package esm

import (
	"bytes"
	"encoding/json"
)

// variable_model.go holds the esm 1.0.0 unified variable model: the two
// declared types and the parameter sidecars (`distribution`, `update`) that
// replaced the `brownian` / `discrete` types, the variable `expression` field,
// and the event `functional_affect` / `discrete_parameters` lists.
//
// The DERIVED categories a solver needs live in classification.go
// (esm-spec §6.3.1). Nothing in this package may read a declared type to answer
// a derived question — that is precisely what 1.0.0 removes.

// ModelVariable represents a variable in a mathematical model.
//
// esm 1.0.0 declares exactly TWO types, `unknown` and `parameter`
// (esm-spec §5.4). Everything finer is DERIVED, never declared:
//
//   - whether an unknown is an ODE state, an observed quantity or an algebraic
//     one follows from the model's EQUATIONS. There is no `expression` field on
//     a variable any more: an unknown's behaviour is stated by `equations` and
//     nowhere else, so what used to be `variables.y.expression = E` is now the
//     equation `{"lhs": "y", "rhs": E}`.
//   - whether a parameter is Brownian, discrete, sampled or constant follows
//     from its Distribution and Update.
type ModelVariable struct {
	Type    string  `json:"type"` // "unknown" or "parameter"
	Units   *string `json:"units,omitempty"`
	Default any     `json:"default,omitempty"`
	// DefaultUnits declares the units the scalar `default` is expressed in when
	// they differ from `units`. The value is converted at load. A conversion that
	// is AFFINE (degC↔K) cannot be expressed as a scalar factor, so declaring one
	// here is a `unit_inconsistency` — see checkDefaultUnits.
	DefaultUnits *string `json:"default_units,omitempty"`
	Description  *string `json:"description,omitempty"`
	// Shape lists index-set names for arrayed variables, drawn from the
	// document-scoped `index_sets` registry (ESMFile.IndexSets). Nil means
	// scalar. As of v0.8.0 the iteration domains named here live at document
	// scope, not on the model. See RFC semiring-faq-unified-ir §5.2 / §6.1.
	//
	// REQUIRED (by the schema) for a parameter whose update kind is `schedule`,
	// `data` or `remesh`: such a parameter is a buffer whose extent must be known
	// before the first refresh. An empty non-nil slice is a valid scalar shape,
	// which is why ShapeDeclared distinguishes it from absent.
	Shape []string `json:"shape,omitempty"`
	// Location tags the variable's staggered-grid location
	// (e.g., "cell_center", "edge_normal", "vertex"). Empty means
	// no explicit staggering. See discretization RFC §10.2.
	Location string `json:"location,omitempty"`
	// Distribution is PARAMETER-ONLY: draw the value from a probability
	// distribution instead of fixing it at `default` (mutually exclusive with
	// it). With no Update the draw happens ONCE at setup (the UQ / ensemble
	// case); with `update.kind: "wiener"` it is redrawn every step with √dt
	// scaling, which promotes the model to an SDE.
	Distribution *Distribution `json:"distribution,omitempty"`
	// Update is PARAMETER-ONLY: when this parameter refreshes and what from.
	// Absent means it never changes after setup. See ParameterUpdateSpec for the
	// single-rule / ordered-array union.
	Update *ParameterUpdateSpec `json:"update,omitempty"`

	// shapeDeclared records whether `shape` was PRESENT on the wire, so that an
	// explicit `"shape": []` (a legal declared scalar shape) stays
	// distinguishable from an absent one. Set by UnmarshalJSON.
	shapeDeclared bool
}

// ShapeDeclared reports whether the variable carried a `shape` key on the wire,
// including the empty-array (scalar) spelling. `len(v.Shape) > 0` cannot answer
// this: the schema treats `"shape": []` as a declared scalar shape and it is a
// legal way to satisfy the schedule/data/remesh shape requirement.
func (v ModelVariable) ShapeDeclared() bool { return v.shapeDeclared || len(v.Shape) > 0 }

