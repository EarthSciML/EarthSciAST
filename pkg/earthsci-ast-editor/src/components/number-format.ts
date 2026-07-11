/**
 * Number-formatting utilities for the interactive expression renderer.
 *
 * These are pure helpers extracted from ExpressionNode so the component file
 * stays focused on rendering. They format numeric literals per ESM spec
 * Section 6.1 and classify variable-vs-numeric strings.
 */

/** Whether a string is a numeric literal (as opposed to a variable name). */
export function isNumericString(str: string): boolean {
  return /^-?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(str);
}

/** Convert a number to a Unicode-superscript string (e.g. -4 → "⁻⁴"). */
function formatSuperscript(exp: number): string {
  const superscriptMap: { [key: string]: string } = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
    '-': '⁻', '+': '⁺'
  };

  return exp.toString().split('').map(char => superscriptMap[char] || char).join('');
}

/** Format a numeric literal for display (ESM spec Section 6.1). */
export function formatNumber(num: number): string {
  if (num === 0) return '0';

  const absNum = Math.abs(num);

  // Use scientific notation for very small or large numbers
  if (absNum < 0.01 || absNum >= 10000) {
    const exp = num.toExponential();
    const [mantissa, exponent] = exp.split('e');

    // Convert to Unicode superscript notation
    const cleanMantissa = parseFloat(mantissa).toString(); // Remove trailing zeros
    const expNum = parseInt(exponent, 10);
    const superscriptExp = formatSuperscript(expNum);

    return `${cleanMantissa}×10${superscriptExp}`;
  }

  // Integers and decimals both render via toString().
  return num.toString();
}
