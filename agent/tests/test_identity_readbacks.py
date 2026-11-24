"""Offline tests for scripts/identity_readbacks.sh and scripts/lib/identity-checks.jq (w2-sentinel, w2-agentid, D-040).

No Azure or Graph call: the jq checks run on synthetic fixtures (all-zeros object IDs), and the script is only parsed
or run with arguments it refuses before any az call. Run from the repo root:

    python3 -I -m unittest discover -s agent/tests -p 'test_identity_readbacks.py' -v
"""
from __future__ import annotations

import copy
import json
import os
import re
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tooling import have_bash, have_jq  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "identity_readbacks.sh"
LIBDIR = REPO / "scripts" / "lib"
GRP = "00000000-0000-0000-0000-00000000000a"
EA = "00000000-0000-0000-0000-00000000000e"
ALDER = "00000000-0000-0000-0000-0000000000a1"
BIRCH = "00000000-0000-0000-0000-0000000000b1"
CA01 = "GA-CA-01 case managers block device code flow (report-only)"
CA02 = "GA-CA-02 case managers require MFA (report-only)"
WS = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-guardedadvisor-shared/providers/Microsoft.OperationalInsights/workspaces/ga-law-shared"
CATS = ["AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs"]


NEEDS_JQ = unittest.skipUnless(have_jq(), "jq not available")
NEEDS_BASH = unittest.skipUnless(have_bash(), "bash not available")


def jq(filter_: str, data: object, *args: str) -> list[list[str]]:
    """Run a lib filter that returns rows; each row comes back as a list of strings."""
    proc = subprocess.run(["jq", "-r", "-L", str(LIBDIR), *args, f'include "identity-checks"; {filter_} | .[] | row'],
                          input=json.dumps(data), capture_output=True, text=True, timeout=20)
    if proc.returncode:
        raise AssertionError(proc.stderr)
    return [line.split("\x1f") for line in proc.stdout.splitlines()]


def failing(rows: list[list[str]]) -> list[str]:
    return [label for label, got, exp in rows if got != exp]


def policy(kind: str) -> dict:
    """A Graph-shaped report-only policy as the portal would save it."""
    p = {"displayName": CA01 if kind == "devicecode" else CA02, "state": "enabledForReportingButNotEnforced",
         "conditions": {"users": {"includeUsers": [], "includeGroups": [GRP.upper()], "includeRoles": [],
                                  "excludeUsers": [EA], "excludeGroups": []},
                        "applications": {"includeApplications": ["All"], "excludeApplications": []},
                        "clientAppTypes": ["all"]},
         "grantControls": {"operator": "OR", "builtInControls": ["block"], "authenticationStrength": None}}
    if kind == "devicecode":
        p["conditions"]["authenticationFlows"] = {"transferMethods": "deviceCodeFlow"}
    else:   # the built-in MFA authentication strength, as created in the portal 2026-11-13
        p["grantControls"]["builtInControls"] = []
        p["grantControls"]["authenticationStrength"] = {"id": "00000000-0000-0000-0000-000000000002",
                                                        "displayName": "Multifactor authentication"}
    return p


def ca(p: dict, kind: str) -> list[list[str]]:
    return jq("lk | ca_checks($k; $grp; $ea)", p, "--arg", "k", kind, "--arg", "grp", GRP, "--arg", "ea", EA)


