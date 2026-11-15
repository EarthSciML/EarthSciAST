/**
 * Typeset unit spellings: LaTeX and Typst, with no unit package.
 *
 * Port of `formal/Esm/Units/Typeset.lean` (after the Rust binding's
 * `document/math/units.rs`), with the `Esm.Units` helpers it uses
 * (`numFactors`, `denFactors` from Factors.lean, `digs`, `symOK` from
 * Canonical.lean, `isIdent`, `isDigitC` from Grammar.lean), and the two
 * functions of the unit layer the math printer and parser call: the canonical
 * spelling of a factor list ({@link spellUnitFactors}, `Esm.Units.spell`) and
 * the two-sided factor list of a canonical unit string ({@link factorsOf},
 * `Math.factorsOf`).
 *
 * **LaTeX**: the canonical spelling's layout inside `\mathrm{…}`: numerator
 * factors joined by `\,`, a denominator after `/` (parenthesized when it has
 * more than one factor), exponents as braced superscripts, `_` and `%` escaped.
 *
 * **Typst**: one `upright("sym")^(exp)` per factor with its signed exponent,
 * factors separated by ` thin `.
 *
 * The Lean parser `pSepBy` carries fuel equal to the input length, which every
 * caller gives and which is never exhausted (each item consumes a character);
 * the port loops without it.
 */

import { cmpCodePoints } from '../json.js'
import type { Chars, Read } from '../number.js'

// ## Rationals (Lean's `ℚ`): normalized, positive denominator.

/** A rational number `n / d` in lowest terms with `d > 0`. */
export interface Rat {
  readonly n: bigint
  readonly d: bigint
}

const babs = (x: bigint): bigint => (x < 0n ? -x : x)

function gcd(a: bigint, b: bigint): bigint {
  a = babs(a)
  b = babs(b)
  while (b !== 0n) [a, b] = [b, a % b]
  return a
}

/** `p / q` in lowest terms (`q ≠ 0`). */
export function rat(p: bigint, q: bigint = 1n): Rat {
  if (q < 0n) {
    p = -p
    q = -q
  }
  const g = gcd(p, q)
  return g > 1n ? { n: p / g, d: q / g } : { n: p, d: q }
}

export const RAT_ONE: Rat = Object.freeze({ n: 1n, d: 1n })
export const ratEq = (a: Rat, b: Rat): boolean => a.n === b.n && a.d === b.d
export const ratNeg = (a: Rat): Rat => ({ n: -a.n, d: a.d })
export const ratAbs = (a: Rat): Rat => ({ n: babs(a.n), d: a.d })
export const ratAdd = (a: Rat, b: Rat): Rat => rat(a.n * b.d + b.n * a.d, a.d * b.d)
const isOne = (q: Rat): boolean => q.n === 1n && q.d === 1n
const isInteger = (q: Rat): boolean => q.d === 1n
const isPositive = (q: Rat): boolean => q.n > 0n

/** `p / d` as Lean's rational division (`x / 0 = 0`). */
function ratio(p: Rat, d: bigint): Rat {
  return d === 0n ? rat(0n) : rat(p.n, p.d * d)
}

/** `Esm.Units.Factor`: a unit symbol and its (signed, rational) exponent. */
export type Factor = readonly [string, Rat]

/** Equality of two factor lists. */
export function factorsEq(a: readonly Factor[], b: readonly Factor[]): boolean {
  return a.length === b.length && a.every((f, i) => f[0] === b[i][0] && ratEq(f[1], b[i][1]))
}

/** `Esm.Units.isDigitC`. */
export function isDigitC(c: string | undefined): boolean {
  return c !== undefined && c.length === 1 && c >= '0' && c <= '9'
}

/** `Esm.Units.isIdent`: characters that may occur in a symbol run. */
export function isIdent(c: string | undefined): boolean {
  return (
    c !== undefined &&
    c.length === 1 &&
    ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '_')
  )
}

/** `Esm.Units.numFactors`: the factors with a positive exponent. */
export function numFactors(l: readonly Factor[]): Factor[] {
  return l.filter((f) => isPositive(f[1]))
}

/** `Esm.Units.denFactors`: the factors with a nonpositive exponent. */
export function denFactors(l: readonly Factor[]): Factor[] {
  return l.filter((f) => !isPositive(f[1]))
}

/** `Esm.Units.symRunB` (Canonical.lean). */
export function symRunB(s: string): boolean {
  if (s.length === 0) return false
  let allDig = true
  for (const c of s) {
    if (!isIdent(c)) return false
    if (!isDigitC(c)) allDig = false
  }
  return !allDig
}

/** `Esm.Units.symOK` (Canonical.lean): `%`, or a symbol run, and not `dimensionless`. */
export function symOk(s: string): boolean {
  return (s === '%' || symRunB(s)) && s !== 'dimensionless'
}

