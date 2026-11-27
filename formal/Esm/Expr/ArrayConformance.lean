import Esm.Expr.Core
import Esm.Expr.ArrayProofs
import Mathlib.Data.List.Forall2

/-! # Gather and array-evaluation laws

Expression indices are one-based. Coordinates in `ArrayData` are zero-based.
The lemmas connect the checked expression read with the storage and broadcast
operations that the evaluator uses. -/

namespace Esm.Expr

open Esm.Closed

variable {α : Type}

theorem indexOffset_outOfRange (offset : Nat) (dims : List Nat) (subscripts : List Int)
    (rank : dims.length = subscripts.length)
    (invalid : ¬ List.Forall₂ (fun (n : Nat) (i : Int) => 1 ≤ i ∧ i ≤ (n : Int)) dims subscripts) :
    indexOffset offset dims subscripts = .error .outOfRange := by
  induction dims generalizing offset subscripts with
  | nil =>
    cases subscripts with
    | nil => exact (invalid .nil).elim
    | cons _ _ => simp at rank
  | cons n dims ih =>
    cases subscripts with
    | nil => simp at rank
    | cons i rest =>
      have tailRank : dims.length = rest.length := Nat.succ.inj rank
      by_cases valid : 1 ≤ i ∧ i ≤ (n : Int)
      · rw [indexOffset, ite_eq_left valid]
        exact ih _ _ tailRank (fun tail => invalid (.cons valid tail))
      · simp [indexOffset, valid]

/-- An out-of-range leading subscript faults independently of its flattened
offset or the other axes. This includes full and partial gathers. -/
theorem indexCell_shaped_outOfRange (dims : List Nat) (cells : List (Val α)) (subscripts : List Int)
    (rank : subscripts.length ≤ dims.length)
    (invalid : ¬ List.Forall₂ (fun (n : Nat) (i : Int) => 1 ≤ i ∧ i ≤ (n : Int))
      (dims.take subscripts.length) subscripts) :
    indexCell (.shaped dims cells) subscripts = .error .outOfRange := by
  have prefixRank : (dims.take subscripts.length).length = subscripts.length := by
    rw [List.length_take, Nat.min_eq_left rank]
  simp [indexCell, indexRect, not_lt_of_ge rank,
    indexOffset_outOfRange 0 _ _ prefixRank invalid, bind, Except.bind]

/-- A literal vector's one-based bounds are checked before its cell is read. -/
theorem indexVal_literal_vector_outOfRange (cells : List α) (i : Int)
    (invalid : ¬ (1 ≤ i ∧ i ≤ (cells.length : Int))) :
    indexVal (.arr1 cells) [i] = .error .outOfRange := by
  simp [indexVal, invalid]

/-- A rectangular literal matrix checks each axis independently. -/
theorem indexVal_literal_matrix_outOfRange (rows : List (List α)) (width : Nat) (i j : Int)
    (rectangular : ∀ row ∈ rows, row.length = width)
    (invalid : ¬ ((1 ≤ i ∧ i ≤ (rows.length : Int)) ∧ (1 ≤ j ∧ j ≤ (width : Int)))) :
    indexVal (.arr2 rows) [i, j] = .error .outOfRange := by
  by_cases first : 1 ≤ i ∧ i ≤ (rows.length : Int)
  · let row := rows[(i - 1).toNat]'(by omega)
    have member : row ∈ rows := List.getElem_mem (by omega)
    have second : ¬ (1 ≤ j ∧ j ≤ (row.length : Int)) := by
      rw [rectangular row member]
      exact fun ok => invalid ⟨first, ok⟩
    rw [indexVal, dite_eq_left first]
    exact dite_eq_right second
  · simp [indexVal, first]

