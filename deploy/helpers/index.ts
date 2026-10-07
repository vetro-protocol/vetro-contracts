import chalk from 'chalk'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {Deployment} from 'hardhat-deploy/types'
import Address from './address'
import {executeForcedTxUsingMultiSig, saveForMultiSigBatchExecution} from './gnosis-safe'
import {getImplementation, getProxyAdmin} from './eip1967'
import {assertUpgradeSafety} from './upgrade-safety'
import {UpgradableContracts, ContractAliases} from '../config'

const {GOVERNOR} = Address

const {log} = console

/**
 * Contract configuration for upgradeable contracts
 */
interface ContractConfig {
  alias: string
  contract: string
}

// Re-export from config for backward compatibility
export {UpgradableContracts, ContractAliases}

interface DeployUpgradableFunctionProps {
  hre: HardhatRuntimeEnvironment
  contractConfig: ContractConfig
  initializeArgs: unknown[]
  methodName?: string
  // If true, doesn't add upgrade tx to batch but requires multi sig to run it immediately
  // It's needed when a later script must execute after this upgrade
  force?: boolean
}

/**
 * Deploys an upgradeable contract using OpenZeppelin v5 Transparent Proxy pattern
 *
 * This function deploys contracts using OZ v5's TransparentUpgradeableProxy directly,
 * bypassing hardhat-deploy's built-in proxy feature (which uses OZ v4).
 *
 * OZ v5 Architecture:
 * - Implementation: The actual contract logic
 * - Proxy: OZ v5 TransparentUpgradeableProxy
 * - ProxyAdmin: Auto-created by OZ v5 proxy, owned by GOVERNOR/deployer
 *
 * Flow:
 * 1. Deploy implementation contract
 * 2. Deploy OZ v5 TransparentUpgradeableProxy with owner as initialOwner
 *    - ProxyAdmin is auto-created, owned by owner (GOVERNOR on mainnet, deployer locally)
 *
 * For upgrades:
 * - Owner calls ProxyAdmin.upgradeAndCall(proxy, newImpl, data)
 *
 * @param hre - Hardhat runtime environment
 * @param contractConfig - Contract name and alias
 * @param initializeArgs - Arguments for the initialize function
 * @param methodName - Initialize method name (default: 'initialize')
 * @param force - If true, execute multisig tx immediately
 * @returns Deployed contract address and implementation address
 */
