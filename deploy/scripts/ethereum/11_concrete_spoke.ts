import chalk from 'chalk'
import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployUpgradable, ContractAliases, UpgradableContracts} from '../../helpers'
import {saveForMultiSigBatchExecution} from '../../helpers/gnosis-safe'
import {isTreasuryMigrated} from '../../helpers/treasury-migration'
import Address from '../../helpers/address'
import {SpokeConfig} from '../../config'

const {PeggedToken, Treasury, Gateway, StakingVault, ConcreteSpoke} = ContractAliases

const {log} = console

/**
 * Deploy the ctDefiUSDT ConcreteSpoke and wire it to the Gateway and sVUSD
 *
 * Queues for the Safe: `addSpoke`, the spoke's mint limit once `SpokeConfig.ctDefiUSDT.mintLimit` is set,
 * and the spoke on sVUSD's instant withdraw whitelist (its staked exit unstakes as the spoke). The AccessManager
 * roles (whitelist, shutdown, force exits) are set up on the AccessManager, not here (docs/OPERATIONS.md
 * 8.2). The AccessManager must have code and the Safe as its admin; on localhost `ACCESS_MANAGER` overrides the
 * configured one for a fork rehearsal.
 *
 * The Gateway gets spoke support with the Treasury migration, so this waits until that has run. Do not re-run while
 * its Safe batch is pending: `addSpoke` would be queued again.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  // Concrete is on mainnet only
  if (hre.network.name === 'hardhat') {
    log(`Skipping ${ConcreteSpoke} on local network (mainnet addresses not available)`)
    return
  }

  // A leftover rehearsal value must never reach mainnet
  const override = hre.network.name === 'localhost' ? process.env.ACCESS_MANAGER : undefined
  const accessManager = override || SpokeConfig.ctDefiUSDT.accessManager
  if (!accessManager) {
    log(chalk.yellow(`${ConcreteSpoke}: no AccessManager configured, skipping`))
    return
  }

  if (!(await isTreasuryMigrated(hre, PeggedToken))) {
    log(chalk.yellow(`${ConcreteSpoke}: the live Treasury predates the migration, run it after the Safe executes`))
    return
  }

  const {deployments} = hre
  const {get, read, execute, catchUnknownSigner} = deployments
  const {mintLimit} = SpokeConfig.ctDefiUSDT

  const asset = Address.CTDEFIUSDT
  if (!asset) throw Error('CTDEFIUSDT is not configured for this network')

  const {address: peggedToken} = await get(PeggedToken)
  const {address: stakingVault} = await get(StakingVault)
  // Gateway roles live on the Treasury; owner() is its DEFAULT_ADMIN_ROLE holder, the Safe
  const admin: string = await read(Treasury, 'owner')

  // A wrong authority makes every restricted function revert, and only an upgrade fixes it
  if ((await hre.ethers.provider.getCode(accessManager)) === '0x') {
    throw Error(`${ConcreteSpoke}: the AccessManager ${accessManager} has no code`)
  }
  const manager = new hre.ethers.Contract(
    accessManager,
    ['function hasRole(uint64 roleId, address account) view returns (bool isMember, uint32 executionDelay)'],
    hre.ethers.provider
  )
  const [isAdmin] = await manager.hasRole(0, admin)
  if (!isAdmin) throw Error(`${ConcreteSpoke}: ${admin} is not the admin of the AccessManager ${accessManager}`)

  const {address: spoke} = await deployUpgradable({
    hre,
    contractConfig: UpgradableContracts.ConcreteSpoke,
    initializeArgs: [
      accessManager, // authority_
      peggedToken, // peggedToken_
      asset, // asset_
      stakingVault, // stakingVault_
    ],
  })
  // On a re-run the proxy already exists and ignores the configured AccessManager
  const authority: string = await read(ConcreteSpoke, 'authority')
  if (authority.toLowerCase() !== accessManager.toLowerCase()) {
    throw Error(`${ConcreteSpoke}: authority is ${authority}, expected the AccessManager ${accessManager}`)
  }

  const queue = async (alias: string, from: string, options: object, method: string, ...args: unknown[]) => {
    const multiSigTx = await catchUnknownSigner(execute(alias, {from, log: true, ...options}, method, ...args), {
      log: true,
    })
    if (multiSigTx) {
      await saveForMultiSigBatchExecution(multiSigTx)
      log(chalk.yellow(`  ⧗ ${alias}.${method}(${args.join(', ')}) queued for the Safe batch`))
    }
    return Boolean(multiSigTx)
  }

  const spokes: string[] = await read(Gateway, 'getSpokes')
  const registered = spokes.some((m) => m.toLowerCase() === spoke.toLowerCase())
  const addQueued = !registered && (await queue(Gateway, admin, {}, 'addSpoke', spoke))

  if (!(await read(StakingVault, 'instantWithdrawWhitelist', spoke))) {
    await queue(StakingVault, await read(StakingVault, 'owner'), {}, 'updateInstantWithdrawWhitelist', spoke, true)
  }

  if (mintLimit.isZero()) {
    log(chalk.yellow(`${ConcreteSpoke}: no mint limit configured, leaving the Gateway's as it is`))
    return
  }
  const current = addQueued ? hre.ethers.constants.Zero : await read(Gateway, 'spokeMintLimit', spoke)
  if (current.eq(mintLimit)) {
    log(chalk.blue(`${Gateway}: ${ConcreteSpoke} mint limit already ${mintLimit}`))
    return
  }
  const method = mintLimit.gt(current) ? 'increaseSpokeMintLimit' : 'decreaseSpokeMintLimit'
  // `execute` estimates gas before it checks the signer, and the estimate reverts while the spoke is not registered
  // yet. A fixed limit skips it so the limit is queued right after `addSpoke`.
  await queue(Gateway, admin, addQueued ? {gasLimit: 100_000} : {}, method, spoke, mintLimit)
}

// No `dependencies`: this is an incremental script; running dependency scripts would redeploy
// drifted contracts. `get()` reads the existing artifacts instead.
func.tags = [ConcreteSpoke]

export default func
