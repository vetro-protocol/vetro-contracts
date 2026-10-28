# Vetro Protocol - Operations Runbook

Manual operations guide for the devops team until automation bots are ready.

> **Curators:** for the end-to-end view of how treasury collateral flows into Vesper Yield
> vaults and Lagoon vaults — including how to update valuations, perform Lagoon settlement,
> assign strategy weights, and keep a redemption buffer ready in the Safe — see the
> [**Curator Handbook**](./CURATOR_HANDBOOK.md).

Vetro currently operates two parallel deployments on Ethereum mainnet: the USD-pegged stablecoin
(**VUSD**) and the BTC-pegged token (**vetBTC**). Each has its own Gateway, Treasury,
StakingVault, and YieldDistributor. All contract APIs are identical — operators perform the
same actions on either system; the only differences are addresses and per-token settings.

Canonical addresses live in the latest release manifest under [`releases/vusd/`](../releases/vusd/) (VUSD) and
[`releases/vetbtc/`](../releases/vetbtc/) (vetBTC). The tables below mirror those files.

## VUSD - Ethereum Mainnet

| Contract            | Address                                      | Type            |
|---------------------|----------------------------------------------|-----------------|
| VUSD (PeggedToken)  | `0xCa83DDE9c22254f58e771bE5E157773212AcBAc3` | Non-upgradeable |
| Treasury            | `0xC8317A10385BE07901A4c9ee3d06E1D83AE378c9` | Non-upgradeable |
| Gateway             | `0xDaD503f8B9d42bb7af3AfC588358D30163e4416F` | TUP Proxy       |
| Gateway impl        | `0x7AFcFcC9619272B4610dDB1E98e6f0cF8E765C81` | -               |
| StakingVault (sVUSD)| `0x476310E34D2810f7d79C43A74E4D79405bd7a925` | TUP Proxy       |
| YieldDistributor    | `0x55745265Ba172378cf45d224F09F0673cB470cef` | TUP Proxy       |

### VUSD Whitelisted Collateral

