package esm

import (
	"encoding/json"
	"fmt"

	"github.com/go-playground/validator/v10"
)

// ========================================
// 1. Expression Types
// ========================================

// ExprNode represents an operator node in the expression tree
type ExprNode struct {
	Op    string        `json:"op"`
	Args  []interface{} `json:"args"`
	Wrt   *string       `json:"wrt,omitempty"`   // for derivatives
	Dim   *string       `json:"dim,omitempty"`   // for grad
	Fn    *string       `json:"fn,omitempty"`    // for bc wrapper kind encoding
	Var   *string       `json:"var,omitempty"`   // integration variable name (for integral)
	Lower interface{}   `json:"lower,omitempty"` // lower integration bound (for integral)
	Upper interface{}   `json:"upper,omitempty"` // upper integration bound (for integral)
	// Name carries the dotted module path of a closed-registry function
	// (esm-spec §4.4 / §9.2) for `fn` op nodes — e.g. "datetime.julian_day".
	Name *string `json:"name,omitempty"`
	// Value carries the inline literal payload of a `const` op node
	// (esm-spec §4.2 / §9.3); `Args` MUST be empty for a const node. Any
	// JSON value (number, integer, or nested array thereof).
	Value interface{} `json:"value,omitempty"`
	// Table is the function_tables entry id targeted by a `table_lookup` op
	// (esm-spec §9.5).
	Table *string `json:"table,omitempty"`
	// TableAxes is the per-axis input-coordinate expression map for a
	// `table_lookup` op. Keys MUST match the names declared on the referenced
	// FunctionTable's Axes; values are arbitrary scalar Expressions. Args MUST
	// be empty for a table_lookup node.
	TableAxes map[string]Expression `json:"axes,omitempty"`
	// Output selects which output of a multi-output table to return for a
	// `table_lookup` op. Either a non-negative integer (0-based index into the
	// leading data dimension) or a string (an entry of the table's Outputs
	// list). Single-output tables MAY omit this (defaults to 0).
	Output interface{} `json:"output,omitempty"`
	// Attrs carries optional named scalar attributes for an OPEN rewrite-target
	// op (esm-spec §4.2). Mirrors the fixed `dim`/`side`/`wrt` slots the core ops
	// use, but is open: a custom op (e.g. `godunov_hamiltonian`) carries its
	// scheme parameters here. Modeled so a rewrite-target op that survives
	// lowering (loading is permissive) round-trips. Evaluable-core ops MUST NOT
	// use `attrs`. Structural `match` rules bind `attrs.<key>` params to matched
	// literals via generic object matching (esm-spec §9.6.1).
	Attrs map[string]interface{} `json:"attrs,omitempty"`

	// --- Structural / array-query op fields (esm-spec §4.2). These carry the
	// defining data of the closed structural tier in fields OTHER than `args`,
	// so the pretty-printer (display.go) can render them non-lossily. They are
	// stored as interface{}/raw slices so numeric literals inside them keep the
	// json.Number shape they had at parse time; the display code normalizes on
	// read. ---

	// Bindings is the param→expression map of an `apply_expression_template` op.
	Bindings map[string]interface{} `json:"bindings,omitempty"`
	// Regions is the list of hyper-rectangular index regions of a `makearray`
	// op; each region is a list of [lo, hi] bound pairs.
	Regions [][][]interface{} `json:"regions,omitempty"`
	// Values is the per-region value list of a `makearray` op (paired with
	// Regions by position).
	Values []interface{} `json:"values,omitempty"`
	// Shape is the target shape of a `reshape` op.
	Shape []interface{} `json:"shape,omitempty"`
	// Perm is the optional permutation of a `transpose` op.
	Perm []interface{} `json:"perm,omitempty"`
	// Axis is the concatenation axis of a `concat` op.
	Axis interface{} `json:"axis,omitempty"`
	// Manifold is the geometry manifold of `intersect_polygon` /
	// `polygon_intersection_area` ops.
	Manifold *string `json:"manifold,omitempty"`
	// OutputIdx are the surviving (free) index names of an `aggregate` op.
	OutputIdx []interface{} `json:"output_idx,omitempty"`
	// Expr is the reduced sub-expression of an `aggregate` / `argmin` / `argmax`
	// op.
	Expr interface{} `json:"expr,omitempty"`
	// Reduce is the scalar reduction operator of an `aggregate` op.
	Reduce *string `json:"reduce,omitempty"`
	// Semiring is the optional named semiring of an `aggregate` op.
	Semiring *string `json:"semiring,omitempty"`
	// Ranges maps a bound index name to its iteration range for `aggregate` /
	// `argmin` / `argmax` ops.
	Ranges map[string]interface{} `json:"ranges,omitempty"`
	// Join is the optional list of join clauses of an `aggregate` op.
	Join []interface{} `json:"join,omitempty"`
	// Filter is the optional predicate of an `aggregate` op.
	Filter interface{} `json:"filter,omitempty"`
	// Distinct marks an `aggregate` op as reducing over distinct values.
	Distinct *bool `json:"distinct,omitempty"`
	// Key is the optional grouping key of an `aggregate` op.
	Key interface{} `json:"key,omitempty"`
	// Arg is the witness index name of an `argmin` / `argmax` op.
	Arg *string `json:"arg,omitempty"`
}

