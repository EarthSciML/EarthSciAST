import Esm.Closed.Interp
import Esm.Closed.Interp.Bilinear64

/-!
# The pure-AST interpolation templates of `lib/interp.esm`

`lib/interp.esm` writes `searchsorted`, `linear` and `bilinear` as expression
templates (esm-spec §9.7.1) built from `faq`, `ifelse`, `index`, `min`, `max`
and the four arithmetic operations, instead of the `fn` primitives of §9.2.
This file states that the template expansions compute what the primitives
compute.

The model has no AST evaluator for `faq` yet, so the three templates are
written below as Lean functions that mirror the AST bodies term for term:

* `ix l k` is `index(l, k)` (1-based, NaN out of range), `ix2` its rank-2 form;
* `faqSum n f` is a `faq` with `reduce: "+"` over `k ∈ [1, n]`, folded in
  index order from a zero seed; its terms are the `ifelse(c, 1, 0)` /
  `ifelse(c, 0, 1)` of the template, so every partial sum is a small natural
  number. The fold is kept over `ℕ`: `faqSum_binary64` shows that the binary64
  fold of the same terms seeded at `+0.0` is exactly that natural number, and
  `clamp_binary64` that the `min(max(·, 1), n − 1)` around it is too, so a
  binary64 evaluation of the AST indexes the same knot;
* the cell index `i` is `cellIdx` written out at each use, as the template
  writes it; the arithmetic is in the template's (= §9.2's pinned) order.

Everything else is generic over `Scalar`, like the primitives. The equalities
are proven for every scalar type satisfying `RealNaN` (finite reals plus one
NaN, IEEE comparisons, NaN absorbing in the four operations). Two instances:
`Num` (exact arithmetic) and `Bin64` (the binary64 model of `Esm/Float64.lean`
with a NaN added: every operation rounds once, to nearest even). At `Bin64` the
equalities are bit-for-bit, so the binary64 rounding bounds proven about the
primitives' pinned order carry over to the templates unchanged
(`linear64_fma_le_two_ulp`, `bilinear64_fma_le`).

Main results:

* `searchsorted_eq`: the template equals `Esm.Closed.searchsorted` for every
  query (NaN included) on a non-decreasing `xs`, `n = |xs|`, including `n = 0`.
* `cellIdx_eq_cell`: `count(axis[k] ≤ q)` clamped to `[1, n − 1]` is one more
  than the primitives' 0-based `cell`, for every real `q`; `cellIdx_spec`
  restates it as §9.2's "largest `i ∈ [1, n−1]` with `a_i ≤ q`".
* `linear_eq`, `bilinear_eq`: the templates equal `Esm.Closed.linear` /
  `Esm.Closed.bilinear` for every query (NaN included) and every table,
  on non-decreasing axes with `n ≥ 2` (a strictly increasing axis is one).
-/

namespace Esm.Closed.Template

open Esm.Closed Scalar

/-! ## The templates -/

section Defs

variable {α : Type} [Scalar α]

/-- `index(l, k)`, 1-based; NaN out of range. -/
def ix (l : List α) (k : ℕ) : α := l.getD (k - 1) nan

/-- `index(T, i, j)`, 1-based, on a row-major table. -/
def ix2 (T : List (List α)) (i j : ℕ) : α := entry T (i - 1) (j - 1)

/-- A `faq` with `reduce: "+"`, `output_idx: []` and `ranges: {k: [1, n]}`,
folded in index order from a zero seed. -/
def faqSum (n : ℕ) (f : ℕ → ℕ) : ℕ :=
  (List.range n).foldl (fun acc k => acc + f (k + 1)) 0

/-- `searchsorted(x, xs, n) = 1 + faq_{k ∈ [1,n]} ifelse(index(xs,k) >= x, 0, 1)`. -/
def searchsorted (x : α) (xs : List α) (n : ℕ) : ℕ :=
  1 + faqSum n (fun k => if le x (ix xs k) then 0 else 1)

/-- `count_{k ∈ [1,n]}(index(axis,k) <= q)`. -/
def countLe (axis : List α) (q : α) (n : ℕ) : ℕ :=
  faqSum n (fun k => if le (ix axis k) q then 1 else 0)

/-- `i = min(max(count_{k ∈ [1,n]}(index(axis,k) <= q), 1), n - 1)`. -/
def cellIdx (axis : List α) (q : α) (n : ℕ) : ℕ :=
  min (max (countLe axis q n) 1) (n - 1)

