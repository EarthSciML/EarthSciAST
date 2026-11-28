import Esm.Document.Math.LexLatex

/-!
# The LaTeX printer writes only LaTeX tokens

Every token of a printed well-formed expression is a LaTeX token (`tokOK`), so the
LaTeX lexer lemma applies to the printer's output.
-/

namespace Esm.Document.Math.Latex

open Esm.Document Esm.Document.Math

/-- Every `\times` is followed, within the list, by a token that is not a number: the printer
writes `\times` between the bound pairs of a region (before a bracket) and after the
`\nabla` of a curl (before an operand that does not start with a number). -/
def TL : List Tok → Prop
  | [] => True
  | t :: r => (t = .kw .times → ∃ u r', r = u :: r' ∧ startsNum [u] = false) ∧ TL r

/-- What the printer writes: LaTeX tokens, and `\times` before a token that is not a number. -/
def AllOK (ts : List Tok) : Prop := (∀ t ∈ ts, tokOK t ∨ t = .kw .times) ∧ TL ts

theorem allOK_nil : AllOK [] := ⟨fun _ h => (by cases h), trivial⟩

theorem TL_append : ∀ {a b : List Tok}, TL a → TL b → TL (a ++ b)
  | [], _, _, hb => hb
  | t :: a, b, ha, hb => by
    refine ⟨fun e => ?_, TL_append ha.2 hb⟩
    obtain ⟨u, r', rfl, hu⟩ := ha.1 e
    exact ⟨u, r' ++ b, rfl, hu⟩

theorem TL_TN : ∀ (ts : List Tok), TL ts → TN ts
  | [], _ => trivial
  | [_], _ => trivial
  | t :: u :: r, h => by
    refine ⟨fun e => ?_, TL_TN (u :: r) h.2⟩
    obtain ⟨u', r', hr, hu⟩ := h.1 e
    simp only [List.cons.injEq] at hr
    rw [hr.1]; exact hu

theorem tok_ne_times {t : Tok} (h : tokOK t) : t ≠ .kw .times := by
  rintro rfl; have h' : kwOK .times = true := h; exact absurd h' (by decide)

theorem allOK_app {a b : List Tok} (ha : AllOK a) (hb : AllOK b) : AllOK (a ++ b) :=
  ⟨fun t ht => (List.mem_append.1 ht).elim (ha.1 t) (hb.1 t), TL_append ha.2 hb.2⟩

theorem allOK_append2 {a b : List Tok} (h : AllOK a ∧ AllOK b) : AllOK (a ++ b) := allOK_app h.1 h.2

theorem allOK_cons' {t : Tok} {r : List Tok} (ht : tokOK t) (hr : AllOK r) : AllOK (t :: r) :=
  ⟨fun u hu => by
    simp only [List.mem_cons] at hu
    rcases hu with rfl | hu
    · exact Or.inl ht
    · exact hr.1 u hu, ⟨fun e => absurd e (tok_ne_times ht), hr.2⟩⟩

theorem allOK_cons2 {t : Tok} {r : List Tok} (h : tokOK t ∧ AllOK r) : AllOK (t :: r) := allOK_cons' h.1 h.2

theorem allOK_times {r : List Tok} (hr : AllOK (.kw .lbk :: r)) : AllOK (.kw .times :: .kw .lbk :: r) :=
  ⟨fun u hu => by
    simp only [List.mem_cons] at hu
    rcases hu with rfl | hu
    · exact Or.inr rfl
    · exact hr.1 u (by simp only [List.mem_cons]; exact hu), ⟨fun _ => ⟨_, r, rfl, rfl⟩, hr.2⟩⟩

/-- `\times` before a list that does not start with a number. -/
theorem allOK_times_tok {u : Tok} {r : List Tok} (hr : AllOK (u :: r)) (hu : startsNum [u] = false) :
    AllOK (.kw .times :: u :: r) :=
  ⟨fun v hv => by
    simp only [List.mem_cons] at hv
    rcases hv with rfl | hv
    · exact Or.inr rfl
    · exact hr.1 v (by simp only [List.mem_cons]; exact hv), ⟨fun _ => ⟨u, r, rfl, hu⟩, hr.2⟩⟩

