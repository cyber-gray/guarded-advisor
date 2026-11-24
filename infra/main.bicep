/*
Standard Setup Network Secured Steps for main.bicep
-----------------------------------

Guarded Advisor fork (w1-fork, D-001a). Source:
  https://github.com/microsoft-foundry/foundry-samples/tree/dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup
Copyright (c) Microsoft Corporation, MIT License (infra/LICENSE-foundry-samples).
Changes from upstream are listed in README.md (Credits) and marked "Guarded Advisor:" in comments.
*/
@description('Location for all resources.')
@allowed([
  'westus'
  'eastus'
  'eastus2'
  'japaneast'
  'francecentral'
  'spaincentral'
  'uaenorth'
  'southcentralus'
  'italynorth'
  'germanywestcentral'
  'brazilsouth'
  'southafricanorth'
  'australiaeast'
  'swedencentral'
  'canadaeast'
  'canadacentral'
  'westeurope'
  'westus3'
  'uksouth'
  'southindia'

  //only class B and C
  'koreacentral'
  'polandcentral'
  'switzerlandnorth'
  'norwayeast'
])
param location string = 'eastus'

@description('Name for your AI Services resource.')
param aiServices string = 'aiservices'

// Model deployment parameters
@description('The name of the model you want to deploy')
param modelName string = 'gpt-4.1'
@description('The provider of your model')
param modelFormat string = 'OpenAI'
@description('The version of your model')
param modelVersion string = '2025-04-14'
@description('The sku of your model deployment')
param modelSkuName string = 'GlobalStandard'
@description('The tokens per minute (TPM) of your model deployment')
param modelCapacity int = 30

// Guarded Advisor: embedding deployment for File Search (the sample deploys only the chat model).
@description('Embedding model name')
param embeddingModelName string = 'text-embedding-3-small'
@description('Embedding model version')
param embeddingModelVersion string = '1'
@description('Embedding deployment SKU')
param embeddingSkuName string = 'Standard'
@description('Embedding deployment capacity, thousands of tokens per minute')
param embeddingCapacity int = 30

// Guarded Advisor: tags on every taggable resource (project convention).
@description('Tags applied to every resource that supports them')
param tags object = {}

// Guarded Advisor: API Management is our own module from week 2 (D-003, D-010). Until then the
// parameter only reports its value in an output; setting it to true deploys nothing.
@description('Deploy API Management Standard v2 as the AI gateway. No effect until week 2.')
param deployApim bool = false

// Guarded Advisor: the sample always deploys Application Insights, a Log Analytics workspace and an
// Azure Monitor Private Link Scope for hosted-agent tracing. Off until w1-law points it at the
// shared workspace in rg-guardedadvisor-shared (D-011).
@description('Deploy Application Insights, its workspace and the Azure Monitor Private Link Scope')
param enableTracing bool = false

// Guarded Advisor: APIM subnet (w1-network). Only used when a new VNet is created.
@description('Name of the subnet for API Management outbound VNet integration')
param apimSubnetName string = 'apim-subnet'
@description('Address prefix for the API Management subnet (min /27, recommended /24)')
param apimSubnetPrefix string = ''

// Guarded Advisor: jumpbox subnet and AzureBastionSubnet (w1-jump, D-018). The VM is in infra/jumpbox.bicep
// and the per-session Bastion in infra/bastion.bicep; only the subnets live here, because the VNet defines its
// subnets inline and a subnet created anywhere else would be removed by the next redeploy of this template.
@description('Address prefix for the jumpbox subnet')
param jumpboxSubnetPrefix string = ''
@description('Address prefix for AzureBastionSubnet (/26 or larger)')
param bastionSubnetPrefix string = ''

// Guarded Advisor: Key Vault (w1-kv). Bump the seed to get a new vault name after a full teardown:
// purge protection keeps a deleted vault's name reserved for the retention period (D-016).
@description('Seed for the Key Vault name; change it to get a new name after a rebuild')
param keyVaultNameSeed string = 'v1'

