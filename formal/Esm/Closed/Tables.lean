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
def prepLookup (tables : List (String × FTable)) (tid : String) (keys : List String)
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

/-- `interpolation: "nearest"` (Q-13). A NaN query has no ruling; the model
returns the last knot's value, which is what its lowering computes. -/
def nearest (v : List Num) (ax : List Num) : Num → Num
  | .fin x => v.getD (nearestIdx (ax.map Num.re) x) .nan
  | .nan => v.getD (ax.length - 1) .nan

/-- A query strictly outside an axis (`out_of_bounds: "error"`, §9.5.3a); a
NaN query is not out of bounds. -/
def outside (ax : List Num) (x : Num) : Bool :=
  Scalar.lt x (ax.getD 0 .nan) || Scalar.lt (ax.getD (ax.length - 1) .nan) x

/-- The value of a lookup on table `T`, data `s` (the output's slice), axis
inputs `xs` in the table's axis order. -/
def lookupValue (T : FTable) (s : Nested) (xs : List Num) : Except Code Num :=
  if T.outOfBounds = .error &&
      (List.zipWith (fun (a : Axis) x => outside a.values x) T.axes xs).any id then
    .error Codes.lookupOutOfBounds
  else
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

/-! ## Expressions -/

inductive Expr where
  | lit (v : Num)
  | var (n : String)
  | const (c : Nested)
  | fn (name : String) (args : List Expr)
  | index (args : List Expr)
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

/-- Midpoints of adjacent knots, the breakpoints of `nearest`. -/
def mids (l : List Num) : List Num :=
  List.zipWith (fun a b => Scalar.div (Scalar.add a b) (Num.fin 2)) l l.tail

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
  | .nearest, [a0] =>
    return .index [.const s,
      .fn "interp.searchsorted" [inp a0, .const (ofVec (mids a0.values))]]
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

end

end Esm.Closed.Tables
