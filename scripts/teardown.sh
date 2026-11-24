#!/usr/bin/env bash
# Tears down billable lab resources. Shows what it found and asks before deleting anything.
# Never touches rg-guardedadvisor-shared (Log Analytics and Sentinel, D-011).
#
# Usage:
#   ./scripts/teardown.sh session   End of EVERY working session (D-010): apim mode, sandboxes mode, then jumpbox
#                                   mode.
#                                   The core stack stays up, including over weekends.
#   ./scripts/teardown.sh jumpbox   Remove the per-session Bastion (D-018) in this order: Reader assignments
#                                   on the host, its diagnostic setting, the host, its public IP. Then
#                                   deallocate the jumpbox and check that no role assignment is left on a
#                                   Bastion scope. AzureBastionSubnet stays (main.bicep).
#   ./scripts/teardown.sh precheck  Read-only. Stops unless the caller can delete role assignments on the lab group.
#                                   session and jumpbox modes run the same check on each Bastion before any change.
#   ./scripts/teardown.sh sandboxes List the sandboxes left in the sandbox group (D-025), show the count, and delete
#                                   them. The group itself stays.
#   ./scripts/teardown.sh apim      Remove API Management (infra/apim.bicep) in order: the Content Safety role,
#                                   diagnostic settings, private endpoints, the privatelink.azure-api.net zone,
#                                   then the instance and (its own prompt) the purge. Each step reads back.
#   ./scripts/teardown.sh all       Full teardown of the core stack (w1-fork). Only for w3-teardown or an
#                                   absence of more than 2 to 3 days (D-010). Set FINAL=1 for
#                                   w3-teardown so the empty resource group isn't recreated.
#
# A deleted APIM instance is soft-deleted for 48 hours and its name can't be reused until it's
# purged (https://learn.microsoft.com/azure/api-management/soft-delete, checked 2026-10-04).
# Full teardown must run in this order, or the next deploy fails with "Subnet already in use":
#   1. apim mode above
#   2. delete the project capability host, then the account capability host (the account one took about 35 minutes
#      on 2026-11-18; the wait is CAPHOST_WAIT_MINUTES, default 45)
#   3. delete the account's projects (the account delete fails with CannotDeleteResource while one exists;
#      findings 2026-11-18, "Full teardown: the Foundry account delete is blocked by its project...")
#   4. delete and purge the Foundry account
#   5. purge any account from this group that an earlier run deleted but couldn't purge (it still holds the subnet)
#   6. wait for the agent subnet's service association links to clear (usually <20 min, up to 24 h)
#   7. delete the resource group, then purge soft-deleted Cognitive Services resources
# Reference: infra/upstream-tools/deleteCapHost.sh and cleanup.ps1 (foundry-samples, D-001a); the sample's order has
# no project step (step 3 is ours). Unlike
# deleteCapHost.sh, this script calls ARM through `az rest`, so no access token is held in a variable.
# Key Vault has purge protection (D-016): its name stays reserved for 7 days, so a rebuild needs a
# new keyVaultNameSeed in infra/main.bicepparam.
set -euo pipefail

MODE="${1:?Usage: $0 session|jumpbox|precheck|apim|sandboxes|all}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-guardedadvisor-lab}"
LOCATION="${LOCATION:-canadaeast}"
SHARED_RESOURCE_GROUP="rg-guardedadvisor-shared"

if [ "$RESOURCE_GROUP" = "$SHARED_RESOURCE_GROUP" ]; then
  echo "Refusing to run against $SHARED_RESOURCE_GROUP: it holds Log Analytics and Sentinel and outlives teardowns (D-011)." >&2
  exit 1
fi

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# Lowercase (portable to macOS bash 3.2, which lacks ${var,,}).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

ROLE_DELETE_ACTION="Microsoft.Authorization/roleAssignments/delete"

