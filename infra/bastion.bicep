// Per-session Bastion Basic for the jumpbox (w1-jump, D-018). Guarded Advisor template.
// Deployed by `scripts/jumpbox.sh up` at session start and removed by `scripts/teardown.sh session`
// (Reader assignment, diagnostic setting, host, then public IP). AzureBastionSubnet stays deployed (main.bicep).
//
// - Basic, not Developer: Microsoft Entra ID sign-in for RDP in the portal needs Basic or higher and is in
//   public preview; Developer can't do it (https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication,
//   updated 2026-08-11; https://learn.microsoft.com/azure/bastion/bastion-sku-comparison, updated 2026-07-01).
// - Basic needs AzureBastionSubnet (/26 or larger) and a Standard static public IP.
// - Cost (Retail Prices API, CAD, canadaeast, 2026-10-16): "Azure Bastion" Basic, meter "Basic Gateway"
//   0.2691/hour; "IP Addresses" Standard, meter "Standard IPv4 Static Public IP" 0.0071/hour.
// - Reader on the host is a documented prerequisite for Entra sign-in through Bastion.
// - BastionAuditLogs go to the shared workspace (C6), table MicrosoftAzureBastionAuditLogs
//   (https://learn.microsoft.com/azure/bastion/monitor-bastion-reference).

@description('Azure region')
param location string

@description('Bastion host name')
param bastionName string = 'ga-bas-lab'

@description('Public IP name for the Bastion host')
param publicIpName string = 'ga-pip-bas-lab'

@description('Existing VNet that holds AzureBastionSubnet')
param vnetName string = 'ga-vnet-lab'

@description('Object ID of the person who signs in (Reader on the host); passed at deploy time')
param adminObjectId string

@description('Resource group and name of the shared Log Analytics workspace (D-011)')
param sharedResourceGroupName string = 'rg-guardedadvisor-shared'
param logAnalyticsWorkspaceName string = 'ga-law-shared'

@description('Tags applied to every resource this template creates')
param tags object = {}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
var workspaceId = resourceId(subscription().subscriptionId, sharedResourceGroupName, 'Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaceName)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource bastionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: bastion
  name: guid(bastion.id, adminObjectId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: adminObjectId
    principalType: 'User'
    description: 'Bastion Entra sign-in prerequisite: Reader on the Bastion host (w1-jump, D-018); removed at teardown'
  }
}

resource bastionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: bastion
  name: 'ga-diag-to-shared-law'
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'BastionAuditLogs'
        enabled: true
      }
    ]
  }
}

output bastionName string = bastion.name
output publicIpName string = publicIp.name
