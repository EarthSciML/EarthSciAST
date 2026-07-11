/**
 * Migration utilities for ESM format version upgrades.
 *
 * LEGACY SCOPE. The only migration this module knows is the historical
 * `0.0.5 → 0.1.0` step, which was a pure version-MARKER bump (no structural
 * transform). Every schema release since (up to the current 0.8.0) introduced
 * its changes as ADDITIVE, backward-compatible fields, so an older file already
 * loads under the current schema without a mechanical migration — there is no
 * `0.1.0 → …` transform to encode, and the table is intentionally NOT extended
 * to newer versions. `getSupportedMigrationTargets` therefore returns `[]` for
 * any source other than `0.0.5`, and content-level changes (e.g. converting
 * unit conventions) remain modeling decisions, not automated migrations.
 */

import type { EsmFile } from './types.js'

/**
 * Error thrown when migration fails.
 */
export class MigrationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'MigrationError'
  }
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
 * Legacy shim: the table encodes only the historical `0.0.5 → 0.1.0` marker
 * bump (see the module header). Any other source version returns `[]`.
 */
export function getSupportedMigrationTargets(sourceVersion: string): string[] {
  const migrations: Record<string, string[]> = {
    '0.0.5': ['0.1.0'],
  }
  return migrations[sourceVersion] || []
}

/**
 * Migrate an ESM file from its current schema version to the target version.
 *
 * LEGACY: the only supported step is `0.0.5 → 0.1.0`, a version-marker bump
 * with no structural transform (see the module header for why the table is not
 * extended to newer schema versions). Any other version pair throws
 * {@link MigrationError}. Content-level changes (e.g. converting unit
 * conventions) are not performed — they are modeling decisions, not mechanical
 * migrations.
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
