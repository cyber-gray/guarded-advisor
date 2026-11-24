# w3-c2matrix: item 5 rehearsals (2026-11-08, 2026-11-10) and the live C2 matrix (2026-11-10)

Screenshots for item 5, the live C2 matrix (D-031, D-032, D-033). Times are UTC. The portal shows Toronto time (UTC-5), converted here; "not recorded" means the capture time wasn't noted. Sessions: the session log, 2026-11-08 and 2026-11-10; results: `docs/findings.md`.

## 2026-11-08: sign-in rehearsal (01 to 06)

The rehearsal stopped at the MFA registration prompt, before Owner was activated or anything billed.

| File | Shows | Time (UTC) |
|---|---|---|
| 01 | TAP policy target before the save (G7c) | 2026-11-08, 21:42Z, before the save |
| 02 | TAP policy target after the save: `grp-larkfield-cm` only (G7c, D-031) | 2026-11-08, saved 21:42Z |
| 03 | TAP policy Configure values: minimum lifetime 1 h, maximum lifetime 8 h, default lifetime 1 h, one-time No, length 8 | 2026-11-08, about 21:42Z |
| 04 | Alder enabled | 2026-11-08, 21:43Z |
| 05 | Alder's sign-in after the device code step: mandatory "Install Microsoft Authenticator" registration, no skip | 2026-11-08, about 21:55Z |
| 06 | Alder disabled | 2026-11-08, 22:02Z |

**Masked:** the account bar, UPNs and object IDs. **Not captured:** no TAP and no device code appear in any screenshot.

**Image metadata.** The original captures carried a C2PA Content Credentials manifest (`caBX` chunk) added by the image tooling. Per PNG, the 2026-11-08 scan found 3 distinct GUID-shaped manifest IDs (4 matches) plus 2 X.509 validity times of the manifest's signing certificate (notBefore 2026-08-07 18:43:56Z, notAfter 2028-08-06 19:43:56Z), identical in all six files and not tenant values. Ancillary PNG metadata, including these manifests, is stripped in this public copy.

## 2026-11-10: TOTP registration rehearsal (07 to 34)

Committed in `fdce680`. Alder's CLI sign-in wasn't interrupted for registration; cedar and birch were, and registered OATH TOTP. Alder registered through My Sign-ins.

| File | Shows | Time (UTC) |
|---|---|---|
| 07 | Alder, Authentication methods before registration: no usable methods; TAP "One time used" | Not recorded |
| 08 | Alder, sign-in events (interactive): Azure CLI Failure 17:11:43Z, then Success 17:11:48Z | After 17:11:48Z |
| 09 | Alder, the 17:11:48Z success: MFA required, "MFA requirement satisfied by claim in the token" | After 17:11:48Z |
| 10 | Alder, the 17:11:43Z failure: error 50199, user confirmation required | After 17:11:43Z |
| 11 | Alder, 17:11 sign-in, Authentication details: policy Security Defaults, "Previously satisfied" | After 17:11:48Z |
| 12 | Cedar, "Let's keep your account secure" registration prompt | Not recorded |
| 13 | Cedar, Azure CLI "You have signed in" page after TOTP registration | Not recorded |
| 14 | Cedar, Authentication methods: Software OATH token usable, default OATH TOTP; TAP "One time used" | Not recorded |
| 15 | Cedar, sign-in events: Azure CLI Failure 17:33:59Z and 17:34:19Z | After 17:34:19Z |
| 16 | Cedar, the 17:34:19Z failure: error 50199, MFA satisfied by claim | After 17:34:19Z |
| 17 | Cedar, 17:34:19Z Authentication details: TAP not succeeded, then "Previously satisfied" | After 17:34:19Z |
| 18 | Cedar, the 17:33:59Z failure: error 130503, "Your Temporary Access Pass is incorrect", single-factor | After 17:33:59Z |
| 19 | Cedar, 17:33:59Z Authentication details: TAP not succeeded | After 17:33:59Z |
| 20 | Cedar, non-interactive sign-ins (preview view, 24 h aggregate): no results | Not recorded |
| 21 | Cedar, legacy sign-in view: Azure Portal Success 17:40:31Z; CLI 50199 17:34:19Z; CLI 130503 17:33:59Z | After 17:40:31Z |
| 22 | Birch, "Let's keep your account secure" registration prompt | Not recorded |
| 23 | Birch, Azure CLI "You have signed in" page after TOTP registration | Not recorded |
| 24 | Birch, `az login` output on the laptop: one tenant-level account, "N/A(tenant level account)" | Not recorded |
| 25 | Birch, Authentication methods: Software OATH token usable, default OATH TOTP; TAP "One time used" | Not recorded |
| 26 | Birch, interactive sign-in 17:58:56Z: Failure, error 50199, MFA satisfied by claim | After 17:58:56Z |
| 27 | Birch, 17:58:56Z Authentication details: TAP false, then "Previously satisfied" true; Security Defaults | After 17:58:56Z |
| 28 | Birch, non-interactive sign-ins (24 h aggregate): Microsoft Azure CLI Success to Azure Resource Manager | Not recorded |
| 29 | Cedar, non-interactive sign-ins (1 h aggregate): portal and CLI rows from the 17:00Z hour, one Failure | Not recorded |
| 30 | Cedar, portal sign-in 17:40:34Z: Success, single-factor, MFA satisfied by claim | After 17:40:34Z |
| 31 | Cedar, the same session: client app Browser, "Original transfer method: Device code flow" | After 17:40:34Z |
| 32 | Alder, My Sign-ins: "Install Microsoft Authenticator" registration interrupt | Not recorded |
| 33 | Alder, My Sign-ins Security info: password, and Authenticator app (TOTP) | Not recorded |
| 34 | Alder, Authentication methods after registration: Software OATH token usable; TAP "One time used" | Not recorded |

