# Guarded Advisor

An AI claims assistant for a fictional insurer, approved through a governance gate, built in a private Azure network, then attacked on purpose to measure what each control caught.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/layers-of-defence-dark.svg">
  <img src="docs/images/layers-of-defence.svg" alt="Layers of defence around an AI agent: requests and member documents pass through identity, network, content filters, agent tools, the sandbox and human review, with detection and audit across every layer. Colour shows the lens: Cybersecurity, IAM, GRC or AI Security." width="100%">
</picture>

---

## What this is

- Larkfield Mutual is a fictional Canadian group benefits insurer. Its disability case managers each carry more than 150 files, and members on leave wait weeks for a return-to-work plan.
- The proposal is an AI assistant that reads claim files and plan wording and drafts return-to-work notes for case managers. It **never decides a claim**.
- The lab takes the proposal through the steps a regulated insurer would follow: an intake and risk review that sets eight launch conditions, a build on Microsoft Foundry Agent Service in a private network, attacks on purpose, and a gate decision on what the tests showed. Passes and failures are both published.

---

## Why it matters

An AI agent reads documents other people wrote, calls tools, and acts under an identity that can reach data, so the question moves from "what might the model say?" to "what can the agent reach, and who decides?". In claims work the attacker writes part of the input, because members and providers upload the documents. The familiar controls still apply, and this lab measures where they held and where they didn't.

---

## Four lenses

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/four-lenses-dark.svg">
  <img src="docs/images/four-lenses.svg" alt="Four lenses (IAM, Cybersecurity, AI Security and GRC) with each finding placed where two lenses meet, for example IAM and Cybersecurity: the tool's check held, but the server's own identity reached further." width="100%">
</picture>

AI agent risk doesn't sit with one team. The gaps appear between the teams, and seeing them takes all four views.

### Cybersecurity

*Covers:* network isolation, the AI gateway, attack cases and detection.

- Foundry, Azure Cosmos DB, Azure AI Search and Storage behind private endpoints with public access off.
- API Management as an AI gateway during test windows, and a jumpbox reached through Azure Bastion.
- A fixed set of attack cases, with expected results written down before each run.
- Detection rules and an incident in Microsoft Sentinel.

**Result:** Sentinel alerted on repeated refused claim requests, but a blocked jailbreak left no audit record and no Defender for AI Services alert.

### IAM

*Covers:* which identities can reach data, and how access is granted and taken back.

- Managed identities instead of keys, and per-caller entitlement by identity.
- Owner only through Microsoft Entra Privileged Identity Management, with no standing write roles.
- Report-only Conditional Access, and a Temporary Access Pass scoped and then disabled.
- A recovery path tested with the least privilege that worked.

**Result:** The tool's per-caller check held every time, but the server's own identity could read every claim directly.

### GRC

*Covers:* approval before the build, evidence, and the launch decision.

- An intake and risk rating before anything was built, mapped to OSFI Guideline E-23 and B-10, PIPEDA and Québec's Law 25.
- A model inventory entry and a decision log.
- Every condition tied to a control and a test, with expected results written down before each test.
- A gate decision on a four-tier scale.

**Result:** Not approved, with a remediation and retest plan: two of eight conditions are partly met and six need remediation.

### AI Security

*Covers:* prompts, tools and what the model says.

- A threat model on the OWASP Top 10 for LLM Applications 2026.
- Indirect prompt injection through member documents, and a planted canary.
- A decision checker on the output, and a paired bias test.
- Code execution held back until its sandbox is proven.

**Result:** A lightly disguised injection got past both content filters but had no tool to act on, and the canary never appeared in an answer.

---

## Layers of defence

No single control is meant to stop everything. The lab stacked layers and tested each one on purpose.

| Layer | What held | Where the next layer mattered | Takeaway | Lens |
|---|---|---|---|---|
| Identity | The claim tool refused every request for another case manager's claim, and Sentinel flagged the repeats. | The server's own identity could read every claim directly, and the database didn't record which person each read was for. | A check is only as strong as the identity it runs under. Give the tool its own identity and trace every read to a person. | IAM × Cybersecurity |
| Content filtering | Prompt Shields blocked a direct jailbreak. | A lightly disguised instruction in a doctor's note got past Prompt Shields and the API Management check. The agent had no tool that could approve a claim. | Filters cut the noise; design is the backstop. | Cybersecurity × AI Security |
| Sandboxing | With outbound traffic set to deny, web traffic was blocked and logged. | A raw network connection got out unlogged, and the sandbox still offered a way to request a token. The code tool was held back from the agent. | A setting's name describes intent; a probe shows what it enforces. | Cybersecurity × AI Security |
| Output checks | Every draft kept its "not a decision" label, and a person makes every decision. | Wording filters missed three phrasings over two days, and the model-based checker still misses one adversarial case. | Put the hard guarantee in what the agent can do. | AI Security × GRC |
| Fairness testing | A small paired test surfaced a real signal before launch. | One of 20 pairs got a different next step when only the member's name changed, and four pairs returned incomplete results. | Run paired tests before launch, and explain every incomplete result. | AI Security × GRC |
| Detection | Prompt Shields blocked the jailbreak. | The application wrote no audit record and Defender for AI Services raised no alert, so a defender wouldn't have known. | Prove the alert path end to end with a known test event. | Cybersecurity × GRC |

