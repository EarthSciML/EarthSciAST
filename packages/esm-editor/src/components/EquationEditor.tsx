/**
 * EquationEditor - Single equation editor with LHS = RHS format
 *
 * This component provides an interactive editor for individual equations,
 * displaying them as "left_expression = right_expression" with clickable
 * expressions that can be edited using the ExpressionNode component.
 */

import { Component, createSignal, createMemo, Show } from 'solid-js';
import type { Equation, Expression } from 'earthsci-toolkit';
import { ExpressionNode } from './ExpressionNode';

export interface EquationEditorProps {
  /** The equation to display and edit */
  equation: Equation;

  /** Callback when the equation is modified */
  onEquationChange?: (newEquation: Equation) => void;

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>;

  /** Whether the editor is in read-only mode */
  readonly?: boolean;

  /** CSS class for styling */
  class?: string;

  /** Unique identifier for this editor */
  id?: string;
}

/**
 * Main EquationEditor component
 */
export const EquationEditor: Component<EquationEditorProps> = (props) => {
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);

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
    if (props.readonly || !props.onEquationChange) return;

    // Clone the equation and update the specified path
    const newEquation = structuredClone(props.equation);

    // Navigate to the path and replace the expression
    let current: any = newEquation;
    for (let i = 0; i < path.length - 1; i++) {
      current = current[path[i]];
    }

    if (path.length > 0) {
      current[path[path.length - 1]] = newExpr;
    }

    props.onEquationChange(newEquation);
  };

  const editorClasses = () => {
    const classes = ['equation-editor'];
    if (props.readonly) classes.push('readonly');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

  return (
    <div class={editorClasses()} id={props.id}>
      <div class="equation-content">
        {/* Left-hand side */}
        <div class="equation-lhs">
          <ExpressionNode
            expr={props.equation.lhs}
            path={['lhs']}
            highlightedVars={() => highlightedVars()}
            onHoverVar={handleHoverVar}
            onSelect={handleSelect}
            onReplace={handleReplace}
            selectedPath={selectedPath()}
          />
        </div>

        {/* Equals sign */}
        <div class="equation-equals" aria-label="equals">
          =
        </div>

        {/* Right-hand side */}
        <div class="equation-rhs">
          <ExpressionNode
            expr={props.equation.rhs}
            path={['rhs']}
            highlightedVars={() => highlightedVars()}
            onHoverVar={handleHoverVar}
            onSelect={handleSelect}
            onReplace={handleReplace}
            selectedPath={selectedPath()}
          />
        </div>
      </div>

      {/* Optional equation metadata display */}
      <Show when={props.equation._comment}>
        <div class="equation-description" title="Equation comment">
          {props.equation._comment}
        </div>
      </Show>
    </div>
  );
};

export default EquationEditor;