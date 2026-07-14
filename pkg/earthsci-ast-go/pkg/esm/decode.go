package esm

// decode.go holds the custom json.Unmarshaler implementations and coupling-decode
// helpers for the esm types. It was split out of types.go (which now carries only
// the type declarations and the Validate/ToJSON/FromJSON entry points) so the
// decode logic — the union-typed Expression handling, the int/float wire-shape
// preservation, and the discriminated coupling-entry dispatch — lives in one
// place. This is a pure move: no behavior differs from the previous in-types.go
// definitions.

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// ========================================
// 11. Helper Functions for Expression Handling
// ========================================

// UnmarshalExpression handles the custom unmarshaling for Expression union
// type. Numeric literals preserve the RFC §5.4.6 round-trip parse rule:
// a JSON-number token with '.', 'e', or 'E' parses to float64; otherwise to
// int64 (falling back to float64 if out of int64 range).
//
// EVERY expression-bearing field is normalized, not just `args`. The decoded
// node is routed through the shared field-preserving walker (mapExprChildren),
// so an operator node nested in a sidecar field — an aggregate's `expr` /
// `filter` / `key` / `join`, an integral's `lower` / `upper`, a table_lookup's
// `axes` / `output`, a makearray's `values` / `regions`, an
// apply_expression_template's `bindings` — arrives as a real ExprNode with its
// own children normalized in turn, exactly like a child of `args`. Before this,
// only `args` was normalized and every other field stayed a raw
// map[string]interface{}, which made those subtrees invisible to Substitute,
// FreeVariables, Canonicalize and the enum-lowering pass (audit G3, and the G15
// enum-lowering half of it).
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

	// Must be an object (ExprNode). Decode via UseNumber so nested literals
	// keep their int/float shape.
	var node ExprNode
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&node); err != nil {
		return nil, fmt.Errorf("expression must be number, string, or object: %w", err)
	}

	return normalizeExprNode(node)
}

// normalizeExprNode normalizes every expression-bearing child of a freshly
// decoded node through mapExprChildren, plus the `value` literal payload (which
// carries no child Expressions and so is deliberately outside the walker's
// remit, but still needs its json.Number leaves resolved to int64/float64 so
// the evaluator and the canonical emitter see real numbers).
func normalizeExprNode(node ExprNode) (ExprNode, error) {
	out, err := mapExprChildren(node, normalizeDecodedExpression)
	if err != nil {
		return out, err
	}
	if out.Value != nil {
		v, err := normalizeDecodedExpression(out.Value)
		if err != nil {
			return out, err
		}
		out.Value = v
	}
	return out, nil
}

// normalizeDecodedExpression is the TOTAL child function handed to
// mapExprChildren by normalizeExprNode. It resolves the raw shapes the JSON
// decoder produces — json.Number leaves, operator objects still spelled as
// map[string]interface{}, and nested []interface{} — into the normalized
// Expression union, and returns everything else (strings, bools, nil, already
// normalized nodes) unchanged, as the walker's totality contract requires.
//
// A map is treated as an operator node only when it carries a string "op" key
// (isOperatorMap). Any other object — an aggregate `ranges` bound pair, a
// non-operator structural payload — keeps its map shape, but its VALUES are
// still normalized so numeric leaves inside it are resolved too.
func normalizeDecodedExpression(child Expression) (Expression, error) {
	switch c := child.(type) {
	case json.Number:
		return normalizeJSONNumber(c), nil

	case map[string]any:
		if !isOperatorMap(c) {
			out := make(map[string]any, len(c))
			for k, v := range c {
				r, err := normalizeDecodedExpression(v)
				if err != nil {
					return nil, err
				}
				out[k] = r
			}
			return out, nil
		}
		b, err := json.Marshal(c)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal nested operator node for re-processing: %w", err)
		}
		node, err := UnmarshalExpression(b)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal nested expression: %w", err)
		}
		return node, nil

	case []any:
		out := make([]any, len(c))
		for i, v := range c {
			r, err := normalizeDecodedExpression(v)
			if err != nil {
				return nil, err
			}
			out[i] = r
		}
		return out, nil

	case ExprNode:
		return normalizeExprNode(c)

	case *ExprNode:
		if c == nil {
			return nil, nil
		}
		return normalizeExprNode(*c)

	default:
		return child, nil
	}
}

// isOperatorMap reports whether a raw decoded JSON object is an operator node —
// i.e. carries an "op" key whose value is a string. Every other object shape
// (bound pairs, structural payloads) is data, not an operator node.
func isOperatorMap(m map[string]any) bool {
	op, has := m["op"]
	if !has {
		return false
	}
	_, isStr := op.(string)
	return isStr
}

// rawIsPresent reports whether a json.RawMessage carries a real value rather
// than an absent (empty) or explicit-null field. It is the single guard the
// optional-Expression unmarshalers share, replacing the
// `len(raw) > 0 && string(raw) != "null"` predicate that was copied at every
// optional-RawMessage decode site.
func rawIsPresent(raw json.RawMessage) bool {
	return len(raw) > 0 && string(raw) != "null"
}

