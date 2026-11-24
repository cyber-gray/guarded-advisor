#!/usr/bin/env bash
# Protect GenAI trace content in the shared workspace (D-021, C5, C6). Shows what it will do and asks before changes.
#
# Usage:
#   ./scripts/protect-trace-content.sh status   Read-only: feature registration, table protection and retention
#   ./scripts/protect-trace-content.sh feature  T1: register the protectGenAISensitiveData preview feature (subscription)
#   ./scripts/protect-trace-content.sh protect  T2: set AppGenAIContent to Protected
#   ./scripts/protect-trace-content.sh retain   T3: set analytics retention of the trace tables to RETENTION_DAYS (7)
#
# Why a script and not Bicep: table settings are changed with PATCH, which leaves each built-in table's schema and plan
# alone; a Bicep table resource is create-or-update and would have to restate them
# (https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure). Recorded in docs/runbook.md.
# Sources:
#   https://learn.microsoft.com/azure/foundry/observability/how-to/traces-sensitive-content (routing flag, protection)
#   https://learn.microsoft.com/azure/azure-monitor/logs/protected-tables-configure (protectionLevel, verification)
set -euo pipefail

MODE="${1:?Usage: $0 status|feature|protect|retain}"
SHARED_RG="${SHARED_RG:-rg-guardedadvisor-shared}"
WORKSPACE="${WORKSPACE:-ga-law-shared}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TABLES_RETAIN=(AppGenAIContent AppDependencies AppTraces AppEvents)
# protectionLevel exists only from api-version 2026-03-01. With 2025-02-01 (the version in Learn's example) and 2025-07-01
# the property isn't in the schema: a PATCH that sets it returns success and changes nothing (seen 2026-10-22).
API="2026-03-01"

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

sub=$(az account show --query id -o tsv)
ws_id="/subscriptions/$sub/resourceGroups/$SHARED_RG/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE"

table_line() {
  az rest --method get --url "https://management.azure.com$ws_id/tables/$1?api-version=$API" \
    --query "[name, properties.protectionLevel, properties.retentionInDays, properties.totalRetentionInDays]" -o tsv \
    | paste -sd ' ' - | awk '{printf "  %-16s protection=%s retention=%s total=%s\n", $1, ($2==""?"null":$2), $3, $4}'
}

status() {
  echo "Feature Microsoft.Insights/protectGenAISensitiveData: $(az feature show --namespace Microsoft.Insights \
    --name protectGenAISensitiveData --query properties.state -o tsv 2>/dev/null || echo NotRegistered)"
  echo "Workspace $WORKSPACE tables:"
  for t in "${TABLES_RETAIN[@]}"; do table_line "$t"; done
}

case "$MODE" in
  status) status ;;
  feature)
    status
    echo "Will register the preview feature protectGenAISensitiveData on subscription ${sub:0:8}-..., then re-register the"
    echo "Microsoft.Insights provider so it takes effect. New GenAI content then goes only to AppGenAIContent."
    confirm "Register it?" || { echo "Nothing changed."; exit 0; }
    az feature register --namespace Microsoft.Insights --name protectGenAISensitiveData --query properties.state -o tsv
    az provider register --namespace Microsoft.Insights
    echo "Registration can take a while; rerun '$0 status' until the state is Registered."
    ;;
  protect)
    table_line AppGenAIContent
    echo "Will set AppGenAIContent to Protected: standard read roles get zero rows; only Privileged Monitoring Data Reader"
    echo "(or a custom role with a protectionLevel condition) can read it."
    confirm "Protect it?" || { echo "Nothing changed."; exit 0; }
    az rest --method patch --url "https://management.azure.com$ws_id/tables/AppGenAIContent?api-version=$API" \
      --body '{"properties": {"protectionLevel": "Protected"}}' -o none
    table_line AppGenAIContent
    # Fail loudly if the change didn't stick, instead of trusting a successful response.
    level=$(az rest --method get --url "https://management.azure.com$ws_id/tables/AppGenAIContent?api-version=$API" \
      --query properties.protectionLevel -o tsv)
    if [ "$level" != "Protected" ]; then
      echo "ERROR: protectionLevel is '$level' after the PATCH, not 'Protected'." >&2
      exit 1
    fi
    ;;
  retain)
    for t in "${TABLES_RETAIN[@]}"; do table_line "$t"; done
    echo "Will set analytics retention to $RETENTION_DAYS days (and total retention to the same) on: ${TABLES_RETAIN[*]}."
    echo "Learn: Azure Monitor waits 30 days before removing data when total retention is shortened, and retention under"
    echo "31 days doesn't lower cost; this limits how long trace content stays queryable, not the bill."
    confirm "Apply?" || { echo "Nothing changed."; exit 0; }
    for t in "${TABLES_RETAIN[@]}"; do
      az rest --method patch --url "https://management.azure.com$ws_id/tables/$t?api-version=$API" \
        --body "{\"properties\": {\"retentionInDays\": $RETENTION_DAYS, \"totalRetentionInDays\": $RETENTION_DAYS}}" -o none
      table_line "$t"
    done
    ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
