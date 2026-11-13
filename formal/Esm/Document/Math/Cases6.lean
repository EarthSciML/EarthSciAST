import Esm.Document.Math.Cases5

/-!
# Round trip, case by case: calls, `min`/`max`, initial conditions, indices
-/

namespace Esm.Document.Math

open Esm.Document

theorem length_callToks (sf : Sf) (h : List Tok) (args : List (List Tok)) :
    (callToks sf h args).length = h.length + (sepBy [.kw .comma] args).length + 2 := by
  simp [callToks]; omega

theorem M_call (c : Ctx) (o : String) (xs : List Json) (ho : kindOf o = .call) (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) =
      mkOut c.sf 10 (callToks c.sf [.opn o] (xs.map fun x => (pr c x).at c.sf 4))) :
    M c (node o xs) := by
  have hco := kindOf_call ho
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by rw [hpr] at hf; unfold need at hf; simp [mkOut, length_callToks] at hf; omega⟩
      rw [hpr] at hf ⊢
      simp only [mkOut, length_callToks] at hf ⊢
      have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
        (Or.inl rfl) xs hx rest g (by simp at hf; unfold need at hf ⊢; omega)
      simp only [callToks, lpC, List.cons_append, List.nil_append, List.append_assoc]
      rw [pPrim.eq_def]
      simp only
      rw [pOpn.eq_def]
      simp only [isLp, ↓reduceIte]
      rw [hca]
      simp only [hco, ↓reduceIte, allPos_map, Option.map_some]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · apply addAcc_node; intro e; subst e; simp [callOps] at hco
  · rw [hpr]; rfl


theorem M_mm (c : Ctx) (o : String) (k : Kw) (xs : List Json) (ho : kindOf o = .mm k) (hl : 2 ≤ xs.length)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) =
      mkOut c.sf 10 (callToks c.sf [.kw k] (xs.map fun x => (pr c x).at c.sf 1))) :
    M c (node o xs) := by
  have hk := kindOf_mm ho
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by rw [hpr] at hf; unfold need at hf; simp [mkOut, length_callToks] at hf; omega⟩
      rw [hpr] at hf ⊢
      simp only [mkOut, length_callToks] at hf ⊢
      have hca := pList_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart, isCmpTok, cmpOf]))
        (by simp) (Or.inl rfl) xs hx rest (g + 1) (by simp at hf; unfold need at hf ⊢; omega)
      simp only [callToks, lpC, List.cons_append, List.nil_append, List.append_assoc]
      rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
      · rw [pPrim.eq_def]; simp only [isLp, ↓reduceIte]; rw [hca]; simp [hl]
      · rw [pPrim.eq_def]; simp only [isLp, ↓reduceIte]; rw [hca]; simp [hl]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;>
      exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · apply addAcc_node; rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> decide
  · rw [hpr]; rfl

theorem M_ic (c : Ctx) (o n : String) (ho : kindOf o = .ic) (hn : nameOK n = true)
    (hpr : pr c (node o [.str n]) = mkOut c.sf 10 (nameToks c n ++ icTail c.sf)) :
    M c (node o [.str n]) := by
  have := kindOf_ic ho; subst this
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by rw [hpr] at hf; unfold need at hf; simp [mkOut] at hf; omega⟩
      rw [hpr]; simp only [mkOut, List.append_assoc]
      rw [pPrim_name_eq]
      unfold pNamePrim
      have hstop : NameStop c.sf (icTail c.sf ++ rest) := by
        refine ⟨fun r e => ?_, ?_⟩
        · cases hs : c.sf <;> simp [icTail, hs] at e
        · cases c.sf <;> simp [icTail, subPat]
      rw [pName_nameToks c n hn _ hstop]
      simp only
      have hic : icTailP c.sf (icTail c.sf ++ rest) = some rest := by
        cases c.sf <;> simp [icTail, icTailP]
      rw [hic]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp only [mkOut]
    obtain ⟨t, tr, he, hh⟩ := nameToks_head c n
    rw [he]
    exact headOK_append (nameHead_ok c n t tr hh) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

end Esm.Document.Math
