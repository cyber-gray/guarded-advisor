#!/usr/bin/env bash
# Creates or updates the lab's monthly cost budget (d0-budget, w1-cost).
# Budgets are free. A budget warns; it does not stop spending. Asks before changing anything.
#
# Usage: ./scripts/create-budget.sh <alert-email> [amount]
#
# Scope: the subscription, filtered to the lab's resource groups (D-011), so alerts track only lab
# costs while other projects share the subscription. Override with RESOURCE_GROUPS="<rg> <rg>",
# or RESOURCE_GROUPS= for the whole subscription with no filter.
# The amount is in the billing currency (CAD for this subscription, checked 2026-10-03).
#
# Alerts: Actual at 50%, 80% and 100%, Forecasted at 100% (operator GreaterThan).
# PUT is create-or-update, so rerunning with a new amount adjusts the same budget.
# API reference (api-version 2026-06-01, checked 2026-10-01):
#   https://learn.microsoft.com/rest/api/consumption/budgets/create-or-update
set -euo pipefail

EMAIL="${1:?Usage: $0 <alert-email> [amount]}"
AMOUNT="${2:-50}"
BUDGET_NAME="budget-guardedadvisor-lab"
API_VERSION="2026-06-01"
START_DATE="$(date -u +%Y-%m-01)T00:00:00Z"   # must be the first of a month

RESOURCE_GROUPS="${RESOURCE_GROUPS-rg-guardedadvisor-lab rg-guardedadvisor-shared}"

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
for rg in $RESOURCE_GROUPS; do
  az group show --name "$rg" >/dev/null 2>&1 \
    || { echo "Resource group '$rg' doesn't exist. Create it first." >&2; exit 1; }
done
URL="https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/$BUDGET_NAME?api-version=$API_VERSION"
# Budget filter on the ResourceGroupName dimension; empty means no filter.
FILTER=$(printf '%s\n' $RESOURCE_GROUPS | jq -R . | jq -s \
  'if length == 0 then {} else {dimensions: {name: "ResourceGroupName", operator: "In", values: .}} end')

notification() { # threshold, thresholdType
  jq -n --arg email "$EMAIL" --argjson t "$1" --arg type "$2" \
    '{enabled: true, operator: "GreaterThan", threshold: $t, thresholdType: $type, contactEmails: [$email], locale: "en-us"}'
}

BODY=$(jq -n \
  --argjson amount "$AMOUNT" --arg start "$START_DATE" --argjson filter "$FILTER" \
  --argjson a50 "$(notification 50 Actual)" \
  --argjson a80 "$(notification 80 Actual)" \
  --argjson a100 "$(notification 100 Actual)" \
  --argjson f100 "$(notification 100 Forecasted)" \
  '{properties: {category: "Cost", amount: $amount, timeGrain: "Monthly",
     timePeriod: {startDate: $start},
     filter: $filter,
     notifications: {
       Actual_GreaterThan_50_Percent: $a50,
       Actual_GreaterThan_80_Percent: $a80,
       Actual_GreaterThan_100_Percent: $a100,
       Forecasted_GreaterThan_100_Percent: $f100}}}')

echo "Subscription: $SUB_NAME"
if [ -n "$RESOURCE_GROUPS" ]; then
  echo "Scope:        subscription, filtered to resource groups: $RESOURCE_GROUPS"
else
  echo "Scope:        whole subscription, no filter"
fi
echo "Budget:       $BUDGET_NAME, $AMOUNT (billing currency) monthly, starting $START_DATE"
echo "Alerts:       Actual 50/80/100%, Forecasted 100%, sent to $EMAIL"
echo
if [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Create or update this budget? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
fi

az rest --method put --url "$URL" --body "$BODY" -o json |
  jq '{name, amount: .properties.amount, timeGrain: .properties.timeGrain,
       start: .properties.timePeriod.startDate,
       resourceGroups: (.properties.filter.dimensions.values // "all"),
       alerts: [.properties.notifications | to_entries[] | "\(.value.thresholdType) \(.value.threshold)%"]}'