// Expression represents the union type: number | string | ExprNode
// In Go, this is handled by using interface{} and custom unmarshaling
type Expression interface{}

// Equation represents a mathematical equation with LHS and RHS
type Equation struct {
	LHS Expression `json:"lhs"`
	RHS Expression `json:"rhs"`
}

// AffectEquation represents an equation that affects a variable (for events)
type AffectEquation struct {
	LHS string     `json:"lhs"` // variable name
	RHS Expression `json:"rhs"` // expression
}

// ========================================
// 2. Model Components
// ========================================

// ModelVariable represents a variable in a mathematical model.
//
// Type "brownian" denotes a stochastic noise source (Wiener process); the
// presence of any brownian variable promotes the enclosing model from an ODE
// system to an SDE system. NoiseKind and CorrelationGroup apply only to
// brownian variables.
type ModelVariable struct {
	Type        string      `json:"type"` // "state", "parameter", "observed", or "brownian"
	Units       *string     `json:"units,omitempty"`
	Default     interface{} `json:"default,omitempty"`
	Description *string     `json:"description,omitempty"`
	Expression  Expression  `json:"expression,omitempty"` // for observed variables
	// Shape lists index-set names for arrayed variables, drawn from the
	// document-scoped `index_sets` registry (EsmFile.IndexSets). Nil means
	// scalar. As of v0.8.0 the iteration domains named here live at document
	// scope, not on the model. See RFC semiring-faq-unified-ir §5.2 / §6.1.
	Shape []string `json:"shape,omitempty"`
	// Location tags the variable's staggered-grid location
	// (e.g., "cell_center", "edge_normal", "vertex"). Empty means
	// no explicit staggering. See discretization RFC §10.2.
	Location string `json:"location,omitempty"`
	// NoiseKind is brownian-only: kind of stochastic process. Currently only
	// "wiener" is supported.
	NoiseKind string `json:"noise_kind,omitempty"`
	// CorrelationGroup is brownian-only: optional opaque tag grouping
	// correlated noise sources.
	CorrelationGroup string `json:"correlation_group,omitempty"`
}

// Model represents an ODE system
type Model struct {
	Reference        *Reference               `json:"reference,omitempty"`
	Variables        map[string]ModelVariable `json:"variables"`
	Equations        []Equation               `json:"equations"`
	DiscreteEvents   []DiscreteEvent          `json:"discrete_events,omitempty"`
	ContinuousEvents []ContinuousEvent        `json:"continuous_events,omitempty"`
	Subsystems       map[string]interface{}   `json:"subsystems,omitempty"`
	// Tolerance is the model-level default numerical tolerance applied to
	// inline tests that do not override it (esm-spec §6.6).
	Tolerance *Tolerance `json:"tolerance,omitempty"`
	// Tests are inline validation tests for this model (esm-spec §6.6).
	Tests []Test `json:"tests,omitempty"`
	// Examples are inline illustrative runs + plot specs (esm-spec §6.7).
	Examples []Example `json:"examples,omitempty"`
	// InitializationEquations hold only at t=0 (not dynamically time-stepped).
	// Used by models that must solve an auxiliary system before the main
	// time-stepping begins (e.g. aerosol equilibrium, plume rise). See gt-ebuq.
	InitializationEquations []Equation `json:"initialization_equations,omitempty"`
	// Guesses provides initial-guess seeds for nonlinear solvers during
	// initialization, keyed by variable name. Values may be numeric literals
	// or Expression graphs (serialized as interface{}).
	Guesses map[string]interface{} `json:"guesses,omitempty"`
	// SystemKind discriminates the MTK system type this model maps to.
	// One of "ode" (default), "nonlinear", "sde", "pde".
	SystemKind *string `json:"system_kind,omitempty"`
}

