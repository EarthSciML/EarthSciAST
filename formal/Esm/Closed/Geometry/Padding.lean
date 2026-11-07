import Esm.Closed.Geometry.TemplateAst

/-!
# Padding a ring with a repeated vertex does not change the planar overlap

esm-spec §8.6.1 lets a polygon ring carry an explicit closing duplicate or
consecutive duplicate vertices. `lib/geometry.esm` has no deduplication step:
it relies on a zero-length edge contributing exactly nothing. This file proves
that in binary64 (`Bin64`), for the algorithm `planarRef` that the template
computes (`planar_template_eq`):

* `planar_pad_A`, `planar_pad_B`: inserting a zero-length edge into ring A
  (resp. B) — any one position of the edge sequence, the rest of the edges kept
  in order and the first vertex kept — leaves `planarRef` bit-for-bit unchanged,
  for finite coordinates;
* `pad_dup_edges`, `pad_close_edges`: a consecutive duplicate (vertex `j`
  repeated after itself) and an explicit closing duplicate (vertex 1 appended)
  are such insertions;
* `planar_template_pad_A`, `planar_template_pad_B`: the same, about the
  evaluated template.

Why it holds, operation by operation: a zero-length edge's shoelace term is
`(a·b − b·a)·… = 0` exactly, and adding `+0` to a double changes nothing; as a
half-plane it is "on the line" (its cross products and tolerance are exactly
`0`), so its candidates are `1` for `t1` and `0` for `t0`, and every other
candidate lies in `[0, 1]` in binary64 (`cand1_le_one`, `cand0_nonneg`: a
crossing parameter `c0 / (c0 − c1)` with `c0`, `c1` of opposite signs), so the
`min` and the `max` are unchanged; the orientation fans are unchanged for the
same reason as the shoelace terms.
-/

namespace Esm.Closed.GeometryAst

open Esm.Expr Esm.Closed Esm.Closed.Template Esm.Closed.TemplateAst Esm.Closed.RelationalAst
open Esm.F64 Scalar RealNaN

set_option linter.unusedSectionVars false

/-! ## Binary64 arithmetic facts -/

abbrev B := Bin64

theorem b_add (a b : ℝ) : (add (Bin64.fin a) (Bin64.fin b) : B) = Bin64.fin (fadd a b) := rfl
theorem b_sub (a b : ℝ) : (sub (Bin64.fin a) (Bin64.fin b) : B) = Bin64.fin (fsub a b) := rfl
theorem b_mul (a b : ℝ) : (mul (Bin64.fin a) (Bin64.fin b) : B) = Bin64.fin (fmul a b) := rfl
theorem b_div (a b : ℝ) : (div (Bin64.fin a) (Bin64.fin b) : B) = Bin64.fin (fdiv a b) := rfl
theorem b_abs (a : ℝ) : (Elem.abs (Bin64.fin a) : B) = Bin64.fin |a| := rfl
theorem b_neg (a : ℝ) : (Elem.neg (Bin64.fin a) : B) = Bin64.fin (-a) := rfl
theorem b_le (a b : ℝ) : (le (Bin64.fin a) (Bin64.fin b) : Bool) = decide (a ≤ b) := rfl
theorem b_lt (a b : ℝ) : (lt (Bin64.fin a) (Bin64.fin b) : Bool) = decide (a < b) := rfl

theorem b_lit (m : ℤ) (h : |m| ≤ 2 ^ 53) : (Lits.ofDec m 0 : B) = Bin64.fin m :=
  ExprLaws.ofDec_int (α := Bin64) m h

theorem b_zero : (zero : B) = Bin64.fin 0 := by
  have := b_lit 0 (by norm_num); simpa [zero] using this
theorem b_one : (one : B) = Bin64.fin 1 := by
  have := b_lit 1 (by norm_num); simpa [one] using this
theorem b_mone : (Lits.ofDec (-1) 0 : B) = Bin64.fin (-1) := by
  have := b_lit (-1) (by norm_num); simpa using this

theorem rn_zero' : rn (0 : ℝ) = 0 := rn_of_repr repr_zero
theorem rn_one' : rn (1 : ℝ) = 1 := rn_of_repr (by simpa using repr_intCast (K := ℝ) (n := 1) (by norm_num))

theorem fsub_self (a : ℝ) : fsub a a = 0 := by simp [fsub]
theorem fmul_zero' (a : ℝ) : fmul a 0 = 0 := by simp [fmul]
theorem zero_fmul' (a : ℝ) : fmul 0 a = 0 := by simp [fmul]
theorem fmul_comm' (a b : ℝ) : fmul a b = fmul b a := by simp [fmul, mul_comm]
theorem fadd_zero_of_repr {a : ℝ} (h : Repr a) : fadd a 0 = a := by simp [fadd, rn_of_repr h]
theorem fmul_one_of_repr {a : ℝ} (h : Repr a) : fmul 1 a = a := by simp [fmul, rn_of_repr h]
theorem fmul_mone_of_repr {a : ℝ} (h : Repr a) : fmul (-1) a = -a := by
  simp [fmul, rn_of_repr (repr_neg h)]

/-! ## Finite values -/

/-- A finite binary64-model value. -/
def IsF (v : B) : Prop := ∃ r, v = Bin64.fin r

/-- A vertex with finite coordinates. -/
def VF (v : V B) : Prop := IsF v.1 ∧ IsF v.2

