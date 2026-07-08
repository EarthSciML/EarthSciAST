/**
 * Pretty-printing formatters for ESM format expressions, equations, models, and files.
 *
 * Implements three output formats:
 * - toUnicode(): Unicode mathematical notation with chemical subscripts
 * - toLatex(): LaTeX mathematical notation
 * - toAscii(): Plain text representation
 *
 * Based on ESM Format Specification Section 6.1
 */

import type { Expr, Equation, Model, EsmFile, ReactionSystem, ExprNode } from './types.js'
import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { opPrecedence, isFunctionCallOp } from './op-registry.js'

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

// Greek letter mapping for LaTeX
const GREEK_LETTERS: Record<string, string> = {
  alpha: '\\alpha',
  beta: '\\beta',
  gamma: '\\gamma',
  delta: '\\delta',
  epsilon: '\\epsilon',
  zeta: '\\zeta',
  eta: '\\eta',
  theta: '\\theta',
  iota: '\\iota',
  kappa: '\\kappa',
  lambda: '\\lambda',
  mu: '\\mu',
  nu: '\\nu',
  xi: '\\xi',
  omicron: '\\omicron',
  pi: '\\pi',
  rho: '\\rho',
  sigma: '\\sigma',
  tau: '\\tau',
  upsilon: '\\upsilon',
  phi: '\\phi',
  chi: '\\chi',
  psi: '\\psi',
  omega: '\\omega',
  Gamma: '\\Gamma',
  Delta: '\\Delta',
  Theta: '\\Theta',
  Lambda: '\\Lambda',
  Xi: '\\Xi',
  Pi: '\\Pi',
  Sigma: '\\Sigma',
  Upsilon: '\\Upsilon',
  Phi: '\\Phi',
  Psi: '\\Psi',
  Omega: '\\Omega',
  // Direct Unicode to LaTeX mappings
  α: '\\alpha',
  β: '\\beta',
  γ: '\\gamma',
  δ: '\\delta',
  ε: '\\epsilon',
  ζ: '\\zeta',
  η: '\\eta',
  θ: '\\theta',
  ι: '\\iota',
  κ: '\\kappa',
  λ: '\\lambda',
  μ: '\\mu',
  ν: '\\nu',
  ξ: '\\xi',
  ο: '\\omicron',
  π: '\\pi',
  ρ: '\\rho',
  σ: '\\sigma',
  τ: '\\tau',
  υ: '\\upsilon',
  φ: '\\phi',
  χ: '\\chi',
  ψ: '\\psi',
  ω: '\\omega',
}

function convertGreekLetters(text: string, format: 'unicode' | 'latex' | 'ascii'): string {
  if (format === 'latex') {
    // Replace Greek letters with LaTeX commands
    // Negative lookahead (?![A-Z}]) prevents conversion when followed by uppercase (chemical prefix)
    // or closing brace (inside \mathrm{})
    return text.replace(
      /[α-ωΑ-Ω]|(?:alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega)(?![A-Z}])/g,
      (match) => GREEK_LETTERS[match] || match,
    )
  } else if (format === 'unicode') {
    // Convert named Greek letters to Unicode symbols
    // Negative lookahead (?![A-Z]) prevents conversion when followed by uppercase (chemical prefix)
    const unicodeGreek: Record<string, string> = {
      phi: 'φ',
      theta: 'θ',
      gamma: 'γ',
      alpha: 'α',
      beta: 'β',
      delta: 'δ',
      epsilon: 'ε',
      zeta: 'ζ',
      eta: 'η',
      iota: 'ι',
      kappa: 'κ',
      lambda: 'λ',
      mu: 'μ',
      nu: 'ν',
      xi: 'ξ',
      omicron: 'ο',
      pi: 'π',
      rho: 'ρ',
      sigma: 'σ',
      tau: 'τ',
      upsilon: 'υ',
      chi: 'χ',
      psi: 'ψ',
      omega: 'ω',
    }
    return text.replace(
      /(?:alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega)(?![A-Z])/g,
      (match) => unicodeGreek[match] || match,
    )
  } else if (format === 'ascii') {
    // Convert Unicode Greek letters to ASCII names
    const asciiGreek: Record<string, string> = {
      φ: 'phi',
      θ: 'theta',
      γ: 'gamma',
      α: 'alpha',
      β: 'beta',
      δ: 'delta',
      ε: 'epsilon',
      ζ: 'zeta',
      η: 'eta',
      ι: 'iota',
      κ: 'kappa',
      λ: 'lambda',
      μ: 'mu',
      ν: 'nu',
      ξ: 'xi',
      ο: 'omicron',
      π: 'pi',
      ρ: 'rho',
      σ: 'sigma',
      τ: 'tau',
      υ: 'upsilon',
      χ: 'chi',
      ψ: 'psi',
      ω: 'omega',
    }
    return text.replace(/[α-ωΑ-Ω]/g, (match) => asciiGreek[match] || match)
  }

  return text
}