// ========================================
// 3. Reaction System Components
// ========================================

// Species represents a chemical species
type Species struct {
	Units       *string     `json:"units,omitempty"`
	Default     interface{} `json:"default,omitempty"`
	Description *string     `json:"description,omitempty"`
	// Constant marks reservoir species (held fixed, no ODE).
	// Maps to Catalyst's isconstantspecies=true.
	Constant *bool `json:"constant,omitempty"`
}

// Parameter represents a model parameter
type Parameter struct {
	Units       *string     `json:"units,omitempty"`
	Default     interface{} `json:"default,omitempty"`
	Description *string     `json:"description,omitempty"`
}

// SubstrateProduct represents a substrate or product in a reaction.
//
// Stoichiometry MUST be a positive finite number. v0.2.x permits fractional
// coefficients (e.g. 0.87 CH2O) in addition to the historical integer case;
// integer-valued coefficients round-trip as integers via encoding/json because
// float64(1) marshals to "1" in Go's standard encoder.
type SubstrateProduct struct {
	Species       string  `json:"species"`
	Stoichiometry float64 `json:"stoichiometry"`
}

// Reaction represents a chemical reaction
type Reaction struct {
	ID         string             `json:"id"`
	Name       *string            `json:"name,omitempty"`
	Substrates []SubstrateProduct `json:"substrates"`
	Products   []SubstrateProduct `json:"products"`
	Rate       Expression         `json:"rate"`
	Reference  *Reference         `json:"reference,omitempty"`
}

// ReactionSystem represents a chemical reaction network
type ReactionSystem struct {
	Reference           *Reference             `json:"reference,omitempty"`
	Species             map[string]Species     `json:"species"`
	Parameters          map[string]Parameter   `json:"parameters"`
	Reactions           []Reaction             `json:"reactions"`
	ConstraintEquations []Equation             `json:"constraint_equations,omitempty"`
	DiscreteEvents      []DiscreteEvent        `json:"discrete_events,omitempty"`
	ContinuousEvents    []ContinuousEvent      `json:"continuous_events,omitempty"`
	Subsystems          map[string]interface{} `json:"subsystems,omitempty"`
	// Tolerance is the component-level default numerical tolerance for inline
	// tests (esm-spec §6.6).
	Tolerance *Tolerance `json:"tolerance,omitempty"`
	// Tests are inline validation tests for this reaction system (esm-spec §6.6).
	Tests []Test `json:"tests,omitempty"`
	// Examples are inline illustrative runs + plot specs (esm-spec §6.7).
	Examples []Example `json:"examples,omitempty"`
}

// ========================================
// 3b. Inline Tests, Examples, and Plots (esm-spec §6.6 / §6.7)
// ========================================

// Tolerance is a numerical comparison tolerance. Any of Abs/Rel may be set; an
// assertion passes when any set bound is satisfied.
type Tolerance struct {
	Abs *float64 `json:"abs,omitempty"`
	Rel *float64 `json:"rel,omitempty"`
}

// TimeSpan is a simulation time interval expressed in the component's time units.
type TimeSpan struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

// Assertion is a single scalar (variable, time, expected) check inside a Test.
// PDE-aware variants pin a spatial point via `coords` or reduce the field to a
// scalar via `reduce` (esm-spec §6.6.5); `coords` and `reduce` are mutually
// exclusive. Error-norm reductions require a `reference` solution. These extra
// fields round-trip verbatim; this binding does not evaluate them.
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
	Reference interface{} `json:"reference,omitempty"`
}

