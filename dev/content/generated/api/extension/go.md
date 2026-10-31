---
title: "Go extension seams"
description: "Go's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

289 names.

### `Analysis` {#x-analysis}

*type* · canonical name `analysis`

```go
type Analysis struct {
	ID             string             `json:"id"`
	Description    *string            `json:"description,omitempty"`
	InitialState   map[string]float64 `json:"initial_state,omitempty"`
	Parameters     map[string]float64 `json:"parameters,omitempty"`
	TimeSpan       TimeSpan           `json:"time_span"`
	ParameterSweep *ParameterSweep    `json:"parameter_sweep,omitempty"`
	Plots          []Plot             `json:"plots,omitempty"`
	// ExpressionTemplateImports are raw §9.7.2 import entries injected into the
	// ENCLOSING component's template scope for THIS analysis's run only (esm-spec
	// §9.7.10 form C / §6.7). Authored per-run config (a peer of Parameters), so
	// it DOES survive parse → emit; consumed only by an ephemeral per-run build,
	// which this binding does not perform.
	ExpressionTemplateImports []any `json:"expression_template_imports,omitempty"`
}
```

Analysis is an inline illustrative analysis of how to run a component.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L694) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Analysis)

### `Assertion` {#x-assertion}

*type* · canonical name `assertion`

```go
type Assertion struct {
	Variable  string     `json:"variable"`
	Time      float64    `json:"time"`
	Expected  float64    `json:"expected"`
	Tolerance *Tolerance `json:"tolerance,omitempty"`
	// Coords pins a spatial-point evaluation: index-set/dimension name → numeric
	// coordinate. Mutually exclusive with Reduce (esm-spec §6.6.5).
	Coords map[string]float64 `json:"coords,omitempty"`
	// Reduce collapses the spatial field to a scalar before comparison
	// ("integral"/"mean"/"max"/"min"/"L2_error"/"Linf_error"; esm-spec §6.6.5).
	Reduce string `json:"reduce,omitempty"`
	// Reference is the analytic/precomputed solution required by error-norm
	// reductions: an inline Expression or a from_file shape (esm-spec §6.6.5).
	Reference any `json:"reference,omitempty"`
}
```

Assertion is a single scalar (variable, time, expected) check inside a Test. PDE-aware variants pin a spatial point via `coords` or reduce the field to a scalar via `reduce` (esm-spec §6.6.5); `coords` and `reduce` are mutually exclusive. Error-norm reductions require a `reference` solution. These extra fields round-trip verbatim; this binding does not evaluate them.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L598) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Assertion)

### `BuildReferenceGraphFromModel` {#x-buildreferencegraphfrommodel}

*function* · canonical name `build_reference_graph_from_model`

```go
func BuildReferenceGraphFromModel(model *Model, modelName string, indexSets map[string]IndexSet) (*ReferenceGraph, error)
```

BuildReferenceGraphFromModel is the typed convenience over BuildReferenceGraph: it renders `model` and the document's `index_sets` registry to their raw views and resolves against those.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L878) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#BuildReferenceGraphFromModel)

### `CadenceClassifier` {#x-cadenceclassifier}

*type* · canonical name `cadence_classifier`

```go
type CadenceClassifier struct {
	// contains filtered or unexported fields
}

func (c *CadenceClassifier) CheckExpectCadence() []error

func (c *CadenceClassifier) CheckNoContinuousRelational() []error

func (c *CadenceClassifier) Classify(expr Expression) (Cadence, error)

func (c *CadenceClassifier) LeafSeeds() (map[string]Cadence, error)

func (c *CadenceClassifier) SeedLeaf(leaf Expression) (Cadence, error)
```

CadenceClassifier derives cadence classes for one model. Build it with NewCadenceClassifier; it memoises observed-leaf resolution, so reuse one instance across a model's equations rather than rebuilding it per node.

**Methods**

```go
func (c *CadenceClassifier) CheckExpectCadence() []error
```

CheckExpectCadence walks every equation of the model and asserts that wherever a node carries an `expect_cadence` annotation the derived class agrees (CONFORMANCE\_SPEC §5.7.6 guard 3). The annotation is a checked assertion, not a control input: it changes no semantics, and a disagreement is a defect.

```go
func (c *CadenceClassifier) CheckNoContinuousRelational() []error
```

CheckNoContinuousRelational is §5.7.6 guard 2: a distinct/join/skolem/rank/argmin/argmax node (or a `distinct` aggregate) that classifies CONTINUOUS is rejected — state-dependent topology may not run per step in v1.

```go
func (c *CadenceClassifier) Classify(expr Expression) (Cadence, error)
```

Classify derives an expression's cadence class: for a leaf, its seed; for an operator node, the join over its children (§5.7.3). For a gather `index(A, e…)` the index expressions are classed independently of the array, which is simply what "join over children" already does — no special case is needed, and the stencil split falls out of it.

```go
func (c *CadenceClassifier) LeafSeeds() (map[string]Cadence, error)
```

LeafSeeds returns the derived seed of every declared variable of the model, keyed by name — the observable form of the §5.7.2 table, useful for diagnostics and for a conformance adapter.

```go
func (c *CadenceClassifier) SeedLeaf(leaf Expression) (Cadence, error)
```

SeedLeaf derives a leaf's cadence from its ROLE, per the §5.7.2 seed table.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L113) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CadenceClassifier)

### `CadenceConst` {#x-cadenceconst}

*constant* · canonical name `cadence_const`

```go
const CadenceConst Cadence = iota
```

CadenceConst never changes: evaluated once and folded into the artifact.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L37) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CadenceConst)

### `CadenceContinuous` {#x-cadencecontinuous}

*constant* · canonical name `cadence_continuous`

```go
const CadenceContinuous
```

CadenceContinuous changes every step: evaluated on every RHS call.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L42) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CadenceContinuous)

### `CadenceDiscrete` {#x-cadencediscrete}

*constant* · canonical name `cadence_discrete`

```go
const CadenceDiscrete
```

CadenceDiscrete changes only at discrete events, and is piecewise-constant between them: evaluated at setup and on each refresh, memoized between.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L40) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CadenceDiscrete)

### `CallbackCoupling` {#x-callbackcoupling}

*type* · canonical name `callback_coupling`

```go
type CallbackCoupling struct {
	Type        string         `json:"type"` // "callback"
	CallbackID  string         `json:"callback_id"`
	Config      map[string]any `json:"config,omitempty"`
	Description *string        `json:"description,omitempty"`
}

func (c CallbackCoupling) CouplingType() string
```

CallbackCoupling represents callback-based coupling

**Methods**

