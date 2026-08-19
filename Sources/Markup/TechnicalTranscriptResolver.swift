import Foundation

/// Post-recognition reranker for Markup dictation.
///
/// This is the correction stage after ASR:
/// `audio → TranscriptionEngine → TechnicalTranscriptResolver → insertion`.
///
/// `SpeechTranscriber` has no `AnalysisContext.contextualStrings` hook, and the
/// live `timeIndexedProgressiveTranscription` preset turns on `.fastResults`
/// (faster, less accurate). Markup keeps live volatile text, drops that speed
/// bias, asks for alternative hypotheses, then picks the candidate that best
/// matches UI/design vocabulary — so “the you” can become “the UI” without
/// rewriting “you should”.
///
/// Parakeet currently has no alternatives, so only the rewrite pass runs.
/// FluidAudio also has CTC custom-vocabulary boosting for Parakeet TDT, but it
/// needs a second 110M CTC model and is not wired in this prototype.
struct TechnicalTranscriptResolver {
    /// App, window, page, and note tokens from the current markup session.
    var sessionTerms: [String] = []
    /// Whole-word substitutions learned from typed note edits this session.
    private var learned: [String: String] = [:]

    mutating func learnCorrection(from previous: String, to edited: String) {
        let oldWords = Self.words(in: previous)
        let newWords = Self.words(in: edited)
        guard oldWords.count == newWords.count, !oldWords.isEmpty else { return }

        for (old, new) in zip(oldWords, newWords) {
            let key = old.lowercased()
            guard key != new.lowercased() else { continue }
            guard !Self.lockedWords.contains(key) else { continue }
            guard Self.looksTechnical(new) else { continue }
            learned[key] = new
        }
    }

    /// Prefer an Apple alternative that already contains technical terms.
    /// Per-token audio timing is kept because the chosen value is still one
    /// of the attributed candidates the transcriber produced.
    func preferredTranscription(
        primary: AttributedString,
        alternatives: [AttributedString]
    ) -> AttributedString {
        var unique: [AttributedString] = []
        var seen = Set<String>()
        for item in [primary] + alternatives {
            let plain = String(item.characters)
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(plain).inserted {
                unique.append(item)
            }
        }
        guard let first = unique.first else { return primary }

        var best = first
        var bestScore = Int.min
        for (rank, item) in unique.enumerated() {
            let score = scoreCandidate(String(item.characters), rank: rank)
            if score > bestScore {
                bestScore = score
                best = item
            }
        }
        return best
    }

    /// Homophone and casing repair for speech that still missed the term.
    /// Typed `baseNote` text is not passed through here.
    func resolvedSpeech(_ text: String) -> String {
        rewrite(text)
    }