// Test is an inline validation test for a Model or ReactionSystem.
type Test struct {
	ID                 string             `json:"id"`
	Description        *string            `json:"description,omitempty"`
	InitialConditions  map[string]float64 `json:"initial_conditions,omitempty"`
	ParameterOverrides map[string]float64 `json:"parameter_overrides,omitempty"`
	TimeSpan           TimeSpan           `json:"time_span"`
	Tolerance          *Tolerance         `json:"tolerance,omitempty"`
	// ExpressionTemplateImports are raw §9.7.2 import entries injected into the
	// ENCLOSING component's template scope for THIS test's run only (esm-spec
	// §9.7.10 form C / §6.6.6): the discretization a discretization-agnostic PDE
	// leaf is lowered under in a per-test ephemeral build. Authored per-run
	// config (a peer of ParameterOverrides), so — unlike a component's own
	// imports — this DOES survive parse → emit. Consumed only by an ephemeral
	// per-run build, which this binding does not perform (no numeric solver).
	ExpressionTemplateImports []interface{} `json:"expression_template_imports,omitempty"`
	Assertions                []Assertion   `json:"assertions"`
}

// PlotAxis is an axis specification for a plot.
type PlotAxis struct {
	Variable string  `json:"variable"`
	Label    *string `json:"label,omitempty"`
}

// PlotValue is a scalar value derived from a trajectory, used for heatmap
// color channels.
type PlotValue struct {
	Variable string   `json:"variable"`
	AtTime   *float64 `json:"at_time,omitempty"`
	Reduce   *string  `json:"reduce,omitempty"`
}

// PlotSeries is a single named series for multi-series line/scatter plots.
type PlotSeries struct {
	Name     string `json:"name"`
	Variable string `json:"variable"`
}

// Plot is a plot specification associated with an Example.
type Plot struct {
	ID          string       `json:"id"`
	Type        string       `json:"type"` // "line" | "scatter" | "heatmap"
	Description *string      `json:"description,omitempty"`
	X           PlotAxis     `json:"x"`
	Y           PlotAxis     `json:"y"`
	Value       *PlotValue   `json:"value,omitempty"`
	Series      []PlotSeries `json:"series,omitempty"`
}

// SweepRange is a generated range of parameter values.
type SweepRange struct {
	Start float64 `json:"start"`
	Stop  float64 `json:"stop"`
	Count int     `json:"count"`
	Scale *string `json:"scale,omitempty"` // "linear" | "log"
}

// SweepDimension is one axis of a parameter sweep; exactly one of Values or
// Range is set.
type SweepDimension struct {
	Parameter string      `json:"parameter"`
	Values    []float64   `json:"values,omitempty"`
	Range     *SweepRange `json:"range,omitempty"`
}

// ParameterSweep is a parameter sweep specification (currently only cartesian).
type ParameterSweep struct {
	Type       string           `json:"type"` // "cartesian"
	Dimensions []SweepDimension `json:"dimensions"`
}

// Example is an inline illustrative example of how to run a component.
type Example struct {
	ID             string             `json:"id"`
	Description    *string            `json:"description,omitempty"`
	InitialState   map[string]float64 `json:"initial_state,omitempty"`
	Parameters     map[string]float64 `json:"parameters,omitempty"`
	TimeSpan       TimeSpan           `json:"time_span"`
	ParameterSweep *ParameterSweep    `json:"parameter_sweep,omitempty"`
	Plots          []Plot             `json:"plots,omitempty"`
	// ExpressionTemplateImports are raw §9.7.2 import entries injected into the
	// ENCLOSING component's template scope for THIS example's run only (esm-spec
	// §9.7.10 form C / §6.7). Authored per-run config (a peer of Parameters), so
	// it DOES survive parse → emit; consumed only by an ephemeral per-run build,
	// which this binding does not perform.
	ExpressionTemplateImports []interface{} `json:"expression_template_imports,omitempty"`
}

// ========================================
// 4. Events
// ========================================

// FunctionalAffect represents a registered functional affect handler for
// discrete events that require complex behavior beyond symbolic expressions
type FunctionalAffect struct {
	HandlerID      string                 `json:"handler_id"`
	ReadVars       []string               `json:"read_vars"`
	ReadParams     []string               `json:"read_params"`
	ModifiedParams []string               `json:"modified_params,omitempty"`
	Config         map[string]interface{} `json:"config,omitempty"`
}

// DiscreteEventTrigger represents different trigger types for discrete events
type DiscreteEventTrigger struct {
	Type          string     `json:"type"`                     // "condition", "periodic", "preset_times"
	Expression    Expression `json:"expression,omitempty"`     // for condition
	Interval      *float64   `json:"interval,omitempty"`       // for periodic
	InitialOffset *float64   `json:"initial_offset,omitempty"` // for periodic
	Times         []float64  `json:"times,omitempty"`          // for preset_times
}

