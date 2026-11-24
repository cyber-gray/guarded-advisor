// Azure AI Content Safety for the gateway's llm-content-safety policy (w1-cs; used in w2-policies, C3).
// Guarded Advisor module, not from the upstream sample.
//
// - Entra ID only: disableLocalAuth true. Entra auth requires a custom subdomain, which can't be changed
//   later (https://learn.microsoft.com/azure/ai-services/authentication,
//   https://learn.microsoft.com/azure/ai-services/cognitive-services-custom-subdomains).
// - No public network access; firewall default Deny. No trusted-service bypass: the kind doesn't support it. Clients reach it through the private
//   endpoint and must call the custom subdomain
//   (https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks).
// - Private endpoint subresource 'account' in the existing privatelink.cognitiveservices.azure.com zone,
//   which the Foundry account already uses (https://learn.microsoft.com/azure/private-link/private-endpoint-dns).
// - No role assignments here; API Management's identity gets Cognitive Services User in w2-policies.

@description('Azure region')
param location string

@description('Account name; also used as the custom subdomain (globally unique)')
@minLength(2)
@maxLength(64)
param contentSafetyName string

@description('Resource ID of the private endpoint subnet')
param peSubnetId string

@description('Resource ID of the existing privatelink.cognitiveservices.azure.com zone')
param cognitiveServicesDnsZoneId string

@description('Tags applied to every resource this module creates')
param tags object = {}

resource contentSafety 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: contentSafetyName
  location: location
  tags: tags
  kind: 'ContentSafety'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: contentSafetyName
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    // No 'bypass' property: the ContentSafety kind rejects it even when set to None
    // (NetworkAclsBypassNotSupported, "The Kind 'ContentSafety' does not support Trusted Services", 2026-10-15).
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource contentSafetyPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${contentSafetyName}-private-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${contentSafetyName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: contentSafety.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

resource contentSafetyDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: contentSafetyPrivateEndpoint
  name: '${contentSafetyName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${contentSafetyName}-dns-cogserv-config'
        properties: {
          privateDnsZoneId: cognitiveServicesDnsZoneId
        }
      }
    ]
  }
}

output contentSafetyName string = contentSafety.name
output contentSafetyId string = contentSafety.id
output contentSafetyEndpoint string = contentSafety.properties.endpoint
output contentSafetyPrincipalId string = contentSafety.identity.principalId
