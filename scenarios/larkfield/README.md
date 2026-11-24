# Scenario pack 1: Larkfield Mutual claims assistant

Larkfield Mutual is a fictional Canadian group benefits insurer (Ontario and Quebec). The pack holds everything domain-specific about the disability claims case assistant; the platform (`infra/`, [infra/policies/](../../infra/policies/), `detections/`, `redteam/` harness, `scripts/`) stays domain-neutral (D-012). All data is synthetic.

| Item | Location | Status |
|---|---|---|
| Intake and approval record, including the regulatory mapping (OSFI E-23 and B-10, PIPEDA, Law 25 ss. 3.3, 12, 12.1, 17 with the s. 17 flows table) | [intake-record.md](intake-record.md) | Approved with conditions C1 to C8, 2026-10-13 |
| Model inventory entry (LM-AI-001), fallbacks, lifecycle | [model-inventory.md](model-inventory.md) | Complete, 2026-10-13 |
| Synthetic records: claims, internal documents, member-submitted files ([data/README.md](data/README.md): seed, regenerate, check) | `data/` | Generated 2026-10-19 (`w1-data` Part B); `agent/check_data.py` passes |
| Invented name list and provenance (reused for B1) | [names.json](names.json) | 2026-10-19 |
| Entitlement map: case manager Entra object ID (with alias, no UPNs) to assigned claim IDs, read by `get_claim_summary` when `SCENARIO=larkfield` | `entitlements.json` | After the accounts exist (`w1-data` Part A, G7b): `agent/build_entitlements.sh` |
| File payloads A4 and A9 to A12, canary for A6, [manifest](attacks/manifest.json) | `attacks/` | Generated 2026-10-19; run in week 3 |
| Bias pairs B1 and results | `bias/`, `bias-test.md` | `w3-bias` |

**Pack identifiers:** `scenario = larkfield`; `record_id` is a claim ID; `caller` is the case manager's Entra object ID. Detections key only on these generic fields ([docs/threat-model.md](../../docs/threat-model.md), Detection rules).

**New packs** start from [docs/templates/intake-record.md](../../docs/templates/intake-record.md) and [docs/templates/model-inventory.md](../../docs/templates/model-inventory.md), and go through Gate 0 before any build.
