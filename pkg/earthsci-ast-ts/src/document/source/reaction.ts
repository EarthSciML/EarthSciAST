/**
 * Reaction sides, shared by the containers.
 *
 * Port of `formal/Esm/Document/Source/Reaction.lean` (after the Rust binding's
 * `document/source/reaction.rs`). A side is the empty-set symbol as math for an
 * empty side, otherwise its terms separated by ` + `; a term is its coefficient
 * as math and a space (left out when it is 1), then the species, bare when
 * formula-shaped and otherwise its name as math under the empty symbol table.
 */

import { isIntN, jnum, jstr, mkInt, type Json } from '../json.js'
import { isFormula, nameOk, numOk } from '../math/index.js'
import type { Chars, Read } from '../number.js'
import { isIdentChar } from '../strings.js'
import type { Term } from './skeleton.js'
import { preS, str, takeWhile } from './text.js'

/**
 * `Source.RSurf`: how a math piece prints and reads back (under the empty
 * symbol table), and the content of the empty-set piece.
 */
export interface RSurf {
  readonly pm: (s: string) => Json | undefined
  readonly prm: (j: Json) => string
  readonly empty: string
}

/** `Source.isAlnumC`. */
const isAlnumC = (c: string): boolean => c.length === 1 && /[A-Za-z0-9]/.test(c)

/** `Source.speciesTxt`. */
function speciesTxt(r: RSurf, n: string): string {
  return isFormula(n) ? n : `$${r.prm(jstr(n))}$`
}

/** `Source.termTxt`. */
function termTxt(r: RSurf, t: Term): string {
  const c = isIntN(t.coef, 1) ? '' : `$${r.prm(jnum(t.coef))}$ `
  return c + speciesTxt(r, t.species)
}

/** `Source.sideTxt`. */
export function sideTxt(r: RSurf, s: readonly Term[] | undefined): string {
  if (s === undefined) return `$${r.empty}$`
  return s.map((t) => termTxt(r, t)).join(' + ')
}

/** `Source.termOK`. */
function termOk(r: RSurf, t: Term): boolean {
  const ps = r.prm(jstr(t.species))
  if (!nameOk(t.species)) return false
  if (!(isFormula(t.species) || (!ps.includes('$') && ps !== r.empty))) return false
  if (isIntN(t.coef, 1)) return true
  const pc = r.prm(jnum(t.coef))
  return numOk(t.coef) && !pc.includes('$') && pc !== r.empty
}

/** `Source.sideOK`. */
export function sideOk(r: RSurf, s: readonly Term[] | undefined): boolean {
  return s === undefined || (s.length > 0 && s.every((t) => termOk(r, t)))
}

/** `Source.idChar`. */
export const idChar = (c: string): boolean => isIdentChar(c) || c === '-' || c === '.' || c === ':'

/** `Source.idOK`: a reaction id the containers spell as a label. */
export function idOk(i: string): boolean {
  if (i.length === 0) return false
  for (const c of i) if (!idChar(c)) return false
  return true
}

/** `Source.pPiece`: the text up to the next `$`, and the index after it. */
export function pPiece(cs: Chars, i: number): Read<string> {
  const e = takeWhile(cs, i, (c) => c !== '$')
  return cs[e] === '$' ? [str(cs, i, e), e + 1] : undefined
}

/** `Source.pSpecies`: a math piece holding a name, or a bare run of letters and digits. */
function pSpecies(r: RSurf, cs: Chars, i: number): Read<string> {
  if (cs[i] === '$') {
    const p = pPiece(cs, i + 1)
    if (p === undefined) return undefined
    const j = r.pm(p[0])
    return j !== undefined && j.t === 'str' ? [j.s, p[1]] : undefined
  }
  const e = takeWhile(cs, i, isAlnumC)
  return e === i ? undefined : [str(cs, i, e), e]
}

/** `Source.pTerm`. */
function pTerm(r: RSurf, cs: Chars, i: number): Read<Term> {
  if (cs[i] === '$') {
    const p = pPiece(cs, i + 1)
    if (p === undefined) return undefined
    const j = r.pm(p[0])
    if (j === undefined) return undefined
    if (j.t === 'num') {
      if (cs[p[1]] !== ' ') return undefined
      const sp = pSpecies(r, cs, p[1] + 1)
      return sp && [{ species: sp[0], coef: j.n }, sp[1]]
    }
    if (j.t === 'str') return [{ species: j.s, coef: mkInt(1) }, p[1]]
    return undefined
  }
  const sp = pSpecies(r, cs, i)
  return sp && [{ species: sp[0], coef: mkInt(1) }, sp[1]]
}

/** `Source.pTerms`: terms separated by ` + `. */
function pTerms(r: RSurf, cs: Chars, i: number): Read<Term[]> {
  const out: Term[] = []
  for (;;) {
    const t = pTerm(r, cs, i)
    if (t === undefined) return undefined
    out.push(t[0])
    if (!preS(' + ', cs, t[1])) return [out, t[1]]
    i = t[1] + 3
  }
}

/** `Source.pSide`: the empty-set piece (`null`), or terms. */
export function pSide(r: RSurf, cs: Chars, i: number): Read<Term[] | null> {
  if (cs[i] === '$') {
    const p = pPiece(cs, i + 1)
    if (p === undefined) return undefined
    if (p[0] === r.empty) return [null, p[1]]
  }
  return pTerms(r, cs, i)
}
