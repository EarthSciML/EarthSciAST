/**
 * esm 2.5.0: the deprecated `initialization_equations` block, read at the
 * load's wire boundary (esm-spec §11.4.4), and the load-time check of an `ic`
 * argument (esm-spec §4.2, the `ic` row).
 *
 * For every model (top-level, and inline subsystems at any depth) that carries
 * `initialization_equations`, the field is removed and:
 *
 * - a model with a time derivative (an equation whose left-hand side contains
 *   a `D`) gets each equation appended to `equations`, with every reference to
 *   an unknown `w` replaced by `ic(w)` and every `D(w)` by `ic(D(w))`;
 * - a model with none gets each `v ~ e`, `v` a bare unknown, as
 *   `guesses[v] = e` (an existing entry is kept); any other equation is
 *   refused with `deprecated_field`.
 *
 * Mirrors the Julia, Rust and Python loaders. Imports nothing that reaches
 * the loader.
 */

import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { pointerToken } from './json-pointer.js'
import { setOwn } from './object-utils.js'

type Obj = Record<string, unknown>

const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v)

/** A load-time refusal of the migration or of an `ic` argument. */
export class InitializationMigrationError extends EsmDiagnosticError {
  constructor(code: string, message: string) {
    super(code, message)
    this.name = 'InitializationMigrationError'
  }
}

/** Whether `e` (an expression) contains a `D` node. */
function mentionsD(e: unknown): boolean {
  if (Array.isArray(e)) return e.some(mentionsD)
  if (!isObj(e)) return false
  if (e.op === 'D') return true
  return mentionsD(e.args) || mentionsD(e.expr)
}

/** A model's own `equations` include one whose left-hand side has a `D`. */
function hasTimeDerivative(model: Obj): boolean {
  const eqs = model.equations
  return Array.isArray(eqs) && eqs.some((eq) => isObj(eq) && mentionsD(eq.lhs))
}

function isUnknownVariable(v: unknown): boolean {
  return isObj(v) && v.type === 'unknown'
}

/** Resolve a dotted name, segment by segment, from a model or reaction system. */
function resolvesToUnknown(container: unknown, parts: readonly string[]): boolean {
  if (!isObj(container) || parts.length === 0) return false
  if (parts.length === 1) {
    const vars = container.variables
    if (isObj(vars) && isUnknownVariable(vars[parts[0]!])) return true
    const species = container.species
    return isObj(species) && Object.prototype.hasOwnProperty.call(species, parts[0]!)
  }
  const subs = container.subsystems
  return isObj(subs) && resolvesToUnknown(subs[parts[0]!], parts.slice(1))
}

/** Whether `name`, read in `model`, names an unknown (local, or scoped). */
function namesUnknown(doc: Obj, model: Obj, name: string): boolean {
  const parts = name.split('.')
  if (resolvesToUnknown(model, parts)) return true
  if (parts.length < 2) return false
  for (const key of ['models', 'reaction_systems']) {
    const top = doc[key]
    if (isObj(top) && resolvesToUnknown(top[parts[0]!], parts.slice(1))) return true
  }
  return false
}

const icOf = (arg: unknown): Obj => ({ op: 'ic', args: [arg] })

/** `e` with every unknown `w` replaced by `ic(w)` and every `D(w)` by `ic(D(w))`. */
function rewriteUnknowns(e: unknown, isUnknown: (n: string) => boolean): unknown {
  if (typeof e === 'string') return isUnknown(e) ? icOf(e) : e
  if (Array.isArray(e)) return e.map((x) => rewriteUnknowns(x, isUnknown))
  if (!isObj(e) || typeof e.op !== 'string') return e
  if (
    e.op === 'D' &&
    Array.isArray(e.args) &&
    typeof e.args[0] === 'string' &&
    isUnknown(e.args[0])
  ) {
    return icOf(e)
  }
  const out: Obj = {}
  for (const [k, v] of Object.entries(e)) {
    const rewrites = k === 'args' || k === 'expr' || k === 'filter' || k === 'values'
    setOwn(out, k, rewrites ? rewriteUnknowns(v, isUnknown) : v)
  }
  return out
}

