import fs from 'fs'
import chalk from 'chalk'
import {task, types} from 'hardhat/config'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {Contract} from 'ethers'
import {NetworkAddresses, UpgradableContracts} from '../deploy/config'
import {getImplementation, getProxyAdmin} from '../deploy/helpers/eip1967'
import {TREASURY_ABI} from './helpers/abis'
import {INSTANCES, InstanceAliases} from './helpers/instances'

// Minimal ABIs so the same snapshot can be read through the live and the upgraded implementation
const TOKEN_ABI = [
  'function totalSupply() view returns (uint256)',
  'function gateway() view returns (address)',
  'function treasury() view returns (address)',
  'function getBlacklistedAddresses() view returns (address[])',
]
const GATEWAY_ABI = [
  'function NAME() view returns (string)',
  'function owner() view returns (address)',
  'function treasury() view returns (address)',
  'function mintLimit() view returns (uint256)',
  'function amoMintLimit() view returns (uint256)',
  'function amoSupply() view returns (uint256)',
  'function withdrawalDelay() view returns (uint256)',
  'function withdrawalDelayEnabled() view returns (bool)',
  'function getInstantRedeemWhitelist() view returns (address[])',
  'function mintFee(address) view returns (uint256)',
  'function redeemFee(address) view returns (uint256)',
  'function pegBand(address) view returns (uint256)',
  'function getRedeemRequest(address) view returns (uint256 amountLocked, uint256 claimableAt)',
  'function maxMint() view returns (uint256)',
  'function maxAmoMint() view returns (uint256)',
  'function maxWithdraw(address) view returns (uint256)',
]
const VAULT_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function asset() view returns (address)',
  'function totalSupply() view returns (uint256)',
  'function owner() view returns (address)',
  'function pendingOwner() view returns (address)',
  'function yieldDistributor() view returns (address)',
  'function vaultRewards() view returns (address)',
  'function cooldownDuration() view returns (uint256)',
  'function cooldownEnabled() view returns (bool)',
  'function totalAssetsInCooldown() view returns (uint256)',
  'function nextRequestId() view returns (uint256)',
  'function instantWithdrawWhitelist(address) view returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function totalAssets() view returns (uint256)',
  'function convertToAssets(uint256) view returns (uint256)',
]
const DISTRIBUTOR_ABI = [
  'function asset() view returns (address)',
  'function vault() view returns (address)',
  'function yieldDuration() view returns (uint256)',
  'function periodFinish() view returns (uint256)',
  'function rewardRate() view returns (uint256)',
  'function lastUpdateTime() view returns (uint256)',
  'function defaultAdmin() view returns (address)',
  'function defaultAdminDelay() view returns (uint48)',
  'function pendingDefaultAdmin() view returns (address newAdmin, uint48 schedule)',
  'function DISTRIBUTOR_ROLE() view returns (bytes32)',
  'function hasRole(bytes32,address) view returns (bool)',
  'function pendingYield() view returns (uint256)',
]
const PROXY_ADMIN_ABI = ['function owner() view returns (address)']

const DEFAULT_ADMIN_ROLE = '0x0000000000000000000000000000000000000000000000000000000000000000'

// Accounts that hold or held a role or whitelist entry but are not discoverable on-chain (membership mappings are
// not enumerable). Collected from RoleGranted / InstantWithdrawWhitelistUpdated events; keep in sync with
// `_knownAccounts()` in test/fork/Upgrade.fork.t.sol.
const KNOWN_ACCOUNTS = [
  '0xF5F5195cF6998c57C651f9f0bBFA7cFC72a6FaC1', // sVetBTC instant withdrawer
  '0x26D4333E2E5572A5609ddEDd65748F8F237042D9', // vetBTC deployer, still a vetBTC Treasury keeper
  '0xE173b056eF552c7322040703dDfC1e0638A575d3', // VUSD deployer
  '0xAF27289D8612574A2bF58f30aD1835bA9D56Bfc2', // vetBTC Treasury role grantee
  '0x421382cf4e6eB73663ABb6d011d60Be66F126553', // Treasury role grantee (both stacks)
]

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any

// Turns ethers results (BigNumbers, Result arrays with named keys) into plain, diffable JSON
const toJson = (value: Json): Json => {
  if (value?._isBigNumber) return value.toString()
  if (Array.isArray(value)) {
    const named = Object.keys(value).filter((k) => isNaN(Number(k)))
    const record = value as Record<string, Json>
    if (named.length) return Object.fromEntries(named.map((k) => [k, toJson(record[k])]))
    return value.map(toJson)
  }
  return value
}

