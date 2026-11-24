#!/usr/bin/env bash
# Sandbox analysis image (w2-sbx-image, D-025 option A). Shows what it will do and asks before changes.
#
# Usage:
#   ./scripts/build-sandbox-image.sh status   Read-only: registry settings, repositories, tags and digests
#   ./scripts/build-sandbox-image.sh import   Import the pinned base image (Docker Official Image python:3.12-slim-
#                                             bookworm, by index digest) into our registry as base/python
#   ./scripts/build-sandbox-image.sh build    Build agent/sandbox-image with ACR Tasks FROM that copy, then record the
#                                             image digest (agent/sandbox-image/IMAGE.txt) and the Python and OS
#                                             package lists from the build log (agent/sandbox-image/PACKAGES.txt)
#   ./scripts/build-sandbox-image.sh register Create disk image ga-analysis in the sandbox group from the digest in
#                                             IMAGE.txt, pulled with the group's user-assigned identity (no registry
#                                             credentials), and wait until it's Ready (A4). Data plane, as the caller
#                                             (SandboxGroup Data Owner on the group, R10). Just-in-time identity: it
#                                             attaches ga-id-sbx-pull-lab to the group (infra/sandbox.bicep) for the run
#                                             and detaches it afterwards, also on failure (trap), then reads back
#
# The build runs in ACR Tasks (no local Docker needed). Its only internet access is the pip download of the
# hash-pinned wheels in the build stage; the base comes from our registry.
# Sources: https://learn.microsoft.com/azure/container-registry/container-registry-import-images
#          https://learn.microsoft.com/azure/container-registry/container-registry-quickstart-task-cli
set -euo pipefail

MODE="${1:?Usage: $0 status|import|build|register}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-guardedadvisor-lab}"
IMAGE_DIR="$ROOT/agent/sandbox-image"
BASE_SOURCE="docker.io/library/python"
BASE_DIGEST="$(sed -n 's/^ARG BASE_DIGEST=//p' "$IMAGE_DIR/Dockerfile")"
BASE_TAG="base/python:3.12-slim-bookworm"
IMAGE_REPO="ga-analysis"
LOCATION="${LOCATION:-canadaeast}"
SANDBOX_GROUP="${SANDBOX_GROUP:-ga-sbx-lab}"
PULL_IDENTITY="${PULL_IDENTITY:-ga-id-sbx-pull-lab}"
SANDBOX_DP_API="2026-02-01-preview"   # azure-containerapps-sandbox 0.1.0b4 (create_disk_image request shape)
TAG="${TAG:-$(date -u +%Y%m%d)}"

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

