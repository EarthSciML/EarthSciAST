import Esm.Closed.Relational.Keys

/-!
# The comparison count the compilers rewrite, and the searches that replace it

The native compilers recognise one `faq` shape and replace its fold by a
search (the Rust `Instr::Count`, the Julia `count_fold`): a `+` reduction
seeded at `+0.0` over one index `k`, whose body is the 0/1 indicator of a
comparison between a key `a[k]` and a query `x`,

  `faq_{k ∈ [1,n]} ifelse(a[k] REL x, 1, 0)`  or  `ifelse(a[k] REL x, 0, 1)`,

with `REL` one of `<=`, `<`, `>=`, `>`, `==`, `!=` (`countRelA`). This is the
form of `searchsorted`, `rank_of` and `rank_of_set`. The rewrites are correct
because the result is an integer, so every algorithm that computes the same
integer gives the same bits. This file proves the three facts that argument
rests on, over the expression evaluator `Esm.Expr.eval`:

* `count_fold_exact` (and `count_fold_exact_binary64`): the evaluated fold is
  exactly the natural-number count of the keys for which the indicator is 1,
  at every scalar type with exact small-integer arithmetic, so in binary64
  (every addition rounded) for up to `2^53` keys;
* `count_perm_invariant`: the count is the same for every permutation of the
  keys, which is what licenses sorting a copy of them once;
* `count_eq_search`: on keys sorted ascending, a bisection (`partitionPoint`,
  the upper bound for `<=`, the lower bound for `<`) computes the count of the
  four ordering comparisons, and the swapped-branch form is the key count
  minus it. NaN keys are set aside before sorting (`S` is a sorted copy of the
  keys that are not NaN): a NaN key satisfies none of the four comparisons, so
  it never counts in the plain form and always counts in the swapped form. A
  NaN query satisfies none of them either; the statement needs no hypothesis
  on the query, so it covers that case too.

`rank_of_set_eq_rank_of` closes the second item of the phase-4 contract: with
a `{"from": S}` range read as the dense range over the positions `1..|S|` of
an interval or derived index set (`denseFrom`), `rank_of_set(x, members, S)`
evaluates to what `rank_of(x, members, |S|)` does, which is §9.2's
`interp.searchsorted(x, members)` on ascending members.

The model has one zero (no `-0.0`), so the statement that `-0.0` and `+0.0`
compare equal is not exercised here; the search lemmas use only that `le` is
transitive and that a NaN compares false, both of which hold for IEEE
comparisons with signed zeros too.
-/

namespace Esm.Closed.CountAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Esm.Closed.RelationalAst
open Esm.Closed.CalendarAst Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## Bisection -/

section Search

variable {β : Type}

/-- Bisection for the first position in `[lo, hi)` at which `p` fails, given
that `p` holds before `lo` and fails from `hi` on. -/
def ppGo (p : β → Bool) (S : List β) (lo hi : ℕ) : ℕ :=
  if h : lo < hi then
    if (S[(lo + hi) / 2]?.map p).getD false then ppGo p S ((lo + hi) / 2 + 1) hi
    else ppGo p S lo ((lo + hi) / 2)
  else lo
termination_by hi - lo
decreasing_by all_goals omega

/-- The first position of `S` at which `p` fails, found by bisection (Rust's
`partition_point`): the upper bound for `p = (· ≤ x)`, the lower bound for
`p = (· < x)`. -/
def partitionPoint (p : β → Bool) (S : List β) : ℕ := ppGo p S 0 S.length

