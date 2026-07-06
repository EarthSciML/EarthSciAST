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

// Path to version compatibility test fixtures
const fixturesPath = '../../../tests/version_compatibility'

describe('Version Compatibility', () => {
  // Helper function to load test fixture
  const loadFixture = (filename: string) => {
    const filePath = join(__dirname, fixturesPath, filename)
    const content = readFileSync(filePath, 'utf-8')
    return JSON.parse(content)
  }

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

  describe('Backward Compatibility', () => {
    it('should load baseline version 0.1.0 without warnings', () => {
      const fixture = loadFixture('version_0_1_0_baseline.esm')
      const { result, warnings } = captureWarnings(() => load(fixture))

      expect(result.esm).toBe('0.1.0')
      expect(result.metadata.name).toBe('Version_0_1_0_Baseline')
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })

    it('should load older minor version (0.0.1) successfully', () => {
      const fixture = loadFixture('version_0_0_1_backwards_compat.esm')
      const result = load(fixture)

      expect(result.esm).toBe('0.0.1')
      expect(result.metadata.name).toBe('Version_0_0_1_BackwardsCompat')
    })

    it('should load older patch version (0.1.5) successfully', () => {
      const fixture = loadFixture('version_0_1_5_patch_upgrade.esm')
      const result = load(fixture)

      expect(result.esm).toBe('0.1.5')
      expect(result.metadata.name).toBe('Version_0_1_5_PatchUpgrade')
    })

    it('should load older minor versions (0.2.0, 0.3.0) cleanly without warnings', () => {
      for (const [file, name] of [
        ['version_0_2_0_minor_upgrade.esm', 'Version_0_2_0_MinorUpgrade'],
        ['version_0_3_0_with_unknown_fields.esm', 'Version_0_3_0_WithUnknownFields'],
      ] as const) {
        const fixture = loadFixture(file)
        const { result, warnings } = captureWarnings(() => load(fixture))

        expect(result.metadata.name).toBe(name)
        expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
      }
    })
  })

  describe('Forward Compatibility', () => {
    it('should warn when loading a newer minor version (0.10.0)', () => {
      const fixture = loadFixture('version_0_10_0_double_digit.esm')
      const { result, warnings } = captureWarnings(() => load(fixture))

      expect(result.esm).toBe('0.10.0')
      expect(
        warnings.some((w) =>
          w.includes(`0.10.0 is newer than the current library version ${SCHEMA_VERSION}`),
        ),
      ).toBe(true)
    })

    it('does not weaken schema validation for newer minor versions', () => {
      const fixture = loadFixture('version_0_10_0_double_digit.esm')
      const withUnknownField = { ...fixture, definitely_not_a_schema_field: true }

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
    it('should reject major version 1.0.0', () => {
      const fixture = loadFixture('version_1_0_0_major_upgrade.esm')

      expect(() => load(fixture)).toThrow('Unsupported major version 1')
    })

    it('should reject major version 2.5.1', () => {
      const fixture = loadFixture('version_2_5_1_major_rejection.esm')

      expect(() => load(fixture)).toThrow('Unsupported major version 2')
    })
  })

  describe('Invalid Version Handling', () => {
    it('should reject invalid version string format', () => {
      const fixture = loadFixture('invalid_version_string.esm')

      expect(() => load(fixture)).toThrow(SchemaValidationError)
    })

    it('should reject missing version field', () => {
      const fixture = loadFixture('missing_version_field.esm')

      expect(() => load(fixture)).toThrow(SchemaValidationError)
    })
  })

  describe('Migration', () => {
    it('canMigrate reports the supported 0.0.5 → 0.1.0 step', () => {
      expect(canMigrate('0.0.5', '0.1.0')).toBe(true)
      expect(canMigrate('0.0.5', '0.2.0')).toBe(false)
      expect(canMigrate('0.1.0', '0.2.0')).toBe(false)
    })

    it('migrate bumps the version marker for a supported step', () => {
      const oldVersion = loadFixture('migration_test_from_0_0_5.esm')
      expect(oldVersion.esm).toBe('0.0.5')

      const migrated = migrate(oldVersion, '0.1.0')
      expect(migrated.esm).toBe('0.1.0')
      // Input is not mutated
      expect(oldVersion.esm).toBe('0.0.5')
    })

    it('migrate throws for unsupported version pairs', () => {
      const oldVersion = loadFixture('migration_test_from_0_0_5.esm')
      expect(() => migrate(oldVersion, '0.8.0')).toThrow(MigrationError)
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