/-- A rectangular rank-three literal checks the outer axis, then the two
axes of the selected plane, independently. -/
theorem indexVal_literal_tensor_outOfRange (planes : List (List (List α)))
    (height width : Nat) (i j k : Int)
    (rectangular : ∀ plane ∈ planes, plane.length = height ∧ ∀ row ∈ plane, row.length = width)
    (invalid : ¬ ((1 ≤ i ∧ i ≤ (planes.length : Int)) ∧
      ((1 ≤ j ∧ j ≤ (height : Int)) ∧ (1 ≤ k ∧ k ≤ (width : Int))))) :
    indexVal (.arr3 planes) [i, j, k] = .error .outOfRange := by
  by_cases first : 1 ≤ i ∧ i ≤ (planes.length : Int)
  · let plane := planes[(i - 1).toNat]'(by omega)
    have member : plane ∈ planes := List.getElem_mem (by omega)
    obtain ⟨heightEq, rows⟩ := rectangular plane member
    rw [indexVal, dite_eq_left first]
    change indexVal (.arr2 plane) [j, k] = .error .outOfRange
    apply indexVal_literal_matrix_outOfRange plane width j k rows
    rw [heightEq]
    exact fun ok => invalid ⟨first, ok⟩
  · simp [indexVal, first]

private theorem stableBlock_at {β γ : Type} (items : List β) (row : β → List γ)
    (width rowNumber column : Nat) (item : β) (cell : γ)
    (rows : ∀ x ∈ items, (row x).length = width)
    (foundRow : items[rowNumber]? = some item) (foundColumn : (row item)[column]? = some cell) :
    (items.flatMap row)[rowNumber * width + column]? = some cell := by
  induction items generalizing rowNumber with
  | nil => simp at foundRow
  | cons first rest ih =>
    cases rowNumber with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at foundRow
      subst item
      obtain ⟨inside, _⟩ := List.getElem?_eq_some_iff.mp foundColumn
      simpa only [List.flatMap_cons, Nat.zero_mul, Nat.zero_add, List.getElem?_append_left inside]
        using foundColumn
    | succ k =>
      have widthFirst := rows first (List.mem_cons_self ..)
      have following : (row first).length ≤ (k + 1) * width + column := by
        rw [widthFirst, Nat.add_mul, Nat.one_mul]
        omega
      have residual : (k + 1) * width + column - (row first).length = k * width + column := by
        rw [widthFirst, Nat.add_mul, Nat.one_mul]
        omega
      rw [List.flatMap_cons, List.getElem?_append_right following, residual]
      exact ih k (fun x hx => rows x (List.mem_cons_of_mem _ hx)) (by simpa using foundRow)

theorem coords_length_eq_product (dims : List Nat) : (ArrayData.coords dims).length = dims.prod := by
  induction dims with
  | nil => rfl
  | cons n ds ih =>
    simp [ArrayData.coords, List.length_flatMap, ih, List.sum_replicate]

/-- The enumeration order used by the broadcast loop is the order used by
row-major gathers, for every coordinate in every rank. -/
theorem coords_at_offset (dims ix : List Nat)
    (valid : List.Forall₂ (fun n i : Nat => i < n) dims ix) :
    (ArrayData.coords dims)[ArrayData.offset dims ix]? = some ix := by
  induction valid with
  | nil => rfl
  | @cons n i ds is head tail ih =>
    have position : ArrayData.offset (n :: ds) (i :: is) =
        i * ds.prod + ArrayData.offset ds is := by
      simpa [ArrayData.offset] using ArrayData.offset_append [n] ds [i] is rfl tail.length_eq
    rw [position]
    exact stableBlock_at (List.range n) (fun j => (ArrayData.coords ds).map (j :: ·)) ds.prod i
      (ArrayData.offset ds is) i (i :: is) (fun _ _ => by simp [coords_length_eq_product])
      (List.getElem?_range head) (by simp [List.getElem?_map, ih])

/-- Convert zero-based coordinates to the expression evaluator's subscripts. -/
def oneBased (ix : List Nat) : List Int := ix.map (fun i : Nat => (i : Int) + 1)

