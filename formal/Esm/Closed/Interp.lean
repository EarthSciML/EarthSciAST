import Mathlib.Basic.Real.Basic
import Mathlib.Data.List.GetD
import Mathlib.Order.MinMax
import Mathlib.Tactic.Linarith
import Mathlib.Tactic.Positivity
import Mathlib.Tactic.Ring
import Mathlib.Algebra.Order.Field.Basic

/-!
# The reference `searchsorted`, `linear` and `bilinear`

The interpolation the `lib/interp.esm` templates are proven to compute
(`Esm/Closed/Interp/TemplateAst.lean`), and the `rank_of` / `rank_of_set`
templates of `lib/relational.esm` reduce to (`searchsorted`). The three are
written ONCE, over an abstract `Scalar` (four arithmetic operations, two
comparisons, a NaN test). Two instances use the same code:

* `Num`, a finite real or NaN, with exact arithmetic. Every theorem in this
  file is about this instance.
* `Float`, the executable C double, at which the `esm-lean templates` adapter
  evaluates expressions.

Because the Float version is the generic definition instantiated at `Float`,
it follows the exact version operation for operation by construction; the only
difference between the two is rounding, which is the subject of the binary64
claims (`Esm/Float64.lean`), not of this file.

The axes are finite and the tables MAY hold NaN (ruling Q-5); `searchsorted`'s
`xs` is non-decreasing (ruling Q-7).
-/

namespace Esm.Closed

/-- The operations the reference interpolation definitions are written in. -/
class Scalar (α : Type) where
  nan : α
  add : α → α → α
  sub : α → α → α
  mul : α → α → α
  div : α → α → α
  le : α → α → Bool
  lt : α → α → Bool
  isNaN : α → Bool

/-- A scalar as the reference sees it: a finite real, or NaN. (Infinite inputs are not
modelled over ℝ; the axes are required finite and JSON cannot spell an
infinite table entry.) -/
inductive Num where
  | fin (r : ℝ)
  | nan

namespace Num

/-- IEEE-style NaN propagation over exact arithmetic. -/
noncomputable def lift₂ (f : ℝ → ℝ → ℝ) : Num → Num → Num
  | fin a, fin b => fin (f a b)
  | _, _ => nan

/-- Division; a zero divisor never occurs on a validated axis (it is strictly
increasing), and is mapped to NaN rather than to Lean's `x / 0 = 0`. -/
noncomputable def div : Num → Num → Num
  | fin a, fin b => if b = 0 then nan else fin (a / b)
  | _, _ => nan

/-- IEEE-754 `≤`: false whenever an operand is NaN. -/
noncomputable def le : Num → Num → Bool
  | fin a, fin b => decide (a ≤ b)
  | _, _ => false

/-- IEEE-754 `<`: false whenever an operand is NaN. -/
noncomputable def lt : Num → Num → Bool
  | fin a, fin b => decide (a < b)
  | _, _ => false

def isNaN : Num → Bool
  | fin _ => false
  | nan => true

end Num

noncomputable instance : Scalar Num where
  nan := .nan
  add := Num.lift₂ (· + ·)
  sub := Num.lift₂ (· - ·)
  mul := Num.lift₂ (· * ·)
  div := Num.div
  le := Num.le
  lt := Num.lt
  isNaN := Num.isNaN

instance : Scalar Float where
  nan := (0.0 : Float) / 0.0
  add := (· + ·)
  sub := (· - ·)
  mul := (· * ·)
  div := (· / ·)
  le := fun a b => a ≤ b
  lt := fun a b => a < b
  isNaN := Float.isNaN

section Generic

variable {α : Type} [Scalar α]
open Scalar

/-! ## Semantics -/

/-- `searchsorted(x, xs)`: the 1-based index of the first element of
`xs` that is `≥ x` under IEEE `≥`, or `N + 1` when there is none. A NaN `x`
satisfies no comparison, so it gets `N + 1` with no special case. -/
def searchsorted (x : α) (xs : List α) : ℕ :=
  xs.findIdx (fun a => le x a) + 1

/-- The 0-based cell index for a query `q` already clamped into
`[ax[0], ax[n-1]]`: the largest `i ∈ [0, n-2]` with `ax[i] ≤ q` (bilinear
step 2; for `linear` step 3 it is the `i` with
`ax[i] ≤ q < ax[i+1]`). Computed as one less than the first knot strictly
above `q`, capped at `n - 2`; for a NaN `q` (no knot compares above it) it is
`n - 2`, a definite cell whose weight is NaN. -/
def cell (q : α) (ax : List α) : ℕ :=
  min (ax.findIdx (fun a => lt q a) - 1) (ax.length - 2)

/-- The pinned weight `(q − lo) / (hi − lo)`. -/
def weight (q lo hi : α) : α := div (sub q lo) (sub hi lo)

/-- The pinned blend `t + w · (u − t)`. -/
def blend (t u w : α) : α := add t (mul w (sub u t))

/-- `linear(table, axis, x)`, steps 1–4, in the pinned order. -/
def linear (t ax : List α) (x : α) : α :=
  let n := ax.length
  if le x (ax.getD 0 nan) then t.getD 0 nan
  else if le (ax.getD (n - 1) nan) x then t.getD (n - 1) nan
  else
    let i := cell x ax
    blend (t.getD i nan) (t.getD (i + 1) nan)
      (weight x (ax.getD i nan) (ax.getD (i + 1) nan))

/-- Bilinear step 1: `lo` if `v ≤ lo`, `hi` if `v ≥ hi`, else `v`. -/
def clamp (v lo hi : α) : α :=
  if le v lo then lo else if le hi v then hi else v

/-- Row-major table entry `T[i][j]` (0-based), NaN when absent. -/
def entry (T : List (List α)) (i j : ℕ) : α := (T.getD i []).getD j nan

/-- The bilinear blend in a given cell `(i, j)` (0-based) at clamped queries
`(xq, yq)`: bilinear steps 3–4 in the pinned order (two x-blends, then one
y-blend). -/
def bilinearCell (T : List (List α)) (ax ay : List α) (i j : ℕ) (xq yq : α) : α :=
  let wx := weight xq (ax.getD i nan) (ax.getD (i + 1) nan)
  let wy := weight yq (ay.getD j nan) (ay.getD (j + 1) nan)
  let row_j := blend (entry T i j) (entry T (i + 1) j) wx
  let row_jp1 := blend (entry T i (j + 1)) (entry T (i + 1) (j + 1)) wx
  blend row_j row_jp1 wy

