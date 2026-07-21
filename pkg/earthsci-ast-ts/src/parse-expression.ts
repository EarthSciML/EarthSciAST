/**
 * parse-expression — the INVERSE of `toAscii` (pretty-print.ts) for authoring
 * EarthSciAST expressions (esm-spec §4.2) as text.
 *
 * The concrete syntax IS what `toAscii` emits, so the pair round-trips:
 * `toAscii(parseExpression(s)) === s`. Precedence is sourced from
 * {@link opPrecedence} (op-registry.ts) so the parser can never drift from the
 * printer. This parser RECONSTRUCTS existing AST node shapes; it never invents
 * new ones, and it requires no change to `toAscii`.
 *
 * Coverage:
 *  - scalar tier: arithmetic, powers, comparisons, boolean logic, elementary
 *    functions, derivatives (`D(x)/Dt` and `D(x, t)`), open/user function calls;
 *  - array & call-shaped tier: array literals `[…]` (`const`), indexing
 *    `a[i, j]` (`index`), dotted closed-function calls `datetime.year(t)` (`fn`),
 *    the `true` literal, and `integral` / `reshape` / `transpose` / `concat`.
 *
 * Still deferred (need dedicated surface syntax — a later pass): `aggregate`,
 * `argmin`, `argmax`, `makearray`, `table_lookup`, `apply_expression_template`,
 * and the geometry ops. Those are refused with an {@link ExpressionParseError}.
 *
 * Design rules: multiplication is ALWAYS explicit (`k * A`) — no implicit
 * juxtaposition, because identifiers are multi-letter (`NO2`, `O3`, `k_photo`).
 * Two known non-exactnesses trace to `toAscii`, not the parser: float
 * serialization (`formatNumber` routes through a JS double), and unary-minus
 * operands being under-parenthesized (`-(a+b)` and `(-a)+b` both print
 * `-a + b`) — the parser matches the printer's loose convention. Because the
 * printer is not injective, `parseExpression(toAscii(ast))` is a faithful
 * SEMANTIC round-trip but may normalize structure (flat vs. nested `+`; a scalar
 * `const`/`fn` with a non-dotted name reprints identically to a plain
 * number/op). Editors should treat text as a derived view and re-parse only
 * dirtied expressions.
 */

import type { Expr, ExprNode, Equation } from './types.js'
import { isExprNode } from './expression.js'
import { opPrecedence } from './op-registry.js'

/** Thrown when an expression string cannot be parsed. */
export class ExpressionParseError extends Error {
  constructor(
    message: string,
    /** 0-based character offset into the source where parsing failed. */
    public pos: number,
  ) {
    super(message)
    this.name = 'ExpressionParseError'
  }
}

// --- operator tables ---------------------------------------------------------

/**
 * Binary infix operators the parser recognizes. Each one's precedence comes
 * from {@link opPrecedence} at parse time, so it tracks op-registry.ts; only the
 * token set and associativity live here. `^` is the sole right-associative
 * operator (mirrors pretty-print's NON_ASSOCIATIVE_RIGHT_OPS handling).
 */
const INFIX: readonly string[] = [
  'or',
  'and',
  '==',
  '!=',
  '<',
  '>',
  '<=',
  '>=',
  '+',
  '-',
  '*',
  '/',
  '^',
]
const RIGHT_ASSOC = new Set<string>(['^'])

// Prefix operand minimum-precedences, sourced from the registry:
//  - unary `-` binds LOOSELY (registry precedence of `-`, = additive), so it
//    swallows a whole additive/multiplicative operand, matching how the printer
//    renders `-(Ea/(R*T))` as `-Ea / (R * T)` with no inner parens.
//  - `not` binds TIGHTLY at its registry precedence (`not p and q` = `(not p) and q`).
const UMINUS_MIN = opPrecedence('-')
const NOT_MIN = opPrecedence('not')

/**
 * Structural ops whose defining data lives OUTSIDE `args` AND which have no
 * text surface yet — refused, pending a dedicated syntax pass. (`integral`,
 * `reshape`, `transpose`, `concat`, `fn`, `const`, `index`, `true` DO have a
 * surface and are reconstructed below; they are intentionally absent here.)
 */
const STRUCTURAL_OPS = new Set<string>([
  'aggregate',
  'argmin',
  'argmax',
  'makearray',
  'table_lookup',
  'apply_expression_template',
  'broadcast',
  'enum',
  'intersect_polygon',
  'polygon_intersection_area',
])

// --- tokenizer ---------------------------------------------------------------

