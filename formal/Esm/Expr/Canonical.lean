import Mathlib.Algebra.BigOperators.Group.List.Basic
import Mathlib.Algebra.GroupWithZero.Defs
import Esm.Float64

/-! The argument transformations of discretization RFC §5.4.2–§5.4.4.
The wire adapter supplies the node view, sort key, and literal predicates.
The preservation laws concern exact monoidal evaluation, for instance real
products or real sums, where regrouping and reordering are valid. -/

namespace Esm.Expr.Canonical

variable {α κ M : Type*}

/-- Splice the immediate children of each unannotated same-operator node. -/
def flattenArgs (children : α → Option (List α)) (args : List α) : List α :=
  args.flatMap fun arg => (children arg).getD [arg]

/-- Compute each comparison key once, including serialized subtree keys. -/
def orderArgs (key : α → κ) (before : κ → κ → Bool) (args : List α) : List α :=
  let keyed := args.map fun arg => (key arg, arg)
  (keyed.mergeSort fun a b => before a.1 b.1).map Prod.snd

/-- Remove literal identities, retaining a representative when the wire type requires it. -/
def identityArgs (identity : α → Bool) (retain : List α → List α → Option α)
    (args : List α) : List α :=
  let (neutral, rest) := args.partition identity
  match retain neutral rest with
  | none => rest
  | some arg => arg :: rest

theorem flattenArgs_preserves [Monoid M] (children : α → Option (List α))
    (value : α → M) (args : List α)
    (sameOp : ∀ arg inner, children arg = some inner → (inner.map value).prod = value arg) :
    ((flattenArgs children args).map value).prod = (args.map value).prod := by
  induction args with
  | nil => simp [flattenArgs]
  | cons arg rest ih =>
    change ((((children arg).getD [arg] ++ flattenArgs children rest).map value).prod) = _
    rw [List.map_append, List.prod_append, ih, List.map_cons, List.prod_cons]
    cases h : children arg with
    | none => simp
    | some inner => rw [show (some inner).getD [arg] = inner from rfl, sameOp arg inner h]

private theorem flattenArgs_leaves (children : α → Option (List α)) (args : List α)
    (normalizedChildren : ∀ arg ∈ args, ∀ inner, children arg = some inner →
      ∀ child ∈ inner, children child = none) :
    ∀ arg ∈ flattenArgs children args, children arg = none := by
  intro arg h
  obtain ⟨parent, member, branch⟩ := List.mem_flatMap.mp h
  cases hparent : children parent with
  | none =>
    have eq : arg = parent := by simpa [hparent] using branch
    simpa [eq] using hparent
  | some inner => exact normalizedChildren parent member inner hparent arg (by simpa [hparent] using branch)

private theorem flattenArgs_of_leaves (children : α → Option (List α)) (args : List α)
    (leaves : ∀ arg ∈ args, children arg = none) : flattenArgs children args = args := by
  unfold flattenArgs
  calc
    _ = args.flatMap (fun arg => [arg]) := by
      apply List.flatMap_congr
      intro arg member
      simp [leaves arg member]
    _ = _ := by simp

theorem flattenArgs_idempotent (children : α → Option (List α)) (args : List α)
    (normalizedChildren : ∀ arg ∈ args, ∀ inner, children arg = some inner →
      ∀ child ∈ inner, children child = none) :
    flattenArgs children (flattenArgs children args) = flattenArgs children args :=
  flattenArgs_of_leaves children _ (flattenArgs_leaves children args normalizedChildren)

theorem orderArgs_eq_mergeSort (key : α → κ) (before : κ → κ → Bool) (args : List α) :
    orderArgs key before args = args.mergeSort (fun a b => before (key a) (key b)) := by
  unfold orderArgs
  rw [List.map_mergeSort (s := fun a b => before (key a) (key b))]
  · simp [Function.comp_def]
  · intro a ha b hb
    obtain ⟨a, _, rfl⟩ := List.mem_map.mp ha
    obtain ⟨b, _, rfl⟩ := List.mem_map.mp hb
    rfl

