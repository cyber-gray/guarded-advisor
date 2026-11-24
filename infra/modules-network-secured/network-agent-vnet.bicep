@description('Azure region for the deployment')
param location string

@description('The name of the virtual network')
param vnetName string

@description('Indicates if an existing VNet should be used')
param useExistingVnet bool = false

@description('Subscription ID of the existing VNet (if different from current subscription)')
param existingVnetSubscriptionId string = subscription().subscriptionId

@description('Resource Group name of the existing VNet (if different from current resource group)')
param existingVnetResourceGroupName string = resourceGroup().name

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('Address space for the VNet (only used for new VNet)')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

// Non-destructive subnet handling. See existing-vnet.bicep.
@description('When true and useExistingVnet=true, do NOT modify the existing subnets, reference them as-is.')
param reuseExistingSubnets bool = false

// Guarded Advisor: APIM subnet and tags, passed to the new-VNet path only. The existing-VNet path
// is unchanged and has no APIM subnet (the lab always creates its own VNet).
@description('The name of the API Management subnet (new VNet only)')
param apimSubnetName string = 'apim-subnet'

@description('Address prefix for the API Management subnet (new VNet only)')
param apimSubnetPrefix string = ''

// Guarded Advisor: jumpbox and Bastion subnets (w1-jump, D-018), new VNet only.
@description('Address prefix for the jumpbox subnet (new VNet only)')
param jumpboxSubnetPrefix string = ''

@description('Address prefix for AzureBastionSubnet (new VNet only)')
param bastionSubnetPrefix string = ''

@description('Tags for the VNet and NSGs (new VNet only)')
param tags object = {}

// Create new VNet if needed
module newVNet 'vnet.bicep' = if (!useExistingVnet) {
  name: 'vnet-deployment'
  params: {
    location: location
    vnetName: vnetName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    vnetAddressPrefix: vnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    apimSubnetName: apimSubnetName
    apimSubnetPrefix: apimSubnetPrefix
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    tags: tags
  }
}

// Use existing VNet if requested
module existingVNet 'existing-vnet.bicep' = if (useExistingVnet) {
  name: 'existing-vnet-deployment'
  params: {
    vnetName: vnetName
    vnetResourceGroupName: existingVnetResourceGroupName
    vnetSubscriptionId: existingVnetSubscriptionId
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    reuseExistingSubnets: reuseExistingSubnets
  }
}

// Provide unified outputs regardless of which module was used
// Guarded Advisor: '!' asserts non-null on the branch the ternary selects (fixes BCP318).
output virtualNetworkName string = useExistingVnet ? existingVNet!.outputs.virtualNetworkName : newVNet!.outputs.virtualNetworkName
output virtualNetworkId string = useExistingVnet ? existingVNet!.outputs.virtualNetworkId : newVNet!.outputs.virtualNetworkId
output virtualNetworkSubscriptionId string = useExistingVnet ? existingVNet!.outputs.virtualNetworkSubscriptionId : newVNet!.outputs.virtualNetworkSubscriptionId
output virtualNetworkResourceGroup string = useExistingVnet ? existingVNet!.outputs.virtualNetworkResourceGroup : newVNet!.outputs.virtualNetworkResourceGroup
output agentSubnetName string = agentSubnetName
output peSubnetName string = peSubnetName
output agentSubnetId string = useExistingVnet ? existingVNet!.outputs.agentSubnetId : newVNet!.outputs.agentSubnetId
output peSubnetId string = useExistingVnet ? existingVNet!.outputs.peSubnetId : newVNet!.outputs.peSubnetId
output apimSubnetId string = useExistingVnet ? '' : newVNet!.outputs.apimSubnetId
output jumpboxSubnetId string = useExistingVnet ? '' : newVNet!.outputs.jumpboxSubnetId
output bastionSubnetId string = useExistingVnet ? '' : newVNet!.outputs.bastionSubnetId
