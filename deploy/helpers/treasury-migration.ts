import chalk from 'chalk'
import {BigNumber, Contract, ethers} from 'ethers'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import Address from './address'
import {getImplementation, getProxyAdmin} from './eip1967'
import {deployUpgradable} from '.'
import {assertNoStaleBatch, queuedMultiSigTxs, saveForMultiSigBatchExecution} from './gnosis-safe'

const {log} = console

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const DEFAULT_ADMIN_ROLE = '0x0000000000000000000000000000000000000000000000000000000000000000'
const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

/** Opt-in: a routine deploy run never starts a migration, it has to be asked for. */
export const MIGRATE_TREASURY_ENV = 'MIGRATE_TREASURY'

const TREASURY_ABI = [
  'function owner() view returns (address)',
  'function PEGGED_TOKEN() view returns (address)',
  'function whitelistedTokens() view returns (address[])',
  'function isWhitelistedToken(address token_) view returns (bool)',
  'function tokenConfig(address token_) view returns (address vault, address oracle, uint256 stalePeriod, bool depositActive, bool withdrawActive, uint8 decimals)',
  'function priceTolerance() view returns (uint256)',
  'function swapper() view returns (address)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function defaultAdminDelay() view returns (uint48)',
  'function pendingDefaultAdmin() view returns (address newAdmin, uint48 schedule)',
  'function pendingDefaultAdminDelay() view returns (uint48 newDelay, uint48 schedule)',
  'function addToWhitelist(address token_, address vault_, address oracle_, uint256 stalePeriod_)',
  'function grantRole(bytes32 role, address account)',
  'function revokeRole(bytes32 role, address account)',
  'function pegBand(address token_) view returns (uint256)',
  'function updatePegBand(address token_, uint256 newPegBand_)',
  'function updatePriceTolerance(uint256 newPriceTolerance_)',
  'function updateSwapper(address swapper_)',
  'function setDepositActive(address token_, bool active_)',
  'function setWithdrawActive(address token_, bool active_)',
  'function migrate(address newTreasury_)',
  'event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)',
  'event Migrated(address indexed newTreasury)',
]

const PEGGED_TOKEN_ABI = [
  'function owner() view returns (address)',
  'function gateway() view returns (address)',
  'function treasury() view returns (address)',
  'function updateTreasury(address newTreasury_)',
]

// A Treasury from before the migration has no peg band: the Gateway held it
const GATEWAY_ABI = ['function pegBand(address token_) view returns (uint256)']

const YIELD_VAULT_ABI = [
  'function isWhitelisted(address account_) view returns (bool)',
  'function maintainers() view returns (address[])',
  'function addToWhitelist(address account_)',
  'function removeFromWhitelist(address account_)',
]

const ERC20_ABI = [
  'function balanceOf(address account_) view returns (uint256)',
  'function symbol() view returns (string)',
  'event Transfer(address indexed from, address indexed to, uint256 value)',
]

interface TokenState {
  token: string
  vault: string
  oracle: string
  stalePeriod: BigNumber
  depositActive: boolean
  withdrawActive: boolean
  pegBand: BigNumber
}

interface TreasuryState {
  admin: string
  adminDelay: number
  // A started admin transfer or delay change, '' if none. Neither can be copied: both run on the admin delay
  pendingAdminChange: string
  peggedToken: string
  tokens: TokenState[]
  priceTolerance: BigNumber
  swapper: string
  // role => holders, DEFAULT_ADMIN_ROLE excluded: it is set at deployment and moves only through the delayed transfer
  roles: Map<string, string[]>
}

interface SafeCall {
  to: string
  data: string
  description: string
}

// Recorded on the `_Previous` deployment when the batch is built, so later runs can tell whether it still holds
interface MigrationRecord {
  newTreasury: string
  calls: SafeCall[]
}

type BlockTag = number | 'latest'

export interface MigrateTreasuryProps {
  peggedTokenAlias: string
  treasuryAlias: string
}

const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase()

const previousAlias = (treasuryAlias: string) => `${treasuryAlias}_Previous`

