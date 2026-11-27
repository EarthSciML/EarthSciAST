import Adapter.Templates

/-! Build-time `distinct` producers used by the static document adapter. -/

namespace Adapter.ValueInvention

open Lean Esm.Expr

structure DerivedAxis where
  name : String
  producer : String
  memberFactor : Option String
  deriving Inhabited

structure Plan where
  sets : Json
  declarations : Json
  axes : List DerivedAxis
  producers : List (String × Json)
  deriving Inhabited

def isProducer (expr : Json) : Bool :=
  (expr.getObjValAs? String "op").toOption == some "faq" &&
    (expr.getObjValAs? Bool "distinct").toOption == some true

def read (sets declarations : Json) (producers : List Json) : Except String Plan := do
  let entries ← if sets.isNull then pure [] else (·.toArray.toList) <$> sets.getObj?
  let axes ← entries.filterMapM fun (name, decl) => do
    unless (decl.getObjValAs? String "kind").toOption == some "derived" do return none
    let producer ← decl.getObjValAs? String "from_faq"
    return some { name, producer, memberFactor := (decl.getObjValAs? String "member_factor").toOption }
  let mut pending := []
  for expr in producers do
    let some id := (expr.getObjValAs? String "id").toOption | continue
    if (pending.lookup id).isSome then throw s!"duplicate distinct producer id {id}"
    if axes.any (·.producer == id) then pending := (id, expr) :: pending
  return { sets, declarations, axes, producers := pending.reverse }

private def couldNotMaterialize (plan : Plan) (id detail : String) : String :=
  let axes := (plan.axes.filter (·.producer == id)).map (·.name)
  s!"derived_index_set_unmaterialized: {axes}, producer {id}: {detail}"

/-- The produced axes and bindings augment the ordinary evaluation environment.
`data` contains only known build-time factors, never the requesting assertion's
time or a differential state. A later producer can read a prior producer's
extent and member factor. -/
def Plan.materialize (plan : Plan) (data : Env Float) (continuous : List String) :
    Except String (List (String × Nat) × Env Float) := do
  let mut pending := plan.producers
  let mut sizes := []
  let mut bindings : Env Float := []
  for _ in [:pending.length] do
    let mut waiting := []
    for (id, expr) in pending do
      match Templates.materialize [] (bindings ++ data) plan.declarations plan.sets expr with
      | .error (.skip reason) => throw s!"unsupported_construct: distinct producer {id}: {reason}"
      | .error (.error reason) => throw reason
      | .error (.missing name) =>
        if continuous.contains name then throw s!"relational_node_in_continuous: {id} reads {name}"
        waiting := (id, expr, name) :: waiting
      | .ok keys =>
        for axis in plan.axes.filter (·.producer == id) do
          sizes := (axis.name, keys.length) :: sizes
          bindings := (setKey axis.name, .num (Float.ofNat keys.length)) :: bindings
          if let some factor := axis.memberFactor then bindings := (factor, .arr1 keys) :: bindings
    if waiting.isEmpty then break
    if waiting.length == pending.length then
      if let some (id, _, name) := waiting.getLast? then
        throw (couldNotMaterialize plan id s!"no build-time factor {name}")
    pending := waiting.reverse.map (fun (id, expr, _) => (id, expr))
  return (sizes, bindings)

end Adapter.ValueInvention
