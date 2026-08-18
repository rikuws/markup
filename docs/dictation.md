# Dictation support for Markup

The product is **point at the bug and talk**, like a coworker standing next to you. Not Globe/Fn Keyboard Dictation, and not a mic button you press after the box is drawn.

Markup cannot be compiled or launched on this Linux VM. Mic, TCC, live partials, and first-word latency need a Mac on macOS 26.

## The interaction

Today the overlay waits for a box, then focuses the note, then the user types. That splits “what” and “where” into two modes.

The fluent version is one mode:

1. `Cmd+Shift+M` captures the window.
2. While the overlay is coming up, Markup already has the mic and the speech engine warm.
3. Overlay appears **already listening**. A waveform in the HUD chip (and a live glass capsule before the first area, and again while a new area is being dragged) shows that Markup is hearing the mic. The system dictation HUD would sit behind `.screenSaver`.
4. The user draws the region and talks at the same time: “this primary button is cramped against cancel, give it 16px and use the destructive style.”
5. Words land live. In-flight (volatile) text **decodes in place** — letters flicker toward the current hypothesis, then lock — and finals go solid. There is no caption chip while the box is still being dragged, so the follow-capsule is the only transcript during that drag. The canvas stays first responder so they can keep adjusting the box while speaking.
6. A pause to fix the box is not “stop dictation.” Listening lasts for the overlay session. `SpeechDetector` drops silence so thinking-pauses do not get transcribed.
7. They click the note to edit, click the listening chip to mute, or Save. Escape mutes first; a second Escape cancels the capture.

Do not auto-focus the note when the box completes if they are still speaking. Today `onSelectionCompleted` does exactly that and would yank keyboard focus mid-sentence.

Do not end listening when the mouse goes up. People keep talking after the rectangle exists (“…and the helper text under it is wrong too”).

First-run Microphone permission must not appear on top of the overlay. Ask at first capture *before* the overlay, or from Settings. If the user declines, typing still works.

## Engine: SpeechAnalyzer + SpeechTranscriber

Keyboard Dictation is the Globe/Fn IME. Skip it.

WhisperKit (`large-v3-v20240930_626MB`) is real Whisper and can win on jargon, but it is the wrong default for **talk-while-you-draw**:

- Cold start is a 626 MB Hugging Face download and a model load. The overlay would appear and the first sentence would be missed or delayed.
- Keeping that model resident in a menu-bar app is hundreds of MB of RAM on every launch.
- Open-source streaming is “re-transcribe a growing buffer,” which fights Liquid Glass selection on the same machine. SpeechAnalyzer is built for live volatile results on the Neural Engine.

Apple’s 2026 `SpeechAnalyzer` is not Keyboard Dictation. Notes’ live record/transcribe feature uses `SpeechAnalyzer` + **`SpeechTranscriber`** — the new on-device model (WWDC 2025). That is the engine Markup uses. `DictationTranscriber` is the old `SFSpeechRecognizer` model, kept only as a fallback when `SpeechTranscriber` is unavailable for the device or locale.

Use:

- `SpeechTranscriber` configured from `timeIndexedProgressiveTranscription` **minus `.fastResults`**, plus `.alternativeTranscriptions` and `.transcriptionConfidence`. Live volatile results and per-token audio time ranges stay; the recognizer is not biased toward speed over accuracy. Alternatives are the contextual-bias layer Apple will not let Markup inject into this model (`AnalysisContext.contextualStrings` is a `DictationTranscriber`-only hook).
- `TechnicalTranscriptResolver` after each result: rerank alternatives with UI/design/session vocabulary, then rewrite leftover homophones (`the you` → `the UI`, `you should` stays `you should`).
- `SpeechDetector` in the same `SpeechAnalyzer` — segment speech, ignore silence, do not require a stop button.
- `AssetInventory` + `modelRetention: .lingering` — warm on session start, keep the locale model around between captures.

Do not call the OpenAI Whisper API. Do not add `SFSpeechRecognizer`. Do not feed screenshot OCR into `AnalysisContext.contextualStrings`; `SpeechTranscriber` does not take that list. Visible UI copy is OCR’d at save time and written into `instruction.md` / `metadata.json` for the agent. Session vocabulary for reranking comes from the marked app/window/page and from typed note edits, not from OCR.

Revisit WhisperKit only if live `SpeechTranscriber` plus the resolver still mangles UI jargon. Same overlay UX; swap the transcriber, do not change the gesture. Do not add a Foundation Models rewrite pass unless the resolver still misses terms — unconstrained “fix this transcript” prompts will rephrase the user’s speech.

## Visible UI text in the bundle, not in the recognizer

