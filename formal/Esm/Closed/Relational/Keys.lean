import Esm.Closed.Geometry.TemplateAst
import Esm.Closed.Datetime.TemplateAst

/-!
# The key, rank and gated arg-witness templates of `lib/relational.esm`

The templates that stand in for the `skolem` and `rank` value-invention ops and
for a `join`-gated arg-witness:

* `pair_key_in_range`, `pair_key_nan`: `pair_key(a, b, lo_a, lo_b, n_a, n_b)`
  is `(a − lo_a)·n_b + (b − lo_b)` when `a` and `b` are integers in
  `[lo_a, lo_a + n_a)` and `[lo_b, lo_b + n_b)` (exactly, at every type with
  the calendar's integer laws, so in binary64 too, for components below
  `2^25`), and NaN otherwise (non-integral, out of range or NaN);
* `edge_key_symm`: `edge_key(u, v, lo, n) = edge_key(v, u, lo, n)` for every
  pair of values, NaN included; `edge_key_eq_pair` gives its value as the pair
  key of `min(u, v)`, `max(u, v)`;
* `rank_of_eq_searchsorted`, `searchsorted_sorted_count`: `rank_of(x, members,
  n)` is §9.2's `interp.searchsorted(x, members)`, which on ascending real
  members is `1 + #{members < x}`;
* `argmin_where_template`, `argmax_where_template`: with the filter `p`, the
  result is `n + 1` when no candidate passes, and otherwise the index the
  unfiltered argmin / argmax theorems give, over the passing candidates only.

`rank_of_set` (the candidate range `{"from": S}`) is proven equal to `rank_of`
in `Esm/Closed/Relational/Count.lean` (`rank_of_set_eq_rank_of`).
-/

namespace Esm.Closed.RelationalAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Esm.Closed.GeometryAst
open Esm.Closed.CalendarAst Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## Laws -/

/-- NaN floors to NaN and compares false on the right of `<` too. -/
class KeyLaws (α : Type) [Scalar α] [RealNaN α] [Elem α] : Prop where
  floor_nan : Elem.floor (nan : α) = nan
  lt_nan_r : ∀ x : α, lt x nan = false

instance : KeyLaws Num := ⟨rfl, fun x => by cases x <;> rfl⟩
instance : KeyLaws Bin64 := ⟨rfl, fun x => by cases x <;> rfl⟩
instance : KeyLaws Bin64Z := ⟨rfl, fun x => by cases (x : Bin64) <;> rfl⟩
instance : NaNIs Bin64Z := ⟨rfl⟩

/-! ## `pair_key` and `edge_key` -/

/-- `ifelse(a ≥ lo_a ∧ a < lo_a + n_a ∧ b ≥ lo_b ∧ b < lo_b + n_b ∧ a = ⌊a⌋ ∧
b = ⌊b⌋, (a − lo_a)·n_b + (b − lo_b), 0 / 0)`, as the template writes it. -/
def pairA (a b la lb na nb : Ast) : Ast :=
  .node "ifelse" [
    .node "and" [.node "and" [.node "and" [.node "and" [.node "and" [
      .node ">=" [a, la], .node "<" [a, .node "+" [la, na]]], .node ">=" [b, lb]],
      .node "<" [b, .node "+" [lb, nb]]], .node "==" [a, .node "floor" [a]]],
      .node "==" [b, .node "floor" [b]]],
    .node "+" [.node "*" [.node "-" [a, la], nb], .node "-" [b, lb]],
    .node "/" [.num 0 0, .num 0 0]]

section Pair

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

/-- The guard of the pair key. -/
def pairG (x y l1 l2 m1 m2 : α) : Bool :=
  ((((le l1 x && lt x (add l1 m1)) && le l2 y) && lt y (add l2 m2)) &&
    eqR x (Elem.floor x)) && eqR y (Elem.floor y)

/-- The value of the pair key on evaluated operands. -/
def pairV (x y l1 l2 m1 m2 : α) : α :=
  if pairG x y l1 l2 m1 m2 then add (mul (sub x l1) m2) (sub y l2) else div zero zero

variable {env : Env α}