const short = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`

const ROLE_NAMES = new Map(['KEEPER_ROLE', 'MAINTAINER_ROLE', 'UMM_ROLE'].map((name) => [ethers.utils.id(name), name]))
const roleName = (role: string) => ROLE_NAMES.get(role) ?? role

const treasuryInterface = new ethers.utils.Interface(TREASURY_ABI)

/** Every `treasury` event matching `topics` from `fromBlock` to `blockTag`, fetched in chunks the node accepts. */
const treasuryLogs = async (
  hre: HardhatRuntimeEnvironment,
  treasury: string,
  topics: (string | null)[],
  fromBlock: number,
  blockTag: BlockTag
) => {
  const {provider} = hre.ethers
  const toBlock = blockTag === 'latest' ? await provider.getBlockNumber() : blockTag
  const logs = []
  let step = 500_000
  for (let start = fromBlock; start <= toBlock; ) {
    const end = Math.min(start + step - 1, toBlock)
    try {
      logs.push(...(await provider.getLogs({address: treasury, topics, fromBlock: start, toBlock: end})))
      start = end + 1
    } catch (error) {
      // Nodes cap the range or the result size differently, so narrow the window until one answers
      if (step <= 1_000) throw error
      step = Math.floor(step / 2)
    }
  }
  return logs
}

/**
 * Current holders of every role ever granted on `treasury`. AccessControl does not enumerate members, so candidates
 * come from RoleGranted events and only those still holding the role count.
 */
const readRoles = async (
  hre: HardhatRuntimeEnvironment,
  treasury: Contract,
  fromBlock: number,
  blockTag: BlockTag
): Promise<Map<string, string[]>> => {
  const candidates = new Map<string, Set<string>>()
  const topics = [treasuryInterface.getEventTopic('RoleGranted')]
  for (const entry of await treasuryLogs(hre, treasury.address, topics, fromBlock, blockTag)) {
    const {role, account} = treasuryInterface.parseLog(entry).args
    if (role === DEFAULT_ADMIN_ROLE) continue
    if (!candidates.has(role)) candidates.set(role, new Set())
    candidates.get(role)!.add(hre.ethers.utils.getAddress(account))
  }

  const roles = new Map<string, string[]>()
  for (const [role, accounts] of candidates) {
    const holders: string[] = []
    for (const account of accounts) {
      if (await treasury.hasRole(role, account, {blockTag})) holders.push(account)
    }
    roles.set(role, holders.sort())
  }
  return roles
}

/** The Gateway a live Treasury's peg bands are read from */
const bandsOf = async (hre: HardhatRuntimeEnvironment, peggedToken: Contract, blockTag: BlockTag = 'latest') =>
  hre.ethers.getContractAt(GATEWAY_ABI, await peggedToken.gateway({blockTag}))

/** `bands` holds the peg bands: the Gateway for a Treasury from before the migration, else the Treasury itself */
const readState = async (
  hre: HardhatRuntimeEnvironment,
  treasury: Contract,
  bands: Contract,
  fromBlock: number,
  blockTag: BlockTag = 'latest'
) => {
  const tokens: TokenState[] = []
  for (const token of (await treasury.whitelistedTokens({blockTag})) as string[]) {
    const {vault, oracle, stalePeriod, depositActive, withdrawActive} = await treasury.tokenConfig(token, {blockTag})
    const pegBand: BigNumber = await bands.pegBand(token, {blockTag})
    tokens.push({token, vault, oracle, stalePeriod, depositActive, withdrawActive, pegBand})
  }
  const [pendingAdmin, adminSchedule] = await treasury.pendingDefaultAdmin({blockTag})
  const [pendingDelay, delaySchedule] = await treasury.pendingDefaultAdminDelay({blockTag})
  let pendingAdminChange = ''
  if (adminSchedule > 0) pendingAdminChange = `admin transfer to ${pendingAdmin}`
  else if (delaySchedule > 0) pendingAdminChange = `admin delay change to ${pendingDelay}s`
  const state: TreasuryState = {
    admin: await treasury.owner({blockTag}),
    adminDelay: await treasury.defaultAdminDelay({blockTag}),
    pendingAdminChange,
    peggedToken: await treasury.PEGGED_TOKEN({blockTag}),
    tokens,
    priceTolerance: await treasury.priceTolerance({blockTag}),
    swapper: await treasury.swapper({blockTag}),
    roles: await readRoles(hre, treasury, fromBlock, blockTag),
  }
  return state
}

/**
 * Whether a yield vault gates its depositors, and if so whether it lets `account` in.
 *
 * Only a successful `isWhitelisted` call proves the gate exists; a failed one can be a revert, a missing function or
 * a dropped connection alike. So absence is settled against the code the vault runs (through its proxy, if any), and
 * anything still ambiguous refuses: migrating without the whitelist strands the shares in a Treasury that can neither
 * deposit nor withdraw them.
 */
const readVaultGate = async (
  hre: HardhatRuntimeEnvironment,
  vault: Contract,
  account: string,
  blockTag: BlockTag = 'latest'
) => {
  try {
    return {gated: true, whitelisted: (await vault.isWhitelisted(account, {blockTag})) as boolean}
  } catch (error) {
    const {provider} = hre.ethers
    const {hexZeroPad, getAddress} = hre.ethers.utils
    const slot = hexZeroPad(await provider.getStorageAt(vault.address, IMPLEMENTATION_SLOT, blockTag), 32)
    const implementation = getAddress(`0x${slot.slice(26)}`)
    const code = await provider.getCode(implementation === ZERO_ADDRESS ? vault.address : implementation, blockTag)
    const selector = vault.interface.getSighash('isWhitelisted').slice(2)
    if (code === '0x' || code.includes(selector)) {
      throw Error(`Could not tell whether yield vault ${vault.address} whitelists ${account}: ${error}`)
    }
    return {gated: false, whitelisted: false}
  }
}

const symbolOf = async (hre: HardhatRuntimeEnvironment, token: string) =>
  (await hre.ethers.getContractAt(ERC20_ABI, token)).symbol() as Promise<string>

/** Each distinct yield vault of the live collateral, once even if two tokens shared one. */
const vaultsOf = (state: TreasuryState) => {
  const vaults = new Map<string, string>()
  for (const {token, vault} of state.tokens)
    if (!vaults.has(vault.toLowerCase())) vaults.set(vault.toLowerCase(), token)
  return [...vaults.entries()].map(([vault, token]) => ({vault: ethers.utils.getAddress(vault), token}))
}

/**
 * Everything the batch needs from the Safe, checked before anything is deployed or recorded: the batch is signed by
 * the Safe alone, so a call it cannot sign would leave a deployed Treasury nobody can finish the migration for.
 */
const assertSafeCanSign = async (
  hre: HardhatRuntimeEnvironment,
  {
    safe,
    peggedToken,
    oldTreasury,
    oldState,
  }: {safe: string; peggedToken: Contract; oldTreasury: Contract; oldState: TreasuryState}
) => {
  for (const [name, account] of [
    ['live Treasury admin', oldState.admin],
    ['PeggedToken owner', await peggedToken.owner()],
  ]) {
    if (!sameAddress(account, safe))
      throw Error(`${name} is ${account}, not the Safe ${safe}: one Safe batch cannot sign it`)
  }
  assertNoAdminChangePending(oldState)
  for (const {vault: vaultAddress} of vaultsOf(oldState)) {
    const vault = await hre.ethers.getContractAt(YIELD_VAULT_ABI, vaultAddress)
    const {gated} = await readVaultGate(hre, vault, oldTreasury.address)
    if (!gated) continue
    const maintainers: string[] = await vault.maintainers()
    if (!maintainers.some((m) => sameAddress(m, safe))) {
      throw Error(`The Safe is not a maintainer of yield vault ${vaultAddress}, so it cannot move the whitelist`)
    }
  }
}

const assertNoAdminChangePending = ({pendingAdminChange}: TreasuryState) => {
  if (pendingAdminChange) {
    throw Error(
      `The live Treasury has a pending ${pendingAdminChange}, which the new Treasury cannot copy. Complete or ` +
        'cancel it first.'
    )
  }
}

/**
 * The migration batch mirrors the live Treasury as read now. A call already queued in this run for either Treasury
 * would execute first and change what the copy was taken from. A batch file left over from an aborted run would
 * fail the first save, after the new Treasury is deployed.
 */
const assertNothingQueuedFor = (addresses: string[]) => {
  assertNoStaleBatch()
  const queued = queuedMultiSigTxs().filter(({to}) => addresses.some((a) => sameAddress(a, to)))
  if (queued.length > 0) {
    throw Error(
      `This run already queued ${queued.length} Safe call(s) to ${addresses.join(', ')}. Build the migration with ` +
        'its own tags (and others that do not touch these contracts), then queue those calls after it executes.'
    )
  }
}

/**
 * The Safe calls that make `newState` an exact copy of `oldState`, then hand custody over. Everything is signed by
 * the Safe, so the batch shows each copied value; nothing is set beforehand by the deployer.
 */
const buildMirrorBatch = async (
  hre: HardhatRuntimeEnvironment,
  {
    safe,
    peggedToken,
    peggedTokenAlias,
    oldTreasury,
    newTreasury,
    oldState,
    newState,
  }: {
    safe: string
    peggedToken: Contract
    peggedTokenAlias: string
    oldTreasury: Contract
    newTreasury: Contract
    oldState: TreasuryState
    newState: TreasuryState
  }
): Promise<SafeCall[]> => {
  const calls: SafeCall[] = []
  const call = (target: Contract, method: string, args: unknown[], description: string) =>
    calls.push({to: target.address, data: target.interface.encodeFunctionData(method, args), description})
  const target = `Treasury ${short(newTreasury.address)}`

  // 1. The yield vaults take deposits and withdrawals from whitelisted callers only
  for (const {token, vault: vaultAddress} of vaultsOf(oldState)) {
    const vault = await hre.ethers.getContractAt(YIELD_VAULT_ABI, vaultAddress)
    const {gated, whitelisted} = await readVaultGate(hre, vault, newTreasury.address)
    if (!gated || whitelisted) continue
    call(
      vault,
      'addToWhitelist',
      [newTreasury.address],
      `vault ${short(vaultAddress)} (${await symbolOf(hre, token)}).addToWhitelist(${target})`
    )
  }

  // 2. Collateral, in the live order. addToWhitelist opens deposits and withdrawals, so flags are set in step 4
  const flags = new Map<string, {depositActive: boolean; withdrawActive: boolean}>()
  for (const t of newState.tokens) {
    if (!oldState.tokens.some((o) => sameAddress(o.token, t.token))) {
      throw Error(`${t.token} is whitelisted on the new Treasury but not on the live one`)
    }
  }
  for (const t of oldState.tokens) {
    const current = newState.tokens.find((n) => sameAddress(n.token, t.token))
    if (current) {
      if (
        !sameAddress(current.vault, t.vault) ||
        !sameAddress(current.oracle, t.oracle) ||
        !current.stalePeriod.eq(t.stalePeriod)
      ) {
        throw Error(`${t.token} is already on the new Treasury with a different vault, oracle or stalePeriod`)
      }
      flags.set(t.token, current)
      continue
    }
    const symbol = await symbolOf(hre, t.token)
    call(
      newTreasury,
      'addToWhitelist',
      [t.token, t.vault, t.oracle, t.stalePeriod],
      `${target}.addToWhitelist(${symbol}, vault ${short(t.vault)}, oracle ${short(t.oracle)}, stalePeriod ${
        t.stalePeriod
      })`
    )
    flags.set(t.token, {depositActive: true, withdrawActive: true})
  }

  // 3. Every live role holder, and nobody else
  const allRoles = new Set([...oldState.roles.keys(), ...newState.roles.keys()])
  const desired = (role: string) => oldState.roles.get(role) ?? []
  const current = (role: string) => newState.roles.get(role) ?? []
  const holds = (holders: string[], account: string) => holders.some((h) => sameAddress(h, account))

  for (const role of allRoles) {
    for (const account of desired(role)) {
      if (!holds(current(role), account)) {
        call(newTreasury, 'grantRole', [role, account], `${target}.grantRole(${roleName(role)}, ${account})`)
      }
    }
  }

  // 4. Settings. The Safe signs them, so it holds the role they need for the batch only, unless it holds it live
  const keeperRole = ethers.utils.id('KEEPER_ROLE')
  const maintainerRole = ethers.utils.id('MAINTAINER_ROLE')
  const settings: SafeCall[] = []
  const setting = (method: string, args: unknown[], description: string) =>
    settings.push({to: newTreasury.address, data: newTreasury.interface.encodeFunctionData(method, args), description})
  const needs = new Set<string>()

  if (!newState.priceTolerance.eq(oldState.priceTolerance)) {
    needs.add(maintainerRole)
    setting(
      'updatePriceTolerance',
      [oldState.priceTolerance],
      `${target}.updatePriceTolerance(${oldState.priceTolerance})`
    )
  }
  if (!sameAddress(newState.swapper, oldState.swapper)) {
    if (sameAddress(oldState.swapper, ZERO_ADDRESS)) throw Error('The new Treasury has a swapper the live one does not')
    needs.add(maintainerRole)
    setting('updateSwapper', [oldState.swapper], `${target}.updateSwapper(${oldState.swapper})`)
  }
  // The Safe is the new Treasury's admin. A band must be below priceTolerance, which is set above
  for (const t of oldState.tokens) {
    const current = newState.tokens.find((n) => sameAddress(n.token, t.token))?.pegBand ?? BigNumber.from(0)
    if (current.eq(t.pegBand)) continue
    const symbol = await symbolOf(hre, t.token)
    if (t.pegBand.gte(oldState.priceTolerance)) {
      throw Error(
        `The live ${symbol} peg band ${t.pegBand} is not below priceTolerance ${oldState.priceTolerance}, so the ` +
          'Gateway ignores it and the new Treasury would refuse it. Lower it on the Gateway first.'
      )
    }
    setting('updatePegBand', [t.token, t.pegBand], `${target}.updatePegBand(${symbol}, ${t.pegBand})`)
  }
  for (const t of oldState.tokens) {
    const {depositActive, withdrawActive} = flags.get(t.token)!
    const symbol = await symbolOf(hre, t.token)
    if (depositActive !== t.depositActive) {
      needs.add(keeperRole)
      setting(
        'setDepositActive',
        [t.token, t.depositActive],
        `${target}.setDepositActive(${symbol}, ${t.depositActive})`
      )
    }
    if (withdrawActive !== t.withdrawActive) {
      needs.add(keeperRole)
      setting(
        'setWithdrawActive',
        [t.token, t.withdrawActive],
        `${target}.setWithdrawActive(${symbol}, ${t.withdrawActive})`
      )
    }
  }

  const temporary = [...needs].filter((role) => !holds(desired(role), safe) && !holds(current(role), safe))
  for (const role of temporary) {
    call(newTreasury, 'grantRole', [role, safe], `${target}.grantRole(${roleName(role)}, Safe) for the settings below`)
  }
  calls.push(...settings)
  for (const role of temporary) {
    call(newTreasury, 'revokeRole', [role, safe], `${target}.revokeRole(${roleName(role)}, Safe)`)
  }

  // 5. Roles the new Treasury holds but the live one does not
  for (const role of allRoles) {
    for (const account of current(role)) {
      if (!holds(desired(role), account)) {
        call(newTreasury, 'revokeRole', [role, account], `${target}.revokeRole(${roleName(role)}, ${account})`)
      }
    }
  }

  // 6. Hand custody over. migrate reverts unless the PeggedToken already points at the new Treasury
  call(peggedToken, 'updateTreasury', [newTreasury.address], `${peggedTokenAlias}.updateTreasury(${target})`)
  call(oldTreasury, 'migrate', [newTreasury.address], `Treasury ${short(oldTreasury.address)}.migrate(${target})`)

  // 7. The emptied Treasury loses its vault access. Shares move by plain transfer, so migrate did not need it
  for (const {token, vault: vaultAddress} of vaultsOf(oldState)) {
    const vault = await hre.ethers.getContractAt(YIELD_VAULT_ABI, vaultAddress)
    const {gated, whitelisted} = await readVaultGate(hre, vault, oldTreasury.address)
    if (!gated || !whitelisted) continue
    call(
      vault,
      'removeFromWhitelist',
      [oldTreasury.address],
      `vault ${short(vaultAddress)} (${await symbolOf(hre, token)}).removeFromWhitelist(Treasury ${short(
        oldTreasury.address
      )})`
    )
  }

  return calls
}

/**
 * The new Treasury must have been an exact copy of the old one, and must have taken all its collateral, when the
 * migration executed. All of it is read at that block, so the result does not change with later config changes or
 * with dust anyone can send to the emptied Treasury. Only the old Treasury's removal from the vaults is read now.
 * A change made later in that same block shows up as a difference; docs/OPERATIONS.md has the recovery.
 */
const verifyMigrated = async (
  hre: HardhatRuntimeEnvironment,
  {
    peggedToken,
    oldTreasury,
    newTreasury,
    oldFromBlock,
    newFromBlock,
  }: {
    peggedToken: Contract
    oldTreasury: Contract
    newTreasury: Contract
    oldFromBlock: number
    newFromBlock: number
  }
) => {
  const topics = [treasuryInterface.getEventTopic('Migrated'), ethers.utils.hexZeroPad(newTreasury.address, 32)]
  const [migrated] = await treasuryLogs(hre, oldTreasury.address, topics, newFromBlock, 'latest')
  if (!migrated) {
    throw Error(
      `The PeggedToken points at ${newTreasury.address} but ${oldTreasury.address} never migrated to it: the Safe ` +
        `must call migrate(${newTreasury.address}) on it`
    )
  }
  const blockTag = migrated.blockNumber
  log(chalk.blue(`  reading both Treasuries at block ${blockTag}, where the migration executed`))

  const problems: string[] = []
  const oldState = await readState(hre, oldTreasury, await bandsOf(hre, peggedToken, blockTag), oldFromBlock, blockTag)
  const newState = await readState(hre, newTreasury, newTreasury, newFromBlock, blockTag)

  const pointsAt: string = await peggedToken.treasury({blockTag})
  if (!sameAddress(pointsAt, newTreasury.address)) problems.push(`the PeggedToken pointed at ${pointsAt}`)

  const tokensOf = (s: TreasuryState) => s.tokens.map((t) => t.token.toLowerCase()).join(',')
  if (tokensOf(oldState) !== tokensOf(newState)) {
    problems.push(`whitelisted tokens differ: ${tokensOf(oldState)} vs ${tokensOf(newState)}`)
  }
  for (const o of oldState.tokens) {
    const n = newState.tokens.find((t) => sameAddress(t.token, o.token))
    if (!n) continue
    for (const key of ['vault', 'oracle'] as const) {
      if (!sameAddress(o[key], n[key])) problems.push(`${o.token} ${key}: ${o[key]} vs ${n[key]}`)
    }
    if (!o.stalePeriod.eq(n.stalePeriod)) problems.push(`${o.token} stalePeriod: ${o.stalePeriod} vs ${n.stalePeriod}`)
    if (!o.pegBand.eq(n.pegBand)) problems.push(`${o.token} pegBand: ${o.pegBand} vs ${n.pegBand}`)
    for (const key of ['depositActive', 'withdrawActive'] as const) {
      if (o[key] !== n[key]) problems.push(`${o.token} ${key}: ${o[key]} vs ${n[key]}`)
    }

    const strandedTokens = await strandedAfter(hre, o.token, oldTreasury.address, migrated)
    const strandedShares = await strandedAfter(hre, o.vault, oldTreasury.address, migrated)
    if (strandedTokens.gt(0)) problems.push(`the old Treasury still held ${strandedTokens} of ${o.token}`)
    if (strandedShares.gt(0)) problems.push(`the old Treasury still held ${strandedShares} shares of ${o.vault}`)
  }
  for (const {vault: vaultAddress} of vaultsOf(oldState)) {
    const vault = await hre.ethers.getContractAt(YIELD_VAULT_ABI, vaultAddress)
    const gate = await readVaultGate(hre, vault, newTreasury.address, blockTag)
    if (gate.gated && !gate.whitelisted) problems.push(`yield vault ${vaultAddress} did not whitelist the new Treasury`)
    // The removal follows migrate in the batch, and on a fork the impersonated Safe runs each call in its own block
    const {whitelisted} = await readVaultGate(hre, vault, oldTreasury.address)
    if (gate.gated && whitelisted) problems.push(`yield vault ${vaultAddress} still whitelists the old Treasury`)
  }
  if (!oldState.priceTolerance.eq(newState.priceTolerance)) {
    problems.push(`priceTolerance: ${oldState.priceTolerance} vs ${newState.priceTolerance}`)
  }
  if (!sameAddress(oldState.swapper, newState.swapper))
    problems.push(`swapper: ${oldState.swapper} vs ${newState.swapper}`)
  if (!sameAddress(oldState.admin, newState.admin)) problems.push(`admin: ${oldState.admin} vs ${newState.admin}`)
  if (oldState.adminDelay !== newState.adminDelay) {
    problems.push(`admin delay: ${oldState.adminDelay} vs ${newState.adminDelay}`)
  }
  if (oldState.pendingAdminChange) problems.push(`the old Treasury had a pending ${oldState.pendingAdminChange}`)
  for (const role of new Set([...oldState.roles.keys(), ...newState.roles.keys()])) {
    const a = (oldState.roles.get(role) ?? []).join(',')
    const b = (newState.roles.get(role) ?? []).join(',')
    if (a !== b) problems.push(`${roleName(role)} holders: [${a}] vs [${b}]`)
  }

  if (problems.length > 0) {
    throw Error(
      `The new Treasury ${newTreasury.address} was not an exact copy at block ${blockTag}:\n` +
        problems.map((p) => `  - ${p}`).join('\n')
    )
  }
  log(chalk.green(`  ${newTreasury.address} mirrored ${oldTreasury.address} and took all its collateral`))
}

/**
 * What `holder` held of `token` right after the `migrated` log: its balance at the end of that block, less what was
 * sent to it later in the block. Anyone can send dust right behind the Safe's transaction.
 */
const strandedAfter = async (
  hre: HardhatRuntimeEnvironment,
  token: string,
  holder: string,
  migrated: ethers.providers.Log
): Promise<BigNumber> => {
  const erc20 = await hre.ethers.getContractAt(ERC20_ABI, token)
  const balance: BigNumber = await erc20.balanceOf(holder, {blockTag: migrated.blockNumber})
  const logs = await hre.ethers.provider.getLogs({
    address: token,
    topics: [erc20.interface.getEventTopic('Transfer'), null, ethers.utils.hexZeroPad(holder, 32)],
    fromBlock: migrated.blockNumber,
    toBlock: migrated.blockNumber,
  })
  return logs
    .filter((l) => l.logIndex > migrated.logIndex)
    .reduce((left, l) => left.sub(erc20.interface.parseLog(l).args.value), balance)
}

const listCalls = (calls: SafeCall[]) =>
  calls.map(({description}, i) => `    ${String(i + 1).padStart(2)}. ${description}`)

/**
 * Whether the Treasury artifact has moved on to a new Treasury the PeggedToken does not point at yet. Scripts that
 * would set up or point the token at the artifact leave it alone then: the migration batch owns that pair.
 */
export const isTreasuryMigrationPending = async (
  hre: HardhatRuntimeEnvironment,
  {peggedTokenAlias, treasuryAlias}: MigrateTreasuryProps
): Promise<boolean> => {
  const {get, read} = hre.deployments
  const {address: treasury} = await get(treasuryAlias)
  const current: string = await read(peggedTokenAlias, 'treasury')
  return !sameAddress(current, ZERO_ADDRESS) && !sameAddress(current, treasury)
}

/**
 * Whether the PeggedToken's live Treasury is behind a proxy, or not set yet. The Gateway prices through the Treasury's
 * peg band, which a Treasury from before the migration does not have, so the Gateway upgrades only after it.
 */
export const isTreasuryMigrated = async (hre: HardhatRuntimeEnvironment, peggedTokenAlias: string) => {
  const treasury: string = await hre.deployments.read(peggedTokenAlias, 'treasury')
  if (sameAddress(treasury, ZERO_ADDRESS)) return true
  return !sameAddress(await getImplementation(hre.ethers.provider, treasury), ZERO_ADDRESS)
}

/**
 * The recorded batch must still be what live state calls for: anything changed on either Treasury since the build,
 * such as a revoked role or a paused token, would be undone by executing it.
 */
const checkPendingBatch = async (
  hre: HardhatRuntimeEnvironment,
  {
    treasuryAlias,
    safe,
    peggedToken,
    peggedTokenAlias,
    oldTreasury,
    oldState,
    newDeployment,
    newFromBlock,
    record,
  }: {
    treasuryAlias: string
    safe: string
    peggedToken: Contract
    peggedTokenAlias: string
    oldTreasury: Contract
    oldState: TreasuryState
    newDeployment: {address: string}
    newFromBlock: number
    record?: MigrationRecord
  }
) => {
  const rebuild = `set ${MIGRATE_TREASURY_ENV}=true to rebuild the batch, and replace the Safe proposal with it`
  assertNoAdminChangePending(oldState)
  if (!record || !sameAddress(record.newTreasury, newDeployment.address)) {
    throw Error(
      `${treasuryAlias}: no batch is recorded for the pending migration to ${newDeployment.address}: ${rebuild}`
    )
  }
  const newTreasury = await hre.ethers.getContractAt(TREASURY_ABI, newDeployment.address)
  const newState = await readState(hre, newTreasury, newTreasury, newFromBlock)
  const calls = await buildMirrorBatch(hre, {
    safe,
    peggedToken,
    peggedTokenAlias,
    oldTreasury,
    newTreasury,
    oldState,
    newState,
  })
  const key = ({to, data}: SafeCall) => `${to.toLowerCase()}:${data}`
  if (calls.map(key).join() !== record.calls.map(key).join()) {
    throw Error(
      `${treasuryAlias}: live state changed since the migration batch was built. Do NOT execute it; ${rebuild}.\n` +
        `  Recorded:\n${listCalls(record.calls).join('\n')}\n  Live state now needs:\n${listCalls(calls).join('\n')}`
    )
  }
  log(
    chalk.yellow(
      `${treasuryAlias}: migration to ${newDeployment.address} is pending, its ${calls.length}-call batch still ` +
        'matches live state. Execute it, then re-run to verify.'
    )
  )
}

/**
 * Move a PeggedToken onto a freshly deployed Treasury that mirrors its live one.
 *
 * With MIGRATE_TREASURY=true and a live Treasury that is not behind a proxy, the deployer deploys a Treasury proxy
 * whose ProxyAdmin the live admin owns, and the Safe batch gets every call that copies the live config and roles onto
 * it, then `updateTreasury`, `migrate` and the old Treasury's removal from the yield vaults. The batch must execute as
 * one Safe transaction. A Treasury behind a proxy changes code through an upgrade instead.
 *
 * While the batch is pending, a run without the flag rebuilds it from live state and fails if it no longer matches
 * the recorded one, so a change made after the build (a revoked role, a pause) cannot be undone by executing it. The
 * first run after it executed verifies the migration, then retires the `_Previous` record.
 */
export const migrateTreasuryIfRequested = async (
  hre: HardhatRuntimeEnvironment,
  {peggedTokenAlias, treasuryAlias}: MigrateTreasuryProps
): Promise<void> => {
  const {deployments, ethers} = hre
  const {get, getOrNull, save} = deployments
  const requested = process.env[MIGRATE_TREASURY_ENV] === 'true'
  const safe = Address.GNOSIS_SAFE_ADDRESS

  const peggedTokenDeployment = await get(peggedTokenAlias)
  const peggedToken = await ethers.getContractAt(PEGGED_TOKEN_ABI, peggedTokenDeployment.address)
  const live: string = await peggedToken.treasury()
  if (sameAddress(live, ZERO_ADDRESS)) return

  const artifact = await get(treasuryAlias)
  const previous = await getOrNull(previousAlias(treasuryAlias))
  const fromBlock = (d: {receipt?: {blockNumber: number}}) => d.receipt?.blockNumber ?? 0
  // Where the new Treasury's events start. Its alias record carries the current implementation's receipt, which every
  // upgrade moves forward, so the proxy's own record counts
  const newFromBlock = async () => fromBlock((await getOrNull(`${treasuryAlias}_Proxy`)) ?? (await get(treasuryAlias)))
  const oldTreasury = await ethers.getContractAt(TREASURY_ABI, live)

  let oldState: TreasuryState
  if (sameAddress(artifact.address, live)) {
    if (previous && !sameAddress(previous.address, live)) {
      // The batch executed: verify once, then drop the record so later runs, and a later migration, start clean
      log(chalk.blue(`${treasuryAlias}: verifying the migration from ${previous.address}`))
      await verifyMigrated(hre, {
        peggedToken,
        oldTreasury: await ethers.getContractAt(TREASURY_ABI, previous.address),
        newTreasury: oldTreasury,
        oldFromBlock: fromBlock(previous),
        newFromBlock: await newFromBlock(),
      })
      await deployments.delete(previousAlias(treasuryAlias))
      log(chalk.green(`  retired ${previousAlias(treasuryAlias)}, git history keeps its record`))
      return
    }
    if (!requested) return
    if (!sameAddress(await getImplementation(ethers.provider, live), ZERO_ADDRESS)) {
      log(chalk.blue(`${treasuryAlias}: the live Treasury is behind a proxy, it changes code through an upgrade`))
      return
    }

    oldState = await readState(hre, oldTreasury, await bandsOf(hre, peggedToken), fromBlock(artifact))
    await assertSafeCanSign(hre, {safe, peggedToken, oldTreasury, oldState})
    assertNothingQueuedFor([live])

    // Kept before deploying: deploying under the alias overwrites the live Treasury's record
    await save(previousAlias(treasuryAlias), artifact)
    await deployUpgradable({
      hre,
      contractConfig: {alias: treasuryAlias, contract: 'Treasury'},
      initializeArgs: [peggedTokenDeployment.address, oldState.admin],
      owner: oldState.admin,
    })
    if (sameAddress((await get(treasuryAlias)).address, live)) {
      throw Error(
        `${treasuryAlias}_Proxy exists but ${treasuryAlias} still records the live Treasury: an earlier run stopped ` +
          `after deploying the proxy. Delete ${treasuryAlias}_Proxy.json and ${treasuryAlias}_ProxyAdmin.json and ` +
          're-run; the orphaned proxy holds nothing.'
      )
    }
  } else if (!previous || !sameAddress(previous.address, live)) {
    throw Error(
      `${treasuryAlias} artifact ${artifact.address} is neither the live Treasury ${live} nor a migration from it`
    )
  } else {
    oldState = await readState(hre, oldTreasury, await bandsOf(hre, peggedToken), fromBlock(previous))
    if (!requested) {
      await checkPendingBatch(hre, {
        treasuryAlias,
        safe,
        peggedToken,
        peggedTokenAlias,
        oldTreasury,
        oldState,
        newDeployment: artifact,
        newFromBlock: await newFromBlock(),
        record: previous.linkedData,
      })
      return
    }
    await assertSafeCanSign(hre, {safe, peggedToken, oldTreasury, oldState})
    assertNothingQueuedFor([live, artifact.address])
  }

  const newDeployment = await get(treasuryAlias)
  const newTreasury = await ethers.getContractAt(TREASURY_ABI, newDeployment.address)
  log(chalk.yellow(`${treasuryAlias}: migrating ${live} -> ${newTreasury.address}`))

  const newState = await readState(hre, newTreasury, newTreasury, await newFromBlock())
  if (!sameAddress(oldState.peggedToken, newState.peggedToken)) throw Error('The two Treasuries back different tokens')
  if (oldState.adminDelay !== newState.adminDelay) {
    throw Error(
      `The new Treasury's admin delay is ${newState.adminDelay}s, the live one's ${oldState.adminDelay}s. A delay ` +
        'change is itself delayed, so the batch cannot copy it.'
    )
  }
  const proxyAdmin = await ethers.getContractAt(
    ['function owner() view returns (address)'],
    await getProxyAdmin(ethers.provider, newTreasury.address)
  )
  const proxyAdminOwner: string = await proxyAdmin.owner()
  if (!sameAddress(proxyAdminOwner, oldState.admin)) {
    throw Error(`The new Treasury's ProxyAdmin is owned by ${proxyAdminOwner}, not the live admin ${oldState.admin}`)
  }

  const calls = await buildMirrorBatch(hre, {
    safe,
    peggedToken,
    peggedTokenAlias,
    oldTreasury,
    newTreasury,
    oldState,
    newState,
  })
  const record: MigrationRecord = {newTreasury: newTreasury.address, calls}
  await save(previousAlias(treasuryAlias), {...(await get(previousAlias(treasuryAlias))), linkedData: record})

  log(chalk.yellow(`  Safe batch for ${treasuryAlias}, ${calls.length} calls, to execute as ONE transaction:`))
  listCalls(calls).forEach((line) => log(chalk.yellow(line)))
  for (const {to, data} of calls) {
    await saveForMultiSigBatchExecution({from: safe, to, data})
  }
}
