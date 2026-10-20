#!/usr/bin/env python3
"""Offline TinyPNG input/output regression tests. Run: python3 tests/test_tinypng_inputs.py"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "devkit/Resources/TinyPNG/tinypng.py"
spec = importlib.util.spec_from_file_location("tinypng", SCRIPT)
tinypng = importlib.util.module_from_spec(spec)
# These cases must never install dependencies or send network requests.
mock_requests = MagicMock()
mock_requests.exceptions.RequestException = type("RequestException", (OSError,), {})
with patch.dict(sys.modules, {
    "requests": mock_requests,
    "urllib3": MagicMock(),
    "urllib3.util": MagicMock(),
    "urllib3.util.retry": MagicMock(),
}):
    spec.loader.exec_module(tinypng)


class TinyPNGInputsTests(unittest.TestCase):
    def test_local_write_error_exits_without_uploading_again(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "photo.png"
            source.write_bytes(b"original" * 100)
            session = MagicMock()
            session.post.return_value.status_code = 201
            session.post.return_value.json.return_value = {"output": {"url": "https://example.invalid/result"}}
            session.get.return_value.status_code = 200
            session.get.return_value.content = b"compressed"
            with patch.object(sys, "argv", [str(SCRIPT), str(source)]), \
                 patch.object(tinypng, "create_session", return_value=session), \
                 patch.object(tinypng, "write_image_atomically", side_effect=PermissionError("denied")), \
                 contextlib.redirect_stdout(io.StringIO()) as output, \
                 self.assertRaises(SystemExit) as exit_result:
                tinypng.main()
            self.assertEqual(exit_result.exception.code, 1)
            self.assertEqual(session.post.call_count, 1)
            self.assertEqual(session.get.call_count, 1)
            self.assertNotIn("第 2 轮", output.getvalue())
            self.assertEqual(source.read_bytes(), b"original" * 100)
            failure_file = next(Path(temporary).glob("photo_*/_failed.json"))
            self.assertFalse(json.loads(failure_file.read_text())[0]["retryable"])

    def test_retry_rounds_exclude_terminal_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = [root / "local.png", root / "network.png"]
            for source in sources:
                source.write_bytes(b"original")
            failed = [dict(src=str(source), dst=str(root / (source.stem + "-output.png")),
                           before=8, after=0, ok=False, error="failure", retryable=index == 1)
                      for index, source in enumerate(sources)]
            with patch.object(sys, "argv", [str(SCRIPT), *map(str, sources)]), \
                 patch.object(tinypng, "create_session"), \
                 patch.object(tinypng.time, "sleep"), \
                 patch.object(tinypng, "run_batch", side_effect=[([], failed, 16, 16), ([{}], [], 8, 4)]) as batch, \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
                tinypng.main()
            self.assertEqual(exit_result.exception.code, 1)
            self.assertEqual(batch.call_count, 2)
            self.assertEqual(batch.call_args.args[0], [(sources[1], Path(failed[1]["dst"]))])

    def test_atomic_write_replaces_complete_image_and_preserves_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "photo.png"
            destination.write_bytes(b"original")
            destination.chmod(0o640)
            tinypng.write_image_atomically(destination, b"complete-result")
            self.assertEqual(destination.read_bytes(), b"complete-result")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(Path(temporary).iterdir()), [destination])

    def test_write_failure_preserves_original_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "photo.png"
            destination.write_bytes(b"original")
            with patch.object(tinypng.os, "fsync", side_effect=OSError("disk full")), self.assertRaises(OSError):
                tinypng.write_image_atomically(destination, b"incomplete-result")
            self.assertEqual(destination.read_bytes(), b"original")
            self.assertEqual(list(Path(temporary).iterdir()), [destination])

    def test_commit_failure_preserves_original_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "photo.png"
            destination.write_bytes(b"original")
            with patch.object(tinypng.os, "replace", side_effect=PermissionError("denied")), self.assertRaises(OSError):
                tinypng.write_image_atomically(destination, b"complete-result")
            self.assertEqual(destination.read_bytes(), b"original")
            self.assertEqual(list(Path(temporary).iterdir()), [destination])

    def invoke(self, paths):
        with patch.object(sys, "argv", [str(SCRIPT), *map(str, paths), "--min-size-kb", "100"]), \
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
