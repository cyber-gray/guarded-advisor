using './custom-tables.bicep'

// rg-guardedadvisor-shared (D-011, D-022). Writer principal IDs stay empty here: each one is passed on the command
// line in its own approved deploy (R6 jumpbox managed identity, R7 T).
param location = 'canadaeast'
param workspaceName = 'ga-law-shared'
param dceName = 'ga-dce-shared'
param agentDcrName = 'ga-dcr-agent-shared'
param redteamDcrName = 'ga-dcr-redteam-shared'
param evidenceRetentionDays = 90
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
