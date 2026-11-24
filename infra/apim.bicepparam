using './apim.bicep'

// rg-guardedadvisor-lab, per session (w2-apim, D-003, D-010). Synthetic publisher details.
// publisherEmail uses the reserved .invalid top-level domain (RFC 2606), so it can't reach anyone.
param publisherName = 'Guarded Advisor lab (synthetic)'
param publisherEmail = 'apim-lab@guarded-advisor.invalid'

// Caller allowlist (object IDs), read at compile time from the environment so no ID is stored here. No default: if
// the variable isn't set, the build fails (BCP427, checked 2026-11-12) before anything deploys. Set it from the
// signed-in caller, e.g.
//   export GA_GATEWAY_ALLOWED_OIDS="$(az ad signed-in-user show --query id -o tsv)"
// https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-parameters-file#readenvironmentvariable
param gatewayAllowedOids = readEnvironmentVariable('GA_GATEWAY_ALLOWED_OIDS')

// D-038: LLM message bodies only in a synthetic test window. Default off; set GA_LOG_LLM_MESSAGES=true for the window.
param logLlmMessages = bool(readEnvironmentVariable('GA_LOG_LLM_MESSAGES', 'false'))

// Foundry backend token audience. Default https://cognitiveservices.azure.com; on a backend 401, redeploy with
// GA_FOUNDRY_BACKEND_RESOURCE=https://ai.azure.com/ (run sheet rule, its own yes).
param foundryBackendResource = readEnvironmentVariable('GA_FOUNDRY_BACKEND_RESOURCE', 'https://cognitiveservices.azure.com')

param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
