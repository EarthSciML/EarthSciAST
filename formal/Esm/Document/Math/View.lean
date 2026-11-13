import Esm.Document.Math.Parse

/-!
# How the printer prints each expression

`view` sorts every well-formed expression into the notation the printer gives it
and states the printer's output for it, so the round-trip proof never unfolds the
printer itself.
-/

namespace Esm.Document.Math

open Esm.Document

theorem attach_map_eq {α β : Type} (l : List α) (g : α → β) :
    (l.attach.map fun x => g x.1) = l.map g := by
  induction l with
  | nil => rfl
  | cons a l ih => simp

/-- The printer's case for an expression, with its output. -/
inductive V (c : Ctx) : Json → Prop where
  | num (n : JNum) (h : n.WF) : V c (.num n)
  | name (s : String) (h : nameOK s = true) : V c (.str s)
  | neg (o : String) (a : Json) (ho : kindOf o = .minus) (ha : isE a = true)
      (hpr : pr c (node o [a]) =
        mkOut c.sf 5 (.kw .minus :: (if startsNum ((pr c a).at c.sf 5) then grp c.sf ((pr c a).at c.sf 5)
          else (pr c a).at c.sf 5))) : V c (node o [a])
  | minus (o : String) (a b : Json) (ho : kindOf o = .minus) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 4 ((pr c a).at c.sf 4 ++ .kw .minus :: (pr c b).at c.sf 5)) :
      V c (node o [a, b])
  | div (o : String) (a b : Json) (ho : kindOf o = .div) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = match c.sf with
        | .latex => mkOut c.sf 10 ([.kw .frac, .kw .lb] ++ (pr c a).at c.sf 1 ++
            [.kw .rb, .kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb])
        | .typst => mkOut c.sf 7 ((pr c a).at c.sf 8 ++ .kw .slash :: (pr c b).at c.sf 8)) :
      V c (node o [a, b])
  | pow (o : String) (a b : Json) (ho : kindOf o = .pow) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 8 ((pr c a).at c.sf 9 ++ .kw .caret :: (match c.sf with
          | .latex => [.kw .lb] ++ (pr c b).at c.sf 1 ++ [.kw .rb]
          | .typst =>
            match (pr c b).toks with
            | [t] => if simpleTok t then [t] else grp c.sf [t]
            | t => grp c.sf t))) :
      V c (node o [a, b])
  | lnot (o : String) (a : Json) (ho : kindOf o = .lnot) (ha : isE a = true)
      (hpr : pr c (node o [a]) = mkOut c.sf 6 (.kw .lnot :: (pr c a).at c.sf 6)) : V c (node o [a])
  | tru (o : String) (ho : kindOf o = .tru) (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "true"]) :
      V c (node o [])
  | fls (o : String) (ho : kindOf o = .fls) (hpr : pr c (node o []) = mkOut c.sf 10 [.txt "false"]) :
      V c (node o [])
  | ite (o : String) (cnd a b : Json) (ho : kindOf o = .ite) (hc : isE cnd = true) (ha : isE a = true)
      (hb : isE b = true)
      (hpr : pr c (node o [cnd, a, b]) =
        ⟨10, casesToks c.sf (caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow),
          caseRow c.sf ((pr c a).at c.sf 1) ((pr c cnd).at c.sf 1) ++ (pr c b).crow⟩) :
      V c (node o [cnd, a, b])
  | un (o : String) (k : Kw) (a : Json) (ho : kindOf o = .un k) (ha : isE a = true)
      (hpr : pr c (node o [a]) = mkOut c.sf 10 (unToks c.sf k ((pr c a).at c.sf 1))) : V c (node o [a])
  | ic (o : String) (n : String) (ho : kindOf o = .ic) (hn : nameOK n = true)
      (hpr : pr c (node o [.str n]) = mkOut c.sf 10 (nameToks c n ++ icTail c.sf)) :
      V c (node o [.str n])
  | idxSub (o : String) (b : String) (is : List Json) (ho : kindOf o = .index) (hne : is ≠ [])
      (hs : subOK c.S (.str b) is = true) (hi : ∀ x ∈ is, isE x = true)
      (hpr : pr c (node o (.str b :: is)) =
        mkOut c.sf 9 (nameToks c b ++ subList c.sf (is.map fun x => (pr c x).at c.sf 1))) :
      V c (node o (.str b :: is))
  | idxBr (o : String) (base : Json) (is : List Json) (ho : kindOf o = .index) (hne : is ≠ [])
      (hb : isE base = true) (hi : ∀ x ∈ is, isE x = true)
      (hpr : pr c (node o (base :: is)) = mkOut c.sf 9 ((pr c base).at c.sf 10 ++ [.kw .lbk] ++
        sepBy [.kw .comma] (is.map fun x => (pr c x).at c.sf 1) ++ [.kw .rbk])) :
      V c (node o (base :: is))
  | cmp (o : String) (k : Kw) (a b : Json) (ho : kindOf o = .cmp k) (ha : isE a = true) (hb : isE b = true)
      (hpr : pr c (node o [a, b]) = mkOut c.sf 3 ((pr c a).at c.sf 4 ++ .kw k :: (pr c b).at c.sf 4)) :
      V c (node o [a, b])
  | plus (o : String) (xs : List Json) (ho : kindOf o = .plus) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 4 (sepBy [.kw .plus] (xs.map fun x => (pr c x).at c.sf 5))) :
      V c (node o xs)
  | times (o : String) (xs : List Json) (ho : kindOf o = .times) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 5 (mulToks (xs.map fun x => (pr c x).at c.sf 6))) :
      V c (node o xs)
  | land (o : String) (xs : List Json) (ho : kindOf o = .land) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 2 (sepBy [.kw .land] (xs.map fun x => (pr c x).at c.sf 3))) :
      V c (node o xs)
  | lor (o : String) (xs : List Json) (ho : kindOf o = .lor) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 1 (sepBy [.kw .lor] (xs.map fun x => (pr c x).at c.sf 2))) :
      V c (node o xs)
  | mm (o : String) (k : Kw) (xs : List Json) (ho : kindOf o = .mm k) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 10 (callToks c.sf [.kw k] (xs.map fun x => (pr c x).at c.sf 1))) :
      V c (node o xs)
  | call (o : String) (xs : List Json) (ho : kindOf o = .call) (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (node o xs) = mkOut c.sf 10 (callToks c.sf [.opn o] (xs.map fun x => (pr c x).at c.sf 4))) :
      V c (node o xs)
  | dTime (a : Json) (ha : isE a = true)
      (hpr : pr c (dNode a "t") = dTime c.sf (pr c a)) : V c (dNode a "t")
  | dSpace (w : String) (a : Json) (hw : w ≠ "t") (hwn : nameOK w = true) (ha : isE a = true)
      (hpr : pr c (dNode a w) = dSpace c.sf (nameToks c w) (pr c a)) : V c (dNode a w)
  | dCall (w : String) (xs : List Json) (hw : w ≠ "t") (hwn : nameOK w = true) (hl : 2 ≤ xs.length)
      (hx : ∀ x ∈ xs, isE x = true)
      (hpr : pr c (dCallNode w xs) =
        mkOut c.sf 10 (dCall c.sf (nameToks c w) (xs.map fun x => (pr c x).at c.sf 4))) :
      V c (dCallNode w xs)
  | qty (u : String) (n : JNum) (hn : n.WF) (hu : unitsOK c.sf u = true)
      (hpr : pr c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)]) =
        mkOut c.sf 7 (qtyToks c.sf n (factorsOf u))) :
      V c (.obj [("args", .arr []), ("op", .str "const"), ("units", .str u), ("value", .num n)])
  | tpos (n : String) (bs : List (String × Json)) (ps : List String) (hn : tnameOK n = true)
      (hs : keysSorted bs = true) (hb : ∀ kv ∈ bs, isE kv.2 = true) (hps : positional c.S n bs = some ps)
      (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n]
        (ps.map fun p => ((bs.map fun kv => (kv.1, (pr c kv.2).at c.sf 4)).lookup p).getD []))) :
      V c (tNode n bs)
  | tnamed (n : String) (bs : List (String × Json)) (hn : tnameOK n = true)
      (hb : ∀ kv ∈ bs, isE kv.2 = true) (hps : positional c.S n bs = none) (hne : bs ≠ [])
      (hk : ∀ kv ∈ bs, nameOK kv.1 = true) (hkn : (bs.map Prod.fst).Nodup)
      (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n]
        (bs.map fun kv => nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at c.sf 4))) :
      V c (tNode n bs)
  | openop (kvs : List (String × Json)) (o : String) (as : List Json)
      (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
      (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, isE x = true)
      (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true)
      (hcore : coreOps.contains o = false) (hopn : opnOK o = true) (htp : tparams c.S o = none)
      (hkey : ∀ kv ∈ fieldsOf kvs, keyOK kv.1 = true)
      (hsz : ∀ x ∈ as, sizeOf x < sizeOf (Json.obj kvs))
      (hszf : ∀ kv ∈ fieldsOf kvs, sizeOf kv.2 < sizeOf (Json.obj kvs))
      (hpr : pr c (.obj kvs) = mkOut c.sf 10 (openToks c.sf o (as.map fun x => (pr c x).at c.sf 4)
        ((fieldsOf kvs).map fun kv =>
          keyToks c.sf kv.1 ++ .kw .eq :: (if isE kv.2 then (pr c kv.2).at c.sf 4 else jsonVal c.sf kv.2)))) :
      V c (.obj kvs)
  | esc (kvs : List (String × Json)) (o : String) (as : List Json)
      (hop : look "op" kvs = some (.str o)) (hargs : look "args" kvs = some (.arr as))
      (hs : keysSorted kvs = true) (hx : ∀ x ∈ as, isE x = true)
      (hf : ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true)
      (hoOK : opOK o = true) (hrem : removedOps.contains o = false)
      (hdep : deprecatedOps.contains o = false)
      (hsz : ∀ x ∈ as, sizeOf x < sizeOf (Json.obj kvs))
      (hpr : pr c (.obj kvs) =
        mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.map fun x => (pr c x).at c.sf 1))) :
      V c (.obj kvs)

