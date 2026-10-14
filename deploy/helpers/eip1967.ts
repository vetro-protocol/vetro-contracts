import {providers, utils} from 'ethers'

// Kept free of `hardhat` imports so tasks loaded by hardhat.config.ts can use it

// ERC-1967 implementation slot
export const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

// ERC-1967 admin slot
export const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'

const readSlotAddress = async (
  provider: providers.Provider,
  address: string,
  slot: string,
  blockTag?: providers.BlockTag
): Promise<string> => utils.getAddress(`0x${(await provider.getStorageAt(address, slot, blockTag)).slice(-40)}`)

export const getImplementation = (provider: providers.Provider, proxy: string, blockTag?: providers.BlockTag) =>
  readSlotAddress(provider, proxy, IMPLEMENTATION_SLOT, blockTag)

export const getProxyAdmin = (provider: providers.Provider, proxy: string, blockTag?: providers.BlockTag) =>
  readSlotAddress(provider, proxy, ADMIN_SLOT, blockTag)
