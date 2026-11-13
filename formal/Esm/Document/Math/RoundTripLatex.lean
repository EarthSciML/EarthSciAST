import Esm.Document.Math.TokLatex

/-!
# The LaTeX math round trip, at the string level
-/

namespace Esm.Document.Math

open Esm.Document

/-- The LaTeX math spelling of an expression under the symbol table `S`. -/
def printLatex (S : Sym) (e : Json) : String :=
  String.ofList (Latex.render (print .latex S e))

/-- Read LaTeX math under the symbol table `S`. -/
def parseLatex (S : Sym) (s : String) : Option Json :=
  (Latex.lex s.toList).bind (parseToks .latex S)

/-- The LaTeX round trip: every well-formed expression reads back from its LaTeX
spelling, under every symbol table (collisions included: the printer switches the
names involved to the explicit form). -/
theorem parseLatex_printLatex (S : Sym) (e : Json) (he : isE e = true) :
    parseLatex S (printLatex S e) = some e := by
  unfold parseLatex printLatex
  rw [String.toList_ofList, Latex.lex_render _ (Latex.print_tokOK S e he)]
  exact parseToks_print .latex S e he

end Esm.Document.Math
