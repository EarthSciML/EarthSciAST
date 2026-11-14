import Esm.Document.Math.Atoms

/-!
# The token-level round trip
-/

namespace Esm.Document.Math

open Esm.Document

/-- The pending `+` operands a level-4 parse of `e` leaves in the loop. -/
def addAcc (e : Json) : List Json :=
  match e with
  | .obj [("args", .arr xs), ("op", .str "+")] => if 2 ≤ xs.length then xs else [e]
  | _ => [e]

theorem close_addAcc (e : Json) : close "+" (addAcc e) = e := by
  unfold addAcc
  split
  · rename_i xs
    split
    · rename_i h
      match xs, h with
      | a :: b :: r, _ => rfl
    · rfl
  · rfl

/-- The level-4 parse of `e` stops in the `+` loop, with fuel to spare. -/
def PA (c : Ctx) (e : Json) : Prop :=
  ∀ rest, Fol c.sf 5 rest → ∀ f, need 4 ((pr c e).at c.sf 4).length ≤ f →
    ∃ g, f ≤ g + 30 * ((pr c e).at c.sf 4).length + 4 ∧
      pAdd c f ((pr c e).at c.sf 4 ++ rest) = addLoop c g (addAcc e) rest

def casesEnd (sf : Sf) : Tok := .kw (if sf = .latex then .ecases else .rp)

/-- `e` as the last rows of a `cases` block reads back. -/
def PCr (c : Ctx) (e : Json) : Prop :=
  ∀ rest f, need 1 ((pr c e).crow.length + 1) ≤ f →
    pCases c f ((pr c e).crow ++ casesEnd c.sf :: rest) = some (e, rest)

/-- Everything the induction carries. -/
def M (c : Ctx) (e : Json) : Prop :=
  PL c e ∧ PA c e ∧ PCr c e ∧ HeadOK c (pr c e).toks ∧ 1 ≤ (pr c e).lvl ∧ (pr c e).lvl ≤ 10

/-! ## Generic steps -/

theorem P0_of_prim (c : Ctx) (e : Json)
    (h : ∀ rest, Fol c.sf 10 rest → ∀ f, need 10 (pr c e).toks.length ≤ f →
      pPrim c f ((pr c e).toks ++ rest) = some (e, rest))
    (hl1 : 1 ≤ (pr c e).lvl) (hl : (pr c e).lvl ≤ 10) : P0 c e := by
  intro rest hr f hf
  have := lift (c := c) (ts := (pr c e).toks ++ rest) (r := rest) (x := e)
    (N := need 10 (pr c e).toks.length) (10 - (pr c e).lvl) (pr c e).lvl hl1 (by omega)
    (by rw [show (pr c e).lvl + (10 - (pr c e).lvl) = 10 by omega]
        exact fun f hf => h rest (hr.mono hl) f hf) hr f (by unfold need at hf ⊢; omega)
  exact this

end Esm.Document.Math
