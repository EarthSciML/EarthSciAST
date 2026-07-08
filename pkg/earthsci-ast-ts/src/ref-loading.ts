/**
 * Subsystem Reference Loading for the ESM format
 *
 * Resolves subsystem references (`ref` fields) by loading referenced ESM files
 * from local filesystem paths or remote URLs. Supports recursive resolution
 * and circular reference detection.
 *
 * Works in both Node.js (using dynamic fs import) and browser (using fetch)
 * environments.
 */

import type { DataLoader, EsmFile, Model, ReactionSystem, SubsystemRef } from './types.js'
import {
  ExpressionTemplateError,
  deepEqual,
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower-expression-templates.js'
import {
  applyScopeInjections,
  isTemplateLibraryDoc,
  rejectTemplateImportsPreV08,
  resolveTemplateMachinery,
} from './template-imports.js'
import { load, validateSchema } from './parse.js'
import { save } from './serialize.js'

/**
 * Error thrown when a circular reference is detected during subsystem resolution.
 */
export class CircularReferenceError extends Error {
  /** The chain of references that form the cycle */
  public readonly chain: string[]

  constructor(chain: string[]) {
    super(`Circular reference detected: ${chain.join(' -> ')}`)
    this.name = 'CircularReferenceError'
    this.chain = chain
  }
}

/**
 * Error thrown when a referenced file cannot be loaded or parsed.
 */
export class RefLoadError extends Error {
  /** The reference path or URL that failed to load */
  public readonly ref: string

  constructor(ref: string, cause?: Error) {
    const message = cause
      ? `Failed to load ref "${ref}": ${cause.message}`
      : `Failed to load ref "${ref}"`
    super(message)
    this.name = 'RefLoadError'
    this.ref = ref
  }
}

/**
 * Resolve all subsystem references in an ESM file by loading and inlining
 * the referenced content.
 *
 * For each subsystem with a `ref` field:
 * - If the ref starts with `http://` or `https://`, fetch from the URL
 * - Otherwise, resolve as a local file path relative to basePath and read with fs
 *
 * The function mutates the input file in place, replacing ref-only subsystems
 * with the resolved content. Resolution is recursive: if a loaded subsystem
 * itself contains refs, those are resolved too.
 *
 * @param file - The ESM file to resolve (mutated in place)
 * @param basePath - Base directory for resolving relative file paths
 * @throws CircularReferenceError if a circular reference chain is detected
 * @throws RefLoadError if a referenced file cannot be loaded or parsed
 */
export async function resolveSubsystemRefs(file: EsmFile, basePath: string): Promise<void> {
  const resolving = new Set<string>()

  // The importing document's index-set registry (esm-spec §4.7): every
  // referenced subsystem file's top-level `index_sets` merge into it, threaded
  // down the model walk (mirrors §9.7.5). Created lazily so a document with no
  // index sets and no mounted axes stays without an `index_sets` block.
  const registry: Record<string, unknown> =
    (file.index_sets as Record<string, unknown> | undefined) ?? {}

  // Process all models
  if (file.models) {
    for (const [name, model] of Object.entries(file.models)) {
      await resolveModelRefs(model, basePath, resolving, [name], registry)
    }
  }

  // Attach the registry only if the merge actually contributed axes to a
  // previously index-set-less document (no empty `index_sets: {}` otherwise).
  if (!file.index_sets && Object.keys(registry).length > 0) {
    ;(file as { index_sets?: unknown }).index_sets = registry
  }

  // Process all reaction systems. Per esm-spec §4.7 the index-set merge is a
  // model-mount mechanism; reaction-system subsystem refs do not merge index
  // sets (mirrors the Julia reference, which threads the registry only into the
  // model walk).
  if (file.reaction_systems) {
    for (const [name, rs] of Object.entries(file.reaction_systems)) {
      await resolveReactionSystemRefs(rs, basePath, resolving, [name])
    }
  }
}

/**
 * Merge a referenced subsystem file's top-level `index_sets` into the importing
 * document's registry (esm-spec §4.7, mirroring the §9.7.5 template-import
 * merge). The referenced document's metaparameters are already closed and
 * folded, so the merge compares concrete declarations. Deep-equal redeclaration
 * is idempotent; a non-equal collision throws `subsystem_index_set_conflict`
 * (§9.6.6) — the mounted-mesh failure mode this makes loud: a mesh file whose
 * axis size disagrees with the importer's declaration must fail at load, not
 * silently resolve against the importer.
 */
function mergeSubsystemIndexSets(
  registry: Record<string, unknown>,
  loaded: EsmFile,
  ref: string,
): void {
  const loadedIsets = (loaded as { index_sets?: unknown }).index_sets
  if (typeof loadedIsets !== 'object' || loadedIsets === null || Array.isArray(loadedIsets)) {
    return
  }
  for (const [n, decl] of Object.entries(loadedIsets as Record<string, unknown>)) {
    if (Object.prototype.hasOwnProperty.call(registry, n)) {
      if (!deepEqual(registry[n], decl)) {
        throw new ExpressionTemplateError(
          'subsystem_index_set_conflict',
          `index set '${n}' from subsystem ref '${ref}' collides with a non-deep-equal declaration in the importing document. A referenced subsystem file's top-level index_sets merge into the importing document's registry; deep-equal redeclaration is idempotent, a size/kind disagreement is a load-time error (esm-spec §4.7).`,
        )
      }
    } else {
      registry[n] = decl
    }
  }
}

/**
 * Read the optional metaparameter `bindings` off a `{ ref, bindings }`
 * subsystem entry (esm-spec §9.7.6 binding site 3). Values MUST be
 * integers (`metaparameter_type_error` otherwise).
 */
function readEdgeBindings(sub: { bindings?: unknown }, subName: string): Record<string, number> {
  const out: Record<string, number> = {}
  const raw = sub.bindings
  if (raw === undefined || raw === null) return out
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `subsystems.${subName}: \`bindings\` must be an object of integers (esm-spec §9.7.6)`,
    )
  }
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v !== 'number' || !Number.isInteger(v)) {
      throw new ExpressionTemplateError(
        'metaparameter_type_error',
        `subsystems.${subName}: binding '${k}' is not an integer (esm-spec §9.7.6)`,
      )
    }
    out[k] = v
  }
  return out
}

