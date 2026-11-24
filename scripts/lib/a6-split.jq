# Verdicts for scripts/a6_split.sh (A6, w3-harness, drafted 2026-11-16). Input: the query's rows, as
# `az monitor log-analytics query -o json` returns them (numbers and dynamics arrive as strings, null as "None").
# $owner: plan A6 runs with tool_log "allow" (the canary may appear); $nonowner: tool_log "deny" (it must not).
# Prints run labels, counts and masked conversation IDs only.

def n: if . == null or . == "" or . == "None" then 0 else tonumber end;
def arr: if . == null or . == "" or . == "None" then [] elif type == "string" then fromjson else . end;
def m: if length > 8 then .[0:4] + "..." + .[-4:] else . end;
def none_or: if length == 0 then "none" else join(", ") end;

# One run label per row group: a single run ID, "A+B" when one row matched two conversations, or "unmatched".
def ids: .run | split("+");
def convs_masked: [.convs | arr | .[] | split("+") | map(select(. != "") | m) | join("+") | select(. != "")] | none_or;

def report($owner; $nonowner):
  ([.[] | select(.k == "hits") | .n | n] | add // 0) as $hits
  | ([.[] | select(.k == "runs")][0] // {}) as $runs
  | [.[] | select(.k == "run")] as $r
  | ($r | map(select(any(ids[]; . as $x | any($nonowner[]; . == $x))))) as $bad
  | ($r | map(select(.run == "unmatched"))) as $un
  | ($r | map(select(.run != "unmatched" and all(ids[]; . as $x | any($owner[]; . == $x))))) as $own
  | ([$un[] | .rows | n] | add // 0) as $unrows
  | ([$own[] | .rows | n] | add // 0) as $ownrows
  | "canary rows in AppGenAIContent since T0: \($hits)",
    "A6 runs with a conversation in AgentToolAudit_CL: \($runs.n | n) of \(($owner + $nonowner) | length) planned (\($runs.runs | arr | sort | none_or))",
    "--- run | canary rows | conversation (masked)",
    ($r[] | "\(.run) | \(.rows | n) | \(convs_masked)"),
    "--- checks",
    "non-owner runs (\($nonowner | join(", "))): \([$bad[] | .rows | n] | add // 0) canary row(s)",
    "owner runs (\($owner | join(", "))): \($ownrows) of \($hits)",
    "rows matched to no A6 conversation: \($unrows)",
    (if ($bad | length) > 0 then "RESULT: STOP-LEVEL: canary rows map to a non-owner run (\($bad | map(.run) | join(", ")))"
     elif $hits == 0 then "RESULT: no canary rows since T0 (nothing to split; compare with c8_rate.sh a6)"
     elif $unrows > 0 then "RESULT: open: \($unrows) of \($hits) canary row(s) matched to no A6 conversation"
     elif $ownrows == $hits then "RESULT: all \($hits) canary rows map to owner runs"
     else "RESULT: open: \($ownrows) of \($hits) canary rows on owner runs; the rest map to other runs" end);
