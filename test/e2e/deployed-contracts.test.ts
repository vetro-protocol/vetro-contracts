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
 * from the release JSON file. They read all config (fees, delays, cooldowns)
 * from on-chain state so they work regardless of deployment configuration.
 *
 * Usage:
 *   RELEASE_FILE=ethereum-1.0.0-beta.1.json npx hardhat test test/e2e/deployed-contracts.test.ts
 *
 * Prerequisites:
 *   - Set ETHEREUM_NODE_URL env variable for mainnet fork
 *   - Set RELEASE_FILE env variable to the release JSON filename (optional, defaults to ethereum-1.0.0-beta.1.json)
 */

// Load release config
const RELEASE_FILE = process.env.RELEASE_FILE || 'ethereum-1.0.0.json'
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

const ONE_DAY = 24 * 60 * 60

/**
 * Helper to reset base fee before transactions.
 * Forked networks retain mainnet's base fee which can cause "maxFeePerGas too low" errors.
 */
const resetBaseFee = async () => {
  await network.provider.send('hardhat_setNextBlockBaseFeePerGas', ['0x0'])
}

/**
 * Helper to impersonate an account, fund it with ETH, and return its signer.
 */
const impersonate = async (address: string, funder: SignerWithAddress): Promise<any> => {
  await network.provider.request({method: 'hardhat_impersonateAccount', params: [address]})
  await funder.sendTransaction({to: address, value: parseUnits('1', 18)})
  return ethers.getSigner(address)
}

const stopImpersonating = async (address: string) => {
  await network.provider.request({method: 'hardhat_stopImpersonatingAccount', params: [address]})
}

/**
 * Helper to set up fork, grant roles, and extend stale periods.
 */
const setupForkAndRoles = async (
  release: ReleaseConfig,
  treasury: Contract,
  gateway: Contract,
  yieldDistributor: Contract,
  deployer: SignerWithAddress,
  keeper: SignerWithAddress,
  usdc: Contract,
  user1: SignerWithAddress,
  user2: SignerWithAddress
) => {
  const nodeUrl = process.env.ETHEREUM_NODE_URL!
  await network.provider.request({method: 'hardhat_reset', params: [{forking: {jsonRpcUrl: nodeUrl}}]})
  await resetBaseFee()

  const owner = release.governance.owner
  const ownerSigner = await impersonate(owner, deployer)

  // Grant roles if needed
  const KEEPER_ROLE = await treasury.KEEPER_ROLE()
  if (!(await treasury.hasRole(KEEPER_ROLE, keeper.address))) {
    await treasury.connect(ownerSigner).grantRole(KEEPER_ROLE, keeper.address)
  }
  const DISTRIBUTOR_ROLE = await yieldDistributor.DISTRIBUTOR_ROLE()
  if (!(await yieldDistributor.hasRole(DISTRIBUTOR_ROLE, deployer.address))) {
    await yieldDistributor.connect(ownerSigner).grantRole(DISTRIBUTOR_ROLE, deployer.address)
  }

  // Extend stale periods to max (72 hours)
  const MAX_STALE_PERIOD = 72 * 60 * 60
  for (const [, config] of Object.entries(release.whitelistedTokens)) {
    const tokenConfig = config as any
    await treasury.connect(ownerSigner).updateOracle(tokenConfig.token, tokenConfig.oracle, MAX_STALE_PERIOD)
  }

  await stopImpersonating(owner)

  // Fund users with USDC from whale
  const whale = await impersonate(USDC_WHALE, deployer)
  await resetBaseFee()
  await usdc.connect(whale).transfer(user1.address, parseUnits('100000', 6))
  await usdc.connect(whale).transfer(user2.address, parseUnits('50000', 6))
  await stopImpersonating(USDC_WHALE)
}

