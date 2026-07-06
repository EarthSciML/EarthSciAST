/**
 * Selection and inline editing primitives for the esm-editor
 *
 * This module provides:
 * - Selection state management with selectedPath tracking
 * - Detail panel data when a node is selected
 * - Inline editing for numbers (double-click to input field)
 * - Inline editing for variables (double-click to autocomplete dropdown)
 * - onReplace callback integration for updating the store
 *
 * `createSelectionContext` is the single implementation; `SelectionProvider`
 * simply wraps it in a SolidJS context provider.
 */

import { createSignal, createMemo, Accessor, Setter, createContext, useContext } from 'solid-js';
import type { Expression, ExpressionNode as ExprNode, EsmFile } from 'earthsci-toolkit';
import { getExpressionAtPath, replaceExpressionAtPath, pathsEqual } from './path-utils';

export { pathsEqual, pathToString, stringToPath } from './path-utils';

// Types for selection context
export interface SelectionContextValue {
  /** Currently selected AST path */
  selectedPath: Accessor<(string | number)[] | null>;
  /** Set the currently selected AST path */
  setSelectedPath: Setter<(string | number)[] | null>;
  /** Check if a path is currently selected */
  isSelected: (path: (string | number)[]) => boolean;
  /** Get detail panel data for the selected node */
  selectedNodeDetails: Accessor<NodeDetails | null>;
  /** Callback when replacing a node with new expression */
  onReplace: (path: (string | number)[], newExpr: Expression) => void;
  /** Start inline editing for the selected node */
  startInlineEdit: () => void;
  /** Cancel inline editing */
  cancelInlineEdit: () => void;
  /** Confirm inline editing with new value */
  confirmInlineEdit: (newValue: string) => void;
  /** Check if inline editing is active */
  isInlineEditing: Accessor<boolean>;
  /** Get inline edit value */
  inlineEditValue: Accessor<string>;
  /** Set inline edit value */
  setInlineEditValue: Setter<string>;
}

// Node detail information for the detail panel
export interface NodeDetails {
  /** Type of the selected node */
  type: 'number' | 'variable' | 'operator';
  /** Current value/content */
  value: string | number;
  /** Parent context information */
  parentContext?: {
    /** Parent node type */
    type: 'operator' | 'root';
    /** Parent operator name (if applicable) */
    operator?: string;
    /** Position in parent's arguments */
    argIndex?: number;
  };
  /** Available actions for this node type */
  availableActions: string[];
  /** Path to this node in the AST */
  path: (string | number)[];
  /** Full expression being edited */
  expression: Expression;
}

// Selection context
const SelectionContext = createContext<SelectionContextValue>();

export interface SelectionProviderProps {
  children: any;
  /** Root expression being edited */
  rootExpression: Accessor<Expression>;
  /** Callback when the root expression is replaced */
  onRootReplace: (newExpr: Expression) => void;
  /** ESM file for variable suggestions */
  esmFile?: Accessor<EsmFile | null>;
}

/**
 * Get parent context information for a given path
 */
function getParentContext(expr: Expression, path: (string | number)[]): NodeDetails['parentContext'] {
  if (path.length === 0) {
    return { type: 'root' };
  }

  const parentPath = path.slice(0, -2); // Remove 'args' and index
  const argIndex = path[path.length - 1];

  if (typeof argIndex !== 'number') {
    return { type: 'root' };
  }

  const parent = getExpressionAtPath(expr, parentPath);
  if (parent && typeof parent === 'object' && 'op' in parent) {
    return {
      type: 'operator',
      operator: (parent as ExprNode).op,
      argIndex
    };
  }

  return { type: 'root' };
}

/**
 * Get available actions for a node based on its type
 */
function getAvailableActions(expr: Expression): string[] {
  const actions: string[] = [];

  if (typeof expr === 'number') {
    actions.push('Edit Value', 'Convert to Variable', 'Wrap in Operator');
  } else if (typeof expr === 'string') {
    actions.push('Edit Variable', 'Convert to Number', 'Wrap in Operator');
  } else if (typeof expr === 'object' && expr !== null && 'op' in expr) {
    actions.push('Change Operator', 'Add Argument', 'Remove Argument', 'Unwrap');
  }

  return actions;
}

/**
 * Extract all variable names from an ESM file
 */
