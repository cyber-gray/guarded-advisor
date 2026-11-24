# w3-incident: read-only walk of D5 incident 7 (Sun 2026-11-15)

- **Who and where:** T (lab admin account), standing Reader only, Defender portal (`security.microsoft.com`), about 19:50Z to 20:06Z (14:50 to 15:06 Toronto). Read-only: no assign, status, classification, comment or tag change.
- **Incident:** 7, D5 on the 11-13 M4 run (`c2model-20261113-M4`, birch). Times in the screenshots are Toronto (UTC-5).
- **Masking:** caller object IDs, conversation IDs and the alert ID are blacked out where shown (05, 06). The other screenshots show display names only. Each PNG carries a C2PA Content Credentials block (`caBX` chunk) with three UUIDs: a standing false-positive class, not tenant data. No `eXIf` or `iTXt` metadata.
- **Notes:**
  - The tenant has the **Cases preview** on; "Switch back to incidents" is admin-only (greyed for T in 01).
  - T first got `AADSTS50076` (MFA step-up required) and an empty list; the incidents appeared only after a fresh MFA sign-in.
  - 01 was taken with **Filter set: None**. The Cases view's default filter "Priority score: 15 - 100", which hid all 7 incidents (findings, 2026-11-15), is Tooni's observation and isn't in the screenshot.

| File | What it shows | Masked |
|---|---|---|
| `01-incidents-list.png` | Cases view: 7 D5 incidents (IDs 1 to 7, 2026-11-09 to 11-13), all New, unassigned, Medium, priority score 1; classification and determination Unknown | Nothing |
| `02-incident-summary.png` | Incident 7 summary: New, Medium, unassigned, not set; "Limited access: You have read-only access to this case" banner for T; first and last activity 14:12:43 to 15:12:43, creation 15:19:53 | Nothing |
| `03-attack-graph.png` | Attack graph: one account entity, `cm-birch` | Nothing |
| `04-alert-rule-details.png` | D5 rule name and description; category Suspicious activity; detection source Scheduled detection; service source Microsoft Sentinel; MITRE ATT&CK techniques Not Set | Nothing |
| `05-alert-query-results.png` | Query results: caller, deny_count 2, first_seen 15:08:26, last_seen 15:08:29, record_ids `LM-CLM-2026-0002` and `-0005`, redteam_id `c2model-20261113-M4`, scenario larkfield | Caller object ID, conversation ID |
| `06-alert-panel.png` | Alert side panel: Medium, New, classification Not set, unassigned; MITRE techniques "-" | Caller object ID, conversation ID, alert ID |
| `07-incident-activity.png` | 3 automated activities at 15:19 by Microsoft Defender XDR: case created, alert linked, priority score changed from Not set to 1; no human activity | Nothing |