/-- The `linear` template (params `table, axis, x, n`). -/
def linear (table axis : List α) (x : α) (n : ℕ) : α :=
  if le x (ix axis 1) then ix table 1
  else if le (ix axis n) x then ix table n
  else
    add (ix table (cellIdx axis x n))
      (mul
        (div (sub x (ix axis (cellIdx axis x n)))
          (sub (ix axis (cellIdx axis x n + 1)) (ix axis (cellIdx axis x n))))
        (sub (ix table (cellIdx axis x n + 1)) (ix table (cellIdx axis x n))))

/-- The `bilinear` template (params `table, axis_x, axis_y, x, y, nx, ny`).
The `let`s only name sub-trees; each is substituted at its uses. -/
def bilinear (table : List (List α)) (axis_x axis_y : List α) (x y : α) (nx ny : ℕ) : α :=
  let xq := if le x (ix axis_x 1) then ix axis_x 1
    else if le (ix axis_x nx) x then ix axis_x nx else x
  let yq := if le y (ix axis_y 1) then ix axis_y 1
    else if le (ix axis_y ny) y then ix axis_y ny else y
  let i := cellIdx axis_x xq nx
  let j := cellIdx axis_y yq ny
  let wx := div (sub xq (ix axis_x i)) (sub (ix axis_x (i + 1)) (ix axis_x i))
  let wy := div (sub yq (ix axis_y j)) (sub (ix axis_y (j + 1)) (ix axis_y j))
  let row_j := add (ix2 table i j) (mul wx (sub (ix2 table (i + 1) j) (ix2 table i j)))
  let row_jp1 :=
    add (ix2 table i (j + 1)) (mul wx (sub (ix2 table (i + 1) (j + 1)) (ix2 table i (j + 1))))
  add row_j (mul wy (sub row_jp1 row_j))

end Defs

/-! ## Scalars with real values and one NaN -/

/-- A scalar type whose values are finite reals or NaN, compared as IEEE
compares them, with NaN absorbing in the operations the templates use. -/
class RealNaN (α : Type) [Scalar α] where
  fin : ℝ → α
  cases : ∀ x : α, x = nan ∨ ∃ r, x = fin r
  le_fin : ∀ a b, le (fin a) (fin b) = decide (a ≤ b)
  lt_fin : ∀ a b, lt (fin a) (fin b) = decide (a < b)
  nan_le : ∀ x : α, le nan x = false
  le_nan : ∀ x : α, le x nan = false
  nan_sub : ∀ x : α, sub nan x = nan
  nan_div : ∀ x : α, div nan x = nan
  nan_mul : ∀ x : α, mul nan x = nan
  nan_add : ∀ x : α, add nan x = nan
  add_nan : ∀ x : α, add x nan = nan

noncomputable instance : RealNaN Num where
  fin := Num.fin
  cases x := by
    cases x with
    | fin r => exact Or.inr ⟨r, rfl⟩
    | nan => exact Or.inl rfl
  le_fin _ _ := rfl
  lt_fin _ _ := rfl
  nan_le := Num.nan_le
  le_nan := Num.le_nan
  nan_sub := Num.nan_sub
  nan_div := Num.nan_div
  nan_mul := Num.nan_mul
  nan_add := Num.nan_add
  add_nan := Num.add_nan

/-- The binary64 model of `Esm/Float64.lean` with a NaN: a finite value or NaN,
every operation rounded once to nearest even (`Esm.F64.fadd` …), NaN
propagating. Division follows `Esm.F64.fdiv` (a zero divisor never occurs
between two distinct knots of a binary64 axis). -/
inductive Bin64 where
  | fin (r : ℝ)
  | nan

namespace Bin64

open Esm.F64

noncomputable def lift₂ (f : ℝ → ℝ → ℝ) : Bin64 → Bin64 → Bin64
  | fin a, fin b => fin (f a b)
  | _, _ => nan

noncomputable def le : Bin64 → Bin64 → Bool
  | fin a, fin b => decide (a ≤ b)
  | _, _ => false

noncomputable def lt : Bin64 → Bin64 → Bool
  | fin a, fin b => decide (a < b)
  | _, _ => false

def isNaN : Bin64 → Bool
  | fin _ => false
  | nan => true

noncomputable instance : Scalar Bin64 where
  nan := .nan
  add := lift₂ fadd
  sub := lift₂ fsub
  mul := lift₂ fmul
  div := lift₂ fdiv
  le := le
  lt := lt
  isNaN := isNaN
  nonFinite := isNaN