# Stops the script unless the caller holds $ROLE_DELETE_ACTION at scope $1. Under PIM that means an active Owner.
# Read-only. Evaluated per permission entry, as Azure does: matched by actions and not by notActions.
require_role_delete() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Stopped before any change: jq isn't installed, and the permission check needs it (brew install jq)." >&2
    exit 1
  fi
  local scope="$1" perms
  if ! perms=$(az rest --method get -o json \
      --url "https://management.azure.com${scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"); then
    echo "Stopped before any change: couldn't read your permissions on ${scope##*/}." >&2
    exit 1
  fi
  if ! jq -e --arg action "$ROLE_DELETE_ACTION" '
      def glob: ascii_downcase | gsub("\\."; "\\.") | gsub("\\*"; ".*") | "^" + . + "$";
      def hit($a; $patterns): any($patterns[]?; . as $p | $a | ascii_downcase | test($p | glob));
      any(.value[]?; hit($action; .actions) and (hit($action; .notActions) | not))
    ' <<<"$perms" >/dev/null; then
    echo "Stopped before any change: no $ROLE_DELETE_ACTION on ${scope##*/}." >&2
    echo "  Activate Owner in PIM, sign in again, then rerun. A new activation can take a few minutes to apply." >&2
    exit 1
  fi
  echo "Pre-check passed: $ROLE_DELETE_ACTION on ${scope##*/}."
}

# Removing a Bastion includes its Reader assignment, so check the right before anything changes.
precheck_bastion() {
  local hosts h id
  if ! hosts=$(az network bastion list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv); then
    echo "Stopped before any change: couldn't list Bastion hosts in $RESOURCE_GROUP." >&2
    exit 1
  fi
  for h in $hosts; do
    id=$(az network bastion show -g "$RESOURCE_GROUP" -n "$h" --query id -o tsv)
    require_role_delete "$id"
  done
}

# API Management (w2-apim, infra/apim.bicep). Removed in this order, each step read back:
#   1. every role assignment held by the instance's system-assigned identity: Cognitive Services User on the Content
#      Safety account (Bicep), and Cognitive Services OpenAI User on the Foundry account if the portal AI gateway flow
#      or the run sheet added it. The identity exists only for this session, so all of its roles go; each scope gets
#      the require_role_delete check before anything changes.
#   2. the instance's diagnostic settings
#   3. its private endpoints (they bill by the hour on their own)
#   4. the privatelink.azure-api.net VNet links, then the zone
#   5. the instance, then the purge, which has its own prompt (soft-delete keeps it 48 hours:
#      https://learn.microsoft.com/azure/api-management/soft-delete#soft-delete-behavior)
# ApiManagementGatewayLlmLog's retention settings on the shared workspace stay (D-038): rows age out in 4 days.
APIM_DNS_ZONE="privatelink.azure-api.net"

# Role assignments held by principal $1, anywhere in the subscription: "<assignment id> <scope>" per line.
apim_identity_roles() {
  az role assignment list --all --assignee-object-id "$1" --query "[].[id, scope]" -o tsv 2>/dev/null
}

# Private endpoints in the resource group that connect to resource ID $1 (compared in lowercase).
apim_private_endpoints() {
  az network private-endpoint list --resource-group "$RESOURCE_GROUP" -o json 2>/dev/null \
    | jq -r --arg id "$(lower "$1")" \
      '.[] | select([.privateLinkServiceConnections[]?.privateLinkServiceId | ascii_downcase] | index($id)) | .name'
}

