import Esm.Document.Source.Keys

/-!
# The `initialization_equations` migration of the canonical form (esm-spec §11.4.4)

`initialization_equations` is deprecated (esm 2.5.0). The canonical form, and so the
Markdown and Typst printers that print it, rewrite the field as a loader does
(esm-spec §11.4.4 and the `deprecated_field` row of §9.6.6), so a printed document never
carries it. For each model, top level or an inline subsystem at any depth (deepest first):

* first, an initial condition of a parameter (esm-spec §11.4.4 "An initial condition of a
  parameter") becomes the parameter's `default`: in a document declaring esm below 2.5.0,
  each `equations` entry whose left-hand side is exactly `ic(k)`, then each
  `initialization_equations` entry whose left-hand side is `k` or `ic(k)`, `k` declared in
  the model's own `variables` with `type` `"parameter"`, is removed and its right-hand side
  (a JSON number, else `ic_invalid_argument`) written as `k`'s `default`, in that order, a
  later one replacing an earlier value;

then, when the model holds `initialization_equations`, the field is removed and its
remaining equations go:

* a model with a time derivative (an equation of `equations` whose left-hand side holds an
  op `D` anywhere): each initialization equation, in the field's order, is appended to
  `equations` with its `lhs` and `rhs` rewritten by `wrap`: every reference to an unknown
  `w` becomes `ic(w)` and every time derivative `D(w)` of an unknown becomes `ic(D(w))`;
* a model with none: each `v ~ e` whose left-hand side is a bare name declared in the
  model's `variables` with `type` `"unknown"` becomes `guesses[v] = e` (in the field's order,
  an entry `guesses` already has, or an earlier equation gave, is kept); any other equation
  is refused (`deprecated_field`, an error).

A document with a refused equation (either refusal above, or an initial condition of a
parameter whose value is not a number) is left as it is (`migrateOrKeep`): the canonical form
of a document the loader rejects is the document unmigrated, and the printers then write
its initialization container, as every binding does.

Unproved executable code (the printers' round-trip theorems are about the canonical form
this produces), pinned by the document-format golden files and the cross-binding gate.
-/

namespace Esm.Document.Source.InitMigration

open Esm.Document

private instance : Inhabited Json := ⟨.null⟩

/-- Field `k` of an object. -/
def field (k : String) : Json → Option Json
  | .obj kvs => Math.look k kvs
  | _ => none

/-- Whether model `m` declares `v` in its `variables` with `type` `"unknown"`. -/
def isUnknownVar (m : Json) (v : String) : Bool :=
  match field "variables" m >>= field v >>= field "type" with
  | some (.str "unknown") => true
  | _ => false

/-- The inline subsystem of `m` at a path of subsystem names. -/
def descend (m : Json) : List String → Option Json
  | [] => some m
  | s :: r => (field "subsystems" m >>= field s) >>= fun n => descend n r

/-- Whether `name` names an unknown seen from `model`: a bare name declared in the model's
`variables` with `type` `"unknown"`; a scoped name `a.b.….v` (split at every `.`, the last
segment the variable) resolving to such a declaration first through the model's own
subsystems (`a`, then `b`, …), then from the top-level model `a` through its subsystems;
or, failing both, naming a species `v` of the top-level reaction system `a` (through its
subsystems). `root` is the document before migration. -/
def namesUnknown (root model : Json) (name : String) : Bool :=
  let parts := name.splitOn "."
  match parts.dropLast, parts.getLast? with
  | [], _ => isUnknownVar model name
  | path@(p0 :: rest), some leaf =>
    (match descend model path with
      | some m => isUnknownVar m leaf
      | none => false) ||
    (match (field "models" root >>= field p0) >>= fun t => descend t rest with
      | some m => isUnknownVar m leaf
      | none => false) ||
    (match field "reaction_systems" root >>= field p0 with
      | some rs =>
        match descend rs rest with
        | some cur => (field "species" cur >>= field leaf).isSome
        | none => false
      | none => false)
  | _, _ => false

/-- Whether an expression holds an op `D` node anywhere. -/
partial def containsD : Json → Bool
  | .obj kvs =>
    (match Math.look "op" kvs with
      | some (.str "D") => true
      | _ => false) || kvs.any (fun kv => containsD kv.2)
  | .arr xs => xs.any containsD
  | _ => false

/-- `ic(a)`, keys sorted. -/
def icOf (a : Json) : Json := .obj [("args", .arr [a]), ("op", .str "ic")]

/-- The expression-valued fields of a node the rewrite descends into (besides `bindings`,
a name-keyed map of expressions). -/
def exprKeys : List String := ["args", "expr", "filter", "values", "lower", "upper", "key"]

