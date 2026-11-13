/**
 * ESM Format JSON Parsing
 *
 * Provides functionality to load and validate ESM files from JSON strings or objects.
 * Separates concerns: JSON parsing → schema validation → type coercion.
 */

import type { ErrorObject } from 'ajv'
import validator from './generated-validator.js'
import type { EsmFile } from './types.js'
import { validateUnits, type UnitWarning } from './units.js'
import { losslessJsonParse, stripNumericLiterals } from './numeric-literal.js'
import { lowerEnums } from './lower-enums.js'
import {
  expandDocument,
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower-expression-templates.js'
import {
  applyScopeInjections,
  checkDataSourceExtents,
  collectMountDeclaredMetaparameters,
  documentDeclaresAnExtent,
  rejectImpureTemplateLibrary,
  rejectTemplateImportsPreV08,
  resolveTemplateMachinery,
} from './template-imports.js'
import {
  absoluteDirectory,
  normalizeEmptySolver,
  rejectConstUnitsPreV12,
  rejectSolverExternalPreV13,
  rejectSolverExternalUnresolved,
  rejectSolverPreV11,
  rejectSolverTimeSpanInvalid,
  rejectSolverTimeSpanPreV13,
} from './solver.js'
import { rejectVariableBoundsPreV21 } from './variable-bounds.js'
import { schema } from './embedded-schema.js'
import { readFileSyncNode, dirnameOf } from './path-utils.js'
import { deepClone } from './object-utils.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { resolveDataSourceUrls } from './data-source-urls.js'
import {
  deprecatedRecordsPerSampleSites,
  deprecatedRecordsPerSampleWarning,
} from './records-per-sample.js'

/**
 * The single root-path token used when a validation diagnostic has no more
 * specific location. The empty string `''` is the RFC-6901 JSON Pointer for the
 * document root (CONFORMANCE_SPEC §7.1.2), so every root-level `path` this
 * library emits — this module's schema-error root fallback, structural
 * errors/warnings, and the catch-paths in validate/orchestrator.ts — points at
 * the document root with the same canonical token the cross-language
 * conformance harness expects (not `$`, `/`, or `(root)`). Exported so
 * validate.ts consumes the same constant (validate imports parse, so there is
 * no import cycle).
 */
export const ROOT_PATH = ''

/**
 * Schema validation error with JSON Pointer path
 */
export interface SchemaError {
  /** JSON Pointer path to the error location */
  path: string
  /** Human-readable error message */
  message: string
  /** AJV validation keyword that failed */
  keyword: string
}

/**
 * Parse error - thrown when JSON parsing fails, or when the wire boundary
 * refuses a document before schema validation. `code` defaults to
 * `parse_error`; a removed op or field carries `removed_op`.
 */
export class ParseError extends EsmDiagnosticError {
  constructor(
    message: string,
    public originalError?: Error,
    code: string = ERROR_CODES.PARSE_ERROR,
  ) {
    super(code, message)
    this.name = 'ParseError'
  }
}

/**
 * Schema validation error - thrown when schema validation fails
 */
export class SchemaValidationError extends EsmDiagnosticError {
  constructor(
    message: string,
    public errors: SchemaError[],
  ) {
    super(ERROR_CODES.SCHEMA_VALIDATION_ERROR, message)
    this.name = 'SchemaValidationError'
  }
}

// The ESM schema is embedded via a GENERATED module so it cannot hand-drift
// from the canonical esm-schema.json. See scripts/generate-embedded-schema.mjs
// and the schema-sync guard in scripts/sync-schema.sh.

/**
 * The schema version this library implements, derived from the embedded
 * schema's `$id` (https://earthsciml.org/schemas/esm/<version>/esm.schema.json)
 * so it cannot hand-drift from the canonical esm-schema.json. The package
 * version in package.json is kept in lockstep.
 */
export const SCHEMA_VERSION: string = (() => {
  const id = (schema as { $id?: string }).$id ?? ''
  const m = /\/esm\/(\d+\.\d+\.\d+)\//.exec(id)
  if (!m) {
    throw new Error(`Embedded ESM schema $id does not carry a version: "${id}"`)
  }
  return m[1]
})()

// The schema validator is PRECOMPILED, not compiled here.
//
// `ajv.compile(schema)` used to run at this point, on module load. Ajv is a code
// generator — it builds JavaScript for the schema and evaluates it — so that
// call requires `'unsafe-eval'`. Under a Content-Security-Policy without it the
// compile threw before anything rendered, which did not degrade validation in a
// consuming app: it blanked the page. And granting `'unsafe-eval'` to get it
// back re-permits exactly the string-to-code execution a CSP is bought to
// prevent, which is a bad trade for a library that parses untrusted documents.
//
// `src/generated-validator.js` is the same schema compiled ahead of time by
// `scripts/generate-standalone-validator.mjs` (Ajv's own `ajv/dist/standalone`),
// under the options in `src/ajv-options.mjs`. Same logic, same errors — verified
// against the fixture corpus, valid and malformed, before the swap — but the
// browser only ever loads the code, never builds it.
//
// The generator is a drift guard too (`--check`, wired into
// `scripts/sync-schema.sh`), so a schema change that skips regeneration fails CI
// rather than shipping a validator for the previous schema.

/**
 * Validate data against the ESM schema
 */
export function validateSchema(data: unknown): SchemaError[] {
  // Reject unsupported major versions before AJV validation. Shares the
  // major-version predicate with `checkVersionCompatibility` (the throw
  // surface); this surface keeps its own separately-pinned schema-error
  // wording/keyword.
  const version = parseFileVersion(data)
  if (version !== null && isUnsupportedMajor(version)) {
    return [
      {
        path: '/esm',
        message: `Unsupported major version ${version.major}; this validator supports ${SUPPORTED_MAJORS_TEXT}`,
        keyword: 'major_version_mismatch',
      },
    ]
  }

  const isValid = validator(data)
  if (isValid || !validator.errors) {
    return []
  }

  return validator.errors.map((error: ErrorObject): SchemaError => ({
    path: error.instancePath ?? ROOT_PATH,
    message: error.message || 'Unknown validation error',
    keyword: error.keyword,
  }))
}

/**
 * Parse JSON string safely
 */
function parseJson(input: string): unknown {
  try {
    return JSON.parse(input)
  } catch (error) {
    throw new ParseError(
      `Invalid JSON: ${error instanceof Error ? error.message : 'Unknown error'}`,
      error instanceof Error ? error : undefined,
    )
  }
}

/**
 * Parse JSON string preserving integer-vs-float distinction via
 * `losslessJsonParse`. Numeric literals in the result are tagged
 * `NumericLiteral` leaves per RFC §5.4.1.
 */
function parseJsonLossless(input: string): unknown {
  try {
    return losslessJsonParse(input)
  } catch (error) {
    throw new ParseError(
      `Invalid JSON: ${error instanceof Error ? error.message : 'Unknown error'}`,
      error instanceof Error ? error : undefined,
    )
  }
}

/**
 * Parse a semantic version string and return its components
 */
function parseSemanticVersion(
  versionString: string,
): { major: number; minor: number; patch: number } | null {
  const match = versionString.match(/^(\d+)\.(\d+)\.(\d+)$/)
  if (!match) {
    return null
  }

  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10),
  }
}