teardown_apim() {
  echo "Resource group: $RESOURCE_GROUP ($LOCATION)"
  local names n id principal ra scope pe s l
  names=$(az apim list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || true)

  if [ -n "$names" ]; then
    echo "API Management instances (bill by the hour while they exist):"
    printf '  %s\n' $names
    # Before any change: the right to delete role assignments on every scope where an instance's identity holds one.
    for n in $names; do
      principal=$(az apim show -g "$RESOURCE_GROUP" -n "$n" --query identity.principalId -o tsv 2>/dev/null || true)
      [ -n "$principal" ] || continue
      for scope in $(apim_identity_roles "$principal" | cut -f2 | sort -u); do
        require_role_delete "$scope"
      done
    done
    if ! confirm "Remove the instances' role assignments, diagnostic settings, private endpoints and $APIM_DNS_ZONE, then delete these instances?"; then
      echo "Nothing changed. These instances are still billing."
      return 0
    fi
    for n in $names; do
      id=$(az apim show -g "$RESOURCE_GROUP" -n "$n" --query id -o tsv)
      principal=$(az apim show -g "$RESOURCE_GROUP" -n "$n" --query identity.principalId -o tsv 2>/dev/null || true)
      # 1. Every role assignment held by the instance's identity (Content Safety, and Foundry if added)
      if [ -n "$principal" ]; then
        for ra in $(apim_identity_roles "$principal" | cut -f1); do
          az role assignment delete --ids "$ra" && echo "  removed role assignment ${ra##*/} held by $n's identity" \
            || echo "  WARNING: couldn't remove role assignment ${ra##*/} held by $n's identity"
        done
        echo "  read-back: role assignments held by $n's identity: $(apim_identity_roles "$principal" | grep -c .)"
      fi
      # 2. Diagnostic settings
      for s in $(az monitor diagnostic-settings list --resource "$id" --query "[].name" -o tsv 2>/dev/null); do
        az monitor diagnostic-settings delete --resource "$id" --name "$s" && echo "  removed diagnostic setting $s on $n" \
          || echo "  WARNING: couldn't remove diagnostic setting $s on $n"
      done
      echo "  read-back: diagnostic settings on $n: $(az monitor diagnostic-settings list --resource "$id" --query 'length(@)' -o tsv)"
      # 3. Private endpoints
      for pe in $(apim_private_endpoints "$id"); do
        az network private-endpoint delete -g "$RESOURCE_GROUP" -n "$pe" && echo "  deleted private endpoint $pe" \
          || echo "  WARNING: couldn't delete private endpoint $pe"
      done
      echo "  read-back: private endpoints to $n: $(apim_private_endpoints "$id" | grep -c .)"
    done
    # 4. The private DNS zone: VNet links first, then the zone
    if az network private-dns zone show -g "$RESOURCE_GROUP" -n "$APIM_DNS_ZONE" >/dev/null 2>&1; then
      for l in $(az network private-dns link vnet list -g "$RESOURCE_GROUP" -z "$APIM_DNS_ZONE" --query "[].name" -o tsv); do
        az network private-dns link vnet delete -g "$RESOURCE_GROUP" -z "$APIM_DNS_ZONE" -n "$l" --yes \
          && echo "  deleted zone link $l" || echo "  WARNING: couldn't delete zone link $l"
      done
      echo "  read-back: links on $APIM_DNS_ZONE: $(az network private-dns link vnet list -g "$RESOURCE_GROUP" -z "$APIM_DNS_ZONE" --query 'length(@)' -o tsv)"
      az network private-dns zone delete -g "$RESOURCE_GROUP" -n "$APIM_DNS_ZONE" --yes && echo "  deleted zone $APIM_DNS_ZONE" \
        || echo "  WARNING: couldn't delete zone $APIM_DNS_ZONE"
      echo "  read-back: $APIM_DNS_ZONE exists: $(az network private-dns zone show -g "$RESOURCE_GROUP" -n "$APIM_DNS_ZONE" >/dev/null 2>&1 && echo yes || echo no)"
    fi
    # 5. The instance, then the purge (its own prompt)
    for n in $names; do
      echo "Deleting $n (takes a few minutes)..."
      az apim delete --resource-group "$RESOURCE_GROUP" --name "$n" --yes || echo "  WARNING: delete of $n failed"
      echo "  read-back: $n exists: $(az apim show -g "$RESOURCE_GROUP" -n "$n" >/dev/null 2>&1 && echo yes || echo no)"
      if confirm "Purge soft-deleted $n now? Otherwise it's kept for 48 hours and its name can't be reused."; then
        az apim deletedservice purge --location "$LOCATION" --service-name "$n" || echo "  WARNING: purge of $n failed"
        echo "  read-back: $n soft-deleted: $(az apim deletedservice show --location "$LOCATION" --service-name "$n" >/dev/null 2>&1 && echo yes || echo no)"
      else
        echo "  not purged: $n stays soft-deleted for up to 48 hours"
      fi
    done
  else
    echo "No API Management instances in $RESOURCE_GROUP."
    if az network private-dns zone show -g "$RESOURCE_GROUP" -n "$APIM_DNS_ZONE" >/dev/null 2>&1; then
      echo "  left over: $APIM_DNS_ZONE still exists (no instance); remove it by hand or redeploy and rerun"
    fi
  fi

  # Leftovers from an interrupted run: soft-deleted instances block reuse of the name.
  local deleted
  deleted=$(az apim deletedservice list --query "[?location=='$(az account list-locations --query "[?name=='$LOCATION'].displayName" -o tsv)'].name" -o tsv 2>/dev/null || true)
  if [ -n "$deleted" ]; then
    echo "Soft-deleted instances in $LOCATION:"
    printf '  %s\n' $deleted
    if confirm "Purge them?"; then
      for n in $deleted; do
        az apim deletedservice purge --location "$LOCATION" --service-name "$n"
        echo "  purged: $n"
      done
    fi
  fi

  echo "Done. Remaining API Management instances: $(az apim list --resource-group "$RESOURCE_GROUP" --query "length(@)" -o tsv)"
}

