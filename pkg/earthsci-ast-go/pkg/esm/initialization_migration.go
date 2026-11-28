package esm

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// esm 2.5.0: the deprecated `initialization_equations` block, read at the
// load's wire boundary (esm-spec §11.4.4), and the load-time check of an `ic`
// argument (esm-spec §4.2, the `ic` row). Mirrors the Julia, Rust, Python and
// TypeScript loaders:
//
//   - a model (top-level, or an inline subsystem at any depth) with a time
//     derivative (an equation whose left-hand side contains a `D`) gets each
//     equation appended to `equations`, every reference to an unknown w
//     replaced by ic(w) and every D(w) by ic(D(w));
//   - a model with none gets each `v ~ e`, v a bare unknown, as
//     `guesses[v] = e` (an existing entry is kept); any other equation is
//     refused with `deprecated_field`;
//   - before either, an initial condition of a declared parameter k (an entry
//     whose left-hand side is k or ic(k), or, below esm 2.5.0, an `equations`
//     entry whose left-hand side is ic(k)) becomes k's `default`.
//
// The loader and the canonical form (so every printer) apply this one
// migration.
//
// The field is removed either way, with one `deprecated_field` warning per
// document naming every migrated block.

// initializationError is a load-time refusal of the migration
// (`deprecated_field`) or of an `ic` node (`ic_invalid_argument`). Path is the
// JSON Pointer of the refused equation or node.
type initializationError struct {
	Code    string
	Path    string
	Message string
}

func (e *initializationError) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *initializationError) DiagnosticCode() string { return e.Code }

var _ DiagnosticError = (*initializationError)(nil)

// readInitializationEquations is the wire-boundary step: migrate, check every
// `ic` argument, then warn. Text that names neither the field nor `ic` is
// returned unchanged; text that does not decode is left to schema validation.
func readInitializationEquations(jsonStr string) (string, error) {
	hasField := strings.Contains(jsonStr, `"initialization_equations"`)
	hasIc := strings.Contains(jsonStr, `"ic"`)
	if !hasField && !hasIc {
		return jsonStr, nil
	}
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return jsonStr, nil
	}
	sites, err := migrateInitializationEquations(view)
	if err != nil {
		return "", err
	}
	if err := checkIcArguments(view); err != nil {
		return "", err
	}
	if len(sites) == 0 && !hasField {
		return jsonStr, nil
	}
	out, err := json.Marshal(view)
	if err != nil {
		return jsonStr, nil
	}
	if len(sites) == 0 {
		return string(out), nil
	}
	fmt.Fprintf(os.Stderr,
		"warning: %s: `initialization_equations` is deprecated (esm 2.5.0, esm-spec §11.4.4); "+
			"each equation was rewritten into an `ic` equation in `equations` (or into "+
			"`guesses` for a model with no time derivative), and an initial condition of a "+
			"parameter became its `default`. Read at: %s.\n",
		codeDeprecatedField, strings.Join(sites, ", "))
	return string(out), nil
}

// initializationEquationsMigratedText is jsonStr read as a load reads its
// `initialization_equations` and its pre-2.5.0 initial conditions of
// parameters (esm-spec §11.4.4), for the canonical form and the printers
// (esm-spec §9.6.6 `deprecated_field`: the field never survives into an
// emitted document). jsonStr itself when there is nothing to migrate, or when
// the migration refuses it (the load reports that refusal; a printer prints
// the document as given).
func initializationEquationsMigratedText(jsonStr string) string {
	if !strings.Contains(jsonStr, `"initialization_equations"`) && !strings.Contains(jsonStr, `"ic"`) {
		return jsonStr
	}
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return jsonStr
	}
	sites, err := migrateInitializationEquations(view)
	if err != nil || len(sites) == 0 && !strings.Contains(jsonStr, `"initialization_equations"`) {
		return jsonStr
	}
	out, err := json.Marshal(view)
	if err != nil {
		return jsonStr
	}
	return string(out)
}

// migrateInitializationEquations rewrites, in place, every model's
// `initialization_equations` and every pre-2.5.0 initial condition of a
// parameter (esm-spec §11.4.4), and returns the sites the `deprecated_field`
// warning names. Idempotent: a second pass finds nothing.
func migrateInitializationEquations(doc map[string]any) ([]string, error) {
	var sites []string
	below250 := declaresBelow250(doc)
	models, _ := doc["models"].(map[string]any)
	for _, k := range sortedKeys(models) {
		if m, ok := models[k].(map[string]any); ok {
			if err := migrateModelInit(doc, m, "/models/"+escapeJSONPointerSegment(k), below250, &sites); err != nil {
				return nil, err
			}
		}
	}
	return sites, nil
}

