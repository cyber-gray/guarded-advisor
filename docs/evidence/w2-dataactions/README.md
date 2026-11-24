# DataActionsOnly pre-checks (item 2, C6)

Captured 2026-11-01 from the laptop as T, read-only. Item 2 stopped at pre-check 3. Finding: `docs/findings.md`, "DataActionsOnly not tested" (2026-11-01). Decision for the next sitting: D-029. Subscription IDs replaced by `<sub>`.

| File | Pre-check | What it shows |
|---|---|---|
| `01-p3-features-baseline-2026-03-01.json` | P3 | `ga-law-shared` `features` read at api-version 2026-03-01: `enableLogAccessUsingOnlyResourcePermissions` true, `legacy` 0, `searchVersion` 1; no `dataAuthorizationMode`. Revert baseline for the next sitting |
| `02-pmdr-role-definition.txt` | P2 | Privileged Monitoring Data Reader: both DataActions (`workspaces/tables/data/read`, `Microsoft.Insights/logs/data/read`), `Microsoft.Insights/Logs/Read` in Actions, and the version 2.0 condition in the definition |
| `03-workspace-api-versions.txt` | P4b | 2026-03-01 is the newest workspaces api-version the provider offers |

## Item 2 run under D-029, 2026-11-02 (C6)

Finding: `docs/findings.md`, "DataActionsOnly removes General reads from standing Owner and Log Analytics Reader, silently" (2026-11-02). Text files are CLI output as printed (subscription IDs `<sub>`, object and assignment IDs first 4 and last 4). Screenshots by Tooni, viewed 2026-11-02: no email address, UPN, tenant or directory name, subscription ID or object ID. 07 to 09 show no account name. 13 and 23 are cropped to the Properties pane. **14 to 22 don't exist:** the window C portal set wasn't captured, and the window D portal set was skipped for time.

| File | What it shows |
|---|---|
| `04` to `06` | Window A, `ga-reader-test2` (Safari private window), Last 7 days: 144 / 0 / 0 |
| `07` to `09` | Window A, the **guest account** by mistake (unconditioned Owner plus Global Administrator): 144 / 0 / 0 |
| `10` to `12` | Window A, T: 144 / 0 / 0 |
| `13-data-auth-mode-dataactionsonly-after.png` | Properties after the enable: Data authorization mode "Data actions only" (22:05Z) |
| `23-data-auth-mode-reverted-control-and-data.png` | Properties after the revert: "Control and data actions" (22:52Z) |
| `24-step1-owner-only-and-features-baseline.txt` | T Owner only; `features` matched `01` |
| `25-test-identity-setup.txt` | User read-back, Log Analytics Reader `980c...f09e`, TAP times, extension check and install, `/me` per profile |
| `26-windowA-cli.txt` | Setting off: both 144 / 0 / 0 |
| `27-features-after-enable.txt` | `"dataAuthorizationMode": true` |
| `28-windowC-cli.txt` | Setting on: both 0 / 0 / 0, no errors |
| `29-windowD-role-and-positive-control.txt` | Data role active: 144 / 90 / 2 |
| `30-features-after-revert.txt` | `"dataAuthorizationMode": false`, twice |
| `31-revert-with-role.txt` | Reader 0 then 144 for General; T with the role 144 / 90 / 2 |
| `32-r4-and-deactivation-lag.txt` | R-4 runs and the lag runs: Owner only in ARM while Protected reads continued until between 23:08Z and 23:26Z |
| `33-cleanup.txt` | Role removed by ID before the user deletion; user gone; Owner only |
