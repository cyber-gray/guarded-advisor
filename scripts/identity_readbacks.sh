#!/usr/bin/env bash
# Read-only read-backs for the Entra diagnostic setting and the two report-only Conditional Access policies
# (w2-sentinel, w2-agentid, 2026-11-12, D-040). Laptop, as T. Nothing here writes to Azure or Entra: az rest GETs and
# Log Analytics queries only. Each run is its own approval.
#
# Usage: bash scripts/identity_readbacks.sh diag | ca
#        bash scripts/identity_readbacks.sh ca-audit | logs | signins SINCE
#   diag      microsoft.aadiam/diagnosticSettings, api-version 2017-04-01
#             (https://learn.microsoft.com/azure/templates/microsoft.aadiam/diagnosticsettings): ga-entra-to-law-shared
#             exists once, sends to ga-law-shared and nowhere else, and enables exactly AuditLogs, SignInLogs,
#             NonInteractiveUserSignInLogs, ServicePrincipalSignInLogs and ManagedIdentitySignInLogs.
#   ca        Graph v1.0 GET /identity/conditionalAccess/policies: GA-CA-01 and GA-CA-02 each report-only
#             (enabledForReportingButNotEnforced), grp-larkfield-cm only, the emergency access account excluded, and
#             the conditions and grant. Needs, in this command's environment, either GA_EA_UPN (the emergency access
#             account's UPN; never printed) or GA_EA_DISPLAYNAME (exactly one user must have that display name; printed).
#             Each excluded user is also resolved by object ID through Graph, and its display name printed and checked.
#             Graph needs delegated Policy.Read.All, and Security Administrator reads standard properties
#             (https://learn.microsoft.com/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0#permissions).
#             Whether the Azure CLI's token carries that scope isn't documented (inference: it may not). A refused read
#             is a FINDING, and ca-audit is the fallback, with no consent change.
#   ca-audit  the same checks on the policy JSON in AuditLogs ("Add Conditional Access policy" and "Update Conditional
#             Access policy", https://learn.microsoft.com/entra/identity/monitoring-health/reference-audit-activities#conditional-access,
#             plus the generic "Add policy" and "Update policy" rows whose target is a GA-CA- policy) since SINCE. The
#             latest row with policy JSON is checked. Only works for policies created after the diagnostic setting.
#   logs      first rows since SINCE in SigninLogs, AADNonInteractiveUserSignInLogs, AADServicePrincipalSignInLogs,
#             AADManagedIdentitySignInLogs and AuditLogs: counts and times only. Rows can take up to 15 minutes
#             (https://learn.microsoft.com/entra/identity/monitoring-health/tutorial-configure-log-analytics-workspace#configure-diagnostic-settings).
#   signins   Friday: alder's and birch's device code sign-ins since SINCE, with the GA-CA-01 and GA-CA-02 report-only
#             results from ConditionalAccessPolicies (https://learn.microsoft.com/azure/azure-monitor/reference/tables/signinlogs).
#             Pass: GA-CA-01 reportOnlyFailure, "Report-only: Failure" (a block that would apply;
#             https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-report-only#policy-evaluation-results),
#             and GA-CA-02 reportOnlySuccess.
#   SINCE     UTC, YYYY-MM-DDTHH:MM:00Z
#
# Rules (as scripts/c2_live.sh): subscription and identity guards before any other read; az never reads stdin; stderr
# goes to a private file; raw output stays in the private folder; output is masked (IDs as first 4 and last 4, users by
# alias, no UPNs). A difference from the expected value is a FINDING, and the run ends with exit 1 if there was one.
# After activating Security Administrator: az logout, then az login, so the new role is in the token.
set -uo pipefail
umask 077

