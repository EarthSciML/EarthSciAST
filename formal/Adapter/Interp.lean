import Lean.Data.Json
import Esm.Closed.Interp

/-! `esm-lean interp <expected.json>`: interp.* closed functions
(tests/closed_functions/interp/*/expected.json).

Reads the fixture's positional `inputs` for every `scenarios` and
`error_scenarios` entry, runs the model's load-time validation and then the
evaluation — the generic `Esm.Closed` definitions instantiated at `Float`, the
same code the exact model's theorems are about — and prints

```json
{"function": "interp.linear",
 "results": [{"name": "...", "value": 15.0, "bits": "4624633867356078080"},
             {"name": "...", "value": "NaN", "bits": "..."},
             {"name": "...", "error": "interp_nan_in_axis"}]}
```

`value` is a JSON number (or the string `"NaN"`); `bits` is the IEEE-754
bit pattern as a decimal string, for exact comparison. Exit status 0 on a
well-formed fixture, 2 on a usage or parse error. -/

namespace Adapter.Interp

open Lean Esm.Closed

def floatOf (j : Json) : Except String Float :=
  match j with
  | .num n => .ok n.toFloat
  | .str "NaN" => .ok ((0.0 : Float) / 0.0)
  | .str "Infinity" | .str "Inf" => .ok ((1.0 : Float) / 0.0)
  | .str "-Infinity" | .str "-Inf" => .ok ((-1.0 : Float) / 0.0)
  | _ => .error s!"expected a number, got {j.compress}"

def vecOf (j : Json) : Except String (List Float) := do
  let a ← j.getArr?
  a.toList.mapM floatOf

def matOf (j : Json) : Except String (List (List Float)) := do
  let a ← j.getArr?
  a.toList.mapM vecOf

/-- How §9.2's argument contract sees a fixture value: a scalar, a rank-1 or
rank-2 array, or anything else. (The fixtures pass values, so a non-`const`
argument — a variable reference — cannot occur here; a wrong-rank one can, and
is `interp_table_not_const` / `interp_axis_not_const`, ruling Q-108.) The
array arguments go through the model's load-time check exactly as written. -/
def argOf (j : Json) : Arg Float :=
  match floatOf j with
  | .ok v => .const0 v
  | .error _ => match vecOf j with
    | .ok v => .const1 v
    | .error _ => match matOf j with
      | .ok m => .const2 m
      | .error _ => .constN

def floatJson (x : Float) : Json :=
  let v : Json := if x.isNaN then .str "NaN"
    else match JsonNumber.fromFloat? x with
      | .inr n => .num n
      | .inl s => .str s
  Json.mkObj [("value", v), ("bits", .str (toString x.toBits))]

/-- One scenario: validate, then evaluate. -/
def runOne (fn : String) (inputs : Array Json) : Except String (Except Code Json) := do
  match fn, inputs.toList with
  | "interp.searchsorted", [x, xs] => do
    let x ← floatOf x
    return (do
      let xs ← validateSearchsorted (argOf xs)
      return Json.mkObj [("value", (searchsorted x xs : Nat))])
  | "interp.linear", [t, ax, x] => do
    let x ← floatOf x
    return (do
      let (t, ax) ← validateLinear (argOf t) (argOf ax)
      return floatJson (linear t ax x))
  | "interp.bilinear", [T, ax, ay, x, y] => do
    let x ← floatOf x
    let y ← floatOf y
    return (do
      let (T, ax, ay) ← validateBilinear (argOf T) (argOf ax) (argOf ay)
      return floatJson (bilinear T ax ay x y))
  | _, _ => throw s!"unsupported function/arity: {fn} with {inputs.size} inputs"

def runFixture (j : Json) : Except String Json := do
  let fn ← j.getObjValAs? String "function"
  let scen := (j.getObjValD "scenarios").getArr?.toOption.getD #[]
  let errs := (j.getObjValD "error_scenarios").getArr?.toOption.getD #[]
  let mut out : Array Json := #[]
  for s in scen ++ errs do
    let name ← s.getObjValAs? String "name"
    let inputs ← (s.getObjValD "inputs").getArr?
    let r ← runOne fn inputs
    match r with
    | .ok v => out := out.push (v.mergeObj (Json.mkObj [("name", name)]))
    | .error c => out := out.push (Json.mkObj [("name", name), ("error", c)])
  return Json.mkObj [("function", fn), ("results", Json.arr out)]

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let txt ← IO.FS.readFile path
    match Json.parse txt >>= runFixture with
    | .ok j => IO.println j.compress; return 0
    | .error e => IO.eprintln s!"esm-lean interp: {e}"; return 2
  | _ => IO.eprintln "usage: esm-lean interp <expected.json>"; return 2

end Adapter.Interp
