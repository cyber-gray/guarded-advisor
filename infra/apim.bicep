// API Management Standard v2 as the AI gateway, Phase 1 (w2-apim, w2-policies, w2-llmlogs; C3, C6). Standalone and
// deployed per session (D-003, D-010), not through main.bicep (deployApim stays reporting-only). Removed by
// `scripts/teardown.sh apim`, which also purges the soft-deleted instance.
//
// Learn, checked 2026-11-12 (the Learn connector shows no updated dates):
// - Standard v2 is available in Canada East:
//   https://learn.microsoft.com/azure/api-management/api-management-region-availability#supported-regions-for-v2-tiers-and-workspace-gateways
// - API version 2024-05-01 (the GA version; v2 capabilities need 2024-05-01 or later):
//   https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview#api-version
// - Outbound VNet integration on a subnet delegated to Microsoft.Web/serverFarms with an NSG (apim-subnet, w1-network):
//   https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound#prerequisites
//   Inference, not stated on Learn: in the template it's virtualNetworkType 'External' plus
//   virtualNetworkConfiguration.subnetResourceId, the only VNet properties the 2024-05-01 schema has. The deploy read-back
//   checks it.
// - Inbound private endpoint, sub-resource 'Gateway' only, zone privatelink.azure-api.net:
//   https://learn.microsoft.com/azure/api-management/private-endpoint#steps-to-configure-private-endpoint
// - Public network access can be disabled only after the private endpoint exists, and for Standard v2 only in the
//   portal: it stays Enabled here and is turned off in the portal with a CLI read-back (runbook).
//   https://learn.microsoft.com/azure/api-management/private-endpoint#optionally-disable-public-network-access
// - Diagnostic categories GatewayLogs and GatewayLlmLogs, resource-specific tables:
//   https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-apimanagement-service-logs
// - Content Safety backend with managed identity (resource https://cognitiveservices.azure.com) and Cognitive Services
//   User for APIM's identity: https://learn.microsoft.com/azure/api-management/llm-content-safety-policy#prerequisites
// - Soft-delete: 48 hours, then the name can be reused only after a purge:
//   https://learn.microsoft.com/azure/api-management/soft-delete#soft-delete-behavior
//
// Gateway fixes, drafted 2026-11-12 after the first window (findings): the Foundry AI Gateway portal flow is replaced.
// - The model API is imported here from a minimal OpenAPI definition (apim/foundry-openai-v1-chat.openapi.json, one
//   operation), Learn option 2: https://learn.microsoft.com/azure/api-management/azure-openai-api-from-specification#option-2-add-an-openapi-specification-to-api-management
//   llm-token-limit works with APIs "that conform to" the OpenAI Chat Completions schema
//   (https://learn.microsoft.com/azure/api-management/llm-token-limit-policy#supported-model-apis). The ARM schema has
//   no language-model API type (service/apis type and apiType: graphql, grpc, http, mcp, odata, soap, websocket;
//   checked through 2025-09-01-preview). Inference, to prove live: an API imported from a Chat Completions definition is what
//   the gateway treats as a language-model API, so T1 gets 429 and ApiManagementGatewayLlmLog gets rows. If it doesn't,
//   the fallback is Learn option 1 (portal import "Microsoft Foundry", Azure OpenAI v1), with a CLI read-back.
// - Backends carry their managed identity credential here, not in the portal. No ARM schema version has the property,
//   but the REST GET returns credentials.managedIdentity (findings, 2026-11-12), so it's set with BCP037 suppressed;
//   the what-if and the read-back prove it. Resource https://cognitiveservices.azure.com, per Learn:
//   https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity
// - APIM's identity gets Cognitive Services OpenAI User on the Foundry account (same Learn section). Learn's Backends
//   page says Cognitive Services User for an Azure OpenAI backend
//   (https://learn.microsoft.com/azure/api-management/backends#configure-managed-identity-for-authorization-credentials);
//   the lab follows the LLM page, the narrower role. On 2026-11-12 the portal flow assigned Cognitive Services User.
// - Caller authorization: global policy, oid allowlist from the named value ga-gateway-allowed-oids (findings, GW-X2).
// - The harness subscription is created here, scoped to the API. The built-in all-access subscription ('master') is NOT
//   in this template: a PUT with its service scope '/' passed what-if and failed at deploy (2026-11-13, findings). It's
//   suspended after the deploy by scripts/apim_suspend_master.sh (Subscription - Update PATCH, the call that worked on
//   2026-11-13). Learn: "you can suspend, cancel, or delete any subscription (including the built-in all-access
//   subscription)":
//   https://learn.microsoft.com/azure/api-management/api-management-subscriptions#create-and-manage-subscriptions-in-azure-portal
//
// Still not here: public network access off (portal only for Standard v2, runbook), API-level LLM message logging
// (off; D-038), and routing the agent through the gateway (Phase 3, deferred).