MODE=${1:-}; SINCE=${2:-}
usage() { echo "usage: bash scripts/identity_readbacks.sh diag|ca"; echo "       bash scripts/identity_readbacks.sh ca-audit|logs|signins SINCE (UTC, YYYY-MM-DDTHH:MM:00Z)"; exit 2; }
case "$MODE" in
  diag|ca) [ -z "$SINCE" ] || usage ;;
  ca-audit|logs|signins)
    [[ "$SINCE" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$ ]] || { echo "STOP: SINCE must be YYYY-MM-DDTHH:MM:00Z (UTC)"; exit 2; }
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$SINCE" +%s >/dev/null 2>&1 || { echo "STOP: SINCE isn't a valid time"; exit 2; } ;;
  *) usage ;;
esac
if [ "$MODE" = ca ] || [ "$MODE" = ca-audit ]; then
  [ -n "${GA_EA_UPN:-}${GA_EA_DISPLAYNAME:-}" ] || { echo "STOP: set GA_EA_UPN or GA_EA_DISPLAYNAME for the emergency access account first"; exit 2; }
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/identity_readbacks.sh" ]; then echo "STOP: could not work out the repo from the script's location"; exit 1; fi
LIBDIR="$REPO/scripts/lib"
[ -f "$LIBDIR/identity-checks.jq" ] || { echo "STOP: $LIBDIR/identity-checks.jq is missing"; exit 1; }
ENT="$REPO/scenarios/larkfield/entitlements.json"
P1=~/guarded-advisor-private/pim-2026-11/p1-t-and-g.json
D=~/guarded-advisor-private/identity-2026-11
SHARED_RG=rg-guardedadvisor-shared
WORKSPACE=ga-law-shared
GROUP=grp-larkfield-cm
SETTING=ga-entra-to-law-shared
CA01="GA-CA-01 case managers block device code flow (report-only)"
CA02="GA-CA-02 case managers require MFA (report-only)"
CATS='["AuditLogs","SignInLogs","NonInteractiveUserSignInLogs","ServicePrincipalSignInLogs","ManagedIdentitySignInLogs"]'

if [ ! -d "$D" ]; then mkdir -m 700 "$D" || { echo "STOP: could not create the private folder"; exit 1; }; fi
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TAG="identity-$MODE-$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$D/masked-$TAG.txt"
ERRF="$D/stderr-$TAG.txt"
if [ -e "$OUT" ]; then echo "STOP: output file for $TAG already exists"; exit 1; fi
exec 2>>"$ERRF"
trap 'echo "stderr lines in private file: $(wc -l <"$ERRF" | tr -d " ")"' EXIT
az() { command az "$@" </dev/null; }
mask() { jq -rn --arg m "$1" '$m[0:4]+"..."+$m[-4:]'; }
say() { echo "$*" | tee -a "$OUT"; }
fail() { say "STOP: $*"; exit 1; }
FINDINGS=0
check() { if [ "$2" = "$3" ]; then say "ok | $1 | $2"; else say "FINDING | $1 | got $2, expected $3"; FINDINGS=$((FINDINGS + 1)); fi; }
finding() { say "FINDING | $*"; FINDINGS=$((FINDINGS + 1)); }
rows() {  # $1 label prefix, $2 jq filter over the lib, $3 input file, then extra jq args. Each row: label, got, expected.
  local prefix=$1 filter=$2 file=$3 label got exp n=0; shift 3
  while IFS=$'\x1f' read -r label got exp; do check "$prefix$label" "$got" "$exp"; n=$((n + 1)); done \
    < <(jq -r -L "$LIBDIR" "$@" "include \"identity-checks\"; $filter | .[] | row" "$file")
  [ "$n" -gt 0 ] || finding "${prefix}no checks ran (the input didn't parse; see the raw file)"
}
info() {  # as rows, without a check: label and value
  local prefix=$1 filter=$2 file=$3 label val; shift 3
  while IFS=$'\x1f' read -r label val; do say "info | $prefix$label | $val"; done \
    < <(jq -r -L "$LIBDIR" "$@" "include \"identity-checks\"; $filter | .[] | row" "$file")
}
isguid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
# BadArgumentError is what Log Analytics returns for a KQL syntax or semantic error (2026-11-13: SEM0100 printed an
# empty class); the inner SyntaxError/SemanticError or SEMnnnn code is also caught when present.
errclass() { tail -n 20 "$ERRF" | grep -o -E "Forbidden|Authorization_RequestDenied|AuthorizationFailed|AccessDenied|Unauthorized|InvalidAuthenticationToken|NotFound|BadArgumentError|SyntaxError|SemanticError|SEM[0-9]+" | tail -n 1; }

