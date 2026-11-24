# Upstream: Microsoft foundry-samples

The network-isolated Foundry infrastructure in `infra/` is a fork of Microsoft's [`15-private-network-standard-agent-setup`](https://github.com/microsoft-foundry/foundry-samples/tree/dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) sample from [microsoft-foundry/foundry-samples](https://github.com/microsoft-foundry/foundry-samples), pinned to commit `dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45` (2026-10-13). Copyright (c) Microsoft Corporation, used under the MIT License; the notice is kept in [`infra/LICENSE-foundry-samples`](LICENSE-foundry-samples). The preflight and cleanup tools in `infra/upstream-tools/` come from the same commit (`deployment-tools/`). API Management is our own module (week 2), not from the sample.

## Upstream files

These 30 files came from the sample at that commit. The upstream license notice is kept in [`LICENSE-foundry-samples`](LICENSE-foundry-samples).

- `infra/main.bicep`
- `infra/modules-network-secured/add-account-capability-host.bicep`
- `infra/modules-network-secured/add-project-capability-host.bicep`
- `infra/modules-network-secured/ai-account-identity.bicep`
- `infra/modules-network-secured/ai-existing-project-connections.bicep`
- `infra/modules-network-secured/ai-project-identity-unique.bicep`
- `infra/modules-network-secured/ai-project-identity.bicep`
- `infra/modules-network-secured/ai-search-role-assignments.bicep`
- `infra/modules-network-secured/application-insights-role-assignment.bicep`
- `infra/modules-network-secured/application-insights.bicep`
- `infra/modules-network-secured/azure-storage-account-role-assignment.bicep`
- `infra/modules-network-secured/blob-storage-container-role-assignments-unique.bicep`
- `infra/modules-network-secured/blob-storage-container-role-assignments.bicep`
- `infra/modules-network-secured/container-registry.bicep`
- `infra/modules-network-secured/cosmos-container-role-assignments.bicep`
- `infra/modules-network-secured/cosmosdb-account-role-assignment.bicep`
- `infra/modules-network-secured/existing-vnet.bicep`
- `infra/modules-network-secured/format-project-workspace-id.bicep`
- `infra/modules-network-secured/monitor-private-link-scope.bicep`
- `infra/modules-network-secured/network-agent-vnet.bicep`
- `infra/modules-network-secured/private-endpoint-and-dns.bicep`
- `infra/modules-network-secured/standard-dependent-resources.bicep`
- `infra/modules-network-secured/subnet.bicep`
- `infra/modules-network-secured/validate-existing-resources.bicep`
- `infra/modules-network-secured/validate-search-aad-auth.bicep`
- `infra/modules-network-secured/vnet.bicep`
- `infra/upstream-tools/cleanup.ps1`
- `infra/upstream-tools/createCapHost.sh`
- `infra/upstream-tools/deleteCapHost.sh`
- `infra/upstream-tools/preflight-check.ps1`

## Changes from upstream

Each change is marked `Guarded Advisor:` in the code.

| Area | Change | Why |
|---|---|---|
| Model deployments | `versionUpgradeOption: 'NoAutoUpgrade'` on every deployment; Standard SKU set in `main.bicepparam` | No unvalidated model version; inference in Canada (C5, D-006, D-014) |
| Embeddings | Second deployment for text-embedding-3-small 1, after the chat model | File Search |
| AI Search | `basic` instead of `standard` | Cost (D-001a) |
| Cosmos DB | Serverless; periodic backup with `backupStorageRedundancy: 'Local'` | Cost; backups stay in Québec (Law 25 s. 17, C5) |
| Storage | `Standard_LRS` instead of the ZRS/GRS logic | Canada East has no zones; GRS replicates to Toronto (C5) |
| Network | APIM subnet delegated to `Microsoft.Web/serverFarms`; NSGs on all three subnets; `privateEndpointNetworkPolicies: 'Enabled'` on the private endpoint subnet | w1-network, D-015 |
| Key Vault | New module `infra/modules/key-vault.bicep` | w1-kv, D-016 |
| Tracing | App Insights, Log Analytics and the Azure Monitor Private Link Scope behind `enableTracing` (default false) | Logs belong in the shared workspace (D-011) |
| Parameters | `tags`, `deployApim` (no effect until week 2), `enableTracing`, embedding, APIM subnet and `keyVaultNameSeed` parameters | Project conventions |
| Capability host | Project capability host behind `deployCapHost` (default `true`) | Capability hosts can't be updated, so redeploys never re-send it |
| AI Search auth | `disableLocalAuth: true`, `authOptions` removed (API keys off) | Built-in policy 71ef260a denies Search with keys enabled (w1-policy, D-017) |
| Lint fixes | The upstream template produced 27 Bicep warnings; all fixed without changing what deploys: `environment()` for the blob zone name; plain `dependsOn` on conditional resources (BCP321); `!` on ternary-guarded conditional access (BCP318); removed an unused parameter and variable; applied the BYO-account scope that `main.bicep` declared but never used to the account capability host module | `bicep lint` passes with no warnings |

**Redeploying an existing stack:** pass `--parameters deployCapHost=false`, for example `az deployment group create -g rg-guardedadvisor-lab --parameters infra/main.bicepparam --parameters deployCapHost=false`. "Updating capability hosts is not supported" (https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts), so only a fresh deploy after a full teardown uses the default. Policy assignments (`scripts/apply-policies.sh`) must exist, and be at least 15 minutes old, before any deploy.

Not imported: `azuredeploy.json`, `add-project*.bicep`, the diagrams and the README. Resource names keep the sample's 4-character suffix from the resource group ID (for example `ga-ai-lab<suffix>`).
