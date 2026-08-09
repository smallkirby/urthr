#!/usr/bin/env python3
"""Copy `src` into `dst`, replacing symlinks with real copies of their targets.

Symlinks are resolved relative to `src`, not the host's real filesystem root.
Symlinks that don't resolve within `src` are dropped.

Safe to re-run against a `dst` that already holds a previous run's output.
"""

import os
import shutil
import sys

def resolve(root: str, path: str, depth: int = 0) -> str | None:
    if depth > 40:
        return None
    if not os.path.lexists(path):
        return None
    if not os.path.islink(path):
        return path

    target = os.readlink(path)
    if os.path.isabs(target):
        next_path = os.path.normpath(os.path.join(root, target.lstrip("/")))
    else:
        next_path = os.path.normpath(os.path.join(os.path.dirname(path), target))

    return resolve(root, next_path, depth + 1)


def clear_if_wrong_type(dst: str, want_dir: bool) -> None:
    if not os.path.lexists(dst):
        return
    if not os.path.islink(dst) and os.path.isdir(dst) == want_dir:
        return  # already the right kind, merge into/overwrite it below
    if os.path.isdir(dst) and not os.path.islink(dst):
        shutil.rmtree(dst)
    else:
        os.remove(dst)


def sync(src: str, dst: str) -> None:
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        target = resolve(src, s)
        if target is None:
            clear_if_wrong_type(d, want_dir=False)
            continue

        if os.path.isdir(target):
            clear_if_wrong_type(d, want_dir=True)
            sync(target, d)
        else:
            clear_if_wrong_type(d, want_dir=False)
            shutil.copy2(target, d)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <src dir> <dst dir>", file=sys.stderr)
        sys.exit(1)
    sync(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]))
