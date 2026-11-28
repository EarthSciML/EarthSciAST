import Esm.Rewrite.Match
import Esm.Rewrite.Metaparameters
import Esm.Document.Notation

/-! Ordered registry composition and import-edge renaming from esm-spec §9.7.
Filesystem traversal and metaparameter instantiation are supplied at the edge. -/

namespace Esm.Rewrite.Imports

open Esm.Document (Json)

abbrev Entries := List (String × Json)
abbrev Renames := List (String × String)

structure Failure where
  code : String
  detail : String
  deriving Repr

structure Exports where
  definitions : Entries := []
  axes : Entries := []
  metaparameters : Entries := []
  deferredBindings : List Json := []
  deriving Inhabited, Repr

structure Edge where
  ref : String
  only : Option (List String) := none
  namespacePrefix : Option String := none
  rename : Renames := []
  rebind : Renames := []
  deriving Inhabited, Repr

def objectFields : Json → Entries
  | .obj fields => fields
  | _ => []

def get (node : Json) (name : String) : Option Json := (objectFields node).lookup name

def entries (node : Json) (name : String) : Entries :=
  ((get node name).map objectFields).getD []

def set (node : Json) (key : String) (value : Json) : Json :=
  let fields := objectFields node
  if (fields.lookup key).isSome then
    .obj (fields.map fun (name, old) => (name, if key == name then value else old))
  else .obj (fields ++ [(key, value)])

def remove (node : Json) (key : String) : Json :=
  .obj ((objectFields node).filter fun field => field.1 != key)

def string? : Json → Option String
  | .str name => some name
  | _ => none

def strings : Json → List String
  | .arr values => values.filterMap string?
  | _ => []

def exports (node : Json) : Exports :=
  { definitions := entries node "operators", axes := entries node "index_sets",
    metaparameters := entries node "metaparameters" }

def Exports.asDocument (value : Exports) : Json :=
  .obj [("operators", .obj value.definitions), ("index_sets", .obj value.axes),
    ("metaparameters", .obj value.metaparameters)]

/-- Append unseen names, preserving the first occurrence of deep-equal entries. -/
def mergeEntries (code : String) (earlier later : Entries) : Except Failure Entries :=
  later.foldlM (init := earlier) fun merged (name, value) => do
    match merged.lookup name with
    | none => return merged ++ [(name, value)]
    | some previous =>
      unless sameValue previous value do throw ⟨code, name⟩
      return merged

def merge (earlier later : Exports) : Except Failure Exports := do
  let definitions ← mergeEntries "operator_import_name_conflict" earlier.definitions later.definitions
  let axes ← mergeEntries "operator_import_index_set_conflict" earlier.axes later.axes
  let metaparameters ← mergeEntries "operator_import_name_conflict" earlier.metaparameters later.metaparameters
  let deferredBindings := later.deferredBindings.foldl (init := earlier.deferredBindings) fun kept value =>
    if kept.any (sameValue value) then kept else kept ++ [value]
  return ⟨definitions, axes, metaparameters, deferredBindings⟩

theorem mergeEntries_append_new (code name : String) (earlier : Entries) (value : Json)
    (fresh : earlier.lookup name = none) :
    mergeEntries code earlier [(name, value)] = .ok (earlier ++ [(name, value)]) := by
  simp [mergeEntries, fresh, pure, Except.pure, bind, Except.bind]

theorem mergeEntries_keep_first (code name : String) (earlier : Entries) (previous value : Json)
    (registered : earlier.lookup name = some previous) (equal : sameValue previous value = true) :
    mergeEntries code earlier [(name, value)] = .ok earlier := by
  simp [mergeEntries, registered, equal, pure, Except.pure, bind, Except.bind]

partial def referenceSites : Json → List Json
  | .arr items => items.flatMap referenceSites
  | node@(.obj fields) =>
    if ((fields.lookup "op").bind string?) == some "apply_operator" then
      node :: (((fields.lookup "bindings").map objectFields).getD []).flatMap (referenceSites ∘ Prod.snd)
    else fields.flatMap fun (key, value) => if key == "attrs" then [] else referenceSites value
  | _ => []

private def closure (definitions : Entries) : Nat → List String → List String
  | 0, names => names
  | fuel + 1, names =>
    let dependencies := names.flatMap fun name =>
      ((definitions.lookup name >>= fun declaration => get declaration "body").map (fun body => (referenceSites body).filterMap fun site => get site "name" >>= string?)).getD []
    let next := (names ++ dependencies).eraseDups
    if next == names then names else closure definitions fuel next

/-- The target's resolution scope is intact when visibility is filtered. Keep
a selected definition's reference dependencies in their original sequence. -/
def selectDefinitions (definitions : Entries) (only : Option (List String)) :
    Except Failure Entries := do
  let some names := only | return definitions
  for name in names do
    unless (definitions.lookup name).isSome do throw ⟨"operator_import_unknown_name", name⟩
  let retained := closure definitions definitions.length names.eraseDups
  return definitions.filter fun (name, _) => retained.contains name

