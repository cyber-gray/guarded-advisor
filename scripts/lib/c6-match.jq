# Verdicts for scripts/c6_match.sh (C6, w3-harness, drafted 2026-11-15). Input: the query's rows, as
# `az monitor log-analytics query -o json` returns them (numbers, booleans and dynamics can arrive as strings).
# Intake C6 test: "Any RedTeamRun_CL run without a matching log row". A run whose plan says tool_log "none" makes no
# tool call by design, so there is nothing to match: it is reported as n/a and never counted as a pass.

# `az monitor log-analytics query -o json` prints a null cell as the string "None": union legs without a column
# (positive_control, claim_reads, unplanned_gt) and runs with no audit join (allows, denies, nic, withheld) carry it.
# Seen 2026-11-16 (raw-20261116T1949Z); before this, tonumber stopped the report on "None".
def num: if . == null or . == "" or . == "None" then 0 else tonumber end;

# Run IDs from ground_truth.py smoke are random GUIDs; mask them on screen as the smoke command does (d5170eb).
def mrid: if test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") then .[0:4] + "..." + .[-4:] else . end;

def runs: [.[] | select(.k == "run")];

# Audit action:decision pairs per run (read = a get_claim_summary lookup, answer = a withheld or decision-check row,
# call = an unknown tool). az prints a dynamic cell as a JSON string, or "None" when the run has no audit rows.
def acts: if has("acts") | not then "not in this raw file"
  else .acts | (if . == null or . == "None" or . == "" then [] elif type == "string" then fromjson else . end)
    | if length == 0 then "none" else sort | join(", ") end end;

# Cosmos resource type (Document, Collection, ...) when the query returned it; older raw files have no rtype.
def rtype: (.rtype // "") | if . == "" or . == "None" then "" else " " + . end;

def verdict:
  (.gt_rows | num) as $g | (.audit_rows | num) as $a | (.allows | num) as $al
  | (.denies | num) as $de | (.nic | num) as $nic
  | if $g == 0 and $a == 0 then "not run (no ground truth, no audit rows: cut, or stopped by the gate)"
    elif $g == 0 then "NOT REGISTERED: \($a) audit row(s) without ground truth (C6 fail; the run doesn't count)"
    elif $g > 1 then "REGISTERED \($g) TIMES"
    elif .tool_log == "none" then
      (if $a == 0 then "n/a: no tool call by design, none logged" else "RECORDED: \($a) tool row(s) where none was expected" end)
    elif $a == 0 then "C6 FAIL: no audit row"
    elif .tool_log == "allow" and $al == 0 then "C6 FAIL: no allow row (\($a) other row(s))"
    elif .tool_log == "deny" and ($de == 0 or $nic != $de) then
      "C6 FAIL: expected not_in_caseload denies only (denies \($de), not_in_caseload \($nic))"
    else "C6 match" end;

def applicable: .tool_log == "allow" or .tool_log == "deny";

def none_or: if length == 0 then "none" else join(", ") end;

# One line per planned run, then the totals and the RESULT line.
def report:
  . as $all
  | runs as $r
  | ($r | map(select(applicable))) as $app
  | ($app | map(select(verdict | startswith("not run") | not))) as $appran
  | ($app | map(select(verdict == "C6 match"))) as $ok
  | ($r | map(select(verdict | startswith("NOT REGISTERED")))) as $unreg
  | ($r | map(select(verdict | startswith("not run")))) as $notrun
  | ($r | map(select(verdict | startswith("C6 FAIL")))) as $fail
  | ($r | map(select(.registered_first == "NO"))) as $late
  | ($r | map(select(.caller_ok == "NO" or .gt_caller_ok == "NO"))) as $who
  | ($r | map(select(.expect_ok == "NO"))) as $exp
  | ($r[] | "\(.rid) | \(verdict) | registered first \(.registered_first) | caller \(.caller_ok) | audit rows \(.audit_rows | num) (allow \(.allows | num), deny \(.denies | num), withheld \(.withheld | num)) | actions \(acts)"),
    "--- totals",
    "planned \($r | length) | registered \($r | map(select((.gt_rows | num) > 0)) | length) | ran without ground truth: \($unreg | map(.rid) | none_or) | not run: \($notrun | map(.rid) | none_or)",
    "C6 applicable (tool_log allow or deny, run): \($appran | length) | matched \($ok | length) | failed: \($fail | map(.rid) | none_or)",
    "n/a (no tool call by design, not counted as passes): \($r | map(select(applicable | not)) | map(.rid) | none_or)",
    "registered after the run's first audit row: \($late | map(.rid) | none_or)",
    "caller differs from the plan: \($who | map(.rid) | none_or)",
    "ground-truth expectation differs from the plan: \($exp | map(.rid) | none_or)",
    "audit rows for this date with no planned run: \([$all[] | select(.k == "unplanned_audit") | "\(.rid) x\(.audit_rows | num)"] | none_or)",
    "ground-truth rows with no planned run: \([$all[] | select(.k == "unplanned_gt") | .rid | mrid] | none_or)",
    "claim-store requests since T0 (larkfield/claims, by operation and status): \([$all[] | select(.k == "claim_reads") | "\(.op)\(rtype) \(.StatusCode) x\(.n | num)"] | none_or) | get_claim_summary allows in planned runs: \([$r[] | .allows | num] | add // 0)",
    (if ($unreg | length) > 0 or ($fail | length) > 0 or ($late | length) > 0
     then "RESULT: C6 FAIL for this run date (\(($unreg | length) + ($fail | length) + ($late | length)) issue(s) above)"
     elif ($appran | length) == 0 then "RESULT: nothing to match (no run with a tool call)"
     else "RESULT: C6 match on \($ok | length) of \($appran | length) applicable runs that ran\(if ($notrun | length) > 0 then "; \($notrun | length) planned run(s) not run" else "" end)" end);
