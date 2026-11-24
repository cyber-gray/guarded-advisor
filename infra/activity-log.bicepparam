using './activity-log.bicep'

// Subscription scope (D-037). Destination: the shared workspace in rg-guardedadvisor-shared (D-011).
param settingName = 'ga-activity-to-law-shared'
param sharedResourceGroupName = 'rg-guardedadvisor-shared'
param workspaceName = 'ga-law-shared'