export const deployUpgradable = async ({
  hre,
  contractConfig,
  initializeArgs,
  methodName = 'initialize',
  force,
}: DeployUpgradableFunctionProps): Promise<{
  address: string
  implementationAddress?: string | undefined
}> => {
  const {
    deployments: {deploy, save, getOrNull, fetchIfDifferent, catchUnknownSigner, execute},
    getNamedAccounts,
    ethers,
  } = hre
  const {deployer} = await getNamedAccounts()
  const {alias, contract} = contractConfig

  // Use deployer as owner on local networks, GOVERNOR on production
  const owner = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : GOVERNOR || deployer

  const implementationAlias = `${contract}_Implementation`
  const proxyAlias = `${alias}_Proxy`
  const proxyAdminAlias = `${alias}_ProxyAdmin`

  // Deploying the implementation changes neither the proxy nor its live implementation, so read them once
  const proxyDeployment: Deployment | null = await getOrNull(proxyAlias)
  const currentImpl = proxyDeployment && (await getImplementation(ethers.provider, proxyDeployment.address))

  // 0. Never deploy or queue an upgrade the Safe would sign blindly: before spending gas or overwriting the
  // implementation artifact, the new layout must be compatible with the live one
  if (proxyDeployment) {
    const {differences} = await fetchIfDifferent(implementationAlias, {contract, from: deployer})
    const recordedImpl = (await getOrNull(implementationAlias))?.address
    if (differences || !recordedImpl || ethers.utils.getAddress(recordedImpl) !== currentImpl) {
      const {reference} = await assertUpgradeSafety(hre, proxyDeployment.address, contract)
      log(chalk.green(`${alias}: storage layout compatible with live ${reference}`))
    }
  }

  // 1. Deploy implementation
  const implDeployment = await deploy(implementationAlias, {
    contract,
    from: deployer,
    log: true,
  })

  // 2. Deploy the proxy if it doesn't exist yet
  if (!proxyDeployment) {
    // First deployment - create new proxy

    // Encode initialize call
    const implContract = await ethers.getContractAt(contract, implDeployment.address)
    const encodedInitializeCall = implContract.interface.encodeFunctionData(methodName, initializeArgs)

    // Deploy OZ v5 TransparentUpgradeableProxy
    // Constructor: (address _logic, address initialOwner, bytes memory _data)
    // initialOwner becomes the owner of auto-created ProxyAdmin
    const proxyDeployResult = await deploy(proxyAlias, {
      contract: '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy',
      args: [implDeployment.address, owner, encodedInitializeCall],
      from: deployer,
      log: true,
    })

    // Get the auto-created ProxyAdmin address from ERC-1967 slot
    const proxyAdmin = await getProxyAdmin(ethers.provider, proxyDeployResult.address)
    log(chalk.green(`  ProxyAdmin (auto-created): ${proxyAdmin}`))

    // Save ProxyAdmin deployment for reference
    await save(proxyAdminAlias, {
      address: proxyAdmin,
      abi: (await hre.artifacts.readArtifact('ProxyAdmin')).abi,
    })

    // Save proxy deployment with implementation info
    await save(proxyAlias, {
      ...proxyDeployResult,
      implementation: implDeployment.address,
    })

    // Save alias deployment with implementation ABI but proxy address
    await save(alias, {
      ...implDeployment,
      address: proxyDeployResult.address,
      implementation: implDeployment.address,
    })

    log(chalk.green(`Deployed ${alias} proxy at ${proxyDeployResult.address}`))
    log(chalk.green(`  Implementation: ${implDeployment.address}`))
    log(chalk.green(`  ProxyAdmin: ${proxyAdmin}`))
    log(chalk.green(`  ProxyAdmin owner: ${owner}`))

    return {
      address: proxyDeployResult.address,
      implementationAddress: implDeployment.address,
    }
  }

  // Proxy exists - check if upgrade is needed
  const newImplAddress = ethers.utils.getAddress(implDeployment.address)

  if (currentImpl !== newImplAddress) {
    log(chalk.yellow(`Upgrade needed for ${alias}`))
    log(chalk.yellow(`  Current implementation: ${currentImpl}`))
    log(chalk.yellow(`  New implementation: ${newImplAddress}`))

    // Get the ProxyAdmin address
    const proxyAdmin = await getProxyAdmin(ethers.provider, proxyDeployment.address)
    log(chalk.yellow(`  ProxyAdmin: ${proxyAdmin}`))

    // Upgrade via ProxyAdmin.upgradeAndCall, sent BY the ProxyAdmin owner. Use hardhat-deploy's
    // `execute` (it honors the named `owner`, unlike raw ethers which would default to account[0]
    // and revert OwnableUnauthorizedAccount against a Safe-owned ProxyAdmin).
    const executeFn = () =>
      execute(
        proxyAdminAlias,
        {from: owner, log: true},
        'upgradeAndCall',
        proxyDeployment.address,
        newImplAddress,
        '0x'
      )

    const multiSigTx = await catchUnknownSigner(executeFn, {log: true})

    if (multiSigTx) {
      if (force) {
        await executeForcedTxUsingMultiSig(hre, multiSigTx)
        log(chalk.green(`  ✓ Upgraded ${alias} via multisig → ${newImplAddress}`))
      } else {
        await saveForMultiSigBatchExecution(multiSigTx)
        log(
          chalk.yellow(
            `  ⧗ ${alias} upgrade QUEUED for the Safe batch — owner ${owner} can't sign here. ` +
              `Confirm & execute the batch in the Safe to apply the upgrade on-chain, then re-run the deploy.`
          )
        )
      }
    } else {
      log(chalk.green(`  ✓ Upgraded ${alias} → ${newImplAddress}`))
    }

    // Update deployment files
    await save(proxyAlias, {
      ...proxyDeployment,
      implementation: newImplAddress,
    })

    await save(alias, {
      ...implDeployment,
      address: proxyDeployment.address,
      implementation: newImplAddress,
    })
  } else {
    log(chalk.blue(`${alias} is already at latest implementation`))
  }

  return {
    address: proxyDeployment.address,
    implementationAddress: newImplAddress,
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const defaultIsCurrentValueUpdated = (currentValue: any, newValue: any) =>
  currentValue.toString() === newValue.toString()

interface UpdateParamProps {
  contractAlias: string
  readMethod: string
  readArgs?: string[]
  writeMethod: string
  writeArgs?: string[]
  // Custom comparison function for complex cases
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  isCurrentValueUpdated?: (currentValue: any, newValue: any) => boolean
  // If true, execute multisig tx immediately
  force?: boolean
  // Optional: specify the governor/owner address for the contract
  // If not provided, will try to read from contract's owner() or governor()
  governorOverride?: string
}

/**
 * Idempotent parameter update helper
 *
 * Features:
 * - Reads current value before writing to avoid unnecessary transactions
 * - Supports array and single value comparisons
 * - Defers execution to multisig on production networks
 * - Custom comparison function support for complex logic
 *
 * @param hre - Hardhat runtime environment
 * @param props - Update configuration
 */
export const updateParamIfNeeded = async (
  hre: HardhatRuntimeEnvironment,
  {
    contractAlias,
    readMethod,
    readArgs,
    writeMethod,
    writeArgs,
    isCurrentValueUpdated = defaultIsCurrentValueUpdated,
    force,
    governorOverride,
  }: UpdateParamProps
): Promise<void> => {
  const {deployments} = hre
  const {read, execute, catchUnknownSigner} = deployments

  try {
    const currentValue = readArgs
      ? await read(contractAlias, readMethod, ...readArgs)
      : await read(contractAlias, readMethod)

    const {isArray} = Array

    // Checks if overriding `isCurrentValueUpdated()` is required
    const isOverrideRequired =
      !writeArgs ||
      (!isArray(currentValue) && writeArgs.length > 1) ||
      (isArray(currentValue) && writeArgs.length != currentValue.length)

    if (isOverrideRequired && isCurrentValueUpdated === defaultIsCurrentValueUpdated) {
      const e = Error(`You must override 'isCurrentValueUpdated()' function for ${contractAlias}.${writeMethod}()`)
      log(chalk.red(e.message))
      throw e
    }

    // Update value if needed
    if (!isCurrentValueUpdated(currentValue, writeArgs)) {
      // Determine the governor/owner address
      let governor: string
      if (governorOverride) {
        governor = governorOverride
      } else {
        // Try to read owner() first (for Ownable contracts), then fall back to other methods
        try {
          governor = await read(contractAlias, 'owner')
        } catch {
          // If owner() doesn't exist, this might be an AccessControl contract
          // In that case, use GOVERNOR from Address config
          governor = GOVERNOR
        }
      }

      const doExecute = async () => {
        return writeArgs
          ? execute(contractAlias, {from: governor, log: true}, writeMethod, ...writeArgs)
          : execute(contractAlias, {from: governor, log: true}, writeMethod)
      }

      const multiSigTx = await catchUnknownSigner(doExecute, {
        log: true,
      })

      if (multiSigTx) {
        if (force) {
          await executeForcedTxUsingMultiSig(hre, multiSigTx)
        } else {
          await saveForMultiSigBatchExecution(multiSigTx)
        }
      }
    }
  } catch (e) {
    log(chalk.red(`The function ${contractAlias}.${writeMethod}() failed.`))
    log(chalk.red('It is probably due to calling a newly implemented function'))
    log(chalk.red('If it is the case, run deployment scripts again after having the contracts upgraded'))
    throw e
  }
}

/**
 * Helper to deploy a non-upgradeable contract
 * Used for PeggedToken and Treasury which don't use proxies
 *
 * @param hre - Hardhat runtime environment
 * @param contractName - Name of the contract to deploy
 * @param args - Constructor arguments
 * @param contractArtifact - Artifact name when it differs from the alias
 * @param redeploy - Replace an existing deployment when its bytecode or args changed (periphery only)
 * @returns Deployed contract address
 */
export const deployNonUpgradeable = async (
  hre: HardhatRuntimeEnvironment,
  alias: string,
  args: unknown[],
  contractArtifact?: string,
  redeploy = false
): Promise<{address: string}> => {
  const {
    deployments: {deploy},
    getNamedAccounts,
  } = hre
  const {deployer} = await getNamedAccounts()

  const result = await deploy(alias, {
    contract: contractArtifact ?? alias,
    from: deployer,
    args,
    log: true,
    // Immutable core is never redeployed on bytecode drift (e.g. an OZ bump); already-deployed
    // wins over bytecode equality. New contracts (no prior record) still deploy.
    skipIfAlreadyDeployed: !redeploy,
  })

  return {address: result.address}
}

/**
 * Grant a role on an AccessControl contract
 *
 * @param hre - Hardhat runtime environment
 * @param contractAlias - Contract deployment alias
 * @param role - Role bytes32 hash
 * @param account - Address to grant role to
 */
export const grantRoleIfNeeded = async (
  hre: HardhatRuntimeEnvironment,
  contractAlias: string,
  role: string,
  account: string
): Promise<void> => {
  const {deployments} = hre
  const {read, execute, catchUnknownSigner} = deployments

  const hasRole = await read(contractAlias, 'hasRole', role, account)

  if (!hasRole) {
    // Get admin from contract (usually DEFAULT_ADMIN_ROLE holder)
    let admin: string
    try {
      admin = await read(contractAlias, 'owner')
    } catch {
      admin = GOVERNOR
    }

    const multiSigTx = await catchUnknownSigner(
      execute(contractAlias, {from: admin, log: true}, 'grantRole', role, account),
      {log: true}
    )

    if (multiSigTx) {
      await saveForMultiSigBatchExecution(multiSigTx)
    }
  }
}

/**
 * Revoke a role on an AccessControl contract
 *
 * @param hre - Hardhat runtime environment
 * @param contractAlias - Contract deployment alias
 * @param role - Role bytes32 hash
 * @param account - Address to revoke role from
 */
export const revokeRoleIfNeeded = async (
  hre: HardhatRuntimeEnvironment,
  contractAlias: string,
  role: string,
  account: string
): Promise<void> => {
  const {deployments} = hre
  const {read, execute, catchUnknownSigner} = deployments

  const hasRole = await read(contractAlias, 'hasRole', role, account)

  if (hasRole) {
    let admin: string
    try {
      admin = await read(contractAlias, 'owner')
    } catch {
      admin = GOVERNOR
    }

    const multiSigTx = await catchUnknownSigner(
      execute(contractAlias, {from: admin, log: true}, 'revokeRole', role, account),
      {log: true}
    )

    if (multiSigTx) {
      await saveForMultiSigBatchExecution(multiSigTx)
    }
  }
}
