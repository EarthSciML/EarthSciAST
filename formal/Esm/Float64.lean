import Mathlib.Data.Int.Log
import Mathlib.Algebra.Order.Archimedean.Real.Basic
import Mathlib.Data.Rat.Floor
import Mathlib.Tactic

/-!
# A small model of IEEE-754 binary64 arithmetic

Lean's `Float` is an opaque C `double`, so nothing about it can be proven. Claims
about rounding in the spec model (an ulp bound, a floor being exact) are proven
against this file instead: binary64 values as a subset of an ordered field, with
a concrete round-to-nearest, ties-to-even function `rn`.

Everything is stated over any ordered field with a floor function (`K`), so the
same definitions are used at two types:

* `K = ℝ`, where the theorems are meant to be applied;
* `K = ℚ`, where the definitions are *computable*, so `rn (p / q : ℚ)` can be
  run. `formal/scripts/f64-diff.py` uses this to check `rn` against Python's
  correctly rounded `float(Fraction(p, q))`.

## What is modelled

* `Repr x`: `x = m · 2^e` with `|m| < 2^53` and `e ≥ -1074`. These are the
  finite binary64 values (normal and subnormal), *without* the upper bound.
* `IsF64 x`: `Repr x` and `|x| ≤ maxFinite`, the finite doubles exactly
  (`maxFinite = (2^53 - 1) · 2^971`). Signed zero is not distinguished: `-0 = 0`.
* `fexp x`: the exponent of the last mantissa bit at the magnitude of `x`,
  `max (⌊log₂ |x|⌋ - 52) (-1074)` (and `-1074` at `0`). `ulp x = 2 ^ fexp x`.
* `rne r`: round a field element to the nearest integer, ties to even.
* `rn x = rne (x / ulp x) · ulp x`: round to nearest, ties to even, at binary64
  precision with gradual underflow. It never overflows: above `maxFinite` it
  keeps rounding at 53 bits. Results that need a finite double therefore carry
  the hypothesis `|x| ≤ maxFinite` (see `isF64_rn`).
* `fadd`, `fsub`, `fmul`, `fdiv`, `ffma`: the operations, each one rounding of
  the exact result.

## What is not modelled

Infinities, NaNs and their payloads, signed zero, exception flags, rounding
modes other than round-to-nearest-even, and the overflow to infinity itself.
There is no connection to Lean's `Float` other than the differential tests.

## Main results

`repr_iff` (representable iff the scaled mantissa is an integer); `fexp_le`,
`fexp_of_normal`, `abs_lt_fexp` (exponent facts); `repr_rn`, `isF64_rn` (rounding yields a double); `rn_of_repr` (doubles are
fixed points); `rn_mono`; `rn_neg`; `abs_rn_sub_le` (`|rn x - x| ≤ ulp x / 2`);
`abs_rn_sub_le_rel` (`≤ 2^-53 |x|` in the normal range); `ulp_le` (bounding the
ulp from a bound on `|x|`); `rn_sub_sterbenz`; `rn_mul_zpow`, `rn_div_zpow`,
`rn_mul_zpow_of_nonneg` (scaling by powers of two); `repr_intCast` (integers up
to `2^53`); `floor_rn_eq` (`⌊rn q⌋ = ⌊q⌋` when `q` is far enough below the next
integer).
-/

namespace Esm.F64

set_option linter.unusedSectionVars false

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

/-! ## Definitions -/

/-- Round to the nearest integer, ties to even. -/
def rne (r : K) : ℤ :=
  if r - ⌊r⌋ < 1 / 2 then ⌊r⌋
  else if 1 / 2 < r - ⌊r⌋ then ⌊r⌋ + 1
  else if ⌊r⌋ % 2 = 0 then ⌊r⌋ else ⌊r⌋ + 1