```go
func (c CallbackCoupling) CouplingType() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L955) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CallbackCoupling)

### `CodeAmbiguousOutputName` {#x-codeambiguousoutputname}

*constant* · canonical name `code_ambiguous_output_name`

```go
const CodeAmbiguousOutputName = "ambiguous_output_name"
```

CodeAmbiguousOutputName: an output name that matches no variable exactly and whose last dotted segment is shared by more than one variable (CONFORMANCE\_SPEC §5.17.4). This binding has no output derivation; the constant exists because the code vocabulary is uniform across bindings.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L134) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeAmbiguousOutputName)

### `CodeAmbiguousSubsystemRef` {#x-codeambiguoussubsystemref}

*constant* · canonical name `code_ambiguous_subsystem_ref`

```go
const CodeAmbiguousSubsystemRef = "ambiguous_subsystem_ref"
```

CodeAmbiguousSubsystemRef: a subsystem `ref` resolves to a file holding other than exactly one top-level system; §4.7 requires exactly one.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L282) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeAmbiguousSubsystemRef)

### `CodeApplyExpressionTemplateBindingsMismatch` {#x-codeapplyexpressiontemplatebindingsmismatch}

*constant* · canonical name `code_apply_expression_template_bindings_mismatch`

```go
const CodeApplyExpressionTemplateBindingsMismatch = "apply_expression_template_bindings_mismatch"
```

CodeApplyExpressionTemplateBindingsMismatch: the supplied `bindings` do not match the template's declared parameters — a missing parameter, or a binding naming a parameter the template does not declare.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L111) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeApplyExpressionTemplateBindingsMismatch)

### `CodeApplyExpressionTemplateInvalidDeclaration` {#x-codeapplyexpressiontemplateinvaliddeclaration}

*constant* · canonical name `code_apply_expression_template_invalid_declaration`

```go
const CodeApplyExpressionTemplateInvalidDeclaration = "apply_expression_template_invalid_declaration"
```

CodeApplyExpressionTemplateInvalidDeclaration: an `apply_expression_template` node is structurally malformed — a missing or non-string `template`, a `bindings` payload that is not an object, or a binding entry whose key is not a non-empty string.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L103) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeApplyExpressionTemplateInvalidDeclaration)

### `CodeApplyExpressionTemplateRecursiveBody` {#x-codeapplyexpressiontemplaterecursivebody}

*constant* · canonical name `code_apply_expression_template_recursive_body`

```go
const CodeApplyExpressionTemplateRecursiveBody = "apply_expression_template_recursive_body"
```

CodeApplyExpressionTemplateRecursiveBody: a template's body applies the template itself, directly or through a cycle of applications.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L114) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeApplyExpressionTemplateRecursiveBody)

### `CodeApplyExpressionTemplateUnknownTemplate` {#x-codeapplyexpressiontemplateunknowntemplate}

*constant* · canonical name `code_apply_expression_template_unknown_template`

```go
const CodeApplyExpressionTemplateUnknownTemplate = "apply_expression_template_unknown_template"
```

CodeApplyExpressionTemplateUnknownTemplate: an `apply_expression_template` names a template neither declared locally nor exported by any import in scope.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L107) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeApplyExpressionTemplateUnknownTemplate)

### `CodeApplyExpressionTemplateVersionTooOld` {#x-codeapplyexpressiontemplateversiontooold}

*constant* · canonical name `code_apply_expression_template_version_too_old`

```go
const CodeApplyExpressionTemplateVersionTooOld = "apply_expression_template_version_too_old"
```

CodeApplyExpressionTemplateVersionTooOld: a file declaring esm &lt; 0.4.0 carries `expression_templates` or `apply_expression_template`.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L144) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeApplyExpressionTemplateVersionTooOld)

### `CodeArrayShapeMismatch` {#x-codearrayshapemismatch}

*constant* · canonical name `code_array_shape_mismatch`

```go
const CodeArrayShapeMismatch = "array_shape_mismatch"
```

CodeArrayShapeMismatch: an operand of a bare array-level expression carries a declared index set that the expression's result is not shaped over, so there is no axis to align it to (esm-spec §4.3.4, §9.6.6; CONFORMANCE\_SPEC §7.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_array_shapes.go#L54) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeArrayShapeMismatch)

### `CodeCadenceContinuousRelational` {#x-codecadencecontinuousrelational}

*constant* · canonical name `code_cadence_continuous_relational`

```go
const CodeCadenceContinuousRelational = "cadence_continuous_relational"
```

Cadence-partition diagnostic codes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L107) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCadenceContinuousRelational)

### `CodeCadenceExpectMismatch` {#x-codecadenceexpectmismatch}

*constant* · canonical name `code_cadence_expect_mismatch`

```go
const CodeCadenceExpectMismatch = "cadence_expect_mismatch"
```

Cadence-partition diagnostic codes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L106) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCadenceExpectMismatch)

### `CodeCadenceObservedCycle` {#x-codecadenceobservedcycle}

*constant* · canonical name `code_cadence_observed_cycle`

```go
const CodeCadenceObservedCycle = "cadence_observed_cycle"
```

CodeCadenceObservedCycle is the CADENCE-pass sighting of the same defect esm-spec §4.9.6 gives the structural validator: a dependency cycle among a model's observed definitions, with the §4.3.1.1 recurrence self-edge exempted on candidacy. It is a \*CadenceError raised while classifying, so `Validate` never sees it; the validator-track counterpart is validate\_observed\_cycle.go's `observed_cycle`, which is what tests/invalid/expected\_errors.json pins. Keep the two in step — in particular the self-edge gate, which both take from recurrenceCandidateVars.

Cadence-partition diagnostic codes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L105) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCadenceObservedCycle)

### `CodeCallbackUnregistered` {#x-codecallbackunregistered}

*constant* · canonical name `code_callback_unregistered`

```go
const CodeCallbackUnregistered = "callback_unregistered"
```

CodeCallbackUnregistered: an equation reads a `callback` coupling variable and no callback supplies it at construction (esm-spec §9.6.6). Go does not simulate, so it never raises this.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L584) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCallbackUnregistered)

### `CodeClosedFunctionArity` {#x-codeclosedfunctionarity}

*constant* · canonical name `code_closed_function_arity`

```go
const CodeClosedFunctionArity = "closed_function_arity"
```

CodeClosedFunctionArity: a closed function received the wrong number or kind of arguments, or an empty table.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L507) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeClosedFunctionArity)

### `CodeClosedFunctionOverflow` {#x-codeclosedfunctionoverflow}

*constant* · canonical name `code_closed_function_overflow`

```go
const CodeClosedFunctionOverflow = "closed_function_overflow"
```

CodeClosedFunctionOverflow: an integer-valued result overflows Int32.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L509) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeClosedFunctionOverflow)

### `CodeCompilerRefusedRule` {#x-codecompilerrefusedrule}

*constant* · canonical name `code_compiler_refused_rule`

```go
const CodeCompilerRefusedRule = "compiler_refused_rule"
```

CodeCompilerRefusedRule: the chosen compiler cannot run this document. Raised at build, naming the compiler, the rule (an equation or an observed, component-qualified) and the reason.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L607) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCompilerRefusedRule)

### `CodeCompilerUnavailable` {#x-codecompilerunavailable}

*constant* · canonical name `code_compiler_unavailable`

```go
const CodeCompilerUnavailable = "compiler_unavailable"
```

CodeCompilerUnavailable: the named compiler is in the vocabulary, but this binding, build or process cannot provide it; the message names what to load or build. Never answered by running a different compiler (esm-libraries-spec §2.5.10).

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L603) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCompilerUnavailable)

### `CodeCompilerUnknown` {#x-codecompilerunknown}

*constant* · canonical name `code_compiler_unknown`

```go
const CodeCompilerUnknown = "compiler_unknown"
```

CodeCompilerUnknown: `esm_problem`'s `compiler` option named a value outside the closed vocabulary of API\_SPEC §5.8 (`interpreter`, `native`, `xla`, `mtk`, `sympy`).

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L598) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCompilerUnknown)

### `CodeConstUnitsVersionTooOld` {#x-codeconstunitsversiontooold}

*constant* · canonical name `code_const_units_version_too_old`

```go
const CodeConstUnitsVersionTooOld = "const_units_version_too_old"
```

CodeConstUnitsVersionTooOld: a document declaring esm &lt; 1.2.0 carries `units` on an expression node.

--- Diagnostic codes: §4.8.5 declared units on a `const` node (raised via newETErr from units.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L215) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeConstUnitsVersionTooOld)

### `CodeCoupleMultiplicativeNoTendency` {#x-codecouplemultiplicativenotendency}

*constant* · canonical name `code_couple_multiplicative_no_tendency`

```go
const CodeCoupleMultiplicativeNoTendency = "couple_multiplicative_no_tendency"
```

CodeCoupleMultiplicativeNoTendency: a `couple` connector equation applies the `multiplicative` transform to a `to` target that has no `D(to)` equation in the flattened system — a parameter, an observed, an algebraic unknown, or an undefined name. Both esm-spec §10.3 and §4.7.2 define `multiplicative` against the target's EXISTING ODE right-hand side, so there is nothing to multiply and the operation has no meaning. Silently dropping the connector equation — what this binding did before — is the one outcome a coupling mis-specification must not have: the document declares a coupling and the flattened system carries no trace of it.

`additive` deliberately has NO counterpart code: zero is the additive identity, so an additive term against an absent tendency simply becomes the tendency. There is no multiplicative identity that would do the same.

--- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector semantics (raised from flatten.go's applyCouple). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L234) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCoupleMultiplicativeNoTendency)

### `CodeCouplingEdgeUnknownRole` {#x-codecouplingedgeunknownrole}

*constant* · canonical name `code_coupling_edge_unknown_role`

```go
const CodeCouplingEdgeUnknownRole = "coupling_edge_unknown_role"
```

CodeCouplingEdgeUnknownRole: a coupling edge inside the library references a role name the library does not declare.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L204) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingEdgeUnknownRole)

### `CodeCouplingImportBindNotAComponent` {#x-codecouplingimportbindnotacomponent}

*constant* · canonical name `code_coupling_import_bind_not_a_component`

```go
const CodeCouplingImportBindNotAComponent = "coupling_import_bind_not_a_component"
```

CodeCouplingImportBindNotAComponent: a role binding names something that is not a component of the importing document.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L201) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingImportBindNotAComponent)

### `CodeCouplingImportNotLibrary` {#x-codecouplingimportnotlibrary}

*constant* · canonical name `code_coupling_import_not_library`

```go
const CodeCouplingImportNotLibrary = "coupling_import_not_library"
```

CodeCouplingImportNotLibrary: a `coupling_import` resolves to a file that is not a coupling library.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L192) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingImportNotLibrary)

### `CodeCouplingImportRoleUnbound` {#x-codecouplingimportroleunbound}

*constant* · canonical name `code_coupling_import_role_unbound`

```go
const CodeCouplingImportRoleUnbound = "coupling_import_role_unbound"
```

CodeCouplingImportRoleUnbound: a role the imported library declares is left unbound by the importing document.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L198) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingImportRoleUnbound)

### `CodeCouplingImportUnknownRole` {#x-codecouplingimportunknownrole}

*constant* · canonical name `code_coupling_import_unknown_role`

```go
const CodeCouplingImportUnknownRole = "coupling_import_unknown_role"
```

CodeCouplingImportUnknownRole: a `coupling_import` binds a role the imported library does not declare.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L195) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingImportUnknownRole)

### `CodeCouplingImportUnresolved` {#x-codecouplingimportunresolved}

*constant* · canonical name `code_coupling_import_unresolved`

```go
const CodeCouplingImportUnresolved = "coupling_import_unresolved"
```

CodeCouplingImportUnresolved: a `coupling_import` names a file that does not exist, is not readable, or was never resolved before use.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L189) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingImportUnresolved)

### `CodeCouplingLibraryIllegalPayload` {#x-codecouplinglibraryillegalpayload}

*constant* · canonical name `code_coupling_library_illegal_payload`

```go
const CodeCouplingLibraryIllegalPayload = "coupling_library_illegal_payload"
```

CodeCouplingLibraryIllegalPayload: a coupling library file carries a payload §10.11 forbids there (a component, a non-`coupling_roles` block, or a role entry of the wrong shape).

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L183) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingLibraryIllegalPayload)

### `CodeCouplingLibraryNestedImport` {#x-codecouplinglibrarynestedimport}

*constant* · canonical name `code_coupling_library_nested_import`

```go
const CodeCouplingLibraryNestedImport = "coupling_library_nested_import"
```

CodeCouplingLibraryNestedImport: a coupling library itself declares a coupling `import`; §10.11 admits no nesting.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L186) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingLibraryNestedImport)

### `CodeCouplingRoleUnused` {#x-codecouplingroleunused}

*constant* · canonical name `code_coupling_role_unused`

```go
const CodeCouplingRoleUnused = "coupling_role_unused"
```

CodeCouplingRoleUnused: a role the library declares is referenced by none of its coupling edges, so binding it could have no effect.

--- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling\_import (raised via newETErr from coupling\_imports.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L207) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeCouplingRoleUnused)

### `CodeDataSourceUnbound` {#x-codedatasourceunbound}

*constant* · canonical name `code_data_source_unbound`

```go
const CodeDataSourceUnbound = "data_source_unbound"
```

CodeDataSourceUnbound: a data-fed parameter (an `update` of `kind: "data"`, esm-spec §5.4/§8.5) reached a build with nothing bound to it -- no provider, no loaded array, no caller-supplied `p` value (esm-spec §9.6.6, CONFORMANCE\_SPEC §5.46). The complement of ErrorDataSourceUndefined, which this binding DOES raise: that is the validator's finding about a source name resolving to nothing, this is the build's finding about a source that resolves and that nothing supplied data for. Go does not simulate, so nothing here raises it; the constant keeps the §9.6.6 vocabulary uniform.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L594) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeDataSourceUnbound)

### `CodeDerivedIndexSetUnmaterialized` {#x-codederivedindexsetunmaterialized}

*constant* · canonical name `code_derived_index_set_unmaterialized`

```go
const CodeDerivedIndexSetUnmaterialized = "derived_index_set_unmaterialized"
```

CodeDerivedIndexSetUnmaterialized: an expression ranges over a `kind: "derived"` index set whose producer could not be materialized at build (esm-spec §9.6.6). Registered for the cross-binding vocabulary; this binding has no simulator, so nothing here raises it.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L576) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeDerivedIndexSetUnmaterialized)

### `CodeDomainUnitMismatch` {#x-codedomainunitmismatch}

*constant* · canonical name `code_domain_unit_mismatch`

```go
const CodeDomainUnitMismatch = "domain_unit_mismatch"
```

CodeDomainUnitMismatch: an `identity`-transform `variable_map` coupling whose `from` and `to` variables carry declared, non-empty, and DIFFERENT units (esm-spec §4.7.6). Mirrors the flatten-time DomainUnitMismatch the evaluating bindings raise (Julia \_check\_variable\_map\_units, Python \_check\_variable\_map\_units, Rust FlattenError::DomainUnitMismatch).

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L48) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeDomainUnitMismatch)

### `CodeDuplicateReactionSpecies` {#x-codeduplicatereactionspecies}

*constant* · canonical name `code_duplicate_reaction_species`

```go
const CodeDuplicateReactionSpecies = "duplicate_reaction_species"
```

CodeDuplicateReactionSpecies is a warning-level code: a species appears more than once in a reaction's substrate/product list. Advisory only — it does not invalidate the document.

--- Diagnostic codes: structural validation, peers of the Error\* block above. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L415) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeDuplicateReactionSpecies)

### `CodeEditEntityNotFound` {#x-codeeditentitynotfound}

*constant* · canonical name `code_edit_entity_not_found`

```go
const CodeEditEntityNotFound = "entity_not_found"
```

CodeEditEntityNotFound: an edit names a variable, equation, reaction, species, event, coupling entry, or component that does not exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L59) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeEditEntityNotFound)

### `CodeEditInvalidOperation` {#x-codeeditinvalidoperation}

*constant* · canonical name `code_edit_invalid_operation`

```go
const CodeEditInvalidOperation = "invalid_operation"
```

CodeEditInvalidOperation: an edit is refused for a reason other than the two above (e.g. it would empty a collection the schema requires to be non-empty).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L66) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeEditInvalidOperation)

### `CodeEditVariableInUse` {#x-codeeditvariableinuse}

*constant* · canonical name `code_edit_variable_in_use`

```go
const CodeEditVariableInUse = "variable_in_use"
```

CodeEditVariableInUse: a removal would strand a live reference to the removed name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L62) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeEditVariableInUse)

### `CodeElementTypeUncarried` {#x-codeelementtypeuncarried}

*constant* · canonical name `code_element_type_uncarried`

```go
const CodeElementTypeUncarried = "element_type_uncarried"
```

CodeElementTypeUncarried: a declared working precision reaches a construct that cannot carry it (esm-spec §4.7 "Working precision crosses a mount", §11.3.1) — a mounted leaf's `domain.element_type` that must be written onto a reaction system, whose species and parameters have no per-variable `element_type`.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L317) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeElementTypeUncarried)

### `CodeEnumDuplicateValue` {#x-codeenumduplicatevalue}

*constant* · canonical name `code_enum_duplicate_value`

```go
const CodeEnumDuplicateValue = "enum_duplicate_value"
```

CodeEnumDuplicateValue: two symbols of ONE `enums` entry map to the same integer (esm-spec §9.3). Raised on the block itself, whether or not an `enum` op names either symbol; values MAY coincide across enums.

--- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError from lower\_enums.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L555) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeEnumDuplicateValue)

### `CodeGeometryManifoldInvalid` {#x-codegeometrymanifoldinvalid}

*constant* · canonical name `code_geometry_manifold_invalid`

```go
const CodeGeometryManifoldInvalid = "geometry_manifold_invalid"
```

CodeGeometryManifoldInvalid: a geometry kernel declares a manifold that is not one of the spec's manifold kinds, or one inconsistent with the coordinates it is given.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L141) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeGeometryManifoldInvalid)

### `CodeIndexedDefinitionUnsupportedForm` {#x-codeindexeddefinitionunsupportedform}

*constant* · canonical name `code_indexed_definition_unsupported_form`

```go
const CodeIndexedDefinitionUnsupportedForm = "indexed_definition_unsupported_form"
```

CodeIndexedDefinitionUnsupportedForm: a bare-index observed definition `index(V, k…) ~ rhs` outside the runnable form (the RHS is not a `faq` whose `output_idx` names the subscripts in order), refused when a simulating binding builds the model. Go does not simulate, so it never raises this; the constant exists because the code table is cross-language uniform.

--- Diagnostic codes: running an arrayed definition (esm-spec §6.3.1). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L328) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeIndexedDefinitionUnsupportedForm)

### `CodeInterpAxisLengthMismatch` {#x-codeinterpaxislengthmismatch}

*constant* · canonical name `code_interp_axis_length_mismatch`

```go
const CodeInterpAxisLengthMismatch = "interp_axis_length_mismatch"
```

CodeInterpAxisLengthMismatch: an `interp` axis length does not match the table's.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L520) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInterpAxisLengthMismatch)

### `CodeInterpAxisNotConst` {#x-codeinterpaxisnotconst}

*constant* · canonical name `code_interp_axis_not_const`

```go
const CodeInterpAxisNotConst = "interp_axis_not_const"
```

CodeInterpAxisNotConst: an axis of `interp.linear` / `interp.bilinear`, or the `xs` of `interp.searchsorted`, is not a rank-1 `const`-op array — a variable reference, a non-`const` expression, or a `const` whose value is a scalar or a nested array (esm-spec §9.2, ruling Q-108). Checked before CodeSearchsortedNaN and CodeSearchsortedNonMonotonic.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L530) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInterpAxisNotConst)

### `CodeInterpAxisTooShort` {#x-codeinterpaxistooshort}

*constant* · canonical name `code_interp_axis_too_short`

```go
const CodeInterpAxisTooShort = "interp_axis_too_short"
```

CodeInterpAxisTooShort: an `interp` axis has fewer than two points.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L524) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInterpAxisTooShort)

### `CodeInterpNaNInAxis` {#x-codeinterpnaninaxis}

*constant* · canonical name `code_interp_na_n_in_axis`

```go
const CodeInterpNaNInAxis = "interp_nan_in_axis"
```

CodeInterpNaNInAxis: an `interp` axis contains a NaN.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L522) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInterpNaNInAxis)

### `CodeInterpNonMonotonicAxis` {#x-codeinterpnonmonotonicaxis}

*constant* · canonical name `code_interp_non_monotonic_axis`

```go
const CodeInterpNonMonotonicAxis = "interp_non_monotonic_axis"
```

CodeInterpNonMonotonicAxis: an `interp` axis is not strictly increasing.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L517) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInterpNonMonotonicAxis)

### `CodeInvalidBroadcastFn` {#x-codeinvalidbroadcastfn}

*constant* · canonical name `code_invalid_broadcast_fn`

```go
const CodeInvalidBroadcastFn = "invalid_broadcast_fn"
```

CodeInvalidBroadcastFn: a `broadcast` node's `fn` is absent, does not name a scalar operator, or is applied to an argument count that operator's §4.2 arity does not admit (esm-spec §4.3.4, §9.6.6). The value analogue of `unknown_closed_function`: `broadcast` is the one op whose OPERATOR is carried as data, so no `op`-keyed check reaches it, and an unchecked `fn` was discarded silently rather than failing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/op_registry.go#L44) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInvalidBroadcastFn)

### `CodeInvalidEnumArg` {#x-codeinvalidenumarg}

*constant* · canonical name `code_invalid_enum_arg`

```go
const CodeInvalidEnumArg = "invalid_enum_arg"
```

CodeInvalidEnumArg: an `enum` node argument is not a string.

--- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError from lower\_enums.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L551) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInvalidEnumArg)

### `CodeInvalidEnumArity` {#x-codeinvalidenumarity}

*constant* · canonical name `code_invalid_enum_arity`

```go
const CodeInvalidEnumArity = "invalid_enum_arity"
```

CodeInvalidEnumArity: an `enum` node does not carry exactly two arguments.

--- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError from lower\_enums.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L549) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeInvalidEnumArity)

### `CodeJoinKeyInvalidType` {#x-codejoinkeyinvalidtype}

*constant* · canonical name `code_join_key_invalid_type`

```go
const CodeJoinKeyInvalidType = "join_key_invalid_type"
```

CodeJoinKeyInvalidType: a value-equality join key column draws from a categorical index set whose `members` contain a float (not portably equality-comparable across bindings) or a null (unmatchable as a key). RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1; CONFORMANCE\_SPEC §5.5.1.

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L33) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeJoinKeyInvalidType)

### `CodeJoinSideAmbiguous` {#x-codejoinsideambiguous}

*constant* · canonical name `code_join_side_ambiguous`

```go
const CodeJoinSideAmbiguous = "join_side_ambiguous"
```

CodeJoinSideAmbiguous: an `on` key for which the DOCUMENT does not determine a range symbol -- its index set is drawn by more than one of the node's ranges and the clause names no `syms` (CONFORMANCE\_SPEC §5.5.8).

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L38) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeJoinSideAmbiguous)

### `CodeJoinSymsUnknownSymbol` {#x-codejoinsymsunknownsymbol}

*constant* · canonical name `code_join_syms_unknown_symbol`

```go
const CodeJoinSymsUnknownSymbol = "join_syms_unknown_symbol"
```

CodeJoinSymsUnknownSymbol: a `join.syms` entry that is not a range symbol of the node (CONFORMANCE\_SPEC §5.5.8).

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L42) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeJoinSymsUnknownSymbol)

### `CodeMakearrayRegionInverted` {#x-codemakearrayregioninverted}

*constant* · canonical name `code_makearray_region_inverted`

```go
const CodeMakearrayRegionInverted = "makearray_region_inverted"
```

CodeMakearrayRegionInverted: a `makearray` region's stop precedes its start, so the region denotes no cells (esm-spec §4.3.5).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L137) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMakearrayRegionInverted)

### `CodeMetaparamNameConflict` {#x-codemetaparamnameconflict}

*constant* · canonical name `code_metaparam_name_conflict`

```go
const CodeMetaparamNameConflict = "metaparameter_name_conflict"
```

CodeMetaparamNameConflict: a metaparameter name collides with a name already bound in the scope the template expands into (esm-spec §9.6.6).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L92) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMetaparamNameConflict)

### `CodeMetaparamTypeError` {#x-codemetaparamtypeerror}

*constant* · canonical name `code_metaparam_type_error`

```go
const CodeMetaparamTypeError = "metaparameter_type_error"
```

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L37) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMetaparamTypeError)

### `CodeMetaparamUnbound` {#x-codemetaparamunbound}

*constant* · canonical name `code_metaparam_unbound`

```go
const CodeMetaparamUnbound = "metaparameter_unbound"
```

CodeMetaparamUnbound: a metaparameter reachable in an expanded template body has no binding — neither from the `metaparameters` block nor from an import's `rebind` (esm-spec §9.6.6).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L89) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMetaparamUnbound)

### `CodeMissingDataSourceKind` {#x-codemissingdatasourcekind}

*constant* · canonical name `code_missing_data_source_kind`

```go
const CodeMissingDataSourceKind = "missing_data_source_kind"
```

A data source entry requires `kind` and `source.url_template`. A source declares no variables; the file variable and units are checked on the consuming PARAMETER instead -- by the schema, since both are required there.

--- Diagnostic codes: structural validation, peers of the Error\* block above. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L421) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMissingDataSourceKind)

### `CodeMissingDataSourceURLTemplate` {#x-codemissingdatasourceurltemplate}

*constant* · canonical name `code_missing_data_source_url_template`

```go
const CodeMissingDataSourceURLTemplate = "missing_data_source_url_template"
```

--- Diagnostic codes: structural validation, peers of the Error\* block above. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L422) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMissingDataSourceURLTemplate)

### `CodeMountFormUnsupported` {#x-codemountformunsupported}

*constant* · canonical name `code_mount_form_unsupported`

```go
const CodeMountFormUnsupported = "mount_form_unsupported"
```

CodeMountFormUnsupported: a §4.7 `{ref}` mount at a form this binding does not implement — here, a top-level `reaction_systems.<k>` `{ref}` (esm-spec §4.7 "Two mount forms, one mechanism"). Refused at load, pointing at the entry, rather than decoded as an empty reaction system.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L311) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeMountFormUnsupported)

### `CodeOperatorComposeAmbiguousBareName` {#x-codeoperatorcomposeambiguousbarename}

*constant* · canonical name `code_operator_compose_ambiguous_bare_name`

```go
const CodeOperatorComposeAmbiguousBareName = "operator_compose_ambiguous_bare_name"
```

CodeOperatorComposeAmbiguousBareName: the bare-name fallback (§4.7.1 step 3) would unify two STATE variables. Each carries its own INITIAL CONDITION and the merge keeps only one, so the choice decides what the flattened system integrates from — and the document, which bound them on a shared local name alone, has not expressed it. Deciding it silently is how flipping an entry's `systems` order came to change the answer. A match where only ONE side is a state is not ambiguous: the state owns it.

--- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector semantics (raised from flatten.go's applyCouple). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L259) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeOperatorComposeAmbiguousBareName)

### `CodeOperatorComposeNoMerge` {#x-codeoperatorcomposenomerge}

*constant* · canonical name `code_operator_compose_no_merge`

```go
const CodeOperatorComposeNoMerge = "operator_compose_no_merge"
```

CodeOperatorComposeNoMerge is an ERROR (esm-libraries-spec §4.7.1 step 5): an `operator_compose` entry merged NONE of the equations Systems\[1\] authored, which makes it indistinguishable from an entry that is not there — the operator integrates a private decoupled system from its own defaults, the other system receives no contribution, and the only evidence is a state count one too high. An operator that genuinely contributes only states of its own declares that with `require_match: false` and is then permitted.

--- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector semantics (raised from flatten.go's applyCouple). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L244) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeOperatorComposeNoMerge)

### `CodeOperatorComposePartialMerge` {#x-codeoperatorcomposepartialmerge}

*constant* · canonical name `code_operator_compose_partial_merge`

```go
const CodeOperatorComposePartialMerge = "operator_compose_partial_merge"
```

CodeOperatorComposePartialMerge is WARNING-level: some but not all of Systems\[1\]'s equations landed. Unlike a zero merge this is indistinguishable from an operator that legitimately contributes states of its own ALONGSIDE the ones it does merge, so the format cannot call it a defect; an author who knows better says so with `require_match`.

--- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector semantics (raised from flatten.go's applyCouple). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L250) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeOperatorComposePartialMerge)

### `CodeOperatorComposeRequireMatchUnmatched` {#x-codeoperatorcomposerequirematchunmatched}

*constant* · canonical name `code_operator_compose_require_match_unmatched`

```go
const CodeOperatorComposeRequireMatchUnmatched = "operator_compose_require_match_unmatched"
```

CodeOperatorComposeRequireMatchUnmatched: an `operator_compose` entry declared `require_match: true` and one of Systems\[1\]'s equations found no equation of Systems\[0\] to land on (esm-libraries-spec §4.7.1 step 5). A PARTIAL match fails too: there is no "some is enough" reading an author could rely on — the seven-of-twelve-species case is exactly the defect the flag exists to catch. Refused at FLATTEN, not at validate: the document is schema-valid and structurally valid, and only the merge knows the answer.

--- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector semantics (raised from flatten.go's applyCouple). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L268) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeOperatorComposeRequireMatchUnmatched)

### `CodeRaggedValuesNotGathered` {#x-coderaggedvaluesnotgathered}

*constant* · canonical name `code_ragged_values_not_gathered`

```go
const CodeRaggedValuesNotGathered = "ragged_values_not_gathered"
```

CodeRaggedValuesNotGathered: a `faq` that is not a value-invention node ranges over a `kind: "ragged"` index set, but its body never reads that set's `values` array. The range binds the POSITION k in 1..offsets\[parent\], not a member, so the body reads positions where the author meant members (esm-spec §4.3.1 "Ragged ranges").

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L60) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRaggedValuesNotGathered)

### `CodeRangeBoxInvalid` {#x-coderangeboxinvalid}

*constant* · canonical name `code_range_box_invalid`

```go
const CodeRangeBoxInvalid = "range_box_invalid"
```

CodeRangeBoxInvalid: a malformed decomposition, tile box or lane-set list.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L620) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRangeBoxInvalid)

### `CodeRangeGlobalLocality` {#x-coderangegloballocality}

*constant* · canonical name `code_range_global_locality`

```go
const CodeRangeGlobalLocality = "range_global_locality"
```

CodeRangeGlobalLocality: a tile restriction or halo report meets a 0-d state write, or a contraction, scan or data-dependent gather along a decomposed axis.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L615) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRangeGlobalLocality)

### `CodeRangeHaloInsufficient` {#x-coderangehaloinsufficient}

*constant* · canonical name `code_range_halo_insufficient`

```go
const CodeRangeHaloInsufficient = "range_halo_insufficient"
```

CodeRangeHaloInsufficient: a tile reads an in-domain cell outside its storage box with no periodic image in it (API\_SPEC §5.8, "Range-restricted right-hand sides").

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L611) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRangeHaloInsufficient)

### `CodeRangeSelectionWritesIncomplete` {#x-coderangeselectionwritesincomplete}

*constant* · canonical name `code_range_selection_writes_incomplete`

```go
const CodeRangeSelectionWritesIncomplete = "range_selection_writes_incomplete"
```

CodeRangeSelectionWritesIncomplete: an operator selection's `writes` omits a variable one of its selected contributions writes.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L618) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRangeSelectionWritesIncomplete)

### `CodeRefCycle` {#x-coderefcycle}

*constant* · canonical name `code_ref_cycle`

```go
const CodeRefCycle = "E_REF_CYCLE"
```

CodeRefCycle: a directed cycle exists among the reference edges.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L63) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRefCycle)

### `CodeRefDuplicateNodeID` {#x-coderefduplicatenodeid}

*constant* · canonical name `code_ref_duplicate_node_id`

```go
const CodeRefDuplicateNodeID = "E_REF_DUPLICATE_NODE_ID"
```

CodeRefDuplicateNodeID: two expression nodes in the same document share an explicit `id`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L58) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRefDuplicateNodeID)

### `CodeRefUndeclaredIndexSet` {#x-coderefundeclaredindexset}

*constant* · canonical name `code_ref_undeclared_index_set`

```go
const CodeRefUndeclaredIndexSet = "E_REF_UNDECLARED_INDEX_SET"
```

CodeRefUndeclaredIndexSet: an undeclared name in a `ranges[*].from`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L52) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRefUndeclaredIndexSet)

### `CodeRefUnknownFAQNode` {#x-coderefunknownfaqnode}

*constant* · canonical name `code_ref_unknown_faq_node`

```go
const CodeRefUnknownFAQNode = "E_REF_UNKNOWN_FAQ_NODE"
```

CodeRefUnknownFAQNode: a `kind:"derived"` index set's `from_faq` names no node id in the document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L55) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRefUnknownFAQNode)

### `CodeRefUnresolvedJoinFactor` {#x-coderefunresolvedjoinfactor}

*constant* · canonical name `code_ref_unresolved_join_factor`

```go
const CodeRefUnresolvedJoinFactor = "E_REF_UNRESOLVED_JOIN_FACTOR"
```

CodeRefUnresolvedJoinFactor: a `join.on` factor reference names nothing in the node's scope.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L61) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRefUnresolvedJoinFactor)

### `CodeRelationalNodeInContinuous` {#x-coderelationalnodeincontinuous}

*constant* · canonical name `code_relational_node_in_continuous`

```go
const CodeRelationalNodeInContinuous = "relational_node_in_continuous"
```

CodeRelationalNodeInContinuous: a relational / value-invention aggregate (`distinct: true` under `bool_and_or`) whose `key`/`expr` reads a declared STATE variable, so the cadence partition classes the node CONTINUOUS and guard 2 (no relational engine on the hot path) forbids it. RFC §6.1, CONFORMANCE\_SPEC §5.7.6 guard 2.

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L54) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRelationalNodeInContinuous)

### `CodeRewriteRuleNonterminating` {#x-coderewriterulenonterminating}

*constant* · canonical name `code_rewrite_rule_nonterminating`

```go
const CodeRewriteRuleNonterminating = "rewrite_rule_nonterminating"
```

CodeRewriteRuleNonterminating: the rewrite fixpoint did not converge within MAX\_REWRITE\_PASSES passes (esm-spec §9.6.3).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L147) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeRewriteRuleNonterminating)

### `CodeSearchsortedNaN` {#x-codesearchsortednan}

*constant* · canonical name `code_searchsorted_na_n`

```go
const CodeSearchsortedNaN = "searchsorted_nan"
```

CodeSearchsortedNaN: a `searchsorted` table contains a NaN. Checked before CodeSearchsortedNonMonotonic (esm-spec §9.2).

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L515) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSearchsortedNaN)

### `CodeSearchsortedNonMonotonic` {#x-codesearchsortednonmonotonic}

*constant* · canonical name `code_searchsorted_non_monotonic`

```go
const CodeSearchsortedNonMonotonic = "searchsorted_non_monotonic"
```

CodeSearchsortedNonMonotonic: a `searchsorted` table is not non-decreasing.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L512) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSearchsortedNonMonotonic)

### `CodeSolverExternalUnresolved` {#x-codesolverexternalunresolved}

*constant* · canonical name `code_solver_external_unresolved`

```go
const CodeSolverExternalUnresolved = "solver_external_unresolved"
```

CodeSolverExternalUnresolved: `solver.external` carries `${` (esm-spec §2.2.6).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L156) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSolverExternalUnresolved)

### `CodeSolverExternalVersionTooOld` {#x-codesolverexternalversiontooold}

*constant* · canonical name `code_solver_external_version_too_old`

```go
const CodeSolverExternalVersionTooOld = "solver_external_version_too_old"
```

CodeSolverExternalVersionTooOld: `solver.external` in a file declaring esm &lt; 1.3.0 (esm-spec §2.2.4).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L153) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSolverExternalVersionTooOld)

### `CodeSolverTimeSpanInvalid` {#x-codesolvertimespaninvalid}

*constant* · canonical name `code_solver_time_span_invalid`

```go
const CodeSolverTimeSpanInvalid = "solver_time_span_invalid"
```

CodeSolverTimeSpanInvalid: `solver.time_span` does not describe an interval -- `end` not after `start`, a timestamp naming no calendar day, or an unreadable time origin (esm-spec §2.2.7).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L163) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSolverTimeSpanInvalid)

### `CodeSolverTimeSpanVersionTooOld` {#x-codesolvertimespanversiontooold}

*constant* · canonical name `code_solver_time_span_version_too_old`

```go
const CodeSolverTimeSpanVersionTooOld = "solver_time_span_version_too_old"
```

CodeSolverTimeSpanVersionTooOld: `solver.time_span` in a file declaring esm &lt; 1.3.0 (esm-spec §2.2.4).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L159) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSolverTimeSpanVersionTooOld)

### `CodeSolverVersionTooOld` {#x-codesolverversiontooold}

*constant* · canonical name `code_solver_version_too_old`

```go
const CodeSolverVersionTooOld = "solver_version_too_old"
```

CodeSolverVersionTooOld: a top-level `solver` block in a file declaring esm &lt; 1.1.0 (esm-spec §2.2.4).

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L150) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSolverVersionTooOld)

### `CodeSubsystemIndexSetConflict` {#x-codesubsystemindexsetconflict}

*constant* · canonical name `code_subsystem_index_set_conflict`

```go
const CodeSubsystemIndexSetConflict = "subsystem_index_set_conflict"
```

CodeSubsystemIndexSetConflict: a referenced subsystem declares an index set that conflicts with a same-named set already in the parent document.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L291) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSubsystemIndexSetConflict)

### `CodeSubsystemIndexSetRenameUnknownName` {#x-codesubsystemindexsetrenameunknownname}

*constant* · canonical name `code_subsystem_index_set_rename_unknown_name`

```go
const CodeSubsystemIndexSetRenameUnknownName = "subsystem_index_set_rename_unknown_name"
```

CodeSubsystemIndexSetRenameUnknownName: a mount edge's `index_set_rename` names an index set the RESOLVED mounted document does not declare (esm-spec §4.7 "Mount-edge index-set renaming") — the mount-edge mirror of `template_import_rename_unknown_name`.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L296) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSubsystemIndexSetRenameUnknownName)

### `CodeSubsystemIndexSetRenameUnsupportedMountForm` {#x-codesubsystemindexsetrenameunsupportedmountform}

*constant* · canonical name `code_subsystem_index_set_rename_unsupported_mount_form`

```go
const CodeSubsystemIndexSetRenameUnsupportedMountForm = "subsystem_index_set_rename_unsupported_mount_form"
```

CodeSubsystemIndexSetRenameUnsupportedMountForm: `index_set_rename` on a mount form that does not implement it (esm-spec §4.7 "Mount-edge index-set renaming", "Where it applies"). The field is a legal `SubsystemRef` property at either mount form, but a binding whose top-level `models.<k>` `{ref}` inliner cannot apply it MUST say so rather than merge the leaf under its pre-rename axis names. Go does not inline a top-level `{ref}` at all, so it never raises this; the constant exists because the code table is cross-language uniform.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L305) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSubsystemIndexSetRenameUnsupportedMountForm)

### `CodeSubsystemRefIsCouplingLibrary` {#x-codesubsystemrefiscouplinglibrary}

*constant* · canonical name `code_subsystem_ref_is_coupling_library`

```go
const CodeSubsystemRefIsCouplingLibrary = "subsystem_ref_is_coupling_library"
```

CodeSubsystemRefIsCouplingLibrary: a subsystem `ref` resolves to a COUPLING library (§10.9) rather than to a document declaring a system.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L288) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSubsystemRefIsCouplingLibrary)

### `CodeSubsystemRefIsTemplateLibrary` {#x-codesubsystemrefistemplatelibrary}

*constant* · canonical name `code_subsystem_ref_is_template_library`

```go
const CodeSubsystemRefIsTemplateLibrary = "subsystem_ref_is_template_library"
```

CodeSubsystemRefIsTemplateLibrary: a subsystem `ref` resolves to a TEMPLATE library (§9.7) rather than to a document declaring a system.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L285) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeSubsystemRefIsTemplateLibrary)

### `CodeTableAxisDuplicateName` {#x-codetableaxisduplicatename}

*constant* · canonical name `code_table_axis_duplicate_name`

```go
const CodeTableAxisDuplicateName = "table_axis_duplicate_name"
```

CodeTableAxisDuplicateName: two axes of one table share a `name`.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L464) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableAxisDuplicateName)

### `CodeTableAxisNaN` {#x-codetableaxisnan}

*constant* · canonical name `code_table_axis_na_n`

```go
const CodeTableAxisNaN = "table_axis_nan"
```

CodeTableAxisNaN: an axis's `values` carries a value that is not finite (NaN, +Inf or -Inf; esm-spec §9.5.5, ruling Q-109).

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L472) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableAxisNaN)

### `CodeTableAxisNonMonotonic` {#x-codetableaxisnonmonotonic}

*constant* · canonical name `code_table_axis_non_monotonic`

```go
const CodeTableAxisNonMonotonic = "table_axis_non_monotonic"
```

CodeTableAxisNonMonotonic: an axis's `values` is not strictly increasing.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L474) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableAxisNonMonotonic)

### `CodeTableAxisTooShort` {#x-codetableaxistooshort}

*constant* · canonical name `code_table_axis_too_short`

```go
const CodeTableAxisTooShort = "table_axis_too_short"
```

CodeTableAxisTooShort: an axis's `values` has fewer than 2 entries. The schema rejects such an axis too; this is what a table built in memory reports.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L478) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableAxisTooShort)

### `CodeTableDataNaN` {#x-codetabledatanan}

*constant* · canonical name `code_table_data_na_n`

```go
const CodeTableDataNaN = "table_data_nan"
```

CodeTableDataNaN: a leaf of `data` is not finite (NaN, +Inf or -Inf; esm-spec §9.5.5, ruling Q-109).

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L488) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableDataNaN)

### `CodeTableDataShapeMismatch` {#x-codetabledatashapemismatch}

*constant* · canonical name `code_table_data_shape_mismatch`

```go
const CodeTableDataShapeMismatch = "table_data_shape_mismatch"
```

CodeTableDataShapeMismatch: `data`'s nesting does not match the shape `axes` (and `outputs`, when present) imply, or the redundant `shape` assertion does not match that shape.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L485) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableDataShapeMismatch)

### `CodeTableInterpolationAxesMismatch` {#x-codetableinterpolationaxesmismatch}

*constant* · canonical name `code_table_interpolation_axes_mismatch`

```go
const CodeTableInterpolationAxesMismatch = "table_interpolation_axes_mismatch"
```

CodeTableInterpolationAxesMismatch: `interpolation` and the axis count disagree — `linear` and `nearest` require 1 axis, `bilinear` 2.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L469) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableInterpolationAxesMismatch)

### `CodeTableLookupArgsNonempty` {#x-codetablelookupargsnonempty}

*constant* · canonical name `code_table_lookup_args_nonempty`

```go
const CodeTableLookupArgsNonempty = "table_lookup_args_nonempty"
```

CodeTableLookupArgsNonempty: a `table_lookup` node carries a non-empty positional `args` (esm-spec §9.5.2); an absent `args` means `[]`. The schema rejects the same node, so this is what a node that skipped schema validation (one built in memory) reports.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L457) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableLookupArgsNonempty)

### `CodeTableLookupAxisNameMismatch` {#x-codetablelookupaxisnamemismatch}

*constant* · canonical name `code_table_lookup_axis_name_mismatch`

```go
const CodeTableLookupAxisNameMismatch = "table_lookup_axis_name_mismatch"
```

CodeTableLookupAxisNameMismatch: the key set of `table_lookup.axes` does not match the axis names the referenced table declares.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L452) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableLookupAxisNameMismatch)

### `CodeTableLookupOutputOutOfRange` {#x-codetablelookupoutputoutofrange}

*constant* · canonical name `code_table_lookup_output_out_of_range`

```go
const CodeTableLookupOutputOutOfRange = "table_lookup_output_out_of_range"
```

CodeTableLookupOutputOutOfRange: `table_lookup.output` selects no output of the referenced table — an index past `len(outputs)` (or past 0 for a single-output table), a name absent from `outputs`, or a non-integer / non-string selector.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L462) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableLookupOutputOutOfRange)

### `CodeTableLookupUnknownTable` {#x-codetablelookupunknowntable}

*constant* · canonical name `code_table_lookup_unknown_table`

```go
const CodeTableLookupUnknownTable = "table_lookup_unknown_table"
```

CodeTableLookupUnknownTable: a `table_lookup` names no table, or one the document's `function_tables` block does not declare.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L449) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableLookupUnknownTable)

### `CodeTableOutOfBoundsUnsupported` {#x-codetableoutofboundsunsupported}

*constant* · canonical name `code_table_out_of_bounds_unsupported`

```go
const CodeTableOutOfBoundsUnsupported = "table_out_of_bounds_unsupported"
```

CodeTableOutOfBoundsUnsupported: the referenced table declares `out_of_bounds: "error"`, which this binding does not implement. Per esm-spec §9.5.3a the lookup is REFUSED at the point it would otherwise lower — answering it under the `"clamp"` mode the binding does have would return a number the author did not ask for with nothing in the result to say so. The document still LOADS and still round-trips; it simply does not evaluate.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L496) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableOutOfBoundsUnsupported)

### `CodeTableOutputsDuplicateName` {#x-codetableoutputsduplicatename}

*constant* · canonical name `code_table_outputs_duplicate_name`

```go
const CodeTableOutputsDuplicateName = "table_outputs_duplicate_name"
```

CodeTableOutputsDuplicateName: two entries of `outputs` share a name.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L466) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableOutputsDuplicateName)

### `CodeTableOutputsLengthMismatch` {#x-codetableoutputslengthmismatch}

*constant* · canonical name `code_table_outputs_length_mismatch`

```go
const CodeTableOutputsLengthMismatch = "table_outputs_length_mismatch"
```

CodeTableOutputsLengthMismatch: `outputs` is declared, `data` is an array, and its length is not `len(outputs)`.

--- Diagnostic codes: §9.5 sampled function tables — the §9.5.5 table checks and the §9.5.3 `table_lookup` lowering (raised via newTableLookupError from lower\_table\_lookup.go).

A CROSS-BINDING vocabulary: every binding raises these same strings from its own §9.5.3 lowering, so they belong in the shared registry rather than beside the pass. Only the codes THIS binding actually emits are declared. It emits all ten §9.5.5 table-well-formedness codes (validateFunctionTable runs them in the spec's pinned order on every table a lookup resolves to) and every `table_lookup_*` code except `table_lookup_out_of_bounds`, which belongs to the `out_of_bounds: "error"` mode this binding refuses instead (CodeTableOutOfBoundsUnsupported, esm-spec §9.5.3a). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L481) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTableOutputsLengthMismatch)

### `CodeTemplateBodyExpansionTooDeep` {#x-codetemplatebodyexpansiontoodeep}

*constant* · canonical name `code_template_body_expansion_too_deep`

```go
const CodeTemplateBodyExpansionTooDeep = "template_body_expansion_too_deep"
```

CodeTemplateBodyExpansionTooDeep: nested template application exceeded the expansion depth budget — the non-cyclic guard against unbounded growth.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L117) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateBodyExpansionTooDeep)

### `CodeTemplateBodyReferencesCouplingRewrittenVariable` {#x-codetemplatebodyreferencescouplingrewrittenvariable}

*constant* · canonical name `code_template_body_references_coupling_rewritten_variable`

```go
const CodeTemplateBodyReferencesCouplingRewrittenVariable = "template_body_references_coupling_rewritten_variable"
```

CodeTemplateBodyReferencesCouplingRewrittenVariable: a SURVIVING registry body names a variable a coupling rule rewrote out of the flattened equations — a `variable_map`'s substituted target, or a spelling an `operator_compose` renaming match deleted (esm-spec §9.6.4, CONFORMANCE\_SPEC §5.35). The body is authored source no equation walk reaches, and it expands at the BUILD boundary, so it is REFUSED rather than resolved: rewriting it would silently diverge from the expand-at-load image of the same document.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L129) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateBodyReferencesCouplingRewrittenVariable)

### `CodeTemplateConstraintUnknownIndexSet` {#x-codetemplateconstraintunknownindexset}

*constant* · canonical name `code_template_constraint_unknown_index_set`

```go
const CodeTemplateConstraintUnknownIndexSet = "template_constraint_unknown_index_set"
```

CodeTemplateConstraintUnknownIndexSet: a template's `constraints` entry names an index set absent from the document `index_sets` registry.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L120) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateConstraintUnknownIndexSet)

### `CodeTemplateImportCycle` {#x-codetemplateimportcycle}

*constant* · canonical name `code_template_import_cycle`

```go
const CodeTemplateImportCycle = "template_import_cycle"
```

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L41) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportCycle)

### `CodeTemplateImportIndexSetConflict` {#x-codetemplateimportindexsetconflict}

*constant* · canonical name `code_template_import_index_set_conflict`

```go
const CodeTemplateImportIndexSetConflict = "template_import_index_set_conflict"
```

CodeTemplateImportIndexSetConflict: a merged `index_sets` name collides with a non-deep-equal definition (esm-spec §9.7.5). This binding does not raise it yet; the constant exists because the §9.6.6 table is cross-language uniform.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L51) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportIndexSetConflict)

### `CodeTemplateImportIsCouplingLibrary` {#x-codetemplateimportiscouplinglibrary}

*constant* · canonical name `code_template_import_is_coupling_library`

```go
const CodeTemplateImportIsCouplingLibrary = "template_import_is_coupling_library"
```

CodeTemplateImportIsCouplingLibrary: a template `import` resolves to a COUPLING library (§10.9). The two library kinds are imported through different blocks and are not interchangeable.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L60) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportIsCouplingLibrary)

### `CodeTemplateImportNameConflict` {#x-codetemplateimportnameconflict}

*constant* · canonical name `code_template_import_name_conflict`

```go
const CodeTemplateImportNameConflict = "template_import_name_conflict"
```

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L40) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportNameConflict)

### `CodeTemplateImportNotLibrary` {#x-codetemplateimportnotlibrary}

*constant* · canonical name `code_template_import_not_library`

```go
const CodeTemplateImportNotLibrary = "template_import_not_library"
```

CodeTemplateImportNotLibrary: an `import` resolves to a file that is not a template library (it declares components, or declares no `expression_templates` / `coupling_roles` block at all).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L56) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportNotLibrary)

### `CodeTemplateImportRebindUnknownName` {#x-codetemplateimportrebindunknownname}

*constant* · canonical name `code_template_import_rebind_unknown_name`

```go
const CodeTemplateImportRebindUnknownName = "template_import_rebind_unknown_name"
```

CodeTemplateImportRebindUnknownName: a `rebind` key names no metaparameter the imported library declares.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L78) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportRebindUnknownName)

### `CodeTemplateImportRenameCollision` {#x-codetemplateimportrenamecollision}

*constant* · canonical name `code_template_import_rename_collision`

```go
const CodeTemplateImportRenameCollision = "template_import_rename_collision"
```

CodeTemplateImportRenameCollision: a `rename` target collides with a name already in scope (another import's export, or a local declaration).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L75) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportRenameCollision)

### `CodeTemplateImportRenameInvalid` {#x-codetemplateimportrenameinvalid}

*constant* · canonical name `code_template_import_rename_invalid`

```go
const CodeTemplateImportRenameInvalid = "template_import_rename_invalid"
```

CodeTemplateImportRenameInvalid: an import's `rename` / `rebind` entry is malformed — not an object, or an entry whose key or value is not a non-empty string.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L69) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportRenameInvalid)

### `CodeTemplateImportRenameUnknownName` {#x-codetemplateimportrenameunknownname}

*constant* · canonical name `code_template_import_rename_unknown_name`

```go
const CodeTemplateImportRenameUnknownName = "template_import_rename_unknown_name"
```

CodeTemplateImportRenameUnknownName: a `rename` key names nothing the imported library exports.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L72) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportRenameUnknownName)

### `CodeTemplateImportUnknownName` {#x-codetemplateimportunknownname}

*constant* · canonical name `code_template_import_unknown_name`

```go
const CodeTemplateImportUnknownName = "template_import_unknown_name"
```

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L39) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportUnknownName)

### `CodeTemplateImportUnresolved` {#x-codetemplateimportunresolved}

*constant* · canonical name `code_template_import_unresolved`

```go
const CodeTemplateImportUnresolved = "template_import_unresolved"
```

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L38) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportUnresolved)

### `CodeTemplateImportVersionTooOld` {#x-codetemplateimportversiontooold}

*constant* · canonical name `code_template_import_version_too_old`

```go
const CodeTemplateImportVersionTooOld = "template_import_version_too_old"
```

CodeTemplateImportVersionTooOld: a file declaring esm &lt; 0.8.0 carries `expression_template_imports`, top-level `expression_templates`, or `metaparameters` (esm-spec §9.6.5).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L46) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateImportVersionTooOld)

### `CodeTemplateInjectTargetNotComponent` {#x-codetemplateinjecttargetnotcomponent}

*constant* · canonical name `code_template_inject_target_not_component`

```go
const CodeTemplateInjectTargetNotComponent = "template_inject_target_not_component"
```

CodeTemplateInjectTargetNotComponent: an injection `target` resolves to something that is not an injectable component.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L84) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateInjectTargetNotComponent)

### `CodeTemplateInjectTargetUnknown` {#x-codetemplateinjecttargetunknown}

*constant* · canonical name `code_template_inject_target_unknown`

```go
const CodeTemplateInjectTargetUnknown = "template_inject_target_unknown"
```

CodeTemplateInjectTargetUnknown: an injection `target` names a component the document does not declare.

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L81) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateInjectTargetUnknown)

### `CodeTemplateLibraryIllegalPayload` {#x-codetemplatelibraryillegalpayload}

*constant* · canonical name `code_template_library_illegal_payload`

```go
const CodeTemplateLibraryIllegalPayload = "template_library_illegal_payload"
```

CodeTemplateLibraryIllegalPayload: a document carries top-level `expression_templates` beside `models` / `reaction_systems` / `data_sources` / `coupling` / `domain`, which a template-library file never declares (esm-spec §9.7.1).

--- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters (raised via newETErr from template\_imports.go and subsystem\_ref.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L65) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTemplateLibraryIllegalPayload)

### `CodeTimeOriginInvalid` {#x-codetimeorigininvalid}

*constant* · canonical name `code_time_origin_invalid`

```go
const CodeTimeOriginInvalid = "time_origin_invalid"
```

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L174) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTimeOriginInvalid)

### `CodeTimestampMalformed` {#x-codetimestampmalformed}

*constant* · canonical name `code_timestamp_malformed`

```go
const CodeTimestampMalformed = "timestamp_malformed"
```

CodeTimestampMalformed, CodeTimestampNoCalendarDay and CodeTimeOriginInvalid: the causes the §2.2.7 clock accessors (`time_origin`, `timestamp_to_seconds`; API\_SPEC §5.8) report, one code each -- a timestamp not in the `solver.time_span` bound form, one whose day is not in its month, and an unreadable `domain.temporal` origin. Go does not simulate and carries no clock accessor, so nothing here raises them; the constants keep the vocabulary uniform across the five registries.

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L172) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTimestampMalformed)

### `CodeTimestampNoCalendarDay` {#x-codetimestampnocalendarday}

*constant* · canonical name `code_timestamp_no_calendar_day`

```go
const CodeTimestampNoCalendarDay = "timestamp_no_calendar_day"
```

--- Diagnostic codes: §9.6 expression templates — declaration, application and body expansion (raised via newETErr from lower\_expression\_templates.go, out\_of\_line\_templates.go and template\_compose.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L173) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeTimestampNoCalendarDay)

### `CodeUndefinedIndexSet` {#x-codeundefinedindexset}

*constant* · canonical name `code_undefined_index_set`

```go
const CodeUndefinedIndexSet = "undefined_index_set"
```

CodeUndefinedIndexSet: an aggregate `ranges` entry `{from: NAME}` names an index set that is not a key of the document `index_sets` registry. No implicit interval is inferred for an undeclared name (RFC §5.2).

validate\_static\_checks.go holds static-validation checks for defects that are decidable from the SINGLE document (no evaluator, no solver, no other file). Their pinned (code, path) tuples live in tests/invalid/expected\_errors.json, and these checks make Go's Validate reject each with exactly that pin:

- join\_key\_invalid\_type          — an aggregate value-equality join whose key column draws from a categorical index set with a float or null member.
- domain\_unit\_mismatch           — an identity variable\_map coupling whose from/to variables carry declared, non-empty, DIFFERENT units.
- relational\_node\_in\_continuous  — a distinct/bool\_and\_or aggregate whose key/expr reads a STATE variable (value-invention in a continuous context).
- undefined\_index\_set            — an aggregate `ranges` entry `{from: NAME}` naming a set absent from the document `index_sets` registry.

Every finding is emitted at the CONTAINING EXPRESSION FIELD (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer convention the reference-integrity findings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate_static_checks.go#L64) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUndefinedIndexSet)

### `CodeUnevaluableOperator` {#x-codeunevaluableoperator}

*constant* · canonical name `code_unevaluable_operator`

```go
const CodeUnevaluableOperator = "unevaluable_operator"
```

CodeUnevaluableOperator: evaluation reached an op that IS in the esm-spec §4.2 evaluable core but that this evaluator has no rule for (esm-spec §9.6.6): an array/query or value-invention op, or an `enum` that should have been lowered at load. The complement of CodeUnloweredOperator.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L571) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnevaluableOperator)

### `CodeUnknownClosedFunction` {#x-codeunknownclosedfunction}

*constant* · canonical name `code_unknown_closed_function`

```go
const CodeUnknownClosedFunction = "unknown_closed_function"
```

CodeUnknownClosedFunction: an `fn` node names a function outside the closed registry.

--- Diagnostic codes: §9.2 closed-function registry (raised via newClosedFunctionError from registered\_functions.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L504) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnknownClosedFunction)

### `CodeUnknownEnum` {#x-codeunknownenum}

*constant* · canonical name `code_unknown_enum`

```go
const CodeUnknownEnum = "unknown_enum"
```

CodeUnknownEnum: an `enum` node names an enum the file does not declare.

--- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError from lower\_enums.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L543) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnknownEnum)

### `CodeUnknownEnumSymbol` {#x-codeunknownenumsymbol}

*constant* · canonical name `code_unknown_enum_symbol`

```go
const CodeUnknownEnumSymbol = "unknown_enum_symbol"
```

CodeUnknownEnumSymbol: an `enum` node names a symbol its enum does not declare.

--- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError from lower\_enums.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L546) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnknownEnumSymbol)

### `CodeUnknownExpressionType` {#x-codeunknownexpressiontype}

*constant* · canonical name `code_unknown_expression_type`

```go
const CodeUnknownExpressionType = "unknown_expression_type"
```

--- Diagnostic codes: structural validation, peers of the Error\* block above. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L410) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnknownExpressionType)

### `CodeUnloweredOperator` {#x-codeunloweredoperator}

*constant* · canonical name `code_unlowered_operator`

```go
const CodeUnloweredOperator = "unlowered_operator"
```

CodeUnloweredOperator: evaluation reached a rewrite-target op — one OUTSIDE the esm-spec §4.2 evaluable core (a spatial or right-hand-side `D`, `grad`, a user op) — that no rewrite rule eliminated.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L566) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnloweredOperator)

### `CodeUnresolvedSubsystemRef` {#x-codeunresolvedsubsystemref}

*constant* · canonical name `code_unresolved_subsystem_ref`

```go
const CodeUnresolvedSubsystemRef = "unresolved_subsystem_ref"
```

CodeUnresolvedSubsystemRef: a subsystem `ref` names a file that does not exist / is not readable, or that was never resolved before validation.

--- Diagnostic codes: §4.7 subsystem refs. Shared with the structural validator, which reports the same two conditions for a document whose refs were never resolved (tests/invalid/subsystem\_ref\_not\_found.esm, subsystem\_ref\_ambiguous.esm; the names are pinned by tests/invalid/expected\_errors.json). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L279) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnresolvedSubsystemRef)

### `CodeUnsupportedConstruct` {#x-codeunsupportedconstruct}

*constant* · canonical name `code_unsupported_construct`

```go
const CodeUnsupportedConstruct = "unsupported_construct"
```

CodeUnsupportedConstruct: a continuous or discrete event, or an implicit equation, reached an evaluator that cannot run it (esm-spec §9.6.6). Go does not simulate, so it never raises this; the constant keeps the §9.6.6 vocabulary uniform.

--- Diagnostic codes: expression EVALUATION (EvaluationError, raised from expression.go). `unlowered_operator` is a cross-binding wire code — Julia and TypeScript emit exactly this string — so it belongs in the registry rather than at the call site. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L580) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeUnsupportedConstruct)

### `CodeValidationFailed` {#x-codevalidationfailed}

*constant* · canonical name `code_validation_failed`

```go
const CodeValidationFailed = "validation_failed"
```

--- Diagnostic codes: structural validation, peers of the Error\* block above. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L409) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CodeValidationFailed)

### `ComponentAdjacency` {#x-componentadjacency}

*type* · canonical name `component_adjacency`

```go
type ComponentAdjacency struct {
	Neighbor ComponentNode
	Edge     CouplingEdge
}
```

ComponentAdjacency is one entry returned by ComponentGraph.Adjacency: a neighbouring component node and the coupling edge that reaches it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L943) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ComponentAdjacency)

### `ComponentCounts` {#x-componentcounts}

*type* · canonical name `component_counts`

```go
type ComponentCounts struct {
	VarCount     int `json:"var_count"`
	EqCount      int `json:"eq_count"`
	SpeciesCount int `json:"species_count"`
}
```

ComponentCounts is a component node's summary metadata (esm-libraries-spec §4.8.1). Exactly three counts are defined, and they mean different things for the two component types:

- a MODEL carries VarCount = len(variables), EqCount = len(equations) and SpeciesCount = 0;
- a REACTION SYSTEM carries VarCount = len(parameters), EqCount = len(reactions) — the reaction count IS the equation count, there is no fourth field — and SpeciesCount = len(species). The schema forbids a `variables` field on a reaction system and SpeciesCount already carries the species, so `parameters` is the only thing left for §4.8.1's "variable count" to mean — and it is the exact analogue of a model's `variables`, which likewise counts unknowns and parameters together.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L32) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ComponentCounts)

### `ComponentGraphFromFile` {#x-componentgraphfromfile}

*function* · canonical name `component_graph_from_file`

```go
func ComponentGraphFromFile(file *ESMFile) *ComponentGraph
```

ComponentGraphFromFile creates a component graph from an ESM file.

Models and reaction systems are visited in sorted key order: ranging over the maps directly made the node and edge lists differ run to run, which is not a conformance failure (order is not pinned) but does make every rendered or diffed export nondeterministic.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L162) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ComponentGraphFromFile)

### `Connector` {#x-connector}

*type* · canonical name `connector`

```go
type Connector struct {
	Equations []ConnectorEquation `json:"equations"`
}
```

Connector represents the connector system for couple coupling

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1007) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Connector)

### `ConnectorEquation` {#x-connectorequation}

*type* · canonical name `connector_equation`

```go
type ConnectorEquation struct {
	From      string `json:"from"`
	To        string `json:"to"`
	Transform string `json:"transform"` // "additive", "multiplicative", "replacement"
	// Expression is OPTIONAL: esm-schema.json `$defs/ConnectorEquation` requires
	// only from/to/transform. Without `omitempty` the nil interface emitted
	// `"expression": null` into every connector equation authored without one —
	// an ADDED key, so a load → save did not just lose content, it invented it.
	Expression Expression `json:"expression,omitempty"`
}
```

ConnectorEquation represents a single equation in a connector

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1012) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ConnectorEquation)

### `CouplingKind` {#x-couplingkind}

*type* · canonical name `coupling_kind`

```go
type CouplingKind string
```

CouplingKind identifies the kind of coupling a component-graph edge represents.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L51) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingKind)

### `CouplingKindCouple` {#x-couplingkindcouple}

*constant* · canonical name `coupling_kind_couple`

```go
const CouplingKindCouple CouplingKind = "couple"
```

CouplingKindCouple marks an edge built from a `couple` coupling entry (esm-spec §10.1, §10.3): the two systems are joined through explicit connector equations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L61) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingKindCouple)

### `CouplingKindOperatorCompose` {#x-couplingkindoperatorcompose}

*constant* · canonical name `coupling_kind_operator_compose`

```go
const CouplingKindOperatorCompose CouplingKind = "operator_compose"
```

CouplingKindOperatorCompose marks an edge built from an `operator_compose` coupling entry (esm-spec §10.1): matching time derivatives are identified and their right-hand sides added together.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L57) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingKindOperatorCompose)

### `CouplingKindVariableMap` {#x-couplingkindvariablemap}

*constant* · canonical name `coupling_kind_variable_map`

```go
const CouplingKindVariableMap CouplingKind = "variable_map"
```

CouplingKindVariableMap marks an edge built from a `variable_map` coupling entry (esm-spec §10.1, §10.4): a parameter in one system is replaced by a variable from another, or by an expression computed from it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L66) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingKindVariableMap)

### `DataSourceExtent` {#x-datasourceextent}

*type* · canonical name `data_source_extent`

```go
type DataSourceExtent struct {
	Metaparameter string `json:"metaparameter"`
}
```

DataSourceExtent binds a source's delivered record count to a metaparameter (esm-spec 8.9.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L835) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceExtent)

### `DataSourceRecordFilter` {#x-datasourcerecordfilter}

*type* · canonical name `data_source_record_filter`

```go
type DataSourceRecordFilter struct {
	RequireFinite []string `json:"require_finite,omitempty"`
}
```

DataSourceRecordFilter names the file variables whose value must be finite for a record of a `points` source to be delivered (esm-spec 8.9.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L829) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceRecordFilter)

### `DefaultIndepVar` {#x-defaultindepvar}

*constant* · canonical name `default_indep_var`

```go
const DefaultIndepVar = "t"
```

--- Spec default: the independent variable when Domain.IndependentVariable is unset (esm-spec §11; dae.go defaults to this). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L664) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DefaultIndepVar)

### `DetailedValidationResult` {#x-detailedvalidationresult}

*type* · canonical name `detailed_validation_result`

```go
type DetailedValidationResult struct {
	Valid    bool                `json:"valid"`
	Messages []ValidationMessage `json:"messages,omitempty"`
}
```

DetailedValidationResult holds the legacy (message-oriented) validation results returned by ValidateStructural. New callers should prefer Validate (or ValidateText for unparsed JSON), which returns the code-bearing ValidationResult.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L94) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DetailedValidationResult)

### `DiagnosticError` {#x-diagnosticerror}

*error* · canonical name `diagnostic_error`

```go
type DiagnosticError interface {
	error
	DiagnosticCode() string
}
```

DiagnosticError is implemented by the package's code-bearing error types (EvaluationError, ExpressionTemplateError, RuleEngineError, EnumLoweringError, ClosedFunctionError, CoupleMultiplicativeNoTendencyError, tableLookupError, OperatorComposeNoMergeError, OperatorComposeAmbiguousBareNameError, OperatorComposeRequireMatchError). It lets a caller recover the stable diagnostic code from any of them uniformly — errors.As(err, &de) then de.DiagnosticCode() — without switching over the concrete types. All ten render Error() in the shared "\[code\] message" form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L716) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DiagnosticError)

### `Dimensionless` {#x-dimensionless}

*constant* · canonical name `dimensionless`

```go
var Dimensionless = Dimension{}
```

Dimensionless is the zero vector.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L183) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Dimensionless)

### `DistributionLognormal` {#x-distributionlognormal}

*constant* · canonical name `distribution_lognormal`

```go
const DistributionLognormal = "lognormal"
```

Distribution kind literals (esm-spec 6.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L381) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DistributionLognormal)

### `DistributionNormal` {#x-distributionnormal}

*constant* · canonical name `distribution_normal`

```go
const DistributionNormal = "normal"
```

Distribution kind literals (esm-spec 6.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L380) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DistributionNormal)

### `DistributionUniform` {#x-distributionuniform}

*constant* · canonical name `distribution_uniform`

```go
const DistributionUniform = "uniform"
```

Distribution kind literals (esm-spec 6.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L382) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DistributionUniform)

### `EdgeKindFromFAQ` {#x-edgekindfromfaq}

*constant* · canonical name `edge_kind_from_faq`

```go
const EdgeKindFromFAQ EdgeKind = "from_faq"
```

EdgeKindFromFAQ: `kind:"derived"` index set → the node that materializes it (`from_faq`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L115) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EdgeKindFromFAQ)

### `EdgeKindJoinFactor` {#x-edgekindjoinfactor}

*constant* · canonical name `edge_kind_join_factor`

```go
const EdgeKindJoinFactor EdgeKind = "join_factor"
```

EdgeKindJoinFactor: aggregate node → a factor named by `join.on`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L117) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EdgeKindJoinFactor)

### `EdgeKindRangeFrom` {#x-edgekindrangefrom}

*constant* · canonical name `edge_kind_range_from`

```go
const EdgeKindRangeFrom EdgeKind = "range_from"
```

EdgeKindRangeFrom: aggregate node → the index set it iterates (`ranges[*].from`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L112) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EdgeKindRangeFrom)

### `EmitReferencePreserving` {#x-emitreferencepreserving}

*function* · canonical name `emit_reference_preserving`

```go
func EmitReferencePreserving(jsonStr, basePath string, metaparameters map[string]int64) (string, error)
```

EmitReferencePreserving loads jsonStr under Option B and emits the canonical, self-contained reference-preserving document (esm-spec §9.6.4 rule 5, §9.6.7): surviving call sites verbatim, materialized template registries, imports consumed, `esm: 0.9.0` version stamp. The byte-identity cross-binding surface — output is byte-identical to the Julia-generated `emitted.esm` goldens.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/out_of_line_templates.go#L1041) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EmitReferencePreserving)

### `EquationBalance` {#x-equationbalance}

*type* · canonical name `equation_balance`

```go
type EquationBalance struct {
	// Unknowns are the model's declared unknowns, sorted. (Declaration order is
	// what the shared corpus's `details` happens to show, but Go's variable map
	// does not preserve it, so this list is sorted for determinism. The pin
	// contract compares (code, path) pairs, not details.)
	Unknowns []string
	// Equations is the number of entries in the model's `equations` block.
	Equations int
	// MissingEquationsFor names the unknowns that no equation LHS credits — the
	// diagnostic detail that preserves the discriminating power of the removed
	// `missing_observed_expr`, since it names exactly the unknowns that code used
	// to name.
	MissingEquationsFor []string
	// ExtraEquationsFor names non-unknown targets an equation LHS credits.
	ExtraEquationsFor []string
}
```

EquationBalance is the outcome of the esm-spec §4.9.4 balance check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L1513) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EquationBalance)

### `ErrCanonicalDivByZero` {#x-errcanonicaldivbyzero}

*error* · canonical name `err_canonical_div_by_zero`

```go
var ErrCanonicalDivByZero = errors.New("E_CANONICAL_DIVBY_ZERO")
```

Error codes per discretization RFC §5.4.6 / §5.4.7.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/canonicalize.go#L18) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrCanonicalDivByZero)

### `ErrCanonicalNonFinite` {#x-errcanonicalnonfinite}

*error* · canonical name `err_canonical_non_finite`

```go
var ErrCanonicalNonFinite = errors.New("E_CANONICAL_NONFINITE")
```

Error codes per discretization RFC §5.4.6 / §5.4.7.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/canonicalize.go#L17) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrCanonicalNonFinite)

### `ErrCanonicalUnsupportedField` {#x-errcanonicalunsupportedfield}

*error* · canonical name `err_canonical_unsupported_field`

```go
var ErrCanonicalUnsupportedField = errors.New("E_CANONICAL_UNSUPPORTED_FIELD")
```

ErrCanonicalUnsupportedField is returned by CanonicalJSON when a node carries a set field outside the closed emissible set {op,args,wrt,dim,fn,name,value} (arg/bindings tolerated) — the node has no faithful canonical JSON in the pinned encoding. Matches the Julia reference's E\_CANONICAL\_UNSUPPORTED\_FIELD (see canonicalize.jl).

Error codes per discretization RFC §5.4.6 / §5.4.7.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/canonicalize.go#L24) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrCanonicalUnsupportedField)

### `ErrorArrayDefaultWithoutShape` {#x-errorarraydefaultwithoutshape}

*constant* · canonical name `error_array_default_without_shape`

```go
const ErrorArrayDefaultWithoutShape = "array_default_without_shape"
```

ErrorArrayDefaultWithoutShape is inline array data as the `default` of a variable that declares no `shape` (esm-spec §6.3). Inline array data is a SHAPED variable's value, so with no shape there is nothing for the array to fill (tests/invalid/array\_default\_without\_shape.esm).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L403) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorArrayDefaultWithoutShape)

### `ErrorAssertionRankMismatch` {#x-errorassertionrankmismatch}

*constant* · canonical name `error_assertion_rank_mismatch`

```go
const ErrorAssertionRankMismatch = "assertion_rank_mismatch"
```

ErrorAssertionRankMismatch is an assertion whose form does not match the declared rank of the variable it names (esm-spec §6.6.5): pointwise on a shaped variable, or `coords` / `reduce` on a scalar one (tests/invalid/assertion\_rank\_mismatch\_\*.esm).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L398) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorAssertionRankMismatch)

### `ErrorCircularDependency` {#x-errorcirculardependency}

*constant* · canonical name `error_circular_dependency`

```go
const ErrorCircularDependency = "circular_dependency"
```

ErrorCircularDependency is a cycle in the cross-model reference graph: ModelA's equations reference ModelB's variables and vice versa (tests/invalid/circular\_coupling.esm).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L377) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorCircularDependency)

### `ErrorDataSourceUndefined` {#x-errordatasourceundefined}

*constant* · canonical name `error_data_source_undefined`

```go
const ErrorDataSourceUndefined = "data_source_undefined"
```

ErrorDataSourceUndefined is raised when a parameter's `update.source` names no declared `data_sources` entry (esm-spec §8.5).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L360) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorDataSourceUndefined)

### `ErrorEquationCountMismatch` {#x-errorequationcountmismatch}

*constant* · canonical name `error_equation_count_mismatch`

```go
const ErrorEquationCountMismatch = "equation_count_mismatch"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L334) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorEquationCountMismatch)

