/**
 * Chemical formula rendering - shared, element-aware subscript formatting
 *
 * Single implementation of chemical-name rendering used by ExpressionNode
 * (variables in expressions) and ReactionEditor (species in reaction lines
 * and panels), so a species renders identically everywhere.
 *
 * Uses greedy 2-char-before-1-char element matching against the periodic
 * table, converting stoichiometric digits to Unicode subscripts (NO2 → NO₂)
 * while leaving non-chemical identifiers untouched.
 */

// Element lookup table for chemical subscript detection (118 elements)
export const ELEMENTS = new Set([
  // Period 1
  'H', 'He',
  // Period 2
  'Li', 'Be', 'B', 'C', 'N', 'O', 'F', 'Ne',
  // Period 3
  'Na', 'Mg', 'Al', 'Si', 'P', 'S', 'Cl', 'Ar',
  // Period 4
  'K', 'Ca', 'Sc', 'Ti', 'V', 'Cr', 'Mn', 'Fe', 'Co', 'Ni', 'Cu', 'Zn', 'Ga', 'Ge', 'As', 'Se', 'Br', 'Kr',
  // Period 5
  'Rb', 'Sr', 'Y', 'Zr', 'Nb', 'Mo', 'Tc', 'Ru', 'Rh', 'Pd', 'Ag', 'Cd', 'In', 'Sn', 'Sb', 'Te', 'I', 'Xe',
  // Period 6
  'Cs', 'Ba', 'La', 'Ce', 'Pr', 'Nd', 'Pm', 'Sm', 'Eu', 'Gd', 'Tb', 'Dy', 'Ho', 'Er', 'Tm', 'Yb', 'Lu',
  'Hf', 'Ta', 'W', 'Re', 'Os', 'Ir', 'Pt', 'Au', 'Hg', 'Tl', 'Pb', 'Bi', 'Po', 'At', 'Rn',
  // Period 7
  'Fr', 'Ra', 'Ac', 'Th', 'Pa', 'U', 'Np', 'Pu', 'Am', 'Cm', 'Bk', 'Cf', 'Es', 'Fm', 'Md', 'No', 'Lr',
  'Rf', 'Db', 'Sg', 'Bh', 'Hs', 'Mt', 'Ds', 'Rg', 'Cn', 'Nh', 'Fl', 'Mc', 'Lv', 'Ts', 'Og'
]);

// Unicode subscripts for digits 0-9
export const SUBSCRIPT_DIGITS = '₀₁₂₃₄₅₆₇₈₉';

/**
 * Check if a variable has element patterns (for chemical formula detection).
 * Must be PURELY a chemical formula (no non-element characters).
 */
export function hasElementPattern(variable: string): boolean {
  // Remove underscores for pure chemical formula check
  const cleanVariable = variable.replace(/_/g, '');

  let i = 0;
  let hasElement = false;

  while (i < cleanVariable.length) {
    // Skip non-alphabetic characters
    while (i < cleanVariable.length && !/[A-Za-z]/.test(cleanVariable[i])) {
      i++;
    }
    if (i >= cleanVariable.length) break;

    // Greedy match: try 2-character element first, then 1-character
    let matchLength = 0;
    if (i + 1 < cleanVariable.length && ELEMENTS.has(cleanVariable.slice(i, i + 2))) {
      matchLength = 2;
    } else if (ELEMENTS.has(cleanVariable[i])) {
      matchLength = 1;
    }

    // A non-element alphabetic character means this is not a pure formula
    if (matchLength === 0) {
      return false;
    }

    hasElement = true;
    i += matchLength;
    // Skip stoichiometric digits
    while (i < cleanVariable.length && /\d/.test(cleanVariable[i])) {
      i++;
    }
  }

  return hasElement;
}

/**
 * Extract chemical formula suffix from a variable name
 */
export function getChemicalSuffix(variable: string): { prefix: string; suffix: string } | null {
  // Handle patterns like k_NO_O3 (with underscore)
  if (variable.includes('_')) {
    const parts = variable.split('_');
    if (parts.length === 2) {
      const [prefix, suffix] = parts;
      if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
        return { prefix, suffix };
      }
    }
    // For patterns like k_NO_O3, try treating NO_O3 as the chemical part
    if (parts.length === 3) {
      const prefix = parts[0];
      const suffix = parts.slice(1).join('_');  // Keep underscore within chemical formula
      if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
        return { prefix, suffix };
      }
    }
  }

  // Handle patterns like jNO2 (without underscore)
  // Try each position to split into non-element prefix and element suffix
  for (let i = 1; i < variable.length; i++) {
    const prefix = variable.substring(0, i);
    const suffix = variable.substring(i);

    if (hasElementPattern(suffix) && !hasElementPattern(prefix)) {
      return { prefix, suffix };
    }
  }

  return null;
}

/**
 * Apply element-aware chemical subscript formatting to a variable name.
 * Uses greedy 2-char-before-1-char matching for element detection.
 */
export function renderChemicalName(variable: string): string {
  // Check if variable looks like a chemical formula (starts with element and has digits)
  const hasElements = hasElementPattern(variable);

  if (!hasElements) {
    // Check if it's a mixed variable (non-element prefix + chemical suffix)
    const chemicalInfo = getChemicalSuffix(variable);
    if (chemicalInfo) {
      // Split into prefix and chemical part
      const { prefix, suffix } = chemicalInfo;
      const chemicalPart = renderChemicalName(suffix);
      // For variables without underscores (like jNO2), don't add underscores
      if (!variable.includes('_')) {
        return `${prefix}${chemicalPart}`;
      }
      // For variables with underscores (like k_NO_O3), preserve them
      return `${prefix}_${chemicalPart}`;
    }
    // No element pattern found, return as-is
    return variable;
  }

  // For element-aware subscript detection
  let result = '';
  let i = 0;

  while (i < variable.length) {
    // Greedy match: try 2-character element first, then 1-character
    let matchLength = 0;
    if (i + 1 < variable.length && ELEMENTS.has(variable.slice(i, i + 2))) {
      matchLength = 2;
    } else if (ELEMENTS.has(variable[i])) {
      matchLength = 1;
    }

    if (matchLength > 0) {
      result += variable.slice(i, i + matchLength);
      i += matchLength;
      // Convert following digits to subscripts
      while (i < variable.length && /\d/.test(variable[i])) {
        result += SUBSCRIPT_DIGITS[parseInt(variable[i], 10)];
        i++;
      }
    } else {
      // Not an element, copy character as-is
      result += variable[i];
      i++;
    }
  }

  return result;
}