type Tok =
  | { k: 'num'; v: number; pos: number }
  | { k: 'name'; v: string; pos: number }
  | { k: 'op'; v: string; pos: number }
  | { k: '('; pos: number }
  | { k: ')'; pos: number }
  | { k: '['; pos: number }
  | { k: ']'; pos: number }
  | { k: ','; pos: number }
  | { k: 'eq'; pos: number } // a lone `=`, the equation separator (NOT `==`)
  | { k: 'eof'; pos: number }

// Longest-match-first so `>=`/`<=`/`==`/`!=` beat `>`/`<`/`=`.
const MULTI_OPS = ['>=', '<=', '==', '!=']
const SINGLE_OPS = new Set(['+', '-', '*', '/', '^', '>', '<'])
const NUM_RE = /^(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/
// Identifiers allow Unicode letters (Greek variables like `ΔF_net`, `Φ`),
// Unicode numbers (subscript/superscript digits in names like `k₀`, `M₁`), and
// dots (qualified refs like `Emissions.NO`, and dotted closed-function names
// like `datetime.year`, which makeCall turns into `fn` nodes). A leading digit
// still can't start an identifier (numbers lex first).
const NAME_RE = /^[_\p{L}][\w.\p{L}\p{N}]*/u
const WORD_OPS = new Set(['and', 'or', 'not'])

function tokenize(src: string): Tok[] {
  const toks: Tok[] = []
  let i = 0
  while (i < src.length) {
    const c = src[i]
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      i++
      continue
    }
    if (c === '(') {
      toks.push({ k: '(', pos: i++ })
      continue
    }
    if (c === ')') {
      toks.push({ k: ')', pos: i++ })
      continue
    }
    if (c === '[') {
      toks.push({ k: '[', pos: i++ })
      continue
    }
    if (c === ']') {
      toks.push({ k: ']', pos: i++ })
      continue
    }
    if (c === ',') {
      toks.push({ k: ',', pos: i++ })
      continue
    }
    const two = src.slice(i, i + 2)
    if (MULTI_OPS.includes(two)) {
      toks.push({ k: 'op', v: two, pos: i })
      i += 2
      continue
    }
    if (c === '=') {
      // lone '=' (the '==' case was handled just above)
      toks.push({ k: 'eq', pos: i++ })
      continue
    }
    if (SINGLE_OPS.has(c)) {
      toks.push({ k: 'op', v: c, pos: i++ })
      continue
    }
    const rest = src.slice(i)
    const num = NUM_RE.exec(rest)
    if (num && (c === '.' || (c >= '0' && c <= '9'))) {
      toks.push({ k: 'num', v: Number(num[0]), pos: i })
      i += num[0].length
      continue
    }
    const name = NAME_RE.exec(rest)
    if (name) {
      const v = name[0]
      toks.push(WORD_OPS.has(v) ? { k: 'op', v, pos: i } : { k: 'name', v, pos: i })
      i += v.length
      continue
    }
    // Remaining structural notation — the `where {…}` of aggregate, and the
    // big-operator / unicode forms (∑ ∫ ∂ …) — has no text surface yet; refuse
    // it uniformly so a caller can route it to a dedicated pass.
    if ('{}'.includes(c) || c.charCodeAt(0) > 127) {
      throw new ExpressionParseError(
        `structural operator syntax (${JSON.stringify(c)}) — not yet expressible in the text form`,
        i,
      )
    }
    throw new ExpressionParseError(`Unexpected character ${JSON.stringify(c)}`, i)
  }
  toks.push({ k: 'eof', pos: src.length })
  return toks
}

// --- parser (Pratt / precedence-climbing) ------------------------------------

class Parser {
  private p = 0
  constructor(private readonly toks: Tok[]) {}

  private peek(k = 0): Tok {
    return this.toks[Math.min(this.p + k, this.toks.length - 1)]
  }
  private next(): Tok {
    return this.toks[this.p++]
  }
  private expect(k: Tok['k'], what: string): void {
    if (this.peek().k !== k) this.fail(`Expected ${what}`)
    this.next()
  }
  private fail(msg: string, tok: Tok = this.peek()): never {
    throw new ExpressionParseError(msg, tok.pos)
  }

  parseEntry(): Expr {
    const e = this.parseExpr(0)
    if (this.peek().k !== 'eof') this.fail('Unexpected trailing input')
    return flatten(e)
  }

