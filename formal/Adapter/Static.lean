import Adapter.Joins
import Adapter.Templates
import Adapter.ValueInvention
import Esm.Units.Grammar

/-! `esm-lean static-assertions <document.esm> <model>` reads a JSON array of
`{test_id, assertion_idx}` requests on stdin, and returns the values in that
order as binary64 bit patterns. Each value comes from `Esm.Expr.eval` on the
model's parsed equations at the assertion's time and parameter overrides.
This covers binary64 scalar and shaped parameters and observations whose
values require no solve or angle-unit conversion. -/

namespace Adapter.Static

open Lean Esm.Expr

private def unsupported {α : Type} (reason : String) : Except String α :=
  .error s!"unsupported_construct: {reason}"

private def number (value : Json) : Except String Float := do
  let n ← value.getNum?
  return Lits.ofDec n.mantissa n.exponent

private def checkPrecision (location : String) (decl : Json) : Except String Unit := do
  if (decl.getObjValAs? String "element_type").toOption == some "Float32" then
    throw s!"float32_unsupported: {location} declares Float32"

private def checkAngleUnit (location : String) (decl : Json) : Except String Unit := do
  if let .ok units := decl.getObjValAs? String "units" then
    if let .ok unit := Esm.Units.resolve units then
      if unit.dim .rad ≠ 0 ∧ unit.scale.exp ≠ Esm.Units.U.one.scale.exp then
        unsupported s!"angle units {units} in {location}"

private partial def checkConstantUnits (location : String) : Json → Except String Unit
  | .obj fields => do
    let node := Json.obj fields
    if (node.getObjValAs? String "op").toOption == some "const" then
      checkAngleUnit location node
    fields.toArray.forM fun (_, child) => checkConstantUnits location child
  | .arr items => items.forM (checkConstantUnits location)
  | _ => pure ()

private def sizedAxes (sets : Json) : List (String × (Nat × Bool)) :=
  (sets.getObj?.toOption.map (·.toArray.toList)).getD [] |>.filterMap fun (name, decl) => do
    match (decl.getObjValAs? String "kind").toOption with
    | some "interval" =>
      let size ← (decl.getObjValAs? Nat "size").toOption
      return (name, size, true)
    | some "categorical" =>
      let members ← (decl.getObjValD "members").getArr?.toOption
      return (name, members.size, false)
    | _ => none

private def dimensions (shape : List String) (sizes : List (String × Nat)) :
    Except String (List Nat) :=
  shape.mapM fun axis => match sizes.lookup axis with
    | some n => pure n
    | none => unsupported s!"axis {axis} has no static extent"

private def evalResult {α : Type} (result : Except EvalError α) : Except String α :=
  match result with
  | .ok value => .ok value
  | .error (.unsupported reason) => unsupported reason
  | .error err => .error (Templates.errorString (.eval err))

private def conformShape (name : String) (shape : Option (List String)) (sizes : List (String × Nat))
    (value : Val Float) :
    Except String (Val Float) := do
  let some shape := shape | return value
  let dims ← dimensions shape sizes
  match value.arrayData with
  | some (actual, _) =>
    unless actual == dims do
      throw s!"array_shape_mismatch: {name} expected {dims}, got {actual}"
    return value
  | none =>
    match value with
    | .num _ | .inf _ =>
      if dims.isEmpty then return value
      return .shaped dims (List.replicate (dims.foldl (· * ·) 1) value)
    | _ => throw s!"array_shape_mismatch: {name} is not rectangular"

private abbrev Shapes := List (String × List String)

private partial def namedOperands (shapes : Shapes) : Ast → List String
  | .var name => (shapes.lookup name).getD []
  | .node op args | .array (.broadcast op) args =>
    if broadcastArity op args.length then args.flatMap (namedOperands shapes) else []
  | _ => []

private def faqScope (shapes : Shapes) (out : List OutputIndex) (ranges : Ranges) : Shapes :=
  let bound := out.filterMap (fun | .symbol name => some name | .singleton => none) ++ ranges.names
  shapes.filter fun (name, _) => !bound.contains name