@description('Azure region')
param location string = resourceGroup().location

@description('APIM name; gateway hostnames are global, so it carries a short unique suffix')
param apimName string = 'ga-apim-lab-${take(uniqueString(resourceGroup().id), 6)}'

@description('Publisher name (required by the API)')
param publisherName string = 'Guarded Advisor lab (synthetic)'

@description('Publisher email (required by the API); a reserved, non-routable address')
param publisherEmail string

@description('VNet that holds apim-subnet and pe-subnet')
param vnetName string = 'ga-vnet-lab'

@description('Subnet for outbound VNet integration (delegated to Microsoft.Web/serverFarms)')
param apimSubnetName string = 'apim-subnet'

@description('Subnet for the inbound private endpoint')
param peSubnetName string = 'pe-subnet'

@description('Content Safety account used by llm-content-safety (w1-cs)')
param contentSafetyName string = 'ga-cs-labv3do'

@description('Shared resource group and workspace for logs (D-011)')
param sharedResourceGroupName string = 'rg-guardedadvisor-shared'
param workspaceName string = 'ga-law-shared'

@description('Foundry account that hosts the model deployments')
param foundryAccountName string = 'ga-ai-labv3do'

// No default: the .bicepparam file reads it from GA_GATEWAY_ALLOWED_OIDS, so no ID is stored in the repository.
@description('Comma-separated object IDs allowed through the gateway (caller authorization)')
@minLength(36)
param gatewayAllowedOids string

// Token audience APIM's identity requests for the Foundry backend. Default per Learn
// (api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity). Fallback: https://ai.azure.com/,
// which the Foundry AI Gateway portal flow set and which worked against services.ai.azure.com/openai/v1 on 2026-11-12
// (findings). Run sheet rule: on a backend 401, redeploy with the fallback, as its own yes.
@description('Managed identity resource (token audience) for the ga-foundry backend')
@allowed([
  'https://cognitiveservices.azure.com'
  'https://ai.azure.com/'
])
param foundryBackendResource string = 'https://cognitiveservices.azure.com'

// D-038: prompt and completion bodies are logged only in synthetic test windows. Off by default; the .bicepparam file
// reads GA_LOG_LLM_MESSAGES. Token usage rows don't depend on it (Learn: the diagnostic setting sends token usage and
// the model name for each request, and "optionally" the messages):
// https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs#enable-diagnostic-setting-for-language-model-api-logs
@description('Log LLM prompt and completion messages for the model API (synthetic test windows only, D-038)')
param logLlmMessages bool = false

param tags object = {}

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User (built-in)
// Cognitive Services OpenAI User (built-in): https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#ai--machine-learning
var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesResource = 'https://cognitiveservices.azure.com'
var foundryHost = '${foundryAccountName}.services.ai.azure.com'
var allowedOids = toLower(replace(gatewayAllowedOids, ' ', ''))

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource apimSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: apimSubnetName
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: peSubnetName
}

resource contentSafety 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: contentSafetyName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
  scope: resourceGroup(sharedResourceGroupName)
}

