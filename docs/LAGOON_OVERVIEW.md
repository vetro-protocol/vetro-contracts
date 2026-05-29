# Lagoon Vault Overview — Plain-Language Guide

> ### 📖 Which document should I read?
> | If you want to… | Read |
> |---|---|
> | Understand what a Lagoon vault is, how Vetro's treasury earns yield, and who is responsible for what — **no code** | **Lagoon Overview** 👈 *you are here* |
> | **Do** the operations — exact buttons, addresses, deploy, settlement, bridging, emergencies | [Lagoon Operations Runbook](./LAGOON_RUNBOOK.md) |
> | Operate Gateway / Treasury / StakingVault (addresses, roles, harvest) | [OPERATIONS.md](./OPERATIONS.md) |

**Who this is for:** the **business team**, the **Curator team**, and **new operators**. It assumes no coding knowledge. Read this first; graduate to the [Runbook](./LAGOON_RUNBOOK.md) when you're ready to click buttons.

**What it covers:** where Vetro's treasury money goes, what a Lagoon vault is, the **three jobs** that keep one healthy (price it, settle it, buffer it), who does each, and the rules that keep everyone honest.

> **If you are ever unsure, stop and ask the Curator engineering lead before signing anything.**

---

## 1. The big picture — where treasury money goes

Vetro mints pegged tokens (VUSD, vetBTC) backed 1:1 by collateral. That collateral does not sit idle — it is routed, layer by layer, into yield. The money passes through three layers before it reaches a Lagoon vault:

```
  Users deposit ─▶ Treasury ─▶ Yield Vault ─▶ split across strategies by "weight"
   (mint pegged    (holds all    (spreads          │
    tokens)        collateral)    the money)        ├─▶ Strategy A (e.g. Aave)
                                                    ├─▶ Strategy B (e.g. Morpho)
                                                    └─▶ Lagoon Strategy ─▶ LAGOON VAULT
                                                                            (curated by
                                                                             THIS team)
```

1. **Treasury → Yield Vault.** Each collateral token is parked in one yield vault that holds the money on the Treasury's behalf.
2. **Yield Vault → strategies.** The yield vault splits the money across several strategies, each given a **weight** (a target % of the pot). One of those can be a **Lagoon strategy**.
3. **Lagoon strategy → Lagoon vault.** The Lagoon strategy puts money into an external **Lagoon vault**, which earns yield on Base (lending USDC on Aave or Morpho).
4. **Vetro curates that Lagoon vault.** Vetro holds the keys to the Lagoon vault's day-to-day operation. **That curation job is what this guide is about.**

