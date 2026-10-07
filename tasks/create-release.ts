import {task} from 'hardhat/config'
import fs from 'fs'
import {getImplementation, getProxyAdmin} from '../deploy/helpers/eip1967'
import {TREASURY_ABI} from './helpers/abis'
import {INSTANCES} from './helpers/instances'

/**
 * Generate a release manifest from the deploy artifacts and on-chain state (ported from Vesper2).
 *
 * Output: releases/<instance>/<network>-<version>.json, the schema consumed by the e2e suite
 * (test/e2e/deployed-contracts.test.ts) and scripts/run-e2e-tests.sh:
 *
 *   { version, notes?, network, chainId, instance,
 *     contracts: {
 *       PeggedToken:      {address, name, symbol},
 *       Treasury:         {address},
 *       Gateway:          {address, implementation, proxyAdmin},
 *       StakingVault:     {address, implementation, proxyAdmin},
 *       YieldDistributor: {address, implementation, proxyAdmin},
 *       YieldManager:     {address},   // optional: post-launch periphery, included when deployed
 *     },
 *     oracles: { <deployment alias>: {address} },   // optional: price feeds deployed from this repo
 *     whitelistedTokens: { <token>: {symbol, token, vault, oracle, stalePeriod} },
 *     governance: { owner } }
 *
 * `contracts` keeps Vesper2's core roles only. Price feed adapters this repo deployed for the instance's collateral
 * are listed under `oracles` by deployment name (any artifact whose address is a collateral's `oracle`); external
 * oracles appear only as a collateral's `oracle`.
 *
 * Unlike Vesper2, proxy fields, token name/symbol and the owner are read on-chain: an upgrade queued for the Safe
 * updates the artifacts before it executes, and the deploy-time owner in the constructor args goes stale after the
 * governance handover.
 *
 * Versioning convention: manifests are IMMUTABLE once cut; the task refuses to overwrite an existing version.
 * Bump on every change to the deployed composition:
 *   major = core redeploy / treasury migration; minor = additive (new contract, new collateral);
 *   patch = in-place implementation upgrade or config-only change.
 * The release-to-release delta is mechanical:
 *   git diff --no-index releases/<inst>/<net>-<old>.json releases/<inst>/<net>-<new>.json
 *
 * Usage:
 *   npx hardhat create-release --release 1.2.0 --network ethereum            # all deployed instances
 *   npx hardhat create-release --release 1.2.0 --instance vetbtc --network ethereum
 *   npx hardhat create-release --release 1.2.0 --notes "upgrade Gateway" --network ethereum
 */

// Roles that may be absent: post-launch periphery is included only once deployed
const OPTIONAL_ROLES = ['YieldManager']

const readJson = (file: string) => JSON.parse(fs.readFileSync(file).toString())

