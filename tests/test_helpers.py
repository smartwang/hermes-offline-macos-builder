from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from manifest_tool import (  # noqa: E402
    create_manifest,
    symlink_target_within_root,
    verify_manifest,
)
from sanitize_site_packages import symlink_escapes_root  # noqa: E402
from relocate_macho import inside, loader_relative  # noqa: E402


class ManifestToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "payload"
        self.root.mkdir()
        (self.root / "sub").mkdir()
        (self.root / "a.txt").write_text("alpha", encoding="utf-8")
        (self.root / "sub" / "b.txt").write_text("beta", encoding="utf-8")
        self.metadata = Path(self.temp.name) / "metadata.json"
        self.metadata.write_text(
            json.dumps(
                {
                    "hermesVersion": "test",
                    "hermesRef": "test",
                    "hermesCommit": "1234567",
                    "platform": "macos",
                    "arch": "arm64",
                }
            ),
            encoding="utf-8",
        )
        self.manifest = Path(self.temp.name) / "MANIFEST.json"
        self.assertEqual(create_manifest(self.root, self.manifest, self.metadata), 0)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_clean_payload_verifies(self) -> None:
        self.assertEqual(verify_manifest(self.root, self.manifest), 0)

    def test_modified_file_is_rejected(self) -> None:
        (self.root / "a.txt").write_text("tampered", encoding="utf-8")
        self.assertEqual(verify_manifest(self.root, self.manifest), 1)

    def test_unexpected_file_is_rejected(self) -> None:
        (self.root / "extra.py").write_text("malicious", encoding="utf-8")
        self.assertEqual(verify_manifest(self.root, self.manifest), 1)

    def test_parent_path_in_manifest_is_rejected(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["files"][0]["path"] = "../outside.txt"
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        self.assertEqual(verify_manifest(self.root, self.manifest), 1)

    def test_symlink_target_must_remain_inside_payload(self) -> None:
        self.assertTrue(symlink_target_within_root("node/bin/npm", "../lib/npm.js"))
        self.assertFalse(symlink_target_within_root("node/bin/npm", "../../../outside"))
        self.assertFalse(symlink_target_within_root("node/bin/npm", "/tmp/outside"))


class SanitizeSitePackagesTests(unittest.TestCase):
    def test_symlink_escape_detection(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve() / "site-packages"
            link = root / "pkg" / "native.so"
            self.assertFalse(symlink_escapes_root(link, Path("../lib/native.so"), root))
            self.assertTrue(symlink_escapes_root(link, Path("../../../outside.so"), root))

    def test_editable_paths_and_bytecode_are_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "site-packages"
            dist_info = root / "pkg.dist-info"
            cache = root / "__pycache__"
            dist_info.mkdir(parents=True)
            cache.mkdir()
            forbidden = "/private/tmp/build/source"
            (root / "__editable__.hermes.pth").write_text(forbidden, encoding="utf-8")
            (dist_info / "direct_url.json").write_text(
                json.dumps({"url": f"file://{forbidden}"}), encoding="utf-8"
            )
            (cache / "x.pyc").write_bytes(b"bytecode")
            (root / "safe.pth").write_text("import safe_hook\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "sanitize_site_packages.py"),
                    str(root),
                    "--forbid",
                    forbidden,
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "__editable__.hermes.pth").exists())
            self.assertFalse((dist_info / "direct_url.json").exists())
            self.assertFalse(cache.exists())
            self.assertTrue((root / "safe.pth").exists())


class RelocateMachoTests(unittest.TestCase):
    def test_loader_relative_uses_binary_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            binary = root / "bin" / "python3.11"
            target = root / "lib" / "libpython3.11.dylib"
            self.assertEqual(
                loader_relative(str(target), binary),
                "@loader_path/../lib/libpython3.11.dylib",
            )

    def test_inside_rejects_sibling_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve() / "runtime"
            self.assertTrue(inside(str(root / "lib" / "safe.dylib"), root))
            self.assertFalse(inside(str(root.parent / "outside.dylib"), root))


if __name__ == "__main__":
    unittest.main()