### `ErrorEquationDefinesParameter` {#x-errorequationdefinesparameter}

*constant* · canonical name `error_equation_defines_parameter`

```go
const ErrorEquationDefinesParameter = "equation_defines_parameter"
```

ErrorEquationDefinesParameter is raised when an equation's left-hand side names a PARAMETER — bare, indexed, inside a `faq`, or through a scoped reference into a subsystem (esm-spec §6.3.1). An equation defines unknowns only.

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L353) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorEquationDefinesParameter)

### `ErrorEventAffectsParameter` {#x-erroreventaffectsparameter}

*constant* · canonical name `error_event_affects_parameter`

```go
const ErrorEventAffectsParameter = "event_affects_parameter"
```

ErrorEventAffectsParameter is raised when an event `affects` LHS names a PARAMETER. From esm 1.0.0 events affect unknowns only: a parameter that changes during a run carries its own `update` block (esm-spec §5.4), so there is no `discrete_parameters` list to be missing from and the write is wrong outright rather than wrong-unless-declared.

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L348) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorEventAffectsParameter)

### `ErrorEventVarUndeclared` {#x-erroreventvarundeclared}

*constant* · canonical name `error_event_var_undeclared`

```go
const ErrorEventVarUndeclared = "event_var_undeclared"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L365) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorEventVarUndeclared)

### `ErrorICInReactionSystem` {#x-erroricinreactionsystem}

*constant* · canonical name `error_ic_in_reaction_system`

```go
const ErrorICInReactionSystem = "ic_in_reaction_system"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L367) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorICInReactionSystem)

