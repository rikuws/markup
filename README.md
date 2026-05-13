# Markup

Markup is a local-first macOS menu bar app for turning visual feedback into structured work. Press the hotkey, mark the issue on screen, add a short note, and Markup writes the whole thing into the project folder where an agent or teammate can act on it.

It is built for the moment when a bug is obvious on screen but expensive to explain. Instead of switching to an issue tracker, describing layout details from memory, or dropping loose screenshots in chat, Markup captures the UI state, the marked region, the note, app context, and optional short recording as one feedback bundle.

## What It Does

- Captures the active app window from the menu bar or `Cmd+Shift+M`.
- Lets you draw one clear box around the problem.
- Gives you a focused note field for a short typed or dictated instruction.
- Can attach a manual 10-second screen recording when motion matters.
- Routes feedback per app into the project and folder you choose.
- Saves structured bundles only when you commit the capture.

## Why It Exists

Visual feedback usually loses context. A screenshot needs a note, the note needs a file path, the file path needs reproduction steps, and by the time the work reaches an implementation agent the original intent has already been compressed.

Markup keeps that context together. Each capture becomes a small task packet with the original screenshot, the annotated screenshot, metadata, and an instruction file. The output is plain files on disk, so it fits local development workflows without adding a service account, inbox, or hosted backend.

## Workflow

1. Launch Markup.
2. Press `Cmd+Shift+M` in the app you are testing.
3. If the app has no route yet, choose the project folder and feedback path.
4. Optionally click `Record 10s`. Markup shows a countdown, then returns to the editor with the recording attached.
5. Draw one box around the issue.
6. Type or dictate a short note.
7. Save. The feedback folder is written only at this point.

## Output

Each saved capture is written as a folder in the configured project:

```txt
<project>/<feedback-path>/<timestamp>-<app>-<id>/
  instruction.md
  metadata.json
  screenshot.png
  screenshot-original.png
  recording.mov
```

`recording.mov` is included only when you use `Record 10s`.

The bundle is meant to be readable by both people and coding agents: `instruction.md` carries the task, `metadata.json` carries the capture context, and the images preserve exactly what was on screen.

## Privacy

Markup is local-first. Captures are written to the project route you configure, and nothing is uploaded by the app.

The first capture may require macOS Screen Recording permission. Window titles use Accessibility permission when available, with Core Graphics metadata as a fallback.