/**
 * Read the optional `expression_template_imports` off a `{ ref, ... }`
 * subsystem edge (esm-spec §9.7.10 form A): raw §9.7.2 import entries injected
 * into the REFERENCED component's own template scope so a mounted
 * discretization-agnostic PDE leaf is lowered under the assembler-chosen
 * discretization. Returns `[]` when absent.
 */
function readEdgeInjectedImports(sub: { expression_template_imports?: unknown }): unknown[] {
  const raw = sub.expression_template_imports
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw)) {
    throw new ExpressionTemplateError(
      'template_import_not_library',
      'subsystem-ref `expression_template_imports` must be a list of §9.7.2 import entries (esm-spec §9.7.10)',
    )
  }
  return raw
}

/**
 * Post-parse handling shared by model / reaction-system ref resolution:
 *
 * 1. A §4.7 subsystem ref MUST NOT target a template-library file — the two
 *    reference mechanisms are disjoint (`subsystem_ref_is_template_library`,
 *    esm-spec §9.7.1).
 * 2. The referenced document's §9.7 machinery (template imports and
 *    metaparameters) is resolved in the referenced file's own directory,
 *    closed with this edge's `bindings` (esm-spec §9.7.6 binding site 3),
 *    and lowered to the §9.6.3 fixpoint before the single component is
 *    extracted and inlined.
 * 3. The edge's `injectedImports` (esm-spec §9.7.10 form A) are folded into
 *    the referenced component's own scope BEFORE resolution, so its
 *    rewrite-targets lower under the assembler-chosen discretization at the
 *    mount (the injection is consumed by the fixpoint and does not survive
 *    parse → emit).
 */