/** `Esm.Units.digs`: the decimal digits of `n` (empty for `0`). */
export function digs(n: bigint): string {
  return n === 0n ? '' : n.toString()
}

/** `Esm.Units.pDigits`: a nonempty digit run and its value. */
export function pDigits(cs: Chars, i: number): Read<bigint> {
  let j = i
  let v = 0n
  while (isDigitC(cs[j])) v = v * 10n + BigInt(cs[j++].charCodeAt(0) - 48)
  return j === i ? undefined : [v, j]
}

/** `Esm.Units.joinWith`. */
export function joinWith(pr: (f: Factor) => string, sep: string, l: readonly Factor[]): string {
  return l.map(pr).join(sep)
}

/** The text `p` occurs in `cs` at `i`. */
function at(p: string, cs: Chars, i: number): boolean {
  for (let k = 0; k < p.length; k++) if (cs[i + k] !== p[k]) return false
  return true
}

/**
 * `Esm.Units.pSepBy`: items read by `pf`, separated by `sep` (fuel dropped, see
 * the module doc).
 */
export function pSepBy(
  pf: (cs: Chars, i: number) => Read<Factor>,
  sep: string,
  cs: Chars,
  i: number,
): Read<Factor[]> {
  const out: Factor[] = []
  for (;;) {
    const r = pf(cs, i)
    if (r === undefined) return undefined
    out.push(r[0])
    if (!at(sep, cs, r[1])) return [out, r[1]]
    i = r[1] + sep.length
  }
}

// ## LaTeX

/** `Esm.Units.latexSym`: `_` and `%` escaped with a backslash. */
export function latexSym(s: string): string {
  let out = ''
  for (const c of s) out += c === '_' || c === '%' ? `\\${c}` : c
  return out
}

/** `Esm.Units.latexExp`: a positive exponent as a braced superscript (nothing for 1). */
export function latexExp(q: Rat): string {
  if (isOne(q)) return ''
  return `^{${digs(babs(q.n))}${isInteger(q) ? '' : `/${digs(q.d)}`}}`
}

/** `Esm.Units.latexFactor`: one factor, with the absolute value of its exponent. */
export function latexFactor(f: Factor): string {
  return latexSym(f[0]) + latexExp(ratAbs(f[1]))
}

/** `Esm.Units.latexSep`. */
export const LATEX_SEP = '\\,'

/** `Esm.Units.latexBody`: the body of `\mathrm{…}`. */
export function latexBody(l: readonly Factor[]): string {
  const nf = numFactors(l)
  let out = nf.length === 0 ? '1' : joinWith(latexFactor, LATEX_SEP, nf)
  const df = denFactors(l)
  if (df.length === 1) out += `/${latexFactor(df[0])}`
  else if (df.length > 1) out += `/(${joinWith(latexFactor, LATEX_SEP, df)})`
  return out
}

/** `Esm.Units.mathrmOpen`. */
export const MATHRM_OPEN = '\\mathrm{'

/** `Esm.Units.latex`: the LaTeX form of a canonical factor list. */
export function latex(l: readonly Factor[]): string {
  return `${MATHRM_OPEN}${latexBody(l)}}`
}

/** `Esm.Units.pLSym`: identifier characters, `%`, and the escapes `\_`, `\%`. */
export function pLSym(cs: Chars, i: number): [string, number] {
  let out = ''
  for (;;) {
    const c = cs[i]
    if (isIdent(c) || c === '%') {
      out += c
      i++
    } else if (c === '\\' && (cs[i + 1] === '_' || cs[i + 1] === '%')) {
      out += cs[i + 1]
      i += 2
    } else return [out, i]
  }
}

/** `Esm.Units.pLExp`: a braced superscript, or nothing (exponent 1). */
export function pLExp(cs: Chars, i: number): Read<Rat> {
  if (!(cs[i] === '^' && cs[i + 1] === '{')) return [RAT_ONE, i]
  const r = pDigits(cs, i + 2)
  if (r === undefined) return undefined
  const [p, j] = r
  if (cs[j] === '}') return [rat(p), j + 1]
  if (cs[j] === '/') {
    const r2 = pDigits(cs, j + 1)
    if (r2 !== undefined && cs[r2[1]] === '}') return [ratio(rat(p), r2[0]), r2[1] + 1]
  }
  return undefined
}

/** `Esm.Units.pLFactor`. */
export function pLFactor(cs: Chars, i: number): Read<Factor> {
  const [s, j] = pLSym(cs, i)
  if (s.length === 0) return undefined
  const r = pLExp(cs, j)
  return r && [[s, r[0]], r[1]]
}

