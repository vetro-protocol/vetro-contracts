import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {deployNonUpgradeable, ContractAliases} from '../../helpers'
import Address from '../../helpers/address'

const {ChainlinkFeedAdapter} = ContractAliases

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const {getNamedAccounts} = hre
  const {deployer} = await getNamedAccounts()

  // Use deployer as owner on local networks, GOVERNOR on production
  const owner = ['hardhat', 'localhost'].includes(hre.network.name) ? deployer : Address.GOVERNOR || deployer

  await deployNonUpgradeable(hre, ChainlinkFeedAdapter, [
    Address.CHAINLINK_BTC_USD_FEED, // feed
    owner, // owner
  ])
}

func.tags = [ChainlinkFeedAdapter]

export default func
