#!/usr/bin/env python3
"""Offline TinyPNG input/output regression tests. Run: python3 tests/test_tinypng_inputs.py"""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "devkit/Resources/TinyPNG/tinypng.py"
spec = importlib.util.spec_from_file_location("tinypng", SCRIPT)
tinypng = importlib.util.module_from_spec(spec)
# These cases must never install dependencies or send network requests.
with patch.dict(sys.modules, {
    "requests": MagicMock(),
    "urllib3": MagicMock(),
    "urllib3.util": MagicMock(),
    "urllib3.util.retry": MagicMock(),
}):
    spec.loader.exec_module(tinypng)


class TinyPNGInputsTests(unittest.TestCase):
    def invoke(self, paths):
        with patch.object(sys, "argv", [str(SCRIPT), *map(str, paths)]), \
             patch.object(tinypng, "start_parent_watchdog"), \
             patch.object(tinypng, "create_session", side_effect=AssertionError("Unexpected upload")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            tinypng.main()
        return output.getvalue()

    def test_single_skipped_image_is_copied(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "small.png"
            image.write_bytes(b"single")
            self.invoke([image])
            outputs = list(root.glob("small_*/small.png"))
            self.assertEqual(len(outputs), 1)
            self.assertEqual(outputs[0].read_bytes(), b"single")

    def test_same_named_roots_keep_both_images_and_deduplicate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "one" / "images"
            second = root / "two" / "images"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            (first / "same.png").write_bytes(b"first")
            (second / "same.png").write_bytes(b"second")
            output = self.invoke([first, second, first / "same.png", first])
            self.assertIn("图片数量: 2", output)
            outputs = list((root / "one").glob("TinyPNG_*/**/*.png"))
            self.assertEqual(len(outputs), 2)
            self.assertEqual({image.read_bytes() for image in outputs}, {b"first", b"second"})

    def test_multiple_files_reach_the_processing_batch_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            images = [root / "first.png", root / "second.jpg"]
            for image in images:
                image.write_bytes(b"x" * 102400)
            with patch.object(sys, "argv", [str(SCRIPT), *map(str, images), str(images[0])]), \
                 patch.object(tinypng, "start_parent_watchdog"), \
                 patch.object(tinypng, "create_session"), \
                 patch.object(tinypng, "run_batch", return_value=([], [], 204800, 102400)) as batch, \
                 contextlib.redirect_stdout(io.StringIO()):
                tinypng.main()
            tasks = batch.call_args.args[0]
            self.assertEqual({source for source, _ in tasks}, {image.resolve() for image in images})
            self.assertEqual(len(tasks), 2)
            self.assertEqual(len({destination for _, destination in tasks}), 2)


if __name__ == "__main__":
    unittest.main()
