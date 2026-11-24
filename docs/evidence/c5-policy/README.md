# Azure Policy compliance (C5)

Captured 2026-10-27 by Tooni in the Azure portal (Policy), read-only. Finding: `docs/findings.md`, "Azure Policy compliance snapshot". Definition mapping: the decision log, D-017.

Checked before committing: emails, subscription ID and assignment IDs blanked. The subscription display name ("Azure subscription 1") and resource names are visible.

| File | What it shows | Supports |
|---|---|---|
| `01-compliance-overview.png` | Policy compliance: 90% overall (66 of 73); ASC Default non-compliant (7 resources); all 11 "GA:" assignments Compliant | Lab assignments all compliant; the 90% comes from the Defender default initiative |
| `02-allowed-locations-shared.png` | GA: Allowed locations (Canada East) on `rg-guardedadvisor-shared`: built-in Allowed locations, Deny, 6 of 6 compliant; 5 resources in Canada East, the action group Global | C5 for the shared group |
| `03-local-auth-assignment-builtin.png` | GA: AI Services and AI Search must disable key (local) authentication: definition "Azure AI Services resources should have key access disabled..." (built-in), Deny, 3 of 3 compliant (`ga-cs-labv3do`, `ga-ai-labv3do`, `ga-ai-labv3dosearch`) | The local-auth deny uses the built-in definition |
| `04-custom-definitions.png` | Policy definitions filtered to Custom: four "Guarded Advisor:" definitions (two model deployment, two Cognitive Services) | Four custom definitions exist; three are assigned (D-017) |
| `05-allowed-locations-lab.png` | GA: Allowed locations (Canada East) on `rg-guardedadvisor-lab`: Deny, 60 of 60 compliant; the first 12 rows shown, with the Failure Anomalies alert rule and the Smart Detection action group as Global | C5 for the lab group (full location count by CLI in the finding) |
| `06-whatif-lab-unpinned.txt` | 2026-10-29 lab what-if before pinning, adding `ga-deny-cosmos-local-auth` (built-in `5450f5bd`, Deny): 1 create, **10 modify**, 61 ignore. Each Modify removes `properties.definitionVersion` (`3.*.*` on `ga-deny-ai-network`, `1.*.*` on the rest). The run printed to the terminal only, so this file is reconstructed from this session's terminal output, not a raw capture (the Ignore list is the same 61 resources as 07) | The Bicep didn't pin `definitionVersion`; the service had set it by default, so a redeploy could move an assignment to a new major version unreviewed |
| `07-whatif-lab-pinned.txt` | Lab what-if after pinning `definitionVersion` on every assignment: 1 create (`ga-deny-cosmos-local-auth`, `definitionVersion` `1.*.*`), 10 no change, 61 ignore | Pinning matches the live assignments; only the new Cosmos assignment is created |
| `08-whatif-shared-pinned.txt` | Shared what-if after pinning: `ga-allowed-locations` no change, 6 ignore | The shared locations assignment (same Bicep object) is unaffected |
| `09-readback-cosmos-assignment.txt` | `az policy assignment show` for `ga-deny-cosmos-local-auth` after the lab deploy (2026-10-29), scope masked: effect Deny, `definitionVersion` `1.*.*`, `enforcementMode` Default, definition `5450f5bd-9c72-4390-a9c4-a7aba4edfdd2`, scope `rg-guardedadvisor-lab` | The 12th GA assignment is live as written |
| `10-readback-lab-assignments.txt` | `az policy assignment list` on the lab group (resource-group scope only): 11 assignments, all Deny and Default, `definitionVersion` `3.*.*` on `ga-deny-ai-network` and `1.*.*` on the other 10 | Every lab assignment carries its pinned major after the deploy |
| `11-compliance-cosmos.txt` | `az policy state list` on the lab group for `ga-deny-cosmos-local-auth`, after `az policy state trigger-scan --no-wait` at 21:20:40Z: `ga-ai-labv3docosmosdb` Compliant, timestamp 2026-10-29T21:21:54Z, definition version 1.2.0 | The claim store's account meets the new Deny assignment |

**Masked 2026-11-02:** the private endpoint NIC name suffixes in `06` and `07` are cut to first 4 and last 4 (redaction pass; the what-if output is otherwise as printed).