function migrateModel(doc: Obj, model: Obj, at: string, sites: string[]): void {
  if (Object.prototype.hasOwnProperty.call(model, 'initialization_equations')) {
    const init = model.initialization_equations
    delete model.initialization_equations
    const eqs = Array.isArray(init) ? init : []
    if (eqs.length > 0) {
      sites.push(`${at}/initialization_equations (initialization_equations)`)
      if (hasTimeDerivative(model)) {
        const isUnknown = (n: string): boolean => namesUnknown(doc, model, n)
        const out = Array.isArray(model.equations) ? model.equations : []
        for (const eq of eqs) {
          if (!isObj(eq)) continue
          const moved: Obj = {}
          for (const [k, v] of Object.entries(eq)) {
            setOwn(moved, k, k === 'lhs' || k === 'rhs' ? rewriteUnknowns(v, isUnknown) : v)
          }
          out.push(moved)
        }
        model.equations = out
      } else {
        const vars = isObj(model.variables) ? model.variables : {}
        const guesses: Obj = isObj(model.guesses) ? model.guesses : {}
        eqs.forEach((eq, i) => {
          const lhs = isObj(eq) ? eq.lhs : undefined
          if (typeof lhs !== 'string' || !isUnknownVariable(vars[lhs])) {
            throw new InitializationMigrationError(
              ERROR_CODES.DEPRECATED_FIELD,
              `${ERROR_CODES.DEPRECATED_FIELD}: ${at}/initialization_equations/${i}: the model has ` +
                'no time derivative, so its initialization equations are read as `guesses` ' +
                '(esm 2.5.0, esm-spec §11.4.4), and this one has no left-hand side that is a ' +
                'bare unknown. Write a `guesses` entry instead.',
            )
          }
          if (!Object.prototype.hasOwnProperty.call(guesses, lhs))
            setOwn(guesses, lhs, (eq as Obj).rhs)
        })
        model.guesses = guesses
      }
    }
  }
  const subs = model.subsystems
  if (isObj(subs)) {
    for (const [k, sub] of Object.entries(subs)) {
      if (isObj(sub)) migrateModel(doc, sub, `${at}/subsystems/${pointerToken(k)}`, sites)
    }
  }
}

/**
 * Rewrite every model's `initialization_equations` IN PLACE (esm-spec
 * §11.4.4). Returns the sites, as the `deprecated_field` warning names them.
 * Idempotent: a second pass finds nothing.
 */
export function migrateInitializationEquations(doc: unknown): string[] {
  const sites: string[] = []
  if (!isObj(doc) || !isObj(doc.models)) return sites
  for (const [k, model] of Object.entries(doc.models)) {
    if (isObj(model)) migrateModel(doc, model, `/models/${pointerToken(k)}`, sites)
  }
  return sites
}

/** The load-time `deprecated_field` warning naming the migrated blocks `sites`. */
export function deprecatedInitializationEquationsWarning(sites: readonly string[]): string {
  return (
    `${ERROR_CODES.DEPRECATED_FIELD}: \`initialization_equations\` is deprecated (esm 2.5.0, ` +
    'esm-spec §11.4.4); each equation was rewritten into an `ic` equation in `equations` ' +
    '(or into `guesses` for a model with no time derivative). ' +
    `Read at: ${sites.join(', ')}.`
  )
}

/**
 * Refuse an `ic` whose argument is neither a variable reference nor `D` of
 * one (esm-spec §4.2): an element is `index(ic(u), i)`, never
 * `ic(index(u, i))`.
 */
export function checkIcArguments(doc: unknown): void {
  const seen = new Set<object>()
  const walk = (n: unknown, at: string): void => {
    if (n === null || typeof n !== 'object' || seen.has(n)) return
    seen.add(n)
    if (Array.isArray(n)) {
      n.forEach((x, i) => walk(x, `${at}/${i}`))
      return
    }
    const o = n as Obj
    if (o.op === 'ic') {
      const args = o.args
      const a = Array.isArray(args) && args.length === 1 ? args[0] : undefined
      const ok =
        typeof a === 'string' ||
        (isObj(a) &&
          a.op === 'D' &&
          Array.isArray(a.args) &&
          a.args.length === 1 &&
          typeof a.args[0] === 'string')
      if (!ok) {
        throw new InitializationMigrationError(
          ERROR_CODES.PARSE_ERROR,
          `${at}: the argument of \`ic\` must be a variable reference or \`D\` of one ` +
            '(esm-spec §4.2); an element of an array unknown is written `index(ic(u), i)`, ' +
            'not `ic(index(u, i))`.',
        )
      }
    }
    for (const [k, v] of Object.entries(o)) walk(v, `${at}/${pointerToken(k)}`)
  }
  walk(doc, '')
}
