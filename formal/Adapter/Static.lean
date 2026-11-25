import Adapter.Templates
import Esm.Units.Grammar

/-! `esm-lean static-assertions <document.esm> <model>` reads a JSON array of
`{test_id, assertion_idx}` requests on stdin, and returns the values in that
order as binary64 bit patterns. Each value comes from `Esm.Expr.eval` on the
model's parsed equations at the assertion's time and parameter overrides.
This covers binary64 scalar parameters and observations whose values require
no solve or angle-unit conversion. -/

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

structure Model where
  name : String
  independent : String
  parameters : List (String × Json)
  equations : List (String × Except String Ast)
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
  let vars ← (← component.getObjVal? "variables").getObj?
  let mut parameters := []
  for (name, decl) in vars.toArray do
    if (decl.getObjValD "shape").getArr?.toOption.any (fun shape => !shape.isEmpty) then
      unsupported s!"shaped variable {name}"
    checkPrecision s!"variable {name}" decl
    checkAngleUnit s!"variable {name}" decl
    if (decl.getObjValAs? String "type").toOption == some "parameter" then
      if (decl.getObjVal? "update").isOk then unsupported s!"parameter {name} has an update"
      parameters := (name, decl.getObjValD "default") :: parameters
  let mut equations := []
  for eq in (← (← component.getObjVal? "equations").getArr?) do
    if let .ok name := eq.getObjValAs? String "lhs" then
      if equations.any (fun e => e.1 == name) then throw s!"multiple equations for {name}"
      unless ((← (Json.obj vars).getObjVal? name).getObjValAs? String "type").toOption == some "unknown" do
        throw s!"{name} is not a declared unknown"
      let rhs ← eq.getObjVal? "rhs"
      checkConstantUnits s!"equation {name}" rhs
      equations := (name, Templates.astOf rhs) :: equations
  return { name := modelName, independent, parameters, equations := equations.reverse }

private def environment (model : Model) (atTime : Float) (overrides : Json) :
    Except String (Env Float) := do
  let overrides ← if overrides.isNull then pure [] else (·.toArray.toList) <$> overrides.getObj?
  let mut resolved := []
  let modelPrefix := model.name ++ "."
  for (key, value) in overrides do
    let name := if (model.parameters.lookup key).isNone && key.startsWith modelPrefix then
      String.ofList (key.toList.drop modelPrefix.length) else key
    unless (model.parameters.lookup name).isSome do throw s!"unknown parameter override {key}"
    if (resolved.lookup name).isSome then throw s!"duplicate parameter override for {name}"
    resolved := (name, value) :: resolved
  let mut env : Env Float := [(model.independent, .num atTime)]
  for (name, defaultValue) in model.parameters do
    let value := (resolved.lookup name).getD defaultValue
    unless value.isNull do env := (name, .num (← number value)) :: env
  return env

private def observed (ast : Except String Ast) (env : Env Float) : Except String (Val Float) := do
  match Esm.Expr.eval (← ast) env with
  | .ok value => return value
  | .error (.unsupported reason) => unsupported reason
  | .error err => throw (Templates.errorString (.eval err))

/-- Evaluate a scalar at a supplied time. Definitions with dependencies later
in the document become available on subsequent passes. A failed equation never
supplies a value, and a state with a differential equation never enters `env`. -/
def Model.value (model : Model) (name : String) (atTime : Float) (overrides : Json) :
    Except String Float := do
  let mut env ← environment model atTime overrides
  let mut pending := model.equations
  let mut lastError := ""
  for _ in [:model.equations.length + 1] do
    let mut next := []
    for (lhs, rhs) in pending do
      match observed rhs env with
      | .ok value => env := (lhs, value) :: env
      | .error err =>
        if lhs == name then lastError := err
        next := (lhs, rhs) :: next
    if let some (.num n) := env.lookup name then return n
    if (env.lookup name).isSome then unsupported s!"{name} does not have a scalar value"
    if next.length == pending.length then break
    pending := next.reverse
  if lastError.isEmpty then unsupported s!"{name} has no static scalar definition"
  else throw lastError

private def evalRequest (model : Model) (tests : Array Json) (request : Json) : Except String Json := do
  let testId ← request.getObjValAs? String "test_id"
  let idx ← request.getObjValAs? Nat "assertion_idx"
  let some test := tests.find? (fun test => (test.getObjValAs? String "id").toOption == some testId)
    | throw s!"unknown test {testId}"
  let assertions ← (← test.getObjVal? "assertions").getArr?
  let some assertion := if idx == 0 then none else assertions[idx - 1]?
    | throw s!"unknown assertion {testId}#{idx}"
  for field in ["coords", "reduce"] do
    if (assertion.getObjVal? field).isOk then unsupported s!"{testId}#{idx} uses {field}"
  let name ← assertion.getObjValAs? String "variable"
  let atTime ← number (← assertion.getObjVal? "time")
  let value ← model.value name atTime (test.getObjValD "parameter_overrides")
  return .str (toString value.toBits)

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
