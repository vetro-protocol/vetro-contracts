import fs from 'fs'
import path from 'path'
import {HardhatRuntimeEnvironment} from 'hardhat/types'
import {
  TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD,
  TASK_COMPILE_SOLIDITY_RUN_SOLC,
  TASK_COMPILE_SOLIDITY_RUN_SOLCJS,
} from 'hardhat/builtin-tasks/task-names'
import {
  SolcInput,
  SolcOutput,
  ValidationRunData,
  assertUpgradeSafe,
  getContractVersion,
  getStorageLayout,
  getStorageUpgradeReport,
  makeNamespacedInput,
  solcInputOutputDecoder,
  trySanitizeNatSpec,
  validate,
  withValidationDefaults,
} from '@openzeppelin/upgrades-core'
import {getImplementation} from './eip1967'

// hardhat-deploy strips outputSelection from the solcInputs it saves, so every compile here sets its own
const OUTPUT_SELECTION = {
  '*': {
    '*': [
      'storageLayout',
      'evm.bytecode.object',
      'evm.bytecode.linkReferences',
      'evm.deployedBytecode.object',
      'evm.deployedBytecode.immutableReferences',
      'evm.methodIdentifiers',
    ],
    '': ['ast'],
  },
}

type ImmutableReferences = Record<string, {start: number; length: number}[]>

// upgrades-core's SolcOutput type omits the deployed bytecode that OUTPUT_SELECTION asks solc for
type SolcEvmWithDeployedBytecode = SolcOutput['contracts'][string][string]['evm'] & {
  deployedBytecode?: {object: string; immutableReferences?: ImmutableReferences}
}

interface Compilation {
  input: SolcInput
  output: SolcOutput
  validation: ValidationRunData
}

export interface UpgradeSafetyResult {
  ok: boolean
  liveImplementation: string
  // Fully qualified name of the live implementation's source, e.g. `src/Gateway.sol:Gateway @ <solcInputHash>`
  reference: string
  report: string
}

// Compiles are slow and the same inputs are checked once per proxy, so cache them per process
const compilations = new Map<string, Promise<Compilation>>()

const runSolc = async (hre: HardhatRuntimeEnvironment, input: SolcInput, solcVersion: string): Promise<SolcOutput> => {
  const build = await hre.run(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, {quiet: true, solcVersion})
  const output = build.isSolcJs
    ? await hre.run(TASK_COMPILE_SOLIDITY_RUN_SOLCJS, {input, solcJsPath: build.compilerPath})
    : await hre.run(TASK_COMPILE_SOLIDITY_RUN_SOLC, {input, solcPath: build.compilerPath, solcVersion})
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const errors = (output.errors ?? []).filter((e: any) => e.severity === 'error')
  if (errors.length) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    throw new Error(`solc ${solcVersion} failed:\n${errors.map((e: any) => e.formattedMessage).join('\n')}`)
  }
  return output
}

/**
 * Compiles `input` and runs the OZ validations on it. Namespaced (ERC-7201) structs are not part of solc's storage
 * layout, so like hardhat-upgrades we also compile a namespaced variant of the input to extract their layout.
 * `inputId` identifies the input for the cache (a solcInput hash or build info id), so it is never re-hashed.
 */
const compile = (
  hre: HardhatRuntimeEnvironment,
  rawInput: SolcInput,
  solcVersion: string,
  inputId: string
): Promise<Compilation> => {
  const input = {...rawInput, settings: {...rawInput.settings, outputSelection: OUTPUT_SELECTION}} as SolcInput
  const key = `${solcVersion}:${inputId}`
  if (!compilations.has(key)) {
    compilations.set(
      key,
      (async () => {
        const output = await runSolc(hre, input, solcVersion)
        const namespacedInput = await trySanitizeNatSpec(makeNamespacedInput(input, output, solcVersion), solcVersion)
        const namespacedOutput = await runSolc(hre, namespacedInput, solcVersion)
        const decodeSrc = solcInputOutputDecoder(input, output)
        const validation = validate(output, decodeSrc, solcVersion, input, namespacedOutput)
        return {input, output, validation}
      })()
    )
  }
  return compilations.get(key)!
}

