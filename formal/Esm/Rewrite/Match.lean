import Esm.Rewrite.Engine

/-!
# Rewrite eligibility (esm-spec §9.6.1, §9.6.3 and §9.6.4)

Match each named pattern field, retain the source paths of captured operands,
then check `where` against the enclosing declaration shapes. The pass engine
ranks only the candidates that this predicate admits.
-/

namespace Esm.Rewrite

open Esm.Document

abbrev ShapeEnv := List (String × List String)

/-- A reachable body's parameter is opaque in an operand position. Its instance
supplies a literal for structural positions and a shape for a bare-variable
operand. -/
structure InstanceArgument where
  literal : Option Json := none
  shape : Option (List String) := none

abbrev InstanceEnv := List (String × InstanceArgument)

private def opName (fields : List (String × Json)) : Option String := do
  let .str name ← fields.lookup "op" | none
  return name

private def isReference (fields : List (String × Json)) : Bool :=
  match opName fields with
  | some op => op == "apply_operator" || op == "apply_expression_template"
  | none => false

private def plainLiteral : Json → Bool
  | .str _ | .num _ | .bool _ | .null => true
  | _ => false

private def stringArray (value : Json) : Option (List String) := do
  let .arr items ← some value | none
  items.mapM fun item => match item with | .str name => some name | _ => none

mutual

/-- Repeated captures compare complete JSON values. Object fields compare by
name while array positions stay ordered. -/
private def sameValue : Json → Json → Bool
  | .str a, .str b => a == b
  | .num a, .num b => decide (a = b)
  | .bool a, .bool b => a == b
  | .null, .null => true
  | .arr a, .arr b => sameArray a b
  | .obj a, .obj b => a.length == b.length && sameObject a b
  | _, _ => false

private def sameArray : List Json → List Json → Bool
  | [], [] => true
  | a :: rest, b :: tail => sameValue a b && sameArray rest tail
  | _, _ => false

private def sameObject : List (String × Json) → List (String × Json) → Bool
  | [], _ => true
  | (name, a) :: rest, fields =>
    match fields.lookup name with
    | some b => sameValue a b && sameObject rest fields
    | none => false

end

private structure MatchContext where
  params : List String
  shapes : ShapeEnv
  instanceArgs : InstanceEnv
  shadowed : List String
  independent : String

private def MatchContext.arg (ctx : MatchContext) (name : String) : Option InstanceArgument :=
  if ctx.shadowed.contains name then none else ctx.instanceArgs.lookup name

private def MatchContext.shapeOf (ctx : MatchContext) (operand : Json) : Option (List String) := do
  let .str name ← some operand | none
  if ctx.shadowed.contains name || name.toList.contains '.' then none
  else match ctx.arg name with
    | some arg => arg.shape
    | none => ctx.shapes.lookup name

/-- Resolve body parameter literals only for a structural match. -/
private def MatchContext.literalAt (ctx : MatchContext) (target : Json) : Option Json :=
  match target with
  | .str name => match ctx.instanceArgs.lookup name with | some arg => arg.literal | none => some target
  | _ => some target

private def MatchContext.spatialDerivative (ctx : MatchContext) (fields : List (String × Json)) : Bool :=
  if opName fields == some "D" then
    match fields.lookup "wrt" with
    | some (.str parameter) =>
      match (ctx.instanceArgs.lookup parameter).bind (·.literal) with
      | some (.str axis) => axis != ctx.independent
      | _ => false
    | _ => false
  else false

private structure Bound where
  capture : Capture
  shape : Option (List String)

private abbrev Matched := List (String × Bound)

private def bindMatch (ctx : MatchContext) (found : Matched) (param : String)
    (target : Json) (operand : Bool) (path : List String) : Option Matched := do
  unless operand || ((ctx.literalAt target).any plainLiteral) do none
  let shape := if operand then ctx.shapeOf target else none
  match found.lookup param with
  | none =>
    return (param, ⟨⟨target, if operand then some path else none⟩, shape⟩) :: found
  | some earlier =>
    unless sameValue earlier.capture.value target do none
    if earlier.shape == shape then return found
    else return found.map fun (name, bound) =>
      (name, if name == param then { bound with shape := none } else bound)

/-- Expression-valued fields carry operand provenance. Structural fields still
participate in the pattern and can bind literals. -/
private def operandField (node : List (String × Json)) (field : String) : Bool :=
  match opName node with
  | none => true
  | some "enum" => false
  | some _ => ["args", "expr", "filter", "key", "lower", "upper", "axes", "values"].contains field

mutual

