import { describe, it, expect } from 'vitest'
import { flatten } from './flatten.js'
import { expandCouplingImports, isCouplingLibraryDoc } from './coupling-imports.js'
import { errCode as errCodeShared } from './test-helpers.js'
import type { EsmFile } from './types.js'

// A coupling-library file: roles + role-scoped edges, no models/loaders.
const lib = {
  esm: '0.8.0',
  metadata: { name: 'RothermelFuelCoupling' },
  coupling_roles: {
    Fuel: { description: 'fuel-property source' },
    Spread: { description: 'Rothermel spread model' },
  },
  coupling: [
    { type: 'variable_map', from: 'Fuel.sigma', to: 'Spread.sigma', transform: 'param_to_var' },
    { type: 'variable_map', from: 'Fuel.w_0', to: 'Spread.w0', transform: 'param_to_var' },
  ],
}

// An assembly mounting the two components the library wires.
function assembly(coupling: unknown[]): EsmFile {
  return {
    esm: '0.8.0',
    metadata: { name: 'wildfire' },
    models: {
      FuelModelLookup: {
        variables: {
          sigma: { type: 'parameter', units: '1/m', default: 1 },
          w_0: { type: 'parameter', units: 'kg/m^2', default: 1 },
        },
        equations: [],
      },
      RothermelFireSpread: {
        variables: {
          sigma: { type: 'parameter', units: '1/m', default: 0 },
          w0: { type: 'parameter', units: 'kg/m^2', default: 0 },
        },
        equations: [],
      },
    },
    coupling,
  } as unknown as EsmFile
}

const loadRef = () => lib

// This file-corpus suite uses the legacy sentinel contract: 'NO_ERROR' on
// success and `err.code ?? 'NON_CODE_ERROR'` for any throw (never rethrows).
const errCode = (fn: () => unknown): string => errCodeShared(fn, { sentinel: true }) as string

describe('isCouplingLibraryDoc', () => {
  it('identifies a coupling-library file by top-level coupling_roles', () => {
    expect(isCouplingLibraryDoc(lib)).toBe(true)
    expect(isCouplingLibraryDoc({ esm: '0.8.0', models: {} })).toBe(false)
    expect(isCouplingLibraryDoc(null)).toBe(false)
  })
})

