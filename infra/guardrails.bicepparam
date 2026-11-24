using './guardrails.bicep'

// rg-guardedadvisor-lab (w2-guardrails, C3). Deployment values match the live gpt-4.1-mini deployment
// (read 2026-11-11T04:23:05Z) and main.bicepparam.
param accountName = 'ga-ai-labv3do'
param policyName = 'ga-c3-guardrail-lab'
param deploymentName = 'gpt-4.1-mini'
param modelFormat = 'OpenAI'
param modelVersion = '2025-04-14'
param skuName = 'Standard'
param skuCapacity = 30

param tags = {
  project: 'guarded-advisor'
  env: 'lab'
  owner: 'tooni'
  managedBy: 'bicep'
  expires: '2026-11-15'
}
