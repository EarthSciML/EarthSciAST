package docfmt

// The math surfaces: LaTeX (Markdown documents) and Typst math. Port of
// formal/Esm/Document/Math/ (Rust: document/math/mod.rs); prefix `math`.
//
// One token type (Tok) serves both surfaces; mathPrint writes an expression's
// tokens under a symbol table, each surface renders and lexes its own
// spelling, and mathParseToks reads the tokens of either surface back.
//
//	math_expr.go     Expr.lean
//	math_token.go    Token.lean
//	math_surface.go  Surface.lean
//	math_print.go    Print.lean
//	math_parse.go    Parse.lean, parseToks of Induct.lean, need of RoundTrip.lean
//	math_latex.go    Latex.lean
//	math_typst.go    Typst.lean
//	math_units.go    Units/Typeset.lean

// mathPrint is `Math.print` (Print.lean): the tokens of an expression under
// the symbol table s.
func mathPrint(sf Sf, s *Sym, e Json) []Tok { return prPrint(sf, s, e) }

// mathParseToks is `Math.parseToks` (Induct.lean): read a token list back
// under the symbol table s; lim is the read's state (limits.go).
func mathParseToks(lim *Lim, sf Sf, s *Sym, toks []Tok) (Json, bool) {
	return psParseToks(lim, sf, s, toks)
}

// mathPrintLatex is `Math.printLatex` (RoundTripLatex.lean): an expression
// (an `==` at its top is a comparison and prints as any expression does).
func mathPrintLatex(s *Sym, e Json) string {
	return string(latexRender(prPa(Ctx{sf: SfLatex, s: s}, 1, e)))
}

// mathPrintLatexEqn is `Math.printLatexEqn`: an equation's expression,
// `==(lhs, rhs)`, in its defining form when it has one.
func mathPrintLatexEqn(s *Sym, e Json) string {
	return string(latexRender(mathPrint(SfLatex, s, e)))
}

// mathParseLatex is `Math.parseLatex` (RoundTripLatex.lean).
func mathParseLatex(lim *Lim, s *Sym, text string) (Json, bool) {
	toks, ok := latexLex([]rune(text))
	if !ok {
		return nil, false
	}
	return mathParseToks(lim, SfLatex, s, toks)
}

// mathPrintTypst is `Math.printTypst` (RoundTripTypst.lean): an expression
// (an `==` at its top is a comparison, as in an event's condition, and prints
// as any expression does).
func mathPrintTypst(s *Sym, e Json) string {
	return string(typRender(prPa(Ctx{sf: SfTypst, s: s}, 1, e)))
}

// mathPrintTypstEqn is `Math.printTypstEqn`: an equation's expression,
// `==(lhs, rhs)`, in its defining form when it has one.
func mathPrintTypstEqn(s *Sym, e Json) string {
	return string(typRender(mathPrint(SfTypst, s, e)))
}

// mathParseTypst is `Math.parseTypst`.
func mathParseTypst(lim *Lim, s *Sym, text string) (Json, bool) {
	toks, ok := typLex(lim, []rune(text))
	if !ok {
		return nil, false
	}
	return mathParseToks(lim, SfTypst, s, toks)
}
