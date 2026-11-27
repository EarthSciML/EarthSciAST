import Esm.Expr.Core
import Esm.Units.Laws

/-!
# Unit preservation for scalar expressions (esm-spec §4.8.3–4.8.4)

These rules consume the unit verdicts of their child expressions. A successful
verdict can name a resolved unit or report an undeterminable one. Invalid
declarations and mismatches remain errors. A scalar expression's evaluator
does not need its unit annotation, so the verdicts are passed separately from
the expression AST.
-/

namespace Esm.Units.ScalarCheck

inductive Error where
  | unitParseError
  | dimensionMismatch
  deriving DecidableEq, Repr

abbrev Verdict := Except Error (Option U)

/-- A nonzero power of the plane-angle axis, with all other axes absent. -/
def PureAngle (d : Dim) : Prop := d .rad ≠ 0 ∧ ∀ a, a ≠ Axis.rad → d a = 0

instance (d : Dim) : Decidable (PureAngle d) := by unfold PureAngle; infer_instance

/-- The exact unit comparison for extrema and `ifelse`. A pure angle can
agree with a pure number at the same scale. Comparing two angular operands
still requires the same dimension. -/
def Compatible (u v : U) : Prop :=
  Scale.exp u.scale = Scale.exp v.scale ∧
    (u.dim = v.dim ∨ (u.dim = 0 ∧ PureAngle v.dim) ∨ (v.dim = 0 ∧ PureAngle u.dim))

instance (u v : U) : Decidable (Compatible u v) := by unfold Compatible; infer_instance

private theorem compatible_self (u : U) : Compatible u u := ⟨rfl, .inl rfl⟩

/-- When a pure number and a pure angle meet, select the pure number's unit.
Otherwise retain the first determinable operand's unit. -/
def chooseUnit (known : List U) : Option U :=
  match known.find? (fun u => decide (u.dim = 0)) with
  | some u => some u
  | none => known.head?

private theorem choose_mem {known : List U} {u : U}
    (h : chooseUnit known = some u) : u ∈ known := by
  unfold chooseUnit at h
  split at h
  · rename_i v hv
    cases h
    exact List.mem_of_find?_eq_some hv
  · cases known with
    | nil => contradiction
    | cons v rest => cases h; simp

/-- Check every pair of determinable inputs. This also compares two angle
operands when a pure number appears between them. -/
def checkKnown (known : List U) : Verdict :=
  if known.all (fun u => known.all (fun v => decide (Compatible u v))) then .ok (chooseUnit known)
  else .error .dimensionMismatch

/-- The `min`/`max` rule and the value-operand part of the `ifelse` rule. -/
def checkExtrema (operands : List Verdict) : Verdict := do
  let units ← operands.mapM id
  checkKnown (units.filterMap id)

/-- Check the condition for errors but derive the result from both branches. -/
def checkIfelse (condition yes no : Verdict) : Verdict := do
  let _ ← condition
  checkExtrema [yes, no]

theorem checkKnown_compatible (known : List U) (result : U)
    (h : checkKnown known = .ok (some result)) :
    result ∈ known ∧ ∀ u ∈ known, ∀ v ∈ known, Compatible u v := by
  unfold checkKnown at h
  split at h
  · rename_i hs
    rw [Except.ok.injEq] at h
    refine ⟨choose_mem h, ?_⟩
    intro u hu v hv
    exact of_decide_eq_true (List.all_eq_true.mp (List.all_eq_true.mp hs u hu) v hv)
  · contradiction

theorem checkKnown_prefers_number (known : List U) (result pureUnit : U)
    (h : checkKnown known = .ok (some result)) (mem : pureUnit ∈ known)
    (pureDim : pureUnit.dim = 0) : result.dim = 0 := by
  unfold checkKnown at h
  split at h
  · rw [Except.ok.injEq] at h
    unfold chooseUnit at h
    split at h
    · rename_i found hf
      cases h
      exact of_decide_eq_true (List.find?_some (p := fun u : U => decide (u.dim = 0)) hf)
    · rename_i hf
      have ha := List.find?_eq_none.mp hf pureUnit mem
      simp [pureDim] at ha
  · contradiction

theorem checkKnown_single (u : U) : checkKnown [u] = .ok (some u) := by
  by_cases h : u.dim = 0 <;> simp [checkKnown, compatible_self, chooseUnit, h]

theorem checkExtrema_unknown (n : Nat) :
    checkExtrema (List.replicate n (.ok none)) = .ok none := by
  have h : (List.replicate n (.ok none : Verdict)).mapM id = .ok (List.replicate n none) := by
    induction n with
    | zero => rfl
    | succ n ih => simp [List.replicate_succ, List.mapM_cons, ih, pure, Except.pure, bind, Except.bind]
  simp [checkExtrema, h, bind, Except.bind, checkKnown, chooseUnit]

theorem checkIfelse_condition_error (e : Error) (yes no : Verdict) :
    checkIfelse (.error e) yes no = .error e := rfl

