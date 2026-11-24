# Defender for Cloud, free tier

Captured 2026-10-27 by Tooni in the Azure portal (Microsoft Defender for Cloud), read-only, with only the free foundational CSPM enabled (the Defender CSPM prompt was declined, deferred under D-023). Finding: `docs/findings.md`, "Defender for Cloud free tier".

Checked before committing: emails, subscription ID and assignment IDs blanked; the risk factors column is blurred. The subscription display name and resource names are visible.

| File | What it shows | Supports |
|---|---|---|
| `01-recommendations-lab.png` | Recommendations filtered to the lab group: six, all risk level "Not evaluated"; two on `gaacrlabv3doqebnffszc`, four on `ga-jump-lab`; 0 critical, 0 attack paths | Free tier doesn't evaluate risk; the lab's open recommendations |
| `02-acr-unrestricted-network.png` | "Container registries should not allow unrestricted network access" on the registry: risk Not evaluated, attack paths 0 | Matches the accepted public-network gap (D-025) |
| `03-overview-secure-score.png` | Overview: 21 assessed resources, 0 attack paths, 0 alerts; secure score 46%; 25 recommendations, all Not evaluated; Microsoft cloud security benchmark 46 of 63 controls | The free-tier posture; 0 attack paths means not analysed |