A coworker can see the labels on screen. The agent can too, if we write them down.

At save time, run `VNRecognizeTextRequest` on the marked region of each captured image and store the strongest unique lines as `captures[n].visibleText`. `instruction.md` repeats them under each area. That still helps the coding agent see labels a coworker can see. It is too late for dictation — pixels are captured on Save — so live jargon repair is `TechnicalTranscriptResolver`, not OCR.

## Signing

Release packages use hardened runtime with no entitlements file. Add `com.apple.security.device.audio-input` and pass `--entitlements` to `codesign`, or Developer ID builds deny the mic with no TCC prompt. Ad-hoc local builds skip `--options runtime`, so a fluent session can work on the developer Mac and fail in the notarized DMG.

Rewrite `NSMicrophoneUsageDescription` to: Markup listens while you mark a screenshot and transcribes the note on this Mac.

## Implementation sketch

`NoteDictationController` owned by the live session:

1. During session start, request mic permission if needed, reserve `SpeechTranscriber` assets (fall back to `DictationTranscriber` only when the new model is unavailable), build the analyzer with transcriber + detector.
2. Start `AVAudioEngine` input → `AnalyzerInput` stream → `analyzer.start(inputSequence:)`.
3. Consume `transcriber.results` by audio time range: pick the best alternative, assemble the current target with replace-or-append; ignore results that ended before the current target started. Rewrite only the new speech, not typed notes.
4. Starting a new-area drag freezes the previous area’s note and retargets. Speech during that drag and after mouse-up belongs only to the new area. Clicking an existing area retargets the same way.
5. Listening chip shows a live mic waveform plus detector / analyzer state. Before the first area, and while a new area is being dragged, a follow-capsule repeats the waveform and the decoding transcript. Mute finalizes through end of input; unmute starts a new session and appends.
6. On Save, OCR each marked region into the bundle. On Save / Cancel, `finalizeAndFinish` or `cancelAndFinishNow`, stop capture, release the mic.

Keep the session view first responder while listening. Gate Escape (mute vs cancel) and do not let Save’s Return key equivalent fire during an active utterance.

## Files

| File | Change |
| --- | --- |
| `Sources/Markup/Resources/Markup.entitlements` | Hardened-runtime audio input. |
| `scripts/build-app.sh` | `--entitlements`; microphone usage string. |
| `Sources/Markup/NoteDictationController.swift` | `SpeechTranscriber` without `.fastResults`, alternatives, VAD, volatile/final text, time-range retargeting, mute, live mic level. |
| `Sources/Markup/TechnicalTranscriptResolver.swift` | Alternative reranking, homophone rewrite, session vocabulary. |
| `Sources/Markup/LiveMarkupSession.swift` | Auto-listen, retarget at new-area drag start, Escape gating, listen-feedback forwarding. |
| `Sources/Markup/LiveSelectionView.swift` | HUD waveform, follow-capsule while dragging / before first area, decode overlay on the caption chip. |
| `Sources/Markup/VoiceMeterView.swift` | Scrolling microphone bar meter. |
| `Sources/Markup/DecodingTranscriptView.swift` | Glyph-diffusion for in-flight transcript. |
| `Sources/Markup/LiveListenCapsule.swift` | Glass capsule that hosts the meter and decode when no chip exists. |
| `Sources/Markup/ScreenshotTextIndex.swift` | Save-time Vision OCR → bundle `visibleText`. |
| `Sources/Markup/FeedbackBundleWriter.swift` | Write visible UI text into `instruction.md` and metadata. |
| `Sources/Markup/CaptureCoordinator.swift` | Pre-warm on session start. |
| `README.md` | Mark and talk; on-device; mic permission. |

## Mac test checklist

- Speak while dragging the first box; the follow-capsule waveform moves with the box and the words land on that area, not a later one.
- Draw a second area while talking; the follow-capsule shows only the new-area speech, and only that speech is on the second note.
- Pause, keep talking after mouse-up; the continuation stays on the current area.
- Saved `instruction.md` lists visible UI text for the marked region.
- Escape mutes; second Escape cancels.
- Clicking an existing area lets you add a sentence without copying the previous area’s note.
- Notarized build prompts for Microphone once, then works offline for later captures (locale model already on disk).
- Technical terms survive dictation. Repeat these until they stick; “you should” must stay a pronoun:

  - “change the UI” / “the UI should be smaller” / “I don’t like this UI”
  - “make the UI feel lighter” / “the UX is confusing” / “open the API”
  - “use SwiftUI” / “the Figma version looks better”
  - “you should change the UI” / “I think you should simplify the UI”