theorem checkIfelse_one_known (condition : Option U) (u : U) :
    checkIfelse (.ok condition) (.ok (some u)) (.ok none) = .ok (some u) ∧
      checkIfelse (.ok condition) (.ok none) (.ok (some u)) = .ok (some u) := by
  change checkKnown [u] = .ok (some u) ∧ checkKnown [u] = .ok (some u)
  exact ⟨checkKnown_single u, checkKnown_single u⟩

theorem checkIfelse_unknown (condition : Option U) :
    checkIfelse (.ok condition) (.ok none) (.ok none) = .ok none := rfl

/-! ## Sound rescaling on the exact scalar evaluator -/

open Esm.Closed Esm.Expr

/-- Multiply a finite value by a scale and preserve a NaN. -/
noncomputable def scaleValue (s : ℝ) (v : Num) : Num :=
  Scalar.mul (.fin s) v

private theorem lt_scale (s : ℝ) (hs : 0 < s) (x y : Num) :
    Scalar.lt (scaleValue s x) (scaleValue s y) = Scalar.lt x y := by
  change Num.lt (scaleValue s x) (scaleValue s y) = Num.lt x y
  cases x <;> cases y <;> simp [scaleValue, Scalar.mul, Num.lift₂, Num.lt, mul_lt_mul_iff_right₀ hs]

private theorem nan_scale (s : ℝ) (x : Num) :
    Scalar.isNaN (scaleValue s x) = Scalar.isNaN x := by cases x <;> rfl

private theorem fmin_scale (s : ℝ) (hs : 0 < s) (x y : Num) :
    fmin (scaleValue s x) (scaleValue s y) = scaleValue s (fmin x y) := by
  simp [fmin, nan_scale, lt_scale s hs]
  split_ifs <;> rfl

private theorem fmax_scale (s : ℝ) (hs : 0 < s) (x y : Num) :
    fmax (scaleValue s x) (scaleValue s y) = scaleValue s (fmax x y) := by
  simp [fmax, nan_scale, lt_scale s hs]
  split_ifs <;> rfl

private theorem fold_scale (op : Num → Num → Num) (s : ℝ)
    (step : ∀ x y, op (scaleValue s x) (scaleValue s y) = scaleValue s (op x y))
    (xs : List Num) (initial : Num) :
    (xs.map (scaleValue s)).foldl op (scaleValue s initial) =
      scaleValue s (xs.foldl op initial) := by
  induction xs generalizing initial with
  | nil => rfl
  | cons x xs ih => simpa only [List.map_cons, List.foldl_cons, step] using ih (op initial x)

private theorem asNum_map (xs : List Num) : (xs.map Val.num).mapM asNum = .ok xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [List.mapM_cons, asNum, pure, Except.pure, bind, Except.bind, ih]

private theorem apply_min (a b : Num) (rest : List Num) :
    applyStrict .min ((a :: b :: rest).map Val.num) = .ok ((b :: rest).foldl fmin a) := by
  have hm := asNum_map (b :: rest)
  simp only [List.map_cons] at hm
  simp only [List.map_cons, applyStrict, asNum, bind, Except.bind, hm, pure, Except.pure]

private theorem apply_max (a b : Num) (rest : List Num) :
    applyStrict .max ((a :: b :: rest).map Val.num) = .ok ((b :: rest).foldl fmax a) := by
  have hm := asNum_map (b :: rest)
  simp only [List.map_cons] at hm
  simp only [List.map_cons, applyStrict, asNum, bind, Except.bind, hm, pure, Except.pure]

private theorem extremum_scaled (maximum : Bool) (s : ℝ) (hs : 0 < s)
    (a b : Num) (rest : List Num) :
    applyStrict (if maximum then .max else .min)
        ((a :: b :: rest).map (fun x => .num (scaleValue s x))) =
      (applyStrict (if maximum then .max else .min) ((a :: b :: rest).map Val.num)).map
        (scaleValue s) := by
  have mapped : (a :: b :: rest).map (fun x => Val.num (scaleValue s x)) =
      ((a :: b :: rest).map (scaleValue s)).map Val.num := by simp [List.map_map, Function.comp_def]
  rw [mapped]
  cases maximum with
  | false =>
    change applyStrict .min ((scaleValue s a :: scaleValue s b :: rest.map (scaleValue s)).map
      Val.num) = (applyStrict .min ((a :: b :: rest).map Val.num)).map (scaleValue s)
    rw [apply_min, apply_min]
    exact congrArg Except.ok (fold_scale fmin s (fmin_scale s hs) (b :: rest) a)
  | true =>
    change applyStrict .max ((scaleValue s a :: scaleValue s b :: rest.map (scaleValue s)).map
      Val.num) = (applyStrict .max ((a :: b :: rest).map Val.num)).map (scaleValue s)
    rw [apply_max, apply_max]
    exact congrArg Except.ok (fold_scale fmax s (fmax_scale s hs) (b :: rest) a)

