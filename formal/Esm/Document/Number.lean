import Esm.Document.Json
import Esm.Digits

/-!
# The canonical number spelling (CONFORMANCE §5.5.3.1)

* An integer prints plainly, `-` for a negative one.
* A decimal prints its digits positionally when its decimal exponent `e10` is in
  `[-4, 5]` (`0.000123456`, `999999.5`), and otherwise in scientific notation
  `d.f…e<exp>` with at least one fraction digit, a lowercase `e`, and `-` but never `+`
  on the exponent (`1.0e-9`, `1.0000005e6`).

`print` writes the spelling, `parse` reads a number token, and `parse_print` is the
round trip: parsing the printed spelling, followed by anything that does not continue a
number token, gives back the number and the rest.

`parse` reads any decimal spelling of a number, not only the canonical one, and
returns it in canonical form: `1.0` and `1.0e0` are the integer `1`, `0.0e10` is the
integer `0`, `2.50` is `2.5` (§5.5.3.1 rules 1 and 3). It rejects what has no
canonical form or is not a JSON number: an integer outside `Int64` (§5.5.3.1 rule 1),
and a leading zero (`007`, `01.5`). `parse_wf`: whatever `parse` returns is well
formed.
-/

namespace Esm.Document.Number

open JNum

/-! ## Digits -/

/-- The digit a digit character stands for. -/
def charDigit (c : Char) : Nat := c.toNat - 48

theorem digitChar_spec_fin : ∀ d : Fin 10,
    (digitChar d.val).isDigit = true ∧ charDigit (digitChar d.val) = d.val ∧
      digitChar d.val ≠ '-' ∧ digitChar d.val ≠ '.' ∧ digitChar d.val ≠ 'e' := by
  decide +kernel

theorem digitChar_spec {d : Nat} (h : d < 10) :
    (digitChar d).isDigit = true ∧ charDigit (digitChar d) = d ∧
      digitChar d ≠ '-' ∧ digitChar d ≠ '.' ∧ digitChar d ≠ 'e' :=
  digitChar_spec_fin ⟨d, h⟩

/-- The big-endian decimal digits of `n` (`[0]` for zero). -/
def natDigits (n : Nat) : List Nat := if n = 0 then [0] else decDigits n

theorem natDigits_spec (n : Nat) :
    natDigits n ≠ [] ∧ (∀ d ∈ natDigits n, d < 10) ∧ digitsVal (natDigits n) = n := by
  unfold natDigits
  split
  · subst n; simp [digitsVal]
  · exact ⟨fun h => ‹¬n = 0› ((decDigits_eq_nil_iff n).mp h), decDigits_lt n,
      foldl_decDigits n⟩

/-- More than one digit, the first of them `0`: a leading zero, which JSON forbids. -/
def leadZero (ip : List Nat) : Bool := 1 < ip.length && ip.head? == some 0

theorem leadZero_one (d : Nat) : leadZero [d] = false := rfl

theorem leadZero_natDigits (n : Nat) : leadZero (natDigits n) = false := by
  unfold natDigits leadZero
  split
  · rfl
  · simp [decDigits_head n ‹_›]

/-- The spelling of a natural number. -/
def printNat (n : Nat) : List Char := (natDigits n).map digitChar

/-- The spelling of an integer. -/
def printInt (z : Int) : List Char :=
  if z < 0 then '-' :: printNat z.natAbs else printNat z.natAbs

/-- The maximal run of digit characters at the front, as digits. -/
def readDigits : List Char → List Nat × List Char
  | [] => ([], [])
  | c :: r =>
    if c.isDigit then
      let p := readDigits r
      (charDigit c :: p.1, p.2)
    else ([], c :: r)

/-- `rest` does not start with a digit. -/
def NoDigit (rest : List Char) : Prop := ∀ c ∈ rest.head?, c.isDigit = false

