#!/usr/bin/env python3
#
# stack-manifest.py — record which files the ReHLDS stack owns.
#
# Runs inside the Docker build (build-server.sh). The depot SteamCMD installs
# is content the image never changes after the build; the stack (engine, game
# library, Metamod, AMX Mod X, bots, patches) is what a rebuild may change. The
# entrypoint refreshes exactly that second set in an existing volume, so the
# build has to know it. This script derives it by comparing the tree before and
# after the stack is applied: every file that is new, or whose content changed,
# is "owned" by the image. Patched depot files (liblist.gam, exec-stack-cleared
# binaries) count as owned too, because a rebuild can change them.
#
#   stack-manifest.py snapshot <dir>           -> "<sha256>  <path>" per file, sorted
#   stack-manifest.py diff <before> <after>    -> the lines of <after> that are not in <before>
#
# Paths are relative to <dir>, one per line (GoldSrc trees have no newlines in
# file names; the script refuses to continue if one turns up).
#
import hashlib
import os
import sys


def snapshot(root: str) -> None:
    entries = {}
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, root)
            if "\n" in rel:
                sys.exit(f"stack-manifest: newline in file name: {rel!r}")
            digest = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    digest.update(chunk)
            entries[rel] = digest.hexdigest()
    for rel in sorted(entries):
        print(f"{entries[rel]}  {rel}")


def diff(before: str, after: str) -> None:
    with open(before, encoding="utf-8") as fh:
        base = set(line.rstrip("\n") for line in fh if line.strip())
    with open(after, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line and line not in base:
                print(line)


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "snapshot":
        snapshot(sys.argv[2])
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "diff":
        diff(sys.argv[2], sys.argv[3])
        return 0
    print("usage: stack-manifest.py snapshot <dir> | diff <before> <after>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