/-- With a determinable unit on every operand, the checked `min` or `max`
commutes with conversion from its authored units to their canonical scales.
Undeterminable operands need a separate semantic premise about their numbers. -/
theorem checked_extremum_scaling (maximum : Bool) (a b : U × Num)
    (rest : List (U × Num)) (result : U)
    (h : checkKnown ((a :: b :: rest).map Prod.fst) = .ok (some result)) :
    applyStrict (if maximum then .max else .min)
        ((a :: b :: rest).map (fun x => .num (scaleValue x.1.scale.real x.2))) =
      (applyStrict (if maximum then .max else .min)
        ((a :: b :: rest).map (fun x => .num x.2))).map (scaleValue result.scale.real) := by
  have ⟨hm, compatible⟩ := checkKnown_compatible _ _ h
  have units : ∀ x ∈ a :: b :: rest, x.1.scale.real = result.scale.real := by
    intro x hx
    exact Scale.real_congr _ _ (compatible _ (List.mem_map.mpr ⟨x, hx, rfl⟩) _ hm).1
  have he : (a :: b :: rest).map (fun x => Val.num (scaleValue x.1.scale.real x.2)) =
        ((a :: b :: rest).map Prod.snd).map (fun x => Val.num (scaleValue result.scale.real x)) := by
    rw [List.map_map]
    exact List.map_congr_left (fun x hx => by simp [units x hx])
  rw [he]
  simpa [List.map_map, Function.comp_def] using
    extremum_scaled maximum _ (Scale.real_pos _) a.2 b.2 (rest.map Prod.snd)

private theorem truthy_scaled (s : ℝ) (hs : 0 < s) (c : Num) :
    truthy (scaleValue s c) = truthy c := by
  have hz : scaleValue s (zero (α := Num)) = zero := by
    simp [scaleValue, zero, Lits.ofDec, Scalar.mul, Num.lift₂]
  unfold truthy
  conv_lhs => rw [← hz]
  simp only [lt_scale s hs]

/-- The `ifelse` truth test selects the same branch under a positive condition
rescaling. Given the evaluated branch values in determinable units, converting
the selected branch and converting the result give the same value. -/
theorem checked_ifelse_scaling (condition : Verdict) (c : Num) (cs : ℝ) (hc : 0 < cs)
    (yes no : U × Num) (result : U)
    (h : checkIfelse condition (.ok (some yes.1)) (.ok (some no.1)) = .ok (some result)) :
    (if truthy (scaleValue cs c) then scaleValue yes.1.scale.real yes.2
      else scaleValue no.1.scale.real no.2) =
    scaleValue result.scale.real (if truthy c then yes.2 else no.2) := by
  have branches : checkKnown [yes.1, no.1] = .ok (some result) := by
    cases condition with
    | error => contradiction
    | ok => exact h
  have ⟨hm, compatible⟩ := checkKnown_compatible _ _ branches
  have hy := Scale.real_congr _ _ (compatible yes.1 (by simp) result hm).1
  have hn := Scale.real_congr _ _ (compatible no.1 (by simp) result hm).1
  rw [truthy_scaled cs hc, hy, hn]
  split_ifs <;> rfl

/-! ## Compositional soundness for resolved scalar arithmetic

This fragment uses the same numeric expression AST and evaluator as the
conformance adapter. Its inputs carry their exact declared units. Inference
here requires every subexpression to have a determinable unit. The neutral
literal rule permits a broader set of expressions in a document, but does
not assign a conversion scale to a bare number (§4.8.4–4.8.6).
-/

inductive Unary where
  | neg | abs | sqrt | not | sign | exp | log | log10

def Unary.spelling : Unary → String
  | .neg => "-"
  | .abs => "abs"
  | .sqrt => "sqrt"
  | .not => "not"
  | .sign => "sign"
  | .exp => "exp"
  | .log => "log"
  | .log10 => "log10"

def Unary.op : Unary → StrictOp
  | .neg => .sub
  | .abs => .abs
  | .sqrt => .sqrt
  | .not => .not
  | .sign => .sign
  | .exp => .exp
  | .log => .log
  | .log10 => .log10

/-- Strict transcendentals admit a scale-one pure number, including the
pure-angle exception of §4.8.3. -/
def checkPure (u : U) : Verdict :=
  if Compatible u U.one then .ok (some .one) else .error .dimensionMismatch

def Unary.check : Unary → U → Verdict
  | .sqrt, u => .ok (some (u.rpow (1 / 2)))
  | .not, _ | .sign, _ => .ok (some .one)
  | .exp, u | .log, u | .log10, u => checkPure u
  | .neg, u | .abs, u => .ok (some u)

inductive Binary where
  | add | sub | mul | div | min | max | le | ge | lt | gt | eq | ne | and | or | atan2

def Binary.spelling : Binary → String
  | .add => "+"
  | .sub => "-"
  | .mul => "*"
  | .div => "/"
  | .min => "min"
  | .max => "max"
  | .le => "<="
  | .ge => ">="
  | .lt => "<"
  | .gt => ">"
  | .eq => "=="
  | .ne => "!="
  | .and => "and"
  | .or => "or"
  | .atan2 => "atan2"

def Binary.op : Binary → StrictOp
  | .add => .add
  | .sub => .sub
  | .mul => .mul
  | .div => .div
  | .min => .min
  | .max => .max
  | .le => .le
  | .ge => .ge
  | .lt => .lt
  | .gt => .gt
  | .eq => .eq
  | .ne => .ne
  | .and => .and
  | .or => .or
  | .atan2 => .atan2