// Guarded Advisor: Content Safety for the gateway (w1-cs). Off until deployed with approval.
@description('Deploy Azure AI Content Safety with a private endpoint')
param enableContentSafety bool = false

// Guarded Advisor: shared Log Analytics workspace in rg-guardedadvisor-shared (w1-law, D-011), from
// infra/shared.bicep. Names rather than a resource ID keep the subscription ID out of the repo. An empty
// workspace name disables diagnostic settings; tracing also requires it.
@description('Resource group of the shared Log Analytics workspace')
param sharedResourceGroupName string = 'rg-guardedadvisor-shared'
@description('Name of the shared Log Analytics workspace; empty disables diagnostics and tracing')
param logAnalyticsWorkspaceName string = ''

var logAnalyticsWorkspaceId = empty(logAnalyticsWorkspaceName) ? '' : resourceId(subscription().subscriptionId, sharedResourceGroupName, 'Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaceName)

// Guarded Advisor: data collection endpoint for agent evidence in the shared group (w2-custom, D-022), from
// infra/custom-tables.bicep. It joins the AMPLS so the jumpbox can use the Logs Ingestion API privately.
@description('Name of the shared data collection endpoint to add to the AMPLS; empty adds none')
param dataCollectionEndpointName string = ''

// Guarded Advisor (D-021 T4): the upstream sample grants the project identity read access to trace content.
@description('Grant the project managed identity Log Analytics Reader and Privileged Monitoring Data Reader on Application Insights (upstream default true)')
param grantProjectTraceReaders bool = true

var dataCollectionEndpointId = empty(dataCollectionEndpointName) ? '' : resourceId(subscription().subscriptionId, sharedResourceGroupName, 'Microsoft.Insights/dataCollectionEndpoints', dataCollectionEndpointName)

// Create a short, unique suffix, that will be unique to each resource group
// Deterministic suffix for idempotent re-deploys (same RG = same names)
var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)
var accountName = toLower('${aiServices}${uniqueSuffix}')

@description('Name for your project resource.')
param firstProjectName string = 'project'

@description('This project will be a sub-resource of your account')
param projectDescription string = 'A project for the AI Foundry account with network secured deployed Agent'

@description('The display name of the project')
param displayName string = 'network secured agent project'

// Existing Virtual Network parameters
// vnetName precedence + UX clarity.
// When existingVnetResourceId is set, vnetName is IGNORED and the actual name
// is derived from the resource ID (`last(vnetParts)`). The original default
// 'agent-vnet-test' was misleading: users who copied it as-is alongside
// existingVnetResourceId thought they were targeting a specific VNet but the
// resource ID won, hiding mistakes. Default is now empty.
@description('Virtual Network name. Required ONLY when creating a NEW VNet (existingVnetResourceId is empty). When existingVnetResourceId is set, this value is IGNORED, the name is derived from the resource ID. If you supply both they should match; otherwise the resource ID wins.')
param vnetName string = ''

@description('The name of Agents Subnet to create new or existing subnet for agents')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet to create new or existing subnet for private endpoints')
param peSubnetName string = 'pe-subnet'

//Existing standard Agent required resources
@description('Existing Virtual Network name Resource ID')
param existingVnetResourceId string = ''

@description('Address space for the VNet (only used for new VNet)')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet. The default value is 192.168.0.0/24 but you can choose any size /26 or any class like 10.0.0.0 or 172.168.0.0')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

// Non-destructive subnet handling.
// Set to true when bringing your own pre-configured subnets (NSG/RT/PE policies
// already set by your platform team). Prevents the template from doing a PUT
// that would reset privateEndpointNetworkPolicies and trip tenant policies.
@description('When true and existingVnetResourceId is set, the template will NOT modify your existing subnets.')
param reuseExistingSubnets bool = false

// True BYO Foundry account.
// When set, the template references the existing AI Foundry account instead of
// creating a new one with a deterministic suffix (which orphans on re-runs).
@description('Optional. Full ARM resource ID of an existing AI Foundry (CognitiveServices/accounts kind=AIServices) account to reuse. When set, the template will NOT create a new account.')
param existingAiFoundryAccountResourceId string = ''

