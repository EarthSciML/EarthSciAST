/**
 * Validation Primitive - Reactive validation signals for ESM files
 *
 * Provides reactive validation results for ESM files, wrapping the core
 * validation functionality from earthsci-toolkit with SolidJS reactivity.
 * Enables live validation feedback in editor components.
 */

import { createMemo, createSignal, createEffect, onCleanup } from 'solid-js';
import { validate, type ValidationError, type ValidationResult } from 'earthsci-toolkit';
import type { EsmFile } from 'earthsci-toolkit';

/**
 * Configuration for validation behavior
 */
export interface ValidationConfig {
  /** Whether to enable automatic validation on file changes */
  enabled?: boolean;
  /** Debounce delay in milliseconds to avoid excessive validation calls */
  debounceMs?: number;
  /** Whether to validate on initialization */
  validateOnInit?: boolean;
}

/**
 * Extended validation error with UI-specific metadata
 */
export interface ValidationErrorWithMetadata extends ValidationError {
  /** Error severity level */
  severity: 'error' | 'warning';
  /** Error category */
  type: 'schema' | 'structural' | 'unit';
  /** Whether this error is highlighted in the UI */
  highlighted?: boolean;
}

/**
 * Validation signals interface providing reactive validation state
 */
export interface ValidationSignals {
  /** Reactive validation result */
  validationResult: () => ValidationResult;
  /** All validation errors with metadata */
  allErrors: () => ValidationErrorWithMetadata[];
  /** Only schema errors */
  schemaErrors: () => ValidationErrorWithMetadata[];
  /** Only structural errors */
  structuralErrors: () => ValidationErrorWithMetadata[];
  /** Unit warnings */
  unitWarnings: () => ValidationErrorWithMetadata[];
  /** Total error count */
  errorCount: () => number;
  /** Total warning count */
  warningCount: () => number;
  /** Whether the file is valid */
  isValid: () => boolean;
  /** Whether validation is currently running */
  isValidating: () => boolean;
  /** Force re-validation */
  revalidate: () => void;
  /** Highlight a specific error by path */
  highlightError: (path: string) => void;
  /** Clear error highlighting */
  clearHighlight: () => void;
}

/**
 * Get severity level for a validation error
 */
