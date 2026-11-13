import Esm.Document.Math.LexTypst
import Esm.Document.Math.TokLatex

/-!
# The Typst printer writes only Typst tokens, in lexable order

Every token of a printed well-formed expression is a Typst token (`tokOK`), every call
parenthesis follows a name-like token, and no unit block follows a unit block
(`Adj`), so the Typst lexer lemma applies to the printer's output.
-/

namespace Esm.Document.Math.Typst

open Esm.Document Esm.Document.Math

def Good (ts : List Tok) : Prop := (∀ t ∈ ts, tokOK t) ∧ Adj ts

/-- A list that may follow anything: it does not start with a call parenthesis or a
unit block. -/
def Nice (ts : List Tok) : Prop := ∀ t ∈ ts.head?, t ≠ .kw .lp ∧ isUnits t = false

def LastCall (ts : List Tok) : Prop := ts ≠ [] ∧ ∀ t ∈ ts.getLast?, callEnd t = true

theorem good_nil : Good [] := ⟨by simp, trivial⟩

theorem adj_cons (t : Tok) (B : List Tok) (hB : Adj B)
    (h : ∀ u ∈ B.head?, (u = .kw .lp → callEnd t = true) ∧ (isUnits t = true → isUnits u = false)) :
    Adj (t :: B) := by
  cases B with
  | nil => trivial
  | cons u r => exact ⟨(h u rfl).1, (h u rfl).2, hB⟩

theorem adj_tail {t : Tok} {B : List Tok} (h : Adj (t :: B)) : Adj B := by
  cases B with
  | nil => trivial
  | cons u r => exact h.2.2

