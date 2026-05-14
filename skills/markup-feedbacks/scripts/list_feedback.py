#!/usr/bin/env python3
import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_FEEDBACK_PATHS = [".markup/feedback"]


def parse_args():
    parser = argparse.ArgumentParser(description="List Markup feedback bundles oldest first.")
    parser.add_argument("--root", default=os.getcwd(), help="Repo root or feedback directory to scan.")
    parser.add_argument(
        "--mode",
        choices=["all", "oldest"],
        default="oldest",
        help="Return every pending bundle or only the oldest one.",
    )
    parser.add_argument(
        "--feedback-path",
        action="append",
        dest="feedback_paths",
        help="Relative feedback path to scan. Can be repeated. Defaults to .markup/feedback.",
    )
    return parser.parse_args()


def feedback_roots(root: Path, feedback_paths):
    paths = feedback_paths or DEFAULT_FEEDBACK_PATHS
    roots = []

    if looks_like_feedback_root(root):
        roots.append(root)

    for feedback_path in paths:
        candidate = root / feedback_path
        if candidate not in roots:
            roots.append(candidate)

    return roots


def looks_like_feedback_root(path: Path):
    normalized = path.as_posix()
    return normalized.endswith("/.markup/feedback")


def discover_bundles(root: Path, feedback_paths):
    bundles = []

    for feedback_root in feedback_roots(root, feedback_paths):
        if not feedback_root.is_dir():
            continue

        for child in feedback_root.iterdir():
            if not child.is_dir():
                continue

            instruction = child / "instruction.md"
            metadata = child / "metadata.json"
            if not instruction.is_file() or not metadata.is_file():
                continue

            bundles.append(bundle_record(child, instruction, metadata, feedback_root))

    return sorted(bundles, key=lambda item: (item["sortTime"], item["id"]))


def bundle_record(path: Path, instruction: Path, metadata_path: Path, feedback_root: Path):
    metadata = load_metadata(metadata_path)
    created_at = metadata.get("createdAt") if isinstance(metadata, dict) else None
    sort_time = sortable_time(created_at, path)
    assets = metadata.get("assets", {}) if isinstance(metadata, dict) else {}

    record = {
        "id": metadata.get("id") if isinstance(metadata, dict) and metadata.get("id") else path.name,
        "path": str(path.resolve()),
        "feedbackRoot": str(feedback_root.resolve()),
        "instruction": str(instruction.resolve()),
        "metadata": str(metadata_path.resolve()),
        "createdAt": created_at,
        "sortTime": sort_time,
        "annotatedScreenshot": asset_path(path, assets.get("annotatedScreenshot"), "screenshot.png"),
        "originalScreenshot": asset_path(path, assets.get("originalScreenshot"), "screenshot-original.png"),
        "recording": asset_path(path, assets.get("recording"), "recording.mov") if assets.get("recording") else None,
    }

    browser = metadata.get("browser") if isinstance(metadata, dict) else None
    if browser:
        record["browser"] = browser

    return record


def load_metadata(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def sortable_time(value, path: Path):
    if value:
        parsed = parse_datetime(value)
        if parsed:
            return parsed.isoformat()

    stat_time = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    return stat_time.isoformat()


def parse_datetime(value):
    candidates = [value]
    if value.endswith("Z"):
        candidates.append(value[:-1] + "+00:00")

    for candidate in candidates:
        try:
            parsed = datetime.fromisoformat(candidate)
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            continue

    return None


def asset_path(bundle: Path, configured_name, fallback_name):
    name = configured_name or fallback_name
    candidate = bundle / name
    return str(candidate.resolve()) if candidate.exists() else None


def main():
    args = parse_args()
    root = Path(args.root).expanduser().resolve()
    bundles = discover_bundles(root, args.feedback_paths)

    selected = bundles if args.mode == "all" else bundles[:1]
    for item in selected:
        item.pop("sortTime", None)

    print(json.dumps(selected, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
