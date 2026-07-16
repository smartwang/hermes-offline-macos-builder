#!/usr/bin/env python3
"""Render @TOKEN@ placeholders without shell-specific sed behavior."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--set", action="append", default=[])
    args = parser.parse_args()

    text = args.template.read_text(encoding="utf-8")
    for pair in args.set:
        if "=" not in pair:
            parser.error(f"invalid --set value: {pair}")
        key, value = pair.split("=", 1)
        text = text.replace(f"@{key}@", value)
    if "@" in text:
        unresolved = sorted({part.split("@", 1)[0] for part in text.split("@")[1::2]})
        if unresolved:
            raise SystemExit(f"unresolved template tokens: {unresolved}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
