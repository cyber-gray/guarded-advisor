"""Unit tests for client fix B (agent/agent_session.py, case_assistant.py; D-039, C2). No Azure calls.

    python3 -I -m unittest discover -s agent/tests -p 'test_agent_endpoint.py' -v
"""
from __future__ import annotations

import ast
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

AGENT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(AGENT))

import pack  # noqa: E402
from agent_session import AgentSession  # noqa: E402
from audit import AuditLog  # noqa: E402
from claims_tool import RecordTool  # noqa: E402
from client_loop import INCLUDE, run_turn  # noqa: E402

CONFIG = pack.load_config("larkfield")
SRC = (AGENT / "case_assistant.py").read_text(encoding="utf-8")


class StatusError(Exception):
    def __init__(self, status, code=None):
        super().__init__(f"HTTP {status}")
        self.status_code = status
        if code is not None:
            self.body = {"error": {"code": code, "message": "blocked"}}


class FakeOpenAI:
    """Records every responses.create call; conversations.create returns an ID or raises."""

    def __init__(self, conversation_error=None, outputs=None):
        self.calls = []
        self._n = 0
        self._outputs = list(outputs or [])

        def create_conversation():
            if conversation_error is not None:
                raise conversation_error
            return SimpleNamespace(id="conv_test")

        def create_response(**kwargs):
            self.calls.append(kwargs)
            self._n += 1
            output = self._outputs.pop(0) if self._outputs else []
            return SimpleNamespace(id=f"resp_{self._n}", output=output, output_text="done")

        self.conversations = SimpleNamespace(create=create_conversation)
        self.responses = SimpleNamespace(create=create_response)


def fc(call_id, claim):
    return SimpleNamespace(type="function_call", name="get_claim_summary", call_id=call_id,
                           arguments='{"claim_id": "%s"}' % claim)


class CaseAssistantUsesTheAgentEndpoint(unittest.TestCase):
    def call(self, name):
        tree = ast.parse(SRC)
        return [n for n in ast.walk(tree) if isinstance(n, ast.Call)
                and (getattr(n.func, "id", None) == name or getattr(n.func, "attr", None) == name)]

    def test_project_client_allows_preview(self):
        calls = self.call("AIProjectClient")
        self.assertEqual(len(calls), 1)
        kw = {k.arg: k.value for k in calls[0].keywords}
        self.assertIsInstance(kw.get("allow_preview"), ast.Constant)
        self.assertIs(kw["allow_preview"].value, True)

    def test_openai_clients_are_bound_to_agents(self):
        """Two clients, each bound to an agent endpoint: the case assistant and the decision checker (C1 layer 2)."""
        calls = self.call("get_openai_client")
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual([k.arg for k in call.keywords], ["agent_name"])
        self.assertIn('get_openai_client(agent_name=config["agent_name"])', SRC)
        self.assertIn('get_openai_client(agent_name=config["decision_check"]["agent_name"])', SRC)

    def test_no_agent_reference_and_no_direct_calls(self):
        code = [line for line in SRC.splitlines() if not line.strip().startswith("#")]
        self.assertEqual([line for line in code if "agent_reference" in line], [])
        self.assertNotIn("extra_body", SRC)
        self.assertNotIn("conversations.create", SRC)
        self.assertNotIn("responses.create", SRC)
        self.assertIn("AgentSession(openai, INCLUDE).start()", SRC)


class ConversationMode(unittest.TestCase):
    def test_turn_uses_the_conversation_and_no_agent_reference(self):
        openai = FakeOpenAI(outputs=[[fc("c1", "LM-CLM-2026-0001")], []])
        session = AgentSession(openai, INCLUDE).start()
        self.assertEqual((session.mode, session.audit_id()), ("conversation", "conv_test"))
        run_turn(session.create_response, "q", {"get_claim_summary": lambda a: "{}"})
        self.assertEqual(len(openai.calls), 2)
        for call in openai.calls:
            self.assertEqual(call["conversation"], "conv_test")
            self.assertEqual(call["include"], INCLUDE)
            self.assertNotIn("previous_response_id", call)
            self.assertNotIn("extra_body", call)


