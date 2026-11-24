# AI use-case intake and approval record

Template (D-012). Copy into `scenarios/<pack>/intake-record.md` and complete it at Gate 0, before any infrastructure is built. Replace every `<placeholder>`; delete guidance lines in italics.

## 1. Use case

| Field | Value |
|---|---|
| Name | `<name of the AI system>` |
| Organization | `<organization (fictional in the lab)>` |
| Business owner | `<role>` |
| Requested by | `<role>` |
| Privacy Officer | `<role>`; consulted from the outset |
| Date submitted | `<YYYY-MM-DD>` |
| Users | `<who uses it; who never interacts with it>` |
| Purpose | `<problem it solves>` |
| In scope | `<capabilities>` |
| Out of scope | `<decisions and functions it must not perform; what triggers a new intake>` |

## 2. Data

| Data | Source | Classification | Notes |
|---|---|---|---|
| `<data set>` | `<source>` | `<classification>` | `<trusted or untrusted; how it's accessed>` |

**Secondary use:** `<state whether data, prompts and outputs may be used for training, fine-tuning or other purposes>`

### Residency

*Region and deployment type for each component, policies that enforce them, features excluded for residency reasons, and the scope of the residency condition (Azure resources and model inference vs tenant-level services).*

## 3. Risk assessment

| Area | Rating | Reason |
|---|---|---|
| Impact on individuals | `<Low/Medium/High>` | `<reason>` |
| Data sensitivity | `<Low/Medium/High>` | `<reason>` |
| Autonomy | `<Low/Medium/High>` | `<reason>` |
| Exposure to untrusted input | `<Low/Medium/High>` | `<reason>` |
| Model risk | `<Low/Medium/High>` | `<rating rationale; see model-inventory.md>` |

**Overall risk tier:** `<tier>`

## 4. Decision

**`<Approve / Approve with conditions / Reject>`.** Launch requires evidence for each condition, assessed under the launch decision rule (section 5).

| Condition | Requirement | Enforced by | Test (fails if…) | Status |
|---|---|---|---|---|
| C1 | `<requirement>` | `<control that enforces it>` | `<concrete observation that would fail the test>` | Open |

*Every test must be able to fail. Fix thresholds here, before results are seen.*

## 5. Launch decision rule

| Result | Decision |
|---|---|
| All conditions pass | Approved for launch. |
| A condition fails and a documented mitigation is accepted by the approver | Approved with a recorded exception (condition, evidence, mitigation, residual risk, owner, review date). |
| Any failure of `<conditions with no exception path>` | **Not approved** until fixed and retested. No exception path. |

## 6. Regulatory context

*One short cited paragraph per regulation or guideline that applies. End each with: "Lab interpretation, not legal advice."*

**`<regulation>`.** `<how it applies>`. Source: `<URL>`. *Lab interpretation, not legal advice.*

**Data leaving the jurisdiction** (s. 17-style flows table):

| Flow | Leaves `<province/state>` | Leaves `<country>` | Treatment |
|---|---|---|---|
| `<flow>` | `<Yes / No / Depends>` | `<Yes / No / Depends>` | `<treatment and source>` |

## 7. Residual-risk register

| Risk | Treatment |
|---|---|
| `<risk>` | `<accepted / mitigated by …>` |

## 8. Lab governance deviations

- `<deviation from what a production program would do, and why it's acceptable in the lab>`

## 9. Kill switch and incident response

- `<how to stop the system quickly; who can do it>`

## 10. Review

- Approver: `<role>`
- Next review: `<triggers and dates>`
- Status history:
  - `<YYYY-MM-DD>`: submitted.
