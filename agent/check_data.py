#!/usr/bin/env python3
"""Checks the synthetic data in scenario pack `larkfield` (w1-data). Exits non-zero on any failure.

Run with: python3 -I agent/check_data.py

Checks:
  1. Determinism: two fresh generator runs produce identical files, identical to what's in the repo (no stale files).
  2. C2 partition: 30 unique claims, exactly 10 per case manager alias, no claim unassigned.
  3. entitlements.json (once built after G7b): keyed by object ID with the alias only; claims match claims.json.
  4. Canary: exactly one occurrence across data/, and it matches attacks/manifest.json.
  5. Rule 1: nothing shaped like a SIN, an Ontario health card, a Quebec RAMQ number, a phone number, a postal code
     or an email address; no date-of-birth fields; no tenant domain or UPN in any pack file.
  6. URLs: every host in data/ and attacks/ is an RFC 2606 reserved name, or the metadata address A10 probes.
  7. A4: pdftotext extracts every hidden instruction, and the raw PDF draws them in text render mode 3 (invisible).
"""
from __future__ import annotations

import filecmp
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACK = ROOT / "scenarios" / "larkfield"
GENERATOR = ROOT / "agent" / "generate_data.py"
GENERATED = ["data/claims.json", "data/submitted", "attacks"]  # paths the generator owns

failures = 0


def ok(msg: str) -> None:
    print(f"  PASS {msg}")


def bad(msg: str) -> None:
    global failures
    failures += 1
    print(f"  FAIL {msg}")


def files_under(base: Path, rels: list[str]) -> dict[str, str]:
    """Relative path -> sha256 for every file under the given generator-owned paths."""
    out = {}
    for rel in rels:
        p = base / rel
        for f in ([p] if p.is_file() else sorted(x for x in p.rglob("*") if x.is_file())):
            out[str(f.relative_to(base))] = hashlib.sha256(f.read_bytes()).hexdigest()
    return out


def check_determinism() -> None:
    print("1. Determinism (two runs, and the repo copy)")
    with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
        for t in (t1, t2):
            subprocess.run([sys.executable, "-I", str(GENERATOR), "--out", t], check=True, capture_output=True)
        run1, run2 = files_under(Path(t1), GENERATED), files_under(Path(t2), GENERATED)
        ok(f"run 1 and run 2 identical ({len(run1)} files)") if run1 == run2 else bad("two generator runs differ")
        repo = files_under(PACK, GENERATED)
        if repo == run1:
            ok("repo copy matches a fresh run (no stale or edited files)")
        else:
            changed = sorted(set(repo) ^ set(run1) | {k for k in set(repo) & set(run1) if repo[k] != run1[k]})
            bad(f"repo copy differs from a fresh run: {changed[:5]}{' ...' if len(changed) > 5 else ''}")


def text_of_pack() -> dict[str, str]:
    """Every text-bearing pack file, as text. PDFs are read raw (latin-1): the generator writes uncompressed streams."""
    out = {}
    for f in sorted(p for p in PACK.rglob("*") if p.is_file()):
        out[str(f.relative_to(PACK))] = f.read_bytes().decode("latin-1")
    return out


