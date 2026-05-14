---
name: markup-feedbacks
description: Process Markup visual feedback bundles from local repos. Use when the user asks Codex to inspect, implement, fix, address, consume, clear, or delete Markup feedback, markup screenshots, visual feedback bundles, `.markup/feedback` items, all feedback items, or only the oldest/next/single feedback item.
---

# Markup Feedbacks

Use this skill to turn saved Markup feedback bundles into code changes and remove each bundle only after it has been handled.

## Quick Start

List all pending bundles in the current repo:

```bash
python3 ~/.codex/skills/markup-feedbacks/scripts/list_feedback.py --root "$PWD" --mode all
```

List only the oldest pending bundle:

```bash
python3 ~/.codex/skills/markup-feedbacks/scripts/list_feedback.py --root "$PWD" --mode oldest
```

## Scope Selection

- If the user says all, every, clear, drain, or cleanup, use `--mode all`.
- If the user says one, single, next, oldest, first, or asks for the same workflow with one item, use `--mode oldest`.
- If the user asks generally to process feedback without a count, use `--mode oldest` unless the surrounding context clearly implies a batch cleanup.

## Workflow

1. Run `list_feedback.py` from the target repo. Treat the JSON output as the work queue, already sorted oldest first.
2. For each selected bundle, read `instruction.md` and `metadata.json`. Inspect `screenshot.png`, `screenshot-original.png`, and `recording.mov` when present and useful.
3. Confirm the bundle belongs to the repo you are editing. Prefer the current working tree when the bundle path is under it; otherwise compare `metadata.project.root` with the requested repo.
4. Implement the requested fix in the codebase using the repo's normal patterns.
5. Verify the fix with the smallest meaningful command or visual check. Broaden verification when the change touches shared behavior or UI rendering.
6. Delete a bundle directory only after its fix is implemented and verified. Leave failed, ambiguous, or partially handled bundles in place.

## Deletion Guardrails

- Delete only the individual bundle directory returned by the script, never the parent feedback folder.
- Before deletion, make sure the directory contains `instruction.md` and `metadata.json`.
- Use the absolute `path` from the script output when deleting.
- Do not delete a bundle if the fix was skipped, blocked, or could not be verified.

## Final Response

Report:

- Which bundle IDs were processed.
- Which bundle directories were deleted.
- Verification commands and outcomes.
- Any bundles left pending and why.
