import Esm.Document.Math.OpenOp

/-!
# Round trip, case by case: expression templates

Positional arguments read back through the parameter list of the symbol table, and the
parser sorts the bindings; named arguments read back in the printed (sorted) order.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Sorting bindings -/

theorem insKV_perm (kv : String × Json) : ∀ l, (insKV kv l).Perm (kv :: l)
  | [] => List.Perm.refl _
  | e :: r => by
    simp only [insKV]; split
    · exact List.Perm.refl _
    · exact ((insKV_perm kv r).cons e).trans (List.Perm.swap kv e r)

theorem sortKV_perm : ∀ l, (sortKV l).Perm l
  | [] => List.Perm.refl _
  | kv :: r => (insKV_perm kv _).trans ((sortKV_perm r).cons kv)

theorem insKV_sorted (kv : String × Json) : ∀ l, l.Pairwise KeyLt → (∀ e ∈ l, e.1 ≠ kv.1) →
    (insKV kv l).Pairwise KeyLt
  | [], _, _ => List.pairwise_singleton _ _
  | e :: r, hp, hne => by
    simp only [insKV]; split
    · rename_i h
      refine List.pairwise_cons.2 ⟨fun b hb => ?_, hp⟩
      simp only [List.mem_cons] at hb
      rcases hb with rfl | hb
      · exact h
      · exact lt_trans h (List.rel_of_pairwise_cons hp hb)
    · rename_i h
      have hlt : e.1 < kv.1 := by
        rcases lt_trichotomy e.1 kv.1 with h1 | h1 | h1
        · exact h1
        · exact absurd h1 (hne e (by simp))
        · exact absurd h1 h
      refine List.pairwise_cons.2 ⟨fun b hb => ?_, insKV_sorted kv r (List.Pairwise.of_cons hp)
        (fun z hz => hne z (by simp [hz]))⟩
      have hb' := (insKV_perm kv r).mem_iff.1 hb
      simp only [List.mem_cons] at hb'
      rcases hb' with rfl | hb'
      · exact hlt
      · exact List.rel_of_pairwise_cons hp hb'

theorem sortKV_sorted : ∀ l, (l.map Prod.fst).Nodup → (sortKV l).Pairwise KeyLt
  | [], _ => List.Pairwise.nil
  | kv :: r, h => by
    simp only [List.map_cons, List.nodup_cons] at h
    refine insKV_sorted kv (sortKV r) (sortKV_sorted r h.2) (fun e he hk => h.1 ?_)
    rw [← hk]
    exact List.mem_map.2 ⟨e, (sortKV_perm r).mem_iff.1 he, rfl⟩

theorem eq_of_perm_sorted {l₁ l₂ : List (String × Json)} (hp : l₁.Perm l₂)
    (h₁ : l₁.Pairwise KeyLt) (h₂ : l₂.Pairwise KeyLt) : l₁ = l₂ :=
  List.Perm.eq_of_pairwise (fun _ _ _ _ a b => absurd (lt_trans a b) (lt_irrefl _)) h₁ h₂ hp

theorem keys_nodup {l : List (String × Json)} (h : l.Pairwise KeyLt) : (l.map Prod.fst).Nodup := by
  have : (l.map Prod.fst).Pairwise (· < ·) := List.pairwise_map.2 h
  exact this.imp ne_of_lt