# Per-session Bastion (D-018). Order matters: role assignments and the diagnostic setting are removed while
# their scope still exists, so nothing is left orphaned when the host goes.
# A failed removal warns and continues, so it can't strand a billing host; check_bastion_roles reports leftovers.
teardown_bastion() {
  local hosts
  hosts=$(az network bastion list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || true)
  if [ -z "$hosts" ]; then
    echo "No Bastion hosts in $RESOURCE_GROUP."
  else
    echo "Bastion hosts (bill by the hour while they exist, with their public IPs):"
    printf '  %s\n' $hosts
    if confirm "Delete them (Reader assignments, diagnostic setting, host, public IP)?"; then
      local h id pips ra ra_scope ds p
      for h in $hosts; do
        id=$(az network bastion show -g "$RESOURCE_GROUP" -n "$h" --query id -o tsv)
        pips=$(az network bastion show -g "$RESOURCE_GROUP" -n "$h" --query "ipConfigurations[].publicIPAddress.id" -o tsv)
        # Assignments made exactly at the host scope. ARM returns IDs in varying case ("resourcegroups",
        # upper-case names), so compare lowercased in bash rather than with a case-sensitive JMESPath filter.
        while IFS=$'\t' read -r ra ra_scope; do
          [ -z "$ra" ] && continue
          [ "$(lower "$ra_scope")" = "$(lower "$id")" ] || continue
          if az role assignment delete --ids "$ra"; then
            echo "  removed role assignment ${ra##*/} on $h"
          else
            echo "  WARNING: couldn't remove role assignment ${ra##*/} on $h; deleting the host anyway." >&2
          fi
        done < <(az role assignment list --scope "$id" --query "[].[id, scope]" -o tsv)
        for ds in $(az monitor diagnostic-settings list --resource "$id" --query "[].name" -o tsv); do
          if az monitor diagnostic-settings delete --resource "$id" --name "$ds"; then
            echo "  removed diagnostic setting $ds on $h"
          else
            echo "  WARNING: couldn't remove diagnostic setting $ds on $h; deleting the host anyway." >&2
          fi
        done
        echo "  deleting Bastion host $h (takes several minutes)..."
        # --yes: the bastion extension asks its own question, which fails without a TTY (2026-10-19). The
        # script's confirm() above is the approval for this delete.
        az network bastion delete -g "$RESOURCE_GROUP" -n "$h" --yes
        echo "  deleted: $h"
        for p in $pips; do
          az network public-ip delete --ids "$p"
          echo "  deleted public IP ${p##*/}"
        done
      done
    else
      echo "Nothing changed. The Bastion hosts are still billing."
      return 0
    fi
  fi

  # Leftovers from an interrupted run: the Bastion's public IP without its host.
  local orphans
  orphans=$(az network public-ip list -g "$RESOURCE_GROUP" --query "[?starts_with(name, 'ga-pip-bas-') && ipConfiguration==null].name" -o tsv 2>/dev/null || true)
  if [ -n "$orphans" ]; then
    echo "Unattached Bastion public IPs (bill by the hour):"
    printf '  %s\n' $orphans
    if confirm "Delete them?"; then
      for p in $orphans; do az network public-ip delete -g "$RESOURCE_GROUP" -n "$p"; echo "  deleted: $p"; done
    fi
  fi
}

