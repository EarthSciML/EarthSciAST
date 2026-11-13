import Esm.Document.Math.Cases9

/-!
# Round trip, case by case: the escape form

Every node has it: LaTeX `\esm{op}{fields}{args}` with the fields as JSON tokens, Typst
`esm.node("op", #(fields), args)`. The parser puts `op` and `args` back in their
sorted places among the fields (`mkNode_fieldsOf`).
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## JSON tokens -/

theorem jsonToks_head (v : Json) : ∃ t r, jsonToks v = t :: r ∧ t ≠ .kw .rbk ∧ t ≠ .kw .rb := by
  cases v with
  | null => exact ⟨_, _, rfl, by simp, by simp⟩
  | bool b => cases b <;> exact ⟨_, _, rfl, by simp, by simp⟩
  | num n => exact ⟨_, _, rfl, by simp, by simp⟩
  | str s => exact ⟨_, _, rfl, by simp, by simp⟩
  | arr xs => exact ⟨_, _, by rw [jsonToks]; rfl, by simp, by simp⟩
  | obj kvs => exact ⟨_, _, by rw [jsonToks]; rfl, by simp, by simp⟩

mutual
theorem pJson_toks : ∀ (v : Json) (f : Nat) (X : List Tok), 2 * (jsonToks v).length + 2 ≤ f →
    pJson f (jsonToks v ++ X) = some (v, X)
  | .null, f + 1, X, _ => rfl
  | .bool true, f + 1, X, _ => rfl
  | .bool false, f + 1, X, _ => rfl
  | .num n, f + 1, X, _ => rfl
  | .str s, f + 1, X, _ => rfl
  | .arr [], f + 1, X, _ => rfl
  | .arr (v :: vs), f + 1, X, hf => by
    obtain ⟨t, r, ht, h1, -⟩ := jsonToks_head v
    have hit := pItems_toks (v :: vs) f (.kw .rbk :: X) (by
      simp only [jsonToks, List.length_cons, List.length_append] at hf; omega)
      (by intro r e; cases e) (by simp)
    have hne : jsonItems (v :: vs) ≠ [] := by
      cases vs with
      | nil => simp [jsonItems, ht]
      | cons w ws => simp [jsonItems, ht]
    obtain ⟨t', r', he⟩ := List.exists_cons_of_ne_nil hne
    have ht' : t' ≠ .kw .rbk := by
      cases vs with
      | nil => simp only [jsonItems, ht, List.cons.injEq] at he; rw [← he.1]; exact h1
      | cons w ws => simp only [jsonItems, ht, List.cons_append, List.cons.injEq] at he; rw [← he.1]; exact h1
    rw [jsonToks, he]
    rw [he] at hit
    simp only [List.cons_append, List.append_assoc, List.nil_append] at hit ⊢
    rw [pJson.eq_8 _ _ (by intro r'' e; cases e; exact ht' rfl), hit]
  | .obj [], f + 1, X, _ => rfl
  | .obj (e :: es), f + 1, X, hf => by
    have hit := pEntries_toks (e :: es) f (.kw .rb :: X) (by
      simp only [jsonToks, List.length_cons, List.length_append] at hf; omega)
      (by intro r e; cases e) (by simp)
    obtain ⟨k, v⟩ := e
    have he : jsonEntries ((k, v) :: es) = .jstr k :: (jsonEntries ((k, v) :: es)).tail := by
      cases es with
      | nil => rfl
      | cons e' es' => rfl
    rw [jsonToks, he]
    rw [he] at hit
    simp only [List.cons_append, List.append_assoc, List.nil_append] at hit ⊢
    rw [pJson.eq_10 _ _ (by intro r'' e; cases e), hit]
  | v, 0, X, hf => by simp at hf

theorem pItems_toks : ∀ (vs : List Json) (f : Nat) (X : List Tok), 2 * (jsonItems vs).length + 3 ≤ f →
    (∀ r, X ≠ .kw .comma :: r) → vs ≠ [] →
    pJsonItems f (jsonItems vs ++ X) = some (vs, X)
  | [], _, _, _, _, hne => absurd rfl hne
  | [v], f + 1, X, hf, hX, _ => by
    simp only [jsonItems] at hf ⊢
    rw [pJsonItems, pJson_toks v f X (by omega)]
    cases X with
    | nil => rfl
    | cons t r =>
      have : t ≠ .kw .comma := fun e => hX r (by rw [e])
      split
      · rename_i heq; simp at heq; exact absurd heq.2.1 this
      · rename_i heq; simp at heq; obtain ⟨rfl, rfl⟩ := heq; rfl
      · rename_i heq; cases heq
  | v :: w :: ws, f + 1, X, hf, hX, _ => by
    simp only [jsonItems] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    rw [pJsonItems, List.append_assoc, List.cons_append, pJson_toks v f _ (by omega)]
    simp only
    rw [pItems_toks (w :: ws) f X (by omega) hX (by simp)]
    rfl
  | _ :: _, 0, X, hf, _, _ => by simp at hf

theorem pEntries_toks : ∀ (es : List (String × Json)) (f : Nat) (X : List Tok),
    2 * (jsonEntries es).length + 3 ≤ f → (∀ r, X ≠ .kw .comma :: r) → es ≠ [] →
    pJsonEntries f (jsonEntries es ++ X) = some (es, X)
  | [], _, _, _, _, hne => absurd rfl hne
  | [(k, v)], f + 1, X, hf, hX, _ => by
    simp only [jsonEntries] at hf ⊢
    simp only [List.length_cons] at hf
    simp only [List.cons_append]
    rw [pJsonEntries, pJson_toks v f X (by omega)]
    cases X with
    | nil => rfl
    | cons t r =>
      have : t ≠ .kw .comma := fun e => hX r (by rw [e])
      split
      · rename_i heq; simp at heq; exact absurd heq.2.1 this
      · rename_i heq; simp at heq; obtain ⟨rfl, rfl⟩ := heq; rfl
      · rename_i heq; cases heq
  | (k, v) :: e :: es, f + 1, X, hf, hX, _ => by
    simp only [jsonEntries] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    simp only [List.cons_append, List.append_assoc]
    rw [pJsonEntries, pJson_toks v f _ (by omega)]
    simp only
    rw [pEntries_toks (e :: es) f X (by omega) hX (by simp)]
    rfl
  | _ :: _, 0, X, hf, _, _ => by simp at hf
end


/-! ## Putting `op` and `args` back -/

def KeyLt (a b : String × Json) : Prop := a.1 < b.1

theorem keysSorted_pairwise : ∀ (l : List (String × Json)), keysSorted l = true → l.Pairwise KeyLt
  | [], _ => List.Pairwise.nil
  | [_], _ => List.pairwise_singleton _ _
  | (k1, v1) :: (k2, v2) :: r, h => by
    simp only [keysSorted, Bool.and_eq_true, decide_eq_true_eq] at h
    have ih := keysSorted_pairwise ((k2, v2) :: r) h.2
    refine List.Pairwise.cons ?_ ih
    intro b hb
    simp only [List.mem_cons] at hb
    rcases hb with rfl | hb
    · exact h.1
    · have := List.rel_of_pairwise_cons ih hb
      exact String.lt_trans h.1 this

theorem look_of_mem {k : String} {v : Json} :
    ∀ {l : List (String × Json)}, l.Pairwise KeyLt → (k, v) ∈ l → look k l = some v
  | [], _, hm => by simp at hm
  | (k', v') :: r, hp, hm => by
    simp only [List.mem_cons] at hm
    simp only [look]
    rcases hm with e | hm
    · simp only [Prod.mk.injEq] at e; obtain ⟨rfl, rfl⟩ := e; simp
    · have hlt : k' < k := List.rel_of_pairwise_cons hp hm
      have hne : k' ≠ k := fun e => String.lt_irrefl k (e ▸ hlt)
      simp only [hne, ↓reduceIte]
      exact look_of_mem (List.Pairwise.of_cons hp) hm

theorem insKV_filter {k : String} {v : Json} :
    ∀ (l : List (String × Json)), l.Pairwise KeyLt → (k, v) ∈ l →
      insKV (k, v) (l.filter (fun kv => kv.1 != k)) = l
  | [], _, hm => by simp at hm
  | (k', v') :: r, hp, hm => by
    simp only [List.mem_cons] at hm
    rcases hm with e | hm
    · simp only [Prod.mk.injEq] at e; obtain ⟨rfl, rfl⟩ := e
      have hall : ∀ kv ∈ r, k < kv.1 := fun kv hkv => List.rel_of_pairwise_cons hp hkv
      have hf : r.filter (fun kv => kv.1 != k) = r := by
        apply List.filter_eq_self.mpr
        intro kv hkv
        have := hall kv hkv
        simp only [bne_iff_ne, ne_eq]
        intro e; rw [e] at this; exact String.lt_irrefl _ this
      simp only [List.filter_cons, bne_self_eq_false, Bool.false_eq_true, ↓reduceIte]
      rw [hf]
      cases r with
      | nil => rfl
      | cons e r' =>
        simp only [insKV]
        rw [iteT (hall e (by simp))]
    · have hlt : k' < k := List.rel_of_pairwise_cons hp hm
      have hne : k' ≠ k := fun e => String.lt_irrefl k (e ▸ hlt)
      have hb : (k' != k) = true := by simp [hne]
      simp only [List.filter_cons, hb, ↓reduceIte, insKV]
      have hnlt : ¬ k < k' := fun h => String.lt_irrefl k (String.lt_trans h hlt)
      rw [iteF hnlt, insKV_filter r (List.Pairwise.of_cons hp) hm]

theorem mkNode_fieldsOf {kvs : List (String × Json)} {o : String} {as : List Json}
    (hs : keysSorted kvs = true) (hop : look "op" kvs = some (.str o))
    (hargs : look "args" kvs = some (.arr as)) : mkNode o as (fieldsOf kvs) = .obj kvs := by
  have hp := keysSorted_pairwise kvs hs
  have hpa : (kvs.filter (fun kv => kv.1 != "args")).Pairwise KeyLt := hp.filter _
  have hmo : ("op", Json.str o) ∈ kvs.filter (fun kv => kv.1 != "args") := by
    rw [List.mem_filter]; exact ⟨look_mem hop, by simp⟩
  have h1 : fieldsOf kvs = (kvs.filter (fun kv => kv.1 != "args")).filter (fun kv => kv.1 != "op") := by
    unfold fieldsOf; rw [List.filter_filter]
  unfold mkNode
  rw [h1, insKV_filter _ hpa hmo, insKV_filter _ hp (look_mem hargs)]


theorem pr_plus_lvl (c : Ctx) (xs : List Json) (h : 2 ≤ xs.length) : (pr c (node "+" xs)).lvl = 4 := by
  rw [pr.eq_def]
  simp only [node]
  match xs, h with
  | [a, b], _ => rfl
  | a :: b :: d :: r, _ => rfl

/-- A node printed at level 10 is not a `+` chain. -/
theorem addAcc_of_lvl {c : Ctx} {kvs : List (String × Json)} (h : (pr c (.obj kvs)).lvl = 10) :
    addAcc (.obj kvs) = [.obj kvs] := by
  unfold addAcc
  split
  · rename_i xs heq
    split
    · rename_i hl
      cases heq
      have := pr_plus_lvl c xs hl
      unfold node at this
      rw [h] at this; cases this
    · rfl
  · rfl

/-! ## The escape node -/

theorem pEscArgs_list (c : Ctx) :
    ∀ (as : List Json), (∀ x ∈ as, M c x) → ∀ rest f,
      need 1 ((as.map fun x => (pr c x).at c.sf 1).flatMap (fun a => .kw .comma :: a)).length + 2 ≤ f →
      pEscArgs c f ((as.map fun x => (pr c x).at c.sf 1).flatMap (fun a => .kw .comma :: a) ++
        .kw .rp :: rest) = some (as, rest)
  | [], _, rest, f + 1, _ => rfl
  | a :: as, hM, rest, f + 1, hf => by
    simp only [List.map_cons, List.flatMap_cons, List.length_append, List.length_cons] at hf ⊢
    have hfol : Fol c.sf 1 (((as.map fun x => (pr c x).at c.sf 1).flatMap (fun a => .kw .comma :: a)) ++
        .kw .rp :: rest) := by
      cases as with
      | nil => exact fol1_kw _ .rp (by simp) rest
      | cons b bs => exact fol1_kw _ .comma (by simp) _
    have h1 := child1 (hM a (by simp)) _ hfol f (by unfold need at hf ⊢; omega)
    simp only [List.cons_append, List.append_assoc]
    rw [pEscArgs.eq_3, h1]
    simp only
    rw [pEscArgs_list c as (fun x hx => hM x (by simp [hx])) rest f (by unfold need at hf ⊢; omega)]
    rfl
  | _, _, _, 0, hf => by simp at hf


theorem M_esc (c : Ctx) (kvs : List (String × Json)) (o : String) (as : List Json)
    (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
    (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, M c x)
    (hoOK : opOK o = true) (hrem : removedOps.contains o = false)
    (hdep : deprecatedOps.contains o = false)
    (hpr : pr c (.obj kvs) =
      mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.map fun x => (pr c x).at c.sf 1))) :
    M c (.obj kvs) := by
  have hmk := mkNode_fieldsOf hs hop hargs
  have hcond : (opOK o && !(removedOps.contains o) && !(deprecatedOps.contains o)) = true := by
    rw [hoOK, hrem, hdep]; rfl
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      rw [hpr] at hf ⊢
      simp only [mkOut] at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by
        unfold need at hf; unfold escToks at hf; split at hf <;> simp at hf <;> omega⟩
      obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
      · have heq : escToks c.sf o (fieldsOf kvs) (as.map fun x => (pr c x).at c.sf 1) =
            [.esc o, .kw .lb] ++ jsonToks (.obj (fieldsOf kvs)) ++ [.kw .rb, .kw .lb] ++
              sepBy [.kw .comma] (as.map fun x => (pr c x).at c.sf 1) ++ [.kw .rb] := by
          unfold escToks; split
          · rfl
          · rename_i h; rw [hsf] at h; cases h
        rw [heq] at hf ⊢
        simp only [List.length_append, List.length_cons, List.length_nil] at hf
        have hj := pJson_toks (.obj (fieldsOf kvs)) (g + 1)
          (.kw .rb :: .kw .lb :: (sepBy [.kw .comma] (as.map fun x => (pr c x).at c.sf 1) ++ .kw .rb :: rest))
          (by unfold need at hf; omega)
        have hl := pList_list c (.kw .rb) (fun r => fol1_kw _ .rb (by simp) r) (by simp)
          (Or.inr (Or.inr (Or.inl rfl))) as hx rest (g + 1) (by unfold need at hf ⊢; omega)
        simp only [List.cons_append, List.append_assoc, List.nil_append]
        rw [pPrim.eq_def]
        simp only
        rw [hj]
        simp only
        rw [hl]
        simp only [hcond, ↓reduceIte, hmk]
      · have heq : escToks c.sf o (fieldsOf kvs) (as.map fun x => (pr c x).at c.sf 1) =
            [.kw .esmnode, .kw .lp, .txt o, .kw .comma, .code (.obj (fieldsOf kvs))] ++
              (as.map fun x => (pr c x).at c.sf 1).flatMap (fun a => .kw .comma :: a) ++ [.kw .rp] := by
          unfold escToks; split
          · rename_i h; rw [hsf] at h; cases h
          · rfl
        rw [heq] at hf ⊢
        have hl := pEscArgs_list c as hx rest (g + 1) (by
          simp only [List.length_append, List.length_cons, List.length_nil] at hf
          unfold need at hf ⊢; omega)
        simp only [List.cons_append, List.append_assoc, List.nil_append]
        rw [pPrim.eq_def]
        simp only [isLp, ↓reduceIte]
        rw [hl]
        simp only [hcond, ↓reduceIte, hmk]
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp only [mkOut, escToks]
    split <;> exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · exact addAcc_of_lvl (by rw [hpr]; rfl)
  · rw [hpr]; rfl

end Esm.Document.Math