function resolveRefDocument(
  parsed: EsmFile,
  ref: string,
  refBasePath: string,
  bindings: Record<string, number>,
  injectedImports: readonly unknown[] = [],
): EsmFile {
  if (isTemplateLibraryDoc(parsed)) {
    throw new ExpressionTemplateError(
      'subsystem_ref_is_template_library',
      `Subsystem ref '${ref}' targets a template-library file; libraries are imported via expression_template_imports (esm-spec §9.7.1)`,
    )
  }
  rejectExpressionTemplatesPreV04(parsed)
  rejectTemplateImportsPreV08(parsed)
  // esm-spec §9.7.10 form A: fold the subsystem-ref edge's injected imports
  // into the referenced component's scope before resolution.
  const injectedRoot = applyScopeInjections(parsed, injectedImports)
  const machineryInput = (injectedRoot ?? parsed) as EsmFile
  // `resolveTemplateMachinery` returns null when the document carries no
  // §9.7 machinery (and rejects non-empty bindings against such a document
  // with `template_import_unknown_name`).
  const resolved = resolveTemplateMachinery(machineryInput, refBasePath, {
    metaparameters: bindings,
    validateSchema,
  })
  if (resolved === null) return machineryInput
  return lowerExpressionTemplates(resolved) as EsmFile
}

/**
 * Ref-edge fields a `{ ref, ... }` subsystem entry may carry.
 */
interface RefEdge {
  ref?: string
  bindings?: unknown
  expression_template_imports?: unknown
}

/**
 * Shared ref-edge skeleton for model and reaction-system resolution:
 * cycle-check the edge, load and parse the referenced document, resolve its
 * §9.7 machinery against this edge's bindings / injected imports, then hand
 * the parsed document (plus its own base directory, for recursive resolution)
 * to `inline` for component extraction.
 */
async function resolveRefEdge(
  sub: RefEdge,
  subName: string,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  inline: (parsed: EsmFile, refBasePath: string) => Promise<void>,
): Promise<void> {
  const ref = sub.ref!
  const chainKey = normalizeRef(ref, basePath)

  // Check for circular references
  if (resolving.has(chainKey)) {
    throw new CircularReferenceError([...refChain, subName, ref])
  }

  resolving.add(chainKey)
  try {
    const content = await loadRef(ref, basePath)
    const refBasePath = isRemoteRef(ref) ? getRemoteBase(ref) : getLocalBase(ref, basePath)
    const parsed = resolveRefDocument(
      JSON.parse(content) as EsmFile,
      ref,
      refBasePath,
      readEdgeBindings(sub, subName),
      readEdgeInjectedImports(sub),
    )
    await inline(parsed, refBasePath)
  } finally {
    resolving.delete(chainKey)
  }
}

/**
 * Recursively resolve refs in a Model's subsystems.
 */
async function resolveModelRefs(
  model: Model | SubsystemRef,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  registry: Record<string, unknown>,
): Promise<void> {
  // A bare `{ ref }` stub (SubsystemRef) has no subsystems to walk; the
  // top-level model union admits it under v0.8.0, but only a full Model
  // carries `subsystems`.
  if (!('subsystems' in model) || !model.subsystems) return

  for (const [subName, subsystem] of Object.entries(model.subsystems)) {
    const sub = subsystem as Model & RefEdge
    if (sub.ref) {
      const ref = sub.ref
      await resolveRefEdge(
        sub,
        subName,
        basePath,
        resolving,
        refChain,
        async (parsed, refBasePath) => {
          // esm-spec §4.7: the mounted file's document-scoped index sets (already
          // metaparameter-folded) join the importing document's registry, so the
          // importer's variables may be shaped over the mesh file's axes and a
          // disagreement fails loudly (`subsystem_index_set_conflict`).
          mergeSubsystemIndexSets(registry, parsed, ref)

          // Extract the first model from the referenced file
          if (parsed.models) {
            const firstEntry = Object.entries(parsed.models)[0]
            if (firstEntry) {
              const resolvedModel = firstEntry[1]
              // Replace the ref subsystem with the resolved model content, then
              // recursively resolve any refs in it, relative to the referenced
              // file's own directory
              model.subsystems![subName] = resolvedModel
              await resolveModelRefs(
                resolvedModel,
                refBasePath,
                resolving,
                [...refChain, subName],
                registry,
              )
            }
          } else if (parsed.data_loaders) {
            // Loader-only file (RFC pure-io-data-loaders §4.3): the referenced
            // file's sole component is `data_loaders`. The schema allows a
            // DataLoader inside Model.subsystems, so inline the first loader
            // keyed by the parent subName. A loader has no subsystems, so there
            // is nothing to recurse into.
            const firstEntry = Object.entries(parsed.data_loaders)[0]
            if (firstEntry) {
              model.subsystems![subName] = firstEntry[1] as DataLoader
            }
          }
        },
      )
    } else {
      // Even if there's no ref, recurse into subsystems
      await resolveModelRefs(sub, basePath, resolving, [...refChain, subName], registry)
    }
  }
}