// DiscreteEvent represents a discrete event
type DiscreteEvent struct {
	Name               string               `json:"name,omitempty"`
	Trigger            DiscreteEventTrigger `json:"trigger"`
	Affects            []AffectEquation     `json:"affects,omitempty"`
	FunctionalAffect   *FunctionalAffect    `json:"functional_affect,omitempty"`
	DiscreteParameters []string             `json:"discrete_parameters,omitempty"`
	Reinitialize       *bool                `json:"reinitialize,omitempty"`
	Description        *string              `json:"description,omitempty"`
}

// ContinuousEvent represents a continuous event
type ContinuousEvent struct {
	Name         *string          `json:"name,omitempty"`
	Conditions   []Expression     `json:"conditions"`
	Affects      []AffectEquation `json:"affects"`
	AffectNeg    []AffectEquation `json:"affect_neg,omitempty"`
	RootFind     *string          `json:"root_find,omitempty"` // "left", "right", "all"
	Reinitialize *bool            `json:"reinitialize,omitempty"`
	Description  *string          `json:"description,omitempty"`
}

// ========================================
// 5. Data Loaders and Operators
// ========================================

// DataLoader is a runtime-agnostic description of an external data source.
// It is pure I/O: it carries enough structural information to locate files,
// map timestamps to files, and describe variable semantics — rather than
// pointing at a runtime handler. Reprojection and regridding are the
// responsibility of downstream rules, not the loader.
type DataLoader struct {
	Kind        string                        `json:"kind"` // "grid", "points", or "static" (esm-spec §8.9)
	Source      DataLoaderSource              `json:"source"`
	Temporal    *DataLoaderTemporal           `json:"temporal,omitempty"`
	Determinism *DataLoaderDeterminism        `json:"determinism,omitempty"`
	Variables   map[string]DataLoaderVariable `json:"variables"`
	Reference   *Reference                    `json:"reference,omitempty"`
	Metadata    map[string]interface{}        `json:"metadata,omitempty"`
}

// DataLoaderDeterminism is the reproducibility contract a loader advertises
// to bindings (esm-spec §8.9.2). A binding that cannot honor the declared
// contract MUST reject the file at load.
type DataLoaderDeterminism struct {
	Endian       *string `json:"endian,omitempty"`        // "little" | "big"
	FloatFormat  *string `json:"float_format,omitempty"`  // "ieee754_single" | "ieee754_double"
	IntegerWidth *int    `json:"integer_width,omitempty"` // 32 | 64
}

// DataLoaderSource describes file discovery for a data source. URL templates
// use Jinja-style substitutions for dates, variable names, and similar.
type DataLoaderSource struct {
	URLTemplate string   `json:"url_template"`
	Mirrors     []string `json:"mirrors,omitempty"`
}

// DataLoaderTemporal describes the temporal coverage and record layout.
// RecordsPerFile may be an int or the string "auto"; represented as interface{}.
type DataLoaderTemporal struct {
	Start          *string     `json:"start,omitempty"`
	End            *string     `json:"end,omitempty"`
	FilePeriod     *string     `json:"file_period,omitempty"`
	Frequency      *string     `json:"frequency,omitempty"`
	RecordsPerFile interface{} `json:"records_per_file,omitempty"`
	TimeVariable   *string     `json:"time_variable,omitempty"`
}

// DataLoaderVariable describes one variable exposed by a data loader.
// UnitConversion is either a number or an Expression AST node.
type DataLoaderVariable struct {
	FileVariable   string      `json:"file_variable"`
	Units          string      `json:"units"`
	UnitConversion interface{} `json:"unit_conversion,omitempty"`
	Description    *string     `json:"description,omitempty"`
	Reference      *Reference  `json:"reference,omitempty"`
}

// The top-level `operators` and `registered_functions` blocks (and the `call`
// AST op that referenced them) were removed in v0.3.0 by the closed function
// registry RFC; their Go types have been deleted in lockstep. The closed
// registry lives in registered_functions.go.

// ========================================
// 6. Coupling
// ========================================

// CouplingEntry represents different types of coupling rules
// This is a discriminated union based on the "type" field
type CouplingEntry interface {
	GetType() string
}

// OperatorComposeCoupling represents operator composition
type OperatorComposeCoupling struct {
	Type        string                 `json:"type"` // "operator_compose"
	Systems     [2]string              `json:"systems"`
	Translate   map[string]interface{} `json:"translate,omitempty"`
	Lifting     *string                `json:"lifting,omitempty"`
	Description *string                `json:"description,omitempty"`
}

