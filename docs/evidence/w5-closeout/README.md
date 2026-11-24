# Close-out read-backs, 2026-11-24 (w3-teardown, w2-pim, D-053, D-054)

Captured 2026-11-24 by Tooni in the Azure portal, the Microsoft Entra admin center and the Microsoft 365 admin center, signed in as T, read-only. Nothing was changed. Checked before committing: no email, UPN, tenant domain, subscription ID or object ID visible; the user name in 01's description and the billing account name in 06 are blanked. The tenant shows only as "Default Directory" (04). Each PNG carries a C2PA manifest (`caBX`), a standing false-positive class; it's stripped in this public copy.

| File | What it shows | Supports |
|---|---|---|
| `01-elevation-toggle-no-T-view-20261124.png` | Microsoft Entra ID > Properties, "Access management for Azure resources", as T: toggle **No** | T's own toggle reads No: T isn't elevated at root, consistent with T never using elevation. It does **not** show that G de-elevated: the toggle shows the signed-in user's own state ("When you set the toggle to **Yes**, you are assigned the User Access Administrator role", https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin#perform-steps-at-root-scope), so G's view is needed: see `07` |
| `02-T-pim-azure-eligible-none-20261124.png` | PIM > My roles > Azure resources > Eligible assignments: No results | T's Owner and Monitoring Contributor eligibilities are gone (D-048, D-052) |
| `03-T-pim-azure-active-reader-20261124.png` | PIM > My roles > Azure resources > Active assignments: Reader, Azure subscription 1, Subscription, Direct, condition None | T holds a standing, read-only Reader role on the subscription (D-054); no write role |
| `04-T-pim-entra-eligible-security-reader-20261124.png` | PIM > My roles > Microsoft Entra roles > Eligible assignments: Security Reader, Default Directory, Direct, Permanent, Activate | T's Security Reader is eligible only, kept on purpose (D-053) |
| `05-T-pim-entra-active-none-20261124.png` | PIM > My roles > Microsoft Entra roles > Active assignments: No results | No Entra role is active for T |
| `06-m365-products-e5-gone-20261124.png` | Microsoft 365 admin center > Your products: 1 item, Microsoft Entra ID Free, Active | The Microsoft 365 E5 trial is no longer listed; only Entra ID Free is active |
| `07-elevation-toggle-no-G-view-20261124.png` | Microsoft Entra ID > Properties, "Access management for Azure resources", as G: toggle **No** (G's name and email masked) | G de-elevated after the recovery step (D-052): G no longer holds User Access Administrator at root |
| `08-entra-security-reader-active-0-20261124.png` | Security Reader role: Users (0) | No one holds Security Reader as an active assignment, consistent with D-053 (T's is eligible only, `04`) |
| `09-purview-audit-reader-0-members-20261124.png` | Microsoft Purview role groups > Audit Reader: Members, 0 users, 0 security groups | T's time-limited membership expired as planned; no one is left in the role group |

07 to 09 were captured 2026-11-24, read-only; 07 is signed in as G, not T. The post-teardown checks are complete.