@description('Optional. When true, skip the model deployment. Recommended when reusing an existing account that already has the required model deployments.')
param skipModelDeployment bool = false

@description('Optional. When true (default), disables API-key (local) authentication on the account. Set to false to enable API-key auth.')
param disableLocalAuth bool = true

@description('Enable Azure Container Registry with Private Endpoint. When true, creates an ACR (Premium SKU) with a PE in the private endpoints subnet.')
param enableContainerRegistry bool = true

@description('Optional developer IP CIDR to allowlist for ACR push access (e.g., 203.0.113.0/26 or 10.0.0.0/16). When empty, public access remains disabled.')
param developerIpCidr string = ''

// Account-level capability host is auto-created by the Cognitive Services
// resource provider (~5s after the account PUT) when the account is created
// with `networkInjections.scenario='agent'` — as this template always does via
// modules-network-secured/ai-account-identity.bicep. The auto-created host is
// named `{accountName}@aml_aiagentservice`. Only one account-level capability
// host is allowed per account (keyed on ClientId), so PUTting a second one
// (e.g. `caphostacct`) fails with HTTP 409 "cannot create a new Capability Host
// ... for the same ClientId" (see issues #312 / #254 / #255 / #265). This flag
// must therefore stay false for fresh deployments. Set true ONLY when the
// account has NO capability host: a BYO account without one, or after
// `deleteCapHost.sh` for a redeploy.
@description('Optional. Create the account-level capability host explicitly. Leave false for fresh deployments (the platform auto-creates {account}@aml_aiagentservice via networkInjections.scenario=agent). Set true only for a BYO account with no capability host, or to recreate after running deleteCapHost.sh.')
param createAccountCapabilityHost bool = false

// Re-derive BYO account context at main.bicep level so we can scope the
// account-level capabilityHost module to the right RG/subscription.
var useExistingAccount = !empty(existingAiFoundryAccountResourceId)
var existingAccountIdParts = split(existingAiFoundryAccountResourceId, '/')
var existingAccountSubscriptionId = useExistingAccount ? existingAccountIdParts[2] : subscription().subscriptionId
var existingAccountResourceGroupName = useExistingAccount ? existingAccountIdParts[4] : resourceGroup().name