/-- The two coordinates passed to `atan2` must have the same dimension and
exact scale (§4.8.3). -/
def checkAtan2 (y x : U) : Verdict :=
  if y.Agree x then .ok (some (.base .rad)) else .error .dimensionMismatch

def Binary.check (op : Binary) (left right : U) : Verdict :=
  match op with
  | .mul => .ok (some (left.mul right))
  | .div => .ok (some (left.div right))
  | .add | .sub | .min | .max => checkKnown [left, right]
  | .le | .ge | .lt | .gt | .eq | .ne => (checkKnown [left, right]).map (fun _ => some .one)
  | .and | .or => .ok (some .one)
  | .atan2 => checkAtan2 left right

/-- A folded rational exponent is written as the exact numerator divided by
its nonzero denominator, both integer literals. -/
def rationalExponent (q : ℚ) : Ast := .node "/" [.num q.num 0, .num q.den 0]

/-- A scalar expression over declared inputs and the operator forms handled by
the exact unit rescaling theorem. Conditions can carry a unit of their own. -/
inductive ScalarTerm where
  | var (name : String)
  | unary (op : Unary) (arg : ScalarTerm)
  | binary (op : Binary) (left right : ScalarTerm)
  | power (base : ScalarTerm) (exponent : ℚ)
  | ifelse (condition yes no : ScalarTerm)

def ScalarTerm.ast : ScalarTerm → Ast
  | .var name => .var name
  | .unary op arg => .node op.spelling [arg.ast]
  | .binary op left right => .node op.spelling [left.ast, right.ast]
  | .power base exponent => .node "^" [base.ast, rationalExponent exponent]
  | .ifelse condition yes no => .node "ifelse" [condition.ast, yes.ast, no.ast]

/-- The checker for the resolved fragment. An absent declaration yields an
undeterminable unit and keeps the tree outside the rescaling guarantee. -/
def ScalarTerm.check (units : List (String × U)) : ScalarTerm → Verdict
  | .var name => .ok (units.lookup name)
  | .unary op arg => do
    match ← arg.check units with
    | some u => op.check u
    | none => .ok none
  | .binary op left right => do
    let leftUnit ← left.check units
    let rightUnit ← right.check units
    match leftUnit, rightUnit with
    | some l, some r => op.check l r
    | _, _ => .ok none
  | .power base exponent => (base.check units).map (Option.map (fun u => u.rpow exponent))
  | .ifelse condition yes no => do
    let conditionUnit ← condition.check units
    let yesUnit ← yes.check units
    let noUnit ← no.check units
    match conditionUnit, yesUnit, noUnit with
    | some c, some y, some n => checkIfelse (.ok (some c)) (.ok (some y)) (.ok (some n))
    | _, _, _ => .ok none

/-- Declarations pairing each unit with its authored numeric input. Both
numeric environments use the same names and shadowing as the checker. -/
abbrev ScalarBindings := List (String × (U × Num))

def scalarUnits (bindings : ScalarBindings) : List (String × U) :=
  bindings.map (fun entry => (entry.1, entry.2.1))

def scalarInputs (bindings : ScalarBindings) : Env Num :=
  bindings.map (fun entry => (entry.1, .num entry.2.2))

noncomputable def canonicalInputs (bindings : ScalarBindings) : Env Num :=
  bindings.map (fun entry => (entry.1, .num (scaleValue entry.2.1.scale.real entry.2.2)))

private theorem lookup_map_value {α β : Type} (f : α → β)
    (bindings : List (String × α)) (name : String) :
    (bindings.map (fun entry => (entry.1, f entry.2))).lookup name =
      (bindings.lookup name).map f := by
  induction bindings with
  | nil => rfl
  | cons entry rest ih =>
    obtain ⟨key, value⟩ := entry
    simp only [List.map_cons, List.lookup, ih]
    split <;> rfl

private theorem scale_one (x : Num) : scaleValue U.one.scale.real x = x := by
  cases x <;> simp [U.one, Scale.real_nil, scaleValue, Scalar.mul, Num.lift₂]

theorem checkPure_scales (u result : U) (h : checkPure u = .ok (some result)) :
    u.scale.real = U.one.scale.real ∧ result = U.one := by
  unfold checkPure at h
  split at h
  · rename_i agrees
    cases h
    exact ⟨Scale.real_congr _ _ agrees.1, rfl⟩
  · contradiction

private theorem compatible_scales {l r result : U}
    (h : checkKnown [l, r] = .ok (some result)) :
    l.scale.real = result.scale.real ∧ r.scale.real = result.scale.real := by
  have ⟨hm, compatible⟩ := checkKnown_compatible _ _ h
  exact ⟨Scale.real_congr _ _ (compatible l (by simp) result hm).1,
    Scale.real_congr _ _ (compatible r (by simp) result hm).1⟩