/-- `p` holds on a prefix of `S` and fails on the rest. -/
def PrefixClosed (p : β → Bool) (S : List β) : Prop :=
  ∀ i j (hij : i ≤ j) (hj : j < S.length), p S[j] = true → p (S[i]'(by omega)) = true

/-- `r` splits `S` into a prefix where `p` holds and a suffix where it fails. -/
def Split (p : β → Bool) (S : List β) (r : ℕ) : Prop :=
  r ≤ S.length ∧ (∀ i (h : i < S.length), i < r → p S[i] = true) ∧
    (∀ i (h : i < S.length), r ≤ i → p S[i] = false)

theorem ppGo_split (p : β → Bool) (S : List β) (hp : PrefixClosed p S) :
    ∀ d lo hi, hi - lo = d → lo ≤ hi → hi ≤ S.length →
      (∀ i (h : i < S.length), i < lo → p S[i] = true) →
      (∀ i (h : i < S.length), hi ≤ i → p S[i] = false) →
      Split p S (ppGo p S lo hi) := by
  intro d
  induction d using Nat.strong_induction_on with
  | _ d ih =>
  intro lo hi hd hlh hhs hlo hhi
  rw [ppGo]
  by_cases hlt : lo < hi
  · simp only [hlt, ↓reduceDIte]
    have hm : (lo + hi) / 2 < S.length := by omega
    rw [List.getElem?_eq_getElem hm]
    simp only [Option.map_some, Option.getD_some]
    by_cases hpm : p S[(lo + hi) / 2] = true
    · simp only [hpm, ↓reduceIte]
      refine ih (hi - ((lo + hi) / 2 + 1)) (by omega) _ _ rfl (by omega) hhs ?_ hhi
      intro i hi' hil
      by_cases hil' : i < lo
      · exact hlo i hi' hil'
      · exact hp i ((lo + hi) / 2) (by omega) hm hpm
    · simp only [hpm, Bool.false_eq_true, ↓reduceIte]
      refine ih ((lo + hi) / 2 - lo) (by omega) _ _ rfl (by omega) (by omega) hlo ?_
      intro i hi' hil
      by_cases hih : hi ≤ i
      · exact hhi i hi' hih
      · cases hpi : p S[i]
        · rfl
        · exact absurd (hp ((lo + hi) / 2) i hil hi' hpi) hpm
  · simp only [hlt, ↓reduceDIte]
    have e : lo = hi := by omega
    subst e
    exact ⟨hhs, hlo, hhi⟩

theorem countP_of_split {p : β → Bool} {S : List β} {r : ℕ} (h : Split p S r) :
    S.countP p = r := by
  obtain ⟨hr, h1, h2⟩ := h
  rw [← List.take_append_drop r S, List.countP_append]
  have e1 : (S.take r).countP p = r := by
    rw [List.countP_eq_length.mpr, List.length_take]
    · omega
    intro a ha
    obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ha
    rw [List.getElem_take]
    rw [List.length_take] at hi
    exact h1 i _ (by omega)
  have e2 : (S.drop r).countP p = 0 := by
    rw [List.countP_eq_zero]
    intro a ha
    obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ha
    rw [List.getElem_drop]
    rw [List.length_drop] at hi
    simp [h2 (r + i) (by omega) (by omega)]
  omega

/-- **Bisection counts.** When `p` holds on a prefix of `S`, the bisection
returns the number of elements of `S` satisfying `p`. -/
theorem partitionPoint_eq_countP (p : β → Bool) (S : List β) (hp : PrefixClosed p S) :
    partitionPoint p S = S.countP p :=
  (countP_of_split (ppGo_split p S hp _ 0 S.length rfl (Nat.zero_le _) le_rfl
    (fun _ _ h => absurd h (Nat.not_lt_zero _)) (fun i h h' => absurd h (by omega)))).symm

theorem countP_add_countP_not (p : β → Bool) (l : List β) :
    l.countP p + l.countP (fun a => !p a) = l.length := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    simp only [List.countP_cons, List.length_cons]
    cases p a <;> simp <;> omega

/-- When `p` holds on a suffix of `S` (`!p` on a prefix), the count of `p` is
the length minus the bisection point of `!p`. -/
theorem countP_suffix (p : β → Bool) (S : List β) (hp : PrefixClosed (fun a => !p a) S) :
    S.countP p = S.length - partitionPoint (fun a => !p a) S := by
  rw [partitionPoint_eq_countP _ _ hp]
  have := countP_add_countP_not p S
  omega

end Search

/-! ## Comparisons -/

/-- A NaN is not less than anything and nothing is less than a NaN. -/
class LtNaN (α : Type) [Scalar α] : Prop where
  nan_lt : ∀ x : α, lt nan x = false
  lt_nan : ∀ x : α, lt x nan = false

instance : LtNaN Num := ⟨fun x => by cases x <;> rfl, fun x => by cases x <;> rfl⟩
instance : LtNaN Bin64 := ⟨fun x => by cases x <;> rfl, fun x => by cases x <;> rfl⟩
instance : LtNaN Bin64Z := ⟨fun x => by cases (x : Bin64) <;> rfl, fun x => by cases (x : Bin64) <;> rfl⟩

theorem s_lt_le : ("<" : String) ≠ "<=" := by decide
theorem s_ge_le : (">=" : String) ≠ "<=" := by decide
theorem s_ge_lt : (">=" : String) ≠ "<" := by decide
theorem s_gt_le : (">" : String) ≠ "<=" := by decide
theorem s_gt_lt : (">" : String) ≠ "<" := by decide
theorem s_gt_ge : (">" : String) ≠ ">=" := by decide

/-- The six comparisons the count rewrite accepts. -/
def relOps : List String := ["<=", "<", ">=", ">", "==", "!="]

/-- The four ordering comparisons a search replaces. -/
def ordOps : List String := ["<=", "<", ">=", ">"]

section Cmp

variable {α : Type} [Scalar α]

/-- `a REL q` as `eval` decides it (§4.2 IEEE comparisons). -/
def relB (rel : String) (a q : α) : Bool :=
  if rel = "<=" then le a q
  else if rel = "<" then lt a q
  else if rel = ">=" then le q a
  else if rel = ">" then lt q a
  else if rel = "==" then le a q && le q a
  else !(le a q && le q a)

/-- The count of `a[k] REL x` over a sorted copy `S` of the non-NaN keys, by
bisection: the upper bound for `<=`, the lower bound for `<`, and the length
minus the bound of the negated comparison for `>=` and `>`. -/
def searchCount (rel : String) (S : List α) (q : α) : ℕ :=
  if rel = "<=" then partitionPoint (fun a => le a q) S
  else if rel = "<" then partitionPoint (fun a => lt a q) S
  else if rel = ">=" then S.length - partitionPoint (fun a => !le q a) S
  else S.length - partitionPoint (fun a => !lt q a) S

variable [RealNaN α] [LtNaN α]

theorem le_trans_b {a b c : α} (h1 : le a b = true) (h2 : le b c = true) : le a c = true := by
  rcases RealNaN.cases a with rfl | ⟨x, rfl⟩
  · rw [nan_le] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases b with rfl | ⟨y, rfl⟩
  · rw [le_nan] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases c with rfl | ⟨z, rfl⟩
  · rw [le_nan] at h2; exact absurd h2 (by simp)
  rw [le_fin] at h1 h2 ⊢
  simp only [decide_eq_true_eq] at h1 h2 ⊢
  linarith

theorem le_lt_trans_b {a b c : α} (h1 : le a b = true) (h2 : lt b c = true) : lt a c = true := by
  rcases RealNaN.cases a with rfl | ⟨x, rfl⟩
  · rw [nan_le] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases b with rfl | ⟨y, rfl⟩
  · rw [le_nan] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases c with rfl | ⟨z, rfl⟩
  · rw [LtNaN.lt_nan] at h2; exact absurd h2 (by simp)
  rw [le_fin] at h1
  rw [lt_fin] at h2 ⊢
  simp only [decide_eq_true_eq] at h1 h2 ⊢
  linarith

theorem lt_le_trans_b {a b c : α} (h1 : lt a b = true) (h2 : le b c = true) : lt a c = true := by
  rcases RealNaN.cases a with rfl | ⟨x, rfl⟩
  · rw [LtNaN.nan_lt] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases b with rfl | ⟨y, rfl⟩
  · rw [LtNaN.lt_nan] at h1; exact absurd h1 (by simp)
  rcases RealNaN.cases c with rfl | ⟨z, rfl⟩
  · rw [le_nan] at h2; exact absurd h2 (by simp)
  rw [le_fin] at h2
  rw [lt_fin] at h1 ⊢
  simp only [decide_eq_true_eq] at h1 h2 ⊢
  linarith

/-- On an ascending list, `S[i] ≤ S[j]` for `i ≤ j` (equal positions are the
same element). -/
theorem sorted_le {S : List α} (hs : S.Pairwise (fun a b => le a b = true)) {i j : ℕ}
    (hij : i ≤ j) (hj : j < S.length) {P : α → Prop} (hP : ∀ a b, le a b = true → P b → P a)
    (h : P S[j]) : P (S[i]'(by omega)) := by
  rcases Nat.lt_or_eq_of_le hij with hlt | rfl
  · exact hP _ _ (List.pairwise_iff_getElem.mp hs i j (by omega) hj hlt) h
  · exact h

theorem countP_search_sorted (rel : String) (hrel : rel ∈ ordOps) (S : List α) (q : α)
    (hs : S.Pairwise (fun a b => le a b = true)) :
    S.countP (fun a => relB rel a q) = searchCount rel S q := by
  simp only [ordOps, List.mem_cons, List.not_mem_nil, or_false] at hrel
  rcases hrel with rfl | rfl | rfl | rfl
  · simp only [relB, searchCount, ↓reduceIte]
    rw [partitionPoint_eq_countP]
    intro i j hij hj h
    exact sorted_le hs hij hj (P := fun a => le a q = true) (fun _ _ h1 h2 => le_trans_b h1 h2) h
  · simp only [relB, searchCount, s_lt_le, ↓reduceIte]
    rw [partitionPoint_eq_countP]
    intro i j hij hj h
    exact sorted_le hs hij hj (P := fun a => lt a q = true) (fun _ _ h1 h2 => le_lt_trans_b h1 h2) h
  · simp only [relB, searchCount, s_ge_le, s_ge_lt, ↓reduceIte]
    rw [countP_suffix]
    intro i j hij hj h
    refine sorted_le hs hij hj (P := fun a => (!le q a) = true) ?_ h
    intro a b hab hb
    cases hqa : le q a
    · rfl
    · simp [le_trans_b hqa hab] at hb
  · simp only [relB, searchCount, s_gt_le, s_gt_lt, s_gt_ge, ↓reduceIte]
    rw [countP_suffix]
    intro i j hij hj h
    refine sorted_le hs hij hj (P := fun a => (!lt q a) = true) ?_ h
    intro a b hab hb
    cases hqa : lt q a
    · rfl
    · simp [lt_le_trans_b hqa hab] at hb

variable [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

theorem eq_nan_of_isNaN {a : α} (h : isNaN a = true) : a = nan := by
  rcases RealNaN.cases a with rfl | ⟨x, rfl⟩
  · rfl
  · rw [ExprLaws.isNaN_fin] at h; exact absurd h (by simp)

/-- A NaN key satisfies none of the ordering comparisons (nor `==`). -/
theorem relB_nan (rel : String) (hrel : rel ∈ ordOps) (q : α) : relB rel nan q = false := by
  simp only [ordOps, List.mem_cons, List.not_mem_nil, or_false] at hrel
  rcases hrel with rfl | rfl | rfl | rfl <;> simp [relB, nan_le, le_nan, LtNaN.nan_lt, LtNaN.lt_nan]

theorem countP_filter_notNaN (P : α → Bool) (hP : P nan = false) (A : List α) :
    A.countP P = (A.filter (fun a => !isNaN a)).countP P := by
  induction A with
  | nil => rfl
  | cons a A ih =>
    by_cases ha : isNaN a = true
    · have e : a = nan := eq_nan_of_isNaN ha
      subst e
      simp [hP, ih, NaNIs.isNaN_nan]
    · simp only [Bool.not_eq_true] at ha
      simp [List.countP_cons, ih, ha]

/-- **The count is a search.** Let `S` be a copy of the keys `A` with the NaN
keys removed, sorted ascending. For each ordering comparison and every query
`q` (NaN included), the number of keys with `a REL q` is `searchCount rel S q`,
and the number without it is `|A|` minus that. -/
theorem countP_eq_search (rel : String) (hrel : rel ∈ ordOps) (A S : List α) (q : α)
    (hS : S.Perm (A.filter (fun a => !isNaN a))) (hs : S.Pairwise (fun a b => le a b = true)) :
    A.countP (fun a => relB rel a q) = searchCount rel S q ∧
      A.countP (fun a => !relB rel a q) = A.length - searchCount rel S q := by
  have h1 : A.countP (fun a => relB rel a q) = searchCount rel S q := by
    rw [countP_filter_notNaN _ (relB_nan rel hrel q), ← hS.countP_eq,
      countP_search_sorted rel hrel S q hs]
  refine ⟨h1, ?_⟩
  have := countP_add_countP_not (fun a => relB rel a q) A
  omega

end Cmp

/-! ## The count shape, evaluated -/

/-- `faq_{k ∈ [1, n]} ifelse(index(a, k) REL x, 1, 0)`, or with the branches
swapped, `ifelse(index(a, k) REL x, 0, 1)`. -/
def countRelA (rel : String) (swap : Bool) (a x : Ast) (k : String) (n : Ast) : Ast :=
  sumA k n (.node "ifelse" [.node rel [ixA a [.var k], x],
    if swap then .num 0 0 else .num 1 0, if swap then .num 1 0 else .num 0 0]) [a]

section Eval

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]
variable {env : Env α}

theorem ev_rel {rel : String} (hrel : rel ∈ relOps) {a b : Ast} {u v : α}
    (ha : eval a env = .ok (.num u)) (hb : eval b env = .ok (.num v)) :
    eval (.node rel [a, b]) env = .ok (.num (ofBool (relB rel u v))) := by
  simp only [relOps, List.mem_cons, List.not_mem_nil, or_false] at hrel
  rcases hrel with rfl | rfl | rfl | rfl | rfl | rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl
  · rw [ev_bin rfl ha hb]; simp only [relB]; rfl

/-- The template-side `faqSum` of an indicator over a list's first `n`
entries is the list count. -/
theorem faqSum_countP (A : List α) (P : α → Bool) {n : ℕ} (hn : n ≤ A.length) :
    faqSum n (fun j => if P (Template.ix A j) then 1 else 0) = (A.take n).countP P := by
  induction n with
  | zero => simp [faqSum]
  | succ n ih =>
    rw [faqSum_succ, ih (by omega), List.take_add_one, List.getElem?_eq_getElem (by omega),
      Option.toList_some, List.countP_append]
    simp only [Template.ix, Nat.add_sub_cancel, List.getD_eq_getElem _ _ (show n < A.length by omega)]
    cases h : P A[n] <;> simp [h]

/-- **The fold is the count, exactly.** For each of the six comparisons, both
branch orders, every key array `A` and query `q`, and `n ≤ |A|`, `n ≤ 2^53`
(the bound `n` may be any expression evaluating to it, a parameter included),
the evaluated `faq` is the natural number of keys among the first `n` for
which the indicator is 1 (`swap = false`: `a REL q` holds; `swap = true`: it
fails). Every partial sum is an integer at most `2^53`, so at any type with
exact small-integer arithmetic, binary64 included, no addition rounds. -/
theorem count_fold_exact (rel : String) (hrel : rel ∈ relOps) (swap : Bool)
    {axis qE nE : Ast} {k : String} {n : ℕ} {A : List α} {q : α}
    (hn : n ≤ 2 ^ 53) (hA : n ≤ A.length) (hnE : eval nE env = .ok (.num (fin (n : ℝ))))
    (hax : ∀ v, eval axis ((k, v) :: env) = .ok (.arr1 A))
    (hq : ∀ v, eval qE ((k, v) :: env) = .ok (.num q)) :
    eval (countRelA rel swap axis qE k nE) env =
      .ok (.num (fin ((A.take n).countP (fun a => relB rel a q != swap) : ℝ))) := by
  unfold countRelA
  rw [ev_sum hn hnE (f := fun j => if (relB rel (Template.ix A j) q != swap) then 1 else 0)
    (fun j => by split <;> omega), faqSum_countP A (fun a => relB rel a q != swap) hA]
  intro j h1 h2
  rw [ev_ifelse (ev_rel hrel (ev_index1 (hax _) ev_ix_var h1 (by omega)) (hq _))]
  cases relB rel (Template.ix A j) q <;> cases swap
  · simpa using ev_zero (α := α) _
  · simpa using ev_one (α := α) _
  · simpa using ev_one (α := α) _
  · simpa using ev_zero (α := α) _

/-- The environment the closed statements use: keys `A`, query `X`. -/
def cenv (A : List α) (q : α) : Env α := [("A", .arr1 A), ("X", .num q)]

theorem ev_cenv_A {k : String} (hk : k ≠ "A") (A : List α) (q : α) (v : Val α) :
    eval (.var "A") ((k, v) :: cenv A q) = .ok (.arr1 A) := by
  refine ev_lookup _ ?_
  have h1 : ("A" == k) = false := by simpa using Ne.symm hk
  simp [cenv, List.lookup, h1]

theorem ev_cenv_X {k : String} (hk : k ≠ "X") (A : List α) (q : α) (v : Val α) :
    eval (.var "X") ((k, v) :: cenv A q) = .ok (.num q) := by
  refine ev_lookup _ ?_
  have h1 : ("X" == k) = false := by simpa using Ne.symm hk
  have h2 : ("X" == "A") = false := by decide
  simp [cenv, List.lookup, h1, h2]

/-- `count_fold_exact` on the whole key array, in the closed environment. -/
theorem count_fold_cenv (rel : String) (hrel : rel ∈ relOps) (swap : Bool) (k : String)
    (hkA : k ≠ "A") (hkX : k ≠ "X") (A : List α) (q : α) (h53 : A.length ≤ 2 ^ 53) :
    eval (countRelA rel swap (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv A q) =
      .ok (.num (fin (A.countP (fun a => relB rel a q != swap) : ℝ))) := by
  have h := count_fold_exact (env := cenv A q) rel hrel swap h53 le_rfl (ev_nat _ h53)
    (ev_cenv_A hkA A q) (ev_cenv_X hkX A q)
  rwa [List.take_length] at h

/-- **The count is invariant under permuting the keys.** Evaluating the count
over any rearrangement `B` of the keys `A` gives the same value, for each of
the six comparisons and both branch orders: this is what makes sorting a copy
of the keys once, at build, exact. -/
theorem count_perm_invariant (rel : String) (hrel : rel ∈ relOps) (swap : Bool) (k : String)
    (hkA : k ≠ "A") (hkX : k ≠ "X") (A B : List α) (hAB : A.Perm B) (q : α)
    (h53 : A.length ≤ 2 ^ 53) :
    eval (countRelA rel swap (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv A q) =
      eval (countRelA rel swap (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv B q) := by
  have hl : B.length = A.length := hAB.length_eq.symm
  rw [count_fold_cenv rel hrel swap k hkA hkX A q h53]
  have := count_fold_cenv rel hrel swap k hkA hkX B q (by rw [hl]; exact h53)
  rw [hl] at this
  rw [this, hAB.countP_eq]

/-- **The evaluated count is the binary search.** For the four ordering
comparisons, every key array `A` (in any order, NaN keys allowed) and every
query `q` (NaN included): with `S` the non-NaN keys sorted ascending, the
evaluated count `faq_k ifelse(A[k] REL q, 1, 0)` is `searchCount rel S q`
(the upper bound of `q` in `S` for `<=`, the lower bound for `<`), and the
swapped-branch form `ifelse(A[k] REL q, 0, 1)` is `|A|` minus it. -/
theorem count_eq_search [LtNaN α] [NaNIs α] (rel : String) (hrel : rel ∈ ordOps)
    (k : String) (hkA : k ≠ "A") (hkX : k ≠ "X") (A S : List α) (q : α)
    (hS : S.Perm (A.filter (fun a => !isNaN a))) (hs : S.Pairwise (fun a b => le a b = true))
    (h53 : A.length ≤ 2 ^ 53) :
    eval (countRelA rel false (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv A q) =
        .ok (.num (fin (searchCount rel S q : ℝ))) ∧
      eval (countRelA rel true (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv A q) =
        .ok (.num (fin ((A.length - searchCount rel S q : ℕ) : ℝ))) := by
  have hrel' : rel ∈ relOps := by
    simp only [ordOps, List.mem_cons, List.not_mem_nil, or_false] at hrel
    simp only [relOps, List.mem_cons, List.not_mem_nil, or_false]
    tauto
  obtain ⟨e1, e2⟩ := countP_eq_search rel hrel A S q hS hs
  refine ⟨?_, ?_⟩
  · rw [count_fold_cenv rel hrel' false k hkA hkX A q h53]
    have : (fun a => relB rel a q != false) = fun a => relB rel a q := by
      funext a; cases relB rel a q <;> rfl
    rw [this, e1]
  · rw [count_fold_cenv rel hrel' true k hkA hkX A q h53]
    have : (fun a => relB rel a q != true) = fun a => !relB rel a q := by
      funext a; cases relB rel a q <;> rfl
    rw [this, e2]

end Eval

/-- `count_fold_exact` at binary64 (`Bin64`, every addition rounded to nearest
even): the evaluated `faq` is the natural-number count, exactly. -/
theorem count_fold_exact_binary64 (rel : String) (hrel : rel ∈ relOps) (swap : Bool)
    (k : String) (hkA : k ≠ "A") (hkX : k ≠ "X") (A : List Bin64) (q : Bin64)
    (h53 : A.length ≤ 2 ^ 53) :
    eval (countRelA rel swap (.var "A") (.var "X") k (.num (A.length : ℤ) 0)) (cenv A q) =
      .ok (.num (Bin64.fin (A.countP (fun a => relB rel a q != swap) : ℝ))) :=
  count_fold_cenv rel hrel swap k hkA hkX A q h53

/-! ## `rank_of_set` over a `{"from": S}` range -/

mutual

/-- Read every `{"from": S}` range whose set `sizes` knows as the dense range
`[1, |S|]` over the set's positions (an interval or derived index set; a
ragged set's `{"from": S, "of": …}` is a different form, not modelled). -/
def denseFrom (sizes : List (String × ℕ)) : Ast → Ast
  | .num m e => .num m e
  | .var s => .var s
  | .const c => .const c
  | .node op args => .node op (denseFromList sizes args)
  | .faq out red rs body args =>
    .faq out red (denseFromRanges sizes rs) (denseFrom sizes body) (denseFromList sizes args)
  | .faqWhere out red rs p body args =>
    .faqWhere out red (denseFromRanges sizes rs) (denseFrom sizes p) (denseFrom sizes body)
      (denseFromList sizes args)
  | .apply n bs => .apply n (denseFromBinds sizes bs)

def denseFromList (sizes : List (String × ℕ)) : List Ast → List Ast
  | [] => []
  | a :: as => denseFrom sizes a :: denseFromList sizes as

def denseFromRanges (sizes : List (String × ℕ)) : Ranges → Ranges
  | .nil => .nil
  | .cons k t rs => .cons k (denseFromList sizes t) (denseFromRanges sizes rs)
  | .fromSet k set rs =>
    match sizes.lookup set with
    | some n => .cons k [.num 1 0, .num (n : ℤ) 0] (denseFromRanges sizes rs)
    | none => .fromSet k set (denseFromRanges sizes rs)

def denseFromBinds (sizes : List (String × ℕ)) : Binds → Binds
  | .nil => .nil
  | .cons p v bs => .cons p (denseFrom sizes v) (denseFromBinds sizes bs)

end

/-- Expand a template, read its `from` ranges through `sizes`, evaluate. -/
def evalApplyFrom {α : Type} [Scalar α] [Lits α] [Elem α] (sizes : List (String × ℕ))
    (t : Template) (σ : Bindings) (env : Env α) : Except ApplyError (Val α) :=
  match expand t σ with
  | .error e => .error (.expand e)
  | .ok a =>
    match eval (denseFrom sizes a) env with
    | .ok v => .ok v
    | .error e => .error (.eval e)

/-- The expansion of `rank_of_set` with its `from` range read as `[1, n]`. -/
def rankSetA (n : ℕ) : Ast :=
  .node "+" [.num 1 0, sumA "k_rank_of_set_1" (.num (n : ℤ) 0)
    (.node "ifelse" [.node ">=" [ixA (.var "A") [.var "k_rank_of_set_1"], .var "X"], .num 0 0,
      .num 1 0]) [.var "A"]]

theorem expand_rank_of_set (n : ℕ) :
    (expand Esm.Lib.Relational.rank_of_set
        [("x", .var "X"), ("members", .var "A"), ("S", .var "S")]).map
      (denseFrom [("S", n)]) = .ok (rankSetA n) := rfl

section RankSet

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

theorem ev_rank_set (A : List α) (x : α) (h53 : A.length < 2 ^ 53) :
    eval (rankSetA A.length) [("A", .arr1 A), ("X", .num x)] =
      .ok (.num (fin (Template.searchsorted x A A.length : ℝ))) := by
  set env : Env α := [("A", .arr1 A), ("X", .num x)]
  have hs : eval (sumA "k_rank_of_set_1" (.num (A.length : ℤ) 0)
      (.node "ifelse" [.node ">=" [ixA (.var "A") [.var "k_rank_of_set_1"], .var "X"], .num 0 0,
        .num 1 0]) [.var "A"]) env =
      .ok (.num (fin (faqSum A.length (fun k => if le x (Template.ix A k) then 0 else 1) : ℝ))) := by
    refine ev_sum h53.le (ev_nat env h53.le) (fun j => by split <;> omega) ?_
    intro j h1 h2
    have eA : eval (.var "A") (("k_rank_of_set_1", Val.num (fin (j : ℝ))) :: env) =
        .ok (.arr1 A) := ev_lookup _ rfl
    have eX : eval (.var "X") (("k_rank_of_set_1", Val.num (fin (j : ℝ))) :: env) =
        .ok (.num x) := ev_lookup _ rfl
    rw [ev_ifelse (ev_ge (ev_index1 eA ev_ix_var h1 h2) eX)]
    cases le x (Template.ix A j)
    · simpa using ev_one (α := α) _
    · simpa using ev_zero (α := α) _
  have hle := faqSum_le A.length (fun k => if le x (Template.ix A k) then 0 else 1)
    (fun j => by split <;> omega)
  unfold rankSetA Template.searchsorted
  rw [ev_add (ev_lit1 env) hs, add_nat (by omega)]

/-- **`rank_of_set` over a set of the members' size is `rank_of`.** With the
key bound to `X`, the members to `A` and the set `S` of `|A|` positions, the
expanded `rank_of_set(x, members, S)` evaluates to exactly what
`rank_of(x, members, |A|)` does, for every key and every member array (NaN
included, any order). -/
theorem rank_of_set_eq_rank_of (A : List α) (x : α) (h53 : A.length < 2 ^ 53) :
    evalApplyFrom [("S", A.length)] Esm.Lib.Relational.rank_of_set
        [("x", .var "X"), ("members", .var "A"), ("S", .var "S")]
        [("A", .arr1 A), ("X", .num x)] =
      evalApply Esm.Lib.Relational.rank_of
        [("x", .var "X"), ("members", .var "A"), ("n", .num (A.length : ℤ) 0)]
        [("A", .arr1 A), ("X", .num x)] := by
  have e1 : expand Esm.Lib.Relational.rank_of_set
      [("x", .var "X"), ("members", .var "A"), ("S", .var "S")] =
      .ok (Esm.Expr.subst [("x", .var "X"), ("members", .var "A"), ("S", .var "S")]
        Esm.Lib.Relational.rank_of_set.body) := rfl
  have e2 : denseFrom [("S", A.length)]
      (Esm.Expr.subst [("x", .var "X"), ("members", .var "A"), ("S", .var "S")]
        Esm.Lib.Relational.rank_of_set.body) = rankSetA A.length := rfl
  unfold evalApplyFrom evalApply
  rw [e1, expand_rank_of A.length]
  dsimp only
  rw [e2, ev_rank_set A x h53, ev_rank A x h53]

/-- **`rank_of_set` is `interp.searchsorted`.** On ascending real members, the
expanded `rank_of_set(x, members, S)` with `S` the members' positions is §9.2's
`interp.searchsorted(x, members)` for every key, NaN included. -/
theorem rank_of_set_template_eq (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (h53 : a.length < 2 ^ 53)
    (x : α) :
    evalApplyFrom [("S", a.length)] Esm.Lib.Relational.rank_of_set
        [("x", .var "X"), ("members", .var "A"), ("S", .var "S")]
        [("A", .arr1 (a.map fin)), ("X", .num x)] =
      .ok (.num (fin (Esm.Closed.searchsorted x (a.map fin) : ℝ))) := by
  have h := rank_of_set_eq_rank_of (a.map (fin : ℝ → α)) x (by simpa using h53)
  rw [List.length_map] at h
  rw [h]
  exact rank_of_template_eq a ha h53 x

end RankSet

end Esm.Closed.CountAst