theorem orderArgs_preserves [CommMonoid M] (key : α → κ) (before : κ → κ → Bool)
    (value : α → M) (args : List α) :
    ((orderArgs key before args).map value).prod = (args.map value).prod := by
  rw [orderArgs_eq_mergeSort]
  exact ((List.mergeSort_perm args _).map value).prod_eq

private theorem filter_identities_preserves [Monoid M] (identity : α → Bool) (value : α → M)
    (args : List α) (neutral : ∀ arg, identity arg = true → value arg = 1) :
    ((args.filter fun arg => !identity arg).map value).prod = (args.map value).prod := by
  induction args with
  | nil => simp
  | cons arg rest ih =>
    cases h : identity arg
    · simp [h, ih]
    · simp [h, ih, neutral arg h]

theorem identityArgs_preserves [Monoid M] (identity : α → Bool)
    (retain : List α → List α → Option α) (value : α → M) (args : List α)
    (neutral : ∀ arg, identity arg = true → value arg = 1)
    (representative : ∀ removed rest arg, retain removed rest = some arg → value arg = 1) :
    ((identityArgs identity retain args).map value).prod = (args.map value).prod := by
  simp only [identityArgs, List.partition_eq_filter_filter]
  split
  · exact filter_identities_preserves identity value args neutral
  · rename_i arg h
    simpa [Function.comp_def, representative _ _ arg h] using
      filter_identities_preserves identity value args neutral

private theorem mergeSort_cons_stable {le : α → α → Bool}
    (transitive : ∀ a b c, le a b → le b c → le a c)
    (total : ∀ a b, le a b || le b a) (arg : α) (args : List α) :
    (arg :: args.mergeSort le).mergeSort le = (arg :: args).mergeSort le := by
  have insertAt : ∀ xs : List α,
      (arg :: xs).mergeSort le = (xs.mergeSort le).takeWhile (fun x => !le arg x) ++
        arg :: (xs.mergeSort le).dropWhile (fun x => !le arg x) := by
    intro xs
    obtain ⟨front, back, withArg, withoutArg, reject⟩ := List.mergeSort_cons transitive total arg xs
    have sorted := List.pairwise_mergeSort transitive total (arg :: xs)
    rw [withArg] at sorted
    have accept := (List.pairwise_cons.mp (List.pairwise_append.mp sorted).2.1).1
    rw [withArg, withoutArg, List.takeWhile_append_of_pos reject, List.dropWhile_append_of_pos reject]
    cases back with
    | nil => simp
    | cons head tail => simp [accept head (by simp)]
  rw [insertAt (args.mergeSort le), insertAt args,
    List.mergeSort_of_pairwise (List.pairwise_mergeSort transitive total args)]

