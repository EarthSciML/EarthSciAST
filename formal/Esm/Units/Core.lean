import Mathlib.Analysis.SpecialFunctions.Pow.Real
import Mathlib.Analysis.Real.Pi.Bounds
import Mathlib.Data.Nat.Factors
import Mathlib.NumberTheory.Padics.PadicVal.Basic

/-!
# Units: dimensions and exact scales (esm-spec §4.8.1)

A **dimension** is a vector of rational exponents over exactly the eight axes
`m kg s mol K A cd rad` (§4.8.1 "The eight canonical dimension axes").

A **scale** is exact. §4.8.1 recommends representing it as "a map from prime
factor (and the symbol `π`) to a rational exponent"; this module does exactly
that. A scale is written as a formal product `∏ bᵢ ^ eᵢ` (a list of base/exponent
pairs, `Scale`), and what it MEANS is its exponent map `Scale.exp : Base → ℚ`:
two scales are the same scale iff their exponent maps are equal. Multiplying
units appends the lists (adds exponent maps), a rational power multiplies every
exponent, so a composite unit's scale stays exact (§4.8.1 "Scales are EXACT").

`Scale.real` is the real number a scale denotes. It is a homomorphism, depends
only on the exponent map, and is positive; these are the facts that make the
formal representation a faithful exact model of the spec's real-valued scales.
-/

namespace Esm.Units

/-- The eight canonical dimension axes, and no others (§4.8.1). -/
inductive Axis
  | m | kg | s | mol | K | A | cd | rad
  deriving DecidableEq, Repr, Inhabited

/-- Every axis, in the spec's order. -/
def Axis.all : List Axis := [.m, .kg, .s, .mol, .K, .A, .cd, .rad]

theorem Axis.mem_all (a : Axis) : a ∈ Axis.all := by cases a <;> simp [Axis.all]

instance : Fintype Axis :=
  ⟨⟨(Axis.all : Multiset Axis), by decide⟩, Axis.mem_all⟩

def Axis.name : Axis → String
  | .m => "m" | .kg => "kg" | .s => "s" | .mol => "mol"
  | .K => "K" | .A => "A" | .cd => "cd" | .rad => "rad"

/-- A dimension: a rational exponent per axis. Unit multiplication is `+`, a
rational power `q` is `q • ·`. -/
abbrev Dim := Axis → ℚ

/-- The dimension of one axis to the first power. -/
def Dim.of (a : Axis) : Dim := fun b => if b = a then 1 else 0

/-- A base of the exact-scale representation: `π` or a prime. -/
inductive Base
  | pi
  | prime (p : Nat.Primes)
  deriving DecidableEq

@[simp] theorem Base.prime_mk_eq (a b : ℕ) (ha : a.Prime) (hb : b.Prime) :
    (Base.prime ⟨a, ha⟩ = Base.prime ⟨b, hb⟩) = (a = b) := by
  apply propext; constructor
  · intro h; cases h; rfl
  · rintro rfl; rfl

/-- The real number a base denotes. -/
noncomputable def Base.real : Base → ℝ
  | .pi => Real.pi
  | .prime p => (p.1 : ℝ)

theorem Base.real_pos : ∀ b : Base, 0 < b.real
  | .pi => Real.pi_pos
  | .prime p => by simp [Base.real, p.2.pos]

/-- An exact scale as a formal product `∏ b ^ e`. Only its exponent map
(`Scale.exp`) is meaningful; the list order and repetitions are not. -/
abbrev Scale := List (Base × ℚ)

/-- The exponent of base `b` in a scale. -/
def Scale.exp : Scale → Base → ℚ
  | [], _ => 0
  | (c, e) :: s, b => (if c = b then e else 0) + Scale.exp s b

/-- Raise a scale to a rational power. -/
def Scale.rpow (s : Scale) (q : ℚ) : Scale := s.map fun x => (x.1, q * x.2)

/-- The real number a scale denotes. -/
noncomputable def Scale.real (s : Scale) : ℝ :=
  (s.map fun x => x.1.real ^ (x.2 : ℝ)).prod

@[simp] theorem Scale.exp_nil (b : Base) : Scale.exp [] b = 0 := rfl

