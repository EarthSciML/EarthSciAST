import Esm.Document.Source.Facts
import Mathlib.Data.String.Basic

/-!
# An equation as math

An equation `lhs = rhs` is printed as the math of the expression `==(lhs, rhs)`: the
`=` is the comparison's sign at the loosest comparison level. So the Phase 2 round trip
(`parseLatex_printLatex`, `parseTypst_printTypst`) reads it back, and a side that is
itself a comparison, `and` or `or` is parenthesized by the precedence rules where
needed: on the right always, on the left when it is an `and` or an `or` (a comparison
on the left, `a < b = c`, reads back as the same equation because comparisons
associate to the left).
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-- The expression an equation is printed as. -/
def eqExpr (e : Eqn) : Json := .obj [("args", .arr [e.lhs, e.rhs]), ("op", .str "==")]

/-- The equation sides of a parsed expression, when it is an `==` node. -/
def eqSides : Json → Option (Json × Json)
  | .obj [("args", .arr [l, r]), ("op", .str "==")] => some (l, r)
  | _ => none

theorem eqSides_eqExpr (e : Eqn) : eqSides (eqExpr e) = some (e.lhs, e.rhs) := rfl

theorem isE_eqExpr (e : Eqn) (hl : isE e.lhs = true) (hr : isE e.rhs = true) :
    isE (eqExpr e) = true := by
  unfold eqExpr
  have hlt : ("args" : String) < "op" := by rw [String.lt_iff_toList_lt]; decide
  rw [isE]
  simp [keysSorted, opFieldOK, hasArgs, look, opOK, removedOps, deprecatedOps, hl, hr, hlt]

end Esm.Document.Source