/** `Esm.Units.pLDen`: a LaTeX denominator (after the `/`), reaching the end `e`. */
export function pLDen(cs: Chars, i: number, e: number): Factor[] | undefined {
  if (cs[i] === '(') {
    const r = pSepBy(pLFactor, LATEX_SEP, cs, i + 1)
    return r !== undefined && r[1] === e - 1 && cs[e - 1] === ')' ? r[0] : undefined
  }
  const r = pSepBy(pLFactor, LATEX_SEP, cs, i)
  return r !== undefined && r[1] === e && r[0].length === 1 ? r[0] : undefined
}

/** `Esm.Units.parseLatex`: a LaTeX unit back to its two-sided factor list. */
export function parseLatex(s: Chars): Factor[] | undefined {
  if (!at(MATHRM_OPEN, s, 0)) return undefined
  if (s.length <= MATHRM_OPEN.length || s[s.length - 1] !== '}') return undefined
  // The body, without the closing brace, ends at `e`.
  const e = s.length - 1
  const b = s.slice(0, e)
  const r = pSepBy(pLFactor, LATEX_SEP, b, MATHRM_OPEN.length)
  if (r === undefined) return undefined
  const rest = r[1]
  let num = r[0]
  if (num.length === 1 && num[0][0] === '1' && isOne(num[0][1])) num = []
  if (rest === e) return num
  if (b[rest] !== '/') return undefined
  const den = pLDen(b, rest + 1, e)
  return den && [...num, ...den.map(([s2, q]): Factor => [s2, ratNeg(q)])]
}

// ## Typst

/** `Esm.Units.uprightOpen`. */
export const UPRIGHT_OPEN = 'upright("'
/** `Esm.Units.uprightClose`. */
export const UPRIGHT_CLOSE = '")'
/** `Esm.Units.thinSep`. */
export const THIN_SEP = ' thin '

/**
 * `Esm.Units.typstExp`: a signed exponent: nothing for 1, `^n`, `^(-n)`,
 * `^(p\/q)`, `^(-p\/q)`.
 */
export function typstExp(q: Rat): string {
  if (isOne(q)) return ''
  const n = digs(babs(q.n))
  if (isInteger(q)) return isPositive(q) ? `^${n}` : `^(-${n})`
  return `^(${q.n < 0n ? '-' : ''}${n}\\/${digs(q.d)})`
}

/** `Esm.Units.typstFactor`: `upright("sym")` and its signed exponent. */
export function typstFactor(f: Factor): string {
  return UPRIGHT_OPEN + f[0] + UPRIGHT_CLOSE + typstExp(f[1])
}

/** `Esm.Units.typst`: the Typst form of a canonical factor list (`1` when empty). */
export function typst(l: readonly Factor[]): string {
  if (l.length === 0) return '1'
  return joinWith(typstFactor, THIN_SEP, [...numFactors(l), ...denFactors(l)])
}

/** `Esm.Units.pTParen`: after `^(`: `'-'? digits (')' | '\/' digits ')')`. */
export function pTParen(cs: Chars, i: number): Read<Rat> {
  const neg = cs[i] === '-'
  const r = pDigits(cs, neg ? i + 1 : i)
  if (r === undefined) return undefined
  const [p, j] = r
  const sp = rat(neg ? -p : p)
  if (cs[j] === ')') return [sp, j + 1]
  if (cs[j] === '\\' && cs[j + 1] === '/') {
    const r2 = pDigits(cs, j + 2)
    if (r2 !== undefined && cs[r2[1]] === ')') return [ratio(sp, r2[0]), r2[1] + 1]
  }
  return undefined
}

/** `Esm.Units.pTExp`: an optional exponent (none means 1). */
export function pTExp(cs: Chars, i: number): Read<Rat> {
  if (cs[i] !== '^') return [RAT_ONE, i]
  if (cs[i + 1] === '(') return pTParen(cs, i + 2)
  if (i + 1 >= cs.length) return undefined
  const r = pDigits(cs, i + 1)
  return r && [rat(r[0]), r[1]]
}

/** `Esm.Units.pTFactor`. */
export function pTFactor(cs: Chars, i: number): Read<Factor> {
  if (!at(UPRIGHT_OPEN, cs, i)) return undefined
  let j = i + UPRIGHT_OPEN.length
  const start = j
  while (j < cs.length && cs[j] !== '"') j++
  const sym = cs.slice(start, j).join('')
  if (!at(UPRIGHT_CLOSE, cs, j)) return undefined
  const r = pTExp(cs, j + UPRIGHT_CLOSE.length)
  return r && [[sym, r[0]], r[1]]
}

/** `Esm.Units.parseTypst`: a Typst unit back to its two-sided factor list. */
export function parseTypst(s: Chars): Factor[] | undefined {
  if (s.length === 1 && s[0] === '1') return []
  const r = pSepBy(pTFactor, THIN_SEP, s, 0)
  return r !== undefined && r[1] === s.length ? r[0] : undefined
}