# Role assignments whose scope is a Bastion host in this group should never outlive the host. Case-insensitive,
# because ARM may return the scope as ".../resourcegroups/..." or with upper-case names.
check_bastion_roles() {
  local left="" ra scope want
  want="$(lower "/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/bastionHosts/")"
  while IFS=$'\t' read -r ra scope; do
    [ -z "$ra" ] && continue
    if [[ "$(lower "$scope")" == *"$want"* ]]; then left+="$ra"$'\n'; fi
  done < <(az role assignment list --all --query "[].[id, scope]" -o tsv)
  if [ -n "$left" ]; then
    echo "WARNING: role assignments still scoped to a Bastion host:" >&2
    printf '  %s\n' $left >&2
    return 1
  fi
  echo "No role assignments left on Bastion scopes."
}

# Sandboxes left in the sandbox group (D-025). They bill per second while running, so a crashed client run must not
# leave one behind. Sandboxes live on the sandbox data plane, not ARM: list and delete them with an Entra token for
# https://dynamicsessions.io and data-plane API 2026-02-01-preview (azure-containerapps-sandbox 0.1.0b4). The caller
# needs Container Apps SandboxGroup Data Owner on the group (R10 for T, PIM-eligible: activate it first).
# The group itself stays.
SANDBOX_GROUP="${SANDBOX_GROUP:-ga-sbx-lab}"
SANDBOX_DP_API="2026-02-01-preview"

teardown_sandboxes() {
  if ! az resource show -g "$RESOURCE_GROUP" -n "$SANDBOX_GROUP" --resource-type Microsoft.App/sandboxGroups \
       --query id -o tsv >/dev/null 2>&1; then
    echo "No sandbox group $SANDBOX_GROUP in $RESOURCE_GROUP."
    return 0
  fi
  local sub base out ids count
  sub=$(az account show --query id -o tsv)
  base="https://management.${LOCATION}.azuredevcompute.io/subscriptions/$sub/resourceGroups/$RESOURCE_GROUP/sandboxGroups/$SANDBOX_GROUP"
  if ! out=$(az rest --method get --resource https://dynamicsessions.io \
               --url "$base/sandboxes?api-version=$SANDBOX_DP_API" -o json 2>&1); then
    echo "WARNING: couldn't list sandboxes in $SANDBOX_GROUP (needs SandboxGroup Data Owner on the group, R10: activate it in PIM):" >&2
    echo "  $(printf '%s' "$out" | tail -1 | cut -c1-200)" >&2
    echo "  Check in the Sandboxes portal that none is left running." >&2
    return 0
  fi
  # The list comes back as an array or as {"value": [...]}; only IDs and states are printed.
  ids=$(printf '%s' "$out" | jq -r '(if type == "array" then . else (.value // []) end)[] | .id')
  count=$(printf '%s' "$ids" | grep -c . || true)
  echo "Sandboxes in $SANDBOX_GROUP: $count"
  if [ "$count" -eq 0 ]; then return 0; fi
  # Egress posture per sandbox, by the same rule as verify.sh sandboxes (scripts/lib/sandbox-egress.jq).
  local sbx verdict
  for id in $ids; do
    sbx=$(az rest --method get --resource https://dynamicsessions.io --url "$base/sandboxes/$id?api-version=$SANDBOX_DP_API" -o json)
    verdict=$(jq -r -f "$(dirname "$0")/lib/sandbox-egress.jq" <<<"$sbx")
    echo "  $id  state=$(jq -r '.state // "?"' <<<"$sbx")  ${verdict//$'\t'/ }"
    case "$verdict" in OK*) ;; *) echo "  FLAG: sandbox $id doesn't have default-deny egress with Full inspection (findings 2026-10-23)" ;; esac
  done
  if confirm "Delete all $count sandbox(es)?"; then
    for id in $ids; do
      az rest --method delete --resource https://dynamicsessions.io \
        --url "$base/sandboxes/$id?api-version=$SANDBOX_DP_API" -o none
      echo "  deleted sandbox: $id"
    done
    out=$(az rest --method get --resource https://dynamicsessions.io --url "$base/sandboxes?api-version=$SANDBOX_DP_API" -o json)
    echo "Sandboxes left in $SANDBOX_GROUP: $(printf '%s' "$out" | jq '(if type == "array" then . else (.value // []) end) | length')"
  else
    echo "Left in place."
  fi
}