private theorem indexOffset_oneBased (initial : Nat) (dims ix : List Nat)
    (valid : List.Forall₂ (fun n i : Nat => i < n) dims ix) :
    indexOffset initial dims (oneBased ix) = .ok (initial * dims.prod + ArrayData.offset dims ix) := by
  induction valid generalizing initial with
  | nil => simp [oneBased, indexOffset, ArrayData.offset]
  | @cons n i ds is head tail ih =>
    have subscript : 1 ≤ (i : Int) + 1 ∧ (i : Int) + 1 ≤ (n : Int) := by omega
    have position : ArrayData.offset (n :: ds) (i :: is) =
        i * ds.prod + ArrayData.offset ds is := by
      simpa [ArrayData.offset] using ArrayData.offset_append [n] ds [i] is rfl tail.length_eq
    rw [oneBased, List.map_cons, indexOffset, ite_eq_left subscript, position]
    change indexOffset _ ds (oneBased is) = _
    rw [ih]
    simp [Nat.add_mul, Nat.mul_assoc, Nat.add_assoc]

theorem gatherCoordinate_oneBased (dims ix : List Nat)
    (valid : List.Forall₂ (fun n i : Nat => i < n) dims ix) :
    gatherCoordinate dims (oneBased ix) = .ok ix := by
  have restored : (oneBased ix).map (fun i => (i - 1).toNat) = ix := by
    simp [oneBased, List.map_map, Function.comp_def]
  simp only [gatherCoordinate, restored, indexOffset_oneBased 0 dims ix valid,
    bind, Except.bind, pure, Except.pure]

theorem indexCell_at_offset (dims ix : List Nat) (cells : List (Val α))
    (valid : List.Forall₂ (fun n i : Nat => i < n) dims ix) :
    indexCell (.shaped dims cells) (oneBased ix) =
      match cells[ArrayData.offset dims ix]? with
      | some cell => .ok cell
      | none => .error (.typeError "index: inconsistent array extents") := by
  have rank : (oneBased ix).length = dims.length := by simpa [oneBased] using valid.length_eq.symm
  simp [indexCell, indexRect, rank, indexOffset_oneBased 0 dims ix valid, bind, Except.bind]
  cases cells[ArrayData.offset dims ix]? <;> rfl

private theorem mapM_success_at {β γ ε : Type} (f : β → Except ε γ)
    (inputs : List β) (outputs : List γ) (position : Nat) (input : β)
    (evaluated : inputs.mapM f = .ok outputs) (selected : inputs[position]? = some input) :
    ∃ output, f input = .ok output ∧ outputs[position]? = some output := by
  induction inputs generalizing outputs position with
  | nil => simp at selected
  | cons first rest ih =>
    cases head : f first with
    | error err => simp [List.mapM_cons, head, bind, Except.bind] at evaluated
    | ok value =>
      cases tail : rest.mapM f with
      | error err => simp [List.mapM_cons, head, tail, bind, Except.bind] at evaluated
      | ok values =>
        simp [List.mapM_cons, head, tail, bind, Except.bind, pure, Except.pure] at evaluated
        subst outputs
        cases position with
        | zero =>
          simp at selected
          subst input
          exact ⟨value, head, rfl⟩
        | succ p =>
          obtain ⟨result, lookup, stored⟩ := ih values p tail (by simpa using selected)
          exact ⟨result, lookup, by simpa using stored⟩

