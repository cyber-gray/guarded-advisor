#!/usr/bin/env bash
# Estimates the 3-week lab cost in CAD from the Azure Retail Prices API (w1-cost).
# Read-only: calls the public, unauthenticated prices API and writes docs/cost-estimate.md.
#
# Usage: ./scripts/estimate-cost.sh
#
# Prices are Microsoft retail list prices; non-USD prices are "for reference to help you
# estimate budget expenses" (https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices).
# Usage quantities are assumptions, set below. Change them and rerun.
set -euo pipefail

REGION="canadaeast"
CURRENCY="CAD"
OUT="docs/cost-estimate.md"

# --- Assumptions -------------------------------------------------------------
INFRA_DAYS=21          # weeks 1 to 3; always-on resources stay up until w3-teardown
APIM_DAYS=14           # Standard v2 only in weeks 2 and 3 (D-003)
APIM_SESSION_HOURS=40  # deployed per working session, deleted and purged after (D-010)
JUMPBOX_HOURS=30       # Windows jumpbox, deallocated after every session (D-004)
PRIVATE_ENDPOINTS=7    # Foundry, AI Search, Storage, Cosmos DB, Key Vault, Content Safety, Azure Monitor
DNS_ZONES=14           # private DNS zones, including APIM and Azure Monitor zones
COSMOS_MILLION_RUS=5   # serverless request units consumed (lab design)
COSMOS_GB=1
GPT_INPUT_K=4000       # gpt-4.1-mini input tokens, thousands (agent use, red team, bias test B1)
GPT_OUTPUT_K=1000      # gpt-4.1-mini output tokens, thousands
CS_TEXT_K=10           # Content Safety text records, thousands (Prompt Shields and content filters)
LOG_GB=3               # Log Analytics ingestion over the lab
SANDBOX_RUN_SECONDS=12000   # e.g. 200 runs x 60 s on XS (0.25 vCPU, 0.5 GiB)
CONTINGENCY=0.25

HOURS=$((INFRA_DAYS * 24))
# Default: APIM only during working sessions (D-010). Override APIM_HOURS to model other patterns.
APIM_HOURS="${APIM_HOURS:-$APIM_SESSION_HOURS}"
APIM_ALWAYS_ON_HOURS=$((APIM_DAYS * 24))
OUT="${OUT_FILE:-$OUT}"
MONTH_FRACTION=$(awk -v d="$INFRA_DAYS" 'BEGIN { printf "%.4f", d / 30 }')

# --- Price lookup --------------------------------------------------------------
# price <OData filter> [tierMinimumUnits] -> retailPrice of the first Consumption match
price() {
  local filter="$1" tier="${2:-0}" body attempt
  for attempt in 1 2 3 4 5; do
    if body=$(curl -fsS -G "https://prices.azure.com/api/retail/prices" \
        --data-urlencode "currencyCode=$CURRENCY" \
        --data-urlencode "\$filter=priceType eq 'Consumption' and $filter" 2>/dev/null); then
      sleep 2   # stay under the API's rate limit
      echo "$body" | jq -r --argjson t "$tier" \
        '[.Items[] | select(.tierMinimumUnits == $t)][0].retailPrice // empty'
      return 0
    fi
    sleep $((attempt * 10))   # 429 or transient error: back off and retry
  done
  echo "Price lookup failed: $filter" >&2
  return 1
}

r="armRegionName eq '$REGION'"
echo "Fetching $CURRENCY retail prices for $REGION..."

P_SEARCH_BASIC=$(price "$r and serviceName eq 'Azure Cognitive Search' and meterName eq 'Basic Unit'")
P_SEARCH_S1=$(price "$r and serviceName eq 'Azure Cognitive Search' and meterName eq 'Standard S1 Unit'")
P_APIM_SV2=$(price "$r and serviceName eq 'API Management' and meterName eq 'Standard v2 Unit'")
P_COSMOS_RU_M=$(price "$r and productName eq 'Azure Cosmos DB serverless' and meterName eq '1M RUs'")
P_COSMOS_GB=$(price "$r and productName eq 'Azure Cosmos DB' and skuName eq 'RUs' and meterName eq 'Data Stored'")
P_COSMOS_100RU=$(price "$r and productName eq 'Azure Cosmos DB' and skuName eq 'RUs' and meterName eq '100 RU/s'")
P_ACR_PREMIUM=$(price "$r and serviceName eq 'Container Registry' and meterName eq 'Premium Registry Unit'")
P_PE_HOUR=$(price "productName eq 'Virtual Network Private Link' and meterName eq 'Standard Private Endpoint'")
P_DNS_ZONE=$(price "serviceName eq 'Azure DNS' and meterName eq 'Private Zone'")
P_VM_B2S_WIN=$(price "$r and armSkuName eq 'Standard_B2s' and productName eq 'Virtual Machines BS Series Windows'")
P_DISK_E10=$(price "$r and serviceName eq 'Storage' and meterName eq 'E10 LRS Disk'")
P_BASTION_BASIC=$(price "$r and serviceName eq 'Azure Bastion' and meterName eq 'Basic Gateway'")
P_PIP_STD=$(price "$r and serviceName eq 'Virtual Network' and skuName eq 'Standard' and meterName eq 'Standard IPv4 Static Public IP'")
P_GPT_IN=$(price "$r and meterName eq 'gpt 4.1 mini Inp regnl Tokens'")
P_GPT_OUT=$(price "$r and meterName eq 'gpt 4.1 mini Outp regnl Tokens'")
P_CS_TEXT=$(price "$r and productName eq 'Content Safety' and meterName eq 'Standard Text Records'")
P_LA_GB=$(price "$r and serviceName eq 'Log Analytics' and meterName eq 'Analytics Logs Data Ingestion'" 5)
P_SENTINEL_GB=$(price "$r and serviceName eq 'Sentinel' and meterName eq 'Pay-as-you-go Analysis'")
P_DEF_STORAGE_H=$(price "$r and productName eq 'Microsoft Defender for Storage' and meterName eq 'Standard Node'")
P_ACA_VCPU_S=$(price "$r and serviceName eq 'Azure Container Apps' and meterName eq 'Standard vCPU Active Usage'")
P_ACA_GIB_S=$(price "$r and serviceName eq 'Azure Container Apps' and meterName eq 'Standard Memory Active Usage'")

