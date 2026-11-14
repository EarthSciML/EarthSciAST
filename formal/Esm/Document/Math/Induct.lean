import Esm.Document.Math.Faq

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
    | call o xs ho hx hpr =>
      exact M_call c o xs ho (fun x hm => IH x (sizeOf_node_lt hm) (hx x hm)) hpr
    | dTime a ha hpr => exact M_dTime c a (IH a (sizeOf_dNode_lt a _) ha) hpr
    | dSpace w a hw hwn ha hpr => exact M_dSpace c w a hwn (IH a (sizeOf_dNode_lt a _) ha) hpr
    | dCall w xs hw hwn hl hx hpr =>
      exact M_dCall c w xs hwn (fun x hm => IH x (sizeOf_dCallNode_lt hm) (hx x hm)) hpr
    | qty u k hk hu hpr => exact M_qty c u k hu hpr
    | arr xs af haf hpr => exact M_arr c xs af haf hpr
    | arrU u xs af haf hu hpr => exact M_arrU c u xs af haf hu hpr
    | faq kvs F hF hok P hP hpr =>
      exact M_faq c kvs F hF hok P hP hpr (fun x hx => IH x (faqSubs_lt hF hx) (faqSubs_isE hok x hx))
    | tpos m bs ps hm hsb hb hps hpr =>
      exact M_tpos c m bs ps hm hsb (fun kv hkv => IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) hps hpr
    | tnamed m bs hm hb hps hne hk hkn hpr =>
      exact M_tnamed c m bs hm (fun kv hkv => IH kv.2 (sizeOf_tNode_lt hkv) (hb kv hkv)) hne hk hpr
    | openop kvs o as hop hargs hsk hx hf hcore hopn htp hkey hsz hszf hpr =>
      obtain ⟨o', hop', -, hrem, -⟩ := isE_op he
      rw [hop] at hop'; cases hop'
      exact M_openop c kvs o as hop hargs hsk (fun x hm => IH x (hsz x hm) (hx x hm)) hf
        (fun kv hkv hkve => IH kv.2 (hszf kv hkv) hkve) hcore htp hrem hpr
    | esc kvs o as hop hargs hsk hx hf hoOK hrem hdep hsz hpr =>
      exact M_esc c kvs o as hop hargs hsk (fun x hm => IH x (hsz x hm) (hx x hm)) hoOK hrem hdep hpr

theorem M_of_isE (c : Ctx) (e : Json) (he : isE e = true) : M c e :=
  M_all c _ e (Nat.lt_succ_self _) he

/-- Read a whole token list as one expression. -/
def parseToks (sf : Sf) (S : Sym) (ts : List Tok) : Option Json :=
  match pOr ⟨sf, S⟩ (need 1 ts.length) ts with
  | some (e, []) => some e
  | _ => none

/-- The token-level round trip: every well-formed expression reads back from its
printed tokens, on both surfaces and under every symbol table. -/
theorem parseToks_print (sf : Sf) (S : Sym) (e : Json) (he : isE e = true) :
    parseToks sf S (print sf S e) = some e := by
  have hm := M_of_isE ⟨sf, S⟩ e he
  have h := PL_at hm 1 (le_refl _) (by omega) [] (fun t r h => by cases h) _ (le_refl _)
  rw [pLvl1, List.append_nil] at h
  unfold parseToks print pa
  rw [h]

end Esm.Document.Math