theorem readDigits_print (ds : List Nat) (rest : List Char) (hd : ∀ d ∈ ds, d < 10)
    (hr : NoDigit rest) : readDigits (ds.map digitChar ++ rest) = (ds, rest) := by
  induction ds with
  | nil =>
    cases rest with
    | nil => rfl
    | cons c r =>
      have : c.isDigit = false := hr c rfl
      simp [readDigits, this]
  | cons d ds ih =>
    have hd0 := digitChar_spec (hd d (by simp))
    have ih' := ih (fun x hx => hd x (by simp [hx]))
    simp [readDigits, hd0.1, hd0.2.1, ih']

/-- A natural number token. -/
def parseNat (input : List Char) : Option (Nat × List Char) :=
  let p := readDigits input
  if p.1 = [] then none else some (digitsVal p.1, p.2)

/-- An integer token: an optional `-`, then digits. -/
def parseInt (input : List Char) : Option (Int × List Char) :=
  match input with
  | '-' :: r => (parseNat r).map fun p => (-(p.1 : Int), p.2)
  | _ => (parseNat input).map fun p => ((p.1 : Int), p.2)

theorem parseNat_print (n : Nat) (rest : List Char) (hr : NoDigit rest) :
    parseNat (printNat n ++ rest) = some (n, rest) := by
  obtain ⟨h1, h2, h3⟩ := natDigits_spec n
  simp [parseNat, printNat, readDigits_print _ _ h2 hr, h1, h3]

theorem printNat_head (n : Nat) : ∃ c t, printNat n = c :: t ∧ c.isDigit = true ∧
    c ≠ '-' ∧ c ≠ '.' ∧ c ≠ 'e' := by
  obtain ⟨h1, h2, -⟩ := natDigits_spec n
  unfold printNat
  cases h : natDigits n with
  | nil => exact absurd h h1
  | cons d ds =>
    have := digitChar_spec (h2 d (by simp [h]))
    exact ⟨_, _, rfl, this.1, this.2.2⟩

theorem parseInt_print (z : Int) (rest : List Char) (hr : NoDigit rest) :
    parseInt (printInt z ++ rest) = some (z, rest) := by
  unfold printInt
  split
  · simp only [List.cons_append, parseInt, parseNat_print _ _ hr, Option.map_some]
    congr 2; omega
  · obtain ⟨c, t, ht, -, hc, -⟩ := printNat_head z.natAbs
    have hp := parseNat_print z.natAbs rest hr
    rw [ht] at hp ⊢
    simp only [List.cons_append] at hp ⊢
    rw [parseInt]
    · simp only [hp, Option.map_some]; congr 2; omega
    · intro r h; cases h; exact hc rfl

/-! ## Decimals -/

/-- The fraction digits printed after the point: at least one. -/
def fracDigits (fp : List Nat) : List Nat := if fp = [] then [0] else fp

/-- The unsigned spelling of the decimal `d₁.d₂… × 10^e10`. -/
def decBody (ds : List Nat) (e10 : Int) : List Char :=
  if e10 < -4 ∨ 5 < e10 then
    match ds with
    | [] => []
    | d :: fp => (digitChar d :: '.' :: (fracDigits fp).map digitChar) ++ 'e' :: printInt e10
  else if e10 < 0 then
    '0' :: '.' :: (List.replicate (-e10 - 1).toNat 0 ++ ds).map digitChar
  else
    (ds.take (e10.toNat + 1) ++ List.replicate (e10.toNat + 1 - ds.length) 0).map digitChar ++
      '.' :: (fracDigits (ds.drop (e10.toNat + 1))).map digitChar

/-- The canonical spelling of a number (CONFORMANCE §5.5.3.1). -/
def print : JNum → List Char
  | .int z => printInt z
  | .dec neg ds e10 => (if neg then ['-'] else []) ++ decBody ds e10

/-- The decimal with digits `ds` (any leading or trailing zeros dropped) whose first
listed digit sits at decimal exponent `e10`. -/
def mkDec (neg : Bool) (ds : List Nat) (e10 : Int) : JNum :=
  let lead := (ds.takeWhile (· == 0)).length
  let core := ((ds.dropWhile (· == 0)).reverse.dropWhile (· == 0)).reverse
  .dec neg core (e10 - lead)

/-- After the fraction digits of a decimal: an optional `e` exponent. -/
def finishDec (neg : Bool) (ds : List Nat) (e10 : Int) (r : List Char) :
    Option (JNum × List Char) :=
  match r with
  | 'e' :: r4 => (parseInt r4).map fun x => (mkDec neg ds (e10 + x.1), x.2)
  | _ => some (mkDec neg ds e10, r)

theorem finishDec_noE (neg : Bool) (ds : List Nat) (e10 : Int) (r : List Char)
    (h : ∀ c ∈ r.head?, c ≠ 'e') : finishDec neg ds e10 r = some (mkDec neg ds e10, r) := by
  cases r with
  | nil => rfl
  | cons c t =>
    unfold finishDec; split
    · rename_i h'; simp at h'; exact absurd h'.1 (h c rfl)
    · rfl

/-- After the integer digits `ip`: a `.` and fraction digits make a decimal, anything
else ends an integer. -/
def afterInt (neg : Bool) (ip : List Nat) (r : List Char) : Option (JNum × List Char) :=
  match r with
  | '.' :: r2 =>
    let q := readDigits r2
    if q.1 = [] then none else finishDec neg (ip ++ q.1) (ip.length - 1) q.2
  | _ => some (.int (if neg then -(digitsVal ip : Int) else digitsVal ip), r)

/-- A number token as written: `-`?, digits with no leading zero, then either nothing
(an integer) or `.`, digits, and an optional `e` exponent (a decimal). Not yet in
canonical form (see `parse`). -/
def parseRaw (input : List Char) : Option (JNum × List Char) :=
  let s : Bool × List Char := match input with
    | '-' :: r => (true, r)
    | r => (false, r)
  let p := readDigits s.2
  if p.1 = [] then none else if leadZero p.1 then none else afterInt s.1 p.1 p.2

/-- The canonical form of a number read as written: a decimal whose digits are all
zero is the integer `0`, and an integral decimal in `Int64` is that integer
(§5.5.3.1 rules 1 and 3). -/
def canonize : JNum → JNum
  | .dec _ [] _ => .int 0
  | .dec neg (d :: ds) e10 =>
    match decInt? neg (d :: ds) e10 with
    | some z => if InInt64 z then .int z else .dec neg (d :: ds) e10
    | none => .dec neg (d :: ds) e10
  | n => n

/-- A number token, in canonical form; `none` for one that has none (an integer
outside `Int64`). -/
def parse (input : List Char) : Option (JNum × List Char) :=
  match parseRaw input with
  | some (n, r) => if (canonize n).wfb then some (canonize n, r) else none
  | none => none

/-- **What `parse` reads is well formed.** -/
theorem parse_wf {input rest : List Char} {n : JNum} (h : parse input = some (n, rest)) :
    n.WF := by
  unfold parse at h
  split at h
  · split at h
    · cases h; exact (JNum.wfb_iff _).mp ‹_›
    · cases h
  · cases h

/-- A well-formed number is already canonical. -/
theorem canonize_wf (n : JNum) (hn : n.WF) : canonize n = n := by
  match n with
  | .int z => rfl
  | .dec neg [] e10 => exact absurd rfl hn.1
  | .dec neg (d :: ds) e10 =>
    have hz := hn.2.2.2.2
    simp only [canonize]
    cases h : decInt? neg (d :: ds) e10 with
    | none => rfl
    | some z => simp [hz z h]

theorem afterInt_noDot (neg : Bool) (ip : List Nat) (r : List Char)
    (h : ∀ c ∈ r.head?, c ≠ '.') :
    afterInt neg ip r = some (.int (if neg then -(digitsVal ip : Int) else digitsVal ip), r) := by
  cases r with
  | nil => rfl
  | cons c t =>
    unfold afterInt; split
    · rename_i h'; simp at h'; exact absurd h'.1 (h c rfl)
    · rfl

/-- What may follow a number token: anything that does not start with a digit, `.` or
`e`. -/
def NumStop (rest : List Char) : Prop :=
  ∀ c ∈ rest.head?, c.isDigit = false ∧ c ≠ '.' ∧ c ≠ 'e'

theorem NumStop.noDigit {rest : List Char} (h : NumStop rest) : NoDigit rest :=
  fun c hc => (h c hc).1

/-! ### `mkDec` undoes the padding the printer adds -/

theorem takeWhile_zeros0 (l : List Nat) (h : l.head? ≠ some 0) :
    l.takeWhile (· == 0) = [] := by
  cases l with
  | nil => rfl
  | cons a l =>
    have : a ≠ 0 := fun e => h (by simp [e])
    simp [this]

theorem dropWhile_zeros0 (l : List Nat) (h : l.head? ≠ some 0) :
    l.dropWhile (· == 0) = l := by
  cases l with
  | nil => rfl
  | cons a l =>
    have : a ≠ 0 := fun e => h (by simp [e])
    simp [this]

theorem takeWhile_zeros (j : Nat) (l : List Nat) (h : l.head? ≠ some 0) :
    ((List.replicate j 0 ++ l).takeWhile (· == 0)).length = j := by
  induction j with
  | zero => simp [takeWhile_zeros0 l h]
  | succ j ih => simp [List.replicate_succ, takeWhile_zeros0 l h]

theorem dropWhile_zeros (j : Nat) (l : List Nat) (h : l.head? ≠ some 0) :
    (List.replicate j 0 ++ l).dropWhile (· == 0) = l := by
  induction j with
  | zero => simpa using dropWhile_zeros0 l h
  | succ j ih => simpa [List.replicate_succ] using ih

theorem mkDec_pad (neg : Bool) (j k : Nat) (ds : List Nat) (e10 : Int) (hne : ds ≠ [])
    (h1 : ds.head? ≠ some 0) (h2 : ds.getLast? ≠ some 0) :
    mkDec neg (List.replicate j 0 ++ ds ++ List.replicate k 0) e10 = .dec neg ds (e10 - j) := by
  have hh : (ds ++ List.replicate k 0).head? ≠ some 0 := by
    cases ds with
    | nil => exact absurd rfl hne
    | cons a l => simpa using h1
  have hl : ds.reverse.head? ≠ some 0 := by simpa [List.head?_reverse] using h2
  simp only [mkDec, List.append_assoc, takeWhile_zeros j _ hh, dropWhile_zeros j _ hh,
    List.reverse_append, List.reverse_replicate, dropWhile_zeros k _ hl, List.reverse_reverse]

/-! ### The round trip -/

/-- Parsing `-`? digits, followed by `rest`. -/
theorem parse_digits (neg : Bool) (ip : List Nat) (rest : List Char)
    (hip : ip ≠ []) (hi : ∀ d ∈ ip, d < 10) (hl : leadZero ip = false) (hr : NoDigit rest) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ rest)) = afterInt neg ip rest := by
  have hs : (match (if neg then ['-'] else []) ++ (ip.map digitChar ++ rest) with
      | '-' :: r => (true, r)
      | r => (false, r) : Bool × List Char) = (neg, ip.map digitChar ++ rest) := by
    cases neg
    · cases ip with
      | nil => exact absurd rfl hip
      | cons d l =>
        have := digitChar_spec (hi d (by simp))
        simp only [List.map_cons, List.nil_append, List.cons_append, Bool.false_eq_true,
          ite_false]
        split
        · rename_i h; simp at h; exact absurd h.1 this.2.2.1
        · rfl
    · rfl
  simp only [parseRaw, hs, readDigits_print _ _ hi hr, hip, hl, ite_false, Bool.false_eq_true]

