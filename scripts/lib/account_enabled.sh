# account_enabled.sh: read a user's accountEnabled from Microsoft Graph (item 29, C2).
# Sourced by scripts/c2_live.sh, which defines az (stdin from /dev/null), say, fail and mask. Defines functions only.
#
# accountEnabled isn't in Graph's default property set. The user resource's Properties table says "Requires $select
# to retrieve" (https://learn.microsoft.com/graph/api/resources/user?view=graph-rest-1.0#properties), and Get a user
# lists the default set, which doesn't include it
# (https://learn.microsoft.com/graph/api/user-get?view=graph-rest-1.0#optional-query-parameters). Both checked with the
# Learn connector on 2026-11-09. az ad user show returns the default set only, so on 2026-11-08 the pre-check read
# accountEnabled as empty for all three case managers (findings).
#
# Outcomes: true, false, MISSING (no boolean in the response) or ERROR (a failed read such as a 404, a response that
# doesn't parse, or a different id). Anything other than true or false fails closed.

parse_enabled() {  # stdin: one Graph user object as JSON. Prints true, false, MISSING or ERROR, nothing else.
  local v
  v=$(jq -r '.accountEnabled | if type == "boolean" then tostring else "MISSING" end') || v=ERROR
  case "$v" in true|false|MISSING) echo "$v" ;; *) echo ERROR ;; esac
}

graph_enabled() {  # $1 object ID. Prints true, false, MISSING or ERROR. Never stops the run, so it's safe in $(...).
  local raw same
  # \$select: the backslash keeps bash from expanding $select (unset; an error under set -u). Graph gets it literally.
  raw=$(az rest --method get --url "https://graph.microsoft.com/v1.0/users/$1?\$select=id,accountEnabled" -o json) \
    || { echo ERROR; return 0; }
  # The response must be for the object asked for (compared in jq: macOS /bin/bash 3.2 has no ${1,,}).
  same=$(printf '%s' "$raw" | jq -r --arg id "$1" \
    'if (.id | type) == "string" and (.id | ascii_downcase) == ($id | ascii_downcase) then "yes" else "no" end')
  [ "$same" = yes ] || { echo ERROR; return 0; }
  printf '%s' "$raw" | parse_enabled
}

enabled_or_stop() {  # $1 object ID, $2 label. Sets ENABLED to true or false in this shell, or stops the run.
  ENABLED=$(graph_enabled "$1")  # call enabled_or_stop directly, never inside $(...): fail there only ends a subshell
  case "$ENABLED" in true|false) ;; *) fail "$2 accountEnabled read as $ENABLED; failing closed (stderr file)" ;; esac
}

positive_control() {  # $1 T's own object ID (the guard ID). Must read true, or the run stops.
  local v
  v=$(graph_enabled "$1")
  [ "$v" = true ] || fail "positive control failed: T ($(mask "$1")) accountEnabled read as $v"
  say "ok | positive control: T ($(mask "$1")) accountEnabled | true"
}
