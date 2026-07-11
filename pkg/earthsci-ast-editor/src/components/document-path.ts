/**
 * Document-dialect path replacement.
 *
 * `primitives/path-utils` is the one place for AST path logic, but its
 * exported {@link replaceExpressionAtPath} only understands the *expression*
 * dialect (alternating `'args'` segments and numeric indices, rooted at an
 * Expression). The editors address sub-nodes through container-object keys
 * first — an equation's `lhs`/`rhs`, a reaction's `rate` — before descending
 * into expression args, so the path they hand to `onReplace` is a *document*
 * path rooted at that container (e.g. `['rhs', 'args', 0]`, `['rate', 'args',
 * 1]`).
 *
 * That document dialect is genuinely absent from path-utils (only the read-only
 * {@link getValueAtPath} navigates arbitrary keys; there is no set/replace
 * counterpart), so this small helper lives here — component-owned — rather than
 * editing path-utils. It replaces the value at an arbitrary object-key /
 * array-index path within a plain-JSON structure and returns a new root; the
 * input is not mutated. Unlike the previous hand-rolled per-component walkers,
 * it fails loudly on an unresolvable path instead of silently corrupting the
 * tree.
 */

import type { Path } from '../primitives/path-utils';

export function replaceAtDocumentPath<T>(root: T, path: Path, newValue: unknown): T {
  if (path.length === 0) {
    return newValue as T;
  }

  const clone = structuredClone(root);

  // Navigate to the parent of the target segment.
  let current: unknown = clone;
  for (let i = 0; i < path.length - 1; i++) {
    if (current == null || typeof current !== 'object') {
      throw new Error(`replaceAtDocumentPath: path does not resolve at segment "${String(path[i])}"`);
    }
    current = (current as Record<PropertyKey, unknown>)[path[i]];
  }

  if (current == null || typeof current !== 'object') {
    throw new Error(`replaceAtDocumentPath: parent of "${String(path[path.length - 1])}" is not a container`);
  }

  (current as Record<PropertyKey, unknown>)[path[path.length - 1]] = newValue;
  return clone;
}
