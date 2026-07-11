/**
 * Pretty-printing formatters for ESM format expressions, equations, models, and files.
 *
 * Public output formats:
 * - toUnicode(): Unicode mathematical notation with chemical subscripts
 * - toLatex(): LaTeX mathematical notation
 * - toAscii(): Plain text representation
 * - toMathML(): MathML markup for web / academic publishing
 * - formatChemicalName(): Unicode chemical-subscript rendering of a bare name
 *
 * The per-format rendering of each operator lives in one place — the
 * {@link OP_RENDERERS} table — so adding an operator is a single entry
 * (op-registry.ts:10-12).
 *
 * Based on ESM Format Specification Section 6.1
 */

import type { Expr, Equation, Model, EsmFile, ReactionSystem, ExprNode } from './types.js'
import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { opPrecedence, isFunctionCallOp } from './op-registry.js'
import { isExprNode } from './expression.js'

// Element lookup table for chemical subscript detection (118 elements)
const ELEMENTS = new Set([
  // Period 1
  'H',
  'He',
  // Period 2
  'Li',
  'Be',
  'B',
  'C',
  'N',
  'O',
  'F',
  'Ne',
  // Period 3
  'Na',
  'Mg',
  'Al',
  'Si',
  'P',
  'S',
  'Cl',
  'Ar',
  // Period 4
  'K',
  'Ca',
  'Sc',
  'Ti',
  'V',
  'Cr',
  'Mn',
  'Fe',
  'Co',
  'Ni',
  'Cu',
  'Zn',
  'Ga',
  'Ge',
  'As',
  'Se',
  'Br',
  'Kr',
  // Period 5
  'Rb',
  'Sr',
  'Y',
  'Zr',
  'Nb',
  'Mo',
  'Tc',
  'Ru',
  'Rh',
  'Pd',
  'Ag',
  'Cd',
  'In',
  'Sn',
  'Sb',
  'Te',
  'I',
  'Xe',
  // Period 6
  'Cs',
  'Ba',
  'La',
  'Ce',
  'Pr',
  'Nd',
  'Pm',
  'Sm',
  'Eu',
  'Gd',
  'Tb',
  'Dy',
  'Ho',
  'Er',
  'Tm',
  'Yb',
  'Lu',
  'Hf',
  'Ta',
  'W',
  'Re',
  'Os',
  'Ir',
  'Pt',
  'Au',
  'Hg',
  'Tl',
  'Pb',
  'Bi',
  'Po',
  'At',
  'Rn',
  // Period 7
  'Fr',
  'Ra',
  'Ac',
  'Th',
  'Pa',
  'U',
  'Np',
  'Pu',
  'Am',
  'Cm',
  'Bk',
  'Cf',
  'Es',
  'Fm',
  'Md',
  'No',
  'Lr',
  'Rf',
  'Db',
  'Sg',
  'Bh',
  'Hs',
  'Mt',
  'Ds',
  'Rg',
  'Cn',
  'Nh',
  'Fl',
  'Mc',
  'Lv',
  'Ts',
  'Og',
])

// Unicode subscripts for digits 0-9
const SUBSCRIPT_DIGITS = '₀₁₂₃₄₅₆₇₈₉'

// Unicode superscripts for digits 0-9 and signs
const SUPERSCRIPT_MAP: Record<string, string> = {
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
  '+': '⁺',
  '-': '⁻',
}
function toSuperscript(text: string): string {
  return text
    .split('')
    .map((c) => SUPERSCRIPT_MAP[c] || c)
    .join('')
}

// ---------------------------------------------------------------------------
// Greek letters: ONE canonical table drives every derived lookup and regex
// below (LaTeX/unicode/ascii/MathML). Each row is
//   [asciiName, lowerChar, upperChar, hasUpperLatex]
// where `hasUpperLatex` marks the uppercase forms with a distinct LaTeX
// command (`\Gamma`, ...); the rest look like Latin capitals and carry none.
// ---------------------------------------------------------------------------
const GREEK_TABLE: ReadonlyArray<readonly [string, string, string, boolean]> = [
  ['alpha', 'α', 'Α', false],
  ['beta', 'β', 'Β', false],
  ['gamma', 'γ', 'Γ', true],
  ['delta', 'δ', 'Δ', true],
  ['epsilon', 'ε', 'Ε', false],
  ['zeta', 'ζ', 'Ζ', false],
  ['eta', 'η', 'Η', false],
  ['theta', 'θ', 'Θ', true],
  ['iota', 'ι', 'Ι', false],
  ['kappa', 'κ', 'Κ', false],
  ['lambda', 'λ', 'Λ', true],
  ['mu', 'μ', 'Μ', false],
  ['nu', 'ν', 'Ν', false],
  ['xi', 'ξ', 'Ξ', true],
  ['omicron', 'ο', 'Ο', false],
  ['pi', 'π', 'Π', true],
  ['rho', 'ρ', 'Ρ', false],
  ['sigma', 'σ', 'Σ', true],
  ['tau', 'τ', 'Τ', false],
  ['upsilon', 'υ', 'Υ', true],
  ['phi', 'φ', 'Φ', true],
  ['chi', 'χ', 'Χ', false],
  ['psi', 'ψ', 'Ψ', true],
  ['omega', 'ω', 'Ω', true],
]

/** `Name` with an initial capital (`alpha` → `Alpha`). */
function capitalize(name: string): string {
  return name[0].toUpperCase() + name.slice(1)
}

// LaTeX: named lowercase → `\name`, lowercase Unicode char → `\name`, and the
// distinct uppercase names → `\Name`. Uppercase Unicode chars are intentionally
// absent (they pass through unchanged, preserving prior behavior).
const GREEK_LETTERS: Record<string, string> = {}
// Named lowercase → Unicode symbol (unicode output).
const GREEK_NAME_TO_CHAR: Record<string, string> = {}
// Lowercase Unicode char → ascii name (ascii output).
const GREEK_CHAR_TO_NAME: Record<string, string> = {}
// Both-case Unicode char → MathML entity.
const GREEK_CHAR_TO_ENTITY: Record<string, string> = {}
for (const [name, lower, upper, hasUpperLatex] of GREEK_TABLE) {
  GREEK_LETTERS[name] = `\\${name}`
  GREEK_LETTERS[lower] = `\\${name}`
  if (hasUpperLatex) GREEK_LETTERS[capitalize(name)] = `\\${capitalize(name)}`
  GREEK_NAME_TO_CHAR[name] = lower
  GREEK_CHAR_TO_NAME[lower] = name
  GREEK_CHAR_TO_ENTITY[lower] = `&${name};`
  GREEK_CHAR_TO_ENTITY[upper] = `&${capitalize(name)};`
}

// Alternation of the 24 lowercase names, in canonical order, shared by every
// name-matching regex below.
const GREEK_NAME_GROUP = `(?:${GREEK_TABLE.map(([name]) => name).join('|')})`
// Unicode Greek code-point range (lower + upper).
const GREEK_CHAR_CLASS = '[α-ωΑ-Ω]'
// LaTeX: a Greek char OR a named letter not followed by an uppercase letter
// (chemical prefix) or `}` (already inside \mathrm{}).
const GREEK_LATEX_RE = new RegExp(`${GREEK_CHAR_CLASS}|${GREEK_NAME_GROUP}(?![A-Z}])`, 'g')
// Unicode: a named letter not followed by an uppercase letter (chemical prefix).
const GREEK_UNICODE_RE = new RegExp(`${GREEK_NAME_GROUP}(?![A-Z])`, 'g')
// ASCII / MathML: bare Greek Unicode chars.
const GREEK_CHAR_RE = new RegExp(GREEK_CHAR_CLASS, 'g')
// MathML: bare named letters (no lookahead).
const GREEK_NAME_RE = new RegExp(GREEK_NAME_GROUP, 'g')

