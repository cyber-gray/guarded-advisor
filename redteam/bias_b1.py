#!/usr/bin/env python3
"""Bias test B1 runner (w3-bias, C7). Sends each side of each pair to the case assistant 3 times and writes one JSONL
row per call. Compare with redteam/bias_compare.py. Not run on 2026-11-11 (prep only).

    python -I redteam/bias_b1.py --out <private path>.jsonl --date 20261111            # live, on the jumpbox
    python3 -I redteam/bias_b1.py --dry-run                                             # offline: plan only
    python -I redteam/bias_b1.py --probe --date 20261111                                # jumpbox: 1 call, fields only

Design (a), 2026-11-11: the claim text is in the user message (pairs.json "prompt"), so no claim store, entitlement or
audit change. The record tool isn't offered a real claim: a function call is refused and counted, never executed.

Temperature 0 and the JSON schema (text.format) live in the B1 agent's definition, larkfield-case-assistant-b1
(agent/b1_agent.py, its own create and delete gates). The 11-11 probe showed a request can't carry temperature or text
when an agent is named (findings 2026-11-11), and Learn says that for prompt agents the agent configuration holds
them (https://learn.microsoft.com/agent-framework/integrations/by-component/agent-services/foundry). The runner calls
the B1 agent through its own endpoint (client fix B: AIProjectClient with allow_preview=True and
get_openai_client(agent_name=...)), with no per-call settings and no agent_reference, so alder needs only Foundry
Agent Consumer. It still reads the effective values back from each response and stops at the first call where they
aren't 0 and json_schema (fail closed).

Caller: alder (a case manager; az login on the jumpbox). The token is validated and the caller must be alder in the
pack's entitlement map. Telemetry is off: this script never configures it (D-020; 2026-11-11 decision).
Results hold the model's JSON output for synthetic claims, so --out must be outside the repository and must not exist.
Environment: FOUNDRY_PROJECT_ENDPOINT, GA_TENANT_ID, SCENARIO (default larkfield).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent"))

RUNS = 3
CALLER_ALIAS = "alder"


def load_pairs(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def redteam_id(pair_id: str, side: str, run: int, date: str) -> str:
    """B1-<pair>-<side>-<run>-<date>, for example B1-07-A-2-20261111 (pair IDs are B1-07 in pairs.json)."""
    return f"B1-{pair_id.removeprefix('B1-')}-{side}-{run}-{date}"


def plan(doc: dict, date: str, runs: int = RUNS, only: str | None = None) -> list[dict]:
    calls = []
    for p in doc["pairs"]:
        if only and p["pair_id"] != only:
            continue
        for label in ("a", "b"):
            s = p[label]
            for run in range(1, runs + 1):
                calls.append({"redteam_id": redteam_id(p["pair_id"], label.upper(), run, date),
                              "pair_id": p["pair_id"], "side": label.upper(), "run": run,
                              "attribute": p["attribute"], "message": doc["prompt"].format(text=s["text"])})
    return calls


def check_out_path(out: Path) -> str | None:
    """A reason to refuse --out, or None."""
    resolved = out.expanduser().resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        return "--out is inside the repository; results go to a private path"
    if resolved.exists():
        return "--out already exists; choose a new file"
    return None


def parse_output(text: str, schema: dict) -> tuple[dict | None, str | None]:
    """The parsed summary and None, or None and a reason. Checks keys and enum values only."""
    try:
        out = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None, "output_not_json"
    if not isinstance(out, dict) or set(out) != set(schema["required"]):
        return None, "output_keys"
    props = schema["properties"]
    for key in ("recommended_next_step", "urgency"):
        if out[key] not in props[key]["enum"]:
            return None, f"output_enum:{key}"
    if not isinstance(out["requested_documents"], list) or not all(isinstance(d, str) for d in out["requested_documents"]):
        return None, "output_documents"
    return out, None


PROBE_ID = "B1-probe-{date}"


def field_report(response) -> dict:
    """The effective sampling and format fields of a response: {field: {"present": bool, "value": ...}}.
    A field the response doesn't carry, or carries as null, is reported as not present."""
    fields = {
        "temperature": getattr(response, "temperature", None),
        "top_p": getattr(response, "top_p", None),
        "text.format": getattr(getattr(getattr(response, "text", None), "format", None), "type", None),
    }
    return {k: {"present": v is not None, "value": v} for k, v in fields.items()}


def format_report(report: dict) -> str:
    return " | ".join(f"{k} {'present' if v['present'] else 'not present'}"
                      + (f" = {v['value']!r}" if v["present"] else "") for k, v in report.items())


def effective(response) -> tuple[float | None, str | None]:
    report = field_report(response)
    return report["temperature"]["value"], report["text.format"]["value"]


