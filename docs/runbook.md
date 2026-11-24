# Runbook: steps done outside infrastructure as code

Anything done by hand in the portal goes here, with the date and why it couldn't be code. Newest at the bottom.

## Subscription budget (`d0-budget`)

- **Date:**
- **Where:** Cost Management + Billing, Budgets
- **Settings:** monthly, amount $____, alerts at Actual 50%, 80%, 100% and Forecasted 100%, sent to Tooni's email
- **Why portal:** one-time subscription setting, faster by hand on Day 0. Could move to Bicep (`Microsoft.Consumption/budgets`) later.

## Jumpbox OS disk: export blocked by script, not Bicep (`w1-jump`, D-018)

- **Date:** 2026-10-16
- **What:** the jumpbox OS disk `ga-jump-lab-osdisk` is set to `networkAccessPolicy: DenyAll` and `publicNetworkAccess: Disabled`, so it can't be exported (downloaded) or imported over any endpoint.
- **How:** `scripts/jumpbox.sh harden-disk`. It's idempotent: it reads both values first and skips if they're already set; otherwise it deallocates the VM, runs `az disk update --network-access-policy DenyAll --public-network-access Disabled`, and starts the VM again if it was running. `jumpbox.sh create` and `jumpbox.sh up` both call it, so a rebuilt jumpbox gets the same settings. `scripts/verify.sh disks` fails on drift.
- **Why outside Bicep:** the VM resource's `storageProfile.osDisk` can't carry `networkAccessPolicy` or `publicNetworkAccess`; they exist only on the `Microsoft.Compute/disks` resource, and an OS disk created from an image is created by the VM. Sources: https://learn.microsoft.com/azure/templates/microsoft.compute/disks, https://learn.microsoft.com/azure/virtual-machines/disks-restrict-import-export-overview (updated 2026-09-17).
- **Why deallocate first:** Learn doesn't say whether these properties can change on a disk attached to a running VM, so the script takes the safe order.
- **First run:** 2026-10-16 21:45 to 21:47Z, `AllowAll`/`Enabled` changed to `DenyAll`/`Disabled`; `verify.sh disks` passed.

## Session teardown G6 finished by hand (2026-10-19)

