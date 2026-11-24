using './sandbox-image.bicep'

// rg-guardedadvisor-lab (D-025 option A). grantAcrPull stays false here: R11 is passed on the command line in its
// own approved deploy.
param location = 'canadaeast'
param registryPrefix = 'gaacrlab'
param pullIdentityName = 'ga-id-sbx-pull-lab'
param sharedResourceGroupName = 'rg-guardedadvisor-shared'
param logAnalyticsWorkspaceName = 'ga-law-shared'
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
