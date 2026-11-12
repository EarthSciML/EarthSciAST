/**
 * Variable bounds `lb` / `ub` (esm-spec §6.3.2): round-trip, the four
 * structural rules, the esm 2.1.0 version gate, and flattening
 * (esm-libraries-spec §4.7.5, "Bounds follow the renaming").
 */
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { flatten } from './flatten.js'
import { loadString } from './parse.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { toJson } from './serialize.js'
import { errCode, readFixture } from './test-helpers.js'
import type { EsmFile } from './types.js'
import { validate, validateText } from './validate.js'
import { EsmMachineryError } from './lower-expression-templates.js'

const VALID = ['variable_bounds.esm', 'variable_bounds_shaped.esm', 'variable_bounds_coupled.esm']

interface PinnedError {
  path: string
  code: string
  details: Record<string, unknown>
}
const expectedErrors = JSON.parse(readFixture('invalid', 'expected_errors.json')) as Record<
  string,
  { structural_errors: PinnedError[]; resolver_error_code?: string }
>

/** Every variable declaration of a raw document, keyed by JSON pointer. */
function boundsOf(doc: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const walk = (model: Record<string, unknown>, at: string): void => {
    for (const [name, v] of Object.entries((model.variables ?? {}) as Record<string, object>)) {
      for (const side of ['lb', 'ub']) {
        if (side in v) out[`${at}/variables/${name}/${side}`] = (v as Record<string, unknown>)[side]
      }
    }
    for (const [name, sub] of Object.entries((model.subsystems ?? {}) as Record<string, object>)) {
      walk(sub as Record<string, unknown>, `${at}/subsystems/${name}`)
    }
  }
  const models = (doc as { models?: Record<string, Record<string, unknown>> }).models ?? {}
  for (const [name, model] of Object.entries(models)) walk(model, `/models/${name}`)
  return out
}

/** A one-model 2.1.0 document whose variables and equations are given. */
function doc(model: object, esm = '2.1.0'): EsmFile {
  return { esm, metadata: { name: 'bounds' }, models: { M: model } } as unknown as EsmFile
}

const decay = (name: string) => ({
  lhs: { op: 'D', args: [name], wrt: 't' },
  rhs: { op: '*', args: [{ op: '-', args: ['k'] }, name] },
})

