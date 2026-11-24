#!/usr/bin/env python3
"""Case assistant client (w1-agent). Run inside the VNet (the jumpbox): every data plane is private.

    python -I agent/case_assistant.py "What does plan A say about graduated return to work?"
    python -I agent/case_assistant.py "Summarise this note and suggest next steps." --document note.txt

A --document file's text is always wrapped in the <documents> delimiter by the client, and every answer passes the
decision-language check before it's shown (C1, C3): the regex layer (agent/untrusted.py), then, if that finds nothing,
the semantic layer, a second agent called through its own endpoint (agent/decision_checker.py). Either layer withholds;
a check that can't give a valid verdict withholds too (fail closed).

Environment (operator settings, none of them identifies the caller):
  FOUNDRY_PROJECT_ENDPOINT  https://<account>.services.ai.azure.com/api/projects/<project>
  COSMOS_ENDPOINT           https://<account>.documents.azure.com:443/
  GA_TENANT_ID              expected Entra tenant ID for token validation
  AUDIT_INGEST_ENDPOINT     ga-dce-shared logs ingestion endpoint (custom-tables.bicep output agentIngestionEndpoint)
  AUDIT_DCR_ID              ga-dcr-agent-shared immutable ID, dcr-... (output agentDcrImmutableId)
  SCENARIO                  scenario pack (default larkfield)

Identities:
  - The person: AzureCliCredential (`az login` on the jumpbox). Their validated oid is the caller (identity.py), and
    their token calls the agent through its own endpoint (agent_session.py, D-039), so Foundry Agent Consumer on the
    project is enough. The agent endpoint is a preview: the SDK needs allow_preview=True and sends a Foundry-Features
    header with preview opt-in keys (azure-ai-projects 2.8.0, _patch.py:84-85; findings 2026-11-12).
  - Claim reads: the jumpbox managed identity (ManagedIdentityCredential), Cosmos DB Built-in Data Reader on the claims
    container only. Known gap: any jumpbox session can use that identity directly (attack A13, findings 2026-10-20).
  - Audit rows: the same managed identity, Monitoring Metrics Publisher on ga-dcr-agent-shared only (R6). Same gap:
    a jumpbox session could write forged rows with it (A13). There is no local-only mode: the workspace audit is
    required, and an allow that can't be audited isn't returned (D-022).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I removes the script directory from sys.path

import pack  # noqa: E402
import telemetry  # noqa: E402
from agent_session import AgentSession  # noqa: E402
from audit import AuditLog  # noqa: E402
from claims_tool import RecordTool  # noqa: E402
from client_loop import INCLUDE, annotation_metadata, format_answer, run_turn  # noqa: E402
from decision_checker import (NOTE_INCONSISTENT, REASON_INCONSISTENT, SemanticCheck, checker_call,  # noqa: E402
                              screen_answer)
from identity import CallerValidationError, validated_caller_oid  # noqa: E402
from ingest import AUDIT_STREAM, IngestionSink  # noqa: E402
from records import CosmosRecordReader  # noqa: E402
from untrusted import DecisionCheck, DocumentTooLong, wrap  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Larkfield case assistant (synthetic lab data)")
    parser.add_argument("question", help="one question for this turn")
    parser.add_argument("--audit-log", type=Path, default=pack.ROOT / "agent" / "logs" / "tool-audit.jsonl")
    parser.add_argument("--document", action="append", type=Path, default=[],
                        help="member-submitted document (UTF-8 text file); the client wraps its text in the "
                             "<documents> delimiter (C3). Repeatable.")
    parser.add_argument("--redteam-id", help="red-team run label, copied to audit rows so results join (w3-harness)")
    parser.add_argument("--show-annotations", action="store_true",
                        help="diagnostics: print the final response's annotation metadata (types, keys, file IDs, "
                             "positions), never message text or tool results")
    args = parser.parse_args()

    from azure.ai.projects import AIProjectClient
    from azure.identity import AzureCliCredential, ManagedIdentityCredential

    config = pack.load_config()
    check = DecisionCheck.from_config(config)
    semantic = SemanticCheck.from_config(config)
    question = args.question
    if args.document:
        # Before any sign-in or Azure call: a message that's too long is refused and nothing is sent.
        try:
            question = wrap(args.question, [p.read_text(encoding="utf-8") for p in args.document],
                            max_chars=config["document_input"]["max_message_chars"])
        except DocumentTooLong as exc:
            print(f"Stopped: {exc}. Nothing was sent.", file=sys.stderr)
            return 2
    user_credential = AzureCliCredential()
    # Fail closed: if the token can't be validated (signature, audience, issuer, tenant, expiry), stop here. There is no
    # fallback to unvalidated token claims or to an environment variable; a failure is a design decision for Tooni.
    try:
        caller = validated_caller_oid(user_credential, os.environ["GA_TENANT_ID"])
    except CallerValidationError as exc:
        print(f"Stopped: couldn't validate your sign-in token ({exc}). No fallback is used; nothing was called.",
              file=sys.stderr)
        return 2
    store = config["record_store"]
    jumpbox_identity = ManagedIdentityCredential()
    reader = CosmosRecordReader(os.environ["COSMOS_ENDPOINT"], store["database"], store["container"], jumpbox_identity)
    sink = IngestionSink(os.environ["AUDIT_INGEST_ENDPOINT"], os.environ["AUDIT_DCR_ID"], AUDIT_STREAM,
                         jumpbox_identity)
    audit = AuditLog(args.audit_log, sink=sink, redteam_id=args.redteam_id)

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=user_credential,
                              allow_preview=True)
    telemetry.configure(project)
    # The agent's own endpoint (D-039): Foundry Agent Consumer is enough, and no agent_reference is sent.
    openai = project.get_openai_client(agent_name=config["agent_name"])
    # The decision checker is another agent on the same project, reached the same way (C1 layer 2).
    checker = project.get_openai_client(agent_name=config["decision_check"]["agent_name"])
    # INCLUDE asks for File Search results so the client can list the retrieved file names (C8); only names are read.
    session = AgentSession(openai, INCLUDE).start()

    tool = RecordTool(caller_oid=caller, entitlements=pack.load_entitlements(), reader=reader, audit=audit,
                      config=config, conversation_id=session.audit_id)

    def on_refused(name: str) -> None:
        audit.record(caller=caller, record_id="", scenario=config["scenario"], action="call",
                     decision="deny", conversation_id=session.audit_id(), reason="unknown_tool",
                     tool_name=name)

    create_response = session.create_response
    result = run_turn(create_response, question, {tool.name: tool.dispatch},
                      max_tool_calls=config["max_tool_calls_per_turn"], on_refused=on_refused)
    outcome = screen_answer(format_answer(result, tool.records_returned), check, semantic, checker_call(checker))
    if outcome.reason:
        audit.record(caller=caller, record_id="", scenario=config["scenario"], action="answer",
                     decision="withheld", conversation_id=session.audit_id(), reason=outcome.reason)
    elif outcome.note == NOTE_INCONSISTENT:
        # The checker said false but quoted evidence: the verdict is trusted and the draft shown (Tooni, 2026-11-14).
        # Audited before it's shown; an allow row that can't be written raises AuditUnavailable, so nothing is shown.
        audit.record(caller=caller, record_id="", scenario=config["scenario"], action="answer",
                     decision="allow", conversation_id=session.audit_id(), reason=REASON_INCONSISTENT)
    print(outcome.shown)
    # The layer and the regex IDs only: the semantic evidence quote is a sentence from the withheld draft.
    if outcome.layer == "regex":
        print(f"[decision-language check: {', '.join(outcome.regex_hits)}]")
    elif outcome.layer == "semantic":
        print("[decision-language check: semantic]")
    elif outcome.layer == "unavailable":
        print(f"[decision check unavailable: {outcome.unavailable_kind}]")
    elif outcome.note == NOTE_INCONSISTENT:
        print("[decision check: inconsistent verdict (false with evidence); shown]")
    if args.show_annotations:
        print("\n[annotation metadata]\n" + json.dumps(annotation_metadata(result.response), indent=1))
    print(f"\n[{session.mode} {session.audit_id()}; tool calls this turn: {result.tool_calls}"
          f"{'; stopped at the cap' if result.stopped else ''}; audit log: {args.audit_log}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
