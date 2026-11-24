#!/usr/bin/env python3
"""Ground-truth logger for red-team runs (w3-harness, D-022). One RedTeamRun_CL row per run.

Every run gets a redteam_id that is also sent as the x-redteam-id header (gateway) or --redteam-id (case
assistant), so what the attacker did can be joined to what each control logged. Detection is computed by that join,
never written here (the lab's honest-results rule: numbers come from queries).

Rows hold labels, IDs and a hash of the payload file, never the payload or the response.
Writes through ga-dcr-redteam-shared's own public endpoint with T's Azure CLI sign-in (Monitoring Metrics
Publisher on that DCR only, R7), from the laptop (D-022, D-045). The jumpbox only runs --smoke once, as the negative
AMPLS test (Mon 2026-11-16 row 4a); no case-manager run there ever registers or runs as T.

    python3 -I redteam/ground_truth.py --smoke                                  # one SMOKE row (w2-custom V5)
    python3 -I redteam/ground_truth.py list --plan redteam/plans/run-20261116.json        # offline: the plan
    python  -I redteam/ground_truth.py register --plan redteam/plans/run-20261116.json \
        --run DF1-20261116 --local <private path>.jsonl                          # one row, BEFORE that run

register writes a pre-registration row: started_at = ended_at = the registration time, run_tool "harness", and
harness_verdict holds the EXPECTED result as expect-blocked, expect-refused or expect-complied, never an outcome.
Every outcome query excludes harness_verdict values starting with "expect-" (D-045; agent/tests/test_ground_truth.py).
The row is sent first and recorded locally only after the upload succeeds, so a failed upload can be retried and a
second registration of the same run is refused. Exit codes: 0 registered, 1 not written (don't start the run),
3 already registered.

Environment: REDTEAM_INGEST_ENDPOINT (custom-tables.bicep output redteamIngestionEndpoint),
REDTEAM_DCR_ID (output redteamDcrImmutableId, dcr-...).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent"))  # shared ingestion wrapper; -I removes script directories from sys.path

from ingest import REDTEAM_STREAM, IngestionSink  # noqa: E402

RUN_TOOLS = ("promptfoo", "pyrit", "garak", "harness", "manual")
TARGETS = ("gateway", "agent", "tool", "sandbox", "guardrail", "human", "none")
EXPECTED = ("expect-blocked", "expect-refused", "expect-complied")
VERDICTS = ("refused", "complied", "blocked", "error", "smoke") + EXPECTED
TOOL_LOGS = ("allow", "deny", "none")
# What AgentToolAudit_CL can hold for each expected result (scripts/c6_match.sh): a refusal is a deny, a block
# happens before any tool call, and a completed run may or may not read a record.
TOOL_LOGS_FOR = {"expect-refused": {"deny"}, "expect-blocked": {"none"}, "expect-complied": {"allow", "none"}}
_PATTERNS = {
    # An allowlist for the run label shared with --redteam-id, AgentToolAudit_CL and KQL datatables (D-045): letters,
    # digits, hyphen and underscore only. Stricter than audit._SAFE_ID, so every allowed ID also passes the audit log.
    "redteam_id": re.compile(r"^[A-Za-z0-9_-]{1,64}$"),
    "attack_id": re.compile(r"^(A[0-9]{1,2}|B[0-9]{1,2}|DF[0-9]|C8|SMOKE)$"),
    "expected_control": re.compile(r"^(C[1-8]|none)$"),
    "expected_detection": re.compile(r"^(D[1-9]|defender|none)$"),
    "technique": re.compile(r"^[a-z0-9_-]{1,40}$"),
    "scenario": re.compile(r"^[a-z0-9-]{1,32}$"),
    # An object ID, or a caller label: the synthetic case manager aliases or the role code T (D-044).
    "caller": re.compile(r"^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|alder|birch|cedar|T)?$"),
    "conversation_id": re.compile(r"^[A-Za-z0-9._:-]{0,128}$"),
    "payload_sha256": re.compile(r"^([0-9a-f]{64})?$"),
}
PLAN_KEYS = {"redteam_id", "case", "caller", "layer", "control", "detection", "expect", "technique", "payload",
             "tool_log"}
_EPOCH = datetime(2000, 1, 1, tzinfo=timezone.utc)
# --smoke keeps its local record here (git-ignored, redteam/logs/); register writes to --local.
SMOKE_LOG = ROOT / "redteam" / "logs" / "ground-truth.jsonl"


def new_redteam_id() -> str:
    return str(uuid.uuid4())


def payload_sha256(path: Path | None) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if path else ""


def _iso(value: datetime) -> str:
    if value.tzinfo is None:
        raise ValueError("timestamps must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds")


def build_row(*, redteam_id: str, attack_id: str, scenario: str, run_tool: str, technique: str, target: str,
              expected_control: str, expected_detection: str, harness_verdict: str, started_at: datetime,
              ended_at: datetime, caller: str = "", conversation_id: str = "", payload_sha256: str = "") -> dict:
    """One RedTeamRun_CL row; every field is checked against a fixed list or pattern, so free text can't get in."""
    for name, value in (("run_tool", run_tool), ("target", target), ("harness_verdict", harness_verdict)):
        allowed = {"run_tool": RUN_TOOLS, "target": TARGETS, "harness_verdict": VERDICTS}[name]
        if value not in allowed:
            raise ValueError(f"{name} must be one of {', '.join(allowed)}")
    fields = {"redteam_id": redteam_id, "attack_id": attack_id, "scenario": scenario, "technique": technique,
              "expected_control": expected_control, "expected_detection": expected_detection, "caller": caller,
              "conversation_id": conversation_id, "payload_sha256": payload_sha256}
    for name, value in fields.items():
        if not isinstance(value, str) or not _PATTERNS[name].match(value):
            raise ValueError(f"invalid {name}")
    started, ended = _iso(started_at), _iso(ended_at)  # checks both are timezone-aware before comparing
    if ended_at < started_at:
        raise ValueError("ended_at is before started_at")
    return {"TimeGenerated": ended, "run_tool": run_tool, "target": target, "harness_verdict": harness_verdict,
            **fields, "started_at": started, "ended_at": ended}