/-- The binary64 exponent of the last mantissa bit at the magnitude of `x`:
`⌊log₂ |x|⌋ - 52`, floored at the subnormal exponent `-1074`. -/
def fexp (x : K) : ℤ :=
  if x = 0 then -1074 else max (Int.log 2 |x| - 52) (-1074)

/-- The spacing of binary64 values at the magnitude of `x` (for `x` itself a
double, the gap to the next double away from zero, except at powers of two
where the gap below is half of it). -/
def ulp (x : K) : K := 2 ^ fexp x

/-- Round to nearest, ties to even, at binary64 precision with gradual
underflow. No overflow: see the module doc. -/
def rn (x : K) : K := (rne (x / 2 ^ fexp x) : K) * 2 ^ fexp x

/-- `x` is a binary64 value if the exponent range had no upper limit:
`m · 2^e` with `|m| < 2^53` and `e ≥ -1074`. -/
def Repr (x : K) : Prop :=
  ∃ m e : ℤ, |m| < 2 ^ 53 ∧ -1074 ≤ e ∧ x = m * 2 ^ e

/-- The largest finite double, `(2^53 - 1) · 2^971 = 0x1.fffffffffffffp+1023`. -/
def maxFinite : K := (2 ^ 53 - 1) * 2 ^ (971 : ℤ)

/-- `x` is a finite binary64 value. -/
def IsF64 (x : K) : Prop := Repr x ∧ |x| ≤ maxFinite

/-- Binary64 addition, `x ⊕ y`. -/
def fadd (x y : K) : K := rn (x + y)
/-- Binary64 subtraction, `x ⊖ y`. -/
def fsub (x y : K) : K := rn (x - y)
/-- Binary64 multiplication, `x ⊗ y`. -/
def fmul (x y : K) : K := rn (x * y)
/-- Binary64 division, `x ⊘ y` (for `y ≠ 0`; at `y = 0` it is `rn 0 = 0`). -/
def fdiv (x y : K) : K := rn (x / y)
/-- Fused multiply-add, one rounding of `x * y + z`. -/
def ffma (x y z : K) : K := rn (x * y + z)

/-! ## Powers of two -/

private lemma two_zpow_pos (e : ℤ) : (0 : K) < 2 ^ e := zpow_pos two_pos e

private lemma two_zpow_mono {a b : ℤ} (h : a ≤ b) : (2 : K) ^ a ≤ 2 ^ b :=
  zpow_le_zpow_right₀ (by norm_num) h

/-- `|m · 2^e| < 2^(e+53)` exactly when the mantissa fits in 53 bits. -/
lemma abs_int_mul_lt_iff (m e : ℤ) : |(m : K) * 2 ^ e| < 2 ^ (e + 53) ↔ |m| < 2 ^ 53 := by
  rw [abs_mul, abs_of_pos (two_zpow_pos (K := K) e), zpow_add₀ two_ne_zero, mul_comm ((2 : K) ^ e),
    mul_lt_mul_iff_of_pos_right (two_zpow_pos e), ← Int.cast_abs]
  constructor
  · intro h; exact_mod_cast h
  · intro h; exact_mod_cast h

/-- Rewrite `a · 2^f` with a smaller exponent `e ≤ f`. -/
lemma int_mul_zpow_rescale (a : ℤ) {e f : ℤ} (h : e ≤ f) :
    (a : K) * 2 ^ f = ((a * 2 ^ (f - e).toNat : ℤ) : K) * 2 ^ e := by
  push_cast
  rw [mul_assoc, ← zpow_natCast, ← zpow_add₀ two_ne_zero, Int.toNat_of_nonneg (sub_nonneg.2 h),
    sub_add_cancel]

/-! ## `rne` -/

lemma rne_eq_or (r : K) : rne r = ⌊r⌋ ∨ rne r = ⌊r⌋ + 1 := by
  unfold rne; split_ifs <;> simp

