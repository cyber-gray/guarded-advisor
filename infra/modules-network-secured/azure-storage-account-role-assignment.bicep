param azureStorageName string
param projectPrincipalId string

// Guarded Advisor (storage rescope, option (b); findings 2026-11-05 and 2026-11-11): the assignment stays at account
// scope, because File Search ingestion creates new ga-ai-labv-<guid> containers, but blob read, write, add and delete
// are limited by a condition to the project's blobstore container and the vector-store container prefix.
@description('Project workspace ID as a dashed GUID (format-project-workspace-id.bicep output)')
param workspaceId string

@description('Prefix of the containers File Search ingestion creates (observed 2026-11-05 and 2026-11-11: ga-ai-labv-<guid>)')
param vectorStoreContainerPrefix string = 'ga-ai-labv-'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: azureStorageName
  scope: resourceGroup()
}

// Blob Storage Owner: b7e6dc6d-f1e8-4753-8033-0f276bb0955b
// Blob Storage Contributor: ba92f5b4-2d11-453d-a403-e96b0029c9fe
resource storageBlobDataContributor 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: resourceGroup()
}

// Condition (Learn, checked 2026-11-11):
// - The pattern and the four DataActions to target for Storage Blob Data Contributor ("read, write, or delete blobs in
//   named containers"): https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-examples#blob-container-names-or-paths
// - An action not named in ActionMatches passes, so every DataAction that reads, writes or deletes blobs is named:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-examples#blob-container-names-or-paths
// - Container name attribute and StringEqualsIgnoreCase / StringStartsWithIgnoreCase:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-attributes#container-name
//   https://learn.microsoft.com/azure/role-based-access-control/conditions-format#string-comparison-operators
// - Conditions apply to DataActions only. The role's container Actions (containers/read, write, delete) and
//   generateUserDelegationKey stay account-wide:
//   https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac#supported-attributes-and-operations
// - Every DataAction of Storage Blob Data Contributor is targeted: read, write, delete, move/action, add/action
//   (https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-contributor).
//   All five support the container name attribute
//   (https://learn.microsoft.com/azure/storage/blobs/storage-auth-abac-attributes#azure-blob-storage-actions-and-suboperations).
var blobstoreContainer = '${workspaceId}-azureml-blobstore'
var contributorCondition = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action\'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEqualsIgnoreCase \'${blobstoreContainer}\' OR @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${vectorStoreContainerPrefix}\'))'

resource storageBlobDataContributorRoleAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(projectPrincipalId, storageBlobDataContributor.id, storageAccount.id) // unchanged: same assignment, updated in place
  properties: {
    principalId: projectPrincipalId
    // Subscription form, as ARM stores it, so what-if shows no role change. The name above keeps the resource group form,
    // so the assignment is the same one. https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-resource#subscriptionresourceid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor.name)
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: contributorCondition
  }
}
