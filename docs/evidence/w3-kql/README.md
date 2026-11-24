# w3-kql: D5 smoke test in the Defender portal, 2026-11-10

Screenshots from the D5 smoke test (`scripts/smoke_d5.py`, C2) in the 2026-11-10 split session (the session log; `docs/findings.md`, 2026-11-10). The portal shows Toronto time (UTC-5); the UTC column converts it. The smoke rows were sent at 01:45:51.514Z.

| File | Shows | Time (UTC) |
|---|---|---|
| `01-defender-incident-list.png` | Defender portal, Incidents, filtered to Status New and In progress and to severity High, Medium and Low: 1 incident, "D5: two or more entitlement denials in one session", ID 1, Medium | Capture time not recorded; after the incident was created at 01:52:54Z |
| `02-defender-incident-1-attack-story.png` | Incident ID 1, Attack story: Active alerts 2/2; Alerts (2); Assets (1), one User. First activity 7:47:43 PM, last activity 8:52:43 PM, creation 8:52:54 PM, last update 8:57 PM Toronto. Two D5 alerts at 7:47 PM and 7:52 PM, each on the synthetic caller | Created 01:52:54Z; captured after the last update at 01:57Z |
| `03-defender-incident-1-alerts.png` | Incident ID 1, Alerts (2): both D5, Medium, New, Suspicious activity; impacted asset the synthetic caller; correlation reason "Same Analytic Rule..." (truncated); detection source scheduled detection | Captured after 01:57Z |
| `04-azure-sentinel-incidents-moved-to-defender.png` | Azure portal, Microsoft Sentinel, Incidents, workspace `ga-law-shared`: "This page has been moved to the Defender portal for the optimal, unified SecOps experience", with a link to the Defender portal | Not recorded |

**Masked:** in 01 to 03, the account bar and avatar (top right) are blacked out; 04 is cropped below the account bar.

**Left visible on purpose:** the synthetic caller `00000000-0000-0000-0000-0000...`, which is `SMOKE_CALLER` in `scripts/smoke_d5.py`. It's a fixed synthetic ID, built at run time from `uuid.UUID(int=0xD5)`, that no Entra object has.

**Not shown:** no tenant ID, subscription ID or real object ID appears.
