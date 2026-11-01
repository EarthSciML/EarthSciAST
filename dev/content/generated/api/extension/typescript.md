---
title: "TypeScript extension seams"
description: "TypeScript's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

91 names.

### `AnalysisOptions` {#x-analysisoptions}

*type* · canonical name `analysis_options`

```typescript
interface AnalysisOptions {
    includeComplexity?: boolean;
    includeSubexpressions?: boolean;
    includeDependencies?: boolean;
    includeDerivatives?: boolean;
    variables?: string[];
    minComplexityThreshold?: number;
}
```

Options controlling which analyses [`analyzeExpression`](/generated/api/extension/typescript#x-analyzeexpression) runs.

**Properties**

- `includeComplexity` — Compute complexity metrics and stability issues (expression targets only).
- `includeSubexpressions` — Identify common subexpressions (expression targets only).
- `includeDependencies` — Build the variable dependency graph.
- `includeDerivatives` — Compute partial derivatives and gradient (expression targets only).
- `variables` — Variables to differentiate with respect to (required for derivatives).
- `minComplexityThreshold` — Minimum complexity threshold for common-subexpression detection.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/index.ts#L97)

### `AnalysisResults` {#x-analysisresults}

*type* · canonical name `analysis_results`

```typescript
interface AnalysisResults {
    complexity?: ComplexityMetrics;
    stabilityIssues?: StabilityIssue[];
    commonSubexpressions?: CommonSubexpression[];
    dependencyGraph?: DependencyGraphType;
    partialDerivatives?: Map<string, DerivativeResult>;
    gradient?: DerivativeResult[];
}
```

Combined results returned by [`analyzeExpression`](/generated/api/extension/typescript#x-analyzeexpression).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/index.ts#L87)

### `analyzeComplexity` {#x-analyzecomplexity}

*function* · canonical name `analyze_complexity`

```typescript
function analyzeComplexity(expr: Expr): ComplexityMetrics
```

Analyze the complexity of an expression

**Parameters**

- `expr` — Expression to analyze

**Returns**

Complexity metrics

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L72)

### `analyzeExpression` {#x-analyzeexpression}

*function* · canonical name `analyze_expression`

```typescript
function analyzeExpression(target: Expr | Model | EsmFile, options?: AnalysisOptions): AnalysisResults
```

Perform comprehensive analysis of an expression or model.

**Parameters**

- `target` — Expression, Model, or ESM file to analyze
- `options` — Analysis options

**Returns**

Complete analysis results

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/index.ts#L118)

### `authoredTemplateNames` {#x-authoredtemplatenames}

*function* · canonical name `authored_template_names`

```typescript
function authoredTemplateNames(rawSource: unknown): Record<string, string[]>
```

Per-component MATCH-LESS template names authored in-file in `rawSource`
(`compKind.cname` → ordered names). Emit keeps these verbatim as authored
entries (esm-spec §9.6.4 rule 5); imported/derived templates are materialized
instead. Mirrors the Julia reference `_authored_template_names`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L2067)

### `buildDependencyGraph` {#x-builddependencygraph}

*function* · canonical name `build_dependency_graph`

```typescript
function buildDependencyGraph(target: EsmFile | Model | ReactionSystem | Expr, options?: { includeParameters?: boolean; includeObserved?: boolean; mergeAcrossSystems?: boolean }): DependencyGraph
```

Build a dependency graph from an ESM file, model, or expression

**Parameters**

- `target` — The target to analyze
- `options` — Analysis options

**Returns**

Dependency graph with nodes and edges

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts#L41)

### `buildEmittedDocument` {#x-buildemitteddocument}

*function* · canonical name `build_emitted_document`

```typescript
function buildEmittedDocument(loaded: Record<string, unknown>, authored: Record<string, string[]>): Record<string, unknown>
```

Build the reference-preserving, self-contained emitted document (esm-spec
§9.6.4 rule 5, §7.5) from an already Option-B-loaded document `loaded` and
the authored-name map from the pristine source. For every component builds
its emitted `expression_templates` block — authored match-less entries first
in authored order, then the materialized transitive closure of its surviving
references (match-less), lexicographically sorted — drops consumed
`expression_template_imports`, and version-stamps `esm: 0.9.0` when any
surviving reference or materialized entry remains (§9.6.4 rule 8). Mutates
and returns `loaded`. Mirrors the Julia reference `emit_document` tail.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L2100)

### `CadenceClass` {#x-cadenceclass}

*type* · canonical name `cadence_class`

```typescript
type CadenceClass = 'const' | 'discrete' | 'continuous';
```

The three cadence classes, totally ordered `const ⊏ discrete ⊏ continuous`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L53)

### `CadenceCycleError` {#x-cadencecycleerror}

*error* · canonical name `cadence_cycle_error`

```typescript
class CadenceCycleError extends EsmDiagnosticError
new CadenceCycleError(cycle: string[]): CadenceCycleError
```

Raised when the observed-definition chain contains a cycle.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L70)

### `CadenceSeeder` {#x-cadenceseeder}

*type* · canonical name `cadence_seeder`

```typescript
class CadenceSeeder
new CadenceSeeder(model: Model, esmFile?: EsmFile): CadenceSeeder
CadenceSeeder.prototype.observedNames(): string[]
CadenceSeeder.prototype.leaf(name: string): CadenceClass
CadenceSeeder.prototype.expression(expr: Expression): CadenceClass
```

A reusable cadence seeder for ONE model. Holds the memo table for observed
resolution, so a chain of observeds is resolved once rather than once per
reference.

**Members**

- `observedNames` — The set of observed unknowns, for callers that want to enumerate them.
- `leaf` — The cadence seed of a single NAME appearing as a leaf.
  
  A name that is not declared in this model — an index-set name, a bound index
  symbol, a relation tag, a coupled reference — seeds `const`, matching the
  final row of the §5.7.2 table.
- `expression` — The cadence of an EXPRESSION: `max` over its leaves.
  
  The gather rule needs no special case — index expressions are ordinary
  children, so `index(u, index(nbr, i, k))` splits naturally, the inner
  neighbour selection staying `const` while the outer value load is
  `continuous` because it touches `u`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L85)

### `CanonicalDims` {#x-canonicaldims}

*type* · canonical name `canonical_dims`

```typescript
interface CanonicalDims {
    kg?: number;
    m?: number;
    s?: number;
    K?: number;
    mol?: number;
    A?: number;
    cd?: number;
    rad?: number;
}
```

Exponents over the SI base dimensions — the SAME eight axes, in the same
roles, as the Go reference's `Dimension` vector (`m kg s mol K A cd rad`),
which is the cross-binding contract for what a unit string MEANS.

