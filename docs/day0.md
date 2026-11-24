# Day 0 runbook

Goal: by the end of this session the tools work, the CLI is signed in to the right subscription, a budget is watching spend, the region is chosen, providers are registered, and the repo is on GitHub with secret scanning on. Nothing billable gets deployed today.

Time: 1 to 2 hours.

## 1. Install and check the tools

```bash
brew update
brew install azure-cli gh jq gitleaks python@3.12 git
az bicep install          # or: az bicep upgrade
./scripts/check-prereqs.sh
```

Node is only needed in week 3 for Promptfoo; the check lists it as optional.

PowerShell 7 (`pwsh`) is required from `w1-fork`: the Foundry sample's preflight and cleanup tools are `.ps1` scripts. Install it from Microsoft's signed PKG, not Homebrew (the Homebrew cask no longer exists). Download the PowerShell 7.6 (LTS) Arm64 `.pkg` from the releases page linked on [Install PowerShell 7 on macOS](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos) and open it; the installer asks for an admin password and links `/usr/local/bin/pwsh`. Installed 2026-10-05: 7.6.6.

## 2. Sign in (Tooni does this herself)

```bash
az login
az account list -o table
az account set --subscription "<subscription name or id>"
az account show --query "{name:name, id:id, tenant:tenantId}" -o table
gh auth login
```

Confirm the subscription shown is the personal pay-as-you-go one before going further.

## 3. Budget with alerts (`d0-budget`)

Done in the portal. Record it in `docs/runbook.md` afterward.

1. Cost Management + Billing, then **Budgets**, then **Add**. Scope: the lab subscription.
2. Reset period: monthly. Amount: the most you're willing to spend on this lab in a month.
3. Alert conditions: **Actual** at 50%, 80% and 100%, and **Forecasted** at 100%.
4. Recipient: your email.

A budget warns you; it doesn't stop spending. The real control is tearing down what you aren't using.

Before setting the amount, look up current hourly prices for API Management Standard v2, Azure AI Search and Azure Cosmos DB in the Azure pricing calculator for your likely region.

## 4. Choose the region (`d0-region`)

```bash
./scripts/check-region.sh canadacentral
./scripts/check-region.sh eastus2
```

The script lists the models offered in a region and whether API Management and Container Apps Sandboxes are offered there. It can't confirm Standard v2 tier availability or Foundry Agent Service private networking support, so confirm both on Microsoft Learn (links are printed by the script). Prefer a Canadian region, because data residency is intake condition C5. Pick one region where all four line up, then fill in D-006 in the decision log with the links you checked. If no Canadian region works, record which service forced the choice.

## 5. Confirm your role (`d0-roles`)

```bash
SUB=$(az account show --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment list --assignee "$ME" --scope "/subscriptions/$SUB" \
  --include-inherited --query "[].roleDefinitionName" -o tsv
```

Expect `Owner`. Owner covers both Foundry Account Owner and Role Based Access Administrator, which the Foundry template needs to create its role assignments.

SC-500 note: this is the first look at "manage Azure built-in role assignments". In week 1 you'll check the opposite direction, that the agent and gateway identities have far less than you do.

## 6. Register resource providers (`d0-providers`)

```bash
./scripts/register-providers.sh
```

Registration is free. It asks before changing anything and waits until every provider reports `Registered`.

## 7. Initialize the repo (`d0-repo`)

```bash
cd ~/Projects/guarded-advisor
git init -b main
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/*.sh
gitleaks dir . --no-banner        # baseline scan; should report no leaks
git add .
git commit -m "chore: scaffold Guarded Advisor workspace (d0-repo)"
gh repo create guarded-advisor --private --source=. --remote=origin --push
```

The repo stays private until the week 3 review.

## Done when

- `scripts/check-prereqs.sh` shows every required tool and both sign-ins.
- The budget exists with four alert conditions and is recorded in `docs/runbook.md`.
- D-006 in the decision log names the region and the sources checked.
- Every provider shows `Registered`.
- The first commit is on a private GitHub repo and the pre-commit hook runs.
- The status notes and the session log are updated.