deallocate_vms() {
  local vms
  vms=$(az vm list --resource-group "$RESOURCE_GROUP" --show-details \
    --query "[?powerState!='VM deallocated'].name" -o tsv 2>/dev/null || true)
  if [ -z "$vms" ]; then
    echo "No running or stopped-but-allocated VMs in $RESOURCE_GROUP."
    return 0
  fi
  echo "VMs still allocated (compute bills until deallocated):"
  printf '  %s\n' $vms
  if confirm "Deallocate them?"; then
    for v in $vms; do
      az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$v"
      echo "  deallocated: $v"
    done
  else
    echo "Left running."
  fi
}

CAPHOST_API="2025-04-01-preview"   # same API version as infra/modules-network-secured
# Projects: the API version of the manual DELETE on 2026-11-18 (findings, "Full teardown..."). accounts/projects exists
# at 2025-06-01: https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2025-06-01/accounts/projects
PROJECT_API="2025-06-01"
SAL_WAIT_MINUTES="${SAL_WAIT_MINUTES:-30}"
CAPHOST_WAIT_MINUTES="${CAPHOST_WAIT_MINUTES:-45}"  # the account capability host took about 35 minutes on 2026-11-18
PROJECT_WAIT_MINUTES="${PROJECT_WAIT_MINUTES:-20}"
POLL_SECONDS="${POLL_SECONDS:-10}"                  # waits count 6 polls per minute; the tests set 0

# State of ARM URL $1: returns 0 if a GET succeeds (present), 1 if it says not found (gone), 2 for any other error.
arm_state() {
  local err
  if err=$(az rest --method get --url "$1" -o none 2>&1); then return 0; fi
  case "$err" in
    *NotFound*|*"Not Found"*|*404*) return 1 ;;
    *) echo "  couldn't read ${1%%\?*}: $(printf '%s' "$err" | tail -1 | cut -c1-200)" >&2; return 2 ;;
  esac
}

# Polls ARM URL $1 until it's gone, for up to $2 minutes (6 polls a minute), printing progress once a minute.
# Returns 0 when gone, 1 on timeout, 2 if the state can't be read.
wait_until_gone() {
  local url="$1" minutes="$2" label="$3" polls i rc
  polls=$(( minutes * 6 ))
  for (( i = 0; i <= polls; i++ )); do
    arm_state "$url" && rc=0 || rc=$?
    case $rc in 1) return 0 ;; 2) return 2 ;; esac
    if (( i > 0 && i % 6 == 0 )); then
      echo "  ... $label still present, about $(( i / 6 )) of ${minutes} min"
    fi
    if (( i < polls )); then sleep "$POLL_SECONDS"; fi
  done
  return 1
}

# Deletes ARM resource $1 (api-version $2), waits up to $3 minutes for it to go, and prints a STOP line on failure.
# $4 names the kind for messages, $5 is the env var that raises the wait. A resource that's already gone is fine.
delete_and_wait() {
  local id="$1" api="$2" minutes="$3" kind="$4" knob="$5" url rc
  url="https://management.azure.com${id}?api-version=${api}"
  echo "  Deleting $kind ${id##*/} (waiting up to ${minutes} min)..."
  if ! az rest --method delete --url "$url" -o none; then
    arm_state "$url" && rc=0 || rc=$?
    if [ "$rc" = 1 ]; then echo "  Already gone: ${id##*/}"; return 0; fi
    echo "STOP: the delete of $kind ${id##*/} failed and it still exists. Nothing after it was deleted." >&2
    return 1
  fi
  wait_until_gone "$url" "$minutes" "$kind ${id##*/}" && rc=0 || rc=$?
  case $rc in
    0) echo "  Deleted: ${id##*/}" ;;
    1) echo "STOP: $kind ${id##*/} still present after ${minutes} min. Nothing after it was deleted." >&2
       echo "  Check it in the portal, then rerun '$0 all' (set $knob to wait longer)." >&2
       return 1 ;;
    *) echo "STOP: couldn't read the state of $kind ${id##*/}. Nothing after it was deleted; rerun '$0 all'." >&2
       return 1 ;;
  esac
}

delete_caphost() { delete_and_wait "$1" "$CAPHOST_API" "$CAPHOST_WAIT_MINUTES" "capability host" CAPHOST_WAIT_MINUTES; }
delete_project() { delete_and_wait "$1" "$PROJECT_API" "$PROJECT_WAIT_MINUTES" "project" PROJECT_WAIT_MINUTES; }

