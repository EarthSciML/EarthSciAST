import Esm.Float64

/-! Concrete checks of `Esm.F64.rn` on rationals, against values Python's
correctly rounded `float(Fraction(p, q))` gives. The definitions are generic
over the field, so at `ℚ` they compute and the kernel checks them by `decide`. -/

namespace Esm.F64.Examples

open Esm.F64

-- 0.1 = 0x1.999999999999ap-4
example : rn (1 / 10 : ℚ) = 3602879701896397 / 36028797018963968 := by decide +kernel

-- -0.1: rounding is odd
example : rn (-1 / 10 : ℚ) = -3602879701896397 / 2 ^ 55 := by decide +kernel

-- 1/3 = 0x1.5555555555555p-2
example : rn (1 / 3 : ℚ) = 6004799503160661 / 2 ^ 54 := by decide +kernel

-- Ties go to even at 2^53: 2^53 + 1 ↦ 2^53, 2^53 + 3 ↦ 2^53 + 4
example : rn (2 ^ 53 + 1 : ℚ) = 2 ^ 53 := by decide +kernel
example : rn (2 ^ 53 + 3 : ℚ) = 2 ^ 53 + 4 := by decide +kernel

-- Gradual underflow: half the smallest subnormal ties to 0 (even),
-- three quarters of it rounds up to it
example : rn (1 / 2 ^ 1075 : ℚ) = 0 := by decide +kernel
example : rn (3 / 2 ^ 1076 : ℚ) = 1 / 2 ^ 1074 := by decide +kernel

-- Subnormal precision: 2^-1059 / 3 = 10922.67 · 2^-1074
example : rn (1 / (3 * 2 ^ 1059) : ℚ) = 10923 / 2 ^ 1074 := by decide +kernel

-- A day count: 1699999999 / 86400
example : rn (1699999999 / 86400 : ℚ) = 2704238666261123 / 2 ^ 37 := by decide +kernel

-- The largest finite double is a fixed point
example : rn (maxFinite : ℚ) = maxFinite := by decide +kernel

end Esm.F64.Examples