def _payload_path(rel: str) -> Path | None:
    """A payload is a file inside the repo, named by a relative path; '' means none."""
    if rel == "":
        return None
    path = (ROOT / rel).resolve()
    if Path(rel).is_absolute() or ".." in Path(rel).parts or ROOT not in path.parents or not path.is_file():
        raise ValueError(f"payload must be an existing file inside the repo: {rel!r}")
    return path


def load_plan(path: Path) -> tuple[dict, dict[str, dict]]:
    """The plan file and its runs by redteam_id. Every run must build a valid row, so a bad plan fails offline."""
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    date, scenario = doc.get("run_date", ""), doc.get("scenario", "")
    if not re.fullmatch(r"[0-9]{8}", str(date)):
        raise ValueError("run_date must be YYYYMMDD")
    runs: dict[str, dict] = {}
    for run in doc.get("runs", []):
        if set(run) != PLAN_KEYS:
            raise ValueError(f"run keys must be exactly {sorted(PLAN_KEYS)}")
        rid = run["redteam_id"]
        if rid in runs:
            raise ValueError(f"duplicate run {rid}")
        if not rid.startswith(f"{run['case']}-{date}"):
            raise ValueError(f"run {rid} must start with <case>-{date}")
        if run["expect"] not in EXPECTED:
            raise ValueError(f"run {rid}: expect must be one of {', '.join(EXPECTED)}")
        if run["tool_log"] not in TOOL_LOGS_FOR[run["expect"]]:
            raise ValueError(f"run {rid}: tool_log {run['tool_log']!r} doesn't fit {run['expect']}")
        if run["caller"] == "":
            raise ValueError(f"run {rid}: a planned run names its caller")
        _payload_path(run["payload"])
        planned_row(doc, run, _EPOCH, payload_digest="")   # validates every label
        runs[rid] = run
    if not runs:
        raise ValueError("the plan has no runs")
    return doc, runs


def planned_row(doc: dict, run: dict, now: datetime, *, payload_digest: str | None = None) -> dict:
    """The pre-registration row for one planned run, stamped `now`."""
    digest = payload_sha256(_payload_path(run["payload"])) if payload_digest is None else payload_digest
    return build_row(redteam_id=run["redteam_id"], attack_id=run["case"], scenario=doc["scenario"],
                     run_tool="harness", technique=run["technique"], target=run["layer"],
                     expected_control=run["control"], expected_detection=run["detection"],
                     harness_verdict=run["expect"], started_at=now, ended_at=now, caller=run["caller"],
                     conversation_id="", payload_sha256=digest)