list_caphosts() {
  az rest --method get --url "https://management.azure.com${1}/capabilityHosts?api-version=${CAPHOST_API}" \
    --query "value[].id" -o tsv 2>/dev/null || true
}

list_projects() {
  az rest --method get --url "https://management.azure.com${1}/projects?api-version=${CAPHOST_API}" \
    --query "value[].id" -o tsv 2>/dev/null || true
}

# Soft-deleted Cognitive Services accounts from this resource group, "<name>\t<location>" per line. ARM may return
# the ID with "resourcegroups" or other casing, so compare lowercased in bash: a JMESPath contains() is
# case-sensitive and matched nothing, without a warning, when the casing differed (STATUS known issues, 2026-11-18).
soft_deleted_accounts() {
  local id name loc want
  want="$(lower "/resourceGroups/$RESOURCE_GROUP/")"
  while IFS=$'\t' read -r id name loc; do
    [ -z "$id" ] && continue
    if [[ "$(lower "$id")" == *"$want"* ]]; then printf '%s\t%s\n' "$name" "${loc:-$LOCATION}"; fi
  done < <(az cognitiveservices account list-deleted --query "[].[id, name, location]" -o tsv 2>/dev/null || true)
}

purge_account() {   # $1 name, $2 location
  if az cognitiveservices account purge -l "$2" -g "$RESOURCE_GROUP" -n "$1"; then
    echo "  Purged: $1"
    return 0
  fi
  echo "  Purge of $1 failed." >&2
  return 1
}

# Purges every soft-deleted account from this group (with a prompt). Returns 1 if any purge fails or is declined.
purge_soft_deleted() {
  local rows name loc failed=0
  rows=$(soft_deleted_accounts)
  if [ -z "$rows" ]; then
    echo "No soft-deleted Cognitive Services accounts from $RESOURCE_GROUP."
    return 0
  fi
  echo "Soft-deleted Cognitive Services accounts from $RESOURCE_GROUP (a Foundry account keeps the agent subnet linked until purged):"
  while IFS=$'\t' read -r name loc; do echo "  $name ($loc)"; done <<<"$rows"
  if ! confirm "Purge them now?"; then
    echo "  Not purged."
    return 1
  fi
  while IFS=$'\t' read -r name loc; do
    purge_account "$name" "$loc" || failed=1
  done <<<"$rows"
  return "$failed"
}

wait_for_subnet_links() {
  local subnets
  subnets=$(az network vnet list -g "$RESOURCE_GROUP" --query "[].subnets[?delegations[?serviceName=='Microsoft.App/environments']].id[]" -o tsv)
  [ -z "$subnets" ] && { echo "No agent subnets found."; return 0; }
  local s i links
  for s in $subnets; do
    echo "Waiting for service association links on ${s##*/} to clear (up to ${SAL_WAIT_MINUTES} min)..."
    for i in $(seq 1 $((SAL_WAIT_MINUTES * 2))); do
      links=$(az network vnet subnet show --ids "$s" --query "length(serviceAssociationLinks || \`[]\`)" -o tsv)
      if [ "$links" = "0" ]; then echo "  Clear: ${s##*/}"; continue 2; fi
      sleep 30
    done
    echo "  Links still present on ${s##*/}. They can take up to 24 hours. Rerun '$0 all' later;" >&2
    echo "  the resource group is left in place until they clear." >&2
    return 1
  done
}

