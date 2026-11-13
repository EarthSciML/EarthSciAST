import Esm.Document.Math.LexLatex

/-!
# The LaTeX printer writes only LaTeX tokens

Every token of a printed well-formed expression is a LaTeX token (`tokOK`), so the
LaTeX lexer lemma applies to the printer's output.
-/

namespace Esm.Document.Math.Latex

open Esm.Document Esm.Document.Math

def AllOK (ts : List Tok) : Prop := ∀ t ∈ ts, tokOK t

theorem allOK_nil : AllOK [] := fun _ h => by cases h

theorem allOK_append {a b : List Tok} : AllOK (a ++ b) ↔ AllOK a ∧ AllOK b := by
  simp only [AllOK, List.mem_append]
  constructor
  · intro h; exact ⟨fun t ht => h t (Or.inl ht), fun t ht => h t (Or.inr ht)⟩
  · rintro ⟨h1, h2⟩ t (ht | ht)
    · exact h1 t ht
    · exact h2 t ht

theorem allOK_cons {t : Tok} {r : List Tok} : AllOK (t :: r) ↔ tokOK t ∧ AllOK r := by
  simp [AllOK]

theorem allOK_sepBy (sep : List Tok) (hs : AllOK sep) :
    ∀ (xs : List (List Tok)), (∀ x ∈ xs, AllOK x) → AllOK (sepBy sep xs)
  | [], _ => allOK_nil
  | [x], h => h x (by simp)
  | x :: y :: ys, h => by
    rw [sepBy_cons2]
    exact allOK_append.2 ⟨allOK_append.2 ⟨h x (by simp), hs⟩,
      allOK_sepBy sep hs (y :: ys) (fun z hz => h z (by simp [hz]))⟩

theorem allOK_flatMap {α : Type} (f : α → List Tok) :
    ∀ (xs : List α), (∀ x ∈ xs, AllOK (f x)) → AllOK (xs.flatMap f)
  | [], _ => allOK_nil
  | x :: xs, h => by
    rw [List.flatMap_cons]
    exact allOK_append.2 ⟨h x (by simp), allOK_flatMap f xs (fun z hz => h z (by simp [hz]))⟩

theorem allOK_map {α : Type} (f : α → List Tok) (xs : List α) (h : ∀ x ∈ xs, AllOK (f x)) :
    ∀ y ∈ xs.map f, AllOK y := by
  intro y hy; obtain ⟨x, hx, rfl⟩ := List.mem_map.1 hy; exact h x hx

theorem tokOK_num0 : tokOK (.num (.int 0)) := by
  show JNum.InInt64 0; unfold JNum.InInt64; decide
theorem tokOK_num10 : tokOK (.num (.int 10)) := by
  show JNum.InInt64 10; unfold JNum.InInt64; decide

