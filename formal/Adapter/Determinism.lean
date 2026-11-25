import Esm.Determinism
import Lean.Data.Json

/-! The determinism runner supplies relational producer inputs directly. The
adapter translates the manifest's payloads to the model's exact relational
operators and emits their results and ranks. -/

namespace Adapter.Determinism

open Esm.Determinism Lean

private def pairOf {α β : Type} (getA : Json → Except String α)
    (getB : Json → Except String β) (json : Json) : Except String (α × β) := do
  match (← json.getArr?).toList with
  | [a, b] => return (← getA a, ← getB b)
  | _ => throw "expected a tuple with two fields"

private def edgesOfFace (face : List Int) : List (Int × Int) :=
  match face with
  | [] => []
  | first :: rest => face.zip (rest ++ [first])

private def edgeRows (payload : Json) : Except String (List (Int × Int)) := do
  match payload.getObjVal? "faces" with
  | .ok faces =>
    let vertices ← (← faces.getArr?).toList.mapM fun face => do
      (← face.getArr?).toList.mapM Json.getInt?
    return vertices.flatMap edgesOfFace
  | .error _ =>
    let tuples ← payload.getObjValAs? (Array Json) "tuples"
    tuples.toList.mapM (pairOf Json.getInt? Json.getInt?)

private def ranksOf {α : Type} [DecidableEq α] (keys : List α) : List Nat :=
  keys.attach.map fun key => (denseRank keys key).val

private def result (rows : List Json) (ranks : List Nat) : List (String × Json) :=
  let indexSet := Json.arr rows.toArray
  [("index_set", indexSet), ("serialized", toJson indexSet.compress),
    ("dense_ids_canonical", toJson ranks)]

private def runPayload (fixture payload : Json) : Except String (List (String × Json)) := do
  match ← fixture.getObjValAs? String "primitive" with
  | "skolem_distinct_rank" =>
    let rows ← edgeRows payload
    let keys ← match ← fixture.getObjValAs? String "skolem" with
      | "directed" => pure rows
      | "undirected" => pure (rows.map fun (a, b) => edgeEndpoints a b)
      | mode => throw s!"unknown edge orientation {mode}"
    let lexKeys : List (Int ×ₗ Int) := keys.map toLex
    let ordered := distinct lexKeys
    let indexSet := ordered.map fun key => toJson [(ofLex key).1, (ofLex key).2]
    return result indexSet (ranksOf ordered)
  | "group_by_sum" =>
    let raw ← payload.getObjValAs? (Array Json) "rows"
    let rows ← raw.toList.mapM (pairOf Json.getStr? Json.getInt?)
    let groups := groupBySum rows
    let indexSet := groups.map fun (key, value) => Json.arr #[toJson key, toJson value]
    return result indexSet (ranksOf (groups.map Prod.fst))
  | primitive => throw s!"unknown determinism primitive {primitive}"

private def runFixture (fixture : Json) : Except String (String × Json) := do
  let id ← fixture.getObjValAs? String "id"
  let inputs ← fixture.getObjVal? "inputs"
  let canonical ← runPayload fixture (← inputs.getObjVal? "canonical")
  let variants ← match inputs.getObjVal? "variants" with
    | .error _ => pure []
    | .ok variants => (← variants.getObj?).toList.mapM fun (name, payload) => do
      let row ← runPayload fixture payload
      return (name, Json.mkObj row)
  return (id, Json.mkObj (canonical ++ [("variants", Json.mkObj variants)]))

private def runManifest (manifest : Json) : Except String Json := do
  let fixtures ← manifest.getObjValAs? (Array Json) "fixtures"
  let results ← fixtures.toList.mapM runFixture
  return Json.mkObj [("binding", toJson "lean"), ("fixtures", Json.mkObj results)]

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--manifest", manifest, "--output", output] =>
    let source ← IO.FS.readFile manifest
    match Json.parse source >>= runManifest with
    | .ok json =>
      IO.FS.writeFile output (json.compress ++ "\n")
      return 0
    | .error error =>
      IO.eprintln s!"esm-lean determinism: {error}"
      return 2
  | _ =>
    IO.eprintln "usage: esm-lean determinism --manifest <manifest.json> --output <result.json>"
    return 2

end Adapter.Determinism
