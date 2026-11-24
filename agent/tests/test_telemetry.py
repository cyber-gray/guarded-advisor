"""Unit tests for agent/telemetry.py: telemetry is optional when the caller can't read project connections
(findings, 2026-11-10, M1 to M4). No Azure calls: the Azure Monitor and Foundry SDK modules are stubbed.

    python3 -I -m unittest discover -s agent/tests -p 'test_telemetry.py' -v

Needs azure-core (for the real exception types); skipped, with a message, if it isn't installed.
"""
from __future__ import annotations

import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import mock

AGENT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(AGENT))

import telemetry  # noqa: E402

try:
    from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
except ImportError:  # pragma: no cover
    ClientAuthenticationError = HttpResponseError = None

FAKE_CONNECTION_STRING = "InstrumentationKey=not-a-real-key;IngestionEndpoint=https://example.invalid/"


def http_error(status):
    exc = HttpResponseError(message=f"stub {status}")
    exc.status_code = status
    return exc


@unittest.skipIf(HttpResponseError is None, "azure-core isn't installed")
class ConfigureTelemetry(unittest.TestCase):
    def setUp(self):
        self.configure_azure_monitor = mock.MagicMock(name="configure_azure_monitor")
        self.instrumentor = mock.MagicMock(name="AIProjectInstrumentor")
        monitor = ModuleType("azure.monitor.opentelemetry")
        monitor.configure_azure_monitor = self.configure_azure_monitor
        projects_telemetry = ModuleType("azure.ai.projects.telemetry")
        projects_telemetry.AIProjectInstrumentor = self.instrumentor
        stubs = {
            "azure.monitor": ModuleType("azure.monitor"),
            "azure.monitor.opentelemetry": monitor,
            "azure.ai": ModuleType("azure.ai"),
            "azure.ai.projects": ModuleType("azure.ai.projects"),
            "azure.ai.projects.telemetry": projects_telemetry,
        }
        patches = [mock.patch.dict(sys.modules, stubs), mock.patch.dict(os.environ, {}, clear=False)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop(telemetry.CONNECTION_STRING_VAR, None)
        self.listing = mock.MagicMock(name="get_application_insights_connection_string")
        self.project = SimpleNamespace(telemetry=SimpleNamespace(get_application_insights_connection_string=self.listing))

    def run_configure(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            telemetry.configure(self.project)
        return out.getvalue(), err.getvalue()

    def test_env_set_uses_env_and_skips_listing(self):
        os.environ[telemetry.CONNECTION_STRING_VAR] = FAKE_CONNECTION_STRING
        out, err = self.run_configure()
        self.configure_azure_monitor.assert_called_once_with()  # reads the variable itself
        self.listing.assert_not_called()
        self.instrumentor.return_value.instrument.assert_called_once_with(
            enable_content_recording=False, enable_baggage_propagation=False)
        self.assertNotIn(FAKE_CONNECTION_STRING, out + err)
        self.assertEqual(out + err, "")

    def test_env_unset_listing_ok_passes_string(self):
        self.listing.return_value = FAKE_CONNECTION_STRING
        out, err = self.run_configure()
        self.listing.assert_called_once_with()
        self.configure_azure_monitor.assert_called_once_with(connection_string=FAKE_CONNECTION_STRING)
        self.instrumentor.return_value.instrument.assert_called_once()
        self.assertEqual(out + err, "")

    def test_env_unset_denied_turns_telemetry_off(self):
        for name, exc in (("403", http_error(403)),
                          ("ClientAuthenticationError", ClientAuthenticationError(message="stub denied"))):
            with self.subTest(name):
                self.listing.reset_mock()
                self.configure_azure_monitor.reset_mock()
                self.instrumentor.reset_mock()
                self.listing.side_effect = exc
                out, err = self.run_configure()  # no exception
                self.assertEqual(err, telemetry.OFF_MESSAGE + "\n")
                self.assertEqual(out, "")
                self.configure_azure_monitor.assert_not_called()
                self.instrumentor.assert_not_called()

    def test_env_unset_other_errors_raise(self):
        for name, exc in (("500", http_error(500)), ("ValueError", ValueError("stub"))):
            with self.subTest(name):
                self.listing.side_effect = exc
                with self.assertRaises(type(exc)):
                    self.run_configure()
                self.configure_azure_monitor.assert_not_called()

    def test_empty_env_counts_as_unset(self):
        os.environ[telemetry.CONNECTION_STRING_VAR] = ""
        self.listing.return_value = FAKE_CONNECTION_STRING
        self.run_configure()
        self.listing.assert_called_once_with()
        self.configure_azure_monitor.assert_called_once_with(connection_string=FAKE_CONNECTION_STRING)


if __name__ == "__main__":
    unittest.main()