/-- An in-range gather of a successfully evaluated broadcast is the scalar
operation on the selected operand cells. Each operand uses the same singleton
and missing-axis rules as broadcast, including rank-zero operands. -/
theorem indexCell_broadcast (apply : List (Val α) → Except EvalError (Val α))
    (operands : List (ArrayData (Val α))) (result : ArrayData (Val α)) (ix : List Nat)
    (evaluated : ArrayData.broadcast apply .shapeMismatch operands = .ok result)
    (valid : List.Forall₂ (fun n i : Nat => i < n) result.dims ix) :
    indexCell (.shaped result.dims result.cells) (oneBased ix) =
      ArrayData.broadcastCell apply .shapeMismatch operands ix := by
  unfold ArrayData.broadcast at evaluated
  cases merged : operands.foldlM (fun ds a => ArrayData.mergeDims ds a.dims) [] with
  | none =>
    simp only [merged] at evaluated
    cases evaluated
  | some dims =>
    let operation := ArrayData.broadcastCell apply .shapeMismatch operands
    simp only [merged] at evaluated
    change (do
      let cells ← (ArrayData.coords dims).mapM operation
      pure (⟨dims, cells⟩ : ArrayData (Val α))) = .ok result at evaluated
    cases materialized : (ArrayData.coords dims).mapM operation with
    | error fault => simp [materialized, bind, Except.bind] at evaluated
    | ok cells =>
      simp [materialized, bind, Except.bind, pure, Except.pure] at evaluated
      subst result
      obtain ⟨cell, applied, stored⟩ := mapM_success_at operation _ cells
        (ArrayData.offset dims ix) ix materialized (coords_at_offset dims ix valid)
      change indexCell (.shaped dims cells) (oneBased ix) = operation ix
      rw [indexCell_at_offset dims ix cells valid, stored, applied]

section Eval

variable [Scalar α] [Lits α] [Elem α]

/-- A strict non-gather operation on numeric operands uses the scalar
primitive, with the operand results in their original order. -/
theorem eval_strict_numbers (env : Env α) (op : String) (args : List Ast)
    (strict : StrictOp) (values : List α) (dispatch : Op.ofString op = .strict strict)
    (notGather : strict ≠ .index) (evaluated : evalList args env = .ok (values.map Val.num)) :
    eval (.node op args) env = (applyStrict strict (values.map Val.num)).map Val.num := by
  have noInf (xs : List α) : hasInf (xs.map Val.num) = false := by
    induction xs with
    | nil => rfl
    | cons x xs ih => exact ih
  simp only [eval, dispatch, ite_eq_right notGather, evaluated, bind, Except.bind]
  cases values with
  | nil =>
    simp only [List.map_nil, applyWholeStrict, bind, Except.bind]
    cases applyStrict strict ([] : List (Val α)) <;> rfl
  | cons v values =>
    have noArrays : (Val.num v :: values.map Val.num).any
        (fun value => value.arrayData.isSome) = false := by
      simp [List.any_map, Function.comp_def, Val.arrayData]
    have noInfCons : hasInf (Val.num v :: values.map Val.num) = false := noInf (v :: values)
    simp only [List.map_cons, applyWholeStrict, Val.rank, Nat.not_lt_zero, decide_false,
      Bool.false_and, Bool.false_eq_true, ite_false, noArrays, noInfCons, bind, Except.bind]
    cases applyStrict strict (Val.num v :: values.map Val.num) <;> rfl

/-- A missing name is a named fault in both whole-expression and per-cell
evaluation. Neither route can substitute a numerical value. -/
theorem unbound_var_fault (env : Env α) (name : String) (ix : List Nat)
    (missing : env.lookup name = none) :
    eval (.var name) env = .error (.unbound name) ∧
      evalCell (.var name) env ix = .error (.unbound name) := by
  constructor
  · simp [eval, missing]
  · rw [evalCell, missing]
    rfl

private theorem evalList_mapM (env : Env α) (args : List Ast) :
    evalList args env = args.mapM (fun arg => eval arg env) := by
  induction args with
  | nil => rfl
  | cons arg rest ih => rw [evalList, List.mapM_cons, ih]

private theorem evalCellList_mapM (env : Env α) (ix : List Nat) (args : List Ast) :
    evalCellList args env ix = args.mapM (fun arg => evalCell arg env ix) := by
  induction args with
  | nil => rfl
  | cons arg rest ih => rw [evalCellList, List.mapM_cons, ih]

