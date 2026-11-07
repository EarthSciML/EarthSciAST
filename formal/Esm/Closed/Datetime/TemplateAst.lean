import Esm.Closed.Interp.TemplateAst
import Esm.Lib.Calendar
import Esm.Closed.Datetime.Hinnant
import Esm.Closed.Datetime.Binary64

/-!
# The `lib/calendar.esm` templates, evaluated, equal the `datetime.*` model

`Esm/Lib/Calendar.lean` holds the nine `datetime.*` expression templates of
`lib/calendar.esm` as ASTs (generated, checked current in CI). Each is
`ifelse(abs(t) < 2^52, body, 0 / 0)`. This file proves, for every real `t`:

* `calendar_int_template_eq`: on `|t| < 2^52` the eight integer templates
  evaluate to the exact integer `IntFn.exact f t` of `Exact.lean` (year, month,
  day, hour, minute, second, day of year, leap-year flag), at every scalar type
  with the `CalLaws` below — the exact `Num`, the binary64 `Bin64` and
  `Bin64Z` — so in binary64 every intermediate value and the result are exact;
* `julian_day_template_eq`: on `|t| < 2^52` the `julian_day` template
  evaluated in binary64 is `fJulianDay t`, the binary64 value of §9.2's pinned
  formula (`Binary64.lean`; `fJulianDay_err` bounds it within one ulp of the
  Julian Date for every double `t` with `|t| ≤ 2^59`);