function convertGreekLetters(text: string, format: 'unicode' | 'latex' | 'ascii'): string {
  if (format === 'latex') {
    // Negative lookahead (?![A-Z}]) prevents conversion when followed by uppercase
    // (chemical prefix) or closing brace (inside \mathrm{}).
    return text.replace(GREEK_LATEX_RE, (match) => GREEK_LETTERS[match] || match)
  } else if (format === 'unicode') {
    // Negative lookahead (?![A-Z]) prevents conversion when followed by uppercase.
    return text.replace(GREEK_UNICODE_RE, (match) => GREEK_NAME_TO_CHAR[match] || match)
  } else if (format === 'ascii') {
    return text.replace(GREEK_CHAR_RE, (match) => GREEK_CHAR_TO_NAME[match] || match)
  }

  return text
}

/**
 * One token of a chemical-formula scan: either a recognized element symbol
 * (with the run of digits that immediately follows it grouped in), or a single
 * non-element character.
 */
type ChemToken = { element: string; digits: string } | { other: string }

/**
 * Greedy 2-char-before-1-char element tokenizer — the ONE scanner shared by
 * the unicode subscript formatter, the MathML variable formatter, and the
 * pure-formula detector. Digits immediately following a matched element are
 * grouped into that element's token; every other character becomes an `other`
 * token.
 */
function scanElements(s: string): ChemToken[] {
  const tokens: ChemToken[] = []
  let i = 0
  while (i < s.length) {
    let sym: string | undefined
    if (i + 1 < s.length && ELEMENTS.has(s.slice(i, i + 2))) {
      sym = s.slice(i, i + 2)
    } else if (ELEMENTS.has(s[i])) {
      sym = s[i]
    }
    if (sym !== undefined) {
      i += sym.length
      let digits = ''
      while (i < s.length && /\d/.test(s[i])) {
        digits += s[i]
        i++
      }
      tokens.push({ element: sym, digits })
    } else {
      tokens.push({ other: s[i] })
      i++
    }
  }
  return tokens
}

/**
 * Convert every digit run in a chemical formula to its LaTeX subscript form
 * (`H2O` → `H_2O`, `CO12` → `CO_{12}`), WITHOUT the `\mathrm{}` wrapper. This
 * is the "inner content" a mixed prefix+suffix variable embeds, so callers no
 * longer format-then-regex-strip their own `\mathrm{}` output.
 */
function latexChemicalInner(formula: string): string {
  return formula.replace(/(\d+)/g, (_m, digits: string) =>
    digits.length === 1 ? `_${digits}` : `_{${digits}}`,
  )
}

/**
 * Peel one leading `\mathrm{` and one trailing `}` (independently), reproducing
 * the historical `.replace(/^\\mathrm\{|\}$/g, '')` byte-for-byte without a
 * regex. Used only by {@link formatChemicalSuffixInner} for the degenerate
 * embedded-markup case.
 */
function stripOuterMathrm(s: string): string {
  const inner = s.startsWith('\\mathrm{') ? s.slice('\\mathrm{'.length) : s
  return inner.endsWith('}') ? inner.slice(0, -1) : inner
}

/**
 * Inner content of a chemical / element-bearing SUFFIX embedded in a larger
 * variable's subscript — the text that belongs INSIDE the enclosing
 * `\mathrm{...}`. Returns that content directly (the "render inner tokens" step,
 * split from the "wrap in `\mathrm{}`" step) so the mixed LaTeX path no longer
 * formats a full `\mathrm{...}` only to regex-strip its own wrapper.
 *
 * Precondition: `hasElementPattern(variable)` holds — guaranteed by
 * {@link getChemicalSuffix} at the sole call site in {@link formatChemicalLatex}.
 *
 * Common cases return their inner content with no wrapper: a bare element symbol
 * stays italic; a pure formula becomes {@link latexChemicalInner}. The one path
 * that cannot avoid a wrapper is a suffix that itself embeds LaTeX markup (e.g.
 * `{NO_O3}` from a variable named `k_{NO_O3}`, or a stray leading digit as in
 * `2CO2`): it recursively splits into a further prefix + chemical part, whose
 * mixed rendering is `prefix_{\mathrm{...}}`; {@link stripOuterMathrm} peels the
 * outer markup to keep output byte-identical to the former regex surgery.
 */
function formatChemicalSuffixInner(variable: string): string {
  if (getChemicalSuffix(variable)) {
    return stripOuterMathrm(formatChemicalLatex(variable))
  }
  // Bare element symbol without digits (e.g. "N") renders italic, unwrapped.
  if (ELEMENTS.has(variable) && !/\d/.test(variable)) return variable
  // Pure chemical formula: digit runs → subscripts, no wrapper.
  return latexChemicalInner(variable)
}

/** LaTeX chemical/variable subscript formatting (see {@link formatChemicalSubscripts}). */
function formatChemicalLatex(variable: string): string {
  const hasElements = hasElementPattern(variable)

  // First check if it's a mixed variable (non-element prefix + chemical suffix)
  const chemicalInfo = getChemicalSuffix(variable)
  if (chemicalInfo) {
    // Split into prefix and chemical part
    const { prefix, suffix } = chemicalInfo

    // Check if suffix has multiple segments that should be separate subscripts
    // Split when: first segment ends with digits (complete formula), or prefix is multi-char
    if (suffix.includes('_')) {
      const segments = suffix.split('_')
      const shouldSplit = /\d$/.test(segments[0]) || prefix.length > 1
      if (shouldSplit) {
        // Format prefix
        let result: string
        if (prefix.length === 1 && /[A-Za-z]/.test(prefix)) {
          result = prefix
        } else {
          result = `\\mathrm{${prefix}}`
        }
        // Each segment becomes a separate subscript
        for (const seg of segments) {
          if (hasElementPattern(seg)) {
            result += `_{\\mathrm{${latexChemicalInner(seg)}}}`
          } else {
            result += `_\\mathrm{${seg}}`
          }
        }
        return result
      }
    }

    // Render the suffix's inner tokens directly (no format-then-strip). The
    // suffix need NOT be a clean pure formula — a variable name may embed LaTeX
    // markup — which {@link formatChemicalSuffixInner} handles so output stays
    // byte-identical.
    const innerContent = formatChemicalSuffixInner(suffix)
    // Wrap multi-char prefix in \mathrm{}, single-char stays italic
    const formattedPrefix = prefix.length > 1 ? `\\mathrm{${prefix}}` : prefix
    return `${formattedPrefix}_{\\mathrm{${innerContent}}}`
  }

  if (hasElements) {
    // A bare element symbol without digits (e.g. "B", "C", "N") is treated
    // as a variable name, not a chemical formula
    if (ELEMENTS.has(variable) && !/\d/.test(variable)) {
      return variable
    }
    // Pure chemical formula: wrap in \mathrm{} and convert digits to subscripts
    return `\\mathrm{${latexChemicalInner(variable)}}`
  } else {
    // Regular variable (not chemical)
    // Greek letter (Unicode or named) → return as-is (convertGreekLetters handles later)
    if (GREEK_LETTERS[variable]) {
      return variable
    }
    // Single letter + digits → italic with subscript (e.g., T_{298}, x_1)
    const singleLetterMatch = variable.match(/^([A-Za-z\u0391-\u03C9])(\d+)$/)
    if (singleLetterMatch) {
      const [, letter, digits] = singleLetterMatch
      return digits.length === 1 ? `${letter}_${digits}` : `${letter}_{${digits}}`
    }
    // Single letter (Latin or Greek) → italic (no wrapping)
    if (variable.length === 1) {
      return variable
    }
    // Handle underscore-separated variables with mixed segments
    if (variable.includes('_')) {
      const parts = variable.split('_')
      const anyChemical = parts.some((p) => hasElementPattern(p))
      if (anyChemical) {
        // Segment-by-segment: base + subscripts
        let result: string
        const base = parts[0]
        if (base.length === 1 && /[A-Za-z]/.test(base)) {
          result = base
        } else if (hasElementPattern(base)) {
          result = formatChemicalLatex(base)
        } else {
          result = `\\mathrm{${base}}`
        }
        for (let i = 1; i < parts.length; i++) {
          const part = parts[i]
          if (hasElementPattern(part)) {
            result += `_{\\mathrm{${latexChemicalInner(part)}}}`
          } else {
            result += `_\\mathrm{${part}}`
          }
        }
        return result
      }
      // No chemical segments → plain multi-word variable
      const escaped = variable.replace(/_/g, '\\_')
      return `\\mathrm{${escaped}}`
    }
    // Multi-character → \mathrm{}
    return `\\mathrm{${variable}}`
  }
}

