import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../helpers'
import {saveForMultiSigBatchExecution} from '../../helpers/gnosis-safe'
import Address from '../../helpers/address'

const {Treasury} = ContractAliases

// 24 hours in seconds
const TWENTY_FOUR_HOURS = 24 * 60 * 60
// 25 hours in seconds — used for feeds with a 24h Chainlink heartbeat to leave a 1h buffer
const TWENTY_FIVE_HOURS = 25 * 60 * 60

// Whitelisted tokens configuration
const WHITELIST_TOKENS = [
  {
    name: 'USDC',
    token: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    vault: '0xe3DA4B83C9dd4c4D185ecE42077462b3F35c454a', // Vetro Vault USDC (vvUSDC)
    oracle: '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6',
    stalePeriod: TWENTY_FOUR_HOURS,
  },
  {
    name: 'USDT',
    token: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    vault: '0x6d134cAAD0CA29Cd6ea145f6C0DC766076690547', // Vetro Vault USDT
    oracle: '0x3E7d1eAB13ad0104d2750B8863b489D65364e32D',
    stalePeriod: TWENTY_FOUR_HOURS,
  },
  {
    name: 'frxUSD',
    token: '0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29',
    vault: '0xBd44B65cE2b7c736724E0AE7e008CE3Fb00697d8', // Vetro Vault frxUSD (vvfrxUSD)
    oracle: '0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83', // frxUSD/USD, 24h heartbeat
    stalePeriod: TWENTY_FIVE_HOURS,
  },
]

/**
 * Whitelist tokens in Treasury
 *
 * Adds approved tokens to the Treasury whitelist with their associated:
 * - Vault address (where tokens are deposited)
 * - Chainlink oracle address (for price feeds)
 * - Stale period (maximum oracle data age)
 *
 * Note: Requires DEFAULT_ADMIN_ROLE on Treasury.
 * On production networks, transactions will be batched for multisig execution.
 *
 * IMPORTANT: This script only runs on mainnet or forked networks since
 * it references mainnet contract addresses (USDC, USDT, vaults, oracles).
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  // Skip on non-mainnet networks (tokens don't exist on local hardhat)
  if (['hardhat'].includes(hre.network.name)) {
    console.log('Skipping WhitelistTokens on local network (mainnet addresses not available)')
    return
  }

  const {deployments, getNamedAccounts} = hre
  const {read, execute, catchUnknownSigner} = deployments
  const {deployer} = await getNamedAccounts()

  // Use deployer on local networks, GOVERNOR on production
  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  for (const tokenConfig of WHITELIST_TOKENS) {
    const {name, token, vault, oracle, stalePeriod} = tokenConfig

    // Check if token is already whitelisted
    const isWhitelisted = await read(Treasury, 'isWhitelistedToken', token)

    if (!isWhitelisted) {
      console.log(`Adding ${name} to Treasury whitelist...`)
      console.log(`  Token: ${token}`)
      console.log(`  Vault: ${vault}`)
      console.log(`  Oracle: ${oracle}`)
      console.log(`  Stale Period: ${stalePeriod} seconds (${stalePeriod / 3600} hours)`)

      const multiSigTx = await catchUnknownSigner(
        execute(Treasury, {from: admin, log: true}, 'addToWhitelist', token, vault, oracle, stalePeriod),
        {log: true}
      )

      if (multiSigTx) {
        await saveForMultiSigBatchExecution(multiSigTx)
      }
    } else {
      console.log(`${name} is already whitelisted in Treasury`)
    }
  }
}

func.tags = ['WhitelistTokens']
func.dependencies = [Treasury]

export default func