* `calendar_template_nan`: outside the domain (`t` NaN, or `|t| ≥ 2^52`) every
  template evaluates to `0 / 0`, which is NaN at `Num` and `Bin64Z`.
  (`Bin64` is the binary64 model the interp theorems use; its division rounds
  `x / 0` to `0`, so it does not model `0 / 0 = NaN`. `Bin64Z` is the same model
  with IEEE's NaN for a zero divisor. ±∞ inputs are outside every model type.)

The year is inside Int32 on the domain, so `IntFn.eval f t = .ok (IntFn.exact
f t)` there (`ExactFacts.overflow_year_rule`; `int_template_eq_eval`).

The route: the expansion is, by computation, built from the named shapes below
(`dA` for `floor(floor(t) / 86400)`, `eraA`, `doeA`, `yoeA`, …, mirroring the
names in the library); each shape evaluates to an integer, and the integers
are Howard Hinnant's steps (`Hinnant.lean`), which `hinnant_eq` ties to
`civilFromDays`. Exactness comes from two facts: integers of magnitude at most
`2^53` add, subtract and multiply exactly, and the binary64 quotient of two
integers below `2^53` has the exact floor (`floor_rn_div_int`).
-/

namespace Esm.Closed.CalendarAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Esm.Closed.Datetime
open Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## The binary64 floor of an integer quotient -/

theorem floor_intCast_div {a b : ℤ} (hb : 0 < b) : ⌊(a : ℝ) / b⌋ = a / b := by
  have hbR : (0 : ℝ) < b := by exact_mod_cast hb
  have hr0 := Int.emod_nonneg a hb.ne'
  have hr1 := Int.emod_lt_of_pos a hb
  have hdecR : (a : ℝ) = (a % b : ℤ) + b * (a / b : ℤ) := by
    exact_mod_cast (Int.emod_add_mul_ediv a b).symm
  rw [Int.floor_eq_iff, le_div_iff₀ hbR, div_lt_iff₀ hbR, hdecR]
  have : ((a % b : ℤ) : ℝ) < b := by exact_mod_cast hr1
  have : (0 : ℝ) ≤ (a % b : ℤ) := by exact_mod_cast hr0
  constructor <;> nlinarith

open Esm.F64 in
/-- The binary64 quotient of two integers below `2^53` (positive divisor) has
the floor of the exact quotient: rounding never reaches the next integer. -/
theorem floor_rn_div_int {a b : ℤ} (hb : 0 < b) (hb' : b ≤ 2 ^ 53) (ha : |a| < 2 ^ 53) :
    ⌊rn ((a : ℝ) / b)⌋ = a / b := by
  have hbR : (0 : ℝ) < b := by exact_mod_cast hb
  have hr1 := Int.emod_lt_of_pos a hb
  have hdecR : (a : ℝ) = (a % b : ℤ) + b * (a / b : ℤ) := by
    exact_mod_cast (Int.emod_add_mul_ediv a b).symm
  have hq := floor_intCast_div (a := a) hb
  rw [← hq]
  apply floor_rn_eq
  · rw [hq]
    have := Int.abs_ediv_le_abs a b
    have : |a| ≤ 2 ^ 53 := ha.le
    linarith
  · rw [hq]
    have hgap : 1 / (b : ℝ) ≤ (a / b : ℤ) + 1 - a / b := by
      rw [div_le_iff₀ hbR, sub_mul, add_mul, div_mul_cancel₀ _ hbR.ne', hdecR]
      have : ((a % b : ℤ) : ℝ) + 1 ≤ b := by exact_mod_cast hr1
      nlinarith
    have hulp : ulp ((a : ℝ) / b) < 2 / b := by
      have hm : (2 : ℝ) ^ (-52 : ℤ) ≤ 2 / b := by
        rw [le_div_iff₀ hbR]
        have : (b : ℝ) ≤ 2 ^ (53 : ℤ) := by exact_mod_cast hb'
        have e : (2 : ℝ) ^ (-52 : ℤ) * 2 ^ (53 : ℤ) = 2 := by norm_num
        nlinarith [show (0 : ℝ) < 2 ^ (-52 : ℤ) by positivity]
      rcases eq_or_lt_of_le (fexp_ge ((a : ℝ) / b)) with h | h
      · have hu : ulp ((a : ℝ) / b) = 2 ^ (-1074 : ℤ) := by unfold ulp; rw [← h]
        have : (2 : ℝ) ^ (-1074 : ℤ) < 2 ^ (-52 : ℤ) :=
          zpow_lt_zpow_right₀ one_lt_two (by norm_num)
        rw [hu]; exact lt_of_lt_of_le this hm
      · have h1 := two_zpow_le_of_fexp h
        have h2 : |(a : ℝ) / b| < 2 ^ (53 : ℤ) / b := by
          rw [abs_div, abs_of_pos hbR]
          apply div_lt_div_of_pos_right _ hbR
          have : |(a : ℝ)| < 2 ^ 53 := by exact_mod_cast ha
          simpa using this
        have e : (2 : ℝ) ^ (fexp ((a : ℝ) / b) + 52) = ulp ((a : ℝ) / b) * 2 ^ (52 : ℤ) := by
          rw [zpow_add₀ two_ne_zero]; rfl
        have e2 : (2 : ℝ) ^ (53 : ℤ) / b = 2 / b * 2 ^ (52 : ℤ) := by
          rw [show (53 : ℤ) = 1 + 52 by norm_num, zpow_add₀ two_ne_zero]; ring
        have h3 := lt_of_le_of_lt h1 h2
        rw [e, e2] at h3
        exact lt_of_mul_lt_mul_right h3 (by positivity)
    have : ulp ((a : ℝ) / b) / 2 < 1 / b := by
      have : 2 / (b : ℝ) / 2 = 1 / b := by ring
      linarith
    linarith

/-! ## `Bin64Z`: binary64 with IEEE's NaN for a zero divisor -/

/-- The binary64 model `Bin64`, except that a zero divisor gives NaN (IEEE
gives NaN for `0 / 0` and ±∞, which the model does not have, for a nonzero
dividend). Every other operation is `Bin64`'s. -/
def Bin64Z : Type := Bin64

namespace Bin64Z

open Esm.F64

noncomputable def div (x y : Bin64Z) : Bin64Z :=
  match (x : Bin64), (y : Bin64) with
  | .fin a, .fin b => if b = 0 then (Bin64.nan : Bin64) else (Bin64.fin (fdiv a b) : Bin64)
  | _, _ => (Bin64.nan : Bin64)

noncomputable instance : Scalar Bin64Z where
  nan := (Bin64.nan : Bin64)
  add := Bin64.lift₂ fadd
  sub := Bin64.lift₂ fsub
  mul := Bin64.lift₂ fmul
  div := div
  le := Bin64.le
  lt := Bin64.lt
  isNaN := Bin64.isNaN
  nonFinite := Bin64.isNaN

noncomputable instance : RealNaN Bin64Z where
  fin r := (Bin64.fin r : Bin64)
  cases x := by
    cases (x : Bin64) with
    | fin r => exact Or.inr ⟨r, rfl⟩
    | nan => exact Or.inl rfl
  le_fin _ _ := rfl
  lt_fin _ _ := rfl
  nan_le x := by cases (x : Bin64) <;> rfl
  le_nan x := by cases (x : Bin64) <;> rfl
  nan_sub x := by cases (x : Bin64) <;> rfl
  nan_div x := by cases (x : Bin64) <;> rfl
  nan_mul x := by cases (x : Bin64) <;> rfl
  nan_add x := by cases (x : Bin64) <;> rfl
  add_nan x := by cases (x : Bin64) <;> rfl

noncomputable instance : Lits Bin64Z := inferInstanceAs (Lits Bin64)
noncomputable instance : Elem Bin64Z := inferInstanceAs (Elem Bin64)

instance : ExprLaws Bin64Z where
  ofDec_int m h := ExprLaws.ofDec_int (α := Bin64) m h
  add_int m k h1 h2 h3 := ExprLaws.add_int (α := Bin64) m k h1 h2 h3
  sub_int m k h1 h2 h3 := ExprLaws.sub_int (α := Bin64) m k h1 h2 h3
  toInt_int m := ExprLaws.toInt_int (α := Bin64) m
  isNaN_fin r := ExprLaws.isNaN_fin (α := Bin64) r

end Bin64Z

/-! ## What the calendar's integer arithmetic needs from a scalar type -/

/-- Integer products below `2^53` are exact, `floor`/`abs` act on the value,
an integer divided by `1` is itself, and the floor of the quotient of two
integers below `2^53` is their floor division. -/
class CalLaws (α : Type) [Scalar α] [RealNaN α] [Lits α] [Elem α] : Prop where
  mul_int : ∀ m k : ℤ, |m * k| ≤ 2 ^ 53 →
    mul (fin (m : ℝ) : α) (fin (k : ℝ)) = fin ((m * k : ℤ) : ℝ)
  floor_fin : ∀ r : ℝ, Elem.floor (fin r : α) = fin (⌊r⌋ : ℝ)
  abs_fin : ∀ r : ℝ, Elem.abs (fin r : α) = fin |r|
  abs_nan : Elem.abs (nan : α) = nan
  lt_nan : ∀ x : α, lt nan x = false
  div_one : ∀ m : ℤ, |m| ≤ 2 ^ 53 → div (fin (m : ℝ) : α) (fin 1) = fin (m : ℝ)
  floor_div_int : ∀ a b : ℤ, 0 < b → b ≤ 2 ^ 53 → |a| < 2 ^ 53 →
    Elem.floor (div (fin (a : ℝ) : α) (fin (b : ℝ))) = fin ((a / b : ℤ) : ℝ)

/-- `0 / 0` is NaN. -/
class ZeroDivNaN (α : Type) [Scalar α] [RealNaN α] : Prop where
  zero_div_zero : div (fin 0 : α) (fin 0) = nan

noncomputable instance : CalLaws Num where
  mul_int m k _ := by
    show Num.fin ((m : ℝ) * k) = Num.fin ((m * k : ℤ) : ℝ); push_cast; rfl
  floor_fin _ := rfl
  abs_fin _ := rfl
  abs_nan := rfl
  lt_nan _ := rfl
  div_one m _ := by
    show Num.div (Num.fin (m : ℝ)) (Num.fin 1) = Num.fin (m : ℝ); simp [Num.div]
  floor_div_int a b hb _ _ := by
    have hb0 : (b : ℝ) ≠ 0 := by exact_mod_cast hb.ne'
    show Elem.floor (Num.div (Num.fin (a : ℝ)) (Num.fin (b : ℝ))) = Num.fin ((a / b : ℤ) : ℝ)
    simp only [Num.div, hb0, ↓reduceIte]
    show Num.fin (⌊(a : ℝ) / b⌋ : ℝ) = _
    rw [floor_intCast_div hb]

noncomputable instance : ZeroDivNaN Num where
  zero_div_zero := by show Num.div (Num.fin 0) (Num.fin 0) = Num.nan; simp [Num.div]

noncomputable instance : CalLaws Bin64 where
  mul_int m k h := by
    show Bin64.fin (Esm.F64.rn ((m : ℝ) * k)) = Bin64.fin ((m * k : ℤ) : ℝ)
    rw [← Int.cast_mul, rn_int h]
  floor_fin _ := rfl
  abs_fin _ := rfl
  abs_nan := rfl
  lt_nan x := by cases x <;> rfl
  div_one m h := by
    show Bin64.fin (Esm.F64.rn ((m : ℝ) / 1)) = Bin64.fin (m : ℝ)
    rw [div_one, rn_int h]
  floor_div_int a b hb hb' ha := by
    show Bin64.fin (⌊Esm.F64.rn ((a : ℝ) / b)⌋ : ℝ) = _
    rw [floor_rn_div_int hb hb' ha]; rfl

noncomputable instance : CalLaws Bin64Z where
  mul_int m k h := CalLaws.mul_int (α := Bin64) m k h
  floor_fin r := CalLaws.floor_fin (α := Bin64) r
  abs_fin r := CalLaws.abs_fin (α := Bin64) r
  abs_nan := CalLaws.abs_nan (α := Bin64)
  lt_nan x := CalLaws.lt_nan (α := Bin64) x
  div_one m h := by
    show (if (1 : ℝ) = 0 then (Bin64.nan : Bin64) else Bin64.fin (Esm.F64.fdiv (m : ℝ) 1)) = _
    simp only [one_ne_zero, ↓reduceIte]; exact CalLaws.div_one (α := Bin64) m h
  floor_div_int a b hb hb' ha := by
    have hb0 : (b : ℝ) ≠ 0 := by exact_mod_cast hb.ne'
    show Elem.floor (if (b : ℝ) = 0 then (Bin64.nan : Bin64)
      else Bin64.fin (Esm.F64.fdiv (a : ℝ) b)) = _
    simp only [hb0, ↓reduceIte]; exact CalLaws.floor_div_int (α := Bin64) a b hb hb' ha

instance : ZeroDivNaN Bin64Z where
  zero_div_zero := by
    show (if (0 : ℝ) = 0 then (Bin64.nan : Bin64) else Bin64.fin (Esm.F64.fdiv 0 0)) = _
    simp only [↓reduceIte]; rfl

/-! ## The shapes the expansions are built from -/

def tA : Ast := .var "T"
def cst (m : ℤ) : Ast := .const (.leaf m 0)
def lit (m : ℤ) : Ast := .num m 0
def flA (a : Ast) : Ast := .node "floor" [a]
def dvA (a b : Ast) : Ast := .node "/" [a, b]
def adA (a b : Ast) : Ast := .node "+" [a, b]
def sbA (a b : Ast) : Ast := .node "-" [a, b]
def mlA (a b : Ast) : Ast := .node "*" [a, b]
def eqA (a b : Ast) : Ast := .node "==" [a, b]
def iteA (c a b : Ast) : Ast := .node "ifelse" [c, a, b]

/-- `floor(t)`. -/
def ftA : Ast := flA tA
/-- The day number `floor(floor(t) / 86400)`. -/
def dA : Ast := flA (dvA ftA (cst 86400))
/-- The second of the day in seconds, `floor(t) − 86400·D`. -/
def ssA : Ast := sbA ftA (mlA (cst 86400) dA)
/-- The second of the day as a count, `S_s / 1 s`. -/
def sA : Ast := dvA ssA (cst 1)
def zA : Ast := adA dA (lit 719468)
def eraA : Ast := flA (dvA zA (lit 146097))
def doeA : Ast := sbA zA (mlA (lit 146097) eraA)
def yoeA : Ast :=
  flA (dvA (sbA (adA (sbA doeA (flA (dvA doeA (lit 1460)))) (flA (dvA doeA (lit 36524))))
    (flA (dvA doeA (lit 146096)))) (lit 365))
def doyA : Ast := sbA doeA (sbA (adA (mlA (lit 365) yoeA) (flA (dvA yoeA (lit 4))))
  (flA (dvA yoeA (lit 100))))
def mpA : Ast := flA (dvA (adA (mlA (lit 5) doyA) (lit 2)) (lit 153))
/-- `DOY >= 306`: the day is in January or February (of the next civil year). -/
def jfA : Ast := .node ">=" [doyA, lit 306]
/-- The leap rule on `x` with the era-boundary year `y == sp`. -/
def leapA (x y : Ast) (sp : ℤ) : Ast :=
  iteA (.node "and" [eqA (sbA x (mlA (lit 4) (flA (dvA x (lit 4))))) (lit 0),
      .node "or" [.node "not" [eqA (sbA x (mlA (lit 100) (flA (dvA x (lit 100))))) (lit 0)],
        eqA y (lit sp)]])
    (lit 1) (lit 0)
/-- `ifelse(abs(t) < 2^52, body, 0 / 0)`. -/
def guardA (b : Ast) : Ast :=
  iteA (.node "<" [.node "abs" [tA], cst 4503599627370496]) b (dvA (lit 0) (lit 0))

def yearA : Ast := adA (adA yoeA (mlA (lit 400) eraA)) (iteA jfA (lit 1) (lit 0))
def monthA : Ast := adA mpA (iteA (.node "<" [mpA, lit 10]) (lit 3) (lit (-9)))
def dayA : Ast := adA (sbA doyA (flA (dvA (adA (mlA (lit 153) mpA) (lit 2)) (lit 5)))) (lit 1)
def hourA : Ast := flA (dvA sA (lit 3600))
def minuteA : Ast := sbA (flA (dvA sA (lit 60))) (mlA (lit 60) (flA (dvA sA (lit 3600))))
def secondA : Ast := sbA sA (mlA (lit 60) (flA (dvA sA (lit 60))))
def dayOfYearA : Ast := adA (adA doyA (lit 60)) (iteA jfA (lit (-365)) (leapA yoeA yoeA 0))
def isLeapA : Ast := iteA jfA (leapA (adA yoeA (lit 1)) yoeA 399) (leapA yoeA yoeA 0)
def julianA : Ast :=
  adA (adA dA (lit 2440588)) (dvA (adA (sbA ssA (cst 43200)) (sbA tA ftA)) (cst 86400))

/-! The expansions, by computation. -/

def bindT : Bindings := [("t", tA)]

theorem expand_year : expand Esm.Lib.Calendar.year bindT = .ok (guardA yearA) := rfl
theorem expand_month : expand Esm.Lib.Calendar.month bindT = .ok (guardA monthA) := rfl
theorem expand_day : expand Esm.Lib.Calendar.day bindT = .ok (guardA dayA) := rfl
theorem expand_hour : expand Esm.Lib.Calendar.hour bindT = .ok (guardA hourA) := rfl
theorem expand_minute : expand Esm.Lib.Calendar.minute bindT = .ok (guardA minuteA) := rfl
theorem expand_second : expand Esm.Lib.Calendar.second bindT = .ok (guardA secondA) := rfl
theorem expand_day_of_year :
    expand Esm.Lib.Calendar.day_of_year bindT = .ok (guardA dayOfYearA) := rfl
theorem expand_is_leap_year :
    expand Esm.Lib.Calendar.is_leap_year bindT = .ok (guardA isLeapA) := rfl
theorem expand_julian_day :
    expand Esm.Lib.Calendar.julian_day bindT = .ok (guardA julianA) := rfl

/-! ## Evaluating the shapes -/

section Eval

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [CalLaws α]

/-- `a` evaluates to the integer `k`. -/
abbrev IV (env : Env α) (a : Ast) (k : ℤ) : Prop := eval a env = .ok (.num (fin (k : ℝ)))

/-- `a` evaluates to the truth value `b` (`1` or `0`). -/
abbrev IB (env : Env α) (a : Ast) (b : Bool) : Prop := eval a env = .ok (.num (ofBool b : α))

theorem op_floor : Op.ofString "floor" = .strict .floor := rfl
theorem op_abs : Op.ofString "abs" = .strict .abs := rfl
theorem op_lt : Op.ofString "<" = .strict .lt := rfl
theorem op_eq : Op.ofString "==" = .strict .eq := rfl
theorem op_and : Op.ofString "and" = .strict .and := rfl
theorem op_or : Op.ofString "or" = .strict .or := rfl
theorem op_not : Op.ofString "not" = .strict .not := rfl

variable {env : Env α}

theorem ev_un {op : String} {o : StrictOp} (hop : Op.ofString op = .strict o) {a : Ast} {u : α}
    (ha : eval a env = .ok (.num u)) :
    eval (.node op [a]) env = (applyStrict o [.num u]).map Val.num := by
  simp only [eval, hop, evalList, ha, bind, Except.bind, pure, Except.pure]
  cases h : applyStrict o [.num u] <;> rfl

theorem ev_lit (m : ℤ) (h : |m| ≤ 2 ^ 53) : IV env (lit m) m := by
  simp [IV, lit, eval, ExprLaws.ofDec_int (α := α) m h]

theorem ev_cst (m : ℤ) (h : |m| ≤ 2 ^ 53) : IV env (cst m) m := by
  simp [IV, cst, eval, constVal, ExprLaws.ofDec_int (α := α) m h]

theorem ev_addI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) (h1 : |A| ≤ 2 ^ 53)
    (h2 : |B| ≤ 2 ^ 53) (h3 : |A + B| ≤ 2 ^ 53) : IV env (adA a b) (A + B) := by
  unfold IV adA; rw [ev_add ha hb, ExprLaws.add_int A B h1 h2 h3]

theorem ev_subI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) (h1 : |A| ≤ 2 ^ 53)
    (h2 : |B| ≤ 2 ^ 53) (h3 : |A - B| ≤ 2 ^ 53) : IV env (sbA a b) (A - B) := by
  unfold IV sbA; rw [ev_sub ha hb, ExprLaws.sub_int A B h1 h2 h3]

theorem ev_mulI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B)
    (h : |A * B| ≤ 2 ^ 53) : IV env (mlA a b) (A * B) := by
  unfold IV mlA; rw [ev_mul ha hb, CalLaws.mul_int A B h]

theorem ev_fdivI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) (hB : 0 < B)
    (hB' : B ≤ 2 ^ 53) (hA : |A| < 2 ^ 53) : IV env (flA (dvA a b)) (A / B) := by
  unfold IV flA dvA
  rw [ev_un op_floor (ev_div ha hb)]
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
    CalLaws.floor_div_int A B hB hB' hA]

theorem ev_div1 {a : Ast} {A : ℤ} (ha : IV env a A) (h : |A| ≤ 2 ^ 53) :
    IV env (dvA a (cst 1)) A := by
  have h1 : IV env (cst 1) 1 := ev_cst 1 (by norm_num)
  unfold IV at h1
  unfold IV dvA; rw [ev_div ha h1]; push_cast; rw [CalLaws.div_one A h]

theorem ofBool_decide_cast (p : Prop) [Decidable p] : (ofBool (decide p) : α) = ofBool (decide p) :=
  rfl

theorem ev_ltI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) :
    IB env (.node "<" [a, b]) (decide (A < B)) := by
  unfold IB; rw [ev_bin op_lt ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, lt_fin]

