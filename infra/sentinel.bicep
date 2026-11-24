// Microsoft Sentinel on ga-law-shared (w2-sentinel) and the D5 analytics rule (w3-kql, C2).
// rg-guardedadvisor-shared (D-011). Separate from shared.bicep: the workspace, its retention and its cap are not touched.
// onboardingStates and alertRules are extension resources on the workspace; neither takes tags.
// Learn, checked 2026-11-09:
// - alertRules 2025-09-01, kind Scheduled: https://learn.microsoft.com/azure/templates/microsoft.securityinsights/2025-09-01/alertrules
// - onboardingStates: https://learn.microsoft.com/azure/templates/microsoft.securityinsights/onboardingstates
// - interval and lookback 5 minutes to 14 days: https://learn.microsoft.com/azure/sentinel/scheduled-rules-overview#analytics-rule-configuration
// - ingestion delay: https://learn.microsoft.com/azure/sentinel/ingestion-delay#how-to-handle-delay

targetScope = 'resourceGroup'

@description('Log Analytics workspace to enable Microsoft Sentinel on')
param workspaceName string = 'ga-law-shared'

@description('Create the D5 rule. false = onboarding only.')
param deployD5 bool = true

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2025-09-01' = {
  name: 'default'
  scope: workspace
  properties: {
    customerManagedKey: false
  }
}

// D5 (docs/threat-model.md, Detection rules): two or more deny decisions for one caller in one conversation_id.
resource d5 'Microsoft.SecurityInsights/alertRules@2025-09-01' = if (deployD5) {
  name: guid(workspace.id, 'ga-d5-entitlement-denials')
  scope: workspace
  kind: 'Scheduled'
  dependsOn: [sentinel]
  properties: {
    displayName: 'D5: two or more entitlement denials in one session'
    description: 'C2: two or more decision == deny for one caller in one conversation_id in AgentToolAudit_CL. Query: detections/d5-entitlement-denials.kql.'
    enabled: true
    query: loadTextContent('../detections/d5-entitlement-denials.kql')
    queryFrequency: 'PT5M' // must equal rule_frequency in the KQL (agent/tests/test_d5_detection.py)
    queryPeriod: 'PT1H' // must equal session_window in the KQL (same test)
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    severity: 'Medium'
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult' // one alert per caller and conversation
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          { identifier: 'AadUserId', columnName: 'caller' }
        ]
      }
    ]
    customDetails: {
      ConversationId: 'conversation_id'
      RedTeamId: 'redteam_id'
    }
    // Suppression pauses the whole rule after it fires, which would hide a second session: off.
    suppressionEnabled: false
    suppressionDuration: 'PT5H' // required by the schema even when suppression is off
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        matchingMethod: 'Selected'
        groupByEntities: ['Account']
        groupByCustomDetails: ['ConversationId']
        lookbackDuration: 'PT5H'
        reopenClosedIncident: false // not available when Sentinel is in the Defender portal
      }
    }
  }
}

output d5RuleId string = deployD5 ? d5.id : ''
