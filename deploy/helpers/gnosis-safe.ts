import {OperationType, MetaTransactionData} from '@safe-global/safe-core-sdk-types'
import Address from './address'
import {ethers} from 'hardhat'
import Safe from '@safe-global/safe-core-sdk'
import SafeServiceClient from '@safe-global/safe-service-client'
import EthersAdapter from '@safe-global/safe-ethers-lib'
import {Signer} from 'ethers'
import {HardhatRuntimeEnvironment} from 'hardhat/types'

const {GNOSIS_SAFE_ADDRESS: safeAddress} = Address

/**
 * Gnosis Safe wrapper for proposing batched transactions
 *
 * Uses the Safe SDK and Transaction Service to create proposals
 * that can be signed and executed by Safe owners.
 */
export class GnosisSafe {
  constructor(protected safeClient: SafeServiceClient, protected safeSDK: Safe) {}

  /**
   * Propose a batch of transactions to the Safe
   *
   * Creates a batched transaction proposal with proper nonce handling.
   * The deployer signs the proposal, which can then be confirmed
   * by other Safe owners in the Safe UI.
   *
   * @param txs - Array of transactions to batch
   * @returns The Safe transaction hash for tracking
   */
  public async proposeTransaction(txs: MetaTransactionData[]): Promise<string> {
    const {safeClient, safeSDK} = this
    const delegateAddress = await this.safeSDK.getEthAdapter().getSignerAddress()
    if (!delegateAddress) {
      throw Error('delegate signer did not set')
    }

    // Mark all transactions as Call operations
    const safeTransactionData: MetaTransactionData[] = txs.map((tx) => ({...tx, operation: OperationType.Call}))

    // Get next nonce from Safe Transaction Service
    const nonce = await safeClient.getNextNonce(safeAddress)
    const safeTransaction = await safeSDK.createTransaction({safeTransactionData, options: {nonce}})
    const safeTxHash = await safeSDK.getTransactionHash(safeTransaction)
    const {data: senderSignature} = await safeSDK.signTransactionHash(safeTxHash)

    await safeClient.proposeTransaction({
      safeAddress,
      safeTransactionData: safeTransaction.data,
      safeTxHash,
      senderAddress: delegateAddress,
      senderSignature,
    })

    return safeTxHash
  }
}

/**
 * Factory for creating GnosisSafe instances
 *
 * Handles SDK initialization and network-specific configuration.
 */
export class GnosisSafeInitializer {
  /**
   * Initialize a GnosisSafe instance for the current network
   *
   * @param hre - Hardhat runtime environment
   * @param delegate - Signer that will propose transactions
   * @returns Configured GnosisSafe instance
   */
  public static async init(hre: HardhatRuntimeEnvironment, delegate: Signer): Promise<GnosisSafe> {
    const ethAdapter = new EthersAdapter({ethers, signerOrProvider: delegate})
    const safeSDK = await Safe.create({ethAdapter, safeAddress})
    const {name: chain} = hre.network

    // Safe Transaction Service URL for the network
    // Supports: mainnet, goerli, optimism, arbitrum, polygon, etc.
    const txServiceUrl = `https://safe-transaction-${chain}.safe.global`
    const safeClient = new SafeServiceClient({txServiceUrl, ethAdapter})

    return new GnosisSafe(safeClient, safeSDK)
  }
}
