/**
 * Migration utilities for ESM format version upgrades.
 *
 * Provides functions to migrate ESM files between schema versions.
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
 * The supported 0.0.5 → 0.1.0 step is a version-marker bump: no structural
 * transforms were introduced between those schema versions. Content-level
 * changes (e.g. converting unit conventions) are not performed — they are
 * modeling decisions, not mechanical migrations.
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
