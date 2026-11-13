import Esm.Document.Math.Escape

/-!
# Round trip, case by case: open operators
-/

namespace Esm.Document.Math

open Esm.Document

/-- A field value as JSON tokens starts with a token the parser takes for JSON. -/
theorem jsonVal_head (sf : Sf) (v : Json) (hv : jwf v = true) (hn : isE v = false) :
    ∃ t r, jsonVal sf v = t :: r ∧
      (sf = .latex → ∀ X, jsonStart (t :: X) = true) ∧ (sf = .typst → t = .code v ∧ r = []) := by
  cases sf with
  | typst => exact ⟨_, _, rfl, by simp, fun _ => ⟨rfl, rfl⟩⟩
  | latex =>
    cases v with
    | null => exact ⟨_, _, rfl, fun _ _ => rfl, by simp⟩
    | bool b => cases b <;> exact ⟨_, _, rfl, fun _ _ => rfl, by simp⟩
    | num n => simp [isE, jwf] at hn hv; rw [hv] at hn; cases hn
    | str s => exact ⟨_, _, rfl, fun _ _ => rfl, by simp⟩
    | arr xs => exact ⟨.kw .lbk, jsonItems xs ++ [.kw .rbk], by simp [jsonVal, jsonToks], fun _ _ => rfl, by simp⟩
    | obj kvs => exact ⟨.kw .lb, jsonEntries kvs ++ [.kw .rb], by simp [jsonVal, jsonToks], fun _ _ => rfl, by simp⟩


/-- A field value as printed: an expression at level 4, or JSON. -/
def valToks (c : Ctx) (v : Json) : List Tok :=
  if isE v then (pr c v).at c.sf 4 else jsonVal c.sf v

/-- A field as printed: key, `=`, value. -/
def fieldToks (c : Ctx) (kv : String × Json) : List Tok :=
  keyToks c.sf kv.1 ++ .kw .eq :: valToks c kv.2

theorem length_keyToks (sf : Sf) (k : String) : (keyToks sf k).length = 1 := by
  cases sf <;> rfl

theorem keyOf_keyToks (c : Ctx) (k : String) (r : List Tok) :
    keyOf c (keyToks c.sf k ++ .kw .eq :: r) = some (k, r) := by
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · have : keyToks c.sf k = [.rm (String.ofList (escT k.toList))] := by simp [keyToks, hsf]
    rw [this]; unfold keyOf; split
    all_goals try (exfalso; simp_all; done)
    rename_i raw r' _ heq
    simp only [List.cons_append, List.nil_append, List.cons.injEq, Tok.rm.injEq] at heq
    obtain ⟨rfl, -, rfl⟩ := heq; simp [String.toList_ofList, unescT_escT]
  · have : keyToks c.sf k = [.ups [(k, "")]] := by simp [keyToks, hsf]
    rw [this]; unfold keyOf; split
    all_goals try (exfalso; simp_all; done)
    rename_i k' r' _ heq
    simp only [List.cons_append, List.nil_append, List.cons.injEq, Tok.ups.injEq,
      Prod.mk.injEq, and_true, true_and] at heq
    obtain ⟨rfl, rfl⟩ := heq; rfl

theorem not_jsonStart {c : Ctx} {t : Tok} {r : List Tok} (h : HeadOK c (t :: r)) :
    jsonStart (t :: r) = false ∧
      ∀ v, t ≠ .code v := by
  obtain ⟨-, -, -, hw, -, hs⟩ := h
  rcases hs with hs | rfl
  · cases t with
    | kw k => cases k <;> first | exact absurd hs Bool.false_ne_true | simp [jsonStart]
    | word w => exact absurd rfl (hw w)
    | _ => first | exact absurd hs Bool.false_ne_true | simp [jsonStart]
  · simp [jsonStart]

theorem pVal_latex {c : Ctx} (h : c.sf = .latex) (f : Nat) (r : List Tok) :
    pVal c (f + 1) r = if jsonStart r then pJson f r else pAdd c f r := by
  rw [pVal.eq_def]; simp only; rw [h]

theorem pVal_code {c : Ctx} (h : c.sf = .typst) (f : Nat) (v : Json) (r : List Tok) :
    pVal c (f + 1) (.code v :: r) = some (v, r) := by
  rw [pVal.eq_def]; simp only; rw [h]

