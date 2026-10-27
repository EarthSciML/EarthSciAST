import Esm.Closed.Tables

/-!
# Checks at load: every table, every `interp.*` node (esm-spec §9.2, §9.5.5)

Rulings modelled (formal/QUESTIONS.md):

* Q-109: a NON-FINITE value (NaN, +Inf or −Inf) in a table axis is
  `table_axis_nan`, in `data` is `table_data_nan`.
* Q-106: the ten §9.5.5 table checks run at load on EVERY `function_tables`
  entry, whether or not a lookup references it, and the §9.2 argument checks run
  at load on EVERY `fn` node naming `interp.searchsorted` / `interp.linear` /
  `interp.bilinear`, wherever it appears, whether or not it is ever evaluated.

## Values as read

`Num` (§9.2's scalar) is a finite real or NaN; it has no infinities, and the
interpolation theorems need none. A table built in memory can hold ±Inf, so the
values a loader READS are `Lit`: a finite real, NaN, +Inf or −Inf. A table as
read is an `RTable` over its value type: `RTable Lit` for the exact model,
`RTable Float` for the `esm-lean tables` adapter, and `validateRaw` (the ten
checks, step 4 and step 9 testing finiteness) is written once for both.

Once a table passes, every value is finite (`validateRaw_ok_iff`), so the table
that LOADS is the `FTable` (over `Num`) `RTable.load` gives — the one lookups,
the lowering and evaluation use. `load` writes every non-finite value as
`Num.nan`; that is the only place the model identifies them, and
`validateRaw_eq` shows it does not change any verdict: `validateRaw R =
validateTable R.load`.

## The document

A `Doc` is the part of a loaded document these checks read: its
`function_tables` entries, as read, and every expression of every
expression-bearing field (§4.9.5), after the load-time rewrites (template
expansion, enum lowering — so a `fn` node from an expression-template body is
checked where the template is applied, ruling Q-106; the rewrites themselves
are phase 4). `loadCheck` checks every table (in document order), then every
node of every expression (`nodes`, each tree root first). Which code a document
with SEVERAL failures reports is not pinned by the spec; the model's choice
(tables first) is not a claim, and the properties below say only whether a
document loads.
-/

namespace Esm.Closed.Tables

open Esm.Closed

/-! ## Values as read -/

/-- A table value as a loader reads it: finite, NaN, or infinite (`inf false`
is +Inf, `inf true` is −Inf). -/
inductive Lit where
  | fin (r : ℝ)
  | nan
  | inf (neg : Bool)

namespace Lit

def isFinite : Lit → Bool
  | fin _ => true
  | _ => false

/-- IEEE-754 `<` on the extended reals; false whenever an operand is NaN. -/
noncomputable def lt : Lit → Lit → Bool
  | fin a, fin b => decide (a < b)
  | inf true, fin _ => true
  | inf true, inf false => true
  | fin _, inf false => true
  | _, _ => false

/-- The value a loaded table holds. Only finite values pass the checks; a
non-finite one is written `Num.nan` (never observed after a table loads). -/
def toNum : Lit → Num
  | fin r => .fin r
  | _ => .nan

end Lit

/-- What the §9.5.5 checks need of a table value: a finiteness test and `<`. -/
class TableValue (α : Type) where
  isFinite : α → Bool
  lt : α → α → Bool

noncomputable instance : TableValue Lit := ⟨Lit.isFinite, Lit.lt⟩

instance : TableValue Float := ⟨Float.isFinite, fun a b => a < b⟩

/-! ## Tables as read -/

/-- A nested `data` literal as read. -/
inductive RNested (α : Type) where
  | leaf (v : α)
  | node (xs : List (RNested α))

namespace RNested

variable {α : Type}

mutual
/-- The literal's nesting is exactly `shape` (as `Nested.hasShape`). -/
def hasShape : RNested α → List ℕ → Bool
  | .leaf _, [] => true
  | .node xs, n :: rest => (xs.length == n) && allShape xs rest
  | _, _ => false
def allShape : List (RNested α) → List ℕ → Bool
  | [], _ => true
  | x :: xs, s => hasShape x s && allShape xs s
end

mutual
/-- Some leaf satisfies `p`. -/
def anyLeaf (p : α → Bool) : RNested α → Bool
  | .leaf v => p v
  | .node xs => anyLeaves p xs
def anyLeaves (p : α → Bool) : List (RNested α) → Bool
  | [] => false
  | x :: xs => anyLeaf p x || anyLeaves p xs
end

mutual
/-- The literal with every leaf mapped to `Num`. -/
def toNested (f : α → Num) : RNested α → Nested
  | .leaf v => .leaf (f v)
  | .node xs => .node (toNesteds f xs)
def toNesteds (f : α → Num) : List (RNested α) → List Nested
  | [] => []
  | x :: xs => toNested f x :: toNesteds f xs
end

theorem length_toNesteds (f : α → Num) : ∀ xs : List (RNested α), (toNesteds f xs).length = xs.length
  | [] => rfl
  | _ :: xs => by simp [toNesteds, length_toNesteds f xs]

mutual
theorem hasShape_toNested (f : α → Num) :
    ∀ (d : RNested α) (sh : List ℕ), (toNested f d).hasShape sh = d.hasShape sh
  | .leaf _, [] => by simp [toNested, hasShape, Nested.hasShape]
  | .leaf _, _ :: _ => by simp [toNested, hasShape, Nested.hasShape]
  | .node _, [] => by simp [toNested, hasShape, Nested.hasShape]
  | .node xs, n :: rest => by
    simp only [toNested, hasShape, Nested.hasShape, length_toNesteds, allShape_toNesteds f xs rest]
theorem allShape_toNesteds (f : α → Num) :
    ∀ (xs : List (RNested α)) (sh : List ℕ), Nested.allShape (toNesteds f xs) sh = allShape xs sh
  | [], _ => by simp [toNesteds, allShape, Nested.allShape]
  | x :: xs, s => by
    simp only [toNesteds, allShape, Nested.allShape, hasShape_toNested f x s,
      allShape_toNesteds f xs s]
end

mutual
theorem anyNaN_toNested (f : α → Num) :
    ∀ d : RNested α, (toNested f d).anyNaN = d.anyLeaf (fun x => (f x).isNaN)
  | .leaf _ => by simp [toNested, anyLeaf, Nested.anyNaN]
  | .node xs => by simp only [toNested, anyLeaf, Nested.anyNaN, anyNaNs_toNesteds f xs]
theorem anyNaNs_toNesteds (f : α → Num) :
    ∀ xs : List (RNested α), Nested.anyNaNs (toNesteds f xs) = anyLeaves (fun x => (f x).isNaN) xs
  | [] => by simp [toNesteds, anyLeaves, Nested.anyNaNs]
  | x :: xs => by
    simp only [toNesteds, anyLeaves, Nested.anyNaNs, anyNaN_toNested f x, anyNaNs_toNesteds f xs]
end

end RNested

structure RAxis (α : Type) where
  name : String
  values : List α

/-- A `FunctionTable` (§9.5.1) as read, before its checks. -/
structure RTable (α : Type) where
  axes : List (RAxis α)
  interpolation : Method := .linear
  outOfBounds : OOB := .clamp
  outputs : Option (List String) := none
  data : RNested α
  shape : Option (List ℕ) := none

namespace RTable

variable {α : Type}

/-- §9.5.1: `[len(outputs), len(axes[0]), …]` with outputs, else the axes alone. -/
def expectedShape (R : RTable α) : List ℕ :=
  match R.outputs with
  | some os => os.length :: R.axes.map (·.values.length)
  | none => R.axes.map (·.values.length)

def outputsMismatch (R : RTable α) : Bool :=
  match R.outputs, R.data with
  | some os, .node xs => xs.length != os.length
  | _, _ => false

def shapeAssertionWrong (R : RTable α) : Bool :=
  match R.shape with
  | some s => s != R.expectedShape
  | none => false

def outputsDup (R : RTable α) : Bool :=
  match R.outputs with
  | some os => !decide os.Nodup
  | none => false

/-- The table that loads (every value finite once `validateRaw` passes). -/
def load (R : RTable Lit) : FTable where
  axes := R.axes.map (fun a => ⟨a.name, a.values.map Lit.toNum⟩)
  interpolation := R.interpolation
  outOfBounds := R.outOfBounds
  outputs := R.outputs
  data := R.data.toNested Lit.toNum
  shape := R.shape

end RTable

/-- Every adjacent pair is strictly increasing. -/
def chainLt {α : Type} [TableValue α] : List α → Bool
  | a :: b :: rest => TableValue.lt a b && chainLt (b :: rest)
  | _ => true

open RTable in
/-- The ten §9.5.5 table checks, in the pinned order, on a table as read
(Q-105, Q-109): step 4 is a non-finite axis value, step 9 a non-finite leaf of
`data`; each step covers every axis before the next. -/
def validateRaw {α : Type} [TableValue α] (R : RTable α) : Except Code Unit :=
  if !decide (R.axes.map (·.name)).Nodup then .error Codes.axisDuplicateName
  else if R.outputsDup then .error Codes.outputsDuplicateName
  else if !FTable.arityOk R.interpolation R.axes.length then
    .error Codes.interpolationAxesMismatch
  else if R.axes.any (fun a => a.values.any (fun x => !TableValue.isFinite x)) then
    .error Codes.axisNaN
  else if R.axes.any (fun a => !chainLt a.values) then .error Codes.axisNonMonotonic
  else if R.axes.any (fun a => decide (a.values.length < 2)) then .error Codes.axisTooShort
  else if R.outputsMismatch then .error Codes.outputsLengthMismatch
  else if !R.data.hasShape R.expectedShape then .error Codes.dataShapeMismatch
  else if R.data.anyLeaf (fun x => !TableValue.isFinite x) then .error Codes.dataNaN
  else if R.shapeAssertionWrong then .error Codes.dataShapeMismatch
  else .ok ()

/-! ## The checks on a table as read are the checks on the table that loads -/

section Bridge

theorem Lit.isNaN_toNum (x : Lit) : Scalar.isNaN x.toNum = !x.isFinite := by
  cases x <;> rfl

theorem Lit.isNaN_toNum' (x : Lit) : x.toNum.isNaN = !x.isFinite := by
  cases x <;> rfl

theorem Lit.toNum_eq_fin {x : Lit} {r : ℝ} : x.toNum = Num.fin r ↔ x = Lit.fin r := by
  cases x <;> simp [Lit.toNum]

theorem Lit.map_toNum_eq_fin {l : List Lit} {r : List ℝ} :
    l.map Lit.toNum = r.map Num.fin ↔ l = r.map Lit.fin := by
  induction l generalizing r with
  | nil => cases r <;> simp
  | cons x l ih =>
    cases r with
    | nil => simp
    | cons a r => simp [Lit.toNum_eq_fin, ih]

/-- On finite values, `<` on `Lit` is `<` on `Num`. -/
theorem chainLt_map_toNum (l : List Lit) (hl : ∀ x ∈ l, x.isFinite = true) :
    adjAll Scalar.lt (l.map Lit.toNum) = chainLt l := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    cases l with
    | nil => rfl
    | cons b l =>
      have ha := hl a (by simp)
      have hb := hl b (by simp)
      have ih' := ih (fun x hx => hl x (List.mem_cons_of_mem _ hx))
      cases a <;> cases b <;> simp_all [Lit.isFinite, adjAll, chainLt, Lit.toNum,
        TableValue.lt, Lit.lt]

theorem any_congr_mem {β : Type} {l : List β} {p q : β → Bool} (h : ∀ a ∈ l, p a = q a) :
    l.any p = l.any q := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.any_cons, h x (by simp), ih (fun a ha => h a (List.mem_cons_of_mem _ ha))]

