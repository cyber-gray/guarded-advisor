@description('Name of the storage account')
param storageName string

@description('Principal ID of the AI Project')
param aiProjectPrincipalId string

@description('Workspace Id of the AI Project')
param workspaceId string


// Reference existing storage account
resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: storageName
  scope: resourceGroup()
}

// Storage Blob Data Owner Role
resource storageBlobDataOwner 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'  // Built-in role ID
  scope: resourceGroup()
}

// Guarded Advisor (storage rescope, option (b); findings 2026-11-05 and 2026-11-11). The template's condition named only
// blob tag read, tag write and filter, so blob read, write and delete passed for any container (an action not named in
// ActionMatches passes). This condition names every blob DataAction the role grants, all limited to the project's
// agent container, as Learn's standard setup scopes Storage Blob Data Owner
// (https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup#provision-resources-step-by-step).
// Learn, checked 2026-11-11:
// - Actions to target for Storage Blob Data Owner, including runAsSuperUser/action:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-examples#blob-container-names-or-paths
// - Container name attribute; StringStartsWithIgnoreCase and StringLikeIgnoreCase:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-attributes#container-name
//   https://learn.microsoft.com/azure/role-based-access-control/conditions-format#string-comparison-operators
// - Conditions apply to DataActions only; containers/* and generateUserDelegationKey stay account-wide:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac#supported-attributes-and-operations
// - Every DataAction under Owner's blobs/* is targeted (14, from the Microsoft.Storage permissions list:
//   https://learn.microsoft.com/azure/role-based-access-control/permissions/storage#microsoftstorage; role:
//   https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-owner).
//   13 support the container name attribute. filter/action (Find blobs by tags) has only account-level attributes
//   (https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-attributes#azure-blob-storage-actions-and-suboperations),
//   so the container test can't be true for it. Inferred, not tested: filter/action is denied by this condition. It was
//   already in the template's condition the same way, so its behaviour doesn't change.
// The agent container is named <workspaceId>-<12 hex>-azureml-agent (read 2026-11-11), so StartsWith plus Like stays.
var conditionStr = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/deleteBlobVersion/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/permanentDelete/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/manageOwnership/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/modifyPermissions/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/runAsSuperUser/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/immutableStorage/runAsSuperUser/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceId}\' AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase \'*-azureml-agent\'))'

// Assign Storage Blob Data Owner role
resource storageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, aiProjectPrincipalId, storageBlobDataOwner.id, workspaceId)
  properties: {
    principalId: aiProjectPrincipalId
    // Subscription form, as ARM stores it, so what-if shows no role change. The name above keeps the resource group form,
    // so the assignment is the same one. https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-resource#subscriptionresourceid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner.name)
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: conditionStr
  }
}
