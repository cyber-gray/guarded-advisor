"""Offline tests for the gateway fixes (infra/apim.bicep, infra/policies/apim/*.xml, the OpenAPI definition). No Azure
calls. The compiled-template test runs `az bicep build` locally when az is installed (it makes no Azure call) and is
skipped otherwise.

    python3 -I -m unittest discover -s agent/tests -p 'test_apim_gateway.py' -v
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tooling import have_bash, have_jq  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
INFRA = ROOT / "infra"
GLOBAL = INFRA / "policies" / "apim" / "global.xml"
API_POLICY = INFRA / "policies" / "apim" / "foundry-api.xml"
SPEC = INFRA / "apim" / "foundry-openai-v1-chat.openapi.json"
BICEP = (INFRA / "apim.bicep").read_text(encoding="utf-8")
PARAMS = (INFRA / "apim.bicepparam").read_text(encoding="utf-8")
GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
OPENAI_USER = "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
COGNITIVE_SERVICES_USER = "a97b65f3-24c7-4388-baec-2e87135dc908"


def inbound(path: Path) -> list[ET.Element]:
    return list(ET.parse(path).getroot().find("inbound"))


def allowed(allowlist: str, oid: str | None) -> bool:
    """Python mirror of the global policy's condition (negated): tests the logic, not the APIM runtime."""
    claim = (oid if oid is not None else "-").lower()
    return ("," + allowlist + ",").find("," + claim + ",") >= 0


class GlobalPolicy(unittest.TestCase):
    def test_inbound_order(self):
        tags = [e.tag for e in inbound(GLOBAL)]
        self.assertEqual(tags, ["ip-filter", "validate-azure-ad-token", "choose", "llm-token-limit",
                                "llm-content-safety"])

    def test_token_is_kept_for_the_caller_check(self):
        validate = inbound(GLOBAL)[1]
        self.assertEqual(validate.get("output-token-variable-name"), "ga-caller-jwt")
        self.assertEqual(validate.get("failed-validation-httpcode"), "401")

    def test_unlisted_callers_get_403(self):
        choose = inbound(GLOBAL)[2]
        when = choose.find("when")
        condition = when.get("condition")
        for part in ["{{ga-gateway-allowed-oids}}", 'GetValueOrDefault<Jwt>("ga-caller-jwt")',
                     'Claims.GetValueOrDefault("oid", "-")', "ToLowerInvariant()", "!("]:
            self.assertIn(part, condition)
        status = when.find("return-response/set-status")
        self.assertEqual((status.get("code"), status.get("reason")), ("403", "Forbidden"))

    def test_allowlist_logic(self):
        t, birch = "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"
        allow = t
        self.assertTrue(allowed(allow, t))
        self.assertTrue(allowed(allow, t.upper()))
        self.assertFalse(allowed(allow, birch))
        self.assertFalse(allowed(allow, t[:-1]))           # a prefix of an allowed oid isn't enough
        self.assertFalse(allowed(allow, t + "0"))
        self.assertFalse(allowed(allow, None))              # no oid claim: the "-" default never matches
        self.assertFalse(allowed(allow, ""))
        self.assertTrue(allowed(f"{birch},{t}", t))
        self.assertFalse(allowed("", t))

    def test_bicep_normalises_the_allowlist(self):
        self.assertIn("var allowedOids = toLower(replace(gatewayAllowedOids, ' ', ''))", BICEP)


class ApiPolicyAndSpec(unittest.TestCase):
    def test_api_policy_routes_to_the_foundry_backend(self):
        root = ET.parse(API_POLICY).getroot()
        for section in ("inbound", "backend", "outbound", "on-error"):
            self.assertIsNotNone(root.find(f"{section}/base"), section)
        self.assertEqual(root.find("inbound/set-backend-service").get("backend-id"), "ga-foundry")

    def test_spec_has_one_operation(self):
        spec = json.loads(SPEC.read_text(encoding="utf-8"))
        self.assertEqual(list(spec["paths"]), ["/chat/completions"])
        self.assertEqual(list(spec["paths"]["/chat/completions"]), ["post"])
        self.assertEqual(spec["servers"][0]["url"], "https://{foundry-host}/openai/v1")
        req = spec["components"]["schemas"]["CreateChatCompletionRequest"]
        self.assertEqual(set(req["required"]), {"model", "messages"})
        self.assertIn("usage", spec["components"]["schemas"]["CreateChatCompletionResponse"]["properties"])


