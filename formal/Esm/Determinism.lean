import Mathlib.Algebra.BigOperators.Group.List.Basic
import Mathlib.Data.List.Chain
import Mathlib.Data.List.Destutter
import Mathlib.Data.List.Sort
import Mathlib.Data.String.Basic
import Mathlib.Order.Prod.Lex.Basic

/-!
# Relational determinism (CONFORMANCE §5.5.1)

These operators describe the ordered values of the relational producers.
Integer fields use the integer order, strings use the Lean string order
(lexicographic on Unicode scalar values), and tuple fields are ordered
lexicographically. These definitions operate on exact keys and exact additive
group-by values. The relational template laws in `Esm.Closed.Relational`
cover ESM's scalar key encodings, rank definitions, and arg-witness reducers.
-/

namespace Esm.Determinism

variable {α β : Type*}

/-- Sort by the key order, then remove only adjacent duplicate keys. -/
def distinct [LinearOrder α] (keys : List α) : List α :=
  (keys.mergeSort (· ≤ ·)).destutter (· ≠ ·)

private theorem mem_destutter_ne [DecidableEq α] (key head : α) (tail : List α) :
    key ∈ tail.destutter' (· ≠ ·) head ↔ key ∈ head :: tail := by
  induction tail generalizing head with
  | nil => simp
  | cons next tail ih =>
    by_cases h : head = next
    · subst next
      simp [ih]
    · simp [h, ih]

@[simp]
theorem mem_distinct [LinearOrder α] (key : α) (keys : List α) :
    key ∈ distinct keys ↔ key ∈ keys := by
  unfold distinct
  rw [← List.mem_mergeSort (a := key) (l := keys) (le := (· ≤ ·))]
  cases keys.mergeSort (· ≤ ·) with
  | nil => rfl
  | cons head tail => exact mem_destutter_ne key head tail

theorem distinct_sorted [LinearOrder α] (keys : List α) :
    (distinct keys).Pairwise (· < ·) := by
  have hLe : (distinct keys).Pairwise (· ≤ ·) :=
    (List.sortedLE_mergeSort (l := keys)).pairwise.sublist (List.destutter_sublist _ _)
  have hNe : (distinct keys).IsChain (· ≠ ·) := List.isChain_destutter _ _
  have hLt : (distinct keys).IsChain (· < ·) := by
    have hChain := List.isChain_iff_pairwise.mpr hLe
    exact List.isChain_iff_getElem.mpr fun i hi =>
      lt_of_le_of_ne (hChain.getElem i hi) (hNe.getElem i hi)
  exact List.isChain_iff_pairwise.mp hLt

theorem distinct_eq_of_mem_iff [LinearOrder α] (a b : List α)
    (h : ∀ k, k ∈ a ↔ k ∈ b) : distinct a = distinct b :=
  (distinct_sorted a).eq_of_mem_iff (distinct_sorted b) (by simpa using h)

theorem distinct_perm [LinearOrder α] (a b : List α) (h : a.Perm b) :
    distinct a = distinct b :=
  distinct_eq_of_mem_iff a b (fun _ => h.mem_iff)

theorem distinct_idempotent [LinearOrder α] (keys : List α) :
    distinct (distinct keys) = distinct keys :=
  distinct_eq_of_mem_iff _ _ (fun k => mem_distinct k keys)

/-- An undirected key is represented by its endpoints in canonical order. -/
def edgeEndpoints [LinearOrder α] (a b : α) : α × α :=
  (min a b, max a b)

theorem edgeEndpoints_swap [LinearOrder α] (a b : α) :
    edgeEndpoints a b = edgeEndpoints b a := by
  simp [edgeEndpoints, min_comm, max_comm]