@description('The AI Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchResourceId string = ''
@description('The AI Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureStorageAccountResourceId string = ''
@description('The Cosmos DB Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureCosmosDBAccountResourceId string = ''

//New Param for resource group of Private DNS zones
//@description('Optional: Resource group containing existing private DNS zones. If specified, DNS zones will not be created.')
//param existingDnsZonesResourceGroup string = ''

@description('Subscription ID where existing private DNS zones are located. Leave empty to use current subscription.')
param dnsZonesSubscriptionId string = ''

@description('Object mapping DNS zone names to their resource group, or empty string to indicate creation')
param existingDnsZones object = {
  'privatelink.services.ai.azure.com': ''
  'privatelink.openai.azure.com': ''
  'privatelink.cognitiveservices.azure.com': ''               
  'privatelink.search.windows.net': ''
  'privatelink.blob.${environment().suffixes.storage}': ''
  'privatelink.documents.azure.com': ''
  'privatelink.azurecr.io': ''
}

@description('Object mapping Azure Monitor private DNS zone names to the resource group of an existing zone, or empty string to create it. Use to bring your own centralized Private DNS Zones (e.g. an Azure Landing Zone connectivity subscription) for agent tracing.')
param existingMonitorDnsZones object = {
  'privatelink.monitor.azure.com': ''
  'privatelink.oms.opinsights.azure.com': ''
  'privatelink.ods.opinsights.azure.com': ''
  'privatelink.agentsvc.azure-automation.net': ''
}

@description('Zone Names for Validation of existing Private Dns Zones')
param dnsZoneNames array = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.azurecr.io'
]


var projectName = toLower('${firstProjectName}${uniqueSuffix}')
// Sanitize aiServices for storage account name: lowercase, no hyphens, max 24 chars total.
// Reserve last 6 chars for `${uniqueSuffix}st` so uniqueness is preserved when prefix is truncated.
var aiServicesSanitized = toLower(replace(aiServices, '-', ''))
var storagePrefixMax = 18 // 24 total - 4 (uniqueSuffix) - 2 ('st' marker)
var storagePrefix = length(aiServicesSanitized) > storagePrefixMax
  ? substring(aiServicesSanitized, 0, storagePrefixMax)
  : aiServicesSanitized
var azureStorageName = '${storagePrefix}${uniqueSuffix}st'

// Cosmos DB allows hyphens but enforces 44-char max. Cap defensively.
var cosmosDBNameRaw = toLower('${aiServices}${uniqueSuffix}cosmosdb')
var cosmosDBName = length(cosmosDBNameRaw) > 44 ? substring(cosmosDBNameRaw, 0, 44) : cosmosDBNameRaw

var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var acrName = toLower('acr${uniqueSuffix}')

// Check if existing resources have been passed in
var storagePassedIn = azureStorageAccountResourceId != ''
var searchPassedIn = aiSearchResourceId != ''
var cosmosPassedIn = azureCosmosDBAccountResourceId != ''
var existingVnetPassedIn = existingVnetResourceId != ''


var acsParts = split(aiSearchResourceId, '/')
var aiSearchServiceSubscriptionId = searchPassedIn ? acsParts[2] : subscription().subscriptionId
var aiSearchServiceResourceGroupName = searchPassedIn ? acsParts[4] : resourceGroup().name

var cosmosParts = split(azureCosmosDBAccountResourceId, '/')
var cosmosDBSubscriptionId = cosmosPassedIn ? cosmosParts[2] : subscription().subscriptionId
var cosmosDBResourceGroupName = cosmosPassedIn ? cosmosParts[4] : resourceGroup().name

var storageParts = split(azureStorageAccountResourceId, '/')
var azureStorageSubscriptionId = storagePassedIn ? storageParts[2] : subscription().subscriptionId
var azureStorageResourceGroupName = storagePassedIn ? storageParts[4] : resourceGroup().name

var vnetParts = split(existingVnetResourceId, '/')
var vnetSubscriptionId = existingVnetPassedIn ? vnetParts[2] : subscription().subscriptionId
var vnetResourceGroupName = existingVnetPassedIn ? vnetParts[4] : resourceGroup().name
var existingVnetName = existingVnetPassedIn ? last(vnetParts) : vnetName
var trimVnetName = trim(existingVnetName)

// Resolve DNS zones subscription ID - use current subscription if not specified.
// Accept either form: bare GUID or "/subscriptions/<guid>".
// The full ARM path form previously broke the existing-zone cross-sub references
// silently (the subscriptionId field needs the bare GUID).
// Trim leading/trailing whitespace first so a value accidentally pasted with a
// trailing space or newline still normalizes correctly (issue #632).
var trimmedDnsZonesSubscriptionId = trim(dnsZonesSubscriptionId)
var normalizedDnsZonesSubscriptionId = empty(trimmedDnsZonesSubscriptionId)
  ? ''
  : (startsWith(toLower(trimmedDnsZonesSubscriptionId), '/subscriptions/')
      ? trim(split(trimmedDnsZonesSubscriptionId, '/')[2])
      : trimmedDnsZonesSubscriptionId)
var resolvedDnsZonesSubscriptionId = empty(normalizedDnsZonesSubscriptionId) ? subscription().subscriptionId : normalizedDnsZonesSubscriptionId

@description('The name of the project capability host to be created')
param projectCapHost string = 'caphostproj'

// Guarded Advisor: "Updating capability hosts is not supported. To modify a capability host, you must delete
// the existing one and recreate it." (https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts,
// updated 2026-09-25). The same page says a same-name, same-configuration create returns the existing host,
// but the docs are mixed, so redeploys of an existing stack pass deployCapHost=false and never re-send it.
@description('Create the project capability host. true for a fresh deploy; false when redeploying an existing stack.')
param deployCapHost bool = true

// Create Virtual Network and Subnets
module vnet 'modules-network-secured/network-agent-vnet.bicep' = {
  name: 'vnet-${trimVnetName}-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: trimVnetName
    useExistingVnet: existingVnetPassedIn
    existingVnetResourceGroupName: vnetResourceGroupName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    vnetAddressPrefix: vnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    existingVnetSubscriptionId: vnetSubscriptionId
    reuseExistingSubnets: reuseExistingSubnets
    apimSubnetName: apimSubnetName
    apimSubnetPrefix: apimSubnetPrefix
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    tags: tags
  }
}

/*
  Create the AI Services account and gpt-4o model deployment
*/
module aiAccount 'modules-network-secured/ai-account-identity.bicep' = {
  name: '${accountName}-${uniqueSuffix}-deployment'
  params: {
    // workspace organization
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: vnet.outputs.agentSubnetId
    existingAccountResourceId: existingAiFoundryAccountResourceId
    skipModelDeployment: skipModelDeployment
    disableLocalAuth: disableLocalAuth
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingSkuName: embeddingSkuName
    embeddingCapacity: embeddingCapacity
    tags: tags
  }
}
/*
  Validate existing resources
  This module will check if the AI Search Service, Storage Account, and Cosmos DB Account already exist.
  If they do, it will set the corresponding output to true. If they do not exist, it will set the output to false.
*/
module validateExistingResources 'modules-network-secured/validate-existing-resources.bicep' = {
  name: 'validate-existing-resources-${uniqueSuffix}-deployment'
  params: {
    aiSearchResourceId: aiSearchResourceId
    azureStorageAccountResourceId: azureStorageAccountResourceId
    azureCosmosDBAccountResourceId: azureCosmosDBAccountResourceId
    existingDnsZones: existingDnsZones
    dnsZoneNames: dnsZoneNames
  }
}

// Fail fast when a bring-your-own AI Search service rejects Microsoft Entra
// (AAD) data-plane auth (apiKeyOnly). Foundry's CognitiveSearch connection uses
// authType=AAD, so an unpatched existing service leaves agents failing with 403.
// Only the existing-service path needs this; a service this template creates is
// already configured for AAD.
module validateSearchAadAuth 'modules-network-secured/validate-search-aad-auth.bicep' = if (searchPassedIn) {
  name: 'validate-search-aad-auth-${uniqueSuffix}-deployment'
  params: {
    aiSearchName: last(acsParts)
    aiSearchResourceGroupName: aiSearchServiceResourceGroupName
    aiSearchSubscriptionId: aiSearchServiceSubscriptionId
  }
}

// This module will create new agent dependent resources
// A Cosmos DB account, an AI Search Service, and a Storage Account are created if they do not already exist
module aiDependencies 'modules-network-secured/standard-dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    // AI Search Service parameters
    aiSearchResourceId: aiSearchResourceId
    aiSearchExists: validateExistingResources.outputs.aiSearchExists

    // Storage Account
    azureStorageAccountResourceId: azureStorageAccountResourceId
    azureStorageExists: validateExistingResources.outputs.azureStorageExists

    // Cosmos DB Account
    cosmosDBResourceId: azureCosmosDBAccountResourceId
    cosmosDBExists: validateExistingResources.outputs.cosmosDBExists

    tags: tags
    }
}

resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: aiDependencies.outputs.azureStorageName
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
}


resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiDependencies.outputs.aiSearchName
  scope: resourceGroup(aiDependencies.outputs.aiSearchServiceSubscriptionId, aiDependencies.outputs.aiSearchServiceResourceGroupName)
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: aiDependencies.outputs.cosmosDBName
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}

// Private Endpoint and DNS Configuration
// This module sets up private network access for all Azure services:
// 1. Creates private endpoints in the specified subnet
// 2. Sets up private DNS zones for each service
// 3. Links private DNS zones to the VNet for name resolution
// 4. Configures network policies to restrict access to private endpoints only
module privateEndpointAndDNS 'modules-network-secured/private-endpoint-and-dns.bicep' = {
    name: '${uniqueSuffix}-private-endpoint'
    params: {
      aiAccountName: aiAccount.outputs.accountName    // AI Services to secure
      location: location                               // Co-locate PEs with target resources (issue #657)
      aiSearchName: aiDependencies.outputs.aiSearchName       // AI Search to secure
      storageName: aiDependencies.outputs.azureStorageName        // Storage to secure
      cosmosDBName:aiDependencies.outputs.cosmosDBName
      vnetName: vnet.outputs.virtualNetworkName    // VNet containing subnets
      peSubnetName: vnet.outputs.peSubnetName        // Subnet for private endpoints
      suffix: uniqueSuffix                                    // Unique identifier
      vnetResourceGroupName: vnet.outputs.virtualNetworkResourceGroup
      vnetSubscriptionId: vnet.outputs.virtualNetworkSubscriptionId // Subscription ID for the VNet
      cosmosDBSubscriptionId: cosmosDBSubscriptionId // Subscription ID for Cosmos DB
      cosmosDBResourceGroupName: cosmosDBResourceGroupName // Resource Group for Cosmos DB
      aiSearchSubscriptionId: aiSearchServiceSubscriptionId // Subscription ID for AI Search Service
      aiSearchResourceGroupName: aiSearchServiceResourceGroupName // Resource Group for AI Search Service
      storageAccountResourceGroupName: azureStorageResourceGroupName // Resource Group for Storage Account
      storageAccountSubscriptionId: azureStorageSubscriptionId // Subscription ID for Storage Account
      existingDnsZones: existingDnsZones
      dnsZonesSubscriptionId: resolvedDnsZonesSubscriptionId
      tags: tags
    }
    dependsOn: [
    aiSearch      // Ensure AI Search exists
    storage       // Ensure Storage exists
    cosmosDB      // Ensure Cosmos DB exists
  ]
  }

