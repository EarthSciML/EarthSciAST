import Esm.Document.Source.SkeletonRT

/-!
# The skeleton as a sequence of constructs

A container spells a skeleton as a sequence of *constructs*: description blocks, path
blocks, component directives, declarations, equations (model, initialization and
constraint) and reactions. This is the container-independent middle layer:

* `items` lists the constructs of a skeleton in the printer's order;
* `unitems` reads a construct sequence back into a skeleton. A construct belongs to
  the section of the last component directive before it, or to the document when
  there is none; within a section, constructs may come in any order (a document can
  interleave declarations and equations with its prose), except that the math entries
  of one field keep their order. `unitems_items` is the round trip.

Math entries are held as the container's math text (`Doc MR`) at this layer; `rawDoc`
prints them under each component's symbol table and `cookDoc` reads them back
(`cookDoc_rawDoc`), the symbol table coming from the rest of the skeleton
(`symFor_mapMath`), so both sides use the same table.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-- One construct of a document. An equation is its math text, uninterpreted; so is a
reaction's rate. `eqn` is a model equation, `eqx` an equation of the field of its role
(the containers write it for initialization equations and constraints). -/
inductive RItem where
  | desc (s : String)
  | block (k : String) (v : Json)
  | comp (K : Kind) (name : String)
  | decl (d : Decl)
  | eqn (raw : String)
  | eqx (r : Role) (raw : String)
  | rxn (x : Rxn String)
  | plot (attrs : List (String × Json))
  | tm (t : Tm String)

/-- The construct of a math entry. -/
def mItem : MR → RItem
  | .eq .eqn raw => .eqn raw
  | .eq r raw => .eqx r raw
  | .rxn x => .rxn x
  | .plot a => .plot a
  | .tm t => .tm t

/-- The constructs of a component section. -/
def compItems (c : Comp MR) : List RItem :=
  .comp c.kind c.name :: ((c.desc.map RItem.desc).toList ++ c.decls.map RItem.decl ++
    c.math.map mItem ++ c.mathBlocks.map (fun kv => RItem.block kv.1 kv.2) ++
    c.blocks.map (fun kv => RItem.block kv.1 kv.2))

/-- **The constructs of a skeleton**, in the printer's order: the document description,
the top-level blocks, the top-level templates, then each component section. -/
def items (D : Doc MR) : List RItem :=
  (D.desc.map RItem.desc).toList ++ D.blocks.map (fun kv => RItem.block kv.1 kv.2) ++
    D.math.map mItem ++ D.comps.flatMap compItems

/-! ## Reading constructs back -/

/-- A fresh component section. -/
def Comp.fresh (K : Kind) (n : String) : Comp MR :=
  ⟨K, n, none, [], [], [], []⟩

/-- Add a construct to a component section. A second description is refused (and a
math field written twice is refused when the section is rebuilt). -/
def addTo (c : Comp MR) : RItem → Option (Comp MR)
  | .desc s => if c.desc.isSome then none else some { c with desc := some s }
  | .block k v =>
    if k ∈ mathFields then some { c with mathBlocks := c.mathBlocks ++ [(k, v)] }
    else some { c with blocks := c.blocks ++ [(k, v)] }
  | .decl d => some { c with decls := c.decls ++ [d] }
  | .eqn r => some { c with math := c.math ++ [.eq .eqn r] }
  | .eqx ro r => some { c with math := c.math ++ [.eq ro r] }
  | .rxn x => some { c with math := c.math ++ [.rxn x] }
  | .plot a => some { c with math := c.math ++ [.plot a] }
  | .tm t => some { c with math := c.math ++ [.tm t] }
  | .comp _ _ => none

/-- The reader's state: the document description, blocks and templates, the finished
sections, and the open one. -/
structure St where
  desc : Option String
  blocks : List (String × Json)
  math : List MR
  comps : List (Comp MR)
  cur : Option (Comp MR)

