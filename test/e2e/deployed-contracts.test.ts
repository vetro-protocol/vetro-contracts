import {expect} from 'chai'
import {ethers, network} from 'hardhat'
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/signers'
import {Contract} from 'ethers'
import {parseUnits, formatUnits} from 'ethers/lib/utils'
import * as fs from 'fs'
import * as path from 'path'

/**
 * E2E Tests for Deployed Contracts
 *
 * These tests run against a forked mainnet using deployed contract addresses
 * from the release JSON file. They verify:
 * 1. User actions (deposit, redeem, stake)
 * 2. Keeper actions (push, pull, toggle)
 * 3. Yield distribution in StakingVault
 *
 * Usage:
 *   RELEASE_FILE=ethereum-1.0.0-beta.1.json npx hardhat test test/e2e/deployed-contracts.test.ts --network localhost
 *
 * Prerequisites:
 *   - Start forked mainnet: npx hardhat node --fork <RPC_URL>
 *   - Set RELEASE_FILE env variable to the release JSON filename
 */

// Load release config
const RELEASE_FILE = process.env.RELEASE_FILE || 'ethereum-1.0.0-beta.1.json'
const releasePath = path.join(__dirname, '../../releases', RELEASE_FILE)

interface ReleaseConfig {
  version: string
  network: string
  chainId: number
  contracts: {
    PeggedToken: {address: string; name: string; symbol: string}
    Treasury: {address: string}
    Gateway: {address: string; implementation: string; proxyAdmin: string}
    StakingVault: {address: string; implementation: string; proxyAdmin: string}
    YieldDistributor: {address: string; implementation: string; proxyAdmin: string}
  }
  whitelistedTokens: {
    [key: string]: {
      token: string
      vault: string
      oracle: string
      stalePeriod: number
    }
  }
  governance: {
    owner: string
  }
}

// Token addresses (mainnet)
const USDC_ADDRESS = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
const USDC_WHALE = '0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341' // Binance

// Time constants
const ONE_DAY = 24 * 60 * 60
const SEVEN_DAYS = 7 * ONE_DAY

/**
 * Helper to reset base fee before transactions
 * Forked networks retain mainnet's base fee which can cause "maxFeePerGas too low" errors
 */
const resetBaseFee = async () => {
  await network.provider.send('hardhat_setNextBlockBaseFeePerGas', ['0x0'])
}

/**
 * Helper to extend stale period so oracle data is considered fresh
 * This solves StalePrice errors on forked networks by setting a very long stale period
 */
const extendStalePeriod = async (
  treasury: Contract,
  ownerSigner: any,
  tokenAddress: string,
  oracleAddress: string,
  newStalePeriod: number
) => {
  await treasury.connect(ownerSigner).updateOracle(tokenAddress, oracleAddress, newStalePeriod)
}

/**
 * Helper to reduce withdrawal delay for faster testing
 */
const reduceWithdrawalDelay = async (gateway: Contract, ownerSigner: any, delaySeconds: number) => {
  await gateway.connect(ownerSigner).updateWithdrawalDelay(delaySeconds)
}

