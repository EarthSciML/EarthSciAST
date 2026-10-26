import Lean.Data.Json
import Esm.Units.Exec

/-! `esm-lean units <unit_verdicts.json>`: resolve every unit string of a
`tests/conformance/unit_registry` golden with the model (esm-spec §4.8.1–4.8.2).

Output (stdout, one JSON object): for each of the golden's lists, one record per
entry.

* `accept`: `resolved`, `canonical_resolved`, `dim` and `canonical_dim` (axis ↦
  exponent string), `dim_equal`, `scale_exact` (the exact ratio of the entry's
  scale to the canonical's, in the golden's `p/q*pi^k` form), `factor` (that
  ratio as a double, given as its IEEE-754 bit pattern `factor_bits`
  so no decimal printing intervenes), `error`.
* `reject`, `reject_scaling_factor`: `resolved` and `error` (the diagnostic).

The comparator `scripts/run-unit-registry-lean.py` checks these against the
golden's contract. -/

namespace Adapter.Units

open Lean Esm.Units

def dimJson (d : Dim) : Json :=
  Json.mkObj ((Dim.entries d).map fun (k, q) => (k, Json.str (ratStr q)))

def errJson (r : Except Err U) : Json :=
  match r with
  | .ok _ => Json.null
  | .error e => Json.str e.message

def resolvedJson (r : Except Err U) : Json :=
  match r with
  | .ok _ => Json.bool true
  | .error _ => Json.bool false

def acceptRecord (units canonical : String) : Json :=
  let r := resolve units
  let c := resolve canonical
  let base := [("units", Json.str units), ("canonical", Json.str canonical),
    ("resolved", resolvedJson r), ("canonical_resolved", resolvedJson c),
    ("error", match r with | .ok _ => errJson c | .error _ => errJson r)]
  match r, c with
  | .ok u, .ok v =>
    let ratio := U.div u v
    Json.mkObj (base ++ [("dim", dimJson u.dim), ("canonical_dim", dimJson v.dim),
      ("dim_equal", Json.bool (decide (u.dim = v.dim))),
      ("scale_exact", Json.str (Scale.exactString ratio.scale)),
      ("factor_bits", Json.str (toString (Scale.toFloat ratio.scale).toBits))])
  | _, _ => Json.mkObj base

def rejectRecord (units : String) : Json :=
  let r := resolve units
  Json.mkObj [("units", Json.str units), ("resolved", resolvedJson r), ("error", errJson r)]

def entries (j : Json) (key : String) : List Json :=
  match j.getObjValAs? (Array Json) key with
  | .ok a => a.toList
  | .error _ => []

def strField (j : Json) (key : String) : String :=
  match j.getObjValAs? String key with
  | .ok s => s
  | .error _ => ""

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let text ← IO.FS.readFile path
    match Json.parse text with
    | .error e => IO.eprintln s!"esm-lean units: {e}"; return 2
    | .ok j =>
      let acc := (entries j "accept").map fun e =>
        acceptRecord (strField e "units") (strField e "canonical")
      let rej := (entries j "reject").map fun e => rejectRecord (strField e "units")
      let rsf := (entries j "reject_scaling_factor").map fun e => rejectRecord (strField e "units")
      IO.println (Json.mkObj [("accept", Json.arr acc.toArray), ("reject", Json.arr rej.toArray),
        ("reject_scaling_factor", Json.arr rsf.toArray)]).pretty
      return 0
  | _ => IO.eprintln "usage: esm-lean units <unit_verdicts.json>"; return 2

end Adapter.Units
