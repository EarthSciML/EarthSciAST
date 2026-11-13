import Esm.Units.Canonical

/-!
# Typeset unit spellings: LaTeX and Typst, with no unit package

A `const` with units prints in a document as the number, a thin space, then the
canonical unit (`Esm.Document.Notation`). This module gives the two typeset
forms of a canonical factor list (`CanonFactors`, `Esm.Units.Canonical`), a
parser for each, and the round-trip theorems.

**LaTeX** (`latex`): the canonical spelling's layout inside `\mathrm{…}`.
The numerator factors are joined by a thin space `\,`, a denominator follows
`/`, parenthesized when it has more than one factor; an exponent is a braced
superscript `^{3}` or `^{1/3}` (braces are required: `^12` would raise only
the `1`). Inside `\mathrm{}` an underscore is a subscript and `%` starts a
comment, so a symbol's `_` is written `\_` and its `%` is written `\%`. So
`J/(K*mol)` is `\mathrm{J/(K\,mol)}`, `short_ton/yr` is `\mathrm{short\_ton/yr}`.

**Typst** (`typst`): one `upright("sym")^(exp)` per factor, with its SIGNED
exponent and no `/`: the positive-exponent factors, then the negative ones, each
group in symbol order (the order the canonical spelling reads in). The exponent is omitted when it is 1, is
`^3` for a positive integer, `^(-1)` for a negative one and `^(1\/3)` or
`^(-1\/3)` for a non-integer (`\/` is Typst's literal slash; a bare `/` in
math would build a fraction). Factors are separated by ` thin `: Typst math
sets two adjacent `upright` texts with no space between them (`cm³molec⁻¹`),
so the thin space is what keeps the factors apart. Symbols are `%` or runs of
`[A-Za-z0-9_]`, so no character in a Typst string needs escaping. The
dimensionless unit is `1` in both forms.

Theorems: `parseLatex_latex` and `parseTypst_typst`, over every canonical factor
list.
-/

namespace Esm.Units

/-! ## Shared parsing pieces -/

/-- Strip a literal prefix. -/
def dropPfx : List Char → List Char → Option (List Char)
  | [], cs => some cs
  | p :: ps, c :: cs => if p = c then dropPfx ps cs else none
  | _ :: _, [] => none

theorem dropPfx_append (p rest : List Char) : dropPfx p (p ++ rest) = some rest := by
  induction p with
  | nil => rfl
  | cons c p ih => simp [dropPfx, ih]

/-- A run of digits, read as a natural number. -/
def pDigits (cs : List Char) : Option (ℕ × List Char) :=
  let p := cs.span isDigitC
  if p.1 = [] then none else some (digitsVal p.1, p.2)

/-- What may follow a digit run without extending it. -/
def NoDigitHead (rest : List Char) : Prop := ∀ c r, rest = c :: r → isDigitC c = false

theorem pDigits_digs (n : ℕ) (hn : 0 < n) (rest : List Char) (hr : NoDigitHead rest) :
    pDigits (digs n ++ rest) = some (n, rest) := by
  have hs : (digs n ++ rest).span isDigitC = (digs n, rest) :=
    span_append isDigitC (digs n) rest (digs_isDigit n) hr
  simp only [pDigits, hs]
  simp [digs_ne_nil n hn, digitsVal_digs]

/-- Items printed by `pr`, joined by `sep`. -/
def joinWith (pr : Factor → List Char) (sep : List Char) : List Factor → List Char
  | [] => []
  | f :: r => pr f ++ r.flatMap (fun g => sep ++ pr g)

theorem joinWith_cons_cons (pr : Factor → List Char) (sep : List Char) (f g : Factor)
    (r : List Factor) :
    joinWith pr sep (f :: g :: r) = pr f ++ (sep ++ joinWith pr sep (g :: r)) := by
  simp [joinWith, List.flatMap_cons, List.append_assoc]

/-- Items read by `pf`, separated by `sep`; at least one. -/
def pSepBy (pf : List Char → Option (Factor × List Char)) (sep : List Char) :
    ℕ → List Char → Option (List Factor × List Char)
  | 0, _ => none
  | n + 1, cs =>
    match pf cs with
    | none => none
    | some (f, r) =>
      match dropPfx sep r with
      | none => some ([f], r)
      | some r' =>
        match pSepBy pf sep n r' with
        | none => none
        | some (fs, r'') => some (f :: fs, r'')

