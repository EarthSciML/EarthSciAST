/**
 * Sanity tests for the centralized diagnostic-code registry (errors.ts) and the
 * neutral `EsmDiagnosticError` base. These do NOT re-pin every value against its
 * source literal (the shared conformance fixtures already do that); they only
 * guard the registry's shape and the base class contract.
 */

import { describe, it, expect } from 'vitest'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

describe('ERROR_CODES', () => {
  it('maps every key to a non-empty string', () => {
    for (const [key, value] of Object.entries(ERROR_CODES)) {
      expect(typeof value, key).toBe('string')
      expect(value.length, key).toBeGreaterThan(0)
    }
  })

  it('uses snake_case-ish diagnostic strings (no whitespace)', () => {
    for (const [key, value] of Object.entries(ERROR_CODES)) {
      expect(value, key).toMatch(/^[a-z][a-z_]*$/)
    }
  })

  it('has no duplicate values', () => {
    const values = Object.values(ERROR_CODES)
    expect(new Set(values).size).toBe(values.length)
  })

  it('exposes a few contract codes verbatim', () => {
    expect(ERROR_CODES.UNDEFINED_VARIABLE).toBe('undefined_variable')
    expect(ERROR_CODES.TEMPLATE_IMPORT_CYCLE).toBe('template_import_cycle')
    expect(ERROR_CODES.COUPLING_IMPORT_UNRESOLVED).toBe('coupling_import_unresolved')
    expect(ERROR_CODES.UNKNOWN_CLOSED_FUNCTION).toBe('unknown_closed_function')
    expect(ERROR_CODES.ENUM_MEMBER_NOT_FOUND).toBe('enum_member_not_found')
  })
})

describe('EsmDiagnosticError', () => {
  it('is an Error carrying a code and message', () => {
    const err = new EsmDiagnosticError('some_code', 'boom')
    expect(err).toBeInstanceOf(Error)
    expect(err.code).toBe('some_code')
    expect(err.message).toBe('boom')
    expect(err.name).toBe('EsmDiagnosticError')
    expect(err.details).toBeUndefined()
  })

  it('carries optional structured details', () => {
    const err = new EsmDiagnosticError(ERROR_CODES.UNIT_ERROR, 'bad units', { expected: 'kg' })
    expect(err.code).toBe('unit_error')
    expect(err.details).toEqual({ expected: 'kg' })
  })
})
