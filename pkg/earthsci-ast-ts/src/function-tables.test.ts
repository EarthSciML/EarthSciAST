import { describe, it, expect } from 'vitest'
import { load } from './parse.js'
import { save } from './serialize.js'
import type { Model } from './types.js'

const FIXTURE = {
  esm: '0.4.0',
  metadata: { name: 'ft_smoke', authors: ['test'] },
  function_tables: {
    sigma_O3: {
      description: '1-D linear table',
      axes: [{ name: 'lambda_idx', values: [1, 2, 3, 4] }],
      interpolation: 'linear',
      out_of_bounds: 'clamp',
      data: [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18],
    },
    F_actinic: {
      axes: [
        { name: 'P', units: 'Pa', values: [10, 100, 1000] },
        { name: 'cos_sza', values: [0.1, 0.5, 1.0] },
      ],
      interpolation: 'bilinear',
      outputs: ['NO2', 'O3'],
      data: [
        [
          [1.0, 1.5, 2.0],
          [1.1, 1.6, 2.1],
          [1.2, 1.7, 2.2],
        ],
        [
          [2.0, 2.5, 3.0],
          [2.1, 2.6, 3.1],
          [2.2, 2.7, 3.2],
        ],
      ],
    },
  },
  models: {
    M: {
      variables: {
        k_O3: { type: 'state', default: 0.0 },
        j_NO2: { type: 'state', default: 0.0 },
        P_atm: { type: 'parameter', default: 101325.0 },
        cos_sza: { type: 'parameter', default: 0.5 },
      },
      equations: [
        {
          lhs: { op: 'D', args: ['k_O3'], wrt: 't' },
          rhs: {
            op: 'table_lookup',
            table: 'sigma_O3',
            axes: { lambda_idx: 2 },
            args: [],
          },
        },
        {
          lhs: { op: 'D', args: ['j_NO2'], wrt: 't' },
          rhs: {
            op: 'table_lookup',
            table: 'F_actinic',
            axes: { P: 'P_atm', cos_sza: 'cos_sza' },
            output: 'NO2',
            args: [],
          },
        },
      ],
    },
  },
}

describe('function_tables block + table_lookup AST op (esm-spec §9.5)', () => {
  it('loads a top-level function_tables block', () => {
    const ef = load(FIXTURE)
    expect(ef.function_tables).toBeDefined()
    const fts = ef.function_tables as Record<string, unknown>
    expect(Object.keys(fts).sort()).toEqual(['F_actinic', 'sigma_O3'])
    const sig = fts.sigma_O3 as { axes: Array<{ name: string }>; interpolation: string }
    expect(sig.axes[0].name).toBe('lambda_idx')
    expect(sig.interpolation).toBe('linear')
    const fa = fts.F_actinic as { outputs: string[]; axes: Array<{ units?: string }> }
    expect(fa.outputs).toEqual(['NO2', 'O3'])
    expect(fa.axes[0].units).toBe('Pa')
  })

  it('preserves table_lookup AST nodes through load', () => {
    const ef = load(FIXTURE)
    const eqs = (ef.models!.M as Model).equations as unknown as Array<{
      rhs: Record<string, unknown>
    }>
    expect(eqs).toHaveLength(2)
    expect(eqs[0].rhs.op).toBe('table_lookup')
    expect(eqs[0].rhs.table).toBe('sigma_O3')
    const axes0 = eqs[0].rhs.axes as Record<string, unknown>
    expect(axes0).toBeDefined()
    expect(axes0.lambda_idx).toBe(2)
    expect(eqs[1].rhs.op).toBe('table_lookup')
    expect(eqs[1].rhs.output).toBe('NO2')
  })

  it('round-trips both blocks unchanged', () => {
    const ef = load(FIXTURE)
    const out = save(ef)
    const reloaded = JSON.parse(out)
    expect(Object.keys(reloaded.function_tables).sort()).toEqual(['F_actinic', 'sigma_O3'])
    const rhs0 = reloaded.models.M.equations[0].rhs
    expect(rhs0.op).toBe('table_lookup')
    expect(rhs0.table).toBe('sigma_O3')
    expect(rhs0.axes).toEqual({ lambda_idx: 2 })
    const rhs1 = reloaded.models.M.equations[1].rhs
    expect(rhs1.op).toBe('table_lookup')
    expect(rhs1.output).toBe('NO2')
    // Round-trip is a fixed point.
    const ef2 = load(reloaded)
    const out2 = save(ef2)
    expect(JSON.parse(out2)).toEqual(reloaded)
  })
})
