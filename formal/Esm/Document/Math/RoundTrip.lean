import Esm.Document.Math.Levels

/-!
# The token-level round trip: generic pieces

`PL c e`: the printed tokens of `e` for any level read back to `e` at that level,
before anything that does not continue it, with enough fuel (`need`). The main
theorem (`Esm.Document.Math.Main`) proves it for every well-formed expression by
strong induction; this file holds the steps that do not depend on the notation.
-/

namespace Esm.Document.Math

open Esm.Document

theorem iteT {α : Sort _} {p : Prop} [Decidable p] (h : p) (a b : α) : (if p then a else b) = a := by
  simp [h]

theorem iteF {α : Sort _} {p : Prop} [Decidable p] (h : ¬p) (a b : α) : (if p then a else b) = b := by
  simp [h]

theorem pLvl1 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 1 ts = pOr c f ts := rfl
theorem pLvl2 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 2 ts = pAnd c f ts := rfl
theorem pLvl3 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 3 ts = pCmp c f ts := rfl
theorem pLvl4 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 4 ts = pAdd c f ts := rfl
theorem pLvl5 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 5 ts = pMul c f ts := rfl
theorem pLvl6 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 6 ts = pNot c f ts := rfl
theorem pLvl7 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 7 ts = pFrac c f ts := rfl
theorem pLvl8 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 8 ts = pPow c f ts := rfl
theorem pLvl9 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 9 ts = pPost c f ts := rfl
theorem pLvl10 (c : Ctx) (f : Nat) (ts : List Tok) : pLvl c f 10 ts = pPrim c f ts := rfl

/-- Fuel enough to read `len` tokens at level `L`. -/
def need (L len : Nat) : Nat := 30 * len + (12 - L)

/-- `e`'s tokens for level `L` read back at level `L`. -/
def PL (c : Ctx) (e : Json) : Prop :=
  ∀ L, 1 ≤ L → L ≤ 10 → ∀ rest, Fol c.sf L rest → ∀ f, need L ((pr c e).at c.sf L).length ≤ f →
    pLvl c f L ((pr c e).at c.sf L ++ rest) = some (e, rest)

/-- `e`'s tokens read back at its own level. -/
def P0 (c : Ctx) (e : Json) : Prop :=
  ∀ rest, Fol c.sf (pr c e).lvl rest → ∀ f, need (pr c e).lvl (pr c e).toks.length ≤ f →
    pLvl c f (pr c e).lvl ((pr c e).toks ++ rest) = some (e, rest)

/-- What a printed expression starts with, as far as the variant readings care. -/
def HeadOK (c : Ctx) : List Tok → Prop
  | t :: r => t ≠ .kw .dif ∧ t ≠ .kw .pdiff ∧ t ≠ .rm "d" ∧ (∀ w, t ≠ .word w) ∧
      (t = .letter 'd' → c.S.names.contains "d" = true ∨ (∃ r', r = .kw .us :: r') ∨
        (∃ r', r = .kw .sdot :: r')) ∧ (atomStart t = true ∨ t = .kw .minus)
  | [] => False

theorem pLvl_pos {c : Ctx} {f L : Nat} {ts : List Tok} {x : Json × List Tok}
    (h : pLvl c f L ts = some x) : 1 ≤ f := by
  cases f with
  | zero =>
    exfalso
    unfold pLvl at h
    split at h <;> simp [pOr, pAnd, pCmp, pAdd, pMul, pNot, pFrac, pPow, pPost, pPrim] at h
  | succ f => omega