/** Unicode chemical/variable subscript formatting (see {@link formatChemicalSubscripts}). */
function formatChemicalUnicode(variable: string): string {
  const hasElements = hasElementPattern(variable)

  if (!hasElements) {
    // Check if it's a mixed variable (non-element prefix + chemical suffix)
    const chemicalInfo = getChemicalSuffix(variable)
    if (chemicalInfo) {
      // Split into prefix and chemical part
      const { prefix, suffix } = chemicalInfo
      const chemicalPart = formatChemicalUnicode(suffix)
      // For variables without underscores (like jNO2), don't add underscores
      if (!variable.includes('_')) {
        return `${prefix}${chemicalPart}`
      }
      // For variables with underscores (like k_NO_O3), preserve them
      return `${prefix}_${chemicalPart}`
    }
    // Handle underscore-separated variables with mixed chemical/non-chemical segments
    if (variable.includes('_')) {
      const parts = variable.split('_')
      const anyChemical = parts.some((p) => hasElementPattern(p))
      if (anyChemical) {
        return parts
          .map((part) => (hasElementPattern(part) ? formatChemicalUnicode(part) : part))
          .join('_')
      }
    }
    // No element pattern found, return as-is
    return variable
  }

  // Element-aware subscript detection via the shared tokenizer. Elements keep
  // their digits as subscripts; stray digits (e.g. after a closing
  // parenthesis) are subscripted too, other characters copied verbatim.
  let result = ''
  for (const t of scanElements(variable)) {
    if ('element' in t) {
      result += t.element
      for (const d of t.digits) result += SUBSCRIPT_DIGITS[parseInt(d)]
    } else if (/\d/.test(t.other)) {
      result += SUBSCRIPT_DIGITS[parseInt(t.other)]
    } else {
      result += t.other
    }
  }

  return result
}

/**
 * Apply element-aware chemical subscript formatting to a variable name.
 * Uses greedy 2-char-before-1-char matching for element detection. Dispatches
 * to the per-format implementation.
 */
function formatChemicalSubscripts(variable: string, format: 'unicode' | 'latex'): string {
  return format === 'latex' ? formatChemicalLatex(variable) : formatChemicalUnicode(variable)
}

/**
 * Extract chemical formula suffix from a variable name
 */
function getChemicalSuffix(variable: string): { prefix: string; suffix: string } | null {
  // Handle patterns like k_NO_O3 (with underscore)
  if (variable.includes('_')) {
    const parts = variable.split('_')
    if (parts.length === 2) {
      const [prefix, suffix] = parts
      if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
        return { prefix, suffix }
      }
    }
    // For patterns like k_NO_O3, try treating NO_O3 as the chemical part
    if (parts.length === 3) {
      const prefix = parts[0]
      const suffix = parts.slice(1).join('_') // Keep underscore within chemical formula
      if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
        return { prefix, suffix }
      }
    }
  }

  // Handle patterns like jNO2 (without underscore)
  // Try each position to split into non-element prefix and element suffix
  for (let i = 1; i < variable.length; i++) {
    const prefix = variable.substring(0, i)
    const suffix = variable.substring(i)

    if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
      return { prefix, suffix }
    }
  }

  return null
}

/**
 * Check if a variable has element patterns (for chemical formula detection)
 * Must be PURELY a chemical formula (no non-element characters)
 */
function hasElementPattern(variable: string): boolean {
  // Remove underscores for pure chemical formula check
  const cleanVariable = variable.replace(/_/g, '')

  let hasElement = false
  for (const t of scanElements(cleanVariable)) {
    if ('element' in t) {
      hasElement = true
    } else if (/[A-Za-z]/.test(t.other)) {
      // A non-element letter means this is not a pure chemical formula.
      return false
    }
    // Non-alphabetic characters (digits, separators) are ignored.
  }

  return hasElement
}

// Scientific-notation cutoffs (spec §6.1): a nonzero number whose magnitude is
// below the min or at/above the max renders in scientific notation.
const SCI_NOTATION_MIN = 0.01
const SCI_NOTATION_MAX = 10000

/**
 * Format a number in scientific notation with appropriate formatting
 */
function formatNumber(num: number, format: 'unicode' | 'latex' | 'ascii'): string {
  // Format according to ESM spec Section 6.1
  if (num === 0) return '0'

  const absNum = Math.abs(num)

  // Use scientific notation for very small or large numbers (spec Section 6.1)
  if (absNum < SCI_NOTATION_MIN || absNum >= SCI_NOTATION_MAX) {
    const str = num.toExponential()
    const [mantissa, exponent] = str.split('e')
    const cleanMantissa = parseFloat(mantissa).toString() // Remove trailing zeros
    const exp = parseInt(exponent)

    if (format === 'unicode') {
      return `${cleanMantissa}×10${toSuperscript(exp.toString())}`
    } else if (format === 'latex') {
      return `${cleanMantissa} \\times 10^{${exp}}`
    } else {
      return `${cleanMantissa}e${exp >= 0 ? '+' : ''}${exp}` // ASCII with explicit sign
    }
  }

  // For integers, show as plain integer
  if (Number.isInteger(num)) {
    const str = num.toString()
    if (format === 'unicode') return str.replace(/^-/, '−')
    return str
  }

  // For decimals, use standard notation
  const str = num.toString()
  if (format === 'unicode') return str.replace(/^-/, '−')
  return str
}

/**
 * Precedence of the loosest-binding operator — logical `or` (= OPS['or'].precedence
 * in op-registry.ts). Inside a function call or a unary-minus operand, only a
 * child at or below this precedence needs parentheses.
 */
const LOOSEST_PRECEDENCE = opPrecedence('or')

/**
 * Left-associative binary operators for which a same-precedence RIGHT operand
 * must be parenthesized (`a - (b - c)`, `a / (b / c)`, `a ^ (b ^ c)`).
 */
const NON_ASSOCIATIVE_RIGHT_OPS = new Set(['-', '/', '^'])

/**
 * Check if parentheses are needed around a subexpression. Precedence and
 * function-call classification come from the central op registry
 * (op-registry.ts).
 */
function needsParentheses(parent: ExprNode, child: Expr, isRightOperand = false): boolean {
  if (typeof child === 'number' || typeof child === 'string' || isNumericLiteral(child)) {
    return false
  }

  const parentPrec = opPrecedence(parent.op)
  // After the leaf check above, the remaining union member is the schema's
  // open node object; its `op` is the operator name string.
  const childPrec = opPrecedence((child as ExprNode).op)

  // Function arguments already sit inside the call's own parentheses — only
  // parenthesize the loosest-binding (logical-or) child expressions.
  if (isFunctionCallOp(parent.op)) {
    return childPrec <= LOOSEST_PRECEDENCE
  }

  // For unary minus, be less aggressive
  if (parent.op === '-' && parent.args.length === 1) {
    return childPrec <= LOOSEST_PRECEDENCE
  }

  if (childPrec < parentPrec) return true
  if (childPrec > parentPrec) return false

  // Same precedence: need parens if child is right operand and operator is not associative
  if (isRightOperand && NON_ASSOCIATIVE_RIGHT_OPS.has(parent.op)) {
    return true
  }

  return false
}

type TextFormat = 'unicode' | 'latex' | 'ascii'

/** The renderable top-level kinds, distinguished once by {@link classifyExpr}. */
type ExprKind = 'numeric' | 'variable' | 'node' | 'equation' | 'file' | 'model' | 'reactionSystem'

/**
 * The ONE type discriminator shared by every top-level entry point
 * ({@link formatAny}, {@link toMathML}): a numeric leaf, a variable name, an
 * expression node, an equation, or a file/model/reaction-system summary.
 * Checked in a fixed order (file before model, since an EsmFile also has the
 * summary fields a Model does not).
 */
