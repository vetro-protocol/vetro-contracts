# Vetro Protocol - Operations Runbook

Manual operations guide for the devops team until automation bots are ready.

## Deployed Contracts (Ethereum Mainnet)

| Contract          | Address                                      | Type        |
|-------------------|----------------------------------------------|-------------|
| VUSD       | `0xB94724aa74A0296447D13a63A35B050b7F137C6d` | Non-upgradeable |
| Treasury          | `0x2bC90279d0f776c915A235791F8B1180B1ecBF86` | Non-upgradeable |
| Gateway           | `0x3B677f95A3B340A655Cd39a13FC056F625bB9492` | UUPS Proxy  |
| StakingVault      | `0x4a16B99f23c5511f0A23EF9770Bf4ab28f37D830` | UUPS Proxy  |
| YieldDistributor  | `0x2AD3e2853910De6B9c12300951e233A764121Dc2` | UUPS Proxy  |

### Whitelisted Collateral Tokens

| Token | Address | Yield Vault | Oracle (Chainlink) | Stale Period |
|-------|---------|-------------|--------------------|----|
| USDC  | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x8C78D34176C971114151a9d5Dd2DBad1e6F30811` | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | 24h |
| USDT  | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `0x3D58BcCFDb150ad4689b04b9Dfdfb149038C1377` | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | 24h |

### Governance

| Role | Address |
|------|---------|
| Owner / DEFAULT_ADMIN | `0xE173b056eF552c7322040703dDfC1e0638A575d3` |

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
- Current setting: 7 days

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

- Maximum total VUSD that can be minted via user deposits
- Current: 100M

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

## Monitoring Checklist

### Daily Checks

| Check | How | Alert If |
|-------|-----|----------|
| Oracle freshness | `Treasury.getPrice(token)` - should not revert with StalePrice | Reverts |
| Treasury reserve vs supply | `Treasury.reserve()` vs `VUSD.totalSupply()` | Reserve < supply (undercollateralized) |
| Yield Vault health | `YieldVault.pricePerShare()` | Decreasing (loss event) |
| Pending yield | `YieldDistributor.pendingYield()` | Large unclaimed amount building up |
| Gateway mint capacity | `Gateway.maxMint()` | Near zero (approaching mint limit) |
| Withdrawable liquidity | `Treasury.withdrawable(token)` per token | Near zero (low liquidity for redemptions) |

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
2. If vault also lacks liquidity, the Yield Vault will unwind from strategies automatically during withdrawal

### Compromised Address
1. **Owner**: Blacklist the address on VUSD
   ```
   VUSD.addToBlacklist(address)
   ```
2. **DEFAULT_ADMIN**: Revoke any roles the address holds
   ```
   Treasury.revokeRole(role, address)
   YieldDistributor.revokeRole(role, address)
   ```