noncomputable instance : RealNaN Bin64 where
  fin := fin
  cases x := by
    cases x with
    | fin r => exact Or.inr ⟨r, rfl⟩
    | nan => exact Or.inl rfl
  le_fin _ _ := rfl
  lt_fin _ _ := rfl
  nan_le x := by cases x <;> rfl
  le_nan x := by cases x <;> rfl
  nan_sub x := by cases x <;> rfl
  nan_div x := by cases x <;> rfl
  nan_mul x := by cases x <;> rfl
  nan_add x := by cases x <;> rfl
  add_nan x := by cases x <;> rfl

end Bin64

/-! ## Counting -/

theorem faqSum_succ (n : ℕ) (f : ℕ → ℕ) : faqSum (n + 1) f = faqSum n f + f (n + 1) := by
  simp [faqSum, List.range_succ, List.foldl_append]

theorem faqSum_congr {n : ℕ} {f g : ℕ → ℕ} (h : ∀ k, 1 ≤ k → k ≤ n → f k = g k) :
    faqSum n f = faqSum n g := by
  induction n with
  | zero => rfl
  | succ n ih =>
    rw [faqSum_succ, faqSum_succ, ih (fun k h1 h2 => h k h1 (by omega)), h (n + 1) (by omega) le_rfl]