/-- Put named operands in result-axis order through the spec's equivalent
pointwise FAQ. Whole-array operators give each operand its own axis order. -/
private partial def alignNamed (shapes : Shapes) (targetAxes : Option (List String))
    (ast : Ast) : Except String Ast := do
  let resultAxes := match targetAxes with
    | some axes => axes
    | none => (namedOperands shapes ast).eraseDups
  match ast with
  | .var name =>
    let axes := (shapes.lookup name).getD []
    if axes.isEmpty || axes == resultAxes then return ast
    -- A NUL-prefixed symbol cannot occur in a valid authored ESM identifier.
    let bindings := resultAxes.map (fun axis => (axis, "\x00axis_" ++ axis))
    let subscripts ← axes.mapM fun axis => match bindings.lookup axis with
      | some symbol => pure (Ast.var symbol)
      | none => throw s!"array_shape_mismatch: {name} has extra axis {axis}"
    let out := bindings.map (fun (_, symbol) => OutputIndex.symbol symbol)
    let ranges := bindings.foldr (fun (axis, symbol) rest => Ranges.fromSet symbol axis rest) .nil
    return .faq out "+" ranges (.node "index" (.var name :: subscripts)) []
  | .node op args =>
    let target := if broadcastArity op args.length then some resultAxes else none
    let args ← args.mapM (alignNamed shapes target)
    -- Both surface spellings use the pointwise conditional for static arrays.
    if op == "ifelse" && args.length == 3 then return .array (.broadcast op) args
    return .node op args
  | .array (.broadcast op) args =>
    return .array (.broadcast op) (← args.mapM (alignNamed shapes (some resultAxes)))
  | .array op args =>
    return .array op (← args.mapM (alignNamed shapes none))
  | .faq out red ranges body args =>
    return .faq out red ranges (← alignNamed (faqScope shapes out ranges) none body) args
  | .faqWhere out red ranges filter body args =>
    let localShapes := faqScope shapes out ranges
    return .faqWhere out red ranges (← alignNamed localShapes none filter)
      (← alignNamed localShapes none body) args
  | .faqJoin out red ranges pairs filter body args =>
    let localShapes := faqScope shapes out ranges
    return .faqJoin out red ranges pairs (← alignNamed localShapes none filter)
      (← alignNamed localShapes none body) args
  | _ => pure ast

private def lowerExpression (scope : Joins.Scope) (name : String) (expression : Json) :
    Except String Ast := do
  alignNamed scope.shapes (scope.shapes.lookup name)
    (← Templates.astOf expression (some (Joins.resolve scope)))

private def operation (node : Json) : String :=
  (node.getObjValAs? String "op").toOption.getD ""

private partial def variableHead (node : Json) : Option String := do
  if let .ok name := node.getStr? then return name
  if operation node != "index" then none
  let args ← (node.getObjValD "args").getArr?.toOption
  variableHead (← args[0]?)

private def differentialTarget (lhs : Json) : Option String := do
  let lhs := if operation lhs == "faq" then lhs.getObjValD "expr" else lhs
  if operation lhs != "D" then none
  let args ← (lhs.getObjValD "args").getArr?.toOption
  variableHead (← args[0]?)

private def indexedTarget (node : Json) : Except String (String × List String) := do
  let args ← (← node.getObjVal? "args").getArr?
  let some target := args[0]? | throw "index definition lacks a target"
  let name ← target.getStr?
  let symbols ← args.toList.drop 1 |>.mapM (·.getStr?)
  return (name, symbols)

private def outputSymbols (node : Json) : Except String (List String) := do
  (← (← node.getObjVal? "output_idx").getArr?).toList.mapM (·.getStr?)

