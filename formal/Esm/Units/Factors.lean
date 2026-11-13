import Esm.Units.GrammarLaws
import Mathlib.Data.String.Basic
import Mathlib.Data.List.Sort
import Mathlib.Algebra.BigOperators.Group.Finset.Basic

/-!
# Factor lists: the flattened form of a parsed unit

The canonical unit spelling (`Esm.Units.Canonical`) is computed from a parsed
unit tree (`UExpr`, esm-spec §4.8.2) by flattening it to a list of factors
(symbol, rational exponent) and normalizing that list:

* `UExpr.factors` flattens: `*` concatenates, `/` negates the exponents of its
  right operand, `^q` multiplies every exponent below it by `q`. The atom `1`
  and the symbol `dimensionless` contribute nothing: §4.8.1 lists `""`, `"1"`
  and `"dimensionless"` as the three spellings of ONE dimensionless entry, so
  `dimensionless` is a spelling of the atom `1`, not a symbol to be kept.
* `norm` sums the exponents of each symbol, drops the symbols whose sum is
  zero, and sorts by symbol (`String`'s order: codepoint order, so uppercase
  before lowercase).
* `norm2` splits the list into its numerator side (positive exponents) and its
  denominator side (the rest) and applies `norm` to each side separately, so a
  symbol on both sides stays on both: `mol/mol` is not cancelled (ruling of
  2026-11-12). This is the canonical form; `norm` is its building block.

This is purely syntactic: no symbol is looked up, so `km` stays `km` and `ppm`
stays `ppm`. Two factor lists denote the same product iff they have the same
exponent function `expOf`; `norm` picks the one sorted, zero-free list with a
given exponent function (`eq_of_expOf_eq`), and `norm2` keeps that exponent
function too (`expOf_norm2`).
-/

namespace Esm.Units

/-- A unit factor: a symbol and its rational exponent. -/
abbrev Factor := String × ℚ

/-- Flatten a parsed unit to its factor list. -/
def UExpr.factors : UExpr → List Factor
  | .one => []
  | .sym s => if s = "dimensionless" then [] else [(s, 1)]
  | .mul a b => a.factors ++ b.factors
  | .div a b => a.factors ++ b.factors.map (fun f => (f.1, -f.2))
  | .pow a q => a.factors.map (fun f => (f.1, q * f.2))

/-- The total exponent of symbol `s` in a factor list. -/
def expOf (l : List Factor) (s : String) : ℚ :=
  ((l.filter (fun f => f.1 = s)).map Prod.snd).sum

/-- The symbols of a factor list. -/
def syms (l : List Factor) : List String := l.map Prod.fst

/-- Sum exponents per symbol, drop zero sums, sort by symbol. -/
def norm (l : List Factor) : List Factor :=
  ((syms l).dedup.insertionSort (· ≤ ·)).filterMap
    (fun s => if expOf l s = 0 then none else some (s, expOf l s))

/-- A normalized factor list: strictly increasing symbols, no zero exponent. -/
def Normal (l : List Factor) : Prop :=
  l.Pairwise (fun a b => a.1 < b.1) ∧ ∀ f ∈ l, f.2 ≠ 0

/-! ## The exponent function -/

@[simp] theorem expOf_nil (s : String) : expOf [] s = 0 := rfl

theorem expOf_cons (f : Factor) (l : List Factor) (s : String) :
    expOf (f :: l) s = (if f.1 = s then f.2 else 0) + expOf l s := by
  unfold expOf
  by_cases h : f.1 = s <;> simp [h]

