import Esm.Float64.Decimal

/-! Shared binary64 rendering for the document and expression adapters. -/

namespace Adapter.Doc

open Esm.F64.Decimal

/-- Round a positive rational to binary64 for the JSON serializers. -/
abbrev toBinary64 := Esm.F64.Decimal.toBinary64

/-- The fraction `n / d` times `10^k`. -/
def scale10 (n d : Nat) (k : Int) : Nat × Nat :=
  if 0 ≤ k then (n * 10 ^ k.toNat, d) else (n, d * 10 ^ (-k).toNat)

/-- `10^e ≤ n / d`. -/
def pow10Le (n d : Nat) (e : Int) : Bool := let (a, b) := scale10 d 1 e; decide (a ≤ n * b)

/-- The digits of a positive natural number, most significant first. -/
def natDigits (c : Nat) : List Nat := (Nat.toDigits 10 c).map (fun ch => ch.toNat - 48)

/-- The shortest decimal `c × 10^s` that rounds back to the double `(m, k)` (`m > 0`),
as its digits and the decimal exponent of the first: for each digit count `p` from 1, the
two `p`-digit decimals around the value; of those that round back, the nearer, and on a
tie the one with the even last digit (CONFORMANCE §5.5.3.1 rule 2, which writes the other
one at a power of two when the even one does not round back). -/
def shortest (m : Nat) (k : Int) : List Nat × Int :=
  let (vn, vd) := scale2 m 1 k
  let e10 := floorLog (pow10Le vn vd) ((((natDigits vn).length : Int) - (natDigits vd).length)) 4
  let back (c : Nat) (s : Int) : Bool :=
    c > 0 && (let (a, b) := scale10 c 1 s; toBinary64 a b == some (m, k))
  let out (c : Nat) (s : Int) : List Nat × Int :=
    let ds := natDigits c
    ((ds.reverse.dropWhile (· == 0)).reverse, (ds.length : Int) - 1 + s)
  let rec go : Nat → List Nat × Int
    | 0 => out (roundHalfEven vn vd) 0
    | fuel + 1 =>
      let p := 18 - (fuel + 1)
      let s := e10 - p + 1
      let (a, b) := scale10 vn vd (-s)
      let lo := a / b
      let hi := if a % b = 0 then lo else lo + 1
      let dLo := a - lo * b
      let dHi := hi * b - a
      match back lo s, back hi s with
      | true, true =>
        if dLo < dHi then out lo s else if dHi < dLo then out hi s
        else if lo % 2 = 0 then out lo s else out hi s
      | true, false => out lo s
      | false, true => out hi s
      | false, false => go fuel
  go 17

end Adapter.Doc
