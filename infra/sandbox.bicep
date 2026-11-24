// Sandbox group for agent-written code (w2-sbx-group, D-025; C4). Deployed to rg-guardedadvisor-lab, canadaeast.
//
// - API version 2026-02-01-preview: the Bicep quickstart documents maxSandboxCount and the defaults there; the GA
//   reference (2026-07-01) documents only environmentId. Bicep 0.47 has no types for either version (BCP081), so the
//   properties are read back after deployment instead of trusted (lesson from the silent Tables PATCH, D-021).
// - No vnetConnections child: sandboxes run attacker-influenced code and get no route into the lab VNet or its
//   private endpoints (D-025).
// - Identity: the user-assigned pull identity from infra/sandbox-image.bicep (AcrPull on the registry only, R11), so
//   the group pulls the analysis image with no registry credentials (D-025 option A, A2). Empty name = no identity.
// - Egress policy isn't an ARM property: it's set per sandbox at create time by the client (S3): default Deny, Full
//   inspection, no Transform rules (D-025).
// - Data-plane access: Container Apps SandboxGroup Data Owner at this group's scope only (the Bicep quickstart's
//   pattern). Each principal is a separate deploy (empty = no assignment) so each role assignment is its own gate.
// Sources:
//   https://learn.microsoft.com/azure/container-apps/sandboxes-quickstart-bicep
//   https://learn.microsoft.com/azure/templates/microsoft.app/sandboxgroups
//   https://learn.microsoft.com/azure/container-apps/sandboxes-overview (tiers: XS = 0.25 cores, 0.5 GiB, 20 GiB)

targetScope = 'resourceGroup'

@description('Azure region (D-006, D-025: Canada East)')
param location string = 'canadaeast'

@description('Sandbox group name')
@maxLength(32)
param sandboxGroupName string = 'ga-sbx-lab'

@description('Upper bound on sandboxes in the group (Tooni, 2026-10-23: 2)')
@minValue(1)
@maxValue(10)
param maxSandboxCount int = 2

@description('Default sandbox timeout in seconds')
@minValue(60)
@maxValue(3600)
param defaultTimeoutSeconds int = 900

@description('User-assigned identity the group pulls the analysis image with (infra/sandbox-image.bicep); empty = none')
param pullIdentityName string = ''

// R9 was removed 2026-10-27 under D-026 (run_analysis deferred; A13: any jumpbox process could create sandboxes with
// it). A managed identity can't be PIM-eligible, so it isn't kept standing. Leave this empty; re-adding R9 is a gated
// step of D-026's reopen path, only if run_analysis reopens.
@description('Principal (object) ID that runs analyses: the jumpbox managed identity. Leave empty; R9 is removed (D-026).')
param dataOwnerPrincipalId string = ''

// R10 is PIM-eligible since 2026-10-27, managed in the portal (runbook), not by this template. Leave this empty: a
// value would recreate a standing assignment beside the eligible one. Incremental deploys that leave it empty don't
// touch the existing assignment.
@description('Principal (object) ID of the operator: T. Leave empty; R10 is PIM-eligible and managed in PIM.')
param operatorPrincipalId string = ''

@description('Tags applied to every resource')
param tags object = {}

// Container Apps SandboxGroup Data Owner: data actions Microsoft.App/sandboxGroups/*/read|write|delete|action.
var dataOwnerRoleId = 'c24cf47c-5077-412d-a19c-45202126392c'

#disable-next-line BCP081
resource sandboxGroup 'Microsoft.App/sandboxGroups@2026-02-01-preview' = {
  name: sandboxGroupName
  location: location
  tags: tags
  identity: empty(pullIdentityName) ? { type: 'None' } : {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', pullIdentityName)}': {}
    }
  }
  // allowedLocations and enableDetailedMetrics are sent explicitly, with the names, shapes and values read back from
  // the live group on 2026-10-24 (preview API), instead of trusting the server to keep values the template doesn't
  // send. allowedLocations is C5 evidence, so it's the literal 'canadaeast', kept independent of the deployment
  // region: a changed location parameter can't widen it. The allowed-locations policy on the lab group (Canada East,
  // Deny) is the second layer. managementEndpoint is read-only and set by the server; its what-if Delete row is
  // expected noise.
  properties: {
    allowedLocations: [
      'canadaeast'
    ]
    enableDetailedMetrics: false
    maxSandboxCount: maxSandboxCount
    defaultTimeoutSeconds: defaultTimeoutSeconds
    defaultCpu: '0.25' // XS tier defaults; the client also asks for XS per sandbox
    defaultMemory: '0.5Gi'
    defaultDisk: '20Gi'
  }
}

// R9: the jumpbox managed identity creates, runs and deletes sandboxes in this group only. Not deployed while
// run_analysis is deferred (dataOwnerPrincipalId empty, see the parameter).
resource dataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(dataOwnerPrincipalId)) {
  name: guid(sandboxGroup.id, dataOwnerPrincipalId, dataOwnerRoleId)
  scope: sandboxGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataOwnerRoleId)
    principalId: dataOwnerPrincipalId
    principalType: 'ServicePrincipal'
    description: 'w2-sbx R9: jumpbox managed identity runs analyses in ga-sbx-lab only (D-025)'
  }
}

// R10: the operator lists public images, creates the disk image (S1) and cleans up sandboxes at teardown. Kept only
// for a rebuild without PIM; normally not deployed (operatorPrincipalId empty, see the parameter).
resource operator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(sandboxGroup.id, operatorPrincipalId, dataOwnerRoleId)
  scope: sandboxGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataOwnerRoleId)
    principalId: operatorPrincipalId
    principalType: 'User'
    description: 'w2-sbx R10: T image setup and teardown sandbox cleanup in ga-sbx-lab only (D-025)'
  }
}

output sandboxGroupId string = sandboxGroup.id
output sandboxGroupName string = sandboxGroup.name
