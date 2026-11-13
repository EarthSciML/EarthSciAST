import Esm.Document.Number
import Esm.Units.Typeset

/-!
# Expressions as JSON values, and the symbol table

The math grammars are stated over the JSON value at an expression position
(spec §4.1), not over `Esm.Ast`, which drops fields. An expression is

* a number (`Json.num`), in the canonical form of CONFORMANCE §5.5.3.1;
* a name (`Json.str`): dot-separated identifier segments (§4.6 scoped references);
* a node (`Json.obj`): `op`, `args` and any other fields.

`isE` is the well-formedness check. It asks for the canonical form only where the
round trip needs it: object keys strictly increasing (the sorted-key canonical
serialization), canonical numbers, every `args` entry an expression, and an `op` that
is neither removed (§4.2 "Removed ops") nor deprecated (`neg`, `pow`: the printer
never writes them). Every other field may hold any well-formed JSON value. The
redundant spellings of `Notation.spellingRules` (an explicit `reduce: "+"`, a
unitless scalar `const`, a `D` without `wrt`) are NOT excluded: they print in the
generic escape form and round-trip exactly, so the theorem covers them too.

The symbol table `Sym` is what a document declares: the declared names and the
parameter lists of the templates in scope. The printer and the parser both consult
it, and the round-trip theorem holds for every table.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Characters -/

def isLetter (c : Char) : Bool := ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z')
def isUpper (c : Char) : Bool := 'A' ≤ c && c ≤ 'Z'
def isLower (c : Char) : Bool := 'a' ≤ c && c ≤ 'z'
def isDig (c : Char) : Bool := '0' ≤ c && c ≤ '9'
def isIdStart (c : Char) : Bool := isLetter c || c == '_'
def isIdChar (c : Char) : Bool := isLetter c || isDig c || c == '_'

/-! ## Names -/

/-- Split a character list at every `.`. -/
def splitDots : List Char → List (List Char)
  | [] => [[]]
  | c :: cs =>
    let r := splitDots cs
    if c = '.' then [] :: r
    else match r with
      | s :: rs => (c :: s) :: rs
      | [] => [[c]]

/-- Join segments with `.`. -/
def joinDots : List (List Char) → List Char
  | [] => []
  | [s] => s
  | s :: ss => s ++ '.' :: joinDots ss

/-- An identifier segment `[A-Za-z_][A-Za-z0-9_]*`. -/
def segOK : List Char → Bool
  | [] => false
  | c :: cs => isIdStart c && cs.all isIdChar

/-- A name: dot-separated identifier segments (every name in the corpus has this
shape). -/
def nameOK (s : String) : Bool := (splitDots s.toList).all segOK

/-- The Greek letter names that are a command in LaTeX (`\lambda`) and a symbol in
Typst (`lambda`): the lowercase letters but omicron, and the eleven uppercase letters
LaTeX has. -/
def greek : List String :=
  ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
    "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi",
    "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi",
    "Omega"]

def isGreek (s : List Char) : Bool := greek.contains (String.ofList s)

/-- One letter, or a Greek letter name: the `single` name shape. -/
def isSingle (s : List Char) : Bool :=
  match s with
  | [c] => isLetter c
  | _ => isGreek s

/-- The element symbols a chemical-formula name is built from. -/
def elements : List String :=
  ["H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S",
    "Cl", "Ar", "K", "Ca", "Ti", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br", "Kr", "Ag",
    "Sn", "I", "Xe", "Hg", "Pb", "Rn"]

/-- The maximal run of digits at the front. -/
def digRun : List Char → List Char × List Char
  | [] => ([], [])
  | c :: cs => if isDig c then let p := digRun cs; (c :: p.1, p.2) else ([], c :: cs)

/-- The maximal run of letters at the front. -/
def letRun : List Char → List Char × List Char
  | [] => ([], [])
  | c :: cs => if isLetter c then let p := letRun cs; (c :: p.1, p.2) else ([], c :: cs)

/-- Split a formula-shaped name into pieces: a run of letters and the run of digits
after it (possibly empty). `CH2O` is `[("CH", "2"), ("O", "")]`. -/
def pieces (s : List Char) : List (List Char × List Char) :=
  go s.length s