| Token | Address | Yield Vault | Oracle (Chainlink) | Stale | pegBand |
|-------|---------|-------------|--------------------|-------|---------|
| USDC  | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0xe3DA4B83C9dd4c4D185ecE42077462b3F35c454a` | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | 24h | 3 bps |
| USDT  | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `0x6d134cAAD0CA29Cd6ea145f6C0DC766076690547` | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | 24h | 3 bps |

### VUSD Live Settings

| Parameter | Value |
|-----------|-------|
| `mintLimit` | 100,000,000 VUSD |
| `withdrawalDelay` | 120 seconds (2 min) |
| `priceTolerance` | 100 bps (1%) |
| `mintFee` / `redeemFee` | 0 bps on all tokens |
| `pegBand` | 3 bps on USDC and USDT |

---

## vetBTC - Ethereum Mainnet

| Contract               | Address                                      | Type            |
|------------------------|----------------------------------------------|-----------------|
| vetBTC (PeggedToken)   | `0xf196C68233464A16CFDa319a47c21f4cECa62001` | Non-upgradeable |
| VetBTCTreasury         | `0xd25a7b0b817fD816d0995eC67fb70e75EE65Bd7F` | Non-upgradeable |
| VetBTCGateway          | `0xCBA2Ffa0AC52d7871a4221a871793Eb788013faB` | TUP Proxy       |
| VetBTCGateway impl     | `0xd1C374C6FDCdDF77923118dC15D66aB13289A5Cf` | -               |
| StakingVault (svetBTC) | `0x0cB9D84d4bcEc8d3D5B2d99a6F07f4605325987e` | TUP Proxy       |
| VetBTCYieldDistributor | `0xd74bcf1299176E98899bA2e86dD2C9aE089F5276` | TUP Proxy       |
| FixedPriceFeedAdapter (WBTC/BTC) | `0x032A35daDA672B394525881f789a3B4E7734C76C` | Adapter |
| DerivedPriceFeedAdapter (cbBTC/BTC) | `0x33F1E44DB47400C9BD6221962712D882Adb8fFA6` | Adapter |

### vetBTC Whitelisted Collateral

| Token   | Address                                      | Yield Vault                                  | Oracle (BTC denom)                           | Oracle dec. | Stale | pegBand |
|---------|----------------------------------------------|----------------------------------------------|----------------------------------------------|---|-------|---------|
| WBTC    | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | `0x30c410D92e54B2b492D725D6CEBed98891817C91` | `0x032A35daDA672B394525881f789a3B4E7734C76C` (Fixed 1.0) | 8  | 24h | 0 bps |
| cbBTC   | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | `0xD954d72D885f8409bCBe3f15ad2fc3EcA4a5Ba33` | `0x33F1E44DB47400C9BD6221962712D882Adb8fFA6` (Derived cbBTC/USD÷BTC/USD) | 8  | 24h | 0 bps |
| hemiBTC | `0x06ea695B91700071B161A434fED42D1DcbAD9f00` | `0x54b8a87c9f85Dd2515CaAE1fad2dd85199900076` | `0x7Ff41654D1551F01E622e2b1050EA027a3A6C9dc` (Chainlink HEMIBTC/BTC) | 18 | 24h | 0 bps |

Note: the hemiBTC yield vault is a `WhitelistedYieldVault`. Before the Treasury can deposit
hemiBTC into the vault, the vault owner must call `addToWhitelist(VetBTCTreasury)` on the
vault. Without this, every deposit reverts with `CallerIsNotWhitelisted`.

### vetBTC Live Settings

| Parameter | Value |
|-----------|-------|
| `mintLimit` | 1,320 vetBTC (~$100M at $75k/BTC) |
| `withdrawalDelay` | 120 seconds (2 min) |
| `priceTolerance` | 200 bps (2%) |
| `mintFee` / `redeemFee` | 0 bps on all tokens |
| `pegBand` | 0 bps on WBTC, cbBTC, hemiBTC |

---

### Governance (both deployments)

| Role | Address |
|------|---------|
| Owner / DEFAULT_ADMIN (VetBTCTreasury, on-chain today) | `0xE173b056eF552c7322040703dDfC1e0638A575d3` |
| Owner / DEFAULT_ADMIN (VUSD Treasury, on-chain today)  | `0x6649Ddb5c7e52348b73c8bBdD2A1cbA630b7AaEA` |
| hemiBTC Vault owner (controls vault caller-whitelist)   | `0x26D4333E2E5572A5609ddEDd65748F8F237042D9` |

---

## Roles Overview

All roles for Gateway and Treasury operations are managed on the **Treasury** contract via `grantRole` / `revokeRole`. Gateway delegates role checks to Treasury.

| Role | Constant | Managed On | Purpose |
|------|----------|------------|---------|
| DEFAULT_ADMIN_ROLE | `0x00` | Treasury, YieldDistributor | Protocol governance: whitelist tokens, set limits, migrate |
| MAINTAINER_ROLE | `keccak256("MAINTAINER_ROLE")` | Treasury | Configuration: fees, oracles, whitelists, withdrawal settings |
| KEEPER_ROLE | `keccak256("KEEPER_ROLE")` | Treasury | Vault operations: push/pull, pause/unpause, swap |
| UMM_ROLE | `keccak256("UMM_ROLE")` | Treasury | AMO operations: mint/burn VUSD, harvest yield |
| DISTRIBUTOR_ROLE | `keccak256("DISTRIBUTOR_ROLE")` | YieldDistributor | Distribute yield to StakingVault |
| Owner (Ownable2Step) | N/A | VUSD, StakingVault | Blacklist, cooldown config, vault rewards |

---

## Operations by Role

### 1. KEEPER_ROLE Operations (Treasury)

#### 1.1 Push Tokens to Yield Vault

Deposits idle collateral from Treasury into the Yield Vault to earn yield.

```
Treasury.push(address token_, uint256 amount_)
```

- `amount_` = 0 sends the entire Treasury balance of that token
- Call when Treasury has idle collateral that should be earning yield
- **When**: After user deposits accumulate in Treasury

#### 1.2 Pull Tokens from Yield Vault

Withdraws collateral from Yield Vault back to Treasury for user redemptions.

```
Treasury.pull(address token_, uint256 amount_)
```

- Call when Treasury want to keep some fund idle in vault. Insufficient fund in vault does not block any redeem operation because when fund not in treasury, redeem function triggers withdraw from vaults.

#### 1.3 Pause/Unpause Deposits

```
Treasury.setDepositActive(address token_, bool active_)
```

- Set `active_ = false` to pause deposits for a token
- **When**: Oracle issues, depegs, emergency scenarios

#### 1.4 Pause/Unpause Withdrawals

```
Treasury.setWithdrawActive(address token_, bool active_)
```

- Set `active_ = false` to pause withdrawals for a token
- **When**: Liquidity issues, oracle failures, emergency scenarios

#### 1.5 Swap Non-Reserved Tokens

```
Treasury.swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_)
```

- Swaps tokens via the configured swapper contract
- Cannot swap whitelisted collateral tokens or vault share tokens
- **When**: Reward tokens or airdropped tokens need to be converted

---

### 2. UMM_ROLE Operations (Gateway + Treasury)

#### 2.1 Mint VUSD for AMO

```
Gateway.mintToAMO(uint256 amount_, address receiver_)
```

- Mints VUSD without collateral for AMO (market-making) operations
- Limited by `amoMintLimit` (check `Gateway.maxAmoMint()` for remaining capacity)
- **When**: Providing liquidity to DEX pools or lending markets

#### 2.2 Burn VUSD from AMO

```
Gateway.burnFromAMO(uint256 amount_)
```

- Burns VUSD from caller's balance, reducing AMO supply
- Cannot burn more than current `amoSupply`
- **When**: Removing AMO liquidity, reducing outstanding AMO-minted supply

#### 2.3 Harvest Excess Yield from Treasury

```
Treasury.harvest(address token_, address receiver_)
```

- Withdraws excess reserves (reserve value - total VUSD supply) as profit
- Only available when reserve exceeds backed supply
- Returns the amount harvested
- **When**: After vault yield has been realized (see Yield Harvesting Workflow below)

---

### 3. DISTRIBUTOR_ROLE Operations (YieldDistributor)

#### 3.1 Distribute Yield to StakingVault

```
YieldDistributor.distribute(uint256 amount_)
```

- Caller must have VUSD balance >= `amount_` and approve YieldDistributor
- Yield is dripped linearly over `yieldDuration` (default 7 days)
- If called during an active period, remaining undistributed yield is combined with new amount
- **When**: After harvesting excess from Treasury (see Yield Harvesting Workflow)

---

### 4. MAINTAINER_ROLE Operations (Gateway + Treasury)

#### 4.1 Update Mint Fee (per token)

```
Gateway.updateMintFee(address token_, uint256 newMintFee_)
```

- Fee in basis points (1 BPS = 0.01%), max 500 BPS (5%)
- Token must be whitelisted in Treasury
- Default is 0 for new tokens

#### 4.2 Update Redeem Fee (per token)

```
Gateway.updateRedeemFee(address token_, uint256 newRedeemFee_)
```

- Fee in basis points, max 500 BPS (5%)
- Token must be whitelisted in Treasury

#### 4.3 Manage Instant Redeem Whitelist

```
Gateway.addToInstantRedeemWhitelist(address account_)
Gateway.removeFromInstantRedeemWhitelist(address account_)
```

- Whitelisted addresses bypass the withdrawal delay period
- **When**: Granting institutional partners instant redemption access

#### 4.4 Toggle Withdrawal Delay

```
Gateway.setWithdrawalDelayEnabled(bool enabled_)
```

- When disabled, all users can redeem instantly (no delay)
- When enabled, non-whitelisted users must use `requestRedeem` + wait + `redeem`

#### 4.5 Update Withdrawal Delay Period

```
Gateway.updateWithdrawalDelay(uint256 newDelay_)
```

- Must be > 0 and <= 30 days
- Current setting: 120 seconds (both VUSD and vetBTC)

#### 4.6 Update Oracle

```
Treasury.updateOracle(address token_, address oracle_, uint256 newStalePeriod_)
```

- Stale period: > 0 and <= 72 hours
- **When**: Oracle migration, adjusting freshness requirements

#### 4.7 Update Price Tolerance

```
Treasury.updatePriceTolerance(uint256 newPriceTolerance_)
```

- In BPS, max 10000 (100%)
- Default: 100 (1%). Prices outside 1 +/- tolerance will revert

#### 4.8 Update Swapper

```
Treasury.updateSwapper(address swapper_)
```

- Sets the address used for `Treasury.swap()` calls

---

### 5. DEFAULT_ADMIN_ROLE Operations

#### 5.1 Whitelist a New Collateral Token

```
Treasury.addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_)
```

- Max 10 whitelisted tokens
- Token decimals must be <= 18
- Vault's asset must match the token
- Stale period: > 0 and <= 72 hours

#### 5.2 Remove Collateral Token

```
Treasury.removeFromWhitelist(address token_)
```

- Vault balance must be 0 first (pull all assets back to Treasury, then withdraw all)

#### 5.3 Update Mint Limit

```
Gateway.updateMintLimit(uint256 newMintLimit_)
```

- Maximum total PeggedToken that can be minted via user deposits
- Current: VUSD = 100M; vetBTC = 1,320 (~$100M)

#### 5.4 Update AMO Mint Limit

```
Gateway.updateAmoMintLimit(uint256 newAmoMintLimit_)
```

- Must be >= current `amoSupply` (cannot reduce below outstanding AMO supply)

#### 5.5 Update Peg Band (per token)

```
Gateway.updatePegBand(address token_, uint256 newPegBandBps_)
```

- Must be less than Treasury's `priceTolerance`
- When price is within peg band, deposit/redeem uses 1:1 rate
- When outside peg band, uses oracle price (discount/premium)

#### 5.6 Migrate Treasury

```
Treasury.migrate(address newTreasury_)
```

- Transfers all tokens and vault shares to new Treasury
- New Treasury must have same VUSD configured
- **Irreversible** - use with extreme caution

#### 5.7 Sweep Non-Reserved Tokens

```
Treasury.sweep(address fromToken_, address receiver_)
```

- Sends non-whitelisted, non-vault-share tokens to receiver
- Cannot sweep reserved tokens

#### 5.8 Rescue Tokens from YieldDistributor

```
YieldDistributor.rescueTokens(address token_, address to_, uint256 amount_)
```

- Cannot rescue the distribution asset (VUSD)
- For recovering accidentally sent tokens

#### 5.9 Update Yield Duration

```
YieldDistributor.updateYieldDuration(uint256 duration_)
```

- Minimum 1 day, no maximum
- Affects future distributions only (not the active period)

---

### 6. Owner Operations (VUSD)

#### 6.1 Blacklist Management

```
VUSD.addToBlacklist(address account_)
VUSD.removeFromBlacklist(address account_)
```

- Blacklisted addresses cannot send or receive VUSD
- The blacklist also applies to the staking vault that holds the token (sVUSD for VUSD, sVETBTC for vetBTC). A blacklisted
  address cannot transfer, receive, deposit, redeem or withdraw vault shares, and cannot open, cancel or claim cooldown
  requests. Its staked position and pending requests are frozen, not seized. Removing the address from the blacklist
  restores all of these actions.
- A blacklisted address cannot claim a Gateway redeem request, even one that has already matured. The locked tokens
  stay in the Gateway until the address is removed from the blacklist. Cancelling the request also reverts, because the
  token's transfer check blocks the refund.

#### 6.2 Update Gateway/Treasury References

```
VUSD.updateTreasury(address newTreasury_)
VUSD.updateGateway(address newGateway_)
```

- Treasury must be set before Gateway can be set

---

### 7. Owner Operations (StakingVault)

#### 7.1 Cooldown Configuration

```
StakingVault.updateCooldownDuration(uint256 duration_)  // min 1 day, max 30 days
StakingVault.updateCooldownEnabled(bool enabled_)
```

#### 7.2 Instant Withdraw Whitelist

```
StakingVault.updateInstantWithdrawWhitelist(address account_, bool status_)
```

#### 7.3 Update Vault Rewards / Yield Distributor

```
StakingVault.updateVaultRewards(address vaultRewards_)
StakingVault.updateYieldDistributor(address distributor_)
```

---

## Yield Harvesting Workflow

This is the end-to-end process to realize yield from strategies and distribute it to StakingVault holders.

### Architecture

```
Yield Vault (ERC4626)
  |-- Strategy 1 (e.g., ERC4626Vault strategy)
  |-- Strategy 2
  ...
