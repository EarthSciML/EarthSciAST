/**
 * ESM Format JSON Serialization (esm-cs3).
 *
 * `toJson(file)` emits an `EsmFile` as wire-form JSON suitable for round-trip
 * through `loadString()`. Mirrors the Python and Julia serializers in three respects:
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
 *      Object key order is the insertion order produced by `loadString()` /
 *      authored constructors, which is itself schema-driven.
 *
 * The Python reference at `pkg/earthsci-ast-py/src/earthsci_ast/serialize.py`
 * is 1172 LoC because it carries dataclass → wire field-name mappings the
 * TypeScript binding does not need. The TS implementation stays compact by
 * delegating shape preservation to the generated types.
 */

import { writeFileSyncNode } from './path-utils.js'
import type { EsmFile } from './types.js'
import {
  isNumericLiteral,
  formatNumericLiteral,
  CanonicalNonfiniteError,
  stripNumericLiterals,
} from './numeric-literal.js'

/** Optional behavior controls for {@link toJson} / {@link writePath}. */
export interface ToJsonOptions {
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
 * Serialize an `EsmFile` to wire-form JSON. PURE — it never touches disk;
 * {@link writePath} is the writer.
 *
 * @param file - The `EsmFile` to serialize.
 * @param options - Optional behavior controls (see {@link ToJsonOptions}).
 * @returns Wire-form JSON string.
 * @throws {CanonicalNonfiniteError} In `canonical: true` mode, if a
 *   `NumericLiteral` leaf holds NaN or ±Infinity (RFC §5.4.6 forbids
 *   non-finite numbers in the canonical wire form).
 */
export function toJson(file: EsmFile, options?: ToJsonOptions): string {
  const indent = options?.indent ?? 2
  const view = withoutNonSchemaFields(file)
  if (options?.canonical === true) {
    return emitCanonical(view, indent)
  }
  const stripped = stripNumericLiterals(view)
  return JSON.stringify(stripped, null, indent)
}

/**
 * The NON-SCHEMA, loader-populated fields an `EsmFile` may carry that must
 * never reach the wire. Currently just `componentTemplates` (see
 * `EsmFile.componentTemplates` in `types.ts`): it is a load-time snapshot of
 * the per-component `expression_templates` blocks kept for flatten's merged
 * registry, not a document field, and emitting it would break the
 * load → `toJson` → load round trip against `esm-schema.json`.
 */
const NON_SCHEMA_FIELDS = ['componentTemplates'] as const

/**
 * A shallow view of `file` with every {@link NON_SCHEMA_FIELDS} key removed.
 * Returns `file` itself (no copy, so key order is untouched) when it carries
 * none of them — the overwhelmingly common case.
 */
function withoutNonSchemaFields(file: EsmFile): EsmFile {
  if (!NON_SCHEMA_FIELDS.some((k) => k in file)) return file
  const out: Record<string, unknown> = { ...(file as Record<string, unknown>) }
  for (const k of NON_SCHEMA_FIELDS) delete out[k]
  return out as EsmFile
}

/**
 * {@link toJson} with no indentation — the single-line wire form. Present in
 * every binding, because Rust and Go have no default arguments and so cannot
 * express `toJson(file, { indent: 0 })`.
 */
export function toJsonCompact(file: EsmFile, options?: ToJsonOptions): string {
  return toJson(file, { ...options, indent: 0 })
}

/**
 * Write an `EsmFile` to `path` as wire-form JSON. Returns nothing: no
 * function in this API both writes and hands back the payload — call
 * {@link toJson} when you want the string.
 *
 * Requires synchronous file access (Node).
 */
export function writePath(file: EsmFile, path: string, options?: ToJsonOptions): void {
  writeFileSyncNode(path, toJson(file, options))
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

function emitValue(v: unknown, indent: number, curIndent: string, path: string): string {
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
    const parts = v.map((x, i) => emitValue(x, indent, childIndent, `${path}[${i}]`))
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