where
  go : Nat → List Char → List (List Char × List Char)
    | 0, _ => []
    | _, [] => []
    | f + 1, cs =>
      let a := letRun cs
      let b := digRun a.2
      if a.1 = [] then [] else (a.1, b.1) :: go f b.2

/-- The element-symbol tokens of a letter run: an uppercase letter, then an optional
lowercase one, greedily. -/
def elemToks : List Char → Option (List String)
  | [] => some []
  | c :: d :: cs =>
    if isUpper c && isLower d then (elemToks cs).map (String.ofList [c, d] :: ·)
    else if isUpper c then (elemToks (d :: cs)).map (String.ofList [c] :: ·)
    else none
  | [c] => if isUpper c then some [String.ofList [c]] else none

/-- A chemical-formula name (decision 2): letters and digits only, read as element
symbols and counts, starting with an element, with at least two tokens. `NO2`,
`CH2O`, `O3`, `NO`. -/
def isFormula (s : List Char) : Bool :=
  s.all (fun c => isLetter c || isDig c) &&
  (match s with | c :: _ => isUpper c | [] => false) &&
  (let ps := pieces s
   (ps.flatMap (fun p => p.1 ++ p.2)) == s &&
   ps.all (fun p => match elemToks p.1 with
     | some ts => ts.all (elements.contains ·)
     | none => false) &&
   2 ≤ (ps.map (fun p => (match elemToks p.1 with | some ts => ts.length | none => 0) +
      (if p.2 = [] then 0 else 1))).sum)

/-- The subscripted shape `b_r`: a single letter or Greek name, `_`, then a nonempty
rest. Returns the base and the rest. -/
def subParts (s : List Char) : Option (List Char × List Char) :=
  let b := s.takeWhile (· != '_')
  let r := s.dropWhile (· != '_')
  match r with
  | '_' :: rest => if isSingle b && rest ≠ [] then some (b, rest) else none
  | _ => none

/-! ## Numbers and JSON well-formedness, as checks -/

def int64OK (z : Int) : Bool := decide (-(2 ^ 63 : Int) ≤ z) && decide (z < 2 ^ 63)

/-- `JNum.WF` as a check. -/
def numOK : JNum → Bool
  | .int z => int64OK z
  | .dec neg ds e10 =>
    ds != [] && ds.all (· < 10) && ds.head? != some 0 && ds.getLast? != some 0 &&
      (match JNum.decInt? neg ds e10 with
       | some z => !int64OK z
       | none => true)

theorem numOK_iff (n : JNum) : numOK n = true ↔ n.WF := by
  cases n with
  | int z => simp [numOK, int64OK, JNum.WF, JNum.InInt64]
  | dec neg ds e10 =>
    simp only [numOK, JNum.WF, JNum.InInt64, Bool.and_eq_true, bne_iff_ne, ne_eq,
      List.all_eq_true, decide_eq_true_eq]
    constructor
    · rintro ⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩
      refine ⟨h1, h2, h3, h4, ?_⟩
      intro z hz
      rw [hz] at h5
      simp only [int64OK, Bool.not_eq_true', Bool.and_eq_false_iff, decide_eq_false_iff_not,
        not_le, not_lt] at h5
      omega
    · rintro ⟨h1, h2, h3, h4, h5⟩
      refine ⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, ?_⟩
      cases h : JNum.decInt? neg ds e10 with
      | none => rfl
      | some z =>
        have := h5 z h
        simp only [int64OK, Bool.not_eq_eq_eq_not, Bool.not_true, Bool.and_eq_false_iff,
          decide_eq_false_iff_not, not_le, not_lt]
        omega

/-- Strictly increasing keys. -/
def keysSorted : List (String × Json) → Bool
  | [] => true
  | [_] => true
  | (k1, _) :: (k2, v2) :: r => decide (k1 < k2) && keysSorted ((k2, v2) :: r)

