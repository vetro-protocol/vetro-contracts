import hre from 'hardhat'
import {getNetworkAddresses} from '../config'

const {chainId} = hre.network.config

// Re-export addresses from centralized config
// eslint-disable-next-line @typescript-eslint/no-non-null-assertion
export default getNetworkAddresses(chainId!)
