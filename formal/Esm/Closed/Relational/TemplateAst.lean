import Esm.Closed.Interp.TemplateAst
import Esm.Lib.Relational

/-!
# The `lib/relational.esm` templates: argmin and argmax

`Esm/Lib/Relational.lean` holds the `argmin` and `argmax` templates of
`lib/relational.esm` (generated, checked current in CI). Each takes a
candidate expression `f` over its loop symbol (`k_argmin_1`, `k_argmax_1`) and
the candidate count `n`, and is two `faq` reductions:
`M = min_k f(k)` (`max` for argmax), then
`min_k ifelse(f(k) == M or (f(k) != f(k) and M != M), k, n + 1)`.

`argmin_template` and `argmax_template` prove, at every scalar type with
`RealNaN` and `ExprLaws` (the exact `Num`, the binary64 `Bin64`), for every
candidate expression whose value at candidate `j` is `v j` (whatever an outer
binding of the same loop symbol, which the template's inner reduction adds):

* the result is an index `j` in `[1, n]`;
* if some candidate is NaN, `v j` is NaN and no earlier candidate is (the
  first NaN index, ruling 11);
* otherwise `v j` is a minimum (maximum) of the candidates, and every earlier
  candidate is strictly greater (smaller): the smallest minimizing
  (maximizing) index, the normative tie-break.

`n ≥ 1` is assumed: for `n = 0` the outer `min` reduction is empty, its
identity `+∞` is not a value of the model's scalar types, and the evaluator
refuses it (`EvalError.unsupported`).
-/

namespace Esm.Closed.RelationalAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## Folds -/

/-- `foldR f g m = f (… f (f (g 1) (g 2)) …) (g (m + 1))`: the fold of a
non-empty `min` / `max` reduction over `[1, m + 1]`. -/
def foldR {α : Type} (f : α → α → α) (g : ℕ → α) : ℕ → α
  | 0 => g 1
  | m + 1 => f (foldR f g m) (g (m + 2))

/-! ## The template, expanded -/

/-- The inner reduction `faq(reduce red, ranges {k: [1, n]}, expr F)`. -/
def innerA (k red : String) (F : Ast) (n : ℕ) : Ast :=
  .faq [] red (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) F []

/-- The selection test `f == M or (f != f and M != M)`. -/
def testA (k red : String) (F : Ast) (n : ℕ) : Ast :=
  .node "or" [.node "==" [F, innerA k red F n],
    .node "and" [.node "!=" [F, F], .node "!=" [innerA k red F n, innerA k red F n]]]

def argA (k red : String) (F : Ast) (n : ℕ) : Ast :=
  .faq [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil)
    (.node "ifelse" [testA k red F n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) []

theorem expand_argmin (F : Ast) (n : ℕ) :
    expand Esm.Lib.Relational.argmin [("f", F), ("n", .num (n : ℤ) 0)] =
      .ok (argA "k_argmin_1" "min" F n) := rfl

theorem expand_argmax (F : Ast) (n : ℕ) :
    expand Esm.Lib.Relational.argmax [("f", F), ("n", .num (n : ℤ) 0)] =
      .ok (argA "k_argmax_1" "max" F n) := rfl

/-! ## Evaluating a non-empty `min` / `max` reduction -/

section Eval

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

theorem indices_succ (m : ℕ) :
    indices 1 ((m + 1 : ℕ) : ℤ) = 1 :: (List.range m).map (fun i : ℕ => (2 : ℤ) + i) := by
  simp only [indices]
  rw [show ((m + 1 : ℕ) : ℤ) + 1 - 1 = ((m + 1 : ℕ) : ℤ) by ring, Int.toNat_natCast,
    List.range_succ_eq_map]
  simp only [List.map_cons, List.map_map, Nat.cast_zero, add_zero, List.cons.injEq, true_and]
  apply List.map_congr_left
  intro i _
  simp only [Function.comp_apply, Nat.cast_succ]
  ring

theorem foldlM_foldR (f : α → α → α) (g : ℕ → α) (step : α → ℤ → Except EvalError α) (M : ℕ)
    (hstep : ∀ acc (i : ℕ), i < M → step acc ((2 : ℤ) + i) = .ok (f acc (g (i + 2)))) :
    ∀ m, m ≤ M →
      ((List.range m).map (fun i : ℕ => (2 : ℤ) + i)).foldlM step (g 1) = .ok (foldR f g m) := by
  intro m
  induction m with
  | zero => intro _; rfl
  | succ m ih =>
    intro hm
    have hs := hstep (foldR f g m) m (by omega)
    rw [List.range_succ, List.map_append, List.foldlM_append, ih (by omega)]
    simp only [List.map_cons, List.map_nil, List.foldlM_cons, List.foldlM_nil, bind, Except.bind,
      hs, pure, Except.pure, foldR]

theorem ofDec_nat' {j : ℕ} (h : j ≤ 2 ^ 53) : (Lits.ofDec (j : ℤ) 0 : α) = fin (j : ℝ) := by
  rw [ExprLaws.ofDec_int _ (nat_abs_le h)]; push_cast; rfl

theorem toInt_n {n : ℕ} (h : n ≤ 2 ^ 53) : Lits.toInt? (Lits.ofDec (n : ℤ) 0 : α) = some n := by
  rw [ofDec_nat' h]; exact toInt_nat n

/-- A `min` reduction over `[1, n]`, `n ≥ 1`, whose body is `g j` at index `j`. -/
theorem ev_faq_min {k : String} {body : Ast} {args : List Ast} {env : Env α} {m : ℕ}
    (hn : m + 1 ≤ 2 ^ 53) (g : ℕ → α)
    (hb : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 → eval body ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (g j))) :
    eval (.faq [] "min" (.cons k [.num 1 0, .num ((m + 1 : ℕ) : ℤ) 0] .nil) body args) env =
      .ok (.num (foldR fmin g m)) := by
  have hb1 : eval body ((k, .num (fin 1)) :: env) = .ok (.num (g 1)) := by
    simpa using hb 1 le_rfl (by omega)
  have o1 : (Lits.ofDec (1 : ℤ) 0 : α) = fin 1 := by
    simpa using ofDec_nat' (α := α) (j := 1) (by norm_num)
  have t1 : Lits.toInt? (fin 1 : α) = some 1 := by
    simpa using toInt_nat (α := α) 1
  have hfold := foldlM_foldR (α := α) fmin g (fun acc i => do
      return fmin acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) m ?_ m le_rfl
  · simp only [eval, asNum, asInt, toInt_n hn, bind, Except.bind, pure,
      Except.pure, Option.bind, o1, t1, indices_succ, hb1] at hfold ⊢
    rw [hfold]
  · intro acc i hi
    have e : (Lits.ofDec ((2 : ℤ) + (i : ℤ)) 0 : α) = fin (((i + 2 : ℕ)) : ℝ) := by
      rw [show (2 : ℤ) + (i : ℤ) = ((i + 2 : ℕ) : ℤ) by push_cast; ring]
      exact ofDec_nat' (by omega)
    simp only [e, hb (i + 2) (by omega) (by omega), bind, Except.bind, pure, Except.pure, asNum]

/-- A `max` reduction over `[1, n]`, `n ≥ 1`, whose body is `g j` at index `j`. -/
theorem ev_faq_max {k : String} {body : Ast} {args : List Ast} {env : Env α} {m : ℕ}
    (hn : m + 1 ≤ 2 ^ 53) (g : ℕ → α)
    (hb : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 → eval body ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (g j))) :
    eval (.faq [] "max" (.cons k [.num 1 0, .num ((m + 1 : ℕ) : ℤ) 0] .nil) body args) env =
      .ok (.num (foldR fmax g m)) := by
  have hb1 : eval body ((k, .num (fin 1)) :: env) = .ok (.num (g 1)) := by
    simpa using hb 1 le_rfl (by omega)
  have o1 : (Lits.ofDec (1 : ℤ) 0 : α) = fin 1 := by
    simpa using ofDec_nat' (α := α) (j := 1) (by norm_num)
  have t1 : Lits.toInt? (fin 1 : α) = some 1 := by
    simpa using toInt_nat (α := α) 1
  have hfold := foldlM_foldR (α := α) fmax g (fun acc i => do
      return fmax acc (← asNum (← eval body ((k, .num (Lits.ofDec i 0)) :: env)))) m ?_ m le_rfl
  · simp only [eval, asNum, asInt, toInt_n hn, bind, Except.bind, pure,
      Except.pure, Option.bind, o1, t1, indices_succ, hb1] at hfold ⊢
    rw [hfold]
  · intro acc i hi
    have e : (Lits.ofDec ((2 : ℤ) + (i : ℤ)) 0 : α) = fin (((i + 2 : ℕ)) : ℝ) := by
      rw [show (2 : ℤ) + (i : ℤ) = ((i + 2 : ℕ) : ℤ) by push_cast; ring]
      exact ofDec_nat' (by omega)
    simp only [e, hb (i + 2) (by omega) (by omega), bind, Except.bind, pure, Except.pure, asNum]

end Eval

/-! ## The folds over values with NaN -/

/-- NaN is recognised as NaN. -/
class NaNIs (α : Type) [Scalar α] : Prop where
  isNaN_nan : isNaN (nan : α) = true

instance : NaNIs Num := ⟨rfl⟩
instance : NaNIs Bin64 := ⟨rfl⟩

section Folds

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

theorem fmin_nan_left (b : α) : fmin nan b = nan := by simp [fmin, NaNIs.isNaN_nan]
theorem fmax_nan_left (b : α) : fmax nan b = nan := by simp [fmax, NaNIs.isNaN_nan]

theorem fmin_nan_right (a : α) : fmin a nan = nan := by
  rcases RealNaN.cases a with rfl | ⟨r, rfl⟩
  · exact fmin_nan_left _
  · simp [fmin, NaNIs.isNaN_nan, ExprLaws.isNaN_fin]

theorem fmax_nan_right (a : α) : fmax a nan = nan := by
  rcases RealNaN.cases a with rfl | ⟨r, rfl⟩
  · exact fmax_nan_left _
  · simp [fmax, NaNIs.isNaN_nan, ExprLaws.isNaN_fin]

/-- One NaN candidate makes the fold NaN (both folds). -/
theorem foldR_nan (f : α → α → α) (hl : ∀ b, f nan b = nan) (hr : ∀ a, f a nan = nan)
    (g : ℕ → α) : ∀ m, (∃ i, 1 ≤ i ∧ i ≤ m + 1 ∧ g i = nan) → foldR f g m = nan := by
  intro m
  induction m with
  | zero =>
    rintro ⟨i, h1, h2, h3⟩
    obtain rfl : i = 1 := by omega
    exact h3
  | succ m ih =>
    rintro ⟨i, h1, h2, h3⟩
    simp only [foldR]
    rcases (show i ≤ m + 1 ∨ i = m + 2 by omega) with h | rfl
    · rw [ih ⟨i, h1, h, h3⟩, hl]
    · rw [h3, hr]

/-- With no NaN candidate, the `min` fold is one of the candidates and at most
every one. -/
theorem foldR_min (g : ℕ → α) (r : ℕ → ℝ) :
    ∀ m, (∀ i, 1 ≤ i → i ≤ m + 1 → g i = fin (r i)) →
      ∃ j, 1 ≤ j ∧ j ≤ m + 1 ∧ foldR fmin g m = fin (r j) ∧
        ∀ i, 1 ≤ i → i ≤ m + 1 → r j ≤ r i := by
  intro m
  induction m with
  | zero =>
    intro hg
    exact ⟨1, le_rfl, le_rfl, hg 1 le_rfl le_rfl, fun i h1 h2 => by
      obtain rfl : i = 1 := by omega
      exact le_rfl⟩
  | succ m ih =>
    intro hg
    obtain ⟨j, j1, j2, hj, hmin⟩ := ih (fun i h1 h2 => hg i h1 (by omega))
    simp only [foldR, hj, hg (m + 2) (by omega) le_rfl, fmin_fin]
    by_cases h : r (m + 2) < r j
    · refine ⟨m + 2, by omega, le_rfl, by rw [min_eq_right h.le], fun i h1 h2 => ?_⟩
      rcases (show i ≤ m + 1 ∨ i = m + 2 by omega) with hi | rfl
      · exact h.le.trans (hmin i h1 hi)
      · exact le_rfl
    · refine ⟨j, j1, by omega, by rw [min_eq_left (not_lt.mp h)], fun i h1 h2 => ?_⟩
      rcases (show i ≤ m + 1 ∨ i = m + 2 by omega) with hi | rfl
      · exact hmin i h1 hi
      · exact not_lt.mp h

/-- With no NaN candidate, the `max` fold is one of the candidates and at least
every one. -/
theorem foldR_max (g : ℕ → α) (r : ℕ → ℝ) :
    ∀ m, (∀ i, 1 ≤ i → i ≤ m + 1 → g i = fin (r i)) →
      ∃ j, 1 ≤ j ∧ j ≤ m + 1 ∧ foldR fmax g m = fin (r j) ∧
        ∀ i, 1 ≤ i → i ≤ m + 1 → r i ≤ r j := by
  intro m
  induction m with
  | zero =>
    intro hg
    exact ⟨1, le_rfl, le_rfl, hg 1 le_rfl le_rfl, fun i h1 h2 => by
      obtain rfl : i = 1 := by omega
      exact le_rfl⟩
  | succ m ih =>
    intro hg
    obtain ⟨j, j1, j2, hj, hmax⟩ := ih (fun i h1 h2 => hg i h1 (by omega))
    simp only [foldR, hj, hg (m + 2) (by omega) le_rfl, fmax_fin]
    by_cases h : r j < r (m + 2)
    · refine ⟨m + 2, by omega, le_rfl, by rw [max_eq_right h.le], fun i h1 h2 => ?_⟩
      rcases (show i ≤ m + 1 ∨ i = m + 2 by omega) with hi | rfl
      · exact (hmax i h1 hi).trans h.le
      · exact le_rfl
    · refine ⟨j, j1, by omega, by rw [max_eq_left (not_lt.mp h)], fun i h1 h2 => ?_⟩
      rcases (show i ≤ m + 1 ∨ i = m + 2 by omega) with hi | rfl
      · exact hmax i h1 hi
      · exact not_lt.mp h

/-- The `min` fold of `ifelse(P k, k, N)` over `[1, m + 1]`, `N` above every
index: the first index where `P` holds, or `N` if there is none. -/
theorem foldR_first (P : ℕ → Bool) (N : ℕ) :
    ∀ m, m + 1 < N →
      ((∃ i, 1 ≤ i ∧ i ≤ m + 1 ∧ P i = true) →
        ∃ j, 1 ≤ j ∧ j ≤ m + 1 ∧ P j = true ∧ (∀ i, 1 ≤ i → i < j → P i = false) ∧
          foldR fmin (fun i => if P i then (fin (i : ℝ) : α) else fin (N : ℝ)) m = fin (j : ℝ)) ∧
      ((∀ i, 1 ≤ i → i ≤ m + 1 → P i = false) →
          foldR fmin (fun i => if P i then (fin (i : ℝ) : α) else fin (N : ℝ)) m = fin (N : ℝ)) := by
  intro m
  induction m with
  | zero =>
    intro _
    refine ⟨fun ⟨i, h1, h2, h3⟩ => ?_, fun h => ?_⟩
    · obtain rfl : i = 1 := by omega
      exact ⟨1, le_rfl, le_rfl, h3, fun i h1 h2 => by omega, by simp [foldR, h3]⟩
    · simp [foldR, h 1 le_rfl le_rfl]
  | succ m ih =>
    intro hN
    obtain ⟨ihA, ihB⟩ := ih (by omega)
    by_cases hex : ∃ i, 1 ≤ i ∧ i ≤ m + 1 ∧ P i = true
    · obtain ⟨j, j1, j2, hj, hfirst, hfold⟩ := ihA hex
      have hlast : (if P (m + 2) then (fin ((m + 2 : ℕ) : ℝ) : α) else fin (N : ℝ)) =
          fin (if P (m + 2) then ((m + 2 : ℕ) : ℝ) else (N : ℝ)) := by split <;> rfl
      have hle : (j : ℝ) ≤ (if P (m + 2) then ((m + 2 : ℕ) : ℝ) else (N : ℝ)) := by
        split
        · exact_mod_cast (show j ≤ m + 2 by omega)
        · exact_mod_cast (show j ≤ N by omega)
      refine ⟨fun _ => ⟨j, j1, by omega, hj, hfirst, ?_⟩, fun h => absurd (h j j1 (by omega)) (by simp [hj])⟩
      simp only [foldR, hfold, hlast, fmin_fin, min_eq_left hle]
    · have hno : ∀ i, 1 ≤ i → i ≤ m + 1 → P i = false := by
        intro i h1 h2; by_contra hc; exact hex ⟨i, h1, h2, by simpa using hc⟩
      have hfold := ihB hno
      refine ⟨fun ⟨i, h1, h2, h3⟩ => ?_, fun h => ?_⟩
      · have hi : i = m + 2 := by
          by_contra hc; rw [hno i h1 (by omega)] at h3; exact absurd h3 (by simp)
        subst hi
        refine ⟨m + 2, by omega, le_rfl, h3, fun i h1 h2 => hno i h1 (by omega), ?_⟩
        have : ((m + 2 : ℕ) : ℝ) ≤ (N : ℝ) := by exact_mod_cast (show m + 2 ≤ N by omega)
        simp only [foldR, hfold, h3, ↓reduceIte, fmin_fin, min_eq_right this]
      · simp only [foldR, hfold, h (m + 2) (by omega) le_rfl, Bool.false_eq_true, ↓reduceIte,
          fmin_fin, min_self]

end Folds

/-! ## The two templates -/

section Templates

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

theorem op_eq' : Op.ofString "==" = .strict .eq := rfl
theorem op_ne' : Op.ofString "!=" = .strict .ne := rfl
theorem op_or' : Op.ofString "or" = .strict .or := rfl
theorem op_and' : Op.ofString "and" = .strict .and := rfl

/-- The selection test at candidate `j`, with candidate value `u` and reduced
value `M`. -/
def sel (u M : α) : Bool :=
  (le u M && le M u) || (!(le u u && le u u) && !(le M M && le M M))

/-- The outer body at one candidate. -/
theorem ev_body {k red : String} {F : Ast} {n : ℕ} {env : Env α} {u M : α} {j : ℕ}
    (hn : n + 1 ≤ 2 ^ 53)
    (hF : eval F ((k, .num (fin (j : ℝ))) :: env) = .ok (.num u))
    (hM : eval (innerA k red F n) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num M)) :
    eval (.node "ifelse" [testA k red F n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
        ((k, .num (fin (j : ℝ))) :: env) =
      .ok (.num (if sel u M then fin (j : ℝ) else fin ((n + 1 : ℕ) : ℝ))) := by
  set e : Env α := (k, .num (fin (j : ℝ))) :: env
  have heq := ev_bin (env := e) op_eq' hF hM
  have hne1 := ev_bin (env := e) op_ne' hF hF
  have hne2 := ev_bin (env := e) op_ne' hM hM
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map] at heq hne1 hne2
  have hand := ev_bin (env := e) op_and' hne1 hne2
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
    truthy_ofBool] at hand
  have hor := ev_bin (env := e) op_or' heq hand
  simp only [applyStrict, asNum, bind, Except.bind, pure, Except.pure, Except.map,
    truthy_ofBool] at hor
  unfold testA
  rw [ev_ifelse hor]
  have hk : eval (.var k) e = .ok (.num (fin (j : ℝ))) := ev_lookup _ (by simp [e])
  have hn1 : eval (.node "+" [.num (n : ℤ) 0, .num 1 0]) e = .ok (.num (fin ((n + 1 : ℕ) : ℝ) : α)) := by
    rw [ev_add (ev_nat e (n := n) (by omega)) (ev_lit1 e), add_nat hn]
  unfold sel
  split <;> assumption