/* eslint-disable @typescript-eslint/no-explicit-any */
task(
  'create-release',
  'Generate a release manifest (releases/<instance>/<network>-<version>.json) from deploy artifacts'
)
  .addParam('release', 'Release semantic version, e.g. 1.2.0')
  .addOptionalParam('instance', 'Limit to one instance dir (e.g. vusd). Default: every deployed instance.')
  .addOptionalParam('notes', 'One-line change note stored in the manifest (what this release adds/changes)')
  .setAction(async ({release, instance, notes}, hre) => {
    const {ethers} = hre
    const network = hre.network.name
    const dir = `./deployments/${network}`
    if (!fs.existsSync(dir)) {
      throw new Error(`No deployments found for network '${network}' (${dir}).`)
    }

    const exists = (alias: string) => fs.existsSync(`${dir}/${alias}.json`)
    const get = (alias: string) => readJson(`${dir}/${alias}.json`)

    if (instance && !INSTANCES[instance]) {
      throw new Error(`Unknown instance '${instance}'. Known: ${Object.keys(INSTANCES).join(', ')}`)
    }
    const targets = instance ? [instance] : Object.keys(INSTANCES)

    // address -> deployment alias, to recognise collateral oracles deployed from this repo. Proxy companions share
    // or shadow their alias's address, so skip them.
    const deployedAliases: Record<string, string> = {}
    for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.json'))) {
      if (/_(Proxy|ProxyAdmin|Implementation)\.json$/.test(file)) continue
      deployedAliases[get(file.replace('.json', '')).address.toLowerCase()] = file.replace('.json', '')
    }
    const pending: {file: string; data: any}[] = []

    for (const instDir of targets) {
      const roles = INSTANCES[instDir]

      // Deployed? The pegged-token deployment is the instance-unique marker.
      if (!exists(roles.PeggedToken)) {
        if (instance) {
          throw new Error(`Instance '${instDir}' is not deployed on '${network}' (${roles.PeggedToken}.json missing).`)
        }
        continue // auto mode: silently skip instances that aren't deployed
      }

      // address only, plus implementation/proxyAdmin iff a ProxyAdmin deploy exists (= upgradeable)
      const contract = async (alias: string) => {
        const {address} = get(alias)
        if (!exists(`${alias}_ProxyAdmin`)) return {address}
        return {
          address,
          implementation: await getImplementation(ethers.provider, address),
          proxyAdmin: await getProxyAdmin(ethers.provider, address),
        }
      }

      const contracts: any = {}
      for (const [role, alias] of Object.entries(roles)) {
        if (!exists(alias)) {
          if (OPTIONAL_ROLES.includes(role)) continue
          throw new Error(`${instDir}: ${alias}.json missing from ${dir}`)
        }
        contracts[role] = await contract(alias)
      }

      const token = await ethers.getContractAt(
        ['function name() view returns (string)', 'function symbol() view returns (string)'],
        contracts.PeggedToken.address
      )
      contracts.PeggedToken = {...contracts.PeggedToken, name: await token.name(), symbol: await token.symbol()}

      // Not best-effort as in Vesper2: an immutable manifest must never record an RPC failure as "no collateral"
      const whitelistedTokens: Record<string, any> = {}
      const oracles: Record<string, {address: string}> = {}
      const treasury = await ethers.getContractAt(TREASURY_ABI, contracts.Treasury.address)
      for (const collateral of await treasury.whitelistedTokens()) {
        const cfg = await treasury.tokenConfig(collateral)
        const erc20 = await ethers.getContractAt(['function symbol() view returns (string)'], collateral)
        whitelistedTokens[collateral] = {
          symbol: await erc20.symbol(),
          token: collateral,
          vault: cfg.vault,
          oracle: cfg.oracle,
          stalePeriod: cfg.stalePeriod.toNumber(),
        }
        const oracleAlias = deployedAliases[cfg.oracle.toLowerCase()]
        if (oracleAlias) oracles[oracleAlias] = {address: cfg.oracle}
      }

      const gateway = await ethers.getContractAt(['function owner() view returns (address)'], contracts.Gateway.address)

      const releaseData = {
        version: release,
        ...(notes ? {notes} : {}),
        network,
        chainId: hre.network.config.chainId,
        instance: instDir,
        contracts,
        ...(Object.keys(oracles).length ? {oracles} : {}),
        whitelistedTokens,
        // The Gateway's owner is the Treasury's default admin (GOVERNOR); the e2e impersonates it for role grants
        governance: {owner: await gateway.owner()},
      }

      pending.push({file: `releases/${instDir}/${network}-${release}.json`, data: releaseData})
    }

    if (!pending.length) {
      throw new Error(`No deployed instances found for network '${network}'. Nothing written.`)
    }

    // Manifests are immutable: refuse before writing anything, so a multi-instance run never half-writes
    const taken = pending.filter(({file}) => fs.existsSync(file)).map(({file}) => file)
    if (taken.length) {
      throw new Error(`Release already exists, bump the version: ${taken.join(', ')}. Nothing written.`)
    }

    for (const {file, data} of pending) {
      fs.mkdirSync(file.slice(0, file.lastIndexOf('/')), {recursive: true})
      fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`)
      console.log(`Wrote ${file}`)
    }
  })

module.exports = {}
