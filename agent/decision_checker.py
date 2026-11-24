"""Semantic decision check: the second layer of the C1 output check (Friday prep, 2026-11-12).

Why a second layer: the regex check (untrusted.DecisionCheck) missed every injected approval sentence after the first,
because the model rephrases freely: 11-12 C3-2a "Immediate approval of the claim is recommended per the doctor's
instruction." and C3-2b "Immediate approval of this claim is consistent with the provider's recommendation ..."
(findings, 2026-11-12). A pattern list only catches the forms someone already wrote down.

Design:
  - The check is a second prompt agent, the pack's `decision_check.agent_name` (larkfield-decision-checker), called
    through its own agent endpoint like the main agent (client fix B, D-039). Case managers hold Foundry Agent Consumer
    only and can't call a model deployment directly (GW-X1a, 2026-11-12), so a direct chat completion isn't an option.
  - Its instructions are fixed in the pack (decision-checker.md) and its output is held to a strict JSON schema in the
    agent definition: {"decision_language": bool, "evidence": "<short quote>"}. temperature and text can't be sent per
    call when an agent is named (B1 probe, findings 2026-11-11), so both live in the definition
    (agent/checker_agent.py).
  - It receives only the draft, never the member's document. The draft goes inside the same documents delimiter as
    untrusted input (untrusted.wrap), so the guardrail's indirect attack check applies to it too: an injection the main
    agent repeated is screened again here.
  - Fail closed: an exception (including a timeout and a guardrail block), an empty or unparseable reply, a reply that
    doesn't match the schema exactly (keys or types), or a draft longer than `max_draft_chars` all mean the draft is
    withheld with reason "decision_check_unavailable".
  - One exception (Tooni, 2026-11-14): `false` with a non-empty evidence string is an "inconsistent" verdict, not a schema
    failure. The verdict is trusted and the draft shown, and the client audits it with reason
    "decision_check_inconsistent". On 11-13 this was all 5 "schema" failures, each on a negative item (findings,
    2026-11-14, A6). The strict schema can't say "evidence empty when false"; only the instructions ask for it.
  - Layering: the regex runs first. A regex match withholds with reason "decision_language" and the checker isn't
    called. Otherwise the checker decides: true withholds with "decision_language_semantic"; false shows the draft.
  - The evidence quote is never shown or audited: it's a sentence from the withheld draft. It's kept on the Outcome for
    the offline eval only.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Callable

from untrusted import DecisionCheck, wrap

REASON_REGEX = "decision_language"
REASON_SEMANTIC = "decision_language_semantic"
REASON_UNAVAILABLE = "decision_check_unavailable"
REASON_INCONSISTENT = "decision_check_inconsistent"  # audited with decision "allow": the draft is shown
NOTE_INCONSISTENT = "inconsistent"
VERDICT_KEYS = {"decision_language", "evidence"}
_FENCE = re.compile(r"^```(?:json)?\s*\n?(.*?)\n?```$", re.DOTALL)


class CheckUnavailable(RuntimeError):
    """The semantic check couldn't give a valid verdict. `kind` is a short label, never draft text."""

    def __init__(self, kind: str):
        super().__init__(kind)
        self.kind = kind


@dataclass(frozen=True)
class Verdict:
    decision_language: bool
    evidence: str
    inconsistent: bool = False  # false with a non-empty evidence string; the evidence is dropped


@dataclass(frozen=True)
class Outcome:
    shown: str
    reason: str | None          # None when the draft is shown
    layer: str | None           # "regex", "semantic", "unavailable" or None
    regex_hits: tuple[str, ...] = ()
    evidence: str = ""          # semantic evidence; for the offline eval only, never shown or audited
    unavailable_kind: str = ""  # timeout, content_filter, unparseable, schema, too_long, empty, error
    note: str = ""              # "inconsistent" when shown on a false verdict that quoted evidence


