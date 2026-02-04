import chalk from 'chalk'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {Deployment} from 'hardhat-deploy/types'
import Address from './address'
import {executeForcedTxUsingMultiSig, saveForMultiSigBatchExecution} from './multisig-helpers'
import {UpgradableContracts, ContractAliases} from '../config'

const {GOVERNOR} = Address

const {log} = console

// ERC-1967 implementation slot
const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

// ERC-1967 admin slot
const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'

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
 * Get implementation address from proxy's ERC-1967 slot
 */
const getImplementation = async (hre: HardhatRuntimeEnvironment, proxyAddress: string): Promise<string> => {
  const implementationStorage = await hre.ethers.provider.getStorageAt(proxyAddress, IMPLEMENTATION_SLOT)
  return hre.ethers.utils.getAddress(`0x${implementationStorage.slice(-40)}`)
}

/**
 * Get ProxyAdmin address from proxy's ERC-1967 slot
 */
const getProxyAdmin = async (hre: HardhatRuntimeEnvironment, proxyAddress: string): Promise<string> => {
  const adminStorage = await hre.ethers.provider.getStorageAt(proxyAddress, ADMIN_SLOT)
  return hre.ethers.utils.getAddress(`0x${adminStorage.slice(-40)}`)
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
    deployments: {deploy, save, getOrNull, catchUnknownSigner},
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

  // 1. Deploy implementation
  const implDeployment = await deploy(implementationAlias, {
    contract,
    from: deployer,
    log: true,
  })

  // 2. Check if proxy already exists
  let proxyDeployment: Deployment | null = await getOrNull(proxyAlias)

  if (!proxyDeployment) {
    // First deployment - create new proxy

    // Encode initialize call
    const implContract = await ethers.getContractAt(contract, implDeployment.address)
    const encodedInitializeCall = implContract.interface.encodeFunctionData(methodName, initializeArgs)

    // Deploy OZ v5 TransparentUpgradeableProxy
    // Constructor: (address _logic, address initialOwner, bytes memory _data)
    // initialOwner becomes the owner of auto-created ProxyAdmin
    const proxyDeployResult = await deploy(proxyAlias, {
      contract:
        '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy',
      args: [implDeployment.address, owner, encodedInitializeCall],
      from: deployer,
      log: true,
    })

    // Get the auto-created ProxyAdmin address from ERC-1967 slot
    const proxyAdmin = await getProxyAdmin(hre, proxyDeployResult.address)
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
  const currentImpl = await getImplementation(hre, proxyDeployment.address)
  const newImplAddress = ethers.utils.getAddress(implDeployment.address)

  if (currentImpl !== newImplAddress) {
    log(chalk.yellow(`Upgrade needed for ${alias}`))
    log(chalk.yellow(`  Current implementation: ${currentImpl}`))
    log(chalk.yellow(`  New implementation: ${newImplAddress}`))

    // Get the ProxyAdmin address
    const proxyAdmin = await getProxyAdmin(hre, proxyDeployment.address)
    log(chalk.yellow(`  ProxyAdmin: ${proxyAdmin}`))

    // Upgrade via ProxyAdmin.upgradeAndCall
    const doUpgrade = async () => {
      const proxyAdminContract = await ethers.getContractAt(
        '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin',
        proxyAdmin
      )
      const tx = await proxyAdminContract.upgradeAndCall(proxyDeployment!.address, newImplAddress, '0x')
      return tx.wait()
    }

    const multiSigTx = await catchUnknownSigner(doUpgrade, {log: true})

    if (multiSigTx) {
      if (force) {
        await executeForcedTxUsingMultiSig(hre, multiSigTx)
      } else {
        await saveForMultiSigBatchExecution(multiSigTx)
      }
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
 * @returns Deployed contract address
 */
export const deployNonUpgradeable = async (
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  args: unknown[]
): Promise<{address: string}> => {
  const {
    deployments: {deploy},
    getNamedAccounts,
  } = hre
  const {deployer} = await getNamedAccounts()

  const result = await deploy(contractName, {
    from: deployer,
    args,
    log: true,
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
