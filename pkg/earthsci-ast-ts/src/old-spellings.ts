/**
 * esm 2.4.0 "one operator type": the spellings an earlier document wrote, read
 * as the 2.4.0 ones (esm-spec §9.6.12 "Old names (no refusal)", §4.2 "Reading
 * earlier documents"). Used at the load's wire boundary (`parse.ts`
 * `prepareDocumentOps`) and by `canonicalizeDocument`. Imports nothing that
 * reaches the loader, so any module may depend on it without an import cycle.
 */

import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { pointerToken } from './json-pointer.js'
import { deepClone } from './object-utils.js'

/**
 * Keys whose value is a map keyed by AUTHOR-CHOSEN names (variables, species,
 * loop symbols, template params, …). A map key is a declared name, not a
 * field, so it is never looked up in a field-keyed table (metaparameter
 * substitution, `template-imports.ts`), and a field spelling is never renamed
 * among its keys.
 */
export const NAME_KEYED_MAP_KEYS: ReadonlySet<string> = new Set<string>([
  'variables',
  'species',
  'parameters',
  'guesses',
  'subsystems',
  'operators',
  'ranges',
  'bindings',
  'config',
  'coords',
  'initial_conditions',
  'parameter_overrides',
  'pinned_coords',
  'map',
  'rename',
  'rebind',
  'index_set_rename',
  'url_substitutions',
  'where',
  // The old spelling of `operators` (read as it at the wire boundary).
  'expression_templates',
])

/**
 * One object spells both an old field name and its esm-2.4.0 spelling; the
 * loader reports it as `operator_invalid_definition`.
 */
export class OldSpellingConflict extends EsmDiagnosticError {
  constructor(message: string) {
    super(ERROR_CODES.OPERATOR_INVALID_DEFINITION, message)
    this.name = 'OldSpellingConflict'
  }
}

// ---------------------------------------------------------------------------
// esm 2.4.0 "one operator type": old spellings read at the wire boundary
// (esm-spec §9.6.12 "Old names (no refusal)", §4.2 "Reading earlier documents")
// ---------------------------------------------------------------------------

/** Old field spelling → new (warning `deprecated_field`). */
const DEPRECATED_FIELDS: readonly (readonly [string, string])[] = [
  ['expression_templates', 'operators'],
  ['expression_template_imports', 'operator_imports'],
]
/** The old op spelling of the reference node (warning `deprecated_op`). */
const OLD_APPLY_OP = 'apply_expression_template'
/** The other spellings of the spatial derivative (warning `deprecated_op`). */
const PARTIAL_SPELLINGS: ReadonlySet<string> = new Set(['δ', '∂'])

/**
 * Objects whose keys are author-chosen names, not fields: a field spelling is
 * never renamed among them (a variable may be called `expression_templates`).
 */
function oldSpellingNameMaps(): ReadonlySet<string> {
  return new Set<string>([
    ...NAME_KEYED_MAP_KEYS,
    'models',
    'reaction_systems',
    'data_sources',
    'index_sets',
    'enums',
    'metaparameters',
    'domains',
    'coupling_roles',
  ])
}

/** The sites {@link rewriteOldSpellings} rewrote: fields first, then ops. */
export interface OldSpellingSites {
  /** `<pointer-to-new-key> (<old>)`, one per renamed field. */
  fields: string[]
  /** `<pointer> (<old op>)`, one per rewritten node. */
  ops: string[]
}

/**
 * Rename `old` to `neu` among the keys of `node` in place, keeping key order.
 * Both spellings in one object are a load error (`operator_invalid_definition`).
 */
function renameFieldInPlace(node: Record<string, unknown>, old: string, neu: string): boolean {
  if (!Object.prototype.hasOwnProperty.call(node, old)) return false
  if (Object.prototype.hasOwnProperty.call(node, neu)) {
    throw new OldSpellingConflict(
      `an object carries both \`${old}\` and its esm-2.4.0 spelling \`${neu}\`; write only ` +
        `\`${neu}\` (esm-spec §9.6.12).`,
    )
  }
  const entries = Object.entries(node)
  for (const [k] of entries) delete node[k]
  for (const [k, v] of entries) node[k === old ? neu : k] = v
  return true
}

/**
 * The document's own renamed independent variable (`domain.independent_variable`
 * when declared and not `"t"`), or `null` (esm-spec §4.2 "The derivative axis").
 */
export function documentIndependentVariable(doc: unknown): string | null {
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return null
  const dom = (doc as Record<string, unknown>).domain
  if (dom === null || typeof dom !== 'object' || Array.isArray(dom)) return null
  const iv = (dom as Record<string, unknown>).independent_variable
  return typeof iv === 'string' && iv !== 't' ? iv : null
}

/**
 * esm 2.4.0 (esm-spec §9.6.12, §4.2): read the spellings an earlier document
 * wrote, IN PLACE, never refusing one:
 *
 * - the field `expression_templates` as `operators` and
 *   `expression_template_imports` as `operator_imports`, wherever a field of
 *   that name appears (never among the keys of a name-keyed map);
 * - the op `apply_expression_template` as `apply_operator`, and the spatial
 *   derivative — a `D` whose `wrt` is present and is not the literal `"t"`, and
 *   the spellings `δ` and `∂` — as `partial`, every other field kept. A `D`
 *   whose `wrt` is one of the enclosing definition's `params` is left as
 *   written: it is decided per definition instance (§9.6.4 rule 3).
 * - a `D` whose `wrt` names the document's own renamed independent variable
 *   (`domain.independent_variable`, not `"t"`) as the time derivative, `wrt`
 *   `"t"` (esm-spec §4.2 "The derivative axis"); no warning, not a site.
 *
 * Idempotent: a second pass finds nothing. Returns the sites, as the
 * `deprecated_field` / `deprecated_op` warnings name them.
 */
