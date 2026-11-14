import Esm.Document.Source.Skeleton

/-!
# The document layer round trip

`ofDoc_toDoc`: a canonical document is rebuilt exactly from its skeleton, for every
choice of container predicates `Caps`.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-! ## Entries kept, dropped or replaced by key -/

/-- Restricting to a key commutes with a map that keeps keys. -/
theorem at_filterMap_comm (g : String × Json → Option (String × Json))
    (hg : ∀ kv w, g kv = some w → w.1 = kv.1) (k : String) :
    ∀ kvs : List (String × Json), at_ k (kvs.filterMap g) = (at_ k kvs).filterMap g
  | [] => rfl
  | (k', v') :: r => by
    have ih := at_filterMap_comm g hg k r
    rw [List.filterMap_cons, at_cons]
    cases hgk : g (k', v') with
    | none =>
      simp only
      rw [ih]
      by_cases h : k' = k
      · subst h; simp [hgk]
      · simp [h]
    | some w =>
      have hw := hg _ _ hgk
      obtain ⟨wk, wv⟩ := w
      simp only at hw
      subst hw
      simp only
      rw [at_cons, ih]
      by_cases h : wk = k
      · subst h; simp [hgk]
      · simp [h]

theorem at_filterMap {kvs : List (String × Json)} (hl : keysSorted kvs = true)
    (g : String × Json → Option (String × Json)) (hg : ∀ kv w, g kv = some w → w.1 = kv.1)
    (k : String) :
    at_ k (kvs.filterMap g) = match look k kvs with
      | some v => (g (k, v)).toList
      | none => [] := by
  rw [at_filterMap_comm g hg k kvs, at_of_sorted hl]
  cases look k kvs with
  | none => rfl
  | some v =>
    simp only [List.filterMap_cons, List.filterMap_nil]
    cases g (k, v) <;> rfl

theorem pickOne_nil {k : String} {l : List (String × Json)} (h : at_ k l = []) :
    pickOne k l = some none := by
  unfold pickOne; rw [h]

theorem pickOne_single {k : String} {l : List (String × Json)} {v : Json}
    (h : at_ k l = [(k, v)]) : pickOne k l = some (some v) := by
  unfold pickOne; rw [h]

