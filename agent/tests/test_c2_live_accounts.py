"""Offline tests for scripts/lib/account_enabled.sh and its use in scripts/c2_live.sh (item 29, C2).

No Azure or Graph call: az is a stub shell function, and every object ID is fake. Run from the repo root:

    python3 -m unittest discover -s agent/tests -v
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tooling import have_bash  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "lib" / "account_enabled.sh"
C2_LIVE = REPO / "scripts" / "c2_live.sh"
OID = "test-oid-alder"
T_OID = "test-oid-admin"

# Stand-ins for what c2_live.sh provides (az, say, fail, mask), then the lib, then the call under test as "$@".
# The az stub logs its arguments to $CALLS, then returns $STUB_RC or prints $STUB_OUT.
HARNESS = r'''
set -uo pipefail
az() {
  printf '%s\n' "$*" >>"$CALLS"
  [ "$STUB_RC" = 0 ] || return "$STUB_RC"
  printf '%s' "$STUB_OUT"
}
say() { echo "$*"; }
fail() { say "STOP: $*"; exit 1; }
mask() { printf '%s...%s' "${1:0:4}" "${1: -4}"; }
show_enabled() { enabled_or_stop "$@"; echo "ENABLED=$ENABLED"; }
. "$LIB"
"$@"
'''


NEEDS_BASH = unittest.skipUnless(have_bash(), "bash not available")


def user(oid: str = OID, **props: object) -> str:
    return json.dumps({"id": oid, **props})


def run(*call: str, stub_out: str = "", stub_rc: int = 0, stdin: str = "") -> tuple[subprocess.CompletedProcess, str]:
    with tempfile.TemporaryDirectory() as tmp:
        calls = Path(tmp) / "calls.txt"
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LIB": str(LIB), "CALLS": str(calls),
               "STUB_OUT": stub_out, "STUB_RC": str(stub_rc)}
        proc = subprocess.run(["bash", "-c", HARNESS, "harness", *call], input=stdin, capture_output=True,
                              text=True, env=env, timeout=20)
        logged = calls.read_text() if calls.exists() else ""
    return proc, logged


@NEEDS_BASH
class ParseEnabled(unittest.TestCase):
    def test_01_true(self):
        proc, _ = run("parse_enabled", stdin='{"accountEnabled":true}')
        self.assertEqual((proc.returncode, proc.stdout), (0, "true\n"))

    def test_02_false(self):
        proc, _ = run("parse_enabled", stdin='{"accountEnabled":false}')
        self.assertEqual((proc.returncode, proc.stdout), (0, "false\n"))

    def test_03_missing(self):
        for body in ('{}', '{"accountEnabled":null}', '{"accountEnabled":"true"}',
                     '{"error":{"code":"Request_ResourceNotFound"}}'):
            with self.subTest(body=body):
                proc, _ = run("parse_enabled", stdin=body)
                self.assertEqual(proc.stdout, "MISSING\n")

    def test_04_error(self):
        for body in ("not json", "", '{"accountEnabled":true}{"accountEnabled":false}', "[]"):
            with self.subTest(body=body):
                proc, _ = run("parse_enabled", stdin=body)
                self.assertEqual(proc.stdout, "ERROR\n")


@NEEDS_BASH
class GraphEnabled(unittest.TestCase):
    def test_05_az_failure_is_error(self):
        proc, _ = run("graph_enabled", OID, stub_rc=1)
        self.assertEqual((proc.returncode, proc.stdout), (0, "ERROR\n"))

    def test_06_wrong_or_no_id_is_error(self):
        for body in (user("test-oid-other", accountEnabled=True), json.dumps({"accountEnabled": True}), "{}"):
            with self.subTest(body=body):
                proc, _ = run("graph_enabled", OID, stub_out=body)
                self.assertEqual(proc.stdout, "ERROR\n")
        proc, _ = run("graph_enabled", OID, stub_out=user(OID.upper(), accountEnabled=False))
        self.assertEqual(proc.stdout, "false\n", "the id comparison ignores case")

    def test_07_request_uses_select(self):
        proc, logged = run("graph_enabled", OID, stub_out=user(accountEnabled=True))
        self.assertEqual(proc.stdout, "true\n")
        self.assertEqual(logged, "rest --method get --url https://graph.microsoft.com/v1.0/users/test-oid-alder"
                                 "?$select=id,accountEnabled -o json\n")


@NEEDS_BASH
class EnabledOrStop(unittest.TestCase):
    def test_08_true_and_false_set_enabled(self):
        for value, text in ((False, "false"), (True, "true")):
            with self.subTest(value=value):
                proc, _ = run("show_enabled", OID, "case manager alder", stub_out=user(accountEnabled=value))
                self.assertEqual((proc.returncode, proc.stdout), (0, f"ENABLED={text}\n"))

    def test_09_missing_or_error_fails_closed(self):
        for kwargs, got in (({"stub_out": user()}, "MISSING"), ({"stub_out": "{}"}, "ERROR"),
                            ({"stub_out": "not json"}, "ERROR"), ({"stub_rc": 1}, "ERROR")):
            with self.subTest(kwargs=kwargs):
                proc, _ = run("show_enabled", OID, "case manager alder", **kwargs)
                self.assertEqual(proc.returncode, 1)
                self.assertEqual(proc.stdout,
                                 f"STOP: case manager alder accountEnabled read as {got}; failing closed (stderr file)\n")
                self.assertNotIn("ENABLED=", proc.stdout)


@NEEDS_BASH
class PositiveControl(unittest.TestCase):
    def test_10_true_passes(self):
        proc, _ = run("positive_control", T_OID, stub_out=user(T_OID, accountEnabled=True))
        self.assertEqual((proc.returncode, proc.stdout),
                         (0, "ok | positive control: T (test...dmin) accountEnabled | true\n"))

    def test_11_anything_else_stops(self):
        for kwargs, got in (({"stub_out": user(T_OID, accountEnabled=False)}, "false"),
                            ({"stub_out": user(T_OID)}, "MISSING"), ({"stub_rc": 1}, "ERROR")):
            with self.subTest(got=got):
                proc, _ = run("positive_control", T_OID, **kwargs)
                self.assertEqual(proc.returncode, 1)
                self.assertEqual(proc.stdout,
                                 f"STOP: positive control failed: T (test...dmin) accountEnabled read as {got}\n")


class C2LiveWiring(unittest.TestCase):
    def test_12_c2_live_uses_the_lib_in_this_shell(self):
        text = C2_LIVE.read_text()
        self.assertNotIn("az ad user show", text)
        self.assertIn('LIB="$REPO/scripts/lib/account_enabled.sh"', text)
        self.assertRegex(text, r'(?m)^\. "\$LIB"$')
        body = re.search(r"(?ms)^case_managers\(\) \{.*?^\}", text).group(0)
        self.assertLess(body.index('positive_control "$ME"'), body.index("while "))
        self.assertIn('enabled_or_stop "$oid"', body)
        for call in ("$(enabled_or_stop", "$(positive_control", "$(case_managers", "| case_managers"):
            self.assertNotIn(call, text)
        self.assertEqual(len(re.findall(r"(?m)^  case_managers false$", text)), 2)
        final = re.search(r"(?ms)^final\)\n(.*?)^  ;;", text).group(1)
        last = final.index("case_managers false")
        for earlier in ("hourly", "role assignments left on Bastion scopes", "billing"):
            self.assertLess(final.index(earlier), last, earlier)
        self.assertEqual(final.rstrip().splitlines()[-1].strip(), "case_managers false")
        lib = LIB.read_text()
        self.assertNotRegex(lib, r"(?m)^\s*az\(\)", "the lib must use c2_live.sh's az wrapper")
        self.assertNotIn("//", re.sub(r"https://\S+", "", lib), "no jq // alternative operator")


if __name__ == "__main__":
    unittest.main()
