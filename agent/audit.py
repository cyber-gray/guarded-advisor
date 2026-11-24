"""Tool audit log (C2, C4, C6). One entry per decision, with fixed fields only.

The fields match AgentToolAudit_CL (infra/custom-tables.bicep, D-022): who, which record, which pack, what action, the
decision, the conversation, the tool, the red-team run and the time. There is deliberately no way to pass record
content: record() takes keyword-only arguments for exactly these fields, `detail` accepts only a few typed sandbox
keys, and returned claim data can't end up in the log.

Every entry goes to the local JSONL file. With a sink (the Logs Ingestion API, agent/ingest.py), it's uploaded first,
and an allow fails closed (D-022, Tooni 2026-10-22): if the upload fails, the entry is written locally as a deny with
reason "audit_unavailable" and AuditUnavailable is raised, so the caller doesn't return the record. A deny is returned
either way; if its upload fails, it's still in the local file.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

AUDIT_FIELDS = ("time", "caller", "record_id", "scenario", "action", "decision", "reason", "conversation_id",
                "tool_name", "redteam_id", "detail")
DETAIL_TYPES = {"exit_code": int, "duration_ms": int, "egress_blocked": bool}  # sandbox events only (C4)
_SAFE_ID = re.compile(r"^[A-Za-z0-9._:-]{0,64}$")


class AuditUnavailable(RuntimeError):
    """The audit row for an allow couldn't be written to the workspace: don't return the record."""


def _check_detail(detail: dict | None) -> dict | None:
    if detail is None:
        return None
    if not isinstance(detail, dict) or set(detail) - set(DETAIL_TYPES):
        raise ValueError(f"detail accepts only {sorted(DETAIL_TYPES)}")
    for key, value in detail.items():
        expected = DETAIL_TYPES[key]
        if type(value) is not expected:  # bool is a subclass of int; be exact
            raise ValueError(f"detail[{key!r}] must be {expected.__name__}")
    return dict(detail)


def to_row(entry: dict) -> dict:
    """Local entry -> AgentToolAudit_CL row: `time` becomes TimeGenerated, other fields keep their names."""
    return {"TimeGenerated": entry["time"], **{k: entry[k] for k in AUDIT_FIELDS if k != "time"}}


class AuditLog:
    def __init__(self, path: Path, *, sink=None, redteam_id: str | None = None):
        if redteam_id is not None and not (redteam_id and _SAFE_ID.match(redteam_id)):
            raise ValueError("redteam_id must be a short plain identifier")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._sink = sink
        self._redteam_id = redteam_id

    def _write(self, entry: dict) -> None:
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=False) + "\n")

    def record(self, *, caller: str, record_id: str, scenario: str, action: str, decision: str,
               conversation_id: str, reason: str | None = None, tool_name: str | None = None,
               detail: dict | None = None) -> dict:
        # "withheld": an answer the client didn't show (decision-language check, C1). D5 counts "deny" only.
        if decision not in ("allow", "deny", "withheld"):
            raise ValueError("decision must be 'allow', 'deny' or 'withheld'")
        entry = {
            "time": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "caller": caller,
            # Attempted IDs can come from the model; keep only short, plain identifiers.
            "record_id": record_id if _SAFE_ID.match(record_id or "") else "<invalid>",
            "scenario": scenario,
            "action": action,
            "decision": decision,
            # String columns: None is written as "" so the local JSONL matches the table (a null string column reads "").
            "reason": reason or "",
            "conversation_id": conversation_id,
            # An unknown tool's name comes from the model, like attempted IDs.
            "tool_name": "" if tool_name is None else (tool_name if _SAFE_ID.match(tool_name) else "<invalid>"),
            "redteam_id": self._redteam_id or "",
            "detail": _check_detail(detail),
        }
        if self._sink is not None:
            try:
                self._sink.send([to_row(entry)])
            except Exception as exc:
                if decision == "allow":
                    self._write({**entry, "decision": "deny", "reason": "audit_unavailable"})
                    raise AuditUnavailable("audit upload failed; the record isn't returned") from exc
                print(f"warning: audit upload failed ({type(exc).__name__}); the deny is in {self.path} only",
                      file=sys.stderr)
        self._write(entry)
        return entry
