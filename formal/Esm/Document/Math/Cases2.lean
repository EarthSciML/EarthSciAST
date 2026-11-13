import Esm.Document.Math.Cases1

/-!
# Round trip, case by case
-/

namespace Esm.Document.Math

open Esm.Document

theorem pr_num (c : Ctx) (n : JNum) :
    pr c (.num n) = mkOut c.sf (if isNegNum (.num n) then 7 else 10) [.num n] := by
  rw [pr.eq_def]

theorem pr_str (c : Ctx) (s : String) : pr c (.str s) = mkOut c.sf 10 (nameToks c s) := by
  rw [pr.eq_def]

theorem addAcc_node {o : String} {xs : List Json} (h : o ≠ "+") : addAcc (node o xs) = [node o xs] := by
  unfold addAcc node
  split
  · rename_i heq; cases heq; exact absurd rfl h
  · rfl

theorem M_num (c : Ctx) (n : JNum) : M c (.num n) := by
  have hpr := pr_num c n
  have hlvl : (pr c (.num n)).lvl = 7 ∨ (pr c (.num n)).lvl = 10 := by
    rw [hpr]; unfold mkOut; split <;> simp
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
      rw [hpr]
      exact pPrim_num c n rest hr g
    · omega
    · omega
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩
  · omega
  · omega
  · omega
  · unfold addAcc; rfl
  · rw [hpr]; rfl

theorem nameHead_ok (c : Ctx) (s : String) (t : Tok) (tr : List Tok) (h : NameHead c s t tr) :
    HeadOK c (t :: tr) := by
  rcases h with ⟨x, rfl⟩ | ⟨ch, rfl, h⟩ | ⟨g, rfl⟩ | ⟨raw, rfl, h1, h2⟩ | ⟨ps, rfl, h1⟩
  · exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩
  · refine ⟨by simp, by simp, by simp, by simp, ?_, Or.inl rfl⟩
    intro hd
    simp only [Tok.letter.injEq] at hd
    subst hd
    rcases h with ⟨rfl, rfl, hex⟩ | ⟨r, rfl⟩ | ⟨r, rfl⟩
    · left
      unfold explicitName at hex
      have e1 : String.ofList ['d'] = "d" := rfl
      rw [e1] at hex
      simpa using hex
    · right; left; exact ⟨r, rfl⟩
    · right; right; exact ⟨r, rfl⟩
  · exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩
  · exact ⟨by simp, by simp, by simpa using h2, by simp, by simp, Or.inl rfl⟩
  · exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl rfl⟩

theorem M_name (c : Ctx) (s : String) (hs : nameOK s = true) : M c (.str s) := by
  have hpr := pr_str c s
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
      rw [hpr]
      exact pPrim_name c s hs rest hr g
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]
    obtain ⟨t, tr, hn, hh⟩ := nameToks_head c s
    simp only [mkOut, hn]
    exact nameHead_ok c s t tr hh
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · unfold addAcc; rfl
  · rw [hpr]; rfl

end Esm.Document.Math

namespace Esm.Document.Math
open Esm.Document

theorem pFn1_ok (c : Ctx) (o : String) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length + 1 ≤ f) :
    pFn1 c f o ((pr c a).at c.sf 1 ++ .kw .rp :: rest) = some (node o [a], rest) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
  rw [pFn1, child1 ha _ (fol1_kw _ .rp (by simp) rest) g (by omega)]

theorem pPrim_un (c : Ctx) (o : String) (k : Kw) (hk : (o, k) ∈ unKw) (a : Json) (ha : M c a)
    (rest : List Tok) (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length + 2 ≤ f) :
    pPrim c (f + 1) (unToks c.sf k ((pr c a).at c.sf 1) ++ rest) = some (node o [a], rest) := by
  have hp := pFn1_ok c o a ha rest f (by omega)
  have h1 := child1 ha _ (fol1_kw _ .rb (by simp) rest) f (by omega)
  have h2 := child1 ha _ (fol1_kw _ .rabs (by simp) rest) f (by omega)
  have h3 := child1 ha _ (fol1_kw _ .rfloor (by simp) rest) f (by omega)
  have h4 := child1 ha _ (fol1_kw _ .rceil (by simp) rest) f (by omega)
  simp only [unKw, fnKw, List.cons_append, List.nil_append, List.mem_cons, Prod.mk.injEq,
    List.mem_nil_iff, or_false] at hk
  obtain ⟨sf, S⟩ := c
  rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
    ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
    ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> cases sf <;>
  · simp only at h1 h2 h3 h4 hp ⊢
    simp only [unToks, callToks, sepBy, lpC, List.cons_append, List.nil_append, List.append_assoc]
    rw [pPrim.eq_def]
    simp only [isLp, fnOf, ↓reduceIte]
    first
    | exact hp
    | (rw [h1])
    | (rw [h2])
    | (rw [h3])
    | (rw [h4])


/-- A token that starts a keyword form. -/
def kwStart (t : Tok) : Prop := ∃ k, t = .kw k ∧ startA t = true ∧ k ≠ .dif ∧ k ≠ .pdiff

theorem headOK_kw (c : Ctx) (t : Tok) (r : List Tok) (h : kwStart t) : HeadOK c (t :: r) := by
  obtain ⟨k, rfl, h1, h2, h3⟩ := h
  exact ⟨fun e => h2 (by cases e; rfl), fun e => h3 (by cases e; rfl), by simp, by simp, by simp,
    Or.inl h1⟩

theorem unToks_head (sf : Sf) (o : String) (k : Kw) (hk : (o, k) ∈ unKw) (t : List Tok) :
    ∃ h r, unToks sf k t = h :: r ∧ kwStart h := by
  simp only [unKw, fnKw, List.cons_append, List.nil_append, List.mem_cons, Prod.mk.injEq,
    List.mem_nil_iff, or_false] at hk
  rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
    ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
    ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> cases sf <;>
    exact ⟨_, _, rfl, ⟨_, rfl, rfl, by decide, by decide⟩⟩

theorem unKw_name {o : String} {k : Kw} (h : unKw.lookup o = some k) : (o, k) ∈ unKw :=
  lookup_mem h

theorem len_pos_of_head {c : Ctx} {ts : List Tok} (h : HeadOK c ts) : 1 ≤ ts.length := by
  match ts, h with
  | _ :: _, _ => simp

theorem M_un (c : Ctx) (o : String) (k : Kw) (a : Json) (ho : kindOf o = .un k) (ha : M c a)
    (hpr : pr c (node o [a]) = mkOut c.sf 10 (unToks c.sf k ((pr c a).at c.sf 1))) :
    M c (node o [a]) := by
  have hk := unKw_name (kindOf_un ho)
  have hlen : ((pr c a).at c.sf 1).length + 2 ≤ (unToks c.sf k ((pr c a).at c.sf 1)).length := by
    simp only [unKw, fnKw, List.cons_append, List.nil_append, List.mem_cons, Prod.mk.injEq,
      List.mem_nil_iff, or_false] at hk
    rcases hk with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
      ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ |
      ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> cases c.sf <;> simp [unToks, callToks, sepBy, lpC]
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
      rw [hpr]
      exact pPrim_un c o k hk a ha rest g (by
        simp only [hpr, mkOut] at hf; unfold need at hf ⊢; omega)
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]
    obtain ⟨h, r, he, hs⟩ := unToks_head c.sf o k hk ((pr c a).at c.sf 1)
    simp only [mkOut, he]
    exact headOK_kw c h r hs
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · apply addAcc_node
    intro e; subst e
    simp [unKw, fnKw] at hk
  · rw [hpr]; rfl

end Esm.Document.Math
