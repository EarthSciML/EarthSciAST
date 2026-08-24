package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

// flatten.go implements esm-libraries-spec §4.7.5 — coupled-system flattening —
// and the CANONICAL `FlattenedSystem` field set step 4 fixes normatively.
//
// Two properties of that field set are load-bearing and easy to lose:
//
//   - DOCUMENT ORDER. Every ordered map and list below is in the order the file
//     declares it: components in file order, variables in declaration order
//     within a component, coupling-merged entries keeping their first-occurrence
//     position. Ordering is OBSERVABLE — a parameter vector is positional — so
//     sorting, or Go's randomized map iteration, is non-conforming. Go maps lose
//     declaration order at decode, which is why ESMFile carries `keyOrders` (the
//     authored JSON key order, recorded by LoadString) and why every iteration
//     here goes through orderedKeys.
//   - FULL METADATA, NOT NAMES. Each name → variable map carries the complete
//     declared variable (units, `default`, `shape`, `update`, `distribution`), so
//     a consumer can build a solver problem from the flattened form alone.
//
// The subsets do not partition the struct, they partition their parent map:
// `brownian_parameters` and `discrete_parameters` are SUBSETS of `parameters`
// (esm-spec §6.3.1 says the four parameter sets "partition the parameters", so
// removing a wiener-updated entry from `parameters` would make the parameter
// vector's LENGTH depend on whether the model is stochastic), and
// `algebraic_variables` is a SUBSET of `state_variables` (a DAE solves for its
// algebraic unknowns; a bucket disjoint from `state_variables` emits a `u`
// vector that silently omits them).
//
// The cross-language contract is tests/conformance/flatten/cases.json, generated
// from the Python oracle; flatten_conformance_test.go drives it.

// intExactCutoff is the magnitude below which every integer-valued float64 is
// representable exactly (2^52 < 1e15 < 2^53). Above it, consecutive integers are
// no longer all representable, so int64(v) could silently misround; such
// coefficients fall back to the general float rendering instead.
const intExactCutoff = 1e15

