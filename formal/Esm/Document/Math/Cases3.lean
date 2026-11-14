import Esm.Document.Math.Loops

/-!
# Round trip, case by case: literals, prefix and infix operators
-/

namespace Esm.Document.Math

open Esm.Document

theorem PL_at {c : Ctx} {a : Json} (h : M c a) (L : Nat) (h1 : 1 ≤ L) (h10 : L ≤ 10) (rest : List Tok)
    (hr : Fol c.sf L rest) (f : Nat) (hf : need L ((pr c a).at c.sf L).length ≤ f) :
    pLvl c f L ((pr c a).at c.sf L ++ rest) = some (a, rest) := h.1 L h1 h10 rest hr f hf

theorem fol_kw (sf : Sf) (L : Nat) (k : Kw) (r : List Tok) (h : conts sf L (.kw k) = false) :
    Fol sf L (.kw k :: r) := by
  intro t r' e; cases e; exact h

theorem M_tru (c : Ctx) (o : String) (ho : kindOf o = .tru)
    (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "true"]) : M c (node o []) := by
  have := kindOf_tru ho; subst this
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
      rw [hpr, pPrim.eq_def]; rfl
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

theorem M_fls (c : Ctx) (o : String) (ho : kindOf o = .fls)
    (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "false"]) : M c (node o []) := by
  have := kindOf_fls ho; subst this
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
      rw [hpr, pPrim.eq_def]; rfl
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

theorem M_lnot (c : Ctx) (o : String) (a : Json) (ho : kindOf o = .lnot) (ha : M c a)
    (hpr : pr c (node o [a]) = mkOut c.sf 6 (.kw .lnot :: (pr c a).at c.sf 6)) : M c (node o [a]) := by
  have := kindOf_lnot ho; subst this
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut, List.length_cons] at hr hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
    have h6 := PL_at ha 6 (by omega) (by omega) rest hr g (by unfold need at hf ⊢; omega)
    rw [pLvl6] at h6
    rw [pLvl6, List.cons_append, pNot.eq_2, h6]
  · rw [hpr]; exact headOK_kw c _ _ ⟨.lnot, rfl, rfl, by decide, by decide⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

/-- A child in parentheses reads back at any level. -/
theorem grp_child {c : Ctx} {a : Json} (ha : M c a) (L : Nat) (h1 : 1 ≤ L) (h10 : L ≤ 10)
    (rest : List Tok) (hr : Fol c.sf L rest) (f : Nat)
    (hf : need L ((pr c a).toks.length + 2) ≤ f) :
    pLvl c f L (grp c.sf (pr c a).toks ++ rest) = some (a, rest) := by
  have hl1 : 1 ≤ (pr c a).lvl := ha.2.2.2.2.1
  have hp : ∀ f, need 1 (pr c a).toks.length + 1 ≤ f →
      pLvl c f (L + (10 - L)) (grp c.sf (pr c a).toks ++ rest) = some (a, rest) := by
    intro f hf
    rw [show L + (10 - L) = 10 by omega, pLvl10]
    refine pPrim_grp c a (pr c a).toks (M_head ha) (fun rest hr f hf => ?_) rest f hf
    have := child1 ha rest hr f (by rw [at_eq]; simpa [hl1] using hf)
    rwa [at_eq, iteT hl1] at this
  exact lift (10 - L) L h1 (by omega) hp hr f (by unfold need at hf ⊢; omega)

theorem M_neg (c : Ctx) (o : String) (a : Json) (ho : kindOf o = .minus) (ha : M c a)
    (hpr : pr c (node o [a]) =
      mkOut c.sf 5 (.kw .minus :: (if startsNum ((pr c a).at c.sf 5) then grp c.sf ((pr c a).at c.sf 5)
        else (pr c a).at c.sf 5))) : M c (node o [a]) := by
  have := kindOf_minus ho; subst this
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut] at hr hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
    rw [pLvl5, List.cons_append, pMul.eq_2]
    split at hf
    · rename_i hn
      -- the operand starts with a number, so it is not in parentheses already
      have hlvl : 5 ≤ (pr c a).lvl := by
        by_contra hc
        rw [at_eq, iteF hc] at hn
        simp [grp, startsNum] at hn
      have heq : (pr c a).at c.sf 5 = (pr c a).toks := by rw [at_eq, iteT hlvl]
      rw [iteT hn, heq]
      rw [heq] at hf
      have := grp_child ha 5 (by omega) (by omega) rest hr g (by
        simp only [List.length_cons, length_grp] at hf; unfold need at hf ⊢; omega)
      rw [pLvl5] at this
      rw [this]
    · rename_i hn
      rw [iteF hn]
      have := PL_at ha 5 (by omega) (by omega) rest hr g (by
        simp only [List.length_cons] at hf; unfold need at hf ⊢; omega)
      rw [pLvl5] at this
      rw [this]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inr rfl⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl


theorem headOK_append {c : Ctx} {A : List Tok} (h : HeadOK c A) (X : List Tok) : HeadOK c (A ++ X) := by
  match A, h with
  | t :: r, ⟨h1, h2, h3, h4, h5, h6⟩ =>
    refine ⟨h1, h2, h3, h4, fun hd => ?_, h6⟩
    rcases h5 hd with h | ⟨r', rfl⟩ | ⟨r', rfl⟩
    · exact Or.inl h
    · exact Or.inr (Or.inl ⟨r' ++ X, rfl⟩)
    · exact Or.inr (Or.inr ⟨r' ++ X, rfl⟩)

theorem M_cmp (c : Ctx) (o : String) (k : Kw) (a b : Json) (ho : kindOf o = .cmp k) (ha : M c a)
    (hb : M c b)
    (hpr : pr c (node o [a, b]) = mkOut c.sf 3 ((pr c a).at c.sf 4 ++ .kw k :: (pr c b).at c.sf 4)) :
    M c (node o [a, b]) := by
  have hk := kindOf_cmp ho
  have hkc : conts c.sf 4 (.kw k) = false := by
    cases k <;> simp_all [cmpOf, conts, isCmpTok, atomStart]
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut, List.length_append, List.length_cons] at hr hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
    have h1 := PL_at ha 4 (by omega) (by omega) _ (fol_kw _ _ k ((pr c b).at c.sf 4 ++ rest) hkc)
      (g + 2) (by unfold need at hf ⊢; omega)
    have h2 := PL_at hb 4 (by omega) (by omega) rest (hr.mono (by omega)) (g + 1)
      (by unfold need at hf ⊢; omega)
    rw [pLvl4] at h1 h2
    rw [pLvl3, pCmp, List.append_assoc, List.cons_append, h1]
    simp only
    rw [cmpLoop.eq_2, hk]
    simp only
    rw [h2]
  · rw [hpr]; exact headOK_append (headOK_at ha 4) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · apply addAcc_node; intro e; subst e
    cases k <;> simp [cmpOf] at hk
  · rw [hpr]; rfl


theorem length_le_flat : ∀ (bs : List (Json × List Tok)), (∀ p ∈ bs, 1 ≤ p.2.length) →
    bs.length ≤ (bs.flatMap Prod.snd).length
  | [], _ => by simp
  | p :: bs, h => by
    have := length_le_flat bs (fun q hq => h q (by simp [hq]))
    have hp := h p (by simp)
    simp only [List.length_cons, List.flatMap_cons, List.length_append]; omega

theorem map_fst_pair {α β : Type} (f : α → β) (l : List α) :
    l.map (Prod.fst ∘ fun y => (y, f y)) = l := by
  induction l with
  | nil => rfl
  | cons a l ih => simp only [List.map_cons, Function.comp_apply, ih]

/-- The blocks after the first operand of a chain with a separator token. -/
def sepBlocks (sep : Tok) (c : Ctx) (L : Nat) (ys : List Json) : List (Json × List Tok) :=
  ys.map fun y => (y, sep :: (pr c y).at c.sf L)

theorem sepBy_blocks (sep : Tok) (c : Ctx) (L : Nat) (x : Json) (ys : List Json) :
    sepBy [sep] ((x :: ys).map fun y => (pr c y).at c.sf L) =
      (pr c x).at c.sf L ++ (sepBlocks sep c L ys).flatMap Prod.snd := by
  simp [sepBy_cons, sepBlocks, List.flatMap_map]

theorem fol_blocks (sf : Sf) (L : Nat) (sep : Tok) (c : Ctx) (L' : Nat) (ys : List Json)
    (hs : ∀ r, Fol sf L (sep :: r)) :
    ∀ p ∈ sepBlocks sep c L' ys, ∀ r, Fol sf L (p.2 ++ r) := by
  intro p hp r
  simp only [sepBlocks, List.mem_map] at hp
  obtain ⟨y, -, rfl⟩ := hp
  exact hs _

theorem len_blocks (sep : Tok) (c : Ctx) (L : Nat) (ys : List Json) (hy : ∀ y ∈ ys, M c y) :
    ∀ p ∈ sepBlocks sep c L ys, 2 ≤ p.2.length := by
  intro p hp
  simp only [sepBlocks, List.mem_map] at hp
  obtain ⟨y, hyy, rfl⟩ := hp
  have := len_pos_of_head (headOK_at (hy y hyy) L)
  simp only [List.length_cons]; omega

theorem mem_blocks {sep : Tok} {c : Ctx} {L : Nat} {ys : List Json} {p : Json × List Tok}
    (hp : p ∈ sepBlocks sep c L ys) : p.1 ∈ ys ∧ p.2 = sep :: (pr c p.1).at c.sf L := by
  simp only [sepBlocks, List.mem_map] at hp
  obtain ⟨y, hyy, rfl⟩ := hp
  exact ⟨hyy, rfl⟩

theorem plus_PA (c : Ctx) (xs : List Json) (hl : 2 ≤ xs.length) (hx : ∀ x ∈ xs, M c x)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : need 4 (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5)).length ≤ f) :
    ∃ g, f ≤ g + 30 * (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5)).length + 4 ∧
      pAdd c f (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5) ++ rest) = addLoop c g xs rest := by
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  have hys : ys ≠ [] := by rintro rfl; simp at hl
  rw [sepBy_blocks] at hf ⊢
  have hbl := block_len_le (sepBlocks (.kw .plus) c 5 ys) (fun p hp => by
    have := len_blocks (.kw .plus) c 5 ys (fun y hy => hx y (by simp [hy])) p hp
    omega)
  have hn := length_le_flat (sepBlocks (Tok.kw .plus) c 5 ys) (fun p hp => by
    have := len_blocks (.kw .plus) c 5 ys (fun y hy => hx y (by simp [hy])) p hp
    omega)
  simp only [List.length_append] at hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  have hfol : Fol c.sf 5 ((sepBlocks (.kw .plus) c 5 ys).flatMap Prod.snd ++ rest) := by
    obtain ⟨y, ys', rfl⟩ := List.exists_cons_of_ne_nil hys
    intro t r e
    simp only [sepBlocks, List.map_cons, List.flatMap_cons, List.cons_append, List.cons.injEq] at e
    rw [← e.1]; simp [conts]
  have h1 := PL_at (hx x1 (by simp)) 5 (by omega) (by omega) _ hfol g (by unfold need at hf ⊢; omega)
  rw [pLvl5] at h1
  rw [pAdd, List.append_assoc, h1]
  simp only
  rw [chain (addLoop c) (Fol c.sf 5) (fun p => need 5 (p.2.length - 1)) rest hr
    (sepBlocks (.kw .plus) c 5 ys) (fol_blocks c.sf 5 (.kw .plus) c 5 ys (fun r => by
      intro t r' e; cases e; simp [conts]))
    (by
      intro p hp f acc r hQ hW
      obtain ⟨hpy, hp2⟩ := mem_blocks hp
      rw [hp2, List.cons_append, addLoop.eq_2]
      rw [hp2] at hW
      simp only [List.length_cons, Nat.add_sub_cancel] at hW
      have := PL_at (hx p.1 (by simp [hpy])) 5 (by omega) (by omega) r hQ f hW
      rw [pLvl5] at this
      rw [this])
    [x1] g (fun p hp => by have := hbl p hp; unfold need at hf ⊢; omega)
    (by unfold need at hf; omega)]
  refine ⟨g - (sepBlocks (.kw .plus) c 5 ys).length, ?_, ?_⟩
  · unfold need at hf; simp only [List.length_append]; omega
  · simp only [sepBlocks, List.map_map, List.singleton_append, map_fst_pair]


theorem close_node (o : String) (xs : List Json) (h : 2 ≤ xs.length) : close o xs = node o xs := by
  match xs, h with
  | a :: b :: r, _ => rfl

theorem M_plus (c : Ctx) (o : String) (xs : List Json) (ho : kindOf o = .plus) (hl : 2 ≤ xs.length)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) = mkOut c.sf 4 (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5))) :
    M c (node o xs) := by
  have := kindOf_plus ho; subst this
  have hacc : addAcc (node "+" xs) = xs := by
    unfold addAcc node; simp only [iteT hl]
  have hat : (pr c (node "+" xs)).at c.sf 4 = sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5) := by
    rw [at_eq, hpr]; simp [mkOut]
  have hPA : PA c (node "+" xs) := by
    intro rest hr f hf
    rw [hat] at hf ⊢
    rw [hacc]
    exact plus_PA c xs hl hx rest hr f hf
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  have hh : HeadOK c (pr c (node "+" (x1 :: ys))).toks := by
    rw [hpr]; simp only [mkOut]; rw [sepBy_blocks]
    exact headOK_append (headOK_at (hx x1 (by simp)) 5) _
  have h0 : P0 c (node "+" (x1 :: ys)) := by
    intro rest hr f hf
    have hl4 : (pr c (node "+" (x1 :: ys))).lvl = 4 := by rw [hpr]; rfl
    rw [hl4] at hr hf ⊢
    rw [hpr] at hf ⊢; simp only [mkOut] at hf ⊢
    obtain ⟨g, hg, he⟩ := plus_PA c (x1 :: ys) hl hx rest (hr.mono (by omega)) f hf
    rw [pLvl4, he]
    obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by unfold need at hf; omega⟩
    rw [addLoop_stop c g' _ rest hr, close_node "+" _ hl]
  have hPL := PL_of c _ h0 hh (by rw [hpr]; simp [mkOut]) (by rw [hpr]; simp [mkOut])
  exact ⟨hPL, hPA, PCr_generic c _ hPL (by rw [hpr]; rfl) (by rw [hpr]; simp [mkOut]), hh,
    by rw [hpr]; simp [mkOut], by rw [hpr]; simp [mkOut]⟩

theorem M_minus (c : Ctx) (o : String) (a b : Json) (ho : kindOf o = .minus) (ha : M c a) (hb : M c b)
    (hpr : pr c (node o [a, b]) = mkOut c.sf 4 ((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5)) :
    M c (node o [a, b]) := by
  have := kindOf_minus ho; subst this
  have hacc : addAcc (node "-" [a, b]) = [node "-" [a, b]] := addAcc_node (by decide)
  -- the shared parse: the left operand's state, then `- b`
  have key : ∀ rest, Fol c.sf 5 rest → ∀ f,
      need 4 ((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5).length ≤ f →
      ∃ g, f ≤ g + 30 * ((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5).length + 4 ∧
        pAdd c f (((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5) ++ rest) =
          addLoop c g [node "-" [a, b]] rest := by
    intro rest hr f hf
    simp only [List.length_append, List.length_cons] at hf ⊢
    have hfm : Fol c.sf 5 (Tok.kw .minus :: ((pr c b).at c.sf 5 ++ rest)) := by
      intro t r e; cases e; simp [conts]
    obtain ⟨g, hg, he⟩ := ha.2.1 _ hfm f (by unfold need at hf ⊢; omega)
    obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by unfold need at hf; omega⟩
    have hbp := PL_at hb 5 (by omega) (by omega) rest hr g' (by unfold need at hf ⊢; omega)
    rw [pLvl5] at hbp
    refine ⟨g', by omega, ?_⟩
    rw [List.append_assoc, List.cons_append, he, addLoop.eq_3, hbp]
    simp only [close_addAcc]
  have hat : (pr c (node "-" [a, b])).at c.sf 4 = (pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5 := by
    rw [at_eq, hpr]; simp [mkOut]
  have hPA : PA c (node "-" [a, b]) := by
    intro rest hr f hf
    rw [hat] at hf ⊢
    rw [hacc]
    exact key rest hr f hf
  have hh : HeadOK c (pr c (node "-" [a, b])).toks := by
    rw [hpr]; exact headOK_append (headOK_at ha 4) _
  have h0 : P0 c (node "-" [a, b]) := by
    intro rest hr f hf
    have hl4 : (pr c (node "-" [a, b])).lvl = 4 := by rw [hpr]; rfl
    rw [hl4] at hr hf ⊢
    rw [hpr] at hf ⊢; simp only [mkOut] at hf ⊢
    obtain ⟨g, hg, he⟩ := key rest (hr.mono (by omega)) f hf
    rw [pLvl4, he]
    obtain ⟨g', rfl⟩ : ∃ g', g = g' + 1 := ⟨g - 1, by unfold need at hf; omega⟩
    rw [addLoop_stop c g' _ rest hr]; rfl
  have hPL := PL_of c _ h0 hh (by rw [hpr]; simp [mkOut]) (by rw [hpr]; simp [mkOut])
  exact ⟨hPL, hPA, PCr_generic c _ hPL (by rw [hpr]; rfl) (by rw [hpr]; simp [mkOut]), hh,
    by rw [hpr]; simp [mkOut], by rw [hpr]; simp [mkOut]⟩

end Esm.Document.Math