### `ErrorNullReaction` {#x-errornullreaction}

*constant* · canonical name `error_null_reaction`

```go
const ErrorNullReaction = "null_reaction"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L364) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorNullReaction)

### `ErrorReservedVariableName` {#x-errorreservedvariablename}

*constant* · canonical name `error_reserved_variable_name`

```go
const ErrorReservedVariableName = "reserved_variable_name"
```

ErrorReservedVariableName is a DECLARATION — a `variables` key, a species, or a reaction parameter — spelled with a globally-scoped name: the document's independent variable (`domain.independent_variable`, default "t") or the §6.4 `_var` placeholder (esm-spec §4.9.1.1). Both are in scope in every component and are resolved BY NAME ahead of the declaration maps — creditIndependentVariable below is exactly that precedence — so the declaration is unreachable and every reader silently receives the implicit symbol instead of the declared quantity. Hard error: the document that reported this (issue #200) validated clean and then read the simulation clock in place of a fuel time-lag constant. (tests/invalid/reserved\_variable\_name\_\*.esm).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L389) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorReservedVariableName)

### `ErrorSystemKindMismatch` {#x-errorsystemkindmismatch}

*constant* · canonical name `error_system_kind_mismatch`

```go
const ErrorSystemKindMismatch = "system_kind_mismatch"
```

ErrorSystemKindMismatch is raised when a model's declared `system_kind` contradicts the esm-spec §6.3.1 derivation.

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L363) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorSystemKindMismatch)

### `ErrorUnboundIndexSymbol` {#x-errorunboundindexsymbol}

*constant* · canonical name `error_unbound_index_symbol`

```go
const ErrorUnboundIndexSymbol = "unbound_index_symbol"
```

ErrorUnboundIndexSymbol is raised when a string subscript of an `index` on an equation's left-hand side names no declared variable or metaparameter and no `faq` binds it (esm-spec §6.3.1).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L357) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUnboundIndexSymbol)

### `ErrorUndefinedOperator` {#x-errorundefinedoperator}

*constant* · canonical name `error_undefined_operator`

```go
const ErrorUndefinedOperator = "undefined_operator"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L341) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUndefinedOperator)

