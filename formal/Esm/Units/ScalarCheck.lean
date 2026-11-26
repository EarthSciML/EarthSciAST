import Esm.Expr.Core
import Esm.Units.Laws

/-!
# Unit preservation for scalar extrema and `ifelse` (esm-spec §4.8.3–4.8.4)

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

end Esm.Units.ScalarCheck
