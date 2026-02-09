import fs from 'fs'
import {HardhatRuntimeEnvironment, HttpNetworkConfig} from 'hardhat/types'
import chalk from 'chalk'
import SafeApiKit from '@safe-global/api-kit'
import Safe from '@safe-global/protocol-kit'
import {MetaTransactionData, OperationType} from '@safe-global/types-kit'
import Address from './address'
import {impersonateAccount, setBalance} from '@nomicfoundation/hardhat-network-helpers'
import {parseEther} from 'ethers/lib/utils'

export const MULTI_SIG_TXS_FILE = 'multisig.batch.tmp.json'

// Type returned by `hardhat-deploy`'s `catchUnknownSigner` function
type MultiSigTx = {
  from: string
  to?: string | undefined
  value?: string | undefined
  data?: string | undefined
}

const {log} = console

/**
 * Impersonate an account for local testing
 * Sets a high ETH balance and returns the signer
 */
const impersonateAccountWithBalance = async (hre: HardhatRuntimeEnvironment, address: string) => {
  await impersonateAccount(address)
  await setBalance(address, parseEther('1000000'))
  return await hre.ethers.getSigner(address)
}

/**
 * Parse `hardhat-deploy` transaction format to Safe transaction format
 */
const prepareTx = ({from, to, data, value}: MultiSigTx): MetaTransactionData => {
  if (!to || !data) {
    throw Error('The `to` and `data` args can not be null')
  }

  if (from !== Address.GNOSIS_SAFE_ADDRESS) {
    throw Error(`Trying to propose a multi-sig transaction but sender ('${from}') isn't the safe address.`)
  }

  return {to, data, value: value || '0'}
}

/**
 * Save a transaction for later batch execution
 *
 * Accumulates transactions in a temporary file for batching.
 * Prevents duplicate transactions from being stored.
 */
export const saveForMultiSigBatchExecution = async (rawTx: MultiSigTx): Promise<void> => {
  if (!fs.existsSync(MULTI_SIG_TXS_FILE)) {
    fs.closeSync(fs.openSync(MULTI_SIG_TXS_FILE, 'w'))
  }

  const file = fs.readFileSync(MULTI_SIG_TXS_FILE)

  const tx = prepareTx(rawTx)

  if (file.length == 0) {
    fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify([tx]))
  } else {
    const current = JSON.parse(file.toString()) as MetaTransactionData[]

    const alreadyStored = current.find(
      (i: MetaTransactionData) => i.to == tx.to && i.data == tx.data && i.value == tx.value
    )

    if (alreadyStored) {
      log(chalk.blue(`This multi-sig transaction is already saved in '${MULTI_SIG_TXS_FILE}'.`))
      return
    }

    const json = [...current, tx]
    fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(json))
  }

  log(chalk.blue(`Multi-sig transaction saved in '${MULTI_SIG_TXS_FILE}'.`))
}

/**
 * Propose transactions to Safe
 *
 * On local networks (hardhat, localhost):
 * - Impersonates the Safe and executes transactions directly
 *
 * On production networks:
 * - Creates a proposal via Safe Transaction Service
 * - Requires manual confirmation in Safe UI
 * - Requires DEPLOYER_PRIVATE_KEY env variable
 */
const proposeSafeTransaction = async (hre: HardhatRuntimeEnvironment, txs: MetaTransactionData[]) => {
  const chainId = BigInt(await hre.getChainId())
  const safeAddress = Address.GNOSIS_SAFE_ADDRESS

  if (['hardhat', 'localhost'].includes(hre.network.name)) {
    for (const tx of txs) {
      const {to, data} = tx
      const w = await impersonateAccountWithBalance(hre, safeAddress)
      await w.sendTransaction({to, data})
    }
    log(chalk.blue('Because it is a test deployment, the transactions were executed by impersonated multi-sig.'))
  } else {
    const {deployer: delegateAddress} = await hre.getNamedAccounts()
    const chainName = (await hre.ethers.provider.getNetwork()).name

    const config = hre.config.networks[chainName] as HttpNetworkConfig
    const provider = config.url

    if (!process.env.DEPLOYER_PRIVATE_KEY) {
      throw Error('DEPLOYER_PRIVATE_KEY environment variable is required for Safe transaction proposals')
    }

    const apiKit = new SafeApiKit({chainId, apiKey: process.env.SAFE_API_KEY})

    const protocolKit = await Safe.init({
      provider: provider,
      signer: process.env.DEPLOYER_PRIVATE_KEY, // Assumes that the deployer is also a delegate
      safeAddress,
    })

    const safeTransactionData: MetaTransactionData[] = txs.map((tx) => ({...tx, operation: OperationType.Call}))

    const safeTransaction = await protocolKit.createTransaction({
      transactions: safeTransactionData,
      onlyCalls: true,
      options: {nonce: Number(await apiKit.getNextNonce(safeAddress))},
    })

    const safeTxHash = await protocolKit.getTransactionHash(safeTransaction)
    const signature = await protocolKit.signHash(safeTxHash)

    await apiKit.proposeTransaction({
      safeAddress,
      safeTransactionData: safeTransaction.data,
      safeTxHash,
      senderAddress: delegateAddress,
      senderSignature: signature.data,
    })

    log(chalk.blue(`MultiSig tx '${safeTxHash}' was proposed.`))
    log(chalk.blue('Wait for tx to confirm (at least 2 confirmations is recommended).'))
    log(chalk.blue('After confirmation, you must run the deployment again.'))
    log(chalk.blue("That way the `hardhat-deploy` will be able to catch the changes and update `deployments/` files."))
  }
}

/**
 * Execute all batched multisig transactions
 *
 * Reads accumulated transactions from the batch file,
 * proposes them to the Safe, then cleans up the file.
 */
export const executeBatchUsingMultisig = async (hre: HardhatRuntimeEnvironment): Promise<void> => {
  if (!fs.existsSync(MULTI_SIG_TXS_FILE)) {
    return
  }

  const file = fs.readFileSync(MULTI_SIG_TXS_FILE)

  const transactions: MetaTransactionData[] = JSON.parse(file.toString())

  log(chalk.blue('Proposing multi-sig batch transaction...'))
  await proposeSafeTransaction(hre, transactions)

  fs.unlinkSync(MULTI_SIG_TXS_FILE)
}

/**
 * Execute a transaction immediately via multisig
 *
 * Used when a later deployment script depends on this transaction.
 * Saves the transaction to batch, executes all batched transactions,
 * then exits the process.
 *
 * @param hre - Hardhat runtime environment
 * @param rawTx - Transaction to execute
 */
export const executeForcedTxUsingMultiSig = async (
  hre: HardhatRuntimeEnvironment,
  rawTx: MultiSigTx
): Promise<void> => {
  await saveForMultiSigBatchExecution(rawTx)
  await executeBatchUsingMultisig(hre)
  process.exit()
}
