# w2-pim evidence: step 4 (R10 on ga-sbx-lab), step 5 (emergency access account) and PIM day 1

Captured 2026-10-27 by Tooni: 01 to 05 and 08 in the Azure portal as T; 06 by the guest Global Administrator; 07 and 09 on the emergency access account's Security info page (runbook, "Emergency access account"). Finding: `docs/findings.md`, "`w2-pim` step 4: PIM holds on the sandbox data plane". Runbook: "R10 Container Apps SandboxGroup Data Owner is PIM-eligible".

Checked before committing: principal names (emails) are blanked; none of these images shows a tenant or directory name, subscription ID or object ID. Display names ("Tooni (lab admin)", "Tooni T") and the subscription display name are visible. 07 and 09 don't show the emergency account's UPN; 07 shows the phone model.

| File | What it shows | Supports |
|---|---|---|
| `01-r10-eligible.png` | PIM, `ga-sbx-lab`, Eligible assignments: Container Apps SandboxGroup Data Owner for "Tooni (lab admin)", User, Direct, no condition | R10 is eligible |
| `02-before-remove-active-assignments.png` | Active assignments before the removal: Data Owner for `ga-jump-lab` (R9) and "Tooni (lab admin)" (R10), both Direct; inherited Foundry User and Owner for "Tooni T" (Owner condition: "Add", so none) and inherited Owner for "Tooni (lab admin)" (condition: "View/Edit") | The standing R10 assignment existed; the guest's unconditioned Owner |
| `03-after-remove-active-assignments.png` | Active assignments after the removal: R10 gone; R9 and the inherited assignments unchanged | R10 is eligible-only. R9 was removed later the same day by CLI (D-026) |
| `04-r10-403-not-activated.png` | Sandboxes portal without activation: "You have read-only access to this sandbox group", "Failed to load sandboxes ADC API error: 403", create buttons disabled | Without activation there's no data-plane access, even with standing Owner |
| `05-r10-loads-activated.png` | Sandboxes portal with the role activated: the group loads, 0 sandboxes, 1 custom image, create enabled | Activation gives access |
| `06-passkey-policy-enabled.png` | Authentication methods policies: Passkey (FIDO2), Microsoft Authenticator, Temporary Access Pass, Software OATH tokens and Email OTP enabled for all users | `w2-pim` step 5: passkey policy on. Observation: TAP, Email OTP and Software OATH enabled for all users (review later) |
| `07-emergency-account-methods.png` | Emergency account Security info: password, Microsoft Authenticator push, device-bound passkey in Authenticator | The passkey was registered (tested by signing in to the Entra admin center) |
| `08-no-active-pim-assignments.png` | PIM My roles > Azure resources > Active assignments: no results | The 4d test activation of R10 expired or was deactivated, confirmed 2026-10-27 |
| `09-emergency-account-passkey-only.png` | Emergency account Security info after removing push: password and the passkey only | Push removed: no weaker, phishable method on the account |
| `10-auth-methods-audit-log.png` | Audit logs, service Authentication Methods, last month: two Authentication Methods Policy Updates on 2026-10-27 and that day's security info registrations; no Temporary Access Pass change | TAP was enabled for all users before the 30-day audit window; origin unknown |

## PIM day 1 (2026-11-03)

11 to 16 are masked text from the CLI as T, lab resources only; anything outside the lab is generalized or omitted, and the details stay in a private folder outside the repo. 17 to 29 are screenshots saved with UPNs, guest identity, tenant domain and subscription ID masked. "T" is T, "G" the guest account, "E" the emergency account. Finding: `docs/findings.md`, 2026-11-03 entries.

