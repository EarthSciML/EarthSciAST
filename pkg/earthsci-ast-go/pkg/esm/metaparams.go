package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// Metaparameters (esm-spec §9.7.6)
// ---------------------------------------------------------------------------

// metaparamInt coerces a JSON value to an exact int64 metaparameter value.
// json.Number tokens must have integer grammar (no '.', 'e', 'E'); native ints
// pass through; anything else (floats, bools, strings, objects) is
// `metaparameter_type_error`. A float64 is accepted only when integral —
// a plain-decoded (non-UseNumber) view cannot distinguish 4 from 4.0.
func metaparamInt(v interface{}, ctx string) (int64, error) {
	switch n := v.(type) {
	case json.Number:
		if !strings.ContainsAny(string(n), ".eE") {
			if i, err := n.Int64(); err == nil {
				return i, nil
			}
		}
	case int:
		return int64(n), nil
	case int32:
		return int64(n), nil
	case int64:
		return n, nil
	case float64:
		if n == math.Trunc(n) && n >= math.MinInt64 && n <= math.MaxInt64 {
			return int64(n), nil
		}
	}
	return 0, newETErr(
		CodeMetaparamTypeError,
		fmt.Sprintf("%s: value %v is not an integer (esm-spec §9.7.6)", ctx, v),
	)
}

// collectMetaparamDecls reads a document's / library's `metaparameters` block
// into an order-preserving map of name → validated declaration (esm-spec
// §9.7.6). Each declaration must be an object with `type: "integer"` (the only
// kind) and, if present, an integer `default`; a violation raises
// `metaparameter_type_error`. An absent/nil block yields an empty map. `order`
// is the declaration order recovered from the raw JSON.
func collectMetaparamDecls(raw map[string]interface{}, origin string, order []string) (*orderedMap, error) {
	out := newOrderedMap()
	mpRaw, has := raw["metaparameters"]
	if !has || mpRaw == nil {
		return out, nil
	}
	mp, ok := mpRaw.(map[string]interface{})
	if !ok {
		return nil, newETErr(CodeMetaparamTypeError,
			fmt.Sprintf("%s: `metaparameters` must be an object", origin))
	}
	for _, name := range orderedKeysOf(mp, order) {
		decl, ok := mp[name].(map[string]interface{})
		if !ok {
			return nil, newETErr(CodeMetaparamTypeError,
				fmt.Sprintf("%s: metaparameters.%s must be an object with `type: \"integer\"`", origin, name))
		}
		if t, _ := decl["type"].(string); t != "integer" {
			return nil, newETErr(CodeMetaparamTypeError,
				fmt.Sprintf("%s: metaparameters.%s: `type` must be \"integer\" (the only kind)", origin, name))
		}
		if d, has := decl["default"]; has && d != nil {
			if _, err := metaparamInt(d, fmt.Sprintf("%s: metaparameters.%s default", origin, name)); err != nil {
				return nil, err
			}
		}
		out.set(name, deepCopyJSON(decl))
	}
	return out, nil
}

// metaSubstSkipKeys: keys whose VALUES are never expression positions —
// metaparameter names are substituted as bare variable-reference strings, so
// structural string fields must not be rewritten. Template `params` shadowing
// is handled separately in substituteMetaparamsDecl.
var metaSubstSkipKeys = map[string]struct{}{
	"metadata": {}, "params": {}, "type": {}, "units": {}, "kind": {},
	"description": {}, "name": {}, "wrt": {},
	"expression_template_imports": {}, "metaparameters": {}, "only": {},
	// `where` match-scoping constraints (esm-spec §9.6.1) carry index-set
	// NAMES, a structural namespace — never expression positions.
	"where": {},
}

