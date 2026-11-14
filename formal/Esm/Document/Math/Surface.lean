import Esm.Document.Math.Token

/-!
# Pieces the LaTeX and Typst spellings share

The two surfaces (`Esm.Document.Math.Latex`, `Esm.Document.Math.Typst`) differ in their
keyword spellings and lexers, but read numbers alike: a number in its JSON spelling, or a
scientific literal `mantissa × 10^exponent`, where only the spelling of `× 10^` and of
the exponent's brackets differs. `lexNum` takes that difference as a parameter
(`sciExp`, which reads the tail after the mantissa), so the literal rule is written and
proved once:

* the tail is read with any amount of white space (none included) between its parts,
  so spacing never changes what is read;
* a mantissa (with or without a decimal point) followed by a complete tail is one
  literal; a tail whose exponent is not an integer (`10^{n}`) leaves the number alone,
  and the rest reads as an ordinary product.

A leading `-` belongs to the number only when its value is below zero (`lexSigned`):
`-0` reads as a minus sign and `0`. Whether a negative literal is a literal or a binary
minus depends on what precedes it, which the parser decides (`Esm.Document.Math.Parse`,
`addLoop`).
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## Literal prefixes -/

/-- Strip a literal prefix. -/
def dropP : List Char → List Char → Option (List Char)
  | [], cs => some cs
  | p :: ps, c :: cs => if p = c then dropP ps cs else none
  | _ :: _, [] => none

theorem dropP_append (p rest : List Char) : dropP p (p ++ rest) = some rest := by
  induction p with
  | nil => rfl
  | cons c p ih => simp [dropP, ih]

/-! ## Spacing -/

/-- Binary operators, spaced on both sides. -/
def isBin : Tok → Bool
  | .kw k => match k with
    | .plus | .eq | .ne | .lt | .gt | .le | .ge | .land | .lor | .cdot | .times | .amp | .nl | .inn => true
    | _ => false
  | _ => false

/-! ## Numbers -/

/-- The mantissa (with its sign) and exponent of a number printed in scientific
notation. -/
def sciSplit : JNum → Option (List Char × Int)
  | .dec neg (d :: fp) e10 =>
    if e10 < -4 ∨ 5 < e10 then
      some ((if neg then ['-'] else []) ++ Esm.digitChar d :: '.' :: (Number.fracDigits fp).map Esm.digitChar, e10)
    else none
  | _ => none

/-- A number below zero. -/
def negNum : JNum → Bool
  | .int z => decide (z < 0)
  | .dec neg _ _ => neg

/-- The value of a mantissa (as `Number.parseRaw` reads it, an integer or a decimal)
times `10^z`, in canonical form; `none` for a value with no canonical form. -/
def sciNum (n0 : JNum) (z : Int) : Option JNum :=
  let m := match n0 with
    | .dec neg ds e => Number.canonize (.dec neg ds (e + z))
    | .int i =>
      Number.canonize (Number.mkDec (decide (i < 0)) (Number.natDigits i.natAbs)
        ((Number.natDigits i.natAbs).length - 1 + z))
  if m.wfb then some m else none

/-- A number: its JSON spelling, or a decimal mantissa followed by a scientific tail that
`sciExp` reads (returning the exponent and what follows). The token ends where the number
as written ends (`Number.parseRaw`); its value is the canonical form. -/
def lexNum (sciExp : List Char → Option (Int × List Char)) (cs : List Char) :
    Option (Tok × List Char) :=
  match Number.parseRaw cs with
  | none => none
  | some (n0, r) =>
    let plain := (Number.parse cs).map fun p => (Tok.num p.1, p.2)
    match sciExp r with
    | some (z, r3) =>
      match sciNum n0 z with
      | some m => some (.num m, r3)
      | none => plain
    | none => plain

/-- A number at the front of the input, where `-` starts it only when the value is below
zero (otherwise the `-` is a minus sign of its own). -/
def lexSigned (sciExp : List Char → Option (Int × List Char)) (cs : List Char) :
    Option (Tok × List Char) :=
  match cs with
  | '-' :: r =>
    match lexNum sciExp cs with
    | some (.num m, r') => if negNum m then some (.num m, r') else some (.kw .minus, r)
    | _ => none
  | _ => lexNum sciExp cs

/-! ## Reading numbers back -/

/-- A number in its JSON spelling, before a tail that is not scientific. -/
theorem lexNum_plain (sciExp : List Char → Option (Int × List Char)) (n : JNum) (hn : n.WF)
    (X : List Char) (hX : Number.NumStop X) (hs : sciExp X = none) :
    lexNum sciExp (Number.print n ++ X) = some (.num n, X) := by
  unfold lexNum
  rw [Number.parseRaw_print n X hn hX]
  simp only
  rw [hs]
  simp only
  rw [Number.parse_print n X hn hX]
  rfl

theorem sciNum_mkDec (neg : Bool) (ds : List Nat) (E z : Int) :
    sciNum (Number.mkDec neg ds E) z =
      let m := Number.canonize (Number.mkDec neg ds (E + z))
      if m.wfb then some m else none := by
  have e : ∀ (a b c : Int), a - b + c = a + c - b := by intros; omega
  simp only [Number.mkDec, sciNum, e]
  rfl

