/**
 * ESM Editor - Interactive SolidJS editor for EarthSciML expressions
 *
 * This package provides interactive editing components for ESM format expressions,
 * built on SolidJS with proper reactive state management and accessibility support.
 */

// Core components
export { ExpressionNode, type ExpressionNodeProps } from './components/ExpressionNode';
export { ExpressionPalette, type ExpressionPaletteProps } from './components/ExpressionPalette';

// Editor components
export { EquationEditor, type EquationEditorProps } from './components/EquationEditor';
export { ModelEditor, type ModelEditorProps } from './components/ModelEditor';
export { ReactionEditor, type ReactionEditorProps } from './components/ReactionEditor';
export { CouplingGraph, type CouplingGraphProps } from './components/CouplingGraph';
export { ValidationPanel, type ValidationPanelProps } from './components/ValidationPanel';
export { FileSummary, type FileSummaryProps } from './components/FileSummary';

// Mathematical layout components (Section 5.2.3)
export {
  Fraction,
  Superscript,
  Subscript,
  Radical,
  Delimiters,
  type FractionProps,
  type SuperscriptProps,
  type SubscriptProps,
  type RadicalProps,
  type DelimitersProps
} from './layout';

// Variable highlighting primitives
export {
  buildVarEquivalences,
  normalizeScopedReference,
  HighlightProvider,
  useHighlightContext,
  createHighlightContext,
  isHighlighted,
  type HighlightContextValue,
  type ScopingMode,
  type HighlightProviderProps
} from './primitives/highlighted-var';

// Selection and inline editing primitives
export {
  SelectionProvider,
  useSelectionContext,
  useMaybeSelectionContext,
  createSelectionContext,
  getVariableSuggestions,
  type SelectionContextValue,
  type SelectionProviderProps,
  type NodeDetails
} from './primitives/selection';

// Shared path utilities (single implementation used by all primitives)
export {
  getValueAtPath,
  getExpressionAtPath,
  replaceExpressionAtPath,
  pathsEqual,
  pathToString,
  stringToPath
} from './primitives/path-utils';

// Structural editing primitives
export {
  StructuralEditingProvider,
  useStructuralEditingContext,
  useMaybeStructuralEditingContext,
  StructuralEditingMenu,
  DraggableExpression,
  WRAP_OPERATORS,
  COMMUTATIVE_OPERATORS,
  type StructuralEditingContextValue,
  type StructuralEditingProviderProps,
  type StructuralEditingMenuProps,
  type DraggableExpressionProps,
  type DragState
} from './primitives/structural-editing';

// Undo/redo history management
export {
  createUndoHistory,
  createUndoKeyboardHandler,
  type UndoHistory,
  type UndoHistoryConfig,
  type HistoryEntry
} from './primitives/history';

// AST store for centralized state management
export {
  createAstStore,
  PathUtils,
  CommonPaths,
  type AstStore,
  type AstStoreConfig,
  type Path,
  type PathSegment
} from './primitives/ast-store';

// Validation primitives for reactive validation signals
export {
  createValidationSignals,
  createValidationContext,
  createDebouncedValidation,
  type ValidationSignals,
  type ValidationConfig,
  type ValidationErrorWithMetadata
} from './primitives/validation';

// Web components for framework integration
export {
  registerWebComponents,
  type EsmExpressionEditorProps,
  type EsmModelEditorProps,
  type EsmFileEditorProps,
  type EsmReactionEditorProps,
  type EsmCouplingGraphProps
} from './web-components';

// Re-export types from @earthsciml/ast for convenience
export type {
  Expression,
  ExpressionNode as ExprNode,
  ComponentNode,
  CouplingEdge,
  Graph,
  EsmFile,
  Model,
  ReactionSystem
} from '@earthsciml/ast';