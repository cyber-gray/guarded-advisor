using './sandbox.bicep'

// rg-guardedadvisor-lab (D-025). Principal IDs stay empty here and are never passed: R9 (jumpbox managed identity)
// was removed 2026-10-27 under D-026 and comes back only as a gated step if run_analysis reopens; R10 (T) is
// PIM-eligible since 2026-10-27 and managed in PIM (runbook).
param location = 'canadaeast'
param sandboxGroupName = 'ga-sbx-lab'
param maxSandboxCount = 2
param defaultTimeoutSeconds = 900
// Just-in-time pull identity (IDEAS.md, 2026-10-26): no identity on the group by default, so nothing running in a
// sandbox can reach one. scripts/build-sandbox-image.sh register attaches ga-id-sbx-pull-lab (AcrPull on the
// analysis-image registry, R11) only for a registration run and detaches it afterwards; verify.sh sandboxes flags an
// identity on the group at any other time.
param pullIdentityName = ''
param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
