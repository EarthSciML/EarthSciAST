import Esm.Document.Math.TokTypst

/-!
# The Typst math round trip, at the string level

Two printers: `printTypst` writes an expression (an `==` at its top is a comparison, as
in an event's condition, and prints as any expression does), and `printTypstEqn` writes
the expression an equation is printed as (`Source.eqExpr`), an equation `x = faq` with
output indices in its defining form `x_s = …, s ∈ S` (`Math.print`). The one reader
takes both back.
-/

namespace Esm.Document.Math

open Esm.Document

/-- The Typst math spelling of an expression under the symbol table `S`. -/
def printTypst (S : Sym) (e : Json) : String :=
  String.ofList (Typst.render (pa ⟨.typst, S⟩ 1 e))

/-- The Typst math spelling of an equation's expression (`==(lhs, rhs)`) under the symbol
table `S`: in its defining form when it has one. -/
def printTypstEqn (S : Sym) (e : Json) : String :=
  String.ofList (Typst.render (print .typst S e))

/-- Read Typst math under the symbol table `S`. -/
def parseTypst (S : Sym) (s : String) : Option Json :=
  (Typst.lex s.toList).bind (parseToks .typst S)

/-- The Typst round trip: every well-formed expression reads back from its Typst
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form). -/
theorem parseTypst_printTypst (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypst S e) = some e := by
  obtain ⟨h1, h2, h3⟩ := Typst.print_ok_pa S e he
  unfold parseTypst printTypst
  rw [String.toList_ofList, Typst.lex_render _ h1 h2 h3]
  exact parseToks_pa .typst S e he

/-- The Typst round trip of an equation's expression, its defining form included. -/
theorem parseTypst_printTypstEqn (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypstEqn S e) = some e := by
  obtain ⟨h1, h2, h3⟩ := Typst.print_ok S e he
  unfold parseTypst printTypstEqn
  rw [String.toList_ofList, Typst.lex_render _ h1 h2 h3]
  exact parseToks_print .typst S e he

end Esm.Document.Math