theorem ev_geI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) :
    IB env (.node ">=" [a, b]) (decide (B ≤ A)) := by
  unfold IB; rw [ev_bin op_ge ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, le_fin]

theorem ev_eqI {a b : Ast} {A B : ℤ} (ha : IV env a A) (hb : IV env b B) :
    IB env (eqA a b) (decide (A = B)) := by
  unfold IB eqA; rw [ev_bin op_eq ha hb]
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, le_fin]
  congr 3
  by_cases h : A = B
  · subst h; simp
  · rcases lt_or_gt_of_ne h with h' | h'
    · have : ¬ (B : ℝ) ≤ A := by exact_mod_cast not_le.mpr h'
      simp [h, this]
    · have : ¬ (A : ℝ) ≤ B := by exact_mod_cast not_le.mpr h'
      simp [h, this]

theorem ev_andB {a b : Ast} {p q : Bool} (ha : IB env a p) (hb : IB env b q) :
    IB env (.node "and" [a, b]) (p && q) := by
  unfold IB; rw [ev_bin op_and ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, truthy_ofBool]

theorem ev_orB {a b : Ast} {p q : Bool} (ha : IB env a p) (hb : IB env b q) :
    IB env (.node "or" [a, b]) (p || q) := by
  unfold IB; rw [ev_bin op_or ha hb]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, truthy_ofBool]