variable (R : RTable Lit)

theorem load_names : (R.load.axes.map (·.name)) = R.axes.map (·.name) := by
  simp [RTable.load, Function.comp_def]

theorem load_axes_length : R.load.axes.length = R.axes.length := by
  simp [RTable.load]

theorem load_expectedShape : R.load.expectedShape = R.expectedShape := by
  unfold FTable.expectedShape RTable.expectedShape
  cases h : R.outputs <;>
    simp [RTable.load, FTable.axesShape, h, Function.comp_def]

theorem load_outputsDup : R.load.outputsDup = R.outputsDup := rfl

theorem load_outputsMismatch : R.load.outputsMismatch = R.outputsMismatch := by
  unfold FTable.outputsMismatch RTable.outputsMismatch
  simp only [RTable.load]
  cases R.outputs <;> cases R.data <;>
    simp [RNested.toNested, RNested.length_toNesteds]

theorem load_shapeAssertionWrong : R.load.shapeAssertionWrong = R.shapeAssertionWrong := by
  unfold FTable.shapeAssertionWrong RTable.shapeAssertionWrong
  rw [load_expectedShape]; rfl

theorem load_hasShape : R.load.data.hasShape R.load.expectedShape = R.data.hasShape R.expectedShape := by
  rw [load_expectedShape]; exact RNested.hasShape_toNested _ _ _

