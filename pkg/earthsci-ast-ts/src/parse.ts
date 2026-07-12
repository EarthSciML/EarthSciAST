/**
 * ESM Format JSON Parsing
 *
 * Provides functionality to load and validate ESM files from JSON strings or objects.
 * Separates concerns: JSON parsing → schema validation → type coercion.
 */

import type { ErrorObject, ValidateFunction } from 'ajv'
import Ajv from 'ajv'
import addFormats from 'ajv-formats'
import type { EsmFile } from './types.js'
import { validateUnits, type UnitWarning } from './units.js'
import { losslessJsonParse, stripNumericLiterals } from './numeric-literal.js'
import { lowerEnums } from './lower-enums.js'
import {
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower-expression-templates.js'
import {
  applyScopeInjections,
  rejectTemplateImportsPreV08,
  resolveTemplateMachinery,
} from './template-imports.js'
import { schema } from './embedded-schema.js'

/**
 * The single root-path token used when a validation diagnostic has no more
 * specific location. `'$'` is chosen (over a bare `'/'`) so every root-level
 * `path` this library emits — structural errors/warnings and catch-paths in
 * validate.ts as well as this module's schema-error root fallback — is uniform,
 * matching the Python and Go bindings. Exported so validate.ts consumes the
 * same constant (validate imports parse, so there is no import cycle).
 */
export const ROOT_PATH = '$'

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
 * Parse error - thrown when JSON parsing fails
 */
export class ParseError extends Error {
  constructor(
    message: string,
    public originalError?: Error,
  ) {
    super(message)
    this.name = 'ParseError'
  }
}

/**
 * Schema validation error - thrown when schema validation fails
 */
export class SchemaValidationError extends Error {
  constructor(
    message: string,
    public errors: SchemaError[],
  ) {
    super(message)
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

// Compile schema validator once at module load time
let validator: ValidateFunction

try {
  const ajv = new Ajv({
    allErrors: true,
    verbose: true,
    strict: false, // Allow unknown keywords for compatibility
    addUsedSchema: false, // Don't add the schema to cache
    validateSchema: false, // Skip schema validation for now
  })
  addFormats(ajv)

  validator = ajv.compile(schema)
} catch (error) {
  throw new Error(`Failed to compile embedded ESM schema: ${error}`, { cause: error })
}

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
        message: `Unsupported major version ${version.major}; this validator supports major version ${CURRENT_VERSION.major}`,
        keyword: 'major_version_mismatch',
      },
    ]
  }

  const isValid = validator(data)
  if (isValid || !validator.errors) {
    return []
  }

  return validator.errors.map((error: ErrorObject): SchemaError => ({
    path: error.instancePath || ROOT_PATH,
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
  return v.major !== CURRENT_VERSION.major
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
      `Unsupported major version ${versionComponents.major}. This parser supports major version ${CURRENT_VERSION.major}.`,
    )
  }

  // Warn about newer minor versions
  if (versionComponents.minor > CURRENT_VERSION.minor) {
    const message =
      `${version} is newer than the current library version ${SCHEMA_VERSION}. ` +
      `Some features may not be supported.`
    if (onVersionWarning) {
      onVersionWarning(message)
    } else {
      console.warn(message)
    }
  }
}

/**
 * Options controlling how `load()` parses and represents an ESM file.
 */
export interface LoadOptions {
  /**
   * When `true`, numeric literals at Expression-bearing positions are
   * decoded to tagged `NumericLiteral` leaves (see
   * {@link losslessJsonParse}) so downstream consumers can preserve the
   * integer-vs-float distinction required by the canonical form
   * (discretization RFC §5.4.1 / §5.4.6). When `false` or absent
   * (default), numeric literals decode to plain JS numbers for
   * backwards compatibility.
   *
   * Canonical mode only takes effect for string inputs; pre-parsed
   * objects are returned as-is (callers that want tagged leaves should
   * run `losslessJsonParse` themselves before passing the object in).
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
}

/**
 * Load an ESM file from a JSON string or pre-parsed object
 *
 * @param input - JSON string or pre-parsed JavaScript object
 * @param options - Optional load-time settings (see {@link LoadOptions})
 * @returns Typed EsmFile object
 * @throws {ParseError} When JSON parsing fails or version is incompatible
 * @throws {SchemaValidationError} When schema validation fails
 */
export function load(input: string | object, options?: LoadOptions): EsmFile {
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
    data = input
    validationView = canonical ? stripNumericLiterals(input) : input
  }

