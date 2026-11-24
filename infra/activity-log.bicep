// Azure Activity log to ga-law-shared (w2-sentinel, the Azure Activity connector; decision D-037).
// A standalone subscription diagnostic setting, deployed at subscription scope. It's a subscription-level setting, so
// it's its own yes, and it's removed at the 11-15/16 teardown. Diagnostic settings don't take tags.
// Learn, checked 2026-11-11 (the Learn connector shows no updated dates):
// - Activity log export with Bicep: a diagnostic setting at subscription scope:
//   https://learn.microsoft.com/azure/azure-resource-manager/bicep/scenarios-monitoring#diagnostic-settings
// - Resource type: https://learn.microsoft.com/azure/templates/microsoft.insights/diagnosticsettings
// - Categories: all eight Activity log categories (Administrative, Security, ServiceHealth, Alert, Recommendation,
//   Policy, Autoscale, ResourceHealth): https://learn.microsoft.com/azure/azure-monitor/fundamentals/activity-log-schema#categories
//   and https://learn.microsoft.com/powershell/module/az.monitor/get-azeventcategory
// - Cost: AzureActivity isn't charged in Microsoft Sentinel or Log Analytics:
//   https://learn.microsoft.com/azure/sentinel/billing#free-data-sources
// - Permission: Microsoft.Insights/DiagnosticSettings/Write (Monitoring Contributor or Owner); ListKeys is needed only
//   for storage or Event Hubs destinations, not Log Analytics:
//   https://learn.microsoft.com/azure/role-based-access-control/permissions/monitor#microsoftinsights
//   https://learn.microsoft.com/azure/azure-monitor/fundamentals/roles-permissions-security#built-in-monitoring-roles

targetScope = 'subscription'

@description('Diagnostic setting name')
param settingName string = 'ga-activity-to-law-shared'

@description('Resource group of the shared Log Analytics workspace (D-011)')
param sharedResourceGroupName string = 'rg-guardedadvisor-shared'

@description('Shared Log Analytics workspace with Microsoft Sentinel')
param workspaceName string = 'ga-law-shared'

var categories = [
  'Administrative'
  'Security'
  'ServiceHealth'
  'Alert'
  'Recommendation'
  'Policy'
  'Autoscale'
  'ResourceHealth'
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
  scope: resourceGroup(sharedResourceGroupName)
}

resource activityToWorkspace 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  properties: {
    workspaceId: workspace.id
    logs: [for c in categories: {
      category: c
      enabled: true
    }]
  }
}

output settingId string = activityToWorkspace.id