/-- Reading back a joined list: each item reads back before anything satisfying
`Stop`, the separator is such a thing, and the list ends before something that is
not a separator. -/
theorem pSepBy_joinWith (pf : List Char → Option (Factor × List Char)) (pr : Factor → List Char)
    (sep : List Char) (P : Factor → Prop) (Stop : List Char → Prop)
    (hpf : ∀ f, P f → ∀ rest, Stop rest → pf (pr f ++ rest) = some (f, rest))
    (hsep : ∀ x, Stop (sep ++ x)) :
    ∀ (fs : List Factor) (f : Factor) (rest : List Char), (∀ g ∈ f :: fs, P g) → Stop rest →
      dropPfx sep rest = none → ∀ n, fs.length < n →
      pSepBy pf sep n (joinWith pr sep (f :: fs) ++ rest) = some (f :: fs, rest) := by
  intro fs
  induction fs with
  | nil =>
    intro f rest hP hS hD n hn
    obtain ⟨j, rfl⟩ : ∃ j, n = j + 1 := ⟨n - 1, by simp at hn; omega⟩
    simp [pSepBy, joinWith, hpf f (hP f (by simp)) rest hS, hD]
  | cons g fs ih =>
    intro f rest hP hS hD n hn
    obtain ⟨j, rfl⟩ : ∃ j, n = j + 1 := ⟨n - 1, by simp at hn; omega⟩
    have hrest := ih g rest (fun x hx => hP x (by simp_all)) hS hD j (by simp at hn; omega)
    rw [joinWith_cons_cons, List.append_assoc, List.append_assoc, pSepBy,
      hpf f (hP f (by simp)) _ (hsep _)]
    simp only [dropPfx_append, hrest]

/-! ## LaTeX -/

/-- A symbol's characters with `_` and `%` escaped. -/
def latexSym : List Char → List Char
  | [] => []
  | c :: cs => (if c = '_' ∨ c = '%' then ['\\', c] else [c]) ++ latexSym cs

/-- A positive exponent as a braced superscript (nothing for 1). -/
def latexExp (q : ℚ) : List Char :=
  if q = 1 then []
  else if q.den = 1 then '^' :: '{' :: digs q.num.natAbs ++ ['}']
  else '^' :: '{' :: digs q.num.natAbs ++ '/' :: digs q.den ++ ['}']

/-- One factor, with the absolute value of its exponent. -/
def latexFactor (f : Factor) : List Char := latexSym f.1.toList ++ latexExp |f.2|

def latexSep : List Char := ['\\', ',']

/-- The body of `\mathrm{…}`. -/
def latexBody (l : List Factor) : List Char :=
  let num := if numFactors l = [] then ['1'] else joinWith latexFactor latexSep (numFactors l)
  match denFactors l with
  | [] => num
  | [g] => num ++ '/' :: latexFactor g
  | den => num ++ '/' :: '(' :: (joinWith latexFactor latexSep den ++ [')'])

def mathrmOpen : List Char := "\\mathrm{".toList

/-- The LaTeX form of a canonical factor list. -/
def latex (l : List Factor) : String := String.ofList (mathrmOpen ++ latexBody l ++ ['}'])

/-- Read a symbol: identifier characters, `%`, and the escapes `\_`, `\%`. -/
def pLSym : List Char → List Char × List Char
  | [] => ([], [])
  | c :: cs =>
    if isIdent c ∨ c = '%' then let p := pLSym cs; (c :: p.1, p.2)
    else if c = '\\' then
      match cs with
      | d :: cs' => if d = '_' ∨ d = '%' then let p := pLSym cs'; (d :: p.1, p.2) else ([], c :: cs)
      | [] => ([], [c])
    else ([], c :: cs)

/-- Read a braced superscript, or nothing (exponent 1). -/
def pLExp : List Char → Option (ℚ × List Char)
  | '^' :: '{' :: cs =>
    match pDigits cs with
    | some (p, '}' :: r) => some ((p : ℚ), r)
    | some (p, '/' :: r) =>
      match pDigits r with
      | some (d, '}' :: r') => some ((p : ℚ) / d, r')
      | _ => none
    | _ => none
  | cs => some (1, cs)

def pLFactor (cs : List Char) : Option (Factor × List Char) :=
  let p := pLSym cs
  if p.1 = [] then none
  else
    match pLExp p.2 with
    | some (q, r) => some ((String.ofList p.1, q), r)
    | none => none

/-- Read a LaTeX denominator (after the `/`): one factor, or a parenthesized list. -/
def pLDen (r : List Char) : Option (List Factor) :=
  if r.head? = some '(' then
    match pSepBy pLFactor latexSep r.tail.length r.tail with
    | some (den, [')']) => some den
    | _ => none
  else
    match pSepBy pLFactor latexSep r.length r with
    | some ([g], []) => some [g]
    | _ => none

