# identity-checks.jq: checks for scripts/identity_readbacks.sh (w2-sentinel, w2-agentid, 2026-11-12). Tested offline by
# agent/tests/test_identity_readbacks.py. Each check is [label, got, expected]; the script prints ok or FINDING.
#
# Object keys are lower-cased first (lk), so the Graph policy and the AuditLogs newValue JSON go through the same checks.
# Learn shows the audit JSON in the Graph shape: conditions.users.includeGroups, grantControls.builtInControls, state
# (https://learn.microsoft.com/entra/identity/conditional-access/troubleshoot-policy-changes-audit-log#reading-the-values).
# Report-only state: enabledForReportingButNotEnforced
# (https://learn.microsoft.com/graph/api/resources/conditionalaccesspolicy?view=graph-rest-1.0).
# Transfer methods are a flags string: none, deviceCodeFlow, authenticationTransfer
# (https://learn.microsoft.com/graph/api/resources/conditionalaccessauthenticationflows?view=graph-rest-1.0).

def lk: walk(if type == "object" then with_entries(.key |= ascii_downcase) else . end);
def low: if type == "string" then ascii_downcase else . end;
def idset: (. // []) | map(low) | sort;
def nz: if . == "" then "(none)" else . end;
def b: if . then "true" else "false" end;
def flags: (. // "") | tostring | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase)
  | map(select(. != "" and . != "none")) | sort | join(",") | nz;
def maskid: if type == "string" and test("^[0-9a-fA-F-]{36}$") then .[0:4] + "..." + .[-4:] else . end;
def row: map(tostring) | join("\u001f");

# One policy with lower-cased keys. $kind: "devicecode" (GA-CA-01) or "mfa" (GA-CA-02). $grp, $ea: object IDs.
def ca_checks($kind; $grp; $ea):
  .conditions.users as $u
  | .grantcontrols as $g
  | [ ["state", (.state // "MISSING"), "enabledForReportingButNotEnforced"],
      ["include groups = grp-larkfield-cm only", ($u.includegroups | idset == [$grp | low] | b), "true"],
      ["include users and roles (none)",
       (if ($u | type) != "object" then "MISSING" else (($u.includeusers // []) + ($u.includeroles // [])) | length end), 0],
      ["exclude users = the emergency access account only", ($u.excludeusers | idset == [$ea | low] | b), "true"] ]
  + if $kind == "devicecode" then
      [ ["authentication flows", (.conditions.authenticationflows.transfermethods | flags), "devicecodeflow"],
        ["grant", ($g.builtincontrols // [] | map(low) | sort | join(",") | nz), "block"] ]
    else
      # GA-CA-02 uses the built-in "Multifactor authentication" strength (Tooni's portal choice, 2026-11-13), which Learn
      # calls equivalent to the Require multifactor authentication grant; the two can't be combined in one policy
      # (https://learn.microsoft.com/entra/identity/authentication/concept-authentication-strengths#limitations).
      [ ["authentication flows (none)", (.conditions.authenticationflows.transfermethods | flags), "(none)"],
        ["built-in grant controls (none)", ($g.builtincontrols // [] | map(low) | sort | join(",") | nz), "(none)"],
        ["authentication strength",
         ($g.authenticationstrength.displayname // ($g.authenticationstrength.id // "(none)" | maskid)),
         "Multifactor authentication"] ]
    end;

# Information lines for one policy (not checked): target resources, excluded groups, client app types.
def ca_info:
  [ ["include resources", (.conditions.applications.includeapplications // [] | map(maskid) | join(",") | nz)],
    ["exclude resources", (.conditions.applications.excludeapplications // [] | map(maskid) | join(",") | nz)],
    ["exclude groups", (.conditions.users.excludegroups // [] | length)],
    ["client app types", (.conditions.clientapptypes // [] | join(",") | nz)] ];

# AuditLogs row -> the policy object in TargetResources[0].modifiedProperties[].newValue, keys lower-cased, or null.
# newValue is a JSON string (possibly encoded twice), so it's parsed up to twice; an array is read as its first item.
def jparse: if type == "string" then (fromjson? // .) else . end;
def audit_policy:
  [ (.Props | jparse)[]? | (.newValue // .newvalue) | jparse | jparse
    | if type == "array" then .[0] else . end | select(type == "object") | lk | select(has("conditions")) ] | .[0];

# The aadiam listing ({value: [...]}) -> checks for one named setting. $ws: the workspace resource ID; $cats: categories.
def diag_checks($name; $ws; $cats):
  [ .value[]? | select(.name == $name) ] as $m
  | [ ["settings named " + $name, ($m | length), 1] ]
  + if ($m | length) == 1 then
      $m[0].properties as $p
      | [ ["destination = ga-law-shared", ((($p.workspaceId // "") | ascii_downcase) == ($ws | ascii_downcase) | b), "true"],
          ["enabled categories", ([ $p.logs[]? | select(.enabled == true) | .category | ascii_downcase ] | sort | join(",")),
           ($cats | map(ascii_downcase) | sort | join(","))],
          ["storage or event hub destination (none)",
           ((($p.storageAccountId // $p.eventHubAuthorizationRuleId // $p.serviceBusRuleId) != null) | b), "false"] ]
    else [] end;

# Sign-in rows from SigninLogs and AADNonInteractiveUserSignInLogs. A device code row: AuthenticationProtocol deviceCode,
# or OriginalTransferMethod deviceCodeFlow (the non-interactive success row may carry only the second; findings,
# 2026-11-10). ConditionalAccessPolicies comes back as a JSON string from the CLI, or as an array.
def capol: if type == "string" then (fromjson? // []) elif type == "array" then . else [] end;
def ca_result($name): ((.CAP | capol | map(select(.displayName == $name)) | .[0].result) // "absent");
def devicecode: ((.AuthenticationProtocol // "") | ascii_downcase) == "devicecode"
  or ((.OriginalTransferMethod // "") | ascii_downcase) == "devicecodeflow";

# $users: {objectId: alias}. Pass per user: at least one device code row; on all of them GA-CA-01 reportOnlyFailure (a
# block that would apply) and GA-CA-02 reportOnlySuccess (Tooni's expectation; the built-in MFA strength includes a
# Temporary Access Pass, https://learn.microsoft.com/entra/identity/authentication/concept-authentication-strengths#built-in-and-custom-authentication-strengths).
def signin_checks($users; $ca01; $ca02):
  . as $rows
  | [ $users | to_entries[] | .key as $oid | .value as $alias
      | [ $rows[] | select(((.UserId // "") | ascii_downcase) == ($oid | ascii_downcase)) | select(devicecode) ] as $dc
      | ["\($alias): device code sign-ins", (if ($dc | length) > 0 then "1 or more" else "0" end), "1 or more"],
        ["\($alias): GA-CA-01 on device code sign-ins", ($dc | map(ca_result($ca01)) | unique | join(",") | nz),
         "reportOnlyFailure"],
        ["\($alias): GA-CA-02 on device code sign-ins", ($dc | map(ca_result($ca02)) | unique | join(",") | nz),
         "reportOnlySuccess"] ];

# Information per user (not checked): result codes on device code rows, rows per table.
def signin_info($users):
  . as $rows
  | [ $users | to_entries[] | .key as $oid | .value as $alias
      | [ $rows[] | select(((.UserId // "") | ascii_downcase) == ($oid | ascii_downcase)) ] as $all
      | ($all | map(select(devicecode))) as $dc
      | ["\($alias): result codes on device code sign-ins", ($dc | map(.ResultType | tostring) | unique | join(",") | nz)],
        ["\($alias): rows by table", ($all | group_by(.Tbl) | map("\(.[0].Tbl) \(length)") | join(", ") | nz)] ];