lemma abs_rne_sub_le (r : K) : |(rne r : K) - r| ≤ 1 / 2 := by
  have h0 := Int.floor_le r
  have h1 := Int.lt_floor_add_one r
  unfold rne
  split_ifs <;> push_cast <;> rw [abs_le] <;> constructor <;> linarith

@[simp] lemma rne_intCast (n : ℤ) : rne (n : K) = n := by
  simp [rne]

lemma rne_mono {r s : K} (h : r ≤ s) : rne r ≤ rne s := by
  have hf : ⌊r⌋ ≤ ⌊s⌋ := Int.floor_mono h
  rcases hf.lt_or_eq with hlt | heq
  · rcases rne_eq_or r with h1 | h1 <;> rcases rne_eq_or s with h2 | h2 <;> omega
  · unfold rne
    rw [heq]
    split_ifs <;> first | omega | (exfalso; linarith)

lemma le_rne {r : K} {n : ℤ} (h : (n : K) ≤ r) : n ≤ rne r := by
  simpa using rne_mono h

lemma rne_le {r : K} {n : ℤ} (h : r ≤ n) : rne r ≤ n := by
  simpa using rne_mono h

lemma abs_rne_le {r : K} {n : ℤ} (h : |r| ≤ n) : |rne r| ≤ n := by
  rw [abs_le] at h ⊢
  exact ⟨le_rne (by push_cast; exact h.1), rne_le h.2⟩

lemma rne_neg (r : K) : rne (-r) = -rne r := by
  by_cases hr : (⌊r⌋ : K) = r
  · rw [← hr, ← Int.cast_neg, rne_intCast, rne_intCast]
  · have hlt : (⌊r⌋ : K) < r := lt_of_le_of_ne (Int.floor_le r) hr
    have h1 := Int.lt_floor_add_one r
    have hneg : ⌊-r⌋ = -⌊r⌋ - 1 := by
      rw [Int.floor_eq_iff]; push_cast; constructor <;> linarith
    unfold rne
    rw [hneg]
    push_cast
    split_ifs <;> first | omega | (exfalso; linarith)

/-! ## The exponent `fexp` -/

lemma fexp_ge (x : K) : -1074 ≤ fexp x := by
  unfold fexp; split_ifs <;> simp

@[simp] lemma fexp_zero : fexp (0 : K) = -1074 := by simp [fexp]

@[simp] lemma fexp_neg (x : K) : fexp (-x) = fexp x := by simp [fexp]

@[simp] lemma fexp_abs (x : K) : fexp |x| = fexp x := by simp [fexp]

private lemma log_sub_le_fexp {x : K} (hx : x ≠ 0) : Int.log 2 |x| - 52 ≤ fexp x := by
  simp [fexp, hx]

/-- Every `x` lies below `2^(fexp x + 53)`: its scaled mantissa has at most 53 bits. -/
lemma abs_lt_fexp (x : K) : |x| < 2 ^ (fexp x + 53) := by
  by_cases hx : x = 0
  · simp only [hx, abs_zero]; exact two_zpow_pos _
  · have h := Int.lt_zpow_succ_log_self (b := 2) (by norm_num) |x|
    push_cast at h
    exact h.trans_le (two_zpow_mono (by linarith [log_sub_le_fexp hx]))

/-- Above the subnormal exponent, `x` is normal: `2^(fexp x + 52) ≤ |x|`. -/
lemma two_zpow_le_of_fexp {x : K} (h : -1074 < fexp x) : 2 ^ (fexp x + 52) ≤ |x| := by
  have hx : x ≠ 0 := by rintro rfl; simp at h
  have hl : -1074 < Int.log 2 |x| - 52 := by simpa [fexp, hx, lt_max_iff] using h
  have he : fexp x = Int.log 2 |x| - 52 := by simp [fexp, hx, max_eq_left hl.le]
  rw [he, sub_add_cancel]
  simpa using Int.zpow_log_le_self (b := 2) (by norm_num) (abs_pos.mpr hx)

