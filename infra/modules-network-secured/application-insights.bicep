/*
Application Insights Module
---------------------------
This module creates workspace-based Application Insights for agent tracing with:
1. Log Analytics workspace
2. Application Insights component (private ingestion for network-secured templates)
3. Connection on the Foundry account so agents export OpenTelemetry traces here
*/

@description('Azure region for the tracing resources.')
param location string

@description('Suffix for unique resource names (the template uniqueSuffix).')
param suffix string

@description('Name of the Foundry (AI Services) account to connect Application Insights to.')
param aiAccountName string

@description('When true, disable public ingestion (reach Application Insights privately via AMPLS). Set false for public templates.')
param disablePublicIngestion bool = true

// Guarded Advisor: use the shared workspace in rg-guardedadvisor-shared instead of creating one in the
// lab group (w1-law, D-011), so traces survive a lab teardown. Tags added.
@description('Resource ID of the existing Log Analytics workspace that stores the telemetry')
param logAnalyticsWorkspaceId string

@description('Tags applied to the Application Insights component')
param tags object = {}

@description('Name of the Application Insights component to create.')
param appInsightsName string = 'appi-tracing-${suffix}'

resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiAccountName
  scope: resourceGroup()
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    publicNetworkAccessForIngestion: disablePublicIngestion ? 'Disabled' : 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Foundry account connection (category AppInsights) so the agent exports OTel traces here.
resource connection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  name: '${aiAccountName}-appinsights'
  parent: aiAccount
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: appInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
}

@description('Resource ID of the Application Insights component.')
output appInsightsId string = appInsights.id

@description('Application ID of the Application Insights component (for trace queries).')
output appInsightsAppId string = appInsights.properties.AppId

@description('Resource ID of the Log Analytics workspace backing Application Insights.')
output logAnalyticsId string = logAnalyticsWorkspaceId

@description('Name of the Application Insights component.')
output appInsightsName string = appInsights.name
