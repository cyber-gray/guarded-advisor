#!/usr/bin/env python3
"""Gateway harness (w2-policies, w2-bypass; C3, C6). Runs the cases in redteam/payloads/gateway-cases.json against the
API Management gateway, or straight to the Foundry model endpoint for the bypass cases, and records only status,
the blocking layer and the gateway's or service's error message. It never records model output text.

Run on the jumpbox, signed in with `az login` as the caller named in --caller-label:

    .venv\\Scripts\\python -I redteam\\gateway_harness.py [--gateway-url <APIM chat completions URL>] ^
        --direct-url <Foundry chat completions URL> --subscription-key-env GA_APIM_KEY ^
        --subscription-key-header <the API's subscriptionKeyParameterNames.header, e.g. api-key> ^
        --caller-label T --out <private path>\\gw-20261112.jsonl --date 20261112

- Standard library plus azure-identity (already in .venv). The token is for https://cognitiveservices.azure.com, the
  audience the global policy validates (infra/policies/apim/global.xml).
- The APIM subscription key is read from the environment variable named by --subscription-key-env and never printed.
- Every request carries x-redteam-id GW-<case>-<date>, so results join to ApiManagementGatewayLogs and LLM logs.
- Error messages are masked before they're stored or printed: GUIDs, email-shaped names (UPNs) and IPv4 addresses.
- GW-T1 always runs last, after a pause (default 60 s), so earlier cases don't count against the token limit.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent"))

from untrusted import CLOSE, OPEN, wrap  # noqa: E402

CASES_FILE = ROOT / "redteam" / "payloads" / "gateway-cases.json"
DOCUMENTS = ROOT / "redteam" / "payloads" / "documents"
DOCUMENT_SOURCES = {"header-free": DOCUMENTS, "full": ROOT / "redteam" / "payloads"}
SCOPE = "https://cognitiveservices.azure.com/.default"
# The model API infra/apim.bicep imports (path foundry/openai/v1), on the instance name the template derives for the lab
# resource group (ga-apim-lab-v3doqe on 2026-11-12). The 11-12 portal flow's API used /ga-ai-labv3do/openai/v1 instead.
GATEWAY_API_PATH = "/foundry/openai/v1/chat/completions"
DEFAULT_GATEWAY_URL = "https://ga-apim-lab-v3doqe.azure-api.net" + GATEWAY_API_PATH
KEY_HEADER = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")  # RFC 9110 token
BIRCH_CASES = ("GW-X1a", "GW-X1b", "GW-X2")  # need birch signed in under a stated role; run only with --cases
FILLER = ("Larkfield Mutual (fictional) background for a synthetic exercise: the member works shifts in a warehouse, "
          "lifts boxes up to 20 kg, and the treating provider recommends modified duties with no lifting over 5 kg "
          "for four weeks, then a gradual increase. ")
_GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_EMAIL = re.compile(r"[A-Za-z0-9._%+#-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_IPV4 = re.compile(r"\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b")


def mask(text: str) -> str:
    text = _GUID.sub(lambda m: m.group()[:4] + "..." + m.group()[-4:], text)
    text = _EMAIL.sub("<upn>", text)
    return _IPV4.sub(lambda m: f"{m.group(1)}.{m.group(2)}.x.x", text)


def load_cases(path: Path = CASES_FILE) -> list[dict]:
    cases = json.loads(path.read_text(encoding="utf-8"))["cases"]
    ids = [c["id"] for c in cases]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate case IDs")
    return cases


def ordered(cases: list[dict], selected: list[str] | None) -> list[dict]:
    """The selected cases in file order, with GW-T1 moved to the end."""
    chosen = [c for c in cases if selected is None or c["id"] in selected]
    if selected is not None:
        missing = set(selected) - {c["id"] for c in chosen}
        if missing:
            raise ValueError(f"unknown case IDs: {sorted(missing)}")
    return [c for c in chosen if c["kind"] != "token_limit"] + [c for c in chosen if c["kind"] == "token_limit"]


def default_selection(cases: list[dict]) -> list[str]:
    """Every case except GW-X1a, GW-X1b and GW-X2, which need birch signed in under a stated role, and the C3-2a
    analysis cases (kind "analysis"), which run on their own with --cases."""
    return [c["id"] for c in cases if c["id"] not in BIRCH_CASES and c["kind"] != "analysis"]


def prompt_for(case: dict, limit: int | None = None) -> str:
    """The user message. Document options (C3-2a analysis, 2026-11-12):
    - document_source: "header-free" (default, payloads/documents/) or "full" (payloads/, with the # header lines);
    - wrap: put the document inside the delimiter;
    - escape (default true): fix A's JSON escaping; false writes the text raw inside the delimiter, as the 11-11 C3-1
      messages were (878 characters for A4);
    - apply_limit (default true): the client's max_message_chars; false for analysis cases that exceed it."""
    text = case["prompt"]
    if "document" in case:
        source = case.get("document_source", "header-free")
        if source not in DOCUMENT_SOURCES:
            raise ValueError(f"{case['id']}: document_source must be one of {sorted(DOCUMENT_SOURCES)}")
        doc = (DOCUMENT_SOURCES[source] / case["document"]).read_text(encoding="utf-8")
        if not case.get("wrap"):
            text = f"{text} {doc}"
        elif case.get("escape", True):
            text = wrap(text, [doc], max_chars=limit if case.get("apply_limit", True) else None)
        else:
            text = f"{text} {OPEN}\n{doc}\n{CLOSE}"
    if case.get("filler_chars"):
        reps = case["filler_chars"] // len(FILLER) + 1
        text = f"{text}\n\n{(FILLER * reps)[:case['filler_chars']]}"
    return text


def body_for(case: dict, deployment: str, prompt: str) -> dict:
    body = {"model": deployment, "messages": [{"role": "user", "content": prompt}]}
    body["max_tokens"] = case.get("max_tokens", 300)
    return body


def classify(status: int, payload: dict | None, target: str) -> tuple[str, str, str]:
    """(layer, error code, masked error message). Never reads model output text."""
    payload = payload if isinstance(payload, dict) else {}
    err = payload.get("error") if isinstance(payload.get("error"), dict) else {}
    code = str(err.get("code") or payload.get("statusCode") or "")
    message = mask(str(err.get("message") or payload.get("message") or ""))[:300]
    if status == 200:
        return "allowed", "", ""
    if status == 400 and (code == "content_filter" or "content_filter" in json.dumps(err)):
        return "guardrail", code or "content_filter", message
    if status == 429:
        return "token_limit", code, message
    if status == 401:
        # Foundry's direct endpoint answers a valid token without the data action with 401 PermissionDenied
        # (observed 2026-11-12, GW-X1): that's an authorization refusal, not a failed sign-in.
        if target == "direct" and code == "PermissionDenied":
            return "forbidden", code, message
        return "auth", code, message
    if status == 403:
        return ("apim_block" if target == "gateway" else "forbidden"), code, message
    return "other", code, message


def filtered_categories(payload: dict | None) -> list[str]:
    """Names of guardrail filters that fired, from the error's content filter result (no text)."""
    try:
        result = payload["error"]["innererror"]["content_filter_result"]
    except (KeyError, TypeError):
        return []
    return sorted(k for k, v in result.items() if isinstance(v, dict) and (v.get("filtered") or v.get("detected")))


Transport = Callable[[str, dict, bytes], tuple[int, dict, bytes]]


def urllib_transport(url: str, headers: dict, data: bytes) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:  # noqa: S310 (fixed https URLs from the operator)
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read()


def call(case: dict, *, url: str, token: str, key: str | None, key_header: str, redteam_id: str, deployment: str,
         prompt: str, transport: Transport) -> dict:
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "x-redteam-id": redteam_id}
    if key:
        headers[key_header] = key
    start = time.monotonic()
    status, resp_headers, raw = transport(url, headers, json.dumps(body_for(case, deployment, prompt)).encode())
    elapsed = int((time.monotonic() - start) * 1000)
    try:
        payload = json.loads(raw.decode("utf-8")) if raw else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = None
    layer, code, message = classify(status, payload, case["target"])
    usage = payload.get("usage", {}) if isinstance(payload, dict) and status == 200 else {}
    lower = {k.lower(): v for k, v in resp_headers.items()}
    return {
        "case": case["id"], "redteam_id": redteam_id, "target": case["target"], "status": status, "layer": layer,
        "error_code": code, "error_message": message, "filters": filtered_categories(payload),
        "latency_ms": elapsed, "prompt_chars": len(prompt),
        "total_tokens": usage.get("total_tokens"), "retry_after": lower.get("retry-after"),
        "remaining_tokens": lower.get("x-ga-remaining-tokens"),
    }