// unmarshalOptionalExpression decodes an optional Expression-valued field from
// its raw JSON. It returns (nil, nil) when the field is absent or explicitly
// null, and otherwise routes the bytes through UnmarshalExpression so numeric
// literals keep their RFC §5.4.6 int/float wire shape. Consolidates the guard +
// UnmarshalExpression pattern used for every optional Expression slot.
func unmarshalOptionalExpression(raw json.RawMessage) (Expression, error) {
	if !rawIsPresent(raw) {
		return nil, nil
	}
	return UnmarshalExpression(raw)
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
		Default          json.RawMessage `json:"default,omitempty"`
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
	mv.Description = temp.Description
	mv.Shape = temp.Shape
	mv.Location = temp.Location
	mv.NoiseKind = temp.NoiseKind
	mv.CorrelationGroup = temp.CorrelationGroup

	// Decode `default` through UnmarshalExpression so an integer-valued default
	// (`"default": 1`) keeps its int wire shape instead of collapsing to
	// float64 and re-emitting as "1.0", per RFC §5.4.1 int/float distinction.
	def, err := unmarshalOptionalExpression(temp.Default)
	if err != nil {
		return fmt.Errorf("failed to unmarshal default: %w", err)
	}
	mv.Default = def

	// Unmarshal Expression if present
	expr, err := unmarshalOptionalExpression(temp.Expression)
	if err != nil {
		return fmt.Errorf("failed to unmarshal expression: %w", err)
	}
	mv.Expression = expr

	return nil
}

// Custom JSON unmarshaling for Species. Decodes `default` through
// UnmarshalExpression so an integer-valued default keeps its int wire shape
// (RFC §5.4.1); a plain decode would coerce it to float64 and re-emit "1.0".
func (s *Species) UnmarshalJSON(data []byte) error {
	type TempSpecies struct {
		Units       *string         `json:"units,omitempty"`
		Default     json.RawMessage `json:"default,omitempty"`
		Description *string         `json:"description,omitempty"`
		Constant    *bool           `json:"constant,omitempty"`
	}
	var temp TempSpecies
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	s.Units = temp.Units
	s.Description = temp.Description
	s.Constant = temp.Constant
	def, err := unmarshalOptionalExpression(temp.Default)
	if err != nil {
		return fmt.Errorf("failed to unmarshal species default: %w", err)
	}
	s.Default = def
	return nil
}

// Custom JSON unmarshaling for Parameter. Decodes `default` through
// UnmarshalExpression so an integer-valued default keeps its int wire shape
// (RFC §5.4.1); a plain decode would coerce it to float64 and re-emit "1.0".
func (p *Parameter) UnmarshalJSON(data []byte) error {
	type TempParameter struct {
		Units       *string         `json:"units,omitempty"`
		Default     json.RawMessage `json:"default,omitempty"`
		Description *string         `json:"description,omitempty"`
	}
	var temp TempParameter
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	p.Units = temp.Units
	p.Description = temp.Description
	def, err := unmarshalOptionalExpression(temp.Default)
	if err != nil {
		return fmt.Errorf("failed to unmarshal parameter default: %w", err)
	}
	p.Default = def
	return nil
}

