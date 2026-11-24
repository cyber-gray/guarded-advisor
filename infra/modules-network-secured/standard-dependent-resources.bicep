// Creates Azure dependent resources for Azure AI Agent Service standard agent setup

@description('Azure region of the deployment')
param location string

// @description('The name of the Key Vault')
// param keyvaultName string

@description('The name of the AI Search resource')
param aiSearchName string

@description('Name of the storage account')
param azureStorageName string

@description('Name of the new Cosmos DB account')
param cosmosDBName string

@description('The AI Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchResourceId string

@description('The AI Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureStorageAccountResourceId string

@description('The Cosmos DB Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param cosmosDBResourceId string

// param aiServiceExists bool
param aiSearchExists bool
param azureStorageExists bool
param cosmosDBExists bool

// Guarded Advisor: tags on every resource.
param tags object = {}

var cosmosParts = split(cosmosDBResourceId, '/')

resource existingCosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (cosmosDBExists) {
  name: cosmosParts[8]
  scope: resourceGroup(cosmosParts[2], cosmosParts[4])
}

// CosmosDB creation

var canaryRegions = ['eastus2euap', 'centraluseuap']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if(!cosmosDBExists) {
  name: cosmosDBName
  location: cosmosDbRegion
  kind: 'GlobalDocumentDB'
  tags: tags
  properties: {
    // Guarded Advisor: serverless instead of provisioned throughput (cost, D-001a). Supported by
    // the standard agent setup (https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup).
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    // Guarded Advisor: periodic backups default to geo-redundant storage, which replicates to the
    // paired region (Canada Central, Toronto). Local keeps backup copies in Canada East (Quebec):
    // Law 25 s. 17, C5, D-006. https://learn.microsoft.com/azure/cosmos-db/periodic-backup-storage-redundancy
    backupPolicy: {
      type: 'Periodic'
      periodicModeProperties: {
        backupIntervalInMinutes: 240
        backupRetentionIntervalInHours: 8
        backupStorageRedundancy: 'Local'
      }
    }
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

var acsParts = split(aiSearchResourceId, '/')

resource existingSearchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (aiSearchExists) {
  name: acsParts[8]
  scope: resourceGroup(acsParts[2], acsParts[4])
}

// AI Search creation

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = if(!aiSearchExists) {
  name: aiSearchName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Guarded Advisor: API keys off, Entra ID only (w1-policy, D-017). The built-in policy 71ef260a denies
    // Search services with local auth enabled. Foundry's CognitiveSearch connection uses authType AAD,
    // so keys aren't needed. authOptions must be omitted when disableLocalAuth is true.
    disableLocalAuth: true
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'disabled'
    replicaCount: 1
    semanticSearch: 'disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
  // Guarded Advisor: Basic instead of the sample's Standard (S1). Basic supports inbound private
  // endpoints; about CAD 72 instead of CAD 240 over the lab (docs/cost-estimate.md, D-001a).
  sku: {
    name: 'basic'
  }
}

var azureStorageParts = split(azureStorageAccountResourceId, '/')

resource existingAzureStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (azureStorageExists) {
  name: azureStorageParts[8]
  scope: resourceGroup(azureStorageParts[2], azureStorageParts[4])
}

// Guarded Advisor: the sample picks ZRS, or GRS where ZRS isn't offered. Canada East has no
// availability zones, and GRS would replicate to Canada Central (Toronto). LRS keeps stored data
// in Canada East (Quebec): Law 25 s. 17, C5, D-006.
var sku = { name: 'Standard_LRS' }

// Storage creation

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if(!azureStorageExists) {
  name: azureStorageName
  location: location
  kind: 'StorageV2'
  tags: tags
  sku: sku
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
    }
    allowSharedKeyAccess: false
  }
}

output aiSearchName string = aiSearchExists ? existingSearchService.name : aiSearch.name
output aiSearchID string = aiSearchExists ? existingSearchService.id : aiSearch.id
output aiSearchServiceResourceGroupName string = aiSearchExists ? acsParts[4] : resourceGroup().name
output aiSearchServiceSubscriptionId string = aiSearchExists ? acsParts[2] : subscription().subscriptionId

output azureStorageName string = azureStorageExists ? existingAzureStorageAccount.name :  storage.name
output azureStorageId string =  azureStorageExists ? existingAzureStorageAccount.id :  storage.id
output azureStorageResourceGroupName string = azureStorageExists ? azureStorageParts[4] : resourceGroup().name
output azureStorageSubscriptionId string = azureStorageExists ? azureStorageParts[2] : subscription().subscriptionId

output cosmosDBName string = cosmosDBExists ? existingCosmosDB.name : cosmosDB.name
output cosmosDBId string = cosmosDBExists ? existingCosmosDB.id : cosmosDB.id
output cosmosDBResourceGroupName string = cosmosDBExists ? cosmosParts[4] : resourceGroup().name
output cosmosDBSubscriptionId string = cosmosDBExists ? cosmosParts[2] : subscription().subscriptionId
// output keyvaultId string = keyVault.id