/-- Parsing `-`? digits `.` digits, followed by `rest`. -/
theorem parse_shape (neg : Bool) (ip fp : List Nat) (rest : List Char)
    (hip : ip ≠ []) (hfp : fp ≠ []) (hi : ∀ d ∈ ip, d < 10) (hf : ∀ d ∈ fp, d < 10)
    (hl : leadZero ip = false) (hr : NoDigit rest) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ '.' :: (fp.map digitChar ++ rest))) =
      finishDec neg (ip ++ fp) (ip.length - 1) rest := by
  rw [parse_digits neg ip _ hip hi hl (fun c hc => by cases hc; decide)]
  simp only [afterInt, readDigits_print fp rest hf hr, hfp, ite_false]

/-- A decimal spelling whose digits normalize to `n`, followed by a number stop. -/
theorem parse_dec (neg : Bool) (ip fp : List Nat) (rest : List Char) (n : JNum)
    (hip : ip ≠ []) (hfp : fp ≠ []) (hi : ∀ d ∈ ip, d < 10) (hf : ∀ d ∈ fp, d < 10)
    (hl : leadZero ip = false) (hr : NumStop rest) (hm : mkDec neg (ip ++ fp) (ip.length - 1) = n) :
    parseRaw ((if neg then ['-'] else []) ++ (ip.map digitChar ++ '.' :: (fp.map digitChar ++ rest))) =
      some (n, rest) := by
  rw [parse_shape neg ip fp rest hip hfp hi hf hl hr.noDigit, finishDec_noE _ _ _ _
    (fun c hc => (hr c hc).2.2), hm]