mutual
/-- `e` with every unknown reference `w` written `ic(w)` and every time derivative `D(w)`
(`wrt` absent, null or `"t"`, first argument an unknown name) written `ic(D(w))`. An `ic`
node is kept as it is. Other nodes are rebuilt with `wrapIn` applied to the values of
`exprKeys` and to every value of `bindings`; their other fields are kept. -/
partial def wrap (isU : String → Bool) : Json → Json
  | .str s => if isU s then icOf (.str s) else .str s
  | .obj kvs =>
    match Math.look "op" kvs with
    | some (.str "ic") => .obj kvs
    | op =>
      let timeD := match op, Math.look "wrt" kvs with
        | some (.str "D"), none => true
        | some (.str "D"), some .null => true
        | some (.str "D"), some (.str "t") => true
        | _, _ => false
      let argU := match Math.look "args" kvs with
        | some (.arr (.str a :: _)) => isU a
        | _ => false
      if timeD && argU then icOf (.obj kvs)
      else .obj (kvs.map fun (k, v) =>
        if exprKeys.contains k then (k, wrapIn isU v)
        else if k == "bindings" then
          (k, match v with
            | .obj bs => .obj (bs.map fun (b, e) => (b, wrapIn isU e))
            | _ => v)
        else (k, v))
  | j => j

/-- `wrap` through arrays, at any depth. -/
partial def wrapIn (isU : String → Bool) : Json → Json
  | .arr xs => .arr (xs.map (wrapIn isU))
  | j => wrap isU j
end

/-- Whether model `m` declares `v` in its `variables` with `type` `"parameter"`. -/
def isParamVar (m : Json) (v : String) : Bool :=
  match field "variables" m >>= field v >>= field "type" with
  | some (.str "parameter") => true
  | _ => false

/-- The parameter of `model` an equation sets: its left-hand side is `ic(k)` (exactly: op
`ic`, `args` the one name `k`), or, when `bare`, the name `k`; `k` a parameter the model
declares. -/
def paramTarget (model : Json) (bare : Bool) (eq : Json) : Option String :=
  match field "lhs" eq with
  | some (.str k) => if bare && isParamVar model k then some k else none
  | some (.obj kvs) =>
    match Math.look "op" kvs, Math.look "args" kvs with
    | some (.str "ic"), some (.arr [.str k]) => if isParamVar model k then some k else none
    | _, _ => none
  | _ => none

/-- Whether the document declares an esm version below 2.5.0 (its `esm` string's first two
dot-separated parts read as natural numbers; any other `esm` is not below). -/
def below250 (doc : Json) : Bool :=
  match field "esm" doc with
  | some (.str v) =>
    match (v.splitOn ".").map String.toNat? with
    | some a :: some b :: _ => a < 2 || (a == 2 && b < 5)
    | _ => false
  | _ => false

/-- Whether a model, or an inline subsystem of it at any depth, has something to migrate:
the field, or (`legacy`: the document is below esm 2.5.0) an `ic(k)` equation of a
parameter. -/
partial def modelHas (legacy : Bool) : Json → Bool
  | .obj kvs =>
    (Math.look "initialization_equations" kvs).isSome ||
      (legacy && match Math.look "equations" kvs with
        | some (.arr es) => es.any fun e => (paramTarget (.obj kvs) false e).isSome
        | _ => false) ||
      (match Math.look "subsystems" kvs with
        | some (.obj s) => s.any (fun kv => modelHas legacy kv.2)
        | _ => false)
  | _ => false

/-- The equations of `es` that set a parameter (`paramTarget`), taken out: the others, and
the `(k, value)` each sets, in order. A value that is not a number is refused. `fld`, `i`:
the list's field and the first equation's index, for the refusal. -/
def takeParamICs (model : Json) (ptr fld : String) (bare : Bool) :
    Nat → List Json → Except String (List Json × List (String × Json))
  | _, [] => pure ([], [])
  | i, eq :: r => do
    let (kept, sets) ← takeParamICs model ptr fld bare (i + 1) r
    match paramTarget model bare eq with
    | some k =>
      match field "rhs" eq with
      | some (.num n) => pure (kept, (k, .num n) :: sets)
      | _ => throw s!"ic_invalid_argument: {ptr}/{fld}/{i}: an initial condition of the parameter `{k}` moves into its default (esm-spec §11.4.4), so its right-hand side must be a number"
    | none => pure (eq :: kept, sets)

/-- `kvs` (a model) with each parameter's `default` set to its value, in order. -/
def setDefaults (kvs : List (String × Json)) (sets : List (String × Json)) :
    List (String × Json) :=
  sets.foldl (fun kvs (k, v) => kvs.map fun (f, x) =>
    if f != "variables" then (f, x)
    else match x with
      | .obj vs => (f, .obj (vs.map fun (n, d) =>
          if n != k then (n, d)
          else match d with
            | .obj dkvs => (n, .obj (sortKeys (("default", v) :: dkvs.filter (·.1 != "default"))))
            | d => (n, d)))
      | x => (f, x)) kvs