  private parseExpr(minPrec: number): Expr {
    let left = this.parsePrefix()
    for (;;) {
      const t = this.peek()
      if (t.k !== 'op' || !INFIX.includes(t.v)) break
      const prec = opPrecedence(t.v)
      if (prec < minPrec) break
      this.next()
      const rhs = this.parseExpr(RIGHT_ASSOC.has(t.v) ? prec : prec + 1)
      left = { op: t.v, args: [left, rhs] }
    }
    return left
  }

  private parsePrefix(): Expr {
    const t = this.peek()
    // `-` directly before a number is a NEGATIVE LITERAL, not a unary-minus
    // node. Both print as `-1.3`, but only a literal reprints WITHOUT parens as
    // an operand (`x^-1.3`, not `x^(-1.3)`) — matching how `toAscii` emits
    // negative constants (e.g. Arrhenius `(300/T)^-1.3`).
    if (t.k === 'op' && t.v === '-' && this.peek(1).k === 'num') {
      this.next()
      const num = this.next() as Extract<Tok, { k: 'num' }>
      return -num.v
    }
    if (t.k === 'op' && (t.v === '-' || t.v === 'not')) {
      this.next()
      const operand = this.parseExpr(t.v === 'not' ? NOT_MIN : UMINUS_MIN)
      return { op: t.v, args: [operand] }
    }
    return this.parsePostfix()
  }

  /** Atom, then postfix `[…]` indexing, then the derivative sugar `D(expr)/D<name>`. */
  private parsePostfix(): Expr {
    let node = this.parseAtom()
    while (this.peek().k === '[') {
      this.next() // '['
      const idx: Expr[] = [this.parseExpr(0)]
      while (this.peek().k === ',') {
        this.next()
        idx.push(this.parseExpr(0))
      }
      this.expect(']', "']'")
      node = { op: 'index', args: [node, ...idx] }
    }
    const slash = this.peek()
    if (isExprNode(node) && node.op === 'D' && slash.k === 'op' && slash.v === '/') {
      const nameTok = this.peek(1)
      if (nameTok.k === 'name' && nameTok.v.length > 1 && nameTok.v[0] === 'D') {
        this.next() // '/'
        this.next() // 'D<var>'
        return { op: 'D', wrt: nameTok.v.slice(1), args: node.args }
      }
    }
    return node
  }

  private parseAtom(): Expr {
    const t = this.next()
    if (t.k === 'num') return t.v
    if (t.k === '(') {
      const e = this.parseExpr(0)
      this.expect(')', "')'")
      return e
    }
    // A leading `[` is a const array literal (`[1, 2, 3]`, `[[1, 2], [3, 4]]`).
    if (t.k === '[') return { op: 'const', value: this.parseArrayRest(), args: [] }
    if (t.k === 'name') {
      if (t.v === 'true') return { op: 'true', args: [] }
      if (this.peek().k === '(') return this.parseCall(t.v)
      return t.v // bare variable / species / qualified reference
    }
    return this.fail("Expected a number, name, '(', or '['", t)
  }