// UnmarshalJSON decodes a variable, keeping two wire distinctions a plain
// struct decode would lose: an integer-valued `default` keeps its int shape
// (RFC §5.4.1), and a present-but-empty `shape` stays distinct from an absent
// one.
func (v *ModelVariable) UnmarshalJSON(data []byte) error {
	type tempModelVariable struct {
		Type         string               `json:"type"`
		Units        *string              `json:"units,omitempty"`
		DefaultUnits *string              `json:"default_units,omitempty"`
		Default      json.RawMessage      `json:"default,omitempty"`
		Description  *string              `json:"description,omitempty"`
		Shape        *[]string            `json:"shape,omitempty"`
		Location     string               `json:"location,omitempty"`
		Distribution *Distribution        `json:"distribution,omitempty"`
		Update       *ParameterUpdateSpec `json:"update,omitempty"`
	}
	var temp tempModelVariable
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	v.Type = temp.Type
	v.Units = temp.Units
	v.DefaultUnits = temp.DefaultUnits
	v.Description = temp.Description
	v.Location = temp.Location
	v.Distribution = temp.Distribution
	v.Update = temp.Update

	// `shape` decodes through a POINTER so that an explicit `"shape": []` — a
	// legal declared scalar shape, and one of the ways a schedule/data/remesh
	// parameter satisfies its shape requirement — stays distinguishable from an
	// absent key. A plain []string flattens both to nil.
	if temp.Shape != nil {
		v.Shape = *temp.Shape
		v.shapeDeclared = true
	}

	// Decode `default` through UnmarshalExpression so an integer-valued default
	// (`"default": 1`) keeps its int wire shape instead of collapsing to float64
	// and re-emitting as "1.0", per RFC §5.4.1's int/float distinction.
	def, err := unmarshalOptionalExpression(temp.Default)
	if err != nil {
		return err
	}
	v.Default = def
	return nil
}

// Distribution is a parameter's value drawn from a probability distribution
// rather than fixed (esm-spec §5.4). The registry is CLOSED — `normal`,
// `lognormal`, `uniform` — exactly as §9.1's closed-registry principle requires.
//
// The location parameter (Mean / Mu / Low) discriminates arity: a number is
// univariate, an array multivariate, and in the multivariate case the
// parameter's Shape must agree. Spread is Std / Sigma for independent
// components or Cov for a full covariance matrix — exactly one of the two.
// Correlated noise is ONE vector-valued parameter whose distribution carries a
// Cov; there is no separate correlation-group tag any more.
type Distribution struct {
	Kind string `json:"kind"` // "normal" | "lognormal" | "uniform"
	// Mean is the location of a `normal` (number or array).
	Mean any `json:"mean,omitempty"`
	// Std is the independent-component spread of a `normal` (number or array).
	Std any `json:"std,omitempty"`
	// Mu is the log-scale location of a `lognormal` (number or array).
	Mu any `json:"mu,omitempty"`
	// Sigma is the log-scale independent-component spread of a `lognormal`.
	Sigma any `json:"sigma,omitempty"`
	// Low and High bound a `uniform` (numbers or equal-length arrays).
	Low  any `json:"low,omitempty"`
	High any `json:"high,omitempty"`
	// Cov is the full covariance matrix of a multivariate `normal` /
	// `lognormal`; mutually exclusive with Std / Sigma. `uniform` has no
	// covariance form.
	Cov [][]float64 `json:"cov,omitempty"`
}

// Location returns the distribution's location parameter — Mean, Mu or Low
// according to Kind — and whether the kind was recognised. It exists so callers
// deciding univariate-vs-multivariate do not each re-switch on Kind.
func (d *Distribution) Location() (any, bool) {
	if d == nil {
		return nil, false
	}
	switch d.Kind {
	case DistributionNormal:
		return d.Mean, true
	case DistributionLognormal:
		return d.Mu, true
	case DistributionUniform:
		return d.Low, true
	}
	return nil, false
}

// IsMultivariate reports whether the distribution's location parameter is an
// array, which is what makes the draw vector-valued (esm-spec §5.4).
func (d *Distribution) IsMultivariate() bool {
	loc, ok := d.Location()
	if !ok {
		return false
	}
	_, isArray := loc.([]any)
	return isArray
}

// FunctionalUpdate is a registered handler computing a parameter's new value
// when its update fires (esm-spec §5.4).
//
// This is the 0.x event `functional_affect` RELOCATED. A handler's only write
// channel was `modified_params`, so in 1.0.0 it lives ON the parameter it writes
// and needs no write list at all — which is why there is no ModifiedParams
// field here. `handler_id` is the sole remaining registration mechanism in the
// format; handlers are deliberately outside the §9 closed function registry,
// since they mutate simulator state rather than being pure callables.
type FunctionalUpdate struct {
	HandlerID  string         `json:"handler_id"`
	ReadVars   []string       `json:"read_vars,omitempty"`
	ReadParams []string       `json:"read_params,omitempty"`
	Config     map[string]any `json:"config,omitempty"`
}

