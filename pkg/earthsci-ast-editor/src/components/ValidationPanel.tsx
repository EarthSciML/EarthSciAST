/**
 * ValidationPanel - Reactive panel showing validation results
 *
 * This component displays schema errors, structural errors, and unit warnings
 * from ESM format validation. Updates live via createMemo wrapping validate().
 * Error items are clickable and highlight the offending AST node in the expression
 * editor by setting the selection path from the error's JSON Pointer.
 */

import { Component, createMemo, For, Show } from 'solid-js';
import type { EsmFile } from '@earthsciml/ast';
import { validate, type ValidationError, type ValidationResult } from '@earthsciml/ast';

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

/** A validation item with UI metadata */
interface ValidationItem extends ValidationError {
  severity: 'error' | 'warning';
  type: 'schema' | 'structural' | 'unit';
}

/**
 * One titled, clickable list of validation items. Rendered once per
 * category (schema errors, structural errors, warnings).
 */
const ErrorSection: Component<{
  title: string;
  items: ValidationItem[];
  severity: 'error' | 'warning';
  onErrorClick: (error: ValidationError) => void;
}> = (props) => {
  return (
    <Show when={props.items.length > 0}>
      <div class="error-section">
        <h4 class={`error-section-title ${props.severity === 'warning' ? 'warning-title' : 'error-title'}`}>
          {props.title} ({props.items.length})
        </h4>
        <div class="error-list">
          <For each={props.items}>
            {(error) => (
              <div
                class={`error-item ${props.severity === 'warning' ? 'warning-severity' : 'error-severity'} clickable`}
                onClick={() => props.onErrorClick(error)}
                role="button"
                tabIndex={0}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    props.onErrorClick(error);
                  }
                }}
              >
                <div class="error-header">
                  <span class="error-icon">{props.severity === 'warning' ? '🟡' : '🔴'}</span>
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
  );
};

/**
 * Main ValidationPanel component
 */
export const ValidationPanel: Component<ValidationPanelProps> = (props) => {
  // Reactive validation results
  const validationResult = createMemo((): ValidationResult => {
    return validate(props.esmFile);
  });

  // Categorized validation items. Schema and structural failures are errors;
  // unit warnings from the toolkit's dimensional analysis are warnings.
  const schemaErrors = createMemo((): ValidationItem[] =>
    (validationResult().schema_errors || []).map(error => ({
      ...error,
      severity: 'error' as const,
      type: 'schema' as const
    }))
  );

  const structuralErrors = createMemo((): ValidationItem[] =>
    (validationResult().structural_errors || []).map(error => ({
      ...error,
      severity: 'error' as const,
      type: 'structural' as const
    }))
  );

  const unitWarnings = createMemo((): ValidationItem[] =>
    (validationResult().unit_warnings || []).map(warning => {
      const details: Record<string, unknown> = {};
      if (warning.equation !== undefined) details.equation = warning.equation;
      return {
        path: warning.location || '$',
        message: warning.message,
        code: 'unit_warning',
        details,
        severity: 'warning' as const,
        type: 'unit' as const
      };
    })
  );

  // Total counts for badge display
  const errorCount = createMemo(() => schemaErrors().length + structuralErrors().length);
  const warningCount = createMemo(() => unitWarnings().length);
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
          {/* Success message when valid and warning-free */}
          <Show when={isValid() && warningCount() === 0}>
            <div class="validation-success">
              <span class="success-icon">✓</span>
              No validation errors found. The ESM file is valid.
            </div>
          </Show>

          <ErrorSection
            title="Schema Errors"
            items={schemaErrors()}
            severity="error"
            onErrorClick={handleErrorClick}
          />

          <ErrorSection
            title="Structural Errors"
            items={structuralErrors()}
            severity="error"
            onErrorClick={handleErrorClick}
          />

          <ErrorSection
            title="Warnings"
            items={unitWarnings()}
            severity="warning"
            onErrorClick={handleErrorClick}
          />
        </div>
      </Show>
    </div>
  );
};

export default ValidationPanel;