// declaresBelow250 reports whether the document declares an esm version below
// 2.5.0.
func declaresBelow250(doc map[string]any) bool {
	v, _ := doc["esm"].(string)
	parts := strings.SplitN(v, ".", 3)
	if len(parts) < 2 {
		return false
	}
	major, err1 := strconv.Atoi(parts[0])
	minor, err2 := strconv.Atoi(parts[1])
	return err1 == nil && err2 == nil && (major < 2 || major == 2 && minor < 5)
}

// parameterTarget is k when lhs is ic(k) — or, with bareToo, the bare name k —
// and k is a declared parameter of model.
func parameterTarget(model map[string]any, lhs any, bareToo bool) (string, bool) {
	k, ok := icTarget(lhs)
	if bare, isName := lhs.(string); bareToo && isName {
		k, ok = bare, true
	}
	return k, ok && resolveDeclared(model, []string{k}) == declaredParameter
}

// moveParameterInitialConditions is esm-spec §11.4.4 "An initial condition of
// a parameter": each pre-2.5.0 initial condition of a declared parameter k of
// model becomes k's `default` (replacing one it declares) and its equation is
// removed. Those are the `initialization_equations` entries whose left-hand
// side is k or ic(k) and, below esm 2.5.0, the `equations` entries whose
// left-hand side is exactly ic(k). A right-hand side that is not a number is
// `ic_invalid_argument`. It returns the indices of the remaining
// initialization equations.
func moveParameterInitialConditions(model map[string]any, init []any, at string, below250 bool, sites *[]string) ([]int, error) {
	vars, _ := model["variables"].(map[string]any)
	take := func(eq any, where string, bareToo bool) (bool, error) {
		e, ok := eq.(map[string]any)
		if !ok {
			return false, nil
		}
		k, isParam := parameterTarget(model, e["lhs"], bareToo)
		if !isParam {
			return false, nil
		}
		if _, isNum := asNumber(e["rhs"]); !isNum {
			return false, &initializationError{Code: CodeICInvalidArgument, Path: where, Message: fmt.Sprintf(
				"%s: an initial condition of the parameter `%s` is read as its `default` "+
					"(esm-spec §11.4.4), which must be a number", where, k)}
		}
		if v, ok := vars[k].(map[string]any); ok {
			v["default"] = e["rhs"]
		}
		return true, nil
	}
	if eqs, ok := model["equations"].([]any); ok && below250 {
		kept := make([]any, 0, len(eqs))
		for i, eq := range eqs {
			where := fmt.Sprintf("%s/equations/%d", at, i)
			moved, err := take(eq, where, false)
			if err != nil {
				return nil, err
			}
			if moved {
				*sites = append(*sites, where+" (ic of a parameter)")
			} else {
				kept = append(kept, eq)
			}
		}
		if len(kept) != len(eqs) {
			model["equations"] = kept
		}
	}
	var rest []int
	for i, eq := range init {
		moved, err := take(eq, fmt.Sprintf("%s/initialization_equations/%d", at, i), true)
		if err != nil {
			return nil, err
		}
		if !moved {
			rest = append(rest, i)
		}
	}
	return rest, nil
}

