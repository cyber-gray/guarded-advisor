// Foundry guardrail for the case assistant (w2-guardrails, C3). rg-guardedadvisor-lab, account ga-ai-labv3do.
// A guardrail is an RAI policy on the account, assigned to a model deployment through raiPolicyName. An agent with no
// guardrail of its own inherits its deployment's (create_agent.py sets no rai_config, so the agent inherits this one).
// Learn, checked 2026-11-11 (the Learn connector shows no updated dates):
// - Guardrail = RAI policy; assign with raiPolicyName on the deployment:
//   https://learn.microsoft.com/azure/foundry/guardrails/how-to-create-guardrails#configure-guardrails-with-the-rest-api
// - Agents inherit the deployment's guardrail unless one is assigned to the agent:
//   https://learn.microsoft.com/azure/foundry/guardrails/guardrails-overview#default-guardrails
// - Resource type: https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/raipolicies
//   API 2025-12-01 (GA): the newest version the local Bicep CLI has types for, so properties are validated at build.
//   2026-09-01 (GA) adds tool-call sources and an action field that this policy doesn't use.
// - Filter names (Hate, Sexual, Violence, Selfharm, Jailbreak, Indirect Attack, Protected Material Text/Code):
//   https://learn.microsoft.com/azure/foundry-classic/foundry-models/how-to/configure-content-filters?pivots=programming-language-bicep
// - Regional deployments keep guardrail processing in-region (C5):
//   https://learn.microsoft.com/azure/ai-services/content-safety/region-availability#guardrails-in-foundry
// - Guardrails moderate the first 1000 characters of text:
//   https://learn.microsoft.com/azure/ai-services/content-safety/region-availability#service-limits
// Not configured, on purpose:
// - Spotlighting: preview, Chat Completions API only, and not yet supported for agents; a guardrail that relies on it
//   may not apply to the agent at all.
//   https://learn.microsoft.com/azure/foundry/openai/concepts/content-filter-prompt-shields#spotlighting-preview
//   https://learn.microsoft.com/azure/foundry/guardrails/guardrails-overview#default-guardrails (troubleshooting)
// - Tool-response controls: preview, and they run only for listed tools (Azure AI Search, Azure Functions, OpenAPI,
//   SharePoint, Fabric Data Agent, Bing, Bing Custom Search, Browser Automation). File Search and client-side function
//   tools aren't listed. https://learn.microsoft.com/azure/foundry/guardrails/intervention-points#supported-tools
// - Groundedness: preview; not in scope for C3. Task Adherence: not used (D-006).

targetScope = 'resourceGroup'

@description('Foundry account that holds the deployment')
param accountName string = 'ga-ai-labv3do'

@description('Guardrail (RAI policy) name. Pattern ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')
param policyName string = 'ga-c3-guardrail-lab'

// The deployment is redeclared with every property it has today (read 2026-11-11T04:23:05Z), so the only intended
// change is raiPolicyName. A PUT replaces the deployment's properties, so a value left out here could change.
param deploymentName string = 'gpt-4.1-mini'
param modelFormat string = 'OpenAI'
param modelVersion string = '2025-04-14'
param skuName string = 'Standard'
param skuCapacity int = 30

param tags object = {}

resource account 'Microsoft.CognitiveServices/accounts@2025-12-01' existing = {
  name: accountName
}

resource guardrail 'Microsoft.CognitiveServices/accounts/raiPolicies@2025-12-01' = {
  parent: account
  name: policyName
  tags: tags
  properties: {
    // Synchronous filtering (the default), not Asynchronous_filter: output is checked before it's returned.
    // https://learn.microsoft.com/azure/foundry/openai/concepts/content-streaming#asynchronous-filtering-for-chat-completions
    mode: 'Default'
    basePolicyName: 'Microsoft.DefaultV2'
    contentFilters: [
      // Harm categories at the DefaultV2 level, Medium: blocks medium and high severity, on prompts and completions.
      // Stricter (Low) not chosen: case files describe injuries, burnout and mental health, and Learn says a higher
      // blocking level raises false positives on legitimate content. Medium is measured first (A4 benign control).
      // https://learn.microsoft.com/azure/foundry/guardrails/default-safety-policies#defaultv2-settings
      // https://learn.microsoft.com/azure/foundry/guardrails/how-to-create-guardrails#best-practices
      { name: 'Hate', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Sexual', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Violence', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Selfharm', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Prompt' }
      { name: 'Hate', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Sexual', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Violence', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Selfharm', severityThreshold: 'Medium', blocking: true, enabled: true, source: 'Completion' }
      // User prompt attack (jailbreak): on and blocking at user input, as in DefaultV2.
      // https://learn.microsoft.com/azure/ai-services/content-safety/concepts/jailbreak-detection
      { name: 'Jailbreak', blocking: true, enabled: true, source: 'Prompt' }
      // Document (indirect) attack: off in DefaultV2, on and blocking here. At user input it scans only content inside
      // the <documents> delimiter.
      // https://learn.microsoft.com/azure/foundry/guardrails/how-to-create-guardrails#embedding-documents-in-your-prompt
      { name: 'Indirect Attack', blocking: true, enabled: true, source: 'Prompt' }
      // Protected material as in DefaultV2: text blocking, code annotate only (Learn's Bicep sample).
      { name: 'Protected Material Text', blocking: true, enabled: true, source: 'Completion' }
      { name: 'Protected Material Code', blocking: false, enabled: true, source: 'Completion' }
    ]
  }
}

// Assign the guardrail to the chat deployment. The embedding deployment keeps Microsoft.DefaultV2.
// https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/deployments
resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-12-01' = {
  parent: account
  name: deploymentName
  tags: tags
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    model: {
      format: modelFormat
      name: deploymentName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade' // as in ai-account-identity.bicep (C5, model inventory)
    // Pinned so a PUT can't pause it: deploymentState is writable ('Paused' or 'Running') and the 2026-11-11 what-if
    // showed it as removed when left out.
    // https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2025-12-01/accounts/deployments#deploymentproperties
    deploymentState: 'Running'
    raiPolicyName: guardrail.name
  }
}

output guardrailId string = guardrail.id