end Esm.Document.Math

namespace Esm.Document.Math
open Esm.Document

theorem isE_unfold {kvs : List (String × Json)} (h : isE (.obj kvs) = true) :
    keysSorted kvs = true ∧ opFieldOK kvs = true ∧ hasArgs kvs = true ∧
      ∀ kv ∈ kvs, (if kv.1 = "args" then
        (match kv.2 with
         | .arr as => as.all (fun a => isE a)
         | _ => false)
      else kv.1 == "op" || jwf kv.2) = true := by
  rw [isE] at h
  simp only [Bool.and_eq_true, List.all_eq_true] at h
  obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := h
  refine ⟨h1, h2, h3, fun kv hkv => ?_⟩
  have := h4 ⟨kv, hkv⟩ (List.mem_attach _ _)
  simp only at this
  split at this
  · rename_i hk
    simp only [hk, ↓reduceIte]
    split at this
    · rename_i as heq
      simp only [heq]
      simp only [List.all_eq_true] at this ⊢
      intro a ha
      exact this ⟨a, ha⟩ (List.mem_attach _ _)
    · simp at this
  · rename_i hk
    simp only [hk, ↓reduceIte]; exact this

theorem isE_args {kvs : List (String × Json)} {as : List Json} (h : isE (.obj kvs) = true)
    (hargs : look "args" kvs = some (.arr as)) : ∀ a ∈ as, isE a = true := by
  have := (isE_unfold h).2.2.2 _ (look_mem hargs)
  simp only [ite_true, List.all_eq_true] at this
  exact this

