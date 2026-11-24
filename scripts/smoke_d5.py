#!/usr/bin/env python3
"""Send three synthetic deny rows to AgentToolAudit_CL to test the D5 rule (w3-kql, C2). Run inside the VNet
(the jumpbox), from the repo root:

    .venv\\Scripts\\python -I scripts\\smoke_d5.py

Why the jumpbox: ga-dce-shared has public network access Disabled, and an outside write is refused (findings, V4).
- Takes no arguments. Every value is fixed here except TimeGenerated and the TAG (UTC time of the send).
- Positive: 2 deny rows, one caller, conversation d5smoke-<TAG>-pos. Negative: 1 deny row, d5smoke-<TAG>-neg.
- scenario is "smoke"; record_id is SMOKE-1 to SMOKE-3, never a claim ID; the caller is a fixed synthetic ID that
  no Entra object has. Queries other than D5 must exclude scenario == "smoke" (detections/README.md).
- Expected: exactly one D5 alert, for the -pos conversation, about 15 minutes after the send.
- Writes through ga-dcr-agent-shared with the jumpbox managed identity (R6), like smoke_adjudication.py.

Environment: AUDIT_INGEST_ENDPOINT, AUDIT_DCR_ID.
"""
from __future__ import annotations

import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))  # -I removes the script directory

from ingest import AUDIT_STREAM, IngestionError, IngestionSink  # noqa: E402

SMOKE_CALLER = str(uuid.UUID(int=0xD5))  # synthetic; built at run time so no ID-shaped literal is committed
FIXED = {"caller": SMOKE_CALLER, "scenario": "smoke", "action": "read", "decision": "deny",
         "reason": "smoke", "tool_name": "get_claim_summary"}


def build_smoke_rows(tag: str, now: str) -> list[dict]:
    """The only rows this script writes: 2 in the positive conversation, 1 in the negative."""
    run = f"d5smoke-{tag}"
    return [{"TimeGenerated": now, **FIXED, "record_id": f"SMOKE-{n}", "conversation_id": f"{run}-{side}",
             "redteam_id": run} for n, side in ((1, "pos"), (2, "pos"), (3, "neg"))]


def main(argv: list[str]) -> int:
    if argv:
        print("smoke_d5.py takes no arguments; every value is fixed. Nothing was sent.", file=sys.stderr)
        return 2
    from azure.identity import ManagedIdentityCredential

    sent = datetime.now(timezone.utc)
    tag = sent.strftime("%Y%m%dT%H%M%SZ")
    rows = build_smoke_rows(tag, sent.isoformat(timespec="milliseconds"))
    sink = IngestionSink(os.environ["AUDIT_INGEST_ENDPOINT"], os.environ["AUDIT_DCR_ID"], AUDIT_STREAM,
                         ManagedIdentityCredential())
    try:
        sink.send(rows)
    except IngestionError as exc:
        print(f"Upload failed: {exc}", file=sys.stderr)
        return 1
    print(f"Sent 3 rows at {rows[0]['TimeGenerated']}, redteam_id d5smoke-{tag}. Check for one D5 alert at +15 min.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
