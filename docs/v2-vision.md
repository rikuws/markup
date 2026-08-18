# Markup 2.0: mark the live screen, not a screenshot

Version 2.0 removes the separate screenshot editor. The same `Cmd+Shift+M` puts Liquid Glass selection **directly on the live screen** — no captured image underneath, no dimmed chrome, no editor window. You draw one or more glass areas on top of whatever apps are actually running, talk, and save. The screen keeps being the screen the whole time.

This is a long work in progress. 1.x fixes keep landing on `main`; this branch (`cursor/v2-dev-0f86`) tracks 2.0 and merges `main` in regularly. Ship nothing from here until the live pipeline is at parity on routing and bundle output.

## Implementation status

The first cut of the whole pipeline is implemented on this branch and needs Mac feel-testing:

- Live session: `LiveMarkupSession` + `LiveSelectionWindow`/`LiveSelectionView` (one transparent window per display, drag-to-create glass areas, caption chips with editable notes, floating HUD, Esc-mute/Esc-cancel/Return-save).
- Per-area app detection: `AreaWindowResolver` (CGWindowList hit-test, majority vote over center + corners).
- Save-time capture: `AreaCapturer` (owner window → display-rect → area-only fallbacks; Markup's windows excluded from every display capture).
- Dictation retargeting: `SpeechTranscriber` with audio time ranges; a new-area drag freezes the previous note and routes later speech only to the new area. Click-to-retarget works via areas and chips. Technical terms are reranked after recognition (`TechnicalTranscriptResolver`); `SpeechTranscriber` still has no contextual-strings hook.
- Routing and output: per-area routes grouped into one bundle per route (`FeedbackBundleWriter`, metadata schema v4 with per-area notes; `instruction.md` keeps a combined "User note:" block for inbox compatibility).
- Retired: `AnnotationWindowController`, `AnnotationCanvasView` (glass pane extracted to `SelectionGlass.swift`), `AppendCaptureHUDController`, `ActiveWindowCapturer`, `ScreenRecorder`, `RecordingProgressWindowController`. There is no Record 10s in 2.0.

## What 1.x does today (what we are replacing)

The 1.x pipeline is: hotkey → `ActiveWindowCapturer` screenshots the frontmost window via ScreenCaptureKit → `AnnotationWindowController` opens a borderless `.screenSaver` window showing **the screenshot** with dimmed chrome → the user draws one region per shot on the image, dictates a note, saves → `FeedbackBundleWriter` writes the bundle into the route's feedback folder.

Everything in that middle section — the screenshot-based editor — goes away:

- `AnnotationWindowController` / `AnnotationViewController` (~1450 lines): the editor window, shot strip, note view, Save/Add Shot/Record chrome.
- `AnnotationCanvasView` drawing a rectangle **on the image**.
- The dimmed `alpha 0.72` overlay look. There is no "overlay mode" in 2.0; there is only the desktop with glass on it.
- The Add Shot / append-capture dance (`AppendCaptureHUDController`, re-arming the hotkey, reactivating the target app). Multi-area on the live screen replaces multi-shot.

What survives, mostly intact: `HotKeyManager`, `CaptureCoordinator` (heavily reshaped), the glass rendering stack (`LiquidWaveShape`, `SelectionGlassPane`, `PassthroughGlassView`, `LiquidGlassSelectionRenderer`), `NoteDictationController` (now `SpeechTranscriber`), `ScreenshotTextIndex` (save-time visible text, not dictation bias), the whole routing stack (`RouteTargetResolver`, `BrowserPageContextResolver`, `RoutePrompts`, `SettingsStore`), `FeedbackBundleWriter`, `StatusBarController`, `TopNotchController`.

## The interaction

1. `Cmd+Shift+M`. No window appears. The cursor becomes a crosshair; a full-desktop transparent session window (one per display, borderless, high window level, no dimming) starts intercepting mouse events.
2. Dictation is already warm (same prewarm path as 1.x) and starts listening immediately. A small glass listening chip — the existing `PassthroughGlassView` chip — floats near the active area, because there is no editor window to host it.
3. The user drags. The drag is the same `SelectionGlassPane` liquid-glass rectangle from 1.x, but the "content" under the glass is the real screen, live. `NSGlassEffectView` samples what is behind the window for free — this is exactly what it is built for, and it is the reason the 1.x export-time approximation (`LiquidGlassSelectionRenderer`) exists: system glass cannot be rendered into an offscreen bitmap, but on the live screen we do not need to.
4. On mouse-up the area stays as a resident glass area with a small per-area label (app name + transcribed note preview). The user can immediately drag another area — anywhere, on any app, on any display.
5. Speech lands in the note of the **active area** (see "Dictation targeting"). Volatile text dims, finals solidify, same as 1.x.
6. Save (Return, or a glass Save affordance on the session): for each area, Markup screenshots the pixels under that area's rect via `SCScreenshotManager` display capture **with the session window excluded from the capture**, resolves the route per area, and writes the bundle(s). Escape mutes first, second Escape cancels the whole session — the gating from `docs/dictation.md` carries over unchanged.

The capture happens at **save time**, not at hotkey time. That is the fundamental inversion: 1.x froze the screen first and let you annotate the freeze; 2.0 lets you annotate reality and freezes only what you marked, when you commit. If the screen changes while you talk, the saved pixels are the ones you saved — that is a feature (you can trigger the bug live and mark it), and a known sharp edge (see open questions).

## Per-area app detection and routing

1.x routes by `NSWorkspace.frontmostApplication` at capture time, because it captures the frontmost window. In 2.0 the frontmost app is Markup's own session window, and different areas can sit on different apps, so detection moves **per area, by geometry**:

- On mouse-up, hit-test the area's rect against `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` ordered front-to-back, skipping Markup's own windows. The window owning the majority of the area (sample the center plus corners) gives the owning PID → `NSRunningApplication`.
- Feed that app through the existing `RouteTargetResolver` exactly as today: native apps route by bundle ID; browsers go through `BrowserPageContextResolver` for the page-derived route key. Browser page resolution needs the AX/AppleScript query to target *that* window, not just the frontmost tab — this is the main upgrade `BrowserPageContextResolver` needs.
- Unknown route → same `RoutePrompts` flow as today (`NSOpenPanel` for the project folder, `asksFeedbackPath` on first configure), deferred to save time so prompting never interrupts drawing or speech.
- Each area carries its own resolved route. Areas on the same route save into one bundle (multiple screenshots, shared note structure — closest to today's multi-shot bundle, schema bump from v3). Areas on different routes save one bundle per route.

`ActiveWindowCapturer`'s AX + `CGWindowList` window-resolution logic is the right code to grow this from; it already knows how to correlate AX windows, CG windows, and ScreenCaptureKit filters.

## Multiple areas and dictation targeting

`FeedbackDraft` becomes a list of **areas** instead of a list of shots: each area = rect (display-relative) + owning app/route + its own note + creation timestamp. `maximumShots = 6` becomes a soft cap on areas, probably higher.

Dictation is one continuous session (one mic, one `SpeechAnalyzer`) with a **routing rule** deciding which area's note receives the text. Speech goes to the latest area, but the cut happens when the **drag starts**, not at mouse-up: starting a new drag freezes the previous area's note and retargets the transcript stream so only audio from that moment on (during the drag and after) lands in the new area. Results are sliced by `SpeechTranscriber` audio time ranges, not by string-prefix stripping of the whole session transcript.

Refinements to explore on this branch (deliberately open, in rough priority order):

- **Click-to-retarget:** clicking an existing glass area makes it active, so you can come back and add a sentence. The active area gets a visibly "awake" glass treatment (stronger `LiquidWaveShape` motion) and hosts the listening chip.
- **Utterance-boundary switching:** retarget only at `SpeechDetector` silence boundaries, so a sentence in flight never straddles two areas even if the user starts drawing mid-sentence.
- **Ordinal references:** "the second box" style verbal addressing. Probably overkill; do not build first.

`ScreenshotTextIndex` OCR runs per area at save time (the marked region of the captured image) and is written into the bundle as visible UI text — the 2.0 equivalent of giving the agent the labels a coworker can see. It is not fed into the recognizer.

## What changes where

| File | Fate |
| --- | --- |
| `CaptureCoordinator.swift` | Reshaped: owns the live session lifecycle; capture moves from session start to save time. |
| `AnnotationWindowController.swift` | Retired with the screenshot editor. Session chrome (chip, per-area labels, save affordance) is new, much smaller code. |
| `AnnotationCanvasView.swift` | `SelectionGlassPane` and drag logic extracted and reused on the transparent session window; the image-hosting canvas dies. |
| `ActiveWindowCapturer.swift` | Becomes area-rect display capture + per-area window/app hit-testing. |
| `Models.swift` | `FeedbackDraft` shots → areas (rect + route + note each); metadata schema v4. |
| `NoteDictationController.swift` | `SpeechTranscriber`; retargeting seam is a time cutoff at drag start, not string-prefix carryover. |
| `BrowserPageContextResolver.swift` | Resolve page context for a specific window, not just the frontmost tab. |
| `RouteTargetResolver.swift` / `RoutePrompts` / `SettingsStore` | Unchanged in behavior; called per area at save time. |
| `FeedbackBundleWriter.swift` | Group areas by route; one bundle per route per save. |
| `ScreenRecorder.swift` / Record 10s | Retired. Live areas plus dictation replace the clip. |

## Open questions

- **Save-time capture vs. glass occlusion:** the glass areas themselves must not appear in the saved screenshots. Excluding Markup's windows from the `SCScreenshotManager` filter handles it; verify glass does not force a flicker/hide frame.
- **Screen changes during the session:** if the app under an area scrolls or navigates before save, the saved pixels differ from what the user marked. Consider snapshotting each area's pixels at mouse-up as the default, with live-at-save as the option — this needs real-Mac feel testing.
- **Click-through:** while the session is active, should clicks outside any glass area pass through to the apps below (so you can reproduce a bug mid-session)? Powerful, but risks accidental interaction; probably a modifier-key escape hatch rather than the default.
- **Where does the note text live visually?** No editor window means transcribed text needs a home: a small glass caption attached to each area is the current bet; must not cover the very pixels being discussed.
- **Dictation targeting rule:** speech from the start of a new-area drag (and after mouse-up) belongs only to that area; click-to-retarget appends to an existing note. Routing is by audio time range.

All feel/latency questions (glass over live content, mic-to-first-word, retargeting mid-sentence) need a Mac on macOS 26 — same constraint as `docs/dictation.md`. This VM edits code and docs only.
