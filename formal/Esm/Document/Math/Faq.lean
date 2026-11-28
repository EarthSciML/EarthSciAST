import Esm.Document.Math.Arrays

/-!
# Round trip, case by case: reductions (`faq`), rows
-/

namespace Esm.Document.Math

open Esm.Document

/-- The tokens a row or an entry may end at. -/
def EndTok (k : Kw) : Prop := k = .nl ∨ k = .rb ∨ k = .rp ∨ k = .comma

theorem endTok_fol {sf : Sf} {k : Kw} (h : EndTok k) (L : Nat) (hL : 1 ≤ L) (r : List Tok) :
    Fol sf L (.kw k :: r) :=
  (fol1_kw sf k (by rcases h with rfl | rfl | rfl | rfl <;> simp) r).mono hL

theorem endTok_stop {sf : Sf} {k : Kw} (h : EndTok k) (r : List Tok) : NameStop sf (.kw k :: r) :=
  nameStop_kw sf k (by rcases h with rfl | rfl | rfl | rfl <;> decide)
    (by rcases h with rfl | rfl | rfl | rfl <;> decide) r

theorem endTok_ne_lp {k : Kw} (h : EndTok k) : k ≠ .lp := by
  rcases h with rfl | rfl | rfl | rfl <;> decide

theorem at_name_L (c : Ctx) (k : String) (L : Nat) (hL : L ≤ 10) : (pr c (.str k)).at c.sf L = nameToks c k := by
  rw [pr_str, at_eq]; simp [mkOut, hL]

theorem pAdd_name (c : Ctx) (k : String) (hk : nameOK k = true) (X : List Tok) (hX : Fol c.sf 4 X) (f : Nat)
    (hf : need 4 (nameToks c k).length ≤ f) : pAdd c f (nameToks c k ++ X) = some (.str k, X) := by
  have := PL_at (M_name c k hk) 4 (by omega) (by omega) X hX f (by rw [at_name_L c k 4 (by omega)]; exact hf)
  rwa [pLvl4, at_name_L c k 4 (by omega)] at this

theorem pAdd_at {c : Ctx} {a : Json} (ha : M c a) (X : List Tok) (hX : Fol c.sf 4 X) (f : Nat)
    (hf : need 4 ((pr c a).at c.sf 4).length ≤ f) : pAdd c f ((pr c a).at c.sf 4 ++ X) = some (a, X) := by
  have := PL_at ha 4 (by omega) (by omega) X hX f hf
  rwa [pLvl4] at this

theorem fol4_kw (sf : Sf) (k : Kw) (hk : k = .le ∨ k = .inn ∨ k = .eq) (r : List Tok) : Fol sf 4 (.kw k :: r) :=
  fol_kw sf 4 k r (by rcases hk with rfl | rfl | rfl <;> simp [conts, atomStart, isCmpTok, cmpOf])

