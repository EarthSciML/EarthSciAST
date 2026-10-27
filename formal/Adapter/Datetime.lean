import Lean.Data.Json
import Esm.Closed.Datetime
import Esm.Closed.Datetime.FloatImpl

/-! `esm-lean datetime <expected.json>`: evaluate every scenario of a
`tests/closed_functions/datetime/*/expected.json` fixture.

Each input is the JSON decimal rounded to the nearest binary64 (`Esm.F64.rn`
at `ℚ`, the same double a binding's JSON parser produces). Integer outputs are
the exact model (`IntFn.eval`, ruling Q-3) on that double's exact value;
`julian_day` is the binary64 evaluation §9.2 pins (`fJulianDay`, ruling Q-99)
in the `Esm.F64` model at `ℚ`, printed as the exact decimal of the double.
Every function reports `closed_function_overflow` when the year of `t` is
outside Int32 (ruling Q-101) and for a non-finite `t` (ruling Q-100).

Output (stdout):

```json
{"function": "datetime.year",
 "results": [{"name": "epoch", "value": 1970},
             {"name": "int32_year_max_plus_one", "error": "closed_function_overflow"}]}
```

Scenarios are read from both `scenarios` and `error_scenarios`. A non-finite
input (`"NaN"`, `"Inf"`, `"-Inf"`, `"Infinity"`, `"-Infinity"`, or a decimal
beyond the largest double) is `Time.nan`/`posInf`/`negInf` and evaluates
through `IntFn.evalTime` / `julianDayEvalTime`.

Diagnostics on stderr, never in the result: a disagreement between the
`Esm.F64` model and Lean's `Float` (the differential test), a julian_day more
than 1 ulp from its exact value, and an integer output where the binary64
floor-divmod pipeline differs from the exact model.
-/

namespace Adapter.Datetime

open Lean Esm.Closed.Datetime

/-- An input value: a finite double (as an exact rational, and as the `Float`
Lean's JSON parser gives), or non-finite. -/
inductive Input where
  | finite (q : ℚ) (f : Float)
  | nonfinite (t : Time ℚ)

def parseInput (j : Json) : Except String Input :=
  match j with
  | .num n =>
    let q : ℚ := (n.mantissa : ℚ) / (10 : ℚ) ^ n.exponent
    let t := Esm.F64.rn q
    if |t| ≤ Esm.F64.maxFinite then .ok (.finite t n.toFloat)
    else .ok (.nonfinite (if 0 < t then .posInf else .negInf))
  | .str "NaN" => .ok (.nonfinite .nan)
  | .str "Inf" | .str "Infinity" => .ok (.nonfinite .posInf)
  | .str "-Inf" | .str "-Infinity" => .ok (.nonfinite .negInf)
  | _ => .error s!"unsupported input {j.compress}"

/-- The exact decimal of a dyadic rational (`num / 2^k = num · 5^k / 10^k`). -/
def dyadicToJson (q : ℚ) : Json :=
  let k := Nat.log2 q.den
  if 2 ^ k == q.den then .num ⟨q.num * 5 ^ k, k⟩ else .str s!"{q}"

def intFnOf : String → Option IntFn
  | "datetime.year" => some .year
  | "datetime.month" => some .month
  | "datetime.day" => some .day
  | "datetime.hour" => some .hour
  | "datetime.minute" => some .minute
  | "datetime.second" => some .second
  | "datetime.day_of_year" => some .dayOfYear
  | "datetime.is_leap_year" => some .isLeapYear
  | _ => none

/-- The integer the binary64 floor-divmod pipeline would give (`fDayNumber`,
`fSecondOfDay` at `ℚ`), for the stderr diagnostic. -/
def pipelineInt (f : IntFn) (t : ℚ) : ℤ :=
  let d := fDayNumber t
  let s := fSecondOfDay t
  let c := civilFromDays d
  match f with
  | .year => c.year | .month => c.month | .day => c.day
  | .hour => s / 3600 | .minute => s % 3600 / 60 | .second => s % 60
  | .dayOfYear => dayOfYearOfDays d
  | .isLeapYear => if Esm.Closed.Datetime.isLeapYear c.year then 1 else 0

def evalScenario (fn : String) (name : String) (inp : Input) : IO Json := do
  let res (fields : List (String × Json)) : Json := Json.mkObj (("name", Json.str name) :: fields)
  let overflow := res [("error", "closed_function_overflow")]
  match inp with
  | .nonfinite x =>
    if fn == "datetime.julian_day" then
      match julianDayEvalTime x with
      | .overflow => return overflow
      | .ok _ => throw (IO.userError s!"{name}: a non-finite t gave a value")
    else
      match intFnOf fn with
      | none => throw (IO.userError s!"unknown datetime function {fn}")
      | some f =>
        match f.evalTime x with
        | .overflow => return overflow
        | .ok _ => throw (IO.userError s!"{name}: a non-finite t gave a value")
  | .finite t tf =>
    if FloatImpl.toRat tf != some t then
      IO.eprintln s!"{name}: Lean's Float parse {tf} differs from Esm.F64.rn of the decimal"
    if fn == "datetime.julian_day" then
      if !(decide (YearInInt32 t)) then return overflow
      let j : ℚ := fJulianDay t
      match FloatImpl.julianDay tf >>= FloatImpl.toRat with
      | some jf =>
        if jf != j then
          IO.eprintln s!"{name}: Lean Float julian_day {jf} differs from the Esm.F64 model {j}"
      | none => IO.eprintln s!"{name}: Lean Float julian_day is not finite"
      let exact : ℚ := julianDay t
      if |j - exact| > Esm.F64.ulp exact then
        IO.eprintln s!"{name}: julian_day {j} is more than 1 ulp from the exact {exact}"
      return res [("value", dyadicToJson j)]
    else
      match intFnOf fn with
      | none => throw (IO.userError s!"unknown datetime function {fn}")
      | some f =>
        let p := pipelineInt f t
        if p != f.exact t then
          IO.eprintln s!"{name}: the binary64 floor-divmod pipeline gives {p}, the exact model {f.exact t}"
        match f.eval t with
        | .ok v => return res [("value", Json.num ⟨v, 0⟩)]
        | .overflow => return overflow

def run (path : String) : IO Json := do
  let text ← IO.FS.readFile path
  let j ← IO.ofExcept (Json.parse text)
  let fn ← IO.ofExcept (j.getObjValAs? String "function")
  let scen := (j.getObjValAs? (Array Json) "scenarios").toOption.getD #[]
  let errs := (j.getObjValAs? (Array Json) "error_scenarios").toOption.getD #[]
  let mut out := #[]
  for s in scen ++ errs do
    let name ← IO.ofExcept (s.getObjValAs? String "name")
    let inputs ← IO.ofExcept (s.getObjValAs? (Array Json) "inputs")
    if inputs.size != 1 then
      out := out.push (Json.mkObj [("name", name), ("error", "closed_function_arity")])
    else
      let inp ← IO.ofExcept (parseInput inputs[0]!)
      out := out.push (← evalScenario fn name inp)
  return Json.mkObj [("function", fn), ("results", Json.arr out)]

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    try
      IO.println (← run path).compress
      return 0
    catch e =>
      IO.eprintln s!"esm-lean datetime: {e}"
      return 1
  | _ =>
    IO.eprintln "usage: esm-lean datetime <expected.json>"
    return 2

end Adapter.Datetime
