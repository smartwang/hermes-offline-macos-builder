#!/usr/bin/env python3
"""Rewrite Mach-O references inside a copied runtime to loader-relative paths."""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


def run(*args: str, check: bool = True) -> str:
    result = subprocess.run(args, check=check, text=True, capture_output=True)
    return result.stdout


def inside(path_text: str, root: Path) -> bool:
    try:
        Path(path_text).resolve().relative_to(root)
        return True
    except (OSError, ValueError):
        return False


def remap_target(path_text: str, root: Path) -> Path | None:
    """Map a pre-copy absolute path to the equivalent object under root."""
    source = Path(path_text)
    if inside(path_text, root):
        return source.resolve()
    parts = source.parts
    for marker in (root.name, "site-packages"):
        positions = [index for index, part in enumerate(parts) if part == marker]
        for index in reversed(positions):
            candidate = root.joinpath(*parts[index + 1 :])
            if candidate.exists():
                return candidate.resolve()
    return None


def loader_relative(target: str | Path, binary: Path) -> str:
    relative = os.path.relpath(str(target), binary.parent)
    return "@loader_path/" + relative.replace(os.sep, "/")


def macho_dependencies(binary: Path) -> list[str]:
    lines = run("otool", "-L", str(binary)).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines if line.strip()]


def macho_id(binary: Path) -> str | None:
    lines = run("otool", "-D", str(binary), check=False).splitlines()[1:]
    return lines[0].strip() if lines else None


def macho_rpaths(binary: Path) -> list[str]:
    lines = run("otool", "-l", str(binary)).splitlines()
    result: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for candidate in lines[index + 1 : index + 5]:
                stripped = candidate.strip()
                if stripped.startswith("path "):
                    result.append(stripped[5:].split(" (offset", 1)[0])
                    break
    return result


def relocate_one(binary: Path, root: Path) -> bool:
    info = run("file", "-b", str(binary), check=False)
    if "Mach-O" not in info:
        return False

    commands: list[list[str]] = []
    for dependency in macho_dependencies(binary):
        mapped_dependency = remap_target(dependency, root) if dependency.startswith("/") else None
        if mapped_dependency is not None:
            commands.append(
                [
                    "install_name_tool",
                    "-change",
                    dependency,
                    loader_relative(mapped_dependency, binary),
                    str(binary),
                ]
            )

    identity = macho_id(binary)
    if identity and identity.startswith("/"):
        commands.append(["install_name_tool", "-id", f"@rpath/{binary.name}", str(binary)])

    rpaths = macho_rpaths(binary)
    replacement_rpaths = set(rpaths)
    for rpath in rpaths:
        mapped_rpath = remap_target(rpath, root) if rpath.startswith("/") else None
        if mapped_rpath is not None:
            replacement = loader_relative(mapped_rpath, binary)
            if replacement != rpath:
                commands.append(["install_name_tool", "-delete_rpath", rpath, str(binary)])
                replacement_rpaths.discard(rpath)
                if replacement not in replacement_rpaths:
                    commands.append(["install_name_tool", "-add_rpath", replacement, str(binary)])
                    replacement_rpaths.add(replacement)

    if not commands:
        return False
    for command in commands:
        run(*command)
    run("codesign", "--force", "--sign", "-", str(binary))
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        raise SystemExit(f"runtime root not found: {root}")

    changed: list[Path] = []
    for path in sorted(root.rglob("*")):
        candidate = path.suffix in {".so", ".dylib"} or os.access(path, os.X_OK)
        if path.is_file() and candidate and relocate_one(path, root):
            changed.append(path)

    print(f"macho-relocation: changed={len(changed)}")
    for path in changed:
        print(f"  {path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
