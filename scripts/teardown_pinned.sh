#!/usr/bin/env bash
# Pinned-hash wrapper for `teardown.sh session` (item 5, D-030). Saved 2026-11-06 from the 2026-11-05 Retest heredoc
# (TAG c5), with these changes for tonight: a new TAG and private folder, `session` instead of `precheck`, and the
# activation guard requiring exactly one activated instance, Owner at the lab subscription scope (c5 expected 0). The
# c5 time guard (30 minutes after a deactivation) is removed: it belonged to the no-activation Retest.
#
# Tooni runs it herself, interactively, from the laptop terminal as T with Owner activated:
#     bash scripts/teardown_pinned.sh
# teardown.sh's prompts show in the terminal and she answers each one; nothing passes ASSUME_YES. The wrapper stops
# before teardown.sh runs if the subscription, the signed-in account, the activation, the pinned sha256 or any pattern
# gate doesn't match. Raw and masked output go to the private folder, never the repo.
set -uo pipefail
umask 077
TAG="c2-teardown-$(date -u +%Y%m%dT%H%MZ)"
D=~/guarded-advisor-private/c2-2026-11
P1=~/guarded-advisor-private/pim-2026-11/p1-t-and-g.json
OWNER_ROLE=8e3af657-a8ff-443c-a75c-2fe8c4bcb635
if [ ! -d "$D" ]; then mkdir -m 700 "$D" || { echo "STOP: could not create the private folder"; exit 1; }; fi
OUT="$D/masked-$TAG.txt"
ERRF="$D/stderr-$TAG.txt"
if [ -e "$OUT" ]; then echo "STOP: output file for $TAG already exists"; exit 1; fi
exec 2>>"$ERRF"
trap 'echo "stderr lines in private file: $(wc -l <"$ERRF" | tr -d " ")"' EXIT
az() { command az "$@" </dev/null; }
scrub() { sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<id>/g; s/[A-Za-z0-9._%+#-]+@[A-Za-z0-9.-]+/<email>/g'; }
mask() { jq -rn --arg m "$1" '$m[0:4]+"..."+$m[-4:]'; }
say() { echo "$*" | tee -a "$OUT"; }
fail() { say "STOP: $*"; exit 1; }
gate() { if [ "$2" = "$3" ]; then say "gate ok | $1 | $2"; else fail "gate failed | $1 | got $2, expected $3. teardown.sh not run"; fi; }

SUB=$(az account show --query id -o tsv)
LAB=$(jq -r '[.[] | select(.roleDefinitionName=="Owner") | .scope | select(test("^/subscriptions/[^/]+$")) | sub("^/subscriptions/";"")] | unique | if length==1 then .[0] else error("expected one subscription in P1") end' "$P1")
echo "subscription: $(mask "$SUB")"
if [ -z "$SUB" ] || [ "$SUB" != "$LAB" ]; then echo "STOP: wrong subscription"; exit 1; fi
ME=$(az ad signed-in-user show --query id -o tsv)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
say "signed in: $(mask "$ME")"
say "now: $NOW"
[ "$(mask "$ME")" = "6d4c...2a4d" ] || fail "signed-in account is not T"

az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&\$filter=principalId%20eq%20'$ME'" -o json >"$D/raw-$TAG-instances.json" || fail "could not read T's instances"
ACTIVATED=$(jq '[.value[] | select(.properties.assignmentType=="Activated")] | length' "$D/raw-$TAG-instances.json")
say "T's activated instances: $ACTIVATED"
[ "$ACTIVATED" = "1" ] || fail "expected exactly 1 activated instance (Owner at the lab subscription), found $ACTIVATED"
ACT_ROLE=$(jq -r '[.value[] | select(.properties.assignmentType=="Activated")][0].properties.roleDefinitionId | ascii_downcase | split("/") | last' "$D/raw-$TAG-instances.json")
ACT_SCOPE=$(jq -r '[.value[] | select(.properties.assignmentType=="Activated")][0].properties.scope | ascii_downcase' "$D/raw-$TAG-instances.json")
[ "$ACT_ROLE" = "$OWNER_ROLE" ] || fail "the activated role isn't Owner"
[ "$ACT_SCOPE" = "/subscriptions/$(echo "$SUB" | tr '[:upper:]' '[:lower:]')" ] || fail "the activated Owner isn't at the lab subscription scope"
say "activated: Owner at the lab subscription scope"

cd ~/Projects/guarded-advisor || fail "could not reach the repo"
F=scripts/teardown.sh
gate "teardown.sh sha256" "$(shasum -a 256 "$F" | cut -d' ' -f1)" "13da9b41e39ead3732b6f6e2dab413528b14ef66595fda00c41dd7b281f4a3df"
gate "lines that source another file" "$(grep -cE '^[[:space:]]*(\.|source)[[:space:]]' "$F")" 0
gate "trap statements" "$(grep -cE '(^|[;&|[:space:]])trap[[:space:]]' "$F")" 0
gate "eval statements" "$(grep -cE '(^|[;&|[:space:]])eval[[:space:]]' "$F")" 0
gate "case fall-through" "$(grep -cE ';;?&' "$F")" 0
gate "exported functions in the environment" "$(env | grep -c '^BASH_FUNC_')" 0

env -u BASH_ENV -u RESOURCE_GROUP -u ASSUME_YES ./scripts/teardown.sh session 2>&1 | tee "$D/raw-$TAG.txt"; RC=${PIPESTATUS[0]}
say "--- teardown.sh session output"
scrub <"$D/raw-$TAG.txt" | cut -c1-300 | tee -a "$OUT"
say "exit code: $RC"