- **Date:** 2026-10-19, 16:02 to 16:12Z
- **What happened:** `ASSUME_YES=1 ./scripts/teardown.sh session` removed the Reader assignment on the Bastion host (`88fd...`) and its diagnostic setting, then stopped: `az network bastion delete` asks its own confirmation, which fails without a TTY ("Unable to prompt for confirmation as no tty available. Use --yes."). `ASSUME_YES` answers only the script's own `confirm()` prompts.
- **Finished by hand under the G6 approval,** in the script's order: `az network bastion delete --yes` on `ga-bas-lab`, `az network public-ip delete` on `ga-pip-bas-lab`, `az vm deallocate` on `ga-jump-lab`. Checked afterwards: no Bastion hosts, no public IPs, no diagnostic settings on the old Bastion ID, jumpbox `PowerState/deallocated`, and `check_bastion_roles` printed "No role assignments left on Bastion scopes."
- **Fix:** `scripts/teardown.sh` now passes `--yes` to `az network bastion delete` (the script's `confirm()` is the approval). Every other delete, deallocate and purge in `teardown.sh` and `jumpbox.sh` was checked with `az … -h`: none of them prompts on its own (`apim delete` already passes `--yes`).

## Azure CLI: extensions install only with approval (2026-10-19)

- **Date:** 2026-10-19
- **What:** in `~/.azure/config` on Tooni's laptop (not in Azure):
  - `extension.use_dynamic_install=yes_prompt`
  - `extension.dynamic_install_allow_preview=false`
- **Why:** on 2026-10-16, with no extension settings configured, az 2.90.0 installed the `bastion` extension without asking the first time `az network bastion` ran ("The command requires the extension bastion. It will be installed first."). The lab adds tools only with approval.
- **Docs conflict:** the configuration options page says `use_dynamic_install` defaults to `no` (https://learn.microsoft.com/cli/azure/azure-cli-configuration, updated 2025-06-24); the extensions overview says dynamic install is enabled by default since 2.12.0 (https://learn.microsoft.com/cli/azure/azure-cli-extensions-overview, updated 2025-05-21). What happened matches the overview. `dynamic_install_allow_preview` is documented only in the release notes (2024-08-06, https://learn.microsoft.com/cli/azure/release-notes-azure-cli).
- **Effect on non-interactive runs:** with `yes_prompt`, a command that needs a missing extension stops and asks. In a non-interactive shell there's no one to answer, so the command fails. The missing extension is then named and added only after Tooni's yes (`az extension add --name <extension>`).
- **Installed on 2026-10-19:** `application-insights` 1.2.3, `bastion` 1.4.3 (kept), `ml` 2.45.1, `scheduled-query` 1.0.0b2.
  - `scheduled-query` is a **preview build**, kept on purpose: it's the extension used for the w1-law `ga-alert-daily-cap-reached` log search alert. `dynamic_install_allow_preview=false` affects only future dynamic installs, not this one.

## Jumpbox sign-in, tool installs and inside check (`w1-jump`, 2026-10-19)

- **Date:** 2026-10-19, about 15:20 to 15:55Z (first Bastion audit row 15:20:54Z). Done by Tooni inside the jumpbox; these steps run in the VM's desktop session, so they aren't infrastructure as code.
- **Sign-in (portal only):** Azure portal > `ga-jump-lab` > Connect > Bastion > Authentication type **Microsoft Entra ID (Preview)** (popups allowed for `cdn.bastion.azure.com`). Bastion Basic is created per session by `scripts/jumpbox.sh up` (D-018). If the Entra option doesn't appear, stop: no fallback to the local administrator password, and remove any temporary data roles before debugging.
- **Installs** (elevated PowerShell, winget, with the vendor installers as fallback): Git for Windows (`Git.Git`), Azure CLI (`Microsoft.AzureCLI`) and jq (`jqlang.jq`; `verify.sh` needs it and Git Bash doesn't include it). Tooni reported the installs and the run as done; the exact install path used wasn't recorded.
- **Inside check (Git Bash):** `git clone -c core.autocrlf=false https://github.com/cyber-gray/guarded-advisor.git` (Git Credential Manager, browser sign-in by Tooni), `az login` (Tooni), `./scripts/verify.sh inside`. Result 0 failed, 0 inconclusive (docs/findings.md). `.gitattributes` now keeps `*.sh` at LF, so later clones work without the `-c` option.
- **Foundry portal:** Edge > https://ai.azure.com > project `ga-proj-labv3do` loaded. A permission error there is recorded as RBAC, not network.
- **Exit steps (every time):** sign out of Edge and clear site data; `cmdkey /delete:git:https://github.com`; `az logout`. On 2026-10-19 Tooni also revoked the GitHub OAuth token used for the clone.
- **Evidence rule:** only redacted screenshots go into `docs/evidence/` (URL bar with `tid=` and resource paths, profile icons and bookmarks cropped). Originals stay outside the repo; if a `docs/evidence/raw/` folder is ever created, it's added to `.gitignore` first.

## Temporary billing roles to start the E5 trial (`w2-licensing`, 2026-10-19)

- **Date:** 2026-10-19 (evening, Eastern). Done by Tooni in the Entra and Microsoft 365 admin centers.
- **Who and what:** the tenant's only Global Administrator, the guest personal Microsoft account, assigned T two directory roles: **Billing Administrator** and **License Administrator**. Global Administrator wasn't needed and wasn't assigned.
- **Why:** the Microsoft 365 admin center refuses the guest consumer account ("Login is not supported for consumer users without business presence"), so the trial had to be started by a member account. T started the Microsoft 365 E5 trial (recurring billing off) and assigned itself one E5 license (D-009).
- **Removal:** the guest Global Administrator removed both roles in the same sitting. **Confirmed 2026-10-19 22:25Z** (Graph, read-only, as T): `roleManagement/directory/roleAssignments?$filter=principalId eq '<T>'` returned no assignments, and `memberOf/microsoft.graph.directoryRole` returned none.
- **Audit log:** the role assignment and removal entries weren't read back: T can't read `auditLogs/directoryAudits` without a directory role (`Authentication_RequestFromUnsupportedUserRole`). To confirm them, the guest Global Administrator opens Entra admin center > Monitoring & health > Audit logs, category RoleManagement, date 2026-10-19.
- **Why it's portal-only and manual:** a one-time tenant setup step performed by the only account that can grant directory roles. It's the **"before" picture for `w2-pim`**: a permanent active assignment granted and removed by hand, with removal depending on someone remembering. With PIM (P2, now licensed through E5) the same grant becomes an eligible, time-bound activation with justification that expires on its own.

## Case manager identities: PIM-granted User Administrator, accounts and group (`w1-data` Part A, 2026-10-20)

This entry and the 2026-10-19 billing-role entry above are the **before and after for `w2-pim`**: on 2026-10-19 a standing role was granted by hand and removed by hand; on 2026-10-20 the same kind of grant went through PIM with a justification and an end time.

**Before: 2026-10-19 (no PIM), from the Entra audit log** (read by Tooni as the guest Global Administrator on 2026-10-20; local time, EDT; target T):
- 5:49:48 PM and 5:50:14 PM: Billing Administrator and License Administrator added (permanent, no justification, no end time).
- 6:10 PM: usage location updated and E5 license assigned.
- 6:17:21 PM and 6:17:22 PM: both roles removed, about 27 minutes after they were granted.
- **Seen, not investigated:** 6:05:32 PM "Add member to group", and 2026-10-20 12:00:43 PM "Update user" twice. Initiators weren't checked; probably automatic, following the trial start and license assignment.

**After: 2026-10-20 (PIM)**
- **G7a, 8:27 PM local (00:27Z on 10-21):** the guest Global Administrator assigned **User Administrator** to T through PIM: **active, time-bound, ending about 10:27 PM local**, with the justification "w1-data G7b: create synthetic case manager accounts and group". The audit log shows the PIM request and its completion with the justification. Verified active at 01:45Z (`roleAssignments`: User Administrator, scope `/`). The end time couldn't be read back from the CLI: the PIM schedule endpoint needs a `RoleAssignmentSchedule.Read.Directory` or `RoleManagement.Read.Directory` scope the Azure CLI's token doesn't carry.
- **G7b, 01:47:52 to 01:48:30Z, as T** with `ASSUME_YES=1 ./agent/create_case_managers.sh` (one-off approval):
  - **First run failed part-way:** it created `cm-alder`, `cm-birch` and `cm-cedar`, then the group request was rejected ("A value is required for property 'securityEnabled' of resource 'Group'"): the script sent `securityGroup`. One-word fix to `securityEnabled` (line 79), then the script was **rerun under the same approval without first showing Tooni the diff**. The rerun was idempotent: it skipped the three existing users, created `grp-larkfield-cm` and added the members.
  - **Process rule set by Tooni afterwards:** if a gated script or command fails and it's changed, the diff is shown before any rerun, even under the same approval.
  - **Result (read-only check):** three users, all `accountEnabled: false`, 0 licenses, display names "Case Manager Alder/Birch/Cedar (synthetic)", company "Larkfield Mutual (fictional)"; group `grp-larkfield-cm` security-enabled, not mail-enabled, not role-assignable, exactly 3 members. Passwords were generated in the pipeline (random value plus a fixed complexity suffix) and never shown or stored; first sign-in will use a Temporary Access Pass (G7c, its own gate, week 3).
- **Removal:** Tooni removed the PIM assignment before its end time. **Confirmed 2026-10-21 01:53:16Z** (Graph, read-only): no active directory role assignments and no directory-role memberships for T.
- **Then:** `agent/build_entitlements.sh` wrote `scenarios/larkfield/entitlements.json` (3 object IDs with aliases, 10 claims each, no UPNs); `check_data.py` 0 failed.
- **Why not infrastructure as code:** the role grant is a PIM action by the only account that can grant directory roles. The users and group are created by a script (`agent/create_case_managers.sh`, idempotent), not by hand.

## Trace content protection: routing flag, protected table, 7-day retention (D-021, 2026-10-22)

- **Why not Bicep:** table settings are changed with PATCH (`scripts/protect-trace-content.sh`), which leaves each built-in table's schema and plan untouched; a Bicep table resource is create-or-update and would have to restate them. The routing flag is a subscription preview feature (`az feature register`).
- **T3, retention (19:07:48 to 19:08:04Z):** `AppGenAIContent`, `AppDependencies`, `AppTraces` and `AppEvents` set to 7 days analytics and 7 days total (were 90). **Caveat (Learn):** when total retention is shortened, Azure Monitor waits 30 days before removing data, and retention under 31 days doesn't reduce cost. Content ingested before the change stays queryable until about 2026-11-21.
- **T2, protection:**
  - **First attempt, 19:07:45Z, failed silently.** The PATCH `{"properties": {"protectionLevel": "Protected"}}` with api-version 2025-02-01 (the version in Learn's example) returned success; the table was unchanged and there was no Activity Log entry. Read-only diagnosis: `protectionLevel` exists only in api-version 2026-03-01 (it read `General`); 2025-02-01 and 2025-07-01 don't have the property.
  - **Fix shown to Tooni before the rerun:** the script uses api-version 2026-03-01 and reads the value back, exiting with an error unless it's `Protected`.
  - **Rerun, 19:11:50Z, succeeded:** `protectionLevel: Protected`. As Tooni (T, subscription Owner, no data actions), `AppGenAIContent | take 10` and `| count` return 0 (the table holds 11 rows): standard roles are denied by default.
  - **Not closed by T2:** the project managed identity holds Privileged Monitoring Data Reader on `appi-tracing-v3do`, so it can still read the protected content. T4 (remove its Log Analytics Reader and Privileged Monitoring Data Reader) closes that at the next jumpbox session, with a live retest.
- **T1, routing flag (19:13:16 to 19:13:27Z):** `az feature register --namespace Microsoft.Insights --name protectGenAISensitiveData`, then `az provider register -n Microsoft.Insights`; state Registered. **Subscription-wide:** it applies to every Application Insights resource in the subscription. Pre-check: the subscription holds one Application Insights resource (`appi-tracing-v3do`) and one workspace (`ga-law-shared`); the Spectre project has neither; no alert rule, workbook or saved search uses `gen_ai`. To verify at the next live run: a new server-side span in `AppDependencies` carries a pointer instead of the value.
- **Status check any time:** `./scripts/protect-trace-content.sh status`.

## Temporary data role for the V4 outside-in write test (R8, `w2-custom`, 2026-10-22)

- **Why not infrastructure as code:** a temporary test role, granted and removed in the same sitting by CLI, like G1 on 2026-10-16. The standing writer roles (R6, R7) are in `infra/custom-tables.bicep`.
- **Granted 20:10:19Z** as T (approved by Tooni): Monitoring Metrics Publisher for T on `ga-dcr-agent-shared` only, assignment `7109...4bd3`, description "Temporary: V4 outside-in write test 2026-10-22, remove after the test (R8)". Listed on the DCR at 20:15:36Z.
- **Used 20:24:50Z:** one write to `ga-dce-shared` from the laptop; refused with 403 `PublicNetworkAccessDisabled` (findings, V4).
- **Removed 20:24:52Z** (`az role assignment delete`, exit 0). Confirmed afterwards: the only direct assignment on `ga-dcr-agent-shared` is Monitoring Metrics Publisher for the jumpbox managed identity (R6); T's only Monitoring Metrics Publisher assignment is R7 on `ga-dcr-redteam-shared`.

## Python on the jumpbox: always the repo's virtual environment (`w1-agent`, recorded 2026-10-23)

- The jumpbox runs the agent scripts from a virtual environment at `.venv` in the repo clone (`$HOME\guarded-advisor`), created in the VM's desktop session by Tooni, so it isn't infrastructure as code.
- **Every Python command on the jumpbox uses `.venv\Scripts\python`, never plain `python`** (which would use the system interpreter and its packages): for example `.venv\Scripts\python -m pip install -r agent\requirements.txt`, `.venv\Scripts\python -m unittest discover -s agent\tests`, `.venv\Scripts\python -I agent\case_assistant.py "..."`.
- The usage lines in the scripts' docstrings show `python -I ...` generically (laptop and jumpbox); on the jumpbox read them as `.venv\Scripts\python -I ...`.

## R10 Container Apps SandboxGroup Data Owner is PIM-eligible (`w2-pim` step 4, 2026-10-27)

- **What:** Tooni converted R10 (T, Container Apps SandboxGroup Data Owner on `ga-sbx-lab`, standing since 2026-10-23, D-025) to a PIM eligible assignment in the portal on 2026-10-27, ending 2026-11-19, and removed the standing active assignment there. **R10 is eligible-only.** Evidence: `docs/evidence/w2-pim/` (01 to 05: eligible, before and after the removal, 403 without activation, access with it).
- **R9 removed the same day by CLI** (not a portal step; Tooni's yes, D-026): `az role assignment delete --ids <ga-sbx-lab ID>/providers/Microsoft.Authorization/roleAssignments/b8cb...` at about 14:06Z. Read-back: subscription assignments 21 before, 20 after; removed exactly `b8cb…4214`, nothing added. The only row left on `ga-sbx-lab` was R10's PIM activation (13:57:49Z to 14:57:47Z), not a standing assignment.
- **Why not infrastructure as code:** PIM eligibility is set in the portal. `infra/sandbox.bicep` stops managing R10: `operatorPrincipalId` stays empty and no script passes it, so a redeploy (including `build-sandbox-image.sh register`'s attach and detach) can't recreate the standing assignment. Incremental deployments leave existing assignments that aren't in the template alone.
- **Before any registration run (`scripts/build-sandbox-image.sh register`) or Sandboxes portal visit:** activate the Data Owner role in PIM (Privileged Identity Management > My roles > Azure resources), with a justification, for the shortest duration that covers the work. Without it, the data-plane calls fail with 403. Deactivate it when done.
- **Teardown:** `teardown.sh session` lists and deletes sandboxes through the data plane, so it needs the role active too, if any sandbox might exist.
- **Test activation (4d) 13:57 to 14:57Z:** activation expired or deactivated, confirmed 2026-10-27 (PIM > My roles > Azure resources > Active assignments: no results; `docs/evidence/w2-pim/08-no-active-pim-assignments.png`).

## Emergency access account (`w2-pim` step 5, 2026-10-27)

- **Source:** https://learn.microsoft.com/entra/identity/role-based-access-control/security-emergency-access (updated 2026-06-05).
- **Why a portal step:** Entra user creation, directory role assignment and authentication method registration are directory changes done in the Entra admin center; the passkey can only be registered by the account holder.
- **Account:** cloud-only, in the tenant's `onmicrosoft.com` domain, with a non-obvious name. **The UPN is deliberately not recorded anywhere in this repository.**
- **Object ID:** not published (the full value is in Entra, not in the repository). It's the target for a future sign-in alert (`SigninLogs | where UserId == "<object-id>"`). No alert or detection code exists yet (nothing in `detections/`, `infra/` or `scripts/` references it), so nothing reads it from here. When the alert is built, pass the object ID in as a deployment parameter or read it from a lookup at deploy time, so it never sits in a committed file; check Learn for the option at build time.
- **Role:** Global Administrator, **permanent active, not PIM-eligible**, as Learn requires for emergency access accounts.
- **Created by** the guest Global Administrator in a private browser window (T holds only Security Reader, eligible, so it can't create users or assign directory roles).
- **Authentication:**
  - Passkey (FIDO2) policy enabled for all users, self-service registration on (`06-passkey-policy-enabled.png`).
  - A device-bound passkey in Microsoft Authenticator, registered from the app and tested by signing in to the Entra admin center (`07-emergency-account-methods.png`).
  - The Authenticator push method was then removed; the account has only a password and the passkey (`09-emergency-account-passkey-only.png`). Reason: push was on the same phone, so it added no recovery path, only a weaker, phishable sign-in.
  - **Recovery:** if the passkey fails, the guest Global Administrator resets the account's methods.
- **Lab deviations from Learn:**
  - One account instead of "two or more".
  - The passkey is in Authenticator on Tooni's own phone. Learn says not to connect these accounts with employee-supplied devices such as phones, and to use methods different from the normal admin accounts ("if your normal administrator account uses the Microsoft Authenticator app ..., use a FIDO2 security key for your emergency accounts"); T also signs in with a passkey in Authenticator. Production: FIDO2 security keys stored in separate secure locations.
  - The account still has a password; Learn's methods are passwordless (passkey or certificate-based).
- **Not done yet (separate decisions):**
  - Sign-in alert: needs Entra sign-in logs sent to `ga-law-shared` (diagnostic setting, small ingestion cost), then a log search alert on the object ID.
  - Validation drill at least every 90 days: not scheduled, the lab ends sooner.
  - Conditional Access exclusion: no policies exist yet. `w2-agentid` must exclude the account from every policy that blocks or restricts sign-in (Learn: report-only policies don't need it), ideally through a dedicated group.
- **Observations for later hardening (no change now):** Email OTP and Software OATH tokens are enabled for all users, and **Temporary Access Pass is enabled for all users** (`06-passkey-policy-enabled.png`), although the `w1-data` plan kept the TAP policy as its own deferred gate (G7c). **Audit check (Tooni, 2026-10-27):** the authentication methods audit log for the last month shows only Tooni's two policy updates on 2026-10-27 (the passkey policy) and that day's registrations, no TAP change (`docs/evidence/w2-pim/10-auth-methods-audit-log.png`). So TAP was enabled before the 30-day audit window; origin unknown. **G7c plan:** scope TAP to a group holding only the synthetic case manager accounts, not all users.


## Signing in as G to Microsoft 365 portals (`w2-dspm`, `w2-pim`, 2026-11-16)

- **Rule:** G (the guest Global Administrator on a consumer Microsoft account) signs in to Microsoft 365 portals with its **in-tenant guest UPN**, the `#EXT#` form, not its personal email. The UPN isn't recorded in the repo; it's in Entra (Users, G's account, User principal name).
- **Why:** with the personal email, the Microsoft 365 admin center (L1, 2026-11-15) and the Purview portal (2026-11-16) refused G; Purview said "account does not exist in tenant 'Microsoft Services'". The sign-in resolved to the wrong tenant. With the guest UPN, Purview loaded Settings > Roles and scopes > Role groups (79 items; Audit Reader 0 users). Findings, 2026-11-15 (corrected 2026-11-16), "A consumer-account guest Global Administrator must sign in...".
- **Seen so far:** Purview: personal email refused, guest UPN works. Microsoft 365 admin center: personal email refused; guest UPN **not tested** (likely the same, *inference*). Exchange admin center: accepted G at L2 (which sign-in name was used wasn't recorded). Entra admin center and PIM: work for G.
- **How:** a private browser window, the portal URL, then the guest UPN at the sign-in prompt; MFA as usual. Close the window after the step.
- **Applies to:** Monday row 18 (G adds T to Audit Reader in Purview) and Tuesday A3 and A4.
- **The L1 route stays recorded as run:** G made T eligible for License Administrator because the Microsoft 365 admin center refused G's personal email. Whether the guest UPN would have worked there is untested.


## Test identity cleanup order: role assignments first, then the user (`w2-privread`, 2026-11-01)

- **Rule:** remove every Azure role assignment of a test identity, and read back that none remain, **before** the identity is deleted.
- **Why:** deleting an Entra user doesn't remove its Azure role assignments. They stay on the scope as orphans (principal name empty, principal ID still set), and `az role assignment list --assignee` can no longer find them, because the assignee doesn't resolve.
- **What happened:** on 2026-11-01 the guest deleted `ga-reader-test` (and permanently deleted it from Deleted users) while the Log Analytics Reader removal was running. The removal's user lookup came back empty, its single-match guard stopped the delete, and the assignment (`4764...7418`) was left as an orphan on `ga-law-shared`. It was then removed by assignment ID, matched on role, name suffix and principal ID first and last four, and the workspace read back 0 assignments for `d204...a385` (19:51:51Z).
- **If it happens again:** list role assignments at the scope, select by assignment name and principal ID, delete with `--ids`, read back at the scope.

## Elevation drill and sign-in log filter (`w2-pim`, PIM day 1, 2026-11-03)

- **Why the portal (rule 7):** the toggle is per user and Learn documents it in the Entra portal; the signed-in Global Administrator has to run it, and neither account uses the CLI (https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin).
- **Steps, one account at a time, in one private window, all others closed:**
  1. Check the account bar shows the expected account and the lab directory.
  2. Entra ID > Properties > Access management for Azure resources > Yes > Save. Note the UTC time.
  3. Sign out and back in.
  4. T, CLI: list the subscription's assignments with `--include-inherited` and select scope `/`. Expect User Access Administrator for that principal.
  5. Entra audit logs, Service "Azure RBAC (Elevated Access)": find the entry.
  6. Toggle to No, Save, within 10 minutes. Read back: T sees no assignment at root; the audit log shows the removal.
- **Reading the logs:** both are read as Global Administrator, without being elevated (https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin#view-elevate-access-log-entries). T has no active directory role, so it can't read them.
- **Control:** a before and after subscription view only works for an account with no other Azure role. The guest holds Owner, so T's root read-back is its control.
- **Sign-in log User filter:** it doesn't match the guest account. Use date windows with no user filter instead. A portal session can reuse an earlier token, so an action may have no sign-in event at that time.

## DataActionsOnly through the portal toggle (item 2, D-029, 2026-11-02)

- **What:** `ga-law-shared` > Settings > Properties > Data authorization mode > Data actions only > Save (Tooni, as T, 22:05Z). Reverted the same way in the same sitting.
- **Why the portal, not IaC or a PATCH (rule 7):** Learn's how-to sends `"dataAuthorizationMode": "DataActionsOnly"` at api-version 2025-02-01, which doesn't define the property; the REST reference defines a boolean from 2026-03-01; on 2026-11-01 the live workspace returned no such property (findings). The portal was the only path with a known outcome. Its read-back at 2026-03-01 showed `"dataAuthorizationMode": true` (22:08:36Z), so a later Bicep or PATCH should use the boolean at 2026-03-01 or newer.
- **Lab stance:** the setting is a test, not a lab default; `infra/` doesn't set it.

## PIM for T's Owner: portal steps (`w2-pim`, D-030, 2026-11-04)

- **Why the portal (rule 7):** G and E never use the CLI (plan rules), and G made these changes while T held a condition blocking Owner assignments. Later policy fixes went by CLI.
- **Steps, each with a CLI read-back by T:**
  1. **G7, G, 16:05:33Z:** PIM > Azure resources > the subscription > Settings > Owner > Edit: 4-hour activation, MFA, justification, no approval.
  2. **G9, G, about 16:23Z:** PIM > the subscription > Roles > Add assignments: Owner for T, Eligible, no condition, ending 2026-11-19T02:21Z (2026-11-18 21:21 Toronto).
  3. **G11-pre, G:** Access control (IAM) > Add role assignment > Owner: open Conditions and Assignment type, confirm the preset and Active Permanent are available, then cancel.
  4. **G11, G, 18:16Z:** Access control (IAM): remove T's conditioned Owner.
  5. **G10, G13a, G14, T:** PIM > My roles > Azure resources > Eligible assignments > Activate. **Deactivate:** Active assignments > Deactivate. Then sign out and in on the portal, and `az logout` and `az login` on the CLI.
- **After any portal edit to PIM role settings, read the policy back field by field.** The G7 save also rewrote `Expiration_EndUser_Assignment.isExpirationRequired` to false, and only a field-level diff showed it (findings). Restore a rule with a one-rule PATCH, which merges, under activated Owner.
- **Activate Owner before `jumpbox.sh up` and before a teardown that may remove a Bastion.** Both write role assignments (D-030). `teardown.sh` stops before any change without the right. Allow for lag: a data role took more than 4.5 minutes to work on one activation (findings).
- **After deactivating:** access can continue for several minutes (findings). Wait 30 minutes before a test that relies on no activation.

## Masked CLI scripts (`w2-pim`, 2026-11-04)

- **Run under `bash <<'EOF'`, quoted.** The Bash tool's shell is zsh, where `GID` and `UID` are special numeric variables. A script assigning an object ID to `GID` failed as arithmetic, and the error printed part of the ID.
- **Send stderr to a private file** with `exec 2>>"$ERRF"`, and print a line count only, so error text can't print unmasked IDs.
- **Wrap `az`:** `az() { command az "$@" </dev/null; }`. Under `bash <<'EOF'` the script arrives on stdin, so a command reading stdin could consume the rest of it.
- **One output file per run**, with a stop if it exists, so a rerun can't overwrite evidence. A time guard that fires should write no file, so running too early doesn't use up the run.

## G15: the guest removes its own subscription Owner (`w2-pim`, D-030, 2026-11-05)

- **Date:** 2026-11-05. Written before the step; the actual times get added after it.
- **Why portal:** the guest (G) acts only in a private browser window and never on the CLI (PIM sitting rules).
- **Who:** G only. T reads back by CLI afterward.
- **Basis:** a Global Administrator can remove the last Owner at subscription scope, and other callers can't by default (https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---cannot-delete-the-last-owner-role-assignment, updated 2026-10-29). G can do this only because it is Global Administrator.
- **Steps:**
  1. Close all private windows. Open one Chrome private window as G. Check the account bar and the directory ("Default Directory") before anything else.
  2. Open the `ga-ag-ops-shared` link from `link-ag-ops-iam.txt` (private folder) and confirm the IAM page loads. No changes, no screenshot.
  3. Subscription > Access control (IAM) > Role assignments. Filter Role = Owner first. The IAM list also shows eligible assignments, so expect exactly two rows: T "Eligible time-bound" (end 11/18/2026 9:21 PM Toronto) and G "Tooni T" "Active Permanent". Any other count or row: stop. Screenshot 85: IAM before removal.
  4. Remove only G's Active Permanent row. Its assignment ID is `40ae...a03b` (`docs/evidence/w2-pim/83-s4-endstate.txt`); the IAM list may not show the ID. Screenshot 86, if captured: the removal confirmation. Record the UTC and Toronto time.
  5. Do a full sign-out and sign-in as G. Screenshot 87: the subscription list, expected empty. On 2026-11-03 the emergency account's list read "Filtered (0 of 1)" with none accessible, so record what it shows.
  6. Open Global Administrator's assignments in Microsoft Entra ID. Screenshot 88: G's assignment is active.
  7. Cost Management + Billing > the billing account scope > Budgets. Screenshot 89: `Azure_Billing_Alert` listed, with the scope visible. If Budgets loads, access comes from a billing role, since RBAC is gone; a denial is also a result. Record what it shows.
  8. Close the private window. Wait at least 15 minutes from the removal time in step 4. Role changes can take up to 10 minutes, and signing out and in forces a refresh (https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignment-changes-are-not-being-detected).
  9. After the wait, open one private window as G, check the account bar and directory, and confirm the subscription is still gone. T runs the read-back (TAG `s4-g15-readback`, evidence 90). Both must pass before G16.
- **Actual times:** the first attempt at 10:39 Toronto was not confirmed in the portal; nothing was removed. Tooni's portal note reads 10:46 Toronto (15:46Z); the activity log records the delete as Succeeded at 15:44:49Z (10:44 Toronto). G's subscription list read Filtered (0 of 0), empty, right after.
- **Evidence:** 85 IAM before removal; 86 skipped if not captured; 87 subscriptions after removal; 88 Global Administrator active; 89 Budgets; 90 read-back.
- **Stop rules:** if the portal shows "Cannot delete the last RBAC admin assignment" or any other block, stop and report. Don't turn on "Allow removal of the last subscription Owner role assignment" without a separate yes from Tooni.
- **Masking:** screenshots 85 to 89 are masked before they go into `docs/evidence/w2-pim/`: account bar, URL bar, UPNs and emails, tenant domain, tenant ID, subscription ID, correlation, request and assignment IDs, IPs, non-lab resource names.
- **Undo:** G elevates, re-adds Owner through IAM and toggles elevation off. The re-added assignment gets a new ID and date; the original record doesn't come back.

## G16 to G17: the guest elevates, assigns and removes a Reader, and toggles off (`w2-pim`, D-030, 2026-11-05)

- **Date:** 2026-11-05. Written before the steps; the actual times get added after them.
- **Why portal:** the guest (G) acts only in a private browser window and never on the CLI (PIM sitting rules).
- **Who:** G only. T runs its reads when Tooni says go.
- **Proves:** that an elevated guest with no Owner can assign a role, which the 2026-11-03 drill left open. G15's undo depends on it.
- **Hard limit:** 10 minutes, counted from G's Save on the elevation toggle (G16) to G's Save on No (G17). Record both times in UTC and Toronto.
- **Before the clock starts:** close all private windows. Open one Chrome private window as G. Check the account bar and the directory ("Default Directory"). Have `link-ag-ops-iam.txt` open on the laptop.
- **Steps:**
  1. **G16:** Microsoft Entra ID > Properties > Access management for Azure resources = Yes, Save. **The clock starts.** Sign out and sign in, then check the account bar and directory. Screenshot 92: the IAM root assignment or the elevated-access banner.
  2. **G16b:** open the `ga-ag-ops-shared` link. Add role assignment: Reader, member G ("Tooni T", the guest row), assignment type Active, duration Permanent, never eligible. If the portal won't offer Active and Permanent, don't create the assignment; record what it offered and go to G17. The guest never gets an eligible or time-bound assignment. Screenshot 93: the assignment listed. Tooni says go for `s4-g16b-read` (evidence 94).
  3. **G16c:** remove that Reader. Screenshot 95: the assignment gone; optional if past 7 minutes. Tooni says go for `s4-g16c-read` (evidence 96). After that go, G may do G17 straight away; the read doesn't depend on elevation.
  4. **G17:** Microsoft Entra ID > Properties > Access management for Azure resources = No, Save. **The clock stops.** Screenshot 97: the banner clear. Sign out.
- **After the window:**
  - Close the private window, then open one as G. Microsoft Entra ID > Monitoring > Audit logs, Service = "Azure RBAC (Elevated Access)". Screenshot 98: both entries (https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin#view-elevate-access-log-entries).
  - Tooni says go for `s4-g17-after` (evidence 99).
  - Optional, read-only: G opens the non-lab workspace URL to see whether workspace admin still works with no Azure role. No changes, and it stays out of evidence.
- **Actual times:** G16 Save 11:14 Toronto, G17 Save 11:22 Toronto. Entra audit: elevated 16:14:23Z, User Access Administrator at root removed 16:22:34Z, a window of 8 minutes 11 seconds. G16b passed. G16c was skipped under the 8-minute rule, and screenshot 95 wasn't taken. G's Reader stayed on `ga-ag-ops-shared` for the cleanup gate below. 95 and 96 aren't used; `s4-g16c-read` became evidence 101.
- **G16b note:** the portal's Add role assignment form for the guest had no Assignment type tab, so it created a direct, active, permanent assignment (consistent with G8).
- **Read-backs:** T was denied at root (`w2-pim/84`), so the proof of elevation on and off is G's own view plus the audit entries. Learn says Global Administrators have permission to read role assignments at root.
- **Stop rules:**
  - A stop inside the window means finish G16c if possible, then G17, then stop. Elevation is never left on.
  - If G16c isn't done 8 minutes after the clock starts, G17 goes first. T then activates Owner to remove the leftover Reader, as its own gate.
  - If the clock passes 10 minutes, G17 still goes straight away. Record the overrun.
  - If G16 or G16b fails, record it and go to G17. Restoring G's Owner is then its own gate, by T under activation or by the emergency account after elevating.
  - G's own portal view counts inside the window. T's retry of a stale read runs after G17, under a new TAG.
- **Masking:** screenshots 92, 93, 95, 97 and 98 are masked before they go into `docs/evidence/w2-pim/`: account bar, URL bar, UPNs and emails, tenant domain, tenant ID, subscription ID, correlation, request and assignment IDs, IPs, non-lab resource names.
- **Undo:** G16 by G17, or repeat the toggle. G16b by G16c. G16c by re-adding the Reader. The time spent elevated and the audit entries can't be undone.

## G16c cleanup: T removes the guest's leftover Reader (`w2-pim`, D-030, 2026-11-05)

- **Date:** 2026-11-05. Written before the steps; the actual times get added after them.
- **Why:** G16c was skipped under the 8-minute rule, so G's Reader is still on `ga-ag-ops-shared`. G has no way to remove it without elevating again, and T needs an activation to write.
- **Why portal:** PIM activation is done in the portal, by T in the normal browser.
- **Who:** T. Tooni does every sign-in.
- **Steps:**
  1. PIM > My roles > Azure resources > Eligible assignments > Owner at the subscription > Activate. Duration 1 hour. Justification: "Stage 4 cleanup: remove guest Reader left on ga-ag-ops-shared after G16c was skipped". Record the activation time in UTC and Toronto. On 2026-11-04 the form showed no MFA prompt, so record whether one appears.
  2. Sign out and in on the portal. Tooni signs in again on the CLI.
  3. Run `s4-g16c-cleanup`. It stops unless T has exactly one activated Owner at the subscription and G has exactly one Reader at exactly the `ga-ag-ops-shared` scope. It deletes that one assignment by ID and nothing else.
  4. Run `s4-g16c-read`. Expected: G's Reader 0.
  5. At least 5 minutes after the activation time, deactivate in PIM > My roles > Azure resources > Active assignments. Sign out and in on the portal and the CLI.
  6. Run the new read, TAG `s4-cleanup-deactivated`. Expected: T activated 0, G assignments 0, Owner at subscription 0.
- **Actual times:** activated 11:42 Toronto (16:42Z), 1 hour. No MFA prompt, same as G10 on 2026-11-04. Deactivated 11:49 Toronto (16:49Z).
- **First-run failure:** the first run of `s4-cleanup-deactivated` exited 1 before its `read_at` line, with 1 line in private stderr and no output. The CLI was likely not signed in; the cause isn't confirmed, because the stderr line wasn't read. After Tooni signed in again, the same script passed unchanged at 16:53:12Z.
- **Evidence:** 100 `s4-g16c-cleanup`, 101 `s4-g16c-read`, 102 `s4-cleanup-deactivated`.
- **Stop rules:** an unexpected read-back stops the sitting. If the delete is refused, nothing is retried without a new yes. A stale role read gets one retry after 10 minutes, under a new TAG, as its own approval.
- **Undo:** G elevates and re-adds the Reader, or T under activation does. There's no reason to.
- **While activated:** T's Owner has no condition and can assign Owner and User Access Administrator (findings, 2026-11-04). The only write planned is the one delete.

## APIM gateway steps outside the template (`w2-apim`, C3, C6, 2026-11-12)

Each step below follows every deploy of `infra/apim.bicep`; a redeploy re-PUTs the backend without its credential and sets public network access back to Enabled (findings, 2026-11-12). All as T with Owner active.

- **4a, Azure portal, 16:59Z:** APIM > Backends > `ga-content-safety` > Authorization credentials > Managed identity: system assigned, resource `https://cognitiveservices.azure.com`. **Why not IaC:** no ARM schema for `service/backends` has a managed identity credential property (Bicep BCP037 at every version), although the REST GET returns `credentials.managedIdentity`. **Read-back:** `az rest` GET at 2024-05-01, `credentials.managedIdentity.resource` as set. Evidence `w4-thu/03`.
- **4b, Foundry portal (ai.azure.com, New Foundry), 17:21Z to 17:25Z:** Manage > AI Gateway > Add AI Gateway > `ga-ai-labv3do` > Use existing > `ga-apim-lab-v3doqe` (no name field), then Add project to gateway for `ga-proj-labv3do`. **Why not IaC:** the Foundry gateway connection has no documented template. **What it created:** API `ga-ai-labv3do` (key header `api-key`), backend `ga-ai-labv3do`, a product and its subscription, and Cognitive Services User for APIM's identity on `ga-ai-labv3do` (findings). Evidence `w4-thu/04a`, `04b`.
- **4c, Azure portal in Edge on the jumpbox, about 17:44Z:** APIM > Subscriptions > Add: `ga-harness-jumpbox`, scope API `ga-ai-labv3do`. The key went into `$env:GA_APIM_KEY` in the jumpbox PowerShell window only. **Why not IaC:** the key must not pass through the laptop or a deployment output. Evidence `w4-thu/05`.
- **4d, Azure portal, 17:55Z:** APIM > Network > Inbound > Public network access: Disable. **Why not IaC:** for Standard v2, Learn allows this only in the portal, after the private endpoint exists (https://learn.microsoft.com/azure/api-management/private-endpoint#optionally-disable-public-network-access). **Read-back:** `publicNetworkAccess` Disabled at 17:58:21Z, after the update finished. Evidence `w4-thu/06`.
- **API policy, CLI, 18:26:39Z:** `az rest --method put` on `apis/ga-ai-labv3do/policies/policy` (2024-05-01, rawxml): `<base />` in all four sections and `<set-backend-service backend-id="ga-ai-labv3do" />` in inbound. **Why:** the 4b flow left the API with no `serviceUrl` and no `set-backend-service`, so every allowed call failed with "Backend service URL is not defined" (findings). **Why not IaC:** the API is created by the Foundry portal, not by `apim.bicep`. **Read-back:** the policy as sent; global policy hash unchanged (`46108f9c17e0`).
- **Undo:** all of these go with the instance at teardown (step 12b removes the Foundry gateway first).

## Entra diagnostic setting and report-only Conditional Access (`w2-sentinel`, `w2-agentid`, D-040, 2026-11-12)

Planned for the evening of 2026-11-12. Times and evidence numbers go here after the sitting. T does both steps in the Microsoft Entra admin center with Security Administrator active (PIM, Entra role) and no Owner. Security defaults stay on.

- **Before:** T activates Security Administrator, signs out of the portal and back in, then runs `az logout` and `az login`, so the new role is in both tokens.
- **1. Diagnostic setting, first** (https://learn.microsoft.com/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs#send-logs-to-azure-monitor):
  - Entra ID > Monitoring & health > Diagnostic settings > Add diagnostic setting.
  - Name: `ga-entra-to-law-shared`.
  - Categories: AuditLogs, SignInLogs, NonInteractiveUserSignInLogs, ServicePrincipalSignInLogs, ManagedIdentitySignInLogs. Nothing else.
  - Send to Log Analytics workspace: the lab subscription, `ga-law-shared`. Save.
  - An authorization error at Save is a STOP (D-040).
  - **Done 2026-11-13:**
    - The Save at 01:32Z (20:32 Toronto) failed with `LinkedAuthorizationFailed`: no `workspaces/sharedKeys/action` on `ga-law-shared` with Reader only (`w4-fri/01`).
    - Owner was activated at 01:35Z for 1 hour, and the retry saved by 01:40Z (`w4-fri/02`).
    - Findings, 2026-11-13, has the details and the least-privilege alternative.
- **2. GA-CA-01** (https://learn.microsoft.com/entra/identity/conditional-access/policy-block-authentication-flows#device-code-flow-policies):
  - Entra ID > Conditional Access > Policies > New policy.
  - Name: "GA-CA-01 case managers block device code flow (report-only)".
  - Users: include `grp-larkfield-cm`; exclude the emergency access account.
  - Target resources: as chosen on screen. Learn recommends All resources; the read-back records the choice.
  - Conditions > Authentication flows: Configure Yes, Device code flow.
  - Grant: Block access.
  - Enable policy: Report-only. Create.
- **3. GA-CA-02:**
  - Name: "GA-CA-02 case managers require MFA (report-only)".
  - The same users and exclusion, and no authentication flows condition.
  - Grant: Grant access, Require multifactor authentication.
  - Enable policy: Report-only. Create.
- **If the portal refuses** either policy because security defaults are on: STOP, and record a finding. Security defaults aren't turned off (D-040, D-034).
- **Done by 02:03Z (21:03 Toronto, 2026-11-12):**
  - Both policies were created as report-only and target All resources (`w4-fri/03a` to `03c`; `04b`, the list).
  - GA-CA-02's grant is authentication strength "Multifactor authentication", not the Require multifactor authentication checkbox. Learn calls them equivalent.
  - The portal showed "You must first disable security defaults before enabling a Conditional Access policy" and still allowed report-only creation (`04a`; findings, 2026-11-13).
- **Why not IaC:** Tooni's decision for this sitting.
  - The setting has a Bicep form, a tenant-scope deployment of `microsoft.aadiam/diagnosticSettings` (https://learn.microsoft.com/azure/templates/microsoft.aadiam/diagnosticsettings). T's rights for a tenant-scope deployment haven't been checked.
  - The lab has no Graph write path set up for the policies.
- **Read-backs (laptop, read-only, each its own approval):** `scripts/identity_readbacks.sh`.
  - `diag`: the aadiam setting.
  - `ca`, with `GA_EA_UPN` set in the shell: the policies through Graph.
  - `ca-audit SINCE`: the same checks from AuditLogs, if Graph refuses.
  - `logs SINCE`: first rows in the workspace.
- **Undo:** the 11-15/16 teardown list (the working run sheet, week plan).

## L1: one E5 trial seat for `cm-alder` through a PIM-eligible License Administrator for T (`w2-dspm`, 2026-11-15)

- **What:** Sunday L1 of the Purview negative test (the working run sheet, Part 0b). `cm-alder` (usage location already Canada) got one Microsoft 365 E5 seat, all apps as defaulted, sign-in still blocked. Saved 19:27Z (14:27 Toronto). Billing > Licenses: before 24 available, 1/25 assigned; after 23 available, 2/25 assigned.
- **Why portal-only and by this route:**
  - G, the guest Global Administrator on a consumer Microsoft account, was refused by the Microsoft 365 admin center: "Login is not supported for consumer users without business presence."
  - Licence assignment is no longer offered in the Entra admin center UI. Learn: "Group-based licensing in Microsoft Entra ID, part of Microsoft Entra, is managed in the Microsoft 365 admin center" (https://learn.microsoft.com/entra/identity/users/licensing-powershell-graph-examples#overview). The page Tooni cited, `entra/identity/users/licensing-groups-assign`, now resolves to the Microsoft 365 admin center page (https://learn.microsoft.com/microsoft-365/admin/manage/manage-group-licenses), which names Microsoft Graph PowerShell as the API route. The exact "will no longer support license assignment through their user interfaces" sentence was found on Learn only quoted in a Q&A post, which isn't cited (the lab cites documentation pages only).
  - So, with Tooni's yes, G gave T a PIM assignment of License Administrator in Entra PIM, and T assigned the seat in the Microsoft 365 admin center. A Graph PowerShell assignment was possible too but needed a new consented app permission; not used.
- **Deviation:** the PIM assignment was created as **Eligible**, not Active as planned. Harmless: T had to activate it (1 hour, with justification), which is less standing access.
- **Steps:** G, Entra admin center, private window: PIM > Microsoft Entra roles > License Administrator > add T (eligible). T: PIM > My roles > activate (1 hour); sign out and in to the Microsoft 365 admin center; Users > Active users > `cm-alder` > Licenses and apps > Microsoft 365 E5 > Save. T: deactivate in PIM. G: remove the eligibility. All private windows closed.
- **Read-backs:** the PIM portal showed no License Administrator eligibility or assignment for T afterwards. Activation and deactivation times: not recorded.
- **Gap: the CLI read-back is unproven.** `GET /me/memberOf/microsoft.graph.directoryRole` returned empty both before and after, so it was never shown to list a PIM-activated role. Don't rely on it.
- **Proposed read-only check for next time (not run):**
  - `az rest --method get --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances/filterByCurrentUser(on='principal')" --query "value[].{role:roleDefinitionId, type:assignmentType, start:startDateTime, end:endDateTime}"`, with the role ID resolved by display name (`/roleManagement/directory/roleDefinitions?$filter=displayName eq 'License Administrator'&$select=id`) rather than typed.
  - Learn: "Get the instances of active role assignments for the calling principal"; least privileged delegated permission `RoleAssignmentSchedule.Read.Directory`; "the signed-in user must be assigned a supported Microsoft Entra role ... For read operations: *Global Reader*, *Security Operator*, *Security Reader*, *Security Administrator*, or *Privileged Role Administrator*" (https://learn.microsoft.com/graph/api/unifiedroleassignmentscheduleinstance-filterbycurrentuser?view=graph-rest-1.0#permissions).
  - So T activates its eligible Security Reader first. Positive control: run it while the target role is active (expect 1 instance), then after deactivation (expect 0).
  - Risk: the Azure CLI's Graph token may not carry `RoleAssignmentSchedule.Read.Directory`, as it lacked `Policy.Read.All` for the Conditional Access read on 2026-11-13. If refused, record the error class, don't grant consent, and keep the PIM portal's My roles page (masked screenshot) as the read-back. The eligibility counterpart, `roleEligibilityScheduleInstances/filterByCurrentUser`, has its own permission; check its Learn page before use.
- **Teardown:** Wednesday 11-18, deleting `cm-alder` frees the seat; read back 1/25 assigned and no License Administrator eligibility or assignment for T (teardown plan).

## Foundry Control Plane Purview toggle: on Sunday, off Tuesday, portal only (`w2-dspm`, 2026-11-15)

- **What:** Sunday DP1 turned on "Powered by Microsoft Purview" for the lab subscription, about 21:44 to 21:46Z, as T with Owner active. Evidence `docs/evidence/w2-dspm/02`, `03`.
- **Why portal-only:** Learn documents only the portal toggle, with no ARM property, CLI command or API (https://learn.microsoft.com/azure/foundry/control-plane/how-to-manage-compliance-security#enable-microsoft-purview-in-foundry, updated 2026-08-04; searched 2026-11-15). DP2 confirmed it: the activity log from 21:40 to 22:05Z holds no write for the toggle, and no `Microsoft.Purview/accounts` resource exists. There's nothing for IaC to manage and no CLI read-back.
- **Steps (on):** Foundry (new) portal (`ai.azure.com`), laptop browser, T with Owner active > Operate > Compliance > Data security and governance > subscription "Azure subscription 1" > turn on **Powered by Microsoft Purview**. The Purview portal's billing and pay-as-you-go pages weren't opened.
- **Steps (off), Tuesday 11-17, teardown P2, its own yes, after the Purview Audit search (A2 to A4):**
  1. Tooni activates Owner in PIM (the turn-on needed it; *inference* that the turn-off does too).
  2. T, Foundry (new) portal, the same path; turn the toggle **off**; screenshot to the private folder, masked into `docs/evidence/w2-dspm/` at the next number.
  3. Read-backs: reload the page (toggle off, "Your AI data estate is not protected" or equivalent); the DP2 activity-log block for the off minute plus 15 minutes (expect no toggle write again); `az resource list --resource-type Microsoft.Purview/accounts --query "length(@)"` (expect 0).
  4. Wednesday's final read-backs check the toggle once more by portal (teardown plan).
- **Side effect seen on the way:** the portal called `listKeys` on `ga-ai-labv3do` 13 times while T's Owner was active (findings, 2026-11-15). Keep the activation short and close the portal before deactivating.