func (o OperatorComposeCoupling) GetType() string { return o.Type }

// CouplingCouple represents bi-directional coupling via connector equations
type CouplingCouple struct {
	Type        string    `json:"type"` // "couple"
	Systems     [2]string `json:"systems"`
	Connector   Connector `json:"connector"`
	Lifting     *string   `json:"lifting,omitempty"`
	Description *string   `json:"description,omitempty"`
}

func (c CouplingCouple) GetType() string { return c.Type }

// VariableMapCoupling represents variable mapping.
// Transform is a union (mirrors DataLoaderVariable.UnitConversion): either one
// of the legacy string kinds ("param_to_var", "identity", "additive",
// "multiplicative", "conversion_factor") held as a string, or a widened
// Expression transform held as an ExprNode (esm-spec §8.6/§10.4/§10.5 — the
// regridding form). Expression transforms are always operator-node OBJECTS on
// the wire; bare string/number Expression spellings are not admissible (the
// string space is reserved for the legacy kinds).
type VariableMapCoupling struct {
	Type        string     `json:"type"` // "variable_map"
	From        string     `json:"from"`
	To          string     `json:"to"`
	Transform   Expression `json:"transform"` // string kind | ExprNode
	Factor      *float64   `json:"factor,omitempty"`
	Lifting     *string    `json:"lifting,omitempty"`
	Description *string    `json:"description,omitempty"`
}

func (v VariableMapCoupling) GetType() string { return v.Type }

// TransformKind returns the legacy string transform kind, or "" when the
// transform is an Expression AST (or absent).
func (v VariableMapCoupling) TransformKind() string {
	s, _ := v.Transform.(string)
	return s
}

// TransformIsExpression reports whether the transform is the widened
// Expression form (an operator node) rather than a legacy string kind.
func (v VariableMapCoupling) TransformIsExpression() bool {
	switch v.Transform.(type) {
	case ExprNode, *ExprNode:
		return true
	}
	return false
}

// OperatorApplyCoupling represents operator application
type OperatorApplyCoupling struct {
	Type        string  `json:"type"` // "operator_apply"
	Operator    string  `json:"operator"`
	Description *string `json:"description,omitempty"`
}

func (o OperatorApplyCoupling) GetType() string { return o.Type }

// CallbackCoupling represents callback-based coupling
type CallbackCoupling struct {
	Type        string                 `json:"type"` // "callback"
	CallbackID  string                 `json:"callback_id"`
	Config      map[string]interface{} `json:"config,omitempty"`
	Description *string                `json:"description,omitempty"`
}

func (c CallbackCoupling) GetType() string { return c.Type }

// EventCoupling represents event-based coupling
type EventCoupling struct {
	Type               string                `json:"type"`       // "event"
	EventType          string                `json:"event_type"` // "continuous" or "discrete"
	Name               string                `json:"name"`
	Conditions         []Expression          `json:"conditions,omitempty"` // for continuous events
	Trigger            *DiscreteEventTrigger `json:"trigger,omitempty"`    // for discrete events
	Affects            []AffectEquation      `json:"affects,omitempty"`
	FunctionalAffect   *FunctionalAffect     `json:"functional_affect,omitempty"`
	AffectNeg          []AffectEquation      `json:"affect_neg,omitempty"`
	DiscreteParameters []string              `json:"discrete_parameters,omitempty"`
	RootFind           *string               `json:"root_find,omitempty"`
	Reinitialize       *bool                 `json:"reinitialize,omitempty"`
	Description        *string               `json:"description,omitempty"`
}

func (e EventCoupling) GetType() string { return e.Type }

// CouplingImport reuses a coupling-library file (esm-spec §10.9, §10.10): it
// imports the library named by `Ref` and binds each of its declared roles to a
// component in the assembly via `Bind` (role name -> scoped component
// reference). At flatten (esm-spec §10.10.3) the import expands into concrete
// variable_map / couple / operator_compose / event edges by substituting the
// bound actual for every role-named top-level segment; the entry itself
// round-trips intact. Carries no `expression_template_imports` (injection is a
// property of the wiring entries, not of an import indirection).
type CouplingImport struct {
	Type        string            `json:"type"` // "coupling_import"
	Ref         string            `json:"ref"`
	Bind        map[string]string `json:"bind,omitempty"`
	Description *string           `json:"description,omitempty"`
}