@[simp] theorem Scale.exp_cons (c : Base) (e : ℚ) (s : Scale) (b : Base) :
    Scale.exp ((c, e) :: s) b = (if c = b then e else 0) + Scale.exp s b := rfl

@[simp] theorem Scale.exp_append (s t : Scale) (b : Base) :
    Scale.exp (s ++ t) b = Scale.exp s b + Scale.exp t b := by
  induction s with
  | nil => simp
  | cons x s ih => obtain ⟨c, e⟩ := x; simp [ih, add_assoc]

@[simp] theorem Scale.exp_rpow (s : Scale) (q : ℚ) (b : Base) :
    Scale.exp (Scale.rpow s q) b = q * Scale.exp s b := by
  induction s with
  | nil => simp [Scale.rpow]
  | cons x s ih =>
    obtain ⟨c, e⟩ := x
    simp only [Scale.rpow, List.map_cons] at ih ⊢
    simp only [Scale.exp_cons, ih]
    split_ifs <;> ring

/-- A base outside a scale's support has exponent 0. -/
theorem Scale.exp_eq_zero_of_not_mem (s : Scale) (b : Base) (h : b ∉ s.map Prod.fst) :
    Scale.exp s b = 0 := by
  induction s with
  | nil => rfl
  | cons x s ih =>
    obtain ⟨c, e⟩ := x
    simp only [List.map_cons, List.mem_cons, not_or] at h
    simp [Ne.symm h.1, ih h.2]

/-- Equality of exponent maps is decided on the finitely many bases that occur. -/
theorem Scale.exp_eq_iff (s t : Scale) :
    Scale.exp s = Scale.exp t ↔ ∀ b ∈ (s ++ t).map Prod.fst, Scale.exp s b = Scale.exp t b := by
  constructor
  · intro h b _; rw [h]
  · intro h
    funext b
    by_cases hb : b ∈ (s ++ t).map Prod.fst
    · exact h b hb
    · simp only [List.map_append, List.mem_append, not_or] at hb
      rw [Scale.exp_eq_zero_of_not_mem s b hb.1, Scale.exp_eq_zero_of_not_mem t b hb.2]

instance (s t : Scale) : Decidable (Scale.exp s = Scale.exp t) :=
  decidable_of_iff _ (Scale.exp_eq_iff s t).symm

/-! ### The real value of a scale -/

theorem Scale.real_nil : Scale.real [] = 1 := by simp [Scale.real]

theorem Scale.real_cons (b : Base) (e : ℚ) (s : Scale) :
    Scale.real ((b, e) :: s) = b.real ^ (e : ℝ) * Scale.real s := by
  simp [Scale.real]

theorem Scale.real_pos (s : Scale) : 0 < Scale.real s := by
  induction s with
  | nil => simp [Scale.real_nil]
  | cons x s ih =>
    obtain ⟨c, e⟩ := x
    rw [Scale.real_cons]
    exact mul_pos (Real.rpow_pos_of_pos c.real_pos _) ih

theorem Scale.real_append (s t : Scale) : Scale.real (s ++ t) = Scale.real s * Scale.real t := by
  simp [Scale.real, List.map_append, List.prod_append]

theorem Scale.real_rpow (s : Scale) (q : ℚ) :
    Scale.real (Scale.rpow s q) = Scale.real s ^ (q : ℝ) := by
  induction s with
  | nil => simp [Scale.rpow, Scale.real_nil]
  | cons x s ih =>
    obtain ⟨c, e⟩ := x
    have ih' : Scale.real (Scale.rpow s q) = Scale.real s ^ (q : ℝ) := ih
    simp only [Scale.rpow, List.map_cons] at ih' ⊢
    rw [Scale.real_cons, Scale.real_cons, ih',
      Real.mul_rpow (Real.rpow_pos_of_pos c.real_pos _).le (Scale.real_pos s).le,
      ← Real.rpow_mul c.real_pos.le]
    push_cast
    ring_nf

