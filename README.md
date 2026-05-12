# punchlist

punchlist is a local-first macOS menu bar utility for capturing visual feedback while testing apps. Press the global hotkey, box the UI issue, add a short note, and punchlist writes an agent-readable task bundle into the configured project.

## Build and Run

```sh
swift run punchlist
```

For a real app bundle:

```sh
./scripts/build-app.sh
open .build/punchlist.app
```

The first capture may require macOS Screen Recording permission. Window titles use Accessibility permission when available, with Core Graphics metadata as a fallback.

## Workflow

1. Launch punchlist.
2. Press `Cmd+Shift+P` in the app you are testing.
3. If the app has no route yet, choose the project folder and feedback path.
4. Optionally click `Record 10s`. punchlist shows a countdown, then returns to the editor with the recording attached.
5. Draw one box around the issue.
6. Type or dictate a short note.
7. Save. The feedback folder is written only at this point.

Bundles are written to:

```text
<project>/<feedback-path>/<timestamp>-<app>-<id>/
  instruction.md
  metadata.json
  screenshot.png
  screenshot-original.png
  recording.mov
```

`recording.mov` is present only when you use `Record 10s`.
