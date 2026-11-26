import Esm.Expr.Array

namespace Esm.Expr.ArrayData

variable {β ε : Type}

/-- With one operand the broadcast still invokes its scalar function at
every cell. -/
theorem broadcast_unary (apply : β → Except ε β) (err : ε) (data : ArrayData β) :
    broadcast (fun | [x] => apply x | _ => throw err) err [data] =
      (do
        let cells ← (coords data.dims).mapM fun ix =>
          match data.broadcastAt ix with
          | some x => apply x
          | none => throw err
        return ⟨data.dims, cells⟩) := by
  simp [broadcast, List.foldlM, mergeDims, List.mapM]
  congr
  funext ix
  cases h : data.broadcastAt ix <;> simp [List.mapM.loop, h]

theorem trailingSlice_dims (data : ArrayData β) (prefixRank prefixOffset : Nat) :
    (data.trailingSlice prefixRank prefixOffset).dims = data.dims.drop prefixRank := rfl

theorem trailingSlice_cells_length (data : ArrayData β) (prefixRank prefixOffset : Nat)
    (fits : (prefixOffset + 1) * (data.dims.drop prefixRank).prod ≤ data.cells.length) :
    (data.trailingSlice prefixRank prefixOffset).cells.length = (data.dims.drop prefixRank).prod := by
  simp only [trailingSlice, List.length_take, List.length_drop]
  apply Nat.min_eq_left
  rw [Nat.add_mul, Nat.one_mul] at fits
  omega

theorem trailingSlice_entry (data : ArrayData β) (prefixRank prefixOffset position : Nat)
    (inSlice : position < (data.dims.drop prefixRank).prod) :
    (data.trailingSlice prefixRank prefixOffset).cells[position]? =
      data.cells[prefixOffset * (data.dims.drop prefixRank).prod + position]? := by
  simp only [trailingSlice, List.getElem?_take_of_lt inSlice, List.getElem?_drop]

private theorem foldOffsetFrom (pairs : List (Nat × Nat)) (start : Nat) :
    pairs.foldl (fun acc (n, i) => acc * n + i) start =
      start * (pairs.map Prod.fst).prod +
        pairs.foldl (fun acc (n, i) => acc * n + i) 0 := by
  induction pairs generalizing start with
  | nil => simp
  | cons pair rest inductionHypothesis =>
    obtain ⟨n, i⟩ := pair
    simp only [List.foldl_cons, List.map_cons, List.prod_cons, Nat.zero_mul, Nat.zero_add,
      inductionHypothesis (start * n + i), inductionHypothesis i, Nat.add_mul, Nat.mul_assoc,
      Nat.add_assoc]

theorem offset_append (leading trailing leadingIndex trailingIndex : List Nat)
    (leadRank : leading.length = leadingIndex.length)
    (tailRank : trailing.length = trailingIndex.length) :
    offset (leading ++ trailing) (leadingIndex ++ trailingIndex) =
      offset leading leadingIndex * trailing.prod + offset trailing trailingIndex := by
  unfold offset
  rw [List.zip_append leadRank, List.foldl_append, foldOffsetFrom, List.map_fst_zip (Nat.le_of_eq tailRank)]

/-- A complete read after slicing selects exactly the same source cell as
the corresponding full index into the original array. -/
theorem trailingSlice_full_read (data : ArrayData β) (leading trailing leadingIndex trailingIndex : List Nat)
    (shape : data.dims = leading ++ trailing) (leadRank : leading.length = leadingIndex.length)
    (tailRank : trailing.length = trailingIndex.length) (inSlice : offset trailing trailingIndex < trailing.prod) :
    (data.trailingSlice leading.length (offset leading leadingIndex)).cells[offset trailing trailingIndex]? =
      data.cells[offset data.dims (leadingIndex ++ trailingIndex)]? := by
  have trailingDims : data.dims.drop leading.length = trailing := by
    rw [shape, List.drop_left]
  rw [trailingSlice_entry data _ _ _ (by simpa only [trailingDims] using inSlice),
    trailingDims, shape, offset_append leading trailing leadingIndex trailingIndex leadRank tailRank]

end Esm.Expr.ArrayData
