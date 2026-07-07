/**
 * ExpressionNode - Core SolidJS component for rendering interactive AST nodes
 *
 * This is a simplified, focused recursive AST renderer for the esm-editor package.
 * It provides the foundation for interactive expression editing with:
 * - Number literals with click-to-select and hover highlighting
 * - Variable references with chemical subscript rendering (shared module)
 * - Operator nodes that dispatch to the layout components in src/layout
 *   (Fraction, Superscript, Radical) for mathematical typography
 */

import { Component, Accessor, createSignal, createMemo, Show, Switch, Match, Index, JSX } from 'solid-js';
import type { Expression, ExpressionNode as ExprNode } from 'earthsci-toolkit';
import { useMaybeStructuralEditingContext, DraggableExpression, StructuralEditingMenu, COMMUTATIVE_OPERATORS } from '../primitives/structural-editing';
import { renderChemicalName } from '../primitives/chemical-formula';
import { NodeFieldEditor, opHasFieldEditor } from './NodeFieldEditor';
import { Fraction } from '../layout/Fraction';
import { Superscript } from '../layout/Superscript';
import { Radical } from '../layout/Radical';

export interface ExpressionNodeProps {
  /** The expression to render (reactive from Solid store) */
  expr: Expression;

  /** AST path for unique identification and updates */
  path: (string | number)[];

  /** Currently highlighted variable equivalence class */
  highlightedVars: Accessor<Set<string>>;

  /** Callback when hovering over a variable */
  onHoverVar: (name: string | null) => void;

  /** Callback when selecting a node */
  onSelect: (path: (string | number)[]) => void;

  /** Callback when replacing a node with new expression */
  onReplace: (path: (string | number)[], newExpr: Expression) => void;

  /** Currently selected path (for showing structural editing menu) */
  selectedPath?: (string | number)[] | null;

  /** Parent path for drag operations */
  parentPath?: (string | number)[];

  /** Index within parent for drag operations */
  indexInParent?: number;
}

/**
 * Operator layout dispatcher with proper mathematical layout and
 * drag-and-drop support. Fractions, exponents, and radicals render via the
 * shared layout components (Section 5.2.3) instead of hand-rolled markup.
 */
function OperatorLayout(props: {
  node: ExprNode;
  path: (string | number)[];
  highlightedVars: Accessor<Set<string>>;
  onHoverVar: (name: string | null) => void;
  onSelect: (path: (string | number)[]) => void;
  onReplace: (path: (string | number)[], newExpr: Expression) => void;
  selectedPath?: (string | number)[] | null;
}) {
  // Structural editing context is optional (non-throwing accessor)
  const structuralEditing = useMaybeStructuralEditingContext();

  const op = () => props.node.op;
  const args = () => (props.node.args as Expression[] | undefined) ?? [];
  const isCommutative = () => COMMUTATIVE_OPERATORS.has(props.node.op);

  // Helper to create child nodes with drag support
  const child = (arg: () => Expression, index: number): JSX.Element => {
    const argPath = () => [...props.path, 'args', index];
    const childNode = (
      <ExpressionNode
        expr={arg()}
        path={argPath()}
        highlightedVars={props.highlightedVars}
        onHoverVar={props.onHoverVar}
        onSelect={props.onSelect}
        onReplace={props.onReplace}
        selectedPath={props.selectedPath}
        parentPath={props.path}
        indexInParent={index}
      />
    );

    // Wrap in draggable component for commutative operations
    return (
      <Show
        when={structuralEditing && isCommutative() && args().length > 1}
        fallback={childNode}
      >
        <DraggableExpression
          path={argPath()}
          index={index}
          parentPath={props.path}
          canDrag={true}
        >
          {childNode}
        </DraggableExpression>
      </Show>
    );
  };

  /** Render args as a separated infix sequence */
  const infixArgs = (separator: () => JSX.Element) => (
    <Index each={args()}>
      {(arg, index) => (
        <>
          <Show when={index > 0}>{separator()}</Show>
          {child(arg, index)}
        </>
      )}
    </Index>
  );

  /** Render args as a parenthesized function argument list */
  const functionArgs = () => (
    <span class="esm-function-args">
      (
      <Index each={args()}>
        {(arg, index) => (
          <>
            <Show when={index > 0}>, </Show>
            {child(arg, index)}
          </>
        )}
      </Index>
      )
    </span>
  );

  const COMPARISON_OPS = ['>', '<', '>=', '<=', '==', '!='];
  const NAMED_FUNCTION_OPS = ['exp', 'log', 'sin', 'cos', 'tan'];

  // Handle different operators with appropriate CSS layouts per Section 5.2.4
  return (
    <Switch
      fallback={
        // Generic function notation for unknown operators
        <span class="esm-generic-function" data-operator={op()}>
          <span class="esm-function-name">{op()}</span>
          {functionArgs()}
        </span>
      }
    >
      <Match when={op() === '+' || op() === '-'}>
        <span class="esm-infix-op" data-operator={op()}>
          {infixArgs(() => <span class="esm-operator"> {op()} </span>)}
        </span>
      </Match>

      <Match when={op() === '*'}>
        <span class="esm-multiplication" data-operator={op()}>
          {infixArgs(() => <span class="esm-multiply">⋅</span>)}
        </span>
      </Match>

      <Match when={op() === '/'}>
        <Fraction
          numerator={child(() => args()[0], 0)}
          denominator={child(() => args()[1], 1)}
        />
      </Match>

      <Match when={op() === '^'}>
        <Superscript
          base={child(() => args()[0], 0)}
          exponent={child(() => args()[1], 1)}
        />
      </Match>

      <Match when={op() === 'sqrt'}>
        <Radical class="esm-sqrt" content={child(() => args()[0], 0)} />
      </Match>

      <Match when={op() === 'D'}>
        <span class="esm-derivative" data-operator={op()}>
          <span class="esm-d-operator">d</span>
          <span class="esm-derivative-body">
            {child(() => args()[0], 0)}
          </span>
          <Show when={(props.node as { wrt?: string }).wrt}>
            <span class="esm-derivative-wrt">
              <span class="esm-d-operator">d</span>
              <span class="esm-variable">{(props.node as { wrt?: string }).wrt}</span>
            </span>
          </Show>
        </span>
      </Match>

      <Match when={NAMED_FUNCTION_OPS.includes(op())}>
        <span class="esm-function" data-operator={op()}>
          <span class="esm-function-name">{op()}</span>
          {functionArgs()}
        </span>
      </Match>

      <Match when={COMPARISON_OPS.includes(op())}>
        <span class="esm-comparison" data-operator={op()}>
          {infixArgs(() => <span class="esm-operator"> {op()} </span>)}
        </span>
      </Match>
    </Switch>
  );
}

