#!/usr/bin/env bash
# Builds scenarios/$SCENARIO/entitlements.json once the case manager accounts exist (w1-data Part A, G7b; C2).
# Read-only against Entra: looks up each alias's user by UPN prefix, then writes the map keyed by object ID with
# the alias only. No UPN, tenant domain or tenant ID goes into the file. No timestamp, so reruns are stable.
#
# Usage: ./agent/build_entitlements.sh            (SCENARIO=larkfield, UPN_PREFIX=cm-)
set -euo pipefail

SCENARIO="${SCENARIO:-larkfield}"
UPN_PREFIX="${UPN_PREFIX:-cm-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAIMS="$ROOT/scenarios/$SCENARIO/data/claims.json"
OUT="$ROOT/scenarios/$SCENARIO/entitlements.json"

echo "Reading aliases from $CLAIMS; looking up Entra users ${UPN_PREFIX}<alias>@... (read-only); writing $OUT"
map='{}'
for alias in $(jq -r '[.claims[].case_manager] | unique[]' "$CLAIMS"); do
  ids=$(az ad user list --filter "startswith(userPrincipalName,'${UPN_PREFIX}${alias}@')" --query "[].id" -o tsv)
  count=$(printf '%s' "$ids" | grep -c . || true)
  if [ "$count" != "1" ]; then
    echo "Expected exactly one user for alias '$alias', found $count. Has G7b run?" >&2
    exit 1
  fi
  map=$(jq --arg id "$ids" --arg a "$alias" '. + {($id): $a}' <<<"$map")
  echo "  $alias -> ${ids:0:8}-..."
done

jq -n --argjson map "$map" --arg scenario "$SCENARIO" --slurpfile claims "$CLAIMS" '
  {
    scenario: $scenario,
    note: "Keys are Entra object IDs of synthetic case manager accounts in the Guarded Advisor lab tenant. Read by get_claim_summary when SCENARIO=\($scenario) (C2). Built by agent/build_entitlements.sh.",
    caseloads: ($map | to_entries | sort_by(.value) | map(.value as $alias | {key: .key, value: {alias: $alias,
      claims: ([$claims[0].claims[] | select(.case_manager == $alias) | .claim_id] | sort)}}) | from_entries)
  }' > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT ($(jq '.caseloads | length' "$OUT") case managers)."