private theorem comparison_units {l r result : U}
    (h : ((checkKnown [l, r]).map fun _ => some U.one) = .ok (some result)) :
    result = U.one ∧ l.scale.real = r.scale.real := by
  unfold checkKnown at h
  split at h
  · rename_i ok
    have hr : U.one = result := by simpa [Except.map] using h
    have compatible := of_decide_eq_true (List.all_eq_true.mp (List.all_eq_true.mp ok l (by simp))
      r (by simp))
    exact ⟨hr.symm, Scale.real_congr _ _ compatible.1⟩
  · contradiction

theorem checkAtan2_units (y x result : U) (h : checkAtan2 y x = .ok (some result)) :
    y.Agree x ∧ result = .base .rad := by
  unfold checkAtan2 at h
  split at h
  · rename_i agrees
    cases h
    exact ⟨agrees, rfl⟩
  · contradiction

private theorem le_scale (s : ℝ) (hs : 0 < s) (x y : Num) :
    Scalar.le (scaleValue s x) (scaleValue s y) = Scalar.le x y := by
  change Num.le (scaleValue s x) (scaleValue s y) = Num.le x y
  cases x <;> cases y <;> simp [scaleValue, Scalar.mul, Num.lift₂, Num.le, mul_le_mul_iff_right₀ hs]

private theorem add_scale (s : ℝ) (x y : Num) :
    Scalar.add (scaleValue s x) (scaleValue s y) = scaleValue s (Scalar.add x y) := by
  cases x <;> cases y <;> simp [scaleValue, Scalar.add, Scalar.mul, Num.lift₂, mul_add]

private theorem sub_scale (s : ℝ) (x y : Num) :
    Scalar.sub (scaleValue s x) (scaleValue s y) = scaleValue s (Scalar.sub x y) := by
  cases x <;> cases y <;> simp [scaleValue, Scalar.sub, Scalar.mul, Num.lift₂, mul_sub]

private theorem mul_scale (s t : ℝ) (x y : Num) :
    Scalar.mul (scaleValue s x) (scaleValue t y) = scaleValue (s * t) (Scalar.mul x y) := by
  cases x <;> cases y <;> simp [scaleValue, Scalar.mul, Num.lift₂, mul_mul_mul_comm]

private theorem div_scale (s t : ℝ) (ht : 0 < t) (x y : Num) :
    Scalar.div (scaleValue s x) (scaleValue t y) = scaleValue (s / t) (Scalar.div x y) := by
  cases x <;> cases y <;> simp only [scaleValue, Scalar.mul, Scalar.div, Num.lift₂, Num.div]
  rename_i x y
  by_cases h : y = 0
  · simp [h]
  · simp [h, ht.ne', div_mul_div_comm]

private theorem unit_div_scale (u v : U) :
    (u.div v).scale.real = u.scale.real / v.scale.real := by
  simp [U.div, U.mul, U.inv, U.rpow, Scale.real_append, Scale.real_rpow, Real.rpow_neg_one,
    div_eq_mul_inv]

private theorem realPow_scale (s x e : ℝ) (hs : 0 < s) :
    realPow (s * x) e = scaleValue (s ^ e) (realPow x e) := by
  have hneg : s * x < 0 ↔ x < 0 := by
    simpa using (mul_lt_mul_iff_right₀ hs : s * x < s * 0 ↔ x < 0)
  by_cases hx : x < 0
  · simp only [realPow, hneg, hx, ite_true]
    split
    · rename_i integral
      have hs_pow : s ^ e = s ^ (⌊e⌋ : ℤ) := by
        calc
          s ^ e = s ^ ((⌊e⌋ : ℤ) : ℝ) := congrArg (fun t : ℝ => s ^ t) integral.symm
          _ = _ := Real.rpow_intCast s _
      simp [scaleValue, Scalar.mul, Num.lift₂, hs_pow, mul_zpow]
    · rfl
  · simp only [realPow, hneg, hx, ite_false, mul_eq_zero, hs.ne', false_or]
    split
    · rfl
    · simp [scaleValue, Scalar.mul, Num.lift₂, Real.mul_rpow hs.le (le_of_not_gt hx)]

private theorem pow_rational_scale (u : U) (q : ℚ) (x : Num) :
    Elem.pow (scaleValue u.scale.real x) (.fin (q : ℝ)) =
      scaleValue (u.rpow q).scale.real (Elem.pow x (.fin (q : ℝ))) := by
  cases x with
  | nan => rfl
  | fin x =>
    change realPow (u.scale.real * x) (q : ℝ) =
      scaleValue (Scale.real (Scale.rpow u.scale q)) (realPow x (q : ℝ))
    rw [Scale.real_rpow, realPow_scale _ _ _ (Scale.real_pos _)]

private theorem sign_scale (s : ℝ) (hs : 0 < s) (x : Num) :
    applyStrict .sign [.num (scaleValue s x)] = applyStrict .sign [.num x] := by
  cases x with
  | nan => rfl
  | fin x =>
    have hneg : s * x < 0 ↔ x < 0 := by
      simpa using (mul_lt_mul_iff_right₀ hs : s * x < s * 0 ↔ x < 0)
    have hpos : 0 < s * x ↔ 0 < x := by
      simpa using (mul_lt_mul_iff_right₀ hs : s * 0 < s * x ↔ 0 < x)
    by_cases hn : x < 0
    · simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, scaleValue, Scalar.mul,
        Num.lift₂, Scalar.lt, Num.lt, zero, Lits.ofDec, hneg, hn]
    · by_cases hp : 0 < x
      · simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, scaleValue, Scalar.mul,
          Num.lift₂, Scalar.lt, Num.lt, zero, Lits.ofDec, hneg, hn, hpos, hp]
      · have hz : x = 0 := le_antisymm (le_of_not_gt hp) (le_of_not_gt hn)
        simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, scaleValue, Scalar.mul,
          Num.lift₂, Scalar.lt, Num.lt, zero, Lits.ofDec, hz]

