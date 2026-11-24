#!/usr/bin/env bash
# Registers the resource providers the lab needs on the current subscription.
# Registration is free. Asks before changing anything.
set -euo pipefail

PROVIDERS=(
  Microsoft.KeyVault Microsoft.CognitiveServices Microsoft.Storage
  Microsoft.MachineLearningServices Microsoft.Search Microsoft.Network
  Microsoft.App Microsoft.ContainerService Microsoft.DocumentDB
  Microsoft.ApiManagement Microsoft.OperationalInsights Microsoft.Insights
  Microsoft.SecurityInsights Microsoft.Security Microsoft.PolicyInsights
  Microsoft.Logic Microsoft.Compute Microsoft.ManagedIdentity
)

SUB_NAME=$(az account show --query name -o tsv)
echo "Subscription: $SUB_NAME"
echo

todo=()
for p in "${PROVIDERS[@]}"; do
  state=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  printf "  %-36s %s\n" "$p" "$state"
  [ "$state" = "Registered" ] || todo+=("$p")
done

if [ "${#todo[@]}" -eq 0 ]; then
  echo
  echo "All providers already registered."
  exit 0
fi

echo
read -r -p "Register ${#todo[@]} provider(s) on '$SUB_NAME'? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }

for p in "${todo[@]}"; do
  az provider register -n "$p" >/dev/null
  echo "  requested: $p"
done

echo
echo "Waiting for registration (up to about 10 minutes)..."
for _ in $(seq 1 60); do
  pending=0
  for p in "${todo[@]}"; do
    [ "$(az provider show -n "$p" --query registrationState -o tsv)" = "Registered" ] || pending=$((pending + 1))
  done
  [ "$pending" -eq 0 ] && { echo "All registered."; exit 0; }
  sleep 10
done
echo "Some providers are still registering. Run this script again in a few minutes."
exit 1
