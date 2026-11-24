#!/usr/bin/env bash
# w3-docs evidence capture (drafted 2026-11-14). Read-only. Laptop, as T with standing Reader; no activation needed.
# Saves masked, counts-only query output to docs/evidence/w3-docs/capture-<UTC time>/ so the write-up cites files,
# not memory (the lab's honest-results rule). Raw output goes to the private folder only. Run it after the Monday 11-16 window and
# before anything in rg-guardedadvisor-shared is removed (teardown plan, the working run sheet).
#
# Files (each is one query; IDs masked to first 4 and last 4; no UPNs, IP addresses, message bodies or free text):
#   E01 AgentToolAudit_CL by redteam_id, decision, reason, action, tool (90 days): C1, C2, C8 outcomes per run
#   E02 ApiManagementGatewayLogs by day, response code, backend code and error source/reason (30 days): C3 gateway
#   E03 D5: SecurityAlert alerts and SecurityIncident incidents per run ID, plus totals (30 days): C2 detection
#   E04 Entra report-only results on the case managers' device code sign-ins, per day and table (30 days): w2-agentid
#   E05 AuditLogs Conditional Access rows for GA-CA-*: operation, time, ingestion latency (30 days): GA-CA-01 finding
#   E06 AzureActivity billing windows: start and stop events for APIM, its private endpoint, Bastion, its IP and the
#       jumpbox, per resource and day (90 days): cost section
#   E07 RedTeamRun_CL row count and run IDs (90 days): the ground-truth gap for w3-matrix
#   E08 CDBDataPlaneRequests by day, operation, status, database, collection and masked principal (30 days): C2 (A13)
#   E09 Table settings from ARM: plan, analytics and total retention, protection level: C6
#   E10 Billable ingestion by table (Usage, 31 days): cost
#   E11 ApiManagementGatewayLlmLog row count as T (Protected since 2026-11-14 17:07:20Z: 0 expected; the 16:45Z
#       counts are in SESSION_LOG and findings): C6 behaviour check
#   E12 Defender for AI Services (w2-defender, C6): the AI plan's tier and extensions (ARM); Defender for Cloud alerts
#       of AI.* types from ARM (type, generated time, severity, status only: an alert's description and entities can
#       carry prompt evidence, so they stay in the raw file); SecurityAlert rows in ga-law-shared by product and type
#       (30 days). DF-1's send time is in the run log; the latency is computed in the write-up, not here
# Not here (Protected; need Privileged Monitoring Data Reader, run sheet row 17): AdjudicationLog_CL, AppGenAIContent.
#
# Usage: bash scripts/w3_evidence_capture.sh
set -uo pipefail
umask 077
cd ~/Projects/guarded-advisor || exit 1
REPO=$PWD
P1=~/guarded-advisor-private/pim-2026-11/p1-t-and-g.json
PRIV=~/guarded-advisor-private/w3-docs
STAMP=$(date -u +%Y%m%dT%H%MZ)
EV="$REPO/docs/evidence/w3-docs/capture-$STAMP"
ENT="$REPO/scenarios/larkfield/entitlements.json"
[ -e "$EV" ] && { echo "STOP: $EV exists"; exit 1; }
mkdir -p "$PRIV" && chmod 700 "$PRIV" || { echo "STOP: private folder"; exit 1; }
ERRF="$PRIV/stderr-capture-$STAMP.txt"
exec 2>>"$ERRF"
trap 'echo "stderr lines in private file: $(wc -l <"$ERRF" | tr -d " ")"' EXIT
az() { command az "$@" </dev/null; }
mask() { jq -rn --arg m "$1" 'if ($m | length) > 8 then $m[0:4] + "..." + $m[-4:] else $m end'; }
JQM='def m: if type == "string" and length > 8 then .[0:4] + "..." + .[-4:] else . end;'
# Every line written to the evidence folder passes through mguid: any GUID, including one joined to other text by
# "_" or "-" (rule IDs in AlertType, the project ID in Cosmos collection names), becomes first 4 ... last 4.
mguid() { perl -pe 's/(?<![0-9a-fA-F])([0-9a-fA-F]{4})[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{8}([0-9a-fA-F]{4})(?![0-9a-fA-F])/$1...$2/g'; }
FINDINGS=0
note() { echo "$*"; }
finding() { echo "FINDING | $*"; FINDINGS=$((FINDINGS + 1)); }

