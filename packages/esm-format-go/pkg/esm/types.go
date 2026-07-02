package esm

import (
	"bytes"
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
	CoupleType       *string                  `json:"coupletype,omitempty"`
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
	CoupleType          *string                `json:"coupletype,omitempty"`
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
type Assertion struct {
	Variable  string     `json:"variable"`
	Time      float64    `json:"time"`
	Expected  float64    `json:"expected"`
	Tolerance *Tolerance `json:"tolerance,omitempty"`
}

// Test is an inline validation test for a Model or ReactionSystem.
type Test struct {
	ID                 string             `json:"id"`
	Description        *string            `json:"description,omitempty"`
	InitialConditions  map[string]float64 `json:"initial_conditions,omitempty"`
	ParameterOverrides map[string]float64 `json:"parameter_overrides,omitempty"`
	TimeSpan           TimeSpan           `json:"time_span"`
	Tolerance          *Tolerance         `json:"tolerance,omitempty"`
	Assertions         []Assertion        `json:"assertions"`
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

// UnmarshalJSON handles plots.y as either a single PlotAxis or an array of
// PlotAxis objects (v0.5.0 inline multi-series shorthand). When y is an
// array the first entry becomes the canonical Y axis and all entries are
// projected onto Series (using label-or-variable as the series name).
// An explicit series field, if present, takes precedence over the projection.
func (p *Plot) UnmarshalJSON(data []byte) error {
	type TempPlot struct {
		ID          string          `json:"id"`
		Type        string          `json:"type"`
		Description *string         `json:"description,omitempty"`
		X           PlotAxis        `json:"x"`
		Y           json.RawMessage `json:"y"`
		Value       *PlotValue      `json:"value,omitempty"`
		Series      []PlotSeries    `json:"series,omitempty"`
	}

	var temp TempPlot
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	p.ID = temp.ID
	p.Type = temp.Type
	p.Description = temp.Description
	p.X = temp.X
	p.Value = temp.Value

	trimmed := bytes.TrimSpace(temp.Y)
	if len(trimmed) > 0 && trimmed[0] == '[' {
		var axes []PlotAxis
		if err := json.Unmarshal(temp.Y, &axes); err != nil {
			return fmt.Errorf("failed to unmarshal y as PlotAxis array: %w", err)
		}
		if len(axes) == 0 {
			return fmt.Errorf("plots.y array must have at least one entry")
		}
		p.Y = axes[0]
		if len(temp.Series) > 0 {
			p.Series = temp.Series
		} else {
			p.Series = make([]PlotSeries, len(axes))
			for i, axis := range axes {
				name := axis.Variable
				if axis.Label != nil {
					name = *axis.Label
				}
				p.Series[i] = PlotSeries{Name: name, Variable: axis.Variable}
			}
		}
	} else {
		if err := json.Unmarshal(temp.Y, &p.Y); err != nil {
			return fmt.Errorf("failed to unmarshal y as PlotAxis: %w", err)
		}
		p.Series = temp.Series
	}

	return nil
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

// VariableMapCoupling represents variable mapping
type VariableMapCoupling struct {
	Type        string   `json:"type"` // "variable_map"
	From        string   `json:"from"`
	To          string   `json:"to"`
	Transform   string   `json:"transform"`
	Factor      *float64 `json:"factor,omitempty"`
	Lifting     *string  `json:"lifting,omitempty"`
	Description *string  `json:"description,omitempty"`
}

func (v VariableMapCoupling) GetType() string { return v.Type }

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

// Validate validates the ESM file structure
func (e *EsmFile) Validate() error {
	validate := validator.New()
	if err := validate.Struct(e); err != nil {
		return err
	}

	// At least one of models, reaction_systems, or data_loaders must be present
	if len(e.Models) == 0 && len(e.ReactionSystems) == 0 && len(e.DataLoaders) == 0 {
		return fmt.Errorf("at least one of 'models', 'reaction_systems', or 'data_loaders' must be present")
	}

	return nil
}

// ToJSON converts the ESM file to JSON
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

// ========================================
// 11. Helper Functions for Expression Handling
// ========================================

// UnmarshalExpression handles the custom unmarshaling for Expression union
// type. Numeric literals preserve the RFC §5.4.6 round-trip parse rule:
// a JSON-number token with '.', 'e', or 'E' parses to float64; otherwise to
// int64 (falling back to float64 if out of int64 range).
func UnmarshalExpression(data []byte) (Expression, error) {
	// Try to unmarshal as number first (via json.Number to preserve int/float
	// distinction).
	var num json.Number
	if err := json.Unmarshal(data, &num); err == nil {
		return normalizeJSONNumber(num), nil
	}

	// Try to unmarshal as string
	var str string
	if err := json.Unmarshal(data, &str); err == nil {
		return str, nil
	}

	// Must be an object (ExprNode). Decode via UseNumber so nested literals in
	// Args keep their int/float shape.
	var node ExprNode
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&node); err != nil {
		return nil, fmt.Errorf("expression must be number, string, or object: %w", err)
	}

	// Recursively normalize Args, handling nested expressions and literals.
	if node.Args != nil {
		for i, arg := range node.Args {
			switch a := arg.(type) {
			case json.Number:
				node.Args[i] = normalizeJSONNumber(a)
			case map[string]interface{}:
				argBytes, err := json.Marshal(a)
				if err != nil {
					return nil, fmt.Errorf("failed to marshal arg for re-processing: %w", err)
				}
				unmarshaledArg, err := UnmarshalExpression(argBytes)
				if err != nil {
					return nil, fmt.Errorf("failed to unmarshal nested expression in args: %w", err)
				}
				node.Args[i] = unmarshaledArg
			}
		}
	}

	return node, nil
}

// Custom JSON unmarshaling for Equation
func (e *Equation) UnmarshalJSON(data []byte) error {
	// Define a temporary struct with the same structure but using json.RawMessage
	type TempEquation struct {
		LHS json.RawMessage `json:"lhs"`
		RHS json.RawMessage `json:"rhs"`
	}

	var temp TempEquation
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	// Unmarshal LHS
	lhs, err := UnmarshalExpression(temp.LHS)
	if err != nil {
		return fmt.Errorf("failed to unmarshal LHS: %w", err)
	}
	e.LHS = lhs

	// Unmarshal RHS
	rhs, err := UnmarshalExpression(temp.RHS)
	if err != nil {
		return fmt.Errorf("failed to unmarshal RHS: %w", err)
	}
	e.RHS = rhs

	return nil
}

// Custom JSON unmarshaling for AffectEquation
func (ae *AffectEquation) UnmarshalJSON(data []byte) error {
	type TempAffectEquation struct {
		LHS string          `json:"lhs"`
		RHS json.RawMessage `json:"rhs"`
	}

	var temp TempAffectEquation
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	ae.LHS = temp.LHS

	// Unmarshal RHS
	rhs, err := UnmarshalExpression(temp.RHS)
	if err != nil {
		return fmt.Errorf("failed to unmarshal RHS: %w", err)
	}
	ae.RHS = rhs

	return nil
}

// Custom JSON unmarshaling for Reaction
func (r *Reaction) UnmarshalJSON(data []byte) error {
	type TempReaction struct {
		ID         string             `json:"id"`
		Name       *string            `json:"name,omitempty"`
		Substrates []SubstrateProduct `json:"substrates"`
		Products   []SubstrateProduct `json:"products"`
		Rate       json.RawMessage    `json:"rate"`
		Reference  *Reference         `json:"reference,omitempty"`
	}

	var temp TempReaction
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	r.ID = temp.ID
	r.Name = temp.Name
	r.Substrates = temp.Substrates
	r.Products = temp.Products
	r.Reference = temp.Reference

	// Unmarshal Rate
	rate, err := UnmarshalExpression(temp.Rate)
	if err != nil {
		return fmt.Errorf("failed to unmarshal rate: %w", err)
	}
	r.Rate = rate

	return nil
}

// Custom JSON unmarshaling for ModelVariable
func (mv *ModelVariable) UnmarshalJSON(data []byte) error {
	type TempModelVariable struct {
		Type             string          `json:"type"`
		Units            *string         `json:"units,omitempty"`
		Default          interface{}     `json:"default,omitempty"`
		Description      *string         `json:"description,omitempty"`
		Expression       json.RawMessage `json:"expression,omitempty"`
		Shape            []string        `json:"shape,omitempty"`
		Location         string          `json:"location,omitempty"`
		NoiseKind        string          `json:"noise_kind,omitempty"`
		CorrelationGroup string          `json:"correlation_group,omitempty"`
	}

	var temp TempModelVariable
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	mv.Type = temp.Type
	mv.Units = temp.Units
	mv.Default = temp.Default
	mv.Description = temp.Description
	mv.Shape = temp.Shape
	mv.Location = temp.Location
	mv.NoiseKind = temp.NoiseKind
	mv.CorrelationGroup = temp.CorrelationGroup

	// Unmarshal Expression if present
	if len(temp.Expression) > 0 && string(temp.Expression) != "null" {
		expr, err := UnmarshalExpression(temp.Expression)
		if err != nil {
			return fmt.Errorf("failed to unmarshal expression: %w", err)
		}
		mv.Expression = expr
	}

	return nil
}

// Custom JSON unmarshaling for EventCoupling
func (ec *EventCoupling) UnmarshalJSON(data []byte) error {
	type TempEventCoupling struct {
		Type               string                `json:"type"`
		EventType          string                `json:"event_type"`
		Name               string                `json:"name"`
		Conditions         []json.RawMessage     `json:"conditions,omitempty"`
		Trigger            *DiscreteEventTrigger `json:"trigger,omitempty"`
		Affects            []AffectEquation      `json:"affects"`
		DiscreteParameters []string              `json:"discrete_parameters,omitempty"`
		Description        *string               `json:"description,omitempty"`
	}

	var temp TempEventCoupling
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	ec.Type = temp.Type
	ec.EventType = temp.EventType
	ec.Name = temp.Name
	ec.Trigger = temp.Trigger
	ec.Affects = temp.Affects
	ec.DiscreteParameters = temp.DiscreteParameters
	ec.Description = temp.Description

	// Unmarshal Conditions if present
	if len(temp.Conditions) > 0 {
		ec.Conditions = make([]Expression, len(temp.Conditions))
		for i, conditionData := range temp.Conditions {
			condition, err := UnmarshalExpression(conditionData)
			if err != nil {
				return fmt.Errorf("failed to unmarshal condition at index %d: %w", i, err)
			}
			ec.Conditions[i] = condition
		}
	}

	return nil
}

// Custom JSON unmarshaling for DataLoaderVariable (handles Expression union
// in unit_conversion: number | ExpressionNode).
func (v *DataLoaderVariable) UnmarshalJSON(data []byte) error {
	type TempDataLoaderVariable struct {
		FileVariable   string          `json:"file_variable"`
		Units          string          `json:"units"`
		UnitConversion json.RawMessage `json:"unit_conversion,omitempty"`
		Description    *string         `json:"description,omitempty"`
		Reference      *Reference      `json:"reference,omitempty"`
	}
	var temp TempDataLoaderVariable
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	v.FileVariable = temp.FileVariable
	v.Units = temp.Units
	v.Description = temp.Description
	v.Reference = temp.Reference
	if len(temp.UnitConversion) > 0 && string(temp.UnitConversion) != "null" {
		expr, err := UnmarshalExpression(temp.UnitConversion)
		if err != nil {
			return fmt.Errorf("failed to unmarshal unit_conversion: %w", err)
		}
		v.UnitConversion = expr
	}
	return nil
}

// Custom JSON unmarshaling for EsmFile
func (esm *EsmFile) UnmarshalJSON(data []byte) error {
	// Define a temporary struct that matches EsmFile but uses json.RawMessage for coupling
	type TempEsmFile struct {
		Esm             string                    `json:"esm"`
		Metadata        Metadata                  `json:"metadata"`
		Models          map[string]Model          `json:"models,omitempty"`
		ReactionSystems map[string]ReactionSystem `json:"reaction_systems,omitempty"`
		DataLoaders     map[string]DataLoader     `json:"data_loaders,omitempty"`
		Enums           map[string]map[string]int `json:"enums,omitempty"`
		Coupling        json.RawMessage           `json:"coupling,omitempty"`
		Domain          *Domain                   `json:"domain,omitempty"`
		FunctionTables  map[string]FunctionTable  `json:"function_tables,omitempty"`
		IndexSets       map[string]IndexSet       `json:"index_sets,omitempty"`
	}

	var temp TempEsmFile
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	// Copy all fields except coupling
	esm.Esm = temp.Esm
	esm.Metadata = temp.Metadata
	esm.Models = temp.Models
	esm.ReactionSystems = temp.ReactionSystems
	esm.DataLoaders = temp.DataLoaders
	esm.Enums = temp.Enums
	esm.Domain = temp.Domain
	esm.FunctionTables = temp.FunctionTables
	esm.IndexSets = temp.IndexSets

	// Handle coupling array with proper type deserialization
	if len(temp.Coupling) > 0 && string(temp.Coupling) != "null" {
		couplingEntries, err := UnmarshalCouplingArray(temp.Coupling)
		if err != nil {
			return fmt.Errorf("failed to unmarshal coupling: %w", err)
		}
		esm.Coupling = couplingEntries
	}

	return nil
}

// UnmarshalCouplingArray handles the deserialization of the coupling array
func UnmarshalCouplingArray(data []byte) ([]interface{}, error) {
	// First unmarshal as a slice of raw messages
	var rawEntries []json.RawMessage
	if err := json.Unmarshal(data, &rawEntries); err != nil {
		return nil, fmt.Errorf("failed to unmarshal coupling array: %w", err)
	}

	var result []interface{}
	for i, rawEntry := range rawEntries {
		entry, err := UnmarshalCouplingEntry(rawEntry)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal coupling entry at index %d: %w", i, err)
		}
		result = append(result, entry)
	}

	return result, nil
}

// UnmarshalCouplingEntry handles the deserialization of a single coupling entry
func UnmarshalCouplingEntry(data []byte) (CouplingEntry, error) {
	// First, determine the type by unmarshaling into a map
	var typeMap map[string]interface{}
	if err := json.Unmarshal(data, &typeMap); err != nil {
		return nil, fmt.Errorf("failed to unmarshal coupling entry as map: %w", err)
	}

	typeVal, ok := typeMap["type"]
	if !ok {
		return nil, fmt.Errorf("coupling entry missing required 'type' field")
	}

	typeStr, ok := typeVal.(string)
	if !ok {
		return nil, fmt.Errorf("coupling entry 'type' field must be a string, got %T", typeVal)
	}

	// Unmarshal into the appropriate concrete type based on the type field
	switch typeStr {
	case "operator_compose":
		var coupling OperatorComposeCoupling
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal OperatorComposeCoupling: %w", err)
		}
		return coupling, nil

	case "couple":
		var coupling CouplingCouple
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal CouplingCouple: %w", err)
		}
		return coupling, nil

	case "variable_map":
		var coupling VariableMapCoupling
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal VariableMapCoupling: %w", err)
		}
		return coupling, nil

	case "operator_apply":
		var coupling OperatorApplyCoupling
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal OperatorApplyCoupling: %w", err)
		}
		return coupling, nil

	case "callback":
		var coupling CallbackCoupling
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal CallbackCoupling: %w", err)
		}
		return coupling, nil

	case "event":
		var coupling EventCoupling
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal EventCoupling: %w", err)
		}
		return coupling, nil

	default:
		return nil, fmt.Errorf("unknown coupling type: %s", typeStr)
	}
}
