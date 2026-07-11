/**
 * Migration utilities for ESM format version upgrades.
 *
 * Two kinds of migration are supported, both of which are pure version-MARKER
 * bumps (they change the `esm` field and touch nothing else):
 *
 *   1. The historical `0.0.5 → 0.1.0` step. `0.0.5` predates the additive line
 *      and can migrate ONLY to `0.1.0` (its documented single step). Reaching a
 *      newer schema from `0.0.5` is a two-step upgrade (`0.0.5 → 0.1.0`, then
 *      `0.1.0 → <current>`), never a single jump.
 *
 *   2. The **additive line** `0.1.0 … <current schema version>` (currently
 *      0.8.0). Every schema release on this line introduced its changes as
 *      ADDITIVE, backward-compatible fields, so an older file already loads
 *      under the current schema without any mechanical transform. Migrating such
 *      a file to the current schema version is therefore a no-op identity
 *      migration that only advances the `esm` marker — which is exactly what
 *      lets a current-version (0.8.0) file be migrated to 0.8.0 at all.
 *
 * The single supported target for an additive-line source is the CURRENT schema
 * version (`SCHEMA_VERSION`); arbitrary intermediate targets (e.g. `0.1.0 →
 * 0.2.0`) are deliberately NOT offered — there is no per-minor transform to
 * encode, only "bring this file up to current". Content-level changes (e.g.
 * converting unit conventions) remain modeling decisions, not automated
 * migrations. Sources outside these two cases (newer-than-current, or a
 * non-zero major version) yield no supported targets.
 */

import type { EsmFile } from './types.js'
import { SCHEMA_VERSION } from './parse.js'

/**
 * Error thrown when migration fails.
 */
export class MigrationError extends Error {
  constructor(message: string) {
    super(message)
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

// The additive line runs from 0.1.0 up to (and including) the current schema
// version. Parsed once from the library's own `SCHEMA_VERSION` so this table
// never hand-drifts from the embedded schema (currently 0.8.0).
const ADDITIVE_FLOOR: SemVer = { major: 0, minor: 1, patch: 0 }
const CURRENT_VERSION = parseVersion(SCHEMA_VERSION)!

/**
 * Historical, pre-additive-line migrations that are NOT a bump-to-current.
 * `0.0.5` can only ever step to `0.1.0`.
 */
const LEGACY_MIGRATIONS: Record<string, string[]> = {
  '0.0.5': ['0.1.0'],
}

/**
 * True when `version` sits on the additive line `0.1.0 … <current>` and can be
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
 * Check if migration is possible from the source version to target version.
 */
export function canMigrate(sourceVersion: string, targetVersion: string): boolean {
  const supported = getSupportedMigrationTargets(sourceVersion)
  return supported.includes(targetVersion)
}

/**
 * Get the list of schema versions that a given source version can migrate to.
 *
 * - `0.0.5` → `['0.1.0']` (the legacy single step; see the module header).
 * - any version on the additive line `0.1.0 … <current schema version>` →
 *   `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
 * - everything else (newer than current, non-zero major, or malformed) → `[]`.
 */
export function getSupportedMigrationTargets(sourceVersion: string): string[] {
  if (sourceVersion in LEGACY_MIGRATIONS) {
    return LEGACY_MIGRATIONS[sourceVersion]
  }

  const parsed = parseVersion(sourceVersion)
  if (parsed && isOnAdditiveLine(parsed)) {
    return [SCHEMA_VERSION]
  }

  return []
}

/**
 * Migrate an ESM file from its current schema version to the target version.
 *
 * Every supported step is a pure version-marker bump with no structural
 * transform: the legacy `0.0.5 → 0.1.0` step, or an additive-line source
 * (`0.1.0 … <current>`) advanced to the current schema version (see the module
 * header). Any other version pair throws {@link MigrationError}. Content-level
 * changes (e.g. converting unit conventions) are not performed — they are
 * modeling decisions, not mechanical migrations. The input file is never
 * mutated; a new object with the updated `esm` marker is returned.
 */
export function migrate(file: EsmFile, targetVersion: string): EsmFile {
  const sourceVersion = file.esm
  if (!sourceVersion) {
    throw new MigrationError("Source file has no 'esm' version field")
  }

  if (!canMigrate(sourceVersion, targetVersion)) {
    throw new MigrationError(`Migration from ${sourceVersion} to ${targetVersion} is not supported`)
  }

  return { ...file, esm: targetVersion }
}
