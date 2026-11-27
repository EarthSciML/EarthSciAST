import Adapter.OrderedJson
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

private abbrev BodyGraph := List (String × List String)
private abbrev Depths := List (String × Nat)

private partial def bodyDepth (graph : BodyGraph) (ancestors : List String) (known : Depths)
    (name : String) : Except Failure (Depths × Nat) := do
  if ancestors.contains name then throw ⟨"operator_recursive_body", name⟩
  if ancestors.length ≥ maxRewritePasses then throw ⟨"operator_body_expansion_too_deep", name⟩
  if let some depth := known.lookup name then return (known, depth)
  let mut depths := known
  let mut longest := 0
  for child in (graph.lookup name).getD [] do
    let (next, depth) ← bodyDepth graph (name :: ancestors) depths child
    depths := next
    longest := max longest depth
  let depth := longest + 1
  if depth > maxRewritePasses then throw ⟨"operator_body_expansion_too_deep", name⟩
  return ((name, depth) :: depths, depth)

private def validateRegistry (scope : Scope) : Except Failure Unit := do
  let graph ← scope.rules.mapM fun rule => do
    let names ← (references rule.body).mapM (validateReference scope)
    return (rule.name, names)
  let _ ← graph.foldlM (fun known (name, _) => do
    return (← bodyDepth graph [] known name).1) []

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

private def instanceKey (name : String) (instances : InstanceEnv) : InstanceKey :=
  let context := instances.map fun (param, arg) =>
    (param, Json.arr [arg.literal.getD .null,
      (arg.shape.map (fun axes => Json.arr (axes.map Json.str))).getD .null])
  ⟨name, Doc.render (.obj context)⟩

private structure ExpansionState where
  active : List InstanceKey := []
  completed : Std.HashSet VisitKey := {}

private abbrev Expansion := StateT ExpansionState (Except Failure)

/-- Walk reachable references in both modes. Only the explicit expansion
builds substituted result trees. A completed check of a definition body does
not skip checks of a different call site's own bindings. -/
private partial def expandTree (materialize : Bool) (scope : Scope) (arguments : Arguments)
    (origins : List Origin) (depth remaining : Nat) (shadowed path : List String) (tree : Json) :
    Expansion Json := do
  match tree with
  | .str name => return if materialize then (arguments.expanded.lookup name).getD tree else tree
  | .arr xs =>
    let items ← xs.zipIdx.mapM fun (item, index) =>
      expandTree materialize scope arguments origins depth remaining shadowed (path ++ [toString index]) item
    return if materialize then .arr items else tree
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
      let expanded ← bindings.mapM fun (param, value) => do
        return (param, ← expandTree materialize scope arguments origins depth remaining shadowed
          (path ++ ["bindings", param]) value)
      let passed : Arguments := { instanceArgs, expanded := if materialize then expanded else [] }
      let depth := max depth ((origin.map (·.depth)).getD 0)
      let currentInstance := instanceKey name instanceArgs
      let active := (← get).active
      if active.contains currentInstance then
        throw ⟨"rewrite_rule_nonterminating", s!"{name}: rewriting needs the same definition instance"⟩
      let key : Option VisitKey := if materialize then none else
        some ⟨currentInstance, Doc.render (.obj bindings), depth, remaining⟩
      if let some key := key then
        if (← get).completed.contains key then return tree
      let lowered ← lowerTree scope passed rule.body depth name
      let remaining + 1 := remaining
        | throw ⟨"operator_body_expansion_too_deep", name⟩
      modify fun state => { state with active := currentInstance :: active }
      let view ← expandTree materialize scope passed lowered.origins depth remaining [] [] lowered.tree
      modify fun state => { active, completed := match key with
        | some key => state.completed.insert key
        | none => state.completed }
      return if materialize then view else tree
    else
      let shadowed := loopNames entries ++ shadowed
      let children ← entries.mapM fun (key, value) => do
        if key == "attrs" then
          return (key, if materialize then substitute arguments.expanded value else value)
        return (key, ← expandTree materialize scope arguments origins depth remaining shadowed (path ++ [key]) value)
      return if materialize then .obj children else tree
  | _ => return tree

private def lowerRoot (scope : Scope) (expanded : Bool) (tree : Json) : Except Failure Json := do
  (references tree).forM fun ref => do
    let _ ← validateReference scope ref
  let lowered ← lowerTree scope {} tree 0 "expression"
  let (view, _) ← (expandTree expanded scope {} lowered.origins 0 maxRewritePasses [] [] lowered.tree).run {}
  return view

private def projectItems (scope : Scope) (component : Json) (expanded : Bool)
    (collection : String) (expressions : List String) : Except Failure (String × Json) := do
  let .arr items := (field component collection).getD (.arr [])
    | throw ⟨"invalid_document", s!"{collection} must be an array"⟩
  return (collection, .arr (← items.mapM fun item => do
    let .obj record := item | throw ⟨"invalid_document", s!"{collection}: expected an object"⟩
    return .obj (← record.mapM fun (key, value) => do
      if expressions.contains key then return (key, ← lowerRoot scope expanded value)
      return (key, value))))

private def shapes (component : Json) : ShapeEnv :=
  (["variables", "species", "parameters"].flatMap fun key => fields ((field component key).getD .null))
    |>.filterMap fun (name, declaration) =>
      ((field declaration "shape").bind strings).map fun dims => (name, dims)

private def project (document : Json) (componentName : String) (expanded : Bool) :
    Except Failure Json := do
  let models := fields ((field document "models").getD .null)
  let reactions := fields ((field document "reaction_systems").getD .null)
  let some component := (models ++ reactions).lookup componentName
    | throw ⟨"invalid_document", s!"unknown component {componentName}"⟩
  if (field document "metaparameters").isSome ||
      (field document "operator_imports").isSome || (field component "operator_imports").isSome ||
      (field component "subsystems").isSome then
    throw ⟨"unsupported_construct", "operator imports, metaparameters and subsystems require load resolution"⟩
  let rules ← readRules document component
  let arities ← (buildDefinitionArities rules).mapError fun error => ⟨error.code, error.detail⟩
  let scope := ⟨rules, arities, shapes component, (Doc.docIndependentVariable document).getD "t"⟩
  validateRegistry scope
  let collections := if (models.lookup componentName).isSome then
      [("equations", ["lhs", "rhs"]), ("initialization_equations", ["lhs", "rhs"])]
    else [("reactions", ["rate"]), ("constraint_equations", ["lhs", "rhs"])]
  let projected ← (collections.filter fun (key, _) => (field component key).isSome).mapM
    fun (collection, expressions) => projectItems scope component expanded collection expressions
  return Doc.spellRules false (.obj projected)

def main (args : List String) : IO UInt32 := do
  let options := match args with
    | [file, component] => some (file, component, false)
    | ["--expanded", file, component] => some (file, component, true)
    | _ => none
  let some (file, component, expanded) := options
    | IO.eprintln "usage: esm-lean rewrite-templates [--expanded] <document.esm> <component>"; return 2
  let input ← IO.FS.readFile file
  let result : Except Failure Json := do
    let document ← (OrderedJson.parse input).mapError fun error => ⟨"invalid_document", error⟩
    project (Doc.spellRules false document (omitFaqDefaults := false)) component expanded
  match result with
  | .ok output => IO.println (Doc.render output); return 0
  | .error error =>
    IO.eprintln (Doc.render (.obj [("code", .str error.code), ("detail", .str error.detail)]))
    return 1

end Adapter.Rewrite