const CURRENT_VERSION = parseSemanticVersion(SCHEMA_VERSION)!

/**
 * The last release of the esm 1.x line. A 1.x document loads at 2.0.0 (user
 * ruling): 2.0.0 removed ops and blocks and changed nothing else, so a 1.x
 * document that uses none of them means what it meant, and one that does is
 * refused with `removed_op` by name, not by its version. The 1.x version gates
 * stay live for it.
 */
export const LAST_V1_VERSION = '1.3.0'
const LAST_V1 = parseSemanticVersion(LAST_V1_VERSION)!

/** The newest release of each major this build loads, keyed by major. */
const NEWEST_BY_MAJOR: ReadonlyMap<number, { major: number; minor: number; patch: number }> =
  new Map([
    [LAST_V1.major, LAST_V1],
    [CURRENT_VERSION.major, CURRENT_VERSION],
  ])

/** The supported majors, for messages: `major versions 1, 2`. */
const SUPPORTED_MAJORS_TEXT =
  (NEWEST_BY_MAJOR.size > 1 ? 'major versions ' : 'major version ') +
  [...NEWEST_BY_MAJOR.keys()].sort().join(', ')

/**
 * The `esm` version declared by `data`, parsed into components, or `null` when
 * `data` is not an object, carries no string `esm`, or the string is not a
 * well-formed semantic version (those cases are deliberately left to schema
 * validation). Shared by both version-check surfaces below.
 */
function parseFileVersion(data: unknown): { major: number; minor: number; patch: number } | null {
  if (typeof data !== 'object' || data === null) return null
  const esm = (data as Record<string, unknown>).esm
  if (typeof esm !== 'string') return null
  return parseSemanticVersion(esm)
}

/**
 * The single definition of "this file's major version is incompatible with the
 * schema this build implements". Consulted by BOTH the `validateSchema`
 * schema-error surface and the `checkVersionCompatibility` throw surface so the
 * rejection rule lives in exactly one place (the two surfaces keep their own,
 * separately-pinned diagnostic wording).
 */
function isUnsupportedMajor(v: { major: number }): boolean {
  return !NEWEST_BY_MAJOR.has(v.major)
}

/**
 * Check version compatibility for an ESM file. Mirrors the Python binding's
 * `_check_version_compatibility`: a different major version is rejected; a
 * newer minor version warns but loads (the schema's `additionalProperties:
 * false` still applies — forward compatibility is warn-only, never weakened
 * validation).
 *
 * The minor-version warning is routed through `onVersionWarning` when supplied,
 * falling back to `console.warn` otherwise (the default that
 * `version-compatibility.test.ts` observes).
 */
function checkVersionCompatibility(
  data: unknown,
  onVersionWarning?: (message: string) => void,
): void {
  if (typeof data !== 'object' || data === null) {
    return // Let schema validation handle this
  }

  const version = (data as Record<string, unknown>).esm
  if (typeof version !== 'string') {
    return // Let schema validation handle this
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    return // Let schema validation handle invalid version format
  }

  // Reject unsupported major versions
  if (isUnsupportedMajor(versionComponents)) {
    throw new ParseError(
      `Unsupported major version ${versionComponents.major}. This library supports ${SUPPORTED_MAJORS_TEXT}.`,
    )
  }

  // Warn about a minor newer than the newest release of its major
  const newest = NEWEST_BY_MAJOR.get(versionComponents.major)!
  if (versionComponents.minor > newest.minor) {
    const latest = `${newest.major}.${newest.minor}.${newest.patch}`
    const message =
      `${version} is newer than the current library version ${latest}. ` +
      `Some features may not be supported.`
    if (onVersionWarning) {
      onVersionWarning(message)
    } else {
      console.warn(message)
    }
  }
}

/**
 * Options controlling how the `load*` entry points parse and represent an ESM file.
 */
export interface LoadOptions {
  /**
   * When `true`, numeric literals at Expression-bearing positions are
   * decoded to tagged `NumericLiteral` leaves so downstream consumers can preserve the
   * integer-vs-float distinction required by the canonical form
   * (discretization RFC §5.4.1 / §5.4.6). When `false` or absent
   * (default), numeric literals decode to plain JS numbers.
   *
   * Canonical mode only takes effect on {@link loadString} and
   * {@link loadPath}, which decode JSON text; {@link loadDocument} takes an
   * already-decoded object and ignores it.
   */
  canonical?: boolean

  /**
   * Directory anchoring relative `expression_template_imports` refs
   * (esm-spec §9.7.2). Defaults to the current working directory. Callers
   * loading from a known file path should pass that file's directory.
   */
  basePath?: string | undefined