/-- Read one construct. Before the first directive only a description, blocks and
templates are allowed. -/
def step (st : St) : RItem → Option St
  | .comp K n => some { st with comps := st.comps ++ st.cur.toList, cur := some (Comp.fresh K n) }
  | it =>
    match st.cur with
    | some c => (addTo c it).map (fun c' => { st with cur := some c' })
    | none =>
      match it with
      | .desc s => if st.desc.isSome then none else some { st with desc := some s }
      | .block k v => some { st with blocks := st.blocks ++ [(k, v)] }
      | .tm t => some { st with math := st.math ++ [.tm t] }
      | _ => none

/-- **Read a construct sequence** (with the front matter) into a skeleton. -/
def unitems (front : List (String × Json)) (its : List RItem) : Option (Doc MR) :=
  (its.foldlM step ⟨none, [], [], [], none⟩).map
    (fun st => ⟨front, st.desc, st.blocks, st.math, st.comps ++ st.cur.toList⟩)

/-! ## The round trip -/

/-- A skeleton the constructs can carry: a component's blocks are not keyed by a math
field, and its math blocks are (the parser files a block by its key); the top-level
entries are templates. -/
def itemsOK (D : Doc MR) : Prop :=
  (∀ c ∈ D.comps, (∀ kv ∈ c.blocks, kv.1 ∉ mathFields) ∧ ∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields) ∧
    ∀ m ∈ D.math, ∃ t, m = .tm t

theorem fold_tms (st : St) (hc : st.cur = none) :
    ∀ ms : List MR, (∀ m ∈ ms, ∃ t, m = .tm t) →
      (ms.map mItem).foldlM step st = some { st with math := st.math ++ ms }
  | [], _ => by simp
  | m :: ms, hm => by
    obtain ⟨t, rfl⟩ := hm m List.mem_cons_self
    simp only [List.map_cons, List.foldlM_cons]
    have h1 : step st (mItem (.tm t)) = some { st with math := st.math ++ [.tm t] } := by
      simp [step, hc, mItem]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_tms { st with math := st.math ++ [.tm t] } hc ms (fun m' h' => hm m' (List.mem_cons_of_mem _ h'))]
    simp

theorem fold_blocks_root (st : St) (hc : st.cur = none) :
    ∀ bs : List (String × Json),
      (bs.map (fun kv => RItem.block kv.1 kv.2)).foldlM step st =
        some { st with blocks := st.blocks ++ bs }
  | [] => by simp
  | (k, v) :: bs => by
    simp only [List.map_cons, List.foldlM_cons]
    have h1 : step st (.block k v) = some { st with blocks := st.blocks ++ [(k, v)] } := by
      simp [step, hc]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_blocks_root { st with blocks := st.blocks ++ [(k, v)] } hc bs]
    simp

theorem fold_decls (st : St) (c : Comp MR) (h : st.cur = some c) :
    ∀ ds : List Decl, (ds.map RItem.decl).foldlM step st =
      some { st with cur := some { c with decls := c.decls ++ ds } }
  | [] => by cases st; simp at h; subst h; simp
  | d :: ds => by
    simp only [List.map_cons, List.foldlM_cons]
    have h1 : step st (.decl d) = some { st with cur := some { c with decls := c.decls ++ [d] } } := by
      simp [step, h, addTo]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_decls _ { c with decls := c.decls ++ [d] } rfl ds]
    simp

theorem addTo_mItem (c : Comp MR) (m : MR) : addTo c (mItem m) = some { c with math := c.math ++ [m] } := by
  cases m with
  | eq r raw => cases r <;> rfl
  | rxn x => rfl
  | plot a => rfl
  | tm t => rfl

theorem fold_math (st : St) (c : Comp MR) (h : st.cur = some c) :
    ∀ ms : List MR, (ms.map mItem).foldlM step st =
      some { st with cur := some { c with math := c.math ++ ms } }
  | [] => by cases st; simp at h; subst h; simp
  | m :: ms => by
    simp only [List.map_cons, List.foldlM_cons]
    have h1 : step st (mItem m) = some { st with cur := some { c with math := c.math ++ [m] } } := by
      have : ∀ K n, mItem m ≠ .comp K n := by intro K n; cases m with
        | eq r raw => cases r <;> simp [mItem]
        | rxn x => simp [mItem]
        | plot a => simp [mItem]
        | tm t => simp [mItem]
      unfold step
      split
      · rename_i K n he; exact absurd he (this K n)
      · rw [h]; simp [addTo_mItem]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_math _ { c with math := c.math ++ [m] } rfl ms]
    simp

