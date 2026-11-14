import Esm.Document.Source.Keys

/-!
# The document skeleton

The document layer maps an ESM document (a JSON object in canonical form) to a
*skeleton*: the front matter, the description, the path blocks, and one section per
model or reaction system with its description, its declarations, its equations and
its own path blocks. Each container (Markdown, Typst) then spells the skeleton; this
module is container-independent except for `Caps`, the predicates saying which values
a container can spell natively.

The mapping is total. Every field without a surface of its own (and every field whose
value a container cannot spell natively) falls back to a block keyed by its JSON path
relative to the enclosing section (`Notation.Home.pathBlock`). So every canonical
document round-trips (`ofDoc_toDoc`), and a nicer surface for some field is a change to
this file, not to the containers.

Native surfaces (`Notation.skeleton`):

* the front matter: `esm` and the entries of `metadata` other than `description`;
* the description block: `metadata.description`, and a component's `description`;
* component directives: the entries of `models` and `reaction_systems`;
* declarations: a model's `variables` (`:var`, and `:param` for `type: "parameter"`), a
  reaction system's `species` (`:species`) and `parameters` (`:param`);
* the math entries of a component: its `equations` (display math, one equation each),
  its `initialization_equations` and `constraint_equations` (display math marked as
  such), and its `reactions` (one reaction line each). Each of these four fields is
  native when every one of its entries is, and otherwise one path block.

Everything else is a path block.

The math entries are printed under the component's symbol table (`symFor`), which is
computed from the rest of the skeleton only, so the parser can build the same table
before it reads any math (`symFor_mapMath`).
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-! ## The canonical form of a document -/

mutual
/-- Every object, at every depth, has strictly increasing keys. -/
def sortedDeep : Json → Bool
  | .obj kvs => keysSorted kvs && sortedDeepObj kvs
  | .arr xs => sortedDeepList xs
  | _ => true

def sortedDeepList : List Json → Bool
  | [] => true
  | v :: vs => sortedDeep v && sortedDeepList vs

def sortedDeepObj : List (String × Json) → Bool
  | [] => true
  | (_, v) :: es => sortedDeep v && sortedDeepObj es
end

/-- A document in canonical form: a JSON object, well formed (canonical numbers,
distinct keys) with sorted keys at every depth. -/
def canonDoc : Json → Bool
  | .obj kvs => jwf (.obj kvs) && sortedDeep (.obj kvs)
  | _ => false

theorem sortedDeepObj_mem : ∀ {kvs : List (String × Json)} {k : String} {v : Json},
    sortedDeepObj kvs = true → (k, v) ∈ kvs → sortedDeep v = true
  | (k', v') :: es, k, v, h, hm => by
    simp only [sortedDeepObj, Bool.and_eq_true] at h
    rcases List.mem_cons.mp hm with he | hm
    · cases he; exact h.1
    · exact sortedDeepObj_mem h.2 hm

theorem jwfObj_mem : ∀ {kvs : List (String × Json)} {k : String} {v : Json},
    jwfObj kvs = true → (k, v) ∈ kvs → jwf v = true
  | (k', v') :: es, k, v, h, hm => by
    simp only [jwfObj, Bool.and_eq_true] at h
    rcases List.mem_cons.mp hm with he | hm
    · cases he; exact h.1
    · exact jwfObj_mem h.2 hm

/-- A value that is canonical as a part of a document: well formed, sorted keys. -/
def canonVal (v : Json) : Bool := jwf v && sortedDeep v

theorem canonVal_obj_sorted {kvs : List (String × Json)} (h : canonVal (.obj kvs) = true) :
    keysSorted kvs = true := by
  simp only [canonVal, sortedDeep, Bool.and_eq_true] at h
  exact h.2.1

theorem canonVal_mem {kvs : List (String × Json)} {k : String} {v : Json}
    (h : canonVal (.obj kvs) = true) (hm : (k, v) ∈ kvs) : canonVal v = true := by
  simp only [canonVal, sortedDeep, jwf, Bool.and_eq_true] at h
  simp only [canonVal, Bool.and_eq_true]
  exact ⟨jwfObj_mem h.1.2 hm, sortedDeepObj_mem h.2.2 hm⟩

