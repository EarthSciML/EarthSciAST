/**
 * parse-expression — the INVERSE of `toAscii` (pretty-print.ts) for the scalar
 * tier of the expression AST (esm-spec §4.2): arithmetic, powers, comparisons,
 * boolean logic, the elementary functions, derivatives, and open / user
 * function calls.
 *
 * The concrete syntax IS what `toAscii` emits, so the pair round-trips:
 * `toAscii(parseExpression(s)) === s`. Precedence is sourced from
 * {@link opPrecedence} (op-registry.ts) rather than duplicated, so the parser
 * can never drift from the printer.
 *
 * Design rules:
 *  - Multiplication is ALWAYS explicit (`k * A`). There is no implicit
 *    juxtaposition, because the format's identifiers are multi-letter (`NO2`,
 *    `O3`, `k_photo`) which makes `kA` ambiguous. This is the reason the input
 *    syntax is code-like rather than LaTeX-like; LaTeX remains the RENDER
 *    target (`toLatex`), never the input.
 *  - The STRUCTURAL tier — ops whose defining data lives OUTSIDE `args`
 *    (aggregate, table_lookup, integral, enum, index, const arrays, closed
 *    functions via `fn`, …; esm-spec §4.2) — is out of scope. Those are refused
 *    with an {@link ExpressionParseError}; a caller routes them to a structural
 *    editor. Array `[...]`, index/table `[...]`, dotted-call and big-operator
 *    (`∑ ∫ ∂`) syntax hit the same refusal.
 *
 * Two known non-exactnesses trace to `toAscii`, not to the parser: (1) float
 * serialization (`formatNumber`) routes through a JS double and is not
 * perfectly round-trippable; the parsed value is the correct nearest double.
 * (2) unary-minus operands are under-parenthesized by the printer (`-(a+b)` and
 * `(-a)+b` both print `-a + b`); the parser matches the printer's loose
 * convention so it stays an exact inverse.
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
 * Ops whose defining data lives OUTSIDE `args` (esm-spec §4.2). They render via
 * their own surface syntax and cannot be reconstructed from a flat arg list, so
 * the scalar parser refuses them. Some (`integral`, `concat`, …) happen to
 * PRINT as `name(...)`; refusing by name is what stops us from building a
 * structurally-wrong node. Mirrors pretty-print's `formatStructuralOp` switch.
 */
const STRUCTURAL_OPS = new Set<string>([
  'const',
  'true',
  'fn',
  'enum',
  'index',
  'broadcast',
  'integral',
  'table_lookup',
  'apply_expression_template',
  'makearray',
  'reshape',
  'transpose',
  'concat',
  'intersect_polygon',
  'polygon_intersection_area',
  'aggregate',
  'argmin',
  'argmax',
])

// --- tokenizer ---------------------------------------------------------------

type Tok =
  | { k: 'num'; v: number; pos: number }
  | { k: 'name'; v: string; pos: number }
  | { k: 'op'; v: string; pos: number }
  | { k: '('; pos: number }
  | { k: ')'; pos: number }
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
// like `datetime.year`, which makeCall then routes to the structural editor).
// A leading digit still can't start an identifier (numbers lex first).
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
    // Array / index / dotted / big-operator syntax belongs to the structural
    // tier; refuse it with the same escape-hatch message so callers route it
    // uniformly to the structural editor.
    if ('[].{}'.includes(c) || c.charCodeAt(0) > 127) {
      throw new ExpressionParseError(
        `structural operator syntax (${JSON.stringify(c)}) — edit it in a structural editor, not the text form`,
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

  /** Atom, then the derivative sugar `D(expr)/D<name>` that `toAscii` emits. */
  private parsePostfix(): Expr {
    const atom = this.parseAtom()
    const slash = this.peek()
    if (isExprNode(atom) && atom.op === 'D' && slash.k === 'op' && slash.v === '/') {
      const nameTok = this.peek(1)
      if (nameTok.k === 'name' && nameTok.v.length > 1 && nameTok.v[0] === 'D') {
        this.next() // '/'
        this.next() // 'D<var>'
        return { op: 'D', wrt: nameTok.v.slice(1), args: atom.args }
      }
    }
    return atom
  }

  private parseAtom(): Expr {
    const t = this.next()
    if (t.k === 'num') return t.v
    if (t.k === '(') {
      const e = this.parseExpr(0)
      if (this.peek().k !== ')') this.fail("Expected ')'")
      this.next()
      return e
    }
    if (t.k === 'name') {
      if (this.peek().k === '(') return this.parseCall(t.v)
      return t.v // bare variable / species / qualified reference
    }
    return this.fail("Expected a number, name, or '('", t)
  }

  private parseCall(name: string): Expr {
    this.next() // '('
    const args: Expr[] = []
    if (this.peek().k !== ')') {
      for (;;) {
        args.push(this.parseExpr(0))
        if (this.peek().k === ',') {
          this.next()
          continue
        }
        break
      }
    }
    if (this.peek().k !== ')') this.fail(`Expected ',' or ')' in call to ${name}(...)`)
    this.next()
    return makeCall(name, args, this.peek().pos)
  }
}

function makeCall(name: string, args: Expr[], pos: number): Expr {
  // A dotted callee is a closed function (`datetime.year`, `interp.bilinear`) —
  // an `fn`-op, which is structural. (A dotted BARE name, by contrast, is a
  // qualified variable reference and is accepted as an identifier.)
  if (STRUCTURAL_OPS.has(name) || name.includes('.')) {
    throw new ExpressionParseError(
      `'${name}' is a structural operator — edit it in a structural editor, not the text form`,
      pos,
    )
  }
  if (name === 'D') {
    // Friendly form D(expr, t) — wrt as an explicit second arg — in addition to
    // the toAscii form D(expr)/Dt handled in parsePostfix. Any other arity is a
    // nonstandard / discretization D (e.g. with boundary conditions) that the
    // printer emits via the generic call fallback; keep it a generic call so it
    // round-trips.
    if (args.length === 2 && typeof args[1] === 'string') {
      return { op: 'D', wrt: args[1], args: [args[0]] }
    }
    if (args.length === 1) return { op: 'D', args }
  }
  return { op: name, args }
}

// --- normalization -----------------------------------------------------------

/**
 * Flatten nested same-op `+` / `*` into the n-ary form the printer emits and
 * authored ASTs use: `a + b + c` → one `+` with three args, not left-nested
 * pairs. (`-` and `/` are binary and stay as parsed.)
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
 * {@link toAscii} for the scalar tier. Throws {@link ExpressionParseError} on
 * malformed input or a structural-tier operator.
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
    if (t.k === '(') depth++
    else if (t.k === ')') depth--
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