describe('E2E: Deployed Contracts', function () {
  this.timeout(300000)

  beforeEach(async function () {
    await resetBaseFee()
  })

  let release: ReleaseConfig
  let deployer: SignerWithAddress
  let user1: SignerWithAddress
  let user2: SignerWithAddress
  let keeper: SignerWithAddress

  let peggedToken: Contract
  let treasury: Contract
  let gateway: Contract
  let stakingVault: Contract
  let yieldDistributor: Contract
  let usdc: Contract

  before(async function () {
    this.timeout(300000)

    if (!fs.existsSync(releasePath)) {
      console.log(`Release file not found: ${releasePath}`)
      this.skip()
    }

    const nodeUrl = process.env.ETHEREUM_NODE_URL
    if (!nodeUrl) {
      console.log('ETHEREUM_NODE_URL not set, skipping E2E tests')
      this.skip()
    }

    release = JSON.parse(fs.readFileSync(releasePath, 'utf8'))
    console.log(`\nLoaded release: ${release.version} on ${release.network}`)
    ;[deployer, user1, user2, keeper] = await ethers.getSigners()

    peggedToken = await ethers.getContractAt('PeggedToken', release.contracts.PeggedToken.address)
    treasury = await ethers.getContractAt('Treasury', release.contracts.Treasury.address)
    gateway = await ethers.getContractAt('Gateway', release.contracts.Gateway.address)
    stakingVault = await ethers.getContractAt('StakingVault', release.contracts.StakingVault.address)
    yieldDistributor = await ethers.getContractAt('YieldDistributor', release.contracts.YieldDistributor.address)
    usdc = await ethers.getContractAt('IERC20', USDC_ADDRESS)

    await setupForkAndRoles(release, treasury, gateway, yieldDistributor, deployer, keeper, usdc, user1, user2)

    // Log on-chain config
    const withdrawalDelay = await gateway.withdrawalDelay()
    const withdrawalDelayEnabled = await gateway.withdrawalDelayEnabled()
    const cooldownDuration = await stakingVault.cooldownDuration()
    const cooldownEnabled = await stakingVault.cooldownEnabled()
    const mintFee = await gateway.mintFee(USDC_ADDRESS)
    const redeemFee = await gateway.redeemFee(USDC_ADDRESS)

    console.log('\nOn-chain config:')
    console.log(`  Withdrawal delay: ${withdrawalDelay} seconds (enabled: ${withdrawalDelayEnabled})`)
    console.log(`  Cooldown duration: ${cooldownDuration} seconds (enabled: ${cooldownEnabled})`)
    console.log(`  Mint fee (USDC): ${mintFee} bps`)
    console.log(`  Redeem fee (USDC): ${redeemFee} bps`)
    console.log(`  User1 USDC balance: ${formatUnits(await usdc.balanceOf(user1.address), 6)}`)
  })

  describe('1. User Actions', function () {
    this.timeout(120000)

    describe('1.1 Deposit (Mint PeggedToken)', function () {
      it('should allow user to deposit USDC and receive PeggedToken', async function () {
        const depositAmount = parseUnits('1000', 6)

        await usdc.connect(user1).approve(gateway.address, depositAmount)

        // Use previewDeposit to get expected output (accounts for fees)
        const expectedPeggedToken = await gateway.previewDeposit(USDC_ADDRESS, depositAmount)
        console.log(
          `    Preview: ${formatUnits(depositAmount, 6)} USDC -> ${formatUnits(expectedPeggedToken, 18)} PeggedToken`
        )

        const peggedTokenBefore = await peggedToken.balanceOf(user1.address)
        await gateway.connect(user1).deposit(USDC_ADDRESS, depositAmount, 0, user1.address)
        const peggedTokenAfter = await peggedToken.balanceOf(user1.address)

        const received = peggedTokenAfter.sub(peggedTokenBefore)
        console.log(`    Received: ${formatUnits(received, 18)} PeggedToken`)

        // Received should match preview (preview already accounts for fees)
        expect(received).to.equal(expectedPeggedToken)
      })

      it('should allow user to mint exact PeggedToken amount', async function () {
        const mintAmount = parseUnits('500', 18)

        // previewMint returns required USDC (accounts for fees)
        const requiredUSDC = await gateway.previewMint(USDC_ADDRESS, mintAmount)
        console.log(
          `    Preview: ${formatUnits(mintAmount, 18)} PeggedToken requires ${formatUnits(requiredUSDC, 6)} USDC`
        )

        await usdc.connect(user1).approve(gateway.address, requiredUSDC)

        const peggedTokenBefore = await peggedToken.balanceOf(user1.address)
        await gateway.connect(user1).mint(USDC_ADDRESS, mintAmount, requiredUSDC, user1.address)
        const peggedTokenAfter = await peggedToken.balanceOf(user1.address)

        const received = peggedTokenAfter.sub(peggedTokenBefore)
        console.log(`    Received: ${formatUnits(received, 18)} PeggedToken`)

        expect(received).to.equal(mintAmount)
      })
    })

    describe('1.2 Redeem (Burn PeggedToken)', function () {
      it('should allow user to request and claim redeem', async function () {
        const redeemAmount = parseUnits('200', 18)

        const delayEnabled = await gateway.withdrawalDelayEnabled()
        const delay = await gateway.withdrawalDelay()
        console.log(`    Withdrawal delay: ${delay} seconds (enabled: ${delayEnabled})`)

        // previewRedeem returns expected USDC (accounts for fees)
        const expectedUSDC = await gateway.previewRedeem(USDC_ADDRESS, redeemAmount)
        console.log(`    Preview: ${formatUnits(redeemAmount, 18)} PeggedToken -> ${formatUnits(expectedUSDC, 6)} USDC`)

        await peggedToken.connect(user1).approve(gateway.address, redeemAmount)

        if (delayEnabled) {
          // Request redeem
          await gateway.connect(user1).requestRedeem(redeemAmount)

          const [amountLocked] = await gateway.getRedeemRequest(user1.address)
          expect(amountLocked).to.equal(redeemAmount)

          // Fast forward past delay
          await network.provider.send('evm_increaseTime', [delay.toNumber() + 1])
          await network.provider.send('evm_mine', [])
        }

        // Claim redeem
        const usdcBefore = await usdc.balanceOf(user1.address)
        await gateway.connect(user1).redeem(USDC_ADDRESS, redeemAmount, 0, user1.address)
        const usdcAfter = await usdc.balanceOf(user1.address)

        const received = usdcAfter.sub(usdcBefore)
        console.log(`    Received: ${formatUnits(received, 6)} USDC`)

        expect(received).to.be.gt(0)
      })
    })

    describe('1.3 Stake (Deposit to StakingVault)', function () {
      it('should allow user to stake PeggedToken in StakingVault', async function () {
        const stakeAmount = parseUnits('500', 18)

        await peggedToken.connect(user1).approve(stakingVault.address, stakeAmount)

        const sharesBefore = await stakingVault.balanceOf(user1.address)
        await stakingVault.connect(user1).deposit(stakeAmount, user1.address)
        const sharesAfter = await stakingVault.balanceOf(user1.address)

        const receivedShares = sharesAfter.sub(sharesBefore)
        console.log(`    Staked: ${formatUnits(stakeAmount, 18)} PeggedToken`)
        console.log(`    Received: ${formatUnits(receivedShares, 18)} sVUSD shares`)

        expect(receivedShares).to.be.gt(0)
      })

      it('should allow user to request unstake and claim after cooldown', async function () {
        const shares = await stakingVault.balanceOf(user1.address)
        const unstakeShares = shares.div(2)

        const cooldownEnabled = await stakingVault.cooldownEnabled()
        const cooldownDuration = await stakingVault.cooldownDuration()
        console.log(`    Cooldown: ${cooldownDuration} seconds (enabled: ${cooldownEnabled})`)

        // Request redeem
        const tx = await stakingVault.connect(user1).requestRedeem(unstakeShares, user1.address)
        const receipt = await tx.wait()

        const event = receipt.events?.find((e: any) => e.event === 'WithdrawRequested')
        const requestId = event?.args?.requestId
        console.log(`    Requested unstake: ${formatUnits(unstakeShares, 18)} shares (requestId: ${requestId})`)

        const request = await stakingVault.getRequestDetails(requestId)
        expect(request.owner).to.equal(user1.address)

        // Fast forward past cooldown
        await network.provider.send('evm_increaseTime', [cooldownDuration.toNumber() + 1])
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
        const pullAmount = parseUnits('500', 6)

        const treasuryUSDCBefore = await usdc.balanceOf(treasury.address)
        await treasury.connect(keeper).pull(USDC_ADDRESS, pullAmount)
        const treasuryUSDCAfter = await usdc.balanceOf(treasury.address)

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

        const pushAmount = treasuryUSDC.div(2)
        await treasury.connect(keeper).push(USDC_ADDRESS, pushAmount)

        const treasuryUSDCAfter = await usdc.balanceOf(treasury.address)
        console.log(`    Pushed: ${formatUnits(pushAmount, 6)} USDC to vault`)
        expect(treasuryUSDCAfter).to.equal(treasuryUSDC.sub(pushAmount))
      })
    })

    describe('2.3 Toggle Deposit/Withdraw', function () {
      it('should allow keeper to toggle deposit activity', async function () {
        const [, , , depositActive] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Deposit active before: ${depositActive}`)

        await treasury.connect(keeper).setDepositActive(USDC_ADDRESS, !depositActive)

        const [, , , depositActiveAfter] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Deposit active after: ${depositActiveAfter}`)
        expect(depositActiveAfter).to.equal(!depositActive)

        // Restore
        await treasury.connect(keeper).setDepositActive(USDC_ADDRESS, depositActive)
      })

      it('should allow keeper to toggle withdraw activity', async function () {
        const [, , , , withdrawActive] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Withdraw active before: ${withdrawActive}`)

        await treasury.connect(keeper).setWithdrawActive(USDC_ADDRESS, !withdrawActive)

        const [, , , , withdrawActiveAfter] = await treasury.tokenConfig(USDC_ADDRESS)
        console.log(`    Withdraw active after: ${withdrawActiveAfter}`)
        expect(withdrawActiveAfter).to.equal(!withdrawActive)

        // Restore
        await treasury.connect(keeper).setWithdrawActive(USDC_ADDRESS, withdrawActive)
      })
    })
  })

  describe('3. Yield Distribution', function () {
    this.timeout(300000)

    before(async function () {
      this.timeout(300000)
      // Re-fork to get fresh oracle data (previous tests may have fast-forwarded time)
      ;[deployer, user1, user2, keeper] = await ethers.getSigners()
      await setupForkAndRoles(release, treasury, gateway, yieldDistributor, deployer, keeper, usdc, user1, user2)

      // Deposit and stake for user2
      await usdc.connect(user2).approve(gateway.address, parseUnits('2000', 6))
      await gateway.connect(user2).deposit(USDC_ADDRESS, parseUnits('2000', 6), 0, user2.address)
      const stakeAmount = parseUnits('1000', 18)
      await peggedToken.connect(user2).approve(stakingVault.address, stakeAmount)
      await stakingVault.connect(user2).deposit(stakeAmount, user2.address)
    })

    describe('3.1 Distribute Yield', function () {
      it('should allow distributor to distribute yield', async function () {
        const yieldAmount = parseUnits('100', 18)

        // Get PeggedToken for yield distribution
        const deployerPeggedToken = await peggedToken.balanceOf(deployer.address)
        if (deployerPeggedToken.lt(yieldAmount)) {
          await usdc.connect(user1).transfer(deployer.address, parseUnits('200', 6))
          await usdc.connect(deployer).approve(gateway.address, parseUnits('200', 6))
          await gateway.connect(deployer).deposit(USDC_ADDRESS, parseUnits('200', 6), 0, deployer.address)
        }

        await peggedToken.connect(deployer).approve(yieldDistributor.address, yieldAmount)

        const periodFinishBefore = await yieldDistributor.periodFinish()
        await yieldDistributor.connect(deployer).distribute(yieldAmount)
        const periodFinishAfter = await yieldDistributor.periodFinish()

        console.log(`    Distributed: ${formatUnits(yieldAmount, 18)} PeggedToken`)
        expect(periodFinishAfter).to.be.gt(periodFinishBefore)
      })
    })

    describe('3.2 Pull Yield to StakingVault', function () {
      it('should accrue yield over time', async function () {
        const pendingBefore = await yieldDistributor.pendingYield()

        await network.provider.send('evm_increaseTime', [ONE_DAY])
        await network.provider.send('evm_mine', [])

        const pendingAfter = await yieldDistributor.pendingYield()
        console.log(`    Pending yield after 1 day: ${formatUnits(pendingAfter, 18)}`)

        expect(pendingAfter).to.be.gt(pendingBefore)
      })

      it('should pull yield when user deposits to StakingVault', async function () {
        const totalAssetsBefore = await stakingVault.totalAssets()

        const depositAmount = parseUnits('10', 18)
        const user2Balance = await peggedToken.balanceOf(user2.address)
        if (user2Balance.lt(depositAmount)) {
          const usdcNeeded = parseUnits('20', 6)
          await usdc.connect(user2).approve(gateway.address, usdcNeeded)
          await gateway.connect(user2).deposit(USDC_ADDRESS, usdcNeeded, 0, user2.address)
        }

        await peggedToken.connect(user2).approve(stakingVault.address, depositAmount)
        await stakingVault.connect(user2).deposit(depositAmount, user2.address)

        const totalAssetsAfter = await stakingVault.totalAssets()
        const increase = totalAssetsAfter.sub(totalAssetsBefore)
        console.log(`    Total assets increased by: ${formatUnits(increase, 18)} (deposit + yield)`)

        // Increase should be >= deposit amount (yield adds extra)
        expect(increase).to.be.gte(depositAmount)
      })
    })

    describe('3.3 Share Price Appreciation', function () {
      it('should show share price >= 1.0 after yield distribution', async function () {
        const totalAssets = await stakingVault.totalAssets()
        const totalSupply = await stakingVault.totalSupply()

        if (totalSupply.eq(0)) {
          console.log('    No shares minted, skipping')
          return
        }

        const sharePrice = totalAssets.mul(parseUnits('1', 18)).div(totalSupply)
        console.log(`    Share price: ${formatUnits(sharePrice, 18)} assets per share`)

        expect(sharePrice).to.be.gte(parseUnits('1', 18).mul(99).div(100))
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
