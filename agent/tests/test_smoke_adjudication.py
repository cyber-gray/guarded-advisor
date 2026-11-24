"""Tests for scripts/smoke_adjudication.py (w2-privread verification, C8). No Azure calls.

    python3 -m unittest discover -s agent/tests -v
"""
from __future__ import annotations

import importlib.util
import inspect
import io
import re
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path

AGENT = Path(__file__).resolve().parent.parent
ROOT = AGENT.parent
sys.path.insert(0, str(AGENT))

import pack  # noqa: E402
from adjudicate import build_row  # noqa: E402

_spec = importlib.util.spec_from_file_location("smoke_adjudication", ROOT / "scripts" / "smoke_adjudication.py")
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)

CALLER = "00000000-0000-4000-8000-00000000abcd"


class SmokeRow(unittest.TestCase):
    def test_values_are_fixed(self):
        row = smoke.build_smoke_row(caller=CALLER, scenario="larkfield")
        self.assertEqual(row["record_id"], "SMOKE")
        self.assertEqual(row["conversation_id"], "SMOKE")
        self.assertEqual(row["outcome"], "agree")
        self.assertEqual(row["rationale_code"], "other")
        self.assertEqual(row["caller"], CALLER)

    def test_no_claim_or_outcome_input(self):
        self.assertEqual(set(inspect.signature(smoke.build_smoke_row).parameters), {"caller", "scenario"})

    def test_same_columns_as_adjudicate(self):
        config = pack.load_config("larkfield")
        caseload = next(iter(pack.load_entitlements("larkfield").items()))
        real = build_row(caller=caseload[0], entitlements=pack.load_entitlements("larkfield"), config=config,
                         conversation_id="conv_test", claim_id=sorted(caseload[1])[0], outcome="agree",
                         rationale_code="matches_source")
        self.assertEqual(set(smoke.build_smoke_row(caller=CALLER, scenario="larkfield")), set(real))

    def test_smoke_id_isnt_a_claim_id(self):
        # SMOKE can never collide with a real record: it fails the pack's claim ID pattern.
        self.assertIsNone(re.match(pack.load_config("larkfield")["record_tool"]["id_pattern"], "SMOKE"))

    def test_refuses_any_argument_before_signing_in(self):
        for argv in (["--claim-id", "LM-CLM-2026-0007"], ["--outcome", "rejected"], ["anything"]):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()) as err:
                self.assertEqual(smoke.main(argv), 2)
                self.assertIn("takes no arguments", err.getvalue())


class NotReachableFromTheAgent(unittest.TestCase):
    def test_no_agent_module_references_it(self):
        """A string-search tripwire, not proof: it catches a direct import or reference by name, not dynamic loading."""
        for path in AGENT.glob("*.py"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(module=path.name):
                self.assertNotIn("smoke_adjudication", text)
                self.assertNotIn("build_smoke_row", text)

    def test_not_a_registered_tool(self):
        names = re.findall(r'"name":\s*"([^"]+)"', (ROOT / "scenarios" / "larkfield" / "agent.json").read_text())
        self.assertTrue(names)
        for name in names:
            with self.subTest(tool=name):
                self.assertNotIn("smoke", name.lower())
                self.assertNotIn("adjudicat", name.lower())


class C8QueryExcludesSmoke(unittest.TestCase):
    def test_filter_before_summarize(self):
        kql = (ROOT / "detections" / "c8-agree-override-rate.kql").read_text(encoding="utf-8")
        body = "\n".join(line for line in kql.splitlines() if not line.lstrip().startswith("//"))
        self.assertIn('| where record_id != "SMOKE"', body)
        self.assertLess(body.index('record_id != "SMOKE"'), body.index("summarize"))


if __name__ == "__main__":
    unittest.main()
