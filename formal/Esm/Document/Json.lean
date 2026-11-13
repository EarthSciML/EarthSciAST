import Mathlib.Data.List.Nodup

/-!
# JSON values of an ESM document, in canonical form

The value type the document codecs (`Esm.Document.Yaml`, `Esm.Document.TypstDict`)
print and read. Numbers are already in the canonical form of CONFORMANCE §5.5.3.1:

* rule 1 and rule 3: a number whose value is integral and representable in `Int64` is
  the integer literal (`1.0` IS the integer `1`), so it is `JNum.int`;
* rule 2: every other finite number is `JNum.dec`, its shortest round-trip decimal
  digits and the decimal exponent of the first digit. Binary64 is not modelled; the
  shortest digits are given data.

Object key order is part of the value (the codecs preserve it; they never sort).
-/

namespace Esm.Document

/-- A JSON number in canonical form.

* `int z`: an integer literal (well formed when `z` fits in `Int64`).
* `dec neg ds e10`: the value `±d₁.d₂d₃… × 10^e10`, `-` when `neg`, with `ds` the
  shortest round-trip digits. -/
inductive JNum where
  | int (z : Int)
  | dec (neg : Bool) (digits : List Nat) (e10 : Int)
  deriving DecidableEq, Repr

namespace JNum

/-- `z` is representable in `Int64`. -/
def InInt64 (z : Int) : Prop := -(2 ^ 63 : Int) ≤ z ∧ z < 2 ^ 63

/-- The value of a big-endian decimal digit list. -/
def digitsVal (ds : List Nat) : Nat := ds.foldl (fun a d => 10 * a + d) 0

/-- The integer a decimal denotes, when the decimal is integral (its last digit sits at
or left of the units place), else `none`. -/
def decInt? (neg : Bool) (ds : List Nat) (e10 : Int) : Option Int :=
  if (ds.length : Int) ≤ e10 + 1 then
    let m : Int := (digitsVal ds : Int) * 10 ^ (e10 + 1 - ds.length).toNat
    some (if neg then -m else m)
  else none

/-- Canonical form of a number:

* an `int` fits in `Int64`;
* a `dec` has nonempty digits, each below 10, with no leading and no trailing zero,
  and is not an integral `Int64` value (that number is an `int`, §5.5.3.1 rule 1). -/
def WF : JNum → Prop
  | int z => InInt64 z
  | dec neg ds e10 =>
      ds ≠ [] ∧ (∀ d ∈ ds, d < 10) ∧ ds.head? ≠ some 0 ∧ ds.getLast? ≠ some 0 ∧
        ∀ z, decInt? neg ds e10 = some z → ¬ InInt64 z

instance (z : Int) : Decidable (InInt64 z) := inferInstanceAs (Decidable (_ ∧ _))

/-- `WF`, as a check. -/
def wfb : JNum → Bool
  | int z => decide (InInt64 z)
  | dec neg ds e10 =>
    !ds.isEmpty && ds.all (· < 10) && ds.head? != some 0 && ds.getLast? != some 0 &&
      match decInt? neg ds e10 with
      | some z => !decide (InInt64 z)
      | none => true

theorem wfb_iff (n : JNum) : n.wfb = true ↔ n.WF := by
  cases n with
  | int z => simp [wfb, WF]
  | dec neg ds e10 =>
    simp only [wfb, WF, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true,
      List.isEmpty_eq_false_iff, List.all_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq]
    cases h : decInt? neg ds e10 <;> simp [and_assoc]

end JNum

/-- A JSON value. Strings and keys are arbitrary Lean strings (any Unicode scalar
values); object entries keep their order. -/
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JNum)
  | str (s : String)
  | arr (xs : List Json)
  | obj (kvs : List (String × Json))
  deriving Repr

namespace Json

mutual
/-- Well formed: every number is canonical and every object has distinct keys. -/
def WF : Json → Prop
  | .num n => n.WF
  | .arr xs => WFList xs
  | .obj kvs => (kvs.map Prod.fst).Nodup ∧ WFObj kvs
  | _ => True

/-- Every element is well formed. -/
def WFList : List Json → Prop
  | [] => True
  | v :: vs => WF v ∧ WFList vs

/-- Every entry's value is well formed. -/
def WFObj : List (String × Json) → Prop
  | [] => True
  | (_, v) :: es => WF v ∧ WFObj es
end

mutual
/-- `WF`, as a check. -/
def wfb : Json → Bool
  | .num n => n.wfb
  | .arr xs => wfbList xs
  | .obj kvs => decide (kvs.map Prod.fst).Nodup && wfbObj kvs
  | _ => true

def wfbList : List Json → Bool
  | [] => true
  | v :: vs => wfb v && wfbList vs

def wfbObj : List (String × Json) → Bool
  | [] => true
  | (_, v) :: es => wfb v && wfbObj es
end

mutual
theorem wfb_iff : ∀ v : Json, v.wfb = true ↔ v.WF
  | .null => by simp [wfb, WF]
  | .bool _ => by simp [wfb, WF]
  | .str _ => by simp [wfb, WF]
  | .num n => by simp only [wfb, WF]; exact n.wfb_iff
  | .arr xs => by simp only [wfb, WF]; exact wfbList_iff xs
  | .obj kvs => by
    simp only [wfb, WF, Bool.and_eq_true, decide_eq_true_eq]
    rw [wfbObj_iff kvs]

theorem wfbList_iff : ∀ l : List Json, wfbList l = true ↔ WFList l
  | [] => by simp [wfbList, WFList]
  | v :: vs => by
    simp only [wfbList, WFList, Bool.and_eq_true]
    rw [wfb_iff v, wfbList_iff vs]

theorem wfbObj_iff : ∀ l : List (String × Json), wfbObj l = true ↔ WFObj l
  | [] => by simp [wfbObj, WFObj]
  | (_, v) :: es => by
    simp only [wfbObj, WFObj, Bool.and_eq_true]
    rw [wfb_iff v, wfbObj_iff es]
end

mutual
/-- A size measure: the parsers' fuel is bounded below by it. -/
def size : Json → Nat
  | .arr xs => sizeList xs + 1
  | .obj kvs => sizeObj kvs + 1
  | _ => 1

def sizeList : List Json → Nat
  | [] => 1
  | v :: vs => size v + sizeList vs + 1

def sizeObj : List (String × Json) → Nat
  | [] => 1
  | (_, v) :: es => size v + sizeObj es + 1
end

end Json

end Esm.Document