theorem ev_notB {a : Ast} {p : Bool} (ha : IB env a p) : IB env (.node "not" [a]) (!p) := by
  unfold IB; rw [ev_un op_not ha]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, truthy_ofBool]

theorem ev_iteI {c p q : Ast} {b : Bool} {P Q : ℤ} (hc : IB env c b) (hp : IV env p P)
    (hq : IV env q Q) : IV env (iteA c p q) (if b then P else Q) := by
  unfold IV iteA; rw [ev_ifelse hc]; cases b <;> simpa

end Eval

/-! ## The integer steps -/

/-- The day number of `F = floor(t)`. -/
def dZ (F : ℤ) : ℤ := F / 86400
def ssZ (F : ℤ) : ℤ := F - 86400 * dZ F
def zZ (F : ℤ) : ℤ := dZ F + 719468
def eraZ (F : ℤ) : ℤ := zZ F / 146097
def doeZ (F : ℤ) : ℤ := zZ F - 146097 * eraZ F
def yoeZ (F : ℤ) : ℤ := yoeOf (doeZ F)
def doyZ (F : ℤ) : ℤ := doeZ F - eraStart (yoeZ F)
def mpZ (F : ℤ) : ℤ := (5 * doyZ F + 2) / 153

/-- The floor of `t`, bounded on the domain. -/
def InDom (F : ℤ) : Prop := -2 ^ 52 ≤ F ∧ F < 2 ^ 52

theorem inDom_floor {t : ℝ} (ht : |t| < 2 ^ 52) : InDom ⌊t⌋ := by
  obtain ⟨h1, h2⟩ := abs_lt.mp ht
  constructor
  · rw [Int.le_floor]; push_cast; linarith
  · rw [Int.floor_lt]; push_cast; linarith

theorem doe_range (F : ℤ) : 0 ≤ doeZ F ∧ doeZ F < 146097 := by
  unfold doeZ eraZ; omega

theorem yoe_range (F : ℤ) : 0 ≤ yoeZ F ∧ yoeZ F ≤ 399 ∧ eraStart (yoeZ F) ≤ doeZ F ∧
    doeZ F < fullStart (yoeZ F + 1) :=
  yoeOf_spec _ (doe_range F).1 (doe_range F).2

theorem doy_range (F : ℤ) : 0 ≤ doyZ F ∧ doyZ F ≤ 365 := by
  have := yoe_range F
  unfold doyZ; unfold eraStart fullStart at *; omega

theorem mp_range (F : ℤ) : 0 ≤ mpZ F ∧ mpZ F ≤ 11 := by
  have := doy_range F
  unfold mpZ; omega

/-- `|x| ≤ c` from two-sided bounds, for `omega`. -/
theorem abs_le_of {x c : ℤ} (h1 : -c ≤ x) (h2 : x ≤ c) : |x| ≤ c := abs_le.mpr ⟨h1, h2⟩

theorem abs_lt_of {x c : ℤ} (h1 : -c < x) (h2 : x < c) : |x| < c := abs_lt.mpr ⟨h1, h2⟩

/-- The leap rule as the template writes it. -/
def leapZ (x y sp : ℤ) : ℤ :=
  if (decide (x - 4 * (x / 4) = 0) &&
    (!decide (x - 100 * (x / 100) = 0) || decide (y = sp))) then 1 else 0

theorem leapZ_bounds (x y sp : ℤ) : 0 ≤ leapZ x y sp ∧ leapZ x y sp ≤ 1 := by
  unfold leapZ; split <;> omega

theorem ev_leap {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [CalLaws α]
    {env : Env α} {x y : Ast} {X Y : ℤ} (sp : ℤ) (hsp : |sp| ≤ 2 ^ 53)
    (hx : IV env x X) (hy : IV env y Y)
    (hX : 0 ≤ X ∧ X ≤ 400) : IV env (leapA x y sp) (leapZ X Y sp) := by
  obtain ⟨x1, x2⟩ := hX
  have h4 := ev_subI hx (ev_mulI (ev_lit 4 (by norm_num)) (ev_fdivI hx (ev_lit 4 (by norm_num))
    (by norm_num) (by norm_num) (abs_lt_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega))) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
  have h100 := ev_subI hx (ev_mulI (ev_lit 100 (by norm_num)) (ev_fdivI hx
    (ev_lit 100 (by norm_num)) (by norm_num) (by norm_num) (abs_lt_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega))) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
  exact ev_iteI (ev_andB (ev_eqI h4 (ev_lit 0 (by norm_num)))
    (ev_orB (ev_notB (ev_eqI h100 (ev_lit 0 (by norm_num)))) (ev_eqI hy (ev_lit sp hsp))))
    (ev_lit 1 (by norm_num)) (ev_lit 0 (by norm_num))

/-! ## The shapes evaluate to the integer steps -/

section Shapes

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [CalLaws α]

/-- The environment binding the template parameter's stand-in `T` to `t`. -/
abbrev envT (t : ℝ) : Env α := [("T", .num (fin t))]

variable {t : ℝ}

theorem ev_ft : IV (envT t : Env α) ftA ⌊t⌋ := by
  unfold IV ftA flA tA
  rw [ev_un op_floor (ev_lookup _ rfl)]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, CalLaws.floor_fin]

variable (hF : InDom ⌊t⌋)
include hF

theorem ev_d : IV (envT t : Env α) dA (dZ ⌊t⌋) := by
  obtain ⟨h1, h2⟩ := hF
  exact ev_fdivI ev_ft (ev_cst 86400 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))