theorem lookup_map_look (F : Json → List Tok) (p : String) :
    ∀ bs : List (String × Json), (bs.map fun kv => (kv.1, F kv.2)).lookup p = (look p bs).map F
  | [] => rfl
  | (k, v) :: r => by
    by_cases h : k = p
    · subst h; simp [look]
    · have h' : (p == k) = false := by simp [Ne.symm h]
      simp only [List.map_cons, List.lookup, h', look, h, ↓reduceIte]
      exact lookup_map_look F p r

theorem zip_map_self {β : Type} (g : String → β) : ∀ ps : List String,
    ps.zip (ps.map g) = ps.map fun p => (p, g p)
  | [] => rfl
  | p :: ps => by simp [zip_map_self g ps]

theorem tpos_perm (bs : List (String × Json)) (ps : List String) (hs : bs.Pairwise KeyLt)
    (hnd : ps.Nodup) (hl : ps.length = bs.length) (hall : ∀ p ∈ ps, (look p bs).isSome = true) :
    (ps.map fun p => (p, (look p bs).getD .null)).Perm bs := by
  have hbk : (bs.map Prod.fst).Nodup := keys_nodup hs
  have hbn : bs.Nodup := List.Nodup.of_map _ hbk
  have hsub : ps ⊆ bs.map Prod.fst := by
    intro p hp
    obtain ⟨v, hv⟩ := Option.isSome_iff_exists.1 (hall p hp)
    exact List.mem_map.2 ⟨(p, v), look_mem hv, rfl⟩
  have hperm : ps.Perm (bs.map Prod.fst) :=
    (List.subperm_of_subset hnd hsub).perm_of_length_le (by simp [hl])
  have hnd' : (ps.map fun p => (p, (look p bs).getD .null)).Nodup :=
    List.Nodup.map_on (fun a _ b _ h => by simpa using congrArg Prod.fst h) hnd
  rw [List.perm_ext_iff_of_nodup hnd' hbn]
  rintro ⟨k, v⟩
  constructor
  · intro h
    obtain ⟨p, hp, he⟩ := List.mem_map.1 h
    simp only [Prod.mk.injEq] at he; obtain ⟨rfl, rfl⟩ := he
    obtain ⟨w, hw⟩ := Option.isSome_iff_exists.1 (hall p hp)
    rw [hw]; exact look_mem hw
  · intro h
    have hk : k ∈ ps := hperm.mem_iff.2 (List.mem_map.2 ⟨(k, v), h, rfl⟩)
    refine List.mem_map.2 ⟨k, hk, ?_⟩
    rw [look_of_mem hs h]; rfl

/-! ## Reserved names -/

theorem tname_facts {n : String} (hn : tnameOK n = true) :
    callOps.contains n = false ∧ n ≠ "neg" ∧ n ≠ "pow" ∧ n ≠ "D" ∧ removedOps.contains n = false := by
  have hr : reservedOpn.contains n = false := by
    simp only [tnameOK, Bool.and_eq_true, Bool.not_eq_true'] at hn; exact hn.2
  simp only [reservedOpn, List.contains_append, Bool.or_eq_false_iff] at hr
  obtain ⟨⟨h1, h2⟩, h3⟩ := hr
  refine ⟨h1, ?_, ?_, ?_, h3⟩ <;> (rintro rfl; exact absurd h2 (by decide))

/-! ## Positional arguments -/

theorem M_tpos (c : Ctx) (n : String) (bs : List (String × Json)) (ps : List String)
    (hn : tnameOK n = true) (hs : keysSorted bs = true) (hM : ∀ kv ∈ bs, M c kv.2)
    (hps : positional c.S n bs = some ps)
    (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n]
        (ps.map fun p => ((bs.map fun kv => (kv.1, (pr c kv.2).at c.sf 4)).lookup p).getD []))) :
    M c (tNode n bs) := by
  obtain ⟨hco, hneg, hpow, hD, hrem⟩ := tname_facts hn
  have hsp := keysSorted_pairwise bs hs
  obtain ⟨htp, hnd, hl, hall⟩ : tparams c.S n = some ps ∧ ps.Nodup ∧ ps.length = bs.length ∧
      ∀ p ∈ ps, (look p bs).isSome = true := by
    unfold positional at hps
    split at hps
    · rename_i ps' hps'
      split at hps
      · rename_i h; cases hps
        simp only [List.all_eq_true] at h
        exact ⟨hps', h.1, h.2.1, h.2.2⟩
      · cases hps
    · cases hps
  let xs := ps.map fun p => (look p bs).getD .null
  have hargs : (ps.map fun p => ((bs.map fun kv => (kv.1, (pr c kv.2).at c.sf 4)).lookup p).getD []) =
      xs.map fun x => (pr c x).at c.sf 4 := by
    simp only [xs, List.map_map]
    apply List.map_congr_left
    intro p hp
    obtain ⟨v, hv⟩ := Option.isSome_iff_exists.1 (hall p hp)
    rw [lookup_map_look (fun x => (pr c x).at c.sf 4)]; simp [hv]
  have hxM : ∀ x ∈ xs, M c x := by
    intro x hx
    obtain ⟨p, hp, rfl⟩ := List.mem_map.1 hx
    obtain ⟨v, hv⟩ := Option.isSome_iff_exists.1 (hall p hp)
    rw [hv]; exact hM _ (look_mem hv)
  have hsort : sortKV (ps.zip xs) = bs := by
    simp only [xs]
    rw [zip_map_self]
    have hp := tpos_perm bs ps hsp hnd hl hall
    refine eq_of_perm_sorted ((sortKV_perm _).trans hp) (sortKV_sorted _ ?_) hsp
    simp only [List.map_map, Function.comp_def, List.map_id']; exact hnd
  rw [hargs] at hpr
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by rw [hpr] at hf; unfold need at hf; simp [mkOut, length_callToks] at hf; omega⟩
      rw [hpr] at hf ⊢
      simp only [mkOut, length_callToks] at hf ⊢
      have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart]))
        (Or.inl rfl) xs hxM rest g (by simp at hf; unfold need at hf ⊢; omega)
      simp only [callToks, lpC, List.cons_append, List.nil_append, List.append_assoc]
      rw [pPrim.eq_def]
      simp only
      rw [pOpn.eq_def]
      simp only [isLp, ↓reduceIte]
      rw [hca]
      have hlen : ps.length = xs.length := by simp [xs]
      simp only [hco, hneg, hpow, hD, hrem, htp, allPos_map, Bool.false_eq_true, ↓reduceIte,
        hlen, hsort]
      simp
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · unfold tNode at hpr ⊢; exact addAcc_of_lvl (by rw [hpr]; rfl)
  · rw [hpr]; rfl

