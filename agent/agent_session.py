"""One turn's state against a prompt agent's own endpoint (client fix B, D-039; C2).

case_assistant.py gets an OpenAI client bound to the agent endpoint, `project.get_openai_client(agent_name=...)`, which
in azure-ai-projects points `base_url` at `{project}/agents/{agent}/endpoint/protocols/openai` and requires
`allow_preview=True` on AIProjectClient
(https://learn.microsoft.com/python/api/azure-ai-projects/azure.ai.projects.aiprojectclient?view=azure-python).
On that endpoint, `endpoints/interact/action` (Foundry Agent Consumer) covers runtime interactions with the agent
(https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions#agent-interaction), so no
`agent_reference` is sent: the endpoint already names the agent.

Threading: a conversation when the agent endpoint supports one. Learn documents conversations under the agent endpoint
for hosted agents (https://learn.microsoft.com/azure/foundry/agents/how-to/migrate-hosted-agent-preview#agent-invocation-changes);
for prompt agents that's untested. If creating one fails with 400, 404 or 405 (not supported), the turn chains with
previous_response_id instead, and the audit's conversation_id is the turn's first response ID, so D5 still groups one
turn under one ID. Any other failure, including 401 and 403, is raised: a permission problem is never hidden by the
fallback. The fallback applies to conversations.create only: responses.create has no handler here, so every error
from it, a guardrail block (400 content_filter) included, reaches the caller as it was raised. A content_filter error
from conversations.create is raised too.
"""
from __future__ import annotations

import sys
from typing import Any

UNSUPPORTED_STATUS = (400, 404, 405)


def _code(exc: BaseException) -> str | None:
    """The service error code, from the exception or its JSON body (openai's APIStatusError has both)."""
    code = getattr(exc, "code", None)
    if isinstance(code, str):
        return code
    body = getattr(exc, "body", None)
    if isinstance(body, dict):
        inner = body.get("error") if isinstance(body.get("error"), dict) else body
        if isinstance(inner.get("code"), str):
            return inner["code"]
    return None


def _status(exc: BaseException) -> int | None:
    for attr in ("status_code", "status"):
        value = getattr(exc, attr, None)
        if isinstance(value, int):
            return value
    response = getattr(exc, "response", None)
    value = getattr(response, "status_code", None)
    return value if isinstance(value, int) else None


class AgentSession:
    """Creates responses for one turn, threaded by conversation or, if that isn't supported, by previous_response_id."""

    def __init__(self, openai: Any, include: list[str]):
        self._openai = openai
        self._include = include
        self.mode: str | None = None
        self.conversation_id: str | None = None
        self._first_response_id: str | None = None
        self._previous_response_id: str | None = None

    def start(self) -> "AgentSession":
        try:
            self.conversation_id = self._openai.conversations.create().id
            self.mode = "conversation"
        except Exception as exc:  # noqa: BLE001 (status decides; anything else is re-raised)
            status = _status(exc)
            # A guardrail block is never "not supported": a content_filter error is raised, whatever its status.
            if status not in UNSUPPORTED_STATUS or _code(exc) == "content_filter":
                raise
            self.mode = "chain"
            print(f"conversations aren't supported on the agent endpoint (HTTP {status}); "
                  "chaining with previous_response_id", file=sys.stderr)
        return self

    def create_response(self, input):
        if self.mode is None:
            raise RuntimeError("start() first")
        kwargs: dict[str, Any] = {"input": input, "include": self._include}
        if self.mode == "conversation":
            kwargs["conversation"] = self.conversation_id
        elif self._previous_response_id is not None:
            kwargs["previous_response_id"] = self._previous_response_id
        response = self._openai.responses.create(**kwargs)
        if self.mode == "chain":
            if self._first_response_id is None:
                self._first_response_id = response.id
            self._previous_response_id = response.id
        return response

    def audit_id(self) -> str:
        """The ID audit rows carry as conversation_id: the conversation, or the turn's first response."""
        value = self.conversation_id if self.mode == "conversation" else self._first_response_id
        if not value:
            raise RuntimeError("no conversation or response ID yet")
        return value