/-- `bilinear(table, axis_x, axis_y, x, y)`, steps 1–5: clamp per
axis, locate the cell, blend. -/
def bilinear (T : List (List α)) (ax ay : List α) (x y : α) : α :=
  let xq := clamp x (ax.getD 0 nan) (ax.getD (ax.length - 1) nan)
  let yq := clamp y (ay.getD 0 nan) (ay.getD (ay.length - 1) nan)
  bilinearCell T ax ay (cell xq ax) (cell yq ay) xq yq

end Generic

/-! ## The exact model: simp lemmas for `Num` -/

namespace Num

@[simp] theorem nan_def : (Scalar.nan : Num) = Num.nan := rfl
@[simp] theorem add_fin (a b : ℝ) : (Scalar.add (fin a) (fin b) : Num) = fin (a + b) := rfl
@[simp] theorem sub_fin (a b : ℝ) : (Scalar.sub (fin a) (fin b) : Num) = fin (a - b) := rfl
@[simp] theorem mul_fin (a b : ℝ) : (Scalar.mul (fin a) (fin b) : Num) = fin (a * b) := rfl
@[simp] theorem add_nan (x : Num) : Scalar.add x nan = nan := by cases x <;> rfl
@[simp] theorem nan_add (x : Num) : Scalar.add nan x = nan := by cases x <;> rfl
@[simp] theorem sub_nan (x : Num) : Scalar.sub x nan = nan := by cases x <;> rfl
@[simp] theorem nan_sub (x : Num) : Scalar.sub nan x = nan := by cases x <;> rfl
@[simp] theorem mul_nan (x : Num) : Scalar.mul x nan = nan := by cases x <;> rfl
@[simp] theorem nan_mul (x : Num) : Scalar.mul nan x = nan := by cases x <;> rfl
@[simp] theorem div_nan (x : Num) : Scalar.div x nan = nan := by cases x <;> rfl
@[simp] theorem nan_div (x : Num) : Scalar.div nan x = nan := by cases x <;> rfl
@[simp] theorem div_fin (a b : ℝ) (hb : b ≠ 0) : (Scalar.div (fin a) (fin b) : Num) = fin (a / b) := by
  simp [Scalar.div, Num.div, hb]
@[simp] theorem le_fin (a b : ℝ) : (Scalar.le (fin a) (fin b) : Bool) = decide (a ≤ b) := rfl
@[simp] theorem lt_fin (a b : ℝ) : (Scalar.lt (fin a) (fin b) : Bool) = decide (a < b) := rfl
@[simp] theorem le_nan (x : Num) : Scalar.le x nan = false := by cases x <;> rfl
@[simp] theorem nan_le (x : Num) : Scalar.le nan x = false := by cases x <;> rfl
@[simp] theorem lt_nan (x : Num) : Scalar.lt x nan = false := by cases x <;> rfl
@[simp] theorem nan_lt (x : Num) : Scalar.lt nan x = false := by cases x <;> rfl
@[simp] theorem isNaN_fin (a : ℝ) : (Scalar.isNaN (fin a) : Bool) = false := rfl
@[simp] theorem isNaN_nan : (Scalar.isNaN nan : Bool) = true := rfl
@[simp] theorem isNaN_fin' (a : ℝ) : (fin a).isNaN = false := rfl
@[simp] theorem isNaN_nan' : nan.isNaN = true := rfl

end Num

open Num in
theorem getD_map_fin {a : List ℝ} {k : ℕ} (hk : k < a.length) :
    (a.map Num.fin).getD k Num.nan = Num.fin (a.getD k 0) := by
  rw [List.getD_eq_getElem _ _ (by simpa using hk), List.getD_eq_getElem _ _ hk]
  simp

/-! ## Strictly increasing axes: the cell a query falls in -/

section Cells

open Num

theorem pw_getD_lt {a : List ℝ} (ha : a.Pairwise (· < ·)) {i j : ℕ} (hj : j < a.length)
    (hij : i < j) : a.getD i 0 < a.getD j 0 := by
  rw [List.getD_eq_getElem _ _ (by omega), List.getD_eq_getElem _ _ hj]
  exact List.pairwise_iff_getElem.mp ha i j (by omega) hj hij

theorem pw_getD_le {a : List ℝ} (ha : a.Pairwise (· < ·)) {i j : ℕ} (hj : j < a.length)
    (hij : i ≤ j) : a.getD i 0 ≤ a.getD j 0 := by
  rcases eq_or_lt_of_le hij with rfl | h
  · exact le_rfl
  · exact (pw_getD_lt ha hj h).le

/-- The first knot strictly above `q`, located from its defining property. -/
theorem findIdx_lt_fin {a : List ℝ} {i : ℕ} {q : ℝ} (hi : i < a.length)
    (h1 : ∀ j < i, a.getD j 0 ≤ q) (h2 : q < a.getD i 0) :
    (a.map Num.fin).findIdx (fun b => Scalar.lt (Num.fin q) b) = i := by
  rw [List.findIdx_eq (by simpa using hi)]
  refine ⟨?_, ?_⟩
  · simp only [List.getElem_map, Num.lt_fin, decide_eq_true_eq]
    rwa [List.getD_eq_getElem _ _ hi] at h2
  · intro j hj
    simp only [List.getElem_map, Num.lt_fin, decide_eq_false_iff_not, not_lt]
    have := h1 j hj
    rwa [List.getD_eq_getElem _ _ (by omega)] at this

/-- A query in the half-open cell `[a[i], a[i+1])` gets cell `i`. -/
theorem cell_eq {a : List ℝ} (ha : a.Pairwise (· < ·)) {i : ℕ} {q : ℝ}
    (hi : i + 1 < a.length) (h1 : a.getD i 0 ≤ q) (h2 : q < a.getD (i + 1) 0) :
    cell (Num.fin q) (a.map Num.fin) = i := by
  have hf : (a.map Num.fin).findIdx (fun b => Scalar.lt (Num.fin q) b) = i + 1 :=
    findIdx_lt_fin hi (fun j hj => (pw_getD_le ha (by omega) (by omega)).trans h1) h2
  simp only [cell, hf, List.length_map]
  omega

