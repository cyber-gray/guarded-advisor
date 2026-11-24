#!/usr/bin/env bash
# Read-only checks of the live lab against the intake conditions (w1-verify). Exits non-zero on any failure.
# Started 2026-10-15 with the model deployment checks (D-014, D-017) and the network checks; w1-verify adds
# the residency and Network Watcher checks.
#
# Usage:
#   ./scripts/verify.sh [deployments]   Model deployments: Standard SKU, approved format/name/version, NoAutoUpgrade
#   ./scripts/verify.sh outside         From a machine OUTSIDE the VNet (Tooni's laptop): every data plane must be
#                                       refused and no name may resolve to a private IP
#   ./scripts/verify.sh inside          From the jumpbox INSIDE the VNet (w1-jump): every name must resolve to the
#                                       private endpoint subnet and no data plane may return a network refusal
#   ./scripts/verify.sh disks           Every managed disk in the lab group blocks export: networkAccessPolicy DenyAll
#                                       and publicNetworkAccess Disabled (set by scripts/jumpbox.sh harden-disk, D-018)
#   ./scripts/verify.sh sandboxes       The sandbox group keeps its limits (maxSandboxCount, no vnetConnections, no identity
#                                       outside a registration run) and every
#                                       sandbox in it has default-deny egress with Full inspection, no rules and the
#                                       egress proxy not skipped (D-025). Needs SandboxGroup Data Owner on the group (R10, PIM)
#   ./scripts/verify.sh residency       Lab groups and resources in $LOCATION or an expected-global type, regional Standard
#                                       model deployments, LRS storage with no secondary, Cosmos DB in $LOCATION only with
#                                       single-region writes and Local backups (C5, D-006). Read-only, control plane
#   ./scripts/verify.sh all             deployments + disks + sandboxes + residency + outside
#
# Calls use `az rest`, which gets the Entra token itself, so no token is printed or stored. Public IPs in error
# text are masked before printing. Portable to Git Bash on Windows: needs only az, curl, nslookup, jq, awk, grep.
set -euo pipefail

