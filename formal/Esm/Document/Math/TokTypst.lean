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

theorem tokOK_txt (s : String) (h : s ≠ ".") : tokOK (.txt s) := h
theorem tokOK_num0 : tokOK (.num (.int 0)) := by
  show JNum.InInt64 0; unfold JNum.InInt64; decide
theorem tokOK_num10 : tokOK (.num (.int 10)) := by
  show JNum.InInt64 10; unfold JNum.InInt64; decide
theorem callEnd_opn (s : String) : callEnd (.opn s) = true := by
  simp only [callEnd, tokChars]
  rw [show "op(".toList ++ Strings.quote true s ++ [')'] = ("op(".toList ++ Strings.quote true s) ++ [')'] by simp,
    List.getLast?_concat]
  rfl

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
    | exact tokOK_txt _ (by decide)
    | exact tokOK_num0
    | exact tokOK_num10
    | exact callEnd_opn _
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

/-! ## Printer pieces -/

theorem nice_of_head {c : Ctx} {ts : List Tok} (h : HeadOK c ts) : Nice ts ∧ ts ≠ [] := by
  match ts, h with
  | t :: r, ⟨_, _, _, _, _, h6⟩ =>
    refine ⟨fun u hu => ?_, by simp⟩
    cases hu
    rcases h6 with h6 | rfl
    · refine ⟨by rintro rfl; simp [startA] at h6, ?_⟩
      cases t <;> simp_all [isUnits, startA, atomStart]
    · exact ⟨by simp, rfl⟩

theorem good_grp {ts : List Tok} (h : Good ts) (hn : Nice ts) : Good (grp .typst ts) := by
  simp only [grp, reduceCtorEq, ↓reduceIte]
  exact good_cons rfl (good_append h ⟨by simp; rfl, trivial⟩ (nice_cons _ (by simp) rfl)) (by
    cases ts with
    | nil => exact nice_cons _ (by simp) rfl
    | cons t r => exact fun u hu => hn u (by simpa using hu))

theorem good_sepBy (k : Kw) (hk : kwOK k = true) (hl : k ≠ .lp) :
    ∀ (xs : List (List Tok)), (∀ x ∈ xs, Good x ∧ Nice x) →
      Good (sepBy [.kw k] xs) ∧ Nice (sepBy [.kw k] xs)
  | [], _ => ⟨good_nil, fun _ h => by cases h⟩
  | [x], h => by simpa [sepBy] using h x (by simp)
  | x :: y :: ys, h => by
    obtain ⟨hx1, hx2⟩ := h x (by simp)
    obtain ⟨hy1, hy2⟩ := good_sepBy k hk hl (y :: ys) (fun z hz => h z (by simp [hz]))
    rw [sepBy_cons2]
    refine ⟨good_append (good_append hx1 (good_cons hk good_nil (fun _ h => by cases h))
      (nice_cons _ (by simp [hl]) rfl)) hy1 hy2, ?_⟩
    by_cases hx3 : x = []
    · subst hx3; exact nice_append _ (nice_cons _ (by simp [hl]) rfl) (by simp)
    · exact nice_append _ (nice_append _ hx2 hx3) (by simp [hx3])

theorem good_flatMap {α : Type} (f : α → List Tok) :
    ∀ (xs : List α), (∀ x ∈ xs, Good (f x) ∧ Nice (f x)) → Good (xs.flatMap f) ∧ Nice (xs.flatMap f)
  | [], _ => ⟨good_nil, fun _ h => by cases h⟩
  | x :: xs, h => by
    obtain ⟨h1, h2⟩ := h x (by simp)
    obtain ⟨h3, h4⟩ := good_flatMap f xs (fun z hz => h z (by simp [hz]))
    rw [List.flatMap_cons]
    refine ⟨good_append h1 h3 h4, ?_⟩
    by_cases he : f x = []
    · rw [he, List.nil_append]; exact h4
    · exact nice_append _ h2 he

theorem good_mulToks : ∀ (xs : List (List Tok)), (∀ x ∈ xs, Good x ∧ Nice x ∧ x ≠ []) →
    Good (mulToks xs) ∧ Nice (mulToks xs)
  | [], _ => ⟨good_nil, fun _ h => by cases h⟩
  | x :: xs, h => by
    obtain ⟨hx1, hx2, hx3⟩ := h x (by simp)
    have hf := good_flatMap (fun y => if startsNum y then .kw .cdot :: y else y) xs (fun y hy => by
      obtain ⟨h1, h2, h3⟩ := h y (by simp [hy])
      split
      · exact ⟨good_cons rfl h1 h2, nice_cons _ (by simp) rfl⟩
      · exact ⟨h1, h2⟩)
    simp only [mulToks]
    exact ⟨good_append hx1 hf.1 hf.2, nice_append _ hx2 hx3⟩

theorem good_callToks (head : List Tok) (hh : Good head) (hl : LastCall head) (hn : Nice head)
    (args : List (List Tok)) (ha : ∀ x ∈ args, Good x ∧ Nice x) :
    Good (callToks .typst head args) ∧ Nice (callToks .typst head args) := by
  obtain ⟨hs1, hs2⟩ := good_sepBy .comma rfl (by simp) args ha
  simp only [callToks, lpC, List.append_assoc, List.singleton_append]
  refine ⟨good_append_lp hh hl (good_append hs1 ⟨by simp; rfl, trivial⟩ (nice_cons _ (by simp) rfl)) ?_,
    nice_append _ hn hl.1⟩
  by_cases he : sepBy [.kw .comma] args = []
  · rw [he]; exact nice_cons _ (by simp) rfl
  · exact nice_append _ hs2 he