/-- `pOr` over a comparison whose right side is followed by something that does not
continue an `and` or `or` chain. -/
theorem pOr_cmp (c : Ctx) (f : Nat) (ts r r' : List Tok) (x y : Json) (k : Kw) (o : String)
    (h1 : pAdd c (f + 1) ts = some (x, .kw k :: r)) (hk : cmpOf k = some o)
    (h2 : pAdd c f r = some (y, r')) (hl : ∀ r'', r' ≠ .kw .land :: r'') (ho : ∀ r'', r' ≠ .kw .lor :: r'') :
    pOr c (f + 4) ts = some (node o [x, y], r') := by
  rw [pOr, pAnd, pCmp, h1]; simp only
  rw [cmpLoop.eq_2, hk]; simp only; rw [h2]; simp only
  rw [andLoop.eq_3 _ _ _ _ (fun r'' e => hl r'' e)]; simp only
  rw [orLoop.eq_3 _ _ _ _ (fun r'' e => ho r'' e)]
  rfl

theorem pOr_noncmp (c : Ctx) (f : Nat) (ts r : List Tok) (x : Json) (k : Kw)
    (h1 : pAdd c (f + 1) ts = some (x, .kw k :: r)) (hk : cmpOf k = none) (hl : k ≠ .land) (ho : k ≠ .lor) :
    pOr c (f + 4) ts = some (x, .kw k :: r) := by
  rw [pOr, pAnd, pCmp, h1]; simp only
  rw [cmpLoop.eq_2, hk]; simp only
  rw [andLoop.eq_3 _ _ _ _ (fun r'' e => hl (by cases e; rfl))]; simp only
  rw [orLoop.eq_3 _ _ _ _ (fun r'' e => ho (by cases e; rfl))]
  rfl

/-! ## Rows -/

theorem pRow_filter {c : Ctx} {x : Json} (hx : M c x) (isEnd : Tok → Bool) (E : Kw) (hE : EndTok E)
    (hi : isEnd (.kw E) = true) (R : List Tok) (f : Nat) (hf : need 1 ((pr c x).at c.sf 1).length ≤ f) :
    pRow c (f + 1) isEnd ((pr c x).at c.sf 1 ++ .kw E :: R) = some (.filt x, .kw E :: R) := by
  have h := PL_at hx 1 (le_refl _) (by omega) _ (endTok_fol hE 1 (le_refl _) R) f hf
  rw [pLvl1] at h
  rw [pRow, h]; simp [hi]

theorem pRow_name (c : Ctx) (k : String) (hk : nameOK k = true) (isEnd : Tok → Bool) (E : Kw) (hE : EndTok E)
    (hi : isEnd (.kw E) = true) (R : List Tok) (f : Nat) (hf : need 1 (nameToks c k).length ≤ f) :
    pRow c (f + 1) isEnd (nameToks c k ++ .kw E :: R) = some (.filt (.str k), .kw E :: R) := by
  have := pRow_filter (M_name c k hk) isEnd E hE hi R f (by rw [at_name_L c k 1 (by omega)]; exact hf)
  rwa [at_name_L c k 1 (by omega)] at this

theorem pRow_one (c : Ctx) (isEnd : Tok → Bool) (E : Kw) (hE : EndTok E)
    (hi : isEnd (.kw E) = true) (R : List Tok) (f : Nat) (hf : need 1 1 ≤ f) :
    pRow c (f + 1) isEnd ([.num (.int 1)] ++ .kw E :: R) = some (.filt (.num (.int 1)), .kw E :: R) := by
  have hat : (pr c (.num (.int 1))).at c.sf 1 = [.num (.int 1)] := by
    rw [pr_num, at_eq]; simp [mkOut]; split <;> simp
  have := pRow_filter (M_num c (.int 1)) isEnd E hE hi R f (by rw [hat]; exact hf)
  rwa [hat] at this

theorem pNames_read (c : Ctx) (X : List Tok) (hX : NameStop c.sf X) (hc : ∀ r, X ≠ .kw .comma :: r) :
    ∀ (ps : List String), ps ≠ [] → (∀ p ∈ ps, nameOK p = true) → ∀ f, ps.length ≤ f →
      pNames c.sf (f + 1) (sepBy [.kw .comma] (ps.map (nameToks c)) ++ X) = some (ps, X)
  | [], h, _, _, _ => absurd rfl h
  | [p], _, hp, f, _ => by
    simp only [List.map_cons, List.map_nil, sepBy]
    rw [pNames, pName_nameToks c p (hp p (by simp)) X hX]
    split
    · rename_i n r heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
      exact absurd heq.2 (hc r)
    · rename_i n r _ heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl⟩ := heq; rfl
    · rename_i heq; cases heq
  | p :: q :: ps, _, hp, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    simp only [List.map_cons, sepBy_cons2, List.append_assoc, List.cons_append, List.nil_append]
    have ih := pNames_read c X hX hc (q :: ps) (by simp) (fun z hz => hp z (by simp [hz])) g (by simp at hf ⊢; omega)
    simp only [List.map_cons] at ih
    rw [pNames, pName_nameToks c p (hp p (by simp)) _ (nameStop_kw c.sf .comma (by decide) (by decide) _)]
    simp only
    rw [ih]; rfl

theorem of_strs : ∀ (ps : List Json), ps.all (fun p => match p with | .str q => nameOK q | _ => false) = true →
    ∃ qs : List String, ps = qs.map .str ∧ ∀ q ∈ qs, nameOK q = true
  | [], _ => ⟨[], rfl, by simp⟩
  | .str q :: r, h => by
    simp only [List.all_cons, Bool.and_eq_true] at h
    obtain ⟨qs, e, hq⟩ := of_strs r h.2
    exact ⟨q :: qs, by simp [e], by simp only [List.mem_cons, forall_eq_or_imp]; exact ⟨h.1, hq⟩⟩
  | .null :: _, h | .bool _ :: _, h | .num _ :: _, h | .arr _ :: _, h | .obj _ :: _, h
  | .math _ :: _, h => by simp at h

/-! ## Index set names -/

/-- `pSeg` never reads an upright word that `upSet` sets upright: it reads an upright
token only as a formula, and `upSet` excludes formulas. -/
theorem pSeg_upSet (sf : Sf) (g : String) (r : List Tok) (h : upSet sf g.toList = true) :
    pSeg sf (.ups [(g, "")] :: r) = none := by
  simp only [upSet, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at h
  obtain ⟨⟨⟨⟨hsf, -⟩, -⟩, -⟩, hf⟩ := h
  simp [pSeg, formulaOf, hsf, hf]

/-- The set-segment reader extends the name-segment reader. -/
theorem pSetSeg_of_pSeg (sf : Sf) (ts : List Tok) (p : List Char × List Tok)
    (h : pSeg sf ts = some p) : pSetSeg sf ts = some p := by
  unfold pSetSeg
  split
  · rename_i g r
    split
    · rename_i hu; rw [pSeg_upSet sf g r hu] at h; simp at h
    · exact h
  · exact h

theorem setSeg_read (sf : Sf) (g : List Char) (hg : segOK g = true) (rest : List Tok)
    (hr : subPat sf rest = false) : pSetSeg sf (setSegToks sf g ++ rest) = some (g, rest) := by
  unfold setSegToks
  split
  · rename_i hu
    simp [pSetSeg, String.toList_ofList, hu]
  · exact pSetSeg_of_pSeg sf _ _ (seg_read sf g hg rest hr)

theorem pSetLoop_stop (sf : Sf) (f : Nat) (acc : List Char) (rest : List Tok)
    (hr : ∀ r, rest ≠ .kw .sdot :: r) : pSetLoop sf (f + 1) acc rest = some (acc, rest) := by
  rw [pSetLoop]
  exact fun r h => hr r h

theorem setLoop_read (sf : Sf) : ∀ (gs : List (List Char)), (∀ g ∈ gs, segOK g = true) →
    ∀ (acc : List Char) (rest : List Tok) (f : Nat), NameStop sf rest → gs.length < f →
    pSetLoop sf f acc ((gs.flatMap fun g => .kw .sdot :: setSegToks sf g) ++ rest) =
      some (acc ++ gs.flatMap (fun g => '.' :: g), rest)
  | [], _, acc, rest, f, hr, hf => by
    obtain ⟨f', rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    simpa using pSetLoop_stop sf f' acc rest hr.1
  | g :: gs, hg, acc, rest, f, hr, hf => by
    obtain ⟨f', rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
    have hseg : pSetSeg sf (setSegToks sf g ++ ((gs.flatMap fun g => .kw .sdot :: setSegToks sf g) ++ rest)) =
        some (g, (gs.flatMap fun g => .kw .sdot :: setSegToks sf g) ++ rest) := by
      apply setSeg_read sf g (hg g (by simp))
      cases gs with
      | nil => simpa using hr.2
      | cons h hs => exact subPat_head _ _ _ (by simp)
    simp only [List.flatMap_cons, List.cons_append, List.append_assoc]
    rw [pSetLoop, hseg]
    simp only
    rw [setLoop_read sf gs (fun x hx => hg x (by simp [hx])) _ rest f' hr (by simp at hf; omega)]
    simp

theorem length_flatMap_sdot_set (sf : Sf) (gs : List (List Char)) :
    gs.length ≤ (gs.flatMap fun g => Tok.kw .sdot :: setSegToks sf g).length := by
  induction gs with
  | nil => simp
  | cons g gs ih => simp only [List.flatMap_cons, List.length_append, List.length_cons]; omega

/-- **Set names read back.** Each segment reads back, upright or as a name segment. -/
theorem pSet_setToks (c : Ctx) (s : String) (hs : nameOK s = true) (rest : List Tok)
    (hr : NameStop c.sf rest) : pSet c.sf (setToks c s ++ rest) = some (s, rest) := by
  unfold setToks
  split
  · simp only [List.cons_append, List.nil_append, pSet, pSetSeg, pSeg]
    rw [pSetLoop_stop c.sf _ _ rest hr.1]
    simp
  · have hsegs := splitDots_ne s.toList
    have hall : ∀ g ∈ splitDots s.toList, segOK g = true := by
      intro g hg; unfold nameOK at hs; exact List.all_eq_true.mp hs g hg
    obtain ⟨g, gs, hgs⟩ := List.exists_cons_of_ne_nil hsegs
    rw [hgs] at hall ⊢
    simp only [List.map_cons, sepBy_cons, List.flatMap_map, List.append_assoc]
    unfold pSet
    have h1 : pSetSeg c.sf (setSegToks c.sf g ++ ((gs.flatMap fun h => [Tok.kw .sdot] ++ setSegToks c.sf h) ++ rest)) =
        some (g, (gs.flatMap fun h => [Tok.kw .sdot] ++ setSegToks c.sf h) ++ rest) := by
      apply setSeg_read c.sf g (hall g (by simp))
      cases gs with
      | nil => simpa using hr.2
      | cons h hs => exact subPat_head _ _ _ (by simp)
    rw [h1]
    simp only [List.singleton_append]
    rw [setLoop_read c.sf gs (fun x hx => hall x (by simp [hx])) g rest _ hr
      (by have := length_flatMap_sdot_set c.sf gs; simp only [List.length_append]; omega)]
    simp only [Option.map_some]
    congr
    rw [← joinDots_cons', ← hgs, joinDots_splitDots, String.ofList_toList]

theorem rowToks_fromOf (c : Ctx) (P : Json → Out) (k s : String) (qs : List String) :
    rowToks c P (k, .obj [("from", .str s), ("of", .arr (qs.map .str))]) =
      nameToks c k ++ .kw .inn :: setToks c s ++ .kw .lp :: (sepBy [.kw .comma] (qs.map (nameToks c)) ++ [.kw .rp]) := by
  simp [rowToks, List.map_map, Function.comp_def]

/-- A printed range row reads back as that range, whatever follows it that neither continues
an expression nor a name nor opens a call. -/
theorem pRow_range_gen (c : Ctx) (P : Json → Out) (k : String) (v : Json) (hk : nameOK k = true)
    (hv : rangeOK v = true) (hM : ∀ a b, v = .arr [a, b] → M c a ∧ M c b ∧ P a = pr c a ∧ P b = pr c b)
    (isEnd : Tok → Bool) (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false)
    (X : List Tok) (hXf : Fol c.sf 4 X) (hXs : NameStop c.sf X) (hXlp : ∀ r, X ≠ .kw .lp :: r) (f : Nat)
    (hf : 30 * (rowToks c P (k, v)).length + 11 ≤ f) :
    pRow c (f + 1) isEnd (rowToks c P (k, v) ++ X) = some (.rng k v, X) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 4 := ⟨f - 4, by omega⟩
  unfold rangeOK at hv
  split at hv
  · rename_i a b
    obtain ⟨ha, hb, hPa, hPb⟩ := hM a b rfl
    have ht : rowToks c P (k, .arr [a, b]) =
        (pr c a).at c.sf 4 ++ .kw .le :: (nameToks c k ++ .kw .le :: (pr c b).at c.sf 4) := by
      simp [rowToks, hPa, hPb]
    rw [ht] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    simp only [List.append_assoc, List.cons_append]
    have hA := fun n (hn : need 4 ((pr c a).at c.sf 4).length ≤ n) =>
      pAdd_at ha (.kw .le :: (nameToks c k ++ .kw .le :: ((pr c b).at c.sf 4 ++ X)))
        (fol4_kw _ .le (Or.inl rfl) _) n hn
    have hK := fun n (hn : need 4 (nameToks c k).length ≤ n) =>
      pAdd_name c k hk (.kw .le :: ((pr c b).at c.sf 4 ++ X)) (fol4_kw _ .le (Or.inl rfl) _) n hn
    have hB := pAdd_at hb X hXf (g + 3) (by unfold need; omega)
    have hor := pOr_cmp c g _ _ _ a (.str k) .le "<=" (hA (g + 1) (by unfold need; omega)) rfl
      (hK g (by unfold need; omega)) (fun _ e => by cases e) (fun _ e => by cases e)
    rw [pRow, hor]; simp only [hle, Bool.false_eq_true, ↓reduceIte]
    rw [pRange, hA (g + 3) (by unfold need; omega)]
    simp only
    rw [hK (g + 3) (by unfold need; omega)]; simp only
    rw [hB]
  · rename_i s
    have ht : rowToks c P (k, .obj [("from", .str s)]) = nameToks c k ++ .kw .inn :: setToks c s := by
      simp [rowToks]
    rw [ht] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    simp only [List.append_assoc, List.cons_append]
    have hK := fun n (hn : need 4 (nameToks c k).length ≤ n) =>
      pAdd_name c k hk (.kw .inn :: (setToks c s ++ X)) (fol4_kw _ .inn (Or.inr (Or.inl rfl)) _) n hn
    have hor := pOr_noncmp c g _ _ (.str k) .inn (hK (g + 1) (by unfold need; omega)) rfl (by decide) (by decide)
    rw [pRow, hor]; simp only [hin, Bool.false_eq_true, ↓reduceIte]
    rw [pRange, hK (g + 3) (by unfold need; omega)]
    simp only
    rw [pSet_setToks c s hv _ hXs]
    split
    · rename_i heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
      exact absurd heq.2 (hXlp _)
    · rename_i n r2 _ heq; simp only [Option.some.injEq, Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl⟩ := heq; rfl
    · rename_i heq; cases heq
  · rename_i s ps
    simp only [Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff] at hv
    obtain ⟨⟨hs, hne⟩, hall⟩ := hv
    obtain ⟨qs, rfl, hq⟩ := of_strs ps hall
    have hqne : qs ≠ [] := by intro e; subst e; simp at hne
    rw [rowToks_fromOf] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    have hK := fun n (hn : need 4 (nameToks c k).length ≤ n) =>
      pAdd_name c k hk (.kw .inn :: (setToks c s ++ .kw .lp :: (sepBy [.kw .comma] (qs.map (nameToks c)) ++
        .kw .rp :: X))) (fol4_kw _ .inn (Or.inr (Or.inl rfl)) _) n hn
    have hor := pOr_noncmp c g _ _ (.str k) .inn (hK (g + 1) (by unfold need; omega)) rfl (by decide) (by decide)
    rw [pRow, hor]; simp only [hin, Bool.false_eq_true, ↓reduceIte]
    rw [pRange, hK (g + 3) (by unfold need; omega)]
    simp only
    rw [pSet_setToks c s hs _ (nameStop_kw c.sf .lp (by decide) (by decide) _)]
    simp only
    have hlen := length_le_sepBy [.kw .comma] (by simp) (qs.map (nameToks c)) (by
      intro x hx; obtain ⟨q, _, rfl⟩ := List.mem_map.1 hx
      obtain ⟨t, tr, he, -⟩ := nameToks_head c q; rw [he]; simp)
    rw [pNames_read c (.kw .rp :: X) (nameStop_kw c.sf .rp (by decide) (by decide) _)
      (fun _ e => by cases e) qs hqne hq _ (by simp at hlen ⊢; omega)]
  · cases hv

/-- A printed range row reads back as that range, before an end token. -/
theorem pRow_range (c : Ctx) (P : Json → Out) (k : String) (v : Json) (hk : nameOK k = true)
    (hv : rangeOK v = true) (hM : ∀ a b, v = .arr [a, b] → M c a ∧ M c b ∧ P a = pr c a ∧ P b = pr c b)
    (isEnd : Tok → Bool) (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false)
    (E : Kw) (hE : EndTok E) (R : List Tok) (f : Nat)
    (hf : 30 * (rowToks c P (k, v)).length + 11 ≤ f) :
    pRow c (f + 1) isEnd (rowToks c P (k, v) ++ .kw E :: R) = some (.rng k v, .kw E :: R) :=
  pRow_range_gen c P k v hk hv hM isEnd hle hin (.kw E :: R) (endTok_fol hE 4 (by omega) R)
    (endTok_stop hE R) (fun r e => by
      simp only [List.cons.injEq, Tok.kw.injEq] at e; exact endTok_ne_lp hE e.1) f hf

/-- Rows separated by `sep` and closed by `close` read back, each row as printed. -/
theorem pRows_read (c : Ctx) (sep close : Kw) (hsc : sep ≠ close) (R : List Tok) :
    ∀ (rs : List (Row × List Tok)), rs ≠ [] →
      (∀ p ∈ rs, ∀ E, (E = sep ∨ E = close) → ∀ R' f, 30 * p.2.length + 11 ≤ f →
        pRow c (f + 1) (fun t => isKw sep t || isKw close t) (p.2 ++ .kw E :: R') = some (p.1, .kw E :: R')) →
      ∀ f, 30 * (sepBy [.kw sep] (rs.map Prod.snd)).length + 12 ≤ f →
      pRows c (f + 1) sep close (sepBy [.kw sep] (rs.map Prod.snd) ++ .kw close :: R) = some (rs.map Prod.fst, R)
  | [], h, _, _, _ => absurd rfl h
  | [p], _, hp, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, List.map_nil, sepBy] at hf ⊢
    rw [pRows, hp p (by simp) close (Or.inr rfl) R g (by omega)]
    simp [Ne.symm hsc]
  | p :: q :: rs, _, hp, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, sepBy_cons2, List.length_append, List.length_cons] at hf ⊢
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    have ih := pRows_read c sep close hsc R (q :: rs) (by simp) (fun z hz => hp z (by simp [hz])) g
      (by simp only [List.map_cons] at hf ⊢; omega)
    simp only [List.map_cons] at ih
    rw [pRows, hp p (by simp) sep (Or.inl rfl) _ g (by omega)]
    simp only [↓reduceIte]
    rw [ih]; rfl

/-- Rows separated by commas, to the end of the input, read back, each row as printed. -/
theorem pTail_read (c : Ctx) :
    ∀ (rs : List (Row × List Tok)), rs ≠ [] →
      (∀ p ∈ rs, ∀ X, (X = [] ∨ ∃ R, X = .kw .comma :: R) → ∀ f, 30 * p.2.length + 11 ≤ f →
        pRow c (f + 1) (isKw .comma) (p.2 ++ X) = some (p.1, X)) →
      ∀ f, 30 * (sepBy [.kw .comma] (rs.map Prod.snd)).length + 12 ≤ f →
      pTail c (f + 1) (sepBy [.kw .comma] (rs.map Prod.snd)) = some (rs.map Prod.fst)
  | [], h, _, _, _ => absurd rfl h
  | [p], _, hp, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, List.map_nil, sepBy] at hf ⊢
    have h := hp p (by simp) [] (Or.inl rfl) g (by omega)
    rw [List.append_nil] at h
    rw [pTail, h]
  | p :: q :: rs, _, hp, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, sepBy_cons2, List.length_append, List.length_cons] at hf ⊢
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    have ih := pTail_read c (q :: rs) (by simp) (fun z hz => hp z (by simp [hz])) g
      (by simp only [List.map_cons] at hf ⊢; omega)
    simp only [List.map_cons] at ih
    rw [pTail, hp p (by simp) _ (Or.inr ⟨_, rfl⟩) g (by omega)]
    simp only
    rw [ih]; rfl

/-- The LaTeX subscript, as `pRedBody` reads it. -/
def rowsL (c : Ctx) (f : Nat) (ts : List Tok) : Option (List Row × List Tok) :=
  match ts with
  | .kw .us :: .kw .lb :: .kw .substack :: .kw .lb :: r =>
    match pRows c f .nl .rb r with
    | some (rs, .kw .rb :: r') => some (rs, r')
    | _ => none
  | .kw .us :: .kw .lb :: r =>
    match pRow c f (isKw .rb) r with
    | some (.filt (.obj [("args", .arr [.str k, a]), ("op", .str "==")]), .kw .rb :: .kw .caret :: .kw .lb :: r2) =>
      match r2 with
      | .kw .lset :: r3 =>
        some ([.filt (.obj [("args", .arr [.str k, a]), ("op", .str "==")])],
          .kw .caret :: .kw .lb :: .kw .lset :: r3)
      | _ =>
        match pOr c f r2 with
        | some (b, .kw .rb :: r3) => some ([.rng k (.arr [a, b])], r3)
        | _ => none
    | some (row, .kw .rb :: r2) => some ([row], r2)
    | _ => none
  | r => some ([], r)

/-- The Typst subscript, as `pRedBody` reads it. -/
def rowsT (c : Ctx) (f : Nat) (ts : List Tok) : Option (List Row × List Tok) :=
  match ts with
  | .kw .us :: .kw .lpg :: r => pRows c f .nl .rp r
  | r => some ([], r)

def bodyOf (c : Ctx) (f : Nat) (red : RedK) (marked : Bool) (rows : Option (List Row × List Tok)) :
    Option (FaqForm × List Tok) :=
  match rows with
  | some (rs, r) =>
    match rowParts rs, pSup c.sf r with
    | some (rg, fl), some (st, r1) =>
      if marked && !st.isEmpty then none
      else
        match pMul c f r1 with
        | some (body, r') => some (⟨red, marked, [], rg, body, fl, st⟩, r')
        | none => none
    | _, _ => none
  | none => none

/-- A marked operator shows no superscript set. -/
theorem marked_sup (F : FaqForm) : (F.marked && !F.sup.isEmpty) = false := by
  unfold FaqForm.sup; cases F.marked <;> simp

theorem pRedBody_latex {c : Ctx} (h : c.sf = .latex) (f : Nat) (red : RedK) (marked : Bool) (ts : List Tok) :
    pRedBody c (f + 1) red marked ts = bodyOf c f red marked (rowsL c f ts) := by
  rw [pRedBody.eq_def]; simp only [bodyOf]; rw [h]; rfl

theorem pRedBody_typst {c : Ctx} (h : c.sf = .typst) (f : Nat) (red : RedK) (marked : Bool) (ts : List Tok) :
    pRedBody c (f + 1) red marked ts = bodyOf c f red marked (rowsT c f ts) := by
  rw [pRedBody.eq_def]; simp only [bodyOf]; rw [h]; rfl

/-! ## The subscript -/

/-- What the round trip of a native `faq` knows of its parts. -/
structure FaqH (c : Ctx) (F : FaqForm) (P : Json → Out) : Prop where
  hE : M c F.expr
  hPe : P F.expr = pr c F.expr
  hFl : ∀ x, F.filter = some x → M c x ∧ P x = pr c x
  hR : ∀ kv ∈ F.ranges, nameOK kv.1 = true ∧ rangeOK kv.2 = true ∧
    ∀ a b, kv.2 = .arr [a, b] → M c a ∧ M c b ∧ P a = pr c a ∧ P b = pr c b

def faqRows (c : Ctx) (P : Json → Out) (F : FaqForm) : List (Row × List Tok) :=
  (redRanges F).map (fun kv => (Row.rng kv.1 kv.2, rowToks c P kv)) ++
    (match F.filter with | some x => [(Row.filt x, (P x).at c.sf 1)] | none => [])

theorem faqRows_snd (c : Ctx) (P : Json → Out) (F : FaqForm) :
    (faqRows c P F).map Prod.snd = subRows c P F := by
  unfold faqRows subRows
  cases F.filter <;> simp [Function.comp_def]

theorem rowParts_rng (l : List (String × Json)) (t : List Row) :
    rowParts (l.map (fun kv => Row.rng kv.1 kv.2) ++ t) = (rowParts t).map fun p => (l ++ p.1, p.2) := by
  induction l with
  | nil => simp only [List.map_nil, List.nil_append]; cases rowParts t <;> rfl
  | cons kv l ih => simp only [List.map_cons, List.cons_append, rowParts, ih]; cases rowParts t <;> simp

theorem faqRows_fst (c : Ctx) (P : Json → Out) (F : FaqForm) :
    rowParts ((faqRows c P F).map Prod.fst) = some (redRanges F, F.filter) := by
  unfold faqRows
  rw [List.map_append, List.map_map]
  have : ((fun x : Row × List Tok => x.1) ∘ fun kv : String × Json => (Row.rng kv.1 kv.2, rowToks c P kv)) =
      fun kv => Row.rng kv.1 kv.2 := rfl
  rw [this, rowParts_rng]
  cases F.filter <;> simp [rowParts]

theorem redRanges_mem {F : FaqForm} {kv : String × Json} (h : kv ∈ redRanges F) : kv ∈ F.ranges :=
  (List.mem_filter.1 h).1

/-- Every printed row starts as an expression does. -/
theorem faqRows_head {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) :
    ∀ p ∈ faqRows c P F, ∃ t r, p.2 = t :: r ∧ (startA t = true ∨ t = .kw .minus) := by
  intro p hp
  unfold faqRows at hp
  rcases List.mem_append.1 hp with hp | hp
  · obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hp
    obtain ⟨hk, hv, hM⟩ := h.hR kv (redRanges_mem hkv)
    simp only
    unfold rowToks
    split
    · rename_i a b hab
      obtain ⟨ha, -, hPa, -⟩ := hM a b hab
      rw [hPa]
      match hh : (pr c a).at c.sf 4, headOK_at ha 4 with
      | t :: r, ⟨_, _, _, _, _, h6⟩ => exact ⟨t, _, rfl, h6⟩
    · obtain ⟨t, tr, he, hh⟩ := nameToks_head c kv.1
      rw [he]; exact ⟨t, _, rfl, (nameHead_ok c kv.1 t tr hh).2.2.2.2.2⟩
    · obtain ⟨t, tr, he, hh⟩ := nameToks_head c kv.1
      rw [he]; exact ⟨t, _, rfl, (nameHead_ok c kv.1 t tr hh).2.2.2.2.2⟩
    · exfalso; unfold rangeOK at hv; split at hv <;> simp_all
  · split at hp
    · rename_i x hx
      simp at hp; subst hp
      obtain ⟨hm, hPx⟩ := h.hFl x hx
      rw [hPx]
      match hh : (pr c x).at c.sf 1, headOK_at hm 1 with
      | t :: r, ⟨_, _, _, _, _, h6⟩ => exact ⟨t, _, rfl, h6⟩
    · simp at hp

/-- Every printed row reads back, before any end token the row reader accepts. -/
theorem faqRows_ok {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (isEnd : Tok → Bool)
    (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false) :
    ∀ p ∈ faqRows c P F, ∀ E, EndTok E → isEnd (.kw E) = true → ∀ R f, 30 * p.2.length + 11 ≤ f →
      pRow c (f + 1) isEnd (p.2 ++ .kw E :: R) = some (p.1, .kw E :: R) := by
  intro p hp E hE hi R f hf
  unfold faqRows at hp
  rcases List.mem_append.1 hp with hp | hp
  · obtain ⟨kv, hkv, rfl⟩ := List.mem_map.1 hp
    obtain ⟨hk, hv, hM⟩ := h.hR kv (redRanges_mem hkv)
    exact pRow_range c P kv.1 kv.2 hk hv hM isEnd hle hin E hE R f hf
  · split at hp
    · rename_i x hx
      simp only [List.mem_singleton] at hp; subst hp
      obtain ⟨hm, hPx⟩ := h.hFl x hx
      simp only [hPx] at hf ⊢
      exact pRow_filter hm isEnd E hE hi R f (by unfold need; omega)
    · simp at hp

theorem faqRows_ne {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) :
    ∀ p ∈ faqRows c P F, p.2 ≠ [] := by
  intro p hp e
  obtain ⟨t, r, he, -⟩ := faqRows_head h p hp
  rw [e] at he; cases he

theorem head_ne_kw {t : Tok} (h : startA t = true ∨ t = .kw .minus) (k : Kw)
    (hk : k = .us ∨ k = .caret ∨ k = .substack ∨ k = .limitsL ∨ k = .lp ∨ k = .lset) : t ≠ .kw k := by
  rintro rfl
  rcases h with h | h
  · rcases hk with rfl | rfl | rfl | rfl | rfl | rfl <;> simp [startA, atomStart] at h
  · rcases hk with rfl | rfl | rfl | rfl | rfl | rfl <;> cases h

theorem body_head {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) :
    ∃ t r, (P F.expr).at c.sf 5 = t :: r ∧ (startA t = true ∨ t = .kw .minus) := by
  rw [h.hPe]
  match hh : (pr c F.expr).at c.sf 5, headOK_at h.hE 5 with
  | t :: r, ⟨_, _, _, _, _, h6⟩ => exact ⟨t, _, rfl, h6⟩

theorem pMul_body {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (rest : List Tok)
    (hr : Fol c.sf 5 rest) (f : Nat) (hf : need 5 ((P F.expr).at c.sf 5).length ≤ f) :
    pMul c f ((P F.expr).at c.sf 5 ++ rest) = some (F.expr, rest) := by
  rw [h.hPe] at hf ⊢
  have := PL_at h.hE 5 (by omega) (by omega) rest hr f hf
  rwa [pLvl5] at this

theorem subRows_nil {c : Ctx} {P : Json → Out} {F : FaqForm} (h : subRows c P F = []) :
    redRanges F = [] ∧ F.filter = none := by
  unfold subRows at h
  rw [List.append_eq_nil_iff] at h
  refine ⟨List.map_eq_nil_iff.1 h.1, ?_⟩
  have := h.2; split at this
  · simp at this
  · assumption

theorem faqRows_single {c : Ctx} {P : Json → Out} {F : FaqForm} {r : List Tok} (h : subRows c P F = [r]) :
    ∃ row, faqRows c P F = [(row, r)] := by
  rw [← faqRows_snd] at h
  match hh : faqRows c P F, h with
  | [(row, r')], e => simp at e; exact ⟨row, by rw [e]⟩

theorem len_ge {l : List Tok} {n : Nat} (h : n ≤ l.length) (X : List Tok) : n ≤ (l ++ X).length := by
  simp; omega

/-- What follows a reduction's subscript: its superscript set, or its body. -/
def AfterSub (Z : List Tok) : Prop :=
  (∃ t r, Z = t :: r ∧ (startA t = true ∨ t = .kw .minus)) ∨
    (∃ r, Z = .kw .caret :: .kw .lb :: .kw .lset :: r) ∨ (∃ r, Z = .kw .caret :: .kw .lpg :: .kw .lset :: r)

theorem afterSub_us {Z : List Tok} (h : AfterSub Z) : ∀ r, Z ≠ .kw .us :: r := by
  intro r e; subst e
  rcases h with ⟨t, r', e, ht⟩ | ⟨r', e⟩ | ⟨r', e⟩
  · simp only [List.cons.injEq] at e; obtain ⟨rfl, -⟩ := e
    rcases ht with ht | ht
    · simp [startA, atomStart] at ht
    · cases ht
  · cases e
  · cases e

theorem afterSub_caret {Z : List Tok} (h : AfterSub Z) (r2 : List Tok) (e : Z = .kw .caret :: .kw .lb :: r2) :
    ∃ r3, r2 = .kw .lset :: r3 := by
  subst e
  rcases h with ⟨t, r', e, ht⟩ | ⟨r', e⟩ | ⟨r', e⟩
  · simp only [List.cons.injEq] at e; obtain ⟨rfl, -⟩ := e
    rcases ht with ht | ht
    · simp [startA, atomStart] at ht
    · cases ht
  · simp only [List.cons.injEq] at e; exact ⟨r', e.2.2⟩
  · simp at e

theorem afterSub_of_head {Z : List Tok} {t : Tok} {r : List Tok} (e : Z = t :: r)
    (ht : startA t = true ∨ t = .kw .minus) : AfterSub Z := Or.inl ⟨t, r, e, ht⟩

/-- The LaTeX subscript reads back as its rows. -/
theorem rowsL_read {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (Z : List Tok)
    (hZ : AfterSub Z) (f : Nat) (hf : 30 * (subToksL c P F).length + 25 ≤ f) :
    rowsL c f (subToksL c P F ++ Z) = some ((faqRows c P F).map Prod.fst, Z) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 5 := ⟨f - 5, by omega⟩
  have hZus := afterSub_us hZ
  revert hf
  unfold subToksL
  split
  · rename_i k a b hred hfil hsup
    intro hf
    have hmem : (k, Json.arr [a, b]) ∈ F.ranges := redRanges_mem (by rw [hred]; simp)
    obtain ⟨hk, -, hM⟩ := h.hR _ hmem
    obtain ⟨ha, hb, hPa, hPb⟩ := hM a b rfl
    rw [hPa, hPb] at hf ⊢
    simp only [List.length_append, List.length_cons, List.length_nil] at hf
    obtain ⟨t, tr, he, hh⟩ := nameToks_head c k
    have ht : t ≠ .kw .substack := head_ne_kw (nameHead_ok c k t tr hh).2.2.2.2.2 _ (Or.inr (Or.inr (Or.inl rfl)))
    obtain ⟨tb, rbb, hbe, hbh⟩ : ∃ tb rbb, (pr c b).at c.sf 1 = tb :: rbb ∧ (startA tb = true ∨ tb = .kw .minus) := by
      match hh2 : (pr c b).at c.sf 1, headOK_at hb 1 with
      | t :: r, ⟨_, _, _, _, _, h6⟩ => exact ⟨t, r, rfl, h6⟩
    have hbl : tb ≠ .kw .lset := head_ne_kw hbh _ (by simp)
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    unfold rowsL
    split
    · rename_i r heq
      rw [he] at heq; simp at heq; exact absurd heq.1 ht
    · rename_i r heq
      simp only [List.cons.injEq, true_and] at heq; subst heq
      have hK := pAdd_name c k hk (.kw .eq :: ((pr c a).at c.sf 4 ++ .kw .rb :: .kw .caret :: .kw .lb ::
        ((pr c b).at c.sf 1 ++ .kw .rb :: Z))) (fol4_kw _ .eq (Or.inr (Or.inr rfl)) _)
        (g + 1) (by unfold need; omega)
      have hA := pAdd_at ha (.kw .rb :: .kw .caret :: .kw .lb ::
        ((pr c b).at c.sf 1 ++ .kw .rb :: Z)) (fol_kw _ 4 .rb _ (by simp [conts, atomStart]))
        g (by unfold need; omega)
      have hor := pOr_cmp c g _ _ _ (.str k) a .eq "==" hK rfl hA (fun _ e => by cases e) (fun _ e => by cases e)
      rw [pRow.eq_def]; simp only
      rw [show g + 4 = g + 4 from rfl, hor]
      simp only [isKw, beq_self_eq_true, ↓reduceIte, node]
      have hBb := PL_at hb 1 (le_refl _) (by omega) (.kw .rb :: Z)
        (fol1_kw _ .rb (by simp) _) (g + 5) (by unfold need; omega)
      rw [pLvl1] at hBb
      rw [hbe]
      simp only [List.cons_append]
      split
      · rename_i r3 heq3; simp only [List.cons.injEq] at heq3; exact absurd heq3.1 hbl
      · rw [← List.cons_append, ← hbe, hBb]
        unfold faqRows
        simp [hred, hfil]
    · rename_i hn1 hn2
      exfalso; exact hn2 _ rfl
  · rename_i hnl
    split
    · rename_i hrows
      intro hf
      obtain ⟨h1, h2⟩ := subRows_nil hrows
      simp only [List.nil_append]
      have : rowsL c (g + 5) Z = some ([], Z) := by
        unfold rowsL; split <;> first | (exfalso; simp_all; done) | rfl
      rw [this]; unfold faqRows; simp [h1, h2]
    · rename_i r hrows
      intro hf
      obtain ⟨row, hrow⟩ := faqRows_single hrows
      have hmem : (row, r) ∈ faqRows c P F := by rw [hrow]; simp
      obtain ⟨t, r'', he, hth⟩ := faqRows_head h _ hmem
      simp only at he
      have ht : t ≠ .kw .substack := head_ne_kw hth _ (Or.inr (Or.inr (Or.inl rfl)))
      simp only [List.length_append, List.length_cons, List.length_nil] at hf
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      unfold rowsL
      split
      · rename_i r1 heq; rw [he] at heq; simp at heq; exact absurd heq.1 ht
      · rename_i r1 heq
        simp only [List.cons.injEq, true_and] at heq; subst heq
        rw [faqRows_ok h (isKw .rb) rfl rfl (row, r) hmem .rb (Or.inr (Or.inl rfl)) rfl
          Z (g + 4) (by simp only; omega)]
        simp only
        rw [hrow]
        split
        · rename_i k a r2 heq2
          simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq, true_and] at heq2
          obtain ⟨rfl, rfl⟩ := heq2
          obtain ⟨r3, rfl⟩ := afterSub_caret hZ _ rfl
          rfl
        · rename_i row' r2 _ heq2
          simp only [Option.some.injEq, Prod.mk.injEq, List.cons.injEq, true_and] at heq2
          obtain ⟨rfl, rfl⟩ := heq2
          rfl
        · rename_i heq2; simp at heq2
      · rename_i hn1 hn2; exfalso; exact hn2 _ rfl
    · rename_i rs hne1 hne2
      intro hf
      have hrs : (faqRows c P F).map Prod.snd = subRows c P F := faqRows_snd c P F
      simp only [List.length_append, List.length_cons, List.length_nil] at hf
      simp only [List.append_assoc, List.cons_append, List.nil_append]
      unfold rowsL
      simp only
      have hne : faqRows c P F ≠ [] := by intro e; rw [e] at hrs; exact hne1 hrs.symm
      have hlen : (faqRows c P F).length ≤ (sepBy [.kw .nl] (subRows c P F)).length := by
        rw [← hrs]
        have := length_le_sepBy [.kw .nl] (by simp) ((faqRows c P F).map Prod.snd)
          (fun x hx => by obtain ⟨p, hp, rfl⟩ := List.mem_map.1 hx; exact faqRows_ne h p hp)
        simpa using this
      rw [← hrs, pRows_read c .nl .rb (by decide) (.kw .rb :: Z) (faqRows c P F) hne
        (fun p hp E hE R' f' hf' => faqRows_ok h _ rfl rfl p hp E
          (by rcases hE with rfl | rfl; exact Or.inl rfl; exact Or.inr (Or.inl rfl))
          (by rcases hE with rfl | rfl <;> rfl) R' f' hf') (g + 4)
        (by rw [hrs]; omega)]

/-- The Typst subscript reads back as its rows. -/
theorem rowsT_read {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (Z : List Tok)
    (hZus : ∀ r, Z ≠ .kw .us :: r) (f : Nat) (hf : 30 * (subToksT c P F).length + 25 ≤ f) :
    rowsT c f (subToksT c P F ++ Z) = some ((faqRows c P F).map Prod.fst, Z) := by
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 5 := ⟨f - 5, by omega⟩
  revert hf
  unfold subToksT
  split
  · rename_i hrows
    intro hf
    obtain ⟨h1, h2⟩ := subRows_nil hrows
    simp only [List.nil_append]
    have : rowsT c (g + 5) Z = some ([], Z) := by
      unfold rowsT; split <;> first | (exfalso; simp_all; done) | rfl
    rw [this]; unfold faqRows; simp [h1, h2]
  · rename_i rs hne1
    intro hf
    have hrs : (faqRows c P F).map Prod.snd = subRows c P F := faqRows_snd c P F
    simp only [List.length_append, List.length_cons, List.length_nil] at hf
    simp only [List.append_assoc, List.cons_append, List.nil_append]
    unfold rowsT
    simp only
    have hne : faqRows c P F ≠ [] := by intro e; rw [e] at hrs; exact hne1 hrs.symm
    have hlen : (faqRows c P F).length ≤ (sepBy [.kw .nl] (subRows c P F)).length := by
      rw [← hrs]
      have := length_le_sepBy [.kw .nl] (by simp) ((faqRows c P F).map Prod.snd)
        (fun x hx => by obtain ⟨p, hp, rfl⟩ := List.mem_map.1 hx; exact faqRows_ne h p hp)
      simpa using this
    rw [← hrs, pRows_read c .nl .rp (by decide) Z (faqRows c P F) hne
      (fun p hp E hE R' f' hf' => faqRows_ok h _ rfl rfl p hp E
        (by rcases hE with rfl | rfl; exact Or.inl rfl; exact Or.inr (Or.inr (Or.inl rfl)))
        (by rcases hE with rfl | rfl <;> rfl) R' f' hf') (g + 4)
      (by rw [hrs]; omega)]

/-- The superscript set a reduction or an output form carries, as printed: none, or the
set of names `st`. -/
def SupOK (c : Ctx) (S : List Tok) (st : List String) : Prop :=
  (S = [] ∧ st = []) ∨ (S = supToks c st ∧ st ≠ [] ∧ ∀ n ∈ st, nameOK n = true)

theorem pSup_nil (sf : Sf) (Y : List Tok) (hY : ∀ r, Y ≠ .kw .caret :: r) : pSup sf Y = some ([], Y) := by
  unfold pSup
  split <;> first | (exfalso; simp_all; done) | rfl

theorem names_len (c : Ctx) (st : List String) : st.length ≤ (sepBy [.kw .comma] (st.map (nameToks c))).length := by
  have := length_le_sepBy [.kw .comma] (by simp) (st.map (nameToks c)) (by
    intro x hx; obtain ⟨q, _, rfl⟩ := List.mem_map.1 hx
    obtain ⟨t, tr, he, -⟩ := nameToks_head c q; rw [he]; simp)
  simpa using this

theorem pSup_read (c : Ctx) (S : List Tok) (st : List String) (hS : SupOK c S st) (Y : List Tok)
    (hY : ∀ r, Y ≠ .kw .caret :: r) : pSup c.sf (S ++ Y) = some (st, Y) := by
  rcases hS with ⟨rfl, rfl⟩ | ⟨rfl, hne, hn⟩
  · exact pSup_nil c.sf Y hY
  · have hl := names_len c st
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · simp only [supToks, hsf, List.cons_append, List.append_assoc, List.nil_append]
      unfold pSup
      simp only
      rw [← hsf, pNames_read c (.kw .rset :: .kw .rb :: Y) (nameStop_kw _ _ (by decide) (by decide) _)
        (fun _ e => by cases e) st hne hn _ (by simp; omega)]
    · simp only [supToks, hsf, List.cons_append, List.append_assoc, List.nil_append]
      unfold pSup
      simp only
      rw [← hsf, pNames_read c (.kw .rset :: .kw .rp :: Y) (nameStop_kw _ _ (by decide) (by decide) _)
        (fun _ e => by cases e) st hne hn _ (by simp; omega)]

theorem supOK_supT (c : Ctx) (F : FaqForm) (hn : ∀ n ∈ F.set, nameOK n = true) : SupOK c (supT c F) F.sup := by
  unfold supT
  split
  · rename_i he; left; exact ⟨rfl, List.isEmpty_iff.1 he⟩
  · rename_i he
    right
    refine ⟨rfl, fun e => he (by rw [e]; rfl), fun n hm => hn n ?_⟩
    unfold FaqForm.sup at hm; split at hm
    · simp at hm
    · exact hm

theorem supOK_nil (c : Ctx) : SupOK c [] [] := Or.inl ⟨rfl, rfl⟩

theorem afterSub_sup {c : Ctx} {S : List Tok} {st : List String} (hS : SupOK c S st) (Y : List Tok)
    (hY : AfterSub Y) : AfterSub (S ++ Y) := by
  rcases hS with ⟨rfl, -⟩ | ⟨rfl, -, -⟩
  · exact hY
  · unfold supToks
    cases c.sf
    · exact Or.inr (Or.inl ⟨_, rfl⟩)
    · exact Or.inr (Or.inr ⟨_, rfl⟩)

theorem bodyOf_eq {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (S : List Tok) (st : List String)
    (hS : SupOK c S st) (red : RedK) (marked : Bool) (hms : (marked && !st.isEmpty) = false)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : need 5 ((P F.expr).at c.sf 5).length ≤ f) :
    bodyOf c f red marked (some ((faqRows c P F).map Prod.fst, S ++ ((P F.expr).at c.sf 5 ++ rest))) =
      some (⟨red, marked, [], redRanges F, F.expr, F.filter, st⟩, rest) := by
  obtain ⟨tb, rb', hbe, hbh⟩ := body_head h
  have hY : ∀ r, (P F.expr).at c.sf 5 ++ rest ≠ .kw .caret :: r := by
    rw [hbe]; intro r e
    simp only [List.cons_append, List.cons.injEq] at e
    exact head_ne_kw hbh _ (by simp) e.1
  unfold bodyOf
  simp only
  rw [faqRows_fst, pSup_read c S st hS _ hY]
  simp only [hms, Bool.false_eq_true, ↓reduceIte]
  rw [pMul_body h rest hr f hf]

/-- The subscript, the superscript set and the body read back. -/
theorem pRedBody_read {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (S : List Tok)
    (st : List String) (hS : SupOK c S st) (hms : (F.marked && !st.isEmpty) = false)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : 30 * (subToks c P F ++ (P F.expr).at c.sf 5).length + 25 ≤ f) :
    pRedBody c (f + 1) F.red F.marked (subToks c P F ++ (S ++ ((P F.expr).at c.sf 5 ++ rest))) =
      some (⟨F.red, F.marked, [], redRanges F, F.expr, F.filter, st⟩, rest) := by
  obtain ⟨tb, rb', hbe, hbh⟩ := body_head h
  have hZ : AfterSub (S ++ ((P F.expr).at c.sf 5 ++ rest)) :=
    afterSub_sup hS _ (afterSub_of_head (by rw [hbe]; rfl) hbh)
  simp only [List.length_append] at hf
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · have e : subToks c P F = subToksL c P F := by unfold subToks; rw [hsf]
    rw [e] at hf ⊢
    rw [pRedBody_latex hsf, rowsL_read h _ hZ f (by omega)]
    exact bodyOf_eq h S st hS F.red F.marked hms rest hr f (by unfold need; omega)
  · have e : subToks c P F = subToksT c P F := by unfold subToks; rw [hsf]
    rw [e] at hf ⊢
    rw [pRedBody_typst hsf, rowsT_read h _ (afterSub_us hZ) f (by omega)]
    exact bodyOf_eq h S st hS F.red F.marked hms rest hr f (by unfold need; omega)

/-! ## Operator, entries, ranges -/

theorem redOf_kw (r : RedK) : redOf r.kw = some r := by cases r <;> rfl

theorem pRedHead_plain (sf : Sf) (k : Kw) (red : RedK) (hk : redOf k = some red) (hk2 : k ≠ .limits)
    (X : List Tok) (hX : ∀ r, X ≠ .kw .limitsL :: r) : pRedHead sf (.kw k :: X) = some (red, false, X) := by
  unfold pRedHead
  split
  · rename_i k' r heq; simp only [List.cons.injEq, Tok.kw.injEq] at heq; exact absurd heq.1 hk2
  · rename_i k' r heq; simp only [List.cons.injEq] at heq; exact absurd heq.2 (hX r)
  · rename_i _ _ heq
    simp only [List.cons.injEq, Tok.kw.injEq] at heq
    obtain ⟨rfl, rfl⟩ := heq; rw [hk]; rfl
  · rename_i hn1 hn2 hn3; exact absurd rfl (hn3 k X)

theorem pRedHead_read (sf : Sf) (F : FaqForm) (X : List Tok) (hX : ∀ r, X ≠ .kw .limitsL :: r) :
    pRedHead sf (headToks sf F ++ X) = some (F.red, F.marked, X) := by
  cases sf with
  | latex =>
    unfold headToks
    cases hm : F.marked
    · simp only [Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
      exact pRedHead_plain _ _ _ (redOf_kw _) (by cases F.red <;> decide) X hX
    · simp only [↓reduceIte, List.cons_append, List.nil_append]
      cases F.red <;> rfl
  | typst =>
    unfold headToks
    cases hm : F.marked
    · simp only [Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
      exact pRedHead_plain _ _ _ (redOf_kw _) (by cases F.red <;> decide) X hX
    · simp only [↓reduceIte, List.cons_append, List.nil_append]
      cases F.red <;> rfl

/-- The range of an output index, when it has one. -/
def outRanges (F : FaqForm) : List (String × Json) :=
  F.out.filterMap fun j => match j with
    | .str k => (look k F.ranges).map ((k, ·))
    | _ => none

def entryRow (F : FaqForm) (j : Json) : Row :=
  match j with
  | .str k => match look k F.ranges with
    | some v => .rng k v
    | none => .filt (.str k)
  | _ => .filt (.num (.int 1))

theorem entryParts_out (F : FaqForm) (hO : ∀ j ∈ F.out, outOK j = true) :
    entryParts (F.out.map (entryRow F)) = some (F.out, outRanges F) := by
  unfold outRanges
  generalize F.out = out at hO ⊢
  induction out with
  | nil => rfl
  | cons j out ih =>
    have hj := hO j (by simp)
    have ih' := ih (fun x hx => hO x (by simp [hx]))
    unfold outOK at hj
    split at hj
    · rename_i k
      simp only [List.map_cons, entryRow, List.filterMap_cons]
      cases hl : look k F.ranges with
      | none => simp only [entryParts, ih', Option.map_some, Option.map_none]
      | some v => simp only [entryParts, ih', Option.map_some]
    · simp only [List.map_cons, entryRow, List.filterMap_cons, entryParts, ih', Option.map_some]
    · cases hj

theorem entry_row {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (j : Json) (hj : outOK j = true)
    (isEnd : Tok → Bool) (hle : isEnd (.kw .le) = false) (hin : isEnd (.kw .inn) = false)
    (E : Kw) (hE : EndTok E) (hi : isEnd (.kw E) = true) (R : List Tok) (f : Nat)
    (hf : 30 * (entryToks c P F j).length + 11 ≤ f) :
    pRow c (f + 1) isEnd (entryToks c P F j ++ .kw E :: R) = some (entryRow F j, .kw E :: R) := by
  unfold outOK at hj
  split at hj
  · rename_i k
    unfold entryToks entryRow at *
    simp only at hf ⊢
    cases hl : look k F.ranges with
    | none =>
      simp only [hl] at hf ⊢
      exact pRow_name c k hj isEnd E hE hi R f (by unfold need; omega)
    | some v =>
      simp only [hl] at hf ⊢
      obtain ⟨hk, hv, hM⟩ := h.hR (k, v) (look_mem hl)
      exact pRow_range c P k v hk hv hM isEnd hle hin E hE R f hf
  · unfold entryToks entryRow
    exact pRow_one c isEnd E hE hi R f (by unfold need; simp [entryToks] at hf; omega)
  · cases hj

theorem outRanges_keys (F : FaqForm) : List.Sublist ((outRanges F).map Prod.fst) (outNames F.out) := by
  unfold outRanges outNames
  generalize F.out = out
  induction out with
  | nil => simp
  | cons j out ih =>
    cases j with
    | str k =>
      cases hl : look k F.ranges with
      | none => simpa [List.filterMap_cons, hl] using ih.cons k
      | some v => simpa [List.filterMap_cons, hl] using ih.cons_cons k
    | null => simpa [List.filterMap_cons] using ih
    | bool _ => simpa [List.filterMap_cons] using ih
    | num _ => simpa [List.filterMap_cons] using ih
    | arr _ => simpa [List.filterMap_cons] using ih
    | obj _ => simpa [List.filterMap_cons] using ih
    | math _ => simpa [List.filterMap_cons] using ih

theorem mem_outNames {out : List Json} {k : String} : k ∈ outNames out ↔ Json.str k ∈ out := by
  unfold outNames
  simp only [List.mem_filterMap]
  constructor
  · rintro ⟨j, hj, he⟩
    split at he
    · simp at he; subst he; exact hj
    · cases he
  · intro h; exact ⟨_, h, rfl⟩

theorem ranges_rebuild (F : FaqForm) (hS : keysSorted F.ranges = true) (hNd : (outNames F.out).Nodup) :
    sortKV (outRanges F ++ redRanges F) = F.ranges := by
  have hp := keysSorted_pairwise F.ranges hS
  have hkn := keys_nodup hp
  let inP : String × Json → Bool := fun kv => (outNames F.out).contains kv.1
  have hrn : (outRanges F).Nodup :=
    List.Nodup.of_map Prod.fst ((outRanges_keys F).nodup hNd)
  have hfn : (F.ranges.filter inP).Nodup := (List.Nodup.of_map Prod.fst hkn).filter _
  have h1 : (outRanges F).Perm (F.ranges.filter inP) := by
    rw [List.perm_ext_iff_of_nodup hrn hfn]
    rintro ⟨k, v⟩
    simp only [List.mem_filter, inP, List.contains_iff_mem, mem_outNames]
    unfold outRanges
    simp only [List.mem_filterMap]
    constructor
    · rintro ⟨j, hj, he⟩
      split at he
      · rename_i k'
        obtain ⟨v', hv', he'⟩ := Option.map_eq_some_iff.1 he
        simp only [Prod.mk.injEq] at he'; obtain ⟨rfl, rfl⟩ := he'
        exact ⟨look_mem hv', hj⟩
      · cases he
    · rintro ⟨hm, hj⟩
      exact ⟨_, hj, by simp [look_of_mem hp hm]⟩
  have h2 : (F.ranges.filter inP ++ redRanges F).Perm F.ranges := by
    unfold redRanges
    exact List.filter_append_perm inP F.ranges
  have hperm : (outRanges F ++ redRanges F).Perm F.ranges := (h1.append_right _).trans h2
  refine eq_of_perm_sorted ((sortKV_perm _).trans hperm) (sortKV_sorted _ ?_) hp
  exact (hperm.map Prod.fst).nodup_iff.2 hkn

/-! ## The node -/

theorem M_of_toksL (c : Ctx) (e : Json) (L : Nat) (toks : List Tok)
    (hpr : pr c e = mkOut c.sf L toks) (h1 : 1 ≤ L) (h10 : L ≤ 10) (h4 : L ≠ 4)
    (hacc : addAcc e = [e]) (hh : HeadOK c toks)
    (hp : ∀ rest, Fol c.sf L rest → ∀ f, need 10 toks.length ≤ f →
      pPrim c f (toks ++ rest) = some (e, rest)) : M c e := by
  apply M_of
  · intro rest hr f hf
    rw [hpr] at hr hf ⊢; simp only [mkOut] at hr hf ⊢
    have := lift (c := c) (ts := toks ++ rest) (r := rest) (x := e) (N := need 10 toks.length) (10 - L) L h1
      (by omega) (by rw [show L + (10 - L) = 10 by omega]; exact fun f hf => hp rest hr f hf) hr f
      (by unfold need at hf ⊢; omega)
    exact this
  · rw [hpr]; exact hh
  · rw [hpr]; exact h1
  · rw [hpr]; exact h10
  · rw [hpr]; exact h4
  · exact hacc
  · rw [hpr]; rfl

theorem faqH_of (c : Ctx) (F : FaqForm) (hok : faqOK F = true) (P : Json → Out)
    (hP : ∀ x ∈ faqSubs F, P x = pr c x) (hM : ∀ x ∈ faqSubs F, M c x) : FaqH c F P := by
  have hok' := hok
  simp only [faqOK, Bool.and_eq_true, List.all_eq_true] at hok'
  obtain ⟨⟨⟨⟨⟨⟨-, -⟩, -⟩, -⟩, -⟩, -⟩, hR⟩ := hok'
  have hsub_e : F.expr ∈ faqSubs F := by simp [faqSubs]
  refine ⟨hM _ hsub_e, hP _ hsub_e, fun x hx => ?_, fun kv hkv => ?_⟩
  · have : x ∈ faqSubs F := by simp [faqSubs, hx]
    exact ⟨hM x this, hP x this⟩
  · have hk3 := hR kv hkv
    obtain ⟨⟨hk, hv⟩, -⟩ := hk3
    refine ⟨hk, hv, fun a b hab => ?_⟩
    have ha : a ∈ faqSubs F := by
      simp only [faqSubs, List.mem_append, List.mem_flatMap]; right; exact ⟨kv, hkv, by rw [hab]; simp⟩
    have hb : b ∈ faqSubs F := by
      simp only [faqSubs, List.mem_append, List.mem_flatMap]; right; exact ⟨kv, hkv, by rw [hab]; simp⟩
    exact ⟨hM a ha, hM b hb, hP a ha, hP b hb⟩

theorem redRanges_nil_out (F : FaqForm) (h : F.out = []) : redRanges F = F.ranges := by
  unfold redRanges outNames; rw [h]; simp

/-- Only `args` depends on `set`, and through `sup` alone. -/
theorem faqJson_sup (F : FaqForm) : faqJson { F with set := F.sup } = faqJson F := by
  cases F with
  | mk red marked out ranges expr filter set =>
    cases marked <;> rfl

theorem faqJson_eta (F : FaqForm) (h : F.out = []) :
    faqJson ⟨F.red, F.marked, [], redRanges F, F.expr, F.filter, F.sup⟩ = faqJson F := by
  rw [redRanges_nil_out F h, ← faqJson_sup F]
  cases F; simp only at h; subst h; rfl

theorem withOut_eta (F : FaqForm) (hS : keysSorted F.ranges = true) (hNd : (outNames F.out).Nodup) :
    faqJson (withSup (withOut ⟨F.red, F.marked, [], redRanges F, F.expr, F.filter, []⟩ F.out (outRanges F)) F.sup) =
      faqJson F := by
  unfold withOut withSup
  simp only
  rw [ranges_rebuild F hS hNd, ← faqJson_sup F]
  split
  · rename_i he
    have : F.sup = [] := List.isEmpty_iff.1 he
    rw [this]
  · rfl

theorem bracketSetOK_eta (F : FaqForm) :
    bracketSetOK ⟨F.red, F.marked, [], redRanges F, F.expr, F.filter, []⟩ F.sup = true := by
  unfold bracketSetOK
  have := marked_sup F
  simp only [List.isEmpty_nil, Bool.true_and] at this ⊢
  simp [this]

theorem addAcc_faq (F : FaqForm) : addAcc (faqJson F) = [faqJson F] := by
  unfold addAcc faqJson
  split
  · rename_i xs heq
    simp only [Json.obj.injEq, List.cons_append, List.cons.injEq, Prod.mk.injEq] at heq
    obtain ⟨-, h2⟩ := heq
    simp at h2
  · rfl

theorem headToks_cons (sf : Sf) (F : FaqForm) :
    ∃ k r, headToks sf F = .kw k :: r ∧ k ≠ .lbkg ∧ k ≠ .lr ∧ k ≠ .lp ∧ k ≠ .barr ∧ k ≠ .mat := by
  unfold headToks
  cases sf <;> cases F.marked <;> cases F.red <;> exact ⟨_, _, rfl, by decide, by decide, by decide, by decide, by decide⟩

theorem pPrim_red (c : Ctx) (F : FaqForm) (f : Nat) (t : Tok) (r : List Tok) (ht : t ≠ .kw .lp) :
    pPrim c (f + 1) (headToks c.sf F ++ t :: r) = pRed c f (headToks c.sf F ++ t :: r) := by
  unfold headToks
  cases c.sf <;> cases F.marked <;> cases F.red <;> simp only [Bool.false_eq_true, ↓reduceIte,
    List.cons_append, List.nil_append, RedK.kw] <;> rw [pPrim.eq_def] <;> simp only <;> rfl

theorem pPrim_lbkg (c : Ctx) (F : FaqForm) (f : Nat) (X : List Tok) :
    pPrim c (f + 1) (.kw .lbkg :: (headToks c.sf F ++ X)) = pRed c f (.kw .lbkg :: (headToks c.sf F ++ X)) := by
  unfold headToks
  cases c.sf <;> cases F.marked <;> cases F.red <;> simp only [Bool.false_eq_true, ↓reduceIte,
    List.cons_append, List.nil_append, RedK.kw] <;> rw [pPrim.eq_def]

theorem pRed_head (c : Ctx) (F : FaqForm) (f : Nat) (X : List Tok) :
    pRed c (f + 1) (headToks c.sf F ++ X) =
      match pRedHead c.sf (headToks c.sf F ++ X) with
      | some (red, marked, r1) => (pRedBody c f red marked r1).map fun p => (faqJson p.1, p.2)
      | none => none := by
  obtain ⟨k, r, hH, hk1, hk2, -⟩ := headToks_cons c.sf F
  rw [hH]
  rw [pRed.eq_def]
  simp only [List.cons_append]
  split
  · rename_i r' heq; simp only [List.cons.injEq, Tok.kw.injEq] at heq; exact absurd heq.1 hk1
  · rename_i r' heq; simp only [List.cons.injEq, Tok.kw.injEq] at heq; exact absurd heq.1 hk2
  · rfl

theorem sub_body_head {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P) (S : List Tok) (st : List String)
    (hS : SupOK c S st) (rest : List Tok) :
    ∃ t r, subToks c P F ++ (S ++ ((P F.expr).at c.sf 5 ++ rest)) = t :: r ∧ t ≠ .kw .lp ∧ t ≠ .kw .limitsL := by
  obtain ⟨tb, rb', hbe, hbh⟩ := body_head h
  have hS' : ∃ t r, S ++ ((P F.expr).at c.sf 5 ++ rest) = t :: r ∧ t ≠ .kw .lp ∧ t ≠ .kw .limitsL := by
    rcases hS with ⟨rfl, -⟩ | ⟨rfl, -, -⟩
    · rw [List.nil_append, hbe]
      exact ⟨tb, _, rfl, head_ne_kw hbh _ (by simp), head_ne_kw hbh _ (by simp)⟩
    · unfold supToks; cases c.sf <;> exact ⟨.kw .caret, _, rfl, by simp, by simp⟩
  obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
  · have e : subToks c P F = subToksL c P F := by unfold subToks; rw [hsf]
    rw [e]
    unfold subToksL
    split
    · exact ⟨.kw .us, _, rfl, by simp, by simp⟩
    · split
      · rw [List.nil_append]; exact hS'
      · exact ⟨.kw .us, _, rfl, by simp, by simp⟩
      · exact ⟨.kw .us, _, rfl, by simp, by simp⟩
  · have e : subToks c P F = subToksT c P F := by unfold subToks; rw [hsf]
    rw [e]
    unfold subToksT
    split
    · rw [List.nil_append]; exact hS'
    · exact ⟨.kw .us, _, rfl, by simp, by simp⟩

theorem headToks_len (sf : Sf) (F : FaqForm) : 1 ≤ (headToks sf F).length := by
  unfold headToks; cases sf <;> cases F.marked <;> simp

theorem headOK_faq (c : Ctx) (F : FaqForm) (X : List Tok) : HeadOK c (headToks c.sf F ++ X) := by
  unfold headToks
  cases c.sf <;> cases F.marked <;> cases F.red <;>
    simp only [Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append, RedK.kw] <;>
    exact hOK_kw c _ _ (by decide) (by decide) (by decide)

/-- The output entries read back as rows. -/
theorem pRows_entries {c : Ctx} {F : FaqForm} {P : Json → Out} (h : FaqH c F P)
    (hO : ∀ j ∈ F.out, outOK j = true) (hout : F.out ≠ []) (close : Kw) (hc : EndTok close)
    (hcc : close ≠ .comma) (R : List Tok) (f : Nat)
    (hf : 30 * (sepBy [.kw .comma] (F.out.map (entryToks c P F))).length + 12 ≤ f) :
    pRows c (f + 1) .comma close (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ .kw close :: R) =
      some (F.out.map (entryRow F), R) := by
  have := pRows_read c .comma close (Ne.symm hcc) R (F.out.map fun j => (entryRow F j, entryToks c P F j))
    (by simpa using hout) (by
      intro p hp E hE R' f' hf'
      obtain ⟨j, hj, rfl⟩ := List.mem_map.1 hp
      refine entry_row h j (hO j hj) _ (by simp [isKw]; rcases hc with rfl | rfl | rfl | rfl <;> decide)
        (by simp [isKw]; rcases hc with rfl | rfl | rfl | rfl <;> decide) E
        (by rcases hE with rfl | rfl <;> first | exact hc | exact Or.inr (Or.inr (Or.inr rfl)))
        (by rcases hE with rfl | rfl <;> simp [isKw]) R' f' hf')
      f (by simpa [List.map_map, Function.comp_def] using hf)
  simpa [List.map_map, Function.comp_def] using this

theorem faqOK_parts {F : FaqForm} (hok : faqOK F = true) :
    isE F.expr = true ∧ (match F.filter with | some x => isE x | none => true) = true ∧
      (∀ j ∈ F.out, outOK j = true) ∧ (outNames F.out).Nodup ∧ (∀ n ∈ F.set, nameOK n = true) ∧
      keysSorted F.ranges = true ∧ ∀ kv ∈ F.ranges, (nameOK kv.1 = true ∧ rangeOK kv.2 = true) ∧
        ((outNames F.out).contains kv.1 || occursJ kv.1 F.expr ||
          (match F.filter with | some x => occursJ kv.1 x | none => false)) = true := by
  simp only [faqOK, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at hok
  obtain ⟨⟨⟨⟨⟨⟨he, hf⟩, hO⟩, hNd⟩, hset⟩, hS⟩, hR⟩ := hok
  exact ⟨he, hf, hO, hNd, hset, hS, hR⟩

theorem faqSubs_isE {F : FaqForm} (hok : faqOK F = true) : ∀ x ∈ faqSubs F, isE x = true := by
  obtain ⟨he, hf, -, -, -, -, hR⟩ := faqOK_parts hok
  intro x hx
  simp only [faqSubs, List.mem_append, List.mem_flatMap] at hx
  rcases hx with (hx | hx) | ⟨kv, hkv, hx⟩
  · simp at hx; rw [hx]; exact he
  · revert hf hx; cases F.filter <;> simp_all
  · obtain ⟨⟨-, hv⟩, -⟩ := hR kv hkv
    revert hv hx; obtain ⟨k, v⟩ := kv
    simp only
    unfold rangeOK
    split <;> simp_all
    rintro ⟨-, -⟩ <;> simp_all

/-- A native `faq` reads back. -/
theorem M_faq (c : Ctx) (kvs : List (String × Json)) (F : FaqForm) (hF : faqForm kvs = some F)
    (hok : faqOK F = true) (P : Json → Out) (hP : ∀ x ∈ faqSubs F, P x = pr c x)
    (hpr : pr c (.obj kvs) = faqOut c P F) (hM : ∀ x ∈ faqSubs F, M c x) : M c (.obj kvs) := by
  have h := faqH_of c F hok P hP hM
  have hj := faqForm_json hF
  obtain ⟨-, -, hO, hNd, hset, hS, -⟩ := faqOK_parts hok
  have hSup := supOK_supT c F hset
  have hacc : addAcc (.obj kvs) = [.obj kvs] := by rw [← hj]; exact addAcc_faq F
  have hhl := headToks_len c.sf F
  by_cases hout : F.out = []
  · -- the reduction alone, level 5
    have hpr' : pr c (.obj kvs) = mkOut c.sf 5 (redToks c P F) := by rw [hpr]; unfold faqOut; simp [hout]
    refine M_of_toksL c _ 5 _ hpr' (by omega) (by omega) (by omega) hacc
      (by unfold redToks; simp only [List.append_assoc]; exact headOK_faq c F _) ?_
    intro rest hr f hf
    unfold redToks at hf ⊢
    simp only [hout, ↓reduceIte, List.length_append] at hf ⊢
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
    obtain ⟨t, r, he, ht1, ht2⟩ := sub_body_head h _ _ hSup rest
    rw [List.append_assoc, List.append_assoc, List.append_assoc, he, pPrim_red c F _ t r ht1, ← he, pRed_head,
      pRedHead_read c.sf F _ (by rw [he]; intro r' e; cases e; exact ht2 rfl)]
    simp only
    rw [pRedBody_read h _ _ hSup (marked_sup F) rest hr g (by simp only [List.length_append]; unfold need at hf; omega)]
    simp only [Option.map_some]
    rw [faqJson_eta F hout, hj]
  · have hbody : ∀ (Y : List Tok) (k : Kw), conts c.sf 5 (.kw k) = false → ∀ g,
        30 * (subToks c P F ++ (P F.expr).at c.sf 5).length + 25 ≤ g →
        pRedHead c.sf (headToks c.sf F ++ (subToks c P F ++ ([] ++ ((P F.expr).at c.sf 5 ++ .kw k :: Y)))) =
          some (F.red, F.marked, subToks c P F ++ ([] ++ ((P F.expr).at c.sf 5 ++ .kw k :: Y))) ∧
        pRedBody c (g + 1) F.red F.marked (subToks c P F ++ ([] ++ ((P F.expr).at c.sf 5 ++ .kw k :: Y))) =
          some (⟨F.red, F.marked, [], redRanges F, F.expr, F.filter, []⟩, .kw k :: Y) := by
      intro Y k hk g hg
      refine ⟨pRedHead_read c.sf F _ ?_, pRedBody_read h [] [] (supOK_nil c) (by simp) _ (fol_kw _ 5 k _ hk) g hg⟩
      obtain ⟨t, r, he, -, ht2⟩ := sub_body_head h [] [] (supOK_nil c) (.kw k :: Y)
      rw [he]; intro r' e; cases e; exact ht2 rfl
    have hsupN : ∀ Y, pSup c.sf (supT c F ++ .kw .us :: Y) = some (F.sup, .kw .us :: Y) :=
      fun Y => pSup_read c _ _ hSup _ (fun _ e => by cases e)
    have hlen : ∀ L, (if supT c F = [] then 10 else 8) = L → 8 ≤ L ∧ L ≤ 10 := by
      intro L e; split at e <;> omega
    obtain hsf | hsf : c.sf = .latex ∨ c.sf = .typst := by cases c.sf <;> simp
    · have hpr' : pr c (.obj kvs) = mkOut c.sf (if supT c F = [] then 10 else 8)
          ([.kw .lbkg] ++ redToks c P F ++ [.kw .rbkg] ++ supT c F ++ [.kw .us, .kw .lb] ++
          sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ [.kw .rb]) := by
        rw [hpr]; unfold faqOut; simp only [hout, ↓reduceIte]; rw [hsf]
      obtain ⟨hl8, hl10⟩ := hlen _ rfl
      refine M_of_toksL c _ _ _ hpr' (by omega) hl10 (by omega) hacc
        (hOK_kw c .lbkg _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      unfold redToks at hf ⊢
      simp only [hout, ↓reduceIte, List.length_append, List.length_cons, List.length_nil] at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
      obtain ⟨h1, h2⟩ := hbody (supT c F ++ .kw .us :: .kw .lb ::
          (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ .kw .rb :: rest))
        .rbkg (by simp [conts, atomStart]) g (by simp only [List.length_append]; unfold need at hf; omega)
      have h3 := pRows_entries h hO hout .rb (Or.inr (Or.inl rfl)) (by decide) rest g (by unfold need at hf; omega)
      simp only [List.nil_append] at h1 h2
      simp only [List.append_assoc, List.cons_append, List.nil_append, List.append_nil] at h1 h2 ⊢
      rw [pPrim_lbkg]
      rw [pRed.eq_def]; simp only
      rw [h1]; simp only
      rw [h2]; simp only
      rw [hsupN]; simp only
      rw [h3]; simp only [bracketSetOK_eta F, ↓reduceIte]
      rw [entryParts_out F hO]; simp only [Option.map_some]; rw [withOut_eta F hS hNd, hj]
    · have hpr' : pr c (.obj kvs) = mkOut c.sf (if supT c F = [] then 10 else 8)
          ([.kw .lr, .kw .lp, .kw .lbk] ++ redToks c P F ++ [.kw .rbk, .kw .rp] ++ supT c F ++
          [.kw .us, .kw .lpg] ++ sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ [.kw .rp]) := by
        rw [hpr]; unfold faqOut; simp only [hout, ↓reduceIte]; rw [hsf]
      obtain ⟨hl8, hl10⟩ := hlen _ rfl
      refine M_of_toksL c _ _ _ hpr' (by omega) hl10 (by omega) hacc
        (hOK_kw c .lr _ (by decide) (by decide) (by decide)) ?_
      intro rest hr f hf
      unfold redToks at hf ⊢
      simp only [hout, ↓reduceIte, List.length_append, List.length_cons, List.length_nil] at hf ⊢
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by unfold need at hf; omega⟩
      obtain ⟨h1, h2⟩ := hbody (.kw .rp :: (supT c F ++ .kw .us :: .kw .lpg ::
          (sepBy [.kw .comma] (F.out.map (entryToks c P F)) ++ .kw .rp :: rest)))
        .rbk (by simp [conts, atomStart]) g (by simp only [List.length_append]; unfold need at hf; omega)
      have h3 := pRows_entries h hO hout .rp (Or.inr (Or.inr (Or.inl rfl))) (by decide) rest g
        (by unfold need at hf; omega)
      have hsupT : ∀ Y, pSup c.sf (supT c F ++ .kw .us :: Y) = some (F.sup, .kw .us :: Y) := hsupN
      simp only [List.nil_append] at h1 h2
      simp only [List.append_assoc, List.cons_append, List.nil_append, List.append_nil] at h1 h2 ⊢
      rw [pPrim.eq_def]; simp only
      rw [pRed.eq_def]; simp only
      rw [h1]; simp only
      rw [h2]; simp only
      rw [hsupT]; simp only
      rw [h3]; simp only [bracketSetOK_eta F, ↓reduceIte]
      rw [entryParts_out F hO]; simp only [Option.map_some]; rw [withOut_eta F hS hNd, hj]

end Esm.Document.Math
