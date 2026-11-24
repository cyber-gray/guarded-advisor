using './main.bicep'

// Guarded Advisor parameters for the fork of Microsoft's 15-private-network-standard-agent-setup
// sample (w1-fork, D-001a). Parameters not set here keep the sample defaults in main.bicep.

// Region: set once here (D-006). Canada East is the only Canadian region with regional Standard
// deployments of the chosen models, which keeps inference in Canada (C5).
param location = 'canadaeast'

// Names. The sample appends a 4-character suffix derived from the resource group ID, for example
// ga-ai-lab1a2b (account), galab1a2bst (storage), ga-ai-lab1a2bsearch, ga-ai-lab1a2bcosmosdb.
param aiServices = 'ga-ai-lab'
param firstProjectName = 'ga-proj-lab'
param displayName = 'Guarded Advisor lab project'
param projectDescription = 'Larkfield Mutual case assistant lab (synthetic data only)'

// Model (D-006, D-014). Standard keeps prompts and responses in the Canada geography. Never
// GlobalStandard or DataZoneStandard: both can process data outside Canada (C5). Deployability
// tested 2026-10-14 (scenarios/larkfield/model-inventory.md). The module sets
// versionUpgradeOption 'NoAutoUpgrade' on every deployment; the model retires 2027-04-14.
param modelName = 'gpt-4.1-mini'
param modelFormat = 'OpenAI'
param modelVersion = '2025-04-14'
param modelSkuName = 'Standard'
param modelCapacity = 30 // thousands of tokens per minute; quota OpenAI.Standard.gpt4.1-mini is 200

// Embeddings for File Search: text-embedding-3-small, version 1, Standard SKU.
param embeddingModelName = 'text-embedding-3-small'
param embeddingModelVersion = '1'
param embeddingSkuName = 'Standard'
param embeddingCapacity = 30 // quota OpenAI.Standard.text-embedding-3-small is 350

// Network (w1-network, D-015; w1-jump, D-018). 192.168.3.0/24 is the jumpbox subnet, 192.168.5.0/26 is
// AzureBastionSubnet, and 192.168.4.0/24 stays reserved for a tools or sandbox subnet (w2).
param vnetName = 'ga-vnet-lab'
param vnetAddressPrefix = '192.168.0.0/16'
param agentSubnetName = 'agent-subnet'
param agentSubnetPrefix = '192.168.0.0/24'
param peSubnetName = 'pe-subnet'
param peSubnetPrefix = '192.168.1.0/24'
param apimSubnetName = 'apim-subnet'
param apimSubnetPrefix = '192.168.2.0/24'
param jumpboxSubnetPrefix = '192.168.3.0/24'
param bastionSubnetPrefix = '192.168.5.0/26'

// Only hosted agents need a container registry; the sample's default is a Premium registry (D-001a).
param enableContainerRegistry = false

// API Management is our own module from week 2 (D-003, D-010). No effect yet.
param deployApim = false

// Tracing (w1-law, D-011): App Insights stores its data in the shared workspace, plus the Azure Monitor
// Private Link Scope (ingestion PrivateOnly, query Open) on this VNet.
param enableTracing = true

// Shared workspace from infra/shared.bicep. Turns on diagnostic settings for every lab resource (C6).
param sharedResourceGroupName = 'rg-guardedadvisor-shared'
param logAnalyticsWorkspaceName = 'ga-law-shared'

// Shared data collection endpoint from infra/custom-tables.bicep, added to the AMPLS (w2-custom, D-022).
param dataCollectionEndpointName = 'ga-dce-shared'

// No trace-content read access for the agent's own identity (D-021 T4): no evaluations run in this lab.
param grantProjectTraceReaders = false

// Content Safety for the gateway (w1-cs).
param enableContentSafety = true

// Key Vault name seed (D-016). Bump to 'v2' for a rebuild after a full teardown: purge protection
// keeps the old name reserved for 7 days.
param keyVaultNameSeed = 'v1'

// Tags on every resource that supports them.
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
