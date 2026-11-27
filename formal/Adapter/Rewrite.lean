import Adapter.OrderedJson
import Esm.Rewrite.BodyGraph
import Adapter.OperatorImports
import Esm.Rewrite.Definitions
import Esm.Rewrite.Match

/-! Component-local rewrite conformance. The adapter exposes the lowered expression
roots and an explicit expanded view for scoring against the existing goldens. -/

namespace Adapter.Rewrite

open Esm.Document Esm.Rewrite

private structure Failure where
  code : String
  detail : String
  deriving Inhabited

private def field (j : Json) (name : String) : Option Json :=
  match j with
  | .obj fields => fields.lookup name
  | _ => none

private def fields (j : Json) : List (String × Json) :=
  match j with
  | .obj items => items
  | _ => []

private def strings : Json → Option (List String)
  | .arr values => values.mapM fun | .str s => some s | _ => none
  | _ => none

private def badDefinition (name message : String) : Failure :=
  ⟨"operator_invalid_definition", s!"{name}: {message}"⟩

private def readRule (name : String) (definition : Json) : Except Failure Rule := do
  let some params := (field definition "params").bind strings
    | throw (badDefinition name "expected an ordered array of params")
  if !decide params.Nodup || params.any String.isEmpty then
    throw (badDefinition name "params must be distinct and non-empty")
  let some body := field definition "body" | throw (badDefinition name "missing body")
  let priority ← match field definition "priority" with
    | none => pure 0
    | some (.num (.int p)) => pure p
    | _ => throw (badDefinition name "priority must be an integer")
  let defines ← match field definition "defines" with
    | none => pure none
    | some (.str op) => pure (some op)
    | _ => throw (badDefinition name "defines must be a string")
  let referenceOnly ← match field definition "reference_only" with
    | none => pure false
    | some (.bool value) => pure value
    | _ => throw (badDefinition name "reference_only must be boolean")
  let pattern := field definition "match"
  let constraints := field definition "where"
  return { name, params, body, priority, defines, referenceOnly, pattern, constraints }

private def readRules (document component : Json) : Except Failure (List Rule) := do
  let indexSets := (fields ((field document "index_sets").getD .null) ++
    fields ((field component "index_sets").getD .null)).map Prod.fst
  let registry := (field component "operators").getD (.obj [])
  let .obj definitions := registry | throw (badDefinition "operators" "expected an object")
  definitions.mapM fun (name, definition) => do
    let rule ← readRule name definition
    (validateRule indexSets rule).mapError fun code => ⟨code, name⟩
    return rule

private abbrev Values := List (String × Json)

private structure Arguments where
  -- Only the explicit view substitutes these trees into the definition body.
  expanded : Values := []
  -- A reference stays opaque even when its explicit expansion is a bare variable.
  instanceArgs : InstanceEnv := []
  deriving Inhabited

private structure Scope where
  rules : List Rule
  arities : DefinitionArities
  shapes : ShapeEnv
  independent : String
  deriving Inhabited

private def referenceNameField (items : Values) (key : String) : Bool :=
  match items.lookup "op" with
  | some (.str "apply_operator") => key == "name"
  | _ => false

private partial def substitute (values : Values) : Json → Json
  | .str name => (values.lookup name).getD (.str name)
  | .arr items => .arr (items.map (substitute values))
  | .obj items => .obj (items.map fun (k, v) =>
      (k, if referenceNameField items k then v else
        match k, v with
        | "bindings", .obj bs | "ranges", .obj bs =>
          .obj (bs.map fun (p, arg) => (p, substitute values arg))
        | _, _ => substitute values v))
  | leaf => leaf

private def bindingLiteral (arguments : Arguments) : Json → Option Json
  | value@(.str name) =>
    match arguments.instanceArgs.lookup name with
    | some arg => arg.literal
    | none => some value
  | value@(.num _) | value@(.bool _) => some value
  | _ => none

private def bindingShape (scope : Scope) (arguments : Arguments) (shadowed : List String) :
    Json → Option (List String)
  | .str name =>
    if shadowed.contains name || name.contains '.' then none
    else match arguments.instanceArgs.lookup name with
      | some arg => arg.shape
      | none => scope.shapes.lookup name
  | _ => none