def renamed (mapping : Renames) (name : String) : String := (mapping.lookup name).getD name

def renamedExport (edge : Edge) (name : String) : String :=
  (edge.rename.lookup name).getD (edge.namespacePrefix.map (· ++ "." ++ name) |>.getD name)

private def asciiLetter (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z')

private def validSegment (segment : String) : Bool :=
  match segment.toList with
  | [] => false
  | head :: tail =>
    (asciiLetter head || head == '_') &&
      tail.all (fun c => asciiLetter c || c == '_' || ('0' ≤ c && c ≤ '9'))

def validIdentifier (name : String) : Bool := (name.splitOn ".").all validSegment

private def names {α : Type} (fields : List (String × α)) : List String := fields.map Prod.fst

private def scopedName (mapping : Renames) (shadowed : List String) : Json → Json
  | .str name => .str (if shadowed.contains name then name else renamed mapping name)
  | value => value

private def mapArray (f : Json → Json) : Json → Json
  | .arr values => .arr (values.map f)
  | value => value

def renameShape (mapping : Renames) : Json → Json := mapArray (scopedName mapping [])

def renameWhere (mapping : Renames) : Json → Json
  | .obj fields => .obj (fields.map fun (parameter, constraint) =>
      (parameter, match constraint with
      | .obj specs => .obj (specs.map fun (key, value) =>
        (key, if key == "shape" then renameShape mapping value else value))
      | _ => constraint))
  | value => value

/-- Each axis in a shape constraint follows the same map as an axis
declaration key. Shape order and the parameter being constrained stay put. -/
theorem renameWhere_shape (mapping : Renames) (param : String) (axes : List String) :
    renameWhere mapping (.obj [(param, .obj [("shape", .arr (axes.map Json.str))])]) =
      .obj [(param, .obj [("shape", .arr ((axes.map (renamed mapping)).map Json.str))])] := by
  simp [renameWhere, renameShape, mapArray, scopedName, List.map_map, Function.comp_def]

private structure Names where
  free : List String := []
  bound : List String := []
  loops : List String := []
  deriving Inhabited

private structure Mapping where
  axes : Renames := []
  definitions : Renames := []
  rebind : Renames := []

private def useName (mapping : Mapping) (shadowed : List String) (name : String) : StateM Names Json := do
  if shadowed.contains name then return .str name
  modify fun state => {state with free := name :: state.free}
  return .str (renamed mapping.rebind name)

private def renameRanges (mapping : Mapping) (shadowed : List String) : Json → Json
  | .obj ranges => .obj (ranges.map fun (symbol, range) =>
      (symbol, match range with
        | .obj fields => .obj (fields.map fun (key, value) =>
          (key, if key == "from" then scopedName mapping.axes shadowed value else value))
        | _ => range))
  | value => value

private def renameJoins (mapping : Mapping) (shadowed : List String) (ranges : Entries) :
    Json → Json :=
  let sourceAxes := ranges.filterMap fun (_, range) => get range "from" >>= string?
  mapArray fun clause =>
    match clause with
    | .obj fields => .obj (fields.map fun (key, value) =>
      (key, if key == "on" then
        mapArray (mapArray fun item =>
          match item with
          | .str axis => if sourceAxes.contains axis then scopedName mapping.axes shadowed item else item
          | _ => item) value
      else value))
    | value => value

private partial def renameExpr (mapping : Mapping) (shadowed : List String) :
    Json → StateM Names Json
  | .str name => useName mapping shadowed name
  | tree@(.arr items) => do
    if (Metaparameters.deferredPayload tree).isSome then return tree
    return .arr (← items.mapM (renameExpr mapping shadowed))
  | .obj fields => do
    let op := (fields.lookup "op").bind string?
    let loops := (fields.lookup "output_idx").map strings |>.getD [] |>.append
      (names ((fields.lookup "ranges").map objectFields |>.getD []))
    modify fun state => {state with bound := loops ++ state.bound, loops := loops ++ state.loops}
    let localScope := loops ++ shadowed
    let changed ← fields.mapM fun (key, value) => do
      let next ← match key with
        | "wrt" | "dim" => pure (scopedName mapping.axes shadowed value)
        | "var" => pure (if op == some "integral" then scopedName mapping.axes shadowed value else value)
        | "lower" | "upper" =>
          let edited := scopedName mapping.axes shadowed value
          if op == some "integral" &&
              ((string? value).any fun name => (mapping.axes.lookup name).isSome && !shadowed.contains name) then
            pure edited
          else renameExpr mapping localScope value
        | "ranges" => pure (renameRanges mapping shadowed value)
        | "join" => pure (renameJoins mapping localScope ((fields.lookup "ranges").map objectFields |>.getD []) value)
        | "name" =>
          pure (if op == some "apply_operator" then scopedName mapping.definitions [] value else value)
        | "bindings" =>
          if op == some "apply_operator" then
            .obj <$> (objectFields value).mapM (fun (name, arg) =>
              return (name, ← renameExpr mapping localScope arg))
          else pure value
        | "args" | "expr" | "filter" | "key" | "values" => renameExpr mapping localScope value
        | _ => pure value
      return (key, next)
    return .obj changed
  | value => pure value

private def rewriteAxis (mapping : Mapping) (axis : Json) : StateM Names Json := do
  let kind := get axis "kind" >>= string?
  let changed ← (objectFields axis).mapM fun (key, value) => do
    let value ← match key with
      | "of" => pure (renameShape mapping.axes value)
      | "offsets" | "values" | "member_factor" =>
        if kind == some "ragged" then
          match value with
          | .str name => useName mapping [] name
          | _ => pure value
        else pure value
      | _ => pure value
    return (key, value)
  return .obj changed

private def inferredOperator (name : String) (decl : Json) : String :=
  ((get decl "match" >>= fun pattern => get pattern "op" >>= string?).filter
    (fun op => !Document.Notation.coreOpNames.contains op)).getD name

private def rewriteDefinition (mapping : Mapping) (oldName newName : String) (decl : Json) :
    StateM Names Json := do
  let parameters := (get decl "params").map strings |>.getD []
  modify fun state => {state with bound := parameters ++ state.bound}
  -- Renaming the definition key preserves the name it defines.
  let decl := if oldName != newName && (get decl "defines").isNone then
    set decl "defines" (.str (inferredOperator oldName decl))
  else decl
  let fields ← (objectFields decl).mapM fun (key, value) => do
    let value ← match key with
      | "body" | "match" => renameExpr mapping parameters value
      | "where" => pure (renameWhere mapping.axes value)
      | _ => pure value
    return (key, value)
  return .obj fields

private def rewriteExports (mapping : Mapping) (value : Exports) : StateM Names Exports := do
  let definitions ← value.definitions.mapM fun (name, declaration) => do
    let target := renamed mapping.definitions name
    return (target, ← rewriteDefinition mapping name target declaration)
  let axes ← value.axes.mapM fun (name, axis) =>
    return (renamed mapping.axes name, ← rewriteAxis mapping axis)
  return {value with definitions, axes}

private def checkRebind (edge : Edge) (declared targets : List String) (seen : Names) :
    Except Failure Unit := do
  let inputs := names edge.rebind
  let free := seen.free.eraseDups.filter fun name => !declared.contains name
  for (name, _) in edge.rebind do
    if seen.loops.contains name then
      throw ⟨"operator_import_rename_invalid", s!"'{name}' is bound"⟩
    unless free.contains name do throw ⟨"operator_import_rebind_unknown_name", name⟩
  let outputs := edge.rebind.map Prod.snd
  let surviving := free.filter fun name => !inputs.contains name
  unless outputs.Nodup do throw ⟨"operator_import_rename_collision", edge.ref⟩
  for output in outputs do
    if seen.bound.contains output || surviving.contains output || targets.contains output then
      throw ⟨"operator_import_rename_collision", output⟩

structure RenamePlan where
  metaRenames : Renames
  transform : Exports → Exports

/-- Resolve rename domains against the selected definitions and open
metaparameters. Apply the resulting transform after instantiation, so a
binding from the importer never becomes a name in the target's vocabulary. -/
def planRename (edge : Edge) (value : Exports) (boundMetas : List String := []) :
    Except Failure RenamePlan := do
  if edge.namespacePrefix.isNone && edge.rename.isEmpty && edge.rebind.isEmpty then
    return ⟨[], id⟩
  let definitions := names value.definitions
  let axes := names value.axes
  let allMetas := names value.metaparameters
  let metas := allMetas.filter fun name => !boundMetas.contains name
  let declared := definitions ++ axes ++ metas
  let allTargets := (edge.namespacePrefix.toList ++ edge.rename.map Prod.snd ++ edge.rebind.map Prod.snd)
  for target in allTargets do
    unless validIdentifier target do throw ⟨"operator_import_rename_invalid", target⟩
  for (name, _) in edge.rename do
    unless declared.contains name do throw ⟨"operator_import_rename_unknown_name", name⟩
  for domain in [definitions, axes, metas] do
    unless (domain.map (renamedExport edge)).Nodup do
      throw ⟨"operator_import_rename_collision", edge.ref⟩
  let remap := fun names => names.map fun name => (name, renamedExport edge name)
  let mapping : Mapping := ⟨remap axes, remap definitions, edge.rebind⟩
  if !edge.rebind.isEmpty then
    let (_, seen) := (rewriteExports {} value).run {}
    checkRebind edge (definitions ++ axes ++ allMetas) (declared.map (renamedExport edge)) seen
  let metaRenames := (remap metas).filter fun (original, target) => original != target
  return ⟨metaRenames, fun instantiated => ((rewriteExports mapping instantiated).run {}).1⟩

end Esm.Rewrite.Imports