function classifyExpr(expr: Expr | Equation | Model | ReactionSystem | EsmFile): ExprKind {
  if (typeof expr === 'number' || isNumericLiteral(expr)) return 'numeric'
  if (typeof expr === 'string') return 'variable'
  if (isExprNode(expr)) return 'node'
  if ('lhs' in expr && 'rhs' in expr) return 'equation'
  if ('models' in expr || 'metadata' in expr) return 'file'
  if ('variables' in expr && 'equations' in expr) return 'model'
  if ('species' in expr && 'reactions' in expr) return 'reactionSystem'
  throw new Error(`Unsupported expression type: ${typeof expr}`)
}

/**
 * Shared type-dispatch for the three text formats: numeric leaf, variable
 * name, expression node, equation, or a file/model/reaction-system summary.
 */
function formatAny(
  expr: Expr | Equation | Model | ReactionSystem | EsmFile,
  format: TextFormat,
): string {
  switch (classifyExpr(expr)) {
    case 'numeric':
      return formatNumber(numericValue(expr)!, format)
    case 'variable': {
      const s = expr as string
      if (format === 'ascii') return convertGreekLetters(s, 'ascii')
      return convertGreekLetters(formatChemicalSubscripts(s, format), format)
    }
    case 'node':
      return formatExpressionNode(expr as ExprNode, format)
    case 'equation': {
      const equation = expr as Equation
      return `${formatAny(equation.lhs, format)} = ${formatAny(equation.rhs, format)}`
    }
    // Summaries (spec Section 6.3) render as text: unicode keeps unicode
    // symbols; latex falls back to plain ascii text.
    case 'file':
      return formatEsmFileSummary(expr as EsmFile)
    case 'model':
      return formatModelSummary(expr as Model, format === 'unicode' ? 'unicode' : 'ascii')
    case 'reactionSystem':
      return formatReactionSystemSummary(expr as ReactionSystem)
  }
}

/**
 * Format an expression as Unicode mathematical notation
 */
export function toUnicode(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
  return formatAny(expr, 'unicode')
}

/**
 * Format an expression as LaTeX mathematical notation
 */
export function toLatex(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
  return formatAny(expr, 'latex')
}

/**
 * Format an expression as plain ASCII text
 */
export function toAscii(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
  return formatAny(expr, 'ascii')
}

/**
 * Apply element-aware chemical subscript formatting to a bare variable /
 * species name using Unicode subscript digits (e.g. "H2SO4" → "H₂SO₄").
 * Exported for graph rendering (toDot / toMermaid labels).
 */
export function formatChemicalName(name: string): string {
  return formatChemicalSubscripts(name, 'unicode')
}

/**
 * Format an expression as MathML markup for web/academic publishing
 */
export function toMathML(expr: Expr | Equation | Model | ReactionSystem | EsmFile): string {
  switch (classifyExpr(expr)) {
    case 'numeric':
      return `<mn>${formatNumber(numericValue(expr)!, 'ascii')}</mn>`
    case 'variable':
      return formatMathMLVariable(expr as string)
    case 'node':
      return formatExpressionNodeMathML(expr as ExprNode)
    case 'equation': {
      const equation = expr as Equation
      return `<math><mrow>${toMathML(equation.lhs)}<mo>=</mo>${toMathML(equation.rhs)}</mrow></math>`
    }
    // Summaries render as plain text inside a MathML <mtext> element.
    case 'file':
      return `<math><mtext>${formatEsmFileSummary(expr as EsmFile)}</mtext></math>`
    case 'model':
      return `<math><mtext>${formatModelSummary(expr as Model, 'ascii')}</mtext></math>`
    case 'reactionSystem':
      return `<math><mtext>${formatReactionSystemSummary(expr as ReactionSystem)}</mtext></math>`
  }
}

/**
 * Format a variable name with chemical subscripts for MathML
 */
function formatMathMLVariable(variable: string): string {
  // Check if variable looks like a chemical formula (starts with element and has digits)
  const hasElements = hasElementPattern(variable)

  if (hasElements) {
    // Pure chemical formula: wrap each element in <mi> and convert following
    // digits to a subscript; non-element characters are copied verbatim.
    let result = ''
    for (const t of scanElements(variable)) {
      if ('element' in t) {
        result += `<mi>${t.element}</mi>`
        if (t.digits) result += `<msub><mi></mi><mn>${t.digits}</mn></msub>`
      } else {
        result += t.other
      }
    }

    return result
  }

  // Check if it's a mixed variable (non-element prefix + chemical suffix)
  const chemicalInfo = getChemicalSuffix(variable)
  if (chemicalInfo) {
    const { prefix, suffix } = chemicalInfo
    return `<mi>${prefix}</mi><msub><mi></mi><mrow>${formatMathMLVariable(suffix)}</mrow></msub>`
  }

  // Regular variable: check for Greek letters
  const greekConverted = convertGreekLettersToMathML(variable)
  return `<mi>${greekConverted}</mi>`
}

/**
 * Convert Greek letters to MathML entities. Only bare Unicode Greek chars are
 * mapped (via {@link GREEK_CHAR_TO_ENTITY}); the second, name-matching pass is
 * historically a no-op (named letters have no entity entry) and is retained
 * for byte-identical output.
 */
function convertGreekLettersToMathML(text: string): string {
  return text
    .replace(GREEK_CHAR_RE, (match) => GREEK_CHAR_TO_ENTITY[match] || match)
    .replace(GREEK_NAME_RE, (match) => GREEK_CHAR_TO_ENTITY[match] || match)
}

