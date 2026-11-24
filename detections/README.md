# Detections

Queries and analytics rules on generic fields (D-012). Analytics rules (YAML plus KQL), the playbook and the coverage query are added in week 3 (`w3-kql`).

| File | What it computes | Condition |
|---|---|---|
| `c8-agree-override-rate.kql` | Agree and override rate per scenario from `AdjudicationLog_CL` | C8 |
| `d5-entitlement-denials.kql` | D5: two or more `decision == "deny"` for one `caller` in one `conversation_id` in `AgentToolAudit_CL`; loaded by the Sentinel rule in `infra/sentinel.bicep` | C2 |

## Rule for every `AgentToolAudit_CL` query

**Every `AgentToolAudit_CL` query other than D5 excludes `scenario == "smoke"`** (for example `| where scenario != "smoke"` before any `summarize`). Smoke rows come from `scripts/smoke_d5.py`: three synthetic deny rows that check the D5 rule (`redteam_id` `d5smoke-<TAG>`), not agent decisions. D5 itself must see them. `agent/tests/test_d5_detection.py` checks the D5 query and the smoke rows.

## Rule for every `AdjudicationLog_CL` query

**Every query on `AdjudicationLog_CL` must exclude `record_id == "SMOKE"`** (for example `| where record_id != "SMOKE"` before any `summarize`). SMOKE rows come from `scripts/smoke_adjudication.py`: they check the ingestion path for the `w2-privread` verification and aren't adjudications. `agent/tests/test_smoke_adjudication.py` checks this for `c8-agree-override-rate.kql`; a new query needs the same filter and the same test.

`AdjudicationLog_CL` is Protected: reading it needs Privileged Monitoring Data Reader (`w2-privread`). It holds IDs and fixed codes only, never claim content (D-022).