const REVERTED = 'REVERTED'

type BlockTag = number | 'latest'

/**
 * Reads at one block. `call` must succeed; `read` records a revert as REVERTED so a getter missing on one
 * implementation shows up as a diff instead of aborting the snapshot. Anything other than a revert (RPC errors,
 * timeouts) is rethrown, so it can never pass for a value.
 */
const makeReader = (blockTag: BlockTag) => {
  const call = async (contract: Contract, method: string, ...args: unknown[]) =>
    toJson(await contract[method](...args, {blockTag}))
  const read = async (contract: Contract, method: string, ...args: unknown[]) => {
    try {
      return await call(contract, method, ...args)
    } catch (error) {
      if ((error as {code?: string}).code === 'CALL_EXCEPTION') return REVERTED
      throw error
    }
  }
  const readAll = async (contract: Contract, methods: string[]) =>
    Object.fromEntries(await Promise.all(methods.map(async (m) => [m, await read(contract, m)])))
  return {blockTag, call, read, readAll}
}

type Reader = ReturnType<typeof makeReader>

const perAccount = async (accounts: string[], fn: (account: string) => Promise<Json>) =>
  Object.fromEntries(await Promise.all(accounts.map(async (a) => [a, await fn(a)])))

/**
 * Accounts whose roles and whitelist flags are recorded. Membership mappings are not enumerable on-chain, so this is
 * every account the protocol is known to grant something to: governance, keepers/managers, the Gateway's (enumerable)
 * instant-redeem whitelist, and any extra accounts passed in.
 */
const candidateAccounts = async (hre: HardhatRuntimeEnvironment, {call}: Reader, extra: string[]) => {
  const {getAddress} = hre.ethers.utils
  const accounts = new Set<string>([...KNOWN_ACCOUNTS, ...extra].map((a) => getAddress(a)))
  const {chainId} = await hre.ethers.provider.getNetwork()
  const config = NetworkAddresses[chainId] ?? {}
  for (const key of ['GOVERNOR', 'GNOSIS_SAFE_ADDRESS']) if (config[key]) accounts.add(getAddress(config[key]))
  for (const {Gateway: gateway, YieldManager: yieldManager} of Object.values(INSTANCES)) {
    const ym = await hre.deployments.getOrNull(yieldManager)
    if (ym) accounts.add(getAddress(ym.address))
    const gw = new Contract((await hre.deployments.get(gateway)).address, GATEWAY_ABI, hre.ethers.provider)
    // Not `read`: a reverted whitelist would silently shrink the accounts every other check covers
    for (const account of await call(gw, 'getInstantRedeemWhitelist')) accounts.add(getAddress(account))
  }
  accounts.delete(hre.ethers.constants.AddressZero)
  return [...accounts].sort()
}