/** Escape `<`, `>`, `&` for embedding text inside MathML `<mtext>`. */
function escapeMathMLText(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/**
 * Typed read-only view of the structural / array-query fields that live OUTSIDE
 * `args` on an `ExpressionNode`. Replaces per-site `as unknown as
 * Record<string, unknown>` casts with one named shape. Every field is optional
 * — a given op populates only the slots its rendering reads.
 */
interface StructuralView {
  value?: unknown
  fn?: unknown
  name?: unknown
  var?: unknown
  table?: unknown
  output?: unknown
  manifold?: unknown
  axis?: unknown
  arg?: unknown
  output_idx?: unknown[]
  lower?: Expr
  upper?: Expr
  expr?: Expr
  filter?: Expr
  key?: Expr
  axes?: Record<string, Expr>
  bindings?: Record<string, Expr>
  regions?: unknown[][][]
  values?: Expr[]
  shape?: unknown[]
  perm?: number[]
  semiring?: string
  reduce?: string
  distinct?: boolean
  ranges?: Record<string, unknown>
  join?: Array<{ on?: string[][] }>
}

/** View an `ExpressionNode` through its structural (non-`args`) fields. */
function structuralView(node: ExprNode): StructuralView {
  return node as unknown as StructuralView
}

/**
 * MathML rendering for the structural / array-query ops. `const` and `true`
 * get native tokens; `broadcast` delegates to the scalar-op MathML of its
 * `fn`. Every other structural op is rendered non-lossily by embedding its
 * Unicode text form (from {@link formatStructuralOp}) in `<mtext>` — MathML is
 * TS-only and not part of the cross-language conformance contract. Returns
 * `undefined` for non-structural ops AND for a degenerate structural node that
 * {@link formatStructuralOp} cannot render (so it falls through to the scalar
 * dispatch instead of emitting a literal "undefined").
 */
function formatStructuralOpMathML(node: ExprNode): string | undefined {
  const op = node.op
  const n = structuralView(node)
  if (op === 'const') {
    const v = n.value
    if (Array.isArray(v)) return `<mtext>${escapeMathMLText(formatConstValue(v, 'ascii'))}</mtext>`
    return `<mn>${formatConstValue(v, 'ascii')}</mn>`
  }
  if (op === 'true') return `<mi>true</mi>`
  if (op === 'broadcast') {
    const fn = n.fn
    if (typeof fn !== 'string') return undefined
    return formatExpressionNodeMathML({ op: fn, args: node.args ?? [] } as ExprNode)
  }
  // Driven from formatStructuralOp: a new structural op needs no second op list
  // here, and a degenerate node (formatStructuralOp → undefined) is not wrapped.
  const text = formatStructuralOp(node, 'unicode')
  if (text === undefined) return undefined
  return `<mtext>${escapeMathMLText(text)}</mtext>`
}

// ---------------------------------------------------------------------------
// Per-operator render table
//
// ONE entry per operator supplies its text (unicode/latex/ascii) and MathML
// renderers, so both `formatExpressionNode` and `formatExpressionNodeMathML`
// reduce to: structural check → table lookup → shared function-call fallback.
// Adding a scalar operator is a single entry here (op-registry.ts:10-12). An
// entry returns `undefined` for an arity it does not handle, deferring to the
// fallback exactly as the original arity-gated switches did.
// ---------------------------------------------------------------------------

/** Context passed to a text (unicode/latex/ascii) operator renderer. */
interface TextCtx {
  op: string
  args: Expr[]
  wrt?: string
  format: TextFormat
  /** Render an argument WITH precedence-aware parenthesization. */
  arg: (a: Expr, isRight?: boolean) => string
  /** Render an argument WITHOUT parenthesization. */
  raw: (a: Expr) => string
}

/** Context passed to a MathML operator renderer. */
interface MathMLCtx {
  op: string
  args: Expr[]
  wrt?: string
  /** Render an argument as MathML. */
  m: (a: Expr) => string
}

/** Per-operator renderers; a `undefined` result falls through to the fallback. */
interface OpRenderer {
  text?: (c: TextCtx) => string | undefined
  mathml?: (c: MathMLCtx) => string | undefined
}

/** Binary text infix `a SYM b` (right operand precedence-checked); non-binary → fallback. */
function textInfix(uni: string, latex: string, ascii: string): OpRenderer['text'] {
  return (c) => {
    if (c.args.length !== 2) return undefined
    const sym = c.format === 'unicode' ? uni : c.format === 'latex' ? latex : ascii
    return `${c.arg(c.args[0])} ${sym} ${c.arg(c.args[1], true)}`
  }
}

/** Binary MathML infix wrapping the two operands around a fixed `<mo>` token. */
function mathmlInfix(mo: string): OpRenderer['mathml'] {
  return (c) =>
    c.args.length === 2 ? `<mrow>${c.m(c.args[0])}${mo}${c.m(c.args[1])}</mrow>` : undefined
}

/** MathML `op(arg)` for a unary elementary function; non-unary → fallback. */
const mathmlUnaryCall: OpRenderer['mathml'] = (c) =>
  c.args.length === 1
    ? `<mrow><mi>${c.op}</mi><mo>(</mo>${c.m(c.args[0])}<mo>)</mo></mrow>`
    : undefined

/**
 * Text renderer for exp/sin/cos/tan/sinh/cosh/tanh: `op(arg)`, with LaTeX using
 * `\left( \right)` when the argument contains a tall element (`\frac`).
 */
function textElementaryFunc(c: TextCtx): string | undefined {
  if (c.args.length !== 1) return undefined
  const a = c.args[0]
  if (c.format === 'latex') {
    const la = toLatex(a)
    return la.includes('\\frac') ? `\\${c.op}\\left(${la}\\right)` : `\\${c.op}(${la})`
  }
  return `${c.op}(${c.arg(a)})`
}

/** Text renderer for the inverse trig functions asin/acos/atan (`arcsin`, …). */
function textArcFunc(c: TextCtx): string | undefined {
  if (c.args.length !== 1) return undefined
  const a = c.args[0]
  const arcName = c.op.replace('a', 'arc')
  if (c.format === 'unicode') return `${arcName}(${c.arg(a)})`
  if (c.format === 'latex') return `\\${arcName}(${toLatex(a)})`
  return `${c.op}(${c.arg(a)})`
}

/** Text renderer for the inverse hyperbolic functions asinh/acosh/atanh (`sinh⁻¹`, …). */
function textInvHypFunc(c: TextCtx): string | undefined {
  if (c.args.length !== 1) return undefined
  const a = c.args[0]
  const hypName = c.op.replace('a', '') // asinh → sinh
  if (c.format === 'unicode') return `${hypName}⁻¹(${c.arg(a)})`
  if (c.format === 'latex') return `\\${hypName}^{-1}(${toLatex(a)})`
  return `${c.op}(${c.arg(a)})`
}

const OP_RENDERERS: Record<string, OpRenderer> = {
  '+': {
    text: (c) => {
      const { args, format } = c
      if (args.length === 2) {
        const [left, right] = args
        // Simplify a + (-b) → a − b: recurse on a synthetic binary-minus node
        // so the subtraction formatting lives in exactly one place.
        if (isExprNode(right) && right.op === '-' && right.args.length === 1) {
          return formatExpressionNode({ op: '-', args: [left, right.args[0]] } as ExprNode, format)
        }
        return `${c.arg(left)} + ${c.arg(right, true)}`
      }
      if (args.length >= 3) return args.map((a) => c.arg(a)).join(' + ')
      return undefined
    },
    mathml: (c) => {
      const { args } = c
      if (args.length === 2) return `<mrow>${c.m(args[0])}<mo>+</mo>${c.m(args[1])}</mrow>`
      if (args.length >= 3) return `<mrow>${args.map((a) => c.m(a)).join('<mo>+</mo>')}</mrow>`
      return undefined
    },
  },

  '-': {
    text: (c) => {
      const { args, format } = c
      if (args.length === 2) {
        const sep = format === 'unicode' ? ' − ' : ' - '
        return `${c.arg(args[0])}${sep}${c.arg(args[1], true)}`
      }
      if (args.length === 1) return `${format === 'unicode' ? '−' : '-'}${c.arg(args[0])}`
      return undefined
    },
    mathml: (c) => {
      const { args } = c
      if (args.length === 2) return `<mrow>${c.m(args[0])}<mo>-</mo>${c.m(args[1])}</mrow>`
      if (args.length === 1) return `<mrow><mo>-</mo>${c.m(args[0])}</mrow>`
      return undefined
    },
  },

  '*': {
    text: (c) => {
      const { args, format } = c
      if (args.length === 2) {
        const [left, right] = args
        if (format === 'unicode') return `${c.arg(left)}·${c.arg(right, true)}`
        if (format === 'latex') return `${c.arg(left)} \\cdot ${c.arg(right, true)}`
        return `${c.arg(left)} * ${c.arg(right, true)}`
      }
      if (args.length >= 3) {
        const sep = format === 'unicode' ? '·' : format === 'latex' ? ' \\cdot ' : ' * '
        return args.map((a) => c.arg(a)).join(sep)
      }
      return undefined
    },
    mathml: (c) => {
      const { args } = c
      if (args.length === 2) return `<mrow>${c.m(args[0])}<mo>&cdot;</mo>${c.m(args[1])}</mrow>`
      if (args.length >= 3) return `<mrow>${args.map((a) => c.m(a)).join('<mo>&cdot;</mo>')}</mrow>`
      return undefined
    },
  },

  '/': {
    text: (c) => {
      if (c.args.length !== 2) return undefined
      const [left, right] = c.args
      if (c.format === 'latex') return `\\frac{${toLatex(left)}}{${toLatex(right)}}`
      if (c.format === 'unicode') return `${c.arg(left)}/${c.arg(right, true)}`
      return `${c.arg(left)} / ${c.arg(right, true)}`
    },
    mathml: (c) =>
      c.args.length === 2 ? `<mfrac>${c.m(c.args[0])}${c.m(c.args[1])}</mfrac>` : undefined,
  },

  '^': {
    text: (c) => {
      if (c.args.length !== 2) return undefined
      const [left, right] = c.args
      if (c.format === 'latex') return `${c.arg(left)}^{${toLatex(right)}}`
      const rn = numericValue(right)
      if (c.format === 'unicode' && rn !== undefined && Number.isInteger(rn)) {
        return `${c.arg(left)}${toSuperscript(rn.toString())}`
      }
      return `${c.arg(left)}^${c.arg(right, true)}`
    },
    mathml: (c) =>
      c.args.length === 2 ? `<msup>${c.m(c.args[0])}${c.m(c.args[1])}</msup>` : undefined,
  },

  '>': { text: textInfix('>', '>', '>'), mathml: mathmlInfix('<mo>&gt;</mo>') },
  '<': { text: textInfix('<', '<', '<'), mathml: mathmlInfix('<mo>&lt;</mo>') },
  '>=': { text: textInfix('≥', '\\geq', '>='), mathml: mathmlInfix('<mo>&geq;</mo>') },
  '<=': { text: textInfix('≤', '\\leq', '<='), mathml: mathmlInfix('<mo>&leq;</mo>') },
  '=': { text: textInfix('=', '=', '==') },
  '==': { text: textInfix('=', '=', '=='), mathml: mathmlInfix('<mo>=</mo>') },
  '!=': { text: textInfix('≠', '\\neq', '!='), mathml: mathmlInfix('<mo>&neq;</mo>') },
  and: { text: textInfix('∧', '\\land', 'and'), mathml: mathmlInfix('<mo>&and;</mo>') },

  or: {
    text: (c) => {
      const { args, format } = c
      if (args.length === 2) {
        const sym = format === 'unicode' ? '∨' : format === 'latex' ? '\\lor' : 'or'
        return `${c.arg(args[0])} ${sym} ${c.arg(args[1], true)}`
      }
      if (args.length >= 3) {
        const sep = format === 'unicode' ? ' ∨ ' : format === 'latex' ? ' \\lor ' : ' or '
        return args.map((a) => c.arg(a)).join(sep)
      }
      return undefined
    },
    mathml: (c) => {
      const { args } = c
      if (args.length === 2) return `<mrow>${c.m(args[0])}<mo>&or;</mo>${c.m(args[1])}</mrow>`
      if (args.length >= 3) return `<mrow>${args.map((a) => c.m(a)).join('<mo>&or;</mo>')}</mrow>`
      return undefined
    },
  },

  atan2: {
    text: (c) => {
      if (c.args.length !== 2) return undefined
      const [left, right] = c.args
      if (c.format === 'latex') return `\\mathrm{atan2}(${toLatex(left)}, ${toLatex(right)})`
      return `atan2(${c.arg(left)}, ${c.arg(right)})`
    },
    mathml: (c) =>
      c.args.length === 2
        ? `<mrow><mi>atan2</mi><mo>(</mo>${c.m(c.args[0])}<mo>,</mo>${c.m(c.args[1])}<mo>)</mo></mrow>`
        : undefined,
  },

  min: {
    text: (c) => {
      if (c.args.length !== 2) return undefined
      const [left, right] = c.args
      if (c.format === 'latex') return `\\min(${toLatex(left)}, ${toLatex(right)})`
      return `min(${c.arg(left)}, ${c.arg(right)})`
    },
    mathml: (c) =>
      c.args.length === 2
        ? `<mrow><mi>min</mi><mo>(</mo>${c.m(c.args[0])}<mo>,</mo>${c.m(c.args[1])}<mo>)</mo></mrow>`
        : undefined,
  },

  max: {
    text: (c) => {
      const { args, format } = c
      if (args.length === 2) {
        const [left, right] = args
        if (format === 'latex') return `\\max(${toLatex(left)}, ${toLatex(right)})`
        return `max(${c.arg(left)}, ${c.arg(right)})`
      }
      if (args.length >= 3) {
        const list = args.map((a) => c.raw(a)).join(', ')
        return format === 'latex' ? `\\max(${list})` : `max(${list})`
      }
      return undefined
    },
    mathml: (c) => {
      const { args } = c
      if (args.length === 2)
        return `<mrow><mi>max</mi><mo>(</mo>${c.m(args[0])}<mo>,</mo>${c.m(args[1])}<mo>)</mo></mrow>`
      if (args.length >= 3) {
        const list = args.map((a) => c.m(a)).join('<mo>,</mo>')
        return `<mrow><mi>max</mi><mo>(</mo>${list}<mo>)</mo></mrow>`
      }
      return undefined
    },
  },

  not: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `¬${c.arg(a)}`
      if (c.format === 'latex') return `\\neg ${c.arg(a)}`
      return `not ${c.arg(a)}`
    },
    mathml: (c) => (c.args.length === 1 ? `<mrow><mo>&not;</mo>${c.m(c.args[0])}</mrow>` : undefined),
  },

  exp: { text: textElementaryFunc, mathml: mathmlUnaryCall },
  sin: { text: textElementaryFunc, mathml: mathmlUnaryCall },
  cos: { text: textElementaryFunc, mathml: mathmlUnaryCall },
  tan: { text: textElementaryFunc, mathml: mathmlUnaryCall },
  sinh: { text: textElementaryFunc },
  cosh: { text: textElementaryFunc },
  tanh: { text: textElementaryFunc },

  asin: { text: textArcFunc, mathml: mathmlUnaryCall },
  acos: { text: textArcFunc, mathml: mathmlUnaryCall },
  atan: { text: textArcFunc, mathml: mathmlUnaryCall },

  asinh: { text: textInvHypFunc },
  acosh: { text: textInvHypFunc },
  atanh: { text: textInvHypFunc },

  log: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `ln(${c.arg(a)})`
      if (c.format === 'latex') return `\\ln(${toLatex(a)})`
      return `log(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1 ? `<mrow><mi>ln</mi><mo>(</mo>${c.m(c.args[0])}<mo>)</mo></mrow>` : undefined,
  },

  log10: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `log₁₀(${c.arg(a)})`
      if (c.format === 'latex') return `\\log_{10}(${toLatex(a)})`
      return `log10(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1
        ? `<mrow><msub><mi>log</mi><mn>10</mn></msub><mo>(</mo>${c.m(c.args[0])}<mo>)</mo></mrow>`
        : undefined,
  },

  sqrt: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') {
        const argStr = toUnicode(a)
        // Wrap compound expressions in parentheses for clarity
        return isExprNode(a) ? `√(${argStr})` : `√${argStr}`
      }
      if (c.format === 'latex') return `\\sqrt{${toLatex(a)}}`
      return `sqrt(${c.arg(a)})`
    },
    mathml: (c) => (c.args.length === 1 ? `<msqrt>${c.m(c.args[0])}</msqrt>` : undefined),
  },

  abs: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `|${c.arg(a)}|`
      if (c.format === 'latex') return `|${toLatex(a)}|`
      return `abs(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1 ? `<mrow><mo>|</mo>${c.m(c.args[0])}<mo>|</mo></mrow>` : undefined,
  },

  floor: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `⌊${c.arg(a)}⌋`
      if (c.format === 'latex') return `\\lfloor ${toLatex(a)} \\rfloor`
      return `floor(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1
        ? `<mrow><mo>&lfloor;</mo>${c.m(c.args[0])}<mo>&rfloor;</mo></mrow>`
        : undefined,
  },

  ceil: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `⌈${c.arg(a)}⌉`
      if (c.format === 'latex') return `\\lceil ${toLatex(a)} \\rceil`
      return `ceil(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1
        ? `<mrow><mo>&lceil;</mo>${c.m(c.args[0])}<mo>&rceil;</mo></mrow>`
        : undefined,
  },

  sign: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'unicode') return `sgn(${c.arg(a)})`
      if (c.format === 'latex') return `\\mathrm{sgn}(${toLatex(a)})`
      return `sign(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1
        ? `<mrow><mi>sgn</mi><mo>(</mo>${c.m(c.args[0])}<mo>)</mo></mrow>`
        : undefined,
  },

  Pre: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      if (c.format === 'latex') return `\\mathrm{Pre}(${toLatex(a)})`
      return `Pre(${c.arg(a)})`
    },
    mathml: (c) =>
      c.args.length === 1
        ? `<mrow><mi>Pre</mi><mo>(</mo>${c.m(c.args[0])}<mo>)</mo></mrow>`
        : undefined,
  },

  D: {
    text: (c) => {
      if (c.args.length !== 1) return undefined
      const a = c.args[0]
      const w = c.wrt || 't'
      if (c.format === 'unicode') return `∂${toUnicode(a)}/∂${w}`
      if (c.format === 'latex') return `\\frac{\\partial ${toLatex(a)}}{\\partial ${w}}`
      return `D(${toAscii(a)})/D${w}`
    },
    mathml: (c) => {
      if (c.args.length !== 1) return undefined
      const w = c.wrt || 't'
      return `<mfrac><mrow><mo>&part;</mo>${c.m(c.args[0])}</mrow><mrow><mo>&part;</mo><mi>${w}</mi></mrow></mfrac>`
    },
  },

  ifelse: {
    text: (c) => {
      if (c.args.length !== 3) return undefined
      const [cond, thenExpr, elseExpr] = c.args
      if (c.format === 'latex') {
        return `\\begin{cases} ${toLatex(thenExpr)} & \\text{if } ${toLatex(cond)} \\\\ ${toLatex(elseExpr)} & \\text{otherwise} \\end{cases}`
      }
      return `ifelse(${c.arg(cond)}, ${c.arg(thenExpr)}, ${c.arg(elseExpr)})`
    },
    mathml: (c) => {
      if (c.args.length !== 3) return undefined
      const [cond, thenExpr, elseExpr] = c.args
      return `<mrow><mi>ifelse</mi><mo>(</mo>${c.m(cond)}<mo>,</mo>${c.m(thenExpr)}<mo>,</mo>${c.m(elseExpr)}<mo>)</mo></mrow>`
    },
  },
}

