/**
 * ESM Format JSON Serialization (esm-cs3).
 *
 * `save(file)` emits an `EsmFile` as wire-form JSON suitable for round-trip
 * through `load()`. Mirrors the Python and Julia serializers in three respects:
 *
 *   1. **AST canonical numeric handling.** `NumericLiteral` tagged leaves
 *      (the in-memory int/float carrier produced by `losslessJsonParse` and
 *      `intLit` / `floatLit`) are emitted as bare JSON numbers. In default
 *      mode they collapse to plain `number` tokens via `JSON.stringify`. In
 *      `canonical: true` mode they emit per RFC §5.4.6: integer-tagged
 *      leaves as integer tokens, float-tagged leaves with the trailing
 *      `.0` discriminator preserved.
 *
 *   2. **Drop transient flags.** The Symbol-keyed
 *      `[NUMERIC_LITERAL_TAG]` brand on tagged literals is non-enumerable
 *      string-key-wise, so `JSON.stringify` already skips it; this module
 *      strips the user-visible `kind` / `value` fields too so the wire
 *      form contains only bare JSON numbers, never the in-memory
 *      `{kind,value}` carrier.
 *
 *   3. **Wire-form keys.** TypeScript types are generated from the JSON
 *      schema, so the in-memory shape already matches the wire form (no
 *      Python-style dataclass → wire field-name remapping is needed).
 *      Object key order is the insertion order produced by `load()` /
 *      authored constructors, which is itself schema-driven.
 *
 * The Python reference at `packages/earthsci_toolkit/src/earthsci_toolkit/serialize.py`
 * is 1172 LoC because it carries dataclass → wire field-name mappings the
 * TypeScript binding does not need. The TS implementation stays compact by
 * delegating shape preservation to the generated types.
 */

import type { EsmFile } from './types.js'
import {
  isNumericLiteral,
  formatNumericLiteral,
  CanonicalNonfiniteError,
} from './numeric-literal.js'

/** Optional behavior controls for {@link save}. */
export interface SaveOptions {
  /**
   * When `true`, emit byte-canonical JSON per RFC §5.4.6: integer-tagged
   * `NumericLiteral` leaves as integer tokens, float-tagged leaves with
   * the trailing `.0` discriminator preserved (e.g. `1.0` stays `1.0`
   * rather than collapsing to `1`). Plain JS `number` values keep
   * `JSON.stringify` semantics in either mode.
   *
   * Default: `false` (structural round-trip; integer-valued floats may
   * collapse to JSON integers).
   */
  canonical?: boolean

  /**
   * Indentation passed through to the underlying JSON formatter.
   * Default `2` to match the Python and Julia reference serializers.
   * Set to `0` for a single-line emission.
   */
  indent?: number
}

/**
 * Serialize an `EsmFile` to wire-form JSON.
 *
 * @param file - The `EsmFile` to serialize.
 * @param options - Optional behavior controls (see {@link SaveOptions}).
 * @returns Wire-form JSON string.
 * @throws {CanonicalNonfiniteError} In `canonical: true` mode, if a
 *   `NumericLiteral` leaf holds NaN or ±Infinity (RFC §5.4.6 forbids
 *   non-finite numbers in the canonical wire form).
 */
export function save(file: EsmFile, options?: SaveOptions): string {
  const indent = options?.indent ?? 2
  if (options?.canonical === true) {
    return emitCanonical(file, indent)
  }
  const stripped = stripNumericLiterals(file)
  return JSON.stringify(stripped, null, indent)
}

/**
 * Recursively replace `NumericLiteral` leaves with their plain-number
 * value. Returns a new tree; input is not mutated. Non-literal objects
 * and arrays are shallow-copied only when a descendant is rewritten so
 * unrelated subtrees stay reference-identical with the input.
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
 * Canonical-mode emitter. Walks the tree directly, emitting tokens per
 * RFC §5.4.6 for `NumericLiteral` leaves and falling back to
 * `JSON.stringify` semantics for everything else.
 *
 * The walk produces JSON token-by-token rather than handing off to
 * `JSON.stringify(replacer)`: a replacer cannot distinguish `intLit(1)`
 * from `floatLit(1)` at emit time without losing the integer/float
 * branding the canonical form depends on.
 */
function emitCanonical(value: unknown, indent: number): string {
  return emitValue(value, indent, '', '')
}

function emitValue(
  v: unknown,
  indent: number,
  curIndent: string,
  path: string,
): string {
  if (v === null || v === undefined) return 'null'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  if (typeof v === 'string') return JSON.stringify(v)
  if (isNumericLiteral(v)) {
    return formatNumericLiteral(v, path || '$')
  }
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) {
      throw new CanonicalNonfiniteError(v, path || '$')
    }
    return JSON.stringify(v)
  }
  if (Array.isArray(v)) {
    if (v.length === 0) return '[]'
    const childIndent = indent === 0 ? '' : curIndent + ' '.repeat(indent)
    const sep = indent === 0 ? ',' : ',\n' + childIndent
    const open = indent === 0 ? '[' : '[\n' + childIndent
    const close = indent === 0 ? ']' : '\n' + curIndent + ']'
    const parts = v.map((x, i) =>
      emitValue(x, indent, childIndent, `${path}[${i}]`),
    )
    return open + parts.join(sep) + close
  }
  if (typeof v === 'object') {
    const obj = v as Record<string, unknown>
    const entries: string[] = []
    const childIndent = indent === 0 ? '' : curIndent + ' '.repeat(indent)
    const colon = indent === 0 ? ':' : ': '
    for (const key of Object.keys(obj)) {
      const child = obj[key]
      if (child === undefined) continue
      const childJson = emitValue(child, indent, childIndent, `${path}.${key}`)
      entries.push(`${JSON.stringify(key)}${colon}${childJson}`)
    }
    if (entries.length === 0) return '{}'
    const sep = indent === 0 ? ',' : ',\n' + childIndent
    const open = indent === 0 ? '{' : '{\n' + childIndent
    const close = indent === 0 ? '}' : '\n' + curIndent + '}'
    return open + entries.join(sep) + close
  }
  throw new TypeError(`Cannot serialize ${typeof v} at ${path || '$'}`)
}