### `ErrorUndefinedParameter` {#x-errorundefinedparameter}

*constant* · canonical name `error_undefined_parameter`

```go
const ErrorUndefinedParameter = "undefined_parameter"
```

ErrorUndefinedParameter is reserved for a future undeclared-parameter diagnostic; no check emits it yet (kept for cross-binding code parity).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L339) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUndefinedParameter)

### `ErrorUndefinedSpecies` {#x-errorundefinedspecies}

*constant* · canonical name `error_undefined_species`

```go
const ErrorUndefinedSpecies = "undefined_species"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L336) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUndefinedSpecies)

### `ErrorUndefinedSystem` {#x-errorundefinedsystem}

*constant* · canonical name `error_undefined_system`

```go
const ErrorUndefinedSystem = "undefined_system"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L340) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUndefinedSystem)

### `ErrorUndefinedVariable` {#x-errorundefinedvariable}

*constant* · canonical name `error_undefined_variable`

```go
const ErrorUndefinedVariable = "undefined_variable"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L335) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUndefinedVariable)

### `ErrorUnitInconsistency` {#x-errorunitinconsistency}

*constant* · canonical name `error_unit_inconsistency`

```go
const ErrorUnitInconsistency = "unit_inconsistency"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L366) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUnitInconsistency)

### `ErrorUnitParseError` {#x-errorunitparseerror}