function getErrorSeverity(_error: ValidationError, type: 'schema' | 'structural' | 'unit'): 'error' | 'warning' {
  // Unit errors are typically warnings
  if (type === 'unit') {
    return 'warning';
  }

  // Schema errors are always errors
  if (type === 'schema') {
    return 'error';
  }

  // Structural errors could be warnings in some cases
  // For now, treating all as errors, but could be enhanced based on error code
  return 'error';
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
  config: ValidationConfig = {}
): ValidationSignals {
  const {
    enabled = true,
    debounceMs = 300,
    validateOnInit = true
  } = config;

  // Internal state
  const [isValidating, setIsValidating] = createSignal(false);
  const [highlightedPath, setHighlightedPath] = createSignal<string | null>(null);
  const [forceRevalidation, setForceRevalidation] = createSignal(0);

  // Debounced validation trigger
  let validationTimeout: ReturnType<typeof setTimeout> | undefined;

  // Core validation result with debouncing
  const validationResult = createMemo((): ValidationResult => {
    // Access forceRevalidation to trigger recomputation when needed
    forceRevalidation();

    if (!enabled) {
      return {
        is_valid: true,
        schema_errors: [],
        structural_errors: [],
        unit_warnings: []
      };
    }

    const currentFile = file();
    if (!currentFile) {
      return {
        is_valid: false,
        schema_errors: [{
          path: '$',
          message: 'No ESM file provided',
          code: 'missing_file',
          details: {}
        }],
        structural_errors: [],
        unit_warnings: []
      };
    }

    try {
      setIsValidating(true);
      const result = validate(currentFile);
      setIsValidating(false);
      return result;
    } catch (error: unknown) {
      setIsValidating(false);
      const err = error as Error;
      return {
        is_valid: false,
        schema_errors: [{
          path: '$',
          message: `Validation error: ${err.message || String(error)}`,
          code: 'validation_exception',
          details: {
            exception_type: err.constructor.name,
            error: err.message || String(error)
          }
        }],
        structural_errors: [],
        unit_warnings: []
      };
    }
  });

  // All errors with metadata and highlighting
  const allErrors = createMemo((): ValidationErrorWithMetadata[] => {
    const result = validationResult();
    const highlighted = highlightedPath();
    const errors: ValidationErrorWithMetadata[] = [];

    // Safety check - ensure result exists and has expected properties
    if (!result) {
      return errors;
    }

    // Add schema errors
    (result.schema_errors || []).forEach(error => {
      errors.push({
        ...error,
        severity: getErrorSeverity(error, 'schema'),
        type: 'schema',
        highlighted: highlighted === error.path
      });
    });

    // Add structural errors
    (result.structural_errors || []).forEach(error => {
      errors.push({
        ...error,
        severity: getErrorSeverity(error, 'structural'),
        type: 'structural',
        highlighted: highlighted === error.path
      });
    });

    // Add unit warnings (UnitWarning carries message/code/location/equation, not path/details)
    (result.unit_warnings || []).forEach(warning => {
      const path = warning.location || '$';
      const details: Record<string, unknown> = {};
      if (warning.equation !== undefined) details.equation = warning.equation;
      const asError: ValidationError = {
        path,
        message: warning.message,
        code: warning.code || 'unit_warning',
        details
      };
      errors.push({
        ...asError,
        severity: getErrorSeverity(asError, 'unit'),
        type: 'unit',
        highlighted: highlighted === path
      });
    });

    return errors;
  });

  // Filtered error lists
  const schemaErrors = createMemo(() =>
    allErrors().filter(e => e.type === 'schema')
  );

  const structuralErrors = createMemo(() =>
    allErrors().filter(e => e.type === 'structural')
  );

  const unitWarnings = createMemo(() =>
    allErrors().filter(e => e.type === 'unit')
  );

  // Summary metrics
  const errorCount = createMemo(() =>
    allErrors().filter(e => e.severity === 'error').length
  );

  const warningCount = createMemo(() =>
    allErrors().filter(e => e.severity === 'warning').length
  );

  const isValid = createMemo(() => {
    const result = validationResult();
    return result ? result.is_valid : false;
  });

  // Actions
  const revalidate = () => {
    setForceRevalidation(prev => prev + 1);
  };

  const highlightError = (path: string) => {
    setHighlightedPath(path);
  };

  const clearHighlight = () => {
    setHighlightedPath(null);
  };

  // Setup debounced validation on file changes
  if (enabled && debounceMs > 0) {
    createEffect(() => {
      // Track file changes
      file();

      // Clear existing timeout
      if (validationTimeout) {
        clearTimeout(validationTimeout);
      }

      // Set new timeout for debounced validation
      validationTimeout = setTimeout(() => {
        revalidate();
      }, debounceMs);
    });

    // Cleanup timeout on disposal
    onCleanup(() => {
      if (validationTimeout) {
        clearTimeout(validationTimeout);
      }
    });
  }

  // Initial validation
  if (validateOnInit && enabled) {
    // Trigger initial validation on next tick
    setTimeout(() => revalidate(), 0);
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
    clearHighlight
  };
}

/**
 * Create a simplified validation context for components that only need basic validation state
 *
 * @param file - Reactive signal containing the current ESM file
 * @param config - Optional configuration
 * @returns Simplified validation interface
 */
export function createValidationContext(
  file: () => EsmFile,
  config: ValidationConfig = {}
) {
  const signals = createValidationSignals(file, config);

  return {
    isValid: signals.isValid,
    errorCount: signals.errorCount,
    warningCount: signals.warningCount,
    revalidate: signals.revalidate
  };
}

/**
 * Debounced validation hook for use in components that trigger validation
 *
 * @param validationFn - Function that performs validation
 * @param debounceMs - Debounce delay in milliseconds
 * @returns Debounced validation function
 */
export function createDebouncedValidation(
  validationFn: () => void,
  debounceMs: number = 300
) {
  let timeout: ReturnType<typeof setTimeout> | undefined;

  const debouncedFn = () => {
    if (timeout) {
      clearTimeout(timeout);
    }
    timeout = setTimeout(validationFn, debounceMs);
  };

  onCleanup(() => {
    if (timeout) {
      clearTimeout(timeout);
    }
  });

  return debouncedFn;
}