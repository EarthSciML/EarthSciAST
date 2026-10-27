import Esm.Closed.Interp
import Mathlib.Algebra.Order.Archimedean.Real.Basic
import Mathlib.Algebra.Order.Floor.Semiring

/-!
# `function_tables` and `table_lookup` (esm-spec §9.5)

The exact model (over `Num`) of:

* the `function_tables` block and its load-time checks (§9.5.1, §9.5.5);
* the `table_lookup` op, its checks (§9.5.2, §9.5.5) and its evaluation;
* the §9.5.3 lowering to `interp.linear` / `interp.bilinear` / `index`;
* a small expression evaluator for the trees the lowering produces (literals,
  variables, `const`, the three `interp.*` closed functions, `index`,
  `table_lookup`).

Rulings modelled (formal/QUESTIONS.md):

* Q-4: `table_axis_nan` is checked before `table_axis_non_monotonic`.
* Q-9: `data` leaves must be finite (`table_data_nan`), stricter than inline tables.
* Q-10: a table WITHOUT `outputs` is single-output and lowers with its whole
  `data`; the `data[i]` slice applies only when `outputs` is declared. Its only
  valid integer `output` is therefore `0` (§9.5.5's "≥ leading dimension of
  `data` when `outputs` is absent" would admit `output: 3` on an 8-knot table and
  is read through Q-10).
* Q-11: absent `args` means `[]`; non-empty `args` is `table_lookup_args_nonempty`.
* Q-12: an omitted `output` means `0`, with or without `outputs`.
* Q-13: `interpolation: "nearest"` returns the value at the knot nearest `x`,
  ties to the lower knot, clamped. The model's lowering is
  `index(data, searchsorted(x, midpoints(axis)))`; the spec's current
  `index(data, searchsorted(x, axis))` is refuted (`spec_nearest_lowering_refuted`).