# Guards: the lab subscription (from P1) and T, before any other read.
[ -f "$P1" ] || { echo "STOP: $P1 is missing"; exit 1; }
SUB=$(az account show --query id -o tsv)
LAB=$(jq -r '[.[] | select(.roleDefinitionName=="Owner") | .scope | select(test("^/subscriptions/[^/]+$")) | sub("^/subscriptions/";"")] | unique | if length==1 then .[0] else error("expected one subscription in P1") end' "$P1")
if [ -z "$SUB" ] || [ "$SUB" != "$LAB" ]; then echo "STOP: wrong subscription"; exit 1; fi
ME=$(az ad signed-in-user show --query id -o tsv)
say "mode: $MODE${SINCE:+ | since: $SINCE} | now: $NOW"
say "subscription: $(mask "$SUB") | signed in: $(mask "$ME")"
[ "$(mask "$ME")" = "6d4c...2a4d" ] || fail "signed-in account is not T"

WSRID=$(az monitor log-analytics workspace show -g "$SHARED_RG" -n "$WORKSPACE" --query id -o tsv)
WSID=$(az monitor log-analytics workspace show -g "$SHARED_RG" -n "$WORKSPACE" --query customerId -o tsv)
isguid "$WSID" && [ -n "$WSRID" ] || fail "could not read $WORKSPACE"

load_ids() {  # GRP and EA in this shell, so a failed read stops the run
  GRP=$(az ad group show --group "$GROUP" --query id -o tsv)
  isguid "$GRP" || fail "could not read $GROUP"
  if [ -n "${GA_EA_UPN:-}" ]; then
    EA=$(az ad user show --id "$GA_EA_UPN" --query id -o tsv)
    isguid "$EA" || fail "could not read the emergency access account from GA_EA_UPN"
  else
    # az ad user list --display-name matches by prefix, so the exact match is taken in jq and must be exactly one.
    EA=$(az ad user list --display-name "$GA_EA_DISPLAYNAME" -o json \
      | jq -r --arg n "$GA_EA_DISPLAYNAME" '[.[] | select(.displayName == $n) | .id] | if length == 1 then .[0] else "" end')
    isguid "$EA" || fail "expected exactly one user with display name \"$GA_EA_DISPLAYNAME\""
  fi
  say "ids: $GROUP $(mask "$GRP") | emergency access account $(mask "$EA")"
}
excluded_names() {  # $1 policy file (lower-cased keys), $2 label: each excluded user resolved by object ID in Graph
  local id name
  for id in $(jq -r '.conditions.users.excludeusers // [] | .[]' "$1"); do
    isguid "$id" || { finding "$2: excluded user entry isn't an object ID"; continue; }
    name=$(az rest --method get --url "https://graph.microsoft.com/v1.0/users/$id?\$select=displayName" --query displayName -o tsv) \
      || { finding "$2: could not resolve excluded user $(mask "$id") ($(errclass))"; continue; }
    if [ -n "${GA_EA_DISPLAYNAME:-}" ]; then
      check "$2: excluded user $(mask "$id") display name" "$name" "$GA_EA_DISPLAYNAME"
    else
      say "info | $2: excluded user $(mask "$id") display name | $name"
    fi
  done
}
kql() {  # $1 label, $2 query. Sets KF to the raw result file, in this shell.
  KF="$D/raw-$TAG-$1.json"
  az monitor log-analytics query --workspace "$WSID" --timespan "$SINCE/$NOW" --analytics-query "$2" -o json >"$KF" \
    || fail "query $1 failed ($(errclass); stderr file)"
  jq -e 'type == "array"' "$KF" >/dev/null || fail "query $1 returned no row array (raw file)"
}
policy_checks() {  # $1 file holding one policy object with lower-cased keys, $2 display name
  local kind=devicecode label="GA-CA-01"
  if [ "$2" = "$CA02" ]; then kind=mfa; label="GA-CA-02"; fi
  rows "$label: " 'ca_checks($k; $grp; $ea)' "$1" --arg k "$kind" --arg grp "$GRP" --arg ea "$EA"
  excluded_names "$1" "$label"
  info "$label: " 'ca_info' "$1"
}

