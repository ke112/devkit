#!/usr/bin/env python3
"""Offline WebP file-safety regressions. Run: python3 tests/test_webp_safety.py"""

import contextlib
import errno
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "devkit/Resources/WebPConvert/webp_convert.py"
spec = importlib.util.spec_from_file_location("webp_convert", SCRIPT)
webp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webp)


class WebPSafetyTests(unittest.TestCase):
    def test_concurrent_same_stem_preserves_existing_webp_and_both_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = [root / "photo.png", root / "photo.jpg"]
            expected = {sources[0]: b"png-result", sources[1]: b"jpg-result"}
            for source in sources:
                source.write_bytes(b"original" * 100)
            destination = root / "photo.webp"
            destination.write_bytes(b"existing-webp")
            barrier = threading.Barrier(2)

            def encode(source, target, *_):
                target.write_bytes(expected[source])
                barrier.wait(timeout=5)
                return ""

            with patch.object(webp, "encode_webp", side_effect=encode), ThreadPoolExecutor(2) as pool:
                results = list(pool.map(lambda src: webp.convert_image(src, destination, 80, 0, True), sources))

            self.assertEqual(destination.read_bytes(), b"existing-webp")
            self.assertEqual(len({result["dst"] for result in results}), 2)
            for source, result in zip(sources, results):
                self.assertTrue(result["ok"], result)
                self.assertEqual(Path(result["dst"]).read_bytes(), expected[source])
                self.assertFalse(source.exists())
            self.assertEqual(list(root.glob(".devkit-webp-*")), [])

    def test_failed_publish_keeps_original_and_cleans_temporary_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "photo.png"
            source.write_bytes(b"original" * 100)

            def encode(_, target, *__):
                target.write_bytes(b"compressed")
                return ""

            with patch.object(webp, "encode_webp", side_effect=encode), \
                 patch.object(webp, "rename_exclusive", side_effect=OSError(errno.ENOSPC, "disk full")):
                result = webp.convert_image(source, root / "photo.webp", 80, 0, True)
            self.assertFalse(result["ok"])
            self.assertEqual(source.read_bytes(), b"original" * 100)
            self.assertEqual(list(root.iterdir()), [source])

    def test_unsupported_exclusive_rename_falls_back_without_hard_links_or_overwriting(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "temporary"
            source.write_bytes(b"new-result")
            destination = root / "photo.webp"
            destination.write_bytes(b"existing")
            with patch.object(webp, "rename_exclusive", side_effect=OSError(errno.ENOTSUP, "unsupported")), \
                 patch.object(webp.os, "link", side_effect=AssertionError("Hard links must not be used")):
                result = webp.publish_without_replacing(source, destination)
            self.assertEqual(destination.read_bytes(), b"existing")
            self.assertEqual(result.read_bytes(), b"new-result")
            self.assertEqual(result.name, "photo_2.webp")

    def test_fallback_write_failure_removes_only_its_new_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "temporary"
            source.write_bytes(b"complete-result")
            destination = root / "photo.webp"
            with patch.object(webp, "rename_exclusive", side_effect=OSError(errno.ENOTSUP, "unsupported")), \
                 patch.object(webp.os, "fsync", side_effect=OSError(errno.ENOSPC, "disk full")), \
                 self.assertRaises(OSError):
                webp.publish_without_replacing(source, destination)
            self.assertFalse(destination.exists())
            self.assertEqual(source.read_bytes(), b"complete-result")

    def test_output_mode_preserves_existing_webp_before_converting_same_stem(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = root / "inputs"
            inputs.mkdir()
            (inputs / "photo.webp").write_bytes(b"existing-webp")
            (inputs / "photo.png").write_bytes(b"original" * 100)

            def encode(_, target, *__):
                target.write_bytes(b"converted")
                return ""

            with patch.object(sys, "argv", [str(SCRIPT), str(inputs), "--min-size-kb", "0"]), \
                 patch.object(webp, "cwebp_available", return_value=True), \
                 patch.object(webp, "encode_webp", side_effect=encode), \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
                webp.main()
            self.assertEqual(exit_result.exception.code, 0)
            output = next(root.glob("inputs_webp_*"))
            self.assertEqual((output / "photo.webp").read_bytes(), b"existing-webp")
            self.assertEqual((output / "photo_2.webp").read_bytes(), b"converted")
            self.assertTrue((inputs / "photo.png").exists())


if __name__ == "__main__":
    unittest.main()