private def matchPattern (ctx : MatchContext) (operand : Bool) (path : List String)
    (pattern target : Json) (found : Matched) : Option Matched := do
  if let .str param := pattern then
    if ctx.params.contains param then return ← bindMatch ctx found param target operand path
  let target ← if operand then
      match target with
      | .str name => if (ctx.arg name).isSome then none else some target
      | _ => some target
    else ctx.literalAt target
  match pattern, target with
  | .obj patternFields, .obj targetFields =>
    if operand && isReference targetFields then none
    else
      let ctx := if operand then { ctx with shadowed := loopNames targetFields ++ ctx.shadowed } else ctx
      matchFields ctx operand path patternFields targetFields found
  | .arr patterns, .arr targets => matchItems ctx operand path 0 patterns targets found
  | _, _ => if sameValue pattern target then some found else none

private def matchItems (ctx : MatchContext) (operand : Bool) (path : List String) (index : Nat)
    (patterns targets : List Json) (found : Matched) : Option Matched := do
  match patterns, targets with
  | [], [] => return found
  | p :: ps, t :: ts =>
    let bindings ← matchPattern ctx operand (path ++ [toString index]) p t found
    matchItems ctx operand path (index + 1) ps ts bindings
  | _, _ => none

private def matchFields (ctx : MatchContext) (operand : Bool) (path : List String)
    (patterns targets : List (String × Json)) (found : Matched) : Option Matched := do
  match patterns with
  | [] => return found
  | (field, pattern) :: rest =>
    let target ← targets.lookup field
    let pathToField := path ++ [field]
    let bindings ← if operand && field == "op" && ctx.spatialDerivative targets then
      matchPattern { ctx with instanceArgs := [] } false pathToField pattern (.str "partial") found
    else matchPattern ctx (operand && operandField targets field) pathToField pattern target found
    matchFields ctx operand path rest targets bindings

end

private def positional (ctx : MatchContext) (index : Nat) : List String → List Json → Matched
  | param :: params, value :: values =>
    (param, ⟨⟨value, some ["args", toString index]⟩, ctx.shapeOf value⟩) :: positional ctx (index + 1) params values
  | _, _ => []

private def matchesCall (ctx : MatchContext) (rule : Rule) (fields : List (String × Json)) : Option Matched := do
  guard (fields.all fun (name, _) => name == "op" || name == "args")
  let effectiveOp ← (fields.lookup "op").bind ctx.literalAt
  let .str op := effectiveOp | none
  guard (op == rule.defines.getD rule.name)
  let .arr args ← fields.lookup "args" | none
  guard (args.length == rule.params.length)
  return positional ctx 0 rule.params args

private def readConstraints (params : List String) : Option Json → Except String ShapeEnv
  | none => .ok []
  | some (.obj constraints) => constraints.mapM fun (param, value) => do
    if !params.contains param then throw "operator_invalid_definition"
    let .obj [("shape", shape)] := value | throw "operator_invalid_definition"
    let some axes := stringArray shape | throw "operator_invalid_definition"
    if axes.isEmpty || axes.any String.isEmpty then throw "operator_invalid_definition"
    return (param, axes)
  | some _ => .error "operator_invalid_definition"

mutual
private def patternAllowed : Json → Bool
  | .obj fields => !isReference fields && patternFieldsAllowed fields
  | .arr values => patternItemsAllowed values
  | .math _ => false
  | _ => true

private def patternFieldsAllowed : List (String × Json) → Bool
  | [] => true
  | (_, value) :: rest => patternAllowed value && patternFieldsAllowed rest

private def patternItemsAllowed : List Json → Bool
  | [] => true
  | value :: rest => patternAllowed value && patternItemsAllowed rest
end

/-- Validate the supported wire grammar at registration, with the consuming
component's index sets already in scope. -/
def validateRule (indexSets : List String) (rule : Rule) : Except String Unit := do
  if !decide rule.params.Nodup || rule.params.any String.isEmpty then
    throw "operator_invalid_definition"
  if let some pattern := rule.pattern then
    match pattern with
    | .obj _ | .str _ | .num _ | .bool _ => pure ()
    | _ => throw "unsupported_rewrite_pattern"
    if !patternAllowed pattern then throw "operator_invalid_definition"
  let constraints ← readConstraints rule.params rule.constraints
  if constraints.any (fun (_, axes) => axes.any fun axis => !indexSets.contains axis) then
    throw "operator_constraint_unknown_index_set"

private def whereSatisfied (constraints : ShapeEnv) (found : Matched) : Bool :=
  constraints.all fun (param, required) => (found.lookup param >>= (·.shape)) == some required

/-- Eligibility is a partial structural match followed by the static shape
checks. The engine supplies missing parameters and writes the reference. -/
def eligibleWithTime (independent : String) (shapes : ShapeEnv) (instanceArgs : InstanceEnv := []) : MatchRule :=
  fun shadowed rule target => do
    if let .obj fields := target then guard (!isReference fields)
    guard (!rule.referenceOnly)
    let ctx : MatchContext := ⟨rule.params, shapes, instanceArgs, shadowed, independent⟩
    let found ← match rule.pattern with
      | some pattern => matchPattern ctx true [] pattern target []
      | none => match target with
        | .obj fields => matchesCall ctx rule fields
        | _ => none
    let constraints ← (readConstraints rule.params rule.constraints).toOption
    guard (whereSatisfied constraints found)
    return rule.params.filterMap fun param => (found.lookup param).map fun result => (param, result.capture)