  /**
   * Loader-API metaparameter bindings for the root document
   * (esm-spec §9.7.6 binding site 4): name → integer. Already-closed edge
   * bindings win; API bindings beat `default`s. Binding a name the
   * document does not declare raises `template_import_unknown_name`.
   */
  metaparameters?: Record<string, number> | undefined

  /**
   * Synchronous file reader used to resolve template-library import refs.
   * Defaults to Node's `fs.readFileSync` (via `process.getBuiltinModule`);
   * browser hosts that need template imports must supply their own.
   */
  readFile?: ((path: string) => string) | undefined

  /**
   * Scope-directed template injection for a §4.7 subsystem-ref edge
   * (esm-spec §9.7.10 form A): raw §9.7.2 import entries folded into this
   * document's single top-level component's own scope BEFORE the §9.6.3
   * fixpoint, so a mounted discretization-agnostic PDE leaf is lowered under
   * the assembler-chosen discretization. Threaded in by `resolveSubsystemRefs`
   * from the subsystem edge; not part of the public authoring surface.
   */
  injectedImports?: readonly unknown[] | undefined

  /**
   * Skip schema validation because the caller has already run
   * {@link validateSchema} on this input. Version checks and the
   * removed-construct rejections still apply. Used by `validate()` to avoid
   * validating the same document twice.
   */
  assumeValid?: boolean | undefined

  /**
   * Receives each dimensional-analysis warning instead of the default
   * `console.warn`. Used by `validate()` to collect unit warnings into its
   * structured result.
   */
  onUnitWarning?: ((warning: UnitWarning) => void) | undefined

  /**
   * Receives the forward-compatibility warning emitted when the file's minor
   * version is newer than the schema this build implements, instead of the
   * default `console.warn`. Parallels {@link onUnitWarning} so hosts can route
   * both load-time warnings into a structured channel.
   */
  onVersionWarning?: ((message: string) => void) | undefined

  /**
   * `false` silences the load-time `deprecated_records_per_sample` warning,
   * emitted with `console.warn` at most once per load. Used by `validate()`,
   * whose internal re-load of a document must not repeat the warning its own
   * load gave.
   */
  warn?: boolean | undefined
}

/**
 * Read and parse an ESM document from a filesystem path.
 *
 * The file's own directory anchors relative `expression_template_imports`
 * refs and `{ref}` subsystem refs unless `options.basePath` overrides it.
 * Requires synchronous file access (Node); browser hosts should read the
 * bytes themselves and call {@link loadString}.
 *
 * @param path - Filesystem path to the `.esm` document
 * @param options - Optional load-time settings (see {@link LoadOptions})
 * @returns Typed EsmFile object
 * @throws {ParseError} When JSON parsing fails or version is incompatible
 * @throws {SchemaValidationError} When schema validation fails
 */
export function loadPath(path: string, options?: LoadOptions): EsmFile {
  const text = (options?.readFile ?? readFileSyncNode)(path)
  const basePath = options?.basePath ?? dirnameOf(path)
  return loadInput(text, { ...options, basePath })
}

/**
 * Parse an ESM document from JSON TEXT.
 *
 * @param json - The document as a JSON string
 * @param options - Optional load-time settings (see {@link LoadOptions})
 * @returns Typed EsmFile object
 * @throws {ParseError} When JSON parsing fails or version is incompatible
 * @throws {SchemaValidationError} When schema validation fails
 */
export function loadString(json: string, options?: LoadOptions): EsmFile {
  return loadInput(json, options)
}

/**
 * Parse an ESM document that is ALREADY a JavaScript object — the same
 * document a `.esm` file holds, just already `JSON.parse`d.
 *
 * `options.canonical` has no effect here: canonical mode tags numeric
 * literals during JSON decoding, and this entry point does no decoding.
 * Callers who want tagged leaves should pass the JSON text to
 * {@link loadString} with `canonical: true` instead.
 *
 * @param doc - The already-parsed document
 * @param options - Optional load-time settings (see {@link LoadOptions})
 * @returns Typed EsmFile object
 * @throws {SchemaValidationError} When schema validation fails
 */
export function loadDocument(doc: object, options?: LoadOptions): EsmFile {
  return loadInput(doc, options)
}

/**
 * The shared pipeline behind {@link loadPath}, {@link loadString} and
 * {@link loadDocument}. NOT exported: `load(stringOrObject)` was the whole
 * bug — the same name and argument type meant "file path" in Julia and Go
 * and "JSON text" here, with no type error anywhere to catch the difference.
 */