def check_out_path(out: Path) -> str | None:
    resolved = out.expanduser().resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        return "--out is inside the repository; results go to a private path"
    if resolved.exists():
        return "--out already exists; choose a new file"
    return None


def check_key_header(name: str) -> str | None:
    """The header must be a plain HTTP token (RFC 9110 field name), and Authorization is already in use."""
    if not KEY_HEADER.fullmatch(name or ""):
        return f"--subscription-key-header {name!r} isn't a valid header name"
    if name.lower() in ("authorization", "content-type", "x-redteam-id"):
        return f"--subscription-key-header can't be {name}"
    return None


def run(cases: list[dict], *, gateway_url: str | None, direct_url: str | None, token: str, key: str | None,
        key_header: str, caller: str, date: str, deployment: str, limit: int, transport: Transport,
        sleep: Callable[[float], None] = time.sleep, pause: float = 60.0) -> list[dict]:
    reason = check_key_header(key_header)
    if reason:
        raise ValueError(reason)
    rows = []
    for case in cases:
        url = gateway_url if case["target"] == "gateway" else direct_url
        if not url:
            raise ValueError(f"{case['id']} needs --{'gateway' if case['target'] == 'gateway' else 'direct'}-url")
        rid = f"{case['id']}-{date}"
        common = dict(url=url, token=token, key=key if case["target"] == "gateway" else None, key_header=key_header,
                      deployment=deployment, transport=transport)
        if case["kind"] == "token_limit":
            # Call 1 spends the budget (expected to pass); call 2 is short and should hit the limit.
            sleep(pause)
            first = call(case, redteam_id=f"{rid}-1", prompt=prompt_for(case, limit), **common)
            second = call(dict(case, max_tokens=20), redteam_id=f"{rid}-2", prompt="Reply with the single word OK.",
                          **common)
            new = [(first, ["allowed"]), (second, case["expect"])]
        else:
            # repeat: the same message several times (the 11-11 C3-1 result was 3 of 3); pause_before: seconds before
            # each call, so a run of analysis calls stays under the gateway's token limit.
            repeat = int(case.get("repeat", 1))
            new = []
            for n in range(1, repeat + 1):
                if case.get("pause_before"):
                    sleep(float(case["pause_before"]))
                new.append((call(case, redteam_id=rid if repeat == 1 else f"{rid}-{n}", prompt=prompt_for(case, limit),
                                 **common), case["expect"]))
        for row, expected in new:
            row.update(caller=caller, expected=expected, as_expected=row["layer"] in expected)
            rows.append(row)
    return rows


