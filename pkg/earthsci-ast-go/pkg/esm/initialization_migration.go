package esm

import (
	"encoding/json"
	"fmt"
	"os"
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
//     refused with `deprecated_field`.
//
// The field is removed either way, with one `deprecated_field` warning per
// document naming every migrated block.

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
	var sites []string
	if hasField {
		sites, err = migrateInitializationEquations(view)
		if err != nil {
			return "", err
		}
	}
	if err := checkIcArguments(view, ""); err != nil {
		return "", err
	}
	if len(sites) == 0 {
		return jsonStr, nil
	}
	out, err := json.Marshal(view)
	if err != nil {
		return jsonStr, nil
	}
	fmt.Fprintf(os.Stderr,
		"warning: %s: `initialization_equations` is deprecated (esm 2.5.0, esm-spec §11.4.4); "+
			"each equation was rewritten into an `ic` equation in `equations` (or into "+
			"`guesses` for a model with no time derivative). Read at: %s.\n",
		codeDeprecatedField, strings.Join(sites, ", "))
	return string(out), nil
}

// migrateInitializationEquations rewrites every model's block in place and
// returns the migrated sites.
func migrateInitializationEquations(doc map[string]any) ([]string, error) {
	var sites []string
	models, _ := doc["models"].(map[string]any)
	for _, k := range sortedKeys(models) {
		if m, ok := models[k].(map[string]any); ok {
			if err := migrateModelInit(doc, m, "/models/"+escapeJSONPointerSegment(k), &sites); err != nil {
				return nil, err
			}
		}
	}
	return sites, nil
}

func migrateModelInit(doc, model map[string]any, at string, sites *[]string) error {
	if init, present := model["initialization_equations"]; present {
		delete(model, "initialization_equations")
		eqs, _ := init.([]any)
		if len(eqs) > 0 {
			*sites = append(*sites, at+"/initialization_equations (initialization_equations)")
			if modelHasTimeDerivative(model) {
				isUnknown := func(n string) bool { return namesUnknown(doc, model, n) }
				out, _ := model["equations"].([]any)
				for _, eq := range eqs {
					e, ok := eq.(map[string]any)
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
			} else {
				vars, _ := model["variables"].(map[string]any)
				guesses, _ := model["guesses"].(map[string]any)
				if guesses == nil {
					guesses = map[string]any{}
				}
				for i, eq := range eqs {
					e, _ := eq.(map[string]any)
					lhs, isName := e["lhs"].(string)
					if !isName || !isUnknownVar(vars[lhs]) {
						return fmt.Errorf("%s: %s/initialization_equations/%d: the model has no time "+
							"derivative, so its initialization equations are read as `guesses` "+
							"(esm 2.5.0, esm-spec §11.4.4), and this one has no left-hand side that "+
							"is a bare unknown. Write a `guesses` entry instead",
							codeDeprecatedField, at, i)
					}
					if _, has := guesses[lhs]; !has {
						guesses[lhs] = e["rhs"]
					}
				}
				model["guesses"] = guesses
			}
		}
	}
	if subs, ok := model["subsystems"].(map[string]any); ok {
		for _, k := range sortedKeys(subs) {
			if s, ok := subs[k].(map[string]any); ok {
				if err := migrateModelInit(doc, s, at+"/subsystems/"+escapeJSONPointerSegment(k), sites); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

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
		return exprMentionsD(v["args"]) || exprMentionsD(v["expr"])
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

func isUnknownVar(v any) bool {
	m, ok := v.(map[string]any)
	return ok && m["type"] == "unknown"
}

// resolvesToUnknown resolves a dotted name, segment by segment, from a model
// or reaction system.
func resolvesToUnknown(container any, parts []string) bool {
	c, ok := container.(map[string]any)
	if !ok || len(parts) == 0 {
		return false
	}
	if len(parts) == 1 {
		if vars, ok := c["variables"].(map[string]any); ok && isUnknownVar(vars[parts[0]]) {
			return true
		}
		species, ok := c["species"].(map[string]any)
		if !ok {
			return false
		}
		_, has := species[parts[0]]
		return has
	}
	subs, _ := c["subsystems"].(map[string]any)
	return resolvesToUnknown(subs[parts[0]], parts[1:])
}

func namesUnknown(doc, model map[string]any, name string) bool {
	parts := strings.Split(name, ".")
	if resolvesToUnknown(model, parts) {
		return true
	}
	if len(parts) < 2 {
		return false
	}
	for _, key := range []string{"models", "reaction_systems"} {
		if top, ok := doc[key].(map[string]any); ok && resolvesToUnknown(top[parts[0]], parts[1:]) {
			return true
		}
	}
	return false
}

func icOf(arg any) map[string]any {
	return map[string]any{"op": "ic", "args": []any{arg}}
}

// rewriteUnknownsToIc is e with every unknown w replaced by ic(w) and every
// D(w) by ic(D(w)).
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
		if !isOp {
			return v
		}
		if op == "D" {
			if args, ok := v["args"].([]any); ok && len(args) > 0 {
				if n, ok := args[0].(string); ok && isUnknown(n) {
					return icOf(v)
				}
			}
		}
		out := map[string]any{}
		for k, x := range v {
			switch k {
			case "args", "expr", "filter", "values":
				out[k] = rewriteUnknownsToIc(x, isUnknown)
			default:
				out[k] = x
			}
		}
		return out
	}
	return e
}

// checkIcArguments refuses an `ic` whose argument is neither a variable
// reference nor D of one (esm-spec §4.2): an element is index(ic(u), i), never
// ic(index(u, i)).
func checkIcArguments(n any, at string) error {
	switch v := n.(type) {
	case []any:
		for i, x := range v {
			if err := checkIcArguments(x, fmt.Sprintf("%s/%d", at, i)); err != nil {
				return err
			}
		}
	case map[string]any:
		if v["op"] == "ic" {
			args, _ := v["args"].([]any)
			ok := false
			if len(args) == 1 {
				switch a := args[0].(type) {
				case string:
					ok = true
				case map[string]any:
					dargs, _ := a["args"].([]any)
					if a["op"] == "D" && len(dargs) == 1 {
						_, ok = dargs[0].(string)
					}
				}
			}
			if !ok {
				return fmt.Errorf("%s: the argument of `ic` must be a variable reference or `D` of "+
					"one (esm-spec §4.2); an element of an array unknown is written "+
					"`index(ic(u), i)`, not `ic(index(u, i))`", pointerOrRoot(at))
			}
		}
		for _, k := range sortedKeys(v) {
			if err := checkIcArguments(v[k], at+"/"+escapeJSONPointerSegment(k)); err != nil {
				return err
			}
		}
	}
	return nil
}