Treasury holds Yield Vault shares
StakingVault holders receive yield via YieldDistributor
```

### Step-by-Step Process

#### Step 1: Rebalance Strategies (on Yield Vault)

**Who**: Keeper (on the Strategy contract, not the Treasury KEEPER_ROLE)
**Contract**: Each Strategy contract (e.g., ERC4626Vault strategy)

```
Strategy.rebalance(uint256 minProfit_, uint256 maxLoss_)
```

What happens:
1. Strategy calculates profit/loss by comparing actual collateral vs tracked debt
2. Strategy withdraws profit from the underlying protocol if needed
3. Strategy calls `YieldVault.reportEarning(profit, loss, payback)` on the vault
4. Vault takes a performance fee (mints shares to feeCollector)
5. Vault settles assets: strategy sends profit + payback, receives new credit line
6. Strategy reinvests remaining idle collateral

**Result**: Yield Vault's `pricePerShare` increases, meaning Treasury's vault shares are now worth more collateral.

**When to call**: Periodically (e.g., daily or weekly) to realize accumulated yield from underlying protocols. Can also be called when there is known yield to capture.

**Verification after rebalance**:
```solidity
// Check the Yield Vault's price per share increased
YieldVault.pricePerShare()  // should be > previous value

// Check Treasury's reserve increased
Treasury.reserve()  // should be > total VUSD supply if there is excess
```

#### Step 2: Harvest Excess from Treasury

**Who**: UMM_ROLE
**Contract**: Treasury

```
Treasury.harvest(address token_, address receiver_)
```

- `receiver_` should be the address that will distribute yield (an address with DISTRIBUTOR_ROLE on YieldDistributor)
- Only works when `Treasury.reserve() > VUSD.totalSupply()`
- Returns the excess collateral tokens (e.g., USDC)

**Prerequisite**: The Yield Vault's `pricePerShare` must have increased (Step 1 completed), causing Treasury's reserve value to exceed the backed VUSD supply.

**Verification**:
```solidity
// Before harvest, check there is excess
Treasury.reserve()        // e.g., 10,050,000 (in 18 decimals)
VUSD.totalSupply() // e.g., 10,000,000
// Excess = 50,000 available for harvest
```

#### Step 3: Convert Harvested Tokens to VUSD

The harvested tokens (e.g., USDC) need to be converted to VUSD before distribution to StakingVault holders.

**Who**: Any address (no role required)
**Contract**: Gateway

```
// Approve Gateway to spend the harvested tokens
IERC20(token).approve(Gateway, amount)

