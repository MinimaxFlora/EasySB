#!/usr/bin/env python3
"""Keep one channel release down to the cores it should still be offering.

The two channel releases (singbox-stable, singbox-alpha) use fixed tags on purpose, so
the panel can poll one URL forever and the release list never grows. Their assets do grow
though, because each archive is named after the version it was built from
(sing-box-1.14.2-linux-amd64.tar.gz), and a new upstream release adds a fresh set beside
the old one instead of replacing it.

This script keeps the current version's set, optionally a few earlier generations, and
deletes the rest. version.ini is never touched: it is the stamp the panel reads to find the
version, not an archive.

Run with --dry-run (or without a token) to see the decisions without deleting anything.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

# sing-box-1.14.2-linux-amd64.tar.gz and the .sha256 beside it
ARCHIVE_RE = re.compile(r"^sing-box-(?P<version>.+)-linux-(?P<arch>[^-]+)\.tar\.gz(\.sha256)?$")
STAMP_NAME = "version.ini"


def version_key(version: str):
    """Order versions the way a person does: 1.14.2 < 1.14.3 < 1.15.0-alpha.8."""
    main, _, pre = version.partition("-")
    numbers = tuple(int(part) if part.isdigit() else 0 for part in main.split("."))
    if not pre:
        return (numbers, 1, 2, 0)  # a release beats any of its own prereleases
    kind = pre.split(".")[0]
    tail = pre.split(".")[-1]
    rank = {"alpha": 0, "beta": 1, "rc": 2}.get(kind, 0)
    return (numbers, 0, rank, int(tail) if tail.isdigit() else 0)


def parse(names: list[str]) -> dict[str, list[str]]:
    """Group asset names by the version they carry. version.ini has no version."""
    grouped: dict[str, list[str]] = {}
    for name in names:
        match = ARCHIVE_RE.match(name)
        if match:
            grouped.setdefault(match.group("version"), []).append(name)
    return grouped


def decide(names: list[str], current: str, keep_generations: int) -> tuple[list[str], list[str]]:
    """Return (keep, drop). keep_generations 0 keeps everything."""
    grouped = parse(names)
    ordered = sorted(grouped, key=version_key, reverse=True)
    if keep_generations <= 0:
        keep_versions = set(ordered)
    else:
        keep_versions = set(ordered[:keep_generations])
        keep_versions.add(current)  # the version being offered now is never dropped
    keep, drop = [], []
    for name in names:
        if name == STAMP_NAME:
            keep.append(name)
            continue
        match = ARCHIVE_RE.match(name)
        (keep if match and match.group("version") in keep_versions else drop).append(name)
    return keep, drop


def list_assets(repo: str, tag: str, assets_file: str | None) -> list[str]:
    if assets_file:
        data = json.loads(open(assets_file, encoding="utf-8").read())
        return [item["name"] if isinstance(item, dict) else item for item in data]
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if shutil.which("gh") and token:
        out = subprocess.run(
            ["gh", "release", "view", tag, "--repo", repo, "--json", "assets", "-q", ".assets[].name"],
            capture_output=True, text=True, check=True,
        )
        return [line for line in out.stdout.splitlines() if line.strip()]
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "easysb-prune"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    return [asset["name"] for asset in data.get("assets", [])]


def delete(repo: str, tag: str, name: str) -> None:
    subprocess.run(
        ["gh", "release", "delete-asset", tag, name, "--repo", repo, "--yes"],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="MinimaxFlora/EasySB")
    parser.add_argument("--tag", required=True, help="channel release tag, e.g. singbox-stable")
    parser.add_argument("--current", required=True, help="the version that channel offers now")
    parser.add_argument("--keep-generations", type=int, default=1,
                        help="versions to retain: 1 keeps only the current one, 0 keeps all")
    parser.add_argument("--assets-file", help="read asset names from a JSON file instead of GitHub")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    names = list_assets(args.repo, args.tag, args.assets_file)
    keep, drop = decide(names, args.current, args.keep_generations)
    print(f"{args.tag}: {len(names)} assets, keeping {len(keep)}, dropping {len(drop)} "
          f"(current {args.current}, keep-generations {args.keep_generations})")
    for name in sorted(drop):
        print("  drop", name)

    if not drop:
        print("  nothing to prune")
        return 0
    if args.dry_run:
        print("  dry run: nothing deleted")
        return 0
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        print("  no token: nothing deleted", file=sys.stderr)
        return 0
    for name in sorted(drop):
        delete(args.repo, args.tag, name)
        print("  deleted", name)
    remaining = list_assets(args.repo, args.tag, None)
    stale = [n for n in remaining if n in drop]
    if stale:
        print(f"::error::still attached: {', '.join(stale)}", file=sys.stderr)
        return 1
    print(f"  {args.tag} now holds {len(remaining)} assets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
