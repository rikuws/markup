# Markup

Markup is a local-first macOS menu bar app for turning visual UI feedback into agent-ready work bundles.

## Download

- [Download latest DMG](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.dmg)
- [Download latest ZIP](https://github.com/rikuws/markup/releases/latest/download/markup-latest-macos.zip)
- [View releases](https://github.com/rikuws/markup/releases/latest)

Markup requires macOS 13 or newer. Give it Screen Recording permission when macOS asks so it can capture screenshots and short recordings.

## Updates

Markup uses Sparkle for native macOS updates. The first Sparkle-capable release still has to be installed from the DMG; later releases can be installed from the app's Check for Updates action. Markup also checks once per day and notifies you when a signed release is available.

Tagged GitHub releases require these secrets:

- `MARKUP_SPARKLE_PUBLIC_ED_KEY`
- `MARKUP_SPARKLE_PRIVATE_ED_KEY`

Generate the key pair with Sparkle's `generate_keys` tool from the resolved SwiftPM artifact, then keep the private key only in release secrets.

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key
```

## Features

- Capture the active window from the menu bar or with `Cmd+Shift+M`.
- Mark one clear region, optionally add more annotated screenshots to the same feedback, and add a typed or dictated instruction.
- Attach an optional 10-second screen recording.
- Route feedback per app, with browser captures grouped by detected page or project.
- Save plain-file `.markup/feedback` bundles that people and coding agents can inspect.

## How It Works

1. Launch Markup.
2. Press `Cmd+Shift+M` in the app or browser page you are reviewing.
3. Draw a box around the issue.
4. Add more screenshots when one issue needs several views or states.
5. Add a short note.
6. Save the feedback bundle to the configured project route.

Each saved feedback includes the note, metadata, marked screenshot, original screenshot, any extra marked screenshots, and optional recording.

## Coding Agent Skill

Markup includes a reusable agent skill in `skills/markup-feedbacks`. Install that folder into any compatible coding agent's local skills or instructions directory, then ask the agent to process pending Markup feedback in the current repo.

For example:

```text
Use the Markup feedbacks skill to process the oldest pending feedback bundle in this repo.
```

The skill guides the agent to read each bundle's instruction, metadata, screenshots, and optional recording, implement the requested fix, verify it, and remove the bundle only after the work is done.

## Privacy

Markup is local-first. Captures are written to the project route you configure, and the app does not upload them.