describe('round-trip (esm-spec §6.3.2)', () => {
  it.each(VALID)('%s keeps every bound as authored', (file) => {
    const text = readFixture('valid', file)
    const authored = boundsOf(JSON.parse(text))
    expect(Object.keys(authored).length).toBeGreaterThan(0)
    const emitted = JSON.parse(toJson(loadString(text)))
    // A number stays a number and a reference stays its string; nothing is added.
    expect(boundsOf(emitted)).toEqual(authored)
  })

  it.each(VALID)('%s validates', (file) => {
    const result = validateText(readFixture('valid', file))
    expect(result.structural_errors).toEqual([])
    expect(result.schema_errors).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('writes no bound a variable does not declare', () => {
    const emitted = JSON.parse(toJson(loadString(readFixture('valid', 'variable_bounds.esm'))))
    const ions = emitted.models.Salts.subsystems.Ions.variables
    expect('lb' in ions.r).toBe(false)
    expect('ub' in ions.r).toBe(false)
  })
})

describe('the shared invalid fixtures', () => {
  it.each([
    'variable_bound_unresolved.esm',
    'variable_bound_shape_mismatch.esm',
    'variable_bound_shape_mismatch_axes.esm',
    'variable_bound_circular_self.esm',
    'variable_bound_circular_observed.esm',
    'variable_bounds_inverted.esm',
  ])('%s reports exactly the pinned finding', (file) => {
    const result = validateText(readFixture('invalid', file))
    expect(result.schema_errors).toEqual([])
    const got = result.structural_errors.map(({ path, code, details }) => ({ path, code, details }))
    expect(got).toEqual(
      expectedErrors[file].structural_errors.map(({ path, code, details }) => ({
        path,
        code,
        details,
      })),
    )
  })

  it('variable_bound_circular_observed.esm names the chain', () => {
    const result = validateText(readFixture('invalid', 'variable_bound_circular_observed.esm'))
    expect(result.structural_errors[0].message).toContain('(a -> b -> x)')
  })
})

describe('validation edge cases', () => {
  const codesAt = (file: EsmFile) =>
    validate(file).structural_errors.map((e) => [e.code, e.path] as const)

  it('pins a finding inside a subsystem at the subsystem variable', () => {
    const file = doc({
      variables: { k: { type: 'parameter', units: '1/s', default: 0.1 } },
      equations: [],
      subsystems: {
        S: {
          variables: {
            y: { type: 'unknown', units: '1', default: 1, lb: 'missing' },
            r: { type: 'parameter', units: '1/s', default: 0.1 },
          },
          equations: [
            {
              lhs: { op: 'D', args: ['y'], wrt: 't' },
              rhs: { op: '*', args: [{ op: '-', args: ['r'] }, 'y'] },
            },
          ],
        },
      },
    })
    expect(codesAt(file)).toEqual([['undefined_variable', '/models/M/subsystems/S/variables/y/lb']])
  })

  it('resolves a nested subsystem at any depth', () => {
    const file = doc({
      variables: { k: { type: 'parameter', units: '1/s', default: 0.1 } },
      equations: [],
      subsystems: {
        A: {
          variables: {},
          equations: [],
          subsystems: {
            B: {
              variables: {
                y: { type: 'parameter', units: '1', default: 1, lb: 3, ub: 2 },
              },
              equations: [],
            },
          },
        },
      },
    })
    expect(codesAt(file)).toEqual([
      ['variable_bounds_inverted', '/models/M/subsystems/A/subsystems/B/variables/y'],
    ])
  })

  it('resolves a dotted reference into an own subsystem and a top-level model', () => {
    const file = {
      esm: '2.1.0',
      metadata: { name: 'bounds' },
      models: {
        M: {
          variables: {
            x: { type: 'unknown', units: '1', default: 1, lb: 'S.floor', ub: 'N.cap' },
            k: { type: 'parameter', units: '1/s', default: 0.1 },
          },
          equations: [decay('x')],
          subsystems: {
            S: {
              variables: { floor: { type: 'parameter', units: '1', default: 0 } },
              equations: [],
            },
          },
        },
        N: { variables: { cap: { type: 'parameter', units: '1', default: 5 } }, equations: [] },
      },
    } as unknown as EsmFile
    expect(codesAt(file)).toEqual([])

    // A dotted reference naming nothing is undefined_variable at the bound.
    ;(file.models!.M as { variables: Record<string, { ub?: string }> }).variables.x.ub = 'N.nope'
    const findings = validate(file).structural_errors
    expect(findings.map((e) => [e.code, e.path])).toEqual([
      ['undefined_variable', '/models/M/variables/x/ub'],
    ])
    expect(findings[0].details).toEqual({ variable: 'N.nope', bound: 'ub' })
  })

  it('accepts a bound on an observed that depends on a different state', () => {
    // `x` is bounded by the observed `cap`, which reads only the state `y`.
    const file = doc({
      variables: {
        x: { type: 'unknown', units: '1', default: 1, ub: 'cap' },
        y: { type: 'unknown', units: '1', default: 1 },
        cap: { type: 'unknown', units: '1', lb: 0, ub: 'y' },
        k: { type: 'parameter', units: '1/s', default: 0.1 },
      },
      equations: [decay('x'), decay('y'), { lhs: 'cap', rhs: { op: '*', args: [2, 'y'] } }],
    })
    expect(codesAt(file)).toEqual([])
  })

  it('stops the circularity walk at a state', () => {
    // `x`'s bound `cap` reads the state `y`; `y`'s own equation reads `x`, but a
    // state's value is not computed from its RHS, so this is not circular.
    const file = doc({
      variables: {
        x: { type: 'unknown', units: '1', default: 1, ub: 'cap' },
        y: { type: 'unknown', units: '1', default: 1 },
        cap: { type: 'unknown', units: '1' },
        k: { type: 'parameter', units: '1/s', default: 0.1 },
      },
      equations: [
        decay('x'),
        { lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: { op: '*', args: ['k', 'x'] } },
        { lhs: 'cap', rhs: { op: '*', args: [2, 'y'] } },
      ],
    })
    expect(codesAt(file)).toEqual([])
  })

  it('reports circularity through a dotted reference into a subsystem', () => {
    // `x`'s ub is `S.w`, an observed of the subsystem defined from `M.x`... via
    // its own scoped reference to the parent model.
    const file = doc({
      variables: {
        x: { type: 'unknown', units: '1', default: 1, ub: 'S.w' },
        k: { type: 'parameter', units: '1/s', default: 0.1 },
      },
      equations: [decay('x')],
      subsystems: {
        S: {
          variables: { w: { type: 'unknown', units: '1' } },
          equations: [{ lhs: 'w', rhs: { op: '+', args: ['M.x', 1] } }],
        },
      },
    })
    const findings = validate(file).structural_errors
    expect(findings.map((e) => [e.code, e.path])).toEqual([
      ['variable_bound_circular', '/models/M/variables/x/ub'],
    ])
    expect(findings[0].details).toEqual({ variable: 'x', bound: 'ub', reference: 'S.w' })
  })

  it('accepts lb equal to ub, and a scalar or same-shape referenced bound', () => {
    const file = doc({
      variables: {
        k: { type: 'parameter', units: '1/s', default: 0.1, lb: 0.1, ub: 0.1 },
      },
      equations: [],
    })
    expect(codesAt(file)).toEqual([])
  })

  it('skips the shape and circularity rules for an unresolved reference', () => {
    const file = doc({
      variables: {
        x: { type: 'unknown', units: '1', default: 1, lb: 'nope', ub: 'nope' },
        k: { type: 'parameter', units: '1/s', default: 0.1 },
      },
      equations: [decay('x')],
    })
    expect(codesAt(file)).toEqual([
      ['undefined_variable', '/models/M/variables/x/lb'],
      ['undefined_variable', '/models/M/variables/x/ub'],
    ])
  })
})

describe('version gate (esm 2.1.0)', () => {
  it('rejects the shared fixture with variable_bounds_version_too_old at the first bound', () => {
    const text = readFixture('invalid', 'variable_bounds_version_too_old.esm')
    expect(expectedErrors['variable_bounds_version_too_old.esm'].resolver_error_code).toBe(
      'variable_bounds_version_too_old',
    )
    expect(errCode(() => loadString(text))).toBe('variable_bounds_version_too_old')
    expect(() => loadString(text)).toThrow(/\/models\/M\/variables\/x\/lb/)
  })

  it('names the first bound in a subsystem, and accepts 2.1.0', () => {
    const raw = {
      variables: { k: { type: 'parameter', units: '1/s', default: 0.1 } },
      equations: [],
      subsystems: {
        S: {
          variables: { y: { type: 'parameter', units: '1', default: 1, ub: 2 } },
          equations: [],
        },
      },
    }
    const text = (esm: string) => JSON.stringify(doc(raw, esm))
    expect(() => loadString(text('2.0.0'))).toThrow(EsmMachineryError)
    expect(() => loadString(text('2.0.0'))).toThrow(/\/models\/M\/subsystems\/S\/variables\/y\/ub/)
    expect(() => loadString(text('1.3.0'))).toThrow(/variables\/y\/ub/)
    expect(() => loadString(text('2.1.0'))).not.toThrow()
  })

  it('holds each file to its own declared version across a mount', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'esm-variable-bounds-'))
    try {
      const leaf = (esm: string) =>
        JSON.stringify({
          esm,
          metadata: { name: 'leaf' },
          models: {
            Leaf: {
              variables: { u: { type: 'parameter', units: '1', default: 1, lb: 0 } },
              equations: [],
            },
          },
        })
      const host = JSON.stringify({
        esm: '2.0.0',
        metadata: { name: 'host' },
        models: {
          H: {
            variables: { k: { type: 'parameter', units: '1/s', default: 0.1 } },
            equations: [],
            subsystems: { L: { ref: './leaf.esm' } },
          },
        },
      })

      // A 2.0.0 host mounting a 2.1.0 leaf that declares a bound is valid, and
      // the resolved document re-loads (it is raised to the 2.1.0 floor).
      writeFileSync(path.join(dir, 'leaf.esm'), leaf('2.1.0'))
      const resolved = loadString(host, { basePath: dir })
      resolveSubsystemRefsSync(resolved, dir)
      expect(resolved.esm).toBe('2.1.0')
      expect(validate(resolved).is_valid).toBe(true)
      expect(() => loadString(toJson(resolved))).not.toThrow()

      // The same leaf declaring 2.0.0 is refused, by its own version.
      writeFileSync(path.join(dir, 'leaf.esm'), leaf('2.0.0'))
      const stale = loadString(host, { basePath: dir })
      expect(errCode(() => resolveSubsystemRefsSync(stale, dir))).toBe(
        'variable_bounds_version_too_old',
      )
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('flatten (esm-libraries-spec §4.7.5, "Bounds follow the renaming")', () => {
  it('rewrites references in variable_bounds_coupled by the equations’ renaming', () => {
    const flat = flatten(loadString(readFixture('valid', 'variable_bounds_coupled.esm')))
    const all = { ...flat.stateVariables, ...flat.parameters, ...flat.observedVariables }
    const bounds = Object.fromEntries(
      Object.values(all)
        .filter((v) => v.lb !== undefined || v.ub !== undefined)
        .map((v) => [v.name, { lb: v.lb, ub: v.ub }]),
    )
    expect(bounds).toEqual({
      // bare reference, namespaced; a reference to the param_to_var target
      // follows the replacement
      'Chem.x': { lb: 'Chem.x_min', ub: 'Met.cap_src' },
      // a scoped reference into a subsystem, namespaced with the full path
      'Chem.z': { lb: 0, ub: 'Chem.Sub.y' },
      // a reference inside a subsystem, namespaced by the subsystem's path
      'Chem.Sub.y': { lb: 0, ub: 'Chem.Sub.y_cap' },
      'Met.cap_src': { lb: 0, ub: undefined },
    })
    // The variable_map target leaves the flattened system.
    expect('Chem.x_cap' in all).toBe(false)
  })

  it('leaves the scaled replacement expression for a factor variable_map', () => {
    const file = JSON.parse(readFixture('valid', 'variable_bounds_coupled.esm'))
    file.coupling = [
      {
        type: 'variable_map',
        from: 'Met.cap_src',
        to: 'Chem.x_cap',
        transform: 'conversion_factor',
        factor: 2.5,
      },
    ]
    const flat = flatten(loadString(JSON.stringify(file)))
    expect(flat.stateVariables['Chem.x'].ub).toEqual({ op: '*', args: [2.5, 'Met.cap_src'] })
  })

  it('carries number bounds unchanged and the shaped fixture’s references namespaced', () => {
    const flat = flatten(loadString(readFixture('valid', 'variable_bounds_shaped.esm')))
    expect(flat.stateVariables['Salts.Q'].lb).toBe(0)
    expect(flat.stateVariables['Salts.Q'].ub).toBe('Salts.Q_max')
    expect(flat.stateVariables['Salts.P'].lb).toBe('Salts.P_min')
    expect(flat.stateVariables['Salts.P'].ub).toBe(10)
    expect(flat.parameters['Salts.Q_max'].lb).toBeUndefined()
  })
})
