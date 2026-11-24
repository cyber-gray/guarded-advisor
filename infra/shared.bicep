// Shared, long-lived resources in rg-guardedadvisor-shared (w1-law, D-011). Deployed separately from the
// lab stack so lab rebuilds never touch it. Sentinel (w2-sentinel) and the custom tables (w2-custom) are
// added here later.

targetScope = 'resourceGroup'

@description('Azure region (D-006)')
param location string = 'canadaeast'

@description('Log Analytics workspace name')
param workspaceName string = 'ga-law-shared'

@description('Interactive retention in days for the Analytics plan (30 is included at no cost)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily ingestion cap in GB. Collection stops for the rest of the 24-hour period once reached.')
param dailyQuotaGb int = 1

@description('Email for the daily-cap alert. Passed at deploy time, not committed. Empty creates the alert without an email action.')
param alertEmailAddress string = ''

@description('Tags applied to every resource')
param tags object = {}

// Public ingestion and query stay enabled on the workspace (D-011):
// - ingestion: the week 3 red-team harness writes RedTeamRun_CL from Tooni's laptop. Diagnostic settings
//   from Azure resources use a private Microsoft channel and aren't affected by this setting.
// - query: the portal, Sentinel and workbooks run outside the VNet.
// Lab VNet clients reach the workspace through the AMPLS (ingestion PrivateOnly, query Open).
// https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-design
resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource capActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ga-ag-ops-shared'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ga-ops'
    enabled: true
    emailReceivers: empty(alertEmailAddress) ? [] : [
      {
        name: 'tooni-email'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// Daily cap reached: query, frequency and threshold exactly as on
// https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap (Alert when daily cap is reached).
// A cap hit means detections go blind until the reset hour, so it must be visible, not silent.
resource dailyCapAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ga-alert-daily-cap-reached'
  location: location
  tags: tags
  properties: {
    displayName: 'Daily data limit reached (${workspaceName})'
    description: 'Log Analytics daily cap reached: collection is stopped until the workspace reset hour (w1-law, C6).'
    severity: 2
    enabled: true
    scopes: [
      workspace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '_LogOperation | where Category =~ "Ingestion" | where Detail contains "OverQuota"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: false
    actions: {
      actionGroups: [
        capActionGroup.id
      ]
    }
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
