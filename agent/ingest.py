"""Logs Ingestion API sink for the custom tables (w2-custom, D-022; C2, C4, C6, C8).

One stream per sink. The endpoint and DCR immutable ID come from operator settings (custom-tables.bicep outputs);
they aren't secrets, and access is decided by Monitoring Metrics Publisher on the DCR.
- Agent evidence (AgentToolAudit_CL, AdjudicationLog_CL): the DCE endpoint, reachable only through the lab AMPLS,
  with the jumpbox managed identity.
- Red-team ground truth (RedTeamRun_CL): the red-team DCR's own endpoint, from the laptop.
The DCR passes only declared columns, so a field that isn't in the schema never reaches the workspace.
Client: azure-monitor-ingestion, https://learn.microsoft.com/python/api/overview/azure/monitor-ingestion-readme
"""
from __future__ import annotations

from urllib.parse import urlparse

AUDIT_STREAM = "Custom-AgentToolAudit_CL"
ADJUDICATION_STREAM = "Custom-AdjudicationLog_CL"
REDTEAM_STREAM = "Custom-RedTeamRun_CL"
STREAMS = (AUDIT_STREAM, ADJUDICATION_STREAM, REDTEAM_STREAM)


class IngestionError(RuntimeError):
    """An upload didn't succeed. The caller decides what that means (the audit log fails closed on allows)."""


def check_endpoint(endpoint: str) -> str:
    """Only Azure Monitor ingestion hosts: a misconfigured setting must not send rows anywhere else."""
    url = urlparse(endpoint or "")
    if url.scheme != "https" or not (url.hostname or "").endswith(".ingest.monitor.azure.com"):
        raise ValueError("ingestion endpoint must be https://<name>.<region>-1.ingest.monitor.azure.com")
    return endpoint


class IngestionSink:
    def __init__(self, endpoint: str, rule_id: str, stream: str, credential=None, *, client=None):
        if stream not in STREAMS:
            raise ValueError(f"unknown stream {stream!r}")
        if not (rule_id or "").startswith("dcr-"):
            raise ValueError("rule_id must be the DCR immutable ID (dcr-...)")
        self.stream = stream
        self._rule_id = rule_id
        if client is None:
            from azure.monitor.ingestion import LogsIngestionClient
            # Short timeouts and few retries: an allowed read waits for its audit row (fail closed), so a dead path
            # should fail in seconds, not minutes.
            client = LogsIngestionClient(endpoint=check_endpoint(endpoint), credential=credential,
                                         retry_total=2, connection_timeout=5, read_timeout=15)
        self._client = client

    def send(self, rows: list[dict]) -> None:
        try:
            self._client.upload(rule_id=self._rule_id, stream_name=self.stream, logs=rows)
        except Exception as exc:  # any failure, including auth and network, is the same outcome for the caller
            raise IngestionError(f"{type(exc).__name__}: {str(exc)[:200]}") from exc