@NEEDS_JQ
class PolicyChecks(unittest.TestCase):
    def test_portal_shaped_policies_pass(self):
        for kind in ("devicecode", "mfa"):
            with self.subTest(kind=kind):
                rows = ca(policy(kind), kind)
                self.assertEqual(failing(rows), [])
                self.assertGreaterEqual(len(rows), 6)

    def test_each_wrong_setting_is_a_finding(self):
        cases = {
            "state": lambda p: p.update(state="enabled"),
            "include groups = grp-larkfield-cm only": lambda p: p["conditions"]["users"]["includeGroups"].append(EA),
            "include users and roles (none)": lambda p: p["conditions"]["users"].update(includeUsers=["All"]),
            "exclude users = the emergency access account only": lambda p: p["conditions"]["users"].update(excludeUsers=[]),
            "authentication flows": lambda p: p["conditions"]["authenticationFlows"].update(
                transferMethods="deviceCodeFlow,authenticationTransfer"),
            "grant": lambda p: p["grantControls"].update(builtInControls=["mfa"]),
        }
        for label, change in cases.items():
            p = policy("devicecode")
            change(p)
            with self.subTest(label=label):
                self.assertEqual(failing(ca(p, "devicecode")), [label])

    def test_mfa_policy_rejects_a_flow_condition_the_mfa_grant_and_another_strength(self):
        p = policy("mfa")
        p["conditions"]["authenticationFlows"] = {"transferMethods": "deviceCodeFlow"}
        p["grantControls"]["builtInControls"] = ["mfa"]
        self.assertEqual(failing(ca(p, "mfa")), ["authentication flows (none)", "built-in grant controls (none)"])
        p = policy("mfa")
        p["grantControls"]["authenticationStrength"] = {"displayName": "Phishing-resistant MFA"}
        self.assertEqual(failing(ca(p, "mfa")), ["authentication strength"])
        p["grantControls"]["authenticationStrength"] = {"id": "00000000-0000-0000-0000-000000000003"}   # no name
        self.assertIn(["authentication strength", "0000...0003", "Multifactor authentication"], ca(p, "mfa"))
        p["grantControls"]["authenticationStrength"] = None
        self.assertIn(["authentication strength", "(none)", "Multifactor authentication"], ca(p, "mfa"))

    def test_a_missing_policy_fails_every_check(self):
        rows = ca({}, "devicecode")
        self.assertEqual(len(failing(rows)), len(rows))
        self.assertIn(["state", "MISSING", "enabledForReportingButNotEnforced"], rows)

    def test_info_masks_resource_ids(self):
        p = policy("mfa")
        p["conditions"]["applications"]["includeApplications"] = ["00000000-0000-0000-0000-0000000000c1"]
        self.assertIn(["include resources", "0000...00c1"], jq("lk | ca_info", p))


@NEEDS_JQ
class AuditPolicy(unittest.TestCase):
    def audit_row(self, p: dict, encode_twice: bool) -> dict:
        value = json.dumps(p)
        if encode_twice:
            value = json.dumps(value)
        props = [{"displayName": "ConditionalAccessPolicy", "oldValue": None, "newValue": value}]
        return {"Policy": p["displayName"], "Props": json.dumps(props)}

    def test_audit_json_goes_through_the_same_checks(self):
        for twice in (False, True):
            with self.subTest(encoded_twice=twice):
                row = self.audit_row(policy("devicecode"), twice)
                rows = jq("audit_policy | ca_checks($k; $grp; $ea)", row,
                          "--arg", "k", "devicecode", "--arg", "grp", GRP, "--arg", "ea", EA)
                self.assertEqual(failing(rows), [])

    def test_a_row_without_policy_json_fails_closed(self):
        row = {"Policy": CA01, "Props": json.dumps([{"displayName": "Other", "newValue": "\"x\""}])}
        rows = jq("(audit_policy // {}) | ca_checks($k; $grp; $ea)", row,
                  "--arg", "k", "devicecode", "--arg", "grp", GRP, "--arg", "ea", EA)
        self.assertEqual(len(failing(rows)), len(rows))


@NEEDS_JQ
class DiagChecks(unittest.TestCase):
    def listing(self, **change: object) -> dict:
        logs = [{"category": c, "enabled": True} for c in CATS] + [{"category": "ProvisioningLogs", "enabled": False}]
        props = {"workspaceId": WS.lower(), "logs": logs, "storageAccountId": None}
        props.update(change)
        return {"value": [{"name": "ga-entra-to-law-shared", "properties": props}]}

    def diag(self, data: dict) -> list[list[str]]:
        return jq("diag_checks($n; $ws; $cats)", data, "--arg", "n", "ga-entra-to-law-shared", "--arg", "ws", WS,
                  "--argjson", "cats", json.dumps(CATS))

    def test_the_planned_setting_passes(self):
        self.assertEqual(failing(self.diag(self.listing())), [])

    def test_differences_are_findings(self):
        extra = self.listing()
        extra["value"][0]["properties"]["logs"][-1]["enabled"] = True
        self.assertEqual(failing(self.diag(extra)), ["enabled categories"])
        self.assertEqual(failing(self.diag(self.listing(workspaceId=WS.replace("ga-law-shared", "other")))),
                         ["destination = ga-law-shared"])
        self.assertEqual(failing(self.diag(self.listing(storageAccountId="/subscriptions/x/storage"))),
                         ["storage or event hub destination (none)"])
        self.assertEqual(self.diag({"value": []}), [["settings named ga-entra-to-law-shared", "0", "1"]])