# Guards: the lab subscription (from P1) and T. No activation is needed or expected.
SUB=$(az account show --query id -o tsv)
LAB=$(jq -r '[.[] | select(.roleDefinitionName=="Owner") | .scope | select(test("^/subscriptions/[^/]+$")) | sub("^/subscriptions/";"")] | unique | if length==1 then .[0] else error("expected one subscription in P1") end' "$P1")
{ [ -n "$SUB" ] && [ "$SUB" = "$LAB" ]; } || { echo "STOP: wrong subscription"; exit 1; }
ME=$(az ad signed-in-user show --query id -o tsv)
[ "$(mask "$ME")" = "6d4c...2a4d" ] || { echo "STOP: signed-in account is not T"; exit 1; }
WSRID="/subscriptions/$SUB/resourceGroups/rg-guardedadvisor-shared/providers/Microsoft.OperationalInsights/workspaces/ga-law-shared"
WSID=$(az monitor log-analytics workspace show -g rg-guardedadvisor-shared -n ga-law-shared --query customerId -o tsv)
[ -n "$WSID" ] || { echo "STOP: could not read ga-law-shared"; exit 1; }
mkdir -p "$EV"
HEADER="capture-$STAMP | read $(date -u +%Y-%m-%dT%H:%M:%SZ) | as T ($(mask "$ME")), standing Reader | workspace ga-law-shared | script scripts/w3_evidence_capture.sh at $(git rev-parse --short HEAD)"

# q NAME TIMESPAN QUERY JQ_FORMAT: runs one query, keeps the raw JSON privately, writes the masked lines to the
# evidence file with the header and the KQL (so the file says exactly what was counted).
q() {
  local name=$1 span=$2 query=$3 fmt=$4 raw="$PRIV/raw-$STAMP-$1.json" out="$EV/$1.txt"
  if ! az monitor log-analytics query --workspace "$WSID" --timespan "$span" --analytics-query "$query" -o json >"$raw"; then
    finding "$name query failed (stderr file)"; return 1
  fi
  # The query text is masked too: E04 carries the case managers' object IDs in its id list.
  { echo "$HEADER"; echo "timespan: $span"; echo "query (GUIDs masked):"
    echo "$query" | sed 's/^/  /'
    echo "rows: $(jq length "$raw")"; echo "---"
    jq -r "$JQM $fmt" "$raw"; } | mguid >"$out"
  note "$name | rows $(jq length "$raw") | $out"
}

q E01-agenttoolaudit-by-run P90D 'AgentToolAudit_CL
| extend rid = iff(isempty(redteam_id), "(none)", redteam_id)
| summarize Rows = count(), FirstT = min(TimeGenerated), LastT = max(TimeGenerated) by rid, decision, reason, action, tool_name
| order by FirstT asc' \
  '.[] | "\(.rid) | \(.decision) | \(if .reason == "" then "-" else .reason end) | \(.action) | \(if .tool_name == "" then "-" else .tool_name end) | \(.Rows) | \(.FirstT[0:16])Z to \(.LastT[0:16])Z"'
T01=$(jq '[.[] | .Rows | tonumber] | add // 0' "$PRIV/raw-$STAMP-E01-agenttoolaudit-by-run.json" 2>/dev/null || echo 0)
[ "${T01:-0}" -ge 111 ] || finding "E01 positive control: $T01 audit rows, 111 or more expected (count on 2026-11-14)"

q E02-gateway-by-code P30D 'ApiManagementGatewayLogs
| summarize Rows = count() by Day = format_datetime(TimeGenerated, "yyyy-MM-dd"), ResponseCode, BackendResponseCode,
    LastErrorSource = tostring(LastErrorSource), LastErrorReason = tostring(LastErrorReason)