/-- A query on the last knot gets the last cell, `n - 2`. -/
theorem cell_last {a : List ℝ} (ha : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) :
    cell (Num.fin (a.getD (a.length - 1) 0)) (a.map Num.fin) = a.length - 2 := by
  have hf : (a.map Num.fin).findIdx
      (fun b => Scalar.lt (Num.fin (a.getD (a.length - 1) 0)) b) = a.length := by
    have := (List.findIdx_eq_length (p := fun b => Scalar.lt (Num.fin (a.getD (a.length - 1) 0)) b)
      (xs := a.map Num.fin)).mpr
    rw [List.length_map] at this
    apply this
    intro x hx
    obtain ⟨k, hk, rfl⟩ := List.mem_iff_getElem.mp hx
    simp only [List.length_map] at hk
    simp only [List.getElem_map, Num.lt_fin, decide_eq_false_iff_not, not_lt]
    have := pw_getD_le ha (i := k) (j := a.length - 1) (by omega) (by omega)
    rwa [List.getD_eq_getElem _ _ hk] at this
  simp only [cell, hf, List.length_map]
  omega

/-- Every query clamped into `[a[0], a[n-1]]` lands in some cell `i` with
`a[i] ≤ q < a[i+1]`, or on the last knot with `i = n - 2`. -/
theorem cell_spec {a : List ℝ} (ha : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) {q : ℝ}
    (h0 : a.getD 0 0 ≤ q) (hL : q ≤ a.getD (a.length - 1) 0) :
    let i := cell (Num.fin q) (a.map Num.fin)
    i + 1 < a.length ∧ a.getD i 0 ≤ q ∧
      (q < a.getD (i + 1) 0 ∨ (i + 2 = a.length ∧ q = a.getD (i + 1) 0)) := by
  intro i
  rcases eq_or_lt_of_le hL with hq | hq
  · have : i = a.length - 2 := by simp only [i, hq]; exact cell_last ha hn
    have e : a.length - 2 + 1 = a.length - 1 := by omega
    refine ⟨by omega, ?_, Or.inr ⟨by omega, by rw [this, e, hq]⟩⟩
    rw [this, hq]; exact pw_getD_le ha (by omega) (by omega)
  · -- the first knot strictly above q exists and is not knot 0
    have hex : ∃ x ∈ a.map Num.fin, Scalar.lt (Num.fin q) x = true :=
      ⟨Num.fin (a.getD (a.length - 1) 0), by
        rw [List.mem_map]; exact ⟨_, by rw [List.getD_eq_getElem _ _ (by omega)]; exact List.getElem_mem _, rfl⟩,
        by simpa using hq⟩
    have hlt := List.findIdx_lt_length_of_exists hex
    set k := (a.map Num.fin).findIdx (fun b => Scalar.lt (Num.fin q) b) with hk
    rw [List.length_map] at hlt
    have hkp : q < a.getD k 0 := by
      have := List.findIdx_getElem (w := by rw [List.length_map]; exact hlt)
        (p := fun b => Scalar.lt (Num.fin q) b) (xs := a.map Num.fin)
      simp only [List.getElem_map, Num.lt_fin, decide_eq_true_eq] at this
      rw [List.getD_eq_getElem _ _ hlt]; convert this using 2
    have hkn : ∀ j < k, a.getD j 0 ≤ q := by
      intro j hj
      have := List.not_of_lt_findIdx (p := fun b => Scalar.lt (Num.fin q) b)
        (xs := a.map Num.fin) hj
      simp only [List.getElem_map, Num.lt_fin, decide_eq_false_iff_not, not_lt] at this
      rw [List.getD_eq_getElem _ _ (by omega)]; exact this
    have hk0 : 0 < k := by
      rcases Nat.eq_zero_or_pos k with h | h
      · rw [h] at hkp; exact absurd h0 (not_le.mpr hkp)
      · exact h
    have hi : i = k - 1 := by
      simp only [i, cell, ← hk, List.length_map]; omega
    have e : k - 1 + 1 = k := by omega
    refine ⟨by omega, ?_, Or.inl ?_⟩
    · rw [hi]; exact hkn _ (by omega)
    · rw [hi, e]; exact hkp

end Cells

/-! ## `searchsorted` over ℝ -/

section Searchsorted

open Num

/-- `searchsorted` is the least 1-based `k` with `xs[k] ≥ x`, or `N + 1`. -/
theorem searchsorted_least (xs : List ℝ) (x : ℝ) :
    let k := searchsorted (Num.fin x) (xs.map Num.fin)
    1 ≤ k ∧ k ≤ xs.length + 1 ∧ (∀ j, j + 1 < k → xs.getD j 0 < x) ∧
      (k ≤ xs.length → x ≤ xs.getD (k - 1) 0) := by
  intro k
  have hle := List.findIdx_le_length (p := fun a => Scalar.le (Num.fin x) a) (xs := xs.map Num.fin)
  rw [List.length_map] at hle
  have hk : k = (xs.map Num.fin).findIdx (fun a => Scalar.le (Num.fin x) a) + 1 := rfl
  refine ⟨by omega, by omega, ?_, ?_⟩
  · intro j hj
    have := List.not_of_lt_findIdx (p := fun a => Scalar.le (Num.fin x) a) (xs := xs.map Num.fin)
      (i := j) (by omega)
    simp only [List.getElem_map, Num.le_fin, decide_eq_false_iff_not, not_le] at this
    rw [List.getD_eq_getElem _ _ (by omega)]; exact this
  · intro hkn
    rcases eq_or_lt_of_le hkn with h | h
    · -- k = N: then findIdx = N - 1 < N, so the predicate holds there
      have hlt : (xs.map Num.fin).findIdx (fun a => Scalar.le (Num.fin x) a) < (xs.map Num.fin).length := by
        simp only [List.length_map]; omega
      have := List.findIdx_getElem (w := hlt)
      simp only [List.getElem_map, Num.le_fin, decide_eq_true_eq] at this
      rw [List.getD_eq_getElem _ _ (by omega)]; convert this using 2; omega
    · have hlt : (xs.map Num.fin).findIdx (fun a => Scalar.le (Num.fin x) a) < (xs.map Num.fin).length := by
        simp only [List.length_map]; omega
      have := List.findIdx_getElem (w := hlt)
      simp only [List.getElem_map, Num.le_fin, decide_eq_true_eq] at this
      rw [List.getD_eq_getElem _ _ (by omega)]; convert this using 2; omega