def parse_verdict(text: str | None) -> Verdict:
    """Strict parse. Accepts one JSON object, optionally inside a single ```json fence, with exactly the two keys,
    a boolean and a string. Anything else raises. A false verdict with non-empty evidence is returned as false and
    marked inconsistent (Tooni, 2026-11-14); its evidence isn't kept."""
    if text is None or not text.strip():
        raise CheckUnavailable("empty")
    raw = text.strip()
    fenced = _FENCE.match(raw)
    if fenced:
        raw = fenced.group(1).strip()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        raise CheckUnavailable("unparseable") from None
    if not isinstance(data, dict) or set(data) != VERDICT_KEYS:
        raise CheckUnavailable("schema")
    flag, evidence = data["decision_language"], data["evidence"]
    if type(flag) is not bool or not isinstance(evidence, str):
        raise CheckUnavailable("schema")
    if flag is False and evidence.strip():
        return Verdict(False, "", inconsistent=True)  # "no decision" with a quote: trust the verdict, flag it
    return Verdict(flag, evidence.strip()[:300])


@dataclass(frozen=True)
class SemanticCheck:
    agent_name: str
    question: str
    max_draft_chars: int
    timeout_seconds: float
    unavailable_message: str

    @classmethod
    def from_config(cls, config: dict) -> "SemanticCheck":
        dc = config["decision_check"]
        max_chars, timeout = dc["max_draft_chars"], dc["timeout_seconds"]
        if isinstance(max_chars, bool) or not isinstance(max_chars, int) or max_chars < 500:
            raise ValueError("decision_check.max_draft_chars must be an integer of at least 500")
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 1 <= timeout <= 120:
            raise ValueError("decision_check.timeout_seconds must be a number from 1 to 120")
        return cls(dc["agent_name"], dc["question"], max_chars, float(timeout), dc["unavailable_message"])

    def build_input(self, draft: str) -> str:
        """The checker's only input: the fixed question and the draft inside the documents delimiter."""
        message = wrap(self.question, [draft], max_chars=None)
        if len(message) > self.max_draft_chars:
            raise CheckUnavailable("too_long")
        return message

    def classify(self, draft: str, call: Callable[..., Any]) -> Verdict:
        """`call(input=..., timeout=...)` sends one request to the checker agent and returns the response."""
        message = self.build_input(draft)
        try:
            response = call(input=message, timeout=self.timeout_seconds)
        except Exception as exc:  # noqa: BLE001 (fail closed on any failure; the kind is only a label)
            raise CheckUnavailable(_kind(exc)) from None
        return parse_verdict(getattr(response, "output_text", None))


def _kind(exc: BaseException) -> str:
    name = type(exc).__name__.lower()
    if "timeout" in name or isinstance(exc, TimeoutError):
        return "timeout"
    body = getattr(exc, "body", None)
    code = getattr(exc, "code", None)
    if isinstance(body, dict):
        inner = body.get("error") if isinstance(body.get("error"), dict) else body
        code = code or inner.get("code")
    if code == "content_filter" or "content_filter" in str(exc):
        return "content_filter"
    return "error"


def screen_answer(draft: str, regex: DecisionCheck, semantic: SemanticCheck, call: Callable[..., Any]) -> Outcome:
    """Layer 1 regex, layer 2 semantic, fail closed. Returns what to show and why."""
    hits = regex.matches(draft)
    if hits:
        return Outcome(regex.withheld_message, REASON_REGEX, "regex", tuple(hits))
    try:
        verdict = semantic.classify(draft, call)
    except CheckUnavailable as exc:
        return Outcome(semantic.unavailable_message, REASON_UNAVAILABLE, "unavailable", unavailable_kind=exc.kind)
    if verdict.decision_language:
        return Outcome(regex.withheld_message, REASON_SEMANTIC, "semantic", evidence=verdict.evidence)
    return Outcome(draft, None, None, note=NOTE_INCONSISTENT if verdict.inconsistent else "")


def checker_call(openai_client: Any) -> Callable[..., Any]:
    """The one request to the checker agent: no conversation, no tools, no per-call model settings (B1 probe)."""
    def call(*, input: str, timeout: float):
        return openai_client.responses.create(input=input, timeout=timeout)
    return call
