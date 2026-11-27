import Esm.Document.Json

/-! Load-time integer scopes and structural folding (esm-spec §9.7.6). -/

namespace Esm.Rewrite.Metaparameters

open Esm.Document

abbrev Bindings := List (String × Json)

structure Error where
  code : String
  detail : String
  deriving Inhabited, Repr, DecidableEq

private def typeError (detail : String) : Error := ⟨"metaparameter_type_error", detail⟩

private def fields : Json → Bindings
  | .obj entries => entries
  | _ => []

private def field (json : Json) (name : String) : Option Json := (fields json).lookup name

private def strings : Json → List String
  | .arr items => items.filterMap fun | .str s => some s | _ => none
  | _ => []

private def int (value : Int) : Json := .num (.int value)

/-- Check each result in a left fold before applying the next operation. -/
def checked (value : Int) : Except Error Int :=
  if JNum.InInt64 value then .ok value else
    .error (typeError "signed 64-bit integer overflow")

theorem checked_iff (value result : Int) : checked value = .ok result ↔
    JNum.InInt64 value ∧ result = value := by
  unfold checked
  split
  · rename_i inRange
    simp [inRange, eq_comm]
  · rename_i outOfRange
    simp [outOfRange]

/-- Divisibility makes Euclidean and truncated quotients coincide. -/
def divide (a b : Int) : Except Error Int :=
  if b = 0 then .error (typeError "division by zero") else
  if a % b = 0 then checked (a / b) else
    .error (typeError s!"{a} / {b} does not divide exactly")

theorem divide_iff (a b q : Int) : divide a b = .ok q ↔
    b ≠ 0 ∧ q * b = a ∧ JNum.InInt64 q := by
  constructor
  · intro h
    unfold divide at h
    split at h
    · contradiction
    · rename_i hb
      split at h
      · rename_i hrem
        obtain ⟨inRange, rfl⟩ := (checked_iff _ _).mp h
        exact ⟨hb, Int.ediv_mul_cancel_of_emod_eq_zero hrem, inRange⟩
      · contradiction
  · rintro ⟨nonzero, rfl, inRange⟩
    unfold divide
    rw [ite_eq_right nonzero, Int.mul_comm q b, Int.mul_emod_right, ite_eq_left rfl,
      Int.mul_ediv_cancel_left _ nonzero]
    exact (checked_iff _ _).mpr ⟨inRange, rfl⟩

private inductive Op where
  | add | sub | mul | div
  deriving DecidableEq

private def parseOp : Option Json → Except Error Op
  | some (.str "+") => .ok .add
  | some (.str "-") => .ok .sub
  | some (.str "*") => .ok .mul
  | some (.str "/") => .ok .div
  | _ => .error (typeError "expected one of +, -, *, /")

private def applyOp : Op → Int → Int → Except Error Int
  | .add, a, b => checked (a + b)
  | .sub, a, b => checked (a - b)
  | .mul, a, b => checked (a * b)
  | .div, a, b => divide a b

-- The tag marks a value originating in the importer's scope. It also lets the
-- final close validate deferred arithmetic without folding ordinary expressions.
-- Wire JSON cannot produce the internal `.math` marker.
private def deferred (value : Json) : Json := .arr [.math "metaparameter", value]

def deferredPayload : Json → Option Json
  | .arr [.math "metaparameter", value] => some value
  | _ => none

private partial def eval : Json → Except Error (Option Int)
  | .str name =>
    if name.isEmpty then .error (typeError "expected a nonempty metaparameter name") else .ok none
  | .num (.int n) => some <$> checked n
  | .arr [.math "metaparameter", value] => eval value
  | .obj entries => do
    unless entries.length == 2 do throw (typeError "expected only op and args in arithmetic")
    let op ← parseOp (entries.lookup "op")
    let some (.arr (first :: rest)) := entries.lookup "args"
      | throw (typeError "expected a nonempty args array")
    let operands ← (first :: rest).mapM eval
    match operands.mapM id with
    | some [a] => some <$> if op == .sub then checked (-a) else pure a
    | some (a :: tail) => some <$> tail.foldlM (applyOp op) a
    | _ => return none
  | _ => .error (typeError "expected an integer, a name, or metaparameter arithmetic")

private partial def freeNames : Json → List String
  | .str name => [name]
  | .arr children => children.flatMap freeNames
  | .obj entries =>
    match entries.lookup "args" with
    | some (.arr args) => args.flatMap freeNames
    | _ => []
  | _ => []

