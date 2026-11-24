#!/usr/bin/env bash
# Negative and positive tests for the Deny policies on the lab resource group (w1-policy, D-017).
# Each request differs from a compliant one by one property, so each denial points at one policy.
# Creates throwaway resources (tag purpose=policytest) only when a request is expected to succeed,
# or when a policy fails to deny. Run `cleanup` afterwards; it deletes and purges everything it made.
#
# Usage:
#   ./scripts/test-policies.sh run       Run T1 to T6, write results to $OUT (JSON lines)
#   ./scripts/test-policies.sh cleanup   Delete the test deployment, accounts and Search service; purge
#
# Requires the assignments from scripts/apply-policies.sh, at least 15 minutes old.
set -euo pipefail

MODE="${1:?Usage: $0 run|cleanup}"
RG="${RESOURCE_GROUP:-rg-guardedadvisor-lab}"
LOC="${LOCATION:-canadaeast}"
SUFFIX="${SUFFIX:?Set SUFFIX to a short random hex string, the same for run and cleanup}"
OUT="${OUT:-./policy-test-results.jsonl}"
CS_API="2025-06-01"
SEARCH_API="2025-05-01"
SUB="$(az account show --query id -o tsv)"
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers"
TAGS='{"project":"guarded-advisor","env":"lab","owner":"tooni","managedBy":"cli","purpose":"policytest","expires":"2026-10-16"}'

name() { echo "ga-pt-$SUFFIX-$1"; }

account_body() { # $1 publicNetworkAccess, $2 defaultAction, $3 disableLocalAuth, $4 subdomain
  jq -n --arg loc "$LOC" --arg pna "$1" --arg acl "$2" --argjson dla "$3" --arg sd "$4" --argjson tags "$TAGS" \
    '{location:$loc, kind:"AIServices", sku:{name:"S0"}, tags:$tags,
      properties:{customSubDomainName:$sd, publicNetworkAccess:$pna, disableLocalAuth:$dla,
                  networkAcls:{defaultAction:$acl, ipRules:[], virtualNetworkRules:[]}}}'
}

deployment_body() { # $1 sku, $2 model, $3 version
  jq -n --arg sku "$1" --arg m "$2" --arg v "$3" \
    '{sku:{name:$sku, capacity:1}, properties:{model:{format:"OpenAI", name:$m, version:$v}, versionUpgradeOption:"NoAutoUpgrade"}}'
}

# Sends one PUT and records the outcome. Never prints tokens: az rest acquires them itself.
# Verdict (Tooni, 2026-10-15): a deny test passes only if the code is RequestDisallowedByPolicy AND every
# expected assignment is named. Any other error is "inconclusive"; an unexpected success is "fail".
# TESTS="T3a T5 T5b" reruns only those tests and appends to $OUT (the T3 account must already exist).
selected() { [ -z "${TESTS:-}" ] || [[ " $TESTS " == *" $1 "* ]]; }

