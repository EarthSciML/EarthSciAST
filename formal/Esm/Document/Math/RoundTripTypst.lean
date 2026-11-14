import Esm.Document.Math.TokTypst

/-!
# The Typst math round trip, at the string level
-/

namespace Esm.Document.Math

open Esm.Document

/-- The Typst math spelling of an expression under the symbol table `S`. -/
def printTypst (S : Sym) (e : Json) : String :=
  String.ofList (Typst.render (print .typst S e))

/-- Read Typst math under the symbol table `S`. -/
def parseTypst (S : Sym) (s : String) : Option Json :=
  (Typst.lex s.toList).bind (parseToks .typst S)

/-- The Typst round trip: every well-formed expression reads back from its Typst
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form). -/
theorem parseTypst_printTypst (S : Sym) (e : Json) (he : isE e = true) :
    parseTypst S (printTypst S e) = some e := by
  obtain ⟨h1, h2, h3⟩ := Typst.print_ok S e he
  unfold parseTypst printTypst
  rw [String.toList_ofList, Typst.lex_render _ h1 h2 h3]
  exact parseToks_print .typst S e he

end Esm.Document.Math
