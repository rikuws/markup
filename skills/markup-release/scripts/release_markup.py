#!/usr/bin/env python3
import argparse
import re
import shlex
import subprocess
import sys
from pathlib import Path


TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
MARKUP_REMOTE_RE = re.compile(r"github\.com[:/]rikuws/markup(?:\.git)?$")


def command_text(args):
    return " ".join(shlex.quote(str(arg)) for arg in args)


def run(args, cwd, check=True, capture=True):
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )

    if check and result.returncode != 0:
        print(f"Command failed: {command_text(args)}", file=sys.stderr)
        if result.stdout:
            print(result.stdout, file=sys.stderr, end="" if result.stdout.endswith("\n") else "\n")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="" if result.stderr.endswith("\n") else "\n")
        sys.exit(result.returncode)

    return result


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compute and optionally push the next Markup release tag from GitHub tags.",
    )
    parser.add_argument("bump", choices=["major", "minor", "patch"], help="Semver part to increment.")
    parser.add_argument(
        "--repo",
        default="/Users/rikuwikman/Dev/markup",
        help="Markup repo path. Defaults to /Users/rikuwikman/Dev/markup.",
    )
    parser.add_argument("--remote", default="origin", help="Git remote name. Defaults to origin.")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Create and push the computed tag. Without this, only preview the release.",
    )
    return parser.parse_args()


def ensure_markup_remote(repo, remote):
    result = run(["git", "remote", "get-url", remote], repo)
    remote_url = result.stdout.strip()
    if not MARKUP_REMOTE_RE.search(remote_url):
        print(
            f"Refusing to release: remote {remote!r} is {remote_url!r}, not github.com:rikuws/markup.",
            file=sys.stderr,
        )
        sys.exit(2)
    return remote_url


def fetch_release_refs(repo, remote):
    run(
        [
            "git",
            "fetch",
            "--tags",
            "--prune",
            "--prune-tags",
            remote,
            f"+refs/heads/main:refs/remotes/{remote}/main",
        ],
        repo,
        capture=False,
    )


def remote_versions(repo, remote):
    result = run(["git", "ls-remote", "--tags", "--refs", remote, "v*"], repo)
    versions = []

    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        tag = parts[1].rsplit("/", 1)[-1]
        match = TAG_RE.match(tag)
        if match:
            version = tuple(int(part) for part in match.groups())
            versions.append((version, tag))

    versions.sort(key=lambda item: item[0])
    return versions


def bump_version(version, bump):
    major, minor, patch = version
    if bump == "major":
        return major + 1, 0, 0
    if bump == "minor":
        return major, minor + 1, 0
    return major, minor, patch + 1


def format_version(version):
    return ".".join(str(part) for part in version)


def warn_if_dirty(repo):
    result = run(["git", "status", "--short"], repo)
    if result.stdout.strip():
        print("Warning: local working tree has changes. The release tag will still point at origin/main.")


def main():
    args = parse_args()
    repo = Path(args.repo).expanduser().resolve()

    if not repo.exists():
        print(f"Repo does not exist: {repo}", file=sys.stderr)
        sys.exit(2)

    run(["git", "rev-parse", "--show-toplevel"], repo)
    remote_url = ensure_markup_remote(repo, args.remote)

    fetch_release_refs(repo, args.remote)
    versions = remote_versions(repo, args.remote)

    if versions:
        latest_version, latest_tag = versions[-1]
    else:
        latest_version, latest_tag = (0, 0, 0), None

    next_version = bump_version(latest_version, args.bump)
    next_tag = f"v{format_version(next_version)}"

    remote_tag_check = run(
        ["git", "ls-remote", "--tags", "--refs", args.remote, f"refs/tags/{next_tag}"],
        repo,
        check=False,
    )
    if remote_tag_check.stdout.strip():
        print(f"Refusing to release: remote tag already exists: {next_tag}", file=sys.stderr)
        sys.exit(2)

    target_ref = f"refs/remotes/{args.remote}/main"
    target_commit = run(["git", "rev-parse", "--verify", target_ref], repo).stdout.strip()
    target_short = run(["git", "rev-parse", "--short=12", target_commit], repo).stdout.strip()

    warn_if_dirty(repo)

    print(f"Remote: {remote_url}")
    print(f"Latest GitHub version tag: {latest_tag or 'none'}")
    print(f"Requested bump: {args.bump}")
    print(f"Next release tag: {next_tag}")
    print(f"Target commit: {args.remote}/main @ {target_short}")

    if not args.yes:
        print("Dry run only. Re-run with --yes to create and push the tag.")
        return

    local_tag_check = run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{next_tag}"], repo, check=False)
    if local_tag_check.returncode == 0:
        local_target = run(["git", "rev-list", "-n", "1", next_tag], repo).stdout.strip()
        if local_target != target_commit:
            print(
                f"Refusing to release: local tag {next_tag} points at {local_target[:12]}, "
                f"not {target_short}.",
                file=sys.stderr,
            )
            sys.exit(2)
    else:
        run(["git", "tag", "-a", next_tag, target_commit, "-m", f"Release {next_tag}"], repo, capture=False)

    run(["git", "push", args.remote, f"refs/tags/{next_tag}"], repo, capture=False)
    print(f"Pushed {next_tag} to {args.remote}.")
    print("GitHub Actions: https://github.com/rikuws/markup/actions/workflows/release.yml")


if __name__ == "__main__":
    main()
