import Esm.Document.Math.RoundTripLatex
import Esm.Document.Math.RoundTripTypst

/-!
# Accepted variants and refused spellings

Each accepted variant spelling is a normalization step with one lemma: the variant
reads to the same token or the same value as the canonical spelling. Removed
operators are refused by name.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## LaTeX spellings the lexer normalizes -/

theorem variant_leq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("leq".toList ++ X)) = Latex.lexOne ('\\' :: ("le".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

theorem variant_geq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("geq".toList ++ X)) = Latex.lexOne ('\\' :: ("ge".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

theorem variant_neq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("neq".toList ++ X)) = Latex.lexOne ('\\' :: ("ne".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

/-- `\bigl(` and `\Bigl(` read as the grouping `\left(`. -/
theorem variant_bigl (X : List Char) :
    Latex.lexOne ('\\' :: ("bigl".toList ++ '(' :: X)) = Latex.lexOne ('\\' :: ("left".toList ++ '(' :: X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide),
    Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
  rfl

/-- `\bigr)` reads as the grouping `\right)`. -/
theorem variant_bigr (X : List Char) :
    Latex.lexOne ('\\' :: ("bigr".toList ++ ')' :: X)) = Latex.lexOne ('\\' :: ("right".toList ++ ')' :: X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide),
    Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
  rfl

/-- The spacing command `\;` is skipped like a space. -/
theorem variant_thickspace (n : Nat) (X : List Char) :
    Latex.skipWs (n + 1) ('\\' :: ';' :: X) = Latex.skipWs n X := by
  rw [Latex.skipWs.eq_2]; simp

/-! ## Variants the parser reads -/

/-- `\times` reads as the product `\cdot`. -/
theorem variant_times (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) :
    mulLoop c (f + 1) acc (.kw .times :: r) = mulLoop c (f + 1) acc (.kw .cdot :: r) := by
  rw [mulLoop.eq_2, mulLoop.eq_3]

/-- `\dot{x}` (LaTeX) reads as the time derivative of `x`. -/
theorem variant_dot (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .dotacc :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (dNode a "t", rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_rb c.sf rest) f hf]

/-- Typst `dot(x)` reads as the time derivative of `x`. -/
theorem variant_dot_typst (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .cdot :: .kw .lp :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (dNode a "t", rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_rp c.sf rest) f hf]

/-- `[x]` reads as the grouping `(x)`. -/
theorem variant_brackets (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .lbk :: ((pr c a).at c.sf 1 ++ .kw .rbk :: rest)) = some (a, rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_kw c.sf .rbk (by simp) rest) f hf]

/-- `\log(x)` reads as `\ln(x)`. -/
theorem variant_log (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .log :: .kw .lp :: r) = pPrim c (f + 1) (.kw .ln :: .kw .lp :: r) := by
  rw [pPrim.eq_def, pPrim.eq_def]; rfl

/-- `\mathrm{e}^{x}` (LaTeX) reads as `\exp(x)`. -/
theorem variant_euler (c : Ctx) (hc : c.sf = .latex) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.rm "e" :: .kw .caret :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "exp" [a], rest) := by
  rw [pPrim.eq_def]; simp only [eulerHead]
  simp only [beq_self_eq_true, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
  rw [pEulerExp.eq_def]; simp only
  rw [pExpo.eq_def]; simp only; rw [hc]; simp only
  have hp := pOr_at ha _ (fol1_rb c.sf rest) f hf
  rw [hc] at hp
  rw [hp]

/-- The deprecated call form `\operatorname{pow}(x, y)` reads as the power `x^{y}`. -/
theorem variant_pow (c : Ctx) (x y : Json) (hx : M c x) (hy : M c y) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "pow" (.kw .lp :: (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "^" [x, y], rest) := by
  have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart])) (Or.inl rfl)
    [x, y] (by simp [hx, hy]) rest f hf
  rw [pOpn.eq_def]; simp only [isLp, ↓reduceIte]
  rw [hca]; simp [callOps, allPos]

/-- The deprecated call form `\operatorname{neg}(x)` reads as the negation `-x`. -/
theorem variant_neg (c : Ctx) (x : Json) (hx : M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "neg" (.kw .lp :: (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "-" [x], rest) := by
  have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart])) (Or.inl rfl)
    [x] (by simp [hx]) rest f hf
  rw [pOpn.eq_def]; simp only [isLp, ↓reduceIte]
  rw [hca]; simp [callOps, allPos]

/-! ## Refused spellings -/

-- The simp calls below need the facts they are given jointly, which the unused-argument
-- linter, testing one at a time, does not see.
set_option linter.unusedSimpArgs false in
/-- A removed operator is refused by name in the call form. -/
theorem refuse_removed_call (c : Ctx) (n : String) (hn : removedOps.contains n = true) :
    ∀ f ts, pOpn c f n ts = none := by
  have hco : callOps.contains n = false := by
    cases h : callOps.contains n
    · rfl
    · simp only [callOps, removedOps, List.contains_cons, List.contains_nil, Bool.or_false,
        Bool.or_eq_true, beq_iff_eq] at h hn
      rcases h with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp at hn
  have hn' : n ∈ removedOps := by simpa using hn
  have hco' : n ∉ callOps := by simpa using hco
  have hneg : n ≠ "neg" := by rintro rfl; exact absurd hn (by decide)
  have hpow : n ≠ "pow" := by rintro rfl; exact absurd hn (by decide)
  have hD : n ≠ "D" := by rintro rfl; exact absurd hn (by decide)
  intro f ts
  match f, ts with
  | 0, _ => rfl
  | f + 1, [] => rfl
  | f + 1, t0 :: r =>
    rw [pOpn.eq_def]; simp only
    split
    · split
      · simp [hco', hn', hneg, hpow]
      · simp [hn']
      · rfl
    · split
      · simp [hD]
      · rfl

/-- A removed operator is refused by name in the LaTeX escape form. -/
theorem refuse_removed_esc (c : Ctx) (o : String) (hn : removedOps.contains o = true) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.esc o :: .kw .lb :: r) = none := by
  rw [pPrim.eq_def]; simp only
  have hn' : o ∈ removedOps := by simpa using hn
  split
  · split <;> simp [hn']
  · rfl

end Esm.Document.Math