| order by Day asc, ResponseCode asc' \
  '.[] | "\(.Day) | gateway \(.ResponseCode) | backend \(.BackendResponseCode) | error source \(if .LastErrorSource == "" then "-" else .LastErrorSource end) | reason \(if .LastErrorReason == "" then "-" else .LastErrorReason end) | \(.Rows)"'

q E03-d5-alerts-incidents P30D 'let ids = @"((?:c2(?:live|model)|d5smoke|A6|C8|DF1)-[A-Za-z0-9-]+)";
let alerts = SecurityAlert | where AlertName startswith "D5"
  | summarize arg_max(TimeGenerated, ExtendedProperties) by SystemAlertId
  | extend rids = extract_all(ids, ExtendedProperties)
  | extend rids = iff(isnull(rids) or array_length(rids) == 0, dynamic(["other"]), rids)
  | mv-expand rid = rids to typeof(string) | distinct SystemAlertId, rid, TimeGenerated;
let inc = SecurityIncident | summarize arg_max(TimeGenerated, AlertIds) by IncidentName
  | mv-expand AlertId = AlertIds to typeof(string)
  | join kind=inner alerts on $left.AlertId == $right.SystemAlertId | distinct IncidentName, rid;
union
  (alerts | summarize n = dcount(SystemAlertId), Day = format_datetime(min(TimeGenerated), "yyyy-MM-dd") by rid | extend k = "D5 alerts"),
  (inc | summarize n = dcount(IncidentName) by rid | extend k = "incidents holding a D5 alert", Day = ""),
  (alerts | summarize n = dcount(SystemAlertId) | extend k = "D5 alerts total", rid = "", Day = ""),
  (SecurityIncident | summarize n = dcount(IncidentName) | extend k = "incidents total (all rules)", rid = "", Day = "")
| order by k asc, rid asc' \
  '.[] | "\(.k) | \(if .rid == "" then "-" else .rid end) | \(.n)\(if .Day != "" then " | first " + .Day else "" end)"'

IDS=$(jq -c '[.caseloads | keys[]]' "$ENT")
USERS=$(jq -c '[.caseloads | to_entries[] | {key: (.key | ascii_downcase), value: .value.alias}] | from_entries' "$ENT")
q E04-entra-reportonly P30D "let ids = dynamic($IDS);
let ca01 = \"GA-CA-01 case managers block device code flow (report-only)\";
let ca02 = \"GA-CA-02 case managers require MFA (report-only)\";
let i = SigninLogs | where UserId in~ (ids)
  | where AuthenticationProtocol =~ \"deviceCode\" or OriginalTransferMethod =~ \"deviceCodeFlow\"
  | extend Tbl = \"interactive\", CAP = todynamic(ConditionalAccessPolicies) | project TimeGenerated, Tbl, UserId, CAP;
let n = AADNonInteractiveUserSignInLogs | where UserId in~ (ids)
  | where AuthenticationProtocol =~ \"deviceCode\" or OriginalTransferMethod =~ \"deviceCodeFlow\"
  | extend Tbl = \"non-interactive\", CAP = todynamic(ConditionalAccessPolicies) | project TimeGenerated, Tbl, UserId, CAP;
union i, n
| mv-apply p = CAP on (summarize R01 = take_anyif(tostring(p.result), tostring(p.displayName) == ca01),
                                R02 = take_anyif(tostring(p.result), tostring(p.displayName) == ca02))
