# Dictation support for Markup

Research notes for adding voice input to Markup notes. This is not an implementation plan that has been shipped; it is the recommended path after inspecting the current overlay, signing, and macOS 26 speech APIs.

Markup cannot be compiled or launched on the Linux Cloud Agent VM. Everything below that depends on TCC, window z-order, or the dictation HUD needs a Mac running macOS 26.

## What Markup already assumes

The note field is the product’s instruction to a coding agent. Capture is useless without it: `FeedbackDraft.isComplete` requires a non-empty note.

The shipping Info.plist has declared dictation intent since the first commit:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Markup can use microphone access when macOS dictation is used in the note field.</string>
```

There is no in-app speech pipeline. Screen recording explicitly turns the mic off (`SCStreamConfiguration.captureMicrophone = false`), so recordings stay visual. The intended voice path is **system dictation into the note**, not a custom recognizer.

Primary surface: `PlaceholderTextView` (`NSTextView`) in `AnnotationWindowController`. After the user draws a region, first responder moves to the note. That is the correct control for system dictation: dictated text arrives as normal input, with the existing note as context.

Secondary surface: SwiftUI `TextEditor` in the top-notch inbox. Same permission story, weaker window setup (non-activating panel). Treat this as follow-up, not the first target.

## Why it likely does not work in release builds

Developer ID packages are signed with the hardened runtime and no entitlements file:

```87:93:scripts/build-app.sh
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP"
```

Hardened runtime silently blocks microphone and Core Audio unless `com.apple.security.device.audio-input` is present in the signed entitlements. The TCC prompt never appears and Markup never shows up under System Settings → Privacy & Security → Microphone. `NSMicrophoneUsageDescription` is not enough by itself.

Markup is not App Sandbox, so `com.apple.security.device.microphone` is not required. Ad-hoc local builds (`MARKUP_SIGNING_MODE=adhoc`) skip `--options runtime`, so dictation may appear to work for the developer and fail for everyone else on a notarized DMG.

## Overlay behavior that fights dictation

Even with the entitlement, the annotation overlay has several conflicts with the system dictation UI.

**Escape cancels the whole capture.** `AnnotationOverlayWindow.sendEvent` swallows Escape before AppKit can deliver it. System dictation uses Escape to stop listening without discarding the rest of the session. Starting dictation and then pressing Esc currently aborts the overlay.

**Return is the Save key equivalent.** `saveButton.keyEquivalent = "\r"`. An `NSTextView` normally consumes Return as a newline, but dictation’s accept/end gesture is often Return. That can save a half-finished note the moment the user finishes speaking.

**No Edit menu affordance.** Markup is an accessory app (`LSUIElement`, `NSApplicationActivationPolicy.accessory`) with no visible menu bar. Users start system dictation with Globe/Fn (or Edit → Start Dictation). There is no mic button on the note, so voice input is undiscoverable even if it works.

**Window level `.screenSaver`.** The overlay sits at screensaver level so it covers full-screen apps. The system dictation microphone HUD may draw behind that overlay. If that happens on macOS 26, the user hears the start sound and sees nothing.

**Dictation only works while the note is focused.** Initial first responder is the canvas. Dictation before drawing a box does nothing useful. After a box is drawn, focus already moves to the note; that part is fine.

**Top-notch editor is a non-activating panel.** `TopNotchPanel` uses `.nonactivatingPanel`. Dictation needs a key window and a focused text view. Inbox editing is a secondary case; do not block capture-overlay work on it.

## Two implementation options

### Option A — Enable system dictation (recommended first)

Stay on the path the Info.plist already describes. `NSTextView` already accepts dictation. Markup’s job is to stop blocking it and make it findable.

1. Add `Sources/Markup/Resources/Markup.entitlements` with `com.apple.security.device.audio-input` set to true, and pass `--entitlements` into `codesign` in `scripts/build-app.sh`. Keep hardened runtime for Developer ID.
2. Do not treat Escape as Cancel while dictation is active, or while the note is first responder and has marked/inline dictation text. Fall back to Cancel when the canvas is focused or the note is idle.
3. Do not fire Save on Return while dictation is active. Keep Return as Save when the canvas is focused, which matches the current shortcut hint for the markup step.
4. Add a mic button next to the Note label that focuses `noteTextView` and invokes the system `startDictation:` action (same path as Edit → Start Dictation). Accessory apps often have no usable Edit menu, so a button is the discoverability fix.
5. After a Mac test: if the dictation HUD is hidden behind the overlay, either lower the overlay while listening or draw a small in-overlay “Listening…” chip so the user is not flying blind.
6. Leave screen recordings without microphone capture. Do not start dictation while a recording is in progress; the annotation overlay is already dismissed then.

Privacy stays local-first: Markup does not upload audio. System dictation uses the user’s Keyboard Dictation setting (on-device when Enhanced Dictation / Apple Intelligence dictation is available).

### Option B — In-app `SpeechAnalyzer` / `DictationTranscriber`

macOS 26 ships Apple’s new Speech framework: `SpeechAnalyzer` plus modules. For a short feedback note, the right module is `DictationTranscriber` (punctuation, sentence structure, `AnalysisContext.contextualStrings`). `SpeechTranscriber` is the long-form / meeting model and does not take contextual strings.

A hold-to-talk or toggle mic on the note would:

- Request microphone access explicitly (the usage string already exists).
- Stream `AVAudioPCMBuffer` / `AnalyzerInput` into `SpeechAnalyzer`.
- Insert volatile then final text into `noteTextView`.
- Optionally bias recognition with up to 100 phrases from the captured app name, window title, route, and a small UI-feedback glossary (`button`, `screenshot`, `navbar`, and similar).

This is the right engine if Option A fails Mac testing: HUD hidden, users with Keyboard Dictation off, or UI jargon transcribed poorly.

Costs:

- More code and locale asset downloads via `AssetInventory`.
- A second voice UX next to system dictation unless system dictation is dropped.
- Mic session contention if dictation and screen recording ever overlap.
- Cannot be verified on this VM.

Do not use `SFSpeechRecognizer` for a new feature. Markup already requires macOS 26, and the legacy API’s default path can leave the device.

Do not ship a third-party / cloud STT stack. That would contradict Markup’s local-first privacy story.

## Recommended rollout

Ship Option A in the next dictation PR. It matches the existing plist, is a small signing and overlay change, and can be validated on one Mac:

1. Notarized Developer ID build prompts for Microphone on first dictation.
2. Globe/Fn or the mic button inserts text into the note.
3. Escape stops dictation without closing the overlay; a second Escape still cancels capture.
4. Return while listening does not Save; Return after dictation ends still inserts a newline in the note (Save stays a click or a Return when the canvas is focused).
5. A 10s screen recording still has no microphone track.

Only start Option B if those checks fail, or if voice notes need Markup-specific vocabulary that system dictation cannot learn.

## Files that would change for Option A

| File | Change |
| --- | --- |
| `Sources/Markup/Resources/Markup.entitlements` | New. Hardened-runtime audio input. |
| `scripts/build-app.sh` | Pass `--entitlements` to `codesign`. |
| `Sources/Markup/AnnotationWindowController.swift` | Escape/Return gating; mic button; optional listening chip. |
| `README.md` | One line: notes accept macOS dictation (Globe/Fn or the mic button). Microphone permission may be requested. |

No Speech framework import, no `NSSpeechRecognitionUsageDescription`, and no change to `ScreenRecorder` unless testing shows a conflict.

## Mac test checklist

These cannot be run here.

- Ad-hoc build vs Developer ID build: confirm the entitlement is what makes the Microphone TCC prompt appear.
- Keyboard Dictation enabled and disabled in System Settings.
- Globe/Fn start, mic-button start, and Edit menu start if a hidden main menu exists.
- Dictation HUD visible above the `.screenSaver` overlay.
- Escape and Return while listening, with an empty note and with a partial note.
- Top-notch `TextEditor` as a separate pass.
- Screen recording immediately after dictating a note (mic should stay off on the movie).
