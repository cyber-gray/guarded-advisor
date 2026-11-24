#!/usr/bin/env bash
# C6 matching for one ground-truth run date (w3-harness, drafted 2026-11-15). Read-only. Laptop, as T with standing
# Reader: RedTeamRun_CL, AgentToolAudit_CL and CDBDataPlaneRequests are General tables. Run sheet "Mon 11-16", row 15.
#
# Usage: bash scripts/c6_match.sh <T0 as YYYY-MM-DDTHH:MM:SSZ> <date YYYYMMDD>
#   Run it at least 10 minutes after the last call, so the audit rows have arrived.
#
# Intake C6 test: "Any RedTeamRun_CL run without a matching log row" fails C6. For each run in
# redteam/plans/run-<date>.json it reports: the ground-truth row (missing = the run doesn't count), whether that row was
# written before the run's first audit row, and whether AgentToolAudit_CL holds what the plan expects. Runs with
# tool_log "none" make no tool call by design; they're n/a, never passes. Verdicts: scripts/lib/c6-match.jq.
# Order (D-045): rows are registered on the laptop, runs happen on the jumpbox, and "registered first" compares the
# laptop's started_at with the jumpbox's first audit row, so the two clocks' offset (Mon row 3) bounds that check.
# "ground-truth rows with no planned run" also shows whether row 4a's SMOKE row got through (outcome open, V3 2026-10-23).
# This script reads harness_verdict only to compare it with the plan; it isn't an outcome query.
# Prints run labels, counts and yes/no only: no object IDs, claim content or prompt text. Raw JSON goes to the
# private folder. The caller check maps audit callers to aliases with entitlements.json inside the query.
set -euo pipefail
umask 077
T0=${1:?usage: c6_match.sh <T0> <YYYYMMDD>}
D=${2:?usage: c6_match.sh <T0> <YYYYMMDD>}
[[ $T0 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "STOP: T0 must be YYYY-MM-DDTHH:MM:SSZ"; exit 1; }
[[ $D =~ ^[0-9]{8}$ ]] || { echo "STOP: date must be YYYYMMDD"; exit 1; }
cd ~/Projects/guarded-advisor
PLAN=redteam/plans/run-$D.json
[[ -f $PLAN ]] || { echo "STOP: no plan file $PLAN"; exit 1; }
python3 -I redteam/ground_truth.py list --plan "$PLAN" >/dev/null || { echo "STOP: the plan doesn't validate"; exit 1; }
P1=~/guarded-advisor-private/pim-2026-11/p1-t-and-g.json
PRIV=~/guarded-advisor-private/w3-docs
mkdir -p "$PRIV" && chmod 700 "$PRIV"
STAMP=$(date -u +%Y%m%dT%H%MZ)
az() { command az "$@" </dev/null; }
mask() { jq -rn --arg m "$1" 'if ($m | length) > 8 then $m[0:4] + "..." + $m[-4:] else $m end'; }

echo "About to run one read-only query on ga-law-shared as T: RedTeamRun_CL, AgentToolAudit_CL and CDBDataPlaneRequests since $T0, matched to $PLAN."

# Guards, as in c8_rate.sh: the lab subscription (from P1) and T.
SUB=$(az account show --query id -o tsv)
LAB=$(jq -r '[.[] | select(.roleDefinitionName=="Owner") | .scope | select(test("^/subscriptions/[^/]+$")) | sub("^/subscriptions/";"")] | unique | if length==1 then .[0] else error("expected one subscription in P1") end' "$P1")
[[ -n $SUB && $SUB == "$LAB" ]] || { echo "STOP: wrong subscription"; exit 1; }
ME=$(az ad signed-in-user show --query id -o tsv)
[[ $(mask "$ME") == "6d4c...2a4d" ]] || { echo "STOP: signed-in account is not T"; exit 1; }
WSID=$(az monitor log-analytics workspace show -g rg-guardedadvisor-shared -n ga-law-shared --query customerId -o tsv)
[[ -n $WSID ]] || { echo "STOP: could not read ga-law-shared"; exit 1; }

# The plan and the alias map as KQL datatables. Plan values are validated labels (ground_truth.py list above);
# entitlement keys are object IDs and aliases are fixed names, so nothing here needs escaping.
PLAN_DT=$(jq -r '[.runs[] | "\"\(.redteam_id)\", \"\(.case)\", \"\(.caller)\", \"\(.tool_log)\", \"\(.expect)\""] | join(",\n  ")' "$PLAN")
ALIAS_DT=$(jq -r '[.caseloads | to_entries[] | select(.key | test("^[0-9a-f-]{36}$")) | select(.value.alias | test("^[a-z]{1,16}$")) | "\"\(.key)\", \"\(.value.alias)\""] | join(", ")' scenarios/larkfield/entitlements.json)
[[ -n $PLAN_DT && -n $ALIAS_DT ]] || { echo "STOP: empty plan or alias table"; exit 1; }

read -r -d '' Q <<KQL || true
let t0 = datetime($T0);
let plan = datatable(rid:string, case_id:string, planned_caller:string, tool_log:string, expect:string) [
  $PLAN_DT
];
let aliases = datatable(oid:string, alias:string) [ $ALIAS_DT ];
let gt = RedTeamRun_CL
  | where TimeGenerated >= t0
  | summarize gt_rows = count(), gt_at = min(started_at), gt_caller = take_any(caller), gt_expect = take_any(harness_verdict)
      by rid = redteam_id;
let au = AgentToolAudit_CL
  | where TimeGenerated >= t0 and isnotempty(redteam_id)
  | join kind=leftouter aliases on \$left.caller == \$right.oid
  | extend who = iff(isempty(alias), "other", alias)
  | summarize audit_rows = count(), allows = countif(action == "read" and decision == "allow"),
      denies = countif(decision == "deny"), nic = countif(decision == "deny" and reason == "not_in_caseload"),
      withheld = countif(decision == "withheld"), audit_at = min(TimeGenerated), callers = make_set(who),
      acts = make_set(strcat(action, ":", decision))
      by rid = redteam_id;
union
  (plan
    | join kind=leftouter gt on rid
    | join kind=leftouter au on rid
    | extend gt_rows = coalesce(gt_rows, 0), audit_rows = coalesce(audit_rows, 0)
    | extend registered_first = iff(isnull(gt_at) or isnull(audit_at), "n/a", iff(gt_at <= audit_at, "yes", "NO")),
        caller_ok = iff(audit_rows == 0, "n/a", iff(tostring(callers) == tostring(pack_array(planned_caller)), "yes", "NO")),
        gt_caller_ok = iff(gt_rows == 0, "n/a", iff(gt_caller == planned_caller, "yes", "NO")),
        expect_ok = iff(gt_rows == 0, "n/a", iff(gt_expect == expect, "yes", "NO"))
    | project k = "run", rid, case_id, planned_caller, tool_log, expect, gt_rows, registered_first, caller_ok,
        gt_caller_ok, expect_ok, audit_rows, allows, denies, nic, withheld, acts),
  (au | join kind=leftanti plan on rid | where rid contains "-$D" | project k = "unplanned_audit", rid, audit_rows),
  (gt | join kind=leftanti plan on rid | project k = "unplanned_gt", rid, gt_rows),
  (RedTeamRun_CL | summarize n = count() | project k = "positive_control", n),
  (CDBDataPlaneRequests
    | where TimeGenerated >= t0
    | where tostring(column_ifexists("DatabaseName", "")) == "larkfield" and tostring(column_ifexists("CollectionName", "")) == "claims"
    | summarize n = count() by op = OperationName, rtype = tostring(column_ifexists("RequestResourceType", "")),
        StatusCode = tostring(StatusCode)
    | project k = "claim_reads", op, rtype, StatusCode, n)
KQL
OUT="$PRIV/raw-$STAMP-c6-match.json"
az monitor log-analytics query --workspace "$WSID" --timespan P30D --analytics-query "$Q" -o json >"$OUT"

# Positive control: RedTeamRun_CL is readable (E07's SMOKE row, 2026-10-22, is inside 30 days until 2026-11-21).
PC=$(jq -r '[.[] | select(.k == "positive_control") | .n | tonumber] | add // 0' "$OUT")
echo "positive control: RedTeamRun_CL rows in 30 days: $PC"
[[ $PC -ge 1 ]] || { echo "STOP: 0 rows. RedTeamRun_CL isn't readable, or nothing was ever registered; nothing below would be trustworthy."; exit 1; }
echo "--- per run (run | verdict | registered first | caller | audit rows)"
jq -r -L scripts/lib 'include "c6-match"; report' "$OUT"
echo "raw file: $OUT"