def main() -> int:
    parser = argparse.ArgumentParser(description="B1 bias runner (synthetic claims)")
    parser.add_argument("--pairs", type=Path, default=ROOT / "scenarios" / "larkfield" / "bias" / "pairs.json")
    parser.add_argument("--out", type=Path, help="results JSONL, outside the repository, new file")
    parser.add_argument("--date", default="20261111", help="date label in each redteam_id (YYYYMMDD)")
    parser.add_argument("--only", help="one pair ID, for a smoke run")
    parser.add_argument("--dry-run", action="store_true", help="print the plan; no Azure calls")
    parser.add_argument("--probe", action="store_true",
                        help="one call (B1-probe-<date>, pair B1-01 side A); prints only the effective temperature, "
                             "top_p and text.format and whether each was present; writes nothing")
    args = parser.parse_args()

    doc = load_pairs(args.pairs)
    calls = plan(doc, args.date, only=args.only)
    if args.dry_run:
        lengths = [len(c["message"]) for c in calls]
        print(f"calls {len(calls)} | pairs {len({c['pair_id'] for c in calls})} | runs per side {RUNS} | "
              f"message chars {min(lengths)} to {max(lengths)} | first {calls[0]['redteam_id']} | "
              f"last {calls[-1]['redteam_id']}")
        return 0
    if not args.probe:
        if not args.out:
            parser.error("--out is required for a live run")
        reason = check_out_path(args.out)
        if reason:
            print(f"STOP: {reason}", file=sys.stderr)
            return 2

    from azure.ai.projects import AIProjectClient
    from azure.identity import AzureCliCredential

    import pack
    from agent_session import AgentSession
    from client_loop import INCLUDE, run_turn
    from identity import CallerValidationError, validated_caller_oid

    config = pack.load_config()
    credential = AzureCliCredential()
    try:
        caller = validated_caller_oid(credential, os.environ["GA_TENANT_ID"])
    except CallerValidationError as exc:
        print(f"STOP: couldn't validate the sign-in token ({exc}); nothing was called.", file=sys.stderr)
        return 2
    caseloads = json.loads((pack.pack_dir() / "entitlements.json").read_text(encoding="utf-8"))["caseloads"]
    if caseloads.get(caller, {}).get("alias") != CALLER_ALIAS:
        print(f"STOP: B1 runs as {CALLER_ALIAS}; the signed-in account isn't {CALLER_ALIAS}.", file=sys.stderr)
        return 2

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=credential,
                              allow_preview=True)
    # The B1 agent's own endpoint: its definition holds temperature 0 and the schema (agent/b1_agent.py).
    openai = project.get_openai_client(agent_name=config["b1_agent"]["agent_name"])
    schema = doc["output_schema"]

    if args.probe:
        # One request, no tool loop and no output text: only the three fields are printed. Nothing is written.
        message = doc["prompt"].format(text=doc["pairs"][0]["a"]["text"])
        response = AgentSession(openai, INCLUDE).start().create_response(message)
        print(f"{PROBE_ID.format(date=args.date)} | {format_report(field_report(response))}")
        return 0

    out = args.out.expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    print(f"B1: {len(calls)} calls as {CALLER_ALIAS}; results to {out}")
    with out.open("x", encoding="utf-8") as fh:
        for i, c in enumerate(calls, 1):
            row = {k: c[k] for k in ("redteam_id", "pair_id", "side", "run", "attribute")}
            refused: list[str] = []
            settings_ok = True  # stays True when there's no response to read (an error is recorded instead)
            try:
                session = AgentSession(openai, INCLUDE).start()  # a new conversation (or chain) per call
                row["session_mode"] = session.mode
                result = run_turn(session.create_response, c["message"], {}, max_tool_calls=2,
                                  on_refused=refused.append)
                row["conversation_id"] = session.audit_id()
                row.update(tool_calls=result.tool_calls, refused_tools=refused, file_search_ran=result.searched,
                           stopped=result.stopped)
                if result.response is not None:
                    temperature, fmt = effective(result.response)
                    row.update(temperature=temperature, text_format=fmt)
                    settings_ok = temperature == 0 and fmt == "json_schema"
                summary, error = parse_output(result.text, schema)
                row.update(output=summary, error=error)
                if error:
                    row["raw_text"] = result.text  # synthetic claim summary; private file
            except Exception as exc:  # recorded, then the run continues (a content_filter block is a result)
                row.update(output=None, error=f"{type(exc).__name__}:{getattr(exc, 'code', '') or ''}")
            fh.write(json.dumps(row, ensure_ascii=True) + "\n")
            fh.flush()
            print(f"{i}/{len(calls)} {row['redteam_id']} | {row.get('error') or 'ok'}")
            if not settings_ok:
                print(f"STOP: effective temperature {row.get('temperature')!r}, format {row.get('text_format')!r}; "
                      "the B1 agent's definition didn't take effect. Check it with `python agent/b1_agent.py show`; "
                      "delete and fix it (its own gate) before rerunning.",
                      file=sys.stderr)
                return 3
    print(f"done | {len(calls)} rows | compare: python -I redteam/bias_compare.py --results {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
