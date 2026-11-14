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
  reaction system's `species` (`:species`) and `parameters` (`:param`), and the entries
  of a component's `subsystems` that are included by reference (`ref`), as subsystem
  directives (an inline subsystem stays in the `subsystems` block);
* the list entries of a component: its `equations` (display math, one equation each),
  its `initialization_equations` and `constraint_equations` (display math marked as
  such), its `reactions` (one reaction line each), and its `analyses` (a plot directive
  each, for an analysis with exactly one plot), and the entries of its
  `expression_templates` (a template display or a rule each, `Tm`). Each of these six
  fields is native when every one of its entries is, and otherwise one path block;
* the top-level `expression_templates` of a library file, the same way (`Doc.math`).

Everything else is a path block.

The math entries are printed under the component's symbol table (`symFor`), which is
computed from the rest of the skeleton and the template headers only (never a template's
math), so the parser can build the same table before it reads any math
(`symFor_rawDoc`); the top-level templates are printed under the document's (`topSym`).
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

/-- The declaration directives. `sub` is a subsystem included by reference, printed as a
directive of its own line. -/
inductive DKind where
  | var
  | param
  | species
  | sub
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

/-- An entry of `expression_templates`: a template (`lhs = none`, applied by name) or a
rewrite rule (`lhs = some m`, its `match`). Its name, its parameter list (a template's,
from its header; a rule's `params` stay among its attributes, `params` here is `[]`), its
body (`ρ`: the expression, or its math text), and its other fields. -/
structure Tm (ρ : Type) where
  name : String
  params : List String
  lhs : Option ρ
  body : ρ
  attrs : List (String × Json)

/-- A list entry of a component: an equation of one of the three equation fields (`α`:
the equation, or its math text), a reaction, an analysis with one plot (its fields,
with `plots` replaced by `plot`, the one plot), or an entry of `expression_templates`. -/
inductive Mx (α ρ : Type) where
  | eq (r : Role) (e : α)
  | rxn (x : Rxn ρ)
  | plot (attrs : List (String × Json))
  | tm (t : Tm ρ)

/-- A math entry as read. -/
abbrev MC := Mx Eqn Json
/-- A math entry as the container's text. -/
abbrev MR := Mx String String

/-- The field a math entry belongs to. -/
def Mx.field {α ρ : Type} : Mx α ρ → String
  | .eq r _ => r.field
  | .rxn _ => "reactions"
  | .plot _ => "analyses"
  | .tm _ => "expression_templates"

/-- The key of an entry of an object-valued field (a template's name). -/
def Mx.key {α ρ : Type} : Mx α ρ → String
  | .tm t => t.name
  | _ => ""

/-- The fields with entries of their own, in key order. `expression_templates` is an
object (its entries keyed by name); the others are lists. -/
def mathFields : List String :=
  ["analyses", "constraint_equations", "equations", "expression_templates",
    "initialization_equations", "reactions"]

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
top-level path blocks, the top-level templates (`expression_templates` of a library
file), and the component sections in order. -/
structure Doc (α : Type) where
  front : List (String × Json)
  desc : Option String
  blocks : List (String × Json)
  math : List α
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

/-- The parameter list a template or rule brings into its body's scope: a template's
header parameters; a rule's `params` attribute. -/
def Tm.ps {ρ : Type} (t : Tm ρ) : List String :=
  match t.lhs with
  | none => t.params
  | some _ => strsOf (look "params" t.attrs)

/-- The symbol-table entry of a template or rule: its name and parameters. -/
def Mx.head {α ρ : Type} : Mx α ρ → Option (String × List String)
  | .tm t => some (t.name, t.ps)
  | _ => none

/-- The symbol table a template's body is read under: the table around it, with the
template's parameters declared. -/
def Tm.scope {ρ : Type} (S : Sym) (t : Tm ρ) : Sym := { S with names := S.names ++ t.ps }

/-- The templates of the document: those of the top-level block, then the top-level
template entries. -/
def rootTs {α ρ : Type} (root : List (String × Json)) (rm : List (Mx α ρ)) :
    List (String × List String) :=
  templatesOf (look "expression_templates" root) ++ rm.filterMap Mx.head

/-- The templates of a component: those of its block, then its template entries. -/
def compTs {α ρ : Type} (c : Comp (Mx α ρ)) : List (String × List String) :=
  templatesOf (look "expression_templates" c.mathBlocks) ++ c.math.filterMap Mx.head

/-- A component's symbol table, given the document's templates `rt` and the component's
own `ct`: the names it declares (its declarations and the entries of its declaration
fields printed as blocks) and the document's index sets. -/
def symWith {α : Type} (root : List (String × Json)) (rt : List (String × List String))
    (c : Comp α) (ct : List (String × List String)) : Sym :=
  { names := (c.decls.filter (fun d => d.kind != .sub)).map Decl.name ++
      keysOf (look "variables" c.blocks) ++
      keysOf (look "species" c.blocks) ++ keysOf (look "parameters" c.blocks) ++
      keysOf (look "index_sets" root),
    templates := rt ++ ct }

/-- **The symbol table of a component** (Phase 2 `Sym`): its declared names and the
document's index sets; the templates of the document and of the component. It reads the
top-level blocks, the component's declarations and blocks, and the headers of the template
entries (name and parameters, never the math of a body), so the parser builds it before
reading any math. -/
def symFor {α ρ : Type} (D : Doc (Mx α ρ)) (c : Comp (Mx α ρ)) : Sym :=
  symWith D.blocks (rootTs D.blocks D.math) c (compTs c)

/-- The symbol table of the top-level templates: the document's index sets and
templates. -/
def topSym {α ρ : Type} (D : Doc (Mx α ρ)) : Sym :=
  { names := keysOf (look "index_sets" D.blocks), templates := rootTs D.blocks D.math }

/-- A map of entries that keeps every header. -/
def HeadsKept {α ρ β σ : Type} (f : Mx α ρ → Mx β σ) : Prop := ∀ m, (f m).head = m.head

theorem filterMap_head_map {α ρ β σ : Type} (f : Mx α ρ → Mx β σ) (hf : HeadsKept f)
    (l : List (Mx α ρ)) : (l.map f).filterMap Mx.head = l.filterMap Mx.head := by
  induction l with
  | nil => rfl
  | cons m l ih => simp only [List.map_cons, List.filterMap_cons, hf m, ih]

/-- The printer and the parser derive the same table: it does not depend on how the
math entries are held (a map that keeps headers), nor on the math fallbacks of other
fields. -/
theorem symWith_mapMath {α β : Type} (root : List (String × Json)) (rt) (f : Comp α → α → β)
    (c : Comp α) (ct) : symWith root rt (c.mapMath f) ct = symWith root rt c ct := rfl

theorem compTs_mapMath {α ρ β σ : Type} (f : Comp (Mx α ρ) → Mx α ρ → Mx β σ)
    (hf : ∀ c, HeadsKept (f c)) (c : Comp (Mx α ρ)) : compTs (c.mapMath f) = compTs c := by
  simp only [compTs, Comp.mapMath, filterMap_head_map (f c) (hf c)]

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
  /-- The fields of a plot directive. -/
  plot : List (String × Json) → Bool
  /-- A template or rule, under its body's symbol table (`Tm.scope`). -/
  tm : Sym → Tm Json → Bool

/-- A list entry the container spells. -/
def Caps.item (caps : Caps) (S : Sym) : MC → Bool
  | .eq _ e => caps.eqn S e
  | .rxn x => caps.rxn S x
  | .plot a => caps.plot a
  | .tm t => caps.tm (t.scope S) t

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

/-! ## Plots -/

/-- The analysis a plot directive stands for: its fields, with `plot` back as the
one-element `plots`. -/
def plotJson (attrs : List (String × Json)) : Json :=
  .obj (sortKeys (attrs.map (fun kv => if kv.1 = "plot" then ("plots", .arr [kv.2]) else kv)))

/-- The plot directive an analysis is, when it has exactly one plot and no `plot` field,
checked by printing it back. -/
def plotOf (v : Json) : Option (List (String × Json)) :=
  match v with
  | .obj kvs =>
    match look "plots" kvs, look "plot" kvs with
    | some (.arr [p]), none =>
      let a := kvs.map (fun kv => if kv.1 = "plots" then ("plot", p) else kv)
      if plotJson a = v then some a else none
    | _, _ => none
  | _ => none

theorem plotOf_some {v : Json} {a : List (String × Json)} (h : plotOf v = some a) : plotJson a = v := by
  unfold plotOf at h
  split at h
  · split at h
    · simp only at h
      split at h
      · cases h; assumption
      · cases h
    · cases h
  · cases h

/-! ## Templates and rules -/

/-- The keys of a template or rule with a surface of their own. -/
def tmKeys (t : Tm Json) : List String :=
  match t.lhs with
  | none => ["body", "params"]
  | some _ => ["body", "match"]

def tmJson (t : Tm Json) : Json :=
  match t.lhs with
  | none => .obj (sortKeys ([("body", t.body), ("params", .arr (t.params.map .str))] ++ t.attrs))
  | some m => .obj (sortKeys ([("body", t.body), ("match", m)] ++ t.attrs))

/-- The string entries of a list, when every entry is a string. -/
def strList : List Json → Option (List String)
  | [] => some []
  | .str x :: r => (strList r).map (x :: ·)
  | _ :: _ => none

/-- The template (no `match`, `params` a list of strings) or the rule (a `match`) an entry
of `expression_templates` is, checked by printing it back; the body and the match are
expressions. -/
def tmOf (n : String) (v : Json) : Option (Tm Json) :=
  match v with
  | .obj kvs =>
    match look "body" kvs, look "match" kvs, look "params" kvs with
    | some b, none, some (.arr ps) =>
      match strList ps with
      | some ps' =>
        let t : Tm Json := ⟨n, ps', none, b, kvs.filter (fun kv => kv.1 != "body" && kv.1 != "params")⟩
        if tmJson t = v ∧ isE b = true then some t else none
      | none => none
    | some b, some m, _ =>
      let t : Tm Json := ⟨n, [], some m, b, kvs.filter (fun kv => kv.1 != "body" && kv.1 != "match")⟩
      if tmJson t = v ∧ isE b = true ∧ isE m = true then some t else none
    | _, _, _ => none
  | _ => none

/-- Well-formed expressions in a template or rule. -/
def tmWF (t : Tm Json) : Bool := isE t.body && t.lhs.all isE

theorem strList_some : ∀ {ps : List Json} {xs : List String}, strList ps = some xs → ps = xs.map .str
  | [], xs, h => by simp [strList] at h; subst h; rfl
  | .str x :: r, xs, h => by
    simp only [strList, Option.map_eq_some_iff] at h
    obtain ⟨ys, hy, rfl⟩ := h
    simp [strList_some hy]
  | .null :: _, _, h | .bool _ :: _, _, h | .num _ :: _, _, h | .arr _ :: _, _, h | .obj _ :: _, _, h => by
    simp [strList] at h

theorem strsOf_strs (xs : List String) : strsOf (some (.arr (xs.map .str))) = xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [strsOf]

theorem look_filter_keep (k : String) (p : String × Json → Bool) (hp : ∀ v, p (k, v) = true) :
    ∀ kvs : List (String × Json), look k (kvs.filter p) = look k kvs
  | [] => rfl
  | (k', v') :: r => by
    have ih := look_filter_keep k p hp r
    by_cases hk : k' = k
    · subst hk; simp [hp v', look]
    · by_cases hq : p (k', v') = true
      · simp [hq, look, hk, ih]
      · simp [hq, look, hk, ih]

/-- A template or rule decoded from an entry stands for the entry, and its header is the
entry's symbol-table entry (`templatesOf`). -/
theorem tmOf_some {n : String} {v : Json} {t : Tm Json} (h : tmOf n v = some t) :
    tmJson t = v ∧ t.name = n ∧ tmWF t = true ∧
      ∃ kvs, v = .obj kvs ∧ t.ps = strsOf (look "params" kvs) := by
  unfold tmOf at h
  split at h
  · rename_i kvs
    split at h
    · rename_i b ps hb hm hp
      split at h
      · rename_i ps' hps
        simp only at h
        split at h
        · cases h; rename_i hc
          refine ⟨hc.1, rfl, by simp [tmWF, hc.2], kvs, rfl, ?_⟩
          simp only [Tm.ps, hp, strList_some hps, strsOf_strs]
        · cases h
      · cases h
    · simp only at h
      split at h
      · cases h; rename_i hc
        refine ⟨hc.1, rfl, by simp [tmWF, hc.2.1, hc.2.2], kvs, rfl, ?_⟩
        simp only [Tm.ps]
        rw [look_filter_keep "params" _ (by intro v; simp) kvs]
      · cases h
    · cases h
  · cases h

/-! ## List entries -/

/-- The JSON value of a list entry. -/
def itemJson : MC → Json
  | .eq _ e => eqnJson e
  | .rxn x => rxnJson x
  | .plot a => plotJson a
  | .tm t => tmJson t

/-- The value of a field from its entries: an object keyed by the entries' names for
`expression_templates`, a list otherwise. -/
def fieldJson (f : String) (ms : List MC) : Json :=
  if f = "expression_templates" then .obj (ms.map (fun m => (m.key, itemJson m)))
  else .arr (ms.map itemJson)

/-- The role of an equation field. -/
def roleOf (f : String) : Option Role := [Role.eqn, .init, .cons].find? (fun r => r.field == f)

/-- The math entry an entry of the math field `f` is. -/
def itemOf (f : String) (v : Json) : Option MC :=
  if f = "reactions" then (rxnOf v).map .rxn
  else if f = "analyses" then (plotOf v).map .plot
  else (roleOf f).bind (fun r => (eqnOf v).map (.eq r))

/-- Well-formed expressions throughout. -/
def mathWF : MC → Bool
  | .eq _ e => isE e.lhs && isE e.rhs
  | .rxn x => isE x.rate
  | .plot _ => true
  | .tm t => tmWF t

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

theorem roleOf_tm : roleOf "expression_templates" = none := by decide

theorem itemOf_some {f : String} {v : Json} {m : MC} (h : itemOf f v = some m) :
    itemJson m = v ∧ m.field = f ∧ mathWF m = true := by
  unfold itemOf at h
  split at h
  · rename_i hf
    simp only [Option.map_eq_some_iff] at h
    obtain ⟨x, hx, rfl⟩ := h
    obtain ⟨h1, h2⟩ := rxnOf_some hx
    exact ⟨h1, hf.symm, h2⟩
  split at h
  · rename_i hf
    simp only [Option.map_eq_some_iff] at h
    obtain ⟨a, ha, rfl⟩ := h
    exact ⟨plotOf_some ha, hf.symm, rfl⟩
  · simp only [Option.bind_eq_some_iff, Option.map_eq_some_iff] at h
    obtain ⟨r, hr, e, he, rfl⟩ := h
    have := eqnOf_isE he
    exact ⟨eqnJson_eqnOf he, roleOf_some hr, by simp [mathWF, this.1, this.2]⟩

/-- The template entry an entry `(name, value)` of `expression_templates` is. -/
def tmItem (kv : String × Json) : Option MC := (tmOf kv.1 kv.2).map .tm

/-- The entries of a math field, when all of them print natively. -/
def mathOf (caps : Caps) (S : Sym) (f : String) : Json → Option (List MC)
  | .arr (x :: xs) =>
    if f = "expression_templates" then none else
    match (x :: xs).mapM (itemOf f) with
    | some ms => if ms.all (caps.item S) then some ms else none
    | none => none
  | .obj (kv :: kvs) =>
    if f = "expression_templates" then
      match (kv :: kvs).mapM tmItem with
      | some ms => if ms.all (caps.item S) then some ms else none
      | none => none
    else none
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

theorem mapM_tmItem : ∀ {kvs : List (String × Json)} {ms : List MC}, kvs.mapM tmItem = some ms →
    kvs = ms.map (fun m => (m.key, itemJson m)) ∧
      ∀ m ∈ ms, m.field = "expression_templates" ∧ mathWF m = true ∧
        ∃ t, m = .tm t ∧ ∃ tkvs, tmJson t = Json.obj tkvs ∧ t.ps = strsOf (look "params" tkvs)
  | [], ms, h => by simp at h; subst h; simp
  | (k, v) :: ys, ms, h => by
    simp only [List.mapM_cons, Option.bind_eq_bind] at h
    cases hy : tmItem (k, v) with
    | none => simp [hy] at h
    | some my =>
      cases hys : ys.mapM tmItem with
      | none => simp [hy, hys] at h
      | some mys =>
        simp [hy, hys] at h
        subst h
        simp only [tmItem, Option.map_eq_some_iff] at hy
        obtain ⟨t, ht, rfl⟩ := hy
        obtain ⟨h1, h2, h3, tkvs, rfl, h5⟩ := tmOf_some ht
        obtain ⟨h4, h6⟩ := mapM_tmItem hys
        refine ⟨by simp [Mx.key, itemJson, h1, h2, h4], ?_⟩
        intro m hm
        rcases List.mem_cons.mp hm with rfl | hm
        · exact ⟨rfl, h3, t, rfl, tkvs, h1, h5⟩
        · exact h6 m hm

theorem mathOf_some {caps : Caps} {S : Sym} {f : String} {j : Json} {ms : List MC}
    (h : mathOf caps S f j = some ms) :
    j = fieldJson f ms ∧ ms ≠ [] ∧
      ∀ m ∈ ms, m.field = f ∧ mathWF m = true ∧ caps.item S m = true := by
  unfold mathOf at h
  split at h
  · rename_i x xs
    split at h
    · cases h
    rename_i hf
    split at h
    · rename_i ms' hm
      split at h
      · cases h
        rename_i hall
        obtain ⟨h1, h2⟩ := mapM_itemOf hm
        refine ⟨by rw [h1]; simp [fieldJson, hf], ?_, fun m hm' => ⟨(h2 m hm').1, (h2 m hm').2, List.all_eq_true.mp hall m hm'⟩⟩
        intro he
        rw [he] at h1
        cases h1
      · cases h
    · cases h
  · rename_i kv kvs
    split at h
    · rename_i hf
      split at h
      · rename_i ms' hm
        split at h
        · cases h
          rename_i hall
          obtain ⟨h1, h2⟩ := mapM_tmItem hm
          refine ⟨by rw [h1]; simp [fieldJson, hf], ?_, fun m hm' => ⟨hf ▸ (h2 m hm').1, (h2 m hm').2.1,
            List.all_eq_true.mp hall m hm'⟩⟩
          intro he
          rw [he] at h1
          cases h1
        · cases h
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

/-- A subsystem included by reference (it has a `ref`) as a declaration. -/
def pickSub (caps : Caps) (n : String) (v : Json) : Option Decl :=
  match v with
  | .obj kvs => if (look "ref" kvs).isSome then pickPlain caps .sub n v else none
  | _ => none

/-- The declaration fields of a component kind, with their pickers. -/
def declFields (caps : Caps) : Kind → List (String × (String → Json → Option Decl))
  | .model => [("variables", pickVar caps), ("subsystems", pickSub caps)]
  | .rs => [("species", pickPlain caps .species), ("parameters", pickPlain caps .param),
      ("subsystems", pickSub caps)]

/-- The field a declaration of kind `k` belongs to, in a component of kind `K`. -/
def declField : Kind → DKind → Option String
  | .model, .var => some "variables"
  | .model, .param => some "variables"
  | .model, .species => none
  | .rs, .species => some "species"
  | .rs, .param => some "parameters"
  | .rs, .var => none
  | _, .sub => some "subsystems"

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
  | _, .sub => some (d.name, .obj (sortKeys d.attrs))
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

/-- The symbol table of a component's entries, from the document's templates `rt`: the
component's own templates are read from its `expression_templates` value, which is what
the finished section's table reads from its template entries or its block (`compTs_compOf`). -/
def compSym (root : List (String × Json)) (rt : List (String × List String)) (K : Kind)
    (caps : Caps) (name : String) (kvs : List (String × Json)) : Sym :=
  symWith root rt (compBase caps K name kvs) (templatesOf (look "expression_templates" kvs))

/-- A component: `compBase`, then its math fields, each native when every entry prints
natively under the component's symbol table, else a block. -/
def compOf (caps : Caps) (root : List (String × Json)) (rt : List (String × List String))
    (K : Kind) (name : String) (kvs : List (String × Json)) : Comp MC :=
  let c := compBase caps K name kvs
  let ps := mathFields.map (mathPart caps (compSym root rt K caps name kvs) kvs)
  { c with math := ps.flatMap Prod.fst, mathBlocks := ps.filterMap Prod.snd }

/-- A component entry prints as a directive when its name does and it is an object. -/
def pickComp (caps : Caps) (n : String) (v : Json) : Option (String × List (String × Json)) :=
  match v with
  | .obj kvs => if caps.compName n then some (n, kvs) else none
  | _ => none

/-- The symbol table of the top-level templates: the document's index sets and its
templates, read from the `expression_templates` value. -/
def topSymOf (kvs : List (String × Json)) : Sym :=
  { names := keysOf (look "index_sets" kvs), templates := templatesOf (look "expression_templates" kvs) }

/-- The top-level templates, when every one prints natively. -/
def topMath (caps : Caps) (kvs : List (String × Json)) : Option (List MC) :=
  (look "expression_templates" kvs).bind (mathOf caps (topSymOf kvs) "expression_templates")

/-- Where a top-level entry goes when it is not a native surface: every entry without
a surface of its own, the residues of `models` and `reaction_systems`, `metadata`
when it is not in the front matter, and `expression_templates` when it is not native
(`tn`). -/
def rootBlock (caps : Caps) (tn : Bool) (kv : String × Json) : Option (String × Json) :=
  if kv.1 = "esm" then none
  else if kv.1 = "metadata" then (if (metaOf caps (some kv.2)).isSome then none else some kv)
  else if kv.1 = "models" ∨ kv.1 = "reaction_systems" then
    (splitOpt (pickComp caps) (some kv.2)).2.map (fun r => (kv.1, r))
  else if kv.1 = "expression_templates" ∧ tn = true then none
  else some kv

/-- The top-level blocks. -/
def rootBlocks (caps : Caps) (tn : Bool) (kvs : List (String × Json)) : List (String × Json) :=
  kvs.filterMap (rootBlock caps tn)

/-- **The skeleton of a document.** -/
def toDoc (caps : Caps) : Json → Doc MC
  | .obj kvs =>
    let m := metaOf caps (look "metadata" kvs)
    let tm := topMath caps kvs
    let blocks := rootBlocks caps tm.isSome kvs
    let rt := templatesOf (look "expression_templates" kvs)
    let comps (K : Kind) (f : String) :=
      (splitOpt (pickComp caps) (look f kvs)).1.map (fun p => compOf caps blocks rt K p.1 p.2)
    { front := at_ "esm" kvs ++ (m.map Prod.fst).getD [],
      desc := m.bind Prod.snd,
      blocks := blocks,
      math := tm.getD [],
      comps := comps .model "models" ++ comps .rs "reaction_systems" }
  | _ => { front := [], desc := none, blocks := [], math := [], comps := [] }

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
  | m :: ms, [] => some [(f, fieldJson f (m :: ms))]
  | _, _ => none

/-- The rebuilt math fields. -/
def mathKvs (c : Comp MC) : Option (List (String × Json)) :=
  (mathFields.mapM (mathKv c)).map List.flatten

/-- The names of the declaration fields of a component kind. -/
def declFieldNames : Kind → List String
  | .model => ["variables", "subsystems"]
  | .rs => ["species", "parameters", "subsystems"]

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
  let tkv := if D.math.isEmpty then [] else [("expression_templates", fieldJson "expression_templates" D.math)]
  let others := D.blocks.filter (fun kv => kv.1 != "models" && kv.1 != "reaction_systems")
  let d := Json.obj (sortKeys (esmKv ++ metaKv ++ optKv "models" models ++
    optKv "reaction_systems" rss ++ tkv ++ others))
  if canonDoc d then pure d else none

end Esm.Document.Source
