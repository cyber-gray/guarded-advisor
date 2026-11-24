#!/usr/bin/env bash
# Informational region check. Lists models offered in a region and whether
# API Management and Container Apps Sandboxes are offered there. Changes nothing.
set -euo pipefail

REGION="${1:?Usage: ./scripts/check-region.sh <region>, for example canadacentral}"
norm() { printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]'; }

echo "Region: $REGION"
echo
echo "Chat-capable model families offered here (name, version, format):"
az cognitiveservices model list -l "$REGION" \
  --query "[].[model.name, model.version, model.format]" -o tsv 2>/dev/null \
  | grep -Ei '^(gpt|o[0-9]|phi|mistral|llama)' | sort -u | column -t || echo "  (none returned, or the query failed)"

echo
printf "API Management offered in this region: "
found="no"
while IFS= read -r loc; do
  [ "$(norm "$loc")" = "$(norm "$REGION")" ] && found="yes"
done < <(az provider show -n Microsoft.ApiManagement \
  --query "resourceTypes[?resourceType=='service'].locations[]" -o tsv 2>/dev/null)
echo "$found"

printf "Container Apps Sandboxes (sandboxGroups) offered in this region: "
found="no"
while IFS= read -r loc; do
  [ "$(norm "$loc")" = "$(norm "$REGION")" ] && found="yes"
done < <(az provider show -n Microsoft.App \
  --query "resourceTypes[?resourceType=='sandboxGroups'].locations[]" -o tsv 2>/dev/null)
echo "$found"

cat <<'LINKS'

This script can't confirm two things. Check them on Microsoft Learn:
  Standard v2 tier by region:
    https://learn.microsoft.com/azure/api-management/api-management-region-availability
  Foundry Agent Service private networking and model region support:
    https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks
    https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure
  Container Apps Sandboxes:
    https://learn.microsoft.com/azure/container-apps/sandboxes-overview
LINKS