/-- Lower a pointwise definition to the array expression it denotes. A bare
`index` takes its range from the RHS FAQ; a shelled LHS can bind a cell RHS. -/
private def staticDefinition (lhs rhs : Json) : Except String (Option (String × Json)) := do
  if let .ok name := lhs.getStr? then return some (name, rhs)
  let wrapped := operation lhs == "faq"
  let target := if wrapped then lhs.getObjValD "expr" else lhs
  if operation target != "index" then return none
  let (name, symbols) ← match indexedTarget target with
    | .ok result => pure result
    | .error message =>
      throw s!"indexed_definition_unsupported_form: {(variableHead target).getD message}"
  let rhsIsArray := operation rhs == "faq" && (outputSymbols rhs).toOption == some symbols
  if !wrapped then
    unless rhsIsArray do throw s!"indexed_definition_unsupported_form: {name}"
    return some (name, rhs)
  unless (← outputSymbols lhs) == symbols do
    unsupported s!"LHS of {name} does not gather in output-index order"
  if rhsIsArray then return some (name, rhs)
  let ranges ← lhs.getObjVal? "ranges"
  return some (name, Json.mkObj [("op", .str "faq"), ("args", .arr #[]),
    ("output_idx", .arr (symbols.toArray.map Json.str)), ("ranges", ranges), ("expr", rhs)])

structure Model where
  name : String
  independent : String
  sizes : List (String × Nat)
  intervalAxes : List String
  indexBindings : Env Float
  shapes : Shapes
  parameters : List (String × Json)
  differentialStates : List String
  equations : List (String × Except String Ast)
  invention : ValueInvention.Plan
  deriving Inhabited

def readModel (doc component : Json) (modelName : String) : Except String Model := do
  for field in ["coupling", "subsystems"] do
    if (doc.getObjVal? field).isOk then unsupported s!"document uses {field}"
  for field in ["events", "operators", "operator_imports", "expression_templates",
      "expression_template_imports", "subsystems"] do
    if (component.getObjVal? field).isOk then unsupported s!"model uses {field}"
  let domain := doc.getObjValD "domain"
  checkPrecision "domain.element_type" domain
  let independent := (domain.getObjValAs? String "independent_variable").toOption.getD "t"
  let sets := (doc.getObjVal? "index_sets").toOption.getD (component.getObjValD "index_sets")
  let axes := sizedAxes sets
  let sizes := axes.map fun (name, size, _) => (name, size)
  let intervalAxes := axes.filterMap fun (name, _, isInterval) => if isInterval then some name else none
  let indexBindings ← Templates.raggedSetBindings sets
  let vars ← (← component.getObjVal? "variables").getObj?
  let mut parameters := []
  let mut shapes := []
  for (name, decl) in vars.toArray do
    if let .ok field := decl.getObjVal? "shape" then
      let shape ← (← field.getArr?).toList.mapM (·.getStr?)
      shapes := (name, shape) :: shapes
    checkPrecision s!"variable {name}" decl
    checkAngleUnit s!"variable {name}" decl
    if (decl.getObjValAs? String "type").toOption == some "parameter" then
      if (decl.getObjVal? "update").isOk then unsupported s!"parameter {name} has an update"
      parameters := (name, decl.getObjValD "default") :: parameters
  let mut equations := []
  let mut producers := []
  let mut differentialStates := []
  for eq in (← (← component.getObjVal? "equations").getArr?) do
    let lhs ← eq.getObjVal? "lhs"
    if let some name := differentialTarget lhs then
      differentialStates := name :: differentialStates
    let rhs ← eq.getObjVal? "rhs"
    if let some (name, expr) ← staticDefinition lhs rhs then
      if equations.any (fun e => e.1 == name) || producers.any (fun e => e.1 == name) then
        throw s!"multiple equations for {name}"
      unless ((← (Json.obj vars).getObjVal? name).getObjValAs? String "type").toOption == some "unknown" do
        throw s!"{name} is not a declared unknown"
      checkConstantUnits s!"equation {name}" expr
      if ValueInvention.isProducer expr then
        producers := (name, expr) :: producers
      else
        equations := (name, expr) :: equations
  let declaredData := parameters.map Prod.fst ++ equations.filterMap fun (name, expr) =>
    if operation expr == "const" then some name else none
  let nonconstant := Joins.nonconstantColumns sets (independent :: differentialStates) equations
  let joinScope : Joins.Scope := ⟨sets, shapes, declaredData, nonconstant⟩
  let loweredEquations := equations.reverse.map fun (name, rhs) =>
    (name, lowerExpression joinScope name rhs)
  let invention ← ValueInvention.read sets (.obj vars) (producers.reverse.map Prod.snd)
  return {
    name := modelName
    independent
    sizes
    intervalAxes
    indexBindings
    shapes
    parameters
    differentialStates
    equations := loweredEquations
    invention }

private def Model.shape (model : Model) (name : String) : List String :=
  (model.shapes.lookup name).getD []

private def environment (model : Model) (atTime : Float) (overrides : Json) :
    Except String (List (String × Nat) × Env Float) := do
  let overrides ← if overrides.isNull then pure [] else (·.toArray.toList) <$> overrides.getObj?
  let mut resolved := []
  let modelPrefix := model.name ++ "."
  for (key, value) in overrides do
    let name := if (model.parameters.lookup key).isNone && key.startsWith modelPrefix then
      String.ofList (key.toList.drop modelPrefix.length) else key
    unless (model.parameters.lookup name).isSome do throw s!"unknown parameter override {key}"
    if (resolved.lookup name).isSome then throw s!"duplicate parameter override for {name}"
    resolved := (name, value) :: resolved
  let parameters ← model.parameters.filterMapM fun (name, defaultValue) => do
    let json := (resolved.lookup name).getD defaultValue
    if json.isNull then return none
    let value ← evalResult (constVal (← Templates.constOf json))
    return some (name, value)
  let indexEnv := model.indexBindings ++
    model.sizes.map (fun (name, size) => (setKey name, .num (Float.ofNat size)))
  let (newSizes, derivedEnv) ← if model.invention.producers.isEmpty then pure ([], []) else do
    let constantArrays := model.equations.filterMap fun (name, rhs) => match rhs with
      | .ok (.const (.arr arr)) => (constVal (.arr arr)).toOption.map (name, ·)
      | _ => none
    let data ← (parameters ++ constantArrays).filterMapM fun (name, value) => do
      let shape := model.shapes.lookup name
      if (dimensions (shape.getD []) model.sizes).isOk then
        return some (name, ← conformShape name shape model.sizes value)
      else return none
    model.invention.materialize (data ++ indexEnv) (model.independent :: model.differentialStates)
  let sizes := newSizes ++ model.sizes
  let parameters ← parameters.mapM fun (name, value) => do
    return (name, ← conformShape name (model.shapes.lookup name) sizes value)
  let mut env : Env Float := (model.independent, .num atTime) :: derivedEnv ++ parameters ++ indexEnv
  -- Shape information can be needed even when an observed's value is never read.
  for (name, axes) in model.shapes do
    if let .ok dims := dimensions axes sizes then
      env := (shapeKey name, .shaped dims []) :: env
  let mut pending := model.equations
  for _ in [:pending.length] do
    let mut next := []
    for (name, rhs) in pending do
      if (env.lookup (shapeKey name)).isNone then
        if let .ok (some dims) := rhs.toOption.map (fun ast => expressionDims ast env)
            |>.getD (.ok none) then
          env := (shapeKey name, .shaped dims []) :: env
        else
          next := (name, rhs) :: next
    if next.isEmpty || next.length == pending.length then break
    pending := next.reverse
  return (sizes, env)

/-- Resolve dependencies only when the AST evaluator reads them, preserving
lazy branches and surfacing a fault in a dependency at the requesting assertion. -/
private partial def resolve (model : Model) (visiting : List String) (env : Env Float)
    (name : String) : Except String (Val Float × Env Float) := do
  if let some value := env.lookup name then return (value, env)
  if model.differentialStates.contains name then
    unsupported s!"requires integrated state {name}"
  if visiting.contains name then throw s!"observed_cycle: {name}"
  let some rhs := model.equations.lookup name | unsupported s!"{name} has no static definition"
  let result := Esm.Expr.eval (← rhs) env
  match result with
  | .error (.unbound dep) =>
    if (env.lookup dep).isNone &&
        ((model.equations.lookup dep).isSome || model.differentialStates.contains dep) then
      let (_, extended) ← resolve model (name :: visiting) env dep
      resolve model visiting extended name
    else
      throw (Templates.errorString (.eval (.unbound dep)))
  | _ =>
    let value ← evalResult result
    let value ← conformShape name (model.shapes.lookup name) model.sizes value
    return (value, (name, value) :: env)

def Model.value (model : Model) (name : String) (atTime : Float) (overrides : Json) :
    Except String (Val Float) := do
  let (sizes, env) ← environment model atTime overrides
  let (value, _) ← resolve {model with sizes} [] env name
  return value

private def scalar (name : String) : Val Float → Except String Float
  | .num value => pure value
  | .inf negative => pure (Float.ofBits (if negative then 0xfff0000000000000 else 0x7ff0000000000000))
  | _ => unsupported s!"{name} does not have a scalar value"

private def localName (model : Model) (name : String) : String :=
  let modelPrefix := model.name ++ "."
  if name.startsWith modelPrefix then String.ofList (name.toList.drop modelPrefix.length) else name

private def assertionTarget (name : String) : Except String (String × List Int) := do
  match name.splitOn "[" with
  | [base] => return (base, [])
  | [base, indices] =>
    let [indices, ""] := indices.splitOn "]" | throw s!"invalid element name {name}"
    let subscripts ← (indices.splitOn ",").mapM fun token =>
      match token.trimAscii.toString.toInt? with
      | some i => pure i
      | none => throw s!"non-integral element subscript in {name}"
    return (base, subscripts)
  | _ => throw s!"invalid element name {name}"

private def coordinateSubscripts (model : Model) (name : String) (coords : Json) :
    Except String (List Int) := do
  let shape := model.shape name
  if shape.isEmpty then throw s!"assertion_rank_mismatch: {name} is not shaped"
  unless shape.all model.intervalAxes.contains do
    unsupported s!"coordinate sampling for {name} requires interval axes"
  let coords ← coords.getObj?
  for (axis, _) in coords.toArray do
    unless shape.contains axis do throw s!"unknown coordinate axis {axis} for {name}"
  let sizes ← dimensions shape model.sizes
  (shape.zip sizes).mapM fun (axis, size) => do
    match coords.get? axis with
    | none =>
      unless size == 1 do throw s!"coordinate {axis} is unpinned for {name}"
      return 1
    | some value =>
      let position ← number value
      let index ← evalResult (asInt (Float.ceil (position - 0.5)))
      unless 1 ≤ index ∧ index ≤ Int.ofNat size do
        throw s!"coordinate {axis} outside 1..{size} for {name}"
      return index

private def reduceField (name op : String) (field : Val Float) : Except String Float := do
  let some (_, cells) := field.arrayData
    | throw s!"assertion_rank_mismatch: {name} is not shaped"
  let values ← cells.mapM (scalar name)
  let first :: rest := values | unsupported s!"{op} on an empty field"
  match op with
  | "min" => pure (rest.foldl fmin first)
  | "max" => pure (rest.foldl fmax first)
  | "mean" | "integral" => pure (values.foldl (· + ·) 0 / Float.ofNat values.length)
  | _ => unsupported s!"assertion reduction {op}"

private def evalRequest (model : Model) (tests : Array Json) (request : Json) : Except String Json := do
  let testId ← request.getObjValAs? String "test_id"
  let idx ← request.getObjValAs? Nat "assertion_idx"
  let some test := tests.find? (fun test => (test.getObjValAs? String "id").toOption == some testId)
    | throw s!"unknown test {testId}"
  let assertions ← (← test.getObjVal? "assertions").getArr?
  let some assertion := if idx == 0 then none else assertions[idx - 1]?
    | throw s!"unknown assertion {testId}#{idx}"
  let (name, elements) ← assertionTarget (← assertion.getObjValAs? String "variable")
  let name := localName model name
  let atTime ← number (← assertion.getObjVal? "time")
  let coords := (assertion.getObjVal? "coords").toOption
  let reduce := (assertion.getObjValAs? String "reduce").toOption
  if coords.isSome && reduce.isSome || !elements.isEmpty && (coords.isSome || reduce.isSome) then
    throw s!"conflicting assertion selectors for {name}"
  if reduce.isSome && (model.shape name).isEmpty then
    throw s!"assertion_rank_mismatch: {name} is not shaped"
  if coords.isNone && reduce.isNone && elements.isEmpty && !(model.shape name).isEmpty then
    throw s!"assertion_rank_mismatch: {name} requires a field or element selector"
  let indices ← match coords with
    | some coords => coordinateSubscripts model name coords
    | none => pure elements
  let value ← model.value name atTime (test.getObjValD "parameter_overrides")
  let result ← match reduce with
    | some op => reduceField name op value
    | none =>
      let cell ← if indices.isEmpty then pure value else evalResult (indexCell value indices)
      scalar name cell
  return .str (toString result.toBits)

private def evaluateRequests (doc : Json) (name : String) (requests : Json) : Except String Json := do
  let component ← (← doc.getObjVal? "models").getObjVal? name
  let model ← readModel doc component name
  let tests ← (← component.getObjVal? "tests").getArr?
  return .arr (← (← requests.getArr?).mapM (evalRequest model tests))

def main : List String → IO UInt32
  | [path, name] => do
    let source ← IO.FS.readFile path
    let input ← (← IO.getStdin).readToEnd
    let result := do evaluateRequests (← Json.parse source) name (← Json.parse input)
    match result with
    | .ok values => IO.println values.compress; return 0
    | .error message => IO.eprintln message; return 1
  | _ => do
    IO.eprintln "usage: esm-lean static-assertions <document.esm> <model>"
    return 2

/-- One request per line, with failures returned in-band so the next request
can still be evaluated. The fixture and request shapes match the file mode. -/
def batch : List String → IO UInt32
  | [name] => do
    let stdin ← IO.getStdin
    let stdout ← IO.getStdout
    repeat
      let line ← stdin.getLine
      if line.isEmpty then break
      let result : Except String Json := do
        let input ← Json.parse line
        evaluateRequests (← input.getObjVal? "document") name (← input.getObjVal? "requests")
      let response := match result with
        | .ok values => Json.mkObj [("values", values)]
        | .error message => Json.mkObj [("error", .str message)]
      stdout.putStrLn response.compress
      stdout.flush
    return 0
  | _ => do
    IO.eprintln "usage: esm-lean static-assertions-jsonl <model>"
    return 2

end Adapter.Static
