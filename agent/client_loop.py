"""One user turn against a Foundry prompt agent (Responses API), with local function tools.

- At most `max_tool_calls` function calls per user turn; when a turn would exceed it, the loop stops and returns a
  clear message instead of continuing (unbounded consumption, A7-style loops).
- Only tools in the `tools` map run; any other function name is refused, reported to the model as refused, and passed
  to `on_refused` for logging. Nothing outside the map is ever executed.
- Sources (C8) are built by the client from the File Search results of the whole turn, never from the model's own text.
  Foundry agent responses carried no citation annotations (findings, 2026-10-23), so the client requests
  include=["file_search_call.results"] (INCLUDE) and lists the retrieved files, best match first, with the number of
  passages from each, labelled "Retrieved from" (retrieved, not necessarily cited). Only file names and scores are
  read, never the retrieved text or attributes, and scores are used for ordering only. A model-written "Sources" line
  and the service's inline 【...】 markers are removed. "Sources: none retrieved" appears only when no File Search call
  ran.
  include values: https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject (OpenAI.IncludeEnum,
  OpenAI.FileSearchToolCallResults).
Pattern from https://learn.microsoft.com/azure/foundry/agents/how-to/tools/function-calling (function_call items in
response.output, answered with function_call_output items).
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Callable

STOP_MESSAGE = ("Stopped: this request needed more than {n} tool calls in one turn. "
                "Ask a narrower question, for example about one claim at a time.")


NO_SOURCES = "Sources: none retrieved"
NO_NAMES = "Retrieved from: file search ran, but no file names were returned"
NO_PASSAGES = "Retrieved from: file search returned no passages"
INCLUDE = ["file_search_call.results"]
_MARKER = re.compile(r"[ \t]*【[^】]*】")  # the service's inline citation markers, with the space before them
_SPACE_BEFORE_PUNCT = re.compile(r"(?<=\w) +([.,;:!?])(?=\s|$)")  # left behind where the service stripped a marker


@dataclass
class TurnResult:
    text: str
    tool_calls: int
    stopped: bool
    sources: list[str] = field(default_factory=list)  # retrieved file names, best match first, whole turn
    response: object = None  # the final response, kept for --show-annotations; never logged
    searched: bool = False  # a file_search_call ran in this turn
    passages: dict[str, int] = field(default_factory=dict)  # file name -> number of passages retrieved from it
    results_returned: bool = False  # at least one file_search_call carried a results list (include honoured)


# Annotation fields whose values are safe to print: identifiers and positions. Every other field is reported by name only.
_SAFE_ANNOTATION_VALUES = ("type", "file_id", "filename", "index", "start_index", "end_index")


def _fields(obj) -> dict:
    if isinstance(obj, dict):
        return obj
    if hasattr(obj, "model_dump"):
        return obj.model_dump()
    return dict(vars(obj)) if hasattr(obj, "__dict__") else {}


def annotation_metadata(response) -> dict:
    """Diagnostics for C8 Sources: the shape of the final response's annotations, never its content.

    Returns the output item types, and for each annotation on a message part: where it sits, which keys it has, and
    only the values of type, file_id, filename and index positions. Message text, quotes, titles and tool results are
    never included.
    """
    items, annotations = [], []
    for i, item in enumerate(getattr(response, "output", []) or []):
        item_type = getattr(item, "type", None) or _fields(item).get("type")
        entry_item = {"output_index": i, "type": str(item_type)}
        if item_type == "file_search_call":
            results = getattr(item, "results", None) or []
            entry_item["results"] = len(results)
            # Filename and rounded score per result, for calibrating score_threshold; never the text or attributes.
            entry_item["result_scores"] = [{"filename": _result_field(r, "filename") or _result_field(r, "file_id"),
                                            "score": _round(_result_field(r, "score"))} for r in results]
        items.append(entry_item)
        if item_type != "message":
            continue
        for j, part in enumerate(getattr(item, "content", []) or []):
            for k, ann in enumerate(getattr(part, "annotations", []) or []):
                data = _fields(ann)
                entry = {"output_index": i, "content_index": j, "annotation_index": k,
                         "part_type": str(getattr(part, "type", None)), "keys": sorted(data)}
                for name in _SAFE_ANNOTATION_VALUES:
                    value = data.get(name)
                    if isinstance(value, bool) or not isinstance(value, (str, int)):
                        continue
                    entry[name] = value[:200] if isinstance(value, str) else value
                annotations.append(entry)
    return {"output_items": items, "annotations": annotations}


def _result_field(result, name: str):
    value = result.get(name) if isinstance(result, dict) else getattr(result, name, None)
    return value if isinstance(value, (str, int, float)) and not isinstance(value, bool) else None


def _round(score):
    return round(float(score), 3) if isinstance(score, (int, float)) else None


class Retrieved:
    """File Search results of one turn: per file, the best score, the number of passages and the first-seen order.

    Reads only `filename` (or `file_id`) and `score`: never `text` or `attributes`.
    """

    def __init__(self):
        self.searched = False
        self.results_returned = False
        self._files: dict[str, list] = {}  # name -> [best score, passages, first-seen index]

    def add(self, response) -> None:
        for item in getattr(response, "output", []) or []:
            if getattr(item, "type", None) != "file_search_call":
                continue
            self.searched = True
            results = getattr(item, "results", None)
            if results is None:  # include not honoured: the call ran but carried no results list
                continue
            self.results_returned = True
            for result in results:
                name = _result_field(result, "filename") or _result_field(result, "file_id")
                if not isinstance(name, str) or not name:
                    continue
                score = _result_field(result, "score")
                score = float(score) if isinstance(score, (int, float)) else float("-inf")
                entry = self._files.setdefault(name, [score, 0, len(self._files)])
                entry[0], entry[1] = max(entry[0], score), entry[1] + 1

    def names(self) -> list[str]:
        """Best match first; files without scores keep the order they were first seen."""
        return [n for n, _ in sorted(self._files.items(), key=lambda kv: (-kv[1][0], kv[1][2]))]

    def passages(self) -> dict[str, int]:
        return {n: v[1] for n, v in self._files.items()}


def clean_text(text: str) -> str:
    """Remove the service's inline 【...】 citation markers and the stray space a stripped marker leaves."""
    return _SPACE_BEFORE_PUNCT.sub(r"\1", _MARKER.sub("", text))