/-- If the earlier strict operands succeed, the first missing operand faults
with that name before executing the primitive or broadcasting its arguments. -/
theorem eval_strict_unbound_operand (env : Env α) (op name : String) (strict : StrictOp)
    (before after : List Ast) (values : List (Val α))
    (dispatch : Op.ofString op = .strict strict)
    (prefixSucceeds : evalList before env = .ok values) (missing : env.lookup name = none) :
    eval (.node op (before ++ .var name :: after)) env = .error (.unbound name) := by
  have listFault (earlier : List Ast) (vs : List (Val α)) (ok : evalList earlier env = .ok vs) :
      evalList (earlier ++ .var name :: after) env = .error (.unbound name) := by
    rw [evalList_mapM] at ok
    simp only [evalList_mapM, List.mapM_append, ok, List.mapM_cons, eval, missing, bind, Except.bind]
  by_cases gather : strict = .index
  · subst strict
    cases before with
    | nil => simp [eval, dispatch, evalIndex, isElementwiseGatherBase, missing, bind, Except.bind]
    | cons base rest =>
      simp only [evalList, bind, Except.bind] at prefixSucceeds
      cases baseResult : eval base env with
      | error err => simp [baseResult] at prefixSucceeds
      | ok value =>
        cases restResult : evalList rest env with
        | error err => simp [baseResult, restResult] at prefixSucceeds
        | ok vs =>
          have tailFault := listFault rest vs restResult
          simp only [List.cons_append, eval, dispatch, ite_true, evalIndex, baseResult,
            tailFault, bind, Except.bind]
          repeat' first | rfl | split
  · simp only [eval, dispatch, ite_eq_right gather, listFault before values prefixSucceeds,
      bind, Except.bind]

theorem evalCell_strict_unbound_operand (env : Env α) (op name : String) (strict : StrictOp)
    (before after : List Ast) (values : List (Val α)) (ix : List Nat) (notGather : strict ≠ .index)
    (dispatch : Op.ofString op = .strict strict)
    (prefixSucceeds : evalCellList before env ix = .ok values) (missing : env.lookup name = none) :
    evalCell (.node op (before ++ .var name :: after)) env ix = .error (.unbound name) := by
  have cellMissing := (unbound_var_fault env name ix missing).2
  rw [evalCellList_mapM] at prefixSucceeds
  cases strict <;> first | contradiction | simp_all only [evalCell, evalCellList_mapM,
    List.mapM_append, List.mapM_cons, bind, Except.bind]

/-- A strict elementwise primitive at a coordinate combines the values of its
operand expressions at that coordinate. Repeated application pushes the
coordinate to each leaf, while an indexed operand is evaluated as a gather. -/
theorem evalCell_strict_operands (env : Env α) (op : String) (args : List Ast) (strict : StrictOp)
    (ix : List Nat) (notGather : strict ≠ .index) (dispatch : Op.ofString op = .strict strict) :
    evalCell (.node op args) env ix =
      (args.mapM fun arg => evalCell arg env ix) >>= applyCell strict := by
  cases strict <;> first | contradiction | simp_all only [evalCell, evalCellList_mapM]

/-- Selecting a cell from a declared scalar broadcasts the scalar at every
result coordinate, including when the resulting rank exceeds zero. -/
theorem evalCell_scalar_variable (env : Env α) (name : String) (value : α) (ix : List Nat)
    (bound : env.lookup name = some (.num value)) : evalCell (.var name) env ix = .ok (.num value) := by
  rw [evalCell, bound]
  rfl

def Val.isLiteralArray : Val α → Bool
  | .arr1 _ | .arr2 _ | .arr3 _ => true
  | _ => false

omit [Scalar α] [Lits α] [Elem α] in
private theorem elementwiseResult_not_literal (value result : Val α)
    (rendered : elementwiseResult value = .ok result) : result.isLiteralArray = false := by
  cases value <;> simp only [elementwiseResult] at rendered
  all_goals
    first
    | cases rendered; rfl
    | split at rendered <;> (first | contradiction | cases rendered; rfl)

