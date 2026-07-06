/**
 * Selection and inline editing primitives for the esm-editor
 *
 * This module provides:
 * - Selection state management with selectedPath tracking
 * - Detail panel data when a node is selected
 * - Inline editing for numbers (double-click to input field)
 * - Inline editing for variables (double-click to autocomplete dropdown)
 * - onReplace callback integration for updating the store
 */

import { createSignal, createMemo, Accessor, Setter, createContext, useContext } from 'solid-js';
import type { Expression, ExpressionNode as ExprNode, EsmFile } from 'earthsci-toolkit';

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
 * Get expression at a given path
 */
function getExpressionAtPath(expr: Expression, path: (string | number)[]): Expression | null {
  let current: any = expr;

  for (const segment of path) {
    if (current == null) return null;

    if (segment === 'args' && typeof current === 'object' && 'args' in current) {
      // Move to the args array
      current = current.args;
    } else if (typeof segment === 'number' && Array.isArray(current)) {
      // Access array element by index
      current = current[segment];
    } else {
      // Invalid path segment for current context
      return null;
    }
  }

  return current;
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
 * Provider component for selection context
 */
export function SelectionProvider(props: SelectionProviderProps) {
  // Selection state
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);

  // Inline editing state
  const [isInlineEditing, setIsInlineEditing] = createSignal(false);
  const [inlineEditValue, setInlineEditValue] = createSignal('');

  // Check if a path is selected
  const isSelected = (path: (string | number)[]) => {
    const selected = selectedPath();
    if (!selected || selected.length !== path.length) return false;
    return selected.every((segment, i) => segment === path[i]);
  };

  // Get details for the selected node
  const selectedNodeDetails = createMemo((): NodeDetails | null => {
    const path = selectedPath();
    if (!path) return null;

    const rootExpr = props.rootExpression();
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

  // Handle node replacement
  const onReplace = (path: (string | number)[], newExpr: Expression) => {
    const rootExpr = props.rootExpression();
    const newRoot = replaceExpressionAtPath(rootExpr, path, newExpr);
    props.onRootReplace(newRoot);
  };

  // Start inline editing
  const startInlineEdit = () => {
    const details = selectedNodeDetails();
    if (!details) return;

    if (details.type === 'number') {
      setInlineEditValue(String(details.value));
      setIsInlineEditing(true);
    } else if (details.type === 'variable') {
      setInlineEditValue(String(details.value));
      setIsInlineEditing(true);
    }
  };

  // Cancel inline editing
  const cancelInlineEdit = () => {
    setIsInlineEditing(false);
    setInlineEditValue('');
  };

  // Confirm inline editing
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

  const contextValue: SelectionContextValue = {
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
 * Create selection context with default settings
 * Convenience function for simple use cases
 */
export function createSelectionContext(
  rootExpression: Accessor<Expression>,
  onRootReplace: (newExpr: Expression) => void
) {
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);
  const [isInlineEditing, setIsInlineEditing] = createSignal(false);
  const [inlineEditValue, setInlineEditValue] = createSignal('');

  const isSelected = (path: (string | number)[]) => {
    const selected = selectedPath();
    if (!selected || selected.length !== path.length) return false;
    return selected.every((segment, i) => segment === path[i]);
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

  return {
    selectedPath,
    setSelectedPath,
    isSelected,
    selectedNodeDetails,
    onReplace,
    startInlineEdit: () => {
      const details = selectedNodeDetails();
      if (!details) return;

      if (details.type === 'number') {
        setInlineEditValue(String(details.value));
        setIsInlineEditing(true);
      } else if (details.type === 'variable') {
        setInlineEditValue(String(details.value));
        setIsInlineEditing(true);
      }
    },
    cancelInlineEdit: () => {
      setIsInlineEditing(false);
      setInlineEditValue('');
    },
    confirmInlineEdit: (newValue: string) => {
      const path = selectedPath();
      const details = selectedNodeDetails();
      if (!path || !details) return;

      let newExpr: Expression;

      if (details.type === 'number') {
        const numValue = parseFloat(newValue);
        if (isNaN(numValue)) return;
        newExpr = numValue;
      } else if (details.type === 'variable') {
        if (!newValue.trim()) return;
        newExpr = newValue.trim();
      } else {
        return;
      }

      onReplace(path, newExpr);
      setIsInlineEditing(false);
      setInlineEditValue('');
    },
    isInlineEditing,
    inlineEditValue,
    setInlineEditValue
  };
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

// Helper functions for path comparison and manipulation
export function pathsEqual(path1: (string | number)[], path2: (string | number)[]): boolean {
  if (path1.length !== path2.length) return false;
  return path1.every((segment, i) => segment === path2[i]);
}

export function pathToString(path: (string | number)[]): string {
  return path.join('.');
}

export function stringToPath(pathStr: string): (string | number)[] {
  if (!pathStr) return [];
  return pathStr.split('.').map(segment => {
    const num = parseInt(segment, 10);
    return isNaN(num) ? segment : num;
  });
}