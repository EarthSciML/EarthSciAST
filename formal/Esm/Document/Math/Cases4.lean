import Esm.Document.Math.Cases3

/-!
# Round trip, case by case: the `and`, `or` and `*` chains
-/

namespace Esm.Document.Math

open Esm.Document

/-- A chain `x₁ sep x₂ sep …` at level `L`, each operand at level `L + 1`, reads back. -/
theorem sepChain (c : Ctx) (L : Nat) (hL1 : 1 ≤ L) (hL : L ≤ 3) (sep : Kw) (o : String)
    (loop : Nat → List Json → List Tok → Option (Json × List Tok))
    (hstep : ∀ f acc r, loop (f + 1) acc (.kw sep :: r) =
      match pLvl c f (L + 1) r with | some (y, r') => loop f (acc ++ [y]) r' | none => none)
    (htop : ∀ f ts, pLvl c (f + 1) L ts =
      match pLvl c f (L + 1) ts with | some (x, r) => loop f [x] r | none => none)
    (hstop : ∀ f acc r, Fol c.sf L r → loop (f + 1) acc r = some (close o acc, r))
    (hsepF : ∀ r, Fol c.sf (L + 1) (.kw sep :: r))
    (xs : List Json) (hl : 2 ≤ xs.length) (hx : ∀ x ∈ xs, M c x) (rest : List Tok)
    (hr : Fol c.sf L rest) (f : Nat)
    (hf : need L (sepBy [.kw sep] (xs.map fun x => (pr c x).at c.sf (L + 1))).length ≤ f) :
    pLvl c f L (sepBy [.kw sep] (xs.map fun x => (pr c x).at c.sf (L + 1)) ++ rest) =
      some (node o xs, rest) := by
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  have hys : ys ≠ [] := by rintro rfl; simp at hl
  rw [sepBy_blocks] at hf ⊢
  have hbl := block_len_le (sepBlocks (.kw sep) c (L + 1) ys) (fun p hp => by
    have := len_blocks (.kw sep) c (L + 1) ys (fun y hy => hx y (by simp [hy])) p hp
    omega)
  have hn := length_le_flat (sepBlocks (Tok.kw sep) c (L + 1) ys) (fun p hp => by
    have := len_blocks (.kw sep) c (L + 1) ys (fun y hy => hx y (by simp [hy])) p hp
    omega)
  simp only [List.length_append] at hf
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  have hfol : Fol c.sf (L + 1) ((sepBlocks (.kw sep) c (L + 1) ys).flatMap Prod.snd ++ rest) := by
    obtain ⟨y, ys', rfl⟩ := List.exists_cons_of_ne_nil hys
    simp only [sepBlocks, List.map_cons, List.flatMap_cons, List.cons_append]
    exact hsepF _
  have h1 := PL_at (hx x1 (by simp)) (L + 1) (by omega) (by omega) _ hfol g
    (by unfold need at hf ⊢; omega)
  rw [htop, List.append_assoc, h1]
  simp only
  rw [chain loop (Fol c.sf (L + 1)) (fun p => need (L + 1) (p.2.length - 1)) rest (hr.mono (by omega))
    (sepBlocks (.kw sep) c (L + 1) ys) (fol_blocks c.sf (L + 1) (.kw sep) c (L + 1) ys hsepF)
    (by
      intro p hp f acc r hQ hW
      obtain ⟨hpy, hp2⟩ := mem_blocks hp
      rw [hp2, List.cons_append, hstep]
      rw [hp2] at hW
      simp only [List.length_cons, Nat.add_sub_cancel] at hW
      rw [PL_at (hx p.1 (by simp [hpy])) (L + 1) (by omega) (by omega) r hQ f hW])
    [x1] g (fun p hp => by have := hbl p hp; unfold need at hf ⊢; omega) (by unfold need at hf; omega)]
  obtain ⟨g', hg'⟩ : ∃ g', g - (sepBlocks (Tok.kw sep) c (L + 1) ys).length = g' + 1 :=
    ⟨g - (sepBlocks (Tok.kw sep) c (L + 1) ys).length - 1, by unfold need at hf; omega⟩
  rw [hg', hstop _ _ _ hr]
  simp only [sepBlocks, List.map_map, List.singleton_append, map_fst_pair]
  rw [close_node o _ (by simpa using hl)]

theorem M_land (c : Ctx) (o : String) (xs : List Json) (ho : kindOf o = .land) (hl : 2 ≤ xs.length)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) = mkOut c.sf 2 (sepBy [.kw .land] (xs.map fun x => (pr c x).at c.sf 3))) :
    M c (node o xs) := by
  have := kindOf_land ho; subst this
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut] at hr hf ⊢
    exact sepChain c 2 (by omega) (by omega) .land "and" (andLoop c)
      (fun f acc r => by rw [andLoop.eq_2]; rfl) (fun f ts => by rw [pLvl2, pAnd]; rfl)
      (fun f acc r hr => andLoop_stop c f acc r hr)
      (fun r => fol_kw _ _ _ r (by simp [conts])) _ hl hx rest hr f hf
  · rw [hpr]; simp only [mkOut]; rw [sepBy_blocks]
    exact headOK_append (headOK_at (hx x1 (by simp)) 3) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