private theorem atan2_scale (s : ℝ) (hs : 0 < s) (y x : Num) :
    Elem.atan2 (scaleValue s y) (scaleValue s x) = Elem.atan2 y x := by
  cases y <;> cases x <;> try rfl
  rename_i y x
  change Num.fin (realAtan2 (s * y) (s * x)) = Num.fin (realAtan2 y x)
  have scaledPoint : (⟨s * x, s * y⟩ : ℂ) = (s : ℂ) * ⟨x, y⟩ := by
    apply Complex.ext <;> simp
  unfold realAtan2
  rw [scaledPoint, Complex.arg_real_mul _ hs]

private theorem unary_scale (op : Unary) (u result : U) (x : Num)
    (h : op.check u = .ok (some result)) :
    applyStrict op.op [.num (scaleValue u.scale.real x)] =
      (applyStrict op.op [.num x]).map (scaleValue result.scale.real) := by
  have hs := Scale.real_pos u.scale
  cases op with
  | neg =>
    cases h
    cases x <;> simp [Unary.op, applyStrict, asNum, bind, Except.bind, pure,
      Except.pure, Except.map, scaleValue, Scalar.mul, Num.lift₂, Elem.neg]
  | abs =>
    cases h
    cases x <;> simp [Unary.op, applyStrict, asNum, bind, Except.bind, pure,
      Except.pure, Except.map, scaleValue, Scalar.mul, Num.lift₂, Elem.abs, abs_mul, abs_of_pos hs]
  | sqrt =>
    cases h
    cases x with
    | nan => rfl
    | fin x =>
      simp only [Unary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure,
        Except.map, scaleValue, Scalar.mul, Num.lift₂, Elem.sqrt]
      have hneg : u.scale.real * x < 0 ↔ x < 0 := by
        simpa using (mul_lt_mul_iff_right₀ hs : u.scale.real * x < u.scale.real * 0 ↔ x < 0)
      by_cases hx : x < 0
      · simp [hneg, hx]
      · simp [hneg, hx, U.rpow, Scale.real_rpow, Real.sqrt_eq_rpow,
          Real.mul_rpow hs.le (le_of_not_gt hx)]
  | not =>
    cases h
    simp [Unary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      truthy_scaled _ hs, scale_one]
  | sign =>
    cases h
    rw [Unary.op, sign_scale _ hs]
    simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, scale_one]
  | exp | log | log10 =>
    obtain ⟨inputScale, rfl⟩ := checkPure_scales _ _ h
    simp [Unary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      inputScale, scale_one]

private theorem binary_scale (op : Binary) (l r result : U) (x y : Num)
    (h : op.check l r = .ok (some result)) :
    applyStrict op.op [.num (scaleValue l.scale.real x), .num (scaleValue r.scale.real y)] =
      (applyStrict op.op [.num x, .num y]).map (scaleValue result.scale.real) := by
  cases op with
  | mul =>
    cases h
    simp [Binary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      U.mul, Scale.real_append, mul_scale]
  | div =>
    cases h
    simp [Binary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      unit_div_scale, div_scale _ _ (Scale.real_pos r.scale)]
  | add | sub | min | max =>
    have ⟨hl, hr⟩ := compatible_scales h
    simp [Binary.op, applyStrict, asNum, hl, hr, bind, Except.bind, pure, Except.pure,
      Except.map, add_scale, sub_scale, fmin_scale _ (Scale.real_pos _), fmax_scale _ (Scale.real_pos _)]
  | le | ge | lt | gt | eq | ne =>
    have ⟨hu, hs⟩ := comparison_units h
    simp [Binary.op, applyStrict, asNum, hs, bind, Except.bind, pure, Except.pure, Except.map,
      hu, scale_one, le_scale _ (Scale.real_pos r.scale), lt_scale _ (Scale.real_pos r.scale)]
  | and | or =>
    cases h
    simp [Binary.op, applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      truthy_scaled _ (Scale.real_pos _), scale_one]
  | atan2 =>
    obtain ⟨agreement, rfl⟩ := checkAtan2_units _ _ _ h
    have sameScale := U.real_hom.2.2.2 l r agreement
    change applyStrict .atan2 [.num (scaleValue l.scale.real x), .num (scaleValue r.scale.real y)] =
      (applyStrict .atan2 [.num x, .num y]).map (scaleValue U.one.scale.real)
    simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
      sameScale, atan2_scale _ (Scale.real_pos r.scale), scale_one]