/**
 * Recursively resolve refs in a ReactionSystem's subsystems.
 */
async function resolveReactionSystemRefs(
  rs: ReactionSystem,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
): Promise<void> {
  if (!rs.subsystems) return

  for (const [subName, subsystem] of Object.entries(rs.subsystems)) {
    const sub = subsystem as ReactionSystem & RefEdge
    if (sub.ref) {
      await resolveRefEdge(
        sub,
        subName,
        basePath,
        resolving,
        refChain,
        async (parsed, refBasePath) => {
          // Extract the first reaction system from the referenced file
          if (parsed.reaction_systems) {
            const firstEntry = Object.entries(parsed.reaction_systems)[0]
            if (firstEntry) {
              const resolvedRs = firstEntry[1]
              // Replace the ref subsystem with the resolved content, then
              // recursively resolve any refs in it, relative to the referenced
              // file's own directory
              rs.subsystems![subName] = resolvedRs
              await resolveReactionSystemRefs(resolvedRs, refBasePath, resolving, [
                ...refChain,
                subName,
              ])
            }
          }
        },
      )
    } else {
      // Even if there's no ref, recurse into subsystems
      await resolveReactionSystemRefs(sub, basePath, resolving, [...refChain, subName])
    }
  }
}

/**
 * esm-spec §9.7.10 form C: build a throwaway `EsmFile` in which component
 * `mname` has the run's `imports` (raw §9.7.2 entries) appended to its own
 * `expression_template_imports`, so the ordinary import resolver + §9.6.3
 * fixpoint lower its rewrite-targets under the run-chosen discretization. The
 * persisted `file` is never mutated. This is what lets one test/example suite
 * exercise a discretization-agnostic PDE leaf under several schemes with no
 * conflict between runs.
 *
 * The raw base is re-read from `sourcePath` when given (relative import `ref`s
 * resolve against its directory), else re-serialized from `file`; `baseDir`
 * anchors the injected `ref`s. Mirrors the Julia reference
 * `_ephemeral_injected_file` (`EarthSciAST.jl/src/pde_inline_tests.jl`).
 *
 * This binding does not numerically simulate PDEs; the ephemeral build is the
 * structural-lowering half of form C (the leaf's rewrite-target is lowered in
 * this copy only). No solver is implied.
 */
