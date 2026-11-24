"""Unit tests for the B1 agent gates (agent/b1_agent.py) and the B1 runner's agent-endpoint call (redteam/bias_b1.py).
No Azure calls: a fake project.

    python3 -I -m unittest discover -s agent/tests -p 'test_b1_agent.py' -v
"""
from __future__ import annotations

import ast
import json
import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

AGENT = Path(__file__).resolve().parent.parent
ROOT = AGENT.parent
sys.path.insert(0, str(AGENT))

import b1_agent as b1  # noqa: E402
import pack  # noqa: E402
from claims_tool import tool_schema  # noqa: E402

CONFIG = pack.load_config("larkfield")
MAIN = CONFIG["agent_name"]
B1 = CONFIG["b1_agent"]["agent_name"]
VS = ["vs_00000000000000000000test"]
RUNNER = (ROOT / "redteam" / "bias_b1.py").read_text(encoding="utf-8")


def not_found():
    err = Exception("not found")
    err.status_code = 404
    return err


class FakeAgents:
    """The case assistant exists with a File Search tool; the B1 agent exists only after create."""

    def __init__(self, b1_exists=False, b1_details=None):
        self.store = {MAIN: {"name": MAIN, "versions": {"latest": {"version": "7"}}}}
        if b1_exists:
            self.store[B1] = {"name": B1, "versions": {"latest": {"version": "1"}}}
        self.b1_details, self.created, self.deleted = b1_details, [], []

    def get(self, agent_name):
        if agent_name not in self.store:
            raise not_found()
        return self.store[agent_name]

    def get_version(self, agent_name, agent_version):
        if agent_name == MAIN:
            return {"definition": {"tools": [{"type": "file_search", "vector_store_ids": VS},
                                             {"type": "function", "name": "get_claim_summary"}]}}
        return self.b1_details

    def create_version(self, agent_name, definition, description):
        self.created.append(definition)
        self.store[agent_name] = {"name": agent_name, "versions": {"latest": {"version": "1"}}}
        return {"name": agent_name, "version": "1"}

    def delete(self, agent_name):
        self.deleted.append(agent_name)
        self.store.pop(agent_name, None)


MODELS = SimpleNamespace(**{n: (lambda n: (lambda **kw: dict(kw, _cls=n)))(n) for n in b1.SDK_MODELS})


def good_details():
    s = b1.settings(CONFIG)
    return {"name": B1, "version": "1",
            "definition": {"model": s["model"], "temperature": 0, "instructions": pack.load_instructions(CONFIG),
                           "text": {"format": {"type": "json_schema", "name": "b1_summary", "strict": True}},
                           "tools": [{"type": "file_search", "vector_store_ids": VS},
                                     {"type": "function", "name": tool_schema(CONFIG)["name"]}]}}


def run_create(agents, answer="larkfield-case-assistant-b1"):
    lines = []
    rc = b1.create(SimpleNamespace(agents=agents), CONFIG, MODELS, ask=lambda _: answer, out=lines.append)
    return rc, lines


