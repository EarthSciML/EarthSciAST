/**
 * Structural editing operations for the esm-editor
 *
 * This module provides structural editing capabilities:
 * - Replace: select a node, replace it entirely with new expression
 * - Wrap: select a node, wrap it in a chosen operator
 * - Unwrap: replace unary operation with its argument
 * - Delete term: remove argument from commutative operations
 * - Reorder: drag-and-drop reordering for commutative operations
 */

import { createSignal, Accessor, Setter, createContext, useContext, JSX } from 'solid-js';
import type { Expression, ExpressionNode as ExprNode } from 'earthsci-toolkit';

// Common operators available for wrapping
export const WRAP_OPERATORS = [
  { op: '-', label: 'Negate', arity: 1 },
  { op: 'abs', label: 'Absolute Value', arity: 1 },
  { op: 'sqrt', label: 'Square Root', arity: 1 },
  { op: 'exp', label: 'Exponential', arity: 1 },
  { op: 'log', label: 'Natural Log', arity: 1 },
  { op: 'sin', label: 'Sine', arity: 1 },
  { op: 'cos', label: 'Cosine', arity: 1 },
  { op: '+', label: 'Addition', arity: 2 },
  { op: '*', label: 'Multiplication', arity: 2 },
  { op: '/', label: 'Division', arity: 2 },
  { op: '^', label: 'Power', arity: 2 }
] as const;

// Commutative operators that support reordering
export const COMMUTATIVE_OPERATORS = new Set(['+', '*']);

// Types for structural editing
export interface StructuralEditingContextValue {
  /** Replace the selected node with a new expression */
  replaceNode: (path: (string | number)[], newExpr: Expression) => void;

  /** Wrap the selected node in an operator */
  wrapNode: (path: (string | number)[], operator: string) => void;

  /** Unwrap a unary operation (replace with its argument) */
  unwrapNode: (path: (string | number)[]) => boolean;

  /** Delete a term from a commutative operation */
  deleteTerm: (path: (string | number)[]) => boolean;

  /** Reorder arguments in a commutative operation */
  reorderArgs: (path: (string | number)[], fromIndex: number, toIndex: number) => boolean;

  /** Check if an operation can be unwrapped */
  canUnwrap: (expr: Expression) => boolean;

  /** Check if a term can be deleted */
  canDeleteTerm: (expr: Expression, path: (string | number)[]) => boolean;

  /** Check if arguments can be reordered */
  canReorderArgs: (expr: Expression) => boolean;

  /** Get available wrap operations for current selection */
  getWrapOperators: () => typeof WRAP_OPERATORS[number][];

  /** Drag and drop state */
  dragState: Accessor<DragState>;
  setDragState: Setter<DragState>;
}

export interface DragState {
  isDragging: boolean;
  dragPath: (string | number)[] | null;
  dragIndex: number | null;
  dropTarget: { path: (string | number)[], index: number } | null;
}

// Context for structural editing
const StructuralEditingContext = createContext<StructuralEditingContextValue>();

export interface StructuralEditingProviderProps {
  children: any;
  /** Root expression being edited */
  rootExpression: Accessor<Expression>;
  /** Callback when the root expression is replaced */
  onRootReplace: (newExpr: Expression) => void;
}

/**
 * Check if an expression is a unary operation that can be unwrapped
 */
function isUnwrappableUnaryOp(expr: Expression): expr is ExprNode {
  return (
    typeof expr === 'object' &&
    expr !== null &&
    'op' in expr &&
    'args' in expr &&
    Array.isArray(expr.args) &&
    expr.args.length === 1
  );
}

/**
 * Check if an expression is a commutative operation
 */
function isCommutativeOp(expr: Expression): expr is ExprNode {
  return (
    typeof expr === 'object' &&
    expr !== null &&
    'op' in expr &&
    COMMUTATIVE_OPERATORS.has((expr as ExprNode).op)
  );
}

/**
 * Get expression at a given path
 */
