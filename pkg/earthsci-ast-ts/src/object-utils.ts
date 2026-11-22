/**
 * Shared object/tree helpers used by the walkers, template lowering, and import
 * resolvers. Both functions were previously copy-pasted across
 * `template-imports.ts` and `lower-expression-templates.ts`; this is their
 * single home so they cannot drift.
 */

import { isNumericLiteral } from './numeric-literal.js'

/**
 * Narrow to a plain JSON object (`Record<string, unknown>`).
 *
 * By the walker convention a tagged `NumericLiteral` is an OPAQUE LEAF, not a
 * traversable container, so this guard EXCLUDES `NumericLiteral` (as well as
 * `null` and arrays). Consumers that recurse into "objects" therefore never
 * descend into a literal's `{kind, value}` shape and treat it as a scalar.
 */
export function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v) && !isNumericLiteral(v)
}

/**
 * Structural deep clone that PRESERVES tagged `NumericLiteral` leaves by
 * reference (they are frozen and immutable, so sharing them is safe and keeps
 * the int/float distinction intact). Arrays and plain objects are copied;
 * `null`/`undefined` and primitives pass through unchanged. Non-JSON values
 * (functions, Maps, class instances) are not handled — this is a JSON-tree
 * clone, matching the identical helpers it replaces.
 */
export function deepClone<T>(v: T): T {
  if (v === null || v === undefined) return v
  if (isNumericLiteral(v)) return v // preserve symbol-tagged literals as-is
  if (Array.isArray(v)) return v.map(deepClone) as unknown as T
  if (typeof v === 'object') {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(v as object))
      setOwn(out, k, deepClone((v as Record<string, unknown>)[k]))
    return out as unknown as T
  }
  return v
}

/**
 * Set `obj[key] = value` as an own, enumerable property, as `JSON.parse` does.
 * A plain assignment would turn a key named `__proto__` (a legal name in a
 * name-keyed map, e.g. a variable) into the object's prototype.
 */
export function setOwn(obj: Record<string, unknown>, key: string, value: unknown): void {
  Object.defineProperty(obj, key, { value, writable: true, enumerable: true, configurable: true })
}