    /// Short phrases for `DictationTranscriber` via `AnalysisContext`.
    /// Ignored by `SpeechTranscriber`. Capped at Apple’s 100-phrase limit.
    var contextualPhrases: [String] {
        var phrases: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...40).contains(phrase.count) else { return }
            let words = phrase.split(whereSeparator: \.isWhitespace)
            guard (1...3).contains(words.count) else { return }
            let key = phrase.lowercased()
            guard seen.insert(key).inserted else { return }
            phrases.append(phrase)
        }

        for term in sessionTerms { add(term) }
        for term in learned.values { add(term) }
        for term in Self.biasPhrases { add(term) }
        if phrases.count > 100 {
            phrases = Array(phrases.prefix(100))
        }
        return phrases
    }

    static func sessionTerms(from areas: [MarkupArea]) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...40).contains(phrase.count) else { return }
            let key = phrase.lowercased()
            guard !Self.stopwords.contains(key) else { return }
            guard seen.insert(key).inserted else { return }
            terms.append(phrase)
        }

        for area in areas {
            if let owner = area.owner {
                add(owner.appName)
                for token in words(in: owner.appName) { add(token) }
                for token in words(in: owner.windowTitle) { add(token) }
                if let page = owner.browserPage {
                    add(page.routeName)
                    for token in words(in: page.title) { add(token) }
                    for token in words(in: page.routeName) { add(token) }
                    if let urlString = page.url, let host = URL(string: urlString)?.host {
                        for label in host.split(separator: ".") {
                            let piece = String(label)
                            guard piece != "www", piece.count > 2 else { continue }
                            add(piece)
                        }
                    }
                }
            }
            for token in words(in: area.note) { add(token) }
        }
        return terms
    }

    // MARK: - Scoring

    private func scoreCandidate(_ text: String, rank: Int) -> Int {
        let rewritten = rewrite(text)
        var score = vocabularyScore(rewritten) * 6
        if rewritten == text {
            score += 4
        }
        score -= rank * 2
        return score
    }

    private func vocabularyScore(_ text: String) -> Int {
        let haystack = " " + Self.normalized(text) + " "
        var score = 0
        for term in Self.vocabulary {
            score += Self.countHits(of: term, in: haystack)
        }
        for term in sessionTerms {
            let needle = term.lowercased()
            guard needle.count >= 2 else { continue }
            score += Self.countHits(of: needle, in: haystack) * 2
        }
        return score
    }

    private static func countHits(of term: String, in haystack: String) -> Int {
        let needle = " " + term + " "
        guard needle.count >= 3 else { return 0 }
        var count = 0
        var search = haystack.startIndex
        while let range = haystack.range(of: needle, range: search..<haystack.endIndex) {
            count += 1
            search = range.upperBound
            if search < haystack.endIndex {
                search = haystack.index(before: search)
            }
        }
        return count
    }

    // MARK: - Rewrite

    private func rewrite(_ text: String) -> String {
        let parts = Self.pieces(in: text)
        guard !parts.isEmpty else { return text }

        var output = ""
        var index = 0
        while index < parts.count {
            let piece = parts[index]
            guard piece.isWord else {
                output += piece.text
                index += 1
                continue
            }

            let lower = piece.text.lowercased()
            if let replacement = learned[lower], !Self.lockedWords.contains(lower) {
                output += replacement
                index += 1
                continue
            }

            if let match = matchPhrase(in: parts, startingAt: index) {
                output += match.replacement
                index = match.nextIndex
                continue
            }

            if lower == "you",
               Self.shouldReadYouAsUI(
                left: Self.adjacentWord(in: parts, from: index, step: -1),
                right: Self.adjacentWord(in: parts, from: index, step: 1)
               ) {
                output += "UI"
                index += 1
                continue
            }

            if let canonical = Self.canonical[lower] {
                output += canonical
                index += 1
                continue
            }

            output += piece.text
            index += 1
        }
        return output
    }

    private func matchPhrase(
        in parts: [Piece],
        startingAt start: Int
    ) -> (replacement: String, nextIndex: Int)? {
        let consecutive = Self.consecutiveWords(in: parts, startingAt: start)
        guard !consecutive.isEmpty else { return nil }

        for phrase in Self.phrases {
            let count = phrase.tokens.count
            guard consecutive.count >= count else { continue }
            let slice = Array(consecutive.prefix(count))
            guard slice.map(\.lowercased) == phrase.tokens else { continue }

            let lastPieceIndex = slice[count - 1].pieceIndex
            let next = Self.adjacentWord(in: parts, from: lastPieceIndex, step: 1)
            if phrase.blockedNext.contains(next ?? "") {
                continue
            }
            return (phrase.replacement, lastPieceIndex + 1)
        }
        return nil
    }

    private static func shouldReadYouAsUI(left: String?, right: String?) -> Bool {
        if let left, determiners.contains(left) {
            return true
        }
        if let right, uiRightCues.contains(right) {
            return true
        }
        return false
    }

    // MARK: - Tokenizing

    private struct Piece {
        var isWord: Bool
        var text: String
    }

    private struct WordSpan {
        var pieceIndex: Int
        var lowercased: String
    }

    private struct Phrase {
        var tokens: [String]
        var replacement: String
        var blockedNext: Set<String>
    }

    private static let wordPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:[.'’\-][A-Za-z0-9]+)*"#)
    }()

    private static func pieces(in text: String) -> [Piece] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let matches = wordPattern.matches(in: text, range: full)
        var parts: [Piece] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                parts.append(Piece(
                    isWord: false,
                    text: nsText.substring(with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    ))
                ))
            }
            parts.append(Piece(isWord: true, text: nsText.substring(with: match.range)))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            parts.append(Piece(
                isWord: false,
                text: nsText.substring(from: cursor)
            ))
        }
        return parts
    }

    private static func words(in text: String) -> [String] {
        pieces(in: text).compactMap { $0.isWord ? $0.text : nil }
    }

    private static func consecutiveWords(in parts: [Piece], startingAt start: Int) -> [WordSpan] {
        var words: [WordSpan] = []
        var index = start
        while index < parts.count, words.count < 4 {
            let piece = parts[index]
            if piece.isWord {
                words.append(WordSpan(pieceIndex: index, lowercased: piece.text.lowercased()))
            } else if !words.isEmpty,
                      !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            index += 1
        }
        return words
    }

    private static func adjacentWord(in parts: [Piece], from index: Int, step: Int) -> String? {
        var cursor = index + step
        while parts.indices.contains(cursor) {
            if parts[cursor].isWord {
                return parts[cursor].text.lowercased()
            }
            cursor += step
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        var output = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "." {
                output.append(character)
            } else {
                output.append(" ")
            }
        }
        return output
    }

    private static func looksTechnical(_ token: String) -> Bool {
        let lower = token.lowercased()
        if canonical[lower] != nil { return true }
        if vocabulary.contains(lower) { return true }
        if token.contains(".") || token.contains("-") { return true }
        let letters = token.filter(\.isLetter)
        let uppers = token.filter { $0.isUppercase && $0.isLetter }
        if letters.count >= 2, uppers.count == letters.count { return true }
        if uppers.count >= 2 { return true }
        return false
    }

    // MARK: - Lexicon

    /// Pronouns and glue we must never learn as unconditional substitutions.
    private static let lockedWords: Set<String> = [
        "you", "i", "me", "we", "they", "it", "a", "an", "the",
        "to", "for", "of", "and", "or"
    ]

    private static let determiners: Set<String> = [
        "the", "this", "that", "a", "an", "my", "your", "our", "their", "its",
        "current", "new", "old", "main", "entire", "whole", "existing", "live",
        "actual", "full", "overall", "primary", "secondary"
    ]

    /// Next-word cues that make bare “you” ungrammatical as a pronoun.
    private static let uiRightCues: Set<String> = [
        "needs", "is", "was", "feels", "looks", "seems", "appears",
        "takes", "has", "gets", "stays", "remains", "becomes",
        "smaller", "bigger", "larger", "wider", "narrower", "taller", "shorter",
        "cluttered", "cramped", "busy", "dense", "sparse", "simple", "simpler",
        "complex", "empty", "light", "lighter", "dark", "darker", "heavy",
        "heavier", "tight", "tighter", "loose", "messy", "clean", "cleaner"
    ]

    private static let swiftUIBlockedNext: Set<String> = [
        "should", "can", "could", "would", "will", "might", "must", "shall", "may",
        "are", "were", "do", "does", "did", "have", "has", "had", "to"
    ]

    private static let youIBlockedNext: Set<String> = [
        "think", "thought", "believe", "mean", "guess", "know", "feel",
        "designed", "made", "built", "created", "want", "wanted",
        "did", "do", "have", "had", "was", "were", "am",
        "will", "would", "could", "should", "can", "might", "must",
        "said", "told", "hope", "wish", "need", "needed"
    ]

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with",
        "this", "that", "is", "it", "be", "at", "from", "by", "as", "into",
        "not", "no", "yes", "if", "then", "than", "but", "so", "too", "very",
        "just", "about", "over", "under", "after", "before", "between",
        "your", "my", "our", "their", "its", "you", "we", "they", "he", "she",
        "window", "windows", "untitled", "desktop"
    ]

    /// Longest phrase first so “swift you i” wins over “swift you”.
    private static let phrases: [Phrase] = [
        Phrase(tokens: ["swift", "you", "i"], replacement: "SwiftUI", blockedNext: []),
        Phrase(tokens: ["swift", "u", "i"], replacement: "SwiftUI", blockedNext: []),
        Phrase(tokens: ["you", "i", "kit"], replacement: "UIKit", blockedNext: []),
        Phrase(tokens: ["u", "i", "kit"], replacement: "UIKit", blockedNext: []),
        Phrase(tokens: ["info", "p", "list"], replacement: "Info.plist", blockedNext: []),
        Phrase(tokens: ["liquid", "glass"], replacement: "Liquid Glass", blockedNext: []),
        Phrase(tokens: ["type", "script"], replacement: "TypeScript", blockedNext: []),
        Phrase(tokens: ["java", "script"], replacement: "JavaScript", blockedNext: []),
        Phrase(tokens: ["next", "j", "s"], replacement: "Next.js", blockedNext: []),
        Phrase(tokens: ["next", "js"], replacement: "Next.js", blockedNext: []),
        Phrase(tokens: ["node", "js"], replacement: "Node.js", blockedNext: []),
        Phrase(tokens: ["vs", "code"], replacement: "VS Code", blockedNext: []),
        Phrase(tokens: ["v", "s", "code"], replacement: "VS Code", blockedNext: []),
        Phrase(tokens: ["git", "hub"], replacement: "GitHub", blockedNext: []),
        Phrase(tokens: ["mac", "o", "s"], replacement: "macOS", blockedNext: []),
        Phrase(tokens: ["mac", "os"], replacement: "macOS", blockedNext: []),
        Phrase(tokens: ["i", "o", "s"], replacement: "iOS", blockedNext: []),
        Phrase(tokens: ["app", "kit"], replacement: "AppKit", blockedNext: []),
        Phrase(tokens: ["you", "x"], replacement: "UX", blockedNext: []),
        Phrase(tokens: ["you", "ex"], replacement: "UX", blockedNext: []),
        Phrase(tokens: ["u", "x"], replacement: "UX", blockedNext: []),
        Phrase(tokens: ["u", "ex"], replacement: "UX", blockedNext: []),
        Phrase(tokens: ["a", "p", "i"], replacement: "API", blockedNext: []),
        Phrase(tokens: ["s", "d", "k"], replacement: "SDK", blockedNext: []),
        Phrase(tokens: ["x", "code"], replacement: "Xcode", blockedNext: []),
        Phrase(tokens: ["c", "s", "s"], replacement: "CSS", blockedNext: []),
        Phrase(tokens: ["h", "t", "m", "l"], replacement: "HTML", blockedNext: []),
        Phrase(tokens: ["j", "s", "o", "n"], replacement: "JSON", blockedNext: []),
        Phrase(tokens: ["side", "bar"], replacement: "sidebar", blockedNext: []),
        Phrase(tokens: ["tool", "bar"], replacement: "toolbar", blockedNext: []),
        Phrase(tokens: ["nav", "bar"], replacement: "navbar", blockedNext: []),
        Phrase(tokens: ["tool", "tip"], replacement: "tooltip", blockedNext: []),
        Phrase(tokens: ["pop", "over"], replacement: "popover", blockedNext: []),
        Phrase(tokens: ["check", "box"], replacement: "checkbox", blockedNext: []),
        Phrase(tokens: ["drop", "down"], replacement: "dropdown", blockedNext: []),
        Phrase(tokens: ["hot", "key"], replacement: "hotkey", blockedNext: []),
        Phrase(tokens: ["swift", "you"], replacement: "SwiftUI", blockedNext: swiftUIBlockedNext),
        Phrase(tokens: ["you", "i"], replacement: "UI", blockedNext: youIBlockedNext),
        Phrase(tokens: ["u", "i"], replacement: "UI", blockedNext: [])
    ]

    private static let canonical: [String: String] = [
        "ui": "UI",
        "ux": "UX",
        "gui": "GUI",
        "hud": "HUD",
        "cta": "CTA",
        "aria": "ARIA",
        "wcag": "WCAG",
        "a11y": "a11y",
        "api": "API",
        "sdk": "SDK",
        "cli": "CLI",
        "ide": "IDE",
        "lsp": "LSP",
        "css": "CSS",
        "html": "HTML",
        "json": "JSON",
        "svg": "SVG",
        "xml": "XML",
        "yaml": "YAML",
        "http": "HTTP",
        "https": "HTTPS",
        "url": "URL",
        "uuid": "UUID",
        "oauth": "OAuth",
        "jwt": "JWT",
        "sql": "SQL",
        "graphql": "GraphQL",
        "swiftui": "SwiftUI",
        "appkit": "AppKit",
        "uikit": "UIKit",
        "figma": "Figma",
        "xcode": "Xcode",
        "macos": "macOS",
        "ios": "iOS",
        "ipados": "iPadOS",
        "typescript": "TypeScript",
        "javascript": "JavaScript",
        "github": "GitHub",
        "next.js": "Next.js",
        "node.js": "Node.js",
        "you-x": "UX",
        "you-i": "UI",
        "u-x": "UX"
    ]

    private static let vocabulary: Set<String> = [
        "ui", "ux", "gui", "hud", "cta", "aria", "wcag", "a11y",
        "swiftui", "appkit", "uikit", "swift", "combine",
        "figma", "framer",
        "sidebar", "toolbar", "navbar", "menubar", "popover", "tooltip",
        "modal", "dialog", "sheet", "drawer", "toast", "canvas", "viewport",
        "checkbox", "dropdown", "stepper", "slider", "chip", "badge", "avatar",
        "api", "sdk", "cli", "repl", "ide", "lsp",
        "json", "yaml", "xml", "html", "css", "svg",
        "http", "https", "url", "uuid", "rest", "graphql", "websocket",
        "oauth", "jwt", "cors", "csrf",
        "git", "github", "gitlab", "npm", "xcode", "vscode",
        "macos", "ios", "ipados",
        "typescript", "javascript", "react", "next.js", "node.js",
        "markup", "screenshot", "liquid glass", "hotkey",
        "component", "layout", "padding", "margin", "contrast", "typography",
        "localhost", "plist", "entitlements", "info.plist"
    ]

    private static let biasPhrases: [String] = [
        "UI", "UX", "API", "SDK", "GUI", "HUD", "CTA", "ARIA", "WCAG",
        "SwiftUI", "AppKit", "UIKit", "Figma", "Xcode",
        "sidebar", "toolbar", "popover", "tooltip", "canvas", "modal",
        "TypeScript", "JavaScript", "GitHub", "macOS", "iOS",
        "JSON", "HTML", "CSS", "GraphQL", "OAuth",
        "Liquid Glass", "Markup", "hotkey"
    ]
}