theorem allOK_sepBy (sep : List Tok) (hs : AllOK sep) :
    ∀ (xs : List (List Tok)), (∀ x ∈ xs, AllOK x) → AllOK (sepBy sep xs)
  | [], _ => allOK_nil
  | [x], h => h x (by simp)
  | x :: y :: ys, h => by
    rw [sepBy_cons2]
    exact allOK_append2 ⟨allOK_append2 ⟨h x (by simp), hs⟩,
      allOK_sepBy sep hs (y :: ys) (fun z hz => h z (by simp [hz]))⟩

theorem allOK_flatMap {α : Type} (f : α → List Tok) :
    ∀ (xs : List α), (∀ x ∈ xs, AllOK (f x)) → AllOK (xs.flatMap f)
  | [], _ => allOK_nil
  | x :: xs, h => by
    rw [List.flatMap_cons]
    exact allOK_append2 ⟨h x (by simp), allOK_flatMap f xs (fun z hz => h z (by simp [hz]))⟩

theorem allOK_map {α : Type} (f : α → List Tok) (xs : List α) (h : ∀ x ∈ xs, AllOK (f x)) :
    ∀ y ∈ xs.map f, AllOK y := by
  intro y hy; obtain ⟨x, hx, rfl⟩ := List.mem_map.1 hy; exact h x hx

theorem tokOK_num0 : tokOK (.num (.int 0)) := by
  show JNum.InInt64 0; unfold JNum.InInt64; decide
theorem tokOK_num10 : tokOK (.num (.int 10)) := by
  show JNum.InInt64 10; unfold JNum.InInt64; decide