theorem simpleE_ok (c : Ctx) (hc : c.sf = .typst) (x : Json) (hx : isE x = true) (t : Tok)
    (h : simpleE c x = some t) : tokOK t ∧ t ≠ .kw .lp ∧ isUnits t = false := by
  unfold simpleE at h
  split at h
  · rename_i n
    split at h
    · cases h
      exact ⟨(numOK_iff n).1 (by simpa [isE] using hx), by simp, rfl⟩
    · cases h
  · rename_i s
    split at h
    · rename_i t' he
      split at h
      · rename_i hs
        cases h
        have hg := (good_nameToks c hc s).1.1 t (by rw [he]; simp)
        refine ⟨hg, ?_, ?_⟩
        · rintro rfl; simp [simpleTok] at hs
        · cases t <;> simp_all [simpleTok, isUnits]
      · cases h
    · cases h
  · cases h

theorem mk_ok {T : List Tok} (h : Good T) (hn : Nice T) (hne : T ≠ []) :
    Good T ∧ Good (T ++ [.kw .amp, .txt "otherwise"]) ∧ Nice (T ++ [.kw .amp, .txt "otherwise"]) :=
  ⟨h, good_append h ⟨(by simp; exact ⟨rfl, tokOK_txt _ (by decide)⟩), ⟨(fun e => by cases e), (fun _ => rfl), trivial⟩⟩
    (nice_cons _ (by simp) rfl), nice_append _ hn hne⟩

theorem good_single {t : Tok} (h : tokOK t) : Good [t] := ⟨by simpa using h, trivial⟩

theorem jwf_obj_fields {kvs : List (String × Json)} (hs : keysSorted kvs = true)
    (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true) : (Json.obj (fieldsOf kvs)).WF := by
  refine ⟨?_, jwfObj_sound _ (Latex.jwfObj_of _ hf)⟩
  have hp := keysSorted_pairwise kvs hs
  exact keys_nodup (hp.filter _)