func (c CouplingImport) GetType() string { return c.Type }

// CouplingRole is one entry in a coupling-library file's `coupling_roles` map
// (esm-spec §10.9): a formal component role (a name, not a type), carrying an
// optional human-readable description. Roles are bound to actual components at
// a `coupling_import` (esm-spec §10.10).
type CouplingRole struct {
	Description *string `json:"description,omitempty"`
}

// Connector represents the connector system for couple coupling
type Connector struct {
	Equations []ConnectorEquation `json:"equations"`
}

// ConnectorEquation represents a single equation in a connector
type ConnectorEquation struct {
	From       string     `json:"from"`
	To         string     `json:"to"`
	Transform  string     `json:"transform"` // "additive", "multiplicative", "replacement"
	Expression Expression `json:"expression"`
}

// ========================================
// 7. Domain
// ========================================

// Domain represents the spatiotemporal domain.
type Domain struct {
	IndependentVariable *string         `json:"independent_variable,omitempty"`
	Temporal            *TemporalDomain `json:"temporal,omitempty"`
	ElementType         *string         `json:"element_type,omitempty"`
	ArrayType           *string         `json:"array_type,omitempty"`
}

// TemporalDomain represents temporal bounds
type TemporalDomain struct {
	Start         string  `json:"start"`
	End           string  `json:"end"`
	ReferenceTime *string `json:"reference_time,omitempty"`
}

// ========================================
// 8. Metadata and References
// ========================================

// Reference represents a scientific reference
type Reference struct {
	DOI      *string `json:"doi,omitempty"`
	Citation *string `json:"citation,omitempty"`
	URL      *string `json:"url,omitempty"`
	Notes    *string `json:"notes,omitempty"`
}

// Metadata represents file metadata
type Metadata struct {
	Name        string      `json:"name"`
	Description *string     `json:"description,omitempty"`
	Authors     []string    `json:"authors"`
	License     *string     `json:"license,omitempty"`
	Created     *string     `json:"created,omitempty"`
	Modified    *string     `json:"modified,omitempty"`
	Tags        []string    `json:"tags,omitempty"`
	References  []Reference `json:"references,omitempty"`
}

// ========================================
// 9. Main ESM File Structure
// ========================================

// IndexSet is one entry in the document-scoped `index_sets` registry
// (RFC semiring-faq-unified-ir §5.2): the declaration shape for an iteration
// domain referenced from an `aggregate` range via { "from": <name> } and from
// arrayed-variable `shape` lists. Exactly one of four kinds — each populating
// its own subset of fields:
//
//   - "interval":    a dense [1..Size] grid axis (Size required).
//   - "categorical": an explicit enumeration (Members required).
//   - "derived":     materialized from an index-set-producing node named by
//     its id (FromFAQ required).
//   - "ragged":      a per-parent inner set backed by CSR factors (Of,
//     Offsets, Values required).
//
// The Go binding is schema-only: it stores and round-trips these declarations
// but does not resolve `{from}` references or evaluate the sets.
type IndexSet struct {
	Kind    string        `json:"kind"`
	Size    *int          `json:"size,omitempty"`
	Members []interface{} `json:"members,omitempty"`
	FromFAQ *string       `json:"from_faq,omitempty"`
	Of      []string      `json:"of,omitempty"`
	Offsets *string       `json:"offsets,omitempty"`
	Values  *string       `json:"values,omitempty"`
}

