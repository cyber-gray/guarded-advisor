// Custom tables and Logs Ingestion API path in rg-guardedadvisor-shared (w2-custom, D-022; C2, C4, C6, C8).
// Deployed on its own, not through shared.bicep: redeploying shared.bicep without its alertEmailAddress
// parameter would drop the email receiver from the daily-cap alert.
//
// Two ingestion paths, kept apart on purpose:
// - Agent evidence (AgentToolAudit_CL, AdjudicationLog_CL), written from the jumpbox by its managed identity:
//   a DCR without kind 'Direct' (so it has no public ingestion endpoint of its own) bound to a DCE whose public
//   network access is Disabled. The DCE joins the lab AMPLS (main.bicep, dataCollectionEndpointName), so only
//   the VNet can reach it. "You must use a DCE if you're sending data to a Log Analytics workspace configured
//   for Private Link."
// - Red-team ground truth (RedTeamRun_CL), written from Tooni's laptop: a kind 'Direct' DCR with its own public
//   logsIngestion endpoint. Only this stream is reachable from the internet, and only by its writer.
// Writers get Monitoring Metrics Publisher on their DCR only. Each writer is a separate deploy (empty principal
// ID = no assignment) so each role assignment is its own gate.
//
// Retention principle (D-022): content short, evidence long. These tables hold IDs and codes only, never prompt,
// claim or note content, and keep 90 days. AdjudicationLog_CL is Protected (intake record: adjudicator decisions
// are Highly confidential); protectionLevel exists only from tables api-version 2026-03-01, and redeploying this
// template keeps it set.
//
// Sources:
//   https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
//   https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-endpoint-overview
//   https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table
//   https://learn.microsoft.com/azure/azure-monitor/logs/protected-tables-configure
//   https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#monitoring-metrics-publisher

targetScope = 'resourceGroup'

@description('Azure region; must match the workspace (D-006)')
param location string = 'canadaeast'

@description('Shared Log Analytics workspace (infra/shared.bicep)')
param workspaceName string = 'ga-law-shared'

@description('Data collection endpoint for the agent evidence DCR (private only)')
param dceName string = 'ga-dce-shared'

@description('DCR for AgentToolAudit_CL and AdjudicationLog_CL (no public endpoint)')
param agentDcrName string = 'ga-dcr-agent-shared'

@description('DCR for RedTeamRun_CL (kind Direct, public endpoint)')
param redteamDcrName string = 'ga-dcr-redteam-shared'

@description('Interactive and total retention of the evidence tables, in days (D-022)')
@minValue(4)
@maxValue(730)
param evidenceRetentionDays int = 90

@description('Principal (object) ID allowed to write agent evidence: the jumpbox managed identity. Empty = no assignment (R6).')
param agentWriterPrincipalId string = ''

@description('Principal (object) ID allowed to write red-team ground truth: T. Empty = no assignment (R7).')
param redteamWriterPrincipalId string = ''

@description('Tags applied to every resource')
param tags object = {}

// Monitoring Metrics Publisher: DataActions Microsoft.Insights/Telemetry/Write and Metrics/Write. The role the
// Logs Ingestion API documents; no narrower built-in role exists.
var metricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Column sets. Table columns use 'dateTime'; DCR stream columns use 'datetime' (the two APIs spell it differently).
// Names are the generic D-012 fields so detections carry over to other scenario packs.
var auditColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'caller', type: 'string' }
  { name: 'record_id', type: 'string' }
  { name: 'scenario', type: 'string' }
  { name: 'action', type: 'string' }
  { name: 'decision', type: 'string' }
  { name: 'reason', type: 'string' }
  { name: 'conversation_id', type: 'string' }
  { name: 'tool_name', type: 'string' }
  { name: 'redteam_id', type: 'string' }
  { name: 'detail', type: 'dynamic' } // sandbox only: exit_code, duration_ms, egress_blocked; never content
]
var adjudicationColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'caller', type: 'string' }
  { name: 'record_id', type: 'string' }
  { name: 'scenario', type: 'string' }
  { name: 'conversation_id', type: 'string' }
  { name: 'outcome', type: 'string' } // agree | modified | rejected: what the case manager did with the draft
  { name: 'rationale_code', type: 'string' } // fixed codes only, no free text (agent/adjudicate.py)
]
var redteamColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'redteam_id', type: 'string' }
  { name: 'attack_id', type: 'string' }
  { name: 'scenario', type: 'string' }
  { name: 'run_tool', type: 'string' }
  { name: 'technique', type: 'string' }
  { name: 'target', type: 'string' }
  { name: 'expected_control', type: 'string' }
  { name: 'expected_detection', type: 'string' }
  { name: 'caller', type: 'string' }
  { name: 'conversation_id', type: 'string' }
  { name: 'harness_verdict', type: 'string' }
  { name: 'started_at', type: 'datetime' }
  { name: 'ended_at', type: 'datetime' }
  { name: 'payload_sha256', type: 'string' } // hash of the payload file in the repo, not the payload
]