/-- A NaN query returns `N + 1`, whatever `xs` holds. -/
theorem searchsorted_nan (xs : List Num) : searchsorted Num.nan xs = xs.length + 1 := by
  simp only [searchsorted, Nat.add_right_cancel_iff]
  exact List.findIdx_eq_length.mpr (fun _ _ => Num.nan_le _)

/-- `searchsorted` is monotone in `x` (for any `xs`), with NaN above every real. -/
theorem searchsorted_mono (xs : List ℝ) (x y : ℝ) (hxy : x ≤ y) :
    searchsorted (Num.fin x) (xs.map Num.fin) ≤ searchsorted (Num.fin y) (xs.map Num.fin) ∧
      searchsorted (Num.fin y) (xs.map Num.fin) ≤ searchsorted Num.nan (xs.map Num.fin) := by
  constructor
  · simp only [searchsorted, Nat.add_le_add_iff_right]
    induction xs with
    | nil => simp
    | cons b l ih =>
      simp only [List.map_cons, List.findIdx_cons, Num.le_fin, decide_eq_true_eq]
      by_cases hy : y ≤ b
      · simp [hxy.trans hy, hy]
      · by_cases hx : x ≤ b
        · simp [hx, hy]
        · simp only [hx, hy, ↓reduceIte]; omega
  · rw [searchsorted_nan]
    simp only [searchsorted, List.length_map, Nat.add_le_add_iff_right]
    simpa using List.findIdx_le_length (p := fun a => Scalar.le (Num.fin y) a) (xs := xs.map Num.fin)

/-- Out of range: `x ≤ xs[1]` gives 1; on a non-decreasing `xs`,
`x > xs[N]` gives `N + 1`. -/
theorem searchsorted_out_of_range (xs : List ℝ) (x : ℝ) (hne : xs ≠ []) :
    (x ≤ xs.getD 0 0 → searchsorted (Num.fin x) (xs.map Num.fin) = 1) ∧
      (xs.Pairwise (· ≤ ·) → xs.getD (xs.length - 1) 0 < x →
        searchsorted (Num.fin x) (xs.map Num.fin) = xs.length + 1) := by
  obtain ⟨b, l, rfl⟩ := List.exists_cons_of_ne_nil hne
  constructor
  · intro h
    simp only [List.getD_cons_zero] at h
    simp [searchsorted, List.findIdx_cons, h]
  · intro hs hx
    simp only [searchsorted, Nat.add_right_cancel_iff]
    rw [← List.length_map (f := Num.fin)]
    apply List.findIdx_eq_length.mpr
    intro y hy
    obtain ⟨k, hk, rfl⟩ := List.mem_iff_getElem.mp hy
    simp only [List.length_map] at hk
    simp only [List.getElem_map, Num.le_fin, decide_eq_false_iff_not, not_le]
    have hle : (b :: l)[k] ≤ (b :: l).getD ((b :: l).length - 1) 0 := by
      rw [List.getD_eq_getElem _ _ (by simp)]
      rcases eq_or_lt_of_le (Nat.le_sub_one_of_lt hk) with h | h
      · simp only [h]; exact le_rfl
      · exact List.pairwise_iff_getElem.mp hs k _ hk (by simp) h
    exact lt_of_le_of_lt hle hx

end Searchsorted

/-! ## `linear` over ℝ -/

section Linear

open Num

theorem blend_fin (p q w : ℝ) :
    blend (Num.fin p) (Num.fin q) (Num.fin w) = Num.fin (p + w * (q - p)) := rfl

theorem blend_nan_left (u w : Num) : blend Num.nan u w = Num.nan := by simp [blend]
theorem blend_nan_right (t w : Num) : blend t Num.nan w = Num.nan := by simp [blend]
theorem blend_nan_w (t u : Num) : blend t u Num.nan = Num.nan := by simp [blend]

/-- Step 3: inside a cell, `linear` is the pinned blend with the
pinned weight. -/
theorem linear_in_cell (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·)) (i : ℕ) (x : ℝ)
    (hi : i + 1 < a.length) (h1 : a.getD i 0 ≤ x) (h2 : x < a.getD (i + 1) 0)
    (h0 : a.getD 0 0 < x) :
    linear t (a.map Num.fin) (Num.fin x) =
      blend (t.getD i .nan) (t.getD (i + 1) .nan)
        (Num.fin ((x - a.getD i 0) / (a.getD (i + 1) 0 - a.getD i 0))) := by
  have hL : x < a.getD (a.length - 1) 0 := lt_of_lt_of_le h2 (pw_getD_le ha (by omega) (by omega))
  have hd : a.getD (i + 1) 0 - a.getD i 0 ≠ 0 := by
    have := pw_getD_lt ha hi (Nat.lt_succ_self i); linarith
  simp only [linear, Num.nan_def, List.length_map, getD_map_fin (show 0 < a.length by omega),
    getD_map_fin (show a.length - 1 < a.length by omega), Num.le_fin, cell_eq ha hi h1 h2,
    getD_map_fin (show i < a.length by omega), getD_map_fin hi, weight, Num.sub_fin,
    Num.div_fin _ _ hd, not_le.mpr h0, not_le.mpr hL, decide_false, Bool.false_eq_true,
    ↓reduceIte]

/-- Step 1: below-range clamp. -/
theorem linear_clamp_below (t : List Num) (a : List ℝ) (hn : 2 ≤ a.length) (x : ℝ)
    (hx : x ≤ a.getD 0 0) : linear t (a.map Num.fin) (Num.fin x) = t.getD 0 .nan := by
  simp only [linear, Num.nan_def, getD_map_fin (show 0 < a.length by omega), Num.le_fin, hx,
    decide_true, ↓reduceIte]

