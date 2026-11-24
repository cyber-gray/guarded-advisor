"""scripts/teardown.sh all, against a stub az (state files, no Azure call). Covers the 2026-11-18 known issues
(the status notes, "Known issues (after the window)"): the project step before the account delete, the capability host
wait (45 minutes by default, with progress), the rerun after a failed purge, and the case-insensitive match of
soft-deleted account IDs. All IDs are synthetic.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tooling import have_bash  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "teardown.sh"
NEEDS_BASH = unittest.skipUnless(have_bash(), "bash isn't usable here")

SUB = "00000000-0000-0000-0000-000000000000"
RG = "rg-guardedadvisor-lab"
ACCT = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.CognitiveServices/accounts/ga-ai-labtest"
PROJ = f"{ACCT}/projects/ga-proj-labtest"
SUBNET = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Network/virtualNetworks/vnet/subnets/agent"
DELETED_MIXED = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.CognitiveServices/locations/canadaeast/resourceGroups/{RG}/deletedAccounts/ga-ai-labtest"
DELETED_LOWER = DELETED_MIXED.replace("resourceGroups", "resourcegroups")

# State lives in $HOME/state: <key>.exists = present; <key>.polls = GETs that still succeed after a DELETE;
# <key>.race = the DELETE itself answers 404 (already gone); purge-fail = the next purge fails once.
STUB = r'''#!/bin/sh
S="$HOME/state"
MG=https://management.azure.com
echo "$*" >>"$HOME/calls.txt"
nf() { echo "ERROR: (ResourceNotFound) The resource was not found. Code: ResourceNotFound" >&2; exit 1; }
get() {
  f="$S/$1.polls"
  if [ -f "$f" ]; then
    n=$(cat "$f")
    if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$f"; exit 0; fi
    rm -f "$f"
  fi
  [ -f "$S/$1.exists" ] && exit 0
  nf
}
del() {
  if [ -f "$S/$1.race" ]; then rm -f "$S/$1.exists" "$S/$1.race"; nf; fi
  [ -f "$S/$1.exists" ] || nf
  rm -f "$S/$1.exists"; echo "${2:-0}" >"$S/$1.polls"; exit 0
}
case "$*" in
  "resource list"*) echo 5 ;;
  "apim list"*"length(@)"*) echo 0 ;;
  "apim list"*) ;;
  "network private-dns zone show"*) exit 3 ;;
  "account list-locations"*) echo "Canada East" ;;
  "apim deletedservice list"*) ;;
  "cognitiveservices account list-deleted"*) cat "$S/deleted" 2>/dev/null; true ;;
  "cognitiveservices account list "*) if [ -f "$S/account.exists" ]; then echo "$ACCT"; fi ;;
  "cognitiveservices account delete"*)
    if [ -f "$S/project.exists" ] || [ -f "$S/project.polls" ]; then
      echo "(CannotDeleteResource) Can not delete resource before nested resources are deleted: projects/ga-proj-labtest" >&2; exit 1
    fi
    rm -f "$S/account.exists"
    printf '%s\t%s\t%s\n' "$DELETED_ID" ga-ai-labtest canadaeast >>"$S/deleted" ;;
  "cognitiveservices account purge"*)
    if [ -f "$S/purge-fail" ]; then rm -f "$S/purge-fail"; echo "ERROR: purge failed (synthetic)" >&2; exit 1; fi
    name=$(echo "$*" | sed 's/.* -n \([^ ]*\).*/\1/')
    grep -v "$(printf '\t%s\t' "$name")" "$S/deleted" >"$S/d.tmp" || true
    mv "$S/d.tmp" "$S/deleted" ;;
  "rest --method delete --url $MG$PROJ/capabilityHosts/"*) del caphost-proj "$CAPHOST_PROJ_POLLS" ;;
  "rest --method delete --url $MG$ACCT/capabilityHosts/"*) del caphost-acct "$CAPHOST_ACCT_POLLS" ;;
  "rest --method delete --url $MG$PROJ?api-version=2025-06-01"*) del project "$PROJECT_POLLS" ;;
  "rest --method get --url $MG$PROJ/capabilityHosts/"*) get caphost-proj ;;
  "rest --method get --url $MG$ACCT/capabilityHosts/"*) get caphost-acct ;;
  "rest --method get --url $MG$PROJ?api-version=2025-06-01"*) get project ;;
  "rest --method get --url $MG$PROJ/capabilityHosts?"*) if [ -f "$S/caphost-proj.exists" ]; then echo "$PROJ/capabilityHosts/caphostproj"; fi ;;
  "rest --method get --url $MG$ACCT/capabilityHosts?"*) if [ -f "$S/caphost-acct.exists" ]; then echo "$ACCT/capabilityHosts/caphostacct"; fi ;;
  "rest --method get --url $MG$ACCT/projects?"*) if [ -f "$S/project.exists" ]; then echo "$PROJ"; fi ;;
  "network vnet list"*) echo "$SUBNET" ;;
  "network vnet subnet show"*)
    if [ -f "$S/account.exists" ] || grep -q ga-ai-labtest "$S/deleted" 2>/dev/null; then echo 1; else echo 0; fi ;;
  "group delete"*) touch "$S/group-deleted" ;;
  *) echo "unexpected az call: $*" >&2; exit 9 ;;
esac
'''


@NEEDS_BASH
class TeardownAll(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        (self.home / "bin").mkdir()
        (self.home / "bin" / "az").write_text(STUB)
        (self.home / "bin" / "az").chmod(0o755)
        self.state = self.home / "state"
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def given(self, *names: str, deleted: list[str] | None = None):
        for n in names:
            (self.state / n).write_text("")
        if deleted is not None:
            (self.state / "deleted").write_text("".join(f"{row}\n" for row in deleted))

    def run_all(self, **extra: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        calls_file = self.home / "calls.txt"
        if calls_file.exists():
            calls_file.unlink()
        env = {"PATH": f"{self.home / 'bin'}:/usr/bin:/bin", "HOME": str(self.home), "ACCT": ACCT, "PROJ": PROJ,
               "SUBNET": SUBNET, "DELETED_ID": DELETED_MIXED, "ASSUME_YES": "1", "FINAL": "1", "POLL_SECONDS": "0",
               "SAL_WAIT_MINUTES": "1", **extra}
        proc = subprocess.run(["bash", str(SCRIPT), "all"], capture_output=True, text=True, env=env, timeout=120)
        calls = calls_file.read_text().splitlines() if calls_file.exists() else []
        return proc, calls

    @staticmethod
    def index(calls: list[str], prefix: str) -> int:
        return next(i for i, c in enumerate(calls) if c.startswith(prefix))

    def test_caphosts_already_gone_and_project_present(self):
        self.given("account.exists", "project.exists")
        proc, calls = self.run_all(PROJECT_POLLS="2")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("No capability host on project ga-proj-labtest.", proc.stdout)
        self.assertIn("No capability host on account ga-ai-labtest.", proc.stdout)
        self.assertFalse(any("--method delete" in c and "capabilityHosts" in c for c in calls))
        project_delete = self.index(calls, f"rest --method delete --url https://management.azure.com{PROJ}?api-version=2025-06-01")
        account_delete = self.index(calls, "cognitiveservices account delete")
        self.assertLess(project_delete, account_delete)
        self.assertIn("Deleted and purged: ga-ai-labtest", proc.stdout)
        self.assertTrue((self.state / "group-deleted").exists())

    def test_full_order_with_caphosts_and_project(self):
        self.given("account.exists", "project.exists", "caphost-proj.exists", "caphost-acct.exists")
        proc, calls = self.run_all()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        order = [self.index(calls, p) for p in (
            f"rest --method delete --url https://management.azure.com{PROJ}/capabilityHosts/",
            f"rest --method delete --url https://management.azure.com{ACCT}/capabilityHosts/",
            f"rest --method delete --url https://management.azure.com{PROJ}?",
            "cognitiveservices account delete",
            "cognitiveservices account purge",
            "network vnet subnet show",
            "group delete")]
        self.assertEqual(order, sorted(order))

    def test_caphost_delete_answering_404_counts_as_gone(self):
        self.given("account.exists", "caphost-acct.exists", "caphost-acct.race")
        proc, _ = self.run_all()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Already gone: caphostacct", proc.stdout)

    def test_caphost_wait_defaults_to_45_minutes_with_progress(self):
        self.given("account.exists", "caphost-acct.exists")
        proc, _ = self.run_all(CAPHOST_ACCT_POLLS="13")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("waiting up to 45 min", proc.stdout)
        self.assertIn("about 1 of 45 min", proc.stdout)
        self.assertIn("about 2 of 45 min", proc.stdout)
        self.assertIn("Deleted: caphostacct", proc.stdout)

    def test_caphost_timeout_stops_before_the_account(self):
        self.given("account.exists", "caphost-acct.exists")
        proc, calls = self.run_all(CAPHOST_WAIT_MINUTES="1", CAPHOST_ACCT_POLLS="1000")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("STOP: capability host caphostacct still present after 1 min", proc.stderr)
        self.assertIn("CAPHOST_WAIT_MINUTES", proc.stderr)
        self.assertFalse(any(c.startswith("cognitiveservices account delete") for c in calls))

    def test_project_timeout_stops_before_the_account(self):
        self.given("account.exists", "project.exists")
        proc, calls = self.run_all(PROJECT_WAIT_MINUTES="1", PROJECT_POLLS="1000")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("STOP: project ga-proj-labtest still present after 1 min", proc.stderr)
        self.assertFalse(any(c.startswith("cognitiveservices account delete") for c in calls))
        self.assertFalse((self.state / "group-deleted").exists())

    def test_purge_failure_then_rerun_purges_before_the_subnet_wait(self):
        self.given("account.exists", "project.exists", "purge-fail")
        first, calls = self.run_all()
        self.assertNotEqual(first.returncode, 0)
        self.assertIn("is deleted but not purged", first.stderr)
        self.assertFalse(any(c.startswith("network vnet") for c in calls))
        self.assertFalse((self.state / "group-deleted").exists())

        second, calls = self.run_all()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertFalse(any(c.startswith("cognitiveservices account delete") for c in calls))
        self.assertLess(self.index(calls, "cognitiveservices account purge"), self.index(calls, "network vnet list"))
        self.assertIn("Clear: agent", second.stdout)
        self.assertTrue((self.state / "group-deleted").exists())

    def test_lowercase_resourcegroups_ids_are_purged_and_other_groups_left(self):
        other = DELETED_LOWER.replace(RG, "rg-someone-else").replace("ga-ai-labtest", "ga-ai-other")
        upper = DELETED_LOWER.replace(RG, RG.upper()).replace("ga-ai-labtest", "ga-cs-labtest")
        self.given(deleted=[f"{DELETED_LOWER}\tga-ai-labtest\tcanadaeast",
                            f"{upper}\tga-cs-labtest\tcanadaeast",
                            f"{other}\tga-ai-other\tcanadaeast"])
        proc, calls = self.run_all()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        purges = [c for c in calls if c.startswith("cognitiveservices account purge")]
        self.assertEqual(len(purges), 2, purges)
        self.assertTrue(any("-n ga-ai-labtest" in c for c in purges))
        self.assertTrue(any("-n ga-cs-labtest" in c for c in purges))
        self.assertFalse(any("ga-ai-other" in c for c in purges))
        self.assertIn("ga-ai-other", (self.state / "deleted").read_text())

    def test_declined_purge_stops_before_the_subnet_wait(self):
        self.given(deleted=[f"{DELETED_LOWER}\tga-ai-labtest\tcanadaeast"])
        env = {"ASSUME_YES": ""}
        calls_file = self.home / "calls.txt"
        proc = subprocess.run(["bash", str(SCRIPT), "all"], input="y\nn\n", capture_output=True, text=True, timeout=60,
                              env={"PATH": f"{self.home / 'bin'}:/usr/bin:/bin", "HOME": str(self.home), "ACCT": ACCT,
                                   "PROJ": PROJ, "SUBNET": SUBNET, "DELETED_ID": DELETED_MIXED, "FINAL": "1",
                                   "POLL_SECONDS": "0", **env})
        calls = calls_file.read_text().splitlines() if calls_file.exists() else []
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("isn't purged, so the subnet links won't clear", proc.stderr)
        self.assertFalse(any(c.startswith("network vnet") for c in calls))


if __name__ == "__main__":
    unittest.main()