/-- Read a LaTeX unit back to its two-sided factor list. -/
def parseLatex (s : String) : Option (List Factor) :=
  match dropPfx mathrmOpen s.toList with
  | none => none
  | some body =>
    if body.getLast? = some '}' then
      let b := body.dropLast
      match pSepBy pLFactor latexSep b.length b with
      | some (num, rest) =>
        let num' := if num = [("1", 1)] then [] else num
        match rest with
        | [] => some num'
        | c :: r =>
          if c = '/' then (pLDen r).map fun den => num' ++ den.map fun f => (f.1, -f.2)
          else none
      | none => none
    else none

/-! ### The LaTeX round trip -/

theorem length_joinWith (pr : Factor → List Char) (sep : List Char) (fs : List Factor)
    (hpr : ∀ f ∈ fs, pr f ≠ []) : fs.length ≤ (joinWith pr sep fs).length := by
  cases fs with
  | nil => simp [joinWith]
  | cons f r =>
    have h1 : 1 ≤ (pr f).length := List.length_pos_iff.mpr (hpr f (by simp))
    have h2 : r.length ≤ (r.flatMap (fun g => sep ++ pr g)).length := by
      have hr : ∀ g ∈ r, pr g ≠ [] := fun g hg => hpr g (by simp [hg])
      clear hpr h1
      induction r with
      | nil => simp
      | cons g r ih =>
        have := List.length_pos_iff.mpr (hr g (by simp))
        have := ih (fun x hx => hr x (by simp [hx]))
        simp only [List.flatMap_cons, List.length_append, List.length_cons]; omega
    simp only [joinWith, List.length_append, List.length_cons]; omega

theorem joinWith_map (pr : Factor → List Char) (sep : List Char) (g : Factor → Factor)
    (fs : List Factor) : joinWith pr sep (fs.map g) = joinWith (pr ∘ g) sep fs := by
  cases fs with
  | nil => rfl
  | cons f r => simp [joinWith, List.flatMap_map]

/-- Characters a symbol may contain. -/
def SymChars (cs : List Char) : Prop := cs ≠ [] ∧ ∀ c ∈ cs, isIdent c = true ∨ c = '%'