| File | What it shows | Supports |
|---|---|---|
| `11-p1-role-assignments.txt` | T's and G's assignments at all scopes, one scope generalized; 0 at root; T's Owner condition hash | P1 baseline; the resource-scope assignment the 2026-10-27 review missed |
| `12-p2-pim-instances.txt` | T's eligible and active instances by `principalId` and `asTarget()`; 0 activated | P2 |
| `13-p3a-foundry-resources.txt` | Foundry and Machine Learning resources; total resource count | G6's control is "not applicable" |
| `14-p3b-guest-activity-lab.txt` | G's Activity Log events from 2026-10-01; 32 earlier non-lab events omitted | The `listKeys` bursts; no G writes on the Foundry account |
| `15-p4-no-hourly-resources.txt` | No Bastion, APIM or public IP; jumpbox deallocated | P4 |
| `16-p5-baseline.txt` | Protection levels; 144 / 0 / 0; the `AgentToolAudit_CL` stop and how it cleared | P5 baseline, no positive control today |
| `17-g1-signin.png` | E's sign-in row: Success, 02:01:00Z | G1 sign-in |
| `18-g1-e5-expiry.png` | E5 trial: expires 2026-11-19, recurring billing off, Active | G1 administrative task; D-009 correction |
| `19-g1-ga-active.png` | PIM > Entra roles > Assignments > Active assignments: Global Administrator for E and G, names masked; Directory Readers for a service principal | G1 |
| `20-g1-myroles-assigned.png` | My roles > Active assignments: Direct, Assigned, Permanent | G1, the authoritative view |
| `21-g2-before-subscriptions.png` | E sees 0 subscriptions before elevating | G2 before |
| `22-g2-after-subscriptions.png` | E sees the lab subscription, role "Specified access" | G2 after |
| `23-g2-audit-entry.png` | Audit: "User has elevated their access", Success, 02:32:38Z | G2 |
| `24-g3-toggle-no.png` | Access management for Azure resources back to No | G3 |
| `25-g3-audit-entry.png` | Audit: User Access Administrator removed, Success, 02:39:20Z | G3 |
| `26-g3-after-subscriptions.png` | E's subscriptions: "Filtered (0 of 1)", none accessible | G3 after |
| `27-g4-audit-entry.png` | Audit: G elevated, Success, 03:35:51Z | G4: a guest Global Administrator can elevate |
| `28-g5-audit-entry.png` | Audit: removal, Success, 03:41:44Z | G5 |
| `29-g5-toggle-no.png` | G's toggle back to No | G5 |
| `30-g1-activity-details-label.png` | PIM Activity details for E's Global Administrator: "Status: Eligible", end time Permanent; no name or UPN visible | The label mismatch; captured after G5, numbered here because it belongs to G1 |

## PIM day 2 (2026-11-04, Toronto; times UTC, some on 2026-11-05)

Text files are masked CLI output as T, copied from a private folder with the subscription replaced by `<sub>`. Lab resources only: resources outside the lab are counted, not named, and G15-pre stays in the private folder. Queries are counts, with no row contents. Screenshots were saved with UPNs masked. Findings: `docs/findings.md`, 2026-11-04 and 2026-11-05 entries.

Evidence 33, 40, 44 and 81 contain the condition hash and the `teardown.sh` hash (64 hex), not IDs; expected hits for pre-publish step 27.