// ## The unit layer's spelling (`Esm.Units.spell`, `Math.factorsOf`)

/** One factor of the canonical spelling, with its exponent's absolute value. */
function spellFactor([s, q0]: Factor): string {
  const q = ratAbs(q0)
  if (isOne(q)) return s
  if (isInteger(q)) return `${s}^${q.n}`
  return `${s}^(${q.n}/${q.d})`
}

/**
 * The canonical spelling of a factor list (`Esm.Units.spell`,
 * formal/Esm/Units/Canonical.lean; the Rust crate's `spell_unit_factors`): the
 * positive-exponent factors joined by `*` (`1` when there are none), then `/`
 * and the others with their exponents' absolute values, parenthesized when
 * there is more than one.
 */
export function spellUnitFactors(l: readonly Factor[]): string {
  const num = l.filter((f) => isPositive(f[1])).map(spellFactor)
  const den = l.filter((f) => !isPositive(f[1])).map(spellFactor)
  let out = num.length === 0 ? '1' : num.join('*')
  if (den.length === 1) out += `/${den[0]}`
  else if (den.length > 1) out += `/(${den.join('*')})`
  return out
}

/** `Esm.Units.norm`: each symbol once with its exponents summed, zero sums dropped, sorted. */
function normSide(fs: readonly Factor[]): Factor[] {
  const total = new Map<string, Rat>()
  for (const [s, q] of fs) {
    const prev = total.get(s)
    total.set(s, prev === undefined ? q : ratAdd(prev, q))
  }
  return [...total.entries()]
    .filter(([, q]) => q.n !== 0n)
    .sort((a, b) => cmpCodePoints(a[0], b[0]))
    .map(([s, q]): Factor => [s, q])
}

/** A factor of the canonical spelling: a symbol and an optional `^n` / `^(p/q)`. */
function pSpellFactor(cs: Chars, i: number): Read<Factor> {
  let j = i
  if (cs[j] === '%') j++
  else while (isIdent(cs[j])) j++
  if (j === i) return undefined
  const s = cs.slice(i, j).join('')
  if (cs[j] !== '^') return [[s, RAT_ONE], j]
  if (cs[j + 1] === '(') {
    const p = pDigits(cs, j + 2)
    if (p === undefined || cs[p[1]] !== '/') return undefined
    const q = pDigits(cs, p[1] + 1)
    if (q === undefined || cs[q[1]] !== ')' || q[0] === 0n) return undefined
    return [[s, rat(p[0], q[0])], q[1] + 1]
  }
  const p = pDigits(cs, j + 1)
  return p && [[s, rat(p[0])], p[1]]
}

/**
 * `Math.factorsOf` (Print.lean): the two-sided factor list of a units string
 * (`[]` when it does not parse), here for the strings the printer typesets.
 *
 * The Rust crate calls its full unit parser (`unit_two_sided_factors`). Every
 * use of the result is guarded by `unitsOK`, which requires
 * `spell(factorsOf(u)) = u` with every symbol `symOK`, i.e. `u` already in the
 * canonical spelling; on such a string this reader of the canonical shape
 * (factors joined by `*`, an optional `/` and one factor or a parenthesized
 * `*` list, the numerator `1` when only a denominator is written), followed by
 * the same per-side normalization, gives the full parser's list. On any other
 * string the result differs from the full parser's, but then `spell` of either
 * list is not `u`, so {@link unitsOkFactors} fails for both.
 */
export function factorsOf(u: string): Factor[] {
  const cs = Array.from(u)
  let i: number
  let num: Factor[] = []
  if (cs[0] === '1' && cs[1] === '/') i = 1
  else {
    const r = pSepBy(pSpellFactor, '*', cs, 0)
    if (r === undefined) return []
    num = r[0]
    i = r[1]
  }
  let den: Factor[] = []
  if (cs[i] === '/') {
    if (cs[i + 1] === '(') {
      const r = pSepBy(pSpellFactor, '*', cs, i + 2)
      if (r === undefined || cs[r[1]] !== ')') return []
      den = r[0]
      i = r[1] + 1
    } else {
      const r = pSpellFactor(cs, i + 1)
      if (r === undefined) return []
      den = [r[0]]
      i = r[1]
    }
  }
  if (i !== cs.length) return []
  return [...normSide(num), ...normSide(den.map(([s, q]): Factor => [s, ratNeg(q)]))]
}

/** The `factorsOf`-dependent part of `Math.unitsOK`: `l` nonempty and spelled `u`. */
export function unitsOkFactors(u: string, l: readonly Factor[]): boolean {
  return l.length > 0 && spellUnitFactors(l) === u
}
