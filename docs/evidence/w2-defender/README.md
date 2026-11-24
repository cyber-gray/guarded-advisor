# w2-defender: Defender for AI Services plan evidence (Mon 2026-11-16)

Sunday Part 2, D4 (the working run sheet): the Defender plans page after D3 turned the AI Services plan on (2026-11-15T21:35:03Z). Captured by T in the Azure portal, Monday 2026-11-16, 06:46 to 06:49 Toronto (11:46 to 11:49Z), **without Owner** (standing Reader), so the page shows "You do not have sufficient permissions to change Defender plans", as expected. Read-only. Findings: `docs/findings.md`, 2026-11-15, "Defender for AI Services: the plan counts 1 of the lab's 2..." and "Defender for App Service was already on...".

- **Masking:** the account bar (top right) is blacked out in 01; 02 and 02b are cropped below it. The subscription display name "Azure subscription 1" is visible. No IDs, UPNs or tenant names.
- **Metadata:** PNG chunks `caBX` (C2PA Content Credentials, a standing false-positive class) and `iCCP` only.

| File | What it shows | Supports |
|---|---|---|
| `01-plans-cspm-cwpp.png` | Defender plans, CSPM and the top of CWPP: the permissions banner; Foundational CSPM Free, coverage Full; Defender CSPM Off (4 resources); Servers Off; **App Service On, 0 instances, coverage Full**; Databases, Storage, Containers Off | D4; App Service already on with nothing to bill (D0 read it `Standard` with no trial) |
| `02-plans-ai-services.png` | CWPP: **AI Services On, "1 AI resources", monitoring coverage "Partial"** with a Settings link; Key Vault, Resource Manager and APIs Off | D4 matches D3; the lab has 2 Cognitive Services accounts (AIServices and ContentSafety) |
| `02b-ai-services-settings.png` | AI Services settings: "Enable suspicious prompt evidence" **On** (portal text: only suspicious segments, sensitive data and secrets redacted, available in the Defender portal as part of each alert); "AI Model Security (Preview)" **Off**. No "Data security for AI interactions" row | D4; C5 note on prompt evidence (intake section 8) |

**DF-1 recheck (Tuesday, about 02:25 to 02:55Z on 11-18, G in the Defender portal, read-only):** no alert for DF-1 (sent 2026-11-16T18:25:12Z). Findings, 2026-11-16, "DF-1: Prompt Shields blocked the jailbreak...". Nothing to mask in 03 to 07: no account bar, names or IDs.

| File | What it shows | Supports |
|---|---|---|
| `03-defender-alerts-G-zero-unfiltered.png` | Investigation & response > Alerts, no filter: **0 Alerts** | No DF-1 alert visible to G |
| `04-defender-alerts-G-30days-zero.png` | Same list with the time range opened, **30 Days** selected: 0 Alerts | The zero covers 30 days |
| `05-alert-tuning-rules-G.png` | Settings > Microsoft Defender XDR > Alert tuning: 22 items, built-in rules for DLP, Endpoint and Office 365 (rows 1 to 11) | No tuning rule suppresses Defender for Cloud alerts |
| `05b-alert-tuning-rules-G-rows12-22.png` | The same list, rows 12 to 22: Office 365 and Endpoint rules only | As 05 |
| `06-ah-alertinfo-since-T0-zero.png` | Advanced hunting: `AlertInfo` where `Timestamp >= datetime(2026-11-16T16:35:00Z)`, summarized by source, title and severity: 0 items | Nothing since Monday's T0 |
| `07-ah-alertinfo-30d-by-source-zero.png` | Advanced hunting: `AlertInfo` over 30 days by `ServiceSource`: 0 items | G sees no alerts of any source, so its visibility is unproven |

Checked before committing 03 to 07: PNG chunks `caBX` (C2PA, standing false-positive class) and `iCCP` only.

**Next number: 08.**