theorem load_anyNaN : R.load.data.anyNaN = R.data.anyLeaf (fun x => !TableValue.isFinite x) := by
  simp only [RTable.load, RNested.anyNaN_toNested, Lit.isNaN_toNum']; rfl

theorem load_axisNaN : R.load.axes.any (fun a => anyNaN a.values) =
    R.axes.any (fun a => a.values.any (fun x => !TableValue.isFinite x)) := by
  simp only [RTable.load, List.any_map, Function.comp_def, anyNaN, List.any_map,
    Lit.isNaN_toNum]; rfl

theorem load_tooShort : R.load.axes.any (fun a => decide (a.values.length < 2)) =
    R.axes.any (fun a => decide (a.values.length < 2)) := by
  simp [RTable.load, List.any_map, Function.comp_def]

theorem load_nonMonotonic
    (h4 : R.axes.any (fun a => a.values.any (fun x => !TableValue.isFinite x)) = false) :
    R.load.axes.any (fun a => !adjAll Scalar.lt a.values) = R.axes.any (fun a => !chainLt a.values) := by
  simp only [RTable.load, List.any_map, Function.comp_def]
  apply any_congr_mem
  intro a ha
  rw [List.any_eq_false] at h4
  have hf : ∀ x ∈ a.values, x.isFinite = true := by
    intro x hx
    by_contra hne
    apply h4 a ha
    refine List.any_eq_true.mpr ⟨x, hx, ?_⟩
    have : Lit.isFinite x = false := by simpa using hne
    show (!Lit.isFinite x) = true
    simp [this]
  rw [chainLt_map_toNum _ hf]

/-- The checks on a table as read give the verdict of the checks on the table
that loads: `load`'s identification of NaN and ±Inf never changes a code. -/
theorem validateRaw_eq : validateRaw R = validateTable R.load := by
  unfold validateRaw validateTable
  rw [load_names, load_outputsDup, load_axes_length, show R.load.interpolation = R.interpolation
    from rfl, load_axisNaN]
  by_cases h4 : R.axes.any (fun a => a.values.any (fun x => !TableValue.isFinite x)) = true
  · simp only [h4, Bool.not_eq_true', ↓reduceIte]
  · rw [load_nonMonotonic R (by simpa using h4), load_tooShort, load_outputsMismatch,
      load_hasShape, load_anyNaN, load_shapeAssertionWrong]

end Bridge

/-! ## The ten checks, with non-finite values (Q-109) -/

/- The ten rules of §9.5.5's "Order of the table checks" on a table as read,
in order. Rules 4 and 9 are "not finite" (Q-109). -/
namespace RRule
variable (R : RTable Lit)
/-- 1. Two axes share a name. -/
def axisDupName : Prop := ¬ (R.axes.map (·.name)).Nodup
/-- 2. Two outputs share a name. -/
def outputsDupName : Prop := ∃ os, R.outputs = some os ∧ ¬ os.Nodup
/-- 3. The interpolation and the axis count disagree. -/
def arity : Prop := FTable.arityOk R.interpolation R.axes.length = false
/-- 4. Some axis holds a non-finite value (NaN, +Inf or −Inf). -/
def axisNonFinite : Prop := ∃ a ∈ R.axes, ∃ x ∈ a.values, x.isFinite = false
/-- 5. Some (finite) axis is not strictly increasing. -/
def axisNonMonotonic : Prop :=
  ∃ a ∈ R.axes, ∃ r : List ℝ, a.values = r.map Lit.fin ∧ ¬ r.Pairwise (· < ·)
/-- 6. Some axis has fewer than 2 values. -/
def axisTooShort : Prop := ∃ a ∈ R.axes, a.values.length < 2
/-- 7. `outputs` is declared, `data` is an array, and their lengths differ. -/
def outputsLength : Prop :=
  ∃ os xs, R.outputs = some os ∧ R.data = .node xs ∧ xs.length ≠ os.length
/-- 8. The nesting of `data` is not the implied shape. -/
def nesting : Prop := R.data.hasShape R.expectedShape = false
/-- 9. Some leaf of `data` is not finite (NaN, +Inf or −Inf). -/
def dataNonFinite : Prop := R.data.anyLeaf (fun x => !x.isFinite) = true
/-- 10. The `shape` assertion is not the implied shape. -/
def shapeAssertion : Prop := ∃ sh, R.shape = some sh ∧ sh ≠ R.expectedShape
end RRule

section RuleBridge
variable (R : RTable Lit)

private theorem r1 : Rule.axisDupName R.load ↔ RRule.axisDupName R := by
  simp only [Rule.axisDupName, RRule.axisDupName, load_names]

private theorem r2 : Rule.outputsDupName R.load ↔ RRule.outputsDupName R := Iff.rfl

private theorem r3 : Rule.arity R.load ↔ RRule.arity R := by
  simp only [Rule.arity, RRule.arity, load_axes_length]; rfl

private theorem r4 : Rule.axisNaN R.load ↔ RRule.axisNonFinite R := by
  simp [Rule.axisNaN, RRule.axisNonFinite, RTable.load, Lit.isNaN_toNum']

private theorem r5 : Rule.axisNonMonotonic R.load ↔ RRule.axisNonMonotonic R := by
  simp [Rule.axisNonMonotonic, RRule.axisNonMonotonic, RTable.load, Lit.map_toNum_eq_fin]

private theorem r6 : Rule.axisTooShort R.load ↔ RRule.axisTooShort R := by
  simp [Rule.axisTooShort, RRule.axisTooShort, RTable.load]

private theorem r7 : Rule.outputsLength R.load ↔ RRule.outputsLength R := by
  have := load_outputsMismatch R
  unfold FTable.outputsMismatch RTable.outputsMismatch at this
  unfold Rule.outputsLength RRule.outputsLength
  simp only [RTable.load] at this ⊢
  cases R.outputs <;> cases hd : R.data <;>
    simp [RNested.toNested, RNested.length_toNesteds]

private theorem r8 : Rule.nesting R.load ↔ RRule.nesting R := by
  simp only [Rule.nesting, RRule.nesting, load_hasShape]

private theorem r9 : Rule.dataNaN R.load ↔ RRule.dataNonFinite R := by
  simp only [Rule.dataNaN, RRule.dataNonFinite, load_anyNaN]; rfl

private theorem r10 : Rule.shapeAssertion R.load ↔ RRule.shapeAssertion R := by
  simp only [Rule.shapeAssertion, RRule.shapeAssertion, load_expectedShape]; rfl

end RuleBridge

open Classical in
/-- §9.5.5 with Q-109: the checks on a table as read are the ten rules read in
order, the first broken rule naming the code; a non-finite axis value is
`table_axis_nan` and a non-finite leaf `table_data_nan`. -/
theorem validateRaw_ladder (R : RTable Lit) : validateRaw R =
    if RRule.axisDupName R then .error "table_axis_duplicate_name"
    else if RRule.outputsDupName R then .error "table_outputs_duplicate_name"
    else if RRule.arity R then .error "table_interpolation_axes_mismatch"
    else if RRule.axisNonFinite R then .error "table_axis_nan"
    else if RRule.axisNonMonotonic R then .error "table_axis_non_monotonic"
    else if RRule.axisTooShort R then .error "table_axis_too_short"
    else if RRule.outputsLength R then .error "table_outputs_length_mismatch"
    else if RRule.nesting R then .error "table_data_shape_mismatch"
    else if RRule.dataNonFinite R then .error "table_data_nan"
    else if RRule.shapeAssertion R then .error "table_data_shape_mismatch"
    else .ok () := by
  rw [validateRaw_eq, validateTable_ladder]
  simp only [r1, r2, r3, r4, r5, r6, r7, r8, r9, r10]

/-- Step 4 (Q-109): `table_axis_nan` exactly when some axis holds a non-finite
value (NaN, +Inf or −Inf) and rules 1–3 hold. -/
theorem validateRaw_first_axis_nonfinite (R : RTable Lit) :
    validateRaw R = .error "table_axis_nan" ↔
      ¬ RRule.axisDupName R ∧ ¬ RRule.outputsDupName R ∧ ¬ RRule.arity R ∧
        RRule.axisNonFinite R := by
  rw [validateRaw_ladder]; split_ifs <;> simp_all

/-- Step 9 (Q-109): `table_data_nan` exactly when a leaf of `data` is not
finite and rules 1–8 hold. -/
theorem validateRaw_first_data_nonfinite (R : RTable Lit) :
    validateRaw R = .error "table_data_nan" ↔
      ¬ RRule.axisDupName R ∧ ¬ RRule.outputsDupName R ∧ ¬ RRule.arity R ∧
        ¬ RRule.axisNonFinite R ∧ ¬ RRule.axisNonMonotonic R ∧ ¬ RRule.axisTooShort R ∧
        ¬ RRule.outputsLength R ∧ ¬ RRule.nesting R ∧ RRule.dataNonFinite R := by
  rw [validateRaw_ladder]; split_ifs <;> simp_all

/-- §9.5.5 `table_axis_nan` precedence with Q-109: once the name and arity
checks pass, an axis holding a non-finite value is `table_axis_nan`, whatever
its other entries (never `table_axis_non_monotonic`). -/
theorem validateRaw_nonfinite_precedence (R : RTable Lit) (h1 : (R.axes.map (·.name)).Nodup)
    (h2 : ∀ os, R.outputs = some os → os.Nodup)
    (h3 : FTable.arityOk R.interpolation R.axes.length = true)
    (hn : ∃ a ∈ R.axes, ∃ x ∈ a.values, x.isFinite = false) :
    validateRaw R = .error "table_axis_nan" := by
  refine (validateRaw_first_axis_nonfinite R).mpr ⟨fun h => h h1, ?_, ?_, hn⟩
  · rintro ⟨os, hos, hnd⟩; exact hnd (h2 os hos)
  · intro h; simp [RRule.arity, h3] at h

/-- The conditions §9.5.1 puts on a table as read: unique names, matching
arity, real strictly increasing axes of ≥ 2 values, the implied nesting, FINITE
data (Q-109), a correct `shape` assertion. -/
def RTableValid (R : RTable Lit) : Prop :=
  (R.axes.map (·.name)).Nodup ∧ (∀ os, R.outputs = some os → os.Nodup) ∧
    FTable.arityOk R.interpolation R.axes.length = true ∧
    (∀ a ∈ R.axes, ∃ r : List ℝ, a.values = r.map Lit.fin ∧ r.Pairwise (· < ·) ∧ 2 ≤ r.length) ∧
    R.data.hasShape R.expectedShape = true ∧ R.data.anyLeaf (fun x => !x.isFinite) = false ∧
    (∀ sh, R.shape = some sh → sh = R.expectedShape)

/-- §9.5.1 / §9.5.5 with Q-109: a table as read passes the checks iff it
satisfies every condition — in particular every axis value and every leaf of
`data` is finite. -/
theorem validateRaw_ok_iff (R : RTable Lit) : validateRaw R = .ok () ↔ RTableValid R := by
  rw [validateRaw_eq, validateTable_ok_iff]
  unfold TableValid RTableValid
  rw [load_names, load_axes_length, load_hasShape, load_anyNaN, load_expectedShape]
  apply and_congr Iff.rfl
  apply and_congr Iff.rfl
  apply and_congr Iff.rfl
  apply and_congr
  · simp [RTable.load, Lit.map_toNum_eq_fin]
  · rfl

/-! ## The document: checks at load (Q-106) -/

/-- The part of a loaded document the §9.2 / §9.5.5 load checks read: its
`function_tables` entries as read, and every expression of every
expression-bearing field after the load-time rewrites. -/
structure Doc where
  tables : List (String × RTable Lit)
  exprs : List Expr

/-- The tables lookups see: each entry as it loads. -/
def Doc.loaded (d : Doc) : List (String × FTable) := d.tables.map (fun p => (p.1, p.2.load))

/-- The direct subexpressions of a node. -/
def children : Expr → List Expr
  | .fn _ args => args
  | .index args => args
  | .op _ args => args
  | .lookup _ axes _ args => axes.map Prod.snd ++ args
  | _ => []

mutual
/-- Every node of an expression tree, the root first. -/
def nodes : Expr → List Expr
  | .fn name args => .fn name args :: nodesList args
  | .index args => .index args :: nodesList args
  | .op name args => .op name args :: nodesList args
  | .lookup t axes out args => .lookup t axes out args :: (nodesAxes axes ++ nodesList args)
  | e => [e]
def nodesList : List Expr → List Expr
  | [] => []
  | e :: es => nodes e ++ nodesList es
def nodesAxes : List (String × Expr) → List Expr
  | [] => []
  | (_, e) :: rest => nodes e ++ nodesAxes rest
end

/-- The load-time check of ONE node: the §9.2 argument check of an `interp.*`
call (on its array arguments as written), the §9.5.5 lookup checks of a
`table_lookup`; nothing else. -/
noncomputable def checkNode (tables : List (String × FTable)) : Expr → Except Code Unit
  | .fn "interp.searchsorted" [_, xs] => (validateSearchsorted (argOf xs)).map (fun _ => ())
  | .fn "interp.linear" [t, ax, _] => (validateLinear (argOf t) (argOf ax)).map (fun _ => ())
  | .fn "interp.bilinear" [T, ax, ay, _, _] =>
    (validateBilinear (argOf T) (argOf ax) (argOf ay)).map (fun _ => ())
  | .lookup tid axes out args =>
    (prepLookup tables tid (axes.map Prod.fst) out args).map (fun _ => ())
  | _ => .ok ()

/-- Run `f` on every element in order; the first failure is the result. -/
def allOk {β : Type} (f : β → Except Code Unit) : List β → Except Code Unit
  | [] => .ok ()
  | x :: xs => match f x with
    | .error c => .error c
    | .ok _ => allOk f xs

/-- Load (§9.2 "When the argument checks run", §9.5.5 "When the table checks
run"): the ten checks on every `function_tables` entry, then the node checks on
every node of every expression. Nothing is evaluated. -/
noncomputable def loadCheck (d : Doc) : Except Code Unit :=
  match allOk (fun p => validateRaw p.2) d.tables with
  | .error c => .error c
  | .ok _ => allOk (fun e => allOk (checkNode d.loaded) (nodes e)) d.exprs

theorem allOk_ok_iff {β : Type} (f : β → Except Code Unit) (l : List β) :
    allOk f l = .ok () ↔ ∀ x ∈ l, f x = .ok () := by
  induction l with
  | nil => simp [allOk]
  | cons x xs ih =>
    simp only [allOk, List.mem_cons, forall_eq_or_imp]
    cases h : f x with
    | error c => simp
    | ok u => cases u; simp [ih]

/-- Q-106: a document loads iff every `function_tables` entry passes the ten
§9.5.5 checks and every node of every expression passes its load check. -/
theorem loadCheck_ok_iff (d : Doc) :
    loadCheck d = .ok () ↔
      (∀ p ∈ d.tables, validateRaw p.2 = .ok ()) ∧
        ∀ e ∈ d.exprs, ∀ n ∈ nodes e, checkNode d.loaded n = .ok () := by
  unfold loadCheck
  cases h : allOk (fun p => validateRaw p.2) d.tables with
  | error c =>
    simp only [reduceCtorEq, false_iff, not_and]
    intro ht
    exact absurd ((allOk_ok_iff _ _).mpr ht) (by rw [h]; simp)
  | ok u =>
    cases u
    have ht := (allOk_ok_iff _ _).mp h
    simp only [allOk_ok_iff]
    exact ⟨fun h' => ⟨ht, h'⟩, fun h' => h'.2⟩

theorem loadCheck_error_of_ne (d : Doc) (h : loadCheck d ≠ .ok ()) : ∃ c, loadCheck d = .error c := by
  cases e : loadCheck d with
  | error c => exact ⟨c, rfl⟩
  | ok u => cases u; exact absurd e h

/-- §9.5.5 "When the table checks run" (Q-106): a document with a table that
fails one of the ten checks does not load, whether or not any lookup
references it and whatever its expressions hold. -/
theorem table_checks_at_load (d : Doc) (p : String × RTable Lit) (c : Code)
    (hp : p ∈ d.tables) (h : validateRaw p.2 = .error c) : ∃ c', loadCheck d = .error c' := by
  apply loadCheck_error_of_ne
  intro hok
  have := ((loadCheck_ok_iff d).mp hok).1 p hp
  rw [h] at this; cases this

/-- §9.2 "When the argument checks run" (Q-106): an `interp.searchsorted`,
`interp.linear` or `interp.bilinear` node ANYWHERE in an expression of the
document whose arguments fail the §9.2 check makes the document fail to load —
whether or not anything evaluates it. -/
theorem interp_checks_at_load (d : Doc) (e : Expr) (he : e ∈ d.exprs) :
    (∀ x xs c, Expr.fn "interp.searchsorted" [x, xs] ∈ nodes e →
      validateSearchsorted (argOf xs) = .error c → ∃ c', loadCheck d = .error c') ∧
    (∀ t ax x c, Expr.fn "interp.linear" [t, ax, x] ∈ nodes e →
      validateLinear (argOf t) (argOf ax) = .error c → ∃ c', loadCheck d = .error c') ∧
    (∀ T ax ay x y c, Expr.fn "interp.bilinear" [T, ax, ay, x, y] ∈ nodes e →
      validateBilinear (argOf T) (argOf ax) (argOf ay) = .error c →
        ∃ c', loadCheck d = .error c') := by
  have key : ∀ n ∈ nodes e, ∀ c, checkNode d.loaded n = .error c → ∃ c', loadCheck d = .error c' :=
    fun n hn c hc => loadCheck_error_of_ne d (fun hok => by
      have := ((loadCheck_ok_iff d).mp hok).2 e he n hn
      rw [hc] at this; cases this)
  refine ⟨fun x xs c hn hc => key _ hn c ?_, fun t ax x c hn hc => key _ hn c ?_,
    fun T ax ay x y c hn hc => key _ hn c ?_⟩ <;>
    simp [checkNode, hc, Except.map]

/-- §9.5.5 (Q-106, Q-107): a `table_lookup` node anywhere in an expression that
fails its checks makes the document fail to load. -/
theorem lookup_checks_at_load (d : Doc) (e : Expr) (he : e ∈ d.exprs) (tid : String)
    (axes : List (String × Expr)) (out : Option OutSel) (args : List Expr) (c : Code)
    (hn : Expr.lookup tid axes out args ∈ nodes e)
    (hc : prepLookup d.loaded tid (axes.map Prod.fst) out args = .error c) :
    ∃ c', loadCheck d = .error c' :=
  loadCheck_error_of_ne d (fun hok => by
    have := ((loadCheck_ok_iff d).mp hok).2 e he _ hn
    simp [checkNode, hc, Except.map] at this)

/-! ### `nodes` is every node of the tree -/

theorem self_mem_nodes (e : Expr) : e ∈ nodes e := by
  cases e <;> simp [nodes]

theorem mem_nodesList_of_mem : ∀ {l : List Expr} {c : Expr}, c ∈ l → nodes c ⊆ nodesList l
  | [], _, h => by simp at h
  | x :: xs, c, h => by
    simp only [List.mem_cons] at h
    rcases h with rfl | h
    · intro n hn; simp [nodesList, hn]
    · intro n hn; simp [nodesList, mem_nodesList_of_mem h hn]

theorem mem_nodesAxes_of_mem : ∀ {axes : List (String × Expr)} {c : Expr},
    c ∈ axes.map Prod.snd → nodes c ⊆ nodesAxes axes
  | [], _, h => by simp at h
  | (k, x) :: xs, c, h => by
    simp only [List.map_cons, List.mem_cons] at h
    rcases h with rfl | h
    · intro n hn; simp [nodesAxes, hn]
    · intro n hn; simp [nodesAxes, mem_nodesAxes_of_mem h hn]

/-- The children of a node are in the node's own list. -/
theorem nodes_children (e : Expr) : ∀ c ∈ children e, nodes c ⊆ nodes e := by
  intro c hc
  cases e with
  | fn name args =>
    intro n hn; simp only [children] at hc; simp [nodes, mem_nodesList_of_mem hc hn]
  | index args =>
    intro n hn; simp only [children] at hc; simp [nodes, mem_nodesList_of_mem hc hn]
  | op name args =>
    intro n hn; simp only [children] at hc; simp [nodes, mem_nodesList_of_mem hc hn]
  | lookup t axes out args =>
    simp only [children, List.mem_append] at hc
    intro n hn
    rcases hc with hc | hc
    · simp [nodes, mem_nodesAxes_of_mem hc hn]
    · simp [nodes, mem_nodesList_of_mem hc hn]
  | _ => simp [children] at hc

mutual
theorem nodes_closed : ∀ (root : Expr) {n c : Expr}, n ∈ nodes root → c ∈ children n →
    c ∈ nodes root
  | .fn name args, n, c, hn, hc => by
    simp only [nodes, List.mem_cons] at hn
    rcases hn with rfl | hn
    · exact nodes_children _ c hc (self_mem_nodes c)
    · exact List.mem_cons_of_mem _ (nodesList_closed args hn hc)
  | .index args, n, c, hn, hc => by
    simp only [nodes, List.mem_cons] at hn
    rcases hn with rfl | hn
    · exact nodes_children _ c hc (self_mem_nodes c)
    · exact List.mem_cons_of_mem _ (nodesList_closed args hn hc)
  | .op name args, n, c, hn, hc => by
    simp only [nodes, List.mem_cons] at hn
    rcases hn with rfl | hn
    · exact nodes_children _ c hc (self_mem_nodes c)
    · exact List.mem_cons_of_mem _ (nodesList_closed args hn hc)
  | .lookup t axes out args, n, c, hn, hc => by
    simp only [nodes, List.mem_cons, List.mem_append] at hn
    rcases hn with rfl | hn | hn
    · exact nodes_children _ c hc (self_mem_nodes c)
    · exact List.mem_cons_of_mem _ (List.mem_append_left _ (nodesAxes_closed axes hn hc))
    · exact List.mem_cons_of_mem _ (List.mem_append_right _ (nodesList_closed args hn hc))
  | .lit v, n, c, hn, hc => by simp [nodes] at hn; subst hn; simp [children] at hc
  | .var v, n, c, hn, hc => by simp [nodes] at hn; subst hn; simp [children] at hc
  | .const v, n, c, hn, hc => by simp [nodes] at hn; subst hn; simp [children] at hc
theorem nodesList_closed : ∀ (l : List Expr) {n c : Expr}, n ∈ nodesList l → c ∈ children n →
    c ∈ nodesList l
  | [], n, c, hn, _ => by simp [nodesList] at hn
  | x :: xs, n, c, hn, hc => by
    simp only [nodesList, List.mem_append] at hn ⊢
    rcases hn with hn | hn
    · exact Or.inl (nodes_closed x hn hc)
    · exact Or.inr (nodesList_closed xs hn hc)
theorem nodesAxes_closed : ∀ (axes : List (String × Expr)) {n c : Expr}, n ∈ nodesAxes axes →
    c ∈ children n → c ∈ nodesAxes axes
  | [], n, c, hn, _ => by simp [nodesAxes] at hn
  | (k, x) :: xs, n, c, hn, hc => by
    simp only [nodesAxes, List.mem_append] at hn ⊢
    rcases hn with hn | hn
    · exact Or.inl (nodes_closed x hn hc)
    · exact Or.inr (nodesAxes_closed xs hn hc)
end

/-- `nodes e` holds the root and is closed under taking children: every node
reachable from the root through `fn`/`index`/`op` arguments and `table_lookup`
axes and arguments is in it (so "wherever it appears" is every such node). -/
theorem nodes_cover (root : Expr) :
    root ∈ nodes root ∧ ∀ n ∈ nodes root, ∀ c ∈ children n, c ∈ nodes root :=
  ⟨self_mem_nodes root, fun _ hn _ hc => nodes_closed root hn hc⟩

/-- Load is not evaluation (Q-106, "whether or not anything ever evaluates
it"): there is a document whose one expression evaluates — the `ifelse` never
takes the branch holding a malformed `interp.linear` — and that does not load. -/
theorem load_is_not_evaluation :
    ∃ (d : Doc) (e : Expr) (v : Val), d.exprs = [e] ∧
      eval d.loaded (fun _ => Num.nan) e = .ok v ∧
      loadCheck d = .error "interp_table_not_const" := by
  let bad := Expr.fn "interp.linear" [.lit (.fin 0), .lit (.fin 0), .lit (.fin 0)]
  let e := Expr.op "ifelse" [.lit (.fin 1), .lit (.fin 0), bad]
  refine ⟨⟨[], [e]⟩, e, .num (.fin 0), rfl, ?_, ?_⟩
  · simp [e, eval, evalOp, Val.asNum, Num.truthy, bind, Except.bind]
  · simp [loadCheck, allOk, e, bad, nodes, nodesList, checkNode, argOf, validateLinear,
      Except.map, Codes.interpTableNotConst]

end Esm.Closed.Tables