/-- Close a goal `AllOK [fixed tokens and pieces]` from the pieces in the context. -/
macro "aok" : tactic => `(tactic| (
  try simp only [List.cons_append, List.nil_append, List.append_assoc, List.append_nil]
  repeat' (first
    | assumption
    | exact allOK_nil
    | apply allOK_times
    | apply allOK_app
    | apply allOK_cons'
    | exact tokOK_num0
    | exact tokOK_num10
    | exact ⟨rfl, by decide⟩
    | exact ⟨by decide, by decide⟩
    | exact True.intro
    | rfl
    | decide)))

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

theorem balOK_escK (s : List Char) : balOK (escK s) = true := by
  simp [balOK, rawB_escK s []]

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
  · rename_i hs; exact allOK_cons2 ⟨tokOK_baseTok g hs, allOK_nil⟩
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
        exact allOK_cons2 ⟨hr, allOK_nil⟩
      · exact allOK_cons2 ⟨trivial, allOK_nil⟩

theorem allOK_nameToks (c : Ctx) (hc : c.sf = .latex) (s : String) : AllOK (nameToks c s) := by
  unfold nameToks
  split
  · exact allOK_cons2 ⟨trivial, allOK_nil⟩
  · rw [hc]
    have hs : AllOK [.kw .sdot] := allOK_cons2 ⟨(rfl : kwOK .sdot = true), allOK_nil⟩
    exact allOK_sepBy _ hs _ (allOK_map _ _ (fun g _ => allOK_segToks g))

/-! ## JSON -/

/-- LaTeX sets no set name upright: a set prints as a name. -/
theorem setToks_latex (c : Ctx) (hc : c.sf = .latex) (s : String) : setToks c s = nameToks c s := by
  have hg : setSegToks c.sf = segToks c.sf := by funext g; simp [setSegToks, upSet, hc]
  simp only [setToks, nameToks, hg]

theorem allOK_setToks (c : Ctx) (hc : c.sf = .latex) (s : String) : AllOK (setToks c s) := by
  rw [setToks_latex c hc s]; exact allOK_nameToks c hc s

mutual
theorem allOK_json : ∀ v : Json, jwf v = true → AllOK (jsonToks v)
  | .null, _ => by
    simp only [jsonToks]; exact allOK_cons2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "null")), allOK_nil⟩
  | .bool true, _ => by
    simp only [jsonToks]; exact allOK_cons2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "true")), allOK_nil⟩
  | .bool false, _ => by
    simp only [jsonToks]; exact allOK_cons2 ⟨(⟨rfl, by decide⟩ : tokOK (.word "false")), allOK_nil⟩
  | .num n, h => by
    simp only [jsonToks]; exact allOK_cons2 ⟨((numOK_iff n).1 h : tokOK (.num n)), allOK_nil⟩
  | .str s, _ => by
    simp only [jsonToks]; exact allOK_cons2 ⟨(trivial : tokOK (.jstr s)), allOK_nil⟩
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
    exact allOK_cons2 ⟨(trivial : tokOK (.jstr k)), allOK_cons2 ⟨(rfl : kwOK .colon = true), h1⟩⟩
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
    refine allOK_append2 ⟨h x (by simp), allOK_flatMap _ xs (fun y hy => ?_)⟩
    have hy' := h y (by simp [hy])
    split
    · exact allOK_cons2 ⟨(rfl : kwOK .cdot = true), hy'⟩
    · exact hy'

theorem allOK_callToks (head : List Tok) (hh : AllOK head) (args : List (List Tok))
    (ha : ∀ x ∈ args, AllOK x) : AllOK (callToks .latex head args) := by
  have hs := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) args ha
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

theorem allOK_numToks (ns : List JNum) (h : ∀ n ∈ ns, numOK n = true) : ∀ x ∈ numToks ns, AllOK x := by
  intro x hx
  obtain ⟨n, hn, rfl⟩ := List.mem_map.1 hx
  exact allOK_cons2 ⟨((numOK_iff n).1 (h n hn) : tokOK (.num n)), allOK_nil⟩

theorem allOK_arr (af : AForm) (h : AOK af) : AllOK (arrToks .latex af) := by
  cases af with
  | col ns =>
    have hS := allOK_sepBy [.kw .nl] (allOK_cons2 ⟨(rfl : kwOK .nl = true), allOK_nil⟩) _
      (allOK_numToks ns h.2)
    simp only [arrToks]; aok
  | mat rs =>
    have hS := allOK_sepBy [.kw .nl] (allOK_cons2 ⟨(rfl : kwOK .nl = true), allOK_nil⟩) _
      (allOK_map _ rs (fun r hr => allOK_sepBy [.kw .amp] (allOK_cons2 ⟨(rfl : kwOK .amp = true), allOK_nil⟩) _
        (allOK_numToks r (h.2.2.1 r hr))))
    simp only [arrToks]
    split
    · rename_i hw
      have hb : tokOK (.kw (.barrC (rs.headD []).length)) := by
        show decide (0 < (rs.headD []).length) = true
        exact decide_eq_true (by unfold bmatCols at hw; omega)
      aok
    · aok

/-! ## Reductions -/

theorem subToks_split (c : Ctx) (P : Json → Out) (F : FaqForm) :
    subToks c P F = (if c.sf = .latex then subToksL c P F else subToksT c P F) := by
  unfold subToks; cases c.sf <;> rfl

theorem tokOK_num1 : tokOK (.num (.int 1)) := by
  show JNum.InInt64 1; unfold JNum.InInt64; decide

theorem faqSubs_rng {F : FaqForm} {kv : String × Json} (hkv : kv ∈ F.ranges) {a b : Json}
    (h : kv.2 = .arr [a, b]) : a ∈ faqSubs F ∧ b ∈ faqSubs F := by
  constructor <;>
  · simp only [faqSubs, List.mem_append, List.mem_flatMap]
    right; exact ⟨kv, hkv, by rw [h]; simp⟩

theorem allOK_faqOut (c : Ctx) (hc : c.sf = .latex) (F : FaqForm) (P : Json → Out)
    (hQ : ∀ x ∈ faqSubs F, AllOK (P x).toks) :
    AllOK (faqOut c P F).toks ∧ AllOK (faqOut c P F).crow := by
  have hAt : ∀ x ∈ faqSubs F, ∀ L, AllOK ((P x).at .latex L) := fun x hx L => allOK_at rfl _ (hQ x hx) L
  have hRow : ∀ kv ∈ F.ranges, AllOK (rowToks c P kv) := by
    intro kv hkv
    unfold rowToks
    split
    · rename_i a b he
      obtain ⟨ha, hb⟩ := faqSubs_rng hkv he
      have hA := hAt a ha 4; have hB := hAt b hb 4
      have hN := allOK_nameToks c hc kv.1
      rw [hc]; aok
    · have hN := allOK_nameToks c hc kv.1
      have hS := allOK_setToks c hc ‹String›
      aok
    · rename_i s ps _
      have hN := allOK_nameToks c hc kv.1
      have hS := allOK_setToks c hc s
      have hL := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map (fun (p : Json) => match p with | .str q => nameToks c q | _ => []) ps (fun p _ => by
          split
          · exact allOK_nameToks c hc _
          · exact allOK_nil))
      aok
    · exact allOK_nil
  have hHead : AllOK (headToks .latex F) := by
    have hk : tokOK (.kw F.red.kw) := by cases F.red <;> rfl
    simp only [headToks]; split <;> aok
  have hSub : AllOK (subToks c P F) := by
    rw [subToks_split, iteT hc]; unfold subToksL
    have hRows : ∀ x ∈ subRows c P F, AllOK x := by
      intro x hx
      unfold subRows at hx
      rcases List.mem_append.1 hx with hx | hx
      · obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hx
        exact hRow kv (List.mem_filter.1 hkv).1
      · split at hx
        · rename_i y hy
          simp only [List.mem_singleton] at hx; subst hx
          rw [hc]; exact hAt y (by simp [faqSubs, hy]) 1
        · cases hx
    split
    · rename_i k a b hr _ _
      have hm : (k, Json.arr [a, b]) ∈ F.ranges := redRanges_mem (by rw [hr]; simp)
      obtain ⟨ha, hb⟩ := faqSubs_rng hm rfl
      have hA := hAt a ha 4; have hB := hAt b hb 1
      have hN := allOK_nameToks c hc k
      rw [hc]; aok
    · split
      · exact allOK_nil
      · rename_i r hr; have := hRows r (by rw [hr]; simp); aok
      · have hS := allOK_sepBy [.kw .nl] (allOK_cons2 ⟨(rfl : kwOK .nl = true), allOK_nil⟩) _ hRows
        aok
  have hBody := hAt F.expr (by simp [faqSubs]) 5
  have hEnt : ∀ x ∈ F.out.map (entryToks c P F), AllOK x := by
    refine allOK_map _ _ (fun j _ => ?_)
    unfold entryToks
    split
    · split
      · rename_i v hv; exact hRow _ (look_mem hv)
      · exact allOK_nameToks c hc _
    · exact allOK_cons2 ⟨tokOK_num1, allOK_nil⟩
  have hE := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _ hEnt
  have hSup : AllOK (supT c F) := by
    unfold supT; split
    · exact allOK_nil
    · have hL := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map _ F.sup (fun n _ => allOK_nameToks c hc n))
      unfold supToks; rw [hc]; aok
  have hIf : AllOK (if F.out = [] then supT c F else []) := by
    split
    · exact hSup
    · exact allOK_nil
  unfold faqOut redToks
  rw [hc]
  split <;> (simp only [mkOut]; constructor <;> aok)

/-! ## Block assembly -/

theorem mem_mkSubs_value {M : MkForm} {v : Json} (h : v ∈ M.values) : v ∈ mkSubs M := by
  simp [mkSubs, h]

theorem mem_mkSubs_bound {M : MkForm} {r : List (Json × Json)} (hr : r ∈ M.regions) {p : Json × Json}
    (hp : p ∈ r) : p.1 ∈ mkSubs M ∧ p.2 ∈ mkSubs M := by
  constructor <;>
  · simp only [mkSubs, List.mem_append, List.mem_flatMap]
    right; exact ⟨r, hr, p, hp, by simp⟩

theorem allOK_mkOutT (c : Ctx) (hc : c.sf = .latex) (M : MkForm) (P : Json → Out)
    (hQ : ∀ x ∈ mkSubs M, AllOK (P x).toks) :
    AllOK (mkOutT c P M).toks ∧ AllOK (mkOutT c P M).crow := by
  have hAt : ∀ x ∈ mkSubs M, ∀ L, AllOK ((P x).at c.sf L) := fun x hx L => by
    rw [hc]; exact allOK_at rfl _ (hQ x hx) L
  have hPair : ∀ r ∈ M.regions, ∀ p ∈ r, AllOK (pairToks c P p) := by
    intro r hr p hp
    obtain ⟨h1, h2⟩ := mem_mkSubs_bound hr hp
    have hA := hAt _ h1 1; have hB := hAt _ h2 1
    simp only [pairToks]; aok
  have hReg : ∀ r ∈ M.regions, AllOK (regToks c P r) := by
    intro r hr
    cases r with
    | nil => exact allOK_nil
    | cons p ps =>
      have hp := hPair _ hr p (by simp)
      have hps := allOK_flatMap (fun q => .kw .times :: .kw .lbk :: pairToks c P q ++ [.kw .rbk]) ps (fun q hq => by
        have := hPair _ hr q (by simp [hq]); aok)
      simp only [regToks]; aok
  have hRows : ∀ x ∈ (M.values.zip M.regions).map (mkRow c P), AllOK x := by
    refine allOK_map _ _ (fun vr hvr => ?_)
    have hv := hAt vr.1 (mem_mkSubs_value (List.of_mem_zip hvr).1) 1
    have hr := hReg vr.2 (List.of_mem_zip hvr).2
    simp only [mkRow]; rw [show cellSep c.sf = .amp by rw [hc]; rfl]; aok
  have hS := allOK_sepBy [.kw (rowSep c.sf)] (allOK_cons2 ⟨(by rw [hc]; rfl : kwOK (rowSep c.sf) = true),
    allOK_nil⟩) _ hRows
  have hSub : AllOK (mkSub c M.out) := by
    unfold mkSub; split
    · exact allOK_nil
    · have hL := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map _ M.out (fun n _ => allOK_nameToks c hc n))
      rw [hc]; aok
  unfold mkOutT
  rw [hc] at hS ⊢
  simp only [mkOut]; constructor <;> aok

/-! ## The induction -/

theorem tokOK_units (u : String) (hu : unitsOK .latex u = true) : tokOK (.units (factorsOf u)) := by
  simp only [unitsOK, Bool.and_eq_true, beq_iff_eq] at hu
  refine ⟨?_, hu.2.2⟩
  unfold unitsOfRaw; rw [String.toList_ofList]; exact hu.2.1

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
      fun k hk xs hx => allOK_sepBy [Tok.kw k] (allOK_cons2 ⟨(show tokOK (Tok.kw k) from hk), allOK_nil⟩) xs hx
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
      have hS := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map _ is (fun x hx => POK_toks (IH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx)) 1))
      rw [hpr]; simp only [mkOut, subList]; constructor <;> aok
    | idxBr o base is ho hne hb hi hpr =>
      simp only [hc] at hpr
      have hB := POK_toks (IH base (sizeOf_node_lt (by simp)) hb) 10
      have hS := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
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
      have hS := allOK_callToks [.kw k] (allOK_cons2 ⟨hk, allOK_nil⟩) _
        (allOK_map _ xs (fun x hm => POK_toks (IH x (sizeOf_node_lt hm) (hx x hm)) 1))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | nab o n a ho ha hpr =>
      simp only [hc] at hpr
      have hA := POK_toks (IH a (sizeOf_node_lt (by simp)) ha) 9
      have hT := (IH a (sizeOf_node_lt (by simp)) ha).1
      have hN : AllOK (nabHead .latex n ++ nabArg .latex n (pr c a)) := by
        unfold nabArg
        by_cases hN6 : startsNabla (pr c a).toks = true ∧ 6 ≤ (pr c a).lvl
        · rw [ite_eq_left hN6]
          obtain ⟨tr, htr⟩ : ∃ tr, (pr c a).toks = .kw .nabla :: tr := by
            have h1 := hN6.1
            cases ht : (pr c a).toks with
            | nil => rw [ht] at h1; simp [startsNabla] at h1
            | cons u us =>
              rw [ht] at h1
              cases u with
              | kw k => cases k <;> simp [startsNabla] at h1 ⊢
              | _ => simp [startsNabla] at h1
          rw [htr] at hT ⊢
          cases n with
          | curl => exact allOK_cons' (show kwOK .nabla = true from rfl) (allOK_times_tok hT rfl)
          | grad => simp only [nabHead]; aok
          | div => simp only [nabHead]; aok
          | lap => simp only [nabHead]; aok
        · rw [ite_eq_right hN6]
          cases n with
          | curl =>
            simp only [nabHead, nabArg9, true_and]
            by_cases hs : startsNum ((pr c a).at .latex 9) = true
            · rw [ite_eq_left hs]
              have hG := allOK_grp (sf := .latex) rfl hA
              simp only [grp, ↓reduceIte] at hG ⊢
              exact allOK_cons' (show kwOK .nabla = true from rfl) (allOK_times_tok hG rfl)
            · rw [ite_eq_right hs]
              have hh := headOK_at (M_of_isE c a ha) 9
              rw [hc] at hh
              obtain ⟨u, r, he⟩ : ∃ u r, (pr c a).at .latex 9 = u :: r := by
                cases h : (pr c a).at .latex 9 with
                | nil => rw [h] at hh; exact absurd hh (by simp [HeadOK])
                | cons u r => exact ⟨u, r, rfl⟩
              rw [he] at hA hs ⊢
              have hu : startsNum [u] = false := by cases u <;> simp_all [startsNum]
              exact allOK_cons' (show kwOK .nabla = true from rfl) (allOK_times_tok hA hu)
          | grad => simp only [nabHead, nabArg9, reduceCtorEq, false_and, ↓reduceIte]; aok
          | div => simp only [nabHead, nabArg9, reduceCtorEq, false_and, ↓reduceIte]; aok
          | lap => simp only [nabHead, nabArg9, reduceCtorEq, false_and, ↓reduceIte]; aok
      rw [hpr]; simp only [mkOut]
      refine ⟨hN, allOK_app hN ?_⟩
      aok
    | call o xs ho hx hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn o] (allOK_cons2 ⟨trivial, allOK_nil⟩) _
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
      have hA := POK_toks (IH a (sizeOf_pNode_lt a _) ha) 1
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
      have hb := tokOK_units u (by rw [← hc]; exact hu)
      have hn : tokOK (.num k) := hk
      have h2 : AllOK [.num k, .units (factorsOf u)] := allOK_cons2 ⟨hn, allOK_cons2 ⟨hb, allOK_nil⟩⟩
      rw [hpr]; simp only [mkOut, qtyToks]
      exact ⟨h2, allOK_append2 ⟨h2, allOK_cons2 ⟨rfl, allOK_cons2 ⟨⟨rfl, by decide⟩, allOK_nil⟩⟩⟩⟩
    | arr xs af haf hpr =>
      simp only [hc] at hpr
      have hA := allOK_arr af (arrForm_spec haf).2
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | arrU u xs af haf hu hpr =>
      simp only [hc] at hpr
      have hA := allOK_arr af (arrForm_spec haf).2
      have hb := tokOK_units u (by rw [← hc]; exact hu)
      have h2 : AllOK (arrToks .latex af ++ [.units (factorsOf u)]) :=
        allOK_append2 ⟨hA, allOK_cons2 ⟨hb, allOK_nil⟩⟩
      rw [hpr]; simp only [mkOut, unitToks]
      exact ⟨h2, allOK_append2 ⟨h2, allOK_cons2 ⟨rfl, allOK_cons2 ⟨⟨rfl, by decide⟩, allOK_nil⟩⟩⟩⟩
    | faq kvs F hF hok P hP hpr =>
      rw [hpr]
      exact allOK_faqOut c hc F P (fun x hx => by
        rw [hP x hx]; exact (IH x (faqSubs_lt hF hx) (faqSubs_isE hok x hx)).1)
    | mk kvs M hM hok P hP hpr =>
      rw [hpr]
      exact allOK_mkOutT c hc M P (fun x hx => by
        rw [hP x hx]; exact (IH x (mkSubs_lt hM hx) (Math.mkSubs_isE hok x hx)).1)
    | tbare m hm _ hpr =>
      have ho : tokOK (.opn m) := trivial
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | tpos m bs ps hm hsb hb hps hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn m] (allOK_cons2 ⟨trivial, allOK_nil⟩) _
        (allOK_map _ ps (fun p _ => allOK_lookup bs (fun v => (pr c v).at .latex 4)
          (fun kv hkv => POK_toks (IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) 4) p))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | tnamed m bs hm _ hb hps hne hk hkn hpr =>
      simp only [hc] at hpr
      have hS := allOK_callToks [.opn m] (allOK_cons2 ⟨trivial, allOK_nil⟩) _
        (allOK_map (fun kv => nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at .latex 4) bs (fun kv hkv => by
          have hN := allOK_nameToks c hc kv.1
          have hV := POK_toks (IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) 4
          aok))
      rw [hpr]; simp only [mkOut]; constructor <;> aok
    | openop kvs o as hop hargs hsk hx hf hcore hopn htp _ hkey hsz hszf hpr =>
      simp only [hc] at hpr
      have hA := hsep .comma rfl _ (allOK_map _ as (fun x hm => POK_toks (IH x (hsz x hm) (hx x hm)) 4))
      have hF := hsep .comma rfl _ (allOK_map (fun kv => keyToks .latex kv.1 ++ .kw .eq ::
          (if mathField o kv then (pr c kv.2).at .latex 4 else jsonVal .latex kv.2)) (fieldsOf kvs) (fun kv hkv => by
          have hK : tokOK (.rm (String.ofList (escK kv.1.toList))) := by
            show balOK (String.ofList (escK kv.1.toList)).toList = true
            rw [String.toList_ofList]; exact balOK_escK _
          have hV : AllOK (if mathField o kv = true then (pr c kv.2).at .latex 4 else jsonVal .latex kv.2) := by
            split
            · rename_i hv; exact POK_toks (IH kv.2 (hszf kv hkv) (mathField_isE hv)) 4
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

/-- The LaTeX printer writes LaTeX tokens, and `\times` only before a bracket. -/
theorem allOK_pa (S : Sym) (e : Json) (he : isE e = true) (L : Nat) :
    AllOK ((pr ⟨.latex, S⟩ e).at .latex L) := by
  have h := POK_all ⟨.latex, S⟩ rfl _ e (Nat.lt_succ_self _) he
  exact POK_toks h L

/-- A range row's tokens are LaTeX tokens. -/
theorem allOK_rowToks (c : Ctx) (hc : c.sf = .latex) (P : Json → Out) (kv : String × Json)
    (hQ : ∀ a b, kv.2 = .arr [a, b] → AllOK ((P a).at .latex 4) ∧ AllOK ((P b).at .latex 4)) :
    AllOK (rowToks c P kv) := by
  unfold rowToks
  split
  · rename_i a b he
    obtain ⟨hA, hB⟩ := hQ a b he
    have hN := allOK_nameToks c hc kv.1
    rw [hc]; aok
  · have hN := allOK_nameToks c hc kv.1
    have hS := allOK_setToks c hc ‹String›
    aok
  · rename_i s ps _
    have hN := allOK_nameToks c hc kv.1
    have hS := allOK_setToks c hc s
    have hL := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
      (allOK_map (fun (p : Json) => match p with | .str q => nameToks c q | _ => []) ps (fun p _ => by
        split
        · exact allOK_nameToks c hc _
        · exact allOK_nil))
    aok
  · exact allOK_nil

theorem print_allOK (S : Sym) (e : Json) (he : isE e = true) : AllOK (print .latex S e) := by
  unfold print
  split
  · rename_i q rows _
    split
    · rename_i hok
      unfold liftOK at hok
      simp only [Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff] at hok
      obtain ⟨⟨⟨-, hq⟩, hrows⟩, -⟩ := hok
      have hP := allOK_pa S q hq 1
      have hT := allOK_sepBy [.kw .comma] (allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩) _
        (allOK_map (rowToks ⟨.latex, S⟩ (pr ⟨.latex, S⟩)) rows (fun kv hkv => by
          have hc := List.all_eq_true.1 hrows kv hkv
          refine allOK_rowToks _ rfl _ kv (fun a b hab => ?_)
          rw [hab] at hc
          simp only [Bool.and_eq_true] at hc
          exact ⟨allOK_pa S a hc.2.1 4, allOK_pa S b hc.2.2 4⟩))
      unfold pa defRowsToks
      have hC : AllOK [Tok.kw .comma] := allOK_cons2 ⟨(rfl : kwOK .comma = true), allOK_nil⟩
      aok
    · exact allOK_pa S e he 1
  · exact allOK_pa S e he 1

/-- Every token the LaTeX printer writes for a well-formed expression is a LaTeX token or a
`\times` the lexer lemma allows. -/
theorem print_tokL (S : Sym) (e : Json) (he : isE e = true) : TokL (print .latex S e) :=
  ⟨(print_allOK S e he).1, TL_TN _ (print_allOK S e he).2⟩

/-- The same for an expression printed whole as an expression (`pa`), an `==` at its top
included. -/
theorem pa_tokL (S : Sym) (e : Json) (he : isE e = true) : TokL (pa ⟨.latex, S⟩ 1 e) :=
  ⟨(allOK_pa S e he 1).1, TL_TN _ (allOK_pa S e he 1).2⟩

end Esm.Document.Math.Latex
