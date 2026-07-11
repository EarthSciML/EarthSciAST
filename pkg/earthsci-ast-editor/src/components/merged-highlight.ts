/**
 * createMergedHighlight - shared hover-highlight merge primitive
 *
 * The editor components each maintain a "highlighted variables" set that is the
 * union of an externally supplied base set (e.g. the variable hovered in a
 * variables panel) and the variable currently hovered inside the component's
 * own expression tree. This helper centralizes that merge, which was previously
 * copy-pasted verbatim across EquationEditor, ExpressionEditor, and
 * ReactionEditor.
 */

import { Accessor, createMemo } from 'solid-js';

/**
 * Build a reactive set that is the base highlight set plus the currently
 * hovered variable (if any). The returned memo is stable and only recomputes
 * when either input changes.
 *
 * @param base    Accessor for the externally supplied highlight set (may be undefined)
 * @param hovered Accessor for the locally hovered variable name (or null)
 */
export function createMergedHighlight(
  base: Accessor<Set<string> | undefined>,
  hovered: Accessor<string | null>
): Accessor<Set<string>> {
  return createMemo(() => {
    const baseSet = base() ?? new Set<string>();
    const hoveredVar = hovered();

    if (hoveredVar && !baseSet.has(hoveredVar)) {
      return new Set([...baseSet, hoveredVar]);
    }
    return baseSet;
  });
}