/**
 * Apply element-aware chemical subscript formatting to a variable name.
 * Uses greedy 2-char-before-1-char matching for element detection.
 */
function formatChemicalSubscripts(variable: string, format: 'unicode' | 'latex'): string {
  // Check if variable looks like a chemical formula (starts with element and has digits)
  const hasElements = hasElementPattern(variable)

  if (format === 'latex') {
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
              const chemFormatted = seg.replace(/(\d+)/g, (_: string, digits: string) =>
                digits.length === 1 ? `_${digits}` : `_{${digits}}`,
              )
              result += `_{\\mathrm{${chemFormatted}}}`
            } else {
              result += `_\\mathrm{${seg}}`
            }
          }
          return result
        }
      }

      const chemicalPart = formatChemicalSubscripts(suffix, 'latex')
      // Remove outer \mathrm{} wrapper but keep the content formatted
      const innerContent = chemicalPart.replace(/^\\mathrm\{|\}$/g, '')
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
      let result = variable
      result = result.replace(/(\d+)/g, (match, digits) => {
        // Single digits don't need braces in LaTeX subscripts
        return digits.length === 1 ? `_${digits}` : `_{${digits}}`
      })
      return `\\mathrm{${result}}`
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
            result = formatChemicalSubscripts(base, 'latex')
          } else {
            result = `\\mathrm{${base}}`
          }
          for (let i = 1; i < parts.length; i++) {
            const part = parts[i]
            if (hasElementPattern(part)) {
              const chemFormatted = part.replace(/(\d+)/g, (_: string, digits: string) =>
                digits.length === 1 ? `_${digits}` : `_{${digits}}`,
              )
              result += `_{\\mathrm{${chemFormatted}}}`
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

  if (!hasElements) {
    // Check if it's a mixed variable (non-element prefix + chemical suffix)
    const chemicalInfo = getChemicalSuffix(variable)
    if (chemicalInfo) {
      // Split into prefix and chemical part
      const { prefix, suffix } = chemicalInfo
      const chemicalPart = formatChemicalSubscripts(suffix, 'unicode')
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
          .map((part) => {
            if (hasElementPattern(part)) {
              return formatChemicalSubscripts(part, 'unicode')
            }
            return part
          })
          .join('_')
      }
    }
    // No element pattern found, return as-is
    return variable
  }

  // For unicode: element-aware subscript detection
  let result = ''
  let i = 0

  while (i < variable.length) {
    let matched = false

    // Try 2-character element first
    if (i + 1 < variable.length) {
      const twoChar = variable.slice(i, i + 2)
      if (ELEMENTS.has(twoChar)) {
        result += twoChar
        i += 2
        // Convert following digits to subscripts
        while (i < variable.length && /\d/.test(variable[i])) {
          result += SUBSCRIPT_DIGITS[parseInt(variable[i])]
          i++
        }
        matched = true
      }
    }

    // Try 1-character element if 2-char didn't match
    if (!matched && i < variable.length) {
      const oneChar = variable[i]
      if (ELEMENTS.has(oneChar)) {
        result += oneChar
        i++
        // Convert following digits to subscripts
        while (i < variable.length && /\d/.test(variable[i])) {
          result += SUBSCRIPT_DIGITS[parseInt(variable[i])]
          i++
        }
        matched = true
      }
    }

    // If not an element, copy character as-is
    // But subscript digits in chemical formulas (e.g., digits after closing parentheses)
    if (!matched) {
      const ch = variable[i]
      if (/\d/.test(ch)) {
        result += SUBSCRIPT_DIGITS[parseInt(ch)]
      } else {
        result += ch
      }
      i++
    }
  }

  return result
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

  let i = 0
  let hasElement = false

  while (i < cleanVariable.length) {
    // Skip non-alphabetic characters at the start
    while (i < cleanVariable.length && !/[A-Za-z]/.test(cleanVariable[i])) {
      i++
    }

    if (i >= cleanVariable.length) break

    // Try 2-character element first
    if (i + 1 < cleanVariable.length) {
      const twoChar = cleanVariable.slice(i, i + 2)
      if (ELEMENTS.has(twoChar)) {
        hasElement = true
        i += 2
        // Skip digits
        while (i < cleanVariable.length && /\d/.test(cleanVariable[i])) {
          i++
        }
        continue
      }
    }

    // Try 1-character element
    const oneChar = cleanVariable[i]
    if (ELEMENTS.has(oneChar)) {
      hasElement = true
      i++
      // Skip digits
      while (i < cleanVariable.length && /\d/.test(cleanVariable[i])) {
        i++
      }
      continue
    }

    // If we encounter a non-element character, this is not a pure chemical formula
    return false
  }

  return hasElement
}

/**
 * Format a number in scientific notation with appropriate formatting
 */
