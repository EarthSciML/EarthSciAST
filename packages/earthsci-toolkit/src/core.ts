/**
 * earthsci-toolkit core entry point
 *
 * Non-JSX exports for bundled npm distribution. The top-level `index.ts`
 * additionally re-exports `web-components.ts`, which pulls in SolidJS `.tsx`
 * files and cannot be safely bundled as plain JS. Rollup uses this file as
 * its input so the published ESM/CJS bundles stay JSX-free.
 */

export * from './types.js'

export { load, validateSchema, ParseError, SchemaValidationError } from './parse.js'
export type { SchemaError } from './parse.js'
export { save } from './serialize.js'
export { validate } from './validate.js'
export type { ValidationError, ValidationResult } from './validate.js'

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

export * from './analysis/index.js'

export { toUnicode, toLatex, toAscii, toMathML } from './pretty-print.js'

export { substitute, substituteInModel, substituteInReactionSystem } from './substitute.js'

export * from './edit.js'

export { freeVariables, freeParameters, contains, simplify } from './expression.js'

export {
  deriveODEs,
  stoichiometricMatrix,
  substrateMatrix,
  productMatrix,
} from './reactions.js'

export { parseUnit, checkDimensions, validateUnits } from './units.js'
export type { UnitResult, UnitWarning } from './units.js'

export { toJuliaCode, toPythonCode, compileExpression, evaluateExpression, UnloweredOperatorError } from './codegen.js'
export type { CompiledExpression } from './codegen.js'

export {
  migrate,
  canMigrate,
  getSupportedMigrationTargets,
  MigrationError,
} from './migration.js'

export * from './error-handling.js'

export { flatten } from './flatten.js'
export type { FlattenedEquation, FlattenMetadata, FlattenedSystem } from './flatten.js'

export {
  resolveSubsystemRefs,
  CircularReferenceError,
  RefLoadError,
} from './ref-loading.js'

export const VERSION = '0.1.0'
export const SCHEMA_VERSION = '0.1.0'
