import {task} from 'hardhat/config'
import chalk from 'chalk'
import {UpgradableContracts} from '../deploy/config'

task('validate-upgrades', "Check each proxy can be upgraded to this repo's implementation without breaking storage")
  .addOptionalParam('only', 'Comma separated proxy aliases to check (default: all upgradeable contracts)')
  .setAction(async ({only}, hre) => {
    // Loaded here, not at config load: upgrades-core would otherwise slow down every hardhat command
    const {checkUpgradeSafety} = await import('../deploy/helpers/upgrade-safety')
    await hre.run('compile', {quiet: true})

    const aliases: string[] = only ? only.split(',') : Object.keys(UpgradableContracts)
    let failed = 0
    for (const alias of aliases) {
      const config = UpgradableContracts[alias]
      if (!config) throw new Error(`Unknown upgradeable alias ${alias}`)
      const {address: proxy} = await hre.deployments.get(`${config.alias}_Proxy`)

      // An error on one proxy (e.g. live source not found) must not hide the result of the others
      try {
        const result = await checkUpgradeSafety(hre, proxy, config.contract)
        const status = result.ok ? chalk.green('✓ safe') : chalk.red('✗ UNSAFE')
        console.log(`${status}  ${alias} (${proxy})`)
        console.log(`    live:    ${result.liveImplementation} = ${result.reference}`)
        console.log(`    upgrade: ${config.contract}`)
        if (!result.ok) {
          failed++
          console.log(result.report.replace(/^/gm, '    '))
        }
      } catch (error) {
        failed++
        console.log(`${chalk.red('✗ ERROR')}  ${alias} (${proxy})`)
        console.log((error as Error).message.replace(/^/gm, '    '))
      }
    }

    if (failed) throw new Error(`${failed} of ${aliases.length} upgrades are unsafe or could not be checked`)
  })

module.exports = {}
