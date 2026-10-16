import {task} from 'hardhat/config'
import chalk from 'chalk'

task(
  'propose-safe-batch',
  'Propose the Safe txs an aborted deploy left in multisig.batch.tmp.json, unchanged, then delete the file'
).setAction(async (_, hre) => {
  // Loaded here, not at config load: the helper reads network addresses through the hardhat runtime
  const {proposeLeftoverBatch, MULTI_SIG_TXS_FILE} = await import('../deploy/helpers/gnosis-safe')
  const transactions = await proposeLeftoverBatch(hre)
  console.log(chalk.green(`Done with ${transactions.length} Safe txs from '${MULTI_SIG_TXS_FILE}' (file deleted):`))
  for (const {to, data} of transactions) console.log(`    ${to} ${data.slice(0, 10)}`)
})

module.exports = {}