// formatStoich renders a stoichiometric coefficient using the shortest form
// that round-trips exactly through JSON: integer-valued coefficients emit
// without a decimal (e.g. "2"), fractional coefficients use the canonical
// minimal float representation (e.g. "0.87").
func formatStoich(v float64) string {
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return strconv.FormatFloat(v, 'g', -1, 64)
	}
	if v == math.Trunc(v) && math.Abs(v) < intExactCutoff {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

// ============================================================================
// Errors (esm-libraries-spec §4.7.6.10)
// ============================================================================

// ConflictingDerivativeError reports that two source systems define
// non-additive equations for the same dependent variable (esm-libraries-spec
// §4.7.5 step 4's over-determination check). Such a system is over-determined:
// one contribution to d[X]/dt would silently shadow the other.
type ConflictingDerivativeError struct{ Message string }

func (e *ConflictingDerivativeError) Error() string { return e.Message }

// CoupleMultiplicativeNoTendencyError reports that a `couple` connector equation
// applies the `multiplicative` transform to a target with no `D(to)` equation in
// the flattened system (esm-spec §10.3, esm-libraries-spec §4.7.2).
//
// Both sections define `multiplicative` against the target's EXISTING ODE
// right-hand side. When `to` names a parameter, an observed, an algebraic
// unknown, or a name nothing defines, there is no tendency to multiply and the
// operation has no meaning — so the entry is rejected rather than dropped.
//
// `additive` has no counterpart error: zero is the additive identity, so an
// additive term against an absent tendency simply becomes the tendency.
type CoupleMultiplicativeNoTendencyError struct {
	// Target is the connector equation's `to` scoped reference.
	Target  string
	Message string
}

func (e *CoupleMultiplicativeNoTendencyError) Error() string {
	return fmt.Sprintf("[%s] %s", CodeCoupleMultiplicativeNoTendency, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *CoupleMultiplicativeNoTendencyError) DiagnosticCode() string {
	return CodeCoupleMultiplicativeNoTendency
}

// DimensionPromotionError reports that a variable or equation cannot be
// promoted onto the target grid (esm-libraries-spec §4.7.6): here, that the
// pointwise spatial lift (esm-spec §10.5) could not read the spatial loop
// variables off a species' operator makearray.
type DimensionPromotionError struct{ Message string }

func (e *DimensionPromotionError) Error() string { return e.Message }

// ============================================================================
// The canonical FlattenedSystem field set (esm-libraries-spec §4.7.5 step 4)
// ============================================================================

// FlattenedVariable is one variable of the flattened system, carrying the FULL
// declared metadata step 4 requires ("Full metadata, not names"): a consumer
// must be able to build a solver problem from the flattened form alone, without
// re-reading the source document.
type FlattenedVariable struct {
	// Name is the dot-namespaced name ("OU.theta").
	Name string
	// Role is the DERIVED role (esm-spec §6.3.1), never a declared type:
	// "state" (an unknown the solver advances or solves for), "observed" (an
	// unknown a bare-variable-LHS equation defines, eliminable by inlining),
	// "parameter", or "species" (a reaction-system state).
	Role string
	// SourceSystem is the component the variable came from.
	SourceSystem string
	Units        *string
	Default      any
	Description  *string
	// Shape lists the index-set names an arrayed variable is shaped over; nil
	// for a scalar.
	Shape []string
	// Update carries the declared cadence machinery verbatim (one
	// ParameterUpdate or an ordered []ParameterUpdate); read it through
	// UpdateRules.
	Update       any
	Distribution *Distribution
}

// UpdateRules returns the variable's update rules in declaration order,
// flattening both spellings of the ParameterUpdateSpec union (esm-spec §5.4).
func (fv FlattenedVariable) UpdateRules() []ParameterUpdate {
	return ModelVariable{Update: fv.Update}.UpdateRules()
}

// DeclaredType is the two-type esm 1.0.0 declaration ("unknown" / "parameter")
// the variable's derived Role was computed from. It is what a caller that used
// to read `FlattenedSystem.Variables[name]` wants.
func (fv FlattenedVariable) DeclaredType() string {
	if fv.Role == "parameter" {
		return VarTypeParameter
	}
	return VarTypeUnknown
}

// LoaderField is a data-fed PARAMETER lowered to a flattened array input
// (esm-spec §8.5). From 1.0.0 a data source is not a component: a model
// consumes a source by declaring a parameter whose `update` is
// `{kind: "data", source: <key>, from: {file_variable}}` — the parameter IS the
// loaded field. Flatten records this descriptor per such parameter so a
// simulator can execute the source at its cadence and bind the resulting array
// into the RHS as a read-only input, keyed by the parameter's namespaced name.
type LoaderField struct {
	// Name is the namespaced parameter symbol ("Advection.u_wind").
	Name string
	// Owner is the owning component's namespaced prefix ("Advection").
	Owner string
	// Source is the `data_sources` key the parameter's update names.
	Source string
	// FileVariable is the source-file variable the binding names.
	FileVariable string
	// Cadence follows the SOURCE, not the parameter (CONFORMANCE_SPEC §5.7.2):
	// a source WITH a `temporal` block is time-varying → "discrete"; one
	// without is read once → "const".
	Cadence string
	// DataSource is the resolved `data_sources` entry.
	DataSource DataSource
	// UnitConversion is the binding's declared `unit_conversion` (§8.5), or nil.
	UnitConversion Expression
}

// FieldIC is one deferred `ic` equation (esm-spec §11.4.1) as a
// (state, expression) pair. An initial condition is a DATUM, not an equation of
// motion, so these are classified OUT of FlattenedSystem.Equations and reported
// only here (esm-libraries-spec §4.7.5 step 4).
type FieldIC struct {
	State string
	Expr  Expression
}

// FlattenedIndexSet is one entry of the flattened system's document-scoped
// index-set registry, in document order.
type FlattenedIndexSet struct {
	Name string
	Set  IndexSet
}

// FlattenedFunctionTable is one entry of the flattened system's merged
// function-table registry (esm-spec §9.5), in document order.
type FlattenedFunctionTable struct {
	Name  string
	Table FunctionTable
}

// FlattenedTemplate is one entry of the MERGED expression-template registry
// (esm-spec §9.6.4 rule 7, §10.7). Declaration is the raw template declaration
// (`params` + `body`, and any sidecar the document carried).
type FlattenedTemplate struct {
	Name        string
	Declaration any
}

// LiftedShape is the concrete integer grid shape the pointwise spatial lift
// (esm-spec §10.5) assigned to one lifted state variable.
type LiftedShape struct {
	Name  string
	Shape []int
}

// FlattenedEquation is a single equation of the flattened system, with
// dot-namespaced Expression TREES on both sides.
//
// LHS/RHS were strings rendered by a flatten-local pretty printer, which made
// every downstream pass re-parse text and made Go's equation rendering
// disagree with the shared display corpus. They are trees now; render them with
// ToAscii / ToUnicode / ToLatex, which is what the cross-language fixtures pin.
type FlattenedEquation struct {
	LHS          Expression
	RHS          Expression
	SourceSystem string // which system this equation came from
}

// LHSString renders the equation's left-hand side with the shared ASCII
// renderer (the one tests/display and tests/conformance/flatten pin).
func (e FlattenedEquation) LHSString() string { return ToAscii(e.LHS) }

// RHSString renders the equation's right-hand side with the shared ASCII
// renderer.
func (e FlattenedEquation) RHSString() string { return ToAscii(e.RHS) }

// FlattenMetadata records provenance information about the flattening operation.
type FlattenMetadata struct {
	SourceSystems []string // names of systems that were flattened
	CouplingRules []string // descriptions of coupling rules applied
	// OperatorApplies are the `operator_apply` coupling entries, recorded as
	// opaque runtime references (§4.7.5 step 3).
	OperatorApplies []string
	// Callbacks are the `callback` coupling entries, likewise.
	Callbacks []string
}

// FlattenedSystem is a coupled system flattened into a single system — the
// canonical intermediate form between an ESMFile and any downstream consumer,
// and the API boundary all of graph construction, validation and simulation
// export operate on.
//
// Field-by-field this is esm-libraries-spec §4.7.5 step 4's normative table,
// transliterated per API_SPEC.md §2. Each `name → variable` ordered map is
// spelled as a SLICE of FlattenedVariable: a Go map has no order, and order is
// part of the contract, so the slice IS the ordered map and Lookup gives the
// by-name access. See the file header for the ordering and subset rules.
type FlattenedSystem struct {
	// IndependentVariables is ["t"] for a discretized system; an undiscretized
	// spatial differential adds the axes it names.
	IndependentVariables []string
	// StateVariables is the SOLVED-FOR VECTOR: every unknown the solver
	// advances or solves for — differential unknowns (including every reaction
	// species, which gets a derived D equation), PLUS AlgebraicVariables, PLUS
	// any arrayed observed that materializes into a buffer. NOT the same set as
	// esm-spec §6.3.1's ode_states.
	StateVariables []FlattenedVariable
	// Parameters is ALL parameters of every cadence, minus any promoted to
	// variables by `variable_map`.
	Parameters []FlattenedVariable
	// ObservedVariables are the unknowns a bare-variable-LHS equation DEFINES —
	// eliminated by substitution into their consumers, so NOT in StateVariables.
	ObservedVariables []FlattenedVariable
	// AlgebraicVariables are the unknowns constrained only by an expression-LHS
	// equation. A SUBSET of StateVariables.
	AlgebraicVariables []FlattenedVariable
	// BrownianParameters are the parameters whose `update.kind` is "wiener" —
	// the SDE noise sources. A SUBSET of Parameters, not a sibling bucket:
	// SystemKind tests this bucket FIRST, so dropping it forfeits "sde".
	BrownianParameters []FlattenedVariable
	// DiscreteParameters are the parameters carrying any other `update`. A
	// SUBSET of Parameters.
	DiscreteParameters []FlattenedVariable
	// Equations are the governing equations — dynamics and constraints — with
	// coupling applied and variables dot-namespaced. Entries classified out into
	// FieldICs are REMOVED from this list.
	Equations []FlattenedEquation
	// ContinuousEvents / DiscreteEvents are the components' events,
	// dot-namespaced. They were one untyped `Events []any` bucket, which no
	// other binding has and which no consumer could dispatch on without a type
	// switch.
	ContinuousEvents []ContinuousEvent
	DiscreteEvents   []DiscreteEvent
	// Domain is the file's `domain` section, unchanged.
	Domain *Domain
	// Metadata records which components were flattened and which coupling rules
	// applied.
	Metadata FlattenMetadata
	// IndexSets is the document-scoped index-set registry, required to interpret
	// arrayed equations.
	IndexSets []FlattenedIndexSet
	// FunctionTables is the merged function-table registry; it resolves a
	// surviving `table_lookup`.
	FunctionTables []FlattenedFunctionTable
	// TemplateRegistry is the merged expression-template registry (esm-spec
	// §9.6.4 rule 7, §10.7).
	TemplateRegistry []FlattenedTemplate
	// FieldICs are the deferred scoped-reference / array `ic` equations
	// (esm-spec §11.4.1), removed from Equations.
	FieldICs []FieldIC
	// LoaderFields are the provider-served loaded fields the system consumes.
	LoaderFields []LoaderField
	// LiftedShapes are the post-lift grid shapes for arrayed states.
	LiftedShapes []LiftedShape
}

// Lookup returns the flattened variable with the given namespaced name,
// searching the state, parameter and observed maps in that order. It is the
// by-name half of the ordered maps the slices above spell.
func (f *FlattenedSystem) Lookup(name string) (FlattenedVariable, bool) {
	if f == nil {
		return FlattenedVariable{}, false
	}
	for _, table := range [][]FlattenedVariable{f.StateVariables, f.Parameters, f.ObservedVariables} {
		for _, v := range table {
			if v.Name == name {
				return v, true
			}
		}
	}
	return FlattenedVariable{}, false
}

// DeclaredTypes maps every flattened variable's namespaced name to its DECLARED
// esm 1.0.0 type ("unknown" / "parameter").
//
// This replaces the old `Variables map[string]string` field, which held exactly
// this and nothing else. It is a derived VIEW, not a field, because the canonical
// field set has no room for a second, unordered, less informative copy of the
// three variable maps — every caller of the old field gets the same answer here,
// and a caller that wants the derived role or the metadata reads the maps.
func (f *FlattenedSystem) DeclaredTypes() map[string]string {
	out := map[string]string{}
	if f == nil {
		return out
	}
	for _, table := range [][]FlattenedVariable{f.StateVariables, f.Parameters, f.ObservedVariables} {
		for _, v := range table {
			if _, seen := out[v.Name]; !seen {
				out[v.Name] = v.DeclaredType()
			}
		}
	}
	return out
}

// InitialValues maps each state variable to its initial value: the declared
// scalar `default`, or 0.0 when it declares none.
//
// This replaces the old `InitialValues map[string]float64` field. The field
// carried reaction-system species only; every state variable now carries its
// own `default` (of any type) in the ordered maps, so the field was a lossy
// projection of information the canonical shape already holds — but the numeric
// coercion it did is genuinely useful, so it survives as this method, widened to
// every state.
func (f *FlattenedSystem) InitialValues() map[string]float64 {
	out := map[string]float64{}
	if f == nil {
		return out
	}
	for _, v := range f.StateVariables {
		out[v.Name] = numericDefault(v.Default)
	}
	return out
}

// SystemKind is the flattened system's derived MTK system kind (esm-spec
// §6.3.1): "sde" / "pde" / "nonlinear" / "ode", tested in that order.
//
// It is available on the flattened form precisely because BrownianParameters
// survives flattening — the derivation's first row is "any parameter in
// brownian_parameters", so a FlattenedSystem that dropped the bucket could not
// report "sde" and a consumer would integrate a stochastic system as a
// deterministic one.
func (f *FlattenedSystem) SystemKind() string {
	if f == nil {
		return SystemKindODE
	}
	model := f.classificationView()
	return SystemKind(&model, f.Domain)
}

// numericDefault coerces a declared `default` to a float64 initial value, or
// 0.0 when it is absent or not numeric. The parser decodes JSON numbers with
// UseNumber inside Expression slots, so json.Number is handled alongside the
// float64/int forms produced when structs are built directly in code.
func numericDefault(v any) float64 {
	switch d := v.(type) {
	case nil:
		return 0.0
	case float64:
		return d
	case float32:
		return float64(d)
	case int:
		return float64(d)
	case int64:
		return float64(d)
	case json.Number:
		if f, err := d.Float64(); err == nil {
			return f
		}
	case string:
		if f, err := strconv.ParseFloat(d, 64); err == nil {
			return f
		}
	}
	return 0.0
}

// ============================================================================
// Internal ordered variable table
// ============================================================================

// varTable is an insertion-ordered name → FlattenedVariable map. Go has no
// ordered map and document order is normative (see the file header), so every
// per-component and whole-system variable bag is one of these.
type varTable struct {
	keys []string
	m    map[string]FlattenedVariable
}

func newVarTable() *varTable {
	return &varTable{m: map[string]FlattenedVariable{}}
}

// set inserts or REPLACES v under its name, keeping an existing name's
// position (last-writer-wins on the value, first-occurrence on the position).
func (t *varTable) set(v FlattenedVariable) {
	if _, ok := t.m[v.Name]; !ok {
		t.keys = append(t.keys, v.Name)
	}
	t.m[v.Name] = v
}

func (t *varTable) has(name string) bool { _, ok := t.m[name]; return ok }

func (t *varTable) get(name string) (FlattenedVariable, bool) {
	v, ok := t.m[name]
	return v, ok
}

// remove deletes a name, closing the gap in the order.
func (t *varTable) remove(name string) (FlattenedVariable, bool) {
	v, ok := t.m[name]
	if !ok {
		return FlattenedVariable{}, false
	}
	delete(t.m, name)
	for i, k := range t.keys {
		if k == name {
			t.keys = append(t.keys[:i], t.keys[i+1:]...)
			break
		}
	}
	return v, true
}

// update folds other into t with varTable.set's semantics.
func (t *varTable) update(other *varTable) {
	for _, k := range other.keys {
		t.set(other.m[k])
	}
}

// slice materializes the table as the ordered slice a FlattenedSystem field is.
func (t *varTable) slice() []FlattenedVariable {
	out := make([]FlattenedVariable, 0, len(t.keys))
	for _, k := range t.keys {
		out = append(out, t.m[k])
	}
	return out
}

// selectOrdered picks `names` out of the given tables, keeping each table's
// order. The §6.3.1 accessors return SORTED name lists (a set-valued answer
// spelled as a list); membership comes from them and POSITION comes from the
// already-document-ordered table being filtered. Sorting here instead would be
// observable — a parameter vector is positional.
func selectOrdered(names map[string]bool, tables ...[]FlattenedVariable) []FlattenedVariable {
	out := []FlattenedVariable{}
	seen := map[string]bool{}
	for _, table := range tables {
		for _, v := range table {
			if names[v.Name] && !seen[v.Name] {
				seen[v.Name] = true
				out = append(out, v)
			}
		}
	}
	return out
}

// ============================================================================
// Expression helpers
// ============================================================================

// mapExprRefChildren rebuilds node with f applied to every REFERENCE-BEARING
// child (the exprRefChildren set: args, lower, upper, expr, filter, key, values,
// axes, bindings), leaving the slots exprRefNonRefSlots names — attrs, output,
// ranges, join, regions — exactly as authored.
//
// A namespacing or substitution walk must not descend into those: `attrs` holds
// a scheme NAME, `output` a table's declared output name, `ranges`/`regions`
// load-time index bounds, and a `join` clause is an untyped map whose plain
// strings are handled by the dedicated, declared-local-gated namespaceJoinNames.
// Prefixing any of them rewrites a name that resolves in a different namespace.
func mapExprRefChildren(node ExprNode, f func(Expression) (Expression, error)) (ExprNode, error) {
	out, err := mapExprChildren(node, f)
	if err != nil {
		return out, err
	}
	out.Attrs = node.Attrs
	out.Output = node.Output
	out.Ranges = node.Ranges
	out.Join = node.Join
	out.Regions = node.Regions
	return out, nil
}

// walkExprNodes calls f on every operator node reachable from expr, pre-order,
// over the reference-bearing child set.
func walkExprNodes(expr Expression, f func(ExprNode)) {
	node, ok := asExprNode(expr)
	if !ok {
		return
	}
	f(node)
	for _, child := range exprRefChildren(node) {
		walkExprNodes(child.Child, f)
	}
}

// exprHasVarPlaceholder reports whether expr mentions the `_var` operator-model
// placeholder (esm-spec §6.4) anywhere.
func exprHasVarPlaceholder(expr Expression) bool {
	if s, ok := expr.(string); ok {
		return s == operatorPlaceholderVar
	}
	node, ok := asExprNode(expr)
	if !ok {
		return false
	}
	for _, child := range exprRefChildren(node) {
		if exprHasVarPlaceholder(child.Child) {
			return true
		}
	}
	return false
}

// namespaceExprTree returns expr with every variable reference prefixed by
// `prefix.` — the port of the reference implementations' `_namespace_expr`.
//
// A bare reference (no dot) is prefixed. A dotted reference is left alone
// (already fully namespaced), EXCEPT when its head segment names one of
// `subsystemKeys` — a subsystem mounted on the component being namespaced — in
// which case the reference is subsystem-LOCAL (`raw.fuel_model`) and must be
// qualified with the owner (`LANDFIRE.raw.fuel_model`) to match the lowered
// subsystem variable name. `leaveAlone` holds the names that are not variable
// references at all: the independent variable `t`, the `_var` placeholder, and —
// added per node — an `aggregate`'s own loop symbols, which are local to its
// body (esm-spec §4.3.1).
//
// `locals` is the component's own declared names, and gates ONLY the plain-string
// references a `join` clause carries (CONFORMANCE_SPEC §5.5.6) — see
// namespaceJoinNames.
func namespaceExprTree(expr Expression, prefix string, leaveAlone, subsystemKeys, locals map[string]bool) Expression {
	if s, ok := expr.(string); ok {
		if leaveAlone[s] {
			return s
		}
		if head, _, found := strings.Cut(s, "."); found {
			if !leaveAlone[head] && subsystemKeys[head] {
				return prefix + "." + s // subsystem-local reference -> qualify
			}
			return s // already fully namespaced -> leave alone
		}
		return prefix + "." + s
	}
	node, ok := asExprNode(expr)
	if !ok {
		return expr
	}

	// An aggregate's index symbols are local to its body and must not be
	// namespaced. They are binder NAMES, not child expressions, so the only
	// handling needed is adding them to `leaveAlone` for the children.
	localLeave := leaveAlone
	if node.Op == "aggregate" {
		localLeave = make(map[string]bool, len(leaveAlone)+len(node.OutputIdx)+len(node.Ranges))
		for k, v := range leaveAlone {
			localLeave[k] = v
		}
		for _, s := range node.OutputIdx {
			if name, ok := s.(string); ok {
				localLeave[name] = true
			}
		}
		for name := range node.Ranges {
			localLeave[name] = true
		}
	}

	out, _ := mapExprRefChildren(node, func(child Expression) (Expression, error) {
		return namespaceExprTree(child, prefix, localLeave, subsystemKeys, locals), nil
	})
	if len(out.Join) > 0 && len(locals) > 0 {
		// THIS node's own loop symbols, not localLeave (which also holds
		// enclosing nodes'). A join column resolves against this node's
		// `ranges`, so its own binders are the exact shadowing set.
		binders := make(map[string]bool, len(out.OutputIdx)+len(out.Ranges))
		for _, s := range out.OutputIdx {
			if name, ok := s.(string); ok {
				binders[name] = true
			}
		}
		for name := range out.Ranges {
			binders[name] = true
		}
		out.Join = namespaceJoinNames(out.Join, binders, prefix, locals)
	}
	return out
}

// namespaceJoinNames dot-prefixes the plain-string variable references a `join`
// clause carries: an `on` key column, and an `overlap` clause's `src_env` /
// `tgt_env` envelope factors (CONFORMANCE_SPEC §5.5.6).
//
// Those are references, not opaque metadata — the engines that materialise a
// join resolve each name against the VARIABLE REGISTRY, which after flattening
// is the namespaced one. They are only encoded as strings rather than as child
// expressions. The gate is `locals`, the component's own declared names: a key
// column naming a document-scoped index set is not a declared variable of this
// component and is left alone. Mirrors Julia `_namespace_join`, Rust
// `namespace_join_names`, and Python `_namespace_join`.
//
// `binders` — the loop symbols the node binds (`output_idx` entries, `ranges`
// keys) — WINS over `locals`. An index symbol is local to the enclosing
// `aggregate` and shadows any coincident variable name (esm-spec §4.3.1), and an
// `on` key column is resolved against this node's own ranges, so prefixing a
// shadowed symbol makes it resolve to nothing.
func namespaceJoinNames(join []any, binders map[string]bool, prefix string, locals map[string]bool) []any {
	ns := func(v any) any {
		s, ok := v.(string)
		if !ok {
			return v
		}
		if binders[s] {
			return s
		}
		if head, _, found := strings.Cut(s, "."); found {
			if locals[head] {
				return prefix + "." + s
			}
			return s
		}
		if locals[s] {
			return prefix + "." + s
		}
		return s
	}
	nsList := func(v any) any {
		items, ok := v.([]any)
		if !ok {
			return v
		}
		out := make([]any, len(items))
		for i, it := range items {
			out[i] = ns(it)
		}
		return out
	}

	out := make([]any, len(join))
	for i, raw := range join {
		clause, ok := raw.(map[string]any)
		if !ok {
			out[i] = raw
			continue
		}
		next := make(map[string]any, len(clause))
		for k, v := range clause {
			next[k] = v
		}
		if pairs, ok := clause["on"].([]any); ok {
			renamed := make([]any, len(pairs))
			for j, pair := range pairs {
				renamed[j] = nsList(pair)
			}
			next["on"] = renamed
		}
		if overlap, ok := clause["overlap"].(map[string]any); ok {
			nextOverlap := make(map[string]any, len(overlap))
			for k, v := range overlap {
				nextOverlap[k] = v
			}
			for _, side := range []string{"src_env", "tgt_env"} {
				if _, present := overlap[side]; present {
					nextOverlap[side] = nsList(overlap[side])
				}
			}
			next["overlap"] = nextOverlap
		}
		out[i] = next
	}
	return out
}

// lhsDependentVar returns the dependent variable an equation LHS names:
// `D(v, t)` and `D(index(v, …), t)` yield v, a bare name yields itself, and an
// `aggregate` yields its body's. An expression LHS (an algebraic constraint)
// names no single variable and yields "".
func lhsDependentVar(lhs Expression) string {
	if s, ok := lhs.(string); ok {
		return s
	}
	node, ok := asExprNode(lhs)
	if !ok {
		return ""
	}
	if node.Op == OpDerivative && len(node.Args) > 0 {
		inner := node.Args[0]
		if s, ok := inner.(string); ok {
			return s
		}
		if in, ok := asExprNode(inner); ok {
			if in.Op == OpDerivative && len(in.Args) > 0 {
				return lhsDependentVar(in)
			}
			if in.Op == "index" && len(in.Args) > 0 {
				if s, ok := in.Args[0].(string); ok {
					return s
				}
			}
		}
		return ""
	}
	if node.Op == "aggregate" && node.Expr != nil {
		return lhsDependentVar(node.Expr)
	}
	return ""
}

// exprHasArrayOp reports whether expr contains any array op node.
func exprHasArrayOp(expr Expression) bool {
	found := false
	walkExprNodes(expr, func(n ExprNode) {
		if _, ok := arrayOps[n.Op]; ok {
			found = true
		}
	})
	return found
}

// arrayOps is the canonical array-op set: the `array` and `geometry` categories
// of the esm-spec §4.2 op registry, the same membership the other bindings spell
// as ARRAY_OPS. An equation carrying one of these may legitimately define a
// different index subset of a state variable another equation also defines, so
// assembleSystem exempts it from the scalar duplicate-LHS check.
var arrayOps = map[string]struct{}{
	"aggregate": {}, "broadcast": {}, "concat": {}, "index": {}, "makearray": {},
	"reshape": {}, "transpose": {},
	"intersect_polygon": {}, "polygon_intersection_area": {},
}

// spatialDimsInExpr returns the spatial dimension labels named by an
// UNDISCRETIZED spatial differential in expr.
//
// Harvested STRUCTURALLY from every node's `dim` axis field (esm-spec §4.9.1),
// NOT from a list of op names: the open-tier sugar ops grad/div/laplacian/curl
// carry no spatial-detection privilege, and only an undiscretized differential
// node carries a `dim`. A discretized system has folded its spatial axes into
// array dimensions and yields the empty set, staying a pure ODE.
func spatialDimsInExpr(expr Expression, out map[string]bool) {
	walkExprNodes(expr, func(n ExprNode) {
		if n.Dim != nil && *n.Dim != "" {
			out[*n.Dim] = true
		}
	})
}

// addExprs sums two expressions, normalizing the trivial zero cases.
func addExprs(left, right Expression) Expression {
	if isNumericZero(left) {
		return right
	}
	if isNumericZero(right) {
		return left
	}
	return ExprNode{Op: "+", Args: []any{left, right}}
}

// multiplyExprs multiplies two expressions, normalizing the trivial 0/1 cases.
func multiplyExprs(left, right Expression) Expression {
	if isNumericOne(left) {
		return right
	}
	if isNumericOne(right) {
		return left
	}
	if isNumericZero(left) || isNumericZero(right) {
		return 0
	}
	return ExprNode{Op: "*", Args: []any{left, right}}
}

func exprNumber(e Expression) (float64, bool) {
	switch v := e.(type) {
	case int:
		return float64(v), true
	case int32:
		return float64(v), true
	case int64:
		return float64(v), true
	case float32:
		return float64(v), true
	case float64:
		return v, true
	case json.Number:
		f, err := v.Float64()
		return f, err == nil
	}
	return 0, false
}

func isNumericZero(e Expression) bool { v, ok := exprNumber(e); return ok && v == 0 }
func isNumericOne(e Expression) bool  { v, ok := exprNumber(e); return ok && v == 1 }

// substituteExpr is Substitute with the error dropped: single-pass substitution
// over a decoded expression has no failure mode of its own.
func substituteExpr(expr Expression, bindings map[string]Expression) Expression {
	out, err := Substitute(expr, bindings)
	if err != nil {
		return expr
	}
	return out
}

// ============================================================================
// Coupling-rule descriptions
// ============================================================================

// describeCoupling is the metadata line one coupling entry contributes. The
// spellings are the cross-binding ones the flatten corpus pins.
func describeCoupling(entry CouplingEntry, file *ESMFile, index int) string {
	switch c := entry.(type) {
	case OperatorComposeCoupling:
		rule := fmt.Sprintf("operator_compose(%s)", strings.Join(c.Systems[:], " + "))
		if len(c.Translate) > 0 {
			parts := make([]string, 0, len(c.Translate))
			for _, k := range orderedKeys(c.Translate, file.declarationOrder(fmt.Sprintf("/coupling/%d/translate", index))) {
				parts = append(parts, fmt.Sprintf("%s->%v", k, c.Translate[k]))
			}
			rule += " [translate: " + strings.Join(parts, ", ") + "]"
		}
		return rule
	case CouplingCouple:
		return fmt.Sprintf("couple(%s)", strings.Join(c.Systems[:], " <-> "))
	case VariableMapCoupling:
		transform := c.TransformKind()
		if c.TransformIsExpression() {
			transform = "expression"
		}
		rule := fmt.Sprintf("variable_map(%s -> %s, transform=%s)", c.From, c.To, transform)
		if c.Factor != nil {
			rule += fmt.Sprintf(" [factor=%s]", formatFactor(*c.Factor))
		}
		return rule
	case OperatorApplyCoupling:
		return fmt.Sprintf("operator_apply(%s)", c.Operator)
	case CallbackCoupling:
		return fmt.Sprintf("callback(%s)", c.CallbackID)
	default:
		return fmt.Sprintf("unknown(%T)", entry)
	}
}

// formatFactor renders a coupling `factor` for the metadata line. An
// integer-valued factor keeps a trailing ".0": the factor is declared as a
// NUMBER, and the metadata strings are a cross-binding surface, so 2.0 must not
// read as 2 in one binding and 2.0 in another.
func formatFactor(v float64) string {
	s := strconv.FormatFloat(v, 'g', -1, 64)
	if !strings.ContainsAny(s, ".eEn") { // "n" catches NaN / Inf spellings
		s += ".0"
	}
	return s
}

// ============================================================================
// Per-component collection
// ============================================================================

// componentSystem is one system's bag of variables and already-namespaced
// equations, before merging.
type componentSystem struct {
	name         string
	stateVars    *varTable
	parameters   *varTable
	observed     *varTable
	equations    []FlattenedEquation
	loaderFields []LoaderField
}

func newComponentSystem(name string) *componentSystem {
	return &componentSystem{
		name:       name,
		stateVars:  newVarTable(),
		parameters: newVarTable(),
		observed:   newVarTable(),
	}
}

// merge folds other's tables into c (last-writer-wins for the variable tables,
// order-preserving append for equations and loader fields). The single place
// the five per-component tables are combined — used to pull a subsystem into
// its parent and, in assembleSystem, to fold every component into one bag.
func (c *componentSystem) merge(other *componentSystem) {
	c.stateVars.update(other.stateVars)
	c.parameters.update(other.parameters)
	c.observed.update(other.observed)
	c.equations = append(c.equations, other.equations...)
	c.loaderFields = append(c.loaderFields, other.loaderFields...)
}

// namespaceEquations namespaces both sides of each equation and appends it to
// the component.
func (c *componentSystem) namespaceEquations(equations []Equation, prefix string, leaveAlone, subsystemKeys, locals map[string]bool) {
	for _, eq := range equations {
		c.equations = append(c.equations, FlattenedEquation{
			LHS:          namespaceExprTree(eq.LHS, prefix, leaveAlone, subsystemKeys, locals),
			RHS:          namespaceExprTree(eq.RHS, prefix, leaveAlone, subsystemKeys, locals),
			SourceSystem: prefix,
		})
	}
}

// placeholderLeaveAlone is the set of names that are never variable references:
// the independent variable and the operator-model placeholder.
func placeholderLeaveAlone() map[string]bool {
	return map[string]bool{DefaultIndepVar: true, operatorPlaceholderVar: true}
}

// dataSourceFields returns every data-fed parameter of the model as a
// LoaderField (esm-spec §8.5). A parameter whose `update` is `kind: "data"`
// reads one `file_variable` of the named document-scoped source; its cadence
// follows the SOURCE, not its own declaration (CONFORMANCE_SPEC §5.7.2). An
// unresolvable source is skipped — `data_source_undefined` is the validator's
// finding, not flatten's.
func dataSourceFields(model *Model, fullPrefix string, varOrder []string, sources map[string]DataSource) []LoaderField {
	var out []LoaderField
	for _, varName := range varOrder {
		v := model.Variables[varName]
		if v.Type != VarTypeParameter {
			continue
		}
		for _, rule := range v.UpdateRules() {
			if rule.Kind != UpdateKindData || rule.From == nil {
				continue
			}
			source, ok := sources[rule.Source]
			if !ok {
				continue
			}
			cadence := CadenceConst
			if source.IsTimeVarying() {
				cadence = CadenceDiscrete
			}
			out = append(out, LoaderField{
				Name:           fullPrefix + "." + varName,
				Owner:          fullPrefix,
				Source:         rule.Source,
				FileVariable:   rule.From.FileVariable,
				Cadence:        cadence.String(),
				DataSource:     source,
				UnitConversion: rule.From.UnitConversion,
			})
		}
	}
	return out
}

// collectModel collects a Model (recursively, including subsystems) into a
// componentSystem.
//
// A variable's role comes from the §6.3.1 classification, NOT from a declared
// type. "observed" is the INLINED form specifically — an unknown a bare-variable
// LHS defines, which is substituted into its consumers. Every other unknown is
// SOLVED FOR and lands in the state table: an ODE state, an algebraic unknown,
// and an ARRAYED definition (`y[i] ~ f(i)`) alike. The arrayed one is observed by
// §6.3.1 and its cadence resolves through its RHS, but it materializes into a
// buffer its consumers index rather than being inlined.
func collectModel(file *ESMFile, model *Model, fullPrefix, docPath string, sources map[string]DataSource) (*componentSystem, error) {
	component := newComponentSystem(fullPrefix)
	inlined := inlinedUnknownSet(model)

	varOrder := orderedKeys(model.Variables, file.declarationOrder(docPath+"/variables"))
	for _, varName := range varOrder {
		v := model.Variables[varName]
		namespaced := fullPrefix + "." + varName
		var role string
		switch {
		case v.Type == VarTypeParameter:
			role = "parameter"
		case v.Type != VarTypeUnknown:
			// Fail closed on a retired 0.x type rather than silently filing it
			// with the unknowns: `state` / `observed` / `brownian` / `discrete`
			// are gone (esm-spec §6.3), and a document still carrying one is a
			// document this binding must not pretend to understand.
			return nil, fmt.Errorf(
				"flatten: variable '%s' declares type '%s', which esm 1.0.0 removed; the declared types are 'unknown' and 'parameter' (esm-spec §6.3)",
				namespaced, v.Type)
		case inlined[varName]:
			role = "observed"
		default:
			role = "state"
		}
		flatVar := FlattenedVariable{
			Name:         namespaced,
			Role:         role,
			SourceSystem: fullPrefix,
			Units:        v.Units,
			Default:      v.Default,
			Description:  v.Description,
			Shape:        append([]string(nil), v.Dims()...),
			Update:       v.Update,
			Distribution: v.Distribution,
		}
		if len(flatVar.Shape) == 0 {
			flatVar.Shape = nil
		}
		switch role {
		case "state":
			component.stateVars.set(flatVar)
		case "parameter":
			component.parameters.set(flatVar)
		default:
			component.observed.set(flatVar)
		}
	}

	// Subsystem keys mounted on this model: references rooted at one of these
	// are subsystem-LOCAL and must be qualified with the model prefix.
	subKeys := map[string]bool{}
	for k := range model.Subsystems {
		subKeys[k] = true
	}
	// The component's own declared names — the gate for namespacing the
	// plain-string references a `join` clause carries (§5.5.6).
	locals := map[string]bool{}
	for k := range model.Variables {
		locals[k] = true
	}
	for k := range subKeys {
		locals[k] = true
	}

	component.namespaceEquations(model.Equations, fullPrefix, placeholderLeaveAlone(), subKeys, locals)
	component.loaderFields = append(component.loaderFields,
		dataSourceFields(model, fullPrefix, varOrder, sources)...)

	for _, subName := range orderedKeys(model.Subsystems, file.declarationOrder(docPath+"/subsystems")) {
		sub, ok := decodeSubsystemAs[Model](model.Subsystems[subName])
		if !ok {
			continue
		}
		subComponent, err := collectModel(file, &sub, fullPrefix+"."+subName,
			docPath+"/subsystems/"+subName, sources)
		if err != nil {
			return nil, err
		}
		component.merge(subComponent)
	}

	return component, nil
}

// collectReactionSystem collects a ReactionSystem (lowered through mass-action
// ODE generation) into a componentSystem. Species become state variables,
// reaction parameters become parameters, rate laws become dN_i/dt equations, and
// constraint equations pass through.
//
// EXCEPT a reservoir species (`constant: true`, §7.4), which becomes a
// PARAMETER: the spec holds its concentration fixed and emits no ODE for it, so
// it is not a state. Its `default` carries over as the parameter's fixed value,
// so it still reads as a concentration in every rate law.
func collectReactionSystem(file *ESMFile, rs *ReactionSystem, fullPrefix, docPath string) (*componentSystem, error) {
	component := newComponentSystem(fullPrefix)
	leaveAlone := placeholderLeaveAlone()

	speciesOrder := orderedKeys(rs.Species, file.declarationOrder(docPath+"/species"))
	for _, name := range speciesOrder {
		sp := rs.Species[name]
		namespaced := fullPrefix + "." + name
		if sp.Constant != nil && *sp.Constant {
			component.parameters.set(FlattenedVariable{
				Name: namespaced, Role: "parameter", SourceSystem: fullPrefix,
				Units: sp.Units, Default: sp.Default, Description: sp.Description,
			})
			continue
		}
		component.stateVars.set(FlattenedVariable{
			Name: namespaced, Role: "species", SourceSystem: fullPrefix,
			Units: sp.Units, Default: sp.Default, Description: sp.Description,
		})
	}

	paramOrder := orderedKeys(rs.Parameters, file.declarationOrder(docPath+"/parameters"))
	for _, name := range paramOrder {
		p := rs.Parameters[name]
		var defaultValue any
		if _, isNum := exprNumber(p.Default); isNum {
			defaultValue = p.Default
		}
		component.parameters.set(FlattenedVariable{
			Name: fullPrefix + "." + name, Role: "parameter", SourceSystem: fullPrefix,
			Units: p.Units, Default: defaultValue, Description: p.Description,
		})
	}

	// Declared local names for the §5.5.6 `join` gate.
	locals := map[string]bool{}
	for _, n := range speciesOrder {
		locals[n] = true
	}
	for _, n := range paramOrder {
		locals[n] = true
	}

	derived, err := lowerReactionsToEquations(rs, speciesOrder)
	if err != nil {
		return nil, err
	}
	component.namespaceEquations(derived, fullPrefix, leaveAlone, nil, locals)
	component.namespaceEquations(rs.ConstraintEquations, fullPrefix, leaveAlone, nil, locals)

	for _, subName := range orderedKeys(rs.Subsystems, file.declarationOrder(docPath+"/subsystems")) {
		sub, ok := decodeSubsystemAs[ReactionSystem](rs.Subsystems[subName])
		if !ok {
			continue
		}
		subComponent, err := collectReactionSystem(file, &sub, fullPrefix+"."+subName,
			docPath+"/subsystems/"+subName)
		if err != nil {
			return nil, err
		}
		component.merge(subComponent)
	}

	return component, nil
}

// lowerReactionsToEquations lowers a reaction network into ODE equations by
// mass-action kinetics: `d[species]/dt = Σ_r net_stoich(species, r) · rate(r)`,
// where the rate law is `k · ∏ Sᵢ^nᵢ` (esm-spec §7.4 — `rate` is the rate
// COEFFICIENT, so the substrate product is always applied).
//
// Species are visited in DECLARATION order, so the derived equations are in
// declaration order too; a species with a zero net rate gets no equation, and a
// reservoir species (`constant: true`) gets none either.
func lowerReactionsToEquations(rs *ReactionSystem, speciesOrder []string) ([]Equation, error) {
	if len(rs.Reactions) == 0 {
		return nil, nil
	}
	rates := make(map[string]Expression, len(speciesOrder))
	for _, name := range speciesOrder {
		rates[name] = 0
	}

	for _, reaction := range rs.Reactions {
		if reaction.Rate == nil {
			return nil, fmt.Errorf("flatten: reaction %q must have a rate constant", reaction.ID)
		}
		reactants := map[string]float64{}
		products := map[string]float64{}
		for _, s := range reaction.Substrates {
			if _, ok := rates[s.Species]; !ok {
				return nil, fmt.Errorf("flatten: reactant %s not found in species list", s.Species)
			}
			reactants[s.Species] += s.Stoichiometry
		}
		for _, p := range reaction.Products {
			if _, ok := rates[p.Species]; !ok {
				return nil, fmt.Errorf("flatten: product %s not found in species list", p.Species)
			}
			products[p.Species] += p.Stoichiometry
		}

		rateExpr := reaction.Rate
		for _, s := range reaction.Substrates {
			if s.Stoichiometry == 1 {
				rateExpr = multiplyExprs(rateExpr, s.Species)
				continue
			}
			if s.Stoichiometry == 0 {
				rateExpr = multiplyExprs(rateExpr, 1)
				continue
			}
			rateExpr = multiplyExprs(rateExpr,
				ExprNode{Op: "^", Args: []any{s.Species, stoichLiteral(s.Stoichiometry)}})
		}

		for _, name := range speciesOrder {
			net := products[name] - reactants[name]
			if net == 0 {
				continue
			}
			rates[name] = addExprs(rates[name], multiplyExprs(stoichLiteral(net), rateExpr))
		}
	}

	var out []Equation
	for _, name := range speciesOrder {
		sp := rs.Species[name]
		if sp.Constant != nil && *sp.Constant {
			continue
		}
		if isNumericZero(rates[name]) {
			continue
		}
		wrt := DefaultIndepVar
		out = append(out, Equation{
			LHS: ExprNode{Op: OpDerivative, Args: []any{name}, Wrt: &wrt},
			RHS: rates[name],
		})
	}
	return out, nil
}

// stoichLiteral renders a stoichiometric coefficient as the numeric literal the
// expression tree carries: an integer-valued coefficient as an int (so it
// renders and round-trips as `2`, not `2.0`), a fractional one as a float.
func stoichLiteral(v float64) any {
	if v == math.Trunc(v) && math.Abs(v) < intExactCutoff {
		return int64(v)
	}
	return v
}

// inlinedUnknownSet is the model's unknowns whose defining LHS is a BARE
// VARIABLE — the strict `y ~ f(…)` form of esm-spec §6.3.1, the one that is
// eliminable by INLINING.
//
// Narrower than ObservedUnknowns on purpose: an arrayed definition
// (`y[i] ~ f(i)`) is observed too — its cadence resolves through its RHS — but
// it materializes into a buffer its consumers index rather than being inlined,
// so it belongs in the solved-for vector. Mirrors Python's `inlined_unknowns`.
func inlinedUnknownSet(model *Model) map[string]bool {
	out := map[string]bool{}
	if model == nil {
		return out
	}
	states := odeStateSet(model)
	for _, eq := range model.Equations {
		name, ok := eq.LHS.(string)
		if !ok {
			continue
		}
		if v, declared := model.Variables[name]; !declared || v.Type != VarTypeUnknown {
			continue
		}
		if states[name] {
			continue
		}
		out[name] = true
	}
	return out
}

// ============================================================================
// Coupling resolution
// ============================================================================

// translateEntry is one normalized `operator_compose` translate rule: the
// system-A variable a system-B variable translates TO, plus an optional
// conversion factor.
type translateEntry struct {
	target string
	factor float64
}

// buildTranslateMap normalizes the `operator_compose` translate map, INVERTED
// for matching.
//
// The authored direction is normative and is not symmetric (esm-spec §10.2,
// esm-libraries-spec §4.7.1 step 2): for `"systems": [A, B]` every KEY names a
// variable of A (`systems[0]`) and every VALUE names a variable of B
// (`systems[1]`).
//
// applyOperatorCompose walks B's equations, so it needs the map the other way
// round; this returns the INVERSE, `{b_name: (a_name, factor)}`. Indexing the
// authored (A-keyed) map by B's dependent variable — what this binding did
// before — is the bug this function exists to prevent: a correctly spelled
// `translate` map then matches nothing at all and the whole entry is a silent
// no-op.
func buildTranslateMap(entry OperatorComposeCoupling) map[string]translateEntry {
	out := map[string]translateEntry{}
	for aName, v := range entry.Translate {
		switch t := v.(type) {
		case string:
			if t != "" {
				out[t] = translateEntry{target: aName, factor: 1.0}
			}
		case map[string]any:
			bName := ""
			for _, key := range []string{"to", "target", "var"} {
				if s, ok := t[key].(string); ok && s != "" {
					bName = s
					break
				}
			}
			factor := 1.0
			if f, ok := exprNumber(t["factor"]); ok {
				factor = f
			}
			if bName != "" {
				out[bName] = translateEntry{target: aName, factor: factor}
			}
		}
	}
	return out
}

// expandOperatorComposePlaceholders expands `_var` placeholders in B's equations
// against A's state variables (esm-spec §4.7.1): an equation like
// `D(_var, t) = -u·grad(_var, x)` is cloned once per state variable of A, with
// `_var` substituted for the actual namespaced name.
func expandOperatorComposePlaceholders(components map[string]*componentSystem, entry OperatorComposeCoupling) {
	a, aok := components[entry.Systems[0]]
	b, bok := components[entry.Systems[1]]
	if !aok || !bok || len(a.stateVars.keys) == 0 {
		return
	}
	var out []FlattenedEquation
	for _, eq := range b.equations {
		if !exprHasVarPlaceholder(eq.LHS) && !exprHasVarPlaceholder(eq.RHS) {
			out = append(out, eq)
			continue
		}
		for _, varName := range a.stateVars.keys {
			bindings := map[string]Expression{operatorPlaceholderVar: varName}
			out = append(out, FlattenedEquation{
				LHS:          substituteExpr(eq.LHS, bindings),
				RHS:          substituteExpr(eq.RHS, bindings),
				SourceSystem: eq.SourceSystem,
			})
		}
	}
	b.equations = out
}

// applyOperatorCompose merges B's equations into A by matching dependent
// variables (esm-spec §4.7.1): for each B equation with LHS `D(x, t)`, find A's
// equation with the same dependent variable (translation-aware) and SUM the two
// right-hand sides. Unmatched B equations survive unchanged.
func applyOperatorCompose(components map[string]*componentSystem, entry OperatorComposeCoupling) {
	a, aok := components[entry.Systems[0]]
	b, bok := components[entry.Systems[1]]
	if !aok || !bok {
		return
	}
	translate := buildTranslateMap(entry)

	// Index A's equations by namespaced dependent variable, keeping insertion
	// order so the fallback scan below is deterministic.
	aIndex := map[string]int{}
	var aOrder []string
	for i, eq := range a.equations {
		dep := lhsDependentVar(eq.LHS)
		if dep == "" {
			continue
		}
		if _, seen := aIndex[dep]; !seen {
			aOrder = append(aOrder, dep)
		}
		aIndex[dep] = i
	}

	var surviving []FlattenedEquation
	for _, bEq := range b.equations {
		bDep := lhsDependentVar(bEq.LHS)
		if bDep == "" {
			surviving = append(surviving, bEq)
			continue
		}
		// esm-libraries-spec §4.7.1 step 3 lists the match kinds in precedence
		// order: DIRECT first, then TRANSLATION, then the bare-name fallback.
		// Direct-first is load-bearing, not cosmetic: placeholder expansion has
		// already rewritten `_var` to A's own variable name, so an expanded
		// equation IS a direct match. Consulting `translate` first would let a
		// map keyed by A's names hit spuriously on that rewritten name and
		// redirect the match to a target that does not exist — turning a working
		// composition into an over-determination error (the
		// `translate: {"A.x": "B._var"}` redundancy invariant, esm-spec §10.2).
		targetDep := bDep
		factor := 1.0
		_, direct := aIndex[bDep]
		t, hasTranslation := translate[bDep]
		switch {
		case direct:
			// Direct match; `targetDep` is already right.
		case hasTranslation:
			targetDep, factor = t.target, t.factor
		default:
			// Map a bare name from B back to A's equivalent.
			short := bDep
			if _, rest, found := strings.Cut(bDep, "."); found {
				short = rest
			}
			for _, ad := range aOrder {
				if strings.HasSuffix(ad, "."+short) {
					targetDep = ad
					break
				}
			}
		}
		i, ok := aIndex[targetDep]
		if !ok {
			surviving = append(surviving, bEq)
			continue
		}
		aEq := a.equations[i]
		// §4.7.1 step 4: on a TRANSLATION match, B's dependent variable is
		// rewritten to A's target throughout `rhs_B` before summing — a
		// `translate` pair names two spellings of the SAME quantity (§10.2), and
		// leaving `rhs_B` in B's spelling strands that variable as an unknown
		// nothing defines, since its own defining equation was just consumed by
		// this merge. The same argument applies to the bare-name fallback above.
		// On a DIRECT match, and on a PLACEHOLDER match (where expansion already
		// substituted), the two names are equal and this rewrite is the identity.
		// Only the dependent variable is rewritten; B's parameters and observeds
		// keep their names.
		rhs := substituteExpr(bEq.RHS, map[string]Expression{bDep: targetDep})
		if factor != 1.0 {
			rhs = ExprNode{Op: "*", Args: []any{factor, rhs}}
		}
		a.equations[i] = FlattenedEquation{
			LHS:          aEq.LHS,
			RHS:          addExprs(aEq.RHS, rhs),
			SourceSystem: aEq.SourceSystem,
		}
	}
	b.equations = surviving
}

// applyCouple resolves a `couple` connector by injecting source/sink terms: each
// connector equation appends its expression to (or multiplies it with, or
// replaces) the target variable's equation.
//
// It fails with *CoupleMultiplicativeNoTendencyError when a `multiplicative`
// equation targets something with no `D(to)` tendency to multiply (esm-spec
// §10.3, esm-libraries-spec §4.7.2).
func applyCouple(components map[string]*componentSystem, order []string, entry CouplingCouple) error {
	if len(entry.Connector.Equations) == 0 {
		return nil
	}
	type eqRef struct {
		system string
		index  int
	}
	eqIndex := map[string]eqRef{}
	// Which targets carry a TENDENCY (`D(x)`), as opposed to merely SOME
	// defining equation: `multiplicative` is defined against an ODE right-hand
	// side, not against an algebraic or observed definition (§10.3, §4.7.2).
	tendencies := map[string]bool{}
	for _, sysName := range order {
		comp := components[sysName]
		for i, eq := range comp.equations {
			dep := lhsDependentVar(eq.LHS)
			if dep == "" {
				continue
			}
			eqIndex[dep] = eqRef{system: sysName, index: i}
			if node, ok := asExprNode(eq.LHS); ok && node.Op == OpDerivative {
				tendencies[dep] = true
			}
		}
	}

	for _, ceq := range entry.Connector.Equations {
		if ceq.To == "" {
			continue
		}
		if ceq.Transform == "multiplicative" && !tendencies[ceq.To] {
			return &CoupleMultiplicativeNoTendencyError{
				Target: ceq.To,
				Message: fmt.Sprintf(
					"couple connector 'multiplicative' transform targets %q, which has no "+
						"tendency (D(%s)) to multiply (esm-spec §10.3). To scale a constant "+
						"parameter by a factor, use a variable_map entry with an Expression "+
						"transform (esm-spec §10.4) instead.", ceq.To, ceq.To),
			}
		}
		ref, ok := eqIndex[ceq.To]
		if !ok {
			continue
		}
		comp := components[ref.system]
		existing := comp.equations[ref.index]
		var expression Expression = ceq.Expression
		if expression == nil {
			expression = ceq.From
		}
		var rhs Expression
		switch ceq.Transform {
		case "multiplicative":
			rhs = multiplyExprs(existing.RHS, expression)
		case "replacement":
			rhs = expression
		default: // "additive" and any unrecognized transform
			rhs = addExprs(existing.RHS, expression)
		}
		comp.equations[ref.index] = FlattenedEquation{
			LHS:          existing.LHS,
			RHS:          rhs,
			SourceSystem: existing.SourceSystem,
		}
	}
	return nil
}

// applyVariableMap substitutes the target parameter with the source variable.
//
// For `param_to_var`, `conversion_factor`, and the empty/absent transform the
// target parameter is PROMOTED — removed from the parameter list, since it
// becomes a shared variable. For the remaining transforms (`identity`,
// `additive`, `multiplicative`) the target stays a parameter; the substitution
// still runs so the equation set references the canonical name.
//
// `loaderNames` is the set of top-level `data_sources` keys. When a
// `param_to_var` binds a LOADED field onto a GRID-SHAPED consumer parameter, the
// shape transfers to the source name so the pointwise lift recognizes it as an
// array operand to index per grid cell (esm-spec §11.5 + §10.4).
func applyVariableMap(components map[string]*componentSystem, order []string, entry VariableMapCoupling, loaderNames map[string]bool) error {
	if entry.From == "" || entry.To == "" {
		return nil
	}
	if entry.TransformIsExpression() {
		return applyVariableMapExpression(components, order, entry)
	}
	var src Expression = entry.From
	if entry.Factor != nil && *entry.Factor != 1.0 {
		src = ExprNode{Op: "*", Args: []any{*entry.Factor, entry.From}}
	}
	bindings := map[string]Expression{entry.To: src}
	for _, sysName := range order {
		comp := components[sysName]
		for i, eq := range comp.equations {
			comp.equations[i] = FlattenedEquation{
				LHS:          substituteExpr(eq.LHS, bindings),
				RHS:          renameJoinNames(substituteExpr(eq.RHS, bindings), entry.To, entry.From),
				SourceSystem: eq.SourceSystem,
			}
		}
	}

	transform := strings.ToLower(entry.TransformKind())
	if transform != "param_to_var" && transform != "conversion_factor" && transform != "" {
		return nil
	}
	for _, sysName := range order {
		comp := components[sysName]
		toVar, ok := comp.parameters.remove(entry.To)
		if !ok {
			continue
		}
		fromOwner, _, _ := strings.Cut(entry.From, ".")
		if len(toVar.Shape) > 0 && loaderNames[fromOwner] && !comp.parameters.has(entry.From) {
			comp.parameters.set(FlattenedVariable{
				Name:         entry.From,
				Role:         "parameter",
				SourceSystem: fromOwner,
				Units:        toVar.Units,
				Description:  toVar.Description,
				Shape:        append([]string(nil), toVar.Shape...),
			})
		}
	}
	return nil
}

// applyVariableMapExpression resolves a `variable_map` whose `transform` is an
// Expression (esm-spec §10.4/§10.5). It promotes like `param_to_var` — the
// target parameter is removed — but references to the target are NOT
// substituted: the target becomes an OBSERVED variable named exactly `to` whose
// defining equation is the transform expression VERBATIM (by contract every
// reference inside an expression transform is already fully scoped).
func applyVariableMapExpression(components map[string]*componentSystem, order []string, entry VariableMapCoupling) error {
	if !exprReferencesVar(entry.Transform, entry.From) {
		return fmt.Errorf(
			"flatten: variable_map expression transform mapping '%s' -> '%s' does not reference its source variable '%s'",
			entry.From, entry.To, entry.From)
	}
	var targetComp *componentSystem
	var removed *FlattenedVariable
	for _, sysName := range order {
		comp := components[sysName]
		if popped, ok := comp.parameters.remove(entry.To); ok && removed == nil {
			v := popped
			removed = &v
			targetComp = comp
		}
	}
	if targetComp == nil {
		head, _, _ := strings.Cut(entry.To, ".")
		targetComp = components[head]
	}
	if targetComp == nil {
		return nil
	}
	observed := FlattenedVariable{Name: entry.To, Role: "observed", SourceSystem: targetComp.name}
	if removed != nil {
		observed.Units = removed.Units
		observed.Description = removed.Description
		observed.SourceSystem = removed.SourceSystem
		observed.Shape = append([]string(nil), removed.Shape...)
		if len(observed.Shape) == 0 {
			observed.Shape = nil
		}
	}
	targetComp.observed.set(observed)
	targetComp.equations = append(targetComp.equations, FlattenedEquation{
		LHS:          entry.To,
		RHS:          entry.Transform,
		SourceSystem: targetComp.name,
	})
	return nil
}

// exprReferencesVar reports whether name occurs as a string leaf in any
// variable-reference position of expr.
func exprReferencesVar(expr Expression, name string) bool {
	if s, ok := expr.(string); ok {
		return s == name
	}
	node, ok := asExprNode(expr)
	if !ok {
		return false
	}
	for _, child := range exprRefChildren(node) {
		if exprReferencesVar(child.Child, name) {
			return true
		}
	}
	return false
}

// renameJoinNames renames toVar -> fromVar in every plain-string `join` name.
//
// The join-side companion of the `variable_map` substitution (CONFORMANCE_SPEC
// §5.5.6). Substitute walks expression CHILDREN, so it cannot see an `on` key
// column or an `overlap`'s `src_env` / `tgt_env` — but those are references in
// the same namespaced scope as everything else. A `param_to_var` /
// `conversion_factor` map REMOVES toVar from the flattened parameter list, so a
// join still naming it points at a variable the system no longer declares.
func renameJoinNames(expr Expression, toVar, fromVar string) Expression {
	node, ok := asExprNode(expr)
	if !ok || !exprContainsJoin(node) {
		return expr
	}
	return renameJoinNamesIn(node, toVar, fromVar)
}

func exprContainsJoin(node ExprNode) bool {
	found := false
	walkExprNodes(node, func(n ExprNode) {
		if len(n.Join) > 0 {
			found = true
		}
	})
	return found
}

func renameJoinNamesIn(expr Expression, toVar, fromVar string) Expression {
	node, ok := asExprNode(expr)
	if !ok {
		return expr
	}
	out, _ := mapExprRefChildren(node, func(child Expression) (Expression, error) {
		return renameJoinNamesIn(child, toVar, fromVar), nil
	})
	if len(node.Join) == 0 {
		return out
	}
	ren := func(v any) any {
		if s, ok := v.(string); ok && s == toVar {
			return fromVar
		}
		return v
	}
	renList := func(v any) any {
		items, ok := v.([]any)
		if !ok {
			return v
		}
		res := make([]any, len(items))
		for i, it := range items {
			res[i] = ren(it)
		}
		return res
	}
	clauses := make([]any, len(node.Join))
	for i, raw := range node.Join {
		clause, ok := raw.(map[string]any)
		if !ok {
			clauses[i] = raw
			continue
		}
		next := make(map[string]any, len(clause))
		for k, v := range clause {
			next[k] = v
		}
		if pairs, ok := clause["on"].([]any); ok {
			renamed := make([]any, len(pairs))
			for j, pair := range pairs {
				renamed[j] = renList(pair)
			}
			next["on"] = renamed
		}
		if overlap, ok := clause["overlap"].(map[string]any); ok {
			nextOverlap := make(map[string]any, len(overlap))
			for k, v := range overlap {
				nextOverlap[k] = v
			}
			for _, side := range []string{"src_env", "tgt_env"} {
				if _, present := overlap[side]; present {
					nextOverlap[side] = renList(overlap[side])
				}
			}
			next["overlap"] = nextOverlap
		}
		clauses[i] = next
	}
	out.Join = clauses
	return out
}

// ============================================================================
// Public API
// ============================================================================

// Flatten takes an ESMFile containing multiple models and/or reaction systems
// and returns a FlattenedSystem with dot-namespaced variables (esm-libraries-spec
// §4.7.5).
//
// The algorithm:
//  1. Collect every component into a per-system bag, lowering reaction systems
//     to ODE equations and namespacing every reference.
//  2. Expand `coupling_import` entries, then apply the coupling rules into the
//     per-component equation sets.
//  3. Assemble one flat system, collect and namespace events, run the pointwise
//     spatial lift, pass the domain through and derive the independent variables.
//  4. Derive the canonical step-4 fields: the §6.3.1 subsets, the deferred `ic`
//     equations, and the merged expression-template registry.
func Flatten(file *ESMFile) (*FlattenedSystem, error) {
	return FlattenWithOptions(file, CouplingImportOptions{})
}

// FlattenWithOptions is Flatten with control over how `coupling_import` refs are
// resolved (esm-spec §10.10). Only needed when the file uses `coupling_import`;
// a file with no such entries flattens identically under the zero-value options.
func FlattenWithOptions(file *ESMFile, opts CouplingImportOptions) (*FlattenedSystem, error) {
	if file == nil {
		return nil, fmt.Errorf("flatten: input file is nil")
	}
	if len(file.Models) == 0 && len(file.ReactionSystems) == 0 {
		return nil, fmt.Errorf("flatten: cannot flatten an ESMFile with no models or reaction systems")
	}

	// Expand `coupling_import` entries (esm-spec §10.10.3) into concrete edges
	// BEFORE any coupling processing.
	coupling, err := expandCouplingImports(file, opts)
	if err != nil {
		return nil, fmt.Errorf("flatten: %w", err)
	}

	components, order, err := collectComponents(file)
	if err != nil {
		return nil, err
	}
	metadata := FlattenMetadata{
		SourceSystems:   append([]string(nil), order...),
		CouplingRules:   []string{},
		OperatorApplies: []string{},
		Callbacks:       []string{},
	}
	if err := applyCouplings(file, components, order, &metadata, coupling); err != nil {
		return nil, err
	}

	flat, err := assembleSystem(file, components, order, metadata)
	if err != nil {
		return nil, err
	}
	namespaceEvents(file, flat)
	if err := applyPointwiseLift(flat, coupling); err != nil {
		return nil, err
	}
	if file.Domain != nil {
		flat.Domain = file.Domain
	}
	deriveIndependentVars(flat)

	// The remaining canonical step-4 fields, all derived LAST over the finished
	// system so they see the equations coupling and the lift actually produced.
	classifyFlattened(flat)
	collectFieldICs(flat)
	flat.TemplateRegistry = mergedTemplateRegistry(file)
	return flat, nil
}

// collectComponents collects every component system into a per-system bag,
// walking models then reaction systems in DOCUMENT order.
func collectComponents(file *ESMFile) (map[string]*componentSystem, []string, error) {
	components := map[string]*componentSystem{}
	var order []string
	sources := file.DataSources
	for _, name := range orderedKeys(file.Models, file.declarationOrder("/models")) {
		model := file.Models[name]
		comp, err := collectModel(file, &model, name, "/models/"+name, sources)
		if err != nil {
			return nil, nil, err
		}
		components[name] = comp
		order = append(order, name)
	}
	for _, name := range orderedKeys(file.ReactionSystems, file.declarationOrder("/reaction_systems")) {
		rs := file.ReactionSystems[name]
		comp, err := collectReactionSystem(file, &rs, name, "/reaction_systems/"+name)
		if err != nil {
			return nil, nil, err
		}
		components[name] = comp
		order = append(order, name)
	}
	return components, order, nil
}

// applyCouplings applies the file's coupling entries to `components` in place,
// walking the post-`coupling_import` list in array order. `operator_compose`
// runs first so its placeholder expansion and merge happen before any
// `variable_map` substitution rewrites the dependent variable names out from
// under it.
func applyCouplings(file *ESMFile, components map[string]*componentSystem, order []string,
	metadata *FlattenMetadata, coupling []CouplingEntry) error {
	var composes []OperatorComposeCoupling
	var couples []CouplingCouple
	var varMaps []VariableMapCoupling
	for i, entry := range coupling {
		switch c := entry.(type) {
		case OperatorComposeCoupling:
			composes = append(composes, c)
		case CouplingCouple:
			couples = append(couples, c)
		case VariableMapCoupling:
			varMaps = append(varMaps, c)
		case OperatorApplyCoupling:
			metadata.OperatorApplies = append(metadata.OperatorApplies, c.Operator)
		case CallbackCoupling:
			metadata.Callbacks = append(metadata.Callbacks, c.CallbackID)
		}
		metadata.CouplingRules = append(metadata.CouplingRules, describeCoupling(entry, file, i))
	}

	for _, oc := range composes {
		expandOperatorComposePlaceholders(components, oc)
		applyOperatorCompose(components, oc)
	}
	for _, cp := range couples {
		if err := applyCouple(components, order, cp); err != nil {
			return err
		}
	}
	loaderNames := map[string]bool{}
	for k := range file.DataSources {
		loaderNames[k] = true
	}
	for _, vm := range varMaps {
		if err := applyVariableMap(components, order, vm, loaderNames); err != nil {
			return err
		}
	}
	return nil
}

// assembleSystem folds the per-component pieces into one FlattenedSystem,
// rejecting a document in which two systems define non-additive equations for
// the same dependent variable.
func assembleSystem(file *ESMFile, components map[string]*componentSystem, order []string,
	metadata FlattenMetadata) (*FlattenedSystem, error) {
	flat := &FlattenedSystem{
		IndependentVariables: []string{DefaultIndepVar},
		Metadata:             metadata,
	}
	for _, name := range orderedKeys(file.IndexSets, file.declarationOrder("/index_sets")) {
		flat.IndexSets = append(flat.IndexSets, FlattenedIndexSet{Name: name, Set: file.IndexSets[name]})
	}
	for _, name := range orderedKeys(file.FunctionTables, file.declarationOrder("/function_tables")) {
		flat.FunctionTables = append(flat.FunctionTables,
			FlattenedFunctionTable{Name: name, Table: file.FunctionTables[name]})
	}

	combined := newComponentSystem("")
	for _, name := range order {
		combined.merge(components[name])
	}
	flat.StateVariables = combined.stateVars.slice()
	flat.Parameters = combined.parameters.slice()
	flat.ObservedVariables = combined.observed.slice()
	flat.LoaderFields = append(flat.LoaderFields, combined.loaderFields...)

	seen := map[string]FlattenedEquation{}
	for _, eq := range combined.equations {
		dep := lhsDependentVar(eq.LHS)
		// Equations that use array ops may legitimately define different index
		// subsets of the same state variable (stencil interior + BCs,
		// block-assembled makearray, ...), so the scalar-only dedup check is
		// skipped for them.
		isArrayEq := exprHasArrayOp(eq.LHS) || exprHasArrayOp(eq.RHS)
		if dep != "" && !isArrayEq {
			if existing, ok := seen[dep]; ok {
				if ToAscii(existing.RHS) == ToAscii(eq.RHS) {
					continue
				}
				// A single source system that authored two equations with the
				// same scalar LHS expressed an algebraic constraint on purpose
				// (K = f(T) AND K = [H+][OH-]); structural simplification
				// resolves which equation defines which variable. A CROSS-system
				// clash is over-determination.
				if existing.SourceSystem != eq.SourceSystem &&
					!exprHasArrayOp(existing.LHS) && !exprHasArrayOp(existing.RHS) {
					return nil, &ConflictingDerivativeError{Message: fmt.Sprintf(
						"flatten: two systems define non-additive equations for variable %q: %s vs %s",
						dep, existing.SourceSystem, eq.SourceSystem)}
				}
			}
			seen[dep] = eq
		}
		flat.Equations = append(flat.Equations, eq)
	}
	return flat, nil
}

// namespaceEvents collects the components' events into flat, dot-namespacing
// variable references where they unambiguously match a known flattened variable.
//
// The events are walked component by component (models then reaction systems, in
// document order), discrete events before continuous ones within a component —
// the same flat aggregation the other bindings expose as `EsmFile.events`.
func namespaceEvents(file *ESMFile, flat *FlattenedSystem) {
	bare := map[string]Expression{}
	for _, table := range [][]FlattenedVariable{flat.StateVariables, flat.Parameters} {
		for _, v := range table {
			short := v.Name
			if idx := strings.LastIndex(short, "."); idx >= 0 {
				short = short[idx+1:]
			}
			if _, seen := bare[short]; !seen {
				bare[short] = v.Name
			}
		}
	}

	appendEvents := func(discrete []DiscreteEvent, continuous []ContinuousEvent) {
		for _, de := range discrete {
			out := de
			out.Affects = namespaceAffects(de.Affects, bare)
			// A `condition` trigger names variables the same way an affect RHS
			// does, so it follows the same registry. (The corpus does not pin
			// this — it records only an event's name, conditions and affects —
			// but a trigger left un-namespaced references a variable the
			// flattened system no longer declares.)
			if de.Trigger.Type == "condition" && de.Trigger.Expression != nil {
				out.Trigger.Expression = substituteExpr(de.Trigger.Expression, bare)
			}
			flat.DiscreteEvents = append(flat.DiscreteEvents, out)
		}
		for _, ce := range continuous {
			out := ce
			conditions := make([]Expression, len(ce.Conditions))
			for i, c := range ce.Conditions {
				conditions[i] = substituteExpr(c, bare)
			}
			out.Conditions = conditions
			out.Affects = namespaceAffects(ce.Affects, bare)
			if ce.AffectNeg != nil {
				out.AffectNeg = namespaceAffects(ce.AffectNeg, bare)
			}
			flat.ContinuousEvents = append(flat.ContinuousEvents, out)
		}
	}

	for _, name := range orderedKeys(file.Models, file.declarationOrder("/models")) {
		m := file.Models[name]
		appendEvents(m.DiscreteEvents, m.ContinuousEvents)
	}
	for _, name := range orderedKeys(file.ReactionSystems, file.declarationOrder("/reaction_systems")) {
		rs := file.ReactionSystems[name]
		appendEvents(rs.DiscreteEvents, rs.ContinuousEvents)
	}
}

// namespaceAffects rewrites each affect's LHS name and RHS expression to
// dot-namespaced form where they unambiguously match a known variable.
func namespaceAffects(affects []AffectEquation, bare map[string]Expression) []AffectEquation {
	if affects == nil {
		return nil
	}
	out := make([]AffectEquation, len(affects))
	for i, affect := range affects {
		lhs := affect.LHS
		if ns, ok := bare[lhs].(string); ok {
			lhs = ns
		}
		out[i] = AffectEquation{LHS: lhs, RHS: substituteExpr(affect.RHS, bare)}
	}
	return out
}

// deriveIndependentVars derives the flattened system's independent variables
// from the equation set: time is always present, and a spatial dimension is
// added when an UNDISCRETIZED spatial differential still names it.
// The axes are collected in DOCUMENT ORDER -- the order the scan first meets
// them -- not sorted. This used to collect into a map and sort on the way out;
// because Go randomizes map iteration, the sort was also the only thing making
// the output deterministic, which hid that the order was wrong rather than
// merely arbitrary. `full_coupled` names lon, lat, lev and emitted lat, lev,
// lon. For a PDE the axis order is the order a downstream array layout follows
// (esm-libraries-spec §4.7.5 step 4's ordering rule, and §4.7.6).
func deriveIndependentVars(flat *FlattenedSystem) {
	seen := map[string]bool{}
	names := make([]string, 0, 4)
	appendDims := func(expr Expression) {
		walkExprNodes(expr, func(n ExprNode) {
			if n.Dim == nil || *n.Dim == "" || seen[*n.Dim] {
				return
			}
			seen[*n.Dim] = true
			names = append(names, *n.Dim)
		})
	}
	for _, eq := range flat.Equations {
		appendDims(eq.LHS)
		appendDims(eq.RHS)
	}
	flat.IndependentVariables = append([]string{DefaultIndepVar}, names...)
}

// classificationView is a model-shaped view of the flattened system that the
// esm-spec §6.3.1 classification functions accept.
//
// Classification is re-run over the FLATTENED system rather than per component
// because flattening moves the ground under it: `operator_compose` merges two
// right-hand sides into one equation, `variable_map` deletes a parameter and
// promotes a variable in its place, and the pointwise lift rewrites a scalar
// state ODE into an `aggregate`. A per-component answer namespaced after the
// fact would describe the document, not the system produced from it.
//
// The view hands the classifier the two DECLARED types and the raw update /
// distribution metadata and lets it derive everything else: reading a derived
// role to answer a derived question is precisely what 1.0.0 removes.
func (f *FlattenedSystem) classificationView() Model {
	variables := map[string]ModelVariable{}
	add := func(v FlattenedVariable, declared string) {
		if _, seen := variables[v.Name]; seen {
			return
		}
		mv := ModelVariable{
			Type:         declared,
			Units:        v.Units,
			Default:      v.Default,
			Update:       v.Update,
			Distribution: v.Distribution,
		}
		if len(v.Shape) > 0 {
			mv.SetDims(append([]string(nil), v.Shape...))
		}
		variables[v.Name] = mv
	}
	for _, v := range f.StateVariables {
		add(v, VarTypeUnknown)
	}
	for _, v := range f.ObservedVariables {
		add(v, VarTypeUnknown)
	}
	for _, v := range f.Parameters {
		add(v, VarTypeParameter)
	}
	equations := make([]Equation, len(f.Equations))
	for i, eq := range f.Equations {
		equations[i] = Equation{LHS: eq.LHS, RHS: eq.RHS}
	}
	return Model{Variables: variables, Equations: equations}
}

// classifyFlattened fills the §6.3.1 SUBSET maps — AlgebraicVariables,
// BrownianParameters, DiscreteParameters — delegating every membership decision
// to classify.go (the binding's only sanctioned answer to these questions) and
// doing nothing here but re-imposing document order.
func classifyFlattened(flat *FlattenedSystem) {
	view := flat.classificationView()
	set := func(names []string) map[string]bool {
		out := make(map[string]bool, len(names))
		for _, n := range names {
			out[n] = true
		}
		return out
	}
	flat.AlgebraicVariables = selectOrdered(set(AlgebraicUnknowns(&view)),
		flat.StateVariables, flat.ObservedVariables)
	flat.BrownianParameters = selectOrdered(set(BrownianParameters(&view)), flat.Parameters)
	flat.DiscreteParameters = selectOrdered(set(DiscreteParameters(&view)), flat.Parameters)
}

// collectFieldICs records the deferred `ic` equations (esm-spec §11.4.1) as
// ordered (state, expression) pairs and CLASSIFIES THEM OUT of flat.Equations.
//
// An initial condition is a datum, not an equation of motion: leaving it in
// `equations` makes that list unusable for building a right-hand side without
// filtering it first, and makes equation counts incomparable across bindings.
// Runs LAST, after the lift and the independent-variable derivation, so every
// intermediate pass still sees the same equation list it always did.
func collectFieldICs(flat *FlattenedSystem) {
	var ics []FieldIC
	var remaining []FlattenedEquation
	for _, eq := range flat.Equations {
		node, ok := asExprNode(eq.LHS)
		if ok && node.Op == "ic" && len(node.Args) == 1 {
			if target, ok := node.Args[0].(string); ok {
				ics = append(ics, FieldIC{State: target, Expr: eq.RHS})
				continue
			}
		}
		remaining = append(remaining, eq)
	}
	flat.FieldICs = ics
	flat.Equations = remaining
}
