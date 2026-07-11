/**
 * Chemical formula rendering — thin editor-facing wrapper over the core renderer.
 *
 * Element-aware Unicode subscript formatting (e.g. "H2SO4" → "H₂SO₄", "jNO2" →
 * "jNO₂") is implemented once in @earthsciml/ast as `formatChemicalName` (the
 * same 118-element table and greedy 2-char-before-1-char matching this module
 * used to duplicate). It now delegates to that core export so a species renders
 * identically in the editor and in core graph / label output.
 *
 * Kept as a named editor primitive because ExpressionNode (variables in
 * expressions) and ReactionEditor (species in reaction lines and panels) import
 * `renderChemicalName` directly; the wrapper is the single seam through which
 * the editor consumes the core renderer.
 */

import { formatChemicalName } from '@earthsciml/ast';

/**
 * Apply element-aware chemical subscript formatting to a variable / species
 * name (e.g. "H2SO4" → "H₂SO₄"), leaving non-chemical identifiers untouched.
 *
 * Delegates to the core `formatChemicalName`; the output is byte-identical to
 * the editor's former hand-rolled renderer across the full species range.
 */
export function renderChemicalName(variable: string): string {
  return formatChemicalName(variable);
}
