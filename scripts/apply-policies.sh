#!/usr/bin/env bash
# Creates the custom Azure Policy definitions (subscription scope) and the resource-group assignments
# for the lab (w1-policy, D-017). Idempotent: rerunning updates definitions and assignments in place.
#
# Usage:
#   ./scripts/apply-policies.sh definitions   Create or update the custom definitions in the subscription
#   ./scripts/apply-policies.sh assign        Deploy the assignments to both resource groups
#   ./scripts/apply-policies.sh all           Both, in that order
#
# Run `all` again after `scripts/teardown.sh all`: assignments at resource-group scope are deleted
# with the group. New assignments take about 15 minutes to take effect
# (https://learn.microsoft.com/azure/foundry/how-to/model-deployment-policy).
set -euo pipefail

MODE="${1:?Usage: $0 definitions|assign|all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEF_DIR="$ROOT/infra/policies/azure-policy"
LAB_RG="rg-guardedadvisor-lab"
SHARED_RG="rg-guardedadvisor-shared"
SUB_ID="$(az account show --query id -o tsv)"

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

apply_definitions() {
  echo "Subscription: $SUB_ID"
  echo "Custom policy definitions to create or update (subscription scope):"
  for f in "$DEF_DIR"/*.json; do echo "  $(jq -r .name "$f"): $(jq -r .properties.displayName "$f")"; done
  confirm "Create or update these definitions at subscription scope?" || { echo "Nothing changed."; return 0; }
  local f name tmp
  tmp="$(mktemp -d)"
  for f in "$DEF_DIR"/*.json; do
    name="$(jq -r .name "$f")"
    jq .properties.policyRule "$f" > "$tmp/rule.json"
    jq .properties.parameters "$f" > "$tmp/params.json"
    az policy definition create --name "$name" \
      --display-name "$(jq -r .properties.displayName "$f")" \
      --description "$(jq -r .properties.description "$f")" \
      --mode "$(jq -r .properties.mode "$f")" \
      --metadata "$(jq -c .properties.metadata "$f")" \
      --rules "$tmp/rule.json" --params "$tmp/params.json" \
      --query "{name:name, mode:mode}" -o tsv
  done
  rm -rf "$tmp"
}

apply_assignments() {
  echo "Assignments: $LAB_RG (all workload policies) and $SHARED_RG (allowed locations)."
  confirm "Deploy the assignments (all Deny)?" || { echo "Nothing changed."; return 0; }
  az deployment group create -g "$LAB_RG" --name "ga-policy-$(date +%Y%m%d%H%M)" \
    --parameters "$ROOT/infra/policy-assignments.lab.bicepparam" --query "properties.outputs.assignmentNames.value" -o tsv
  az deployment group create -g "$SHARED_RG" --name "ga-policy-$(date +%Y%m%d%H%M)" \
    --parameters "$ROOT/infra/policy-assignments.shared.bicepparam" --query "properties.outputs.assignmentNames.value" -o tsv
  echo "Done. Wait about 15 minutes before testing."
}

case "$MODE" in
  definitions) apply_definitions ;;
  assign) apply_assignments ;;
  all) apply_definitions; apply_assignments ;;
  *) echo "Unknown mode: $MODE. Supported: definitions, assign, all" >&2; exit 1 ;;
esac
