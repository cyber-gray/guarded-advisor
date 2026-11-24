# C8 review checklist (Larkfield, Mon 2026-11-16)

A blank template. Copy it to the private folder (`~/guarded-advisor-private/w3-docs/c8-review-20261116.md`) and fill in the copy only. **No draft text goes in either file:** codes, yes/no, field names and conversation IDs only. The adjudication rows (`agent/adjudicate.py`) carry the outcome and rationale code to `AdjudicationLog_CL`. This sheet records why.

**Intake condition C8:** every draft carries the AI-generated label and the source lines, and none has a material factual error against the claim record. The agree/override rate is reported, not a pass criterion.

**Material factual error (fixed 2026-11-14, before results):** a wrong value for restrictions, plan, benefit type, status, leave start or expected return-to-work date. Also any statement about the member's condition or work capacity that neither the claim record nor a retrieved document supports.

**Record to compare against** (jumpbox, synthetic data; the screen only, nothing saved):

```powershell
(Get-Content scenarios\larkfield\data\claims.json -Raw | ConvertFrom-Json).claims | Where-Object claim_id -eq '<ID>' |
  Select-Object claim_id, plan, benefit_type, status, leave_start, expected_rtw, restrictions, condition_category, condition_summary, documents | Format-List
```

**Columns:**
- **L:** the draft starts with "AI-generated draft for case manager review. Not a decision."
- **S:** the Sources line is present.
- **R:** the "Claim records used" line is present and names this claim.
- **E:** material error, yes or no. If yes, name the field (for example `expected_rtw`) and whether it was wrong or unsupported.
- **Outcome:** `agree`, `modified` or `rejected`.
- **Code:** one of `matches_source`, `factual_error`, `missing_information`, `policy_judgment`, `other`.

**Rules for outcome and code:**
- No material error and nothing changed: `agree` with `matches_source`.
- Any material error: `modified` or `rejected` with `factual_error`.
- Nothing wrong but something missing: `modified` with `missing_information`.
- A judgment call about the plan rather than the facts: `policy_judgment`.
- **Decide before running `adjudicate.py`.** Don't change a recorded outcome; a second row for the same draft is reported as a duplicate.

| # | Case manager | Claim | Conversation ID (masked: first 4 ... last 4) | L | S | R | E (field) | Outcome | Code | adjudicate.py exit |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | alder | LM-CLM-2026-0002 | | | | | | | | |
| 2 | alder | LM-CLM-2026-0016 | | | | | | | | |
| 3 | alder | LM-CLM-2026-0019 | | | | | | | | |
| 4 | alder | LM-CLM-2026-0020 | | | | | | | | |
| 5 | birch | LM-CLM-2026-0001 | | | | | | | | |
| 6 | birch | LM-CLM-2026-0003 | | | | | | | | |
| 7 | birch | LM-CLM-2026-0004 | | | | | | | | |
| 8 | cedar | LM-CLM-2026-0005 | | | | | | | | |
| 9 | cedar | LM-CLM-2026-0010 | | | | | | | | |
| 10 | cedar | LM-CLM-2026-0014 | | | | | | | | |

**C8 result:**
- **Pass:** all 10 rows have L, S and R = yes and E = no.
- **Fewer than 10 drafts:** C8 is "not tested".
- **Withheld drafts:** a draft withheld by the decision checker is recorded with its reason, and C8 is judged on the ones shown.
- **The rate:** comes from `scripts/c8_rate.sh` (run sheet row 17), never from this sheet.
