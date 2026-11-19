package docfmt

// Expressions as JSON values, and the symbol table. Port of
// formal/Esm/Document/Math/Expr.lean (Rust: document/math/expr.rs); prefix
// `expr`.
//
// An expression is the JSON value at an expression position (spec §4.1): a
// number, a name (dot-separated identifier segments), or a node (`op`, `args`
// and any other fields). exprIsE is the well-formedness check; Sym is what a
// document declares.

import "slices"

// ## Characters (`Math.isLetter` …): ASCII only.

func exprIsLetter(c rune) bool  { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
func exprIsUpper(c rune) bool   { return c >= 'A' && c <= 'Z' }
func exprIsLower(c rune) bool   { return c >= 'a' && c <= 'z' }
func exprIsDig(c rune) bool     { return c >= '0' && c <= '9' }
func exprIsIdStart(c rune) bool { return exprIsLetter(c) || c == '_' }
func exprIsIdChar(c rune) bool  { return exprIsLetter(c) || exprIsDig(c) || c == '_' }

// ## Names

// exprSplitDots is `Math.splitDots`: split at every `.` (an empty input is one
// empty segment).
func exprSplitDots(cs []rune) [][]rune {
	var out [][]rune
	start := 0
	for i, c := range cs {
		if c == '.' {
			out = append(out, cs[start:i])
			start = i + 1
		}
	}
	return append(out, cs[start:])
}

// exprSegOk is `Math.segOK`: an identifier segment `[A-Za-z_][A-Za-z0-9_]*`.
func exprSegOk(cs []rune) bool {
	if len(cs) == 0 || !exprIsIdStart(cs[0]) {
		return false
	}
	for _, d := range cs[1:] {
		if !exprIsIdChar(d) {
			return false
		}
	}
	return true
}

// exprNameOk is `Math.nameOK`: dot-separated identifier segments.
func exprNameOk(s string) bool {
	for _, seg := range exprSplitDots([]rune(s)) {
		if !exprSegOk(seg) {
			return false
		}
	}
	return true
}

// exprGreek is `Math.greek`: the Greek letter names that are a LaTeX command
// and a Typst symbol.
var exprGreek = []string{
	"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
	"lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi",
	"omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi",
	"Omega",
}

// exprIsGreek is `Math.isGreek`.
func exprIsGreek(s []rune) bool { return slices.Contains(exprGreek, string(s)) }

// exprIsSingle is `Math.isSingle`: one letter, or a Greek letter name.
func exprIsSingle(s []rune) bool {
	if len(s) == 1 {
		return exprIsLetter(s[0])
	}
	return exprIsGreek(s)
}

// exprElements is `Math.elements`: the element symbols a chemical-formula name
// is built from.
var exprElements = []string{
	"H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl",
	"Ar", "K", "Ca", "Ti", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br", "Kr", "Ag", "Sn", "I",
	"Xe", "Hg", "Pb", "Rn",
}

// exprDigRun is `Math.digRun`: the maximal run of digits at the front.
func exprDigRun(cs []rune) ([]rune, []rune) {
	n := 0
	for n < len(cs) && exprIsDig(cs[n]) {
		n++
	}
	return cs[:n], cs[n:]
}

// exprLetRun is `Math.letRun`: the maximal run of letters at the front.
func exprLetRun(cs []rune) ([]rune, []rune) {
	n := 0
	for n < len(cs) && exprIsLetter(cs[n]) {
		n++
	}
	return cs[:n], cs[n:]
}

// exprPiece is a run of letters and the run of digits after it.
type exprPiece struct{ a, b []rune }

// exprPieces is `Math.pieces`: a run of letters and the run of digits after
// it, repeatedly. `CH2O` is [("CH", "2"), ("O", "")].
func exprPieces(s []rune) []exprPiece {
	var out []exprPiece
	cs := s
	for range s {
		if len(cs) == 0 {
			break
		}
		a, r := exprLetRun(cs)
		b, r := exprDigRun(r)
		if len(a) == 0 {
			break
		}
		out = append(out, exprPiece{a, b})
		cs = r
	}
	return out
}

// exprElemToks is `Math.elemToks`: an uppercase letter, then an optional
// lowercase one, greedily.
func exprElemToks(cs []rune) ([]string, bool) {
	out := []string{}
	for {
		switch {
		case len(cs) == 0:
			return out, true
		case len(cs) >= 2:
			c, d := cs[0], cs[1]
			if exprIsUpper(c) && exprIsLower(d) {
				out = append(out, string([]rune{c, d}))
				cs = cs[2:]
			} else if exprIsUpper(c) {
				out = append(out, string(c))
				cs = cs[1:]
			} else {
				return nil, false
			}
		default:
			if exprIsUpper(cs[0]) {
				return append(out, string(cs[0])), true
			}
			return nil, false
		}
	}
}

// exprIsFormula is `Math.isFormula`: letters and digits only, read as element
// symbols and counts, starting with an element, with at least two tokens.
func exprIsFormula(s []rune) bool {
	for _, c := range s {
		if !exprIsLetter(c) && !exprIsDig(c) {
			return false
		}
	}
	if len(s) == 0 || !exprIsUpper(s[0]) {
		return false
	}
	ps := exprPieces(s)
	var flat []rune
	for _, p := range ps {
		flat = append(flat, p.a...)
		flat = append(flat, p.b...)
	}
	if string(flat) != string(s) {
		return false
	}
	count := 0
	for _, p := range ps {
		ts, ok := exprElemToks(p.a)
		if !ok {
			return false
		}
		for _, t := range ts {
			if !slices.Contains(exprElements, t) {
				return false
			}
		}
		count += len(ts)
		if len(p.b) > 0 {
			count++
		}
	}
	return count >= 2
}

// exprSubParts is `Math.subParts`: the subscripted shape `b_r` (a single
// letter or Greek name, `_`, a nonempty rest): the base and the rest.
func exprSubParts(s []rune) ([]rune, []rune, bool) {
	i := slices.Index(s, '_')
	if i < 0 {
		return nil, nil, false
	}
	b, rest := s[:i], s[i+1:]
	if exprIsSingle(b) && len(rest) > 0 {
		return b, rest, true
	}
	return nil, nil, false
}

// ## Numbers and JSON well-formedness, as checks

// exprNumOk is `Math.numOK`: `JNum.WF` as a check.
func exprNumOk(n JNum) bool { return n.Wfb() }

// exprKeysSorted is `Math.keysSorted`: object keys strictly increasing.
func exprKeysSorted(kvs Obj) bool {
	for i := 1; i < len(kvs); i++ {
		if kvs[i-1].K >= kvs[i].K {
			return false
		}
	}
	return true
}

// exprJwf is `Math.jwf`: `Json.WF` as a check.
func exprJwf(j Json) bool { return JsonWfb(j) }

// ## Operators

// exprRemovedOps is `Math.removedOps`: spec §4.2 "Removed ops", refused by
// name.
var exprRemovedOps = []string{
	"arrayop", "aggregate", "fn", "table_lookup", "skolem", "rank", "argmin", "argmax",
	"polygon_intersection_area", "intersect_polygon",
}

// exprDeprecatedOps is `Math.deprecatedOps`: read in the call form and
// rewritten, never printed.
var exprDeprecatedOps = []string{"neg", "pow"}

// exprOpOk is `Math.opOK`: `[A-Za-z_][A-Za-z0-9_.]*` or `[-+*/^<>=!]+`.
func exprOpOk(s string) bool {
	cs := []rune(s)
	if len(cs) == 0 {
		return false
	}
	ident := exprIsIdStart(cs[0])
	if ident {
		for _, d := range cs[1:] {
			if !exprIsIdChar(d) && d != '.' {
				ident = false
				break
			}
		}
	}
	if ident {
		return true
	}
	for _, d := range cs {
		switch d {
		case '-', '+', '*', '/', '^', '<', '>', '=', '!':
		default:
			return false
		}
	}
	return true
}

// exprOpFieldOk is `Math.opFieldOK`: an `op` that is neither removed nor
// deprecated.
func exprOpFieldOk(kvs Obj) bool {
	v, _ := exprLook("op", kvs)
	o, ok := v.(string)
	return ok && exprOpOk(o) && !slices.Contains(exprRemovedOps, o) && !slices.Contains(exprDeprecatedOps, o)
}

// exprHasArgs is `Math.hasArgs`.
func exprHasArgs(kvs Obj) bool {
	_, ok := exprLook("args", kvs)
	return ok
}

// exprIsE is `Math.isE`: a well-formed expression (canonical form).
func exprIsE(e Json) bool {
	switch v := e.(type) {
	case JNum:
		return exprNumOk(v)
	case string:
		return exprNameOk(v)
	case Obj:
		if !exprKeysSorted(v) || !exprOpFieldOk(v) || !exprHasArgs(v) {
			return false
		}
		for _, kv := range v {
			if kv.K == "args" {
				xs, ok := kv.V.([]Json)
				if !ok {
					return false
				}
				for _, x := range xs {
					if !exprIsE(x) {
						return false
					}
				}
			} else if kv.K != "op" && !exprJwf(kv.V) {
				return false
			}
		}
		return true
	}
	return false
}

// TemplateParams is one template in scope: its name and parameter list.
type TemplateParams struct {
	Name   string
	Params []string
}

// Sym is `Math.Sym`: the names a document declares and the parameter list of
// every template in scope.
type Sym struct {
	Names     []string
	Templates []TemplateParams
}
