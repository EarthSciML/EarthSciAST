import Esm.Document.Math.Expr
import Mathlib.Data.List.Sort
import Mathlib.Data.String.Basic

/-!
# Objects in canonical form: sorting entries, and splitting an object between surfaces

A canonical ESM document has the keys of every object in strictly increasing order
(the sorted-key canonical serialization). The document printer takes an object apart:
some entries get a surface of their own (a declaration, a component directive), the
rest is printed as a path block. The parser collects the entries back from wherever
they were written, in whatever order, and sorts them. This module holds the two facts
that make that sound:

* `sortKeys_ext`: sorting a list that holds, key by key, the same entries as a
  canonical object gives that object;
* `joinField_splitField`: an object-valued field split between its own surfaces and a
  residue block is rebuilt exactly.
-/

namespace Esm.Document.Source

open Esm.Document Esm.Document.Math

/-! ## Sorting by key -/

/-- The entries ordered by key (a stable merge sort). -/
def sortKeys (l : List (String × Json)) : List (String × Json) :=
  l.mergeSort (fun a b => decide (a.1 ≤ b.1))

/-- The entries of `l` with key `k`. -/
def at_ (k : String) (l : List (String × Json)) : List (String × Json) :=
  l.filter (fun kv => kv.1 == k)

theorem keysSorted_cons {k : String} {v : Json} {l : List (String × Json)}
    (h : keysSorted ((k, v) :: l) = true) : keysSorted l = true := by
  match l, h with
  | [], _ => rfl
  | (_, _) :: _, h =>
    simp only [keysSorted, Bool.and_eq_true] at h
    exact h.2

theorem keysSorted_pairwise : ∀ l : List (String × Json), keysSorted l = true →
    l.Pairwise (fun a b => a.1 < b.1)
  | [], _ => List.Pairwise.nil
  | [_], _ => List.pairwise_singleton _ _
  | (k1, v1) :: (k2, v2) :: r, h => by
    have h' := h
    simp only [keysSorted, Bool.and_eq_true, decide_eq_true_eq] at h'
    have ih := keysSorted_pairwise ((k2, v2) :: r) h'.2
    refine List.Pairwise.cons ?_ ih
    intro b hb
    rcases List.mem_cons.mp hb with rfl | hb
    · exact h'.1
    · exact lt_trans h'.1 (List.rel_of_pairwise_cons ih hb)

theorem keysSorted_nodup {l : List (String × Json)} (h : keysSorted l = true) :
    (l.map Prod.fst).Nodup := by
  have := keysSorted_pairwise l h
  rw [List.Nodup, List.pairwise_map]
  exact this.imp (fun hab => ne_of_lt hab)

