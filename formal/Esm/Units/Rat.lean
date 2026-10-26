import Esm.Units.Core

/-!
# Exact scales of rational numbers

`Scale.ofRat q` is the prime factorization of a positive rational `q` in the
formal-product representation: every prime of the numerator with exponent `1`
and every prime of the denominator with exponent `-1`. Its exponent at a prime
`p` is the `p`-adic valuation of `q`, so multiplication of rationals is addition
of exponent maps — which is what lets every registry identity be checked exactly.
-/

namespace Esm.Units

/-- Each prime in the list, with exponent `e`. -/
def Scale.ofPrimes : (l : List ℕ) → (∀ p ∈ l, p.Prime) → ℚ → Scale
  | [], _, _ => []
  | p :: l, h, e =>
    (.prime ⟨p, h p List.mem_cons_self⟩, e) ::
      Scale.ofPrimes l (fun q hq => h q (List.mem_cons_of_mem _ hq)) e

/-- The prime factorization of `n`, each prime with exponent `e`. -/
def Scale.ofNat (n : ℕ) (e : ℚ) : Scale :=
  Scale.ofPrimes n.primeFactorsList (fun _ hp => Nat.prime_of_mem_primeFactorsList hp) e

/-- The exact scale of a positive rational. -/
def Scale.ofRat (q : ℚ) : Scale := Scale.ofNat q.num.natAbs 1 ++ Scale.ofNat q.den (-1)

/-- `π ^ e`. -/
def Scale.pi (e : ℚ) : Scale := [(.pi, e)]

theorem Scale.exp_ofPrimes_pi (l : List ℕ) (h : ∀ p ∈ l, p.Prime) (e : ℚ) :
    Scale.exp (Scale.ofPrimes l h e) .pi = 0 := by
  induction l with
  | nil => rfl
  | cons p l ih => simp [Scale.ofPrimes, ih]

theorem Scale.exp_ofPrimes_prime (l : List ℕ) (h : ∀ p ∈ l, p.Prime) (e : ℚ) (p : Nat.Primes) :
    Scale.exp (Scale.ofPrimes l h e) (.prime p) = (l.count p.1 : ℚ) * e := by
  induction l with
  | nil => simp [Scale.ofPrimes]
  | cons a l ih =>
    simp only [Scale.ofPrimes, Scale.exp_cons, ih, List.count_cons]
    by_cases hap : a = p.1
    · subst hap
      have : (Base.prime ⟨p.1, h p.1 List.mem_cons_self⟩) = Base.prime p := rfl
      simp only [this, ite_true, beq_self_eq_true]
      push_cast; ring
    · have hne : (Base.prime ⟨a, h a List.mem_cons_self⟩) ≠ Base.prime p := by
        intro hc; apply hap; cases hc; rfl
      have hb : (a == p.1) = false := by simpa using hap
      simp [hne, hb]

theorem Scale.real_ofPrimes (l : List ℕ) (h : ∀ p ∈ l, p.Prime) (e : ℚ) :
    Scale.real (Scale.ofPrimes l h e) = ((l.prod : ℕ) : ℝ) ^ (e : ℝ) := by
  induction l with
  | nil => simp [Scale.ofPrimes, Scale.real_nil]
  | cons a l ih =>
    simp only [Scale.ofPrimes, Scale.real_cons, ih, List.prod_cons, Nat.cast_mul, Base.real]
    rw [Real.mul_rpow (Nat.cast_nonneg _) (Nat.cast_nonneg _)]

theorem Scale.exp_ofNat_pi (n : ℕ) (e : ℚ) : Scale.exp (Scale.ofNat n e) .pi = 0 :=
  Scale.exp_ofPrimes_pi _ _ _

theorem Scale.exp_ofNat_prime (n : ℕ) (e : ℚ) (p : Nat.Primes) :
    Scale.exp (Scale.ofNat n e) (.prime p) = (padicValNat p.1 n : ℚ) * e := by
  rw [Scale.ofNat, Scale.exp_ofPrimes_prime, Nat.primeFactorsList_count_eq,
    Nat.factorization_def n p.2]

