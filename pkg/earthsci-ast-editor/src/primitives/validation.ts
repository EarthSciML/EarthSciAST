/**
 * Validation Primitive - Reactive validation signals for ESM files
 *
 * Provides reactive validation results for ESM files, wrapping the core
 * validation functionality from @earthsciml/ast with SolidJS reactivity.
 * Enables live validation feedback in editor components.
 *
 * Structure: validation runs synchronously on creation (when
 * `validateOnInit` is set) and inside a debounced `createEffect` when the
 * file changes. Results are written to a plain signal — no side effects
 * inside memos — so `isValidating()` truthfully reports the window between
 * a file change and the debounced validation completing.
 */

import { createMemo, createSignal, createEffect, on, onCleanup, untrack } from 'solid-js'
import { validate, type ValidationError, type ValidationResult } from '@earthsciml/ast'
import type { EsmFile } from '@earthsciml/ast'

/**
 * Configuration for validation behavior
 */
export interface ValidationConfig {
  /** Whether to enable automatic validation on file changes */
  enabled?: boolean
  /** Debounce delay in milliseconds to avoid excessive validation calls */
  debounceMs?: number
  /** Whether to validate on initialization */
  validateOnInit?: boolean
}

/**
 * Extended validation error with UI-specific metadata
 */
export interface ValidationErrorWithMetadata extends ValidationError {
  /** Error severity level */
  severity: 'error' | 'warning'
  /** Error category */
  type: 'schema' | 'structural' | 'unit'
  /** Whether this error is highlighted in the UI */
  highlighted?: boolean
}

/**
 * Validation signals interface providing reactive validation state
 */
export interface ValidationSignals {
  /** Reactive validation result */
  validationResult: () => ValidationResult
  /** All validation errors with metadata */
  allErrors: () => ValidationErrorWithMetadata[]
  /** Only schema errors */
  schemaErrors: () => ValidationErrorWithMetadata[]
  /** Only structural errors */
  structuralErrors: () => ValidationErrorWithMetadata[]
  /** Unit warnings */
  unitWarnings: () => ValidationErrorWithMetadata[]
  /** Total error count */
  errorCount: () => number
  /** Total warning count */
  warningCount: () => number
  /** Whether the file is valid */
  isValid: () => boolean
  /** Whether a debounced validation is pending */
  isValidating: () => boolean
  /** Force immediate re-validation */
  revalidate: () => void
  /** Highlight a specific error by path */
  highlightError: (path: string) => void
  /** Clear error highlighting */
  clearHighlight: () => void
}

/**
 * Severity by error category: schema and structural errors are hard errors;
 * unit checks surface as warnings.
 */
const SEVERITY_BY_TYPE: Record<'schema' | 'structural' | 'unit', 'error' | 'warning'> = {
  schema: 'error',
  structural: 'error',
  unit: 'warning',
}

/** Get severity level for a validation error category. */
function getErrorSeverity(type: 'schema' | 'structural' | 'unit'): 'error' | 'warning' {
  return SEVERITY_BY_TYPE[type]
}

/** Empty (valid) validation result */
function emptyResult(): ValidationResult {
  return {
    is_valid: true,
    schema_errors: [],
    structural_errors: [],
    unit_warnings: [],
  }
}

/** Run validation on a file, converting exceptions into result errors */
function runValidation(currentFile: EsmFile | null | undefined): ValidationResult {
  if (!currentFile) {
    return {
      is_valid: false,
      schema_errors: [
        {
          path: '$',
          message: 'No ESM file provided',
          code: 'missing_file',
          details: {},
        },
      ],
      structural_errors: [],
      unit_warnings: [],
    }
  }

  try {
    return validate(currentFile)
  } catch (error: unknown) {
    const err = error as Error
    return {
      is_valid: false,
      schema_errors: [
        {
          path: '$',
          message: `Validation error: ${err.message || String(error)}`,
          code: 'validation_exception',
          details: {
            exception_type: err.constructor.name,
            error: err.message || String(error),
          },
        },
      ],
      structural_errors: [],
      unit_warnings: [],
    }
  }
}

/**
 * Create reactive validation signals for an ESM file
 *
 * @param file - Reactive signal containing the current ESM file
 * @param config - Optional configuration for validation behavior
 * @returns Validation signals interface with reactive validation state
 */