/-- Step 2: above-range clamp. -/
theorem linear_clamp_above (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·))
    (hn : 2 ≤ a.length) (x : ℝ) (hx : a.getD (a.length - 1) 0 ≤ x) :
    linear t (a.map Num.fin) (Num.fin x) = t.getD (a.length - 1) .nan := by
  have h01 : a.getD 0 0 < a.getD (a.length - 1) 0 := pw_getD_lt ha (by omega) (by omega)
  have : ¬ x ≤ a.getD 0 0 := by linarith
  simp only [linear, Num.nan_def, List.length_map, getD_map_fin (show 0 < a.length by omega),
    getD_map_fin (show a.length - 1 < a.length by omega), Num.le_fin, hx, this,
    decide_true, decide_false, Bool.false_eq_true, ↓reduceIte]

/-- Step 4: a NaN query gives NaN. -/
theorem linear_nan (t ax : List Num) : linear t ax Num.nan = Num.nan := by
  simp [linear, weight, blend]

/-- Exact at the endpoints, w = 0: a query on knot `k` returns `t[k]`,
provided the right neighbour `t[k+1]` of an interior knot is not NaN (at an
interior knot the blend still multiplies `0 · (t[k+1] − t[k])`). -/
theorem linear_knot (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·)) (hn : 2 ≤ a.length)
    (k : ℕ) (hk : k < a.length)
    (hnb : 0 < k → k + 1 < a.length → (t.getD (k + 1) .nan).isNaN = false) :
    linear t (a.map Num.fin) (Num.fin (a.getD k 0)) = t.getD k .nan := by
  rcases Nat.eq_zero_or_pos k with rfl | hk0
  · exact linear_clamp_below t a hn _ le_rfl
  rcases eq_or_lt_of_le (Nat.le_sub_one_of_lt hk) with hkl | hkl
  · rw [hkl]; exact linear_clamp_above t a ha hn _ le_rfl
  rw [linear_in_cell t a ha k _ (by omega) le_rfl (pw_getD_lt ha (by omega) (Nat.lt_succ_self k))
    (pw_getD_lt ha hk hk0)]
  have hnn := hnb hk0 (by omega)
  cases h1 : t.getD k .nan with
  | nan => simp [blend]
  | fin p =>
    cases h2 : t.getD (k + 1) .nan with
    | nan => rw [h2] at hnn; simp at hnn
    | fin q => simp [blend_fin]

/-- The other side of `linear_knot`: an interior knot whose right neighbour is
NaN evaluates to NaN — the knot belongs to the cell `[a[k], a[k+1])`, whose
corner is NaN (a query landing in a cell whose corner is NaN gives NaN). -/
theorem linear_knot_nan_neighbour (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·))
    (k : ℕ) (hk0 : 0 < k) (hk : k + 1 < a.length)
    (hnb : (t.getD (k + 1) .nan).isNaN = true) :
    linear t (a.map Num.fin) (Num.fin (a.getD k 0)) = Num.nan := by
  rw [linear_in_cell t a ha k _ hk le_rfl (pw_getD_lt ha hk (Nat.lt_succ_self k))
    (pw_getD_lt ha (by omega) hk0)]
  cases h2 : t.getD (k + 1) .nan with
  | nan => exact blend_nan_right _ _
  | fin q => rw [h2] at hnb; simp at hnb

/-- The blend with `w ∈ [0, 1]` lies between its two endpoints. -/
theorem blend_between (p q w : ℝ) (hw0 : 0 ≤ w) (hw1 : w ≤ 1) :
    min p q ≤ p + w * (q - p) ∧ p + w * (q - p) ≤ max p q := by
  rcases le_total p q with h | h
  · rw [min_eq_left h, max_eq_right h]
    constructor <;> nlinarith
  · rw [min_eq_right h, max_eq_left h]
    constructor <;> nlinarith

/-- An in-range result lies between the two bracketing table values. -/
theorem linear_between (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·)) (hn : 2 ≤ a.length)
    (i : ℕ) (x p q : ℝ) (hi : i + 1 < a.length) (h1 : a.getD i 0 ≤ x)
    (h2 : x < a.getD (i + 1) 0) (hp : t.getD i .nan = Num.fin p)
    (hq : t.getD (i + 1) .nan = Num.fin q) :
    ∃ r, linear t (a.map Num.fin) (Num.fin x) = Num.fin r ∧ min p q ≤ r ∧ r ≤ max p q := by
  rcases le_or_gt x (a.getD 0 0) with hx0 | hx0
  · -- then x = a[0] and i = 0
    have hi0 : i = 0 := by
      by_contra h
      have := pw_getD_lt ha (i := 0) (j := i) (by omega) (by omega)
      linarith
    subst hi0
    refine ⟨p, by rw [linear_clamp_below t a hn x hx0, hp], min_le_left _ _, le_max_left _ _⟩
  · have hlt := pw_getD_lt ha hi (Nat.lt_succ_self i)
    rw [linear_in_cell t a ha i x hi h1 h2 hx0, hp, hq, blend_fin]
    refine ⟨_, rfl, blend_between p q _ ?_ ?_⟩
    · exact div_nonneg (by linarith) (by linarith)
    · rw [div_le_one (by linarith)]; linarith

/-- A query inside a cell one of whose corners is NaN gives NaN. -/
theorem linear_nan_corner (t : List Num) (a : List ℝ) (ha : a.Pairwise (· < ·)) (i : ℕ) (x : ℝ)
    (hi : i + 1 < a.length) (h1 : a.getD i 0 ≤ x) (h2 : x < a.getD (i + 1) 0)
    (h0 : a.getD 0 0 < x)
    (hnan : (t.getD i .nan).isNaN = true ∨ (t.getD (i + 1) .nan).isNaN = true) :
    linear t (a.map Num.fin) (Num.fin x) = Num.nan := by
  rw [linear_in_cell t a ha i x hi h1 h2 h0]
  rcases hnan with h | h
  · cases e : t.getD i .nan with
    | nan => exact blend_nan_left _ _
    | fin _ => rw [e] at h; simp at h
  · cases e : t.getD (i + 1) .nan with
    | nan => exact blend_nan_right _ _
    | fin _ => rw [e] at h; simp at h

end Linear

/-! ## `bilinear` over ℝ -/

section Bilinear

open Num

/-- Clamping a finite query into a finite axis range. -/
theorem clamp_fin (x lo hi : ℝ) (h : lo ≤ hi) :
    clamp (Num.fin x) (Num.fin lo) (Num.fin hi) = Num.fin (max lo (min x hi)) := by
  unfold clamp
  by_cases h1 : x ≤ lo
  · simp [h1]
  · by_cases h2 : hi ≤ x
    · simp [h1, h2, h]
    · have : max lo (min x hi) = x := by
        rw [min_eq_left (le_of_lt (not_le.mp h2)), max_eq_right (le_of_lt (not_le.mp h1))]
      simp [h1, h2, this]

