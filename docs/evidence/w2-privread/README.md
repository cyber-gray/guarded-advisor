# w2-privread portal evidence (ga-law-shared)

Captured 2026-10-26 in the Azure portal by Tooni, signed in as T. Privileged Monitoring Data Reader on `ga-law-shared` was PIM eligible, activated for 1 hour, then deactivated. Finding: `docs/findings.md`, "Protected tables don't stop a standing Owner".

Checked before committing: none of these images shows an email address, tenant or directory name, subscription ID or object ID. 08 was cropped to remove the account name.

**01 and 02 don't exist:** no "before" screenshots were taken. 03 and 06 are the with-role and after-deactivation pair.

| File | What it shows | Supports |
|---|---|---|
| `03-after-appgenaicontent-count.png` | `AppGenAIContent \| count` returns 37 with the role active | The with-role reading |
| `04-after-adjudicationlog-count.png` | `AdjudicationLog_CL \| count` returns 0 with the role active | The table is empty |
| `05-adjudicationlog-empty-role-active.png` | `AdjudicationLog_CL \| summarize Rows = count(), Latest = max(TimeGenerated)` returns 0 rows and no latest time, over 90 days, role active | The table is empty, not hidden |
| `06-after-deactivation-appgenaicontent-count.png` | `AppGenAIContent \| count` still returns 37 after deactivating and signing back in | Finding: standing Owner reads the protected table without the role |
| `07-appgenaicontent-protected-7d.png` | `AppGenAIContent` table settings: Analytics plan, protection Protected, analytics and total retention 7 days | The table is Protected (D-021 T2, T3) |
| `08-my-access-owner-inherited.png` | Current role assignments for the account on `ga-law-shared`: one, Owner, inherited from the subscription, with a condition; no deny assignments | Finding: the only standing role is Owner |

## Item 1 verification, 2026-10-31 to 2026-11-01 (C6)

Finding: `docs/findings.md`, "Protected tables do stop a standing Owner" (2026-11-01), which supersedes the 2026-10-26 entry above. Plan: the working run sheet, item 1 (PIM windows A and B). Text files are CLI output as printed, with subscription IDs replaced by `<sub>` and object and assignment IDs cut to first 4 and last 4. Screenshots by Tooni in the portal.

Checked before committing (13 to 34 viewed 2026-11-01): no email address, UPN, tenant or directory name, subscription ID or object ID. 16, 17, 18 and 30 show query request IDs. 32 to 34 (Safari private window, `ga-reader-test`) are cropped at the breadcrumb. 17, 18 and 30 show "Last 24 hours"; those queries failed on the table name, so the range didn't apply. 13, 19 to 20 and 29 show "Set in query" or Last 7 days with the 7-day filter in the query.

| File | Window, identity | What it shows |
|---|---|---|
| `11-1pre-role-readback-2026-10-31.txt` | A, T | Only Owner, inherited from the subscription, reaches `ga-law-shared` |
| `12-1a-cli-baseline-2026-10-31.txt` | A, CLI | 144 / 0 / 0, exit 0 |
| `13` to `15` | A, workspace context, 10-31 | 144 / 0 / 0 |
| `16` to `18` | A, `appi-tracing-v3do` resource context | "Failed to resolve table or column expression" for `AppDependencies`, `AppGenAIContent`, `AdjudicationLog_CL` |
| `19-baseline-appi-dependencies-legacy-144.png` | A, resource context | `dependencies` (legacy name) 144 |
| `20` to `22` | A-short, workspace context, 11-01, Last 7 days | 144 / 0 / 0 (a first run with Last 24 hours was discarded) |
| `23` to `25` | A-final, workspace context, Last 7 days | 144 / 0 / 0 |
| `26` to `28` | B, workspace context, data role active | 144 / 90 / 2 |
| `29-b5-pmdr-appi-dependencies-144.png` | B, resource context | `dependencies` 144 |
| `30-b5-pmdr-appi-appgenaicontent-not-resolved.png` | B, resource context | `AppGenAIContent` doesn't resolve with the role active |
| `31-b5-pmdr-appi-genaicontent-0.png` | B, resource context | `genAIContent` 0, no error, with the role active on `rg-guardedadvisor-shared` |
| `32` to `34` | B, `ga-reader-test`, workspace context | 144 / 0 / 0 |
| `35-ashort-cli-baseline-2026-11-01.txt` | A-short, CLI, 18:18:05Z | 144 / 0 / 0 |
| `36-afinal-cli-baseline-2026-11-01.txt` | A-final, CLI, 19:05:45Z | 144 / 0 / 0 |
| `37-b2-role-readback-pmdr-active.txt` | B, 19:15:30Z | Owner plus Privileged Monitoring Data Reader at `rg-guardedadvisor-shared` |
| `38-b3-cli-positive-control.txt` | B, CLI, 19:16:14Z | 144 / 90 / 2 |
| `39-ingestion-and-attribution.txt` | B, metadata only | Last ingestion times before the baseline; two SMOKE rows; all 90 rows from `appi-tracing-v3do` in `rg-guardedadvisor-lab` |
| `40-reader-only-cli-with-positive-control.txt` | B, both profiles, 20 s apart | Reader 144 / 0 / 0; T 144 / 90 / 2 |
| `41-pmdr-assignment-condition.txt` | B | The active assignment has `condition` null |
| `42-owner-only-after-deactivation.txt` | After B, 19:40:46Z | Only Owner again |
| `43-test-identity-lifecycle.txt` | `ga-reader-test` | Creation read-back, Log Analytics Reader, `/me` per profile, the orphaned assignment and its removal |