MODE="${1:-deployments}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_GROUPS="${RESOURCE_GROUPS:-rg-guardedadvisor-lab rg-guardedadvisor-shared}"
LAB_RG="${LAB_RG:-rg-guardedadvisor-lab}"
PE_SUBNET_PREFIX="${PE_SUBNET_PREFIX:-192.168.1.}"   # pe-subnet 192.168.1.0/24 (D-015)
LOCATION="${LOCATION:-canadaeast}"
SANDBOX_GROUP="${SANDBOX_GROUP:-ga-sbx-lab}"
SANDBOX_MAX="${SANDBOX_MAX:-2}"
# The group's limits are returned only by the preview ARM version (the GA 2026-07-01 hides them, findings 2026-10-23);
# the data plane is 2026-02-01-preview (azure-containerapps-sandbox 0.1.0b4).
SANDBOX_API="2026-02-01-preview"
# Types whose location is "global" by design; any other location outside $LOCATION fails (w1-verify, 2026-11-05).
GLOBAL_TYPES="microsoft.network/privatednszones microsoft.network/privatednszones/virtualnetworklinks microsoft.insights/privatelinkscopes microsoft.insights/actiongroups microsoft.insights/activitylogalerts microsoft.insights/metricalerts microsoft.alertsmanagement/smartdetectoralertrules"
FAILURES=0
INCONCLUSIVE=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILURES=$((FAILURES + 1)); }
inconclusive() { echo "  INCONCLUSIVE $*"; INCONCLUSIVE=$((INCONCLUSIVE + 1)); }
mask() { sed -E 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/<ip>/g' | tr '\n' ' ' | cut -c1-240; }

check_deployments() {
  # Approved models come from the same parameter file the policy assignment uses, so the check and the
  # preventive control can't drift apart.
  local approved
  approved="$(az bicep build-params --file "$ROOT/infra/policy-assignments.lab.bicepparam" --stdout 2>/dev/null \
    | jq -r '.parametersJson | fromjson | .parameters.approvedModels.value[]')"
  echo "Model deployments (C5: Standard SKU, approved model and version, NoAutoUpgrade)"
  echo "  approved: $(echo "$approved" | paste -sd ' ' -)"
  local rg account dep sku fmt model version upgrade id
  for rg in $RESOURCE_GROUPS; do
    for account in $(az cognitiveservices account list -g "$rg" --query "[].name" -o tsv); do
      while IFS=$'\t' read -r dep sku fmt model version upgrade; do
        [ -z "$dep" ] && continue
        id="$rg/$account/$dep"
        [ "$sku" = "Standard" ] && pass "$id sku=$sku" || fail "$id sku=$sku (only Standard keeps inference in Canada, D-006)"
        if echo "$approved" | grep -qxF "$fmt/$model/$version"; then
          pass "$id model=$fmt/$model/$version"
        else
          fail "$id model=$fmt/$model/$version is not in the approved list (model inventory, D-017)"
        fi
        [ "$upgrade" = "NoAutoUpgrade" ] && pass "$id versionUpgradeOption=$upgrade" \
          || fail "$id versionUpgradeOption=$upgrade (must be NoAutoUpgrade, D-014)"
      done < <(az cognitiveservices account deployment list -g "$rg" -n "$account" \
        --query "[].[name, sku.name, properties.model.format, properties.model.name, properties.model.version, properties.versionUpgradeOption]" -o tsv)
    done
  done
}

# Detective check for the disk export settings that can't be set in Bicep (docs/runbook.md, 2026-10-16).
# https://learn.microsoft.com/azure/virtual-machines/disks-restrict-import-export-overview
check_disks() {
  echo "Managed disks in $LAB_RG (export blocked: networkAccessPolicy DenyAll, publicNetworkAccess Disabled)"
  local name nap pna found=0
  while IFS=$'\t' read -r name nap pna; do
    [ -z "$name" ] && continue
    found=1
    [ "$nap" = "DenyAll" ] && pass "$name networkAccessPolicy=$nap" \
      || fail "$name networkAccessPolicy=$nap (must be DenyAll; run scripts/jumpbox.sh harden-disk)"
    [ "$pna" = "Disabled" ] && pass "$name publicNetworkAccess=$pna" \
      || fail "$name publicNetworkAccess=$pna (must be Disabled; run scripts/jumpbox.sh harden-disk)"
  done < <(az disk list -g "$LAB_RG" --query "[].[name, networkAccessPolicy, publicNetworkAccess]" -o tsv)
  [ "$found" = 1 ] || echo "  no managed disks"
}

# Residency (C5, D-006; w1-verify evidence 03 and 04, 2026-11-05). Control plane only, read-only, no keys.
# Lab resources are named; resources outside $RESOURCE_GROUPS are counted, not named. This reads configuration,
# not where data or requests went. Key Vault replicates to Canada Central by platform design (D-006).
check_residency() {
  echo "Residency (C5: $LOCATION or expected-global; Standard models; LRS storage; Cosmos DB single-region, Local backups)"
  local rg loc rgs all name type ltype lloc n_ok=0 n_glob=0 seen=""
  for rg in $RESOURCE_GROUPS; do
    loc=$(az group show -n "$rg" --query location -o tsv)
    if [ "$loc" = "$LOCATION" ]; then
      pass "group $rg location=$loc"
    else
      fail "group $rg location=$loc (must be $LOCATION, D-006)"
    fi
  done
  rgs=$(printf '%s\n' $RESOURCE_GROUPS | jq -R 'ascii_downcase' | jq -s .)
  all=$(az resource list -o json)
  while IFS=$'\t' read -r name type loc; do
    [ -z "$name" ] && continue
    ltype=$(tr 'A-Z' 'a-z' <<<"$type"); lloc=$(tr 'A-Z' 'a-z' <<<"$loc")
    if [ "$lloc" = "$LOCATION" ]; then
      n_ok=$((n_ok + 1))
    elif [ "$lloc" = "global" ] && [[ " $GLOBAL_TYPES " == *" $ltype "* ]]; then
      n_glob=$((n_glob + 1))
      if [[ " $seen " != *" $ltype "* ]]; then seen="$seen $ltype"; fi
    else
      fail "$name $type location=$loc (not $LOCATION and not an expected-global type)"
    fi
  done < <(jq -r --argjson rgs "$rgs" '.[] | select(.resourceGroup|ascii_downcase|IN($rgs[])) | [.name, .type, (.location // "none")] | @tsv' <<<"$all")
  pass "lab resources: $n_ok in $LOCATION, $n_glob expected global (${seen# })"
  echo "  outside the lab groups: $(jq --argjson rgs "$rgs" '[.[] | select(.resourceGroup|ascii_downcase|IN($rgs[])|not)] | length' <<<"$all"), counted only"

  local acct dep sku
  for rg in $RESOURCE_GROUPS; do
    for acct in $(az cognitiveservices account list -g "$rg" --query "[].name" -o tsv); do
      while IFS=$'\t' read -r dep sku; do
        [ -z "$dep" ] && continue
        if [ "$sku" = "Standard" ]; then
          pass "$acct/$dep sku=$sku"
        else
          fail "$acct/$dep sku=$sku (only regional Standard keeps processing in the Canada geography; Global and DataZone can leave it)"
        fi
      done < <(az cognitiveservices account deployment list -g "$rg" -n "$acct" --query "[].[name, sku.name]" -o tsv)
    done
  done

  local st ssku prim sec
  for rg in $RESOURCE_GROUPS; do
    while IFS=$'\t' read -r st ssku prim sec; do
      [ -z "$st" ] && continue
      if [ "$prim" = "$LOCATION" ]; then
        pass "$st primaryLocation=$prim"
      else
        fail "$st primaryLocation=$prim (must be $LOCATION)"
      fi
      if [[ "$ssku" == *_LRS ]]; then
        pass "$st sku=$ssku"
      else
        fail "$st sku=$ssku (must be LRS so data stays in $LOCATION, D-006)"
      fi
      if [ -z "$sec" ] || [ "$sec" = "None" ]; then
        pass "$st no secondary"
      else
        fail "$st secondaryLocation=$sec (D-006)"
      fi
    done < <(az storage account list -g "$rg" --query "[].[name, sku.name, primaryLocation, secondaryLocation]" -o tsv)
  done

  local co cos clocs mw bsr l
  for rg in $RESOURCE_GROUPS; do
    cos=$(az cosmosdb list -g "$rg" -o json)
    for co in $(jq -r '.[].name' <<<"$cos"); do
      clocs=$(jq -r --arg n "$co" '.[] | select(.name==$n) | .locations[].locationName | ascii_downcase | gsub(" ";"")' <<<"$cos")
      for l in $clocs; do
        if [ "$l" = "$LOCATION" ]; then
          pass "$co location=$l"
        else
          fail "$co location=$l (Cosmos DB must stay in $LOCATION, D-006)"
        fi
      done
      mw=$(jq -r --arg n "$co" '.[] | select(.name==$n) | .enableMultipleWriteLocations' <<<"$cos")
      if [ "$mw" = "false" ]; then
        pass "$co enableMultipleWriteLocations=false"
      else
        fail "$co enableMultipleWriteLocations=$mw"
      fi
      bsr=$(jq -r --arg n "$co" '.[] | select(.name==$n) | .backupPolicy.periodicModeProperties.backupStorageRedundancy // "not returned"' <<<"$cos")
      case "$bsr" in
        Local) pass "$co backupStorageRedundancy=Local" ;;
        "not returned") inconclusive "$co backupStorageRedundancy not returned (continuous backup mode?)" ;;
        *) fail "$co backupStorageRedundancy=$bsr (must be Local, D-006)" ;;
      esac
    done
  done
  echo "  not checked here: Key Vault replication (Canada Central, D-006); Entra data location (United States, docs/evidence/w2-pim/97)"
}

