import Esm.Document.Source.Items

/-!
# What the skeleton of a canonical document satisfies

`toDoc_ok`: the skeleton of a canonical document only holds what its container can
spell (`Caps`), and only well-formed JSON values; the containers' round trips assume
exactly this.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-- What a container needs of a skeleton. -/
structure DocOK (caps : Caps) (D : Doc MC) : Prop where
  front : ∀ kv ∈ D.front, caps.frontKey kv.1 = true
  frontWF : jwf (.obj D.front) = true
  desc : ∀ s, D.desc = some s → caps.desc s = true
  blocks : ∀ kv ∈ D.blocks, jwf kv.2 = true
  compName : ∀ c ∈ D.comps, caps.compName c.name = true
  cdesc : ∀ c ∈ D.comps, ∀ s, c.desc = some s → caps.desc s = true
  declName : ∀ c ∈ D.comps, ∀ d ∈ c.decls, caps.declName d.name = true
  attrs : ∀ c ∈ D.comps, ∀ d ∈ c.decls, ∀ a ∈ d.attrs, caps.attr a = true ∧ jwf a.2 = true
  math : ∀ c ∈ D.comps, ∀ m ∈ c.math, caps.item (symFor D.blocks c) m = true ∧ mathWF m = true
  mathBlocks : ∀ c ∈ D.comps, ∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields ∧ jwf kv.2 = true
  cblocks : ∀ c ∈ D.comps, ∀ kv ∈ c.blocks, kv.1 ∉ mathFields ∧ jwf kv.2 = true

/-! ## Well-formed values -/

theorem jwfObj_iff_mem : ∀ kvs : List (String × Json), jwfObj kvs = true ↔ ∀ kv ∈ kvs, jwf kv.2 = true
  | [] => by simp [jwfObj]
  | (k, v) :: r => by
    simp only [jwfObj, Bool.and_eq_true, List.mem_cons, forall_eq_or_imp]
    rw [jwfObj_iff_mem r]

theorem jwf_obj_iff (kvs : List (String × Json)) :
    jwf (.obj kvs) = true ↔ (kvs.map Prod.fst).Nodup ∧ ∀ kv ∈ kvs, jwf kv.2 = true := by
  simp only [jwf, Bool.and_eq_true, decide_eq_true_eq]
  rw [jwfObj_iff_mem]

theorem jwf_of_canonVal {v : Json} (h : canonVal v = true) : jwf v = true := by
  simp only [canonVal, Bool.and_eq_true] at h; exact h.1