private def lowerTree (scope : Scope) (arguments : Arguments) (tree : Json) (depth : Nat)
    (owner : String) : Except Failure RewriteResult := do
  let lowered ← (rewriteTracked scope.rules
    (eligibleWithTime scope.independent scope.shapes arguments.instanceArgs) tree depth)
    |>.mapError fun error => ⟨"rewrite_rule_nonterminating", s!"{owner}: {error.rule} at {error.path}"⟩
  (checkCallArities scope.arities lowered.tree).mapError fun error => ⟨error.code, error.detail⟩
  return lowered

private def readBindings (rule : Rule) (refer : Json) : Except Failure Values := do
  let some (.obj bindings) := field refer "bindings"
    | throw ⟨"operator_bindings_mismatch", rule.name⟩
  unless bindings.length == rule.params.length do throw ⟨"operator_bindings_mismatch", rule.name⟩
  rule.params.mapM fun param =>
    match bindings.lookup param with
    | some value => pure (param, value)
    | none => throw ⟨"operator_bindings_mismatch", s!"{rule.name}: missing {param}"⟩

private partial def references : Json → List Json
  | .arr values => values.flatMap references
  | j@(.obj items) =>
    let nested := items.flatMap fun (k, value) =>
      if k == "attrs" || referenceNameField items k then [] else references value
    match items.lookup "op" with
    | some (.str "apply_operator") => j :: nested
    | _ => nested
  | _ => []

private def validateReference (scope : Scope) (ref : Json) : Except Failure String := do
  let some (.str name) := field ref "name" | throw ⟨"operator_unknown_definition", "missing name"⟩
  let some rule := scope.rules.find? (fun rule => rule.name == name && rule.pattern.isNone)
    | throw ⟨"operator_unknown_definition", name⟩
  let some (.arr []) := field ref "args" | throw ⟨"operator_bindings_mismatch", name⟩
  let _ ← readBindings rule ref
  return name

private def validateRegistry (scope : Scope) : Except Failure Unit := do
  let graph ← scope.rules.mapM fun rule => do
    let names ← (references rule.body).mapM (validateReference scope)
    return (rule.name, names)
  (BodyGraph.checkGraph graph).mapError fun (code, detail) => ⟨code, detail⟩

private def pathText (path : List String) : String := "/" ++ "/".intercalate path

private structure InstanceKey where
  definition : String
  context : String
  deriving BEq, Hashable

private structure VisitKey where
  instanceKey : InstanceKey
  bindings : String
  depth : Nat
  remaining : Nat
  deriving BEq, Hashable

private inductive Projection where
  | roots | expanded | emitted
  deriving BEq

private abbrev ReferenceTargets := List (List String × InstanceKey)

private structure TreeView where
  tree : Json
  targets : ReferenceTargets := []
  deriving Inhabited

private def instanceKey (name : String) (instances : InstanceEnv) : InstanceKey :=
  let context := instances.map fun (param, arg) =>
    (param, Json.arr [arg.literal.getD .null,
      (arg.shape.map (fun axes => Json.arr (axes.map Json.str))).getD .null])
  ⟨name, Doc.render (.obj context)⟩

private structure ExpansionState where
  active : List InstanceKey := []
  completed : Std.HashSet VisitKey := {}
  instances : Std.HashMap InstanceKey TreeView := {}
  instanceOrder : List InstanceKey := []

private abbrev Expansion := StateT ExpansionState (Except Failure)