theorem good_unToks (o : String) (k : Kw) (hk : unKw.lookup o = some k) (t : List Tok)
    (ht : Good t) (hn : Nice t) : Good (unToks .typst k t) ∧ Nice (unToks .typst k t) := by
  have hm := lookup_mem hk
  simp only [unKw, fnKw, List.cons_append, List.nil_append, List.mem_cons, Prod.mk.injEq,
    List.not_mem_nil, or_false] at hm
  have hargs : ∀ x ∈ [t], Good x ∧ Nice x := by simp [ht, hn]
  rcases hm with ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ |
    ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩
  all_goals first
    | (simp only [unToks]
       have h := good_callToks [.kw .log, .kw .us, .num (.int 10)]
         (good_cons rfl (good_cons rfl (good_single tokOK_num10) (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl))
         ⟨by simp, fun u hu => by simp at hu; subst hu; rfl⟩ (nice_cons _ (by simp) rfl) [t] hargs
       simpa [callToks] using h)
    | (simp only [unToks]
       refine good_callToks _ (good_single ?_) ⟨by simp, ?_⟩ (nice_cons _ ?_ ?_) [t] hargs <;>
         first | rfl | decide | simp)

theorem good_simple : ∀ (l : List Tok), (∀ t ∈ l, tokOK t ∧ t ≠ .kw .lp ∧ isUnits t = false) →
    Good l ∧ Nice l
  | [], _ => ⟨good_nil, fun _ h => by cases h⟩
  | t :: r, h => by
    obtain ⟨h1, h2, h3⟩ := h t (by simp)
    obtain ⟨hr1, hr2⟩ := good_simple r (fun u hu => h u (by simp [hu]))
    exact ⟨good_cons h1 hr1 hr2, nice_cons _ h2 h3⟩

/-- The fixed tokens of a printed template. -/
macro "fixed" : tactic => `(tactic| (apply good_simple; simp (config := {decide := true}) [tokOK, kwOK, isUnits, isLetter]))

theorem adj_snoc : ∀ (A : List Tok) (u : Tok), Adj A → u ≠ .kw .lp →
    (∀ t ∈ A.getLast?, isUnits t = false) → Adj (A ++ [u])
  | [], _, _, _, _ => trivial
  | [t], u, _, hu, hl => ⟨fun e => absurd e hu, fun h => by simp [hl t rfl] at h, trivial⟩
  | t :: t' :: r, u, hA, hu, hl => ⟨hA.1, hA.2.1, adj_snoc (t' :: r) u hA.2.2 hu
      (fun x hx => hl x (by simpa using hx))⟩

theorem good_numToks (ns : List JNum) (h : ∀ n ∈ ns, numOK n = true) :
    ∀ x ∈ numToks ns, Good x ∧ Nice x := by
  intro x hx
  obtain ⟨n, hn, rfl⟩ := List.mem_map.1 hx
  exact ⟨good_single ((numOK_iff n).1 (h n hn)), nice_cons _ (by simp) rfl⟩

theorem good_arr (af : AForm) (h : AOK af) : Good (arrToks .typst af) ∧ Nice (arrToks .typst af) ∧
    ∀ t ∈ (arrToks .typst af).getLast?, isUnits t = false := by
  cases af with
  | col ns =>
    have hc := good_callToks [.kw .vec] (good_single rfl) ⟨by simp, fun u hu => by simp at hu; subst hu; rfl⟩
      (nice_cons _ (by simp) rfl) (numToks ns) (good_numToks ns h.2)
    simp only [callToks, lpC] at hc
    simp only [arrToks]
    refine ⟨hc.1, hc.2, fun t ht => ?_⟩
    rw [List.getLast?_append_of_ne_nil _ (by simp)] at ht; simp at ht; subst ht; rfl
  | mat rs =>
    have hS := good_sepBy .semi rfl (by simp) (rs.map fun r => sepBy [.kw .comma] (numToks r)) (fun y hy => by
      obtain ⟨r, hr, rfl⟩ := List.mem_map.1 hy
      exact good_sepBy .comma rfl (by simp) _ (good_numToks r (h.2.2 r hr)))
    simp only [arrToks, List.cons_append, List.nil_append]
    refine ⟨good_cons_lp rfl rfl (good_append hS.1 (good_single rfl) (nice_cons _ (by simp) rfl)) ?_,
      nice_cons _ (by simp) rfl, fun t ht => ?_⟩
    · by_cases he : sepBy [.kw .semi] (rs.map fun r => sepBy [.kw .comma] (numToks r)) = []
      · rw [he]; exact nice_cons _ (by simp) rfl
      · exact nice_append _ hS.2 he
    · rw [List.getLast?_cons_cons, ← List.cons_append, List.getLast?_append_of_ne_nil _ (by simp)] at ht
      simp at ht; subst ht; rfl

/-! ## Reductions -/

theorem tokOK_num1 : tokOK (.num (.int 1)) := by
  show JNum.InInt64 1; unfold JNum.InInt64; decide

theorem faqOut_crow (c : Ctx) (P : Json → Out) (F : FaqForm) :
    (faqOut c P F).crow = (faqOut c P F).toks ++ [.kw .amp, .txt "otherwise"] := by
  unfold faqOut; split
  · rfl
  · split <;> rfl

theorem good_faqOut (c : Ctx) (hc : c.sf = .typst) (F : FaqForm) (P : Json → Out)
    (hQ : ∀ x ∈ faqSubs F, ∀ L, Good ((P x).at .typst L) ∧ Nice ((P x).at .typst L) ∧ (P x).at .typst L ≠ []) :
    Good (faqOut c P F).toks := by
  have hRow : ∀ kv ∈ F.ranges, Good (rowToks c P kv) ∧ Nice (rowToks c P kv) := by
    intro kv hkv
    obtain ⟨hN1, hN2, hN3⟩ := good_nameToks c hc kv.1
    unfold rowToks
    split
    · rename_i a b he
      obtain ⟨ha, hb⟩ := Latex.faqSubs_rng hkv he
      obtain ⟨hA1, hA2, hA3⟩ := hQ a ha 4
      obtain ⟨hB1, hB2, -⟩ := hQ b hb 4
      rw [hc]; simp only [List.append_assoc, List.cons_append]
      have hT := good_cons (t := .kw .le) rfl (good_append hN1 (good_cons (t := .kw .le) rfl hB1 hB2)
        (nice_cons _ (by simp) rfl)) (nice_append _ hN2 hN3.1)
      exact ⟨good_append hA1 hT (nice_cons _ (by simp) rfl), nice_append _ hA2 hA3⟩
    · rename_i s _
      obtain ⟨hS1, hS2, -⟩ := good_nameToks c hc s
      exact ⟨good_append hN1 (good_cons rfl hS1 hS2) (nice_cons _ (by simp) rfl), nice_append _ hN2 hN3.1⟩
    · rename_i s ps _
      obtain ⟨hS1, hS2, hS3⟩ := good_nameToks c hc s
      have hL := good_sepBy .comma rfl (by simp) (ps.map fun (p : Json) => match p with
          | .str q => nameToks c q | _ => []) (fun y hy => by
        obtain ⟨p, -, rfl⟩ := List.mem_map.1 hy
        split
        · exact ⟨(good_nameToks c hc _).1, (good_nameToks c hc _).2.1⟩
        · exact ⟨good_nil, fun _ h => by cases h⟩)
      have hR : Good (sepBy [.kw .comma] (ps.map fun (p : Json) => match p with
          | .str q => nameToks c q | _ => []) ++ [.kw .rp]) ∧ Nice (sepBy [.kw .comma] (ps.map fun (p : Json) =>
          match p with | .str q => nameToks c q | _ => []) ++ [.kw .rp]) := by
        refine ⟨good_append hL.1 (good_single rfl) (nice_cons _ (by simp) rfl), ?_⟩
        by_cases he : sepBy [.kw .comma] (ps.map fun (p : Json) => match p with
          | .str q => nameToks c q | _ => []) = []
        · rw [he]; exact nice_cons _ (by simp) rfl
        · exact nice_append _ hL.2 he
      have hT : Good (nameToks c s ++ .kw .lp :: (sepBy [.kw .comma] (ps.map fun (p : Json) => match p with
          | .str q => nameToks c q | _ => []) ++ [.kw .rp])) := good_append_lp hS1 hS3 hR.1 hR.2
      simp only [List.cons_append, List.append_assoc] at hT ⊢
      refine ⟨good_append hN1 ?_ (nice_cons _ (by simp) rfl), nice_append _ hN2 hN3.1⟩
      exact good_cons rfl hT (nice_append _ hS2 hS3.1)
    · exact ⟨good_nil, fun _ h => by cases h⟩
  have hk : tokOK (.kw F.red.kw) ∧ Tok.kw F.red.kw ≠ .kw .lp := by cases F.red <;> exact ⟨rfl, by simp [RedK.kw]⟩
  have hH : Good (headToks .typst F) ∧ Nice (headToks .typst F) ∧ headToks .typst F ≠ [] := by
    simp only [headToks]
    split
    · refine ⟨good_cons_lp rfl rfl (good_cons hk.1 (good_single rfl) (nice_cons _ (by simp) rfl))
        (nice_cons _ hk.2 rfl), nice_cons _ (by simp) rfl, by simp⟩
    · exact ⟨good_single hk.1, nice_cons _ hk.2 rfl, by simp⟩
  have hRows : ∀ x ∈ subRows c P F, Good x ∧ Nice x := by
    intro x hx
    unfold subRows at hx
    rcases List.mem_append.1 hx with hx | hx
    · obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hx
      exact hRow kv (List.mem_filter.1 hkv).1
    · split at hx
      · rename_i y hy
        simp only [List.mem_singleton] at hx; subst hx
        rw [hc]; exact ⟨(hQ y (by simp [faqSubs, hy]) 1).1, (hQ y (by simp [faqSubs, hy]) 1).2.1⟩
      · cases hx
  have hSub : Good (subToks c P F) ∧ Nice (subToks c P F) := by
    rw [subToks_eq, iteF (by rw [hc]; decide)]; unfold subToksT
    split
    · exact ⟨good_nil, fun _ h => by cases h⟩
    · have hS := good_sepBy .nl rfl (by simp) _ hRows
      have hR : Good (sepBy [.kw .nl] (subRows c P F) ++ [.kw .rp]) ∧
          Nice (sepBy [.kw .nl] (subRows c P F) ++ [.kw .rp]) := by
        refine ⟨good_append hS.1 (good_single rfl) (nice_cons _ (by simp) rfl), ?_⟩
        by_cases he : sepBy [.kw .nl] (subRows c P F) = []
        · rw [he]; exact nice_cons _ (by simp) rfl
        · exact nice_append _ hS.2 he
      simp only [List.cons_append, List.nil_append]
      exact ⟨good_cons rfl (good_cons rfl hR.1 hR.2) (nice_cons _ (by simp) rfl), nice_cons _ (by simp) rfl⟩
  obtain ⟨hB1, hB2, hB3⟩ := hQ F.expr (by simp [faqSubs]) 5
  have hRed : Good (redToks c P F) ∧ Nice (redToks c P F) ∧ redToks c P F ≠ [] := by
    unfold redToks; rw [hc]
    refine ⟨good_append (good_append hH.1 hSub.1 hSub.2) hB1 hB2, nice_append _ (nice_append _ hH.2.1 hH.2.2)
      (by simp [hH.2.2]), by simp [hH.2.2]⟩
  have hEnt : ∀ x ∈ F.out.map (entryToks c P F), Good x ∧ Nice x := by
    intro x hx
    obtain ⟨j, -, rfl⟩ := List.mem_map.1 hx
    unfold entryToks
    split
    · split
      · rename_i v hv; exact hRow _ (look_mem hv)
      · exact ⟨(good_nameToks c hc _).1, (good_nameToks c hc _).2.1⟩
    · exact ⟨good_single tokOK_num1, nice_cons _ (by simp) rfl⟩
  have hE := good_sepBy .comma rfl (by simp) _ hEnt
  have hE' : Good (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ [.kw .rp]) ∧
      Nice (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ [.kw .rp]) := by
    refine ⟨good_append hE.1 (good_single rfl) (nice_cons _ (by simp) rfl), ?_⟩
    by_cases he : sepBy [.kw .comma] (F.out.map (entryToks c P F)) = []
    · rw [he]; exact nice_cons _ (by simp) rfl
    · exact nice_append _ hE.2 he
  unfold faqOut
  rw [hc]
  split
  · exact hRed.1
  · simp only [mkOut, List.cons_append, List.nil_append, List.append_assoc]
    have hTail : Good (.kw .rbk :: .kw .rp :: .kw .us :: .kw .lpg ::
        (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ [.kw .rp])) :=
      good_cons rfl (good_cons rfl (good_cons rfl (good_cons rfl hE'.1 hE'.2) (nice_cons _ (by simp) rfl))
        (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl)
    exact good_cons_lp rfl rfl (good_cons rfl (good_append hRed.1 hTail (nice_cons _ (by simp) rfl))
      (nice_append _ hRed.2.1 hRed.2.2)) (nice_cons _ (by simp) rfl)

/-! ## The induction -/

def TP (c : Ctx) (e : Json) : Prop :=
  Good (pr c e).toks ∧ Good (pr c e).crow ∧ Nice (pr c e).crow

theorem TP_all (c : Ctx) (hc : c.sf = .typst) : ∀ n e, sizeOf e < n → isE e = true → TP c e
  | 0, _, h, _ => absurd h (Nat.not_lt_zero _)
  | n + 1, e, hs, he => by
    have IH : ∀ x, sizeOf x < sizeOf e → isE x = true → TP c x :=
      fun x hx hxe => TP_all c hc n x (by omega) hxe
    have CH : ∀ x, sizeOf x < sizeOf e → isE x = true → ∀ L,
        Good ((pr c x).at .typst L) ∧ Nice ((pr c x).at .typst L) ∧ (pr c x).at .typst L ≠ [] := by
      intro x hx hxe L
      have hm := M_of_isE c x hxe
      have hh := headOK_at hm L
      rw [hc] at hh
      obtain ⟨hn, hne⟩ := nice_of_head hh
      refine ⟨?_, hn, hne⟩
      have hh0 := M_head hm
      rw [at_eq]; split
      · exact (IH x hx hxe).1
      · exact good_grp (IH x hx hxe).1 (nice_of_head hh0).1
    have hself := M_of_isE c e he
    have hselfN := nice_of_head (M_head hself)
    unfold TP
    cases view c e he with
    | num k hk =>
      rw [pr_num] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_single hk) hselfN.1 hselfN.2
    | name s _ =>
      rw [pr_str] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_nameToks c hc s).1 hselfN.1 hselfN.2

    | neg o a ho ha hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 5
      have hG := good_grp hA hAn
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      refine mk_ok ?_ hselfN.1 hselfN.2
      split
      · exact good_cons rfl hG (nice_cons _ (by simp) rfl)
      · exact good_cons rfl hA hAn
    | minus o a b ho ha hb hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 4
      obtain ⟨hB, hBn, hBne⟩ := CH b (sizeOf_node_lt (by simp)) hb 5
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_append hA (good_cons rfl hB hBn) (nice_cons _ (by simp) rfl)) hselfN.1 hselfN.2
    | div o a b ho ha hb hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 8
      obtain ⟨hB, hBn, hBne⟩ := CH b (sizeOf_node_lt (by simp)) hb 8
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_append hA (good_cons rfl hB hBn) (nice_cons _ (by simp) rfl)) hselfN.1 hselfN.2
    | pow o a b ho ha hb hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 9
      have hBt := (IH b (sizeOf_node_lt (by simp)) hb).1
      have hBtn := (nice_of_head (M_head (M_of_isE c b hb))).1
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      refine mk_ok (good_append hA (good_cons rfl ?_ ?_) (nice_cons _ (by simp) rfl)) hselfN.1 hselfN.2
      · split
        · rename_i t hst
          exact good_single (simpleE_ok c hc b hb t hst).1
        · exact good_grp hBt hBtn
      · split
        · rename_i t hst
          exact nice_cons _ (simpleE_ok c hc b hb t hst).2.1 (simpleE_ok c hc b hb t hst).2.2
        · exact nice_cons _ (by simp) rfl
    | lnot o a ho ha hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 6
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_cons rfl hA hAn) hselfN.1 hselfN.2
    | tru o ho hpr =>
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_single (tokOK_txt _ (by decide))) hselfN.1 hselfN.2
    | fls o ho hpr =>
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_single (tokOK_txt _ (by decide))) hselfN.1 hselfN.2
    | ite o cnd a b ho hcn ha hb hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 1
      obtain ⟨hC, hCn, hCne⟩ := CH cnd (sizeOf_node_lt (by simp)) hcn 1
      obtain ⟨-, hBc, hBcn⟩ := IH b (sizeOf_node_lt (by simp)) hb
      have hrows : Good (caseRow .typst ((pr c a).at .typst 1) ((pr c cnd).at .typst 1) ++ (pr c b).crow) := by
        simp only [caseRow, reduceCtorEq, ↓reduceIte, List.append_assoc, List.cons_append, List.nil_append]
        exact good_append hA (good_cons rfl (good_cons (tokOK_txt _ (by decide))
          (good_append hC (good_cons rfl hBc hBcn) (nice_cons _ (by simp) rfl)) (nice_append _ hCn hCne))
          (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl)
      have hrowsN : Nice (caseRow .typst ((pr c a).at .typst 1) ((pr c cnd).at .typst 1) ++ (pr c b).crow) := by
        simp only [caseRow, List.append_assoc]; exact nice_append _ hAn hAne
      rw [hpr]
      refine ⟨?_, hrows, hrowsN⟩
      generalize caseRow .typst ((pr c a).at .typst 1) ((pr c cnd).at .typst 1) ++ (pr c b).crow = R at hrows hrowsN ⊢
      have hr2 : Good (R ++ [.kw .rp]) :=
        good_append hrows (good_single (show tokOK (.kw .rp) from rfl)) (nice_cons _ (by simp) rfl)
      rw [show casesToks .typst R = .kw .cases :: .kw .lp :: (R ++ [.kw .rp]) by simp [casesToks]]
      refine good_cons_lp rfl rfl hr2 ?_
      by_cases he : R = []
      · rw [he]; exact nice_cons _ (by simp) rfl
      · exact nice_append _ hrowsN he
    | un o k a ho ha hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 1
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_unToks o k (kindOf_un ho) _ hA hAn).1 hselfN.1 hselfN.2
    | ic o m ho hm hpr =>
      simp only [hc] at hpr
      obtain ⟨hN, -, hNl⟩ := good_nameToks c hc m
      rw [hpr] at hselfN ⊢; simp only [mkOut, icTail] at hselfN ⊢
      refine mk_ok (good_append_lp hN hNl ?_ (nice_cons _ (by simp) rfl)) hselfN.1 hselfN.2
      exact good_cons rfl (good_cons rfl (good_cons tokOK_num0 (good_single rfl) (nice_cons _ (by simp) rfl))
        (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl)
    | idxSub o b is ho hne hsub hsp hi hpr =>
      simp only [hc] at hpr
      obtain ⟨hN, -, -⟩ := good_nameToks c hc b
      have hS := good_sepBy .comma rfl (by simp) (is.map fun x => (pr c x).at .typst 1) (fun y hy => by
        obtain ⟨x, hx, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx) 1).1,
          (CH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx) 1).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut, subList] at hselfN ⊢
      refine mk_ok (good_append hN ?_ (by split <;> exact nice_cons _ (by simp) rfl)) hselfN.1 hselfN.2
      split
      · rename_i t hst
        unfold simpleArg at hst
        split at hst
        · rename_i x
          have hx := hi x (by simp)
          have := simpleE_ok c hc x hx t hst
          exact good_cons (show tokOK (.kw .us) from rfl) (good_single this.1) (nice_cons _ this.2.1 this.2.2)
        · cases hst
      · simp only [List.cons_append, List.nil_append]
        exact good_cons (show tokOK (.kw .us) from rfl) (good_cons (show tokOK (.kw .lpg) from rfl)
          (good_append hS.1 (good_single (show tokOK (.kw .rp) from rfl)) (nice_cons _ (by simp) rfl))
          (by
            by_cases he : sepBy [.kw .comma] (is.map fun x => (pr c x).at .typst 1) = []
            · rw [he]; exact nice_cons _ (by simp) rfl
            · exact nice_append _ hS.2 he)) (nice_cons _ (by simp) rfl)
    | idxBr o base is ho hne hb hi hpr =>
      simp only [hc] at hpr
      obtain ⟨hB, hBn, hBne⟩ := CH base (sizeOf_node_lt (by simp)) hb 10
      have hS := good_sepBy .comma rfl (by simp) (is.map fun x => (pr c x).at .typst 1) (fun y hy => by
        obtain ⟨x, hx, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx) 1).1,
          (CH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx) 1).2.1⟩)
      have hT : Good ((pr c base).at .typst 10 ++ [.kw .lbk] ++
          sepBy [.kw .comma] (is.map fun x => (pr c x).at .typst 1) ++ [.kw .rbk]) := by
        simp only [List.append_assoc, List.singleton_append]
        refine good_append hB (good_cons (show tokOK (.kw .lbk) from rfl)
          (good_append hS.1 (good_single (show tokOK (.kw .rbk) from rfl)) (nice_cons _ (by simp) rfl))
          ?_) (nice_cons _ (by simp) rfl)
        by_cases he : sepBy [.kw .comma] (is.map fun x => (pr c x).at .typst 1) = []
        · rw [he]; exact nice_cons _ (by simp) rfl
        · exact nice_append _ hS.2 he
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hT hselfN.1 hselfN.2
    | cmp o k a b ho ha hb hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_node_lt (by simp)) ha 4
      obtain ⟨hB, hBn, hBne⟩ := CH b (sizeOf_node_lt (by simp)) hb 4
      have hco := kindOf_cmp ho
      have hk : tokOK (.kw k) ∧ k ≠ .lp := by
        rw [cmpOf.eq_def] at hco
        cases k <;> simp only [reduceCtorEq, Option.some.injEq] at hco <;> exact ⟨rfl, by simp⟩
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok (good_append hA (good_cons hk.1 hB hBn) (nice_cons _ (by simp [hk.2]) rfl)) hselfN.1 hselfN.2
    | plus o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := good_sepBy .plus rfl (by simp) (xs.map fun x => (pr c x).at .typst 5) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (sizeOf_node_lt hm) (hx x hm) 5).1, (CH x (sizeOf_node_lt hm) (hx x hm) 5).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | times o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := good_mulToks (xs.map fun x => (pr c x).at .typst 6) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        exact CH x (sizeOf_node_lt hm) (hx x hm) 6)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | land o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := good_sepBy .land rfl (by simp) (xs.map fun x => (pr c x).at .typst 3) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (sizeOf_node_lt hm) (hx x hm) 3).1, (CH x (sizeOf_node_lt hm) (hx x hm) 3).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | lor o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := good_sepBy .lor rfl (by simp) (xs.map fun x => (pr c x).at .typst 2) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (sizeOf_node_lt hm) (hx x hm) 2).1, (CH x (sizeOf_node_lt hm) (hx x hm) 2).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | mm o k xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hk : tokOK (.kw k) ∧ callEnd (.kw k) = true := by
        rcases kindOf_mm ho with ⟨-, rfl⟩ | ⟨-, rfl⟩ <;> exact ⟨rfl, rfl⟩
      have hS := good_callToks [.kw k] (good_single hk.1) ⟨by simp, fun u hu => by simp at hu; subst hu; exact hk.2⟩
        (nice_cons _ (by rcases kindOf_mm ho with ⟨-, rfl⟩ | ⟨-, rfl⟩ <;> simp) rfl)
        (xs.map fun x => (pr c x).at .typst 1) (fun y hy => by
          obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
          exact ⟨(CH x (sizeOf_node_lt hm) (hx x hm) 1).1, (CH x (sizeOf_node_lt hm) (hx x hm) 1).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | call o xs ho hx hpr =>
      simp only [hc] at hpr
      have hS := good_callToks [.opn o] (good_single trivial) ⟨by simp, fun u hu => by simp at hu; subst hu; exact callEnd_opn o⟩
        (nice_cons _ (by simp) rfl)
        (xs.map fun x => (pr c x).at .typst 4) (fun y hy => by
          obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
          exact ⟨(CH x (sizeOf_node_lt hm) (hx x hm) 4).1, (CH x (sizeOf_node_lt hm) (hx x hm) 4).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2

    | dTime a ha hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_dNode_lt a _) ha 1
      have hG := good_grp hA hAn
      rw [hpr] at hselfN ⊢
      simp only [dTime] at hselfN ⊢
      by_cases hin : inlineD (pr c a) = true <;>
        simp only [hin, Bool.false_eq_true, ↓reduceIte, mkOut] at hselfN ⊢ <;> refine mk_ok ?_ hselfN.1 hselfN.2
      · have hF : Good [Tok.kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp] ∧
            Nice [Tok.kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp] := by fixed
        simp only [List.cons_append, List.nil_append]
        exact good_cons rfl (good_cons rfl (good_append hA hF.1 hF.2) (nice_append _ hAn hAne))
          (nice_cons _ (by simp) rfl)
      · have hF : Good [Tok.kw .lpg, .kw .dif, .kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp] ∧
            Nice [Tok.kw .lpg, .kw .dif, .kw .rp, .kw .slash, .kw .lpg, .kw .dif, .letter 't', .kw .rp] := by fixed
        exact good_append hF.1 hG (nice_cons _ (by simp) rfl)
    | dSpace w a hw hwn ha hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, hAn, hAne⟩ := CH a (sizeOf_dNode_lt a _) ha 1
      have hG := good_grp hA hAn
      obtain ⟨hW, hWn, hWl⟩ := good_nameToks c hc w
      rw [hpr] at hselfN ⊢
      simp only [dSpace] at hselfN ⊢
      by_cases hin : inlineD (pr c a) = true <;>
        simp only [hin, Bool.false_eq_true, ↓reduceIte, mkOut] at hselfN ⊢ <;> refine mk_ok ?_ hselfN.1 hselfN.2
      · have hF : Good [Tok.kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ∧
            Nice [Tok.kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] := by fixed
        simp only [List.cons_append, List.nil_append, List.append_assoc]
        exact good_cons rfl (good_cons rfl (good_append hA (good_append hF.1 (good_append hW (good_single rfl)
          (nice_cons _ (by simp) rfl)) (nice_append _ hWn hWl.1)) (nice_append _ hF.2 (by simp)))
          (nice_append _ hAn hAne)) (nice_cons _ (by simp) rfl)
      · have hF : Good [Tok.kw .lpg, .kw .pdiff, .kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] ∧
            Nice [Tok.kw .lpg, .kw .pdiff, .kw .rp, .kw .slash, .kw .lpg, .kw .pdiff] := by fixed
        simp only [List.append_assoc]
        exact good_append hF.1 (good_append hW (good_append (good_single rfl) hG (nice_cons _ (by simp) rfl))
          (nice_cons _ (by simp) rfl)) (nice_append _ hWn hWl.1)
    | dCall w xs hw hwn hl hx hpr =>
      simp only [hc] at hpr
      obtain ⟨hW, hWn, hWl⟩ := good_nameToks c hc w
      have hF : Good [Tok.opn "D", .kw .us, .kw .lpg] ∧ Nice [Tok.opn "D", .kw .us, .kw .lpg] := by fixed
      have hH : Good ([Tok.opn "D", .kw .us, .kw .lpg] ++ nameToks c w ++ [.kw .rp]) :=
        good_append (good_append hF.1 hW hWn) (good_single rfl) (nice_cons _ (by simp) rfl)
      have hS := good_callToks ([Tok.opn "D", .kw .us, .kw .lpg] ++ nameToks c w ++ [.kw .rp]) hH
        (lastCall_append _ ⟨by simp, fun u hu => by simp at hu; subst hu; rfl⟩) (nice_append _ (nice_append _ hF.2 (by simp)) (by simp))
        (xs.map fun x => (pr c x).at .typst 4) (fun y hy => by
          obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
          exact ⟨(CH x (sizeOf_dCallNode_lt hm) (hx x hm) 4).1, (CH x (sizeOf_dCallNode_lt hm) (hx x hm) 4).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut, dCall] at hselfN ⊢
      have e : [Tok.opn "D", .kw .us, .kw .lpg] ++ nameToks c w ++ [.kw .rp] ++
          callToks .typst [] (xs.map fun x => (pr c x).at .typst 4) =
          callToks .typst ([Tok.opn "D", .kw .us, .kw .lpg] ++ nameToks c w ++ [.kw .rp])
            (xs.map fun x => (pr c x).at .typst 4) := by simp [callToks]
      rw [e] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | qty u k hk hu hpr =>
      simp only [hc] at hpr hu
      have hl : factorsOf u ≠ [] ∧ ∀ f ∈ factorsOf u, Esm.Units.symOK f.1 = true ∧ f.2 ≠ 0 := by
        simp only [unitsOK, Bool.and_eq_true, bne_iff_ne, ne_eq, List.all_eq_true, bne_iff_ne] at hu
        exact ⟨hu.1.1.1, fun f hf => hu.1.2 f hf⟩
      rw [hpr] at hselfN ⊢; simp only [mkOut, qtyToks] at hselfN ⊢
      have hT : Good [Tok.num k, .units (factorsOf u)] :=
        ⟨(by simp; exact ⟨hk, hl⟩), ⟨(fun e => by cases e), (fun h => by simp [isUnits] at h), trivial⟩⟩
      exact mk_ok hT hselfN.1 hselfN.2
    | arr xs af haf hpr =>
      simp only [hc] at hpr
      obtain ⟨hA, -, -⟩ := good_arr af (arrForm_spec haf).2
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hA hselfN.1 hselfN.2
    | arrU u xs af haf hu hpr =>
      simp only [hc] at hpr hu
      obtain ⟨hA, -, hl⟩ := good_arr af (arrForm_spec haf).2
      have hlf : factorsOf u ≠ [] ∧ ∀ f ∈ factorsOf u, Esm.Units.symOK f.1 = true ∧ f.2 ≠ 0 := by
        simp only [unitsOK, Bool.and_eq_true, bne_iff_ne, ne_eq, List.all_eq_true, bne_iff_ne] at hu
        exact ⟨hu.1.1.1, fun f hf => hu.1.2 f hf⟩
      have hT : Good (arrToks .typst af ++ unitToks (factorsOf u)) := by
        simp only [unitToks]
        refine ⟨fun t ht => ?_, adj_snoc _ _ hA.2 (by simp) hl⟩
        rcases List.mem_append.1 ht with ht | ht
        · exact hA.1 t ht
        · simp at ht; subst ht; exact hlf
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hT hselfN.1 hselfN.2
    | faq kvs F hF hok P hP hpr =>
      have hT := good_faqOut c hc F P (fun x hx L => by
        rw [hP x hx]; exact CH x (faqSubs_lt hF hx) (faqSubs_isE hok x hx) L)
      rw [hpr] at hselfN ⊢
      have hm := mk_ok hT hselfN.1 hselfN.2
      rw [faqOut_crow]
      exact ⟨hT, hm.2.1, hm.2.2⟩
    | tpos m bs ps hm hsb hb hps hpr =>
      simp only [hc] at hpr
      have hS := good_callToks [.opn m] (good_single trivial) ⟨by simp, fun u hu => by simp at hu; subst hu; exact callEnd_opn m⟩
        (nice_cons _ (by simp) rfl)
        (ps.map fun p => ((bs.map fun kv => (kv.1, (pr c kv.2).at .typst 4)).lookup p).getD []) (fun y hy => by
          obtain ⟨p, -, rfl⟩ := List.mem_map.1 hy
          rw [lookup_map_look (fun v => (pr c v).at .typst 4) p bs]
          cases hlk : look p bs with
          | none => exact ⟨good_nil, fun _ h => by cases h⟩
          | some v =>
            have hv := look_mem hlk
            exact ⟨(CH v (sizeOf_tNode_lt hv) (hb _ hv) 4).1, (CH v (sizeOf_tNode_lt hv) (hb _ hv) 4).2.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | tnamed m bs hm hb hps hne hk hkn hpr =>
      simp only [hc] at hpr
      have hS := good_callToks [.opn m] (good_single trivial) ⟨by simp, fun u hu => by simp at hu; subst hu; exact callEnd_opn m⟩
        (nice_cons _ (by simp) rfl)
        (bs.map fun kv => nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at .typst 4) (fun y hy => by
          obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hy
          obtain ⟨hN, hNn, hNl⟩ := good_nameToks c hc kv.1
          obtain ⟨hV, hVn, -⟩ := CH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv) 4
          exact ⟨good_append hN (good_cons rfl hV hVn) (nice_cons _ (by simp) rfl), nice_append _ hNn hNl.1⟩)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hS.1 hselfN.1 hselfN.2
    | openop kvs o as hop hargs hsk hx hf hcore hopn htp hkey hsz hszf hpr =>
      simp only [hc] at hpr
      have hA := good_sepBy .comma rfl (by simp) (as.map fun x => (pr c x).at .typst 4) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        exact ⟨(CH x (hsz x hm) (hx x hm) 4).1, (CH x (hsz x hm) (hx x hm) 4).2.1⟩)
      have hFl := good_sepBy .comma rfl (by simp) ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
          (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) (fun y hy => by
        obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hy
        have hV : Good (if isE kv.2 = true then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2) ∧
            Nice (if isE kv.2 = true then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2) := by
          split
          · rename_i hv; exact ⟨(CH kv.2 (hszf kv hkv) hv 4).1, (CH kv.2 (hszf kv hkv) hv 4).2.1⟩
          · exact ⟨good_single (jwf_sound _ (hf kv hkv)), nice_cons _ (by simp) rfl⟩
        have hK : tokOK (.ups [(kv.1, "")]) := ⟨by simp, fun p hp => by simp at hp; subst hp; left; rfl⟩
        simp only [keyToks]
        exact ⟨good_cons hK (good_cons rfl hV.1 hV.2) (nice_cons _ (by simp) rfl), nice_cons _ (by simp) rfl⟩)
      have hTail : Good (sepBy [.kw .comma] (as.map fun x => (pr c x).at .typst 4) ++
          ((if (fieldsOf kvs).map (fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) = [] then []
           else .kw .semi :: sepBy [.kw .comma] ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2))) ++ [.kw .rp])) ∧
          Nice (sepBy [.kw .comma] (as.map fun x => (pr c x).at .typst 4) ++
          ((if (fieldsOf kvs).map (fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) = [] then []
           else .kw .semi :: sepBy [.kw .comma] ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2))) ++ [.kw .rp])) := by
        have hR : Good ((if (fieldsOf kvs).map (fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) = [] then []
           else .kw .semi :: sepBy [.kw .comma] ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2))) ++ [.kw .rp]) ∧
            Nice ((if (fieldsOf kvs).map (fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) = [] then []
           else .kw .semi :: sepBy [.kw .comma] ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2))) ++ [.kw .rp]) := by
          split
          · exact ⟨good_single rfl, nice_cons _ (by simp) rfl⟩
          · exact ⟨good_cons rfl (good_append hFl.1 (good_single rfl) (nice_cons _ (by simp) rfl))
              (by
                by_cases he : sepBy [.kw .comma] ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
                    (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2)) = []
                · rw [he]; exact nice_cons _ (by simp) rfl
                · exact nice_append _ hFl.2 he), nice_cons _ (by simp) rfl⟩
        refine ⟨good_append hA.1 hR.1 hR.2, ?_⟩
        by_cases he : sepBy [.kw .comma] (as.map fun x => (pr c x).at .typst 4) = []
        · rw [he, List.nil_append]; exact hR.2
        · exact nice_append _ hA.2 he
      have hT : Good (openToks .typst o (as.map fun x => (pr c x).at .typst 4)
          ((fieldsOf kvs).map fun kv => keyToks .typst kv.1 ++ .kw .eq ::
            (if isE kv.2 then (pr c kv.2).at .typst 4 else jsonVal .typst kv.2))) := by
        simp only [openToks, lpC, List.cons_append, List.nil_append, List.append_assoc]
        exact good_cons_lp trivial (callEnd_opn o) hTail.1 hTail.2
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hT hselfN.1 hselfN.2
    | esc kvs o as hop hargs hsk hx hf hoOK hrem hdep hsz hpr =>
      simp only [hc] at hpr
      have ho : o ≠ "." := by rintro rfl; exact absurd hoOK (by decide)
      have hFM := good_flatMap (fun a => .kw .comma :: a) (as.map fun x => (pr c x).at .typst 1) (fun y hy => by
        obtain ⟨x, hm, rfl⟩ := List.mem_map.1 hy
        obtain ⟨hA, hAn, -⟩ := CH x (hsz x hm) (hx x hm) 1
        exact ⟨good_cons rfl hA hAn, nice_cons _ (by simp) rfl⟩)
      have hR : Good ((as.map fun x => (pr c x).at .typst 1).flatMap (fun a => .kw .comma :: a) ++ [.kw .rp]) ∧
          Nice ((as.map fun x => (pr c x).at .typst 1).flatMap (fun a => .kw .comma :: a) ++ [.kw .rp]) := by
        refine ⟨good_append hFM.1 (good_single rfl) (nice_cons _ (by simp) rfl), ?_⟩
        by_cases he : (as.map fun x => (pr c x).at .typst 1).flatMap (fun a => .kw .comma :: a) = []
        · rw [he]; exact nice_cons _ (by simp) rfl
        · exact nice_append _ hFM.2 he
      have hj : tokOK (.code (.obj (fieldsOf kvs))) := jwf_obj_fields hsk hf
      have hT : Good (escToks .typst o (fieldsOf kvs) (as.map fun x => (pr c x).at .typst 1)) := by
        simp only [escToks, List.cons_append, List.nil_append]
        exact good_cons_lp rfl rfl (good_cons (tokOK_txt o ho) (good_cons rfl (good_cons hj hR.1 hR.2)
          (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl)) (nice_cons _ (by simp) rfl)
      rw [hpr] at hselfN ⊢; simp only [mkOut] at hselfN ⊢
      exact mk_ok hT hselfN.1 hselfN.2

/-- Every token the Typst printer writes for a well-formed expression is a Typst token,
in an order the Typst lexer reads back. -/
theorem print_ok (S : Sym) (e : Json) (he : isE e = true) :
    (∀ t ∈ print .typst S e, tokOK t) ∧ Adj (print .typst S e) ∧ ∀ r, print .typst S e ≠ .kw .lp :: r := by
  have h := TP_all ⟨.typst, S⟩ rfl _ e (Nat.lt_succ_self _) he
  have hm := M_of_isE ⟨.typst, S⟩ e he
  have hh := headOK_at hm 1
  obtain ⟨hn, -⟩ := nice_of_head hh
  have hg : Good ((pr ⟨.typst, S⟩ e).at .typst 1) := by
    rw [at_eq]; split
    · exact h.1
    · exact good_grp h.1 (nice_of_head (M_head hm)).1
  refine ⟨hg.1, hg.2, fun r e' => ?_⟩
  have := hn (.kw .lp) (by unfold print pa at e'; simp only at e'; rw [e']; rfl)
  exact this.1 rfl

end Esm.Document.Math.Typst
