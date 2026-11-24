#!/usr/bin/env bash
# Checks the tools and sign-ins Guarded Advisor needs. Changes nothing.
set -euo pipefail

missing=0
row() { printf "  %-3s %-12s %s\n" "$1" "$2" "$3"; }

need() { # name, command, version command, install hint
  if command -v "$2" >/dev/null 2>&1; then
    row "ok" "$1" "$(eval "$3" 2>/dev/null | head -1)"
  else
    row "--" "$1" "missing. Install: $4"
    missing=1
  fi
}

echo "Required tools"
need "az"       az       "az version --query '\"azure-cli\"' -o tsv"  "brew install azure-cli"
need "git"      git      "git --version"                              "brew install git"
need "gh"       gh       "gh --version"                               "brew install gh"
need "jq"       jq       "jq --version"                               "brew install jq"
need "gitleaks" gitleaks "gitleaks version"                           "brew install gitleaks"
need "python3"  python3  "python3 --version"                          "brew install python@3.12"
need "pwsh"     pwsh     "pwsh -NoLogo -NoProfile -Command '\$PSVersionTable.PSVersion.ToString()'" "Microsoft's signed PKG (7.6 LTS, Arm64): https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos"

if command -v az >/dev/null 2>&1; then
  if bv=$(az bicep version 2>/dev/null | head -1) && [ -n "$bv" ]; then
    row "ok" "bicep" "$bv"
  else
    row "--" "bicep" "missing. Install: az bicep install"
    missing=1
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    row "--" "python3" "needs 3.10 or later. Install: brew install python@3.12"
    missing=1
  fi
fi

echo
echo "Optional (week 3)"
if command -v node >/dev/null 2>&1; then
  row "ok" "node" "$(node --version)"
else
  row ".." "node" "not needed until Promptfoo in week 3. Install: brew install node"
fi

echo
echo "Sign-ins"
# az account show only reads the local cache, so it passes even when the refresh
# token has expired. Requesting a token proves the sign-in works; only the expiry is printed.
if command -v az >/dev/null 2>&1 \
  && expires=$(az account get-access-token --query expiresOn -o tsv 2>/dev/null) \
  && acct=$(az account show --query "name" -o tsv 2>/dev/null); then
  row "ok" "azure" "subscription: $acct (token valid until $expires)"
else
  row "--" "azure" "not signed in or sign-in expired. Run: az login"
  missing=1
fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  row "ok" "github" "signed in"
else
  row "--" "github" "not signed in. Run: gh auth login"
  missing=1
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "All set."
else
  echo "Fix the items marked -- and run this again."
  exit 1
fi