function formatNumber(num: number, format: 'unicode' | 'latex' | 'ascii'): string {
  // Format according to ESM spec Section 6.1
  if (num === 0) return '0'

  const absNum = Math.abs(num)

  // Use scientific notation for very small or large numbers (spec Section 6.1)
  if (absNum < 0.01 || absNum >= 10000) {
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
    return childPrec <= 1
  }

  // For unary minus, be less aggressive
  if (parent.op === '-' && parent.args.length === 1) {
    return childPrec <= 1
  }

  if (childPrec < parentPrec) return true
  if (childPrec > parentPrec) return false

  // Same precedence: need parens if child is right operand and operator is not associative
  if (isRightOperand && (parent.op === '-' || parent.op === '/' || parent.op === '^')) {
    return true
  }

  return false
}

type TextFormat = 'unicode' | 'latex' | 'ascii'

/**
 * Shared type-dispatch for the three text formats: numeric leaf, variable
 * name, expression node, equation, or a file/model/reaction-system summary.
 */
function formatAny(
  expr: Expr | Equation | Model | ReactionSystem | EsmFile,
  format: TextFormat,
): string {
  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return formatNumber(numericValue(expr)!, format)
  }

  if (typeof expr === 'string') {
    if (format === 'ascii') return convertGreekLetters(expr, 'ascii')
    return convertGreekLetters(formatChemicalSubscripts(expr, format), format)
  }

  if ('op' in expr && 'args' in expr) {
    return formatExpressionNode(expr as ExprNode, format)
  }

  if ('lhs' in expr && 'rhs' in expr) {
    const equation = expr as Equation
    return `${formatAny(equation.lhs, format)} = ${formatAny(equation.rhs, format)}`
  }

  // Summaries (spec Section 6.3) render as text: unicode keeps unicode
  // symbols; latex falls back to plain ascii text.
  const summaryFormat = format === 'unicode' ? 'unicode' : 'ascii'

  if ('models' in expr || 'metadata' in expr) {
    return formatEsmFileSummary(expr as EsmFile)
  }

  if ('variables' in expr && 'equations' in expr) {
    return formatModelSummary(expr as Model, summaryFormat)
  }

  if ('species' in expr && 'reactions' in expr) {
    return formatReactionSystemSummary(expr as ReactionSystem)
  }

  throw new Error(`Unsupported expression type: ${typeof expr}`)
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
  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return `<mn>${formatNumber(numericValue(expr)!, 'ascii')}</mn>`
  }

  if (typeof expr === 'string') {
    return formatMathMLVariable(expr)
  }

  if ('op' in expr && 'args' in expr) {
    return formatExpressionNodeMathML(expr as ExprNode)
  }

  if ('lhs' in expr && 'rhs' in expr) {
    // Equation
    const equation = expr as Equation
    return `<math><mrow>${toMathML(equation.lhs)}<mo>=</mo>${toMathML(equation.rhs)}</mrow></math>`
  }

  if ('models' in expr || 'metadata' in expr) {
    // EsmFile - return plain text in MathML text element
    return `<math><mtext>${formatEsmFileSummary(expr as EsmFile)}</mtext></math>`
  }

  if ('variables' in expr && 'equations' in expr) {
    // Model - return plain text in MathML text element
    return `<math><mtext>${formatModelSummary(expr as Model, 'ascii')}</mtext></math>`
  }

  if ('species' in expr && 'reactions' in expr) {
    // ReactionSystem - return plain text in MathML text element
    return `<math><mtext>${formatReactionSystemSummary(expr as ReactionSystem)}</mtext></math>`
  }

  throw new Error(`Unsupported expression type: ${typeof expr}`)
}

/**
 * Format a variable name with chemical subscripts for MathML
 */
