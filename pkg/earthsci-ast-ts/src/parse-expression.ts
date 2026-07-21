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
 *    the `true` literal, and `integral` / `reshape` / `transpose` / `concat`;
 *  - reduction & array-query tier: `aggregate` reductions
 *    `sum[i] (expr) where {i in set, j in lo:hi} join(a=b) if pred distinct
 *    key=k [semiring=…]` (all clause shapes), the `argmin`/`argmax` arg-witnesses
 *    `argmin[g] (expr) where {…}`, template application
 *    `name<binding = value, …>` (`apply_expression_template`),
 *    `polygon_intersection_area(a, b, manifold=…)`, and the piecewise-region
 *    array `makearray([lo:hi, …] = value, …)`.
 *
 * Aggregate `args` is a derived operand cache the printer doesn't emit; it's
 * reconstructed best-effort (see {@link deriveAggregateArgs}) and is
 * reprint-neutral. `sum` with neither an explicit `[semiring=…]` nor a `join`
 * reconstructs as a plain `+` reduction — the join-less `sum_product` annotation
 * (semantically identical there) is not recovered; both reprint identically.
 *
 * Still deferred (need dedicated surface syntax — a later pass): `table_lookup`,
 * `broadcast`, `enum`, and `intersect_polygon` (its `id` field is not printed, so
 * it can't round-trip). Those are refused with an {@link ExpressionParseError}.
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
// Template binding values (`name<k = value, …>`) bind at additive precedence so
// the closing `>` — a comparison operator — is never swallowed as `value > …`.
const TEMPLATE_ARG_MIN = opPrecedence('+')

/**
 * Structural ops whose defining data lives OUTSIDE `args` AND which have no
 * text surface yet — refused, pending a dedicated syntax pass. (`integral`,
 * `reshape`, `transpose`, `concat`, `fn`, `const`, `index`, `true`, `aggregate`,
 * `apply_expression_template`, `polygon_intersection_area`, `makearray` DO have a
 * surface and are reconstructed below; they are intentionally absent here.
 * `intersect_polygon` stays refused: its `id` field is not printed, so it can't
 * round-trip.)
 */
const STRUCTURAL_OPS = new Set<string>(['table_lookup', 'broadcast', 'enum', 'intersect_polygon'])

/**
 * The aggregate reduction symbols `toAscii` emits (`formatAggregate`). Each maps
 * to a default `reduce` when no explicit `[semiring=…]` supersedes it; `sum` and
 * `any` carry no `reduce` field (plain `+` / semiring-only).
 */
const AGG_SYMS = new Set<string>(['sum', 'prod', 'max', 'min', 'any'])
/** Arg-witness reductions (`formatArgWitness`): `argmin[g] (expr) where {…}`. */
const ARGWITNESS_SYMS = new Set<string>(['argmin', 'argmax'])
const REDUCE_BY_SYM: Record<string, string | undefined> = {
  sum: undefined,
  prod: '*',
  max: 'max',
  min: 'min',
  any: undefined,
}

// --- tokenizer ---------------------------------------------------------------

type Tok =
  | { k: 'num'; v: number; pos: number }
  | { k: 'name'; v: string; pos: number }
  | { k: 'op'; v: string; pos: number }
  | { k: '('; pos: number }
  | { k: ')'; pos: number }
  | { k: '['; pos: number }
  | { k: ']'; pos: number }
  | { k: '{'; pos: number } // aggregate `where { … }` range clause
  | { k: '}'; pos: number }
  | { k: ':'; pos: number } // range bound separator (`lo:hi`)
  | { k: ';'; pos: number } // aggregate join-clause separator
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
//
// `∂` (U+2202) and `∇` (U+2207) are also name-constituents: source variables are
// sometimes named with them (`∂u_∂z`, a discretized ∂u/∂z shear field), and
// `toAscii` prints such names verbatim. Those glyphs are NOT ascii operators —
// the ascii derivative surface is `D(x)/Dt`, so `∂`/`∇` appear in `toAscii`
// output ONLY inside a name, and accepting them keeps the parser its exact
// inverse. (The unicode big-operator display forms `∑ ∫ ∈ ⟨⟩` remain refused;
// they're `toUnicode`/`toLatex` forms, not the ascii surface — see tokenize().)
const NAME_RE = /^[_∂∇\p{L}][\w.∂∇\p{L}\p{N}]*/u
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
    if (c === '{') {
      toks.push({ k: '{', pos: i++ })
      continue
    }
    if (c === '}') {
      toks.push({ k: '}', pos: i++ })
      continue
    }
    if (c === ':') {
      toks.push({ k: ':', pos: i++ })
      continue
    }
    if (c === ';') {
      toks.push({ k: ';', pos: i++ })
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
    // The big-operator / unicode display forms (∑ ∫ ∈ ⟨⟩ …) are rendered by
    // toUnicode/toLatex, not the ascii form this parser inverts; refuse them so a
    // caller routes such input elsewhere. (The ascii aggregate surface uses the
    // words `sum`/`where`/`in`/`join`/`if` and `{ }` `:` `;`, all handled above;
    // the name-constituents `∂`/`∇` matched via NAME_RE just above.)
    if (c.charCodeAt(0) > 127) {
      throw new ExpressionParseError(
        `unicode operator syntax (${JSON.stringify(c)}) — use the ascii text form`,
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
      // A trailing `[semiring=…]` is an aggregate suffix, never an index — leave
      // it for parseAggregate's tail (it can follow a `key=`/`if` expression).
      if (this.peek(1).k === 'name' && (this.peek(1) as { v: string }).v === 'semiring') break
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
      // `makearray(region = value, …)` — a piecewise-region array. Its arguments
      // are `[lo:hi, …] = value` pairs, not plain call args, so it needs its own
      // parse rather than the generic parseCall path.
      if (t.v === 'makearray' && this.peek().k === '(') return this.parseMakearray()
      if (this.peek().k === '(') return this.parseCall(t.v)
      // Template application `name<binding = value, …>` (or empty `name<>`) →
      // apply_expression_template. The `< NAME =` / `< >` lookahead distinguishes
      // it from a `<` comparison (whose RHS is never a lone `=` nor an empty `>`).
      const lt = this.peek()
      const lt1 = this.peek(1)
      if (
        lt.k === 'op' &&
        lt.v === '<' &&
        ((lt1.k === 'op' && lt1.v === '>') || (lt1.k === 'name' && this.peek(2).k === 'eq'))
      ) {
        return this.parseTemplate(t.v)
      }
      // Aggregate reduction `sym[out_idx] (expr) where {…} …`. Only when the
      // bracket is followed (past its match) by `(` — otherwise `sym[i]` is an
      // ordinary index into a variable that happens to be named `sum`/`max`/….
      if (AGG_SYMS.has(t.v) && this.peek().k === '[' && this.aggregateAhead()) {
        return this.parseAggregate(t.v)
      }
      // Arg-witness reduction `argmin[g] (expr) where {…}` (same `[…] (` shape).
      if (ARGWITNESS_SYMS.has(t.v) && this.peek().k === '[' && this.aggregateAhead()) {
        return this.parseArgWitness(t.v)
      }
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

  // --- aggregate / template (the reduction & array-query tier) ----------------

  /**
   * True when the `[` at the current position (this.peek()) closes with a `]`
   * immediately followed by `(` — the signature of an aggregate `sym[…] (expr)`,
   * as opposed to plain indexing `sym[i]`. Scans balanced brackets, no consume.
   */
  private aggregateAhead(): boolean {
    let depth = 0
    for (let i = this.p; i < this.toks.length; i++) {
      const k = this.toks[i].k
      if (k === '[') depth++
      else if (k === ']') {
        depth--
        if (depth === 0) return this.toks[i + 1]?.k === '('
      }
    }
    return false
  }

  private expectOp(v: string, what: string): void {
    const t = this.peek()
    if (t.k !== 'op' || t.v !== v) this.fail(`Expected ${what}`)
    this.next()
  }

  /** True when the next token is the contextual keyword name `v`. */
  private atWord(v: string): boolean {
    const t = this.peek()
    return t.k === 'name' && t.v === v
  }

  /**
   * Parse an `aggregate` reduction (esm-spec §4.2) — the inverse of
   * `formatAggregate`:
   *
   *   sym '[' out_idx ']' '(' expr ')' ('where' '{' ranges '}')? ('join' '(' … ')')?
   *   ('if' filter)? 'distinct'? ('key' '=' expr)? ('[' 'semiring' '=' name ']')?
   *
   * `sym` selects the default `reduce`; an explicit `[semiring=…]` supersedes it,
   * as does a `join` (which implies `sum_product`). `args` is a derived
   * dependency cache (see {@link deriveAggregateArgs}); `toAscii` doesn't print
   * it, so its exact value is reprint-neutral.
   */
  private parseAggregate(sym: string): Expr {
    this.next() // '['
    const outputIdx: string[] = []
    if (this.peek().k !== ']') {
      for (;;) {
        const t = this.next()
        if (t.k !== 'name') this.fail('Expected an output index name', t)
        outputIdx.push(t.v)
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    this.expect(']', "']' after aggregate output indices")
    this.expect('(', "'(' before the aggregate body")
    const expr = this.parseExpr(0)
    this.expect(')', "')' after the aggregate body")

    let ranges: Record<string, unknown> = {}
    if (this.atWord('where')) {
      this.next()
      ranges = this.parseRanges()
    }
    const join: Array<{ on: [string, string][] }> = []
    if (this.atWord('join')) {
      this.next()
      join.push(...this.parseJoin())
    }
    let filter: Expr | undefined
    if (this.atWord('if')) {
      this.next()
      filter = this.parseExpr(0)
    }
    let distinct = false
    if (this.atWord('distinct')) {
      this.next()
      distinct = true
    }
    let key: Expr | undefined
    if (this.atWord('key') && this.peek(1).k === 'eq') {
      this.next() // 'key'
      this.next() // '='
      key = this.parseExpr(0)
    }
    let semiring: string | undefined
    if (
      this.peek().k === '[' &&
      this.peek(1).k === 'name' &&
      (this.peek(1) as { v: string }).v === 'semiring'
    ) {
      this.next() // '['
      this.next() // 'semiring'
      this.expect('eq', "'=' in [semiring=…]")
      const nm = this.next()
      if (nm.k !== 'name') this.fail('Expected a semiring name', nm)
      semiring = nm.v
      this.expect(']', "']' after [semiring=…]")
    }
    // A join with no explicit semiring is the sum-of-products contraction.
    if (semiring === undefined && join.length > 0) semiring = 'sum_product'

    const node: Record<string, unknown> = { op: 'aggregate', output_idx: outputIdx }
    if (semiring !== undefined) node.semiring = semiring
    else {
      const red = REDUCE_BY_SYM[sym]
      if (red !== undefined) node.reduce = red
    }
    node.ranges = ranges
    if (join.length > 0) node.join = join
    if (filter !== undefined) node.filter = filter
    if (distinct) node.distinct = true
    if (key !== undefined) node.key = key
    node.expr = expr
    node.args = deriveAggregateArgs(expr, join, filter, key)
    return node as unknown as Expr
  }

  /**
   * Parse an `argmin` / `argmax` arg-witness (esm-spec §4.2) — the inverse of
   * `formatArgWitness`: `op '[' arg ']' '(' expr ')' ('where' '{' ranges '}')?`.
   * Like aggregate, its `args` operand cache isn't printed and is derived.
   */
  private parseArgWitness(op: string): Expr {
    this.next() // '['
    const at = this.next()
    if (at.k !== 'name') this.fail('Expected the arg-witness index name', at)
    this.expect(']', "']' after the arg-witness index")
    this.expect('(', "'(' before the arg-witness body")
    const expr = this.parseExpr(0)
    this.expect(')', "')' after the arg-witness body")
    let ranges: Record<string, unknown> = {}
    if (this.atWord('where')) {
      this.next()
      ranges = this.parseRanges()
    }
    return {
      op,
      args: deriveAggregateArgs(expr, [], undefined, undefined),
      arg: at.v,
      ranges,
      expr,
    } as unknown as Expr
  }

  /** Parse a `{ k in <rhs>, … }` where-body into a ranges object. */
  private parseRanges(): Record<string, unknown> {
    this.expect('{', "'{' after where")
    const ranges: Record<string, unknown> = {}
    if (this.peek().k !== '}') {
      for (;;) {
        const kt = this.next()
        if (kt.k !== 'name') this.fail('Expected a range index name', kt)
        if (!this.atWord('in')) this.fail("Expected 'in' in a range clause")
        this.next() // 'in'
        ranges[kt.v] = this.parseRangeRhs()
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    this.expect('}', "'}' to close the where clause")
    return ranges
  }

  /** One range RHS: `set` → {from}; `set(a, b)` → {from, of}; `lo:hi` → [lo, hi]. */
  private parseRangeRhs(): unknown {
    const bound = this.parseExpr(0)
    if (this.peek().k === ':') {
      this.next()
      return [bound, this.parseExpr(0)]
    }
    if (typeof bound === 'string') return { from: bound }
    // `k in set(of1, of2)` prints as a generic call → {from, of}.
    if (isExprNode(bound) && /^[_\p{L}]/u.test(bound.op) && Array.isArray(bound.args)) {
      const of = (bound.args as Expr[]).map((a) => {
        if (typeof a !== 'string') this.fail('range set arguments must be names')
        return a as string
      })
      return { from: bound.op, of }
    }
    return this.fail('malformed range (expected a set name, set(of…), or lo:hi)')
  }

  /** Parse `( a=b, c=d ; e=f )` → [{on:[[a,b],[c,d]]}, {on:[[e,f]]}]. */
  private parseJoin(): Array<{ on: [string, string][] }> {
    this.expect('(', "'(' after join")
    const clauses: Array<{ on: [string, string][] }> = []
    let cur: [string, string][] = []
    if (this.peek().k !== ')') {
      for (;;) {
        const a = this.next()
        if (a.k !== 'name') this.fail('Expected a join key name', a)
        this.expect('eq', "'=' in a join pair")
        const b = this.next()
        if (b.k !== 'name') this.fail('Expected a join key name', b)
        cur.push([a.v, b.v])
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        if (this.peek().k === ';') {
          this.next()
          clauses.push({ on: cur })
          cur = []
          continue
        }
        break
      }
    }
    clauses.push({ on: cur })
    this.expect(')', "')' to close join(…)")
    return clauses
  }

  /** Parse `name<binding = value, …>` (or empty `name<>`) → apply_expression_template. */
  private parseTemplate(name: string): Expr {
    this.next() // '<'
    const bindings: Record<string, Expr> = {}
    while (!(this.peek().k === 'op' && (this.peek() as { v: string }).v === '>')) {
      const kt = this.next()
      if (kt.k !== 'name') this.fail('Expected a binding name in <…>', kt)
      this.expect('eq', "'=' in a template binding")
      bindings[kt.v] = this.parseExpr(TEMPLATE_ARG_MIN)
      if (this.peek().k === ',') {
        this.next()
        continue
      }
      break
    }
    this.expectOp('>', "'>' to close a template application")
    return { op: 'apply_expression_template', args: [], name, bindings }
  }

  /**
   * Parse a `makearray` piecewise-region array (esm-spec §4.2) — the inverse of
   * `formatStructuralOp`'s makearray case:
   *
   *   'makearray' '(' region '=' value ( ',' region '=' value )* ')'
   *   region := '[' bound ':' bound ( ',' bound ':' bound )* ']'
   *
   * Each region is a list of per-dimension `lo:hi` bounds, and `value` is the
   * expression that region evaluates to. A bound is any expression (a number, a
   * name like `NLON`, or e.g. `NLON - 1`). `args` is always `[]` (the printer
   * emits none); `regions` and `values` are positionally paired. Values are
   * flattened to the canonical n-ary `+`/`*` form, like the top-level parse.
   */
  private parseMakearray(): Expr {
    this.next() // '('
    const regions: [Expr, Expr][][] = []
    const values: Expr[] = []
    if (this.peek().k !== ')') {
      for (;;) {
        this.expect('[', "'[' to open a makearray region")
        const region: [Expr, Expr][] = []
        if (this.peek().k !== ']') {
          for (;;) {
            const lo = this.parseExpr(0)
            this.expect(':', "':' between a region's lo:hi bounds")
            const hi = this.parseExpr(0)
            region.push([flatten(lo), flatten(hi)])
            if (this.peek().k === ',') {
              this.next()
              continue
            }
            break
          }
        }
        this.expect(']', "']' to close a makearray region")
        this.expect('eq', "'=' after a makearray region")
        regions.push(region)
        values.push(flatten(this.parseExpr(0)))
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    this.expect(')', "')' to close makearray(...)")
    return { op: 'makearray', args: [], regions, values } as unknown as Expr
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
  // Geometry area query `polygon_intersection_area(a, b, manifold=<name>)`. (Its
  // sibling `intersect_polygon` stays refused: its `id` field isn't printed.)
  if (name === 'polygon_intersection_area') {
    const manifold = named.manifold
    if (typeof manifold !== 'string') {
      throw new ExpressionParseError(`${name}(...) requires manifold=<name>`, pos)
    }
    for (const k of Object.keys(named)) {
      if (k !== 'manifold') throw new ExpressionParseError(`unexpected ${k}=… in ${name}(...)`, pos)
    }
    return { op: 'polygon_intersection_area', args, manifold }
  }
  noNamed(named, name, pos)
  if (STRUCTURAL_OPS.has(name)) {
    throw new ExpressionParseError(`'${name}' is not yet expressible in the text form`, pos)
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

/**
 * Best-effort reconstruction of an aggregate's `args` — its array operands.
 * `toAscii` does NOT print `args` (it's a derived dependency cache), and the
 * authoritative set excludes parameter arrays by *declared role*, which needs
 * the variable table. From the printed structure alone we approximate it as: the
 * base of every `index(…)` in the body / filter / key, plus the names in `join`
 * clauses, in first-appearance order. This is reprint-neutral (the printer
 * ignores it) and a dependency superset (safe for graph/dead-code analysis); an
 * editor holding the symbol table should recompute it on save.
 */
function deriveAggregateArgs(
  expr: Expr,
  join: Array<{ on: [string, string][] }>,
  filter: Expr | undefined,
  key: Expr | undefined,
): string[] {
  const out: string[] = []
  const add = (n: string) => {
    if (!out.includes(n)) out.push(n)
  }
  const bases = (e: unknown): void => {
    if (Array.isArray(e)) return e.forEach(bases)
    if (e && typeof e === 'object') {
      const o = e as Record<string, unknown>
      if (o.op === 'index' && Array.isArray(o.args) && typeof o.args[0] === 'string') add(o.args[0])
      for (const k of Object.keys(o)) bases(o[k])
    }
  }
  bases(expr)
  for (const c of join)
    for (const [a, b] of c.on) {
      add(a)
      add(b)
    }
  bases(filter)
  bases(key)
  return out
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
  let angle = 0 // template `name<binding = value>` — its `=` is not a separator
  let split = -1
  for (let i = 0; i < toks.length && split === -1; i++) {
    const t = toks[i]
    if (t.k === '(' || t.k === '[' || t.k === '{') depth++
    else if (t.k === ')' || t.k === ']' || t.k === '}') depth--
    else if (t.k === 'op' && t.v === '<' && toks[i + 1]?.k === 'name' && toks[i + 2]?.k === 'eq')
      angle++
    else if (t.k === 'op' && t.v === '>' && angle > 0) angle--
    // The FIRST top-level lone `=` splits lhs/rhs; a later binding/`key=` `=`
    // (legitimately present in an aggregate or template on the rhs) is left intact.
    else if (t.k === 'eq' && depth === 0 && angle === 0) split = i
  }
  if (split === -1) throw new ExpressionParseError("Expected 'lhs = rhs'", src.length)
  const lhs = new Parser(toks.slice(0, split).concat({ k: 'eof', pos: toks[split].pos }))
  const rhs = new Parser(toks.slice(split + 1))
  // parseEntry yields `Expr`; the parser never produces a NumericLiteral (only
  // number/string/node), so narrowing to Equation's `Expression` fields is safe.
  return { lhs: lhs.parseEntry() as Equation['lhs'], rhs: rhs.parseEntry() as Equation['rhs'] }
}
