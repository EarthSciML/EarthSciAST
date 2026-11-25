import Esm.Expr.Core
import Mathlib.Algebra.Order.Monoid.Unbundled.MinMax
import Mathlib.Algebra.Order.AddGroupWithTop
import Mathlib.Basic.NNReal.Defs
import Mathlib.Data.List.Perm.Basic
import Mathlib.Tactic.NormNum

/-!
# Exact FAQ semiring operations and laws

The nominal carrier of the `max_product` row omits its specified empty
sentinel. The exact algebra adjoins that sentinel to the nonnegative reals,
and its product with any term is again the sentinel (the semiring zero law).
This construction documents the distinction between the carrier of admitted
finite terms and that of the reduction. Q-114 records the unresolved format
policy for a negative term, and for reusing the sentinel in a product.
-/

namespace Esm.Semiring

open scoped NNReal

theorem Name.parse_spelling (n : Name) : Name.parse n.spelling = .ok n := by
  cases n <;> rfl

theorem resolveReduction_registered (n : Name) (legacy : Option String) :
    resolveReduction (some n.spelling) legacy = .ok n.reduction := by
  rw [resolveReduction, n.parse_spelling]
  rfl

/-- The two operations and two identities fixed by a registry row. -/
structure Operations (α : Type) where
  reduce : α → α → α
  empty : α
  product : α → α → α
  one : α

/-- Exact commutative-semiring laws for the registry operations. Commutativity
also gives the right identities, right annihilation, and right distributivity. -/
structure Valid {α : Type} (op : Operations α) : Prop where
  reduce_assoc : ∀ a b c, op.reduce (op.reduce a b) c = op.reduce a (op.reduce b c)
  reduce_comm : ∀ a b, op.reduce a b = op.reduce b a
  empty_reduce : ∀ a, op.reduce op.empty a = a
  product_assoc : ∀ a b c, op.product (op.product a b) c = op.product a (op.product b c)
  product_comm : ∀ a b, op.product a b = op.product b a
  one_product : ∀ a, op.product op.one a = a
  empty_product : ∀ a, op.product op.empty a = op.empty
  distributive : ∀ a b c,
    op.product a (op.reduce b c) = op.reduce (op.product a b) (op.product a c)

/-- An ordered sentinel for a missing `max_product` term. Finite factors are
nonnegative, so multiplication by a finite factor is monotone. -/
abbrev MaxProduct := WithBot ℝ≥0

noncomputable def maxProductMul : MaxProduct → MaxProduct → MaxProduct
  | (a : ℝ≥0), (b : ℝ≥0) => ↑(a * b)
  | _, _ => ⊥

/-- The exact carrier of each row, including its empty-reduction value. -/
abbrev Carrier : Name → Type
  | .sumProduct => ℝ
  | .maxProduct => MaxProduct
  | .minSum => WithTop ℝ
  | .maxSum => WithBot ℝ
  | .boolAndOr => Bool

noncomputable def operations : (row : Name) → Operations (Carrier row)
  | .sumProduct => ⟨(· + ·), 0, (· * ·), 1⟩
  | .maxProduct => ⟨max, ⊥, maxProductMul, ↑(1 : ℝ≥0)⟩
  | .minSum => ⟨min, ⊤, (· + ·), 0⟩
  | .maxSum => ⟨max, ⊥, (· + ·), 0⟩
  | .boolAndOr => ⟨(· || ·), false, (· && ·), true⟩

private theorem maxProductMul_assoc (a b c : MaxProduct) :
    maxProductMul (maxProductMul a b) c = maxProductMul a (maxProductMul b c) := by
  cases a <;> cases b <;> cases c <;> simp only [maxProductMul, mul_assoc]

private theorem maxProductMul_comm (a b : MaxProduct) :
    maxProductMul a b = maxProductMul b a := by
  cases a <;> cases b <;> simp only [maxProductMul, mul_comm]

private theorem one_maxProductMul (a : MaxProduct) : maxProductMul ↑(1 : ℝ≥0) a = a := by
  cases a <;> simp only [maxProductMul, one_mul] <;> rfl

private theorem bot_maxProductMul (a : MaxProduct) : maxProductMul ⊥ a = ⊥ := by
  cases a <;> rfl

private theorem maxProductMul_monotone (a : MaxProduct) : Monotone (maxProductMul a) := by
  intro b c h
  induction a using WithBot.recBotCoe with
  | bot => simp only [bot_maxProductMul, le_refl]
  | coe a =>
    induction b using WithBot.recBotCoe with
    | bot => exact bot_le
    | coe b =>
      induction c using WithBot.recBotCoe with
      | bot => exact (not_le_of_gt (WithBot.bot_lt_coe b) h).elim
      | coe c => exact WithBot.coe_le_coe.2 (mul_le_mul_right (WithBot.coe_le_coe.1 h) a)

