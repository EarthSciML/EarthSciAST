/**
 * Tests for the version-migration utilities.
 *
 * Two supported kinds of pure version-marker migration are exercised:
 *   1. the legacy single step `0.0.5 → 0.1.0`, and
 *   2. the additive line `0.1.0 … <current schema version>` → current schema
 *      version (a no-op marker bump).
 *
 * The cross-file `version-compatibility.test.ts` pins the legacy edges
 * (`0.0.5 → 0.1.0` supported; `0.0.5 → 0.2.0`, `0.1.0 → 0.2.0` unsupported;
 * `0.0.5 → 0.8.0` throws); this file additionally covers the additive-line
 * bump-to-current behavior and the reject cases.
 */

import { describe, it, expect } from 'vitest'
import { migrate, canMigrate, getSupportedMigrationTargets, MigrationError } from './migration.js'
import { SCHEMA_VERSION } from './parse.js'
import type { EsmFile } from './types.js'

const fileAt = (version: string): EsmFile =>
  ({ esm: version, metadata: { name: 'test' } }) as unknown as EsmFile

describe('migration', () => {
  describe('getSupportedMigrationTargets', () => {
    it('keeps the legacy 0.0.5 → 0.1.0 step (and nothing else) for 0.0.5', () => {
      expect(getSupportedMigrationTargets('0.0.5')).toEqual(['0.1.0'])
    })

    it('offers a no-op bump to the current schema for additive-line sources', () => {
      for (const source of ['0.1.0', '0.1.5', '0.2.0', '0.3.0', SCHEMA_VERSION]) {
        expect(getSupportedMigrationTargets(source)).toEqual([SCHEMA_VERSION])
      }
    })

    it('returns [] for a version newer than the current schema', () => {
      // 0.99.0 is on the same major but beyond the current additive ceiling.
      expect(getSupportedMigrationTargets('0.99.0')).toEqual([])
    })

    it('returns [] for a non-zero major version', () => {
      expect(getSupportedMigrationTargets('1.0.0')).toEqual([])
    })

    it('returns [] for a malformed version string', () => {
      expect(getSupportedMigrationTargets('not-a-version')).toEqual([])
      expect(getSupportedMigrationTargets('0.1')).toEqual([])
    })
  })

  describe('canMigrate', () => {
    it('accepts the legacy 0.0.5 → 0.1.0 step', () => {
      expect(canMigrate('0.0.5', '0.1.0')).toBe(true)
    })

    it('accepts an additive-line source bumped to the current schema', () => {
      expect(canMigrate('0.1.0', SCHEMA_VERSION)).toBe(true)
      expect(canMigrate('0.3.0', SCHEMA_VERSION)).toBe(true)
    })

    it('accepts a current-version file migrated to itself (identity no-op)', () => {
      expect(canMigrate(SCHEMA_VERSION, SCHEMA_VERSION)).toBe(true)
    })

    it('rejects an additive-line source targeting an intermediate (non-current) version', () => {
      // Only the current schema is a valid target; per-minor jumps are not offered.
      expect(canMigrate('0.1.0', '0.2.0')).toBe(false)
      expect(canMigrate('0.0.5', '0.2.0')).toBe(false)
    })

    it('rejects a single 0.0.5 → current jump (must go via 0.1.0)', () => {
      expect(canMigrate('0.0.5', SCHEMA_VERSION)).toBe(false)
    })
  })

  describe('migrate', () => {
    it('bumps the marker for the legacy 0.0.5 → 0.1.0 step without mutating input', () => {
      const source = fileAt('0.0.5')
      const migrated = migrate(source, '0.1.0')

      expect(migrated.esm).toBe('0.1.0')
      expect(migrated).not.toBe(source)
      expect(source.esm).toBe('0.0.5')
    })

    it('bumps an additive-line file up to the current schema version', () => {
      const source = fileAt('0.3.0')
      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.esm).toBe(SCHEMA_VERSION)
      expect(source.esm).toBe('0.3.0')
    })

    it('accepts migrating a current-version file to the current schema (no-op)', () => {
      const source = fileAt(SCHEMA_VERSION)
      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.esm).toBe(SCHEMA_VERSION)
      // A no-op marker bump still returns a fresh object.
      expect(migrated).not.toBe(source)
    })

    it('preserves all other fields untouched (marker-only bump)', () => {
      const source = {
        esm: '0.2.0',
        metadata: { name: 'keep-me' },
        models: { M: { variables: {}, equations: [] } },
      } as unknown as EsmFile

      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.metadata).toEqual(source.metadata)
      expect(migrated.models).toEqual(source.models)
    })

    it('throws MigrationError for an unsupported version pair', () => {
      expect(() => migrate(fileAt('0.0.5'), SCHEMA_VERSION)).toThrow(MigrationError)
      expect(() => migrate(fileAt('0.1.0'), '0.2.0')).toThrow(MigrationError)
      expect(() => migrate(fileAt('1.0.0'), SCHEMA_VERSION)).toThrow(MigrationError)
    })

    it("throws when the source file has no 'esm' field", () => {
      const noVersion = { metadata: { name: 'x' } } as unknown as EsmFile
      expect(() => migrate(noVersion, SCHEMA_VERSION)).toThrow(MigrationError)
    })
  })
})