theorem at_optKv (k k' : String) (o : Option Json) :
    at_ k (optKv k' o) = if k' = k then optKv k' o else [] := by
  cases o with
  | none => simp [optKv]
  | some v =>
    simp only [optKv]
    rw [at_single]

theorem optKv_look {kvs : List (String × Json)} (hl : keysSorted kvs = true) (k : String) :
    optKv k (look k kvs) = at_ k kvs := by
  rw [at_of_sorted hl]
  cases look k kvs <;> rfl

theorem look_any {kvs : List (String × Json)} {k : String} {v : Json} (h : look k kvs = some v) :
    kvs.any (fun kv => kv.1 == k) = true := by
  have := look_mem' h
  rw [List.any_eq_true]
  exact ⟨_, this, by simp⟩

theorem filter_noKey_any (kvs : List (String × Json)) (k : String) :
    (kvs.filter (fun kv => kv.1 != k)).any (fun kv => kv.1 == k) = false := by
  rw [Bool.eq_false_iff]
  intro h
  rw [List.any_eq_true] at h
  obtain ⟨x, hx, hxk⟩ := h
  rw [List.mem_filter] at hx
  simp only [bne_iff_ne, ne_eq, beq_iff_eq] at hx hxk
  exact hx.2 hxk

/-- Putting back an entry that was filtered out of a canonical object restores it. -/
theorem sortKeys_cons_filter {kvs : List (String × Json)} (hl : keysSorted kvs = true)
    {k : String} {v : Json} (hk : look k kvs = some v) :
    sortKeys ((k, v) :: kvs.filter (fun kv => kv.1 != k)) = kvs := by
  apply sortKeys_ext hl
  intro k'
  rw [at_cons]
  by_cases h : k = k'
  · subst h
    simp only [↓reduceIte]
    rw [look_at hl hk, at_filter_false]
    intro w; simp
  · simp only [h, ↓reduceIte]
    rw [at_filter]
    intro w; simp [Ne.symm h]

/-! ## Declarations -/

theorem pickVar_back {caps : Caps} {n : String} {v : Json} {d : Decl}
    (h : pickVar caps n v = some d) (hv : canonVal v = true) :
    backDecl .model d = some (n, v) ∧ declField .model d.kind = some "variables" := by
  unfold pickVar at h
  split at h
  · cases h
  · split at h
    · rename_i kvs
      have hl := canonVal_obj_sorted hv
      split at h
      · rename_i hty
        dsimp only at h
        split at h
        · cases h
          refine ⟨?_, rfl⟩
          simp only [backDecl, filter_noKey_any, Bool.false_eq_true, ite_false]
          rw [sortKeys_cons_filter hl hty]
        · cases h
      · rename_i hty
        dsimp only at h
        split at h
        · cases h
          refine ⟨?_, rfl⟩
          simp only [backDecl, filter_noKey_any, Bool.false_eq_true, ite_false]
          rw [sortKeys_cons_filter hl hty]
        · cases h
      · rename_i t _ _ hty

        split at h
        · cases h
          refine ⟨?_, rfl⟩
          simp only [backDecl, look_any hty, ↓reduceIte]
          rw [sortKeys_eq (List.Perm.refl _) hl]
        · cases h
      · cases h
    · cases h

theorem pickPlain_back {caps : Caps} {k : DKind} {n : String} {v : Json} {d : Decl}
    (h : pickPlain caps k n v = some d) (hv : canonVal v = true) :
    d.kind = k ∧ ∃ kvs, v = .obj kvs ∧ d = ⟨k, n, kvs⟩ ∧ keysSorted kvs = true := by
  unfold pickPlain at h
  split at h
  · cases h
  · split at h
    · rename_i kvs
      split at h
      · cases h; exact ⟨rfl, kvs, rfl, rfl, canonVal_obj_sorted hv⟩
      · cases h
    · cases h

/-- Every declaration a field's picker produces belongs to that field, and stands for
its entry. -/
theorem declFields_back (caps : Caps) (K : Kind) :
    ∀ f ∈ declFields caps K, ∀ n v d, f.2 n v = some d → canonVal v = true →
      backDecl K d = some (n, v) ∧ declField K d.kind = some f.1 := by
  intro f hf n v d h hv
  cases K with
  | model =>
    simp only [declFields, List.mem_singleton] at hf
    subst hf
    exact pickVar_back h hv
  | rs =>
    simp only [declFields, List.mem_cons, List.not_mem_nil, or_false] at hf
    rcases hf with rfl | rfl
    · obtain ⟨hk, kvs, rfl, rfl, hs⟩ := pickPlain_back h hv
      exact ⟨by simp [backDecl, sortKeys_eq (List.Perm.refl _) hs], rfl⟩
    · obtain ⟨hk, kvs, rfl, rfl, hs⟩ := pickPlain_back h hv
      exact ⟨by simp [backDecl, sortKeys_eq (List.Perm.refl _) hs], rfl⟩


/-! ## A component -/

theorem at_at (k f : String) (l : List (String × Json)) :
    at_ k (at_ f l) = if f = k then at_ k l else [] := by
  unfold at_
  rw [List.filter_filter]
  by_cases h : f = k
  · subst h; simp
  · simp only [h, ite_false, List.filter_eq_nil_iff, Bool.and_eq_true, beq_iff_eq, not_and]
    intro kv _ h1 h2
    exact h (h2 ▸ h1)

theorem mem_splitOpt_fst {β : Type} {pick : String → Json → Option β} {o : Option Json} {p : β}
    (h : p ∈ (splitOpt pick o).1) :
    ∃ kvs, o = some (.obj kvs) ∧ ∃ k w, (k, w) ∈ kvs ∧ pick k w = some p := by
  cases o with
  | none => simp [splitOpt] at h
  | some v =>
    simp only [splitOpt] at h
    rw [splitField_fst] at h
    cases v with
    | obj kvs =>
      simp only [List.mem_filterMap] at h
      obtain ⟨⟨k, w⟩, hm, hp⟩ := h
      exact ⟨kvs, rfl, k, w, hm, hp⟩
    | _ => simp at h

theorem lookup_declFields_none (caps : Caps) (K : Kind) (k : String) (h : k ∉ declFieldNames K) :
    (declFields caps K).lookup k = none := by
  cases K with
  | model =>
    have h1 : (k == "variables") = false := by simpa [declFieldNames] using h
    simp [declFields, List.lookup, h1]
  | rs =>
    have h1 : (k == "species") = false := by simp [declFieldNames] at h; simp [h.1]
    have h2 : (k == "parameters") = false := by simp [declFieldNames] at h; simp [h.2]
    simp [declFields, List.lookup, h1, h2]

theorem compOf_blocks (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) :
    (compOf caps root K name kvs).blocks = (compBase caps K name kvs).blocks := by
  unfold compOf; dsimp only; split
  · rfl
  · split <;> rfl

theorem compOf_decls (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) :
    (compOf caps root K name kvs).decls = (compBase caps K name kvs).decls := by
  unfold compOf; dsimp only; split
  · rfl
  · split <;> rfl

theorem compOf_desc (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) :
    (compOf caps root K name kvs).desc = descOf caps (look "description" kvs) := by
  unfold compOf; dsimp only; split
  · rfl
  · split <;> rfl

theorem compOf_kind (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) : (compOf caps root K name kvs).kind = K := by
  unfold compOf; dsimp only; split
  · rfl
  · split <;> rfl

theorem compOf_name (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) : (compOf caps root K name kvs).name = name := by
  unfold compOf; dsimp only; split
  · rfl
  · split <;> rfl

/-- The blocks of a component, key by key. -/
theorem compBase_blocks_at (caps : Caps) (K : Kind) (name : String) {kvs : List (String × Json)}
    (hl : keysSorted kvs = true) (k : String) :
    at_ k (compBase caps K name kvs).blocks = match look k kvs with
      | some v => (compBlock caps K (descOf caps (look "description" kvs)) (k, v)).toList
      | none => [] := by
  apply at_filterMap hl
  intro kv w h
  unfold compBlock at h
  split at h
  · split at h
    · cases h
    · cases h; rfl
  · split at h
    · cases h
    · split at h
      · simp only [Option.map_eq_some_iff] at h
        obtain ⟨r, _, rfl⟩ := h
        rfl
      · cases h; rfl

/-- A declaration field is rebuilt from the declarations and the residue block. -/
theorem declKv_compOf (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) (f : String × (String → Json → Option Decl))
    (hf : f ∈ declFields caps K)
    (hsep : ∀ g ∈ declFields caps K, ∀ d ∈ (splitOpt g.2 (look g.1 kvs)).1,
      (declField K d.kind == some f.1) = (g.1 == f.1)) :
    declKv K (compOf caps root K name kvs) f.1 = some (at_ f.1 kvs) := by
  have hl := canonVal_obj_sorted hv
  have hblk := compOf_blocks caps root K name kvs
  have hdec := compOf_decls caps root K name kvs
  have hfn : f.1 ∈ declFieldNames K := by
    rw [← declFields_names caps K]; exact List.mem_map_of_mem hf
  have hne : f.1 ≠ "description" ∧ f.1 ≠ "equations" := by
    cases K with
    | model => simp only [declFieldNames, List.mem_singleton] at hfn; simp [hfn]
    | rs =>
      simp only [declFieldNames, List.mem_cons, List.not_mem_nil, or_false] at hfn
      rcases hfn with h | h <;> simp [h]
  have hlk : (declFields caps K).lookup f.1 = some f.2 := by
    cases K with
    | model => simp only [declFields, List.mem_singleton] at hf; subst hf; rfl
    | rs =>
      simp only [declFields, List.mem_cons, List.not_mem_nil, or_false] at hf
      rcases hf with rfl | rfl <;> rfl
  -- the residue block
  have hpick : pickOne f.1 (compOf caps root K name kvs).blocks = some (splitOpt f.2 (look f.1 kvs)).2 := by
    rw [hblk, pickOne, compBase_blocks_at caps K name hl f.1]
    cases hk : look f.1 kvs with
    | none => rfl
    | some v =>
      simp only [compBlock, hne.1, hne.2, ite_false, hlk]
      cases (splitOpt f.2 (some v)).2 <;> rfl
  -- the declarations
  have hdecls : (compOf caps root K name kvs).decls.filter (fun d => declField K d.kind == some f.1) =
      (splitOpt f.2 (look f.1 kvs)).1 := by
    rw [hdec]
    simp only [compBase]
    rw [List.filter_flatMap]
    have hnd : ((declFields caps K).map Prod.fst).Nodup := by
      rw [declFields_names]; cases K <;> simp [declFieldNames]
    clear hblk hdec hpick hlk hfn
    generalize declFields caps K = L at hf hsep hnd ⊢
    induction L with
    | nil => cases hf
    | cons g gs ih =>
      simp only [List.flatMap_cons]
      rcases List.mem_cons.mp hf with rfl | hg
      · rw [List.filter_eq_self.mpr (fun d hd => by rw [hsep _ List.mem_cons_self d hd]; simp)]
        have : (gs.flatMap fun g' => (splitOpt g'.2 (look g'.1 kvs)).1.filter
            (fun d => declField K d.kind == some f.1)) = [] := by
          rw [List.flatMap_eq_nil_iff]
          intro g' hg'
          rw [List.filter_eq_nil_iff]
          intro d hd
          rw [hsep g' (List.mem_cons_of_mem _ hg') d hd]
          simp only [List.map_cons, List.nodup_cons] at hnd
          have : g'.1 ≠ f.1 := fun e => hnd.1 (e ▸ List.mem_map_of_mem hg')
          simpa using this
        rw [this, List.append_nil]
      · have hgf : g.1 ≠ f.1 := by
          simp only [List.map_cons, List.nodup_cons] at hnd
          exact fun e => hnd.1 (e ▸ List.mem_map_of_mem hg)
        rw [List.filter_eq_nil_iff.mpr (fun d hd => by rw [hsep _ List.mem_cons_self d hd]; simpa using hgf),
          List.nil_append]
        exact ih hg (fun g' hg' => hsep g' (List.mem_cons_of_mem _ hg'))
          (List.nodup_cons.mp hnd).2
  unfold declKv
  rw [hpick]
  simp only [Option.bind_eq_bind, Option.bind_some, hdecls]
  rw [joinField_splitOpt f.2 (backDecl K) (look f.1 kvs)
    (fun kvs' h => canonVal_obj_sorted (canonVal_look hv h))
    (fun kvs' h k w p hm hp => (declFields_back caps K f hf k w p hp
      (canonVal_mem (canonVal_look hv h) hm)).1)]
  simp [optKv_look hl]