@NEEDS_JQ
class SigninChecks(unittest.TestCase):
    USERS = {ALDER: "alder", BIRCH: "birch"}

    def row(self, oid: str, ca01: str | None, table: str = "SigninLogs", protocol: str = "deviceCode",
            transfer: str = "", result: str = "0", as_string: bool = True, ca02: str = "reportOnlySuccess") -> dict:
        cap = [{"displayName": CA02, "result": ca02}]
        if ca01:
            cap.append({"displayName": CA01, "result": ca01})
        return {"Tbl": table, "UserId": oid.upper(), "AuthenticationProtocol": protocol,
                "OriginalTransferMethod": transfer, "ResultType": result, "CAP": json.dumps(cap) if as_string else cap}

    def checks(self, rows: list[dict]) -> list[list[str]]:
        return jq("signin_checks($u; $a; $b)", rows, "--argjson", "u", json.dumps(self.USERS), "--arg", "a", CA01,
                  "--arg", "b", CA02)

    def test_report_only_failure_for_both_users_passes(self):
        rows = [self.row(ALDER, "reportOnlyFailure", result="50199"),
                self.row(BIRCH, "reportOnlyFailure", table="AADNonInteractiveUserSignInLogs", protocol="none",
                         transfer="deviceCodeFlow", as_string=False)]
        self.assertEqual(failing(self.checks(rows)), [])

    def test_not_applied_absent_or_no_device_code_rows_are_findings(self):
        rows = [self.row(ALDER, "reportOnlyNotApplied"), self.row(BIRCH, None),
                self.row(BIRCH, "reportOnlyFailure", protocol="oAuth2")]   # not a device code row
        self.assertEqual(failing(self.checks(rows)), ["alder: GA-CA-01 on device code sign-ins",
                                                      "birch: GA-CA-01 on device code sign-ins"])
        self.assertEqual(failing(self.checks([])), [f"{u}: {c}" for u in ("alder", "birch") for c in (
            "device code sign-ins", "GA-CA-01 on device code sign-ins", "GA-CA-02 on device code sign-ins")])

    def test_ga_ca_02_must_be_report_only_success(self):
        rows = [self.row(ALDER, "reportOnlyFailure", ca02="reportOnlyInterrupted"), self.row(BIRCH, "reportOnlyFailure")]
        self.assertEqual(failing(self.checks(rows)), ["alder: GA-CA-02 on device code sign-ins"])

    def test_info_reports_result_codes(self):
        rows = [self.row(ALDER, "reportOnlyFailure", result="50199"), self.row(ALDER, "reportOnlyFailure")]
        info = jq("signin_info($u)", rows, "--argjson", "u", json.dumps(self.USERS))
        self.assertIn(["alder: result codes on device code sign-ins", "0,50199"], info)
        self.assertIn(["birch: rows by table", "(none)"], info)