# Detective check for sandbox egress (findings 2026-10-23): a sandbox's egress default isn't set by the group, so
# every sandbox in the group is read back and judged by scripts/lib/sandbox-egress.jq (shared with teardown.sh).
check_sandboxes() {
  echo "Sandbox group $SANDBOX_GROUP in $LAB_RG (limits, no VNet connection, default-deny egress on every sandbox)"
  local sub gid group max ident vnets base out ids id sbx verdict detail
  sub=$(az account show --query id -o tsv)
  gid="/subscriptions/$sub/resourceGroups/$LAB_RG/providers/Microsoft.App/sandboxGroups/$SANDBOX_GROUP"
  if ! group=$(az rest --method get --url "https://management.azure.com$gid?api-version=$SANDBOX_API" -o json 2>/dev/null); then
    echo "  no sandbox group $SANDBOX_GROUP"
    return 0
  fi
  max=$(jq -r '.properties.maxSandboxCount // "unset"' <<<"$group")
  [ "$max" = "$SANDBOX_MAX" ] && pass "maxSandboxCount=$max" || fail "maxSandboxCount=$max (must be $SANDBOX_MAX)"
  # Just-in-time pull identity (IDEAS.md, 2026-10-26): the group carries an identity only during a registration run
  # (build-sandbox-image.sh register); set SANDBOX_REGISTRATION=1 while one is in progress.
  ident=$(jq -r '.identity.type // "None"' <<<"$group")
  if [ "$ident" = "None" ]; then
    pass "identity=None (no identity on the group outside a registration run)"
  elif [ "${SANDBOX_REGISTRATION:-}" = "1" ]; then
    inconclusive "identity=$ident (a registration run is in progress, SANDBOX_REGISTRATION=1)"
  else
    fail "identity=$ident outside a registration run (detach: deploy infra/sandbox.bicep with the default param file)"
  fi
  vnets=$(az rest --method get --url "https://management.azure.com$gid/vnetConnections?api-version=$SANDBOX_API" \
            --query "length(value)" -o tsv 2>/dev/null || echo "?")
  [ "$vnets" = "0" ] && pass "vnetConnections=0 (no route into the lab VNet)" \
    || fail "vnetConnections=$vnets (must be 0, D-025)"
  base="https://management.${LOCATION}.azuredevcompute.io/subscriptions/$sub/resourceGroups/$LAB_RG/sandboxGroups/$SANDBOX_GROUP"
  if ! out=$(az rest --method get --resource https://dynamicsessions.io \
               --url "$base/sandboxes?api-version=$SANDBOX_API" -o json 2>&1); then
    inconclusive "couldn't list sandboxes (needs SandboxGroup Data Owner on the group, R10: activate it in PIM): $(echo "$out" | mask)"
    return 0
  fi
  ids=$(jq -r '(if type == "array" then . else (.value // []) end)[] | .id' <<<"$out")
  if [ -z "$ids" ]; then
    pass "0 sandboxes in the group"
    return 0
  fi
  for id in $ids; do
    sbx=$(az rest --method get --resource https://dynamicsessions.io --url "$base/sandboxes/$id?api-version=$SANDBOX_API" -o json)
    IFS=$'\t' read -r verdict detail <<<"$(jq -r -f "$ROOT/scripts/lib/sandbox-egress.jq" <<<"$sbx")"
    case "$verdict" in
      OK) pass "sandbox $id ${detail//$'\t'/ }" ;;
      UNKNOWN) inconclusive "sandbox $id ${detail//$'\t'/ } (the response doesn't say whether the proxy is skipped)" ;;
      *) fail "sandbox $id ${detail//$'\t'/ } (must be default=Deny inspection=Full rules=0, proxy not skipped)" ;;
    esac
  done
}

