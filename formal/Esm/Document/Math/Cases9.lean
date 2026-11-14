import Esm.Document.Math.Cases8

/-!
# Round trip, case by case: `ifelse` as `cases`
-/

namespace Esm.Document.Math

open Esm.Document

theorem rows_parse (c : Ctx) (cnd a b : Json) (hc : M c cnd) (ha : M c a) (hb : M c b)
    (rest : List Tok) (f : Nat)
    (hf : need 1 ((caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow).length + 1) ≤ f + 1) :
    pCases c (f + 1) ((caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow) ++
      casesEnd c.sf :: rest) = some (node "ifelse" [cnd, a, b], rest) := by
  have hsep : ∀ r, Fol c.sf 1 (Tok.kw (if c.sf = .latex then .nl else .comma) :: r) := by
    intro r; cases c.sf <;> exact fol1_kw _ _ (by simp) r
  simp only [caseRow, List.length_append, List.length_cons, List.length_nil] at hf
  have h1 := child1 ha (.kw .amp :: .txt "if " :: ((pr c cnd).at c.sf 1 ++
      .kw (if c.sf = .latex then .nl else .comma) :: ((pr c b).crow ++ casesEnd c.sf :: rest)))
    (fol1_kw _ .amp (by simp) _) f (by unfold need at hf ⊢; omega)
  have h2 := child1 hc (.kw (if c.sf = .latex then .nl else .comma) :: ((pr c b).crow ++ casesEnd c.sf :: rest))
    (hsep _) f (by unfold need at hf ⊢; omega)
  have h3 := hb.2.2.1 rest f (by unfold need at hf ⊢; omega)
  simp only [caseRow, List.append_assoc, List.cons_append, List.nil_append]
  rw [pCases, h1]
  simp only
  rw [h2]
  simp only [↓reduceIte, h3, Option.map_some]

theorem M_ite (c : Ctx) (o : String) (cnd a b : Json) (ho : kindOf o = .ite) (hc : M c cnd)
    (ha : M c a) (hb : M c b)
    (hpr : pr c (node o [cnd, a, b]) =
      ⟨10, casesToks c.sf (caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow),
        caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow⟩) :
    M c (node o [cnd, a, b]) := by
  have := kindOf_ite ho; subst this
  have h0 : P0 c (node "ifelse" [cnd, a, b]) := by
    apply P0_of_prim
    · intro rest hr f hf
      rw [hpr] at hf ⊢
      simp only at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
      have hrows := rows_parse c cnd a b hc ha hb rest g (by
        simp only [casesToks] at hf
        split at hf <;> simp only [List.length_append, List.length_cons, List.length_nil] at hf ⊢ <;>
          unfold need at hf ⊢ <;> omega)
      unfold casesToks
      split
      · rename_i hs
        have he : casesEnd c.sf = .kw .ecases := by simp [casesEnd, hs]
        rw [he] at hrows
        simp only [List.cons_append, List.append_assoc, List.nil_append] at hrows ⊢
        rw [pPrim.eq_def]; simp only
        rw [hrows]
      · rename_i hs
        have he : casesEnd c.sf = .kw .rp := by simp [casesEnd, hs]
        rw [he] at hrows
        simp only [List.cons_append, List.append_assoc, List.nil_append] at hrows ⊢
        rw [pPrim.eq_def]; simp only [isLp, ↓reduceIte]
        rw [hrows]
    · rw [hpr]; exact Nat.le_of_ble_eq_true rfl
    · rw [hpr]
  have hh : HeadOK c (pr c (node "ifelse" [cnd, a, b])).toks := by
    rw [hpr]; simp only [casesToks]
    cases c.sf <;> exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  have hl1 : 1 ≤ (pr c (node "ifelse" [cnd, a, b])).lvl := by rw [hpr]; simp
  have hl10 : (pr c (node "ifelse" [cnd, a, b])).lvl ≤ 10 := by rw [hpr]
  have hPL := PL_of c _ h0 hh hl1 hl10
  refine ⟨hPL, PA_generic c _ hPL (by rw [hpr]; simp) (addAcc_node (by decide)), ?_, hh, hl1, hl10⟩
  intro rest f hf
  rw [hpr] at hf ⊢
  simp only at hf ⊢
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  exact rows_parse c cnd a b hc ha hb rest g hf

end Esm.Document.Math
