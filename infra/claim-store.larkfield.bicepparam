using './claim-store.bicep'

// Larkfield claim store (w1-agent, w1-rbac R2 and R3). readerPrincipalId is passed at deploy time:
// az vm show -g rg-guardedadvisor-lab -n ga-jump-lab --query identity.principalId -o tsv
param cosmosAccountName = 'ga-ai-labv3docosmosdb'
param databaseName = 'larkfield'
param containerName = 'claims'
param partitionKeyPath = '/claim_id'
param readerPrincipalId = ''
