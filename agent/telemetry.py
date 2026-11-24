"""Client-side tracing to Application Insights, metadata only (C5, C6; decision D-020).

Learn (https://learn.microsoft.com/azure/foundry/observability/how-to/trace-agent-client-side, updated 2026-09-11):
- GenAI tracing is opt-in: AZURE_EXPERIMENTAL_ENABLE_GENAI_TRACING=true before AIProjectInstrumentor().instrument().
- Message content and tool-call arguments are captured only if OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT is true
  (default false). The enable_content_recording parameter takes priority over the variable, so it's passed as False
  explicitly: content stays out of traces even if the variable is set in the shell.
- Baggage propagation stays off (it can carry user data to Azure services).
Turning content recording on, even for debugging, is a separate decision.

Where the connection string comes from (findings, 2026-11-10, M1 to M4):
1. APPLICATIONINSIGHTS_CONNECTION_STRING, if set: configure_azure_monitor() reads it itself when no connection_string is
   passed (https://learn.microsoft.com/python/api/overview/azure/monitor-opentelemetry-readme?view=azure-python#getting-started).
2. Otherwise the project's connections. Listing them needs connections/read, which Foundry Agent Consumer doesn't have
   (https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning#foundry-agent-consumer).
   If the caller is denied (ClientAuthenticationError, or HttpResponseError with status 403), telemetry stays off with
   one line on stderr and the run continues. Any other error still raises.
The connection string is never printed.
"""
from __future__ import annotations

import os
import sys

CONNECTION_STRING_VAR = "APPLICATIONINSIGHTS_CONNECTION_STRING"
OFF_MESSAGE = ("telemetry: off (no connections/read for this identity; "
               "set APPLICATIONINSIGHTS_CONNECTION_STRING to enable)")


def configure(project_client) -> None:
    os.environ["AZURE_EXPERIMENTAL_ENABLE_GENAI_TRACING"] = "true"
    os.environ["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "false"

    from azure.ai.projects.telemetry import AIProjectInstrumentor
    from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
    from azure.monitor.opentelemetry import configure_azure_monitor

    if os.environ.get(CONNECTION_STRING_VAR):
        configure_azure_monitor()
    else:
        try:
            connection_string = project_client.telemetry.get_application_insights_connection_string()
        except HttpResponseError as exc:
            if isinstance(exc, ClientAuthenticationError) or exc.status_code == 403:
                print(OFF_MESSAGE, file=sys.stderr)
                return
            raise
        configure_azure_monitor(connection_string=connection_string)
    AIProjectInstrumentor().instrument(enable_content_recording=False, enable_baggage_propagation=False)