theorem ev_floorA {a : Ast} {u : α} (ha : EV env a u) :
    EV env (.node "floor" [a]) (Elem.floor u) := by
  unfold EV; rw [ev_un' op_floor ha]; rfl

theorem ev_minA {a b : Ast} {u v : α} (ha : EV env a u) (hb : EV env b v) :
    EV env (.node "min" [a, b]) (fmin u v) := by
  unfold EV; rw [ev_bin op_min ha hb]; rfl

theorem ev_pair {a b la lb na nb : Ast} {x y l1 l2 m1 m2 : α} (ha : EV env a x)
    (hb : EV env b y) (h1 : EV env la l1) (h2 : EV env lb l2) (h3 : EV env na m1)
    (h4 : EV env nb m2) : EV env (pairA a b la lb na nb) (pairV x y l1 l2 m1 m2) :=
  ev_iteA (ev_andA (ev_andA (ev_andA (ev_andA (ev_andA (ev_geA ha h1)
      (ev_ltA ha (ev_addA h1 h3))) (ev_geA hb h2)) (ev_ltA hb (ev_addA h2 h4)))
      (ev_eqA ha (ev_floorA ha))) (ev_eqA hb (ev_floorA hb)))
    (ev_addA (ev_mulA (ev_subA ha h1) h4) (ev_subA hb h2)) (ev_divA ev_zero' ev_zero')

end Pair

def bindPK : Bindings :=
  [("a", .var "A"), ("b", .var "B"), ("lo_a", .var "LA"), ("lo_b", .var "LB"),
   ("n_a", .var "NA"), ("n_b", .var "NB")]

theorem expand_pair_key :
    expand Esm.Lib.Relational.pair_key bindPK =
      .ok (pairA (.var "A") (.var "B") (.var "LA") (.var "LB") (.var "NA") (.var "NB")) := rfl

def bindEK : Bindings := [("u", .var "U"), ("v", .var "V"), ("lo", .var "L"), ("n", .var "N")]

def bindEK' : Bindings := [("u", .var "V"), ("v", .var "U"), ("lo", .var "L"), ("n", .var "N")]

theorem expand_edge_key :
    expand Esm.Lib.Relational.edge_key bindEK =
      .ok (pairA (.node "min" [.var "U", .var "V"]) (.node "max" [.var "U", .var "V"])
        (.var "L") (.var "L") (.var "N") (.var "N")) := rfl

theorem expand_edge_key' :
    expand Esm.Lib.Relational.edge_key bindEK' =
      .ok (pairA (.node "min" [.var "V", .var "U"]) (.node "max" [.var "V", .var "U"])
        (.var "L") (.var "L") (.var "N") (.var "N")) := rfl

section PairThms

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [CalLaws α]

/-- The environment of the `pair_key` theorems. -/
abbrev envPK (x y : α) (la lb na nb : ℤ) : Env α :=
  [("A", .num x), ("B", .num y), ("LA", .num (fin (la : ℝ))), ("LB", .num (fin (lb : ℝ))),
   ("NA", .num (fin (na : ℝ))), ("NB", .num (fin (nb : ℝ)))]

omit [CalLaws α] in
theorem evalApply_eq {t : Template} {σ : Bindings} {a : Ast} {env : Env α} {v : α}
    (he : expand t σ = .ok a) (hv : EV env a v) : evalApply t σ env = .ok (.num v) := by
  unfold evalApply; rw [he]; simp only []; rw [hv]

omit [CalLaws α] in
theorem ev_pk (x y : α) (la lb na nb : ℤ) :
    EV (envPK x y la lb na nb)
      (pairA (.var "A") (.var "B") (.var "LA") (.var "LB") (.var "NA") (.var "NB"))
      (pairV x y (fin (la : ℝ)) (fin (lb : ℝ)) (fin (na : ℝ)) (fin (nb : ℝ))) :=
  ev_pair (ev_lookup _ rfl) (ev_lookup _ rfl) (ev_lookup _ rfl) (ev_lookup _ rfl)
    (ev_lookup _ rfl) (ev_lookup _ rfl)

theorem eqR_floor (r : ℝ) : eqR (fin r : α) (fin (⌊r⌋ : ℝ)) = decide (r = (⌊r⌋ : ℝ)) := by
  by_cases h : r = (⌊r⌋ : ℝ)
  · rw [← h]; simp [eqR, le_fin]
  · have : ¬ r ≤ (⌊r⌋ : ℝ) := not_le.mpr (lt_of_le_of_ne (Int.floor_le r) (Ne.symm h))
    simp [eqR, le_fin, h, this]

/-- The guard on integer bounds, as real conditions. -/
theorem pairG_fin {r s : ℝ} {la lb na nb : ℤ} (h1 : |la| ≤ 2 ^ 25) (h2 : |lb| ≤ 2 ^ 25)
    (h3 : |na| ≤ 2 ^ 25) (h4 : |nb| ≤ 2 ^ 25) :
    pairG (fin r : α) (fin s) (fin (la : ℝ)) (fin (lb : ℝ)) (fin (na : ℝ)) (fin (nb : ℝ)) =
      decide ((((((la : ℝ) ≤ r ∧ r < ((la + na : ℤ) : ℝ)) ∧ (lb : ℝ) ≤ s) ∧
        s < ((lb + nb : ℤ) : ℝ)) ∧ r = (⌊r⌋ : ℝ)) ∧ s = (⌊s⌋ : ℝ)) := by
  obtain ⟨h1a, h1b⟩ := abs_le.mp h1
  obtain ⟨h2a, h2b⟩ := abs_le.mp h2
  obtain ⟨h3a, h3b⟩ := abs_le.mp h3
  obtain ⟨h4a, h4b⟩ := abs_le.mp h4
  have ea := ExprLaws.add_int (α := α) la na (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
  have eb := ExprLaws.add_int (α := α) lb nb (abs_le_of (by omega) (by omega))
    (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
  unfold pairG
  rw [ea, eb, CalLaws.floor_fin, CalLaws.floor_fin, eqR_floor, eqR_floor]
  simp only [le_fin, lt_fin, Bool.decide_and]

/-- **`pair_key` in range.** For integers `a ∈ [lo_a, lo_a + n_a)` and
`b ∈ [lo_b, lo_b + n_b)`, all of magnitude at most `2^25`, the template is
`(a − lo_a)·n_b + (b − lo_b)` exactly. -/
theorem pair_key_in_range {ia ib la lb na nb : ℤ} (b1 : |ia| ≤ 2 ^ 25) (b2 : |ib| ≤ 2 ^ 25)
    (b3 : |la| ≤ 2 ^ 25) (b4 : |lb| ≤ 2 ^ 25) (b5 : |na| ≤ 2 ^ 25) (b6 : |nb| ≤ 2 ^ 25)
    (ha1 : la ≤ ia) (ha2 : ia < la + na) (hb1 : lb ≤ ib) (hb2 : ib < lb + nb) :
    evalApply Esm.Lib.Relational.pair_key bindPK
        (envPK (fin (ia : ℝ) : α) (fin (ib : ℝ)) la lb na nb) =
      .ok (.num (fin (((ia - la) * nb + (ib - lb) : ℤ) : ℝ))) := by
  refine evalApply_eq expand_pair_key ?_
  obtain ⟨c1, c2⟩ := abs_le.mp b1
  obtain ⟨c3, c4⟩ := abs_le.mp b2
  obtain ⟨c5, c6⟩ := abs_le.mp b3
  obtain ⟨c7, c8⟩ := abs_le.mp b4
  obtain ⟨c9, c10⟩ := abs_le.mp b5
  obtain ⟨c11, c12⟩ := abs_le.mp b6
  have hv := ev_pk (α := α) (fin (ia : ℝ)) (fin (ib : ℝ)) la lb na nb
  have hg := pairG_fin (α := α) (r := (ia : ℝ)) (s := (ib : ℝ)) b3 b4 b5 b6
  have hgt : pairG (fin (ia : ℝ) : α) (fin (ib : ℝ)) (fin (la : ℝ)) (fin (lb : ℝ))
      (fin (na : ℝ)) (fin (nb : ℝ)) = true := by
    rw [hg]; simp only [Int.floor_intCast, decide_eq_true_eq]
    exact ⟨⟨⟨⟨⟨by exact_mod_cast ha1, by exact_mod_cast ha2⟩, by exact_mod_cast hb1⟩,
      by exact_mod_cast hb2⟩, by simp⟩, by simp⟩
  unfold pairV at hv
  rw [hgt] at hv
  simp only [↓reduceIte] at hv
  rw [ExprLaws.sub_int ia la (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
      (abs_le_of (by omega) (by omega)),
    CalLaws.mul_int (ia - la) nb (by
      have : |ia - la| ≤ 2 ^ 26 := abs_le_of (by omega) (by omega)
      rw [abs_mul]; nlinarith [abs_nonneg (ia - la), abs_nonneg nb]),
    ExprLaws.sub_int ib lb (abs_le_of (by omega) (by omega)) (abs_le_of (by omega) (by omega))
      (abs_le_of (by omega) (by omega)),
    ExprLaws.add_int _ _ (by
      have : |ia - la| ≤ 2 ^ 26 := abs_le_of (by omega) (by omega)
      rw [abs_mul]; nlinarith [abs_nonneg (ia - la), abs_nonneg nb])
      (abs_le_of (by omega) (by omega)) (by
      have : |ia - la| ≤ 2 ^ 26 := abs_le_of (by omega) (by omega)
      have : |(ia - la) * nb| ≤ 2 ^ 51 := by
        rw [abs_mul]; nlinarith [abs_nonneg (ia - la), abs_nonneg nb]
      have := abs_le.mp this
      exact abs_le_of (by omega) (by omega))] at hv
  exact hv

/-- **`pair_key` outside its domain is NaN.** If the two values are not integers
in `[lo_a, lo_a + n_a)` and `[lo_b, lo_b + n_b)` (one is NaN, non-integral or
out of range), the template is NaN wherever `0 / 0` is (`Num`, `Bin64Z`). -/
theorem pair_key_nan [KeyLaws α] [NaNIs α] [ZeroDivNaN α] {la lb na nb : ℤ}
    (b3 : |la| ≤ 2 ^ 25) (b4 : |lb| ≤ 2 ^ 25) (b5 : |na| ≤ 2 ^ 25) (b6 : |nb| ≤ 2 ^ 25)
    (x y : α)
    (hout : ¬ ∃ ia ib : ℤ, x = fin (ia : ℝ) ∧ y = fin (ib : ℝ) ∧ la ≤ ia ∧ ia < la + na ∧
      lb ≤ ib ∧ ib < lb + nb) :
    evalApply Esm.Lib.Relational.pair_key bindPK (envPK x y la lb na nb) = .ok (.num nan) := by
  refine evalApply_eq expand_pair_key ?_
  have hv := ev_pk (α := α) x y la lb na nb
  suffices hg : pairG x y (fin (la : ℝ)) (fin (lb : ℝ)) (fin (na : ℝ)) (fin (nb : ℝ)) = false by
    unfold pairV at hv
    rw [hg] at hv
    simp only [Bool.false_eq_true, ↓reduceIte] at hv
    rw [zero_eq, ZeroDivNaN.zero_div_zero] at hv
    exact hv
  rcases RealNaN.cases x with rfl | ⟨r, rfl⟩
  · simp [pairG, RealNaN.le_nan]
  rcases RealNaN.cases y with rfl | ⟨s, rfl⟩
  · simp [pairG, RealNaN.le_nan]
  rw [pairG_fin b3 b4 b5 b6, decide_eq_false_iff_not]
  rintro ⟨⟨⟨⟨⟨a1, a2⟩, a3⟩, a4⟩, a5⟩, a6⟩
  refine hout ⟨⌊r⌋, ⌊s⌋, by rw [← a5], by rw [← a6], ?_, ?_, ?_, ?_⟩
  · rw [a5] at a1; exact_mod_cast a1
  · rw [a5] at a2; exact_mod_cast a2
  · rw [a6] at a3; exact_mod_cast a3
  · rw [a6] at a4; exact_mod_cast a4

end PairThms

section Edge

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

theorem fmin_comm' (a b : α) : fmin a b = fmin b a := by
  rcases RealNaN.cases a with rfl | ⟨r, rfl⟩
  · rw [fmin_nan_left, fmin_nan_right]
  rcases RealNaN.cases b with rfl | ⟨s, rfl⟩
  · rw [fmin_nan_left, fmin_nan_right]
  rw [fmin_fin, fmin_fin, min_comm]

theorem fmax_comm' (a b : α) : fmax a b = fmax b a := by
  rcases RealNaN.cases a with rfl | ⟨r, rfl⟩
  · rw [fmax_nan_left, fmax_nan_right]
  rcases RealNaN.cases b with rfl | ⟨s, rfl⟩
  · rw [fmax_nan_left, fmax_nan_right]
  rw [fmax_fin, fmax_fin, max_comm]

abbrev envEK (x y l m : α) : Env α := [("U", .num x), ("V", .num y), ("L", .num l), ("N", .num m)]

/-- `edge_key` is the pair key of `min(u, v)` and `max(u, v)`. -/
theorem edge_key_eq_pair (x y l m : α) :
    evalApply Esm.Lib.Relational.edge_key bindEK (envEK x y l m) =
      .ok (.num (pairV (fmin x y) (fmax x y) l l m m)) := by
  refine evalApply_eq expand_edge_key ?_
  have hU : EV (envEK x y l m) (.var "U") x := ev_lookup _ rfl
  have hV : EV (envEK x y l m) (.var "V") y := ev_lookup _ rfl
  have hL : EV (envEK x y l m) (.var "L") l := ev_lookup _ rfl
  have hN : EV (envEK x y l m) (.var "N") m := ev_lookup _ rfl
  exact ev_pair (ev_minA hU hV) (ev_maxA hU hV) hL hL hN hN

/-- **`edge_key` is symmetric**: swapping `u` and `v` gives the same value, for
every pair of values (NaN included). -/
theorem edge_key_symm (x y l m : α) :
    evalApply Esm.Lib.Relational.edge_key bindEK (envEK x y l m) =
      evalApply Esm.Lib.Relational.edge_key bindEK' (envEK x y l m) := by
  rw [edge_key_eq_pair]
  have hU : EV (envEK x y l m) (.var "U") x := ev_lookup _ rfl
  have hV : EV (envEK x y l m) (.var "V") y := ev_lookup _ rfl
  have hL : EV (envEK x y l m) (.var "L") l := ev_lookup _ rfl
  have hN : EV (envEK x y l m) (.var "N") m := ev_lookup _ rfl
  rw [evalApply_eq expand_edge_key' (ev_pair (ev_minA hV hU) (ev_maxA hV hU) hL hL hN hN),
    fmin_comm' y x, fmax_comm' y x]

end Edge

/-! ## `rank_of` -/

/-- The expansion of `rank_of`: `1 + Σ_k ifelse(members[k] ≥ x, 0, 1)`. -/
def rankA (x A n : Ast) : Ast :=
  .node "+" [.num 1 0, sumA "k_rank_of_1" n
    (.node "ifelse" [.node ">=" [ixA A [.var "k_rank_of_1"], x], .num 0 0, .num 1 0]) [A]]

theorem expand_rank_of (n : ℕ) :
    expand Esm.Lib.Relational.rank_of [("x", .var "X"), ("members", .var "A"), ("n", .num n 0)] =
      .ok (rankA (.var "X") (.var "A") (.num n 0)) := rfl

section Rank

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α]

theorem ev_rank (A : List α) (x : α) (h53 : A.length < 2 ^ 53) :
    eval (rankA (.var "X") (.var "A") (.num (A.length : ℤ) 0))
        [("A", .arr1 A), ("X", .num x)] =
      .ok (.num (fin (Template.searchsorted x A A.length : ℝ))) := by
  set env : Env α := [("A", .arr1 A), ("X", .num x)]
  have hs : eval (sumA "k_rank_of_1" (.num (A.length : ℤ) 0)
      (.node "ifelse" [.node ">=" [ixA (.var "A") [.var "k_rank_of_1"], .var "X"], .num 0 0,
        .num 1 0]) [.var "A"]) env =
      .ok (.num (fin (faqSum A.length (fun k => if le x (Template.ix A k) then 0 else 1) : ℝ))) := by
    refine ev_sum h53.le (ev_nat env h53.le) (fun j => by split <;> omega) ?_
    intro j h1 h2
    have eA : eval (.var "A") (("k_rank_of_1", Val.num (fin (j : ℝ))) :: env) = .ok (.arr1 A) :=
      ev_lookup _ rfl
    have eX : eval (.var "X") (("k_rank_of_1", Val.num (fin (j : ℝ))) :: env) = .ok (.num x) :=
      ev_lookup _ rfl
    rw [ev_ifelse (ev_ge (ev_index1 eA ev_ix_var h1 h2) eX)]
    cases le x (Template.ix A j)
    · simpa using ev_one (α := α) _
    · simpa using ev_zero (α := α) _
  have hle := faqSum_le A.length (fun k => if le x (Template.ix A k) then 0 else 1)
    (fun j => by split <;> omega)
  unfold rankA Template.searchsorted
  rw [ev_add (ev_lit1 env) hs, add_nat (by omega)]

/-- **`rank_of` is `interp.searchsorted`.** With the key bound to `X`, ascending
members bound to `A` and `n` their count, the template evaluates to §9.2's
`interp.searchsorted(x, members)` for every key, NaN included. -/
theorem rank_of_template_eq (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (h53 : a.length < 2 ^ 53)
    (x : α) :
    evalApply Esm.Lib.Relational.rank_of
        [("x", .var "X"), ("members", .var "A"), ("n", .num (a.length : ℤ) 0)]
        [("A", .arr1 (a.map fin)), ("X", .num x)] =
      .ok (.num (fin (Esm.Closed.searchsorted x (a.map fin) : ℝ))) := by
  have h := ev_rank (a.map (fin : ℝ → α)) x (by simpa using h53)
  rw [List.length_map] at h
  rw [evalApply_of (expand_rank_of a.length) h, Template.searchsorted_eq a ha x]

/-- On ascending real members, `interp.searchsorted(x, members)` is
`1 + #{members < x}`. -/
theorem searchsorted_sorted_count (a : List ℝ) (ha : a.Pairwise (· ≤ ·)) (x : ℝ) :
    Esm.Closed.searchsorted (fin x : α) (a.map fin) = 1 + (a.filter (fun b => decide (b < x))).length := by
  unfold Esm.Closed.searchsorted
  induction a with
  | nil => simp
  | cons b rest ih =>
    rw [List.pairwise_cons] at ha
    rw [List.map_cons, List.findIdx_cons, le_fin]
    by_cases h : x ≤ b
    · have hnil : rest.filter (fun c => decide (c < x)) = [] := by
        rw [List.filter_eq_nil_iff]
        intro c hc; have := ha.1 c hc; simp; linarith
      simp [h, hnil, not_lt.mpr h]
    · have hb : b < x := not_le.mp h
      simp only [h, decide_false, Bool.false_eq_true, ↓reduceIte]
      rw [List.filter_cons_of_pos (by simpa using hb), List.length_cons]
      have := ih ha.2
      omega

end Rank

/-! ## Filtered folds -/

section OptFold

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

/-- A `min` / `max` fold over the indices of a list, from no term. -/
def optFold (f : α → α → α) (g : ℕ → α) (L : List ℕ) : Option α :=
  L.foldl (fun acc j => some (match acc with | none => g j | some x => f x (g j))) none

theorem foldl_some (f : α → α → α) (g : ℕ → α) (L : List ℕ) (a : α) :
    L.foldl (fun acc j => some (match acc with | none => g j | some x => f x (g j))) (some a) =
      some (L.foldl (fun x j => f x (g j)) a) := by
  induction L generalizing a with
  | nil => rfl
  | cons j L ih => exact ih _

theorem optFold_cons (f : α → α → α) (g : ℕ → α) (j : ℕ) (L : List ℕ) :
    optFold f g (j :: L) = some (L.foldl (fun x i => f x (g i)) (g j)) :=
  foldl_some f g L (g j)

theorem optFold_snoc (f : α → α → α) (g : ℕ → α) (L : List ℕ) (j : ℕ) :
    optFold f g (L ++ [j]) =
      some (match optFold f g L with | none => g j | some x => f x (g j)) := by
  unfold optFold; rw [List.foldl_append]; rfl

theorem foldl_nan (f : α → α → α) (hl : ∀ b, f nan b = nan) (hr : ∀ a, f a nan = nan)
    (g : ℕ → α) (L : List ℕ) :
    ∀ a, (a = nan ∨ ∃ i ∈ L, g i = nan) → L.foldl (fun x i => f x (g i)) a = nan := by
  induction L with
  | nil => rintro a (h | ⟨i, hi, -⟩); exact h; simp at hi
  | cons j L ih =>
    rintro a h
    apply ih
    rcases h with rfl | ⟨i, hi, hgi⟩
    · left; exact hl _
    · rcases List.mem_cons.mp hi with rfl | hi'
      · left; show f a (g i) = nan; rw [hgi]; exact hr _
      · right; exact ⟨i, hi', hgi⟩

theorem optFold_nan (f : α → α → α) (hl : ∀ b, f nan b = nan) (hr : ∀ a, f a nan = nan)
    (g : ℕ → α) (L : List ℕ) (h : ∃ i ∈ L, g i = nan) : optFold f g L = some nan := by
  cases L with
  | nil => obtain ⟨i, hi, -⟩ := h; simp at hi
  | cons j L =>
    rw [optFold_cons]; congr 1
    obtain ⟨i, hi, hgi⟩ := h
    apply foldl_nan f hl hr g L
    rcases List.mem_cons.mp hi with rfl | hi'
    · left; exact hgi
    · right; exact ⟨i, hi', hgi⟩

/-- With real values, the `min` fold is one of them and at most every one. -/
theorem foldl_min_char (g : ℕ → α) (r : ℕ → ℝ) (L : List ℕ) :
    ∀ j0, (∀ i ∈ j0 :: L, g i = fin (r i)) →
      ∃ j ∈ j0 :: L, L.foldl (fun x i => fmin x (g i)) (g j0) = fin (r j) ∧
        ∀ i ∈ j0 :: L, r j ≤ r i := by
  induction L with
  | nil => intro j0 hg; exact ⟨j0, by simp, hg j0 (by simp), fun i hi => by simp at hi; rw [hi]⟩
  | cons i L ih =>
    intro j0 hg
    let j1 := if r i < r j0 then i else j0
    have hj1 : fmin (g j0) (g i) = g j1 := by
      rw [hg j0 (by simp), hg i (by simp), fmin_fin]
      simp only [j1]; split
      · rename_i h; rw [min_eq_right h.le, hg i (by simp)]
      · rename_i h; rw [min_eq_left (not_lt.mp h), hg j0 (by simp)]
    have hg1 : ∀ i' ∈ j1 :: L, g i' = fin (r i') := by
      intro i' hi'; apply hg
      rcases List.mem_cons.mp hi' with rfl | h
      · simp only [j1]; split <;> simp
      · simp [h]
    obtain ⟨j, hj, hv, hmin⟩ := ih j1 hg1
    refine ⟨j, ?_, by rw [List.foldl_cons, hj1]; exact hv, fun i' hi' => ?_⟩
    · rcases List.mem_cons.mp hj with rfl | h
      · simp only [j1]; split <;> simp
      · simp [h]
    · have hm := hmin j1 (by simp)
      have hj1le : r j1 ≤ r j0 ∧ r j1 ≤ r i := by
        simp only [j1]; split
        · rename_i h; exact ⟨h.le, le_rfl⟩
        · rename_i h; exact ⟨le_rfl, not_lt.mp h⟩
      rcases List.mem_cons.mp hi' with rfl | h
      · linarith [hj1le.1]
      rcases List.mem_cons.mp h with rfl | h
      · linarith [hj1le.2]
      · exact hmin i' (by simp [h])

/-- With real values, the `max` fold is one of them and at least every one. -/
theorem foldl_max_char (g : ℕ → α) (r : ℕ → ℝ) (L : List ℕ) :
    ∀ j0, (∀ i ∈ j0 :: L, g i = fin (r i)) →
      ∃ j ∈ j0 :: L, L.foldl (fun x i => fmax x (g i)) (g j0) = fin (r j) ∧
        ∀ i ∈ j0 :: L, r i ≤ r j := by
  induction L with
  | nil => intro j0 hg; exact ⟨j0, by simp, hg j0 (by simp), fun i hi => by simp at hi; rw [hi]⟩
  | cons i L ih =>
    intro j0 hg
    let j1 := if r j0 < r i then i else j0
    have hj1 : fmax (g j0) (g i) = g j1 := by
      rw [hg j0 (by simp), hg i (by simp), fmax_fin]
      simp only [j1]; split
      · rename_i h; rw [max_eq_right h.le, hg i (by simp)]
      · rename_i h; rw [max_eq_left (not_lt.mp h), hg j0 (by simp)]
    have hg1 : ∀ i' ∈ j1 :: L, g i' = fin (r i') := by
      intro i' hi'; apply hg
      rcases List.mem_cons.mp hi' with rfl | h
      · simp only [j1]; split <;> simp
      · simp [h]
    obtain ⟨j, hj, hv, hmax⟩ := ih j1 hg1
    refine ⟨j, ?_, by rw [List.foldl_cons, hj1]; exact hv, fun i' hi' => ?_⟩
    · rcases List.mem_cons.mp hj with rfl | h
      · simp only [j1]; split <;> simp
      · simp [h]
    · have hm := hmax j1 (by simp)
      have hj1le : r j0 ≤ r j1 ∧ r i ≤ r j1 := by
        simp only [j1]; split
        · rename_i h; exact ⟨h.le, le_rfl⟩
        · rename_i h; exact ⟨le_rfl, not_lt.mp h⟩
      rcases List.mem_cons.mp hi' with rfl | h
      · linarith [hj1le.1]
      rcases List.mem_cons.mp h with rfl | h
      · linarith [hj1le.2]
      · exact hmax i' (by simp [h])

theorem optFold_min (g : ℕ → α) (r : ℕ → ℝ) (L : List ℕ) (hne : L ≠ [])
    (hg : ∀ i ∈ L, g i = fin (r i)) :
    ∃ j ∈ L, optFold fmin g L = some (fin (r j)) ∧ ∀ i ∈ L, r j ≤ r i := by
  cases L with
  | nil => exact absurd rfl hne
  | cons j0 L =>
    obtain ⟨j, hj, hv, hm⟩ := foldl_min_char g r L j0 hg
    exact ⟨j, hj, by rw [optFold_cons, hv], hm⟩

theorem optFold_max (g : ℕ → α) (r : ℕ → ℝ) (L : List ℕ) (hne : L ≠ [])
    (hg : ∀ i ∈ L, g i = fin (r i)) :
    ∃ j ∈ L, optFold fmax g L = some (fin (r j)) ∧ ∀ i ∈ L, r i ≤ r j := by
  cases L with
  | nil => exact absurd rfl hne
  | cons j0 L =>
    obtain ⟨j, hj, hv, hm⟩ := foldl_max_char g r L j0 hg
    exact ⟨j, hj, by rw [optFold_cons, hv], hm⟩

/-- The `min` fold of `ifelse(Q k, k, N)` over a non-empty list of indices below
`N`: the least index where `Q` holds, or `N` if there is none. -/
theorem optFold_first (L : List ℕ) (Q : ℕ → Bool) (N : ℕ) (hN : ∀ i ∈ L, i < N) (hne : L ≠ []) :
    ∃ t : ℕ, optFold fmin (fun i => if Q i then (fin (i : ℝ) : α) else fin (N : ℝ)) L =
        some (fin (t : ℝ)) ∧
      ((∃ i ∈ L, Q i = true) → t ∈ L ∧ Q t = true ∧ ∀ i ∈ L, i < t → Q i = false) ∧
      ((∀ i ∈ L, Q i = false) → t = N) := by
  obtain ⟨j, hj, hv, hm⟩ := optFold_min (α := α)
    (fun i => if Q i then (fin (i : ℝ) : α) else fin (N : ℝ)) (fun i => if Q i then (i : ℝ) else N)
    L hne (fun i _ => by by_cases h : Q i = true <;> simp [h])
  have hval : (if Q j then (j : ℝ) else (N : ℝ)) = ((if Q j then j else N : ℕ) : ℝ) := by
    split <;> rfl
  refine ⟨if Q j then j else N, by rw [hv, hval], fun ⟨i0, hi0, hq0⟩ => ?_,
    fun hno => by rw [hno j hj]; rfl⟩
  have h0 := hm i0 hi0
  simp only [hq0, ↓reduceIte] at h0
  by_cases hqj : Q j = true
  · simp only [hqj, ↓reduceIte] at h0 ⊢
    refine ⟨hj, by simp, fun i hi hlt => ?_⟩
    by_contra hc
    have := hm i hi
    simp only [Bool.not_eq_false] at hc
    simp only [hc, hqj, ↓reduceIte] at this
    have : (j : ℝ) ≤ i := this
    exact absurd (by exact_mod_cast this : j ≤ i) (by omega)
  · simp only [hqj, Bool.false_eq_true, ↓reduceIte] at h0
    have := hN i0 hi0
    have : (N : ℝ) ≤ i0 := h0
    exact absurd (by exact_mod_cast this : N ≤ i0) (by omega)

end OptFold

/-! ## `argmin_where` and `argmax_where` -/

/-- The candidates in `[1, n]` that pass the filter. -/
def passL (Pb : ℕ → Bool) (n : ℕ) : List ℕ := ((List.range n).map (· + 1)).filter Pb

theorem mem_passL {Pb : ℕ → Bool} {n i : ℕ} : i ∈ passL Pb n ↔ 1 ≤ i ∧ i ≤ n ∧ Pb i = true := by
  unfold passL
  simp only [List.mem_filter, List.mem_map, List.mem_range]
  constructor
  · rintro ⟨⟨a, ha, rfl⟩, hp⟩; exact ⟨by omega, by omega, hp⟩
  · rintro ⟨h1, h2, hp⟩; exact ⟨⟨i - 1, by omega, by omega⟩, hp⟩

theorem passL_succ (Pb : ℕ → Bool) (m : ℕ) :
    passL Pb (m + 1) = passL Pb m ++ (if Pb (m + 1) then [m + 1] else []) := by
  unfold passL
  rw [List.range_succ, List.map_append, List.filter_append]
  congr 1
  simp only [List.map_cons, List.map_nil, List.filter_cons, List.filter_nil]

/-- The filtered reduction's argument fold. -/
def innerW (k red : String) (F P : Ast) (n : ℕ) : Ast :=
  .faqWhere [] red (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P F []

def testW (k red : String) (F P : Ast) (n : ℕ) : Ast :=
  .node "or" [.node "==" [F, innerW k red F P n],
    .node "and" [.node "!=" [F, F], .node "!=" [innerW k red F P n, innerW k red F P n]]]

def argwA (k red : String) (F P : Ast) (n : ℕ) : Ast :=
  .node "min" [.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
      (.node "ifelse" [testW k red F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [],
    .node "+" [.num (n : ℤ) 0, .num 1 0]]

theorem expand_argmin_where (F P : Ast) (n : ℕ) :
    expand Esm.Lib.Relational.argmin_where [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] =
      .ok (argwA "k_argmin_where_1" "min" F P n) := rfl

theorem expand_argmax_where (F P : Ast) (n : ℕ) :
    expand Esm.Lib.Relational.argmax_where [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] =
      .ok (argwA "k_argmax_where_1" "max" F P n) := rfl

section Where

variable {α : Type} [Scalar α] [RealNaN α] [Lits α] [Elem α] [ExprLaws α] [NaNIs α]

theorem foldlM_opt (f : α → α → α) (Pb : ℕ → Bool) (g : ℕ → α) (n : ℕ)
    (step : Option α → ℤ → Except EvalError (Option α))
    (hstep : ∀ acc (i : ℕ), i < n → step acc ((1 : ℤ) + i) =
      .ok (if Pb (i + 1) then some (match acc with | none => g (i + 1) | some x => f x (g (i + 1)))
        else acc)) :
    ∀ m, m ≤ n → ((List.range m).map (fun i : ℕ => (1 : ℤ) + i)).foldlM step none =
      .ok (optFold f g (passL Pb m)) := by
  intro m
  induction m with
  | zero => intro _; rfl
  | succ m ih =>
    intro hm
    rw [List.range_succ, List.map_append, List.foldlM_append, ih (by omega)]
    simp only [List.map_cons, List.map_nil, List.foldlM_cons, List.foldlM_nil, bind,
      Except.bind, hstep _ m (by omega), pure, Except.pure, passL_succ]
    split
    · rw [optFold_snoc]
    · rw [List.append_nil]

/-- A filtered `min` reduction: the fold over the passing candidates, or `+∞`
when none passes. -/
theorem ev_faqw_min {k : String} {P body : Ast} {args : List Ast} {env : Env α} {n : ℕ}
    (hn : n ≤ 2 ^ 53) (Pb : ℕ → Bool) (g : ℕ → α)
    (hp : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval P ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (ofBool (Pb j))))
    (hb : ∀ j : ℕ, 1 ≤ j → j ≤ n → Pb j = true →
      eval body ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (g j))) :
    eval (.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P body args) env =
      .ok (match optFold fmin g (passL Pb n) with | none => .inf false | some x => .num x) := by
  have o1 : (Lits.ofDec (1 : ℤ) 0 : α) = fin 1 := by
    simpa using ofDec_nat' (α := α) (j := 1) (by norm_num)
  have t1 : Lits.toInt? (fin 1 : α) = some 1 := by
    simpa using toInt_nat (α := α) 1
  have hi : indices 1 (n : ℤ) = (List.range n).map (fun i : ℕ => (1 : ℤ) + (i : ℤ)) := by
    simp [indices]
  simp only [eval, asNum, asInt, o1, t1, toInt_n hn, bind, Except.bind, pure, Except.pure,
    Option.bind, hi]
  rw [foldlM_opt fmin Pb g n _ ?_ n le_rfl]
  · simp only [show ¬ (("min" : String) = "+") from by decide, ↓reduceIte]
    cases optFold _ g (passL Pb n) <;> rfl
  · intro acc i hi'
    have e : (Lits.ofDec ((1 : ℤ) + (i : ℤ)) 0 : α) = fin (((i + 1 : ℕ)) : ℝ) := by
      rw [show (1 : ℤ) + (i : ℤ) = ((i + 1 : ℕ) : ℤ) by push_cast; ring]
      exact ofDec_nat' (by omega)
    simp only [e, hp (i + 1) (by omega) (by omega), truthy_ofBool]
    cases hP : Pb (i + 1)
    · simp
    · simp only [↓reduceIte, hb (i + 1) (by omega) (by omega) hP]
      cases acc <;> simp

/-- A filtered `max` reduction: the fold over the passing candidates, or `-∞`
when none passes. -/
theorem ev_faqw_max {k : String} {P body : Ast} {args : List Ast} {env : Env α} {n : ℕ}
    (hn : n ≤ 2 ^ 53) (Pb : ℕ → Bool) (g : ℕ → α)
    (hp : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval P ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (ofBool (Pb j))))
    (hb : ∀ j : ℕ, 1 ≤ j → j ≤ n → Pb j = true →
      eval body ((k, .num (fin (j : ℝ))) :: env) = .ok (.num (g j))) :
    eval (.faqWhere [] "max" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P body args) env =
      .ok (match optFold fmax g (passL Pb n) with | none => .inf true | some x => .num x) := by
  have o1 : (Lits.ofDec (1 : ℤ) 0 : α) = fin 1 := by
    simpa using ofDec_nat' (α := α) (j := 1) (by norm_num)
  have t1 : Lits.toInt? (fin 1 : α) = some 1 := by
    simpa using toInt_nat (α := α) 1
  have hi : indices 1 (n : ℤ) = (List.range n).map (fun i : ℕ => (1 : ℤ) + (i : ℤ)) := by
    simp [indices]
  simp only [eval, asNum, asInt, o1, t1, toInt_n hn, bind, Except.bind, pure, Except.pure,
    Option.bind, hi]
  rw [foldlM_opt fmax Pb g n _ ?_ n le_rfl]
  · simp only [show ¬ (("max" : String) = "+") from by decide, show ¬ (("max" : String) = "min") from by decide, ↓reduceIte]
    cases optFold _ g (passL Pb n) <;> rfl
  · intro acc i hi'
    have e : (Lits.ofDec ((1 : ℤ) + (i : ℤ)) 0 : α) = fin (((i + 1 : ℕ)) : ℝ) := by
      rw [show (1 : ℤ) + (i : ℤ) = ((i + 1 : ℕ) : ℤ) by push_cast; ring]
      exact ofDec_nat' (by omega)
    simp only [e, hp (i + 1) (by omega) (by omega), truthy_ofBool]
    cases hP : Pb (i + 1)
    · simp
    · simp only [↓reduceIte, hb (i + 1) (by omega) (by omega) hP]
      cases acc <;> simp

theorem ev_bodyW {k red : String} {F P : Ast} {n : ℕ} {env : Env α} {u M : α} {j : ℕ}
    (hn : n + 1 ≤ 2 ^ 53)
    (hF : eval F ((k, .num (fin (j : ℝ))) :: env) = .ok (.num u))
    (hM : eval (innerW k red F P n) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num M)) :
    eval (.node "ifelse" [testW k red F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
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
  unfold testW
  rw [ev_ifelse hor]
  have hk : eval (.var k) e = .ok (.num (fin (j : ℝ))) := ev_lookup _ (by simp [e])
  have hn1 : eval (.node "+" [.num (n : ℤ) 0, .num 1 0]) e = .ok (.num (fin ((n + 1 : ℕ) : ℝ) : α)) := by
    rw [ev_add (ev_nat e (n := n) (by omega)) (ev_lit1 e), add_nat hn]
  unfold sel
  split <;> assumption

/-- `min(+∞, x)` is `x`. -/
theorem ev_min_inf {a b : Ast} {env : Env α} {u : α} (ha : eval a env = .ok (.inf false))
    (hb : eval b env = .ok (.num u)) : eval (.node "min" [a, b]) env = .ok (.num u) := by
  simp only [eval, op_min, evalList, ha, hb, bind, Except.bind, pure, Except.pure]
  simp [hasInf, infMinMax, List.filterMapM, List.filterMapM.loop]
  rfl

theorem optFold_ne_none (f : α → α → α) (g : ℕ → α) {L : List ℕ} (h : L ≠ []) :
    ∃ m, optFold f g L = some m := by
  cases L with
  | nil => exact absurd rfl h
  | cons j L => exact ⟨_, optFold_cons f g j L⟩

theorem optFold_nil (f : α → α → α) (g : ℕ → α) : optFold f g [] = none := rfl

/-- **argmin_where.** With a candidate expression `F` over `k_argmin_where_1`
whose value at candidate `j` is `v j`, and a filter `P` whose truth value there
is `Pb j` (each whatever an outer binding of the same symbol), the template is
`n + 1` when no candidate in `[1, n]` passes; otherwise it is a passing index:
the first passing NaN candidate if one is NaN, else the smallest passing index
of a minimum over the passing candidates. -/
theorem argmin_where_template (F P : Ast) (n : ℕ) (hn : n + 1 ≤ 2 ^ 53) (env : Env α)
    (v : ℕ → α) (Pb : ℕ → Bool)
    (hf : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval F (("k_argmin_where_1", .num (fin (j : ℝ))) :: env) = .ok (.num (v j)) ∧
      ∀ w : Val α, eval F (("k_argmin_where_1", .num (fin (j : ℝ))) ::
        ("k_argmin_where_1", w) :: env) = .ok (.num (v j)))
    (hp : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval P (("k_argmin_where_1", .num (fin (j : ℝ))) :: env) = .ok (.num (ofBool (Pb j))) ∧
      ∀ w : Val α, eval P (("k_argmin_where_1", .num (fin (j : ℝ))) ::
        ("k_argmin_where_1", w) :: env) = .ok (.num (ofBool (Pb j)))) :
    ∃ j : ℕ, evalApply Esm.Lib.Relational.argmin_where
        [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] env = .ok (.num (fin (j : ℝ))) ∧
      ((∀ i, 1 ≤ i → i ≤ n → Pb i = false) → j = n + 1) ∧
      ((∃ i, 1 ≤ i ∧ i ≤ n ∧ Pb i = true) → 1 ≤ j ∧ j ≤ n ∧ Pb j = true ∧
        ((∃ i, 1 ≤ i ∧ i ≤ n ∧ Pb i = true ∧ v i = nan) →
          v j = nan ∧ ∀ i, 1 ≤ i → i < j → Pb i = true → v i ≠ nan) ∧
        ((∀ i, 1 ≤ i → i ≤ n → Pb i = true → v i ≠ nan) →
          (∀ i, 1 ≤ i → i ≤ n → Pb i = true → le (v j) (v i) = true) ∧
          (∀ i, 1 ≤ i → i < j → Pb i = true → lt (v j) (v i) = true))) := by
  set k := "k_argmin_where_1"
  set L := passL Pb n
  have hn1 : EV env (.node "+" [.num (n : ℤ) 0, .num 1 0]) (fin ((n + 1 : ℕ) : ℝ)) := by
    unfold EV; rw [ev_add (ev_nat env (n := n) (by omega)) (ev_lit1 env), add_nat hn]
  have hres : ∀ x : Val α, eval (.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
      (.node "ifelse" [testW k "min" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [])
      env = .ok x → ∀ u : α, eval (.node "min" [.faqWhere [] "min"
        (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
        (.node "ifelse" [testW k "min" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [],
        .node "+" [.num (n : ℤ) 0, .num 1 0]]) env = .ok (.num u) →
      evalApply Esm.Lib.Relational.argmin_where [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] env =
        .ok (.num u) := by
    intro x _ u hu
    unfold evalApply; rw [expand_argmin_where]; simp only [argwA]; rw [hu]
  by_cases hL : L = []
  · -- no candidate passes: `min(+∞, n + 1)`
    have hnone : ∀ i, 1 ≤ i → i ≤ n → Pb i = false := by
      intro i h1 h2
      by_contra hc
      have : i ∈ L := mem_passL.mpr ⟨h1, h2, by simpa using hc⟩
      rw [hL] at this; simp at this
    have hout := ev_faqw_min (k := k) (args := [])
      (body := .node "ifelse" [testW k "min" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
      (env := env) (by omega) Pb (fun _ => zero) (fun j h1 h2 => (hp j h1 h2).1)
      (fun j h1 h2 hP => by rw [hnone j h1 h2] at hP; exact absurd hP (by simp))
    rw [show passL Pb n = [] from hL, optFold_nil] at hout
    simp only at hout
    refine ⟨n + 1, hres _ hout _ (ev_min_inf hout hn1), fun _ => rfl, fun ⟨i, h1, h2, hi⟩ => ?_⟩
    rw [hnone i h1 h2] at hi; exact absurd hi (by simp)
  · obtain ⟨m, hm⟩ := optFold_ne_none fmin v hL
    have hM : ∀ j : ℕ, 1 ≤ j → j ≤ n →
        eval (innerW k "min" F P n) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num m) := by
      intro j h1 h2
      have := ev_faqw_min (k := k) (args := []) (body := F) (P := P)
        (env := (k, .num (fin (j : ℝ))) :: env) (by omega) Pb v
        (fun i i1 i2 => (hp i i1 i2).2 _) (fun i i1 i2 _ => (hf i i1 i2).2 _)
      rw [hm] at this; simp only at this; exact this
    set w : ℕ → α := fun j => if sel (v j) m then fin (j : ℝ) else fin ((n + 1 : ℕ) : ℝ)
    have hout := ev_faqw_min (k := k) (args := [])
      (body := .node "ifelse" [testW k "min" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
      (env := env) (by omega) Pb w (fun j h1 h2 => (hp j h1 h2).1)
      (fun j h1 h2 _ => ev_bodyW hn (hf j h1 h2).1 (hM j h1 h2))
    obtain ⟨t, ht, hfirst, -⟩ := optFold_first (α := α) L (fun j => sel (v j) m) (n + 1)
      (fun i hi => by have := mem_passL.mp hi; omega) hL
    rw [show passL Pb n = L from rfl, show optFold fmin w L = some (fin (t : ℝ)) from ht] at hout
    simp only at hout
    have hex : ∃ i ∈ L, sel (v i) m = true := by
      by_cases hnan : ∃ i ∈ L, v i = nan
      · obtain ⟨i, hi, hvi⟩ := hnan
        have hmn : m = nan := by
          have := optFold_nan fmin fmin_nan_left fmin_nan_right v L ⟨i, hi, hvi⟩
          rw [hm] at this; exact Option.some.inj this
        exact ⟨i, hi, by simp [sel, hvi, hmn, RealNaN.nan_le]⟩
      · have hreal : ∀ i ∈ L, ∃ r, v i = fin r := by
          intro i hi
          rcases RealNaN.cases (v i) with h | h
          · exact absurd ⟨i, hi, h⟩ hnan
          · exact h
        choose! r hr using hreal
        obtain ⟨j0, hj0, hv0, -⟩ := optFold_min v r L hL hr
        rw [hm] at hv0
        exact ⟨j0, hj0, by rw [Option.some.inj hv0, hr j0 hj0]; simp [sel, RealNaN.le_fin]⟩
    obtain ⟨htL, hselt, hbefore⟩ := hfirst hex
    obtain ⟨t1, t2, tP⟩ := mem_passL.mp htL
    have hfin : eval (.node "min" [.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
        (.node "ifelse" [testW k "min" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [],
        .node "+" [.num (n : ℤ) 0, .num 1 0]]) env = .ok (.num (fin (t : ℝ))) := by
      rw [ev_min hout hn1]
      congr 2
      rw [min_eq_left (by exact_mod_cast (show t ≤ n + 1 by omega))]
    refine ⟨t, hres _ hout _ hfin, fun hno => absurd (hno t t1 t2) (by simp [tP]),
      fun _ => ⟨t1, t2, tP, ?_, ?_⟩⟩
    · rintro ⟨i, i1, i2, iP, hvi⟩
      have hiL : i ∈ L := mem_passL.mpr ⟨i1, i2, iP⟩
      have hmn : m = nan := by
        have := optFold_nan fmin fmin_nan_left fmin_nan_right v L ⟨i, hiL, hvi⟩
        rw [hm] at this; exact Option.some.inj this
      have hsel : ∀ j, sel (v j) m = isNaN (v j) := by
        intro j
        rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;>
          simp [sel, hmn, h, RealNaN.nan_le, RealNaN.le_nan, NaNIs.isNaN_nan, ExprLaws.isNaN_fin,
            RealNaN.le_fin]
      have hnan' : ∀ j, isNaN (v j) = true → v j = nan := by
        intro j hj
        rcases RealNaN.cases (v j) with h | ⟨r, h⟩
        · exact h
        · rw [h, ExprLaws.isNaN_fin] at hj; exact absurd hj (by simp)
      refine ⟨hnan' t (by rw [← hsel]; exact hselt), fun i' h1 h2 hP hc => ?_⟩
      have := hbefore i' (mem_passL.mpr ⟨h1, by omega, hP⟩) h2
      rw [hsel, hc, NaNIs.isNaN_nan] at this
      exact absurd this (by simp)
    · intro hno
      have hreal : ∀ i ∈ L, ∃ r, v i = fin r := by
        intro i hi
        obtain ⟨i1, i2, iP⟩ := mem_passL.mp hi
        rcases RealNaN.cases (v i) with h | h
        · exact absurd h (hno i i1 i2 iP)
        · exact h
      choose! r hr using hreal
      obtain ⟨j0, hj0, hv0, hmin⟩ := optFold_min v r L hL hr
      rw [hm] at hv0
      have hmv : m = fin (r j0) := Option.some.inj hv0
      have hsel : ∀ j ∈ L, sel (v j) m = decide (r j = r j0) := by
        intro j hj
        rw [hr j hj, hmv]
        simp only [sel, RealNaN.le_fin, le_refl, decide_true, Bool.and_self, Bool.not_true,
          Bool.or_false]
        by_cases h : r j = r j0
        · simp [h]
        · rcases lt_or_gt_of_ne h with h' | h'
          · simp [h, not_le.mpr h']
          · simp [h, not_le.mpr h']
      have htv : r t = r j0 := by rw [hsel t htL] at hselt; simpa using hselt
      refine ⟨fun i i1 i2 iP => ?_, fun i i1 i2 iP => ?_⟩
      · have hiL : i ∈ L := mem_passL.mpr ⟨i1, i2, iP⟩
        rw [hr t htL, hr i hiL, RealNaN.le_fin, htv]; simpa using hmin i hiL
      · have hiL : i ∈ L := mem_passL.mpr ⟨i1, by omega, iP⟩
        rw [hr t htL, hr i hiL, RealNaN.lt_fin, htv]
        have h3 := hbefore i hiL i2
        rw [hsel i hiL] at h3
        have hne : r i ≠ r j0 := by simpa using h3
        simpa using lt_of_le_of_ne (hmin i hiL) (Ne.symm hne)

/-- **argmax_where.** With a candidate expression `F` over `k_argmax_where_1`
whose value at candidate `j` is `v j`, and a filter `P` whose truth value there
is `Pb j` (each whatever an outer binding of the same symbol), the template is
`n + 1` when no candidate in `[1, n]` passes; otherwise it is a passing index:
the first passing NaN candidate if one is NaN, else the smallest passing index
of a maximum over the passing candidates. -/
theorem argmax_where_template (F P : Ast) (n : ℕ) (hn : n + 1 ≤ 2 ^ 53) (env : Env α)
    (v : ℕ → α) (Pb : ℕ → Bool)
    (hf : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval F (("k_argmax_where_1", .num (fin (j : ℝ))) :: env) = .ok (.num (v j)) ∧
      ∀ w : Val α, eval F (("k_argmax_where_1", .num (fin (j : ℝ))) ::
        ("k_argmax_where_1", w) :: env) = .ok (.num (v j)))
    (hp : ∀ j : ℕ, 1 ≤ j → j ≤ n →
      eval P (("k_argmax_where_1", .num (fin (j : ℝ))) :: env) = .ok (.num (ofBool (Pb j))) ∧
      ∀ w : Val α, eval P (("k_argmax_where_1", .num (fin (j : ℝ))) ::
        ("k_argmax_where_1", w) :: env) = .ok (.num (ofBool (Pb j)))) :
    ∃ j : ℕ, evalApply Esm.Lib.Relational.argmax_where
        [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] env = .ok (.num (fin (j : ℝ))) ∧
      ((∀ i, 1 ≤ i → i ≤ n → Pb i = false) → j = n + 1) ∧
      ((∃ i, 1 ≤ i ∧ i ≤ n ∧ Pb i = true) → 1 ≤ j ∧ j ≤ n ∧ Pb j = true ∧
        ((∃ i, 1 ≤ i ∧ i ≤ n ∧ Pb i = true ∧ v i = nan) →
          v j = nan ∧ ∀ i, 1 ≤ i → i < j → Pb i = true → v i ≠ nan) ∧
        ((∀ i, 1 ≤ i → i ≤ n → Pb i = true → v i ≠ nan) →
          (∀ i, 1 ≤ i → i ≤ n → Pb i = true → le (v i) (v j) = true) ∧
          (∀ i, 1 ≤ i → i < j → Pb i = true → lt (v i) (v j) = true))) := by
  set k := "k_argmax_where_1"
  set L := passL Pb n
  have hn1 : EV env (.node "+" [.num (n : ℤ) 0, .num 1 0]) (fin ((n + 1 : ℕ) : ℝ)) := by
    unfold EV; rw [ev_add (ev_nat env (n := n) (by omega)) (ev_lit1 env), add_nat hn]
  have hres : ∀ x : Val α, eval (.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
      (.node "ifelse" [testW k "max" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [])
      env = .ok x → ∀ u : α, eval (.node "min" [.faqWhere [] "min"
        (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
        (.node "ifelse" [testW k "max" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [],
        .node "+" [.num (n : ℤ) 0, .num 1 0]]) env = .ok (.num u) →
      evalApply Esm.Lib.Relational.argmax_where [("f", F), ("p", P), ("n", .num (n : ℤ) 0)] env =
        .ok (.num u) := by
    intro x _ u hu
    unfold evalApply; rw [expand_argmax_where]; simp only [argwA]; rw [hu]
  by_cases hL : L = []
  · -- no candidate passes: `min(+∞, n + 1)`
    have hnone : ∀ i, 1 ≤ i → i ≤ n → Pb i = false := by
      intro i h1 h2
      by_contra hc
      have : i ∈ L := mem_passL.mpr ⟨h1, h2, by simpa using hc⟩
      rw [hL] at this; simp at this
    have hout := ev_faqw_min (k := k) (args := [])
      (body := .node "ifelse" [testW k "max" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
      (env := env) (by omega) Pb (fun _ => zero) (fun j h1 h2 => (hp j h1 h2).1)
      (fun j h1 h2 hP => by rw [hnone j h1 h2] at hP; exact absurd hP (by simp))
    rw [show passL Pb n = [] from hL, optFold_nil] at hout
    simp only at hout
    refine ⟨n + 1, hres _ hout _ (ev_min_inf hout hn1), fun _ => rfl, fun ⟨i, h1, h2, hi⟩ => ?_⟩
    rw [hnone i h1 h2] at hi; exact absurd hi (by simp)
  · obtain ⟨m, hm⟩ := optFold_ne_none fmax v hL
    have hM : ∀ j : ℕ, 1 ≤ j → j ≤ n →
        eval (innerW k "max" F P n) ((k, .num (fin (j : ℝ))) :: env) = .ok (.num m) := by
      intro j h1 h2
      have := ev_faqw_max (k := k) (args := []) (body := F) (P := P)
        (env := (k, .num (fin (j : ℝ))) :: env) (by omega) Pb v
        (fun i i1 i2 => (hp i i1 i2).2 _) (fun i i1 i2 _ => (hf i i1 i2).2 _)
      rw [hm] at this; simp only at this; exact this
    set w : ℕ → α := fun j => if sel (v j) m then fin (j : ℝ) else fin ((n + 1 : ℕ) : ℝ)
    have hout := ev_faqw_min (k := k) (args := [])
      (body := .node "ifelse" [testW k "max" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]])
      (env := env) (by omega) Pb w (fun j h1 h2 => (hp j h1 h2).1)
      (fun j h1 h2 _ => ev_bodyW hn (hf j h1 h2).1 (hM j h1 h2))
    obtain ⟨t, ht, hfirst, -⟩ := optFold_first (α := α) L (fun j => sel (v j) m) (n + 1)
      (fun i hi => by have := mem_passL.mp hi; omega) hL
    rw [show passL Pb n = L from rfl, show optFold fmin w L = some (fin (t : ℝ)) from ht] at hout
    simp only at hout
    have hex : ∃ i ∈ L, sel (v i) m = true := by
      by_cases hnan : ∃ i ∈ L, v i = nan
      · obtain ⟨i, hi, hvi⟩ := hnan
        have hmn : m = nan := by
          have := optFold_nan fmax fmax_nan_left fmax_nan_right v L ⟨i, hi, hvi⟩
          rw [hm] at this; exact Option.some.inj this
        exact ⟨i, hi, by simp [sel, hvi, hmn, RealNaN.nan_le]⟩
      · have hreal : ∀ i ∈ L, ∃ r, v i = fin r := by
          intro i hi
          rcases RealNaN.cases (v i) with h | h
          · exact absurd ⟨i, hi, h⟩ hnan
          · exact h
        choose! r hr using hreal
        obtain ⟨j0, hj0, hv0, -⟩ := optFold_max v r L hL hr
        rw [hm] at hv0
        exact ⟨j0, hj0, by rw [Option.some.inj hv0, hr j0 hj0]; simp [sel, RealNaN.le_fin]⟩
    obtain ⟨htL, hselt, hbefore⟩ := hfirst hex
    obtain ⟨t1, t2, tP⟩ := mem_passL.mp htL
    have hfin : eval (.node "min" [.faqWhere [] "min" (.cons k [.num 1 0, .num (n : ℤ) 0] .nil) P
        (.node "ifelse" [testW k "max" F P n, .var k, .node "+" [.num (n : ℤ) 0, .num 1 0]]) [],
        .node "+" [.num (n : ℤ) 0, .num 1 0]]) env = .ok (.num (fin (t : ℝ))) := by
      rw [ev_min hout hn1]
      congr 2
      rw [min_eq_left (by exact_mod_cast (show t ≤ n + 1 by omega))]
    refine ⟨t, hres _ hout _ hfin, fun hno => absurd (hno t t1 t2) (by simp [tP]),
      fun _ => ⟨t1, t2, tP, ?_, ?_⟩⟩
    · rintro ⟨i, i1, i2, iP, hvi⟩
      have hiL : i ∈ L := mem_passL.mpr ⟨i1, i2, iP⟩
      have hmn : m = nan := by
        have := optFold_nan fmax fmax_nan_left fmax_nan_right v L ⟨i, hiL, hvi⟩
        rw [hm] at this; exact Option.some.inj this
      have hsel : ∀ j, sel (v j) m = isNaN (v j) := by
        intro j
        rcases RealNaN.cases (v j) with h | ⟨r, h⟩ <;>
          simp [sel, hmn, h, RealNaN.nan_le, RealNaN.le_nan, NaNIs.isNaN_nan, ExprLaws.isNaN_fin,
            RealNaN.le_fin]
      have hnan' : ∀ j, isNaN (v j) = true → v j = nan := by
        intro j hj
        rcases RealNaN.cases (v j) with h | ⟨r, h⟩
        · exact h
        · rw [h, ExprLaws.isNaN_fin] at hj; exact absurd hj (by simp)
      refine ⟨hnan' t (by rw [← hsel]; exact hselt), fun i' h1 h2 hP hc => ?_⟩
      have := hbefore i' (mem_passL.mpr ⟨h1, by omega, hP⟩) h2
      rw [hsel, hc, NaNIs.isNaN_nan] at this
      exact absurd this (by simp)
    · intro hno
      have hreal : ∀ i ∈ L, ∃ r, v i = fin r := by
        intro i hi
        obtain ⟨i1, i2, iP⟩ := mem_passL.mp hi
        rcases RealNaN.cases (v i) with h | h
        · exact absurd h (hno i i1 i2 iP)
        · exact h
      choose! r hr using hreal
      obtain ⟨j0, hj0, hv0, hmax⟩ := optFold_max v r L hL hr
      rw [hm] at hv0
      have hmv : m = fin (r j0) := Option.some.inj hv0
      have hsel : ∀ j ∈ L, sel (v j) m = decide (r j = r j0) := by
        intro j hj
        rw [hr j hj, hmv]
        simp only [sel, RealNaN.le_fin, le_refl, decide_true, Bool.and_self, Bool.not_true,
          Bool.or_false]
        by_cases h : r j = r j0
        · simp [h]
        · rcases lt_or_gt_of_ne h with h' | h'
          · simp [h, not_le.mpr h']
          · simp [h, not_le.mpr h']
      have htv : r t = r j0 := by rw [hsel t htL] at hselt; simpa using hselt
      refine ⟨fun i i1 i2 iP => ?_, fun i i1 i2 iP => ?_⟩
      · have hiL : i ∈ L := mem_passL.mpr ⟨i1, i2, iP⟩
        rw [hr t htL, hr i hiL, RealNaN.le_fin, htv]; simpa using hmax i hiL
      · have hiL : i ∈ L := mem_passL.mpr ⟨i1, by omega, iP⟩
        rw [hr t htL, hr i hiL, RealNaN.lt_fin, htv]
        have h3 := hbefore i hiL i2
        rw [hsel i hiL] at h3
        have hne : r i ≠ r j0 := by simpa using h3
        simpa using lt_of_le_of_ne (hmax i hiL) hne

end Where

end Esm.Closed.RelationalAst