def main() -> None:
    check_determinism()

    claims = json.loads((PACK / "data" / "claims.json").read_text(encoding="utf-8"))["claims"]
    manifest = json.loads((PACK / "attacks" / "manifest.json").read_text(encoding="utf-8"))

    print("2. C2 partition")
    ids = [c["claim_id"] for c in claims]
    ok("30 unique claim IDs") if len(ids) == 30 and len(set(ids)) == 30 else bad(f"claim IDs: {len(ids)} total, {len(set(ids))} unique")
    by_alias: dict[str, list[str]] = {}
    for c in claims:
        by_alias.setdefault(c["case_manager"], []).append(c["claim_id"])
    sizes = {a: len(v) for a, v in sorted(by_alias.items())}
    ok(f"10 claims per case manager {sizes}") if sizes == {"alder": 10, "birch": 10, "cedar": 10} else bad(f"caseloads {sizes}")

    print("3. entitlements.json")
    ent_path = PACK / "entitlements.json"
    if not ent_path.exists():
        print("  SKIP not built yet (agent/build_entitlements.sh runs after the accounts exist, G7b)")
    else:
        ent = json.loads(ent_path.read_text(encoding="utf-8"))
        guid = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        loads = ent.get("caseloads", {})
        ok("keys are object IDs") if loads and all(guid.match(k) for k in loads) else bad("caseload keys aren't all object IDs")
        aliases = {v.get("alias"): sorted(v.get("claims", [])) for v in loads.values()}
        expected = {a: sorted(v) for a, v in by_alias.items()}
        ok("caseloads match claims.json") if aliases == expected else bad("caseloads differ from claims.json")
        ok("no UPNs") if "@" not in ent_path.read_text(encoding="utf-8") else bad("entitlements.json contains '@'")

    texts = text_of_pack()

    print("4. Canary")
    canary = manifest["canary"]["value"]
    hits = {path: t.count(canary) for path, t in texts.items() if path.startswith("data/") and canary in t}
    total = sum(hits.values())
    ok(f"{canary} appears once in data/ ({list(hits)[0]})") if total == 1 else bad(f"canary appears {total} times in data/: {hits}")
    owner = next((c for c in claims if any(canary in n["text"] for n in c["notes"])), None)
    ok("canary claim matches the manifest") if owner and owner["claim_id"] == manifest["canary"]["claim_id"] else bad("canary claim mismatch")

    print("5. Rule 1 patterns and tenant identifiers")
    patterns = {
        "SIN": r"(?<![\w-])\d{3}[- ]?\d{3}[- ]?\d{3}(?![\w-])",
        "Ontario health card": r"(?<!\w)\d{4}[- ]?\d{3}[- ]?\d{3}[- ]?[A-Z]{2}(?!\w)",
        "Quebec RAMQ": r"(?<!\w)[A-Z]{4}\d{8}(?!\w)",
        "phone number": r"(?<!\d)\(?\d{3}\)?[-. ]\d{3}[-. ]\d{4}(?!\d)",
        "postal code": r"(?<![A-Za-z0-9])[ABCEGHJ-NPRSTVXY]\d[A-Z] ?\d[A-Z]\d(?![A-Za-z0-9])",
        "email address": r"[\w.+-]+@[\w-]+\.[\w.-]+",
        "date of birth": r"(?i)date[_ ]of[_ ]birth|\bdob\b|birth_?date",
        "tenant domain": r"(?i)onmicrosoft\.com",
    }
    for label, rx in patterns.items():
        found = [(p, m.group(0)) for p, t in texts.items() for m in re.finditer(rx, t)]
        ok(f"no {label}") if not found else bad(f"{label}: {found[:3]}")

    print("6. URLs in data/ and attacks/ (RFC 2606 reserved names only)")
    # The governance records (intake-record.md, model-inventory.md) cite real regulators and Learn pages; the rule
    # applies to the synthetic data and the attack payloads.
    reserved = re.compile(r"(^|\.)(example|test|invalid|localhost)$|^(.+\.)?example\.(com|net|org)$")
    allowed_ip = {"169.254.169.254"}  # instance metadata address probed by A10 (manifest note)
    scoped = [t for p, t in texts.items() if p.startswith(("data/", "attacks/"))]
    hosts = sorted({m.group(1).lower() for t in scoped for m in re.finditer(r"https?://([^/\s\"',:)]+)", t)})
    bad_hosts = [h for h in hosts if not (reserved.search(h) or h in allowed_ip)]
    ok(f"hosts: {hosts}") if not bad_hosts else bad(f"non-reserved hosts: {bad_hosts}")

    print("7. A4 payload readable by an extractor")
    a4 = next(a for a in manifest["attacks"] if a["attack_id"] == "A4")
    pdf = PACK / "attacks" / a4["file"]
    if not shutil.which("pdftotext"):
        bad("pdftotext not found (Homebrew poppler)")
    else:
        extracted = subprocess.run(["pdftotext", "-layout", str(pdf), "-"], check=True, capture_output=True, text=True).stdout
        flat = " ".join(extracted.split())
        for line in a4["payload"]:
            ok(f"extracted: {line[:60]}...") if " ".join(line.split()) in flat else bad(f"not extracted: {line}")
    raw = pdf.read_bytes().decode("latin-1")
    hidden_block = raw.split("3 Tr", 1)[1].split("0 Tr", 1)[0] if "3 Tr" in raw else ""
    in_block = all(line.replace("(", "\\(").replace(")", "\\)") in hidden_block for line in a4["payload"])
    ok("hidden lines are drawn with text render mode 3 (invisible)") if in_block else bad("hidden lines not inside a 3 Tr block")

    print()
    print(f"check_data.py: {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