theorem mapM_some {α β : Type} (f : α → Option β) (g : α → β) :
    ∀ l : List α, (∀ x ∈ l, f x = some (g x)) → l.mapM f = some (l.map g)
  | [], _ => rfl
  | x :: xs, h => by
    simp only [List.mapM_cons, h x List.mem_cons_self,
      mapM_some f g xs (fun y hy => h y (List.mem_cons_of_mem _ hy)), List.map_cons]
    rfl

theorem decls_field (caps : Caps) (K : Kind) {kvs : List (String × Json)}
    (hv : canonVal (.obj kvs) = true) :
    ∀ g ∈ declFields caps K, ∀ d ∈ (splitOpt g.2 (look g.1 kvs)).1,
      declField K d.kind = some g.1 := by
  intro g hg d hd
  obtain ⟨kvs', ho, k, w, hm, hp⟩ := mem_splitOpt_fst hd
  exact (declFields_back caps K g hg k w d hp (canonVal_mem (canonVal_look hv ho) hm)).2

theorem declKvs_compOf (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) :
    declKvs K (compOf caps root K name kvs) =
      some ((declFieldNames K).flatMap (fun f => at_ f kvs)) := by
  have hdf := decls_field caps K hv
  unfold declKvs
  have hall : (compOf caps root K name kvs).decls.all (fun d => (declField K d.kind).isSome) = true := by
    rw [compOf_decls, List.all_eq_true]
    intro d hd
    simp only [compBase, List.mem_flatMap] at hd
    obtain ⟨g, hg, hd⟩ := hd
    rw [hdf g hg d hd]; rfl
  simp only [hall, ↓reduceIte]
  rw [← declFields_names caps K, List.mapM_map]
  rw [mapM_some _ (fun f => at_ f.1 kvs)]
  · simp [List.flatMap, Function.comp_def]
  · intro f hf
    exact declKv_compOf caps root K name hv f hf (fun g hg d hd => by
      rw [hdf g hg d hd]; simp)

