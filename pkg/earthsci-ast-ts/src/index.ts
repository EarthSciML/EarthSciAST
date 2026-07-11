/**
 * ESM Format TypeScript Package
 *
 * Entry point for the @earthsciml/ast package, providing complete TypeScript
 * type definitions for the EarthSciML Serialization Format.
 *
 * @example
 * ```typescript
 * import { EsmFile, Model, Expr } from '@earthsciml/ast';
 *
 * const myModel: Model = {
 *   name: "atmospheric_chemistry",
 *   variables: [],
 *   equations: []
 * };
 * ```
 */

// Intentional full wildcard re-export of the schema type-definition barrel
// (generated schema types plus augmentations — dozens of type aliases). Kept as
// `export *` on purpose: enumerating every generated type by name is fragile and
// churns with the schema, and this module owns only type definitions.
export * from './types.js'

// Export parsing and serialization functions
export { load, validateSchema, ParseError, SchemaValidationError } from './parse.js'
export type { SchemaError, LoadOptions } from './parse.js'
export { save } from './serialize.js'
export type { SaveOptions } from './serialize.js'
export { validate } from './validate.js'
export type { ValidationError, ValidationResult } from './validate.js'

// Export graph utilities
export {
  component_graph,
  componentGraph,
  expressionGraph,
  componentExists,
  getComponentType,
  toDot,
  toMermaid,
  toJsonGraph,
} from './graph.js'
export type {
  ComponentGraph,
  ComponentNode,
  CouplingEdge,
  Graph,
  VariableNode,
  DependencyEdge,
} from './graph.js'

// Export advanced expression analysis and manipulation.
// Explicit named re-export of the full public surface of ./analysis/index.js
// (formerly `export *`); every symbol that module exports is enumerated here.
export {
  // Dependency graph analysis
  buildDependencyGraph,
  findDeadVariables,
  findDependencyChains,
  // Complexity analysis
  analyzeComplexity,
  compareComplexity,
  classifyComplexity,
  findExpensiveSubexpressions,
  estimateParallelPotential,
  detectStabilityIssues,
  // Common subexpression identification
  findCommonSubexpressions,
  findCommonSubexpressionsAcrossExpressions,
  findCommonSubexpressionsInModel,
  findCommonSubexpressionsInEsmFile,
  estimateSavings,
  generateFactoredVariableNames,
  groupSubexpressionsByType,
  DEFAULT_MIN_COMPLEXITY,
  // Symbolic differentiation
  differentiate,
  partialDerivatives,
  gradient,
  higherOrderDerivative,
  isDifferentiable,
  findCriticalPoints,
  NonDifferentiableExpressionError,
  InvalidDerivativeOrderError,
  // Combined expression-analysis entry point
  analyzeExpression,
  ExpressionAnalyzer,
} from './analysis/index.js'
export type {
  // Analysis-owned types
  DependencyNode,
  DependencyRelation,
  DependencyGraph,
  VariableKind,
  ComplexityMetrics,
  StabilityIssue,
  CommonSubexpression,
  ExpressionLocation,
  DerivativeResult,
  // Combined-analysis option/result shapes
  AnalysisResults,
  AnalysisOptions,
} from './analysis/index.js'

// Export pretty-printing utilities
export { toUnicode, toLatex, toAscii, toMathML, formatChemicalName } from './pretty-print.js'

// Export substitution utilities
export { substitute, substituteInModel, substituteInReactionSystem } from './substitute.js'

// Export immutable editing operations.
// Explicit named re-export of the full public surface of ./edit.js (formerly
// `export *`). edit.js also re-exports `deriveODEs` from reactions.js, but that
// symbol is already exported from reactions.js above, so it is intentionally
// not re-listed here to avoid a duplicate re-export.
export {
  // Typed errors
  VariableInUseError,
  EntityNotFoundError,
  // Variable operations
  addVariable,
  removeVariable,
  renameVariable,
  // Equation operations
  addEquation,
  removeEquation,
  substituteInEquations,
  // Reaction operations
  addReaction,
  removeReaction,
  addSpecies,
  removeSpecies,
  // Event operations
  addContinuousEvent,
  addDiscreteEvent,
  removeEvent,
  // Coupling operations
  addCoupling,
  removeCoupling,
  compose,
  mapVariable,
  // File-level operations
  merge,
  extract,
} from './edit.js'

