/**
 * The math surfaces: LaTeX (Markdown documents) and Typst math.
 *
 * Port of `formal/Esm/Document/Math/` (after the Rust binding's
 * `document/math/mod.rs`). One token type ({@link Tok}) serves both surfaces;
 * {@link print} writes an expression's tokens under a symbol table, each
 * surface renders and lexes its own spelling, and {@link parseToks} reads the
 * tokens of either surface back.
 *
 * | TypeScript | Lean |
 * |---|---|
 * | `expr.ts` | `Expr.lean` |
 * | `token.ts` | `Token.lean` |
 * | `surface.ts` | `Surface.lean` |
 * | `print.ts` | `Print.lean` |
 * | `parse.ts` | `Parse.lean`, `parseToks` of `Induct.lean`, `need` of `RoundTrip.lean` |
 * | `latex.ts` | `Latex.lean` |
 * | `typst.ts` | `Typst.lean` |
 * | `units.ts` | `Units/Typeset.lean` |
 *
 * The other Lean files under `Math/` hold the round-trip proofs and the
 * predicates they are stated with; they have no executable definitions the
 * printer or the parser use. `HandWritten.lean`'s checks are unit tests in
 * `math.test.ts`.
 */

import type { Json } from '../json.js'
import type { Sym } from './expr.js'
import { lex as latexLex, render as latexRender } from './latex.js'
import { parseToks as parseToksImpl } from './parse.js'
import { pa, print as printImpl } from './print.js'
import type { Sf, Tok } from './token.js'
import { lex as typstLex, render as typstRender } from './typst.js'

export {
  DEPRECATED_OPS,
  REMOVED_OPS,
  isDig,
  isE,
  isFormula,
  isLetter,
  jwf,
  keysSorted,
  look,
  nameOk,
  numOk,
  type Sym,
} from './expr.js'
export { escT, rawB, unescT } from './print.js'
export { isKwTok, kw, tokEq, type Kw, type Sf, type Tok } from './token.js'
export { type Factor, type Rat } from './units.js'
export { latexLex, latexRender, typstLex, typstRender }

/** `Math.print` (Print.lean): the tokens of an expression under the symbol table `s`. */
export function print(sf: Sf, s: Sym, e: Json): Tok[] {
  return printImpl(sf, s, e)
}

/** `Math.parseToks` (Induct.lean): read a token list back under the symbol table `s`. */
export function parseToks(sf: Sf, s: Sym, toks: readonly Tok[]): Json | undefined {
  return parseToksImpl(sf, s, toks)
}

/**
 * `Math.printLatex` (RoundTripLatex.lean): an expression (an `==` at its top is a
 * comparison and prints as any expression does).
 */
export function printLatex(s: Sym, e: Json): string {
  return latexRender(pa({ sf: 'latex', s }, 1, e))
}

/**
 * `Math.printLatexEqn` (RoundTripLatex.lean): an equation's expression,
 * `==(lhs, rhs)`, in its defining form when it has one.
 */
export function printLatexEqn(s: Sym, e: Json): string {
  return latexRender(print('latex', s, e))
}

/** `Math.parseLatex` (RoundTripLatex.lean). */
export function parseLatex(s: Sym, text: string): Json | undefined {
  const toks = latexLex(Array.from(text))
  return toks === undefined ? undefined : parseToks('latex', s, toks)
}

/**
 * `Math.printTypst` (RoundTripTypst.lean): an expression (an `==` at its top is a
 * comparison, as in an event's condition, and prints as any expression does).
 */
export function printTypst(s: Sym, e: Json): string {
  return typstRender(pa({ sf: 'typst', s }, 1, e))
}

/**
 * `Math.printTypstEqn` (RoundTripTypst.lean): an equation's expression,
 * `==(lhs, rhs)`, in its defining form `x_s = …, s in S` when it has one.
 */
export function printTypstEqn(s: Sym, e: Json): string {
  return typstRender(print('typst', s, e))
}

/** `Math.parseTypst` (RoundTripTypst.lean). */
export function parseTypst(s: Sym, text: string): Json | undefined {
  const toks = typstLex(Array.from(text))
  return toks === undefined ? undefined : parseToks('typst', s, toks)
}