*constant* · canonical name `error_unit_parse_error`

```go
const ErrorUnitParseError = "unit_parse_error"
```

ErrorUnitParseError is a declared unit string that denotes no real unit ("not\_a\_unit"). It is a defect in the FILE — a hard error, distinct from `unit_inconsistency` (a provable dimensional mismatch between two resolvable units) — and is the code the shared corpus pins for tests/invalid/unparseable\_unit.esm.

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L373) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUnitParseError)

### `ErrorUnknownOverrideKey` {#x-errorunknownoverridekey}

*constant* · canonical name `error_unknown_override_key`

```go
const ErrorUnknownOverrideKey = "unknown_override_key"
```

ErrorUnknownOverrideKey is an inline test's `initial_conditions` or `parameter_overrides` key that matches no declared name under the esm-spec §6.6.2 override-key rules (tests/invalid/unknown\_override\_key\_\*.esm).

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L393) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUnknownOverrideKey)

### `ErrorUnresolvedScopedRef` {#x-errorunresolvedscopedref}

*constant* · canonical name `error_unresolved_scoped_ref`

```go
const ErrorUnresolvedScopedRef = "unresolved_scoped_ref"
```

--- Diagnostic codes: structural validation, per ESM Libraries Spec Section 3.4. The names and values are pinned by tests/invalid/expected\_errors.json. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L342) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ErrorUnresolvedScopedRef)

### `EvaluationError` {#x-evaluationerror}

*error* · canonical name `evaluation_error`

```go
type EvaluationError struct {
	Code    string
	Message string
}

func (e *EvaluationError) DiagnosticCode() string

func (e *EvaluationError) Error() string
```

EvaluationError is raised by the scalar evaluator when an expression cannot be evaluated. The Code field carries a stable diagnostic code — in particular `unlowered_operator` when a rewrite-target op (a spatial/RHS `D`, or grad/div/laplacian/integral sugar) reaches evaluation without having been lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8). The gate fires before evaluation, not at load: loading such a file stays permissive.

**Methods**

```go
func (e *EvaluationError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *EvaluationError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/expression.go#L16) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EvaluationError)

### `EventCoupling` {#x-eventcoupling}

*type* · canonical name `event_coupling`

```go
type EventCoupling struct {
	Type         string                `json:"type"`       // "event"
	EventType    string                `json:"event_type"` // "continuous" or "discrete"
	Name         string                `json:"name"`
	Conditions   []Expression          `json:"conditions,omitempty"` // for continuous events
	Trigger      *DiscreteEventTrigger `json:"trigger,omitempty"`    // for discrete events
	Affects      []AffectEquation      `json:"affects,omitempty"`
	AffectNeg    []AffectEquation      `json:"affect_neg,omitempty"`
	RootFind     *string               `json:"root_find,omitempty"`
	Reinitialize *bool                 `json:"reinitialize,omitempty"`
	Description  *string               `json:"description,omitempty"`
}

func (e EventCoupling) CouplingType() string

func (ec *EventCoupling) UnmarshalJSON(data []byte) error
```

EventCoupling represents event-based coupling. Like a model-local event it may affect UNKNOWNS ONLY (`event_affects_parameter` otherwise, esm-spec 5.4).

**Methods**

```go
func (e EventCoupling) CouplingType() string
```

```go
func (ec *EventCoupling) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for EventCoupling

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L966) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EventCoupling)

### `Expression` {#x-expression}

*type* · canonical name `expression`

```go
type Expression any
```

Expression represents the union type: number | string | ExprNode In Go, this is handled by using interface{} and custom unmarshaling

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L124) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Expression)

### `ExpressionGraphFromEquation` {#x-expressiongraphfromequation}

*function* · canonical name `expression_graph_from_equation`

```go
func ExpressionGraphFromEquation(equation Equation) *ExpressionGraph
```

ExpressionGraphFromEquation creates an expression graph for a single equation (esm-libraries-spec §4.8.2). The equation is numbered 0 and its variables are unscoped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L445) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromEquation)

### `ExpressionGraphFromExpression` {#x-expressiongraphfromexpression}

*function* · canonical name `expression_graph_from_expression`

```go
func ExpressionGraphFromExpression(expr Expression) *ExpressionGraph
```

ExpressionGraphFromExpression creates an expression graph for a bare expression (esm-libraries-spec §4.8.2). A synthetic `expr_result` observed node stands in for the expression's value, and every free variable feeds it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L463) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromExpression)

### `ExpressionGraphFromFile` {#x-expressiongraphfromfile}

*function* · canonical name `expression_graph_from_file`

```go
func ExpressionGraphFromFile(file *ESMFile) *ExpressionGraph
```

ExpressionGraphFromFile creates an expression graph from an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L391) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromFile)

### `ExpressionGraphFromFileWithOptions` {#x-expressiongraphfromfilewithoptions}

*function* · canonical name `expression_graph_from_file_with_options`

```go
func ExpressionGraphFromFileWithOptions(file *ESMFile, opts ExpressionGraphOptions) *ExpressionGraph
```

ExpressionGraphFromFileWithOptions creates an expression graph from an ESM file, honouring opts.

Every inline model and reaction system is walked, INCLUDING its inline `subsystems` (recursively): a subsystem's variables are part of the document's dependency structure, and omitting them silently truncated the graph. Scoped names compose with a dot; `{ref}` include stubs are skipped as opaque leaves.

Components are visited in sorted key order so the node and edge lists do not vary run to run.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L405) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromFileWithOptions)

### `ExpressionGraphFromModel` {#x-expressiongraphfrommodel}

*function* · canonical name `expression_graph_from_model`

```go
func ExpressionGraphFromModel(model Model, systemName string) *ExpressionGraph
```

ExpressionGraphFromModel creates an expression graph for a single model, including its inline subsystems. Pass "default" as systemName for a bare target whose nodes should carry unscoped names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L428) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromModel)

### `ExpressionGraphFromReaction` {#x-expressiongraphfromreaction}

*function* · canonical name `expression_graph_from_reaction`

```go
func ExpressionGraphFromReaction(reaction Reaction) *ExpressionGraph
```

ExpressionGraphFromReaction creates an expression graph for a single reaction (esm-libraries-spec §4.8.2). The reaction is numbered 0 and its species are unscoped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L454) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromReaction)

### `ExpressionGraphFromReactionSystem` {#x-expressiongraphfromreactionsystem}

*function* · canonical name `expression_graph_from_reaction_system`

```go
func ExpressionGraphFromReactionSystem(system ReactionSystem, systemName string) *ExpressionGraph
```

ExpressionGraphFromReactionSystem creates an expression graph for a single reaction system, including its inline subsystems.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L436) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphFromReactionSystem)

### `FieldIC` {#x-fieldic}

*type* · canonical name `field_ic`

```go
type FieldIC struct {
	State string
	Expr  Expression
}
```

FieldIC is one deferred `ic` equation (esm-spec §11.4.1) as a (state, expression) pair. An initial condition is a DATUM, not an equation of motion, so these are classified OUT of FlattenedSystem.Equations and reported only here (esm-libraries-spec §4.7.5 step 4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L308) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FieldIC)

### `FlattenedFunctionTable` {#x-flattenedfunctiontable}

*type* · canonical name `flattened_function_table`

```go
type FlattenedFunctionTable struct {
	Name  string
	Table FunctionTable
}
```

FlattenedFunctionTable is one entry of the flattened system's merged function-table registry (esm-spec §9.5), in document order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L322) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedFunctionTable)

### `FlattenedIndexSet` {#x-flattenedindexset}

*type* · canonical name `flattened_index_set`

```go
type FlattenedIndexSet struct {
	Name string
	Set  IndexSet
}
```

FlattenedIndexSet is one entry of the flattened system's document-scoped index-set registry, in document order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L315) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedIndexSet)

### `FlattenedTemplate` {#x-flattenedtemplate}

*type* · canonical name `flattened_template`

```go
type FlattenedTemplate struct {
	Name        string
	Declaration any
}
```

FlattenedTemplate is one entry of the MERGED expression-template registry (esm-spec §9.6.4 rule 7, §10.7). Declaration is the raw template declaration (`params` + `body`, and any sidecar the document carried).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L330) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedTemplate)

### `FmtASCII` {#x-fmtascii}

*constant* · canonical name `fmt_ascii`

```go
const FmtASCII = "ascii"
```

--- Render format discriminator (display.go; compared ~50× as a bare string). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L700) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FmtASCII)

### `FmtLatex` {#x-fmtlatex}

*constant* · canonical name `fmt_latex`

```go
const FmtLatex = "latex"
```

--- Render format discriminator (display.go; compared ~50× as a bare string). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L699) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FmtLatex)

### `FmtUnicode` {#x-fmtunicode}

*constant* · canonical name `fmt_unicode`

```go
const FmtUnicode = "unicode"
```

--- Render format discriminator (display.go; compared ~50× as a bare string). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L698) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FmtUnicode)

### `FmtUnicodeSpaced` {#x-fmtunicodespaced}

*constant* · canonical name `fmt_unicode_spaced`

```go
const FmtUnicodeSpaced = "unicode_spaced"
```

FmtUnicodeSpaced is FmtUnicode with the multiplication operator rendered as " · " (spaced) instead of "·". The spacing is applied where the operator is emitted, so it never touches a "·" occurring inside a variable name or chemical formula.

--- Render format discriminator (display.go; compared ~50× as a bare string). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L705) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FmtUnicodeSpaced)

### `FromJSON` {#x-fromjson}

*function* · canonical name `from_json`

```go
func FromJSON(data []byte) (*ESMFile, error)
```

FromJSON creates an ESM file from JSON data

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1464) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FromJSON)

### `IndexSet` {#x-indexset}

*type* · canonical name `index_set`

```go
type IndexSet struct {
	Kind    string   `json:"kind"`
	Size    *int     `json:"size,omitempty"`
	Members []any    `json:"members,omitempty"`
	FromFAQ *string  `json:"from_faq,omitempty"`
	Of      []string `json:"of,omitempty"`
	Offsets *string  `json:"offsets,omitempty"`
	Values  *string  `json:"values,omitempty"`
	// SizeExpr carries an interval `size` that is still a metaparameter
	// EXPRESSION — a bare name like `"N_REC"` or a `{op, args}` tree — rather
	// than an integer. Exactly one of Size / SizeExpr is ever set.
	//
	// It exists because this registry is TYPED where every other binding's is a
	// plain dict, and esm-spec §4.7 "Index-set merge" hands it an UNFOLDED size:
	// a leaf mounted at a §4.7 edge whose axis is sized by a name only the
	// ASSEMBLER declares resolves with that size still symbolic, and the size
	// travels up into the mounting document's registry to be closed there
	// (§9.7.6 site 5). Decoding that into `Size *int` fails, and it failed as a
	// bare `json: cannot unmarshal string` — an anonymous unmarshal error where
	// the spec calls for either a resolved axis or a diagnostic. The custom
	// codec below routes a non-integer `size` here and writes it back out
	// verbatim, so the declaration survives parse -> emit unchanged.
	//
	// It is deliberately NOT a JSON field of its own: `size` is one wire key
	// with two inhabitants, and MarshalJSON re-emits it under that one key.
	SizeExpr any `json:"-"`
}

func (s IndexSet) MarshalJSON() ([]byte, error)

func (s *IndexSet) UnmarshalJSON(data []byte) error
```

IndexSet is one entry in the document-scoped `index_sets` registry (RFC semiring-faq-unified-ir §5.2): the declaration shape for an iteration domain referenced from a `faq` range via { "from": &lt;name&gt; } and from arrayed-variable `shape` lists. Exactly one of four kinds — each populating its own subset of fields:

- "interval":    a dense \[1..Size\] grid axis (Size required).
- "categorical": an explicit enumeration (Members required).
- "derived":     materialized from an index-set-producing node named by its id (FromFAQ required).
- "ragged":      a per-parent inner set backed by CSR factors (Of, Offsets, Values required).

The Go binding is schema-only: it stores and round-trips these declarations but does not resolve `{from}` references or evaluate the sets.

**Methods**

```go
func (s IndexSet) MarshalJSON() ([]byte, error)
```

MarshalJSON re-emits an unfolded `size` under the same `size` key it was read from, so a symbolic axis round-trips to itself.

```go
func (s *IndexSet) UnmarshalJSON(data []byte) error
```

UnmarshalJSON decodes an index-set declaration, routing a `size` that is not an integer literal into SizeExpr (see the field comment). Numbers still land in Size.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1123) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#IndexSet)

### `IsClosedFunction` {#x-isclosedfunction}

*function* · canonical name `is_closed_function`

```go
func IsClosedFunction(name string) bool
```

IsClosedFunction reports whether name is in the v0.3.0 closed registry.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/registered_functions.go#L112) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#IsClosedFunction)

### `LevelError` {#x-levelerror}

*constant* · canonical name `level_error`

```go
const LevelError = "error"
```

LevelError is a document-INVALIDATING finding. It is also the value of an UNSET Level: a StructuralError built without one is an error, which is why isWarning tests for the warning rather than against the error.

--- Diagnostic SEVERITY levels: the values StructuralError.Level and ValidationMessage.Level carry on the wire.

These are the last diagnostic vocabulary validate.go still spelled as bare literals after the Error\* / Code\* blocks moved here, and they are the same kind of thing: a value a consumer compares against, so the string is a contract and belongs beside the codes it qualifies. The values are unchanged.

Only two are emitted. "info" appears in ValidationMessage.Level's field comment as an admissible value but is produced nowhere, so it gets no constant — a constant for a level nothing raises would advertise a severity this binding cannot report. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L689) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LevelError)

### `LevelWarning` {#x-levelwarning}

*constant* · canonical name `level_warning`

```go
const LevelWarning = "warning"
```

LevelWarning is an ADVISORY finding that does not invalidate the document (e.g. duplicate\_reaction\_species).

--- Diagnostic SEVERITY levels: the values StructuralError.Level and ValidationMessage.Level carry on the wire.

These are the last diagnostic vocabulary validate.go still spelled as bare literals after the Error\* / Code\* blocks moved here, and they are the same kind of thing: a value a consumer compares against, so the string is a contract and belongs beside the codes it qualifies. The values are unchanged.

Only two are emitted. "info" appears in ValidationMessage.Level's field comment as an admissible value but is produced nowhere, so it gets no constant — a constant for a level nothing raises would advertise a severity this binding cannot report. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L692) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LevelWarning)

### `LiftedShape` {#x-liftedshape}

*type* · canonical name `lifted_shape`

```go
type LiftedShape struct {
	Name  string
	Shape []int
}
```

LiftedShape is the concrete integer grid shape the pointwise spatial lift (esm-spec §10.5) assigned to one lifted state variable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L337) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LiftedShape)

### `LoadOption` {#x-loadoption}

*type* · canonical name `load_option`

```go
type LoadOption func(*loadOptions)
```

LoadOption configures a LoadPath / LoadString / LoadDocument call.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse.go#L19) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LoadOption)

### `MaxRewritePasses` {#x-maxrewritepasses}

*constant* · canonical name `max_rewrite_passes`

```go
const MaxRewritePasses = 64
```

MaxRewritePasses is the maximum number of productive rewrite passes before a file is rejected as non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`). Pinned identically across all bindings so the accept/reject decision — and the resulting fixpoint — is byte-identical everywhere.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L120) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MaxRewritePasses)

### `ModelSummary` {#x-modelsummary}

*function* · canonical name `model_summary`

```go
func ModelSummary(esm *ESMFile) string
```

ModelSummary returns a structured model summary display showing all models, reaction systems, data loaders, coupling, domain, and solver as specified in Section 6.3

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/display.go#L1326) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ModelSummary)

### `NewCadenceClassifier` {#x-newcadenceclassifier}

*function* · canonical name `new_cadence_classifier`

```go
func NewCadenceClassifier(file *ESMFile, model *Model) *CadenceClassifier
```

NewCadenceClassifier builds the classifier for one model of a document. Pass the whole file so the `data` update's source refinement (§5.7.2) can resolve; a nil file is accepted and simply loses that refinement.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L142) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NewCadenceClassifier)

### `NodeKindAlgebraic` {#x-nodekindalgebraic}

*constant* · canonical name `node_kind_algebraic`

```go
const NodeKindAlgebraic = "algebraic"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L87) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindAlgebraic)

### `NodeKindBrownian` {#x-nodekindbrownian}

*constant* · canonical name `node_kind_brownian`

```go
const NodeKindBrownian = "brownian"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L90) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindBrownian)

### `NodeKindDiscrete` {#x-nodekinddiscrete}

*constant* · canonical name `node_kind_discrete`

```go
const NodeKindDiscrete = "discrete"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L91) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindDiscrete)

### `NodeKindObserved` {#x-nodekindobserved}

*constant* · canonical name `node_kind_observed`

```go
const NodeKindObserved = "observed"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L89) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindObserved)

### `NodeKindParameter` {#x-nodekindparameter}

*constant* · canonical name `node_kind_parameter`

```go
const NodeKindParameter = "parameter"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L88) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindParameter)