/-- Reapplying typed identity elimination and stable ordering to the output
changes nothing when the retained literal is stable under reordering its peers. -/
theorem orderedIdentityArgs_idempotent (identity : α → Bool)
    (retain : List α → List α → Option α) (key : α → κ) (before : κ → κ → Bool)
    (args : List α) (transitive : ∀ a b c, before a b → before b c → before a c)
    (total : ∀ a b, before a b || before b a)
    (noNewIdentity : ∀ rest, retain [] rest = none)
    (retainedIdentity : ∀ neutral rest arg, retain neutral rest = some arg → identity arg = true)
    (retainAgain : ∀ neutral rest ordered arg, rest.Perm ordered →
      retain neutral rest = some arg → retain [arg] ordered = some arg) :
    orderArgs key before (identityArgs identity retain
        (orderArgs key before (identityArgs identity retain args))) =
      orderArgs key before (identityArgs identity retain args) := by
  let le : α → α → Bool := fun a b => before (key a) (key b)
  have lt : ∀ a b c, le a b → le b c → le a c := fun a b c => transitive (key a) (key b) (key c)
  have leTotal : ∀ a b, le a b || le b a := fun a b => total (key a) (key b)
  let rest := args.filter (not ∘ identity)
  have nonIdentity (arg : α) (h : arg ∈ rest.mergeSort le) : identity arg = false := by
    simpa [Function.comp_def] using (List.mem_filter.mp (List.mem_mergeSort.mp h)).2
  have filters (ys : List α) (member : ∀ arg ∈ ys, arg ∈ rest.mergeSort le) :
      ys.filter identity = [] ∧ ys.filter (not ∘ identity) = ys := by
    constructor
    · exact List.filter_eq_nil_iff.mpr (fun arg h => by simp [nonIdentity arg (member arg h)])
    · exact List.filter_eq_self.mpr (fun arg h => by simp [nonIdentity arg (member arg h)])
  simp only [orderArgs_eq_mergeSort]
  change (identityArgs identity retain ((identityArgs identity retain args).mergeSort le)).mergeSort le = _
  rw [show identityArgs identity retain args =
      match retain (args.filter identity) rest with
      | none => rest
      | some arg => arg :: rest by simp [identityArgs, rest]]
  cases hr : retain (args.filter identity) rest with
  | none =>
    obtain ⟨removed, remaining⟩ := filters (rest.mergeSort le) (fun _ h => h)
    simp only [identityArgs, List.partition_eq_filter_filter, removed, remaining, noNewIdentity]
    exact List.mergeSort_of_pairwise (List.pairwise_mergeSort lt leTotal rest)
  | some arg =>
    obtain ⟨front, back, withArg, withoutArg, _⟩ := List.mergeSort_cons lt leTotal arg rest
    obtain ⟨frontRemoved, frontRemaining⟩ := filters front (fun x h => by simp [withoutArg, h])
    obtain ⟨backRemoved, backRemaining⟩ := filters back (fun x h => by simp [withoutArg, h])
    have keep := retainedIdentity _ _ _ hr
    have keepAgain := retainAgain _ _ _ _ (List.mergeSort_perm rest le).symm hr
    have afterSort : identityArgs identity retain ((arg :: rest).mergeSort le) =
        arg :: rest.mergeSort le := by
      rw [withArg]
      simp [identityArgs, List.filter_append, keep, frontRemoved, backRemoved,
        frontRemaining, backRemaining, ← withoutArg, keepAgain]
    rw [afterSort]
    exact mergeSort_cons_stable lt leTotal arg rest

/-- The full associative argument pass reaches a fixed point when child
  nodes have already been normalized and a retained identity is a leaf. -/
theorem associativeArgs_idempotent (children : α → Option (List α)) (identity : α → Bool)
    (retain : List α → List α → Option α) (key : α → κ) (before : κ → κ → Bool)
    (args : List α) (transitive : ∀ a b c, before a b → before b c → before a c)
    (total : ∀ a b, before a b || before b a)
    (normalizedChildren : ∀ arg ∈ args, ∀ inner, children arg = some inner →
      ∀ child ∈ inner, children child = none)
    (noNewIdentity : ∀ rest, retain [] rest = none)
    (retainedIdentity : ∀ neutral rest arg, retain neutral rest = some arg →
      identity arg = true ∧ children arg = none)
    (retainAgain : ∀ neutral rest ordered arg, rest.Perm ordered →
      retain neutral rest = some arg → retain [arg] ordered = some arg) :
    let normalize := fun xs => orderArgs key before (identityArgs identity retain (flattenArgs children xs))
    normalize (normalize args) = normalize args := by
  let flat := flattenArgs children args
  let ordered := orderArgs key before (identityArgs identity retain flat)
  have leaves : ∀ arg ∈ ordered, children arg = none := by
    intro arg member
    simp only [ordered, orderArgs_eq_mergeSort, List.mem_mergeSort, identityArgs,
      List.partition_eq_filter_filter] at member
    have fromFlat (h : arg ∈ flat.filter (not ∘ identity)) : children arg = none :=
      flattenArgs_leaves children args normalizedChildren arg (List.mem_filter.mp h).1
    split at member
    · exact fromFlat member
    · rename_i kept keep
      rcases List.mem_cons.mp member with rfl | h
      · exact (retainedIdentity _ _ _ keep).2
      · exact fromFlat h
  change orderArgs key before (identityArgs identity retain (flattenArgs children ordered)) = ordered
  rw [flattenArgs_of_leaves children ordered leaves]
  exact orderedIdentityArgs_idempotent identity retain key before flat transitive total noNewIdentity
    (fun neutral rest arg keep => (retainedIdentity neutral rest arg keep).1) retainAgain

