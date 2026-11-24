// Diagnostic settings for every lab resource that emits resource logs, sent to the shared workspace in
// rg-guardedadvisor-shared (w1-law, C6, D-011). Guarded Advisor module.
//
// - categoryGroup 'allLogs' on every resource. Checked against the live resources on 2026-10-15
//   (diagnosticSettingsCategories API): every type below supports the allLogs group.
// - logAnalyticsDestinationType 'Dedicated' sends logs to resource-specific tables where the service
//   supports them. Services without resource-specific tables keep writing to AzureDiagnostics.
//   https://learn.microsoft.com/azure/azure-monitor/platform/resource-logs#send-to-log-analytics-workspace
// - Platform metrics aren't exported (they're kept by Azure Monitor for 93 days at no cost).
// - Excluded, no resource-log categories (checked live): private endpoints, private DNS zones, VNet links.
//   The VNet is included: it has one log category, VMProtectionAlerts.
// Diagnostic settings use a private Microsoft channel and aren't affected by the workspace's or the AMPLS
// network settings (https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-design).

@description('Resource ID of the shared Log Analytics workspace')
param workspaceId string

param accountName string
param aiSearchName string
param cosmosDBName string
param storageName string
param keyVaultName string

@description('Content Safety account name; empty when it isn\'t deployed')
param contentSafetyName string = ''

param nsgNames array = []

@description('Virtual network name')
param vnetName string

var settingName = 'ga-diag-to-shared-law'
var allLogs = [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
]

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource contentSafety 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = if (!empty(contentSafetyName)) {
  name: empty(contentSafetyName) ? 'unused' : contentSafetyName
}

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: aiSearchName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName

  resource blobService 'blobServices' existing = {
    name: 'default'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = [for n in nsgNames: {
  name: n
}]

resource accountDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: account
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource contentSafetyDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(contentSafetyName)) {
  name: settingName
  scope: contentSafety
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource searchDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: search
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource cosmosDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: cosmos
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: storage::blobService
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource keyVaultDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: keyVault
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}

resource nsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (n, i) in nsgNames: {
  name: settingName
  scope: nsgs[i]
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}]

resource vnetDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: vnet
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: allLogs
  }
}