attempt() { # $1 test id, $2 expected (deny|allow), $3 expected assignments (comma-separated), $4 url, $5 body
  local id="$1" expected="$2" want="$3" url="$4" body="$5" err outcome detail
  selected "$id" || return 0
  err="$(mktemp)"
  echo "== $id (expected: $expected)"
  if az rest --method put --url "$url" --body "$body" -o none 2>"$err"; then
    outcome="allowed"; detail="{}"
  else
    outcome="denied"
    # az rest prints: ERROR: <Reason>({json}). Keep the JSON body.
    detail="$(sed -n 's/^ERROR: [A-Za-z ]*(\(.*\))$/\1/p' "$err" | head -1)"
    jq -e . >/dev/null 2>&1 <<<"$detail" || detail="$(jq -Rs '{raw:.}' "$err")"
  fi
  jq -nc --arg id "$id" --arg exp "$expected" --arg want "$want" --arg out "$outcome" --arg url "${url%%\?*}" --argjson d "$detail" \
    '{test:$id, expected:$exp, expectedAssignments:($want|split(",")|map(select(.!=""))), outcome:$out,
      resource:($url|split("/providers/")[1]),
      code:($d.error.code // null), message:($d.error.message // $d.raw // null),
      policies:[($d.error.additionalInfo // [])[] | select(.type=="PolicyViolation") | .info |
                {assignment:.policyAssignmentName, definition:.policyDefinitionName, displayName:.policyDefinitionDisplayName}]}
     | .verdict = (if .expected=="allow" then (if .outcome=="allowed" then "pass" else "inconclusive" end)
                   elif .outcome=="allowed" then "fail"
                   elif .code=="RequestDisallowedByPolicy" and ((.expectedAssignments - [.policies[].assignment]) | length) == 0 then "pass"
                   else "inconclusive" end)' \
    | tee -a "$OUT"
  rm -f "$err"
}

run_tests() {
  [ -n "${TESTS:-}" ] || : > "$OUT"
  local acct="$BASE/Microsoft.CognitiveServices/accounts"
  attempt T1  deny  ga-deny-cs-public-network,ga-deny-ai-network "$acct/$(name t1)?api-version=$CS_API"  "$(account_body Enabled Allow true "$(name t1)")"
  attempt T1b deny  ga-deny-cs-public-network "$acct/$(name t1b)?api-version=$CS_API" "$(account_body Enabled Deny true "$(name t1b)")"
  attempt T2  deny  ga-deny-ai-local-auth "$acct/$(name t2)?api-version=$CS_API"  "$(account_body Disabled Deny false "$(name t2)")"
  attempt T3  allow "" "$acct/$(name t3)?api-version=$CS_API"  "$(account_body Disabled Deny true "$(name t3)")"
  # The PUT returns while the account is still provisioning, and a deployment request then fails with
  # RequestConflict (seen 2026-10-15). Wait for Succeeded before the deployment tests.
  local i state
  for i in $(seq 1 36); do
    state="$(az cognitiveservices account show -g "$RG" -n "$(name t3)" --query properties.provisioningState -o tsv 2>/dev/null || true)"
    [ "$state" = "Succeeded" ] && break
    sleep 5
  done
  echo "   T3 account state: ${state:-missing}"
  local dep="$acct/$(name t3)/deployments"
  attempt T3a allow "" "$dep/gpt-4.1-mini?api-version=$CS_API"         "$(deployment_body Standard gpt-4.1-mini 2025-04-14)"
  attempt T4  deny  ga-deny-deployment-sku "$dep/gpt-4.1-mini-global?api-version=$CS_API"  "$(deployment_body GlobalStandard gpt-4.1-mini 2025-04-14)"
  # T5 first ran 2026-10-15 against the built-in approved-models policy alone and was ALLOWED (D-017, findings).
  # The custom control-plane allowlist (ga-deny-unpinned-models) is the expected denial now.
  attempt T5  deny  ga-deny-unpinned-models "$dep/text-embedding-3-large-v2?api-version=$CS_API" "$(deployment_body Standard text-embedding-3-large 1)"
  # T5b: an approved model with the version omitted must be denied (no floating default version).
  attempt T5b deny  ga-deny-unpinned-models "$dep/gpt-4.1-mini-noversion?api-version=$CS_API" \
    "$(jq -n '{sku:{name:"Standard", capacity:1}, properties:{model:{format:"OpenAI", name:"gpt-4.1-mini"}, versionUpgradeOption:"NoAutoUpgrade"}}')"
  attempt T6  deny  ga-deny-ai-local-auth "$BASE/Microsoft.Search/searchServices/$(name t6)?api-version=$SEARCH_API" \
    "$(jq -n --arg loc "$LOC" --argjson tags "$TAGS" '{location:$loc, sku:{name:"free"}, tags:$tags, properties:{publicNetworkAccess:"disabled", disableLocalAuth:false}}')"
  echo "Results in $OUT. Verdicts:"
  jq -r '"  \(.test): \(.verdict) (\(.outcome); code \(.code // "-"); named \([.policies[].assignment] | join(",")))"' "$OUT"
}

cleanup() {
  echo "Cleaning up test resources with suffix $SUFFIX in $RG"
  local t3; t3="$(name t3)"
  # Delete only deployments that exist: the CLI reports success for a missing deployment.
  local d
  for d in $(az cognitiveservices account deployment list -g "$RG" -n "$t3" --query "[].name" -o tsv 2>/dev/null || true); do
    az cognitiveservices account deployment delete -g "$RG" -n "$t3" --deployment-name "$d" && echo "  deleted deployment $d"
  done
  for t in t1 t1b t2 t3; do
    if az cognitiveservices account show -g "$RG" -n "$(name $t)" -o none 2>/dev/null; then
      az cognitiveservices account delete -g "$RG" -n "$(name $t)" && echo "  deleted $(name $t)"
    fi
  done
  for t in t1 t1b t2 t3; do
    if az cognitiveservices account list-deleted --query "[?name=='$(name $t)'] | length(@)" -o tsv | grep -q '^[1-9]'; then
      az cognitiveservices account purge -l "$LOC" -g "$RG" -n "$(name $t)" && echo "  purged $(name $t)"
    fi
  done
  if az search service show -g "$RG" -n "$(name t6)" -o none 2>/dev/null; then
    az search service delete -g "$RG" -n "$(name t6)" --yes && echo "  deleted $(name t6)"
  fi
  echo "Resources left in $RG: $(az resource list -g "$RG" --query 'length(@)' -o tsv)"
  echo "Soft-deleted Cognitive Services accounts: $(az cognitiveservices account list-deleted --query 'length(@)' -o tsv)"
}

case "$MODE" in
  run) run_tests ;;
  cleanup) cleanup ;;
  *) echo "Unknown mode: $MODE. Supported: run, cleanup" >&2; exit 1 ;;
esac