theorem look_mem' : ∀ {k : String} {kvs : List (String × Json)} {v : Json},
    look k kvs = some v → (k, v) ∈ kvs
  | _, [], _, h => by cases h
  | k, (k', v') :: r, v, h => by
    simp only [look] at h
    split at h
    · cases h; rename_i hk; subst hk; exact List.mem_cons_self
    · exact List.mem_cons_of_mem _ (look_mem' h)

theorem canonVal_look {kvs : List (String × Json)} {k : String} {v : Json}
    (h : canonVal (.obj kvs) = true) (hl : look k kvs = some v) : canonVal v = true :=
  canonVal_mem h (look_mem' hl)

/-! ## The skeleton -/

/-- The two kinds of component, each with its own directive. -/
inductive Kind where
  | model
  | rs
  deriving DecidableEq, Repr

/-- The declaration directives. -/
inductive DKind where
  | var
  | param
  | species
  deriving DecidableEq, Repr

/-- A declaration: the directive, the declared name, and the other fields of the
declared object as attributes. -/
structure Decl where
  kind : DKind
  name : String
  attrs : List (String × Json)

/-- An equation: `lhs = rhs`, with its optional `_comment`. -/
structure Eqn where
  comment : Option String
  lhs : Json
  rhs : Json

/-- The field an equation belongs to. -/
inductive Role where
  | eqn
  | init
  | cons
  deriving DecidableEq, Repr

def Role.field : Role → String
  | .eqn => "equations"
  | .init => "initialization_equations"
  | .cons => "constraint_equations"

/-- One term of a reaction side: a species and its stoichiometric coefficient. -/
structure Term where
  species : String
  coef : JNum

/-- A reaction: its `id`, its sides (`none` for an empty side, JSON `null`), its rate
(`ρ`: the expression, or its math text), and its other fields. -/
structure Rxn (ρ : Type) where
  id : String
  subs : Option (List Term)
  prods : Option (List Term)
  rate : ρ
  attrs : List (String × Json)

/-- A math entry of a component: an equation of one of the three equation fields (`α`:
the equation, or its math text), or a reaction. -/
inductive Mx (α ρ : Type) where
  | eq (r : Role) (e : α)
  | rxn (x : Rxn ρ)

/-- A math entry as read. -/
abbrev MC := Mx Eqn Json
/-- A math entry as the container's text. -/
abbrev MR := Mx String String

/-- The field a math entry belongs to. -/
def Mx.field {α ρ : Type} : Mx α ρ → String
  | .eq r _ => r.field
  | .rxn _ => "reactions"

/-- The math fields, in key order. -/
def mathFields : List String :=
  ["constraint_equations", "equations", "initialization_equations", "reactions"]

/-- One component section. `α` is how a math entry is held: `MC` in the semantic
skeleton, `MR` (the container's math text) in the raw one. `mathBlocks` holds the math
fields that are not printed natively. -/
structure Comp (α : Type) where
  kind : Kind
  name : String
  desc : Option String
  decls : List Decl
  math : List α
  mathBlocks : List (String × Json)
  blocks : List (String × Json)

/-- A document skeleton: the front matter entries, the document description, the
top-level path blocks, and the component sections in order. -/
structure Doc (α : Type) where
  front : List (String × Json)
  desc : Option String
  blocks : List (String × Json)
  comps : List (Comp α)

/-- Change how math entries are held. -/
def Comp.mapMath {α β : Type} (f : Comp α → α → β) (c : Comp α) : Comp β :=
  { c with math := c.math.map (f c) }

/-! ## The symbol table of a component -/

/-- The keys of an object value. -/
def keysOf : Option Json → List String
  | some (.obj kvs) => kvs.map Prod.fst
  | _ => []

/-- The string entries of an array value. -/
def strsOf : Option Json → List String
  | some (.arr xs) => xs.filterMap (fun x => match x with | .str s => some s | _ => none)
  | _ => []

/-- The parameter list of every template of an `expression_templates` value. -/
def templatesOf : Option Json → List (String × List String)
  | some (.obj kvs) => kvs.filterMap (fun kv => match kv.2 with
      | .obj t => some (kv.1, strsOf (look "params" t))
      | _ => none)
  | _ => []

/-- **The symbol table of a component** (Phase 2 `Sym`): the names it declares (its
declarations and the entries of its declaration fields printed as blocks) and the
document's index sets; the templates of the document and of the component. It reads
the top-level blocks and the component's declarations and blocks only, never an
math entry, so the parser builds it before reading any math. -/
def symFor {α : Type} (root : List (String × Json)) (c : Comp α) : Sym :=
  { names := c.decls.map Decl.name ++ keysOf (look "variables" c.blocks) ++
      keysOf (look "species" c.blocks) ++ keysOf (look "parameters" c.blocks) ++
      keysOf (look "index_sets" root),
    templates := templatesOf (look "expression_templates" root) ++
      templatesOf (look "expression_templates" c.blocks) }

/-- The printer and the parser derive the same table: it does not depend on how the
math entries are held, nor on the math fallbacks. -/
theorem symFor_mapMath {α β : Type} (root : List (String × Json)) (f : Comp α → α → β)
    (c : Comp α) : symFor root (c.mapMath f) = symFor root c := rfl

theorem symFor_math {α : Type} (root : List (String × Json)) (c : Comp α)
    (bs : List (String × Json)) (ms : List α) :
    symFor root { c with mathBlocks := bs, math := ms } = symFor root c := rfl

/-! ## What a container can spell natively -/

/-- The container-specific predicates. A value failing one of them falls back to a
path block (or, for an equation, the whole `equations` field does). -/
structure Caps where
  /-- A front-matter key (Typst: a named argument, so an identifier). -/
  frontKey : String → Bool
  /-- A description text. -/
  desc : String → Bool
  /-- A component name in its directive. -/
  compName : String → Bool
  /-- A declared name (printed as math). -/
  declName : String → Bool
  /-- A declaration attribute. -/
  attr : String × Json → Bool
  /-- An equation under the component's symbol table. -/
  eqn : Sym → Eqn → Bool
  /-- A reaction under the component's symbol table. -/
  rxn : Sym → Rxn Json → Bool

/-- A math entry the container spells. -/
def Caps.item (caps : Caps) (S : Sym) : MC → Bool
  | .eq _ e => caps.eqn S e
  | .rxn x => caps.rxn S x

/-! ## Equations -/

/-- The JSON value of an equation. -/
def eqnJson (e : Eqn) : Json :=
  match e.comment with
  | some c => .obj [("_comment", .str c), ("lhs", e.lhs), ("rhs", e.rhs)]
  | none => .obj [("lhs", e.lhs), ("rhs", e.rhs)]

/-- The equation a JSON value is, when it has exactly the keys `lhs`, `rhs` and
optionally a string `_comment`, and both sides are well-formed expressions. -/
def eqnOf : Json → Option Eqn
  | .obj [("_comment", .str c), ("lhs", l), ("rhs", r)] =>
    if isE l && isE r then some ⟨some c, l, r⟩ else none
  | .obj [("lhs", l), ("rhs", r)] => if isE l && isE r then some ⟨none, l, r⟩ else none
  | _ => none

theorem eqnJson_eqnOf {j : Json} {e : Eqn} (h : eqnOf j = some e) : eqnJson e = j := by
  unfold eqnOf at h
  split at h
  · split at h
    · cases h; rfl
    · cases h
  · split at h
    · cases h; rfl
    · cases h
  · cases h

/-! ## Reactions -/

def termJson (t : Term) : Json := .obj [("species", .str t.species), ("stoichiometry", .num t.coef)]

def termOf : Json → Option Term
  | .obj [("species", .str s), ("stoichiometry", .num n)] => some ⟨s, n⟩
  | _ => none

/-- A reaction side: JSON `null` for an empty side, else a non-empty array. -/
def sideJson : Option (List Term) → Json
  | none => .null
  | some ts => .arr (ts.map termJson)

def sideOf : Json → Option (Option (List Term))
  | .null => some none
  | .arr (x :: xs) => ((x :: xs).mapM termOf).map some
  | _ => none

/-- The keys of a reaction with a surface of their own; every other key is an
attribute. -/
def rxnKeys : List String := ["id", "products", "rate", "substrates"]

def rxnJson (x : Rxn Json) : Json :=
  .obj (sortKeys ([("id", .str x.id), ("products", sideJson x.prods), ("rate", x.rate),
    ("substrates", sideJson x.subs)] ++ x.attrs))

/-- The reaction a JSON value is, checked by printing it back: its `id` is a string, both
sides are present, and the rate is an expression. -/
def rxnOf (v : Json) : Option (Rxn Json) :=
  match v with
  | .obj kvs =>
    match look "id" kvs, (look "substrates" kvs).bind sideOf, (look "products" kvs).bind sideOf,
      look "rate" kvs with
    | some (.str i), some s, some p, some r =>
      let x : Rxn Json := ⟨i, s, p, r, kvs.filter (fun kv => !rxnKeys.contains kv.1)⟩
      if rxnJson x = v ∧ isE r = true then some x else none
    | _, _, _, _ => none
  | _ => none

theorem rxnOf_some {v : Json} {x : Rxn Json} (h : rxnOf v = some x) :
    rxnJson x = v ∧ isE x.rate = true := by
  unfold rxnOf at h
  split at h
  · split at h
    · simp only at h
      split at h
      · cases h; assumption
      · cases h
    · cases h
  · cases h

/-! ## Math entries -/

/-- The JSON value of a math entry. -/
def itemJson : MC → Json
  | .eq _ e => eqnJson e
  | .rxn x => rxnJson x

/-- The role of an equation field. -/
def roleOf (f : String) : Option Role := [Role.eqn, .init, .cons].find? (fun r => r.field == f)

/-- The math entry an entry of the math field `f` is. -/
def itemOf (f : String) (v : Json) : Option MC :=
  if f = "reactions" then (rxnOf v).map .rxn
  else (roleOf f).bind (fun r => (eqnOf v).map (.eq r))

/-- Well-formed expressions throughout. -/
def mathWF : MC → Bool
  | .eq _ e => isE e.lhs && isE e.rhs
  | .rxn x => isE x.rate

theorem roleOf_some {f : String} {r : Role} (h : roleOf f = some r) : r.field = f := by
  unfold roleOf at h
  have := List.find?_some h
  simpa using this

theorem eqnOf_isE {j : Json} {e : Eqn} (h : eqnOf j = some e) : isE e.lhs = true ∧ isE e.rhs = true := by
  unfold eqnOf at h
  split at h
  · split at h
    · cases h; simp_all
    · cases h
  · split at h
    · cases h; simp_all
    · cases h
  · cases h

theorem itemOf_some {f : String} {v : Json} {m : MC} (h : itemOf f v = some m) :
    itemJson m = v ∧ m.field = f ∧ mathWF m = true := by
  unfold itemOf at h
  split at h
  · rename_i hf
    simp only [Option.map_eq_some_iff] at h
    obtain ⟨x, hx, rfl⟩ := h
    obtain ⟨h1, h2⟩ := rxnOf_some hx
    exact ⟨h1, hf.symm, h2⟩
  · simp only [Option.bind_eq_some_iff, Option.map_eq_some_iff] at h
    obtain ⟨r, hr, e, he, rfl⟩ := h
    have := eqnOf_isE he
    exact ⟨eqnJson_eqnOf he, roleOf_some hr, by simp [mathWF, this.1, this.2]⟩

/-- The entries of a math field, when all of them print natively. -/
def mathOf (caps : Caps) (S : Sym) (f : String) : Json → Option (List MC)
  | .arr (x :: xs) =>
    match (x :: xs).mapM (itemOf f) with
    | some ms => if ms.all (caps.item S) then some ms else none
    | none => none
  | _ => none

theorem mapM_itemOf {f : String} : ∀ {xs : List Json} {ms : List MC}, xs.mapM (itemOf f) = some ms →
    xs = ms.map itemJson ∧ ∀ m ∈ ms, m.field = f ∧ mathWF m = true
  | [], ms, h => by simp at h; subst h; simp
  | y :: ys, ms, h => by
    simp only [List.mapM_cons, Option.bind_eq_bind] at h
    cases hy : itemOf f y with
    | none => simp [hy] at h
    | some my =>
      cases hys : ys.mapM (itemOf f) with
      | none => simp [hy, hys] at h
      | some mys =>
        simp [hy, hys] at h
        subst h
        obtain ⟨h1, h2, h3⟩ := itemOf_some hy
        obtain ⟨h4, h5⟩ := mapM_itemOf hys
        refine ⟨by simp [h1, h4], ?_⟩
        intro m hm
        rcases List.mem_cons.mp hm with rfl | hm
        · exact ⟨h2, h3⟩
        · exact h5 m hm

theorem mathOf_some {caps : Caps} {S : Sym} {f : String} {j : Json} {ms : List MC}
    (h : mathOf caps S f j = some ms) :
    j = .arr (ms.map itemJson) ∧ ms ≠ [] ∧
      ∀ m ∈ ms, m.field = f ∧ mathWF m = true ∧ caps.item S m = true := by
  unfold mathOf at h
  split at h
  · rename_i x xs
    split at h
    · rename_i ms' hm
      split at h
      · cases h
        rename_i hall
        obtain ⟨h1, h2⟩ := mapM_itemOf hm
        refine ⟨by rw [h1], ?_, fun m hm' => ⟨(h2 m hm').1, (h2 m hm').2, List.all_eq_true.mp hall m hm'⟩⟩
        intro he
        rw [he] at h1
        cases h1
      · cases h
    · cases h
  · cases h

/-! ## From a document to its skeleton -/

/-- A description that prints natively. -/
def descOf (caps : Caps) : Option Json → Option String
  | some (.str s) => if caps.desc s then some s else none
  | _ => none

/-- `metadata` printed in the front matter: a non-empty object without an `esm` key
whose keys the container can spell there. Returns the front-matter entries and the
description. -/
def metaOf (caps : Caps) : Option Json → Option (List (String × Json) × Option String)
  | some (.obj kvs) =>
    if !kvs.isEmpty && (look "esm" kvs).isNone && kvs.all (fun kv => caps.frontKey kv.1) then
      let d := descOf caps (look "description" kvs)
      some (kvs.filter (fun kv => !(kv.1 == "description" && d.isSome)), d)
    else none
  | _ => none

/-- A model variable as a declaration: `:param` for `type: "parameter"`, `:var`
otherwise; the `type` attribute is left out when it is `"unknown"` (the meaning of
`:var`) or `"parameter"`. A variable without `type` stays in the block. -/
def pickVar (caps : Caps) (n : String) (v : Json) : Option Decl :=
  if !caps.declName n then none else
  match v with
  | .obj kvs =>
    match look "type" kvs with
    | some (.str "parameter") =>
      let a := kvs.filter (fun kv => kv.1 != "type")
      if a.all caps.attr then some ⟨.param, n, a⟩ else none
    | some (.str "unknown") =>
      let a := kvs.filter (fun kv => kv.1 != "type")
      if a.all caps.attr then some ⟨.var, n, a⟩ else none
    | some _ => if kvs.all caps.attr then some ⟨.var, n, kvs⟩ else none
    | none => none
  | _ => none

/-- A reaction-system species or parameter as a declaration of kind `k`. -/
def pickPlain (caps : Caps) (k : DKind) (n : String) (v : Json) : Option Decl :=
  if !caps.declName n then none else
  match v with
  | .obj kvs => if kvs.all caps.attr then some ⟨k, n, kvs⟩ else none
  | _ => none

/-- The declaration fields of a component kind, with their pickers. -/
def declFields (caps : Caps) : Kind → List (String × (String → Json → Option Decl))
  | .model => [("variables", pickVar caps)]
  | .rs => [("species", pickPlain caps .species), ("parameters", pickPlain caps .param)]

/-- The field a declaration of kind `k` belongs to, in a component of kind `K`. -/
def declField : Kind → DKind → Option String
  | .model, .var => some "variables"
  | .model, .param => some "variables"
  | .model, .species => none
  | .rs, .species => some "species"
  | .rs, .param => some "parameters"
  | .rs, .var => none

/-- The entry a declaration stands for, in a component of kind `K`. -/
def backDecl (K : Kind) (d : Decl) : Option (String × Json) :=
  match K, d.kind with
  | .model, .param =>
    if d.attrs.any (fun kv => kv.1 == "type") then none
    else some (d.name, .obj (sortKeys (("type", .str "parameter") :: d.attrs)))
  | .model, .var =>
    if d.attrs.any (fun kv => kv.1 == "type") then some (d.name, .obj (sortKeys d.attrs))
    else some (d.name, .obj (sortKeys (("type", .str "unknown") :: d.attrs)))
  | .rs, .species => some (d.name, .obj (sortKeys d.attrs))
  | .rs, .param => some (d.name, .obj (sortKeys d.attrs))
  | _, _ => none

/-- Where an entry of a component goes when it is not a native surface: the
description when it does not print natively, every entry without a surface of its own,
and the residue of each declaration field; the math fields are decided later. -/
def compBlock (caps : Caps) (K : Kind) (desc : Option String) (kv : String × Json) :
    Option (String × Json) :=
  if kv.1 = "description" then (if desc.isSome then none else some kv)
  else if kv.1 ∈ mathFields then none
  else match (declFields caps K).lookup kv.1 with
    | some pick => (splitOpt pick (some kv.2)).2.map (fun r => (kv.1, r))
    | none => some kv

/-- A component, before its equations are decided: its description, its declarations,
and its blocks. -/
def compBase (caps : Caps) (K : Kind) (name : String) (kvs : List (String × Json)) : Comp MC :=
  let desc := descOf caps (look "description" kvs)
  { kind := K, name := name, desc := desc,
    decls := (declFields caps K).flatMap (fun f => (splitOpt f.2 (look f.1 kvs)).1),
    math := [], mathBlocks := [],
    blocks := kvs.filterMap (compBlock caps K desc) }

/-- One math field of a component: its entries when every one prints natively under the
symbol table `S`, else its block. -/
def mathPart (caps : Caps) (S : Sym) (kvs : List (String × Json)) (f : String) :
    List MC × Option (String × Json) :=
  match look f kvs with
  | none => ([], none)
  | some v =>
    match mathOf caps S f v with
    | some ms => (ms, none)
    | none => ([], some (f, v))

/-- A component: `compBase`, then its math fields, each native when every entry prints
natively under the component's symbol table, else a block. -/
def compOf (caps : Caps) (root : List (String × Json)) (K : Kind) (name : String)
    (kvs : List (String × Json)) : Comp MC :=
  let c := compBase caps K name kvs
  let ps := mathFields.map (mathPart caps (symFor root c) kvs)
  { c with math := ps.flatMap Prod.fst, mathBlocks := ps.filterMap Prod.snd }

/-- A component entry prints as a directive when its name does and it is an object. -/
def pickComp (caps : Caps) (n : String) (v : Json) : Option (String × List (String × Json)) :=
  match v with
  | .obj kvs => if caps.compName n then some (n, kvs) else none
  | _ => none

/-- Where a top-level entry goes when it is not a native surface: every entry without
a surface of its own, the residues of `models` and `reaction_systems`, and `metadata`
when it is not in the front matter. -/
def rootBlock (caps : Caps) (kv : String × Json) : Option (String × Json) :=
  if kv.1 = "esm" then none
  else if kv.1 = "metadata" then (if (metaOf caps (some kv.2)).isSome then none else some kv)
  else if kv.1 = "models" ∨ kv.1 = "reaction_systems" then
    (splitOpt (pickComp caps) (some kv.2)).2.map (fun r => (kv.1, r))
  else some kv

/-- The top-level blocks. -/
def rootBlocks (caps : Caps) (kvs : List (String × Json)) : List (String × Json) :=
  kvs.filterMap (rootBlock caps)

/-- **The skeleton of a document.** -/
def toDoc (caps : Caps) : Json → Doc MC
  | .obj kvs =>
    let m := metaOf caps (look "metadata" kvs)
    let blocks := rootBlocks caps kvs
    let comps (K : Kind) (f : String) :=
      (splitOpt (pickComp caps) (look f kvs)).1.map (fun p => compOf caps blocks K p.1 p.2)
    { front := at_ "esm" kvs ++ (m.map Prod.fst).getD [],
      desc := m.bind Prod.snd,
      blocks := blocks,
      comps := comps .model "models" ++ comps .rs "reaction_systems" }
  | _ => { front := [], desc := none, blocks := [], comps := [] }

/-! ## From a skeleton back to the document -/

/-- An optional entry as a list. -/
def optKv (k : String) : Option Json → List (String × Json)
  | some v => [(k, v)]
  | none => []

/-- One rebuilt math field: its entries, or its block, or neither. -/
def mathKv (c : Comp MC) (f : String) : Option (List (String × Json)) :=
  match c.math.filter (fun m => m.field == f), at_ f c.mathBlocks with
  | [], [] => some []
  | [], [(_, v)] => some [(f, v)]
  | m :: ms, [] => some [(f, .arr ((m :: ms).map itemJson))]
  | _, _ => none

/-- The rebuilt math fields. -/
def mathKvs (c : Comp MC) : Option (List (String × Json)) :=
  (mathFields.mapM (mathKv c)).map List.flatten

/-- The names of the declaration fields of a component kind. -/
def declFieldNames : Kind → List String
  | .model => ["variables"]
  | .rs => ["species", "parameters"]

theorem declFields_names (caps : Caps) (K : Kind) :
    (declFields caps K).map Prod.fst = declFieldNames K := by
  cases K <;> rfl

/-- One rebuilt declaration field: its declarations joined with its residue block. -/
def declKv (K : Kind) (c : Comp MC) (f : String) : Option (List (String × Json)) := do
  let r ← pickOne f c.blocks
  let v ← joinField (backDecl K) (c.decls.filter (fun d => declField K d.kind == some f)) r
  pure (optKv f v)

/-- The rebuilt declaration fields; a declaration of a kind the component does not
have (`:species` in a model) is refused. -/
def declKvs (K : Kind) (c : Comp MC) : Option (List (String × Json)) :=
  if c.decls.all (fun d => (declField K d.kind).isSome) then
    ((declFieldNames K).mapM (declKv K c)).map List.flatten
  else none

/-- **A component rebuilt from its section.** -/
def ofComp (c : Comp MC) : Option Json := do
  let ds ← declKvs c.kind c
  let es ← mathKvs c
  let others := c.blocks.filter (fun kv => !(declFieldNames c.kind).contains kv.1)
  pure (.obj (sortKeys (optKv "description" (c.desc.map Json.str) ++ ds ++ es ++ others)))

/-- A component back to its entry. -/
def backComp (c : Comp MC) : Option (String × Json) := (ofComp c).map (fun v => (c.name, v))

/-- **A document rebuilt from its skeleton.** The result is checked to be canonical,
which rejects a field written twice (once natively and once in a block, say). -/
def ofDoc (D : Doc MC) : Option Json := do
  let esmKv := at_ "esm" D.front
  let metaEs := D.front.filter (fun kv => kv.1 != "esm") ++ optKv "description" (D.desc.map Json.str)
  let metaKv := if metaEs.isEmpty then [] else [("metadata", Json.obj (sortKeys metaEs))]
  let mr ← pickOne "models" D.blocks
  let models ← joinField backComp (D.comps.filter (fun c => c.kind == .model)) mr
  let rr ← pickOne "reaction_systems" D.blocks
  let rss ← joinField backComp (D.comps.filter (fun c => c.kind == .rs)) rr
  let others := D.blocks.filter (fun kv => kv.1 != "models" && kv.1 != "reaction_systems")
  let d := Json.obj (sortKeys (esmKv ++ metaKv ++ optKv "models" models ++
    optKv "reaction_systems" rss ++ others))
  if canonDoc d then pure d else none

end Esm.Document.Source
