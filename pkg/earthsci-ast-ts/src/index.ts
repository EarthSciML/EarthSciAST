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

// Export the root of the diagnostic hierarchy and the central code registry.
// Every error class this package throws extends `EsmDiagnosticError` (finding
// H-1), so a consumer can bracket a whole pipeline with one clause:
//
//   try { loadString(text) } catch (e) {
//     if (e instanceof EsmDiagnosticError) console.error(e.code, e.message)
//   }
//
// `ERROR_CODES` is the registry of the stable `code` strings those errors
// carry — a cross-binding contract shared with the Julia `ERROR_CODES`
// registry, Python's `ErrorCode` enum, Go's `codes.go` and Rust's
// `diagnostic::codes` (finding H-2).
export { EsmDiagnosticError, ERROR_CODES } from './errors.js'
export type { ErrorCode } from './errors.js'

// Export parsing and serialization functions.
//
// `load` used to take `string | object` and mean JSON TEXT for a string —
// while the same call in Julia and Go meant a FILE PATH, and Python sniffed.
// One name, one argument type, opposite meanings, no type error anywhere.
// It is replaced by three entry points that say which they are.
export {
  loadPath,
  loadString,
  loadDocument,
  validateSchema,
  ParseError,
  SchemaValidationError,
} from './parse.js'
export type { SchemaError, LoadOptions } from './parse.js'
// `save` returned a string here and wrote to disk in Julia. Split: `toJson`
// is pure, `writePath` writes and returns nothing.
export { toJson, toJsonCompact, writePath } from './serialize.js'
export type { ToJsonOptions } from './serialize.js'
export { validate } from './validate.js'
export type { ValidationError, ValidationResult } from './validate.js'

// The esm 1.0.0 classification API (esm-spec §6.3.1). Two variable types are
// declared; everything a solver needs beyond that is DERIVED by these. Spelled
// camelCase here and snake_case in the other bindings.
export {
  odeStates,
  observedUnknowns,
  algebraicUnknowns,
  isOdeState,
  brownianParameters,
  discreteParameters,
  sampledParameters,
  constantParameters,
  systemKind,
  declaredSystemKind,
  parameterClass,
  updateRules,
  classifyModel,
  classifyDocument,
  unknowns,
  parameters,
} from './classification.js'
export type {
  ParameterClass,
  UnknownClass,
  SystemKind,
  ModelClassification,
} from './classification.js'
export { observedDefinitions } from './classification.js'

// Cadence-class leaf seeding (CONFORMANCE_SPEC §5.7.2). Seeds FROM the
// classification API above rather than re-deriving the categories locally.
export {
  CadenceSeeder,
  CadenceCycleError,
  joinCadence,
  joinAll,
  leafCadence,
  expressionCadence,
} from './cadence.js'
export type { CadenceClass } from './cadence.js'

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

// Export the expression text-form parser (inverse of toAscii for the scalar tier)
export { parseExpression, parseEquation, ExpressionParseError } from './parse-expression.js'

// Export the reaction text-form parser (inverse of toAscii for a single reaction)
export { parseReaction } from './parse-reaction.js'

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
export { parseUnit, tryParseUnit, checkDimensions, validateUnits } from './units.js'
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

// Coupled system flattening (esm-libraries-spec §4.7.5)
export {
  flatten,
  // The flatten error family, spelled as every other binding spells it
  // (§4.7.6's taxonomy) so a caller catching by name behaves uniformly.
  FlattenError,
  ConflictingDerivativeError,
  DomainUnitMismatchError,
  DimensionPromotionError,
} from './flatten.js'
export type {
  FlattenedEquation,
  FlattenMetadata,
  FlattenedSystem,
  FlattenOptions,
  // The canonical step-4 payload types: an ordered `name -> variable` map
  // carrying full per-variable metadata, a provider-served loaded field, and a
  // deferred `ic` (esm-spec §11.4.1).
  FlattenedVariable,
  FlattenedVariableRole,
  FlattenedVariableMap,
  FieldInitialCondition,
  LoaderField,
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
  // Out-of-line expression templates (Option B, esm-spec §9.6.4):
  // full expansion (`Expand`), reference-preserving emit, and flatten merge.
  expandDocument,
  Expand,
  buildEmittedDocument,
  authoredTemplateNames,
  emitEsmString,
  flattenTemplateRegistries,
} from './lower-expression-templates.js'
export type { FlattenedTemplateRegistries } from './lower-expression-templates.js'

// Template-library imports + load-time metaparameters (esm-spec §9.7 /
// docs/content/rfcs/template-library-imports.md).
export {
  resolveTemplateMachinery,
  rejectTemplateImportsPreV08,
  isTemplateLibraryDoc,
  applyScopeInjections,
  // Reference-preserving emit orchestration (esm-spec §9.6.4 rule 5).
  emitDocument,
} from './template-imports.js'
export type { TemplateResolveOptions, TemplateSchemaError } from './template-imports.js'

// Package metadata — two DIFFERENT numbers, and they used to share a name.
// `SCHEMA_VERSION` is the `.esm` format version this build implements,
// derived from the embedded schema's `$id` in parse.ts. `LIBRARY_VERSION` is
// this npm package's own version. `VERSION` (which aliased the schema
// version here and the package version in Rust) is gone.
export { SCHEMA_VERSION } from './parse.js'
export { LIBRARY_VERSION } from './version.js'