theorem fracDigits_ne (fp : List Nat) : fracDigits fp ≠ [] := by
  unfold fracDigits; split <;> simp_all

theorem fracDigits_lt (fp : List Nat) (h : ∀ d ∈ fp, d < 10) : ∀ d ∈ fracDigits fp, d < 10 := by
  unfold fracDigits; split
  · simp
  · exact h

theorem parseRaw_print (n : JNum) (rest : List Char) (hn : n.WF) (hr : NumStop rest) :
    parseRaw (print n ++ rest) = some (n, rest) := by
  cases n with
  | int z =>
    -- An integer: digits not followed by `.`.
    obtain ⟨h1, h2, h3⟩ := natDigits_spec z.natAbs
    have hnd : ∀ c ∈ rest.head?, c ≠ '.' := fun c hc => (hr c hc).2.1
    have key := fun neg => parse_digits neg (natDigits z.natAbs) rest h1 h2
      (leadZero_natDigits _) hr.noDigit
    simp only [print, printInt, printNat]
    split
    · have k := key true
      rw [afterInt_noDot _ _ _ hnd, h3] at k
      simp only [ite_true, List.cons_append, List.nil_append] at k
      simp only [List.cons_append]
      rw [k]; congr 3; omega
    · have k := key false
      rw [afterInt_noDot _ _ _ hnd, h3] at k
      simp only [Bool.false_eq_true, ite_false, List.nil_append] at k
      rw [k]; congr 3; omega
  | dec neg ds e10 =>
    obtain ⟨hne, hd, hh, hl, -⟩ := hn
    rw [print, List.append_assoc]; unfold decBody
    by_cases hsci : e10 < -4 ∨ 5 < e10
    · -- scientific
      rw [ite_eq_left hsci]
      cases ds with
      | nil => exact absurd rfl hne
      | cons d fp =>
        have hd0 : d < 10 := hd d (by simp)
        have hfp : ∀ x ∈ fp, x < 10 := fun x hx => hd x (by simp [hx])
        have key := parse_shape neg [d] (fracDigits fp) ('e' :: (printInt e10 ++ rest))
          (by simp) (fracDigits_ne fp) (by simpa using hd0) (fracDigits_lt fp hfp)
          (leadZero_one d) (fun c hc => by cases hc; decide)
        simp only [List.map_cons, List.map_nil, List.cons_append, List.nil_append,
          List.append_assoc] at key ⊢
        rw [key]
        simp only [finishDec, parseInt_print _ _ hr.noDigit, Option.map_some,
          List.length_singleton]
        have : d :: fracDigits fp = List.replicate 0 0 ++ (d :: fp) ++
            List.replicate (if fp = [] then 1 else 0) 0 := by
          unfold fracDigits; split <;> simp_all
        rw [this, mkDec_pad _ _ _ _ _ hne hh hl]
        simp
    · rw [ite_eq_right hsci]
      by_cases hneg : e10 < 0
      · -- positional, e10 < 0
        rw [ite_eq_left hneg]
        have hall : ∀ x ∈ List.replicate (-e10 - 1).toNat 0 ++ ds, x < 10 := by
          intro x hx; simp only [List.mem_append, List.mem_replicate] at hx
          rcases hx with hx | hx
          · omega
          · exact hd x hx
        have h0 : digitChar 0 = '0' := by decide +kernel
        have key := parse_dec neg [0] (List.replicate (-e10 - 1).toNat 0 ++ ds) rest (.dec neg ds e10)
          (by simp) (by simp [hne]) (by simp) hall (leadZero_one 0) hr (by
            have : [0] ++ (List.replicate (-e10 - 1).toNat 0 ++ ds) =
                List.replicate (-e10).toNat 0 ++ ds ++ List.replicate 0 0 := by
              rw [← List.append_assoc, List.singleton_append, ← List.replicate_succ]
              simp only [List.replicate_zero, List.append_nil]
              congr 2; omega
            rw [this, mkDec_pad _ _ _ _ _ hne hh hl]; congr 1; simp; omega)
        simp only [List.map_cons, List.map_nil, List.cons_append, List.nil_append, h0] at key
        simpa only [List.cons_append, List.append_assoc] using key
      · -- positional, e10 ≥ 0
        rw [ite_eq_right hneg]
        have hip : ds.take (e10.toNat + 1) ++ List.replicate (e10.toNat + 1 - ds.length) 0 ≠ [] := by
          cases ds with
          | nil => exact absurd rfl hne
          | cons a l => simp
        have hlz : leadZero (ds.take (e10.toNat + 1) ++
            List.replicate (e10.toNat + 1 - ds.length) 0) = false := by
          cases ds with
          | nil => exact absurd rfl hne
          | cons a l =>
            have ha : a ≠ 0 := fun e => hh (by simp [e])
            simp [leadZero, ha]
        have hlen : (ds.take (e10.toNat + 1) ++
            List.replicate (e10.toNat + 1 - ds.length) 0).length = e10.toNat + 1 := by
          simp; omega
        have key := parse_dec neg (ds.take (e10.toNat + 1) ++
            List.replicate (e10.toNat + 1 - ds.length) 0)
          (fracDigits (ds.drop (e10.toNat + 1))) rest (.dec neg ds e10) hip (fracDigits_ne _)
          (by intro x hx; simp only [List.mem_append, List.mem_replicate] at hx
              rcases hx with hx | hx
              · exact hd x (List.mem_of_mem_take hx)
              · omega)
          (fracDigits_lt _ (fun x hx => hd x (List.mem_of_mem_drop hx))) hlz hr (by
            rw [hlen]
            have : ds.take (e10.toNat + 1) ++ List.replicate (e10.toNat + 1 - ds.length) 0 ++
                fracDigits (ds.drop (e10.toNat + 1)) = List.replicate 0 0 ++ ds ++
                  List.replicate (if ds.length ≤ e10.toNat + 1
                    then e10.toNat + 1 - ds.length + 1 else 0) 0 := by
              unfold fracDigits
              by_cases hc : ds.length ≤ e10.toNat + 1
              · have h' : ds.drop (e10.toNat + 1) = [] := List.drop_eq_nil_of_le hc
                rw [List.take_of_length_le hc, h', ite_eq_left rfl, ite_eq_left hc]
                simp [List.replicate_succ']
              · have h' : ds.drop (e10.toNat + 1) ≠ [] := by simp; omega
                rw [ite_eq_right h', ite_eq_right hc]
                have : e10.toNat + 1 - ds.length = 0 := by omega
                simp [this]
            rw [this, mkDec_pad _ _ _ _ _ hne hh hl]; congr 1; omega)
        simpa only [List.append_assoc, List.cons_append] using key

/-- **The number round trip.** -/
theorem parse_print (n : JNum) (rest : List Char) (hn : n.WF) (hr : NumStop rest) :
    parse (print n ++ rest) = some (n, rest) := by
  rw [parse, parseRaw_print n rest hn hr]
  simp only [canonize_wf n hn, (JNum.wfb_iff n).mpr hn, ite_true]

/-! ## Canonical form of what `parse` reads -/

example : parse "1.0".toList = some (.int 1, []) := by decide +kernel
example : parse "1.0e0".toList = some (.int 1, []) := by decide +kernel
example : parse "0.0e10".toList = some (.int 0, []) := by decide +kernel
example : parse "-0.0".toList = some (.int 0, []) := by decide +kernel
example : parse "2.50".toList = some (.dec false [2, 5] 0, []) := by decide +kernel
example : parse "1.0e20".toList = some (.dec false [1] 20, []) := by decide +kernel
example : parse "9223372036854775807".toList = some (.int 9223372036854775807, []) := by
  decide +kernel
example : parse "9223372036854775808".toList = none := by decide +kernel
example : parse "007".toList = none := by decide +kernel
example : parse "01.5".toList = none := by decide +kernel
example : parse "0.5".toList = some (.dec false [5] (-1), []) := by decide +kernel

/-- The first character of a printed number: `-` or a digit. -/
def NumHead (c : Char) : Prop := c = '-' ∨ ∃ d, d < 10 ∧ c = digitChar d

/-- A fact about every possible first character of a number, checked character by
character. -/
theorem NumHead.of_fin {P : Char → Prop} (h1 : P '-') (h2 : ∀ d : Fin 10, P (digitChar d.val))
    {c : Char} (hc : NumHead c) : P c := by
  rcases hc with rfl | ⟨d, hd, rfl⟩
  · exact h1
  · exact h2 ⟨d, hd⟩

/-- A printed number starts with `-` or a digit. -/
theorem print_head (n : JNum) (hn : n.WF) : ∃ c t, print n = c :: t ∧ NumHead c := by
  cases n with
  | int z =>
    simp only [print, printInt]
    split
    · exact ⟨_, _, rfl, Or.inl rfl⟩
    · obtain ⟨h1, h2, -⟩ := natDigits_spec z.natAbs
      unfold printNat
      cases h : natDigits z.natAbs with
      | nil => exact absurd h h1
      | cons d ds => exact ⟨_, _, rfl, Or.inr ⟨d, h2 d (by simp [h]), rfl⟩⟩
  | dec neg ds e10 =>
    obtain ⟨hne, hd, -⟩ := hn
    cases neg
    · simp only [print, Bool.false_eq_true, ite_false, List.nil_append]
      unfold decBody
      cases ds with
      | nil => exact absurd rfl hne
      | cons d fp =>
        have := hd d (by simp)
        split
        · exact ⟨_, _, rfl, Or.inr ⟨d, this, rfl⟩⟩
        · split
          · exact ⟨_, _, rfl, Or.inr ⟨0, by decide, by decide⟩⟩
          · cases h : e10.toNat with
            | zero => exact ⟨digitChar d, _, by simp; rfl, Or.inr ⟨d, this, rfl⟩⟩
            | succ k => exact ⟨digitChar d, _, by simp; rfl, Or.inr ⟨d, this, rfl⟩⟩
    · exact ⟨_, _, rfl, Or.inl rfl⟩

theorem decBody_head (ds : List Nat) (e10 : Int) (hne : ds ≠ []) (hd : ∀ d ∈ ds, d < 10) :
    ∃ d t, d < 10 ∧ decBody ds e10 = digitChar d :: t := by
  unfold decBody
  cases ds with
  | nil => exact absurd rfl hne
  | cons d fp =>
    have := hd d (by simp)
    split
    · exact ⟨d, _, this, rfl⟩
    · split
      · have h0 : digitChar 0 = '0' := by decide
        exact ⟨0, _, by decide, by rw [h0]⟩
      · cases h : e10.toNat with
        | zero => exact ⟨d, _, this, by simp; rfl⟩
        | succ k => exact ⟨d, _, this, by simp; rfl⟩

/-- After a leading `-`, a printed number continues with a digit. -/
theorem print_neg_head (n : JNum) (hn : n.WF) (t : List Char) (h : print n = '-' :: t) :
    ∃ d t', d < 10 ∧ t = digitChar d :: t' := by
  cases n with
  | int z =>
    obtain ⟨h1, h2, -⟩ := natDigits_spec z.natAbs
    simp only [print, printInt, printNat] at h
    cases hn' : natDigits z.natAbs with
    | nil => exact absurd hn' h1
    | cons d ds =>
      have hd := h2 d (by simp [hn'])
      rw [hn'] at h
      split at h
      · simp only [List.cons.injEq] at h
        exact ⟨d, _, hd, h.2.symm⟩
      · simp only [List.map_cons, List.cons.injEq] at h
        exact absurd h.1 (digitChar_spec hd).2.2.1
  | dec neg ds e10 =>
    obtain ⟨hne, hd, -⟩ := hn
    obtain ⟨d, t', hd', ht⟩ := decBody_head ds e10 hne hd
    cases neg
    · simp only [print, Bool.false_eq_true, ite_false, List.nil_append, ht,
        List.cons.injEq] at h
      exact absurd h.1 (digitChar_spec hd').2.2.1
    · simp only [print, ite_true, List.cons_append, List.nil_append, List.cons.injEq] at h
      exact ⟨d, t', hd', h.2 ▸ ht⟩

/-! ## The CONFORMANCE §5.5.3.1 probe table -/

example : print (.dec false [1] (-9)) = "1.0e-9".toList := by decide +kernel
example : print (.dec false [1, 5] (-5)) = "1.5e-5".toList := by decide +kernel
example : print (.dec false [1, 2, 3, 4, 5, 6] (-4)) = "0.000123456".toList := by decide +kernel
example : print (.dec false [2, 5] 0) = "2.5".toList := by decide +kernel
example : print (.dec false [9, 9, 9, 9, 9, 9, 5] 5) = "999999.5".toList := by decide +kernel
example : print (.dec false [1, 0, 0, 0, 0, 0, 0, 5] 6) = "1.0000005e6".toList := by decide +kernel
example : print (.dec false [1, 2, 3, 4, 5, 6, 7, 8, 9, 2, 5] 8) = "1.2345678925e8".toList := by
  decide +kernel
/-- `0.0` is the integer `0` (rule 1). -/
example : print (.int 0) = "0".toList := by decide +kernel
example : print (.int (-42)) = "-42".toList := by decide +kernel
example : print (.dec true [7, 0, 5] 25) = "-7.05e25".toList := by decide +kernel

end Esm.Document.Number
