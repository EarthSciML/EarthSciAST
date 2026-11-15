package docfmt

// An equation as math: `lhs = rhs` is the math of the expression
// `==(lhs, rhs)`. Port of formal/Esm/Document/Source/Equation.lean (Rust:
// document/source/equation.rs); prefix `eqn`.

// eqnEqExpr is `Source.eqExpr`: the expression an equation is printed as.
func eqnEqExpr(e *Eqn) Json {
	return Obj{{"args", []Json{e.Lhs, e.Rhs}}, {"op", "=="}}
}

// eqnEqSides is `Source.eqSides`: the equation sides of a parsed `==` node.
func eqnEqSides(j Json) (Json, Json, bool) {
	kvs, ok := j.(Obj)
	if !ok || len(kvs) != 2 || kvs[0].K != "args" || kvs[1].K != "op" {
		return nil, nil, false
	}
	xs, ok1 := kvs[0].V.([]Json)
	op, ok2 := kvs[1].V.(string)
	if !ok1 || !ok2 || op != "==" || len(xs) != 2 {
		return nil, nil, false
	}
	return xs[0], xs[1], true
}