function getExpressionAtPath(expr: Expression, path: (string | number)[]): Expression | null {
  let current: any = expr;

  for (const segment of path) {
    if (current == null) return null;

    if (segment === 'args' && typeof current === 'object' && 'args' in current) {
      current = current.args;
    } else if (typeof segment === 'number' && Array.isArray(current)) {
      current = current[segment];
    } else {
      return null;
    }
  }

  return current;
}

/**
 * Get parent expression and context for a given path
 */
function getParentInfo(
  rootExpr: Expression,
  path: (string | number)[]
): { parent: Expression | null; parentPath: (string | number)[]; argIndex: number | null } {
  if (path.length < 2) {
    return { parent: null, parentPath: [], argIndex: null };
  }

  const parentPath = path.slice(0, -2); // Remove 'args' and index
  const argIndex = path[path.length - 1];

  const parent = getExpressionAtPath(rootExpr, parentPath);

  return {
    parent,
    parentPath,
    argIndex: typeof argIndex === 'number' ? argIndex : null
  };
}

/**
 * Replace expression at a given path with a new expression
 */
function replaceExpressionAtPath(
  rootExpr: Expression,
  path: (string | number)[],
  newExpr: Expression
): Expression {
  if (path.length === 0) {
    return newExpr;
  }

  // Make a deep copy of the root expression
  let newRoot = JSON.parse(JSON.stringify(rootExpr));
  let current: any = newRoot;

  // Navigate to the parent of the target
  for (let i = 0; i < path.length - 1; i++) {
    const segment = path[i];
    if (segment === 'args' && typeof current === 'object' && 'args' in current) {
      current = current.args;
    } else if (typeof segment === 'number' && Array.isArray(current)) {
      current = current[segment];
    } else {
      throw new Error(`Invalid path segment: ${segment}`);
    }
  }

  // Replace at the final segment
  const lastSegment = path[path.length - 1];
  if (typeof lastSegment === 'number' && Array.isArray(current)) {
    current[lastSegment] = newExpr;
  } else {
    throw new Error(`Invalid final path segment: ${lastSegment}`);
  }

  return newRoot;
}

/**
 * Provider component for structural editing context
 */