function loadInput(input: string | object, options?: LoadOptions): EsmFile {
  const canonical = options?.canonical === true

  // Step 1: JSON parsing. In canonical mode, decode tagged numeric
  // literals and keep a separate plain view for Ajv schema validation
  // (the schema declares `type: number`, which does not match tagged
  // `NumericLiteral` objects).
  let data: unknown
  let validationView: unknown
  if (typeof input === 'string') {
    if (canonical) {
      data = parseJsonLossless(input)
      validationView = stripNumericLiterals(data)
    } else {
      data = parseJson(input)
      validationView = data
    }
  } else {
    // Copy: the passes below rewrite nested values (data-source locations, the
    // solver block), and a caller that handed us a live object should not see
    // its document mutated.
    // Rust, Go and Julia all work on their own copy; this makes the five agree.
    data = structuredClone(input)
    validationView = canonical ? stripNumericLiterals(data) : data
  }

  // Step 1a-pre: the wire boundary for `op` spellings — removed ops and blocks
  // are refused by name, ahead of every other pass, and the `faq` version gate
  // reads the authored form.
  prepareDocumentOps(data)

  // Step 1a: esm-spec §8.2.1 — resolve every `data_sources[*].source` location
  // against this document's own directory, before schema validation and before
  // anything downstream reads the field, so the typed `DataSourceLocation`,
  // `flatten`'s `LoaderField` and `emit` all see one resolved form and none of
  // them needs a base directory. Idempotent (the output is scheme-led), so
  // `parse → emit → parse` is stable. Both views are rewritten because in
  // canonical mode `validationView` is a separate stripped copy; applying the
  // pass twice to the same object is harmless for the same reason.
  const dataSourceBase =
    options?.basePath ??
    (typeof process !== 'undefined' && typeof process.cwd === 'function' ? process.cwd() : '.')
  const dsResolved = resolveDataSourceUrls(data, dataSourceBase)
  if (dsResolved !== null) {
    data = dsResolved
    // In canonical mode `validationView` is a SEPARATE stripped copy, so it
    // needs its own pass; otherwise it is the same object and just follows.
    validationView = canonical
      ? (resolveDataSourceUrls(validationView, dataSourceBase) ?? validationView)
      : data
  }

  // Step 2: Version compatibility check (before schema validation)
  checkVersionCompatibility(validationView, options?.onVersionWarning)

  // Step 2a: v0.3.0 file-boundary rejection of removed v0.2.x extension
  // points (esm-spec §9). Mirrors the
  // Julia ref `parse.jl` rejection so cross-binding behavior is uniform.
  rejectRemovedV02Blocks(validationView)

  // Steps 2b–2e: every file-level version gate and the root-only solver checks,
  // before schema validation so the user sees the version hint instead of a
  // generic "extra property" error.
  rejectRootLoadGates(validationView)
  // Then §2.2's one normalization — an EMPTY block means what absence means, so
  // it is dropped here rather than surviving to emit. Applied to BOTH views for
  // the same reason `resolveDataSourceUrls` is: in canonical mode
  // `validationView` is a separate stripped copy, and the `EsmFile` is built out
  // of `data`.
  const solverNormalized = normalizeEmptySolver(data)
  if (solverNormalized !== null) {
    data = solverNormalized
    validationView = canonical ? (normalizeEmptySolver(validationView) ?? validationView) : data
  }

  // Step 3: Schema validation
  if (options?.assumeValid !== true) {
    const schemaErrors = validateSchema(validationView)
    if (schemaErrors.length > 0) {
      throw new SchemaValidationError(
        `Schema validation failed with ${schemaErrors.length} error(s)`,
        schemaErrors,
      )
    }
  }

  // Step 3a: Resolve esm-spec §9.7 machinery first — template-library
  // imports (depth-first post-order, per-edge metaparameter instantiation),
  // index_sets merge, metaparameter close+fold — then expand
  // `apply_expression_template` ops / fire `match` rules to the §9.6.3
  // fixpoint. After both passes the tree carries no
  // apply_expression_template nodes, no `expression_templates` blocks, no
  // imports, and no metaparameters — downstream consumers see only normal
  // Expression ASTs (Option A round-trip).
  const basePath = dataSourceBase
  // esm-spec §9.7.10 forms A/B: fold any scope-directed injection — a
  // subsystem-ref edge's `injectedImports` (form A) or a coupling entry's
  // injection map (form B) — into the target components' own
  // `expression_template_imports` BEFORE resolution, so the ordinary import
  // resolver + §9.6.3 fixpoint lower the target under the chosen
  // discretization. `null` when no injection applies (the fast path).
  const injectedRoot = applyScopeInjections(data, options?.injectedImports ?? [])
  const machineryInput = injectedRoot ?? data
  // The ROOT document's CLOSED metaparameter environment — its declared integer
  // defaults overlaid with the loader-API bindings — captured BEFORE resolution
  // consumes the `metaparameters` block. It is the scope each §4.7 mount
  // contribution folds against as it merges (esm-spec §4.7 "Index-set merge"),
  // and it leaves here on a non-enumerable sidecar because ref resolution is a
  // separate entry point in this binding.
  const rootMetaEnv: Record<string, number> = {}
  {
    const decls = (machineryInput as { metaparameters?: Record<string, unknown> }).metaparameters
    if (decls && typeof decls === 'object' && !Array.isArray(decls)) {
      for (const [n, d] of Object.entries(decls)) {
        const dflt = (d as { default?: unknown } | null)?.default
        if (typeof dflt === 'number' && Number.isInteger(dflt)) rootMetaEnv[n] = dflt
      }
    }
    for (const [k, v] of Object.entries(options?.metaparameters ?? {})) rootMetaEnv[k] = v
  }
  // The metaparameter names every document this one MOUNTS declares (esm-spec
  // §4.7, either mount form, transitively). It widens the §9.7.6 site-4 check:
  // a loader-API binding — which is how a discovered §8.9.4 `extent` arrives —
  // may name a metaparameter the LEAF declares and this document has no reason
  // to restate. The mount edge forwards it into the leaf's own close, so the
  // name is meaningful; only a name NO document in the assembly declares is the
  // typo the check exists to catch.
  // Guarded: the widening can only matter when the load carries loader-API
  // bindings or the document declares an `extent`. A document with neither pays
  // no extra ref reads — which also keeps the ordinary load off the filesystem
  // for every mount it would otherwise re-read here.
  const mountDeclared =
    (options?.metaparameters && Object.keys(options.metaparameters).length > 0) ||
    documentDeclaresAnExtent(machineryInput)
      ? collectMountDeclaredMetaparameters(machineryInput, basePath, {
          readFile: options?.readFile,
        })
      : undefined
  // esm-spec §8.9.4, statically: an `extent` naming a metaparameter nobody
  // declares is refused HERE rather than when the source is finally sampled at
  // build.
  //
  // ON THE AUTHORED TREE, and that placement is load-bearing rather than
  // incidental (esm-spec §8.9.4 "When the check is evaluated"). Both this check
  // and `mountDeclared` above read the UNRESOLVED `{ref}` mount edges: a §4.7
  // mount CONSUMES the leaf's `metaparameters` at its edge (§9.7.6 site 3), so
  // once refs are resolved the names a conforming `extent` legitimately reaches
  // are gone. Resolving refs ahead of the root machinery is a legitimate thing
  // to want — a rewrite target inside a mounted component only lowers if the
  // content is spliced in first — so if that ever happens in this binding it
  // must happen BELOW this line, not above it.
  //
  // Moving the check after the close is not the alternative it looks like: the
  // close folds this document's own `index_sets` sizes to integers, which makes
  // `documentIsInResolvedShape` true for any mount-less document and exempts it,
  // so a single file whose `extent` misspells a metaparameter it declares itself
  // stops being caught. Measured both ways.
  checkDataSourceExtents(machineryInput, basePath, mountDeclared ?? new Set<string>(), {
    readFile: options?.readFile,
  })
  const resolved = resolveTemplateMachinery(machineryInput, basePath, {
    metaparameters: options?.metaparameters,
    readFile: options?.readFile,
    validateSchema,
    mountDeclared,
  })
  data = resolved ?? machineryInput
  // esm-spec §9.6.4 (Option B): `lowerExpressionTemplates` resolves the document
  // to the REFERENCE-PRESERVING form (surviving references, retained registries).
  // The TS binding uses the RFC §7.7 "Expand at build" evaluation strategy: call
  // `Expand` (`expandDocument`) once here at typed-coercion time, so every
  // downstream consumer (codegen, units, graph, …) sees the Option-A expanded
  // image and remains numerically bit-identical to pre-0.9.0 behavior. The
  // reference-preserving form is what `emitDocument` re-derives from source.
  const loweredTemplates = lowerExpressionTemplates(data as object)
  // Capture the per-component `expression_templates` registries while the
  // Option-B image still holds them: `expandDocument` below strips every block,
  // and esm-libraries-spec §4.7.5 step 4 requires `flatten` to carry the MERGED
  // registry as a first-class field of the flattened representation. Keyed
  // `"models.<name>"` / `"reaction_systems.<name>"` (the Julia / Python
  // `component_templates` key shape).
  const componentTemplates = captureComponentTemplates(loweredTemplates)
  const authoredTemplateRhs = captureTemplateApplicationRhs(loweredTemplates)
  const typedData = expandDocument(loweredTemplates) as EsmFile

  // Step 4: Lower `enum` ops to `const` integer nodes against the
  // file-local `enums` block (esm-spec §9.3). After this pass, the
  // codegen runner sees only `const` — `evaluateExpression()` rejects
  // any leftover `enum` op as an unlowered file.
  const loweredData = lowerEnums(typedData)

  // Attach the captured Option-B registries (NON-SCHEMA, loader-populated —
  // see `EsmFile.componentTemplates` in `types.ts`). Omitted entirely when the
  // document declares no per-component block, which is the common case, so a
  // normal load carries no extra key.
  //
  // NON-ENUMERABLE deliberately. The field is a loader sidecar, not a document
  // field, and the conformance round-trip asserts
  // `loadString(toJson(loadString(f)))` deep-equals `loadString(f)`. An
  // enumerable sidecar breaks that identity for every template-bearing fixture:
  // `toJson` cannot emit it (the schema has no such key), so the reloaded file
  // has no per-component `expression_templates` left to recapture. Hiding it
  // from enumeration keeps `JSON.stringify`, `Object.keys`, and structural
  // equality seeing exactly the document — while `file.componentTemplates` still
  // reads normally for `flatten`.
  if (Object.keys(componentTemplates).length > 0) {
    Object.defineProperty(loweredData, 'componentTemplates', {
      value: componentTemplates,
      enumerable: false,
      writable: true,
      configurable: true,
    })
  }

  // The authored right-hand side of every equation that applies a template, for
  // `faq_bare_array_operand` (see `EsmFile.authoredTemplateRhs`).
  if (Object.keys(authoredTemplateRhs).length > 0) {
    Object.defineProperty(loweredData, 'authoredTemplateRhs', {
      value: authoredTemplateRhs,
      enumerable: false,
      writable: true,
      configurable: true,
    })
  }

  // Same sidecar mechanism, for the loader-API metaparameter bindings (§9.7.6
  // site 4). `resolveSubsystemRefsSync` is a SEPARATE entry point in this
  // binding — `load` does not inline `{ref}` mounts — so this is the only route
  // by which the bindings reach a `subsystems.<k>` mount edge, where §4.7 says
  // they must seed the leaf's close exactly as they do at a top-level mount.
  // Non-enumerable for the same round-trip reason as `componentTemplates`.
  if (options?.metaparameters && Object.keys(options.metaparameters).length > 0) {
    Object.defineProperty(loweredData, 'loaderMetaparameters', {
      value: { ...options.metaparameters },
      enumerable: false,
      writable: true,
      configurable: true,
    })
  }

  // And the same sidecar again, for the ROOT document's CLOSED metaparameter
  // environment (its declared integer defaults overlaid with the loader-API
  // bindings). `resolveSubsystemRefsSync` needs it to fold each §4.7 mount
  // contribution as it merges (esm-spec §4.7 "Index-set merge"), and by the time
  // that entry point runs the `metaparameters` block resolution consumed is
  // gone — so it is captured HERE, on the pre-resolution document, or not at all.
  Object.defineProperty(loweredData, 'rootMetaEnv', {
    value: rootMetaEnv,
    enumerable: false,
    writable: true,
    configurable: true,
  })

  // esm-spec §10.10 / §4.7: a relative `coupling_import` `ref` names a file
  // relative to THIS document, not to the working directory `flatten` runs in.
  // `flatten` never learns where the document came from, so the base is kept
  // as a sidecar — the refs stay as authored, because the entry must round-trip
  // verbatim (§10.10.3). Only an explicit base is recorded.
  if (options?.basePath !== undefined) {
    Object.defineProperty(loweredData, 'couplingImportBase', {
      value: options.basePath,
      enumerable: false,
      writable: true,
      configurable: true,
    })
  }

  // esm-spec §2.2.6: `solver.external` resolves against the directory of the
  // file read, or the working directory for a string load. Recorded absolute,
  // here, so a later change of working directory does not move it; kept beside
  // the document because `external` round-trips verbatim.
  Object.defineProperty(loweredData, 'documentBase', {
    value: absoluteDirectory(dataSourceBase),
    enumerable: false,
    writable: true,
    configurable: true,
  })

  // Step 5: Dimensional analysis — emit warnings but never fail the load.
  // Mirrors the Julia @warn behavior so TS callers get the same signal
  // without an API break.
  const onUnitWarning = options?.onUnitWarning
  for (const warning of validateUnits(loweredData)) {
    if (onUnitWarning) {
      onUnitWarning(warning)
    } else {
      const location = warning.location ? ` [${warning.location}]` : ''
      console.warn(`ESM unit validation${location}: ${warning.message}`)
    }
  }

  // esm-spec §8.5.1: the deprecated `records_per_sample` loads with ONE
  // warning per load naming every place it is written. Mounted `{ref}`
  // children never pass through here, so they add no second warning.
  if (options?.warn !== false) {
    const sites = deprecatedRecordsPerSampleSites(loweredData)
    if (sites.length > 0) console.warn(deprecatedRecordsPerSampleWarning(sites))
  }

  return loweredData
}