/-- `skip_keys` from the §9.7.6 field classification. -/
def structuralFields : List String := [
  "_comment", "attrs", "citation", "default_units", "defines", "description", "dim",
  "direction", "doi", "element_type", "expect_cadence", "file_variable", "fn", "format",
  "from_faq", "handler_id", "hook", "id", "index_set_rename", "kind", "label", "location",
  "members", "metadata", "metaparameters", "model", "name", "notes", "of", "on", "only",
  "op", "operator_imports", "output_idx", "params", "path", "prefix", "reaction_system",
  "rebind", "reduce", "ref", "rename", "root_find", "scale", "semiring", "side", "source",
  "syms", "system_kind", "type", "units", "unmapped", "url", "url_substitutions",
  "var", "where", "wrt"
]

/-- `name_keyed_map_keys` from the §9.7.6 field classification. -/
def nameKeyedFields : List String := [
  "bindings", "config", "coords", "expression_templates", "guesses", "index_set_rename",
  "initial_conditions", "map", "operators", "parameter_overrides", "parameters",
  "pinned_coords", "ranges", "rebind", "rename", "species", "subsystems",
  "url_substitutions", "variables", "where"
]

private def registryField (key : String) : Bool :=
  key == "operators" || key == "expression_templates"

private def nameKeyed (key : String) : Bool :=
  nameKeyedFields.contains key || ["index_sets", "models", "reaction_systems"].contains key

private def mapValues (transform : Json → Json) : Json → Json
  | .obj entries => .obj (entries.map fun (name, item) => (name, transform item))
  | value => value

private partial def subst (values : Bindings) (hidden : List String) : Json → Json
  | node@(.str name) => if hidden.contains name then node else (values.lookup name).getD node
  | .arr [.math "metaparameter", value] => deferred (subst values [] value)
  | .arr children => .arr (children.map (subst values hidden))
  | .obj entries => .obj <| entries.map fun (key, value) =>
    let value := if structuralFields.contains key then value else
      if registryField key then mapValues (fun decl =>
        let params := strings ((field decl "params").getD .null)
        subst values (params ++ hidden) decl) value else
      if nameKeyed key then mapValues (subst values hidden) value else
        subst values hidden value
    (key, value)
  | value => value

/-- Simultaneous value substitution. Structural keys and local definition parameters
    keep their original meanings. -/
def substitute (document : Json) (values : Bindings) : Json := subst values [] document

private def setField (entries : Bindings) (key : String) (value : Json) : Bindings :=
  if entries.any (fun item => item.1 == key) then
    entries.map fun item => if item.1 == key then (key, value) else item
  else entries ++ [(key, value)]

def declarations (document : Json) : Bindings := fields ((field document "metaparameters").getD .null)

private def integerLiteral : Json → Except Error Int
  | .num (.int value) => checked value
  | _ => .error (typeError "expected an integer literal")

private partial def reservedNames : Json → List String
  | .arr children => children.flatMap reservedNames
  | .obj entries =>
    let op := match entries.lookup "op" with | some (.str _) => true | _ => false
    let loopNames := if op then
      (fields ((entries.lookup "ranges").getD .null)).map Prod.fst ++
        strings ((entries.lookup "output_idx").getD .null) else []
    loopNames ++ entries.flatMap fun (key, value) =>
      if structuralFields.contains key then [] else
      if nameKeyed key then (fields value).flatMap fun (name, item) =>
        let nested := reservedNames item
        if ["variables", "species", "parameters", "index_sets"].contains key then
          name :: nested else nested
      else reservedNames value
  | _ => []

/-- Check names before an edge can remove any of the declarations that collide. -/
def validateNames (document : Json) : Except Error Unit := do
  let declared := declarations document
  if let some registry := field document "metaparameters" then
    let .obj _ := registry | throw (typeError "expected a metaparameters object")
  unless declared.isEmpty do
    let reserved := reservedNames document
    for (name, value) in declared do
      if reserved.contains name then throw ⟨"metaparameter_name_conflict", name⟩
      let some (.str "integer") := field value "type" | throw (typeError s!"{name}: expected integer type")
      if let some defaultValue := field value "default" then
        let _ ← integerLiteral defaultValue

private def foldSite (value : Json) (strict : Bool := false) : Except Error Json := do
  match ← eval value with
  | some result => return int result
  | none =>
    if strict then throw ⟨"metaparameter_unbound", String.intercalate ", " (freeNames value)⟩
    return value

private def mapItems (transform : Json → Except Error Json) : Json → Except Error Json
  | .arr items => .arr <$> items.mapM transform
  | value => .ok value

private def foldBounds (value : Json) : Except Error Json := do
  let folded ← mapItems (fun site => foldSite site) value
  if let .arr [.num (.int lo), .num (.int hi)] := folded then
    if hi < lo - 1 then throw ⟨"makearray_region_inverted", s!"[{lo}, {hi}]"⟩
  return folded