# A meter that matched nothing would silently price at zero; stop instead.
for v in P_SEARCH_BASIC P_SEARCH_S1 P_APIM_SV2 P_COSMOS_RU_M P_COSMOS_GB P_COSMOS_100RU P_ACR_PREMIUM \
         P_PE_HOUR P_DNS_ZONE P_VM_B2S_WIN P_DISK_E10 P_BASTION_BASIC P_PIP_STD P_GPT_IN P_GPT_OUT P_CS_TEXT P_LA_GB \
         P_SENTINEL_GB P_DEF_STORAGE_H P_ACA_VCPU_S P_ACA_GIB_S; do
  [ -n "${!v}" ] || { echo "No price found for $v. Check the meter name in the API." >&2; exit 1; }
done

# --- Line items --------------------------------------------------------------
# Quantities that need arithmetic are computed here: macOS bash 3.2 mis-parses quotes
# inside a heredoc nested in $(...), so the heredoc below holds no quote characters.
Q_COSMOS_GB=$(awk -v g="$COSMOS_GB" -v m="$MONTH_FRACTION" 'BEGIN { print g * m }')
Q_DNS=$(awk -v z="$DNS_ZONES" -v m="$MONTH_FRACTION" 'BEGIN { print z * m }')
Q_SBX_VCPU=$(awk -v s="$SANDBOX_RUN_SECONDS" 'BEGIN { print s * 0.25 }')
Q_SBX_GIB=$(awk -v s="$SANDBOX_RUN_SECONDS" 'BEGIN { print s * 0.5 }')
Q_PE=$((PRIVATE_ENDPOINTS * HOURS))
Q_COSMOS_PROV=$((30 * HOURS))   # 3000 RU/s = 30 x 100 RU/s
Q_DEF_STORAGE=$((14 * 24))

# label | unit price | unit | quantity | included in lab design (1/0) | note
items=$(cat <<EOF
AI Search Basic (1 search unit)|$P_SEARCH_BASIC|hour|$HOURS|1|Basic supports inbound private endpoints, Free does not
API Management Standard v2 (1 unit)|$P_APIM_SV2|hour|$APIM_HOURS|1|working sessions in weeks 2 and 3, purged between (D-003, D-010)
Cosmos DB serverless, request units|$P_COSMOS_RU_M|1M RUs|$COSMOS_MILLION_RUS|1|serverless is supported for the standard agent setup
Cosmos DB storage|$P_COSMOS_GB|GB-month|$Q_COSMOS_GB|1|
Private endpoints|$P_PE_HOUR|endpoint-hour|$Q_PE|1|$PRIVATE_ENDPOINTS endpoints for $INFRA_DAYS days
Private endpoint for APIM|$P_PE_HOUR|endpoint-hour|$APIM_HOURS|1|weeks 2 and 3
Private DNS zones|$P_DNS_ZONE|zone-month|$Q_DNS|1|$DNS_ZONES zones
Jumpbox VM, Windows B2s|$P_VM_B2S_WIN|hour|$JUMPBOX_HOURS|1|deallocated between sessions
Jumpbox OS disk, Standard SSD E10|$P_DISK_E10|disk-month|$MONTH_FRACTION|1|billed while deallocated
Bastion Basic|$P_BASTION_BASIC|hour|$JUMPBOX_HOURS|1|created per session for Entra RDP sign-in, deleted at teardown (D-018)
Bastion public IP, Standard static|$P_PIP_STD|hour|$JUMPBOX_HOURS|1|exists only with the per-session Bastion (D-018)
gpt-4.1-mini regional input tokens|$P_GPT_IN|1K tokens|$GPT_INPUT_K|1|Standard deployment, processed in Canada (C5)
gpt-4.1-mini regional output tokens|$P_GPT_OUT|1K tokens|$GPT_OUTPUT_K|1|
Content Safety text records (S0)|$P_CS_TEXT|1K records|$CS_TEXT_K|1|
Log Analytics ingestion (beyond 5 GB free)|$P_LA_GB|GB|$LOG_GB|1|upper bound: assumes the monthly free 5 GB is already used
Container Apps Sandboxes, vCPU (proxy)|$P_ACA_VCPU_S|vCPU-second|$Q_SBX_VCPU|1|UNVERIFIED proxy: no Sandboxes meter in the API yet
Container Apps Sandboxes, memory (proxy)|$P_ACA_GIB_S|GiB-second|$Q_SBX_GIB|1|UNVERIFIED proxy; Consumption free grant likely covers it
Sentinel analysis (if no trial)|$P_SENTINEL_GB|GB|$LOG_GB|0|0 during the free trial (w2-trials)
Defender for Storage (if no trial)|$P_DEF_STORAGE_H|account-hour|$Q_DEF_STORAGE|0|0 during the free trial; weeks 2 and 3
Alternative: APIM always on in weeks 2 and 3|$P_APIM_SV2|hour|$APIM_ALWAYS_ON_HOURS|0|rejected in D-010; replaces the session line above
Template default: AI Search S1 instead of Basic|$P_SEARCH_S1|hour|$HOURS|0|sample sets the standard SKU
Template default: Cosmos DB 3000 RU/s provisioned|$P_COSMOS_100RU|100 RU/s-hour|$Q_COSMOS_PROV|0|instead of serverless
Template default: Container Registry Premium|$P_ACR_PREMIUM|day|$INFRA_DAYS|0|enableContainerRegistry = true; only hosted agents need it
EOF
)

