# Markup

Markup is a local-first macOS menu bar utility for capturing visual feedback while testing apps. Press the global hotkey, box the UI issue, add a short note, and Markup writes an agent-readable task bundle into the configured project.

## Build and Run

```sh
swift run Markup
```

For a real app bundle:

```sh
./scripts/build-app.sh
open .build/Markup.app
```

`build-app.sh` uses a real Apple signing identity automatically when one is installed. It prefers `Developer ID Application`, then `Apple Development`, and only falls back to ad hoc signing when no Apple identity exists. To force a local developer-signed build:

```sh
MARKUP_SIGNING_MODE=development ./scripts/build-app.sh
```

For a downloadable build you can upload to a website:

```sh
./scripts/package-app.sh
```

That writes a drag-to-Applications disk image and a zipped app bundle under `dist/`.

Website downloads that should open without Gatekeeper warnings need Developer ID signing and notarization. `package-app.sh` requires a `Developer ID Application` certificate by default so release artifacts do not accidentally ship with development or ad hoc signing. After installing that certificate and storing notary credentials, build and notarize like this:

```sh
xcrun notarytool store-credentials markup-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

./scripts/package-app.sh
NOTARYTOOL_PROFILE=markup-notary ./scripts/notarize-app.sh
```

The first capture may require macOS Screen Recording permission. Window titles use Accessibility permission when available, with Core Graphics metadata as a fallback.

## Workflow

1. Launch Markup.
2. Press `Cmd+Shift+M` in the app you are testing.
3. If the app has no route yet, choose the project folder and feedback path.
4. Optionally click `Record 10s`. Markup shows a countdown, then returns to the editor with the recording attached.
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
