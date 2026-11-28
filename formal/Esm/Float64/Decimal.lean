import Init.Data.Float

/-! Executable decimal-to-binary64 conversion, shared by JSON normalization
and the expression interpreter. All rounding uses exact integer arithmetic. -/

namespace Esm.F64.Decimal

/-- `n / d` rounded to a natural number, ties to even (`d > 0`). -/
def roundHalfEven (n d : Nat) : Nat :=
  let q := n / d
  let r := n % d
  if 2 * r > d then q + 1 else if 2 * r < d then q else if q % 2 = 0 then q else q + 1

/-- The fraction `n / d` times `2^k`. -/
def scale2 (n d : Nat) (k : Int) : Nat × Nat :=
  if 0 ≤ k then (n * 2 ^ k.toNat, d) else (n, d * 2 ^ (-k).toNat)

/-- `⌊log_b (n / d)⌋` for `n, d > 0`: the first guess `g`, moved one step at a time
(`fuel` bounds the steps). `le e` decides `b^e ≤ n / d`. -/
def floorLog (le : Int → Bool) (g : Int) : Nat → Int
  | 0 => g
  | fuel + 1 =>
    if !le g then floorLog le (g - 1) fuel
    else if le (g + 1) then floorLog le (g + 1) fuel
    else g

/-- `2^e ≤ n / d`. -/
def pow2Le (n d : Nat) (e : Int) : Bool := let (a, b) := scale2 d 1 e; decide (a ≤ n * b)

/-- The positive fraction `n / d` rounded to binary64, ties to even: `(M, k)` with value
`M × 2^k`, `M < 2^53`, and `2^52 ≤ M` unless `k = -1074` (a subnormal). `none` when it
overflows. -/
def toBinary64 (n d : Nat) : Option (Nat × Int) :=
  let t := floorLog (pow2Le n d) ((Nat.log2 n : Int) - Nat.log2 d) 4
  let k := max (t - 52) (-1074)
  let (a, b) := scale2 n d (-k)
  let m := roundHalfEven a b
  let (m, k) := if m = 2 ^ 53 then (2 ^ 52, k + 1) else (m, k)
  if k > 971 then none else some (m, k)

/-- Interpret `m × 10^-e` as a binary64, rounded to nearest with ties to even. -/
def toFloat (m : Int) (e : Nat) : Float :=
  if m = 0 then 0.0 else
    let sign : Nat := if m < 0 then 2 ^ 63 else 0
    let magnitude := match toBinary64 m.natAbs (10 ^ e) with
      | none => 2047 * 2 ^ 52
      | some (sig, k) =>
        if sig < 2 ^ 52 then sig
        else (k + 1075).toNat * 2 ^ 52 + (sig - 2 ^ 52)
    Float.ofBits (sign + magnitude).toUInt64

end Esm.F64.Decimal