teardown_all() {
  echo "FULL TEARDOWN of $RESOURCE_GROUP ($LOCATION). This deletes the core stack (D-010)."
  echo "Resources now in the group: $(az resource list -g "$RESOURCE_GROUP" --query 'length(@)' -o tsv)"
  confirm "Continue with the full teardown?" || { echo "Nothing changed."; return 0; }

  teardown_apim

  local accounts a acct projects p hosts h left
  accounts=$(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[?kind=='AIServices'].id" -o tsv)
  for a in $accounts; do
    acct="${a##*/}"
    echo "Foundry account: $acct"
    projects=$(list_projects "$a")
    for p in $projects; do
      hosts=$(list_caphosts "$p")
      if [ -z "$hosts" ]; then echo "  No capability host on project ${p##*/}."; fi
      for h in $hosts; do delete_caphost "$h" || return 1; done
    done
    hosts=$(list_caphosts "$a")
    if [ -z "$hosts" ]; then echo "  No capability host on account $acct."; fi
    for h in $hosts; do delete_caphost "$h" || return 1; done

    # account delete has no --ids (its name argument has no id_part in azure-cli 2.90.0), so pass -g and -n.
    if [ -z "$acct" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$LOCATION" ]; then
      echo "STOP: empty account name, resource group or location; nothing deleted." >&2
      return 1
    fi
    if [ -n "$projects" ]; then
      echo "  Projects under $acct (the account delete fails while one exists):"
      for p in $projects; do echo "    ${p##*/}"; done
    fi
    if confirm "Delete the projects listed above (if any), then delete and purge Foundry account $acct?"; then
      for p in $projects; do delete_project "$p" || return 1; done
      left=$(list_projects "$a")
      if [ -n "$left" ]; then
        echo "STOP: projects still listed under $acct: $(for p in $left; do printf '%s ' "${p##*/}"; done)" >&2
        echo "  The account wasn't deleted. Rerun '$0 all'." >&2
        return 1
      fi
      if ! az cognitiveservices account delete -g "$RESOURCE_GROUP" -n "$acct"; then
        echo "STOP: the delete of account $acct failed. Nothing after it was deleted; rerun '$0 all'." >&2
        return 1
      fi
      if ! purge_account "$acct" "$LOCATION"; then
        echo "STOP: $acct is deleted but not purged, so it still holds the agent subnet." >&2
        echo "  Rerun '$0 all': it purges soft-deleted accounts from $RESOURCE_GROUP before the subnet wait." >&2
        return 1
      fi
      echo "  Deleted and purged: $acct"
    else
      echo "Stopped before deleting $acct. The subnet stays linked until it's deleted and purged."
      return 0
    fi
  done

  # Rerun path: an account deleted on an earlier run whose purge failed isn't listed above, but it still holds the
  # agent subnet, so the link wait below could never pass. Purge it first.
  if ! purge_soft_deleted; then
    echo "STOP: a soft-deleted account from $RESOURCE_GROUP isn't purged, so the subnet links won't clear." >&2
    echo "  Resolve the purge (az cognitiveservices account list-deleted shows it), then rerun '$0 all'." >&2
    return 1
  fi

  wait_for_subnet_links || return 1

  if confirm "Delete resource group $RESOURCE_GROUP and everything left in it?"; then
    az group delete -n "$RESOURCE_GROUP" --yes
    echo "Deleted: $RESOURCE_GROUP"
  else
    echo "Resource group kept."; return 0
  fi

  # Accounts the group delete soft-deleted (for example Content Safety). Case-insensitive match (soft_deleted_accounts).
  purge_soft_deleted || echo "  WARNING: soft-deleted accounts from $RESOURCE_GROUP remain; they block reuse of their names." >&2

  if [ "${FINAL:-}" != "1" ]; then
    echo "Recreating the empty resource group with the standard tags (free; keeps the budget filter working)."
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" \
      --tags project=guarded-advisor env=lab owner=tooni managedBy=bicep expires=2026-11-15 -o none
  fi
  echo "Done. Key Vault is soft-deleted with purge protection: bump keyVaultNameSeed before the next deploy (D-016)."
  if [ "${FINAL:-}" != "1" ]; then
    echo "Policy assignments were deleted with the group. Run scripts/apply-policies.sh assign and wait"
    echo "15 minutes before redeploying, so the deploy is checked against the Deny policies (D-017)."
  fi
}

case "$MODE" in
  session) precheck_bastion; teardown_apim; teardown_sandboxes; teardown_bastion; deallocate_vms; check_bastion_roles ;;
  sandboxes) teardown_sandboxes ;;
  jumpbox) precheck_bastion; teardown_bastion; deallocate_vms; check_bastion_roles ;;
  apim) teardown_apim ;;
  all) teardown_all ;;
  precheck) require_role_delete "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP" ;;
  *) echo "Unknown mode: $MODE. Supported: session, jumpbox, precheck, apim, sandboxes, all" >&2; exit 1 ;;
esac
