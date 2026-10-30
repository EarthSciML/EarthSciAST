/**
 * parse-reaction.ts — the inverse of the reaction printer (`toAscii(reaction)`).
 *
 * Parses a single chemical reaction written in the text DSL, e.g.
 *
 *     2 NO + O3 -> [k1] NO2 + O2
 *     CH4 + OH -> [arr(2.45e-12, 1775)] CH3O2 + H2O
 *     -> [k_emit] O3            (source: ∅ → X, empty reactant side)
 *     O3 -> [k_dep]             (sink:   X → ∅, empty product side)
 *
 * Grammar:
 *   reaction := side? arrow rate? side?
 *   arrow    := '->' | '→' | '⟶'
 *   rate     := '[' expression ']'      (required — a reaction must have a rate)
 *   side     := term ('+' term)*        (empty / '∅' ⇒ null: a source or sink)
 *   term     := coefficient? species
 *   coefficient := positive finite number (default 1; fractional yields allowed)
 *   species  := any run of non-whitespace characters (a chemical formula token)
 *
 * The rate is parsed with the shared {@link parseExpression}, so a rate is any
 * expression the DSL accepts (a parameter name, a number, an operator tree, a
 * template application, …). The returned reaction carries an empty `id` — the
 * caller (e.g. the editor merging into an existing reaction) supplies id/name.
 */

import { parseExpression, ExpressionParseError } from './parse-expression.js'
import type { Reaction, StoichiometryEntry } from './types.js'

const isDigit = (c: string | undefined): boolean => c !== undefined && c >= '0' && c <= '9'
const isSpace = (c: string): boolean => /\s/.test(c)

/**
 * Split a term into its optional coefficient and its species token, as the
 * regex `^(\d*\.?\d+(?:[eE][-+]?\d+)?)?\s*(\S+)$` would: the coefficient is
 * the LONGEST number prefix that still leaves `\s*\S+` (a species with no
 * spaces) after it, so `22` is coefficient 2 of species `2` and `1e5` is
 * coefficient 1 of species `e5`. Returns null when the term has no such
 * split. A scan rather than that regex, whose adjacent digit runs backtrack
 * polynomially on a long run of digits.
 */
function splitTerm(term: string): { coefficient: string | undefined; species: string } | null {
  const n = term.length
  let lastSpace = -1
  for (let i = 0; i < n; i++) if (isSpace(term[i]!)) lastSpace = i
  // The species after a coefficient ending at k: skip spaces, then the rest
  // must be non-empty and contain no space.
  const speciesAfter = (k: number): string | null => {
    let j = k
    while (j < n && isSpace(term[j]!)) j++
    return j < n && j > lastSpace ? term.slice(j) : null
  }

  // Every prefix length that is a number, longest first. A mantissa is
  // `\d+` or `\d*\.\d+`; an exponent can only follow the longest mantissa,
  // since every shorter one is followed by a digit.
  const ends: number[] = []
  let a = 0
  while (isDigit(term[a])) a++
  for (let k = 1; k <= a; k++) ends.push(k)
  let mantissaEnd = a
  if (term[a] === '.' && isDigit(term[a + 1])) {
    let b = a + 1
    while (isDigit(term[b])) b++
    for (let k = a + 2; k <= b; k++) ends.push(k)
    mantissaEnd = b
  }
  if (mantissaEnd > 0 && (term[mantissaEnd] === 'e' || term[mantissaEnd] === 'E')) {
    let p = mantissaEnd + 1
    if (term[p] === '+' || term[p] === '-') p++
    let c = p
    while (isDigit(term[c])) c++
    for (let k = p + 1; k <= c; k++) ends.push(k)
  }
  // Only the last candidate of each run can be followed by spaces; for every
  // other one the species scan stops at once, so this stays linear.
  for (let i = ends.length - 1; i >= 0; i--) {
    const k = ends[i]!
    const species = speciesAfter(k)
    if (species !== null) return { coefficient: term.slice(0, k), species }
  }
  const species = speciesAfter(0)
  return species === null ? null : { coefficient: undefined, species }
}

