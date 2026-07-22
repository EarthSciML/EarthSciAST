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

/** A term's coefficient (optional) followed by a species token with no spaces. */
const TERM_RE = /^(\d*\.?\d+(?:[eE][-+]?\d+)?)?\s*(\S+)$/

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
    const m = TERM_RE.exec(term)
    if (!m) {
      throw new ExpressionParseError(`Could not parse reaction term "${term}"`, offset)
    }
    const coefficient = m[1] === undefined ? 1 : Number(m[1])
    if (!(coefficient > 0) || !Number.isFinite(coefficient)) {
      throw new ExpressionParseError(
        `Stoichiometric coefficient must be positive and finite (got "${m[1]}")`,
        offset,
      )
    }
    entries.push({ species: m[2], stoichiometry: coefficient })
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