// Optional: Azure Container Registry with Private Endpoint
module acr 'modules-network-secured/container-registry.bicep' = if (enableContainerRegistry) {
  name: 'acr-${uniqueSuffix}-deployment'
  params: {
    acrName: acrName
    location: location
    peSubnetId: vnet.outputs.peSubnetId
    vnetId: vnet.outputs.virtualNetworkId
    suffix: uniqueSuffix
    existingDnsZoneResourceGroup: existingDnsZones['privatelink.azurecr.io']
    dnsZonesSubscriptionId: resolvedDnsZonesSubscriptionId
    developerIpCidr: developerIpCidr
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// Application Insights for hosted-agent tracing (this template ships none). Creates a
// workspace-based Application Insights and connects it to the account so the agent exports traces.
// Guarded Advisor: tracing needs the shared workspace (w1-law, D-011); App Insights stores its data there.
var tracingOn = enableTracing && !empty(logAnalyticsWorkspaceId)

module applicationInsights 'modules-network-secured/application-insights.bicep' = if (tracingOn) {
  name: 'app-insights-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    aiAccountName: aiAccount.outputs.accountName
    disablePublicIngestion: true
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags
  }
}

// Private trace ingestion path (Azure Monitor Private Link Scope) so an in-VNet agent's traces
// reach Application Insights over the private link rather than the (disabled) public endpoint.
module monitorPrivateLink 'modules-network-secured/monitor-private-link-scope.bicep' = if (tracingOn) {
  name: 'monitor-pls-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    appInsightsId: applicationInsights!.outputs.appInsightsId
    logAnalyticsId: applicationInsights!.outputs.logAnalyticsId
    vnetId: vnet.outputs.virtualNetworkId
    peSubnetId: vnet.outputs.peSubnetId
    existingDnsZones: existingMonitorDnsZones
    dnsZonesSubscriptionId: resolvedDnsZonesSubscriptionId
    dataCollectionEndpointId: dataCollectionEndpointId
    tags: tags
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

/*
  Creates a new project (sub-resource of the AI Services account)
*/
module aiProject 'modules-network-secured/ai-project-identity.bicep' = {
  name: '${projectName}-${uniqueSuffix}-deployment'
  params: {
    // workspace organization
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    location: location

    aiSearchName: aiDependencies.outputs.aiSearchName
    aiSearchServiceResourceGroupName: aiDependencies.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: aiDependencies.outputs.aiSearchServiceSubscriptionId

    cosmosDBName: aiDependencies.outputs.cosmosDBName
    cosmosDBSubscriptionId: aiDependencies.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: aiDependencies.outputs.cosmosDBResourceGroupName

    azureStorageName: aiDependencies.outputs.azureStorageName
    azureStorageSubscriptionId: aiDependencies.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: aiDependencies.outputs.azureStorageResourceGroupName
    // dependent resources
    accountName: aiAccount.outputs.accountName
    tags: tags
  }
  dependsOn: [
     validateSearchAadAuth
     privateEndpointAndDNS
     cosmosDB
     aiSearch
     storage
  ]
}

module formatProjectWorkspaceId 'modules-network-secured/format-project-workspace-id.bicep' = {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

/*
  Assigns the project SMI the storage blob data contributor role on the storage account
*/
module storageAccountRoleAssignment 'modules-network-secured/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-${azureStorageName}-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    azureStorageName: aiDependencies.outputs.azureStorageName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
    workspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid // Guarded Advisor: container condition (rescope (b))
  }
  dependsOn: [
   storage
   privateEndpointAndDNS
  ]
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments 'modules-network-secured/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    cosmosDB
    privateEndpointAndDNS
  ]
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments 'modules-network-secured/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
  params: {
    aiSearchName: aiDependencies.outputs.aiSearchName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    aiSearch
    privateEndpointAndDNS
  ]
}

