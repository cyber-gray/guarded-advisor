# Guarded Advisor

An AI governance and AI security lab on Microsoft Azure, built by [Tooni Temowo](https://www.linkedin.com/in/tooni-temowo/).

## What this is

Larkfield Mutual is a fictional Canadian group benefits insurer. Its disability case managers each carry more than 150 files, and members on leave wait weeks for a return-to-work plan. The proposal: an AI assistant that reads claim files and plan wording and drafts return-to-work notes for case managers, but never decides a claim. This lab takes that proposal through the steps a regulated insurer would follow. It goes through an intake and risk review that sets eight conditions for launch. It's built on Microsoft Foundry Agent Service in a private network. Then it's attacked on purpose, and a gate decision is made on what the tests actually showed. Passes and failures are both published here.

## Why it matters

An AI agent isn't only a chat window. It reads documents that other people wrote, it calls tools, and it acts under an identity that can reach data. That moves the security question from "what might the model say?" to "what can the agent reach, and who decides?".

The familiar controls still apply: identity, network isolation, logging, change control. But they meet new problems. Instructions can be hidden in a document the agent reads. The agent can write code and ask to run it. A draft can read like a decision. In claims work the attacker writes part of the input, because members and providers upload the documents. This lab measures where the controls held and where they didn't.

## The verdict

**Not approved, with a remediation and retest plan** (decided 2026-11-20).

The gate did what a launch gate is for: it held the launch until the evidence supports it. Of the eight launch conditions, two are partly met and six need remediation before a retest. Three of those six are launch blockers by design: the assistant must never decide a claim (C1), case managers see only their own claims (C2), and agent-written code runs isolated (C4). Each has a remediation path and a retest trigger in the [gate decision](scenarios/larkfield/gate-decision.md).

Many layers held. The claim tool checked permissions in code, so every attempt to read another case manager's claim was refused, and Microsoft Sentinel raised an alert on the repeats. The agent had no tool that could change a claim. Protected log tables returned nothing to readers without the data role. A planted test secret never appeared in an answer. Every draft carried its "AI-generated, not a decision" label.

## Layers of defence: what held, and where the next layer mattered

No single control is meant to stop everything. The lab stacked layers (identity, network, content filtering, application logic, detection and human review), then tested each one on purpose. One pattern repeats: a layer held, a neighbouring layer had a gap, and the design stayed safe where another layer backed it up.

1. **Identity: the tool's check held; the server's own identity was broader.** The claim tool refused every request for another case manager's claim, and Sentinel flagged the repeats. Underneath, the server hosting the tool had its own identity that could read every claim directly, and the database didn't record which person each read was for.
   *Takeaway:* an authorization check is only as strong as the identity it runs under. Give the tool its own service identity, and make every read traceable to a person.

2. **Content filtering: a strong first layer, not the only one.** Prompt Shields in Microsoft Foundry blocked a direct jailbreak. An instruction hidden in a doctor's note, when lightly disguised, got past both Prompt Shields and the content safety check in Azure API Management. It still couldn't approve a claim, because the agent had no tool that could.
   *Takeaway:* filters cut the noise; design is the backstop. If injected text has nothing dangerous to trigger, a missed filter isn't a breach.

3. **Sandboxing: test before you trust.** The Azure Container Apps sandbox, set to deny outbound traffic, blocked and logged web traffic. A raw network connection still got out unlogged, and the sandbox still offered a way to request an access token. Because this surfaced before launch, the code tool was held back and never given to the agent.
   *Takeaway:* a setting's name describes intent; a probe shows what it enforces, especially on a new service.

4. **Output checks: wording filters help; capability limits decide.** Filters meant to keep the assistant from stating a claim decision missed three phrasings over two days, and a model-based checker still misses one adversarial case. Every draft kept its "not a decision" label, and a person makes every decision.
   *Takeaway:* language filters leak at the edges. Put the hard guarantee in what the agent can do.

5. **Fairness testing: small tests surface real signals.** In a paired test where only a member's name changed, one of 20 pairs got a different recommended next step, and four pairs returned incomplete results.
   *Takeaway:* run paired tests before launch, and treat an incomplete result as something to explain, not a row to skip.

6. **Detection: a blocked attack should still be seen.** Prompt Shields blocked the jailbreak, which is the outcome you want. But the application wrote no audit record of the block, and no Microsoft Defender for AI Services alert appeared, so a defender watching the dashboards wouldn't have known it happened.
   *Takeaway:* prove the alert path end to end with a known test event. Silence means "safe" only once you've seen the alarm ring.

## Lessons that travel

- **Check the logger is on before trusting a zero.** Audit logging had never been switched on in the trial tenant, so a planned "no results" check would have looked like an all-clear. ([finding](docs/findings.md#purview-audit-was-never-recording-in-this-tenant-so-the-planned-w2-dspm-zero-would-have-been-a-false-negative-w2-dspm-c5-c6-2026-11-17-to-11-18))
- **Confirm the plan, not just the setting.** After the Defender for AI Services plan was turned off, the AI resource's own Defender setting still read "Enabled". ([finding](docs/findings.md#the-resource-level-defender-for-ai-setting-outlives-the-plan-defenderforaisettings-still-read-enabled-after-the-plan-went-to-free-w2-defender-w3-teardown-2026-11-18))
- **Rehearse the way back in.** With no one holding a write role, the recovery path was tested for real with a one-hour, least-privilege role instead of Owner. ([finding](docs/findings.md#the-documented-recovery-path-works-after-the-last-owner-eligibility-expires-g-elevated-at-root-granted-a-1-hour-least-privilege-role-and-removed-the-elevation-w3-teardown-w2-pim-d-048-d-052-2026-11-18))

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

## Data

All data is synthetic. Larkfield Mutual and its case managers, members, claims and documents are made up, generated by scripts in `agent/`. Nothing here comes from any employer or client. Identifiers in documents and screenshots are masked, and the lab's admin, guest administrator and emergency access accounts appear only as T, G and E. Regulatory references are the lab's interpretation, not legal advice.

## Credits and license

Built by [Tooni Temowo](https://www.linkedin.com/in/tooni-temowo/).

The private-network Foundry infrastructure is based on Microsoft's [`15-private-network-standard-agent-setup`](https://github.com/microsoft-foundry/foundry-samples/tree/dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) sample from microsoft-foundry/foundry-samples (MIT License). The upstream files are `infra/main.bicep`, the 25 modules in `infra/modules-network-secured/` and the 4 tools in `infra/upstream-tools/`. They're listed one by one, with every change made to them, in [`infra/UPSTREAM.md`](infra/UPSTREAM.md), and the upstream notice is kept in `infra/LICENSE-foundry-samples`.

Licensed under the MIT License ([`LICENSE`](LICENSE)). Third-party material, including the OWASP content used in the threat model under CC BY-SA 4.0, is listed in [`NOTICE`](NOTICE).