class Script(unittest.TestCase):
    TEXT = SCRIPT.read_text(encoding="utf-8")

    @NEEDS_BASH
    def test_bash_parses(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True).returncode, 0)

    def test_read_only(self):
        methods = re.findall(r"az rest --method (\w+)", self.TEXT)
        self.assertTrue(methods)
        self.assertEqual(set(methods), {"get"})
        code = [line for line in self.TEXT.splitlines() if not line.lstrip().startswith("#")]
        writes = re.compile(r"\baz\b.*\b(create|delete|update|set|assign|remove|add|purge)\b")
        self.assertEqual([line for line in code if writes.search(line)], [])

    def test_names_match_the_plan(self):
        for name in (CA01, CA02, "ga-entra-to-law-shared", "grp-larkfield-cm", "ga-law-shared",
                     "api-version=2017-04-01", "graph.microsoft.com/v1.0/identity/conditionalAccess/policies"):
            self.assertIn(name, self.TEXT)
        self.assertEqual(json.loads(re.search(r"CATS='(\[.*\])'", self.TEXT).group(1)), CATS)

    def test_kql_avoids_reserved_names(self):
        # first and last are reserved in KQL (2026-11-12 slip, batch A 2026-11-14); columns are FirstRow and LastRow.
        self.assertNotRegex(self.TEXT, r"\b(first|last)\s*=")
        self.assertNotRegex(self.TEXT, r"(?i)\bby\s+(first|last)\b")

    def test_signins_converts_each_table_before_the_union(self):
        """ConditionalAccessPolicies is dynamic in SigninLogs and string in AADNonInteractiveUserSignInLogs; a plain
        union renamed both (SEM0100, 2026-11-13). A (T:(*)) function can't reference UserId (2026-11-14)."""
        body = self.TEXT[self.TEXT.index("  signins)"):]
        body = body[:body.index(";;")]
        code = "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("isfuzzy", code)
        self.assertNotIn("(T:(*))", code)
        self.assertIn('let i = SigninLogs | where UserId in~ (ids)', body)
        self.assertIn('let n = AADNonInteractiveUserSignInLogs | where UserId in~ (ids)', body)
        self.assertEqual(body.count("CAP = todynamic(ConditionalAccessPolicies)"), 2)
        self.assertIn("union i, n", body)
        # Tbl keeps the table names signin_info groups by.
        self.assertIn('Tbl = \\"SigninLogs\\"', body)
        self.assertIn('Tbl = \\"AADNonInteractiveUserSignInLogs\\"', body)

    def test_errclass_knows_kql_errors(self):
        line = next(line for line in self.TEXT.splitlines() if line.startswith("errclass()"))
        for code in ("BadArgumentError", "SyntaxError", "SemanticError", "SEM[0-9]+"):
            self.assertIn(code, line)

    def test_ca_audit_matches_generic_policy_rows_for_ga_ca_only(self):
        body = self.TEXT[self.TEXT.index("  ca-audit)"):]
        body = body[:body.index(";;")]
        self.assertIn('OperationName in~ ("Add Conditional Access policy", "Update Conditional Access policy")', body)
        self.assertIn('(OperationName in~ ("Add policy", "Update policy") and Policy startswith "GA-CA-")', body)

    @NEEDS_JQ
    def test_ca_audit_checks_the_latest_row_that_carries_policy_json(self):
        """GA-CA-02 on 2026-11-13: "Add policy" and "Add conditional access policy" a third of a second apart. The
        latest row with policy JSON is checked, so a later generic row without JSON doesn't fail a good policy."""
        selector = re.search(r"'include \"identity-checks\"; (\[\.\[\] \| select\(\.Policy == \$n\).*?)' \"\$KF\" >\"\$PF\"",
                             self.TEXT).group(1)
        good = AuditPolicy().audit_row(policy("mfa"), False)
        generic = {"Policy": CA02, "Props": json.dumps([{"displayName": "Other", "newValue": "\"x\""}])}
        for rows in ([good, generic], [generic, good]):
            proc = subprocess.run(["jq", "-L", str(LIBDIR), "--arg", "n", CA02, f'include "identity-checks"; {selector}'],
                                  input=json.dumps(rows), capture_output=True, text=True, timeout=20)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            chosen = json.loads(proc.stdout)
            self.assertEqual(chosen["displayname"], CA02)
        proc = subprocess.run(["jq", "-L", str(LIBDIR), "--arg", "n", CA02, f'include "identity-checks"; {selector}'],
                              input=json.dumps([generic]), capture_output=True, text=True, timeout=20)
        self.assertEqual(json.loads(proc.stdout), {})   # no JSON at all: {} fails every check (closed)

    @NEEDS_BASH
    def test_bad_arguments_stop_before_any_az_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "az-called"
            fake = Path(tmp) / "az"
            fake.write_text(f"#!/bin/sh\ntouch {marker}\n")
            fake.chmod(0o755)
            env = {"PATH": f"{tmp}:/usr/bin:/bin", "HOME": tmp}
            for args in ([], ["logs"], ["logs", "2026-11-12"], ["diag", "2026-11-12T20:00:00Z"], ["nope"], ["ca"]):
                with self.subTest(args=args):
                    proc = subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=20)
                    self.assertEqual(proc.returncode, 2, proc.stdout)
            self.assertFalse(marker.exists())