theorem clamp_nan (lo hi : Num) : clamp Num.nan lo hi = Num.nan := by simp [clamp]

/-- A real axis's clamp, as the model computes it. -/
theorem bilinear_clamp_fin (T : List (List Num)) (ax ay : List ℝ)
    (hx : 2 ≤ ax.length) (hy : 2 ≤ ay.length)
    (hax : ax.getD 0 0 ≤ ax.getD (ax.length - 1) 0) (hay : ay.getD 0 0 ≤ ay.getD (ay.length - 1) 0)
    (x y : ℝ) :
    bilinear T (ax.map Num.fin) (ay.map Num.fin) (Num.fin x) (Num.fin y) =
      let xq := max (ax.getD 0 0) (min x (ax.getD (ax.length - 1) 0))
      let yq := max (ay.getD 0 0) (min y (ay.getD (ay.length - 1) 0))
      bilinearCell T (ax.map Num.fin) (ay.map Num.fin)
        (cell (Num.fin xq) (ax.map Num.fin)) (cell (Num.fin yq) (ay.map Num.fin))
        (Num.fin xq) (Num.fin yq) := by
  simp only [bilinear, Num.nan_def, List.length_map, getD_map_fin (show 0 < ax.length by omega),
    getD_map_fin (show ax.length - 1 < ax.length by omega),
    getD_map_fin (show 0 < ay.length by omega),
    getD_map_fin (show ay.length - 1 < ay.length by omega), clamp_fin _ _ _ hax, clamp_fin _ _ _ hay]

/-- Bilinear step 1 (extrapolate-flat): a query outside the table gives
the same result as the query pinned to the nearest edge, per axis. -/
theorem bilinear_clamp (T : List (List Num)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·))
    (hx : 2 ≤ ax.length) (hy : 2 ≤ ay.length) (x y : ℝ) :
    bilinear T (ax.map Num.fin) (ay.map Num.fin) (Num.fin x) (Num.fin y) =
      bilinear T (ax.map Num.fin) (ay.map Num.fin)
        (Num.fin (max (ax.getD 0 0) (min x (ax.getD (ax.length - 1) 0))))
        (Num.fin (max (ay.getD 0 0) (min y (ay.getD (ay.length - 1) 0)))) := by
  have h1 := (pw_getD_lt hax (i := 0) (j := ax.length - 1) (by omega) (by omega)).le
  have h2 := (pw_getD_lt hay (i := 0) (j := ay.length - 1) (by omega) (by omega)).le
  rw [bilinear_clamp_fin T ax ay hx hy h1 h2, bilinear_clamp_fin T ax ay hx hy h1 h2]
  have e1 : ∀ v : ℝ, max (ax.getD 0 0) (min (max (ax.getD 0 0) (min v (ax.getD (ax.length - 1) 0)))
      (ax.getD (ax.length - 1) 0)) = max (ax.getD 0 0) (min v (ax.getD (ax.length - 1) 0)) := by
    intro v
    rw [min_eq_left (max_le h1 (min_le_right _ _)), max_eq_right (le_max_left _ _)]
  have e2 : ∀ v : ℝ, max (ay.getD 0 0) (min (max (ay.getD 0 0) (min v (ay.getD (ay.length - 1) 0)))
      (ay.getD (ay.length - 1) 0)) = max (ay.getD 0 0) (min v (ay.getD (ay.length - 1) 0)) := by
    intro v
    rw [min_eq_left (max_le h2 (min_le_right _ _)), max_eq_right (le_max_left _ _)]
  simp only [e1, e2]

/-- Bilinear step 5: NaN `x` or NaN `y` gives NaN, whatever the table. -/
theorem bilinear_nan (T : List (List Num)) (ax ay : List Num) (v : Num) :
    bilinear T ax ay Num.nan v = Num.nan ∧ bilinear T ax ay v Num.nan = Num.nan := by
  constructor
  · simp [bilinear, bilinearCell, clamp_nan, weight, blend]
  · simp [bilinear, bilinearCell, clamp_nan, weight, blend]

/-- The cell a query in range selects (half-open, or the last knot). -/
def InCell (a : List ℝ) (i : ℕ) (q : ℝ) : Prop :=
  i + 1 < a.length ∧ a.getD i 0 ≤ q ∧
    (q < a.getD (i + 1) 0 ∨ (i + 2 = a.length ∧ q = a.getD (i + 1) 0))

theorem cell_of_inCell {a : List ℝ} (ha : a.Pairwise (· < ·)) {i : ℕ} {q : ℝ}
    (h : InCell a i q) : cell (Num.fin q) (a.map Num.fin) = i := by
  obtain ⟨hi, h1, h2 | ⟨hl, hq⟩⟩ := h
  · exact cell_eq ha hi h1 h2
  · have e : i + 1 = a.length - 1 := by omega
    rw [hq, e, cell_last ha (by omega)]; omega

theorem inCell_range {a : List ℝ} (ha : a.Pairwise (· < ·)) {i : ℕ} {q : ℝ}
    (h : InCell a i q) : a.getD 0 0 ≤ q ∧ q ≤ a.getD (a.length - 1) 0 := by
  obtain ⟨hi, h1, h2⟩ := h
  refine ⟨(pw_getD_le ha (by omega) (Nat.zero_le _)).trans h1, ?_⟩
  rcases h2 with h2 | ⟨_, h2⟩
  · exact h2.le.trans (pw_getD_le ha (by omega) (by omega))
  · rw [h2]; exact pw_getD_le ha (by omega) (by omega)