`molec` is deliberately NOT an axis. A count of discrete things carries no
physical dimension, so `molec` (and `individuals`, `vehicles`, `units`,
`count`) is a DIMENSIONLESS unit in the table below — which is what makes
`molec/cm^3` compare equal to `1/cm^3`, as every other binding has it.

A missing key means exponent zero; `{}` is dimensionless.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/unit-conversion.ts#L27)

### `checkDimensions` {#x-checkdimensions}

*function* · canonical name `check_dimensions`

```typescript
function checkDimensions(expr: Expression, unitBindings: Map<string, ParsedUnit>, options?: DimensionOptions): UnitResult
```

Check dimensional consistency of an expression.

Follows ESM spec Section 3.3.1:
- Addition/subtraction: operands must share canonical dimensions
- Multiplication: dimensions add (scales multiply)
- Division: dimensions subtract (scales divide)
- `^` with a constant integer exponent: dimensions scale by the exponent
- `sqrt`: dimensions halve
- `D(x, wrt=t)`: dimension of x divided by dimension of t
- Transcendental functions require dimensionless arguments

Returns `dimensions: null` for anything INDETERMINATE (see
`UnitResult.dimensions`) — an unknown variable, or an operator this
module does not model dimensionally. Indeterminate operands never produce a
mismatch; only a *provable* inconsistency does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/units.ts#L385)

### `classifyComplexity` {#x-classifycomplexity}

*function* · canonical name `classify_complexity`

```typescript
function classifyComplexity(expr: Expr): 'trivial' | 'simple' | 'moderate' | 'complex' | 'very_complex'
```

Classify expression complexity level

**Parameters**

- `expr` — Expression to classify

**Returns**

Complexity level

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L282)

### `classifyDocument` {#x-classifydocument}

*function* · canonical name `classify_document`

```typescript
function classifyDocument(models: { [k: string]: unknown }): { [path: string]: ModelClassification }
```

Classify every model node in a document, keyed by DOT-PATH from the document
root, so a subsystem is `Parent.Child`. Classification is per model NODE, not
per document: the names inside each list are LOCAL to that model and are not
namespaced. A binding that flattens the document first and classifies once
returns one merged answer instead of a scoped answer per node.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L418)

### `classifyModel` {#x-classifymodel}

*function* · canonical name `classify_model`

```typescript
function classifyModel(model: Model): ModelClassification
```

Classify one model node.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L397)

### `CLOSED_FUNCTION_NAMES` {#x-closed_function_names}

*constant* · canonical name `closed_function_names`

```typescript
const CLOSED_FUNCTION_NAMES: readonly string[]
```

**Deprecated.** Use `closedFunctionNames()`.

---

**Deprecated.** Use [`closedFunctionNames`](/generated/api/ref/closed_function_names). Kept for one minor per
API_SPEC.md §10; removed at the next major.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L602)

### `ClosedFunctionErrorCode` {#x-closedfunctionerrorcode}

*type* · canonical name `closed_function_error_code`

```typescript
type ClosedFunctionErrorCode = 'unknown_closed_function' | 'closed_function_arity' | 'closed_function_overflow' | 'searchsorted_non_monotonic' | 'searchsorted_nan' | 'interp_non_monotonic_axis' | 'interp_axis_length_mismatch' | 'interp_nan_in_axis' | 'interp_axis_too_short' | 'interp_table_not_const' | 'interp_axis_not_const';
```

The stable diagnostic codes a [`ClosedFunctionError`](/generated/api/ref/closed_function_error) can carry: an
unrecognized function name or wrong argument count at dispatch, a non-finite
input or out-of-range integer result, and the load-time validation failures of
`interp.searchsorted` tables and `interp.linear` / `interp.bilinear` axes
and tables (non-monotonic, NaN, length mismatch, too short, not a constant).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L28)

### `CommonSubexpression` {#x-commonsubexpression}

*type* · canonical name `common_subexpression`

```typescript
interface CommonSubexpression {
    expression: Expr;
    locations: ExpressionLocation[];
    count: number;
    savings: number;
}
```

Common subexpression identification result

**Properties**

- `expression` — The common subexpression
- `locations` — Locations where this subexpression appears
- `count` — Number of occurrences
- `savings` — Estimated cost savings from factoring out

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L113)

### `compareComplexity` {#x-comparecomplexity}

*function* · canonical name `compare_complexity`

```typescript
function compareComplexity(expr1: Expr, expr2: Expr): number
```

Compare complexity of two expressions

**Parameters**

- `expr1` — First expression
- `expr2` — Second expression

**Returns**

Comparison result (-1: expr1 simpler, 0: equal, 1: expr1 more complex)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L250)

### `CompiledExpression` {#x-compiledexpression}

*type* · canonical name `compiled_expression`

```typescript
type CompiledExpression = (bindings: Map<string, number>) => number;
```

Compiled expression closure produced by [`compileExpression`](/generated/api/extension/typescript#x-compileexpression).
Accepts a `bindings` map of free-variable name → numeric value and
returns the scalar result.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L37)

### `compileExpression` {#x-compileexpression}

*function* · canonical name `compile_expression`

```typescript
function compileExpression(expr: Expr, options?: EvaluateOptions): CompiledExpression
```

Build a reusable closure that walks the canonical-AST `Expr` and
evaluates it against a bindings map. This is the EarthSciAST TypeScript
runner's entry point for scalar evaluation.

The walker rejects unlowered `enum` ops (lower via `lowerEnums()` at
load time) and array-valued `const` nodes (those are consumed by
container ops such as `interp.searchsorted` and `index`, not by
scalar evaluation).

Pass `{ functionTables: file.function_tables }` to evaluate an expression
containing `table_lookup` nodes — see `EvaluateOptions`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L208)

### `ComplexityMetrics` {#x-complexitymetrics}

*type* · canonical name `complexity_metrics`

```typescript
interface ComplexityMetrics {
    depth: number;
    operationCount: number;
    variableCount: number;
    constantCount: number;
    operationTypes: Record<string, number>;
    computationalCost: number;
    memoryUsage: number;
}
```

Complexity metrics for an expression

**Properties**

- `depth` — Total depth of the expression tree
- `operationCount` — Total number of operations
- `variableCount` — Number of unique variables
- `constantCount` — Number of constants
- `operationTypes` — Distribution of operation types
- `computationalCost` — Estimated computational cost (arbitrary units)
- `memoryUsage` — Memory usage estimate (arbitrary units)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L83)

### `DEFAULT_MIN_COMPLEXITY` {#x-default_min_complexity}

*constant* · canonical name `default_min_complexity`

```typescript
const DEFAULT_MIN_COMPLEXITY: 5
```

Default minimum [`analyzeComplexity`](/generated/api/extension/typescript#x-analyzecomplexity) cost a subexpression must reach to
be considered for factoring. Shared by every entry point below.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L18)