/**
 * Locate the reaction arrow (`->`, `→`, or `⟶`) at bracket depth 0, so an
 * arrow-like sequence inside a bracketed rate is never mistaken for it.
 */
function findArrow(s: string): { index: number; length: number } | null {
  let depth = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '[' || c === '(' || c === '{') depth++
    else if (c === ']' || c === ')' || c === '}') depth = Math.max(0, depth - 1)
    else if (depth === 0) {
      if (c === '-' && s[i + 1] === '>') return { index: i, length: 2 }
      if (c === '→' /* → */ || c === '⟶' /* ⟶ */) return { index: i, length: 1 }
    }
  }
  return null
}

/** Index of the `]` matching the `[` at `open`, or -1 if unbalanced. */
function matchBracket(s: string, open: number): number {
  let depth = 0
  for (let i = open; i < s.length; i++) {
    if (s[i] === '[') depth++
    else if (s[i] === ']') {
      depth--
      if (depth === 0) return i
    }
  }
  return -1
}

/**
 * Parse one side of a reaction into stoichiometry entries, or `null` for an
 * empty side (a source or sink). `∅` is accepted as an explicit empty set.
 */
function parseSide(str: string, offset: number): Reaction['substrates'] {
  const t = str.trim()
  if (t === '' || t === '∅' /* ∅ */) return null

  const entries: StoichiometryEntry[] = []
  for (const raw of t.split('+')) {
    const term = raw.trim()
    if (term === '') {
      throw new ExpressionParseError('Empty term in reaction side (a stray "+"?)', offset)
    }
    const m = splitTerm(term)
    if (!m) {
      throw new ExpressionParseError(`Could not parse reaction term "${term}"`, offset)
    }
    const coefficient = m.coefficient === undefined ? 1 : Number(m.coefficient)
    if (!(coefficient > 0) || !Number.isFinite(coefficient)) {
      throw new ExpressionParseError(
        `Stoichiometric coefficient must be positive and finite (got "${m.coefficient}")`,
        offset,
      )
    }
    entries.push({ species: m.species, stoichiometry: coefficient })
  }
  // A non-empty side always yields ≥1 entry, matching the schema's non-empty
  // tuple type for substrates/products.
  return entries as Reaction['substrates']
}

/**
 * Parse a single reaction from its text-DSL form. Throws
 * {@link ExpressionParseError} on any malformed input (the editor surfaces the
 * message and blocks the edit). The returned reaction's `id` is empty — the
 * caller assigns identity when merging into an existing reaction.
 */
export function parseReaction(src: string): Reaction {
  const s = src.trim()
  if (s === '') throw new ExpressionParseError('Empty reaction', 0)

  const arrow = findArrow(s)
  if (!arrow) {
    throw new ExpressionParseError("Expected a reaction arrow ('->' or '→')", s.length)
  }

  const lhsStr = s.slice(0, arrow.index)
  let after = s.slice(arrow.index + arrow.length)
  const afterOffset = arrow.index + arrow.length

  // Optional rate bracket, which follows the arrow directly (a species never
  // starts with '['), read with balanced-bracket matching so a rate expression
  // may itself contain brackets.
  let rateStr: string | null = null
  if (/^\s*\[/.test(after)) {
    const open = after.indexOf('[')
    const close = matchBracket(after, open)
    if (close === -1) {
      throw new ExpressionParseError('Unterminated rate bracket "["', afterOffset + open)
    }
    rateStr = after.slice(open + 1, close).trim()
    after = after.slice(close + 1)
  }

  const substrates = parseSide(lhsStr, 0)
  const products = parseSide(after, afterOffset)

  if (substrates === null && products === null) {
    throw new ExpressionParseError('A reaction needs at least one reactant or product', 0)
  }
  if (rateStr === null || rateStr === '') {
    throw new ExpressionParseError('A reaction needs a rate, e.g. "A -> [k] B"', s.length)
  }

  const rate = parseExpression(rateStr) as Reaction['rate']

  return { id: '', substrates, products, rate }
}