# Endpoint table: label|hostname|token audience|method|path|extra az rest args|network-refusal pattern|rbac-first
# rbac-first=1 marks data planes that check the caller's data action before the network (observed 2026-10-15:
# a caller without a data role gets PermissionDenied, not a network refusal), so from outside they are
# INCONCLUSIVE unless the caller holds a data role. A caller that holds one settles them: on 2026-10-16, with
# temporary scoped data roles, both were refused with "Public access is disabled" (docs/findings.md).
endpoints() {
  local acct cs search storage cosmos kv project
  acct="$(az cognitiveservices account list -g "$LAB_RG" --query "[?kind=='AIServices'].name | [0]" -o tsv)"
  cs="$(az cognitiveservices account list -g "$LAB_RG" --query "[?kind=='ContentSafety'].name | [0]" -o tsv)"
  project="$(az resource list -g "$LAB_RG" --resource-type Microsoft.CognitiveServices/accounts/projects --query "[0].name" -o tsv | awk -F/ '{print $NF}')"
  search="$(az search service list -g "$LAB_RG" --query "[0].name" -o tsv)"
  storage="$(az storage account list -g "$LAB_RG" --query "[0].name" -o tsv)"
  cosmos="$(az cosmosdb list -g "$LAB_RG" --query "[0].name" -o tsv)"
  kv="$(az keyvault list -g "$LAB_RG" --query "[0].name" -o tsv)"
  cat <<EOT
foundry|$acct.services.ai.azure.com|https://ai.azure.com|get|/api/projects/$project/agents?api-version=v1||Public access is disabled|0
openai|$acct.openai.azure.com|https://cognitiveservices.azure.com|get|/openai/v1/models||Public access is disabled|1
contentsafety|$cs.cognitiveservices.azure.com|https://cognitiveservices.azure.com|post|/contentsafety/text:analyze?api-version=2024-09-01|--body {"text":"verify"}|Public access is disabled|1
search|$search.search.windows.net|https://search.azure.com|get|/indexes?api-version=2024-07-01||publicNetworkAccess: Disabled|0
storage|$storage.blob.core.windows.net|https://storage.azure.com|get|/?comp=list|--headers x-ms-version=2023-11-03|AuthorizationFailure|0
keyvault|$kv.vault.azure.net|https://vault.azure.net|get|/secrets?api-version=7.4||ForbiddenByConnection|0
cosmos|$cosmos.documents.azure.com|-|get|/dbs||blocked by your Cosmos DB account firewall|0
EOT
}

