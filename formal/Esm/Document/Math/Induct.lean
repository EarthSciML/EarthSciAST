import Esm.Document.Math.Makearray

/-!
# The token-level round trip, by induction over the expression
-/

namespace Esm.Document.Math

open Esm.Document

theorem sizeOf_node_lt {o : String} {xs : List Json} {x : Json} (h : x ∈ xs) :
    sizeOf x < sizeOf (node o xs) :=
  sizeOf_obj_lt (as := xs) (by simp [look]) x h

theorem sizeOf_tNode_lt {n : String} {bs : List (String × Json)} {kv : String × Json} (h : kv ∈ bs) :
    sizeOf kv.2 < sizeOf (tNode n bs) := by
  have := List.sizeOf_lt_of_mem h
  obtain ⟨k, v⟩ := kv
  simp only [tNode, Json.obj.sizeOf_spec, List.cons.sizeOf_spec, Prod.mk.sizeOf_spec,
    Json.arr.sizeOf_spec, Json.str.sizeOf_spec] at this ⊢
  omega

theorem sizeOf_dNode_lt (a : Json) (w : String) : sizeOf a < sizeOf (dNode a w) :=
  sizeOf_obj_lt (as := [a]) (by simp [look]) a (by simp)

theorem sizeOf_pNode_lt (a : Json) (w : String) : sizeOf a < sizeOf (pNode a w) :=
  sizeOf_obj_lt (as := [a]) (by simp [look]) a (by simp)

theorem sizeOf_dCallNode_lt {w : String} {xs : List Json} {x : Json} (h : x ∈ xs) :
    sizeOf x < sizeOf (dCallNode w xs) :=
  sizeOf_obj_lt (as := xs) (by simp [look]) x h

