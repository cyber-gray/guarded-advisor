# Foundry Operate overview with fresh traces (D-024, C6)

Captured 2026-10-30 to 2026-10-31 by Tooni in Edge on the jumpbox, signed in as T (the working run sheet, item 7). Finding: `docs/findings.md`, "Operate overview still shows no data while fresh agent spans exist". Checked before committing: no email, UPN, subscription ID or tenant ID visible. The subscription display name ("Azure subscription 1") is visible.

| File | When | What it shows |
|---|---|---|
| `01-overview-all-projects-no-data.png` | About 5 minutes after phase 1 (version 3 spans 22:43 to 22:45Z) | Operate > Overview (Preview), range 10/24/2026 to 10/31/2026 (7D), filter "All projects (1)": Running agents, Estimated cost, Agent success rate and Token usage all "No data to show"; 0 active alerts |
| `02-overview-project-selected-no-data.png` | Same visit | The project dropdown open: "All projects" and `ga-proj-labv3do` (the only project) both ticked; every tile "No data to show" |
| `03-overview-after-v4-runs-no-data.png` | After the version 4 runs (spans 01:03 to 01:12Z) | Same filter and range: still "No data to show" on every tile; 0 active alerts |

At the same time `AppDependencies` in the connected workspace held 29 version 3 and 38 version 4 `responsesapi` spans with `gen_ai.agent.name`, `gen_ai.agent.id` and `gen_ai.agent.version` set (laptop queries, findings).

**Project filter:** the page says "Non-Foundry agent data is always displayed. Select a project to view Foundry data." With one project, ticking `ga-proj-labv3do` also ticks All projects; the UI can't select it alone (02 shows both ticked). Observed by Tooni during the session.
