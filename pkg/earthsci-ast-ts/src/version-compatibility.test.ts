import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import {
  load,
  migrate,
  canMigrate,
  MigrationError,
  VERSION,
  SCHEMA_VERSION,
  SchemaValidationError,
} from './index.js'
import { readFixture } from './test-helpers.js'

/**
 * Version gating for esm 1.0.0.
 *
 * The library implements major version 1, so a DIFFERENT major is rejected
 * outright (`ParseError`) and a newer MINOR loads with a warning. 1.0.0 is a
 * clean break with no deprecation path, which puts every 0.x document on the
 * rejected side of that line — the polarity of this whole suite is inverted
 * from its 0.x form, where major 1 was the thing being refused.
 *
 * The version each case needs is applied to a base document IN MEMORY rather
 * than read from a per-version fixture. The shared
 * `tests/version_compatibility/` fixtures are named for the version they used
 * to carry, but a blanket sweep in commit 49ca9be8 rewrote every one of them to
 * declare `1.0.0` — so `version_2_5_1_major_rejection.esm` no longer declares
 * 2.5.1, and reading the version out of the file would silently test nothing.
 * Overriding the field here keeps this binding's gating coverage real
 * regardless; the fixtures themselves still need repairing for the other four
 * bindings.
 */
describe('Version Compatibility', () => {
  // A schema-valid 1.0.0 document, used as the carrier for every version under
  // test. Its own `esm` field is replaced per case.
  const baseDocument = () =>
    JSON.parse(readFixture('version_compatibility', 'version_1_0_0_major_upgrade.esm'))

  /** The base document re-stamped with `version`. */
  const atVersion = (version: string) => ({ ...baseDocument(), esm: version })

  // Capture console.warn output around a callback
  const captureWarnings = <T>(fn: () => T): { result: T; warnings: string[] } => {
    const warnings: string[] = []
    const originalWarn = console.warn
    console.warn = (...args: unknown[]) => {
      warnings.push(args.join(' '))
    }
    try {
      return { result: fn(), warnings }
    } finally {
      console.warn = originalWarn
    }
  }

  describe('Current major', () => {
    it('loads the current schema version without warnings', () => {
      const { result, warnings } = captureWarnings(() => load(atVersion(SCHEMA_VERSION)))

      expect(result.esm).toBe(SCHEMA_VERSION)
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })

    it('loads the 1.0.0 baseline without warnings', () => {
      const { result, warnings } = captureWarnings(() => load(atVersion('1.0.0')))

      expect(result.esm).toBe('1.0.0')
      expect(result.metadata.name).toBe('Version_1_0_0_MajorUpgrade')
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })

    it('loads an older patch on the same minor without warnings', () => {
      const { result, warnings } = captureWarnings(() => load(atVersion('1.0.0')))

      expect(result.esm).toBe('1.0.0')
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })
  })

  describe('Forward Compatibility', () => {
    it('warns when loading a newer minor version', () => {
      const { result, warnings } = captureWarnings(() => load(atVersion('1.10.0')))

      expect(result.esm).toBe('1.10.0')
      expect(
        warnings.some((w) =>
          w.includes(`1.10.0 is newer than the current library version ${SCHEMA_VERSION}`),
        ),
      ).toBe(true)
    })

    it('does not weaken schema validation for newer minor versions', () => {
      const withUnknownField = { ...atVersion('1.10.0'), definitely_not_a_schema_field: true }

      const { result } = captureWarnings(() =>
        (() => {
          try {
            load(withUnknownField)
            return null
          } catch (e) {
            return e
          }
        })(),
      )
      expect(result).toBeInstanceOf(SchemaValidationError)
    })
  })

  describe('Major Version Rejection', () => {
    // 1.0.0 is a clean break: a 0.x document is not "an older file that still
    // loads", it is a file written to a format this parser no longer speaks.
    it('rejects the 0.x line outright', () => {
      for (const version of ['0.0.1', '0.1.0', '0.8.0', '0.9.0', '0.10.0']) {
        expect(() => load(atVersion(version))).toThrow('Unsupported major version 0')
      }
    })

    it('rejects a newer major version', () => {
      expect(() => load(atVersion('2.5.1'))).toThrow('Unsupported major version 2')
      expect(() => load(atVersion('12.34.56'))).toThrow('Unsupported major version 12')
    })
  })

  describe('Invalid Version Handling', () => {
    it('should reject invalid version string format', () => {
      const fixture = JSON.parse(readFixture('version_compatibility', 'invalid_version_string.esm'))

      expect(() => load(fixture)).toThrow(SchemaValidationError)
    })

    it('should reject missing version field', () => {
      const fixture = JSON.parse(readFixture('version_compatibility', 'missing_version_field.esm'))

      expect(() => load(fixture)).toThrow(SchemaValidationError)
    })
  })

  describe('Migration', () => {
    // A migration is a pure version-MARKER bump, sound only along an additive
    // line. Nothing crosses the 1.0.0 boundary: the variable-model collapse,
    // the observed-expression relocation and the data_sources rename all
    // RESHAPE the document, so a 0.x source has no supported target at all
    // rather than a bump that would leave a file claiming 1.0.0 while still
    // carrying 0.x shapes.
    it('offers no migration path out of the 0.x line', () => {
      expect(canMigrate('0.0.5', '0.1.0')).toBe(false)
      expect(canMigrate('0.9.0', SCHEMA_VERSION)).toBe(false)
      expect(canMigrate('0.9.0', '1.0.0')).toBe(false)
    })

    it('canMigrate reports the additive-line bump to the current version', () => {
      expect(canMigrate('1.0.0', SCHEMA_VERSION)).toBe(true)
      // Only the CURRENT version is offered as a target, never an arbitrary
      // intermediate one.
      expect(canMigrate('1.0.0', '1.0.1')).toBe(false)
    })

    it('migrate bumps the version marker for a supported step', () => {
      const source = atVersion('1.0.0')

      const migrated = migrate(source, SCHEMA_VERSION)
      expect(migrated.esm).toBe(SCHEMA_VERSION)
      // Input is not mutated
      expect(source.esm).toBe('1.0.0')
    })

    it('migrate throws for unsupported version pairs', () => {
      expect(() => migrate(atVersion('1.0.0'), '2.0.0')).toThrow(MigrationError)
      expect(() => migrate(atVersion('0.9.0'), SCHEMA_VERSION)).toThrow(MigrationError)
    })
  })

  describe('Library Version Information', () => {
    it('exposes the schema version, kept in lockstep with package.json', () => {
      const pkg = JSON.parse(readFileSync(join(__dirname, '../package.json'), 'utf-8'))
      expect(VERSION).toBe(pkg.version)
      expect(SCHEMA_VERSION).toBe(pkg.version)
    })
  })
})
