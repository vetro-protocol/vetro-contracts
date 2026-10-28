import fs from 'fs'
import {network} from 'hardhat'
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

// The batch records where it was built and whether its run reached the proposal, so a leftover can only be proposed
// to the network it was built for, and only if no queued call is missing from it
type BatchFile = {
  network: string
  chainId: number | undefined
  complete: boolean
  txs: MetaTransactionData[]
}

const {log} = console

// Set by this process's first save, so later saves in the same run append to the batch it started
let batchStarted = false

// An empty file holds no txs (e.g. left by an older version of this helper), so only a non-empty one counts
const hasBatchFile = () => fs.existsSync(MULTI_SIG_TXS_FILE) && fs.statSync(MULTI_SIG_TXS_FILE).size > 0

const readBatch = (): BatchFile => {
  const json = JSON.parse(fs.readFileSync(MULTI_SIG_TXS_FILE).toString())
  // A bare array was written by an older version of this helper, which recorded neither network nor completeness
  if (Array.isArray(json)) {
    throw Error(
      `'${MULTI_SIG_TXS_FILE}' is in an older format that does not say which network it was built for or whether ` +
        'it is complete: discard it and re-run the deploy.'
    )
  }
  return json
}

const writeBatch = (txs: MetaTransactionData[], complete: boolean) => {
  const batch: BatchFile = {network: network.name, chainId: network.config.chainId, complete, txs}
  fs.writeFileSync(MULTI_SIG_TXS_FILE, JSON.stringify(batch, null, 2))
}

// A batch file present before this run's first save is left over from an aborted run: appending to or proposing it
// would mix stale calls into this batch. Re-running the deploy queues again whatever is still needed.
export const assertNoStaleBatch = () => {
  if (!batchStarted && hasBatchFile()) {
    throw Error(
      `'${MULTI_SIG_TXS_FILE}' has Safe txs from a previous run. Check the Safe queue, then propose them with ` +
        '`npx hardhat propose-safe-batch --network <network>` if only their proposal failed, or discard the file.'
    )
  }
}

/** The Safe txs this run has queued so far: a leftover batch file is not this run's and fails on the next save. */
export const queuedMultiSigTxs = (): MetaTransactionData[] => (batchStarted && hasBatchFile() ? readBatch().txs : [])

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
  // Validate first: a rejected tx must not start a batch or leave a file that blocks later runs
  const tx = prepareTx(rawTx)
  assertNoStaleBatch()
  batchStarted = true

  const current = hasBatchFile() ? readBatch().txs : []

  const alreadyStored = current.find(
    (i: MetaTransactionData) => i.to == tx.to && i.data == tx.data && i.value == tx.value
  )

  if (alreadyStored) {
    log(chalk.blue(`This multi-sig transaction is already saved in '${MULTI_SIG_TXS_FILE}'.`))
    return
  }

  writeBatch([...current, tx], false)

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
    const w = await impersonateAccountWithBalance(hre, safeAddress)
    for (const {to, data, value} of txs) {
      // Wait for the receipt: a tx that is only submitted, or mined but reverted, must not count as executed
      const receipt = await (await w.sendTransaction({to, data, value})).wait()
      log(chalk.blue(`  ${to} ${data.slice(0, 10)} executed in ${receipt.transactionHash}`))
    }
    log(chalk.blue('Because it is a test deployment, the transactions were executed by impersonated multi-sig.'))
  } else {
    const {deployer: delegateAddress} = await hre.getNamedAccounts()
    // Read url off the current network config; ethers getNetwork().name ("homestead") is not the
    // hardhat network key ("ethereum"), so looking it up in hre.config.networks misses.
    const provider = (hre.network.config as HttpNetworkConfig).url

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
    log(chalk.blue('That way the `hardhat-deploy` will be able to catch the changes and update `deployments/` files.'))
  }
}

/**
 * Execute all batched multisig transactions
 *
 * Reads accumulated transactions from the batch file,
 * proposes them to the Safe, then cleans up the file.
 */
export const executeBatchUsingMultisig = async (hre: HardhatRuntimeEnvironment): Promise<void> => {
  if (!hasBatchFile()) {
    return
  }
  assertNoStaleBatch()

  // Every call this run queues is in the batch by now: if the proposal fails, the leftover is safe to propose as is
  const {txs} = readBatch()
  writeBatch(txs, true)

  log(chalk.blue('Proposing multi-sig batch transaction...'))
  await proposeSafeTransaction(hre, txs)

  fs.unlinkSync(MULTI_SIG_TXS_FILE)
}

/**
 * Propose a batch left over from an aborted run exactly as it is: nothing is added to it, so it never mixes with a
 * new run's calls. The file is deleted once proposed (or, on a fork, executed by the impersonated Safe).
 */
export const proposeLeftoverBatch = async (hre: HardhatRuntimeEnvironment): Promise<MetaTransactionData[]> => {
  if (!hasBatchFile()) {
    throw Error(`'${MULTI_SIG_TXS_FILE}' has no Safe txs to propose.`)
  }
  // The in-process network is thrown away when the task exits, so "executing" the batch there would only lose it
  if (hre.network.name === 'hardhat') {
    throw Error('Pass the network the batch was built for, e.g. `--network ethereum`.')
  }
  const {network: builtFor, chainId, complete, txs} = readBatch()
  if (builtFor !== hre.network.name || chainId !== hre.network.config.chainId) {
    throw Error(`'${MULTI_SIG_TXS_FILE}' was built for ${builtFor} (chainId ${chainId}), not ${hre.network.name}.`)
  }
  // A run that aborted before its last deploy step left some of its calls out, so the batch may be missing
  // half of an upgrade
  if (!complete) {
    throw Error(
      `'${MULTI_SIG_TXS_FILE}' is from a run that aborted before proposing: discard it and re-run the deploy.`
    )
  }
  await proposeSafeTransaction(hre, txs)
  fs.unlinkSync(MULTI_SIG_TXS_FILE)
  return txs
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
