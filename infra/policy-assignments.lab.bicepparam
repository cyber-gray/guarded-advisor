using './policy-assignments.bicep'

// rg-guardedadvisor-lab: every workload policy (w1-policy, D-017).
param includeWorkloadPolicies = true
param allowedLocations = [
  'canadaeast'
  'global'
]

// Full versioned asset IDs from the azure-openai registry (the model catalog's "Model ID"),
// copied with `az ml model show --registry-name azure-openai` on 2026-10-15. These are the models
// approved in scenarios/larkfield/model-inventory.md. gpt-4o 2024-11-20 is not pinned: D-014 made the
// fallback unnecessary, so deploying it now needs a re-intake and a change here (D-006).
param approvedModelAssetIds = [
  'azureml://registries/azure-openai/models/gpt-4.1-mini/versions/2025-04-14'
  'azureml://registries/azure-openai/models/text-embedding-3-small/versions/1'
]
// Same approvals for the custom control-plane allowlist: exact 'format/name/version' (D-017).
param approvedModels = [
  'OpenAI/gpt-4.1-mini/2025-04-14'
  'OpenAI/text-embedding-3-small/1'
]
param allowedDeploymentSkus = [
  'Standard'
]
