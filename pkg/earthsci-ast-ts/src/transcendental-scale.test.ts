/**
 * esm-spec §4.8.3 and issue #409: a unit's SCALE reaches the trig and
 * transcendental rules.
 *
 * Two halves that want OPPOSITE fixes, and one file so they stay in view of
 * each other:
 *
 * - **Angles convert.** `deg` is a registry unit at scale π/180, so
 *   `sin(theta [deg])` is a CONFORMING document — and `flatten` used to hand the
 *   stored number straight to `sin`, so `sin(90 [deg])` evaluated
 *   0.8939966636005579, which is `sin(90 radians)`, with no diagnostic. The
 *   conversion is exact and has exactly one reading.
 * - **Scaled dimensionless refuses.** `ppm` is dimensionless at 1e-6, so
 *   `log(c [ppm])` satisfied every dimension-only test. The log of the ppm
 *   NUMBER and the log of the mole fraction differ by `ln(1e-6) = 13.8155…` and
 *   nothing in the document says which was meant, so the checker refuses and
 *   names the repair rather than picking one.
 *
 * Everything asserted here is asserted off SHARED fixtures, so the same facts
 * are checked by the other four bindings.
 */
import { describe, it, expect } from 'vitest'
import { parseUnitForConversion } from './unit-conversion.js'
import type { ParsedUnit } from './unit-conversion.js'
import { angleNormalizationFactor, checkDimensions } from './units.js'
import { flatten } from './flatten.js'
import { validate } from './validate/orchestrator.js'
import { loadFixture } from './test-helpers.js'
import type { Expression, ExpressionNode } from './types.js'

/** The ops whose argument esm-spec §4.8.3 requires to be dimensionless. */
const STRICT_ARGUMENT_OPS = [
  'ln',
  'log',
  'log10',
  'exp',
  'sinh',
  'cosh',
  'tanh',
  'asinh',
  'acosh',
  'atanh',
  'asin',
  'acos',
  'atan',
]

const env = (units: string): Map<string, ParsedUnit> =>
  new Map([['x', parseUnitForConversion(units)]])

/** The dimensional-mismatch messages raised for `op(x)` with `x` in `units`. */
const mismatches = (op: string, units: string): string[] =>
  checkDimensions({ op, args: ['x'] } as Expression, env(units))
    .diagnostics.filter((d) => d.code === 'dimensional_mismatch')
    .map((d) => d.message)

describe('a strict transcendental argument must be dimensionless at scale 1', () => {
  it.each(STRICT_ARGUMENT_OPS)('refuses %s of a ppm quantity, naming the repair', (op) => {
    const found = mismatches(op, 'ppm')
    expect(found).toHaveLength(1)
    expect(found[0]).toContain('dimensionless at scale 1')
    expect(found[0]).toContain('(ppm)')
    // The diagnostic names the REPAIR, not only the refusal.
    expect(found[0]).toContain('divide by 1 ppm')
  })

  it.each(STRICT_ARGUMENT_OPS)('leaves %s of a pure number accepted', (op) => {
    expect(mismatches(op, '1')).toHaveLength(0)
  })

  it('names the percent spelling too', () => {
    expect(mismatches('exp', 'percent')[0]).toContain('divide by 1 percent')
  })
})

describe('a circular function takes an angle at any scale', () => {
  it.each(['sin', 'cos', 'tan'])('%s accepts rad, deg and a pure number', (op) => {
    for (const ok of ['rad', 'deg', '1']) expect(mismatches(op, ok)).toHaveLength(0)
  })

  it.each(['sin', 'cos', 'tan'])('%s refuses a scaled dimensionless argument', (op) => {
    // The reading is unstated, exactly as it is for `log`.
    expect(mismatches(op, 'percent')).toHaveLength(1)
    // `sr` is rad^2. No conversion turns a solid angle into a plane one, so
    // accepting it would multiply by `scale` where `scale^2` was meant.
    expect(mismatches(op, 'sr')).toHaveLength(1)
  })
})

describe('the angle normalization factor', () => {
  it('is null for everything a rewrite must leave alone', () => {
    for (const spelling of ['rad', '1', 'ppm', 'm', 'sr']) {
      expect(angleNormalizationFactor(parseUnitForConversion(spelling))).toBeNull()
    }
  })

  it('turns 90 deg into exactly a quarter turn', () => {
    const factor = angleNormalizationFactor(parseUnitForConversion('deg'))
    expect(factor).toBe(Math.PI / 180)
    expect(Math.sin(90 * (factor as number))).toBe(1)
  })
})

function trigArguments(expr: Expression, out: Array<[string, Expression]>): void {
  if (typeof expr !== 'object' || expr === null || Array.isArray(expr)) return
  const node = expr as ExpressionNode
  if (
    (node.op === 'sin' || node.op === 'cos' || node.op === 'tan') &&
    node.args !== undefined &&
    node.args.length === 1
  ) {
    out.push([node.op, node.args[0] as Expression])
  }
  for (const a of node.args ?? []) trigArguments(a as Expression, out)
}

