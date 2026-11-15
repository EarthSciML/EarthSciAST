package docfmt

// The entry points the esm package calls.

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
// in scope. An object with `lhs` and `rhs` prints as its two sides around `=`
// (`Source.eqExpr`).
func PrintMath(e Json, names []string, latex bool) string {
	if kvs, ok := e.(Obj); ok {
		lhs, okL := exprLook("lhs", kvs)
		rhs, okR := exprLook("rhs", kvs)
		if okL && okR {
			e = Obj{{"args", []Json{lhs, rhs}}, {"op", "=="}}
		}
	}
	s := &Sym{Names: append([]string(nil), names...)}
	if latex {
		return mathPrintLatex(s, e)
	}
	return mathPrintTypst(s, e)
}
