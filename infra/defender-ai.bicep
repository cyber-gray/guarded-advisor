// Defender for AI Services, model level only (w2-defender, D-009; C6 records prompt evidence as content capture).
// Subscription scope: a Defender plan is a subscription-level setting, so each deploy (on and off) is its own yes.
// CSPM, Key Vault and Storage plans stay off (not in this template). Pricings don't take tags.
// Learn, checked 2026-11-14 (the Learn connector shows no updated dates):
// - Plan, trial, roles: "Defender for AI Services includes a 30-day free trial, capped at 75 billion tokens scanned.
//   Billing begins if the cap is reached within the 30-day period." To enable at subscription level, Owner at
//   subscription scope: https://learn.microsoft.com/azure/defender-for-cloud/ai-threat-protection#availability
// - Enable steps and components (prompt evidence; data security for AI interactions is a paid Purview feature and stays
//   off; AI model security stays off): https://learn.microsoft.com/azure/defender-for-cloud/ai-onboarding#enable-the-components-of-the-plan
// - Resource and extension name: pricing name "AI"; extension "AIPromptEvidence" ("Available for AI plan"):
//   https://learn.microsoft.com/azure/templates/microsoft.security/2024-01-01/pricings#property-values
// - Agent-level coverage needs Agent 365, which this tenant doesn't have (D-009); this plan covers model calls only.

targetScope = 'subscription'

@description('true: Standard with prompt evidence on. false: back to Free (teardown).')
param planOn bool = true

@description('Include suspicious prompt and response segments in alert evidence (C6 content-capture item)')
param promptEvidence bool = true

resource aiPlan 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'AI'
  properties: planOn ? {
    pricingTier: 'Standard'
    extensions: [
      {
        name: 'AIPromptEvidence'
        isEnabled: promptEvidence ? 'True' : 'False'
      }
    ]
  } : {
    pricingTier: 'Free'
  }
}

output pricingTier string = aiPlan.properties.pricingTier
