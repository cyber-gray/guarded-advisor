// Registry and pull identity for the sandbox analysis image (w2-sbx-image, D-025 option A; C4, C6).
// Deployed to rg-guardedadvisor-lab, canadaeast.
//
// - ACR Basic holds only the analysis image and the imported base image it's built from. Admin user disabled and
//   anonymous pull off: the sandbox group pulls with a user-assigned managed identity holding AcrPull on this
//   registry only, so no registry credentials exist anywhere (D-025).
// - Accepted gap (Tooni, 2026-10-23): Basic keeps public network access, so the registry endpoint is reachable from
//   the internet; every pull and push still needs an Entra identity with a role on it. Set explicitly here so the
//   choice is visible.
// - Diagnostic setting to the shared workspace (allLogs, resource-specific tables) for C6, as for every lab resource.
// - R11 (AcrPull for the pull identity) is a separate deploy: grantAcrPull=false creates no assignment.
// Sources:
//   https://learn.microsoft.com/azure/container-registry/container-registry-skus
//   https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/containers#acrpull
//   https://learn.microsoft.com/azure/container-apps/sandboxes-quickstart-bicep (group identity "for gateway
//   connections and registries")

targetScope = 'resourceGroup'

@description('Azure region (D-006)')
param location string = 'canadaeast'

@description('Registry name prefix; a uniqueString suffix keeps the global name unique')
param registryPrefix string = 'gaacrlab'

@description('User-assigned identity the sandbox group uses to pull the analysis image')
param pullIdentityName string = 'ga-id-sbx-pull-lab'

@description('Grant AcrPull on this registry to the pull identity (R11). False = no assignment.')
param grantAcrPull bool = false

@description('Resource group of the shared Log Analytics workspace (D-011)')
param sharedResourceGroupName string = 'rg-guardedadvisor-shared'

@description('Shared Log Analytics workspace name; empty skips the diagnostic setting')
param logAnalyticsWorkspaceName string = 'ga-law-shared'

@description('Tags applied to every resource')
param tags object = {}

// AcrPull: Microsoft.ContainerRegistry/registries/pull/read only.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var registryName = toLower('${registryPrefix}${uniqueString(resourceGroup().id)}')

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled' // accepted gap: Basic can't use private endpoints (D-025)
    zoneRedundancy: 'Disabled'
  }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: pullIdentityName
  location: location
  tags: tags
}

// R11: the pull identity may pull from this registry only.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantAcrPull) {
  name: guid(registry.id, pullIdentity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'w2-sbx R11: ga-sbx-lab pulls the analysis image with this identity (D-025)'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceName)) {
  name: 'ga-diag-to-shared-law'
  scope: registry
  properties: {
    workspaceId: resourceId(subscription().subscriptionId, sharedResourceGroupName, 'Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaceName)
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output registryName string = registry.name
output loginServer string = registry.properties.loginServer
output pullIdentityId string = pullIdentity.id
output pullIdentityPrincipalId string = pullIdentity.properties.principalId