theorem expOf_append (l l' : List Factor) (s : String) :
    expOf (l ++ l') s = expOf l s + expOf l' s := by
  simp [expOf, List.filter_append]

theorem expOf_eq_zero (l : List Factor) (s : String) (h : s ∉ syms l) : expOf l s = 0 := by
  induction l with
  | nil => rfl
  | cons f l ih =>
    simp only [syms, List.map_cons, List.mem_cons, not_or] at h
    rw [expOf_cons, ite_eq_right (Ne.symm h.1), ih h.2]; simp

theorem mem_syms_of_expOf_ne (l : List Factor) (s : String) (h : expOf l s ≠ 0) : s ∈ syms l := by
  by_contra h'; exact h (expOf_eq_zero l s h')

theorem expOf_perm {l l' : List Factor} (h : l.Perm l') : expOf l = expOf l' := by
  funext s
  unfold expOf
  exact ((h.filter _).map _).sum_eq

/-! ## `norm` -/

theorem expOf_filterMap (K : List String) (hK : K.Nodup) (q : String → ℚ) (s : String) :
    expOf (K.filterMap (fun k => if q k = 0 then none else some (k, q k))) s =
      if s ∈ K then q s else 0 := by
  induction K with
  | nil => simp
  | cons k K ih =>
    rw [List.nodup_cons] at hK
    have ih := ih hK.2
    by_cases hq : q k = 0
    · simp only [List.filterMap_cons, hq, ite_true, ih, List.mem_cons]
      by_cases hs : s = k
      · subst hs; simp [hq]
      · simp [hs]
    · simp only [List.filterMap_cons, hq, ite_false, expOf_cons, ih, List.mem_cons]
      by_cases hs : s = k
      · subst hs; simp [hK.1]
      · simp [hs, Ne.symm hs]

theorem expOf_norm (l : List Factor) : expOf (norm l) = expOf l := by
  funext s
  unfold norm
  rw [expOf_filterMap _ ((List.perm_insertionSort _ _).nodup_iff.mpr (List.nodup_dedup _))]
  simp only [List.mem_insertionSort, List.mem_dedup]
  split_ifs with h
  · rfl
  · exact (expOf_eq_zero l s h).symm

theorem syms_norm_sub (l : List Factor) : ∀ f ∈ norm l, f.1 ∈ syms l := by
  intro f hf
  unfold norm at hf
  rw [List.mem_filterMap] at hf
  obtain ⟨k, hk, he⟩ := hf
  split_ifs at he
  cases he
  simpa [List.mem_insertionSort, List.mem_dedup] using hk

theorem normal_norm (l : List Factor) : Normal (norm l) := by
  constructor
  · unfold norm
    have hs : ((syms l).dedup.insertionSort (· ≤ ·)).Pairwise (· < ·) := by
      have hle := List.pairwise_insertionSort (· ≤ ·) (syms l).dedup
      have hnd := (List.perm_insertionSort (· ≤ ·) (syms l).dedup).nodup_iff.mpr
        (List.nodup_dedup _)
      exact (hle.and hnd).imp fun ⟨h1, h2⟩ => lt_of_le_of_ne h1 h2
    refine List.Pairwise.filterMap _ ?_ hs
    intro a b hab a' ha' b' hb'
    split_ifs at ha' hb'
    cases ha'; cases hb'; exact hab
  · intro f hf
    unfold norm at hf
    rw [List.mem_filterMap] at hf
    obtain ⟨k, -, he⟩ := hf
    split_ifs at he with h
    cases he; exact h

/-- In a normal list, a member's exponent is its symbol's total exponent. -/
theorem expOf_of_mem_normal {l : List Factor} (hl : Normal l) {f : Factor} (hf : f ∈ l) :
    expOf l f.1 = f.2 := by
  obtain ⟨hp, -⟩ := hl
  induction l with
  | nil => cases hf
  | cons g l ih =>
    rw [List.pairwise_cons] at hp
    rw [expOf_cons]
    rcases List.mem_cons.mp hf with rfl | hf
    · have : f.1 ∉ syms l := by
        intro hm
        obtain ⟨g, hg, he⟩ := List.mem_map.mp hm
        exact (ne_of_lt (hp.1 g hg)) he.symm
      simp [expOf_eq_zero l f.1 this]
    · have hne : g.1 ≠ f.1 := ne_of_lt (hp.1 f hf)
      simp [hne, ih hf hp.2]

theorem mem_normal_iff {l : List Factor} (hl : Normal l) (f : Factor) :
    f ∈ l ↔ f.2 ≠ 0 ∧ expOf l f.1 = f.2 := by
  constructor
  · intro hf; exact ⟨hl.2 f hf, expOf_of_mem_normal hl hf⟩
  · rintro ⟨h0, he⟩
    have hm := mem_syms_of_expOf_ne l f.1 (he ▸ h0)
    obtain ⟨g, hg, hgs⟩ := List.mem_map.mp hm
    have := expOf_of_mem_normal hl hg
    rw [hgs, he] at this
    have : g = f := Prod.ext hgs this.symm
    exact this ▸ hg

/-- A normal list is determined by its exponent function. -/
theorem eq_of_expOf_eq {l l' : List Factor} (hl : Normal l) (hl' : Normal l')
    (h : expOf l = expOf l') : l = l' := by
  have hmem : ∀ f, f ∈ l ↔ f ∈ l' := by
    intro f; rw [mem_normal_iff hl, mem_normal_iff hl', h]
  have hnd : ∀ {m : List Factor}, Normal m → m.Nodup := fun hm =>
    hm.1.imp fun h e => (ne_of_lt h) (congrArg Prod.fst e)
  exact List.Perm.eq_of_pairwise (fun a b _ _ h1 h2 => absurd (lt_trans h1 h2) (lt_irrefl _))
    hl.1 hl'.1 ((List.perm_ext_iff_of_nodup (hnd hl) (hnd hl')).mpr hmem)

theorem norm_eq_of_normal {l : List Factor} (hl : Normal l) : norm l = l :=
  eq_of_expOf_eq (normal_norm l) hl (expOf_norm l)

theorem norm_eq_of_perm {l l' : List Factor} (hl : Normal l) (h : l'.Perm l) : norm l' = l :=
  eq_of_expOf_eq (normal_norm l') hl ((expOf_norm l').trans (expOf_perm h))