/-- Literal array storage can reach a gather unchanged only through a path
that does not itself construct an elementwise result. -/
theorem literal_array_gather_barrier (env : Env α) (base : Ast) (result : Val α)
    (evaluated : eval base env = .ok result) (literal : result.isLiteralArray = true) :
    isElementwiseGatherBase base = false := by
  cases base <;> try rfl
  case node op args =>
    cases dispatch : Op.ofString op with
    | strict strict =>
      by_cases gather : strict = .index
      · subst strict
        simp [isElementwiseGatherBase, broadcastArity, dispatch]
      · simp only [eval, dispatch, ite_eq_right gather, bind, Except.bind] at evaluated
        split at evaluated <;> try contradiction
        split at evaluated <;> try contradiction
        exact Bool.noConfusion (literal.symm.trans (elementwiseResult_not_literal _ _ evaluated))
    | ifelse => simp [isElementwiseGatherBase, dispatch]
    | other op => simp [isElementwiseGatherBase, dispatch]
  case array op args =>
    cases op <;> try rfl
    rename_i fn
    simp only [eval, bind, Except.bind] at evaluated
    repeat' first | contradiction | split at evaluated
    all_goals exact Bool.noConfusion (literal.symm.trans (elementwiseResult_not_literal _ _ evaluated))

/-- Materialized barriers and scalar/partial gathers keep the checked
value-level gather semantics. -/
theorem eval_index_materialized (env : Env α) (base : Ast) (args : List Ast)
    (barrier : isElementwiseGatherBase base = false) :
    eval (.node "index" (base :: args)) env = (do
      let value ← eval base env
      applyWholeStrict .index (value :: (← evalList args env))) := by
  have indexDispatch : Op.ofString "index" = .strict .index := rfl
  simp [eval, indexDispatch, evalIndex, barrier]

/-- Replacing a literal constant by a name bound to that same constant leaves
the gather result unchanged, including a fault on any evaluated axis. -/
theorem eval_index_constant_spelling (env : Env α) (name : String) (constant : Const)
    (args : List Ast) (value : Val α) (constantValue : constVal constant = .ok value)
    (nameBound : env.lookup name = some value) :
    eval (.node "index" (.const constant :: args)) env =
      eval (.node "index" (.var name :: args)) env := by
  have indexDispatch : Op.ofString "index" = .strict .index := rfl
  simp [eval, indexDispatch, evalIndex, isElementwiseGatherBase, constantValue, nameBound]

/-- The ordinary AST evaluator reaches the same checked gather used by the
array lemmas once a shaped base and its integral indices have evaluated. -/
theorem eval_index_shaped (env : Env α) (base : Ast) (args : List Ast) (values : List (Val α))
    (dims : List Nat) (cells : List (Val α)) (subscripts : List Int)
    (materialized : isElementwiseGatherBase base = false)
    (baseValue : eval base env = .ok (.shaped dims cells))
    (evaluated : evalList args env = .ok values)
    (indicesValue : gatherSubscripts values = .ok subscripts) :
    eval (.node "index" (base :: args)) env = indexCell (.shaped dims cells) subscripts := by
  have indexDispatch : Op.ofString "index" = .strict .index := rfl
  simp [eval, indexDispatch, evalIndex, materialized, baseValue, evaluated, applyWholeStrict,
    indicesValue, bind, Except.bind]

/-- On a successful elementwise materialization, the AST gather and the
primitive evaluated on the broadcast operand cells give the same value. -/
theorem eval_index_materialized_broadcast (env : Env α) (base : Ast) (args : List Ast)
    (values : List (Val α)) (op : StrictOp) (operands : List (ArrayData (Val α)))
    (result : ArrayData (Val α)) (ix : List Nat)
    (broadcasted : ArrayData.broadcast (applyCell op) .shapeMismatch operands = .ok result)
    (materialized : isElementwiseGatherBase base = false)
    (baseValue : eval base env = .ok (.shaped result.dims result.cells))
    (evaluated : evalList args env = .ok values)
    (indicesValue : gatherSubscripts values = .ok (oneBased ix))
    (valid : List.Forall₂ (fun n i : Nat => i < n) result.dims ix) :
    eval (.node "index" (base :: args)) env =
      ArrayData.broadcastCell (applyCell op) .shapeMismatch operands ix := by
  rw [eval_index_shaped env base args values result.dims result.cells (oneBased ix)
    materialized baseValue evaluated indicesValue]
  exact indexCell_broadcast _ operands result ix broadcasted valid