function formatMathMLVariable(variable: string): string {
  // Check if variable looks like a chemical formula (starts with element and has digits)
  const hasElements = hasElementPattern(variable)

  if (hasElements) {
    // Pure chemical formula: wrap in <mi> and convert digits to subscripts
    let result = ''
    let i = 0

    while (i < variable.length) {
      let matched = false

      // Try 2-character element first
      if (i + 1 < variable.length) {
        const twoChar = variable.slice(i, i + 2)
        if (ELEMENTS.has(twoChar)) {
          result += `<mi>${twoChar}</mi>`
          i += 2
          // Convert following digits to subscripts
          if (i < variable.length && /\d/.test(variable[i])) {
            const digits = variable.slice(i).match(/^\d+/)?.[0] || ''
            result += `<msub><mi></mi><mn>${digits}</mn></msub>`
            i += digits.length
          }
          matched = true
        }
      }

      // Try 1-character element if 2-char didn't match
      if (!matched && i < variable.length) {
        const oneChar = variable[i]
        if (ELEMENTS.has(oneChar)) {
          result += `<mi>${oneChar}</mi>`
          i++
          // Convert following digits to subscripts
          if (i < variable.length && /\d/.test(variable[i])) {
            const digits = variable.slice(i).match(/^\d+/)?.[0] || ''
            result += `<msub><mi></mi><mn>${digits}</mn></msub>`
            i += digits.length
          }
          matched = true
        }
      }

      // If not an element, copy character as-is
      if (!matched) {
        result += variable[i]
        i++
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
 * Convert Greek letters to MathML entities
 */
function convertGreekLettersToMathML(text: string): string {
  const mathMLGreek: Record<string, string> = {
    α: '&alpha;',
    β: '&beta;',
    γ: '&gamma;',
    δ: '&delta;',
    ε: '&epsilon;',
    ζ: '&zeta;',
    η: '&eta;',
    θ: '&theta;',
    ι: '&iota;',
    κ: '&kappa;',
    λ: '&lambda;',
    μ: '&mu;',
    ν: '&nu;',
    ξ: '&xi;',
    ο: '&omicron;',
    π: '&pi;',
    ρ: '&rho;',
    σ: '&sigma;',
    τ: '&tau;',
    υ: '&upsilon;',
    φ: '&phi;',
    χ: '&chi;',
    ψ: '&psi;',
    ω: '&omega;',
    Α: '&Alpha;',
    Β: '&Beta;',
    Γ: '&Gamma;',
    Δ: '&Delta;',
    Ε: '&Epsilon;',
    Ζ: '&Zeta;',
    Η: '&Eta;',
    Θ: '&Theta;',
    Ι: '&Iota;',
    Κ: '&Kappa;',
    Λ: '&Lambda;',
    Μ: '&Mu;',
    Ν: '&Nu;',
    Ξ: '&Xi;',
    Ο: '&Omicron;',
    Π: '&Pi;',
    Ρ: '&Rho;',
    Σ: '&Sigma;',
    Τ: '&Tau;',
    Υ: '&Upsilon;',
    Φ: '&Phi;',
    Χ: '&Chi;',
    Ψ: '&Psi;',
    Ω: '&Omega;',
  }

  return text
    .replace(/[α-ωΑ-Ω]/g, (match) => mathMLGreek[match] || match)
    .replace(
      /(?:alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega)/g,
      (match) => mathMLGreek[match] || match,
    )
}

/** Escape `<`, `>`, `&` for embedding text inside MathML `<mtext>`. */
function escapeMathMLText(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/**
 * MathML rendering for the structural / array-query ops. `const` and `true`
 * get native tokens; the array-query tier is rendered non-lossily by
 * embedding its Unicode text form in `<mtext>` (MathML is TS-only and not
 * part of the cross-language conformance contract). `broadcast` delegates to
 * the scalar-op MathML of its `fn`. Returns `undefined` for other ops.
 */
function formatStructuralOpMathML(node: ExprNode): string | undefined {
  const op = node.op
  const n = node as unknown as Record<string, unknown>
  switch (op) {
    case 'const': {
      const v = n.value
      if (Array.isArray(v)) return `<mtext>${escapeMathMLText(formatConstValue(v, 'ascii'))}</mtext>`
      return `<mn>${formatConstValue(v, 'ascii')}</mn>`
    }
    case 'true':
      return `<mi>true</mi>`
    case 'broadcast': {
      const fn = n.fn
      if (typeof fn !== 'string') return undefined
      return formatExpressionNodeMathML({ op: fn, args: node.args ?? [] } as ExprNode)
    }
    case 'fn':
    case 'enum':
    case 'index':
    case 'integral':
    case 'table_lookup':
    case 'apply_expression_template':
    case 'makearray':
    case 'reshape':
    case 'transpose':
    case 'concat':
    case 'intersect_polygon':
    case 'polygon_intersection_area':
    case 'aggregate':
    case 'argmin':
    case 'argmax':
      return `<mtext>${escapeMathMLText(formatStructuralOp(node, 'unicode')!)}</mtext>`
    default:
      return undefined
  }
}

/**
 * Format an ExpressionNode for MathML output
 */
function formatExpressionNodeMathML(node: ExprNode): string {
  const { op, args, wrt } = node

  // Helper to format arguments
  const formatArg = (arg: Expr): string => toMathML(arg)

  const structural = formatStructuralOpMathML(node)
  if (structural !== undefined) return structural

  // Binary operators
  if (args.length === 2) {
    const [left, right] = args

    switch (op) {
      case '+':
        return `<mrow>${formatArg(left)}<mo>+</mo>${formatArg(right)}</mrow>`

      case '-':
        return `<mrow>${formatArg(left)}<mo>-</mo>${formatArg(right)}</mrow>`

      case '*':
        return `<mrow>${formatArg(left)}<mo>&cdot;</mo>${formatArg(right)}</mrow>`

      case '/':
        return `<mfrac>${formatArg(left)}${formatArg(right)}</mfrac>`

      case '^':
        return `<msup>${formatArg(left)}${formatArg(right)}</msup>`

      case '>':
        return `<mrow>${formatArg(left)}<mo>&gt;</mo>${formatArg(right)}</mrow>`

      case '<':
        return `<mrow>${formatArg(left)}<mo>&lt;</mo>${formatArg(right)}</mrow>`

      case '>=':
        return `<mrow>${formatArg(left)}<mo>&geq;</mo>${formatArg(right)}</mrow>`

      case '<=':
        return `<mrow>${formatArg(left)}<mo>&leq;</mo>${formatArg(right)}</mrow>`

      case '==':
        return `<mrow>${formatArg(left)}<mo>=</mo>${formatArg(right)}</mrow>`

      case '!=':
        return `<mrow>${formatArg(left)}<mo>&neq;</mo>${formatArg(right)}</mrow>`

      case 'and':
        return `<mrow>${formatArg(left)}<mo>&and;</mo>${formatArg(right)}</mrow>`

      case 'or':
        return `<mrow>${formatArg(left)}<mo>&or;</mo>${formatArg(right)}</mrow>`

      case 'atan2':
        return `<mrow><mi>atan2</mi><mo>(</mo>${formatArg(left)}<mo>,</mo>${formatArg(right)}<mo>)</mo></mrow>`

      case 'min':
      case 'max':
        return `<mrow><mi>${op}</mi><mo>(</mo>${formatArg(left)}<mo>,</mo>${formatArg(right)}<mo>)</mo></mrow>`
    }
  }

  // Unary operators
  if (args.length === 1) {
    const [arg] = args

    switch (op) {
      case '-':
        // Unary minus
        return `<mrow><mo>-</mo>${formatArg(arg)}</mrow>`

      case 'not':
        return `<mrow><mo>&not;</mo>${formatArg(arg)}</mrow>`

      case 'exp':
      case 'sin':
      case 'cos':
      case 'tan':
      case 'asin':
      case 'acos':
      case 'atan':
        return `<mrow><mi>${op}</mi><mo>(</mo>${formatArg(arg)}<mo>)</mo></mrow>`

      case 'log':
        return `<mrow><mi>ln</mi><mo>(</mo>${formatArg(arg)}<mo>)</mo></mrow>`

      case 'log10':
        return `<mrow><msub><mi>log</mi><mn>10</mn></msub><mo>(</mo>${formatArg(arg)}<mo>)</mo></mrow>`

      case 'sqrt':
        return `<msqrt>${formatArg(arg)}</msqrt>`

      case 'abs':
        return `<mrow><mo>|</mo>${formatArg(arg)}<mo>|</mo></mrow>`

      case 'floor':
        return `<mrow><mo>&lfloor;</mo>${formatArg(arg)}<mo>&rfloor;</mo></mrow>`

      case 'ceil':
        return `<mrow><mo>&lceil;</mo>${formatArg(arg)}<mo>&rceil;</mo></mrow>`

      case 'sign':
        return `<mrow><mi>sgn</mi><mo>(</mo>${formatArg(arg)}<mo>)</mo></mrow>`

      case 'Pre':
        return `<mrow><mi>Pre</mi><mo>(</mo>${formatArg(arg)}<mo>)</mo></mrow>`

      case 'D': {
        // Derivative operator
        const wrtVar = wrt || 't'
        return `<mfrac><mrow><mo>&part;</mo>${formatArg(arg)}</mrow><mrow><mo>&part;</mo><mi>${wrtVar}</mi></mrow></mfrac>`
      }
    }
  }

  // Ternary and n-ary operators
  if (args.length >= 3) {
    switch (op) {
      case 'ifelse':
        if (args.length === 3) {
          const [cond, thenExpr, elseExpr] = args
          return `<mrow><mi>ifelse</mi><mo>(</mo>${formatArg(cond)}<mo>,</mo>${formatArg(thenExpr)}<mo>,</mo>${formatArg(elseExpr)}<mo>)</mo></mrow>`
        }
        break

      case '+':
        // N-ary addition
        return `<mrow>${args.map((arg) => formatArg(arg)).join('<mo>+</mo>')}</mrow>`

      case '*':
        // N-ary multiplication
        return `<mrow>${args.map((arg) => formatArg(arg)).join('<mo>&cdot;</mo>')}</mrow>`

      case 'or':
        // N-ary or
        return `<mrow>${args.map((arg) => formatArg(arg)).join('<mo>&or;</mo>')}</mrow>`

      case 'max': {
        // N-ary max
        const maxArgList = args.map((arg) => formatArg(arg)).join('<mo>,</mo>')
        return `<mrow><mi>max</mi><mo>(</mo>${maxArgList}<mo>)</mo></mrow>`
      }
    }
  }

  // Fallback: function call notation
  const argList = args.map((arg) => formatArg(arg)).join('<mo>,</mo>')
  return `<mrow><mi>${op}</mi><mo>(</mo>${argList}<mo>)</mo></mrow>`
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
  if (typeof expr === 'object' && expr !== null && 'op' in expr) return `(${s})`
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
  if (value && typeof value === 'object' && 'op' in (value as object)) {
    return renderExpr(value as Expr, format)
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
  const n = node as unknown as Record<string, unknown>
  const r = (e: Expr) => renderExpr(e, format)
  const outIdx = ((n.output_idx as unknown[]) ?? []).map((o) => String(o)).join(', ')
  const exprStr = n.expr !== undefined ? r(n.expr as Expr) : ''
  const semiring = n.semiring as string | undefined
  const reduce = (n.reduce as string | undefined) ?? '+'
  const sym = aggregateSymbol(semiring, reduce, format)
  const idxPart = format === 'latex' ? `_{${outIdx}}` : `[${outIdx}]`
  let out = `${sym}${idxPart} (${exprStr})`
  const ranges = n.ranges as Record<string, unknown> | undefined
  if (ranges && Object.keys(ranges).length > 0) out += formatRangesClause(ranges, format)
  const join = n.join as Array<{ on?: string[][] }> | undefined
  if (join && join.length > 0) {
    const clauses = join
      .map((c) => (c.on ?? []).map((p) => `${p[0]}=${p[1]}`).join(', '))
      .join('; ')
    out += ` join(${clauses})`
  }
  if (n.filter !== undefined) out += ` if ${r(n.filter as Expr)}`
  if (n.distinct === true) out += ` distinct`
  if (n.key !== undefined) out += ` key=${r(n.key as Expr)}`
  if (semiring && semiring !== 'sum_product') out += ` [semiring=${semiring}]`
  return out
}

/** Render an `argmin` / `argmax` arg-witness node per the rendering contract. */
function formatArgWitness(node: ExprNode, format: TextFormat): string {
  const n = node as unknown as Record<string, unknown>
  const r = (e: Expr) => renderExpr(e, format)
  const arg = String(n.arg ?? '')
  const exprStr = n.expr !== undefined ? r(n.expr as Expr) : ''
  const idxPart = format === 'latex' ? `_{${arg}}` : `[${arg}]`
  const name = format === 'latex' ? `\\mathrm{${node.op}}` : node.op
  let out = `${name}${idxPart} (${exprStr})`
  const ranges = n.ranges as Record<string, unknown> | undefined
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
  const n = node as unknown as Record<string, unknown>
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
      const lo = n.lower !== undefined ? r(n.lower as Expr) : ''
      const hi = n.upper !== undefined ? r(n.upper as Expr) : ''
      if (format === 'latex') return `\\int_{${lo}}^{${hi}} ${f} \\, d${v}`
      if (format === 'unicode') return `∫[${lo}, ${hi}] ${f} d${v}`
      return `integral(${f}, ${v}, ${lo}, ${hi})`
    }

    case 'table_lookup': {
      const table = String(n.table ?? '')
      const axes = (n.axes as Record<string, Expr>) ?? {}
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
      const bindings = (n.bindings as Record<string, Expr>) ?? {}
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
      const regions = (n.regions as unknown[][][]) ?? []
      const values = (n.values as Expr[]) ?? []
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
      const shape = ((n.shape as unknown[]) ?? []).map((s) => formatBound(s, format)).join(', ')
      const name = format === 'latex' ? '\\mathrm{reshape}' : 'reshape'
      return `${name}(${r(args[0])}, [${shape}])`
    }

    case 'transpose': {
      if (args.length === 0) return undefined
      const perm = n.perm as number[] | undefined
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
 * Format an ExpressionNode (operator with arguments)
 */
function formatExpressionNode(node: ExprNode, format: 'unicode' | 'latex' | 'ascii'): string {
  const { op, args, wrt } = node

  const structural = formatStructuralOp(node, format)
  if (structural !== undefined) return structural

  // Helper to format arguments with proper parenthesization
  const formatArg = (arg: Expr, isRightOperand = false): string => {
    let result: string
    if (format === 'unicode') result = toUnicode(arg)
    else if (format === 'latex') result = toLatex(arg)
    else result = toAscii(arg)

    if (needsParentheses(node, arg, isRightOperand)) {
      return `(${result})`
    }
    return result
  }

  // Binary operators
  if (args.length === 2) {
    const [left, right] = args

    switch (op) {
      case '+': {
        // Simplify a + (-b) → a - b
        if (
          typeof right === 'object' &&
          right !== null &&
          'op' in right &&
          (right as ExprNode).op === '-' &&
          (right as ExprNode).args.length === 1
        ) {
          const innerArg = (right as ExprNode).args[0]
          // Format as binary subtraction
          const syntheticMinus = { op: '-', args: [left, innerArg] } as ExprNode
          let leftStr: string
          if (format === 'unicode') leftStr = toUnicode(left)
          else if (format === 'latex') leftStr = toLatex(left)
          else leftStr = toAscii(left)
          if (needsParentheses(syntheticMinus, left)) leftStr = `(${leftStr})`

          let rightStr: string
          if (format === 'unicode') rightStr = toUnicode(innerArg)
          else if (format === 'latex') rightStr = toLatex(innerArg)
          else rightStr = toAscii(innerArg)
          if (needsParentheses(syntheticMinus, innerArg, true)) rightStr = `(${rightStr})`

          if (format === 'unicode') return `${leftStr} − ${rightStr}`
          return `${leftStr} - ${rightStr}`
        }
        return `${formatArg(left)} + ${formatArg(right, true)}`
      }

      case '-':
        if (format === 'unicode') {
          return `${formatArg(left)} − ${formatArg(right, true)}`
        }
        return `${formatArg(left)} - ${formatArg(right, true)}`

      case '*':
        if (format === 'unicode') {
          return `${formatArg(left)}·${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\cdot ${formatArg(right, true)}`
        }
        return `${formatArg(left)} * ${formatArg(right, true)}`

      case '/':
        if (format === 'latex') {
          return `\\frac{${toLatex(left)}}{${toLatex(right)}}`
        } else if (format === 'unicode') {
          return `${formatArg(left)}/${formatArg(right, true)}`
        }
        return `${formatArg(left)} / ${formatArg(right, true)}`

      case '^':
        if (format === 'latex') {
          return `${formatArg(left)}^{${toLatex(right)}}`
        }
        // For unicode, try to use superscript digits
        {
          const rn = numericValue(right)
          if (format === 'unicode' && rn !== undefined && Number.isInteger(rn)) {
            return `${formatArg(left)}${toSuperscript(rn.toString())}`
          }
        }
        return `${formatArg(left)}^${formatArg(right, true)}`

      case '>':
      case '<':
        return `${formatArg(left)} ${op} ${formatArg(right, true)}`

      case '>=':
        if (format === 'unicode') {
          return `${formatArg(left)} ≥ ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\geq ${formatArg(right, true)}`
        }
        return `${formatArg(left)} ${op} ${formatArg(right, true)}`

      case '<=':
        if (format === 'unicode') {
          return `${formatArg(left)} ≤ ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\leq ${formatArg(right, true)}`
        }
        return `${formatArg(left)} ${op} ${formatArg(right, true)}`

      case '=':
      case '==':
        if (format === 'unicode') {
          return `${formatArg(left)} = ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} = ${formatArg(right, true)}`
        }
        return `${formatArg(left)} == ${formatArg(right, true)}`

      case '!=':
        if (format === 'unicode') {
          return `${formatArg(left)} ≠ ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\neq ${formatArg(right, true)}`
        }
        return `${formatArg(left)} ${op} ${formatArg(right, true)}`

      case 'and':
        if (format === 'unicode') {
          return `${formatArg(left)} ∧ ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\land ${formatArg(right, true)}`
        }
        return `${formatArg(left)} and ${formatArg(right, true)}`

      case 'or':
        if (format === 'unicode') {
          return `${formatArg(left)} ∨ ${formatArg(right, true)}`
        } else if (format === 'latex') {
          return `${formatArg(left)} \\lor ${formatArg(right, true)}`
        }
        return `${formatArg(left)} or ${formatArg(right, true)}`

      case 'atan2':
        if (format === 'latex') {
          return `\\mathrm{atan2}(${toLatex(left)}, ${toLatex(right)})`
        }
        return `atan2(${formatArg(left)}, ${formatArg(right)})`

      case 'min':
      case 'max':
        if (format === 'latex') {
          return `\\${op}(${toLatex(left)}, ${toLatex(right)})`
        }
        return `${op}(${formatArg(left)}, ${formatArg(right)})`
    }
  }

  // Unary operators
  if (args.length === 1) {
    const [arg] = args

    switch (op) {
      case '-':
        // Unary minus
        if (format === 'unicode') {
          return `−${formatArg(arg)}`
        }
        return `-${formatArg(arg)}`

      case 'not':
        if (format === 'unicode') {
          return `¬${formatArg(arg)}`
        } else if (format === 'latex') {
          return `\\neg ${formatArg(arg)}`
        }
        return `not ${formatArg(arg)}`

      case 'exp':
      case 'sin':
      case 'cos':
      case 'tan':
      case 'sinh':
      case 'cosh':
      case 'tanh':
        if (format === 'latex') {
          const latexArg = toLatex(arg)
          // Use \left( \right) when the argument contains tall elements like \frac
          if (latexArg.includes('\\frac')) {
            return `\\${op}\\left(${latexArg}\\right)`
          }
          return `\\${op}(${latexArg})`
        }
        return `${op}(${formatArg(arg)})`

      case 'log':
        if (format === 'unicode') {
          return `ln(${formatArg(arg)})`
        } else if (format === 'latex') {
          return `\\ln(${toLatex(arg)})`
        }
        return `${op}(${formatArg(arg)})`

      case 'log10':
        if (format === 'unicode') {
          return `log₁₀(${formatArg(arg)})`
        } else if (format === 'latex') {
          return `\\log_{10}(${toLatex(arg)})`
        }
        return `${op}(${formatArg(arg)})`

      case 'sqrt':
        if (format === 'unicode') {
          const argStr = toUnicode(arg)
          // Wrap compound expressions in parentheses for clarity
          if (typeof arg === 'object' && 'op' in arg) {
            return `√(${argStr})`
          }
          return `√${argStr}`
        } else if (format === 'latex') {
          return `\\sqrt{${toLatex(arg)}}`
        }
        return `${op}(${formatArg(arg)})`

      case 'abs':
        if (format === 'unicode') {
          return `|${formatArg(arg)}|`
        } else if (format === 'latex') {
          return `|${toLatex(arg)}|`
        }
        return `${op}(${formatArg(arg)})`

      case 'floor':
        if (format === 'unicode') {
          return `⌊${formatArg(arg)}⌋`
        } else if (format === 'latex') {
          return `\\lfloor ${toLatex(arg)} \\rfloor`
        }
        return `${op}(${formatArg(arg)})`

      case 'ceil':
        if (format === 'unicode') {
          return `⌈${formatArg(arg)}⌉`
        } else if (format === 'latex') {
          return `\\lceil ${toLatex(arg)} \\rceil`
        }
        return `${op}(${formatArg(arg)})`

      case 'sign':
        if (format === 'unicode') {
          return `sgn(${formatArg(arg)})`
        } else if (format === 'latex') {
          return `\\mathrm{sgn}(${toLatex(arg)})`
        }
        return `${op}(${formatArg(arg)})`

      case 'asin':
      case 'acos':
      case 'atan': {
        const arcName = op.replace('a', 'arc')
        if (format === 'unicode') {
          return `${arcName}(${formatArg(arg)})`
        } else if (format === 'latex') {
          return `\\${arcName}(${toLatex(arg)})`
        }
        return `${op}(${formatArg(arg)})`
      }

      case 'asinh':
      case 'acosh':
      case 'atanh': {
        // Inverse hyperbolic: sinh⁻¹(x), \sinh^{-1}(x)
        const hypName = op.replace('a', '') // asinh → sinh
        if (format === 'unicode') {
          return `${hypName}⁻¹(${formatArg(arg)})`
        } else if (format === 'latex') {
          return `\\${hypName}^{-1}(${toLatex(arg)})`
        }
        return `${op}(${formatArg(arg)})`
      }

      case 'Pre':
        if (format === 'latex') {
          return `\\mathrm{Pre}(${toLatex(arg)})`
        }
        return `Pre(${formatArg(arg)})`

      case 'D': {
        // Derivative operator
        const wrtVar = wrt || 't'
        if (format === 'unicode') {
          const variable = toUnicode(arg)
          return `∂${variable}/∂${wrtVar}`
        } else if (format === 'latex') {
          return `\\frac{\\partial ${toLatex(arg)}}{\\partial ${wrtVar}}`
        }
        return `D(${toAscii(arg)})/D${wrtVar}`
      }
    }
  }

  // Ternary and n-ary operators
  if (args.length >= 3) {
    switch (op) {
      case 'ifelse':
        if (args.length === 3) {
          const [cond, thenExpr, elseExpr] = args
          if (format === 'latex') {
            return `\\begin{cases} ${toLatex(thenExpr)} & \\text{if } ${toLatex(cond)} \\\\ ${toLatex(elseExpr)} & \\text{otherwise} \\end{cases}`
          }
          return `ifelse(${formatArg(cond)}, ${formatArg(thenExpr)}, ${formatArg(elseExpr)})`
        }
        break

      case '+':
        // N-ary addition
        return args.map((arg) => formatArg(arg)).join(' + ')

      case '*': {
        // N-ary multiplication
        const sep = format === 'unicode' ? '·' : format === 'latex' ? ' \\cdot ' : ' * '
        return args.map((arg) => formatArg(arg)).join(sep)
      }

      case 'or':
        // N-ary or
        if (format === 'unicode') {
          return args.map((arg) => formatArg(arg)).join(' ∨ ')
        } else if (format === 'latex') {
          return args.map((arg) => formatArg(arg)).join(' \\lor ')
        }
        return args.map((arg) => formatArg(arg)).join(' or ')

      case 'max': {
        // N-ary max
        const maxArgList = args
          .map((arg) => {
            if (format === 'unicode') return toUnicode(arg)
            else if (format === 'latex') return toLatex(arg)
            else return toAscii(arg)
          })
          .join(', ')

        if (format === 'latex') {
          return `\\max(${maxArgList})`
        }
        return `max(${maxArgList})`
      }
    }
  }

  // Generic fallback: function-call notation for open-tier sugar
  // (grad/div/laplacian) and any unknown user op. Only `args` are shown.
  const argList = args
    .map((arg) => {
      if (format === 'unicode') return toUnicode(arg)
      else if (format === 'latex') return toLatex(arg)
      else return toAscii(arg)
    })
    .join(', ')

  if (format === 'latex') {
    return `\\mathrm{${latexName(op)}}(${argList})`
  }
  return `${op}(${argList})`
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