def format_answer(result: TurnResult, records_used: list[str] | None = None) -> str:
    """Model text without markers or a model-written Sources line, then the client-built line (and records used)."""
    body = "\n".join(line for line in clean_text(result.text).splitlines()
                     if not line.strip().lstrip("*_#> ").lower().startswith("sources")).rstrip()
    if result.sources:
        def count(name):
            n = result.passages.get(name)
            return "" if n is None else f" ({n} passage{'s' if n != 1 else ''})"
        sources_line = "Retrieved from (best match first): " + ", ".join(f"{n}{count(n)}" for n in result.sources)
    elif not result.searched:
        sources_line = NO_SOURCES
    else:
        sources_line = NO_PASSAGES if result.results_returned else NO_NAMES
    lines = [body, "", sources_line]
    if records_used:
        lines.append("Claim records used: " + ", ".join(records_used))
    return "\n".join(lines)


def run_turn(create_response: Callable, user_text: str, tools: dict[str, Callable[[str], str]], *,
             max_tool_calls: int = 5, on_refused: Callable[[str], None] | None = None) -> TurnResult:
    response = create_response(input=user_text)
    calls = 0
    retrieved = Retrieved()

    def result(text, stopped, final=None):
        return TurnResult(text, calls, stopped, retrieved.names(), response=final, searched=retrieved.searched,
                          passages=retrieved.passages(), results_returned=retrieved.results_returned)

    while True:
        retrieved.add(response)
        function_calls = [item for item in response.output if getattr(item, "type", None) == "function_call"]
        if not function_calls:
            return result(response.output_text, False, response)
        if calls + len(function_calls) > max_tool_calls:
            return result(STOP_MESSAGE.format(n=max_tool_calls), True)
        outputs = []
        for fc in function_calls:
            calls += 1
            handler = tools.get(fc.name)
            if handler is None:
                if on_refused:
                    on_refused(fc.name)
                output = json.dumps({"error": f"tool '{fc.name}' is not available; refused"})
            else:
                output = handler(fc.arguments)
            outputs.append({"type": "function_call_output", "call_id": fc.call_id, "output": output})
        response = create_response(input=outputs)