/**
 * Core ExpressionNode component - recursive AST renderer
 */
export const ExpressionNode: Component<ExpressionNodeProps> = (props) => {
  const [isHovered, setIsHovered] = createSignal(false);
  const [showStructuralMenu, setShowStructuralMenu] = createSignal(false);
  const [menuPosition, setMenuPosition] = createSignal({ x: 0, y: 0 });
  const [showFieldEditor, setShowFieldEditor] = createSignal(false);

  // Structural editing context is optional (non-throwing accessor)
  const structuralEditing = useMaybeStructuralEditingContext();

  // Determine if this expression is a variable reference
  const isVariable = createMemo(() =>
    typeof props.expr === 'string' && !isNumericString(props.expr)
  );

  // Check if this variable should be highlighted
  const shouldHighlight = createMemo(() =>
    isVariable() && props.highlightedVars().has(props.expr as string)
  );

  // Check if this node is currently selected
  const isSelected = createMemo(() =>
    props.selectedPath != null &&
    props.selectedPath.length === props.path.length &&
    props.selectedPath.every((segment, i) => segment === props.path[i])
  );

  // Check if this can be dragged (is in a commutative operation with siblings)
  const canDrag = createMemo(() =>
    structuralEditing !== undefined &&
    props.parentPath !== undefined &&
    typeof props.indexInParent === 'number' &&
    props.parentPath.length > 0
  );

  // CSS classes for styling
  const nodeClasses = createMemo(() => {
    const classes = ['esm-expression-node'];

    if (isHovered()) classes.push('hovered');
    if (shouldHighlight()) classes.push('highlighted');
    if (isSelected()) classes.push('selected');
    if (isVariable()) classes.push('variable');
    if (typeof props.expr === 'number') classes.push('number');
    if (typeof props.expr === 'object') classes.push('operator');

    return classes.join(' ');
  });

  // Handle mouse events
  const handleMouseEnter = () => {
    setIsHovered(true);
    if (isVariable()) {
      props.onHoverVar(props.expr as string);
    }
  };

  const handleMouseLeave = () => {
    setIsHovered(false);
    if (isVariable()) {
      props.onHoverVar(null);
    }
  };

  const handleClick = (e: MouseEvent) => {
    e.stopPropagation();
    props.onSelect(props.path);
  };

  const handleContextMenu = (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();

    if (structuralEditing) {
      props.onSelect(props.path); // Select the node first
      setMenuPosition({ x: e.clientX, y: e.clientY });
      setShowStructuralMenu(true);
    }
  };

  const handleCloseMenu = () => {
    setShowStructuralMenu(false);
  };

  // Get ARIA label for accessibility
  const ariaLabel = (): string => {
    if (typeof props.expr === 'number') {
      return `Number: ${props.expr}`;
    }
    if (typeof props.expr === 'string') {
      return `Variable: ${props.expr}`;
    }
    if (typeof props.expr === 'object' && props.expr !== null && 'op' in props.expr) {
      return `Operator: ${(props.expr as ExprNode).op}`;
    }
    return 'Expression';
  };

  const isOperatorNode = () =>
    typeof props.expr === 'object' && props.expr !== null && 'op' in props.expr;

  // Op name when this node is an operator (empty otherwise).
  const opName = () => (isOperatorNode() ? (props.expr as ExprNode).op : '');

  // Whether this operator exposes editable non-`args` fields (e.g. D's `wrt`,
  // const's `value`, aggregate's reduce/semiring/…).
  const canEditFields = createMemo(() => isOperatorNode() && opHasFieldEditor(opName()));

  const openFieldEditor = (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    props.onSelect(props.path); // Select the node first
    setShowFieldEditor(true);
  };

  const content = (
    <>
      <span
        class={nodeClasses()}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
        onClick={handleClick}
        onContextMenu={handleContextMenu}
        tabIndex={0}
        role="button"
        aria-label={ariaLabel()}
        data-path={props.path.join('.')}
      >
        <Switch fallback={<span class="esm-unknown">?</span>}>
          <Match when={typeof props.expr === 'number'}>
            <span class="esm-num" title={`Number: ${props.expr}`}>
              {formatNumber(props.expr as number)}
            </span>
          </Match>

          <Match when={typeof props.expr === 'string'}>
            <span class="esm-var" title={`Variable: ${props.expr}`}>
              {renderChemicalName(props.expr as string)}
            </span>
          </Match>

          <Match when={isOperatorNode()}>
            <OperatorLayout
              node={props.expr as ExprNode}
              path={props.path}
              highlightedVars={props.highlightedVars}
              onHoverVar={props.onHoverVar}
              onSelect={props.onSelect}
              onReplace={props.onReplace}
              selectedPath={props.selectedPath}
            />
          </Match>
        </Switch>
      </span>

      <Show when={canEditFields() && (isSelected() || isHovered() || showFieldEditor())}>
        <button
          class="esm-edit-fields-btn"
          onClick={openFieldEditor}
          title={`Edit ${opName()} fields`}
          aria-label={`Edit fields of ${opName()}`}
        >
          ⚙
        </button>
      </Show>

      <Show when={showFieldEditor() && isOperatorNode()}>
        <NodeFieldEditor
          node={props.expr as ExprNode}
          path={props.path}
          onReplace={props.onReplace}
          onClose={() => setShowFieldEditor(false)}
        />
      </Show>

      <Show when={showStructuralMenu() && structuralEditing}>
        <StructuralEditingMenu
          selectedPath={props.path}
          selectedExpr={props.expr}
          isVisible={showStructuralMenu()}
          position={menuPosition()}
          onClose={handleCloseMenu}
        />
      </Show>
    </>
  );

  // Wrap in draggable component if this can be dragged
  return (
    <Show when={canDrag()} fallback={content}>
      <DraggableExpression
        path={props.path}
        index={props.indexInParent!}
        parentPath={props.parentPath!}
        canDrag={true}
      >
        {content}
      </DraggableExpression>
    </Show>
  );
};

// Helper functions
function isNumericString(str: string): boolean {
  return /^-?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(str);
}

function formatNumber(num: number): string {
  // Format number according to ESM spec Section 6.1
  if (num === 0) return '0';

  const absNum = Math.abs(num);

  // Use scientific notation for very small or large numbers
  if (absNum < 0.01 || absNum >= 10000) {
    const exp = num.toExponential();
    const [mantissa, exponent] = exp.split('e');

    // Convert to Unicode superscript notation
    const cleanMantissa = parseFloat(mantissa).toString(); // Remove trailing zeros
    const expNum = parseInt(exponent, 10);
    const superscriptExp = formatSuperscript(expNum);

    return `${cleanMantissa}×10${superscriptExp}`;
  }

  // For integers, show as plain integer
  if (Number.isInteger(num)) {
    return num.toString();
  }

  // For decimals, use standard notation
  return num.toString();
}

function formatSuperscript(exp: number): string {
  // Convert number to Unicode superscript
  const superscriptMap: { [key: string]: string } = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
    '-': '⁻', '+': '⁺'
  };

  return exp.toString().split('').map(char => superscriptMap[char] || char).join('');
}

export default ExpressionNode;