  // Step 2: Version compatibility check (before schema validation)
  checkVersionCompatibility(validationView, options?.onVersionWarning)

  // Step 2a: v0.3.0 file-boundary rejection of removed v0.2.x extension
  // points (esm-spec §9 / closed function registry RFC). Mirrors the
  // Julia ref `parse.jl` rejection so cross-binding behavior is uniform.
  rejectRemovedV02Blocks(validationView)

  // Step 2b: v0.4.0 expression_templates / apply_expression_template are
  // rejected when the file declares esm < 0.4.0 (RFC §5.4 spec-version gate).
  // Surfaced with a stable diagnostic before schema validation so the user
  // sees the version hint instead of a generic "extra property" error.
  rejectExpressionTemplatesPreV04(validationView)

  // Step 2c: v0.8.0 §9.7 constructs (expression_template_imports, top-level
  // expression_templates, metaparameters) are rejected when the file
  // declares esm < 0.8.0 (esm-spec §9.6.5).
  rejectTemplateImportsPreV08(validationView)

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
  const basePath =
    options?.basePath ??
    (typeof process !== 'undefined' && typeof process.cwd === 'function' ? process.cwd() : '.')
  // esm-spec §9.7.10 forms A/B: fold any scope-directed injection — a
  // subsystem-ref edge's `injectedImports` (form A) or a coupling entry's
  // injection map (form B) — into the target components' own
  // `expression_template_imports` BEFORE resolution, so the ordinary import
  // resolver + §9.6.3 fixpoint lower the target under the chosen
  // discretization. `null` when no injection applies (the fast path).
  const injectedRoot = applyScopeInjections(data, options?.injectedImports ?? [])
  const machineryInput = injectedRoot ?? data
  const resolved = resolveTemplateMachinery(machineryInput, basePath, {
    metaparameters: options?.metaparameters,
    readFile: options?.readFile,
    validateSchema,
  })
  data = resolved ?? machineryInput
  // `lowerExpressionTemplates` returns a fresh tree (it deep-clones), so `data`
  // is already independent of the caller's input here; no separate defensive
  // copy is needed. (The former `coerceTypes` pass was a second, no-op identity
  // deep-copy that transformed nothing — it is removed and the value cast
  // directly.)
  const typedData = lowerExpressionTemplates(data as object) as EsmFile

  // Step 4: Lower `enum` ops to `const` integer nodes against the
  // file-local `enums` block (esm-spec §9.3). After this pass, the
  // codegen runner sees only `const` — `evaluateExpression()` rejects
  // any leftover `enum` op as an unlowered file.
  const loweredData = lowerEnums(typedData)

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

  return loweredData
}

/**
 * Reject the v0.2.x extension points that v0.3.0 closed (esm-spec §9 /
 * docs/rfcs/closed-function-registry.md):
 *
 *   - top-level `operators` block — replaced by AST equations + named
 *     `discretizations` schemes.
 *   - top-level `registered_functions` block — replaced by the closed
 *     `fn`-op registry (datetime + interp.searchsorted).
 *   - any expression-tree `call` op — replaced by `fn`.
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
        "top-level 'registered_functions' block was removed in ESM v0.3.0; migrate to the closed 'fn'-op registry (esm-spec §9.2).",
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
        "'call' AST op was removed in ESM v0.3.0; migrate to AST equations or the closed 'fn'-op registry (esm-spec §9.2).",
    })
  }

  if (errors.length > 0) {
    throw new SchemaValidationError(
      `ESM v0.3.0 rejects ${errors.length} removed v0.2.x construct(s)`,
      errors,
    )
  }
}