/**
 * The per-component `expression_templates` blocks of an Option-B loaded
 * document, keyed `"<section>.<component>"` (`models.A`,
 * `reaction_systems.rs1`).
 *
 * Snapshot taken on the tree BETWEEN `lowerExpressionTemplates` (which
 * preserves the blocks) and `expandDocument` (which strips them). Deep copied,
 * so a later in-place pass over the document cannot mutate the snapshot.
 * Components declaring no block are omitted, so the common document yields
 * `{}` and flatten's registry merge is a no-op.
 *
 * Mirrors the Python reference `parse._capture_component_templates`.
 */
/**
 * The right-hand side of every model equation, inline subsystems included,
 * that holds an `apply_expression_template` node, keyed by its equation
 * pointer. Taken on the reference-preserving form, before `expandDocument`.
 */
function captureTemplateApplicationRhs(data: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const isObject = (v: unknown): v is Record<string, unknown> =>
    v !== null && typeof v === 'object' && !Array.isArray(v)
  const holdsApplication = (v: unknown): boolean => {
    if (Array.isArray(v)) return v.some(holdsApplication)
    if (!isObject(v)) return false
    if (v.op === 'apply_expression_template') return true
    return Object.values(v).some(holdsApplication)
  }
  const visit = (model: Record<string, unknown>, path: string): void => {
    const equations = Array.isArray(model.equations) ? model.equations : []
    equations.forEach((eq: unknown, i: number) => {
      if (isObject(eq) && holdsApplication(eq.rhs))
        out[`${path}/equations/${i}`] = deepClone(eq.rhs)
    })
    if (isObject(model.subsystems)) {
      for (const [name, sub] of Object.entries(model.subsystems)) {
        if (isObject(sub)) visit(sub, `${path}/subsystems/${name}`)
      }
    }
  }
  if (isObject(data) && isObject(data.models)) {
    for (const [name, model] of Object.entries(data.models)) {
      if (isObject(model)) visit(model, `/models/${name}`)
    }
  }
  return out
}