theorem fold_mblocks (st : St) (c : Comp MR) (h : st.cur = some c) :
    ∀ bs : List (String × Json), (∀ kv ∈ bs, kv.1 ∈ mathFields) →
      (bs.map (fun kv => RItem.block kv.1 kv.2)).foldlM step st =
        some { st with cur := some { c with mathBlocks := c.mathBlocks ++ bs } }
  | [], _ => by cases st; simp at h; subst h; simp
  | (k, v) :: bs, hb => by
    simp only [List.map_cons, List.foldlM_cons]
    have hk : k ∈ mathFields := hb (k, v) List.mem_cons_self
    have h1 : step st (.block k v) =
        some { st with cur := some { c with mathBlocks := c.mathBlocks ++ [(k, v)] } } := by
      simp [step, h, addTo, hk]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_mblocks _ { c with mathBlocks := c.mathBlocks ++ [(k, v)] } rfl bs
      (fun kv hkv => hb kv (List.mem_cons_of_mem _ hkv))]
    simp

theorem fold_blocks (st : St) (c : Comp MR) (h : st.cur = some c) :
    ∀ bs : List (String × Json), (∀ kv ∈ bs, kv.1 ∉ mathFields) →
      (bs.map (fun kv => RItem.block kv.1 kv.2)).foldlM step st =
        some { st with cur := some { c with blocks := c.blocks ++ bs } }
  | [], _ => by cases st; simp at h; subst h; simp
  | (k, v) :: bs, hb => by
    simp only [List.map_cons, List.foldlM_cons]
    have hk : k ∉ mathFields := hb (k, v) List.mem_cons_self
    have h1 : step st (.block k v) =
        some { st with cur := some { c with blocks := c.blocks ++ [(k, v)] } } := by
      simp [step, h, addTo, hk]
    rw [h1]
    simp only [Option.bind_eq_bind, Option.bind_some]
    rw [fold_blocks _ { c with blocks := c.blocks ++ [(k, v)] } rfl bs
      (fun kv hkv => hb kv (List.mem_cons_of_mem _ hkv))]
    simp

theorem fold_comp (st : St) (c : Comp MR) (hc : (∀ kv ∈ c.blocks, kv.1 ∉ mathFields) ∧
    ∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields) :
    (compItems c).foldlM step st =
      some { st with comps := st.comps ++ st.cur.toList, cur := some c } := by
  obtain ⟨K, n, desc, decls, math, mblocks, blocks⟩ := c
  simp only [compItems, List.foldlM_cons, List.foldlM_append]
  have h0 : step st (.comp K n) =
      some { st with comps := st.comps ++ st.cur.toList, cur := some (Comp.fresh K n) } := rfl
  rw [h0]
  simp only [Option.bind_eq_bind, Option.bind_some]
  -- the description
  have h1 : ((desc.map RItem.desc).toList).foldlM step
      { st with comps := st.comps ++ st.cur.toList, cur := some (Comp.fresh K n) } =
      some { st with comps := st.comps ++ st.cur.toList, cur := some ⟨K, n, desc, [], [], [], []⟩ } := by
    cases desc with
    | none => rfl
    | some s => simp [step, addTo, Comp.fresh]
  rw [h1]
  simp only [Option.bind_some]
  rw [fold_decls _ _ rfl decls]
  simp only [Option.bind_some]
  rw [fold_math _ _ rfl math]
  simp only [Option.bind_some]
  rw [fold_mblocks _ _ rfl mblocks hc.2]
  simp only [Option.bind_some]
  rw [fold_blocks _ _ rfl blocks hc.1]
  simp