theorem eqnsKv_compOf (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hl : keysSorted kvs = true) :
    eqnsKv (compOf caps root K name kvs) = some (at_ "equations" kvs) := by
  unfold compOf
  dsimp only
  cases hk : look "equations" kvs with
  | none => simp [eqnsKv, compBase, optKv, look_at_none hl hk]
  | some ev =>
    simp only
    rw [look_at hl hk]
    cases he : eqnsOf caps (symFor root (compBase caps K name kvs)) ev with
    | none => simp [eqnsKv, compBase, optKv]
    | some es =>
      obtain ⟨rfl, hne⟩ := eqnsOf_json he
      obtain ⟨e, es', rfl⟩ := List.exists_cons_of_ne_nil hne
      simp [eqnsKv, compBase]

/-- **A component is rebuilt exactly from its section.** -/
theorem ofComp_compOf (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) :
    ofComp (compOf caps root K name kvs) = some (.obj kvs) := by
  have hl := canonVal_obj_sorted hv
  unfold ofComp
  rw [compOf_kind, declKvs_compOf caps root K name hv, eqnsKv_compOf caps root K name hl]
  simp only [Option.bind_eq_bind, Option.bind_some, Option.pure_def, Option.some.injEq,
    Json.obj.injEq]
  apply sortKeys_ext hl
  intro k
  rw [compOf_desc, compOf_blocks]
  simp only [at_append]
  have hA : at_ k ((declFieldNames K).flatMap (fun f => at_ f kvs)) =
      if k ∈ declFieldNames K then at_ k kvs else [] := by
    cases K with
    | model =>
      simp only [declFieldNames, List.flatMap_cons, List.flatMap_nil,
        List.append_nil, at_at, List.mem_singleton]
      by_cases h : k = "variables" <;> simp [h, eq_comm]
    | rs =>
      simp only [declFieldNames, List.flatMap_cons, List.flatMap_nil,
        List.append_nil, at_append, at_at, List.mem_cons, List.not_mem_nil, or_false]
      by_cases h1 : k = "species"
      · subst h1; simp
      · by_cases h2 : k = "parameters"
        · subst h2; simp
        · simp [h1, h2, Ne.symm h1, Ne.symm h2]
  have hB : at_ k ((compBase caps K name kvs).blocks.filter
      (fun kv => !(declFieldNames K).contains kv.1)) =
      if k ∈ declFieldNames K then [] else at_ k (compBase caps K name kvs).blocks := by
    by_cases h : k ∈ declFieldNames K
    · simp only [h, ↓reduceIte]; rw [at_filter_false]; intro w; simp [h]
    · simp only [h, ↓reduceIte]; rw [at_filter]; intro w; simp [h]
  rw [at_optKv, hA, hB, at_at, compBase_blocks_at caps K name hl k]
  have hdn : "description" ∉ declFieldNames K := by cases K <;> simp [declFieldNames]
  have hen : "equations" ∉ declFieldNames K := by cases K <;> simp [declFieldNames]
  by_cases hd : k = "description"
  · subst hd
    simp only [hdn, ↓reduceIte, List.append_nil]
    simp only [show ("equations" = "description") = False by simp, ite_false, List.append_nil]
    cases hk : look "description" kvs with
    | none => simp [descOf, optKv, look_at_none hl hk]
    | some v =>
      rw [look_at hl hk]
      cases hdv : descOf caps (some v) with
      | none => simp [optKv, compBlock]
      | some t =>
        have : v = .str t := by
          cases v <;> simp [descOf] at hdv
          rw [hdv.2]
        subst this
        simp [optKv, compBlock]
  · by_cases he : k = "equations"
    · subst he
      simp only [hen, ↓reduceIte, List.append_nil]
      simp only [show ("description" = "equations") = False by simp, ite_false, List.nil_append]
      cases hk : look "equations" kvs with
      | none => simp [look_at_none hl hk]
      | some v => simp [compBlock]
    · by_cases hn : k ∈ declFieldNames K
      · simp [hn, Ne.symm hd, Ne.symm he]
      · simp only [hn, ite_false, Ne.symm hd, Ne.symm he, List.nil_append, List.append_nil]
        rw [at_of_sorted hl]
        cases look k kvs with
        | none => rfl
        | some v =>
          simp [compBlock, hd, he, lookup_declFields_none caps K k hn]