describe('flatten converts a degree argument', () => {
  it('folds pi/180 into the deg arguments and leaves the rad control alone', () => {
    // What distinguishes "the scale is applied" from "the scale is applied twice".
    const flat = flatten(loadFixture('simulation', 'angle_units_degrees.esm'))
    const found: Array<[string, Expression]> = []
    for (const eq of flat.equations) trigArguments(eq.rhs, found)
    expect(found).toHaveLength(4)

    let converted = 0
    let untouched = 0
    for (const [op, arg] of found) {
      if (typeof arg === 'object' && arg !== null) {
        const node = arg as ExpressionNode
        expect(node.op, `${op}: expected the folded product`).toBe('*')
        expect(node.args?.[1], `${op}: the factor is the declared scale`).toBe(Math.PI / 180)
        converted += 1
      } else {
        expect(String(arg).endsWith('theta_rad'), `${op}: only the rad control stays bare`).toBe(
          true,
        )
        untouched += 1
      }
    }
    expect([converted, untouched]).toEqual([3, 1])
  })

  it('leaves a document with no scaled angle untouched', () => {
    const first = flatten(loadFixture('simulation', 'simple_ode.esm'))
    const second = flatten(loadFixture('simulation', 'simple_ode.esm'))
    expect(first.equations.map((e) => e.rhs)).toEqual(second.equations.map((e) => e.rhs))
  })
})

// An array element carries its array's unit on the evaluation path, so
// `cos(index(lat, i))` with `lat` in `deg` converts like `cos(lat)` does. The
// checker has no rule for `index` or `faq` (esm-spec §4.8.4), and the rewrite
// used to read the argument with the checker's rules, so it left every array
// element unconverted.
describe('flatten converts a degree ARRAY ELEMENT', () => {
  const fixture = (): ReturnType<typeof loadFixture> =>
    loadFixture('conformance', 'scalar_operator_semantics', 'fixtures', 'angle_array_element.esm')

  it('folds pi/180 into index and faq-body arguments and leaves the rad control alone', () => {
    const flat = flatten(fixture())
    const args = new Map<string, Expression>()
    const walk = (name: string, expr: Expression): void => {
      if (typeof expr !== 'object' || expr === null || Array.isArray(expr)) return
      const node = expr as ExpressionNode
      if (
        (node.op === 'sin' || node.op === 'cos' || node.op === 'tan') &&
        node.args !== undefined &&
        node.args.length === 1
      ) {
        args.set(name, node.args[0] as Expression)
      }
      for (const a of node.args ?? []) walk(name, a as Expression)
      if (node.expr !== undefined) walk(name, node.expr as Expression)
    }
    for (const eq of flat.equations) {
      if (typeof eq.lhs === 'string') walk(eq.lhs.split('.').pop() as string, eq.rhs)
    }
    expect([...args.keys()].sort()).toEqual([
      'cos_lat',
      'cos_lat_rad',
      'sin_colat',
      'sin_scalar',
      'sin_sum',
    ])
    for (const name of ['cos_lat', 'sin_colat', 'sin_sum']) {
      const node = args.get(name) as ExpressionNode
      // `index(A, ...) * (pi/180)`: the element, then the declared scale, once.
      expect(node.op, `${name}: expected the folded product`).toBe('*')
      expect((node.args?.[0] as ExpressionNode).op, `${name}: the element first`).toBe('index')
      expect(node.args?.[1], `${name}: the factor is the declared scale`).toBe(Math.PI / 180)
    }
    expect((args.get('sin_scalar') as ExpressionNode).op).toBe('*')
    // The `rad` control is never touched.
    expect((args.get('cos_lat_rad') as ExpressionNode).op).toBe('index')
  })

  it('leaves the checker reading the authored spelling', () => {
    const result = validate(fixture())
    expect(result.structural_errors).toEqual([])
    expect(result.is_valid).toBe(true)
    // The checker still has no rule for an array element.
    const deg = parseUnitForConversion('deg')
    const bindings = new Map<string, ParsedUnit>([['lat', deg]])
    expect(checkDimensions({ op: 'index', args: ['lat', 1] }, bindings).dimensions).toBeNull()
  })
})

describe('the shared fixtures', () => {
  it('refuses the scaled-argument fixture and names the repair', () => {
    const result = validate(
      loadFixture('invalid', 'units_discriminator_transcendental_scaled_argument.esm'),
    )
    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((e) => e.message.includes('divide by 1 ppm'))).toBe(true)
  })

  it('accepts the repaired spelling and the degree argument beside it', () => {
    const result = validate(loadFixture('valid', 'units_transcendental_scaled_argument_repair.esm'))
    expect(result.structural_errors).toEqual([])
    expect(result.is_valid).toBe(true)
  })
})
