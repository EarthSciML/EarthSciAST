/**
 * Path Utilities - Single shared implementation of AST/document path helpers
 *
 * This module is the one place where path navigation, comparison, and
 * expression-tree replacement logic live. It is consumed by:
 * - selection.tsx (selection + inline editing)
 * - structural-editing.tsx (wrap/unwrap/reorder operations)
 * - ast-store.ts (document-level path get/set and the `PathUtils` export)
 *
 * Two path dialects are supported:
 * - Expression paths: alternate `'args'` segments and numeric indices into an
 *   ESM expression tree (e.g. `['args', 0, 'args', 1]`).
 * - Document paths: arbitrary object/array property chains into an ESM file
 *   (e.g. `['components', 'Chemistry', 'variables', 'O3']`).
 */

import type { Expression } from '@earthsciml/ast';

/** Path segment for navigating nested structures */
export type PathSegment = string | number;

/** Path for addressing nested properties */
export type Path = PathSegment[];

/**
 * Navigate an arbitrary object/array structure and return the value at the
 * given document path, or `undefined` when the path does not resolve.
 */
export function getValueAtPath(obj: unknown, path: Path): unknown {
  if (path.length === 0) return obj;

  let current: any = obj;
  for (const segment of path) {
    if (current == null) return undefined;
    current = current[segment];
  }
  return current;
}

/**
 * Get the sub-expression at a given expression path.
 *
 * Expression paths alternate `'args'` segments (moving into an operator
 * node's argument list) with numeric indices (selecting an argument).
 * Returns `null` when the path does not resolve.
 */
export function getExpressionAtPath(expr: Expression, path: Path): Expression | null {
  let current: any = expr;

  for (const segment of path) {
    if (current == null) return null;

    if (segment === 'args' && typeof current === 'object' && 'args' in current) {
      // Move to the args array
      current = current.args;
    } else if (typeof segment === 'number' && Array.isArray(current)) {
      // Access array element by index
      current = current[segment];
    } else {
      // Invalid path segment for current context
      return null;
    }
  }

  return current;
}

/**
 * Replace the sub-expression at a given expression path, returning a new
 * root expression (the input is not mutated).
 *
 * @throws when the path does not resolve to a replaceable position
 */
export function replaceExpressionAtPath(
  rootExpr: Expression,
  path: Path,
  newExpr: Expression
): Expression {
  if (path.length === 0) {
    return newExpr;
  }

  // Make a deep copy of the root expression
  const newRoot = JSON.parse(JSON.stringify(rootExpr));
  let current: any = newRoot;

  // Navigate to the parent of the target
  for (let i = 0; i < path.length - 1; i++) {
    const segment = path[i];
    if (segment === 'args' && typeof current === 'object' && 'args' in current) {
      current = current.args;
    } else if (typeof segment === 'number' && Array.isArray(current)) {
      current = current[segment];
    } else {
      throw new Error(`Invalid path segment: ${segment}`);
    }
  }

  // Replace at the final segment
  const lastSegment = path[path.length - 1];
  if (typeof lastSegment === 'number' && Array.isArray(current)) {
    current[lastSegment] = newExpr;
  } else {
    throw new Error(`Invalid final path segment: ${lastSegment}`);
  }

  return newRoot;
}

/** Check if two paths are equal segment-by-segment */
export function pathsEqual(path1: Path, path2: Path): boolean {
  if (path1.length !== path2.length) return false;
  return path1.every((segment, i) => segment === path2[i]);
}

/** Convert a path array to a dot-separated string */
export function pathToString(path: Path): string {
  return path.join('.');
}

/**
 * Convert a dot-separated string to a path array, converting numeric
 * segments to numbers (expression-path dialect, e.g. `'args.0'` →
 * `['args', 0]`).
 */
export function stringToPath(pathStr: string): Path {
  if (!pathStr) return [];
  return pathStr.split('.').map(segment => {
    const num = parseInt(segment, 10);
    return isNaN(num) ? segment : num;
  });
}

/**
 * Utility object for common document-path operations.
 * (Historically exported from ast-store; kept as the same shape.)
 */
export const PathUtils = {
  /**
   * Convert a dot-separated string to a path array. Unlike
   * {@link stringToPath}, segments stay strings (document-path dialect,
   * where numeric-looking object keys are legal).
   */
  fromString: (pathString: string): Path => {
    return pathString.split('.').filter(segment => segment.length > 0);
  },

  /** Convert a path array to a dot-separated string */
  toString: pathToString,

  /** Check if two paths are equal */
  equals: pathsEqual,

  /** Check if `parent` is a strict ancestor of `child` */
  isParent: (parent: Path, child: Path): boolean => {
    if (parent.length >= child.length) return false;
    return parent.every((segment, i) => segment === child[i]);
  },

  /** Get the parent path (all segments except the last) */
  parent: (path: Path): Path => {
    return path.slice(0, -1);
  },

  /** Get the last segment of a path */
  lastSegment: (path: Path): PathSegment | undefined => {
    return path[path.length - 1];
  },

  /** Append a segment to a path */
  append: (path: Path, segment: PathSegment): Path => {
    return [...path, segment];
  }
};