/-- A `faq` count of `ifelse(P(l[k]), 0, 1)` over the whole of `l`, where `P`
once true stays true along `l`, is the index of the first `k` with `P`. -/
theorem faqSum_not_eq_findIdx {α : Type} (l : List α) (P : α → Bool) (d : α)
    (hup : ∀ i j (hij : i ≤ j) (hj : j < l.length), P (l[i]'(by omega)) = true → P l[j] = true) :
    faqSum l.length (fun k => if P (l.getD (k - 1) d) then 0 else 1) = l.findIdx P := by
  have key : ∀ N, N ≤ l.length →
      faqSum N (fun k => if P (l.getD (k - 1) d) then 0 else 1) = min N (l.findIdx P) := by
    intro N
    induction N with
    | zero => intro _; simp [faqSum]
    | succ N ih =>
      intro hN
      rw [faqSum_succ, ih (by omega)]
      rw [Nat.add_sub_cancel, List.getD_eq_getElem _ _ (show N < l.length by omega)]
      by_cases hm : N < l.findIdx P
      · have : P l[N] = false := by simpa using List.not_of_lt_findIdx hm
        simp only [this, Bool.false_eq_true, ↓reduceIte]
        omega
      · have hml : l.findIdx P < l.length := by omega
        have hp : P l[N] = true := hup (l.findIdx P) N (by omega) (by omega) (List.findIdx_getElem (w := hml))
        simp only [hp, ↓reduceIte]
        omega
  rw [key l.length le_rfl]
  exact min_eq_right (List.findIdx_le_length)

section Real

variable {α : Type} [Scalar α] [RealNaN α]
open RealNaN

theorem getD_map {a : List ℝ} {k : ℕ} (hk : k < a.length) :
    (a.map (fin : ℝ → α)).getD k nan = fin (a.getD k 0) := by
  rw [List.getD_eq_getElem _ _ (by simpa using hk), List.getD_eq_getElem _ _ hk]
  simp

/-! ## `searchsorted` -/

/-- The `searchsorted` template equals the primitive whenever `le x` is
upward closed along `xs` (once `xs[i] ≥ x`, every later knot is too). -/
theorem searchsorted_eq_of_upward {β : Type} [Scalar β] (x : β) (xs : List β)
    (hup : ∀ i j (hij : i ≤ j) (hj : j < xs.length),
      le x (xs[i]'(by omega)) = true → le x xs[j] = true) :
    searchsorted x xs xs.length = Esm.Closed.searchsorted x xs := by
  unfold searchsorted Esm.Closed.searchsorted ix
  rw [faqSum_not_eq_findIdx xs (fun a => le x a) nan hup]
  omega

/-- §9.2 `searchsorted`, as a template: on a non-decreasing `xs` of length
`n`, `1 + count(not(xs[k] >= x))` is the primitive's result for every query,
NaN included (`n + 1`), and for `n = 0` (`1`). -/
theorem searchsorted_eq (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (x : α) :
    searchsorted x (a.map fin) a.length = Esm.Closed.searchsorted x (a.map fin) := by
  have := searchsorted_eq_of_upward x (a.map fin) ?_
  · simpa using this
  intro i j hij hj hi
  simp only [List.length_map] at hj
  simp only [List.getElem_map] at hi ⊢
  rcases RealNaN.cases x with rfl | ⟨r, rfl⟩
  · rw [nan_le] at hi; exact absurd hi (by simp)
  · rw [le_fin] at hi ⊢
    simp only [decide_eq_true_eq] at hi ⊢
    rcases eq_or_lt_of_le hij with rfl | h
    · exact hi
    · exact hi.trans (List.pairwise_iff_getElem.mp ha i j (by omega) hj h)

/-! ## The cell index -/

/-- On a non-decreasing real axis, `count(axis[k] <= q)` for a real `q` is the
index of the first knot strictly above `q`, which `cell` is defined from. -/
theorem countLe_eq_findIdx (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (q : ℝ) :
    countLe (a.map fin) (fin q : α) a.length = (a.map fin).findIdx (fun b => lt (fin q : α) b) := by
  have h := faqSum_not_eq_findIdx (a.map (fin : ℝ → α)) (fun b => lt (fin q : α) b) nan ?_
  · rw [List.length_map] at h
    rw [← h]
    unfold countLe ix
    apply faqSum_congr
    intro k hk1 hk
    have hk' : k - 1 < a.length := by omega
    rw [getD_map hk', le_fin, lt_fin]
    by_cases hq : a.getD (k - 1) 0 ≤ q
    · rw [decide_eq_true hq, decide_eq_false (not_lt.mpr hq)]; rfl
    · rw [decide_eq_false hq, decide_eq_true (not_le.mp hq)]; rfl
  · intro i j hij hj hi
    simp only [List.length_map] at hj
    simp only [List.getElem_map, lt_fin, decide_eq_true_eq] at hi ⊢
    rcases eq_or_lt_of_le hij with rfl | h
    · exact hi
    · exact lt_of_lt_of_le hi (List.pairwise_iff_getElem.mp ha i j (by omega) hj h)

/-- `cell` reads only `lt` against the knots, so it is the same at every
`RealNaN` scalar on a real query and a real axis. -/
theorem cell_transfer (a : List ℝ) (q : ℝ) :
    cell (fin q : α) (a.map fin) = cell (Num.fin q) (a.map Num.fin) := by
  unfold cell
  simp only [List.findIdx_map, List.length_map, Function.comp_def, lt_fin, Num.lt_fin]

/-- **The key lemma.** On a non-decreasing real axis of `n ≥ 2` knots, the
template's cell index `min(max(count(axis[k] <= q), 1), n - 1)` is one more
(1-based) than the primitives' 0-based `cell`, for every real query. -/
theorem cellIdx_eq_cell (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (hn : 2 ≤ a.length) (q : ℝ) :
    cellIdx (a.map fin) (fin q : α) a.length = cell (fin q : α) (a.map fin) + 1 := by
  unfold cellIdx cell
  rw [countLe_eq_findIdx a ha q, List.length_map]
  omega

/-- §9.2's cell, read off the template: on a strictly increasing axis of
`n ≥ 2` knots and a query `q ∈ [a_1, a_n]`, the template's 1-based `i` lies in
`[1, n − 1]` with `a_i ≤ q < a_{i+1}`, or `q` is the last knot and
`i = n − 1`; so `i` is the largest index in `[1, n − 1]` with `a_i ≤ q`.
(Lists are 0-based: `a_i` is `a.getD (i - 1) 0`.) -/
theorem cellIdx_spec (a : List ℝ) (ha : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) {q : ℝ}
    (h0 : a.getD 0 0 ≤ q) (hL : q ≤ a.getD (a.length - 1) 0) :
    let i := cellIdx (a.map fin) (fin q : α) a.length
    1 ≤ i ∧ i ≤ a.length - 1 ∧ a.getD (i - 1) 0 ≤ q ∧
      (q < a.getD i 0 ∨ (i = a.length - 1 ∧ q = a.getD i 0)) := by
  intro i
  have e : i = cell (Num.fin q) (a.map Num.fin) + 1 := by
    simp only [i]; rw [cellIdx_eq_cell a (ha.imp le_of_lt) hn q, cell_transfer]
  obtain ⟨h1, h2, h3⟩ := cell_spec ha hn h0 hL
  rw [e, Nat.add_sub_cancel]
  refine ⟨by omega, by omega, h2, ?_⟩
  rcases h3 with h | ⟨hl, hq⟩
  · exact Or.inl h
  · exact Or.inr ⟨by omega, hq⟩

/-- The interior-knot convention: a query exactly on 1-based knot `k + 1`
(with a knot after it) gets `i = k + 1`, so its weight is 0. -/
theorem cellIdx_knot (a : List ℝ) (ha : a.Pairwise (· < ·)) (k : ℕ) (hk : k + 1 < a.length) :
    cellIdx (a.map fin) (fin (a.getD k 0) : α) a.length = k + 1 := by
  rw [cellIdx_eq_cell a (ha.imp le_of_lt) (by omega), cell_transfer,
    cell_eq ha hk le_rfl (pw_getD_lt ha hk (Nat.lt_succ_self k))]

/-! ## `linear` -/

/-- §9.2 `interp.linear`, as a template: on a non-decreasing axis of `n ≥ 2`
knots, the template equals the primitive for every table and every query, NaN
included. Equality is of the scalar values, so at `Bin64` it is bit-for-bit. -/
theorem linear_eq (t : List α) (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (hn : 2 ≤ a.length)
    (x : α) : linear t (a.map fin) x a.length = Esm.Closed.linear t (a.map fin) x := by
  rcases RealNaN.cases x with rfl | ⟨r, rfl⟩
  · simp only [linear, Esm.Closed.linear, nan_le, le_nan, nan_sub, nan_div, nan_mul, add_nan,
      blend, weight, Bool.false_eq_true, ↓reduceIte]
  · unfold linear Esm.Closed.linear
    rw [cellIdx_eq_cell a ha hn r]
    simp only [ix, Nat.add_sub_cancel, Nat.sub_self, List.length_map, blend, weight]

/-! ## `bilinear` -/

theorem bilinearCell_nan_x (T : List (List α)) (ax ay : List α) (i j : ℕ) (yq : α) :
    bilinearCell T ax ay i j nan yq = nan := by
  simp only [bilinearCell, blend, weight, nan_sub, nan_div, nan_mul, add_nan, nan_add]

theorem bilinearCell_nan_y (T : List (List α)) (ax ay : List α) (i j : ℕ) (xq : α) :
    bilinearCell T ax ay i j xq nan = nan := by
  simp only [bilinearCell, blend, weight, nan_sub, nan_div, nan_mul, add_nan]

/-- §9.2 `interp.bilinear`, as a template: on non-decreasing axes of at least
two knots each, the template equals the primitive for every table and every
query, NaN in either coordinate included. -/
theorem bilinear_eq (T : List (List α)) (ax ay : List ℝ) (hax : ax.Pairwise (· ≤ ·))
    (hay : ay.Pairwise (· ≤ ·)) (hx : 2 ≤ ax.length) (hy : 2 ≤ ay.length) (x y : α) :
    bilinear T (ax.map fin) (ay.map fin) x y ax.length ay.length =
      Esm.Closed.bilinear T (ax.map fin) (ay.map fin) x y := by
  unfold bilinear Esm.Closed.bilinear
  simp only [List.length_map]
  generalize hxq : clamp x ((ax.map fin).getD 0 nan) ((ax.map fin).getD (ax.length - 1) nan) = xq
  generalize hyq : clamp y ((ay.map fin).getD 0 nan) ((ay.map fin).getD (ay.length - 1) nan) = yq
  have ex : (if le x (ix (ax.map (fin : ℝ → α)) 1) then ix (ax.map fin) 1
      else if le (ix (ax.map fin) ax.length) x then ix (ax.map fin) ax.length else x) = xq := by
    rw [← hxq]; rfl
  have ey : (if le y (ix (ay.map (fin : ℝ → α)) 1) then ix (ay.map fin) 1
      else if le (ix (ay.map fin) ay.length) y then ix (ay.map fin) ay.length else y) = yq := by
    rw [← hyq]; rfl
  simp only [ex, ey]
  rcases RealNaN.cases xq with rfl | ⟨p, rfl⟩
  · rw [bilinearCell_nan_x]
    simp only [nan_sub, nan_div, nan_mul, add_nan, nan_add]
  rcases RealNaN.cases yq with rfl | ⟨q, rfl⟩
  · rw [bilinearCell_nan_y]
    simp only [nan_sub, nan_div, nan_mul, add_nan]
  rw [cellIdx_eq_cell ax hax hx p, cellIdx_eq_cell ay hay hy q]
  simp only [ix, ix2, Nat.add_sub_cancel, bilinearCell, blend, weight]

/-! ## Real queries in a cell -/

theorem clamp_fin_real (x lo hi : ℝ) (h : lo ≤ hi) :
    clamp (fin x : α) (fin lo) (fin hi) = fin (max lo (min x hi)) := by
  unfold clamp
  rw [le_fin, le_fin]
  by_cases h1 : x ≤ lo
  · simp [h1, min_eq_left (h1.trans h)]
  · by_cases h2 : hi ≤ x
    · simp [h1, h2, h]
    · have : max lo (min x hi) = x := by
        rw [min_eq_left (le_of_lt (not_le.mp h2)), max_eq_right (le_of_lt (not_le.mp h1))]
      simp [h1, h2, this]

/-- Inside cell `i` (and above the first knot), the `linear` template is the
pinned blend with the pinned weight. -/
theorem linear_in_cell_real (t : List α) (a : List ℝ) (ha : a.Pairwise (· < ·)) (i : ℕ) (x : ℝ)
    (hi : i + 1 < a.length) (h0 : a.getD 0 0 < x) (h1 : a.getD i 0 ≤ x)
    (h2 : x < a.getD (i + 1) 0) :
    linear t (a.map fin) (fin x) a.length =
      blend (t.getD i nan) (t.getD (i + 1) nan)
        (weight (fin x) (fin (a.getD i 0)) (fin (a.getD (i + 1) 0))) := by
  rw [linear_eq t a (ha.imp le_of_lt) (by omega)]
  have hL : ¬ a.getD (a.length - 1) 0 ≤ x :=
    not_le.mpr (lt_of_lt_of_le h2 (pw_getD_le ha (by omega) (by omega)))
  unfold Esm.Closed.linear
  simp only [List.length_map, getD_map (show 0 < a.length by omega),
    getD_map (show a.length - 1 < a.length by omega), le_fin,
    not_le.mpr h0, hL, ↓reduceIte, decide_false, Bool.false_eq_true]
  rw [cell_transfer, cell_eq ha hi h1 h2, getD_map (by omega), getD_map hi]

/-- In cell `(i, j)`, the `bilinear` template is the pinned blend in that cell. -/
theorem bilinear_in_cell_real (T : List (List α)) (ax ay : List ℝ)
    (hax : ax.Pairwise (· < ·)) (hay : ay.Pairwise (· < ·)) (i j : ℕ) (x y : ℝ)
    (hi : InCell ax i x) (hj : InCell ay j y) :
    bilinear T (ax.map fin) (ay.map fin) (fin x) (fin y) ax.length ay.length =
      bilinearCell T (ax.map fin) (ay.map fin) i j (fin x) (fin y) := by
  have hx : 2 ≤ ax.length := by have := hi.1; omega
  have hy : 2 ≤ ay.length := by have := hj.1; omega
  obtain ⟨rx0, rx1⟩ := inCell_range hax hi
  obtain ⟨ry0, ry1⟩ := inCell_range hay hj
  rw [bilinear_eq T ax ay (hax.imp le_of_lt) (hay.imp le_of_lt) hx hy]
  unfold Esm.Closed.bilinear
  have ex : max (ax.getD 0 0) (min x (ax.getD (ax.length - 1) 0)) = x := by
    rw [min_eq_left rx1, max_eq_right rx0]
  have ey : max (ay.getD 0 0) (min y (ay.getD (ay.length - 1) 0)) = y := by
    rw [min_eq_left ry1, max_eq_right ry0]
  simp only [List.length_map, getD_map (show 0 < ax.length by omega),
    getD_map (show ax.length - 1 < ax.length by omega), getD_map (show 0 < ay.length by omega),
    getD_map (show ay.length - 1 < ay.length by omega), clamp_fin_real _ _ _ (rx0.trans rx1),
    clamp_fin_real _ _ _ (ry0.trans ry1), ex, ey, cell_transfer, cell_of_inCell hax hi,
    cell_of_inCell hay hj]

theorem entry_map (U : List (List ℝ)) {i j : ℕ} (hi : i < U.length)
    (hj : j < (U.getD i []).length) :
    entry (U.map (List.map (fin : ℝ → α))) i j = fin (rentry U i j) := by
  have h1 : (U.map (List.map (fin : ℝ → α))).getD i [] = (U.getD i []).map fin := by
    rw [List.getD_eq_getElem _ _ (by simpa using hi), List.getElem_map,
      List.getD_eq_getElem _ _ hi]
  unfold entry rentry
  rw [h1]
  exact getD_map hj

end Real

/-! ## Binary64: the rounding bounds, about the templates -/

section Binary64

open Esm.F64 Esm.Closed.Rounding

theorem getD_map_bin64 {a : List ℝ} {k : ℕ} (hk : k < a.length) :
    (a.map Bin64.fin).getD k nan = Bin64.fin (a.getD k 0) :=
  getD_map (α := Bin64) hk

/-- **Q-6 for the `linear` template.** On a strictly increasing axis, a
binary64 table and a query inside cell `i` (above the first knot), the template
evaluated in binary64 is the pinned binary64 blend `blend64` with the pinned
weight `weight64`, and so lies within `2 · ulp(max(|t_i|, |t_{i+1}|))` of the
FMA blend (`Esm.Closed.Rounding.linear_fma_le_two_ulp`). -/
theorem linear64_fma_le_two_ulp (u a : List ℝ) (ha : a.Pairwise (· < ·))
    (hlen : u.length = a.length) (i : ℕ) (x : ℝ) (hi : i + 1 < a.length)
    (h0 : a.getD 0 0 < x) (h1 : a.getD i 0 ≤ x) (h2 : x < a.getD (i + 1) 0)
    (hu0 : Repr (u.getD i 0)) (hu1 : Repr (u.getD (i + 1) 0)) :
    linear (u.map Bin64.fin) (a.map Bin64.fin) (Bin64.fin x) a.length =
        Bin64.fin (blend64 (u.getD i 0) (u.getD (i + 1) 0)
          (weight64 x (a.getD i 0) (a.getD (i + 1) 0))) ∧
      |blend64 (u.getD i 0) (u.getD (i + 1) 0) (weight64 x (a.getD i 0) (a.getD (i + 1) 0)) -
          blendFMA (u.getD i 0) (u.getD (i + 1) 0) (weight64 x (a.getD i 0) (a.getD (i + 1) 0))| ≤
        2 * ulp (max |u.getD i 0| |u.getD (i + 1) 0|) := by
  refine ⟨?_, linear_fma_le_two_ulp _ _ _ _ _ hu0 hu1 h1 h2.le⟩
  refine (linear_in_cell_real (α := Bin64) (u.map Bin64.fin) a ha i x hi h0 h1 h2).trans ?_
  rw [getD_map_bin64 (show i < u.length by omega), getD_map_bin64 (show i + 1 < u.length by omega)]
  rfl

/-- **Q-6 for the `bilinear` template.** On strictly increasing axes, a
binary64 table of the validated shape and a query in cell `(i, j)`, the
template evaluated in binary64 is the pinned binary64 bilinear blend
`bilinear64` with the pinned weights, and so lies within
`17/2 · ulp(max |corner|)` of the all-FMA evaluation
(`Esm.Closed.Rounding.bilinear_fma_le`). -/
theorem bilinear64_fma_le (U : List (List ℝ)) (ax ay : List ℝ) (hax : ax.Pairwise (· < ·))
    (hay : ay.Pairwise (· < ·)) (hU : TableShape U ax.length ay.length) (i j : ℕ) (x y : ℝ)
    (hi : InCell ax i x) (hj : InCell ay j y)
    (h00 : Repr (rentry U i j)) (h10 : Repr (rentry U (i + 1) j))
    (h01 : Repr (rentry U i (j + 1))) (h11 : Repr (rentry U (i + 1) (j + 1))) :
    let wx := weight64 x (ax.getD i 0) (ax.getD (i + 1) 0)
    let wy := weight64 y (ay.getD j 0) (ay.getD (j + 1) 0)
    let c := bilinear64 (rentry U i j) (rentry U (i + 1) j) (rentry U i (j + 1))
      (rentry U (i + 1) (j + 1)) wx wy
    bilinear (U.map (List.map Bin64.fin)) (ax.map Bin64.fin) (ay.map Bin64.fin)
        (Bin64.fin x) (Bin64.fin y) ax.length ay.length = Bin64.fin c ∧
      |c - bilinearFMA (rentry U i j) (rentry U (i + 1) j) (rentry U i (j + 1))
          (rentry U (i + 1) (j + 1)) wx wy| ≤
        17 / 2 * ulp (max (max |rentry U i j| |rentry U (i + 1) j|)
          (max |rentry U i (j + 1)| |rentry U (i + 1) (j + 1)|)) := by
  intro wx wy c
  obtain ⟨hi1, hi2, hi3⟩ := hi
  obtain ⟨hj1, hj2, hj3⟩ := hj
  have hxu : x ≤ ax.getD (i + 1) 0 := by rcases hi3 with h | ⟨_, h⟩ <;> [exact h.le; exact h.le]
  have hyu : y ≤ ay.getD (j + 1) 0 := by rcases hj3 with h | ⟨_, h⟩ <;> [exact h.le; exact h.le]
  obtain ⟨wx0, wx1⟩ := weight64_mem x _ _ hi2 hxu
  obtain ⟨wy0, wy1⟩ := weight64_mem y _ _ hj2 hyu
  refine ⟨?_, bilinear_fma_le _ _ _ _ _ _ h00 h10 h01 h11 wx0 wx1 wy0 wy1⟩
  refine (bilinear_in_cell_real (α := Bin64) (U.map (List.map Bin64.fin)) ax ay hax hay i j x y
    ⟨hi1, hi2, hi3⟩ ⟨hj1, hj2, hj3⟩).trans ?_
  have r : ∀ k, k < ax.length → ∀ l, l < ay.length →
      entry (U.map (List.map Bin64.fin)) k l = Bin64.fin (rentry U k l) := by
    intro k hk l hl
    exact entry_map (α := Bin64) U (by rw [hU.1]; exact hk) (by rw [row_length hU hk]; exact hl)
  simp only [bilinearCell, getD_map (α := Bin64) hi1, getD_map (α := Bin64) (show i < ax.length by omega),
    getD_map (α := Bin64) hj1, getD_map (α := Bin64) (show j < ay.length by omega),
    r i (by omega) j (by omega), r (i + 1) hi1 j (by omega), r i (by omega) (j + 1) hj1,
    r (i + 1) hi1 (j + 1) hj1]
  rfl

/-! ## The `faq` count in binary64 -/

/-- Adding two naturals in binary64 is exact while the sum is at most `2^53`. -/
theorem fadd_nat (m k : ℕ) (h : m + k ≤ 2 ^ 53) : fadd (m : ℝ) (k : ℝ) = ((m + k : ℕ) : ℝ) := by
  have e : (m : ℝ) + k = (((m + k : ℕ) : ℤ) : ℝ) := by push_cast; ring
  have hr : Repr ((((m + k : ℕ) : ℤ)) : ℝ) :=
    repr_intCast (by rw [abs_of_nonneg (by positivity)]; exact_mod_cast h)
  unfold fadd
  rw [e, rn_of_repr hr]
  push_cast; ring

theorem faqSum_le (n : ℕ) (f : ℕ → ℕ) (hf : ∀ k, f k ≤ 1) : faqSum n f ≤ n := by
  induction n with
  | zero => simp [faqSum]
  | succ n ih => rw [faqSum_succ]; have := hf (n + 1); omega

/-- The template's `faq` count, evaluated in binary64 (each term `ifelse(c, 1,
0)` or `ifelse(c, 0, 1)` as `1.0` or `0.0`, folded in index order from the
seed `0.0`, every addition rounded), is exactly the natural-number count
`faqSum`, for up to `2^53` terms. -/
theorem faqSum_binary64 (n : ℕ) (f : ℕ → ℕ) (hf : ∀ k, f k ≤ 1) (hn : n ≤ 2 ^ 53) :
    (List.range n).foldl (fun acc k => fadd acc ((f (k + 1) : ℕ) : ℝ)) (0 : ℝ) =
      (faqSum n f : ℝ) := by
  induction n with
  | zero => simp [faqSum]
  | succ n ih =>
    rw [List.range_succ, List.foldl_append, ih (by omega), faqSum_succ]
    simp only [List.foldl_cons, List.foldl_nil]
    have := faqSum_le n f hf
    have := hf (n + 1)
    exact fadd_nat _ _ (by omega)

/-- The clamp `min(max(c, 1), n - 1)` around the count, evaluated in binary64
(`n - 1` rounded), is the natural-number clamp `cellIdx` uses, for `n ≤ 2^53`. -/
theorem clamp_binary64 (c n : ℕ) (hn1 : 1 ≤ n) (hn : n ≤ 2 ^ 53) :
    min (max (c : ℝ) 1) (fsub (n : ℝ) 1) = ((min (max c 1) (n - 1) : ℕ) : ℝ) := by
  have e : (n : ℝ) - 1 = (((n - 1 : ℕ) : ℤ) : ℝ) := by push_cast [Nat.cast_sub hn1]; ring
  have hr : Repr ((((n - 1 : ℕ) : ℤ)) : ℝ) :=
    repr_intCast (by rw [abs_of_nonneg (by positivity)]; exact_mod_cast (by omega : n - 1 ≤ 2 ^ 53))
  unfold fsub
  rw [e, rn_of_repr hr]
  push_cast [Nat.cast_min, Nat.cast_max]
  rfl

end Binary64

end Esm.Closed.Template