theorem look_eq_some_of_isSome {k : String} {kvs : List (String × Json)} (h : (look k kvs).isSome = true) :
    ∃ v, look k kvs = some v := Option.isSome_iff_exists.mp h

theorem isE_hasArr {kvs : List (String × Json)} (h : isE (.obj kvs) = true) :
    ∃ as, look "args" kvs = some (.arr as) := by
  obtain ⟨v, hv⟩ := look_eq_some_of_isSome (isE_unfold h).2.2.1
  have := (isE_unfold h).2.2.2 _ (look_mem hv)
  simp only [ite_true] at this
  cases v with
  | arr as => exact ⟨as, hv⟩
  | _ => simp at this

theorem isE_op {kvs : List (String × Json)} (h : isE (.obj kvs) = true) :
    ∃ o, look "op" kvs = some (.str o) ∧ opOK o = true ∧ removedOps.contains o = false ∧
      deprecatedOps.contains o = false := by
  have := (isE_unfold h).2.1
  unfold opFieldOK at this
  split at this
  · rename_i o ho
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at this
    exact ⟨o, ho, this.1.1, this.1.2, this.2⟩
  · simp at this

theorem mem_fieldsOf {kv : String × Json} {kvs : List (String × Json)} (h : kv ∈ fieldsOf kvs) :
    kv ∈ kvs ∧ kv.1 ≠ "op" ∧ kv.1 ≠ "args" := by
  unfold fieldsOf at h
  rw [List.mem_filter] at h
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h
  exact ⟨h.1, h.2.1, h.2.2⟩