/-! ## The document -/

theorem joinField_map {β γ : Type} (back : γ → Option (String × Json)) (F : β → γ) (ps : List β)
    (r : Option Json) : joinField back (ps.map F) r = joinField (fun p => back (F p)) ps r := by
  cases ps with
  | nil => rfl
  | cons p ps' =>
    simp only [List.map_cons, joinField]
    rw [← List.map_cons, List.mapM_map]
    rfl

theorem at_idem (k : String) (l : List (String × Json)) : at_ k (at_ k l) = at_ k l := by
  unfold at_; rw [List.filter_filter]; simp

@[simp] theorem optKv_none (k : String) : optKv k none = [] := rfl

theorem at_filter_comm (k : String) (p : String × Json → Bool) (l : List (String × Json)) :
    at_ k (l.filter p) = (at_ k l).filter p := by
  unfold at_; rw [List.filter_filter, List.filter_filter]
  congr 1; funext kv; exact Bool.and_comm _ _

/-- The `metadata` entries are rebuilt from the front matter and the description. -/
theorem meta_rebuild (caps : Caps) {mkvs : List (String × Json)} (hl : keysSorted mkvs = true) :
    sortKeys (mkvs.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs)).isSome)) ++
      optKv "description" ((descOf caps (look "description" mkvs)).map Json.str)) = mkvs := by
  apply sortKeys_ext hl
  intro k
  rw [at_append, at_optKv]
  by_cases hk : k = "description"
  · subst hk
    simp only [↓reduceIte]
    cases hd : look "description" mkvs with
    | none =>
      simp [descOf, optKv, look_at_none hl hd]
    | some v =>
      rw [look_at hl hd]
      cases hdv : descOf caps (some v) with
      | none =>
        simp only [Option.isSome_none, Bool.and_false, Bool.not_false, List.filter_true,
          Option.map_none, optKv, List.append_nil]
        rw [look_at hl hd]
      | some t =>
        have : v = .str t := by
          cases v <;> simp [descOf] at hdv
          rw [hdv.2]
        subst this
        rw [at_filter_false]
        · rfl
        · intro w; simp
  · simp only [Ne.symm hk, ↓reduceIte, List.append_nil]
    rw [at_filter]
    intro w; simp [hk]