theorem isF_fin (r : ℝ) : IsF (Bin64.fin r) := ⟨r, rfl⟩
theorem isF_add {a b : B} (ha : IsF a) (hb : IsF b) : IsF (add a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; exact ⟨_, rfl⟩
theorem isF_sub {a b : B} (ha : IsF a) (hb : IsF b) : IsF (sub a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; exact ⟨_, rfl⟩
theorem isF_mul {a b : B} (ha : IsF a) (hb : IsF b) : IsF (mul a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; exact ⟨_, rfl⟩
theorem isF_div {a b : B} (ha : IsF a) (hb : IsF b) : IsF (div a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; exact ⟨_, rfl⟩
theorem isF_abs {a : B} (ha : IsF a) : IsF (Elem.abs a) := by
  obtain ⟨x, rfl⟩ := ha; exact ⟨_, rfl⟩
theorem isF_fmin {a b : B} (ha : IsF a) (hb : IsF b) : IsF (fmin a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; rw [show (Bin64.fin x : B) = fin x from rfl,
    show (Bin64.fin y : B) = fin y from rfl, fmin_fin]; exact ⟨_, rfl⟩
theorem isF_fmax {a b : B} (ha : IsF a) (hb : IsF b) : IsF (fmax a b) := by
  obtain ⟨x, rfl⟩ := ha; obtain ⟨y, rfl⟩ := hb; rw [show (Bin64.fin x : B) = fin x from rfl,
    show (Bin64.fin y : B) = fin y from rfl, fmax_fin]; exact ⟨_, rfl⟩
theorem isF_ite {p : Bool} {a b : B} (ha : IsF a) (hb : IsF b) : IsF (if p then a else b) := by
  cases p <;> simpa
theorem isF_zero : IsF (zero : B) := by rw [b_zero]; exact isF_fin _
theorem isF_one : IsF (one : B) := by rw [b_one]; exact isF_fin _
theorem isF_lit (m : ℤ) (e : ℕ) : IsF (Lits.ofDec m e : B) := ⟨_, rfl⟩

theorem isF_foldR (f : B → B → B) (hf : ∀ a b, IsF a → IsF b → IsF (f a b)) (g : ℕ → B)
    (hg : ∀ i, IsF (g i)) : ∀ m, IsF (foldR f g m) := by
  intro m; induction m with
  | zero => exact hg 1
  | succ m ih => exact hf _ _ ih (hg _)

theorem isF_sumR (g : ℕ → B) (hg : ∀ i, IsF (g i)) : ∀ m, IsF (sumR g m) := by
  intro m; induction m with
  | zero => exact isF_zero
  | succ m ih => exact isF_add ih (hg _)

theorem isF_cross {q0 q1 p : V B} (h0 : VF q0) (h1 : VF q1) (hp : VF p) : IsF (crossR q0 q1 p) :=
  isF_sub (isF_mul (isF_sub h1.1 h0.1) (isF_sub hp.2 h0.2))
    (isF_mul (isF_sub h1.2 h0.2) (isF_sub hp.1 h0.1))

theorem isF_dot {q0 q1 p0 p1 : V B} (h0 : VF q0) (h1 : VF q1) (h2 : VF p0) (h3 : VF p1) :
    IsF (dotR q0 q1 p0 p1) :=
  isF_add (isF_mul (isF_sub h1.1 h0.1) (isF_sub h3.1 h2.1))
    (isF_mul (isF_sub h1.2 h0.2) (isF_sub h3.2 h2.2))

theorem isF_tol {p0 p1 q0 q1 : V B} (h2 : VF p0) (h3 : VF p1) (h0 : VF q0) (h1 : VF q1) :
    IsF (tolR p0 p1 q0 q1) :=
  isF_mul (isF_mul (isF_add (isF_abs (isF_sub h1.1 h0.1)) (isF_abs (isF_sub h1.2 h0.2)))
    (isF_add (isF_add (isF_add (isF_abs h2.1) (isF_abs h2.2)) (isF_add (isF_abs h3.1)
      (isF_abs h3.2))) (isF_add (isF_abs h0.1) (isF_abs h0.2)))) (isF_lit _ _)

theorem isF_ratio {a b : B} (ha : IsF a) (hb : IsF b) : IsF (ratioR a b) :=
  isF_div ha (isF_ite isF_one (isF_sub ha hb))

theorem isF_cand1 {s a b t : B} (ha : IsF a) (hb : IsF b) : IsF (cand1R s a b t) := by
  unfold cand1R
  exact isF_ite isF_one (isF_ite isF_one (isF_ite (isF_ite isF_zero (isF_ratio ha hb)) isF_one))

theorem isF_cand0 {s a b t w : B} (ha : IsF a) (hb : IsF b) (hw : IsF w) :
    IsF (cand0R s a b t w) := by
  unfold cand0R
  exact isF_ite hw (isF_ite (isF_ite isF_one (isF_ite isF_one (isF_ratio ha hb))) isF_zero)

theorem isF_sgn (f : B) : IsF (sgnR f) := by
  unfold sgnR; exact isF_ite isF_one (isF_lit _ _)

/-! ## A zero-length edge -/

theorem cross_zero_edge {q p : V B} (hq : VF q) (hp : VF p) : crossR q q p = Bin64.fin 0 := by
  obtain ⟨⟨x, hx⟩, ⟨y, hy⟩⟩ := hq
  obtain ⟨⟨u, hu⟩, ⟨w, hw⟩⟩ := hp
  obtain ⟨q1, q2⟩ := q; obtain ⟨p1, p2⟩ := p
  simp only at hx hy hu hw; subst hx hy hu hw
  simp only [crossR, b_sub, b_mul, fsub_self, zero_fmul']

theorem cross_end_twice {o u : V B} (ho : VF o) (hu : VF u) : crossR o u u = Bin64.fin 0 := by
  obtain ⟨⟨x, hx⟩, ⟨y, hy⟩⟩ := ho
  obtain ⟨⟨a, ha⟩, ⟨b, hb⟩⟩ := hu
  obtain ⟨o1, o2⟩ := o; obtain ⟨u1, u2⟩ := u
  simp only at hx hy ha hb; subst hx hy ha hb
  simp only [crossR, b_sub, b_mul]
  rw [fmul_comm' (fsub a x) (fsub b y), fsub_self]

theorem dot_zero_edge {q p0 p1 : V B} (hq : VF q) (h0 : VF p0) (h1 : VF p1) :
    dotR q q p0 p1 = Bin64.fin 0 := by
  obtain ⟨⟨x, hx⟩, ⟨y, hy⟩⟩ := hq
  obtain ⟨⟨a, ha⟩, ⟨b, hb⟩⟩ := h0
  obtain ⟨⟨c, hc⟩, ⟨d, hd⟩⟩ := h1
  obtain ⟨q1, q2⟩ := q; obtain ⟨p01, p02⟩ := p0; obtain ⟨p11, p12⟩ := p1
  simp only at hx hy ha hb hc hd; subst hx hy ha hb hc hd
  simp only [dotR, b_sub, b_mul, b_add, fsub_self, zero_fmul', fadd, add_zero, rn_zero']

theorem tol_zero_edge {p0 p1 q : V B} (h0 : VF p0) (h1 : VF p1) (hq : VF q) :
    tolR p0 p1 q q = Bin64.fin 0 := by
  obtain ⟨⟨x, hx⟩, ⟨y, hy⟩⟩ := hq
  obtain ⟨q1, q2⟩ := q
  simp only at hx hy; subst hx hy
  have hX := isF_add (isF_add (isF_add (isF_abs h0.1) (isF_abs h0.2))
    (isF_add (isF_abs h1.1) (isF_abs h1.2))) (isF_add (isF_abs (isF_fin x)) (isF_abs (isF_fin y)))
  obtain ⟨X, hXe⟩ := hX
  unfold tolR
  simp only at hXe ⊢
  rw [hXe]
  simp only [b_sub, b_abs, fsub_self, abs_zero, b_add, b_mul, fadd, add_zero, rn_zero',
    zero_fmul']
  rw [show (Lits.ofDec 1 12 : B) = Bin64.fin (rn ((1 : ℤ) / (10 : ℝ) ^ 12)) from rfl, b_mul,
    zero_fmul']

theorem onR_zero : onR (Bin64.fin 0 : B) (Bin64.fin 0) = true := by
  simp [onR, b_abs, b_le]

theorem cand1_zero_edge (s : B) : cand1R s (Bin64.fin 0) (Bin64.fin 0) (Bin64.fin 0) = one := by
  simp [cand1R, onR_zero]

theorem cand0_zero_edge (s w : B) :
    cand0R s (Bin64.fin 0) (Bin64.fin 0) (Bin64.fin 0) w = w := by
  simp [cand0R, onR_zero]

/-! ## The candidates lie in `[0, 1]` -/

/-- A finite value that is a double. -/
def IsD (v : B) : Prop := ∃ r, v = Bin64.fin r ∧ Repr r

theorem isD_sub (a b : ℝ) : IsD (sub (Bin64.fin a) (Bin64.fin b)) := ⟨_, rfl, repr_rn _⟩
theorem isD_mul (a b : ℝ) : IsD (mul (Bin64.fin a) (Bin64.fin b)) := ⟨_, rfl, repr_rn _⟩

theorem isD_cross {q0 q1 p : V B} (h0 : VF q0) (h1 : VF q1) (hp : VF p) : IsD (crossR q0 q1 p) := by
  obtain ⟨x, hx⟩ := isF_mul (isF_sub h1.1 h0.1) (isF_sub hp.2 h0.2)
  obtain ⟨y, hy⟩ := isF_mul (isF_sub h1.2 h0.2) (isF_sub hp.1 h0.1)
  unfold crossR; rw [hx, hy]; exact isD_sub _ _

/-- The tolerance is a nonnegative finite value. -/
theorem tol_nonneg {p0 p1 q0 q1 : V B} (h2 : VF p0) (h3 : VF p1) (h0 : VF q0) (h1 : VF q1) :
    ∃ t, tolR p0 p1 q0 q1 = Bin64.fin t ∧ 0 ≤ t := by
  obtain ⟨a, ha⟩ := isF_sub h1.1 h0.1
  obtain ⟨b, hb⟩ := isF_sub h1.2 h0.2
  obtain ⟨⟨x0, hx0⟩, ⟨y0, hy0⟩⟩ := h2
  obtain ⟨⟨x1, hx1⟩, ⟨y1, hy1⟩⟩ := h3
  obtain ⟨⟨x2, hx2⟩, ⟨y2, hy2⟩⟩ := h0
  unfold tolR
  rw [ha, hb, hx0, hy0, hx1, hy1, hx2, hy2]
  simp only [b_abs, b_add, b_mul]
  have hc : (Lits.ofDec 1 12 : B) = Bin64.fin (rn ((1 : ℤ) / 10 ^ 12)) := rfl
  rw [hc]
  refine ⟨_, rfl, ?_⟩
  have nn : ∀ u v : ℝ, 0 ≤ u → 0 ≤ v → 0 ≤ fadd u v := fun u v hu hv => by
    unfold fadd; rw [← rn_zero']; exact rn_mono (by linarith)
  have nm : ∀ u v : ℝ, 0 ≤ u → 0 ≤ v → 0 ≤ fmul u v := fun u v hu hv => by
    unfold fmul; rw [← rn_zero']; exact rn_mono (mul_nonneg hu hv)
  have hc0 : 0 ≤ rn ((1 : ℤ) / (10 : ℝ) ^ 12) := by
    rw [← rn_zero']; exact rn_mono (by positivity)
  exact nm _ _ (nm _ _ (nn _ _ (abs_nonneg _) (abs_nonneg _))
    (nn _ _ (nn _ _ (nn _ _ (abs_nonneg _) (abs_nonneg _)) (nn _ _ (abs_nonneg _) (abs_nonneg _)))
      (nn _ _ (abs_nonneg _) (abs_nonneg _)))) hc0

/-- A sign is `1` or `-1`. -/
theorem sgn_cases (f : B) : sgnR f = Bin64.fin 1 ∨ sgnR f = Bin64.fin (-1) := by
  unfold sgnR; split
  · exact Or.inl b_one
  · exact Or.inr b_mone

/-- `s · c` for a sign `s` and a double `c`. -/
theorem sgn_mul {s : B} (hs : s = Bin64.fin 1 ∨ s = Bin64.fin (-1)) {c : ℝ} (hc : Repr c) :
    (s = Bin64.fin 1 ∧ mul s (Bin64.fin c) = Bin64.fin c) ∨
      (s = Bin64.fin (-1) ∧ mul s (Bin64.fin c) = Bin64.fin (-c)) := by
  rcases hs with rfl | rfl
  · exact Or.inl ⟨rfl, by rw [b_mul, fmul_one_of_repr hc]⟩
  · exact Or.inr ⟨rfl, by rw [b_mul, fmul_mone_of_repr hc]⟩

/-- The crossing parameter of two doubles of strictly opposite signs is in `[0, 1]`. -/
theorem ratio_mem {a b : ℝ} (ha : Repr a) (hab : (0 < a ∧ b < 0) ∨ (a < 0 ∧ 0 < b)) :
    ∃ v, ratioR (Bin64.fin a) (Bin64.fin b) = Bin64.fin v ∧ 0 ≤ v ∧ v ≤ 1 := by
  have hne : eqR (Bin64.fin a : B) (Bin64.fin b) = false := by
    simp only [eqR, b_le, Bool.and_eq_false_iff, decide_eq_false_iff_not, not_le]
    rcases hab with ⟨h1, h2⟩ | ⟨h1, h2⟩
    · left; linarith
    · right; linarith
  unfold ratioR
  rw [hne]
  simp only [Bool.false_eq_true, ↓reduceIte, b_sub, b_div]
  refine ⟨_, rfl, ?_⟩
  rcases hab with ⟨h1, h2⟩ | ⟨h1, h2⟩
  · have hd : a ≤ fsub a b := by
      have := rn_mono (show a ≤ a - b by linarith); rwa [rn_of_repr ha] at this
    have hdpos : 0 < fsub a b := lt_of_lt_of_le h1 hd
    constructor
    · unfold fdiv; rw [← rn_zero']; exact rn_mono (div_nonneg h1.le hdpos.le)
    · unfold fdiv; rw [← rn_one']; exact rn_mono ((div_le_one hdpos).mpr hd)
  · have hd : fsub a b ≤ a := by
      have := rn_mono (show a - b ≤ a by linarith); rwa [rn_of_repr ha] at this
    have hdneg : fsub a b < 0 := lt_of_le_of_lt hd h1
    constructor
    · unfold fdiv; rw [← rn_zero']; exact rn_mono (div_nonneg_of_nonpos h1.le hdneg.le)
    · unfold fdiv; rw [← rn_one']
      exact rn_mono ((div_le_one_of_neg hdneg).mpr hd)

/-- A sign times a double, as a real product. -/
theorem sgn_mul' {sv : ℝ} (hsv : sv = 1 ∨ sv = -1) {c : ℝ} (hc : Repr c) :
    mul (Bin64.fin sv : B) (Bin64.fin c) = Bin64.fin (sv * c) := by
  rcases hsv with rfl | rfl
  · rw [b_mul, fmul_one_of_repr hc, one_mul]
  · rw [b_mul, fmul_mone_of_repr hc, neg_one_mul]

theorem sgn_val {s : B} (hs : s = Bin64.fin 1 ∨ s = Bin64.fin (-1)) :
    ∃ sv : ℝ, (sv = 1 ∨ sv = -1) ∧ s = Bin64.fin sv := by
  rcases hs with h | h
  · exact ⟨1, Or.inl rfl, h⟩
  · exact ⟨-1, Or.inr rfl, h⟩

/-- Every `t1` candidate is a finite value at most `1`. -/
theorem cand1_le_one {s : B} (hs : s = Bin64.fin 1 ∨ s = Bin64.fin (-1)) {a b t : ℝ}
    (ha : Repr a) (hb : Repr b) (ht : 0 ≤ t) :
    ∃ v, cand1R s (Bin64.fin a) (Bin64.fin b) (Bin64.fin t) = Bin64.fin v ∧ v ≤ 1 := by
  obtain ⟨sv, hsv, rfl⟩ := sgn_val hs
  unfold cand1R
  simp only [onR, ltNegR, b_abs, b_le, b_neg, sgn_mul' hsv ha, sgn_mul' hsv hb, b_lt,
    Bool.and_eq_true, decide_eq_true_eq]
  split_ifs with h1 h2 h3 h4
  · exact ⟨1, b_one, le_rfl⟩
  · exact ⟨1, b_one, le_rfl⟩
  · exact ⟨0, b_zero, by norm_num⟩
  · obtain ⟨v, hv, -, hv1⟩ := ratio_mem ha (by
      rcases hsv with rfl | rfl
      · refine Or.inl ⟨?_, by linarith⟩
        rcases abs_cases a with ⟨h, -⟩ | ⟨h, -⟩ <;> [linarith; (simp at h2; linarith)]
      · refine Or.inr ⟨?_, by linarith⟩
        simp at h2
        rcases abs_cases a with ⟨h, -⟩ | ⟨h, -⟩ <;> linarith)
    exact ⟨v, hv, hv1⟩
  · exact ⟨1, b_one, le_rfl⟩

/-- Every `t0` candidate is a finite value at least `0`, given the on-the-line
value is. -/
theorem cand0_nonneg {s : B} (hs : s = Bin64.fin 1 ∨ s = Bin64.fin (-1)) {a b t w : ℝ}
    (ha : Repr a) (hb : Repr b) (ht : 0 ≤ t) (hw : 0 ≤ w) :
    ∃ v, cand0R s (Bin64.fin a) (Bin64.fin b) (Bin64.fin t) (Bin64.fin w) = Bin64.fin v ∧
      0 ≤ v := by
  obtain ⟨sv, hsv, rfl⟩ := sgn_val hs
  unfold cand0R
  simp only [onR, ltNegR, b_abs, b_le, b_neg, sgn_mul' hsv ha, sgn_mul' hsv hb, b_lt,
    Bool.and_eq_true, decide_eq_true_eq]
  split_ifs with h1 h2 h3 h4
  · exact ⟨w, rfl, hw⟩
  · exact ⟨1, b_one, by norm_num⟩
  · exact ⟨1, b_one, by norm_num⟩
  · obtain ⟨v, hv, hv0, -⟩ := ratio_mem ha (by
      rcases hsv with rfl | rfl
      · refine Or.inr ⟨by linarith, ?_⟩
        simp at h3
        rcases abs_cases b with ⟨h, -⟩ | ⟨h, -⟩ <;> linarith
      · refine Or.inl ⟨by linarith, ?_⟩
        simp at h2 h3
        rcases abs_cases b with ⟨h, -⟩ | ⟨h, -⟩ <;> linarith)
    exact ⟨v, hv, hv0⟩
  · exact ⟨0, b_zero, le_rfl⟩

/-! ## Folds with a neutral element inserted -/

/-- `g'` is `g` with `w` inserted at position `p` (positions `1 … N` of `g'`). -/
def Ins (g g' : ℕ → B) (p N : ℕ) (w : B) : Prop :=
  (∀ i, 1 ≤ i → i < p → g' i = g i) ∧ g' p = w ∧ ∀ i, p < i → i ≤ N → g' i = g (i - 1)

theorem sumR_repr (g : ℕ → B) (n : ℕ) (hg : ∀ i, 1 ≤ i → i ≤ n → IsF (g i)) :
    ∃ r, sumR g n = Bin64.fin r ∧ Repr r := by
  induction n with
  | zero => exact ⟨0, b_zero, repr_zero⟩
  | succ n ih =>
    obtain ⟨r, hr, -⟩ := ih (fun i h1 h2 => hg i h1 (by omega))
    obtain ⟨x, hx⟩ := hg (n + 1) (by omega) le_rfl
    exact ⟨rn (r + x), by rw [sumR, hr, hx, b_add]; rfl, repr_rn _⟩

theorem sumR_ins {g g' : ℕ → B} {p n : ℕ} (hp1 : 1 ≤ p) (hp2 : p ≤ n + 1)
    (hg : ∀ i, 1 ≤ i → i ≤ n → IsF (g i)) (hI : Ins g g' p (n + 1) (Bin64.fin 0)) :
    sumR g' (n + 1) = sumR g n := by
  obtain ⟨hlo, hmid, hhi⟩ := hI
  have hpre : ∀ k, k < p → sumR g' k = sumR g k := by
    intro k
    induction k with
    | zero => intro _; rfl
    | succ k ih => intro hk; rw [sumR, sumR, ih (by omega), hlo (k + 1) (by omega) hk]
  obtain ⟨q, rfl⟩ : ∃ q, p = q + 1 := ⟨p - 1, by omega⟩
  have hat : sumR g' (q + 1) = sumR g q := by
    obtain ⟨r, hr, hrr⟩ := sumR_repr g q (fun i h1 h2 => hg i h1 (by omega))
    rw [sumR, hpre q (by omega), hmid, hr, b_add, fadd_zero_of_repr hrr]
  have hpost : ∀ d, q + 1 + d ≤ n + 1 → sumR g' (q + 1 + d) = sumR g (q + d) := by
    intro d
    induction d with
    | zero => intro _; simpa using hat
    | succ d ih =>
      intro hd
      rw [show q + 1 + (d + 1) = (q + 1 + d) + 1 by ring, sumR, ih (by omega),
        hhi _ (by omega) (by omega), show q + 1 + d + 1 - 1 = q + d + 1 by omega, ← sumR]
      rfl
  have := hpost (n - q) (by omega)
  rwa [show q + 1 + (n - q) = n + 1 by omega, show q + (n - q) = n by omega] at this

/-- The `min` fold is unchanged by inserting `1` among finite values at most `1`. -/
theorem foldR_min_ins {g g' : ℕ → B} {p m : ℕ} (hp1 : 1 ≤ p) (hp2 : p ≤ m + 2)
    (hg : ∀ i, 1 ≤ i → i ≤ m + 1 → ∃ r, g i = Bin64.fin r ∧ r ≤ 1)
    (hI : Ins g g' p (m + 2) (Bin64.fin 1)) : foldR fmin g' (m + 1) = foldR fmin g m := by
  obtain ⟨hlo, hmid, hhi⟩ := hI
  choose! r hr hr1 using hg
  obtain ⟨j0, j01, j02, hj0, hmin⟩ := foldR_min (α := Bin64) g r m hr
  let r' : ℕ → ℝ := fun i => if i < p then r i else if i = p then 1 else r (i - 1)
  have hr' : ∀ i, 1 ≤ i → i ≤ m + 1 + 1 → g' i = fin (r' i) := by
    intro i h1 h2
    simp only [r']
    split_ifs with h3 h4
    · rw [hlo i h1 h3]; exact hr i h1 (by omega)
    · subst h4; exact hmid
    · rw [hhi i (by omega) (by omega)]; exact hr (i - 1) (by omega) (by omega)
  obtain ⟨j1, j11, j12, hj1, hmin'⟩ := foldR_min (α := Bin64) g' r' (m + 1) hr'
  rw [hj1, hj0]
  congr 1
  apply le_antisymm
  · -- the new fold is at most the old minimum, which still occurs
    by_cases h : j0 < p
    · have := hmin' j0 j01 (by omega); simpa [r', h] using this
    · have := hmin' (j0 + 1) (by omega) (by omega)
      simpa [r', show ¬ (j0 + 1 < p) by omega, show j0 + 1 ≠ p by omega] using this
  · simp only [r']
    split_ifs with h3 h4
    · exact hmin j1 j11 (by omega)
    · exact hr1 j0 j01 j02
    · exact hmin (j1 - 1) (by omega) (by omega)

/-- The `max` fold is unchanged by inserting `0` among finite values at least `0`. -/
theorem foldR_max_ins {g g' : ℕ → B} {p m : ℕ} (hp1 : 1 ≤ p) (hp2 : p ≤ m + 2)
    (hg : ∀ i, 1 ≤ i → i ≤ m + 1 → ∃ r, g i = Bin64.fin r ∧ 0 ≤ r)
    (hI : Ins g g' p (m + 2) (Bin64.fin 0)) : foldR fmax g' (m + 1) = foldR fmax g m := by
  obtain ⟨hlo, hmid, hhi⟩ := hI
  choose! r hr hr1 using hg
  obtain ⟨j0, j01, j02, hj0, hmax⟩ := foldR_max (α := Bin64) g r m hr
  let r' : ℕ → ℝ := fun i => if i < p then r i else if i = p then 0 else r (i - 1)
  have hr' : ∀ i, 1 ≤ i → i ≤ m + 1 + 1 → g' i = fin (r' i) := by
    intro i h1 h2
    simp only [r']
    split_ifs with h3 h4
    · rw [hlo i h1 h3]; exact hr i h1 (by omega)
    · subst h4; exact hmid
    · rw [hhi i (by omega) (by omega)]; exact hr (i - 1) (by omega) (by omega)
  obtain ⟨j1, j11, j12, hj1, hmax'⟩ := foldR_max (α := Bin64) g' r' (m + 1) hr'
  rw [hj1, hj0]
  congr 1
  apply le_antisymm
  · simp only [r']
    split_ifs with h3 h4
    · exact hmax j1 j11 (by omega)
    · exact hr1 j0 j01 j02
    · exact hmax (j1 - 1) (by omega) (by omega)
  · by_cases h : j0 < p
    · have := hmax' j0 j01 (by omega); simpa [r', h] using this
    · have := hmax' (j0 + 1) (by omega) (by omega)
      simpa [r', show ¬ (j0 + 1 < p) by omega, show j0 + 1 ≠ p by omega] using this

/-! ## `planarRef` by edges -/

/-- An edge's `t1` against the half-planes of ring `Q`. -/
noncomputable def t1R (Q : List (List (List B))) (cq nq : ℕ) (s : B) (p0 p1 : V B) : B :=
  foldR fmin (fun j => cand1R s (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p0)
    (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p1)
    (tolR p0 p1 (vat Q cq j) (vat Q cq (nxt nq j)))) (nq - 1)

/-- An A edge's `t0` against B's half-planes. -/
noncomputable def t0AR (Q : List (List (List B))) (cq nq : ℕ) (sA sB : B) (p0 p1 : V B) : B :=
  foldR fmax (fun j => cand0R sB (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p0)
    (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p1)
    (tolR p0 p1 (vat Q cq j) (vat Q cq (nxt nq j)))
    (if lt (mul (mul sA sB) (dotR (vat Q cq j) (vat Q cq (nxt nq j)) p0 p1)) zero then one
      else zero)) (nq - 1)

/-- A B edge's `t0` against A's half-planes. -/
noncomputable def t0BR (Q : List (List (List B))) (cq nq : ℕ) (sA sB : B) (p0 p1 : V B) : B :=
  foldR fmax (fun j => cand0R sA (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p0)
    (crossR (vat Q cq j) (vat Q cq (nxt nq j)) p1)
    (tolR p0 p1 (vat Q cq j) (vat Q cq (nxt nq j)))
    (if eqR (mul (mul sB sA) (dotR (vat Q cq j) (vat Q cq (nxt nq j)) p0 p1)) zero then zero
      else one)) (nq - 1)

/-- One edge's clipped shoelace term. -/
noncomputable def termR (s t1 t0 : B) (O p0 p1 : V B) : B :=
  mul (mul (mul s (fmax zero (sub t1 t0))) (crossR O p0 p1)) (Lits.ofDec 5 1)

theorem planarRef_edges (MA MB : List (List (List B))) (ca na cb nb : ℕ) :
    planarRef MA ca na MB cb nb =
      if eqR (fanR MA ca na) zero || eqR (fanR MB cb nb) zero then zero else
        add (sumR (fun i => termR (sgnR (fanR MA ca na))
            (t1R MB cb nb (sgnR (fanR MB cb nb)) (vat MA ca i) (vat MA ca (nxt na i)))
            (t0AR MB cb nb (sgnR (fanR MA ca na)) (sgnR (fanR MB cb nb)) (vat MA ca i)
              (vat MA ca (nxt na i)))
            (vat MA ca 1) (vat MA ca i) (vat MA ca (nxt na i))) na)
          (sumR (fun i => termR (sgnR (fanR MB cb nb))
            (t1R MA ca na (sgnR (fanR MA ca na)) (vat MB cb i) (vat MB cb (nxt nb i)))
            (t0BR MA ca na (sgnR (fanR MA ca na)) (sgnR (fanR MB cb nb)) (vat MB cb i)
              (vat MB cb (nxt nb i)))
            (vat MA ca 1) (vat MB cb i) (vat MB cb (nxt nb i))) nb) := rfl

/-! ## Padding a ring -/

/-- `M'` (with `n + 1` slots) is ring `M` (`n` slots) of the same cell with a
zero-length edge inserted at edge position `p`: the first vertex is kept, edge
`p` of `M'` has equal endpoints, and every other edge of `M'` is the matching
edge of `M`, in order. -/
def PadAt (M M' : List (List (List B))) (c n p : ℕ) : Prop :=
  1 ≤ p ∧ p ≤ n + 1 ∧ vat M' c 1 = vat M c 1 ∧ vat M' c (nxt (n + 1) p) = vat M' c p ∧
    ∀ i, 1 ≤ i → i ≤ n + 1 → i ≠ p →
      vat M' c i = vat M c (if i < p then i else i - 1) ∧
        vat M' c (nxt (n + 1) i) = vat M c (nxt n (if i < p then i else i - 1))

/-- Every vertex slot of the cell has finite coordinates. -/
def AllF (M : List (List (List B))) (c n : ℕ) : Prop := ∀ i, 1 ≤ i → i ≤ n → VF (vat M c i)

theorem nxt_mem' {n j : ℕ} (h1 : 1 ≤ j) (h2 : j ≤ n) : 1 ≤ nxt n j ∧ nxt n j ≤ n := by
  unfold nxt; split <;> omega

theorem pad_r_mem {n p i : ℕ} (hp : 1 ≤ p) (hp2 : p ≤ n + 1) (h1 : 1 ≤ i) (h2 : i ≤ n + 1) (hi : i ≠ p) :
    1 ≤ (if i < p then i else i - 1) ∧ (if i < p then i else i - 1) ≤ n := by
  split <;> omega

/-- The fan of a padded ring is the fan of the ring. -/
theorem fan_pad {M M' : List (List (List B))} {c n p : ℕ} (hn : 1 ≤ n) (hP : PadAt M M' c n p)
    (hF : AllF M c n) (hF' : AllF M' c (n + 1)) : fanR M' c (n + 1) = fanR M c n := by
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  unfold fanR
  refine sumR_ins hp1 hp2 (fun i h1 h2 => ?_) ⟨fun i h1 h2 => ?_, ?_, fun i h h2 => ?_⟩
  · have := nxt_mem' h1 h2
    exact isF_cross (hF 1 le_rfl hn) (hF i h1 h2) (hF _ this.1 this.2)
  · obtain ⟨e1, e2⟩ := he i h1 (by omega) (by omega)
    simp only [h2, ↓reduceIte] at e1 e2
    dsimp only
    rw [hO, e1, e2]
  · dsimp only
    rw [hz, hO]; exact cross_end_twice (hF 1 le_rfl hn) (hF' p hp1 hp2)
  · obtain ⟨e1, e2⟩ := he i (by omega) h2 (by omega)
    simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
    dsimp only
    rw [hO, e1, e2]

theorem isF_foldR' (f : B → B → B) (hf : ∀ a b, IsF a → IsF b → IsF (f a b)) (g : ℕ → B) :
    ∀ m, (∀ i, 1 ≤ i → i ≤ m + 1 → IsF (g i)) → IsF (foldR f g m) := by
  intro m; induction m with
  | zero => intro hg; exact hg 1 le_rfl le_rfl
  | succ m ih => intro hg; exact hf _ _ (ih (fun i h1 h2 => hg i h1 (by omega))) (hg _ (by omega) le_rfl)

theorem sumR_congr {g g' : ℕ → B} {n : ℕ} (h : ∀ i, 1 ≤ i → i ≤ n → g i = g' i) :
    sumR g n = sumR g' n := by
  induction n with
  | zero => rfl
  | succ n ih => rw [sumR, sumR, ih (fun i h1 h2 => h i h1 (by omega)), h (n + 1) (by omega) le_rfl]

theorem isF_vat_edge {M : List (List (List B))} {c n i : ℕ} (hF : AllF M c n) (h1 : 1 ≤ i)
    (h2 : i ≤ n) : VF (vat M c i) ∧ VF (vat M c (nxt n i)) :=
  ⟨hF i h1 h2, hF _ (nxt_mem' h1 h2).1 (nxt_mem' h1 h2).2⟩

theorem isF_t1 {Q : List (List (List B))} {cq nq : ℕ} (hn : 1 ≤ nq) (hF : AllF Q cq nq) (s : B)
    {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) : IsF (t1R Q cq nq s p0 p1) := by
  unfold t1R
  refine isF_foldR' _ (fun a b => isF_fmin) _ _ (fun j j1 j2 => ?_)
  obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 (by omega)
  exact isF_cand1 (isF_cross e0 e1 h0) (isF_cross e0 e1 h1)

theorem isF_t0A {Q : List (List (List B))} {cq nq : ℕ} (hn : 1 ≤ nq) (hF : AllF Q cq nq)
    (sA sB : B) {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) : IsF (t0AR Q cq nq sA sB p0 p1) := by
  unfold t0AR
  refine isF_foldR' _ (fun a b => isF_fmax) _ _ (fun j j1 j2 => ?_)
  obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 (by omega)
  exact isF_cand0 (isF_cross e0 e1 h0) (isF_cross e0 e1 h1) (isF_ite isF_one isF_zero)

theorem isF_t0B {Q : List (List (List B))} {cq nq : ℕ} (hn : 1 ≤ nq) (hF : AllF Q cq nq)
    (sA sB : B) {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) : IsF (t0BR Q cq nq sA sB p0 p1) := by
  unfold t0BR
  refine isF_foldR' _ (fun a b => isF_fmax) _ _ (fun j j1 j2 => ?_)
  obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 (by omega)
  exact isF_cand0 (isF_cross e0 e1 h0) (isF_cross e0 e1 h1) (isF_ite isF_zero isF_one)

theorem isF_term {s t1 t0 : B} (hs : IsF s) (h1 : IsF t1) (h0 : IsF t0) {O p0 p1 : V B}
    (hO : VF O) (hp0 : VF p0) (hp1 : VF p1) : IsF (termR s t1 t0 O p0 p1) :=
  isF_mul (isF_mul (isF_mul hs (isF_fmax isF_zero (isF_sub h1 h0))) (isF_cross hO hp0 hp1))
    (isF_lit _ _)

/-- The clipped term of a zero-length edge is `0`. -/
theorem term_zero_edge {s t1 t0 : B} (hs : IsF s) (h1 : IsF t1) (h0 : IsF t0) {O u : V B}
    (hO : VF O) (hu : VF u) : termR s t1 t0 O u u = Bin64.fin 0 := by
  obtain ⟨x, hx⟩ := isF_mul hs (isF_fmax isF_zero (isF_sub h1 h0))
  unfold termR
  rw [hx, cross_end_twice hO hu, b_mul, fmul_zero',
    show (Lits.ofDec 5 1 : B) = Bin64.fin (rn ((5 : ℤ) / (10 : ℝ) ^ 1)) from rfl, b_mul,
    zero_fmul']

/-- A candidate built from a double cross product. -/
theorem cross_dbl {q0 q1 p : V B} (h0 : VF q0) (h1 : VF q1) (hp : VF p) :
    ∃ a, crossR q0 q1 p = Bin64.fin a ∧ Repr a := by
  obtain ⟨a, ha, har⟩ := isD_cross h0 h1 hp; exact ⟨a, ha, har⟩

/-- `t1` against a padded ring is `t1` against the ring. -/
theorem t1_pad {M M' : List (List (List B))} {c n p : ℕ} (hn : 1 ≤ n) (hP : PadAt M M' c n p)
    (hF : AllF M c n) (hF' : AllF M' c (n + 1)) {s : B} (hs : s = Bin64.fin 1 ∨ s = Bin64.fin (-1))
    {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) : t1R M' c (n + 1) s p0 p1 = t1R M c n s p0 p1 := by
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  unfold t1R
  simp only [Nat.add_sub_cancel]
  refine foldR_min_ins hp1 (by omega) (fun j j1 j2 => ?_) ⟨fun i i1 i2 => ?_, ?_, fun i i1 i2 => ?_⟩
  · obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 j2
    obtain ⟨a, ha, har⟩ := cross_dbl e0 e1 h0
    obtain ⟨b, hb, hbr⟩ := cross_dbl e0 e1 h1
    obtain ⟨t, htv, ht⟩ := tol_nonneg h0 h1 e0 e1
    rw [ha, hb, htv]
    exact cand1_le_one hs har hbr ht
  · obtain ⟨e1, e2⟩ := he i i1 (by omega) (by omega)
    simp only [i2, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]
  · dsimp only
    rw [hz, cross_zero_edge (hF' p hp1 hp2) h0, cross_zero_edge (hF' p hp1 hp2) h1,
      tol_zero_edge h0 h1 (hF' p hp1 hp2), cand1_zero_edge, b_one]
  · obtain ⟨e1, e2⟩ := he i (by omega) (by omega) (by omega)
    simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]

/-- An A edge's `t0` against a padded ring B is the same. -/
theorem t0A_pad {M M' : List (List (List B))} {c n p : ℕ} (hn : 1 ≤ n) (hP : PadAt M M' c n p)
    (hF : AllF M c n) (hF' : AllF M' c (n + 1)) {sA sB : B} (hsA : IsF sA)
    (hs : sB = Bin64.fin 1 ∨ sB = Bin64.fin (-1)) {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) :
    t0AR M' c (n + 1) sA sB p0 p1 = t0AR M c n sA sB p0 p1 := by
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  unfold t0AR
  simp only [Nat.add_sub_cancel]
  refine foldR_max_ins hp1 (by omega) (fun j j1 j2 => ?_) ⟨fun i i1 i2 => ?_, ?_, fun i i1 i2 => ?_⟩
  · obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 j2
    obtain ⟨a, ha, har⟩ := cross_dbl e0 e1 h0
    obtain ⟨b, hb, hbr⟩ := cross_dbl e0 e1 h1
    obtain ⟨t, htv, ht⟩ := tol_nonneg h0 h1 e0 e1
    rw [ha, hb, htv]
    split
    · rw [b_one]; exact cand0_nonneg hs har hbr ht (by norm_num)
    · rw [b_zero]; exact cand0_nonneg hs har hbr ht le_rfl
  · obtain ⟨e1, e2⟩ := he i i1 (by omega) (by omega)
    simp only [i2, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]
  · dsimp only
    obtain ⟨x, hx⟩ := isF_mul hsA (show IsF sB by rcases hs with h | h <;> rw [h] <;> exact isF_fin _)
    rw [hz, cross_zero_edge (hF' p hp1 hp2) h0, cross_zero_edge (hF' p hp1 hp2) h1,
      tol_zero_edge h0 h1 (hF' p hp1 hp2), cand0_zero_edge, dot_zero_edge (hF' p hp1 hp2) h0 h1,
      hx, b_mul, fmul_zero', b_zero, b_lt]
    simp
  · obtain ⟨e1, e2⟩ := he i (by omega) (by omega) (by omega)
    simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]

/-- A B edge's `t0` against a padded ring A is the same. -/
theorem t0B_pad {M M' : List (List (List B))} {c n p : ℕ} (hn : 1 ≤ n) (hP : PadAt M M' c n p)
    (hF : AllF M c n) (hF' : AllF M' c (n + 1)) {sA sB : B} (hsB : IsF sB)
    (hs : sA = Bin64.fin 1 ∨ sA = Bin64.fin (-1)) {p0 p1 : V B} (h0 : VF p0) (h1 : VF p1) :
    t0BR M' c (n + 1) sA sB p0 p1 = t0BR M c n sA sB p0 p1 := by
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  unfold t0BR
  simp only [Nat.add_sub_cancel]
  refine foldR_max_ins hp1 (by omega) (fun j j1 j2 => ?_) ⟨fun i i1 i2 => ?_, ?_, fun i i1 i2 => ?_⟩
  · obtain ⟨e0, e1⟩ := isF_vat_edge hF j1 j2
    obtain ⟨a, ha, har⟩ := cross_dbl e0 e1 h0
    obtain ⟨b, hb, hbr⟩ := cross_dbl e0 e1 h1
    obtain ⟨t, htv, ht⟩ := tol_nonneg h0 h1 e0 e1
    rw [ha, hb, htv]
    split
    · rw [b_zero]; exact cand0_nonneg hs har hbr ht le_rfl
    · rw [b_one]; exact cand0_nonneg hs har hbr ht (by norm_num)
  · obtain ⟨e1, e2⟩ := he i i1 (by omega) (by omega)
    simp only [i2, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]
  · dsimp only
    obtain ⟨x, hx⟩ := isF_mul hsB (show IsF sA by rcases hs with h | h <;> rw [h] <;> exact isF_fin _)
    rw [hz, cross_zero_edge (hF' p hp1 hp2) h0, cross_zero_edge (hF' p hp1 hp2) h1,
      tol_zero_edge h0 h1 (hF' p hp1 hp2), cand0_zero_edge, dot_zero_edge (hF' p hp1 hp2) h0 h1,
      hx, b_mul, fmul_zero', b_zero]
    simp [eqR, b_le]
  · obtain ⟨e1, e2⟩ := he i (by omega) (by omega) (by omega)
    simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
    dsimp only; rw [e1, e2]

/-! ## The two padding theorems -/

theorem sgn_isF (f : B) : IsF (sgnR f) := isF_sgn f

/-- **Padding ring A does not change the planar overlap.** In binary64, for
finite coordinates, a ring A' that is ring A with one zero-length edge
inserted (`PadAt`) gives bit-for-bit the same `planarRef`. -/
theorem planar_pad_A {MA MA' MB : List (List (List B))} {ca na cb nb p : ℕ} (ha : 1 ≤ na)
    (hb : 1 ≤ nb) (hP : PadAt MA MA' ca na p) (hFA : AllF MA ca na)
    (hFA' : AllF MA' ca (na + 1)) (hFB : AllF MB cb nb) :
    planarRef MA' ca (na + 1) MB cb nb = planarRef MA ca na MB cb nb := by
  have hfan := fan_pad ha hP hFA hFA'
  rw [planarRef_edges, planarRef_edges, hfan]
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  set sA := sgnR (fanR MA ca na)
  set sB := sgnR (fanR MB cb nb)
  have hO' := hFA 1 le_rfl ha
  split_ifs
  · rfl
  congr 1
  · -- A's edges: one more, the zero-length one, whose term is `0`
    refine sumR_ins hp1 hp2 (fun i h1 h2 => ?_) ⟨fun i h1 h2 => ?_, ?_, fun i h h2 => ?_⟩
    · obtain ⟨e0, e1⟩ := isF_vat_edge hFA h1 h2
      exact isF_term (sgn_isF _) (isF_t1 hb hFB _ e0 e1) (isF_t0A hb hFB _ _ e0 e1) hO' e0 e1
    · obtain ⟨e1, e2⟩ := he i h1 (by omega) (by omega)
      simp only [h2, ↓reduceIte] at e1 e2
      dsimp only; rw [hO, e1, e2]
    · dsimp only
      have hu := hFA' p hp1 hp2
      rw [hz, hO]
      exact term_zero_edge (sgn_isF _) (isF_t1 hb hFB _ hu hu) (isF_t0A hb hFB _ _ hu hu) hO' hu
    · obtain ⟨e1, e2⟩ := he i (by omega) h2 (by omega)
      simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
      dsimp only; rw [hO, e1, e2]
  · -- B's edges: each clipped by one more half-plane, a neutral one
    refine sumR_congr (fun i h1 h2 => ?_)
    obtain ⟨e0, e1⟩ := isF_vat_edge hFB h1 h2
    rw [hO, t1_pad ha ⟨hp1, hp2, hO, hz, he⟩ hFA hFA' (sgn_cases _) e0 e1,
      t0B_pad ha ⟨hp1, hp2, hO, hz, he⟩ hFA hFA' (sgn_isF _) (sgn_cases _) e0 e1]

/-- **Padding ring B does not change the planar overlap.** -/
theorem planar_pad_B {MA MB MB' : List (List (List B))} {ca na cb nb p : ℕ} (ha : 1 ≤ na)
    (hb : 1 ≤ nb) (hP : PadAt MB MB' cb nb p) (hFA : AllF MA ca na) (hFB : AllF MB cb nb)
    (hFB' : AllF MB' cb (nb + 1)) :
    planarRef MA ca na MB' cb (nb + 1) = planarRef MA ca na MB cb nb := by
  have hfan := fan_pad hb hP hFB hFB'
  rw [planarRef_edges, planarRef_edges, hfan]
  obtain ⟨hp1, hp2, hO, hz, he⟩ := hP
  have hO' := hFA 1 le_rfl ha
  split_ifs
  · rfl
  congr 1
  · -- A's edges: each clipped by one more half-plane, a neutral one
    refine sumR_congr (fun i h1 h2 => ?_)
    obtain ⟨e0, e1⟩ := isF_vat_edge hFA h1 h2
    rw [t1_pad hb ⟨hp1, hp2, hO, hz, he⟩ hFB hFB' (sgn_cases _) e0 e1,
      t0A_pad hb ⟨hp1, hp2, hO, hz, he⟩ hFB hFB' (sgn_isF _) (sgn_cases _) e0 e1]
  · -- B's edges: one more, the zero-length one, whose term is `0`
    refine sumR_ins hp1 hp2 (fun i h1 h2 => ?_) ⟨fun i h1 h2 => ?_, ?_, fun i h h2 => ?_⟩
    · obtain ⟨e0, e1⟩ := isF_vat_edge hFB h1 h2
      exact isF_term (sgn_isF _) (isF_t1 ha hFA _ e0 e1) (isF_t0B ha hFA _ _ e0 e1) hO' e0 e1
    · obtain ⟨e1, e2⟩ := he i h1 (by omega) (by omega)
      simp only [h2, ↓reduceIte] at e1 e2
      dsimp only; rw [e1, e2]
    · dsimp only
      have hu := hFB' p hp1 hp2
      rw [hz]
      exact term_zero_edge (sgn_isF _) (isF_t1 ha hFA _ hu hu) (isF_t0B ha hFA _ _ hu hu) hO' hu
    · obtain ⟨e1, e2⟩ := he i (by omega) h2 (by omega)
      simp only [show ¬ i < p by omega, ↓reduceIte] at e1 e2
      dsimp only; rw [e1, e2]

/-! ## Repeated vertices are zero-length edges -/

/-- Vertex `j` repeated after itself (a consecutive duplicate). -/
theorem pad_dup_edges {M M' : List (List (List B))} {c n j : ℕ} (hj1 : 1 ≤ j) (hjn : j ≤ n)
    (h : ∀ i, 1 ≤ i → i ≤ n + 1 → vat M' c i = vat M c (if i ≤ j then i else i - 1)) :
    PadAt M M' c n j := by
  refine ⟨hj1, by omega, by rw [h 1 le_rfl (by omega)]; simp [show 1 ≤ j from hj1], ?_,
    fun i h1 h2 hi => ⟨?_, ?_⟩⟩
  · unfold nxt
    simp only [show j < n + 1 by omega, ↓reduceIte]
    rw [h (j + 1) (by omega) (by omega), h j hj1 (by omega)]
    simp [show ¬ (j + 1 ≤ j) by omega]
  · rw [h i h1 h2]; congr 1; split_ifs <;> omega
  · unfold nxt
    by_cases hin : i < n + 1
    · simp only [hin, ↓reduceIte]
      rw [h (i + 1) (by omega) (by omega)]
      congr 1
      split_ifs <;> omega
    · simp only [hin, ↓reduceIte]
      rw [h 1 le_rfl (by omega)]
      congr 1
      split_ifs <;> omega

/-- Vertex 1 appended after the last (an explicit closing duplicate). -/
theorem pad_close_edges {M M' : List (List (List B))} {c n : ℕ} (hn : 1 ≤ n)
    (h : ∀ i, 1 ≤ i → i ≤ n + 1 → vat M' c i = vat M c (if i ≤ n then i else 1)) :
    PadAt M M' c n (n + 1) := by
  refine ⟨by omega, le_rfl, by rw [h 1 le_rfl (by omega)]; simp [hn], ?_,
    fun i h1 h2 hi => ⟨?_, ?_⟩⟩
  · unfold nxt
    simp only [lt_irrefl, ↓reduceIte]
    rw [h 1 le_rfl (by omega), h (n + 1) (by omega) le_rfl]
    simp [hn]
  · rw [h i h1 h2]; congr 1; split_ifs <;> omega
  · unfold nxt
    simp only [show i < n + 1 by omega, ↓reduceIte]
    rw [h (i + 1) (by omega) (by omega)]
    congr 1

/-! ## About the evaluated template -/

/-- The environment of `planar_template_eq`. -/
noncomputable abbrev envP (MA : List (List (List B))) (ca : ℕ) (MB : List (List (List B))) (cb : ℕ) : Env B :=
  [("RA", .arr3 MA), ("CA", .num (fin (ca : ℝ))), ("RB", .arr3 MB), ("CB", .num (fin (cb : ℝ)))]

/-- **The padded ring A gives the same template value**, bit for bit, in
binary64: `overlap_area_planar` on ring A' (A with a zero-length edge
inserted, `na + 1` slots) equals it on ring A (`na` slots). -/
theorem planar_template_pad_A {MA MA' MB : List (List (List B))} {ca na cb nb p : ℕ}
    (hSA : Shape MA ca na) (hSA' : Shape MA' ca (na + 1)) (hSB : Shape MB cb nb) (ha : 1 ≤ na)
    (hb : 1 ≤ nb) (han : na + 1 < 2 ^ 53) (hbn : nb < 2 ^ 53) (hP : PadAt MA MA' ca na p)
    (hFA : AllF MA ca na) (hFA' : AllF MA' ca (na + 1)) (hFB : AllF MB cb nb) :
    evalApply Esm.Lib.Geometry.overlap_area_planar (bindP (na + 1) nb) (envP MA' ca MB cb) =
      evalApply Esm.Lib.Geometry.overlap_area_planar (bindP na nb) (envP MA ca MB cb) := by
  rw [planar_template_eq hSA' hSB (by omega) hb han hbn,
    planar_template_eq hSA hSB ha hb (by omega) hbn, planar_pad_A ha hb hP hFA hFA' hFB]

/-- **The padded ring B gives the same template value**, bit for bit. -/
theorem planar_template_pad_B {MA MB MB' : List (List (List B))} {ca na cb nb p : ℕ}
    (hSA : Shape MA ca na) (hSB : Shape MB cb nb) (hSB' : Shape MB' cb (nb + 1)) (ha : 1 ≤ na)
    (hb : 1 ≤ nb) (han : na < 2 ^ 53) (hbn : nb + 1 < 2 ^ 53) (hP : PadAt MB MB' cb nb p)
    (hFA : AllF MA ca na) (hFB : AllF MB cb nb) (hFB' : AllF MB' cb (nb + 1)) :
    evalApply Esm.Lib.Geometry.overlap_area_planar (bindP na (nb + 1)) (envP MA ca MB' cb) =
      evalApply Esm.Lib.Geometry.overlap_area_planar (bindP na nb) (envP MA ca MB cb) := by
  rw [planar_template_eq hSA hSB' ha (by omega) han hbn,
    planar_template_eq hSA hSB ha hb han (by omega), planar_pad_B ha hb hP hFA hFB hFB']

end Esm.Closed.GeometryAst