  /** Parse the elements of an array literal after `[` up to and including `]`. */
  private parseArrayRest(): unknown[] {
    const els: unknown[] = []
    if (this.peek().k !== ']') {
      for (;;) {
        if (this.peek().k === '[') {
          this.next()
          els.push(this.parseArrayRest()) // nested raw array
        } else {
          els.push(this.parseExpr(0)) // number / name / expression element
        }
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    this.expect(']', "']'")
    return els
  }

  private parseCall(name: string): Expr {
    this.next() // '('
    const args: Expr[] = []
    const named: Record<string, Expr> = {}
    if (this.peek().k !== ')') {
      for (;;) {
        // A `key = value` argument (e.g. concat `axis=0`); a lone `=` (not `==`)
        // after a bare name marks it.
        if (this.peek().k === 'name' && this.peek(1).k === 'eq') {
          const key = (this.next() as Extract<Tok, { k: 'name' }>).v
          this.next() // '='
          named[key] = this.parseExpr(0)
        } else {
          args.push(this.parseExpr(0))
        }
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    this.expect(')', `',' or ')' in call to ${name}(...)`)
    return makeCall(name, args, named, this.peek().pos)
  }
}

/** Extract the raw element list of a parsed `const` array literal, or fail. */
function asArrayLiteral(e: Expr, pos: number): unknown[] {
  if (isExprNode(e) && e.op === 'const') {
    const value = (e as Record<string, unknown>).value
    if (Array.isArray(value)) return value
  }
  throw new ExpressionParseError('expected an array literal [ ... ]', pos)
}

function noNamed(named: Record<string, Expr>, name: string, pos: number): void {
  const keys = Object.keys(named)
  if (keys.length) throw new ExpressionParseError(`unexpected ${keys[0]}=… in ${name}(...)`, pos)
}

function makeCall(name: string, args: Expr[], named: Record<string, Expr>, pos: number): Expr {
  // A dotted callee is a closed function — an `fn` node carrying the name.
  if (name.includes('.')) {
    noNamed(named, name, pos)
    return { op: 'fn', name, args }
  }
  // Call-shaped structural ops: reconstruct their non-`args` fields from the
  // positional / named arguments `toAscii` renders.
  if (name === 'integral' && args.length === 4 && typeof args[1] === 'string') {
    noNamed(named, name, pos)
    return { op: 'integral', args: [args[0]], var: args[1], lower: args[2], upper: args[3] }
  }
  if (name === 'reshape' && args.length === 2) {
    noNamed(named, name, pos)
    return { op: 'reshape', args: [args[0]], shape: asArrayLiteral(args[1], pos) }
  }
  if (name === 'transpose' && (args.length === 1 || args.length === 2)) {
    noNamed(named, name, pos)
    return args.length === 1
      ? { op: 'transpose', args: [args[0]] }
      : { op: 'transpose', args: [args[0]], perm: asArrayLiteral(args[1], pos) }
  }
  if (name === 'concat') {
    const axis = named.axis
    if (axis === undefined) throw new ExpressionParseError('concat(...) requires axis=<n>', pos)
    return { op: 'concat', args, axis }
  }
  noNamed(named, name, pos)
  if (STRUCTURAL_OPS.has(name)) {
    throw new ExpressionParseError(
      `'${name}' is not yet expressible in the text form`,
      pos,
    )
  }
  if (name === 'D') {
    // Friendly form D(expr, t) — wrt as an explicit second arg — in addition to
    // the toAscii form D(expr)/Dt handled in parsePostfix. Any other arity is a
    // nonstandard / discretization D (e.g. with boundary conditions) that the
    // printer emits via the generic call fallback; keep it a generic call.
    if (args.length === 2 && typeof args[1] === 'string') {
      return { op: 'D', wrt: args[1], args: [args[0]] }
    }
    if (args.length === 1) return { op: 'D', args }
  }
  return { op: name, args }
}

// --- normalization -----------------------------------------------------------

/**
 * Flatten nested same-op `+` / `*` in `args` into the n-ary form the printer
 * emits and authored ASTs use: `a + b + c` → one `+` with three args, not
 * left-nested pairs. (`-` and `/` are binary and stay as parsed.) Non-`args`
 * expression fields (integral bounds, etc.) are left as parsed.
 */
function flatten(e: Expr): Expr {
  if (!isExprNode(e)) return e
  const args = (e.args as Expr[]).map(flatten)
  if (e.op === '+' || e.op === '*') {
    const out: Expr[] = []
    for (const a of args) {
      if (isExprNode(a) && a.op === e.op && a.wrt === undefined) out.push(...(a.args as Expr[]))
      else out.push(a)
    }
    return { ...(e as ExprNode), args: out }
  }
  return { ...(e as ExprNode), args }
}

// --- public API --------------------------------------------------------------

/**
 * Parse a single expression string into an AST expression — the inverse of
 * {@link toAscii}. Throws {@link ExpressionParseError} on malformed input or an
 * operator with no text surface yet.
 */
export function parseExpression(src: string): Expr {
  return new Parser(tokenize(src)).parseEntry()
}

/**
 * Parse `lhs = rhs` into an {@link Equation}. The top-level separator is a LONE
 * `=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side.
 */
export function parseEquation(src: string): Equation {
  const toks = tokenize(src)
  let depth = 0
  let split = -1
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i]
    if (t.k === '(' || t.k === '[') depth++
    else if (t.k === ')' || t.k === ']') depth--
    else if (t.k === 'eq' && depth === 0) {
      if (split !== -1) throw new ExpressionParseError("Multiple '=' at top level", t.pos)
      split = i
    }
  }
  if (split === -1) throw new ExpressionParseError("Expected 'lhs = rhs'", src.length)
  const lhs = new Parser(toks.slice(0, split).concat({ k: 'eof', pos: toks[split].pos }))
  const rhs = new Parser(toks.slice(split + 1))
  // parseEntry yields `Expr`; the parser never produces a NumericLiteral (only
  // number/string/node), so narrowing to Equation's `Expression` fields is safe.
  return { lhs: lhs.parseEntry() as Equation['lhs'], rhs: rhs.parseEntry() as Equation['rhs'] }
}
