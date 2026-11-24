# Egress posture of one sandbox, from a data-plane GET of the sandbox (D-025; findings 2026-10-23).
# Output: one tab-separated line: verdict, then the fields it was decided on.
#   verdict OK       default Deny, inspection Full, no rules or host rules, proxy not skipped
#   verdict FLAG     anything else, including a sandbox with no egress policy (read as default Allow by SDK 0.1.0b4)
#   verdict UNKNOWN  everything else passes but the response doesn't say whether the egress proxy was skipped
# Used by scripts/verify.sh (sandboxes) and scripts/teardown.sh (sandbox listing), so both apply the same rule.
(.egressPolicy // {}) as $p
| ($p.defaultAction // "none") as $default
| ($p.trafficInspection // "none") as $inspection
| ((($p.rules // []) | length) + (($p.hostRules // []) | length)) as $rules
| (if has("skipEgressProxy") then (.skipEgressProxy | tostring) else "absent" end) as $skip
| (if $default != "Deny" or $inspection != "Full" or $rules > 0 or $skip == "true" then "FLAG"
   elif $skip == "absent" then "UNKNOWN"
   else "OK" end) as $verdict
| [$verdict, "default=\($default)", "inspection=\($inspection)", "rules=\($rules)", "skipEgressProxy=\($skip)"]
| @tsv