class TemplateSource(unittest.TestCase):
    def test_roles(self):
        self.assertIn(f"var cognitiveServicesOpenAiUserRoleId = '{OPENAI_USER}'", BICEP)
        foundry_role = BICEP[BICEP.index("resource foundryOpenAiUser"):BICEP.index("resource foundryBackend")]
        self.assertIn("scope: foundry", foundry_role)
        self.assertIn("cognitiveServicesOpenAiUserRoleId", foundry_role)
        self.assertNotIn("cognitiveServicesUserRoleId", foundry_role)

    def test_backend_credentials_are_in_the_template(self):
        lines = BICEP.splitlines()
        idx = [i for i, line in enumerate(lines) if line.strip().startswith("managedIdentity:")]
        self.assertEqual(len(idx), 2)
        for i in idx:
            self.assertEqual(lines[i - 1].strip(), "#disable-next-line BCP037")
        # Content Safety: fixed audience (Learn's llm-content-safety prerequisites); Foundry: the parameter.
        self.assertEqual([lines[i + 1].strip() for i in idx],
                         ["resource: cognitiveServicesResource", "resource: foundryBackendResource"])
        self.assertIn("var cognitiveServicesResource = 'https://cognitiveservices.azure.com'", BICEP)

    def test_api_subscriptions_and_master(self):
        api = BICEP[BICEP.index("resource foundryApi "):BICEP.index("resource foundryApiPolicy")]
        for part in ["format: 'openapi+json'", "path: 'foundry/openai/v1'", "header: 'api-key'",
                     "subscriptionRequired: true", "'{foundry-host}', foundryHost"]:
            self.assertIn(part, api)
        self.assertIn("scope: '/apis/${foundryApi.name}'", BICEP)
        # 'master' with scope '/' passed what-if and failed at deploy (2026-11-13): it's no longer in the template.
        code = "\n".join(line for line in BICEP.splitlines() if not line.lstrip().startswith("//"))
        self.assertNotIn("name: 'master'", code)
        self.assertNotIn("scope: '/'", code)
        self.assertNotIn("suspendMasterSubscription", code)
        self.assertNotIn("Inference, proven at what-if: a PUT on the built-in 'master'", BICEP)
        self.assertIn("scripts/apim_suspend_master.sh", BICEP)

    def test_master_is_suspended_by_the_script_without_storing_keys(self):
        script = (ROOT / "scripts" / "apim_suspend_master.sh").read_text(encoding="utf-8")
        self.assertIn('--headers "If-Match=*"', script)
        self.assertIn("""--body '{"properties":{"state":"suspended"}}'""", script)
        self.assertIn("subscriptions/master?api-version=$API_VERSION", script)
        self.assertIn("API_VERSION=2024-05-01", script)
        patch = next(line for line in script.splitlines() if "--method patch" in line)
        nxt = script.splitlines()[script.splitlines().index(patch) + 1]
        # The PATCH response holds both keys: piped straight into jq for the state, never redirected to a file.
        self.assertNotIn(">", patch + nxt)
        self.assertNotIn("tee", patch + nxt)
        self.assertIn("jq -r '.properties.state'", nxt)
        self.assertEqual(script.count("--method patch"), 1)
        self.assertLess(script.index("read -r -p"), script.index("--method patch"))   # asks first
        self.assertLess(script.index("--method patch"), script.rindex("--method get"))  # GET read-back after
        # A failed command stops with one fixed line (Tooni, 2026-11-14), set before any az call.
        self.assertIn("set -Eeuo pipefail", script)
        self.assertIn("""on_err() { echo "STOP: a command failed; master state unknown; don't open the gateway"; }""",
                      script)
        self.assertLess(script.index("trap on_err ERR"), script.index("az account show"))

    @unittest.skipUnless(have_bash() and have_jq(), "bash and jq not available")
    def test_master_script_stops_on_a_failed_read_without_patching(self):
        """Against a stub az in a throwaway HOME: the GET of master fails, so the trap prints its STOP line, the exit
        code is non-zero and no PATCH is sent."""
        stub = r'''#!/bin/sh
echo "$*" >>"$HOME/calls.txt"
case "$*" in
  "account show"*) echo "$SUB" ;;
  "ad signed-in-user show"*) echo "6d4c0000-0000-0000-0000-000000002a4d" ;;
  "apim list"*) echo "ga-apim-lab-test00" ;;
  "rest --method get"*) echo "ERROR: (ResourceNotFound) stub" >&2; exit 3 ;;
  *) echo "unexpected az call: $*" >&2; exit 9 ;;
esac
'''
        sub = "00000000-0000-0000-0000-000000000000"
        with tempfile.TemporaryDirectory() as home:
            h = Path(home)
            (h / "bin").mkdir()
            (h / "bin" / "az").write_text(stub)
            (h / "bin" / "az").chmod(0o755)
            p1 = h / "guarded-advisor-private" / "pim-2026-11"
            p1.mkdir(parents=True)
            (p1 / "p1-t-and-g.json").write_text(json.dumps([{"roleDefinitionName": "Owner", "scope": f"/subscriptions/{sub}"}]))
            env = {"PATH": f"{h / 'bin'}:/usr/bin:/bin", "HOME": home, "SUB": sub}
            proc = subprocess.run(["bash", str(ROOT / "scripts" / "apim_suspend_master.sh")], capture_output=True,
                                  text=True, env=env, timeout=60, stdin=subprocess.DEVNULL)
            calls = (h / "calls.txt").read_text()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("STOP: a command failed; master state unknown; don't open the gateway", proc.stdout)
        self.assertNotIn("ok | master suspended", proc.stdout)
        self.assertIn("rest --method get", calls)
        self.assertNotIn("--method patch", calls)

    def test_foundry_backend_audience_is_a_parameter_with_the_fallback(self):
        self.assertIn("param foundryBackendResource string = 'https://cognitiveservices.azure.com'", BICEP)
        allowed = BICEP[BICEP.index("@allowed(["):BICEP.index("param foundryBackendResource")]
        self.assertIn("'https://ai.azure.com/'", allowed)
        backend = BICEP[BICEP.index("resource foundryBackend"):BICEP.index("// 6. Named values")]
        self.assertIn("resource: foundryBackendResource", backend)
        self.assertIn("readEnvironmentVariable('GA_FOUNDRY_BACKEND_RESOURCE', 'https://cognitiveservices.azure.com')",
                      PARAMS)

    def test_llm_message_logging_is_off_by_default(self):
        self.assertIn("param logLlmMessages bool = false", BICEP)
        self.assertIn("bool(readEnvironmentVariable('GA_LOG_LLM_MESSAGES', 'false'))", PARAMS)
        diag = BICEP[BICEP.index("resource foundryApiDiagnostic"):BICEP.index("// 8. Subscriptions")]
        self.assertIn("service/apis/diagnostics@2024-06-01-preview", diag)
        self.assertIn("largeLanguageModel: logLlmMessages ? {", diag)
        when_on, when_off = diag.split("} : {", 1)
        self.assertIn("requests: llmMessageSettings", when_on)
        self.assertIn("responses: llmMessageSettings", when_on)
        self.assertIn("logs: 'enabled'", when_off.split("}", 1)[0])
        self.assertNotIn("requests", when_off.split("}", 1)[0])

    def test_no_portal_gateway_flow_and_no_ids_in_params(self):
        self.assertIn("param gatewayAllowedOids string\n", BICEP)  # no default
        self.assertIn("readEnvironmentVariable('GA_GATEWAY_ALLOWED_OIDS')", PARAMS)
        self.assertIsNone(GUID.search(PARAMS))