var tableSpecs = [
  { name: 'AgentToolAudit_CL', columns: auditColumns, protection: 'General' }
  { name: 'AdjudicationLog_CL', columns: adjudicationColumns, protection: 'Protected' }
  { name: 'RedTeamRun_CL', columns: redteamColumns, protection: 'General' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

resource tables 'Microsoft.OperationalInsights/workspaces/tables@2026-03-01' = [for t in tableSpecs: {
  parent: workspace
  name: t.name
  properties: {
    plan: 'Analytics'
    protectionLevel: t.protection
    retentionInDays: evidenceRetentionDays
    totalRetentionInDays: evidenceRetentionDays
    schema: {
      name: t.name
      columns: [for c in t.columns: {
        name: c.name
        type: c.type == 'datetime' ? 'dateTime' : c.type
      }]
    }
  }
}]

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    description: 'Private ingestion for agent evidence (w2-custom, D-022). Reachable only through the lab AMPLS.'
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

// No kind 'Direct': this DCR gets no logsIngestion endpoint and is reachable only through the DCE above.
// Only declared columns pass the stream, so a client can't add content fields even if it tried.
resource agentDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: agentDcrName
  location: location
  tags: tags
  properties: {
    description: 'AgentToolAudit_CL and AdjudicationLog_CL from the jumpbox (w2-custom, C2, C4, C8)'
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-AgentToolAudit_CL': { columns: auditColumns }
      'Custom-AdjudicationLog_CL': { columns: adjudicationColumns }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'sharedWorkspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-AgentToolAudit_CL']
        destinations: ['sharedWorkspace']
        transformKql: 'source'
        outputStream: 'Custom-AgentToolAudit_CL'
      }
      {
        streams: ['Custom-AdjudicationLog_CL']
        destinations: ['sharedWorkspace']
        transformKql: 'source'
        outputStream: 'Custom-AdjudicationLog_CL'
      }
    ]
  }
  dependsOn: [
    tables
  ]
}

resource redteamDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: redteamDcrName
  location: location
  kind: 'Direct'
  tags: tags
  properties: {
    description: 'RedTeamRun_CL from the red-team harness on Tooni\'s laptop (w2-custom, w3-harness)'
    streamDeclarations: {
      'Custom-RedTeamRun_CL': { columns: redteamColumns }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'sharedWorkspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-RedTeamRun_CL']
        destinations: ['sharedWorkspace']
        transformKql: 'source'
        outputStream: 'Custom-RedTeamRun_CL'
      }
    ]
  }
  dependsOn: [
    tables
  ]
}

// R6: the jumpbox managed identity may write agent evidence, on this DCR only.
resource agentWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(agentWriterPrincipalId)) {
  name: guid(agentDcr.id, agentWriterPrincipalId, metricsPublisherRoleId)
  scope: agentDcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisherRoleId)
    principalId: agentWriterPrincipalId
    principalType: 'ServicePrincipal'
    description: 'w2-custom R6: jumpbox managed identity writes AgentToolAudit_CL and AdjudicationLog_CL (D-022)'
  }
}

// R7: T may write red-team ground truth, on this DCR only.
resource redteamWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(redteamWriterPrincipalId)) {
  name: guid(redteamDcr.id, redteamWriterPrincipalId, metricsPublisherRoleId)
  scope: redteamDcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisherRoleId)
    principalId: redteamWriterPrincipalId
    principalType: 'User'
    description: 'w2-custom R7: red-team harness (T) writes RedTeamRun_CL (D-022)'
  }
}

// Not secrets: clients need the endpoint and the DCR immutable ID; access is decided by the role above.
output dceName string = dce.name
output agentIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output agentDcrImmutableId string = agentDcr.properties.immutableId
output redteamIngestionEndpoint string = redteamDcr.properties.endpoints.logsIngestion
output redteamDcrImmutableId string = redteamDcr.properties.immutableId
