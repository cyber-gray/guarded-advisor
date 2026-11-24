// Claim store for a scenario pack (w1-agent; w1-rbac R2 and R3). Guarded Advisor template, deployed to the lab group.
//
// - A database and container on the existing Cosmos DB account (serverless, private endpoint, disableLocalAuth true,
//   Local backup). Serverless containers take no throughput settings. Names and partition key come from the pack's
//   .bicepparam, so this template holds no domain data (D-012).
// - One Cosmos DB data-plane role assignment: Cosmos DB Built-in Data Reader for the reader identity (the jumpbox's
//   managed identity), scoped to this container only. Cosmos data roles are Cosmos's own RBAC system, separate from
//   Azure RBAC: Azure roles such as Owner manage the account but grant no data access, and these assignments don't show
//   up in `az role assignment list` (use `az cosmosdb sql role assignment list`).
//   https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control (updated 2026-10-15)
// - Read-only by design (C1). Loading the data uses a temporary Data Contributor assignment made and removed by CLI
//   (w1-rbac R4), not this template.
// - Known gap: any session on the jumpbox can use its managed identity (attack A13, findings 2026-10-20).

@description('Existing Cosmos DB account name')
param cosmosAccountName string

@description('Database name for the pack')
param databaseName string

@description('Container name for the records')
param containerName string

@description('Partition key path')
param partitionKeyPath string

@description('Object ID of the identity that reads records (the jumpbox managed identity); passed at deploy time')
param readerPrincipalId string

var dataReaderRoleId = '00000000-0000-0000-0000-000000000001' // Cosmos DB Built-in Data Reader

resource account 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosAccountName
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2025-04-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2025-04-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          partitionKeyPath
        ]
        kind: 'Hash'
      }
    }
  }
}

resource readerAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: account
  name: guid(account.id, databaseName, containerName, readerPrincipalId, dataReaderRoleId)
  properties: {
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${dataReaderRoleId}'
    principalId: readerPrincipalId
    scope: '${account.id}/dbs/${databaseName}/colls/${containerName}'
  }
  dependsOn: [
    container
  ]
}

output containerScope string = '${account.id}/dbs/${databaseName}/colls/${containerName}'
output readerAssignmentName string = readerAssignment.name
