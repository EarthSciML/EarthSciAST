package docfmt

// The entry points the esm package calls.

// NodeAnnotations are the operator-node fields that annotate a node without
// changing the value it computes: the `id` a derived index set names and the
// author's `expect_cadence` (`Notation.annotatedNodeFields`). The math printer
// sends a node carrying one to the escape form; the esm package drops them
// from an expression's comparison key.
var NodeAnnotations = []string{"id", "expect_cadence"}

// PrintMd prints a document (canonical form, keys sorted) as Markdown
// (`Source.Md.printMd`).
func PrintMd(d Json) string { return mdDocPrintMd(&Lim{}, d) }

// ParseMd reads a Markdown document (`Source.Md.parseMd`). lim is the read's
// state, fresh for each read: afterwards it holds what the read ran into
// (limits.go).
func ParseMd(lim *Lim, text string) (Json, bool) { return mdDocParseMd(lim, text) }

// PrintTyp prints a document (canonical form, keys sorted) as Typst
// (`Source.Typ.printTyp`).
func PrintTyp(d Json) string { return typDocPrintTyp(&Lim{}, d) }

// ParseTyp reads a Typst document (`Source.Typ.parseTyp`). See ParseMd.
func ParseTyp(lim *Lim, text string) (Json, bool) { return typDocParseTyp(lim, text) }

// PrintMath prints one expression or equation (canonical form, keys sorted) as
// LaTeX (latex true) or Typst math under the declared names, with no template
// in scope. An object with `lhs` and `rhs` is an equation and prints as in a
// document (`Source.eqExpr`, `Math.printLatexEqn` / `Math.printTypstEqn`): its
// two sides around `=`, or its defining form when it has one. Anything else is
// an expression (`Math.printLatex` / `Math.printTypst`): an `==` at its top is
// a comparison and never prints in the defining form.
func PrintMath(e Json, names []string, latex bool) string {
	eqn := false
	if kvs, ok := e.(Obj); ok {
		lhs, okL := exprLook("lhs", kvs)
		rhs, okR := exprLook("rhs", kvs)
		if okL && okR {
			e = Obj{{"args", []Json{lhs, rhs}}, {"op", "=="}}
			eqn = true
		}
	}
	s := &Sym{Names: append([]string(nil), names...)}
	switch {
	case latex && eqn:
		return mathPrintLatexEqn(s, e)
	case latex:
		return mathPrintLatex(s, e)
	case eqn:
		return mathPrintTypstEqn(s, e)
	}
	return mathPrintTypst(s, e)
}

// ParseMath reads one expression or equation written as LaTeX (latex true) or
// Typst math under the declared names, with no template in scope: the inverse
// of PrintMath. A parsed `==` node at the top is an equation, an object with
// `lhs` and `rhs` (`Source.eqSides`), and so is an equation in its defining
// form, `y_j = …, j in C`, whose right side reads as the `faq` with output
// indices it writes (`Math.unlift`). See ParseMd for lim.
func ParseMath(lim *Lim, text string, names []string, latex bool) (Json, bool) {
	s := &Sym{Names: append([]string(nil), names...)}
	var (
		e  Json
		ok bool
	)
	if latex {
		e, ok = mathParseLatex(lim, s, text)
	} else {
		e, ok = mathParseTypst(lim, s, text)
	}
	if !ok {
		return nil, false
	}
	if l, r, ok := eqnEqSides(e); ok {
		return Obj{{"lhs", l}, {"rhs", r}}, true
	}
	return e, true
}