function captureComponentTemplates(data: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  if (data === null || typeof data !== 'object' || Array.isArray(data)) return out
  const root = data as Record<string, unknown>
  for (const section of ['models', 'reaction_systems'] as const) {
    const comps = root[section]
    if (comps === null || typeof comps !== 'object' || Array.isArray(comps)) continue
    for (const [cname, comp] of Object.entries(comps as Record<string, unknown>)) {
      if (comp === null || typeof comp !== 'object' || Array.isArray(comp)) continue
      const block = (comp as Record<string, unknown>).expression_templates
      if (block === null || typeof block !== 'object' || Array.isArray(block)) continue
      if (Object.keys(block as Record<string, unknown>).length === 0) continue
      out[`${section}.${cname}`] = deepClone(block)
    }
  }
  return out
}

/**
 * Reject the v0.2.x extension points that v0.3.0 closed (esm-spec §9 /
 * docs/rfcs/closed-function-registry.md):
 *
 *   - top-level `operators` block — replaced by AST equations + named
 *     `discretizations` schemes.
 *   - top-level `registered_functions` block — replaced by AST equations
 *     and expression templates.
 *   - any expression-tree `call` op — likewise.
 *
 * Throws `SchemaValidationError` with one entry per offending location
 * so the caller surfaces all of them at once. Operates on the
 * pre-coercion view (plain JS objects) so it sees `op: "call"` exactly
 * as the file declared it.
 */
function rejectRemovedV02Blocks(view: unknown): void {
  if (!view || typeof view !== 'object') return
  const errors: SchemaError[] = []
  const root = view as Record<string, unknown>

  if ('operators' in root) {
    errors.push({
      path: '/operators',
      keyword: 'removed_in_v0_3',
      message:
        "top-level 'operators' block was removed in ESM v0.3.0; migrate to AST equations + 'discretizations' (closed-function-registry RFC §6).",
    })
  }
  if ('registered_functions' in root) {
    errors.push({
      path: '/registered_functions',
      keyword: 'removed_in_v0_3',
      message:
        "top-level 'registered_functions' block was removed in ESM v0.3.0; migrate to AST equations or expression templates (esm-spec §9.6).",
    })
  }

  // Walk the tree looking for `call` ops anywhere they could appear.
  const callPaths: string[] = []
  const walk = (node: unknown, path: string): void => {
    if (!node) return
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) walk(node[i], `${path}/${i}`)
      return
    }
    if (typeof node !== 'object') return
    const obj = node as Record<string, unknown>
    if (obj.op === 'call') callPaths.push(path)
    for (const k of Object.keys(obj)) walk(obj[k], `${path}/${k}`)
  }
  walk(root, '')
  for (const p of callPaths) {
    errors.push({
      path: p,
      keyword: 'removed_in_v0_3',
      message:
        "'call' AST op was removed in ESM v0.3.0; migrate to AST equations or expression templates (esm-spec §9.6).",
    })
  }

  if (errors.length > 0) {
    throw new SchemaValidationError(
      `ESM v0.3.0 rejects ${errors.length} removed v0.2.x construct(s)`,
      errors,
    )
  }
}