/-- A complete gather of an elementwise expression checks the subscripts and
enters its per-cell evaluator. The whole expression need not evaluate. -/
theorem eval_index_elementwise (env : Env α) (base : Ast) (args : List Ast) (dims : List Nat)
    (elementwise : isElementwiseGatherBase base = true)
    (shape : expressionDims base env = .ok (some dims))
    (nonempty : dims ≠ []) (fullRank : dims.length = args.length) :
    eval (.node "index" (base :: args)) env = (do
      let subscripts ← gatherSubscripts (← evalList args env)
      evalCell base env (← gatherCoordinate dims subscripts)) := by
  have indexDispatch : Op.ofString "index" = .strict .index := rfl
  cases dims with
  | nil => contradiction
  | cons d dims => simp [eval, indexDispatch, evalIndex, elementwise, shape, fullRank]

/-- A valid complete elementwise gather reads just the chosen coordinate even
if whole-expression evaluation would encounter a fault in another cell. -/
theorem eval_index_elementwise_cell (env : Env α) (base : Ast) (args : List Ast)
    (dims ix : List Nat) (values : List (Val α))
    (elementwise : isElementwiseGatherBase base = true)
    (shape : expressionDims base env = .ok (some dims))
    (nonempty : dims ≠ []) (fullRank : dims.length = args.length)
    (evaluated : evalList args env = .ok values)
    (subscripts : gatherSubscripts values = .ok (oneBased ix))
    (valid : List.Forall₂ (fun n i : Nat => i < n) dims ix) :
    eval (.node "index" (base :: args)) env = evalCell base env ix := by
  rw [eval_index_elementwise env base args dims elementwise shape nonempty fullRank]
  simp [evaluated, subscripts, gatherCoordinate_oneBased dims ix valid, bind, Except.bind]

/-- Bounds errors occur before any cell of the elementwise base is read. -/
theorem eval_index_elementwise_outOfRange (env : Env α) (base : Ast) (args : List Ast)
    (dims : List Nat) (values : List (Val α)) (indices : List Int)
    (elementwise : isElementwiseGatherBase base = true)
    (shape : expressionDims base env = .ok (some dims))
    (nonempty : dims ≠ []) (fullRank : dims.length = args.length)
    (evaluated : evalList args env = .ok values)
    (subscripts : gatherSubscripts values = .ok indices) (indexRank : dims.length = indices.length)
    (invalid : ¬ List.Forall₂ (fun (n : Nat) (i : Int) => 1 ≤ i ∧ i ≤ (n : Int)) dims indices) :
    eval (.node "index" (base :: args)) env = .error .outOfRange := by
  rw [eval_index_elementwise env base args dims elementwise shape nonempty fullRank]
  simp [evaluated, subscripts, gatherCoordinate, indexOffset_outOfRange 0 _ _ indexRank invalid,
    bind, Except.bind]

/-- A scalar conditional evaluates only its selected branch, including when
the other branch contains a bad gather or an unbound name. -/
theorem eval_ifelse_selected_branch (env : Env α) (condition yes no : Ast) (value : α)
    (tested : eval condition env = .ok (.num value)) :
    eval (.node "ifelse" [condition, yes, no]) env =
      if truthy value then eval yes env else eval no env := by
  have dispatch : Op.ofString "ifelse" = .ifelse := rfl
  simp [eval, dispatch, evalIfelse, tested, asNum, bind, Except.bind]

/-- The per-cell conditional follows the tested cell's branch alone. -/
theorem evalCell_ifelse_selected_branch (env : Env α) (condition yes no : Ast)
    (ix : List Nat) (value : α) (tested : evalCell condition env ix = .ok (.num value)) :
    evalCell (.node "ifelse" [condition, yes, no]) env ix =
      if truthy value then evalCell yes env ix else evalCell no env ix := by
  have dispatch : Op.ofString "ifelse" = .ifelse := rfl
  simp [evalCell, dispatch, evalConditionalCell, tested, asNum, bind, Except.bind]

end Eval

end Esm.Expr