case "$MODE" in
  diag)
    RAW="$D/raw-$TAG-aadiam.json"
    az rest --method get --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01" -o json >"$RAW" \
      || fail "the aadiam read failed ($(errclass); stderr file). With Security Administrator active: az logout, az login, retry"
    say "info | Entra diagnostic settings in the tenant | $(jq '.value | length' "$RAW")"
    rows "" 'diag_checks($n; $ws; $cats)' "$RAW" --arg n "$SETTING" --arg ws "$WSRID" --argjson cats "$CATS"
    ;;
  ca)
    load_ids
    RAW="$D/raw-$TAG-policies.json"
    if ! az rest --method get --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" -o json >"$RAW"; then
      finding "Graph refused the policy read ($(errclass); stderr file). Likely cause (inference): the Azure CLI token has no Policy.Read.All. Fallback: bash scripts/identity_readbacks.sh ca-audit <SINCE>"
    else
      [ "$(jq -r '."@odata.nextLink" // "none"' "$RAW")" = none ] || finding "the policy list has more pages; not read"
      say "info | Conditional Access policies in the tenant | $(jq '.value | length' "$RAW")"
      for NAME in "$CA01" "$CA02"; do
        check "policies named \"$NAME\"" "$(jq --arg n "$NAME" '[.value[] | select(.displayName == $n)] | length' "$RAW")" 1
        PF="$D/raw-$TAG-$(printf '%s' "$NAME" | cut -c1-8).json"
        jq -L "$LIBDIR" --arg n "$NAME" 'include "identity-checks"; [.value[] | select(.displayName == $n)] | .[0] // {} | lk' "$RAW" >"$PF"
        policy_checks "$PF" "$NAME"
      done
      check "other policies named GA-CA-*" "$(jq --arg a "$CA01" --arg b "$CA02" '[.value[] | select((.displayName | startswith("GA-CA-")) and .displayName != $a and .displayName != $b)] | length' "$RAW")" 0
    fi
    ;;
  ca-audit)
    load_ids
    # Entra also writes generic "Add policy" and "Update policy" rows for a Conditional Access change (GA-CA-02 on
    # 2026-11-13: "Add policy" at 02:02:07.32Z, "Add conditional access policy" at 02:02:07.63Z). Those are matched
    # only when their target is a GA-CA- policy; rows without policy JSON fail the checks closed, as before.
    kql audit 'AuditLogs
| extend Policy = tostring(TargetResources[0].displayName), Props = TargetResources[0].modifiedProperties
| where OperationName in~ ("Add Conditional Access policy", "Update Conditional Access policy")
    or (OperationName in~ ("Add policy", "Update policy") and Policy startswith "GA-CA-")