// substituteMetaparams substitutes bound metaparameter names — appearing as
// bare strings, the variable-reference surface syntax — with their bound
// VALUES, everywhere except the metaSubstSkipKeys structural fields (esm-spec
// §9.7.6: expression-position substitution; no folding here). Returns a new
// tree; the input is not modified. A bound value is usually an integer literal
// (the document-close and folded-edge cases) but may be a metaparameter
// EXPRESSION (a `{op, args}` tree over the importer's still-open metaparameters,
// e.g. `NX*NY`) at an import edge — carried symbolically until the importer
// closes (esm-spec §9.7.6 binding value flow).
func substituteMetaparams(x interface{}, values map[string]interface{}) interface{} {
	switch v := x.(type) {
	case string:
		if i, ok := values[v]; ok {
			return i
		}
		return v
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			out[i] = substituteMetaparams(c, values)
		}
		return out
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, c := range v {
			if _, skip := metaSubstSkipKeys[k]; skip {
				out[k] = deepCopyJSON(c)
			} else {
				out[k] = substituteMetaparams(c, values)
			}
		}
		return out
	}
	return x
}

// substituteMetaparamsDecl applies metaparameter substitution over one
// `expression_templates` entry: the template's own `params` shadow like-named
// metaparameters inside its `body` and `match` (a param is the inner binder;
// substitution must not capture it).
func substituteMetaparamsDecl(decl interface{}, values map[string]interface{}) interface{} {
	declObj, ok := decl.(map[string]interface{})
	if !ok {
		return substituteMetaparams(decl, values)
	}
	shadowed := values
	if params, ok := declObj["params"].([]interface{}); ok {
		shadow := false
		pset := map[string]struct{}{}
		for _, p := range params {
			if ps, ok := p.(string); ok {
				pset[ps] = struct{}{}
				if _, bound := values[ps]; bound {
					shadow = true
				}
			}
		}
		if shadow {
			shadowed = make(map[string]interface{}, len(values))
			for k, v := range values {
				if _, isParam := pset[k]; !isParam {
					shadowed[k] = v
				}
			}
		}
	}
	return substituteMetaparams(decl, shadowed)
}

func overflowErr(ctx string) error {
	return newETErr(CodeMetaparamTypeError,
		fmt.Sprintf("%s: 64-bit integer overflow while folding a metaparameter expression", ctx))
}

