"""Tests for agent/tests/tooling.py: a missing or broken tool makes the shell tests skip, not error (item 5)."""
from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tooling  # noqa: E402


class Usable(unittest.TestCase):
    def setUp(self):
        tooling.usable.cache_clear()

    def tearDown(self):
        tooling.usable.cache_clear()

    def test_missing_tool(self):
        with mock.patch.object(tooling.shutil, "which", return_value=None):
            self.assertFalse(tooling.have_bash())

    def test_a_stub_on_path_that_fails_is_not_usable(self):
        """Like System32\\bash.exe with no WSL distribution: found by which, but it can't run."""
        with tempfile.TemporaryDirectory() as d:
            stub = Path(d) / "brokentool"
            stub.write_text("#!/bin/sh\nexit 1\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            with mock.patch.dict(os.environ, {"PATH": d}):
                self.assertFalse(tooling.usable("brokentool", "-c", "true"))

    def test_a_path_that_cannot_execute_is_not_usable(self):
        with mock.patch.object(tooling.shutil, "which", return_value="/nonexistent/bash"):
            self.assertFalse(tooling.usable("bash", "-c", "true"))

    def test_a_working_tool_is_usable(self):
        self.assertTrue(tooling.usable(Path(sys.executable).name if os.name == "nt" else sys.executable, "-c", "0"))


if __name__ == "__main__":
    unittest.main()
