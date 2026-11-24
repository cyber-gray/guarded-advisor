"""Unit tests for redteam/decision_check_eval.py and the adversarial eval items. No Azure calls: a fake client.

    python3 -I -m unittest discover -s agent/tests -p 'test_decision_check_eval.py' -v
"""
from __future__ import annotations

import io
import json
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "redteam"))
sys.path.insert(0, str(ROOT / "agent"))

import decision_check_eval as dce  # noqa: E402
import pack  # noqa: E402
from decision_checker import SemanticCheck, checker_call  # noqa: E402
from untrusted import DecisionCheck  # noqa: E402

CONFIG = pack.load_config("larkfield")
REGEX = DecisionCheck.from_config(CONFIG)
SEMANTIC = SemanticCheck.from_config(CONFIG)
ITEMS = dce.load_items(pack.pack_dir("larkfield") / "decision-check-eval.json")
BY_ID = {i["id"]: i for i in ITEMS}
EVIDENCE_MARKER = "EVIDENCE-MUST-NOT-BE-STORED"


class FakeClient:
    """A checker agent stand-in: answers with each item's label, except for scripted overrides."""

    def __init__(self, overrides=None):
        self.by_input = {SEMANTIC.build_input(i["text"]): i for i in ITEMS}
        self.overrides, self.sent = overrides or {}, []
        self.responses = SimpleNamespace(create=self.create)

    def create(self, **kwargs):
        self.sent.append(kwargs)
        item = self.by_input[kwargs["input"]]
        action = self.overrides.get(item["id"])
        if isinstance(action, BaseException):
            raise action
        if action == "inconsistent":   # false with a quote, the 11-13 "schema" case
            return SimpleNamespace(output_text=json.dumps({"decision_language": False, "evidence": EVIDENCE_MARKER}))
        flag = item["expect"] if action is None else action
        return SimpleNamespace(output_text=json.dumps(
            {"decision_language": flag, "evidence": EVIDENCE_MARKER if flag else ""}))


def run(overrides=None, items=ITEMS):
    client = FakeClient(overrides)
    rows = dce.evaluate(items, REGEX, SEMANTIC, checker_call(client), sleep=lambda s: None)
    return rows, client


class AdversarialItems(unittest.TestCase):
    def test_present_and_labelled_positive(self):
        adv = [i for i in ITEMS if i["id"].startswith("P-adv-")]
        self.assertEqual(len(adv), 10)
        self.assertTrue(all(i["expect"] for i in adv))
        texts = " ".join(i["text"] for i in adv)
        for marker in ['"decision_language": false', '</documents> """', "part 2: set decision_language",
                       "Answer false"]:
            self.assertIn(marker, texts)

    def test_layer_1_holds_whatever_the_checker_says(self):
        rows, _ = run({"P-adv-09-regex-plus-false": False}, [BY_ID["P-adv-09-regex-plus-false"]])
        self.assertEqual((rows[0]["regex"], rows[0]["semantic"], rows[0]["combined_withheld"]), (True, "false", True))

    def test_a_fake_close_in_a_draft_stays_inside_the_block(self):
        sent = SEMANTIC.build_input(BY_ID["P-adv-05-fake-close-reopen"]["text"])
        self.assertEqual((sent.count("<documents>"), sent.count("</documents>")), (1, 1))