function extractVariableNames(esmFile: EsmFile | null): string[] {
  if (!esmFile) return [];

  const variables = new Set<string>();

  // Extract from models (variables — including parameters — are keyed by name)
  if (esmFile.models) {
    for (const model of Object.values(esmFile.models)) {
      if ('ref' in model) continue; // Skip external subsystem references
      for (const name of Object.keys(model.variables || {})) {
        variables.add(name);
      }
    }
  }

  // Extract species and parameters from reaction systems
  if (esmFile.reaction_systems) {
    for (const system of Object.values(esmFile.reaction_systems)) {
      for (const name of Object.keys(system.species || {})) {
        variables.add(name);
      }
      for (const name of Object.keys(system.parameters || {})) {
        variables.add(name);
      }
    }
  }

  return Array.from(variables).sort();
}

/**
 * Create selection context state and actions.
 *
 * This is the single implementation of selection + inline editing;
 * `SelectionProvider` delegates to it.
 */
export function createSelectionContext(
  rootExpression: Accessor<Expression>,
  onRootReplace: (newExpr: Expression) => void
): SelectionContextValue {
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);
  const [isInlineEditing, setIsInlineEditing] = createSignal(false);
  const [inlineEditValue, setInlineEditValue] = createSignal('');

  const isSelected = (path: (string | number)[]) => {
    const selected = selectedPath();
    if (!selected) return false;
    return pathsEqual(selected, path);
  };

  const selectedNodeDetails = createMemo((): NodeDetails | null => {
    const path = selectedPath();
    if (!path) return null;

    const rootExpr = rootExpression();
    const expression = getExpressionAtPath(rootExpr, path);
    if (!expression) return null;

    const type = typeof expression === 'number' ? 'number' :
                 typeof expression === 'string' ? 'variable' : 'operator';

    const value = typeof expression === 'object' && 'op' in expression
      ? (expression as ExprNode).op
      : expression;

    return {
      type,
      value: (value as string | number),
      parentContext: getParentContext(rootExpr, path),
      availableActions: getAvailableActions(expression),
      path: [...path],
      expression
    };
  });

  const onReplace = (path: (string | number)[], newExpr: Expression) => {
    const rootExpr = rootExpression();
    const newRoot = replaceExpressionAtPath(rootExpr, path, newExpr);
    onRootReplace(newRoot);
  };

  const startInlineEdit = () => {
    const details = selectedNodeDetails();
    if (!details) return;

    if (details.type === 'number' || details.type === 'variable') {
      setInlineEditValue(String(details.value));
      setIsInlineEditing(true);
    }
  };

  const cancelInlineEdit = () => {
    setIsInlineEditing(false);
    setInlineEditValue('');
  };

  const confirmInlineEdit = (newValue: string) => {
    const path = selectedPath();
    const details = selectedNodeDetails();
    if (!path || !details) return;

    let newExpr: Expression;

    if (details.type === 'number') {
      const numValue = parseFloat(newValue);
      if (isNaN(numValue)) return; // Invalid number
      newExpr = numValue;
    } else if (details.type === 'variable') {
      if (!newValue.trim()) return; // Empty variable name
      newExpr = newValue.trim();
    } else {
      return; // Can't inline edit operators
    }

    onReplace(path, newExpr);
    cancelInlineEdit();
  };

  return {
    selectedPath,
    setSelectedPath,
    isSelected,
    selectedNodeDetails,
    onReplace,
    startInlineEdit,
    cancelInlineEdit,
    confirmInlineEdit,
    isInlineEditing,
    inlineEditValue,
    setInlineEditValue
  };
}

/**
 * Provider component for selection context.
 * Delegates all state management to `createSelectionContext`.
 */
export function SelectionProvider(props: SelectionProviderProps) {
  const contextValue = createSelectionContext(
    () => props.rootExpression(),
    (newExpr) => props.onRootReplace(newExpr)
  );

  return (
    <SelectionContext.Provider value={contextValue}>
      {props.children}
    </SelectionContext.Provider>
  );
}

/**
 * Hook to access the selection context
 */
export function useSelectionContext(): SelectionContextValue {
  const context = useContext(SelectionContext);
  if (!context) {
    throw new Error('useSelectionContext must be used within a SelectionProvider');
  }
  return context;
}

/**
 * Non-throwing variant of `useSelectionContext` for components that work
 * with or without a surrounding provider.
 */
export function useMaybeSelectionContext(): SelectionContextValue | undefined {
  return useContext(SelectionContext);
}

/**
 * Get variable suggestions for autocomplete
 */
export function getVariableSuggestions(
  esmFile: EsmFile | null,
  searchTerm: string = ''
): string[] {
  const allVars = extractVariableNames(esmFile);

  if (!searchTerm) return allVars;

  const lowerTerm = searchTerm.toLowerCase();
  return allVars.filter(variable =>
    variable.toLowerCase().includes(lowerTerm)
  );
}