private theorem unary_evaluates (op : Unary) (x : Num) :
    ∃ value, applyStrict op.op [.num x] = .ok value := by
  cases op <;> exact ⟨_, rfl⟩

private theorem binary_evaluates (op : Binary) (x y : Num) :
    ∃ value, applyStrict op.op [.num x, .num y] = .ok value := by
  cases op <;> exact ⟨_, rfl⟩

private theorem eval_strict_one (name : String) (op : StrictOp) (arg : Ast) (env : Env Num)
    (dispatch : Op.ofString name = .strict op) (x : Num) (h : eval arg env = .ok (.num x)) :
    eval (.node name [arg]) env = (applyStrict op [.num x]).map Val.num := by
  simp [eval, evalList, dispatch, h, Val.arrayData, hasInf, bind, Except.bind,
    pure, Except.pure, Except.map]

private theorem eval_strict_two (name : String) (op : StrictOp) (left right : Ast) (env : Env Num)
    (dispatch : Op.ofString name = .strict op) (x y : Num)
    (hl : eval left env = .ok (.num x)) (hr : eval right env = .ok (.num y)) :
    eval (.node name [left, right]) env = (applyStrict op [.num x, .num y]).map Val.num := by
  simp [eval, evalList, dispatch, hl, hr, Val.arrayData, hasInf, bind, Except.bind,
    pure, Except.pure, Except.map]

theorem eval_rationalExponent (q : ℚ) (env : Env Num) :
    eval (rationalExponent q) env = .ok (.num (.fin (q : ℝ))) := by
  have nonzero : (q.den : ℝ) ≠ 0 := by exact_mod_cast (Rat.den_ne_zero q)
  simp [rationalExponent, eval, evalList, Op.ofString, Val.arrayData, hasInf, bind, Except.bind,
    pure, Except.pure, Lits.ofDec, applyStrict, asNum, Scalar.div, Num.div, nonzero, Rat.cast_def]

/-- For any expression in the resolved scalar fragment, checking fixes the
conversion scale of the result. Converting all of its declared inputs before
evaluation gives exactly the canonical value of the authored computation. -/
theorem checked_scalar_rescaling (bindings : ScalarBindings) (term : ScalarTerm) (result : U)
    (checked : term.check (scalarUnits bindings) = .ok (some result)) :
    ∃ value : Num, eval term.ast (scalarInputs bindings) = .ok (.num value) ∧
      eval term.ast (canonicalInputs bindings) = .ok (.num (scaleValue result.scale.real value)) := by
  induction term generalizing result with
  | var name =>
    simp only [ScalarTerm.check, scalarUnits, lookup_map_value, Except.ok.injEq] at checked
    cases found : bindings.lookup name with
    | none => simp [found] at checked
    | some entry =>
      obtain ⟨unit, value⟩ := entry
      simp [found] at checked
      subst result
      refine ⟨value, ?_, ?_⟩
      · simp only [ScalarTerm.ast, eval, scalarInputs]
        rw [lookup_map_value (fun pair : U × Num => Val.num pair.2), found]
        rfl
      · simp only [ScalarTerm.ast, eval, canonicalInputs]
        rw [lookup_map_value (fun pair : U × Num => Val.num (scaleValue pair.1.scale.real pair.2)),
          found]
        rfl
  | unary op arg ih =>
    cases h : arg.check (scalarUnits bindings) with
    | error e => simp [ScalarTerm.check, h, bind, Except.bind] at checked
    | ok child =>
      cases child with
      | none => simp [ScalarTerm.check, h, bind, Except.bind] at checked
      | some unit =>
        change (arg.check (scalarUnits bindings) >>= fun
          | some u => op.check u | none => .ok none) = .ok (some result) at checked
        rw [h] at checked
        change op.check unit = .ok (some result) at checked
        obtain ⟨x, hx, sx⟩ := ih unit h
        obtain ⟨value, hv⟩ := unary_evaluates op x
        have dispatch : Op.ofString op.spelling = .strict op.op := by cases op <;> rfl
        refine ⟨value, ?_, ?_⟩
        · rw [ScalarTerm.ast, eval_strict_one _ _ _ _ dispatch x hx, hv]
          rfl
        · rw [ScalarTerm.ast, eval_strict_one _ _ _ _ dispatch _ sx, unary_scale op unit result x checked, hv]
          rfl
  | binary op left right il ir =>
    cases hl : left.check (scalarUnits bindings) <;> cases hr : right.check (scalarUnits bindings) <;>
      simp only [ScalarTerm.check, hl, hr, bind, Except.bind] at checked <;> try contradiction
    rename_i l r
    cases l <;> cases r <;> simp at checked
    rename_i lu ru
    obtain ⟨x, hx, sx⟩ := il lu hl
    obtain ⟨y, hy, sy⟩ := ir ru hr
    obtain ⟨value, hv⟩ := binary_evaluates op x y
    have dispatch : Op.ofString op.spelling = .strict op.op := by cases op <;> rfl
    refine ⟨value, ?_, ?_⟩
    · rw [ScalarTerm.ast, eval_strict_two _ _ _ _ _ dispatch x y hx hy, hv]
      rfl
    · rw [ScalarTerm.ast, eval_strict_two _ _ _ _ _ dispatch _ _ sx sy,
        binary_scale op lu ru result x y checked, hv]
      rfl
  | power base exponent ih =>
    cases h : base.check (scalarUnits bindings) with
    | error e => simp [ScalarTerm.check, h, Except.map] at checked
    | ok found =>
      cases found with
      | none => simp [ScalarTerm.check, h, Except.map] at checked
      | some unit =>
        simp [ScalarTerm.check, h, Except.map] at checked
        subst result
        obtain ⟨x, hx, sx⟩ := ih unit h
        refine ⟨Elem.pow x (.fin (exponent : ℝ)), ?_, ?_⟩
        · rw [ScalarTerm.ast, eval_strict_two _ _ _ _ _ rfl _ _ hx (eval_rationalExponent _ _)]
          rfl
        · rw [ScalarTerm.ast, eval_strict_two _ _ _ _ _ rfl _ _ sx (eval_rationalExponent _ _)]
          change (Except.ok (.num (Elem.pow (scaleValue unit.scale.real x) (.fin (exponent : ℝ)))) :
            Except EvalError (Val Num)) = _
          rw [pow_rational_scale]
  | ifelse condition yes no ic iy ino =>
    cases hc : condition.check (scalarUnits bindings) <;> cases hy : yes.check (scalarUnits bindings) <;>
      cases hn : no.check (scalarUnits bindings) <;>
      simp only [ScalarTerm.check, hc, hy, hn, bind, Except.bind] at checked <;> try contradiction
    rename_i c y n
    cases c <;> cases y <;> cases n <;> simp at checked
    rename_i cu yu nu
    change checkKnown [yu, nu] = .ok (some result) at checked
    obtain ⟨sc, sy⟩ := compatible_scales checked
    obtain ⟨cond, hcond, scond⟩ := ic cu hc
    obtain ⟨yv, hyv, syv⟩ := iy yu hy
    obtain ⟨nv, hnv, snv⟩ := ino nu hn
    refine ⟨if truthy cond then yv else nv, ?_, ?_⟩
    · by_cases truth : truthy cond = true <;>
        simp [ScalarTerm.ast, eval, Op.ofString, evalIfelse, hcond, hyv, hnv, asNum,
          bind, Except.bind, truth]
    · by_cases truth : truthy cond = true <;>
        simp [ScalarTerm.ast, eval, Op.ofString, evalIfelse, scond, syv, snv, asNum,
          bind, Except.bind, truthy_scaled _ (Scale.real_pos _), sc, sy, truth]