/-- `fexp` is monotone in `|x|`. -/
lemma fexp_mono {x y : K} (h : |x| ≤ |y|) : fexp x ≤ fexp y := by
  by_cases hx : x = 0
  · simp only [hx, fexp_zero]; exact fexp_ge y
  · have hy : y ≠ 0 := by
      rintro rfl; simp only [abs_zero] at h; exact hx (abs_nonpos_iff.1 h)
    have := Int.log_mono_right (b := 2) (abs_pos.mpr hx) h
    simp only [fexp, hx, hy, ite_false]
    exact max_le_max (by omega) le_rfl

/-- The exponent is at most `e` when `|x| < 2^(e+53)` and `e` is in range. -/
lemma fexp_le {x : K} {e : ℤ} (hx : |x| < 2 ^ (e + 53)) (he : -1074 ≤ e) : fexp x ≤ e := by
  by_cases h0 : x = 0
  · simp [h0, he]
  · have : Int.log 2 |x| < e + 53 :=
      (Int.lt_zpow_iff_log_lt (b := 2) (by norm_num) (abs_pos.mpr h0)).1 (by simpa using hx)
    simp only [fexp, h0, ite_false]
    exact max_le (by omega) he

/-- In the normal range the exponent is `⌊log₂ |x|⌋ - 52`. -/
lemma fexp_of_normal {x : K} (hx : 2 ^ (-1022 : ℤ) ≤ |x|) : fexp x = Int.log 2 |x| - 52 := by
  have hx0 : x ≠ 0 := by
    rintro rfl; simp only [abs_zero] at hx; exact absurd hx (not_le.2 (two_zpow_pos _))
  have hlog : -1022 ≤ Int.log 2 |x| :=
    (Int.zpow_le_iff_le_log (b := 2) (by norm_num) (abs_pos.2 hx0)).1 (by simpa using hx)
  simp [fexp, hx0, max_eq_left (show -1074 ≤ Int.log 2 |x| - 52 by omega)]

/-- Bounding the ulp of `x` from a power-of-two bound on `|x|`. -/
lemma ulp_le {x : K} {k : ℤ} (hx : |x| < 2 ^ k) (hk : -1074 ≤ k - 53) : ulp x ≤ 2 ^ (k - 53) :=
  two_zpow_mono (fexp_le (by rwa [sub_add_cancel]) hk)

lemma ulp_pos (x : K) : 0 < ulp x := two_zpow_pos _

/-! ## Representable values -/

/-- `x` is representable exactly when its scaled mantissa `x / 2^fexp x` is an integer. -/
lemma repr_iff {x : K} : Repr x ↔ ∃ n : ℤ, x = n * 2 ^ fexp x := by
  constructor
  · rintro ⟨m, e, hm, he, rfl⟩
    have hf : fexp ((m : K) * 2 ^ e) ≤ e := fexp_le ((abs_int_mul_lt_iff m e).2 hm) he
    exact ⟨_, int_mul_zpow_rescale m hf⟩
  · rintro ⟨n, hn⟩
    refine ⟨n, fexp x, ?_, fexp_ge x, hn⟩
    have h : |(n : K) * 2 ^ fexp x| < 2 ^ (fexp x + 53) := by
      rw [← hn]; exact abs_lt_fexp x
    exact (abs_int_mul_lt_iff n _).1 h

lemma repr_zero : Repr (0 : K) := ⟨0, 0, by norm_num, by norm_num, by simp⟩

lemma repr_neg {x : K} (h : Repr x) : Repr (-x) := by
  obtain ⟨m, e, hm, he, rfl⟩ := h
  exact ⟨-m, e, by rwa [abs_neg], he, by push_cast; ring⟩

lemma repr_maxFinite : Repr (maxFinite : K) :=
  ⟨2 ^ 53 - 1, 971, by norm_num, by norm_num, by rw [maxFinite]; push_cast; ring⟩