### `DependencyGraph` {#x-dependencygraph}

*type* · canonical name `dependency_graph`

```typescript
interface DependencyGraph extends Graph<DependencyNode, DependencyRelation> {
    hasCircularDependencies(): boolean;
    getCycles(): DependencyNode[][];
    getStronglyConnectedComponents(): DependencyNode[][];
    topologicalSort(): DependencyNode[];
}
```

Graph representing variable dependencies

**Properties**

- `hasCircularDependencies` — Check for circular dependencies
- `getCycles` — Circular-dependency cycles. Each entry is one back-edge cycle found by a
  DFS over the directed edges; distinct cycles may share nodes (these are
  NOT strongly-connected components).
- `getStronglyConnectedComponents` — **Deprecated.** Misnomer — this does NOT compute strongly-connected
  components; it returns the raw DFS cycles from `getCycles`. Use
  `getCycles` instead.
- `topologicalSort` — Topological sort of dependencies

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L63)

### `DependencyNode` {#x-dependencynode}

*type* · canonical name `dependency_node`

```typescript
interface DependencyNode {
    name: string;
    kind: VariableKind;
    system: string;
    units?: string;
    definition?: Expr;
    depth: number;
}
```

Node representing a variable in a dependency graph.

Overlaps graph.ts's [`VariableNode`](/generated/api/ref/variable_node) (both carry `name`/`kind`/`units`/
`system`); this analysis variant additionally tracks the defining expression
(`definition`) and the topological `depth`. The two families are
kept separate because they are produced by different builders
(`analysis/buildDependencyGraph` vs graph.ts's `expressionGraph`) with
different edge payloads; the shared `kind` vocabulary is unified via
[`VariableKind`](/generated/api/ref/variable_kind).

**Properties**

- `name` — Variable name
- `kind` — DERIVED variable category (state, algebraic, observed, parameter, brownian, discrete, species) — see [`VariableKind`](/generated/api/ref/variable_kind).
- `system` — System/model this variable belongs to
- `units` — Units if specified
- `definition` — Definition expression if available
- `depth` — Nesting level in the dependency graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L29)

### `DependencyRelation` {#x-dependencyrelation}

*type* · canonical name `dependency_relation`

```typescript
interface DependencyRelation {
    source: string;
    target: string;
    type: 'direct' | 'circular' | 'parameter_dependency' | 'definition_dependency';
    expression?: Expr;
}
```

Edge representing a dependency relationship between variables.

Analysis-local counterpart of graph.ts's [`DependencyEdge`](/generated/api/ref/dependency_edge); the two use
disjoint edge vocabularies (`type` here vs `relationship`/`equation_index`
there) because they are built by different graph constructors.

**Properties**

- `source` — Source variable
- `target` — Target variable
- `type` — Type of dependency
- `expression` — Expression that creates this dependency

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L51)

### `DerivativeResult` {#x-derivativeresult}

*type* · canonical name `derivative_result`

```typescript
interface DerivativeResult {
    derivative: Expr;
    variable: string;
    simplified?: Expr;
    derivativeSteps?: Array<{
        expression: Expr;
        derivative: Expr;
    }>;
}
```

Result of symbolic differentiation

**Properties**

- `derivative` — The derivative expression
- `variable` — Variable with respect to which we differentiated
- `simplified` — Simplified form if different from derivative
- `derivativeSteps` — For [`higherOrderDerivative`](/generated/api/extension/typescript#x-higherorderderivative): one entry per differentiation order,
  recording the expression at that order (`expression`) and its derivative
  (`derivative`, i.e. the expression at the next order). These are the
  successive derivative steps, NOT chain-rule multiplicative factors.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L135)

### `detectStabilityIssues` {#x-detectstabilityissues}

*function* · canonical name `detect_stability_issues`

```typescript
function detectStabilityIssues(expr: Expr): StabilityIssue[]
```

Detect numerical stability issues in expressions

**Parameters**

- `expr` — Expression to analyze

**Returns**

Array of potential stability issues

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L392)

### `differentiate` {#x-differentiate}

*function* · canonical name `differentiate`

```typescript
function differentiate(expr: Expr, variable: string): DerivativeResult
```

Compute the symbolic derivative of an expression with respect to a variable

**Parameters**

- `expr` — Expression to differentiate
- `variable` — Variable with respect to which to differentiate

**Returns**

Derivative result with simplified form

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L112)

### `dispatchClosedFunction` {#x-dispatchclosedfunction}

*function* · canonical name `dispatch_closed_function`

```typescript
function dispatchClosedFunction(name: string, args: unknown[]): number
```

Resolve a closed-function name + already-evaluated positional args into a
scalar result via `CLOSED_FUNCTION_DISPATCH`. Unknown names raise
`unknown_closed_function`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L609)

### `E_CANONICAL_DIVBY_ZERO` {#x-e_canonical_divby_zero}

*constant* · canonical name `e_canonical_divby_zero`

```typescript
const E_CANONICAL_DIVBY_ZERO: "E_CANONICAL_DIVBY_ZERO"
```

`E_CANONICAL_DIVBY_ZERO` — `/(0, 0)` (§5.4.7).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/canonicalize.ts#L33)

### `E_CANONICAL_NONFINITE` {#x-e_canonical_nonfinite}

*constant* · canonical name `e_canonical_nonfinite`

```typescript
const E_CANONICAL_NONFINITE: "E_CANONICAL_NONFINITE"
```

`E_CANONICAL_NONFINITE` — NaN or ±Inf (§5.4.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/canonicalize.ts#L31)

### `ErrorCode` {#x-errorcode}

*type* · canonical name `error_code`

```typescript
type ErrorCode = (typeof ERROR_CODES)[keyof typeof ERROR_CODES];
```

A diagnostic code string from [`ERROR_CODES`](/generated/api/ref/error_codes).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/errors.ts#L530)

### `EsmDiagnosticError` {#x-esmdiagnosticerror}

*error* · canonical name `esm_diagnostic_error`

```typescript
class EsmDiagnosticError extends Error
new EsmDiagnosticError(code: string, message: string, details?: Record<string, unknown>): EsmDiagnosticError
```

Neutral base for EarthSciAST diagnostics: an `Error` carrying a stable `code`
string (from [`ERROR_CODES`](/generated/api/ref/error_codes)) and optional structured `details`. The
package's error classes extend it — `EsmMachineryError`, `EnumLoweringError`,
`ClosedFunctionError`, `FlattenError`, `UnitConversionError` and the rest —
so one `instanceof EsmDiagnosticError` check catches them, and `code` names
the specific diagnostic.

One exception: the operator registry's arity and domain checks (an operator
given the wrong number of arguments, `log` of a non-positive value, division
by zero) throw a plain `Error` with no `code`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/errors.ts#L544)