/-- Look up a member's zero-based position in an emitted distinct sequence.
ESM's `rank_of` for a member is this position plus one. -/
def denseRank [DecidableEq α] (members : List α) (key : { k // k ∈ members }) :
    Fin members.length :=
  ⟨members.idxOf key.val, List.idxOf_lt_length_iff.mpr key.property⟩

private theorem idxOf_eq_count_lt [LinearOrder α] (l : List α)
    (strict : l.Pairwise (· < ·)) (key : α) (member : key ∈ l) :
    l.idxOf key = (l.filter (fun value => decide (value < key))).length := by
  induction l with
  | nil => simp at member
  | cons head tail ih =>
    obtain ⟨headLt, tailStrict⟩ := List.pairwise_cons.mp strict
    by_cases eq : head = key
    · subst head
      have noSmaller : tail.filter (fun value => decide (value < key)) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro value h
        simp [not_lt_of_gt (headLt _ h)]
      simp [noSmaller]
    · have inTail : key ∈ tail := by simpa [Ne.symm eq] using member
      simp [eq, headLt key inTail, ih tailStrict inTail, Nat.succ_eq_add_one]

/-- On a sorted distinct set this is the number of smaller members, matching
the one-based relational template `rank_of` after base normalization. -/
theorem denseRank_eq_count_lt [LinearOrder α] (keys : List α) (key : { k // k ∈ distinct keys }) :
    (denseRank (distinct keys) key).val = ((distinct keys).filter (fun value => decide (value < key.val))).length :=
  idxOf_eq_count_lt _ (distinct_sorted keys) key.val key.property

theorem denseRank_bijective [LinearOrder α] (keys : List α) :
    Function.Bijective (denseRank (distinct keys)) := by
  constructor
  · intro a b h
    have ha : (distinct keys)[(denseRank (distinct keys) a).val] = a.val :=
      List.getElem_idxOf (denseRank (distinct keys) a).isLt
    have hb : (distinct keys)[(denseRank (distinct keys) b).val] = b.val :=
      List.getElem_idxOf (denseRank (distinct keys) b).isLt
    apply Subtype.ext
    exact ha.symm.trans ((congrArg (distinct keys).get h).trans hb)
  · intro pos
    refine ⟨⟨(distinct keys)[pos.val], List.getElem_mem pos.isLt⟩, ?_⟩
    apply Fin.ext
    exact (distinct_sorted keys).nodup.idxOf_getElem pos.val pos.isLt

/-- Reference match set for an equality join (§5.5.8), ordered first by
key, then left and right position. The input rows carry their assigned
positions, which are distinct from the order in which rows are enumerated. -/
def equalityMatches [LinearOrder α] (left right : List (α × Int)) : List (α ×ₗ (Int ×ₗ Int)) :=
  distinct (left.flatMap fun (key, i) =>
    (right.filterMap fun (other, j) => if key = other then some (toLex (key, toLex (i, j))) else none))

theorem mem_equalityMatches [LinearOrder α] (left right : List (α × Int)) (key : α) (i j : Int) :
    toLex (key, toLex (i, j)) ∈ equalityMatches left right ↔
      (key, i) ∈ left ∧ (key, j) ∈ right := by
  simp [equalityMatches, List.mem_flatMap, List.mem_filterMap]

theorem equalityMatches_sorted [LinearOrder α] (left right : List (α × Int)) :
    (equalityMatches left right).Pairwise (· < ·) :=
  distinct_sorted _

theorem equalityMatches_perm [LinearOrder α] (a b c d : List (α × Int))
    (hLeft : a.Perm b) (hRight : c.Perm d) :
    equalityMatches a c = equalityMatches b d := by
  apply (equalityMatches_sorted a c).eq_of_mem_iff (equalityMatches_sorted b d)
  intro matchKey
  obtain ⟨⟨key, pos⟩, rfl⟩ := toLex.surjective matchKey
  obtain ⟨⟨i, j⟩, rfl⟩ := toLex.surjective pos
  simp only [mem_equalityMatches, hLeft.mem_iff, hRight.mem_iff]

/-- Ordered group-by with exact addition. The key order can be read directly
from the emitted rows. -/
def groupBySum [LinearOrder α] [AddCommMonoid β] (rows : List (α × β)) : List (α × β) :=
  (distinct (rows.map Prod.fst)).map fun key =>
    (key, ((rows.filter fun row => row.1 = key).map Prod.snd).sum)

theorem mem_groupBySum [LinearOrder α] [AddCommMonoid β]
    (rows : List (α × β)) (key : α) (value : β) :
    (key, value) ∈ groupBySum rows ↔
      key ∈ rows.map Prod.fst ∧ value = ((rows.filter fun row => row.1 = key).map Prod.snd).sum := by
  simp [groupBySum, List.mem_map, eq_comm]

theorem groupBySum_sorted [LinearOrder α] [AddCommMonoid β] (rows : List (α × β)) :
    ((groupBySum rows).map Prod.fst).Pairwise (· < ·) := by
  simpa [groupBySum, List.map_map, Function.comp_def] using distinct_sorted (rows.map Prod.fst)

theorem groupBySum_perm [LinearOrder α] [AddCommMonoid β] (a b : List (α × β)) (h : a.Perm b) :
    groupBySum a = groupBySum b := by
  unfold groupBySum
  rw [distinct_perm _ _ (h.map Prod.fst)]
  apply List.map_congr_left
  intro key _
  rw [((h.filter (fun row => row.1 = key)).map Prod.snd).sum_eq]

end Esm.Determinism