func checkedAdd(a, b int64, ctx string) (int64, error) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedSub(a, b int64, ctx string) (int64, error) {
	c := a - b
	if (b < 0 && c < a) || (b > 0 && c > a) {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedMul(a, b int64, ctx string) (int64, error) {
	if a == 0 || b == 0 {
		return 0, nil
	}
	if a == math.MinInt64 && b == -1 || b == math.MinInt64 && a == -1 {
		return 0, overflowErr(ctx)
	}
	c := a * b
	if c/b != a {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedNeg(a int64, ctx string) (int64, error) {
	if a == math.MinInt64 {
		return 0, overflowErr(ctx)
	}
	return -a, nil
}

// tryFold folds a metaparameter expression (integer literal, name, or
// {op, args} over + - * /) to a concrete int64 with exact 64-bit arithmetic
// (esm-spec §9.7.6). folded=false (with err == nil) means the expression still
// contains a bare name (an open metaparameter awaiting a later binding site,
// or a template-param slot inside a rule body) — the site is left symbolic for
// a later pass. Errors carry `metaparameter_type_error`: a non-integer
// literal, an op outside + - * / over concrete args, inexact division, or
// 64-bit overflow.
func tryFold(x interface{}, ctx string) (val int64, folded bool, err error) {
	switch v := x.(type) {
	case string:
		return 0, false, nil
	case json.Number:
		if !strings.ContainsAny(string(v), ".eE") {
			if i, e := v.Int64(); e == nil {
				return i, true, nil
			}
		}
		return 0, false, newETErr(CodeMetaparamTypeError,
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case int:
		return int64(v), true, nil
	case int32:
		return int64(v), true, nil
	case int64:
		return v, true, nil
	case float64:
		return 0, false, newETErr(CodeMetaparamTypeError,
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case bool:
		return 0, false, newETErr(CodeMetaparamTypeError,
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case map[string]interface{}:
		opRaw, hasOp := v["op"]
		argsRaw, hasArgs := v["args"]
		args, argsOk := argsRaw.([]interface{})
		if !hasOp || !hasArgs || !argsOk || len(args) == 0 {
			return 0, false, newETErr(CodeMetaparamTypeError,
				fmt.Sprintf("%s: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})", ctx))
		}
		vals := make([]int64, len(args))
		for i, a := range args {
			av, af, aerr := tryFold(a, ctx)
			if aerr != nil {
				return 0, false, aerr
			}
			if !af {
				return 0, false, nil
			}
			vals[i] = av
		}
		op, _ := opRaw.(string)
		if op != "+" && op != "-" && op != "*" && op != "/" {
			return 0, false, newETErr(CodeMetaparamTypeError,
				fmt.Sprintf("%s: op '%s' is not allowed in a metaparameter expression (only + - * /)", ctx, op))
		}
		acc := vals[0]
		if op == "-" && len(vals) == 1 {
			n, e := checkedNeg(acc, ctx)
			return n, e == nil, e
		}
		for _, v2 := range vals[1:] {
			switch op {
			case "+":
				acc, err = checkedAdd(acc, v2, ctx)
			case "-":
				acc, err = checkedSub(acc, v2, ctx)
			case "*":
				acc, err = checkedMul(acc, v2, ctx)
			case "/":
				if v2 == 0 {
					return 0, false, newETErr(CodeMetaparamTypeError,
						fmt.Sprintf("%s: division by zero", ctx))
				}
				if acc%v2 != 0 {
					return 0, false, newETErr(CodeMetaparamTypeError,
						fmt.Sprintf("%s: %d / %d does not divide exactly (esm-spec §9.7.6)", ctx, acc, v2))
				}
				acc = acc / v2
			}
			if err != nil {
				return 0, false, err
			}
		}
		return acc, true, nil
	}
	return 0, false, newETErr(CodeMetaparamTypeError,
		fmt.Sprintf("%s: invalid metaparameter expression (expected integer, name, or {op, args})", ctx))
}

// collectMetaNames accumulates every bare-string leaf of a metaparameter
// expression into out (the `op` discriminator of a `{op, args}` node is
// skipped). Used to report the free names of an expression that failed to fold
// (evalMetaExpr / foldIndexSetSizes diagnostics).
func collectMetaNames(out *[]string, x interface{}) {
	switch v := x.(type) {
	case string:
		*out = append(*out, v)
	case []interface{}:
		for _, c := range v {
			collectMetaNames(out, c)
		}
	case map[string]interface{}:
		for _, k := range sortedKeys(v) {
			if k == "op" {
				continue
			}
			collectMetaNames(out, v[k])
		}
	}
}

// isIntToken reports whether v is an already-concrete integer literal — a
// json.Number with integer grammar (no '.', 'e', 'E') or a native int type.
// Used to skip structural sites that need no metaparameter folding.
func isIntToken(v interface{}) bool {
	switch n := v.(type) {
	case json.Number:
		return !strings.ContainsAny(string(n), ".eE")
	case int, int32, int64:
		return true
	}
	return false
}

// validateMetaExpr is the structural grammar check for a metaparameter
// expression (esm-spec §9.7.6), independent of whether its names are yet
// concrete: an integer literal, a name string, or `{op: +|-|*|/, args:
// [...non-empty...]}` recursively. Unlike tryFold (which defers op-validation
// until every arg is concrete), this catches an inadmissible op (`%`), a
// missing/empty `args`, or a float literal at the binding EDGE even when an
// arg is still a symbolic importer name. Mirrors the Python reference
// `_validate_meta_expr`.
func validateMetaExpr(x interface{}, ctx string) error {
	switch v := x.(type) {
	case string:
		// A bare name (variable-reference surface syntax) — always structurally
		// admissible; whether it is in scope is decided at fold time.
		return nil
	case map[string]interface{}:
		op, _ := v["op"].(string)
		argsRaw, hasArgs := v["args"]
		args, argsOk := argsRaw.([]interface{})
		if (op != "+" && op != "-" && op != "*" && op != "/") || !hasArgs || !argsOk || len(args) == 0 {
			return newETErr(CodeMetaparamTypeError,
				fmt.Sprintf("%s: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})", ctx))
		}
		for _, a := range args {
			if err := validateMetaExpr(a, ctx); err != nil {
				return err
			}
		}
		return nil
	}
	// A numeric leaf must be an integer literal. metaparamInt is the shared
	// integer gate — it accepts json.Number integer grammar, native ints, and
	// an integral float64 (the Go non-UseNumber compromise: 4 and 4.0 are
	// indistinguishable), and rejects a fractional literal like 1.5, a bool,
	// or a stray array — so the admissible-literal set here matches every other
	// metaparameter site exactly.
	if _, err := metaparamInt(x, ctx); err != nil {
		return newETErr(CodeMetaparamTypeError,
			fmt.Sprintf("%s: invalid metaparameter expression (expected integer, name, or {op, args})", ctx))
	}
	return nil
}

// requireMetaExpr validates that v is a *metaparameter expression* (esm-spec
// §9.7.6) — an integer literal, a metaparameter-name string, or a `{op:
// +|-|*|/, args}` tree over the same — and returns it UNCHANGED (unfolded);
// its free names close at a later binding site. Raises `metaparameter_type_error`
// on an inadmissible node. This is the relaxed replacement for the integer-only
// gate (metaparamInt) at the metaparameter *binding* sites (import edge /
// subsystem edge): a binding may now derive a child metaparameter from an
// arithmetic combination of the importer's metaparameters (e.g. `NTGT = NX*NY`),
// which import renaming (name→name) could not express. Mirrors the Python
// reference `require_meta_expr`.
func requireMetaExpr(v interface{}, ctx string) (interface{}, error) {
	if err := validateMetaExpr(v, ctx); err != nil {
		return nil, err
	}
	return v, nil
}

// coerceMetaExprInts normalizes the numeric leaves of a metaparameter
// expression to int64 so tryFold (which folds only int64 / integer-grammar
// json.Number leaves) accepts values that arrived from a non-UseNumber JSON
// decode as integral float64 — the same 4-vs-4.0 compromise metaparamInt makes
// at every other metaparameter site. Non-integral / non-integer literals are
// left untouched so tryFold raises the metaparameter_type_error. Strings
// (names) and structure are preserved.
func coerceMetaExprInts(x interface{}) interface{} {
	switch v := x.(type) {
	case json.Number:
		if !strings.ContainsAny(string(v), ".eE") {
			if i, err := v.Int64(); err == nil {
				return i
			}
		}
		return v
	case float64:
		if v == math.Trunc(v) && v >= math.MinInt64 && v <= math.MaxInt64 {
			return int64(v)
		}
		return v
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			out[i] = coerceMetaExprInts(c)
		}
		return out
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, c := range v {
			out[k] = coerceMetaExprInts(c)
		}
		return out
	}
	return x
}

// evalMetaExpr folds a metaparameter expression to a concrete int64 against a
// CLOSED environment env (name → int) — the importing document's metaparameter
// scope (esm-spec §9.7.6 binding value flow). Substitutes the env names, then
// folds with the exact-integer tryFold arithmetic (`/` must divide exactly;
// 64-bit overflow is an error). Raises `template_import_unknown_name` if the
// expression references a name absent from env — the mount-edge typo failure,
// keeping error locality at the edge that authored the expression. Mirrors the
// Python reference `eval_meta_expr`.
func evalMetaExpr(expr interface{}, env map[string]int64, ctx string) (int64, error) {
	envAny := make(map[string]interface{}, len(env))
	for k, v := range env {
		envAny[k] = v
	}
	val, folded, err := tryFold(coerceMetaExprInts(substituteMetaparams(expr, envAny)), ctx)
	if err != nil {
		return 0, err
	}
	if !folded {
		var names []string
		collectMetaNames(&names, expr)
		seen := map[string]bool{}
		var free []string
		for _, n := range names {
			if _, ok := env[n]; !ok && !seen[n] {
				seen[n] = true
				free = append(free, n)
			}
		}
		sort.Strings(free)
		which := strings.Join(free, ", ")
		if which == "" {
			which = "a name"
		}
		return 0, newETErr(CodeTemplateImportUnknownName,
			fmt.Sprintf("%s: metaparameter expression references %s not in the importing document's metaparameter scope (esm-spec §9.7.6)", ctx, which))
	}
	return val, nil
}

// foldStructuralSites folds metaparameter expressions in the structural
// integer sites — `aggregate` dense `ranges` tuple entries and `makearray`
// `regions` bound pairs — to concrete integers, in place, wherever they are
// already closed. Entries still carrying a bare name (a template-param slot,
// or an open metaparameter in a not-yet-fully-bound library) are left symbolic
// for a later binding site. Index-set sizes are folded separately by
// foldIndexSetSizes.
func foldStructuralSites(x interface{}, ctx string) error {
	switch v := x.(type) {
	case []interface{}:
		for _, c := range v {
			if err := foldStructuralSites(c, ctx); err != nil {
				return err
			}
		}
		return nil
	case map[string]interface{}:
		op, _ := v["op"].(string)
		if op == "aggregate" {
			if ranges, ok := v["ranges"].(map[string]interface{}); ok {
				for _, k := range sortedKeys(ranges) {
					rv, ok := ranges[k].([]interface{})
					if !ok {
						continue // {from: ...} index-set refs untouched
					}
					for i, entry := range rv {
						if isIntToken(entry) {
							continue
						}
						f, folded, err := tryFold(entry, fmt.Sprintf("%s: aggregate ranges.%s", ctx, k))
						if err != nil {
							return err
						}
						if folded {
							rv[i] = f
						}
					}
				}
			}
		} else if op == "makearray" {
			if regions, ok := v["regions"].([]interface{}); ok {
				for _, regionRaw := range regions {
					region, ok := regionRaw.([]interface{})
					if !ok {
						continue
					}
					for _, boundsRaw := range region {
						bounds, ok := boundsRaw.([]interface{})
						if !ok {
							continue
						}
						for i, entry := range bounds {
							if isIntToken(entry) {
								continue
							}
							f, folded, err := tryFold(entry, ctx+": makearray regions bound")
							if err != nil {
								return err
							}
							if folded {
								bounds[i] = f
							}
						}
					}
				}
			}
		}
		for _, k := range sortedKeys(v) {
			if err := foldStructuralSites(v[k], ctx); err != nil {
				return err
			}
		}
		return nil
	}
	return nil
}

// foldIndexSetSizes folds interval `size` metaparameter expressions in an
// `index_sets` registry. With strict=true (the root document, after its
// metaparameters closed) any remaining bare name is `metaparameter_unbound`;
// with strict=false (a library instantiated at an edge that left some
// metaparameters open) open sizes stay symbolic and close at a later binding
// site.
func foldIndexSetSizes(indexSets *orderedMap, ctx string, strict bool) error {
	for _, name := range indexSets.keys {
		decl, ok := indexSets.m[name].(map[string]interface{})
		if !ok {
			continue
		}
		sz, has := decl["size"]
		if !has || sz == nil || isIntToken(sz) {
			continue
		}
		f, folded, err := tryFold(sz, fmt.Sprintf("%s: index_sets.%s.size", ctx, name))
		if err != nil {
			return err
		}
		if !folded {
			if strict {
				var names []string
				collectMetaNames(&names, sz)
				seen := map[string]bool{}
				uniq := []string{}
				for _, n := range names {
					if !seen[n] {
						uniq = append(uniq, n)
						seen[n] = true
					}
				}
				return newETErr("metaparameter_unbound",
					fmt.Sprintf("%s: index_sets.%s.size references unbound name(s) %s (esm-spec §9.7.6)",
						ctx, name, strings.Join(uniq, ", ")))
			}
			continue
		}
		decl["size"] = f
	}
	return nil
}
