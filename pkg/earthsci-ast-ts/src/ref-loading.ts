/**
 * Subsystem reference loading for the ESM format (esm-spec §4.7).
 *
 * Resolves subsystem `ref` fields by loading the referenced ESM file (local
 * path or remote URL), resolving any §9.7 template machinery + metaparameters
 * the referenced document carries against this edge's `bindings` / injected
 * imports, lowering it to the §9.6.3 fixpoint, then inlining the single
 * extracted component in place. Resolution is recursive with path-scoped
 * circular-reference detection.
 *
 * File access: local refs are read asynchronously via `node:fs/promises`
 * (dynamic import so the module still parses in a browser), remote refs via
 * `fetch`. Historically this module was purely fetch/fs I/O and so worked in
 * both Node and the browser; that is no longer unconditional. Once a ref
 * carries §9.7 machinery, resolution drives the SYNCHRONOUS §9.7 resolver over
 * the already-loaded content (`resolveTemplateMachinery`), which needs a
 * synchronous file reader for any transitive template-library imports — a
 * plain-fetch browser host cannot satisfy that, so a machinery-bearing ref is
 * fully resolvable only under Node (or a host supplying its own readFile hook).
 */

import type { DataLoader, EsmFile, Model, ReactionSystem, SubsystemRef } from './types.js'
import {
  EsmMachineryError,
  deepEqual,
  expandDocument,
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower-expression-templates.js'
import {
  appendComponentImports,
  applyScopeInjections,
  evalMetaExpr,
  isTemplateLibraryDoc,
  rejectTemplateImportsPreV08,
  requireMetaExpr,
  resolveTemplateMachinery,
} from './template-imports.js'
import { isCouplingLibraryDoc } from './coupling-imports.js'
import {
  canonicalizePath,
  isRemoteRef,
  joinPath,
  normalizeRef,
  readFileSyncNode,
} from './path-utils.js'
import { ERROR_CODES } from './errors.js'
import { load, validateSchema, ROOT_PATH } from './parse.js'
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
 * Error thrown when a referenced file cannot be loaded, parsed, or uniquely
 * resolved to one system.
 *
 * Carries the CANONICAL cross-binding diagnostic code (see `ERROR_CODES`):
 *
 *  - `unresolved_subsystem_ref` (default) — the file does not exist, or could
 *    not be read or parsed.
 *  - `ambiguous_subsystem_ref` — the file WAS read, and holds more than one
 *    top-level system; §4.7 requires exactly one.
 *
 * The resolver is the only layer that reads the referenced file, so it is the
 * only layer that can tell those two apart — the synchronous `validate()` does
 * no I/O and reports every unresolved `{ref}` as `unresolved_subsystem_ref`.
 */
export class RefLoadError extends Error {
  /** The reference path or URL that failed to load */
  public readonly ref: string
  /** Canonical code: `unresolved_subsystem_ref` or `ambiguous_subsystem_ref`. */
  public readonly code: string
  /**
   * JSON Pointer of the SUBSYSTEM ENTRY that carries the bad ref (e.g.
   * `/models/ClimateModel/subsystems/Atm`) — not the document root. The corpus
   * pins these errors at the offending mount, and a caller handed `$` has to go
   * hunting for which of a dozen mounts failed.
   */
  public readonly path: string

  constructor(
    ref: string,
    cause?: Error,
    code: string = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
    message?: string,
    path: string = ROOT_PATH,
  ) {
    super(
      message ??
        (cause ? `Failed to load ref "${ref}": ${cause.message}` : `Failed to load ref "${ref}"`),
    )
    this.name = 'RefLoadError'
    this.ref = ref
    this.code = code
    this.path = path
  }
}

/**
 * Enforce the §4.7 invariant that a referenced subsystem file holds EXACTLY ONE
 * top-level system.
 *
 * A file with two models (or a model plus a loader) gives the mount no way to
 * say WHICH one it means. The loader used to silently take the first entry —
 * `Object.entries(parsed.models)[0]` — so a multi-system file resolved to
 * whichever component happened to serialize first: a silent, order-dependent
 * mis-mount. It is instead a hard `ambiguous_subsystem_ref`, the code the shared
 * corpus pins for `subsystem_ref_ambiguous.esm`.
 */
function assertSingleTopLevelSystem(parsed: EsmFile, ref: string, path: string): void {
  const systems = [
    ...Object.keys(parsed.models ?? {}),
    ...Object.keys(parsed.reaction_systems ?? {}),
    ...Object.keys(parsed.data_loaders ?? {}),
  ]
  if (systems.length > 1) {
    throw new RefLoadError(
      ref,
      undefined,
      ERROR_CODES.AMBIGUOUS_SUBSYSTEM_REF,
      `Subsystem reference '${ref}' resolves to a file containing multiple top-level systems; ` +
        `exactly one is required (found ${systems.join(', ')})`,
      path,
    )
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
export function resolveSubsystemRefsSync(
  file: EsmFile,
  basePath: string,
  read: SyncRefReader = loadRefSync,
): void {
  const resolving = new Set<string>()

  // The importing document's index-set registry (esm-spec §4.7): every
  // referenced subsystem file's top-level `index_sets` merge into it, threaded
  // down the model walk (mirrors §9.7.5). When the document already declares
  // `index_sets`, the registry ALIASES that same object so merges accumulate in
  // place; otherwise it starts as a detached `{}` that is only attached back
  // below if a merge actually contributed axes (so an index-set-less, mount-less
  // document keeps no empty `index_sets` block).
  const registry: Record<string, unknown> =
    (file.index_sets as Record<string, unknown> | undefined) ?? {}

  // Process all models
  if (file.models) {
    for (const [name, model] of Object.entries(file.models)) {
      resolveModelRefs(model, basePath, resolving, [name], registry, read, `/models/${name}`)
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
      resolveReactionSystemRefs(rs, basePath, resolving, [name], read, `/reaction_systems/${name}`)
    }
  }
}

/**
 * Async resolution — the historical entry point, and the only one that can reach
 * a REMOTE (`http(s)://`) ref, since `fetch` cannot be awaited synchronously.
 *
 * It is now a thin shell around the SYNC core: fetch every reachable ref into a
 * cache first, then run the one and only resolution walk against that cache.
 * There is deliberately no second walk implementing the same semantics — index-set
 * merging, the §4.7 single-component invariant, template-machinery lowering,
 * cycle detection and component inlining exist in exactly one place, so the sync
 * and async paths cannot drift apart.
 */
export async function resolveSubsystemRefs(file: EsmFile, basePath: string): Promise<void> {
  const cache = new Map<string, string>()
  await prefetchRefs(file, basePath, cache, new Set())
  resolveSubsystemRefsSync(file, basePath, (ref, refBase) => {
    const cached = cache.get(normalizeRef(ref, refBase))
    // Unreachable in practice (the prefetch walks the same `ref` fields), but
    // fail CLOSED rather than silently leaving a stub unresolved.
    if (cached === undefined) throw new RefLoadError(ref)
    return cached
  })
}

/**
 * Walk the `subsystems[*].ref` graph over RAW JSON and read every reachable
 * document into `cache`, so the sync core can then run without doing I/O itself.
 *
 * Raw JSON is the right surface to scan: a `ref` is a structural field, and
 * neither scope injection nor template lowering can introduce or remove one — so
 * the set of reachable refs is identical before and after the machinery runs.
 * `seen` both dedupes shared mounts and stops the prefetch from looping on a
 * CYCLE; the cycle itself is still detected and reported by the sync core, which
 * owns that rule.
 */
async function prefetchRefs(
  doc: unknown,
  basePath: string,
  cache: Map<string, string>,
  seen: Set<string>,
): Promise<void> {
  const walk = async (subsystems: unknown, currentBase: string): Promise<void> => {
    if (typeof subsystems !== 'object' || subsystems === null) return
    for (const sub of Object.values(subsystems as Record<string, unknown>)) {
      const ref = (sub as RefEdge | null)?.ref
      if (typeof ref !== 'string') {
        walkComponent(sub, currentBase)
        await walkNested(sub, currentBase)
        continue
      }
      const key = normalizeRef(ref, currentBase)
      if (seen.has(key)) continue
      seen.add(key)

      let content: string
      try {
        content = await loadRef(ref, currentBase)
      } catch {
        // An unreadable target (missing file / failed fetch) is the sync core's
        // error to report — resolveRefEdge re-throws it WITH the offending
        // mount's JSON Pointer attached (the async prefetch has no pointer
        // context). Leave it uncached and let the sync pass reject it. Mirrors
        // the malformed-JSON handling below.
        continue
      }
      cache.set(key, content)

      const refBase = isRemoteRef(ref) ? getRemoteBase(ref) : getLocalBase(ref, currentBase)
      let parsed: unknown
      try {
        parsed = JSON.parse(content)
      } catch {
        // A malformed target is the sync core's error to report, with its code.
        continue
      }
      await walkDocument(parsed, refBase)
    }
  }

  const walkNested = async (component: unknown, base: string): Promise<void> => {
    const nested = (component as { subsystems?: unknown } | null)?.subsystems
    if (nested) await walk(nested, base)
  }
  // Kept as a no-op hook so the recursion reads symmetrically; components carry
  // no refs outside `subsystems`.
  const walkComponent = (_component: unknown, _base: string): void => {}

  const walkDocument = async (parsed: unknown, base: string): Promise<void> => {
    const root = parsed as { models?: object; reaction_systems?: object } | null
    for (const component of Object.values(root?.models ?? {})) await walkNested(component, base)
    for (const component of Object.values(root?.reaction_systems ?? {}))
      await walkNested(component, base)
  }

  await walkDocument(doc, basePath)
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
        throw new EsmMachineryError(
          ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
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
 * subsystem entry (esm-spec §9.7.6 binding site 3), folding each value to a
 * concrete integer at the mount.
 *
 * A value may be a *metaparameter expression* — an integer literal, a name in
 * the MOUNTING document's metaparameter scope, or a `{op: +|-|*|/, args}` tree
 * over the same (e.g. `NTGT = NX*NY`). Unlike an import edge, a §4.7 subsystem
 * ref is resolved as a complete document folded to concrete integers at the
 * mount, so its binding values cannot be carried symbolically: each folds
 * IMMEDIATELY against the mounting document's already-closed metaparameter
 * environment. That closing has already happened — `load` → `resolveTemplate
 * Machinery` substitutes the mounting doc's closed metaparameters into these
 * ref bindings before this runs (a symbolic `NX*NY` arrives here as `18*20`),
 * so the fold below closes against an empty env; a free name that survived the
 * substitution is a genuine mount-edge typo and folds to
 * `template_import_unknown_name`, reported at the edge.
 */
function readEdgeBindings(sub: { bindings?: unknown }, subName: string): Record<string, number> {
  const out: Record<string, number> = {}
  const raw = sub.bindings
  if (raw === undefined || raw === null) return out
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new EsmMachineryError(
      ERROR_CODES.METAPARAMETER_TYPE_ERROR,
      `subsystems.${subName}: \`bindings\` must be an object (esm-spec §9.7.6)`,
    )
  }
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    const expr = requireMetaExpr(v, `subsystems.${subName}: binding '${k}'`)
    out[k] = evalMetaExpr(expr, {}, `mount subsystems.${subName}, binding '${k}'`)
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
    throw new EsmMachineryError(
      ERROR_CODES.TEMPLATE_IMPORT_NOT_LIBRARY,
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
    throw new EsmMachineryError(
      ERROR_CODES.SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
      `Subsystem ref '${ref}' targets a template-library file; libraries are imported via expression_template_imports (esm-spec §9.7.1)`,
    )
  }
  if (isCouplingLibraryDoc(parsed)) {
    throw new EsmMachineryError(
      ERROR_CODES.SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
      `Subsystem ref '${ref}' targets a coupling-library file; libraries are imported via a coupling_import coupling entry (esm-spec §10.9)`,
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
  // esm-spec §9.6.4 (Option B): lower to the reference-preserving form, then
  // apply the RFC §7.7 Expand-at-build strategy so the resolved subsystem is
  // the Option-A expanded image (bit-identical downstream behavior).
  return expandDocument(lowerExpressionTemplates(resolved)) as EsmFile
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
 * to `inline` for component extraction. `ref` is passed explicitly (the caller
 * has already established `sub.ref` is present), so no non-null assertion on
 * the optional `RefEdge.ref` field is needed here.
 */
function resolveRefEdge(
  sub: RefEdge,
  ref: string,
  subName: string,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  read: SyncRefReader,
  pointer: string,
  inline: (parsed: EsmFile, refBasePath: string) => void,
): void {
  const chainKey = normalizeRef(ref, basePath)

  // Check for circular references
  if (resolving.has(chainKey)) {
    throw new CircularReferenceError([...refChain, subName, ref])
  }

  resolving.add(chainKey)
  try {
    let content: string
    try {
      content = read(ref, basePath)
    } catch (error) {
      // Re-throw with the offending mount's pointer attached.
      if (error instanceof RefLoadError) {
        throw new RefLoadError(error.ref, undefined, error.code, error.message, pointer)
      }
      throw error
    }
    const refBasePath = isRemoteRef(ref) ? getRemoteBase(ref) : getLocalBase(ref, basePath)
    const parsed = resolveRefDocument(
      JSON.parse(content) as EsmFile,
      ref,
      refBasePath,
      readEdgeBindings(sub, subName),
      readEdgeInjectedImports(sub),
    )
    inline(parsed, refBasePath)
  } finally {
    resolving.delete(chainKey)
  }
}

/**
 * Shared subsystem-map walk for model and reaction-system resolution: for each
 * subsystem entry, either resolve its `ref` edge (`onRef`, given the parsed +
 * lowered referenced document and its base directory) or — when the entry
 * carries no `ref` — recurse into it (`onRecurse`). This is the one place the
 * two otherwise-parallel `resolveModelRefs` / `resolveReactionSystemRefs` loops
 * are unified; only the per-kind component extraction differs and is supplied
 * by the callbacks.
 */
function walkSubsystemRefs(
  subsystems: Record<string, unknown>,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  read: SyncRefReader,
  pointer: string,
  onRef: (
    parsed: EsmFile,
    refBasePath: string,
    ctx: { subName: string; ref: string; pointer: string },
  ) => void,
  onRecurse: (subsystem: unknown, subName: string, pointer: string) => void,
): void {
  for (const [subName, subsystem] of Object.entries(subsystems)) {
    const sub = subsystem as RefEdge
    const ref = sub.ref
    const subPointer = `${pointer}/subsystems/${subName}`
    if (ref) {
      resolveRefEdge(
        sub,
        ref,
        subName,
        basePath,
        resolving,
        refChain,
        read,
        subPointer,
        (parsed, refBasePath) => onRef(parsed, refBasePath, { subName, ref, pointer: subPointer }),
      )
    } else {
      // Even without a ref, recurse into nested subsystems.
      onRecurse(subsystem, subName, subPointer)
    }
  }
}

/**
 * Recursively resolve refs in a Model's subsystems.
 */
function resolveModelRefs(
  model: Model | SubsystemRef,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  registry: Record<string, unknown>,
  read: SyncRefReader,
  pointer: string,
): void {
  // A bare `{ ref }` stub (SubsystemRef) has no subsystems to walk; the
  // top-level model union admits it under v0.8.0, but only a full Model
  // carries `subsystems`.
  if (!('subsystems' in model) || !model.subsystems) return
  const subsystems = model.subsystems

  walkSubsystemRefs(
    subsystems,
    basePath,
    resolving,
    refChain,
    read,
    pointer,
    (parsed, refBasePath, { subName, ref, pointer: subPointer }) => {
      // esm-spec §4.7: the mounted file's document-scoped index sets (already
      // metaparameter-folded) join the importing document's registry, so the
      // importer's variables may be shaped over the mesh file's axes and a
      // disagreement fails loudly (`subsystem_index_set_conflict`).
      mergeSubsystemIndexSets(registry, parsed, ref)

      // esm-spec §4.7 invariant: a referenced subsystem file holds exactly ONE
      // top-level component — enforced, not assumed. A referenced file with no
      // `models` and no `data_loaders` leaves the original `{ref}` stub in
      // place; nothing is inlined here.
      assertSingleTopLevelSystem(parsed, ref, subPointer)
      if (parsed.models) {
        const firstEntry = Object.entries(parsed.models)[0]
        if (firstEntry) {
          const resolvedModel = firstEntry[1]
          // Replace the ref subsystem with the resolved model content, then
          // recursively resolve any refs in it, relative to the referenced
          // file's own directory.
          subsystems[subName] = resolvedModel
          resolveModelRefs(
            resolvedModel,
            refBasePath,
            resolving,
            [...refChain, subName],
            registry,
            read,
            subPointer,
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
          subsystems[subName] = firstEntry[1] as DataLoader
        }
      }
    },
    (subsystem, subName, subPointer) =>
      resolveModelRefs(
        subsystem as Model & RefEdge,
        basePath,
        resolving,
        [...refChain, subName],
        registry,
        read,
        subPointer,
      ),
  )
}

/**
 * Recursively resolve refs in a ReactionSystem's subsystems.
 */
function resolveReactionSystemRefs(
  rs: ReactionSystem | SubsystemRef,
  basePath: string,
  resolving: Set<string>,
  refChain: string[],
  read: SyncRefReader,
  pointer: string,
): void {
  // A bare `{ ref }` stub (SubsystemRef) carries no subsystems to walk; only a
  // full ReactionSystem does.
  if (!('subsystems' in rs) || !rs.subsystems) return
  const subsystems = rs.subsystems

  walkSubsystemRefs(
    subsystems,
    basePath,
    resolving,
    refChain,
    read,
    pointer,
    (parsed, refBasePath, { subName, ref, pointer: subPointer }) => {
      // esm-spec §4.7 invariant: exactly one top-level system per referenced
      // file — enforced, not assumed. A file with no `reaction_systems` leaves
      // the `{ref}` stub in place.
      assertSingleTopLevelSystem(parsed, ref, subPointer)
      if (parsed.reaction_systems) {
        const firstEntry = Object.entries(parsed.reaction_systems)[0]
        if (firstEntry) {
          const resolvedRs = firstEntry[1]
          // Replace the ref subsystem with the resolved content, then
          // recursively resolve any refs in it, relative to the referenced
          // file's own directory.
          subsystems[subName] = resolvedRs
          resolveReactionSystemRefs(
            resolvedRs,
            refBasePath,
            resolving,
            [...refChain, subName],
            read,
            subPointer,
          )
        }
      }
    },
    (subsystem, subName, subPointer) =>
      resolveReactionSystemRefs(
        subsystem as ReactionSystem & RefEdge,
        basePath,
        resolving,
        [...refChain, subName],
        read,
        subPointer,
      ),
  )
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
    // Caller/API precondition (not a document-level §9.6.6 diagnostic), so this
    // stays a plain `Error` rather than a coded `EsmMachineryError`.
    throw new Error('ephemeralInjectedFile: one of `file` or `sourcePath` must be provided')
  }

  let injected = false
  for (const kind of ['models', 'reaction_systems'] as const) {
    const comps = raw[kind]
    if (typeof comps !== 'object' || comps === null || Array.isArray(comps)) continue
    const comp = (comps as Record<string, unknown>)[mname]
    if (typeof comp !== 'object' || comp === null || Array.isArray(comp)) continue
    // Reuse the clone-based append (esm-spec §9.7.10 merge order) so the
    // per-run injection matches forms A/B and never captures `imports` by
    // reference into the built file.
    appendComponentImports(comp as Record<string, unknown>, imports)
    injected = true
    break
  }
  if (!injected) {
    // A §9.7.10 injection target that names no top-level component: a coded
    // diagnostic, consistent with the surrounding `EsmMachineryError`
    // convention (message preserved).
    throw new EsmMachineryError(
      ERROR_CODES.TEMPLATE_INJECT_TARGET_UNKNOWN,
      `component '${mname}' not found for per-run injection (esm-spec §9.7.10)`,
    )
  }

  const f = load(JSON.stringify(raw), { basePath: baseDir })
  await resolveSubsystemRefs(f, baseDir)
  return f
}

/**
 * Load content from a ref, dispatching to fetch() for URLs or fs for local paths.
 */
/**
 * The I/O primitive the resolution walk is parameterised over: given a `ref` and
 * the base directory it is relative to, hand back the target document's text.
 *
 * Parameterising the walk (rather than hard-wiring `fs`) is what lets ONE
 * implementation of the §4.7 semantics serve both the synchronous `validate()` /
 * `resolveSubsystemRefsSync()` path and the asynchronous, remote-capable
 * `resolveSubsystemRefs()` path.
 */
export type SyncRefReader = (ref: string, basePath: string) => string

/**
 * Synchronous local-file reader — the default for `resolveSubsystemRefsSync()`.
 *
 * A REMOTE ref is refused here rather than silently ignored: `fetch` cannot be
 * awaited synchronously, so a synchronous caller genuinely cannot resolve one.
 * Refusing it produces the ordinary `unresolved_subsystem_ref` diagnostic (with a
 * message naming the async resolver), which is the honest answer — as opposed to
 * leaving the `{ref}` stub in place and letting the document validate as though
 * the mount had succeeded.
 */
function loadRefSync(ref: string, basePath: string): string {
  if (isRemoteRef(ref)) {
    throw new RefLoadError(
      ref,
      undefined,
      ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
      `Remote ref "${ref}" cannot be resolved synchronously; use the async resolveSubsystemRefs()`,
    )
  }
  try {
    return readFileSyncNode(joinPath(basePath, ref))
  } catch (error) {
    throw new RefLoadError(ref, error instanceof Error ? error : new Error(String(error)))
  }
}

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

// `isRemoteRef`, `normalizeRef` (the cycle-detection key), `joinPath`, and
// `canonicalizePath` now come from the shared `./path-utils.js` module — they
// were byte-identical to the `template-imports.ts` copies. The two base-dir
// helpers below stay local: they derive an imported file's own directory for
// recursive resolution, which is not part of the shared path surface.

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