theorem ev_ss : IV (envT t : Env α) ssA (ssZ ⌊t⌋) := by
  obtain ⟨h1, h2⟩ := hF
  have hd := ev_d (α := α) ⟨h1, h2⟩
  unfold ssZ dZ at *
  exact ev_subI ev_ft (ev_mulI (ev_cst 86400 (by norm_num)) hd (abs_le_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ss_range : 0 ≤ ssZ ⌊t⌋ ∧ ssZ ⌊t⌋ < 86400 := by
  unfold ssZ dZ; omega

theorem ev_s : IV (envT t : Env α) sA (ssZ ⌊t⌋) := by
  have := ss_range hF
  exact ev_div1 (ev_ss hF) (abs_le_of (by omega) (by omega))

theorem ev_z : IV (envT t : Env α) zA (zZ ⌊t⌋) := by
  obtain ⟨h1, h2⟩ := hF
  have hd := ev_d (α := α) ⟨h1, h2⟩
  unfold zZ dZ at *
  exact ev_addI hd (ev_lit 719468 (by norm_num)) (abs_le_of (by omega) (by omega))
    (by norm_num) (abs_le_of (by omega) (by omega))

theorem ev_era : IV (envT t : Env α) eraA (eraZ ⌊t⌋) := by
  obtain ⟨h1, h2⟩ := hF
  have hz := ev_z (α := α) ⟨h1, h2⟩
  unfold eraZ zZ dZ at *
  exact ev_fdivI hz (ev_lit 146097 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))

theorem ev_doe : IV (envT t : Env α) doeA (doeZ ⌊t⌋) := by
  obtain ⟨h1, h2⟩ := hF
  have hz := ev_z (α := α) ⟨h1, h2⟩
  have he := ev_era (α := α) ⟨h1, h2⟩
  unfold doeZ eraZ zZ dZ at *
  exact ev_subI hz (ev_mulI (ev_lit 146097 (by norm_num)) he (abs_le_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_yoe : IV (envT t : Env α) yoeA (yoeZ ⌊t⌋) := by
  have hd := ev_doe (α := α) hF
  have hr := doe_range ⌊t⌋
  show IV _ yoeA (yoeOf (doeZ ⌊t⌋))
  generalize doeZ ⌊t⌋ = D at hd hr ⊢
  obtain ⟨r1, r2⟩ := hr
  have a1 := ev_fdivI hd (ev_lit 1460 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))
  have a2 := ev_fdivI hd (ev_lit 36524 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))
  have a3 := ev_fdivI hd (ev_lit 146096 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))
  have s1 := ev_subI hd a1 (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))
  have s2 := ev_addI s1 a2 (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))
  have s3 := ev_subI s2 a3 (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))
  exact ev_fdivI s3 (ev_lit 365 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))