/-- Sorting a permutation of a canonical (strictly key-sorted) list gives that list. -/
theorem sortKeys_eq {l l' : List (String × Json)} (hp : l.Perm l') (hs : keysSorted l' = true) :
    sortKeys l = l' := by
  have h1 : (sortKeys l).Perm l' := (List.mergeSort_perm _ _).trans hp
  have h2 : (sortKeys l).Pairwise (fun a b => decide (a.1 ≤ b.1) = true) :=
    List.pairwise_mergeSort (le := fun a b => decide (a.1 ≤ b.1))
      (fun a b c hab hbc => by simp only [decide_eq_true_eq] at *; exact le_trans hab hbc)
      (fun a b => by
        simp only [Bool.or_eq_true, decide_eq_true_eq]
        exact le_total _ _) l
  have h3 := keysSorted_pairwise l' hs
  have hn : ((sortKeys l).map Prod.fst).Nodup := (h1.map Prod.fst).nodup_iff.mpr (keysSorted_nodup hs)
  rw [List.Nodup, List.pairwise_map] at hn
  have h4 : (sortKeys l).Pairwise (fun a b => a.1 < b.1) :=
    (h2.and hn).imp (fun ⟨h, hne⟩ => lt_of_le_of_ne (of_decide_eq_true h) hne)
  exact h1.eq_of_pairwise (fun a b _ _ hab hba => absurd (lt_trans hab hba) (lt_irrefl _)) h4 h3

/-- **Key-by-key extensionality.** A list holding, for every key, exactly the entries a
canonical list holds sorts to that list. -/
theorem sortKeys_ext {R l : List (String × Json)} (hl : keysSorted l = true)
    (h : ∀ k, at_ k R = at_ k l) : sortKeys R = l := by
  classical
  apply sortKeys_eq _ hl
  rw [List.perm_iff_count]
  intro a
  have e1 : List.count a R = List.count a (at_ a.1 R) := by
    unfold at_; rw [List.count_filter]; simp
  have e2 : List.count a l = List.count a (at_ a.1 l) := by
    unfold at_; rw [List.count_filter]; simp
  rw [e1, e2, h]

theorem at_append (k : String) (a b : List (String × Json)) : at_ k (a ++ b) = at_ k a ++ at_ k b :=
  List.filter_append ..

@[simp] theorem at_nil (k : String) : at_ k [] = [] := rfl

theorem at_cons (k k' : String) (v : Json) (l : List (String × Json)) :
    at_ k ((k', v) :: l) = if k' = k then (k', v) :: at_ k l else at_ k l := by
  unfold at_
  rw [List.filter_cons]
  by_cases h : k' = k <;> simp [h]

theorem at_single (k k' : String) (v : Json) : at_ k [(k', v)] = if k' = k then [(k', v)] else [] := by
  rw [at_cons]; rfl

theorem at_filter (k : String) (p : String × Json → Bool) (l : List (String × Json))
    (hp : ∀ v, p (k, v) = true) : at_ k (l.filter p) = at_ k l := by
  unfold at_
  rw [List.filter_filter]
  congr 1
  funext kv
  obtain ⟨k', v⟩ := kv
  by_cases h : k' = k
  · subst h; simp [hp v]
  · simp [h]

theorem at_filter_false (k : String) (p : String × Json → Bool) (l : List (String × Json))
    (hp : ∀ v, p (k, v) = false) : at_ k (l.filter p) = [] := by
  unfold at_
  rw [List.filter_filter, List.filter_eq_nil_iff]
  intro kv _
  obtain ⟨k', v⟩ := kv
  by_cases h : k' = k
  · subst h; simp [hp v]
  · simp [h]

/-- In a canonical list, the entries with key `k` are the one `look` finds, or none. -/
theorem at_of_sorted {l : List (String × Json)} (hl : keysSorted l = true) (k : String) :
    at_ k l = match look k l with
      | some v => [(k, v)]
      | none => [] := by
  induction l with
  | nil => rfl
  | cons e r ih =>
    obtain ⟨k', v'⟩ := e
    have ih' := ih (keysSorted_cons hl)
    have hp := keysSorted_pairwise _ hl
    rw [at_cons]
    by_cases h : k' = k
    · subst h
      simp only [look, ite_true]
      have : at_ k' r = [] := by
        unfold at_
        rw [List.filter_eq_nil_iff]
        intro kv hkv
        have := List.rel_of_pairwise_cons hp hkv
        simp only [beq_iff_eq]
        exact (ne_of_lt this).symm
      rw [this]
    · simp only [h, ite_false, look]
      exact ih'

theorem look_at {l : List (String × Json)} {k : String} {v : Json} (hl : keysSorted l = true)
    (h : look k l = some v) : at_ k l = [(k, v)] := by
  rw [at_of_sorted hl, h]

theorem look_at_none {l : List (String × Json)} {k : String} (hl : keysSorted l = true)
    (h : look k l = none) : at_ k l = [] := by
  rw [at_of_sorted hl, h]

/-! ## Splitting an object-valued field -/

/-- The entries of an object-valued field that get a surface of their own (`pick`
returns their piece) and the residue, printed as a path block under the field's key.
A value that is not an object is all residue. The residue block is omitted only when
some entry was picked and none is left; an object none of whose entries is picked
(including `{}`) is all residue, so an absent field and an empty one stay apart. -/
def splitField {β : Type} (pick : String → Json → Option β) : Json → List β × Option Json
  | .obj kvs =>
    let ps := kvs.filterMap (fun kv => pick kv.1 kv.2)
    let rs := kvs.filter (fun kv => (pick kv.1 kv.2).isNone)
    (ps, if !ps.isEmpty && rs.isEmpty then none else some (.obj rs))
  | v => ([], some v)

/-- `splitField` of a field that may be absent. -/
def splitOpt {β : Type} (pick : String → Json → Option β) : Option Json → List β × Option Json
  | some v => splitField pick v
  | none => ([], none)

/-- The field rebuilt from its pieces (each mapped back to its entry) and its residue:
`none` when they do not fit together, `some none` when the field is absent. -/
def joinField {β : Type} (back : β → Option (String × Json)) (ps : List β) (r : Option Json) :
    Option (Option Json) :=
  match ps with
  | [] => some r
  | p :: ps' =>
    match (p :: ps').mapM back, r with
    | some es, none => some (some (.obj (sortKeys es)))
    | some es, some (.obj rs) => some (some (.obj (sortKeys (es ++ rs))))
    | _, _ => none

theorem mapM_filterMap {β : Type} (pick : String → Json → Option β)
    (back : β → Option (String × Json)) :
    ∀ kvs : List (String × Json),
      (∀ k v p, (k, v) ∈ kvs → pick k v = some p → back p = some (k, v)) →
      (kvs.filterMap (fun kv => pick kv.1 kv.2)).mapM back =
        some (kvs.filter (fun kv => (pick kv.1 kv.2).isSome))
  | [], _ => rfl
  | (k, v) :: r, hb => by
    have ih := mapM_filterMap pick back r
      (fun k' v' p hm hp => hb k' v' p (List.mem_cons_of_mem _ hm) hp)
    cases h : pick k v with
    | none => simp [h, ih]
    | some p => simp [h, ih, hb k v p List.mem_cons_self h]

/-- **The split field is rebuilt exactly**, when every piece maps back to its entry. -/
theorem joinField_splitField {β : Type} (pick : String → Json → Option β)
    (back : β → Option (String × Json)) (v : Json)
    (hv : ∀ kvs, v = .obj kvs → keysSorted kvs = true)
    (hb : ∀ kvs, v = .obj kvs → ∀ k w p, (k, w) ∈ kvs → pick k w = some p → back p = some (k, w)) :
    joinField back (splitField pick v).1 (splitField pick v).2 = some (some v) := by
  match v with
  | .obj kvs =>
    have hs := hv kvs rfl
    simp only [splitField]
    have hm := mapM_filterMap pick back kvs (hb kvs rfl)
    cases hps : kvs.filterMap (fun kv => pick kv.1 kv.2) with
    | nil =>
      have hall : kvs.filter (fun kv => (pick kv.1 kv.2).isNone) = kvs := by
        rw [List.filter_eq_self]
        intro kv hkv
        rw [List.filterMap_eq_nil_iff] at hps
        simp [hps kv hkv]
      simp [joinField, hall]
    | cons p ps' =>
      rw [hps] at hm
      simp only [joinField, hm, List.isEmpty_cons, Bool.not_false, Bool.true_and]
      by_cases hr : (kvs.filter (fun kv => (pick kv.1 kv.2).isNone)).isEmpty
      · simp only [hr, ite_true]
        have : kvs.filter (fun kv => (pick kv.1 kv.2).isSome) = kvs := by
          rw [List.filter_eq_self]
          intro kv hkv
          rw [List.isEmpty_iff, List.filter_eq_nil_iff] at hr
          have := hr kv hkv
          simp only [Option.isNone_iff_eq_none] at this
          simpa [Option.isSome_iff_ne_none] using this
        rw [this, sortKeys_eq (List.Perm.refl _) hs]
      · simp only [hr, ite_false, Bool.false_eq_true]
        congr 3
        apply sortKeys_eq _ hs
        have := List.filter_append_perm (fun kv : String × Json => (pick kv.1 kv.2).isSome) kvs
        refine List.Perm.trans ?_ this
        apply List.Perm.append_left
        apply List.Perm.of_eq
        congr 1
        funext kv
        simp
  | .null => rfl
  | .bool _ => rfl
  | .num _ => rfl
  | .str _ => rfl
  | .arr _ => rfl

/-- The same, for a field that may be absent. -/
theorem joinField_splitOpt {β : Type} (pick : String → Json → Option β)
    (back : β → Option (String × Json)) (o : Option Json)
    (hv : ∀ kvs, o = some (.obj kvs) → keysSorted kvs = true)
    (hb : ∀ kvs, o = some (.obj kvs) →
      ∀ k w p, (k, w) ∈ kvs → pick k w = some p → back p = some (k, w)) :
    joinField back (splitOpt pick o).1 (splitOpt pick o).2 = some o := by
  cases o with
  | none => rfl
  | some v =>
    exact joinField_splitField pick back v (fun kvs h => hv kvs (by rw [h]))
      (fun kvs h => hb kvs (by rw [h]))

/-- The pieces of a split field are the picks of its entries. -/
theorem splitField_fst {β : Type} (pick : String → Json → Option β) (v : Json) :
    (splitField pick v).1 = (match v with
      | .obj kvs => kvs.filterMap (fun kv => pick kv.1 kv.2)
      | _ => []) := by
  cases v <;> rfl

/-! ## Reading one entry back -/

/-- The value of the only entry with key `k`: `some none` when there is none, `none`
when there are several. -/
def pickOne (k : String) (l : List (String × Json)) : Option (Option Json) :=
  match at_ k l with
  | [] => some none
  | [(_, v)] => some (some v)
  | _ => none

end Esm.Document.Source