// Live code has immutables filled in where the compiled code has zeros, so mask them out before comparing
const maskImmutables = (code: string, immutableReferences: ImmutableReferences = {}) => {
  let masked = code
  for (const refs of Object.values(immutableReferences)) {
    for (const {start, length} of refs) {
      masked = masked.slice(0, start * 2) + '0'.repeat(length * 2) + masked.slice((start + length) * 2)
    }
  }
  return masked
}

/**
 * Solc versions to try for a saved input, which does not record its compiler. An artifact that used the input knows
 * it, but upgrades overwrite artifacts, so the live implementation's input may have none left: then fall back to the
 * versions this project compiles with.
 */
const compilerVersionsByDir = new Map<string, Map<string, string>>()

// solcInputHash -> compiler version, from the artifacts that used each input; read once per directory
const compilerVersionsByInput = (deploymentsDir: string) => {
  if (!compilerVersionsByDir.has(deploymentsDir)) {
    const versions = new Map<string, string>()
    for (const file of fs.readdirSync(deploymentsDir).filter((f) => f.endsWith('.json'))) {
      const artifact = JSON.parse(fs.readFileSync(path.join(deploymentsDir, file), 'utf8'))
      if (artifact.solcInputHash && artifact.metadata && !versions.has(artifact.solcInputHash)) {
        versions.set(artifact.solcInputHash, JSON.parse(artifact.metadata).compiler.version.split('+')[0])
      }
    }
    compilerVersionsByDir.set(deploymentsDir, versions)
  }
  return compilerVersionsByDir.get(deploymentsDir)!
}

const solcVersionsFor = (hre: HardhatRuntimeEnvironment, deploymentsDir: string, solcInputHash: string): string[] => {
  // The bytecode embeds the compiler version, so no other version could match
  const known = compilerVersionsByInput(deploymentsDir).get(solcInputHash)
  if (known) return [known]
  const {compilers, overrides} = hre.config.solidity
  return [...new Set([...compilers, ...Object.values(overrides)].map((c) => c.version))]
}

interface LiveImplementation {
  implementation: string
  compilation: Compilation
  fullyQualifiedName: string
  solcInputHash: string
}

// Proxies share implementations (VUSD and vetBTC run the same Gateway and StakingVault), so resolve each once
const liveImplementations = new Map<string, Promise<LiveImplementation>>()

/**
 * Finds the source of the implementation currently behind `proxy` by recompiling every solc input that
 * hardhat-deploy recorded for this network and matching the result against the live bytecode. Matching on bytecode
 * (rather than trusting artifact names) guarantees the storage layout we compare against is the one actually live.
 */
const findLiveImplementation = async (hre: HardhatRuntimeEnvironment, proxy: string) => {
  const implementation = await getImplementation(hre.ethers.provider, proxy)
  const key = `${hre.network.name}:${implementation}`
  if (!liveImplementations.has(key)) liveImplementations.set(key, resolveSource(hre, implementation))
  return liveImplementations.get(key)!
}

