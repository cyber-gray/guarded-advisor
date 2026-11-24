#!/usr/bin/env python3
"""Create, read back and delete the B1 agent, larkfield-case-assistant-b1 (w3-bias, C7). Jumpbox only.

    python agent/b1_agent.py --dry-run       pack only, no Azure calls
    python agent/b1_agent.py --check-sdk     installed SDK has every class and method used here; no Azure calls
    python agent/b1_agent.py show            GET only: the agent and its latest version, masked
    python agent/b1_agent.py create          gate: refuses if it exists; asks for the agent name typed back
    python agent/b1_agent.py delete          gate: asks for the agent name typed back; reads back that it's gone

Why a separate agent (PLAN "Wed 11-11 B1", step 3): B1 needs temperature 0 and the b1_summary JSON schema. When an
agent is named, a request can't carry temperature or text (B1 probe, findings 2026-11-11), so both live in this
agent's definition. Everything else matches the case assistant: model, instructions, File Search on the same vector
store (read from the case assistant's latest version, so nothing is uploaded) and the record tool schema. The runner,
redteam/bias_b1.py, calls this agent through its own endpoint (client fix B), so alder needs only Foundry Agent
Consumer, and it reads the effective temperature and format back from every response (fail closed).

Gates: each Azure step is its own one-off yes. create and delete need the project's agent write data actions (Foundry
User, R1 for T). Before delete, the agent's identity fields are printed masked so they can be recorded (the plan's
"record the agent identity and blueprint"). Output masking and SDK names: as in agent/checker_agent.py.

Environment: FOUNDRY_PROJECT_ENDPOINT, SCENARIO (default larkfield).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pack  # noqa: E402
from checker_agent import _get, confirm, exists, identity_fields, mask, sha12  # noqa: E402
from claims_tool import tool_schema  # noqa: E402
from create_agent import file_search_settings  # noqa: E402

SDK_MODELS = ("PromptAgentDefinition", "PromptAgentDefinitionTextOptions", "TextResponseFormatJsonSchema",
              "FileSearchTool", "FunctionTool", "RankingOptions")
SDK_METHODS = ("create_version", "get", "get_version", "delete")


def settings(config: dict) -> dict:
    b1 = config["b1_agent"]
    if b1["temperature"] != 0:
        raise ValueError("b1_agent.temperature must be 0")
    if b1["agent_name"] == config["agent_name"]:
        raise ValueError("b1_agent.agent_name must differ from the case assistant's")
    schema = json.loads((pack.pack_dir() / b1["output_schema_file"]).read_text(encoding="utf-8"))["output_schema"]
    if schema.get("additionalProperties") is not False:
        raise ValueError("the B1 output schema must have additionalProperties false")
    return {"agent_name": b1["agent_name"], "main_agent": config["agent_name"], "model": config["model_deployment"],
            "temperature": 0, "format_name": b1["response_format_name"], "schema": schema}


def text_format(s: dict) -> dict:
    return {"format": {"type": "json_schema", "name": s["format_name"], "schema": s["schema"], "strict": True}}


def main_vector_store_ids(project: Any, config: dict) -> list[str]:
    """The vector store IDs of the case assistant's latest version (GET only)."""
    agent = project.agents.get(agent_name=config["agent_name"])
    latest = _get(_get(_get(agent, "versions", {}) or {}, "latest", {}) or {}, "version")
    details = project.agents.get_version(agent_name=config["agent_name"], agent_version=str(latest))
    tools = _get(_get(details, "definition", {}) or {}, "tools", []) or []
    ids = [i for t in tools if _get(t, "type") == "file_search" for i in (_get(t, "vector_store_ids", []) or [])]
    if not ids:
        raise ValueError("the case assistant's latest version has no File Search vector store")
    return ids