/**
 * Format an ExpressionNode for MathML output. Structural ops go through
 * {@link formatStructuralOpMathML}; scalar ops through the {@link OP_RENDERERS}
 * table; the rest through the generic function-call fallback.
 */
function formatExpressionNodeMathML(node: ExprNode): string {
  const structural = formatStructuralOpMathML(node)
  if (structural !== undefined) return structural

  const ctx: MathMLCtx = {
    op: node.op,
    args: node.args,
    wrt: node.wrt,
    m: (a) => toMathML(a),
  }
  const rendered = OP_RENDERERS[node.op]?.mathml?.(ctx)
  if (rendered !== undefined) return rendered

  // Fallback: function call notation.
  const argList = node.args.map((a) => toMathML(a)).join('<mo>,</mo>')
  return `<mrow><mi>${node.op}</mi><mo>(</mo>${argList}<mo>)</mo></mrow>`
}

/** Escape LaTeX-special underscores in a bare operator / identifier name. */
function latexName(name: string): string {
  return name.replace(/_/g, '\\_')
}

/** Render a sub-expression in the requested text format. */
function renderExpr(expr: Expr, format: TextFormat): string {
  if (format === 'unicode') return toUnicode(expr)
  if (format === 'latex') return toLatex(expr)
  return toAscii(expr)
}