theorem pVal_typst {c : Ctx} (h : c.sf = .typst) (f : Nat) (t : Tok) (r : List Tok)
    (ht : ∀ v, t ≠ .code v) : pVal c (f + 1) (t :: r) = pAdd c f (t :: r) := by
  rw [pVal.eq_def]; simp only; rw [h]; simp only
  split
  · rename_i heq; simp only [List.cons.injEq] at heq; exact absurd heq.1 (ht _)
  · rfl

theorem pVal_val (c : Ctx) (v : Json) (hv : jwf v = true) (hM : isE v = true → M c v)
    (X : List Tok) (hX : Fol c.sf 4 X) (f : Nat) (hf : need 4 (valToks c v).length ≤ f) :
    pVal c (f + 1) (valToks c v ++ X) = some (v, X) := by
  by_cases he : isE v = true
  · have hm := hM he
    simp only [valToks, he, ↓reduceIte] at hf ⊢
    have hp := PL_at hm 4 (by omega) (by omega) X hX f hf
    rw [pLvl4] at hp
    have hh := headOK_at hm 4
    revert hp hh
    generalize (pr c v).at c.sf 4 = ts
    intro hp hh
    match ts, hh with
    | t :: r, hh =>
      obtain ⟨hj, hc⟩ := not_jsonStart hh
      simp only [List.cons_append] at hp ⊢
      obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
      · rw [pVal_latex hsf, show jsonStart (t :: (r ++ X)) = jsonStart (t :: r) from rfl, hj]
        exact hp
      · rw [pVal_typst hsf _ _ _ hc]; exact hp
  · have hn : isE v = false := by simpa using he
    simp only [valToks, hn, Bool.false_eq_true, ↓reduceIte] at hf ⊢
    obtain ⟨t, r, ht, hl, hty⟩ := jsonVal_head c.sf v hv hn
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · have hj : jsonVal c.sf v = jsonToks v := by simp [jsonVal, hsf]
      have hpj := pJson_toks v f X (by rw [hj] at hf; unfold need at hf; omega)
      rw [hj] at ht ⊢
      rw [ht] at hpj ⊢
      simp only [List.cons_append] at hpj ⊢
      rw [pVal_latex hsf, hl hsf]; exact hpj
    · obtain ⟨rfl, rfl⟩ := hty hsf
      rw [ht]; exact pVal_code hsf f v X

theorem pFields_list (c : Ctx) (rest : List Tok) :
    ∀ (fs : List (String × Json)), fs ≠ [] → (∀ kv ∈ fs, jwf kv.2 = true) →
      (∀ kv ∈ fs, isE kv.2 = true → M c kv.2) → ∀ f,
      need 1 (sepBy [.kw .comma] (fs.map (fieldToks c))).length + 1 ≤ f →
      pFields c f (sepBy [.kw .comma] (fs.map (fieldToks c)) ++ .kw .rp :: rest) =
        some (fs, .kw .rp :: rest)
  | [], hne, _, _, _, _ => absurd rfl hne
  | [kv], _, hj, hM, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
    simp only [List.map_cons, List.map_nil, sepBy, fieldToks, List.length_append,
      List.length_cons, length_keyToks] at hf ⊢
    have hv := pVal_val c kv.2 (hj kv (by simp)) (hM kv (by simp)) (.kw .rp :: rest)
      (fol_kw _ _ _ _ (by simp [conts, atomStart])) g (by unfold need at hf ⊢; omega)
    rw [pFields.eq_def]; simp only [List.append_assoc, List.cons_append]
    rw [keyOf_keyToks]; simp only
    rw [hv]
  | kv :: kv2 :: kvs, _, hj, hM, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by unfold need at hf; omega⟩
    have hft : fieldToks c kv = keyToks c.sf kv.1 ++ .kw .eq :: valToks c kv.2 := rfl
    simp only [List.map_cons, sepBy_cons2] at hf ⊢
    rw [hft] at hf ⊢
    simp only [List.length_append, List.length_cons, length_keyToks] at hf
    have ih := pFields_list c rest (kv2 :: kvs) (by simp) (fun z hz => hj z (by simp [hz]))
      (fun z hz => hM z (by simp [hz])) (g + 1) (by simp only [List.map_cons]; unfold need at hf ⊢; omega)
    simp only [List.map_cons] at ih
    have hv := pVal_val c kv.2 (hj kv (by simp)) (hM kv (by simp))
      (.kw .comma :: (sepBy [.kw .comma] (fieldToks c kv2 :: kvs.map (fieldToks c)) ++ .kw .rp :: rest))
      (fol_kw _ _ _ _ (by simp [conts, atomStart])) g (by unfold need at hf ⊢; omega)
    rw [pFields.eq_def]; simp only [List.append_assoc, List.cons_append, List.nil_append]
    rw [keyOf_keyToks]; simp only
    rw [hv]; simp only
    rw [ih]; simp