def readback(details: Any, config: dict, vector_store_ids: list[str]) -> dict:
    s = settings(config)
    definition = _get(details, "definition", {}) or {}
    fmt = _get(_get(definition, "text", {}) or {}, "format", {}) or {}
    tools = _get(definition, "tools", []) or []
    fs = [t for t in tools if _get(t, "type") == "file_search"]
    fn = [t for t in tools if _get(t, "type") == "function"]
    remote = _get(definition, "instructions", "") or ""
    return {
        "name": _get(details, "name"), "version": _get(details, "version"), "model": _get(definition, "model"),
        "temperature": _get(definition, "temperature"), "text_format_type": _get(fmt, "type"),
        "text_format_name": _get(fmt, "name"), "text_format_strict": _get(fmt, "strict"),
        "file_search_tools": len(fs), "function_tools": [_get(t, "name") for t in fn],
        "same_vector_store": bool(fs) and list(_get(fs[0], "vector_store_ids", []) or []) == vector_store_ids,
        "instructions_sha12": sha12(remote), "instructions_match": remote == pack.load_instructions(config),
        "expected": {"model": s["model"], "temperature": 0, "text_format_type": "json_schema",
                     "text_format_name": s["format_name"], "text_format_strict": True, "file_search_tools": 1,
                     "function_tools": [tool_schema(config)["name"]], "same_vector_store": True},
    }


def readback_ok(rb: dict) -> list[str]:
    failed = [k for k, v in rb["expected"].items() if rb.get(k) != v]
    return failed + ([] if rb["instructions_match"] else ["instructions_match"])


def build_definition(config: dict, models: Any, vector_store_ids: list[str]) -> Any:
    s, fs, schema = settings(config), file_search_settings(config), tool_schema(config)
    ranking = {"ranker": fs["ranker"]}
    if fs["score_threshold"] is not None:
        ranking["score_threshold"] = fs["score_threshold"]
    fmt = text_format(s)["format"]
    return models.PromptAgentDefinition(
        model=s["model"], instructions=pack.load_instructions(config), temperature=0,
        text=models.PromptAgentDefinitionTextOptions(format=models.TextResponseFormatJsonSchema(
            name=fmt["name"], schema=fmt["schema"], strict=True)),
        tools=[models.FileSearchTool(vector_store_ids=vector_store_ids, max_num_results=fs["max_num_results"],
                                     ranking_options=models.RankingOptions(**ranking)),
               models.FunctionTool(name=schema["name"], description=schema["description"],
                                   parameters=schema["parameters"], strict=schema["strict"])])


def create(project: Any, config: dict, models: Any, ask: Callable[[str], str] = input, out=print) -> int:
    s = settings(config)
    name = s["agent_name"]
    if exists(project, name):
        out(f"STOP: {name} already exists; nothing created. Read it with `show` or remove it with `delete` first.")
        return 1
    vs = main_vector_store_ids(project, config)
    out(f"Will create prompt agent {name}: model {s['model']}, temperature 0, text format json_schema "
        f"'{s['format_name']}' (strict), the case assistant's instructions (sha256 "
        f"{sha12(pack.load_instructions(config))}...), File Search on {', '.join(mask(v) for v in vs)} (no upload) and "
        f"the record tool.")
    if not confirm(name, "create", ask):
        out("Stopped: the name didn't match. Nothing was created.")
        return 1
    created = project.agents.create_version(
        agent_name=name, definition=build_definition(config, models, vs),
        description=f"B1 bias test copy of {s['main_agent']}: temperature 0, JSON schema (synthetic data)")
    version = str(_get(created, "version"))
    details = project.agents.get_version(agent_name=name, agent_version=version)
    rb = readback(details, config, vs)
    out("read-back: " + json.dumps({k: v for k, v in rb.items() if k != "expected"}, default=str))
    for line in identity_fields(details):
        out(f"identity field: {line}")
    failed = readback_ok(rb)
    if failed:
        out(f"FINDING: read-back differs on {', '.join(failed)}. Don't run B1 against it; decide: delete and fix, "
            "or record.")
        return 1
    out(f"created {name} version {version}; read-back matches.")
    return 0


def show(project: Any, config: dict, out=print) -> int:
    name = settings(config)["agent_name"]
    if not exists(project, name):
        out(f"{name}: doesn't exist.")
        return 0
    agent = project.agents.get(agent_name=name)
    latest = _get(_get(_get(agent, "versions", {}) or {}, "latest", {}) or {}, "version")
    out(f"{name}: exists; latest version {mask(latest)}")
    details = project.agents.get_version(agent_name=name, agent_version=str(latest))
    rb = readback(details, config, main_vector_store_ids(project, config))
    out("read-back: " + json.dumps({k: v for k, v in rb.items() if k != "expected"}, default=str))
    failed = readback_ok(rb)
    out("matches" if not failed else f"FINDING: differs on {', '.join(failed)}")
    for line in identity_fields(details):
        out(f"identity field: {line}")
    return 0


