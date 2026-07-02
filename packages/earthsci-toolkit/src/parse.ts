/**
 * ESM Format JSON Parsing
 *
 * Provides functionality to load and validate ESM files from JSON strings or objects.
 * Separates concerns: JSON parsing → schema validation → type coercion.
 */

import Ajv, { ErrorObject, ValidateFunction } from 'ajv'
import addFormats from 'ajv-formats'
import type { EsmFile, Expression, CouplingEntry } from './types.js'
import { validateUnits } from './units.js'
import { isNumericLiteral, losslessJsonParse } from './numeric-literal.js'
import { lowerEnums } from './lower_enums.js'
import {
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
} from './lower_expression_templates.js'
import {
  rejectTemplateImportsPreV08,
  resolveTemplateMachinery,
} from './template_imports.js'
import { schema } from './embedded-schema.js'

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
  constructor(message: string, public originalError?: Error) {
    super(message)
    this.name = 'ParseError'
  }
}

/**
 * Schema validation error - thrown when schema validation fails
 */
export class SchemaValidationError extends Error {
  constructor(message: string, public errors: SchemaError[]) {
    super(message)
    this.name = 'SchemaValidationError'
  }
}

// The ESM schema is embedded via a GENERATED module so it cannot hand-drift
// from the canonical esm-schema.json. See scripts/generate-embedded-schema.mjs
// and the schema-sync guard in scripts/sync-schema.sh.

// Compile schema validator once at module load time
let validator: ValidateFunction

try {
  const ajv = new Ajv({
    allErrors: true,
    verbose: true,
    strict: false, // Allow unknown keywords for compatibility
    addUsedSchema: false, // Don't add the schema to cache
    validateSchema: false // Skip schema validation for now
  })
  addFormats(ajv)

  validator = ajv.compile(schema)
} catch (error) {
  throw new Error(`Failed to compile embedded ESM schema: ${error}`)
}

/**
 * Validate data against the ESM schema
 */
