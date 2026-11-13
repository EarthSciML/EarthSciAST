import Esm.Document.Math.Cases6

/-!
# Round trip, case by case: indices, fractions, powers, cases
-/

namespace Esm.Document.Math

open Esm.Document

theorem M_idxBr (c : Ctx) (o : String) (base : Json) (is : List Json) (ho : kindOf o = .index)
    (hne : is ≠ []) (hb : M c base) (hi : ∀ x ∈ is, M c x)
    (hpr : pr c (node o (base :: is)) = mkOut c.sf 9 ((pr c base).at c.sf 10 ++ [.kw .lbk] ++
      sepBy [.kw .comma] (is.map fun x => (pr c x).at c.sf 1) ++ [.kw .rbk])) :
    M c (node o (base :: is)) := by
  have := kindOf_index ho; subst this
  apply M_of
  · intro rest hr f hf
    have hl9 : (pr c (node "index" (base :: is))).lvl = 9 := by rw [hpr]; rfl
    rw [hl9] at hr hf ⊢
    rw [hpr] at hf ⊢; simp only [mkOut, List.length_append, List.length_singleton] at hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
    have hbp := PL_at hb 10 (by omega) le_rfl
      (.kw .lbk :: (sepBy [.kw .comma] (is.map fun x => (pr c x).at c.sf 1) ++ .kw .rbk :: rest))
      (fol_kw _ _ _ _ (by simp [conts])) (g + 2) (by unfold need at hf ⊢; omega)
    rw [pLvl10] at hbp
    have hl := pList_list c (.kw .rbk) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart, isCmpTok, cmpOf]))
      (by simp) (Or.inr (Or.inr (Or.inr rfl))) is hi rest (g + 1) (by unfold need at hf ⊢; omega)
    rw [pLvl9, pPost]
    simp only [List.append_assoc, List.cons_append, List.nil_append] at hbp ⊢
    rw [hbp]
    simp only
    rw [postLoop.eq_6, hl]
    simp only [hne, ↓reduceIte]
    exact postLoop_stop c g _ rest hr
  · rw [hpr]; simp only [mkOut, List.append_assoc]; exact headOK_append (headOK_at hb 10) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl


theorem simpleE_parse (c : Ctx) (x : Json) (hx : isE x = true) (t : Tok) (h : simpleE c x = some t)
    (f : Nat) : pPrim c (f + 1) [t] = some (x, []) ∧ simpleTok t = true ∧ t ≠ .kw .lpg := by
  unfold simpleE at h
  split at h
  · rename_i n
    split at h
    · rename_i hs
      cases h
      refine ⟨pPrim_num c n [] (Fol_nil _ _) f, hs, by simp⟩
    · cases h
  · rename_i s
    split at h
    · rename_i t' ht'
      split at h
      · rename_i hs
        cases h
        have hn : nameOK s = true := by rw [isE] at hx; exact hx
        have := pPrim_name c s hn [] (Fol_nil _ _) f
        rw [ht'] at this
        refine ⟨by simpa using this, hs, ?_⟩
        rintro rfl; simp [simpleTok] at hs
      · cases h
    · cases h
  · cases h

theorem subPat_append (sf : Sf) (A rest : List Tok) (h : subPat sf A = false) (hl : 4 ≤ A.length) :
    subPat sf (A ++ rest) = false := by
  match A, hl with
  | a :: b :: d :: e :: r, _ => exact h

theorem subPat4_second (sf : Sf) (t1 t2 t3 t4 : Tok) (h1 : t2 ≠ .kw .lb) (h2 : t2 ≠ .kw .lpg) :
    subPat4 sf t1 t2 t3 t4 = false := by
  unfold subPat4
  split
  · exact absurd rfl h1
  · exact absurd rfl h2
  · rfl

theorem subPat_second (sf : Sf) (t1 t2 : Tok) (X : List Tok) (h1 : t2 ≠ .kw .lb) (h2 : t2 ≠ .kw .lpg) :
    subPat sf (t1 :: t2 :: X) = false := by
  match X with
  | [] => rfl
  | [_] => rfl
  | t3 :: t4 :: r => exact subPat4_second sf t1 t2 t3 t4 h1 h2

theorem simpleArg_some {c : Ctx} {is : List Json} {t : Tok} (h : simpleArg c is = some t) :
    ∃ x, is = [x] ∧ simpleE c x = some t := by
  unfold simpleArg at h
  split at h
  · exact ⟨_, rfl, h⟩
  · cases h

theorem M_idxSub (c : Ctx) (o b : String) (is : List Json) (ho : kindOf o = .index) (hne : is ≠ [])
    (hsub : subOK c.S (.str b) is = true)
    (hsp : subPat c.sf (subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1)) = false)
    (hi : ∀ x ∈ is, M c x) (hie : ∀ x ∈ is, isE x = true)
    (hpr : pr c (node o (.str b :: is)) =
      mkOut c.sf 9 (nameToks c b ++ subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1))) :
    M c (node o (.str b :: is)) := by
  have := kindOf_index ho; subst this
  have hbn : nameOK b = true := by unfold subOK at hsub; simp only [Bool.and_eq_true] at hsub; exact hsub.1.1.1
  have hSlen : 1 ≤ (sepBy [.kw .comma] (is.map fun x => (pr c x).at c.sf 1)).length := by
    obtain ⟨x, xs, rfl⟩ := List.exists_cons_of_ne_nil hne
    have := len_pos_of_head (headOK_at (hi x (by simp)) 1)
    rw [List.map_cons, sepBy_cons]; simp only [List.length_append]; omega
  apply M_of
  · intro rest hr f hf
    have hl9 : (pr c (node "index" (.str b :: is))).lvl = 9 := by rw [hpr]; rfl
    rw [hl9] at hr hf ⊢
    rw [hpr] at hf ⊢; simp only [mkOut, List.length_append] at hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
    -- the subscript starts with `_`, so the name stops before it
    have hus : ∃ X, subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1) = .kw .us :: X := by
      cases c.sf
      · exact ⟨_, rfl⟩
      · simp only [subList]; split <;> exact ⟨_, rfl⟩
    obtain ⟨X, hX⟩ := hus
    have hsp' : subPat c.sf (subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1) ++ rest) = false := by
      cases hs : c.sf
      · simp only [hs] at hsp hSlen ⊢
        apply subPat_append _ _ _ hsp
        simp [subList]; omega
      · simp only [hs] at hsp hSlen ⊢
        simp only [subList] at hsp ⊢
        split
        · rename_i t ht
          obtain ⟨x, rfl, hx⟩ := simpleArg_some ht
          obtain ⟨-, -, hlp⟩ := simpleE_parse c x (hie x (by simp)) t hx 0
          apply subPat_second
          · rintro rfl; obtain ⟨-, hs2, -⟩ := simpleE_parse c x (hie x (by simp)) _ hx 0; simp [simpleTok] at hs2
          · exact hlp
        · rename_i ht
          rw [ht] at hsp
          apply subPat_append _ _ _ hsp
          simp; omega
    have hstop : NameStop c.sf (subList c.sf (simpleArg c is) (is.map fun x => (pr c x).at c.sf 1) ++ rest) :=
      ⟨fun r e => by rw [hX] at e; simp at e, hsp'⟩
    rw [pLvl9, pPost, List.append_assoc, pPrim_name_eq]
    unfold pNamePrim
    rw [pName_nameToks c b hbn _ hstop]
    simp only
    rw [icTailP_none _ _ (fun r e => by rw [hX] at e; simp at e)]
    simp only
    have hstop9 := postLoop_stop c g (node "index" (.str b :: is)) rest hr
    cases hs : c.sf
    · have hl := pList_list c (.kw .rb) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart, isCmpTok, cmpOf]))
        (by simp) (Or.inr (Or.inr (Or.inl rfl))) is hi rest (g + 1) (by
          simp only [subList, hs, List.length_append, List.length_cons, List.length_nil] at hf ⊢
          unfold need at hf ⊢; omega)
      simp only [hs] at hl
      simp only [subList, List.cons_append, List.append_assoc, List.nil_append]
      rw [postLoop.eq_def]
      simp only [hs]
      rw [hl]
      simp only [hne, ↓reduceIte]
      exact hstop9
    · simp only [subList]
      split
      · rename_i t ht
        obtain ⟨x, rfl, hx⟩ := simpleArg_some ht
        obtain ⟨hp, hs2, hlp⟩ := simpleE_parse c x (hie x (by simp)) t hx g
        simp only [List.cons_append, List.nil_append]
        rw [postLoop.eq_def]
        simp only [hs]
        simp only [hs2, ↓reduceIte, hp]
        exact hstop9
      · rename_i ht
        have hl := pList_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart, isCmpTok, cmpOf]))
          (by simp) (Or.inl rfl) is hi rest (g + 1) (by
            simp only [subList, hs, ht, List.length_append, List.length_cons, List.length_nil] at hf ⊢
            unfold need at hf ⊢; omega)
        simp only [hs] at hl
        simp only [List.cons_append, List.append_assoc, List.nil_append]
        rw [postLoop.eq_def]
        simp only [hs]
        rw [hl]
        have hne' : is.isEmpty = false := by cases is <;> simp_all
        simp only [isRp, hne', Bool.not_false, Bool.and_self, ↓reduceIte]
        exact hstop9
  · rw [hpr]; simp only [mkOut]
    obtain ⟨t, tr, he, hh⟩ := nameToks_head c b
    rw [he]
    exact headOK_append (nameHead_ok c b t tr hh) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

end Esm.Document.Math