/-- A number in scientific spelling: its mantissa, then a tail `sciExp` reads as its
exponent. -/
theorem lexNum_sci (sciExp : List Char → Option (Int × List Char)) (n : JNum) (hn : n.WF)
    (m : List Char) (e : Int) (hsp : sciSplit n = some (m, e)) (T X : List Char)
    (hT : sciExp T = some (e, X)) (hTh : ∀ c ∈ T.head?, c.isDigit = false ∧ c ≠ 'e') :
    lexNum sciExp (m ++ T) = some (.num n, X) := by
  unfold sciSplit at hsp
  split at hsp
  · rename_i neg d fp e10
    split at hsp
    · rename_i hout
      simp only [Option.some.injEq, Prod.mk.injEq] at hsp
      obtain ⟨rfl, rfl⟩ := hsp
      have hn' := hn
      obtain ⟨-, hlt, -⟩ := hn'
      have hd : d < 10 := hlt d (by simp)
      have hfp : ∀ x ∈ Number.fracDigits fp, x < 10 :=
        Number.fracDigits_lt fp (fun x hx => hlt x (by simp [hx]))
      -- the mantissa before the tail
      have hp := Number.parse_shape neg [d] (Number.fracDigits fp) T (by simp) (Number.fracDigits_ne fp)
        (by simpa using hd) hfp (Number.leadZero_one d) (fun c hc => (hTh c hc).1)
      rw [Number.finishDec_noE _ _ _ _ (fun c hc => (hTh c hc).2)] at hp
      -- the mantissa before `e` and the exponent: the printed spelling of `n`
      have hq := Number.parse_shape neg [d] (Number.fracDigits fp) ('e' :: Number.printInt e10)
        (by simp) (Number.fracDigits_ne fp) (by simpa using hd) hfp (Number.leadZero_one d)
        (fun c hc => by simp at hc; subst hc; decide)
      have hN := Number.parse_print (.dec neg (d :: fp) e10) [] hn (fun c hc => by simp at hc)
      simp only [Number.print, Number.decBody, hout, ↓reduceIte, List.append_nil] at hN
      unfold Number.parse at hN
      have e1 : (if neg = true then ['-'] else []) ++ (Esm.digitChar d :: '.' ::
            (Number.fracDigits fp).map Esm.digitChar ++ 'e' :: Number.printInt e10) =
          (if neg = true then ['-'] else []) ++ (List.map Esm.digitChar [d] ++ '.' ::
            (List.map Esm.digitChar (Number.fracDigits fp) ++ 'e' :: Number.printInt e10)) := by simp
      rw [e1, hq] at hN
      simp only [Number.finishDec] at hN
      rw [show Number.printInt e10 = Number.printInt e10 ++ [] by simp,
        Number.parseInt_print e10 [] (fun c hc => by simp at hc)] at hN
      simp only [Option.map_some] at hN
      split at hN
      · rename_i hw
        simp only [Option.some.injEq, Prod.mk.injEq] at hN
        obtain ⟨hc, -⟩ := hN
        have e2 : (if neg = true then ['-'] else []) ++ Esm.digitChar d :: '.' ::
              (Number.fracDigits fp).map Esm.digitChar ++ T =
            (if neg = true then ['-'] else []) ++ (List.map Esm.digitChar [d] ++ '.' ::
              (List.map Esm.digitChar (Number.fracDigits fp) ++ T)) := by simp
        unfold lexNum
        rw [e2, hp]
        simp only
        rw [hT]
        simp only
        rw [sciNum_mkDec]
        simp only [hc] at hw ⊢
        simp [hw]
      · simp at hN
    · cases hsp
  · cases hsp

theorem print_neg {n : JNum} (hn : n.WF) {t : List Char} (h : Number.print n = '-' :: t) :
    negNum n = true := by
  cases n with
  | int z =>
    simp only [Number.print, Number.printInt] at h
    split at h
    · simp [negNum, *]
    · exfalso
      obtain ⟨c, t', ht, -, hc, -⟩ := Number.printNat_head z.natAbs
      rw [ht] at h
      simp only [List.cons.injEq] at h
      exact hc h.1
  | dec neg ds e10 =>
    cases neg
    · exfalso
      obtain ⟨hne, hd, -⟩ := hn
      obtain ⟨d, t', hd', ht⟩ := Number.decBody_head ds e10 hne hd
      simp only [Number.print, Bool.false_eq_true, ite_false, List.nil_append, ht,
        List.cons.injEq] at h
      exact (Number.digitChar_spec hd').2.2.1 h.1
    · rfl

theorem sciSplit_neg {n : JNum} (hn : n.WF) {m : List Char} {e : Int} (hs : sciSplit n = some (m, e))
    {T r : List Char} (h : m ++ T = '-' :: r) : negNum n = true := by
  unfold sciSplit at hs
  split at hs
  · rename_i neg d fp e10
    split at hs
    · simp only [Option.some.injEq, Prod.mk.injEq] at hs
      obtain ⟨rfl, rfl⟩ := hs
      cases neg
      · exfalso
        obtain ⟨-, hlt, -⟩ := hn
        simp only [Bool.false_eq_true, ↓reduceIte, List.nil_append, List.cons_append,
          List.cons.injEq] at h
        exact (Number.digitChar_spec (hlt d (by simp))).2.2.1 h.1
      · rfl
    · cases hs
  · cases hs

/-- A number spelled `N` reads back with its sign: a spelling that starts with `-` is
of a negative number. -/
theorem lexSigned_of (sciExp : List Char → Option (Int × List Char)) (N X : List Char) (n : JNum)
    (hN : N ≠ []) (hneg : ∀ r, N = '-' :: r → negNum n = true)
    (h : lexNum sciExp (N ++ X) = some (.num n, X)) : lexSigned sciExp (N ++ X) = some (.num n, X) := by
  unfold lexSigned
  split
  · rename_i r heq
    obtain ⟨c, t, rfl⟩ := List.exists_cons_of_ne_nil hN
    simp only [List.cons_append, List.cons.injEq] at heq
    obtain ⟨rfl, -⟩ := heq
    rw [h]
    simp [hneg t rfl]
  · exact h

end Esm.Document.Math