// Account-level capability host (opt-in). See `createAccountCapabilityHost`
// param notes — disabled by default because the Cognitive Services resource
// provider auto-creates `{accountName}@aml_aiagentservice` for fresh accounts
// deployed with networkInjections.scenario='agent'. The project caphost binds
// to that auto-created host. Project caphost depends on this so ordering is
// correct when the flag is true; when false, the dependsOn entry is a no-op in
// ARM. Enabling it on an account that already has a caphost returns HTTP 409.
module addAccountCapabilityHost 'modules-network-secured/add-account-capability-host.bicep' = if (createAccountCapabilityHost) {
  name: 'account-capability-host-${uniqueSuffix}-deployment'
  // Guarded Advisor: apply the scope the comment above describes (upstream declared the
  // variables but never used them). Resolves to this resource group unless the account is BYO.
  scope: resourceGroup(existingAccountSubscriptionId, existingAccountResourceGroupName)
  params: {
    accountName: aiAccount.outputs.accountName
    agentSubnetResourceId: vnet.outputs.agentSubnetId
  }
}

module addProjectCapabilityHost 'modules-network-secured/add-project-capability-host.bicep' = if (deployCapHost) {
  name: 'capabilityHost-configuration-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    cosmosDBConnection: aiProject.outputs.cosmosDBConnection
    azureStorageConnection: aiProject.outputs.azureStorageConnection
    aiSearchConnection: aiProject.outputs.aiSearchConnection
    projectCapHost: projectCapHost
  }
  dependsOn: [
     addAccountCapabilityHost  // no-op when createAccountCapabilityHost=false
     aiSearch      // Ensure AI Search exists
     storage       // Ensure Storage exists
     cosmosDB
     privateEndpointAndDNS
     cosmosAccountRoleAssignments
     storageAccountRoleAssignment
     aiSearchRoleAssignments
  ]
}

// The Storage Blob Data Owner role must be assigned after the caphost is created
module storageContainersRoleAssignment 'modules-network-secured/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    aiProjectPrincipalId: aiProject.outputs.projectPrincipalId
    storageName: aiDependencies.outputs.azureStorageName
    workspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// The Cosmos Built-In Data Contributor role must be assigned after the caphost is created
