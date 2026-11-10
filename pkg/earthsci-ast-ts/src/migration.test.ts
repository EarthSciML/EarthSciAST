/**
 * Tests for the version-migration utilities.
 *
 * A migration changes only the `esm` marker. It is sound along an ADDITIVE line
 * — a run of releases whose changes were additive, so an older file already
 * loads under the newer schema; the current line is
 * `2.0.0 … <current schema version>` — and across the 2.0.0 break for a 1.x
 * document that uses none of the constructs 2.0.0 removed. A 1.x document that
 * does use one is refused with `removed_op`, naming the codemod.
 *
 * Nothing crosses the 1.0.0 boundary. esm 1.0.0 is a clean break: the five
 * declared variable types collapse to two, an observed variable's `expression`
 * becomes an equation, `data_loaders` becomes a non-component `data_sources`
 * registry, and parameter mutation moves off events onto the parameter. Each of
 * those RESHAPES the document, so a 0.x source has no supported target at all.
 *
 * The 1.x cases need a build that implements major 2; they are skipped while
 * the embedded schema still declares 1.x.
 */

import { describe, it, expect } from 'vitest'
import {
  migrate,
  canMigrate,
  supportedMigrationTargets,
  getSupportedMigrationTargets,
  MigrationError,
} from './migration.js'
import { SCHEMA_VERSION } from './parse.js'
import type { EsmFile } from './types.js'

const fileAt = (version: string): EsmFile =>
  ({ esm: version, metadata: { name: 'test' } }) as unknown as EsmFile

const IMPLEMENTS_V2 = SCHEMA_VERSION.startsWith('2.')

/** A 1.3.0 document whose one equation's right-hand side is `rhs`. */
const v1WithRhs = (rhs: unknown, extra: Record<string, unknown> = {}): EsmFile =>
  ({
    esm: '1.3.0',
    metadata: { name: 'v1' },
    models: {
      M: {
        variables: { x: { type: 'unknown', units: '1' } },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs }],
        ...extra,
      },
    },
  }) as unknown as EsmFile