func migrateModelInit(doc, model map[string]any, at string, below250 bool, sites *[]string) error {
	init, hasField := model["initialization_equations"]
	delete(model, "initialization_equations")
	all, _ := init.([]any)
	if hasField && len(all) > 0 {
		*sites = append(*sites, at+"/initialization_equations (initialization_equations)")
	}
	rest, err := moveParameterInitialConditions(model, all, at, below250, sites)
	if err != nil {
		return err
	}
	if len(rest) > 0 && modelHasTimeDerivative(model) {
		isUnknown := func(n string) bool { return namesUnknown(doc, model, n) }
		out, _ := model["equations"].([]any)
		for _, i := range rest {
			e, ok := all[i].(map[string]any)
			if !ok {
				continue
			}
			moved := map[string]any{}
			for k, v := range e {
				if k == "lhs" || k == "rhs" {
					v = rewriteUnknownsToIc(v, isUnknown)
				}
				moved[k] = v
			}
			out = append(out, moved)
		}
		model["equations"] = out
	} else if len(rest) > 0 {
		guesses, _ := model["guesses"].(map[string]any)
		if guesses == nil {
			guesses = map[string]any{}
		}
		for _, i := range rest {
			e, _ := all[i].(map[string]any)
			lhs, isName := e["lhs"].(string)
			if !isName || resolveDeclared(model, []string{lhs}) != declaredUnknown {
				path := fmt.Sprintf("%s/initialization_equations/%d", at, i)
				return &initializationError{Code: codeDeprecatedField, Path: path, Message: path +
					": the model has no time derivative, so its initialization equations are read " +
					"as `guesses` (esm 2.5.0, esm-spec §11.4.4), and this one has no left-hand side " +
					"that is a bare unknown. Write a `guesses` entry instead"}
			}
			if _, has := guesses[lhs]; !has {
				guesses[lhs] = e["rhs"]
			}
		}
		model["guesses"] = guesses
	}
	if subs, ok := model["subsystems"].(map[string]any); ok {
		for _, k := range sortedKeys(subs) {
			if s, ok := subs[k].(map[string]any); ok {
				if err := migrateModelInit(doc, s, at+"/subsystems/"+escapeJSONPointerSegment(k), below250, sites); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// exprMentionsD reports whether e holds a `D` node anywhere.
func exprMentionsD(e any) bool {
	switch v := e.(type) {
	case []any:
		for _, x := range v {
			if exprMentionsD(x) {
				return true
			}
		}
	case map[string]any:
		if v["op"] == "D" {
			return true
		}
		for _, x := range v {
			if exprMentionsD(x) {
				return true
			}
		}
	}
	return false
}

func modelHasTimeDerivative(model map[string]any) bool {
	eqs, _ := model["equations"].([]any)
	for _, eq := range eqs {
		if e, ok := eq.(map[string]any); ok && exprMentionsD(e["lhs"]) {
			return true
		}
	}
	return false
}

// declaredKind is what a name declares: an unknown, a parameter, a species, or
// nothing found.
type declaredKind int

const (
	declaredNothing declaredKind = iota
	declaredUnknown
	declaredParameter
	declaredSpecies
)

// resolveDeclared resolves a dotted name, segment by segment, from a model or
// reaction system (raw view).
func resolveDeclared(container any, parts []string) declaredKind {
	c, ok := container.(map[string]any)
	if !ok || len(parts) == 0 {
		return declaredNothing
	}
	if len(parts) == 1 {
		vars, _ := c["variables"].(map[string]any)
		if v, ok := vars[parts[0]].(map[string]any); ok {
			switch v["type"] {
			case "unknown":
				return declaredUnknown
			case "parameter":
				return declaredParameter
			}
		}
		if species, ok := c["species"].(map[string]any); ok {
			if _, has := species[parts[0]]; has {
				return declaredSpecies
			}
		}
		if params, ok := c["parameters"].(map[string]any); ok {
			if _, has := params[parts[0]]; has {
				return declaredParameter
			}
		}
		return declaredNothing
	}
	subs, _ := c["subsystems"].(map[string]any)
	return resolveDeclared(subs[parts[0]], parts[1:])
}

// declaredAs is what name, read in model, declares: a local variable, else a
// scoped name resolved from the model's subsystems, then from the document's
// models and reaction systems.
func declaredAs(doc, model map[string]any, name string) declaredKind {
	parts := strings.Split(name, ".")
	if d := resolveDeclared(model, parts); d != declaredNothing || len(parts) < 2 {
		return d
	}
	for _, key := range []string{"models", "reaction_systems"} {
		if top, ok := doc[key].(map[string]any); ok {
			if d := resolveDeclared(top[parts[0]], parts[1:]); d != declaredNothing {
				return d
			}
		}
	}
	return declaredNothing
}

// namesUnknown reports whether name, read in model, names an unknown (a
// variable or a species).
func namesUnknown(doc, model map[string]any, name string) bool {
	d := declaredAs(doc, model, name)
	return d == declaredUnknown || d == declaredSpecies
}

func icOf(arg any) map[string]any {
	return map[string]any{"op": "ic", "args": []any{arg}}
}

// migratedExprFields are the expression-valued fields of a raw node the
// migration rewrites (the fields exprChildren walks).
var migratedExprFields = map[string]bool{
	"args": true, "values": true, "expr": true, "filter": true,
	"lower": true, "upper": true, "key": true, "bindings": true,
}

// rewriteUnknownsToIc is e with every unknown w replaced by ic(w) and every
// time derivative D(w) of an unknown (wrt absent or `t`) by ic(D(w)), through
// every expression-valued field. An `ic` node is left as it is.
func rewriteUnknownsToIc(e any, isUnknown func(string) bool) any {
	switch v := e.(type) {
	case string:
		if isUnknown(v) {
			return icOf(v)
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, x := range v {
			out[i] = rewriteUnknownsToIc(x, isUnknown)
		}
		return out
	case map[string]any:
		op, isOp := v["op"].(string)
		if !isOp || op == "ic" {
			return v
		}
		if wrt, _ := v["wrt"].(string); op == "D" && (wrt == "" || wrt == "t") {
			if args, ok := v["args"].([]any); ok && len(args) > 0 {
				if n, ok := args[0].(string); ok && isUnknown(n) {
					return icOf(v)
				}
			}
		}
		out := map[string]any{}
		for k, x := range v {
			switch {
			case k == "bindings":
				if b, ok := x.(map[string]any); ok {
					nb := make(map[string]any, len(b))
					for bk, bv := range b {
						nb[bk] = rewriteUnknownsToIc(bv, isUnknown)
					}
					x = nb
				}
			case migratedExprFields[k]:
				x = rewriteUnknownsToIc(x, isUnknown)
			}
			out[k] = x
		}
		return out
	}
	return e
}

// icArgumentName is the name an `ic` node reads (u of ic(u) or ic(D(u))); ok
// is false when its argument is malformed.
func icArgumentName(args []any) (string, bool) {
	if len(args) != 1 {
		return "", false
	}
	switch a := args[0].(type) {
	case string:
		return a, true
	case map[string]any:
		dargs, _ := a["args"].([]any)
		if a["op"] == "D" && len(dargs) == 1 {
			n, ok := dargs[0].(string)
			return n, ok
		}
	}
	return "", false
}

// checkIcArguments is the load-time check of every `ic` node of the raw
// document (esm-spec §4.2, the `ic` row), refused with `ic_invalid_argument`
// naming the node's location:
//
//   - its argument must be a variable reference or D of one: an element is
//     index(ic(u), i), never ic(index(u, i));
//   - inside a model, that reference must not name a declared parameter (bare,
//     or scoped to another component): a parameter has no starting value.
func checkIcArguments(doc map[string]any) error {
	return checkIcNode(doc, doc, "", nil)
}

// checkIcNode walks n at pointer at; model is the model whose scope n sits in,
// nil outside a model and under `operators` (whose bodies name template
// parameters).
func checkIcNode(doc map[string]any, n any, at string, model map[string]any) error {
	switch v := n.(type) {
	case []any:
		for i, x := range v {
			if err := checkIcNode(doc, x, fmt.Sprintf("%s/%d", at, i), model); err != nil {
				return err
			}
		}
	case map[string]any:
		if v["op"] == "ic" {
			args, _ := v["args"].([]any)
			name, ok := icArgumentName(args)
			if !ok {
				where := pointerOrRoot(at)
				return &initializationError{Code: CodeICInvalidArgument, Path: where, Message: where +
					": the argument of `ic` must be a variable reference or `D` of one (esm-spec " +
					"§4.2); an element of an array unknown is written `index(ic(u), i)`, not " +
					"`ic(index(u, i))`"}
			}
			if model != nil && declaredAs(doc, model, name) == declaredParameter {
				where := pointerOrRoot(at)
				return &initializationError{Code: CodeICInvalidArgument, Path: where, Message: fmt.Sprintf(
					"%s: `ic(%s)` names a parameter, which has no starting value; `ic` reads the "+
						"starting value of an unknown (esm-spec §4.2). Write `%s` for the parameter's value",
					where, name, name)}
			}
		}
		for _, k := range sortedKeys(v) {
			child, scope := v[k], model
			switch {
			case k == "operators":
				scope = nil
			case (k == "models" && at == "") || (k == "subsystems" && model != nil):
				comps, _ := child.(map[string]any)
				for _, name := range sortedKeys(comps) {
					m, _ := comps[name].(map[string]any)
					p := at + "/" + k + "/" + escapeJSONPointerSegment(name)
					if err := checkIcNode(doc, comps[name], p, m); err != nil {
						return err
					}
				}
				continue
			}
			if err := checkIcNode(doc, child, at+"/"+escapeJSONPointerSegment(k), scope); err != nil {
				return err
			}
		}
	}
	return nil
}

// validateInitializationOverdetermination reports the one balance finding a
// document shows by itself (esm 2.5.0, esm-spec §11.4.3 "What validate
// reports"); see overdeterminedInitialization. Mirrors the other four
// bindings.
func (s *structuralScan) validateInitializationOverdetermination(model *Model, basePath string) {
	equations, cells, unknowns, found := overdeterminedInitialization(model, s.file.IndexSets)
	if !found {
		return
	}
	s.addErr(StructuralError{
		Path: basePath + "/equations",
		Code: CodeICSystemUnbalanced,
		Message: fmt.Sprintf("the initialization system is over-determined: its %d scalar "+
			"equation(s) that are not explicit initial conditions mention %d starting value "+
			"cell(s) that no explicit initial condition sets (esm-spec §11.4.3)", equations, cells),
		Details: map[string]any{
			"direction": "over-determined",
			"equations": equations,
			"unknowns":  unknowns,
		},
	})
}
