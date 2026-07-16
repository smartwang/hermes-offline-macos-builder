#!/usr/bin/env python3
"""Remove build-path bindings and bytecode from copied site-packages."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def symlink_escapes_root(path: Path, target: Path, root: Path) -> bool:
    resolved_target = (path.parent / target).resolve(strict=False)
    try:
        resolved_target.relative_to(root)
    except ValueError:
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("site_packages", type=Path)
    parser.add_argument("--forbid", action="append", default=[])
    args = parser.parse_args()
    root = args.site_packages.resolve()
    removed: list[str] = []

    for directory in sorted(root.rglob("__pycache__"), reverse=True):
        if directory.is_dir():
            shutil.rmtree(directory)
            removed.append(str(directory.relative_to(root)))

    for path in root.rglob("*.pyc"):
        path.unlink(missing_ok=True)
        removed.append(str(path.relative_to(root)))

    for path in list(root.glob("__editable__*")):
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
        removed.append(path.name)

    forbidden = [value for value in args.forbid if value]
    for path in root.glob("*.pth"):
        text = path.read_text(encoding="utf-8", errors="replace")
        if any(value in text for value in forbidden):
            path.unlink()
            removed.append(path.name)

    # Editable installs also leave absolute source URLs in direct_url.json.
    # They are metadata only and must not bind the offline copy to the runner.
    for path in root.rglob("direct_url.json"):
        raw = path.read_bytes()
        if any(value.encode() in raw for value in forbidden):
            path.unlink()
            removed.append(str(path.relative_to(root)))

    leaked: list[str] = []
    bad_links: list[str] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            target = path.readlink()
            target_text = str(target)
            escapes_root = symlink_escapes_root(path, target, root)
            if target.is_absolute() or escapes_root or any(value in target_text for value in forbidden):
                bad_links.append(f"{path.relative_to(root)} -> {target}")
            continue
        if not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
            continue
        raw = path.read_bytes()
        if b"\x00" in raw:
            continue
        if any(value.encode() in raw for value in forbidden):
            leaked.append(str(path.relative_to(root)))
    if bad_links:
        raise SystemExit(f"non-relocatable symlinks remain in site-packages: {bad_links[:20]}")
    if leaked:
        raise SystemExit(f"absolute build paths remain in site-packages: {leaked[:20]}")

    print(f"site-packages-sanitized removed={len(removed)}")
    for item in removed[:20]:
        print(f"  {item}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