// Export expression structural operations
export { freeVariables, freeParameters, contains, simplify } from './expression.js'

// Export reaction system ODE derivation and stoichiometric matrix computation
export { deriveODEs, stoichiometricMatrix, substrateMatrix, productMatrix } from './reactions.js'

// Export unit parsing and dimensional analysis
export { parseUnit, checkDimensions, validateUnits } from './units.js'
export type { UnitResult, UnitWarning } from './units.js'

// Export runtime unit conversion
export {
  convertUnits,
  parseUnitForConversion,
  unitsCompatible,
  UnitConversionError,
} from './unit-conversion.js'
export type { CanonicalDims, ParsedUnit } from './unit-conversion.js'

// Export the tree-walking scalar evaluator (esm-spec closed-core semantics).
export {
  compileExpression,
  evaluateExpression,
  UnloweredOperatorError,
  EvaluatorError,
} from './codegen.js'
export type { CompiledExpression } from './codegen.js'

// Export migration functionality
export { migrate, canMigrate, getSupportedMigrationTargets, MigrationError } from './migration.js'

// Interactive editor components and web components live in the earthsci-ast-editor
// package.

// Coupled system flattening
export { flatten } from './flatten.js'
export type {
  FlattenedEquation,
  FlattenMetadata,
  FlattenedSystem,
  FlattenOptions,
} from './flatten.js'

// Coupling-library files and coupling_import role binding (esm-spec §10.9–§10.11)
export { expandCouplingImports, isCouplingLibraryDoc } from './coupling-imports.js'
export type { CouplingImportOptions } from './coupling-imports.js'

// Subsystem reference loading
export {
  resolveSubsystemRefs,
  ephemeralInjectedFile,
  CircularReferenceError,
  RefLoadError,
} from './ref-loading.js'

// Canonical AST form (RFC §5.4). TS lacks native int/float distinction;
// see canonicalize.ts for the gt-ca2u limitation note.
export {
  canonicalize,
  canonicalJson,
  formatCanonicalFloat,
  CanonicalizeError,
  E_CANONICAL_NONFINITE,
  E_CANONICAL_DIVBY_ZERO,
} from './canonicalize.js'

// Closed function registry (esm-spec §9.2 / RFC closed-function-registry).
export {
  CLOSED_FUNCTION_NAMES,
  ClosedFunctionError,
  dispatchClosedFunction,
  searchsortedFirst,
  validateSearchsortedTable,
  interpLinear,
  interpBilinear,
  validateInterpAxis,
} from './closed-functions.js'
export type { ClosedFunctionErrorCode } from './closed-functions.js'

// Load-time enum lowering (esm-spec §9.3).
export { lowerEnums, EnumLoweringError } from './lower-enums.js'

// Load-time expression-template expansion (esm-spec §9.6,
// docs/rfcs/ast-expression-templates.md).
export {
  lowerExpressionTemplates,
  rejectExpressionTemplatesPreV04,
  // Shared load-time machinery diagnostic (templates / imports / coupling / refs).
  EsmMachineryError,
  // @deprecated Same-class alias for `EsmMachineryError`; kept for external consumers.
  ExpressionTemplateError,
  MAX_TEMPLATE_EXPANSION_DEPTH,
} from './lower-expression-templates.js'

// Template-library imports + load-time metaparameters (esm-spec §9.7 /
// docs/content/rfcs/template-library-imports.md).
export {
  resolveTemplateMachinery,
  rejectTemplateImportsPreV08,
  isTemplateLibraryDoc,
  applyScopeInjections,
} from './template-imports.js'
export type { TemplateResolveOptions, TemplateSchemaError } from './template-imports.js'

// Package metadata. Both constants track the embedded schema's version
// (derived from its $id in parse.ts); package.json is kept in lockstep.
export { SCHEMA_VERSION, SCHEMA_VERSION as VERSION } from './parse.js'