/-- Bilinear steps 2–4: a query in cell `(i, j)` is the pinned blend in
that cell. -/
theorem bilinear_in_cell (T : List (List Num)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·)) (i j : ℕ) (x y : ℝ)
    (hi : InCell ax i x) (hj : InCell ay j y) :
    bilinear T (ax.map Num.fin) (ay.map Num.fin) (Num.fin x) (Num.fin y) =
      bilinearCell T (ax.map Num.fin) (ay.map Num.fin) i j (Num.fin x) (Num.fin y) := by
  have hx : 2 ≤ ax.length := by have := hi.1; omega
  have hy : 2 ≤ ay.length := by have := hj.1; omega
  obtain ⟨rx0, rx1⟩ := inCell_range hax hi
  obtain ⟨ry0, ry1⟩ := inCell_range hay hj
  rw [bilinear_clamp_fin T ax ay hx hy (rx0.trans rx1) (ry0.trans ry1)]
  have ex : max (ax.getD 0 0) (min x (ax.getD (ax.length - 1) 0)) = x := by
    rw [min_eq_left rx1, max_eq_right rx0]
  have ey : max (ay.getD 0 0) (min y (ay.getD (ay.length - 1) 0)) = y := by
    rw [min_eq_left ry1, max_eq_right ry0]
  simp only [ex, ey, cell_of_inCell hax hi, cell_of_inCell hay hj]

/-- A finite table: every row's entries are reals. -/
abbrev finTable (U : List (List ℝ)) : List (List Num) := U.map (fun row => row.map Num.fin)

/-- `U[i][j]` with 0 default. -/
def rentry (U : List (List ℝ)) (i j : ℕ) : ℝ := (U.getD i []).getD j 0

theorem entry_finTable {U : List (List ℝ)} {i j : ℕ} (hi : i < U.length)
    (hj : j < (U.getD i []).length) : entry (finTable U) i j = Num.fin (rentry U i j) := by
  have h1 : (U.map (fun row => row.map Num.fin)).getD i [] = (U.getD i []).map Num.fin := by
    rw [List.getD_eq_getElem _ _ (by simpa using hi), List.getElem_map,
      List.getD_eq_getElem _ _ hi]
  unfold entry rentry finTable
  rw [h1]
  exact getD_map_fin hj

/-- The pinned real blend in cell `(i, j)`. -/
noncomputable def realCell (U : List (List ℝ)) (ax ay : List ℝ) (i j : ℕ) (x y : ℝ) : ℝ :=
  let wx := (x - ax.getD i 0) / (ax.getD (i + 1) 0 - ax.getD i 0)
  let wy := (y - ay.getD j 0) / (ay.getD (j + 1) 0 - ay.getD j 0)
  let row_j := rentry U i j + wx * (rentry U (i + 1) j - rentry U i j)
  let row_jp1 := rentry U i (j + 1) + wx * (rentry U (i + 1) (j + 1) - rentry U i (j + 1))
  row_j + wy * (row_jp1 - row_j)

/-- Table shape as validated: `Nx` rows of length `Ny`. -/
def TableShape (U : List (List ℝ)) (nx ny : ℕ) : Prop :=
  U.length = nx ∧ ∀ row ∈ U, row.length = ny

theorem row_length {U : List (List ℝ)} {nx ny : ℕ} (hU : TableShape U nx ny) {i : ℕ}
    (hi : i < nx) : (U.getD i []).length = ny := by
  apply hU.2
  rw [List.getD_eq_getElem _ _ (by rw [hU.1]; exact hi)]
  exact List.getElem_mem _

theorem bilinearCell_fin (U : List (List ℝ)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·))
    (hU : TableShape U ax.length ay.length) (i j : ℕ) (hi : i + 1 < ax.length)
    (hj : j + 1 < ay.length) (x y : ℝ) :
    bilinearCell (finTable U) (ax.map Num.fin) (ay.map Num.fin) i j (Num.fin x) (Num.fin y) =
      Num.fin (realCell U ax ay i j x y) := by
  have dx : ax.getD (i + 1) 0 - ax.getD i 0 ≠ 0 := by
    have := pw_getD_lt hax hi (Nat.lt_succ_self i); linarith
  have dy : ay.getD (j + 1) 0 - ay.getD j 0 ≠ 0 := by
    have := pw_getD_lt hay hj (Nat.lt_succ_self j); linarith
  have r : ∀ k, k < ax.length → ∀ l, l < ay.length →
      entry (finTable U) k l = Num.fin (rentry U k l) := by
    intro k hk l hl
    exact entry_finTable (by rw [hU.1]; exact hk) (by rw [row_length hU hk]; exact hl)
  simp only [bilinearCell, Num.nan_def, getD_map_fin hi, getD_map_fin (show i < ax.length by omega),
    getD_map_fin hj, getD_map_fin (show j < ay.length by omega), weight, Num.sub_fin,
    Num.div_fin _ _ dx, Num.div_fin _ _ dy, r i (by omega) j (by omega),
    r (i + 1) hi j (by omega), r i (by omega) (j + 1) hj, r (i + 1) hi (j + 1) hj, blend_fin,
    realCell]

/-- Bilinear: on a finite table, a query exactly on knot `(k, l)` returns
`table[k][l]` (over ℝ; whether the w = 1 case at the last knot is exact in
binary64 is a separate, rounding, claim). -/
theorem bilinear_knot (U : List (List ℝ)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·)) (hx : 2 ≤ ax.length)
    (hy : 2 ≤ ay.length) (hU : TableShape U ax.length ay.length) (k l : ℕ)
    (hk : k < ax.length) (hl : l < ay.length) :
    bilinear (finTable U) (ax.map Num.fin) (ay.map Num.fin)
      (Num.fin (ax.getD k 0)) (Num.fin (ay.getD l 0)) = Num.fin (rentry U k l) := by
  -- the cell along each axis, and its weight: 0 inside, 1 at the last knot
  have cellx : ∃ i, InCell ax i (ax.getD k 0) ∧ ((i = k ∧ i + 1 < ax.length) ∨ (i + 1 = k)) := by
    by_cases h : k + 1 < ax.length
    · exact ⟨k, ⟨h, le_rfl, Or.inl (pw_getD_lt hax h (Nat.lt_succ_self k))⟩, Or.inl ⟨rfl, h⟩⟩
    · refine ⟨k - 1, ⟨by omega, pw_getD_le hax hk (by omega), Or.inr ⟨by omega, ?_⟩⟩, Or.inr (by omega)⟩
      congr 1; omega
  have celly : ∃ j, InCell ay j (ay.getD l 0) ∧ ((j = l ∧ j + 1 < ay.length) ∨ (j + 1 = l)) := by
    by_cases h : l + 1 < ay.length
    · exact ⟨l, ⟨h, le_rfl, Or.inl (pw_getD_lt hay h (Nat.lt_succ_self l))⟩, Or.inl ⟨rfl, h⟩⟩
    · refine ⟨l - 1, ⟨by omega, pw_getD_le hay hl (by omega), Or.inr ⟨by omega, ?_⟩⟩, Or.inr (by omega)⟩
      congr 1; omega
  obtain ⟨i, hi, hik⟩ := cellx
  obtain ⟨j, hj, hjl⟩ := celly
  rw [bilinear_in_cell _ ax ay hax hay i j _ _ hi hj,
    bilinearCell_fin U ax ay hax hay hU i j hi.1 hj.1]
  congr 1
  have dx : ax.getD (i + 1) 0 - ax.getD i 0 ≠ 0 := by
    have := pw_getD_lt hax hi.1 (Nat.lt_succ_self i); linarith
  have dy : ay.getD (j + 1) 0 - ay.getD j 0 ≠ 0 := by
    have := pw_getD_lt hay hj.1 (Nat.lt_succ_self j); linarith
  simp only [realCell]
  rcases hik with ⟨rfl, _⟩ | rfl <;> rcases hjl with ⟨rfl, _⟩ | rfl <;>
    simp only [sub_self, zero_div, div_self dx, div_self dy] <;> ring