/-- Only the expanded view substitutes trees. The emitted view records the
instance named by each reference for placement after every root is lowered. -/
private partial def expandTree (mode : Projection) (scope : Scope) (arguments : Arguments)
    (origins : List Origin) (depth remaining : Nat) (shadowed path : List String) (tree : Json) :
    Expansion TreeView := do
  let materialize := mode == .expanded
  let track := mode == .emitted
  match tree with
  | .str name => return ⟨if materialize then (arguments.expanded.lookup name).getD tree else tree, []⟩
  | .arr xs =>
    let items ← xs.zipIdx.mapM fun (item, index) =>
      expandTree mode scope arguments origins depth remaining shadowed (path ++ [toString index]) item
    return ⟨if materialize then .arr (items.map (·.tree)) else tree, items.flatMap (·.targets)⟩
  | .obj entries =>
    if let some (.str "apply_operator") := entries.lookup "op" then
      let some (.str name) := entries.lookup "name" | throw ⟨"operator_invalid_reference", pathText path⟩
      let some rule := scope.rules.find? (fun rule => rule.name == name)
        | throw ⟨"operator_unknown_definition", name⟩
      let origin := origins.find? (fun origin => origin.path == path)
      let bindings ← readBindings rule tree
      let instanceArgs := bindings.map fun (param, value) =>
        let argument : InstanceArgument :=
          { literal := bindingLiteral arguments value, shape := bindingShape scope arguments shadowed value }
        (param, argument)
      let views ← bindings.mapM fun (param, value) => do
        return (param, ← expandTree mode scope arguments origins depth remaining shadowed
          (path ++ ["bindings", param]) value)
      let passed : Arguments := {
        instanceArgs, expanded := if materialize then views.map (fun (p, view) => (p, view.tree)) else [] }
      let depth := max depth ((origin.map (·.depth)).getD 0)
      let currentInstance := instanceKey name instanceArgs
      let targets := if track then (path, currentInstance) :: views.flatMap (·.2.targets) else []
      let active := (← get).active
      if active.contains currentInstance then
        throw ⟨"rewrite_rule_nonterminating", s!"{name}: rewriting needs the same definition instance"⟩
      let key : Option VisitKey := if materialize then none else
        some ⟨currentInstance, Doc.render (.obj bindings), depth, remaining⟩
      if let some key := key then
        if (← get).completed.contains key then return ⟨tree, targets⟩
      let lowered ← lowerTree scope passed rule.body depth name
      let remaining + 1 := remaining
        | throw ⟨"operator_body_expansion_too_deep", name⟩
      modify fun state => { state with active := currentInstance :: active }
      let view ← expandTree mode scope passed lowered.origins depth remaining [] [] lowered.tree
      modify fun state =>
        let completed := match key with
          | some key => state.completed.insert key
          | none => state.completed
        let state := { state with active, completed }
        if track && !state.instances.contains currentInstance then
          { state with
            instances := state.instances.insert currentInstance view
            instanceOrder := currentInstance :: state.instanceOrder }
        else state
      return if materialize then view else ⟨tree, targets⟩
    else
      let shadowed := loopNames entries ++ shadowed
      let children ← entries.mapM fun (key, value) => do
        if key == "attrs" then
          return (key, (⟨if materialize then substitute arguments.expanded value else value, []⟩ : TreeView))
        return (key, ← expandTree mode scope arguments origins depth remaining shadowed (path ++ [key]) value)
      return ⟨if materialize then .obj (children.map (fun (key, view) => (key, view.tree))) else tree,
        children.flatMap (·.2.targets)⟩
  | _ => return ⟨tree, []⟩

private def lowerRoot (scope : Scope) (mode : Projection) (tree : Json) : Expansion TreeView := do
  (references tree).forM fun ref => do
    let _ ← validateReference scope ref
  let lowered ← lowerTree scope {} tree 0 "expression"
  expandTree mode scope {} lowered.origins 0 maxRewritePasses [] [] lowered.tree

private def projectItems (scope : Scope) (component : Json) (mode : Projection)
    (collection : String) (expressions : List String) : Expansion (String × TreeView) := do
  let .arr items := (field component collection).getD (.arr [])
    | throw ⟨"invalid_document", s!"{collection} must be an array"⟩
  let views ← items.zipIdx.mapM fun (item, index) => do
    let .obj record := item | throw ⟨"invalid_document", s!"{collection}: expected an object"⟩
    let children ← record.mapM fun (key, value) => do
      let view ← if expressions.contains key then lowerRoot scope mode value else pure ⟨value, []⟩
      let targets := view.targets.map fun (path, target) => (collection :: toString index :: key :: path, target)
      return (key, { view with targets })
    return (⟨.obj (children.map fun (key, view) => (key, view.tree)),
      children.flatMap (·.2.targets)⟩ : TreeView)
  return (collection, ⟨.arr (views.map (·.tree)), views.flatMap (·.targets)⟩)