def eligible (shapes : ShapeEnv) (instanceArgs : InstanceEnv := []) : MatchRule :=
  eligibleWithTime "t" shapes instanceArgs

/-- A reference at the current node is a boundary for every rewrite rule. -/
theorem eligible_reference_root (independent : String) (shapes : ShapeEnv) (instanceArgs : InstanceEnv)
    (shadowed : List String) (rule : Rule) (fields : List (String × Json)) :
    eligibleWithTime independent shapes instanceArgs shadowed rule
      (.obj (("op", .str "apply_operator") :: fields)) = none := by rfl

private def call (op : String) (args : List Json) : Json :=
  .obj [("op", .str op), ("args", .arr args)]

private def repeated : Rule :=
  { name := "repeated", params := ["p"], body := .str "p",
    pattern := some (call "+" [.str "p", .str "p"]) }

example : (eligible [] [] [] repeated (call "+" [.num (.int 2), .num (.int 3)])).isNone = true := by decide +kernel

example :
    let target := call "+" [.str "u", .str "u"]
    (eligible [] [] [] repeated target).isSome &&
      (eligible [] [] [] { repeated with referenceOnly := true } target).isNone = true := by decide +kernel

example :
    let one := call "f" [.str "u"]
    let two := .obj [("args", .arr [.str "u"]), ("op", .str "f")]
    ((eligible [] [] [] repeated (call "+" [one, two])).bind fun bindings =>
        (bindings.lookup "p").bind Capture.source) = some ["args", "0"] := by decide +kernel

private def constrain (param : String) (shape : List String) : Json :=
  .obj [(param, .obj [("shape", .arr (shape.map Json.str))])]

private def gridRule : Rule :=
  { name := "grid", params := ["p"], body := .str "p", pattern := some (call "grad" [.str "p"]),
    constraints := some (constrain "p" ["cell", "lev"]) }

example :
    (eligible [("u", ["cell", "lev"])] [] [] gridRule (call "grad" [.str "u"])).isSome = true := by decide +kernel

example :
    (eligible [("u", ["lev", "cell"])] [] [] gridRule (call "grad" [.str "u"])).isNone = true := by decide +kernel

example :
    (eligible [("u", ["cell", "lev"])] [] ["u"] gridRule (call "grad" [.str "u"])).isNone = true := by decide +kernel

example :
    let rule := { gridRule with pattern := some (.obj [("wrt", .str "p")]) }
    let node := .obj [("op", .str "partial"), ("args", .arr [.str "u"]), ("wrt", .str "u")]
    (eligible [("u", ["cell", "lev"])] [] [] rule node).isNone = true := by decide +kernel

example :
    let rule := { gridRule with body := .str "p", pattern := some (.obj [("args", .arr [.str "p"]),
      ("wrt", .str "x"), ("dim", .str "d")]), params := ["p", "d"] }
    let view : InstanceEnv := [("operand", { shape := some ["cell", "lev"] }),
      ("axis", { literal := some (.str "x") })]
    let node := .obj [("op", .str "partial"), ("args", .arr [.str "operand"]),
      ("wrt", .str "axis"), ("dim", .str "axis")]
    ((eligible [] view [] rule node).any fun bindings =>
      (bindings.lookup "d").any fun binding => sameValue binding.value (.str "axis")) = true := by decide +kernel

example :
    let rule := { gridRule with pattern := some (.str "u"), constraints := none }
    (eligible [("u", ["cell"])] [("u", { literal := some (.str "u") })] [] rule (.str "u")).isNone = true := by decide +kernel

example :
    let rule := { gridRule with pattern := some (.str "p"), constraints := none }
    (eligible [] [("u", {})] [] rule (.str "u")).isSome = true := by decide +kernel

example :
    let rule := { gridRule with pattern := some (call "partial" [.str "p"]), constraints := none }
    let target := .obj [("op", .str "D"), ("args", .arr [.str "u"]), ("wrt", .str "axis")]
    let spatial : InstanceEnv := [("axis", { literal := some (.str "x") })]
    let temporal : InstanceEnv := [("axis", { literal := some (.str "t") })]
    (eligible [] spatial [] rule target).isSome && (eligible [] temporal [] rule target).isNone = true := by decide +kernel

example :
    let rule := { gridRule with pattern := some (call "f" [call "apply_operator" []]) }
    validateRule ["cell", "lev"] rule = .error "operator_invalid_definition" := by decide +kernel

example : validateRule ["cell"] gridRule = .error "operator_constraint_unknown_index_set" := by decide +kernel

end Esm.Rewrite
