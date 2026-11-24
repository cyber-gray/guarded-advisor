# Key decisions

Ten decisions from the lab that say the most about how it was run. Each one shows a lens: **Cybersecurity**, **IAM** (identity and access management), **GRC** (governance, risk and compliance) or **AI Security**.

The small print under each decision cites the lab's decision log by number (D-0xx). The log itself lives in the private working repository and isn't published; this page summarizes the decisions that matter most. Evidence paths point into this repository.

## 1. Approve the use case before building it, and tie every condition to a test

*Lenses: GRC, AI Security*

**What we decided.** The case assistant went through an AI use-case intake and a risk rating (High: health information, influence on benefit outcomes) before any resource was deployed. The approval came with eight conditions, C1 to C8. Each condition names the control that enforces it and the test that proves it, and a launch decision rule says in advance which failures block launch.

**Why it matters.** The gate decision at the end didn't have to invent its criteria. It applied rules written weeks earlier, before anyone knew the results.

<sub>Intake record: `scenarios/larkfield/intake-record.md`. Model inventory: `scenarios/larkfield/model-inventory.md`. Gate decision: `scenarios/larkfield/gate-decision.md`.</sub>

## 2. Write down the expected result before each test runs

*Lenses: GRC, Cybersecurity*

**What we decided.** Before each test run, a row recording what was expected (blocked, refused or complied) was written to a separate ground-truth table, and the run plan was committed before the results existed. A script then checked that every run had its row, written first. For the jailbreak sent through the agent (DF-1), the run sheet said in advance that "no alert" from Microsoft Defender for AI Services would be recorded as a result, not as a fail. When no alert came, that's how it was recorded.

**Why it matters.** It's easy to decide after the fact that a result was what you meant to test. Fixing the expectations first keeps the scorecard honest, including when the honest answer is "we saw nothing, and we don't know why".

<sub>D-045. Findings: "C6 match for 2026-11-16" and "DF-1" in `docs/findings.md`. Plan file: `redteam/plans/run-20261116.json`.</sub>

## 3. Check permissions in code, not in the prompt

*Lenses: AI Security, IAM*

**What we decided.** The tool that returns a claim, `get_claim_summary`, decides whether the caller may see that claim from the caller's identity token and an entitlement map. The model's instructions play no part in the decision. A request for another case manager's claim is refused and logged, whatever the model was talked into asking for.

**Why it matters.** Members and providers write part of what the agent reads, so a prompt injection is expected, not exceptional. A control the model can be persuaded around isn't a control. This one held in every test: each case manager got only their own claims, and a Microsoft Sentinel rule fired on repeated refusals.

<sub>Intake condition C2. Findings: "M3 and M4 pass" and the live matrix in `docs/findings.md`; control matrix K04 to K06.</sub>

## 4. Don't give the agent code execution until the sandbox is proven

*Lenses: AI Security, Cybersecurity*

**What we decided.** The planned tool that lets the agent write and run Python in an Azure Container Apps sandbox was not given to the agent. A direct probe of the sandbox showed that, with outbound traffic set to deny with full inspection, a raw network connection still got out with no log entry, and managed-identity endpoint variables were present even with no identity attached. The path to reopen it is written down: a verified network-level deny, an answer from Microsoft on the identity endpoint, a non-root execution path, then the tool behind a feature flag with its tests.

**Why it matters.** Code written by an agent from attacker-supplied input is untrusted code. A new platform feature whose settings say "deny" deserves a test before it carries that risk.

<sub>D-026. Findings: "S3-0 probe" and "The sandbox exposes a managed-identity endpoint" in `docs/findings.md`.</sub>

## 5. A control that failed stays failed, even if the feature is switched off

*Lenses: GRC, AI Security*

**What we decided.** The condition for agent-written code (C4) was first recorded as met because the code tool wasn't exposed. That was reversed: C4 reads **Fail**. Leaving the tool out limits exposure, but it doesn't make the sandbox controls work, and the condition is about the controls.

**Why it matters.** "Pass by scope" quietly turns a failed control into a green line on a dashboard. Recording the fail keeps the retest on the list and tells the next reviewer what's actually true.

<sub>D-047 (final 2026-11-20), amending D-026. Gate decision, section 4, C4.</sub>

## 6. Drop a retest rather than re-enable a disabled account

*Lenses: IAM, GRC*

**What we decided.** A planned Microsoft Purview Audit check turned out to be impossible to rerun: audit logging had never been on in the tenant, and the only way to create new interactions was to re-enable one of the synthetic case manager accounts that had already been disabled and stripped of access. The rerun was dropped. One read-only check was kept, and the gap is recorded as "not tested".

**Why it matters.** Re-opening an account to get one more data point undoes the clean-up the test was part of. Accepting a recorded gap is the safer trade.

<sub>D-046. Findings: "Purview Audit was never recording in this tenant" in `docs/findings.md`.</sub>

## 7. No standing write roles: Owner only through just-in-time activation

*Lens: IAM*

**What we decided.** The lab's admin account holds a standing read-only Reader role and is only *eligible* for Owner through Microsoft Entra Privileged Identity Management (PIM). Every change to Azure needed a time-limited activation, and the teardown script stops before changing anything if the caller lacks the right.

**Why it matters.** A standing Owner could quietly undo the lab's own controls, for example by downgrading a protected log table. With PIM, each such change is a deliberate, logged step, and the rest of the time the account can only read.

<sub>D-030. Evidence: `docs/evidence/w2-pim/`.</sub>

## 8. Test the way back in, with the least privilege that works

*Lenses: IAM, Cybersecurity*

**What we decided.** At the end, the admin account's Owner eligibility was left to expire, so no one held a write role on the subscription. The recovery path was then exercised for real: the Global Administrator elevated access at the tenant root, made the admin account eligible for **Monitoring Contributor** (not Owner) for one hour, and switched the elevation off again. The admin account used it to remove one leftover diagnostic setting.

**Why it matters.** A recovery path you have never used is a guess. Using it once, with the narrowest role that does the job, shows both that it works and that it doesn't need Owner.

<sub>D-048, D-052 (with a correction of 2026-11-24: the admin account kept its standing Reader throughout). Evidence: `docs/evidence/w5-closeout/`.</sub>

## 9. Narrow the Temporary Access Pass, then turn it off

*Lens: IAM*

**What we decided.** The Temporary Access Pass sign-in method had been enabled for all users before the lab, for unknown reasons. It was narrowed to the case manager group for the test window, with one-time passes timed to the sessions, and disabled at the end once those accounts were deleted.

**Why it matters.** A sign-in method that bypasses a password is a standing risk if it's open to everyone. Scoping it to the people who need it, then removing it, closes a path that nobody was watching.

<sub>D-031, D-049. Evidence: `docs/evidence/w4-wed/13`.</sub>

## 10. Record the access you keep, not only the access you remove

*Lenses: IAM, GRC*

**What we decided.** Two read-only roles were kept on purpose after teardown and recorded as decisions: a standing Reader on the subscription and an eligible (not active) Microsoft Entra Security Reader role, both for exam practice, with a review at the next lab.

**Why it matters.** Teardowns usually list what was deleted. Leftover access that nobody wrote down is how a clean environment drifts. Writing down what stays, and why, makes the next access review short.

<sub>D-053, D-054. Evidence: `docs/evidence/w5-closeout/03` and `04`.</sub>