/-- **The construct round trip.** -/
theorem unitems_items (D : Doc MR) (hD : itemsOK D) : unitems D.front (items D) = some D := by
  obtain ⟨front, desc, blocks, rmath, comps⟩ := D
  obtain ⟨hD, hT⟩ := hD
  unfold unitems items
  simp only [List.foldlM_append]
  have h1 : ((desc.map RItem.desc).toList).foldlM step ⟨none, [], [], [], none⟩ =
      some ⟨desc, [], [], [], none⟩ := by
    cases desc with
    | none => rfl
    | some s => rfl
  rw [h1]
  simp only [Option.bind_eq_bind, Option.bind_some]
  rw [fold_blocks_root _ rfl blocks]
  simp only [Option.bind_some, List.nil_append]
  rw [fold_tms _ rfl rmath hT]
  simp only [Option.bind_some, List.nil_append]
  -- the sections
  have h2 : ∀ (cs : List (Comp MR)) (st : St), (∀ c ∈ cs, (∀ kv ∈ c.blocks, kv.1 ∉ mathFields) ∧
      ∀ kv ∈ c.mathBlocks, kv.1 ∈ mathFields) →
      (cs.flatMap compItems).foldlM step st =
        some (match cs.getLast? with
          | some c => { st with comps := st.comps ++ st.cur.toList ++ cs.dropLast, cur := some c }
          | none => st) := by
    intro cs
    induction cs with
    | nil => intro st _; simp
    | cons c cs ih =>
      intro st hcs
      simp only [List.flatMap_cons, List.foldlM_append]
      rw [fold_comp st c (hcs c List.mem_cons_self)]
      simp only [Option.bind_eq_bind, Option.bind_some]
      rw [ih _ (fun c' hc' => hcs c' (List.mem_cons_of_mem _ hc'))]
      congr 1
      cases hl : cs.getLast? with
      | none =>
        rw [List.getLast?_eq_none_iff] at hl
        subst hl
        simp
      | some c' =>
        have hne : cs ≠ [] := by intro h; subst h; simp at hl
        rw [List.getLast?_cons, hl]
        simp only [Option.getD_some, Option.toList_some, List.append_assoc]
        rw [List.dropLast_cons_of_ne_nil hne]
        simp
  rw [h2 comps _ hD]
  simp only [Option.map_some, Option.some.injEq, Doc.mk.injEq, true_and]
  cases hl : comps.getLast? with
  | none =>
    rw [List.getLast?_eq_none_iff] at hl
    subst hl; simp
  | some c =>
    simp only [Option.toList_none, List.append_nil, Option.toList_some, List.nil_append]
    exact ⟨trivial, trivial, trivial, List.dropLast_append_getLast? c hl⟩

/-! ## Math entries: printed under the symbol table, and read back -/

/-- Print every math entry under its symbol table: a top-level template under the
document's, a component's entry under the component's. -/
def rawDoc (pr : Sym → MC → MR) (D : Doc MC) : Doc MR :=
  ⟨D.front, D.desc, D.blocks, D.math.map (pr (topSym D)),
    D.comps.map (fun c => c.mapMath (fun c m => pr (symFor D c) m))⟩

/-- Read a component's math entries under its symbol table; one math text may hold
several equations (the multi-line variants). -/
def cookComp (ck : Sym → MR → Option (List MC)) (D : Doc MR) (c : Comp MR) : Option (Comp MC) :=
  (c.math.mapM (ck (symFor D c))).map (fun ms => { c with math := ms.flatten })

/-- Read every math entry of a skeleton. -/
def cookDoc (ck : Sym → MR → Option (List MC)) (D : Doc MR) : Option (Doc MC) := do
  let rm ← D.math.mapM (ck (topSym D))
  let cs ← D.comps.mapM (cookComp ck D)
  pure ⟨D.front, D.desc, D.blocks, rm.flatten, cs⟩

theorem mapM_singleton {α β : Type} (f : α → Option (List β)) (g : α → β) :
    ∀ l : List α, (∀ x ∈ l, f x = some [g x]) → (l.mapM f).map List.flatten = some (l.map g)
  | [], _ => rfl
  | x :: xs, h => by
    have ih := mapM_singleton f g xs (fun y hy => h y (List.mem_cons_of_mem _ hy))
    simp only [List.mapM_cons, h x List.mem_cons_self, Option.bind_eq_bind, Option.bind_some]
    cases hm : xs.mapM f with
    | none => rw [hm] at ih; cases ih
    | some ys =>
      rw [hm] at ih
      simp only [Option.map_some, Option.some.injEq] at ih
      simp [ih]