// Deposit to get VUSD
Gateway.deposit(address token_, uint256 amount_, uint256 minVUSDOut_, address receiver_)
```

- Set `receiver_` to the address that will call `distribute`

#### Step 4: Distribute Yield to StakingVault

**Who**: DISTRIBUTOR_ROLE
**Contract**: YieldDistributor

```
// Approve YieldDistributor to spend VUSD
VUSD.approve(YieldDistributor, amount)

// Distribute - yield drips linearly over yieldDuration (default 7 days)
YieldDistributor.distribute(uint256 amount_)
```

**Result**: StakingVault's `totalAssets()` gradually increases over the yield duration as `pullYield()` is called automatically on every deposit/withdraw/requestRedeem operation on StakingVault.

**Verification**:
```solidity
YieldDistributor.pendingYield()    // shows currently accrued but not yet pulled yield
YieldDistributor.rewardRate()      // tokens per second (scaled by 1e18)
YieldDistributor.periodFinish()    // when current distribution period ends
StakingVault.totalAssets()         // should gradually increase
```

### Complete Workflow Summary

```
1. Keeper calls Strategy.rebalance()         --> Yield Vault pricePerShare increases
2. UMM calls Treasury.harvest(token, self)   --> Excess collateral sent to UMM
3. UMM deposits harvested tokens via Gateway --> Gets VUSD
4. Distributor calls YieldDistributor.distribute(amount)  --> Yield drips to StakingVault over 7 days
```

### Frequency Recommendations

| Operation | Frequency | Trigger Condition |
|-----------|-----------|-------------------|
| Strategy rebalance | Daily to weekly | When underlying protocol has accumulated yield |
| Treasury harvest | After each rebalance | When `reserve > totalSupply` |
| YieldDistributor.distribute | After each harvest | When VUSD from harvest is available |
| Treasury.push | As needed | When idle collateral sits in Treasury |
| Treasury.pull | As needed | When it is preferred to keep some asset idle in treasury to avoid pull from strategies |

---

## Upgrading Proxies

Only `Gateway`, `StakingVault` and `YieldDistributor` (and their vetBTC counterparts) are upgradeable. Each sits
behind its own OZ v5 `ProxyAdmin`, owned by the governance Safe. Both stacks upgrade to one shared implementation
per contract (`<Contract>_Implementation`), though the live ones can differ until then: in the 1.1.0 releases VUSD's
`YieldDistributor` runs `0xe8Ac98555f8815F4c125C871F803DFCaD2101886` and vetBTC's runs
`0x4a6e1AcA9fB0A5d428dFac5127C511a9d5723080`.

1. **Check storage compatibility** against the live implementations:

   ```bash
   npx hardhat validate-upgrades --network ethereum
   ```

   This finds the source of each live implementation by recompiling the solc inputs in `deployments/ethereum` and
   matching the bytecode on-chain, then runs OZ's upgrade safety and storage layout checks (including ERC-7201
   namespaces) against this repo's contracts. The deploy scripts run the same check before deploying a new
   implementation.

2. **Dry run on a fork**: deploys as the mainnet deployer, queues the upgrades and config calls in the Safe batch
   and executes it as the impersonated Safe, checks that only implementations changed, and reruns the flow tests
   against the upgraded node. On the fork the batch runs as one tx per call, not atomically through MultiSend:

   ```bash
   ./scripts/test-upgrade-on-fork.sh
   ```

   The Foundry fork tests (`test/fork/Upgrade.fork.t.sol`) also run on their own: `UpgradeStateForkTest` compares
   every stored value (config, whitelists, roles, balances, cooldown requests) before and after an in-test upgrade
   in the same block, and `LiveForkTest` / `UpgradedForkTest` run the user, keeper and integrator flows on both
   stacks before and after.

3. **Deploy** with `npx hardhat deploy --network ethereum`. The storage check runs before each contract's
   implementation is deployed, so a failure on a later contract leaves the earlier implementations deployed: run
   step 1 first. The upgrades are queued and proposed as one Safe batch. If the run fails after queueing any Safe
   tx, `multisig.batch.tmp.json` is left behind and blocks later runs. If only the proposal failed (e.g. the Safe API
   rejected it), check the Safe queue, then propose the batch unchanged with
   `npx hardhat propose-safe-batch --network ethereum`. A run that failed before proposing left an incomplete batch,
   which the task refuses: delete the file and re-run the deploy. The task also refuses a batch built for another
   network, so a leftover mainnet batch can't be rehearsed on a fork first.

4. **After the Safe executes** in block `B`, compare the block before it with block `B` and cut the release:

   ```bash
   npx hardhat upgrade-snapshot --network ethereum --block <B-1> --out before.json
   npx hardhat upgrade-snapshot --network ethereum --block <B> --compare before.json
   npx hardhat create-release --release <version> --notes "<what changed>" --network ethereum
   ```

   Comparing adjacent blocks keeps normal user and keeper activity out of the diff, so the compare can be strict: it
   fails if anything other than implementations changed. Anything else in block `B` shows up as an unexpected change
   and must be explained, including config calls bundled into the same Safe batch (e.g. role grants). Accounts found
   only after the upgrade (e.g. one added to the Gateway whitelist in the batch) are read again at the baseline's
   block, so a role or whitelist entry they gained is a change like any other. The baseline must come from the same
   network and an earlier block. Pass the changes you expect with `--allow`, as comma separated key globs (`*`
   within one key segment, `**` across segments), quoted so the shell leaves them alone:
   `--allow 'vusd.gateway.fees.*.mintFee'`. `ALLOW_CHANGES` does the same for the dry run. Allowed changes are listed
   and do not fail. A glob that matches nothing fails, and nothing can allow a change to a proxy's admin or its
   owner, or a value that starts or stops reverting. Values that move with prices or time (reserve, total assets,
   share price, pending yield) are listed for review. Reading past blocks needs an archive RPC.

   `create-release` writes `releases/<instance>/<network>-<version>.json` for each deployed instance and refuses
   to overwrite an existing version: manifests are immutable. An implementation upgrade is a patch bump. It also
   refuses while an upgrade is still pending in the Safe, so the manifest only records what is live.

---

## Migrating a Treasury

The Treasury is not upgradeable: a change to its code ships as a new Treasury that takes over the collateral.
`09_migrate_treasury.ts` (VUSD) and `vetbtc/10_vetbtc_migrate_treasury.ts` do this, and only when asked to with
`MIGRATE_TREASURY=true`, so a routine deploy never starts a migration.

1. **Dry run on a fork.** Fork with anvil (`--gas-limit 16777216 --base-fee 0 --chain-id 1`: mainnet caps a tx at
   2^24 gas, and the fork's base fee outruns the deploy's fee estimate), copy `deployments/ethereum` to
   `deployments/localhost`, `export DEPLOYER=<deployer address>`, impersonate it, and run step 2 with
   `--network localhost`. The impersonated Safe executes the batch. Then re-run without the flag to verify, and run
   the Foundry fork tests against the node with `ETHEREUM_FORK_NODE_URL=http://127.0.0.1:8545
   ETHEREUM_FORK_BLOCK_NUMBER=0`: they use the Treasury each token points at, so they exercise the new one.

2. **Build the batch**:

   ```bash
   MIGRATE_TREASURY=true npx hardhat deploy --network ethereum \
     --tags MigrateTreasury,MigrateVetBTCTreasury,MultisigTxs
   ```

   Before deploying anything, the script checks that the Safe is the live Treasury's admin, the token's owner and a
   maintainer of every yield vault, that no admin transfer or delay change is pending on the live Treasury, and that
   no batch file is left over. It refuses if this run already queued a call to the live Treasury (it would run before
   the copy and not be in it). The deployer then deploys the compiled Treasury with the live Treasury's admin and
   renounces the KEEPER and MAINTAINER roles its constructor gave it; the live Treasury's record is kept as
   `<alias>_Previous`.

   Everything else is a Safe call, read from the live Treasury and printed as a numbered list:
   - whitelist the new Treasury on each yield vault
   - add each collateral with its live vault, oracle and stale period
   - grant every live role holder (found from `RoleGranted` events, kept only if `hasRole`)
   - copy the price tolerance, swapper and pause flags, granting the Safe a role for the batch only when it needs one
     it does not hold
   - revoke anything the live Treasury does not have
   - `updateTreasury`, then `migrate`
   - remove the old Treasury from each yield vault's whitelist (shares move by plain transfer, so `migrate` does not
     need it)

   The batch is recorded on `<alias>_Previous`. **Execute it as one Safe transaction.** Between `updateTreasury` and
   `migrate` the token points at a Treasury without collateral, and `migrate` reverts until `updateTreasury` has run.

3. **While it is pending**, routine deploys leave `updateTreasury`, the whitelist and the YieldManager scripts alone.
   The migration script rebuilds the batch from live state and **fails if it no longer matches the recorded one**: a
   role revoked or a token paused after the build would be undone by executing it. Run it right before executing:

   ```bash
   npx hardhat deploy --network ethereum --tags MigrateTreasury,MigrateVetBTCTreasury
   ```

   If it fails, reject the proposal and run step 2 again, which rebuilds the batch for the same new Treasury. A
   started admin transfer or admin delay change on the live Treasury cannot be copied, so the script refuses until
   it is completed or cancelled. Do not run `create-release` (it refuses) or cut a release until the batch has
   executed and been verified.

   The check only sees what has executed. Before executing, make sure no Safe tx queued ahead of the batch changes
   the live Treasury, and do not migrate during an incident: the batch would undo a change it does not know about.
   A keeper action after the check is caught by step 4, which is why it follows the execution right away.

4. **Right after the Safe executes**, re-run the deploy without the flag. The migration script finds the block
   `migrate` executed in and compares both Treasuries at that block: collateral list and order, configs, flags,
   tolerance, swapper, admin, admin delay and every role's holders. It checks that the old Treasury held no
   collateral or vault shares right after `migrate` (transfers sent to it later in the block do not count) and that
   each vault whitelisted the new Treasury, then that the vaults no longer whitelist the old one. It fails listing
   every difference. On success it deletes `<alias>_Previous`. Then:
   - commit the artifacts (git keeps the deleted `_Previous` record)
   - update the Treasury addresses in this file and in `test/helpers/Address.ethereum.sol`
   - repoint keeper bots and monitoring at the new Treasury
   - cut a release (major bump)

   If it reports a difference, the batch undid a change made on the old Treasury, typically a keeper pause right
   before execution: apply the change again on the new Treasury, whose role holders are the old one's. A change made
   on either Treasury later in the migration's own block also shows up as a difference, and stays one, since that
   block never changes. Once every reported difference is explained or applied again, delete
   `<alias>_Previous.json` by hand and commit.

5. **To abandon a pending migration** (never executed, e.g. the Treasury code changed and the script now refuses to
   rebuild), copy `<alias>_Previous.json` back over `<alias>.json`, remove its `linkedData` field, and delete
   `<alias>_Previous.json`. Then reject the Safe proposal. The abandoned Treasury holds nothing and no roles but the
   Safe's admin, so it can stay.

---

## Monitoring Checklist

### Daily Checks

| Check | How | Alert If |
|-------|-----|----------|
| Oracle freshness | `Treasury.getPrice(token)` - should not revert with StalePrice | Reverts |
| Treasury reserve vs supply | `Treasury.reserve()` vs `VUSD.totalSupply()` | Reserve < supply (undercollateralized) |
| Yield Vault health | `YieldVault.pricePerShare()` | Decreasing (loss event) |
| Pending yield | `YieldDistributor.pendingYield()` | Large unclaimed amount building up |
| Gateway mint capacity | `Gateway.maxMint()` | Near zero (approaching mint limit) |
| Withdrawable liquidity | Simulate `Treasury.withdraw(token, amount, receiver)` per token with `eth_call` from the Gateway (`cast call <treasury> "withdraw(address,uint256,address)" <token> <amount> <receiver> --from <gateway>`). `Treasury.withdrawable(token)` is book value, not what the vault can pay at once | Reverts for a normal redemption size |

### Weekly Checks

| Check | How | Alert If |
|-------|-----|----------|
| AMO supply | `Gateway.amoSupply()` vs `Gateway.amoMintLimit()` | Approaching limit |
| Yield distribution period | `YieldDistributor.periodFinish()` | Period ended with no new distribution |
| StakingVault share price | `StakingVault.convertToAssets(1e18)` | Not increasing over time |
| Pending redeem requests | `Gateway.getRedeemRequest(user)` for known users | Old unclaimed requests |

---

## Emergency Procedures

### Oracle Failure
1. **KEEPER**: Pause deposits and withdrawals for affected token
   ```
   Treasury.setDepositActive(token, false)
   Treasury.setWithdrawActive(token, false)
   ```
2. **MAINTAINER**: Update oracle once replacement is available
   ```
   Treasury.updateOracle(token, newOracle, stalePeriod)
   ```
3. **KEEPER**: Re-enable deposits/withdrawals
   ```
   Treasury.setDepositActive(token, true)
   Treasury.setWithdrawActive(token, true)
   ```

### Depeg Event
1. **KEEPER**: Pause deposits for the depegging token
2. **MAINTAINER**: Adjust peg band if needed
   ```
   Gateway.updatePegBand(token, newBandBps)
   ```
3. Monitor oracle price and re-enable when stable

### Liquidity Crunch (When strategies of vault can not perform instant withdraw. For example, async withdraw vault)
1. **KEEPER**: Pull tokens from vault to Treasury
   ```
   Treasury.pull(token, amount)
   ```
2. The Yield Vault pulls from strategies during a withdrawal, but only what they can return at once. If idle plus that falls short, the withdrawal reverts with `AssetsCanNotBeWithdrawn`, even when `Gateway.maxWithdraw(token)` shows more

### Compromised Address
1. **Owner**: Blacklist the address on VUSD (and/or vetBTC). This also freezes its staked shares and cooldown requests
   in the matching staking vault (see 6.1).
   ```
   VUSD.addToBlacklist(address)
   ```
2. **DEFAULT_ADMIN**: Revoke any roles the address holds
   ```
   Treasury.revokeRole(role, address)
   YieldDistributor.revokeRole(role, address)
   ```
