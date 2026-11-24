# w2-dspm: Purview negative test evidence (Sun 2026-11-15)

Part 0b of the Sunday run sheet: one case manager, `cm-alder`, licensed so Tuesday's Purview Audit search has a licensed user with a mailbox (findings, 2026-11-15).

Part 2, DP1 (Sun 2026-11-15, T with Owner): the Foundry Control Plane Purview toggle, before and after (02, 03). Tuesday's Purview Audit (A2), A4 and Data Location (A3) checks, 2026-11-18 UTC, are 04 to 11 (findings, 2026-11-17, "Purview Audit was never recording..." and 2026-11-18, "The Microsoft 365 Data Location card..."). Wednesday 11-18's switch-on search, Audit Reader check and toggle-off are 12 to 17 (same findings, updated 11-18).

- **Masking:** in 01, email addresses and T's display name are blacked out. 02 and 03 show only the subscription display name. Each PNG carries a C2PA Content Credentials block (`caBX` chunk) with three UUIDs: a standing false-positive class, not tenant data. No `eXIf` or `iTXt` metadata.

| File | What it shows | Masked |
|---|---|---|
| `02-purview-toggle-off.png` | DP1 before: Foundry (new) portal, Operate > Compliance > Data security and governance, subscription "Azure subscription 1", "Powered by Microsoft Purview" toggle **off**, "Your AI data estate is not protected"; the note "If PayG billing isn't set up in Purview, only Purview Audit integration will be supported." Captured by T with Owner active, about 21:44Z | Nothing to mask: no account bar, names or IDs shown |
| `03-purview-toggle-on.png` | DP1 after (about 21:46Z): toggle **on**, "Purview covering visibility across 0 agents and 0+ daily interactions across 1 subscription", "Purview is connected but no policies are configured." No refusal or network-isolation message. DP2 found no ARM write for the toggle (portal-only; runbook) and 0 `Microsoft.Purview/accounts` (findings, 2026-11-15, "The Purview toggle turned on...") | Nothing to mask |
| `01-alder-mailbox.png` | L2: Exchange admin center, Recipients > Mailboxes, signed in as G (accepted here, although the Microsoft 365 admin center refused G at L1). 2 items: "Case Manager Alder (synthetic)", **UserMailbox**, archive None, last modified 11/15/2026 3:25 PM Toronto (20:25Z), about 58 minutes after the E5 seat was assigned (19:27Z); and T's mailbox (UserMailbox, 2:30 PM) | Both email addresses; T's display name |
| `04-audit-search-T-failed-load.png` | A2, T (Audit Reader active), Purview Audit > Search, about 00:38Z on 11-18: "Sorry, we're having trouble figuring out if activity is being recorded"; form disabled; jobs "Failed to load data" | Nothing to mask: the account bar shows an initial only |
| `05-audit-reader-members-T-expiry.png` | A4, Purview role group Audit Reader > Members: 1 item, T, User, Organization, expiration Nov 18, 2026 (left to expire; removal confirmed Wednesday) | T's display name and UPN |
| `06-audit-search-G-start-recording-banner.png` | A2, G, same page: the same "trouble figuring out" line plus the **"Start recording user and admin activity"** banner; form disabled | Nothing to mask: cropped above the account bar |
| `07-audit-search-G-after-start-recording.png` | G after selecting the banner (about 02:05Z): banner gone, search fields editable, Search enabled; jobs still "Failed to load data" | Nothing to mask |
| `08-audit-G-banner-returned-after-70min.png` | Read-back about 03:15Z: the banner is back and the status still unreadable; form disabled | Nothing to mask |
| `09-audit-G-after-second-click.png` | G after the second banner selection (about 03:15Z): fields editable; the "trouble figuring out" line still shown | Nothing to mask |
| `10-audit-G-probe-search-input-error.png` | Probe about 03:20Z, range Nov 16 to Nov 17, no filters: "Error with the inputs provided … Please check if the IPAddress, Site ID are valid and Search Duration is less than 6 months."; jobs "Failed to load data"; the "trouble figuring out" line gone | The request ID |
| `11-data-location-card-G-product-terms-unavailable.png` | A3, G, Microsoft 365 admin center > Org settings > Organization profile > Data location, about 03:25Z: "Product Terms residency is unavailable. We couldn't load this setting."; no geography shown | Nothing to mask |

| `12-audit-G-status-cleared-20261118.png` | Wednesday 11-18, G, Purview Audit > Search: the status recovered overnight. No "trouble figuring out" line, no banner, form enabled; searches completed 0, active 0; "No search history available" | The account bar |
| `13-audit-G-w1-search-queued.png` | G started search "W1 audit switch-on": Queued, created Nov 18, 2026 10:0x (portal time). The list shows 2 items; one row is in the crop. The form fields show the page defaults, not the search's range (the range is in `15b`) | "Search performed by" column |
| `14-audit-reader-members-T-still-member-20261118.png` | Audit Reader > Members: 1 item, T, User, Organization, expiration Nov 18, 2026: still a member on 11-18 | T's display name |
| `15-audit-w1-job-completed-0.png` | "W1 audit switch-on": Completed, 100%, search time 13m 2s, total results **0**; searches completed 1 | Nothing to mask: cropped above the account bar |
| `15b-audit-w1-results-0-items.png` | The results page: "Search Query Information: Tue, 17 Nov 2026 00:00:00 GMT to Wed, 18 Nov 2026 10:00:00 GMT, Set-AdminAuditLogConfig", "Total Result Count: 0 items", "No data available". The header also shows unfilled placeholders `{9} {10} {11} {12}` (portal rendering) | Nothing to mask |
| `16-foundry-purview-toggle-off-1545Z.png` | T with Owner, Foundry (new) portal, Operate > Compliance > Data security and governance, "Azure subscription 1", 15:45Z: "Powered by Microsoft Purview" toggle **off**, "Your AI data estate is not protected", the same PayG note as `02`. DP2 for 15:45Z to 16:00Z found no write for the toggle (findings, 2026-11-15, "The Purview toggle turned on...", updated 11-18) | Nothing to mask: no account bar |
| `17-audit-reader-T-member-expiry-nov18-1416.png` | Audit Reader > Members at 14:16 Toronto (19:16Z): T still the one member, expiration Nov 18, 2026. Removal to be confirmed on 11-19 | T's display name |

Checked before committing 04 to 11: PNG chunks `caBX` (C2PA, standing false-positive class) and `iCCP` only; no IDs, UPNs or tenant names in the pixels.

Checked before committing 12 to 17 (2026-11-18): each PNG has only `IHDR`, `iCCP`, `caBX` and `IEND`; the 4 GUID-shaped strings per file are in `caBX` (C2PA, standing false-positive class); no `eXIf`, `tEXt`, `iTXt` or `zTXt`; no email addresses. Pixels: no IDs, UPNs or names visible; T appears only as the avatar initial.

**Next number: 18.**
