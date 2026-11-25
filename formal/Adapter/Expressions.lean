import Adapter.Doc

/-! `esm-lean expressions <fixture.json> …`: the shared property-corpus driver.

A fixture is a bare §4.1 expression, with no document scope in which to resolve
operators or run legacy document rewrites. Decode to the lossless document JSON
tree, check expression positions, and emit that tree with the canonical number
writer (CONFORMANCE §5.5.3.1). Operator fields and operand order are preserved.
-/

namespace Adapter.Expressions

open Esm.Document

/-- Check the wire grammar without evaluating the expression or interpreting its
operator-specific descriptors. This includes expression slots beside `args`,
while metadata such as `attrs` stays ordinary JSON. -/
private partial def checkExpr : Json → Except String Unit
  | .num n => unless n.wfb do throw "number is outside the canonical form"
  | .str _ => pure ()
  | .obj fields => do
    let some (.str op) := Math.look "op" fields | throw "expected string op"
    unless Math.opOK op || op == "δ" || op == "∂" do
      throw s!"invalid operator name {op}"
    unless !(Math.removedOps.contains op) do throw s!"removed operator {op}"
    let some (.arr _) := Math.look "args" fields | throw "expected array args"
    for (key, value) in fields do
      match key with
      | "args" | "values" =>
        let .arr values := value | throw s!"expected array {key}"
        values.forM checkExpr
      | "expr" | "filter" | "key" | "lower" | "upper" => checkExpr value
      | "bindings" =>
        let .obj bindings := value | throw "expected object bindings"
        bindings.forM (fun (_, expr) => checkExpr expr)
      | _ => unless value.wfb do throw s!"invalid JSON in field {key}"
  | _ => throw "expected a number, a reference string, or an operator node"

private def result (path : String) : IO Json := do
  let outcome ← try
    let expr ← Doc.readDoc path
    pure (checkExpr expr |>.map fun () => expr)
  catch error => pure (.error error.toString)
  return match outcome with
  | .ok expr => .obj [("ok", .bool true), ("value", expr)]
  | .error error => .obj [("error", .str error), ("ok", .bool false)]

def main (paths : List String) : IO UInt32 := do
  if paths.isEmpty then
    IO.eprintln "usage: esm-lean expressions <fixture.json> …"
    return 2
  let entries ← paths.mapM fun path => do
    let name := (System.FilePath.mk path).fileName.getD path
    return (name, ← result path)
  IO.println (Doc.render (.obj entries))
  return 0

end Adapter.Expressions