theorem rootBlocks_at (caps : Caps) {kvs : List (String × Json)} (hl : keysSorted kvs = true)
    (k : String) : at_ k (rootBlocks caps kvs) = match look k kvs with
      | some v => (rootBlock caps (k, v)).toList
      | none => [] := by
  apply at_filterMap hl
  intro kv w h
  unfold rootBlock at h
  split at h
  · cases h
  · split at h
    · split at h
      · cases h
      · cases h; rfl
    · split at h
      · simp only [Option.map_eq_some_iff] at h
        obtain ⟨r, _, rfl⟩ := h
        rfl
      · cases h; rfl

theorem comps_filter (caps : Caps) (blocks : List (String × Json)) (K K' : Kind)
    (ps : List (String × List (String × Json))) :
    (ps.map (fun p => compOf caps blocks K p.1 p.2)).filter (fun c => c.kind == K') =
      if K = K' then ps.map (fun p => compOf caps blocks K p.1 p.2) else [] := by
  by_cases h : K = K'
  · subst h
    simp only [↓reduceIte]
    rw [List.filter_eq_self]
    intro c hc
    simp only [List.mem_map] at hc
    obtain ⟨p, _, rfl⟩ := hc
    simp [compOf_kind]
  · simp only [h, ↓reduceIte]
    rw [List.filter_eq_nil_iff]
    intro c hc
    simp only [List.mem_map] at hc
    obtain ⟨p, _, rfl⟩ := hc
    simp [compOf_kind, h]

theorem compField_pick (caps : Caps) {kvs : List (String × Json)} (hl : keysSorted kvs = true)
    (f : String) (hf : f = "models" ∨ f = "reaction_systems") :
    pickOne f (rootBlocks caps kvs) = some (splitOpt (pickComp caps) (look f kvs)).2 := by
  unfold pickOne
  rw [rootBlocks_at caps hl f]
  have hne1 : f ≠ "esm" := by rcases hf with rfl | rfl <;> simp
  have hne2 : f ≠ "metadata" := by rcases hf with rfl | rfl <;> simp
  cases look f kvs with
  | none => rfl
  | some v =>
    simp only [rootBlock, hne1, hne2, ↓reduceIte, hf]
    cases (splitOpt (pickComp caps) (some v)).2 <;> rfl

/-- A component field (`models`, `reaction_systems`) is rebuilt from its directives
and its residue block. -/
theorem compField_join (caps : Caps) {kvs : List (String × Json)}
    (hv : canonVal (.obj kvs) = true) (root : List (String × Json)) (K : Kind) (f : String) :
    joinField backComp ((splitOpt (pickComp caps) (look f kvs)).1.map
        (fun p => compOf caps root K p.1 p.2)) (splitOpt (pickComp caps) (look f kvs)).2 =
      some (look f kvs) := by
  rw [joinField_map]
  apply joinField_splitOpt
  · intro kvs' h; exact canonVal_obj_sorted (canonVal_look hv h)
  · intro kvs' h k w p hm hp
    unfold pickComp at hp
    split at hp
    · rename_i ckvs
      split at hp
      · cases hp
        have hc : canonVal (.obj ckvs) = true := canonVal_mem (canonVal_look hv h) hm
        simp [backComp, ofComp_compOf caps _ K k hc, compOf_name]
      · cases hp
    · cases hp

theorem metaOf_some {caps : Caps} {v : Json} {mf : List (String × Json)} {d : Option String}
    (h : metaOf caps (some v) = some (mf, d)) :
    ∃ mkvs, v = .obj mkvs ∧ mkvs ≠ [] ∧ look "esm" mkvs = none ∧
      d = descOf caps (look "description" mkvs) ∧
      mf = mkvs.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs)).isSome)) ∧
      mkvs.all (fun kv => caps.frontKey kv.1) = true := by
  cases v with
  | obj mkvs =>
    simp only [metaOf] at h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true, Option.isNone_iff_eq_none] at hc
      cases h
      exact ⟨mkvs, rfl, by simpa using hc.1.1, hc.1.2, rfl, rfl, hc.2⟩
    · cases h
  | _ => simp [metaOf] at h