/-- Close a goal `AllOK [fixed tokens and pieces]` from the pieces in the context. -/
macro "aok" : tactic => `(tactic| (
  simp only [allOK_append, allOK_cons, List.cons_append, List.nil_append, List.append_assoc,
    and_true, true_and]
  repeat' constructor
  all_goals first | assumption | rfl | exact allOK_nil | exact tokOK_num0 | exact tokOK_num10))

theorem allOK_grp {sf : Sf} (h : sf = .latex) {ts : List Tok} (ht : AllOK ts) : AllOK (grp sf ts) := by
  subst h; simp only [grp, ↓reduceIte]; aok

theorem allOK_at {sf : Sf} (h : sf = .latex) (o : Out) (ht : AllOK o.toks) (L : Nat) :
    AllOK (o.at sf L) := by
  rw [at_eq]; split
  · exact ht
  · exact allOK_grp h ht

/-! ## Names -/

theorem plain_of_alnum {c : Char} (h : isLetter c = true ∨ isDig c = true) :
    c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
  have hr : (65 ≤ c.toNat ∧ c.toNat ≤ 90) ∨ (97 ≤ c.toNat ∧ c.toNat ≤ 122) ∨
      (48 ≤ c.toNat ∧ c.toNat ≤ 57) := by
    rcases h with h | h
    · rcases letter_range h with h | h
      · exact Or.inl h
      · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr (dig_range h))
  refine ⟨ne_of_toNat ?_, ne_of_toNat ?_, ne_of_toNat ?_⟩
  · have : ('\\').toNat = 92 := rfl
    omega
  · have : ('{').toNat = 123 := rfl
    omega
  · have : ('}').toNat = 125 := rfl
    omega

theorem rawB_plain (d : Nat) (Z : List Char) :
    ∀ (cs : List Char), (∀ c ∈ cs, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}') →
      rawB d (cs ++ Z) = (rawB d Z).map (fun p => (cs ++ p.1, p.2))
  | [], _ => by simp only [List.nil_append]; cases rawB d Z <;> rfl
  | c :: cs, h => by
    obtain ⟨h1, h2, h3⟩ := h c (by simp)
    rw [List.cons_append, rawB.eq_5 _ _ _ (fun _ _ e _ => h1 e) h2 (fun _ e => h3 e) (fun _ _ e => h3 e),
      rawB_plain d Z cs (fun x hx => h x (by simp [hx]))]
    cases rawB d Z <;> simp

def fpiece (p : List Char × List Char) : List Char :=
  p.1 ++ (if p.2 = [] then [] else '_' :: '{' :: p.2 ++ ['}'])

theorem rawB_pieces (X : List Char) :
    ∀ (ps : List (List Char × List Char)),
      (∀ p ∈ ps, ∀ c ∈ p.1 ++ p.2, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}') →
      rawB 0 (ps.flatMap fpiece ++ '}' :: X) = some (ps.flatMap fpiece, X)
  | [], _ => rfl
  | p :: ps, h => by
    have hp := h p (by simp)
    have ih := rawB_pieces X ps (fun q hq => h q (by simp [hq]))
    have h1 : ∀ c ∈ p.1, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := fun c hc => hp c (by simp [hc])
    have h2 : ∀ c ∈ p.2, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := fun c hc => hp c (by simp [hc])
    simp only [List.flatMap_cons, fpiece, List.append_assoc]
    rw [rawB_plain 0 _ p.1 h1]
    split
    · rw [List.nil_append, ih]; rfl
    · simp only [List.cons_append, List.append_assoc, List.nil_append]
      rw [rawB.eq_5 _ _ _ (by intro _ _ e; cases e) (by intro e; cases e) (by intro _ e; cases e)
        (by intro _ _ e; cases e), rawB, rawB_plain 1 _ p.2 h2, rawB, ih]
      simp

theorem balOK_escT (s : List Char) : balOK (escT s) = true := by
  simp [balOK, rawB_escT s []]

theorem balOK_formula (g : List Char) (hf : isFormula g = true) : balOK (formulaRaw g) = true := by
  have hcat := pieces_cat hf
  have hall : ∀ c ∈ g, isLetter c = true ∨ isDig c = true := by
    have := hf; simp only [isFormula, Bool.and_eq_true] at this
    intro c hc; simpa using List.all_eq_true.1 this.1.1 c hc
  have hp : ∀ p ∈ pieces g, ∀ c ∈ p.1 ++ p.2, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
    intro p hp c hc
    apply plain_of_alnum
    apply hall
    rw [← hcat]
    exact List.mem_flatMap.2 ⟨p, hp, hc⟩
  have := rawB_pieces [] (pieces g) hp
  unfold balOK formulaRaw
  have e : (pieces g).flatMap (fun p => p.1 ++ (if p.2 = [] then [] else '_' :: '{' :: p.2 ++ ['}'])) =
      (pieces g).flatMap fpiece := rfl
  rw [e, this]; simp

theorem tokOK_baseTok (b : List Char) (hb : isSingle b = true) : tokOK (baseTok b) := by
  unfold baseTok isSingle at *
  split
  · rename_i c; exact hb
  · rename_i hne
    show isGreek (String.ofList b).toList = true
    rw [String.toList_ofList]
    split at hb
    · rename_i c; exact absurd rfl (hne c)
    · exact hb

theorem allOK_segToks (g : List Char) : AllOK (segToks .latex g) := by
  unfold segToks
  split
  · rename_i hs; exact allOK_cons.2 ⟨tokOK_baseTok g hs, allOK_nil⟩
  · split
    · rename_i b r hsp
      have hb := (subParts_spec hsp).2.1
      have hb' := tokOK_baseTok b hb
      have hr : tokOK (.rm (String.ofList (escT r))) := by
        show balOK (String.ofList (escT r)).toList = true
        rw [String.toList_ofList]; exact balOK_escT r
      simp only [subTxt]; aok
    · split
      · rename_i hf
        show AllOK [.rm (String.ofList (formulaRaw g))]
        have hr : tokOK (.rm (String.ofList (formulaRaw g))) := by
          show balOK (String.ofList (formulaRaw g)).toList = true
          rw [String.toList_ofList]; exact balOK_formula g hf
        exact allOK_cons.2 ⟨hr, allOK_nil⟩
      · exact allOK_cons.2 ⟨trivial, allOK_nil⟩

theorem allOK_nameToks (c : Ctx) (hc : c.sf = .latex) (s : String) : AllOK (nameToks c s) := by
  unfold nameToks
  split
  · exact allOK_cons.2 ⟨trivial, allOK_nil⟩
  · rw [hc]
    have hs : AllOK [.kw .sdot] := allOK_cons.2 ⟨(rfl : kwOK .sdot = true), allOK_nil⟩
    exact allOK_sepBy _ hs _ (allOK_map _ _ (fun g _ => allOK_segToks g))

/-! ## JSON -/

mutual
theorem allOK_json : ∀ v : Json, jwf v = true → AllOK (jsonToks v)
  | .null, _ => by
    simp only [jsonToks]; exact allOK_cons.2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "null")), allOK_nil⟩
  | .bool true, _ => by
    simp only [jsonToks]; exact allOK_cons.2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "true")), allOK_nil⟩
  | .bool false, _ => by
    simp only [jsonToks]; exact allOK_cons.2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "false")), allOK_nil⟩
  | .num n, h => by
    simp only [jsonToks]; exact allOK_cons.2 ⟨((numOK_iff n).1 h : tokOK (.num n)), allOK_nil⟩
  | .str s, _ => by
    simp only [jsonToks]; exact allOK_cons.2 ⟨(trivial : tokOK (.jstr s)), allOK_nil⟩
  | .arr xs, h => by
    have := allOK_items xs h
    simp only [jsonToks]; aok
  | .obj kvs, h => by
    simp only [jwf, Bool.and_eq_true] at h
    have := allOK_entries kvs h.2
    simp only [jsonToks]; aok

theorem allOK_items : ∀ vs : List Json, jwfList vs = true → AllOK (jsonItems vs)
  | [], _ => allOK_nil
  | [v], h => by
    simp only [jwfList, Bool.and_eq_true] at h
    exact allOK_json v h.1
  | v :: w :: vs, h => by
    simp only [jwfList, Bool.and_eq_true] at h
    have h1 := allOK_json v h.1
    have h2 := allOK_items (w :: vs) (by simp only [jwfList, Bool.and_eq_true]; exact h.2)
    simp only [jsonItems]; aok

theorem allOK_entries : ∀ kvs : List (String × Json), jwfObj kvs = true → AllOK (jsonEntries kvs)
  | [], _ => allOK_nil
  | [(k, v)], h => by
    simp only [jwfObj, Bool.and_eq_true] at h
    have h1 := allOK_json v h.1
    simp only [jsonEntries]
    exact allOK_cons.2 ⟨(trivial : tokOK (.jstr k)), allOK_cons.2 ⟨(rfl : kwOK .colon = true), h1⟩⟩
  | (k, v) :: e :: es, h => by
    simp only [jwfObj, Bool.and_eq_true] at h
    have h1 := allOK_json v h.1
    have h2 := allOK_entries (e :: es) (by obtain ⟨k', v'⟩ := e; simp only [jwfObj, Bool.and_eq_true]; exact h.2)
    simp only [jsonEntries]
    have ht : tokOK (.jstr k) := trivial
    aok
end

end Esm.Document.Math.Latex
