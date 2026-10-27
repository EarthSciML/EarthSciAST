import Lean.Data.Json
import Adapter.Interp
import Esm.Closed.Tables.Load

/-! `esm-lean tables <cases.json>`: the §9.5.5 load-time table checks
(tests/conformance/function_tables/load_errors/cases.json).

For every case, builds the table IN MEMORY as an `RTable Float` — the strings
`"NaN"`, `"Inf"` and `"-Inf"` are those binary64 values (ruling Q-109) — and
runs the model's table check `Esm.Closed.Tables.validateRaw`, the generic
definition the exact model's theorems are about (`validateRaw_eq`,
`validateRaw_ladder`), instantiated at `Float`. Prints

```json
{"results": [{"name": "control_valid", "error": null},
             {"name": "axis_pos_inf", "error": "table_axis_nan"}]}
```

The case's `lookup` is not run: every lookup in the ledger is well-formed, and
the lookup order (Q-107) is the exact model's `lookup_check_order`. Exit status
0 on a well-formed ledger, 2 on a usage or parse error. -/

namespace Adapter.Tables

open Lean Esm.Closed Esm.Closed.Tables

/-- A table value; `"Inf"` / `"-Inf"` (the ledger's spelling) as well as
`Adapter.Interp.floatOf`'s spellings. -/
def valOf (j : Json) : Except String Float :=
  match j with
  | .str "Inf" => .ok ((1.0 : Float) / 0.0)
  | .str "-Inf" => .ok ((-1.0 : Float) / 0.0)
  | _ => Adapter.Interp.floatOf j

partial def nestedOf (j : Json) : Except String (RNested Float) :=
  match j with
  | .arr a => do return .node (← a.toList.mapM nestedOf)
  | _ => do return .leaf (← valOf j)

def methodOf : Option String → Except String Method
  | none | some "linear" => .ok .linear
  | some "bilinear" => .ok .bilinear
  | some "nearest" => .ok .nearest
  | some m => .error s!"unknown interpolation {m}"

def tableOf (j : Json) : Except String (RTable Float) := do
  let axes ← (← j.getObjVal? "axes").getArr?
  let axes ← axes.toList.mapM fun a => do
    let name ← a.getObjValAs? String "name"
    let vals ← (← a.getObjVal? "values").getArr?
    return ({ name, values := ← vals.toList.mapM valOf } : RAxis Float)
  let interp ← methodOf (j.getObjValAs? String "interpolation").toOption
  let outputs := (j.getObjValAs? (Array String) "outputs").toOption.map (·.toList)
  let shape := (j.getObjValAs? (Array Nat) "shape").toOption.map (·.toList)
  let oob : OOB := if (j.getObjValAs? String "out_of_bounds").toOption == some "error"
    then .error else .clamp
  return { axes, interpolation := interp, outOfBounds := oob, outputs,
           data := ← nestedOf (← j.getObjVal? "data"), shape }

def runLedger (j : Json) : Except String Json := do
  let cases ← (← j.getObjVal? "cases").getArr?
  let mut out : Array Json := #[]
  for c in cases do
    let name ← c.getObjValAs? String "name"
    let t ← tableOf (← c.getObjVal? "table")
    let err : Json := match validateRaw t with
      | .ok () => .null
      | .error code => .str code
    out := out.push (Json.mkObj [("name", name), ("error", err)])
  return Json.mkObj [("results", Json.arr out)]

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let txt ← IO.FS.readFile path
    match Json.parse txt >>= runLedger with
    | .ok j => IO.println j.compress; return 0
    | .error e => IO.eprintln s!"esm-lean tables: {e}"; return 2
  | _ => IO.eprintln "usage: esm-lean tables <cases.json>"; return 2

end Adapter.Tables
