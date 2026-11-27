import Esm.Expr.Core
import Lean.Data.Json

/-! Document-local resolution of `faq.join.on` (CONFORMANCE §5.5.8). The
adapter resolves the wire names. The expression evaluator owns the gates and
the accumulation order. -/

namespace Adapter.Joins

open Lean Esm.Expr

structure Scope where
  sets : Json
  shapes : List (String × List String)
  declaredData : List String
  nonconstant : List String

private def fields (value : Json) : List (String × Json) :=
  (value.getObj?.toOption.map fun object => object.toArray.toList).getD []

private def strings (value : Json) : List String :=
  (value.getArr?.toOption.getD #[]).toList.filterMap fun item => item.getStr?.toOption

/-- A join key may depend on a constant computed column. Determine which
definitions reach time or state, respecting a FAQ's local index binders. -/
private partial def freeReads (sets : Json) (bound : List String) (expr : Json) : List String :=
  match expr with
  | .str name => if bound.contains name then [] else [name]
  | .obj _ =>
    let ranges := fields (expr.getObjValD "ranges")
    let outputs := strings (expr.getObjValD "output_idx")
    let scope := ranges.map Prod.fst ++ outputs ++ bound
    let args := (expr.getObjValD "args").getArr?.toOption.getD #[]
    let values := (expr.getObjValD "values").getArr?.toOption.getD #[]
    let rangeReads := ranges.flatMap fun (_, range) =>
      if let .ok axis := range.getObjValAs? String "from" then
        let decl := sets.getObjValD axis
        ((decl.getObjValAs? String "offsets").toOption.toList).filter (fun name => !bound.contains name)
      else
        (range.getArr?.toOption.getD #[]).toList.flatMap (freeReads sets bound)
    let clauses := (expr.getObjValD "join").getArr?.toOption.getD #[]
    let keys := clauses.toList.flatMap fun clause =>
      (clause.getObjValD "on").getArr?.toOption.getD #[] |>.toList.flatMap strings
    args.toList.flatMap (freeReads sets scope) ++ values.toList.flatMap (freeReads sets scope) ++
      rangeReads ++ (keys.filter (fun name => !scope.contains name)) ++
      (fields (expr.getObjValD "bindings")).flatMap (fun (_, value) => freeReads sets scope value) ++
      freeReads sets scope (expr.getObjValD "filter") ++ freeReads sets scope (expr.getObjValD "expr")
  | _ => []

def nonconstantColumns (sets : Json) (seeds : List String) (definitions : List (String × Json)) :
    List String := Id.run do
  let reads := definitions.map fun (name, expr) => (name, freeReads sets [] expr)
  let mut current := seeds
  for _ in definitions do
    let fresh := reads.filterMap fun (name, deps) =>
      if !current.contains name && deps.any current.contains then some name else none
    if fresh.isEmpty then break
    current := fresh ++ current
  return current

private abbrev RangesByName := List (String × Json)

private def visitOrder (node : Json) (ranges : RangesByName) : RangesByName :=
  let outputs := (strings (node.getObjValD "output_idx")).filterMap fun name =>
    (ranges.lookup name).map fun range => (name, range)
  outputs ++ ranges.filter (fun range => (outputs.lookup range.1).isNone)

private def source (scope : Scope) (range : Json) : Except String JoinSource := do
  if let .ok _ := range.getArr? then return .position
  let set ← range.getObjValAs? String "from"
  let decl := scope.sets.getObjValD set
  match (decl.getObjValAs? String "kind").toOption with
  | some "interval" => pure .position
  | some "categorical" =>
    let members ← (← decl.getObjVal? "members").getArr?
    let keys ← members.mapM fun member => do
      if let .ok name := member.getStr? then return JoinMember.category name
      let value ← (member.getInt?).mapError (fun _ => s!"invalid_join_key: {set} has a non-integral member")
      unless value.natAbs ≤ 9007199254740992 do
        throw s!"unsupported_construct: categorical integer in {set} exceeds the binary64 exact range"
      return JoinMember.integer value
    pure (.members keys)
  | _ => throw s!"unsupported_construct: equality join over index set {set}"

private def candidates (axis : String) (ranges : RangesByName) : RangesByName :=
  ranges.filter fun (_, range) => (range.getObjValAs? String "from").toOption == some axis

private def chooseRange (key : String) (explicit : Option String) (allowDefault right : Bool)
    (choices : RangesByName) : Except String (Option (String × Json)) := do
  if let some symbol := explicit then
    let some range := choices.lookup symbol
      | throw s!"join_side_mismatch: key {key} cannot be read at {symbol}"
    return some (symbol, range)
  match choices with
  | [] => pure none
  | [only] => pure (some only)
  | [left, last] =>
    if allowDefault then pure (some (if right then last else left))
    else throw s!"join_side_ambiguous: {key} can bind {choices.map Prod.fst}"
  | _ => throw s!"join_side_ambiguous: {key} can bind {choices.map Prod.fst}"

private def side (scope : Scope) (ranges : RangesByName) (key : String)
    (explicit : Option String) (right : Bool) : Except String (Option JoinSide) := do
  if let some range := ranges.lookup key then
    if let some symbol := explicit then
      unless key == symbol do throw s!"join_side_mismatch: key {key} cannot be read at {symbol}"
    return some ⟨key, ← source scope range⟩
  let drawn := candidates key ranges
  if !drawn.isEmpty then
    let some (symbol, range) ← chooseRange key explicit false right drawn | return none
    return some ⟨symbol, ← source scope range⟩
  let some [axis] := scope.shapes.lookup key | return none
  let some (symbol, range) ← chooseRange key explicit true right (candidates axis ranges) | return none
  if (range.getObjVal? "of").isOk then
    throw s!"unsupported_construct: equality join on ragged column {key}"
  match (scope.sets.getObjValD axis |>.getObjValAs? String "kind").toOption with
  | some "interval" | some "categorical" => pure ()
  | _ => throw s!"unsupported_construct: equality join over index set {axis}"
  if scope.nonconstant.contains key then
    throw s!"join_key_not_constant: {key} reads state or the independent variable"
  return some ⟨symbol, .column key (scope.declaredData.contains key)⟩

def resolve (scope : Scope) (node : Json) : Except String (List JoinPair) := do
  let ranges := visitOrder node (fields (node.getObjValD "ranges"))
  let clauses ← (← node.getObjVal? "join").getArr?
  let mut result := []
  for clause in clauses do
    if (fields clause).any (fun (name, _) => name != "on" && name != "syms") then
      throw "unsupported_construct: join clause outside equality joins"
    let (left, right) ← match clause.getObjVal? "syms" with
      | .error _ => pure (none, none)
      | .ok value => do
        let #[.str a, .str b] ← value.getArr? | throw "join syms requires two range symbols"
        for symbol in [a, b] do
          unless (ranges.lookup symbol).isSome do throw s!"join_syms_unknown_symbol: {symbol}"
        pure (some a, some b)
    let pairs ← (← clause.getObjVal? "on").getArr?
    if pairs.isEmpty then throw "join on requires at least one pair"
    for pair in pairs do
      let #[.str a, .str b] ← pair.getArr? | throw "join on requires pairs of key names"
      let some l ← side scope ranges a left false | throw s!"join_key_unresolved: {a}"
      if let some r ← side scope ranges b right true then
        let pair : JoinPair := ⟨l, r⟩
        unless pair.positional do result := pair :: result
  return result.reverse

end Adapter.Joins
