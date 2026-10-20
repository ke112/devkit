#!/usr/bin/env python3
"""Offline runtime-isolation checks. Run: python3 tests/test_image_python_runtime.py"""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "devkit/Resources/DependencyBootstrap/image_python_runtime.py"
spec = importlib.util.spec_from_file_location("image_python_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ImagePythonRuntimeTests(unittest.TestCase):
    def test_check_missing_environment_does_not_create_or_install_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "runtime"
            result = subprocess.run([sys.executable, str(SCRIPT), "--check", "--runtime-root", str(directory)],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertFalse(directory.exists())

    def test_managed_reexecution_resolves_to_same_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = runtime.environment_directory(runtime.REQUIREMENTS, Path(temporary))
            with patch.object(sys, "executable", str(directory / "bin/python3")):
                self.assertEqual(runtime.environment_directory(runtime.REQUIREMENTS, Path(temporary)), directory)

    def test_lock_change_selects_new_environment_instead_of_mutating_shared_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            requirements = root / "requirements.txt"
            requirements.write_text("requests==2.32.5\n")
            original = runtime.environment_directory(requirements, root)
            requirements.write_text("requests==2.34.2\n")
            self.assertNotEqual(runtime.environment_directory(requirements, root), original)


if __name__ == "__main__":
    unittest.main()