theorem isE_fields {kvs : List (String × Json)} (h : isE (.obj kvs) = true) :
    ∀ kv ∈ fieldsOf kvs, jwf kv.2 = true := by
  intro kv hkv
  obtain ⟨hm, h1, h2⟩ := mem_fieldsOf hkv
  have := (isE_unfold h).2.2.2 _ hm
  simp only [h2, ↓reduceIte] at this
  simpa [h1] using this

theorem isE_node {o : String} {as : List Json} (h : isE (node o as) = true) :
    ∀ a ∈ as, isE a = true :=
  isE_args h (by simp [look])

theorem sizeOf_obj_lt {kvs : List (String × Json)} {as : List Json}
    (hargs : look "args" kvs = some (.arr as)) : ∀ a ∈ as, sizeOf a < sizeOf (Json.obj kvs) := by
  intro a ha
  have := look_arr_lt hargs ha
  simp only [Json.obj.sizeOf_spec]; omega

theorem sizeOf_fields_lt {kvs : List (String × Json)} :
    ∀ kv ∈ fieldsOf kvs, sizeOf kv.2 < sizeOf (Json.obj kvs) := by
  intro kv hkv
  have := fields_lt hkv
  simp only [Json.obj.sizeOf_spec]; omega

theorem view (c : Ctx) : ∀ e, isE e = true → V c e
  | .num n, h => .num n ((numOK_iff n).1 (by rw [isE] at h; exact h))
  | .str s, h => .name s (by rw [isE] at h; exact h)
  | .obj kvs, h => by
    have hpr := pr.eq_def c (.obj kvs)
    simp only at hpr
    obtain ⟨o0, hop0, hok0, hrem0, hdep0⟩ := isE_op h
    obtain ⟨as0, hargs0⟩ := isE_hasArr h
    have hs0 := (isE_unfold h).1
    have hx0 := isE_args h hargs0
    have hf0 := isE_fields h
    have hsz0 := sizeOf_obj_lt hargs0
    have hszf0 := sizeOf_fields_lt (kvs := kvs)
    -- the escape form, from the escape match
    have fbEsc : ∀ X : Out, pr c (.obj kvs) = X →
        X = (match look "op" kvs, _hk : look "args" kvs with
          | some (.str o), some (.arr as) =>
            mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.attach.map fun x => (pr c x.1).at c.sf 1))
          | _, _ => mkOut c.sf 10 []) → V c (.obj kvs) := by
      intro X hX hXe
      rw [hXe] at hX
      split at hX
      · rename_i o as hop hargs
        exact V.esc kvs o as hop hargs hs0 (isE_args h hargs) hf0
          (by rw [hop0] at hop; cases hop; exact hok0) (by rw [hop0] at hop; cases hop; exact hrem0)
          (by rw [hop0] at hop; cases hop; exact hdep0) (sizeOf_obj_lt hargs)
          (by rw [hX, attach_map_eq as (fun x => Out.at c.sf 1 (pr c x))])
      · rename_i hne
        exact absurd (hne o0 as0 hop0 hargs0) id
    have fbOpn : ∀ X : Out, pr c (.obj kvs) = X →
        X = (match look "op" kvs, _hk : look "args" kvs with
          | some (.str o), some (.arr as) =>
            if !(coreOps.contains o) && opnOK o && (tparams c.S o).isNone &&
                (fieldsOf kvs).all (fun kv => keyOK kv.1) then
              mkOut c.sf 10 (openToks c.sf o (as.attach.map fun x => (pr c x.1).at c.sf 4)
                ((fieldsOf kvs).attach.map fun x =>
                  keyToks c.sf x.1.1 ++ .kw .eq :: (if isE x.1.2 then (pr c x.1.2).at c.sf 4 else jsonVal c.sf x.1.2)))
            else (match look "op" kvs, _hk : look "args" kvs with
              | some (.str o), some (.arr as) =>
                mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.attach.map fun x => (pr c x.1).at c.sf 1))
              | _, _ => mkOut c.sf 10 [])
          | _, _ => (match look "op" kvs, _hk : look "args" kvs with
              | some (.str o), some (.arr as) =>
                mkOut c.sf 10 (escToks c.sf o (fieldsOf kvs) (as.attach.map fun x => (pr c x.1).at c.sf 1))
              | _, _ => mkOut c.sf 10 [])) → V c (.obj kvs) := by
      intro X hX hXe
      rw [hXe] at hX
      split at hX
      · rename_i o as hop hargs
        split at hX
        · rename_i hcond
          simp only [Bool.and_eq_true, Bool.not_eq_true', Option.isNone_iff_eq_none,
            List.all_eq_true] at hcond
          obtain ⟨⟨⟨hc1, hc2⟩, hc3⟩, hc4⟩ := hcond
          refine V.openop kvs o as hop hargs hs0 (isE_args h hargs) hf0 hc1 hc2 hc3 hc4
            (sizeOf_obj_lt hargs) sizeOf_fields_lt ?_
          rw [hX, attach_map_eq as (fun x => Out.at c.sf 4 (pr c x)),
            attach_map_eq (fieldsOf kvs) (fun kv =>
              keyToks c.sf kv.1 ++ .kw .eq :: (if isE kv.2 then (pr c kv.2).at c.sf 4 else jsonVal c.sf kv.2))]
        · simp only at hX
          exact V.esc kvs o as hop hargs hs0 (isE_args h hargs) hf0
            (by rw [hop0] at hop; cases hop; exact hok0) (by rw [hop0] at hop; cases hop; exact hrem0)
            (by rw [hop0] at hop; cases hop; exact hdep0) (sizeOf_obj_lt hargs)
            (by rw [hX, attach_map_eq as (fun x => Out.at c.sf 1 (pr c x))])
      · exact fbEsc _ hX rfl
    split at hpr
    · rename_i as o
      have hx : ∀ a ∈ as, isE a = true := isE_node h
      split at hpr
      next a ho => exact V.neg o a ho (hx a (by simp)) hpr
      next a b ho => exact V.minus o a b ho (hx a (by simp)) (hx b (by simp)) hpr
      next a b ho => exact V.div o a b ho (hx a (by simp)) (hx b (by simp)) hpr
      next a b ho => exact V.pow o a b ho (hx a (by simp)) (hx b (by simp)) hpr
      next a ho => exact V.lnot o a ho (hx a (by simp)) hpr
      next ho => exact V.tru o ho hpr
      next ho => exact V.fls o ho hpr
      next cnd a b ho => exact V.ite o cnd a b ho (hx cnd (by simp)) (hx a (by simp)) (hx b (by simp)) hpr
      next k a ho => exact V.un o k a ho (hx a (by simp)) hpr
      next n ho =>
        split at hpr
        · rename_i hn; exact V.ic o n ho hn hpr
        · exact fbEsc _ hpr rfl
      next base i is ho =>
        have hb : isE base = true := hx base (by simp)
        have his : ∀ x ∈ i :: is, isE x = true := fun x hx' => hx x (List.mem_cons_of_mem _ hx')
        split at hpr
        · rename_i hsub
          cases base with
          | str b =>
            exact V.idxSub o b (i :: is) ho (by simp) hsub his
              (by unfold node; rw [hpr, attach_map_eq (i :: is) (fun x => Out.at c.sf 1 (pr c x))])
          | _ => simp [subOK] at hsub
        · exact V.idxBr o base (i :: is) ho (by simp) hb his
            (by unfold node; rw [hpr, attach_map_eq (i :: is) (fun x => Out.at c.sf 1 (pr c x))])
      next k a b ho => exact V.cmp o k a b ho (hx a (by simp)) (hx b (by simp)) hpr
      next _ _ ho =>
        split at hpr
        · rename_i hl
          exact V.plus o _ ho hl hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 5 (pr c x))])
        · exact fbOpn _ hpr rfl
      next _ _ ho =>
        split at hpr
        · rename_i hl
          exact V.times o _ ho hl hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 6 (pr c x))])
        · exact fbOpn _ hpr rfl
      next _ _ ho =>
        split at hpr
        · rename_i hl
          exact V.land o _ ho hl hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 3 (pr c x))])
        · exact fbOpn _ hpr rfl
      next _ _ ho =>
        split at hpr
        · rename_i hl
          exact V.lor o _ ho hl hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 2 (pr c x))])
        · exact fbOpn _ hpr rfl
      next _ k ho =>
        split at hpr
        · rename_i hl
          exact V.mm o _ _ ho hl hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 1 (pr c x))])
        · exact fbOpn _ hpr rfl
      next _ ho =>
        exact V.call o _ ho hx (by unfold node; rw [hpr, attach_map_eq _ (fun x => Out.at c.sf 4 (pr c x))])
      next => exact fbOpn _ hpr rfl
    · rename_i as w
      have hx : ∀ a ∈ as, isE a = true := isE_args h (by simp [look])
      split at hpr
      · rename_i a
        split at hpr
        · rename_i hw; subst hw
          exact V.dTime a (hx a (by simp)) hpr
        · rename_i hw
          split at hpr
          · rename_i hwn
            exact V.dSpace w a hw hwn (hx a (by simp)) hpr
          · exact fbEsc _ hpr rfl
      · rename_i a b r
        split at hpr
        · rename_i hw
          exact V.dCall w (a :: b :: r) hw.1 hw.2 (by simp) hx
            (by unfold dCallNode; rw [hpr, attach_map_eq (a :: b :: r) (fun x => Out.at c.sf 4 (pr c x))])
        · exact fbEsc _ hpr rfl
      · exact fbEsc _ hpr rfl
    · rename_i u n
      split at hpr
      · rename_i hu
        have hn : n.WF := by
          have := hf0 ("value", .num n) (by simp [fieldsOf])
          simpa [jwf, numOK_iff] using this
        exact V.qty u n hn hu hpr
      · exact fbEsc _ hpr rfl
    · rename_i bs n
      split at hpr
      · rename_i hcond
        simp only [Bool.and_eq_true, List.all_eq_true] at hcond
        obtain ⟨⟨hn, hs⟩, hb⟩ := hcond
        split at hpr
        · rename_i ps hps
          exact V.tpos n bs ps hn hs hb hps
            (by unfold tNode; rw [hpr, attach_map_eq bs (fun kv => (kv.1, Out.at c.sf 4 (pr c kv.2)))])
        · rename_i hps
          split at hpr
          · rename_i hne
            simp only [Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true] at hne
            have hkn : (bs.map Prod.fst).Nodup := by
              have := hf0 ("bindings", .obj bs) (by simp [fieldsOf])
              simp only [jwf, Bool.and_eq_true, decide_eq_true_eq] at this
              exact this.1
            refine V.tnamed n bs hn hb hps hne.1 hne.2 hkn ?_
            unfold tNode; rw [hpr, attach_map_eq bs (fun kv => (kv.1, Out.at c.sf 4 (pr c kv.2))), List.map_map]
            rfl
          · exact fbEsc _ hpr rfl
      · exact fbEsc _ hpr rfl
    · exact fbOpn _ hpr rfl
  | .null, h => by simp [isE] at h
  | .bool _, h => by simp [isE] at h
  | .arr _, h => by simp [isE] at h

end Esm.Document.Math
