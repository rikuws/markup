# Dictation support for Markup

The product is **point at the bug and talk**, like a coworker standing next to you. Not Globe/Fn Keyboard Dictation, and not a mic button you press after the box is drawn.

Markup cannot be compiled or launched on this Linux VM. Mic, TCC, live partials, and first-word latency need a Mac on macOS 26.

## The interaction

Today the overlay waits for a box, then focuses the note, then the user types. That splits “what” and “where” into two modes.

The fluent version is one mode:

1. `Cmd+Shift+M` captures the window.
2. While the overlay is coming up, Markup already has the mic and the speech engine warm.
3. Overlay appears **already listening**. A small in-overlay chip is the only HUD (the system dictation HUD would sit behind `.screenSaver`).
4. The user draws the region and talks at the same time: “this primary button is cramped against cancel, give it 16px and use the destructive style.”
5. Words land live in the note (volatile text dimmed, finals solid). The canvas stays first responder so they can keep adjusting the box while speaking.
6. A pause to fix the box is not “stop dictation.” Listening lasts for the overlay session. `SpeechDetector` drops silence so thinking-pauses do not get transcribed.
7. They click the note to edit, click the listening chip to mute, or Save. Escape mutes first; a second Escape cancels the capture.

Do not auto-focus the note when the box completes if they are still speaking. Today `onSelectionCompleted` does exactly that and would yank keyboard focus mid-sentence.

Do not end listening when the mouse goes up. People keep talking after the rectangle exists (“…and the helper text under it is wrong too”).

First-run Microphone permission must not appear on top of the overlay. Ask at first capture *before* the overlay, or from Settings. If the user declines, typing still works.

Screen recordings stay silent (`captureMicrophone = false`). Tear the speech session down before “Record 10s”.

## Engine: SpeechAnalyzer, live, not WhisperKit

Keyboard Dictation is the Globe/Fn IME. Skip it.

WhisperKit (`large-v3-v20240930_626MB`) is real Whisper and can win on jargon, but it is the wrong default for **talk-while-you-draw**:

- Cold start is a 626 MB Hugging Face download and a model load. The overlay would appear and the first sentence would be missed or delayed.
- Keeping that model resident in a menu-bar app is hundreds of MB of RAM on every launch.
- Open-source streaming is “re-transcribe a growing buffer,” which fights Liquid Glass selection on the same machine. SpeechAnalyzer is built for live volatile results on the Neural Engine.

Apple’s 2026 `SpeechAnalyzer` is not Keyboard Dictation. Notes uses this model. On English LibriSpeech it beats Whisper Small (~2.1% vs ~3.7% WER) and is faster. For a 10–40s “what’s wrong with this control” utterance, that is the fluent engine.

Use:

- `DictationTranscriber` — punctuated, coworker-style prose, not raw captions. Apple’s own live-mic sample uses this module.
- `reportingOptions: [.volatileResults]` — the note updates while they draw.
- `SpeechDetector` in the same `SpeechAnalyzer` — segment speech, ignore silence, do not require a stop button.
- `AnalysisContext.contextualStrings` — up to 100 phrases. This is Markup’s accuracy lever (see below).
- `AssetInventory` + `modelRetention: .lingering` — warm during `captureActiveWindow()`, keep the locale model around between captures.

Do not call the OpenAI Whisper API. Do not add `SFSpeechRecognizer`.

Revisit WhisperKit only if live SpeechAnalyzer still mangles UI jargon after contextual strings and screenshot OCR are in. Same overlay UX; swap the transcriber, do not change the gesture.

## Accuracy without Whisper: bias from the screenshot

A coworker can see the labels on screen. The transcriber cannot, unless we tell it.

When the overlay opens, run `VNRecognizeTextRequest` on the captured image (already in memory) and take the strongest unique tokens — button titles, headings, visible copy. Combine with app name, window title, route name, and a tiny UI glossary (`button`, `navbar`, `sheet`, `padding`, `screenshot`). Feed that set as `contextualStrings`.

That is why SpeechAnalyzer can be *more* accurate than generic Whisper for Markup: the vocabulary is this window, right now. Whisper’s free-form prompt can do something similar, but not at the cost of live latency.

Cap at 100 phrases. Refresh when the user adds a shot.

## Signing

Release packages use hardened runtime with no entitlements file. Add `com.apple.security.device.audio-input` and pass `--entitlements` to `codesign`, or Developer ID builds deny the mic with no TCC prompt. Ad-hoc local builds skip `--options runtime`, so a fluent session can work on the developer Mac and fail in the notarized DMG.

Rewrite `NSMicrophoneUsageDescription` to: Markup listens while you mark a screenshot and transcribes the note on this Mac.

## Implementation sketch

`NoteDictationController` owned by the annotation overlay:

1. During capture, request mic permission if needed, reserve `DictationTranscriber` assets, build the analyzer with transcriber + detector.
2. On overlay `viewDidAppear`, start `AVCaptureSession` (more reliable than `AVAudioEngine` input on macOS) → `AnalyzerInput` stream → `analyzer.start(inputSequence:)`.
3. `setContext` from capture metadata + OCR tokens.
4. Consume `transcriber.results`: append finals, replace the trailing volatile span in `noteTextView` without stealing first responder from the canvas.
5. Listening chip reflects detector / analyzer state. Mute finalizes through end of input; unmute starts a new session and appends.
6. On Save / Cancel / Record, `finalizeAndFinish` or `cancelAndFinishNow`, stop capture, release the mic.

Keep canvas first responder while listening. Gate overlay Escape (mute vs cancel) and do not let Save’s Return key equivalent fire during an active utterance.

## Files

| File | Change |
| --- | --- |
| `Sources/Markup/Resources/Markup.entitlements` | Hardened-runtime audio input. |
| `scripts/build-app.sh` | `--entitlements`; microphone usage string. |
| `Sources/Markup/NoteDictationController.swift` | Warm, listen, VAD, volatile/final text, mute. |
| `Sources/Markup/ScreenshotTextIndex.swift` | One-shot Vision OCR → contextual phrases. |
| `Sources/Markup/AnnotationWindowController.swift` | Auto-listen, chip, do not focus the note mid-speech, Escape gating. |
| `Sources/Markup/CaptureCoordinator.swift` | Pre-warm on capture; stop dictation before recording. |
| `README.md` | Mark and talk; on-device; mic permission. |

## Mac test checklist

- Speak while dragging the box; first words appear before mouse-up.
- Pause, resize the box, keep talking; both sentences are in the note.
- Visible UI label (“Sign in”, a unique heading) is transcribed correctly more often with OCR context than without.
- Escape mutes; second Escape cancels.
- Clicking the note lets them edit without killing already-final text.
- “Record 10s” after talking still writes a silent movie.
- Notarized build prompts for Microphone once, then works offline for later captures (locale model already on disk).
