#!/usr/bin/env bash
# Jumpbox and per-session Bastion (w1-jump, D-004, D-018). Shows what it will do and asks before any change.
#
# Usage:
#   ./scripts/jumpbox.sh up            Session start: deploy Bastion Basic (infra/bastion.bicep), harden the OS disk
#                                      if needed, start the jumpbox. Bills about CAD 0.35/hour until `down`.
#   ./scripts/jumpbox.sh down          Same as `teardown.sh jumpbox`: Reader assignments on the Bastion host, its
#                                      diagnostic setting, the host, its public IP, then deallocate the jumpbox.
#   ./scripts/jumpbox.sh harden-disk   Idempotent: set the OS disk to networkAccessPolicy DenyAll and
#                                      publicNetworkAccess Disabled. Skips if both are already set; otherwise
#                                      deallocates, patches and starts the VM again if it was running.
#   ./scripts/jumpbox.sh create        Rebuild only: deploy infra/jumpbox.bicep, then harden-disk. Not part of the
#                                      session routine: each deploy generates a new (unused) local admin password.
#
# Why harden-disk is a script step and not Bicep: docs/runbook.md (2026-10-16). verify.sh disks checks for drift.
# Prices: infra/bastion.bicep header (Retail Prices API, CAD, canadaeast, 2026-10-16).
set -euo pipefail

MODE="${1:?Usage: $0 up|down|harden-disk|create}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-guardedadvisor-lab}"
VM_NAME="${VM_NAME:-ga-jump-lab}"

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

signed_in_object_id() { az ad signed-in-user show --query id -o tsv; }

power_state() {
  az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv
}

# Prints "<networkAccessPolicy><TAB><publicNetworkAccess>" on one line. The nested [[...]] matters: a flat
# --query "[a, b]" -o tsv prints each value on its own line, so `read -r a b` would fill only the first
# (tested 2026-10-16 on a lab NIC).
disk_network_settings() {
  az disk show -g "$RESOURCE_GROUP" -n "$1" --query "[[networkAccessPolicy, publicNetworkAccess]]" -o tsv
}

harden_disk() {
  local disk nap pna state
  disk=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query storageProfile.osDisk.name -o tsv)
  read -r nap pna < <(disk_network_settings "$disk")
  echo "OS disk $disk: networkAccessPolicy=$nap publicNetworkAccess=$pna"
  if [ "$nap" = "DenyAll" ] && [ "$pna" = "Disabled" ]; then
    echo "  Already DenyAll and Disabled. Nothing to do."
    return 0
  fi
  state=$(power_state)
  echo "  Will set DenyAll and Disabled. The VM ($state) is deallocated first and started again if it was running."
  confirm "Harden the OS disk now?" || { echo "Nothing changed."; return 1; }
  if [ "$state" != "PowerState/deallocated" ]; then
    az vm deallocate -g "$RESOURCE_GROUP" -n "$VM_NAME"
  fi
  az disk update -g "$RESOURCE_GROUP" -n "$disk" --network-access-policy DenyAll --public-network-access Disabled -o none
  read -r nap pna < <(disk_network_settings "$disk")
  echo "  Now: networkAccessPolicy=$nap publicNetworkAccess=$pna"
  if [ "$state" = "PowerState/running" ]; then
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME"
    echo "  Started $VM_NAME again."
  fi
}

up() {
  echo "Session start in $RESOURCE_GROUP:"
  echo "  1. Deploy Bastion Basic and its Standard public IP (infra/bastion.bicep): CAD 0.2691 + 0.0071 per hour."
  echo "  2. Check the jumpbox OS disk settings (harden-disk; skips if already set)."
  echo "  3. Start $VM_NAME: CAD 0.0771 per hour while running."
  confirm "Continue?" || { echo "Nothing changed."; return 0; }
  az deployment group create -g "$RESOURCE_GROUP" -n "ga-bastion-$(date -u +%Y%m%d%H%M)" \
    -f "$ROOT/infra/bastion.bicep" -p "$ROOT/infra/bastion.bicepparam" \
    -p adminObjectId="$(signed_in_object_id)" -o none
  echo "  Bastion deployed."
  # Bastion is billing from here on, so a declined or failed disk step warns and carries on rather than exiting.
  # Run as a child process: inside an `if` condition bash ignores set -e, so a failing az call in a function
  # called directly here could go unnoticed; the child script keeps its own set -e.
  if ! "$ROOT/scripts/jumpbox.sh" harden-disk; then
    echo "WARNING: Bastion $RESOURCE_GROUP is running (billing) and the OS disk is NOT hardened" >&2
    echo "  (networkAccessPolicy DenyAll / publicNetworkAccess Disabled). Rerun: $0 harden-disk." >&2
    echo "  Continuing to start $VM_NAME. End the session with: scripts/teardown.sh session" >&2
  fi
  if [ "$(power_state)" != "PowerState/running" ]; then
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME"
  fi
  echo "Ready: portal > $VM_NAME > Connect > Bastion > Authentication type 'Microsoft Entra ID (Preview)'."
}

create() {
  if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query id -o tsv >/dev/null 2>&1; then
    echo "Refusing: VM $VM_NAME already exists in $RESOURCE_GROUP. Rebuild = delete it first; redeploying would" >&2
    echo "send a new generated admin password to an existing VM." >&2
    return 1
  fi
  echo "Rebuild: deploy infra/jumpbox.bicep into $RESOURCE_GROUP (VM, NIC, OS disk, extensions, auto-shutdown,"
  echo "role assignments), then harden-disk. Creates an Entra device object for $VM_NAME."
  confirm "Continue?" || { echo "Nothing changed."; return 0; }
  az deployment group create -g "$RESOURCE_GROUP" -n "ga-jumpbox-$(date -u +%Y%m%d%H%M)" \
    -f "$ROOT/infra/jumpbox.bicep" -p "$ROOT/infra/jumpbox.bicepparam" \
    -p adminObjectId="$(signed_in_object_id)" -o none
  echo "  Jumpbox deployed."
  harden_disk
}

case "$MODE" in
  up) up ;;
  down) "$ROOT/scripts/teardown.sh" jumpbox ;;
  harden-disk) harden_disk ;;
  create) create ;;
  *) echo "Unknown mode: $MODE. Supported: up, down, harden-disk, create" >&2; exit 2 ;;
esac
