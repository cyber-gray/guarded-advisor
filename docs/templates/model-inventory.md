# Model inventory entry

Template (D-012), in the style of an OSFI Guideline E-23 model inventory. Copy into `scenarios/<pack>/model-inventory.md` and complete it at Gate 0. Model review evidence is added after testing.

| Field | Value |
|---|---|
| Model ID | `<inventory ID>` |
| Model name and version | `<model, version>` |
| Deployment | `<deployment type, region, upgrade policy>` |
| Components | `<embeddings, guardrail models, other models>` |
| Provider | `<publisher; contracting vendor>` |
| Use case | `<link to intake-record.md>` |
| Model owner | `<role>` |
| Developer | `<role>` |
| Risk tier | `<tier> (rationale in intake-record.md, section 3)` |
| Materiality | `<why the outputs matter>` |
| Decision role | `<supports human decisions / makes decisions>` |
| Inputs | `<inputs>` |
| Outputs | `<outputs and labelling>` |
| Known limitations | `<limitations>` |
| Model review plan | `<tests, thresholds fixed in advance>` |
| Model review evidence | `<links, added after testing>` |
| Independent model review | `<who reviews, independent of development; or the deviation>` |
| Monitoring | `<alerts, metrics>` |
| Monitoring thresholds | `<what triggers investigation or review>` |
| Third-party and vendor review | `<data use, retention, location terms; sources>` |
| Approval | `<link to intake decision>` |
| Next review date | `<date>` |
| Decommission | `<how the model is removed>` |

## Model selection and fallbacks

| Order | Model | Retirement | Status |
|---|---|---|---|
| 1 (primary) | `<model version>` | `<date>` | `<lifecycle status and source>` |

`<What happens if no model in the list can be deployed.>`

## Lifecycle

| Item | Value |
|---|---|
| Retirement dates | `<dates and source>` |
| Lifecycle status | `<status, how it was checked>` |
| Upgrade policy | `<for example NoAutoUpgrade, and why>` |
| Review cadence | `<cadence>` |
| Re-intake trigger | `<model or version change; retirement within N days>` |