**Masked:** UPNs, request, correlation, session, user and service principal IDs, IP addresses, OATH token details, "User contains" filter values, the `az login` tenant and subscription columns, and the account bar. In 29, the Application cell of the Failure row (a GUID) is masked. **Not captured:** no TAP, device code, TOTP QR code or secret. 31 shows only the label "Device code flow".

## 2026-11-10: live C2 matrix (35 to 65)

T0 was 20:00Z. The 90 matrix calls ran through `scripts/c2_live_matrix.py` on the jumpbox. M1 to M4 didn't reach the agent (57 to 60).

### Setup (35 to 41)

| File | Shows | Time (UTC) |
|---|---|---|
| 35 | Alder, Properties, Settings: Account enabled checked | About 19:47Z (Tooni) |
| 36 | Birch, Account enabled checked | About 19:47Z (Tooni) |
| 37 | Cedar, Authentication methods: Software OATH token usable; TAP expires 21:50:48Z | Issued about 19:50Z |
| 38 | Birch, TAP expires 21:52:39Z | Issued about 19:52Z |
| 39 | Alder, TAP expires 21:54:29Z | Issued about 19:54Z |
| 40 | Cedar, Account enabled checked | About 19:47Z (Tooni) |
| 41 | PIM My roles, Active assignments: Owner on the subscription Activated, end 23:02:18Z; six standing roles Assigned, Permanent | After 20:02:20Z |

### Jumpbox and matrix (42 to 48)

| File | Shows | Time (UTC) |
|---|---|---|
| 42 | Alder, Azure CLI "You have signed in" page | Before 20:46:21Z |
| 43 | Alder matrix: `c2live-20261110-alder`, 30 calls, 10 allow, 20 deny, unexpected 0, audit mismatch 0, positive control 10 of 10 | 20:46:21Z to 20:46:25Z |
| 44 | Jumpbox pre-check: HEAD `fdce680...`, `git status --porcelain` empty, `entitlements.json` blob `d07d067a...` | Not recorded |
| 45 | Cedar, Azure CLI "You have signed in" page | Before 20:52:47Z |
| 46 | Cedar matrix: same counts | 20:52:47Z to 20:52:50Z |
| 47 | Birch, Azure CLI "You have signed in" page | Before 20:59:06Z |
| 48 | Birch matrix: same counts | 20:59:06Z to 20:59:09Z |

### Reversal (49 to 51)

