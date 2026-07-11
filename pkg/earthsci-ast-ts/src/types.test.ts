import { describe, it, expect } from 'vitest'
import type { EsmFile, Model, Expr, DiscreteEventTrigger } from './index.js'
import { VERSION } from './index.js'

describe('ESM Format Types', () => {
  it('should have correct package version', () => {
    expect(VERSION).toBe('0.8.0')
  })

  it('should handle Expr type correctly', () => {
    // Test that Expr can be number, string, or ExprNode
    const numberExpr: Expr = 42
    const stringExpr: Expr = 'temperature'
    const nodeExpr: Expr = {
      op: '+',
      args: [1, 'x'],
    }

    expect(typeof numberExpr).toBe('number')
    expect(typeof stringExpr).toBe('string')
    expect(typeof nodeExpr).toBe('object')
  })

  it('should handle DiscreteEventTrigger discriminated union', () => {
    // Test different trigger types
    const conditionTrigger: DiscreteEventTrigger = {
      type: 'condition',
      expression: 'temperature > 100',
    }

    const periodicTrigger: DiscreteEventTrigger = {
      type: 'periodic',
      interval: 3600,
    }

    const presetTrigger: DiscreteEventTrigger = {
      type: 'preset_times',
      times: [0, 3600, 7200],
    }

    expect(conditionTrigger.type).toBe('condition')
    expect(periodicTrigger.type).toBe('periodic')
    expect(presetTrigger.type).toBe('preset_times')
  })

  it('should handle basic Model structure', () => {
    const model: Partial<Model> = {
      variables: {},
      equations: [],
    }

    expect(typeof model.variables).toBe('object')
    expect(Array.isArray(model.equations)).toBe(true)
  })

  it('should handle EsmFile structure', () => {
    const esmFile: Partial<EsmFile> = {
      esm: '0.1.0',
      metadata: {
        name: 'Test Model',
        authors: ['Test Author'],
      },
    }

    expect(esmFile.esm).toBe('0.1.0')
    expect(esmFile.metadata?.name).toBe('Test Model')
  })
})
