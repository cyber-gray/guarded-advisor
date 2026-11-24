// Key Vault for the lab (w1-kv, D-016). Guarded Advisor module, not from the upstream sample.
//
// - RBAC authorization only (no access policies). Nothing is granted here; roles come per identity in w1-rbac.
// - Soft delete with 7-day retention (the minimum) and purge protection on. Both are set once at creation:
//   retention can't be changed later and purge protection can't be turned off. With purge protection a
//   deleted vault can't be purged before the retention ends, so its name stays reserved for 7 days.
//   https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview
// - No public network access, firewall default Deny, bypass None. No trusted service needs a bypass:
//   API Management is trusted only for custom-domain certificates, and Foundry isn't on the list.
//   https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints
// - Private endpoint (subresource 'vault') with its own private DNS zone, VNet link and zone group.
//   https://learn.microsoft.com/azure/private-link/private-endpoint-dns

@description('Azure region for the vault and its private endpoint')
param location string

@description('Globally unique vault name, 3 to 24 characters')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Resource ID of the private endpoint subnet')
param peSubnetId string

@description('Resource ID of the VNet the private DNS zone is linked to')
param vnetId string

@description('Tags applied to every resource this module creates')
param tags object = {}

var keyVaultDnsZoneName = 'privatelink.vaultcore.azure.net'

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // Explicit: the API default is false (access policies).
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      // Explicit: the API default bypass is AzureServices.
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource keyVaultDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: keyVaultDnsZoneName
  location: 'global'
  tags: tags
}

resource keyVaultDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultDnsZone
  name: 'keyvault-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${keyVaultName}-private-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource keyVaultDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: '${keyVaultName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${keyVaultName}-dns-config'
        properties: {
          privateDnsZoneId: keyVaultDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    keyVaultDnsZoneLink
  ]
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultDnsZoneId string = keyVaultDnsZone.id
