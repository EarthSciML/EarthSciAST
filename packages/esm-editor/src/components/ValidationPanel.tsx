/**
 * ValidationPanel - Reactive panel showing validation results
 *
 * This component displays schema errors, structural errors, and unit warnings
 * from ESM format validation. Updates live via createMemo wrapping validate().
 * Error items are clickable and highlight the offending AST node in the expression
 * editor by setting the selection path from the error's JSON Pointer.
 */

import { Component, createMemo, For, Show } from 'solid-js';
import type { EsmFile } from 'earthsci-toolkit';
import { validate, type ValidationError, type ValidationResult } from 'earthsci-toolkit';

export interface ValidationPanelProps {
  /** The ESM file to validate */
  esmFile: EsmFile;

  /** Callback when an error is clicked to highlight the corresponding AST node */
  onErrorClick?: (path: string) => void;

  /** CSS class for styling */
  class?: string;

  /** Whether the panel is collapsed */
  collapsed?: boolean;

  /** Callback when collapse state changes */
  onToggleCollapsed?: (collapsed: boolean) => void;
}

/**
 * Get severity level for error classification
 */
function getErrorSeverity(_error: ValidationError): 'error' | 'warning' {
  // Schema errors are always errors
  // Structural errors could be warnings in some cases, but treating as errors for now
  // Could be enhanced to check error.code for specific warning types
  return 'error';
}

/**
 * Main ValidationPanel component
 */
