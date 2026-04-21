import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {ContractAliases} from '../../../helpers'
import {saveForMultiSigBatchExecution} from '../../../helpers/gnosis-safe'
import Address from '../../../helpers/address'

const {VetBTCTreasury, FixedPriceFeedAdapter, DerivedPriceFeedAdapter} = ContractAliases

const TWENTY_FOUR_HOURS = 24 * 60 * 60

/**
 * Whitelist WBTC and cbBTC in the vetBTC Treasury
 *
 * Oracles:
 * - WBTC:  FixedPriceFeedAdapter  (WBTC/BTC = 1.0, hardcoded)
 * - cbBTC: DerivedPriceFeedAdapter (cbBTC/USD ÷ BTC/USD = cbBTC/BTC)
 *
 * Vaults: set WBTC_VAULT and CBBTC_VAULT in deploy/config.ts before running on mainnet.
 *
 * Note: Requires DEFAULT_ADMIN_ROLE on VetBTCTreasury.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  if (['hardhat'].includes(hre.network.name)) {
    console.log('Skipping VetBTCWhitelistTokens on local network (mainnet addresses not available)')
    return
  }

  const {deployments, getNamedAccounts} = hre
  const {read, execute, catchUnknownSigner, get} = deployments
  const {deployer} = await getNamedAccounts()

  const admin = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  const {address: wbtcOracleAddress} = await get(FixedPriceFeedAdapter)
  const {address: cbBtcOracleAddress} = await get(DerivedPriceFeedAdapter)

  const WHITELIST_TOKENS = [
    {
      name: 'WBTC',
      token: Address.WBTC,
      vault: Address.VETRO_VAULT_WBTC,
      oracle: wbtcOracleAddress,
      stalePeriod: TWENTY_FOUR_HOURS,
    },
    {
      name: 'cbBTC',
      token: Address.CBBTC,
      vault: Address.VETRO_VAULT_CBBTC,
      oracle: cbBtcOracleAddress,
      stalePeriod: TWENTY_FOUR_HOURS,
    },
  ]

  for (const tokenConfig of WHITELIST_TOKENS) {
    const {name, token, vault, oracle, stalePeriod} = tokenConfig

    if (vault === '0x0000000000000000000000000000000000000000') {
      console.log(`Skipping ${name}: vault address not configured in deploy/config.ts`)
      continue
    }

    const isWhitelisted = await read(VetBTCTreasury, 'isWhitelistedToken', token)

    if (!isWhitelisted) {
      console.log(`Adding ${name} to VetBTCTreasury whitelist...`)
      console.log(`  Token: ${token}`)
      console.log(`  Vault: ${vault}`)
      console.log(`  Oracle: ${oracle}`)
      console.log(`  Stale Period: ${stalePeriod} seconds (${stalePeriod / 3600} hours)`)

      const multiSigTx = await catchUnknownSigner(
        execute(VetBTCTreasury, {from: admin, log: true}, 'addToWhitelist', token, vault, oracle, stalePeriod),
        {log: true}
      )

      if (multiSigTx) {
        await saveForMultiSigBatchExecution(multiSigTx)
      }
    } else {
      console.log(`${name} is already whitelisted in VetBTCTreasury`)
    }
  }
}

func.tags = ['VetBTCWhitelistTokens']
func.dependencies = [VetBTCTreasury, FixedPriceFeedAdapter, DerivedPriceFeedAdapter]

export default func
