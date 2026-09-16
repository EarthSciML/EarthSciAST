/**
 * Static checks on every inline test (esm-spec §6.6), decidable from the document
 * alone and so owed by every binding, executing or not:
 *
 * - an assertion `variable` that is a bare name (element suffix removed) the
 *   asserting component does not declare is `undefined_variable` (§6.6.3); a
 *   dotted target names a declaration elsewhere and is resolved by the runtime;
 * - an `initial_conditions` / `parameter_overrides` key that matches no declared
 *   name under the §6.6.2 rules is `unknown_override_key`; skipped when the
 *   document still holds an unresolved `{ref}` mount a key could name into;
 * - an assertion whose form does not match the declared rank of its target is
 *   `assertion_rank_mismatch` (§6.6.5).
 */

import { ERROR_CODES } from '../errors.js'
import type { EsmFile } from '../types.js'
import type { StructuralError } from './types.js'

type JsonObject = Record<string, unknown>
type Section = 'models' | 'reaction_systems'

const SECTIONS: readonly Section[] = ['models', 'reaction_systems']
const ELEMENT_SUFFIX = /^(.*?)\[[^\]]*\]$/

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function entries(value: unknown): [string, unknown][] {
  return isObject(value) ? Object.entries(value) : []
}

/** `u[1]` -> `['u', true]`; a name without an element suffix is unchanged. */
function stripElementSuffix(name: string): [string, boolean] {
  const m = ELEMENT_SUFFIX.exec(name)
  return m ? [m[1], true] : [name, false]
}

/** Escape one JSON Pointer reference token (RFC 6901). */
function pointerToken(key: string): string {
  return key.replace(/~/g, '~0').replace(/\//g, '~1')
}

/**
 * The names an assertion may target by a bare name, mapped to the declared
 * `shape` (empty when absent): a model's `variables`, or a reaction system's
 * `species` (which carry no shape) and `parameters`.
 */
function targetDeclarations(component: JsonObject, section: Section): Map<string, string[]> {
  const shapeOf = (decl: unknown): string[] =>
    isObject(decl) && Array.isArray(decl.shape) ? (decl.shape as string[]) : []
  const out = new Map<string, string[]>()
  if (section === 'models') {
    for (const [name, decl] of entries(component.variables)) out.set(name, shapeOf(decl))
  } else {
    for (const [name] of entries(component.species)) out.set(name, [])
    for (const [name, decl] of entries(component.parameters)) out.set(name, shapeOf(decl))
  }
  return out
}

interface DeclaredNames {
  names: Set<string>
  namespaces: Set<string>
  complete: boolean
}

/**
 * The document's declared names qualified as a flatten qualifies them
 * (`<component>.<name>`, `<component>.<subsystem>.<name>` at any depth), the
 * component and subsystem names §6.6.2 rule 2 validates a key's leading segments
 * against, and whether every mount is resolved.
 */
function declaredOverrideNames(esmFile: EsmFile): DeclaredNames {
  const out: DeclaredNames = { names: new Set(), namespaces: new Set(), complete: true }
  const walk = (prefix: string, component: unknown, section: Section): void => {
    if (!isObject(component) || 'ref' in component) {
      out.complete = false
      return
    }
    out.namespaces.add(prefix.slice(prefix.lastIndexOf('.') + 1))
    for (const name of targetDeclarations(component, section).keys()) {
      out.names.add(`${prefix}.${name}`)
    }
    for (const [subName, sub] of entries(component.subsystems)) {
      walk(`${prefix}.${subName}`, sub, section)
    }
  }
  const doc = esmFile as unknown as JsonObject
  for (const section of SECTIONS) {
    for (const [name, component] of entries(doc[section])) walk(name, component, section)
  }
  return out
}

/**
 * Whether `key` reaches a declared name under §6.6.2 rules 1-3: an exact hit; a
 * dotted suffix of the key that is a name, every dropped leading segment naming a
 * component or subsystem; or the key a dotted suffix of some name. Ambiguity is a
 * runtime diagnostic, so one match suffices.
 */
function overrideKeyMatches(key: string, declared: DeclaredNames): boolean {
  if (declared.names.has(key)) return true
  const parts = key.split('.')
  for (let i = 1; i < parts.length; i++) {
    if (
      declared.names.has(parts.slice(i).join('.')) &&
      parts.slice(0, i).every((p) => declared.namespaces.has(p))
    ) {
      return true
    }
  }
  const tail = `.${key}`
  for (const name of declared.names) if (name.endsWith(tail)) return true
  return false
}

export function validateInlineTests(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredNames = declaredOverrideNames(esmFile)
  const doc = esmFile as unknown as JsonObject
  for (const section of SECTIONS) {
    for (const [componentName, component] of entries(doc[section])) {
      if (!isObject(component) || 'ref' in component) continue
      const declared = targetDeclarations(component, section)
      const tests = Array.isArray(component.tests) ? component.tests : []
      tests.forEach((test: unknown, ti: number) => {
        if (!isObject(test)) return
        const base = `/${section}/${componentName}/tests/${ti}`
        if (declaredNames.complete) {
          for (const field of ['initial_conditions', 'parameter_overrides']) {
            for (const [key] of entries(test[field])) {
              const [bareKey] = stripElementSuffix(key)
              if (!overrideKeyMatches(bareKey, declaredNames)) {
                errors.push({
                  path: `${base}/${field}/${pointerToken(key)}`,
                  code: ERROR_CODES.UNKNOWN_OVERRIDE_KEY,
                  message: `Override key "${key}" in ${field} matches no declared name`,
                  details: { key, field },
                })
              }
            }
          }
        }
        const assertions = Array.isArray(test.assertions) ? test.assertions : []
        assertions.forEach((assertion: unknown, ai: number) => {
          if (!isObject(assertion) || typeof assertion.variable !== 'string') return
          const [bare, isElement] = stripElementSuffix(assertion.variable)
          if (bare.includes('.')) return
          const pointer = `${base}/assertions/${ai}`
          const shape = declared.get(bare)
          if (shape === undefined) {
            errors.push({
              path: `${pointer}/variable`,
              code: ERROR_CODES.UNDEFINED_VARIABLE,
              message: `Variable "${bare}" referenced in assertion variable but not declared`,
              details: { variable: bare },
            })
            return
          }
          if (isElement) return
          const selects =
            (assertion.coords !== undefined && assertion.coords !== null) ||
            (assertion.reduce !== undefined && assertion.reduce !== null)
          if (shape.length > 0 && !selects) {
            errors.push({
              path: pointer,
              code: ERROR_CODES.ASSERTION_RANK_MISMATCH,
              message: `Assertion on shaped variable "${bare}" selects no scalar (give coords, reduce, or an element name)`,
              details: { variable: bare, shape },
            })
          } else if (shape.length === 0 && selects) {
            errors.push({
              path: pointer,
              code: ERROR_CODES.ASSERTION_RANK_MISMATCH,
              message: `Assertion on scalar variable "${bare}" carries coords or reduce`,
              details: { variable: bare, shape: [] },
            })
          }
        })
      })
    }
  }
  return errors
}
