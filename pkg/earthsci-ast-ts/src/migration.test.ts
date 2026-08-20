/**
 * Tests for the version-migration utilities.
 *
 * A migration is a pure version-MARKER bump, sound only along an ADDITIVE line
 * — a run of releases whose changes were additive, so an older file already
 * loads under the newer schema. The current line is
 * `1.0.0 … <current schema version>`.
 *
 * Nothing crosses the 1.0.0 boundary. esm 1.0.0 is a clean break: the five
 * declared variable types collapse to two, an observed variable's `expression`
 * becomes an equation, `data_loaders` becomes a non-component `data_sources`
 * registry, and parameter mutation moves off events onto the parameter. Each of
 * those RESHAPES the document, and several need information only the equations
 * carry, so a 0.x source has no supported target at all. Offering one would
 * produce a file claiming 1.0.0 while still carrying 0.x shapes — worse than
 * refusing, because the claim would be believed.
 */

import { describe, it, expect } from 'vitest'
import { migrate, canMigrate, getSupportedMigrationTargets, MigrationError } from './migration.js'
import { SCHEMA_VERSION } from './parse.js'
import type { EsmFile } from './types.js'

const fileAt = (version: string): EsmFile =>
  ({ esm: version, metadata: { name: 'test' } }) as unknown as EsmFile

describe('migration', () => {
  describe('getSupportedMigrationTargets', () => {
    it('offers no target for any 0.x source, the clean break being uncrossable', () => {
      for (const source of ['0.0.5', '0.1.0', '0.3.0', '0.8.0', '0.9.0']) {
        expect(getSupportedMigrationTargets(source)).toEqual([])
      }
    })

    it('offers a no-op bump to the current schema for additive-line sources', () => {
      for (const source of ['1.0.0', SCHEMA_VERSION]) {
        expect(getSupportedMigrationTargets(source)).toEqual([SCHEMA_VERSION])
      }
    })

    it('returns [] for a version newer than the current schema', () => {
      // Same major, but beyond the current additive ceiling.
      expect(getSupportedMigrationTargets('1.99.0')).toEqual([])
    })

    it('returns [] for a higher major version', () => {
      expect(getSupportedMigrationTargets('2.0.0')).toEqual([])
    })

    it('returns [] for a malformed version string', () => {
      expect(getSupportedMigrationTargets('not-a-version')).toEqual([])
      expect(getSupportedMigrationTargets('1.0')).toEqual([])
    })
  })

  describe('canMigrate', () => {
    it('rejects every 0.x source, whatever the target', () => {
      expect(canMigrate('0.0.5', '0.1.0')).toBe(false)
      expect(canMigrate('0.9.0', '1.0.0')).toBe(false)
      expect(canMigrate('0.9.0', SCHEMA_VERSION)).toBe(false)
    })

    it('accepts an additive-line source bumped to the current schema', () => {
      expect(canMigrate('1.0.0', SCHEMA_VERSION)).toBe(true)
    })

    it('accepts a current-version file migrated to itself (identity no-op)', () => {
      expect(canMigrate(SCHEMA_VERSION, SCHEMA_VERSION)).toBe(true)
    })

    it('rejects an additive-line source targeting an intermediate (non-current) version', () => {
      // Only the current schema is a valid target; per-minor jumps are not offered.
      expect(canMigrate('1.0.0', '1.0.1')).toBe(false)
      expect(canMigrate('1.0.0', '2.0.0')).toBe(false)
    })
  })

  describe('migrate', () => {
    it('refuses a 0.x source rather than bumping its marker', () => {
      const source = fileAt('0.9.0')
      expect(() => migrate(source, SCHEMA_VERSION)).toThrow(MigrationError)
      // The input is left alone.
      expect(source.esm).toBe('0.9.0')
    })

    it('bumps an additive-line file up to the current schema version', () => {
      const source = fileAt('1.0.0')
      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.esm).toBe(SCHEMA_VERSION)
      expect(migrated).not.toBe(source)
      expect(source.esm).toBe('1.0.0')
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
        esm: '1.0.0',
        metadata: { name: 'keep-me' },
        models: { M: { variables: {}, equations: [] } },
      } as unknown as EsmFile

      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.metadata).toEqual(source.metadata)
      expect(migrated.models).toEqual(source.models)
    })

    it('throws MigrationError for an unsupported version pair', () => {
      expect(() => migrate(fileAt('1.0.0'), '2.0.0')).toThrow(MigrationError)
      expect(() => migrate(fileAt('0.1.0'), SCHEMA_VERSION)).toThrow(MigrationError)
    })

    it("throws when the source file has no 'esm' field", () => {
      const noVersion = { metadata: { name: 'x' } } as unknown as EsmFile
      expect(() => migrate(noVersion, SCHEMA_VERSION)).toThrow(MigrationError)
    })
  })
})