theorem M_lor (c : Ctx) (o : String) (xs : List Json) (ho : kindOf o = .lor) (hl : 2 ≤ xs.length)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) = mkOut c.sf 1 (sepBy [.kw .lor] (xs.map fun x => (pr c x).at c.sf 2))) :
    M c (node o xs) := by
  have := kindOf_lor ho; subst this
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut] at hr hf ⊢
    exact sepChain c 1 (by omega) (by omega) .lor "or" (orLoop c)
      (fun f acc r => by rw [orLoop.eq_2]; rfl) (fun f ts => by rw [pLvl1, pOr]; rfl)
      (fun f acc r hr => orLoop_stop c f acc r hr)
      (fun r => fol_kw _ _ _ r (by simp [conts])) _ hl hx rest hr f hf
  · rw [hpr]; simp only [mkOut]; rw [sepBy_blocks]
    exact headOK_append (headOK_at (hx x1 (by simp)) 2) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl


/-- The blocks after the first factor of a product. -/
def mulBlocks (c : Ctx) (ys : List Json) : List (Json × List Tok) :=
  ys.map fun y => (y, if startsNum ((pr c y).at c.sf 6) then .kw .cdot :: (pr c y).at c.sf 6
    else (pr c y).at c.sf 6)

theorem mulToks_blocks (c : Ctx) (x : Json) (ys : List Json) :
    mulToks ((x :: ys).map fun y => (pr c y).at c.sf 6) =
      (pr c x).at c.sf 6 ++ (mulBlocks c ys).flatMap Prod.snd := by
  simp [mulToks, mulBlocks, List.flatMap_map]