const snapshotStack = async (
  hre: HardhatRuntimeEnvironment,
  {call, read, readAll}: Reader,
  aliases: InstanceAliases,
  accounts: string[]
) => {
  const {provider} = hre.ethers
  const at = async (alias: string, abi: string[]) =>
    new Contract((await hre.deployments.get(alias)).address, abi, provider)
  const token = await at(aliases.PeggedToken, TOKEN_ABI)
  const treasury = await at(aliases.Treasury, TREASURY_ABI)
  const gateway = await at(aliases.Gateway, GATEWAY_ABI)
  const vault = await at(aliases.StakingVault, VAULT_ABI)
  const distributor = await at(aliases.YieldDistributor, DISTRIBUTOR_ABI)

  // Inputs to the other reads must exist: a revert here would silently drop whole sections
  const tokens: string[] = await call(treasury, 'whitelistedTokens')
  const treasuryRoles = {
    DEFAULT_ADMIN_ROLE,
    KEEPER_ROLE: await call(treasury, 'KEEPER_ROLE'),
    UMM_ROLE: await call(treasury, 'UMM_ROLE'),
    MAINTAINER_ROLE: await call(treasury, 'MAINTAINER_ROLE'),
  }
  const distributorRole = await call(distributor, 'DISTRIBUTOR_ROLE')
  const decimals: number = await call(vault, 'decimals')

  // `state` is what an upgrade must never change; `derived` depends on prices/time and is reported for review
  const state = {
    token: await readAll(token, ['totalSupply', 'gateway', 'treasury', 'getBlacklistedAddresses']),
    treasury: {
      ...(await readAll(treasury, ['NAME', 'gateway', 'swapper', 'priceTolerance', 'defaultAdmin'])),
      whitelistedTokens: tokens,
      tokenConfig: await perAccount(tokens, (t) => read(treasury, 'tokenConfig', t)),
      roles: Object.fromEntries(
        await Promise.all(
          Object.entries(treasuryRoles).map(async ([name, role]) => [
            name,
            await perAccount(accounts, (a) => read(treasury, 'hasRole', role, a)),
          ])
        )
      ),
    },
    gateway: {
      ...(await readAll(gateway, [
        'NAME',
        'owner',
        'treasury',
        'mintLimit',
        'amoMintLimit',
        'amoSupply',
        'withdrawalDelay',
        'withdrawalDelayEnabled',
        'getInstantRedeemWhitelist',
      ])),
      fees: await perAccount(tokens, async (t) => ({
        mintFee: await read(gateway, 'mintFee', t),
        redeemFee: await read(gateway, 'redeemFee', t),
        pegBand: await read(gateway, 'pegBand', t),
      })),
      redeemRequests: await perAccount(accounts, (a) => read(gateway, 'getRedeemRequest', a)),
    },
    vault: {
      ...(await readAll(vault, [
        'name',
        'symbol',
        'decimals',
        'asset',
        'totalSupply',
        'owner',
        'pendingOwner',
        'yieldDistributor',
        'vaultRewards',
        'cooldownDuration',
        'cooldownEnabled',
        'totalAssetsInCooldown',
        'nextRequestId',
      ])),
      instantWithdrawWhitelist: await perAccount(accounts, (a) => read(vault, 'instantWithdrawWhitelist', a)),
      balances: await perAccount(accounts, (a) => read(vault, 'balanceOf', a)),
    },
    distributor: {
      ...(await readAll(distributor, [
        'asset',
        'vault',
        'yieldDuration',
        'periodFinish',
        'rewardRate',
        'lastUpdateTime',
        'defaultAdmin',
        'defaultAdminDelay',
        'pendingDefaultAdmin',
      ])),
      distributors: await perAccount(accounts, (a) => read(distributor, 'hasRole', distributorRole, a)),
    },
  }

  const derived = {
    treasury: {
      reserve: await read(treasury, 'reserve'),
      withdrawable: await perAccount(tokens, (t) => read(treasury, 'withdrawable', t)),
      prices: await perAccount(tokens, (t) => read(treasury, 'getPrice', t)),
    },
    gateway: {
      maxMint: await read(gateway, 'maxMint'),
      maxAmoMint: await read(gateway, 'maxAmoMint'),
      maxWithdraw: await perAccount(tokens, (t) => read(gateway, 'maxWithdraw', t)),
    },
    vault: {
      totalAssets: await read(vault, 'totalAssets'),
      sharePrice: await read(vault, 'convertToAssets', hre.ethers.BigNumber.from(10).pow(decimals)),
    },
    distributor: {pendingYield: await read(distributor, 'pendingYield')},
  }

  return {state, derived}
}

const takeSnapshot = async (hre: HardhatRuntimeEnvironment, blockTag: BlockTag, extraAccounts: string[]) => {
  const {provider} = hre.ethers
  const reader = makeReader(blockTag)
  const block = await provider.getBlock(blockTag)
  if (!block) throw new Error(`Block ${blockTag} does not exist on ${hre.network.name} (not mined yet?)`)
  const proxies: Json = {}
  for (const {alias} of Object.values(UpgradableContracts)) {
    const {address} = await hre.deployments.get(alias)
    const admin = await getProxyAdmin(provider, address, blockTag)
    proxies[alias] = {
      address,
      implementation: await getImplementation(provider, address, blockTag),
      admin,
      adminOwner: await reader.call(new Contract(admin, PROXY_ADMIN_ABI, provider), 'owner'),
    }
  }

  const accounts = await candidateAccounts(hre, reader, extraAccounts)
  const stacks: Json = {}
  for (const [name, aliases] of Object.entries(INSTANCES)) {
    stacks[name] = await snapshotStack(hre, reader, aliases, accounts)
  }

  return {network: hre.network.name, block: block.number, timestamp: block.timestamp, accounts, proxies, stacks}
}