/-- The registry rows satisfy the semiring laws on their exact carriers.
These laws impose no reassociation permission on a binary64 fold. -/
theorem operations_valid : ∀ row : Name, Valid (operations row)
  | .sumProduct =>
    ⟨add_assoc, add_comm, zero_add, mul_assoc, mul_comm, one_mul, zero_mul, mul_add⟩
  | .maxProduct =>
    ⟨max_assoc, max_comm, max_bot_left, maxProductMul_assoc, maxProductMul_comm,
      one_maxProductMul, bot_maxProductMul, fun a _ _ => (maxProductMul_monotone a).map_max⟩
  | .minSum =>
    ⟨min_assoc, min_comm, min_top_left, add_assoc, add_comm, zero_add, WithTop.top_add,
      fun a _ _ => (show Monotone (a + ·) from fun _ _ h => add_le_add_right h a).map_min⟩
  | .maxSum =>
    ⟨max_assoc, max_comm, max_bot_left, add_assoc, add_comm, zero_add, WithBot.bot_add,
      fun a _ _ => (show Monotone (a + ·) from fun _ _ h => add_le_add_right h a).map_max⟩
  | .boolAndOr => by
    refine ⟨Bool.or_assoc, Bool.or_comm, Bool.false_or, Bool.and_assoc, Bool.and_comm,
      Bool.true_and, Bool.false_and, ?_⟩
    intro a b c
    cases a <;> rfl

/-- Nonnegative finite multiplication is essential to the `max_product`
distributive law. Using ordinary signed multiplication admits a counterexample. -/
theorem signed_max_product_not_distributive :
    ¬ (∀ a b c : ℝ, a * max b c = max (a * b) (a * c)) := by
  intro h
  have hc := h (-1) 0 1
  norm_num [max_def] at hc

/-- The production fold has the existential meaning for successfully evaluated
terms. Excluded terms have a false indicator. -/
theorem foldBoolM_except_eq_any {α ε : Type} (items : List α)
    (term : α → Except ε Bool) (predicate : α → Bool)
    (h : ∀ x ∈ items, term x = .ok (predicate x)) :
    foldBoolM items term = .ok (items.any predicate) := by
  let step := fun (acc : Bool) (x : α) => do
    let value ← term x
    pure (acc || value)
  have foldAny (xs : List α) (init : Bool)
      (hxs : ∀ x ∈ xs, term x = .ok (predicate x)) :
      xs.foldlM step init = .ok (init || xs.any predicate) := by
    induction xs generalizing init with
    | nil => cases init <;> rfl
    | cons x xs ih =>
      have hstep : step init x = .ok (init || predicate x) := by
        simp only [step, hxs x (by simp), bind, Except.bind, pure, Except.pure]
      simp only [List.foldlM_cons, List.any_cons, hstep]
      change xs.foldlM step (init || predicate x) =
        .ok (init || (predicate x || xs.any predicate))
      rw [ih _ (fun y hy => hxs y (List.mem_cons_of_mem x hy)), Bool.or_assoc]
  exact foldAny items false h

theorem foldBoolM_except_perm {α ε : Type} (items reordered : List α)
    (term : α → Except ε Bool) (predicate : α → Bool)
    (h : ∀ x ∈ items, term x = .ok (predicate x)) (perm : items.Perm reordered) :
    foldBoolM items term = foldBoolM reordered term := by
  rw [foldBoolM_except_eq_any _ _ _ h,
    foldBoolM_except_eq_any _ _ _ (fun x hx => h x (perm.mem_iff.mpr hx))]
  exact congrArg Except.ok (Bool.eq_iff_iff.2 (by simp only [List.any_eq_true, perm.mem_iff]))

/-- The exact Boolean identity is also the result when every item is
excluded, because the executable fold sees a false indicator for each. -/
theorem foldBoolM_except_all_excluded {α ε : Type} (items : List α)
    (term : α → Except ε Bool) (h : ∀ x ∈ items, term x = .ok false) :
    foldBoolM items term = .ok false := by
  rw [foldBoolM_except_eq_any _ _ (fun _ => false) h]
  simp

/-- An admitted NaN term counts as true, independently of ordered comparison. -/
theorem nonzeroTerm_nan {α : Type} [Esm.Closed.Scalar α] [Esm.Expr.Lits α] (x : α)
    (h : Esm.Closed.Scalar.isNaN x = true) :
    Esm.Expr.nonzeroTerm (Esm.Expr.Val.num x) = .ok true := by
  simp [Esm.Expr.nonzeroTerm, h, pure, Except.pure]

end Esm.Semiring