/-- The real value as a product over any finite set of bases containing the
support. -/
theorem Scale.real_eq_prod (s : Scale) (S : Finset Base) (hS : ∀ x ∈ s, x.1 ∈ S) :
    Scale.real s = ∏ b ∈ S, b.real ^ ((Scale.exp s b : ℚ) : ℝ) := by
  induction s with
  | nil => simp [Scale.real_nil]
  | cons x s ih =>
    obtain ⟨c, e⟩ := x
    have hc : c ∈ S := hS (c, e) (by simp)
    have hs : ∀ y ∈ s, y.1 ∈ S := fun y hy => hS y (by simp [hy])
    rw [Scale.real_cons, ih hs]
    have : ∀ b ∈ S, b.real ^ ((Scale.exp ((c, e) :: s) b : ℚ) : ℝ)
        = (if c = b then b.real ^ (e : ℝ) else 1) * b.real ^ ((Scale.exp s b : ℚ) : ℝ) := by
      intro b _
      rw [Scale.exp_cons]
      split_ifs with h
      · push_cast; rw [Real.rpow_add b.real_pos]
      · simp
    rw [Finset.prod_congr rfl this, Finset.prod_mul_distrib]
    congr 1
    rw [Finset.prod_ite_eq S c (fun b => b.real ^ (e : ℝ))]
    simp [hc]

/-- The real value depends only on the exponent map: the formal representation
never distinguishes a scale from itself. -/
theorem Scale.real_congr (s t : Scale) (h : Scale.exp s = Scale.exp t) :
    Scale.real s = Scale.real t := by
  classical
  let S : Finset Base := ((s ++ t).map Prod.fst).toFinset
  have hs : ∀ x ∈ s, x.1 ∈ S := fun x hx => by
    simp only [S, List.mem_toFinset, List.map_append, List.mem_append, List.mem_map]
    exact Or.inl ⟨x, hx, rfl⟩
  have ht : ∀ x ∈ t, x.1 ∈ S := fun x hx => by
    simp only [S, List.mem_toFinset, List.map_append, List.mem_append, List.mem_map]
    exact Or.inr ⟨x, hx, rfl⟩
  rw [Scale.real_eq_prod s S hs, Scale.real_eq_prod t S ht, h]

/-! ### Units -/

/-- A resolved unit: a dimension and an exact scale. -/
structure U where
  dim : Dim
  scale : Scale

namespace U

/-- The dimensionless unit at scale 1. -/
def one : U := ⟨0, []⟩

def mul (u v : U) : U := ⟨u.dim + v.dim, u.scale ++ v.scale⟩

/-- A rational power. -/
def rpow (u : U) (q : ℚ) : U := ⟨q • u.dim, Scale.rpow u.scale q⟩

def inv (u : U) : U := u.rpow (-1)

def div (u v : U) : U := u.mul v.inv

/-- What a unit means: its dimension and its scale's exponent map. -/
def val (u : U) : Dim × (Base → ℚ) := (u.dim, Scale.exp u.scale)

/-- Two units agree iff they have the same dimension and the same exact scale
(§4.8.3 "agreement"; decided exactly, §4.8.1). -/
def Agree (u v : U) : Prop := u.val = v.val

instance (u v : U) : Decidable (Agree u v) := by
  unfold Agree val
  exact decidable_of_iff (u.dim = v.dim ∧ Scale.exp u.scale = Scale.exp v.scale)
    (by simp [Prod.ext_iff])

/-- The unit that is the given exact positive rational, dimensionless. -/
def ofScale (s : Scale) : U := ⟨0, s⟩

/-- A unit of one axis at scale 1. -/
def base (a : Axis) : U := ⟨Dim.of a, []⟩

@[simp] theorem val_mul (u v : U) : (u.mul v).val = u.val + v.val := by
  simp only [val, mul, Prod.mk_add_mk, Prod.mk.injEq, true_and]
  funext b; simp

@[simp] theorem val_rpow (u : U) (q : ℚ) : (u.rpow q).val = q • u.val := by
  simp only [val, rpow, Prod.smul_mk, Prod.mk.injEq, true_and]
  funext b; simp

@[simp] theorem val_one : one.val = 0 := by
  simp only [val, one, Prod.mk_eq_zero, true_and]; funext b; simp

end U

end Esm.Units
