using './jumpbox.bicep'

// Jumpbox (w1-jump, D-018). Deployed once; see the header of jumpbox.bicep.
// adminObjectId is passed on the command line at deploy time (az ad signed-in-user show); not committed.
// adminPassword is never passed: ARM generates it from newGuid().
param location = 'canadaeast'
param vmName = 'ga-jump-lab'
param vmSize = 'Standard_B2s'
param adminObjectId = ''
param enableAutoShutdown = true
param autoShutdownTime = '2200'
param autoShutdownTimeZone = 'Eastern Standard Time'
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
