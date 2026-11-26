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

end Esm.Expr.ArrayData