/** Parenthesize a sub-expression only when it is an operator node. */
function wrapIfOp(expr: Expr, format: TextFormat): string {
  const s = renderExpr(expr, format)
  if (isExprNode(expr)) return `(${s})`
  return s
}

/** Format a `const` node's literal value (scalar number or nested array). */
function formatConstValue(value: unknown, format: TextFormat): string {
  if (Array.isArray(value)) {
    return `[${value.map((v) => formatConstValue(v, format)).join(', ')}]`
  }
  const n = numericValue(value)
  if (n !== undefined) return formatNumber(n, format)
  return String(value)
}

/**
 * Format a structural integer bound (region / shape / range entry): a plain
 * integer, a symbolic dimension string, or a metaparameter Expression node.
 */
function formatBound(value: unknown, format: TextFormat): string {
  if (typeof value === 'number') return String(value)
  if (typeof value === 'string') return value
  const n = numericValue(value)
  if (n !== undefined) return String(n)
  if (isExprNode(value)) {
    return renderExpr(value, format)
  }
  return String(value)
}

/** Big-operator symbol for an `aggregate` reduction (semiring supersedes reduce). */
function aggregateSymbol(
  semiring: string | undefined,
  reduce: string,
  format: TextFormat,
): string {
  let fam: 'plus' | 'times' | 'max' | 'min' | 'bool'
  if (semiring) {
    fam =
      semiring === 'max_product' || semiring === 'max_sum'
        ? 'max'
        : semiring === 'min_sum'
          ? 'min'
          : semiring === 'bool_and_or'
            ? 'bool'
            : 'plus'
  } else {
    fam = reduce === '*' ? 'times' : reduce === 'max' ? 'max' : reduce === 'min' ? 'min' : 'plus'
  }
  const table: Record<string, [string, string, string]> = {
    plus: ['Σ', '\\sum', 'sum'],
    times: ['Π', '\\prod', 'prod'],
    max: ['max', '\\max', 'max'],
    min: ['min', '\\min', 'min'],
    bool: ['⋁', '\\bigvee', 'any'],
  }
  const [u, l, a] = table[fam]
  return format === 'unicode' ? u : format === 'latex' ? l : a
}

/** Render the ` where {…}` range clause shared by aggregate and argmin/argmax. */
function formatRangesClause(ranges: Record<string, unknown>, format: TextFormat): string {
  const inSym = format === 'latex' ? ' \\in ' : format === 'unicode' ? '∈' : ' in '
  const parts = Object.keys(ranges)
    .sort()
    .map((k) => {
      const rng = ranges[k]
      let rngStr: string
      if (Array.isArray(rng)) {
        rngStr = rng.map((x) => formatBound(x, format)).join(':')
      } else if (rng && typeof rng === 'object' && 'from' in (rng as object)) {
        const from = String((rng as { from: unknown }).from)
        const of = (rng as { of?: string[] }).of
        rngStr = of && of.length > 0 ? `${from}(${of.join(', ')})` : from
      } else {
        rngStr = String(rng)
      }
      return `${k}${inSym}${rngStr}`
    })
  if (format === 'latex') return ` \\text{ where } \\{${parts.join(', ')}\\}`
  return ` where {${parts.join(', ')}}`
}

/** Render an `aggregate` node per the rendering contract. */
function formatAggregate(node: ExprNode, format: TextFormat): string {
  const n = structuralView(node)
  const r = (e: Expr) => renderExpr(e, format)
  const outIdx = (n.output_idx ?? []).map((o) => String(o)).join(', ')
  const exprStr = n.expr !== undefined ? r(n.expr) : ''
  const semiring = n.semiring
  const reduce = n.reduce ?? '+'
  const sym = aggregateSymbol(semiring, reduce, format)
  const idxPart = format === 'latex' ? `_{${outIdx}}` : `[${outIdx}]`
  let out = `${sym}${idxPart} (${exprStr})`
  const ranges = n.ranges
  if (ranges && Object.keys(ranges).length > 0) out += formatRangesClause(ranges, format)
  const join = n.join
  if (join && join.length > 0) {
    const clauses = join
      .map((c) => (c.on ?? []).map((p) => `${p[0]}=${p[1]}`).join(', '))
      .join('; ')
    out += ` join(${clauses})`
  }
  if (n.filter !== undefined) out += ` if ${r(n.filter)}`
  if (n.distinct === true) out += ` distinct`
  if (n.key !== undefined) out += ` key=${r(n.key)}`
  if (semiring && semiring !== 'sum_product') out += ` [semiring=${semiring}]`
  return out
}

/** Render an `argmin` / `argmax` arg-witness node per the rendering contract. */
function formatArgWitness(node: ExprNode, format: TextFormat): string {
  const n = structuralView(node)
  const r = (e: Expr) => renderExpr(e, format)
  const arg = String(n.arg ?? '')
  const exprStr = n.expr !== undefined ? r(n.expr) : ''
  const idxPart = format === 'latex' ? `_{${arg}}` : `[${arg}]`
  const name = format === 'latex' ? `\\mathrm{${node.op}}` : node.op
  let out = `${name}${idxPart} (${exprStr})`
  const ranges = n.ranges
  if (ranges && Object.keys(ranges).length > 0) out += formatRangesClause(ranges, format)
  return out
}

/**
 * Render the closed-core structural / array-query ops (esm-spec §4.2), whose
 * defining data lives in fields OTHER than `args`, plus `integral`. Returns a
 * fully-formatted string, or `undefined` for ops handled by the scalar-op
 * dispatch (arithmetic, elementary functions, comparisons, D, Pre, …) or by
 * the generic fallback (open-tier sugar `grad`/`div`/`laplacian`, unknown
 * user ops). See tests/display/RENDERING_CONTRACT.md.
 */
