import Esm.Document.Math.Names

/-!
# Parsing at a level, what may follow, and moving between levels

`pLvl L` parses at precedence level `L` (`1` = an `or` chain … `9` = postfix, `10` =
a primary). `Fol sf L rest` says `rest` does not continue an expression parsed at
level `L`. `lift` moves a parse at a tighter level to a looser one: the loops of the
levels in between stop at once.
-/

namespace Esm.Document.Math

open Esm.Document

def pLvl (c : Ctx) (f : Nat) (L : Nat) (ts : List Tok) : Option (Json × List Tok) :=
  match L with
  | 1 => pOr c f ts
  | 2 => pAnd c f ts
  | 3 => pCmp c f ts
  | 4 => pAdd c f ts
  | 5 => pMul c f ts
  | 6 => pNot c f ts
  | 7 => pFrac c f ts
  | 8 => pPow c f ts
  | 9 => pPost c f ts
  | _ => pPrim c f ts

def isCmpTok : Tok → Bool
  | .kw k => (cmpOf k).isSome
  | _ => false

/-- `t` continues an expression parsed at level `L`. -/
def conts (sf : Sf) (L : Nat) : Tok → Bool
  | .kw .us | .kw .sdot | .kw .lp | .units _ => true
  | .kw .lbk => decide (L ≤ 9)
  | .kw .caret => decide (L ≤ 8)
  | .kw .slash => decide (L ≤ (match sf with | .typst => 7 | .latex => 5))
  | .kw .cdot | .kw .times => decide (L ≤ 5)
  | .kw .plus | .kw .minus => decide (L ≤ 4)
  | .kw .land => decide (L ≤ 2)
  | .kw .lor => decide (L ≤ 1)
  | t => (decide (L ≤ 3) && isCmpTok t) || (decide (L ≤ 5) && atomStart t)

/-- `rest` does not continue an expression parsed at level `L`. -/
def Fol (sf : Sf) (L : Nat) (rest : List Tok) : Prop :=
  ∀ t r, rest = t :: r → conts sf L t = false

theorem Fol_nil (sf : Sf) (L : Nat) : Fol sf L [] := fun _ _ h => by cases h

theorem conts_mono (sf : Sf) {L L' : Nat} (h : L ≤ L') (t : Tok) (ht : conts sf L t = false) :
    conts sf L' t = false := by
  have key : ∀ a b : Bool, ((decide (L ≤ 3) && a) || (decide (L ≤ 5) && b)) = false →
      ((decide (L' ≤ 3) && a) || (decide (L' ≤ 5) && b)) = false := by
    intro a b hab
    cases a <;> cases b <;> simp_all <;> omega
  unfold conts at ht ⊢
  split at ht <;> first | (simp_all; done) | (simp_all; omega) | exact key _ _ ht

theorem Fol.mono {sf : Sf} {L L' : Nat} {rest : List Tok} (hr : Fol sf L rest) (h : L ≤ L') :
    Fol sf L' rest := fun t r e => conts_mono sf h t (hr t r e)

/-! ## No level starts with a binary `-` or a `not` it does not own -/

theorem pPrim_minus (c : Ctx) (f : Nat) (r : List Tok) : pPrim c f (.kw .minus :: r) = none := by
  cases f with
  | zero => rfl
  | succ f =>
    rw [pPrim.eq_def]
    cases r with
    | nil => simp [pNamePrim, pName, pSeg, formulaOf, eulerHead]
    | cons t r => simp [fnOf]

theorem pPrim_lnot (c : Ctx) (f : Nat) (r : List Tok) : pPrim c f (.kw .lnot :: r) = none := by
  cases f with
  | zero => rfl
  | succ f =>
    rw [pPrim.eq_def]
    cases r with
    | nil => simp [pNamePrim, pName, pSeg, formulaOf, eulerHead]
    | cons t r => simp [fnOf]

theorem pPost_none {c : Ctx} {ts : List Tok} (h : ∀ f, pPrim c f ts = none) (f : Nat) :
    pPost c f ts = none := by
  cases f with
  | zero => rfl
  | succ f => rw [pPost]; simp [h f]

theorem pPow_none {c : Ctx} {ts : List Tok} (h : ∀ f, pPrim c f ts = none) (f : Nat) :
    pPow c f ts = none := by
  cases f with
  | zero => rfl
  | succ f => rw [pPow]; simp [pPost_none h f]

theorem pFrac_none {c : Ctx} {ts : List Tok} (h : ∀ f, pPrim c f ts = none) (f : Nat) :
    pFrac c f ts = none := by
  cases f with
  | zero => rfl
  | succ f => rw [pFrac]; simp [pPow_none h f]