mutual
/-- `Json.WF` as a check. -/
def jwf : Json → Bool
  | .num n => numOK n
  | .arr xs => jwfList xs
  | .obj kvs => decide (kvs.map Prod.fst).Nodup && jwfObj kvs
  | _ => true

def jwfList : List Json → Bool
  | [] => true
  | v :: vs => jwf v && jwfList vs

def jwfObj : List (String × Json) → Bool
  | [] => true
  | (_, v) :: es => jwf v && jwfObj es
end

mutual
theorem jwf_sound : ∀ v : Json, jwf v = true → v.WF
  | .null, _ => trivial
  | .bool _, _ => trivial
  | .str _, _ => trivial
  | .num n, h => (numOK_iff n).1 h
  | .arr xs, h => jwfList_sound xs h
  | .obj kvs, h => by
    simp only [jwf, Bool.and_eq_true, decide_eq_true_eq] at h
    exact ⟨h.1, jwfObj_sound kvs h.2⟩

theorem jwfList_sound : ∀ xs : List Json, jwfList xs = true → Json.WFList xs
  | [], _ => trivial
  | v :: vs, h => by
    simp only [jwfList, Bool.and_eq_true] at h
    exact ⟨jwf_sound v h.1, jwfList_sound vs h.2⟩

theorem jwfObj_sound : ∀ kvs : List (String × Json), jwfObj kvs = true → Json.WFObj kvs
  | [], _ => trivial
  | (_, v) :: es, h => by
    simp only [jwfObj, Bool.and_eq_true] at h
    exact ⟨jwf_sound v h.1, jwfObj_sound es h.2⟩
end

/-! ## Operators -/

/-- Spec §4.2 "Removed ops": refused by name. -/
def removedOps : List String :=
  ["arrayop", "aggregate", "fn", "table_lookup", "skolem", "rank", "argmin", "argmax",
    "polygon_intersection_area", "intersect_polygon"]

/-- Deprecated: read in the call form and rewritten, never printed. -/
def deprecatedOps : List String := ["neg", "pow"]

/-- The `op` pattern of the schema: `[A-Za-z_][A-Za-z0-9_.]*` or `[-+*/^<>=!]+`. -/
def opOK (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: cs =>
    (isIdStart c && cs.all (fun d => isIdChar d || d == '.')) ||
      (c :: cs).all (fun d => "-+*/^<>=!".toList.contains d)

/-- The value of key `k`. -/
def look (k : String) : List (String × Json) → Option Json
  | [] => none
  | (k', v) :: r => if k' = k then some v else look k r

/-! ## Expressions -/

/-- The `op` field is present and names an operator that is neither removed nor
deprecated. -/
def opFieldOK (kvs : List (String × Json)) : Bool :=
  match look "op" kvs with
  | some (.str o) => opOK o && !(removedOps.contains o) && !(deprecatedOps.contains o)
  | _ => false

/-- The `args` field is present. -/
def hasArgs (kvs : List (String × Json)) : Bool := (look "args" kvs).isSome

/-- Well-formed expression (canonical form), as a check. -/
def isE : Json → Bool
  | .num n => numOK n
  | .str s => nameOK s
  | .obj kvs =>
    keysSorted kvs && opFieldOK kvs && hasArgs kvs &&
    kvs.attach.all (fun ⟨kv, _h⟩ =>
      if kv.1 = "args" then
        (match _hv : kv.2 with
         | .arr as => as.attach.all (fun ⟨a, _ha⟩ => isE a)
         | _ => false)
      else kv.1 == "op" || jwf kv.2)
  | _ => false
termination_by e => sizeOf e
decreasing_by
  have h1 := List.sizeOf_lt_of_mem _h
  have h2 := List.sizeOf_lt_of_mem _ha
  obtain ⟨k, v⟩ := kv
  simp only at _hv
  subst _hv
  simp only [Json.obj.sizeOf_spec, Prod.mk.sizeOf_spec, Json.arr.sizeOf_spec] at *
  omega

/-- The symbol table: the names a document declares (variables, parameters, species,
index names) and the parameter list of every template in scope. -/
structure Sym where
  names : List String := []
  templates : List (String × List String) := []

end Esm.Document.Math
