import {DeployFunction} from 'hardhat-deploy/types'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {executeBatchUsingMultisig} from '../../helpers/gnosis-safe'

/**
 * Execute batched multisig transactions
 *
 * This is the FINAL deployment script that runs at the end.
 * It collects all deferred multisig transactions from the deployment
 * and either:
 *
 * On local networks (hardhat, localhost):
 * - Impersonates the Gnosis Safe
 * - Executes all transactions directly
 *
 * On production networks:
 * - Creates a batched proposal in Safe Transaction Service
 * - Logs the transaction hash
 * - Exits and requires re-running after multisig confirmation
 *
 * The batch file (multisig.batch.tmp.json) is cleaned up after execution.
 */
const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  await executeBatchUsingMultisig(hre)
}

func.tags = ['MultisigTxs']
func.runAtTheEnd = true

export default func
