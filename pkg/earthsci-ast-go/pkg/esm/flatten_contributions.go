package esm

// Per-term provenance through flatten (esm-libraries-spec §4.7.5, "Per-term
// provenance"; issue #539): the types, and the helpers every flatten pass uses
// to edit a flattened equation through its contribution list.
//
// The list lives beside the expression tree, never on a node, so canonical
// form, structural equality and interning are untouched by it.

// TermOrigin names who authored one contribution to a flattened equation.
// Exactly one field is set: Component is the full dotted path of the model,
// subsystem or reaction system whose equation contained the expression
// ("Atmosphere.Chemistry"); Coupling is the 0-based index of the coupling entry
// that wrote the expression itself, counted in the coupling sequence AFTER
// coupling_import expansion (the sequence FlattenMetadata.CouplingRules lists).
//
// Its JSON form is the corpus form: {"component": path} or {"coupling": k}.
type TermOrigin struct {
	Component string `json:"component,omitempty"`
	Coupling  *int   `json:"coupling,omitempty"`
}

// Contribution is one summand of a flattened equation's right-hand side, with
// its authors.
//
// Origins is deduplicated in first-appearance order. It has more than one entry
// only where a non-additive merge (a multiplicative `couple`, or an
// `operator_compose` translate factor applied to a multi-contribution equation)
// collapsed several contributions into one indivisible expression. Flatten
// never produces an empty Origins; an equation built outside flatten may carry
// one, meaning "author unknown".
type Contribution struct {
	Expr    Expression   `json:"expr"`
	Origins []TermOrigin `json:"origins"`
}

func componentOrigin(path string) TermOrigin { return TermOrigin{Component: path} }

func couplingOrigin(index int) TermOrigin {
	k := index
	return TermOrigin{Coupling: &k}
}

func sameOrigin(a, b TermOrigin) bool {
	if (a.Coupling == nil) != (b.Coupling == nil) {
		return false
	}
	if a.Coupling != nil {
		return *a.Coupling == *b.Coupling
	}
	return a.Component == b.Component
}

// unionOrigins is every origin of contributions, then extra, deduplicated in
// first-appearance order.
func unionOrigins(contributions []Contribution, extra ...TermOrigin) []TermOrigin {
	var out []TermOrigin
	add := func(o TermOrigin) {
		for _, seen := range out {
			if sameOrigin(seen, o) {
				return
			}
		}
		out = append(out, o)
	}
	for _, c := range contributions {
		for _, o := range c.Origins {
			add(o)
		}
	}
	for _, o := range extra {
		add(o)
	}
	return out
}

// foldContributions is the right-hand side a contribution list stands for: the
// LEFT fold of the contribution expressions under binary `+` (the provenance
// invariant). A literal-zero operand is dropped from the tree; its contribution
// stays recorded.
func foldContributions(contributions []Contribution) Expression {
	rhs := contributions[0].Expr
	for _, c := range contributions[1:] {
		rhs = addExprs(rhs, c.Expr)
	}
	return rhs
}

// Body is the sum the contributions stand for: RHS, or the `faq` body when the
// pointwise lift wrapped the equation (Lifted).
func (e FlattenedEquation) Body() Expression {
	if e.Lifted {
		if node, ok := asExprNode(e.RHS); ok {
			return node.Expr
		}
	}
	return e.RHS
}

// contributionList is e's contribution list, or — when it is empty, as on an
// equation built outside flatten — the one contribution `Body()` with no
// origins, so every pass reads a list that folds to the equation's sum.
func (e FlattenedEquation) contributionList() []Contribution {
	if len(e.Contributions) == 0 {
		return []Contribution{{Expr: e.Body(), Origins: []TermOrigin{}}}
	}
	return e.Contributions
}

// equationFrom is eq with a new contribution list, its right-hand side REBUILT
// from that list (left fold, re-wrapped in the lift's `faq` when eq is lifted)
// and its left-hand side replaced by lhs. Every flatten pass that rewrites an
// equation goes through here, so no term moves across a contribution boundary.
func equationFrom(eq FlattenedEquation, contributions []Contribution, lhs Expression) FlattenedEquation {
	if len(contributions) == 0 {
		contributions = eq.contributionList()
	}
	body := foldContributions(contributions)
	rhs := body
	if eq.Lifted {
		if node, ok := asExprNode(eq.RHS); ok {
			node.Expr = body
			rhs = node
		}
	}
	eq.LHS = lhs
	eq.RHS = rhs
	eq.Contributions = contributions
	return eq
}

// mapContributions is eq with f applied inside every contribution, origins
// unchanged, and its left-hand side replaced by lhs.
func mapContributions(eq FlattenedEquation, f func(Expression) Expression, lhs Expression) FlattenedEquation {
	in := eq.contributionList()
	out := make([]Contribution, len(in))
	for i, c := range in {
		out[i] = Contribution{Expr: f(c.Expr), Origins: c.Origins}
	}
	return equationFrom(eq, out, lhs)
}
