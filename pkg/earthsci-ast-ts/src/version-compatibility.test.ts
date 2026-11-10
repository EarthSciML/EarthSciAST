import { describe, it, expect } from 'vitest'
import {
  loadString,
  loadDocument,
  migrate,
  canMigrate,
  MigrationError,
  LIBRARY_VERSION,
  SCHEMA_VERSION,
  SchemaValidationError,
} from './index.js'
import { readFixture } from './test-helpers.js'

/**
 * Version gating for esm 2.0.0.
 *
 * The library implements major version 2, so a DIFFERENT major is rejected
 * outright (`ParseError`) and a newer MINOR loads with a warning. 1.0.0 and
 * 2.0.0 are both breaks: a 0.x or 1.x document is on the rejected side of the
 * line. A 1.x document that uses none of what 2.0.0 removed is carried across by
 * `migrate()`, which relabels it; one that does is refused with `removed_op`.
 *
 * The suite reads the current major from `SCHEMA_VERSION` rather than spelling
 * it, so it states the same rules whichever major the embedded schema declares;
 * only the literal pin at the end names 2.0.0.
 *
 * Most cases apply the version under test to a base document IN MEMORY rather
 * than reading a per-version fixture: the gate is a function of the version
 * STRING alone, and one carrier document sweeps a whole line of versions
 * (`0.0.1` … `0.10.0`) without asking for a fixture per point. The shared
 * `tests/version_compatibility/` fixtures each declare the version they are
 * named for, so either spelling is sound; the ones read below are read for
 * content the sweep cannot synthesize.
 */
