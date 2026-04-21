import {HardhatUserConfig} from 'hardhat/types'
import '@nomicfoundation/hardhat-foundry'
import '@nomicfoundation/hardhat-chai-matchers'
import '@nomiclabs/hardhat-ethers'
import '@nomicfoundation/hardhat-verify'
import '@typechain/hardhat'
import 'hardhat-gas-reporter'
import 'solidity-coverage'
import 'hardhat-deploy'
import 'hardhat-log-remover'
import 'hardhat-contract-sizer'
import 'hardhat-spdx-license-identifier'
import './tasks/create-release'
import './tasks/impersonate-deployer'
import dotenv from 'dotenv'

dotenv.config()

const accounts = process.env.PRIVATE_KEY
  ? [process.env.PRIVATE_KEY]
  : process.env.MNEMONIC
    ? {mnemonic: process.env.MNEMONIC}
    : undefined
const deployer = process.env.DEPLOYER || 0

// Hardhat do not support adding chainId at runtime. Only way to set it in hardhat-config.js
// More info https://github.com/NomicFoundation/hardhat/issues/2167
function resolveChainId() {
  // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
  const FORK_CHAIN = process.env.FORK_CHAIN || 'ethereum'
  const deploy = ['deploy/scripts/ethereum']

  if (FORK_CHAIN == 'ethereum') {
    return {chainId: 1, deploy}
  }

  return {chainId: 31337, deploy}
}
const {chainId, deploy} = resolveChainId()

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  networks: {
    localhost: {
      saveDeployments: true,
      autoImpersonate: true,
      chainId,
      deploy,
    },
    hardhat: {
      // Note: Forking is being made from those test suites that need it
      saveDeployments: true,
      chainId,
      deploy,
      hardfork: 'cancun',
      chains: {
        // See: https://hardhat.org/hardhat-network/docs/guides/forking-other-networks#using-a-custom-hardfork-history
        1923: {hardforkHistory: {cancun: 1}},
        43111: {hardforkHistory: {cancun: 1}},
        9745: {hardforkHistory: {cancun: 1}},
        8453: {hardforkHistory: {cancun: 1}},
      },
    },
    ethereum: {
      url: process.env.ETHEREUM_NODE_URL || '',
      chainId: 1,
      gas: 6700000,
      accounts,
      deploy: ['deploy/scripts/ethereum'],
    },
    optimism: {
      url: process.env.OPTIMISM_NODE_URL || '',
      chainId: 10,
      gas: 8000000,
      deploy: ['deploy/scripts/optimism'],
      accounts,
    },
    base: {
      url: process.env.BASE_NODE_URL || '',
      chainId: 8453,
      gas: 8000000,
      deploy: ['deploy/scripts/base'],
      accounts,
    },
  },
  namedAccounts: {
    deployer: {
      default: 0, // First account from accounts array
    },
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: process.env.RUN_CONTRACT_SIZER === 'true',
    disambiguatePaths: false,
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === 'true',
    outputFile: 'gas-report.txt',
    noColors: true,
    excludeContracts: ['mock/'],
  },
  paths: {
    sources: './src',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },
  solidity: {
    compilers: [
      {
        version: '0.8.12',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: '0.8.30',
        settings: {
          evmVersion: 'cancun',
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || 'noApiKeyNeeded',
  },
  spdxLicenseIdentifier: {
    overwrite: false,
    runOnCompile: true,
  },
  typechain: {
    outDir: 'typechain',
  },
  mocha: {
    timeout: 200000,
    // Note: We can enable parallelism here instead of using the `--parallel`
    // flag on npm script but it would make coverage to fail
    // parallel: true
  },
}

export default config
