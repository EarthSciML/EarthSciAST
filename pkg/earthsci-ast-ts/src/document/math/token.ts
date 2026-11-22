/**
 * Math tokens, shared by the two surfaces.
 *
 * Port of `formal/Esm/Document/Math/Token.lean` (after the Rust binding's
 * `document/math/token.rs`). A token names what the surface text MEANS (`Land`
 * is `\land` in LaTeX and `and` in Typst), so one parser reads both; each
 * surface has its own renderer and lexer.
 */

import { jnumEq, jsonEq, type JNum, type Json } from '../json.js'
import { factorsEq, type Factor } from './units.js'

/**
 * `Math.Kw`: keywords and punctuation. `Lp`/`Rp` are call parentheses,
 * `Lpg`/`Rpg` grouping parentheses; `LimitsL` is the LaTeX marker `\limits`.
 */
export type Kw =
  // operators
  | 'Plus'
  | 'Minus'
  | 'Eq'
  | 'Ne'
  | 'Lt'
  | 'Gt'
  | 'Le'
  | 'Ge'
  | 'Land'
  | 'Lor'
  | 'Lnot'
  | 'Cdot'
  | 'Times'
  | 'Slash'
  | 'Caret'
  | 'Us'
  // delimiters
  | 'Lp'
  | 'Rp'
  | 'Lpg'
  | 'Rpg'
  | 'Lb'
  | 'Rb'
  | 'Lbk'
  | 'Rbk'
  | 'Comma'
  | 'Semi'
  | 'Colon'
  | 'Amp'
  | 'Nl'
  | 'Sdot'
  // functions and notations
  | 'Frac'
  | 'Sqrt'
  | 'Exp'
  | 'Ln'
  | 'Log'
  | 'Sin'
  | 'Cos'
  | 'Tan'
  | 'Asin'
  | 'Acos'
  | 'Atan'
  | 'Sinh'
  | 'Cosh'
  | 'Tanh'
  | 'Min'
  | 'Max'
  | 'Labs'
  | 'Rabs'
  | 'Lfloor'
  | 'Rfloor'
  | 'Lceil'
  | 'Rceil'
  | 'Abs'
  | 'Floor'
  | 'Ceil'
  | 'Pdiff'
  // the nabla of the grad, div, laplacian and curl forms: LaTeX `\nabla`, Typst `nabla`
  | 'Nabla'
  | 'Dif'
  | 'Dotacc'
  | 'Bcases'
  | 'Ecases'
  | 'Cases'
  | 'Esmnode'
  // constant arrays
  | 'Bmat'
  | 'Emat'
  | 'Vec'
  | 'Mat'
  // faq reductions
  | 'Sum'
  | 'Prod'
  | 'Inn'
  | 'Substack'
  | 'Limits'
  | 'Lbkg'
  | 'Rbkg'
  | 'Lr'
  | 'LimitsL'
  // makearray: LaTeX `\begin{array}{l|l}` `\end{array}` (`\end{array}` also closes a
  // wide constant matrix)
  | 'Barr'
  | 'Earr'
  // a set of names, LaTeX `\{` `\}`, Typst `{` `}` (the `args` of a `faq`)
  | 'Lset'
  | 'Rset'

/**
 * `Math.Tok`.
 *
 * - `rm`: LaTeX `\mathrm{…}`, kept raw.
 * - `ups`: Typst run of adjacent `upright("…")` pieces (text, digit subscript).
 * - `jstr`: LaTeX JSON string inside an escape node's fields.
 * - `esc`: LaTeX `\esm{op}`.
 * - `code`: Typst `#value`.
 * - `units`: the unit after a quantity's number.
 * - `acols`: LaTeX `\begin{array}{c…c}`, the opener of a constant matrix with
 *   more columns than `bmatrix` allows, carrying its column count.
 */
export type Tok =
  | { readonly t: 'num'; readonly n: JNum }
  | { readonly t: 'letter'; readonly c: string }
  | { readonly t: 'greek'; readonly s: string }
  | { readonly t: 'word'; readonly s: string }
  | { readonly t: 'it'; readonly s: string }
  | { readonly t: 'rm'; readonly s: string }
  | { readonly t: 'ups'; readonly ps: readonly (readonly [string, string])[] }
  | { readonly t: 'opn'; readonly s: string }
  | { readonly t: 'txt'; readonly s: string }
  | { readonly t: 'jstr'; readonly s: string }
  | { readonly t: 'esc'; readonly s: string }
  | { readonly t: 'code'; readonly j: Json }
  | { readonly t: 'units'; readonly l: readonly Factor[] }
  | { readonly t: 'acols'; readonly n: number }
  | { readonly t: 'kw'; readonly k: Kw }

/** `Math.Sf`: which surface. */
export type Sf = 'latex' | 'typst'

const KW_CACHE = new Map<Kw, Tok>()

/** The keyword token `k` (shared, immutable). */
export function kw(k: Kw): Tok {
  let t = KW_CACHE.get(k)
  if (t === undefined) {
    t = Object.freeze({ t: 'kw', k })
    KW_CACHE.set(k, t)
  }
  return t
}

export const tNum = (n: JNum): Tok => ({ t: 'num', n })
export const tLetter = (c: string): Tok => ({ t: 'letter', c })
export const tGreek = (s: string): Tok => ({ t: 'greek', s })
export const tWord = (s: string): Tok => ({ t: 'word', s })
export const tIt = (s: string): Tok => ({ t: 'it', s })
export const tRm = (s: string): Tok => ({ t: 'rm', s })
export const tUps = (ps: readonly (readonly [string, string])[]): Tok => ({ t: 'ups', ps })
export const tOpn = (s: string): Tok => ({ t: 'opn', s })
export const tTxt = (s: string): Tok => ({ t: 'txt', s })
export const tJstr = (s: string): Tok => ({ t: 'jstr', s })
export const tEsc = (s: string): Tok => ({ t: 'esc', s })
export const tCode = (j: Json): Tok => ({ t: 'code', j })
export const tUnits = (l: readonly Factor[]): Tok => ({ t: 'units', l })
export const tAcols = (n: number): Tok => ({ t: 'acols', n })

/** The token is the keyword `k`. */
export function isKwTok(t: Tok | undefined, k: Kw): boolean {
  return t !== undefined && t.t === 'kw' && t.k === k
}

/** Structural equality of two tokens (Rust's derived `PartialEq`). */
export function tokEq(a: Tok, b: Tok): boolean {
  if (a === b) return true
  switch (a.t) {
    case 'num':
      return b.t === 'num' && jnumEq(a.n, b.n)
    case 'letter':
      return b.t === 'letter' && a.c === b.c
    case 'ups':
      return (
        b.t === 'ups' &&
        a.ps.length === b.ps.length &&
        a.ps.every((p, i) => p[0] === b.ps[i][0] && p[1] === b.ps[i][1])
      )
    case 'code':
      return b.t === 'code' && jsonEq(a.j, b.j)
    case 'units':
      return b.t === 'units' && factorsEq(a.l, b.l)
    case 'kw':
      return b.t === 'kw' && a.k === b.k
    case 'acols':
      return b.t === 'acols' && a.n === b.n
    default:
      return b.t === a.t && (b as { s: string }).s === a.s
  }
}
