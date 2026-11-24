using './policy-assignments.bicep'

// rg-guardedadvisor-shared (D-011): allowed locations only. AMPLS and action groups are "global",
// which the built-in skips.
param includeWorkloadPolicies = false
param allowedLocations = [
  'canadaeast'
  'global'
]