| project TimeGenerated, OperationName, Policy, Props
| order by TimeGenerated asc'
    say "info | policy audit rows since $SINCE | $(jq 'length' "$KF") (GA-CA-*: $(jq '[.[] | select(.Policy | startswith("GA-CA-"))] | length' "$KF"))"
    for NAME in "$CA01" "$CA02"; do
      check "audit rows for \"$NAME\"" "$(jq --arg n "$NAME" '[.[] | select(.Policy == $n)] | if length > 0 then "1 or more" else "0" end' -r "$KF")" "1 or more"
      PF="$D/raw-$TAG-$(printf '%s' "$NAME" | cut -c1-8).json"
      # The latest row for the policy that carries policy JSON, as written by its last add or update.
      jq -L "$LIBDIR" --arg n "$NAME" 'include "identity-checks"; [.[] | select(.Policy == $n) | audit_policy | select(. != null)] | (.[-1] // {})' "$KF" >"$PF"
      policy_checks "$PF" "$NAME"
    done
    ;;
  logs)
    kql logs 'union isfuzzy=true withsource=Tbl SigninLogs, AADNonInteractiveUserSignInLogs, AADServicePrincipalSignInLogs, AADManagedIdentitySignInLogs, AuditLogs
| summarize Rows = count(), FirstRow = min(TimeGenerated), LastRow = max(TimeGenerated) by Tbl'
    for T in SigninLogs AADNonInteractiveUserSignInLogs AADServicePrincipalSignInLogs AADManagedIdentitySignInLogs AuditLogs; do
      say "info | $T | $(jq -r --arg t "$T" '[.[] | select(.Tbl == $t)] | if length == 0 then "0 rows" else .[0] | "\(.Rows) rows, first \(.FirstRow), last \(.LastRow)" end' "$KF")"
    done
    # Positive controls: T's own sign-ins since SINCE, and the role activation and policy adds in AuditLogs.
    for T in SigninLogs AuditLogs; do
      check "$T rows since $SINCE" "$(jq -r --arg t "$T" '[.[] | select(.Tbl == $t) | .Rows | tonumber] | add // 0 | if . > 0 then "1 or more" else "0" end' "$KF")" "1 or more"
    done
    ;;
  signins)
    USERS=$(jq -c '[.caseloads | to_entries[] | select(.value.alias == "alder" or .value.alias == "birch") | {key, value: .value.alias}] | from_entries' "$ENT")
    [ "$(jq 'length' <<<"$USERS")" = 2 ] || fail "could not read alder and birch from $ENT"
    IDS=$(jq -c 'keys' <<<"$USERS")
    # ConditionalAccessPolicies is dynamic in SigninLogs and string in AADNonInteractiveUserSignInLogs (getschema,
    # 2026-11-13), so union renamed both and the 11-13 run failed with SEM0100. Each table is converted and projected
    # to the same columns first. The filters are written out per table: a (T:(*)) function can't reference UserId
    # (batch A, 2026-11-14).
    kql signins "let ids = dynamic($IDS);
let i = SigninLogs | where UserId in~ (ids)
  | extend Tbl = \"SigninLogs\", CAP = todynamic(ConditionalAccessPolicies)
  | project TimeGenerated, Tbl, UserId, AuthenticationProtocol, OriginalTransferMethod, ResultType = tostring(ResultType), CAP;
let n = AADNonInteractiveUserSignInLogs | where UserId in~ (ids)
  | extend Tbl = \"AADNonInteractiveUserSignInLogs\", CAP = todynamic(ConditionalAccessPolicies)
  | project TimeGenerated, Tbl, UserId, AuthenticationProtocol, OriginalTransferMethod, ResultType = tostring(ResultType), CAP;
union i, n
| order by TimeGenerated asc"
    say "info | sign-in rows for alder and birch since $SINCE | $(jq 'length' "$KF")"
    rows "" 'signin_checks($u; $a; $b)' "$KF" --argjson u "$USERS" --arg a "$CA01" --arg b "$CA02"
    info "" 'signin_info($u)' "$KF" --argjson u "$USERS"
    ;;
esac

say "findings: $FINDINGS | masked output: $OUT"
[ "$FINDINGS" -eq 0 ] || exit 1