### `EsmMachineryError` {#x-esmmachineryerror}

*error* · canonical name `esm_machinery_error`

```typescript
class EsmMachineryError extends EsmDiagnosticError
new EsmMachineryError(code: string, message: string): EsmMachineryError
```

Shared load-time diagnostic for the §9.x machinery: expression-template
lowering (§9.6), template-library imports (§9.7), coupling-library imports
(§10.10), subsystem-ref loading, and the §9.6.4 expanded-form validators all
raise it as their common coded-diagnostic class — `validate` maps it (by
`instanceof`) to the `expression_template_error` load-error kind. A subclass
of [`EsmDiagnosticError`](/generated/api/extension/typescript#x-esmdiagnosticerror): `code` is the specific diagnostic and the
message text is `[code] message`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L113)

### `estimateParallelPotential` {#x-estimateparallelpotential}

*function* · canonical name `estimate_parallel_potential`

```typescript
function estimateParallelPotential(expr: Expr): number
```

Estimate parallel execution potential

**Parameters**

- `expr` — Expression to analyze

**Returns**

Parallelization score (0-1, higher means more parallelizable)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L361)

### `estimateSavings` {#x-estimatesavings}

*function* · canonical name `estimate_savings`

```typescript
function estimateSavings(commonSubexpressions: CommonSubexpression[]): number
```

Estimate the cost savings from factoring out common subexpressions

**Parameters**

- `commonSubexpressions` — Array of common subexpressions

**Returns**

Total estimated cost savings

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L245)

### `evaluateExpression` {#x-evaluateexpression}

*function* · canonical name `evaluate_expression`

```typescript
function evaluateExpression(expr: Expr, bindings: Map<string, number>, options?: EvaluateOptions): number
```

Compile and apply in one step. Equivalent to
`compileExpression(expr)(bindings)` but avoids allocating a closure
for one-shot callers (`simplify`'s constant-folding path,
fixed-point observed-variable resolution, unit-conversion
folding).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L220)

### `EvaluatorError` {#x-evaluatorerror}

*error* · canonical name `evaluator_error`

```typescript
class EvaluatorError extends EsmDiagnosticError
new EvaluatorError(code: string, message: string): EvaluatorError
```

Error raised by the tree-walking evaluator for a node it cannot reduce to a
scalar: an unbound variable, an unsupported operator, an unlowered `enum`, a
non-scalar `const`, a malformed `fn`, or a non-expression value. Carries a
stable `code` field so callers can branch programmatically instead of
regex-matching prose.

Unlike [`UnloweredOperatorError`](/generated/api/extension/typescript#x-unloweredoperatorerror), the `message` is passed through
VERBATIM (not `[code]`-prefixed): several of these strings are matched
byte-for-byte by the cross-binding runner tests, so the wording is pinned.
These `code` values are binding-local diagnostics for the in-process runner,
distinct from the cross-language conformance codes in `errors.ts`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L188)

### `Expand` {#x-expand}

*type* · canonical name `expand`

```typescript
function Expand<T extends object>(loaded: T): T
```

Public alias for [`expandDocument`](/generated/api/ref/expand_document) using the spec's spelling (§9.6.4 rule 2).

---

Fully expand every surviving `apply_expression_template` reference in a
document `loaded` by [`lowerExpressionTemplates`](/generated/api/ref/lower_expression_templates) (Option B), producing
the Option-A image: every reference replaced by its expansion (pure
substitution to the acyclic fixpoint, §9.6.4 rule 2) and every per-component
`expression_templates` block stripped. Deterministic — the §9.7.3 DAG is
acyclic and substitution confluent, so `expandDocument(load(f))` is
structurally equal to the pre-0.9.0 expanded form (the `expanded*.esm`
conformance oracle). Non-destructive: `loaded` is deep-cloned first. Mirrors
the Julia reference `expand_document` / `Expand`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L1985)

### `expressionCadence` {#x-expressioncadence}

*function* · canonical name `expression_cadence`

```typescript
function expressionCadence(model: Model, expr: Expression, esmFile?: EsmFile): CadenceClass
```

The cadence of an expression in a model: `max` over its leaves.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L293)

### `ExpressionLocation` {#x-expressionlocation}

*type* · canonical name `expression_location`

```typescript
interface ExpressionLocation {
    path: string[];
    description: string;
    context?: Expr;
}
```

Location of an expression within a larger structure

**Properties**

- `path` — Path to the expression (e.g. `['root', 'args[0]', 'args[1]']`)
- `description` — Human-readable description
- `context` — Parent expression context

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L125)

### `FieldInitialCondition` {#x-fieldinitialcondition}

*type* · canonical name `field_initial_condition`

```typescript
interface FieldInitialCondition {
    state: string;
    expr: Expression;
}
```

A deferred `ic` equation (esm-spec §11.4.1): an initial condition, not dynamics.

**Properties**

- `state` — The namespaced state the condition pins.
- `expr` — The value at t=0.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L396)

### `findCommonSubexpressions` {#x-findcommonsubexpressions}

*function* · canonical name `find_common_subexpressions`

```typescript
function findCommonSubexpressions(expr: Expr, minComplexity?: number): CommonSubexpression[]
```

Find common subexpressions in a single expression

**Parameters**

- `expr` — Expression to analyze
- `minComplexity` — Minimum complexity threshold for considering subexpressions

**Returns**

Array of common subexpressions found

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L115)

### `findCommonSubexpressionsAcrossExpressions` {#x-findcommonsubexpressionsacrossexpressions}

*function* · canonical name `find_common_subexpressions_across_expressions`

```typescript
function findCommonSubexpressionsAcrossExpressions(expressions: Array<{ expr: Expr; name: string }>, minComplexity?: number): CommonSubexpression[]
```

Find common subexpressions across multiple expressions

**Parameters**

- `expressions` — Array of expressions to analyze
- `minComplexity` — Minimum complexity threshold

**Returns**

Array of common subexpressions found across expressions

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L136)

### `findCommonSubexpressionsInEsmFile` {#x-findcommonsubexpressionsinesmfile}

*function* · canonical name `find_common_subexpressions_in_esm_file`

```typescript
function findCommonSubexpressionsInEsmFile(esmFile: EsmFile, minComplexity?: number): CommonSubexpression[]
```

Find common subexpressions across an entire ESM file. All models' and
reaction systems' raw expressions are aggregated into ONE analysis pass so
occurrence counts and locations reflect actual appearances — including
duplicates local to a single model and duplicates spanning components.

**Parameters**

- `esmFile` — ESM file to analyze
- `minComplexity` — Minimum complexity threshold

**Returns**

Array of common subexpressions found across the file

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L208)

### `findCommonSubexpressionsInModel` {#x-findcommonsubexpressionsinmodel}

*function* · canonical name `find_common_subexpressions_in_model`

