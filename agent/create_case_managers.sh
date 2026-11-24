#!/usr/bin/env bash
# Creates the synthetic case manager accounts and their security group for a scenario pack (w1-data Part A, G7b; C2).
# Needs a directory role that can create users and groups (User Administrator, granted for the sitting through PIM).
#
# - Aliases come from scenarios/$SCENARIO/data/claims.json; names, group and attributes from identities.json.
# - Accounts are created DISABLED and unlicensed. Graph requires a password at creation: a random value is generated
#   with openssl and piped straight into the request body (stdin to jq, process substitution to az rest), so it never
#   appears on screen, on a command line or in a file. A fixed suffix (Aa1!) is appended inside jq so the complexity
#   rule (upper, lower, digit, symbol) always holds. Nobody knows it; first sign-in uses a Temporary Access Pass (G7c).
# - Idempotent: existing users, the existing group and existing memberships are skipped.
# - The tenant's default domain is read at run time and never written anywhere.
# - Output: every az rest call returns only an ID (--query ... -o tsv) or nothing (-o none); no response bodies are
#   printed, and --debug or --verbose must never be used here (they would log request bodies).
#
# Usage: ./agent/create_case_managers.sh            (SCENARIO=larkfield)
set -euo pipefail

SCENARIO="${SCENARIO:-larkfield}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK="$ROOT/scenarios/$SCENARIO"
CLAIMS="$PACK/data/claims.json"
IDS="$PACK/identities.json"
GRAPH="https://graph.microsoft.com/v1.0"

confirm() {
  if [ "${ASSUME_YES:-}" = "1" ]; then return 0; fi
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

prefix=$(jq -r .upn_prefix "$IDS")
group=$(jq -r .group "$IDS")
aliases=$(jq -r '[.claims[].case_manager] | unique[]' "$CLAIMS")
domain=$(az rest --method get --url "$GRAPH/domains" --query "value[?isDefault].id | [0]" -o tsv)
[ -n "$domain" ] || { echo "Couldn't read the tenant's default domain." >&2; exit 1; }

echo "Scenario $SCENARIO: will create, if missing, in the tenant's default domain (<lab-tenant>):"
for a in $aliases; do echo "  user ${prefix}${a}@<lab-tenant>  (disabled, unlicensed)"; done
echo "  security group $group with those members (not mail-enabled, not role-assignable)"
confirm "Continue?" || { echo "Nothing changed."; exit 0; }

user_id() {
  az rest --method get --url "$GRAPH/users?\$filter=userPrincipalName%20eq%20'$1'&\$select=id" --query "value[0].id" -o tsv
}

ids=()
for a in $aliases; do
  upn="${prefix}${a}@${domain}"
  id=$(user_id "$upn")
  if [ -n "$id" ]; then
    echo "  exists: ${prefix}${a} (${id:0:8}-...)"
  else
    alias_cap="$(printf '%s' "${a:0:1}" | tr '[:lower:]' '[:upper:]')${a:1}"
    display=$(jq -r --arg A "$alias_cap" '.display_name_template | sub("\\{Alias\\}"; $A)' "$IDS")
    # The password goes from openssl to jq on stdin and from jq to az rest through a file descriptor.
    id=$(az rest --method post --url "$GRAPH/users" --headers "Content-Type=application/json" \
      --body @<(openssl rand -base64 30 | tr -d '\n' | jq -R \
        --arg upn "$upn" --arg nick "${prefix}${a}" --arg display "$display" --slurpfile ids "$IDS" '{
          accountEnabled: false,
          displayName: $display,
          mailNickname: $nick,
          userPrincipalName: $upn,
          companyName: $ids[0].company,
          department: $ids[0].department,
          jobTitle: $ids[0].job_title,
          passwordProfile: {forceChangePasswordNextSignIn: true, password: (. + "Aa1!")}
        }') --query id -o tsv)
    echo "  created: ${prefix}${a} (${id:0:8}-...), disabled"
  fi
  ids+=("$id")
done

gid=$(az rest --method get --url "$GRAPH/groups?\$filter=displayName%20eq%20'$group'&\$select=id" --query "value[0].id" -o tsv)
if [ -n "$gid" ]; then
  echo "  exists: group $group (${gid:0:8}-...)"
else
  gid=$(az rest --method post --url "$GRAPH/groups" --headers "Content-Type=application/json" \
    --body "$(jq -n --arg g "$group" --slurpfile ids "$IDS" '{displayName: $g, mailNickname: $g, mailEnabled: false,
      securityEnabled: true, isAssignableToRole: false, description: $ids[0].group_description}')" --query id -o tsv)
  echo "  created: group $group (${gid:0:8}-...)"
fi

members=$(az rest --method get --url "$GRAPH/groups/$gid/members?\$select=id" --query "value[].id" -o tsv)
for id in "${ids[@]}"; do
  if printf '%s\n' "$members" | grep -qx "$id"; then
    echo "  member already: ${id:0:8}-..."
  else
    # A user or group created seconds ago may not have replicated yet: 3 tries, 10 seconds apart.
    added=0
    for try in 1 2 3; do
      if az rest --method post --url "$GRAPH/groups/$gid/members/\$ref" --headers "Content-Type=application/json" \
        --body "{\"@odata.id\": \"$GRAPH/directoryObjects/$id\"}" -o none 2>/dev/null; then
        added=1; break
      fi
      echo "  add to $group failed for ${id:0:8}-... (try $try of 3); retrying in 10 s"
      sleep 10
    done
    [ "$added" = 1 ] || { echo "Couldn't add ${id:0:8}-... to $group after 3 tries." >&2; exit 1; }
    echo "  added to $group: ${id:0:8}-..."
  fi
done

echo "Result (group members: nickname, accountEnabled, license count):"
az rest --method get --url "$GRAPH/groups/$gid/members?\$select=mailNickname,accountEnabled,assignedLicenses" \
  --query "value[].[mailNickname, accountEnabled, length(assignedLicenses)]" -o tsv | sed 's/^/  /'