[[ "$BASE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Couldn't read BASE_DIGEST from the Dockerfile." >&2; exit 2; }
ACR="$(az acr list -g "$RESOURCE_GROUP" --query "[?starts_with(name, 'gaacrlab')].name | [0]" -o tsv)"
[ -n "$ACR" ] || { echo "No gaacrlab* registry in $RESOURCE_GROUP (deploy infra/sandbox-image.bicep first)." >&2; exit 2; }

# Package lists from a build log. The markers are matched as whole lines only: the build log also echoes each RUN
# command, and that line contains the marker text too (first build, 2026-10-24, captured pip's download output).
record_packages() { # $1 build log, $2 image digest
  strip() { sed -E 's/^#[0-9]+ [0-9.]+ //; s/\r$//'; }
  {
    echo "# Packages in $IMAGE_REPO@$2, from the ACR Tasks build log ($(date -u +%Y-%m-%dT%H:%M:%SZ))."
    echo "# Python packages (pip freeze --path /opt/analysis, build stage):"
    strip < "$1" | sed -n '/^=== PYTHON PACKAGES (pip freeze) ===$/,/^=== END PYTHON PACKAGES ===$/p' | grep -v '^===' | sort -u
    echo "# OS packages (dpkg-query, runtime stage):"
    strip < "$1" | sed -n '/^=== OS PACKAGES (dpkg-query) ===$/,/^=== END OS PACKAGES ===$/p' | grep -v '^===' | sort -u
  } > "$IMAGE_DIR/PACKAGES.txt"
}

status() {
  echo "Registry $ACR:"
  az acr show -n "$ACR" --query "{sku:sku.name, adminUserEnabled:adminUserEnabled, anonymousPullEnabled:anonymousPullEnabled, publicNetworkAccess:publicNetworkAccess}" -o tsv \
    | awk -F'\t' '{printf "  sku=%s adminUserEnabled=%s anonymousPullEnabled=%s publicNetworkAccess=%s\n", $1, $2, $3, $4}'
  for repo in $(az acr repository list -n "$ACR" -o tsv); do
    az acr manifest list-metadata -r "$ACR" -n "$repo" --query "[].[digest, join(',', tags || \`[]\`)]" -o tsv \
      | awk -v r="$repo" -F'\t' '{printf "  %s@%s tags=%s\n", r, $1, $2}'
  done
}

case "$MODE" in
  status) status ;;
  import)
    echo "Will import $BASE_SOURCE@$BASE_DIGEST into $ACR as $BASE_TAG (all platforms of the index)."
    confirm "Import?" || { echo "Nothing changed."; exit 0; }
    az acr import -n "$ACR" --source "$BASE_SOURCE@$BASE_DIGEST" --image "$BASE_TAG"
    got="$(az acr repository show -n "$ACR" --image "$BASE_TAG" --query digest -o tsv)"
    if [ "$got" != "$BASE_DIGEST" ]; then
      echo "ERROR: imported digest $got differs from the pinned $BASE_DIGEST." >&2; exit 1
    fi
    echo "Imported: $ACR.azurecr.io/$BASE_TAG@$got (matches the pin)."
    ;;
  build)
    echo "Will build $IMAGE_REPO:$TAG in $ACR (ACR Tasks, linux/amd64) FROM $ACR.azurecr.io/base/python@$BASE_DIGEST,"
    echo "then write $IMAGE_DIR/IMAGE.txt and PACKAGES.txt."
    confirm "Build?" || { echo "Nothing changed."; exit 0; }
    log="$(mktemp)"
    az acr build -r "$ACR" --platform linux/amd64 -t "$IMAGE_REPO:$TAG" \
      --build-arg "BASE_REPO=$ACR.azurecr.io/base/python" -f "$IMAGE_DIR/Dockerfile" "$IMAGE_DIR" 2>&1 | tee "$log"
    digest="$(az acr repository show -n "$ACR" --image "$IMAGE_REPO:$TAG" --query digest -o tsv)"
    record_packages "$log" "$digest"
    {
      echo "# Analysis image for the sandbox (D-025 option A). Reference it by digest, never by tag."
      echo "image=$ACR.azurecr.io/$IMAGE_REPO@$digest"
      echo "tag=$TAG"
      echo "base=$BASE_SOURCE@$BASE_DIGEST (imported as $ACR.azurecr.io/$BASE_TAG)"
      echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$IMAGE_DIR/IMAGE.txt"
    rm -f "$log"
    echo "Built: $ACR.azurecr.io/$IMAGE_REPO@$digest"
    echo "Recorded: agent/sandbox-image/IMAGE.txt, agent/sandbox-image/PACKAGES.txt ($(grep -vc '^#' "$IMAGE_DIR/PACKAGES.txt") packages)"
    ;;
  register)
    image="$(sed -n 's/^image=//p' "$IMAGE_DIR/IMAGE.txt")"
    [[ "$image" =~ ^$ACR\.azurecr\.io/$IMAGE_REPO@sha256:[0-9a-f]{64}$ ]] \
      || { echo "IMAGE.txt has no digest-pinned $IMAGE_REPO image for $ACR." >&2; exit 2; }
    sub="$(az account show --query id -o tsv)"
    # The pull identity's client ID (not a secret): the identity attached to the group in A2, AcrPull on the registry.
    client_id="$(az identity show -g "$RESOURCE_GROUP" -n "$PULL_IDENTITY" --query clientId -o tsv)"
    host="management.${LOCATION}.azuredevcompute.io"
    base="https://$host/subscriptions/$sub/resourceGroups/$RESOURCE_GROUP/sandboxGroups/$SANDBOX_GROUP"
    # Pre-check: never create a second disk image for the same name or digest. List the group's private disk images
    # (GET on the collection, as the SDK's list_disk_images does; the response is an array or {"value": [...]}).
    existing="$(az rest --method get --resource https://dynamicsessions.io --url "$base/diskimages?api-version=$SANDBOX_DP_API" -o json)"
    match="$(jq -c --arg name "$IMAGE_REPO" --arg img "$image" --arg digest "${image##*@}" \
               '(if type == "array" then . else (.value // []) end)
                | map(((.image.base // .source.imageUrl // "")) as $b
                      | select((.labels.name // .name // "") == $name or $b == $img or ($b | endswith("@" + $digest))))
                | map({id, labels, base: (.image.base // .source.imageUrl), state: .status.state})' <<<"$existing")"
    if [ "$(jq 'length' <<<"$match")" -gt 0 ]; then
      echo "A disk image with name=$IMAGE_REPO or digest ${image##*@} already exists in $SANDBOX_GROUP; nothing created:"
      jq '.' <<<"$match"
      exit 0
    fi
    echo "No existing disk image with name=$IMAGE_REPO or this digest ($(jq '(if type == "array" then . else (.value // []) end) | length' <<<"$existing") private images in the group)."
    echo "Will attach $PULL_IDENTITY to $SANDBOX_GROUP, create disk image '$IMAGE_REPO' from $image"
    echo "(pulled with that identity's client ID, no registry credentials, via diskimages/v2), then detach the identity."
    echo "Needs Container Apps SandboxGroup Data Owner on $SANDBOX_GROUP: activate it in PIM first (R10, runbook)."
    confirm "Create it?" || { echo "Nothing changed."; exit 0; }
    # Just-in-time pull identity (IDEAS.md, 2026-10-26): the group carries no identity except during this run, so
    # nothing running in a sandbox can reach one. Attach and detach are deployments of infra/sandbox.bicep (the
    # default param file has pullIdentityName empty), each read back. The trap detaches on any exit.
    group_url="https://management.azure.com/subscriptions/$sub/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.App/sandboxGroups/$SANDBOX_GROUP?api-version=$SANDBOX_DP_API"
    group_state() { az rest --method get --url "$group_url" -o json \
                      | jq -c '{identity: (.identity.type // "None"), allowedLocations: .properties.allowedLocations, maxSandboxCount: .properties.maxSandboxCount}'; }
    deploy_group() { # $1: pull identity name, or empty for none
      az deployment group create -g "$RESOURCE_GROUP" -n "ga-sbx-identity-$(date -u +%Y%m%d%H%M%S)" \
        -f "$ROOT/infra/sandbox.bicep" -p "$ROOT/infra/sandbox.bicepparam" ${1:+-p "pullIdentityName=$1"} \
        --query properties.provisioningState -o tsv
    }
    attached=0; resp_headers=""; resp_body=""
    cleanup_register() {
      rm -f "$resp_headers" "$resp_body"
      if [ "$attached" = 1 ]; then
        echo "Detaching $PULL_IDENTITY from $SANDBOX_GROUP: $(deploy_group "")"
        echo "Group after detach: $(group_state)"
      fi
    }
    trap cleanup_register EXIT
    echo "Group before: $(group_state)"
    attached=1
    echo "Attaching $PULL_IDENTITY to $SANDBOX_GROUP: $(deploy_group "$PULL_IDENTITY")"
    echo "Group during the run: $(group_state)"
    # On data plane 2026-02-01-preview the plain diskimages endpoint ignores managedIdentityResourceId and
    # managedIdentityClientId and pulls anonymously (both A4 attempts, 2026-10-24; findings). The managed-identity pull
    # works only on diskimages/v2 with source.managedIdentityClientId: a maintainer workaround in
    # https://github.com/microsoft/azure-container-apps/issues/1816 (the portal uses diskimages/v2/async and gets 202
    # plus operation-location, issues/1845). Not on Learn, and not in azure-rest-api-specs, which defines only
    # 2026-09-01-preview. Status errors are read from errorMessage, not message (issues/1839).
    body="$(jq -n --arg img "$image" --arg cid "$client_id" --arg name "$IMAGE_REPO" \
             '{source: {kind: "registry", imageUrl: $img, managedIdentityClientId: $cid}, name: $name, labels: {name: $name}}')"
    # The PUT goes through curl because its status code and operation-location header are needed: az rest hides them,
    # and its --verbose or --debug output is ruled out. The token (same audience as every other data-plane call here,
    # https://dynamicsessions.io) reaches curl through a file descriptor, never a variable, a file or the terminal.
    # mktemp creates both files with mode 600. They hold only the response headers (-D) and body (-o), never the request
    # or its Authorization header; the trap (cleanup_register) deletes them on exit.
    resp_headers="$(mktemp)"; resp_body="$(mktemp)"
    # Tracing off for the request, even if a caller enabled it: xtrace would print the expanded Authorization header.
    { set +x; } 2>/dev/null
    status="$(curl --proto =https --max-time 60 -sS -X PUT "$base/diskimages/v2?api-version=$SANDBOX_DP_API" \
                -H "Content-Type: application/json" -H "Accept: application/json" \
                -H @<(printf 'Authorization: Bearer %s\r\n' \
                       "$(az account get-access-token --resource https://dynamicsessions.io --query accessToken -o tsv)") \
                --data "$body" -D "$resp_headers" -o "$resp_body" -w '%{http_code}')"
    echo "PUT diskimages/v2: HTTP $status"
    case "$status" in
      200|201)
        id="$(jq -r '.id // .diskImage.id // empty' "$resp_body")"
        ;;
      202)
        oploc="$(grep -i '^operation-location:' "$resp_headers" | head -1 | cut -d' ' -f2- | tr -d '\r')"
        [ -n "$oploc" ] || { echo "ERROR: 202 without an operation-location header." >&2; exit 1; }
        [[ "$oploc" == http* ]] || oploc="https://$host$oploc"
        # Only ever poll our own regional data-plane host with a data-plane token.
        [[ "$oploc" == "https://$host/"* ]] || { echo "ERROR: unexpected operation-location host: ${oploc%%\?*}" >&2; exit 1; }
        [[ "$oploc" == *api-version=* ]] || oploc="$oploc$([[ "$oploc" == *\?* ]] && echo '&' || echo '?')api-version=$SANDBOX_DP_API"
        echo "Polling the operation (up to 10 minutes)."
        id=""
        for _ in $(seq 1 60); do
          op="$(az rest --method get --resource https://dynamicsessions.io --url "$oploc" -o json)"
          op_state="$(jq -r '.status // .state // "?"' <<<"$op")"
          case "$op_state" in
            Succeeded|Ready|Completed) id="$(jq -r '.diskImage.id // .resourceId // .id // empty' <<<"$op")"; break ;;
            Failed|Canceled|Cancelled)
              echo "ERROR: operation $op_state: $(jq -c '.error // .diskImage.status // .' <<<"$op")" >&2; exit 1 ;;
          esac
          sleep 10
        done
        echo "Operation state: $op_state"
        ;;
      *)
        echo "ERROR: PUT diskimages/v2 returned HTTP $status:" >&2
        jq -c '{title, status, detail, errorMessage, errorCode, traceId, requestId}' "$resp_body" >&2 2>/dev/null || cat "$resp_body" >&2
        exit 1
        ;;
    esac
    [ -n "$id" ] || { echo "ERROR: no disk image ID in the response." >&2; jq -c '.' "$resp_body" >&2; exit 1; }
    echo "Disk image $id; waiting for Ready (up to 10 minutes)."
    for _ in $(seq 1 60); do
      got="$(az rest --method get --resource https://dynamicsessions.io --url "$base/diskimages/$id?api-version=$SANDBOX_DP_API" -o json)"
      state="$(jq -r '.status.state // "?"' <<<"$got")"
      case "$state" in
        Ready|Succeeded) break ;;
        Failed|Error) echo "ERROR: disk image $id state=$state: $(jq -r '.status.errorMessage // ""' <<<"$got")" >&2; exit 1 ;;
      esac
      sleep 10
    done
    echo "Disk image $id: state=$state"
    jq '{id, name, labels, image, source: (.source // null | if . then del(.managedIdentityClientId) else . end), status, region: (.region // .location // null)}' <<<"$got"
    ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