@unittest.skipUnless(shutil.which("az"), "az not installed")
class CompiledTemplate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        out = subprocess.run(["az", "bicep", "build", "--file", str(INFRA / "apim.bicep"), "--stdout"],
                             capture_output=True, text=True, timeout=180)
        if out.returncode != 0:
            raise AssertionError(out.stderr)
        cls.template = json.loads(out.stdout)
        cls.by_type = {}
        for r in cls.template["resources"]:
            cls.by_type.setdefault(r["type"], []).append(r)

    def test_backends_carry_managed_identity(self):
        backends = {("foundry" if "ga-foundry" in b["name"] else "cs"): b
                    for b in self.by_type["Microsoft.ApiManagement/service/backends"]}
        self.assertEqual(set(backends), {"foundry", "cs"})
        self.assertEqual(backends["cs"]["properties"]["credentials"]["managedIdentity"]["resource"],
                         "[variables('cognitiveServicesResource')]")
        self.assertEqual(backends["foundry"]["properties"]["credentials"]["managedIdentity"]["resource"],
                         "[parameters('foundryBackendResource')]")

    def test_role_assignments(self):
        roles = sorted(r["properties"]["roleDefinitionId"] for r in
                       self.by_type["Microsoft.Authorization/roleAssignments"])
        self.assertEqual(len(roles), 2)
        self.assertIn("cognitiveServicesOpenAiUserRoleId", " ".join(roles))
        self.assertEqual(self.template["variables"]["cognitiveServicesOpenAiUserRoleId"], OPENAI_USER)
        self.assertEqual(self.template["variables"]["cognitiveServicesUserRoleId"], COGNITIVE_SERVICES_USER)

    def test_api_diagnostic_and_backend_parameter(self):
        diag = self.by_type["Microsoft.ApiManagement/service/apis/diagnostics"][0]
        self.assertEqual(diag["apiVersion"], "2024-06-01-preview")
        self.assertIn("parameters('logLlmMessages')", diag["properties"]["largeLanguageModel"])
        self.assertEqual(self.template["parameters"]["logLlmMessages"]["defaultValue"], False)
        self.assertEqual(self.template["parameters"]["foundryBackendResource"]["allowedValues"],
                         ["https://cognitiveservices.azure.com", "https://ai.azure.com/"])

    def test_subscriptions(self):
        subs = {r["name"].split("'")[-2] if "'" in r["name"] else r["name"]: r for r in
                self.by_type["Microsoft.ApiManagement/service/subscriptions"]}
        states = sorted(r["properties"]["state"] for r in subs.values())
        self.assertEqual(states, ["active"])   # the harness only; master is suspended by scripts/apim_suspend_master.sh


if __name__ == "__main__":
    unittest.main()