Choices the spec does not make, recorded where they are made: the order of the
§9.5.5 checks beyond Q-4; an axis with fewer than 2 values (required by §9.5.1,
no code in §9.5.5) is rejected under the non-spec marker
`unspecified:table_axis_too_short`; a NaN query to a `nearest` table has no
ruling (the model, and its lowering, return the last knot's value).
-/

namespace Esm.Closed.Tables

open Esm.Closed

noncomputable section

/-! ## Data literals -/

/-- A nested numeric `const` / `data` literal. -/
inductive Nested where
  | leaf (v : Num)
  | node (xs : List Nested)

namespace Nested

mutual
/-- The literal's nesting is exactly `shape` (a leaf has shape `[]`). -/
def hasShape : Nested → List ℕ → Bool
  | .leaf _, [] => true
  | .node xs, n :: rest => (xs.length == n) && allShape xs rest
  | _, _ => false
def allShape : List Nested → List ℕ → Bool
  | [], _ => true
  | x :: xs, s => hasShape x s && allShape xs s
end

mutual
/-- Some leaf is NaN. -/
def anyNaN : Nested → Bool
  | .leaf v => v.isNaN
  | .node xs => anyNaNs xs
def anyNaNs : List Nested → Bool
  | [] => false
  | x :: xs => anyNaN x || anyNaNs xs
end

def leafVal : Nested → Option Num
  | .leaf v => some v
  | _ => none

/-- A rank-1 literal as a list. -/
def toVec : Nested → Option (List Num)
  | .node xs => xs.mapM leafVal
  | _ => none

/-- A rank-2 literal as a list of rows. -/
def toMat : Nested → Option (List (List Num))
  | .node xs => xs.mapM toVec
  | _ => none

end Nested

def ofVec (l : List Num) : Nested := .node (l.map .leaf)
def ofMat (m : List (List Num)) : Nested := .node (m.map ofVec)

/-- How §9.2's argument contract sees a `const` literal. -/
def argOfNested : Nested → Arg Num
  | .leaf v => .const0 v
  | c => match c.toVec with
    | some v => .const1 v
    | none => match c.toMat with
      | some m => .const2 m
      | none => .constN

/-! ## The `function_tables` block -/

inductive Method where
  | linear
  | bilinear
  | nearest
  deriving DecidableEq

inductive OOB where
  | clamp
  | error
  deriving DecidableEq

structure Axis where
  name : String
  values : List Num

/-- A `FunctionTable` (§9.5.1). `description`, `units` and `schema_version`
carry no semantics and are omitted. -/
structure FTable where
  axes : List Axis
  interpolation : Method := .linear
  outOfBounds : OOB := .clamp
  outputs : Option (List String) := none
  data : Nested
  shape : Option (List ℕ) := none

namespace FTable

/-- The axis part of the data shape. -/
def axesShape (T : FTable) : List ℕ := T.axes.map (·.values.length)

/-- §9.5.1: `[len(outputs), len(axes[0]), …]` with outputs, else the axes alone. -/
def expectedShape (T : FTable) : List ℕ :=
  match T.outputs with
  | some os => os.length :: T.axesShape
  | none => T.axesShape

def arityOk : Method → ℕ → Bool
  | .linear, 1 => true
  | .bilinear, 2 => true
  | .nearest, 1 => true
  | _, _ => false

/-- The leading dimension of `data` differs from `len(outputs)`. -/
def outputsMismatch (T : FTable) : Bool :=
  match T.outputs, T.data with
  | some os, .node xs => xs.length != os.length
  | _, _ => false

def shapeAssertionWrong (T : FTable) : Bool :=
  match T.shape with
  | some s => s != T.expectedShape
  | none => false

def outputsDup (T : FTable) : Bool :=
  match T.outputs with
  | some os => !decide os.Nodup
  | none => false

end FTable

namespace Codes
def axisDuplicateName : Code := "table_axis_duplicate_name"
def outputsDuplicateName : Code := "table_outputs_duplicate_name"
def interpolationAxesMismatch : Code := "table_interpolation_axes_mismatch"
def axisNaN : Code := "table_axis_nan"
def axisNonMonotonic : Code := "table_axis_non_monotonic"
def axisTooShort : Code := "unspecified:table_axis_too_short"
def outputsLengthMismatch : Code := "table_outputs_length_mismatch"
def dataShapeMismatch : Code := "table_data_shape_mismatch"
def dataNaN : Code := "table_data_nan"
def lookupArgsNonempty : Code := "table_lookup_args_nonempty"
def lookupUnknownTable : Code := "table_lookup_unknown_table"
def lookupAxisNameMismatch : Code := "table_lookup_axis_name_mismatch"
def lookupOutputOutOfRange : Code := "table_lookup_output_out_of_range"
def lookupOutOfBounds : Code := "table_lookup_out_of_bounds"
end Codes

open FTable in
/-- The §9.5.5 load-time checks on one table, in the model's order (Q-4 pins
NaN before monotonicity; the rest is the model's choice). -/
def validateTable (T : FTable) : Except Code Unit :=
  if !decide (T.axes.map (·.name)).Nodup then .error Codes.axisDuplicateName
  else if T.outputsDup then .error Codes.outputsDuplicateName
  else if !arityOk T.interpolation T.axes.length then .error Codes.interpolationAxesMismatch
  else if T.axes.any (fun a => anyNaN a.values) then .error Codes.axisNaN
  else if T.axes.any (fun a => !adjAll Scalar.lt a.values) then .error Codes.axisNonMonotonic
  else if T.axes.any (fun a => decide (a.values.length < 2)) then .error Codes.axisTooShort
  else if T.outputsMismatch then .error Codes.outputsLengthMismatch
  else if !T.data.hasShape T.expectedShape then .error Codes.dataShapeMismatch
  else if T.data.anyNaN then .error Codes.dataNaN
  else if T.shapeAssertionWrong then .error Codes.dataShapeMismatch
  else .ok ()

/-! ## `table_lookup` -/

inductive OutSel where
  | idx (n : ℕ)
  | name (s : String)

/-- The 0-based position of `s` in `os`. -/
def findName (s : String) : List String → Option ℕ
  | [] => none
  | o :: os => if o = s then some 0 else (findName s os).map (· + 1)

theorem findName_lt {s : String} {os : List String} {i : ℕ} (h : findName s os = some i) :
    i < os.length := by
  induction os generalizing i with
  | nil => simp [findName] at h
  | cons o os ih =>
    simp only [findName] at h
    split_ifs at h with ho
    · cases h; simp
    · obtain ⟨j, hj, rfl⟩ := Option.map_eq_some_iff.mp h
      simpa using ih hj

/-- §9.5.2 `output` (integer index), with Q-10: without `outputs` the only
output is 0. -/
def resolveIdx (T : FTable) (n : ℕ) : Except Code ℕ :=
  match T.outputs with
  | some os => if n < os.length then .ok n else .error Codes.lookupOutputOutOfRange
  | none => if n = 0 then .ok 0 else .error Codes.lookupOutputOutOfRange

/-- §9.5.2 `output`, with Q-10 and Q-12 (omitted means 0, whether or not
`outputs` is declared). -/
def resolveOutput (T : FTable) : Option OutSel → Except Code ℕ
  | none => resolveIdx T 0
  | some (.idx n) => resolveIdx T n
  | some (.name s) =>
    match T.outputs with
    | some os => match findName s os with
      | some i => .ok i
      | none => .error Codes.lookupOutputOutOfRange
    | none => .error Codes.lookupOutputOutOfRange

theorem resolveOutput_lt {T : FTable} {os : List String} (hos : T.outputs = some os)
    {out : Option OutSel} {o : ℕ} (h : resolveOutput T out = .ok o) : o < os.length := by
  have hidx : ∀ n, resolveIdx T n = .ok o → o < os.length := by
    intro n hn
    simp only [resolveIdx, hos] at hn
    split_ifs at hn with h1
    · cases hn; exact h1
  cases out with
  | none => exact hidx 0 h
  | some sel =>
    cases sel with
    | idx n => exact hidx n h
    | name s =>
      simp only [resolveOutput, hos] at h
      cases hf : findName s os with
      | none => rw [hf] at h; cases h
      | some i => rw [hf] at h; cases h; exact findName_lt hf

/-- The data an output reads: `data[o]` with `outputs`, the whole `data`
without (Q-10). -/
def slice (T : FTable) (o : ℕ) : Nested :=
  match T.outputs, T.data with
  | some _, .node xs => xs.getD o (.node [])
  | _, d => d

/-- The axis-key check of §9.5.2: same set of names. -/
def keysMatch (keys names : List String) : Bool :=
  keys.all (· ∈ names) && names.all (· ∈ keys)

/-- Everything about a `table_lookup` node that is decided at load: Q-11 args,
the table reference, the table's own checks, the axis keys, the output. -/
def prepLookup {α : Type} (tables : List (String × FTable)) (tid : String) (keys : List String)
    (out : Option OutSel) (args : List α) : Except Code (FTable × Nested) :=
  if !args.isEmpty then .error Codes.lookupArgsNonempty
  else match tables.lookup tid with
    | none => .error Codes.lookupUnknownTable
    | some T => do
      validateTable T
      if !keysMatch keys (T.axes.map (·.name)) then .error Codes.lookupAxisNameMismatch
      else
        let o ← resolveOutput T out
        return (T, slice T o)

/-- Real part of a validated (NaN-free) value. -/
def Num.re : Num → ℝ
  | .fin r => r
  | .nan => 0

/-- The least index of a knot nearest `x`: ties go to the lower knot (Q-13). -/
def nearestIdx (a : List ℝ) (x : ℝ) : ℕ :=
  a.findIdx (fun ak => a.all (fun aj => decide (|x - ak| ≤ |x - aj|)))

/-- `interpolation: "nearest"` (Q-13, §9.5.3): the value at the knot nearest
`x`, ties to the lower knot, clamped; a NaN query returns NaN (§9.5.3). This
is the semantics with EXACT distances; the binary64 behaviour of the spec's
lowering is in `Esm/Closed/Tables/Nearest64.lean`. -/
def nearest (v : List Num) (ax : List Num) : Num → Num
  | .fin x => v.getD (nearestIdx (ax.map Num.re) x) .nan
  | .nan => .nan

/-- A query strictly outside an axis (`out_of_bounds: "error"`, §9.5.3a); a
NaN query is not out of bounds. -/
def outside (ax : List Num) (x : Num) : Bool :=
  Scalar.lt x (ax.getD 0 .nan) || Scalar.lt (ax.getD (ax.length - 1) .nan) x

/-- The value of a lookup on table `T`, data `s` (the output's slice), axis
inputs `xs` in the table's axis order, before the out-of-bounds check. -/
def lookupCore (T : FTable) (s : Nested) (xs : List Num) : Except Code Num :=
  match T.interpolation, T.axes, xs with
  | .linear, [a0], [x0] => match s.toVec with
    | some v => .ok (linear v a0.values x0)
    | none => .error Codes.dataShapeMismatch
  | .bilinear, [a0, a1], [x0, x1] => match s.toMat with
    | some m => .ok (bilinear m a0.values a1.values x0 x1)
    | none => .error Codes.dataShapeMismatch
  | .nearest, [a0], [x0] => match s.toVec with
    | some v => .ok (nearest v a0.values x0)
    | none => .error Codes.dataShapeMismatch
  | _, _, _ => .error Codes.interpolationAxesMismatch

/-- Some input lies strictly outside its axis. -/
def anyOutside (T : FTable) (xs : List Num) : Bool :=
  (List.zipWith (fun (a : Axis) x => outside a.values x) T.axes xs).any id

/-- The value of a lookup, with `out_of_bounds: "error"` (§9.5.3a). -/
def lookupValue (T : FTable) (s : Nested) (xs : List Num) : Except Code Num :=
  if T.outOfBounds = .error && anyOutside T xs then .error Codes.lookupOutOfBounds
  else lookupCore T s xs

/-! ## Expressions -/

inductive Expr where
  | lit (v : Num)
  | var (n : String)
  | const (c : Nested)
  | fn (name : String) (args : List Expr)
  | index (args : List Expr)
  /-- The §4.2 ops the nearest lowering uses: `-`, `<`, `==`, `min`, `max`, `ifelse`. -/
  | op (name : String) (args : List Expr)
  | lookup (table : String) (axes : List (String × Expr)) (output : Option OutSel)
      (args : List Expr)

inductive Val where
  | num (v : Num)
  | arr (c : Nested)

def Val.asNum : Val → Except Code Num
  | .num v => .ok v
  | .arr _ => .error "unspecified:not_a_scalar"

def argOf : Expr → Arg Num
  | .const c => argOfNested c
  | _ => .other

/-- `index(a, i)` for a rank-1 `a` and a 1-based integral `i` (§4.3.3, only as
far as the lowering needs it). -/
def indexVal : Val → Val → Except Code Val
  | .arr (.node xs), .num (.fin r) =>
    let k := ⌊r⌋₊
    if (k : ℝ) = r ∧ 1 ≤ k ∧ k ≤ xs.length then
      match xs.getD (k - 1) (.node []) with
      | .leaf v => .ok (.num v)
      | c => .ok (.arr c)
    else .error "unspecified:index_out_of_bounds"
  | _, _ => .error "unspecified:index_operand"

/-- IEEE `==`: false when either side is NaN. -/
def Num.beq : Num → Num → Bool
  | .fin a, .fin b => decide (a = b)
  | _, _ => false

def Num.ofBool (b : Bool) : Num := .fin (if b then 1 else 0)

/-- An `ifelse` condition holds when it is a nonzero number. -/
def Num.truthy : Num → Bool
  | .fin r => decide (r ≠ 0)
  | .nan => false

def Num.max : Num → Num → Num
  | .fin a, .fin b => .fin (Max.max a b)
  | _, _ => .nan

def Num.min : Num → Num → Num
  | .fin a, .fin b => .fin (Min.min a b)
  | _, _ => .nan

def closedNames : List String :=
  ["datetime.year", "datetime.month", "datetime.day", "datetime.hour", "datetime.minute",
   "datetime.second", "datetime.day_of_year", "datetime.julian_day", "datetime.is_leap_year",
   "interp.searchsorted", "interp.linear", "interp.bilinear"]

mutual

/-- Evaluation of the modelled fragment. -/
def eval (tables : List (String × FTable)) (env : String → Num) :
    Expr → Except Code Val
  | .lit v => .ok (.num v)
  | .var n => .ok (.num (env n))
  | .const (.leaf v) => .ok (.num v)
  | .const c => .ok (.arr c)
  | .fn name args => evalFn tables env name args
  | .index args => evalIndex tables env args
  | .op name args => evalOp tables env name args
  | .lookup tid axes out args => do
    let (T, s) ← prepLookup tables tid (axes.map Prod.fst) out args
    let vals ← evalAxes tables env axes
    let xs ← T.axes.mapM (fun a => match vals.lookup a.name with
      | some v => .ok v
      | none => .error Codes.lookupAxisNameMismatch)
    let r ← lookupValue T s xs
    return .num r

def evalFn (tables : List (String × FTable)) (env : String → Num) :
    String → List Expr → Except Code Val
  | "interp.searchsorted", [xe, xs] => do
    let xs ← validateSearchsorted (argOf xs)
    let x ← (← eval tables env xe).asNum
    return .num (.fin (searchsorted x xs : ℝ))
  | "interp.linear", [t, ax, xe] => do
    let (t, ax) ← validateLinear (argOf t) (argOf ax)
    let x ← (← eval tables env xe).asNum
    return .num (linear t ax x)
  | "interp.bilinear", [T, ax, ay, xe, ye] => do
    let (T, ax, ay) ← validateBilinear (argOf T) (argOf ax) (argOf ay)
    let x ← (← eval tables env xe).asNum
    let y ← (← eval tables env ye).asNum
    return .num (bilinear T ax ay x y)
  | name, _ =>
    if name ∈ closedNames then .error "unspecified:arity_or_unmodelled"
    else .error "unknown_closed_function"

/-- `ifelse` evaluates only the branch it takes. -/
def evalOp (tables : List (String × FTable)) (env : String → Num) :
    String → List Expr → Except Code Val
  | "ifelse", [c, a, b] => do
    let cv ← (← eval tables env c).asNum
    if Num.truthy cv then eval tables env a else eval tables env b
  | "-", [a, b] => do
    let u ← (← eval tables env a).asNum
    let v ← (← eval tables env b).asNum
    return .num (Scalar.sub u v)
  | "<", [a, b] => do
    let u ← (← eval tables env a).asNum
    let v ← (← eval tables env b).asNum
    return .num (Num.ofBool (Scalar.lt u v))
  | "==", [a, b] => do
    let u ← (← eval tables env a).asNum
    let v ← (← eval tables env b).asNum
    return .num (Num.ofBool (Num.beq u v))
  | "max", [a, b] => do
    let u ← (← eval tables env a).asNum
    let v ← (← eval tables env b).asNum
    return .num (Num.max u v)
  | "min", [a, b] => do
    let u ← (← eval tables env a).asNum
    let v ← (← eval tables env b).asNum
    return .num (Num.min u v)
  | _, _ => .error "unspecified:op_not_modelled"

def evalIndex (tables : List (String × FTable)) (env : String → Num) :
    List Expr → Except Code Val
  | [a, i] => do
    let av ← eval tables env a
    let iv ← eval tables env i
    indexVal av iv
  | _ => .error "unspecified:index_arity"

def evalAxes (tables : List (String × FTable)) (env : String → Num) :
    List (String × Expr) → Except Code (List (String × Num))
  | [] => .ok []
  | (k, e) :: rest => do
    let v ← (← eval tables env e).asNum
    let r ← evalAxes tables env rest
    return (k, v) :: r

end

/-! ## The §9.5.3 lowering -/

/-- §9.5.3's `nearest` lowering, as the spec writes it:
`ifelse(x == x, index(D, ifelse(A[hi] − x < x − A[lo], hi, lo)), x)` with
`j = searchsorted(x, A)`, `lo = max(j − 1, 1)`, `hi = min(j, N)`. -/
def nearestTree (D : Nested) (A : List Num) (x : Expr) : Expr :=
  let Ae := Expr.const (ofVec A)
  let j := Expr.fn "interp.searchsorted" [x, Ae]
  let lo := Expr.op "max" [.op "-" [j, .lit (.fin 1)], .lit (.fin 1)]
  let hi := Expr.op "min" [j, .lit (.fin (A.length : ℝ))]
  .op "ifelse" [.op "==" [x, x],
    .index [.const D,
      .op "ifelse" [.op "<" [.op "-" [.index [Ae, hi], x], .op "-" [x, .index [Ae, lo]]], hi, lo]],
    x]

/-- Lower a `table_lookup` node to closed functions. The `out_of_bounds:
"error"` mode has no closed-function form (nothing in the AST raises); its
check stays with the thin evaluator (`lookupValue`), which §9.5.3 permits. -/
def lower (tables : List (String × FTable)) (tid : String)
    (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr) :
    Except Code Expr := do
  let (T, s) ← prepLookup tables tid (axes.map Prod.fst) out args
  let inp := fun (a : Axis) => (axes.lookup a.name).getD (.lit .nan)
  match T.interpolation, T.axes with
  | .linear, [a0] => return .fn "interp.linear" [.const s, .const (ofVec a0.values), inp a0]
  | .bilinear, [a0, a1] =>
    return .fn "interp.bilinear"
      [.const s, .const (ofVec a0.values), .const (ofVec a1.values), inp a0, inp a1]
  | .nearest, [a0] => return nearestTree s a0.values (inp a0)
  | _, _ => .error Codes.interpolationAxesMismatch

/-! ## Facts about literals -/

theorem toVec_ofVec (l : List Num) : (ofVec l).toVec = some l := by
  induction l with
  | nil => rfl
  | cons x l ih =>
    simp only [ofVec, Nested.toVec, List.map_cons, List.mapM_cons, Nested.leafVal] at ih ⊢
    rw [ih]; rfl

theorem toVec_ofMat_cons (r : List Num) (m : List (List Num)) :
    (ofMat (r :: m)).toVec = none := by
  simp [ofMat, ofVec, Nested.toVec, List.mapM_cons, Nested.leafVal]

theorem toMat_ofMat (m : List (List Num)) : (ofMat m).toMat = some m := by
  induction m with
  | nil => rfl
  | cons r m ih =>
    simp only [ofMat, Nested.toMat, List.map_cons, List.mapM_cons, toVec_ofVec] at ih ⊢
    rw [ih]; rfl

theorem argOfNested_ofVec (l : List Num) : argOfNested (ofVec l) = .const1 l := by
  simp only [ofVec, argOfNested]
  rw [show Nested.node (l.map Nested.leaf) = ofVec l from rfl, toVec_ofVec]

theorem argOfNested_ofMat (r : List Num) (m : List (List Num)) :
    argOfNested (ofMat (r :: m)) = .const2 (r :: m) := by
  simp only [ofMat, argOfNested]
  rw [show Nested.node ((r :: m).map ofVec) = ofMat (r :: m) from rfl, toVec_ofMat_cons,
    toMat_ofMat]

theorem allShape_nil_iff (xs : List Nested) :
    Nested.allShape xs [] = true ↔ ∃ l : List Num, xs = l.map Nested.leaf := by
  induction xs with
  | nil => exact ⟨fun _ => ⟨[], rfl⟩, fun _ => rfl⟩
  | cons x xs ih =>
    simp only [Nested.allShape, Bool.and_eq_true]
    constructor
    · rintro ⟨hx, hxs⟩
      obtain ⟨l, rfl⟩ := ih.mp hxs
      cases x with
      | leaf v => exact ⟨v :: l, rfl⟩
      | node _ => simp [Nested.hasShape] at hx
    · rintro ⟨l, hl⟩
      cases l with
      | nil => simp at hl
      | cons v l =>
        simp only [List.map_cons, List.cons.injEq] at hl
        obtain ⟨rfl, rfl⟩ := hl
        exact ⟨rfl, ih.mpr ⟨l, rfl⟩⟩

theorem hasShape_one {s : Nested} {n : ℕ} (h : s.hasShape [n] = true) :
    ∃ v, s = ofVec v ∧ v.length = n := by
  cases s with
  | leaf _ => simp [Nested.hasShape] at h
  | node xs =>
    simp only [Nested.hasShape, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨l, rfl⟩ := (allShape_nil_iff xs).mp h.2
    exact ⟨l, rfl, by simpa using h.1⟩

theorem allShape_one_iff (xs : List Nested) (n : ℕ) :
    Nested.allShape xs [n] = true ↔
      ∃ m : List (List Num), xs = m.map ofVec ∧ ∀ row ∈ m, row.length = n := by
  induction xs with
  | nil => exact ⟨fun _ => ⟨[], rfl, by simp⟩, fun _ => rfl⟩
  | cons x xs ih =>
    simp only [Nested.allShape, Bool.and_eq_true]
    constructor
    · rintro ⟨hx, hxs⟩
      obtain ⟨m, rfl, hm⟩ := ih.mp hxs
      obtain ⟨v, rfl, hv⟩ := hasShape_one hx
      exact ⟨v :: m, rfl, by simp [hv, hm]; intro a ha; exact hm a ha⟩
    · rintro ⟨m, hm, hlen⟩
      cases m with
      | nil => simp at hm
      | cons v m =>
        simp only [List.map_cons, List.cons.injEq] at hm
        obtain ⟨rfl, rfl⟩ := hm
        refine ⟨?_, ih.mpr ⟨m, rfl, fun r hr => hlen r (by simp [hr])⟩⟩
        simp only [ofVec, Nested.hasShape, Bool.and_eq_true, beq_iff_eq, List.length_map]
        exact ⟨hlen v (by simp), (allShape_nil_iff _).mpr ⟨v, rfl⟩⟩

theorem hasShape_two {s : Nested} {n m : ℕ} (h : s.hasShape [n, m] = true) :
    ∃ M, s = ofMat M ∧ M.length = n ∧ ∀ row ∈ M, row.length = m := by
  cases s with
  | leaf _ => simp [Nested.hasShape] at h
  | node xs =>
    simp only [Nested.hasShape, Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨M, rfl, hM⟩ := (allShape_one_iff xs m).mp h.2
    exact ⟨M, rfl, by simpa using h.1, hM⟩

theorem allShape_getD {xs : List Nested} {sh : List ℕ} (h : Nested.allShape xs sh = true)
    {o : ℕ} (ho : o < xs.length) : (xs.getD o (.node [])).hasShape sh = true := by
  induction xs generalizing o with
  | nil => simp at ho
  | cons x xs ih =>
    simp only [Nested.allShape, Bool.and_eq_true] at h
    cases o with
    | zero => simpa using h.1
    | succ o => simpa using ih h.2 (by simpa using ho)

/-! ## What a valid table guarantees -/

/-- The axes of a valid table are real, strictly increasing and have ≥ 2 knots. -/
theorem validateTable_axes {T : FTable} (h : validateTable T = .ok ()) :
    ∀ a ∈ T.axes, ∃ r : List ℝ, a.values = r.map Num.fin ∧ r.Pairwise (· < ·) ∧ 2 ≤ r.length := by
  intro a ha
  unfold validateTable at h
  split_ifs at h with h1 h2 h3 h4 h5 h6 h7 h8 h9 h10
  simp only [List.any_eq_true, not_exists, not_and, Bool.not_eq_true] at h4 h6
  simp only [List.any_eq_true, Bool.not_eq_true', not_exists, not_and, Bool.not_eq_false] at h5
  obtain ⟨r, hr⟩ := (anyNaN_false_iff _).mp (h4 a ha)
  refine ⟨r, hr, (adjAll_lt_iff r).mp (by rw [← hr]; exact h5 a ha), ?_⟩
  have := h6 a ha
  simp only [decide_eq_false_iff_not, not_lt] at this
  rw [hr, List.length_map] at this; exact this

theorem validateTable_arity {T : FTable} (h : validateTable T = .ok ()) :
    FTable.arityOk T.interpolation T.axes.length = true := by
  unfold validateTable at h
  split_ifs at h with h1 h2 h3
  simpa using h3

theorem validateTable_shape {T : FTable} (h : validateTable T = .ok ()) :
    T.data.hasShape T.expectedShape = true ∧ T.data.anyNaN = false := by
  unfold validateTable at h
  split_ifs at h with h1 h2 h3 h4 h5 h6 h7 h8 h9
  exact ⟨by simpa using h8, by simpa using h9⟩

/-- Q-10: the slice an output reads has the axes' shape. -/
theorem slice_shape {T : FTable} (h : validateTable T = .ok ()) {out : Option OutSel} {o : ℕ}
    (ho : resolveOutput T out = .ok o) : (slice T o).hasShape T.axesShape = true := by
  have hs := (validateTable_shape h).1
  unfold slice
  unfold FTable.expectedShape at hs
  cases hout : T.outputs with
  | none => rw [hout] at hs; simpa [hout] using hs
  | some os =>
    rw [hout] at hs
    cases hd : T.data with
    | leaf _ => rw [hd] at hs; simp [Nested.hasShape] at hs
    | node xs =>
      rw [hd] at hs
      simp only [Nested.hasShape, Bool.and_eq_true, beq_iff_eq] at hs
      have hlt : o < xs.length := by rw [hs.1]; exact resolveOutput_lt hout ho
      simpa [FTable.axesShape] using allShape_getD hs.2 hlt

/-! ## Nearest knot, by midpoints -/

/-- Real midpoints of adjacent knots. -/
def midsR (r : List ℝ) : List ℝ := List.zipWith (fun p q => (p + q) / 2) r r.tail

theorem length_midsR (r : List ℝ) : (midsR r).length = r.length - 1 := by
  simp [midsR, List.length_zipWith, List.length_tail]

theorem getD_midsR {r : List ℝ} {j : ℕ} (hj : j + 1 < r.length) :
    (midsR r).getD j 0 = (r.getD j 0 + r.getD (j + 1) 0) / 2 := by
  rw [List.getD_eq_getElem _ _ (by rw [length_midsR]; omega), List.getD_eq_getElem _ _ (by omega),
    List.getD_eq_getElem _ _ hj]
  simp [midsR, List.getElem_zipWith, List.getElem_tail]

theorem abs_le_abs_iff_mid {p q x : ℝ} (hpq : p < q) :
    |x - p| ≤ |x - q| ↔ x ≤ (p + q) / 2 := by
  rw [← sq_le_sq]
  constructor
  · intro h; nlinarith
  · intro h; nlinarith

theorem abs_lt_abs_iff_mid {p q x : ℝ} (hpq : p < q) :
    |x - q| < |x - p| ↔ (p + q) / 2 < x := by
  rw [← sq_lt_sq]
  constructor
  · intro h; nlinarith
  · intro h; nlinarith

/-- Q-13: the first midpoint at or above `x` locates the nearest knot, ties to
the lower knot. -/
theorem findIdx_midsR (r : List ℝ) (hr : r.Pairwise (· < ·)) (hn : 1 ≤ r.length) (x : ℝ) :
    (midsR r).findIdx (fun m => decide (x ≤ m)) = nearestIdx r x := by
  set k := (midsR r).findIdx (fun m => decide (x ≤ m)) with hk
  have hkle : k ≤ r.length - 1 := by
    have := List.findIdx_le_length (p := fun m => decide (x ≤ m)) (xs := midsR r)
    rw [length_midsR] at this; exact this
  -- below k every midpoint is below x; at k (if any) it is ≥ x
  have hbelow : ∀ j, j < k → (r.getD j 0 + r.getD (j + 1) 0) / 2 < x := by
    intro j hj
    have := List.not_of_lt_findIdx (p := fun m => decide (x ≤ m)) (xs := midsR r) hj
    simp only [decide_eq_false_iff_not, not_le] at this
    rw [← getD_midsR (by omega), List.getD_eq_getElem _ _ (by rw [length_midsR]; omega)]
    exact this
  have hat : k + 1 < r.length → x ≤ (r.getD k 0 + r.getD (k + 1) 0) / 2 := by
    intro hk1
    have hlt : k < (midsR r).length := by rw [length_midsR]; omega
    have := List.findIdx_getElem (w := hlt)
    simp only [decide_eq_true_eq] at this
    rw [← getD_midsR hk1, List.getD_eq_getElem _ _ hlt]
    exact this
  have hkn : k < r.length := by omega
  -- the knot k is at least as close as every knot, and strictly closer than those below
  have closest : ∀ j, j < r.length → |x - r.getD k 0| ≤ |x - r.getD j 0| := by
    intro j hj
    rcases lt_trichotomy j k with h | h | h
    · have h1 := hbelow (k - 1) (by omega)
      have e : k - 1 + 1 = k := by omega
      rw [e] at h1
      have h2 : r.getD j 0 ≤ r.getD (k - 1) 0 := pw_getD_le hr (by omega) (by omega)
      have h3 : r.getD j 0 < r.getD k 0 := pw_getD_lt hr hkn h
      exact ((abs_lt_abs_iff_mid h3).mpr (by linarith)).le
    · rw [h]
    · have h1 := hat (by omega)
      have h2 : r.getD (k + 1) 0 ≤ r.getD j 0 := pw_getD_le hr hj (by omega)
      have h3 : r.getD k 0 < r.getD j 0 := pw_getD_lt hr hj h
      exact (abs_le_abs_iff_mid h3).mpr (by linarith)
  have strict : ∀ j, j < k → |x - r.getD k 0| < |x - r.getD j 0| := by
    intro j hj
    have h1 := hbelow (k - 1) (by omega)
    have e : k - 1 + 1 = k := by omega
    rw [e] at h1
    have h2 : r.getD j 0 ≤ r.getD (k - 1) 0 := pw_getD_le hr (by omega) (by omega)
    have h3 : r.getD j 0 < r.getD k 0 := pw_getD_lt hr hkn hj
    exact (abs_lt_abs_iff_mid h3).mpr (by linarith)
  symm
  unfold nearestIdx
  rw [List.findIdx_eq hkn]
  constructor
  · rw [List.all_eq_true]
    intro aj haj
    obtain ⟨j, hj, rfl⟩ := List.mem_iff_getElem.mp haj
    have := closest j hj
    rw [List.getD_eq_getElem _ _ hkn, List.getD_eq_getElem _ _ hj] at this
    simpa using this
  · intro j hj
    rw [List.all_eq_false]
    refine ⟨r[k], List.getElem_mem _, ?_⟩
    have := strict j hj
    rw [List.getD_eq_getElem _ _ hkn, List.getD_eq_getElem _ _ (by omega)] at this
    simpa using this

/-- Q-13, the semantics: the model's nearest index is an argmin of `|x − knot|`,
the least one (ties to the lower knot), and clamps (it is always a knot). -/
theorem nearestIdx_spec (r : List ℝ) (hr : r.Pairwise (· < ·)) (hn : 1 ≤ r.length) (x : ℝ) :
    nearestIdx r x < r.length ∧
      (∀ j, j < r.length → |x - r.getD (nearestIdx r x) 0| ≤ |x - r.getD j 0|) ∧
      (∀ j, j < nearestIdx r x → |x - r.getD (nearestIdx r x) 0| < |x - r.getD j 0|) := by
  have hidx := findIdx_midsR r hr hn x
  have hkn : nearestIdx r x < r.length := by
    rw [← hidx]
    have := List.findIdx_le_length (p := fun m => decide (x ≤ m)) (xs := midsR r)
    rw [length_midsR] at this; omega
  have hP : r.all (fun aj => decide (|x - (r[nearestIdx r x]'hkn)| ≤ |x - aj|)) = true :=
    List.findIdx_getElem (p := fun ak => r.all (fun aj => decide (|x - ak| ≤ |x - aj|)))
      (xs := r) (w := hkn)
  have hQ : ∀ j (hj : j < nearestIdx r x),
      r.all (fun aj => decide (|x - (r[j]'(by omega))| ≤ |x - aj|)) = false :=
    fun j hj => List.not_of_lt_findIdx
      (p := fun ak => r.all (fun aj => decide (|x - ak| ≤ |x - aj|))) (xs := r) (i := j) hj
  rw [List.all_eq_true] at hP
  refine ⟨hkn, ?_, ?_⟩
  · intro j hj
    have := hP r[j] (List.getElem_mem _)
    rw [List.getD_eq_getElem _ _ hkn, List.getD_eq_getElem _ _ hj]
    simpa using this
  · intro j hj
    have := hQ j hj
    rw [List.all_eq_false] at this
    obtain ⟨aj, haj, hlt⟩ := this
    simp only [Bool.not_eq_true, decide_eq_false_iff_not, not_le] at hlt
    rw [List.getD_eq_getElem _ _ hkn, List.getD_eq_getElem _ _ (by omega)]
    have := hP aj haj
    simp only [decide_eq_true_eq] at this
    linarith

/-! ## Validation of the lowered arguments -/

theorem validateLinear_eq (t : List Num) (r : List ℝ) (hlen : t.length = r.length)
    (h2 : 2 ≤ r.length) (hr : r.Pairwise (· < ·)) :
    validateLinear (Arg.const1 t) (Arg.const1 (r.map Num.fin)) = .ok (t, r.map Num.fin) := by
  have h3 : anyNaN (r.map Num.fin) = false := (anyNaN_false_iff _).mpr ⟨r, rfl⟩
  have h4 := (adjAll_lt_iff r).mpr hr
  have c1 : ¬ (r.map Num.fin).length < 2 := by simp; omega
  have c2 : t.length = (r.map Num.fin).length := by simpa using hlen
  simp only [validateLinear, h3, h4, c1, c2, ne_eq, not_true_eq_false, Bool.not_true,
    Bool.false_eq_true, ↓reduceIte]

theorem validateBilinear_eq (M : List (List Num)) (rx ry : List ℝ) (hlen : M.length = rx.length)
    (hrow : ∀ row ∈ M, row.length = ry.length) (h2x : 2 ≤ rx.length) (h2y : 2 ≤ ry.length)
    (hx : rx.Pairwise (· < ·)) (hy : ry.Pairwise (· < ·)) :
    validateBilinear (Arg.const2 M) (Arg.const1 (rx.map Num.fin)) (Arg.const1 (ry.map Num.fin)) =
      .ok (M, rx.map Num.fin, ry.map Num.fin) := by
  have n1 : anyNaN (rx.map Num.fin) = false := (anyNaN_false_iff _).mpr ⟨rx, rfl⟩
  have n2 : anyNaN (ry.map Num.fin) = false := (anyNaN_false_iff _).mpr ⟨ry, rfl⟩
  have m1 := (adjAll_lt_iff rx).mpr hx
  have m2 := (adjAll_lt_iff ry).mpr hy
  have c1 : (decide ((rx.map Num.fin).length < 2) || decide ((ry.map Num.fin).length < 2)) = false := by
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, not_lt, List.length_map]; omega
  have c2 : (decide (M.length ≠ (rx.map Num.fin).length) ||
      M.any (fun row => decide (row.length ≠ (ry.map Num.fin).length))) = false := by
    simpa [hlen] using hrow
  simp only [validateBilinear, c1, c2, n1, n2, m1, m2, Bool.or_false, Bool.and_true, Bool.not_true,
    Bool.false_eq_true, ↓reduceIte]

theorem midsR_pairwise (r : List ℝ) (hr : r.Pairwise (· < ·)) : (midsR r).Pairwise (· ≤ ·) := by
  rw [List.pairwise_iff_getElem]
  intro i j hi hj hij
  rw [length_midsR] at hi hj
  have a := getD_midsR (r := r) (j := i) (by omega)
  have b := getD_midsR (r := r) (j := j) (by omega)
  rw [List.getD_eq_getElem _ _ (by rw [length_midsR]; omega)] at a b
  rw [a, b]
  have h1 := pw_getD_lt hr (i := i) (j := j) (by omega) hij
  have h2 := pw_getD_lt hr (i := i + 1) (j := j + 1) (by omega) (by omega)
  linarith

theorem validateSearchsorted_eq (r : List ℝ) (hr : r.Pairwise (· ≤ ·)) :
    validateSearchsorted (Arg.const1 (r.map Num.fin)) = .ok (r.map Num.fin) := by
  have h1 : anyNaN (r.map Num.fin) = false := (anyNaN_false_iff _).mpr ⟨r, rfl⟩
  have h2 := (adjAll_le_iff r).mpr hr
  simp [validateSearchsorted, h1, h2]

/-! ## Unpacking a successful lookup preparation -/

theorem prepLookup_ok {tables : List (String × FTable)} {tid : String} {keys : List String}
    {out : Option OutSel} {args : List Expr} {T : FTable} {s : Nested}
    (h : prepLookup tables tid keys out args = .ok (T, s)) :
    args = [] ∧ tables.lookup tid = some T ∧ validateTable T = .ok () ∧
      keysMatch keys (T.axes.map (·.name)) = true ∧
      ∃ o, resolveOutput T out = .ok o ∧ s = slice T o := by
  unfold prepLookup at h
  cases h1 : args.isEmpty with
  | false => rw [h1] at h; cases h
  | true =>
    rw [h1] at h
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
    cases hT : tables.lookup tid with
      | none => rw [hT] at h; cases h
      | some T' =>
        rw [hT] at h
        dsimp only at h
        cases hv : validateTable T' with
        | error c => rw [hv] at h; cases h
        | ok u =>
          rw [hv] at h
          simp only [bind, Except.bind] at h
          cases h2 : keysMatch keys (T'.axes.map (·.name)) with
          | false => simp [h2] at h
          | true =>
            simp only [h2, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
            cases ho : resolveOutput T' out with
            | error c => rw [ho] at h; cases h
            | ok o =>
              rw [ho] at h
              simp only [pure, Except.pure, Except.ok.injEq, Prod.mk.injEq] at h
              obtain ⟨rfl, rfl⟩ := h
              exact ⟨List.isEmpty_iff.mp h1, rfl, by cases u; exact hv, h2, o, ho, rfl⟩

theorem lookup_isSome_of_mem {β : Type} {axes : List (String × β)} {k : String}
    (h : k ∈ axes.map Prod.fst) : ∃ e, axes.lookup k = some e := by
  induction axes with
  | nil => simp at h
  | cons p rest ih =>
    obtain ⟨k', e'⟩ := p
    simp only [List.lookup]
    by_cases hk : k = k'
    · subst hk; exact ⟨e', by simp⟩
    · have : (k == k') = false := by simpa using hk
      rw [this]
      exact ih (by simp at h; rcases h with h | h; exact absurd h hk; simpa using h)

theorem evalAxes_ok (tables : List (String × FTable)) (env : String → Num)
    (axes : List (String × Expr)) (hin : ∀ p ∈ axes, ∃ v, eval tables env p.2 = .ok (.num v)) :
    ∃ vals, evalAxes tables env axes = .ok vals ∧
      ∀ k e, axes.lookup k = some e → ∃ v, eval tables env e = .ok (.num v) ∧ vals.lookup k = some v := by
  induction axes with
  | nil => exact ⟨[], by simp [evalAxes], fun k e h => by simp at h⟩
  | cons p rest ih =>
    obtain ⟨k0, e0⟩ := p
    obtain ⟨v0, hv0⟩ := hin (k0, e0) (by simp)
    obtain ⟨vals, hvals, hlk⟩ := ih (fun p hp => hin p (by simp [hp]))
    refine ⟨(k0, v0) :: vals, ?_, ?_⟩
    · simp only [evalAxes, hv0, hvals]; rfl
    · intro k e hke
      simp only [List.lookup] at hke ⊢
      by_cases hk : k = k0
      · subst hk
        simp only [beq_self_eq_true, Option.some.injEq] at hke ⊢
        subst hke
        exact ⟨v0, hv0, rfl⟩
      · have : (k == k0) = false := by simpa using hk
        rw [this] at hke ⊢
        exact hlk k e hke

theorem keysMatch_mem {keys names : List String} (h : keysMatch keys names = true) {n : String}
    (hn : n ∈ names) : n ∈ keys := by
  simp only [keysMatch, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at h
  exact h.2 n hn

/-! ## The lowering is sound -/

/-- Inputs of a lookup whose axis keys match: each table axis has an input
expression, it evaluates to a scalar, and `evalAxes` recorded that scalar. -/
theorem axis_input {tables : List (String × FTable)} {env : String → Num}
    {axes : List (String × Expr)} {vals : List (String × Num)} {T : FTable}
    (hkeys : keysMatch (axes.map Prod.fst) (T.axes.map (·.name)) = true)
    (hlk : ∀ k e, axes.lookup k = some e →
      ∃ v, eval tables env e = .ok (.num v) ∧ vals.lookup k = some v)
    {a : Axis} (ha : a ∈ T.axes) :
    ∃ v, eval tables env ((axes.lookup a.name).getD (.lit .nan)) = .ok (.num v) ∧
      vals.lookup a.name = some v := by
  obtain ⟨e, he⟩ := lookup_isSome_of_mem (keysMatch_mem hkeys (List.mem_map_of_mem ha))
  obtain ⟨v, hv, hvl⟩ := hlk _ _ he
  exact ⟨v, by rw [he]; exact hv, hvl⟩

theorem eval_lookup_prep {tables : List (String × FTable)} {env : String → Num}
    {tid : String} {axes : List (String × Expr)} {out : Option OutSel} {args : List Expr}
    {T : FTable} {s : Nested} {vals : List (String × Num)}
    (hp : prepLookup tables tid (axes.map Prod.fst) out args = .ok (T, s))
    (hvals : evalAxes tables env axes = .ok vals) :
    eval tables env (.lookup tid axes out args) =
      (do
        let xs ← T.axes.mapM (fun a => match vals.lookup a.name with
          | some v => .ok v
          | none => .error Codes.lookupAxisNameMismatch)
        let r ← lookupValue T s xs
        return Val.num r) := by
  rw [eval, hp]
  simp only [bind, Except.bind, hvals]

theorem searchsorted_fin_map (x : ℝ) (l : List ℝ) :
    searchsorted (Num.fin x) (l.map Num.fin) = l.findIdx (fun m => decide (x ≤ m)) + 1 := by
  simp only [searchsorted, List.findIdx_map]
  rfl

theorem map_re_fin (r : List ℝ) : (r.map Num.fin).map Num.re = r := by
  induction r with
  | nil => rfl
  | cons a r ih => simp only [List.map_cons, Num.re, ih]

/-- Characterize `findIdx` by its value (either an index or the length). -/
theorem findIdx_eq_of {α : Type} {p : α → Bool} {l : List α} {k : ℕ} (hk : k ≤ l.length)
    (hpos : ∀ (h : k < l.length), p l[k] = true) (hneg : ∀ i (h : i < k), p (l[i]'(by omega)) = false) :
    l.findIdx p = k := by
  rcases hk.lt_or_eq with h | h
  · exact (List.findIdx_eq h).mpr ⟨hpos h, fun i hi => hneg i hi⟩
  · subst h
    apply List.findIdx_eq_length.mpr
    intro x hx
    obtain ⟨i, hi, rfl⟩ := List.mem_iff_getElem.mp hx
    exact hneg i hi

/-- §9.5.3 with exact arithmetic: with `j` the first knot `≥ x` (0-based),
`lo = j − 1` and `hi = min(j, N − 1)`, the nearest knot (least argmin) is `hi`
when `A[hi] − x < x − A[lo]` and `lo` otherwise. -/
theorem nearestIdx_bracket (a : List ℝ) (hr : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) (x : ℝ) :
    nearestIdx a x =
      if a.getD (min (a.findIdx (fun b => decide (x ≤ b))) (a.length - 1)) 0 - x <
          x - a.getD (a.findIdx (fun b => decide (x ≤ b)) - 1) 0
      then min (a.findIdx (fun b => decide (x ≤ b))) (a.length - 1)
      else a.findIdx (fun b => decide (x ≤ b)) - 1 := by
  rw [← findIdx_midsR a hr (by omega) x]
  set j := a.findIdx (fun b => decide (x ≤ b)) with hj
  have hjle : j ≤ a.length := List.findIdx_le_length
  have hbelow : ∀ i, i < j → a.getD i 0 < x := by
    intro i hi
    have := List.not_of_lt_findIdx (p := fun b => decide (x ≤ b)) (xs := a) (i := i) hi
    simp only [decide_eq_false_iff_not, not_le] at this
    rw [List.getD_eq_getElem _ _ (by omega)]; exact this
  have hat : j < a.length → x ≤ a.getD j 0 := by
    intro h
    have := List.findIdx_getElem (p := fun b => decide (x ≤ b)) (xs := a) (w := h)
    simp only [decide_eq_true_eq] at this
    rw [List.getD_eq_getElem _ _ h]; exact this
  have hlm : (midsR a).length = a.length - 1 := length_midsR a
  have gm : ∀ i (h : i < (midsR a).length),
      (midsR a)[i] = (a.getD i 0 + a.getD (i + 1) 0) / 2 := by
    intro i h
    rw [← getD_midsR (by omega), List.getD_eq_getElem]
  rcases Nat.eq_zero_or_pos j with h0 | h0
  · -- below (or on) the first knot
    rw [h0] at hat ⊢
    have hx0 := hat (by omega)
    simp only [Nat.zero_min, Nat.zero_sub, lt_self_iff_false, sub_lt_self_iff, ↓reduceIte]
    have : ¬ (a.getD 0 0 - x < x - a.getD 0 0) := by intro h; linarith
    rw [if_neg this]
    apply findIdx_eq_of (by omega)
    · intro h
      have := pw_getD_lt hr (i := 0) (j := 1) (by omega) (by omega)
      simp only [gm 0 h, decide_eq_true_eq]; linarith
    · intro i hi; omega
  rcases (show j = a.length ∨ j < a.length by omega) with hL | hL
  · -- above the last knot
    have hxL := hbelow (a.length - 1) (by omega)
    have e1 : min j (a.length - 1) = a.length - 1 := by omega
    have e2 : j - 1 = a.length - 1 := by omega
    rw [e1, e2]
    have : ¬ (a.getD (a.length - 1) 0 - x < x - a.getD (a.length - 1) 0) ∨ True := Or.inr trivial
    have hres : (if a.getD (a.length - 1) 0 - x < x - a.getD (a.length - 1) 0
        then a.length - 1 else a.length - 1) = a.length - 1 := by split_ifs <;> rfl
    rw [hres]
    apply findIdx_eq_of (by omega)
    · intro h; omega
    · intro i hi
      have := pw_getD_le hr (i := i + 1) (j := a.length - 1) (by omega) (by omega)
      have h2 := pw_getD_lt hr (i := i) (j := i + 1) (by omega) (by omega)
      simp only [gm i (by omega), decide_eq_false_iff_not, not_le]
      linarith
  · -- in the cell (j − 1, j)
    have e1 : min j (a.length - 1) = j := by omega
    rw [e1]
    have hxj := hat hL
    have hxl := hbelow (j - 1) (by omega)
    have ej : j - 1 + 1 = j := by omega
    have hneg : ∀ i (h : i < j - 1), decide (x ≤ (midsR a)[i]'(by omega)) = false := by
      intro i hi
      have := pw_getD_le hr (i := i + 1) (j := j - 1) (by omega) (by omega)
      have h2 := pw_getD_lt hr (i := i) (j := i + 1) (by omega) (by omega)
      simp only [gm i (by omega), decide_eq_false_iff_not, not_le]
      linarith
    split_ifs with hc
    · apply findIdx_eq_of (by omega)
      · intro h
        have := pw_getD_lt hr (i := j) (j := j + 1) (by omega) (by omega)
        simp only [gm j h, decide_eq_true_eq]; linarith
      · intro i hi
        rcases (show i < j - 1 ∨ i = j - 1 by omega) with h | h
        · exact hneg i h
        · subst h
          simp only [gm (j - 1) (by omega), ej, decide_eq_false_iff_not, not_le]
          linarith
    · apply findIdx_eq_of (by omega)
      · intro h
        simp only [gm (j - 1) h, ej, decide_eq_true_eq]
        linarith
      · exact hneg

theorem indexVal_ofVec (v : List Num) (k : ℕ) (hk1 : 1 ≤ k) (hk2 : k ≤ v.length) :
    indexVal (.arr (ofVec v)) (.num (.fin (k : ℝ))) = .ok (.num (v.getD (k - 1) .nan)) := by
  have hlt : k - 1 < v.length := by omega
  have hlt' : k - 1 < (v.map Nested.leaf).length := by simpa using hlt
  simp only [ofVec, indexVal, Nat.floor_natCast, List.length_map, hk1, hk2, and_self,
    ↓reduceIte, List.getD_eq_getElem _ _ hlt', List.getElem_map, List.getD_eq_getElem _ _ hlt]

theorem ev_const_arr (tables : List (String × FTable)) (env : String → Num) (l : List Num) :
    eval tables env (.const (ofVec l)) = .ok (.arr (ofVec l)) := by
  rw [eval]; exact fun _ h => by cases h

theorem ev_lit (tables : List (String × FTable)) (env : String → Num) (v : Num) :
    eval tables env (.lit v) = .ok (.num v) := by rw [eval]

theorem ev_sub (tables : List (String × FTable)) (env : String → Num)
    (a b : Expr) (u v : Num) (ha : eval tables env a = .ok (.num u))
    (hb : eval tables env b = .ok (.num v)) :
    eval tables env (.op "-" [a, b]) = .ok (.num (Scalar.sub u v)) := by
  rw [eval, evalOp]
  simp only [ha, hb, bind, Except.bind, Val.asNum, pure, Except.pure]

theorem ev_lt (tables : List (String × FTable)) (env : String → Num)
    (a b : Expr) (u v : Num) (ha : eval tables env a = .ok (.num u))
    (hb : eval tables env b = .ok (.num v)) :
    eval tables env (.op "<" [a, b]) = .ok (.num (Num.ofBool (Scalar.lt u v))) := by
  rw [eval, evalOp]
  simp only [ha, hb, bind, Except.bind, Val.asNum, pure, Except.pure]

theorem ev_beq (tables : List (String × FTable)) (env : String → Num)
    (a b : Expr) (u v : Num) (ha : eval tables env a = .ok (.num u))
    (hb : eval tables env b = .ok (.num v)) :
    eval tables env (.op "==" [a, b]) = .ok (.num (Num.ofBool (Num.beq u v))) := by
  rw [eval, evalOp]
  simp only [ha, hb, bind, Except.bind, Val.asNum, pure, Except.pure]

theorem ev_max (tables : List (String × FTable)) (env : String → Num)
    (a b : Expr) (u v : Num) (ha : eval tables env a = .ok (.num u))
    (hb : eval tables env b = .ok (.num v)) :
    eval tables env (.op "max" [a, b]) = .ok (.num (Num.max u v)) := by
  rw [eval, evalOp]
  simp only [ha, hb, bind, Except.bind, Val.asNum, pure, Except.pure]

theorem ev_min (tables : List (String × FTable)) (env : String → Num)
    (a b : Expr) (u v : Num) (ha : eval tables env a = .ok (.num u))
    (hb : eval tables env b = .ok (.num v)) :
    eval tables env (.op "min" [a, b]) = .ok (.num (Num.min u v)) := by
  rw [eval, evalOp]
  simp only [ha, hb, bind, Except.bind, Val.asNum, pure, Except.pure]

theorem ev_ifelse (tables : List (String × FTable)) (env : String → Num) (c a b : Expr) (cv : Num)
    (hc : eval tables env c = .ok (.num cv)) :
    eval tables env (.op "ifelse" [c, a, b]) =
      if Num.truthy cv then eval tables env a else eval tables env b := by
  rw [eval, evalOp]
  simp only [hc, bind, Except.bind, Val.asNum]

theorem ev_index_vec (tables : List (String × FTable)) (env : String → Num) (l : List Num)
    (ie : Expr) (k : ℕ) (hi : eval tables env ie = .ok (.num (.fin (k : ℝ))))
    (hk1 : 1 ≤ k) (hk2 : k ≤ l.length) :
    eval tables env (.index [.const (ofVec l), ie]) = .ok (.num (l.getD (k - 1) .nan)) := by
  rw [eval, evalIndex, ev_const_arr, hi]
  simp only [bind, Except.bind]
  exact indexVal_ofVec l k hk1 hk2

theorem ev_searchsorted (tables : List (String × FTable)) (env : String → Num) (r : List ℝ)
    (hr : r.Pairwise (· < ·)) (xe : Expr) (x0 : Num)
    (hx : eval tables env xe = .ok (.num x0)) :
    eval tables env (.fn "interp.searchsorted" [xe, .const (ofVec (r.map Num.fin))]) =
      .ok (.num (.fin (searchsorted x0 (r.map Num.fin) : ℝ))) := by
  rw [eval, evalFn]
  simp only [argOf, argOfNested_ofVec,
    validateSearchsorted_eq r (hr.imp (fun h => le_of_lt h)), bind, Except.bind, hx, Val.asNum,
    pure, Except.pure]

/-- The §9.5.3 `nearest` tree, evaluated with EXACT arithmetic, is the
nearest knot's value (ties low, clamped), and NaN for a NaN query. -/
theorem eval_nearest_lowered (tables : List (String × FTable)) (env : String → Num)
    (v : List Num) (r0 : List ℝ) (hpw : r0.Pairwise (· < ·)) (hlen : 2 ≤ r0.length)
    (hv : v.length = r0.length) (xe : Expr) (x0 : Num)
    (hx : eval tables env xe = .ok (.num x0)) :
    eval tables env (nearestTree (ofVec v) (r0.map Num.fin) xe) =
      .ok (.num (nearest v (r0.map Num.fin) x0)) := by
  unfold nearestTree
  simp only
  have hsr := ev_searchsorted tables env r0 hpw xe x0 hx
  cases x0 with
  | nan =>
    have hq := ev_beq tables env xe xe _ _ hx hx
    simp only [Num.beq] at hq
    rw [ev_ifelse _ _ _ _ _ _ hq]
    simp [Num.ofBool, Num.truthy, hx, nearest]
  | fin x =>
    have hq := ev_beq tables env xe xe _ _ hx hx
    simp only [Num.beq, decide_true] at hq
    rw [ev_ifelse _ _ _ _ _ _ hq]
    simp only [Num.ofBool, Num.truthy, ↓reduceIte, ne_eq, one_ne_zero, not_false_eq_true,
      decide_true]
    rw [searchsorted_fin_map] at hsr
    set j := r0.findIdx (fun m => decide (x ≤ m)) with hj
    have hjle : j ≤ r0.length := List.findIdx_le_length
    -- lo and hi, as 1-based indices
    have hlo := ev_max tables env _ (.lit (.fin 1)) _ _
      (ev_sub tables env _ (.lit (.fin 1)) _ _ hsr (ev_lit _ _ _)) (ev_lit _ _ _)
    simp only [Num.sub_fin, Num.max] at hlo
    have hhi := ev_min tables env _ (.lit (.fin ((r0.map Num.fin).length : ℝ))) _ _ hsr
      (ev_lit _ _ _)
    simp only [Num.min] at hhi
    have elo : Max.max ((((j + 1 : ℕ)) : ℝ) - 1) 1 = (((j - 1 + 1 : ℕ)) : ℝ) := by
      rcases Nat.eq_zero_or_pos j with h | h
      · rw [h]; norm_num
      · rw [show j - 1 + 1 = j by omega]
        have h1 : (1 : ℝ) ≤ j := by exact_mod_cast h
        rw [show (((j + 1 : ℕ)) : ℝ) - 1 = j by push_cast; ring]
        exact max_eq_left h1
    have ehi : Min.min (((j + 1 : ℕ)) : ℝ) ((r0.map Num.fin).length : ℝ) =
        (((min j (r0.length - 1) + 1 : ℕ)) : ℝ) := by
      rw [List.length_map, ← Nat.cast_min]
      congr 1; omega
    rw [elo] at hlo
    rw [ehi] at hhi
    have hlen' : (r0.map Num.fin).length = r0.length := List.length_map _
    have hAhi := ev_index_vec tables env (r0.map Num.fin) _ _ hhi (by omega) (by omega)
    have hAlo := ev_index_vec tables env (r0.map Num.fin) _ _ hlo (by omega) (by omega)
    rw [Nat.add_sub_cancel, getD_map_fin (show min j (r0.length - 1) < r0.length by omega)] at hAhi
    rw [Nat.add_sub_cancel, getD_map_fin (show j - 1 < r0.length by omega)] at hAlo
    have hd1 := ev_sub tables env _ _ _ _ hAhi hx
    have hd2 := ev_sub tables env _ _ _ _ hx hAlo
    simp only [Num.sub_fin] at hd1 hd2
    have hcmp := ev_lt tables env _ _ _ _ hd1 hd2
    simp only [Num.lt_fin] at hcmp
    have hbr := ev_ifelse tables env _ (Expr.op "min" [Expr.fn "interp.searchsorted"
        [xe, Expr.const (ofVec (List.map Num.fin r0))],
        Expr.lit (Num.fin ((List.map Num.fin r0).length : ℝ))])
      (Expr.op "max" [Expr.op "-" [Expr.fn "interp.searchsorted"
        [xe, Expr.const (ofVec (List.map Num.fin r0))], Expr.lit (Num.fin 1)],
        Expr.lit (Num.fin 1)]) _ hcmp
    rw [hhi, hlo] at hbr
    have hres := nearestIdx_bracket r0 hpw hlen x
    rw [← hj] at hres
    simp only [nearest, map_re_fin, hres]
    by_cases hc : r0.getD (min j (r0.length - 1)) 0 - x < x - r0.getD (j - 1) 0
    · simp only [Num.ofBool, hc, decide_true, Num.truthy, ↓reduceIte, ne_eq, one_ne_zero,
        not_false_eq_true] at hbr
      rw [ev_index_vec tables env v _ _ hbr (by omega) (by omega), Nat.add_sub_cancel, if_pos hc]
    · simp only [Num.ofBool, hc, decide_false, Num.truthy, Bool.false_eq_true, ↓reduceIte, ne_eq,
        not_true_eq_false, decide_true, Decidable.not_not] at hbr
      rw [ev_index_vec tables env v _ _ hbr (by omega) (by omega), Nat.add_sub_cancel, if_neg hc]

/-- The lowered tree computes `lookupCore` on the inputs evaluated in table
axis order. -/
theorem lower_eval_core (tables : List (String × FTable)) (env : String → Num) (tid : String)
    (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr) (e : Expr)
    (T : FTable) (s : Nested) (vals : List (String × Num))
    (hl : lower tables tid axes out args = .ok e)
    (hp : prepLookup tables tid (axes.map Prod.fst) out args = .ok (T, s))
    (hvals : evalAxes tables env axes = .ok vals)
    (hlk : ∀ k e, axes.lookup k = some e →
      ∃ v, eval tables env e = .ok (.num v) ∧ vals.lookup k = some v) :
    eval tables env e =
      (do
        let xs ← T.axes.mapM (fun a => match vals.lookup a.name with
          | some v => .ok v
          | none => .error Codes.lookupAxisNameMismatch)
        let r ← lookupCore T s xs
        return Val.num r) := by
    unfold lower at hl
    rw [hp] at hl
    simp only [bind, Except.bind] at hl
    obtain ⟨hargs, hT, hv, hkeys, o, ho, hs⟩ := prepLookup_ok hp
    have hax := validateTable_axes hv
    have har := validateTable_arity hv
    have hsh := slice_shape hv ho
    rw [← hs] at hsh
    have hinp := fun a (ha : a ∈ T.axes) => axis_input hkeys hlk ha
    unfold lookupCore
    cases hm : T.interpolation <;> rw [hm] at hl har <;>
      rcases hA : T.axes with _ | ⟨a0, _ | ⟨a1, _ | ⟨a2, rest⟩⟩⟩ <;>
      rw [hA] at hl har <;> simp [FTable.arityOk] at har <;> simp only [pure, Except.pure] at hl <;>
      cases hl
    · -- linear
      have ha0 := hax a0 (by rw [hA]; simp)
      obtain ⟨r0, hr0, hpw0, hlen0⟩ := ha0
      obtain ⟨v0, hv0, hvl0⟩ := hinp a0 (by rw [hA]; simp)
      rw [FTable.axesShape, hA] at hsh
      obtain ⟨v, rfl, hvlen⟩ := hasShape_one hsh
      replace hvlen : v.length = r0.length := by simpa [hr0] using hvlen
      rw [hr0]
      simp only [List.mapM_cons, List.mapM_nil, hvl0, bind, Except.bind, pure, Except.pure,
        toVec_ofVec]
      rw [eval, evalFn]
      simp only [argOf, argOfNested_ofVec, validateLinear_eq v r0 (by simpa using hvlen) hlen0 hpw0,
        bind, Except.bind, hv0, Val.asNum, pure, Except.pure]
      rw [hr0]
    · -- bilinear
      obtain ⟨r0, hr0, hpw0, hlen0⟩ := hax a0 (by rw [hA]; simp)
      obtain ⟨r1, hr1, hpw1, hlen1⟩ := hax a1 (by rw [hA]; simp)
      obtain ⟨v0, hv0, hvl0⟩ := hinp a0 (by rw [hA]; simp)
      obtain ⟨v1, hv1, hvl1⟩ := hinp a1 (by rw [hA]; simp)
      rw [FTable.axesShape, hA] at hsh
      obtain ⟨M, rfl, hMlen, hMrow⟩ := hasShape_two hsh
      obtain ⟨row, M', rfl⟩ : ∃ row M', M = row :: M' := by
        cases M with
        | nil => simp [hr0] at hMlen; omega
        | cons row M' => exact ⟨row, M', rfl⟩
      simp only [List.mapM_cons, List.mapM_nil, hvl0, hvl1, bind, Except.bind, pure, Except.pure,
        toMat_ofMat]
      rw [eval, evalFn]
      replace hMlen : (row :: M').length = r0.length := by simpa [hr0] using hMlen
      replace hMrow : ∀ x ∈ row :: M', x.length = r1.length := by simpa [hr1] using hMrow
      rw [hr0, hr1]
      simp only [argOf, argOfNested_ofMat, argOfNested_ofVec,
        validateBilinear_eq (row :: M') r0 r1 (by simpa using hMlen) (by simpa using hMrow)
          hlen0 hlen1 hpw0 hpw1,
        bind, Except.bind, hv0, hv1, Val.asNum, pure, Except.pure]
    · -- nearest
      obtain ⟨r0, hr0, hpw0, hlen0⟩ := hax a0 (by rw [hA]; simp)
      obtain ⟨v0, hv0, hvl0⟩ := hinp a0 (by rw [hA]; simp)
      rw [FTable.axesShape, hA] at hsh
      obtain ⟨v, rfl, hvlen⟩ := hasShape_one hsh
      replace hvlen : v.length = r0.length := by simpa [hr0] using hvlen
      rw [hr0]
      simp only [List.mapM_cons, List.mapM_nil, hvl0, bind, Except.bind, pure, Except.pure,
        toVec_ofVec]
      rw [hr0]
      exact eval_nearest_lowered tables env v r0 hpw0 hlen0 (by simpa using hvlen) _ v0 hv0

/-- §9.5 / §9.5.3: for `out_of_bounds: "clamp"`, evaluating the lowered tree
equals evaluating the `table_lookup` node, for every interpolation method,
whenever the lookup lowers (every load-time check passed) and its axis inputs
evaluate to scalars. -/
theorem lower_eval (tables : List (String × FTable)) (env : String → Num) (tid : String)
    (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr) (e : Expr)
    (hl : lower tables tid axes out args = .ok e)
    (hin : ∀ p ∈ axes, ∃ v, eval tables env p.2 = .ok (.num v))
    (hclamp : ∀ T, tables.lookup tid = some T → T.outOfBounds = .clamp) :
    eval tables env e = eval tables env (.lookup tid axes out args) := by
  cases hp : prepLookup tables tid (axes.map Prod.fst) out args with
  | error c => unfold lower at hl; rw [hp] at hl; cases hl
  | ok Ts =>
    obtain ⟨T, s⟩ := Ts
    obtain ⟨-, hT, -⟩ := prepLookup_ok hp
    obtain ⟨vals, hvals, hlk⟩ := evalAxes_ok tables env axes hin
    rw [eval_lookup_prep hp hvals, lower_eval_core tables env tid axes out args e T s vals hl hp hvals hlk]
    unfold lookupValue
    rw [hclamp T hT]
    simp only [reduceCtorEq, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte]

/-- §9.5.3a, for a binding that implements `out_of_bounds: "error"` (the model
does): with `xs` the axis inputs in table order, the lookup raises
`table_lookup_out_of_bounds` exactly when some input is strictly outside its
axis, and otherwise equals the lowered (clamp) tree. -/
theorem lookup_error_mode (tables : List (String × FTable)) (env : String → Num) (tid : String)
    (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr) (e : Expr)
    (hl : lower tables tid axes out args = .ok e)
    (hin : ∀ p ∈ axes, ∃ v, eval tables env p.2 = .ok (.num v)) :
    ∃ T xs, tables.lookup tid = some T ∧
      T.axes.mapM (fun a => do
        (← eval tables env ((axes.lookup a.name).getD (.lit .nan))).asNum) = .ok xs ∧
      eval tables env (.lookup tid axes out args) =
        (if T.outOfBounds = .error && anyOutside T xs then .error Codes.lookupOutOfBounds
         else eval tables env e) := by
  cases hp : prepLookup tables tid (axes.map Prod.fst) out args with
  | error c => unfold lower at hl; rw [hp] at hl; cases hl
  | ok Ts =>
    obtain ⟨T, s⟩ := Ts
    obtain ⟨-, hT, -, hkeys, -⟩ := prepLookup_ok hp
    obtain ⟨vals, hvals, hlk⟩ := evalAxes_ok tables env axes hin
    -- the inputs, in table order
    have key : ∀ (L : List Axis), (∀ a ∈ L, a ∈ T.axes) →
        ∃ xs, L.mapM (fun a => match vals.lookup a.name with
            | some v => .ok v
            | none => .error Codes.lookupAxisNameMismatch) = (.ok xs : Except Code (List Num)) ∧
          L.mapM (fun a => do
            (← eval tables env ((axes.lookup a.name).getD (.lit .nan))).asNum) = .ok xs := by
      intro L hL
      induction L with
      | nil => exact ⟨[], rfl, rfl⟩
      | cons a L ih =>
        obtain ⟨xs, h1, h2⟩ := ih (fun b hb => hL b (by simp [hb]))
        obtain ⟨v, hv, hvl⟩ := axis_input hkeys hlk (hL a (by simp))
        refine ⟨v :: xs, ?_, ?_⟩
        · simp only [List.mapM_cons, hvl, h1]; rfl
        · rw [List.mapM_cons, h2]; simp only [hv, bind, Except.bind, Val.asNum]; rfl
    obtain ⟨xs, h1, h2⟩ := key T.axes (fun a ha => ha)
    refine ⟨T, xs, hT, h2, ?_⟩
    rw [eval_lookup_prep hp hvals, lower_eval_core tables env tid axes out args e T s vals hl hp hvals hlk,
      h1]
    simp only [bind, Except.bind]
    unfold lookupValue
    split_ifs <;> rfl

/-- §9.5.3a: `outside` is "strictly below the first knot or strictly above the
last"; a NaN query is never outside. -/
theorem outside_spec (r : List ℝ) (hn : 1 ≤ r.length) (x : ℝ) :
    outside (r.map Num.fin) (Num.fin x) = true ↔ x < r.getD 0 0 ∨ r.getD (r.length - 1) 0 < x := by
  simp only [outside, List.length_map, getD_map_fin (show 0 < r.length by omega),
    getD_map_fin (show r.length - 1 < r.length by omega), Num.lt_fin, Bool.or_eq_true,
    decide_eq_true_eq]

theorem outside_nan (ax : List Num) : outside ax Num.nan = false := by
  simp [outside]

/-! ## Load-time checks of `function_tables` and `table_lookup` -/

/-- The conditions §9.5.1 puts on a table (with Q-9: finite data). -/
def TableValid (T : FTable) : Prop :=
  (T.axes.map (·.name)).Nodup ∧ (∀ os, T.outputs = some os → os.Nodup) ∧
    FTable.arityOk T.interpolation T.axes.length = true ∧
    (∀ a ∈ T.axes, ∃ r : List ℝ, a.values = r.map Num.fin ∧ r.Pairwise (· < ·) ∧ 2 ≤ r.length) ∧
    T.data.hasShape T.expectedShape = true ∧ T.data.anyNaN = false ∧
    (∀ sh, T.shape = some sh → sh = T.expectedShape)

/-- §9.5.1/§9.5.5: a table loads iff it satisfies every condition. -/
theorem validateTable_ok_iff (T : FTable) : validateTable T = .ok () ↔ TableValid T := by
  constructor
  · intro h
    have hax := validateTable_axes h
    have har := validateTable_arity h
    obtain ⟨hsh, hnan⟩ := validateTable_shape h
    unfold validateTable at h
    split_ifs at h with h1 h2 h3 h4 h5 h6 h7 h8 h9 h10
    refine ⟨by simpa using h1, ?_, har, hax, hsh, hnan, ?_⟩
    · intro os hos
      simp only [FTable.outputsDup, hos, Bool.not_eq_true', decide_eq_false_iff_not,
        Decidable.not_not] at h2
      simpa using h2
    · intro sh hsh'
      simp only [FTable.shapeAssertionWrong, hsh', bne_iff_ne, ne_eq, Decidable.not_not] at h10
      exact h10
  · rintro ⟨h1, h2, h3, h4, h5, h6, h7⟩
    have c2 : T.outputsDup = false := by
      unfold FTable.outputsDup
      cases ho : T.outputs with
      | none => rfl
      | some os => simpa using h2 os ho
    have c4 : T.axes.any (fun a => anyNaN a.values) = false := by
      rw [List.any_eq_false]; intro a ha
      obtain ⟨r, hr, -, -⟩ := h4 a ha
      rw [hr]; simp [(anyNaN_false_iff _).mpr ⟨r, rfl⟩]
    have c5 : T.axes.any (fun a => !adjAll Scalar.lt a.values) = false := by
      rw [List.any_eq_false]; intro a ha
      obtain ⟨r, hr, hp, -⟩ := h4 a ha
      rw [hr, (adjAll_lt_iff r).mpr hp]; simp
    have c6 : T.axes.any (fun a => decide (a.values.length < 2)) = false := by
      rw [List.any_eq_false]; intro a ha
      obtain ⟨r, hr, -, hl⟩ := h4 a ha
      rw [hr]; simp; omega
    have c7 : T.outputsMismatch = false := by
      unfold FTable.outputsMismatch
      unfold FTable.expectedShape at h5
      cases ho : T.outputs with
      | none => rfl
      | some os =>
        rw [ho] at h5
        cases hd : T.data with
        | leaf _ => rfl
        | node xs =>
          rw [hd] at h5
          simp only [Nested.hasShape, Bool.and_eq_true, beq_iff_eq] at h5
          simp [h5.1]
    have c10 : T.shapeAssertionWrong = false := by
      unfold FTable.shapeAssertionWrong
      cases hs : T.shape with
      | none => rfl
      | some sh => simp [h7 sh hs]
    simp [validateTable, h1, c2, h3, c4, c5, c6, c7, h5, h6, c10]

/-- Q-4 (`table_axis_nan` before `table_axis_non_monotonic`): once the name and
arity checks pass, a NaN in any axis is reported as `table_axis_nan`. -/
theorem validateTable_nan_precedence (T : FTable) (h1 : (T.axes.map (·.name)).Nodup)
    (h2 : ∀ os, T.outputs = some os → os.Nodup)
    (h3 : FTable.arityOk T.interpolation T.axes.length = true)
    (hn : ∃ a ∈ T.axes, ∃ x ∈ a.values, x.isNaN = true) :
    validateTable T = .error "table_axis_nan" := by
  have c2 : T.outputsDup = false := by
    unfold FTable.outputsDup
    cases ho : T.outputs with
    | none => rfl
    | some os => simpa using h2 os ho
  have c4 : T.axes.any (fun a => anyNaN a.values) = true := by
    obtain ⟨a, ha, hx⟩ := hn
    exact List.any_eq_true.mpr ⟨a, ha, (anyNaN_true_iff _).mpr hx⟩
  simp [validateTable, h1, c2, h3, c4, Codes.axisNaN]

/-- §9.5.5: every rejection of a table names a violated condition. -/
theorem validateTable_code_sound (T : FTable) (c : Code) (h : validateTable T = .error c) :
    (c = "table_axis_duplicate_name" ∧ ¬ (T.axes.map (·.name)).Nodup) ∨
    (c = "table_outputs_duplicate_name" ∧ ∃ os, T.outputs = some os ∧ ¬ os.Nodup) ∨
    (c = "table_interpolation_axes_mismatch" ∧
      FTable.arityOk T.interpolation T.axes.length = false) ∨
    (c = "table_axis_nan" ∧ ∃ a ∈ T.axes, ∃ x ∈ a.values, x.isNaN = true) ∨
    (c = "table_axis_non_monotonic" ∧
      ∃ a ∈ T.axes, ∃ r : List ℝ, a.values = r.map Num.fin ∧ ¬ r.Pairwise (· < ·)) ∨
    (c = "unspecified:table_axis_too_short" ∧ ∃ a ∈ T.axes, a.values.length < 2) ∨
    (c = "table_outputs_length_mismatch" ∧
      ∃ os xs, T.outputs = some os ∧ T.data = .node xs ∧ xs.length ≠ os.length) ∨
    (c = "table_data_shape_mismatch" ∧
      (T.data.hasShape T.expectedShape = false ∨ ∃ sh, T.shape = some sh ∧ sh ≠ T.expectedShape)) ∨
    (c = "table_data_nan" ∧ T.data.anyNaN = true) := by
  unfold validateTable at h
  split_ifs at h with h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 <;>
    simp only [Except.error.injEq] at h <;> subst h
  · left; exact ⟨rfl, by simpa using h1⟩
  · right; left
    refine ⟨rfl, ?_⟩
    unfold FTable.outputsDup at h2
    cases ho : T.outputs with
    | none => rw [ho] at h2; simp at h2
    | some os => rw [ho] at h2; exact ⟨os, rfl, by simpa using h2⟩
  · right; right; left; exact ⟨rfl, by simpa using h3⟩
  · right; right; right; left
    refine ⟨rfl, ?_⟩
    obtain ⟨a, ha, hx⟩ := List.any_eq_true.mp h4
    exact ⟨a, ha, (anyNaN_true_iff _).mp hx⟩
  · right; right; right; right; left
    refine ⟨rfl, ?_⟩
    obtain ⟨a, ha, hx⟩ := List.any_eq_true.mp h5
    simp only [List.any_eq_true, not_exists, not_and, Bool.not_eq_true] at h4
    obtain ⟨r, hr⟩ := (anyNaN_false_iff _).mp (h4 a ha)
    refine ⟨a, ha, r, hr, fun hp => ?_⟩
    rw [hr, (adjAll_lt_iff r).mpr hp] at hx; simp at hx
  · right; right; right; right; right; left
    refine ⟨rfl, ?_⟩
    obtain ⟨a, ha, hx⟩ := List.any_eq_true.mp h6
    exact ⟨a, ha, by simpa using hx⟩
  · right; right; right; right; right; right; left
    refine ⟨rfl, ?_⟩
    unfold FTable.outputsMismatch at h7
    cases ho : T.outputs with
    | none => rw [ho] at h7; simp at h7
    | some os =>
      rw [ho] at h7
      cases hd : T.data with
      | leaf _ => rw [hd] at h7; simp at h7
      | node xs => rw [hd] at h7; exact ⟨os, xs, rfl, rfl, by simpa using h7⟩
  · right; right; right; right; right; right; right; left
    exact ⟨rfl, Or.inl (by simpa using h8)⟩
  · right; right; right; right; right; right; right; right
    exact ⟨rfl, h9⟩
  · right; right; right; right; right; right; right; left
    refine ⟨rfl, Or.inr ?_⟩
    unfold FTable.shapeAssertionWrong at h10
    cases hs : T.shape with
    | none => rw [hs] at h10; simp at h10
    | some sh => rw [hs] at h10; exact ⟨sh, rfl, by simpa using h10⟩

/-- Q-11: a `table_lookup` with non-empty `args` is `table_lookup_args_nonempty`. -/
theorem lookup_args_nonempty (tables : List (String × FTable)) (env : String → Num)
    (tid : String) (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr)
    (h : args ≠ []) :
    eval tables env (.lookup tid axes out args) = .error "table_lookup_args_nonempty" := by
  have : args.isEmpty = false := by simpa using h
  rw [eval]
  simp [prepLookup, this, Codes.lookupArgsNonempty, bind, Except.bind]

/-- §9.5.2: a reference to an undeclared table is `table_lookup_unknown_table`. -/
theorem lookup_unknown_table (tables : List (String × FTable)) (env : String → Num)
    (tid : String) (axes : List (String × Expr)) (out : Option OutSel)
    (h : tables.lookup tid = none) :
    eval tables env (.lookup tid axes out []) = .error "table_lookup_unknown_table" := by
  rw [eval]
  simp [prepLookup, h, Codes.lookupUnknownTable, bind, Except.bind]

/-- §9.5.2: on a valid table, axis keys that are not exactly its axis names are
`table_lookup_axis_name_mismatch`. -/
theorem lookup_axis_mismatch (tables : List (String × FTable)) (env : String → Num)
    (tid : String) (axes : List (String × Expr)) (out : Option OutSel) (T : FTable)
    (hT : tables.lookup tid = some T) (hv : validateTable T = .ok ())
    (hk : ¬ (∀ k, k ∈ axes.map Prod.fst ↔ k ∈ T.axes.map (·.name))) :
    eval tables env (.lookup tid axes out []) = .error "table_lookup_axis_name_mismatch" := by
  have : keysMatch (axes.map Prod.fst) (T.axes.map (·.name)) = false := by
    cases e : keysMatch (axes.map Prod.fst) (T.axes.map (·.name))
    · rfl
    · exfalso; apply hk; intro k
      simp only [keysMatch, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at e
      exact ⟨fun h => e.1 k h, fun h => e.2 k h⟩
  rw [eval]
  simp [prepLookup, hT, hv, this, Codes.lookupAxisNameMismatch, bind, Except.bind]

/-- §9.5.2 with Q-12: an omitted `output` is output 0, whether or not `outputs`
is declared. -/
theorem resolveOutput_omitted (T : FTable) : resolveOutput T none = resolveOutput T (some (.idx 0)) :=
  rfl

/-- §9.5.2 with Q-10: without `outputs` the table has the one output 0. -/
theorem resolveOutput_single (T : FTable) (h : T.outputs = none) (n : ℕ) (s : String) :
    (resolveOutput T (some (.idx n)) = if n = 0 then .ok 0 else .error "table_lookup_output_out_of_range") ∧
      resolveOutput T (some (.name s)) = .error "table_lookup_output_out_of_range" := by
  simp [resolveOutput, resolveIdx, h, Codes.lookupOutputOutOfRange]

/-- §9.5.2 with `outputs` declared: an integer must be `< len(outputs)`, a
string must be one of them (its position); otherwise
`table_lookup_output_out_of_range`. -/
theorem resolveOutput_multi (T : FTable) (os : List String) (h : T.outputs = some os) (n : ℕ)
    (s : String) :
    (resolveOutput T (some (.idx n)) =
        if n < os.length then .ok n else .error "table_lookup_output_out_of_range") ∧
      (s ∉ os → resolveOutput T (some (.name s)) = .error "table_lookup_output_out_of_range") ∧
      (∀ i (hi : i < os.length), os[i] = s → (∀ j (hj : j < i), os[j] ≠ s) →
        resolveOutput T (some (.name s)) = .ok i) := by
  refine ⟨by simp [resolveOutput, resolveIdx, h, Codes.lookupOutputOutOfRange], ?_, ?_⟩
  · intro hs
    have : findName s os = none := by
      clear h
      induction os with
      | nil => rfl
      | cons o os ih =>
        simp only [List.mem_cons, not_or] at hs
        simp only [findName, show ¬ o = s from fun e => hs.1 e.symm, ↓reduceIte, ih hs.2,
          Option.map_none]
    simp [resolveOutput, h, this, Codes.lookupOutputOutOfRange]
  · intro i hi hs hlt
    have : findName s os = some i := by
      clear h
      induction os generalizing i with
      | nil => simp at hi
      | cons o os ih =>
        cases i with
        | zero => simp only [List.getElem_cons_zero] at hs; simp [findName, hs]
        | succ i =>
          have ho : ¬ o = s := hlt 0 (by omega)
          simp only [findName, ho, ↓reduceIte]
          rw [ih i (by simpa using hi) (by simpa using hs)
            (fun j hj => by simpa using hlt (j + 1) (by omega))]
          rfl
    simp [resolveOutput, h, this]

/-! ## The spec's current `nearest` lowering is not nearest (Q-13) -/

/-- The §9.5.3 lowering as the spec text currently writes it:
`index(data, searchsorted(x, axis))`, claimed to return the nearest knot's value. -/
def SpecNearestLowering : Prop :=
  ∀ (v : List Num) (r : List ℝ) (x : ℝ), r.Pairwise (· < ·) → 2 ≤ r.length →
    v.length = r.length →
    eval [] (fun _ => Num.nan) (.index [.const (ofVec v),
      .fn "interp.searchsorted" [.lit (.fin x), .const (ofVec (r.map Num.fin))]]) =
      .ok (.num (nearest v (r.map Num.fin) (.fin x)))

/-- Refuted: on axis `[0, 10]` with data `[1, 2]`, the query `x = 1` is nearest
knot 0 (value 1), but `searchsorted` returns the first knot ≥ x, knot 1
(value 2). (Above the last knot it returns `N + 1`, an out-of-range index.) -/
theorem spec_nearest_lowering_refuted : ¬ SpecNearestLowering := by
  intro h
  have hpw : [(0 : ℝ), 10].Pairwise (· < ·) := by simp
  have hc := h [.fin 1, .fin 2] [0, 10] 1 hpw (by simp) rfl
  have hconst : eval [] (fun _ => Num.nan) (.const (ofVec [.fin 1, .fin 2])) =
      .ok (.arr (ofVec [.fin 1, .fin 2])) := by
    rw [eval]; exact fun _ h => by cases h
  rw [eval, evalIndex, hconst, eval, evalFn] at hc
  simp only [argOf, ofVec, argOfNested] at hc
  rw [show Nested.node (([(0 : ℝ), 10].map Num.fin).map Nested.leaf) =
      ofVec ([(0 : ℝ), 10].map Num.fin) from rfl, toVec_ofVec,
    validateSearchsorted_eq _ (by simp)] at hc
  simp only [bind, Except.bind, eval, Val.asNum, pure, Except.pure] at hc
  rw [searchsorted_fin_map] at hc
  have hf : [(0 : ℝ), 10].findIdx (fun m => decide ((1 : ℝ) ≤ m)) = 1 := by
    simp [List.findIdx_cons]
  rw [hf] at hc
  have hn : nearestIdx [(0 : ℝ), 10] 1 = 0 := by
    rw [← findIdx_midsR _ hpw (by simp)]
    simp [midsR, List.findIdx_cons]; norm_num
  rw [show Nested.node (List.map Nested.leaf [Num.fin 1, Num.fin 2]) = ofVec [Num.fin 1, Num.fin 2]
      from rfl, indexVal_ofVec _ 2 (by norm_num) (by simp)] at hc
  simp only [nearest, map_re_fin, hn] at hc
  simp only [Except.ok.injEq, Val.num.injEq] at hc
  simp at hc

end

end Esm.Closed.Tables
