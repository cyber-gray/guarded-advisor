// Policy assignments at resource-group scope (w1-policy, D-017). Domain-neutral (D-012).
// Deployed to rg-guardedadvisor-lab (full set) and rg-guardedadvisor-shared (locations only) by
// scripts/apply-policies.sh. Custom definitions live in infra/policies/azure-policy/ and are created at
// subscription scope by the same script before this runs.
//
// Assignments at resource-group scope are deleted with the group, so rerun scripts/apply-policies.sh
// after `scripts/teardown.sh all`.

targetScope = 'resourceGroup'

@description('true for the lab group (all assignments); false for the shared group (allowed locations only)')
param includeWorkloadPolicies bool = true

@description('Allowed resource locations. The built-in already skips location "global" (private DNS zones, AMPLS); listing it is explicit, not required.')
param allowedLocations array = [
  'canadaeast'
  'global'
]

@description('Full versioned model asset IDs approved in the model inventory. The built-in matches with "contains", so keep the version.')
param approvedModelAssetIds array = []

@description('Exact format/name/version strings for the custom control-plane model allowlist (D-017)')
param approvedModels array = []

@description('Deployment SKUs allowed by the custom SKU allowlist')
param allowedDeploymentSkus array = [
  'Standard'
]

// Built-in definitions (IDs verified with `az policy definition show`, 2026-10-15).
var builtIn = {
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
  aiServicesRestrictNetwork: '037eea7a-bd0a-46c5-9a66-03aea78705d3'
  storagePublicNetwork: 'b2982f36-99f2-4db5-8eff-283140c09693'
  vaultPublicNetwork: '405c5871-3e91-4644-8a63-58e19d68ff5b'
  searchPublicNetwork: 'ee980b6d-0eca-4501-8d54-f6290fd512c3'
  aiServicesLocalLogin: '71ef260a-8f18-47b7-abcb-62d0673d94dc'
  approvedModels: 'aafe3651-cb78-4f68-9f81-e7e41509110f'
  // Verified 2026-10-29: https://learn.microsoft.com/azure/cosmos-db/policy-reference (Audit, Deny, Disabled;
  // version 1.2.0) and the definition JSON in Azure/azure-policy (one parameter, effect, default Audit).
  cosmosLocalLogin: '5450f5bd-9c72-4390-a9c4-a7aba4edfdd2'
}

// Each assignment pins its definition's major version (definitionVersion), matching what the service
// set by default at creation. Without it, what-if shows the property being removed, and a redeploy
// could move an assignment to a new major version unreviewed (2026-10-29, D-017). Majors checked with
// `az policy definition show` on 2026-10-29: every built-in's newest major equals its pin.

var deny = {
  effect: {
    value: 'Deny'
  }
}

var workloadAssignments = [
  {
    name: 'ga-deny-ai-network'
    displayName: 'GA: AI Services and AI Search must restrict network access'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.aiServicesRestrictNetwork)
    definitionVersion: '3.*.*'
    parameters: deny
    message: 'Guarded Advisor: AI Services and AI Search must not be reachable from public networks (private endpoints only).'
  }
  {
    name: 'ga-deny-cs-public-network'
    displayName: 'GA: Cognitive Services public network access must be Disabled (strict)'
    definitionId: subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'ga-cognitive-services-pna-disabled')
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor: set publicNetworkAccess to Disabled. A firewall default of Deny is not enough (D-017).'
  }
  {
    name: 'ga-deny-storage-public-network'
    displayName: 'GA: Storage accounts must disable public network access'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.storagePublicNetwork)
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor: storage accounts must have publicNetworkAccess Disabled (private endpoints only).'
  }
  {
    name: 'ga-deny-kv-public-network'
    displayName: 'GA: Key Vault must disable public network access'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.vaultPublicNetwork)
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor: Key Vault must have publicNetworkAccess Disabled (D-016).'
  }
  {
    name: 'ga-deny-search-public-network'
    displayName: 'GA: AI Search must disable public network access'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.searchPublicNetwork)
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor: AI Search must have publicNetworkAccess Disabled (private endpoints only).'
  }
  {
    name: 'ga-deny-ai-local-auth'
    displayName: 'GA: AI Services and AI Search must disable key (local) authentication'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.aiServicesLocalLogin)
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor: disableLocalAuth must be true. Microsoft Entra ID is the only access method.'
  }
  {
    // The template sets disableLocalAuth on the claim store; nothing enforced it (A13 check 3, 2026-10-29).
    name: 'ga-deny-cosmos-local-auth'
    displayName: 'GA: Cosmos DB accounts must disable key (local) authentication'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.cosmosLocalLogin)
    definitionVersion: '1.*.*'
    parameters: deny
    message: 'Guarded Advisor C2: Cosmos DB disableLocalAuth must be true, so account keys can never bypass Entra RBAC on the claim store.'
  }
  {
    name: 'ga-deny-unapproved-models'
    displayName: 'GA: Model deployments must use approved, version-pinned models'
    definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.approvedModels)
    definitionVersion: '1.*.*'
    parameters: {
      effect: {
        value: 'Deny'
      }
      allowedPublishers: {
        value: []
      }
      allowedAssetIds: {
        value: approvedModelAssetIds
      }
    }
    message: 'Guarded Advisor C5: only models approved in the model inventory may be deployed (scenarios/<pack>/model-inventory.md). A new model or version needs re-intake.'
  }
  {
    name: 'ga-deny-deployment-sku'
    displayName: 'GA: Model deployments must use an allowed SKU (Standard)'
    definitionId: subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'ga-allowed-deployment-skus')
    definitionVersion: '1.*.*'
    parameters: {
      effect: {
        value: 'Deny'
      }
      allowedSkus: {
        value: allowedDeploymentSkus
      }
    }
    message: 'Guarded Advisor C5: model deployments must use the Standard SKU so inference stays in Canada (D-006).'
  }
  {
    // Compensating control for the built-in above, which did not deny an ARM deployment (test T5, D-017).
    name: 'ga-deny-unpinned-models'
    displayName: 'GA: Model deployments must use an approved model and version (control plane)'
    definitionId: subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'ga-allowed-deployment-models')
    definitionVersion: '1.*.*'
    parameters: {
      effect: {
        value: 'Deny'
      }
      allowedModels: {
        value: approvedModels
      }
    }
    message: 'Guarded Advisor C5: only the model versions approved in the model inventory may be deployed, with an explicit version. A new model or version needs re-intake (D-017).'
  }
]

var locationAssignment = {
  name: 'ga-allowed-locations'
  displayName: 'GA: Allowed locations (Canada East)'
  definitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.allowedLocations)
  definitionVersion: '1.*.*'
  parameters: {
    effect: {
      value: 'Deny'
    }
    listOfAllowedLocations: {
      value: allowedLocations
    }
  }
  message: 'Guarded Advisor C5: resources must be in Canada East (D-006).'
}

var assignments = includeWorkloadPolicies ? concat([locationAssignment], workloadAssignments) : [locationAssignment]

resource policyAssignments 'Microsoft.Authorization/policyAssignments@2025-11-01' = [for a in assignments: {
  name: a.name
  properties: {
    displayName: a.displayName
    description: 'Managed by infra/policy-assignments.bicep (D-017).'
    policyDefinitionId: a.definitionId
    definitionVersion: a.definitionVersion
    enforcementMode: 'Default'
    parameters: a.parameters
    nonComplianceMessages: [
      {
        message: a.message
      }
    ]
    metadata: {
      managedBy: 'bicep'
      project: 'guarded-advisor'
    }
  }
}]

output assignmentNames array = [for (a, i) in assignments: policyAssignments[i].name]
