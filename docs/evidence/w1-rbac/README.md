# w1-rbac evidence

Read-only checks as T, 2026-11-05, for `docs/rbac-review.md`. CLI output as masked text. Outside-lab scopes are counted, not named.

| File | Shows | Used for |
|---|---|---|
| `01-w1-rbac-review.txt` | 16 assignments visible to T. Owner, Contributor and User Access Administrator 0; T's 6 as the positive control. Identity and Cosmos DB data-plane roles, with R numbers. **Its "T4 rows: 0" line is only half valid:** the filter's project name was wrong, so the identities table is the T4 evidence | The identity table and checks |
| `02-w1-rbac-detail.txt` | The Storage Blob Data Owner condition; AI Search and Cosmos DB `disableLocalAuth` true; the Cosmos DB Operator and Search Service Contributor definitions; the 3 outside-lab rows aren't log roles and no lab identity holds them | The storage finding; key access; T4 |
| `03-w1-rbac-containers.txt` | 22 containers in `gaailabv3dost`: 1 agent, 1 blobstore, 20 neither. Control plane, names only. **Labelled edit:** a 12-hex segment in the agent container name was masked after capture, as `f0e1...bcde` | The storage finding |
| `04-t-entra-eligible-roles.png` | PIM > My roles > Microsoft Entra roles > Eligible: Security Reader, Default Directory, Direct, Permanent. The account bar is masked | T's Entra eligibility in the review |
| `05-t-entra-active-roles.png` | PIM > My roles > Microsoft Entra roles > Active assignments: No results. The account bar is masked | T has no active Entra role, in the review |
| `06-containers-use.txt` | Container metadata via ARM (22 live, none soft-deleted; the 20 `ga-ai-labv-<id>` all last modified 2026-10-22 15:42:22Z to 15:43:03Z), the name pattern (all 20 are GUIDs; 0 matches to 14 IDs from the account, project, AI Search, capability hosts and project identity), and the first part 3, which failed with SYN0002 | The storage finding |
| `07-containers-use-logs.txt` | `StorageBlobLogs` aggregate over P30D, 66 rows: per container, operation group, count, last seen and caller class. Its summary lines printed empty (a `jq` bug), so the counts in findings come from the rows. Its classifier labels the `$purview` system container "neither" | The storage finding; the `$purview` entry |
