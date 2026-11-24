using './sentinel.bicep'

// rg-guardedadvisor-shared (D-011). No retention or cap change here: shared.bicep owns both.
param workspaceName = 'ga-law-shared'
param deployD5 = true