theorem symChars_of_symOK (s : String) (h : symOK s = true) : SymChars s.toList := by
  by_cases hp : s = "%"
  · subst hp; refine ⟨by simp, by simp⟩
  · have h2 : symRunB s = true := by
      simp only [symOK, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at h
      exact h.1.resolve_left hp
    simp only [symRunB, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true,
      List.all_eq_true] at h2
    exact ⟨by simpa using h2.1.1, fun c hc => Or.inl (h2.1.2 c hc)⟩

theorem symOK_ne_one (s : String) (h : symOK s = true) : s ≠ "1" := by
  rintro rfl; simp [symOK, symRunB, isDigitC] at h

/-- What stops a LaTeX symbol run: not a symbol character, not an escape. -/
def LStop (rest : List Char) : Prop := pLSym rest = ([], rest) ∧ ∀ r, rest ≠ '^' :: r

theorem pLSym_latexSym (cs rest : List Char) (hc : ∀ c ∈ cs, isIdent c = true ∨ c = '%')
    (hr : pLSym rest = ([], rest)) : pLSym (latexSym cs ++ rest) = (cs, rest) := by
  induction cs with
  | nil => simpa [latexSym] using hr
  | cons c cs ih =>
    have ih := ih (fun x hx => hc x (by simp [hx]))
    have hc' := hc c (by simp)
    simp only [latexSym, List.append_assoc]
    by_cases he : c = '_' ∨ c = '%'
    · simp only [he, ite_true, List.cons_append, List.nil_append]
      simp [pLSym, isIdent, isAlphaC, isDigitC, he, ih]
    · simp only [he, ite_false, List.cons_append, List.nil_append]
      rw [pLSym.eq_def]; dsimp only; rw [ite_eq_left hc', ih]

theorem pLExp_stop (rest : List Char) (h : ∀ r, rest ≠ '^' :: r) : pLExp rest = some (1, rest) := by
  unfold pLExp
  split
  · rename_i cs; exact absurd rfl (h ('{' :: cs))
  · rfl

/-- A positive exponent reads back. -/
theorem pLExp_latexExp (q : ℚ) (hq : 0 < q) (rest : List Char) (hr : ∀ r, rest ≠ '^' :: r) :
    pLExp (latexExp q ++ rest) = some (q, rest) := by
  have hn : 0 < q.num.natAbs := Int.natAbs_pos.mpr (Rat.num_pos.mpr hq).ne'
  have hnd : ∀ x : List Char, ∀ c ∈ ['}', '/'], NoDigitHead (c :: x) := by
    intro x c hc d r h; cases h; simp at hc; rcases hc with rfl | rfl <;> rfl
  unfold latexExp
  split_ifs with h1 h2
  · simpa [h1] using pLExp_stop rest hr
  · simp only [List.cons_append, List.append_assoc, List.nil_append]
    rw [pLExp, pDigits_digs _ hn _ (hnd rest '}' (by simp))]
    simp only
    rw [natAbs_num_cast _ hq.le, Rat.coe_int_num_of_den_eq_one h2]
  · simp only [List.cons_append, List.append_assoc, List.nil_append]
    rw [pLExp, pDigits_digs _ hn _ (hnd _ '/' (by simp))]
    simp only
    rw [pDigits_digs _ q.den_pos _ (hnd rest '}' (by simp))]
    simp only
    rw [natAbs_num_cast _ hq.le, Rat.num_div_den]

theorem pLSym_latexExp (q : ℚ) (rest : List Char) (hr : LStop rest) :
    pLSym (latexExp q ++ rest) = ([], latexExp q ++ rest) := by
  unfold latexExp
  split_ifs
  · simpa using hr.1
  · simp [pLSym, isIdent, isAlphaC, isDigitC]
  · simp [pLSym, isIdent, isAlphaC, isDigitC]

/-- One LaTeX factor reads back (with its positive exponent). -/
theorem pLFactor_latexFactor (f : Factor) (hs : SymChars f.1.toList) (hq : 0 < f.2)
    (rest : List Char) (hr : LStop rest) : pLFactor (latexFactor f ++ rest) = some (f, rest) := by
  unfold pLFactor latexFactor
  rw [List.append_assoc, pLSym_latexSym _ _ hs.2 (pLSym_latexExp _ _ hr)]
  simp only [hs.1, ite_false, abs_of_pos hq, String.ofList_toList]
  rw [pLExp_latexExp _ hq _ hr.2]

theorem lStop_sep (x : List Char) : LStop (latexSep ++ x) := by
  exact ⟨rfl, fun r h => by cases h⟩

theorem lStop_cons (c : Char) (x : List Char) (hc : c = '/' ∨ c = ')' ∨ c = '}') :
    LStop (c :: x) := by
  rcases hc with rfl | rfl | rfl <;>
    exact ⟨by rw [pLSym.eq_def]; simp [isIdent, isAlphaC, isDigitC], fun r h => by cases h⟩

theorem lStop_nil : LStop [] := ⟨rfl, by simp⟩

/-- A list of positive-exponent factors reads back from its LaTeX join. -/
theorem pSepBy_latex (fs : List Factor) (f : Factor)
    (hP : ∀ g ∈ f :: fs, SymChars g.1.toList ∧ 0 < g.2) (rest : List Char) (hS : LStop rest)
    (hD : dropPfx latexSep rest = none) (n : ℕ) (hn : fs.length < n) :
    pSepBy pLFactor latexSep n (joinWith latexFactor latexSep (f :: fs) ++ rest) =
      some (f :: fs, rest) :=
  pSepBy_joinWith pLFactor latexFactor latexSep (fun g => SymChars g.1.toList ∧ 0 < g.2) LStop
    (fun g hg rest hr => pLFactor_latexFactor g hg.1 hg.2 rest hr) lStop_sep fs f rest hP hS hD n hn

theorem latexFactor_absF (f : Factor) : latexFactor (absF f) = latexFactor f := by
  simp [latexFactor, absF]

theorem latexFactor_ne_nil (f : Factor) (hs : SymChars f.1.toList) : latexFactor f ≠ [] := by
  obtain ⟨c, t, ht⟩ := List.exists_cons_of_ne_nil hs.1
  unfold latexFactor; rw [ht]; unfold latexSym; split_ifs <;> simp

/-- **LaTeX round trip.** Every canonical factor list reads back from its LaTeX form. -/
theorem parseLatex_latex :
    ∀ l : List Factor, CanonFactors l → parseLatex (latex l) = some l := by
  intro l hl
  have hsc : ∀ f ∈ l, SymChars f.1.toList := fun f hf => symChars_of_symOK _ (hl.2 f hf)
  set N := numFactors l with hNdef
  set D := denFactors l with hDdef
  have hNpos : ∀ f ∈ N, 0 < f.2 := fun f hf => by
    simpa [N, numFactors] using (List.mem_filter.mp hf).2
  have hNmem : ∀ f ∈ N, f ∈ l := fun f hf => mem_numFactors hf
  have hDmem : ∀ f ∈ D, f ∈ l := fun f hf => mem_denFactors hf
  have hDneg : ∀ f ∈ D, f.2 < 0 := fun f hf => by
    have h1 : ¬ 0 < f.2 := by simpa [D, denFactors] using (List.mem_filter.mp hf).2
    exact lt_of_le_of_ne (not_lt.mp h1) (hl.1.2 f (hDmem f hf))
  have hDabs : (D.map absF).map (fun f => (f.1, -f.2)) = D := by
    rw [List.map_map]
    conv_rhs => rw [← List.map_id D]
    refine List.map_congr_left fun f hf => ?_
    simp [absF, abs_of_neg (hDneg f hf)]
  have hsplit : N ++ D = l := hl.1.1.1
  -- the numerator, as a list the LaTeX join prints
  set NN : List Factor := if N = [] then [("1", 1)] else N with hNN
  have hNNtext : (if N = [] then ['1'] else joinWith latexFactor latexSep N) =
      joinWith latexFactor latexSep NN := by
    by_cases h : N = [] <;> simp [hNN, h, joinWith, latexFactor, latexSym, latexExp]
  have hNNP : ∀ g ∈ NN, SymChars g.1.toList ∧ 0 < g.2 := by
    intro g hg
    by_cases h : N = []
    · simp [hNN, h] at hg; subst hg
      refine ⟨⟨by decide, ?_⟩, by norm_num⟩
      intro c hc; left; simp at hc; subst hc; rfl
    · simp only [hNN, h, ite_false] at hg
      exact ⟨hsc g (hNmem g hg), hNpos g hg⟩
  have hNNne : NN ≠ [] := by by_cases h : N = [] <;> simp [hNN, h]
  obtain ⟨f₀, r₀, hNN₀⟩ := List.exists_cons_of_ne_nil hNNne
  have hnum' : (if NN = [("1", 1)] then [] else NN) = N := by
    by_cases h : N = []
    · simp [hNN, h]
    · have : NN = N := by simp [hNN, h]
      rw [this]
      have : N ≠ [("1", 1)] := by
        intro h1
        have := symOK_ne_one _ (hl.2 ("1", 1) (hNmem _ (by simp [h1])))
        exact this rfl
      simp [this]
  have hDP : ∀ g ∈ D.map absF, SymChars g.1.toList ∧ 0 < g.2 := by
    intro g hg
    obtain ⟨g', hg', rfl⟩ := List.mem_map.mp hg
    exact ⟨hsc g' (hDmem g' hg'), by simp [absF, (hl.1.2 g' (hDmem g' hg'))]⟩
  have hlen := length_joinWith latexFactor latexSep NN
    (fun f hf => latexFactor_ne_nil f (hNNP f hf).1)
  have hDlen := length_joinWith latexFactor latexSep (D.map absF)
    (fun f hf => latexFactor_ne_nil f (hDP f hf).1)
  unfold parseLatex latex
  rw [String.toList_ofList, List.append_assoc, dropPfx_append]
  simp only [List.getLast?_append, List.getLast?_singleton, Option.some_or, List.dropLast_concat,
    ite_true]
  unfold latexBody
  rw [hNNtext, hNN₀]
  rw [hNN₀] at hNNP hlen hnum'
  rw [← hDdef]
  cases hD : D with
  | nil =>
    simp only
    rw [show joinWith latexFactor latexSep (f₀ :: r₀) =
      joinWith latexFactor latexSep (f₀ :: r₀) ++ [] by simp,
      pSepBy_latex r₀ f₀ hNNP [] lStop_nil rfl _ (by simp at hlen ⊢; omega)]
    simp only [hnum']
    simpa [hD] using hsplit
  | cons g r =>
    rw [hD] at hDabs hDP hDlen hsplit
    cases r with
    | nil =>
      dsimp only
      have hg := hDP (absF g) (by simp)
      rw [pSepBy_latex r₀ f₀ hNNP _ (lStop_cons '/' _ (by simp)) (by simp [dropPfx, latexSep]) _
        (by simp only [List.length_append, List.length_cons] at hlen ⊢; omega)]
      simp only [hnum', ite_true]
      have e := pSepBy_latex [] (absF g) (by simpa using hg) [] lStop_nil rfl
        (latexFactor g).length (by
          have := latexFactor_ne_nil _ hg.1; rw [latexFactor_absF] at this
          exact List.length_pos_iff.mpr this)
      simp only [joinWith, List.flatMap_nil, List.append_nil, latexFactor_absF] at e
      have hhead : (latexFactor g).head? ≠ some '(' := by
        obtain ⟨c', t', ht'⟩ := List.exists_cons_of_ne_nil hg.1.1
        have hc' := hg.1.2 c' (by simp [ht'])
        rw [← latexFactor_absF]
        unfold latexFactor
        rw [ht']
        unfold latexSym
        split_ifs with hh
        · simp
        · simp only [List.cons_append, List.head?_cons, ne_eq, Option.some.injEq]
          rintro rfl; simp [isIdent, isAlphaC, isDigitC] at hc'
      simp only [pLDen]
      rw [ite_eq_right hhead, e]
      simp only [Option.map_some, List.map_cons, List.map_nil]
      simp only [List.map_cons, List.map_nil] at hDabs
      rw [show (absF g).1 = g.1 from rfl, show -(absF g).2 = g.2 by
        simpa using congrArg (fun x => (List.head! x).2) hDabs]
      rw [← hsplit]
    | cons h r =>
      dsimp only
      have hJ : joinWith latexFactor latexSep (g :: h :: r) =
          joinWith latexFactor latexSep ((g :: h :: r).map absF) := by
        rw [joinWith_map]; congr 1; funext f; exact (latexFactor_absF f).symm
      rw [hJ, pSepBy_latex r₀ f₀ hNNP _ (lStop_cons '/' _ (by simp)) (by simp [dropPfx, latexSep]) _
        (by simp only [List.length_append, List.length_cons] at hlen ⊢; omega)]
      simp only [hnum', ite_true]
      have e := pSepBy_latex ((h :: r).map absF) (absF g) (by simpa using hDP) [')']
        (lStop_cons ')' [] (by simp)) (by simp [dropPfx, latexSep])
        (joinWith latexFactor latexSep ((g :: h :: r).map absF) ++ [')']).length
        (by simp only [List.length_append, List.length_cons, List.length_map] at hDlen ⊢; omega)
      simp only [pLDen, List.head?_cons, ite_true, List.tail_cons]
      simp only [List.map_cons] at e ⊢
      rw [e]
      simp only [Option.map_some]
      rw [show absF g :: absF h :: List.map absF r = (g :: h :: r).map absF by simp, hDabs,
        hsplit]

/-! ## Typst -/

def uprightOpen : List Char := "upright(\"".toList
def uprightClose : List Char := "\")".toList
def thinSep : List Char := " thin ".toList

/-- A signed exponent: nothing for 1, `^n`, `^(-n)`, `^(p\/q)`, `^(-p\/q)`. -/
def typstExp (q : ℚ) : List Char :=
  if q = 1 then []
  else if q.den = 1 then
    if 0 < q then '^' :: digs q.num.natAbs else '^' :: '(' :: '-' :: (digs q.num.natAbs ++ [')'])
  else '^' :: '(' :: ((if q < 0 then ['-'] else []) ++
    (digs q.num.natAbs ++ '\\' :: '/' :: (digs q.den ++ [')'])))

/-- One factor: `upright("sym")` and its signed exponent. -/
def typstFactor (f : Factor) : List Char :=
  uprightOpen ++ (f.1.toList ++ (uprightClose ++ typstExp f.2))

/-- The Typst form of a canonical factor list (`1` when it is empty): the
positive-exponent factors, then the negative ones, each group in symbol order
(the order the canonical spelling reads in). -/
def typst (l : List Factor) : String :=
  if l = [] then "1" else String.ofList (joinWith typstFactor thinSep (numFactors l ++ denFactors l))

/-- After `^(`: `'-'? digits (')' | '\/' digits ')')`. -/
def pTParen (cs : List Char) : Option (ℚ × List Char) :=
  let neg := decide (cs.head? = some '-')
  let cs' := if neg then cs.tail else cs
  match pDigits cs' with
  | some (p, r) =>
    match r with
    | ')' :: r' => some (if neg then -(p : ℚ) else p, r')
    | '\\' :: '/' :: r' =>
      match pDigits r' with
      | some (d, ')' :: r'') => some ((if neg then -(p : ℚ) else p) / d, r'')
      | _ => none
    | _ => none
  | none => none

/-- An optional exponent (none means 1). -/
def pTExp (cs : List Char) : Option (ℚ × List Char) :=
  match cs with
  | c :: cs' =>
    if c = '^' then
      match cs' with
      | d :: cs'' => if d = '(' then pTParen cs'' else (pDigits cs').map fun p => ((p.1 : ℚ), p.2)
      | [] => none
    else some (1, cs)
  | [] => some (1, [])

def pTFactor (cs : List Char) : Option (Factor × List Char) :=
  match dropPfx uprightOpen cs with
  | none => none
  | some r =>
    let p := r.span (fun c => c != '"')
    match dropPfx uprightClose p.2 with
    | none => none
    | some r' =>
      match pTExp r' with
      | some (q, r'') => some ((String.ofList p.1, q), r'')
      | none => none

/-- Read a Typst unit back to its two-sided factor list. -/
def parseTypst (s : String) : Option (List Factor) :=
  if s = "1" then some []
  else
    match pSepBy pTFactor thinSep s.length s.toList with
    | some (fs, []) => some fs
    | _ => none

/-! ### The Typst round trip -/

/-- What may follow a Typst factor: not an exponent, not a digit. -/
def TStop (rest : List Char) : Prop := (∀ r, rest ≠ '^' :: r) ∧ NoDigitHead rest

theorem natAbs_num_cast_neg (q : ℚ) (hq : q < 0) : ((q.num.natAbs : ℕ) : ℚ) = -q.num := by
  rw [Nat.cast_natAbs, Int.cast_abs, abs_of_neg (by exact_mod_cast Rat.num_neg.mpr hq)]

theorem noDigitHead_cons (c : Char) (x : List Char) (h : isDigitC c = false) :
    NoDigitHead (c :: x) := by
  intro d r e; cases e; exact h

theorem pTExp_paren (x : List Char) : pTExp ('^' :: '(' :: x) = pTParen x := by
  simp [pTExp]

theorem pTParen_neg_int (n : ℕ) (hn : 0 < n) (rest : List Char) :
    pTParen ('-' :: (digs n ++ ')' :: rest)) = some (-(n : ℚ), rest) := by
  have e := pDigits_digs n hn (')' :: rest) (noDigitHead_cons _ _ (by decide))
  simp [pTParen, e]

theorem pTParen_rat (neg : Bool) (n d : ℕ) (hn : 0 < n) (hd : 0 < d) (rest : List Char) :
    pTParen ((if neg then ['-'] else []) ++ (digs n ++ '\\' :: '/' :: (digs d ++ ')' :: rest))) =
      some ((if neg then -(n : ℚ) else n) / d, rest) := by
  have e1 := pDigits_digs n hn ('\\' :: '/' :: (digs d ++ ')' :: rest))
    (noDigitHead_cons _ _ (by decide))
  have e2 := pDigits_digs d hd (')' :: rest) (noDigitHead_cons _ _ (by decide))
  cases neg with
  | true => simp [pTParen, e1, e2]
  | false =>
    obtain ⟨c, t, hct⟩ := List.exists_cons_of_ne_nil (digs_ne_nil _ hn)
    have hc : isDigitC c = true := digs_isDigit _ c (by rw [hct]; exact List.mem_cons_self)
    have hcm : c ≠ '-' := by rintro rfl; simp [isDigitC] at hc
    rw [hct] at e1 ⊢
    simp only [List.cons_append] at e1
    simp [pTParen, hcm, e1, e2]

theorem pTExp_typstExp (q : ℚ) (hq : q ≠ 0) (rest : List Char) (hr : TStop rest) :
    pTExp (typstExp q ++ rest) = some (q, rest) := by
  have hn : 0 < q.num.natAbs := Int.natAbs_pos.mpr (Rat.num_ne_zero.mpr hq)
  by_cases h1 : q = 1
  · subst h1
    simp only [typstExp, ite_true, List.nil_append]
    cases rest with
    | nil => rfl
    | cons d r =>
      have hd : d ≠ '^' := by rintro rfl; exact hr.1 r rfl
      simp [pTExp, hd]
  by_cases h2 : q.den = 1
  · by_cases h3 : 0 < q
    · rw [typstExp, ite_eq_right h1, ite_eq_left h2, ite_eq_left h3]
      obtain ⟨c, t, hct⟩ := List.exists_cons_of_ne_nil (digs_ne_nil _ hn)
      have hc : isDigitC c = true := digs_isDigit _ c (by rw [hct]; exact List.mem_cons_self)
      have hcp : c ≠ '(' := by rintro rfl; simp [isDigitC] at hc
      have e := pDigits_digs _ hn rest hr.2
      rw [hct] at e ⊢
      simp only [List.cons_append] at e ⊢
      simp only [pTExp, ite_true, hcp, ite_false, e, Option.map_some]
      rw [natAbs_num_cast _ h3.le, Rat.coe_int_num_of_den_eq_one h2]
    · have hneg : q < 0 := lt_of_le_of_ne (not_lt.mp h3) hq
      rw [typstExp, ite_eq_right h1, ite_eq_left h2, ite_eq_right h3]
      simp only [List.cons_append, List.append_assoc, List.nil_append]
      rw [pTExp_paren, pTParen_neg_int _ hn, natAbs_num_cast_neg _ hneg, neg_neg,
        Rat.coe_int_num_of_den_eq_one h2]
  · rw [typstExp, ite_eq_right h1, ite_eq_right h2]
    simp only [List.cons_append, List.append_assoc, List.nil_append]
    have := pTParen_rat (decide (q < 0)) q.num.natAbs q.den hn q.den_pos rest
    simp only [decide_eq_true_eq] at this
    rw [pTExp_paren, this]
    by_cases hneg : q < 0
    · simp only [hneg, ite_true]
      rw [natAbs_num_cast_neg _ hneg, neg_neg, Rat.num_div_den]
    · simp only [hneg, ite_false]
      rw [natAbs_num_cast _ (not_lt.mp hneg), Rat.num_div_den]

theorem pTFactor_typstFactor (f : Factor) (hs : symOK f.1 = true) (hq : f.2 ≠ 0)
    (rest : List Char) (hr : TStop rest) : pTFactor (typstFactor f ++ rest) = some (f, rest) := by
  have hsc := symChars_of_symOK f.1 hs
  have hspan : (f.1.toList ++ (uprightClose ++ typstExp f.2 ++ rest)).span (fun c => c != '"') =
      (f.1.toList, uprightClose ++ typstExp f.2 ++ rest) := by
    refine span_append _ _ _ (fun x hx => ?_) (fun c r h => ?_)
    · rcases hsc.2 x hx with h | h
      · have : x ≠ '"' := by rintro rfl; simp [isIdent, isAlphaC, isDigitC] at h
        simpa using this
      · subst h; decide
    · simp [uprightClose] at h; rw [← h.1]; decide
  unfold pTFactor typstFactor
  rw [List.append_assoc, dropPfx_append]
  simp only [List.append_assoc] at hspan ⊢
  rw [hspan]
  simp only [dropPfx_append, pTExp_typstExp _ hq _ hr, String.ofList_toList]

theorem tStop_sep (x : List Char) : TStop (thinSep ++ x) :=
  ⟨fun r h => by simp [thinSep] at h, noDigitHead_cons _ _ (by decide)⟩

/-- **Typst round trip.** Every canonical factor list reads back from its Typst form. -/
theorem parseTypst_typst :
    ∀ l : List Factor, CanonFactors l → parseTypst (typst l) = some l := by
  intro l hl
  by_cases hl0 : l = []
  · subst hl0; simp [typst, parseTypst]
  have hsplit : numFactors l ++ denFactors l = l := hl.1.1.1
  have hne' : numFactors l ++ denFactors l ≠ [] := by rw [hsplit]; exact hl0
  obtain ⟨f, r, hfr⟩ := List.exists_cons_of_ne_nil hne'
  have hmem : ∀ g ∈ f :: r, g ∈ l := fun g hg => by rw [← hsplit, hfr]; exact hg
  have hne : typst l ≠ "1" := by
    intro h
    have := congrArg String.toList h
    simp [typst, hl0, hfr, joinWith, typstFactor, uprightOpen] at this
  have hlen := length_joinWith typstFactor thinSep (f :: r)
    (fun g _ => by simp [typstFactor, uprightOpen])
  have e := pSepBy_joinWith pTFactor typstFactor thinSep (fun g => symOK g.1 = true ∧ g.2 ≠ 0)
    TStop (fun g hg rest hr => pTFactor_typstFactor g hg.1 hg.2 rest hr) tStop_sep r f []
    (fun g hg => (⟨hl.2 g (hmem g hg), hl.1.2 g (hmem g hg)⟩ : symOK g.1 = true ∧ g.2 ≠ 0))
    (show TStop [] from ⟨fun r h => (by cases h), fun c r h => (by cases h)⟩) rfl
    (typst l).length (by
      simp only [typst, hl0, ite_false, String.length_ofList, hfr]
      simp only [List.length_cons] at hlen; omega)
  simp only [List.append_nil] at e
  unfold parseTypst
  rw [ite_eq_right hne]
  have ht : (typst l).toList = joinWith typstFactor thinSep (f :: r) := by
    simp [typst, hl0, hfr]
  rw [ht, e]
  rw [← hfr, hsplit]

end Esm.Units