private def shapes (component : Json) : ShapeEnv :=
  (["variables", "species", "parameters"].flatMap fun key => fields ((field component key).getD .null))
    |>.filterMap fun (name, declaration) =>
      ((field declaration "shape").bind strings).map fun dims => (name, dims)

private abbrev InstanceNames := Std.HashMap InstanceKey String
private abbrev InstanceGroups := Std.HashMap String (List InstanceKey)

private def components (document : Json) : Values :=
  fields ((field document "models").getD .null) ++ fields ((field document "reaction_systems").getD .null)

private def authoredOperatorNames (document : Json) (componentName : String) : List String :=
  let component := ((components document).lookup componentName).getD .null
  (fields ((field component "operators").getD .null)).map Prod.fst

private def putField (items : Values) (key : String) (value : Json) : Values :=
  if (items.lookup key).isSome then items.map fun (k, v) => (k, if k == key then value else v)
  else items ++ [(key, value)]

private partial def repointJson (names : Std.HashMap (List String) String) (path : List String) : Json → Json
  | .arr xs => .arr (xs.zipIdx.map fun (x, i) => repointJson names (path ++ [toString i]) x)
  | .obj entries =>
    let children := entries.map fun (k, v) =>
      (k, if k == "attrs" then v else repointJson names (path ++ [k]) v)
    .obj (match names[path]? with
      | none => children
      | some name => putField children "name" (.str name))
  | leaf => leaf

private def TreeView.repoint (view : TreeView) (names : InstanceNames) : Json :=
  let targets := view.targets.foldl (init := ({} : Std.HashMap (List String) String))
    fun acc (path, key) => match names[key]? with
      | none => acc
      | some name => acc.insert path name
  repointJson targets [] view.tree

private partial def sortJson : Json → Json
  | .arr xs => .arr (xs.map sortJson)
  | .obj entries => .obj (Source.sortKeys (entries.map fun (k, v) => (k, sortJson v)))
  | leaf => leaf

private def bodyBytes (body : Json) : String := Doc.render (sortJson body)

private def dependencyGraph (state : ExpansionState) (groups : InstanceGroups) :
    Std.HashMap String (List String) :=
  groups.fold (init := {}) fun graph name keys =>
    let children := keys.flatMap fun key =>
      ((state.instances[key]?.getD default).targets.map fun (_, target) => target.definition)
    graph.insert name children.eraseDups

private partial def placementOrder (graph : Std.HashMap String (List String))
    (active : List String) (done : Std.HashSet String × List String) (name : String) :
    Except Failure (Std.HashSet String × List String) := do
  if done.1.contains name then return done
  if active.contains name then
    throw ⟨"rewrite_rule_nonterminating", s!"{name}: rewritten bodies depend on their own definition"⟩
  let (visited, order) ← (graph[name]?.getD []).foldlM (placementOrder graph (name :: active)) done
  return (visited.insert name, name :: order)

private def instanceBodies (state : ExpansionState) (keys : List InstanceKey) (names : InstanceNames) :
    List (InstanceKey × Json × String) :=
  keys.map fun key =>
    let body := (state.instances[key]?.getD default).repoint names
    (key, body, bodyBytes body)

private def distinctBodies (bodies : List (InstanceKey × Json × String)) : List String :=
  (bodies.map (·.2.2)).mergeSort (fun a b => decide (a ≤ b)) |>.eraseDups

/-- Use unique symbolic names for child bodies to determine which definitions
need variants before choosing whether their authored bodies stay visible. -/
private def multibodyDefinitions (state : ExpansionState) (groups : InstanceGroups)
    (order : List String) : Std.HashSet String :=
  (order.foldl (init := (({} : InstanceNames), ({} : Std.HashSet String)))
    fun (names, multi) name =>
      let bodies := instanceBodies state (groups[name]?.getD []) names
      let distinct := distinctBodies bodies
      let different := distinct.length > 1
      let names := bodies.foldl (init := names) fun acc (key, _, bytes) =>
        let candidate := if different then name ++ String.singleton (Char.ofNat 31) ++ toString (distinct.idxOf bytes)
          else name
        acc.insert key candidate
      (names, if different then multi.insert name else multi)).2

