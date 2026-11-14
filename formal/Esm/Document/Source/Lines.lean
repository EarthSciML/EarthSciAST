import Mathlib.Data.List.Basic

/-!
# Lines of text

Containers are line-oriented: a fenced block ends at the first line that starts with
its closing fence. `heads` lists the characters that start a line, so "no line of `s`
starts with a backtick" is `'`' ∉ heads true s`.
-/

namespace Esm.Document.Source

/-- The characters that start a line of `s`: the first character when `s` starts at the
beginning of a line (`bol`), and every character right after a newline. -/
def heads : Bool → List Char → List Char
  | _, [] => []
  | bol, c :: r => (if bol then [c] else []) ++ heads (c == '\n') r

/-- Whether the text after `s` starts at the beginning of a line. -/
def endBol (bol : Bool) (s : List Char) : Bool :=
  match s.getLast? with
  | none => bol
  | some c => c == '\n'

theorem endBol_cons (bol : Bool) (c : Char) (x : List Char) :
    endBol bol (c :: x) = endBol (c == '\n') x := by
  unfold endBol
  rw [List.getLast?_cons]
  cases x.getLast? <;> rfl

theorem endBol_append (bol : Bool) (x y : List Char) :
    endBol bol (x ++ y) = endBol (endBol bol x) y := by
  unfold endBol
  rw [List.getLast?_append]
  cases y.getLast? <;> cases x.getLast? <;> rfl

theorem endBol_newline (bol : Bool) (x : List Char) : endBol bol (x ++ ['\n']) = true := by
  rw [endBol_append]; rfl

theorem heads_append (bol : Bool) (x y : List Char) :
    heads bol (x ++ y) = heads bol x ++ heads (endBol bol x) y := by
  induction x generalizing bol with
  | nil => rfl
  | cons c x ih =>
    simp only [List.cons_append, heads, ih, endBol_cons, List.append_assoc]

end Esm.Document.Source
