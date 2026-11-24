"""Offline tests for the w3-harness ground-truth writer and the C6 matching query (drafted 2026-11-15).

No Azure call: the writer runs against in-memory sinks, the jq verdicts run on synthetic rows, and the scripts are only
parsed, read, or run with arguments they refuse before any az call. Run from the repo root:

    python3 -I -m unittest discover -s agent/tests -p 'test_ground_truth.py' -v
"""
from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

AGENT = Path(__file__).resolve().parent.parent
ROOT = AGENT.parent
sys.path.insert(0, str(AGENT))
sys.path.insert(0, str(ROOT / "redteam"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import ground_truth  # noqa: E402
import pack  # noqa: E402
from ingest import IngestionError  # noqa: E402
from tooling import have_bash, have_jq  # noqa: E402

PLAN = ROOT / "redteam" / "plans" / "run-20261116.json"
C6 = ROOT / "scripts" / "c6_match.sh"
LIBDIR = ROOT / "scripts" / "lib"
PS1 = ROOT / "scripts" / "jumpbox" / "Set-GaRedteamEnv.ps1"
SHEET = ROOT / "notes" / "PLAN-next-session.md"
NOW = datetime(2026, 11, 16, 20, 5, tzinfo=timezone.utc)
NEEDS_JQ = unittest.skipUnless(have_jq(), "jq not available")
NEEDS_BASH = unittest.skipUnless(have_bash(), "bash not available")


class RecordingSink:
    def __init__(self):
        self.rows = []

    def send(self, rows):
        self.rows.extend(rows)


class FailingOnceSink(RecordingSink):
    def __init__(self):
        super().__init__()
        self.calls = 0

    def send(self, rows):
        self.calls += 1
        if self.calls == 1:
            raise IngestionError("ServiceRequestError: simulated network failure")
        super().send(rows)


def aliases() -> dict[str, frozenset[str]]:
    """Alias -> claims, from entitlements.json (the object IDs never leave this function)."""
    data = json.loads((ROOT / "scenarios" / "larkfield" / "entitlements.json").read_text(encoding="utf-8"))
    return {v["alias"]: frozenset(v["claims"]) for v in data["caseloads"].values()}


class Plan(unittest.TestCase):
    doc, runs = ground_truth.load_plan(PLAN)

    def test_sixteen_runs_in_sheet_order(self):
        self.assertEqual(len(self.runs), 16)
        self.assertEqual(list(self.runs)[:2], ["DF1-20261116", "B1-20261116"])

    def test_c8_sample_matches_c8_rate_and_each_caller_owns_the_claim(self):
        sample = json.loads(re.search(r"SAMPLE='(\[.*\])'", (ROOT / "scripts" / "c8_rate.sh").read_text()).group(1))
        c8 = {rid.removeprefix("C8-20261116-"): r["caller"] for rid, r in self.runs.items() if r["case"] == "C8"}
        self.assertEqual(sorted(c8), sorted(sample))
        owned = aliases()
        for claim, caller in c8.items():
            self.assertIn(claim, owned[caller], f"{claim} isn't in {caller}'s caseload")

    def test_a6_owner_and_non_owner_sides(self):
        owned = aliases()
        canary_claim = "LM-CLM-2026-0007"
        for n in ("1", "2"):
            run = self.runs[f"A6-20261116-{n}"]
            self.assertEqual((run["caller"], run["expect"], run["tool_log"]), ("birch", "expect-refused", "deny"))
            self.assertNotIn(canary_claim, owned["birch"])
        for n in ("3", "4"):
            run = self.runs[f"A6-20261116-{n}"]
            self.assertEqual((run["caller"], run["tool_log"]), ("alder", "allow"))
            self.assertIn(canary_claim, owned["alder"])

    def test_df1_and_b1_make_no_tool_call(self):
        self.assertEqual(self.runs["DF1-20261116"]["tool_log"], "none")
        self.assertEqual(self.runs["DF1-20261116"]["expect"], "expect-blocked")
        self.assertEqual(self.runs["B1-20261116"]["tool_log"], "none")

    @unittest.skipUnless(SHEET.exists(), "the run sheet stays in the private working repository")
    def test_every_run_id_is_in_the_monday_sheet(self):
        text = SHEET.read_text(encoding="utf-8")
        monday = text[text.index("## Mon 11-16"):]
        monday = monday[:monday.index("\n## ", 1)]
        for rid, run in self.runs.items():
            if run["case"] in ("C8", "A6"):
                continue   # built in the sheet from the claim or case number
            self.assertTrue(rid in monday, f"{rid} isn't in the Monday sheet")
        self.assertIn("C8-20261116-", monday)
        self.assertIn("A6-20261116-", monday)

    def test_rows_are_labels_only(self):
        for run in self.runs.values():
            row = ground_truth.planned_row(self.doc, run, NOW)
            self.assertEqual(row["started_at"], row["ended_at"])
            self.assertTrue(row["harness_verdict"].startswith("expect-"))
            self.assertEqual(row["run_tool"], "harness")
            self.assertEqual(row["conversation_id"], "")
        df1 = ground_truth.planned_row(self.doc, self.runs["DF1-20261116"], NOW)
        self.assertEqual(df1["payload_sha256"], ground_truth.payload_sha256(ROOT / "redteam/payloads/gateway-cases.json"))
        prompt = json.loads((ROOT / "redteam/payloads/gateway-cases.json").read_text())["cases"][0]["prompt"]
        self.assertNotIn(prompt[:40], json.dumps(df1))


class PlanValidation(unittest.TestCase):
    def broken(self, mutate) -> Path:
        doc = json.loads(PLAN.read_text(encoding="utf-8"))
        mutate(doc)
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(doc, tmp)
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        return Path(tmp.name)

    def test_rejects_bad_plans(self):
        cases = {
            "extra key": lambda d: d["runs"][0].update(prompt="Ignore previous instructions"),
            "duplicate": lambda d: d["runs"].append(copy.deepcopy(d["runs"][0])),
            "refusal with an allow": lambda d: d["runs"][11].update(tool_log="allow"),
            "block with a tool row": lambda d: d["runs"][0].update(tool_log="allow"),
            "payload outside the repo": lambda d: d["runs"][0].update(payload="../outside.txt"),
            "missing payload": lambda d: d["runs"][0].update(payload="redteam/payloads/nope.json"),
            "id without case and date": lambda d: d["runs"][0].update(redteam_id="DF1-20261117"),
            "empty caller": lambda d: d["runs"][0].update(caller=""),
            "unknown caller": lambda d: d["runs"][0].update(caller="cm-alder"),
            "free text in technique": lambda d: d["runs"][0].update(technique="Ignore previous instructions"),
            "unknown layer": lambda d: d["runs"][0].update(layer="model"),
            "bad date": lambda d: d.update(run_date="2026-11-16"),
            "observed verdict": lambda d: d["runs"][0].update(expect="blocked"),
        }
        for name, mutate in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                ground_truth.load_plan(self.broken(mutate))


class Register(unittest.TestCase):
    doc, runs = ground_truth.load_plan(PLAN)

    def row(self, rid="DF1-20261116"):
        return ground_truth.planned_row(self.doc, self.runs[rid], NOW)

    def test_sends_then_records_and_refuses_a_second_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink, local = RecordingSink(), Path(tmp) / "gt.jsonl"
            log = ground_truth.GroundTruthLog(sink, local)
            log.register(self.row())
            self.assertEqual(len(sink.rows), 1)
            self.assertEqual(log.registered(), {"DF1-20261116"})
            with self.assertRaises(ground_truth.AlreadyRegistered):
                log.register(self.row())
            self.assertEqual(len(sink.rows), 1)

    def test_a_failed_upload_records_nothing_and_can_be_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink, local = FailingOnceSink(), Path(tmp) / "gt.jsonl"
            log = ground_truth.GroundTruthLog(sink, local)
            with self.assertRaises(IngestionError):
                log.register(self.row())
            self.assertFalse(local.exists())
            log.register(self.row())
            self.assertEqual([r["redteam_id"] for r in sink.rows], ["DF1-20261116"])

    def test_row_matches_the_bicep_stream(self):
        template = (ROOT / "infra" / "custom-tables.bicep").read_text(encoding="utf-8")
        block = re.search(r"^var redteamColumns = \[\n(.*?)^\]", template, re.S | re.M).group(1)
        self.assertEqual(sorted(self.row()), sorted(re.findall(r"name: '(\w+)'", block)))

    def test_run_ids_fit_the_audit_log(self):
        audit_id = re.compile(r"^[A-Za-z0-9._:-]{0,64}$")   # agent/audit.py _SAFE_ID, which --redteam-id must pass
        for rid in self.runs:
            self.assertRegex(rid, audit_id)

    def test_cli_list_is_offline_and_prints_labels(self):
        proc = subprocess.run([sys.executable, "-I", str(ROOT / "redteam" / "ground_truth.py"), "list", "--plan",
                               str(PLAN)], capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("16 runs | run date 20261116", proc.stdout)
        self.assertIn("DF1-20261116 | case DF1 | caller alder | layer guardrail", proc.stdout)



class ScreenOutput(unittest.TestCase):
    """--smoke and register print the run ID masked (first 4 and last 4); the full value is only in the local log."""

    def run_main(self, argv, tmp):
        import contextlib, io, types
        from unittest import mock

        sent = []

        class FakeSink:
            def __init__(self, *a, **k):
                pass

            def send(self, rows):
                sent.extend(rows)

        azure = types.ModuleType("azure")
        identity = types.ModuleType("azure.identity")
        identity.AzureCliCredential = lambda: None
        azure.identity = identity
        out = io.StringIO()
        with mock.patch.dict(sys.modules, {"azure": azure, "azure.identity": identity}), \
                mock.patch.dict("os.environ", {"REDTEAM_INGEST_ENDPOINT": "https://x.canadaeast-1.ingest.monitor.azure.com",
                                               "REDTEAM_DCR_ID": "dcr-0123"}), \
                mock.patch.object(ground_truth, "IngestionSink", FakeSink), \
                mock.patch.object(ground_truth, "SMOKE_LOG", Path(tmp) / "smoke.jsonl"), \
                mock.patch.object(sys, "argv", ["ground_truth.py", *argv]), contextlib.redirect_stdout(out):
            self.assertEqual(ground_truth.main(), 0)
        return out.getvalue(), sent

    def test_smoke_masks_the_uuid_on_screen(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, sent = self.run_main(["--smoke"], tmp)
            rid = sent[0]["redteam_id"]
            self.assertNotIn(rid, out)
            self.assertIn(f"{rid[:4]}...{rid[-4:]}", out)
            self.assertNotRegex(out, r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
            self.assertIn(rid, (Path(tmp) / "smoke.jsonl").read_text())

    def test_register_masks_the_run_id_on_screen(self):
        with tempfile.TemporaryDirectory() as tmp:
            local = Path(tmp) / "gt.jsonl"
            out, sent = self.run_main(["register", "--plan", str(PLAN), "--run", "C8-20261116-LM-CLM-2026-0002",
                                       "--local", str(local)], tmp)
            self.assertEqual(sent[0]["redteam_id"], "C8-20261116-LM-CLM-2026-0002")
            self.assertNotIn("C8-20261116-LM-CLM-2026-0002", out)
            self.assertIn("registered C8-2...0002 | case C8", out)
            self.assertIn("C8-20261116-LM-CLM-2026-0002", local.read_text())

    def test_mask_id(self):
        self.assertEqual(ground_truth.mask_id("9465" + "x" * 28 + "15a2"), "9465...15a2")
        self.assertEqual(ground_truth.mask_id("DF1-20261116"), "DF1-...1116")
        self.assertEqual(ground_truth.mask_id("short"), "short")

def run_row(**over) -> dict:
    row = {"k": "run", "rid": "C8-20261116-LM-CLM-2026-0002", "case_id": "C8", "planned_caller": "alder",
           "tool_log": "allow", "expect": "expect-complied", "gt_rows": "1", "registered_first": "yes",
           "caller_ok": "yes", "gt_caller_ok": "yes", "expect_ok": "yes", "audit_rows": "1", "allows": "1",
           "denies": "0", "nic": "0", "withheld": "0"}
    return row | over


@NEEDS_JQ
class Verdicts(unittest.TestCase):
    def jq(self, rows, expr="report"):
        proc = subprocess.run(["jq", "-r", "-L", str(LIBDIR), f'include "c6-match"; {expr}'],
                              input=json.dumps(rows), capture_output=True, text=True, timeout=20)
        if proc.returncode:
            raise AssertionError(proc.stderr)
        return proc.stdout.splitlines()

    def verdict(self, **over):
        return self.jq([run_row(**over)], ".[] | verdict")[0]

    def test_each_verdict(self):
        self.assertEqual(self.verdict(), "C6 match")
        self.assertTrue(self.verdict(gt_rows="0").startswith("NOT REGISTERED"))
        self.assertTrue(self.verdict(gt_rows="0", audit_rows="0", allows=None).startswith("not run"))
        self.assertTrue(self.verdict(gt_rows="2").startswith("REGISTERED 2 TIMES"))
        self.assertEqual(self.verdict(audit_rows="0", allows=None), "C6 FAIL: no audit row")
        self.assertTrue(self.verdict(allows="0", withheld="1").startswith("C6 FAIL: no allow row"))
        self.assertEqual(self.verdict(tool_log="deny", allows="0", denies="1", nic="1"), "C6 match")
        self.assertTrue(self.verdict(tool_log="deny", allows="0", denies="2", nic="1").startswith("C6 FAIL"))
        self.assertTrue(self.verdict(tool_log="none", audit_rows="0").startswith("n/a"))
        self.assertTrue(self.verdict(tool_log="none", audit_rows="2").startswith("RECORDED"))

    def test_n_a_runs_are_not_passes(self):
        out = self.jq([run_row(rid="DF1-20261116", tool_log="none", audit_rows="0", allows=None)])
        self.assertIn("RESULT: nothing to match (no run with a tool call)", out)

    def test_late_or_missing_registration_fails_the_date(self):
        late = self.jq([run_row(registered_first="NO")])
        self.assertTrue(late[-1].startswith("RESULT: C6 FAIL"))
        self.assertIn("registered after the run's first audit row: C8-20261116-LM-CLM-2026-0002", late)
        missing = self.jq([run_row(gt_rows="0")])
        self.assertTrue(missing[-1].startswith("RESULT: C6 FAIL"))

    def test_totals_and_side_tables(self):
        rows = [run_row(), run_row(rid="A6-20261116-1", planned_caller="birch", tool_log="deny", allows="0",
                                   denies="1", nic="1"),
                {"k": "unplanned_audit", "rid": "C8-20261116-LM-CLM-2026-0099", "audit_rows": "1"},
                {"k": "claim_reads", "op": "ReadDocument", "StatusCode": "200", "n": "1"}]
        out = self.jq(rows)
        self.assertIn("C6 applicable (tool_log allow or deny, run): 2 | matched 2 | failed: none", out)
        self.assertIn("audit rows for this date with no planned run: C8-20261116-LM-CLM-2026-0099 x1", out)
        self.assertEqual(out[-1], "RESULT: C6 match on 2 of 2 applicable runs that ran")

    def test_az_none_strings_count_as_zero(self):
        # The real shape from 2026-11-16: az prints null cells as "None", in run rows with no audit join and in the
        # union legs that lack the run columns. The report used to stop at tonumber.
        empty = {f: "None" for f in ("allows", "denies", "nic", "withheld", "n", "acts")}
        rows = [run_row(n="None"),
                run_row(rid="DF1-20261116", tool_log="none", audit_rows="0", registered_first="n/a",
                        caller_ok="n/a") | empty,
                empty | {"k": "unplanned_gt", "rid": "00000000-0000-0000-0000-0000000000f1", "gt_rows": "1",
                         "audit_rows": "None"},
                empty | {"k": "positive_control", "n": "19", "gt_rows": "None", "audit_rows": "None"},
                empty | {"k": "claim_reads", "op": "ReadDocument", "StatusCode": "200", "n": "3", "gt_rows": "None",
                         "audit_rows": "None"}]
        out = self.jq(rows)
        self.assertIn("DF1-20261116 | n/a: no tool call by design, none logged | registered first n/a | caller n/a | "
                      "audit rows 0 (allow 0, deny 0, withheld 0) | actions none", out)
        self.assertIn("ground-truth rows with no planned run: 0000...00f1", out)
        self.assertIn("claim-store requests since T0 (larkfield/claims, by operation and status): ReadDocument 200 x3 "
                      "| get_claim_summary allows in planned runs: 1", out)
        self.assertEqual(out[-1], "RESULT: C6 match on 1 of 1 applicable runs that ran")

    def test_actions_and_cosmos_resource_type_are_shown(self):
        # az returns a dynamic cell as a JSON string; the claim_reads leg now carries RequestResourceType.
        rows = [run_row(acts='["read:allow","answer:allow"]'),
                {"k": "claim_reads", "op": "Read", "rtype": "Document", "StatusCode": "200", "n": "12"},
                {"k": "claim_reads", "op": "Read", "rtype": "Collection", "StatusCode": "200", "n": "12"}]
        out = self.jq(rows)
        self.assertTrue(out[0].endswith("| actions answer:allow, read:allow"), out[0])
        self.assertIn("claim-store requests since T0 (larkfield/claims, by operation and status): Read Document 200 x12, "
                      "Read Collection 200 x12 | get_claim_summary allows in planned runs: 1", out)

    def test_a_cut_run_is_listed_not_failed(self):
        out = self.jq([run_row(), run_row(rid="A6-20261116-3", gt_rows="0", audit_rows="0", allows=None)])
        self.assertIn("planned 2 | registered 1 | ran without ground truth: none | not run: A6-20261116-3", out)
        self.assertEqual(out[-1], "RESULT: C6 match on 1 of 1 applicable runs that ran; 1 planned run(s) not run")


class Scripts(unittest.TestCase):
    TEXT = C6.read_text(encoding="utf-8")

    @NEEDS_BASH
    def test_bash_parses(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(C6)], capture_output=True).returncode, 0)

    def test_read_only(self):
        code = [line for line in self.TEXT.splitlines() if not line.lstrip().startswith("#")]
        writes = re.compile(r"\baz\b.*\b(create|delete|update|set|assign|remove|add|purge|upload)\b")
        self.assertEqual([line for line in code if writes.search(line)], [])
        self.assertNotIn("az rest", self.TEXT)

    @NEEDS_BASH
    def test_bad_arguments_stop_before_any_az_call(self):
        for args in (["2026-11-16 20:00", "20261116"], ["2026-11-16T20:00:00Z", "2026116"]):
            proc = subprocess.run(["bash", str(C6), *args], capture_output=True, text=True, timeout=20)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("STOP", proc.stdout)

    def test_kql_avoids_reserved_names(self):
        self.assertNotRegex(self.TEXT, r"\b(first|last)\s*=")

    def test_allow_count_uses_the_action_the_claims_tool_audits(self):
        """2026-11-16: the query counted action "call", the tool writes action "read", so 12 allows scored 0."""
        tool = (ROOT / "agent" / "claims_tool.py").read_text(encoding="utf-8")
        actions = set(re.findall(r'action="([a-z_]+)"', tool))
        self.assertEqual(actions, {"read"})
        allow = re.search(r'allows = countif\(action == "([a-z_]+)" and decision == "allow"\)', self.TEXT)
        self.assertIsNotNone(allow)
        self.assertIn(allow.group(1), actions)

    def test_jumpbox_helper_never_runs_as_t_for_a_case_manager(self):
        """D-045: ground truth is registered on the laptop; the jumpbox helper only sets and clears two variables."""
        ps = PS1.read_text(encoding="utf-8")
        code = "\n".join(line for line in ps.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("AZURE_CONFIG_DIR", code)
        self.assertNotIn("ground_truth.py", code)
        self.assertNotIn("Register-GaRun", code)
        self.assertIn("function Clear-GaRedteamEnv", code)
        self.assertFalse((ROOT / "scripts" / "jumpbox" / "Register-GaRun.ps1").exists())


# Every query file in the repo: KQL, shell, Python and jq. Docs and evidence aren't queries.
QUERY_FILES = sorted(p for p in ROOT.rglob("*") if p.suffix in {".kql", ".sh", ".py", ".jq"}
                     and ".git" not in p.parts and ".venv" not in p.parts and "evidence" not in p.parts
                     and p.name != "test_ground_truth.py")
FUZZY = re.compile(r"harness_verdict[\"')\s]*(?:!?has\b|!?contains\b|!?in~|!?startswith\b|!?hasprefix\b|!?has_any\b|=~|!~|matches\s+regex)",
                   re.I)
EXPECT_PREFIX = re.compile(r"harness_verdict[\"')\s]*!?startswith\s+\"expect-\"")


def fuzzy_verdict_lines(text: str) -> list[str]:
    """Lines that match harness_verdict loosely, other than the expect- prefix test itself (D-045): "expect-blocked"
    matches has "blocked" and contains "blocked", so an outcome filter must be exact or exclude expect-* first."""
    return [line.strip() for line in text.splitlines() if FUZZY.search(line) and not EXPECT_PREFIX.search(line)]


class OutcomeFilters(unittest.TestCase):
    def test_no_query_matches_harness_verdict_loosely(self):
        self.assertTrue(QUERY_FILES)
        bad = {str(p.relative_to(ROOT)): fuzzy_verdict_lines(p.read_text(encoding="utf-8", errors="replace"))
               for p in QUERY_FILES}
        self.assertEqual({k: v for k, v in bad.items() if v}, {})

    def test_the_guard_catches_the_expect_trap(self):
        for line in ('RedTeamRun_CL | where harness_verdict has "blocked"',
                     "| where harness_verdict contains 'refused'",
                     '| where harness_verdict in~ ("blocked", "refused")',
                     '| where harness_verdict =~ "Blocked"',
                     '| where harness_verdict startswith "block"',
                     '| where tostring(harness_verdict) has_any ("blocked")'):
            self.assertEqual(len(fuzzy_verdict_lines(line)), 1, line)
        for line in ('| where not(harness_verdict startswith "expect-") and harness_verdict == "blocked"',
                     '| where harness_verdict !startswith "expect-"',
                     '| extend Kind = iff(tostring(column_ifexists("harness_verdict", "")) startswith "expect-", "registered", "outcome")'):
            self.assertEqual(fuzzy_verdict_lines(line), [], line)

    def test_expect_values_would_match_a_loose_filter(self):
        """Why the guard exists: each expect-* value contains an outcome word."""
        for outcome, expected in (("blocked", "expect-blocked"), ("refused", "expect-refused"),
                                  ("complied", "expect-complied")):
            self.assertIn(expected, ground_truth.EXPECTED)
            self.assertIn(outcome, ground_truth.VERDICTS)
            self.assertIn(outcome, expected)

    def test_e07_labels_registered_rows(self):
        text = (ROOT / "scripts" / "w3_evidence_capture.sh").read_text(encoding="utf-8")
        self.assertIn('startswith "expect-", "registered", "outcome"', text)


if __name__ == "__main__":
    unittest.main()
