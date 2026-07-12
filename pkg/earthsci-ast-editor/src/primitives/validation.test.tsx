/**
 * Tests for the validation primitive
 */

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { createSignal, createRoot } from 'solid-js'
import {
  createValidationSignals,
  createValidationContext,
  createDebouncedValidation,
} from './validation'
import type { EsmFile } from '@earthsciml/ast'

// Mock the @earthsciml/ast validate function
vi.mock('@earthsciml/ast', () => ({
  validate: vi.fn(),
  type: {}, // Mock type exports
}))

import { validate } from '@earthsciml/ast'
const mockValidate = vi.mocked(validate)

describe('validation primitive', () => {
  const validEsmFile: EsmFile = {
    esm: '0.8.0',
    metadata: { name: 'Validation test file' },
    models: {
      TestModel: {
        variables: {
          x: {
            type: 'state',
            units: 'm',
            default: 0.0,
          },
        },
        equations: [
          {
            lhs: { op: 'D', args: ['x', 't'] },
            rhs: 1.0,
          },
        ],
      },
    },
  }

  const invalidEsmFile: EsmFile = {
    esm: '0.8.0',
    metadata: { name: 'Invalid validation test file' },
    models: {},
  }

  beforeEach(() => {
    vi.resetAllMocks()
  })

  describe('createValidationSignals', () => {
    it('should create validation signals with default configuration', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockReturnValue({
          is_valid: true,
          schema_errors: [],
          structural_errors: [],
          unit_warnings: [],
        })

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(true)
        expect(signals.errorCount()).toBe(0)
        expect(signals.warningCount()).toBe(0)
        expect(signals.allErrors()).toEqual([])
        expect(signals.isValidating()).toBe(false)
      })
    })

    it('should handle schema errors correctly', () => {
      createRoot(() => {
        const [file] = createSignal(invalidEsmFile)

        mockValidate.mockReturnValue({
          is_valid: false,
          schema_errors: [
            {
              path: '/models',
              message: 'models cannot be empty',
              code: 'required',
              details: {},
            },
          ],
          structural_errors: [],
          unit_warnings: [],
        })

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(false)
        expect(signals.errorCount()).toBe(1)
        expect(signals.warningCount()).toBe(0)
        expect(signals.schemaErrors()).toHaveLength(1)
        expect(signals.schemaErrors()[0].type).toBe('schema')
        expect(signals.schemaErrors()[0].severity).toBe('error')
      })
    })

    it('should handle structural errors correctly', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockReturnValue({
          is_valid: false,
          schema_errors: [],
          structural_errors: [
            {
              path: '/models/TestModel',
              message: 'equation count mismatch',
              code: 'equation_count_mismatch',
              details: { expected: 2, actual: 1 },
            },
          ],
          unit_warnings: [],
        })

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(false)
        expect(signals.errorCount()).toBe(1)
        expect(signals.warningCount()).toBe(0)
        expect(signals.structuralErrors()).toHaveLength(1)
        expect(signals.structuralErrors()[0].type).toBe('structural')
        expect(signals.structuralErrors()[0].severity).toBe('error')
      })
    })

    it('should handle unit warnings correctly', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockReturnValue({
          is_valid: true,
          schema_errors: [],
          structural_errors: [],
          unit_warnings: [
            {
              location: '/models/TestModel/variables/x',
              message: 'inconsistent units',
              code: 'analysis' as const,
              equation: 'D(x, t) = 1',
            },
          ],
        })

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(true) // Warnings don't make file invalid
        expect(signals.errorCount()).toBe(0)
        expect(signals.warningCount()).toBe(1)
        expect(signals.unitWarnings()).toHaveLength(1)
        expect(signals.unitWarnings()[0].type).toBe('unit')
        expect(signals.unitWarnings()[0].severity).toBe('warning')
      })
    })

    it('should handle validation exceptions', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockImplementation(() => {
          throw new Error('Validation crashed')
        })

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(false)
        expect(signals.errorCount()).toBe(1)
        expect(signals.allErrors()[0].code).toBe('validation_exception')
        expect(signals.allErrors()[0].message).toContain('Validation crashed')
      })
    })

    it('should support error highlighting', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockReturnValue({
          is_valid: false,
          schema_errors: [
            {
              path: '/models/TestModel',
              message: 'test error',
              code: 'test',
              details: {},
            },
          ],
          structural_errors: [],
          unit_warnings: [],
        })

        const signals = createValidationSignals(file)

        expect(signals.allErrors()[0].highlighted).toBe(false)

        signals.highlightError('/models/TestModel')
        expect(signals.allErrors()[0].highlighted).toBe(true)

        signals.clearHighlight()
        expect(signals.allErrors()[0].highlighted).toBe(false)
      })
    })

    it('should support manual revalidation', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        let callCount = 0
        mockValidate.mockImplementation(() => {
          callCount++
          return {
            is_valid: true,
            schema_errors: [],
            structural_errors: [],
            unit_warnings: [],
          }
        })

        const signals = createValidationSignals(file, { validateOnInit: false })

        // With validateOnInit disabled, no validation runs until requested
        signals.isValid()
        expect(callCount).toBe(0)

        // Force revalidation runs synchronously
        signals.revalidate()
        expect(callCount).toBe(1)
        expect(signals.isValid()).toBe(true)

        signals.revalidate()
        expect(callCount).toBe(2)
      })
    })

    it('should debounce validation on file changes and report isValidating', () => {
      vi.useFakeTimers()
      try {
        let callCount = 0
        mockValidate.mockImplementation(() => {
          callCount++
          return {
            is_valid: true,
            schema_errors: [],
            structural_errors: [],
            unit_warnings: [],
          }
        })

        let signals!: ReturnType<typeof createValidationSignals>
        let setFile!: (f: EsmFile) => void
        let dispose!: () => void
        // The debounce effect gets its initial run when the root body
        // completes, so trigger file changes outside the createRoot body.
        createRoot((d) => {
          dispose = d
          const [file, setF] = createSignal(validEsmFile)
          setFile = setF
          signals = createValidationSignals(file, { debounceMs: 100 })
        })

        // Initial synchronous validation, nothing pending
        expect(callCount).toBe(1)
        expect(signals.isValidating()).toBe(false)

        // A file change marks validation as pending...
        setFile({ ...validEsmFile, metadata: { name: 'Changed' } })
        expect(signals.isValidating()).toBe(true)
        // ...but does not validate until the debounce elapses
        expect(callCount).toBe(1)

        // Rapid successive changes coalesce into one validation run
        setFile({ ...validEsmFile, metadata: { name: 'Changed again' } })
        vi.advanceTimersByTime(150)
        expect(callCount).toBe(2)
        expect(signals.isValidating()).toBe(false)

        dispose()
      } finally {
        vi.useRealTimers()
      }
    })

    it('should handle disabled validation', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        const signals = createValidationSignals(file, { enabled: false })

        expect(signals.isValid()).toBe(true)
        expect(signals.errorCount()).toBe(0)
        expect(signals.warningCount()).toBe(0)

        // Validate should not be called when disabled
        expect(mockValidate).not.toHaveBeenCalled()
      })
    })

    it('should handle missing file', () => {
      createRoot(() => {
        const [file] = createSignal(null as any)

        const signals = createValidationSignals(file)

        expect(signals.isValid()).toBe(false)
        expect(signals.errorCount()).toBe(1)
        expect(signals.allErrors()[0].code).toBe('missing_file')
      })
    })
  })

  describe('createValidationContext', () => {
    it('should provide simplified validation interface', () => {
      createRoot(() => {
        const [file] = createSignal(validEsmFile)

        mockValidate.mockReturnValue({
          is_valid: true,
          schema_errors: [],
          structural_errors: [],
          unit_warnings: [],
        })

        const context = createValidationContext(file)

        expect(context.isValid()).toBe(true)
        expect(context.errorCount()).toBe(0)
        expect(context.warningCount()).toBe(0)
        expect(typeof context.revalidate).toBe('function')
      })
    })
  })

  describe('createDebouncedValidation', () => {
    it('should debounce validation calls', async () => {
      let callCount = 0
      const validationFn = () => {
        callCount++
      }

      let debouncedValidation!: () => void
      createRoot(() => {
        debouncedValidation = createDebouncedValidation(validationFn, 50)
      })

      // Call multiple times rapidly
      debouncedValidation()
      debouncedValidation()
      debouncedValidation()

      // Should not be called immediately
      expect(callCount).toBe(0)

      // Should be called once after debounce period
      await new Promise((resolve) => setTimeout(resolve, 100))
      expect(callCount).toBe(1)
    })
  })
})