lemma isF64_maxFinite : IsF64 (maxFinite : K) :=
  ⟨repr_maxFinite, by rw [abs_of_pos (by unfold maxFinite; positivity)]⟩

/-- Every integer of magnitude at most `2^53` is representable. -/
theorem repr_intCast {n : ℤ} (h : |n| ≤ 2 ^ 53) : Repr (n : K) := by
  rcases h.lt_or_eq with h | h
  · exact ⟨n, 0, h, by norm_num, by simp⟩
  · rcases (abs_eq (by norm_num)).1 h with rfl | rfl
    · exact ⟨2 ^ 52, 1, by norm_num, by norm_num, by norm_num⟩
    · exact ⟨-2 ^ 52, 1, by norm_num, by norm_num, by norm_num⟩

/-- Every integer of magnitude at most `2^53` is a finite double. -/
theorem isF64_intCast {n : ℤ} (h : |n| ≤ 2 ^ 53) : IsF64 (n : K) := by
  refine ⟨repr_intCast h, ?_⟩
  have : (|n| : K) ≤ 2 ^ 53 := by exact_mod_cast h
  refine this.trans ?_
  have h2 : (2 : K) ≤ 2 ^ (971 : ℤ) := by
    simpa using two_zpow_mono (K := K) (show (1 : ℤ) ≤ 971 by norm_num)
  unfold maxFinite
  generalize (2 : K) ^ (971 : ℤ) = t at h2 ⊢
  norm_num
  linarith

/-! ## Rounding -/

@[simp] lemma rn_zero : rn (0 : K) = 0 := by
  have := rne_intCast (K := K) 0
  simp only [Int.cast_zero] at this
  simp [rn, this]

lemma rn_eq (x : K) : rn x = (rne (x / 2 ^ fexp x) : K) * 2 ^ fexp x := rfl

/-- The scaled mantissa has magnitude below `2^53`. -/
lemma abs_div_lt (x : K) : |x / 2 ^ fexp x| < 2 ^ 53 := by
  rw [abs_div, abs_of_pos (two_zpow_pos (K := K) _), div_lt_iff₀ (two_zpow_pos _)]
  have h := abs_lt_fexp x
  rwa [zpow_add₀ two_ne_zero, mul_comm, zpow_ofNat] at h