def delete(project: Any, config: dict, vector_store_exists: Callable[[str], bool], ask: Callable[[str], str] = input,
           out=print) -> int:
    """Deletes the B1 agent only: the one call is agents.delete(agent_name=<b1>). The shared vector store belongs to the
    case assistant and is never deleted here; the read-back confirms it and the case assistant still exist."""
    name = settings(config)["agent_name"]
    if not exists(project, name):
        out(f"{name} doesn't exist; nothing to delete.")
        return 0
    shared = main_vector_store_ids(project, config)
    for line in identity_fields(project.agents.get(agent_name=name)):
        out(f"identity field (record before delete): {line}")
    out(f"Will delete agent {name} and all its versions. Not touched: the case assistant ({config['agent_name']}) "
        f"and its vector store {', '.join(mask(v) for v in shared)}.")
    if not confirm(name, "delete", ask):
        out("Stopped: the name didn't match. Nothing was deleted.")
        return 1
    project.agents.delete(agent_name=name)
    gone = not exists(project, name)
    main_ok = exists(project, config["agent_name"])
    stores_ok = all(vector_store_exists(v) for v in shared)
    out(f"read-back: {name} exists: {'no' if gone else 'yes'}; {config['agent_name']} exists: "
        f"{'yes' if main_ok else 'NO'}; shared vector store exists: {'yes' if stores_ok else 'NO'}")
    if not (main_ok and stores_ok):
        out("FINDING: the case assistant or its vector store is missing after the B1 delete.")
    return 0 if gone and main_ok and stores_ok else 1


def vector_store_probe(project: Any) -> Callable[[str], bool]:
    """GET only: True if the vector store can be retrieved, False on a 404."""
    openai = project.get_openai_client()

    def probe(vector_store_id: str) -> bool:
        try:
            openai.vector_stores.retrieve(vector_store_id)
            return True
        except Exception as exc:  # noqa: BLE001
            not_found = type(exc).__name__ in ("NotFoundError", "ResourceNotFoundError")
            if getattr(exc, "status_code", None) == 404 or not_found:
                return False
            raise
    return probe


def check_sdk() -> list[str]:
    import importlib
    models = importlib.import_module("azure.ai.projects.models")
    ops = getattr(importlib.import_module("azure.ai.projects.operations"), "AgentsOperations", None)
    missing = [f"models.{n}" for n in SDK_MODELS if not hasattr(models, n)]
    missing += [f"AgentsOperations.{m}" for m in SDK_METHODS if ops is None or not hasattr(ops, m)]
    return missing


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="B1 agent gates (w3-bias, C7)")
    p.add_argument("mode", nargs="?", choices=("show", "create", "delete"))
    p.add_argument("--dry-run", action="store_true", help="read the pack only; no Azure calls")
    p.add_argument("--check-sdk", action="store_true", help="check the installed SDK names; no Azure calls")
    args = p.parse_args(argv)
    if sum([bool(args.mode), args.dry_run, args.check_sdk]) != 1:
        p.error("choose exactly one of: show, create, delete, --dry-run, --check-sdk")
    config = pack.load_config()
    s = settings(config)
    if args.dry_run:
        fs = file_search_settings(config)
        print(f"dry run: agent {s['agent_name']} (copy of {s['main_agent']}) on {s['model']}, temperature 0")
        print(f"instructions: {len(pack.load_instructions(config))} characters, sha256 "
              f"{sha12(pack.load_instructions(config))}... (the case assistant's)")
        print(f"tools: file_search (the case assistant's vector store, max_num_results {fs['max_num_results']}), "
              f"function {tool_schema(config)['name']}")
        print("text format: " + json.dumps(text_format(s)["format"], sort_keys=True))
        return 0
    if args.check_sdk:
        missing = check_sdk()
        print("SDK check: ok" if not missing else "SDK check: MISSING " + ", ".join(missing))
        return 0 if not missing else 1
    from azure.ai.projects import AIProjectClient
    from azure.ai.projects import models
    from azure.identity import AzureCliCredential

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=AzureCliCredential())
    if args.mode == "show":
        return show(project, config)
    if args.mode == "create":
        return create(project, config, models)
    return delete(project, config, vector_store_probe(project))


if __name__ == "__main__":
    sys.exit(main())