/-- Flattening, identity elimination and ordering preserve an exact n-ary fold.
Apply with multiplication or with the multiplicative presentation of addition. -/
theorem associativeArgs_preserve [CommMonoid M] (children : α → Option (List α))
    (identity : α → Bool) (retain : List α → List α → Option α)
    (key : α → κ) (before : κ → κ → Bool) (value : α → M) (args : List α)
    (sameOp : ∀ arg inner, children arg = some inner → (inner.map value).prod = value arg)
    (neutral : ∀ arg, identity arg = true → value arg = 1)
    (representative : ∀ removed rest arg, retain removed rest = some arg → value arg = 1) :
    ((orderArgs key before (identityArgs identity retain (flattenArgs children args))).map value).prod =
      (args.map value).prod := by
  rw [orderArgs_preserves, identityArgs_preserves identity retain value _ neutral representative,
    flattenArgs_preserves children value args sameOp]

/-- The first accepted zero witness preserves exact product value. -/
theorem firstZero_preserves [MonoidWithZero M] (zero : α → Option α) (value : α → M)
    (args : List α) (chosen : α) (found : args.findSome? zero = some chosen)
    (witness : ∀ arg selected, zero arg = some selected → value arg = 0 ∧ value selected = 0) :
    (args.map value).prod = value chosen := by
  induction args with
  | nil => simp at found
  | cons arg rest ih =>
    cases h : zero arg with
    | none =>
      have inRest : rest.findSome? zero = some chosen := by simpa [h] using found
      have resultZero : value chosen = 0 := by
        obtain ⟨a, _, hz⟩ := List.exists_of_findSome?_eq_some inRest
        exact (witness a chosen hz).2
      simp [ih inRest, resultZero]
    | some a =>
      have eq : a = chosen := by simpa [h] using found
      obtain ⟨argZero, chosenZero⟩ := witness arg a h
      simp [argZero, ← eq, chosenZero]

/-- Sorting the terms of a binary64 left fold can change its result. -/
theorem binary64_order_changes_sum :
    ¬ (∀ values : List ℚ,
      (orderArgs id (fun a b => decide (a ≤ b)) values).foldl Esm.F64.fadd 0 =
        values.foldl Esm.F64.fadd 0) := by
  intro h
  have sorted : (orderArgs id (fun a b => decide (a ≤ b)) [2 ^ 54, -(2 ^ 54), 1] : List ℚ) =
      [-(2 ^ 54), 1, 2 ^ 54] := by
    rw [orderArgs_eq_mergeSort]
    change (([2 ^ 54, -(2 ^ 54)] ++ [1] : List ℚ).mergeSort (fun a b => decide (a ≤ b))) = _
    rw [List.mergeSort_append _ _ (by simp) (by simp)]
    norm_num [List.merge]
  have counterexample :
      ([-(2 ^ 54), 1, 2 ^ 54] : List ℚ).foldl Esm.F64.fadd 0 ≠
        ([2 ^ 54, -(2 ^ 54), 1] : List ℚ).foldl Esm.F64.fadd 0 := by
    decide +kernel
  exact counterexample (sorted ▸ h _)

end Esm.Expr.Canonical