describe('Version Compatibility', () => {
  // A schema-valid 1.0.0 document, used as the carrier for every version under
  // test. Its own `esm` field is replaced per case.
  const baseDocument = () =>
    JSON.parse(readFixture('version_compatibility', 'version_1_0_0_baseline.esm'))

  /** The base document re-stamped with `version`. */
  const atVersion = (version: string) => ({ ...baseDocument(), esm: version })

  const MAJOR = Number(SCHEMA_VERSION.split('.')[0])

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
      const { result, warnings } = captureWarnings(() => loadString(atVersion(SCHEMA_VERSION)))

      expect(result.esm).toBe(SCHEMA_VERSION)
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })

    it('loads the first release of the current major without warnings', () => {
      const { result, warnings } = captureWarnings(() => loadString(atVersion(`${MAJOR}.0.0`)))

      expect(result.esm).toBe(`${MAJOR}.0.0`)
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })

    it('loads a newer patch on the same minor without warnings', () => {
      const { result, warnings } = captureWarnings(() => loadString(atVersion(`${MAJOR}.0.5`)))

      expect(result.esm).toBe(`${MAJOR}.0.5`)
      expect(warnings.some((w) => w.includes('newer than'))).toBe(false)
    })
  })

  describe('Forward Compatibility', () => {
    it('warns when loading a newer minor version', () => {
      const newer = `${MAJOR}.10.0`
      const { result, warnings } = captureWarnings(() => loadString(atVersion(newer)))

      expect(result.esm).toBe(newer)
      expect(
        warnings.some((w) =>
          w.includes(`${newer} is newer than the current library version ${SCHEMA_VERSION}`),
        ),
      ).toBe(true)
    })

    // esm-libraries-spec §8 asks a library to SKIP schema validation here so an
    // unknown block is ignored. It is not implemented — by this binding or any
    // other — and `tests/version_compatibility/README.md` carries the OPEN note
    // saying so, with `version_1_2_0_with_unknown_fields.esm` pinning it in the
    // shared corpus. What this asserts is the behavior the five bindings share.
    it('does not weaken schema validation for newer minor versions', () => {
      const withUnknownField = {
        ...atVersion(`${MAJOR}.10.0`),
        definitely_not_a_schema_field: true,
      }

      const { result } = captureWarnings(() =>
        (() => {
          try {
            loadString(withUnknownField)
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
        expect(() => loadString(atVersion(version))).toThrow('Unsupported major version 0')
      }
    })

    it.runIf(MAJOR === 2)('rejects the 1.x line outright', () => {
      for (const version of ['1.0.0', '1.0.5', '1.1.0', '1.3.0']) {
        expect(() => loadString(atVersion(version))).toThrow('Unsupported major version 1')
      }
    })

    it('rejects a newer major version', () => {
      const next = MAJOR + 1
      expect(() => loadString(atVersion(`${next}.5.1`))).toThrow(
        `Unsupported major version ${next}`,
      )
      expect(() => loadString(atVersion('12.34.56'))).toThrow('Unsupported major version 12')
    })
  })

  describe('Invalid Version Handling', () => {
    it('should reject invalid version string format', () => {
      const fixture = JSON.parse(readFixture('version_compatibility', 'invalid_version_string.esm'))

      expect(() => loadString(fixture)).toThrow(SchemaValidationError)
    })

    it('should reject missing version field', () => {
      const fixture = JSON.parse(readFixture('version_compatibility', 'missing_version_field.esm'))

      expect(() => loadString(fixture)).toThrow(SchemaValidationError)
    })
  })

  describe('Migration', () => {
    // A migration is a pure version-MARKER bump, sound along an additive line
    // and, for a document that uses none of the removed constructs, across the
    // 2.0.0 break. Nothing crosses the 1.0.0 boundary: the variable-model
    // collapse, the observed-expression relocation and the data_sources rename
    // all RESHAPE the document, so a 0.x source has no supported target at all
    // rather than a bump that would leave a file claiming 1.0.0 while still
    // carrying 0.x shapes.
    it('offers no migration path out of the 0.x line', () => {
      expect(canMigrate('0.0.5', '0.1.0')).toBe(false)
      expect(canMigrate('0.9.0', SCHEMA_VERSION)).toBe(false)
      expect(canMigrate('0.9.0', '1.0.0')).toBe(false)
    })

    it.runIf(MAJOR === 2)('canMigrate reports the 1.x relabel to the current version', () => {
      expect(canMigrate('1.0.0', SCHEMA_VERSION)).toBe(true)
      // Only the CURRENT version is offered as a target, never an arbitrary
      // intermediate one.
      expect(canMigrate('1.0.0', '1.0.1')).toBe(false)
    })

    it.runIf(MAJOR === 2)('migrate relabels a 1.x document, which then loads', () => {
      const source = atVersion('1.0.0')

      const migrated = migrate(source, SCHEMA_VERSION)
      expect(migrated.esm).toBe(SCHEMA_VERSION)
      // Input is not mutated
      expect(source.esm).toBe('1.0.0')
      expect(loadDocument(migrated).esm).toBe(SCHEMA_VERSION)
    })

    it('migrate throws for unsupported version pairs', () => {
      expect(() => migrate(atVersion('1.0.0'), '3.0.0')).toThrow(MigrationError)
      expect(() => migrate(atVersion('0.9.0'), SCHEMA_VERSION)).toThrow(MigrationError)
    })
  })

  describe('Library Version Information', () => {
    // The esm FORMAT version and the npm PACKAGE version are independent. The
    // format version is what appears in a document's `esm` field and in the
    // schema `$id`; the package version tracks releases of this binding and
    // moves on its own cadence. They were equal while both read 1.0.0, and a
    // test asserting lockstep encoded that coincidence as a rule -- which broke
    // the moment the bindings were released as 0.1.0 against the 1.0.0 format.
    it('exposes the schema version, derived from the embedded schema $id', () => {
      // Moved 1.3.0 -> 2.0.0 with the removal of `fn`, `function_tables` /
      // `table_lookup`, `skolem`, `rank`, `argmin`, `argmax` and the geometry
      // ops.
      // The literal is the point of the test: SCHEMA_VERSION is DERIVED from the
      // embedded schema `$id`, so this pins that the derivation still reads the
      // schema rather than a stale copy, and it is expected to be updated by
      // hand on each format bump.
      expect(SCHEMA_VERSION).toBe('2.0.0')
    })

    it('exposes the package version separately, under its own name', () => {
      // `VERSION` used to alias SCHEMA_VERSION here and CARGO_PKG_VERSION in
      // Rust -- one name, two meanings. It is gone; the two numbers now have
      // two names in every binding.
      expect(LIBRARY_VERSION).toMatch(/^\d+\.\d+\.\d+/)
    })
  })
})