/-- **argmin.** For a candidate expression `F` over `k_argmin_1` whose value at
candidate `j ∈ [1, n]` is `v j` (with or without an outer binding of the same
symbol), the expanded template evaluates to an index `j ∈ [1, n]`: the first
NaN candidate if there is one, else the smallest index of a minimum. -/
theorem argmin_template (F : Ast) (n : ℕ) (hn1 : 1 ≤ n) (hn : n + 1 ≤ 2 ^ 53) (env : Env α)
    (v : ℕ → α)
    (hf : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval F (("k_argmin_1", .num (fin (j : ℝ))) :: env) = .ok (.num (v j)) ∧
      ∀ w : Val α, eval F (("k_argmin_1", .num (fin (j : ℝ))) :: ("k_argmin_1", w) :: env) =
        .ok (.num (v j))) :
    ∃ j : ℕ, evalApply Esm.Lib.Relational.argmin [("f", F), ("n", .num (n : ℤ) 0)] env =
        .ok (.num (fin (j : ℝ))) ∧ 1 ≤ j ∧ j ≤ n ∧
      ((∃ i, 1 ≤ i ∧ i ≤ n ∧ v i = nan) → v j = nan ∧ ∀ i, 1 ≤ i → i < j → v i ≠ nan) ∧
      ((∀ i, 1 ≤ i → i ≤ n → v i ≠ nan) →
        (∀ i, 1 ≤ i → i ≤ n → le (v j) (v i) = true) ∧
        (∀ i, 1 ≤ i → i < j → lt (v j) (v i) = true)) := by
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  set k := "k_argmin_1"
  set M := foldR fmin v m
  have hM : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 →
      eval (innerA k "min" F (m + 1)) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num M) := by
    intro j h1 h2
    exact ev_faq_min (by omega) v (fun i i1 i2 => (hf i i1 i2).2 _)
  have hbody : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 →
      eval (.node "ifelse" [testA k "min" F (m + 1), .var k,
          .node "+" [.num ((m + 1 : ℕ) : ℤ) 0, .num 1 0]]) ((k, .num (fin (j : ℝ))) :: env) =
        .ok (.num (if sel (v j) M then fin (j : ℝ) else fin ((m + 1 + 1 : ℕ) : ℝ))) :=
    fun j h1 h2 => ev_body hn (hf j h1 h2).1 (hM j h1 h2)
  have hev := ev_faq_min (k := k) (args := []) (env := env) (m := m) (by omega) _ hbody
  have hres : ∀ j : ℕ, foldR fmin (fun j => if sel (v j) M then (fin (j : ℝ) : α)
      else fin ((m + 1 + 1 : ℕ) : ℝ)) m = fin (j : ℝ) →
      evalApply Esm.Lib.Relational.argmin [("f", F), ("n", .num ((m + 1 : ℕ) : ℤ) 0)] env =
        .ok (.num (fin (j : ℝ))) := by
    intro j hj
    unfold evalApply
    rw [expand_argmin]
    simp only [argA]
    rw [hev, hj]
  obtain ⟨hA, -⟩ := foldR_first (α := α) (fun j => sel (v j) M) (m + 1 + 1) m (by omega)
  by_cases hnan : ∃ i, 1 ≤ i ∧ i ≤ m + 1 ∧ v i = nan
  · -- `M` is NaN; the test holds exactly at the NaN candidates.
    have hMn : M = nan := foldR_nan fmin fmin_nan_left fmin_nan_right v m hnan
    have hsel : ∀ j, sel (v j) M = isNaN (v j) := by
      intro j
      rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;>
        simp [sel, hMn, h, RealNaN.nan_le, RealNaN.le_nan, NaNIs.isNaN_nan, ExprLaws.isNaN_fin,
          RealNaN.le_fin]
    have hnan' : ∀ j, isNaN (v j) = true ↔ v j = nan := by
      intro j
      rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;> rw [h]
      · simp [NaNIs.isNaN_nan]
      · simp only [ExprLaws.isNaN_fin, Bool.false_eq_true, false_iff]
        intro hc
        rcases RealNaN.cases (fin r : α) with h' | h'
        · have := ExprLaws.isNaN_fin (α := α) r; rw [hc, NaNIs.isNaN_nan] at this
          exact absurd this (by simp)
        · have := ExprLaws.isNaN_fin (α := α) r; rw [hc, NaNIs.isNaN_nan] at this
          exact absurd this (by simp)
    obtain ⟨i, i1, i2, hi⟩ := hnan
    obtain ⟨j, j1, j2, hj, hfirst, hfold⟩ := hA ⟨i, i1, i2, by rw [hsel, (hnan' i).mpr hi]⟩
    refine ⟨j, hres j hfold, j1, j2, fun _ => ⟨(hnan' j).mp (by rw [← hsel]; exact hj), ?_⟩,
      fun hno => absurd hi (hno i i1 i2)⟩
    intro i h1 h2 hc
    have := hfirst i h1 h2
    rw [hsel, (hnan' i).mpr hc] at this
    exact absurd this (by simp)
  · -- No NaN: every candidate is a real; `M` is the least of them.
    have hreal : ∀ i, 1 ≤ i → i ≤ m + 1 → ∃ r, v i = fin r := by
      intro i h1 h2
      rcases RealNaN.cases (v i) with h | h
      · exact absurd ⟨i, h1, h2, h⟩ hnan
      · exact h
    choose! r hr using hreal
    obtain ⟨j0, j01, j02, hj0, hmin⟩ := foldR_min v r m hr
    have hsel : ∀ j, 1 ≤ j → j ≤ m + 1 → sel (v j) M = decide (r j = r j0) := by
      intro j h1 h2
      rw [hr j h1 h2, show M = fin (r j0) from hj0]
      simp only [sel, RealNaN.le_fin, le_refl, decide_true, Bool.and_self, Bool.not_true,
        Bool.or_false]
      by_cases h : r j = r j0
      · simp [h]
      · rcases lt_or_gt_of_ne h with h' | h'
        · simp [h, not_le.mpr h']
        · simp [h, not_le.mpr h']
    obtain ⟨j, j1, j2, hj, hfirst, hfold⟩ := hA ⟨j0, j01, j02, by rw [hsel j0 j01 j02]; simp⟩
    have hjv : r j = r j0 := by rw [hsel j j1 j2] at hj; simpa using hj
    refine ⟨j, hres j hfold, j1, j2, fun ⟨i, i1, i2, hi⟩ => absurd ⟨i, i1, i2, hi⟩ hnan,
      fun _ => ⟨fun i h1 h2 => ?_, fun i h1 h2 => ?_⟩⟩
    · rw [hr j j1 j2, hr i h1 h2, RealNaN.le_fin, hjv]; simpa using hmin i h1 h2
    · rw [hr j j1 j2, hr i h1 (by omega), RealNaN.lt_fin, hjv]
      have h3 := hfirst i h1 h2
      rw [hsel i h1 (by omega)] at h3
      have hne : r i ≠ r j0 := by simpa using h3
      simpa using lt_of_le_of_ne (hmin i h1 (by omega)) (Ne.symm hne)

/-- **argmax.** For a candidate expression `F` over `k_argmax_1` whose value at
candidate `j ∈ [1, n]` is `v j` (with or without an outer binding of the same
symbol), the expanded template evaluates to an index `j ∈ [1, n]`: the first
NaN candidate if there is one, else the smallest index of a maximum. -/
theorem argmax_template (F : Ast) (n : ℕ) (hn1 : 1 ≤ n) (hn : n + 1 ≤ 2 ^ 53) (env : Env α)
    (v : ℕ → α)
    (hf : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval F (("k_argmax_1", .num (fin (j : ℝ))) :: env) = .ok (.num (v j)) ∧
      ∀ w : Val α, eval F (("k_argmax_1", .num (fin (j : ℝ))) :: ("k_argmax_1", w) :: env) =
        .ok (.num (v j))) :
    ∃ j : ℕ, evalApply Esm.Lib.Relational.argmax [("f", F), ("n", .num (n : ℤ) 0)] env =
        .ok (.num (fin (j : ℝ))) ∧ 1 ≤ j ∧ j ≤ n ∧
      ((∃ i, 1 ≤ i ∧ i ≤ n ∧ v i = nan) → v j = nan ∧ ∀ i, 1 ≤ i → i < j → v i ≠ nan) ∧
      ((∀ i, 1 ≤ i → i ≤ n → v i ≠ nan) →
        (∀ i, 1 ≤ i → i ≤ n → le (v i) (v j) = true) ∧
        (∀ i, 1 ≤ i → i < j → lt (v i) (v j) = true)) := by
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  set k := "k_argmax_1"
  set M := foldR fmax v m
  have hM : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 →
      eval (innerA k "max" F (m + 1)) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num M) := by
    intro j h1 h2
    exact ev_faq_max (by omega) v (fun i i1 i2 => (hf i i1 i2).2 _)
  have hbody : ∀ j : ℕ, 1 ≤ j → j ≤ m + 1 →
      eval (.node "ifelse" [testA k "max" F (m + 1), .var k,
          .node "+" [.num ((m + 1 : ℕ) : ℤ) 0, .num 1 0]]) ((k, .num (fin (j : ℝ))) :: env) =
        .ok (.num (if sel (v j) M then fin (j : ℝ) else fin ((m + 1 + 1 : ℕ) : ℝ))) :=
    fun j h1 h2 => ev_body hn (hf j h1 h2).1 (hM j h1 h2)
  have hev := ev_faq_min (k := k) (args := []) (env := env) (m := m) (by omega) _ hbody
  have hres : ∀ j : ℕ, foldR fmin (fun j => if sel (v j) M then (fin (j : ℝ) : α)
      else fin ((m + 1 + 1 : ℕ) : ℝ)) m = fin (j : ℝ) →
      evalApply Esm.Lib.Relational.argmax [("f", F), ("n", .num ((m + 1 : ℕ) : ℤ) 0)] env =
        .ok (.num (fin (j : ℝ))) := by
    intro j hj
    unfold evalApply
    rw [expand_argmax]
    simp only [argA]
    rw [hev, hj]
  obtain ⟨hA, -⟩ := foldR_first (α := α) (fun j => sel (v j) M) (m + 1 + 1) m (by omega)
  by_cases hnan : ∃ i, 1 ≤ i ∧ i ≤ m + 1 ∧ v i = nan
  · -- `M` is NaN; the test holds exactly at the NaN candidates.
    have hMn : M = nan := foldR_nan fmax fmax_nan_left fmax_nan_right v m hnan
    have hsel : ∀ j, sel (v j) M = isNaN (v j) := by
      intro j
      rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;>
        simp [sel, hMn, h, RealNaN.nan_le, RealNaN.le_nan, NaNIs.isNaN_nan, ExprLaws.isNaN_fin,
          RealNaN.le_fin]
    have hnan' : ∀ j, isNaN (v j) = true ↔ v j = nan := by
      intro j
      rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;> rw [h]
      · simp [NaNIs.isNaN_nan]
      · simp only [ExprLaws.isNaN_fin, Bool.false_eq_true, false_iff]
        intro hc
        rcases RealNaN.cases (fin r : α) with h' | h'
        · have := ExprLaws.isNaN_fin (α := α) r; rw [hc, NaNIs.isNaN_nan] at this
          exact absurd this (by simp)
        · have := ExprLaws.isNaN_fin (α := α) r; rw [hc, NaNIs.isNaN_nan] at this
          exact absurd this (by simp)
    obtain ⟨i, i1, i2, hi⟩ := hnan
    obtain ⟨j, j1, j2, hj, hfirst, hfold⟩ := hA ⟨i, i1, i2, by rw [hsel, (hnan' i).mpr hi]⟩
    refine ⟨j, hres j hfold, j1, j2, fun _ => ⟨(hnan' j).mp (by rw [← hsel]; exact hj), ?_⟩,
      fun hno => absurd hi (hno i i1 i2)⟩
    intro i h1 h2 hc
    have := hfirst i h1 h2
    rw [hsel, (hnan' i).mpr hc] at this
    exact absurd this (by simp)
  · -- No NaN: every candidate is a real; `M` is the greatest of them.
    have hreal : ∀ i, 1 ≤ i → i ≤ m + 1 → ∃ r, v i = fin r := by
      intro i h1 h2
      rcases RealNaN.cases (v i) with h | h
      · exact absurd ⟨i, h1, h2, h⟩ hnan
      · exact h
    choose! r hr using hreal
    obtain ⟨j0, j01, j02, hj0, hmax⟩ := foldR_max v r m hr
    have hsel : ∀ j, 1 ≤ j → j ≤ m + 1 → sel (v j) M = decide (r j = r j0) := by
      intro j h1 h2
      rw [hr j h1 h2, show M = fin (r j0) from hj0]
      simp only [sel, RealNaN.le_fin, le_refl, decide_true, Bool.and_self, Bool.not_true,
        Bool.or_false]
      by_cases h : r j = r j0
      · simp [h]
      · rcases lt_or_gt_of_ne h with h' | h'
        · simp [h, not_le.mpr h']
        · simp [h, not_le.mpr h']
    obtain ⟨j, j1, j2, hj, hfirst, hfold⟩ := hA ⟨j0, j01, j02, by rw [hsel j0 j01 j02]; simp⟩
    have hjv : r j = r j0 := by rw [hsel j j1 j2] at hj; simpa using hj
    refine ⟨j, hres j hfold, j1, j2, fun ⟨i, i1, i2, hi⟩ => absurd ⟨i, i1, i2, hi⟩ hnan,
      fun _ => ⟨fun i h1 h2 => ?_, fun i h1 h2 => ?_⟩⟩
    · rw [hr j j1 j2, hr i h1 h2, RealNaN.le_fin, hjv]; simpa using hmax i h1 h2
    · rw [hr j j1 j2, hr i h1 (by omega), RealNaN.lt_fin, hjv]
      have h3 := hfirst i h1 h2
      rw [hsel i h1 (by omega)] at h3
      have hne : r i ≠ r j0 := by simpa using h3
      simpa using lt_of_le_of_ne (hmax i h1 (by omega)) hne

end Templates

end Esm.Closed.RelationalAst