export const ValidationPanel: Component<ValidationPanelProps> = (props) => {
  // Reactive validation results
  const validationResult = createMemo((): ValidationResult => {
    return validate(props.esmFile);
  });

  // Aggregate all errors with severity
  const allErrors = createMemo(() => {
    const result = validationResult();
    const errors: Array<ValidationError & { severity: 'error' | 'warning'; type: 'schema' | 'structural' }> = [];

    // Add schema errors
    result.schema_errors.forEach(error => {
      errors.push({
        ...error,
        severity: 'error',
        type: 'schema'
      });
    });

    // Add structural errors
    result.structural_errors.forEach(error => {
      errors.push({
        ...error,
        severity: getErrorSeverity(error),
        type: 'structural'
      });
    });

    return errors;
  });

  // Group errors by severity
  const errorsByType = createMemo(() => {
    const errors = allErrors();
    return {
      errors: errors.filter(e => e.severity === 'error'),
      warnings: errors.filter(e => e.severity === 'warning')
    };
  });

  // Total counts for badge display
  const errorCount = createMemo(() => errorsByType().errors.length);
  const warningCount = createMemo(() => errorsByType().warnings.length);
  const isValid = createMemo(() => validationResult().is_valid);

  // Handle error click to highlight AST node
  const handleErrorClick = (error: ValidationError) => {
    if (props.onErrorClick) {
      props.onErrorClick(error.path);
    }
  };

  // Handle collapse toggle
  const handleToggleCollapsed = () => {
    if (props.onToggleCollapsed) {
      props.onToggleCollapsed(!props.collapsed);
    }
  };

  // CSS classes
  const panelClasses = () => {
    const classes = ['validation-panel'];
    if (props.collapsed) classes.push('collapsed');
    if (isValid()) classes.push('valid');
    else classes.push('invalid');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

  return (
    <div class={panelClasses()}>
      {/* Panel header with error counts and collapse toggle */}
      <div class="validation-header" onClick={handleToggleCollapsed}>
        <h3 class="validation-title">
          Validation Results
          <Show when={errorCount() > 0}>
            <span class="error-badge" title={`${errorCount()} error(s)`}>
              {errorCount()}
            </span>
          </Show>
          <Show when={warningCount() > 0}>
            <span class="warning-badge" title={`${warningCount()} warning(s)`}>
              {warningCount()}
            </span>
          </Show>
          <Show when={isValid()}>
            <span class="success-badge" title="No errors found">
              ✓
            </span>
          </Show>
        </h3>
        <button
          class="collapse-toggle"
          aria-label={props.collapsed ? 'Expand validation panel' : 'Collapse validation panel'}
        >
          {props.collapsed ? '▶' : '▼'}
        </button>
      </div>

      {/* Panel content - only shown when not collapsed */}
      <Show when={!props.collapsed}>
        <div class="validation-content">
          {/* Success message when valid */}
          <Show when={isValid()}>
            <div class="validation-success">
              <span class="success-icon">✓</span>
              No validation errors found. The ESM file is valid.
            </div>
          </Show>

          {/* Error sections */}
          <Show when={!isValid()}>
            {/* Schema errors section */}
            <Show when={errorsByType().errors.filter(e => e.type === 'schema').length > 0}>
              <div class="error-section">
                <h4 class="error-section-title error-title">
                  Schema Errors ({errorsByType().errors.filter(e => e.type === 'schema').length})
                </h4>
                <div class="error-list">
                  <For each={errorsByType().errors.filter(e => e.type === 'schema')}>
                    {(error) => (
                      <div
                        class="error-item error-severity clickable"
                        onClick={() => handleErrorClick(error)}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            handleErrorClick(error);
                          }
                        }}
                      >
                        <div class="error-header">
                          <span class="error-icon">🔴</span>
                          <span class="error-code">{error.code}</span>
                          <span class="error-path" title={`Path: ${error.path}`}>
                            {error.path || '$'}
                          </span>
                        </div>
                        <div class="error-message">{error.message}</div>
                        <Show when={Object.keys(error.details).length > 0}>
                          <div class="error-details">
                            <For each={Object.entries(error.details)}>
                              {([key, value]) => (
                                <div class="error-detail">
                                  <strong>{key}:</strong> {String(value)}
                                </div>
                              )}
                            </For>
                          </div>
                        </Show>
                      </div>
                    )}
                  </For>
                </div>
              </div>
            </Show>

            {/* Structural errors section */}
            <Show when={errorsByType().errors.filter(e => e.type === 'structural').length > 0}>
              <div class="error-section">
                <h4 class="error-section-title error-title">
                  Structural Errors ({errorsByType().errors.filter(e => e.type === 'structural').length})
                </h4>
                <div class="error-list">
                  <For each={errorsByType().errors.filter(e => e.type === 'structural')}>
                    {(error) => (
                      <div
                        class="error-item error-severity clickable"
                        onClick={() => handleErrorClick(error)}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            handleErrorClick(error);
                          }
                        }}
                      >
                        <div class="error-header">
                          <span class="error-icon">🔴</span>
                          <span class="error-code">{error.code}</span>
                          <span class="error-path" title={`Path: ${error.path}`}>
                            {error.path || '$'}
                          </span>
                        </div>
                        <div class="error-message">{error.message}</div>
                        <Show when={Object.keys(error.details).length > 0}>
                          <div class="error-details">
                            <For each={Object.entries(error.details)}>
                              {([key, value]) => (
                                <div class="error-detail">
                                  <strong>{key}:</strong> {String(value)}
                                </div>
                              )}
                            </For>
                          </div>
                        </Show>
                      </div>
                    )}
                  </For>
                </div>
              </div>
            </Show>

            {/* Warnings section */}
            <Show when={warningCount() > 0}>
              <div class="error-section">
                <h4 class="error-section-title warning-title">
                  Warnings ({warningCount()})
                </h4>
                <div class="error-list">
                  <For each={errorsByType().warnings}>
                    {(warning) => (
                      <div
                        class="error-item warning-severity clickable"
                        onClick={() => handleErrorClick(warning)}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            handleErrorClick(warning);
                          }
                        }}
                      >
                        <div class="error-header">
                          <span class="error-icon">🟡</span>
                          <span class="error-code">{warning.code}</span>
                          <span class="error-path" title={`Path: ${warning.path}`}>
                            {warning.path || '$'}
                          </span>
                        </div>
                        <div class="error-message">{warning.message}</div>
                        <Show when={Object.keys(warning.details).length > 0}>
                          <div class="error-details">
                            <For each={Object.entries(warning.details)}>
                              {([key, value]) => (
                                <div class="error-detail">
                                  <strong>{key}:</strong> {String(value)}
                                </div>
                              )}
                            </For>
                          </div>
                        </Show>
                      </div>
                    )}
                  </For>
                </div>
              </div>
            </Show>
          </Show>
        </div>
      </Show>
    </div>
  );
};

export default ValidationPanel;