def summary(rows: list[dict]) -> str:
    lines = ["case | id | status | layer | expected | ok | error code | message"]
    for r in rows:
        lines.append(f"{r['case']} | {r['redteam_id']} | {r['status']} | {r['layer']} | {'/'.join(r['expected'])} | "
                     f"{'ok' if r['as_expected'] else 'MISMATCH'} | {r['error_code']} | {r['error_message'][:120]}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Gateway harness (synthetic cases; records no model text)")
    p.add_argument("--gateway-url", default=DEFAULT_GATEWAY_URL,
                   help=f"APIM chat completions URL (default {DEFAULT_GATEWAY_URL})")
    p.add_argument("--direct-url", help="Foundry chat completions URL, for the GW-X1 bypass cases")
    p.add_argument("--subscription-key-env", default="GA_APIM_KEY", help="env var holding the APIM subscription key")
    p.add_argument("--subscription-key-header", required=True,
                   help="header the gateway API reads the key from: its subscriptionKeyParameterNames.header (the API "
                        "the Foundry AI Gateway created uses api-key, not APIM's default Ocp-Apim-Subscription-Key)")
    p.add_argument("--deployment", default="gpt-4.1-mini")
    p.add_argument("--caller-label", required=True, help="who is signed in: T, alder or birch (recorded per row)")
    p.add_argument("--cases", help="comma-separated case IDs; default all except GW-X1a, GW-X1b and GW-X2")
    p.add_argument("--date", required=True, help="YYYYMMDD label in each x-redteam-id")
    p.add_argument("--out", type=Path, required=True, help="results JSONL, outside the repository, new file")
    p.add_argument("--pause", type=float, default=60.0, help="seconds before GW-T1")
    args = p.parse_args(argv)
    if not re.fullmatch(r"20\d{6}", args.date):
        p.error("--date must be YYYYMMDD")
    reason = check_out_path(args.out) or check_key_header(args.subscription_key_header)
    if reason:
        print(f"STOP: {reason}", file=sys.stderr)
        return 2
    selected = args.cases.split(",") if args.cases else default_selection(load_cases())
    cases = ordered(load_cases(), selected)
    key = os.environ.get(args.subscription_key_env) or None
    if any(c["target"] == "gateway" for c in cases) and not key:
        print(f"STOP: {args.subscription_key_env} isn't set; gateway cases need the APIM subscription key", file=sys.stderr)
        return 2
    import pack
    limit = pack.load_config()["document_input"]["max_message_chars"]
    from azure.identity import AzureCliCredential
    token = AzureCliCredential().get_token(SCOPE).token
    rows = run(cases, gateway_url=args.gateway_url, direct_url=args.direct_url, token=token, key=key,
               key_header=args.subscription_key_header, caller=args.caller_label, date=args.date,
               deployment=args.deployment, limit=limit, transport=urllib_transport, pause=args.pause)
    with args.out.open("x", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print(summary(rows))
    print(f"\n{len(rows)} rows; {sum(not r['as_expected'] for r in rows)} mismatches; results: {args.out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