/** Path of the first node carrying `"op": <op>`, or `null`. */
function findOp(node: unknown, op: string, at = ''): string | null {
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) {
      const hit = findOp(node[i], op, `${at}/${i}`)
      if (hit !== null) return hit
    }
  } else if (node !== null && typeof node === 'object') {
    const obj = node as Record<string, unknown>
    if (obj.op === op) return at
    for (const k of Object.keys(obj)) {
      const hit = findOp(obj[k], op, `${at}/${k}`)
      if (hit !== null) return hit
    }
  }
  return null
}

/**
 * Ops removed at esm 2.0.0, each with what replaces it. Rejected BY NAME at the
 * wire boundary ({@link prepareDocumentOps}): every one is a well-formed
 * identifier, so the open rewrite-target tier (esm-spec §4.2) would otherwise
 * admit it and the document would fail much later as `unlowered_operator`.
 */
const REMOVED_OPS_V2: ReadonlyMap<string, string> = new Map([
  ['fn', 'the esm:std/interp.esm, esm:std/calendar.esm and esm:std/solar.esm templates'],
  ['table_lookup', 'the `linear` / `bilinear` templates of esm:std/interp.esm over the table data'],
  ['skolem', '`pair_key` / `edge_key` from esm:std/relational.esm, keyed into a `distinct` `faq`'],
  ['rank', 'the `rank_of` / `rank_of_set` templates of esm:std/relational.esm'],
  ['intersect_polygon', 'nothing (it has no replacement)'],
  [
    'polygon_intersection_area',
    'the `overlap_area_planar` / `overlap_area_spherical` templates of esm:std/geometry.esm',
  ],
  ['argmin', 'the `argmin` template of esm:std/relational.esm'],
  ['argmax', 'the `argmax` template of esm:std/relational.esm'],
  ['aggregate', '`"op": "faq"`, the same node under its 1.1.0 name'],
])

/** Where a removed construct's message sends the author. */
const MIGRATE_HINT = 'Convert the document with the codemod: `python -m earthsci_ast.migrate`.'

/** Path and name of the first node (pre-order) whose `op` is in `ops`, or `null`. */
function findFirstOp(
  node: unknown,
  ops: ReadonlyMap<string, string>,
  at = '',
): { path: string; op: string } | null {
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) {
      const hit = findFirstOp(node[i], ops, `${at}/${i}`)
      if (hit !== null) return hit
    }
  } else if (node !== null && typeof node === 'object') {
    const obj = node as Record<string, unknown>
    if (typeof obj.op === 'string' && ops.has(obj.op)) return { path: at, op: obj.op }
    for (const k of Object.keys(obj)) {
      const hit = findFirstOp(obj[k], ops, `${at}/${k}`)
      if (hit !== null) return hit
    }
  }
  return null
}

/**
 * Path of the first `function_tables` block (removed at esm 2.0.0) on the
 * document root or on any component — a `models` / `reaction_systems` entry or
 * one of their `subsystems`, at any depth — or `null`.
 */
function findFunctionTables(doc: unknown): string | null {
  const isObj = (v: unknown): v is Record<string, unknown> =>
    v !== null && typeof v === 'object' && !Array.isArray(v)
  const visit = (component: unknown, at: string): string | null => {
    if (!isObj(component)) return null
    if ('function_tables' in component) return `${at}/function_tables`
    const subs = component.subsystems
    if (isObj(subs)) {
      for (const [k, sub] of Object.entries(subs)) {
        const hit = visit(sub, `${at}/subsystems/${k}`)
        if (hit !== null) return hit
      }
    }
    return null
  }
  if (!isObj(doc)) return null
  if ('function_tables' in doc) return '/function_tables'
  for (const kind of ['models', 'reaction_systems']) {
    const block = doc[kind]
    if (!isObj(block)) continue
    for (const [k, component] of Object.entries(block)) {
      const hit = visit(component, `/${kind}/${k}`)
      if (hit !== null) return hit
    }
  }
  return null
}

/**
 * The first removed construct `doc` uses, as its JSON path and `removed_op`
 * message, or `null` when it uses none: `"op": "arrayop"` (removed at esm
 * 0.8.0), then the `function_tables` block, then the ops in
 * {@link REMOVED_OPS_V2} in pre-order. The message names the construct, where
 * it sits, and what replaces it. Shared by the load-time rejection,
 * `validate()` and `migrate()`, which refuses to relabel such a 1.x document.
 */
export function findRemovedConstruct(doc: unknown): { path: string; message: string } | null {
  const arrayopAt = findOp(doc, 'arrayop')
  if (arrayopAt !== null) {
    return {
      path: arrayopAt,
      message:
        `removed_op at ${arrayopAt}: \`"op": "arrayop"\` was removed at esm 0.8.0 and is not ` +
        `a deprecated alias; use \`"op": "faq"\` (the Functional Aggregate Query node). ` +
        `See docs/content/rfcs/faq-node-rename.md.`,
    }
  }
  const tablesAt = findFunctionTables(doc)
  if (tablesAt !== null) {
    return {
      path: tablesAt,
      message:
        `removed_op at ${tablesAt}: the \`function_tables\` block was removed at esm 2.0.0; ` +
        `read the table data with the \`linear\` / \`bilinear\` templates of ` +
        `esm:std/interp.esm instead. ${MIGRATE_HINT}`,
    }
  }
  const hit = findFirstOp(doc, REMOVED_OPS_V2)
  if (hit !== null) {
    return {
      path: hit.path,
      message:
        `removed_op at ${hit.path}: \`"op": "${hit.op}"\` was removed at esm 2.0.0; ` +
        `use ${REMOVED_OPS_V2.get(hit.op)} instead. ${MIGRATE_HINT}`,
    }
  }
  return null
}

