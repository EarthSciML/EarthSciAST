import Esm.Document.Math.Cases4

/-!
# Round trip, case by case: fractions, powers, cases, initial conditions, indices, calls
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Lists -/

theorem headOK_closer {c : Ctx} {ts : List Tok} (h : HeadOK c ts) :
    ∃ t r, ts = t :: r ∧ isRp t = false ∧ t ≠ .kw .rb ∧ t ≠ .kw .rbk ∧ t ≠ .kw .semi ∧
      t ≠ .kw .comma ∧ t ≠ .kw .eq := by
  match ts, h with
  | t :: r, ⟨_, _, _, _, _, h6⟩ =>
    refine ⟨t, r, rfl, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    · rcases h6 with h6 | rfl
      · cases t with
        | kw k => cases k <;> simp_all [startA, atomStart, isRp]
        | _ => simp [isRp]
      · simp [isRp]

/-- A possibly empty comma list of children at level 1 before a closing token. -/
theorem pList_list (c : Ctx) (closer : Tok) (hcl : ∀ r, Fol c.sf 1 (closer :: r))
    (hcc : closer ≠ .kw .comma)
    (hcl' : closer = .kw .rp ∨ closer = .kw .rpg ∨ closer = .kw .rb ∨ closer = .kw .rbk)
    (xs : List Json) (hx : ∀ x ∈ xs, M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 1)).length + 3 ≤ f) :
    pList c f 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 1) ++ closer :: rest) =
      some (xs, closer :: rest) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  cases xs with
  | nil => simp only [List.map_nil, sepBy, List.nil_append, pList]; rcases hcl' with rfl | rfl | rfl | rfl <;> rfl
  | cons x xs =>
    have hp := pItems_list c 1 (Or.inl rfl) closer hcl hcc (x :: xs) (by simp) hx rest g (by omega)
    obtain ⟨t, r, he, h1, h2, h3, -⟩ := headOK_closer (headOK_at (hx x (by simp)) 1)
    have hs : sepBy [.kw .comma] ((x :: xs).map fun x => (pr c x).at c.sf 1) =
        t :: (r ++ (xs.map fun x => (pr c x).at c.sf 1).flatMap (fun y => [.kw .comma] ++ y)) := by
      rw [List.map_cons, sepBy_cons, he]; rfl
    rw [hs] at hp ⊢
    simp only [List.cons_append, pList, List.append_assoc] at hp ⊢
    rw [h1]
    simp only [Bool.or_self, Bool.false_eq_true, ↓reduceIte]
    exact hp

/-- Call arguments at level 4, positional. -/
theorem pCallItems_list (c : Ctx) (closer : Tok) (hcl : ∀ r, Fol c.sf 4 (closer :: r))
    (hcc : closer ≠ .kw .comma) (hce : closer ≠ .kw .eq) :
    ∀ (xs : List Json), xs ≠ [] → (∀ x ∈ xs, M c x) → ∀ rest f,
      need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4)).length + 2 ≤ f →
      pCallItems c f (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) ++ closer :: rest) =
        some (xs.map CallArg.pos, closer :: rest)
  | [], hne, _, _, _, _ => absurd rfl hne
  | [x], _, hM, rest, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hx := PL_at (hM x (by simp)) 4 (by omega) (by omega) (closer :: rest) (hcl rest) g
      (by simp only [List.map_cons, List.map_nil, sepBy] at hf; unfold need at hf ⊢; omega)
    rw [pLvl4] at hx
    simp only [List.map_cons, List.map_nil, sepBy]
    rw [pCallItems, hx]
    split
    · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq] at heq
      exact absurd heq.2.1 hce
    · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq] at heq
      exact absurd heq.2.1 hcc
    · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl⟩ := heq; rfl
    · rename_i heq; cases heq
  | x :: y :: ys, _, hM, rest, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, sepBy_cons2, List.length_append, List.length_singleton] at hf ⊢
    have hrest := pCallItems_list c closer hcl hcc hce (y :: ys) (by simp)
      (fun z hz => hM z (by simp [hz])) rest g (by simp only [List.map_cons]; unfold need at hf ⊢; omega)
    have hx := PL_at (hM x (by simp)) 4 (by omega) (by omega)
      (Tok.kw .comma :: (sepBy [.kw .comma] ((y :: ys).map fun x => (pr c x).at c.sf 4) ++ closer :: rest))
      (fol_kw c.sf 4 .comma _ (by simp [conts, atomStart])) g (by unfold need at hf ⊢; omega)
    rw [pLvl4] at hx
    simp only [List.map_cons] at hrest hx
    rw [pCallItems]
    simp only [List.append_assoc, List.cons_append, List.nil_append] at hx ⊢
    rw [hx]
    split
    · rename_i heq; simp at heq
    · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq] at heq
      obtain ⟨rfl, -, rfl⟩ := heq
      simp [hrest]
    · rename_i _ _ h1 h2 heq
      simp only [Option.some.injEq, Prod.mk.injEq] at heq
      exact absurd heq.2.symm (h2 _)
    · rename_i heq; cases heq

theorem pCallArgs_list (c : Ctx) (closer : Tok) (hcl : ∀ r, Fol c.sf 4 (closer :: r))
    (hcc : closer = .kw .rp ∨ closer = .kw .semi)
    (xs : List Json) (hx : ∀ x ∈ xs, M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4)).length + 3 ≤ f) :
    pCallArgs c f (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) ++ closer :: rest) =
      some (xs.map CallArg.pos, closer :: rest) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  cases xs with
  | nil => rcases hcc with rfl | rfl <;> rfl
  | cons x xs =>
    have hp := pCallItems_list c closer hcl (by rcases hcc with rfl | rfl <;> simp)
      (by rcases hcc with rfl | rfl <;> simp) (x :: xs) (by simp) hx rest g (by omega)
    obtain ⟨t, r, he, h1, -, -, h4, -, -⟩ := headOK_closer (headOK_at (hx x (by simp)) 4)
    have hs : sepBy [.kw .comma] ((x :: xs).map fun x => (pr c x).at c.sf 4) =
        t :: (r ++ (xs.map fun x => (pr c x).at c.sf 4).flatMap (fun y => [.kw .comma] ++ y)) := by
      rw [List.map_cons, sepBy_cons, he]; rfl
    rw [hs] at hp ⊢
    have ht : t ≠ .kw .rp := by intro e; subst e; simp [isRp] at h1
    rw [pCallArgs.eq_4 _ _ _ (by intro r' e; cases e; exact ht rfl) (by intro r' e; cases e; exact h4 rfl)]
    exact hp

theorem allPos_map (xs : List Json) : allPos (xs.map CallArg.pos) = some xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [allPos, ih]

end Esm.Document.Math