export async function ephemeralInjectedFile(
  file: EsmFile | null,
  sourcePath: string | null,
  mname: string,
  imports: readonly unknown[],
  baseDir: string,
): Promise<EsmFile> {
  let raw: Record<string, unknown>
  if (sourcePath !== null) {
    const fs = await import('node:fs/promises')
    raw = JSON.parse(await fs.readFile(sourcePath, 'utf-8')) as Record<string, unknown>
  } else if (file !== null) {
    raw = JSON.parse(save(file)) as Record<string, unknown>
  } else {
    throw new Error('ephemeralInjectedFile: one of `file` or `sourcePath` must be provided')
  }

  let injected = false
  for (const kind of ['models', 'reaction_systems'] as const) {
    const comps = raw[kind]
    if (typeof comps !== 'object' || comps === null || Array.isArray(comps)) continue
    const comp = (comps as Record<string, unknown>)[mname]
    if (typeof comp !== 'object' || comp === null || Array.isArray(comp)) continue
    const c = comp as Record<string, unknown>
    const existing = c.expression_template_imports
    const base: unknown[] = Array.isArray(existing) ? [...existing] : []
    for (const e of imports) base.push(e)
    c.expression_template_imports = base
    injected = true
    break
  }
  if (!injected) {
    throw new Error(`component '${mname}' not found for per-run injection (esm-spec §9.7.10)`)
  }

  const f = load(JSON.stringify(raw), { basePath: baseDir })
  await resolveSubsystemRefs(f, baseDir)
  return f
}

/**
 * Load content from a ref, dispatching to fetch() for URLs or fs for local paths.
 */
async function loadRef(ref: string, basePath: string): Promise<string> {
  if (isRemoteRef(ref)) {
    return loadRemoteRef(ref)
  }
  return loadLocalRef(ref, basePath)
}

/**
 * Load a remote reference via fetch().
 */
async function loadRemoteRef(url: string): Promise<string> {
  try {
    const response = await fetch(url)
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }
    return await response.text()
  } catch (error) {
    throw new RefLoadError(url, error instanceof Error ? error : new Error(String(error)))
  }
}

/**
 * Load a local file reference using dynamic fs import.
 * Uses dynamic import so the module can be loaded in browser environments
 * without failing at parse time.
 */
async function loadLocalRef(ref: string, basePath: string): Promise<string> {
  try {
    // Dynamic import of Node.js fs and path modules
    const fs = await import('node:fs/promises')
    const path = await import('node:path')

    const fullPath = path.resolve(basePath, ref)
    return await fs.readFile(fullPath, 'utf-8')
  } catch (error) {
    throw new RefLoadError(ref, error instanceof Error ? error : new Error(String(error)))
  }
}

/**
 * Check if a ref is a remote URL.
 */
function isRemoteRef(ref: string): boolean {
  return ref.startsWith('http://') || ref.startsWith('https://')
}

/**
 * Normalize a ref to a canonical key for cycle detection.
 * Local paths are resolved against basePath and collapsed (../, ./);
 * URLs are returned as-is.
 */
function normalizeRef(ref: string, basePath: string): string {
  if (isRemoteRef(ref)) {
    return ref
  }
  return canonicalizePath(joinPath(basePath, ref))
}

/**
 * Get the base directory of a remote URL for recursive resolution.
 */
function getRemoteBase(url: string): string {
  const lastSlash = url.lastIndexOf('/')
  return lastSlash >= 0 ? url.substring(0, lastSlash) : url
}

/**
 * Get the base directory of a local ref for recursive resolution.
 */
function getLocalBase(ref: string, basePath: string): string {
  const resolved = canonicalizePath(joinPath(basePath, ref))
  const lastSlash = resolved.lastIndexOf('/')
  return lastSlash > 0 ? resolved.substring(0, lastSlash) : '/'
}

/**
 * Join two POSIX-style paths.
 */
function joinPath(a: string, b: string): string {
  if (b.startsWith('/')) return b
  if (a.endsWith('/')) return `${a}${b}`
  return `${a}/${b}`
}

/**
 * Collapse "." and ".." segments in a POSIX-style path.
 */
function canonicalizePath(p: string): string {
  const isAbs = p.startsWith('/')
  const parts = p.split('/').filter((seg) => seg.length > 0 && seg !== '.')
  const stack: string[] = []
  for (const seg of parts) {
    if (seg === '..') {
      if (stack.length > 0 && stack[stack.length - 1] !== '..') {
        stack.pop()
      } else if (!isAbs) {
        stack.push('..')
      }
    } else {
      stack.push(seg)
    }
  }
  const joined = stack.join('/')
  return isAbs ? `/${joined}` : joined || '.'
}