/-- **The document layer round trip.** For every container (`caps`), a document in
canonical form is rebuilt exactly from its skeleton. -/
theorem ofDoc_toDoc (caps : Caps) (d : Json) (hd : canonDoc d = true) :
    ofDoc (toDoc caps d) = some d := by
  match d, hd with
  | .obj kvs, hd =>
  have hv : canonVal (.obj kvs) = true := by simpa [canonDoc, canonVal] using hd
  have hl := canonVal_obj_sorted hv
  have hpm := compField_pick caps hl "models" (Or.inl rfl)
  have hpr := compField_pick caps hl "reaction_systems" (Or.inr rfl)
  have hjm := compField_join caps hv (rootBlocks caps kvs) .model "models"
  have hjr := compField_join caps hv (rootBlocks caps kvs) .rs "reaction_systems"
  unfold ofDoc toDoc
  simp only [List.filter_append, comps_filter, ↓reduceIte, reduceCtorEq, List.append_nil,
    List.nil_append]
  rw [hpm]
  simp only [Option.bind_eq_bind, Option.bind_some]
  rw [hjm]
  simp only [Option.bind_some]
  rw [hpr]
  simp only [Option.bind_some]
  rw [hjr]
  simp only [Option.bind_some]
  have hR : ∀ R, sortKeys R = kvs → (if canonDoc (.obj (sortKeys R)) = true then
      (pure (.obj (sortKeys R)) : Option Json) else none) = some (Json.obj kvs) := by
    intro R h; rw [h]; simp [hd]
  apply hR
  apply sortKeys_ext hl
  intro k
  have hE : (at_ "esm" kvs).filter (fun kv => kv.1 != "esm") = [] := by
    unfold at_; rw [List.filter_filter, List.filter_eq_nil_iff]
    intro kv _; simp only [bne_iff_ne, ne_eq, Bool.and_eq_true, beq_iff_eq, not_and]
    intro h1 h2; exact h1 h2
  have hO : at_ k ((rootBlocks caps kvs).filter
      (fun kv => kv.1 != "models" && kv.1 != "reaction_systems")) =
      if k = "models" ∨ k = "reaction_systems" then [] else at_ k (rootBlocks caps kvs) := by
    by_cases h : k = "models" ∨ k = "reaction_systems"
    · simp only [h, ↓reduceIte]; rw [at_filter_false]; intro w
      rcases h with rfl | rfl <;> simp
    · simp only [h, ↓reduceIte]; rw [at_filter]; intro w
      simp only [not_or] at h; simp [h.1, h.2]
  simp only [at_append, at_optKv, hO, hE, List.nil_append]
  rw [rootBlocks_at caps hl k]
  rw [at_idem, at_at]
  -- the entries other than `metadata`, the same whatever `metadata` became
  have hrest : ∀ M : List (String × Json), at_ k M = (if k = "metadata" then M else []) →
      k ≠ "metadata" →
      ((((if "esm" = k then at_ k kvs else []) ++ at_ k M ++
          if "models" = k then optKv "models" (look "models" kvs) else []) ++
        if "reaction_systems" = k then optKv "reaction_systems" (look "reaction_systems" kvs) else []) ++
      if k = "models" ∨ k = "reaction_systems" then [] else
        match look k kvs with
        | some v => (rootBlock caps (k, v)).toList
        | none => []) = at_ k kvs := by
    intro M hM hk
    simp only [hM, hk, ↓reduceIte, List.append_nil]
    by_cases h1 : k = "esm"
    · subst h1
      cases hk' : look "esm" kvs <;> simp [rootBlock]
    · by_cases h2 : k = "models"
      · subst h2; simp [optKv_look hl]
      · by_cases h3 : k = "reaction_systems"
        · subst h3; simp [optKv_look hl]
        · simp only [Ne.symm h1, Ne.symm h2, Ne.symm h3, ↓reduceIte, h2, h3, or_self,
            List.nil_append]
          rw [at_of_sorted hl]
          cases look k kvs with
          | none => rfl
          | some v => simp [rootBlock, h1, hk, h2, h3]
  generalize hm : metaOf caps (look "metadata" kvs) = m
  cases m with
  | none =>
    simp only [Option.map_none, Option.getD_none, at_nil, List.filter_nil, Option.bind_none,
      optKv_none, List.isEmpty_nil, ↓reduceIte, List.append_nil]
    by_cases hk : k = "metadata"
    · subst hk
      simp only [show ("esm" = "metadata") = False by simp, show ("models" = "metadata") = False by simp,
        show ("reaction_systems" = "metadata") = False by simp, ↓reduceIte, List.append_nil,
        List.nil_append]
      simp only [show ("metadata" = "models" ∨ "metadata" = "reaction_systems") = False by simp,
        ↓reduceIte]
      rw [at_of_sorted hl]
      cases hlk : look "metadata" kvs with
      | none => rfl
      | some v => rw [hlk] at hm; simp [rootBlock, hm]
    · have := hrest [] (by simp) hk
      simpa using this
  | some p =>
    obtain ⟨mf, md⟩ := p
    obtain ⟨v, hlk⟩ : ∃ v, look "metadata" kvs = some v := by
      cases h : look "metadata" kvs with
      | none => rw [h] at hm; simp [metaOf] at hm
      | some v => exact ⟨v, rfl⟩
    rw [hlk] at hm
    obtain ⟨mkvs', rfl, hne, hnoesm, rfl, rfl, -⟩ := metaOf_some hm
    have hmv : canonVal (.obj mkvs') = true := canonVal_look hv hlk
    have hms := canonVal_obj_sorted hmv
    have hfe : (mkvs'.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs')).isSome))).filter (fun kv => kv.1 != "esm") =
        mkvs'.filter (fun kv => !(kv.1 == "description" &&
          (descOf caps (look "description" mkvs')).isSome)) := by
      rw [List.filter_eq_self]
      intro kv hkv
      have := (List.mem_filter.mp hkv).1
      simp only [bne_iff_ne, ne_eq]
      intro he
      have hat : at_ "esm" mkvs' = [] := look_at_none hms hnoesm
      have : kv ∈ at_ "esm" mkvs' := List.mem_filter.mpr ⟨this, by simp [he]⟩
      rw [hat] at this; cases this
    have hae : at_ "esm" (mkvs'.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs')).isSome))) = [] := by
      rw [at_filter_comm, look_at_none hms hnoesm, List.filter_nil]
    have hmr := meta_rebuild caps hms
    have hnemp : (mkvs'.filter (fun kv => !(kv.1 == "description" &&
        (descOf caps (look "description" mkvs')).isSome)) ++
        optKv "description" ((descOf caps (look "description" mkvs')).map Json.str)).isEmpty = false := by
      rw [List.isEmpty_eq_false_iff]
      intro he
      rw [he] at hmr
      exact hne (hmr.symm.trans (by simp [sortKeys]))
    simp only [Option.map_some, Option.getD_some, Option.bind_some, hfe, hae, hnemp, hmr,
      Bool.false_eq_true, ↓reduceIte, at_nil, List.append_nil]
    by_cases hk : k = "metadata"
    · subst hk
      simp only [show ("esm" = "metadata") = False by simp, show ("models" = "metadata") = False by simp,
        show ("reaction_systems" = "metadata") = False by simp, ↓reduceIte, List.append_nil,
        List.nil_append, at_single]
      simp only [show ("metadata" = "models" ∨ "metadata" = "reaction_systems") = False by simp,
        ↓reduceIte, hlk, rootBlock, hm]
      simp [look_at hl hlk]
    · exact hrest _ (by rw [at_single]; simp [Ne.symm hk, hk]) hk
end Esm.Document.Source
