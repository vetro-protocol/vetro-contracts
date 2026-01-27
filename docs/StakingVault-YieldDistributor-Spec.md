# Staking Vault & Yield Distributor

## Product Overview

A secure staking system that allows users to stake tokens and earn yield, with built-in protections against market manipulation.

---

## Staking Vault

### What It Does
Users deposit tokens (e.g., VUSD, VcETH, vcWBTC) and receive vault shares representing their stake. As yield is distributed, the value of each share increases, allowing users to withdraw more than they deposited.

### Key Features

| Feature | Description |
|---------|-------------|
| **Deposit & Earn** | Users deposit tokens and automatically earn yield over time |
| **Share-Based Accounting** | Users receive shares proportional to their deposit; share value grows as yield accrues |
| **Cooldown Withdrawals** | 7-day waiting period for withdrawals to prevent market manipulation |
| **Multiple Requests** | Users can have multiple pending withdrawal requests simultaneously |
| **Batch Claims** | Claim multiple matured requests in a single transaction |
| **Delegated Withdrawals** | Approve third parties (protocols, bots) to request withdrawals on your behalf |
| **Instant Withdraw Whitelist** | Trusted partners/protocols can bypass the cooldown |
| **Emergency Functions** | Users can still exit even if drip systems have issues |
| **Cancel Requests** | Users can cancel pending withdrawals and return to earning yield |

### Withdrawal Process

```
1. User requests withdrawal → Shares burned, assets locked
2. 7-day cooldown period → Assets do NOT earn yield during this time
3. After cooldown → User claims their assets
```

### Multiple Withdrawal Requests

Users can create **multiple simultaneous withdrawal requests**, each tracked independently:

| Capability | Description |
|------------|-------------|
| **Parallel Requests** | Create new withdrawal requests while others are pending |
| **Independent Tracking** | Each request has unique ID, amount, and maturity time |
| **Flexible Claims** | Claim individual requests or batch claim multiple at once |
| **Partial Cancellation** | Cancel specific requests without affecting others |
| **Query Functions** | View all pending and claimable requests for any account |

**Example Flow:**
```
Day 1: Request #1 → 1000 tokens (claimable Day 8)
Day 3: Request #2 → 500 tokens  (claimable Day 10)
Day 5: Request #3 → 750 tokens  (claimable Day 12)
Day 8: Claim Request #1 → Receive 1000 tokens
       Requests #2 and #3 still pending
```

### Approval & Allowance (Delegated Operations)

The vault supports **ERC20 approval/allowance** for delegated withdrawals:

| Function | Description |
|----------|-------------|
| `approve(spender, amount)` | Allow spender to use up to `amount` of your shares |
| `allowance(owner, spender)` | Check how many shares spender can use on owner's behalf |

**Use Cases:**
- **Smart Contract Integration**: Allow protocols to manage withdrawals on user's behalf
- **Automation**: Permit keeper bots to execute withdrawals when conditions are met
- **Account Abstraction**: Enable gasless withdrawal requests via relayers

**Delegated Withdrawal Flow:**
```
1. User approves Protocol Contract for 1000 shares
2. Protocol calls requestRedeem(1000, userAddress) using allowance
3. User's shares are burned, cooldown request created
4. After cooldown, user (or anyone) can claim to user's chosen receiver
```

### Configurable Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| Cooldown Duration | 7 days | 1-30 days | Waiting period for withdrawals |
| Cooldown Enabled | Yes | Yes/No | Can disable for all users |
| Instant Whitelist | Per-address | - | Bypass cooldown for trusted addresses |

---

## Yield Distributor

### What It Does
Manages yield distribution to the Staking Vault using a "drip" mechanism that releases yield gradually over time, preventing sudden price spikes that could be exploited.

### Key Features

| Feature | Description |
|---------|-------------|
| **Linear Drip Distribution** | Yield is released steadily over 7 days (configurable) |
| **Anti-Manipulation** | Prevents "sandwich attacks" where attackers exploit sudden yield additions |
| **Accumulating Yield** | New yield is added to remaining undistributed yield |
| **Role-Based Access** | Only authorized distributors can add yield |
| **Secure Admin Transfer** | 3-day delay for admin changes (safety mechanism) |

### How Yield Distribution Works

```
Day 0: 70 tokens distributed → 10 tokens/day drip rate
Day 3: User deposits → Triggers yield pull, vault receives ~30 tokens
Day 3: Another 70 tokens distributed → Combines with remaining 40 tokens
       New total: 110 tokens over 7 days = ~15.7 tokens/day
```

### Configurable Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| Yield Duration | 7 days | 1+ days | Period over which yield is distributed |
| Admin Transfer Delay | 3 days | Fixed | Safety delay for changing admin |

---

## Security Features

### Built-in Protections
- **Sandwich Attack Prevention**: Cooldown + drip distribution eliminates front-running opportunities
- **Reentrancy Protection**: All user-facing functions protected against reentrancy attacks  
- **Upgradeable**: Contracts can be upgraded to fix issues or add features
- **Role Separation**: Different roles for distribution vs. administration
- **Emergency Exits**: Users can withdraw even if yield systems fail

### Access Control

| Role | Staking Vault | Yield Distributor |
|------|---------------|-------------------|
| Owner/Admin | Configure settings, whitelist | Configure duration, rescue tokens |
| Distributor | - | Add yield to be distributed |
| Users | Deposit, withdraw, request cooldown | - |
| Vault | - | Pull accrued yield |

---

## User Journey

### Staking Flow (Direct)
1. **Approve** tokens for the vault
2. **Deposit** tokens → Receive vault shares
3. **Hold** shares → Value grows as yield accrues
4. **Request Withdrawal** → Start 7-day cooldown (can create multiple requests)
5. **Claim** → Receive tokens after cooldown (single or batch claim)

### Staking Flow (Delegated)
1. **Approve** vault shares for a protocol/bot
2. Protocol calls **Request Withdrawal** on user's behalf (using allowance)
3. User waits for 7-day cooldown
4. User or protocol **Claims** tokens to user's chosen receiver

### Yield Distribution Flow
1. Protocol earns yield from external sources
2. Authorized distributor sends yield to Yield Distributor
3. Yield drips linearly to vault over 7 days
4. Users' share value increases proportionally

---

## Use Cases

| Token | Vault Name | Share Token | Description |
|-------|------------|-------------|-------------|
| VUSD | Staked VUSD | sVUSD | Stablecoin yield vault |
| VcETH | Staked VcETH | sVcETH | ETH yield vault |
| vcWBTC | Staked vcWBTC | sVcWBTC | BTC yield vault |

---

## Key Metrics to Track

- Total Value Locked (TVL)
- Share Price (Assets per Share)
- Total Assets in Cooldown
- Pending Yield Available
- Active Withdrawal Requests
- Yield Distribution Rate