module cosmosContainerRoleAssignments 'modules-network-secured/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-containers-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosAccountName: aiDependencies.outputs.cosmosDBName
    projectWorkspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
    projectPrincipalId: aiProject.outputs.projectPrincipalId

  }
dependsOn: [
  addProjectCapabilityHost
  storageContainersRoleAssignment
  ]
}

// Grant the project managed identity read access on the tracing Application Insights (for evaluation)
// Guarded Advisor (D-021 T4, w1-rbac): off in this lab. The grant is Log Analytics Reader plus Privileged Monitoring
// Data Reader, which lets the agent's own identity read every conversation's protected trace content; the lab runs no
// evaluations that need it. Turning the parameter off stops redeploys re-creating the grant; the existing assignments
// are removed separately (incremental deployments don't delete).
module applicationInsightsRoleAssignment 'modules-network-secured/application-insights-role-assignment.bicep' = if (tracingOn && grantProjectTraceReaders) {
  name: 'app-insights-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: applicationInsights!.outputs.appInsightsName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Guarded Advisor: Key Vault with RBAC, purge protection, no public access and a private endpoint
  (w1-kv, D-016). Our own module, not part of the upstream sample.
*/
module keyVault 'modules/key-vault.bicep' = {
  name: 'key-vault-${uniqueSuffix}-deployment'
  params: {
    location: location
    keyVaultName: 'ga-kv-${uniqueString(resourceGroup().id, keyVaultNameSeed)}'
    peSubnetId: vnet.outputs.peSubnetId
    vnetId: vnet.outputs.virtualNetworkId
    tags: tags
  }
}

// Guarded Advisor: outputs used by later tasks (w1-cs, w1-law, w1-jump, w2-apim) and verify.sh.
output accountName string = aiAccount.outputs.accountName
output projectName string = aiProject.outputs.projectName
output virtualNetworkId string = vnet.outputs.virtualNetworkId
output peSubnetId string = vnet.outputs.peSubnetId
output apimSubnetId string = vnet.outputs.apimSubnetId
output jumpboxSubnetId string = vnet.outputs.jumpboxSubnetId
output bastionSubnetId string = vnet.outputs.bastionSubnetId
output cognitiveServicesDnsZoneId string = privateEndpointAndDNS.outputs.cognitiveServicesDnsZoneId
output keyVaultName string = keyVault.outputs.keyVaultName
output apimEnabled bool = deployApim
output tracingEnabled bool = enableTracing

/*
  Guarded Advisor: Azure AI Content Safety with a private endpoint in the existing cognitiveservices zone
  (w1-cs). The gateway's llm-content-safety policy calls it in week 2 (C3).
*/
module contentSafety 'modules/content-safety.bicep' = if (enableContentSafety) {
  name: 'content-safety-${uniqueSuffix}-deployment'
  params: {
    location: location
    contentSafetyName: toLower('ga-cs-lab${uniqueSuffix}')
    peSubnetId: vnet.outputs.peSubnetId
    cognitiveServicesDnsZoneId: privateEndpointAndDNS.outputs.cognitiveServicesDnsZoneId
    tags: tags
  }
}

/*
  Guarded Advisor: diagnostic settings on every lab resource that emits resource logs, sent to the shared
  workspace with resource-specific tables (w1-law, C6, D-011).
*/
module diagnostics 'modules/diagnostics.bicep' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'diagnostics-${uniqueSuffix}-deployment'
  params: {
    workspaceId: logAnalyticsWorkspaceId
    accountName: aiAccount.outputs.accountName
    aiSearchName: aiDependencies.outputs.aiSearchName
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    storageName: aiDependencies.outputs.azureStorageName
    keyVaultName: keyVault.outputs.keyVaultName
    contentSafetyName: enableContentSafety ? contentSafety!.outputs.contentSafetyName : ''
    vnetName: vnet.outputs.virtualNetworkName
    nsgNames: [
      'ga-nsg-agent-lab'
      'ga-nsg-pe-lab'
      'ga-nsg-apim-lab'
      'ga-nsg-jump-lab'
    ]
  }
}