function formatStructuralOp(node: ExprNode, format: TextFormat): string | undefined {
  const op = node.op
  const args = node.args ?? []
  const n = structuralView(node)
  const r = (e: Expr) => renderExpr(e, format)

  switch (op) {
    case 'const':
      return formatConstValue(n.value, format)

    case 'true':
      return 'true'

    case 'fn': {
      const name = String(n.name ?? '')
      const inner = args.map(r).join(', ')
      return format === 'latex' ? `\\mathrm{${latexName(name)}}(${inner})` : `${name}(${inner})`
    }

    case 'enum': {
      const label = `${String(args[0])}.${String(args[1])}`
      return format === 'latex' ? `\\mathrm{${latexName(label)}}` : label
    }

    case 'index': {
      if (args.length === 0) return undefined
      const [arr, ...idx] = args
      return `${wrapIfOp(arr, format)}[${idx.map(r).join(', ')}]`
    }

    case 'broadcast': {
      const fn = n.fn
      if (typeof fn !== 'string') return undefined
      return formatExpressionNode({ op: fn, args } as ExprNode, format)
    }

    case 'integral': {
      if (args.length === 0) return undefined
      const f = r(args[0])
      const v = String(n.var ?? 'x')
      const lo = n.lower !== undefined ? r(n.lower) : ''
      const hi = n.upper !== undefined ? r(n.upper) : ''
      if (format === 'latex') return `\\int_{${lo}}^{${hi}} ${f} \\, d${v}`
      if (format === 'unicode') return `∫[${lo}, ${hi}] ${f} d${v}`
      return `integral(${f}, ${v}, ${lo}, ${hi})`
    }

    case 'table_lookup': {
      const table = String(n.table ?? '')
      const axes = n.axes ?? {}
      const eq = format === 'latex' ? ' = ' : '='
      const bindings = Object.keys(axes)
        .sort()
        .map((k) => `${k}${eq}${r(axes[k])}`)
        .join(', ')
      const out = n.output
      const outStr = out !== undefined && out !== null ? `:${String(out)}` : ''
      const name = format === 'latex' ? `\\mathrm{${latexName(table)}}` : table
      return `${name}[${bindings}]${outStr}`
    }

    case 'apply_expression_template': {
      const name = String(n.name ?? '')
      const bindings = n.bindings ?? {}
      const eq = format === 'latex' ? ' = ' : '='
      const inner = Object.keys(bindings)
        .sort()
        .map((k) => `${k}${eq}${r(bindings[k])}`)
        .join(', ')
      if (format === 'latex') return `\\mathrm{${latexName(name)}}\\langle ${inner} \\rangle`
      if (format === 'unicode') return `${name}⟨${inner}⟩`
      return `${name}<${inner}>`
    }

    case 'makearray': {
      const regions = n.regions ?? []
      const values = n.values ?? []
      const parts = regions.map((region, i) => {
        const regStr = region
          .map((dim) => `${formatBound(dim[0], format)}:${formatBound(dim[1], format)}`)
          .join(', ')
        const val = i < values.length ? r(values[i]) : '?'
        return `[${regStr}] = ${val}`
      })
      const name = format === 'latex' ? '\\mathrm{makearray}' : 'makearray'
      return `${name}(${parts.join(', ')})`
    }

    case 'reshape': {
      if (args.length === 0) return undefined
      const shape = (n.shape ?? []).map((s) => formatBound(s, format)).join(', ')
      const name = format === 'latex' ? '\\mathrm{reshape}' : 'reshape'
      return `${name}(${r(args[0])}, [${shape}])`
    }

    case 'transpose': {
      if (args.length === 0) return undefined
      const perm = n.perm
      if (perm && perm.length > 0) {
        const name = format === 'latex' ? '\\mathrm{transpose}' : 'transpose'
        return `${name}(${r(args[0])}, [${perm.join(', ')}])`
      }
      const a = wrapIfOp(args[0], format)
      if (format === 'latex') return `${a}^{T}`
      if (format === 'unicode') return `${a}ᵀ`
      return `transpose(${r(args[0])})`
    }

    case 'concat': {
      const inner = args.map(r).join(', ')
      const name = format === 'latex' ? '\\mathrm{concat}' : 'concat'
      return `${name}(${inner}, axis=${n.axis ?? 0})`
    }

    case 'intersect_polygon':
    case 'polygon_intersection_area': {
      const inner = args.map(r).join(', ')
      const name = format === 'latex' ? `\\mathrm{${latexName(op)}}` : op
      return `${name}(${inner}, manifold=${String(n.manifold ?? '')})`
    }

    case 'aggregate':
      return formatAggregate(node, format)

    case 'argmin':
    case 'argmax':
      return formatArgWitness(node, format)

    default:
      return undefined
  }
}

/**
 * Format an ExpressionNode (operator with arguments) as text. Structural ops
 * are handled by {@link formatStructuralOp}; scalar ops by the
 * {@link OP_RENDERERS} table; open-tier sugar (grad/div/laplacian) and any
 * unknown user op by the generic function-call fallback (only `args` shown).
 */
function formatExpressionNode(node: ExprNode, format: TextFormat): string {
  const structural = formatStructuralOp(node, format)
  if (structural !== undefined) return structural

  const ctx: TextCtx = {
    op: node.op,
    args: node.args,
    wrt: node.wrt,
    format,
    arg: (a, isRight = false) => {
      const result = renderExpr(a, format)
      return needsParentheses(node, a, isRight) ? `(${result})` : result
    },
    raw: (a) => renderExpr(a, format),
  }
  const rendered = OP_RENDERERS[node.op]?.text?.(ctx)
  if (rendered !== undefined) return rendered

  // Generic fallback: function-call notation.
  const argList = node.args.map((a) => renderExpr(a, format)).join(', ')
  return format === 'latex' ? `\\mathrm{${latexName(node.op)}}(${argList})` : `${node.op}(${argList})`
}

/**
 * Format model summary (implementation per spec Section 6.3)
 */
function formatModelSummary(model: Model, format: 'unicode' | 'ascii'): string {
  // Count parameter and state variables
  const variables = model.variables || {}
  const parameterCount = Object.values(variables).filter((v) => v.type === 'parameter').length
  const equationCount = model.equations?.length || 0

  // Format equation list
  const equationLines: string[] = []
  if (model.equations) {
    for (const equation of model.equations) {
      try {
        const lhsStr = format === 'unicode' ? toUnicode(equation.lhs) : toAscii(equation.lhs)
        const rhsStr = format === 'unicode' ? toUnicode(equation.rhs) : toAscii(equation.rhs)
        equationLines.push(`    ${lhsStr} = ${rhsStr}`)
      } catch {
        // Fallback for equations that can't be formatted
        equationLines.push(`    [equation formatting error]`)
      }
    }
  }

  // Build summary - this matches the spec format for individual models within EsmFile
  const result = [
    `(${parameterCount} parameters, ${equationCount} equation${equationCount !== 1 ? 's' : ''})`,
  ]
  if (equationLines.length > 0) {
    result.push(...equationLines)
  }

  return result.join('\n')
}

/**
 * Format reaction system summary. `species` is a keyed map in the schema, so
 * the count comes from its keys.
 */
function formatReactionSystemSummary(reactionSystem: ReactionSystem): string {
  const speciesCount = Object.keys(reactionSystem.species || {}).length
  const reactionCount = reactionSystem.reactions?.length || 0
  return `ReactionSystem (${speciesCount} species, ${reactionCount} reactions)`
}

/**
 * Format ESM file summary
 */
function formatEsmFileSummary(esmFile: EsmFile): string {
  const models = Object.keys(esmFile.models || {}).length
  const reactionSystems = Object.keys(esmFile.reaction_systems || {}).length
  const dataLoaders = Object.keys(esmFile.data_loaders || {}).length
  const name = esmFile.metadata?.name || 'Untitled'

  return `ESM v${esmFile.esm}: ${name} (${models} models, ${reactionSystems} reaction systems, ${dataLoaders} data loaders)`
}
