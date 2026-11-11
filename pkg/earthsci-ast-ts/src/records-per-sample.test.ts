/**
 * Record axes (esm-spec §8.5.1) against index sets a `{ref}` mount declares.
 * `loadPath`/`loadString` do not mount refs, so an index set only a mounted
 * component declares is not decidable as loaded; the record-shape rules judge
 * it once `resolveSubsystemRefsSync` has merged that component's `index_sets`.
 * With no unmounted ref left, an undeclared index set is not a record axis.
 */
import { describe, expect, it } from 'vitest'
import path from 'node:path'
import { loadString } from './parse.js'
import { flatten } from './flatten.js'
import { validate } from './validate.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import type { EsmFile } from './types.js'
import { REPO_ROOT } from './test-helpers.js'

const COMPONENTS = path.join(
  REPO_ROOT,
  'tests',
  'conformance',
  'records_per_sample',
  'fixtures',
  'components',
)
const POINTER = '/models/Met/variables/K/update'
const MISPLACED = `record_axis_misplaced ${POINTER}`

/**
 * `Met.K` is data-fed, written with the deprecated `records_per_sample` only
 * when `written` is given. `Box` mounts `component` by ref, whose `F_k` is
 * shaped by `rec` (a record axis) and `x`, declared only in that component.
 */
function doc(options: {
  component?: string
  ownShape?: string[]
  mapToBox: boolean
  written?: 1 | 2
}): string {
  return JSON.stringify({
    esm: '1.3.0',
    metadata: { name: 'RecordsPerSampleMountedIndexSet' },
    data_sources: {
      met_source: {
        kind: 'grid',
        source: { url_template: 'file:///data/met/met_{date:%Y%m%d}.nc' },
        temporal: {
          start: '2024-05-01T00:00:00Z',
          frequency: 'PT1H',
          file_period: 'P1D',
          records_per_file: 24,
        },
      },
    },
    models: {
      Met: {
        variables: {
          K: {
            type: 'parameter',
            units: '1/s',
            // No own shape: the record shape is the param_to_var target's
            // (esm-spec §8.5.1). An explicit `[]` would be a scalar buffer.
            ...(options.ownShape === undefined ? {} : { shape: options.ownShape }),
            default: 0.1,
            update: {
              kind: 'data',
              source: 'met_source',
              from: {
                file_variable: 'K',
                ...(options.written === undefined ? {} : { records_per_sample: options.written }),
              },
            },
          },
        },
        equations: [],
      },
      ...(options.component === undefined ? {} : { Box: { ref: `./${options.component}` } }),
    },
    coupling: options.mapToBox
      ? [{ type: 'variable_map', from: 'Met.K', to: 'Box.F_k', transform: 'param_to_var' }]
      : [],
  })
}

const CODES = new Set([
  'record_axis_invalid',
  'record_axis_misplaced',
  'record_axis_time_invariant_source',
  'records_per_sample_invalid',
])

function pointers(file: EsmFile): string[] {
  return validate(file)
    .structural_errors.filter((e) => CODES.has(e.code))
    .map((e) => `${e.code} ${e.path}`)
}

/** Validate as loaded, then mount refs and report validation and flatten. */
function stages(json: string): { loaded: string[]; mounted: string[]; flattenCode?: string } {
  const file = loadString(json, { basePath: COMPONENTS })
  const loaded = pointers(file)
  resolveSubsystemRefsSync(file, COMPONENTS)
  const mounted = pointers(file)
  try {
    flatten(file)
    return { loaded, mounted }
  } catch (err) {
    return { loaded, mounted, flattenCode: (err as { code?: string }).code }
  }
}

describe('record axes: index sets declared by a ref-mounted component', () => {
  it('a mounted param_to_var target shaped [rec, x] is valid as loaded and mounted', () => {
    const r = stages(doc({ component: 'transport_rec_first.esm', mapToBox: true }))
    expect(r).toEqual({ loaded: [], mounted: [] })
  })

  it('a mounted param_to_var target shaped [x, rec] is refused once mounted', () => {
    const r = stages(doc({ component: 'transport_rec_second.esm', mapToBox: true }))
    expect(r.loaded).toEqual([])
    expect(r.mounted).toEqual([MISPLACED])
    expect(r.flattenCode).toBe('record_axis_misplaced')
  })

  it('an own shape [rec] whose rec only the mount declares is valid as loaded and mounted', () => {
    const r = stages(
      doc({ component: 'transport_rec_first.esm', ownShape: ['rec'], mapToBox: false }),
    )
    expect(r).toEqual({ loaded: [], mounted: [] })
  })

  it('an own shape [x, rec] whose sets only the mount declares is refused once mounted', () => {
    const r = stages(
      doc({ component: 'transport_rec_first.esm', ownShape: ['x', 'rec'], mapToBox: false }),
    )
    expect(r.loaded).toEqual([])
    expect(r.mounted).toEqual([MISPLACED])
    expect(r.flattenCode).toBe('record_axis_misplaced')
  })

  it('a deprecated 2 agreeing with a mounted record axis is valid as loaded and mounted', () => {
    const r = stages(doc({ component: 'transport_rec_first.esm', mapToBox: true, written: 2 }))
    expect(r).toEqual({ loaded: [], mounted: [] })
  })

  it('with no unmounted ref, an undeclared first index set is no record axis', () => {
    // The deprecated 2 then disagrees with the one record the shape gives.
    const file = loadString(doc({ ownShape: ['rec'], mapToBox: false, written: 2 }))
    expect(pointers(file)).toEqual([`records_per_sample_invalid ${POINTER}`])
  })
})