table=$(echo "$items" | awk -F'|' '
  { cost = $2 * $4; printf "%s|%s|%s|%s|%.2f|%s|%s\n", $1, $2, $3, $4, cost, $5, $6 }')

lab_total=$(echo "$table" | awk -F'|' '$6 == 1 { s += $5 } END { printf "%.2f", s }')
no_trial=$(echo "$table" | awk -F'|' '$1 ~ /if no trial/ { s += $5 } END { printf "%.2f", s }')
template_extra=$(echo "$table" | awk -F'|' '$1 ~ /^Template default/ { s += $5 } END { printf "%.2f", s }')
with_contingency=$(awk -v t="$lab_total" -v c="$CONTINGENCY" 'BEGIN { printf "%.2f", t * (1 + c) }')

{
  echo "# Lab cost estimate"
  echo
  echo "Generated by \`scripts/estimate-cost.sh\` on $(date -u +%Y-%m-%d) from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices). Region \`$REGION\`, currency $CURRENCY, retail list prices. Quantities are assumptions set at the top of the script; rerun after changing them. Don't edit the numbers by hand."
  echo
  echo "Window: $INFRA_DAYS days of always-on infrastructure (weeks 1 to 3), API Management for $APIM_HOURS hours in weeks 2 and 3."
  echo
  echo "| Item | Unit price ($CURRENCY) | Unit | Quantity | Cost ($CURRENCY) | Note |"
  echo "|---|---:|---|---:|---:|---|"
  echo "$table" | awk -F'|' '$6 == 1 { printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $7 }'
  echo "| **Lab design total** | | | | **$lab_total** | |"
  echo "| **With ${CONTINGENCY/0./}% contingency** | | | | **$with_contingency** | |"
  echo
  echo "## Not in the total"
  echo
  echo "| Item | Unit price ($CURRENCY) | Unit | Quantity | Cost ($CURRENCY) | Note |"
  echo "|---|---:|---|---:|---:|---|"
  echo "$table" | awk -F'|' '$6 == 0 { printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $7 }'
  echo
  echo "- If the Sentinel and Defender trials aren't available: add about $no_trial $CURRENCY."
  echo "- Keeping the sample template's defaults (AI Search S1, provisioned Cosmos DB, Premium registry) would add about $template_extra $CURRENCY before subtracting the Basic and serverless lines they replace. \`w1-fork\` changes all three."
  echo
  echo "## Known gaps"
  echo
  echo "- **Container Apps Sandboxes** have no meter in the Retail Prices API and no billing section on Learn yet. The overview says stopped sandboxes incur no CPU or memory fees (https://learn.microsoft.com/azure/container-apps/sandboxes-overview). The lines above use the Container Apps Consumption vCPU and memory rates as a proxy. Check actual cost in Cost Management after the first runs (\`w2-sbx-tool\`)."
  echo "- **Defender for AI Services and Defender CSPM** returned no Canada East meters. Check pricing on Learn before enabling them outside the trial (\`w2-defender\`)."
  echo "- Not priced (expected to be under 1 $CURRENCY each): Key Vault operations, Storage account capacity and transactions, private endpoint data processing, Logic App runs, embeddings (text-embedding-3-small rounds to 0.0000 per 1K tokens)."
  echo "- Spectre (another project on the subscription) isn't included; the lab budget is scoped to \`rg-guardedadvisor-lab\`."
} > "$OUT"

echo "Lab design total: $lab_total $CURRENCY ($with_contingency with contingency)"
echo "Wrote $OUT"