/-- The refusal of an initialization equation of a model with no time derivative. -/
def refusal (ptr : String) (i : Nat) : String :=
  s!"deprecated_field: {ptr}/initialization_equations/{i}: the model has no time derivative, " ++
  "so its initialization equations move into `guesses` (esm-spec §11.4.4); this one's " ++
  "left-hand side is not a bare unknown"

/-- The `guesses` a model with no time derivative gets: `g` with `v ↦ e` added for each
`v ~ e`, in order, unless `v` is already there. -/
def toGuesses (model : Json) (ptr : String) :
    Nat → List (String × Json) → List Json → Except String (List (String × Json))
  | _, g, [] => pure g
  | i, g, eq :: r => do
    let v ← match field "lhs" eq with
      | some (.str v) => if isUnknownVar model v then pure v else throw (refusal ptr i)
      | _ => throw (refusal ptr i)
    let g := if (Math.look v g).isSome then g else g ++ [(v, (field "rhs" eq).getD .null)]
    toGuesses model ptr (i + 1) g r

/-- One model migrated (its subsystems first). `root`: the document before migration;
`ptr`: the model's JSON pointer, for the refusal. -/
partial def migrateModel (root : Json) (legacy : Bool) (ptr : String) :
    Json → Except String Json
  | .obj kvs => do
    let kvs ← kvs.mapM fun (k, v) => do
      match k, v with
      | "subsystems", .obj subs =>
        return (k, .obj (← subs.mapM fun (n, s) => do
          return (n, ← migrateModel root legacy s!"{ptr}/subsystems/{n}" s)))
      | _, _ => return (k, v)
    let model0 := Json.obj kvs
    -- An initial condition of a parameter becomes its default: first `ic(k)` in
    -- `equations` (below esm 2.5.0 only), then the old field's `k` or `ic(k)`.
    let (kvs, setsE) ← match legacy, Math.look "equations" kvs with
      | true, some (.arr es) => do
        let (kept, sets) ← takeParamICs model0 ptr "equations" false 0 es
        pure (kvs.map (fun (k, v) => if k == "equations" then (k, .arr kept) else (k, v)), sets)
      | _, _ => pure (kvs, [])
    match Math.look "initialization_equations" kvs with
    | none => return .obj (setDefaults kvs setsE)
    | some block =>
      let kvs := kvs.filter (·.1 != "initialization_equations")
      let eqs ← match block with
        | .arr xs => pure xs
        | .null => pure []
        | _ => throw s!"deprecated_field: {ptr}/initialization_equations: not a list of equations"
      let (eqs, setsI) ← takeParamICs model0 ptr "initialization_equations" true 0 eqs
      let kvs := setDefaults kvs (setsE ++ setsI)
      if eqs.isEmpty then return .obj kvs
      let model := Json.obj kvs
      let hasD := match Math.look "equations" kvs with
        | some (.arr es) => es.any fun e => (field "lhs" e).any containsD
        | _ => false
      if hasD then
        let isU := namesUnknown root model
        let migrated := eqs.map fun eq => match eq with
          | .obj ekvs => .obj (ekvs.map fun (k, v) =>
              if k == "lhs" || k == "rhs" then (k, wrap isU v) else (k, v))
          | j => j
        return .obj (kvs.map fun (k, v) =>
          match k, v with
          | "equations", .arr es => (k, .arr (es ++ migrated))
          | _, _ => (k, v))
      else
        let g0 := match Math.look "guesses" kvs with
          | some (.obj g) => g
          | _ => []
        let g ← toGuesses model ptr 0 g0 eqs
        return .obj (sortKeys (("guesses", .obj (sortKeys g)) ::
          kvs.filter (·.1 != "guesses")))
  | j => return j

/-- Every model migrated, or the refusal of the first equation that has no reading. A document without the field is returned as it is. -/
def migrate (doc : Json) : Except String Json :=
  match doc with
  | .obj kvs =>
    match Math.look "models" kvs with
    | some (.obj ms) =>
      let legacy := below250 doc
      if !(ms.any fun kv => modelHas legacy kv.2) then pure doc
      else do
        let ms' ← ms.mapM fun (n, m) => do
          return (n, ← migrateModel doc legacy s!"/models/{n}" m)
        return .obj (kvs.map fun (k, v) => if k == "models" then (k, .obj ms') else (k, v))
    | _ => pure doc
  | _ => pure doc

/-- The canonical form's migration: `migrate`, or the document unmigrated when the loader
would refuse it. -/
def migrateOrKeep (doc : Json) : Json :=
  match migrate doc with
  | .ok d => d
  | .error _ => doc

end Esm.Document.Source.InitMigration