```typescript
function findCommonSubexpressionsInModel(model: Model, minComplexity?: number): CommonSubexpression[]
```

Find common subexpressions in a model (including its subsystems). All of
the model's expressions are analyzed in a single pass so duplicates that
span the parent and a subsystem are counted together.

**Parameters**

- `model` — Model to analyze
- `minComplexity` — Minimum complexity threshold

**Returns**

Array of common subexpressions found in the model

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L190)

### `findCriticalPoints` {#x-findcriticalpoints}

*function* · canonical name `find_critical_points`

```typescript
function findCriticalPoints(expr: Expr, variable: string): { derivative: Expr; simplified?: Expr; hasConstantDerivative: boolean; isConstantZero: boolean }
```

Find critical points (where derivative equals zero)
This is a symbolic analysis - actual solving would require numerical methods

**Parameters**

- `expr` — Expression to analyze
- `variable` — Variable to find critical points for

**Returns**

Information about potential critical points

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L414)

### `findDeadVariables` {#x-finddeadvariables}

*function* · canonical name `find_dead_variables`

```typescript
function findDeadVariables(graph: DependencyGraph): DependencyNode[]
```

Find dependency-graph sinks: non-state variables that nothing else depends
on. Note this includes terminal observed outputs — a sink is only truly
"dead" if it is also not consumed outside the model (plots, couplings,
downstream tooling), which this graph cannot see. State variables are
excluded because they are integration outputs by definition.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts#L435)

### `findDependencyChains` {#x-finddependencychains}

*function* · canonical name `find_dependency_chains`

```typescript
function findDependencyChains(graph: DependencyGraph, startNode: string, maxDepth?: number): string[][]
```

Enumerate every path from `startNode` to a sink (a node with no successors),
following successor edges. Paths that revisit a node or exceed `maxDepth`
hops are pruned.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/dependency-graph.ts#L452)

### `findExpensiveSubexpressions` {#x-findexpensivesubexpressions}

*function* · canonical name `find_expensive_subexpressions`

```typescript
function findExpensiveSubexpressions(expr: Expr, limit?: number): Array<{ expression: Expr; cost: number; path: string[] }>
```

Find the most expensive sub-expressions in an expression

**Parameters**

- `expr` — Expression to analyze
- `limit` — Maximum number of results to return

**Returns**

Array of expensive sub-expressions with their costs

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/complexity.ts#L307)

### `FlattenedTemplateRegistries` {#x-flattenedtemplateregistries}

*type* · canonical name `flattened_template_registries`

```typescript
interface FlattenedTemplateRegistries {
    root: Record<string, unknown>;
    merged: Record<string, unknown>;
}
```

Result of [`flattenTemplateRegistries`](/generated/api/ref/flatten_template_registries): the rewritten document + merged registry.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L2328)

### `FlattenedVariableMap` {#x-flattenedvariablemap}

*type* · canonical name `flattened_variable_map`

```typescript
type FlattenedVariableMap = Record<string, FlattenedVariable>;
```

An insertion-ORDERED map from namespaced name to variable. Order is part of
the cross-binding contract (see the module doc); JavaScript preserves the
insertion order of string keys that do not look like array indices, which a
dot-namespaced variable name never does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L295)

### `FlattenedVariableRole` {#x-flattenedvariablerole}

*type* · canonical name `flattened_variable_role`

```typescript
type FlattenedVariableRole = 'state' | 'parameter' | 'observed' | 'species';
```

The DERIVED role of a flattened variable (esm-spec §6.3.1) — never a declared
type, which from 1.0.0 is only `unknown` or `parameter`.

- `state` — solved for and defined by no equation of its own: an ODE state or
  an algebraic unknown.
- `observed` — an unknown an equation DEFINES, at either LHS spelling. A
  scalar one is eliminable by inlining and appears in `observedVariables`
  alone; an arrayed one materializes into a buffer and appears in
  `stateVariables` too, keeping this role in both (esm-libraries-spec §4.7.5
  step 4: `stateVariables` is the solved-for vector, not a classification).
- `parameter` — a parameter of any cadence.
- `species` — a reaction-system state (a `state` that came from a species).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L258)

### `FlattenOptions` {#x-flattenoptions}

*type* · canonical name `flatten_options`

```typescript
type FlattenOptions = CouplingImportOptions;
```

Options for [`flatten`](/generated/api/ref/flatten). Only needed when the file uses `coupling_import`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L105)

### `formatChemicalName` {#x-formatchemicalname}

*function* · canonical name `format_chemical_name`

```typescript
function formatChemicalName(name: string): string
```

Apply element-aware chemical subscript formatting to a bare variable /
species name using Unicode subscript digits (e.g. "H2SO4" → "H₂SO₄").
Exported for graph rendering (toDot / toMermaid labels).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/pretty-print.ts#L929)

### `generateFactoredVariableNames` {#x-generatefactoredvariablenames}

*function* · canonical name `generate_factored_variable_names`

```typescript
function generateFactoredVariableNames(commonSubexpressions: CommonSubexpression[], prefix?: string): Map<CommonSubexpression, string>
```

Generate variable names for factored subexpressions.

Keyed by the [`CommonSubexpression`](/generated/api/extension/typescript#x-commonsubexpression) object itself so callers can look up
a generated name directly from the array element (the previous private
string key could not be reconstructed by callers).

**Parameters**

- `commonSubexpressions` — Array of common subexpressions
- `prefix` — Prefix for generated variable names

**Returns**

Map from each common subexpression to its generated variable name

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L259)

### `gradient` {#x-gradient}

*function* · canonical name `gradient`

```typescript
function gradient(expr: Expr, variables?: string[]): DerivativeResult[]
```

Compute the gradient (all first partial derivatives)

**Parameters**

- `expr` — Expression to differentiate
- `variables` — Array of variables (if not provided, will extract from expression)

**Returns**

Gradient as array of derivatives

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L145)

### `groupSubexpressionsByType` {#x-groupsubexpressionsbytype}

*function* · canonical name `group_subexpressions_by_type`

```typescript
function groupSubexpressionsByType(commonSubexpressions: CommonSubexpression[]): Record<string, CommonSubexpression[]>
```

Group common subexpressions by their structure type

**Parameters**

- `commonSubexpressions` — Array of common subexpressions

**Returns**

Grouped subexpressions by operation type

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/common-subexpressions.ts#L280)

### `higherOrderDerivative` {#x-higherorderderivative}

*function* · canonical name `higher_order_derivative`

```typescript
function higherOrderDerivative(expr: Expr, variable: string, order?: number): DerivativeResult
```

Compute higher-order derivatives

**Parameters**

- `expr` — Expression to differentiate
- `variable` — Variable with respect to which to differentiate
- `order` — Order of derivative (default: 1)

**Returns**

