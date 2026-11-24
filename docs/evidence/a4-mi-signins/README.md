# A4 managed identity sign-ins (ga-id-sbx-pull-lab)

Captured 2026-10-27 by Tooni in the Microsoft Entra admin center (Sign-in events, Managed identity sign-ins), read-only. Finding: `docs/findings.md`, A4 ("The sandbox SDK's managed-identity pull is silently ignored"), bullet "Identity-side corroboration".

Checked before committing: emails, subscription ID and assignment IDs blanked; another project's managed identity cropped out of 01 (recaptured 2026-10-27, 2428x772). **Re-masked 2026-11-24 (Tooni):** the request IDs and managed identity IDs in 01, and the request ID and correlation ID in 02, are now blanked.

| File | What it shows | Supports |
|---|---|---|
| `01-mi-signins-oct24-pull-identity.png` | Managed identity sign-ins, 2026-10-24, UTC, 24-hour time aggregate: the `ga-id-sbx-pull-lab` row expanded, holding one sign-in at 15:36:51Z, Success (request and identity IDs masked) | The pull identity signed in once that day, at 15:36:51Z; no sign-in at 15:08 or 15:16Z (the two 401 attempts) |
| `02-mi-signin-1536-detail.png` | Sign-in detail: 2026-10-24T15:36:51Z, Status Success, not an agent; request and correlation IDs masked. The identity's name isn't in this view | One successful managed identity sign-in in the same second as the registry's 200 row (`ContainerRegistryLoginEvents`, identity `ga-id-sbx-pull-lab`) |