/-! A bare additive literal can pass dimensional checking without specifying
how that literal must change when the surrounding expression is converted. -/

theorem unscaled_literal_breaks_rescaling (s x : ℝ) (h : s ≠ 1) :
    eval (.node "+" [.var "x", .num 1 0]) [("x", .num (Num.fin (s * x)))] ≠
      .ok (.num (Num.fin (s * (x + 1)))) := by
  let env : Env Num := [("x", .num (.fin (s * x)))]
  have hv : eval (.var "x") env = .ok (.num (.fin (s * x))) := by
    simp [eval, env]
  have hn : eval (.num 1 0) env = .ok (.num (.fin 1)) := by
    simp [eval, Lits.ofDec]
  change eval (.node "+" [.var "x", .num 1 0]) env ≠ _
  rw [eval_strict_two "+" .add _ _ env rfl _ _ hv hn]
  simp [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map, Scalar.add, Num.lift₂]
  intro eq
  apply h
  linarith only [eq, mul_add s x 1]

/-! Checker controls. These compute the verdicts with the exact scale comparison. -/

example :
    (match checkKnown [.base .m, (U.base .m).mul (.ofScale [(.pi, 1)])] with
    | .error .dimensionMismatch => true
    | _ => false) = true := by decide +kernel

example :
    (match checkKnown [.base .rad, .one, (U.base .rad).rpow 2] with
    | .error .dimensionMismatch => true
    | _ => false) = true := by decide +kernel

example :
    (match checkIfelse (.ok none) (.ok (some (.base .rad))) (.ok (some .one)) with
    | .ok (some u) => decide (u.dim = 0)
    | _ => false) = true := by decide +kernel

example :
    (match (.ifelse (.binary .lt (.var "x") (.var "y"))
        (.unary .abs (.var "x")) (.binary .sub (.var "y") (.var "x")) : ScalarTerm).check
        [("x", (U.base .m).mul (.ofScale [(.pi, 1)])),
          ("y", (U.base .m).mul (.ofScale [(.pi, 1)]))] with
    | .ok (some u) => decide (u.Agree ((U.base .m).mul (.ofScale [(.pi, 1)])))
    | _ => false) = true := by decide +kernel

example :
    (match checkPure (.ofScale [(.pi, 1)]) with
    | .error .dimensionMismatch => true
    | _ => false) = true := by decide +kernel

example :
    (match checkAtan2 (.base .rad) .one with
    | .error .dimensionMismatch => true
    | _ => false) = true := by decide +kernel

end Esm.Units.ScalarCheck