theorem norm_idem (l : List Factor) : norm (norm l) = norm l :=
  norm_eq_of_normal (normal_norm l)

/-! ## The two-sided normal form

The canonical spelling never cancels a symbol across the fraction bar: `mol/mol`
stays `mol/mol`. A factor is on the numerator side when its net exponent (after
`/` and negative exponents) is positive, and on the denominator side otherwise;
each side is normalized on its own (`norm2`). A zero exponent (`m^0`) is dropped. -/

/-- The factors with a positive exponent. -/
def numFactors (l : List Factor) : List Factor := l.filter (fun f => decide (0 < f.2))
/-- The factors with a nonpositive exponent. -/
def denFactors (l : List Factor) : List Factor := l.filter (fun f => !decide (0 < f.2))

theorem mem_numFactors {l : List Factor} {f : Factor} (h : f ∈ numFactors l) : f ∈ l :=
  List.mem_of_mem_filter h
theorem mem_denFactors {l : List Factor} {f : Factor} (h : f ∈ denFactors l) : f ∈ l :=
  List.mem_of_mem_filter h

theorem pos_of_mem_numFactors {l : List Factor} {f : Factor} (h : f ∈ numFactors l) : 0 < f.2 := by
  simpa [numFactors] using (List.mem_filter.mp h).2
theorem nonpos_of_mem_denFactors {l : List Factor} {f : Factor} (h : f ∈ denFactors l) :
    f.2 ≤ 0 := by
  have := (List.mem_filter.mp h).2
  simp at this; exact this

/-- Each side normalized on its own: numerator side, then denominator side. -/
def norm2 (l : List Factor) : List Factor := norm (numFactors l) ++ norm (denFactors l)

/-- A two-sided normal list: its positive factors, then its negative ones, each
side normal; no zero exponent. -/
def Normal2 (l : List Factor) : Prop :=
  (numFactors l ++ denFactors l = l ∧ Normal (numFactors l) ∧ Normal (denFactors l)) ∧
    ∀ f ∈ l, f.2 ≠ 0

theorem expOf_num_den (l : List Factor) (s : String) :
    expOf l s = expOf (numFactors l) s + expOf (denFactors l) s := by
  rw [← expOf_append]
  exact (congrFun (expOf_perm (List.filter_append_perm _ l)) s).symm

theorem expOf_norm2 (l : List Factor) : expOf (norm2 l) = expOf l := by
  funext s
  rw [norm2, expOf_append, expOf_norm, expOf_norm, expOf_num_den l s]

theorem syms_norm2_sub (l : List Factor) : ∀ f ∈ norm2 l, f.1 ∈ syms l := by
  intro f hf
  rcases List.mem_append.mp hf with hf | hf
  · obtain ⟨g, hg, he⟩ := List.mem_map.mp (syms_norm_sub _ f hf)
    exact List.mem_map.mpr ⟨g, mem_numFactors hg, he⟩
  · obtain ⟨g, hg, he⟩ := List.mem_map.mp (syms_norm_sub _ f hf)
    exact List.mem_map.mpr ⟨g, mem_denFactors hg, he⟩

theorem expOf_nonneg (l : List Factor) (h : ∀ f ∈ l, 0 ≤ f.2) (s : String) : 0 ≤ expOf l s := by
  unfold expOf
  refine List.sum_nonneg fun x hx => ?_
  obtain ⟨f, hf, rfl⟩ := List.mem_map.mp hx
  exact h f (List.mem_of_mem_filter hf)

theorem expOf_nonpos (l : List Factor) (h : ∀ f ∈ l, f.2 ≤ 0) (s : String) : expOf l s ≤ 0 := by
  induction l with
  | nil => simp
  | cons f l ih =>
    have hf := h f (by simp)
    have := ih (fun g hg => h g (by simp [hg]))
    rw [expOf_cons]; split_ifs <;> linarith

