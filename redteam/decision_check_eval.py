#!/usr/bin/env python3
"""Live eval of the C1 decision check (agent/decision_checker.py) against the checker agent. Jumpbox only.

    .venv\\Scripts\\python redteam\\decision_check_eval.py --out <private path>\\dc-eval-20261113.jsonl

Runs every item of scenarios/<pack>/decision-check-eval.json through both layers:
  - layer 1, the regex (output_check), locally;
  - layer 2, the checker agent, through its own agent endpoint, exactly as case_assistant.py calls it
    (AIProjectClient with allow_preview=True, get_openai_client(agent_name=...), SemanticCheck.classify). The caller is
    whoever is signed in with `az login` (AzureCliCredential); Foundry Agent Consumer on the project is enough.
Layer 2 runs on every item, including the ones layer 1 already catches, so each layer is measured on its own.
"combined" is what case_assistant.py does: withheld if layer 1 matches, or layer 2 says true, or layer 2 is
unavailable (fail closed).

Records only: item ID, label, each layer's result, the unavailable kind and the latency. Never the draft text and
never the checker's evidence quote. --out must be a new file outside the repository.

Positive = the item is labelled decision language (expect true). For each layer: TP withheld a positive, FN showed a
positive, FP withheld a negative, TN showed a negative. Layer 2 "unavailable" rows are counted on their own and listed;
in "combined" they count as withheld. A false verdict with non-empty evidence (2026-11-14) is scored as false, as the
client shows it, and listed on its own as "layer2_inconsistent".
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent"))

import pack  # noqa: E402
from decision_checker import CheckUnavailable, SemanticCheck, checker_call  # noqa: E402
from untrusted import DecisionCheck  # noqa: E402

ROW_FIELDS = ("id", "expect", "regex", "semantic", "semantic_note", "unavailable_kind", "combined_withheld",
              "latency_ms")


def load_items(path: Path) -> list[dict]:
    items = json.loads(path.read_text(encoding="utf-8"))["items"]
    ids = [i["id"] for i in items]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate item IDs in the eval file")
    return items


def check_out_path(out: Path) -> str | None:
    resolved = out.expanduser().resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        return "--out is inside the repository; results go to a private path"
    if resolved.exists():
        return "--out already exists; choose a new file"
    return None


def evaluate(items: list[dict], regex: DecisionCheck, semantic: SemanticCheck, call: Callable[..., Any], *,
             sleep: Callable[[float], None] = time.sleep, pause: float = 0.5,
             clock: Callable[[], float] = time.monotonic) -> list[dict]:
    rows = []
    for n, item in enumerate(items):
        if n and pause:
            sleep(pause)
        layer1 = bool(regex.matches(item["text"]))
        start = clock()
        note = ""
        try:
            verdict = semantic.classify(item["text"], call)
            semantic_result, kind = ("true" if verdict.decision_language else "false"), ""
            note = "inconsistent" if verdict.inconsistent else ""
        except CheckUnavailable as exc:
            semantic_result, kind = "unavailable", exc.kind
        row = {"id": item["id"], "expect": bool(item["expect"]), "regex": layer1, "semantic": semantic_result,
               "semantic_note": note, "unavailable_kind": kind,
               "combined_withheld": layer1 or semantic_result != "false",
               "latency_ms": int((clock() - start) * 1000)}
        rows.append(row)
    return rows


def confusion(rows: list[dict], withheld: Callable[[dict], bool]) -> dict:
    out = {"TP": [], "FN": [], "FP": [], "TN": []}
    for r in rows:
        w = withheld(r)
        out[("TP" if w else "FN") if r["expect"] else ("FP" if w else "TN")].append(r["id"])
    return out


def summary(rows: list[dict]) -> dict:
    available = [r for r in rows if r["semantic"] != "unavailable"]
    return {
        "items": len(rows),
        "positives": sum(r["expect"] for r in rows),
        "negatives": sum(not r["expect"] for r in rows),
        "layer1_regex": confusion(rows, lambda r: r["regex"]),
        "layer2_semantic": confusion(available, lambda r: r["semantic"] == "true"),
        "layer2_unavailable": {r["id"]: r["unavailable_kind"] for r in rows if r["semantic"] == "unavailable"},
        "layer2_inconsistent": [r["id"] for r in rows if r.get("semantic_note") == "inconsistent"],
        "combined": confusion(rows, lambda r: r["combined_withheld"]),
    }


def render(s: dict) -> str:
    lines = [f"items {s['items']} (positives {s['positives']}, negatives {s['negatives']})"]
    for name in ("layer1_regex", "layer2_semantic", "combined"):
        c = s[name]
        lines.append(f"{name}: TP {len(c['TP'])} | FN {len(c['FN'])} | FP {len(c['FP'])} | TN {len(c['TN'])}")
        if c["FN"]:
            lines.append(f"  FN (positive shown): {', '.join(c['FN'])}")
        if c["FP"]:
            lines.append(f"  FP (negative withheld): {', '.join(c['FP'])}")
    unavailable = s["layer2_unavailable"]
    lines.append(f"layer2_unavailable: {len(unavailable)}"
                 + (" | " + ", ".join(f"{k} ({v})" for k, v in unavailable.items()) if unavailable else ""))
    inconsistent = s["layer2_inconsistent"]
    lines.append(f"layer2_inconsistent (false with evidence, shown): {len(inconsistent)}"
                 + (" | " + ", ".join(inconsistent) if inconsistent else ""))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Live eval of the C1 decision check (records no draft or evidence text)")
    p.add_argument("--out", type=Path, required=True, help="results JSONL, outside the repository, new file")
    p.add_argument("--eval-file", type=Path, help="default: scenarios/<pack>/decision-check-eval.json")
    p.add_argument("--items", help="comma-separated item IDs; default all")
    p.add_argument("--pause", type=float, default=0.5, help="seconds between checker calls")
    args = p.parse_args(argv)
    reason = check_out_path(args.out)
    if reason:
        print(f"STOP: {reason}", file=sys.stderr)
        return 2
    config = pack.load_config()
    items = load_items(args.eval_file or pack.pack_dir() / "decision-check-eval.json")
    if args.items:
        wanted = args.items.split(",")
        unknown = set(wanted) - {i["id"] for i in items}
        if unknown:
            print(f"STOP: unknown item IDs: {sorted(unknown)}", file=sys.stderr)
            return 2
        items = [i for i in items if i["id"] in wanted]
    regex, semantic = DecisionCheck.from_config(config), SemanticCheck.from_config(config)
    from azure.ai.projects import AIProjectClient
    from azure.identity import AzureCliCredential

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=AzureCliCredential(),
                              allow_preview=True)
    checker = project.get_openai_client(agent_name=config["decision_check"]["agent_name"])
    rows = evaluate(items, regex, semantic, checker_call(checker), pause=args.pause)
    with args.out.open("x", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps({k: r[k] for k in ROW_FIELDS}) + "\n")
    s = summary(rows)
    print(render(s))
    print(f"results: {args.out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
