import Esm.Document.Math.Cases7

/-!
# Round trip, case by case: fractions, powers, cases
-/

namespace Esm.Document.Math

open Esm.Document

theorem headOK_fields {c : Ctx} {ts : List Tok} (h : HeadOK c ts) :
    ∃ t r, ts = t :: r ∧ t ≠ .kw .dif ∧ t ≠ .kw .pdiff ∧ t ≠ .rm "d" := by
  match ts, h with
  | t :: r, ⟨h1, h2, h3, _, _, _⟩ => exact ⟨t, r, rfl, h1, h2, h3⟩

/-- After `\frac{`: an ordinary quotient. -/
theorem pFracL_quot (c : Ctx) (a b : Json) (ha : M c a) (hb : M c b) (rest : List Tok) (f : Nat)
    (hf : need 1 (((pr c a).at c.sf 1).length + ((pr c b).at c.sf 1).length + 3) + 1 ≤ f) :
    pFracL c (f + 1) ((pr c a).at c.sf 1 ++ .kw .rb :: .kw .lb :: ((pr c b).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "/" [a, b], rest) := by
  have h1 := child1 ha (.kw .rb :: .kw .lb :: ((pr c b).at c.sf 1 ++ .kw .rb :: rest))
    (fol1_kw _ .rb (by simp) _) f (by unfold need at hf ⊢; omega)
  have h2 := child1 hb _ (fol1_kw _ .rb (by simp) rest) f (by unfold need at hf ⊢; omega)
  have hi := pItalicD_none c ((pr c a).at c.sf 1) (.kw .rb :: .kw .lb :: ((pr c b).at c.sf 1 ++ .kw .rb :: rest))
    (headOK_at ha 1)
  obtain ⟨t, r, he, h1d, h2d, h3d⟩ := headOK_fields (headOK_at ha 1)
  rw [he] at h1 hi ⊢
  simp only [List.cons_append] at h1 hi ⊢
  rw [pFracL.eq_6 _ _ _ (by intro r' e; simp at e; exact h3d e.1) (by intro r' e; simp at e; exact h3d e.1)
    (by intro r' e; simp at e; exact h2d e.1) (by intro r' e; simp at e; exact h2d e.1)]
  rw [hi]
  simp only
  rw [h1]
  simp only
  rw [h2]

theorem M_div (c : Ctx) (o : String) (a b : Json) (ho : kindOf o = .div) (ha : M c a) (hb : M c b)
    (hpr : pr c (node o [a, b]) = match c.sf with
      | .latex => mkOut c.sf 10 ([.kw .frac, .kw .lb] ++ (pr c a).at c.sf 1 ++
          [.kw .rb, .kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb])
      | .typst => mkOut c.sf 7 ((pr c a).at c.sf 8 ++ .kw .slash :: (pr c b).at c.sf 8)) :
    M c (node o [a, b]) := by
  have := kindOf_div ho; subst this
  split at hpr
  · rename_i hs
    apply M_of
    · apply P0_of_prim
      · intro rest hr f hf
        obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by rw [hpr] at hf; simp [mkOut] at hf; unfold need at hf; omega⟩
        rw [hpr] at hf ⊢
        simp only [mkOut, List.length_append, List.length_cons, List.length_nil] at hf ⊢
        simp only [List.append_assoc, List.cons_append, List.nil_append]
        rw [pPrim.eq_def]
        simp only
        exact pFracL_quot c a b ha hb rest g (by unfold need at hf ⊢; omega)
      · rw [hpr]; simp [mkOut]
      · rw [hpr]; simp [mkOut]
    · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
    · exact addAcc_node (by decide)
    · rw [hpr]; rfl
  · rename_i hs
    apply M_of
    · intro rest hr f hf
      have hl7 : (pr c (node "/" [a, b])).lvl = 7 := by rw [hpr]; rfl
      rw [hl7] at hr hf ⊢
      rw [hpr] at hf ⊢; simp only [mkOut, List.length_append, List.length_cons] at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
      have h1 := PL_at ha 8 (by omega) (by omega) _ (fol_kw _ _ .slash ((pr c b).at c.sf 8 ++ rest)
        (by simp [conts, hs])) (g + 2) (by unfold need at hf ⊢; omega)
      have h2 := PL_at hb 8 (by omega) (by omega) rest (hr.mono (by omega)) (g + 1)
        (by unfold need at hf ⊢; omega)
      rw [pLvl8] at h1 h2
      rw [pLvl7, pFrac, List.append_assoc, List.cons_append, h1]
      simp only
      rw [fracLoop, iteT hs]
      rw [h2]
      simp only
      exact fracLoop_stop c g _ rest hr
    · rw [hpr]; simp only [mkOut]; exact headOK_append (headOK_at ha 8) _
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
    · exact addAcc_node (by decide)
    · rw [hpr]; rfl


theorem at1_toks {c : Ctx} {a : Json} (h : M c a) : (pr c a).at c.sf 1 = (pr c a).toks := by
  rw [at_eq, iteT h.2.2.2.2.1]

theorem simpleE_toks {c : Ctx} {b : Json} {t : Tok} (h : simpleE c b = some t) : (pr c b).toks = [t] := by
  unfold simpleE at h
  split at h
  · rename_i n; split at h
    · cases h; rw [pr_num]; rfl
    · cases h
  · rename_i s; split at h
    · rename_i t' ht; split at h
      · cases h; rw [pr_str]; simp [mkOut, ht]
      · cases h
    · cases h
  · cases h

/-- The power, once the exponent's tokens `EX` are known to read back. -/
theorem M_pow_of (c : Ctx) (a b : Json) (ha : M c a) (EX : List Tok)
    (hex : ∀ rest g, 30 * EX.length + 30 ≤ g → pExpo c g (EX ++ rest) = some (b, rest))
    (hpr : pr c (node "^" [a, b]) = mkOut c.sf 8 ((pr c a).at c.sf 9 ++ .kw .caret :: EX)) :
    M c (node "^" [a, b]) := by
  apply M_of
  · intro rest hr f hf
    have hl8 : (pr c (node "^" [a, b])).lvl = 8 := by rw [hpr]; rfl
    rw [hl8] at hr hf ⊢
    rw [hpr] at hf ⊢; simp only [mkOut, List.length_append, List.length_cons] at hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
    have h1 := PL_at ha 9 (by omega) (by omega) (.kw .caret :: (EX ++ rest))
      (fol_kw _ _ .caret _ (by simp [conts])) (g + 2) (by unfold need at hf ⊢; omega)
    rw [pLvl9] at h1
    rw [pLvl8, pPow, List.append_assoc, List.cons_append, h1]
    simp only
    rw [hex rest (g + 2) (by unfold need at hf; omega)]
  · rw [hpr]; simp only [mkOut]; exact headOK_append (headOK_at ha 9) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

theorem M_pow (c : Ctx) (o : String) (a b : Json) (ho : kindOf o = .pow) (ha : M c a) (hb : M c b)
    (hbe : isE b = true)
    (hpr : pr c (node o [a, b]) = mkOut c.sf 8 ((pr c a).at c.sf 9 ++ .kw .caret :: (match c.sf with
        | .latex => [.kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb]
        | .typst =>
          match simpleE c b with
          | some t => [t]
          | none => grp c.sf (pr c b).toks))) :
    M c (node o [a, b]) := by
  have := kindOf_pow ho; subst this
  split at hpr
  · rename_i hs
    refine M_pow_of c a b ha _ (fun rest g hg => ?_) hpr
    obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by omega⟩
    have h2 := child1 hb _ (fol1_kw _ .rb (by simp) rest) g' (by
      simp only [List.length_append, List.length_cons, List.length_nil] at hg; unfold need; omega)
    rw [pExpo.eq_def]
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    split
    all_goals try (exfalso; simp_all; done)
    rename_i r heq
    simp only [List.cons.injEq] at heq; obtain ⟨-, rfl⟩ := heq
    rw [h2]
  · rename_i hs
    split at hpr
    · rename_i t ht
      refine M_pow_of c a b ha _ (fun rest g hg => ?_) hpr
      obtain ⟨g', rfl⟩ : ∃ g', g = g' + 2 := ⟨g - 2, by simp at hg; omega⟩
      obtain ⟨hp, hs2, hlp⟩ := simpleE_parse c b hbe t ht g'
      rw [pExpo.eq_def]
      simp only [List.cons_append, List.nil_append]
      split
      all_goals try (exfalso; simp_all; done)
      rename_i t' r heq
      simp only [List.cons.injEq] at heq; obtain ⟨rfl, rfl⟩ := heq
      simp only [hs2, ↓reduceIte, hp, Option.bind_some]
    · refine M_pow_of c a b ha _ (fun rest g hg => ?_) hpr
      obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by omega⟩
      have hrp : rpG c.sf = .kw .rp := by simp [rpG, hs]
      have h2 := child1 hb (rpG c.sf :: rest) (by rw [hrp]; exact fol1_kw _ .rp (by simp) rest) g' (by
        simp only [grp, List.length_append, List.length_cons, List.length_nil] at hg
        rw [at1_toks hb]; unfold need; omega)
      rw [at1_toks hb, hrp] at h2
      have hgrp : grp c.sf (pr c b).toks = .kw .lpg :: (pr c b).toks ++ [.kw .rp] := by
        simp [grp, hs]
      rw [hgrp]
      rw [pExpo.eq_def]
      simp only [List.cons_append, List.append_assoc, List.nil_append]
      split
      all_goals try (exfalso; simp_all; done)
      rename_i r heq
      simp only [List.cons.injEq] at heq; obtain ⟨-, rfl⟩ := heq
      rw [h2]; simp [isRp]

end Esm.Document.Math
