/**
 * `records_per_sample_invalid` rule 3 (esm-spec §8.5.1) against index sets a
 * `{ref}` mount declares. `loadPath`/`loadString` do not mount refs, so an
 * index set only a mounted component declares is not decidable as loaded; the
 * check judges it once `resolveSubsystemRefsSync` has merged that component's
 * `index_sets`. With no unmounted ref left, an undeclared index set still fails.
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

/**
 * `Met.K` reads two records per sample. `Box` mounts `component` by ref, whose
 * `F_k` is shaped by `rec` and `x`, declared only in that component.
 */
function doc(options: { component?: string; ownShape?: string[]; mapToBox: boolean }): string {
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
            shape: options.ownShape ?? [],
            default: 0.1,
            update: {
              kind: 'data',
              source: 'met_source',
              from: { file_variable: 'K', records_per_sample: 2 },
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

function pointers(file: EsmFile): string[] {
  return validate(file)
    .structural_errors.filter((e) => e.code === 'records_per_sample_invalid')
    .map((e) => e.path)
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

describe('records_per_sample: index sets declared by a ref-mounted component', () => {
  it('a mounted param_to_var target shaped [rec, x] is valid as loaded and mounted', () => {
    const r = stages(doc({ component: 'transport_rec_first.esm', mapToBox: true }))
    expect(r).toEqual({ loaded: [], mounted: [] })
  })

  it('a mounted param_to_var target shaped [x, rec] is refused once mounted', () => {
    const r = stages(doc({ component: 'transport_rec_second.esm', mapToBox: true }))
    expect(r.loaded).toEqual([])
    expect(r.mounted).toEqual([POINTER])
    expect(r.flattenCode).toBe('records_per_sample_invalid')
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
    expect(r.mounted).toEqual([POINTER])
    expect(r.flattenCode).toBe('records_per_sample_invalid')
  })

  it('with no unmounted ref, an undeclared first index set still fails as loaded', () => {
    const file = loadString(doc({ ownShape: ['rec'], mapToBox: false }))
    expect(pointers(file)).toEqual([POINTER])
  })
})
