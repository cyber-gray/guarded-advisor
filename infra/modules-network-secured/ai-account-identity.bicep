param accountName string
param location string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int
param agentSubnetId string
param networkInjection string = 'true'

// True BYO Foundry account.
// When existingAccountResourceId is set, reference the existing AI Foundry
// (Cognitive Services AIServices kind) account instead of creating a new one
// with a deterministic suffix (which orphans on re-runs and collides on conflict).
@description('Optional. Full ARM resource ID of an existing AI Foundry (CognitiveServices/accounts kind=AIServices) account to reuse. When set, the template will NOT create a new account.')
param existingAccountResourceId string = ''

@description('Optional. When true, skip the model deployment. Recommended when reusing an existing account that already has the required model deployments.')
param skipModelDeployment bool = false

@description('Optional. When true (default), disables API-key (local) authentication on the account. Set to false to enable API-key auth.')
param disableLocalAuth bool = true

// Guarded Advisor: embedding deployment for File Search, and tags.
param embeddingModelName string
param embeddingModelVersion string
param embeddingSkuName string
param embeddingCapacity int
param tags object = {}

var useExistingAccount = !empty(existingAccountResourceId)
var existingParts = split(existingAccountResourceId, '/')
var existingAccountSub = useExistingAccount ? existingParts[2] : subscription().subscriptionId
var existingAccountRg  = useExistingAccount ? existingParts[4] : resourceGroup().name
var existingAccountName = useExistingAccount ? last(existingParts) : accountName

#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = if (!useExistingAccount) {
  name: accountName
  location: location
  tags: tags
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
      bypass:'AzureServices'
    }
    publicNetworkAccess: 'Disabled'
    networkInjections:((networkInjection == 'true') ? [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
      ] : null )
    disableLocalAuth: disableLocalAuth
  }
}

// Reference to existing account (cross-RG / cross-sub aware)
resource existingAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: existingAccountName
  scope: resourceGroup(existingAccountSub, existingAccountRg)
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = if (!useExistingAccount && !skipModelDeployment) {
  parent: account
  name: modelName
  tags: tags
  sku : {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    model:{
      name: modelName
      format: modelFormat
      version: modelVersion
    }
    // Guarded Advisor: never move to an unvalidated model version. At retirement the deployment
    // stops instead of auto-upgrading (fail closed; model inventory, Lifecycle; C5).
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// Guarded Advisor: embedding model for File Search. Deployed after the chat model because
// deployments on one account can't be created in parallel.
#disable-next-line BCP081
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = if (!useExistingAccount && !skipModelDeployment) {
  parent: account
  name: embeddingModelName
  tags: tags
  sku: {
    capacity: embeddingCapacity
    name: embeddingSkuName
  }
  properties: {
    model: {
      name: embeddingModelName
      format: 'OpenAI'
      version: embeddingModelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [
    modelDeployment
  ]
}

// Outputs use ARM short-circuit ternary so only the chosen branch is evaluated.
// Guarded Advisor: '!' asserts non-null in the branch where the account is created (fixes BCP318).
output accountName string = useExistingAccount ? existingAccount.name : account.name
output accountID string = useExistingAccount ? existingAccount.id : account.id
output accountTarget string = useExistingAccount ? existingAccount.properties.endpoint : account!.properties.endpoint
output accountPrincipalId string = useExistingAccount ? existingAccount.identity.principalId : account!.identity.principalId