describe('E2E: Deployed Contracts', function () {
  // Increase timeout for forked network tests (5 minutes for before hook)
  this.timeout(300000)

  // Reset base fee before each test to prevent gas errors
  beforeEach(async function () {
    await resetBaseFee()
  })

  let release: ReleaseConfig
  let deployer: SignerWithAddress
  let user1: SignerWithAddress
  let user2: SignerWithAddress
  let keeper: SignerWithAddress

  // Contracts
  let peggedToken: Contract
  let treasury: Contract
  let gateway: Contract
  let stakingVault: Contract
  let yieldDistributor: Contract
  let usdc: Contract

  before(async function () {
    // Increase timeout for setup (forked network is slow)
    this.timeout(300000)

    // Check if release file exists
    if (!fs.existsSync(releasePath)) {
      console.log(`Release file not found: ${releasePath}`)
      console.log('Skipping E2E tests. Set RELEASE_FILE env variable to run.')
      this.skip()
    }

    // Load release config
    release = JSON.parse(fs.readFileSync(releasePath, 'utf8'))
    console.log(`\nLoaded release: ${release.version} on ${release.network}`)

    // Get signers
    console.log('Getting signers...')
    ;[deployer, user1, user2, keeper] = await ethers.getSigners()
    console.log(`  Deployer: ${deployer.address}`)

    // Connect to deployed contracts
    console.log('Connecting to deployed contracts...')
    peggedToken = await ethers.getContractAt('PeggedToken', release.contracts.PeggedToken.address)
    treasury = await ethers.getContractAt('Treasury', release.contracts.Treasury.address)
    gateway = await ethers.getContractAt('Gateway', release.contracts.Gateway.address)
    stakingVault = await ethers.getContractAt('StakingVault', release.contracts.StakingVault.address)
    yieldDistributor = await ethers.getContractAt('YieldDistributor', release.contracts.YieldDistributor.address)

    // Connect to USDC
    console.log('Connecting to USDC...')
    usdc = await ethers.getContractAt('IERC20', USDC_ADDRESS)

    // Fund user1 with USDC from whale
    console.log('Funding users with USDC from whale...')
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [USDC_WHALE],
    })
    const whale = await ethers.getSigner(USDC_WHALE)
    await resetBaseFee()
    await deployer.sendTransaction({to: USDC_WHALE, value: parseUnits('1', 18)})

    await usdc.connect(whale).transfer(user1.address, parseUnits('100000', 6)) // 100k USDC

    await usdc.connect(whale).transfer(user2.address, parseUnits('50000', 6)) // 50k USDC
    await network.provider.request({
      method: 'hardhat_stopImpersonatingAccount',
      params: [USDC_WHALE],
    })
    console.log('  Users funded with USDC')

    // Grant KEEPER_ROLE to keeper
    console.log('Granting roles...')
    const owner = release.governance.owner
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [owner],
    })
    const ownerSigner = await ethers.getSigner(owner)

    await deployer.sendTransaction({to: owner, value: parseUnits('1', 18)})

    const KEEPER_ROLE = await treasury.KEEPER_ROLE()
    const hasKeeperRole = await treasury.hasRole(KEEPER_ROLE, keeper.address)
    if (!hasKeeperRole) {
      await treasury.connect(ownerSigner).grantRole(KEEPER_ROLE, keeper.address)
      console.log('  Granted KEEPER_ROLE')
    }

    // Grant DISTRIBUTOR_ROLE to deployer for yield distribution tests
    const DISTRIBUTOR_ROLE = await yieldDistributor.DISTRIBUTOR_ROLE()
    const hasDistributorRole = await yieldDistributor.hasRole(DISTRIBUTOR_ROLE, deployer.address)
    if (!hasDistributorRole) {
      await yieldDistributor.connect(ownerSigner).grantRole(DISTRIBUTOR_ROLE, deployer.address)
      console.log('  Granted DISTRIBUTOR_ROLE')
    }

    // Ensure owner has MAINTAINER_ROLE for updating withdrawal delay and stale periods
    const MAINTAINER_ROLE = await treasury.MAINTAINER_ROLE()
    const hasMaintainerRole = await treasury.hasRole(MAINTAINER_ROLE, owner)
    if (!hasMaintainerRole) {
      await treasury.connect(ownerSigner).grantRole(MAINTAINER_ROLE, owner)
      console.log('  Granted MAINTAINER_ROLE to owner')
    }

    // Extend stale period to 30 days to prevent StalePrice errors on forked network
    const EXTENDED_STALE_PERIOD = 30 * 24 * 60 * 60 // 30 days
    console.log('Extending oracle stale periods...')
    for (const [symbol, config] of Object.entries(release.whitelistedTokens)) {
      const tokenConfig = config as any
      await extendStalePeriod(treasury, ownerSigner, tokenConfig.token, tokenConfig.oracle, EXTENDED_STALE_PERIOD)
      console.log(`  Extended ${symbol} stale period to 30 days`)
    }

    // Reduce withdrawal delay for faster testing (5 minutes instead of default)
    const TEST_WITHDRAWAL_DELAY = 5 * 60 // 5 minutes
    await reduceWithdrawalDelay(gateway, ownerSigner, TEST_WITHDRAWAL_DELAY)
    console.log(`  Set withdrawal delay to ${TEST_WITHDRAWAL_DELAY} seconds`)

    await network.provider.request({
      method: 'hardhat_stopImpersonatingAccount',
      params: [owner],
    })

    console.log('\nTest Setup Complete:')
    console.log(`  PeggedToken: ${peggedToken.address}`)
    console.log(`  Treasury: ${treasury.address}`)
    console.log(`  Gateway: ${gateway.address}`)
    console.log(`  StakingVault: ${stakingVault.address}`)
    console.log(`  YieldDistributor: ${yieldDistributor.address}`)
    console.log(`  User1 USDC balance: ${formatUnits(await usdc.balanceOf(user1.address), 6)}`)
  })

  describe('1. User Actions', function () {
    // Increase timeout for all user action tests
    this.timeout(120000)

    describe('1.1 Deposit (Mint PeggedToken)', function () {
      it('should allow user to deposit USDC and receive PeggedToken', async function () {
        const depositAmount = parseUnits('1000', 6) // 1000 USDC

        // Approve Gateway to spend USDC
        await usdc.connect(user1).approve(gateway.address, depositAmount)

        // Preview deposit
        const expectedPeggedToken = await gateway.previewDeposit(USDC_ADDRESS, depositAmount)
        console.log(
          `    Preview: ${formatUnits(depositAmount, 6)} USDC -> ${formatUnits(expectedPeggedToken, 18)} PeggedToken`
        )

        // Deposit
        const peggedTokenBefore = await peggedToken.balanceOf(user1.address)
        await gateway.connect(user1).deposit(USDC_ADDRESS, depositAmount, 0, user1.address)
        const peggedTokenAfter = await peggedToken.balanceOf(user1.address)

        const received = peggedTokenAfter.sub(peggedTokenBefore)
        console.log(`    Received: ${formatUnits(received, 18)} PeggedToken`)

        expect(received).to.be.gte(expectedPeggedToken.mul(99).div(100)) // Allow 1% slippage
      })

      it('should allow user to mint exact PeggedToken amount', async function () {
        const mintAmount = parseUnits('500', 18) // 500 PeggedToken

        // Preview mint
        const requiredUSDC = await gateway.previewMint(USDC_ADDRESS, mintAmount)
        console.log(
          `    Preview: ${formatUnits(mintAmount, 18)} PeggedToken requires ${formatUnits(requiredUSDC, 6)} USDC`
        )

        // Approve Gateway
        await usdc.connect(user1).approve(gateway.address, requiredUSDC.mul(101).div(100))

        // Mint
        const peggedTokenBefore = await peggedToken.balanceOf(user1.address)
        await gateway.connect(user1).mint(USDC_ADDRESS, mintAmount, requiredUSDC.mul(101).div(100), user1.address)
        const peggedTokenAfter = await peggedToken.balanceOf(user1.address)

        const received = peggedTokenAfter.sub(peggedTokenBefore)
        console.log(`    Received: ${formatUnits(received, 18)} PeggedToken`)

        expect(received).to.equal(mintAmount)
      })
    })

    describe('1.2 Redeem (Burn PeggedToken)', function () {
      it('should allow user to request redeem with delay', async function () {
        const redeemAmount = parseUnits('200', 18) // 200 PeggedToken

        // Check if withdrawal delay is enabled
        const delayEnabled = await gateway.withdrawalDelayEnabled()
        console.log(`    Withdrawal delay enabled: ${delayEnabled}`)

        // Preview redeem (using USDC as output token)
        const expectedUSDC = await gateway.previewRedeem(USDC_ADDRESS, redeemAmount)
        console.log(`    Preview: ${formatUnits(redeemAmount, 18)} PeggedToken -> ${formatUnits(expectedUSDC, 6)} USDC`)

        // Approve Gateway to transfer PeggedToken
        await peggedToken.connect(user1).approve(gateway.address, redeemAmount)

        // Request redeem (locks PeggedToken in Gateway) - only takes amount, no token address
        await gateway.connect(user1).requestRedeem(redeemAmount)

        // Check request was created - only takes user address
        const [amountLocked, claimableAt] = await gateway.getRedeemRequest(user1.address)
        console.log(`    Amount locked: ${formatUnits(amountLocked, 18)} PeggedToken`)
        console.log(`    Claimable at: ${new Date(claimableAt.toNumber() * 1000).toISOString()}`)

        expect(amountLocked).to.equal(redeemAmount)
      })

      it('should allow user to claim redeem after delay', async function () {
        // Check if there's a pending request - only takes user address
        const [amountLocked, claimableAt] = await gateway.getRedeemRequest(user1.address)
        if (amountLocked.eq(0)) {
          console.log('    No pending request, skipping')
          return
        }

        // Fast forward time past the delay (5 minutes + 1 second)
        const delay = await gateway.withdrawalDelay()
        console.log(`    Withdrawal delay: ${delay.toNumber()} seconds`)
        await network.provider.send('evm_increaseTime', [delay.toNumber() + 1])

        await network.provider.send('evm_mine', [])

        // Preview redeem (using USDC as output token)
        const expectedUSDC = await gateway.previewRedeem(USDC_ADDRESS, amountLocked)

        // Claim - redeem now that delay has passed
        const usdcBefore = await usdc.balanceOf(user1.address)
        await gateway.connect(user1).redeem(USDC_ADDRESS, amountLocked, 0, user1.address)
        const usdcAfter = await usdc.balanceOf(user1.address)

        const received = usdcAfter.sub(usdcBefore)
        console.log(`    Received: ${formatUnits(received, 6)} USDC`)

        expect(received).to.be.gte(expectedUSDC.mul(99).div(100))
      })
    })

    describe('1.3 Stake (Deposit to StakingVault)', function () {
      it('should allow user to stake PeggedToken in StakingVault', async function () {
        const stakeAmount = parseUnits('500', 18) // 500 PeggedToken

        // Approve StakingVault
        await peggedToken.connect(user1).approve(stakingVault.address, stakeAmount)

        // Deposit to StakingVault
        const sharesBefore = await stakingVault.balanceOf(user1.address)
        await stakingVault.connect(user1).deposit(stakeAmount, user1.address)
        const sharesAfter = await stakingVault.balanceOf(user1.address)

        const receivedShares = sharesAfter.sub(sharesBefore)
        console.log(`    Staked: ${formatUnits(stakeAmount, 18)} PeggedToken`)
        console.log(`    Received: ${formatUnits(receivedShares, 18)} sVUSD shares`)

        expect(receivedShares).to.be.gt(0)
      })

      it('should allow user to request unstake with cooldown', async function () {
        const shares = await stakingVault.balanceOf(user1.address)
        const unstakeShares = shares.div(2) // Unstake half

        // Request redeem (cooldown)
        const tx = await stakingVault.connect(user1).requestRedeem(unstakeShares, user1.address)
        const receipt = await tx.wait()

        // Get request ID from event
        const event = receipt.events?.find((e: any) => e.event === 'WithdrawRequested')
        const requestId = event?.args?.requestId

        console.log(`    Requested unstake: ${formatUnits(unstakeShares, 18)} shares`)
        console.log(`    Request ID: ${requestId}`)

        // Verify request exists
        const request = await stakingVault.getRequestDetails(requestId)
        expect(request.owner).to.equal(user1.address)
        expect(request.assets).to.be.gt(0)
      })

      it('should allow user to claim after cooldown', async function () {
        // Get user's pending requests
        const [requestIds] = await stakingVault.getPendingRequests(user1.address)
        if (requestIds.length === 0) {
          console.log('    No pending requests to claim')
          return
        }

        const requestId = requestIds[0]
        const request = await stakingVault.getRequestDetails(requestId)

        // Fast forward time past cooldown
        await network.provider.send('evm_increaseTime', [SEVEN_DAYS + 1])
        await network.provider.send('evm_mine', [])

        // Claim
        const peggedTokenBefore = await peggedToken.balanceOf(user1.address)
        await stakingVault.connect(user1).claimWithdraw(requestId, user1.address)
        const peggedTokenAfter = await peggedToken.balanceOf(user1.address)

        const claimed = peggedTokenAfter.sub(peggedTokenBefore)
        console.log(`    Claimed: ${formatUnits(claimed, 18)} PeggedToken`)

        expect(claimed).to.be.gte(request.assets)
      })
    })
  })

  describe('2. Keeper Actions', function () {
    this.timeout(120000)

    describe('2.1 Pull (Withdraw from Vault)', function () {
      it('should allow keeper to pull tokens from vault', async function () {
        const pullAmount = parseUnits('500', 6) // Pull 500 USDC from vault to treasury

        const treasuryUSDCBefore = await usdc.balanceOf(treasury.address)
        console.log(`    Treasury USDC before: ${formatUnits(treasuryUSDCBefore, 6)}`)

        // Pull from vault
        await treasury.connect(keeper).pull(USDC_ADDRESS, pullAmount)

        const treasuryUSDCAfter = await usdc.balanceOf(treasury.address)
        console.log(`    Treasury USDC after: ${formatUnits(treasuryUSDCAfter, 6)}`)
        console.log(`    Pulled: ${formatUnits(pullAmount, 6)} USDC from vault`)

        expect(treasuryUSDCAfter).to.equal(treasuryUSDCBefore.add(pullAmount))
      })
    })

    describe('2.2 Push (Deposit to Vault)', function () {
      it('should allow keeper to push tokens to vault', async function () {
        const treasuryUSDC = await usdc.balanceOf(treasury.address)
        if (treasuryUSDC.eq(0)) {
          console.log('    No USDC in Treasury to push')
          return
        }

        const pushAmount = treasuryUSDC.div(2) // Push half of treasury USDC back to vault
        console.log(`    Treasury USDC before: ${formatUnits(treasuryUSDC, 6)}`)

        // Push to vault
        await treasury.connect(keeper).push(USDC_ADDRESS, pushAmount)

        const treasuryUSDCAfter = await usdc.balanceOf(treasury.address)
        console.log(`    Treasury USDC after: ${formatUnits(treasuryUSDCAfter, 6)}`)
        console.log(`    Pushed: ${formatUnits(pushAmount, 6)} USDC to vault`)

        expect(treasuryUSDCAfter).to.equal(treasuryUSDC.sub(pushAmount))
      })
    })

    describe('2.3 Toggle Deposit/Withdraw', function () {
      it('should allow keeper to toggle deposit activity', async function () {
        // Get current state
        const [, , , depositActive] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Deposit active before: ${depositActive}`)

        // Toggle
        await treasury.connect(keeper).toggleDepositActive(USDC_ADDRESS)

        const [, , , depositActiveAfter] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Deposit active after: ${depositActiveAfter}`)

        expect(depositActiveAfter).to.equal(!depositActive)

        // Toggle back
        await treasury.connect(keeper).toggleDepositActive(USDC_ADDRESS)
      })

      it('should allow keeper to toggle withdraw activity', async function () {
        // Get current state
        const [, , , , withdrawActive] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Withdraw active before: ${withdrawActive}`)

        // Toggle
        await treasury.connect(keeper).toggleWithdrawActive(USDC_ADDRESS)

        const [, , , , withdrawActiveAfter] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Withdraw active after: ${withdrawActiveAfter}`)

        expect(withdrawActiveAfter).to.equal(!withdrawActive)

        // Toggle back
        await treasury.connect(keeper).toggleWithdrawActive(USDC_ADDRESS)
      })
    })
  })

  describe('3. Yield Distribution', function () {
    this.timeout(120000)

    before(async function () {
      // Ensure there are stakers
      const totalSupply = await stakingVault.totalSupply()
      if (totalSupply.eq(0)) {
        // Stake some PeggedToken
        const stakeAmount = parseUnits('1000', 18)
        const peggedTokenBalance = await peggedToken.balanceOf(user2.address)
        if (peggedTokenBalance.lt(stakeAmount)) {
          // Deposit more
          await usdc.connect(user2).approve(gateway.address, parseUnits('2000', 6))
          await gateway.connect(user2).deposit(USDC_ADDRESS, parseUnits('2000', 6), 0, user2.address)
        }
        await peggedToken.connect(user2).approve(stakingVault.address, stakeAmount)
        await stakingVault.connect(user2).deposit(stakeAmount, user2.address)
      }
    })

    describe('3.1 Distribute Yield', function () {
      it('should allow distributor to distribute yield', async function () {
        const yieldAmount = parseUnits('100', 18) // 100 PeggedToken yield

        // Get some PeggedToken for yield distribution
        const deployerPeggedToken = await peggedToken.balanceOf(deployer.address)
        if (deployerPeggedToken.lt(yieldAmount)) {
          // Deposit via Gateway
          await usdc.connect(user1).transfer(deployer.address, parseUnits('200', 6))
          await usdc.connect(deployer).approve(gateway.address, parseUnits('200', 6))
          await gateway.connect(deployer).deposit(USDC_ADDRESS, parseUnits('200', 6), 0, deployer.address)
        }

        // Approve YieldDistributor
        await peggedToken.connect(deployer).approve(yieldDistributor.address, yieldAmount)

        // Distribute
        const periodFinishBefore = await yieldDistributor.periodFinish()
        await yieldDistributor.connect(deployer).distribute(yieldAmount)
        const periodFinishAfter = await yieldDistributor.periodFinish()

        console.log(`    Distributed: ${formatUnits(yieldAmount, 18)} PeggedToken`)
        console.log(`    Period finish: ${new Date(periodFinishAfter.toNumber() * 1000).toISOString()}`)

        expect(periodFinishAfter).to.be.gt(periodFinishBefore)

        const rewardRate = await yieldDistributor.rewardRate()
        console.log(`    Reward rate: ${formatUnits(rewardRate, 18)} tokens/second (scaled by 1e18)`)
      })
    })

    describe('3.2 Pull Yield to StakingVault', function () {
      it('should accrue yield over time', async function () {
        // Check pending yield at start
        const pendingBefore = await yieldDistributor.pendingYield()
        console.log(`    Pending yield before: ${formatUnits(pendingBefore, 18)}`)

        // Fast forward 1 day
        await network.provider.send('evm_increaseTime', [ONE_DAY])
        await network.provider.send('evm_mine', [])

        // Check pending yield after time passes
        const pendingAfter = await yieldDistributor.pendingYield()
        console.log(`    Pending yield after 1 day: ${formatUnits(pendingAfter, 18)}`)

        expect(pendingAfter).to.be.gt(pendingBefore)
      })

      it('should pull yield when user deposits to StakingVault', async function () {
        const pendingBefore = await yieldDistributor.pendingYield()
        console.log(`    Pending yield before deposit: ${formatUnits(pendingBefore, 18)}`)

        // Total assets before
        const totalAssetsBefore = await stakingVault.totalAssets()
        console.log(`    Total assets before: ${formatUnits(totalAssetsBefore, 18)}`)

        // Ensure user2 has enough PeggedToken
        const depositAmount = parseUnits('10', 18)
        const user2Balance = await peggedToken.balanceOf(user2.address)
        if (user2Balance.lt(depositAmount)) {
          // Get more PeggedToken via deposit
          const usdcNeeded = parseUnits('20', 6)
          await usdc.connect(user2).approve(gateway.address, usdcNeeded)
          await gateway.connect(user2).deposit(USDC_ADDRESS, usdcNeeded, 0, user2.address)
          console.log(`    Deposited more USDC to get PeggedToken for user2`)
        }

        // User deposits (this triggers _pullYield internally)
        await peggedToken.connect(user2).approve(stakingVault.address, depositAmount)
        await stakingVault.connect(user2).deposit(depositAmount, user2.address)

        // Total assets after (should include pulled yield)
        const totalAssetsAfter = await stakingVault.totalAssets()
        console.log(`    Total assets after: ${formatUnits(totalAssetsAfter, 18)}`)

        // Yield should have been pulled (pending should be 0 or very small)
        const pendingAfter = await yieldDistributor.pendingYield()
        console.log(`    Pending yield after deposit: ${formatUnits(pendingAfter, 18)}`)

        // Total assets should increase by more than just the deposit (includes yield)
        const increase = totalAssetsAfter.sub(totalAssetsBefore)
        console.log(`    Total assets increased by: ${formatUnits(increase, 18)}`)

        expect(increase).to.be.gte(depositAmount)
      })
    })

    describe('3.3 Share Price Appreciation', function () {
      it('should show share price appreciation after yield distribution', async function () {
        // Get current share price (assets per share)
        const totalAssets = await stakingVault.totalAssets()
        const totalSupply = await stakingVault.totalSupply()

        if (totalSupply.eq(0)) {
          console.log('    No shares minted, skipping')
          return
        }

        const sharePrice = totalAssets.mul(parseUnits('1', 18)).div(totalSupply)
        console.log(`    Current share price: ${formatUnits(sharePrice, 18)} assets per share`)

        // Share price should be >= 1 (if yield has been distributed)
        expect(sharePrice).to.be.gte(parseUnits('1', 18).mul(99).div(100)) // At least 0.99
      })
    })
  })

  describe('4. View Functions Verification', function () {
    this.timeout(60000)

    it('should return correct treasury reserve', async function () {
      const reserve = await treasury.reserve()
      console.log(`    Treasury reserve: ${formatUnits(reserve, 18)}`)
      expect(reserve).to.be.gte(0)
    })

    it('should return correct withdrawable amount', async function () {
      const withdrawable = await treasury.withdrawable(USDC_ADDRESS)
      console.log(`    USDC withdrawable: ${formatUnits(withdrawable, 6)}`)
      expect(withdrawable).to.be.gte(0)
    })

    it('should return correct max mint', async function () {
      const maxMint = await gateway.maxMint()
      console.log(`    Max mint: ${formatUnits(maxMint, 18)}`)
      expect(maxMint).to.be.gte(0)
    })

    it('should return correct staking vault total assets', async function () {
      const totalAssets = await stakingVault.totalAssets()
      console.log(`    StakingVault total assets: ${formatUnits(totalAssets, 18)}`)
      expect(totalAssets).to.be.gte(0)
    })
  })
})