> **The same team can be on both sides of one vault** — putting money *in* (as a depositor) and *running* it (as the curator). Money put in only actually moves when the curator runs a settlement (Job #2 below).

For the layers *above* the Lagoon vault (Treasury, Yield Vault, harvesting yield back to stakers), see [OPERATIONS.md](./OPERATIONS.md). The rest of this guide focuses on the Lagoon vault itself.

---

## 2. What a Lagoon vault is, in one picture

Think of the vault as a **shared pot of money** with a **price tag on each share**.

- Vetro puts money in and gets **shares** back (like units of a fund).
- The vault's money is sent out to earn **yield** (lending USDC on Aave / Morpho on Base).
- As it earns, **each share becomes worth more**. That rising **share price** is how Vetro's profit shows up.

```
   Money in  ─────▶   LAGOON VAULT (the pot)   ─────▶  earns yield on Base
   (get shares)         every share has a              │
                        "share price"                  ▼
                                              share price goes UP
                                                       │
                                                       ▼
                          Vetro's shares are now worth more  =  YIELD
```

**The share price is the heartbeat of the vault.** Keeping it accurate and up to date is the single most important recurring job.

---

## 3. The roles — who does what

Lagoon defines a set of named **roles** for every vault. Think of each role as a *hat*: the right to perform certain actions on-chain. A single Gnosis **Safe** (a multi-person shared wallet) can wear one hat or all of them.

**For Vetro's 5 vaults today, one shared Safe wears every hat** — the same group proposes the valuation, settles, holds the money, and can pause or close. The table below is what each hat *does*; the [Current setup](#current-setup-as-deployed-today) section records who holds them.

| Role | What it does | One sentence to remember |
|---|---|---|
| **Vault Admin / Owner** | Sets up the vault, sets fees, can **pause** or **close** it, assigns the other roles | The safety switch and rule-setter |
| **Valuation Manager** | **Proposes the new share price** on a schedule | The one who reads the meter |
| **Curator (the Safe)** | **Holds all the money**, **settles** deposits/redeems, deploys cash to yield, keeps the buffer | The treasurer who moves money |
| **Keeper / Operator** | Clicks the buttons (propose, settle, bridge, supply) within tight pre-set limits | The hands on the controls |
| **Security Council** | Emergency-only override of valuation safety limits | The break-glass option |
| **Fee Receiver** | Receives the management / performance fees | Where the fees land |

### Current setup (as deployed today)

Vetro runs exactly these 5 Lagoon vaults, all on **Ethereum mainnet** — this is the **full scope** your team manages:

| # | Vault | What it holds | Vault address |
|---|---|---|---|
| 1 | Vetro cbBTC (`vetrocbBTC`) | cbBTC | `0x110b1f3cd409ef5a7b354aa1667c19998e1b6340` |
| 2 | Vetro hemiBTC (`vetrohemiBTC`) | hemiBTC | `0x26a6179247420b6e8036dbdef48fd74d1e57fdc3` |
| 3 | Vetro USDC (`vetroUSDC`) | USDC | `0x131ccfdffed712885aac31445d351e6b62656679` |
| 4 | Vetro USDT (`vetroUSDT`) | USDT | `0xE7FaE53e32B09028db4Ca8Ff7E4fF0574367eDba` |
| 5 | Vetro WBTC (`vetroWBTC`) | WBTC | `0x1a9b5c9845c2685923215779c6ec288bd5090e90` |

**All roles on all five vaults are currently held by one shared Safe** (`0x1b534a8543212F5957168D83311A41E0Ea1cfe48`). One group does the valuation, the settling, and the administration. This is deliberate — it keeps launch operations simple.

What keeps the money safe under this single-Safe setup: the Safe is a **multi-person multisig**, so no one person can move funds alone — **every** deposit settlement, bridge, or yield action needs the agreed number of signers to approve it. See [Runbook §3](./LAGOON_RUNBOOK.md).

> **Recommended hardening (not done yet).** Best practice — and what the Lagoon audit assumes — is to split the roles across *separate* Safes, so the **Valuation Manager and the Curator never share people** (whoever sets the price shouldn't also settle against it). Plan this split as the deployment matures: the Vault Admin reassigns each role to its own Safe. See [Runbook §1.2](./LAGOON_RUNBOOK.md) for the mapping and steps.

---

## 4. The three jobs that keep the vault healthy

Everything the Curator team does day to day comes down to three jobs, run on a fixed **cadence** (e.g. every Tuesday 14:00 UTC — agree it once and stick to it). The jobs are described by role below; with the current single-Safe setup the *same* Safe performs all of them, but they stay distinct jobs so the split is easy later.

### Job #1 — Price it: update the share price (valuation)

This is how Vetro's yield gets recognized. The **Valuation Manager** does it.

**What "share price" means:** *total money the vault controls ÷ number of shares.* To update it, the Valuation Manager updates the **total money** figure (Lagoon calls this "total assets" or **NAV**). Lagoon recalculates the per-share price automatically.

**How to work out total money** — add up **everything the vault controls**, wherever it sits:

- USDC in the Curator Safe (on **both** Ethereum and Base — treat them as one balance), **plus**
- The value of money deployed to yield (the Aave/Morpho position at current value, including interest), **plus**
- Any USDC **mid-transfer between chains** (count it at full value — it isn't lost, just travelling), **plus**
- Any rewards you've decided to count.

**The steps:** open the vault's **Manage** page, type the new total, check the preview (fees + queues), click **"Propose new valuation,"** sign. That's a *proposal* only — nothing settles until the Curator accepts it (Job #2).

> **Two special rules:**
> - **The very first valuation on a brand-new vault must be `0`.** Real numbers start the next cycle.
> - **Always count money mid-bridge.** Forget it, and the share price will appear to dip and jump back — which looks alarming and can trip the safety limits.

### Job #2 — Settle it: act on the price, on time

**Settlement** is the moment the vault actually acts on the new share price: it lets new depositors in and pays exiting redeemers out, all at the freshly agreed price. The **Curator** does it.

**Why *on time* matters:** between settlements, deposit and redemption requests just **wait in a queue**.

- **New deposits only become usable money after settlement.** Until then, fresh cash is parked and can't be put to work or used to pay redeemers.
- **Redemptions only get paid at settlement.** Skipping or delaying it makes people wait longer for their money — a trust problem.

So: **settle every cadence, on schedule, without skipping.**

**The steps:** open the Manage page, review the proposal (before/after total, fees, queue sizes). If anything looks wrong, **do nothing** — there's no "reject" button; just wait for a corrected proposal, which replaces the bad one. If it looks right, click one of:

| Button | What it does | When |
|---|---|---|
| **Settle Deposit** | Lets new deposits in **and then** uses that fresh cash (plus what's in the Safe) to pay as many redemptions as possible | **The normal choice** — right after deposits land, the Safe holds the most cash, the best moment to pay redeemers |
| **Settle Redeem** | Pays redemptions only; new deposits wait for next cycle | Only when you deliberately don't want new deposits this cycle |

**Default to "Settle Deposit."**

### Job #3 — Buffer it: keep cash ready for redemptions

**Lagoon does not force you to keep any cash on hand — it is entirely up to the Curator.**

**The problem to avoid:** when you settle redemptions, the Curator Safe must already **hold enough USDC** to pay everyone exiting. If most of the money is away earning yield on Base and the Safe is short, **those redemptions can't be paid that cycle** — exiting users wait. That's exactly the outcome to prevent.

**The buffer rule of thumb:** after each settlement, don't deploy everything to yield. Keep a cushion in the Curator Safe on the settlement chain (Ethereum):

> **Keep at least the larger of:** `1.5 × your forecast of next cycle's redemptions`, **or** `5% of the vault's total assets`. Send only the **rest** to Base for yield.

Forecast from recent cycles' churn, and assume a bit more to be safe.

**If the buffer turns out too small:** withdraw from the yield venue on Base → bridge that USDC back to Ethereum → confirm it has **arrived** → *then* settle the redemptions. There's no shortcut, so it's far better to keep a healthy buffer up front than to scramble.

---

## 5. The bigger liquidity picture — three nested buffers

The Curator's buffer (Job #3) is the *innermost* of three cushions across the whole treasury stack. Size them so an outer redemption never forces a fire-sale of an inner, locked-up position.

| Buffer | Where it sits | Sized for |
|---|---|---|
| **1. Lagoon Safe buffer** | USDC idle in the Curator Safe | This cycle's Lagoon redemptions: `max(1.5 × forecast, 5% of assets)` |
| **2. Yield Vault buffer** | Idle cash + instantly-liquid strategies in the Yield Vault | Expected Treasury withdrawals |
| **3. Treasury idle** | Collateral held directly in the Treasury | Gateway redemptions |

**Rule of thumb:** the more capital committed to the slow Lagoon leg, the larger buffers 1–3 must be. When a large redemption is expected, refill **from the inside out, ahead of** the cadence: withdraw from Aave/Morpho → bridge back → top up the Lagoon buffer → then push up to the Treasury if needed. (Buffers 2 and 3 are operated per [OPERATIONS.md](./OPERATIONS.md).)

---

## 6. The weekly rhythm (putting it together)

1. **Valuation Manager** works out the new total money and **proposes the new share price.** (Job #1)
2. **Curator** reviews, then **settles** — usually "Settle Deposit." (Job #2)
   New deposit cash now sits in the Safe; the higher share price is Vetro's recognized yield.
3. **Curator** sets aside the **buffer**, then sends the surplus to **yield on Base** — the signers approve these as Safe transactions (bridge, then supply to the yield venue). (Job #3)
4. Keep money mid-bridge **counted** in the next valuation, so the share price stays smooth.
5. Repeat next cadence. **Never skip a settlement.**

That recognized yield eventually flows back to Vetro stakers via the Treasury's harvest cycle — see [OPERATIONS.md](./OPERATIONS.md).

---

## 7. Golden rules (print this)

- ✅ **Settle on schedule, every cadence.** New money only arrives, and redeemers only get paid, when you settle.
- ✅ **Always keep the buffer** (`max(1.5× forecast, 5% of assets)`) before deploying to yield.
- ✅ **Count in-flight (bridging) money** in the valuation.
- ✅ **Every fund movement is a Safe multisig transaction** — it needs the full signer quorum, no exceptions.
- ❌ **Never deploy 100% to yield** and leave the Safe empty before a redemption cycle.
- ❌ **Never rush a settlement** that looks wrong — wait for a corrected valuation.
- 🔜 **Plan to separate the roles.** Today one shared Safe holds every role on all five vaults; as the setup matures, move the Valuation Manager and Curator onto different Safes so the people who set the price aren't the ones who settle against it.

---

## 8. When something goes wrong

| Situation | What to do | Who acts |
|---|---|---|
| Anything abnormal (suspected exploit, bad valuation, yield-protocol issue) | **Pause the vault** — freezes all activity until resolved | Vault Admin |
| A correct valuation is being blocked by the safety limits | Use the **Security Council override** — break-glass only, with full team awareness, and log it | Security Council |
| Winding the vault down for good | **Close** the vault — irreversible; the Safe must hold enough cash to pay *all* redemptions first | Admin → Valuation Manager → Curator |
| Buffer too small for this cycle | Withdraw from yield, bridge back, confirm arrival, **then** settle | Curator + Keeper |

For the exact steps, see [Runbook §6 (Emergencies)](./LAGOON_RUNBOOK.md). **When in doubt, pause first, ask second** — pausing is reversible; a bad settlement may not be.

---

## 9. Mini-glossary

| Term | Plain meaning |
|---|---|
| **NAV / total assets** | The total money the vault controls. Divided by the number of shares, it gives the **share price**. |
| **Share price** | What one share is worth. When it rises, that rise is Vetro's **yield**. |
| **Valuation** | Telling the vault its new total money, so it recalculates the share price. |
| **Settlement** | The moment the vault lets deposits in and pays redemptions out, at the agreed price. |
| **Buffer** | Cash kept ready in the Curator Safe so redemptions can always be paid. |
| **Curator Safe** | The shared multi-person wallet that holds all the vault's money — and, today, every other role too (`0x1b53…fe48`). |
| **Bridge / CCTP** | Moving USDC between chains (Ethereum ↔ Base). Money mid-bridge still counts as the vault's. |
| **Cadence** | The fixed schedule for valuing and settling (e.g. weekly). |

---

## 10. Where to go next

- **Exact steps, buttons, addresses, function names:** [Lagoon Operations Runbook](./LAGOON_RUNBOOK.md).
- **Treasury / Gateway / StakingVault operations:** [OPERATIONS.md](./OPERATIONS.md).
- **Lagoon official docs:** https://docs.lagoon.finance
- **Open business decisions before go-live** (signer lists, valuation formula, buffer %, yield allowlist, cadence, on-call rota): [Runbook §8](./LAGOON_RUNBOOK.md).