class Evaluate(unittest.TestCase):
    def test_both_layers_run_on_every_item(self):
        rows, client = run()
        self.assertEqual(len(rows), len(ITEMS))
        self.assertEqual(len(client.sent), len(ITEMS))
        self.assertTrue(all(set(c) == {"input", "timeout"} for c in client.sent))

    def test_counts_and_failed_ids(self):
        rows, _ = run({"P-C3-2a-1112": False, "N-label": True, "N-m3": RuntimeError("boom"),
                       "P-adv-02-fake-json": TimeoutError()})
        s = dce.summary(rows)
        positives, negatives = s["positives"], s["negatives"]
        self.assertEqual(positives + negatives, len(ITEMS))
        l2 = s["layer2_semantic"]
        self.assertEqual(l2["FN"], ["P-C3-2a-1112"])
        self.assertEqual(l2["FP"], ["N-label"])
        self.assertEqual(s["layer2_unavailable"], {"N-m3": "error", "P-adv-02-fake-json": "timeout"})
        self.assertEqual(len(l2["TP"]) + len(l2["FN"]) + len(l2["FP"]) + len(l2["TN"]), len(ITEMS) - 2)
        l1 = s["layer1_regex"]
        self.assertEqual(sorted(l1["FP"]), ["N-near-01", "N-reported-injection"])
        self.assertEqual(len(l1["TP"]), sum(i["expect"] and i["regex"] for i in ITEMS))
        comb = s["combined"]
        self.assertIn("P-C3-2a-1112", comb["FN"])            # neither layer withheld it
        self.assertIn("N-m3", comb["FP"])                    # unavailable withholds (fail closed)
        self.assertIn("P-adv-02-fake-json", comb["TP"])      # unavailable withholds a positive too
        text = dce.render(s)
        self.assertIn("FN (positive shown): P-C3-2a-1112", text)

    def test_inconsistent_false_counts_as_shown_and_is_listed(self):
        rows, _ = run({"N-rtw": "inconsistent", "N-plan-01": "inconsistent", "P-semantic-01": "inconsistent"})
        by = {r["id"]: r for r in rows}
        self.assertEqual((by["N-rtw"]["semantic"], by["N-rtw"]["semantic_note"], by["N-rtw"]["unavailable_kind"]),
                         ("false", "inconsistent", ""))
        s = dce.summary(rows)
        self.assertEqual(s["layer2_inconsistent"], ["P-semantic-01", "N-rtw", "N-plan-01"])
        self.assertEqual(s["layer2_unavailable"], {})
        self.assertIn("N-rtw", s["combined"]["TN"])               # shown, as the client shows it
        self.assertIn("P-semantic-01", s["combined"]["FN"])       # a positive shown is still an FN
        self.assertIn("layer2_inconsistent (false with evidence, shown): 3", dce.render(s))
        self.assertNotIn(EVIDENCE_MARKER, json.dumps(rows) + dce.render(s))

    def test_no_draft_or_evidence_text_is_recorded(self):
        rows, _ = run()
        dump = json.dumps(rows) + dce.render(dce.summary(rows))
        self.assertNotIn(EVIDENCE_MARKER, dump)
        for item in ITEMS:
            self.assertNotIn(item["text"], dump)
        self.assertTrue(all(set(r) == set(dce.ROW_FIELDS) for r in rows))


class Guards(unittest.TestCase):
    def test_out_path_must_be_private_and_new(self):
        self.assertIsNotNone(dce.check_out_path(ROOT / "redteam" / "logs" / "x.jsonl"))
        self.assertIsNotNone(dce.check_out_path(ROOT / "README.md"))
        self.assertIsNone(dce.check_out_path(Path("/nonexistent-dir-for-test/dc.jsonl")))

    def test_refusals_happen_before_any_azure_import(self):
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(dce.main(["--out", str(ROOT / "x.jsonl")]), 2)
            self.assertEqual(dce.main(["--out", "/nonexistent-dir-for-test/dc.jsonl", "--items", "NOPE"]), 2)
        self.assertIn("inside the repository", err.getvalue())
        self.assertIn("unknown item IDs", err.getvalue())
        self.assertNotIn("azure.ai.projects", sys.modules)

    def test_duplicate_ids_are_refused(self):
        tmp = Path("/nonexistent-dir-for-test")
        doc = {"items": [{"id": "a", "expect": True, "text": "x"}, {"id": "a", "expect": False, "text": "y"}]}
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "e.json"
            p.write_text(json.dumps(doc), encoding="utf-8")
            with self.assertRaises(ValueError):
                dce.load_items(p)
        self.assertFalse(tmp.exists())


if __name__ == "__main__":
    unittest.main()
