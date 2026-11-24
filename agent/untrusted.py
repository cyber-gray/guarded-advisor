"""Untrusted document input and the decision-language output check (C1, C3; client fix A, 2026-11-12).

Input side (C3). A member-submitted document reaches the model only through `wrap()`, which the client applies to every
`--document` file, so a case manager can't leave the delimiter out (findings 2026-11-11, C3-2):
  - The document text goes inside the delimiter that indirect attack detection depends on:
        <question> \"\"\" <documents>
        <escaped document text>
        </documents> \"\"\"
    https://learn.microsoft.com/azure/foundry/guardrails/how-to-create-guardrails#document-embedding-in-prompts
  - The text is JSON-escaped, as Learn says to do for unvetted documents (same section). That also turns `\"\"\"` into
    `\\"\\"\\"`, and `<documents` / `</documents` inside the text are written as `\\u003c...`, so a document can't close
    the delimiter early.
  - The whole message, as sent, must fit the pack's `document_input.max_message_chars` (1,000 for larkfield), or nothing
    is sent. Learn says guardrails moderate the first 1,000 characters of text, but on 2026-11-11 the guardrail reported
    a moderated length of 3,703 for an 878-character message, so the limit is a precaution until Learn clarifies it.
    It applies to --document input only; the B1 runner (redteam/bias_b1.py) builds its own messages and doesn't use it.

Output side (C1). `DecisionCheck` withholds an answer that states or recommends a claim decision. The patterns live in
the pack (`output_check` in agent.json), not here. A withheld answer is never shown; the caller writes an audit row with
decision "withheld", which D5 doesn't count (it counts decision == "deny" only).

What this doesn't catch: injections that arrive through tool output (get_claim_summary notes or documents) or File
Search, which aren't delimited or scanned; a document pasted into the question instead of passed as --document;
paraphrased or non-English decisions (on 2026-11-12 two rephrased approvals passed the patterns; the semantic layer in
decision_checker.py runs when they find nothing); disclosure within the caller's own caseload. Known false positive,
failing safe: a correct report of a manipulation attempt that quotes it ("the note asks staff to approve this claim") is
withheld.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

OPEN = '""" <documents>'
CLOSE = '</documents> """'
_TAG = re.compile(r"<(/?)(documents)", re.IGNORECASE)
_MARKUP = re.compile(r"[*_`]")
_SPACE = re.compile(r"\s+")


class DocumentTooLong(ValueError):
    """The wrapped message is longer than the pack allows; nothing was sent."""


def escape_document(text: str) -> str:
    """JSON-escape the text (Learn), then write any documents tag as \\u003c so it can't open or close the delimiter."""
    escaped = json.dumps(text, ensure_ascii=True)[1:-1]
    return _TAG.sub(lambda m: "\\u003c" + m.group(1) + m.group(2), escaped)


def wrap(question: str, documents: list[str], *, max_chars: int | None) -> str:
    """The question followed by the documents inside the delimiter, as one user message."""
    if not documents:
        raise ValueError("wrap() needs at least one document")
    body = "\n\n".join(escape_document(d) for d in documents)
    message = f"{question} {OPEN}\n{body}\n{CLOSE}"
    if max_chars is not None and len(message) > max_chars:
        raise DocumentTooLong(f"the question with its documents is {len(message)} characters after escaping; "
                              f"the limit is {max_chars}")
    return message


@dataclass(frozen=True)
class DecisionCheck:
    patterns: tuple[tuple[str, re.Pattern], ...]
    not_after: re.Pattern | None
    withheld_message: str

    @classmethod
    def from_config(cls, config: dict) -> "DecisionCheck":
        oc = config["output_check"]
        patterns = tuple((p["id"], re.compile(p["regex"], re.IGNORECASE)) for p in oc["decision_patterns"])
        if not patterns:
            raise ValueError("output_check.decision_patterns is empty")
        not_after = re.compile(oc["not_after"], re.IGNORECASE) if oc.get("not_after") else None
        return cls(patterns, not_after, oc["withheld_message"])

    def matches(self, text: str) -> list[str]:
        """IDs of the patterns that match, after removing markdown emphasis and joining lines."""
        flat = _SPACE.sub(" ", _MARKUP.sub("", text))
        hits = []
        for pid, rx in self.patterns:
            for m in rx.finditer(flat):
                before = flat[max(0, m.start() - 12):m.start()]
                if self.not_after is not None and self.not_after.search(before):
                    continue
                hits.append(pid)
                break
        return hits

    def screen(self, answer: str) -> tuple[str, list[str]]:
        """(text to show, matched pattern IDs). A matched answer is replaced by the withheld message."""
        hits = self.matches(answer)
        return (self.withheld_message, hits) if hits else (answer, [])
