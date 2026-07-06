/**
 * Tagged numeric-literal AST nodes and lossless JSON I/O per
 * discretization RFC §5.4.1 (int/float distinction) and §5.4.6
 * (on-wire number formatting).
 *
 * JS has a single IEEE-754 `number` type, so `JSON.parse("1")` and
 * `JSON.parse("1.0")` both yield `1`. To preserve the RFC-mandated
 * integer-vs-float AST-node distinction, this module provides:
 *
 *   - `NumericLiteral` — a tagged `{kind, value}` leaf that records
 *     whether the on-wire token was a JSON-integer or a JSON-float.
 *   - `losslessJsonParse` — a minimal JSON parser that emits
 *     `NumericLiteral` at every numeric-token position. Token shape
 *     (presence of `.`, `e`, `E`) determines kind per the RFC §5.4.6
 *     round-trip parse rule.
 *   - `losslessJsonStringify` — inverse: `NumericLiteral{kind:int}`
 *     → JSON integer; `NumericLiteral{kind:float}` → RFC §5.4.6 float
 *     with the trailing-`.0` override for integer-valued magnitudes
 *     in `[−(1e21 − 1), 1e21 − 1]`.
 *   - `intLit`, `floatLit`, `isNumericLiteral`, `isIntLit`, `isFloatLit`,
 *     `numericValue` — ergonomic helpers so existing consumers of the
 *     `number | string | ExpressionNode` union can accept
 *     `NumericLiteral` with minimal churn.
 *
 * NaN and ±Infinity are rejected on serialize with
 * `E_CANONICAL_NONFINITE` per RFC §5.4.6.
 */

export interface NumericLiteral {
  readonly kind: 'int' | 'float'
  readonly value: number
}

const NUMERIC_LITERAL_TAG = Symbol.for('earthsci-toolkit.NumericLiteral')

interface TaggedNumericLiteral extends NumericLiteral {
  readonly [NUMERIC_LITERAL_TAG]: true
}

export function intLit(value: number): NumericLiteral {
  if (!Number.isInteger(value)) {
    throw new TypeError(`intLit requires an integer-valued number; got ${value}`)
  }
  if (!Number.isFinite(value)) {
    throw new TypeError(`intLit requires a finite number; got ${value}`)
  }
  return makeTagged('int', value)
}

export function floatLit(value: number): NumericLiteral {
  return makeTagged('float', value)
}

function makeTagged(kind: 'int' | 'float', value: number): TaggedNumericLiteral {
  return Object.freeze({
    kind,
    value,
    [NUMERIC_LITERAL_TAG]: true as const,
  })
}

export function isNumericLiteral(x: unknown): x is NumericLiteral {
  return (
    typeof x === 'object' &&
    x !== null &&
    (x as { [NUMERIC_LITERAL_TAG]?: unknown })[NUMERIC_LITERAL_TAG] === true
  )
}

export function isIntLit(x: unknown): x is NumericLiteral & { kind: 'int' } {
  return isNumericLiteral(x) && x.kind === 'int'
}

export function isFloatLit(x: unknown): x is NumericLiteral & { kind: 'float' } {
  return isNumericLiteral(x) && x.kind === 'float'
}

/**
 * Return the underlying numeric value of a plain `number` or a
 * `NumericLiteral`. Returns `undefined` for anything else. Use this
 * at the boundary between kind-aware and kind-agnostic code.
 */
export function numericValue(x: unknown): number | undefined {
  if (typeof x === 'number') return x
  if (isNumericLiteral(x)) return x.value
  return undefined
}

// ---------------------------------------------------------------------------
// Lossless JSON parser
// ---------------------------------------------------------------------------

export class LosslessJsonParseError extends Error {
  constructor(message: string, public readonly position: number) {
    super(`${message} (at pos ${position})`)
    this.name = 'LosslessJsonParseError'
  }
}

/**
 * Parse a JSON document, preserving the integer-vs-float distinction
 * of every numeric token per RFC §5.4.6: a token containing `.`, `e`,
 * or `E` becomes `NumericLiteral{kind:'float'}`; otherwise it becomes
 * `NumericLiteral{kind:'int'}`. All other JSON values (strings, bools,
 * null, arrays, objects) decode to their native JS equivalents.
 *
 * Integer-grammar tokens outside the safe-integer range fall back to
 * `float` kind to avoid silent precision loss, matching the Go
 * binding's `normalizeJSONNumber` behavior.
 */
export function losslessJsonParse(text: string): unknown {
  const parser = new Parser(text)
  parser.skipWhitespace()
  const value = parser.parseValue()
  parser.skipWhitespace()
  if (parser.pos !== text.length) {
    throw new LosslessJsonParseError('Unexpected trailing content', parser.pos)
  }
  return value
}

class Parser {
  pos = 0
  constructor(private readonly src: string) {}

  peek(): string {
    return this.src[this.pos] ?? ''
  }

  skipWhitespace(): void {
    while (this.pos < this.src.length) {
      const c = this.src.charCodeAt(this.pos)
      if (c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d) {
        this.pos++
      } else {
        break
      }
    }
  }

