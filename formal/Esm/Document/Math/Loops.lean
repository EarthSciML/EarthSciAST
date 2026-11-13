import Esm.Document.Math.Cases2

/-!
# The loops of the level parsers: stopping and running through a chain
-/

namespace Esm.Document.Math

open Esm.Document

theorem orLoop_stop (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) (hr : Fol c.sf 1 r) :
    orLoop c (f + 1) acc r = some (close "or" acc, r) :=
  orLoop.eq_3 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)

theorem andLoop_stop (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) (hr : Fol c.sf 2 r) :
    andLoop c (f + 1) acc r = some (close "and" acc, r) :=
  andLoop.eq_3 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)

theorem cmpLoop_stop (c : Ctx) (f : Nat) (x : Json) (r : List Tok) (hr : Fol c.sf 3 r) :
    cmpLoop c (f + 1) x r = some (x, r) := by
  cases r with
  | nil => rfl
  | cons t r' =>
    cases t with
    | kw k =>
      have := hr _ _ rfl
      rw [cmpLoop]
      cases hk : cmpOf k with
      | none => rfl
      | some o => exfalso; cases k <;> simp_all [conts, cmpOf, isCmpTok]
    | _ => rfl

theorem addLoop_stop (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) (hr : Fol c.sf 4 r) :
    addLoop c (f + 1) acc r = some (close "+" acc, r) :=
  addLoop.eq_4 _ _ _ _ (by intro r' e; have := hr _ _ e; simp [conts] at this)
    (by intro r' e; have := hr _ _ e; simp [conts] at this)

theorem mulLoop_stop (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) (hr : Fol c.sf 5 r) :
    mulLoop c (f + 1) acc r = some (close "*" acc, r) := by
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    have h1 : t ≠ .kw .cdot := by rintro rfl; simp [conts] at ht
    have h2 : t ≠ .kw .times := by rintro rfl; simp [conts] at ht
    have h4 : atomStart t = false := by
      unfold conts at ht; split at ht <;> simp_all [atomStart]
    by_cases h3 : t = .kw .slash
    · subst h3
      rw [mulLoop.eq_4]
      cases hsf : c.sf
      · simp [conts, hsf] at ht
      · simp
    · rw [mulLoop.eq_5 _ _ _ _ _ h1 h2 h3]
      simp [h4]

theorem fracLoop_stop (c : Ctx) (f : Nat) (x : Json) (r : List Tok) (hr : Fol c.sf 7 r) :
    fracLoop c (f + 1) x r = some (x, r) := by
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    by_cases h3 : t = .kw .slash
    · subst h3
      rw [fracLoop]
      cases hsf : c.sf
      · simp
      · simp [conts, hsf] at ht
    · rw [fracLoop.eq_3 _ _ _ _ (by intro r'' e; cases e; exact h3 rfl)]

theorem postLoop_stop (c : Ctx) (f : Nat) (x : Json) (r : List Tok) (hr : Fol c.sf 9 r) :
    postLoop c (f + 1) x r = some (x, r) := by
  cases r with
  | nil => rfl
  | cons t r' =>
    have ht := hr _ _ rfl
    have h1 : t ≠ .kw .us := by rintro rfl; simp [conts] at ht
    have h2 : t ≠ .kw .lbk := by rintro rfl; simp [conts] at ht
    exact postLoop.eq_7 _ _ _ _ (by intro r e; cases e; exact h1 rfl) (by intro r e; cases e; exact h2 rfl)

/-- A chain of blocks, each of which one loop step consumes (with fuel at least `W` of it). -/
theorem chain {α : Type} (loop : Nat → List Json → List Tok → Option α) (Q : List Tok → Prop)
    (W : Json × List Tok → Nat) (rest : List Tok) (hQr : Q rest) :
    ∀ (bs : List (Json × List Tok)), (∀ p ∈ bs, ∀ r, Q (p.2 ++ r)) →
      (∀ p ∈ bs, ∀ f acc r, Q r → W p ≤ f →
        loop (f + 1) acc (p.2 ++ r) = loop f (acc ++ [p.1]) r) →
      ∀ (acc : List Json) (f : Nat), (bs.map W).sum + bs.length ≤ f →
      loop f acc ((bs.flatMap Prod.snd) ++ rest) = loop (f - bs.length) (acc ++ bs.map Prod.fst) rest
  | [], _, _, acc, f, _ => by simp
  | p :: bs, hQb, step, acc, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.flatMap_cons, List.append_assoc, List.map_cons, List.sum_cons,
      List.length_cons] at hf ⊢
    have hQ : Q ((bs.flatMap Prod.snd) ++ rest) := by
      cases bs with
      | nil => simpa using hQr
      | cons q qs => simpa [List.append_assoc] using hQb q (by simp) ((qs.flatMap Prod.snd) ++ rest)
    rw [step p (by simp) g acc _ hQ (by omega)]
    rw [chain loop Q W rest hQr bs (fun q hq => hQb q (by simp [hq]))
      (fun q hq => step q (by simp [hq])) (acc ++ [p.1]) g (by omega)]
    simp only [List.append_assoc, List.singleton_append]
    congr 1
    omega

theorem sumW_le (W : Json × List Tok → Nat) :
    ∀ (bs : List (Json × List Tok)), (∀ p ∈ bs, W p + 1 ≤ 30 * p.2.length) →
      (bs.map W).sum + bs.length ≤ 30 * (bs.flatMap Prod.snd).length
  | [], _ => by simp
  | p :: bs, h => by
    have := sumW_le W bs (fun q hq => h q (by simp [hq]))
    have hp := h p (by simp)
    simp only [List.map_cons, List.sum_cons, List.length_cons, List.flatMap_cons, List.length_append]
    omega

end Esm.Document.Math
