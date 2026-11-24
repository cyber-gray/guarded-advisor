#!/usr/bin/env python3
"""Create the case assistant agent version (w1-agent). Run inside the VNet (the jumpbox).

    python -I agent/create_agent.py [--dry-run]
    python -I agent/create_agent.py --update-instructions <vector_store_id> [--dry-run]
    python -I agent/create_agent.py --show-version <n>

Uploads the pack's internal documents to a vector store (standard agent setup: files land in the connected Storage
account and are indexed by the connected AI Search; needs Storage Blob Data Contributor for the person running it,
https://learn.microsoft.com/azure/foundry/agents/how-to/tools/file-search), then creates a prompt agent version with
File Search and the record tool. The record tool runs in the client (case_assistant.py), not in the service.

Environment: FOUNDRY_PROJECT_ENDPOINT, SCENARIO (default larkfield).
--dry-run reads the pack and prints the documents, model and tool schema, with no Azure calls.
--update-instructions creates a new agent version with the pack's current instructions and tool schema, reusing an
existing vector store: nothing is uploaded, so it needs only Foundry User on the project, not a Storage role.
File Search settings come from the pack's "file_search" block (max_num_results, ranker, score_threshold), per
OpenAI.FileSearchTool in https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject.
--show-version reads one existing agent version back (a single GET, agents.get_version) and prints only its File
Search settings: max_num_results and the ranking options (ranker, score_threshold, hybrid_search). It never prints the
instructions or other tools, and it creates, updates and uploads nothing.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pack  # noqa: E402
from claims_tool import tool_schema  # noqa: E402

RANKERS = ("auto", "default-2024-11-15")  # OpenAI.RankerVersionType


def file_search_settings(config: dict) -> dict:
    """Validated File Search settings from the pack: max_num_results 1 to 50, a known ranker, threshold null or 0 to 1."""
    fs = config.get("file_search", {})
    max_results, ranker, threshold = fs.get("max_num_results"), fs.get("ranker", "auto"), fs.get("score_threshold")
    if isinstance(max_results, bool) or not isinstance(max_results, int) or not 1 <= max_results <= 50:
        raise ValueError("file_search.max_num_results must be an integer from 1 to 50")
    if ranker not in RANKERS:
        raise ValueError(f"file_search.ranker must be one of {', '.join(RANKERS)}")
    if threshold is not None and (isinstance(threshold, bool) or not isinstance(threshold, (int, float))
                                  or not 0 <= threshold <= 1):
        raise ValueError("file_search.score_threshold must be null or a number from 0 to 1")
    return {"max_num_results": max_results, "ranker": ranker, "score_threshold": threshold}


def show_version(project, agent_name: str, version: str) -> dict:
    """Read one agent version back and keep only its File Search settings. The only call is agents.get_version."""
    details = project.agents.get_version(agent_name=agent_name, agent_version=version)
    tools = [t for t in (details["definition"].get("tools") or []) if t.get("type") == "file_search"]
    out = {"agent": details.get("name"), "version": details.get("version"), "file_search_tools": len(tools)}
    if tools:
        ranking = tools[0].get("ranking_options") or {}
        out["max_num_results"] = tools[0].get("max_num_results")
        out["ranking_options"] = {key: ranking.get(key) for key in ("ranker", "score_threshold", "hybrid_search")}
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Create the case assistant agent version and its vector store")
    parser.add_argument("--dry-run", action="store_true", help="read the pack only; no Azure calls")
    parser.add_argument("--update-instructions", metavar="VECTOR_STORE_ID",
                        help="new agent version reusing this vector store (no upload, Foundry User only)")
    parser.add_argument("--show-version", metavar="N",
                        help="read agent version N back and print only its File Search settings (GET only)")
    args = parser.parse_args()
    if args.show_version is not None:
        if not args.show_version.isdigit():
            parser.error("--show-version expects a version number")
        if args.update_instructions or args.dry_run:
            parser.error("--show-version can't be combined with other options")

    config = pack.load_config()
    fs = file_search_settings(config)
    docs = sorted((pack.pack_dir() / config["documents_dir"]).glob("*.md"))
    reuse = args.update_instructions
    if reuse is not None and not reuse.startswith("vs_"):
        parser.error("--update-instructions expects a vector store ID (vs_...)")
    if args.dry_run:
        target = f"reusing vector store {reuse}, no upload" if reuse else \
            f"{len(docs)} documents for vector store {config['vector_store_name']}"
        print(f"dry run: agent {config['agent_name']} on {config['model_deployment']}, {target}")
        print(f"instructions: {len(pack.load_instructions(config))} characters")
        print(f"file search: max_num_results={fs['max_num_results']}, ranker={fs['ranker']}, "
              f"score_threshold={'none' if fs['score_threshold'] is None else fs['score_threshold']}")
        print("record tool schema: " + json.dumps(tool_schema(config)))
        return 0

    if args.show_version is not None:
        from azure.ai.projects import AIProjectClient
        from azure.identity import AzureCliCredential

        project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=AzureCliCredential())
        print(json.dumps(show_version(project, config["agent_name"], args.show_version), indent=1, default=dict))
        return 0

    from azure.ai.projects import AIProjectClient
    from azure.ai.projects.models import FileSearchTool, FunctionTool, PromptAgentDefinition, RankingOptions
    from azure.identity import AzureCliCredential

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=AzureCliCredential())
    openai = project.get_openai_client()

    if reuse:
        vector_store_id = reuse
        print(f"  reusing vector store {vector_store_id} (no upload)")
    else:
        vector_store = openai.vector_stores.create(name=config["vector_store_name"])
        vector_store_id = vector_store.id
        for path in docs:
            with path.open("rb") as fh:
                result = openai.vector_stores.files.upload_and_poll(vector_store_id=vector_store_id, file=fh)
            print(f"  indexed {path.name}: {result.status}")

    schema = tool_schema(config)
    ranking = {"ranker": fs["ranker"]}
    if fs["score_threshold"] is not None:
        ranking["score_threshold"] = fs["score_threshold"]
    agent = project.agents.create_version(
        agent_name=config["agent_name"],
        definition=PromptAgentDefinition(
            model=config["model_deployment"],
            instructions=pack.load_instructions(config),
            tools=[
                FileSearchTool(vector_store_ids=[vector_store_id], max_num_results=fs["max_num_results"],
                               ranking_options=RankingOptions(**ranking)),
                FunctionTool(name=schema["name"], description=schema["description"],
                             parameters=schema["parameters"], strict=schema["strict"]),
            ],
        ),
        description=f"Case assistant for scenario pack {config['scenario']} (synthetic data)",
    )
    print(f"agent {agent.name} version {agent.version}; vector store {vector_store_id}"
          f"{'' if reuse else f'; {len(docs)} documents'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
