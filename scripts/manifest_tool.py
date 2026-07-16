#!/usr/bin/env python3
"""Create or verify an offline payload manifest using only the stdlib."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

CHUNK_SIZE = 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def iter_entry_paths(root: Path):
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        dirs.sort()
        files.sort()
        base = Path(current)
        for name in [*dirs, *files]:
            yield (base / name).relative_to(root).as_posix()


def iter_entries(root: Path):
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        dirs.sort()
        files.sort()
        base = Path(current)
        for name in [*dirs, *files]:
            path = base / name
            rel = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if path.is_symlink():
                yield {"path": rel, "type": "symlink", "mode": mode, "target": os.readlink(path)}
            elif path.is_file():
                yield {
                    "path": rel,
                    "type": "file",
                    "mode": mode,
                    "size": info.st_size,
                    "sha256": sha256_file(path),
                }
            elif path.is_dir():
                yield {"path": rel, "type": "directory", "mode": mode}


def symlink_target_within_root(entry_path: str, target: str) -> bool:
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        return False
    normalized = posixpath.normpath(posixpath.join(posixpath.dirname(entry_path), target))
    return normalized != ".." and not normalized.startswith("../")


def create_manifest(root: Path, output: Path, metadata_path: Path) -> int:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    files = list(iter_entries(root))
    unsafe_links = [
        f"{item['path']} -> {item['target']}"
        for item in files
        if item["type"] == "symlink"
        and not symlink_target_within_root(item["path"], item["target"])
    ]
    if unsafe_links:
        raise SystemExit(f"symlink escapes payload root: {unsafe_links[:20]}")
    manifest = {
        "schemaVersion": 1,
        "product": "Hermes Agent Offline Bundle",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        **metadata,
        "payloadEntryCount": len(files),
        "payloadBytes": sum(item.get("size", 0) for item in files),
        "files": files,
    }
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"manifest-created entries={len(files)} bytes={manifest['payloadBytes']}")
    return 0


def verify_manifest(root: Path, manifest_path: Path) -> int:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    checked = 0
    manifest_items = manifest.get("files", [])
    expected_paths = [item["path"] for item in manifest_items]
    unsafe_paths = {
        value
        for value in expected_paths
        if PurePosixPath(value).is_absolute() or ".." in PurePosixPath(value).parts
    }
    if unsafe_paths:
        errors.extend(f"unsafe manifest path: {path}" for path in sorted(unsafe_paths))
    unsafe_links = {
        item["path"]
        for item in manifest_items
        if item.get("type") == "symlink"
        and not symlink_target_within_root(item["path"], item.get("target", ""))
    }
    if unsafe_links:
        errors.extend(f"unsafe symlink target: {path}" for path in sorted(unsafe_links))
    if len(expected_paths) != len(set(expected_paths)):
        errors.append("manifest contains duplicate paths")
    actual_paths = set(iter_entry_paths(root))
    unexpected = sorted(actual_paths - set(expected_paths))
    if unexpected:
        errors.extend(f"unexpected: {path}" for path in unexpected[:50])

    for item in manifest_items:
        checked += 1
        if item["path"] in unsafe_paths or item["path"] in unsafe_links:
            continue
        if item["path"] not in actual_paths:
            errors.append(f"missing: {item['path']}")
            continue
        path = root / item["path"]
        expected_type = item["type"]

        actual_mode = stat.S_IMODE(path.lstat().st_mode)
        if actual_mode != item.get("mode"):
            errors.append(f"mode: {item['path']} expected={item.get('mode'):o} actual={actual_mode:o}")

        if expected_type == "symlink":
            if not path.is_symlink():
                errors.append(f"type: {item['path']} expected=symlink")
            elif os.readlink(path) != item["target"]:
                errors.append(f"target: {item['path']}")
        elif expected_type == "directory":
            if not path.is_dir() or path.is_symlink():
                errors.append(f"type: {item['path']} expected=directory")
        elif expected_type == "file":
            if not path.is_file() or path.is_symlink():
                errors.append(f"type: {item['path']} expected=file")
                continue
            actual_size = path.stat().st_size
            if actual_size != item["size"]:
                errors.append(f"size: {item['path']} expected={item['size']} actual={actual_size}")
                continue
            actual_hash = sha256_file(path)
            if actual_hash != item["sha256"]:
                errors.append(f"sha256: {item['path']}")
        else:
            errors.append(f"unknown type: {item['path']}={expected_type}")

        if len(errors) >= 50:
            errors.append("too many errors; verification stopped")
            break

    if checked != manifest.get("payloadEntryCount"):
        errors.append(
            f"entry-count: expected={manifest.get('payloadEntryCount')} manifest-list={checked}"
        )

    if errors:
        print("payload-verification: FAILED", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    print(f"payload-verification: OK entries={checked}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--metadata", type=Path, required=True)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "create":
        return create_manifest(args.root.resolve(), args.output.resolve(), args.metadata.resolve())
    return verify_manifest(args.root.resolve(), args.manifest.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