theorem pNot_minus (c : Ctx) (f : Nat) (r : List Tok) : pNot c f (.kw .minus :: r) = none := by
  cases f with
  | zero => rfl
  | succ f =>
    rw [pNot.eq_3 _ _ _ (by intro r' h; cases h)]
    exact pFrac_none (fun g => pPrim_minus c g r) f

theorem pFrac_lnot (c : Ctx) (f : Nat) (r : List Tok) : pFrac c f (.kw .lnot :: r) = none :=
  pFrac_none (fun g => pPrim_lnot c g r) f

/-! ## Lifting a parse to a looser level -/

theorem lift_or {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pAnd c f ts = some (x, r))
    (hr : Fol c.sf 1 r) (hf : 1 ≤ f) : pOr c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pOr, h]
  simp only
  rw [orLoop.eq_3 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)]
  rfl

theorem lift_and {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pCmp c f ts = some (x, r))
    (hr : Fol c.sf 2 r) (hf : 1 ≤ f) : pAnd c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pAnd, h]
  simp only
  rw [andLoop.eq_3 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)]
  rfl

theorem lift_cmp {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pAdd c f ts = some (x, r))
    (hr : Fol c.sf 3 r) (hf : 1 ≤ f) : pCmp c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pCmp, h]
  simp only
  cases r with
  | nil => rfl
  | cons t r' =>
    cases t with
    | kw k =>
      have := hr _ _ rfl
      rw [cmpLoop]
      cases hk : cmpOf k with
      | none => rfl
      | some o =>
        exfalso
        cases k <;> simp_all [conts, cmpOf, isCmpTok]
    | _ => rfl

/-- Nothing that does not continue a level-5 parse starts with a number. -/
theorem negTail_fol {sf : Sf} {L : Nat} {r : List Tok} (hr : Fol sf L r) (hL : L ≤ 5) :
    negTail r = none := by
  cases r with
  | nil => rfl
  | cons t r' =>
    cases t with
    | num n =>
      have := hr _ _ rfl
      simp [conts, atomStart] at this; omega
    | _ => rfl

theorem lift_add {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pMul c f ts = some (x, r))
    (hr : Fol c.sf 4 r) (hf : 1 ≤ f) : pAdd c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pAdd, h]
  simp only
  rw [addLoop.eq_4 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)
    (by intro r' e; have := hr _ _ e; simp [conts] at this), negTail_fol hr (by omega)]
  rfl

theorem lift_mul {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pNot c f ts = some (x, r))
    (hr : Fol c.sf 5 r) (hf : 1 ≤ f) : pMul c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  have hts : ∀ r', ts ≠ .kw .minus :: r' := by
    intro r' e; subst e; rw [pNot_minus] at h; cases h
  rw [pMul.eq_3 _ _ _ (fun r' e => hts r' e), h]
  simp only
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    have h1 : t ≠ .kw .cdot := by rintro rfl; simp [conts] at ht
    have h2 : t ≠ .kw .times := by rintro rfl; simp [conts] at ht
    have h4 : atomStart t = false := by
      unfold conts at ht; split at ht <;> simp_all [atomStart]
    by_cases h3 : t = .kw .slash
    · subst h3
      rw [mulLoop.eq_4]
      cases hsf : c.sf
      · simp [conts, hsf] at ht
      · simp; rfl
    · rw [mulLoop.eq_5 _ _ _ _ _ h1 h2 h3]
      simp [h4]; rfl

theorem lift_not {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pFrac c f ts = some (x, r)) :
    pNot c (f + 1) ts = some (x, r) := by
  have hts : ∀ r', ts ≠ .kw .lnot :: r' := by
    intro r' e; subst e; rw [pFrac_lnot] at h; cases h
  rw [pNot.eq_3 _ _ _ (fun r' e => hts r' e), h]

theorem lift_frac {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pPow c f ts = some (x, r))
    (hr : Fol c.sf 7 r) (hf : 1 ≤ f) : pFrac c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pFrac, h]
  simp only
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    by_cases h3 : t = .kw .slash
    · subst h3
      rw [fracLoop]
      cases hsf : c.sf
      · simp
      · simp [conts, hsf] at ht
    · rw [fracLoop.eq_3 _ _ _ _ (by intro r'' e; cases e; exact h3 rfl)]

theorem lift_pow {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pPost c f ts = some (x, r))
    (hr : Fol c.sf 8 r) : pPow c (f + 1) ts = some (x, r) := by
  rw [pPow, h]
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    by_cases h3 : t = .kw .caret
    · subst h3; simp [conts] at ht
    · split
      · rename_i heq; simp at heq; exact absurd heq.2.1 h3
      · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
        obtain ⟨rfl, rfl⟩ := heq; rfl
      · rename_i heq; simp at heq

theorem lift_post {c : Ctx} {f : Nat} {ts r : List Tok} {x : Json} (h : pPrim c f ts = some (x, r))
    (hr : Fol c.sf 9 r) (hf : 1 ≤ f) : pPost c (f + 1) ts = some (x, r) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pPost, h]
  simp only
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    have h1 : t ≠ .kw .us := by rintro rfl; simp [conts] at ht
    have h2 : t ≠ .kw .lbk := by rintro rfl; simp [conts] at ht
    exact postLoop.eq_7 _ _ _ _ (by intro r e; cases e; exact h1 rfl) (by intro r e; cases e; exact h2 rfl)

end Esm.Document.Math