/-- In `norm l`, each member's exponent is the total exponent of its symbol in `l`. -/
theorem exp_of_mem_norm (l : List Factor) {f : Factor} (hf : f ∈ norm l) : f.2 = expOf l f.1 := by
  rw [← expOf_of_mem_normal (normal_norm l) hf, expOf_norm]

theorem norm_pos (l : List Factor) (h : ∀ f ∈ l, 0 < f.2) : ∀ f ∈ norm l, 0 < f.2 := by
  intro f hf
  have h0 := (normal_norm l).2 f hf
  have := expOf_nonneg l (fun g hg => (h g hg).le) f.1
  rw [← exp_of_mem_norm l hf] at this
  exact lt_of_le_of_ne this (Ne.symm h0)

theorem norm_neg (l : List Factor) (h : ∀ f ∈ l, f.2 ≤ 0) : ∀ f ∈ norm l, f.2 < 0 := by
  intro f hf
  have h0 := (normal_norm l).2 f hf
  have := expOf_nonpos l h f.1
  rw [← exp_of_mem_norm l hf] at this
  exact lt_of_le_of_ne this h0

theorem numFactors_sides (A B : List Factor) (hA : ∀ f ∈ A, 0 < f.2) (hB : ∀ f ∈ B, f.2 < 0) :
    numFactors (A ++ B) = A ∧ denFactors (A ++ B) = B := by
  unfold numFactors denFactors
  rw [List.filter_append, List.filter_append,
    List.filter_eq_self.mpr (fun f hf => by simpa using hA f hf),
    List.filter_eq_nil_iff.mpr (fun f hf => by simpa using (hB f hf).le),
    List.filter_eq_nil_iff.mpr (fun f hf => by simpa using hA f hf),
    List.filter_eq_self.mpr (fun f hf => by simpa using (hB f hf).le)]
  simp

theorem normal2_norm2 (l : List Factor) : Normal2 (norm2 l) := by
  have hA := norm_pos (numFactors l) (fun f hf => pos_of_mem_numFactors hf)
  have hB := norm_neg (denFactors l) (fun f hf => nonpos_of_mem_denFactors hf)
  obtain ⟨hn, hd⟩ := numFactors_sides _ _ hA hB
  unfold Normal2 norm2
  rw [hn, hd]
  refine ⟨⟨rfl, normal_norm _, normal_norm _⟩, fun f hf => ?_⟩
  rcases List.mem_append.mp hf with hf | hf
  · exact (hA f hf).ne'
  · exact (hB f hf).ne

theorem norm2_eq_of_normal2 {l : List Factor} (hl : Normal2 l) : norm2 l = l := by
  unfold norm2
  rw [norm_eq_of_normal hl.1.2.1, norm_eq_of_normal hl.1.2.2, hl.1.1]

theorem norm2_idem (l : List Factor) : norm2 (norm2 l) = norm2 l :=
  norm2_eq_of_normal2 (normal2_norm2 l)

/-! ## Weighted sums depend only on the exponent function -/

section Weighted

variable {M : Type*} [AddCommGroup M] [Module ℚ M]

/-- `Σ q • v s` over a factor list. -/
def wsum (v : String → M) (l : List Factor) : M := (l.map fun f => f.2 • v f.1).sum

theorem wsum_eq_finset (v : String → M) (l : List Factor) (S : Finset String)
    (hS : ∀ s ∈ syms l, s ∈ S) : wsum v l = ∑ s ∈ S, expOf l s • v s := by
  induction l with
  | nil => simp [wsum]
  | cons f l ih =>
    have hf : f.1 ∈ S := hS f.1 (by simp [syms])
    have ih := ih (fun s hs => hS s (by simp only [syms, List.map_cons, List.mem_cons] at hs ⊢; exact Or.inr hs))
    simp only [wsum, List.map_cons, List.sum_cons] at ih ⊢
    rw [ih]
    simp only [expOf_cons, add_smul, Finset.sum_add_distrib, ite_smul, zero_smul]
    rw [Finset.sum_ite_eq S f.1 (fun s => f.2 • v s), ite_eq_left hf]

theorem wsum_congr (v : String → M) {l l' : List Factor} (h : expOf l = expOf l') :
    wsum v l = wsum v l' := by
  classical
  let S := (syms l).toFinset ∪ (syms l').toFinset
  rw [wsum_eq_finset v l S (fun s hs => by simp [S, hs]),
    wsum_eq_finset v l' S (fun s hs => by simp [S, hs]), h]

end Weighted

end Esm.Units
