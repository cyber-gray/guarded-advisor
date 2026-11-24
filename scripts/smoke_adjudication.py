#!/usr/bin/env python3
"""Write one synthetic SMOKE row to AdjudicationLog_CL (w2-privread verification, C8 ingestion path). Run inside the
VNet (the jumpbox), from the repo root:

    .venv\\Scripts\\python -I scripts\\smoke_adjudication.py

Why: AdjudicationLog_CL is empty, so a protected-table read test on it can't tell "no access" from "no rows". One
SMOKE row gives the w2-privread queries something to find (the working run sheet, item 3).

- Takes no arguments. Every row value is fixed here: record_id and conversation_id are SMOKE, so no claim ID, outcome
  or free text can be passed in, and no real claim is ever named.
- Not part of the agent: nothing under agent/ imports or references this script, and it isn't a tool (tested in
  agent/tests/test_smoke_adjudication.py). It isn't agent/adjudicate.py either, which stays the only path for real
  outcomes and keeps its caseload check.
- The C8 agree and override query excludes SMOKE rows (detections/c8-agree-override-rate.kql).
- The caller comes from the validated sign-in token, as in adjudicate.py, so the row shows who wrote it. If the token
  can't be validated, nothing is sent.
- The row goes through ga-dcr-agent-shared with the jumpbox managed identity (R6), the same writer adjudicate.py uses.
  It isn't written to agent/logs/adjudication.jsonl.

Environment: GA_TENANT_ID, AUDIT_INGEST_ENDPOINT, AUDIT_DCR_ID, SCENARIO (default larkfield).
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))  # -I removes the script directory

import pack  # noqa: E402
from identity import CallerValidationError, validated_caller_oid  # noqa: E402
from ingest import ADJUDICATION_STREAM, IngestionError, IngestionSink  # noqa: E402

SMOKE = "SMOKE"
SMOKE_VALUES = {
    "record_id": SMOKE,
    "conversation_id": SMOKE,
    "outcome": "agree",
    "rationale_code": "other",
}


def build_smoke_row(*, caller: str, scenario: str) -> dict:
    """The only row this script writes. The caller and scenario come from the token and the pack, never from input."""
    return {"TimeGenerated": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "caller": caller,
            "scenario": scenario, **SMOKE_VALUES}


def main(argv: list[str]) -> int:
    if argv:
        print("smoke_adjudication.py takes no arguments; every value is fixed. Nothing was sent.", file=sys.stderr)
        return 2

    from azure.identity import AzureCliCredential, ManagedIdentityCredential

    try:
        caller = validated_caller_oid(AzureCliCredential(), os.environ["GA_TENANT_ID"])
    except CallerValidationError as exc:
        print(f"Stopped: couldn't validate your sign-in token ({exc}). Nothing was sent.", file=sys.stderr)
        return 2
    row = build_smoke_row(caller=caller, scenario=pack.load_config()["scenario"])
    sink = IngestionSink(os.environ["AUDIT_INGEST_ENDPOINT"], os.environ["AUDIT_DCR_ID"], ADJUDICATION_STREAM,
                         ManagedIdentityCredential())
    try:
        sink.send([row])
    except IngestionError as exc:
        print(f"Upload failed: {exc}", file=sys.stderr)
        return 1
    print(f"Sent one SMOKE row to AdjudicationLog_CL at {row['TimeGenerated']}; allow a few minutes to ingest.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