theorem Scale.real_ofNat (n : ℕ) (hn : n ≠ 0) (e : ℚ) :
    Scale.real (Scale.ofNat n e) = (n : ℝ) ^ (e : ℝ) := by
  rw [Scale.ofNat, Scale.real_ofPrimes, Nat.prod_primeFactorsList hn]

@[simp] theorem Scale.exp_ofRat_pi (q : ℚ) : Scale.exp (Scale.ofRat q) .pi = 0 := by
  simp [Scale.ofRat, Scale.exp_ofNat_pi]

/-- The exponent of a prime in `ofRat q` is the `p`-adic valuation of `q`. -/
@[simp] theorem Scale.exp_ofRat_prime (q : ℚ) (p : Nat.Primes) :
    Scale.exp (Scale.ofRat q) (.prime p) = (padicValRat p.1 q : ℚ) := by
  rw [Scale.ofRat, Scale.exp_append, Scale.exp_ofNat_prime, Scale.exp_ofNat_prime]
  rw [padicValRat_def, padicValInt]
  simp only [Int.cast_sub, Int.cast_natCast]
  ring

/-- `ofRat q` denotes `q`. -/
theorem Scale.real_ofRat (q : ℚ) (hq : 0 < q) : Scale.real (Scale.ofRat q) = (q : ℝ) := by
  have hnum : q.num.natAbs ≠ 0 := by
    simpa using (Rat.num_pos.mpr hq).ne'
  rw [Scale.ofRat, Scale.real_append, Scale.real_ofNat _ hnum, Scale.real_ofNat _ q.den_nz]
  have h1 : ((q.num.natAbs : ℕ) : ℝ) = (q.num : ℝ) := by
    have h0 : (0 : ℝ) ≤ (q.num : ℝ) := by exact_mod_cast (Rat.num_pos.mpr hq).le
    rw [Nat.cast_natAbs, Int.cast_abs, abs_of_nonneg h0]
  push_cast
  rw [Real.rpow_one, Real.rpow_neg_one, h1, ← div_eq_mul_inv, Rat.cast_def]

theorem Scale.real_pi (e : ℚ) : Scale.real (Scale.pi e) = Real.pi ^ (e : ℝ) := by
  simp [Scale.pi, Scale.real, Base.real]

@[simp] theorem Scale.exp_pi_pi (e : ℚ) : Scale.exp (Scale.pi e) .pi = e := by
  simp [Scale.pi]

@[simp] theorem Scale.exp_pi_prime (e : ℚ) (p : Nat.Primes) :
    Scale.exp (Scale.pi e) (.prime p) = 0 := by
  simp [Scale.pi]

/-- Multiplying rationals adds their exact scales. -/
theorem Scale.exp_ofRat_mul (q r : ℚ) (hq : q ≠ 0) (hr : r ≠ 0) :
    Scale.exp (Scale.ofRat (q * r)) = Scale.exp (Scale.ofRat q ++ Scale.ofRat r) := by
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp [padicValRat.mul hq hr]

theorem Scale.exp_ofRat_inv (q : ℚ) :
    Scale.exp (Scale.ofRat q⁻¹) = Scale.exp (Scale.rpow (Scale.ofRat q) (-1)) := by
  funext b
  cases b with
  | pi => simp
  | prime p =>
    have : Fact p.1.Prime := ⟨p.2⟩
    simp [padicValRat.inv]

theorem Scale.exp_ofRat_one : Scale.exp (Scale.ofRat 1) = Scale.exp [] := by
  funext b
  cases b with
  | pi => simp
  | prime p => simp

/-- Two positive rationals have the same exact scale iff they are equal. -/
theorem Scale.exp_ofRat_inj (q r : ℚ) (hq : 0 < q) (hr : 0 < r) :
    Scale.exp (Scale.ofRat q) = Scale.exp (Scale.ofRat r) ↔ q = r := by
  constructor
  · intro h
    have := Scale.real_congr _ _ h
    rw [Scale.real_ofRat q hq, Scale.real_ofRat r hr] at this
    exact_mod_cast this
  · rintro rfl; rfl

end Esm.Units
