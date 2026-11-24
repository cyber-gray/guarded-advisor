"""get_claim_summary: the record tool, run by the client app (C1, C2).

- The tool is bound to one validated caller when it's constructed (identity.validated_caller_oid). The callable the model
  reaches, dispatch(arguments_json), accepts exactly one argument, the record ID; anything else is refused and logged.
- The entitlement check runs in code before any read. A record outside the caller's caseload is refused with the same
  message whether or not it exists.
- Reads go through a read-only reader (the jumpbox managed identity with Cosmos DB Built-in Data Reader); no write path.
- Every allow and deny goes to the audit log with fixed fields only (audit.py), never the returned content.
- Fail closed on allows (D-022): if the allow can't be audited in the workspace, the record isn't returned.
- Don't add azure.ai.projects.telemetry.trace_function here: it always records parameters and return values, whatever
  the content-recording setting says (Learn, client-side tracing).
"""
from __future__ import annotations

import json
import re
from typing import Protocol

from audit import AuditUnavailable


class RecordReader(Protocol):
    def read(self, record_id: str) -> dict | None: ...


def tool_schema(config: dict) -> dict:
    """Function tool definition for the agent: one string parameter, strict, no additional properties."""
    t = config["record_tool"]
    return {
        "name": t["name"],
        "description": t["description"],
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {t["id_parameter"]: {"type": "string", "description": t["id_description"]}},
            "required": [t["id_parameter"]],
            "additionalProperties": False,
        },
    }


class RecordTool:
    def __init__(self, *, caller_oid: str, entitlements: dict[str, frozenset[str]], reader: RecordReader, audit,
                 config: dict, conversation_id):  # a string, or a zero-argument callable (agent_session.audit_id)
        t = config["record_tool"]
        self._caller = caller_oid
        self._allowed = entitlements.get(caller_oid, frozenset())
        self._reader = reader
        self._audit = audit
        self._scenario = config["scenario"]
        self._param = t["id_parameter"]
        self._pattern = re.compile(t["id_pattern"])
        self._fields = tuple(t["returned_fields"])
        self._conversation_id = conversation_id
        self.name = t["name"]
        self.records_returned: list[str] = []  # IDs only, for the client's "Claim records used" line (C8)

    @property
    def caller(self) -> str:  # read-only: there's no way to change the caller after construction
        return self._caller

    def _conversation_id_now(self) -> str:
        cid = self._conversation_id
        return cid() if callable(cid) else cid

    def _log(self, record_id: str, decision: str, reason: str | None) -> None:
        self._audit.record(caller=self._caller, record_id=record_id, scenario=self._scenario, action="read",
                           decision=decision, conversation_id=self._conversation_id_now(), reason=reason,
                           tool_name=self.name)

    def lookup(self, record_id: str) -> dict:
        """The only operation: return the summary of one record in the caller's caseload."""
        if not isinstance(record_id, str) or not self._pattern.match(record_id):
            self._log(str(record_id)[:64] if isinstance(record_id, str) else "", "deny", "invalid_record_id")
            return {"error": "invalid claim ID"}
        if record_id not in self._allowed:
            self._log(record_id, "deny", "not_in_caseload")
            return {"error": "this claim isn't available to you"}
        record = self._reader.read(record_id)
        if record is None:
            self._log(record_id, "deny", "not_found")
            return {"error": "this claim isn't available to you"}
        try:
            self._log(record_id, "allow", None)  # written before anything is returned (D-022)
        except AuditUnavailable:
            return {"error": "audit unavailable; the claim wasn't returned"}
        if record_id not in self.records_returned:
            self.records_returned.append(record_id)
        return {k: record[k] for k in self._fields if k in record}

    def dispatch(self, arguments_json: str) -> str:
        """Entry point for a function_call from the model. Returns the function_call_output string."""
        try:
            args = json.loads(arguments_json)
        except (TypeError, ValueError):
            args = None
        if not isinstance(args, dict) or set(args) != {self._param}:
            attempted = args.get(self._param, "") if isinstance(args, dict) else ""
            self._log(attempted if isinstance(attempted, str) else "", "deny", "invalid_arguments")
            return json.dumps({"error": f"invalid arguments: only {self._param} is accepted"})
        return json.dumps(self.lookup(args[self._param]))