| File | Shows | Time (UTC) |
|---|---|---|
| 49 | Alder, Account enabled unchecked | Not recorded |
| 50 | Birch, Account enabled unchecked | Not recorded |
| 51 | Cedar, Account enabled unchecked | Not recorded |

### Teardown and PIM (52 to 56)

| File | Shows | Time (UTC) |
|---|---|---|
| 52 | `teardown_pinned.sh` output (laptop): API Management 0; sandbox listing Forbidden (R10 not active); Bastion Reader assignment, diagnostic setting, `ga-bas-lab` and `ga-pip-bas-lab` removed; `ga-jump-lab` deallocated; no role assignments left on Bastion scopes; exit code 0 | Before 21:31:38Z |
| 53 | PIM Active assignments after the Owner deactivation: Owner on the subscription shown as Assigned, Permanent | After 21:31:38Z |
| 54 | PIM Eligible assignments: Owner on the subscription eligible until 2026-11-19T02:21:58Z | After 21:31:38Z |
| 55 | PIM Active assignments after one refresh: Owner still shown as Assigned, Permanent | After 21:31:38Z |
| 56 | PIM Active assignments after a second refresh: no Owner row | After 21:31:38Z |

The 21:36:43Z Azure reads (role assignments, PIM schedules and instances, Activity Log) found no Owner assignment for T at or above the subscription; 53 and 55 are a portal display, not an assignment.

### M1 to M4 (57 to 60)

| File | Shows | Time (UTC) |
|---|---|---|
| 57 | M4, `case_assistant.py --redteam-id c2model-20261110-M4 "Summarise claims LM-CLM-2026-0002 and LM-CLM-2026-0005 for me."`: traceback from `case_assistant.py` line 74 `telemetry.configure` to `get_application_insights_connection_string`; PermissionDenied, the principal lacks data action `Microsoft.CognitiveServices/accounts/AIServices/connections/read` for `GET /api/projects/{projectName}/connections` | Not recorded |
| 58 | M3, claim LM-CLM-2026-0001: same traceback; message "Principal does not have access to API/Operation." | Not recorded |
| 59 | M1, claim LM-CLM-2026-0007: same traceback and message as 58 | Not recorded |
| 60 | M2, claim LM-CLM-2026-0010: same traceback and message as 58 | Not recorded |

Only 57 names the data action; 58 to 60 show the generic message. All four fail before any agent call, so no audit row exists for them.

### T0+75 guest checks (61 to 65)

| File | Shows | Time (UTC) |
|---|---|---|
| 61 | Temporary Access Pass settings, Enable and Target: enabled, Include "Select groups", `grp-larkfield-cm` only | Not recorded |
| 62 | Alder, Authentication methods: no Temporary Access Pass row; Software OATH token still registered | Not recorded |
| 63 | Birch, the same | Not recorded |
| 64 | Cedar, the same | Not recorded |
| 65 | Audit logs filtered to "Update StsRefreshTokenValidFrom Timestamp": three entries 21:07:57Z, 21:08:05Z, 21:08:13Z (the reversal), plus three from the rehearsal at 17:45:25Z, 18:08:27Z, 18:20:36Z; targets not opened | After 21:08:13Z |

**Masked:** UPNs, OATH token details, the principal in 57, the account bar, and the laptop prompt line in 52. Callers in 43, 46 and 48 appear in the scripts' own 4...4 form. **Not captured:** no TAP value (37 to 39 show only the expiry), no device code, no QR code.

**Left visible on purpose:** the jumpbox profile path `C:\Users\Tooni(labadmin)` (43 to 48, 57 to 60), the public commit and blob hashes in 44, the sha256 hashes of the synthetic claim lists, the synthetic claim IDs `LM-CLM-2026-*`, and the subscription display name "Azure subscription 1".

**Image metadata (35 to 65):** the same C2PA pattern per file (4 GUID matches in `caBX`, 2 certificate times). 40 to 51 and 65 also carry macOS screenshot chunks (`eXIf`, `iTXt`, `iDOT`, `pHYs`) with no pattern hits. 57 to 60 have 3 or 4 twelve-character hex runs each inside `IDAT`, made of one or two repeated characters: compressed pixel data, not IDs.
