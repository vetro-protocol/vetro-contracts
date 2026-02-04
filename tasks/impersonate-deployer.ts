import {task} from 'hardhat/config'
import {impersonateAccount, setBalance} from '@nomicfoundation/hardhat-network-helpers'
import {parseEther} from 'ethers/lib/utils'

task('impersonate-deployer', 'Impersonate `process.env.DEPLOYER` account').setAction(async () => {
  if (process.env.DEPLOYER) {
    const address = process.env.DEPLOYER
    await impersonateAccount(address)
    await setBalance(address, parseEther('1000000'))
  }
})