class ChainFallback(unittest.TestCase):
    def test_unsupported_statuses_fall_back_to_previous_response_id(self):
        for status in (400, 404, 405):
            with self.subTest(status=status):
                openai = FakeOpenAI(conversation_error=StatusError(status),
                                    outputs=[[fc("c1", "LM-CLM-2026-0001")], [fc("c2", "LM-CLM-2026-0002")], []])
                session = AgentSession(openai, INCLUDE).start()
                self.assertEqual(session.mode, "chain")
                run_turn(session.create_response, "q", {"get_claim_summary": lambda a: "{}"})
                self.assertNotIn("previous_response_id", openai.calls[0])
                self.assertEqual(openai.calls[1]["previous_response_id"], "resp_1")
                self.assertEqual(openai.calls[2]["previous_response_id"], "resp_2")
                self.assertTrue(all("conversation" not in c for c in openai.calls))
                self.assertEqual(session.audit_id(), "resp_1")

    def test_permission_errors_are_raised_not_hidden(self):
        for status in (401, 403, 500):
            with self.subTest(status=status):
                with self.assertRaises(StatusError):
                    AgentSession(FakeOpenAI(conversation_error=StatusError(status)), INCLUDE).start()

    def test_status_on_a_response_attribute_is_read(self):
        exc = Exception("not found")
        exc.response = SimpleNamespace(status_code=404)
        self.assertEqual(AgentSession(FakeOpenAI(conversation_error=exc), INCLUDE).start().mode, "chain")

    def test_audit_id_before_any_response_is_an_error(self):
        session = AgentSession(FakeOpenAI(conversation_error=StatusError(404)), INCLUDE).start()
        with self.assertRaises(RuntimeError):
            session.audit_id()

    def test_content_filter_on_conversation_create_is_raised_not_a_fallback(self):
        for exc in (StatusError(400, code="content_filter"), StatusError(404, code="content_filter")):
            with self.subTest(status=exc.status_code):
                with self.assertRaises(StatusError):
                    AgentSession(FakeOpenAI(conversation_error=exc), INCLUDE).start()

    def test_errors_from_responses_create_always_surface(self):
        """The fallback is for conversations.create only. A guardrail block (400 content_filter) or any 400/404/405 from
        responses.create reaches the caller unchanged, in both modes, and the mode doesn't change."""
        for conv_error in (None, StatusError(404)):
            for exc in (StatusError(400, code="content_filter"), StatusError(400), StatusError(404), StatusError(405)):
                with self.subTest(mode="chain" if conv_error else "conversation", status=exc.status_code,
                                  code=getattr(exc, "body", {}).get("error", {}).get("code")):
                    openai = FakeOpenAI(conversation_error=conv_error)

                    def raising(**kwargs):
                        openai.calls.append(kwargs)
                        raise exc

                    openai.responses.create = raising
                    session = AgentSession(openai, INCLUDE).start()
                    mode = session.mode
                    with self.assertRaises(StatusError) as caught:
                        run_turn(session.create_response, "q", {})
                    self.assertIs(caught.exception, exc)
                    self.assertEqual(session.mode, mode)
                    self.assertEqual(len(openai.calls), 1)

    def test_fallback_code_wraps_only_conversation_create(self):
        src = (AGENT / "agent_session.py").read_text(encoding="utf-8")
        tree = ast.parse(src)
        tries = [n for n in ast.walk(tree) if isinstance(n, ast.Try)]
        self.assertEqual(len(tries), 1)
        guarded = ast.unparse(tries[0].body[0]) if hasattr(ast, "unparse") else ""
        self.assertIn("conversations.create", guarded)
        create_response = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                               and n.name == "create_response")
        self.assertFalse([n for n in ast.walk(create_response) if isinstance(n, ast.Try)])

    def test_create_before_start_is_an_error(self):
        with self.assertRaises(RuntimeError):
            AgentSession(FakeOpenAI(), INCLUDE).create_response("q")


class AuditRowsCarryTheTurnId(unittest.TestCase):
    def test_tool_rows_use_the_first_response_id_in_chain_mode(self):
        entitlements = pack.load_entitlements("larkfield")
        caller = next(oid for oid, claims in entitlements.items() if "LM-CLM-2026-0001" in claims)
        records = {r["claim_id"]: r for r in pack.load_records("larkfield")}
        reader = SimpleNamespace(read=lambda cid: records.get(cid))
        openai = FakeOpenAI(conversation_error=StatusError(404), outputs=[[fc("c1", "LM-CLM-2026-0001")], []])
        session = AgentSession(openai, INCLUDE).start()
        with tempfile.TemporaryDirectory() as d:
            audit = AuditLog(Path(d) / "a.jsonl")
            tool = RecordTool(caller_oid=caller, entitlements=entitlements, reader=reader, audit=audit,
                              config=CONFIG, conversation_id=session.audit_id)
            run_turn(session.create_response, "q", {tool.name: tool.dispatch})
            rows = (Path(d) / "a.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(rows), 1)
        self.assertIn('"conversation_id": "resp_1"', rows[0])

    def test_a_plain_string_still_works(self):
        tool = RecordTool(caller_oid="c", entitlements={}, reader=None, audit=None, config=CONFIG,
                          conversation_id="conv_fixed")
        self.assertEqual(tool._conversation_id_now(), "conv_fixed")


if __name__ == "__main__":
    unittest.main()