/-- Bilinear: on a finite table, the result in cell `(i, j)` lies between
the smallest and largest of that cell's four corners. -/
theorem bilinear_between (U : List (List ℝ)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·))
    (hU : TableShape U ax.length ay.length) (i j : ℕ) (x y : ℝ)
    (hi : InCell ax i x) (hj : InCell ay j y) :
    ∃ r, bilinear (finTable U) (ax.map Num.fin) (ay.map Num.fin) (Num.fin x) (Num.fin y) =
        Num.fin r ∧
      min (min (rentry U i j) (rentry U (i + 1) j)) (min (rentry U i (j + 1)) (rentry U (i + 1) (j + 1))) ≤ r ∧
      r ≤ max (max (rentry U i j) (rentry U (i + 1) j)) (max (rentry U i (j + 1)) (rentry U (i + 1) (j + 1))) := by
  rw [bilinear_in_cell _ ax ay hax hay i j _ _ hi hj,
    bilinearCell_fin U ax ay hax hay hU i j hi.1 hj.1]
  refine ⟨_, rfl, ?_⟩
  have w01 : ∀ (a : List ℝ) (k : ℕ) (q : ℝ), a.Pairwise (· < ·) → InCell a k q →
      0 ≤ (q - a.getD k 0) / (a.getD (k + 1) 0 - a.getD k 0) ∧
      (q - a.getD k 0) / (a.getD (k + 1) 0 - a.getD k 0) ≤ 1 := by
    intro a k q ha hk
    have hlt := pw_getD_lt ha hk.1 (Nat.lt_succ_self k)
    have hq : q ≤ a.getD (k + 1) 0 := by
      rcases hk.2.2 with h | ⟨_, h⟩
      · exact h.le
      · exact h.le
    exact ⟨div_nonneg (by linarith [hk.2.1]) (by linarith),
      (div_le_one (by linarith)).mpr (by linarith)⟩
  obtain ⟨wx0, wx1⟩ := w01 ax i x hax hi
  obtain ⟨wy0, wy1⟩ := w01 ay j y hay hj
  simp only [realCell]
  set wx := (x - ax.getD i 0) / (ax.getD (i + 1) 0 - ax.getD i 0)
  set wy := (y - ay.getD j 0) / (ay.getD (j + 1) 0 - ay.getD j 0)
  obtain ⟨a1, a2⟩ := blend_between (rentry U i j) (rentry U (i + 1) j) wx wx0 wx1
  obtain ⟨b1, b2⟩ := blend_between (rentry U i (j + 1)) (rentry U (i + 1) (j + 1)) wx wx0 wx1
  obtain ⟨c1, c2⟩ := blend_between
    (rentry U i j + wx * (rentry U (i + 1) j - rentry U i j))
    (rentry U i (j + 1) + wx * (rentry U (i + 1) (j + 1) - rentry U i (j + 1))) wy wy0 wy1
  constructor
  · refine le_trans ?_ c1
    exact le_min (le_trans (min_le_left _ _) a1) (le_trans (min_le_right _ _) b1)
  · refine le_trans c2 ?_
    exact max_le (le_trans a2 (le_max_left _ _)) (le_trans b2 (le_max_right _ _))

/-- Bilinear step 2: at an interior x-knot `k`, the alternative cell
`i = k − 1` (weight 1) gives the same value as the pinned `i = k` (weight 0),
over ℝ on a finite table. (Bit-identity in binary64 is a rounding claim.) -/
theorem bilinear_alt_cell (U : List (List ℝ)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (k j : ℕ) (hk0 : 0 < k) (hk : k + 1 < ax.length) (y : ℝ) :
    realCell U ax ay (k - 1) j (ax.getD k 0) y = realCell U ax ay k j (ax.getD k 0) y := by
  have e : k - 1 + 1 = k := by omega
  have d : ax.getD k 0 - ax.getD (k - 1) 0 ≠ 0 := by
    have := pw_getD_lt hax (i := k - 1) (j := k) (by omega) (by omega); linarith
  simp only [realCell, e, div_self d, sub_self, zero_div]
  ring

/-- Bilinear step 5: a query in a cell with a NaN corner gives NaN. -/
theorem bilinear_nan_corner (T : List (List Num)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·)) (i j : ℕ) (x y : ℝ)
    (hi : InCell ax i x) (hj : InCell ay j y)
    (hnan : (entry T i j).isNaN = true ∨ (entry T (i + 1) j).isNaN = true ∨
      (entry T i (j + 1)).isNaN = true ∨ (entry T (i + 1) (j + 1)).isNaN = true) :
    bilinear T (ax.map Num.fin) (ay.map Num.fin) (Num.fin x) (Num.fin y) = Num.nan := by
  rw [bilinear_in_cell T ax ay hax hay i j x y hi hj]
  have isn : ∀ v : Num, v.isNaN = true → v = Num.nan := by
    intro v hv; cases v
    · simp at hv
    · rfl
  simp only [bilinearCell]
  rcases hnan with h | h | h | h <;> rw [isn _ h] <;> simp [blend]

end Bilinear

end Esm.Closed
