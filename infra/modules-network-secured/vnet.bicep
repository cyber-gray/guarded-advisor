/*
Virtual Network Module
This module deploys the core network infrastructure with security controls:

1. Address Space:
   - VNet CIDR: 172.16.0.0/16 OR 192.168.0.0/16
   - Agents Subnet: 172.16.0.0/24 OR 192.168.0.0/24
   - Private Endpoint Subnet: 172.16.101.0/24 OR 192.168.1.0/24

2. Security Features:
   - Network isolation
   - Subnet delegation
   - Private endpoint subnet
*/

@description('Azure region for the deployment')
param location string

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Hub subnet')
param peSubnetName string = 'pe-subnet'


@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

// Guarded Advisor: APIM subnet, NSGs and tags (w1-network, D-015).
@description('The name of the API Management subnet')
param apimSubnetName string = 'apim-subnet'

@description('Address prefix for the API Management subnet')
param apimSubnetPrefix string = ''

// Guarded Advisor: jumpbox and Bastion subnets (w1-jump, D-018, D-019).
@description('The name of the jumpbox subnet')
param jumpboxSubnetName string = 'jumpbox-subnet'

@description('Address prefix for the jumpbox subnet')
param jumpboxSubnetPrefix string = ''

@description('Address prefix for AzureBastionSubnet (/26 or larger)')
param bastionSubnetPrefix string = ''

@description('Tags applied to the VNet and NSGs')
param tags object = {}

var defaultVnetAddressPrefix = '192.168.0.0/16'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix
var apimSubnet = empty(apimSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 2) : apimSubnetPrefix
var jumpboxSubnet = empty(jumpboxSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 3) : jumpboxSubnetPrefix
var bastionSubnet = empty(bastionSubnetPrefix) ? cidrSubnet(vnetAddress, 26, 20) : bastionSubnetPrefix

// Guarded Advisor: agent and private endpoint subnets get NSGs with the default rules only. The
// defaults already allow what the delegated agent subnet needs (AzureActiveDirectory, AzureMonitor,
// MicrosoftContainerRegistry, Azure DNS outbound; AzureLoadBalancer probes inbound):
// https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks (Limitations) and
// https://learn.microsoft.com/azure/container-apps/firewall-integration. Custom rules come in
// w1-verify, once the agent works and can be tested against a baseline.
resource agentNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'ga-nsg-agent-lab'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'ga-nsg-pe-lab'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// Guarded Advisor: APIM Standard v2 outbound VNet integration requires an NSG on its subnet and an
// outbound rule to Azure Key Vault on 443. Inbound NSG rules don't apply to v2 VNet integration.
// https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'ga-nsg-apim-lab'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowKeyVaultOutbound'
        properties: {
          description: 'APIM dependency on Azure Key Vault (Learn: integrate-vnet-outbound)'
          direction: 'Outbound'
          access: 'Allow'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// Guarded Advisor: the jumpbox accepts RDP only from AzureBastionSubnet, which is where Bastion opens the
// session from (https://learn.microsoft.com/azure/bastion/bastion-nsg, target VM subnet). Every other
// inbound flow from the VNet is denied ahead of the default AllowVnetInBound. Outbound keeps the default
// rules until w1-verify or w1-rbac adds service-tag rules (D-019, findings: jumpbox egress).
resource jumpNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'ga-nsg-jump-lab'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromBastion'
        properties: {
          description: 'RDP from AzureBastionSubnet only (D-018)'
          direction: 'Inbound'
          access: 'Allow'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: jumpboxSubnet
          destinationPortRange: '3389'
        }
      }
      {
        name: 'DenyOtherVnetInbound'
        properties: {
          description: 'No other inbound from the VNet; overrides the default AllowVnetInBound'
          direction: 'Inbound'
          access: 'Deny'
          priority: 4000
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddress
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnet
          networkSecurityGroup: {
            id: agentNsg.id
          }
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
          networkSecurityGroup: {
            id: peNsg.id
          }
          // Guarded Advisor: the default is Disabled, which means NSG and UDR rules don't apply to
          // private endpoint traffic. Enabled turns on both.
          // https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnet
          networkSecurityGroup: {
            id: apimNsg.id
          }
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      // Guarded Advisor: jumpbox subnet (w1-jump). defaultOutboundAccess is set explicitly on this subnet only,
      // so the jumpbox's internet egress is visible in code instead of implicit (D-019). The other subnets are
      // left as deployed. https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnet
          networkSecurityGroup: {
            id: jumpNsg.id
          }
          defaultOutboundAccess: true
        }
      }
      // Guarded Advisor: AzureBastionSubnet for Bastion Basic, /26 or larger, kept permanently; the Bastion host
      // and its public IP are created per session (D-018). No NSG: it's optional here, and a partial rule set
      // breaks Bastion (https://learn.microsoft.com/azure/bastion/bastion-nsg).
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnet
        }
      }
    ]
  }
}
// Output variables
output peSubnetName string = peSubnetName
output agentSubnetName string = agentSubnetName
output agentSubnetId string = '${virtualNetwork.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output apimSubnetId string = '${virtualNetwork.id}/subnets/${apimSubnetName}'
output jumpboxSubnetId string = '${virtualNetwork.id}/subnets/${jumpboxSubnetName}'
output bastionSubnetId string = '${virtualNetwork.id}/subnets/AzureBastionSubnet'
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output virtualNetworkResourceGroup string = resourceGroup().name
output virtualNetworkSubscriptionId string = subscription().subscriptionId