private def referenceNames (body : Json) : List String :=
  (references body).filterMap fun ref => match field ref "name" with
    | some (.str name) => some name
    | _ => none

private partial def exposedDefinitions (scope : Scope) (groups : InstanceGroups) (multi : Std.HashSet String) :
    Std.HashSet String := Id.run do
  let matchless := scope.rules.filter (·.pattern.isNone)
  let edges := matchless.foldl (init := ({} : Std.HashMap String (List String)))
    fun graph rule => graph.insert rule.name (referenceNames rule.body)
  let roots := matchless.filterMap fun rule =>
    if !groups.contains rule.name || multi.contains rule.name then some rule.name else none
  return visit edges groups roots {}
where
  visit (edges : Std.HashMap String (List String)) (groups : InstanceGroups)
      (pending : List String) (seen : Std.HashSet String) : Std.HashSet String :=
    match pending with
    | [] => seen
    | name :: rest =>
      let children := (edges[name]?.getD []).filter fun child =>
        edges.contains child && groups.contains child && !seen.contains child
      let seen := children.foldl (fun seen child => seen.insert child) seen
      visit edges groups (children ++ rest) seen

private def definitionEntry (name : String) (entry : Json) : Values :=
  let declared := fields entry
  if (declared.lookup "defines").isSome then declared else
    let fromPattern := match (field entry "match").bind (field · "op") with
      | some (.str op) => if Notation.coreOpNames.contains op then name else op
      | _ => name
    putField declared "defines" (.str fromPattern)

private def referenceOnly (entry : Values) : Values :=
  putField (entry.filter fun (k, _) => !(["match", "where", "priority"].contains k))
    "reference_only" (.bool true)

private def freshName (taken : Std.HashMap String Json) (name : String) : String :=
  go (taken.size + 1) name
where
  go : Nat → String → String
    | 0, name => name
    | fuel + 1, name => if taken.contains name then go fuel (name ++ "_") else name

private structure Placement where
  names : InstanceNames := {}
  entries : Std.HashMap String Json := {}

private def placeDefinition (state : ExpansionState) (groups : InstanceGroups)
    (exposed : Std.HashSet String) (placement : Placement) (name : String) : Placement := Id.run do
  let original := placement.entries[name]?.getD .null
  let entry := fields original
  let authoredBody := (entry.lookup "body").getD .null
  let bodies := instanceBodies state (groups[name]?.getD []) placement.names
  let distinct := distinctBodies bodies
  if let [bytes] := distinct then
    if !exposed.contains name || bytes == bodyBytes authoredBody then
      let names := bodies.foldl (fun acc (key, _, _) => acc.insert key name) placement.names
      let body := (bodies.head?.map (·.2.1)).getD authoredBody
      let entry := if (entry.lookup "match").isSome then referenceOnly entry else entry
      return ⟨names, placement.entries.insert name (.obj (putField entry "body" body))⟩
  let mut placement := placement
  for (bytes, index) in distinct.zipIdx do
    let variant := freshName placement.entries s!"{name}.variant{index + 1}"
    let some (_, body, _) := bodies.find? (fun (_, _, encoded) => bytes == encoded) | continue
    let entries := placement.entries.insert variant (.obj (putField (referenceOnly entry) "body" body))
    let names := bodies.foldl (init := placement.names) fun acc (key, _, encoded) =>
      if bytes == encoded then acc.insert key variant else acc
    placement := ⟨names, entries⟩
  return placement

private partial def reachableEntries (entries : Std.HashMap String Json) (pending : List String)
    (seen : Std.HashSet String) : Std.HashSet String :=
  match pending with
  | [] => seen
  | name :: rest =>
    if seen.contains name then reachableEntries entries rest seen
    else
      let children := referenceNames (entries[name]?.getD .null)
      reachableEntries entries (children ++ rest) (seen.insert name)

