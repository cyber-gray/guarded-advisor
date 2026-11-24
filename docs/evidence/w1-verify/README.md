# w1-verify evidence

Read-only checks as T, 2026-11-05. CLI output as masked text. Outside-lab resources are counted, not named.

| File | Shows | Closes |
|---|---|---|
| `01-s4-identify.txt` | The one public IP outside the lab is attached to the outside-lab NAT gateway. Also the older `directoryRoles/{id}/members` call: 0 members for Directory Readers, no error, 18:00:01Z | Plan's Thursday item: identify the public IP outside the lab |
| `02-s4-identify-dr.txt` | The unified RBAC API at 18:03:10Z: 1 active Directory Readers assignment, `Microsoft.Azure.SyncFabric`, first-party owner tenant, scope `/`. `roleEligibilityScheduleInstances` denied, 403, so eligible members are unknown | Plan's Thursday item: identify the Directory Readers service principal |
| `03-w1-residency.txt` | Lab resource groups and all 67 lab resources from `az resource list`: 41 in `canadaeast`, 26 expected global, 0 flagged. Model deployments: both regional Standard. 11 resources outside the lab, counted only | `w1-verify` residency (C5), control plane and deployment SKU |
| `04-w1-residency-replicas.txt` | Storage `Standard_LRS`, no secondary. Cosmos DB in Canada East only, no multi-region writes, Local backups. Key Vault references D-006, no new read | `w1-verify` residency (C5), replica regions |
| `05-verify-residency.txt` | `scripts/verify.sh residency` at code commit `afe3640`: 0 failed, 0 inconclusive. Run 2026-11-05 from the laptop as T (the CLI identity used by the guarded scripts), nothing activated (last read 18:26:44Z, `w1-rbac/02`). `verify.sh` prints no timestamp or identity; the exit status line was recorded separately | `w1-verify` residency (C5), the repeatable check |

The Entra data location is in `docs/evidence/w2-pim/97-g17-elevation-toggle-no.png` (United States datacenters).