export function validateSchema(data: unknown): SchemaError[] {
  // Reject unsupported major versions before AJV validation.
  if (typeof data === 'object' && data !== null) {
    const esm = (data as Record<string, unknown>).esm
    if (typeof esm === 'string') {
      const v = parseSemanticVersion(esm)
      if (v !== null && v.major !== 0) {
        return [{
          path: '/esm',
          message: `Unsupported major version ${v.major}; this validator supports major version 0`,
          keyword: 'major_version_mismatch'
        }]
      }
    }
  }

  const isValid = validator(data)
  if (isValid || !validator.errors) {
    return []
  }

  return validator.errors.map((error: ErrorObject): SchemaError => ({
    path: error.instancePath || '/',
    message: error.message || 'Unknown validation error',
    keyword: error.keyword
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
      error instanceof Error ? error : undefined
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
 * Recursively replace `NumericLiteral` leaves with their plain-number
 * value. Used to produce a plain view of a lossless-parsed document
 * for Ajv schema validation (the schema declares `type: number`, which
 * does not match tagged objects).
 *
 * Returns a new tree; input is not mutated. Non-literal objects and
 * arrays are shallow-copied only when a descendant is rewritten.
 */
function stripNumericLiterals(value: unknown): unknown {
  if (isNumericLiteral(value)) return value.value
  if (Array.isArray(value)) {
    let changed = false
    const out: unknown[] = new Array(value.length)
    for (let i = 0; i < value.length; i++) {
      const v = stripNumericLiterals(value[i])
      if (v !== value[i]) changed = true
      out[i] = v
    }
    return changed ? out : value
  }
  if (value && typeof value === 'object') {
    const src = value as Record<string, unknown>
    let changed = false
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(src)) {
      const v = stripNumericLiterals(src[key])
      if (v !== src[key]) changed = true
      out[key] = v
    }
    return changed ? out : value
  }
  return value
}

/**
 * Coerce types for better TypeScript compatibility
 * Handles Expression union types and discriminated unions
 */
function coerceTypes(data: any): any {
  if (data === null || data === undefined) {
    return data
  }

  // Canonical-mode tagged leaves are opaque — never descend into them.
  if (isNumericLiteral(data)) {
    return data
  }

  if (Array.isArray(data)) {
    return data.map(coerceTypes)
  }

  if (typeof data === 'object') {
    const result: any = {}

    for (const [key, value] of Object.entries(data)) {
      // Handle Expression types - they can be number, string, or ExpressionNode
      // ExpressionNode has 'op' and 'args' properties
      if (key === 'expression' || key === 'args' || /expr/i.test(key)) {
        result[key] = coerceExpression(value)
      } else {
        result[key] = coerceTypes(value)
      }
    }

    return result
  }

  return data
}

/**
 * Coerce Expression union type (number | string | ExpressionNode).
 * `NumericLiteral` tagged leaves (canonical-mode only) pass through
 * unchanged.
 */
function coerceExpression(value: any): Expression {
  if (typeof value === 'number' || typeof value === 'string') {
    return value
  }

  // NumericLiteral — canonical-mode tagged leaf; pass through.
  if (isNumericLiteral(value)) {
    return value as unknown as Expression
  }

  // If it's an object with 'op' and 'args', treat as ExpressionNode
  if (value && typeof value === 'object' && 'op' in value && 'args' in value) {
    return {
      ...value,
      args: Array.isArray(value.args) ? value.args.map(coerceExpression) : value.args
    }
  }

  return value
}

/**
 * Parse a semantic version string and return its components
 */
function parseSemanticVersion(versionString: string): { major: number; minor: number; patch: number } | null {
  const match = versionString.match(/^(\d+)\.(\d+)\.(\d+)$/)
  if (!match) {
    return null
  }

  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10)
  }
}

/**
 * Check version compatibility for an ESM file
 */
function checkVersionCompatibility(data: any): void {
  if (typeof data !== 'object' || data === null) {
    return // Let schema validation handle this
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return // Let schema validation handle this
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    return // Let schema validation handle invalid version format
  }

  const { major } = versionComponents
  const CURRENT_MAJOR = 0 // Current supported major version

  // Reject unsupported major versions
  if (major !== CURRENT_MAJOR) {
    throw new ParseError(`Unsupported major version ${major}. This parser supports major version ${CURRENT_MAJOR}.`)
  }
}

/**
 * Version-aware schema validation that handles backward/forward compatibility
 */
function validateSchemaWithVersionCompatibility(data: any): SchemaError[] {
  if (typeof data !== 'object' || data === null) {
    return validateSchema(data)
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return validateSchema(data)
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    // If version parsing fails, use normal validation
    return validateSchema(data)
  }

  const { major, minor, patch } = versionComponents
  const CURRENT_VERSION = { major: 0, minor: 1, patch: 0 }

  // If it's the exact current version, use normal validation
  if (major === CURRENT_VERSION.major && minor === CURRENT_VERSION.minor && patch === CURRENT_VERSION.patch) {
    return validateSchema(data)
  }

  // Same major version: attempt backward/forward compatibility
  if (major === CURRENT_VERSION.major) {
    // Forward compatibility: newer minor version
    if (minor > CURRENT_VERSION.minor) {
      console.warn(`Forward compatibility: Version ${version} is newer than current ${CURRENT_VERSION.major}.${CURRENT_VERSION.minor}.${CURRENT_VERSION.patch}. Some features may not be fully supported.`)

      // Validate with current version substituted to check structural validity
      const tempData = { ...data, esm: '0.1.0' }
      const errors = validateSchema(tempData)

      // Filter out additionalProperties errors (unknown fields from newer versions)
      return errors.filter(error => {
        if (error.keyword === 'additionalProperties') {
          console.warn(`Forward compatibility: Ignoring unknown field at ${error.path}`)
          return false
        }
        return true
      })
    }

    // Backward compatibility or different patch: validate with current version substituted
    const tempData = { ...data, esm: '0.1.0' }
    return validateSchema(tempData)
  }

  // This shouldn't happen due to checkVersionCompatibility, but fallback to normal validation
  return validateSchema(data)
}

/**
 * Remove unknown fields for forward compatibility
 */
function removeUnknownFields(data: any): any {
  if (typeof data !== 'object' || data === null) {
    return data
  }

  const version = data.esm
  if (typeof version !== 'string') {
    return data
  }

  const versionComponents = parseSemanticVersion(version)
  if (versionComponents === null) {
    return data
  }

  const { major, minor } = versionComponents
  const CURRENT_VERSION = { major: 0, minor: 1, patch: 0 }

  // Only clean up for forward compatible versions (newer minor versions in the same major)
  if (major === CURRENT_VERSION.major && minor > CURRENT_VERSION.minor) {
    // Create a copy of the data and remove fields that would cause schema validation errors
    const cleanedData = { ...data }

    // Remove known forward compatibility fields that aren't in the current schema
    const unknownRootFields = ['performance_hints', 'validation_metadata', 'extended_metadata']
    unknownRootFields.forEach(field => {
      if (field in cleanedData) {
        delete cleanedData[field]
      }
    })

    // Recursively clean model and reaction system objects
    if (cleanedData.models) {
      cleanedData.models = cleanModels(cleanedData.models)
    }
    if (cleanedData.reaction_systems) {
      cleanedData.reaction_systems = cleanReactionSystems(cleanedData.reaction_systems)
    }

    return cleanedData
  }

  return data
}

/**
 * Clean unknown fields from models
 */
function cleanModels(models: any): any {
  if (typeof models !== 'object' || models === null) {
    return models
  }

  const cleaned: any = {}
  for (const [key, model] of Object.entries(models)) {
    if (typeof model === 'object' && model !== null) {
      const cleanedModel: any = { ...model }
      // Remove known forward compatibility fields
      const unknownModelFields = ['solver_hints', 'optimization_flags']
      unknownModelFields.forEach(field => {
        if (field in cleanedModel) {
          delete cleanedModel[field]
        }
      })
      cleaned[key] = cleanedModel
    } else {
      cleaned[key] = model
    }
  }
  return cleaned
}

/**
 * Clean unknown fields from reaction systems
 */
function cleanReactionSystems(reactionSystems: any): any {
  if (typeof reactionSystems !== 'object' || reactionSystems === null) {
    return reactionSystems
  }

  const cleaned: any = {}
  for (const [key, system] of Object.entries(reactionSystems)) {
    if (typeof system === 'object' && system !== null) {
      const cleanedSystem: any = { ...system }

      // Clean reactions array
      if (Array.isArray(cleanedSystem.reactions)) {
        cleanedSystem.reactions = cleanedSystem.reactions.map((reaction: any) => {
          if (typeof reaction === 'object' && reaction !== null) {
            const cleanedReaction: any = { ...reaction }
            // Remove known forward compatibility fields from reactions
            const unknownReactionFields = ['kinetics_metadata', 'thermodynamic_data']
            unknownReactionFields.forEach(field => {
              if (field in cleanedReaction) {
                delete cleanedReaction[field]
              }
            })
            return cleanedReaction
          }
          return reaction
        })
      }

      cleaned[key] = cleanedSystem
    } else {
      cleaned[key] = system
    }
  }
  return cleaned
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
  checkVersionCompatibility(validationView)

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

  // Step 3: Schema validation with version compatibility
  const schemaErrors = validateSchemaWithVersionCompatibility(validationView)
  if (schemaErrors.length > 0) {
    throw new SchemaValidationError(
      `Schema validation failed with ${schemaErrors.length} error(s)`,
      schemaErrors
    )
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
  const resolved = resolveTemplateMachinery(data, basePath, {
    metaparameters: options?.metaparameters,
    readFile: options?.readFile,
    validateSchema,
  })
  if (resolved !== null) data = resolved
  data = lowerExpressionTemplates(data as object)

  // Step 4: Clean up unknown fields for forward compatibility and type coercion
  const cleanedData = removeUnknownFields(data)
  const typedData = coerceTypes(cleanedData) as EsmFile

  // Step 4b: Lower `enum` ops to `const` integer nodes against the
  // file-local `enums` block (esm-spec §9.3). After this pass, the
  // codegen runner sees only `const` — `evaluateExpression()` rejects
  // any leftover `enum` op as an unlowered file.
  const loweredData = lowerEnums(typedData)

  // Step 5: Dimensional analysis — emit warnings but never fail the load.
  // Mirrors the Julia @warn behavior so TS callers get the same signal
  // without an API break.
  for (const warning of validateUnits(loweredData)) {
    const location = warning.location ? ` [${warning.location}]` : ''
    console.warn(`ESM unit validation${location}: ${warning.message}`)
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
      message: "top-level 'operators' block was removed in ESM v0.3.0; migrate to AST equations + 'discretizations' (closed-function-registry RFC §6).",
    })
  }
  if ('registered_functions' in root) {
    errors.push({
      path: '/registered_functions',
      keyword: 'removed_in_v0_3',
      message: "top-level 'registered_functions' block was removed in ESM v0.3.0; migrate to the closed 'fn'-op registry (esm-spec §9.2).",
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
      message: "'call' AST op was removed in ESM v0.3.0; migrate to AST equations or the closed 'fn'-op registry (esm-spec §9.2).",
    })
  }

  if (errors.length > 0) {
    throw new SchemaValidationError(
      `ESM v0.3.0 rejects ${errors.length} removed v0.2.x construct(s)`,
      errors,
    )
  }
}