// EsmFile represents the top-level ESM file structure
type EsmFile struct {
	Esm             string                    `json:"esm" validate:"required"`
	Metadata        Metadata                  `json:"metadata" validate:"required"`
	Models          map[string]Model          `json:"models,omitempty"`
	ReactionSystems map[string]ReactionSystem `json:"reaction_systems,omitempty"`
	DataLoaders     map[string]DataLoader     `json:"data_loaders,omitempty"`
	// Enums holds file-local symbol → positive-integer mappings used by the
	// `enum` AST op (esm-spec §9.3). Each entry is an enum name; its value is
	// a map from symbolic names (strings) to positive integers. Lowering
	// (resolution to `const`-op integers) happens at load time.
	Enums    map[string]map[string]int `json:"enums,omitempty"`
	Coupling []interface{}             `json:"coupling,omitempty"` // Properly deserialized coupling entries
	// CouplingRoles is present only in a coupling-library file (esm-spec §10.9):
	// the map of formal component roles a role-scoped `coupling` array wires.
	// Presence of this key is the sole positive identifier of the
	// coupling-library file kind (see isCouplingLibraryDoc). An assembly file
	// never declares it.
	CouplingRoles map[string]CouplingRole `json:"coupling_roles,omitempty"`
	// Domain is the single temporal domain shared by every component in the
	// document. A document has at most one domain. See esm-spec §11.
	Domain *Domain `json:"domain,omitempty"`
	// FunctionTables holds top-level sampled function tables (esm-spec §9.5,
	// v0.4.0). Each entry is a FunctionTable referenced by `table_lookup` AST
	// op nodes via its key.
	FunctionTables map[string]FunctionTable `json:"function_tables,omitempty"`
	// IndexSets is the document-scoped registry of named index sets
	// (RFC semiring-faq-unified-ir §5.2), keyed by name — the single,
	// document-level declaration site for every iteration domain shared by all
	// models in the document. An `aggregate` range references one by name as
	// { "from": <name> } and arrayed-variable `shape` lists draw dimension
	// names from it. As of v0.8.0 this moved from a per-Model field to
	// document scope: one registry, shared by every model.
	IndexSets map[string]IndexSet `json:"index_sets,omitempty"`
}

// FunctionTableAxis is a single named axis inside a FunctionTable.
// `Values` MUST be strictly-increasing finite floats with at least 2 entries
// (mirrors the §9.2 interp.linear / interp.bilinear axis contract).
type FunctionTableAxis struct {
	Name   string    `json:"name"`
	Units  *string   `json:"units,omitempty"`
	Values []float64 `json:"values"`
}

// FunctionTable is a sampled function table (esm-spec §9.5). The shape of
// Data is [len(Outputs), len(Axes[0].Values), len(Axes[1].Values), ...] when
// Outputs is non-empty; [len(Axes[0].Values), ...] otherwise. Tables are
// syntactic sugar over interp.linear / interp.bilinear / index — a
// table_lookup query MUST be bit-equivalent to the equivalent inline-const
// lookup.
type FunctionTable struct {
	Description   *string             `json:"description,omitempty"`
	Axes          []FunctionTableAxis `json:"axes"`
	Interpolation *string             `json:"interpolation,omitempty"`
	OutOfBounds   *string             `json:"out_of_bounds,omitempty"`
	Outputs       []string            `json:"outputs,omitempty"`
	Data          interface{}         `json:"data"`
	Shape         []int               `json:"shape,omitempty"`
	SchemaVersion *string             `json:"schema_version,omitempty"`
}

// ========================================
// 10. Validation and Utility Methods
// ========================================

// validate is the shared go-playground struct validator. validator.New()
// builds and caches struct metadata on first use, so it is documented as
// cache-heavy and MUST be reused rather than reconstructed per call.
var validate = validator.New()

// Validate validates the ESM file structure
func (e *EsmFile) Validate() error {
	if err := validate.Struct(e); err != nil {
		return err
	}

	// At least one of models, reaction_systems, or data_loaders must be present
	if len(e.Models) == 0 && len(e.ReactionSystems) == 0 && len(e.DataLoaders) == 0 {
		return fmt.Errorf("at least one of 'models', 'reaction_systems', or 'data_loaders' must be present")
	}

	return nil
}

// ToJSON converts the ESM file to canonical (indented) JSON bytes.
//
// Unlike Save (serialize.go), ToJSON does NOT run (*EsmFile).Validate first —
// it serializes whatever it is given. Callers that need the file validated
// before emission should use Save (which returns a string) or call Validate
// explicitly; ToJSON exists for the raw byte form and for round-trip paths that
// have already validated.
func (e *EsmFile) ToJSON() ([]byte, error) {
	return marshalCanonical(e, true)
}

// FromJSON creates an ESM file from JSON data
func FromJSON(data []byte) (*EsmFile, error) {
	var esm EsmFile
	if err := json.Unmarshal(data, &esm); err != nil {
		return nil, fmt.Errorf("failed to unmarshal JSON: %w", err)
	}

	if err := esm.Validate(); err != nil {
		return nil, fmt.Errorf("validation failed: %w", err)
	}

	return &esm, nil
}