export function StructuralEditingProvider(props: StructuralEditingProviderProps) {
  const [dragState, setDragState] = createSignal<DragState>({
    isDragging: false,
    dragPath: null,
    dragIndex: null,
    dropTarget: null
  });

  // Replace node operation
  const replaceNode = (path: (string | number)[], newExpr: Expression) => {
    const rootExpr = props.rootExpression();
    const newRoot = replaceExpressionAtPath(rootExpr, path, newExpr);
    props.onRootReplace(newRoot);
  };

  // Wrap node operation
  const wrapNode = (path: (string | number)[], operator: string) => {
    const rootExpr = props.rootExpression();
    const currentExpr = getExpressionAtPath(rootExpr, path);
    if (!currentExpr) return;

    const wrappedExpr: ExprNode = {
      op: operator,
      args: [currentExpr]
    };

    const newRoot = replaceExpressionAtPath(rootExpr, path, wrappedExpr);
    props.onRootReplace(newRoot);
  };

  // Unwrap node operation
  const unwrapNode = (path: (string | number)[]): boolean => {
    const rootExpr = props.rootExpression();
    const expr = getExpressionAtPath(rootExpr, path);

    if (expr === null || !isUnwrappableUnaryOp(expr)) {
      return false;
    }

    const unwrappedExpr = expr.args[0];
    const newRoot = replaceExpressionAtPath(rootExpr, path, unwrappedExpr);
    props.onRootReplace(newRoot);
    return true;
  };

  // Delete term operation
  const deleteTerm = (path: (string | number)[]): boolean => {
    const rootExpr = props.rootExpression();
    const { parent, parentPath, argIndex } = getParentInfo(rootExpr, path);

    if (!parent || !isCommutativeOp(parent) || argIndex === null) {
      return false;
    }

    const parentNode = parent as ExprNode;
    if (parentNode.args.length <= 2) {
      // If only 2 args, remove the parent and keep the other arg
      const remainingArg = parentNode.args[1 - argIndex];
      const newRoot = replaceExpressionAtPath(rootExpr, parentPath, remainingArg);
      props.onRootReplace(newRoot);
    } else {
      // Remove this arg from the parent
      const newArgs = [...parentNode.args];
      newArgs.splice(argIndex, 1);
      const newParent: ExprNode = { ...parentNode, args: newArgs };
      const newRoot = replaceExpressionAtPath(rootExpr, parentPath, newParent);
      props.onRootReplace(newRoot);
    }

    return true;
  };

  // Reorder arguments operation
  const reorderArgs = (path: (string | number)[], fromIndex: number, toIndex: number): boolean => {
    const rootExpr = props.rootExpression();
    const expr = getExpressionAtPath(rootExpr, path);

    if (expr === null || !isCommutativeOp(expr)) {
      return false;
    }

    const exprNode = expr as ExprNode;
    const newArgs = [...exprNode.args];

    // Move the element from fromIndex to toIndex
    const [moved] = newArgs.splice(fromIndex, 1);
    newArgs.splice(toIndex, 0, moved);

    const newExpr: ExprNode = { ...exprNode, args: newArgs };
    const newRoot = replaceExpressionAtPath(rootExpr, path, newExpr);
    props.onRootReplace(newRoot);
    return true;
  };

  // Check if expression can be unwrapped
  const canUnwrap = (expr: Expression): boolean => {
    return isUnwrappableUnaryOp(expr);
  };

  // Check if term can be deleted
  const canDeleteTerm = (_expr: Expression, path: (string | number)[]): boolean => {
    const rootExpr = props.rootExpression();
    const { parent } = getParentInfo(rootExpr, path);
    return parent !== null && isCommutativeOp(parent);
  };

  // Check if arguments can be reordered
  const canReorderArgs = (expr: Expression): boolean => {
    return isCommutativeOp(expr) && (expr as ExprNode).args.length > 1;
  };

  // Get available wrap operators
  const getWrapOperators = () => {
    return [...WRAP_OPERATORS];
  };

  const contextValue: StructuralEditingContextValue = {
    replaceNode,
    wrapNode,
    unwrapNode,
    deleteTerm,
    reorderArgs,
    canUnwrap,
    canDeleteTerm,
    canReorderArgs,
    getWrapOperators,
    dragState,
    setDragState
  };

  return (
    <StructuralEditingContext.Provider value={contextValue}>
      {props.children}
    </StructuralEditingContext.Provider>
  );
}

/**
 * Hook to access the structural editing context
 */
export function useStructuralEditingContext(): StructuralEditingContextValue {
  const context = useContext(StructuralEditingContext);
  if (!context) {
    throw new Error('useStructuralEditingContext must be used within a StructuralEditingProvider');
  }
  return context;
}

/**
 * Component for structural editing menu
 */
export interface StructuralEditingMenuProps {
  /** Currently selected path */
  selectedPath: (string | number)[] | null;
  /** Currently selected expression */
  selectedExpr: Expression | null;
  /** Show/hide the menu */
  isVisible: boolean;
  /** Position for the menu */
  position?: { x: number; y: number };
  /** Callback when menu is closed */
  onClose: () => void;
}