/-- A factor's tokens never start with what would end a product early or be read
otherwise after an operand. -/
theorem factor_head {c : Ctx} {a : Json} (ha : M c a) :
    ∃ t r, (pr c a).at c.sf 6 = t :: r ∧ atomStart t = true ∧ conts c.sf 6 t = false := by
  have hh := headOK_at ha 6
  obtain ⟨t, r, he⟩ : ∃ t r, (pr c a).at c.sf 6 = t :: r := by
    cases h : (pr c a).at c.sf 6 with
    | nil => rw [h] at hh; exact absurd hh (by simp [HeadOK])
    | cons t r => exact ⟨t, r, rfl⟩
  rw [he] at hh
  obtain ⟨-, -, -, -, -, h6⟩ := hh
  -- a factor's parse at level 6 succeeds, so it does not start with `-`
  have hp := PL_at ha 6 (by omega) (by omega) [] (Fol_nil _ _) (need 6 ((pr c a).at c.sf 6).length) le_rfl
  rw [he, pLvl6] at hp
  rcases h6 with h6 | rfl
  · refine ⟨t, r, he, ?_, ?_⟩
    · simp only [startA, Bool.and_eq_true] at h6; exact h6.1.1
    · simp only [startA, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at h6
      obtain ⟨⟨h1, h2⟩, h3⟩ := h6
      unfold conts
      split <;> simp_all [atomStart]
  · rw [List.cons_append, pNot_minus] at hp; cases hp

theorem M_times (c : Ctx) (o : String) (xs : List Json) (ho : kindOf o = .times) (hl : 2 ≤ xs.length)
    (hx : ∀ x ∈ xs, M c x)
    (hpr : pr c (node o xs) = mkOut c.sf 5 (mulToks (xs.map fun x => (pr c x).at c.sf 6))) :
    M c (node o xs) := by
  have := kindOf_times ho; subst this
  obtain ⟨x1, ys, rfl⟩ : ∃ x1 ys, xs = x1 :: ys := by
    cases xs with
    | nil => simp at hl
    | cons x ys => exact ⟨x, ys, rfl⟩
  have hys : ys ≠ [] := by rintro rfl; simp at hl
  have hblk : ∀ p ∈ mulBlocks c ys, ∃ t r, p.2 = t :: r ∧ conts c.sf 6 t = false ∧ 2 ≤ (p.2.length + 1) ∧
      p.1 ∈ ys := by
    intro p hp
    simp only [mulBlocks, List.mem_map] at hp
    obtain ⟨y, hy, rfl⟩ := hp
    obtain ⟨t, r, he, h1, h2⟩ := factor_head (hx y (by simp [hy]))
    simp only [he]
    split
    · exact ⟨_, _, rfl, by simp [conts], by simp, hy⟩
    · exact ⟨_, _, rfl, h2, by simp, hy⟩
  apply M_of
  · intro rest hr f hf
    simp only [hpr, mkOut] at hr hf ⊢
    rw [mulToks_blocks] at hf ⊢
    have hbl := block_len_le (mulBlocks c ys) (fun p hp => by
      obtain ⟨t, r, he, -⟩ := hblk p hp; rw [he]; simp)
    have hn := length_le_flat (mulBlocks c ys) (fun p hp => by
      obtain ⟨t, r, he, -⟩ := hblk p hp; rw [he]; simp)
    simp only [List.length_append] at hf
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
    have hfol : Fol c.sf 6 ((mulBlocks c ys).flatMap Prod.snd ++ rest) := by
      obtain ⟨y, ys', rfl⟩ := List.exists_cons_of_ne_nil hys
      obtain ⟨t, r, he, h2, -⟩ := hblk (y, if startsNum ((pr c y).at c.sf 6) then .kw .cdot :: (pr c y).at c.sf 6
        else (pr c y).at c.sf 6) (by simp [mulBlocks])
      simp only [mulBlocks, List.map_cons, List.flatMap_cons] at he ⊢
      rw [List.append_assoc, he]
      intro t' r' e; simp only [List.cons_append, List.cons.injEq] at e; rw [← e.1]; exact h2
    have h1 := PL_at (hx x1 (by simp)) 6 (by omega) (by omega) _ hfol g
      (by unfold need at hf ⊢; omega)
    rw [pLvl6] at h1
    have hnm : ∀ r', (pr c x1).at c.sf 6 ++ ((mulBlocks c ys).flatMap Prod.snd ++ rest) ≠ .kw .minus :: r' := by
      intro r' e; rw [e, pNot_minus] at h1; cases h1
    rw [pLvl5, List.append_assoc, pMul.eq_3 _ _ _ hnm, h1]
    simp only
    rw [chain (mulLoop c) (Fol c.sf 6)
      (fun p => need 6 (p.2.length - (if startsNum ((pr c p.1).at c.sf 6) then 1 else 0))) rest
      (hr.mono (by omega)) (mulBlocks c ys)
      (by
        intro p hp r
        obtain ⟨t, r', he, h2, -⟩ := hblk p hp
        rw [he]; intro t'' r'' e; simp only [List.cons_append, List.cons.injEq] at e; rw [← e.1]; exact h2)
      (by
        intro p hp f acc r hQ hW
        simp only [mulBlocks, List.mem_map] at hp
        obtain ⟨y, hy, rfl⟩ := hp
        have hyM := hx y (by simp [hy])
        simp only at hW ⊢
        split
        · rename_i hsn
          simp only [hsn, ↓reduceIte, List.length_cons, Nat.add_sub_cancel] at hW
          rw [List.cons_append, mulLoop.eq_2]
          have := PL_at hyM 6 (by omega) (by omega) r hQ f hW
          rw [pLvl6] at this
          rw [this]
        · rename_i hsn
          simp only [hsn, Bool.false_eq_true, ↓reduceIte, Nat.sub_zero] at hW
          obtain ⟨t, r', he, h1, h2⟩ := factor_head hyM
          have := PL_at hyM 6 (by omega) (by omega) r hQ f hW
          rw [pLvl6] at this
          rw [he] at this ⊢
          have hc1 : t ≠ .kw .cdot := by rintro rfl; simp [atomStart] at h1
          have hc2 : t ≠ .kw .times := by rintro rfl; simp [atomStart] at h1
          have hc3 : t ≠ .kw .slash := by rintro rfl; simp [atomStart] at h1
          rw [List.cons_append, mulLoop.eq_5 _ _ _ _ _ hc1 hc2 hc3]
          simp only [h1, ↓reduceIte]
          rw [← List.cons_append, this])
      [x1] g (fun p hp => by
        have := hbl p hp
        have := len_pos_of_head (headOK_at (hx x1 (by simp)) 6)
        unfold need at hf ⊢; split <;> omega) (by unfold need at hf; omega)]
    obtain ⟨g', hg'⟩ : ∃ g', g - (mulBlocks c ys).length = g' + 1 :=
      ⟨g - (mulBlocks c ys).length - 1, by unfold need at hf; omega⟩
    rw [hg', mulLoop_stop c g' _ rest hr]
    simp only [mulBlocks, List.map_map, List.singleton_append, map_fst_pair]
    rw [close_node "*" _ (by simpa using hl)]
  · rw [hpr]; simp only [mkOut]; rw [mulToks_blocks]
    exact headOK_append (headOK_at (hx x1 (by simp)) 6) _
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_node (by decide)
  · rw [hpr]; rfl

end Esm.Document.Math
