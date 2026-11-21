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
values); object entries keep their order.

`math s` is not JSON: it is the math text of an expression inside a path block, the
form a container prints and reads there (`Source.mathify`, `Source.cookBlocks`). It
lives only between a container's text and the skeleton; a document never holds one
(`WF` is false on it). -/
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JNum)
  | str (s : String)
  | arr (xs : List Json)
  | obj (kvs : List (String × Json))
  | math (s : String)
  deriving Repr

namespace Json

/-- Math text a container can delimit with `$`: not empty, no `$`, no line break, and
not ending in a backslash (which would escape the closing `$`). -/
def mathOK (s : String) : Bool :=
  !s.toList.isEmpty && !s.toList.contains '$' && !s.toList.contains '\n' &&
    !s.toList.contains '\r' && s.toList.getLast? != some '\\'

/-- The text of a math leaf after its `$`, up to the next `$`. -/
def mathBody : List Char → Option (List Char × List Char)
  | [] => none
  | c :: r => if c = '$' then some ([], r) else (mathBody r).map fun p => (c :: p.1, p.2)

/-- A math leaf after its `$`: the text up to the next `$`, which must be `mathOK`. -/
def pMath (r : List Char) : Option (Json × List Char) :=
  match mathBody r with
  | some (b, r') => if mathOK (String.ofList b) then some (.math (String.ofList b), r') else none
  | none => none

theorem mathBody_append : ∀ (l r : List Char), l.contains '$' = false →
    mathBody (l ++ '$' :: r) = some (l, r)
  | [], r, _ => by simp [mathBody]
  | c :: l, r, h => by
    simp only [List.contains_cons, Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at h
    have hc : c ≠ '$' := fun e => h.1 e.symm
    simp only [List.cons_append, mathBody, hc, ite_false, mathBody_append l r h.2,
      Option.map_some]

theorem pMath_math (s : String) (r : List Char) (h : mathOK s = true) :
    pMath (s.toList ++ '$' :: r) = some (.math s, r) := by
  have hd : s.toList.contains '$' = false := by
    simp only [mathOK, Bool.and_eq_true, Bool.not_eq_true'] at h; exact h.1.1.1.2
  simp [pMath, mathBody_append _ _ hd, String.ofList_toList, h]

mutual
/-- Well formed: every number is canonical, every object has distinct keys, and there is
no math leaf. -/
def WF : Json → Prop
  | .num n => n.WF
  | .arr xs => WFList xs
  | .obj kvs => (kvs.map Prod.fst).Nodup ∧ WFObj kvs
  | .math _ => False
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
  | .math _ => false
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
  | .math _ => by simp [wfb, WF]
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
/-- Well formed with math leaves: `WF`, except that a math leaf whose text is `mathOK`
is allowed. What the codecs print and read: a path block's value as a container holds
it. -/
def WFm : Json → Prop
  | .num n => n.WF
  | .arr xs => WFmList xs
  | .obj kvs => (kvs.map Prod.fst).Nodup ∧ WFmObj kvs
  | .math s => mathOK s = true
  | _ => True

def WFmList : List Json → Prop
  | [] => True
  | v :: vs => WFm v ∧ WFmList vs

def WFmObj : List (String × Json) → Prop
  | [] => True
  | (_, v) :: es => WFm v ∧ WFmObj es
end

mutual
/-- `WFm`, as a check. -/
def wfmb : Json → Bool
  | .num n => n.wfb
  | .arr xs => wfmbList xs
  | .obj kvs => decide (kvs.map Prod.fst).Nodup && wfmbObj kvs
  | .math s => mathOK s
  | _ => true

def wfmbList : List Json → Bool
  | [] => true
  | v :: vs => wfmb v && wfmbList vs

def wfmbObj : List (String × Json) → Bool
  | [] => true
  | (_, v) :: es => wfmb v && wfmbObj es
end

mutual
theorem wfmb_iff : ∀ v : Json, v.wfmb = true ↔ v.WFm
  | .null => by simp [wfmb, WFm]
  | .bool _ => by simp [wfmb, WFm]
  | .str _ => by simp [wfmb, WFm]
  | .math _ => by simp [wfmb, WFm]
  | .num n => by simp only [wfmb, WFm]; exact n.wfb_iff
  | .arr xs => by simp only [wfmb, WFm]; exact wfmbList_iff xs
  | .obj kvs => by
    simp only [wfmb, WFm, Bool.and_eq_true, decide_eq_true_eq]
    rw [wfmbObj_iff kvs]

theorem wfmbList_iff : ∀ l : List Json, wfmbList l = true ↔ WFmList l
  | [] => by simp [wfmbList, WFmList]
  | v :: vs => by
    simp only [wfmbList, WFmList, Bool.and_eq_true]
    rw [wfmb_iff v, wfmbList_iff vs]

theorem wfmbObj_iff : ∀ l : List (String × Json), wfmbObj l = true ↔ WFmObj l
  | [] => by simp [wfmbObj, WFmObj]
  | (_, v) :: es => by
    simp only [wfmbObj, WFmObj, Bool.and_eq_true]
    rw [wfmb_iff v, wfmbObj_iff es]
end

mutual
/-- A well-formed value is well formed with math leaves (it has none). -/
theorem WF.wfm : ∀ {v : Json}, v.WF → v.WFm
  | .null, _ => trivial
  | .bool _, _ => trivial
  | .str _, _ => trivial
  | .num _, h => h
  | .math _, h => h.elim
  | .arr xs, h => WFList.wfm (xs := xs) h
  | .obj _, h => ⟨h.1, WFObj.wfm h.2⟩

theorem WFList.wfm : ∀ {xs : List Json}, WFList xs → WFmList xs
  | [], _ => trivial
  | _ :: _, h => ⟨WF.wfm h.1, WFList.wfm h.2⟩

theorem WFObj.wfm : ∀ {es : List (String × Json)}, WFObj es → WFmObj es
  | [], _ => trivial
  | (_, _) :: _, h => ⟨WF.wfm h.1, WFObj.wfm h.2⟩
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