private def foldSize (strict : Bool) : Json → Except Error Json
  | .obj entries => .obj <$> entries.mapM (fun (key, value) => do
    if key == "size" then return (key, ← foldSite value strict)
    return (key, value))
  | value => .ok value

private partial def foldDocument (strict : Bool) : Json → Except Error Json
  | node@(.arr [.math "metaparameter", _]) => do
    let _ ← foldSite node strict
    return node
  | .arr items => .arr <$> items.mapM (foldDocument strict)
  | .obj entries => do
    let op := match entries.lookup "op" with | some (.str name) => name | _ => ""
    .obj <$> entries.mapM fun (key, value) => do
      if structuralFields.contains key then return (key, value)
      if key == "index_sets" then
        if let .obj items := value then
          return (key, .obj (← items.mapM fun (name, decl) => do
            return (name, ← foldSize strict decl)))
      if key == "ranges" && (op == "faq" || op == "aggregate") then
        if let .obj items := value then
          return (key, .obj (← items.mapM fun (name, range) => do
            let range ← match range with
            | .arr _ => mapItems (fun site => foldSite site) range
            | _ => foldDocument strict range
            return (name, range)))
      if key == "regions" && op == "makearray" then
        return (key, ← mapItems (mapItems foldBounds) value)
      if nameKeyed key then
        if let .obj items := value then
          return (key, .obj (← items.mapM fun (name, item) => do
            return (name, ← foldDocument strict item)))
      return (key, ← foldDocument strict value)
  | value => .ok value

/-- Check binding values in the importer's scope. Import edges preserve the
    value's syntax for substitution. A subsystem edge passes `strict` and
    receives only closed integer values. -/
def edgeBindings (edge : Json) (importerNames : List String) (importerValues : Bindings := [])
    (strict : Bool := false) :
    Except Error Bindings := do
  let .obj values := (field edge "bindings").getD (.obj [])
    | throw (typeError "expected a bindings object")
  values.mapM fun (name, value) => do
    if let some unknown := (freeNames value).find? (fun key =>
          !importerNames.contains key && (importerValues.lookup key).isNone) then
      throw ⟨"operator_import_unknown_name", unknown⟩
    let substituted := substitute value importerValues
    let folded ← foldSite substituted strict
    return (name, if strict then folded else substituted)

private def validateKeys (declared values : Bindings) : Except Error Unit :=
  match values.find? (fun pair => (declared.lookup pair.1).isNone) with
  | some (name, _) => .error ⟨"operator_import_unknown_name", name⟩
  | none => .ok ()

/-- Close only the names bound on this edge, and rename still-open names in the
    same substitution so parent-origin free names do not get renamed at this edge. -/
def instantiate (document : Json) (bindings : Bindings)
    (metaRenames : List (String × String) := []) : Except Error Json := do
  validateNames document
  let declared := declarations document
  validateKeys declared bindings
  let values ← bindings.mapM fun (name, value) => do
    let _ ← eval value
    return (name, match value with | .num (.int _) => value | _ => deferred value)
  let renames := metaRenames.map fun (oldName, newName) => (oldName, Json.str newName)
  let remaining := declared.filterMap fun (name, decl) =>
    if (bindings.lookup name).isSome then none else some ((metaRenames.lookup name).getD name, decl)
  let substituted := substitute document (values ++ renames)
  let substituted := if (field document "metaparameters").isSome then
    .obj (setField (fields substituted) "metaparameters" (.obj remaining)) else substituted
  foldDocument false substituted

/-- At the final JSON boundary, keep the imported expression but erase its
    internal scope tag. -/
partial def clearDeferred : Json → Json
  | .arr [.math "metaparameter", value] => clearDeferred value
  | .arr children => .arr (children.map clearDeferred)
  | .obj entries => .obj (entries.map fun (name, value) => (name, clearDeferred value))
  | value => value

/-- Close a root scope from explicit values and defaults. A mount can keep unknown
    index-set sizes open for the enclosing document by passing `strict := false`. -/
def close (document : Json) (overrides : Bindings := []) (strict : Bool := true) :
    Except Error (Json × Bindings) := do
  validateNames document
  let declared := declarations document
  validateKeys declared overrides
  let values ← declared.mapM fun (name, decl) => do
    let some value := (overrides.lookup name).orElse (fun _ => field decl "default")
      | throw ⟨"metaparameter_unbound", name⟩
    return (name, int (← integerLiteral value))
  let folded ← foldDocument strict (substitute document values)
  return (if strict then clearDeferred folded else folded, values)

end Esm.Rewrite.Metaparameters
