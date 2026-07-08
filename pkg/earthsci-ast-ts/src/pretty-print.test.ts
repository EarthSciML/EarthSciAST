/**
 * Tests for pretty-printing formatters using display test fixtures
 */

import { describe, it, expect } from 'vitest'
import { toUnicode, toLatex, toAscii, toMathML } from './pretty-print.js'
import { readFileSync } from 'fs'
import { join } from 'path'

// Load test fixtures
const chemicalSubscriptsFixtures = JSON.parse(
  readFileSync(join(process.cwd(), '../../tests/display/chemical_subscripts.json'), 'utf8'),
)

const comprehensiveOperatorsFixtures = JSON.parse(
  readFileSync(join(process.cwd(), '../../tests/display/comprehensive_operators.json'), 'utf8'),
)

describe('Chemical Subscripts', () => {
  chemicalSubscriptsFixtures.forEach((fixture: any) => {
    it(`should format ${fixture.input} correctly (${fixture.reasoning})`, () => {
      // Test string inputs (chemical species)
      expect(toUnicode(fixture.input)).toBe(fixture.unicode)
      expect(toLatex(fixture.input)).toBe(fixture.latex)

      // ASCII doesn't have special formatting for chemical subscripts
      expect(toAscii(fixture.input)).toBe(fixture.input)
    })
  })
})

describe('Expression Operators', () => {
  comprehensiveOperatorsFixtures.forEach((group: any) => {
    describe(group.name, () => {
      group.tests.forEach((test: any) => {
        it(`should format ${JSON.stringify(test.input)} correctly`, () => {
          const input = test.input

          if (test.unicode) {
            expect(toUnicode(input)).toBe(test.unicode)
          }

          if (test.latex) {
            expect(toLatex(input)).toBe(test.latex)
          }

          if (test.ascii) {
            expect(toAscii(input)).toBe(test.ascii)
          }
        })
      })
    })
  })
})

describe('Basic expressions', () => {
  it('should format numbers correctly', () => {
    expect(toUnicode(42)).toBe('42')
    expect(toLatex(42)).toBe('42')
    expect(toAscii(42)).toBe('42')

    // Scientific notation
    expect(toUnicode(1.8e-12)).toBe('1.8×10⁻¹²')
    expect(toLatex(1.8e-12)).toBe('1.8 \\times 10^{-12}')
    expect(toAscii(1.8e-12)).toBe('1.8e-12')
  })

  it('should format simple variables correctly', () => {
    expect(toUnicode('x')).toBe('x')
    expect(toLatex('x')).toBe('x')
    expect(toAscii('x')).toBe('x')
  })

  it('should format simple expressions correctly', () => {
    const expr = { op: '+', args: ['a', 'b'] }
    expect(toUnicode(expr)).toBe('a + b')
    expect(toLatex(expr)).toBe('a + b')
    expect(toAscii(expr)).toBe('a + b')
  })

  it('should format multiplication correctly', () => {
    const expr = { op: '*', args: ['a', 'b'] }
    expect(toUnicode(expr)).toBe('a·b')
    expect(toLatex(expr)).toBe('a \\cdot b')
    expect(toAscii(expr)).toBe('a * b')
  })

  it('should format division correctly', () => {
    const expr = { op: '/', args: ['a', 'b'] }
    expect(toUnicode(expr)).toBe('a/b')
    expect(toLatex(expr)).toBe('\\frac{a}{b}')
    expect(toAscii(expr)).toBe('a / b')
  })

  it('should format power correctly', () => {
    const expr = { op: '^', args: ['x', 3] }
    expect(toUnicode(expr)).toBe('x³')
    expect(toLatex(expr)).toBe('x^{3}')
    expect(toAscii(expr)).toBe('x^3')
  })

  it('should format derivatives correctly', () => {
    const expr = { op: 'D', args: ['x'], wrt: 't' }
    expect(toUnicode(expr)).toBe('∂x/∂t')
    expect(toLatex(expr)).toBe('\\frac{\\partial x}{\\partial t}')
    expect(toAscii(expr)).toBe('D(x)/Dt')
  })
})

describe('MathML formatting', () => {
  it('should format numbers correctly', () => {
    expect(toMathML(42)).toBe('<mn>42</mn>')
    expect(toMathML(3.14)).toBe('<mn>3.14</mn>')
  })

  it('should format simple variables correctly', () => {
    expect(toMathML('x')).toBe('<mi>x</mi>')
    expect(toMathML('theta')).toBe('<mi>theta</mi>')
  })

  it('should format chemical formulas correctly', () => {
    expect(toMathML('O3')).toContain('<mi>O</mi>')
    expect(toMathML('O3')).toContain('<msub>')
    expect(toMathML('O3')).toContain('<mn>3</mn>')
  })

  it('should format simple expressions correctly', () => {
    const expr = { op: '+', args: ['a', 'b'] }
    expect(toMathML(expr)).toBe('<mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow>')
  })

  it('should format multiplication correctly', () => {
    const expr = { op: '*', args: ['a', 'b'] }
    expect(toMathML(expr)).toBe('<mrow><mi>a</mi><mo>&cdot;</mo><mi>b</mi></mrow>')
  })

  it('should format division correctly', () => {
    const expr = { op: '/', args: ['a', 'b'] }
    expect(toMathML(expr)).toBe('<mfrac><mi>a</mi><mi>b</mi></mfrac>')
  })

  it('should format power correctly', () => {
    const expr = { op: '^', args: ['x', 3] }
    expect(toMathML(expr)).toBe('<msup><mi>x</mi><mn>3</mn></msup>')
  })

  it('should format square root correctly', () => {
    const expr = { op: 'sqrt', args: ['x'] }
    expect(toMathML(expr)).toBe('<msqrt><mi>x</mi></msqrt>')
  })

  it('should format complex expressions correctly', () => {
    const expr = {
      op: 'sqrt',
      args: [
        {
          op: '+',
          args: [
            { op: '^', args: ['x', 2] },
            { op: '^', args: ['y', 2] },
          ],
        },
      ],
    }
    const expected =
      '<msqrt><mrow><msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><msup><mi>y</mi><mn>2</mn></msup></mrow></msqrt>'
    expect(toMathML(expr)).toBe(expected)
  })

  it('should format derivatives correctly', () => {
    const expr = { op: 'D', args: ['x'], wrt: 't' }
    const result = toMathML(expr)
    expect(result).toContain('<mfrac>')
    expect(result).toContain('&part;')
    expect(result).toContain('<mi>x</mi>')
    expect(result).toContain('<mi>t</mi>')
  })

  it('should format equations correctly', () => {
    const equation = { lhs: 'y', rhs: { op: '+', args: ['m', { op: '*', args: ['x', 'b'] }] } }
    const result = toMathML(equation)
    expect(result).toContain('<math>')
    expect(result).toContain('<mo>=</mo>')
    expect(result).toContain('<mi>y</mi>')
  })
})