| File | What it shows | Supports |
|---|---|---|
| `31-g6-guest-foundry-user-removed.txt` | One assignment removed; G's Owner and T's R1 unchanged | G6 |
| `32-p2-rerun.txt` | T's eligible and active instances, 0 activated | P2 rerun |
| `33-hash-check.txt` | Condition hash, P1 against live: match | Hard stop for G11 |
| `34-p5-rerun.txt` | 144 / 0 / 0 / 2, no time filter on `AgentToolAudit_CL` | P5 rerun |
| `35-g7-read-before.txt` | Owner's 17 rules before the edit; Reader's assignment expiration | G7 before; the expiration finding |
| `36-g7-settings-after.png` | Role setting details for Owner: 4 hours, Azure MFA, justification, no approval | G7 |
| `37-g7-after-diff-refused-patch.txt` | Rules that differ, field diff, the refused PATCH and the read-back after it | The portal rewrite; the refused PATCH |
| `38-g8-reader.txt` | T's Reader with no end date, beside the conditioned Owner | G8; the expiration finding |
| `39-g9-eligible-owner.png` | Eligible assignments: Owner for T, Direct, domain masked | G9 |
| `40-g9-readback.txt` | Eligible Owner ends 2026-11-19T02:21Z; conditioned Owner and hash unchanged | G9 |
| `41-g11pre-conditions-preset.png` | The Conditions tab's preset for Owner: excludes Owner, User Access Administrator and Role Based Access Control Administrator | G11-pre |
| `42-g11pre-assignment-eligible.png` | Assignment type tab, Eligible: Permanent greyed out, Time bound selected | G11-pre; the expiration finding |
| `43-g11pre-assignment-active-permanent.png` | Assignment type tab: Active with Permanent duration offered, form cancelled | G11-pre; the expiration finding |
| `44-g11pre-readback.txt` | Nothing saved; condition's excluded roles match the preset's three | G11-pre; finding (b) |
| `45-g11-owner-removed.png` | IAM after the removal: T's Owner Eligible time-bound and Reader Active Permanent; G's Owner Active Permanent; UPN and ID masked | G11 |
| `46-g11-readback.txt` | Only that assignment removed; eligible roles intact | G11 |
| `47-g10-activate-form.png` | Activate form: 4-hour limit, Reason required | G10 |
| `48-g10-active.txt` | Owner activated 18:45:17Z to 19:45:16Z | G10 |
| `49-g10-patch.txt` | 19 rules, only `Expiration_EndUser_Assignment` changed, `required=true max=PT4H` | The fix for the portal rewrite |
| `50-g10-deactivated.txt` | Assigned 6, none activated, eligible unchanged | G10 |
| `51-g10-audit-list.png` | PIM audit list, local time: G7 save, G9, G10 activation, PATCH and deactivation | G10; the alert anchor lists both paths |
| `52-g10-audit-activation-mfa.png` | `IsAuthenticatedWithMfa` True | The MFA finding |
| `53-g10-audit-activation-targets.png` | The audit entry's targets: Owner, the subscription and T, with IDs masked | G10 |
| `54-g10-audit-policy-update.png` | "Update role setting in PIM", actor T, user agent Azure CLI, 18:54Z | The alert anchor; the fix |
| `55` to `59` | G12 checks 1 to 5, Reader only. In `58`, a labelled correction is appended: the first `dataAuthorizationMode` line read the wrong path | The G12 column |
| `60-g13a-active.txt` | Owner activated 23:11:29Z, 2 hours | G13a |
| `61-g13a-reader.txt`, `62-g13b-reader-removed.txt` | Reader created, then removed about 1.5 minutes later | Check 1; the 5-minute note |
| `63` to `66` | G13c: PATCH, queries, permissions (positive control), precheck | The G13 column |
| `67-g13d-deactivated.txt` | Assigned 6, none activated, eligible unchanged | G13d |
| `68-g14-active.txt`, `69-g14-first-query.txt` | First data role activation; 144 / 0 / 0 / 2 at 4.5 minutes | Activation lag |
| `70-g14-retry-missed-window.txt` | Retry at 00:42:54Z, after the 00:31:29Z expiry: stopped, no query. A missed window, kept as a real result. An earlier stop at 23:37:51Z (run too early, no query) was overwritten by this run | Why the redo happened |
| `71-g14redo-precheck.txt` | T's 6 assigned and 3 eligible roles, 0 activated; G holds only Owner | State before the redo |
| `72-g14redo-active.txt` | Second activation, 01:08:24Z to 03:08:22Z | G14 redo |
| `73-g14redo-q10.txt` | 144 / 90 / 2 / 2 at 11 minutes | The positive control |
| `74-g14lag-m01.txt` | 117 s after the request, after a fresh sign-in: data action yes, 90 and 2 | Deactivation lag |
| `75-g14lag-m10.txt` | 657 s: data action no, 0 and 0 | Deactivation lag |
| `76-g14lag-m20.txt` | **A +31 reading, not +20:** 1845 s, 0 and 0. The filename is kept. No reading between 11 and 31 minutes | Stayed denied |
| `77-g14lag-m30.txt` | 1892 s: 0 and 0. Also Retest check 3 | Deactivation lag; the Retest column |
| `78-retest-check1-self-assign.txt` | Denied, count 0. **`roleAssignments/ed` in the action line is the regex matching a hex ID;** the action is `roleAssignments/write` | Retest |
| `79-retest-check2-noop-patch.txt` | Denied, no change | Retest |
| `80-retest-check4-permissions.txt` | `dataAuthorizationMode` false; `protectionLevel/write` no at both scopes, the only possible answer under Reader; 0 of 5 scopes | Retest |
| `81-retest-check5-precheck.txt` | Gates clear; stopped, exit 1 | Retest |
| `82-stage5-hourly-billing.txt` | No Bastion or API Management; no public IP in the lab; `ga-jump-lab` deallocated; AI Search 1 in the lab; outside the lab 1 public IP and 1 NAT gateway, counted only | End of day 2 |
| `83-s4-endstate.txt` | T's 6 assigned and 3 eligible roles, 0 activated; G holds only Owner, `40ae...a03b` | Stage 4 end-state check |
| `84-s4-prep.txt` | Owner 1 (G), User Access Administrator 0; T's root read denied, 403, from the error's reason text; Defender contact: role Owner, no email, High | Stage 4 prep; the Defender finding; the root-visibility note |
| `85-g15-iam-owner-filter-before-removal.png` | IAM Owner filter before removal, two rows: T eligible time-bound, G active permanent | G15 |
| `87-g15-subscriptions-after-removal.png` | G's subscription list after removal, Filtered (0 of 0) | G15 |
| `88-g15-global-admin-active.png` | Global Administrator active assignments, G still active and direct | G15 |
| `89-g15-budgets-billing-scope.png` | Budgets at the billing account scope seen by G with no Azure role: `Azure_Billing_Alert`, $50 budget, $136.75 forecast | G15; the billing role finding |
| `90-s4-g15-readback.txt` | Owner at subscription 0, G assignments 0, T activated 0, eligible Owner intact; delete Succeeded at 15:44:49Z, caller G | G15 read-back |
| `92-g16-portal-after-elevation-signin.png` | G's portal home after elevation and sign-in. It doesn't show the banner; the elevation proof is `98` | G16 |
| `93-g16b-guest-reader-assigned.png` | Subscription IAM showing G's Reader at "This resource" | G16b |
| `94-s4-g16b-read.txt` | G's Reader on `ga-ag-ops-shared`: 1, no condition, `Assigned`, no end date. T's listing also shows G's User Access Administrator at root | G16b; the root-visibility note |
| `97-g17-elevation-toggle-no.png` | Entra Properties after G17, toggle No. Also shows Data location (Primary Copy) United States datacenters, for reuse in `w1-verify` and C5 | G17 |
| `98-g17-elevated-access-audit.png` | Entra audit, Azure RBAC (Elevated Access): elevated 11:14:23 and root User Access Administrator removed 11:22:34 Toronto | G16, G17 |
| `99-s4-g17-after.txt` | G assignments 1, the expected `DIFF`: the leftover Reader. Owner at subscription 0. One Succeeded write by G on `ga-ag-ops-shared`, no delete | After G17 |
| `100-s4-g16c-cleanup.txt` | One activated Owner, one Reader found, delete accepted for `bb96...f476` | Cleanup gate |
| `101-s4-g16c-read.txt` | T activated 1, G's Reader 0 | Cleanup gate |
| `102-s4-cleanup-deactivated.txt` | T activated 0, G assignments 0, Owner at subscription 0. The rerun; the first run exited 1 with no output (runbook) | Cleanup gate |
| `103-s4-billing.txt` | No Bastion or API Management; no public IP in the lab; `ga-jump-lab` deallocated; AI Search 1 in the lab; outside the lab 1 public IP and 1 NAT gateway, counted only | End of Stage 4 |
| `104-pim-eligible-owner-condition-none.png` | PIM, My roles, Azure resources, Eligible assignments: Container Apps SandboxGroup Data Owner on `ga-sbx-lab`, Owner on the subscription ("Azure subscription 1") and Privileged Monitoring Data Reader on `rg-guardedadvisor-shared`, all Direct, all Condition "None". Owner eligibility ends 11/18/2026 9:21:58 PM Toronto (2026-11-19T02:21:58Z). Capture time not recorded. Account bar and avatar blacked out | The eligible Owner has no condition (findings, 2026-11-10; complements C2) |
| `105-pim-active-owner-condition-none.png` | Active assignments: Owner on the subscription and Privileged Monitoring Data Reader on `rg-guardedadvisor-shared`, both Activated, Condition "None", ending 10:18:31 PM and 10:21:25 PM Toronto (03:18:31Z and 03:21:25Z on 11-10). The standing assignments are also shown (Foundry User; Monitoring Metrics Publisher on `ga-dcr-redteam-shared`; Reader on the jumpbox NIC, the VM and the subscription; "Virtual Machine Ad..." on `ga-jump-lab`), all "None". Captured during the 2026-11-10 session after both activations; exact time not recorded. Cropped below the account bar | The activated Owner has no condition (complements C5) |
| `106-fri-owner-activated.png` | PIM, Active assignments, one row: Owner on "Azure subscription 1", Subscription, Direct, Condition "None", Activated, ending 11/13/2026 4:46:18 PM Toronto (21:46:18Z). Captured after the 17:46:18Z activation; exact time not recorded | Friday 11-13 window, row 1 (`w4-fri`) |
| `107-sat-pmdr-activated.png` | PIM, Active assignments, one row: Privileged Monitoring Data Reader on `rg-guardedadvisor-shared`, Resource group, Direct, Condition "None", Activated, ending 11/14/2026 10:23:41 AM Toronto (15:23:41Z). Activated 14:23:41Z for Saturday's A6 read of `AppGenAIContent` (item 6, C1). Deactivated by T in the portal between 15:14:30Z and 15:18:32Z; the exact minute wasn't noted. No deactivation screenshot: the CLI read-back at 15:18:32Z (0 activated instances) is the evidence | The data role was active only for A6, and is off |
| `108-sat-owner-activated-retention.png` | PIM, Active assignments, one row: Owner on "Azure subscription 1", Subscription, Direct, Condition "None", Activated, ending 11/14/2026 12:53:56 PM Toronto (17:53:56Z). Activated for Saturday's `w3-retention` change (run tag `retention-change-20261114T165747Z`; C1 accepted 17:07:20Z, C2 refused 17:07:51Z). Deactivated by T in the portal at 17:12Z; the CLI read 0 activated instances at 17:32:27Z | Owner was active only for the two table changes |
| `109-owner-activated-20261115.png` | PIM, Active assignments, one row: Owner on "Azure subscription 1", Subscription, Direct, Condition "None", Activated, ending 11/15/2026 5:29:25 PM Toronto (22:29:25Z). Sunday Part 2, D1: active 21:30Z to 21:52Z for D2/D3 (Defender for AI on), DP1 (Purview toggle) and S2 (Sentinel Reader eligibility). Deactivated at 16:52 Toronto (21:52Z), confirmed by CLI | Owner was active only for Sunday's Part 2; the `listKeys` burst fell inside it (findings, 2026-11-15) |
| `110-sentinel-reader-activated-20261116.png` | PIM, Active assignments, one row: Microsoft Sentinel Reader on `rg-guardedadvisor-shared`, Resource group, Direct, Condition "None", Activated, ending 11/16/2026 8:03:45 AM Toronto (13:03:45Z). S4: activated about 12:04Z; the CLI showed the role at `resourceGroups/rg-guardedadvisor-shared`; deactivated 12:12Z; the CLI then showed none | `w2-sentinel`: the PIM path to the least-privilege Sentinel role works (control matrix K40) |
| `111-entra-roles-security-reader-only-20261116.png` | PIM, My roles > Microsoft Entra roles > Eligible assignments, one row: **Security Reader**, Default Directory, Direct, Permanent. File dated 2026-11-16; Security Administrator is no longer listed | T holds only Security Reader eligibility in Entra PIM |
| `112-owner-activated-until-1922Z-20261118.png` | PIM, Active assignments, a cropped row: "Activated", ending 11/18/2026 2:22:5x PM Toronto (19:22:5xZ), "Deactivate". The crop doesn't show the role or scope; it is T's Owner on the subscription, activated 15:22:56Z for the Wed 11-18 `w3-teardown` window, deactivated at about 19:05Z (activated 0 on read-back) | Owner was active only for the teardown window (D-048) |

Checked before committing 109 and 110: single table rows, no names, UPNs or IDs; PNG chunks are `caBX` (C2PA, a standing false-positive class) and `iCCP` only.

Checked before committing 112 (2026-11-18): chunks `IHDR`, `iCCP`, `caBX` (C2PA, 4 GUID-shaped strings, standing false-positive class) and `IEND` only; no names or IDs in the pixels.

**Next number: 113.** **Not used:** 86, 91, 95, 96. Screenshots from `85` onward were masked before saving.
