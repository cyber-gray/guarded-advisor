# Guarded Advisor

An AI governance and AI security lab on Microsoft Azure, built by [Tooni Temowo](https://www.linkedin.com/in/tooni-temowo/).

## What this is

Larkfield Mutual is a fictional Canadian group benefits insurer. Its disability case managers each carry more than 150 files, and members on leave wait weeks for a return-to-work plan. The proposal: an AI assistant that reads claim files and plan wording and drafts return-to-work notes for case managers, but never decides a claim. This lab takes that proposal through the steps a regulated insurer would follow. It goes through an intake and risk review that sets eight conditions for launch. It's built on Microsoft Foundry Agent Service in a private network. Then it's attacked on purpose, and a gate decision is made on what the tests actually showed. Passes and failures are both published here.

## Why it matters

An AI agent isn't only a chat window. It reads documents that other people wrote, it calls tools, and it acts under an identity that can reach data. That moves the security question from "what might the model say?" to "what can the agent reach, and who decides?".

The familiar controls still apply: identity, network isolation, logging, change control. But they meet new problems. Instructions can be hidden in a document the agent reads. The agent can write code and ask to run it. A draft can read like a decision. In claims work the attacker writes part of the input, because members and providers upload the documents. This lab measures where the controls held and where they didn't.

## The verdict

The gate has four possible outcomes: approved; approved with conditions; not approved, with a remediation and retest plan; not approved.

**Not approved, with a remediation and retest plan** (decided 2026-11-20). Of the eight conditions, six failed and two were partial. Three of the failures block launch on their own: the assistant must never decide a claim (C1), case managers see only their own claims (C2), and agent-written code is isolated (C4). Each failed condition has a remediation path and a retest trigger in the [gate decision](scenarios/larkfield/gate-decision.md).

Some things worked well. The tool that returns claims checked permissions in code, so every attempt to read another case manager's claim was refused, and Microsoft Sentinel raised an alert on the repeats. The agent had no tool that could change a claim. Protected log tables returned nothing to readers without the data role. A planted test secret never appeared in an answer. Every draft carried its "AI-generated, not a decision" label. Even so, in a review of 10 drafts, one had a material factual error.

## What we found

1. **The permission check held, but the server it ran on didn't.** The claim tool refused other case managers' claims every time. But the server's own identity could read every claim directly, and the database logged the tool's own reads with no identity attached.
   *If you're deploying AI agents:* authorization inside a tool is only as strong as the identity the tool runs under. Give the tool its own service identity that no person's session shares, and make sure every read can be traced to a caller.

2. **An instruction hidden in a doctor's note got past both content filters.** A note with an injected "approve this claim" passed Prompt Shields in Microsoft Foundry and the content safety check in Azure API Management when the hidden instruction was lightly disguised.
   *If you're deploying AI agents:* treat injection filters as one layer, not the defence. Design so that injected text has nothing dangerous to trigger: no write tools, and a person who makes the decision.

3. **The code sandbox's "deny" setting didn't stop everything.** In an Azure Container Apps sandbox set to deny outbound traffic with full inspection, web traffic was blocked and logged. A raw network connection still got out, with no log entry, and the sandbox still offered a way to request an access token, even with no identity attached. The agent was never given the code tool.
   *If you're deploying AI agents:* probe a sandbox yourself before an agent runs code in it, especially on a new service. A setting's name is not evidence of what it enforces.

4. **Checks on what the assistant says missed some phrasings.** Filters meant to stop the assistant from stating a claim decision missed three phrasings over two days. A second, model-based checker still misses one adversarial case.
   *If you're deploying AI agents:* filters on natural language leak. Put the hard guarantee in what the agent can do, not only in what it says.

5. **Changing only a member's name changed a recommendation.** In a paired bias test, one of 20 pairs got a different recommended next step when only the name changed, and four pairs returned incomplete results.
   *If you're deploying AI agents:* run paired tests before launch. Even a small set can surface this, and an incomplete result needs a logged reason, not a skip.

6. **A blocked attack left no trace where defenders would look.** Prompt Shields blocked a direct jailbreak on the agent's own path. But the application wrote no audit record, and Microsoft Defender for AI Services raised no alert.
   *If you're deploying AI agents:* prove the alert path end to end with a known event before you trust silence.

## Also notable

- Audit logging was never switched on in the trial tenant, so a planned 'zero results' check would have been a false all-clear. Check the logger is on before trusting a zero. ([finding](docs/findings.md#purview-audit-was-never-recording-in-this-tenant-so-the-planned-w2-dspm-zero-would-have-been-a-false-negative-w2-dspm-c5-c6-2026-11-17-to-11-18))
- After the Defender for AI Services plan was turned off, the AI resource's own Defender setting still read 'Enabled'. A resource setting alone can mislead a reviewer. ([finding](docs/findings.md#the-resource-level-defender-for-ai-setting-outlives-the-plan-defenderforaisettings-still-read-enabled-after-the-plan-went-to-free-w2-defender-w3-teardown-2026-11-18))
- With no one left holding a write role, the recovery path was tested for real, using a one-hour Monitoring Contributor role instead of Owner. ([finding](docs/findings.md#the-documented-recovery-path-works-after-the-last-owner-eligibility-expires-g-elevated-at-root-granted-a-1-hour-least-privilege-role-and-removed-the-elevation-w3-teardown-w2-pim-d-048-d-052-2026-11-18))

## Four lenses

- **Cybersecurity:** Foundry, Azure Cosmos DB, Azure AI Search and Storage behind private endpoints with public access off; API Management as an AI gateway during test windows; a jumpbox reached through Azure Bastion; fixed attack cases; detection rules and an incident in Microsoft Sentinel.
- **IAM:** managed identities instead of keys; Owner only through Microsoft Entra Privileged Identity Management, with no standing write roles; per-caller entitlement by identity; report-only Conditional Access; a Temporary Access Pass scoped and then disabled; a recovery path tested with the least privilege that worked.
- **GRC:** an intake and risk rating before anything was built, mapped to OSFI Guideline E-23 and B-10, PIPEDA and Québec's Law 25; a model inventory entry; every condition tied to a control and a test; expected results written down before each test; a gate decision on a four-tier scale; a decision log.
- **AI Security:** a threat model on the OWASP Top 10 for LLM Applications 2026; indirect prompt injection through member documents; a decision checker on the output; a planted canary; a paired bias test; code execution held back until its sandbox is proven.

## Go deeper

- [Gate decision](scenarios/larkfield/gate-decision.md): results by condition, remediation and retest.
- [Key decisions](docs/key-decisions.md): ten decisions in plain language, and why they matter.
- [Findings](docs/findings.md): start with the summary; limitations and everything not tested are listed there.
- [Control matrix](docs/control-matrix.md): each control with its condition, NIST AI RMF subcategory, SC-500 skill area, evidence and result.
- [Threat model](docs/threat-model.md): the OWASP Top 10 for LLM Applications 2026, mapped to the conditions.
- [Intake record](scenarios/larkfield/intake-record.md) and [model inventory](scenarios/larkfield/model-inventory.md).
- [Runbook](docs/runbook.md) for portal-only steps, and [rerunning the lab](docs/rerunning.md).
- [Evidence](docs/evidence/): one folder per test, each with a README.

Decision numbers like D-045 refer to the lab's internal decision log; [Key decisions](docs/key-decisions.md) summarizes the important ones.

## Cost and teardown

About CAD 241 in Azure spend from mid-October to the teardown (October CAD 111.02; November CAD 129.94), against a design estimate of about CAD 230. Everything was deleted on 2026-11-18, and nothing is deployed.

## Data

All data is synthetic. Larkfield Mutual and its case managers, members, claims and documents are made up, generated by scripts in `agent/`. Nothing here comes from any employer or client. Identifiers in documents and screenshots are masked, and the lab's admin, guest administrator and emergency access accounts appear only as T, G and E. Regulatory references are the lab's interpretation, not legal advice.

## Credits and license

Built by [Tooni Temowo](https://www.linkedin.com/in/tooni-temowo/).

The private-network Foundry infrastructure is based on Microsoft's [`15-private-network-standard-agent-setup`](https://github.com/microsoft-foundry/foundry-samples/tree/dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) sample from microsoft-foundry/foundry-samples (MIT License). The upstream files are `infra/main.bicep`, the 25 modules in `infra/modules-network-secured/` and the 4 tools in `infra/upstream-tools/`. They're listed one by one, with every change made to them, in [`infra/UPSTREAM.md`](infra/UPSTREAM.md), and the upstream notice is kept in `infra/LICENSE-foundry-samples`.

Licensed under the MIT License ([`LICENSE`](LICENSE)). Third-party material, including the OWASP content used in the threat model under CC BY-SA 4.0, is listed in [`NOTICE`](NOTICE).
