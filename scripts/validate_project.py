#!/usr/bin/env python3
"""Static checks that can run on Windows before macOS CI is triggered."""

from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    ROOT / ".github/workflows/build-macos-offline.yml",
    ROOT / "scripts/build-macos-offline.sh",
    ROOT / "scripts/manifest_tool.py",
    ROOT / "scripts/sanitize_site_packages.py",
    ROOT / "scripts/render_template.py",
    ROOT / "templates/install-offline.sh",
    ROOT / "templates/install-offline.command",
    ROOT / "templates/README-中文.md",
]


def main() -> int:
    errors: list[str] = []
    for path in REQUIRED:
        if not path.is_file():
            errors.append(f"missing: {path.relative_to(ROOT)}")

    for path in ROOT.rglob("*.py"):
        try:
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except SyntaxError as exc:
            errors.append(f"python syntax: {path.relative_to(ROOT)}: {exc}")

    workflow_path = ROOT / ".github/workflows/build-macos-offline.yml"
    if workflow_path.is_file():
        workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
        jobs = workflow.get("jobs", {})
        matrix = jobs.get("build", {}).get("strategy", {}).get("matrix", {}).get("include", [])
        actual = {(item.get("arch"), item.get("runner")) for item in matrix}
        expected = {("arm64", "macos-15"), ("x64", "macos-15-intel")}
        if actual != expected:
            errors.append(f"workflow matrix mismatch: {actual}")

    installer = (ROOT / "templates/install-offline.sh").read_text(encoding="utf-8")
    network_commands = re.findall(r"(?m)^\s*(curl|wget|brew|pip|npm)\b", installer)
    if network_commands:
        errors.append(f"installer contains network/package-manager commands: {network_commands}")
    for marker in [
        "BUNDLE-CONTENTS.sha256",
        "MANIFEST.json",
        "verify --root",
        ".hermes-bootstrap-complete",
        "rollback",
        "validate_user_path",
    ]:
        if marker not in installer:
            errors.append(f"installer missing required marker: {marker}")
    if "skills_sync.py" in installer:
        errors.append("installer must not execute target-side skills_sync.py")

    builder = (ROOT / "scripts/build-macos-offline.sh").read_text(encoding="utf-8")
    for marker in ["sandbox-exec", "deny network*", "UV_SHA256", "NODE_SHA256", "RG_SHA256"]:
        if marker not in builder:
            errors.append(f"builder missing security marker: {marker}")
    workflow_text = workflow_path.read_text(encoding="utf-8")
    if "actions/attest-build-provenance@" not in workflow_text:
        errors.append("workflow missing build provenance attestation")

    for shell in [ROOT / "scripts/build-macos-offline.sh", ROOT / "templates/install-offline.sh", ROOT / "templates/install-offline.command"]:
        if shell.is_file():
            # Use a POSIX relative path with the project root as cwd. This
            # works in both MSYS Git Bash and native Unix Bash.
            shell_for_bash = shell.relative_to(ROOT).as_posix()
            result = subprocess.run(
                ["bash", "-n", shell_for_bash],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            if result.returncode:
                errors.append(f"bash syntax: {shell.relative_to(ROOT)}: {result.stderr.strip()}")

    if errors:
        print("project-validation: FAILED")
        for error in errors:
            print(f"  {error}")
        return 1
    print("project-validation: OK")
    print(json.dumps({"required_files": len(REQUIRED), "workflow_matrix": sorted(actual)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
