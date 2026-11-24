"""Which external tools the shell-script tests can use (Saturday 2026-11-14 item 5).

On the jumpbox the suite printed 37 bash environment errors and 0 failures on 2026-11-13: the tests that run bash, jq or
perl errored instead of skipping. A tool counts as available when shutil.which finds it AND a trivial probe exits 0, so a
stub that is on PATH but can't run (on Windows, System32\\bash.exe with no WSL distribution) also skips cleanly.
"""
from __future__ import annotations

import shutil
import subprocess
from functools import lru_cache


@lru_cache(maxsize=None)
def usable(tool: str, *probe: str) -> bool:
    path = shutil.which(tool)
    if not path:
        return False
    try:
        return subprocess.run([path, *probe], capture_output=True, timeout=15).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def have_bash() -> bool:
    return usable("bash", "-c", "true")


def have_jq() -> bool:
    return usable("jq", "-n", "1")


def have_perl() -> bool:
    return usable("perl", "-e", "1")
