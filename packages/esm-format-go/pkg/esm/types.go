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
	Op   string        `json:"op"`
	Args []interface{} `json:"args"`
	Wrt   *string      `json:"wrt,omitempty"`   // for derivatives
	Dim   *string      `json:"dim,omitempty"`   // for grad
	Fn    *string      `json:"fn,omitempty"`    // for bc wrapper kind encoding
	Var   *string      `json:"var,omitempty"`   // integration variable name (for integral)
	Lower interface{}  `json:"lower,omitempty"` // lower integration bound (for integral)
	Upper interface{}  `json:"upper,omitempty"` // upper integration bound (for integral)
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
}

// Expression represents the union type: number | string | ExprNode
// In Go, this is handled by using interface{} and custom unmarshaling
type Expression interface{}

// RuleRegion is a spatial scope for a rule or equation (discretization RFC §7.2).
// It can be a string (legacy advisory tag) or an object with a "kind" field.
type RuleRegion = interface{}

// Equation represents a mathematical equation with LHS and RHS
type Equation struct {
	LHS    Expression  `json:"lhs"`
	RHS    Expression  `json:"rhs"`
	Region *RuleRegion `json:"region,omitempty"`
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
	// Shape lists dimension names (drawn from the enclosing model's
	// domain.spatial) for arrayed variables. Nil means scalar.
	// See discretization RFC §10.2.
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
	CoupleType         *string                       `json:"coupletype,omitempty"`
	Reference          *Reference                    `json:"reference,omitempty"`
	// Domain references a top-level domain (EsmFile.Domains) that declares the
	// spatial coordinates this model discretizes over. Used by the unit checker
	// to resolve grad/div/laplacian coordinate units.
	Domain             *string                       `json:"domain,omitempty"`
	Variables          map[string]ModelVariable      `json:"variables"`
	Equations          []Equation                    `json:"equations"`
	DiscreteEvents     []DiscreteEvent               `json:"discrete_events,omitempty"`
	ContinuousEvents   []ContinuousEvent             `json:"continuous_events,omitempty"`
	Subsystems         map[string]interface{}        `json:"subsystems,omitempty"`
	// BoundaryConditions holds model-level BC entries keyed by user-supplied id.
	// New in ESM v0.2.0; see docs/rfcs/discretization.md §9.
	BoundaryConditions map[string]BoundaryCondition  `json:"boundary_conditions,omitempty"`
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
	// Regrid holds per-variable regridding configuration for fields consumed
	// from data-loader subsystems, keyed by variable name (RFC
	// pure-io-data-loaders §5.2, §6). Regridding is a model concern; an entry
	// may override the staggering-derived kernel and, for scattered-point
	// (cell-averaging) loaders, declares the no-data missing_value fill.
	Regrid map[string]RegridSpec `json:"regrid,omitempty"`
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
	Units       *string `json:"units,omitempty"`
	Default     interface{} `json:"default,omitempty"`
	Description *string `json:"description,omitempty"`
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
	CoupleType          *string                   `json:"coupletype,omitempty"`
	Reference           *Reference                `json:"reference,omitempty"`
	Species             map[string]Species        `json:"species"`
	Parameters          map[string]Parameter      `json:"parameters"`
	Reactions           []Reaction                `json:"reactions"`
	ConstraintEquations []Equation                `json:"constraint_equations,omitempty"`
	DiscreteEvents      []DiscreteEvent           `json:"discrete_events,omitempty"`
	ContinuousEvents    []ContinuousEvent         `json:"continuous_events,omitempty"`
	Subsystems          map[string]interface{}    `json:"subsystems,omitempty"`
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
	InitialState   *InitialConditions `json:"initial_state,omitempty"`
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
	HandlerID       string                 `json:"handler_id"`
	ReadVars        []string               `json:"read_vars"`
	ReadParams      []string               `json:"read_params"`
	ModifiedParams  []string               `json:"modified_params,omitempty"`
	Config          map[string]interface{} `json:"config,omitempty"`
}

// DiscreteEventTrigger represents different trigger types for discrete events
type DiscreteEventTrigger struct {
	Type          string      `json:"type"` // "condition", "periodic", "preset_times"
	Expression    Expression  `json:"expression,omitempty"`    // for condition
	Interval      *float64    `json:"interval,omitempty"`      // for periodic
	InitialOffset *float64    `json:"initial_offset,omitempty"` // for periodic
	Times         []float64   `json:"times,omitempty"`         // for preset_times
}