// Flattens to `a.b.c -> value` so diffs point at the exact field
const flatten = (value: Json, prefix = '', out: Record<string, string> = {}) => {
  if (value !== null && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) flatten(v, prefix ? `${prefix}.${k}` : k, out)
  } else {
    out[prefix] = JSON.stringify(value)
  }
  return out
}

const diff = (before: Json, after: Json) => {
  const a = flatten(before)
  const b = flatten(after)
  return [...new Set([...Object.keys(a), ...Object.keys(b)])]
    .filter((k) => a[k] !== b[k])
    .map((k) => ({key: k, before: a[k] ?? '<missing>', after: b[k] ?? '<missing>'}))
}

task(
  'upgrade-snapshot',
  'Snapshot Vetro proxies and state; with --compare, fail if anything but implementations changed'
)
  .addOptionalParam('out', 'Write the snapshot JSON to this file')
  .addOptionalParam('compare', 'Snapshot JSON taken before the upgrade, to compare the current state against')
  .addOptionalParam('accounts', 'Comma separated extra accounts to record roles, whitelists and balances for')
  .addOptionalParam(
    'block',
    'Block to read at (default: latest). On mainnet, compare the block before the Safe execution with its block',
    undefined,
    types.int
  )
  .setAction(async ({out, compare, accounts, block}, hre) => {
    const extraAccounts: string[] = accounts ? accounts.split(',') : []
    if (compare) {
      // Read the same accounts as the baseline so new candidates don't show up as diffs
      extraAccounts.push(...JSON.parse(fs.readFileSync(compare, 'utf8')).accounts)
    }
    const snapshot = await takeSnapshot(hre, block ?? 'latest', extraAccounts)

    if (out) {
      fs.writeFileSync(out, `${JSON.stringify(snapshot, null, 2)}\n`)
      console.log(`Snapshot of block ${snapshot.block} written to ${out}`)
    }
    if (!compare) {
      if (!out) console.log(JSON.stringify(snapshot, null, 2))
      return
    }

    const before = JSON.parse(fs.readFileSync(compare, 'utf8'))
    console.log(`Comparing block ${before.block} (${compare}) with block ${snapshot.block}`)

    const upgraded = diff(before.proxies, snapshot.proxies)
    const unexpectedProxyChanges = upgraded.filter((d) => !d.key.endsWith('.implementation'))
    const stateChanges = Object.keys(INSTANCES).flatMap((name) =>
      diff(before.stacks[name].state, snapshot.stacks[name].state).map((d) => ({...d, key: `${name}.${d.key}`}))
    )
    const derivedChanges = Object.keys(INSTANCES).flatMap((name) =>
      diff(before.stacks[name].derived, snapshot.stacks[name].derived).map((d) => ({...d, key: `${name}.${d.key}`}))
    )

    const print = (d: {key: string; before: string; after: string}) => `    ${d.key}: ${d.before} -> ${d.after}`
    console.log(chalk.bold('\nUpgraded implementations:'))
    console.log(
      upgraded
        .filter((d) => d.key.endsWith('.implementation'))
        .map(print)
        .join('\n') || '    (none)'
    )
    console.log(chalk.bold('\nPrice/time dependent values (review, not enforced):'))
    console.log(derivedChanges.map(print).join('\n') || '    (unchanged)')

    // A value that reverts on both sides compares equal and proves nothing, so it fails too. A revert on one side
    // only is already a state change.
    const reverted = Object.keys(INSTANCES).flatMap((name) => {
      const a = flatten(before.stacks[name].state)
      const b = flatten(snapshot.stacks[name].state)
      return Object.keys(a)
        .filter((key) => a[key] === JSON.stringify(REVERTED) && b[key] === a[key])
        .map((key) => ({key: `${name}.${key}`, before: REVERTED, after: REVERTED}))
    })

    const failures = [...unexpectedProxyChanges, ...stateChanges, ...reverted]
    if (failures.length) {
      console.log(chalk.red.bold('\nUnexpected changes:'))
      console.log(chalk.red(failures.map(print).join('\n')))
      throw new Error(`${failures.length} values changed besides implementations`)
    }
    console.log(chalk.green('\n✓ Only implementations changed'))
  })

module.exports = {}