class GroundTruthLog:
    def __init__(self, sink, local_path: Path = ROOT / "redteam" / "logs" / "ground-truth.jsonl"):
        self._sink = sink
        self.path = Path(local_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def record(self, **fields) -> dict:
        """Local file first, then the workspace. An upload failure raises: a run without ground truth doesn't count."""
        row = build_row(**fields)
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
        self._sink.send([row])
        return row

    def registered(self) -> set[str]:
        """Run IDs already sent from this local file."""
        if not self.path.exists():
            return set()
        with self.path.open(encoding="utf-8") as fh:
            return {json.loads(line)["redteam_id"] for line in fh if line.strip()}

    def register(self, row: dict) -> dict:
        """Workspace first, then the local file: the local file lists only rows that reached the DCR."""
        if row["redteam_id"] in self.registered():
            raise AlreadyRegistered(row["redteam_id"])
        self._sink.send([row])
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
        return row


class AlreadyRegistered(RuntimeError):
    pass


def mask_id(value: str) -> str:
    """On-screen form of a run ID: first 4 and last 4 characters. The full value goes only to the local log."""
    return value if len(value) <= 8 else f"{value[:4]}...{value[-4:]}"


def describe(row: dict) -> str:
    """One line per registered run: labels and times only, with the run ID masked."""
    return (f"{mask_id(row['redteam_id'])} | case {row['attack_id']} | caller {row['caller']} | layer {row['target']} | "
            f"control {row['expected_control']} | detection {row['expected_detection']} | "
            f"{row['harness_verdict']} | started {row['started_at']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Red-team ground-truth logger (RedTeamRun_CL)")
    parser.add_argument("--smoke", action="store_true", help="write one SMOKE row to check the ingestion path")
    sub = parser.add_subparsers(dest="cmd")
    p_list = sub.add_parser("list", help="print the plan's runs (offline, no Azure call)")
    p_list.add_argument("--plan", type=Path, required=True)
    p_reg = sub.add_parser("register", help="send one planned run's row, before the run starts")
    p_reg.add_argument("--plan", type=Path, required=True)
    p_reg.add_argument("--run", required=True, help="the run's redteam_id, as in the plan")
    p_reg.add_argument("--local", type=Path, required=True,
                       help="local record of rows sent (keep it outside the repo, in the private folder)")
    args = parser.parse_args()

    if args.cmd == "list":
        doc, runs = load_plan(args.plan)
        for rid, run in runs.items():
            print(f"{rid} | case {run['case']} | caller {run['caller']} | layer {run['layer']} | control "
                  f"{run['control']} | detection {run['detection']} | {run['expect']} | tool log {run['tool_log']}")
        print(f"{len(runs)} runs | run date {doc['run_date']}")
        return 0
    if args.cmd == "register":
        doc, runs = load_plan(args.plan)
        if args.run not in runs:
            print(f"STOP: {args.run} is not in the plan; nothing was sent.", file=sys.stderr)
            return 1
        from azure.identity import AzureCliCredential
        from ingest import IngestionError

        sink = IngestionSink(os.environ["REDTEAM_INGEST_ENDPOINT"], os.environ["REDTEAM_DCR_ID"], REDTEAM_STREAM,
                             AzureCliCredential())
        try:
            row = GroundTruthLog(sink, args.local).register(planned_row(doc, runs[args.run],
                                                                         datetime.now(timezone.utc)))
        except AlreadyRegistered:
            print(f"STOP: {args.run} is already registered in {args.local}; a repeat needs its own run ID.",
                  file=sys.stderr)
            return 3
        except IngestionError as exc:
            print(f"STOP: ground truth not written for {args.run} ({exc}). Don't start the run.", file=sys.stderr)
            return 1
        print("registered " + describe(row))
        return 0
    if not args.smoke:
        parser.error("use --smoke, list or register")

    from azure.identity import AzureCliCredential

    sink = IngestionSink(os.environ["REDTEAM_INGEST_ENDPOINT"], os.environ["REDTEAM_DCR_ID"], REDTEAM_STREAM,
                         AzureCliCredential())
    now = datetime.now(timezone.utc)
    row = GroundTruthLog(sink, SMOKE_LOG).record(
        redteam_id=new_redteam_id(), attack_id="SMOKE", scenario="larkfield", run_tool="manual",
        technique="ingestion-smoke-test", target="none", expected_control="none", expected_detection="none",
        harness_verdict="smoke", started_at=now, ended_at=now)
    print(f"sent SMOKE row, redteam_id {mask_id(row['redteam_id'])} (full value in the local log)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
