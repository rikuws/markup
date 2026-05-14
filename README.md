# Markup

Markup is a local-first macOS menu bar app for turning visual UI feedback into agent-ready work bundles.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?style=for-the-badge)](#install)
[![SwiftPM 5.9](https://img.shields.io/badge/SwiftPM-5.9-orange?style=for-the-badge)](Package.swift)
[![Local first](https://img.shields.io/badge/local-first-blue?style=for-the-badge)](#privacy)

- active-window capture from the menu bar or `Cmd+Shift+M`
- one clear marked region plus a typed or dictated instruction
- optional manual 10-second screen recording
- per-app routes, with browser captures routed by detected page/project
- plain-file `.markup/feedback` bundles for people and coding agents

## Install

Build the app bundle locally:

```bash
./scripts/build-app.sh
open .build/Markup.app
```

Requirements:

- macOS 13+
- Xcode command line tools / Swift 5.9+
- Screen Recording permission for screenshot and recording capture
- Accessibility permission recommended for better active-window titles

For a distributable package:

```bash
./scripts/package-app.sh
./scripts/notarize-app.sh
```

Packaging requires a `Developer ID Application` certificate by default. For a local-only package with a development identity, set `MARKUP_ALLOW_DEVELOPMENT_PACKAGE=1`.

## Quick Start

```bash
swift build          # compile the debug executable
./scripts/build-app.sh  # build and sign .build/Markup.app
```

### Capturing Feedback

1. Launch Markup.
2. Press `Cmd+Shift+M` in the app or browser page you are reviewing.
3. Pick a project folder and feedback path if this route is new.
4. Optionally click `Record 10s`.
5. Draw one box around the issue.
6. Add a short note.
7. Save.

Markup writes the bundle only when you save the capture.

### Working With Agents

Install the bundled Codex skill:

```bash
mkdir -p ~/.codex/skills
cp -R skills/markup-feedbacks ~/.codex/skills/
```

A good generic prompt is:

```text
Use the Markup feedbacks skill and process the oldest pending feedback bundle in this repo.
```

The skill reads `instruction.md`, `metadata.json`, screenshots, and optional recordings, then deletes a bundle only after the requested fix is implemented and verified.

## Output Bundle

Each saved capture is written under the configured project route:

```txt
<project>/<feedback-path>/<timestamp>-<app-or-page>-<id>/
  instruction.md
  metadata.json
  screenshot.png
  screenshot-original.png
  recording.mov
```

`recording.mov` is present only when you attach a recording.

`metadata.json` includes app identity, window title, browser page context when available, project route, screenshot size, marked-region coordinates, and asset names. `instruction.md` contains the user note and the task context an implementation agent should follow.

## Advanced

### Routes

Markup stores routes per app identity. Browser captures can use the current page/project as the route key, so feedback from different web apps can land in different project folders even when it came from the same browser.

The default feedback path is:

```txt
.markup/feedback
```

Generated feedback folders should usually be ignored by the receiving repo.

### Hotkey

The default global hotkey is `Cmd+Shift+M`. It can be changed in Markup's settings window.

### Signing

`scripts/build-app.sh` resolves a signing identity from `MARKUP_CODESIGN_IDENTITY`, `CODE_SIGN_IDENTITY`, or the local keychain. `MARKUP_SIGNING_MODE` supports:

- `auto`
- `developer-id`
- `development`
- `adhoc`

Local builds may be Apple Development signed. Downloadable packages and notarized DMGs should be Developer ID signed.

## Privacy

Markup is local-first. Captures are written to the project route you configure, and the app does not upload them.