/-- Every well-formed expression carries the round-trip facts. -/
theorem M_all (c : Ctx) : ∀ n e, sizeOf e < n → isE e = true → M c e
  | 0, _, h, _ => absurd h (Nat.not_lt_zero _)
  | n + 1, e, hs, he => by
    have IH : ∀ x, sizeOf x < sizeOf e → isE x = true → M c x :=
      fun x hx hxe => M_all c n x (by omega) hxe
    cases view c e he with
    | num k _ => exact M_num c k
    | name s h => exact M_name c s h
    | neg o a ho ha hpr => exact M_neg c o a ho (IH a (sizeOf_node_lt (by simp)) ha) hpr
    | minus o a b ho ha hb hpr =>
      exact M_minus c o a b ho (IH a (sizeOf_node_lt (by simp)) ha) (IH b (sizeOf_node_lt (by simp)) hb) hpr
    | div o a b ho ha hb hpr =>
      exact M_div c o a b ho (IH a (sizeOf_node_lt (by simp)) ha) (IH b (sizeOf_node_lt (by simp)) hb) hpr
    | pow o a b ho ha hb hpr =>
      exact M_pow c o a b ho (IH a (sizeOf_node_lt (by simp)) ha) (IH b (sizeOf_node_lt (by simp)) hb) hb hpr
    | lnot o a ho ha hpr => exact M_lnot c o a ho (IH a (sizeOf_node_lt (by simp)) ha) hpr
    | tru o ho hpr => exact M_tru c o ho hpr
    | fls o ho hpr => exact M_fls c o ho hpr
    | ite o cnd a b ho hc ha hb hpr =>
      exact M_ite c o cnd a b ho (IH cnd (sizeOf_node_lt (by simp)) hc) (IH a (sizeOf_node_lt (by simp)) ha)
        (IH b (sizeOf_node_lt (by simp)) hb) hpr
    | un o k a ho ha hpr => exact M_un c o k a ho (IH a (sizeOf_node_lt (by simp)) ha) hpr
    | ic o m ho hm hpr => exact M_ic c o m ho hm hpr
    | idxSub o b is ho hne hsub hsp hi hpr =>
      exact M_idxSub c o b is ho hne hsub hsp
        (fun x hx => IH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx)) hi hpr
    | idxBr o base is ho hne hb hi hpr =>
      exact M_idxBr c o base is ho hne (IH base (sizeOf_node_lt (by simp)) hb)
        (fun x hx => IH x (sizeOf_node_lt (List.mem_cons_of_mem _ hx)) (hi x hx)) hpr
    | cmp o k a b ho ha hb hpr =>
      exact M_cmp c o k a b ho (IH a (sizeOf_node_lt (by simp)) ha) (IH b (sizeOf_node_lt (by simp)) hb) hpr
    | plus o xs ho hl hx hpr =>
      exact M_plus c o xs ho hl (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | times o xs ho hl hx hpr =>
      exact M_times c o xs ho hl (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | land o xs ho hl hx hpr =>
      exact M_land c o xs ho hl (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | lor o xs ho hl hx hpr =>
      exact M_lor c o xs ho hl (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | mm o k xs ho hl hx hpr =>
      exact M_mm c o k xs ho hl (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | nab o n a ho ha hpr => exact M_nab c o n a ho (IH a (sizeOf_node_lt (by simp)) ha) hpr
    | call o xs ho hx hpr =>
      exact M_call c o xs ho (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | dTime a ha hpr => exact M_dTime c a (IH a (sizeOf_dNode_lt a _) ha) hpr
    | dSpace w a hw hwn ha hpr => exact M_dSpace c w a hw hwn (IH a (sizeOf_pNode_lt a _) ha) hpr
    | dCall w xs hw hwn hl hx hpr =>
      exact M_dCall c w xs hwn (fun x hm => IH x (sizeOf_dCallNode_lt hm) (hx x hm)) hpr
    | qty u k hk hu hpr => exact M_qty c u k hu hpr
    | arr xs af haf hpr => exact M_arr c xs af haf hpr
    | arrU u xs af haf hu hpr => exact M_arrU c u xs af haf hu hpr
    | faq kvs F hF hok P hP hpr =>
      exact M_faq c kvs F hF hok P hP hpr (fun x hx => IH x (faqSubs_lt hF hx) (faqSubs_isE hok x hx))
    | mk kvs A hA hok P hP hpr =>
      exact M_mk c kvs A hA hok P hP hpr (fun x hx => IH x (mkSubs_lt hA hx) (mkSubs_isE hok x hx))
    | tbare m hm hps hpr => exact M_tbare c m hm hps hpr
    | tpos m bs ps hm hsb hb hps hpr =>
      exact M_tpos c m bs ps hm hsb (fun kv hkv => IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) hps hpr
    | tnamed m bs hm hks hb hps hne hk hkn hpr =>
      exact M_tnamed c m bs hm hks (fun kv hkv => IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) hne hk hpr
    | openop kvs o as hop hargs hsk hx hf hcf hopn htp hnat hkey hsz hszf hpr =>
      obtain ⟨o', hop', -, hrem, -⟩ := isE_op he
      rw [hop] at hop'; cases hop'
      exact M_openop c kvs o as hop hargs hsk (fun x hm => IH x (hsz x hm) (hx x hm)) hf
        (fun kv hkv hkve => IH kv.2 (hszf kv hkv) hkve) hcf hopn htp hnat hrem hpr
    | esc kvs o as hop hargs hsk hx hf hoOK hrem hdep hsz hpr =>
      exact M_esc c kvs o as hop hargs hsk (fun x hm => IH x (hsz x hm) (hx x hm)) hf hoOK hrem hdep hpr

theorem M_of_isE (c : Ctx) (e : Json) (he : isE e = true) : M c e :=
  M_all c _ e (Nat.lt_succ_self _) he

/-- Read a whole token list as one expression: an expression, or an equation in its
defining form (`x_s = …, s ∈ S`, `unlift`). -/
def parseToks (sf : Sf) (S : Sym) (ts : List Tok) : Option Json :=
  match pOr ⟨sf, S⟩ (need 1 ts.length) ts with
  | some (e, []) => some e
  | some (q, .kw .comma :: r) =>
    match pTail ⟨sf, S⟩ (need 1 ts.length) r with
    | some rows =>
      match rowParts rows with
      | some (rg, none) => unlift q rg
      | _ => none
    | none => none
  | _ => none

/-- An expression printed whole reads back. -/
theorem parseToks_pa (sf : Sf) (S : Sym) (e : Json) (he : isE e = true) :
    parseToks sf S (pa ⟨sf, S⟩ 1 e) = some e := by
  have hm := M_of_isE ⟨sf, S⟩ e he
  have h := PL_at hm 1 (le_refl _) (by omega) [] (fun t r h => by cases h) _ (le_refl _)
  rw [pLvl1, List.append_nil] at h
  unfold parseToks pa
  rw [h]

theorem rowParts_rngs : ∀ (l : List (String × Json)),
    rowParts (l.map fun kv => Row.rng kv.1 kv.2) = some (l, none)
  | [] => rfl
  | kv :: l => by simp only [List.map_cons, rowParts, rowParts_rngs l, Option.map_some]

/-- The range rows after a defining equation read back. -/
theorem pTail_tail (c : Ctx) (rows : List (String × Json)) (hne : rows ≠ [])
    (hrows : rows.all (fun kv => nameOK kv.1 && rangeOK kv.2 &&
      match kv.2 with | .arr [a, b] => isE a && isE b | _ => true) = true)
    (f : Nat) (hf : 30 * (defRowsToks c rows).length + 12 ≤ f) :
    pTail c (f + 1) (defRowsToks c rows) = some (rows.map fun kv => Row.rng kv.1 kv.2) := by
  let rs := rows.map fun kv => (Row.rng kv.1 kv.2, rowToks c (pr c) kv)
  have h1 : defRowsToks c rows = sepBy [.kw .comma] (rs.map Prod.snd) := by
    simp [rs, defRowsToks, Function.comp_def]
  have h2 : rows.map (fun kv => Row.rng kv.1 kv.2) = rs.map Prod.fst := by
    simp [rs, Function.comp_def]
  rw [h1, h2]
  rw [h1] at hf
  refine pTail_read c rs (by simpa [rs] using hne) ?_ f hf
  intro p hp X hX g hg
  obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hp
  have hc := List.all_eq_true.1 hrows kv hkv
  simp only [Bool.and_eq_true] at hc
  obtain ⟨⟨hk, hv⟩, hab⟩ := hc
  have hM : ∀ a b, kv.2 = .arr [a, b] → M c a ∧ M c b ∧ pr c a = pr c a ∧ pr c b = pr c b := by
    intro a b e
    rw [e] at hab
    simp only [Bool.and_eq_true] at hab
    exact ⟨M_of_isE c a hab.1, M_of_isE c b hab.2, rfl, rfl⟩
  rcases hX with rfl | ⟨R, rfl⟩
  · exact pRow_range_gen c (pr c) kv.1 kv.2 hk hv hM _ rfl rfl [] (Fol_nil _ _)
      ⟨fun r e => (by cases e), rfl⟩ (fun r e => by cases e) g hg
  · have hE : EndTok .comma := Or.inr (Or.inr (Or.inr rfl))
    exact pRow_range_gen c (pr c) kv.1 kv.2 hk hv hM _ rfl rfl _ (endTok_fol hE 4 (by omega) R)
      (endTok_stop hE R) (fun r e => by simp at e) g hg

/-- The token-level round trip: every well-formed expression reads back from its
printed tokens, on both surfaces and under every symbol table. -/
theorem parseToks_print (sf : Sf) (S : Sym) (e : Json) (he : isE e = true) :
    parseToks sf S (print sf S e) = some e := by
  unfold print
  split
  · rename_i q rows _
    split
    · rename_i hok
      unfold liftOK at hok
      simp only [Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff] at hok
      obtain ⟨⟨⟨hne, hq⟩, hrows⟩, hun⟩ := hok
      obtain ⟨e', hu, hj⟩ : ∃ e', unlift q rows = some e' ∧ jbeq e' e = true := by
        revert hun; cases unlift q rows with
        | none => intro h; cases h
        | some e' => intro h; exact ⟨e', rfl, h⟩
      have he' := jbeq_sound _ _ hj
      subst he'
      have hm := M_of_isE ⟨sf, S⟩ q hq
      have hE : EndTok .comma := Or.inr (Or.inr (Or.inr rfl))
      have hlen : (pa ⟨sf, S⟩ 1 q ++ .kw .comma :: defRowsToks ⟨sf, S⟩ rows).length =
          (pa ⟨sf, S⟩ 1 q).length + 1 + (defRowsToks ⟨sf, S⟩ rows).length := by simp; omega
      have h := PL_at hm 1 (le_refl _) (by omega) (.kw .comma :: defRowsToks ⟨sf, S⟩ rows)
        (endTok_fol hE 1 (le_refl _) _) (need 1 (pa ⟨sf, S⟩ 1 q ++ .kw .comma :: defRowsToks ⟨sf, S⟩ rows).length)
        (by unfold pa at hlen ⊢; rw [hlen]; unfold need; omega)
      rw [pLvl1] at h
      unfold parseToks
      unfold pa at h ⊢
      rw [h]
      simp only
      have ht := pTail_tail ⟨sf, S⟩ rows hne hrows
        (need 1 ((pr ⟨sf, S⟩ q).at sf 1 ++ .kw .comma :: defRowsToks ⟨sf, S⟩ rows).length - 1)
        (by unfold pa at hlen; rw [hlen]; unfold need; omega)
      have hn1 : need 1 ((pr ⟨sf, S⟩ q).at sf 1 ++ .kw .comma :: defRowsToks ⟨sf, S⟩ rows).length - 1 + 1 =
          need 1 ((pr ⟨sf, S⟩ q).at sf 1 ++ .kw .comma :: defRowsToks ⟨sf, S⟩ rows).length := by
        unfold need; omega
      rw [hn1] at ht
      rw [ht]
      simp only
      rw [rowParts_rngs]
      exact hu
    · exact parseToks_pa sf S e he
  · exact parseToks_pa sf S e he

end Esm.Document.Math