// DataSourceBinding binds a parameter to one variable of a `data_sources` entry
// (esm-spec §8). It is the 0.x DataLoaderVariable MINUS `units`: the units are
// the parameter's own, declared once on the parameter instead of twice.
type DataSourceBinding struct {
	FileVariable string `json:"file_variable"`
	// UnitConversion is a multiplicative factor reaching the parameter's declared
	// units — a plain number or a full Expression AST (§4). The schema spells it
	// as a single Expression $ref, because Expression already admits a bare
	// number; the 0.x `oneOf: [number, Expression]` was unsatisfiable for every
	// plain factor. It is an Expression POSITION, so its free names are subject
	// to reference integrity (§4.9.5).
	UnitConversion Expression `json:"unit_conversion,omitempty"`
	// Codes decodes a text label into a number — contrast UnitConversion, which
	// scales a number that is already one.
	Codes any `json:"codes,omitempty"`
	// Select overrides the source-level default slice for this parameter only,
	// which is how a full-grid field and a prefix of it are both read from one
	// file_variable without either being sliced by the consumer.
	Select      any        `json:"select,omitempty"`
	Description *string    `json:"description,omitempty"`
	Reference   *Reference `json:"reference,omitempty"`
}

// UnmarshalJSON normalizes the `unit_conversion` Expression union (number,
// string or operator node) the same way every other Expression position is
// decoded.
func (b *DataSourceBinding) UnmarshalJSON(data []byte) error {
	type tempBinding struct {
		FileVariable   string          `json:"file_variable"`
		UnitConversion json.RawMessage `json:"unit_conversion,omitempty"`
		Codes          any             `json:"codes,omitempty"`
		Select         any             `json:"select,omitempty"`
		Description    *string         `json:"description,omitempty"`
		Reference      *Reference      `json:"reference,omitempty"`
	}
	var temp tempBinding
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	b.FileVariable = temp.FileVariable
	b.Codes = temp.Codes
	b.Select = temp.Select
	b.Description = temp.Description
	b.Reference = temp.Reference
	conv, err := unmarshalOptionalExpression(temp.UnitConversion)
	if err != nil {
		return err
	}
	b.UnitConversion = conv
	return nil
}

// ParameterUpdate declares WHEN a parameter refreshes and WHAT from
// (esm-spec §5.4). Six kinds, and they subsume three constructs 0.x kept apart:
// the `brownian` variable type (now `wiener`), the `discrete` type with its
// refresh trigger (now `schedule` / `data` / `remesh`), and the
// `discrete_parameters` event lists with their `functional_affect` (now
// `condition` / `crossing`).
//
// `wiener` takes NO value form — it resamples the parameter's own Distribution.
// The other five take EXACTLY ONE of Expression, From or Handler.
//
// This is also the sole seed of the DISCRETE cadence class
// (CONFORMANCE_SPEC §5.7.2).
type ParameterUpdate struct {
	Kind string `json:"kind"` // wiener | schedule | condition | crossing | data | remesh

	// --- schedule ---
	// Times are explicit simulation times (the tstops) at which the parameter
	// refreshes; Interval is a periodic refresh interval. `schedule` requires at
	// least one of the two.
	Times         []float64 `json:"times,omitempty"`
	Interval      *float64  `json:"interval,omitempty"`
	InitialOffset *float64  `json:"initial_offset,omitempty"`

	// --- condition / crossing ---
	// When is the boolean expression tested at end of step (`condition`) or the
	// expression whose zero crossing triggers the refresh (`crossing`).
	When Expression `json:"when,omitempty"`
	// Direction selects which crossings count: "up" | "down" | "any".
	Direction string `json:"direction,omitempty"`

	// --- data ---
	// Source is the key of the `data_sources` entry whose record advance drives
	// this refresh. It MUST resolve — `data_source_undefined` otherwise.
	Source string `json:"source,omitempty"`

	// --- remesh ---
	// Hook optionally names the remesh hook driving the refresh; absent means any
	// remesh event.
	Hook string `json:"hook,omitempty"`

	// --- the three value forms (exactly one, except for `wiener`) ---
	Expression Expression         `json:"expression,omitempty"`
	From       *DataSourceBinding `json:"from,omitempty"`
	Handler    *FunctionalUpdate  `json:"handler,omitempty"`
}