/-- One level looser. -/
theorem lift_step {c : Ctx} {L f : Nat} {ts r : List Tok} {x : Json} (hL : 1 ≤ L) (hL' : L < 10)
    (h : pLvl c f (L + 1) ts = some (x, r)) (hr : Fol c.sf L r) :
    pLvl c (f + 1) L ts = some (x, r) := by
  have hf := pLvl_pos h
  match L, hL, hL' with
  | 1, _, _ => exact lift_or h hr hf
  | 2, _, _ => exact lift_and h hr hf
  | 3, _, _ => exact lift_cmp h hr hf
  | 4, _, _ => exact lift_add h hr hf
  | 5, _, _ => exact lift_mul h hr hf
  | 6, _, _ => exact lift_not h
  | 7, _, _ => exact lift_frac h hr hf
  | 8, _, _ => exact lift_pow h hr
  | 9, _, _ => exact lift_post h hr hf

/-- Several levels looser. -/
theorem lift {c : Ctx} {ts r : List Tok} {x : Json} {N : Nat} :
    ∀ (d L : Nat), 1 ≤ L → L + d ≤ 10 → (∀ f, N ≤ f → pLvl c f (L + d) ts = some (x, r)) →
      Fol c.sf L r → ∀ f, N + d ≤ f → pLvl c f L ts = some (x, r)
  | 0, L, _, _, h, _, f, hf => h f (by omega)
  | d + 1, L, hL, hd, h, hr, f, hf => by
    have h1 := lift d (L + 1) (by omega) (by omega) (by simpa [Nat.add_assoc, Nat.add_comm 1 d] using h)
      (hr.mono (by omega)) (f - 1) (by omega)
    have := lift_step hL (by omega) h1 hr
    rwa [show f - 1 + 1 = f by omega] at this

theorem pName_us (sf : Sf) (r : List Tok) : pName sf (.kw .us :: r) = none := by
  simp [pName, pSeg, formulaOf]

theorem pName_sdot (sf : Sf) (r : List Tok) : pName sf (.kw .sdot :: r) = none := by
  simp [pName, pSeg, formulaOf]

theorem dName_none (c : Ctx) (k : Kw) (toks rest : List Tok) (hh : HeadOK c toks)
    (hd : c.S.names.contains "d" = false) : dName c.sf k (toks ++ rest) = none := by
  cases toks with
  | nil => exact absurd hh (by simp [HeadOK])
  | cons t tr =>
    obtain ⟨-, -, -, hw, hdd, -⟩ := hh
    unfold dName
    split
    · rename_i w _ _ heq
      simp only [List.cons_append, List.cons.injEq] at heq
      exact absurd heq.1 (hw w)
    · rename_i r heq
      simp only [List.cons_append, List.cons.injEq] at heq
      obtain ⟨rfl, rfl⟩ := heq
      rcases hdd rfl with h | ⟨r', rfl⟩ | ⟨r', rfl⟩
      · rw [hd] at h; cases h
      · simp [pName_us]
      · simp [pName_sdot]
    · rfl

theorem pItalicD_none (c : Ctx) (toks rest : List Tok) (hh : HeadOK c toks) :
    pItalicD c (toks ++ rest) = none := by
  unfold pItalicD
  cases hd : c.S.names.contains "d"
  · simp only [Bool.false_eq_true, ite_false]
    have h1 := dName_none c .rb toks rest hh hd
    have h2 := dName_none c .rp toks rest hh hd
    cases hs : c.sf
    · rw [hs] at h1; simp [h1]
    · rw [hs] at h2; simp [h2]
  · simp

/-- A primary read in parentheses. -/
theorem pPrim_grp (c : Ctx) (e : Json) (toks : List Tok) (hh : HeadOK c toks)
    (h1 : ∀ rest, Fol c.sf 1 rest → ∀ f, need 1 toks.length ≤ f → pOr c f (toks ++ rest) = some (e, rest))
    (rest : List Tok) (f : Nat) (hf : need 1 toks.length + 1 ≤ f) :
    pPrim c f (grp c.sf toks ++ rest) = some (e, rest) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  have hc : ∀ r, Fol c.sf 1 (rpG c.sf :: r) := by
    intro r t r' e; cases e; cases c.sf <;> simp [rpG, conts, isCmpTok, cmpOf, atomStart]
  have hp := h1 (rpG c.sf :: rest) (hc rest) g (by omega)
  obtain ⟨t, tr, ht⟩ : ∃ t tr, toks = t :: tr := by
    cases toks with
    | nil => exact absurd hh (by simp [HeadOK])
    | cons t tr => exact ⟨t, tr, rfl⟩
  rw [pPrim.eq_def]
  simp only [grp, List.cons_append, List.append_assoc]
  cases hs : c.sf
  · have hp' : pOr c g (toks ++ Tok.kw .rpg :: rest) = some (e, Tok.kw .rpg :: rest) := by
      simpa [rpG, hs] using hp
    simp [hp', isRp]
  · have hp' : pOr c g (toks ++ Tok.kw .rp :: rest) = some (e, Tok.kw .rp :: rest) := by
      simpa [rpG, hs] using hp
    have hi := pItalicD_none c toks (Tok.kw .rp :: rest) hh
    obtain ⟨hd1, hd2, -, -, -, -⟩ := (by rw [ht] at hh; exact hh : HeadOK c (t :: tr))
    subst ht
    simp only [List.cons_append, List.nil_append, reduceCtorEq, ↓reduceIte]
    split
    · rename_i heq; simp at heq; exact absurd heq.1 hd1
    · rename_i heq; simp at heq; exact absurd heq.1 hd2
    · rename_i heq
      simp only [List.cons_append] at hi hp'
      rw [hi, hp']; simp [isRp]
    · simp only [List.cons_append] at hp'
      rw [hp']; simp [isRp]

theorem at_eq (sf : Sf) (L : Nat) (o : Out) :
    o.at sf L = if L ≤ o.lvl then o.toks else grp sf o.toks := rfl

theorem length_grp (sf : Sf) (ts : List Tok) : (grp sf ts).length = ts.length + 2 := by
  simp [grp]

/-- From the natural-level parse to every level. -/
theorem PL_of (c : Ctx) (e : Json) (h0 : P0 c e) (hh : HeadOK c (pr c e).toks)
    (hl1 : 1 ≤ (pr c e).lvl) (hl : (pr c e).lvl ≤ 10) : PL c e := by
  -- the natural-level parse, at every level up to the natural one
  have hnat : ∀ L, 1 ≤ L → L ≤ (pr c e).lvl → ∀ rest, Fol c.sf L rest → ∀ f,
      need L (pr c e).toks.length ≤ f → pLvl c f L ((pr c e).toks ++ rest) = some (e, rest) := by
    intro L hL1 hL rest hr f hf
    have := lift (c := c) (ts := (pr c e).toks ++ rest) (r := rest) (x := e)
      (N := need (pr c e).lvl (pr c e).toks.length) ((pr c e).lvl - L) L hL1 (by omega)
      (by rw [show L + ((pr c e).lvl - L) = (pr c e).lvl by omega]
          exact fun f hf => h0 rest (hr.mono hL) f hf) hr f (by unfold need at hf ⊢; omega)
    exact this
  intro L hL1 hL10 rest hr f hf
  rw [at_eq] at hf ⊢
  split
  · rename_i hL
    simp only [hL, ↓reduceIte] at hf
    exact hnat L hL1 hL rest hr f hf
  · rename_i hL
    simp only [hL, ↓reduceIte, length_grp] at hf
    have hp : ∀ f, need 1 (pr c e).toks.length + 1 ≤ f →
        pLvl c f (L + (10 - L)) (grp c.sf (pr c e).toks ++ rest) = some (e, rest) := by
      intro f hf
      rw [show L + (10 - L) = 10 by omega]
      exact pPrim_grp c e (pr c e).toks hh (fun rest hr f hf => hnat 1 le_rfl hl1 rest hr f hf) rest f hf
    exact lift (10 - L) L hL1 (by omega) hp hr f (by unfold need at hf ⊢; omega)

end Esm.Document.Math
