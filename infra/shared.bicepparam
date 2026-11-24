using './shared.bicep'

// rg-guardedadvisor-shared (D-011). Tooni's choice 2026-10-15: 1 GB/day cap, 30-day retention.
// Raise retention to 90 days in w2-sentinel (included with Sentinel) and revisit the cap before week 3.
param location = 'canadaeast'
param workspaceName = 'ga-law-shared'
param retentionInDays = 30
param dailyQuotaGb = 1
// alertEmailAddress is passed on the command line at deploy time; not committed.
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
