import Esm.Document.Math.Kinds

/-!
# Round trip of the atoms: numbers and names
-/

namespace Esm.Document.Math

open Esm.Document

/-- How a printed name segment starts. -/
def SegHead (g : List Char) (t : Tok) (tr : List Tok) : Prop :=
  (∃ x, t = .it x) ∨
  (∃ ch, t = .letter ch ∧ ((tr = [] ∧ g = [ch]) ∨ (∃ r, tr = .kw .us :: r))) ∨
  (∃ gg, t = .greek gg) ∨
  (∃ raw, t = .rm raw ∧ raw ≠ "e" ∧ raw ≠ "d") ∨
  (∃ ps, t = .ups ps ∧ ps ≠ [("e", "")])

theorem formula_head {g : List Char} (hf : isFormula g = true) : ∃ ch r, g = ch :: r ∧ isUpper ch = true := by
  unfold isFormula at hf
  simp only [Bool.and_eq_true] at hf
  obtain ⟨⟨_, h2⟩, _⟩ := hf
  match g, h2 with
  | ch :: r, h2 => exact ⟨ch, r, rfl, h2⟩

theorem formula_ne {g : List Char} (hf : isFormula g = true) : g ≠ ['e'] ∧ g ≠ ['d'] := by
  obtain ⟨ch, r, rfl, hu⟩ := formula_head hf
  unfold isUpper at hu
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hu
  constructor <;> intro e <;> simp only [List.cons.injEq] at e <;> obtain ⟨rfl, -⟩ := e <;>
    simp at hu

theorem segToks_head (sf : Sf) (g : List Char) :
    ∃ t tr, segToks sf g = t :: tr ∧ SegHead g t tr := by
  unfold segToks
  split
  · unfold baseTok
    split
    · rename_i ch _; exact ⟨_, _, rfl, Or.inr (Or.inl ⟨ch, rfl, Or.inl ⟨rfl, rfl⟩⟩)⟩
    · exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inl ⟨_, rfl⟩))⟩
  · split
    · rename_i b r _
      unfold baseTok
      split
      · rename_i ch _
        exact ⟨_, _, rfl, Or.inr (Or.inl ⟨ch, rfl, Or.inr (by cases sf <;> exact ⟨_, rfl⟩)⟩)⟩
      · exact ⟨_, _, rfl, Or.inr (Or.inr (Or.inl ⟨_, rfl⟩))⟩
    · split
      · rename_i hf
        obtain ⟨hne, hnd⟩ := formula_ne hf
        unfold formTok
        cases sf
        · refine ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inl ⟨_, rfl, ?_, ?_⟩)))⟩
          · intro e
            have h1 := congrArg (fun x => decodeFormula x.toList) e
            simp only [String.toList_ofList, decode_formulaRaw hf] at h1
            exact hne (by rw [h1]; rfl)
          · intro e
            have h1 := congrArg (fun x => decodeFormula x.toList) e
            simp only [String.toList_ofList, decode_formulaRaw hf] at h1
            exact hnd (by rw [h1]; rfl)
        · refine ⟨_, _, rfl, Or.inr (Or.inr (Or.inr (Or.inr ⟨_, rfl, ?_⟩)))⟩
          intro e
          have h1 := congrArg (fun ps => ps.flatMap (fun p : String × String => p.1.toList ++ p.2.toList)) e
          simp only [List.flatMap_map, String.toList_ofList] at h1
          rw [pieces_cat hf] at h1
          exact hne (by rw [h1]; rfl)
      · exact ⟨_, _, rfl, Or.inl ⟨_, rfl⟩⟩

/-- How a printed name starts. -/
def NameHead (c : Ctx) (s : String) (t : Tok) (tr : List Tok) : Prop :=
  (∃ x, t = .it x) ∨
  (∃ ch, t = .letter ch ∧ ((tr = [] ∧ s = String.ofList [ch] ∧ explicitName c.S s = false) ∨
    (∃ r, tr = .kw .us :: r) ∨ (∃ r, tr = .kw .sdot :: r))) ∨
  (∃ g, t = .greek g) ∨
  (∃ raw, t = .rm raw ∧ raw ≠ "e" ∧ raw ≠ "d") ∨
  (∃ ps, t = .ups ps ∧ ps ≠ [("e", "")])

