/**
 * ExpressionEditor - Single expression editor without LHS = RHS format
 *
 * This component provides an interactive editor for individual expressions,
 * displaying them as a single mathematical expression with clickable
 * nodes that can be edited using the ExpressionNode component.
 * This is distinct from EquationEditor which shows "left = right" format.
 */

import { Component, createSignal, createMemo, Show } from 'solid-js';
import type { Expression } from '@earthsciml/ast';
import { ExpressionNode } from './ExpressionNode';
import { ExpressionPalette } from './ExpressionPalette';

export interface ExpressionEditorProps {
  /** The initial expression to display and edit */
  initialExpression: Expression;

  /** Callback when the expression is modified */
  onChange?: (newExpression: Expression) => void;

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>;

  /** Whether the editor is in read-only mode */
  allowEditing?: boolean;

  /** Whether to show the expression palette */
  showPalette?: boolean;

  /** Whether to show validation errors */
  showValidation?: boolean;

  /** CSS class for styling */
  class?: string;

  /** Unique identifier for this editor */
  id?: string;
}

/**
 * Main ExpressionEditor component
 */
export const ExpressionEditor: Component<ExpressionEditorProps> = (props) => {
  const [currentExpression, setCurrentExpression] = createSignal<Expression>(props.initialExpression);
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);
  const [showPalettePanel, setShowPalettePanel] = createSignal(props.showPalette ?? false);

  // Create reactive highlighted vars set that includes hovered variable
  const highlightedVars = createMemo(() => {
    const baseHighlighted = props.highlightedVars || new Set<string>();
    const hovered = hoveredVar();

    if (hovered && !baseHighlighted.has(hovered)) {
      return new Set([...baseHighlighted, hovered]);
    }
    return baseHighlighted;
  });

  // Handle selection of expression nodes
  const handleSelect = (path: (string | number)[]) => {
    setSelectedPath(path);
  };

  // Handle hovering over variables
  const handleHoverVar = (varName: string | null) => {
    setHoveredVar(varName);
  };

  // Handle replacement of expression parts
  const handleReplace = (path: (string | number)[], newExpr: Expression) => {
    if (props.allowEditing === false) return;

    let updatedExpression: Expression;

    if (path.length === 0) {
      // Replacing the root expression
      updatedExpression = newExpr;
    } else {
      // Clone the expression and update the specified path
      updatedExpression = structuredClone(currentExpression());

      // Navigate to the path and replace the expression
      let current: any = updatedExpression;
      for (let i = 0; i < path.length - 1; i++) {
        current = current[path[i]];
      }

      current[path[path.length - 1]] = newExpr;
    }

    setCurrentExpression(updatedExpression);
    props.onChange?.(updatedExpression);
  };

  // Handle palette insertion
  const handleInsertExpression = (expr: Expression) => {
    const selected = selectedPath();
    if (selected) {
      handleReplace(selected, expr);
    } else {
      // If nothing selected, replace the entire expression
      handleReplace([], expr);
    }
    setShowPalettePanel(false);
  };

  const editorClasses = () => {
    const classes = ['expression-editor'];
    if (props.allowEditing === false) classes.push('readonly');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

  return (
    <div class={editorClasses()} id={props.id}>
      <div class="expression-editor-content">
        {/* Main expression display */}
        <div class="expression-main">
          <ExpressionNode
            expr={currentExpression()}
            path={[]}
            highlightedVars={() => highlightedVars()}
            onHoverVar={handleHoverVar}
            onSelect={handleSelect}
            onReplace={handleReplace}
            selectedPath={selectedPath()}
          />
        </div>

        {/* Optional palette toggle button */}
        <Show when={props.showPalette && props.allowEditing !== false}>
          <button
            class="palette-toggle-btn"
            onClick={() => setShowPalettePanel(prev => !prev)}
            title="Toggle expression palette"
            aria-label="Toggle expression palette"
          >
            {showPalettePanel() ? '←' : '→'}
          </button>
        </Show>
      </div>

      {/* Optional expression palette */}
      <Show when={showPalettePanel() && props.showPalette && props.allowEditing !== false}>
        <div class="expression-palette-container">
          <ExpressionPalette
            visible={showPalettePanel()}
            onInsertExpression={handleInsertExpression}
            class="expression-editor-palette"
          />
        </div>
      </Show>

      {/* Optional validation display */}
      <Show when={props.showValidation}>
        <div class="expression-validation">
          {/* Placeholder for validation errors - would be populated by parent */}
          {/* This could show syntax errors, type mismatches, undefined variables, etc. */}
        </div>
      </Show>
    </div>
  );
};

export default ExpressionEditor;