### `NodeKindSpecies` {#x-nodekindspecies}

*constant* · canonical name `node_kind_species`

```go
const NodeKindSpecies = "species"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L92) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindSpecies)

### `NodeKindState` {#x-nodekindstate}

*constant* · canonical name `node_kind_state`

```go
const NodeKindState = "state"
```

Graph node kinds (esm-libraries-spec §4.8.2).

This is the GRAPH vocabulary, which is COARSER than the §6.3.1 classifier partition the package computes internally: a sampled parameter and a constant parameter are both plain "parameter" here. The classifier names themselves (see RoleSampled / RoleConstant below) are unchanged; only the graph's node label uses these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L86) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NodeKindState)

### `NonEquationIndex` {#x-nonequationindex}

*constant* · canonical name `non_equation_index`

```go
const NonEquationIndex = -1
```

NonEquationIndex is the EquationIndex sentinel for a dependency that does not originate from a positionally-numbered equation or reaction: a coupling variable map folded in by ExpressionGraphOptions.MergeCoupled, and the synthetic expr\_result edges of a bare-expression target.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L122) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#NonEquationIndex)

### `OpConst` {#x-opconst}

*constant* · canonical name `op_const`

```go
const OpConst = "const"
```

inline literal payload node

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L645) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpConst)

### `OpDerivative` {#x-opderivative}

*constant* · canonical name `op_derivative`

```go
const OpDerivative = "D"
```

derivative op (structural time derivative, or a spatial rewrite target)

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L643) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpDerivative)

### `OpEnum` {#x-openum}

*constant* · canonical name `op_enum`

```go
const OpEnum = "enum"
```

enum symbol (lowered to const at load)

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L647) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpEnum)

### `OperatorApplyCoupling` {#x-operatorapplycoupling}

*type* · canonical name `operator_apply_coupling`

```go
type OperatorApplyCoupling struct {
	Type        string  `json:"type"` // "operator_apply"
	Operator    string  `json:"operator"`
	Description *string `json:"description,omitempty"`
}

func (o OperatorApplyCoupling) CouplingType() string
```

OperatorApplyCoupling represents operator application

**Methods**

```go
func (o OperatorApplyCoupling) CouplingType() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L946) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OperatorApplyCoupling)

### `OperatorComposeCoupling` {#x-operatorcomposecoupling}

*type* · canonical name `operator_compose_coupling`

```go
type OperatorComposeCoupling struct {
	Type      string         `json:"type"` // "operator_compose"
	Systems   [2]string      `json:"systems"`
	Translate map[string]any `json:"translate,omitempty"`
	Lifting   *string        `json:"lifting,omitempty"`
	// RequireMatch is the entry's MERGE INTENT (esm-libraries-spec §4.7.1
	// step 5). TRI-STATE, which is why it is a pointer: nil is NOT false.
	//
	//	nil    the author has not said. A zero-merge is then
	//	       CodeOperatorComposeNoMerge, an ERROR (such an entry is
	//	       indistinguishable from one that is absent); a partial merge is a
	//	       warning.
	//	true   the Systems[1] equations are CONTRIBUTIONS and every one must
	//	       land; any shortfall, partial included, is a hard refusal.
	//	false  a standalone-contributing operator, DECLARED. Unmatched equations
	//	       are expected and nothing is reported.
	//
	// `omitempty` on a pointer drops only nil, so an explicit false survives the
	// round trip -- dropping it would silently re-arm the zero-merge refusal on
	// every document that opted out.
	RequireMatch *bool   `json:"require_match,omitempty"`
	Description  *string `json:"description,omitempty"`
}

func (o OperatorComposeCoupling) CouplingType() string
```

OperatorComposeCoupling represents operator composition

**Methods**

```go
func (o OperatorComposeCoupling) CouplingType() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L871) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OperatorComposeCoupling)

### `OpFn` {#x-opfn}

*constant* · canonical name `op_fn`

```go
const OpFn = "fn"
```

closed-registry function call

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L646) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpFn)

### `OpIC` {#x-opic}

*constant* · canonical name `op_ic`

```go
const OpIC = "ic"
```

initial-condition wrapper

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L644) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpIC)

### `OpMakearray` {#x-opmakearray}

*constant* · canonical name `op_makearray`

```go
const OpMakearray = "makearray"
```

hyper-rectangular array constructor

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L648) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpMakearray)

### `OpTableLookup` {#x-optablelookup}

*constant* · canonical name `op_table_lookup`

```go
const OpTableLookup = "table_lookup"
```

sampled function-table query

--- Spec enum literal: AST op names used across more than one file (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in lower\_expression\_templates.go and is intentionally not redeclared here. ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L649) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OpTableLookup)

### `ParseCadence` {#x-parsecadence}

*function* · canonical name `parse_cadence`

```go
func ParseCadence(s string) (Cadence, bool)
```

ParseCadence maps an `expect_cadence` annotation to its class.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L61) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseCadence)

### `PartialSubstitute` {#x-partialsubstitute}

*function* · canonical name `partial_substitute`

```go
func PartialSubstitute(expr Expression, bindings map[string]Expression, keepSymbolic []string) (Expression, error)
```

PartialSubstitute performs substitution but preserves the original structure when possible. This is useful when you want to substitute some variables but keep others as symbolic references.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L205) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PartialSubstitute)

### `PropagateDimension` {#x-propagatedimension}

*function* · canonical name `propagate_dimension`

```go
func PropagateDimension(expr Expression, env map[string]Unit) (*Unit, error)
```

PropagateDimension walks an Expression AST and returns the resulting Unit. It mirrors the Julia reference implementation (get\_expression\_dimensions):

- numeric literals → indeterminate (nil, nil), except where their meaning is determined: neutral in "+"/"-", and read by value as an exponent
- variable names → looked up in env; unknown variables return nil, nil (dimensional analysis is best-effort when unit annotations are missing)
- "+", "-" require all operands to share a dimension
- "\*" multiplies dimensions, "/" divides
- "^" requires a dimensionless constant exponent (which may be RATIONAL)
- CIRCULAR functions (sin/cos/tan) take an ANGLE or a dimensionless number and return dimensionless; INVERSE circular functions (asin/acos/atan, atan2) take dimensionless arguments and RETURN AN ANGLE (rad)
- the remaining transcendentals (exp/log/ln/log10, the hyperbolics) require a dimensionless argument and return dimensionless; sqrt halves the operand's dimension
- "D" (derivative) divides by the wrt variable's unit (default "t")

A non-nil error signals a dimensional inconsistency discovered during propagation. The caller decides whether to turn that into a UnitWarning.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L1662) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PropagateDimension)

### `Rat` {#x-rat}

*type* · canonical name `rat`

```go
type Rat struct {
	Num int32 `json:"num"`
	Den int32 `json:"den"`
}

func (r Rat) Add(o Rat) Rat

func (r Rat) AddChecked(o Rat) (Rat, bool)

func (r Rat) Equal(o Rat) bool

func (r Rat) Float() float64

func (r Rat) IsZero() bool

func (r Rat) Mul(o Rat) Rat

func (r Rat) MulChecked(o Rat) (Rat, bool)

func (r Rat) Neg() Rat

func (r Rat) String() string

func (r Rat) Sub(o Rat) Rat

func (r Rat) SubChecked(o Rat) (Rat, bool)
```

Rat is an exact RATIONAL unit exponent (num/den).

Dimension exponents are rational, not integer: `1/s^0.5` is the noise intensity of an SDE (tests/fixtures/sde/\*.esm), `m^(1/2)` and `s^(-1/2)` appear wherever a square root of a dimensional quantity does, and `sqrt(x)` halves whatever exponents x carries. An int8 exponent vector cannot represent any of them, so — now that an unparseable unit is a HARD ERROR — an integer representation falsely rejects those files.

The ZERO VALUE is the exponent 0: every operation normalizes a zero (or missing) denominator to 1 via fix(), so `Rat{}` and a composite literal such as `Rat{Num: 2}` are both well-formed. Nothing compares two Rats (or two Dimensions) with `==` — Equal cross-multiplies, so a non-reduced value never silently compares unequal to its reduced form.

**Methods**

```go
func (r Rat) Add(o Rat) Rat
```

Add returns r + o. It panics with errExponentOverflow on overflow.

```go
func (r Rat) AddChecked(o Rat) (Rat, bool)
```

AddChecked returns r + o and whether it fits the Rat representation.

```go
func (r Rat) Equal(o Rat) bool
```

Equal reports whether two exponents denote the same rational number, regardless of whether either is in lowest terms.

```go
func (r Rat) Float() float64
```

Float returns the exponent as a float64 (used for scale arithmetic).

```go
func (r Rat) IsZero() bool
```

IsZero reports whether the exponent is 0.

```go
func (r Rat) Mul(o Rat) Rat
```

Mul returns r × o. It panics with errExponentOverflow on overflow.

```go
func (r Rat) MulChecked(o Rat) (Rat, bool)
```

MulChecked returns r × o and whether it fits the Rat representation.

```go
func (r Rat) Neg() Rat
```

Neg returns −r.

```go
func (r Rat) String() string
```

String renders the exponent: "2", "-1", "1/2", "-3/2".

```go
func (r Rat) Sub(o Rat) Rat
```

Sub returns r − o. It panics with errExponentOverflow on overflow.

```go
func (r Rat) SubChecked(o Rat) (Rat, bool)
```

SubChecked returns r − o and whether it fits the Rat representation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L28) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Rat)

### `RemoveEquationAt` {#x-removeequationat}

*function* · canonical name `remove_equation_at`

```go
func RemoveEquationAt(model Model, index int) (Model, error)
```

RemoveEquationAt returns a copy of `model` without the equation at `index`. Indices are 0-based (Julia's are 1-based; Go and TypeScript agree on 0).

Returns \*EntityNotFoundError when the index is out of range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L850) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveEquationAt)

### `RemoveEquationByLHS` {#x-removeequationbylhs}

*function* · canonical name `remove_equation_by_lhs`

```go
func RemoveEquationByLHS(model Model, lhs Expression) (Model, error)
```

RemoveEquationByLHS returns a copy of `model` without the FIRST equation whose left-hand side structurally equals `lhs`.

Matching uses field-aware structural equality (exprEqual), so e.g. two `const` nodes with different `value`s, or two derivatives differing only in `wrt`, are not treated as the same equation.

Returns \*EntityNotFoundError when no equation matches. TypeScript and Julia spell this as an overload of their single remove-equation entry point; Go has no overloading, so the index and pattern forms are separate functions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L872) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveEquationByLHS)

### `RenameVariableInFile` {#x-renamevariableinfile}

*function* · canonical name `rename_variable_in_file`

```go
func RenameVariableInFile(file ESMFile, modelName, oldName, newName string) (ESMFile, error)
```

RenameVariableInFile renames a variable of the model `modelName` throughout `file`, and is the scope-aware counterpart of RenameVariable.

Beyond what RenameVariable does, it:

- resolves SCOPED references while rewriting, so a self-qualified read of the variable ("EarthSystem.global\_forcing" inside model EarthSystem) is rewritten rather than left dangling; and
- rewrites the coupling endpoints that name the variable — a `variable_map`'s `from`/`to` and an `event` coupling's affect targets — which are plain strings in the file, not expressions inside the model, and so are out of reach of any model-scoped rewrite.

Returns \*EntityNotFoundError when the model or the variable does not exist.

This entry point has no counterpart in the other bindings: TypeScript, Julia, Rust and Python all stop at the model-scoped rename. It is additive — the model-scoped RenameVariable keeps its cross-binding behaviour unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L770) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RenameVariableInFile)

### `ResolveAndLower` {#x-resolveandlower}

*function* · canonical name `resolve_and_lower`

```go
func ResolveAndLower(jsonStr, basePath string, metaparameters map[string]int64) (string, error)
```

ResolveAndLower is the exported raw §9.7 pipeline — resolveAndLowerJSON verbatim: load-time template-import/metaparameter resolution against basePath, then the §9.6.3 rewrite fixpoint AND Expand-at-build, returning the post-lowering Option-A image as JSON (numeric tokens preserved via json.Number). This is the entry point that reproduces the committed `expanded.esm` goldens (CONFORMANCE\_SPEC.md §5.9) without going through the typed Load round-trip, whose serializer normalizes fields.

It is NOT the right entry point for a conformance runner that must be compared against the other four bindings: they all stop at the Option-B image, and expansion multiplies out a reference-dense document. Use ResolveAndLowerReferencePreserving, of which this is Expand ∘ that.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L1707) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveAndLower)

### `ResolveAndLowerReferencePreserving` {#x-resolveandlowerreferencepreserving}

*function* · canonical name `resolve_and_lower_reference_preserving`

```go
func ResolveAndLowerReferencePreserving(jsonStr, basePath string, metaparameters map[string]int64) (string, error)
```

ResolveAndLowerReferencePreserving is the raw §9.7 pipeline WITHOUT the Expand-at-build step: load-time template-import/metaparameter resolution against basePath, §9.7.10 form-B coupling injection, then the §9.6.3 rewrite fixpoint — stopping at the Option-B image. Surviving `apply_expression_template` references stay as leaves (§9.6.4 rule 4) and each component keeps its `expression_templates` registry (rule 5). Returns the post-lowering document as JSON, numeric tokens preserved via json.Number.

This is what a conformance runner should drive to produce an artifact COMPARABLE WITH THE OTHER FOUR BINDINGS. The Julia reference, Python (`resolve_template_machinery` → `lower_expression_templates`), TypeScript (`resolveTemplateMachinery` → `lowerExpressionTemplates`) and Rust all stop here; only Go's fused ResolveAndLower went on to Expand, so Go alone emitted the Option-A image and could not be compared to the other four structurally.

It is also the only pipeline that TERMINATES on a reference-dense document. Expansion is what Option B exists to avoid: it substitutes each reference's body at every call site, so a document whose templates reference templates multiplies out. EarthSciDiscretizations' `duo_*` cases were OOM-killed past 9 GB going through ResolveAndLower, which is why the Go runner had no output to compare at all on that family.

ResolveAndLower remains the Option-A surface: it is this function followed by Expand, and reproduces the committed `expanded.esm` goldens. Prefer this one unless you specifically need the expanded image.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L1736) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveAndLowerReferencePreserving)

### `ResolveReferencesInFile` {#x-resolvereferencesinfile}

*function* · canonical name `resolve_references_in_file`

```go
func ResolveReferencesInFile(file *ESMFile) (map[string]*ReferenceGraph, error)
```

ResolveReferencesInFile is the typed convenience over ResolveReferences: it renders `file` to its raw view and resolves every model in it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L897) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveReferencesInFile)

### `RoleAlgebraic` {#x-rolealgebraic}

*constant* · canonical name `role_algebraic`

```go
const RoleAlgebraic = "algebraic"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L638) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleAlgebraic)

### `RoleBrownian` {#x-rolebrownian}

*constant* · canonical name `role_brownian`

```go
const RoleBrownian = "brownian"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L639) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleBrownian)

### `RoleConstant` {#x-roleconstant}

*constant* · canonical name `role_constant`

```go
const RoleConstant = "constant"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L642) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleConstant)

### `RoleDiscrete` {#x-rolediscrete}

*constant* · canonical name `role_discrete`

```go
const RoleDiscrete = "discrete"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L640) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleDiscrete)

### `RoleObserved` {#x-roleobserved}

*constant* · canonical name `role_observed`

```go
const RoleObserved = "observed"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L637) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleObserved)

### `RoleODEState` {#x-roleodestate}

*constant* · canonical name `role_ode_state`

```go
const RoleODEState = "ode_state"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L636) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleODEState)

### `RoleSampled` {#x-rolesampled}

*constant* · canonical name `role_sampled`

```go
const RoleSampled = "sampled"
```

Derived variable-role labels (esm-spec §6.3.1), the FINER partition the classification API computes. The expression graph maps them onto the coarser §4.8.2 NodeKind\* vocabulary through graphKindForRole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L641) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RoleSampled)

### `RuleEngineError` {#x-ruleengineerror}

*error* · canonical name `rule_engine_error`

```go
type RuleEngineError struct {
	Code    string
	Message string
}

func (e *RuleEngineError) DiagnosticCode() string

func (e *RuleEngineError) Error() string
```

RuleEngineError is a stable-coded error raised by the DAE contract. Code is one of the RFC §12 codes (e.g. E\_NONTRIVIAL\_DAE).

**Methods**

```go
func (e *RuleEngineError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *RuleEngineError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/dae.go#L19) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RuleEngineError)

### `SerializeExpression` {#x-serializeexpression}

*function* · canonical name `serialize_expression`

```go
func SerializeExpression(expr Expression) (string, error)
```

SerializeExpression serializes just an expression to JSON

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L178) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SerializeExpression)

### `SerializeExpressionCompact` {#x-serializeexpressioncompact}

*function* · canonical name `serialize_expression_compact`

```go
func SerializeExpressionCompact(expr Expression) (string, error)
```

SerializeExpressionCompact serializes just an expression to compact JSON

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L187) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SerializeExpressionCompact)

### `SerializeModel` {#x-serializemodel}

*function* · canonical name `serialize_model`

```go
func SerializeModel(model *Model) (string, error)
```

SerializeModel serializes just a model to JSON

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L196) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SerializeModel)

### `SerializeReactionSystem` {#x-serializereactionsystem}