// Custom JSON unmarshaling for Model. Decodes `guesses` values through
// UnmarshalExpression so integer-valued initial guesses keep their int wire
// shape (RFC §5.4.1); every other field decodes exactly as its struct tags
// specify (via the alias type, which does not carry this method and so uses the
// default struct decoder). The embedded `Guesses` shadows the alias's field so
// the raw guess objects are captured here rather than decoded lossily.
func (m *Model) UnmarshalJSON(data []byte) error {
	type modelAlias Model
	aux := struct {
		*modelAlias
		Guesses map[string]json.RawMessage `json:"guesses,omitempty"`
	}{modelAlias: (*modelAlias)(m)}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	if len(aux.Guesses) > 0 {
		m.Guesses = make(map[string]any, len(aux.Guesses))
		for k, raw := range aux.Guesses {
			g, err := unmarshalOptionalExpression(raw)
			if err != nil {
				return fmt.Errorf("failed to unmarshal guess %q: %w", k, err)
			}
			m.Guesses[k] = g
		}
	} else {
		m.Guesses = nil
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
		FunctionalAffect   *FunctionalAffect     `json:"functional_affect,omitempty"`
		AffectNeg          []AffectEquation      `json:"affect_neg,omitempty"`
		DiscreteParameters []string              `json:"discrete_parameters,omitempty"`
		RootFind           *string               `json:"root_find,omitempty"`
		Reinitialize       *bool                 `json:"reinitialize,omitempty"`
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
	ec.FunctionalAffect = temp.FunctionalAffect
	ec.AffectNeg = temp.AffectNeg
	ec.DiscreteParameters = temp.DiscreteParameters
	ec.RootFind = temp.RootFind
	ec.Reinitialize = temp.Reinitialize
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
	conv, err := unmarshalOptionalExpression(temp.UnitConversion)
	if err != nil {
		return fmt.Errorf("failed to unmarshal unit_conversion: %w", err)
	}
	v.UnitConversion = conv
	return nil
}

// Custom JSON unmarshaling for VariableMapCoupling (handles the transform
// union: legacy string kind | ExpressionNode object). A string transform is
// stored as a string; an object transform is decoded via UnmarshalExpression
// into an ExprNode. Any other JSON shape (number, array, boolean) is rejected:
// an Expression transform is always an operator-node OBJECT (the degenerate
// bare-reference / literal spellings are reserved for the string kinds).
func (v *VariableMapCoupling) UnmarshalJSON(data []byte) error {
	type TempVariableMapCoupling struct {
		Type        string          `json:"type"`
		From        string          `json:"from"`
		To          string          `json:"to"`
		Transform   json.RawMessage `json:"transform"`
		Factor      *float64        `json:"factor,omitempty"`
		Lifting     *string         `json:"lifting,omitempty"`
		Description *string         `json:"description,omitempty"`
	}
	var temp TempVariableMapCoupling
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}
	v.Type = temp.Type
	v.From = temp.From
	v.To = temp.To
	v.Factor = temp.Factor
	v.Lifting = temp.Lifting
	v.Description = temp.Description
	v.Transform = nil
	if rawIsPresent(temp.Transform) {
		raw := bytes.TrimSpace(temp.Transform)
		switch {
		case len(raw) > 0 && raw[0] == '"':
			var kind string
			if err := json.Unmarshal(raw, &kind); err != nil {
				return fmt.Errorf("failed to unmarshal variable_map transform: %w", err)
			}
			v.Transform = kind
		case len(raw) > 0 && raw[0] == '{':
			expr, err := UnmarshalExpression(raw)
			if err != nil {
				return fmt.Errorf("failed to unmarshal variable_map transform expression: %w", err)
			}
			v.Transform = expr
		default:
			return fmt.Errorf("variable_map 'transform' must be a legacy string kind or an Expression operator-node object, got: %s", string(raw))
		}
	}
	// `factor` is a scaling slot for the scaling STRING transforms only; an
	// Expression transform computes its own value and admits no separate
	// scaling coefficient (esm-schema CouplingVariableMap.factor).
	if v.Factor != nil && v.TransformIsExpression() {
		return fmt.Errorf("variable_map: 'factor' is not permitted with an Expression 'transform' (factor only applies to the scaling string transforms)")
	}
	return nil
}

// Custom JSON unmarshaling for ESMFile
func (esm *ESMFile) UnmarshalJSON(data []byte) error {
	// Define a temporary struct that matches ESMFile but uses json.RawMessage for coupling
	type TempESMFile struct {
		ESM             string                    `json:"esm"`
		Metadata        Metadata                  `json:"metadata"`
		Models          map[string]Model          `json:"models,omitempty"`
		ReactionSystems map[string]ReactionSystem `json:"reaction_systems,omitempty"`
		DataLoaders     map[string]DataLoader     `json:"data_loaders,omitempty"`
		Enums           map[string]map[string]int `json:"enums,omitempty"`
		Coupling        json.RawMessage           `json:"coupling,omitempty"`
		CouplingRoles   map[string]CouplingRole   `json:"coupling_roles,omitempty"`
		Domain          *Domain                   `json:"domain,omitempty"`
		FunctionTables  map[string]FunctionTable  `json:"function_tables,omitempty"`
		IndexSets       map[string]IndexSet       `json:"index_sets,omitempty"`
	}

	var temp TempESMFile
	if err := json.Unmarshal(data, &temp); err != nil {
		return err
	}

	// Copy all fields except coupling
	esm.ESM = temp.ESM
	esm.Metadata = temp.Metadata
	esm.Models = temp.Models
	esm.ReactionSystems = temp.ReactionSystems
	esm.DataLoaders = temp.DataLoaders
	esm.Enums = temp.Enums
	esm.CouplingRoles = temp.CouplingRoles
	esm.Domain = temp.Domain
	esm.FunctionTables = temp.FunctionTables
	esm.IndexSets = temp.IndexSets

	// Handle coupling array with proper type deserialization
	if rawIsPresent(temp.Coupling) {
		couplingEntries, err := UnmarshalCouplingArray(temp.Coupling)
		if err != nil {
			return fmt.Errorf("failed to unmarshal coupling: %w", err)
		}
		esm.Coupling = couplingEntries
	}

	return nil
}

// UnmarshalCouplingArray handles the deserialization of the coupling array
func UnmarshalCouplingArray(data []byte) ([]CouplingEntry, error) {
	// First unmarshal as a slice of raw messages
	var rawEntries []json.RawMessage
	if err := json.Unmarshal(data, &rawEntries); err != nil {
		return nil, fmt.Errorf("failed to unmarshal coupling array: %w", err)
	}

	var result []CouplingEntry
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
	var typeMap map[string]any
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

	case "coupling_import":
		var coupling CouplingImport
		if err := json.Unmarshal(data, &coupling); err != nil {
			return nil, fmt.Errorf("failed to unmarshal CouplingImport: %w", err)
		}
		return coupling, nil

	default:
		return nil, fmt.Errorf("unknown coupling type: %s", typeStr)
	}
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
