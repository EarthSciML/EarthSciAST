/**
 * Grid accessor contract (ESS-side) for the 2026-04-22 grid-inversion
 * decision. ESS defines the accessor surface and registration hook;
 * concrete family implementations live in EarthSciDiscretizations (ESD)
 * and register themselves with this package at runtime.
 *
 * Method names mirror `EarthSciDiscretizations/docs/GRIDS_API.md` §2 and
 * §3.4: snake_case on the wire and on accessor methods, `camelCase` only
 * for TS-native invariants (`toESM`). See `gt-j2b8`.
 *
 * This module is signatures-only. No family is implemented here — the
 * registry starts empty and is populated by the ESD bindings.
 */

export type Dtype = 'float64' | 'float32'

/**
 * Cell index. Block-structured families use a compound index;
 * rectilinear families use `[i, j]` or a flat scalar. The accessor
 * instance defines the convention; consumers pass the index shape
 * the accessor hands out in `neighbors`.
 */
export type CellIndex = number | readonly number[]

/**
 * Geographic / cartesian center of a cell. Spherical families populate
 * `lon`/`lat`; cartesian families populate `x`/`y`/`z`. The accessor
 * may populate both for families that carry both coordinate systems.
 */
export interface CellCenter {
  readonly lon?: number
  readonly lat?: number
  readonly x?: number
  readonly y?: number
  readonly z?: number
}

/**
 * Accessor contract every ESD-provided concrete grid implements.
 * Subsumes the GRIDS_API §3.4 `Grid` interface (family/dtype/toESM)
 * and adds the three accessor methods called out in gt-j2b8.
 */
export interface GridAccessor {
  /** Family name per GRIDS_API §1, e.g. `"cartesian"`. */
  readonly family: string
  /** Element precision. Cross-binding conformance is promised at `"float64"`. */
  readonly dtype: Dtype
  /** Total cell count (interior + ghosts, consistent with `ghosts`). */
  readonly n_cells: number

  /**
   * Cell center at logical index `(i, j)`. For families with more than
   * two logical indices, wrap the extra indices in the accessor's
   * factory closure and expose a 2-D view.
   */
  cell_centers(i: number, j: number): CellCenter

  /** Indices of cells adjacent to `cell`, in family-defined order. */
  neighbors(cell: CellIndex): readonly CellIndex[]

  /**
   * Evaluate a named metric field (e.g. `"area"`, `"jac"`, `"dx"`) at
   * logical index `(i, j)`. Field names are family-specific; an
   * unknown name is a family-level error.
   */
  metric_eval(name: string, i: number, j: number): number

  /**
   * Lower to a §6-schema-valid ESM object. After `canonicalize()`
   * (§5.4.6), the result is the cross-binding conformance ground
   * truth (GRIDS_API §3.5).
   */
  toESM(): object
}

/**
 * Factory function a concrete family registers. Given the options
 * object (the same snake_case keys the `.esm` wire form carries),
 * construct and return a ready-to-use accessor.
 */
export type GridAccessorFactory = (opts: Record<string, unknown>) => GridAccessor

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export const E_GRID_FAMILY_UNKNOWN = 'E_GRID_FAMILY_UNKNOWN'
export const E_GRID_FAMILY_ALREADY_REGISTERED = 'E_GRID_FAMILY_ALREADY_REGISTERED'
export const E_GRID_FAMILY_NAME_INVALID = 'E_GRID_FAMILY_NAME_INVALID'

export class GridAccessorError extends Error {
  readonly code: string
  constructor(code: string, message?: string) {
    super(message ?? code)
    this.code = code
    this.name = 'GridAccessorError'
  }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

const registry = new Map<string, GridAccessorFactory>()

function assertValidFamilyName(name: string): void {
  if (typeof name !== 'string' || name.length === 0) {
    throw new GridAccessorError(
      E_GRID_FAMILY_NAME_INVALID,
      'grid family name must be a non-empty string',
    )
  }
}

/**
 * Register a factory for `family`. Re-registering the same family is
 * an error so downstream code cannot silently pick the wrong
 * implementation when two packages ship the same name. Use
 * `unregisterGridFamily` first if you need to swap.
 */
export function registerGridFamily(family: string, factory: GridAccessorFactory): void {
  assertValidFamilyName(family)
  if (typeof factory !== 'function') {
    throw new GridAccessorError(
      E_GRID_FAMILY_NAME_INVALID,
      `factory for grid family "${family}" must be a function`,
    )
  }
  if (registry.has(family)) {
    throw new GridAccessorError(
      E_GRID_FAMILY_ALREADY_REGISTERED,
      `grid family "${family}" is already registered`,
    )
  }
  registry.set(family, factory)
}

/**
 * Remove a registration. Returns `true` iff the family was present.
 * Intended for tests and ESD hot-reload; not a production path.
 */
export function unregisterGridFamily(family: string): boolean {
  assertValidFamilyName(family)
  return registry.delete(family)
}

/** Look up a previously-registered factory. */
export function getGridFamily(family: string): GridAccessorFactory | undefined {
  return registry.get(family)
}

/** `true` iff a factory is registered under `family`. */
export function hasGridFamily(family: string): boolean {
  return registry.has(family)
}

/**
 * All registered family names, sorted lexicographically so output is
 * deterministic across runs.
 */
export function listGridFamilies(): string[] {
  return Array.from(registry.keys()).sort()
}

/**
 * Construct a grid via the registry. Raises
 * `GridAccessorError(E_GRID_FAMILY_UNKNOWN)` if the family has no
 * registered factory.
 */
export function createGrid(family: string, opts: Record<string, unknown> = {}): GridAccessor {
  const factory = registry.get(family)
  if (factory === undefined) {
    throw new GridAccessorError(
      E_GRID_FAMILY_UNKNOWN,
      `grid family "${family}" is not registered; call registerGridFamily() first`,
    )
  }
  return factory(opts)
}

/**
 * Drop every registered family. Intended for test isolation; do not
 * call in production code.
 */
export function clearGridFamilies(): void {
  registry.clear()
}