theorem nameToks_head (c : Ctx) (s : String) :
    ∃ t tr, nameToks c s = t :: tr ∧ NameHead c s t tr := by
  unfold nameToks
  split
  · exact ⟨_, _, rfl, Or.inl ⟨s, rfl⟩⟩
  · rename_i hex
    simp only [Bool.not_eq_true] at hex
    obtain ⟨g, gs, hgs⟩ := List.exists_cons_of_ne_nil (splitDots_ne s.toList)
    have hsplit : s.toList = joinDots (g :: gs) := by rw [← hgs, joinDots_splitDots]
    rw [hgs]
    simp only [List.map_cons, sepBy_cons]
    obtain ⟨t, tr, hseg, hh⟩ := segToks_head c.sf g
    rw [hseg]
    refine ⟨t, _, rfl, ?_⟩
    rcases hh with h | ⟨ch, rfl, h⟩ | h | h | h
    · exact Or.inl h
    · right; left
      refine ⟨ch, rfl, ?_⟩
      rcases h with ⟨rfl, rfl⟩ | ⟨r, rfl⟩
      · cases gs with
        | nil =>
          left
          have : s = String.ofList [ch] := by
            rw [← String.ofList_toList (s := s), hsplit]; rfl
          exact ⟨by simp, this, this ▸ hex⟩
        | cons h hs' =>
          right; right
          exact ⟨segToks c.sf h ++ (hs'.map (segToks c.sf)).flatMap (fun y => [Tok.kw .sdot] ++ y), by simp⟩
      · right; left
        exact ⟨r ++ (gs.map (segToks c.sf)).flatMap (fun y => [Tok.kw .sdot] ++ y), by simp⟩
    · exact Or.inr (Or.inr (Or.inl h))
    · exact Or.inr (Or.inr (Or.inr (Or.inl h)))
    · exact Or.inr (Or.inr (Or.inr (Or.inr h)))

end Esm.Document.Math

namespace Esm.Document.Math
open Esm.Document

theorem icTailP_none (sf : Sf) (rest : List Tok) (hr : ∀ r, rest ≠ .kw .lp :: r) :
    icTailP sf rest = none := by
  unfold icTailP
  split
  · rename_i r _; exact absurd rfl (hr _)
  · rfl

theorem fol10_name {sf : Sf} {rest : List Tok} (hr : Fol sf 10 rest) : NameStop sf rest := by
  refine ⟨fun r e => ?_, ?_⟩
  · have := hr _ _ e; simp [conts] at this
  · unfold subPat
    split
    · rename_i e; have := hr _ _ rfl; simp [conts] at this
    · rename_i e; have := hr _ _ rfl; simp [conts] at this
    · rfl

theorem pNamePrim_name (c : Ctx) (s : String) (hs : nameOK s = true) (rest : List Tok)
    (hr : Fol c.sf 10 rest) : pNamePrim c (nameToks c s ++ rest) = some (.str s, rest) := by
  unfold pNamePrim
  rw [pName_nameToks c s hs rest (fol10_name hr)]
  simp only
  rw [icTailP_none c.sf rest (fun r e => by have := hr _ _ e; simp [conts] at this)]

/-- A primary that starts with a name's tokens is read as a name (never as `e^x`). -/
theorem pPrim_name_eq (c : Ctx) (s : String) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (nameToks c s ++ rest) = pNamePrim c (nameToks c s ++ rest) := by
  obtain ⟨t, tr, hn, hh⟩ := nameToks_head c s
  rw [hn]
  rw [pPrim.eq_def]
  simp only [List.cons_append]
  rcases hh with ⟨x, rfl⟩ | ⟨ch, rfl, h⟩ | ⟨g, rfl⟩ | ⟨raw, rfl, h1, h2⟩ | ⟨ps, rfl, h1⟩
  · rfl
  · have he : eulerHead c (Tok.letter ch :: (tr ++ rest)) = false := by
      unfold eulerHead
      split
      · rename_i heq; cases heq
      · rename_i heq; cases heq
      · rename_i ch' r heq
        simp only [List.cons.injEq, Tok.letter.injEq] at heq
        obtain ⟨rfl, htr⟩ := heq
        rcases h with ⟨rfl, rfl, hex⟩ | ⟨r', rfl⟩ | ⟨r', rfl⟩
        · unfold explicitName at hex
          by_cases hch : ch = 'e'
          · subst hch
            have e1 : String.ofList ['e'] = "e" := rfl
            rw [e1] at hex
            simp only [beq_self_eq_true, Bool.true_or, Bool.true_and,
              Bool.not_eq_eq_eq_not, Bool.not_false] at hex
            simp only [beq_self_eq_true, hex, Bool.not_true, Bool.and_false]
          · simp [hch]
        · simp at htr
        · simp at htr
      · rfl
    simp only [he]; rfl
  · rfl
  · have he : eulerHead c (Tok.rm raw :: (tr ++ rest)) = false := by
      unfold eulerHead
      split
      · rename_i heq; simp only [List.cons.injEq, Tok.rm.injEq] at heq
        obtain ⟨rfl, -⟩ := heq; simp [h1]
      · rename_i heq; cases heq
      · rename_i heq; cases heq
      · rfl
    simp only [he]; rfl
  · have he : eulerHead c (Tok.ups ps :: (tr ++ rest)) = false := by
      unfold eulerHead
      split
      · rename_i heq; cases heq
      · rename_i heq; simp only [List.cons.injEq, Tok.ups.injEq] at heq
        obtain ⟨rfl, -⟩ := heq; simp [h1]
      · rename_i heq; cases heq
      · rfl
    simp only [he]; rfl

theorem pPrim_name (c : Ctx) (s : String) (hs : nameOK s = true) (rest : List Tok)
    (hr : Fol c.sf 10 rest) (f : Nat) : pPrim c (f + 1) (nameToks c s ++ rest) = some (.str s, rest) := by
  rw [pPrim_name_eq]; exact pNamePrim_name c s hs rest hr

end Esm.Document.Math