class Settings(unittest.TestCase):
    def test_pack_block(self):
        s = b1.settings(CONFIG)
        self.assertEqual((s["agent_name"], s["temperature"], s["format_name"]),
                         ("larkfield-case-assistant-b1", 0, "b1_summary"))
        self.assertNotEqual(s["agent_name"], MAIN)
        pairs = json.loads((pack.pack_dir("larkfield") / "bias" / "pairs.json").read_text(encoding="utf-8"))
        self.assertEqual(s["schema"], pairs["output_schema"])

    def test_bad_settings_are_refused(self):
        for key, value in [("temperature", 1), ("agent_name", MAIN)]:
            bad = json.loads(json.dumps(CONFIG))
            bad["b1_agent"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                b1.settings(bad)


class Gates(unittest.TestCase):
    def test_create_refuses_an_existing_b1_agent(self):
        agents = FakeAgents(b1_exists=True)
        rc, lines = run_create(agents)
        self.assertEqual((rc, agents.created), (1, []))
        self.assertIn("already exists", lines[0])

    def test_create_needs_the_name_typed_back(self):
        agents = FakeAgents()
        self.assertEqual(run_create(agents, "yes")[0], 1)
        self.assertEqual(agents.created, [])

    def test_create_copies_the_case_assistant_and_reads_back(self):
        agents = FakeAgents(b1_details=good_details())
        rc, lines = run_create(agents)
        self.assertEqual(rc, 0, lines)
        d = agents.created[0]
        self.assertEqual((d["model"], d["temperature"]), ("gpt-4.1-mini", 0))
        self.assertEqual(d["instructions"], pack.load_instructions(CONFIG))
        self.assertEqual(d["text"]["format"]["name"], "b1_summary")
        self.assertIs(d["text"]["format"]["strict"], True)
        fs, fn = d["tools"]
        self.assertEqual(fs["vector_store_ids"], VS)        # reused, nothing uploaded
        self.assertEqual(fn["name"], "get_claim_summary")
        self.assertNotIn("You are", "\n".join(lines))         # instructions compared by hash, never printed

    def test_a_differing_read_back_is_a_finding(self):
        details = good_details()
        details["definition"]["temperature"] = 1
        details["definition"]["tools"][0]["vector_store_ids"] = ["vs_other"]
        rc, lines = run_create(FakeAgents(b1_details=details))
        self.assertEqual(rc, 1)
        self.assertIn("FINDING", lines[-1])
        self.assertIn("temperature", lines[-1])
        self.assertIn("same_vector_store", lines[-1])

    def test_delete_needs_the_name_and_leaves_the_case_assistant_and_vector_store(self):
        agents = FakeAgents(b1_exists=True)
        store_deletes, probed = [], []
        project = SimpleNamespace(agents=agents,
                                  vector_stores=SimpleNamespace(delete=lambda *a, **k: store_deletes.append(a)))

        def store_exists(vid):
            probed.append(vid)
            return True

        lines = []
        self.assertEqual(b1.delete(project, CONFIG, store_exists, ask=lambda _: "no", out=lines.append), 1)
        self.assertEqual(agents.deleted, [])
        self.assertEqual(b1.delete(project, CONFIG, store_exists, ask=lambda _: B1, out=lines.append), 0)
        self.assertEqual(agents.deleted, [B1])                  # only the B1 agent
        self.assertEqual(store_deletes, [])                     # the shared vector store is never deleted
        self.assertEqual(probed, VS)                            # and it's read back
        self.assertIn(f"{B1} exists: no; {MAIN} exists: yes; shared vector store exists: yes", lines[-1])
        tree = ast.parse((AGENT / "b1_agent.py").read_text(encoding="utf-8"))
        deletes = [ast.unparse(n.func) for n in ast.walk(tree)
                   if isinstance(n, ast.Call) and getattr(n.func, "attr", None) == "delete"]
        self.assertEqual(deletes, ["project.agents.delete"])     # the only delete call in the module

    def test_delete_read_back_flags_a_missing_vector_store(self):
        lines = []
        rc = b1.delete(SimpleNamespace(agents=FakeAgents(b1_exists=True)), CONFIG, lambda vid: False,
                       ask=lambda _: B1, out=lines.append)
        self.assertEqual(rc, 1)
        self.assertIn("shared vector store exists: NO", lines[-2])
        self.assertIn("FINDING", lines[-1])

    def test_dry_run_makes_no_azure_call(self):
        out = subprocess.run([sys.executable, "-I", str(AGENT / "b1_agent.py"), "--dry-run"],
                             capture_output=True, text=True, cwd=ROOT, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("larkfield-case-assistant-b1 (copy of larkfield-case-assistant) on gpt-4.1-mini, temperature 0",
                      out.stdout)


class Runner(unittest.TestCase):
    def calls(self, name):
        return [n for n in ast.walk(ast.parse(RUNNER)) if isinstance(n, ast.Call)
                and (getattr(n.func, "id", None) == name or getattr(n.func, "attr", None) == name)]

    def test_calls_the_b1_agent_endpoint_with_no_per_call_settings(self):
        self.assertIn('get_openai_client(agent_name=config["b1_agent"]["agent_name"])', RUNNER)
        client = self.calls("AIProjectClient")[0]
        self.assertTrue(any(k.arg == "allow_preview" and getattr(k.value, "value", None) is True
                            for k in client.keywords))
        for name in ("create", "create_response"):
            for call in self.calls(name):
                self.assertFalse({"temperature", "text", "extra_body"} & {k.arg for k in call.keywords}, name)
        code = [line for line in RUNNER.splitlines() if not line.lstrip().startswith("#")]
        self.assertFalse([line for line in code if "agent_reference" in line and "no agent_reference" not in line])
        self.assertIn("AgentSession(openai, INCLUDE).start()", RUNNER)

    def test_still_stops_when_the_effective_settings_are_wrong(self):
        self.assertIn('settings_ok = temperature == 0 and fmt == "json_schema"', RUNNER)
        self.assertIn("return 3", RUNNER)


if __name__ == "__main__":
    unittest.main()