// UnmarshalJSON normalizes the two Expression positions (`when`, `expression`)
// so a nested operator node arrives as an ExprNode rather than a raw map, the
// same way decode.go treats every other Expression field.
func (p *ParameterUpdate) UnmarshalJSON(data []byte) error {
	type tempUpdate struct {
		Kind          string             `json:"kind"`
		Times         []float64          `json:"times,omitempty"`
		Interval      *float64           `json:"interval,omitempty"`
		InitialOffset *float64           `json:"initial_offset,omitempty"`
		When          json.RawMessage    `json:"when,omitempty"`
		Direction     string             `json:"direction,omitempty"`
		Source        string             `json:"source,omitempty"`
		Hook          string             `json:"hook,omitempty"`
		Expression    json.RawMessage    `json:"expression,omitempty"`
		From          *DataSourceBinding `json:"from,omitempty"`
		Handler       *FunctionalUpdate  `json:"handler,omitempty"`
	}
	var temp tempUpdate
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	p.Kind = temp.Kind
	p.Times = temp.Times
	p.Interval = temp.Interval
	p.InitialOffset = temp.InitialOffset
	p.Direction = temp.Direction
	p.Source = temp.Source
	p.Hook = temp.Hook
	p.From = temp.From
	p.Handler = temp.Handler

	when, err := unmarshalOptionalExpression(temp.When)
	if err != nil {
		return err
	}
	p.When = when
	expr, err := unmarshalOptionalExpression(temp.Expression)
	if err != nil {
		return err
	}
	p.Expression = expr
	return nil
}

// ParameterUpdateSpec is a parameter's update behaviour: EITHER a single rule OR
// an ordered array of two or more (esm-spec §5.4).
//
// The array form exists because collapsing parameter mutation onto the parameter
// must not cost expressiveness events had: before 1.0.0 any number of events
// could write one parameter, and a counter incremented on two schedules or a
// continuous event's affects/affect_neg pair is ONE parameter with several
// rules. Rules are independent and, where more than one fires, apply in
// DECLARATION ORDER.
//
// A single rule MUST be the object form — a one-element array is invalid — so
// the representation of any update set is unique and the round-trip stable.
// That is why IsArray is carried explicitly rather than inferred from
// len(Rules).
type ParameterUpdateSpec struct {
	// Rules holds the update rules in declaration order. A single-rule spec has
	// exactly one entry and IsArray false.
	Rules []ParameterUpdate
	// IsArray records the wire spelling so MarshalJSON reproduces it exactly.
	IsArray bool
}

// UnmarshalJSON accepts either the object form (one rule) or the array form
// (two or more), recording which was used.
func (u *ParameterUpdateSpec) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '[' {
		var rules []ParameterUpdate
		if err := json.Unmarshal(data, &rules); err != nil {
			return err
		}
		u.Rules = rules
		u.IsArray = true
		return nil
	}
	var single ParameterUpdate
	if err := json.Unmarshal(data, &single); err != nil {
		return err
	}
	u.Rules = []ParameterUpdate{single}
	u.IsArray = false
	return nil
}

// MarshalJSON re-emits the spelling the document used, so a round-trip is
// byte-stable in both forms.
func (u ParameterUpdateSpec) MarshalJSON() ([]byte, error) {
	if u.IsArray {
		return json.Marshal(u.Rules)
	}
	if len(u.Rules) == 0 {
		return []byte("null"), nil
	}
	return json.Marshal(u.Rules[0])
}

// IsWiener reports whether this spec is the driving-noise form.
//
// The schema forbids `wiener` inside the array form — a driving noise process is
// the parameter's whole value, so combining it with scheduled writes is
// incoherent — so in practice an array is never Brownian. The test is
// nonetheless written as "ANY rule is wiener", because that is what
// esm-spec §6.3.1 states, and a hand-built or schema-skipping document should
// still classify the way the spec says rather than the way the schema happens to
// constrain.
func (u *ParameterUpdateSpec) IsWiener() bool {
	if u == nil {
		return false
	}
	for _, r := range u.Rules {
		if r.Kind == UpdateKindWiener {
			return true
		}
	}
	return false
}

// DataSourceKeys returns the `data_sources` keys this spec's `data`-kind rules
// name, in declaration order. Used by the data_source_undefined check.
func (u *ParameterUpdateSpec) DataSourceKeys() []string {
	if u == nil {
		return nil
	}
	var out []string
	for _, r := range u.Rules {
		if r.Kind == UpdateKindData && r.Source != "" {
			out = append(out, r.Source)
		}
	}
	return out
}

// RequiresShape reports whether any rule is one of the three buffer-filling
// kinds (`schedule`, `data`, `remesh`) that oblige the parameter to declare a
// `shape`: the runtime must size the buffer before the first refresh.
func (u *ParameterUpdateSpec) RequiresShape() bool {
	if u == nil {
		return false
	}
	for _, r := range u.Rules {
		switch r.Kind {
		case UpdateKindSchedule, UpdateKindData, UpdateKindRemesh:
			return true
		}
	}
	return false
}
