# S3 portal evidence (ga-sbx-lab)

Captured 2026-10-26 from the Container Apps Sandboxes portal, signed in as the lab admin. Files 01 to 09 are read-only views (nothing created). Files 10 to 13 are from S3-0b: one sandbox from `ga-analysis`, XS, Full inspection with default Deny, no rules, nothing else added, deleted straight after. No network tests were run.

Checked before committing: none of these images shows an email address, tenant or directory name, subscription ID or object ID. The 403 screenshot, which showed the guest account's email, is left out on purpose.

| File | What it shows | Supports |
|---|---|---|
| `01-disk-image-ga-analysis-private.png` | Disk Images: one private image, `ga-analysis`, labelled `ga-analysis` (17 public images not used) | A4: image registered |
| `02-disk-image-ready.png` | The disk image state is Ready | A4: image registered |
| `03-identity-attached-before-detach.png` | Security > Identity: user-assigned `ga-id-sbx-pull-lab` attached, system-assigned off | The state before the just-in-time detach (see 10 for after) |
| `04-create-defaults-partial-allow.png` | Create form defaults: Partial inspection and default action Allow; the help text says Partial requires Allow | Finding: a portal-created sandbox has open egress unless changed |
| `05-full-inspection-help-text.png` | Full inspection with Deny; the help text says "All HTTPS traffic is inspected and non-HTTP traffic is blocked" | Finding: the UI makes the same claim as Learn, which the S3-0 TCP connect contradicts (unconfirmed) |
| `06-rule-match-fields.png` | A rule matches on a destination host pattern and an optional path only | Finding: no CIDR, port or protocol matching |
| `07-rule-actions.png` | Rule actions: Allow, Deny, Transform, Rewrite, Webhook | Finding: no non-HTTP deny can be expressed; the Webhook action isn't listed on Learn |
| `08-networking-vnet.png` | Networking > VNET: no VNet connections; sandboxes can attach to a delegated subnet in the group's region | D-026 reopen path: VNet connection plus NSG |
| `09-networking-private-endpoint.png` | Networking > Private Endpoint: Express environment link, ingress only, permanent once created; not associated | Note: not used, and avoid (it's irreversible) |
| `10-identity-after-detach.png` | Security > Identity after the detach: no user-assigned identities, system-assigned off | Just-in-time pull identity: no identity on the group outside a registration run |
| `11-s3-0b-env-names.png` | Portal terminal: `whoami` root, `uid=0(root)`, and environment variable names only, including `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` | Findings: the portal terminal runs as root (the API exec ran as `analysis`, uid 10001); the platform still injects the token endpoint with no group identity |
| `12-s3-0b-policy.png` | The S3-0b sandbox's egress policy: Full, Deny, no rules; the dialog says "If you don't specify it, the sandbox has unrestricted outbound access. Egress policies are opt-in." | The policy was applied as intended; the UI confirms the open default in its own words |
| `13-s3-0b-sandbox-running.png` | The running S3-0b sandbox: root prompt, 0 allowed and 0 denied egress decisions, 0 B network traffic | Context for 11: nothing tried to go out during the check |
