# RBAC review (w1-rbac, 2026-11-05)

Tracker item: "RBAC review: agent and gateway identities hold only the data-plane roles they need; no Owner or Contributor on any identity."

## Result

- **The item holds as amended.** Owner, Contributor and User Access Administrator are 0 everywhere, at subscription scope and below. The project identity carries the runtime roles Microsoft requires for standard agent setup, and two of them carry control-plane rights: Cosmos DB Operator and Search Service Contributor. API Management isn't deployed, so no gateway identity exists.
- **The project identity's storage access isn't limited to its containers.** Its Storage Blob Data Owner condition limits only blob tag read, tag write and tag filtering, so blob read, write and delete pass for any container. Its Storage Blob Data Contributor is assigned account-wide with no condition. The account holds 22 containers, and 20 aren't the two Learn's standard setup names. No Azure change was made; the rescope is on the 2026-11-08 review list.
- **Agent ID (added 2026-11-11, `w2-agentid`):** the account managed identity, both agent identities and both agent blueprints hold 0 Azure role assignments in the subscription and 0 Cosmos DB data-plane assignments. Each blueprint holds one Microsoft Graph application permission, `AgentIdentity.CreateAsManager`, the permission Learn says a blueprint uses to create its agent identities. The project identity owns both agent identities. Details in [Agent ID review](#agent-id-review-w2-agentid-2026-11-11).

## Scope and method

- **Identity:** T, holding Reader at subscription scope, nothing activated. Read-only.
- **Azure RBAC:** `az role assignment list --all --include-inherited`. An identity review needs an all-scopes listing, because a listing at subscription scope misses resource-scope assignments (findings, P1, 2026-11-03).
- **Cosmos DB data plane:** `az cosmosdb sql role assignment list`, because these roles aren't in Azure RBAC.
- **Identities:** matched by `identity.principalId` to resources in `rg-guardedadvisor-*`. Outside-lab scopes are counted, not named.
- **Read:** 18:22:17Z to 18:30:28Z. T saw 16 assignments: 12 lab, 1 subscription, 3 outside the lab. This reconciles with P1's 19: minus G's 3, minus T's conditioned Owner, plus T's Reader.

## Identities and roles

| Identity | Role | Scope | Why | R# |
|---|---|---|---|---|
| `ga-ai-labv3do/ga-proj-labv3do` (project) | Cosmos DB Operator | `ga-ai-labv3docosmosdb` | Standard agent setup, Phase 3 | None, template |
| Project | Cosmos DB Built-in Data Contributor (data plane) | `dbs/enterprise_memory` | Standard agent setup, Phase 4 | None, template |
| Project | Search Index Data Contributor | `ga-ai-labv3dosearch` | Standard agent setup, Phase 4 | None, template |
| Project | Search Service Contributor | `ga-ai-labv3dosearch` | Standard agent setup, Phase 4 | None, template |
| Project | Storage Blob Data Contributor | `gaailabv3dost`, whole account | Learn scopes it to `<workspaceId>-azureml-blobstore` | None, template |
| Project | Storage Blob Data Owner, conditioned | `gaailabv3dost`, whole account | Learn scopes it to `<workspaceId>-azureml-agent` | None, template |
| `ga-jump-lab` (jumpbox) | Cosmos DB Built-in Data Reader (data plane) | `dbs/larkfield/colls/claims` | `get_claim_summary` reads claims | R2/R3 |
| Jumpbox | Monitoring Metrics Publisher | `ga-dcr-agent-shared` | Writes `AgentToolAudit_CL` and `AdjudicationLog_CL` (D-022) | R6 |
| `ga-id-sbx-pull-lab` | AcrPull | `gaacrlabv3doqebnffszc` | Sandbox image pull. Not attached to the group since 2026-10-26 (D-026) | R11 |
| T | Foundry User | `ga-proj-labv3do` | Uses the agent | R1 |
| T | Monitoring Metrics Publisher | `ga-dcr-redteam-shared` | Writes `RedTeamRun_CL` (D-022) | R7 |
| T | Reader | Subscription | Standing read after D-030 (G8) | None |
| T | Virtual Machine Administrator Login | `ga-jump-lab` | Jumpbox sign-in (D-018) | None |
| T | Reader | `ga-jump-lab` | Jumpbox sign-in through Bastion (D-018) | None |
| T | Reader | `ga-jump-lab-nic` | Jumpbox sign-in through Bastion (D-018) | None |

The "None, template" rows have no R number because the core template creates them, not a role gate. The session log splits R2 and R3 no further than one gate. "Why" states purpose; this review didn't test whether each role is used.

**T's jumpbox roles:** Learn requires Reader on the VM, the NIC and the Bastion resource to connect through Bastion (https://learn.microsoft.com/azure/bastion/bastion-faq#vm-connection-and-available-features-faqs, updated 2026-07-01), and Virtual Machine Administrator Login or User Login for Microsoft Entra sign-in (https://learn.microsoft.com/azure/bastion/connect-vm-native-client-linux#verify-roles-and-ports, updated 2026-07-01). Since D-030 gave T Reader at subscription, the resource-scope Readers duplicate it. They're recorded as kept so the jumpbox path doesn't depend on subscription Reader, and they're a cleanup candidate at teardown.

## Agent ID review (w2-agentid, 2026-11-11)

- **Method:** T, holding Reader at subscription scope and no active Entra role, Graph and ARM GETs only. Agent objects were listed with `GET /servicePrincipals/microsoft.graph.agentIdentity` (https://learn.microsoft.com/graph/api/agentidentity-list?view=graph-rest-1.0) and `GET /servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal` (https://learn.microsoft.com/graph/api/agentidentityblueprintprincipal-list?view=graph-rest-1.0).
- **Read times:** lists, the account identity and the agent objects' Azure roles at 04:02:31Z; the project identity, owners, sponsors and Cosmos DB at 04:06:03Z; Graph app role assignments and memberships at 04:10:42Z.

| Identity | Type | Azure RBAC | Cosmos DB data plane | Graph app roles | Memberships | Owners | Sponsors |
|---|---|---|---|---|---|---|---|
| `ga-ai-labv3do` account identity, `b45d...c630` | System-assigned managed identity | 0 | 0 | Not read | Not read | n/a | n/a |
| Project identity, `77f9...5e2a` | System-assigned managed identity | 5, as in the table above (reread, unchanged) | 1, as above | Not read | Not read | n/a | n/a |
| `ga-ai-labv3do-ga-proj-labv3do-larkfield-case-assistant-AgentIdentity`, `5c6d...f4c1` | Agent identity (the agent's own) | 0 | 0 | 0 | 0 | T; project identity | Not readable: delegated access isn't supported (https://learn.microsoft.com/graph/api/agentidentity-list-sponsors?view=graph-rest-1.0) |
| `ga-ai-labv3do-ga-proj-labv3do-AgentIdentity`, `d0c2...8f91` | Agent identity (the project's shared one) | 0 | 0 | 0 | 0 | Project identity | Not readable, as above |
| `ga-ai-labv3do-ga-proj-labv3do-larkfield-case-assistant-f3a0a-AgentIdentityBlueprint`, `208d...0831` | Blueprint principal (the agent's own) | 0 | 0 | 1: Microsoft Graph `AgentIdentity.CreateAsManager` (application) | 0 | None | T |
| `ga-ai-labv3do-ga-proj-labv3do-AgentIdentityBlueprint`, `8db4...58ba` | Blueprint principal (the project's shared one) | 0 | 0 | 1: the same | 0 | None | None |

- **The Graph permission:** its appRoleId `4c39...d001` matches `AgentIdentity.CreateAsManager` in the permissions reference (https://learn.microsoft.com/graph/permissions-reference#all-permissions). Learn says a blueprint "can perform exactly one operation in the tenant: provision or deprovision agent identities", and this permission is what enables it (https://learn.microsoft.com/entra/agent-id/agent-blueprint#key-characteristics-of-agent-identity-blueprints). Sponsors were read on the blueprint application by appId (https://learn.microsoft.com/graph/api/agentidentityblueprint-list-sponsors?view=graph-rest-1.0).
- **Open:** the same blueprint page says "OAuth permissions granted to a agent identity blueprint are granted to all agent identities created from that blueprint". Both agent identities read 0 app role assignments of their own. Whether they act with the blueprint's permission isn't tested.
- **Ownership:** the project identity owns both agent identities (findings, 2026-11-11). T owns the agent's own identity and sponsors its blueprint.
- **Search Index Data Contributor** is assigned to the project identity on the whole `ga-ai-labv3dosearch` service, so on every index in it, with no condition (findings, 2026-11-11).
- **Not ours:** an `Azure SRE Agent Id Application` blueprint principal, `cdc6...90eb`, is Microsoft first-party and holds 0 Azure role assignments in the subscription (findings, 2026-11-11).
- **Verdict:**
  - The agent identities, the blueprints and the account identity hold least privilege: nothing beyond the blueprints' one Graph permission.
  - The project identity is unchanged: it holds as amended, with the storage gap above.
  - The jumpbox identity's Cosmos DB row is unchanged: read-only on the claims container.
- **Limits:**
  - Memberships came from `transitiveMemberOf`, which covers groups and directory roles. The older directory roles API returned 0 where the unified RBAC API returned 1 (findings, 2026-11-05), so this isn't proof that no Entra role is assigned.
  - Not read: the blueprints' federated credentials, Graph data for the managed identities, and anything outside this subscription.

## Checks

| Check | Result | Evidence |
|---|---|---|
| Owner held by any principal | 0 | `w1-rbac/01` |
| Contributor held by any principal | 0 | `w1-rbac/01` |
| User Access Administrator held by any principal | 0 | `w1-rbac/01` |
| Positive control: T's assignments | 6 of 6 | `w1-rbac/01` |
| Administrator or Owner in the role name, held by an identity (listed) | 1: the project's Storage Blob Data Owner | `w1-rbac/01` |
| Lab identity assignments with no R number (listed) | 5 Azure RBAC, plus 1 Cosmos DB data plane, all the project identity | `w1-rbac/01` |
| Project identity's log roles (T4) | None. The 3 outside-lab rows aren't log roles and no lab identity holds them | `w1-rbac/01`, `02` |
| AI Search `disableLocalAuth` | `true` | `w1-rbac/02` |
| Cosmos DB `disableLocalAuth` | `true` | `w1-rbac/02` |
| Containers in `gaailabv3dost` | 22: 1 agent, 1 blobstore, 20 neither | `w1-rbac/03` |

## Key access through the two control-plane roles

- **Search Service Contributor:** its definition has `Microsoft.Search/searchServices/*` and no `notActions`. Learn says it can retrieve admin keys, which give full data-plane access, and that it can set authentication options (https://learn.microsoft.com/azure/search/search-security-rbac#built-in-roles, updated 2026-09-17). The mitigation rests on `disableLocalAuth=true` plus the GA Deny policy on AI local auth (`ga-deny-ai-local-auth`, D-017). It hasn't been tested for this identity.
- **Cosmos DB Operator:** its definition has `Microsoft.DocumentDb/databaseAccounts/*`, and its `notActions` block `listKeys`, `readonlyKeys`, `regenerateKey`, `listConnectionStrings` and role assignment writes. It has no data actions. `disableLocalAuth` is `true`.

## Human identities after D-030

| Identity | Azure | Entra | Evidence |
|---|---|---|---|
| T | Reader at subscription plus 5 narrow roles, nothing activated. Eligible: Owner at subscription (ends 2026-11-19T02:21Z), Privileged Monitoring Data Reader on `rg-guardedadvisor-shared`, R10 on `ga-sbx-lab` | Eligible (Permanent) for Security Reader, no active Entra role | `w2-pim/83`, `w1-rbac/01` (Azure roles); `w1-rbac/04`, `w1-rbac/05` (Entra) |
| G, the guest | No role. Can elevate to User Access Administrator at root, shown for Reader (G16b) | Global Administrator, active and direct. Also sees Budgets through a billing role | `w2-pim/88`, `89`, `94`, `w1-rbac/01` |
| E, the emergency account | No role | Global Administrator, permanent | `w2-pim/17`, `w1-rbac/01` |

No standing Owner remains on the subscription (`w2-pim/102`).

**T:** T is eligible (Permanent) for Security Reader (Entra), directory scope, with no active Entra role (w1-rbac/04, w1-rbac/05, 2026-11-05).

## Deviations

- **R9 removed** (2026-10-27, D-026): the jumpbox identity's Container Apps SandboxGroup Data Owner. Nothing used it, and any jumpbox process could create sandboxes with it. Re-adding it is its own gate.
- **R10 is PIM eligible-only** (2026-10-27): T on `ga-sbx-lab`, with no standing assignment.
- **G8, a direct permanent Reader despite policy:** Reader's PIM policy requires an end date on active assignments (`max=P180D`), but T's Reader has none (`w2-pim/38`). That setting doesn't bind `az role assignment create`. It's used on purpose (findings, G8, G11-pre).
- **G11-pre, the conditioned Owner:** T's Owner carried a condition excluding Owner, User Access Administrator and Role Based Access Control Administrator (`w2-pim/44`). It was replaced because a standing Owner can assign itself the data role or set a Protected table back to General (D-030). Learn allows conditions on eligible assignments for three Storage Blob Data roles only, so activated Owner is stronger than the role it replaced (findings).
- **Storage Account Contributor isn't held:** Learn's manual steps list it for the project identity (Phase 3). It's absent today; whether the agent needs it isn't tested.
- **R4, R5 and R8:** temporary, and none appears in this listing.

## Learn's sources for the runtime roles

- **Standard agent setup:** Phases 3 and 4 list the project identity's roles, and scope the storage roles to the two containers (https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup#provision-resources-step-by-step, updated 2026-07-09).
- **Elevated-role tasks:** it lists the same search and Cosmos DB data roles, and names the second container `agents-blobstore`. (https://learn.microsoft.com/azure/foundry/concepts/administrator-guide#standard-agent-setup, updated 2026-10-23). It also lists Storage Blob Data Contributor on the project storage account for the File Search tool, which this agent uses (https://learn.microsoft.com/azure/foundry/concepts/administrator-guide#infrastructure-tools). So Learn isn't uniform on storage scope.

## Limits

- **Assigned, not used:** this shows what's assigned, not what's needed. Rescoping is the test of the storage roles.
- **The 20 other containers:** their names don't say what they hold or which service uses them. A rescope may break the agent if the service needs them, so the plan retests it.
- **Eligible assignments:** T's come from `w2-pim/83`. Nobody else's are visible to T.
- **Visible to T:** this is the best view without an activation, not proof of completeness. Entra roles, Databricks workspace admin and other non-RBAC paths aren't listed.
- **The jumpbox identity (A13, D-027):** any process on the jumpbox can use it. C2 stays launch-blocking until a service identity exists.
- **Deny policy:** the local-auth policy wasn't tested against this identity.

## Evidence

- [`docs/evidence/w1-rbac/`](evidence/w1-rbac/README.md): the listing, the details and the container list.
- [`docs/evidence/w2-pim/`](evidence/w2-pim/README.md): `11` (P1), `38` (G8), `44` (G11-pre), `83` (T's roles), `88` and `89` (G), `94` (G16b), `102` (no standing Owner).
- `docs/findings.md`: P1, G8 and G11-pre, and the 2026-11-05 storage condition entry.