theorem mapM_flat_id {α : Type} (f : α → Option (List α)) (l : List α) (h : ∀ x ∈ l, f x = some [x]) :
    ∃ ys, l.mapM f = some ys ∧ ys.flatten = l := by
  have := mapM_singleton f id l h
  cases hm : l.mapM f with
  | none => rw [hm] at this; cases this
  | some ys => rw [hm] at this; simp at this; exact ⟨ys, rfl, this⟩

/-- The tables of a printed skeleton are those of the skeleton: the printer keeps every
header. -/
theorem topSym_rawDoc (pr : Sym → MC → MR) (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC) :
    topSym (rawDoc pr D) = topSym D := by
  simp only [topSym, rawDoc, rootTs, filterMap_head_map _ (hpr _)]

theorem symFor_rawDoc (pr : Sym → MC → MR) (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC) (c : Comp MC) :
    symFor (rawDoc pr D) (c.mapMath (fun c m => pr (symFor D c) m)) = symFor D c := by
  simp only [symFor, rawDoc, rootTs, filterMap_head_map _ (hpr _), symWith_mapMath]
  rw [compTs_mapMath _ (fun c => hpr _)]

/-- **Math entries read back** when each one does under its table. The table is the same
on both sides: `symFor` and `topSym` read headers, never math, and the printer keeps
headers. -/
theorem cookDoc_rawDoc (pr : Sym → MC → MR) (ck : Sym → MR → Option (List MC))
    (hpr : ∀ S, HeadsKept (pr S)) (D : Doc MC)
    (ht : ∀ m ∈ D.math, ck (topSym D) (pr (topSym D) m) = some [m])
    (h : ∀ c ∈ D.comps, ∀ m ∈ c.math, ck (symFor D c) (pr (symFor D c) m) = some [m]) :
    cookDoc ck (rawDoc pr D) = some D := by
  have hT := topSym_rawDoc pr hpr D
  have hS := symFor_rawDoc pr hpr D
  obtain ⟨front, desc, blocks, rmath, comps⟩ := D
  unfold cookDoc
  have h1 : (rawDoc pr ⟨front, desc, blocks, rmath, comps⟩).math.mapM
      (ck (topSym (rawDoc pr ⟨front, desc, blocks, rmath, comps⟩))) =
      (rmath.mapM (fun m => ck (topSym ⟨front, desc, blocks, rmath, comps⟩)
        (pr (topSym ⟨front, desc, blocks, rmath, comps⟩) m))) := by
    rw [hT]; simp only [rawDoc, List.mapM_map]; rfl
  rw [h1]
  obtain ⟨ys, hys, hyf⟩ := mapM_flat_id _ rmath ht
  rw [hys]
  simp only [Option.bind_eq_bind, Option.bind_some]
  have : ∀ c ∈ comps, cookComp ck (rawDoc pr ⟨front, desc, blocks, rmath, comps⟩)
      (c.mapMath (fun c m => pr (symFor ⟨front, desc, blocks, rmath, comps⟩ c) m)) = some c := by
    intro c hc
    unfold cookComp
    rw [hS c]
    simp only [Comp.mapMath]
    rw [List.mapM_map]
    have := mapM_singleton (fun m => ck (symFor ⟨front, desc, blocks, rmath, comps⟩ c)
      (pr (symFor ⟨front, desc, blocks, rmath, comps⟩ c) m)) id c.math (fun m hm => h c hc m hm)
    cases hm : c.math.mapM (fun m => ck (symFor ⟨front, desc, blocks, rmath, comps⟩ c)
        (pr (symFor ⟨front, desc, blocks, rmath, comps⟩ c) m)) with
    | none => rw [hm] at this; cases this
    | some ms =>
      rw [hm] at this
      simp only [Option.map_some, Option.some.injEq, List.map_id_fun, id_eq] at this
      simp only [Function.comp_def, hm, Option.map_some, this]
  have h2 : (rawDoc pr ⟨front, desc, blocks, rmath, comps⟩).comps.mapM
      (cookComp ck (rawDoc pr ⟨front, desc, blocks, rmath, comps⟩)) = some comps := by
    show (List.map _ comps).mapM _ = _
    rw [List.mapM_map]
    exact (mapM_some _ id comps (fun c hc => this c hc)).trans (by simp)
  rw [h2]
  simp [rawDoc, hyf]

