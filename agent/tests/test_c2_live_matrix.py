"""Tests for scripts/c2_live_matrix.py (item 5, C2). No Azure calls: the caller and the backends are fakes.

    python3 -m unittest discover -s agent/tests -v
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

AGENT = Path(__file__).resolve().parent.parent
ROOT = AGENT.parent
sys.path.insert(0, str(AGENT))

import pack  # noqa: E402

_spec = importlib.util.spec_from_file_location("c2_live_matrix", ROOT / "scripts" / "c2_live_matrix.py")
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

CONFIG = pack.load_config("larkfield")
RECORDS = {r["claim_id"]: r for r in pack.load_records("larkfield")}
ENTITLEMENTS = pack.load_entitlements("larkfield")
ALIASES = harness.load_aliases("larkfield")
OID = {alias: oid for oid, alias in ALIASES.items()}
OUTSIDER = "00000000-0000-4000-8000-00000000abcd"  # not in the entitlement map (like T)
RUN_DATE = "20261106"


class FakeReader:
    def __init__(self, records):
        self.records, self.reads = records, []

    def read(self, record_id):
        self.reads.append(record_id)
        return self.records.get(record_id)


class FakeSink:
    def __init__(self, fail=False):
        self.rows, self.fail = [], fail

    def send(self, rows):
        if self.fail:
            raise RuntimeError("ingestion unavailable")
        self.rows.extend(rows)


class Run:
    """One harness run with fakes. The caller is what the fake token says, never an argument."""

    def __init__(self, out_dir, *, token_alias=None, token_oid=None, reader=None, sink=None):
        self.out_dir = Path(out_dir)
        self.token_oid = token_oid or OID[token_alias]
        self.reader = reader or FakeReader(RECORDS)
        self.sink = sink or FakeSink()
        self.caller_calls = 0
        self.backend_calls = 0

    def get_caller(self):
        self.caller_calls += 1
        return self.token_oid

    def make_backends(self, config):
        self.backend_calls += 1
        return self.reader, self.sink

    def __call__(self, *argv):
        argv = [*argv, "--out-dir", str(self.out_dir)]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.code = harness.main(argv, get_caller=self.get_caller, make_backends=self.make_backends)
        self.stdout, self.stderr = out.getvalue(), err.getvalue()
        return self.code

    def output(self, alias):
        return (self.out_dir / f"c2live-{RUN_DATE}-{alias}.txt").read_text(encoding="utf-8")


class FullMatrix(unittest.TestCase):
    def test_each_case_manager_gets_own_caseload_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            total_allow = total_deny = 0
            for alias in ("alder", "cedar", "birch"):  # tonight's run order
                run = Run(tmp, token_alias=alias)
                self.assertEqual(run("--expect-alias", alias, "--run-date", RUN_DATE), 0, run.stderr)
                own = ENTITLEMENTS[OID[alias]]
                self.assertEqual(set(run.reader.reads), set(own))  # the store is read only for the caseload
                rows = run.sink.rows
                self.assertEqual(len(rows), 30)
                allows = [r for r in rows if r["decision"] == "allow"]
                denies = [r for r in rows if r["decision"] == "deny"]
                self.assertEqual({r["record_id"] for r in allows}, set(own))
                self.assertTrue(all(r["reason"] == "not_in_caseload" for r in denies))
                self.assertTrue(all(r["caller"] == OID[alias] for r in rows))
                self.assertTrue(all(r["redteam_id"] == f"c2live-{RUN_DATE}-{alias}" for r in rows))
                self.assertIn(f"positive control: {len(own)} of {len(own)} assigned claims allowed", run.output(alias))
                total_allow, total_deny = total_allow + len(allows), total_deny + len(denies)
            self.assertEqual((total_allow, total_deny), (30, 60))

    def test_output_is_masked(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="birch")
            run("--expect-alias", "birch", "--run-date", RUN_DATE)
            text = run.output("birch") + run.stdout
            self.assertIsNone(re.search(r"LM-CLM-", text))
            for oid in ALIASES:
                self.assertNotIn(oid, text)
            for record in RECORDS.values():
                for key in ("member_id", "member_name", "condition_summary", "treating_provider", "clinic"):
                    self.assertNotIn(str(record[key]), text)
            self.assertIn(f"{OID['birch'][:4]}...{OID['birch'][-4:]}", text)


class ExpectAliasCannotSetTheCaller(unittest.TestCase):
    def test_mismatch_stops_before_any_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="birch")
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 2)
            self.assertIn("signed in as birch, expected alder", run.stderr)
            self.assertEqual((run.backend_calls, run.reader.reads, run.sink.rows), (0, [], []))
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_caller_in_rows_is_the_token_holder(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="cedar")
            self.assertEqual(run("--expect-alias", "cedar", "--run-date", RUN_DATE), 0)
            self.assertEqual({r["caller"] for r in run.sink.rows}, {OID["cedar"]})

    def test_no_option_names_a_caller(self):
        for option in ("--caller", "--caller-oid", "--oid", "--user"):
            with self.subTest(option=option), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                harness.parse_args(["--expect-alias", "alder", "--run-date", RUN_DATE, option, OID["alder"]])

    def test_shortened_options_are_rejected(self):
        for argv in (["--expect", "alder", "--run-date", RUN_DATE],
                     ["--expect-alias", "alder", "--run", RUN_DATE],
                     ["--expect-alias", "alder", "--run-date", RUN_DATE, "--out", "x"]):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                harness.parse_args(argv)

    def test_environment_cannot_set_the_caller(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"GA_CALLER_OID": OID["alder"]}):
            run = Run(tmp, token_alias="birch")
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 2)
            self.assertEqual(run.reader.reads, [])


class RefusesWrongCaller(unittest.TestCase):
    def test_caller_outside_the_map_stops_before_any_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_oid=OUTSIDER)
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 2)
            self.assertIn("isn't one of the case managers", run.stderr)
            self.assertNotIn(OUTSIDER, run.stderr)  # masked
            self.assertEqual((run.backend_calls, run.reader.reads, run.sink.rows), (0, [], []))
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_token_failure_stops_before_any_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="alder")

            def broken():
                raise RuntimeError("az not signed in")
            run.get_caller = broken
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 2)
            self.assertEqual((run.backend_calls, run.reader.reads), (0, []))

    def test_unknown_alias_and_bad_date_stop_before_signing_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            for argv in (("--expect-alias", "tooni", "--run-date", RUN_DATE),
                         ("--expect-alias", "alder", "--run-date", "2026-11-06"),
                         ("--expect-alias", "alder", "--run-date", "../x")):
                with self.subTest(argv=argv):
                    run = Run(tmp, token_alias="alder")
                    self.assertEqual(run(*argv), 2)
                    self.assertEqual(run.caller_calls, 0)


class RefusesSecondRun(unittest.TestCase):
    def test_second_run_for_same_alias_and_date_is_refused_before_signing_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = Run(tmp, token_alias="alder")
            self.assertEqual(first("--expect-alias", "alder", "--run-date", RUN_DATE), 0)
            second = Run(tmp, token_alias="alder")
            self.assertEqual(second("--expect-alias", "alder", "--run-date", RUN_DATE), 4)
            self.assertEqual((second.caller_calls, second.backend_calls, second.reader.reads), (0, 0, []))
            self.assertIn("already run", second.stderr)

    def test_leftover_audit_file_alone_also_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, f"c2live-{RUN_DATE}-cedar.audit.jsonl").write_text("", encoding="utf-8")
            run = Run(tmp, token_alias="cedar")
            self.assertEqual(run("--expect-alias", "cedar", "--run-date", RUN_DATE), 4)

    def test_other_aliases_still_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(Run(tmp, token_alias="alder")("--expect-alias", "alder", "--run-date", RUN_DATE), 0)
            self.assertEqual(Run(tmp, token_alias="cedar")("--expect-alias", "cedar", "--run-date", RUN_DATE), 0)


class StopRules(unittest.TestCase):
    def test_unexpected_allow_stops_at_once(self):
        alder_claim = sorted(ENTITLEMENTS[OID["alder"]])[0]
        widened = {**ENTITLEMENTS, OID["birch"]: ENTITLEMENTS[OID["birch"]] | {alder_claim}}
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="birch")
            # The tool's map is widened; the harness's expectation still comes from entitlements.json.
            with mock.patch.object(harness.pack, "load_entitlements",
                                   side_effect=[ENTITLEMENTS, widened]):
                self.assertEqual(run("--expect-alias", "birch", "--run-date", RUN_DATE), 3)
            stop_index = sorted(RECORDS).index(alder_claim) + 1
            self.assertEqual(len(run.sink.rows), stop_index)
            text = run.output("birch")
            self.assertIn("UNEXPECTED ALLOW: stopped", text)
            self.assertIn("unexpected allow: 1", text)

    def test_allow_returning_another_claim_counts_as_unexpected_allow(self):
        own = sorted(ENTITLEMENTS[OID["cedar"]])
        other = next(c for c in sorted(RECORDS) if c not in own)
        records = {**RECORDS, own[0]: {**RECORDS[other]}}  # the store returns another member's claim
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="cedar", reader=FakeReader(records))
            self.assertEqual(run("--expect-alias", "cedar", "--run-date", RUN_DATE), 3)
            self.assertIn("allow_mismatch", run.output("cedar"))

    def test_unexpected_deny_is_recorded_and_the_run_continues(self):
        own = sorted(ENTITLEMENTS[OID["alder"]])
        records = {k: v for k, v in RECORDS.items() if k != own[0]}
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="alder", reader=FakeReader(records))
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 1)
            text = run.output("alder")
            self.assertEqual(len(run.sink.rows), 30)
            self.assertIn("not_found | UNEXPECTED DENY", text)
            self.assertIn(f"positive control: {len(own) - 1} of {len(own)}", text)

    def test_audit_unavailable_withholds_allows(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="alder", sink=FakeSink(fail=True))
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 1)
            text = run.output("alder")
            self.assertEqual(text.count("audit_unavailable | UNEXPECTED DENY"), len(ENTITLEMENTS[OID["alder"]]))
            self.assertIn("positive control: 0 of", text)


class _SkipAllowLog(harness.RecordTool):
    """A broken tool that returns allows without logging them."""

    def _log(self, record_id, decision, reason):
        if decision != "allow":
            super()._log(record_id, decision, reason)


class _FlipAllowLog(harness.RecordTool):
    """A broken tool that logs its allows as denies."""

    def _log(self, record_id, decision, reason):
        super()._log(record_id, "deny" if decision == "allow" else decision, reason)


class AuditCheck(unittest.TestCase):
    def _first_own_index(self, alias):
        return sorted(RECORDS).index(min(ENTITLEMENTS[OID[alias]])) + 1

    def test_allow_with_no_audit_record_stops(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(harness, "RecordTool", _SkipAllowLog):
            run = Run(tmp, token_alias="birch")
            self.assertEqual(run("--expect-alias", "birch", "--run-date", RUN_DATE), 5)
            text = run.output("birch")
            stop = self._first_own_index("birch")
            self.assertIn(f"{stop:02d} | birch | allow | allow | - | AUDIT MISMATCH: stopped", text)
            self.assertEqual(len(run.sink.rows), stop - 1)  # the denies before it, and no row for the allow
            self.assertIn("audit mismatch: 1", text)
            self.assertIn("STOPPED at an audit mismatch", text)

    def test_audit_decision_that_differs_from_the_result_stops(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(harness, "RecordTool", _FlipAllowLog):
            run = Run(tmp, token_alias="alder")
            self.assertEqual(run("--expect-alias", "alder", "--run-date", RUN_DATE), 5)
            self.assertIn("AUDIT MISMATCH: stopped", run.output("alder"))
            self.assertEqual(run.sink.rows[-1]["decision"], "deny")

    def test_unexpected_allow_outranks_a_missing_audit_record(self):
        first = sorted(RECORDS)[0]
        alias = next(a for a in ("alder", "birch", "cedar") if first not in ENTITLEMENTS[OID[a]])
        widened = {**ENTITLEMENTS, OID[alias]: ENTITLEMENTS[OID[alias]] | {first}}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(harness, "RecordTool", _SkipAllowLog), \
                mock.patch.object(harness.pack, "load_entitlements", side_effect=[ENTITLEMENTS, widened]):
            run = Run(tmp, token_alias=alias)
            self.assertEqual(run("--expect-alias", alias, "--run-date", RUN_DATE), 3)
            self.assertIn("01 | ", run.output(alias))
            self.assertIn("UNEXPECTED ALLOW: stopped; AUDIT MISMATCH", run.output(alias))


class RaisingReader(FakeReader):
    def read(self, record_id):
        raise ValueError(f"store failure for {record_id} as {OID['cedar']}")


class Errors(unittest.TestCase):
    def assertNoDetail(self, text):
        self.assertNotIn("Traceback", text)
        self.assertIsNone(re.search(r"LM-CLM-", text))
        self.assertNotIn(OID["cedar"], text)
        self.assertNotIn("secret-endpoint", text)

    def test_backend_failure_stops_with_the_type_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="cedar")

            def broken(config):
                raise RuntimeError(f"secret-endpoint LM-CLM-2026-0001 {OID['cedar']}")
            run.make_backends = broken
            self.assertEqual(run("--expect-alias", "cedar", "--run-date", RUN_DATE), 6)
            self.assertIn("ERROR: stopped (RuntimeError)", run.stderr)
            self.assertNoDetail(run.stderr + run.stdout)
            self.assertEqual(list(Path(tmp).iterdir()), [])  # no output file was opened

    def test_dispatch_failure_stops_with_the_type_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(tmp, token_alias="cedar", reader=RaisingReader(RECORDS))
            self.assertEqual(run("--expect-alias", "cedar", "--run-date", RUN_DATE), 6)
            stop = sorted(RECORDS).index(min(ENTITLEMENTS[OID["cedar"]])) + 1
            text = run.output("cedar")
            for expected in (f"ERROR: stopped (ValueError) at index {stop:02d}", "calls: ", "positive control: ",
                             "STOPPED on an error"):
                with self.subTest(expected=expected):
                    self.assertIn(expected, text)
                    self.assertIn(expected, run.stderr)
            self.assertNoDetail(text + run.stderr + run.stdout)


class NotReachableFromTheAgent(unittest.TestCase):
    def test_no_agent_module_references_it(self):
        """A string-search tripwire, not proof: it catches a direct import or reference by name, not dynamic loading."""
        for path in AGENT.glob("*.py"):
            with self.subTest(module=path.name):
                self.assertNotIn("c2_live_matrix", path.read_text(encoding="utf-8"))

    def test_not_a_registered_tool(self):
        names = re.findall(r'"name":\s*"([^"]+)"', (ROOT / "scenarios" / "larkfield" / "agent.json").read_text())
        self.assertTrue(names)
        for name in names:
            with self.subTest(tool=name):
                self.assertNotIn("matrix", name.lower())


if __name__ == "__main__":
    unittest.main()
