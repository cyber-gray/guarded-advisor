#!/usr/bin/env bash
# Suspend APIM's built-in all-access subscription ('master') right after infra/apim.bicep is deployed (w2-apim, C3).
# Laptop, as T with Owner active (an Azure write: its own yes, like the deploy).
#
# Why a script, not the template: a PUT of 'master' with its service scope '/' passed what-if and failed at deploy on
# 2026-11-13 ("Subscription scope should be one of '/apis', '/apis/{apiId}', '/products/{productId}'"; findings). This
# is the call that worked that day: Subscription - Update, PATCH at api-version 2024-05-01, header If-Match: *, body
# {"properties":{"state":"suspended"}}
# (https://learn.microsoft.com/rest/api/apimanagement/subscription/update?view=rest-apimanagement-2024-05-01).
#
# The PATCH response returns both subscription keys (findings, 2026-11-13), although a GET doesn't. So the response is
# never written to a file or printed: it goes straight into jq, which keeps only properties.state. The read-back is a
# GET, which returns no keys.
#
# Usage: bash scripts/apim_suspend_master.sh            (asks before the PATCH)
set -Eeuo pipefail
umask 077
# Any failed command (a guard read, the GET, the PATCH) stops the script here with one fixed line, so a failure never
# reads like a pass. -E makes the trap apply inside functions too. The PATCH body is still never stored or printed.
on_err() { echo "STOP: a command failed; master state unknown; don't open the gateway"; }
trap on_err ERR
LAB_RG=rg-guardedadvisor-lab
API_VERSION=2024-05-01
P1=~/guarded-advisor-private/pim-2026-11/p1-t-and-g.json
az() { command az "$@" </dev/null; }
mask() { local v=$1; if [ "${#v}" -gt 8 ]; then printf '%s...%s' "${v:0:4}" "${v: -4}"; else printf '%s' "$v"; fi; }

# Guards: the lab subscription (from P1) and T.
[ -f "$P1" ] || { echo "STOP: $P1 is missing"; exit 1; }
SUB=$(az account show --query id -o tsv)
LAB=$(jq -r '[.[] | select(.roleDefinitionName=="Owner") | .scope | select(test("^/subscriptions/[^/]+$")) | sub("^/subscriptions/";"")] | unique | if length==1 then .[0] else error("expected one subscription in P1") end' "$P1")
[ -n "$SUB" ] && [ "$SUB" = "$LAB" ] || { echo "STOP: wrong subscription"; exit 1; }
ME=$(az ad signed-in-user show --query id -o tsv)
[ "$(mask "$ME")" = "6d4c...2a4d" ] || { echo "STOP: signed-in account is not T"; exit 1; }

NAMES=$(az apim list -g "$LAB_RG" --query "[].name" -o tsv)
[ "$(printf '%s\n' "$NAMES" | grep -c .)" = 1 ] || { echo "STOP: expected exactly one API Management instance in $LAB_RG"; exit 1; }
APIM=$NAMES
URL="https://management.azure.com/subscriptions/$SUB/resourceGroups/$LAB_RG/providers/Microsoft.ApiManagement/service/$APIM/subscriptions/master?api-version=$API_VERSION"
echo "now $(date -u +%Y-%m-%dT%H:%M:%SZ) | subscription $(mask "$SUB") | signed in $(mask "$ME") | APIM $APIM"

before=$(az rest --method get --url "$URL" -o json | jq -r '"\(.properties.state) \(.properties.scope)"')
echo "master before: state ${before% *} | scope ${before#* }"
if [ "${before% *}" = suspended ]; then echo "already suspended; nothing to do"; exit 0; fi

read -r -p "PATCH master to state suspended on $APIM? [y/N] " answer </dev/tty
[ "$answer" = y ] || { echo "not changed"; exit 1; }
# The body is piped to jq and never stored: it holds primaryKey and secondaryKey.
state=$(az rest --method patch --url "$URL" --headers "If-Match=*" --body '{"properties":{"state":"suspended"}}' -o json \
  | jq -r '.properties.state')
echo "PATCH returned state: $state (keys in the response were not stored or printed)"

after=$(az rest --method get --url "$URL" -o json | jq -r '"\(.properties.state) \(.properties.scope)"')
echo "read-back (GET): state ${after% *} | scope ${after#* }"
if [ "${after% *}" != suspended ]; then echo "FINDING: master isn't suspended"; exit 1; fi
echo "ok | master suspended"