describe('migration', () => {
  describe('getSupportedMigrationTargets', () => {
    it('offers no target for any 0.x source, the clean break being uncrossable', () => {
      for (const source of ['0.0.5', '0.1.0', '0.3.0', '0.8.0', '0.9.0']) {
        expect(getSupportedMigrationTargets(source)).toEqual([])
      }
    })

    it('offers a no-op bump to the current schema for additive-line sources', () => {
      expect(getSupportedMigrationTargets(SCHEMA_VERSION)).toEqual([SCHEMA_VERSION])
    })

    it.runIf(IMPLEMENTS_V2)('offers the current schema to every 1.x source', () => {
      for (const source of ['1.0.0', '1.1.0', '1.2.0', '1.3.0']) {
        expect(getSupportedMigrationTargets(source)).toEqual([SCHEMA_VERSION])
      }
    })

    it('returns [] for a version newer than the current schema', () => {
      // Same major, but beyond the current additive ceiling; and a 1.x minor
      // newer than the last 1.x release.
      expect(getSupportedMigrationTargets('2.99.0')).toEqual([])
      expect(getSupportedMigrationTargets('1.99.0')).toEqual([])
    })

    it('returns [] for a higher major version', () => {
      expect(getSupportedMigrationTargets('3.0.0')).toEqual([])
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

    it.runIf(IMPLEMENTS_V2)('accepts a 1.x source bumped to the current schema', () => {
      expect(canMigrate('1.0.0', SCHEMA_VERSION)).toBe(true)
      expect(canMigrate('1.3.0', SCHEMA_VERSION)).toBe(true)
    })

    it('accepts a current-version file migrated to itself (identity no-op)', () => {
      expect(canMigrate(SCHEMA_VERSION, SCHEMA_VERSION)).toBe(true)
    })

    it('rejects an additive-line source targeting an intermediate (non-current) version', () => {
      // Only the current schema is a valid target; per-minor jumps are not offered.
      expect(canMigrate('1.0.0', '1.0.1')).toBe(false)
      expect(canMigrate('1.0.0', '3.0.0')).toBe(false)
    })
  })

  describe('migrate', () => {
    it('refuses a 0.x source rather than bumping its marker', () => {
      const source = fileAt('0.9.0')
      expect(() => migrate(source, SCHEMA_VERSION)).toThrow(MigrationError)
      // The input is left alone.
      expect(source.esm).toBe('0.9.0')
    })

    it.runIf(IMPLEMENTS_V2)('relabels a 1.x file that uses no removed construct', () => {
      const source = fileAt('1.0.0')
      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.esm).toBe(SCHEMA_VERSION)
      expect(migrated).not.toBe(source)
      expect(source.esm).toBe('1.0.0')
    })

    it.runIf(IMPLEMENTS_V2)('relabels a 1.x file that calls an esm:std template', () => {
      const source = v1WithRhs({
        op: 'apply_expression_template',
        args: [],
        name: 'argmin',
        bindings: { f: 'x', n: 3 },
      })
      expect(migrate(source, SCHEMA_VERSION).esm).toBe(SCHEMA_VERSION)
    })

    const removed: [string, unknown][] = [
      ['fn', { op: 'fn', name: 'datetime.year', args: ['t'] }],
      ['table_lookup', { op: 'table_lookup', args: [], table: 'T', axes: { a: 'x' } }],
      ['skolem', { op: 'skolem', args: ['x'] }],
      ['rank', { op: 'rank', args: ['x'] }],
      ['intersect_polygon', { op: 'intersect_polygon', args: ['x', 'x'], manifold: 'planar' }],
      [
        'polygon_intersection_area',
        { op: 'polygon_intersection_area', args: ['x', 'x'], manifold: 'planar' },
      ],
      ['argmin', { op: 'argmin', args: ['x'], arg: 'i', expr: 'x', ranges: {} }],
      ['argmax', { op: 'argmax', args: ['x'], arg: 'i', expr: 'x', ranges: {} }],
      ['aggregate', { op: 'aggregate', args: [], output_idx: [], expr: 'x', ranges: {} }],
    ]
    for (const [op, node] of removed) {
      it.runIf(IMPLEMENTS_V2)(`refuses a 1.x file using \`${op}\` with removed_op`, () => {
        const source = v1WithRhs({ op: '+', args: [1, node] })
        let err: unknown
        try {
          migrate(source, SCHEMA_VERSION)
        } catch (e) {
          err = e
        }
        expect(err).toBeInstanceOf(MigrationError)
        expect((err as MigrationError).code).toBe('removed_op')
        expect((err as MigrationError).message).toContain(`"op": "${op}"`)
        expect((err as MigrationError).message).toContain('/models/M/equations/0/rhs/args/1')
        expect((err as MigrationError).message).toContain('python -m earthsci_ast.migrate')
        expect(source.esm).toBe('1.3.0')
      })
    }

    for (const where of ['top-level', 'component-level']) {
      it.runIf(IMPLEMENTS_V2)(`refuses a 1.x file with a ${where} function_tables block`, () => {
        const block = { T: { axes: [{ name: 'a', values: [0, 1] }], data: [0, 1] } }
        const source =
          where === 'top-level'
            ? ({ ...v1WithRhs('x'), function_tables: block } as unknown as EsmFile)
            : v1WithRhs('x', { function_tables: block })
        expect(() => migrate(source, SCHEMA_VERSION)).toThrow(
          where === 'top-level'
            ? /removed_op at \/function_tables: the `function_tables` block/
            : /removed_op at \/models\/M\/function_tables: the `function_tables` block/,
        )
      })
    }

    it('accepts migrating a current-version file to the current schema (no-op)', () => {
      const source = fileAt(SCHEMA_VERSION)
      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.esm).toBe(SCHEMA_VERSION)
      // A no-op marker bump still returns a fresh object.
      expect(migrated).not.toBe(source)
    })

    it('preserves all other fields untouched (marker-only bump)', () => {
      const source = {
        esm: SCHEMA_VERSION,
        metadata: { name: 'keep-me' },
        models: { M: { variables: {}, equations: [] } },
      } as unknown as EsmFile

      const migrated = migrate(source, SCHEMA_VERSION)

      expect(migrated.metadata).toEqual(source.metadata)
      expect(migrated.models).toEqual(source.models)
    })

    it('throws MigrationError for an unsupported version pair', () => {
      expect(() => migrate(fileAt('1.0.0'), '3.0.0')).toThrow(MigrationError)
      expect(() => migrate(fileAt('0.1.0'), SCHEMA_VERSION)).toThrow(MigrationError)
    })

    it("throws when the source file has no 'esm' field", () => {
      const noVersion = { metadata: { name: 'x' } } as unknown as EsmFile
      expect(() => migrate(noVersion, SCHEMA_VERSION)).toThrow(MigrationError)
    })
  })
})

describe('supportedMigrationTargets (canonical spelling)', () => {
  it('is the same function as the deprecated getSupportedMigrationTargets', () => {
    expect(supportedMigrationTargets).toBe(getSupportedMigrationTargets)
  })

  it('agrees with the other bindings: additive line -> [SCHEMA_VERSION], else []', () => {
    expect(supportedMigrationTargets(SCHEMA_VERSION)).toEqual([SCHEMA_VERSION])
    expect(supportedMigrationTargets('0.9.0')).toEqual([])
  })
})
