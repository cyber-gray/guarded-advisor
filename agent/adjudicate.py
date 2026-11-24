#!/usr/bin/env python3
"""Record what a case manager did with an assistant draft (C8). Run inside the VNet (the jumpbox).

    python -I agent/adjudicate.py --conversation-id conv_... --claim-id LM-CLM-2026-0007 \
        --outcome agree --rationale-code matches_source

C8: the adjudicator's decision and rationale are recorded separately from the assistant's output and linked by case
and conversation ID, so the agree/override rate can be computed from AdjudicationLog_CL. The claim decision itself
is made outside this lab (C1); `outcome` is what the case manager did with the draft.

- The caller comes only from the validated sign-in token (identity.py), never from an argument or the environment.
  If the token can't be validated, nothing is recorded.
- A case manager can record outcomes only for claims in their own caseload (the same entitlement map as the tool).
- Fixed codes only, no free text: the table is Protected (intake record: adjudicator decisions are Highly
  confidential) and holds IDs and codes, never claim content (D-022).
- Each row goes to agent/logs/adjudication.jsonl and to AdjudicationLog_CL through ga-dcr-agent-shared with the
  jumpbox managed identity. If the upload fails, the script says so and exits 1.

Environment: GA_TENANT_ID, AUDIT_INGEST_ENDPOINT, AUDIT_DCR_ID, SCENARIO (default larkfield).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I removes the script directory from sys.path

import pack  # noqa: E402
from identity import CallerValidationError, validated_caller_oid  # noqa: E402
from ingest import ADJUDICATION_STREAM, IngestionError, IngestionSink  # noqa: E402

OUTCOMES = ("agree", "modified", "rejected")
RATIONALE_CODES = ("matches_source", "factual_error", "missing_information", "policy_judgment", "other")
_CONVERSATION_ID = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


class NotInCaseload(PermissionError):
    pass


def build_row(*, caller: str, entitlements: dict[str, frozenset[str]], config: dict, conversation_id: str,
              claim_id: str, outcome: str, rationale_code: str) -> dict:
    """One AdjudicationLog_CL row, after every check. Raises ValueError or NotInCaseload."""
    if not re.match(config["record_tool"]["id_pattern"], claim_id or ""):
        raise ValueError("invalid claim ID")
    if not _CONVERSATION_ID.match(conversation_id or ""):
        raise ValueError("invalid conversation ID")
    if outcome not in OUTCOMES:
        raise ValueError(f"outcome must be one of {', '.join(OUTCOMES)}")
    if rationale_code not in RATIONALE_CODES:
        raise ValueError(f"rationale code must be one of {', '.join(RATIONALE_CODES)}")
    if claim_id not in entitlements.get(caller, frozenset()):
        raise NotInCaseload("you can only record outcomes for claims in your own caseload")
    return {
        "TimeGenerated": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "caller": caller,
        "record_id": claim_id,
        "scenario": config["scenario"],
        "conversation_id": conversation_id,
        "outcome": outcome,
        "rationale_code": rationale_code,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Record a case manager's outcome for an assistant draft (C8)")
    parser.add_argument("--conversation-id", required=True, help="the conversation the draft came from")
    parser.add_argument("--claim-id", required=True)
    parser.add_argument("--outcome", required=True, choices=OUTCOMES)
    parser.add_argument("--rationale-code", required=True, choices=RATIONALE_CODES)
    parser.add_argument("--local-log", type=Path, default=pack.ROOT / "agent" / "logs" / "adjudication.jsonl")
    args = parser.parse_args()

    from azure.identity import AzureCliCredential, ManagedIdentityCredential

    config = pack.load_config()
    # Fail closed, as in case_assistant.py: no fallback to unvalidated claims or the environment.
    try:
        caller = validated_caller_oid(AzureCliCredential(), os.environ["GA_TENANT_ID"])
    except CallerValidationError as exc:
        print(f"Stopped: couldn't validate your sign-in token ({exc}). Nothing was recorded.", file=sys.stderr)
        return 2
    try:
        row = build_row(caller=caller, entitlements=pack.load_entitlements(), config=config,
                        conversation_id=args.conversation_id, claim_id=args.claim_id, outcome=args.outcome,
                        rationale_code=args.rationale_code)
    except (ValueError, NotInCaseload) as exc:
        print(f"Not recorded: {exc}", file=sys.stderr)
        return 3

    args.local_log.parent.mkdir(parents=True, exist_ok=True)
    with args.local_log.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row) + "\n")
    sink = IngestionSink(os.environ["AUDIT_INGEST_ENDPOINT"], os.environ["AUDIT_DCR_ID"], ADJUDICATION_STREAM,
                         ManagedIdentityCredential())
    try:
        sink.send([row])
    except IngestionError as exc:
        print(f"Recorded locally only ({args.local_log}); upload failed: {exc}", file=sys.stderr)
        return 1
    print(f"Recorded: {row['record_id']} {row['outcome']} ({row['rationale_code']}), conversation "
          f"{row['conversation_id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
