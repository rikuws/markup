# Markup

<div align="center">

**Visual feedback bundles for installed apps, browser tabs, and local dev servers.**

Markup is a local-first macOS menu bar app for capturing UI feedback, marking the exact problem, and saving an agent-ready work bundle directly inside the project that should be fixed.

[![Latest release](https://img.shields.io/github/v/release/rikuws/markup?label=release)](https://github.com/rikuws/markup/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Local first](https://img.shields.io/badge/local--first-yes-2f855a)
![Dev server ready](https://img.shields.io/badge/dev--server-ready-6b46c1)

[Download DMG](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.dmg)
&nbsp;&middot;&nbsp;
[Download ZIP](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.zip)
&nbsp;&middot;&nbsp;
[Releases](https://github.com/rikuws/markup/releases/latest)

</div>

## Why Markup?

Screenshots in chat are easy to lose. Bug reports without pixels are easy to misunderstand. Markup keeps visual feedback where the code lives: every capture becomes a plain-file folder with an instruction, metadata, annotated screenshots, and originals.

That gives coding agents the same context a human reviewer would want: what app was captured, what window or browser page it came from, where the user pointed, what they wrote, and which project route should receive the fix.

**Markup does not require the thing you are reviewing to be installed.** If the UI is running from `npm run dev`, `vite`, `next dev`, `cargo tauri dev`, a localhost browser tab, or any other transient development window, Markup can still capture it and route the feedback by page or project context. That makes it useful while the product is still being built, before there is a packaged app to install.

## Features

| Feature | What it does |
| --- | --- |
| Live on-screen markup | The default `Cmd+Shift+M` hotkey (or the menu bar item) puts Liquid Glass selection directly on the live screen — no screenshot editor, no dimmed overlay. |
| Dev-mode friendly | Mark local development builds, localhost browser tabs, and uninstalled app windows. |
| Multiple areas | Mark as many areas as you want, across apps and displays; each area gets its own note. |
| Talk while you mark | Speak while you draw; dictation uses Apple’s on-device `SpeechTranscriber` (the Notes engine). Speech from the moment you start a new drag lands only in that area (click an area to retarget). |
| Save-time capture | Pixels are captured when you save, so you can reproduce the issue live while narrating it. |
| Per-area routing | Each area detects the app it was drawn on and routes to that app's markup folder — native apps by identity, browser pages by local host, repository, Figma file, Google Doc, or host. |
| Feedback inbox | Review pending feedback by project, open screenshots, edit notes, reveal folders, or move handled items to Trash. |
| Agent-ready files | Save `instruction.md`, `metadata.json`, screenshots, and originals in the target repo — one bundle per route. |

## Install

1. Download the latest [DMG](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.dmg) or [ZIP](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.zip).
2. Move `Markup.app` to `/Applications`.
3. Launch Markup and grant Screen Recording permission when macOS asks. Microphone permission is requested on the first capture so you can talk while you mark.
4. Open Settings to configure the hotkey, app routes, and the feedback inbox notch.

Markup requires macOS 26 (Tahoe) or newer for its Liquid Glass selection UI. The first install comes from the DMG or ZIP; later signed releases can be installed from **Check for Updates**. Accessibility permission is useful for richer browser/page context and can be opened from Settings.

## Workflow

1. Press `Cmd+Shift+M` or choose **Mark Up Screen** from the menu bar item. The screen stays live — glass selection renders directly on top of whatever is running.
2. Drag a glass area over the issue and say what’s wrong — Markup listens while you mark.
3. Drag more areas anywhere on the screen. Speech from the moment you start that drag (and after you release) goes only to the new area. Click an existing area (or its caption chip) to add to its note, or type in the chip directly.
4. Press Return or click Save. Each area's pixels are captured from the live screen, the app under each area is detected, and one bundle is written per project route — prompting for a folder the first time an app is seen, like before.
5. Ask your coding agent to process the pending Markup feedback.

The default feedback path is `.markup/feedback`, but each app or browser route can point at a different project root and relative feedback path.

## Bundle Format

Markup writes ordinary files so humans, scripts, and agents can all inspect the same source of truth.

```text
.markup/feedback/
  20260703-153015-safari-a1b2c3/
    instruction.md
    metadata.json
    screenshot.png
    screenshot-original.png
    screenshot-2.png
    screenshot-original-2.png
```

`instruction.md` contains the notes, the marked-area list (including visible UI text OCR’d from each region), app/window/browser context, and done-when criteria. `metadata.json` stores structured capture data, route information, marked regions, per-area notes, optional `visibleText`, asset names, and the schema version (v4 for live areas). Each marked area contributes one screenshot pair; areas on different apps save into separate bundles, one per route.

## Use With Coding Agents

This repository includes a reusable agent skill at [`skills/markup-feedbacks`](skills/markup-feedbacks). Install it into a compatible agent environment, then ask the agent to process the oldest or all pending bundles in the current repo.

For Codex-style local skills:

```bash
mkdir -p ~/.codex/skills/markup-feedbacks
cp -R skills/markup-feedbacks/. ~/.codex/skills/markup-feedbacks/
```

Then ask:

```text
Use the Markup feedbacks skill to process the oldest pending feedback bundle in this repo.
```

The skill lists feedback bundles, reads `instruction.md` and `metadata.json`, inspects screenshots, implements the fix, verifies it, and removes the bundle only after the work is done.

## Development

Markup is a Swift Package Manager macOS app. For day-to-day Xcode work, open **`Markup.xcodeproj`** rather than `Package.swift`.

Running the Swift package executable from Xcode launches an unpackaged, debugger-attached binary. macOS ties Screen Recording (and related TCC) grants to a stable code signature, and it will not give a working grant to a process Xcode is tracing. That is why the permission prompt comes back on every Run and capture still fails after you relaunch.

### Run from Xcode

1. Open `Markup.xcodeproj`.
2. Select the Markup target → **Signing & Capabilities** → your Personal Team / Apple Development team. Ad-hoc “Sign to Run Locally” identities change on every build, so the prompt will not stick.
3. Run the **Markup** scheme. It launches without the debugger so Screen Recording and microphone permissions work after one grant and relaunch.
4. Use **Markup Debug** only when you need breakpoints. Capture will refuse to run under the debugger and offer to relaunch without it.

If System Settings already lists leftover Markup entries from earlier package runs, remove the extra ones and keep the signed `Markup.app`.

Command-line builds still work without Xcode:

```bash
swift package resolve
swift build
```

Build a local `.app` bundle:

```bash
./scripts/build-app.sh
```

Create a local development package without Developer ID signing:

```bash
MARKUP_ALLOW_DEVELOPMENT_PACKAGE=1 MARKUP_SIGNING_MODE=adhoc ./scripts/package-app.sh
```

Useful paths:

| Path | Purpose |
| --- | --- |
| [`Markup.xcodeproj`](Markup.xcodeproj) | Local Xcode app target with stable signing and a no-debugger Run scheme. |
| [`Sources/Markup`](Sources/Markup) | AppKit and SwiftUI application source. |
| [`Sources/Markup/Resources`](Sources/Markup/Resources) | App icon and menu bar assets. |
| [`scripts`](scripts) | Build, package, signing, notarization, Sparkle, and release helpers. |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | GitHub Actions workflow for CI packages and tagged releases. |
| [`.github/workflows/create-release.yml`](.github/workflows/create-release.yml) | Manual `major` / `minor` / `patch` bump that tags `main` and starts the release workflow. |
| [`skills/markup-feedbacks`](skills/markup-feedbacks) | Agent workflow for consuming saved feedback bundles. |

## Releases

Tagged releases are built by GitHub Actions. The usual path is **Actions → Create Release**: choose `major`, `minor`, or `patch`, then run the workflow. That uses the same helper as local releases to compute the next `vX.Y.Z` from the latest GitHub version tag, tags `main`, and starts the macOS packaging workflow.

Pushing a `vX.Y.Z` tag yourself does the same packaging step. Either path signs and notarizes release artifacts, generates Sparkle update assets, uploads checksum files, and publishes latest DMG/ZIP aliases.

Release signing expects these GitHub secrets:

| Secret | Purpose |
| --- | --- |
| `MARKUP_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate. |
| `MARKUP_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the certificate archive. |
| `MARKUP_APPLE_ID` | Apple ID used for notarization. |
| `MARKUP_APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization. |
| `MARKUP_APPLE_TEAM_ID` | Apple Developer Team ID. |
| `MARKUP_SPARKLE_PUBLIC_ED_KEY` | Sparkle public EdDSA key embedded in the app. |
| `MARKUP_SPARKLE_PRIVATE_ED_KEY` | Sparkle private EdDSA key used for appcast signing. |

Generate Sparkle keys from the resolved SwiftPM artifact:

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key
```

Keep the private key only in release secrets.

## Principles

- **Local first:** captures are written to the project route you configure, not uploaded to a service.
- **Plain files:** feedback is useful in Finder, Git, scripts, and agents.
- **Specific context:** a marked region, source screenshot, route metadata, and note beat vague visual bug reports.
- **Human controlled:** bundles stay pending until a human or agent processes them.

## Privacy

Markup does not upload captures. Screenshots, notes, and metadata are saved locally in the feedback directory for the configured route. Spoken notes are transcribed on this Mac and are not sent to a network speech service.

## License

No license has been declared yet.