Higher-order derivative result

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L360)

### `interpBilinear` {#x-interpbilinear}

*function* · canonical name `interp_bilinear`

```typescript
function interpBilinear(table: readonly (readonly number[])[], axisX: readonly number[], axisY: readonly number[], x: number, y: number): number
```

2-D bilinear interpolation with per-axis extrapolate-flat clamps.
Pinned evaluation order: two x-blends followed by one y-blend, each
in the form `a + w*(b - a)` (esm-spec §9.2). `table` is row-major:
`table[i][j]` is the value at `(axis_x[i], axis_y[j])`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L446)

### `interpLinear` {#x-interplinear}

*function* · canonical name `interp_linear`

```typescript
function interpLinear(table: readonly number[], axis: readonly number[], x: number): number
```

1-D linear interpolation with extrapolate-flat clamps. Pinned form
`result = t[i] + w * (t[i+1] - t[i])` so that w=0/1 reproduce the
endpoint exactly under IEEE-754 round-to-nearest.

Validates `axis` on every call (cheap relative to dispatch overhead;
matches the `searchsortedFirst` convention in this module).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L420)

### `InvalidDerivativeOrderError` {#x-invalidderivativeordererror}

*error* · canonical name `invalid_derivative_order_error`

```typescript
class InvalidDerivativeOrderError extends EsmDiagnosticError
new InvalidDerivativeOrderError(order: number): InvalidDerivativeOrderError
```

Thrown by [`higherOrderDerivative`](/generated/api/extension/typescript#x-higherorderderivative) when `order` is not positive.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L32)

### `isDifferentiable` {#x-isdifferentiable}

*function* · canonical name `is_differentiable`

```typescript
function isDifferentiable(expr: Expr, variable: string): boolean
```

Check if an expression is differentiable with respect to a variable

**Parameters**

- `expr` — Expression to check
- `variable` — Variable to check differentiability with respect to

**Returns**

True if differentiable, false otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L397)

### `joinAll` {#x-joinall}

*function* · canonical name `join_all`

```typescript
function joinAll(classes: Iterable<CadenceClass>): CadenceClass
```

The join of any number of cadence classes; `const` when there are none.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L63)

### `joinCadence` {#x-joincadence}

*function* · canonical name `join_cadence`

```typescript
function joinCadence(a: CadenceClass, b: CadenceClass): CadenceClass
```

The join (`max`) of two cadence classes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L58)

### `leafCadence` {#x-leafcadence}

*function* · canonical name `leaf_cadence`

```typescript
function leafCadence(model: Model, name: string, esmFile?: EsmFile): CadenceClass
```

The cadence seed of one leaf NAME in a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/cadence.ts#L288)

### `ModelClassification` {#x-modelclassification}

*type* · canonical name `model_classification`

```typescript
interface ModelClassification {
    odeStates: string[];
    observedUnknowns: string[];
    algebraicUnknowns: string[];
    brownianParameters: string[];
    discreteParameters: string[];
    sampledParameters: string[];
    constantParameters: string[];
    systemKind: SystemKind;
    declaredSystemKind: SystemKind | null;
}
```

Every derived set for one model node, as the conformance goldens spell it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L384)

### `NonDifferentiableExpressionError` {#x-nondifferentiableexpressionerror}

*error* · canonical name `non_differentiable_expression_error`

```typescript
class NonDifferentiableExpressionError extends EsmDiagnosticError
new NonDifferentiableExpressionError(op: string, variable: string): NonDifferentiableExpressionError
```

