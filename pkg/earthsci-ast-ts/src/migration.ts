/**
 * Migration utilities for ESM format version upgrades.
 *
 * A migration here is a pure version-MARKER bump: it changes the `esm` field
 * and touches nothing else. That is only ever sound along an ADDITIVE line —
 * a run of schema releases each of which introduced its changes as additive,
 * backward-compatible fields, so an older file already loads under the newer
 * schema without any mechanical transform.
 *
 * The current additive line is `1.0.0 … <current schema version>`.
 *
 * **There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean
 * break with no deprecation path: the five declared variable types collapse to
 * two, an observed variable's `expression` becomes an equation, `data_loaders`
 * becomes a non-component `data_sources` registry, and parameter mutation moves
 * off events onto the parameter. None of that is a marker bump — every one of
 * them RESHAPES the document, and several need information (which unknowns are
 * ODE states) that only the equations carry. A 0.x source therefore yields no
 * supported targets rather than a bump that would produce a file claiming 1.0.0
 * while still carrying 0.x shapes. Converting a 0.x document is a rewrite, and
 * deliberately not offered as an automated one.
 *
 * The single supported target for an additive-line source is the CURRENT schema
 * version (`SCHEMA_VERSION`); arbitrary intermediate targets are deliberately
 * NOT offered — there is no per-minor transform to encode, only "bring this
 * file up to current". Sources outside that line (newer than current, a
 * different major, or malformed) yield no supported targets.
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

// The additive line runs from 1.0.0 up to (and including) the current schema
// version. Parsed once from the library's own `SCHEMA_VERSION` so this never
// hand-drifts from the embedded schema.
//
// The floor is 1.0.0, not 0.1.0: the 0.x line ended at a clean break, so no 0.x
// version can be carried forward by a marker bump. `isOnAdditiveLine` already
// requires the majors to agree, which makes a 0.x source ineligible on its own;
// the floor is stated at 1.0.0 as well so the intent survives the next major.
const ADDITIVE_FLOOR: SemVer = { major: 1, minor: 0, patch: 0 }
const CURRENT_VERSION = parseVersion(SCHEMA_VERSION)!

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
 * - any version on the additive line `1.0.0 … <current schema version>` →
 *   `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
 * - everything else — including EVERY 0.x version, which 1.0.0's clean break
 *   puts out of reach of a marker bump — → `[]`.
 */
export function getSupportedMigrationTargets(sourceVersion: string): string[] {
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
 * transform: an additive-line source (`1.0.0 … <current>`) advanced to the
 * current schema version (see the module header). Any other version pair — a
 * 0.x source included — throws {@link MigrationError}. Content-level changes
 * are not performed; they are modeling decisions, not mechanical migrations.
 * The input file is never mutated; a new object with the updated `esm` marker
 * is returned.
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
