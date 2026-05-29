# Lagoon Vault Operations Runbook

> ### 📖 Which document should I read?
> | If you want to… | Read |
> |---|---|
> | Understand what a Lagoon vault is and who does what — **no code** | [Lagoon Overview](./LAGOON_OVERVIEW.md) |
> | **Do** the operations — exact buttons, addresses, deployment, settlement, bridging, emergencies | **Lagoon Operations Runbook** 👈 *you are here* |
> | Operate Gateway / Treasury / StakingVault (addresses, roles, harvest) | [OPERATIONS.md](./OPERATIONS.md) |
>
> **This is the reference manual.** New to Lagoon vaults? Read the [Overview](./LAGOON_OVERVIEW.md) first.

**Audience:** Vault Admin and Curator team members operating a Lagoon vault end-to-end — deployment, daily NAV/settlement, cross-chain yield, and emergencies.

**Scope:** Lagoon v0.6.0. Worked example throughout: **USDC vault on Ethereum, yield generated on Base via Aave or Morpho.**

**How to read each task:** every step states (a) which interface — Lagoon app, Safe app, or a block explorer — (b) who clicks the button, and (c) what changes on-chain. **If you ever feel unsure, stop and ask the Curator engineering lead before signing.**

**Contents**
1. [Roles and naming](#1-roles-and-naming--read-this-first)
2. [Pre-deployment checklist & deployment](#2-pre-deployment-checklist--deployment)
3. [Operating the Curator Safe](#3-operating-the-curator-safe)
4. [Daily operations — NAV update & settlement](#4-daily-operations--nav-update--settlement)
5. [Cross-chain yield workflow](#5-cross-chain-yield-workflow)
6. [Whitelist / Access Manager](#6-whitelist--access-manager)
7. [Emergency procedures](#7-emergency-procedures)
8. [Quarterly housekeeping & open items](#8-quarterly-housekeeping--open-items)
9. [Reference URLs](#9-reference-urls)
10. [Appendix — the Vetro layers above the vault](#10-appendix--the-vetro-layers-above-the-vault)

---

## 1. Roles and naming — read this first

Lagoon's UI and the on-chain contract use slightly different names. This trips people up:

| UI name (app.lagoon.finance) | On-chain role | What they do |
|---|---|---|
| **Vault Admin** | `owner` (Ownable2Step) | Governance, safety, role assignment, fees, pause, close |
| **Curator** | `safe` | Holds the assets, deploys capital, settles deposits/redeems |
| **Valuation Provider** | `valuationManager` | Proposes new NAV (price per share) |
| **Access Manager** | `whitelistManager` | Manages whitelist / blacklist |
| **Security Council** | `securityCouncil` | Bypasses NAV guardrails in emergencies |
| **Fee Receiver** | `feeReceiver` | Receives management / performance fees |

Each role is a single Ethereum address — can be an EOA, a contract, or a Gnosis Safe. Lagoon does **not** enforce that any role be a multisig. **Our policy: every role except Fee Receiver must be a Gnosis Safe multisig.**

**The Curator role holds and moves all vault funds.** Lagoon's audit report explicitly states the `safe` (Curator) "is allowed to walk away with funds by design." The off-chain control that makes that safe in practice is the **Curator Safe multisig**: every fund movement requires the signer quorum to approve. (Scoping routine operator permissions so they don't each need the full quorum is a planned hardening — see §3.)

**Why the same Safe address on every chain:** deterministic CREATE2 deployment. Same signers, same threshold, one address to remember, no second source of truth.

### 1.1 Deployed vaults

All five vaults are **Lagoon v0.6.0 on Ethereum mainnet** (chainId `1`). Manage page for any of them: `https://app.lagoon.finance/manage/1/<vaultAddress>`.

| # | Vault (token) | Vault address | Underlying asset |
|---|---|---|---|
| 1 | Vetro cbBTC (`vetrocbBTC`) | `0x110b1f3cd409ef5a7b354aa1667c19998e1b6340` | cbBTC `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| 2 | Vetro hemiBTC (`vetrohemiBTC`) | `0x26a6179247420b6e8036dbdef48fd74d1e57fdc3` | hemiBTC `0x06ea695B91700071B161A434fED42D1DcbAD9f00` |
| 3 | Vetro USDC (`vetroUSDC`) | `0x131ccfdffed712885aac31445d351e6b62656679` | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| 4 | Vetro USDT (`vetroUSDT`) | `0xE7FaE53e32B09028db4Ca8Ff7E4fF0574367eDba` | USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| 5 | Vetro WBTC (`vetroWBTC`) | `0x1a9b5c9845c2685923215779c6ec288bd5090e90` | WBTC `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |

> **Worked example caveat.** This runbook's cross-chain example (§5) is written for the **stablecoin** vaults — USDC/USDT, yielding on Base via Aave/Morpho over CCTP. The **BTC** vaults (cbBTC, hemiBTC, WBTC) follow the identical request → value → settle → claim lifecycle, but their yield venue, chain, and bridge differ. Whatever a given vault's venue is, it must be agreed up front and is a go-live open item (§8.2). Substitute the right asset/venue per vault.

### 1.2 Current role assignments

**Today, for simplicity, every Lagoon role on all five vaults is assigned to a single shared Safe: `0x1b534a8543212F5957168D83311A41E0Ea1cfe48`.** This is operationally convenient but collapses the separation-of-duties model described in §1 — the Curator and Valuation Provider are the same signers, so the same humans both set the NAV and settle against it.

| On-chain role | UI name | Currently assigned to |
|---|---|---|
| `owner` | Vault Admin | Shared Safe `0x1b53…fe48` ✅ verified on-chain |
| `safe` | Curator | Shared Safe `0x1b53…fe48` ✅ verified on-chain |
| `valuationManager` | Valuation Provider | Shared Safe `0x1b53…fe48` |
| `whitelistManager` | Access Manager | Shared Safe `0x1b53…fe48` |
| `securityCouncil` | Security Council | Shared Safe `0x1b53…fe48` |
| `feeReceiver` | Fee Receiver | Shared Safe `0x1b53…fe48` |

> `owner()` and `safe()` were read directly from all five vault contracts and both return the shared Safe; the remaining roles are set to the same Safe per the current configuration. To re-verify any role on-chain: `cast call <vault> "owner()(address)" --rpc-url <eth-rpc>` (and `safe()`).

> **This can and should be separated as the deployment matures.** To split roles, the Vault Admin (`owner`) reassigns each role to its own dedicated Safe — per the target model in §1 (every role except Fee Receiver a distinct multisig, no shared signers between Curator and Valuation Provider) and the separation constraint in §2.1. Until then, the single-Safe setup leans entirely on that Safe's multisig threshold (every action needs the full signer quorum — §3). Track the split as a go-live open item (§8.2).

---

## 2. Pre-deployment checklist & deployment

### 2.1 Pre-deployment checklist
Complete every row before any vault contract is deployed.

| # | Decision | Owner | Suggested value (USDC example) |
|---|---|---|---|
| 1 | Vault asset (underlying ERC-20) | Admin | USDC on Ethereum mainnet (`0xA0b8...eB48`) |
| 2 | Vault name and symbol | Admin | `Vetro USDC Yield Vault` / `vUSDC` |
| 3 | Deployment chain | Admin | Ethereum |
| 4 | Vault Admin multisig | Admin | Existing org admin Safe (Ethereum) |
| 5 | Curator (`safe`) address | Admin | New deterministic Safe, deployed at the **same address on Ethereum and Base** before vault deploy |
| 6 | Valuation Provider | Admin | Separate Safe (**not** the Curator's signer set), or a specialist provider |
| 7 | Access Manager | Admin | Admin Safe or compliance Safe |
| 8 | Security Council | Admin | Independent Safe, conservative signer set |
| 9 | Fee Receiver | Admin | Treasury Safe |
| 10 | Management fee (annual %) | Admin | Per business model |
| 11 | Performance fee (%) | Admin | Per business model |
| 12 | Entry/exit fees (if any) | Admin | Per business model |
| 13 | Whitelist / blacklist / open mode | Admin | Whitelist for institutional launch |
| 14 | Sync deposits enabled? | Admin | Off at launch (async-only is safer; can enable later) |
| 15 | Settlement cadence | Admin + Curator | e.g. weekly, Tuesdays 14:00 UTC |

> **Critical constraint:** rows 5–9 should **never share signers**. Separation of duties is the only thing that makes the trust model meaningful — if Vault Admin and Curator are the same Safe, the Admin's power to swap the Curator address is worthless.

### 2.2 Deployment flow

**Option A — Lagoon Solutions (managed). Use this for our launch.** Lagoon's team handles deployment, sets parameters from a config you sign off on, and hands you the vault address. See [Lagoon Solutions](https://docs.lagoon.finance/vault/deploy-your-vault/lagoon-solutions).

**Option B — Self-deploy.** Connect the Admin wallet to `app.lagoon.finance`, click "Deploy a vault," fill the parameter form (matching §2.1), submit. See [Deploy your vault](https://docs.lagoon.finance/vault/deploy-your-vault).

### 2.3 Post-deployment wiring — DO THIS BEFORE TAKING ANY DEPOSITS
Order matters.

1. **Curator Safe approves the vault to spend USDC (one-time, infinite allowance).**
   - Safe app → New transaction → Contract interaction → target the **USDC** contract.
   - Function `approve(spender, value)`; `spender` = the deployed vault address; `value` = `115792089237316195423570985008687907853269984665640564039457584007913129639935` (max uint256).
   - **Without this, redemptions will fail.** ([Vault post-deployment operations](https://docs.lagoon.finance/vault/deploy-your-vault/vault-post-deployment-operations))
2. **Verify the proxy on Etherscan** so the vault pages show Read/Write tabs (Contract tab → "Is this a proxy?" → Verify).
3. **First NAV must equal 0.** The very first valuation after deployment must be `0`, regardless of pending deposits. Normal cadence begins after a non-zero NAV has been posted once. ([Update valuation & settle](https://docs.lagoon.finance/vault/how-to))
4. **Submit vault metadata** for listing on the Lagoon front-end (name, description, logo, links). The vault works without it, but users can't find it on the public explorer.
5. **Confirm the Curator Safe signer set and threshold** are correct on every chain the vault will use — see §3.

---

## 3. Operating the Curator Safe

The Curator (`safe`) holds and moves all vault funds, so how the Safe is operated is the core control. **Today there is no scoped operator lane: every Curator action — settling, bridging, supplying to / withdrawing from a yield venue — is executed as an ordinary Safe multisig transaction and requires the full signer quorum.**

### 3.1 The Curator Safe address
For Vetro's current vaults, all five share one Curator Safe: **`0x1b534a8543212F5957168D83311A41E0Ea1cfe48`** (also holds every other role — see §1.2). If a vault's yield is generated on another chain (e.g. Base), the Safe must exist at the **same address** there, deployed with the **same signer set and threshold**; verify the addresses match before moving funds across.

### 3.2 How Curator actions are executed
Every action is a Safe transaction: **Safe app → New transaction → Contract interaction**, then collect the required signatures and execute. The actions the Curator performs:
- **Settlement** — on the Lagoon vault: `settleDeposit(uint256)`, `settleRedeem(uint256)`, plus occasional `setMaxAssets(uint256)` (cap management) and `approve(vault, …)` re-approval. (§4)
- **Bridging** (only for vaults whose yield is on another chain) — CCTP `depositForBurn(...)` / `receiveMessage(...)`. (§5)
- **Yield** — the venue's `supply` / `withdraw`, plus a one-time `approve`. (§5)

Because each of these needs a full signer quorum, plan signer availability around the settlement cadence (§2.1 row 15).

### 3.3 Test in small size
Before any user funds flow through a vault, fund the Curator Safe with a small amount (e.g. ~$100 of the vault asset) and run the full loop once as Safe transactions: settle a tiny deposit, and — for cross-chain vaults — bridge out, supply, withdraw, bridge back. Confirm every step succeeds and the signing process works end-to-end.

> **Planned hardening.** Two controls are on the roadmap and **not yet in place**: (1) **scoping routine operator permissions** so day-to-day actions don't each need the full signer quorum, and (2) **separating the Lagoon roles onto distinct Safes** (§1.2). Until both land, the multisig quorum is the *only* control — keep the signer set tight and the threshold meaningful, and treat every signature with care. Track both in §8.2.

---

## 4. Daily operations — NAV update & settlement

The core recurring workflow. Reference: [Update valuation & settle requests](https://docs.lagoon.finance/vault/how-to).

### 4.1 Open the management UI
- URL: `https://app.lagoon.finance/manage/<chainId>/<vaultAddress>` (Ethereum chainId = 1).
- The blue **Manage** button appears only for connected Admin, Curator, or Valuation Provider wallets. ([Access your vault](https://docs.lagoon.finance/vault/deploy-your-vault/access-your-vault-on-lagoon))

### 4.2 Valuation Provider proposes new NAV
1. Connect the Valuation Provider Safe.
2. Click into the NAV input field — the UI enters **simulation mode**.
3. Enter the new total-assets value. The page previews fee accruals, asset deltas, and pending-request impact as a green diff.
4. When correct, click **"Propose new valuation"** and execute the Safe transaction. On-chain this is `updateNewTotalAssets(newTotalAssets)`, guarded by the price-per-share guardrails.

> **Where the number comes from:** `Total assets = USDC in the Curator Safe (both chains, one balance) + aToken/Morpho balance at current exchange rate + in-flight bridge USDC at face value (+ accrued rewards if counted)`. Document the methodology in a separate sheet, signed off by Admin before launch (§8).
>
> **First NAV must be `0`** on a new vault (§2.3). **In-flight bridge USDC must be counted** (§5.5), or NAV will dip and recover artificially and the guardrails may reject the update.

### 4.3 Curator reviews the proposal
1. Connect the Curator Safe. The proposed valuation shows three sections to verify:
   - **Asset changes** — total assets before vs after.
   - **Fee calculations** — management + performance fees to be taken.
   - **Pending requests** — deposit-queue and redeem-queue sizes.
2. **If anything looks wrong, do nothing.** There is no "reject" button — wait for the Valuation Provider to re-propose; the stale proposal is superseded.

### 4.4 Curator settles
Choose based on liquidity strategy. The Curator signs this as a Safe multisig transaction (§3.2).

| Function | What it does | When |
|---|---|---|
| `settleDeposit(newTotalAssets)` | Processes pending deposits, then **also tries** to settle redeems using fresh deposit assets + Curator holdings | **Standard cadence** — maximizes redemption liquidity |
| `settleRedeem(newTotalAssets)` | Settles redemptions only; pending deposits wait for next cycle | When you don't want new deposits this cycle but must pay redeemers |

> **Lagoon docs:** "The best moment to honor redemption requests is when there is a maximum of underlying in the curator address" — which is right after `settleDeposit`. **Default to `settleDeposit`** unless there's a specific reason not to. `settleDeposit` also takes management + performance fees (minted as shares to the Fee Receiver) and advances the high-water mark.

**Contract mechanics worth knowing:** requests batch into epochs (deposit epochs odd, redeem epochs even). A pending NAV must be proposed before each settlement (`updateTotalAssets` consumes it and resets to 0). `settleRedeem` is **liquidity-gated** — if `assetsToWithdraw` exceeds the USDC held in the Curator Safe, it **returns silently and redeems stay unsettled**. That's exactly why the buffer (§4.5) matters; there is no recovery *inside* a failed settlement — you re-run it once liquidity is present.

### 4.5 Buffer management (manual)
After settlement, decide how much USDC to keep as a redemption buffer vs deploy to yield. **Lagoon enforces nothing here.** Heuristic:
- Forecast next-cycle redemptions from historical churn.
- Keep at least `max(1.5 × forecast, 5% of total assets)` as USDC on Ethereum.
- Deploy the remainder to Base for yield (§5).

If the buffer is short and a redeem cycle exceeds available USDC, unwind and bridge back **before** the next settlement (§5.4).

---

## 5. Cross-chain yield workflow

Every step happens **inside the Curator Safe** and is executed as a Safe multisig transaction (§3.2). This applies to vaults whose yield is generated on another chain — e.g. the USDC/USDT vaults yielding on Base.

### 5.1 Move USDC Ethereum → Base (post-settlement)
1. Ethereum Curator Safe → New transaction → Contract interaction → CCTP TokenMessenger `depositForBurn`.
2. Parameters: amount, `destinationDomain=6` (Base), `mintRecipient`=our Base Safe, `burnToken`=USDC.
3. Wait for CCTP attestation (typically 15–20 min).
4. On Base, call `receiveMessage` on the CCTP MessageTransmitter to mint USDC into the Base Safe. (Circle's app at `app.circle.com/multichain` automates this.)

### 5.2 Supply USDC to yield on Base
1. Base Curator Safe. First time only: `USDC.approve(aaveV3Pool, max)` as a Safe transaction.
2. `aaveV3Pool.supply(USDC, amount, ourBaseSafe, 0)`.
3. Verify the aUSDC balance increased by the supplied amount.

### 5.3 Withdraw from yield on Base
1. `aaveV3Pool.withdraw(USDC, amount, ourBaseSafe)`. Use `type(uint256).max` to withdraw the entire position.
2. Verify USDC arrived in the Base Safe.

### 5.4 Bridge back Base → Ethereum
1. CCTP `depositForBurn` on Base: amount, `destinationDomain=0` (Ethereum), `mintRecipient`=our Ethereum Safe.
2. Wait for attestation, redeem on Ethereum.
3. USDC is now in the Ethereum Curator Safe and available for redemption settlement.

### 5.5 NAV implications during in-flight bridges
The Valuation Provider must count in-flight USDC (between `depositForBurn` and `receiveMessage`) toward total assets, or NAV will drop and recover artificially. Treat in-flight CCTP messages as USDC on the destination chain at **face value** — CCTP burns and mints 1:1, no discount.

---

## 6. Whitelist / Access Manager

If the vault launches in whitelist mode (§2.1 row 13), the Access Manager controls who can interact.
1. Connect the Access Manager Safe → Manage page → **Access** section.
2. Add/remove addresses via `addToWhitelist` / `removeFromWhitelist`.
3. Vault Admin can switch between **whitelist**, **blacklist**, and **open** modes. **Switching to async-only mode is permanent** — synchronous deposits are disabled forever once toggled.

Reference: [Whitelist Manager](https://docs.lagoon.finance/vault/roles-and-capacities/whitelist-manager).

---

## 7. Emergency procedures

### 7.1 Pause the vault
For any abnormal condition — suspected exploit, valuation gone wrong, yield protocol compromised, oracle issue.
1. **Only the Vault Admin can pause.** Connect the Admin Safe.
2. Call `pause()` (via Etherscan or Safe transaction builder).
3. When paused, **everything is blocked**: deposits, redeems, withdraws, mints, settlements, NAV updates, share transfers, operator changes.
4. To resume: Admin calls `unpause()`.

### 7.2 Security Council guardrail bypass
When a legitimate NAV update is blocked by the guardrails (e.g. a justified mark-down exceeds the allowed % move, or a vault inactive > 1 year).
1. Connect the Security Council Safe.
2. Call `securityCouncilUpdateTotalAssets(newTotalAssets)` — bypasses the price-per-share guardrail.
3. **Use only with full board awareness.** This is the trust-extension path; log every use in the operations journal.

### 7.3 Close the vault (irreversible)
Reference: [Close a vault](https://docs.lagoon.finance/vault/how-to).
1. **Admin** calls `initiateClosing()` → state `Closing`. New deposit settlements blocked; users can still request deposits and (importantly) request redeems.
2. **Valuation Provider** calls `updateNewTotalAssets(finalNAV)` with the final liquidation value.
3. **Curator** calls `close(finalNAV)` — value must **exactly** match step 2. Settles all pending and locks the vault.
4. After close: users can `withdraw()` / `redeem()` settled positions and transfer shares; no new deposits.

> **Before step 3, the Curator Safe must already hold enough USDC** to cover all pending redemptions and all share→asset conversions. Unwind Base positions and bridge back first. **There is no recovery from a botched close.**

### 7.4 Buffer short before a settlement
Withdraw from the yield venue (§5.3) → bridge back to Ethereum (§5.4) → confirm USDC has landed → **then** run `settleRedeem`. Re-run the settlement once liquidity is present.

---

## 8. Quarterly housekeeping & open items

### 8.1 Quarterly housekeeping
| Task | Owner | Cadence |
|---|---|---|
| Verify Curator Safe signer set and threshold | Admin | Quarterly; on any personnel change |
| Re-confirm signer availability around the settlement cadence | Curator | Quarterly |
| Review approved yield venues before onboarding a new one | Curator + Admin | Before any new venue |
| Reconcile in-flight CCTP messages against the NAV log | Valuation Provider | Each settlement |
| Test the pause flow on a testnet vault | Admin | Quarterly |
| Confirm Fee Receiver address matches treasury | Admin | Quarterly |

### 8.2 Open items the business team must resolve before go-live
1. **Final signer lists** for Curator, Valuation Provider, Security Council, Admin Safes — **no overlap** between Curator and Valuation Provider.
2. **Valuation methodology document** — exact NAV formula, including how in-flight bridges, accrued aToken interest, and rewards are counted.
3. **Buffer policy** — % of AUM kept on Ethereum as USDC for redemption liquidity.
4. **Yield venue list** — exactly which protocols (e.g. Aave V3, specific Morpho markets) and on which chain each vault may use. Agree this before deploying funds; adding a venue is a deliberate change.
7. **Operator-permission scoping & role separation** — plan for scoping routine operator actions and splitting the Lagoon roles onto distinct Safes (§3, §1.2). Until done, every action needs the full multisig quorum.
5. **Settlement cadence** and a communication plan for depositors who request mid-cycle.
6. **Incident-response on-call rota** — who responds within 1 hour to a `pause()`-worthy event.

---

## 9. Reference URLs

- Lagoon docs: https://docs.lagoon.finance
- Lagoon app (vaults): `https://app.lagoon.finance/vault/<chainId>/<vaultAddress>`
- Lagoon manage page: `https://app.lagoon.finance/manage/<chainId>/<vaultAddress>`
- Safe app: https://app.safe.global
- Circle CCTP UI: https://app.circle.com/multichain
- Lagoon vault contracts (this repo): `lagoon-v0/` · upstream https://github.com/hopperlabsxyz/lagoon-v0
- Lagoon Solutions: https://docs.lagoon.finance/vault/deploy-your-vault/lagoon-solutions
- Curator role: https://docs.lagoon.finance/vault/roles-and-capacities/curator
- Vault Admin role: https://docs.lagoon.finance/vault/roles-and-capacities/vault-admin
- Whitelist Manager: https://docs.lagoon.finance/vault/roles-and-capacities/whitelist-manager
- NAV update + settle: https://docs.lagoon.finance/vault/how-to

---

## 10. Appendix — the Vetro layers above the vault

A Lagoon vault is the *outermost* leg of Vetro's treasury yield chain. The layers above it are operated per [OPERATIONS.md](./OPERATIONS.md); this appendix is the technical reference for how they connect, for curators who also manage those layers.

```
Treasury ─▶ Vesper Yield Vault ─▶ strategies (by weight) ─▶ Lagoon strategy ─▶ Lagoon vault
                                                                                (this runbook)
```

### 10.1 Vesper Yield Vault — allocation by weight
The Yield Vault (`yield-vault/src/YieldVault.sol`) is a multi-strategy ERC-4626 vault. Each strategy has a `debtRatio` in basis points (`10_000` = 100%) = its target share of assets and borrow cap.
- `addStrategy(strategy, debtRatio)` (`owner`) / `updateDebtRatio(strategy, newRatio)` (`maintainer`) / `removeStrategy(strategy)` (`owner`, requires debt repaid). Running `totalDebtRatio` must stay `<= 10_000`.
- Allocation is **reactive, not pushed**: a strategy draws up to its credit line when the keeper calls `Strategy.rebalance(minProfit, maxLoss)`, which triggers the vault's `reportEarning(profit, loss, payback)`. **Change a weight, then trigger the next rebalance for it to take effect.**
- Keep `totalDebtRatio < 10_000` so idle headroom acts as a withdrawal buffer.
- **A Lagoon strategy is not instantly liquid** — keep it **late in the withdraw queue** (`updateWithdrawQueue`, `maintainer`) and keep enough weight in liquid strategies to satisfy expected Treasury withdrawals.

### 10.2 Lagoon strategy adapter — Vesper as a depositor
`vesper-strategies/contracts/strategies/lagoon/LagoonV05.sol` / `LagoonV06.sol` (extending `LagoonBase.sol`) deposit the strategy's assets **into a Lagoon vault** via the ERC-7540 async request/claim flow. Here Vetro is a **depositor**, on the other side of the settlement this runbook performs.
- **`rebalance(minProfit, maxLoss)`** — sweeps matured claimables, reports profit/loss to the pool, then either queues a redeem (if the pool wants capital back) or deposits idle into the Lagoon vault.
- `requestDeposit` / `requestRedeem` — queue async requests that **only complete once the Lagoon curator settles** (§4.4).
- `processAllClaimable` / `processClaimableDeposits` / `processClaimableRedeems` — claim settled requests, with slippage floors.
- `cancelDeposit` / (V06) `cancelRedeem` — pull a request from the Silo before the curator settles it.
- (V06) `instantRedeem(shares, minAssets)` — emergency sync redeem; incurs exit fee **plus** a haircut (up to ~20%). Emergency-only.
- `tvl() = idle + pendingDeposit + claimableDeposit + assetsInVault + pendingRedeem + claimableRedeem`; `instantLiquidity() = idle + claimableRedeem` only — on-chain confirmation the strategy is illiquid between settlements.

**V05 vs V06 deltas:** allow-check `isWhitelisted()` → `isAllowed()`; V06 adds frozen per-batch entry/exit fees, `instantRedeem()`, `cancelRedeem()`, and a permanent `isAsyncOnly()` lock.

### 10.3 The full yield cycle back to stakers
1. Lagoon vault earns on Base → Valuation Provider posts higher NAV → Curator settles (§4) → Lagoon share price rises.
2. Lagoon strategy reports the gain to the Yield Vault via `rebalance → reportEarning` → Yield Vault `pricePerShare` rises, performance fee taken.
3. Treasury holds Yield Vault shares, so `Treasury.reserve()` now exceeds backed supply.
4. **Harvest** (`UMM_ROLE`): `Treasury.harvest(token, receiver)` extracts the excess.
5. Convert via the Gateway and `YieldDistributor.distribute(amount)` (`DISTRIBUTOR_ROLE`) drips it (~7 days) into the StakingVault, raising sVUSD / svetBTC value for stakers.

See [OPERATIONS.md](./OPERATIONS.md) for the harvest workflow, addresses, and roles for these layers.