export function rewriteOldSpellings(doc: unknown): OldSpellingSites {
  const fields: string[] = []
  const ops: string[] = []
  const nameMaps = oldSpellingNameMaps()
  const iv = documentIndependentVariable(doc)
  const seen = new Set<object>()
  const isObj = (v: unknown): v is Record<string, unknown> =>
    v !== null && typeof v === 'object' && !Array.isArray(v)
  const walk = (
    node: unknown,
    at: string,
    namemap: boolean,
    params: ReadonlySet<string> | null,
  ): void => {
    if (Array.isArray(node)) {
      if (seen.has(node)) return
      seen.add(node)
      for (let i = 0; i < node.length; i++) walk(node[i], `${at}/${i}`, false, params)
      return
    }
    if (!isObj(node)) return
    if (seen.has(node)) return
    seen.add(node)
    if (!namemap) {
      for (const [old, neu] of DEPRECATED_FIELDS) {
        if (renameFieldInPlace(node, old, neu)) fields.push(`${at}/${pointerToken(neu)} (${old})`)
      }
      const op = node.op
      if (typeof op === 'string') {
        if (op === OLD_APPLY_OP) {
          node.op = 'apply_operator'
          ops.push(`${at} (${op})`)
        } else if (PARTIAL_SPELLINGS.has(op)) {
          node.op = 'partial'
          ops.push(`${at} (${op})`)
        } else if (op === 'D') {
          const w = node.wrt
          if (iv !== null && w === iv && !(params !== null && params.has(w))) {
            // esm-spec §4.2 "The derivative axis": a `wrt` naming the
            // document's renamed independent variable is the time derivative,
            // read with the literal axis (no warning).
            node.wrt = 't'
          } else if (
            w !== undefined &&
            w !== null &&
            w !== 't' &&
            !(typeof w === 'string' && params !== null && params.has(w))
          ) {
            node.op = 'partial'
            ops.push(`${at} (D)`)
          }
        }
      }
    }
    for (const k of Object.keys(node)) {
      const v = node[k]
      if (v === null || typeof v !== 'object') continue
      if (!namemap && k === 'operators' && isObj(v)) {
        // A definition block: each entry's own params decide a `D` whose `wrt`
        // names one of them.
        if (seen.has(v)) continue
        seen.add(v)
        for (const [dn, dv] of Object.entries(v)) {
          if (dv === null || typeof dv !== 'object') continue
          const p = isObj(dv) ? dv.params : undefined
          const P = Array.isArray(p)
            ? new Set(p.filter((x): x is string => typeof x === 'string'))
            : null
          walk(dv, `${at}/operators/${pointerToken(dn)}`, false, P)
        }
        continue
      }
      walk(v, `${at}/${pointerToken(k)}`, !namemap && nameMaps.has(k), params)
    }
  }
  walk(doc, '', false, null)
  return { fields, ops }
}

/** The load-time `deprecated_field` warning naming the renamed fields `sites`. */
export function deprecatedFieldWarning(sites: readonly string[]): string {
  return (
    `${ERROR_CODES.DEPRECATED_FIELD}: the fields \`expression_templates\` and ` +
    '`expression_template_imports` are read as `operators` and `operator_imports` ' +
    `(esm 2.4.0, esm-spec §9.6.12). Read at: ${sites.join(', ')}.`
  )
}

/** The load-time `deprecated_op` warning naming the old reference / derivative spellings `sites`. */
export function deprecatedOperatorSpellingWarning(sites: readonly string[]): string {
  return (
    `${ERROR_CODES.DEPRECATED_OP}: \`apply_expression_template\` is read as \`apply_operator\`, ` +
    'and a spatial `D` (and `δ`, `∂`) as `partial` (esm 2.4.0, esm-spec §4.2, §9.6.12). ' +
    `Rewritten at: ${sites.join(', ')}.`
  )
}

/**
 * Whether `x` spells anything an earlier document wrote (esm-spec §9.6.12,
 * §4.2): an old field name, the old reference op, `δ` / `∂`, or a `D` whose
 * `wrt` is present and is not `"t"`. A cheap pre-check for entry points a
 * caller may reach without the load's wire boundary.
 */
export function hasOldSpellings(x: unknown): boolean {
  const seen = new Set<object>()
  const go = (n: unknown): boolean => {
    if (n === null || typeof n !== 'object') return false
    if (seen.has(n)) return false
    seen.add(n)
    if (Array.isArray(n)) return n.some(go)
    const o = n as Record<string, unknown>
    if ('expression_templates' in o || 'expression_template_imports' in o) return true
    const op = o.op
    if (typeof op === 'string') {
      if (op === OLD_APPLY_OP || PARTIAL_SPELLINGS.has(op)) return true
      if (op === 'D' && o.wrt !== undefined && o.wrt !== null && o.wrt !== 't') return true
    }
    return Object.values(o).some(go)
  }
  return go(x)
}

/**
 * `raw` itself when it spells nothing an earlier document wrote, else a copy
 * read through {@link rewriteOldSpellings} (silently). For entry points a
 * caller may reach without the load's wire boundary
 * (`lowerExpressionTemplates`, `resolveTemplateMachinery`).
 */
export function wireOldSpellings<T>(raw: T): T {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return raw
  if (!hasOldSpellings(raw)) return raw
  const doc = deepClone(raw)
  rewriteOldSpellings(doc)
  return doc
}
