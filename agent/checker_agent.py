#!/usr/bin/env python3
"""Create, read back and delete the decision-checker agent (C1 layer 2; agent/decision_checker.py). Jumpbox only:
the Foundry data plane is private.

    python agent/checker_agent.py --dry-run        pack only, no Azure calls
    python agent/checker_agent.py --check-sdk      installed SDK has every class and method used here; no Azure calls
    python agent/checker_agent.py show             GET only: the agent and its latest version, masked
    python agent/checker_agent.py create           gate: refuses if the agent exists; asks for the agent name typed back
    python agent/checker_agent.py delete           gate: asks for the agent name typed back; reads back that it's gone

Each Azure step is its own one-off yes (the same pattern as the planned b1 agent, PLAN "Wed 11-11 B1" step 3). The
person running it signs in with `az login` (AzureCliCredential); creating and deleting agents needs the project's
agent write data actions (Foundry User, R1 for T). Case managers never run this.

What it creates: a prompt agent with the pack's `decision_check` settings: model, the fixed instructions file,
temperature 0 and a strict JSON-schema text format, and no tools. The SDK names follow Learn's azure-ai-projects
reference (PromptAgentDefinition: temperature, text; PromptAgentDefinitionTextOptions.format;
TextResponseFormatJsonSchema: name, schema, strict; AgentsOperations: create_version, get, get_version, delete:
https://learn.microsoft.com/python/api/azure-ai-projects/azure.ai.projects.models.promptagentdefinition?view=azure-python
and .../azure.ai.projects.operations.agentsoperations?view=azure-python). That reference tracks the latest SDK, not the
pinned 2.8.0, so --check-sdk confirms them on the jumpbox before the gate runs.

Output is masked: GUID-shaped values as first 4 and last 4, email-shaped values as <upn>. The instructions text is
never printed; it's compared by SHA-256.

Environment: FOUNDRY_PROJECT_ENDPOINT, SCENARIO (default larkfield).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pack  # noqa: E402

_GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_EMAIL = re.compile(r"[A-Za-z0-9._%+#-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SDK_NAMES = {
    "azure.ai.projects.models": ("PromptAgentDefinition", "PromptAgentDefinitionTextOptions",
                                 "TextResponseFormatJsonSchema"),
    "azure.ai.projects.operations": ("AgentsOperations",),
}
SDK_METHODS = ("create_version", "get", "get_version", "delete")


def mask(value: Any) -> str:
    text = str(value)
    text = _GUID.sub(lambda m: m.group(0)[:4] + "..." + m.group(0)[-4:], text)
    return _EMAIL.sub("<upn>", text)


def sha12(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def settings(config: dict) -> dict:
    """The checker's definition settings from the pack, validated."""
    dc = config["decision_check"]
    rs = dc["response_schema"]
    schema = rs["schema"]
    if dc["temperature"] != 0:
        raise ValueError("decision_check.temperature must be 0")
    if rs.get("strict") is not True or schema.get("additionalProperties") is not False:
        raise ValueError("decision_check.response_schema must be strict with additionalProperties false")
    if set(schema.get("required", [])) != {"decision_language", "evidence"}:
        raise ValueError("decision_check.response_schema must require decision_language and evidence")
    return {"agent_name": dc["agent_name"], "model": dc["model_deployment"], "temperature": 0,
            "instructions_file": dc["instructions_file"], "schema_name": rs["name"], "schema": schema}


def instructions(config: dict) -> str:
    return (pack.pack_dir() / config["decision_check"]["instructions_file"]).read_text(encoding="utf-8")


def definition_kwargs(config: dict) -> dict:
    """Plain-data form of the agent definition (what create builds the SDK objects from)."""
    s = settings(config)
    return {"model": s["model"], "instructions": instructions(config), "temperature": s["temperature"],
            "text": {"format": {"type": "json_schema", "name": s["schema_name"], "schema": s["schema"],
                                "strict": True}},
            "tools": []}


