"""Offline checks for D5 (w3-kql, C2): the KQL file, the Sentinel rule that loads it, and the smoke rows.
No Azure calls. Run from the repo root:  python3 -m unittest discover -s agent/tests -v
"""
from __future__ import annotations

import importlib.util
import io
import re
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KQL = ROOT / "detections" / "d5-entitlement-denials.kql"
BICEP = ROOT / "infra" / "sentinel.bicep"
LOAD = "loadTextContent('../detections/d5-entitlement-denials.kql')"
ALLOWED = ["caller", "conversation_id", "deny_count", "first_seen", "last_seen", "record_ids", "scenario", "redteam_id"]


def code(text: str) -> str:  # KQL without // comments
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


class D5Kql(unittest.TestCase):
    def test_01_file_exists(self):
        self.assertTrue(KQL.is_file())

    def test_02_projects_only_the_allowed_columns_last(self):
        body = code(KQL.read_text())
        projects = re.findall(r"(?m)^\|\s*project\s+(.+)$", body)
        self.assertEqual(len(projects), 1)
        self.assertEqual([c.strip() for c in projects[0].split(",")], ALLOWED)
        self.assertTrue(body.rstrip().splitlines()[-1].lstrip().startswith("| project "))

    def test_03_never_reason_or_detail(self):
        self.assertNotRegex(code(KQL.read_text()), r"\b(reason|detail)\b")

    def test_04_deny_and_threshold(self):
        body = code(KQL.read_text())
        self.assertIn('decision == "deny"', body)
        self.assertRegex(body, r"deny_count\s*>=\s*2")
        self.assertRegex(body, r"by caller, conversation_id")

    def test_05_ingestion_overlap(self):
        self.assertIn("ago(rule_frequency + 2m)", code(KQL.read_text()))


class D5Rule(unittest.TestCase):
    def test_06_bicep_loads_that_same_file(self):
        text = BICEP.read_text()
        self.assertEqual(text.count(LOAD), 1)
        self.assertEqual((BICEP.parent / "../detections/d5-entitlement-denials.kql").resolve(), KQL.resolve())

    def test_07_schedule_matches_the_kql(self):
        text, kql = BICEP.read_text(), KQL.read_text()
        self.assertIn("queryFrequency: 'PT5M'", text)
        self.assertIn("let rule_frequency = 5m;", kql)
        self.assertIn("queryPeriod: 'PT1H'", text)
        self.assertIn("let session_window = 1h;", kql)

    def test_08_rule_settings(self):
        text = BICEP.read_text()
        for needle in ("triggerOperator: 'GreaterThan'", "triggerThreshold: 0", "createIncident: true",
                       "suppressionEnabled: false", "reopenClosedIncident: false",
                       "{ identifier: 'AadUserId', columnName: 'caller' }"):
            self.assertIn(needle, text)
        details = re.search(r"(?s)customDetails: \{(.*?)\}", text).group(1)
        columns = re.findall(r"'(\w+)'", details)
        self.assertTrue(columns)
        for column in columns:
            self.assertIn(column, ALLOWED)
        self.assertNotRegex(details, r"reason|detail")


_spec = importlib.util.spec_from_file_location("smoke_d5", ROOT / "scripts" / "smoke_d5.py")
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)


class D5Smoke(unittest.TestCase):
    def test_09_two_positive_one_negative(self):
        rows = smoke.build_smoke_rows("20261110T000000Z", "2026-11-10T00:00:00.000+00:00")
        convs = [r["conversation_id"] for r in rows]
        self.assertEqual(convs, ["d5smoke-20261110T000000Z-pos"] * 2 + ["d5smoke-20261110T000000Z-neg"])
        self.assertEqual({r["decision"] for r in rows}, {"deny"})
        self.assertEqual({r["caller"] for r in rows}, {smoke.SMOKE_CALLER})
        self.assertEqual({r["scenario"] for r in rows}, {"smoke"})
        self.assertEqual({r["redteam_id"] for r in rows}, {"d5smoke-20261110T000000Z"})
        self.assertTrue(all(r["record_id"].startswith("SMOKE-") for r in rows))

    def test_10_takes_no_arguments(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(smoke.main(["anything"]), 2)


if __name__ == "__main__":
    unittest.main()