export function StructuralEditingMenu(props: StructuralEditingMenuProps) {
  const structuralEditing = useStructuralEditingContext();

  if (!props.isVisible || !props.selectedPath || !props.selectedExpr) {
    return null;
  }

  const handleWrapClick = (operator: string) => {
    if (props.selectedPath) {
      structuralEditing.wrapNode(props.selectedPath, operator);
      props.onClose();
    }
  };

  const handleUnwrapClick = () => {
    if (props.selectedPath && structuralEditing.unwrapNode(props.selectedPath)) {
      props.onClose();
    }
  };

  const handleDeleteClick = () => {
    if (props.selectedPath && structuralEditing.deleteTerm(props.selectedPath)) {
      props.onClose();
    }
  };

  const canUnwrap = structuralEditing.canUnwrap(props.selectedExpr);
  const canDelete = props.selectedPath && structuralEditing.canDeleteTerm(props.selectedExpr, props.selectedPath);

  return (
    <div
      class="structural-editing-menu"
      style={{
        position: 'absolute',
        left: `${props.position?.x || 0}px`,
        top: `${props.position?.y || 0}px`,
        'background-color': 'white',
        border: '1px solid #ccc',
        'border-radius': '4px',
        padding: '8px',
        'box-shadow': '0 2px 8px rgba(0,0,0,0.1)',
        'z-index': 1000,
        'min-width': '200px'
      }}
    >
      <div class="menu-section">
        <h4 class="menu-header">Wrap in Operator</h4>
        <div class="wrap-operators">
          {structuralEditing.getWrapOperators().map((op) => (
            <button
              class="wrap-operator-btn"
              onClick={() => handleWrapClick(op.op)}
              title={op.label}
            >
              {op.label}
            </button>
          ))}
        </div>
      </div>

      {canUnwrap && (
        <div class="menu-section">
          <button
            class="unwrap-btn"
            onClick={handleUnwrapClick}
            title="Remove the outer operator and keep its argument"
          >
            Unwrap
          </button>
        </div>
      )}

      {canDelete && (
        <div class="menu-section">
          <button
            class="delete-term-btn"
            onClick={handleDeleteClick}
            title="Remove this term from the operation"
          >
            Delete Term
          </button>
        </div>
      )}

      <div class="menu-section">
        <button class="close-menu-btn" onClick={props.onClose}>
          Close
        </button>
      </div>
    </div>
  );
}

/**
 * Draggable wrapper component for expression nodes in commutative operations
 */
export interface DraggableExpressionProps {
  children: JSX.Element;
  path: (string | number)[];
  index: number;
  parentPath: (string | number)[];
  canDrag: boolean;
}

export function DraggableExpression(props: DraggableExpressionProps) {
  const structuralEditing = useStructuralEditingContext();

  if (!props.canDrag) {
    return props.children;
  }

  const handleDragStart = (e: DragEvent) => {
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', JSON.stringify({
        path: props.path,
        index: props.index,
        parentPath: props.parentPath
      }));
    }

    structuralEditing.setDragState({
      isDragging: true,
      dragPath: props.path,
      dragIndex: props.index,
      dropTarget: null
    });
  };

  const handleDragEnd = () => {
    structuralEditing.setDragState({
      isDragging: false,
      dragPath: null,
      dragIndex: null,
      dropTarget: null
    });
  };

  const handleDragOver = (e: DragEvent) => {
    e.preventDefault();
    if (e.dataTransfer) {
      e.dataTransfer.dropEffect = 'move';
    }

    const dragState = structuralEditing.dragState();
    if (dragState.isDragging && dragState.dragIndex !== props.index) {
      structuralEditing.setDragState({
        ...dragState,
        dropTarget: { path: props.parentPath, index: props.index }
      });
    }
  };

  const handleDrop = (e: DragEvent) => {
    e.preventDefault();

    const data = e.dataTransfer?.getData('text/plain');
    if (!data) return;

    try {
      const dragInfo = JSON.parse(data);
      if (dragInfo.index !== props.index && dragInfo.parentPath.join('.') === props.parentPath.join('.')) {
        structuralEditing.reorderArgs(props.parentPath, dragInfo.index, props.index);
      }
    } catch (error) {
      console.error('Failed to parse drag data:', error);
    }
  };

  return (
    <div
      class="draggable-expression"
      draggable={true}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
      data-drag-index={props.index}
    >
      {props.children}
    </div>
  );
}