/-- Doubles are fixed points of rounding. -/
theorem rn_of_repr {x : K} (h : Repr x) : rn x = x := by
  obtain ⟨n, hn⟩ := repr_iff.1 h
  have : x / 2 ^ fexp x = n := by rw [div_eq_iff (two_zpow_pos _).ne']; exact hn
  rw [rn_eq, this, rne_intCast, ← hn]

/-- Rounding always yields a representable value. -/
theorem repr_rn (x : K) : Repr (rn x) := by
  have hn : |rne (x / 2 ^ fexp x)| ≤ 2 ^ 53 :=
    abs_rne_le (by rw [Int.cast_pow, Int.cast_ofNat]; exact (abs_div_lt x).le)
  have key : ∀ m : ℤ, rne (x / 2 ^ fexp x) = 2 * m → |m| < 2 ^ 53 → Repr (rn x) :=
    fun m hm hm' => ⟨m, fexp x + 1, hm', by linarith [fexp_ge x], by
      rw [rn_eq, hm, zpow_add_one₀ two_ne_zero]; push_cast; ring⟩
  rcases hn.lt_or_eq with hlt | heq
  · exact ⟨_, fexp x, hlt, fexp_ge x, rfl⟩
  · rcases (abs_eq (by norm_num)).1 heq with h | h
    · exact key (2 ^ 52) (by rw [h]; norm_num) (by norm_num)
    · exact key (-2 ^ 52) (by rw [h]; norm_num) (by norm_num)

/-- The rounding error is at most half an ulp. -/
theorem abs_rn_sub_le (x : K) : |rn x - x| ≤ ulp x / 2 := by
  have hp := two_zpow_pos (K := K) (fexp x)
  have h := abs_rne_sub_le (x / 2 ^ fexp x)
  have : rn x - x = ((rne (x / 2 ^ fexp x) : K) - x / 2 ^ fexp x) * 2 ^ fexp x := by
    rw [rn_eq, sub_mul, div_mul_cancel₀ _ hp.ne']
  rw [this, abs_mul, abs_of_pos hp, ulp]
  calc _ ≤ 1 / 2 * (2 : K) ^ fexp x := mul_le_mul_of_nonneg_right h hp.le
    _ = _ := by ring

/-- In the normal range the relative rounding error is at most `2^-53`. -/
theorem abs_rn_sub_le_rel {x : K} (hx : 2 ^ (-1022 : ℤ) ≤ |x|) :
    |rn x - x| ≤ 2 ^ (-53 : ℤ) * |x| := by
  have hx0 : x ≠ 0 := by
    rintro rfl; simp only [abs_zero] at hx; exact absurd hx (not_le.2 (two_zpow_pos _))
  have h2 : (2 : K) ^ Int.log 2 |x| ≤ |x| := by
    simpa using Int.zpow_log_le_self (b := 2) (by norm_num) (abs_pos.2 hx0)
  calc |rn x - x| ≤ ulp x / 2 := abs_rn_sub_le x
    _ = 2 ^ (-53 : ℤ) * 2 ^ Int.log 2 |x| := by
      rw [ulp, fexp_of_normal hx, show Int.log 2 |x| - 52 = -53 + Int.log 2 |x| + 1 by ring,
        zpow_add₀ two_ne_zero, zpow_add₀ two_ne_zero, zpow_one]
      ring
    _ ≤ _ := mul_le_mul_of_nonneg_left h2 (two_zpow_pos _).le

@[simp] theorem rn_neg (x : K) : rn (-x) = -rn x := by
  simp only [rn, fexp_neg, neg_div, rne_neg]; push_cast; ring

lemma rn_nonneg {x : K} (hx : 0 ≤ x) : 0 ≤ rn x := by
  have : (0 : ℤ) ≤ rne (x / 2 ^ fexp x) := le_rne (by push_cast; exact div_nonneg hx (two_zpow_pos _).le)
  rw [rn_eq]; exact mul_nonneg (by exact_mod_cast this) (two_zpow_pos _).le

private lemma rn_le_two_zpow (x : K) : rn x ≤ 2 ^ (fexp x + 53) := by
  have h1 : x / 2 ^ fexp x ≤ ((2 ^ 53 : ℤ) : K) := by
    rw [Int.cast_pow, Int.cast_ofNat]; exact (le_abs_self _).trans (abs_div_lt x).le
  have h2 := rne_le h1
  rw [rn_eq, zpow_add₀ two_ne_zero, mul_comm ((2 : K) ^ fexp x), zpow_ofNat]
  refine mul_le_mul_of_nonneg_right ?_ (two_zpow_pos _).le
  exact_mod_cast h2

private lemma two_zpow_le_rn {x : K} (hx : 0 ≤ x) (he : -1074 < fexp x) :
    2 ^ (fexp x + 52) ≤ rn x := by
  have hn := two_zpow_le_of_fexp he
  rw [abs_of_nonneg hx, zpow_add₀ two_ne_zero, mul_comm, zpow_ofNat] at hn
  have h1 : ((2 ^ 52 : ℤ) : K) ≤ x / 2 ^ fexp x := by
    rw [Int.cast_pow, Int.cast_ofNat, le_div_iff₀ (two_zpow_pos _)]; exact hn
  have h2 := le_rne h1
  rw [rn_eq, zpow_add₀ two_ne_zero, mul_comm ((2 : K) ^ fexp x), zpow_ofNat]
  refine mul_le_mul_of_nonneg_right ?_ (two_zpow_pos _).le
  exact_mod_cast h2

private lemma rn_mono_nonneg {x y : K} (hx : 0 ≤ x) (hxy : x ≤ y) : rn x ≤ rn y := by
  have hy : 0 ≤ y := hx.trans hxy
  have hf : fexp x ≤ fexp y := fexp_mono (by rwa [abs_of_nonneg hx, abs_of_nonneg hy])
  rcases hf.lt_or_eq with hlt | heq
  · calc rn x ≤ 2 ^ (fexp x + 53) := rn_le_two_zpow x
      _ ≤ 2 ^ (fexp y + 52) := two_zpow_mono (by omega)
      _ ≤ rn y := two_zpow_le_rn hy (by linarith [fexp_ge x])
  · rw [rn_eq, rn_eq, heq]
    refine mul_le_mul_of_nonneg_right ?_ (two_zpow_pos _).le
    exact_mod_cast rne_mono (div_le_div_of_nonneg_right hxy (two_zpow_pos _).le)

/-- Rounding is monotone. -/
theorem rn_mono {x y : K} (h : x ≤ y) : rn x ≤ rn y := by
  rcases le_total 0 x with hx | hx
  · exact rn_mono_nonneg hx h
  rcases le_total 0 y with hy | hy
  · have := rn_nonneg (neg_nonneg.2 hx)
    rw [rn_neg] at this
    linarith [rn_nonneg hy]
  · have := rn_mono_nonneg (neg_nonneg.2 hy) (neg_le_neg h)
    rw [rn_neg, rn_neg] at this
    linarith

/-- Rounding a value within the finite range yields a finite double. -/
theorem isF64_rn {x : K} (h : |x| ≤ maxFinite) : IsF64 (rn x) := by
  refine ⟨repr_rn x, ?_⟩
  have hm := rn_of_repr (repr_maxFinite (K := K))
  rw [abs_le] at h ⊢
  constructor
  · rw [← neg_neg (rn x), neg_le_neg_iff, ← hm, ← rn_neg]; exact rn_mono (by linarith [h.1])
  · rw [← hm]; exact rn_mono h.2

/-! ## Exact operations -/

/-- Sterbenz: if `y / 2 ≤ x ≤ 2y` then `x - y` is representable. -/
theorem repr_sub_of_sterbenz {x y : K} (hx : Repr x) (hy : Repr y) (h1 : y / 2 ≤ x)
    (h2 : x ≤ 2 * y) : Repr (x - y) := by
  obtain ⟨a, ha⟩ := repr_iff.1 hx
  obtain ⟨b, hb⟩ := repr_iff.1 hy
  have hy0 : 0 ≤ y := by linarith
  have hx0 : 0 ≤ x := by linarith
  have hdx : |x - y| ≤ x := by rw [abs_le]; constructor <;> linarith
  have hdy : |x - y| ≤ y := by rw [abs_le]; constructor <;> linarith
  set e := min (fexp x) (fexp y) with he
  rw [int_mul_zpow_rescale a (min_le_left (fexp x) (fexp y)), ← he] at ha
  rw [int_mul_zpow_rescale b (min_le_right (fexp x) (fexp y)), ← he] at hb
  set A := a * 2 ^ (fexp x - e).toNat
  set B := b * 2 ^ (fexp y - e).toNat
  have hd : x - y = ((A - B : ℤ) : K) * 2 ^ e := by rw [Int.cast_sub, sub_mul, ← ha, ← hb]
  refine ⟨A - B, e, ?_, le_min (fexp_ge x) (fexp_ge y), hd⟩
  rw [← abs_int_mul_lt_iff (K := K), ← hd]
  rcases min_choice (fexp x) (fexp y) with h | h <;> rw [he, h]
  · exact hdx.trans_lt ((le_abs_self x).trans_lt (abs_lt_fexp x))
  · exact hdy.trans_lt ((le_abs_self y).trans_lt (abs_lt_fexp y))

/-- Sterbenz: if `y / 2 ≤ x ≤ 2y` then the subtraction `x ⊖ y` is exact. -/
theorem rn_sub_sterbenz {x y : K} (hx : Repr x) (hy : Repr y) (h1 : y / 2 ≤ x)
    (h2 : x ≤ 2 * y) : rn (x - y) = x - y :=
  rn_of_repr (repr_sub_of_sterbenz hx hy h1 h2)

/-- Scaling a double by `2^k` is exact when the result is normal. -/
theorem repr_mul_zpow {x : K} (hx : Repr x) (k : ℤ) (h : 2 ^ (-1022 : ℤ) ≤ |x * 2 ^ k|) :
    Repr (x * 2 ^ k) := by
  obtain ⟨m, e, hm, he, rfl⟩ := hx
  have hxk : (m : K) * 2 ^ e * 2 ^ k = m * 2 ^ (e + k) := by
    rw [zpow_add₀ two_ne_zero]; ring
  rw [hxk] at h ⊢
  refine ⟨m, e + k, hm, ?_, rfl⟩
  have hlt := h.trans_lt ((abs_int_mul_lt_iff m (e + k)).2 hm)
  have := (zpow_lt_zpow_iff_right₀ (by norm_num : (1 : K) < 2)).1 hlt
  omega

/-- Scaling a double up by `2^k`, `k ≥ 0`, is exact (overflow aside). -/
theorem repr_mul_zpow_of_nonneg {x : K} (hx : Repr x) {k : ℤ} (hk : 0 ≤ k) :
    Repr (x * 2 ^ k) := by
  obtain ⟨m, e, hm, he, rfl⟩ := hx
  exact ⟨m, e + k, hm, by omega, by rw [zpow_add₀ two_ne_zero]; ring⟩

/-- `x ⊗ 2^k = x · 2^k` when the result is normal. -/
theorem rn_mul_zpow {x : K} (hx : Repr x) (k : ℤ) (h : 2 ^ (-1022 : ℤ) ≤ |x * 2 ^ k|) :
    rn (x * 2 ^ k) = x * 2 ^ k :=
  rn_of_repr (repr_mul_zpow hx k h)

/-- `x ⊗ 2^k = x · 2^k` for `k ≥ 0` (overflow aside). -/
theorem rn_mul_zpow_of_nonneg {x : K} (hx : Repr x) {k : ℤ} (hk : 0 ≤ k) :
    rn (x * 2 ^ k) = x * 2 ^ k :=
  rn_of_repr (repr_mul_zpow_of_nonneg hx hk)

/-- `x ⊘ 2^k = x / 2^k` when the result is normal. -/
theorem rn_div_zpow {x : K} (hx : Repr x) (k : ℤ) (h : 2 ^ (-1022 : ℤ) ≤ |x / 2 ^ k|) :
    rn (x / 2 ^ k) = x / 2 ^ k := by
  rw [div_eq_mul_inv, ← zpow_neg] at h ⊢
  exact rn_mul_zpow hx (-k) h

/-! ## Floors -/

/-- `⌊rn q⌋ = ⌊q⌋` when `⌊q⌋` is a double and `q` lies more than half an ulp
below the next integer. Use `ulp_le` to discharge the gap from a bound on `|q|`;
e.g. for `q = t / 86400` with `|q| < 2^k`, a gap of `2^(k-54)` suffices. -/
theorem floor_rn_eq {q : K} (hq : |⌊q⌋| ≤ 2 ^ 53) (hgap : ulp q / 2 < ⌊q⌋ + 1 - q) :
    ⌊rn q⌋ = ⌊q⌋ := by
  rw [Int.floor_eq_iff]
  constructor
  · rw [← rn_of_repr (repr_intCast (K := K) hq)]
    exact rn_mono (Int.floor_le q)
  · have := (le_abs_self _).trans (abs_rn_sub_le q)
    linarith

end Esm.F64