/** Does `doc` declare an `esm` version below 1.1.0? */
function declaredBelowV11(doc: unknown): boolean {
  if (doc === null || typeof doc !== 'object') return false
  const esm = (doc as Record<string, unknown>).esm
  if (typeof esm !== 'string') return false
  const [major, minor] = esm.split('.').map((x) => Number.parseInt(x, 10))
  if (Number.isNaN(major) || Number.isNaN(minor)) return false
  return major < 1 || (major === 1 && minor < 1)
}

/**
 * The checks {@link loadDocument} runs on the ROOT document after the major
 * version check and before schema validation: every file-level version gate
 * ({@link rejectVersionGatedConstructs}), the template-library purity check,
 * and the root-only `solver.external` / `solver.time_span` checks, in that
 * order.
 */
function rejectRootLoadGates(validationView: unknown): void {
  // A mounted leaf runs the same list against its own `esm` (esm-spec §4.7).
  rejectVersionGatedConstructs(validationView)
  // Top-level `expression_templates` beside a component payload is a
  // template-library payload no component can see (esm-spec §9.7.1).
  rejectImpureTemplateLibrary(validationView)
  // `solver.external` and `solver.time_span` arrive at esm 1.3.0 (§2.2.4); a
  // `${` in `external` is refused (§2.2.6), and `time_span` must describe an
  // interval once its bounds are converted to seconds (§2.2.7). Root only: a
  // mounted leaf's block never reaches these passes. After the whole-block
  // gate, so a document below 1.1.0 is told about the block first. Skips a
  // bound the schema will report.
  rejectSolverExternalPreV13(validationView)
  rejectSolverTimeSpanPreV13(validationView)
  rejectSolverExternalUnresolved(validationView)
  rejectSolverTimeSpanInvalid(validationView)
}

/**
 * Every file-level version gate: a construct the document spells while
 * declaring an `esm` older than the one that introduced it is rejected with
 * that construct's `*_version_too_old`-style diagnostic. Run against the root
 * by {@link loadDocument} and against every §4.7-mounted leaf on its OWN
 * declared `esm` (esm-spec §4.7), so the two paths cannot drift.
 *
 * The `faq` gate lives in {@link prepareDocumentOps}, because it alone reads the
 * AUTHORED version.
 *
 * - `expression_templates` / `apply_expression_template` — esm 0.4.0
 * - `expression_template_imports`, top-level `expression_templates`,
 *   `metaparameters` — esm 0.8.0 (esm-spec §9.6.5)
 * - the top-level `solver` block — esm 1.1.0 (esm-spec §2.2.4)
 * - declared `units` on a `const` node — esm 1.2.0 (esm-spec §4.8.5)
 * - `lb` / `ub` on a model variable — esm 2.1.0 (esm-spec §6.3.2)
 *
 * Not here: the esm 1.3.0 gates on `solver.external` and `solver.time_span`
 * are checks on the root alone (esm-spec §2.2.6 and §2.2.7 "Mounting"), so
 * {@link loadDocument} runs them itself, after this.
 */
export function rejectVersionGatedConstructs(view: unknown): void {
  rejectExpressionTemplatesPreV04(view)
  rejectTemplateImportsPreV08(view)
  rejectSolverPreV11(view)
  rejectConstUnitsPreV12(view)
  rejectVariableBoundsPreV21(view)
}

/**
 * Raise a document's declared `esm` to the 1.1.0 `faq` floor when it CONTAINS a
 * `faq` node but declares less. FLOOR only — a document at or above 1.1.0 keeps
 * its own version.
 *
 * A document can come to CONTAIN `faq` without ever spelling it: a 1.0.0 parent
 * that mounts a subsystem whose child uses `faq` has the child inlined at
 * resolution. The parent's AUTHORED bytes stay legal — the gate in
 * {@link prepareDocumentOps} reads the authored form and must not reject them —
 * but the RESOLVED document really does carry the node, so anything that
 * re-enters the loader with it trips a gate nobody mis-authored. `validate()`
 * does exactly that: it calls `loadDocument` on whatever it is handed, which is
 * routinely a document the caller already resolved. Stamping the floor at
 * resolution keeps the resolved form self-consistent; it is the same stamp
 * `toJson` applies on the way out (see `serialize.ts`), one step earlier.
 *
 * See docs/content/rfcs/faq-node-rename.md §5.5.
 */
export function raiseFaqVersionFloor(doc: unknown): void {
  if (doc === null || typeof doc !== 'object') return
  if (!declaredBelowV11(doc)) return
  if (findOp(doc, 'faq') === null) return
  ;(doc as Record<string, unknown>).esm = '1.1.0'
}

/**
 * The wire boundary for expression-node `op` spellings, applied to EVERY
 * document — root, `{ref}`-loaded child, template library, coupling library.
 *
 * Two steps, in this order:
 *
 * 1. `arrayop` (removed at esm 0.8.0), the ops removed at esm 2.0.0 (the
 *    `aggregate` alias of `faq` among them) and the `function_tables` block are
 *    rejected BY NAME with `removed_op`. Each op is a well-formed identifier, so
 *    esm-spec §4.2 would otherwise admit it as an OPEN rewrite-target op: the
 *    document would load silently and fail much later as `unlowered_operator`,
 *    or never.
 * 2. The `faq` version gate, on the AUTHORED form — `faq` arrives at esm 1.1.0
 *    (esm-spec §2.2.4).
 *
 * Read-only: the document is not modified.
 */
export function prepareDocumentOps(doc: unknown): void {
  const removed = findRemovedConstruct(doc)
  if (removed !== null) throw new ParseError(removed.message, undefined, ERROR_CODES.REMOVED_OP)
  const faqAt = findOp(doc, 'faq')
  if (faqAt !== null && declaredBelowV11(doc)) {
    const declared = (doc as Record<string, unknown>).esm
    throw new ParseError(
      `faq_version_too_old at ${faqAt}: the \`faq\` op arrives at esm 1.1.0; file declares ` +
        `${String(declared)}. Raise the declared version. ` +
        `See docs/content/rfcs/faq-node-rename.md.`,
    )
  }
}