*function* · canonical name `serialize_reaction_system`

```go
func SerializeReactionSystem(system *ReactionSystem) (string, error)
```

SerializeReactionSystem serializes just a reaction system to JSON

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L209) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SerializeReactionSystem)

### `StructuralValidationResult` {#x-structuralvalidationresult}

*type* · canonical name `structural_validation_result`

```go
type StructuralValidationResult struct {
	Valid            bool              `json:"valid"`
	StructuralErrors []StructuralError `json:"structural_errors"`
	UnitWarnings     []UnitWarning     `json:"unit_warnings"`
}
```

StructuralValidationResult holds the code-bearing structural validation output. It is the return type of ValidateStructuralWithCodes, and the source of the structural and unit findings Validate reports.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L278) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#StructuralValidationResult)

### `SubstituteInAffectEquation` {#x-substituteinaffectequation}

*function* · canonical name `substitute_in_affect_equation`

```go
func SubstituteInAffectEquation(affect AffectEquation, bindings map[string]Expression) (AffectEquation, error)
```

SubstituteInAffectEquation substitutes variables in an affect equation. Note: LHS is a variable name (string) so it's not substituted, only RHS.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L154) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInAffectEquation)

### `SubstituteInEquation` {#x-substituteinequation}

*function* · canonical name `substitute_in_equation`

```go
func SubstituteInEquation(eq Equation, bindings map[string]Expression) (Equation, error)
```

SubstituteInEquation substitutes variables in both LHS and RHS of an equation. The equation's `_comment` annotation rides along: substitution rewrites the expressions, it does not make the author's note about this equation stale.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L140) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInEquation)

### `SubstituteInFile` {#x-substituteinfile}

*function* · canonical name `substitute_in_file`

```go
func SubstituteInFile(file ESMFile, bindings map[string]Expression) (ESMFile, error)
```

SubstituteInFile performs substitution across an entire ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L176) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInFile)

### `SubstituteInFileWithContext` {#x-substituteinfilewithcontext}

*function* · canonical name `substitute_in_file_with_context`

```go
func SubstituteInFileWithContext(file ESMFile, bindings map[string]Expression) (ESMFile, error)
```

SubstituteInFileWithContext performs substitution across an entire ESM file with scoped reference support.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L404) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInFileWithContext)

### `SubstrateProduct` {#x-substrateproduct}

*type* · canonical name `substrate_product`

```go
type SubstrateProduct struct {
	Species       string  `json:"species"`
	Stoichiometry float64 `json:"stoichiometry"`
}
```

SubstrateProduct represents a substrate or product in a reaction.

Stoichiometry MUST be a positive finite number; fractional coefficients (e.g. 0.87 CH2O) are allowed. Integer-valued coefficients round-trip as integers via encoding/json because float64(1) marshals to "1" in Go's standard encoder.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L515) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstrateProduct)

### `SystemKindDAE` {#x-systemkinddae}

*constant* · canonical name `system_kind_dae`

```go
const SystemKindDAE = "dae"
```

--- Spec enum literal: Model.SystemKind and the ode/dae DAE classification (esm-spec §6 / dae.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L656) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKindDAE)

### `SystemKindNonlinear` {#x-systemkindnonlinear}

*constant* · canonical name `system_kind_nonlinear`

```go
const SystemKindNonlinear = "nonlinear"
```

--- Spec enum literal: Model.SystemKind and the ode/dae DAE classification (esm-spec §6 / dae.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L657) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKindNonlinear)

### `SystemKindODE` {#x-systemkindode}

*constant* · canonical name `system_kind_ode`

```go
const SystemKindODE = "ode"
```

--- Spec enum literal: Model.SystemKind and the ode/dae DAE classification (esm-spec §6 / dae.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L655) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKindODE)

### `SystemKindPDE` {#x-systemkindpde}

*constant* · canonical name `system_kind_pde`

```go
const SystemKindPDE = "pde"
```

--- Spec enum literal: Model.SystemKind and the ode/dae DAE classification (esm-spec §6 / dae.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L659) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKindPDE)

### `SystemKindSDE` {#x-systemkindsde}

*constant* · canonical name `system_kind_sde`

```go
const SystemKindSDE = "sde"
```

--- Spec enum literal: Model.SystemKind and the ode/dae DAE classification (esm-spec §6 / dae.go). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L658) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKindSDE)

### `Test` {#x-test}

*type* · canonical name `test`

```go
type Test struct {
	ID          string  `json:"id"`
	Description *string `json:"description,omitempty"`
	// InitialConditions and ParameterOverrides each map a LOCAL variable name to
	// its value for this run. A value is a number, or — for a SHAPED variable —
	// INLINE ARRAY DATA: a row-major nested JSON array matching the declared
	// shape after metaparameter folding (esm-spec §6.6.2, §6.3). Hence `any`
	// rather than float64: this binding is a rewrite-only port with no
	// simulator, so it carries the authored value through parse → emit
	// verbatim rather than interpreting it.
	InitialConditions  map[string]any `json:"initial_conditions,omitempty"`
	ParameterOverrides map[string]any `json:"parameter_overrides,omitempty"`
	TimeSpan           TimeSpan       `json:"time_span"`
	Tolerance          *Tolerance     `json:"tolerance,omitempty"`
	// ExpressionTemplateImports are raw §9.7.2 import entries injected into the
	// ENCLOSING component's template scope for THIS test's run only (esm-spec
	// §9.7.10 form C / §6.6.6): the discretization a discretization-agnostic PDE
	// leaf is lowered under in a per-test ephemeral build. Authored per-run
	// config (a peer of ParameterOverrides), so — unlike a component's own
	// imports — this DOES survive parse → emit. Consumed only by an ephemeral
	// per-run build, which this binding does not perform (no numeric solver).
	ExpressionTemplateImports []any       `json:"expression_template_imports,omitempty"`
	Assertions                []Assertion `json:"assertions"`
}
```

Test is an inline validation test for a Model or ReactionSystem.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L615) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Test)

### `ToUnicodeSpaced` {#x-tounicodespaced}

*function* · canonical name `to_unicode_spaced`

```go
func ToUnicodeSpaced(target Expression) string
```

ToUnicodeSpaced converts an expression to a Unicode string identical to ToUnicode except that the multiplication operator renders as " · " (spaced) for readability in model-summary displays. The spacing is produced at the operator during formatting (FmtUnicodeSpaced), not by a post-hoc string replace, so a "·" inside a rendered leaf (e.g. a hydrate chemical formula) is never disturbed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/display.go#L1320) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToUnicodeSpaced)

### `UnmarshalCouplingArray` {#x-unmarshalcouplingarray}

*function* · canonical name `unmarshal_coupling_array`

```go
func UnmarshalCouplingArray(data []byte) ([]CouplingEntry, error)
```

UnmarshalCouplingArray handles the deserialization of the coupling array

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/decode.go#L715) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnmarshalCouplingArray)

### `UnmarshalCouplingEntry` {#x-unmarshalcouplingentry}

*function* · canonical name `unmarshal_coupling_entry`

```go
func UnmarshalCouplingEntry(data []byte) (CouplingEntry, error)
```

UnmarshalCouplingEntry handles the deserialization of a single coupling entry

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/decode.go#L735) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnmarshalCouplingEntry)

### `UnmarshalExpression` {#x-unmarshalexpression}

*function* · canonical name `unmarshal_expression`

```go
func UnmarshalExpression(data []byte) (Expression, error)
```

UnmarshalExpression handles the custom unmarshaling for Expression union type. Numeric literals preserve the RFC §5.4.6 round-trip parse rule: a JSON-number token with '.', 'e', or 'E' parses to float64; otherwise to int64 (falling back to float64 if out of int64 range).

EVERY expression-bearing field is normalized, not just `args`. The decoded node is routed through the shared field-preserving walker (mapExprChildren), so an operator node nested in a sidecar field — an aggregate's `expr` / `filter` / `key` / `join`, an integral's `lower` / `upper`, a table\_lookup's `axes` / `output`, a makearray's `values` / `regions`, an apply\_expression\_template's `bindings` — arrives as a real ExprNode with its own children normalized in turn, exactly like a child of `args`. Before this, only `args` was normalized and every other field stayed a raw map\[string\]interface{}, which made those subtrees invisible to Substitute, FreeVariables, Canonicalize and the enum-lowering pass (audit G3, and the G15 enum-lowering half of it).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/decode.go#L38) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnmarshalExpression)

### `UpdateKindCondition` {#x-updatekindcondition}

*constant* · canonical name `update_kind_condition`

```go
const UpdateKindCondition = "condition"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L294) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindCondition)

### `UpdateKindCrossing` {#x-updatekindcrossing}

*constant* · canonical name `update_kind_crossing`

```go
const UpdateKindCrossing = "crossing"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L295) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindCrossing)

### `UpdateKindData` {#x-updatekinddata}

*constant* · canonical name `update_kind_data`

```go
const UpdateKindData = "data"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L296) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindData)

### `UpdateKindRemesh` {#x-updatekindremesh}

*constant* · canonical name `update_kind_remesh`

```go
const UpdateKindRemesh = "remesh"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L297) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindRemesh)

### `UpdateKindSchedule` {#x-updatekindschedule}

*constant* · canonical name `update_kind_schedule`

```go
const UpdateKindSchedule = "schedule"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L293) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindSchedule)

### `UpdateKindWiener` {#x-updatekindwiener}

*constant* · canonical name `update_kind_wiener`

```go
const UpdateKindWiener = "wiener"
```

Update kind literals (esm-spec 5.4, "When: the six kinds").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L292) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UpdateKindWiener)

### `ValidateStructuralWithCodes` {#x-validatestructuralwithcodes}

*function* · canonical name `validate_structural_with_codes`

```go
func ValidateStructuralWithCodes(file *ESMFile) *StructuralValidationResult
```

ValidateStructuralWithCodes performs structural validation and returns structured errors directly

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L319) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidateStructuralWithCodes)

### `ValidationMessage` {#x-validationmessage}

*type* · canonical name `validation_message`

```go
type ValidationMessage struct {
	Level   string `json:"level"`   // "error", "warning", "info"
	Message string `json:"message"` // Human-readable description
	Path    string `json:"path"`    // JSON path to the problematic element
}
```

ValidationMessage represents a single validation issue in the legacy DetailedValidationResult surface returned by ValidateStructural.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L84) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidationMessage)

### `VariableAdjacency` {#x-variableadjacency}

*type* · canonical name `variable_adjacency`

```go
type VariableAdjacency struct {
	Neighbor VariableNode
	Edge     DependencyEdge
}
```

VariableAdjacency is one entry returned by ExpressionGraph.AdjacencyVariable: a neighbouring variable node and the dependency edge that reaches it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L995) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableAdjacency)

### `VariableExprSite` {#x-variableexprsite}

*type* · canonical name `variable_expr_site`

```go
type VariableExprSite struct {
	// Path is the JSON-pointer suffix from the variable, e.g.
	// "/update/expression" or "/update/1/from/unit_conversion".
	Path string
	// Expr is the Expression currently at the position.
	Expr Expression
	// Set writes a replacement back into the variable.
	Set func(Expression)
}
```

VariableExprSite is one Expression-bearing position inside a ModelVariable, with the JSON-pointer suffix that addresses it and a setter that writes a rewritten tree back.

esm 1.0.0 moved an observed unknown's defining expression OUT of the variable (into the model's `equations`), and moved parameter mutation IN (as `update`). The positions a pass must visit on a variable are therefore no longer "the `expression` field" but the update block's `when` / `expression` and its data binding's `unit_conversion` — exactly the three variable-scoped rows of the esm-spec §4.9.5 table. Enumerating them ONCE here is what stops the five passes that walk variables (enum lowering, parse normalization, substitution, reference integrity, unit propagation) from each growing a different hole.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/expr_walk.go#L335) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableExprSite)

### `VariableExprSites` {#x-variableexprsites}

*function* · canonical name `variable_expr_sites`

```go
func VariableExprSites(mv *ModelVariable) []VariableExprSite
```

VariableExprSites returns every Expression-bearing position of mv, in a stable order. mv must be addressable; the returned setters mutate it in place.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/expr_walk.go#L347) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableExprSites)

### `VariableMapCoupling` {#x-variablemapcoupling}

*type* · canonical name `variable_map_coupling`

```go
type VariableMapCoupling struct {
	Type        string     `json:"type"` // "variable_map"
	From        string     `json:"from"`
	To          string     `json:"to"`
	Transform   Expression `json:"transform"` // string kind | ExprNode
	Factor      *float64   `json:"factor,omitempty"`
	Lifting     *string    `json:"lifting,omitempty"`
	Description *string    `json:"description,omitempty"`
}

func (v VariableMapCoupling) CouplingType() string

func (v VariableMapCoupling) TransformIsExpression() bool

func (v VariableMapCoupling) TransformKind() string

func (v *VariableMapCoupling) UnmarshalJSON(data []byte) error
```

VariableMapCoupling represents variable mapping. Transform is a union (mirrors DataSourceBinding.UnitConversion): either one of the named string kinds ("param\_to\_var", "identity", "additive", "multiplicative", "conversion\_factor") held as a string, or a widened Expression transform held as an ExprNode (esm-spec §8.6/§10.4/§10.5 — the regridding form). Expression transforms are always operator-node OBJECTS on the wire; bare string/number Expression spellings are not admissible (the string space is reserved for the named kinds).

**Methods**

```go
func (v VariableMapCoupling) CouplingType() string
```

```go
func (v VariableMapCoupling) TransformIsExpression() bool
```

TransformIsExpression reports whether the transform is the widened Expression form (an operator node) rather than a named string kind.

```go
func (v VariableMapCoupling) TransformKind() string
```

TransformKind returns the named string transform kind, or "" when the transform is an Expression AST (or absent).

```go
func (v *VariableMapCoupling) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for VariableMapCoupling (handles the transform union: named string kind | ExpressionNode object). A string transform is stored as a string; an object transform is decoded via UnmarshalExpression into an ExprNode. Any other JSON shape (number, array, boolean) is rejected: an Expression transform is always an operator-node OBJECT (the degenerate bare-reference / literal spellings are reserved for the string kinds).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L916) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableMapCoupling)

### `VarTypeParameter` {#x-vartypeparameter}

*constant* · canonical name `var_type_parameter`

```go
const VarTypeParameter = "parameter"
```

VarTypeParameter is a quantity supplied to the solver, valued by `default` or a `distribution` and optionally refreshed by an `update`.

--- Spec enum literal: ModelVariable.Type (esm-spec §6.3). esm 1.0.0 declares exactly TWO. Whether an unknown is a state, an observed, or an algebraic unknown, and whether a parameter is Brownian or discrete, is DERIVED: call the classification functions in classify.go (esm-spec §6.3.1). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L636) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VarTypeParameter)

### `VarTypeUnknown` {#x-vartypeunknown}

*constant* · canonical name `var_type_unknown`

```go
const VarTypeUnknown = "unknown"
```

VarTypeUnknown is a quantity the solver solves for; its behaviour is stated by the model's `equations` and nowhere else.

--- Spec enum literal: ModelVariable.Type (esm-spec §6.3). esm 1.0.0 declares exactly TWO. Whether an unknown is a state, an observed, or an algebraic unknown, and whether a parameter is Brownian or discrete, is DERIVED: call the classification functions in classify.go (esm-spec §6.3.1). ---

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/codes.go#L633) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VarTypeUnknown)

### `VertexKindFactor` {#x-vertexkindfactor}

*constant* · canonical name `vertex_kind_factor`

```go
const VertexKindFactor VertexKind = "factor"
```

VertexKindFactor is a factor named by a `join.on` reference.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L102) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VertexKindFactor)

### `VertexKindIndexSet` {#x-vertexkindindexset}

*constant* · canonical name `vertex_kind_index_set`

```go
const VertexKindIndexSet VertexKind = "index_set"
```

VertexKindIndexSet is a declared `index_sets` entry.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L100) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VertexKindIndexSet)

### `VertexKindNode` {#x-vertexkindnode}

*constant* · canonical name `vertex_kind_node`

```go
const VertexKindNode VertexKind = "node"
```

VertexKindNode is an expression node (aggregate, or `id`-bearing).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L98) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VertexKindNode)

### `WithBasePath` {#x-withbasepath}

*function* · canonical name `with_base_path`

```go
func WithBasePath(dir string) LoadOption
```

WithBasePath anchors relative `expression_template_imports` refs (esm-spec §9.7.2) for LoadString / LoadDocument input. LoadPath derives it from the file's directory automatically; an explicit WithBasePath overrides that.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse.go#L73) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#WithBasePath)

### `WithMetaparameters` {#x-withmetaparameters}

*function* · canonical name `with_metaparameters`

```go
func WithMetaparameters(m map[string]int64) LoadOption
```

WithMetaparameters binds the ROOT document's open metaparameters at the loader API (esm-spec §9.7.6 binding site 4): already-closed edge bindings win, API bindings beat `default`s. Binding a name the document does not declare fails with `template_import_unknown_name`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse.go#L66) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#WithMetaparameters)

### `WritePathCompact` {#x-writepathcompact}

*function* · canonical name `write_path_compact`

```go
func WritePathCompact(file *ESMFile, path string) error
```

WritePathCompact writes an ESM file to path in the compact canonical form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L158) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#WritePathCompact)