| summarize Rows = count() by Day = format_datetime(TimeGenerated, \"yyyy-MM-dd\"), Tbl, UserId,
    GA_CA_01 = iff(R01 == \"\", \"absent\", R01), GA_CA_02 = iff(R02 == \"\", \"absent\", R02)
| order by Day asc, UserId asc" \
  ".[] | \"\(.Day) | \((${USERS})[.UserId | ascii_downcase] // \"?\") | \(.Tbl) | GA-CA-01 \(.GA_CA_01) | GA-CA-02 \(.GA_CA_02) | \(.Rows)\""

q E05-auditlogs-ca P30D 'AuditLogs
| extend TR = tostring(TargetResources)
| where TR has "GA-CA-" or LoggedByService =~ "Conditional Access"
| extend Policy = case(TR has "GA-CA-01", "GA-CA-01", TR has "GA-CA-02", "GA-CA-02", "other")
| project TimeGenerated, OperationName, Policy, Result, LatencyS = datetime_diff("second", ingestion_time(), TimeGenerated)
| order by TimeGenerated asc' \
  '.[] | "\(.TimeGenerated[0:19])Z | \(.Policy) | \(.OperationName) | \(.Result) | ingestion latency \(.LatencyS) s"'

q E06-activity-billing P90D 'AzureActivity
| where ResourceGroup =~ "rg-guardedadvisor-lab" and ActivityStatusValue in~ ("Success", "Succeeded")
| where ResourceProviderValue in~ ("MICROSOFT.APIMANAGEMENT", "MICROSOFT.NETWORK", "MICROSOFT.COMPUTE")
| extend O = replace_string(tolower(OperationNameValue), "/action", "")
| extend Res = tostring(split(_ResourceId, "/")[-1]), Op = tostring(split(O, "/")[-1]), Kind = tostring(split(O, "/")[-2])
| where Kind in~ ("service", "bastionHosts", "publicIPAddresses", "virtualMachines", "privateEndpoints")
| where Op in~ ("write", "delete", "start", "deallocate", "powerOff")
| where Kind !~ "privateEndpoints" or Res startswith "ga-apim"
| summarize FirstT = min(TimeGenerated), LastT = max(TimeGenerated), Events = count()
    by Day = format_datetime(TimeGenerated, "yyyy-MM-dd"), Kind, Res, Op
| order by Day asc, FirstT asc' \
  '.[] | "\(.Day) | \(.Kind) | \(.Res) | \(.Op) | \(.FirstT[11:19])Z to \(.LastT[11:19])Z | events \(.Events)"'
[ "$(jq length "$PRIV/raw-$STAMP-E06-activity-billing.json" 2>/dev/null || echo 0)" -gt 0 ] || finding "E06 positive control: no billing events read"

# D-045: pre-registered rows hold harness_verdict expect-*; they are ground truth, never outcomes, so each row is labelled.
q E07-redteamrun P90D 'RedTeamRun_CL
| extend Kind = iff(tostring(column_ifexists("harness_verdict", "")) startswith "expect-", "registered", "outcome")
| summarize Rows = count(), FirstT = min(TimeGenerated), LastT = max(TimeGenerated) by rid = tostring(column_ifexists("redteam_id", "")), Kind' \
  '.[] | "\(if .rid == "" then "(no redteam_id)" else .rid end) | \(.Kind) | \(.Rows) | \(.FirstT[0:16])Z to \(.LastT[0:16])Z"'

q E08-cosmos-dataplane P30D 'CDBDataPlaneRequests
| summarize Rows = count() by Day = format_datetime(TimeGenerated, "yyyy-MM-dd"), OperationName, StatusCode = tostring(StatusCode),
    DatabaseName = tostring(column_ifexists("DatabaseName", "")), CollectionName = tostring(column_ifexists("CollectionName", "")),
    Principal = tostring(column_ifexists("AadPrincipalId", ""))
| order by Day asc, Rows desc' \
  '.[] | "\(.Day) | \(.OperationName) | \(.StatusCode) | \(if .DatabaseName == "" then "-" else .DatabaseName end)/\(if .CollectionName == "" then "-" else .CollectionName end) | principal \(if .Principal == "" then "-" else (.Principal | m) end) | \(.Rows)"'

q E10-usage-by-table P31D 'Usage
| where IsBillable == true
| summarize GB = round(sum(Quantity) / 1024.0, 3) by DataType
| order by GB desc' \
  '.[] | "\(.DataType) | \(.GB) GB billable"'

q E11-llmlog-as-reader P30D 'ApiManagementGatewayLlmLog | count' '.[] | "ApiManagementGatewayLlmLog rows readable by T without the data role: \(.Count) (0 expected since 2026-11-14 17:07:20Z; 72 before)"'

# E09 from ARM, not KQL.
T9="$EV/E09-table-settings.txt"
{ echo "$HEADER"; echo "source: ARM GET workspaces/tables/<name>, api-version 2026-03-01"; echo "---"
  for t in AppGenAIContent AppDependencies AppTraces AppEvents AppRequests AppExceptions ApiManagementGatewayLlmLog ApiManagementGatewayLogs AgentToolAudit_CL AdjudicationLog_CL RedTeamRun_CL AuditLogs SigninLogs AADNonInteractiveUserSignInLogs AzureActivity SecurityAlert SecurityIncident AzureDiagnostics CDBDataPlaneRequests; do
    if az rest --method get --url "https://management.azure.com$WSRID/tables/$t?api-version=2026-03-01" -o json >"$PRIV/raw-$STAMP-E09-$t.json"; then
      jq -r '"\(.name) | plan \(.properties.plan) | analytics \(.properties.retentionInDays) | total \(.properties.totalRetentionInDays) | protection \(.properties.protectionLevel // "null")"' "$PRIV/raw-$STAMP-E09-$t.json"
    else echo "$t | not read"; fi
  done; } | mguid >"$T9"
note "E09-table-settings | $T9"

# E12: Defender for AI Services. ARM first (plan state, then alerts), then the workspace.
T12="$EV/E12-defender-ai.txt"
R12P="$PRIV/raw-$STAMP-E12-pricing.json" R12A="$PRIV/raw-$STAMP-E12-alerts.json"
{ echo "$HEADER"; echo "source: az security pricing show -n AI; az security alert list (ARM, subscription); fields kept: type, generated time, severity, status"; echo "---"
  if az security pricing show -n AI -o json >"$R12P"; then
    jq -r '"AI plan | tier \(.pricingTier) | enabled \(.enablementTime // "-") | trial remaining \(.freeTrialRemainingTime // "-") | extensions \([.extensions[]? | "\(.name)=\(.isEnabled)"] | join(", ") | if . == "" then "-" else . end)"' "$R12P"
  else echo "AI plan | not read"; fi
  if az security alert list -o json >"$R12A"; then
    echo "alerts (all plans): $(jq length "$R12A")"
    jq -r '[.[] | {t: (.alertType // .properties.alertType // ""), g: (.timeGeneratedUtc // .properties.timeGeneratedUtc // ""), s: (.severity // .properties.severity // ""), st: (.status // .properties.status // "")}
      | select(.t | startswith("AI."))] | sort_by(.g) | if length == 0 then "AI alerts: 0" else (.[] | "\(.g[0:19])Z | \(.t) | \(.s) | \(.st)") end' "$R12A"
  else echo "alerts | not read"; fi; } | mguid >"$T12"
q E12b-securityalert-by-product P30D 'SecurityAlert
| summarize Alerts = dcount(SystemAlertId), FirstT = min(TimeGenerated) by ProductName, AlertType
| order by FirstT asc' \
  '.[] | "\(.ProductName) | \(.AlertType) | \(.Alerts) | first \(.FirstT[0:16])Z"'
note "E12-defender-ai | $T12"

{ echo "# w3-docs evidence capture $STAMP"
  echo
  echo "Generated by \`scripts/w3_evidence_capture.sh\` (read-only, as T with standing Reader). Each file holds one query, its timespan and its masked output: counts, codes, run IDs and times; IDs masked to first 4 and last 4; no UPNs, IP addresses, message bodies or free text. Raw output is in the private folder only. Protected tables (\`AdjudicationLog_CL\`, \`AppGenAIContent\`) aren't read here."
  echo
  for f in "$EV"/E*.txt; do r=$(sed -n 's/^rows: //p' "$f" | head -1); echo "- \`$(basename "$f")\`: ${r:+$r rows}${r:-ARM read, see the file}"; done; } >"$EV/README.md"
# Last guard: no full GUID may remain anywhere in the evidence folder.
LEFT=$(grep -rhoE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$EV" | wc -l | tr -d ' ')
[ "$LEFT" -eq 0 ] || finding "unmasked GUIDs left in the evidence folder: $LEFT (don't commit it)"
echo "findings: $FINDINGS | evidence: $EV (masked; scan before commit)"
[ "$FINDINGS" -eq 0 ] || exit 1