// 1. ApiManagementGatewayLlmLog keeps its default retention (30/30): ga-law-shared is a Defender-connected
//    Sentinel workspace, where analytics retention is 30 days to two years and is set in the Defender portal
//    (https://learn.microsoft.com/azure/sentinel/manage-table-tiers-retention#manage-table-settings). D-038 revised.

// 2. The instance: Standard v2, one unit, system-assigned identity, outbound VNet integration.
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    publicNetworkAccess: 'Enabled' // Learn: disabled only after the private endpoint exists, in the portal (Standard v2)
    // Pinned to the values the first deploy produced (2026-11-12). Left unset, the redeploy what-if predicted both
    // portals Disabled => Enabled and the NAT gateway Enabled => Disabled (findings). The developer and legacy portals
    // stay off: the lab has no portal users.
    // https://learn.microsoft.com/azure/templates/microsoft.apimanagement/2024-05-01/service
    developerPortalStatus: 'Disabled'
    legacyPortalStatus: 'Disabled'
    natGatewayState: 'Enabled' // the deployed value; the first deploy set it, not this template
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnet.id
    }
  }
}

// 3. Inbound private endpoint for the gateway, with its own private DNS zone.
resource apimDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azure-api.net'
  location: 'global'
  tags: tags
}

resource apimDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: apimDnsZone
  name: 'apim-${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource apimPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${apimName}-private-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${apimName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: apim.id
          groupIds: [
            'Gateway'
          ]
        }
      }
    ]
  }
}

resource apimDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: apimPrivateEndpoint
  name: '${apimName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${apimName}-dns-azure-api-config'
        properties: {
          privateDnsZoneId: apimDnsZone.id
        }
      }
    ]
  }
}

// 4. Gateway logs and LLM logs to the shared workspace.
resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'ga-apim-to-shared-law'
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
  }
}

// 5. Content Safety backend for llm-content-safety. Learn says its authorization credentials must be Managed Identity
//    with resource https://cognitiveservices.azure.com (llm-content-safety-policy#prerequisites). No ARM schema for
//    service/backends, 2024-05-01 to 2025-09-01-preview, has a managed identity credential property
//    (https://learn.microsoft.com/azure/templates/microsoft.apimanagement/2025-09-01-preview/service/backends#backendcredentialscontract),
//    but on 2026-11-12 the REST GET at 2024-05-01 returned credentials.managedIdentity {clientId, resource} after the
//    portal set it (findings). So it's set here with BCP037 suppressed. Proven at what-if and by the read-back; if the
//    service ignores it, the portal step (runbook 4a) comes back.
resource contentSafetyUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: contentSafety
  name: guid(contentSafety.id, apim.id, cognitiveServicesUserRoleId)
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'ga-content-safety'
  properties: {
    description: 'Azure AI Content Safety for llm-content-safety (private endpoint, Entra only)'
    url: 'https://${contentSafetyName}.cognitiveservices.azure.com'
    protocol: 'http'
    credentials: {
      // System-assigned identity (no clientId). Not in the ARM schema; returned by the REST API (see above).
      #disable-next-line BCP037
      managedIdentity: {
        resource: cognitiveServicesResource
      }
    }
  }
}

// 5b. The Foundry model backend: Cognitive Services OpenAI User for APIM's identity on the Foundry account, and a
//     backend with the same managed identity credential pattern. The base URL is the OpenAI v1 surface that the
//     harness proved on 2026-11-12 (B1 to B3 200 through https://<account>.services.ai.azure.com/openai/v1/...).
resource foundryOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, apim.id, cognitiveServicesOpenAiUserRoleId)
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      cognitiveServicesOpenAiUserRoleId
    )
  }
}

resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'ga-foundry'
  properties: {
    description: 'Foundry OpenAI v1 surface for ${foundryAccountName} (private endpoint, Entra only)'
    url: 'https://${foundryHost}/openai/v1'
    protocol: 'http'
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: foundryBackendResource
      }
    }
  }
}

