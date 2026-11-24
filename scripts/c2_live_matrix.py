#!/usr/bin/env python3
"""Live C2 matrix, one case manager per run (item 5, C2). Run inside the VNet (the jumpbox), from the repo root, signed
in to the Azure CLI as one synthetic case manager in that person's own profile:

    .venv\\Scripts\\python -I scripts\\c2_live_matrix.py --expect-alias alder --run-date YYYYMMDD

What it does: builds get_claim_summary exactly as agent/case_assistant.py does (caller from the validated sign-in token,
the live claim store through the jumpbox managed identity, the live AgentToolAudit_CL sink), then calls the tool's
dispatch entry, the one the model reaches, once for each of the pack's claims. No model and no Foundry call.

- The caller comes only from the validated token (identity.validated_caller_oid). --expect-alias is an assertion: if
  the token's caller isn't that case manager, the run stops before any call. It never sets the caller.
- A caller who isn't in entitlements.json stops the run before any call (a wrong sign-in would otherwise show 30
  "expected" denies).
- One run per case manager per run date: if this run's files exist, it stops before signing in.
- Expected results come from entitlements.json: allow for the caller's caseload, deny not_in_caseload for every other
  claim. An unexpected allow (or an allow that returns another claim or extra fields) stops the run at once, exit 3:
  a C2 failure. An unexpected deny is recorded and the run continues, exit 1.
- Audit check: every call must leave exactly one audit record whose decision matches the result (allow for an allow,
  deny for a deny). A missing record or a mismatch stops the run at once, exit 5. That covers an allow with no audit
  row.
- Errors: an exception while building the backends or during a call stops the run, exit 6. The output file (if it's
  open) and stderr get "ERROR: stopped (<exception type>)" and the summary lines; never a traceback or the exception
  message, which could hold IDs.
- Output is masked: claims appear as their index in sorted order and their owner's alias, the caller as first 4 and
  last 4. Returned claim content is checked (claim ID, field names) and dropped; it's never printed or written.
- The .audit.jsonl file next to the output is NOT masked: it's the tool's local audit log, with full caller and claim
  IDs. It stays on the jumpbox and never goes into evidence; only the masked .txt is copied off.
- The audit rows carry redteam_id c2live-<run date>-<alias>, so the AgentToolAudit_CL read-back can find them.
- Not part of the agent: nothing under agent/ imports or references this script, and it isn't a tool (tested).
- A13 is out of scope: the managed identity is used only through the tool's reader and audit sink, as in the client.

Environment: GA_TENANT_ID, COSMOS_ENDPOINT, AUDIT_INGEST_ENDPOINT, AUDIT_DCR_ID, SCENARIO (default larkfield).
Exit codes: 0 all as expected; 1 unexpected denies only; 2 stopped before any call; 3 unexpected allow, stopped
(also when that call's audit record is missing or wrong); 4 second run refused; 5 audit mismatch, stopped; 6 error,
stopped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agent"))  # -I removes the script directory

import pack  # noqa: E402
from audit import AuditLog, AuditUnavailable  # noqa: E402
from claims_tool import RecordTool  # noqa: E402

PREFIX = "c2live"
DEFAULT_OUT = pack.ROOT / "agent" / "logs" / "c2-live"  # gitignored (agent/logs/)
_RUN_DATE = re.compile(r"^20[0-9]{6}$")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def mask(value: str) -> str:
    return f"{value[:4]}...{value[-4:]}"


def digest(ids) -> str:
    return hashlib.sha256("\n".join(sorted(ids)).encode("utf-8")).hexdigest()


def load_aliases(name: str | None = None) -> dict[str, str]:
    """Caller object ID -> alias, from entitlements.json (pack.load_entitlements keeps only the claims)."""
    data = json.loads((pack.pack_dir(name) / "entitlements.json").read_text(encoding="utf-8"))
    return {oid: entry["alias"] for oid, entry in data["caseloads"].items()}


def run_files(out_dir: Path, run_date: str, alias: str) -> tuple[str, Path, Path]:
    redteam_id = f"{PREFIX}-{run_date}-{alias}"
    return redteam_id, out_dir / f"{redteam_id}.txt", out_dir / f"{redteam_id}.audit.jsonl"


class _DecisionRecorder:
    """Wraps the audit log so the harness sees every decision and reason the tool logged, in order."""

    def __init__(self, inner: AuditLog):
        self._inner = inner
        self.entries: list[tuple[str, str]] = []

    def record(self, **kwargs):
        try:
            entry = self._inner.record(**kwargs)
        except AuditUnavailable:
            self.entries.append(("deny", "audit_unavailable"))  # what the local log holds for this allow (audit.py)
            raise
        self.entries.append((entry["decision"], entry["reason"]))
        return entry


def _default_caller() -> str:
    from azure.identity import AzureCliCredential

    from identity import validated_caller_oid

    return validated_caller_oid(AzureCliCredential(), os.environ["GA_TENANT_ID"])


def _default_backends(config: dict):
    from azure.identity import ManagedIdentityCredential

    from ingest import AUDIT_STREAM, IngestionSink
    from records import CosmosRecordReader

    store = config["record_store"]
    jumpbox_identity = ManagedIdentityCredential()
    reader = CosmosRecordReader(os.environ["COSMOS_ENDPOINT"], store["database"], store["container"], jumpbox_identity)
    sink = IngestionSink(os.environ["AUDIT_INGEST_ENDPOINT"], os.environ["AUDIT_DCR_ID"], AUDIT_STREAM,
                         jumpbox_identity)
    return reader, sink


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Live C2 matrix for one synthetic case manager (masked output)",
                                     allow_abbrev=False)
    parser.add_argument("--expect-alias", required=True,
                        help="assertion only: stop unless the signed-in caller is this case manager")
    parser.add_argument("--run-date", required=True, help="YYYYMMDD label shared by the three runs")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    return parser.parse_args(argv)


def main(argv: list[str], *, get_caller=_default_caller, make_backends=_default_backends) -> int:
    args = parse_args(argv)
    config = pack.load_config()
    aliases = load_aliases()
    if args.expect_alias not in set(aliases.values()):
        print(f"Stopped: --expect-alias must be one of {sorted(set(aliases.values()))}. Nothing was called.",
              file=sys.stderr)
        return 2
    if not _RUN_DATE.match(args.run_date):
        print("Stopped: --run-date must be YYYYMMDD. Nothing was called.", file=sys.stderr)
        return 2

    redteam_id, out_path, audit_path = run_files(args.out_dir, args.run_date, args.expect_alias)
    if out_path.exists() or audit_path.exists():
        print(f"Stopped: {redteam_id} has already run (files in {args.out_dir}). One run per case manager per run "
              "date. Nothing was called.", file=sys.stderr)
        return 4

    # Pack check: every claim belongs to exactly one caseload, and the caseloads cover every claim.
    caseloads = {oid: frozenset(ids) for oid, ids in pack.load_entitlements().items()}
    claims = sorted(r["claim_id"] for r in pack.load_records())
    owner = {c: aliases[oid] for oid, ids in caseloads.items() for c in ids}
    if (len(set(claims)) != len(claims) or set(owner) != set(claims)
            or sum(len(ids) for ids in caseloads.values()) != len(claims)):
        print("Stopped: entitlements.json and claims.json don't partition the same claims. Nothing was called.",
              file=sys.stderr)
        return 2

    try:
        caller = get_caller()
    except Exception as exc:  # CallerValidationError, a missing setting or a CLI failure: same outcome
        print(f"Stopped: couldn't validate your sign-in token ({type(exc).__name__}). Nothing was called.",
              file=sys.stderr)
        return 2
    if caller not in aliases:
        print(f"Stopped: the signed-in caller ({mask(caller)}) isn't one of the case managers in entitlements.json. "
              "Nothing was called.", file=sys.stderr)
        return 2
    if aliases[caller] != args.expect_alias:
        print(f"Stopped: signed in as {aliases[caller]}, expected {args.expect_alias}. Nothing was called.",
              file=sys.stderr)
        return 2

    alias, own = aliases[caller], caseloads[caller]
    fields = set(config["record_tool"]["returned_fields"])
    param = config["record_tool"]["id_parameter"]
    try:
        reader, sink = make_backends(config)
        args.out_dir.mkdir(parents=True, exist_ok=True)
        recorder = _DecisionRecorder(AuditLog(audit_path, sink=sink, redteam_id=redteam_id))
        tool = RecordTool(caller_oid=caller, entitlements=pack.load_entitlements(), reader=reader, audit=recorder,
                          config=config, conversation_id=redteam_id)
    except Exception as exc:  # type only: the message could hold an endpoint or an ID
        print(f"ERROR: stopped ({type(exc).__name__}) while building the backends. No claim was requested.",
              file=sys.stderr)
        return 6

    counts = {"allow": 0, "deny": 0, "unexpected_allow": 0, "unexpected_deny": 0, "audit_mismatch": 0,
              "own_allowed": 0}
    stop_code, stop_note, error = None, "", None
    with out_path.open("x", encoding="utf-8") as out:
        def say(line: str, *, to_stderr: bool = False) -> None:
            print(line, file=sys.stderr if to_stderr else sys.stdout)
            out.write(line + "\n")
            out.flush()

        say(f"run: {redteam_id} | caller: {alias} ({mask(caller)}) | start: {now()}")
        say(f"claims: {len(claims)} | own caseload: {len(own)} | sha256 of sorted claims: {digest(claims)}")
        say(f"sha256 of sorted own caseload: {digest(own)}")
        say("index | owner | expected | actual | reason | result")
        for index, claim_id in enumerate(claims, 1):
            expected = "allow" if claim_id in own else "deny"
            before = len(recorder.entries)
            try:
                result = json.loads(tool.dispatch(json.dumps({param: claim_id})))
            except Exception as exc:  # type only: the message could hold a claim ID or the caller
                error = f"ERROR: stopped ({type(exc).__name__}) at index {index:02d}"
                break
            if "error" in result:
                actual = "deny"
            else:
                # An allow must return the requested claim with tool fields only; anything else counts as an
                # unexpected allow. The content is dropped here and never printed or written.
                actual = "allow" if result.get("claim_id") == claim_id and set(result) <= fields else "allow_mismatch"
            del result
            # Audit check: exactly one record for this call, with the same decision as the result.
            logged = recorder.entries[before:]
            audit_ok = len(logged) == 1 and logged[0][0] == ("deny" if actual == "deny" else "allow")
            reason = (logged[-1][1] if logged else "") or "-"
            if actual != "deny" and (expected == "deny" or actual == "allow_mismatch"):
                verdict = "UNEXPECTED ALLOW: stopped" + ("" if audit_ok else "; AUDIT MISMATCH")
                counts["unexpected_allow"] += 1
                stop_code, stop_note = 3, " | STOPPED at the first unexpected allow"
            elif not audit_ok:
                verdict = "AUDIT MISMATCH: stopped"
                counts["audit_mismatch"] += 1
                stop_code, stop_note = 5, " | STOPPED at an audit mismatch"
            elif actual == "deny" and (expected == "allow" or reason != "not_in_caseload"):
                verdict = "UNEXPECTED DENY"
                counts["unexpected_deny"] += 1
            else:
                verdict = "ok"
            counts["allow" if actual != "deny" else "deny"] += 1
            if actual == "allow" and expected == "allow" and audit_ok:
                counts["own_allowed"] += 1
            say(f"{index:02d} | {owner[claim_id]} | {expected} | {actual} | {reason} | {verdict}")
            if stop_code:
                break
        if error:
            say(error, to_stderr=True)
            stop_code, stop_note = 6, " | STOPPED on an error"
        summary = [
            f"calls: {counts['allow'] + counts['deny']} | allow: {counts['allow']} | deny: {counts['deny']} | "
            f"unexpected allow: {counts['unexpected_allow']} | unexpected deny: {counts['unexpected_deny']} | "
            f"audit mismatch: {counts['audit_mismatch']}",
            f"positive control: {counts['own_allowed']} of {len(own)} assigned claims allowed",
            f"end: {now()}{stop_note}",
        ]
        for line in summary:
            say(line, to_stderr=bool(error))
    if stop_code:
        return stop_code
    return 1 if counts["unexpected_deny"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
