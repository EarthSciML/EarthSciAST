import Esm.Units.Grammar

/-!
# Executable read-outs of a resolved unit

Rendering for the `esm-lean units` adapter: the exponent map of a scale in
normal form, the exact scale as the `p/q*pi^k` string the unit-registry golden
uses, and a floating-point conversion factor (for the golden's 1e-12 check only;
no verdict reads it, §4.8.1).
-/

namespace Esm.Units

def Base.key : Base → ℕ
  | .pi => 0
  | .prime p => p.1

/-- The distinct bases of a scale, in first-occurrence order. -/
def Scale.bases (s : Scale) : List Base := (s.map Prod.fst).dedup

/-- The nonzero exponents of a scale, primes ascending, π last. -/
def Scale.normal (s : Scale) : List (Base × ℚ) :=
  let bs := (Scale.bases s).filter (fun b => Scale.exp s b ≠ 0)
  let sorted := bs.mergeSort (fun a b => decide (a.key ≤ b.key))
  let primes := sorted.filter (fun b => b != .pi)
  let pis := sorted.filter (fun b => b == .pi)
  (primes ++ pis).map fun b => (b, Scale.exp s b)

def ratStr (q : ℚ) : String :=
  if q.den = 1 then toString q.num else s!"{q.num}/{q.den}"

/-- The exact scale as a string: `p/q` (lowest terms, `/q` omitted when 1), then
`*pi` or `*pi^k`. A prime with a non-integer exponent is written `*p^(a/b)`. -/
def Scale.exactString (s : Scale) : String := Id.run do
  let n := Scale.normal s
  let mut num : ℤ := 1
  let mut den : ℕ := 1
  let mut extra := ""
  for (b, e) in n do
    match b with
    | .pi => extra := extra ++ (if e = 1 then "*pi" else s!"*pi^{ratStr e}")
    | .prime p =>
      if e.den = 1 then
        if e.num ≥ 0 then num := num * (p.1 : ℤ) ^ e.num.toNat
        else den := den * p.1 ^ (-e.num).toNat
      else extra := extra ++ s!"*{p.1}^({ratStr e})"
  let r : ℚ := (num : ℚ) / (den : ℚ)
  return ratStr r ++ extra

def ratToFloat (q : ℚ) : Float := Float.ofInt q.num / Float.ofNat q.den

/-- A floating-point value of the scale (product of `p ^ e`, `π ^ k`). -/
def Scale.toFloat (s : Scale) : Float :=
  (Scale.normal s).foldl (fun acc (b, e) =>
    let base : Float := match b with
      | .pi => 3.141592653589793
      | .prime p => Float.ofNat p.1
    if e.den = 1 then
      if e.num ≥ 0 then acc * base ^ (Float.ofNat e.num.toNat)
      else acc / base ^ (Float.ofNat (-e.num).toNat)
    else acc * Float.pow base (ratToFloat e)) 1

/-- The dimension's nonzero exponents, by axis name. -/
def Dim.entries (d : Dim) : List (String × ℚ) :=
  (Axis.all.filter fun a => d a ≠ 0).map fun a => (a.name, d a)

end Esm.Units
