# Agent notes

## Cursor Cloud specific instructions

Markup is a **macOS 26+** SwiftPM menu bar app (`Package.swift` platform `.macOS("26.0")`, `LSMinimumSystemVersion` 26.0). Live selection uses `NSGlassEffectView` (Liquid Glass). Cursor Cloud Agent VMs are **Linux** and cannot compile or launch `Markup.app`.

Do not install Swift, Xcode, or macOS SDKs on this VM, and do not run `swift build`, `./scripts/build-app.sh`, or `./scripts/package-app.sh` here. Those commands belong on a Mac or on GitHub Actions (`macos-latest` in `.github/workflows/release.yml`). Canonical local-Mac commands are in the README Development section.

There is **no** in-repo test target, linter config, or long-running service. Nothing should be started in `start` / `terminals` for this repository.

What Cloud Agents *can* do:

- Edit Swift, scripts, skills, and CI YAML.
- Run the agent-facing feedback skill with stdlib `python3`:
  `python3 skills/markup-feedbacks/scripts/list_feedback.py --root "$PWD" --mode oldest`
  Empty output `[]` is expected when `.markup/feedback` has no pending bundles.
- Dry-run a release tag (do not pass `--yes` unless the user asked to publish):
  `python3 skills/markup-release/scripts/release_markup.py patch --repo "$PWD"`

Full capture → annotate → save still requires a Mac running macOS 26 (Tahoe) or newer with Screen Recording permission.