/-! ## Named arguments -/

def itemToks (c : Ctx) (kv : String × Json) : List Tok :=
  nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at c.sf 4

theorem at_name (c : Ctx) (k : String) : (pr c (.str k)).at c.sf 4 = nameToks c k := by
  rw [pr_str]; rfl

theorem pName_item (c : Ctx) (k : String) (hk : nameOK k = true) (X : List Tok) (f : Nat)
    (hf : need 4 (nameToks c k).length ≤ f) :
    pAdd c f (nameToks c k ++ .kw .eq :: X) = some (.str k, .kw .eq :: X) := by
  have h := PL_at (M_name c k hk) 4 (by omega) (by omega) (.kw .eq :: X)
    (fol_kw _ _ _ _ (by simp [conts, atomStart, isCmpTok])) f (by rw [at_name]; exact hf)
  rw [pLvl4, at_name] at h; exact h

theorem pCallItems_named (c : Ctx) (rest : List Tok) :
    ∀ (bs : List (String × Json)), bs ≠ [] → (∀ kv ∈ bs, M c kv.2) → (∀ kv ∈ bs, nameOK kv.1 = true) →
      ∀ f, need 1 (sepBy [.kw .comma] (bs.map (itemToks c))).length + 2 ≤ f →
      pCallItems c f (sepBy [.kw .comma] (bs.map (itemToks c)) ++ .kw .rp :: rest) =
        some (bs.map fun kv => .named kv.1 kv.2, .kw .rp :: rest)
  | [], hne, _, _, _, _ => absurd rfl hne
  | [kv], _, hM, hk, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    simp only [List.map_cons, List.map_nil, sepBy, itemToks, List.length_append,
      List.length_cons] at hf ⊢
    have hv := PL_at (hM kv (by simp)) 4 (by omega) (by omega) (.kw .rp :: rest)
      (fol_kw _ _ _ _ (by simp [conts, atomStart])) g (by unfold need at hf ⊢; omega)
    rw [pLvl4] at hv
    rw [pCallItems]; simp only [List.append_assoc, List.cons_append]
    rw [pName_item c kv.1 (hk kv (by simp)) _ g (by unfold need at hf ⊢; omega)]
    simp only
    rw [hv]
  | kv :: kv2 :: kvs, _, hM, hk, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by omega⟩
    have hft : itemToks c kv = nameToks c kv.1 ++ .kw .eq :: (pr c kv.2).at c.sf 4 := rfl
    simp only [List.map_cons, sepBy_cons2] at hf ⊢
    rw [hft] at hf ⊢
    simp only [List.length_append, List.length_cons] at hf
    have ih := pCallItems_named c rest (kv2 :: kvs) (by simp) (fun z hz => hM z (by simp [hz]))
      (fun z hz => hk z (by simp [hz])) g (by simp only [List.map_cons]; unfold need at hf ⊢; omega)
    simp only [List.map_cons] at ih
    have hv := PL_at (hM kv (by simp)) 4 (by omega) (by omega)
      (.kw .comma :: (sepBy [.kw .comma] (itemToks c kv2 :: kvs.map (itemToks c)) ++ .kw .rp :: rest))
      (fol_kw _ _ _ _ (by simp [conts, atomStart])) g (by unfold need at hf ⊢; omega)
    rw [pLvl4] at hv
    rw [pCallItems]; simp only [List.append_assoc, List.cons_append, List.nil_append]
    rw [pName_item c kv.1 (hk kv (by simp)) _ g (by unfold need at hf ⊢; omega)]
    simp only
    rw [hv]; simp only
    rw [ih]; simp