describe('expandCouplingImports', () => {
  it('expands an import into the library edges with roles substituted', () => {
    const file = assembly([
      { type: 'coupling_import', ref: 'lib.esm', bind: { Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' } },
    ])
    const expanded = expandCouplingImports(file, { loadRef })
    expect(expanded).toEqual([
      { type: 'variable_map', from: 'FuelModelLookup.sigma', to: 'RothermelFireSpread.sigma', transform: 'param_to_var' },
      { type: 'variable_map', from: 'FuelModelLookup.w_0', to: 'RothermelFireSpread.w0', transform: 'param_to_var' },
    ])
  })

  it('leaves a file without coupling_import entries untouched (no options needed)', () => {
    const file = assembly([
      { type: 'variable_map', from: 'FuelModelLookup.sigma', to: 'RothermelFireSpread.sigma', transform: 'param_to_var' },
    ])
    expect(expandCouplingImports(file)).toBe(file.coupling)
  })

  it('supports multiple instantiation with different binds', () => {
    const file = assembly([
      { type: 'coupling_import', ref: 'lib.esm', bind: { Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' } },
      { type: 'coupling_import', ref: 'lib.esm', bind: { Fuel: 'RothermelFireSpread', Spread: 'FuelModelLookup' } },
    ])
    const expanded = expandCouplingImports(file, { loadRef })
    expect(expanded).toHaveLength(4)
    expect(expanded?.[2]).toMatchObject({ from: 'RothermelFireSpread.sigma', to: 'FuelModelLookup.sigma' })
  })
})

describe('flatten equivalence (esm-spec §10.10.3)', () => {
  it('an import and the equivalent inline edges flatten identically', () => {
    const imported = flatten(
      assembly([{ type: 'coupling_import', ref: 'lib.esm', bind: { Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' } }]),
      { loadRef },
    )
    const inline = flatten(
      assembly([
        { type: 'variable_map', from: 'FuelModelLookup.sigma', to: 'RothermelFireSpread.sigma', transform: 'param_to_var' },
        { type: 'variable_map', from: 'FuelModelLookup.w_0', to: 'RothermelFireSpread.w0', transform: 'param_to_var' },
      ]),
    )
    expect(imported).toEqual(inline)
    expect(imported.variables).toEqual({
      'RothermelFireSpread.sigma': 'FuelModelLookup.sigma',
      'RothermelFireSpread.w0': 'FuelModelLookup.w_0',
    })
  })
})

describe('diagnostics (esm-spec §10.11)', () => {
  const importEntry = (bind: Record<string, string>, ref = 'lib.esm') => [{ type: 'coupling_import', ref, bind }]

  it('coupling_import_role_unbound when a declared role has no bind', () => {
    expect(errCode(() => expandCouplingImports(assembly(importEntry({ Fuel: 'FuelModelLookup' })), { loadRef }))).toBe(
      'coupling_import_role_unbound',
    )
  })

  it('coupling_import_unknown_role when a bind key is not a role', () => {
    expect(
      errCode(() =>
        expandCouplingImports(
          assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread', Ghost: 'FuelModelLookup' })),
          { loadRef },
        ),
      ),
    ).toBe('coupling_import_unknown_role')
  })

  it('coupling_import_bind_not_a_component when a bind value is not a component', () => {
    expect(
      errCode(() =>
        expandCouplingImports(assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'DoesNotExist' })), { loadRef }),
      ),
    ).toBe('coupling_import_bind_not_a_component')
  })

  it('coupling_import_not_library when the ref is not a coupling library', () => {
    expect(
      errCode(() =>
        expandCouplingImports(assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' })), {
          loadRef: () => ({ esm: '0.8.0', metadata: { name: 'x' }, models: {} }),
        }),
      ),
    ).toBe('coupling_import_not_library')
  })

  it('coupling_library_illegal_payload when the library declares models', () => {
    expect(
      errCode(() =>
        expandCouplingImports(assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' })), {
          loadRef: () => ({ ...lib, models: {} }),
        }),
      ),
    ).toBe('coupling_library_illegal_payload')
  })

  it('coupling_role_unused when a declared role is referenced by no edge', () => {
    expect(
      errCode(() =>
        expandCouplingImports(
          assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread', Extra: 'FuelModelLookup' })),
          { loadRef: () => ({ ...lib, coupling_roles: { ...lib.coupling_roles, Extra: {} } }) },
        ),
      ),
    ).toBe('coupling_role_unused')
  })

  it('coupling_edge_unknown_role when an edge references an undeclared role', () => {
    expect(
      errCode(() =>
        expandCouplingImports(assembly(importEntry({ Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' })), {
          loadRef: () => ({
            ...lib,
            coupling: [{ type: 'variable_map', from: 'Ghost.sigma', to: 'Spread.sigma', transform: 'param_to_var' }],
          }),
        }),
      ),
    ).toBe('coupling_edge_unknown_role')
  })
})

// Guards the read-only role-collection visitor (forEachEntryRef/forEachExprRef)
// against the mutating rewriter (rewriteEntryInPlace): both must agree on the
// §10.10.2 occurrence set across every edge type, so role collection (used for
// validation) and role substitution (used for expansion) stay in lockstep.
describe('role collection + rewrite parity across edge types (esm-spec §10.10.2)', () => {
  // A couple edge names roles in `systems` AND in its connector equations.
  const coupleLib = {
    esm: '0.8.0',
    metadata: { name: 'CoupleLib' },
    coupling_roles: { Fuel: {}, Spread: {} },
    coupling: [
      {
        type: 'couple',
        systems: ['Fuel', 'Spread'],
        connector: { equations: [{ from: 'Fuel.sigma', to: 'Spread.sigma' }] },
      },
    ],
  }

  it('collects and substitutes roles from a couple systems array + connector', () => {
    const file = assembly([
      { type: 'coupling_import', ref: 'c.esm', bind: { Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' } },
    ])
    const expanded = expandCouplingImports(file, { loadRef: () => coupleLib })
    expect(expanded?.[0]).toMatchObject({
      type: 'couple',
      systems: ['FuelModelLookup', 'RothermelFireSpread'],
      connector: { equations: [{ from: 'FuelModelLookup.sigma', to: 'RothermelFireSpread.sigma' }] },
    })
  })

  it('detects an undeclared role reached only via a couple systems entry', () => {
    const badCoupleLib = {
      ...coupleLib,
      coupling: [
        {
          type: 'couple',
          systems: ['Fuel', 'Ghost'],
          connector: { equations: [{ from: 'Fuel.sigma', to: 'Spread.sigma' }] },
        },
      ],
    }
    const file = assembly([
      { type: 'coupling_import', ref: 'c.esm', bind: { Fuel: 'FuelModelLookup', Spread: 'RothermelFireSpread' } },
    ])
    expect(errCode(() => expandCouplingImports(file, { loadRef: () => badCoupleLib }))).toBe(
      'coupling_edge_unknown_role',
    )
  })
})
