using './bastion.bicep'

// Per-session Bastion Basic (w1-jump, D-018). adminObjectId is passed on the command line at deploy time
// (az ad signed-in-user show); not committed.
param location = 'canadaeast'
param bastionName = 'ga-bas-lab'
param publicIpName = 'ga-pip-bas-lab'
param adminObjectId = ''
param sharedResourceGroupName = 'rg-guardedadvisor-shared'
param logAnalyticsWorkspaceName = 'ga-law-shared'
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