  parseValue(): unknown {
    this.skipWhitespace()
    const c = this.peek()
    if (c === '{') return this.parseObject()
    if (c === '[') return this.parseArray()
    if (c === '"') return this.parseString()
    if (c === 't' || c === 'f') return this.parseBool()
    if (c === 'n') return this.parseNull()
    if (c === '-' || (c >= '0' && c <= '9')) return this.parseNumber()
    throw new LosslessJsonParseError(`Unexpected character ${JSON.stringify(c)}`, this.pos)
  }

  parseObject(): Record<string, unknown> {
    this.expect('{')
    const result: Record<string, unknown> = {}
    this.skipWhitespace()
    if (this.peek() === '}') {
      this.pos++
      return result
    }
    for (;;) {
      this.skipWhitespace()
      if (this.peek() !== '"') {
        throw new LosslessJsonParseError('Expected string key', this.pos)
      }
      const key = this.parseString()
      this.skipWhitespace()
      this.expect(':')
      const value = this.parseValue()
      result[key] = value
      this.skipWhitespace()
      const next = this.peek()
      if (next === ',') {
        this.pos++
        continue
      }
      if (next === '}') {
        this.pos++
        return result
      }
      throw new LosslessJsonParseError(`Expected , or } in object`, this.pos)
    }
  }

  parseArray(): unknown[] {
    this.expect('[')
    const result: unknown[] = []
    this.skipWhitespace()
    if (this.peek() === ']') {
      this.pos++
      return result
    }
    for (;;) {
      result.push(this.parseValue())
      this.skipWhitespace()
      const next = this.peek()
      if (next === ',') {
        this.pos++
        continue
      }
      if (next === ']') {
        this.pos++
        return result
      }
      throw new LosslessJsonParseError(`Expected , or ] in array`, this.pos)
    }
  }

  parseString(): string {
    this.expect('"')
    let out = ''
    while (this.pos < this.src.length) {
      const c = this.src[this.pos]
      if (c === '"') {
        this.pos++
        return out
      }
      if (c === '\\') {
        this.pos++
        const esc = this.src[this.pos++]
        switch (esc) {
          case '"': out += '"'; break
          case '\\': out += '\\'; break
          case '/': out += '/'; break
          case 'b': out += '\b'; break
          case 'f': out += '\f'; break
          case 'n': out += '\n'; break
          case 'r': out += '\r'; break
          case 't': out += '\t'; break
          case 'u': {
            const hex = this.src.slice(this.pos, this.pos + 4)
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
              throw new LosslessJsonParseError('Invalid \\u escape', this.pos)
            }
            out += String.fromCharCode(parseInt(hex, 16))
            this.pos += 4
            break
          }
          default:
            throw new LosslessJsonParseError(`Invalid escape \\${esc}`, this.pos - 1)
        }
      } else {
        out += c
        this.pos++
      }
    }
    throw new LosslessJsonParseError('Unterminated string', this.pos)
  }

  parseBool(): boolean {
    if (this.src.startsWith('true', this.pos)) {
      this.pos += 4
      return true
    }
    if (this.src.startsWith('false', this.pos)) {
      this.pos += 5
      return false
    }
    throw new LosslessJsonParseError('Invalid literal', this.pos)
  }

  parseNull(): null {
    if (this.src.startsWith('null', this.pos)) {
      this.pos += 4
      return null
    }
    throw new LosslessJsonParseError('Invalid literal', this.pos)
  }

  parseNumber(): NumericLiteral {
    const start = this.pos
    if (this.peek() === '-') this.pos++
    while (this.pos < this.src.length && this.src[this.pos] >= '0' && this.src[this.pos] <= '9') {
      this.pos++
    }
    let isFloat = false
    if (this.peek() === '.') {
      isFloat = true
      this.pos++
      while (this.pos < this.src.length && this.src[this.pos] >= '0' && this.src[this.pos] <= '9') {
        this.pos++
      }
    }
    if (this.peek() === 'e' || this.peek() === 'E') {
      isFloat = true
      this.pos++
      if (this.peek() === '+' || this.peek() === '-') this.pos++
      while (this.pos < this.src.length && this.src[this.pos] >= '0' && this.src[this.pos] <= '9') {
        this.pos++
      }
    }
    const token = this.src.slice(start, this.pos)
    if (token === '' || token === '-') {
      throw new LosslessJsonParseError('Invalid number', start)
    }
    const value = Number(token)
    if (Number.isNaN(value)) {
      throw new LosslessJsonParseError(`Invalid number ${JSON.stringify(token)}`, start)
    }
    if (isFloat) return makeTagged('float', value)
    // JSON-integer grammar. Fall back to float if outside safe-integer
    // range to avoid silent precision loss.
    if (Number.isSafeInteger(value)) return makeTagged('int', value)
    return makeTagged('float', value)
  }

  expect(ch: string): void {
    if (this.src[this.pos] !== ch) {
      throw new LosslessJsonParseError(`Expected ${JSON.stringify(ch)}`, this.pos)
    }
    this.pos++
  }
}

