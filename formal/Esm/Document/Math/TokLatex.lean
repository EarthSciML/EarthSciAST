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
  try simp only [allOK_append, allOK_cons, List.cons_append, List.nil_append, List.append_assoc,
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

/-! ## Printer pieces -/

theorem allOK_mulToks : ∀ (xs : List (List Tok)), (∀ x ∈ xs, AllOK x) → AllOK (mulToks xs)
  | [], _ => allOK_nil
  | x :: xs, h => by
    simp only [mulToks]
    refine allOK_append.2 ⟨h x (by simp), allOK_flatMap _ xs (fun y hy => ?_)⟩
    have hy' := h y (by simp [hy])
    split
    · exact allOK_cons.2 ⟨(rfl : kwOK .cdot = true), hy'⟩
    · exact hy'

theorem allOK_callToks (head : List Tok) (hh : AllOK head) (args : List (List Tok))
    (ha : ∀ x ∈ args, AllOK x) : AllOK (callToks .latex head args) := by
  have hs := allOK_sepBy [.kw .comma] (allOK_cons.2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) args ha
  simp only [callToks, lpC]; aok

theorem allOK_unToks (o : String) (k : Kw) (hk : unKw.lookup o = some k) (t : List Tok)
    (ht : AllOK t) : AllOK (unToks .latex k t) := by
  have hm := lookup_mem hk
  simp only [unKw, fnKw, List.cons_append, List.nil_append, List.mem_cons, Prod.mk.injEq,
    List.not_mem_nil, or_false] at hm
  rcases hm with ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ |
    ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ | ⟨-, rfl⟩ <;>
  (simp only [unToks, callToks, lpC, sepBy]; aok)

theorem jwfObj_of : ∀ (kvs : List (String × Json)), (∀ kv ∈ kvs, jwf kv.2 = true) → jwfObj kvs = true
  | [], _ => rfl
  | (k, v) :: r, h => by
    simp only [jwfObj, Bool.and_eq_true]
    exact ⟨h (k, v) (by simp), jwfObj_of r (fun kv hkv => h kv (by simp [hkv]))⟩

theorem allOK_lookup (bs : List (String × Json)) (F : Json → List Tok)
    (h : ∀ kv ∈ bs, AllOK (F kv.2)) (p : String) :
    AllOK (((bs.map fun kv => (kv.1, F kv.2)).lookup p).getD []) := by
  rw [lookup_map_look F p bs]
  cases hl : look p bs with
  | none => exact allOK_nil
  | some v => exact h (p, v) (look_mem hl)

/-! ## The induction -/

def POK (c : Ctx) (e : Json) : Prop := AllOK (pr c e).toks ∧ AllOK (pr c e).crow

theorem POK_toks {c : Ctx} {e : Json} (h : POK c e) (L : Nat) : AllOK ((pr c e).at .latex L) :=
  allOK_at rfl _ h.1 L

theorem POK_all (c : Ctx) (hc : c.sf = .latex) : ∀ n e, sizeOf e < n → isE e = true → POK c e
  | 0, _, h, _ => absurd h (Nat.not_lt_zero _)
  | n + 1, e, hs, he => by
    have IH : ∀ x, sizeOf x < sizeOf e → isE x = true → POK c x :=
      fun x hx hxe => POK_all c hc n x (by omega) hxe
    have hsep : ∀ (k : Kw), kwOK k = true → ∀ (xs : List (List Tok)), (∀ x ∈ xs, AllOK x) →
        AllOK (sepBy [.kw k] xs) :=
      fun k hk xs hx => allOK_sepBy [Tok.kw k] (allOK_cons.2 ⟨(show tokOK (Tok.kw k) from hk), allOK_nil⟩) xs hx
    unfold POK
    cases view c e he with
    | num k hk =>
      rw [pr_num]; have : tokOK (.num k) := hk
      simp only [mkOut]; constructor <;> aok
    | name s _ =>
      rw [pr_str]; have := allOK_nameToks c hc s
      simp only [mkOut]; constructor <;> aok
    | neg o a ho ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 5
      have hG := allOK_grp (sf := .latex) rfl hA
      rw [hpr]; simp only [mkOut]
      split <;> constructor <;> aok
    | minus o a b ho ha hb hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 4
      have hB := POK_toks (IH b (sizeOf_node_lt (by simp)) hb) 5
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | div o a b ho ha hb hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 1
      have hB := POK_toks (IH b (sizeOf_node_lt (by simp)) hb) 1
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | pow o a b ho ha hb hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 9
      have hB := POK_toks (IH b (sizeOf_node_lt (by simp)) hb) 1
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | lnot o a ho ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 6
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | tru o ho hpr => rw [hpr]; simp only [mkOut]; constructor <;> aok
    | fls o ho hpr => rw [hpr]; simp only [mkOut]; constructor <;> aok
    | ite o cnd a b ho hcn ha hb hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 1
      have hC := POK_toks (IH cnd (sizeOf_node_lt (by simp)) hcn) 1
      have hB := (IH b (sizeOf_node_lt (by simp)) hb).2
      rw [hpr]; simp only [casesToks, caseRow, ↓reduceIte]; constructor <;> aok
    | un o k a ho ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 1
      have hU := allOK_unToks o k (kindOf_un ho) _ hA
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | ic o m ho hm hpr =>
      simp only [hc] at hpr
      have hN := allOK_nameToks c hc m
      rw [hpr]; simp only [mkOut, icTail]; constructor <;> aok
    | idxSub o b is ho hne hsub hsp hi hpr =>
      simp only [hc] at hpr
      have hN := allOK_nameToks c hc b
      have hS := allOK_sepBy [.kw .comma] (allOK_cons.2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map _ is (fun x hx => POK_toks (IH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx)) 1))
      rw [hpr]; simp only [mkOut, subList]; constructor <;> aok
    | idxBr o base is ho hne hb hi hpr =>
      simp only [hc] at hpr
      have hB := POK_toks (IH base (sizeOf_node_lt (by simp)) hb) 10
      have hS := allOK_sepBy [.kw .comma] (allOK_cons.2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map _ is (fun x hx => POK_toks (IH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx)) 1))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | cmp o k a b ho ha hb hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 4
      have hB := POK_toks (IH b (sizeOf_node_lt (by simp)) hb) 4
      have hco := kindOf_cmp ho
      have hk : tokOK (.kw k) := by
        show kwOK k = true
        cases k <;> first | rfl | (simp [cmpOf] at hco)
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | plus o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := hsep .plus rfl _ (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 5))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | times o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := allOK_mulToks _ (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 6))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | land o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := hsep .land rfl _ (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 3))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | lor o xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hS := hsep .lor rfl _ (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 2))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | mm o k xs ho hl hx hpr =>
      simp only [hc] at hpr
      have hk : tokOK (.kw k) := by
        rcases kindOf_mm ho with ⟨-, rfl⟩ | ⟨-, rfl⟩ <;> rfl
      have hS := allOK_callToks [.kw k] (allOK_cons.2 ⟨hk, allOK_nil⟩) _
        (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 1))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | call o xs ho hx hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn o] (allOK_cons.2 ⟨trivial, allOK_nil⟩) _
        (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 4))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | dTime a ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_dNode_lt a _) ha) 1
      have hG := allOK_grp (sf := .latex) rfl hA
      rw [hpr]; simp only [dTime]
      split <;> (simp only [mkOut]; constructor <;> aok)
    | dSpace w a hw hwn ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_dNode_lt a _) ha) 1
      have hG := allOK_grp (sf := .latex) rfl hA
      have hN := allOK_nameToks c hc w
      rw [hpr]; simp only [dSpace]
      split <;> (simp only [mkOut]; constructor <;> aok)
    | dCall w xs hw hwn hl hx hpr =>
      simp only [hc] at hpr
      have hN := allOK_nameToks c hc w
      have hS := allOK_callToks [] allOK_nil _
        (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_dCallNode_lt hm) (hx x hm)) 4))
      rw [hpr]; simp only [mkOut, dCall]; constructor <;> aok
    | qty u k hk hu hpr =>
      simp only [hc] at hpr
      have hb : tokOK (.rm (String.ofList (Esm.Units.latexBody (factorsOf u)))) := by
        show balOK (String.ofList (Esm.Units.latexBody (factorsOf u))).toList = true
        rw [String.toList_ofList]
        simp only [unitsOK, hc, Bool.and_eq_true] at hu
        exact hu.2.2
      have hn : tokOK (.num k) := hk
      rw [hpr]; simp only [mkOut, qtyToks]; constructor <;> aok
    | tpos m bs ps hm hsb hb hps hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn m] (allOK_cons.2 ⟨trivial, allOK_nil⟩) _
        (allOK_map _ ps (fun p _ => allOK_lookup bs (fun v => (pr c v).at .latex 4)
          (fun kv hkv => POK_toks (IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) 4) p))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | tnamed m bs hm hb hps hne hk hkn hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn m] (allOK_cons.2 ⟨trivial, allOK_nil⟩) _
        (allOK_map (fun kv => nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at .latex 4) bs (fun kv hkv => by
          have hN := allOK_nameToks c hc kv.1
          have hV := POK_toks (IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) 4
          aok))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | openop kvs o as hop hargs hsk hx hf hcore hopn htp hkey hsz hszf hpr =>
      simp only [hc] at hpr
      have hA := hsep .comma rfl _ (allOK_map _ as (fun x hm => POK_toks (IH x (hsz x hm) (hx x hm)) 4))
      have hF := hsep .comma rfl _ (allOK_map (fun kv => keyToks .latex kv.1 ++ .kw .eq ::
          (if isE kv.2 then (pr c kv.2).at .latex 4 else jsonVal .latex kv.2)) (fieldsOf kvs) (fun kv hkv => by
          have hK : tokOK (.rm (String.ofList (escT kv.1.toList))) := by
            show balOK (String.ofList (escT kv.1.toList)).toList = true
            rw [String.toList_ofList]; exact balOK_escT _
          have hV : AllOK (if isE kv.2 = true then (pr c kv.2).at .latex 4 else jsonVal .latex kv.2) := by
            split
            · rename_i hv; exact POK_toks (IH kv.2 (hszf kv hkv) hv) 4
            · exact allOK_json kv.2 (hf kv hkv)
          simp only [keyToks]; aok))
      rw [hpr]; simp only [mkOut, openToks, lpC]
      split <;> (constructor <;> aok)
    | esc kvs o as hop hargs hsk hx hf hoOK hrem hdep hsz hpr =>
      simp only [hc] at hpr
      have hA := hsep .comma rfl _ (allOK_map _ as (fun x hm => POK_toks (IH x (hsz x hm) (hx x hm)) 1))
      have hJ := allOK_entries (fieldsOf kvs) (jwfObj_of _ hf)
      have hE : tokOK (.esc o) := trivial
      rw [hpr]; simp only [mkOut, escToks, jsonToks]; constructor <;> aok

/-- Every token the LaTeX printer writes for a well-formed expression is a LaTeX token. -/
theorem print_tokOK (S : Sym) (e : Json) (he : isE e = true) : ∀ t ∈ print .latex S e, tokOK t := by
  have h := POK_all ⟨.latex, S⟩ rfl _ e (Nat.lt_succ_self _) he
  exact POK_toks h 1

end Esm.Document.Math.Latex