// 6. Named values and the global policy.
resource tenantIdValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ga-tenant-id'
  properties: {
    displayName: 'ga-tenant-id'
    value: tenant().tenantId
    secret: false
  }
}

// Caller allowlist for the global policy (oid claims, lower case, comma-separated). Not secret: object IDs identify,
// they don't authenticate. Kept readable so the read-back can compare it.
resource allowedOidsValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ga-gateway-allowed-oids'
  properties: {
    displayName: 'ga-gateway-allowed-oids'
    value: allowedOids
    secret: false
  }
}

resource globalPolicy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('policies/apim/global.xml')
  }
  dependsOn: [
    tenantIdValue
    allowedOidsValue
    contentSafetyBackend
  ]
}

// 7. The model API, imported from the minimal OpenAI v1 chat completions definition. Clients call
//    https://<gateway>/foundry/openai/v1/chat/completions with the model in the body and the key in api-key (the
//    header the harness takes from --subscription-key-header).
resource foundryApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'ga-foundry-openai-v1'
  properties: {
    displayName: 'Foundry OpenAI v1 (chat completions only)'
    path: 'foundry/openai/v1'
    protocols: [
      'https'
    ]
    format: 'openapi+json'
    value: replace(loadTextContent('apim/foundry-openai-v1-chat.openapi.json'), '{foundry-host}', foundryHost)
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
  }
}

resource foundryApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: foundryApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('policies/apim/foundry-api.xml')
  }
  dependsOn: [
    foundryBackend
  ]
}

// 7b. API-level Azure Monitor diagnostic for the model API: language-model logs on (token usage rows), message
//     bodies only when logLlmMessages is true (D-038). largeLanguageModel isn't in the 2024-05-01 schema (BCP037,
//     checked with a local build on 2026-11-12) and is in 2024-06-01-preview, the earliest version Learn's template
//     reference lists with it: https://learn.microsoft.com/azure/templates/microsoft.apimanagement/2024-06-01-preview/service/apis/diagnostics
//     This is deliberately the template's only preview API version: 2024-05-01 (GA) lacks largeLanguageModel. Move it
//     to a GA version once one includes the property.
//     Inference, proven at what-if and deploy: the instance's built-in 'azuremonitor' logger (seen on 2026-11-12 after
//     the diagnostic setting was created) is the logger for resource-specific Azure Monitor logs.
var llmMessageSettings = {
  messages: 'all'
  maxSizeInBytes: 32768
}

resource foundryApiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: foundryApi
  name: 'azuremonitor'
  properties: {
    loggerId: '${apim.id}/loggers/azuremonitor'
    logClientIp: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    largeLanguageModel: logLlmMessages ? {
      logs: 'enabled'
      requests: llmMessageSettings
      responses: llmMessageSettings
    } : {
      logs: 'enabled'
    }
  }
  dependsOn: [
    apimDiagnostics
  ]
}

// 8. Subscriptions: the harness's, scoped to the one API (its key is read on the jumpbox only, runbook).
//    The built-in all-access subscription isn't declared here. The earlier version declared 'master' with scope '/'
//    and state 'suspended'; what-if listed it as a plain Create, and the deploy rejected it: "Subscription scope should
//    be one of '/apis', '/apis/{apiId}', '/products/{productId}'" (2026-11-13, findings). A clean what-if didn't prove
//    the deploy. Moving 'master' to '/apis' isn't used: Learn calls the built-in subscription service-scoped, a
//    different scope class from all APIs
//    (https://learn.microsoft.com/azure/api-management/api-management-subscriptions#all-access-subscription), and a
//    scope change on it is untested. scripts/apim_suspend_master.sh suspends it right after the deploy.
resource harnessSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'ga-harness-jumpbox'
  properties: {
    displayName: 'ga-harness-jumpbox'
    scope: '/apis/${foundryApi.name}'
    state: 'active'
    allowTracing: false
  }
}

output apimName string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output chatCompletionsPath string = '/${foundryApi.properties.path}/chat/completions'
