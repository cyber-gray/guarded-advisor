"""Scenario pack loading (D-012). The platform code reads everything domain-specific from scenarios/$SCENARIO."""
from __future__ import annotations

import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def scenario() -> str:
    return os.environ.get("SCENARIO", "larkfield")


def pack_dir(name: str | None = None) -> Path:
    return ROOT / "scenarios" / (name or scenario())


def load_config(name: str | None = None) -> dict:
    return json.loads((pack_dir(name) / "agent.json").read_text(encoding="utf-8"))


def load_instructions(config: dict, name: str | None = None) -> str:
    return (pack_dir(name) / config["instructions_file"]).read_text(encoding="utf-8")


def load_entitlements(name: str | None = None) -> dict[str, frozenset[str]]:
    """Caller object ID -> the record IDs assigned to that caller (entitlements.json, built by build_entitlements.sh)."""
    data = json.loads((pack_dir(name) / "entitlements.json").read_text(encoding="utf-8"))
    return {oid: frozenset(entry["claims"]) for oid, entry in data["caseloads"].items()}


def load_records(name: str | None = None) -> list[dict]:
    return json.loads((pack_dir(name) / "data" / "claims.json").read_text(encoding="utf-8"))["claims"]