/-! ## A container's math printer and reader, entry by entry -/

/-- Print a math entry with the container's equation printer and expression printer. -/
def prMx (prE : Sym → Eqn → String) (prR : Sym → Json → String) (S : Sym) : MC → MR
  | .eq r e => .eq r (prE S e)
  | .rxn x => .rxn { x with rate := prR S x.rate }
  | .plot a => .plot a
  | .tm t => .tm { t with lhs := t.lhs.map (prR (t.scope S)), body := prR (t.scope S) t.body }

theorem prMx_heads (prE : Sym → Eqn → String) (prR : Sym → Json → String) (S : Sym) :
    HeadsKept (prMx prE prR S) := by
  intro m
  cases m with
  | tm t => cases hl : t.lhs <;> simp [prMx, Mx.head, Tm.ps, hl]
  | _ => rfl

/-- Read a math entry with the container's equation reader and expression reader. -/
def ckMx (ckE : Sym → String → Option (List Eqn)) (ckR : Sym → String → Option Json) (S : Sym) :
    MR → Option (List MC)
  | .eq r raw => (ckE S raw).map (fun es => es.map (.eq r))
  | .rxn x => (ckR S x.rate).map (fun j => [.rxn { x with rate := j }])
  | .plot a => some [.plot a]
  | .tm t =>
    match t.lhs with
    | none => (ckR (t.scope S) t.body).map (fun b => [.tm { t with lhs := none, body := b }])
    | some l =>
      match ckR (t.scope S) l, ckR (t.scope S) t.body with
      | some l', some b => some [.tm { t with lhs := some l', body := b }]
      | _, _ => none

theorem ckMx_prMx (prE : Sym → Eqn → String) (prR : Sym → Json → String)
    (ckE : Sym → String → Option (List Eqn)) (ckR : Sym → String → Option Json) (S : Sym)
    (m : MC) (hE : ∀ r e, m = .eq r e → ckE S (prE S e) = some [e])
    (hR : ∀ x, m = .rxn x → ckR S (prR S x.rate) = some x.rate)
    (hT : ∀ t, m = .tm t → ckR (t.scope S) (prR (t.scope S) t.body) = some t.body ∧
      ∀ l, t.lhs = some l → ckR (t.scope S) (prR (t.scope S) l) = some l) :
    ckMx ckE ckR S (prMx prE prR S m) = some [m] := by
  cases m with
  | eq r e => simp [prMx, ckMx, hE r e rfl]
  | rxn x => simp [prMx, ckMx, hR x rfl]
  | plot a => rfl
  | tm t =>
    obtain ⟨hb, hl⟩ := hT t rfl
    obtain ⟨n, ps, lhs, body, as⟩ := t
    cases lhs with
    | none =>
      have e : Tm.scope S (⟨n, ps, none, prR (Tm.scope S ⟨n, ps, none, body, as⟩) body, as⟩ : Tm String) =
          Tm.scope S (⟨n, ps, none, body, as⟩ : Tm Json) := rfl
      simp only [prMx, ckMx, Option.map_none, e]
      simp only at hb
      rw [hb]; rfl
    | some l =>
      have e : Tm.scope S (⟨n, ps, some (prR (Tm.scope S ⟨n, ps, some l, body, as⟩) l),
          prR (Tm.scope S ⟨n, ps, some l, body, as⟩) body, as⟩ : Tm String) =
          Tm.scope S (⟨n, ps, some l, body, as⟩ : Tm Json) := rfl
      simp only [prMx, ckMx, Option.map_some, e]
      simp only at hb hl
      rw [hl l rfl, hb]

end Esm.Document.Source