theorem adj_append : ∀ (A B : List Tok), Adj A → Adj B → Nice B → Adj (A ++ B)
  | [], B, _, hB, _ => hB
  | [t], B, _, hB, hn => adj_cons t B hB (fun u hu => ⟨fun e => absurd e (hn u hu).1,
      fun _ => (hn u hu).2⟩)
  | t :: t' :: r, B, hA, hB, hn => by
    refine ⟨hA.1, hA.2.1, ?_⟩
    exact adj_append (t' :: r) B hA.2.2 hB hn

theorem good_append {A B : List Tok} (hA : Good A) (hB : Good B) (hn : Nice B) : Good (A ++ B) :=
  ⟨fun t ht => (List.mem_append.1 ht).elim (hA.1 t) (hB.1 t), adj_append A B hA.2 hB.2 hn⟩

theorem good_cons {t : Tok} {B : List Tok} (ht : tokOK t) (hB : Good B) (hn : Nice B) : Good (t :: B) :=
  good_append (A := [t]) ⟨by simpa using ht, trivial⟩ hB hn

theorem good_cons_lp {t : Tok} {B : List Tok} (ht : tokOK t) (hc : callEnd t = true) (hB : Good B)
    (hn : Nice B) : Good (t :: .kw .lp :: B) := by
  refine ⟨fun u hu => ?_, ⟨fun _ => hc, fun h => by simp [isUnits] at h ⊢, adj_cons _ B hB.2
    (fun u hu => ⟨fun e => absurd e (hn u hu).1, fun h => by simp [isUnits] at h⟩)⟩⟩
  simp only [List.mem_cons] at hu
  rcases hu with rfl | rfl | hu
  · exact ht
  · rfl
  · exact hB.1 u hu

theorem good_append_lp : ∀ {A B : List Tok}, Good A → LastCall A → Good B → Nice B →
    Good (A ++ .kw .lp :: B)
  | [], _, _, hl, _, _ => absurd rfl hl.1
  | [t], B, hA, hl, hB, hn => good_cons_lp (hA.1 t (by simp)) (hl.2 t rfl) hB hn
  | t :: t' :: r, B, hA, hl, hB, hn => by
    have ih := good_append_lp (A := t' :: r) (B := B) ⟨fun u hu => hA.1 u (by simp [hu]), hA.2.2.2⟩
      ⟨by simp, fun u hu => hl.2 u (by simpa using hu)⟩ hB hn
    exact ⟨fun u hu => by
        simp only [List.cons_append, List.mem_cons] at hu
        rcases hu with rfl | hu
        · exact hA.1 u (by simp)
        · exact ih.1 u (by simpa using hu),
      ⟨hA.2.1, hA.2.2.1, ih.2⟩⟩

theorem nice_cons {t : Tok} (r : List Tok) (h1 : t ≠ .kw .lp) (h2 : isUnits t = false) : Nice (t :: r) :=
  fun u hu => by cases hu; exact ⟨h1, h2⟩

theorem nice_append {A : List Tok} (B : List Tok) (hA : Nice A) (hne : A ≠ []) : Nice (A ++ B) := by
  obtain ⟨t, r, rfl⟩ := List.exists_cons_of_ne_nil hne
  exact fun u hu => hA u (by simpa using hu)

theorem lastCall_append (A : List Tok) {B : List Tok} (hB : LastCall B) : LastCall (A ++ B) := by
  refine ⟨by simp [hB.1], fun t ht => hB.2 t ?_⟩
  rw [List.getLast?_append] at ht
  obtain ⟨u, hu⟩ := Option.ne_none_iff_exists'.1 (by simpa [List.getLast?_eq_none_iff] using hB.1 :
    B.getLast? ≠ none)
  rw [hu] at ht ⊢; simpa using ht

/-- Close `Good`, `Nice` and fact goals about a printed template from the pieces in
the context. -/
macro "gok" : tactic => `(tactic| (
  simp only [List.cons_append, List.nil_append, List.append_assoc, List.singleton_append]
  repeat (first
    | assumption
    | exact good_nil
    | (apply good_append_lp <;> first | assumption | (apply lastCall_append; assumption) | skip)
    | (apply good_cons_lp <;> first | assumption | rfl | decide | skip)
    | (apply good_cons <;> first | assumption | rfl | decide | skip)
    | (apply good_append <;> first | assumption | skip)
    | (apply nice_cons <;> first | rfl | decide)
    | (apply nice_append <;> first | assumption | skip)
    | rfl
    | decide)))

/-! ## Names -/

theorem digRun_dig : ∀ (cs : List Char), ∀ c ∈ (digRun cs).1, isDig c = true
  | [], c, h => by simp [digRun] at h
  | d :: cs, c, h => by
    unfold digRun at h
    split at h
    · rename_i hd
      simp only [List.mem_cons] at h
      rcases h with rfl | h
      · exact hd
      · exact digRun_dig cs c h
    · simp at h

theorem pieces_go_dig : ∀ (f : Nat) (cs : List Char), ∀ p ∈ Esm.Document.Math.pieces.go f cs, ∀ c ∈ p.2, isDig c = true
  | 0, _, p, h => by simp [Esm.Document.Math.pieces.go] at h
  | f + 1, [], p, h => by simp [Esm.Document.Math.pieces.go] at h
  | f + 1, d :: cs, p, h => by
    unfold Esm.Document.Math.pieces.go at h
    simp only at h
    split at h
    · simp at h
    · simp only [List.mem_cons] at h
      rcases h with rfl | h
      · exact digRun_dig _
      · exact pieces_go_dig f _ p h

theorem tokOK_baseTok (b : List Char) (hb : isSingle b = true) :
    tokOK (baseTok b) ∧ callEnd (baseTok b) = true ∧ baseTok b ≠ .kw .lp ∧ isUnits (baseTok b) = false := by
  unfold baseTok isSingle at *
  split
  · rename_i c
    refine ⟨hb, ?_, by simp, rfl⟩
    simp [callEnd, tokChars, isIdC, hb]
  · rename_i hne
    have hg : isGreek b = true := by
      split at hb
      · rename_i c; exact absurd rfl (hne c)
      · exact hb
    have hg' : isGreek (String.ofList b).toList = true := by rw [String.toList_ofList]; exact hg
    refine ⟨hg', ?_, by simp, rfl⟩
    obtain ⟨hl, ⟨c0, r, he⟩, -⟩ := greek_lex _ hg'
    simp only [callEnd, tokChars]
    have hgl : (String.ofList b).toList.getLast? ≠ none := by rw [he]; simp
    obtain ⟨e, he'⟩ := Option.ne_none_iff_exists'.1 hgl
    rw [he']
    simp [isIdC, hl e (List.mem_of_getLast? he')]

theorem callEnd_ups (ps : List (String × String)) (h : tokOK (.ups ps)) : callEnd (.ups ps) = true := by
  obtain ⟨hne, hok⟩ := (show ps ≠ [] ∧ ∀ p ∈ ps, PieceOK p from h)
  obtain ⟨qs, p, rfl⟩ := List.eq_nil_or_concat ps |>.resolve_left hne
  rw [List.concat_eq_append] at hok ⊢
  have hp := hok p (by simp)
  simp only [callEnd, tokChars, List.flatMap_append, List.flatMap_cons, List.flatMap_nil, List.append_nil]
  rw [List.getLast?_append_of_ne_nil _ (by simp [pieceChars])]
  rcases hp with h0 | ⟨hne2, hdig⟩
  · simp only [pieceChars, h0, ↓reduceIte]
    rw [show "upright(".toList ++ Strings.quote true p.1 ++ [')'] ++ [] =
      ("upright(".toList ++ Strings.quote true p.1) ++ [')'] by simp, List.getLast?_concat]
    rfl
  · have h0 : p.2 ≠ "" := fun e => hne2 (by rw [e]; rfl)
    simp only [pieceChars, h0, ↓reduceIte]
    obtain ⟨ds, d, hds⟩ := List.eq_nil_or_concat p.2.toList |>.resolve_left hne2
    rw [List.concat_eq_append] at hds
    have hd : isDig d = true := List.all_eq_true.1 hdig d (by rw [hds]; simp)
    rw [hds, show "upright(".toList ++ Strings.quote true p.1 ++ [')'] ++ '_' :: (ds ++ [d]) =
      ("upright(".toList ++ Strings.quote true p.1 ++ [')'] ++ '_' :: ds) ++ [d] by simp,
      List.getLast?_concat]
    simp [isIdC, hd]

theorem good_segToks (g : List Char) :
    Good (segToks .typst g) ∧ Nice (segToks .typst g) ∧ LastCall (segToks .typst g) := by
  unfold segToks
  split
  · rename_i hs
    obtain ⟨h1, h2, h3, h4⟩ := tokOK_baseTok g hs
    exact ⟨⟨(by simpa using h1), trivial⟩, nice_cons _ h3 h4, (by simp), (by simpa using h2)⟩
  · split
    · rename_i b r hsp
      obtain ⟨h1, -, h3, h4⟩ := tokOK_baseTok b (subParts_spec hsp).2.1
      have hu : tokOK (.ups [(String.ofList r, "")]) := ⟨(by simp), fun p hp => by simp at hp; subst hp; left; rfl⟩
      refine ⟨?_, nice_cons _ h3 h4, (by simp [subTxt]), (fun t ht => by simp [subTxt] at ht; subst ht; rfl)⟩
      simp only [subTxt]
      refine ⟨fun t ht => ?_, ⟨(fun e => by cases e), (fun h => ?_), ⟨(fun e => by cases e), (fun _ => rfl),
        ⟨(fun e => by cases e), (fun _ => rfl), ⟨(fun e => by cases e), (fun _ => rfl), trivial⟩⟩⟩⟩⟩
      · simp only [List.mem_cons, List.not_mem_nil, or_false] at ht
        rcases ht with rfl | rfl | rfl | rfl | rfl
        · exact h1
        · rfl
        · rfl
        · exact hu
        · rfl
      · rfl
    · split
      · rename_i hf
        have hpc := pieces_cat hf
        have hne : Esm.Document.Math.pieces g ≠ [] := by
          intro e; rw [e] at hpc
          have : isFormula [] = false := rfl
          simp at hpc; subst hpc; exact absurd hf (by rw [this]; decide)
        have hu : tokOK (.ups ((Esm.Document.Math.pieces g).map fun p => (String.ofList p.1, String.ofList p.2))) := by
          refine ⟨by simpa using hne, fun q hq => ?_⟩
          obtain ⟨p, hp, rfl⟩ := List.mem_map.1 hq
          have hd := pieces_go_dig _ _ p hp
          by_cases h2 : p.2 = []
          · left; simp [h2]
          · right
            refine ⟨by simpa using h2, ?_⟩
            rw [String.toList_ofList]; exact List.all_eq_true.2 hd
        exact ⟨⟨(by simpa [formTok] using hu), trivial⟩, nice_cons _ (by simp [formTok]) rfl, (by simp [formTok]),
          fun t ht => by simp [formTok] at ht; subst ht; exact callEnd_ups _ hu⟩
      · refine ⟨⟨(by simp; trivial), trivial⟩, nice_cons _ (by simp) rfl, (by simp), ?_⟩
        intro t ht; simp at ht; subst ht
        simp only [callEnd, tokChars, Strings.quote]
        rw [show "italic(".toList ++ ('"' :: Strings.escape true (String.ofList g).toList ++ ['"']) ++ [')'] =
          ("italic(".toList ++ ('"' :: Strings.escape true (String.ofList g).toList ++ ['"'])) ++ [')'] by simp,
          List.getLast?_concat]
        rfl

theorem good_sepBy_names : ∀ (xs : List (List Tok)), xs ≠ [] →
    (∀ x ∈ xs, Good x ∧ Nice x ∧ LastCall x) →
    Good (sepBy [.kw .sdot] xs) ∧ Nice (sepBy [.kw .sdot] xs) ∧ LastCall (sepBy [.kw .sdot] xs)
  | [], h, _ => absurd rfl h
  | [x], _, h => by simpa [sepBy] using h x (by simp)
  | x :: y :: ys, _, h => by
    obtain ⟨hx1, hx2, hx3⟩ := h x (by simp)
    obtain ⟨hy1, hy2, hy3⟩ := good_sepBy_names (y :: ys) (by simp) (fun z hz => h z (by simp [hz]))
    rw [sepBy_cons2]
    refine ⟨good_append (good_append hx1 (good_cons rfl good_nil (fun _ h => by cases h))
      (nice_cons _ (by simp) rfl)) hy1 hy2, nice_append _ (nice_append _ hx2 hx3.1) (by simp [hx3.1]),
      lastCall_append _ hy3⟩

theorem good_nameToks (c : Ctx) (hc : c.sf = .typst) (s : String) :
    Good (nameToks c s) ∧ Nice (nameToks c s) ∧ LastCall (nameToks c s) := by
  unfold nameToks
  split
  · refine ⟨⟨(by simp; trivial), trivial⟩, nice_cons _ (by simp) rfl, (by simp), ?_⟩
    intro t ht; simp at ht; subst ht
    simp only [callEnd, tokChars, Strings.quote]
    rw [show "italic(".toList ++ ('"' :: Strings.escape true s.toList ++ ['"']) ++ [')'] =
      ("italic(".toList ++ ('"' :: Strings.escape true s.toList ++ ['"'])) ++ [')'] by simp,
      List.getLast?_concat]
    rfl
  · rw [hc]
    exact good_sepBy_names _ (by simpa using splitDots_ne s.toList)
      (fun x hx => by obtain ⟨g, -, rfl⟩ := List.mem_map.1 hx; exact good_segToks g)

end Esm.Document.Math.Typst
