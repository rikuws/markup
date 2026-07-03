---
name: markup-release
description: Release a new Markup macOS version by bumping the latest GitHub `vX.Y.Z` tag. Use when the user asks to release Markup, create a new Markup version, bump major/minor/patch, push a release tag, or trigger the Markup GitHub release workflow.
---

# Markup Release

Use this skill only for the Markup repo at `/Users/rikuwikman/Dev/markup` / `github.com:rikuws/markup`.

The release workflow is tag-driven: pushing a `vX.Y.Z` tag to GitHub triggers `.github/workflows/release.yml`, which builds, signs, notarizes, generates Sparkle assets, and uploads the GitHub Release assets.

## Required Input

The user must say which semver part to bump: `major`, `minor`, or `patch`.

If the bump type is missing or ambiguous, ask for exactly one of those three words before doing release work.

## Workflow

1. Start in `/Users/rikuwikman/Dev/markup`.
2. Confirm the remote is the Markup GitHub repo:

   ```bash
   git remote -v
   ```

3. Run the helper once without `--yes` to fetch GitHub tags, inspect the latest remote `vX.Y.Z` tag, and preview the next tag:

   ```bash
   python3 ~/.codex/skills/markup-release/scripts/release_markup.py patch
   ```

   Replace `patch` with the user's requested `major`, `minor`, or `patch`.

4. Check the preview:
   - It must say the latest tag came from GitHub.
   - It must tag `origin/main`, not an arbitrary local working tree commit.
   - The new tag must be the expected semver bump.

5. If the user's current request explicitly asks to release/push the tag, run the same command with `--yes`:

   ```bash
   python3 ~/.codex/skills/markup-release/scripts/release_markup.py patch --yes
   ```

6. After the push, report:
   - Previous latest tag.
   - New pushed tag.
   - Target commit short SHA.
   - The GitHub Actions workflow URL: `https://github.com/rikuws/markup/actions/workflows/release.yml`.

## Guardrails

- Do not invent a version manually; compute it from GitHub remote tags after fetching.
- Do not retag, delete, force-push, or move existing tags.
- Do not push a tag if the helper reports the remote is not `rikuws/markup`.
- Do not release local unpushed work. The helper intentionally tags `origin/main`.
- If the helper reports dirty local changes, mention that they are not part of the release unless already pushed to `origin/main`.
- If GitHub rejects the push or the workflow fails to start, stop and report the exact error instead of retrying with destructive git commands.