theorem allNamed_pos : ∀ (xs : List Json), xs ≠ [] → allNamed (xs.map CallArg.pos) = none
  | [], h => absurd rfl h
  | _ :: _, _ => rfl

theorem callOps_core {n : String} (h : coreOps.contains n = false) : callOps.contains n = false := by
  cases hc : callOps.contains n
  · rfl
  · exfalso; simp only [callOps, List.contains_cons, List.contains_nil, Bool.or_false,
      Bool.or_eq_true, beq_iff_eq] at hc
    rcases hc with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> exact absurd h (by decide)

theorem M_openop (c : Ctx) (kvs : List (String × Json)) (o : String) (as : List Json)
    (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
    (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, M c x)
    (hj : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true)
    (hfM : ∀ kv ∈ fieldsOf kvs, isE kv.2 = true → M c kv.2)
    (hcore : coreOps.contains o = false) (htp : tparams c.S o = none)
    (hrem : removedOps.contains o = false)
    (hpr : pr c (.obj kvs) = mkOut c.sf 10 (openToks c.sf o (as.map fun x => (pr c x).at c.sf 4)
        ((fieldsOf kvs).map (fieldToks c)))) :
    M c (.obj kvs) := by
  have hmk := mkNode_fieldsOf hs hop hargs
  have hco := callOps_core hcore
  have hneg : o ≠ "neg" := by rintro rfl; exact absurd hcore (by decide)
  have hpow : o ≠ "pow" := by rintro rfl; exact absurd hcore (by decide)
  have hD : o ≠ "D" := by rintro rfl; exact absurd hcore (by decide)
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      rw [hpr] at hf ⊢
      simp only [mkOut] at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by
        unfold need at hf; unfold openToks at hf; simp at hf; omega⟩
      by_cases hfe : fieldsOf kvs = []
      · rw [hfe] at hmk hf ⊢
        simp only [openToks, List.map_nil, ↓reduceIte, List.append_nil, List.cons_append,
          List.nil_append, List.append_assoc, List.length_append, List.length_cons,
          List.length_nil] at hf ⊢
        have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
          (Or.inl rfl) as hx rest g (by unfold need at hf ⊢; omega)
        rw [pPrim.eq_def]; simp only
        rw [pOpn.eq_def]; simp only [lpC, isLp, ↓reduceIte]
        rw [hca]
        simp only [hco, hneg, hpow, hD, hrem, htp, allPos_map, Bool.false_eq_true, ↓reduceIte]
        cases as with
        | nil => simp [allNamed, hmk]
        | cons a as' => rw [allNamed_pos _ (by simp)]; simp [hmk]
      · have hne : (fieldsOf kvs).map (fieldToks c) ≠ [] := by simpa using hfe
        simp only [openToks, hne, ↓reduceIte, List.cons_append, List.nil_append,
          List.append_assoc, List.length_append, List.length_cons, List.length_nil] at hf ⊢
        have hfl := pFields_list c rest (fieldsOf kvs) hfe hj hfM g (by unfold need at hf ⊢; omega)
        have hca := pCallArgs_list c (.kw .semi) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
          (Or.inr rfl) as hx
          (sepBy [.kw .comma] ((fieldsOf kvs).map (fieldToks c)) ++ .kw .rp :: rest) g (by unfold need at hf ⊢; omega)
        rw [pPrim.eq_def]; simp only
        rw [pOpn.eq_def]; simp only [lpC, isLp, ↓reduceIte]
        rw [hca]
        simp only [hcore, hrem, htp, Option.isSome_none, Bool.or_self, Bool.false_eq_true,
          ↓reduceIte, allPos_map]
        rw [hfl]
        simp only [hmk]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp only [mkOut, openToks, List.cons_append, List.append_assoc]
    exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_of_lvl (by rw [hpr]; rfl)
  · rw [hpr]; rfl

end Esm.Document.Math
