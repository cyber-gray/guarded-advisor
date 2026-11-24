# Larkfield synthetic data (`w1-data`)

Everything here is synthetic: fictional people, employers, clinics, providers and claims for the Guarded Advisor lab.
Nothing comes from a real person, record or organization.

| Path | What | How it's made |
|---|---|---|
| `claims.json` | 30 disability claims, 10 per case manager alias (`alder`, `birch`, `cedar`), with one planted canary note (A6) | `agent/generate_data.py` |
| `submitted/` | Clean member-submitted files: 12 doctor's notes (PDF) and 8 expense spreadsheets (CSV) | `agent/generate_data.py` |
| `internal/` | 10 internal documents for File Search: plan wording, claims guidelines, return-to-work procedure and template, accommodation, privacy, escalation | Hand-written, static |
| `../attacks/` | Week-3 payloads A4 and A9 to A12, plus `manifest.json` (canary, targets, expected controls) | `agent/generate_data.py` |
| `../entitlements.json` | Case manager Entra object ID to claim IDs (C2), alias only, no UPNs | `agent/build_entitlements.sh`, after the accounts exist |
| `../names.json` | Invented name list and its provenance (reused for the B1 bias pairs) | Hand-written |

**Seed:** `20261016` (in `agent/generate_data.py`). Outputs contain no timestamps or random IDs, so every run
produces identical bytes.

**Regenerate and check:**

```bash
python3 -I agent/generate_data.py   # rewrites claims.json, submitted/ and ../attacks/
python3 -I agent/check_data.py      # determinism, C2 partition, canary, rule-1 patterns, URLs, A4 extraction
```

**Requirements:** Python 3.11 or later (standard library only), and `pdftotext` from Poppler
(`brew install poppler`) for the A4 extraction check. `check_data.py` **fails** if `pdftotext` is missing; it never
skips the check. After the case manager accounts exist: `./agent/build_entitlements.sh`, then rerun the check.

**Attack payloads** (`../attacks/`): A9 to A12 run only inside the Azure Container Apps sandbox through
`run_analysis` (week 3). Never run the code they ask for on a workstation, the jumpbox or any host with credentials.

**Rules (the lab's synthetic-data rule):** names come from the invented list; age is an integer; no addresses, phone numbers,
dates of birth, or values shaped like a SIN, health card or real insurer's policy number; exfiltration targets in
the attack files use RFC 2606 reserved names only (`exfil.example`); the canary is obviously fake
(`LARKFIELD-CANARY-XXXX`).