def _get(obj: Any, key: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(key, default)
    try:
        return obj[key]
    except (KeyError, TypeError, IndexError):
        return getattr(obj, key, default)


def identity_fields(obj: Any, path: str = "") -> list[str]:
    """Key paths whose name mentions identity, blueprint or an ID, with masked values (agent identity, if any)."""
    out: list[str] = []
    if isinstance(obj, dict) or hasattr(obj, "keys"):
        for key in list(obj.keys()):
            value = obj[key]
            here = f"{path}.{key}" if path else str(key)
            if re.search(r"identity|blueprint|(^|_)id$|Id$", str(key)) and not isinstance(value, (dict, list)):
                out.append(f"{here}: {mask(value)}")
            elif isinstance(value, (dict, list)) or hasattr(value, "keys"):
                out.extend(identity_fields(value, here))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            out.extend(identity_fields(item, f"{path}[{i}]"))
    return out


def readback(details: Any, config: dict) -> dict:
    """The checks a created version must pass, from a get_version result. Never includes the instructions text."""
    s = settings(config)
    definition = _get(details, "definition", {}) or {}
    fmt = _get(_get(definition, "text", {}) or {}, "format", {}) or {}
    remote_instructions = _get(definition, "instructions", "") or ""
    return {
        "name": _get(details, "name"),
        "version": _get(details, "version"),
        "model": _get(definition, "model"),
        "temperature": _get(definition, "temperature"),
        "text_format_type": _get(fmt, "type"),
        "text_format_name": _get(fmt, "name"),
        "text_format_strict": _get(fmt, "strict"),
        "tools": len(_get(definition, "tools", []) or []),
        "instructions_sha12": sha12(remote_instructions),
        "instructions_match": remote_instructions == instructions(config),
        "expected": {"model": s["model"], "temperature": 0, "text_format_type": "json_schema",
                     "text_format_name": s["schema_name"], "text_format_strict": True, "tools": 0},
    }


def readback_ok(rb: dict) -> list[str]:
    """Names of failed checks (empty list = pass)."""
    failed = [k for k, v in rb["expected"].items() if rb.get(k) != v]
    if not rb["instructions_match"]:
        failed.append("instructions_match")
    return failed


def confirm(agent_name: str, action: str, ask: Callable[[str], str] = input) -> bool:
    typed = ask(f"Type the agent name to {action} it ({agent_name}), anything else stops: ")
    return typed.strip() == agent_name


def exists(project: Any, agent_name: str) -> bool:
    try:
        project.agents.get(agent_name=agent_name)
        return True
    except Exception as exc:  # noqa: BLE001
        if getattr(exc, "status_code", None) == 404 or type(exc).__name__ == "ResourceNotFoundError":
            return False
        raise


def check_sdk() -> list[str]:
    """Missing SDK names, without any Azure call."""
    import importlib
    missing = []
    for module_name, names in SDK_NAMES.items():
        module = importlib.import_module(module_name)
        missing += [f"{module_name}.{n}" for n in names if not hasattr(module, n)]
    ops = getattr(importlib.import_module("azure.ai.projects.operations"), "AgentsOperations", None)
    missing += [f"AgentsOperations.{m}" for m in SDK_METHODS if ops is None or not hasattr(ops, m)]
    models = importlib.import_module("azure.ai.projects.models")
    pad = getattr(models, "PromptAgentDefinition", None)
    if pad is not None:
        fields = set(getattr(pad, "_attr_to_rest_field", {}) or {}) | set(dir(pad))
        missing += [f"PromptAgentDefinition.{f}" for f in ("temperature", "text") if f not in fields]
    return missing


def create(project: Any, config: dict, models: Any, ask: Callable[[str], str] = input, out=print) -> int:
    s = settings(config)
    name = s["agent_name"]
    if exists(project, name):
        out(f"STOP: {name} already exists; nothing created. Read it with `show` or remove it with `delete` first.")
        return 1
    out(f"Will create prompt agent {name}: model {s['model']}, temperature 0, text format json_schema "
        f"'{s['schema_name']}' (strict), no tools, instructions {s['instructions_file']} "
        f"(sha256 {sha12(instructions(config))}...).")
    if not confirm(name, "create", ask):
        out("Stopped: the name didn't match. Nothing was created.")
        return 1
    kw = definition_kwargs(config)
    fmt = kw["text"]["format"]
    definition = models.PromptAgentDefinition(
        model=kw["model"], instructions=kw["instructions"], temperature=kw["temperature"], tools=[],
        text=models.PromptAgentDefinitionTextOptions(format=models.TextResponseFormatJsonSchema(
            name=fmt["name"], schema=fmt["schema"], strict=True)))
    created = project.agents.create_version(
        agent_name=name, definition=definition,
        description=f"C1 decision-language checker for scenario pack {config['scenario']} (synthetic data)")
    version = str(_get(created, "version"))
    details = project.agents.get_version(agent_name=name, agent_version=version)
    rb = readback(details, config)
    out("read-back: " + json.dumps({k: v for k, v in rb.items() if k != "expected"}, default=str))
    for line in identity_fields(details):
        out(f"identity field: {line}")
    failed = readback_ok(rb)
    if failed:
        out(f"FINDING: read-back differs from the pack on {', '.join(failed)}. Don't use the checker; decide: delete "
            "and fix, or record.")
        return 1
    out(f"created {name} version {version}; read-back matches the pack.")
    return 0


def show(project: Any, config: dict, out=print) -> int:
    name = settings(config)["agent_name"]
    if not exists(project, name):
        out(f"{name}: doesn't exist.")
        return 0
    agent = project.agents.get(agent_name=name)
    latest = _get(_get(_get(agent, "versions", {}) or {}, "latest", {}) or {}, "version")
    out(f"{name}: exists; latest version {mask(latest)}")
    if latest is not None:
        details = project.agents.get_version(agent_name=name, agent_version=str(latest))
        rb = readback(details, config)
        out("read-back: " + json.dumps({k: v for k, v in rb.items() if k != "expected"}, default=str))
        failed = readback_ok(rb)
        out("matches the pack" if not failed else f"FINDING: differs on {', '.join(failed)}")
        for line in identity_fields(details):
            out(f"identity field: {line}")
    return 0


def delete(project: Any, config: dict, ask: Callable[[str], str] = input, out=print) -> int:
    name = settings(config)["agent_name"]
    if not exists(project, name):
        out(f"{name} doesn't exist; nothing to delete.")
        return 0
    agent = project.agents.get(agent_name=name)
    for line in identity_fields(agent):
        out(f"identity field (record before delete): {line}")
    out(f"Will delete agent {name} and all its versions.")
    if not confirm(name, "delete", ask):
        out("Stopped: the name didn't match. Nothing was deleted.")
        return 1
    project.agents.delete(agent_name=name)
    gone = not exists(project, name)
    out(f"read-back: {name} exists: {'no' if gone else 'yes'}")
    if not gone:
        out("FINDING: the agent still exists after delete.")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Decision-checker agent gates (C1 layer 2)")
    p.add_argument("mode", nargs="?", choices=("show", "create", "delete"))
    p.add_argument("--dry-run", action="store_true", help="read the pack only; no Azure calls")
    p.add_argument("--check-sdk", action="store_true", help="check the installed SDK names; no Azure calls")
    args = p.parse_args(argv)
    if sum([bool(args.mode), args.dry_run, args.check_sdk]) != 1:
        p.error("choose exactly one of: show, create, delete, --dry-run, --check-sdk")
    config = pack.load_config()
    s = settings(config)
    if args.dry_run:
        kw = definition_kwargs(config)
        print(f"dry run: agent {s['agent_name']} on {s['model']}, temperature {s['temperature']}, "
              f"tools {len(kw['tools'])}")
        print(f"instructions: {s['instructions_file']}, {len(kw['instructions'])} characters, "
              f"sha256 {sha12(kw['instructions'])}...")
        print("text format: " + json.dumps(kw["text"]["format"], sort_keys=True))
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
    return delete(project, config)


if __name__ == "__main__":
    sys.exit(main())
