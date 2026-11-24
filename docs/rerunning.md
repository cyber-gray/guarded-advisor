# Rerunning the lab safely

Moved from the README of the working repository (2026-11-24). Commands assume the repository root.

- **Cost:**
  - The design estimate is about CAD 230 for three weeks ([`docs/cost-estimate.md`](cost-estimate.md), generated from the Azure Retail Prices API).
  - **Actual spend (Cost Management, actual cost):** October 2026, both lab groups: CAD 111.02 (read 2026-11-15). November 2026 to teardown, month to date at about 18:12Z on 2026-11-18: lab group CAD 128.51, shared monitoring group CAD 1.43.
  - **What bills by the hour:** API Management Standard v2 (about CAD 1.36 an hour), AI Search Basic (about CAD 3.43 a day), Bastion with its IP, and the jumpbox (about CAD 0.35 an hour together).
  - Create a budget first (`scripts/create-budget.sh`). A budget warns; it doesn't stop spending.
- **Privileged access:**
  - The lab account (**T**) holds Reader standing and activates Owner through Privileged Identity Management only for a change.
  - Protected log tables need a separate, PIM-eligible data role.
  - A guest Global Administrator (**G**) handles Entra changes, and an emergency access account (**E**) is excluded from Conditional Access.
  - Every change is its own approval; read-only checks are batched.
- **Order:** prerequisites and region checks, provider registration, policy assignments (at least 15 minutes before any deploy), then `infra/main.bicep`. Day 0 runbook: [`docs/day0.md`](day0.md). Portal-only steps: [`docs/runbook.md`](runbook.md).
- **Teardown:**
  - **End of every session:** `scripts/teardown.sh session` removes API Management (with purge), Bastion and its IP, and deallocates the jumpbox. The auto-shutdown doesn't remove Bastion.
  - **At the end:** `FINAL=1 scripts/teardown.sh all` removes the lab group. The shared monitoring group goes last.
- **Secrets:** none in the repository. Managed identities are used throughout, and Cosmos DB, AI Search and Foundry keys are disabled. A pre-commit hook runs gitleaks.


## Repository layout

```
README.md                executive summary
docs/                    architecture, threat model, control matrix, findings, cost, runbooks, evidence
scenarios/larkfield/     scenario pack 1: intake record, model inventory, synthetic data, attacks, bias pairs
agent/                   case assistant client, entitlement tool, decision checker, data generators, tests
infra/                   Bicep: forked Foundry private-network setup, APIM, Sentinel, policies, sandbox
redteam/                 gateway harness, decision-check eval, bias test, ground-truth logger
detections/              Sentinel rule D5 and the C8 agree/override query
scripts/                 checks, deploy, teardown, read-only evidence capture
```


## Before a rerun: regenerate the canary

The public copy plants `LARK-CANARY-REDACTED` in claim `LM-CLM-2026-0007`. Before any rerun, set `GA_CANARY` to a new private value (8 to 64 letters, digits or hyphens) and run `python -I agent/generate_data.py`, then `python -I agent/check_data.py`, so the planted value isn't known to anyone who has read this repository.