theorem allNamed_named : ∀ bs : List (String × Json),
    allNamed (bs.map fun kv => CallArg.named kv.1 kv.2) = some bs
  | [] => rfl
  | kv :: r => by simp [allNamed, allNamed_named r]

theorem allPos_named : ∀ bs : List (String × Json), bs ≠ [] →
    allPos (bs.map fun kv => CallArg.named kv.1 kv.2) = none
  | [], h => absurd rfl h
  | _ :: _, _ => rfl

theorem M_tnamed (c : Ctx) (n : String) (bs : List (String × Json))
    (hn : tnameOK n = true) (hM : ∀ kv ∈ bs, M c kv.2) (hne : bs ≠ [])
    (hk : ∀ kv ∈ bs, nameOK kv.1 = true)
    (hpr : pr c (tNode n bs) = mkOut c.sf 10 (callToks c.sf [.opn n] (bs.map (itemToks c)))) :
    M c (tNode n bs) := by
  obtain ⟨hco, hneg, hpow, hD, hrem⟩ := tname_facts hn
  apply M_of
  · apply P0_of_prim
    · intro rest hr f hf
      obtain ⟨g, rfl⟩ : ∃ g, f = g + 3 := ⟨f - 3, by rw [hpr] at hf; unfold need at hf; simp [mkOut, length_callToks] at hf; omega⟩
      rw [hpr] at hf ⊢
      simp only [mkOut, length_callToks] at hf ⊢
      have hci := pCallItems_named c rest bs hne hM hk g (by simp at hf; unfold need at hf ⊢; omega)
      obtain ⟨kv, bs', rfl⟩ : ∃ kv bs', bs = kv :: bs' := by
        cases bs with
        | nil => exact absurd rfl hne
        | cons kv bs' => exact ⟨kv, bs', rfl⟩
      obtain ⟨t, tr, he, h1, -, -, h4, -, -⟩ :=
        headOK_closer (headOK_at (M_name c kv.1 (hk kv (by simp))) 4)
      rw [at_name] at he
      have hs : sepBy [.kw .comma] ((kv :: bs').map (itemToks c)) =
          t :: (tr ++ .kw .eq :: (pr c kv.2).at c.sf 4 ++
            (bs'.map (itemToks c)).flatMap (fun y => [.kw .comma] ++ y)) := by
        rw [List.map_cons, sepBy_cons]; simp [itemToks, he]
      rw [hs] at hci
      simp only [callToks, lpC, List.cons_append, List.nil_append, List.append_assoc]
      rw [hs]
      simp only [List.cons_append, List.append_assoc]
      rw [pPrim.eq_def]
      simp only
      rw [pOpn.eq_def]
      simp only [isLp, ↓reduceIte]
      have ht : t ≠ .kw .rp := by intro e; subst e; simp [isRp] at h1
      rw [pCallArgs.eq_4 _ _ _ (by intro r' e; cases e; exact ht rfl) (by intro r' e; cases e; exact h4 rfl)]
      simp only [List.append_assoc, List.cons_append] at hci
      rw [hci]
      simp only [hco, hneg, hpow, hD, hrem, Bool.false_eq_true, ↓reduceIte,
        allNamed_named, allPos_named _ hne]
      split <;> simp_all
    · rw [hpr]; simp [mkOut]
    · rw [hpr]; simp [mkOut]
  · rw [hpr]; exact ⟨by simp, by simp, by simp, by simp, by simp, Or.inl (by simp [startA, atomStart])⟩
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · rw [hpr]; simp [mkOut]
  · unfold tNode at hpr ⊢; exact addAcc_of_lvl (by rw [hpr]; rfl)
  · rw [hpr]; rfl

end Esm.Document.Math
