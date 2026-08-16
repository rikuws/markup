# Dictation support for Markup

Voice notes for the capture overlay. Markup cannot be compiled or launched on the Linux Cloud Agent VM; mic, TCC, and model-download behavior need a Mac on macOS 26.

System Keyboard Dictation (Globe/Fn, Edit → Start Dictation) is **not** the product. It has not been tried in Markup, so there is no confirmed overlay bug. It is also the engine people mean when they say macOS dictation is bad. Do not build the feature around it.

The note is the instruction to a coding agent. `FeedbackDraft.isComplete` already requires one. The goal is a **mic on the note** that records a short clip and transcribes it on-device into `PlaceholderTextView`.

## Product

- Mic control next to the Note label. Click to start, click to stop. Optional silence-end after ~1.5s.
- While listening: in-overlay “Listening…” chip and a pulsing mic. Do not depend on the system dictation HUD (the overlay is `.screenSaver` and would hide it).
- On stop: transcribe the buffer, append to the note (or replace the current selection), keep typing available.
- Escape while listening stops the mic and discards that clip. Escape when idle still cancels the overlay.
- Return while listening does not Save.
- First use: Microphone TCC prompt. Model assets may download once, then stay on disk.
- Screen recordings stay silent (`captureMicrophone = false`). Dictation and the 10s recording must not share the mic.
- Top-notch inbox editor is follow-up.

This is Superwhisper-style **press-to-talk into the focused field**, not global Fn dictation into whatever app is frontmost.

## Engines

Three different things get called “dictation” on a Mac. Only the last two are worth shipping.

| | Keyboard Dictation | SpeechAnalyzer | WhisperKit |
| --- | --- | --- | --- |
| What it is | Globe/Fn IME (`startDictation:`). Same family as legacy `SFSpeechRecognizer`. | macOS 26 Speech framework. Apple Notes uses this model. | OpenAI Whisper on Apple Silicon (Core ML / ANE). MIT. Package: `argmaxinc/argmax-oss-swift`, product `WhisperKit`. |
| Quality | The “default dictation is shit” engine. LibriSpeech WER ~9% on-device. | English LibriSpeech ~2.1% clean / 4.6% other. Beats Whisper Small. | Small ~3.7% on the same corpus. `large-v3-v20240930_626MB` is the accuracy pick Superwhisper-class apps use; not in that LibriSpeech table. |
| First-run cost | User must enable Keyboard Dictation in Settings. | System `AssetInventory` download if the locale model is missing. No extra SPM dep. | ~626 MB from Hugging Face into Application Support. SPM dep. `Package.swift` is currently Swift tools 5.9; WhisperKit wants 5.10. |
| Markup fit | Overlay fights the HUD; Escape/Return conflict; undiscoverable in an accessory app. | Short notes, punctuation via `DictationTranscriber`, `AnalysisContext.contextualStrings` (app name, window title, route). | Whisper `--prompt` / `--prefix` for “UI bug report about {app}”. 99 languages. Matches “use Whisper”. |
| Privacy | On-device if Enhanced Dictation is on; otherwise can leave the machine. | On-device only. | On-device after the model download. Not the OpenAI Whisper API. |

Do not call the OpenAI Whisper HTTP API. That would upload the note audio and break Markup’s local-first rule.

Do not add `SFSpeechRecognizer` for a new feature.

## Recommendation

**Ship in-app press-to-talk with Apple `SpeechAnalyzer` + `DictationTranscriber` as the default engine.**

That is not Keyboard Dictation. It is the 2026 on-device model, already required by Markup’s macOS 26 floor, with no 600 MB Hugging Face hit before the first voice note. Seed `contextualStrings` from the captured app name, window title, route name, and a small UI glossary (`button`, `navbar`, `sheet`, `screenshot`).

Use **WhisperKit `large-v3-v20240930_626MB`** only if SpeechAnalyzer still feels like Keyboard Dictation on real Markup notes, or if you want Whisper’s free-form prompt and extra languages. Same mic button and record-then-transcribe loop; swap the transcriber.

Record the whole utterance, then transcribe once. Streaming partials are extra moving parts for a 10–30s UI note and make Escape/undo harder. M-series machines transcribe a clip like that faster than real time on either engine.

## Signing (needed for either engine)

Release packages sign with hardened runtime and no entitlements file:

```87:93:scripts/build-app.sh
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
```

Add `Sources/Markup/Resources/Markup.entitlements` with `com.apple.security.device.audio-input` and pass `--entitlements` to `codesign`. Without it, Developer ID builds deny the mic silently. Ad-hoc local builds skip `--options runtime`, so a mic feature can work on the developer machine and fail in the notarized DMG.

Markup is not sandboxed; `com.apple.security.device.microphone` is not required.

Update `NSMicrophoneUsageDescription` to match the real feature, for example: Markup records a short voice note and transcribes it on this Mac so you can dictate feedback.

## Implementation sketch (SpeechAnalyzer)

New type, e.g. `NoteDictationController`:

1. `AVAudioApplication.requestRecordPermission()`.
2. Capture 16 kHz mono PCM into a buffer while the mic is armed.
3. `DictationTranscriber` for the current locale (formatted note text). Ensure assets with `AssetInventory`.
4. `SpeechAnalyzer(modules:)` + `setContext` with capture metadata phrases.
5. `analyzeSequence` / `finalizeAndFinishThroughEndOfInput()`, then insert `String(result.text.characters)` at the note caret.
6. Tear down the audio session so a later “Record 10s” is unaffected.

Wire a mic button in `AnnotationWindowController` next to the Note label. Gate overlay Escape/Return on `isListening`. Keep `ScreenRecorder.captureMicrophone = false`.

WhisperKit variant of the same controller: `WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_626MB"))`, `AudioProcessor.startRecordingLive`, `transcribe(audioArray:decodeOptions:)` with a prompt built from the capture. Download the model once into Application Support; show progress on first use. Do not put 626 MB in the DMG.

## Files for the SpeechAnalyzer slice

| File | Change |
| --- | --- |
| `Sources/Markup/Resources/Markup.entitlements` | Hardened-runtime audio input. |
| `scripts/build-app.sh` | `--entitlements`; rewrite the microphone usage string. |
| `Sources/Markup/NoteDictationController.swift` | Permission, capture, transcribe, insert. |
| `Sources/Markup/AnnotationWindowController.swift` | Mic button, listening chip, Escape/Return gating. |
| `README.md` | Notes can be dictated on-device. Microphone permission on first use. |

No WhisperKit / Hugging Face work in that slice.

## Mac test checklist

- Developer ID build shows a Microphone TCC prompt; ad-hoc vs notarized confirms the entitlement.
- First dictation may download a locale model; later notes work offline.
- Click mic → speak a UI note with the captured app’s name → text lands in the note with punctuation.
- Escape while listening does not close the overlay; second Escape cancels capture.
- Return while listening does not Save.
- “Record 10s” after dictation still writes a silent movie.
- Airplane mode after the first successful transcription still works.