Thrown when [`differentiate`](/generated/api/extension/typescript#x-differentiate) encounters an operator with no
differentiation rule, or a known operator applied with an arity its rule
does not cover. Callers that need a boolean answer should use
[`isDifferentiable`](/generated/api/extension/typescript#x-isdifferentiable).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L21)

### `ParameterClass` {#x-parameterclass-2}

*type* · canonical name `parameter_class`

```typescript
type ParameterClass = 'brownian' | 'discrete' | 'sampled' | 'constant';
```

The four derived parameter categories (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L28)

### `parameterClass` {#x-parameterclass}

*function* · canonical name `parameter_class`

```typescript
function parameterClass(variable: ModelVariable): ParameterClass
```

The derived class of ONE parameter. Exported because the cadence pass seeds
its leaves from this rather than re-deriving the categories locally
(CONFORMANCE_SPEC §5.7.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L285)

### `ParsedUnit` {#x-parsedunit}

*type* · canonical name `parsed_unit`

```typescript
interface ParsedUnit {
    dims: CanonicalDims;
    scale: number;
    offset?: number;
    exact: ExactScale;
}
```

**Properties**

- `exact` — The scale every agreement is decided on (esm-spec §4.8.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/unit-conversion.ts#L264)

### `parseReaction` {#x-parsereaction}

*function* · canonical name `parse_reaction`

```typescript
function parseReaction(src: string): Reaction
```

Parse a single reaction from its text-DSL form. Throws
[`ExpressionParseError`](/generated/api/ref/expression_parse_error) on any malformed input (the editor surfaces the
message and blocks the edit). The returned reaction's `id` is empty — the
caller assigns identity when merging into an existing reaction.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse-reaction.ts#L154)

### `parseUnitForConversion` {#x-parseunitforconversion}

*function* · canonical name `parse_unit_for_conversion`

```typescript
function parseUnitForConversion(unitStr: string): ParsedUnit
```

Parse a unit string into canonical SI dimensions plus scale (and optional offset).

Recursive-descent parser over the grammar of the Go reference implementation
(`pkg/earthsci-ast-go/pkg/esm/units.go`), so the bindings agree on how a unit
string associates:

```
  unit     := term ( ('*' | '/')? term )*
  term     := atom ( ('^' | '**') exponent )?
  exponent := '-'? (integer | decimal) | '(' '-'? integer '/' '-'? integer ')'
  atom     := '1' | symbol | '(' unit ')'
```

TOKENS (esm-spec §4.8.2). A RUN is a maximal sequence of `[A-Za-z0-9_]`. A run
of digits alone, optionally followed by `.` and a second digit-only run, is a
NUMBER; every other run is ONE symbol, which must be a table key as a whole:
`s1`, `1s` and `kgm` are never split into a key and a remainder, and `1e3` is a
symbol, not exponent notation. `%` is a one-character symbol whatever is
adjacent (`%h` is `%`·`h`). The only numeric atom is the literal `1` (`01` and
`1.0` are scaling factors). Exponents take no `+` sign. Whitespace is ASCII
space, tab, CR and LF.

EXPONENTS ARE RATIONAL, not integral: `1/s^0.5` (an SDE noise intensity) and
`m^(1/2)` are legitimate corpus units, and a dimension vector may therefore
carry fractional entries.

`*` and `/` share one precedence level and associate LEFT — so `kg/m*s` is
`(kg/m)*s` = kg·s·m⁻¹, NOT kg·m⁻¹·s⁻¹, and `a/b/c` is `a/(b*c)`. Grouping with
parentheses is supported, so the ordinary earth-science spellings `J/(mol*K)`
and `cm^3/(molec*s)` parse.

WHITESPACE BETWEEN TWO TERMS IS MULTIPLICATION — the SI style `kg m^2 s^-2`
and the corpus's `ppb^-1 s^-1`. The scanner is greedy over identifier
characters, so `ms` stays ONE symbol (millisecond); juxtaposition can only
arise across a real token boundary. `**` is accepted as a synonym for `^` (the
Python/pint spelling, e.g. the corpus's `Pa*m**3`).

The empty string, `"1"` and `"dimensionless"` are the dimensionless unit.
Only the EMPTY string is the empty unit: a whitespace-only string has no
tokens and does not resolve. Non-ASCII spellings (`μg`, `°C`) are normalized first — see
`normalizeUnitString`.

**Throws**

- [`UnitConversionError`](/generated/api/ref/unit_conversion_error) — on unknown unit names, malformed tokens,
    unbalanced parentheses, or trailing input.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/unit-conversion.ts#L777)

### `partialDerivatives` {#x-partialderivatives}

*function* · canonical name `partial_derivatives`

```typescript
function partialDerivatives(expr: Expr, variables: string[]): Map<string, DerivativeResult>
```

Compute partial derivatives with respect to multiple variables

**Parameters**

- `expr` — Expression to differentiate
- `variables` — Array of variables to differentiate with respect to

**Returns**

Map of variable names to their derivative results

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/differentiation.ts#L129)

### `RefLoadError` {#x-refloaderror}

*error* · canonical name `ref_load_error`

```typescript
class RefLoadError extends EsmDiagnosticError
new RefLoadError(ref: string, cause?: Error, code?: string, message?: string, path?: string): RefLoadError
readonly RefLoadError.prototype.ref: string
readonly RefLoadError.prototype.code: string
readonly RefLoadError.prototype.path: string
```

Error thrown when a referenced file cannot be loaded, parsed, or uniquely
resolved to one system.

Carries the CANONICAL cross-binding diagnostic code (see `ERROR_CODES`):

 - `unresolved_subsystem_ref` (default) — the file does not exist, or could
   not be read or parsed.
 - `ambiguous_subsystem_ref` — the file WAS read, and holds more than one
   top-level system; §4.7 requires exactly one.

The resolver is the only layer that reads the referenced file, so it is the
only layer that can tell those two apart — the synchronous `validate()` does
no I/O and reports every unresolved `{ref}` as `unresolved_subsystem_ref`.

**Members**

- `ref` — The reference path or URL that failed to load
- `code` — Canonical code: `unresolved_subsystem_ref`, `ambiguous_subsystem_ref`, or
  `mount_form_unsupported` for a mount form this binding does not implement.
- `path` — JSON Pointer of the SUBSYSTEM ENTRY that carries the bad ref (e.g.
  `/models/ClimateModel/subsystems/Atm`) — not the document root. The corpus
  pins these errors at the offending mount, and a caller handed `$` has to go
  hunting for which of a dozen mounts failed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/ref-loading.ts#L86)

### `searchsortedFirst` {#x-searchsortedfirst}

*function* · canonical name `searchsorted_first`

```typescript
function searchsortedFirst(x: number, xs: readonly number[]): number
```

Smallest 1-based `i` with `xs[i] ≥ x` (Julia `searchsortedfirst`
semantics). NaN x → N+1. xs MUST be pre-validated; the table is
inspected at every call so the caller can pass a fresh array each
scenario without bookkeeping (validation is cheap relative to the
dispatch overhead).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L254)

### `StabilityIssue` {#x-stabilityissue}

*type* · canonical name `stability_issue`

```typescript
interface StabilityIssue {
    issue: string;
    severity: 'low' | 'medium' | 'high';
    path: string[];
    suggestion: string;
}
```

A single numerical-stability finding produced by `detectStabilityIssues`.

**Properties**

- `issue` — Human-readable description of the issue
- `severity` — Severity of the issue
- `path` — Path to the offending subexpression (e.g. `['args[1]']`)
- `suggestion` — Suggested remediation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/analysis/types.ts#L101)

### `TemplateResolveOptions` {#x-templateresolveoptions}

*type* · canonical name `template_resolve_options`

```typescript
interface TemplateResolveOptions {
    metaparameters?: Record<string, number> | undefined;
    readFile?: ((path: string) => string) | undefined;
    validateSchema?: ((raw: unknown) => TemplateSchemaError[]) | undefined;
    mountDeclared?: ReadonlySet<string> | undefined;
    mountedLeaf?: boolean | undefined;
}
```

Options threaded through §9.7 resolution.

**Properties**

- `metaparameters` — Loader-API metaparameter bindings for the ROOT document
  (esm-spec §9.7.6 binding site 4). Already-closed edge bindings win;
  API bindings beat `default`s.
- `readFile` — Synchronous file reader for import refs. Defaults to Node's
  `fs.readFileSync` (via `process.getBuiltinModule`); browser hosts must
  supply their own.
- `validateSchema` — Schema validator applied to each import target (a target failing schema
  validation is `template_import_unresolved`, mirroring the Julia
  reference). Supplied by the `load*` entry points; optional for direct/raw use.
- `mountDeclared` — Metaparameter names declared by the documents this one MOUNTS (esm-spec
  §4.7, either mount form, transitively) — see
  `collectMountDeclaredMetaparameters`. Widens the §9.7.6 site-4
  check: a loader-API binding naming one of these is meaningful even though
  THIS document does not declare it, because the mount edge forwards it into
  the leaf's own close.
- `mountedLeaf` — This call IS a §4.7 mount edge, so index-set sizes this scope cannot close
  stay symbolic for the MOUNTING document's registry to close (§9.7.6 site
  5) instead of being `metaparameter_unbound` here. A root document leaves it
  unset.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/template-imports.ts#L75)

### `TemplateSchemaError` {#x-templateschemaerror}

*type* · canonical name `template_schema_error`

```typescript
interface TemplateSchemaError {
    path: string;
    message: string;
}
```

Schema-error shape accepted from the host's schema validator.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/template-imports.ts#L69)

### `ToJsonOptions` {#x-tojsonoptions}

*type* · canonical name `to_json_options`

```typescript
interface ToJsonOptions {
    canonical?: boolean;
    indent?: number;
}
```

Optional behavior controls for [`toJson`](/generated/api/ref/to_json) / [`writePath`](/generated/api/ref/write_path).

**Properties**

- `canonical` — When `true`, emit byte-canonical JSON per RFC §5.4.6: integer-tagged
  `NumericLiteral` leaves as integer tokens, float-tagged leaves with
  the trailing `.0` discriminator preserved (e.g. `1.0` stays `1.0`
  rather than collapsing to `1`). Plain JS `number` values keep
  `JSON.stringify` semantics in either mode.
  
  Default: `false` (structural round-trip; integer-valued floats may
  collapse to JSON integers).
- `indent` — Indentation passed through to the underlying JSON formatter.
  Default `2` to match the Python and Julia reference serializers.
  Set to `0` for a single-line emission.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/serialize.ts#L44)

### `toMathML` {#x-tomathml}

*function* · canonical name `to_math_ml`

```typescript
function toMathML(expr: Expr | Equation | Model | ReactionSystem | Reaction | EsmFile): string
```

Format an expression as MathML markup for web/academic publishing

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/pretty-print.ts#L936)

### `tryParseUnit` {#x-tryparseunit}

*function* · canonical name `try_parse_unit`

```typescript
function tryParseUnit(unitStr: string): ParsedUnit | null
```

Parse a unit string into canonical SI dimensions plus scale factor, or return
`null` when the string cannot be parsed.

This is the fallible companion to [`parseUnit`](/generated/api/ref/parse_unit): instead of swallowing a
parse failure into a dimensionless fallback, it surfaces the failure as
`null`. Callers can then leave the variable's dimension UNKNOWN (unbound) and
emit a warning, rather than silently manufacturing a dimensionless binding
that HIDES real dimensional mismatches — or MANUFACTURES false ones
(esm-libraries-spec §3.3.3/§3.4, matching the Julia reference). A
`UnitConversionError` (unknown unit name, malformed token, misused offset
unit) maps to `null`; any other error is rethrown.

`"degree"` / `"degrees"` are resolved by the canonical table as long-form
aliases of `deg` (esm-spec §4.8.1), i.e. as the ANGLE axis scaled by π/180 —
the reading the Rust, Julia and Python tables carry too.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/units.ts#L189)

### `UnevaluableOperatorError` {#x-unevaluableoperatorerror}

*error* · canonical name `unevaluable_operator_error`

```typescript
class UnevaluableOperatorError extends EsmDiagnosticError
new UnevaluableOperatorError(op: string, remedy?: string): UnevaluableOperatorError
readonly UnevaluableOperatorError.prototype.op: string
```

Error carrying the stable, cross-binding `unevaluable_operator` diagnostic
(esm-spec §9.6.6): an op that IS in the §4.2 evaluable-core set but that this
scalar evaluator has no rule for. The complement of
[`UnloweredOperatorError`](/generated/api/extension/typescript#x-unloweredoperatorerror), which is for an op OUTSIDE the core, so it
carries no rewrite-rule advice: the op needs an earlier pipeline stage (value
invention, or a load-time lowering pass), not a rewrite rule.

**Members**

- `op` — The offending operator name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L76)

### `UnitResult` {#x-unitresult}

*type* · canonical name `unit_result`

```typescript
interface UnitResult {
    dimensions: ParsedUnit | null;
    warnings: string[];
    diagnostics: UnitDiagnostic[];
}
```

Result of dimensional analysis for a single expression.

**Properties**

- `dimensions` — The expression's canonical dimension, or `null` when it is INDETERMINATE.
  
  `null` is not "dimensionless" — it is "this analysis cannot say", and it is
  the value returned for an unknown variable, an unparseable unit
  declaration, and any operator whose dimensional semantics this module does
  not model (`fn`, `table_lookup`, an faq under `reduce: "*"` with a
  dimensional body, ...).
  Keeping the two apart is what stops a structural op from being *assumed*
  dimensionless and thereby manufacturing a false mismatch against a
  dimensional operand. `null` propagates through every combining rule, and a
  comparison against `null` is never a mismatch — it is simply skipped, which
  mirrors the Go reference (`PropagateDimension` returns `nil, nil`).
- `warnings` — Message-only view, for the public `checkDimensions` API and callers that
   inspect warning prose.
- `diagnostics` — Structured view of `warnings`: each message with its explicit
   classification. `validateUnits` uses these codes (not a prose regex) to
   decide which warnings `validate()` promotes to errors.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/units.ts#L55)

### `unitsCompatible` {#x-unitscompatible}

*function* · canonical name `units_compatible`

```typescript
function unitsCompatible(a: string, b: string): boolean
```

Report whether two unit strings represent compatible (same-dimension) quantities.
A non-throwing companion to `convertUnits`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/unit-conversion.ts#L1120)

### `UnknownClass` {#x-unknownclass}

*type* · canonical name `unknown_class`

```typescript
type UnknownClass = 'ode_state' | 'observed' | 'algebraic';
```

The three derived unknown categories (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L31)

### `UnloweredOperatorError` {#x-unloweredoperatorerror}

*error* · canonical name `unlowered_operator_error`

```typescript
class UnloweredOperatorError extends EsmDiagnosticError
new UnloweredOperatorError(message: string): UnloweredOperatorError
```

Error carrying the stable, cross-binding `unlowered_operator` diagnostic
(esm-spec §4.2 / §9.6.3 constraint 6 / §9.6.8). Raised when a rewrite-target
op reaches evaluation/compilation without having been lowered — one uniform
gate, the same in every binding. Loading stays permissive (the op namespace
is open); the gate fires only at evaluation, as in the Julia reference.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/codegen.ts#L60)

### `updateRules` {#x-updaterules}

*function* · canonical name `update_rules`

```typescript
function updateRules(spec: ParameterUpdateSpec | undefined): ParameterUpdate[]
```

The update rules of a parameter, normalized to an array (possibly empty).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L275)

### `validateInterpAxis` {#x-validateinterpaxis}

*function* · canonical name `validate_interp_axis`

```typescript
function validateInterpAxis(axis: readonly number[], where: string): void
```

Validate a 1-D interpolation axis (`interp.linear` / `interp.bilinear`):
at least 2 entries, every entry finite, strictly increasing — in that order
(esm-spec §9.2 "Order of the argument checks").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L319)

### `validateSearchsortedTable` {#x-validatesearchsortedtable}

*function* · canonical name `validate_searchsorted_table`

```typescript
function validateSearchsortedTable(xs: readonly number[], where?: string): void
```

Validate a `searchsorted` xs table, in esm-spec §9.2's order: a value that
is not a rank-1 array of numbers is `interp_axis_not_const` (checked at run
time too, since a JavaScript caller can hand over anything), then a NaN entry
is `searchsorted_nan`, then a decreasing pair is `searchsorted_non_monotonic`.
An empty `xs` is a valid rank-1 table (N = 0, trivially non-decreasing), and
every query against it returns 1 (esm-spec §9.2, ruling Q-108).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L222)
