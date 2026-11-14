import Esm.Document.Math.RoundTrip

/-!
# Which operator a printer kind stands for
-/

namespace Esm.Document.Math

open Esm.Document

theorem lookup_mem {β : Type} {l : List (String × β)} {a : String} {b : β} (h : l.lookup a = some b) :
    (a, b) ∈ l := by
  induction l with
  | nil => simp [List.lookup] at h
  | cons p l ih =>
    obtain ⟨x, y⟩ := p
    simp only [List.lookup] at h
    split at h
    · rename_i hx
      simp only [beq_iff_eq] at hx
      cases h; subst hx; simp
    · exact List.mem_cons_of_mem _ (ih h)

/-- A kind from the table names the operator the table gives it. -/
theorem kindOf_table {o : String} {k : OpK} (h : kindOf o = k)
    (hk : ∀ k', k ≠ .cmp k') (hu : ∀ k', k ≠ .un k') (hc : k ≠ .call) (hother : k ≠ .other) :
    (o, k) ∈ kindTable := by
  unfold kindOf at h
  split at h
  · exact absurd h.symm (hk _)
  · exact absurd h.symm (hu _)
  · rename_i k' hk'; subst h; exact lookup_mem hk'
  · split at h
    · exact absurd h.symm hc
    · exact absurd h.symm hother

macro "kind_tac" h:ident : tactic => `(tactic| (
  have hm := kindOf_table $h:ident (by intro _ e; cases e) (by intro _ e; cases e) (by intro e; cases e)
    (by intro e; cases e)
  simpa [kindTable] using hm))

theorem kindOf_minus {o : String} (h : kindOf o = .minus) : o = "-" := by kind_tac h
theorem kindOf_div {o : String} (h : kindOf o = .div) : o = "/" := by kind_tac h
theorem kindOf_pow {o : String} (h : kindOf o = .pow) : o = "^" := by kind_tac h
theorem kindOf_lnot {o : String} (h : kindOf o = .lnot) : o = "not" := by kind_tac h
theorem kindOf_tru {o : String} (h : kindOf o = .tru) : o = "true" := by kind_tac h
theorem kindOf_fls {o : String} (h : kindOf o = .fls) : o = "false" := by kind_tac h
theorem kindOf_ite {o : String} (h : kindOf o = .ite) : o = "ifelse" := by kind_tac h
theorem kindOf_ic {o : String} (h : kindOf o = .ic) : o = "ic" := by kind_tac h
theorem kindOf_index {o : String} (h : kindOf o = .index) : o = "index" := by kind_tac h
theorem kindOf_plus {o : String} (h : kindOf o = .plus) : o = "+" := by kind_tac h
theorem kindOf_times {o : String} (h : kindOf o = .times) : o = "*" := by kind_tac h
theorem kindOf_land {o : String} (h : kindOf o = .land) : o = "and" := by kind_tac h
theorem kindOf_lor {o : String} (h : kindOf o = .lor) : o = "or" := by kind_tac h

theorem kindOf_mm {o : String} {k : Kw} (h : kindOf o = .mm k) :
    (o = "min" ∧ k = .min) ∨ (o = "max" ∧ k = .max) := by
  have hm := kindOf_table h (by intro _ e; cases e) (by intro _ e; cases e) (by intro e; cases e)
    (by intro e; cases e)
  simp only [kindTable, List.mem_cons, Prod.mk.injEq, List.mem_nil_iff, or_false] at hm
  rcases hm with ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ |
    ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨_, e⟩ | ⟨h1, e⟩ | ⟨h1, e⟩ <;> cases e
  · exact Or.inl ⟨h1, rfl⟩
  · exact Or.inr ⟨h1, rfl⟩

theorem kindOf_call {o : String} (h : kindOf o = .call) : callOps.contains o = true := by
  unfold kindOf at h
  split at h
  · cases h
  · cases h
  · rename_i k' hk'; subst h
    have := lookup_mem hk'
    simp [kindTable] at this
  · split at h
    · assumption
    · cases h

theorem kindOf_cmp {o : String} {k : Kw} (h : kindOf o = .cmp k) : cmpOf k = some o := by
  unfold kindOf at h
  split at h
  · rename_i k' hk
    cases h
    have := lookup_mem hk
    simp only [cmpKw, List.mem_cons, Prod.mk.injEq, List.mem_nil_iff, or_false] at this
    rcases this with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> rfl
  · cases h
  · rename_i k' hk'; subst h
    have := lookup_mem hk'
    simp [kindTable] at this
  · split at h <;> cases h

theorem kindOf_un {o : String} {k : Kw} (h : kindOf o = .un k) : unKw.lookup o = some k := by
  unfold kindOf at h
  split at h
  · cases h
  · rename_i k' _ hk; cases h; exact hk
  · rename_i k' hk'; subst h
    have := lookup_mem hk'
    simp [kindTable] at this
  · split at h <;> cases h

end Esm.Document.Math