theorem jwf_obj_sub {kvs kvs' : List (String × Json)} (h : jwf (.obj kvs) = true) (hs : kvs'.Sublist kvs) :
    jwf (.obj kvs') = true := by
  rw [jwf_obj_iff] at h ⊢
  exact ⟨h.1.sublist (hs.map _), fun kv hkv => h.2 kv (hs.subset hkv)⟩

theorem look_none_mem {k : String} : ∀ {l : List (String × Json)}, look k l = none → ∀ kv ∈ l, kv.1 ≠ k
  | [], _, _, h => by cases h
  | (k', v') :: r, h, kv, hm => by
    simp only [look] at h
    split at h
    · cases h
    · rename_i hk
      rcases List.mem_cons.mp hm with rfl | hm
      · exact hk
      · exact look_none_mem h kv hm

theorem descOf_some {caps : Caps} {o : Option Json} {s : String} (h : descOf caps o = some s) :
    caps.desc s = true ∧ o = some (.str s) := by
  unfold descOf at h
  split at h
  · split at h
    · cases h; exact ⟨by assumption, rfl⟩
    · cases h
  · cases h

/-! ## A component -/

theorem decls_ok (caps : Caps) (K : Kind) {kvs : List (String × Json)}
    (hv : canonVal (.obj kvs) = true) :
    ∀ d ∈ (compBase caps K "" kvs).decls,
      caps.declName d.name = true ∧ ∀ a ∈ d.attrs, caps.attr a = true ∧ jwf a.2 = true := by
  intro d hd
  simp only [compBase, List.mem_flatMap] at hd
  obtain ⟨g, hg, hd⟩ := hd
  obtain ⟨fkvs, hfo, n, w, hm, hp⟩ := mem_splitOpt_fst hd
  have hw : canonVal w = true := canonVal_mem (canonVal_look hv hfo) hm
  have hpick : ∀ k, g = ("", pickPlain caps k) ∨ True := fun _ => Or.inr trivial
  clear hpick
  cases K with
  | model =>
    simp only [declFields, List.mem_singleton] at hg
    subst hg
    simp only [pickVar] at hp
    split at hp
    · cases hp
    · rename_i hn
      simp only [Bool.not_eq_true', Bool.not_eq_false] at hn
      split at hp
      · rename_i wkvs
        have hwj : ∀ a ∈ wkvs, jwf a.2 = true := by
          intro ⟨x, y⟩ ha; exact jwf_of_canonVal (canonVal_mem hw ha)
        split at hp
        · split at hp
          · cases hp; rename_i hall
            refine ⟨hn, fun a ha => ⟨List.all_eq_true.mp hall a ha, hwj a (List.mem_filter.mp ha).1⟩⟩
          · cases hp
        · split at hp
          · cases hp; rename_i hall
            refine ⟨hn, fun a ha => ⟨List.all_eq_true.mp hall a ha, hwj a (List.mem_filter.mp ha).1⟩⟩
          · cases hp
        · split at hp
          · cases hp; rename_i hall
            exact ⟨hn, fun a ha => ⟨List.all_eq_true.mp hall a ha, hwj a ha⟩⟩
          · cases hp
        · cases hp
      · cases hp
  | rs =>
    have : ∀ k, pickPlain caps k n w = some d →
        caps.declName d.name = true ∧ ∀ a ∈ d.attrs, caps.attr a = true ∧ jwf a.2 = true := by
      intro k hp
      simp only [pickPlain] at hp
      split at hp
      · cases hp
      · rename_i hn
        simp only [Bool.not_eq_true', Bool.not_eq_false] at hn
        split at hp
        · rename_i wkvs
          split at hp
          · cases hp; rename_i hall
            refine ⟨hn, ?_⟩
            intro ⟨x, y⟩ ha
            exact ⟨List.all_eq_true.mp hall _ ha, jwf_of_canonVal (canonVal_mem hw ha)⟩
          · cases hp
        · cases hp
    simp only [declFields, List.mem_cons, List.not_mem_nil, or_false] at hg
    rcases hg with rfl | rfl
    · exact this _ hp
    · exact this _ hp

theorem compBase_decls_name (caps : Caps) (K : Kind) (n n' : String) (kvs : List (String × Json)) :
    (compBase caps K n kvs).decls = (compBase caps K n' kvs).decls := rfl

theorem compOf_ok (caps : Caps) (root : List (String × Json)) (K : Kind) (n : String)
    {kvs : List (String × Json)} (hv : canonVal (.obj kvs) = true) :
    let c := compOf caps root K n kvs
    (∀ s, c.desc = some s → caps.desc s = true) ∧
    (∀ d ∈ c.decls, caps.declName d.name = true ∧ ∀ a ∈ d.attrs, caps.attr a = true ∧ jwf a.2 = true) ∧
    (∀ m ∈ c.math, caps.item (symFor root c) m = true ∧ mathWF m = true) ∧
    (∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields ∧ jwf kv.2 = true) ∧
    (∀ kv ∈ c.blocks, kv.1 ∉ mathFields ∧ jwf kv.2 = true) := by
  intro c
  have hl := canonVal_obj_sorted hv
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro s hs
    rw [compOf_desc] at hs
    exact (descOf_some hs).1
  · rw [compOf_decls, compBase_decls_name caps K n ""]
    exact decls_ok caps K hv
  · intro m hm
    simp only [c, compOf, List.mem_flatMap, List.mem_map] at hm ⊢
    obtain ⟨p, ⟨f, hf, rfl⟩, hm⟩ := hm
    unfold mathPart at hm
    split at hm
    · cases hm
    · split at hm
      · rename_i ms hms
        have := (mathOf_some hms).2.2 m hm
        exact ⟨this.2.2, this.2.1⟩
      · cases hm
  · intro kv hkv
    simp only [c, compOf, List.mem_filterMap, List.mem_map] at hkv
    obtain ⟨p, ⟨f, hf, rfl⟩, hkv⟩ := hkv
    unfold mathPart at hkv
    split at hkv
    · cases hkv
    · rename_i v hlk
      split at hkv
      · cases hkv
      · cases hkv
        exact ⟨hf, jwf_of_canonVal (canonVal_look hv hlk)⟩
  · intro kv hkv
    rw [compOf_blocks] at hkv
    simp only [compBase, List.mem_filterMap] at hkv
    obtain ⟨⟨k, w⟩, hm, hg⟩ := hkv
    have hw : canonVal w = true := canonVal_mem hv hm
    unfold compBlock at hg
    split at hg
    · split at hg
      · cases hg
      · cases hg; rename_i hk; exact ⟨by simp_all [mathFields], jwf_of_canonVal hw⟩
    · split at hg
      · cases hg
      · rename_i hk1 hk2
        split at hg
        · simp only [Option.map_eq_some_iff] at hg
          obtain ⟨r, hr, rfl⟩ := hg
          refine ⟨hk2, ?_⟩
          simp only [splitOpt, splitField] at hr
          split at hr
          · rename_i wkvs
            split at hr
            · cases hr
            · cases hr
              exact jwf_obj_sub (jwf_of_canonVal hw) List.filter_sublist
          · cases hr; exact jwf_of_canonVal hw
        · cases hg; exact ⟨hk2, jwf_of_canonVal hw⟩

/-! ## The document -/

theorem pickComp_some {caps : Caps} {n : String} {w : Json} {p : String × List (String × Json)}
    (h : pickComp caps n w = some p) : caps.compName n = true ∧ w = .obj p.2 ∧ p.1 = n := by
  unfold pickComp at h
  split at h
  · split at h
    · cases h; exact ⟨by assumption, rfl, rfl⟩
    · cases h
  · cases h

theorem mem_comps {caps : Caps} {kvs : List (String × Json)} {c : Comp MC}
    (h : c ∈ (toDoc caps (.obj kvs)).comps) :
    ∃ K f fkvs n ckvs, look f kvs = some (.obj fkvs) ∧ (n, .obj ckvs) ∈ fkvs ∧
      caps.compName n = true ∧ c = compOf caps (rootBlocks caps kvs) K n ckvs := by
  simp only [toDoc, List.mem_append, List.mem_map] at h
  rcases h with ⟨p, hp, rfl⟩ | ⟨p, hp, rfl⟩
  · obtain ⟨fkvs, hf, n, w, hm, hpk⟩ := mem_splitOpt_fst hp
    obtain ⟨hn, rfl, hp1⟩ := pickComp_some hpk
    exact ⟨.model, "models", fkvs, n, p.2, hf, hm, hn, by rw [hp1]⟩
  · obtain ⟨fkvs, hf, n, w, hm, hpk⟩ := mem_splitOpt_fst hp
    obtain ⟨hn, rfl, hp1⟩ := pickComp_some hpk
    exact ⟨.rs, "reaction_systems", fkvs, n, p.2, hf, hm, hn, by rw [hp1]⟩

/-- **The skeleton of a canonical document is spellable**, when the container can spell
the front-matter key `esm`. -/
theorem toDoc_ok (caps : Caps) (hesm : caps.frontKey "esm" = true) (d : Json)
    (hd : canonDoc d = true) : DocOK caps (toDoc caps d) := by
  match d, hd with
  | .obj kvs, hd =>
  have hv : canonVal (.obj kvs) = true := by simpa [canonDoc, canonVal] using hd
  have hl := canonVal_obj_sorted hv
  have hcomp : ∀ c ∈ (toDoc caps (.obj kvs)).comps, caps.compName c.name = true ∧
      ∃ ckvs, canonVal (.obj ckvs) = true ∧
        c = compOf caps (toDoc caps (.obj kvs)).blocks (c.kind) c.name ckvs := by
    intro c hc
    obtain ⟨K, f, fkvs, n, ckvs, hf, hm, hn, rfl⟩ := mem_comps hc
    refine ⟨by rw [compOf_name]; exact hn, ckvs, canonVal_mem (canonVal_look hv hf) hm, ?_⟩
    rw [compOf_kind, compOf_name]; rfl
  -- the front matter
  have hfront : ∀ kv ∈ (toDoc caps (.obj kvs)).front,
      (kv.1 = "esm" ∧ kv ∈ kvs) ∨ ∃ mkvs, look "metadata" kvs = some (.obj mkvs) ∧ kv ∈ mkvs ∧
        caps.frontKey kv.1 = true ∧ kv.1 ≠ "esm" := by
    intro kv hkv
    simp only [toDoc, List.mem_append] at hkv
    rcases hkv with h | h
    · left
      have := List.mem_filter.mp h
      exact ⟨by simpa using this.2, this.1⟩
    · right
      cases hm : metaOf caps (look "metadata" kvs) with
      | none => rw [hm] at h; simp at h
      | some p =>
        obtain ⟨mf, md⟩ := p
        rw [hm] at h
        simp only [Option.map_some, Option.getD_some] at h
        cases hlk : look "metadata" kvs with
        | none => rw [hlk] at hm; simp [metaOf] at hm
        | some v =>
          rw [hlk] at hm
          obtain ⟨mkvs, rfl, -, hnoesm, -, rfl, hall⟩ := metaOf_some hm
          have hin := (List.mem_filter.mp h).1
          exact ⟨mkvs, rfl, hin, List.all_eq_true.mp hall kv hin,
            look_none_mem hnoesm kv hin⟩
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro kv hkv
    rcases hfront kv hkv with ⟨h, -⟩ | ⟨_, _, _, h, _⟩
    · rw [h]; exact hesm
    · exact h
  · rw [jwf_obj_iff]
    constructor
    · simp only [toDoc, List.map_append]
      rw [List.nodup_append]
      refine ⟨?_, ?_, ?_⟩
      · exact (keysSorted_nodup hl).sublist ((List.filter_sublist).map _)
      · cases hm : metaOf caps (look "metadata" kvs) with
        | none => simp
        | some p =>
          obtain ⟨mf, md⟩ := p
          simp only [Option.map_some, Option.getD_some]
          cases hlk : look "metadata" kvs with
          | none => rw [hlk] at hm; simp [metaOf] at hm
          | some v =>
            rw [hlk] at hm
            obtain ⟨mkvs, rfl, -, -, -, rfl, -⟩ := metaOf_some hm
            have := canonVal_obj_sorted (canonVal_look hv hlk)
            exact (keysSorted_nodup this).sublist ((List.filter_sublist).map _)
      · intro a ha b hb
        simp only [List.mem_map] at ha hb
        obtain ⟨x, hx, rfl⟩ := ha
        obtain ⟨y, hy, rfl⟩ := hb
        have hx' : x.1 = "esm" := by simpa using (List.mem_filter.mp hx).2
        rcases hfront y (by simp [toDoc, hy]) with ⟨h, -⟩ | ⟨_, _, _, _, h⟩
        · exfalso
          -- y comes from the metadata part, which has no `esm` key
          cases hm : metaOf caps (look "metadata" kvs) with
          | none => rw [hm] at hy; simp at hy
          | some p =>
            obtain ⟨mf, md⟩ := p
            rw [hm] at hy
            simp only [Option.map_some, Option.getD_some] at hy
            cases hlk : look "metadata" kvs with
            | none => rw [hlk] at hm; simp [metaOf] at hm
            | some v =>
              rw [hlk] at hm
              obtain ⟨mkvs, rfl, -, hnoesm, -, rfl, -⟩ := metaOf_some hm
              exact look_none_mem hnoesm y (List.mem_filter.mp hy).1 h
        · rw [hx']; exact Ne.symm h
    · intro ⟨a, b⟩ hkv
      rcases hfront _ hkv with ⟨-, h⟩ | ⟨mkvs, hlk, h, -⟩
      · exact jwf_of_canonVal (canonVal_mem hv h)
      · exact jwf_of_canonVal (canonVal_mem (canonVal_look hv hlk) h)
  · intro s hs
    simp only [toDoc] at hs
    cases hm : metaOf caps (look "metadata" kvs) with
    | none => rw [hm] at hs; cases hs
    | some p =>
      obtain ⟨mf, md⟩ := p
      rw [hm] at hs
      simp only [Option.bind_some] at hs
      cases hlk : look "metadata" kvs with
      | none => rw [hlk] at hm; simp [metaOf] at hm
      | some v =>
        rw [hlk] at hm
        obtain ⟨mkvs, rfl, -, -, rfl, -, -⟩ := metaOf_some hm
        exact (descOf_some hs).1
  · intro kv hkv
    simp only [toDoc, rootBlocks, List.mem_filterMap] at hkv
    obtain ⟨⟨k, w⟩, hm, hg⟩ := hkv
    have hw : canonVal w = true := canonVal_mem hv hm
    unfold rootBlock at hg
    split at hg
    · cases hg
    · split at hg
      · split at hg
        · cases hg
        · cases hg; exact jwf_of_canonVal hw
      · split at hg
        · simp only [Option.map_eq_some_iff] at hg
          obtain ⟨r, hr, rfl⟩ := hg
          simp only [splitOpt, splitField] at hr
          split at hr
          · split at hr
            · cases hr
            · cases hr
              exact jwf_obj_sub (jwf_of_canonVal hw) List.filter_sublist
          · cases hr; exact jwf_of_canonVal hw
        · cases hg; exact jwf_of_canonVal hw
  · intro c hc; exact (hcomp c hc).1
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; exact (compOf_ok caps _ _ _ hck).1
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; intro d hd; exact ((compOf_ok caps _ _ _ hck).2.1 d hd).1
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; intro d hd; exact ((compOf_ok caps _ _ _ hck).2.1 d hd).2
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; exact (compOf_ok caps _ _ _ hck).2.2.1
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; exact (compOf_ok caps _ _ _ hck).2.2.2.1
  · intro c hc
    obtain ⟨-, ckvs, hck, he⟩ := hcomp c hc
    rw [he]; exact (compOf_ok caps _ _ _ hck).2.2.2.2

end Esm.Document.Source