---

## Proof from the lab

<a href="docs/evidence/w4-wed/"><img src="docs/images/proof-refused-then-detected.png" alt="Two panels. Panel 1, refused in code: the case assistant declines to summarise claims LM-CLM-2026-0002 and LM-CLM-2026-0005 because both are outside the caller's caseload. Panel 2, detected in Sentinel: the D5 alert, two or more entitlement denials in one session, for synthetic case manager Birch, with a deny count of 2." width="100%"></a>

*The tool refused claims outside the caseload, and Sentinel raised the D5 alert on repeated denials. Two layers, same attack.*

Sources: panel 1 is [`w4-wed`](docs/evidence/w4-wed/) 07 (run `c2model-20261111-M4`); panel 2 is [`w3-incident`](docs/evidence/w3-incident/), the D5 incident on the 11-13 rerun of the same attack (`c2model-20261113-M4`). Both runs raised D5.

<a href="docs/evidence/w4-wed/"><img src="docs/images/proof-foundry-operations.png" alt="Foundry Operations view for 2026-10-18 to 2026-11-18: 295 agent runs, 331 model requests, 75 tool calls and 580.6K tokens, with a chart of daily agent runs." width="100%"></a>

*One month of operations in Foundry.*

Source: [`w4-wed`](docs/evidence/w4-wed/) 11.

---

## Start here, by role

- Leaders: [gate decision](scenarios/larkfield/gate-decision.md), [key decisions](docs/key-decisions.md), [intake record](scenarios/larkfield/intake-record.md) and [model inventory](scenarios/larkfield/model-inventory.md).
- Security engineers: [findings](docs/findings.md), [threat model](docs/threat-model.md), [control matrix](docs/control-matrix.md) and the [evidence index](docs/evidence/) (screenshots and outputs, one folder per test).
- Builders: [runbook](docs/runbook.md) and [rerunning the lab](docs/rerunning.md).

---

## The verdict

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/gate-decision-scale-dark.svg">
  <img src="docs/images/gate-decision-scale.svg" alt="Gate decision scale with four outcomes: approved; approved with conditions; not approved, with a remediation and retest plan (selected, decided 2026-11-20); not approved." width="100%">
</picture>

**Not approved, with a remediation and retest plan** (decided 2026-11-20). Of the eight launch conditions, two are partly met and six need remediation before a retest, and three of those six block launch by design: the assistant never decides a claim (C1), case managers see only their own claims (C2), and agent-written code runs isolated (C4). Each has a remediation path and a retest trigger in the [gate decision](scenarios/larkfield/gate-decision.md).

---

## Data

All data is synthetic. Larkfield Mutual and its case managers, members, claims and documents are made up, generated by scripts in `agent/`. Nothing here comes from any employer or client. Identifiers in documents and screenshots are masked, and the lab's admin, guest administrator and emergency access accounts appear only as T, G and E. Regulatory references are the lab's interpretation, not legal advice.

---

## Credits and license

Built by [Tooni Temowo](https://www.linkedin.com/in/tooni-temowo/).

The private-network Foundry infrastructure is based on Microsoft's [`15-private-network-standard-agent-setup`](https://github.com/microsoft-foundry/foundry-samples/tree/dd8ed7fe05bc69f4448a1759b56c3ee1d91a1f45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup) sample from microsoft-foundry/foundry-samples (MIT License). The upstream files are `infra/main.bicep`, the 25 modules in `infra/modules-network-secured/` and the 4 tools in `infra/upstream-tools/`. They're listed one by one, with every change made to them, in [`infra/UPSTREAM.md`](infra/UPSTREAM.md), and the upstream notice is kept in `infra/LICENSE-foundry-samples`.

Licensed under the MIT License ([`LICENSE`](LICENSE)). Third-party material, including the OWASP content used in the threat model under CC BY-SA 4.0, is listed in [`NOTICE`](NOTICE).