# Sends one request. Cosmos DB uses a plain unauthenticated GET (its firewall answers before auth); the rest use
# az rest with an Entra token. Prints "ok" or the error text.
call() {
  local host="$1" aud="$2" method="$3" path="$4" extra="$5" err
  if [ "$aud" = "-" ]; then
    local body code
    body="$(mktemp)"
    code="$(curl -sS -m 15 -o "$body" -w '%{http_code}' "https://$host$path" 2>&1 || true)"
    echo "HTTP $code $(head -c 400 "$body")"; rm -f "$body"; return 0
  fi
  local args=()
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2206
    args=($extra)
  fi
  if err="$(az rest --method "$method" --resource "$aud" --url "https://$host$path" ${args[@]+"${args[@]}"} -o none 2>&1)"; then
    echo "ok"
  else
    echo "$err" | grep -v -i '^warning'
  fi
}

# First IPv4 answer for a name, after CNAMEs. Uses nslookup, not dig, so the same script runs in Git Bash
# on the Windows jumpbox (w1-jump). Works with both the macOS/BIND and the Windows nslookup output: the
# answer section starts at the first "Name:" line, and the resolver's own address comes before it.
resolve() {
  nslookup "$1" 2>/dev/null | tr -d '\r' \
    | awk '/^Name:/ {seen=1; next} seen' \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true
}

is_private_ip() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; }

check_network() { # $1 outside|inside
  local where="$1" label host aud method path extra pattern rbacfirst ip result
  echo "Network: data planes from $where the VNet (C5, trust boundaries 2 and 3)"
  while IFS='|' read -r label host aud method path extra pattern rbacfirst; do
    [ -z "$label" ] && continue
    ip="$(resolve "$host")"
    result="$(call "$host" "$aud" "$method" "$path" "$extra")"
    if [ "$where" = "outside" ]; then
      if [ -n "$ip" ] && is_private_ip "$ip"; then fail "$label DNS $host resolves to a private IP from outside"
      else pass "$label DNS $host -> public answer ($(echo "$ip" | sed -E 's/\.[0-9]+$/.x/'))"; fi
      if echo "$result" | grep -qF "$pattern"; then
        pass "$label refused: $(echo "$result" | mask)"
      elif [ "$result" = "ok" ]; then
        fail "$label REACHABLE from outside"
      elif [ "$rbacfirst" = "1" ] && echo "$result" | grep -q "PermissionDenied"; then
        inconclusive "$label RBAC checked before network: $(echo "$result" | mask)"
      else
        fail "$label unexpected response: $(echo "$result" | mask)"
      fi
    else
      if [ -n "$ip" ] && [[ "$ip" == "$PE_SUBNET_PREFIX"* ]]; then pass "$label DNS $host -> $ip (private endpoint subnet)"
      else fail "$label DNS $host -> ${ip:-no answer} (expected ${PE_SUBNET_PREFIX}x)"; fi
      if echo "$result" | grep -qF "$pattern"; then
        fail "$label still refused from inside: $(echo "$result" | mask)"
      elif [ "$result" = "ok" ] || echo "$result" | grep -q "^HTTP 2"; then
        pass "$label reached and answered"
      else
        pass "$label reached (no network refusal; data-plane answer: $(echo "$result" | mask))"
      fi
    fi
  done < <(endpoints)
}

case "$MODE" in
  deployments) check_deployments ;;
  outside) check_network outside ;;
  inside) check_network inside ;;
  disks) check_disks ;;
  sandboxes) check_sandboxes ;;
  residency) check_residency ;;
  all) check_deployments; echo; check_disks; echo; check_sandboxes; echo; check_residency; echo; check_network outside ;;
  *) echo "Unknown mode: $MODE. Supported: deployments, outside, inside, disks, sandboxes, residency, all" >&2; exit 2 ;;
esac

echo
echo "verify.sh ($MODE): $FAILURES failed, $INCONCLUSIVE inconclusive"
[ "$FAILURES" -eq 0 ]
