/**
 * Tests for the TS scalar expression runner (AST → JS lowering)
 */

import { describe, it, expect } from 'vitest'
import { compileExpression, evaluateExpression } from './codegen.js'
import type { Expr } from './types.js'

describe('compileExpression / evaluateExpression — TS scalar runner', () => {
  // Migrated from expression.test.ts under esm-3r4: this is the
  // sanctioned TS in-process evaluator (AGENTS.md "Official per-binding
  // runners"). The runner walks canonical-form AST generically — no
  // per-rule-shape dispatch.
  const bindings = new Map<string, number>([
    ['x', 2],
    ['y', 3],
    ['pi', Math.PI],
  ])

  it('returns numbers as-is', () => {
    expect(evaluateExpression(42, bindings)).toBe(42)
  })

  it('resolves bound variables', () => {
    expect(evaluateExpression('x', bindings)).toBe(2)
    expect(evaluateExpression('y', bindings)).toBe(3)
  })

  it('throws for unbound variables', () => {
    expect(() => evaluateExpression('z', bindings)).toThrow('Unbound variable: z')
  })

  it('compileExpression returns a reusable closure', () => {
    const expr: Expr = { op: '+', args: ['x', 'y'] }
    const fn = compileExpression(expr)
    expect(fn(bindings)).toBe(5)
    const otherBindings = new Map<string, number>([['x', 10], ['y', 20]])
    expect(fn(otherBindings)).toBe(30)
  })

  describe('arithmetic operations', () => {
    it('evaluates addition', () => {
      const expr: Expr = { op: '+', args: ['x', 'y', 5] }
      expect(evaluateExpression(expr, bindings)).toBe(10)
    })

    it('evaluates subtraction', () => {
      const expr: Expr = { op: '-', args: [10, 'x'] }
      expect(evaluateExpression(expr, bindings)).toBe(8)
    })

    it('evaluates unary minus', () => {
      const expr: Expr = { op: '-', args: ['x'] }
      expect(evaluateExpression(expr, bindings)).toBe(-2)
    })

    it('evaluates multiplication', () => {
      const expr: Expr = { op: '*', args: ['x', 'y'] }
      expect(evaluateExpression(expr, bindings)).toBe(6)
    })

    it('evaluates division', () => {
      const expr: Expr = { op: '/', args: [6, 'x'] }
      expect(evaluateExpression(expr, bindings)).toBe(3)
    })

    it('evaluates exponentiation', () => {
      const expr: Expr = { op: '^', args: ['x', 'y'] }
      expect(evaluateExpression(expr, bindings)).toBe(8)
    })
  })

  describe('mathematical functions', () => {
    it('evaluates exp', () => {
      expect(evaluateExpression({ op: 'exp', args: [0] }, bindings)).toBe(1)
    })

    it('evaluates log', () => {
      expect(evaluateExpression({ op: 'log', args: [Math.E] }, bindings)).toBeCloseTo(1)
    })

    it('evaluates sqrt', () => {
      expect(evaluateExpression({ op: 'sqrt', args: [4] }, bindings)).toBe(2)
    })

    it('evaluates trig functions', () => {
      expect(evaluateExpression({ op: 'sin', args: [0] }, bindings)).toBe(0)
      expect(evaluateExpression({ op: 'cos', args: [0] }, bindings)).toBe(1)
    })

    it('evaluates n-ary min/max', () => {
      expect(evaluateExpression({ op: 'min', args: ['x', 'y', 1] }, bindings)).toBe(1)
      expect(evaluateExpression({ op: 'max', args: ['x', 'y', 1] }, bindings)).toBe(3)
    })

    it('rejects min/max with fewer than 2 args (esm-spec §4.2)', () => {
      // esm-2is — n-ary arity ≥ 2
      expect(() => evaluateExpression({ op: 'min', args: ['x'] }, bindings))
        .toThrow('min requires at least 2 arguments')
      expect(() => evaluateExpression({ op: 'max', args: ['x'] }, bindings))
        .toThrow('max requires at least 2 arguments')
    })
  })

  describe('comparison and logical operations', () => {
    it('evaluates comparisons', () => {
      expect(evaluateExpression({ op: '>', args: ['y', 'x'] }, bindings)).toBe(1)
      expect(evaluateExpression({ op: '<', args: ['y', 'x'] }, bindings)).toBe(0)
      expect(evaluateExpression({ op: '==', args: ['x', 2] }, bindings)).toBe(1)
    })

    it('evaluates logical operations', () => {
      expect(evaluateExpression({ op: 'and', args: [1, 1] }, bindings)).toBe(1)
      expect(evaluateExpression({ op: 'and', args: [1, 0] }, bindings)).toBe(0)
      expect(evaluateExpression({ op: 'or', args: [0, 1] }, bindings)).toBe(1)
      expect(evaluateExpression({ op: 'not', args: [0] }, bindings)).toBe(1)
    })

    it('evaluates ifelse', () => {
      expect(evaluateExpression({ op: 'ifelse', args: [1, 'x', 'y'] }, bindings)).toBe(2)
      expect(evaluateExpression({ op: 'ifelse', args: [0, 'x', 'y'] }, bindings)).toBe(3)
    })
  })

  describe('error handling', () => {
    it('throws for division by zero', () => {
      expect(() => evaluateExpression({ op: '/', args: [1, 0] }, bindings))
        .toThrow('Division by zero')
    })

    it('throws for invalid log argument', () => {
      expect(() => evaluateExpression({ op: 'log', args: [-1] }, bindings))
        .toThrow('log argument must be positive')
    })

    it('throws for invalid sqrt argument', () => {
      expect(() => evaluateExpression({ op: 'sqrt', args: [-1] }, bindings))
        .toThrow('sqrt argument must be non-negative')
    })

    it('throws for unsupported operator', () => {
      const expr: any = { op: 'unsupported', args: [1] }
      expect(() => evaluateExpression(expr, bindings))
        .toThrow('Unsupported operator: unsupported')
    })

    it('rejects unlowered enum nodes', () => {
      const expr: any = { op: 'enum', value: 'foo' }
      expect(() => evaluateExpression(expr, bindings))
        .toThrow(/enum op encountered/)
    })

    it('rejects array-valued const nodes in scalar position', () => {
      const expr: any = { op: 'const', value: [1, 2, 3] }
      expect(() => evaluateExpression(expr, bindings))
        .toThrow(/array value cannot be evaluated as a scalar/)
    })
  })
})