const resolveSource = async (hre: HardhatRuntimeEnvironment, implementation: string): Promise<LiveImplementation> => {
  const liveCode = (await hre.ethers.provider.getCode(implementation)).slice(2).toLowerCase()
  if (!liveCode.length) throw new Error(`No code at live implementation ${implementation}`)

  const deploymentsDir = path.join(hre.config.paths.root, 'deployments', hre.network.name)
  const solcInputsDir = path.join(deploymentsDir, 'solcInputs')
  if (!fs.existsSync(solcInputsDir)) throw new Error(`Missing ${solcInputsDir}; copy the network's deployments first`)

  const compileErrors: string[] = []
  for (const file of fs.readdirSync(solcInputsDir).filter((f) => f.endsWith('.json'))) {
    const solcInputHash = file.replace('.json', '')
    const input = JSON.parse(fs.readFileSync(path.join(solcInputsDir, file), 'utf8'))
    for (const solcVersion of solcVersionsFor(hre, deploymentsDir, solcInputHash)) {
      let compilation: Compilation
      try {
        compilation = await compile(hre, input, solcVersion, solcInputHash)
      } catch (error) {
        // Expected for a wrong compiler (pragma mismatch), but keep the error in case it was the right one
        compileErrors.push(`${solcInputHash} with solc ${solcVersion}: ${(error as Error).message}`)
        continue
      }
      for (const [sourceName, contracts] of Object.entries(compilation.output.contracts)) {
        for (const [contractName, contract] of Object.entries(contracts)) {
          const deployed = (contract.evm as SolcEvmWithDeployedBytecode).deployedBytecode
          if (!deployed?.object || deployed.object.length !== liveCode.length) continue
          if (maskImmutables(liveCode, deployed.immutableReferences) === deployed.object.toLowerCase()) {
            return {implementation, compilation, fullyQualifiedName: `${sourceName}:${contractName}`, solcInputHash}
          }
        }
      }
    }
  }
  throw new Error(
    `No solc input in ${solcInputsDir} compiles to the live implementation ${implementation}. ` +
      `Refusing to treat the upgrade as safe without the live source.` +
      (compileErrors.length ? `\nCompiles that failed:\n${compileErrors.join('\n')}` : '')
  )
}

/**
 * Compares the implementation currently behind `proxy` with `contract` from this repo's latest compile, using the
 * same checks as OZ's `validateUpgrade`: the new implementation must be upgrade safe, and its storage layout
 * (including ERC-7201 namespaces) must be compatible with the live one.
 */
export const checkUpgradeSafety = async (
  hre: HardhatRuntimeEnvironment,
  proxy: string,
  contract: string
): Promise<UpgradeSafetyResult> => {
  const opts = withValidationDefaults({kind: 'transparent'})

  const live = await findLiveImplementation(hre, proxy)
  const {sourceName} = await hre.artifacts.readArtifact(contract)
  const newFullyQualifiedName = `${sourceName}:${contract}`
  const buildInfo = await hre.artifacts.getBuildInfo(newFullyQualifiedName)
  if (!buildInfo) throw new Error(`No build info for ${newFullyQualifiedName}; compile first`)
  const updated = await compile(hre, buildInfo.input as SolcInput, buildInfo.solcVersion, buildInfo.id)

  const reference = `${live.fullyQualifiedName} @ ${live.solcInputHash}`
  const lines: string[] = []

  let ok = true
  try {
    const version = getContractVersion(updated.validation, newFullyQualifiedName)
    assertUpgradeSafe([updated.validation], version, opts)
  } catch (error) {
    ok = false
    lines.push((error as Error).message)
  }

  const originalLayout = getStorageLayout(
    [live.compilation.validation],
    getContractVersion(live.compilation.validation, live.fullyQualifiedName)
  )
  const updatedLayout = getStorageLayout(
    [updated.validation],
    getContractVersion(updated.validation, newFullyQualifiedName)
  )
  const storageReport = getStorageUpgradeReport(originalLayout, updatedLayout, opts)
  if (!storageReport.ok) {
    ok = false
    lines.push(storageReport.explain())
  }

  return {ok, liveImplementation: live.implementation, reference, report: lines.join('\n\n')}
}

export const assertUpgradeSafety = async (hre: HardhatRuntimeEnvironment, proxy: string, contract: string) => {
  const result = await checkUpgradeSafety(hre, proxy, contract)
  if (!result.ok) {
    throw new Error(`Upgrade of ${proxy} from ${result.reference} to ${contract} is unsafe:\n${result.report}`)
  }
  return result
}
