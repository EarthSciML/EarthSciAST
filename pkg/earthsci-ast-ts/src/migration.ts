/**
 * Migration utilities for ESM format version upgrades.
 *
 * A migration here changes the `esm` field and touches nothing else. That is
 * sound in two cases:
 *
 * 1. Along an ADDITIVE line — a run of schema releases each of which introduced
 *    its changes as additive, backward-compatible fields, so an older file
 *    already loads under the newer schema. The current additive line is
 *    `2.0.0 … <current schema version>`.
 * 2. Across the 2.0.0 break, for a 1.x document (`1.0.0 … 1.3.0`) that uses
 *    none of what 2.0.0 removed. esm 2.0.0 removes the `fn` op (the closed
 *    function registry), the `function_tables` block with the `table_lookup`
 *    op, the `skolem`, `rank`, `argmin` and `argmax` ops, and the geometry ops
 *    `intersect_polygon` and `polygon_intersection_area`, and changes nothing
 *    else, so a 1.x document that uses none of them means the same thing at
 *    2.0.0 and is relabelled. One that uses any of them is REFUSED with the
 *    `removed_op` diagnostic: replacing those constructs with `esm:std/...`
 *    template references is a rewrite, done by the one codemod
 *    (`earthsci-ast migrate`, Python `earthsci_ast.migration`), not here.
 *
 * **There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean
 * break with no deprecation path: the five declared variable types collapse to
 * two, an observed variable's `expression` becomes an equation, `data_loaders`
 * becomes a non-component `data_sources` registry, and parameter mutation moves
 * off events onto the parameter. None of that is a marker bump — every one of
 * them RESHAPES the document, and several need information (which unknowns are
 * ODE states) that only the equations carry. A 0.x source therefore yields no
 * supported targets.
 *
 * The single supported target for a migratable source is the CURRENT schema
 * version (`SCHEMA_VERSION`); arbitrary intermediate targets are deliberately
 * NOT offered — there is no per-minor transform to encode, only "bring this
 * file up to current". Sources outside both cases (newer than current, a
 * different major, or malformed) yield no supported targets.
 */

import type { EsmFile } from './types.js'
import { SCHEMA_VERSION, removedV2ConstructMessage } from './parse.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

/**
 * Error thrown when migration fails. `code` is `removed_op` when a 1.x document
 * is refused for using a construct esm 2.0.0 removed.
 */
export class MigrationError extends EsmDiagnosticError {
  constructor(message: string, code: string = ERROR_CODES.UNEXPECTED_ERROR) {
    super(code, message)
    this.name = 'MigrationError'
  }
}

/** Parsed semantic-version components, or `null` for a malformed string. */
interface SemVer {
  major: number
  minor: number
  patch: number
}

function parseVersion(version: string): SemVer | null {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(version)
  if (!m) return null
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) }
}

function compareVersions(a: SemVer, b: SemVer): number {
  return a.major - b.major || a.minor - b.minor || a.patch - b.patch
}

// The additive line runs from 2.0.0 up to (and including) the current schema
// version. Parsed once from the library's own `SCHEMA_VERSION` so this never
// hand-drifts from the embedded schema.
//
// The floor is 2.0.0: the 1.x line ended at the 2.0.0 break, which a 1.x
// document crosses only through the relabel-or-refuse step below, never as a
// plain marker bump.
const ADDITIVE_FLOOR: SemVer = { major: 2, minor: 0, patch: 0 }
const CURRENT_VERSION = parseVersion(SCHEMA_VERSION)!

// The 1.x line that crosses the 2.0.0 break by relabelling: 1.0.0 up to the last
// 1.x release.
const V1_FLOOR: SemVer = { major: 1, minor: 0, patch: 0 }
const V1_LAST: SemVer = { major: 1, minor: 3, patch: 0 }

/**
 * True when `version` sits on the additive line `2.0.0 … <current>` and can be
 * carried to the current schema version by a marker-only, no-op migration.
 */
function isOnAdditiveLine(version: SemVer): boolean {
  return (
    version.major === CURRENT_VERSION.major &&
    compareVersions(version, ADDITIVE_FLOOR) >= 0 &&
    compareVersions(version, CURRENT_VERSION) <= 0
  )
}

/**
 * True when `version` is on the 1.x line (`1.0.0 … 1.3.0`) and this build
 * implements major 2, so the document crosses the 2.0.0 break by a relabel if
 * it uses none of the removed constructs.
 */
function crossesV2Break(version: SemVer): boolean {
  return (
    CURRENT_VERSION.major === 2 &&
    compareVersions(version, V1_FLOOR) >= 0 &&
    compareVersions(version, V1_LAST) <= 0
  )
}

/**
 * Check if migration is possible from the source version to target version.
 */
export function canMigrate(sourceVersion: string, targetVersion: string): boolean {
  const supported = supportedMigrationTargets(sourceVersion)
  return supported.includes(targetVersion)
}

/**
 * Get the list of schema versions that a given source version can migrate to.
 *
 * - any version on the additive line `2.0.0 … <current schema version>` →
 *   `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
 * - a 1.x version (`1.0.0 … 1.3.0`) → `[SCHEMA_VERSION]`: the version pair is
 *   supported, and {@link migrate} relabels the document or refuses it with
 *   `removed_op`, depending on its content.
 * - everything else — including EVERY 0.x version, which 1.0.0's clean break
 *   puts out of reach of a marker bump — → `[]`.
 */
export function supportedMigrationTargets(sourceVersion: string): string[] {
  const parsed = parseVersion(sourceVersion)
  if (parsed && (isOnAdditiveLine(parsed) || crossesV2Break(parsed))) {
    return [SCHEMA_VERSION]
  }

  return []
}

/**
 * @deprecated Use {@link supportedMigrationTargets}. The canonical name is
 * `supported_migration_targets`, with no `get` prefix. Kept for one minor per
 * API_SPEC.md §10; removed at the next major.
 */
export const getSupportedMigrationTargets = supportedMigrationTargets

/**
 * Migrate an ESM file from its current schema version to the target version.
 *
 * Every supported step is a pure version-marker bump with no structural
 * transform: an additive-line source (`2.0.0 … <current>`), or a 1.x source
 * that uses none of the constructs esm 2.0.0 removed, advanced to the current
 * schema version (see the module header). A 1.x source that uses one throws
 * {@link MigrationError} with code `removed_op`, naming the construct, where it
 * sits, and the codemod that rewrites it. Any other version pair — a 0.x source
 * included — throws {@link MigrationError}. The input file is never mutated; a
 * new object with the updated `esm` marker is returned.
 */
export function migrate(file: EsmFile, targetVersion: string): EsmFile {
  const sourceVersion = file.esm
  if (!sourceVersion) {
    throw new MigrationError("Source file has no 'esm' version field")
  }

  if (!canMigrate(sourceVersion, targetVersion)) {
    throw new MigrationError(`Migration from ${sourceVersion} to ${targetVersion} is not supported`)
  }

  const source = parseVersion(sourceVersion)
  if (source !== null && crossesV2Break(source)) {
    const removed = removedV2ConstructMessage(file)
    if (removed !== null) throw new MigrationError(removed, ERROR_CODES.REMOVED_OP)
  }

  return { ...file, esm: targetVersion }
}