// ---------------------------------------------------------------------------
// Lossless JSON stringifier
// ---------------------------------------------------------------------------

export class CanonicalNonfiniteError extends Error {
  code = 'E_CANONICAL_NONFINITE' as const
  constructor(public readonly value: number, public readonly path: string) {
    super(`Canonical form forbids non-finite number ${value} at ${path}`)
    this.name = 'CanonicalNonfiniteError'
  }
}

/**
 * Stringify a value to JSON, emitting `NumericLiteral` leaves per RFC
 * §5.4.6:
 *
 *   - `kind: 'int'`  → JSON-integer token (no `.`, no `e`).
 *   - `kind: 'float'` with integer-valued magnitude in
 *     `[−(1e21 − 1), 1e21 − 1]` → `ToString(Number)` with trailing
 *     `.0` appended so the token cannot be confused with an integer
 *     on parse-back (e.g. `1.0`, `-3.0`, `0.0`).
 *   - `kind: 'float'` otherwise → native `ToString(Number)` (which is
 *     already distinguishable via `.` or `e`).
 *   - `-0.0` float → `-0.0`.
 *   - NaN or ±Infinity → throws `CanonicalNonfiniteError`.
 *
 * Plain JS `number` values are serialized with `JSON.stringify`'s
 * default rules (no trailing `.0` override); callers that want
 * canonical emission must tag literals via `intLit` / `floatLit`.
 */
export function losslessJsonStringify(value: unknown): string {
  return stringifyValue(value, '$')
}

function stringifyValue(v: unknown, path: string): string {
  if (v === null) return 'null'
  if (v === undefined) return 'null'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  if (typeof v === 'string') return JSON.stringify(v)
  if (isNumericLiteral(v)) return formatNumericLiteral(v, path)
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new CanonicalNonfiniteError(v, path)
    return JSON.stringify(v)
  }
  if (Array.isArray(v)) {
    const parts = v.map((x, i) => stringifyValue(x, `${path}[${i}]`))
    return `[${parts.join(',')}]`
  }
  if (typeof v === 'object') {
    const obj = v as Record<string, unknown>
    const parts: string[] = []
    for (const key of Object.keys(obj)) {
      const child = obj[key]
      if (child === undefined) continue
      parts.push(`${JSON.stringify(key)}:${stringifyValue(child, `${path}.${key}`)}`)
    }
    return `{${parts.join(',')}}`
  }
  throw new TypeError(`Cannot stringify ${typeof v} at ${path}`)
}

/**
 * Emit an integer-tagged token per RFC §5.4.6. Shared by the document
 * serializer (`save`), `losslessJsonStringify`, and `canonicalJson` so the
 * integer-token guards live in exactly one place.
 */
export function formatIntToken(value: number, path: string): string {
  if (!Number.isFinite(value)) throw new CanonicalNonfiniteError(value, path)
  if (!Number.isInteger(value)) {
    throw new TypeError(`int NumericLiteral holds non-integer value ${value} at ${path}`)
  }
  if (Object.is(value, -0)) {
    // Integer nodes cannot hold negative zero (RFC §5.4.6).
    throw new TypeError(`int NumericLiteral cannot hold -0 at ${path}`)
  }
  // Emit as plain decimal — JS toString on finite integers in the
  // safe-integer range produces the JSON-integer grammar already.
  // For out-of-safe-range floats that ended up tagged int, we still
  // defensively drop any exponent.
  const s = String(value)
  if (s.includes('.') || s.includes('e') || s.includes('E')) {
    throw new TypeError(`int NumericLiteral produced non-integer token ${s} at ${path}`)
  }
  return s
}

/**
 * Emit a `NumericLiteral` leaf as its RFC §5.4.6 token: an integer token for
 * int-tagged leaves, `formatFloatToken` for float-tagged ones.
 */
export function formatNumericLiteral(lit: NumericLiteral, path: string): string {
  const { kind, value } = lit
  if (kind === 'int') return formatIntToken(value, path)
  if (!Number.isFinite(value)) throw new CanonicalNonfiniteError(value, path)
  return formatFloatToken(value)
}

/**
 * Emit a float token via ECMAScript `ToString(Number)` with a trailing
 * `.0` override when the result is an integer-valued plain-decimal token.
 *
 * This is the document-serialization float emitter used by
 * {@link losslessJsonStringify} and `save()`. It is NOT the strict RFC
 * §5.4.6 canonical-form emitter — that is `formatCanonicalFloat` in
 * `canonicalize.ts`, which additionally normalizes exponent notation
 * (strips the leading `+`, forces exponent thresholds).
 */
export function formatFloatToken(value: number): string {
  if (!Number.isFinite(value)) {
    throw new CanonicalNonfiniteError(value, '$')
  }
  if (Object.is(value, -0)) return '-0.0'
  const s = String(value)
  if (s.includes('.') || s.includes('e') || s.includes('E')) return s
  // Integer-valued float in plain-decimal range — add trailing `.0`.
  return `${s}.0`
}