// DiscreteEvent represents a discrete event
type DiscreteEvent struct {
	Name                string                `json:"name,omitempty"`
	Trigger             DiscreteEventTrigger  `json:"trigger"`
	Affects             []AffectEquation      `json:"affects,omitempty"`
	FunctionalAffect    *FunctionalAffect     `json:"functional_affect,omitempty"`
	DiscreteParameters  []string              `json:"discrete_parameters,omitempty"`
	Reinitialize        *bool                 `json:"reinitialize,omitempty"`
	Description         *string               `json:"description,omitempty"`
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
// pointing at a runtime handler. The native grid of the source, when known,
// is described by the optional Grid (a GDD Grid); reprojection and regridding
// are the responsibility of downstream rules, not the loader.
type DataLoader struct {
	Kind        string                        `json:"kind"` // "grid", "points", "static", or "mesh" (esm-spec §8.9)
	Source      DataLoaderSource              `json:"source"`
	Temporal    *DataLoaderTemporal           `json:"temporal,omitempty"`
	Grid        *Grid                         `json:"grid,omitempty"`
	Mesh        *DataLoaderMesh               `json:"mesh,omitempty"`
	Determinism *DataLoaderDeterminism        `json:"determinism,omitempty"`
	Variables   map[string]DataLoaderVariable `json:"variables"`
	Reference   *Reference                    `json:"reference,omitempty"`
	Metadata    map[string]interface{}        `json:"metadata,omitempty"`
}

// DataLoaderMesh is the mesh descriptor attached to a DataLoader with
// Kind == "mesh" (esm-spec §8.9). Connectivity fields are integer-typed;
// metric fields are float-typed. DimensionSizes entries are either an
// integer extent or the literal string "from_file".
type DataLoaderMesh struct {
	Topology           string                 `json:"topology"`            // "mpas_voronoi" | "fesom_triangular" | "icon_triangular"
	ConnectivityFields []string               `json:"connectivity_fields"` // e.g. cellsOnEdge
	MetricFields       []string               `json:"metric_fields"`       // e.g. dcEdge
	DimensionSizes     map[string]interface{} `json:"dimension_sizes,omitempty"`
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
	Type        string                       `json:"type"` // "operator_compose"
	Systems     [2]string                    `json:"systems"`
	Translate   map[string]interface{}       `json:"translate,omitempty"`
	Interface   *string                      `json:"interface,omitempty"`
	Lifting     *string                      `json:"lifting,omitempty"`
	Description *string                      `json:"description,omitempty"`
}

func (o OperatorComposeCoupling) GetType() string { return o.Type }

// CouplingCouple represents bi-directional coupling via connector equations
type CouplingCouple struct {
	Type        string    `json:"type"` // "couple"
	Systems     [2]string `json:"systems"`
	Connector   Connector `json:"connector"`
	Interface   *string   `json:"interface,omitempty"`
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
	Interface   *string  `json:"interface,omitempty"`
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
	Type               string                `json:"type"` // "event"
	EventType          string                `json:"event_type"` // "continuous" or "discrete"
	Name               string                `json:"name"`
	Conditions         []Expression          `json:"conditions,omitempty"`          // for continuous events
	Trigger            *DiscreteEventTrigger  `json:"trigger,omitempty"`             // for discrete events
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
// v0.2.0: boundary conditions have moved to Model.BoundaryConditions (RFC §9).
// Domain.BoundaryConditions (the deprecated v0.1.0 list form) is retained as a
// transitional compatibility shim; loaders emit E_DEPRECATED_DOMAIN_BC when it
// is present. A follow-up release will remove it entirely.
type Domain struct {
	IndependentVariable   *string                       `json:"independent_variable,omitempty"`
	Temporal              *TemporalDomain               `json:"temporal,omitempty"`
	Spatial               map[string]SpatialDimension   `json:"spatial,omitempty"`
	CoordinateTransforms  []CoordinateTransform         `json:"coordinate_transforms,omitempty"`
	SpatialRef            *string                       `json:"spatial_ref,omitempty"`
	InitialConditions     InitialConditions             `json:"initial_conditions,omitempty"`
	// Deprecated: v0.2.0 moves BCs to Model.BoundaryConditions. This field is
	// kept for transitional round-trip; loading a file with this field emits
	// E_DEPRECATED_DOMAIN_BC (see LoadString).
	BoundaryConditions    []DomainBoundaryConditionDeprecated          `json:"boundary_conditions,omitempty"`
	ElementType           *string                       `json:"element_type,omitempty"`
	ArrayType             *string                       `json:"array_type,omitempty"`
}

// DomainBoundaryConditionDeprecated is the legacy v0.1.0 domain-level boundary-condition
// entry. Kept in the v0.2.0 schema strictly as a transitional shim; use
// Model.BoundaryConditions (map keyed by BC id) for new code.
//
// Deprecated: use BoundaryCondition on Model.BoundaryConditions instead.
type DomainBoundaryConditionDeprecated struct {
	Type        string      `json:"type"`
	Dimensions  []string    `json:"dimensions"`
	Value       interface{} `json:"value,omitempty"`
	Function    *string     `json:"function,omitempty"`
	RobinAlpha  *float64    `json:"robin_alpha,omitempty"`
	RobinBeta   *float64    `json:"robin_beta,omitempty"`
	RobinGamma  *float64    `json:"robin_gamma,omitempty"`
}

// TemporalDomain represents temporal bounds
type TemporalDomain struct {
	Start         string  `json:"start"`
	End           string  `json:"end"`
	ReferenceTime *string `json:"reference_time,omitempty"`
}

// SpatialDimension represents a spatial dimension
type SpatialDimension struct {
	Min         float64 `json:"min"`
	Max         float64 `json:"max"`
	Units       string  `json:"units"`
	GridSpacing float64 `json:"grid_spacing"`
}

// CoordinateTransform represents a coordinate system transformation
type CoordinateTransform struct {
	ID          string   `json:"id"`
	Description *string  `json:"description,omitempty"`
	Dimensions  []string `json:"dimensions"`
}

// InitialConditions represents initial conditions specification
type InitialConditions struct {
	Type   string                 `json:"type"` // "constant", "per_variable", "from_file"
	Value  interface{}            `json:"value,omitempty"`
	Values map[string]interface{} `json:"values,omitempty"`
	Path   *string                `json:"path,omitempty"`
	Format *string                `json:"format,omitempty"`
}

// BoundaryCondition is a model-level BC entry (v0.2.0, RFC §9.2).
// It constrains one model variable on one boundary side. Replaces the v0.1.0
// domain-level form.
type BoundaryCondition struct {
	// Variable is the name of the model variable the BC constrains.
	Variable string `json:"variable"`
	// Side identifies the boundary side (e.g. "xmin", "xmax", "mesh_boundary").
	Side string `json:"side"`
	// Kind is the BC kind: "constant", "dirichlet", "neumann", "robin",
	// "zero_gradient", "periodic", "flux_contrib", or "interface".
	Kind string `json:"kind"`
	// Value is the BC value (numeric literal, variable reference, or Expression
	// AST). Required for kind="constant" or "dirichlet"; see RFC §9.2.
	Value interface{} `json:"value,omitempty"`
	// RobinAlpha/Beta/Gamma hold coefficients for kind="robin" (αu + β∂u/∂n = γ).
	RobinAlpha interface{} `json:"robin_alpha,omitempty"`
	RobinBeta  interface{} `json:"robin_beta,omitempty"`
	RobinGamma interface{} `json:"robin_gamma,omitempty"`
	// FaceCoords declares reduced face-coordinate index names used when Value
	// contains an index op into a loader-provided time-varying field.
	FaceCoords []string `json:"face_coords,omitempty"`
	// ContributedBy identifies the component providing a flux contribution
	// (kind="flux_contrib"). See RFC §9.3.
	ContributedBy *BCContributedBy `json:"contributed_by,omitempty"`
	// CoupledVariable is the name of the model variable at the other side of a
	// shared boundary point. Required when kind="interface"; ignored otherwise.
	CoupledVariable *string `json:"coupled_variable,omitempty"`
	// FluxMatch enforces normal-flux continuity in addition to value continuity
	// when kind="interface". Default false. See RFC §9.2.
	FluxMatch *bool `json:"flux_match,omitempty"`
	// Description is a human-readable description.
	Description *string `json:"description,omitempty"`
}

// RegridSpec is a per-variable regridding configuration entry on a model that
// owns a data loader as a subsystem (RFC pure-io-data-loaders §5.2, §6). All
// fields are optional.
type RegridSpec struct {
	// Method optionally overrides the staggering-derived regridding kernel:
	// "conservative", "bspline", or "cell_average".
	Method *string `json:"method,omitempty"`
	// MissingValue is the no-data fill for "cell_average" (scattered-point)
	// regridding: the value placed in a target cell with no contributing
	// source station. Ignored by the conservative/bspline kernels.
	MissingValue *float64 `json:"missing_value,omitempty"`
	// Description is a human-readable note about this variable's regridding.
	Description *string `json:"description,omitempty"`
}

// BCContributedBy identifies the contributing component for a flux_contrib BC.
type BCContributedBy struct {
	Component string  `json:"component"`
	FluxSign  *string `json:"flux_sign,omitempty"` // "+" or "-"
}

// ========================================
// 7a. Grids (v0.2.0, RFC §6)
// ========================================

// Grid is a named discretization grid declared at the top-level `grids` map.
// See docs/rfcs/discretization.md §6.
type Grid struct {
	Family             string                         `json:"family"`        // "cartesian" | "unstructured"
	CRS                *GridCRS                       `json:"crs,omitempty"` // optional coordinate reference system, orthogonal to Family (§4.2)
	Description        *string                        `json:"description,omitempty"`
	Dimensions         []string                       `json:"dimensions"`
	Locations          []string                       `json:"locations,omitempty"`
	MetricArrays       map[string]GridMetricArray     `json:"metric_arrays,omitempty"`
	Parameters         map[string]Parameter           `json:"parameters,omitempty"`
	Domain             *string                        `json:"domain,omitempty"`
	Extents            map[string]GridExtent          `json:"extents,omitempty"`
	Connectivity       map[string]GridConnectivity    `json:"connectivity,omitempty"`
}

// GridCRS is the optional coordinate reference system for a grid (RFC
// pure-io-data-loaders §4.2), orthogonal to the topological Family: a
// "cartesian" grid may be geographic ("longlat") or projected
// ("lambert_conformal", ...), and a point dataset may be "unstructured" +
// "longlat". It names the projection and the parameters a downstream
// reprojection rule consumes; the grid itself performs no reprojection.
type GridCRS struct {
	Projection string             `json:"projection"`           // longlat | lambert_conformal | mercator | polar_stereographic | rotated_pole
	Datum      *string            `json:"datum,omitempty"`      // "sphere" (radius R) | "WGS84"
	R          *float64           `json:"R,omitempty"`          // sphere radius in metres, used when datum="sphere"
	Parameters map[string]float64 `json:"parameters,omitempty"` // projection parameters, e.g. {lat_1, lat_2, lat_0, lon_0}
}

// GridExtent is a per-dimension extent (cartesian). `N` is an
// integer literal or a parameter-reference string; `Spacing` is optional and
// only meaningful for cartesian ('uniform' or 'nonuniform').
type GridExtent struct {
	N       interface{} `json:"n"`
	Spacing *string     `json:"spacing,omitempty"`
}

// GridMetricArray is a named metric array on a grid (e.g., dx, areaCell). §6.5.
type GridMetricArray struct {
	Rank      int                 `json:"rank"`
	Dim       *string             `json:"dim,omitempty"`
	Dims      []string            `json:"dims,omitempty"`
	Shape     []interface{}       `json:"shape,omitempty"`
	Generator GridMetricGenerator `json:"generator"`
}

// GridMetricGenerator is the generator for a metric array — one of expression,
// loader, or builtin per §6.5.
type GridMetricGenerator struct {
	Kind   string      `json:"kind"` // "expression" | "loader" | "builtin"
	Expr   interface{} `json:"expr,omitempty"`
	Loader *string     `json:"loader,omitempty"`
	Field  *string     `json:"field,omitempty"`
	Name   *string     `json:"name,omitempty"`
}

// GridConnectivity is an unstructured connectivity table (§6.3 /
// §6.4). Entries are either loader-backed (Loader+Field) or generator-backed
// (Generator).
type GridConnectivity struct {
	Shape     []interface{}        `json:"shape"`
	Rank      int                  `json:"rank"`
	Loader    *string              `json:"loader,omitempty"`
	Field     *string              `json:"field,omitempty"`
	Generator *GridMetricGenerator `json:"generator,omitempty"`
}

// ========================================
// 7b. Interfaces
// ========================================

// Interface represents a geometric connection between two domains
type Interface struct {
	Description      *string          `json:"description,omitempty"`
	Domains          [2]string        `json:"domains"`
	DimensionMapping DimensionMapping `json:"dimension_mapping"`
	Regridding       *Regridding      `json:"regridding,omitempty"`
}

// DimensionMapping specifies shared dimensions and constraints at an interface
type DimensionMapping struct {
	Shared      map[string]string              `json:"shared,omitempty"`
	Constraints map[string]InterfaceConstraint `json:"constraints,omitempty"`
}

// InterfaceConstraint represents a constraint on a non-shared dimension at the interface
type InterfaceConstraint struct {
	Value       interface{} `json:"value"` // string ("min", "max", "boundary") or number
	Description *string     `json:"description,omitempty"`
}

// Regridding represents the regridding strategy at an interface
type Regridding struct {
	Method      string  `json:"method"` // "bilinear", "conservative", "nearest", "patch"
	Description *string `json:"description,omitempty"`
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
	Enums           map[string]map[string]int `json:"enums,omitempty"`
	Coupling        []interface{}             `json:"coupling,omitempty"` // Properly deserialized coupling entries
	Domains         map[string]Domain         `json:"domains,omitempty"`
	Interfaces      map[string]Interface      `json:"interfaces,omitempty"`
	Discretizations map[string]Discretization `json:"discretizations,omitempty"`
	// Grids holds top-level discretization grid declarations (v0.2.0, RFC §6).
	Grids map[string]Grid `json:"grids,omitempty"`
	// StaggeringRules holds top-level staggering-rule declarations (RFC §7.4).
	StaggeringRules map[string]StaggeringRule `json:"staggering_rules,omitempty"`
	// FunctionTables holds top-level sampled function tables (esm-spec §9.5,
	// v0.4.0). Each entry is a FunctionTable referenced by `table_lookup` AST
	// op nodes via its key.
	FunctionTables map[string]FunctionTable `json:"function_tables,omitempty"`
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

// Discretization is a named discretization scheme. Four variants are
// supported:
//
//   - "stencil" (the default when Kind is "") is a neighbor-combination
//     template per RFC §7.1.
//   - "dimensional_split" composes a 1D inner scheme along several orthogonal
//     axes via Strang/Lie operator splitting per RFC §7.5.
//   - "flux_form_semi_lagrangian" is a flux-form semi-Lagrangian (FFSL)
//     advection scheme (Lin & Rood 1996) per RFC §7.7 that uses
//     Reconstruction / Remap / Limiter / CflPolicy / Dimensions instead of
//     Stencil.
//
// The AST-pattern fields (AppliesTo, Stencil[*].Coeff, NeighborSelector
// expression slots) carry pattern variables like "$u" / "$target" that are
// bound by the rule engine at expansion time — they are not ordinary
// Expressions and thus are preserved as raw json.RawMessage for lossless
// round-tripping. Reconstruction and Limiter are raw JSON because they may
// be either a string (rule ref) or an inline object.
type Discretization struct {
	// Kind discriminates scheme sub-types:
	//   "" or "stencil"             = classic neighbor-combination template (§7.1)
	//   "dimensional_split"         = axis-sweep composite (§7.5); activates
	//                                 InnerRule / Splitting / OrderOfSweeps
	//   "flux_form_semi_lagrangian" = FFSL advection rule (§7.7); activates
	//                                 Reconstruction / Remap / Limiter /
	//                                 CflPolicy / Dimensions.
	//   "multi_output_stencil"      = multi-output stencil rule (§7.9); activates
	//                                 Outputs / MultiOutputStencil / Primary.
	Kind               string            `json:"kind,omitempty"`
	// AppliesTo is the shallow (depth-1) AST pattern identifying the operator
	// this scheme discretizes. Preserved as raw JSON because the pattern may
	// contain pattern variables ($u, $x, ...) that are not valid
	// Expression ops.
	AppliesTo          json.RawMessage   `json:"applies_to"`
	GridFamily         string            `json:"grid_family"`
	Combine            string            `json:"combine,omitempty"`
	// Stencil is the per-neighbor contribution list for a standard
	// discretization (RFC §7.1). Mutually exclusive with Terms and MultiOutputStencil.
	Stencil            []StencilEntry    `json:"stencil,omitempty"`
	// StencilGen is a declarative stencil-weight generator (RFC §7.1.3).
	// Mutually exclusive with Stencil; expanded by the Julia loader at parse time.
	StencilGen         *StencilGen       `json:"stencil_gen,omitempty"`

	// Axes is the ordered coordinate-axis list for a "dimensional_split"
	// composite (§7.5).
	Axes               []string          `json:"axes,omitempty"`

	// InnerRule, Splitting, OrderOfSweeps apply to "dimensional_split"
	// composites (§7.5).
	InnerRule          string            `json:"inner_rule,omitempty"`
	Splitting          string            `json:"splitting,omitempty"`
	OrderOfSweeps      string            `json:"order_of_sweeps,omitempty"`

	// Reconstruction (FFSL §7.7): sub-cell reconstruction — string rule-ref
	// or inline {order, parameters} object.
	Reconstruction     json.RawMessage   `json:"reconstruction,omitempty"`
	// Remap (FFSL §7.7): flux-form remap semantics.
	Remap              *FfslRemap        `json:"remap,omitempty"`
	// Limiter (FFSL §7.7, optional): slope/flux limiter — string rule-ref or
	// inline {family, parameters} object.
	Limiter            json.RawMessage   `json:"limiter,omitempty"`
	// CflPolicy (FFSL §7.7): "conservative" or "non_conservative".
	CflPolicy          string            `json:"cfl_policy,omitempty"`
	// Dimensions (FFSL §7.7): axis names, in application order.
	Dimensions         []string          `json:"dimensions,omitempty"`
	Accuracy           string            `json:"accuracy,omitempty"`
	// Order optionally selects stencil width / truncation order for
	// families that admit a parameterized order (e.g. arbitrary-order
	// centered uniform finite differences via Fornberg-recursion weights).
	// Pointer-to-int so zero-vs-absent is preserved across round-trips.
	// See discretization RFC §7.1.
	Order              *int              `json:"order,omitempty"`
	RequiresLocations  []string          `json:"requires_locations,omitempty"`
	EmitsLocation      string            `json:"emits_location,omitempty"`
	TargetBinding      string            `json:"target_binding,omitempty"`
	GhostVars          []GhostVarDecl    `json:"ghost_vars,omitempty"`
	FreeVariables      []string          `json:"free_variables,omitempty"`
	Description        string            `json:"description,omitempty"`
	Reference          *Reference        `json:"reference,omitempty"`
	// GridDispatch (RFC §7.8) declares family-keyed body variants in lieu of an
	// inline body. When non-empty, GridFamily and the inline body fields
	// (Stencil / Axes / InnerRule / etc.) MUST be empty; the loader picks the
	// variant whose GridFamily matches the active grid at expansion time.
	GridDispatch       []DiscretizationVariant `json:"grid_dispatch,omitempty"`

	// Outputs is the ordered list of named outputs for a "multi_output_stencil"
	// scheme (RFC §7.9). Key set MUST equal the keys of MultiOutputStencil.
	Outputs            []string                     `json:"outputs,omitempty"`
	// MultiOutputStencil is the object-valued stencil for kind="multi_output_stencil"
	// (RFC §7.9): keyed by output name → stencil-entry list. Mutually exclusive
	// with the flat Stencil slice. Marshaled / unmarshaled under the JSON key
	// "stencil" via custom JSON methods.
	MultiOutputStencil map[string][]StencilEntry    `json:"-"`
	// Primary is the name of the output to substitute at the matched expression
	// site in the consumed-directly trigger path (RFC §7.9). json.RawMessage
	// preserves the JSON null literal verbatim; a nil/empty RawMessage is omitted.
	Primary            json.RawMessage              `json:"primary,omitempty"`
	// Requires is the RFC §7.9 consumer demand map. Maps local names used inside
	// this scheme's stencil coefficient expressions to outputs of sibling
	// MultiOutputStencilRule providers in the form "<sibling-scheme>#<output-name>".
	Requires           map[string]string            `json:"requires,omitempty"`
}

// MarshalJSON serializes Discretization, routing MultiOutputStencil to the
// "stencil" JSON key as an object when the scheme is a multi_output_stencil.
func (d Discretization) MarshalJSON() ([]byte, error) {
	type DiscAlias Discretization
	alias := DiscAlias(d)
	raw, err := json.Marshal(alias)
	if err != nil {
		return nil, err
	}
	if len(d.MultiOutputStencil) == 0 {
		return raw, nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	stencilBytes, err := json.Marshal(d.MultiOutputStencil)
	if err != nil {
		return nil, err
	}
	m["stencil"] = json.RawMessage(stencilBytes)
	return json.Marshal(m)
}

// UnmarshalJSON deserializes Discretization, routing the "stencil" JSON key
// to either Stencil (array form) or MultiOutputStencil (object form, §7.9).
func (d *Discretization) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	stencilRaw, hasStencil := raw["stencil"]
	if hasStencil {
		delete(raw, "stencil")
	}
	remaining, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	type DiscAlias Discretization
	alias := &DiscAlias{}
	if err := json.Unmarshal(remaining, alias); err != nil {
		return err
	}
	*d = Discretization(*alias)
	if hasStencil {
		trimmed := bytes.TrimSpace(stencilRaw)
		if len(trimmed) > 0 && trimmed[0] == '{' {
			if err := json.Unmarshal(stencilRaw, &d.MultiOutputStencil); err != nil {
				return err
			}
		} else {
			if err := json.Unmarshal(stencilRaw, &d.Stencil); err != nil {
				return err
			}
		}
	}
	return nil
}

// DiscretizationVariant (RFC §7.8) is one entry of a Discretization's
// grid_dispatch block: a per-grid-family body that replaces the parent's
// inline body when the active grid family matches GridFamily. Body fields
// follow the same kind-discriminated semantics as the parent Discretization;
// shared fields (AppliesTo, Accuracy, Order, RequiresLocations, etc.) live on
// the parent and are not duplicated.
type DiscretizationVariant struct {
	GridFamily     string          `json:"grid_family"`
	Kind           string          `json:"kind,omitempty"`
	Combine        string          `json:"combine,omitempty"`
	Stencil        []StencilEntry  `json:"stencil,omitempty"`
	Axes           []string        `json:"axes,omitempty"`
	InnerRule      string          `json:"inner_rule,omitempty"`
	Splitting      string          `json:"splitting,omitempty"`
	OrderOfSweeps  string          `json:"order_of_sweeps,omitempty"`
	Reconstruction json.RawMessage `json:"reconstruction,omitempty"`
	Remap          *FfslRemap      `json:"remap,omitempty"`
	Limiter        json.RawMessage `json:"limiter,omitempty"`
	CflPolicy      string          `json:"cfl_policy,omitempty"`
	Dimensions     []string        `json:"dimensions,omitempty"`
}

// IsMultiOutput reports whether this Discretization is a multi-output stencil
// rule (RFC §7.9): kind="multi_output_stencil" or MultiOutputStencil is populated.
func (d *Discretization) IsMultiOutput() bool {
	return d.Kind == "multi_output_stencil" || len(d.MultiOutputStencil) > 0
}

// FfslRemap is the `remap` field of a flux-form semi-Lagrangian rule
// (RFC §7.7). Semantics is "conservative" or "non_conservative".
type FfslRemap struct {
	Semantics  string                 `json:"semantics"`
	FluxForm   string                 `json:"flux_form,omitempty"`
	Parameters map[string]interface{} `json:"parameters,omitempty"`
}

// StencilEntry is one neighbor contribution: a selector plus a symbolic
// coefficient. Coeff is raw JSON so that pattern variables survive round-trip.
type StencilEntry struct {
	Selector NeighborSelector `json:"selector"`
	Coeff    json.RawMessage  `json:"coeff"`
}

// StencilGen is a declarative finite-difference weight generator (RFC §7.1.3).
// The Julia loader expands it into an equivalent StencilEntry list at parse time
// using the Fornberg recurrence in exact rational arithmetic.
// Go preserves StencilGen for round-trip fidelity; it does not evaluate it.
type StencilGen struct {
	Method        string `json:"method"`
	DerivOrder    int    `json:"deriv_order"`
	AccuracyOrder int    `json:"accuracy_order"`
	Stagger       string `json:"stagger"`
	Axis          string `json:"axis"`
	Spacing       string `json:"spacing"`
}

// NeighborSelector selects a neighbor (or neighbor set) in a stencil entry.
// Kind discriminates the selector family; per-kind fields are carried as raw
// JSON because they may contain pattern variables.
type NeighborSelector struct {
	Kind       string          `json:"kind"`
	Axis       json.RawMessage `json:"axis,omitempty"`
	Offset     json.RawMessage `json:"offset,omitempty"`
	Side       json.RawMessage `json:"side,omitempty"`
	Di         json.RawMessage `json:"di,omitempty"`
	Dj         json.RawMessage `json:"dj,omitempty"`
	IndexExpr  json.RawMessage `json:"index_expr,omitempty"`
	Table      string          `json:"table,omitempty"`
	CountExpr  json.RawMessage `json:"count_expr,omitempty"`
	KBound     string          `json:"k_bound,omitempty"`
	Combine    string          `json:"combine,omitempty"`
}

// StaggeringRule is a named staggering convention declaring where quantities
// live on a grid (RFC §7.4). Kind discriminates the staggering family; v0.2.0
// defines "unstructured_c_grid" (MPAS Voronoi). The referenced Grid must be
// of family "unstructured".
type StaggeringRule struct {
	Kind                   string            `json:"kind"`
	Grid                   string            `json:"grid"`
	Description            string            `json:"description,omitempty"`
	CellQuantityLocations  map[string]string `json:"cell_quantity_locations,omitempty"`
	EdgeNormalConvention   string            `json:"edge_normal_convention,omitempty"`
	DualMeshRef            string            `json:"dual_mesh_ref,omitempty"`
	Reference              *Reference        `json:"reference,omitempty"`
}

// GhostVarDecl declares a ghost-cell variable used by a discretization scheme.
type GhostVarDecl struct {
	Name        string  `json:"name"`
	Source      string  `json:"source,omitempty"`
	Description string  `json:"description,omitempty"`
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
		LHS    json.RawMessage `json:"lhs"`
		RHS    json.RawMessage `json:"rhs"`
		Region json.RawMessage `json:"region,omitempty"`
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

	// Unmarshal region (optional — string or object)
	if len(temp.Region) > 0 && string(temp.Region) != "null" {
		var region interface{}
		if err := json.Unmarshal(temp.Region, &region); err != nil {
			return fmt.Errorf("failed to unmarshal region: %w", err)
		}
		e.Region = &region
	}

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
		Type               string                 `json:"type"`
		EventType          string                 `json:"event_type"`
		Name               string                 `json:"name"`
		Conditions         []json.RawMessage      `json:"conditions,omitempty"`
		Trigger            *DiscreteEventTrigger  `json:"trigger,omitempty"`
		Affects            []AffectEquation       `json:"affects"`
		DiscreteParameters []string               `json:"discrete_parameters,omitempty"`
		Description        *string                `json:"description,omitempty"`
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
		Domains         map[string]Domain         `json:"domains,omitempty"`
		Interfaces      map[string]Interface      `json:"interfaces,omitempty"`
		Discretizations map[string]Discretization `json:"discretizations,omitempty"`
		Grids           map[string]Grid           `json:"grids,omitempty"`
		StaggeringRules map[string]StaggeringRule `json:"staggering_rules,omitempty"`
		FunctionTables  map[string]FunctionTable  `json:"function_tables,omitempty"`
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
	esm.Domains = temp.Domains
	esm.Interfaces = temp.Interfaces
	esm.Discretizations = temp.Discretizations
	esm.Grids = temp.Grids
	esm.StaggeringRules = temp.StaggeringRules
	esm.FunctionTables = temp.FunctionTables

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