@NEEDS_BASH
@NEEDS_JQ
class ScriptEndToEnd(unittest.TestCase):
    """The script against a stub az (canned JSON by argument pattern), in a throwaway HOME. Covers the bash wiring:
    guards, the rows/IFS loop, the jq include, exit codes and the masked output."""
    SUB = "00000000-0000-0000-0000-000000000000"
    T = "6d4c0000-0000-0000-0000-000000002a4d"   # synthetic, shaped to T's masked ID
    STUB = r'''#!/bin/sh
echo "$*" >>"$HOME/calls.txt"
case "$*" in
  "account show"*) echo "$SUB" ;;
  "ad signed-in-user show"*) echo "$ME" ;;
  *"workspace show"*"--query id"*) echo "$WS" ;;
  *"workspace show"*"--query customerId"*) echo "00000000-0000-0000-0000-0000000000f0" ;;
  "rest --method get --url https://management.azure.com/providers/microsoft.aadiam"*) cat "$HOME/aadiam.json" ;;
  "monitor log-analytics query"*) cat "$HOME/kql.json" ;;
  *) echo "unexpected az call: $*" >&2; exit 9 ;;
esac
'''

    def run_script(self, args: list[str], files: dict[str, object], me: str = T) -> tuple[subprocess.CompletedProcess, str]:
        with tempfile.TemporaryDirectory() as home:
            h = Path(home)
            (h / "bin").mkdir()
            (h / "bin" / "az").write_text(self.STUB)
            (h / "bin" / "az").chmod(0o755)
            p1 = h / "guarded-advisor-private" / "pim-2026-11"
            p1.mkdir(parents=True)
            (p1 / "p1-t-and-g.json").write_text(json.dumps([{"roleDefinitionName": "Owner", "scope": f"/subscriptions/{self.SUB}"}]))
            for name, data in files.items():
                (h / name).write_text(json.dumps(data))
            env = {"PATH": f"{h / 'bin'}:/usr/bin:/bin", "HOME": home, "SUB": self.SUB, "ME": me, "WS": WS}
            proc = subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=60)
            calls = (h / "calls.txt").read_text() if (h / "calls.txt").exists() else ""
        return proc, calls

    def test_diag_passes_and_fails_on_the_stub(self):
        good = DiagChecks().listing()
        proc, calls = self.run_script(["diag"], {"aadiam.json": good})
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ok | enabled categories |", proc.stdout)
        self.assertIn("findings: 0", proc.stdout)
        self.assertNotIn(self.T, proc.stdout)                     # IDs only masked
        self.assertIn("signed in: 6d4c...2a4d", proc.stdout)
        bad = DiagChecks().listing(workspaceId="/other")
        proc, _ = self.run_script(["diag"], {"aadiam.json": bad})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("FINDING | destination = ga-law-shared | got false, expected true", proc.stdout)

    def test_signins_on_the_stub(self):
        rows = [SigninChecks().row(ALDER, "reportOnlyFailure"), SigninChecks().row(BIRCH, "reportOnlyNotApplied")]
        ent = REPO / "scenarios" / "larkfield" / "entitlements.json"
        ids = {v["alias"]: k for k, v in json.loads(ent.read_text(encoding="utf-8"))["caseloads"].items()}
        for r, alias in zip(rows, ("alder", "birch")):
            r["UserId"] = ids[alias]
        proc, calls = self.run_script(["signins", "2026-11-13T16:00:00Z"], {"kql.json": rows})
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("ok | alder: GA-CA-01 on device code sign-ins | reportOnlyFailure", proc.stdout)
        self.assertIn("FINDING | birch: GA-CA-01 on device code sign-ins | got reportOnlyNotApplied", proc.stdout)
        self.assertIn("--timespan 2026-11-13T16:00:00Z/", calls)

    def test_the_identity_guard_stops_a_different_account(self):
        proc, calls = self.run_script(["diag"], {"aadiam.json": {"value": []}}, me="11110000-0000-0000-0000-000000001111")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("STOP: signed-in account is not T", proc.stdout)
        self.assertNotIn("aadiam", calls)


if __name__ == "__main__":
    unittest.main()