export function createValidationSignals(
  file: () => EsmFile,
  config: ValidationConfig = {},
): ValidationSignals {
  const { enabled = true, debounceMs = 300, validateOnInit = true } = config

  // Internal state
  const [isValidating, setIsValidating] = createSignal(false)
  const [highlightedPath, setHighlightedPath] = createSignal<string | null>(null)
  const [validationResult, setValidationResult] = createSignal<ValidationResult>(
    // Validate the initial file synchronously when requested; otherwise start
    // from an empty (valid) result until the first file change or revalidate()
    enabled && validateOnInit ? runValidation(untrack(file)) : emptyResult(),
  )

  let validationTimeout: ReturnType<typeof setTimeout> | undefined

  /** Immediately validate the current file and publish the result */
  const doValidate = () => {
    if (!enabled) return
    setValidationResult(runValidation(untrack(file)))
    setIsValidating(false)
  }

  // Debounced validation on file changes. Deferred so creation does not
  // schedule a redundant run on top of the synchronous initial validation.
  if (enabled) {
    createEffect(
      on(
        () => file(),
        () => {
          setIsValidating(true)
          if (validationTimeout) {
            clearTimeout(validationTimeout)
          }
          validationTimeout = setTimeout(() => {
            validationTimeout = undefined
            doValidate()
          }, debounceMs)
        },
        { defer: true },
      ),
    )

    onCleanup(() => {
      if (validationTimeout) {
        clearTimeout(validationTimeout)
      }
    })
  }

  // All errors with metadata and highlighting
  const allErrors = createMemo((): ValidationErrorWithMetadata[] => {
    const result = validationResult()
    const highlighted = highlightedPath()
    const errors: ValidationErrorWithMetadata[] = []

    // Safety check - ensure result exists and has expected properties
    if (!result) {
      return errors
    }

    // Add schema errors
    ;(result.schema_errors || []).forEach((error) => {
      errors.push({
        ...error,
        severity: getErrorSeverity('schema'),
        type: 'schema',
        highlighted: highlighted === error.path,
      })
    })

    // Add structural errors
    ;(result.structural_errors || []).forEach((error) => {
      errors.push({
        ...error,
        severity: getErrorSeverity('structural'),
        type: 'structural',
        highlighted: highlighted === error.path,
      })
    })

    // Add unit warnings (UnitWarning carries message/location/equation, not path/details)
    ;(result.unit_warnings || []).forEach((warning) => {
      const path = warning.location || '$'
      const details: Record<string, unknown> = {}
      if (warning.equation !== undefined) details.equation = warning.equation
      const asError: ValidationError = {
        path,
        message: warning.message,
        code: 'unit_warning',
        details,
      }
      errors.push({
        ...asError,
        severity: getErrorSeverity('unit'),
        type: 'unit',
        highlighted: highlighted === path,
      })
    })

    return errors
  })

  // Filtered error lists
  const schemaErrors = createMemo(() => allErrors().filter((e) => e.type === 'schema'))

  const structuralErrors = createMemo(() => allErrors().filter((e) => e.type === 'structural'))

  const unitWarnings = createMemo(() => allErrors().filter((e) => e.type === 'unit'))

  // Summary metrics
  const errorCount = createMemo(() => allErrors().filter((e) => e.severity === 'error').length)

  const warningCount = createMemo(() => allErrors().filter((e) => e.severity === 'warning').length)

  const isValid = createMemo(() => {
    const result = validationResult()
    return result ? result.is_valid : false
  })

  // Actions
  const revalidate = () => {
    if (validationTimeout) {
      clearTimeout(validationTimeout)
      validationTimeout = undefined
    }
    doValidate()
  }

  const highlightError = (path: string) => {
    setHighlightedPath(path)
  }

  const clearHighlight = () => {
    setHighlightedPath(null)
  }

  return {
    validationResult,
    allErrors,
    schemaErrors,
    structuralErrors,
    unitWarnings,
    errorCount,
    warningCount,
    isValid,
    isValidating,
    revalidate,
    highlightError,
    clearHighlight,
  }
}

/**
 * Create a simplified validation context for components that only need basic validation state
 *
 * @param file - Reactive signal containing the current ESM file
 * @param config - Optional configuration
 * @returns Simplified validation interface
 */
export function createValidationContext(file: () => EsmFile, config: ValidationConfig = {}) {
  const signals = createValidationSignals(file, config)

  return {
    isValid: signals.isValid,
    errorCount: signals.errorCount,
    warningCount: signals.warningCount,
    revalidate: signals.revalidate,
  }
}

/**
 * Debounced validation hook for use in components that trigger validation
 *
 * @param validationFn - Function that performs validation
 * @param debounceMs - Debounce delay in milliseconds
 * @returns Debounced validation function
 */
export function createDebouncedValidation(validationFn: () => void, debounceMs: number = 300) {
  let timeout: ReturnType<typeof setTimeout> | undefined

  const debouncedFn = () => {
    if (timeout) {
      clearTimeout(timeout)
    }
    timeout = setTimeout(validationFn, debounceMs)
  }

  onCleanup(() => {
    if (timeout) {
      clearTimeout(timeout)
    }
  })

  return debouncedFn
}
