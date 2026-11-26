import Mathlib.Data.List.Basic

/-! Array storage and the shape operations of esm-spec §4.3.
Coordinates in this module are zero-based. Cells are stored in row-major
order, irrespective of the index order used by an operation. -/

namespace Esm.Expr

inductive ShapeOp where
  | reshape (dims : List (Nat ⊕ String))
  | transpose (perm : Option (List Nat))
  | concat (axis : Nat)
  | broadcast (fn : String)
  | makearray (regions : List (List (Int × Int)))

structure ArrayData (β : Type) where
  dims : List Nat
  cells : List β

namespace ArrayData

variable {β ε : Type}

def scalar (cell : β) : ArrayData β := ⟨[], [cell]⟩

def coords : List Nat → List (List Nat)
  | [] => [[]]
  | n :: ns =>
    let tail := coords ns
    (List.range n).flatMap fun i => tail.map (i :: ·)

private def within (dims ix : List Nat) : Bool :=
  dims.length == ix.length && (ix.zip dims).all fun (i, n) => i < n

def offset (dims ix : List Nat) : Nat :=
  (dims.zip ix).foldl (fun acc (n, i) => acc * n + i) 0

def at? (data : ArrayData β) (ix : List Nat) : Option β :=
  if within data.dims ix then data.cells[offset data.dims ix]? else none

private def coordsFromColumnOffset : List Nat → Nat → List Nat
  | [], _ => []
  | n :: ns, pos => pos % n :: coordsFromColumnOffset ns (pos / n)

/-- The first axis varies fastest when relabeling the elements by reshape. -/
def reshape (dims : List Nat) (source : ArrayData β) : Option (ArrayData β) := do
  guard (dims.prod = source.dims.prod ∧ source.cells.length = source.dims.prod)
  let cells ← (coords dims).mapM fun ix =>
    source.at? (coordsFromColumnOffset source.dims (offset dims.reverse ix.reverse))
  return ⟨dims, cells⟩

def transpose (perm : Option (List Nat)) (source : ArrayData β) : Option (ArrayData β) := do
  let axes := List.range source.dims.length
  let order := perm.getD axes.reverse
  guard (order.length = axes.length ∧ axes.all order.contains)
  let dims ← order.mapM fun axis => source.dims[axis]?
  let cells ← (coords dims).mapM fun ix => do
    let input ← axes.mapM fun axis => ix[order.idxOf axis]?
    source.at? input
  return ⟨dims, cells⟩

private def concatAt (axis : Nat) : List (ArrayData β) → List Nat → Nat → Option β
  | [], _, _ => none
  | src :: sources, ix, i => do
    let n ← src.dims[axis]?
    if i < n then src.at? (ix.set axis i)
    else concatAt axis sources ix (i - n)

def concat (axis : Nat) (operands : List (ArrayData β)) : Option (ArrayData β) := do
  let src ← operands.head?
  guard (axis < src.dims.length)
  let extents ← operands.mapM fun x => do
    let n ← x.dims[axis]?
    guard (x.dims.set axis 0 = src.dims.set axis 0)
    return n
  let dims := src.dims.set axis extents.sum
  let cells ← (coords dims).mapM fun (ix : List Nat) => do
    let i ← ix[axis]?
    concatAt axis operands ix i
  return ⟨dims, cells⟩

/-- Anonymous operands align from the first axis. Missing trailing dimensions
replicate, as do explicitly singleton dimensions. -/
def mergeDims : List Nat → List Nat → Option (List Nat)
  | [], b => some b
  | a, [] => some a
  | a :: as, b :: bs => do
    let n ← if a = b ∨ b = 1 then some a else if a = 1 then some b else none
    return n :: (← mergeDims as bs)

def broadcastAt (data : ArrayData β) (ix : List Nat) : Option β :=
  data.at? ((data.dims.zip ix).map fun (n, i) => if n = 1 then 0 else i)

def broadcast (apply : List β → Except ε β) (shapeError : ε)
    (operands : List (ArrayData β)) : Except ε (ArrayData β) := do
  let some dims := operands.foldlM (fun ds operand => mergeDims ds operand.dims) []
    | throw shapeError
  let cells ← (coords dims).mapM fun (ix : List Nat) => do
    let some args := operands.mapM (broadcastAt · ix) | throw shapeError
    apply args
  return ⟨dims, cells⟩

def emptyRegion (region : List (Int × Int)) : Bool :=
  region.any fun (lo, hi) => hi == lo - 1

def invertedRegion (region : List (Int × Int)) : Bool :=
  region.any fun (lo, hi) => hi < lo - 1

private def extent (bound : Int × Int) : Nat :=
  (bound.2 - bound.1 + 1).toNat

private def contains (region : List (Int × Int)) (ix : List Int) : Bool :=
  (region.zip ix).all fun ((lo, hi), i) => lo ≤ i && i ≤ hi

/-- Match all non-singleton axes. Singleton region axes may be dropped from
the source shape. -/
private def regionCoordinates : List (Int × Int) → List Nat → List Int → Option (List Nat)
  | [], [], [] => some []
  | (lo, hi) :: rs, ns, i :: is => do
    let n := extent (lo, hi)
    match ns with
    | k :: ks =>
      if n = k then (regionCoordinates rs ks is).map ((i - lo).toNat :: ·)
      else if n = 1 then regionCoordinates rs ns is
      else none
    | [] => if n = 1 then regionCoordinates rs [] is else none
  | _, _, _ => none

/-- Assembly uses the region bounding box, with later entries taking
precedence at covered cells. Empty regions contribute no cells. -/
def makearray (regions : List (List (Int × Int))) (values : List (ArrayData β))
    (zero : β) : Option (ArrayData β) := do
  let first ← regions.head?
  guard (regions.length = values.length)
  guard (regions.all fun r => r.length == first.length && !invertedRegion r)
  let bounds := regions.foldl (List.zipWith fun (lo, hi) (a, b) => (min lo a, max hi b)) first
  let dims := bounds.map extent
  let entries := (regions.zip values).filter fun (r, _) => !emptyRegion r
  for (region, source) in entries do
    unless source.dims.isEmpty do
      let _ ← regionCoordinates region source.dims (region.map Prod.fst)
  let laterFirst := entries.reverse
  let cells ← (coords dims).mapM fun (ix : List Nat) => do
    let position := (bounds.zip ix).map fun ((lo, _), i) => lo + Int.ofNat i
    match laterFirst.find? (fun (r, _) => contains r position) with
    | none => return zero
    | some (region, source) =>
      if source.dims.isEmpty then source.at? []
      else source.at? (← regionCoordinates region source.dims position)
  return ⟨dims, cells⟩

end ArrayData
end Esm.Expr