private def emitProjection (scope : Scope) (component : Json) (authored : List String)
    (view : TreeView) (state : ExpansionState) : Except Failure Json := do
  let groups := state.instanceOrder.foldl (init := ({} : InstanceGroups)) fun groups key =>
    groups.insert key.definition (key :: groups[key.definition]?.getD [])
  let graph := dependencyGraph state groups
  let (_, order) ← (scope.rules.filterMap fun rule =>
    if groups.contains rule.name then some rule.name else none).foldlM (placementOrder graph []) ({}, [])
  let order := order.reverse
  let exposed := exposedDefinitions scope groups (multibodyDefinitions state groups order)
  let entries := (fields ((field component "operators").getD .null)).foldl (init := {})
    fun entries (name, entry) => entries.insert name (.obj (definitionEntry name entry))
  let placement := order.foldl (placeDefinition state groups exposed) { entries }
  let roots := view.repoint placement.names
  let authoredEntries := authored.filterMap fun name => do
    let entry ← placement.entries[name]?
    if (field entry "match").isSome then none else some (name, entry)
  let materialized := reachableEntries placement.entries (referenceNames roots) {}
  let names := (materialized.toList.filter fun name => !authored.contains name).mergeSort (fun a b => decide (a ≤ b))
  let registry := authoredEntries ++ (names.filterMap fun name => (placement.entries[name]?).map (name, ·))
  return if registry.isEmpty then roots else .obj (putField (fields roots) "operators" (.obj registry))

private def project (document : Json) (componentName : String) (mode : Projection) (authoredNames : List String) :
    Except Failure Json := do
  let models := fields ((field document "models").getD .null)
  let some component := (components document).lookup componentName
    | throw ⟨"invalid_document", s!"unknown component {componentName}"⟩
  if (field component "subsystems").isSome then
    throw ⟨"unsupported_construct", "subsystems require load resolution"⟩
  let rules ← readRules document component
  let arities ← (buildDefinitionArities rules).mapError fun error => ⟨error.code, error.detail⟩
  let scope := ⟨rules, arities, shapes component, (Doc.docIndependentVariable document).getD "t"⟩
  validateRegistry scope
  let collections := if (models.lookup componentName).isSome then
      [("equations", ["lhs", "rhs"]), ("initialization_equations", ["lhs", "rhs"])]
    else [("reactions", ["rate"]), ("constraint_equations", ["lhs", "rhs"])]
  let action : Expansion (List (String × TreeView)) :=
    (collections.filter fun (key, _) => (field component key).isSome).mapM
      fun (collection, expressions) => projectItems scope component mode collection expressions
  let (projected, state) ← action.run {}
  let tree := Json.obj (projected.map fun (key, view) => (key, view.tree))
  if mode == .emitted then
    let view := ⟨tree, projected.flatMap (·.2.targets)⟩
    let emitted ← emitProjection scope component authoredNames view state
    let emitted := match field document "index_sets" with
      | some indexSets => .obj (putField (fields emitted) "index_sets" indexSets)
      | none => emitted
    return .obj ((fields (Doc.spellRules false emitted)).map fun (key, value) =>
      (key, if key == "operators" then .obj ((fields value).map fun (name, entry) => (name, sortJson entry))
        else sortJson value))
  return Doc.spellRules false tree

def main (args : List String) : IO UInt32 := do
  let options : Option (String × String × Projection) := match args with
    | [file, component] => some (file, component, .roots)
    | ["--expanded", file, component] => some (file, component, .expanded)
    | ["--emitted", file, component] => some (file, component, .emitted)
    | _ => none
  let some (file, component, mode) := options
    | IO.eprintln "usage: esm-lean rewrite-templates [--expanded|--emitted] <document.esm> <component>"; return 2
  let input ← IO.FS.readFile file
  let result : Except Failure Json ← match OrderedJson.parse input with
    | .error error => pure (.error ⟨"invalid_document", error⟩)
    | .ok raw => do
      let document := Doc.spellRules false raw (omitFaqDefaults := false)
      let authored := authoredOperatorNames document component
      let resolved ← OperatorImports.resolve (System.FilePath.mk file) document
      pure do
        let document ← resolved.mapError fun error => ⟨error.code, error.detail⟩
        project document component mode authored
  match result with
  | .ok output => IO.println (Doc.render output); return 0
  | .error error =>
    IO.eprintln (Doc.render (.obj [("code", .str error.code), ("detail", .str error.detail)]))
    return 1

end Adapter.Rewrite
