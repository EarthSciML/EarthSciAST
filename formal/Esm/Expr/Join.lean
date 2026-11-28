import Std.Data.HashMap.Basic
import Std.Data.HashSet.Basic

/-! Resolved FAQ equality joins. A partner list preserves the visiting order
of the corresponding range. The FAQ evaluator can drive from either side. -/

namespace Esm.Expr

variable {α : Type}

inductive JoinMember where
  | integer (value : Int)
  | category (value : String)
  deriving BEq

inductive JoinSource where
  | position
  | members (values : Array JoinMember)
  | column (name : String) (declaredData : Bool)
  deriving BEq

structure JoinSide where
  symbol : String
  source : JoinSource

structure JoinPair where
  left : JoinSide
  right : JoinSide

/-- An environment entry recording that a declared key column was rounded. -/
def joinColumnPrecisionKey (name : String) : String := "{join key precision}:" ++ name

/-- A loop symbol and an alias for its same index-set key combine
positionally. Distinct key columns on one range still restrict its rows. -/
def JoinPair.positional (pair : JoinPair) : Bool :=
  pair.left.symbol == pair.right.symbol && match pair.left.source with
    | .column .. => false
    | source => source == pair.right.source

def JoinPair.mapNames (f : String → String) (pair : JoinPair) : JoinPair :=
  let side (s : JoinSide) : JoinSide :=
    ⟨f s.symbol, match s.source with
      | .column name declaredData => .column (f name) declaredData
      | source => source⟩
  ⟨side pair.left, side pair.right⟩

/-- Membership for a gate when both symbols are bound, and ordered partners
when one symbol still needs to be visited. -/
structure JoinPositions where
  order : List Int := []
  members : Std.HashSet Int := {}

structure JoinPartners where
  left : String
  right : String
  leftByRight : Std.HashMap Int JoinPositions
  rightByLeft : Std.HashMap Int JoinPositions

inductive JoinKey (α : Type) where
  | number (value : α)
  | infinity (negative : Bool)
  | category (value : String)

private def JoinKey.le (le : α → α → Bool) : JoinKey α → JoinKey α → Bool
  | .category a, .category b => decide (a ≤ b)
  | _, .category _ => true
  | .category _, _ => false
  | .number a, .number b => le a b
  | .infinity a, .infinity b => a || !b
  | .infinity negative, .number _ => negative
  | .number _, .infinity negative => !negative

private structure KeyRow (α : Type) where
  key : JoinKey α
  position : Int
  order : Nat
  left : Bool

/-- Sort the two columns by exact key and group equal keys. Order within a
group is the visiting order on each side, irrespective of key order. -/
def JoinPartners.ofKeys (le : α → α → Bool) (pair : JoinPair)
    (left right : List (Int × JoinKey α)) : JoinPartners :=
  let rows (isLeft : Bool) (keys : List (Int × JoinKey α)) : List (KeyRow α) :=
    keys.zipIdx.map fun ((position, key), order) => ⟨key, position, order, isLeft⟩
  let equalKey (a b : KeyRow α) := a.key.le le b.key && b.key.le le a.key
  let sorted := (rows true left ++ rows false right).mergeSort fun a b =>
    if equalKey a b then decide (a.order ≤ b.order) else a.key.le le b.key
  (sorted.splitBy equalKey).foldl (fun partners group =>
    let l := (group.filter (·.left)).map (·.position)
    let r := (group.filter (fun row => !row.left)).map (·.position)
    let positions (order : List Int) : JoinPositions :=
      ⟨order, order.foldl (fun set i => set.insert i) {}⟩
    let lp := positions l
    let rp := positions r
    { partners with
      leftByRight := r.foldl (fun m i => m.insert i lp) partners.leftByRight
      rightByLeft := l.foldl (fun m i => m.insert i rp) partners.rightByLeft })
    ⟨pair.left.symbol, pair.right.symbol, {}, {}⟩

end Esm.Expr