theorem ev_doy : IV (envT t : Env α) doyA (doyZ ⌊t⌋) := by
  have hd := ev_doe (α := α) hF
  have hy := ev_yoe (α := α) hF
  have hr := doe_range ⌊t⌋
  have hyr := yoe_range ⌊t⌋
  show IV _ doyA (doeZ ⌊t⌋ - eraStart (yoeZ ⌊t⌋))
  unfold eraStart at hyr ⊢
  generalize doeZ ⌊t⌋ = D at hd hr hyr ⊢
  generalize yoeZ ⌊t⌋ = Y at hy hyr ⊢
  obtain ⟨r1, r2⟩ := hr
  obtain ⟨y1, y2, -, -⟩ := hyr
  exact ev_subI hd (ev_subI (ev_addI (ev_mulI (ev_lit 365 (by norm_num)) hy
      (abs_le_of (by omega) (by omega)))
    (ev_fdivI hy (ev_lit 4 (by norm_num)) (by norm_num) (by norm_num)
      (abs_lt_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)))
    (ev_fdivI hy (ev_lit 100 (by norm_num)) (by norm_num) (by norm_num)
      (abs_lt_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_mp : IV (envT t : Env α) mpA (mpZ ⌊t⌋) := by
  have hd := ev_doy (α := α) hF
  have hr := doy_range ⌊t⌋
  show IV _ mpA ((5 * doyZ ⌊t⌋ + 2) / 153)
  generalize doyZ ⌊t⌋ = D at hd hr ⊢
  obtain ⟨r1, r2⟩ := hr
  exact ev_fdivI (ev_addI (ev_mulI (ev_lit 5 (by norm_num)) hd (abs_le_of (by omega) (by omega)))
    (ev_lit 2 (by norm_num)) (abs_le_of (by omega) (by omega)) (by norm_num)
    (abs_le_of (by omega) (by omega))) (ev_lit 153 (by norm_num)) (by norm_num) (by norm_num)
    (abs_lt_of (by omega) (by omega))

theorem ev_jf : IB (envT t : Env α) jfA (decide (306 ≤ doyZ ⌊t⌋)) :=
  ev_geI (ev_doy hF) (ev_lit 306 (by norm_num))

/-! ### The nine fields, as integers -/

theorem era_bound : -2 ^ 20 ≤ eraZ ⌊t⌋ ∧ eraZ ⌊t⌋ ≤ 2 ^ 20 := by
  obtain ⟨h1, h2⟩ := hF
  unfold eraZ zZ dZ; omega

theorem ev_yearF : IV (envT t : Env α) yearA
    (yoeZ ⌊t⌋ + 400 * eraZ ⌊t⌋ + (if decide (306 ≤ doyZ ⌊t⌋) then 1 else 0)) := by
  have he := era_bound hF
  have hy := yoe_range ⌊t⌋
  have hyv := ev_yoe (α := α) hF
  have hev := ev_era (α := α) hF
  generalize eraZ ⌊t⌋ = E at he hev ⊢
  generalize yoeZ ⌊t⌋ = Y at hy hyv ⊢
  obtain ⟨e1, e2⟩ := he
  obtain ⟨y1, y2, -, -⟩ := hy
  have hj := ev_iteI (ev_jf (α := α) hF) (ev_lit 1 (by norm_num)) (ev_lit 0 (by norm_num))
  have hJb : (0 : ℤ) ≤ (if decide (306 ≤ doyZ ⌊t⌋) then 1 else 0) ∧
      (if decide (306 ≤ doyZ ⌊t⌋) then (1 : ℤ) else 0) ≤ 1 := by split <;> omega
  generalize (if decide (306 ≤ doyZ ⌊t⌋) then (1 : ℤ) else 0) = J at hj hJb ⊢
  obtain ⟨j1, j2⟩ := hJb
  exact ev_addI (ev_addI hyv (ev_mulI (ev_lit 400 (by norm_num)) hev
      (abs_le_of (by omega) (by omega))) (abs_le_of (by omega) (by omega))
      (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega)))
    hj (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))


theorem ev_monthF : IV (envT t : Env α) monthA
    (mpZ ⌊t⌋ + (if decide (mpZ ⌊t⌋ < 10) then 3 else -9)) := by
  have hm := ev_mp (α := α) hF
  have hr := mp_range ⌊t⌋
  have hb := ev_iteI (ev_ltI hm (ev_lit 10 (by norm_num))) (ev_lit 3 (by norm_num))
    (ev_lit (-9) (by norm_num)) (env := (envT t : Env α))
  have hJb : (-9 : ℤ) ≤ (if decide (mpZ ⌊t⌋ < 10) then 3 else -9) ∧
      (if decide (mpZ ⌊t⌋ < 10) then (3 : ℤ) else -9) ≤ 3 := by split <;> omega
  generalize (if decide (mpZ ⌊t⌋ < 10) then (3 : ℤ) else -9) = J at hb hJb ⊢
  generalize mpZ ⌊t⌋ = M at hm hr ⊢
  obtain ⟨r1, r2⟩ := hr
  obtain ⟨j1, j2⟩ := hJb
  exact ev_addI hm hb (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_dayF : IV (envT t : Env α) dayA (doyZ ⌊t⌋ - (153 * mpZ ⌊t⌋ + 2) / 5 + 1) := by
  have hm := ev_mp (α := α) hF
  have hd := ev_doy (α := α) hF
  have hr := mp_range ⌊t⌋
  have hdr := doy_range ⌊t⌋
  generalize mpZ ⌊t⌋ = M at hm hr ⊢
  generalize doyZ ⌊t⌋ = D at hd hdr ⊢
  obtain ⟨r1, r2⟩ := hr
  obtain ⟨d1, d2⟩ := hdr
  have h5 := ev_fdivI (ev_addI (ev_mulI (ev_lit 153 (by norm_num)) hm
      (abs_le_of (by omega) (by omega))) (ev_lit 2 (by norm_num))
      (abs_le_of (by omega) (by omega)) (by norm_num) (abs_le_of (by omega) (by omega)))
    (ev_lit 5 (by norm_num)) (by norm_num) (by norm_num) (abs_lt_of (by omega) (by omega))
  exact ev_addI (ev_subI hd h5 (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
      (abs_le_of (by omega) (by omega))) (ev_lit 1 (by norm_num))
    (abs_le_of (by omega) (by omega)) (by norm_num) (abs_le_of (by omega) (by omega))

theorem ev_s_div (c : ℤ) (hc : 0 < c) (hc' : c ≤ 86400) :
    IV (envT t : Env α) (flA (dvA sA (lit c))) (ssZ ⌊t⌋ / c) := by
  have := ss_range hF
  exact ev_fdivI (ev_s hF) (ev_lit c (abs_le_of (by omega) (by omega))) hc (by omega)
    (abs_lt_of (by omega) (by omega))

theorem ev_hourF : IV (envT t : Env α) hourA (ssZ ⌊t⌋ / 3600) :=
  ev_s_div hF 3600 (by norm_num) (by norm_num)

theorem ev_minuteF : IV (envT t : Env α) minuteA (ssZ ⌊t⌋ / 60 - 60 * (ssZ ⌊t⌋ / 3600)) := by
  have h60 := ev_s_div (α := α) hF 60 (by norm_num) (by norm_num)
  have h3600 := ev_s_div (α := α) hF 3600 (by norm_num) (by norm_num)
  have hr := ss_range hF
  generalize ssZ ⌊t⌋ = S at h60 h3600 hr ⊢
  obtain ⟨r1, r2⟩ := hr
  exact ev_subI h60 (ev_mulI (ev_lit 60 (by norm_num)) h3600 (abs_le_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_secondF : IV (envT t : Env α) secondA (ssZ ⌊t⌋ - 60 * (ssZ ⌊t⌋ / 60)) := by
  have h60 := ev_s_div (α := α) hF 60 (by norm_num) (by norm_num)
  have hs := ev_s (α := α) hF
  have hr := ss_range hF
  generalize ssZ ⌊t⌋ = S at h60 hs hr ⊢
  obtain ⟨r1, r2⟩ := hr
  exact ev_subI hs (ev_mulI (ev_lit 60 (by norm_num)) h60 (abs_le_of (by omega) (by omega)))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_dayOfYearF : IV (envT t : Env α) dayOfYearA
    (doyZ ⌊t⌋ + 60 + (if decide (306 ≤ doyZ ⌊t⌋) then -365 else leapZ (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0)) := by
  have hy := ev_yoe (α := α) hF
  have hyr := yoe_range ⌊t⌋
  have hd := ev_doy (α := α) hF
  have hdr := doy_range ⌊t⌋
  have hl := ev_leap (α := α) 0 (by norm_num) hy hy ⟨hyr.1, by omega⟩
  have hb := ev_iteI (ev_jf (α := α) hF) (ev_lit (-365) (by norm_num)) hl
  have hlb := leapZ_bounds (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0
  have hJb : (-365 : ℤ) ≤ (if decide (306 ≤ doyZ ⌊t⌋) then -365 else leapZ (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0) ∧
      (if decide (306 ≤ doyZ ⌊t⌋) then -365 else leapZ (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0) ≤ 1 := by
    split <;> omega
  generalize (if decide (306 ≤ doyZ ⌊t⌋) then -365 else leapZ (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0) = J
    at hb hJb ⊢
  generalize doyZ ⌊t⌋ = D at hd hdr ⊢
  obtain ⟨d1, d2⟩ := hdr
  obtain ⟨j1, j2⟩ := hJb
  exact ev_addI (ev_addI hd (ev_lit 60 (by norm_num)) (abs_le_of (by omega) (by omega))
      (by norm_num) (abs_le_of (by omega) (by omega))) hb
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega))

theorem ev_isLeapF : IV (envT t : Env α) isLeapA
    (if decide (306 ≤ doyZ ⌊t⌋) then leapZ (yoeZ ⌊t⌋ + 1) (yoeZ ⌊t⌋) 399
      else leapZ (yoeZ ⌊t⌋) (yoeZ ⌊t⌋) 0) := by
  have hy := ev_yoe (α := α) hF
  have hyr := yoe_range ⌊t⌋
  have hy1 : IV (envT t : Env α) (adA yoeA (lit 1)) (yoeZ ⌊t⌋ + 1) :=
    ev_addI hy (ev_lit 1 (by norm_num)) (abs_le_of (by omega) (by omega)) (by norm_num)
      (abs_le_of (by omega) (by omega))
  exact ev_iteI (ev_jf hF) (ev_leap 399 (by norm_num) hy1 hy ⟨by omega, by omega⟩)
    (ev_leap 0 (by norm_num) hy hy ⟨hyr.1, by omega⟩)

end Shapes

/-! ## The integer steps are the model's calendar -/

theorem dayNumber_eq (t : ℝ) : dayNumber t = dZ ⌊t⌋ := by
  unfold dayNumber dZ
  have h := floor_intCast_div (a := ⌊t⌋) (b := 86400) (by norm_num)
  rw [Int.floor_eq_iff]
  have h1 := Int.floor_le t
  have h2 := Int.lt_floor_add_one t
  have e1 : (86400 : ℝ) * ((⌊t⌋ / 86400 : ℤ) : ℝ) ≤ (⌊t⌋ : ℝ) := by
    have : 86400 * (⌊t⌋ / 86400) ≤ ⌊t⌋ := by omega
    exact_mod_cast this
  have e2 : (⌊t⌋ : ℝ) + 1 ≤ 86400 * (((⌊t⌋ / 86400 : ℤ) : ℝ) + 1) := by
    have : ⌊t⌋ + 1 ≤ 86400 * (⌊t⌋ / 86400 + 1) := by omega
    exact_mod_cast this
  constructor
  · rw [le_div_iff₀ (by norm_num)]; linarith
  · rw [div_lt_iff₀ (by norm_num)]; linarith

theorem secondOfDay_eq_ss (t : ℝ) : secondOfDay t = ssZ ⌊t⌋ := by
  rw [secondOfDay_eq, dayNumber_eq]; rfl

theorem hinnant_dZ (F : ℤ) : hinnant (dZ F) =
    ⟨yoeZ F + 400 * eraZ F + (if 306 ≤ doyZ F then 1 else 0),
      mpZ F + (if mpZ F < 10 then 3 else -9), doyZ F - (153 * mpZ F + 2) / 5 + 1⟩ := rfl

theorem dateOf_eq (t : ℝ) : dateOf t = hinnant (dZ ⌊t⌋) := by
  unfold dateOf; rw [dayNumber_eq, hinnant_eq]

theorem yearOfDays_eq_hinnant (n : ℤ) : yearOfDays n = (hinnant n).year := by
  rw [hinnant_eq]; rfl

/-- The facts the identities below need about the steps. -/
theorem steps_facts (F : ℤ) :
    dZ F + 719468 = doeZ F + 146097 * eraZ F ∧ doeZ F = fullStart (yoeZ F) + doyZ F ∧
      0 ≤ yoeZ F ∧ yoeZ F ≤ 399 ∧ 0 ≤ doyZ F ∧ doyZ F < fullStart (yoeZ F + 1) - fullStart (yoeZ F) := by
  have := yoe_range F
  have he := eraStart_eq_full this.1 this.2.1
  have hd := doy_range F
  refine ⟨by unfold doeZ zZ; ring, by unfold doyZ; rw [he]; ring, this.1, this.2.1, hd.1, ?_⟩
  unfold doyZ; rw [he] at *; omega

/-- The template's leap rule on a year of the era is the Gregorian rule. -/
theorem leapZ_eq0 (x : ℤ) (h0 : 0 ≤ x) (h1 : x ≤ 399) :
    leapZ x x 0 = if isLeapYear x then 1 else 0 := by
  unfold leapZ
  rw [isLeapYear_eq_decide]
  by_cases a : x - 4 * (x / 4) = 0 <;> by_cases b : x - 100 * (x / 100) = 0 <;>
    by_cases c : x = 0 <;> simp [a, b, c] <;> omega

/-- The template's leap rule on the year after a year of the era. -/
theorem leapZ_eq1 (y : ℤ) (h0 : 0 ≤ y) (h1 : y ≤ 399) :
    leapZ (y + 1) y 399 = if isLeapYear (y + 1) then 1 else 0 := by
  unfold leapZ
  rw [isLeapYear_eq_decide]
  by_cases a : y + 1 - 4 * ((y + 1) / 4) = 0 <;> by_cases b : y + 1 - 100 * ((y + 1) / 100) = 0 <;>
    by_cases c : y = 399 <;> simp [a, b, c] <;> omega

theorem dayOfYear_eq (F : ℤ) : dayOfYearOfDays (dZ F) =
    doyZ F + 60 + (if 306 ≤ doyZ F then -365 else leapZ (yoeZ F) (yoeZ F) 0) := by
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := steps_facts F
  have a0 := daysBeforeYear_march (yoeZ F)
  have a1 := daysBeforeYear_succ_march (yoeZ F)
  have l0 := leapZ_eq0 (yoeZ F) h3 h4
  unfold dayOfYearOfDays doy0OfDays
  rw [yearOfDays_eq_hinnant, hinnant_dZ]
  simp only [epochOffset]
  rw [show yoeZ F + 400 * eraZ F + (if 306 ≤ doyZ F then 1 else 0) =
    (yoeZ F + if 306 ≤ doyZ F then 1 else 0) + 400 * eraZ F by ring, daysBeforeYear_add_400]
  rw [l0]
  generalize isLeapYear (yoeZ F) = L at a0 ⊢
  by_cases hj : 306 ≤ doyZ F <;> simp only [hj, ↓reduceIte, add_zero] <;> cases L <;>
    simp only [Bool.false_eq_true, ↓reduceIte] at a0 ⊢ <;> omega

theorem isLeap_eq (F : ℤ) :
    (if isLeapYear (hinnant (dZ F)).year then (1 : ℤ) else 0) =
      if 306 ≤ doyZ F then leapZ (yoeZ F + 1) (yoeZ F) 399 else leapZ (yoeZ F) (yoeZ F) 0 := by
  obtain ⟨-, -, h3, h4, -, -⟩ := steps_facts F
  rw [hinnant_dZ]
  simp only
  rw [show yoeZ F + 400 * eraZ F + (if 306 ≤ doyZ F then 1 else 0) =
    (yoeZ F + if 306 ≤ doyZ F then 1 else 0) + 400 * eraZ F by ring, isLeapYear_add_400]
  by_cases hj : 306 ≤ doyZ F <;> simp only [hj, ↓reduceIte, add_zero, leapZ_eq0 _ h3 h4,
    leapZ_eq1 _ h3 h4]

/-! ## The nine templates -/

/-- The template of each integer `datetime.*` function. -/
def intTemplate : IntFn → Template
  | .year => Esm.Lib.Calendar.year
  | .month => Esm.Lib.Calendar.month
  | .day => Esm.Lib.Calendar.day
  | .hour => Esm.Lib.Calendar.hour
  | .minute => Esm.Lib.Calendar.minute
  | .second => Esm.Lib.Calendar.second
  | .dayOfYear => Esm.Lib.Calendar.day_of_year
  | .isLeapYear => Esm.Lib.Calendar.is_leap_year

section Top

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [CalLaws α]

theorem ev_cond_in {t : ℝ} (ht : |t| < 2 ^ 52) :
    IB (envT t : Env α) (.node "<" [.node "abs" [tA], cst 4503599627370496]) true := by
  have ha : eval (.node "abs" [tA]) (envT t : Env α) = .ok (.num (fin |t|)) := by
    unfold tA
    rw [ev_un op_abs (ev_lookup _ rfl)]
    simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, CalLaws.abs_fin]
  have hc := ev_cst (env := (envT t : Env α)) 4503599627370496 (by norm_num)
  unfold IV at hc
  unfold IB; rw [ev_bin op_lt ha hc]
  have h2 : lt (fin |t| : α) (fin ((4503599627370496 : ℤ) : ℝ)) = true := by
    rw [lt_fin, decide_eq_true_eq]; push_cast; linarith
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, h2]

theorem ev_guard_in {t : ℝ} (ht : |t| < 2 ^ 52) (b : Ast) :
    eval (guardA b) (envT t : Env α) = eval b (envT t) := by
  unfold guardA iteA; rw [ev_ifelse (ev_cond_in ht)]; rfl

/-- **The integer `datetime.*` templates are exact.** On `|t| < 2^52`, each of
the eight integer templates of `lib/calendar.esm`, applied to `t` and
evaluated, is the exact integer value of its `datetime.*` function. At `Bin64`
this is a statement about binary64 evaluation: every operation in the
expansion is exact. -/
theorem calendar_int_template_eq (f : IntFn) (t : ℝ) (ht : |t| < 2 ^ 52) :
    evalApply (intTemplate f) bindT (envT t : Env α) = .ok (.num (fin ((f.exact t : ℤ) : ℝ))) := by
  have hF := inDom_floor ht
  have hss := ss_range hF
  cases f
  · unfold evalApply; rw [show intTemplate .year = Esm.Lib.Calendar.year from rfl, expand_year]
    simp only [ev_guard_in ht, ev_yearF hF, IntFn.exact_year, dateOf_eq, hinnant_dZ,
      decide_eq_true_eq]
  · unfold evalApply; rw [show intTemplate .month = Esm.Lib.Calendar.month from rfl, expand_month]
    simp only [ev_guard_in ht, ev_monthF hF, IntFn.exact_month, dateOf_eq, hinnant_dZ,
      decide_eq_true_eq]
  · unfold evalApply; rw [show intTemplate .day = Esm.Lib.Calendar.day from rfl, expand_day]
    simp only [ev_guard_in ht, ev_dayF hF, IntFn.exact_day, dateOf_eq, hinnant_dZ]
  · unfold evalApply; rw [show intTemplate .hour = Esm.Lib.Calendar.hour from rfl, expand_hour]
    simp only [ev_guard_in ht, ev_hourF hF, IntFn.exact_hour, secondOfDay_eq_ss]
  · unfold evalApply; rw [show intTemplate .minute = Esm.Lib.Calendar.minute from rfl, expand_minute]
    simp only [ev_guard_in ht, ev_minuteF hF, IntFn.exact_minute, secondOfDay_eq_ss]
    have : ssZ ⌊t⌋ / 60 - 60 * (ssZ ⌊t⌋ / 3600) = ssZ ⌊t⌋ % 3600 / 60 := by omega
    rw [this]
  · unfold evalApply; rw [show intTemplate .second = Esm.Lib.Calendar.second from rfl, expand_second]
    simp only [ev_guard_in ht, ev_secondF hF, IntFn.exact_second, secondOfDay_eq_ss]
    have : ssZ ⌊t⌋ - 60 * (ssZ ⌊t⌋ / 60) = ssZ ⌊t⌋ % 60 := by omega
    rw [this]
  · unfold evalApply; rw [show intTemplate .dayOfYear = Esm.Lib.Calendar.day_of_year from rfl, expand_day_of_year]
    simp only [ev_guard_in ht, ev_dayOfYearF hF, IntFn.exact_dayOfYear, dayNumber_eq, dayOfYear_eq]
    simp only [decide_eq_true_eq]
  · unfold evalApply; rw [show intTemplate .isLeapYear = Esm.Lib.Calendar.is_leap_year from rfl, expand_is_leap_year]
    simp only [ev_guard_in ht, ev_isLeapF hF, IntFn.exact_isLeapYear, dateOf_eq, isLeap_eq]
    simp only [decide_eq_true_eq]

/-- On the domain the year is a signed 32-bit integer, so §9.2's result is the
exact value: the templates agree with `IntFn.eval`, not only `IntFn.exact`. -/
theorem int_template_eq_eval (f : IntFn) (t : ℝ) (ht : |t| < 2 ^ 52) :
    f.eval t = .ok (f.exact t) := by
  have hF := inDom_floor ht
  have he := era_bound hF
  have hy := yoe_range ⌊t⌋
  refine (overflow_year_rule f t).2.1 ?_
  unfold YearInInt32 int32Min int32Max
  rw [IntFn.exact_year, dateOf_eq, hinnant_dZ]
  simp only
  split <;> omega

/-- **Outside the domain every template is `0 / 0`**: for a NaN `t`, or a
finite `t` with `|t| ≥ 2^52`, each of the nine templates evaluates its `0 / 0`
branch, which is NaN at `Num` and `Bin64Z` (`ZeroDivNaN`). -/
theorem calendar_template_nan [ZeroDivNaN α] (tm : Template)
    (htm : tm ∈ [Esm.Lib.Calendar.year, Esm.Lib.Calendar.month, Esm.Lib.Calendar.day,
      Esm.Lib.Calendar.hour, Esm.Lib.Calendar.minute, Esm.Lib.Calendar.second,
      Esm.Lib.Calendar.day_of_year, Esm.Lib.Calendar.julian_day, Esm.Lib.Calendar.is_leap_year])
    (x : α) (hx : x = nan ∨ ∃ r : ℝ, x = fin r ∧ 2 ^ 52 ≤ |r|) :
    evalApply tm bindT [("T", .num x)] = .ok (.num nan) := by
  have hcond : IB [("T", .num x)] (.node "<" [.node "abs" [tA], cst 4503599627370496]) false := by
    have hc := ev_cst (env := [("T", .num x)]) 4503599627370496 (by norm_num)
    unfold IV at hc
    unfold IB
    rcases hx with rfl | ⟨r, rfl, hr⟩
    · have ha : eval (.node "abs" [tA]) [("T", .num (nan : α))] = .ok (.num nan) := by
        unfold tA
        rw [ev_un op_abs (ev_lookup _ rfl)]
        simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
          CalLaws.abs_nan]
      rw [ev_bin op_lt ha hc]
      simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, CalLaws.lt_nan]
    · have ha : eval (.node "abs" [tA]) [("T", .num (fin r : α))] = .ok (.num (fin |r|)) := by
        unfold tA
        rw [ev_un op_abs (ev_lookup _ rfl)]
        simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
          CalLaws.abs_fin]
      rw [ev_bin op_lt ha hc]
      have h2 : lt (fin |r| : α) (fin ((4503599627370496 : ℤ) : ℝ)) = false := by
        rw [lt_fin, decide_eq_false_iff_not]; push_cast; linarith
      simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, h2]
  have hg : ∀ b : Ast, eval (guardA b) [("T", .num x)] = .ok (.num nan) := by
    intro b
    unfold guardA iteA
    rw [ev_ifelse hcond]
    simp only [Bool.false_eq_true, ↓reduceIte]
    have h0 := ev_lit (env := [("T", .num x)]) 0 (by norm_num)
    unfold IV at h0
    unfold dvA
    rw [ev_div h0 h0]
    push_cast
    rw [ZeroDivNaN.zero_div_zero]
  simp only [List.mem_cons, List.not_mem_nil, or_false] at htm
  rcases htm with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> unfold evalApply
  · rw [expand_year]; simp only [hg]
  · rw [expand_month]; simp only [hg]
  · rw [expand_day]; simp only [hg]
  · rw [expand_hour]; simp only [hg]
  · rw [expand_minute]; simp only [hg]
  · rw [expand_second]; simp only [hg]
  · rw [expand_day_of_year]; simp only [hg]
  · rw [expand_julian_day]; simp only [hg]
  · rw [expand_is_leap_year]; simp only [hg]

end Top

/-! ## julian_day in binary64 -/

/-- **`julian_day` is the pinned binary64 formula.** On `|t| < 2^52`, the
`julian_day` template evaluated in binary64 (`Bin64`, and `Bin64Z`, whose
operations are the same away from a zero divisor) is `fJulianDay t`, §9.2's
`(d + 2440588) + ((s − 43200) + (t − floor(t))) / 86400` rounded operation by
operation on the exact split — bit for bit. -/
theorem julian_day_template_eq (t : ℝ) (ht : |t| < 2 ^ 52) :
    evalApply Esm.Lib.Calendar.julian_day bindT (envT t : Env Bin64) =
      .ok (.num (Bin64.fin (fJulianDay t))) := by
  have hF := inDom_floor ht
  have hss := ss_range hF
  obtain ⟨h1, h2⟩ := hF
  have hd := ev_d (α := Bin64) ⟨h1, h2⟩
  have hdl : |dZ ⌊t⌋| ≤ 2 ^ 53 := by unfold dZ; exact abs_le_of (by omega) (by omega)
  have hd2 := ev_addI hd (ev_lit 2440588 (by norm_num)) hdl (by norm_num)
    (by unfold dZ; exact abs_le_of (by omega) (by omega))
  have hs2 := ev_subI (ev_ss (α := Bin64) ⟨h1, h2⟩) (ev_cst 43200 (by norm_num))
    (abs_le_of (by omega) (by omega)) (by norm_num) (abs_le_of (by omega) (by omega))
  have htv : eval tA (envT t : Env Bin64) = .ok (.num (Bin64.fin t)) := ev_lookup _ rfl
  have hfr := ev_sub htv (ev_ft (α := Bin64) (t := t))
  have hc := ev_cst (env := (envT t : Env Bin64)) 86400 (by norm_num)
  have hdl' : |dZ ⌊t⌋ + 2440588| ≤ 2 ^ 53 := by unfold dZ; exact abs_le_of (by omega) (by omega)
  have hsl' : |ssZ ⌊t⌋ - 43200| ≤ 2 ^ 53 := abs_le_of (by omega) (by omega)
  unfold IV at hd2 hs2 hc
  unfold evalApply
  rw [expand_julian_day]
  simp only [ev_guard_in ht]
  rw [show julianA = .node "+" [adA dA (lit 2440588),
    .node "/" [.node "+" [sbA ssA (cst 43200), .node "-" [tA, ftA]], cst 86400]] from rfl]
  rw [ev_add hd2 (ev_div (ev_add hs2 hfr) hc)]
  unfold fJulianDay
  rw [dayNumber_eq, secondOfDay_eq_ss, rn_int hdl', rn_int hsl']
  push_cast
  rfl

end Esm.Closed.CalendarAst
