import Esm.Units.Factors
import Esm.Units.Strings
import Esm.Digits

/-!
# The canonical unit spelling

The canonical form of a document rewrites every `units` string to ONE spelling
built from its parsed unit (esm-spec §4.8.2), so `m*h/(mi*s)`, `m h/(mi s)` and
`m·h/(mi·s)` canonicalize alike. It is a syntactic normalization of the parsed
tree, not a reduction to SI: symbols are kept (`ppm` stays `ppm`, `km` stays `km`).

From the two-sided normal form (`norm2`, `Esm.Units.Factors`): the numerator is
the factors whose net exponent is positive, each symbol once with its exponents
summed, in symbol order, joined by `*`; the denominator is the factors whose net
exponent is negative, normalized the same way, written with the exponent's
absolute value. A symbol is NEVER cancelled across the fraction bar (ruling of
2026-11-12): `mol/mol` stays `mol/mol`, `mol/mol/s` is `mol/(mol*s)`, and
`m m^-1` is `m/m`.
An exponent 1 is omitted, an integer exponent is `^n`, a non-integer rational is
`^(p/q)` in lowest terms. The spelling is `num`, `num/den` when the denominator
has one factor, or `num/(den1*den2*…)`; an empty numerator is `1`, so the
dimensionless unit is `1`.

Choices beyond the grammar:

* `""`, `"1"` and `"dimensionless"` are the three §4.8.1 spellings of one
  dimensionless entry, so all three canonicalize to `"1"`, and a `dimensionless`
  factor inside a product is dropped like the atom `1` (`UExpr.factors`).
* A string that does not lex or parse is left unchanged (`canon` is total and is
  the identity there). So is a string that parses but contains a symbol run with
  a `.` in it (`1.5m`: the lexer reads `digits.run` with a non-digit in the second
  run as one symbol); no table key contains `.`, so such a string never resolves.
* Because nothing cancels, a symbol of the parse is dropped from the spelling
  only when its exponent is 0 (`m^0`). A dropped symbol must still name a table
  unit (`keepsSyms`); otherwise the string is left unchanged, so it keeps failing
  to resolve. Canonicalization never turns a resolving string into a
  non-resolving one (`resolve_canon`), nor the reverse (`resolve_of_canon`).

Theorems: `canon_idem` (idempotent), `parse_canon` (the spelling parses back to a
tree with the same two-sided normal form), `resolve_canon` (and so the same unit),
`resolve_of_canon` (a string whose spelling resolves resolves itself),
`canon_eq_of_factors` (strings with the same two-sided normal form spell alike), and
`parse_spell` (every two-sided normal list with admissible symbols is spelled so that
it parses back to itself).
-/

namespace Esm.Units

/-! ## Admissible symbols and digits -/

/-- A run of identifier characters that is not all digits: one symbol token. -/
def symRunB (s : String) : Bool :=
  !s.toList.isEmpty && s.toList.all isIdent && !s.toList.all isDigitC

/-- A symbol the canonical spelling can write: `%`, or a run of identifier
characters that is not all digits (so the lexer reads it back as one symbol),
and not `dimensionless` (a spelling of `1`). -/
def symOK (s : String) : Bool := (s == "%" || symRunB s) && s != "dimensionless"

/-- A canonical factor list: two-sided normal, every symbol admissible. -/
def CanonFactors (l : List Factor) : Prop := Normal2 l ∧ ∀ f ∈ l, symOK f.1 = true

/-- The decimal digits of `n` (empty for `0`; only positive numbers are written). -/
def digs (n : ℕ) : List Char := (decDigits n).map digitChar

theorem digitChar_isDigitC (d : ℕ) (h : d < 10) : isDigitC (digitChar d) = true := by
  interval_cases d <;> rfl

theorem digitsVal_snoc (xs : List Char) (c : Char) :
    digitsVal (xs ++ [c]) = 10 * digitsVal xs + (c.toNat - '0'.toNat) := by
  simp [digitsVal, List.foldl_append]

theorem digitsVal_digs (n : ℕ) : digitsVal (digs n) = n := by
  have key : ∀ L : List ℕ, (∀ d ∈ L, d < 10) →
      digitsVal (L.map digitChar) = L.foldl (fun a d => 10 * a + d) 0 := by
    intro L hL
    induction L using List.reverseRecOn with
    | nil => rfl
    | append_singleton L d ih =>
      have hd : d < 10 := hL d (by simp)
      rw [List.map_append, List.map_singleton, digitsVal_snoc,
        ih (fun x hx => hL x (by simp [hx])), digitChar_toNat hd, List.foldl_append]
      simp
  rw [digs, key _ (decDigits_lt n), foldl_decDigits]

theorem digs_isDigit (n : ℕ) : ∀ c ∈ digs n, isDigitC c = true := by
  intro c hc
  simp only [digs, List.mem_map] at hc
  obtain ⟨d, hd, rfl⟩ := hc
  exact digitChar_isDigitC d (decDigits_lt n d hd)

theorem digs_ne_nil (n : ℕ) (h : 0 < n) : digs n ≠ [] := by
  simp [digs, decDigits_eq_nil_iff, h.ne']

/-! ## The spelling, as tokens -/

/-- The number token the lexer produces for the digits of `n`. -/
def numTok (n : ℕ) : Tok := .num (String.ofList (digs n)) ((digitsVal (digs n) : ℕ) : ℚ) true

/-- The exponent tokens for a positive exponent `q`. -/
def expToks (q : ℚ) : List Tok :=
  if q = 1 then []
  else if q.den = 1 then [.caret, numTok q.num.natAbs]
  else [.caret, .lp, numTok q.num.natAbs, .slash, numTok q.den, .rp]

/-- One factor, written with the absolute value of its exponent. -/
def fToks (f : Factor) : List Tok := .sym f.1 :: expToks |f.2|

/-- Factors joined by `*`. -/
def joinToks : List Factor → List Tok
  | [] => []
  | f :: r => fToks f ++ r.flatMap (fun g => .star :: fToks g)


/-- The canonical spelling of a factor list, as tokens. -/
def spellToks (l : List Factor) : List Tok :=
  let numT := if numFactors l = [] then [numTok 1] else joinToks (numFactors l)
  match denFactors l with
  | [] => numT
  | [g] => numT ++ .slash :: fToks g
  | den => numT ++ (.slash :: .lp :: (joinToks den ++ [.rp]))

def renderTok : Tok → List Char
  | .sym s => s.toList
  | .num lit _ _ => lit.toList
  | .star => ['*']
  | .dstar => ['*', '*']
  | .slash => ['/']
  | .caret => ['^']
  | .lp => ['(']
  | .rp => [')']
  | .minus => ['-']

def renderToks (ts : List Tok) : List Char := ts.flatMap renderTok

/-- The canonical spelling of a factor list. -/
def spell (l : List Factor) : String := String.ofList (renderToks (spellToks l))

/-! ## The canonicalizer -/

/-- Parse a unit string's characters to a tree. The empty string is the
dimensionless unit `1` (§4.8.1: `""` is a spelling of it). -/
def parseChars (cs : List Char) : Except Err UExpr :=
  if cs = [] then .ok .one else lex (normalize cs) >>= parse

/-- Every symbol of the parse either survives into the two-sided normal form or
names a table unit. (A symbol is dropped only when its exponent is 0, as in
`m^0`; spelling a string without such a symbol would hide that it does not
resolve.) -/
def keepsSyms (e : UExpr) : Bool :=
  e.factors.all fun f => (syms (norm2 e.factors)).contains f.1 || (lookup f.1).isSome

/-- The canonical spelling of a unit string; the identity on a string that does
not parse, whose factors include a symbol the spelling cannot write, or that
drops a symbol naming no unit (`keepsSyms`). -/
def canon (s : String) : String :=
  match parseChars s.toList with
  | .ok e =>
    if (norm2 e.factors).all (fun f => symOK f.1) && keepsSyms e then spell (norm2 e.factors)
    else s
  | .error _ => s

/-! ## Lexing the spelling -/

theorem renderToks_append (a b : List Tok) : renderToks (a ++ b) = renderToks a ++ renderToks b := by
  simp [renderToks]

theorem renderToks_cons (t : Tok) (b : List Tok) :
    renderToks (t :: b) = renderTok t ++ renderToks b := by
  simp [renderToks]

/-- What may follow an operand (a symbol run or a number): nothing, or a
character that neither extends the run nor makes it a decimal. -/
def OpHead (rest : List Char) : Prop := ∀ c r, rest = c :: r → isIdent c = false ∧ c ≠ '.'

/-- No condition on what follows. -/
def AnyRest (_ : List Char) : Prop := True

/-- What may follow `*`: anything but a second `*`. -/
def NoStarHead (rest : List Char) : Prop := ∀ r, rest ≠ '*' :: r

/-- `toks` lexes from its rendering, whatever follows that satisfies `P`. -/
def LexP (toks : List Tok) (P : List Char → Prop) : Prop :=
  toks.length ≤ (renderToks toks).length ∧ (∀ x ∈ renderToks toks, x.toNat < 128) ∧
  ∀ k rest R, P rest → lexAux k rest = .ok R →
    lexAux (k + toks.length) (renderToks toks ++ rest) = .ok (toks ++ R)

theorem LexP.append {t₁ t₂ : List Tok} {P₁ P₂ : List Char → Prop} (h₁ : LexP t₁ P₁)
    (h₂ : LexP t₂ P₂) (hc : ∀ rest, P₂ rest → P₁ (renderToks t₂ ++ rest)) :
    LexP (t₁ ++ t₂) P₂ := by
  refine ⟨by simp [renderToks_append]; have := h₁.1; have := h₂.1; omega, ?_, ?_⟩
  · intro x hx
    rw [renderToks_append, List.mem_append] at hx
    rcases hx with hx | hx
    · exact h₁.2.1 x hx
    · exact h₂.2.1 x hx
  intro k rest R hp h
  have e2 := h₂.2.2 k rest R hp h
  have e1 := h₁.2.2 (k + t₂.length) (renderToks t₂ ++ rest) (t₂ ++ R) (hc rest hp) e2
  rw [renderToks_append, List.append_assoc, List.length_append, List.append_assoc,
    show k + (t₁.length + t₂.length) = k + t₂.length + t₁.length by omega]
  exact e1

theorem LexP.mono {t : List Tok} {P Q : List Char → Prop} (h : LexP t P) (hq : ∀ r, Q r → P r) :
    LexP t Q := ⟨h.1, h.2.1, fun k rest R hr e => h.2.2 k rest R (hq rest hr) e⟩

theorem LexP.nil (P : List Char → Prop) : LexP [] P :=
  ⟨by simp, by simp [renderToks], fun k rest R _ e => by simpa [renderToks] using e⟩

theorem LexP.cons {t : Tok} {ts : List Tok} {P₁ P₂ : List Char → Prop} (h₁ : LexP [t] P₁)
    (h₂ : LexP ts P₂) (hc : ∀ rest, P₂ rest → P₁ (renderToks ts ++ rest)) :
    LexP (t :: ts) P₂ := h₁.append h₂ hc

theorem ident_ne {c : Char} (h : isIdent c = true) (d : Char) (hd : isIdent d = false) : c ≠ d := by
  rintro rfl; rw [h] at hd; exact Bool.noConfusion hd

theorem isSpace_of_ident {c : Char} (h : isIdent c = true) : isSpace c = false := by
  unfold isSpace
  simp [ident_ne h ' ' (by decide), ident_ne h '\t' (by decide), ident_ne h '\n' (by decide),
    ident_ne h '\r' (by decide)]

theorem isIdent_of_digit {c : Char} (h : isDigitC c = true) : isIdent c = true := by
  simp [isIdent, h]

/-- A single-character operator other than `*`. -/
theorem lexP_op (t : Tok) (c : Char) (hr : renderTok t = [c])
    (h : ∀ k cs, lexAux (k + 1) (c :: cs) = (t :: ·) <$> lexAux k cs) (P : List Char → Prop)
    (ha : c.toNat < 128) : LexP [t] P := by
  refine ⟨by simp [renderToks, hr], by simp [renderToks, hr, ha], ?_⟩
  intro k rest R _ e
  simp only [renderToks, List.flatMap_cons, List.flatMap_nil, List.append_nil, hr,
    List.singleton_append, List.length_singleton, h, e]
  rfl

theorem lexP_slash (P : List Char → Prop) : LexP [.slash] P :=
  lexP_op .slash '/' rfl (fun k cs => by simp [lexAux, isSpace]) P (by decide)
theorem lexP_caret (P : List Char → Prop) : LexP [.caret] P :=
  lexP_op .caret '^' rfl (fun k cs => by simp [lexAux, isSpace]) P (by decide)
theorem lexP_lp (P : List Char → Prop) : LexP [.lp] P :=
  lexP_op .lp '(' rfl (fun k cs => by simp [lexAux, isSpace]) P (by decide)
theorem lexP_rp (P : List Char → Prop) : LexP [.rp] P :=
  lexP_op .rp ')' rfl (fun k cs => by simp [lexAux, isSpace]) P (by decide)
theorem lexP_percent (P : List Char → Prop) : LexP [.sym "%"] P :=
  lexP_op (.sym "%") '%' rfl (fun k cs => by simp [lexAux, isSpace]) P (by decide)

theorem lexP_star : LexP [.star] NoStarHead := by
  refine ⟨by simp [renderToks, renderTok], by simp [renderToks, renderTok], ?_⟩
  intro k rest R hr e
  simp only [renderToks, List.flatMap_cons, List.flatMap_nil, List.append_nil, renderTok,
    List.singleton_append, List.length_singleton]
  cases rest with
  | nil => simp [lexAux, isSpace, e]
  | cons c r =>
    have hc : c ≠ '*' := by rintro rfl; exact hr r rfl
    rw [lexAux]
    simp [isSpace]
    · rw [e]; rfl
    · intro cs' h; injection h with h1; exact hc h1

theorem lexP_symRun (s : String) (hne : s.toList ≠ []) (hid : s.toList.all isIdent = true)
    (hnd : s.toList.all isDigitC = false) : LexP [.sym s] OpHead := by
  refine ⟨by simp [renderToks, renderTok]; exact List.length_pos_iff.mpr hne,
    fun x hx => ascii_of_ident (List.all_eq_true.mp hid x (by simpa [renderToks, renderTok] using hx)),
    ?_⟩
  intro k rest R hr e
  simp only [renderToks, List.flatMap_cons, List.flatMap_nil, List.append_nil, renderTok,
    List.length_singleton]
  obtain ⟨c, t, ht⟩ : ∃ c t, s.toList = c :: t := List.exists_cons_of_ne_nil hne
  rw [List.all_eq_true] at hid
  have hc : isIdent c = true := hid c (by simp [ht])
  have hspan : (c :: (t ++ rest)).span isIdent = (c :: t, rest) := by
    have := span_append isIdent (c :: t) rest (by rw [← ht]; exact hid)
      (fun c' r' h => (hr c' r' h).1)
    simpa using this
  rw [ht, List.cons_append, lexAux.eq_def]
  dsimp only
  rw [ht] at hnd
  simp only [isSpace_of_ident hc, ident_ne hc '*' (by decide), ident_ne hc '/' (by decide),
    ident_ne hc '^' (by decide), ident_ne hc '(' (by decide), ident_ne hc ')' (by decide),
    ident_ne hc '-' (by decide), ident_ne hc '%' (by decide), hc, hspan, hnd]
  simp [e, ← ht]

theorem lexP_num (n : ℕ) (hn : 0 < n) : LexP [numTok n] OpHead := by
  have hne := digs_ne_nil n hn
  have hdig := digs_isDigit n
  refine ⟨by simp [renderToks, renderTok, numTok]; exact List.length_pos_iff.mpr hne,
    fun x hx => ascii_of_ident (isIdent_of_digit (hdig x (by simpa [renderToks, renderTok, numTok] using hx))),
    ?_⟩
  intro k rest R hr e
  simp only [renderToks, List.flatMap_cons, List.flatMap_nil, List.append_nil, renderTok, numTok,
    String.toList_ofList, List.length_singleton]
  obtain ⟨c, t, ht⟩ : ∃ c t, digs n = c :: t := List.exists_cons_of_ne_nil hne
  have hc : isDigitC c = true := hdig c (by simp [ht])
  have hci := isIdent_of_digit hc
  have hspan : (c :: (t ++ rest)).span isIdent = (c :: t, rest) := by
    have := span_append isIdent (c :: t) rest
      (by rw [← ht]; exact fun x hx => isIdent_of_digit (hdig x hx))
      (fun c' r' h => (hr c' r' h).1)
    simpa using this
  have hall : (c :: t).all isDigitC = true := by rw [← ht]; exact List.all_eq_true.mpr hdig
  rw [ht, List.cons_append, lexAux.eq_def]
  dsimp only
  simp only [isSpace_of_ident hci, ident_ne hci '*' (by decide), ident_ne hci '/' (by decide),
    ident_ne hci '^' (by decide), ident_ne hci '(' (by decide), ident_ne hci ')' (by decide),
    ident_ne hci '-' (by decide), ident_ne hci '%' (by decide), hci, hspan, hall,
    ↓reduceIte, Bool.false_eq_true]
  cases rest with
  | nil => rw [e]; rfl
  | cons d r =>
    have hd : d ≠ '.' := (hr d r rfl).2
    split
    · rename_i h; injection h with h1; exact absurd h1 hd
    · rw [e]; rfl

theorem opHead_cons (c : Char) (r : List Char) (h : isIdent c = false) (hd : c ≠ '.') :
    OpHead (c :: r) := by
  intro c' r' e; cases e; exact ⟨h, hd⟩

theorem lexP_sym (s : String) (h : symOK s = true) : LexP [.sym s] OpHead := by
  by_cases hp : s = "%"
  · subst hp; exact lexP_percent _
  · have h2 : symRunB s = true := by
      simp only [symOK, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at h
      exact h.1.resolve_left hp
    simp only [symRunB, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at h2
    exact lexP_symRun s (by simpa using h2.1.1) h2.1.2 h2.2

/-- The first character of an admissible symbol is not `*`. -/
theorem symOK_head (s : String) (h : symOK s = true) : ∀ r, s.toList ≠ '*' :: r := by
  intro r hr
  by_cases hp : s = "%"
  · subst hp; simp at hr
  · have h2 : symRunB s = true := by
      simp only [symOK, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at h
      exact h.1.resolve_left hp
    simp only [symRunB, Bool.and_eq_true] at h2
    have h' := h2.1.2
    rw [hr] at h'
    simp [isIdent, isAlphaC, isDigitC] at h'

theorem lexP_expToks (q : ℚ) (hq : 0 < q) : LexP (expToks q) OpHead := by
  unfold expToks
  have hn : 0 < q.num.natAbs := Int.natAbs_pos.mpr (Rat.num_pos.mpr hq).ne'
  split_ifs with h1 h2
  · exact LexP.nil _
  · exact (lexP_caret AnyRest).cons (lexP_num _ hn) (fun _ _ => trivial)
  · refine (lexP_caret AnyRest).cons ((lexP_lp AnyRest).cons ((lexP_num _ hn).cons ((lexP_slash AnyRest).cons
      ((lexP_num _ q.den_pos).cons (lexP_rp OpHead) ?_) (fun _ _ => trivial)) ?_)
      (fun _ _ => trivial)) (fun _ _ => trivial)
    · intro rest _; simp only [renderToks_cons, renderTok, List.singleton_append]
      exact opHead_cons _ _ (by decide) (by decide)
    · intro rest _; simp only [renderToks_cons, renderTok, List.cons_append]
      exact opHead_cons _ _ (by decide) (by decide)

theorem renderToks_expToks (q : ℚ) (rest : List Char) :
    renderToks (expToks q) ++ rest = rest ∨ ∃ r, renderToks (expToks q) ++ rest = '^' :: r := by
  unfold expToks
  split_ifs <;> simp [renderTok, renderToks]

theorem lexP_fToks (f : Factor) (hs : symOK f.1 = true) (hq : f.2 ≠ 0) :
    LexP (fToks f) OpHead := by
  refine (lexP_sym f.1 hs).cons (lexP_expToks _ (abs_pos.mpr hq)) ?_
  intro rest hr
  rcases renderToks_expToks |f.2| rest with h | ⟨r, h⟩
  · rw [h]; exact hr
  · rw [h]; exact opHead_cons _ _ (by decide) (by decide)

theorem renderToks_fToks_head (f : Factor) (hs : symOK f.1 = true) (rest : List Char) :
    NoStarHead (renderToks (fToks f) ++ rest) := by
  intro r hr
  have hne : f.1.toList ≠ [] := by
    intro h
    by_cases hp : f.1 = "%"
    · rw [hp] at h; simp at h
    · have h2 : symRunB f.1 = true := by
        have hs' := hs
        simp only [symOK, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hs'
        exact hs'.1.resolve_left hp
      simp [symRunB, h] at h2
  obtain ⟨c, t, ht⟩ := List.exists_cons_of_ne_nil hne
  simp only [fToks, renderToks_cons, renderTok, ht, List.cons_append, List.cons.injEq] at hr
  exact symOK_head f.1 hs t (by rw [ht, hr.1])

theorem lexP_stars (r : List Factor) (hs : ∀ f ∈ r, symOK f.1 = true) (hq : ∀ f ∈ r, f.2 ≠ 0) :
    LexP (r.flatMap (fun g => .star :: fToks g)) OpHead := by
  induction r with
  | nil => exact LexP.nil _
  | cons g r ih =>
    rw [List.flatMap_cons]
    refine LexP.append (lexP_star.cons (lexP_fToks g (hs g (by simp)) (hq g (by simp)))
      (fun rest _ => renderToks_fToks_head g (hs g (by simp)) rest))
      (ih (fun f hf => hs f (by simp [hf])) (fun f hf => hq f (by simp [hf]))) ?_
    intro rest hr
    cases r with
    | nil => simpa [renderToks] using hr
    | cons g' r' =>
      simp only [List.flatMap_cons, renderToks_append, renderToks_cons, renderTok,
        List.cons_append]
      exact opHead_cons _ _ (by decide) (by decide)

theorem lexP_join (f : Factor) (r : List Factor) (hs : ∀ g ∈ f :: r, symOK g.1 = true)
    (hq : ∀ g ∈ f :: r, g.2 ≠ 0) : LexP (joinToks (f :: r)) OpHead := by
  refine (lexP_fToks f (hs f (by simp)) (hq f (by simp))).append
    (lexP_stars r (fun g hg => hs g (by simp [hg])) (fun g hg => hq g (by simp [hg]))) ?_
  intro rest hr
  cases r with
  | nil => simpa [renderToks] using hr
  | cons g' r' =>
    simp only [List.flatMap_cons, renderToks_append, renderToks_cons, renderTok,
      List.cons_append]
    exact opHead_cons _ _ (by decide) (by decide)


/-- The numerator tokens. -/
def numToks (l : List Factor) : List Tok :=
  if numFactors l = [] then [numTok 1] else joinToks (numFactors l)

theorem spellToks_eq (l : List Factor) : spellToks l =
    match denFactors l with
    | [] => numToks l
    | [g] => numToks l ++ .slash :: fToks g
    | den => numToks l ++ (.slash :: .lp :: (joinToks den ++ [.rp])) := rfl

theorem lexP_numToks (l : List Factor) (hl : CanonFactors l) : LexP (numToks l) OpHead := by
  unfold numToks
  split_ifs with h
  · exact lexP_num 1 one_pos
  · obtain ⟨f, r, hfr⟩ := List.exists_cons_of_ne_nil h
    rw [hfr]
    exact lexP_join f r (fun g hg => hl.2 g (mem_numFactors (hfr ▸ hg)))
      (fun g hg => hl.1.2 g (mem_numFactors (hfr ▸ hg)))

theorem lexP_spellToks (l : List Factor) (hl : CanonFactors l) : LexP (spellToks l) OpHead := by
  have hN := lexP_numToks l hl
  have hs : ∀ g ∈ denFactors l, symOK g.1 = true := fun g hg => hl.2 g (mem_denFactors hg)
  have hq : ∀ g ∈ denFactors l, g.2 ≠ 0 := fun g hg => hl.1.2 g (mem_denFactors hg)
  rw [spellToks_eq]
  have slashHead : ∀ x : List Char, OpHead ('/' :: x) := fun x => opHead_cons _ _ (by decide) (by decide)
  split
  · exact hN
  · rename_i g hg
    rw [hg] at hs hq
    refine hN.append ((lexP_slash AnyRest).cons (lexP_fToks g (hs g (by simp)) (hq g (by simp)))
      (fun _ _ => trivial)) ?_
    intro rest _; simp only [renderToks_cons, renderTok, List.cons_append]
    exact slashHead _
  · rename_i den h0 h1
    obtain ⟨g, r, hgr⟩ := List.exists_cons_of_ne_nil (fun h => h0 h)
    rw [hgr] at hs hq ⊢
    refine hN.append ((lexP_slash AnyRest).cons ((lexP_lp AnyRest).cons
      ((lexP_join g r hs hq).append (lexP_rp OpHead) ?_) (fun _ _ => trivial)) (fun _ _ => trivial)) ?_
    · intro rest _; exact opHead_cons _ _ (by decide) (by decide)
    · intro rest _; simp only [renderToks_cons, renderTok, List.cons_append]
      exact slashHead _

theorem spellToks_ne_nil (l : List Factor) : spellToks l ≠ [] := by
  rw [spellToks_eq]
  have : numToks l ≠ [] := by
    unfold numToks; split_ifs with h
    · simp
    · obtain ⟨f, r, hfr⟩ := List.exists_cons_of_ne_nil h; rw [hfr]; simp [joinToks, fToks]
  split <;> simp [this]

/-- The spelling's characters lex to the spelling's tokens. -/
theorem lex_spell (l : List Factor) (hl : CanonFactors l) :
    lex (normalize (renderToks (spellToks l))) = .ok (spellToks l) := by
  obtain ⟨hlen, hascii, hlex⟩ := lexP_spellToks l hl
  rw [normalize_ascii _ hascii, lex]
  have e := hlex ((renderToks (spellToks l)).length + 1 - (spellToks l).length) [] []
    (by intro c r h; cases h) (by
      obtain ⟨j, hj⟩ : ∃ j, (renderToks (spellToks l)).length + 1 - (spellToks l).length = j + 1 :=
        ⟨(renderToks (spellToks l)).length - (spellToks l).length, by omega⟩
      rw [hj]; exact lexAux_nil j)
  simp only [List.append_nil] at e
  rwa [show (renderToks (spellToks l)).length + 1 - (spellToks l).length + (spellToks l).length =
    (renderToks (spellToks l)).length + 1 by omega] at e

/-! ## The parse of the spelling -/

/-- The tree one factor parses to: its symbol, raised to the exponent's absolute
value unless that is 1. -/
def term (f : Factor) : UExpr := if |f.2| = 1 then .sym f.1 else .pow (.sym f.1) |f.2|

/-- `acc * t₁ * t₂ * …`, folded left. -/
def foldTerms (acc : UExpr) (fs : List Factor) : UExpr := fs.foldl (fun a g => .mul a (term g)) acc

theorem natAbs_num_cast (q : ℚ) (hq : 0 ≤ q) : ((q.num.natAbs : ℕ) : ℚ) = q.num := by
  rw [Nat.cast_natAbs, Int.cast_abs, abs_of_nonneg (by exact_mod_cast Rat.num_nonneg.mpr hq)]

theorem pTerm_fToks (f : Factor) (hq : f.2 ≠ 0) (ts : List Tok) (hts : NoPowHead ts) (n : ℕ) :
    pTerm (n + 3) (fToks f ++ ts) = .ok (term f, ts) := by
  have hpos : 0 < |f.2| := abs_pos.mpr hq
  unfold fToks expToks term
  by_cases h1 : |f.2| = 1
  · simp only [h1, ite_true, List.cons_append, List.nil_append]
    exact pTerm_sym (n + 1) f.1 ts hts
  · by_cases hd : (|f.2|).den = 1
    · simp only [h1, hd, ite_true, ite_false, List.cons_append, List.nil_append, numTok]
      simp only [pTerm, pAtom, pExp]
      rw [digitsVal_digs, natAbs_num_cast _ hpos.le, Rat.coe_int_num_of_den_eq_one hd]
    · simp only [h1, hd, ite_false, List.cons_append, List.nil_append, numTok]
      have hden : ((digitsVal (digs (|f.2|).den) : ℕ) : ℚ) ≠ 0 := by
        rw [digitsVal_digs]; exact_mod_cast (|f.2|).den_pos.ne'
      simp only [pTerm, pAtom, pExp, pInt, hden, ite_false]
      rw [digitsVal_digs, digitsVal_digs, natAbs_num_cast _ hpos.le, Rat.num_div_den]

theorem noPowHead_fToks (f : Factor) (ts : List Tok) : NoPowHead (fToks f ++ ts) := by
  simp [NoPowHead, fToks]

theorem noPowHead_stars (r : List Factor) (ts : List Tok) (h : NoPowHead ts) :
    NoPowHead (r.flatMap (fun g => .star :: fToks g) ++ ts) := by
  cases r with
  | nil => simpa using h
  | cons g r => simp [NoPowHead]

theorem pTail_stars (r : List Factor) (hq : ∀ f ∈ r, f.2 ≠ 0) (ts : List Tok) (hts : NoPowHead ts) :
    ∀ (acc : UExpr) (n k : ℕ), 4 * r.length + k ≤ n →
      ∃ m, k ≤ m ∧ pTail n acc (r.flatMap (fun g => .star :: fToks g) ++ ts) =
        pTail m (foldTerms acc r) ts := by
  induction r with
  | nil => intro acc n k h; exact ⟨n, by simpa using h, by simp [foldTerms]⟩
  | cons g r ih =>
    intro acc n k h
    obtain ⟨j, rfl⟩ : ∃ j, n = j + 4 := ⟨n - 4, by simp at h; omega⟩
    have hg : g.2 ≠ 0 := hq g (by simp)
    have hrest := noPowHead_stars r ts hts
    obtain ⟨m, hm, e⟩ := ih (fun f hf => hq f (by simp [hf])) (.mul acc (term g)) (j + 3) k
      (by simp at h; omega)
    refine ⟨m, hm, ?_⟩
    rw [List.flatMap_cons, List.cons_append, List.cons_append, List.append_assoc,
      show j + 4 = (j + 3) + 1 from rfl, pTail, pTerm_fToks g hg _ hrest j]
    simpa [foldTerms] using e

theorem pUnit_join (f : Factor) (r : List Factor) (hq : ∀ g ∈ f :: r, g.2 ≠ 0) (ts : List Tok)
    (hts : NoPowHead ts) (n k : ℕ) (h : 4 * r.length + k + 4 ≤ n) :
    ∃ m, k ≤ m ∧ pUnit n (joinToks (f :: r) ++ ts) = pTail m (foldTerms (term f) r) ts := by
  obtain ⟨j, rfl⟩ : ∃ j, n = j + 4 := ⟨n - 4, by omega⟩
  have hrest := noPowHead_stars r ts hts
  rw [joinToks, List.append_assoc, show j + 4 = (j + 3) + 1 from rfl, pUnit,
    pTerm_fToks f (hq f (by simp)) _ hrest j]
  exact pTail_stars r (fun g hg => hq g (by simp [hg])) ts hts (term f) (j + 3) k (by omega)

theorem pTail_nil (m : ℕ) (acc : UExpr) : pTail (m + 1) acc [] = .ok (acc, []) := by
  simp [pTail, startsTerm]

theorem pTail_rp (m : ℕ) (acc : UExpr) (ts : List Tok) :
    pTail (m + 1) acc (.rp :: ts) = .ok (acc, .rp :: ts) := by
  simp [pTail, startsTerm]

/-- The numerator's tree. -/
def numTree (l : List Factor) : UExpr :=
  match numFactors l with
  | [] => .one
  | f :: r => foldTerms (term f) r

/-- The tree the spelling parses to. -/
def spellTree (l : List Factor) : UExpr :=
  match denFactors l with
  | [] => numTree l
  | g :: r => .div (numTree l) (foldTerms (term g) r)

theorem numTok_one : numTok 1 = .num "1" 1 true := by
  have : decDigits 1 = [1] := by simp [decDigits]
  simp only [numTok, digs, this]
  rfl

theorem pUnit_numToks (l : List Factor) (hl : ∀ f ∈ l, f.2 ≠ 0) (ts : List Tok)
    (hts : NoPowHead ts) (n k : ℕ) (h : 4 * (numFactors l).length + k + 4 ≤ n) :
    ∃ m, k ≤ m ∧ pUnit n (numToks l ++ ts) = pTail m (numTree l) ts := by
  unfold numToks numTree
  cases hN : numFactors l with
  | nil =>
    simp only [numTok_one, ite_true, List.cons_append, List.nil_append]
    obtain ⟨j, rfl⟩ : ∃ j, n = j + 4 := ⟨n - 4, by omega⟩
    refine ⟨j + 3, by omega, ?_⟩
    have hT : pTerm (j + 3) (.num "1" 1 true :: ts) = .ok (.one, ts) := by
      cases ts with
      | nil => simp [pTerm, pAtom]
      | cons t ts => cases t <;> simp_all [pTerm, pAtom, NoPowHead]
    rw [show j + 4 = (j + 3) + 1 from rfl, pUnit, hT]
  | cons f r =>
    rw [hN] at h
    simp only [List.cons_ne_nil, ite_false]
    exact pUnit_join f r (fun g hg => hl g (mem_numFactors (hN ▸ hg))) ts hts n k
      (by simp at h; omega)

theorem length_stars (r : List Factor) :
    r.length ≤ (r.flatMap (fun g => .star :: fToks g)).length := by
  induction r with
  | nil => simp
  | cons g r ih => simp only [List.flatMap_cons, List.length_append, List.length_cons]; omega

theorem length_joinToks (f : Factor) (r : List Factor) :
    r.length + 1 ≤ (joinToks (f :: r)).length := by
  have := length_stars r
  have h1 : 1 ≤ (fToks f).length := by simp [fToks]
  simp only [joinToks, List.length_append]; omega

theorem length_numToks (l : List Factor) : (numFactors l).length ≤ (numToks l).length := by
  unfold numToks
  split_ifs with h
  · simp [h]
  · obtain ⟨f, r, hfr⟩ := List.exists_cons_of_ne_nil h
    rw [hfr]; have := length_joinToks f r; simp only [List.length_cons]; omega

theorem parse_append_ok (ts : List Tok) (e : UExpr) (h : pUnit (4 * ts.length + 8) ts = .ok (e, [])) :
    parse ts = .ok e := by
  unfold parse; rw [h]

/-- The spelling's tokens parse to `spellTree`. -/
theorem parse_spellToks (l : List Factor) (hl : ∀ f ∈ l, f.2 ≠ 0) :
    parse (spellToks l) = .ok (spellTree l) := by
  have hD : ∀ g ∈ denFactors l, g.2 ≠ 0 := fun g hg => hl g (mem_denFactors hg)
  have hNl := length_numToks l
  apply parse_append_ok
  rw [spellToks_eq]
  unfold spellTree
  cases hd : denFactors l with
  | nil =>
    obtain ⟨m, hm, e⟩ := pUnit_numToks l hl [] (by simp [NoPowHead])
      (4 * (numToks l).length + 8) 1 (by omega)
    obtain ⟨j, rfl⟩ : ∃ j, m = j + 1 := ⟨m - 1, by omega⟩
    simp only [List.append_nil] at e
    rw [e, pTail_nil]
  | cons g r =>
    rw [hd] at hD
    cases r with
    | nil =>
      have hg : g.2 ≠ 0 := hD g (by simp)
      obtain ⟨m, hm, e⟩ := pUnit_numToks l hl (.slash :: fToks g) (by simp [NoPowHead])
        (4 * (numToks l ++ .slash :: fToks g).length + 8) 4
        (by simp only [List.length_append, List.length_cons, fToks]; omega)
      obtain ⟨j, rfl⟩ : ∃ j, m = j + 4 := ⟨m - 4, by omega⟩
      have hT : pTerm (j + 3) (fToks g) = .ok (term g, []) := by
        simpa using pTerm_fToks g hg [] (by simp [NoPowHead]) j
      rw [e, show j + 4 = (j + 3) + 1 from rfl, pTail, hT]
      simp only [foldTerms, List.foldl_nil]
      exact pTail_nil (j + 2) _
    | cons h r =>
      have hJ := length_joinToks g (h :: r)
      simp only [List.length_cons] at hJ
      obtain ⟨m, hm, e⟩ := pUnit_numToks l hl (Tok.slash :: Tok.lp :: (joinToks (g :: h :: r) ++ [Tok.rp]))
        (by simp [NoPowHead]) (4 * (numToks l ++ Tok.slash :: Tok.lp :: (joinToks (g :: h :: r) ++ [Tok.rp])).length + 8)
        (4 * r.length + 17)
        (by simp only [List.length_append, List.length_cons, List.length_nil]; omega)
      obtain ⟨j, rfl⟩ : ∃ j, m = j + 3 := ⟨m - 3, by omega⟩
      obtain ⟨m', hm', eU⟩ := pUnit_join g (h :: r) hD [.rp] (by simp [NoPowHead]) j 1
        (by simp only [List.length_cons]; omega)
      obtain ⟨i, rfl⟩ : ∃ i, m' = i + 1 := ⟨m' - 1, by omega⟩
      rw [pTail_rp] at eU
      have hA : pAtom (j + 1) (.lp :: (joinToks (g :: h :: r) ++ [.rp])) =
          .ok (foldTerms (term g) (h :: r), []) := by
        simp only [pAtom, eU]
      have hT : pTerm (j + 2) (.lp :: (joinToks (g :: h :: r) ++ [.rp])) =
          .ok (foldTerms (term g) (h :: r), []) := by
        simp only [pTerm, hA]
      rw [e, show j + 3 = (j + 2) + 1 from rfl, pTail, hT]
      exact pTail_nil (j + 1) _

/-! ## The spelling's factors -/

theorem symOK_ne_dimensionless {s : String} (h : symOK s = true) : s ≠ "dimensionless" := by
  intro hs; subst hs; simp [symOK] at h

/-- A factor with its exponent's absolute value. -/
def absF (f : Factor) : Factor := (f.1, |f.2|)

theorem factors_term (f : Factor) (h : f.1 ≠ "dimensionless") :
    (term f).factors = [absF f] := by
  unfold term absF
  split_ifs with h1 <;> simp [UExpr.factors, h, h1]

theorem factors_foldTerms (acc : UExpr) (fs : List Factor)
    (h : ∀ f ∈ fs, f.1 ≠ "dimensionless") :
    (foldTerms acc fs).factors = acc.factors ++ fs.map absF := by
  induction fs generalizing acc with
  | nil => simp [foldTerms]
  | cons g r ih =>
    have := ih (.mul acc (term g)) (fun f hf => h f (by simp [hf]))
    simp only [foldTerms, List.foldl_cons] at this ⊢
    rw [this, UExpr.factors, factors_term g (h g (by simp))]
    simp

theorem factors_spellTree (l : List Factor) (hl : CanonFactors l) :
    (spellTree l).factors = numFactors l ++ denFactors l := by
  have hdim : ∀ f ∈ l, f.1 ≠ "dimensionless" := fun f hf => symOK_ne_dimensionless (hl.2 f hf)
  have hnum : (numFactors l).map absF = numFactors l := by
    conv_rhs => rw [← List.map_id (numFactors l)]
    refine List.map_congr_left fun f hf => ?_
    have : 0 < f.2 := by simpa [numFactors] using (List.mem_filter.mp hf).2
    simp [absF, abs_of_pos this]
  have hden : ((denFactors l).map absF).map (fun f => (f.1, -f.2)) = denFactors l := by
    rw [List.map_map]
    conv_rhs => rw [← List.map_id (denFactors l)]
    refine List.map_congr_left fun f hf => ?_
    have : ¬ 0 < f.2 := by simpa [denFactors] using (List.mem_filter.mp hf).2
    simp [absF, abs_of_nonpos (not_lt.mp this)]
  have hN : (numTree l).factors = numFactors l := by
    unfold numTree
    cases h : numFactors l with
    | nil => rfl
    | cons f r =>
      rw [h] at hnum
      have hd : ∀ g ∈ f :: r, g.1 ≠ "dimensionless" :=
        fun g hg => hdim g (mem_numFactors (h ▸ hg))
      simp only
      rw [factors_foldTerms _ _ (fun g hg => hd g (by simp [hg])),
        factors_term f (hd f (by simp))]
      simpa using hnum
  unfold spellTree
  cases h : denFactors l with
  | nil => simpa using hN
  | cons g r =>
    rw [h] at hden
    have hd : ∀ g' ∈ g :: r, g'.1 ≠ "dimensionless" :=
      fun g' hg => hdim g' (mem_denFactors (h ▸ hg))
    simp only [UExpr.factors]
    rw [hN, factors_foldTerms _ _ (fun g' hg => hd g' (by simp [hg])),
      factors_term g (hd g (by simp))]
    simpa using hden

theorem factors_spellTree_eq (l : List Factor) (hl : CanonFactors l) : (spellTree l).factors = l := by
  rw [factors_spellTree l hl, hl.1.1.1]

/-- **The spelling parses back.** Every canonical factor list is spelled so that
it parses (§4.8.2) to a tree whose factor list is a permutation of it, and whose
normalized factor list is it exactly. -/
theorem parse_spell :
    ∀ l : List Factor, CanonFactors l →
      ∃ e, parseChars (spell l).toList = .ok e ∧ e.factors = l ∧ norm2 e.factors = l := by
  intro l hl
  refine ⟨spellTree l, ?_, factors_spellTree_eq l hl, ?_⟩
  swap
  · rw [factors_spellTree_eq l hl]; exact norm2_eq_of_normal2 hl.1
  have hne : renderToks (spellToks l) ≠ [] := by
    intro h
    have := (lexP_spellToks l hl).1
    rw [h] at this
    exact spellToks_ne_nil l (List.eq_nil_of_length_eq_zero (by simpa using this))
  unfold spell parseChars
  rw [String.toList_ofList, ite_eq_right hne, lex_spell l hl]
  exact parse_spellToks l hl.1.2

theorem canonFactors_norm2 (e : UExpr) (h : (norm2 e.factors).all (fun f => symOK f.1) = true) :
    CanonFactors (norm2 e.factors) :=
  ⟨normal2_norm2 _, fun f hf => List.all_eq_true.mp h f hf⟩

/-- `canon` either leaves a string alone or spells a canonical factor list —
the normalized factor list of the string's parse. -/
theorem canon_cases (s : String) :
    canon s = s ∨ ∃ e, parseChars s.toList = .ok e ∧ CanonFactors (norm2 e.factors) ∧
      keepsSyms e = true ∧ canon s = spell (norm2 e.factors) := by
  unfold canon
  cases h : parseChars s.toList with
  | error _ => exact Or.inl rfl
  | ok e =>
    simp only
    split_ifs with hv
    · rw [Bool.and_eq_true] at hv
      exact Or.inr ⟨e, rfl, canonFactors_norm2 e hv.1, hv.2, rfl⟩
    · exact Or.inl rfl

/-- A tree whose factors are exactly its normal form keeps its symbols. -/
theorem keepsSyms_of_normal (e : UExpr) (h : norm2 e.factors = e.factors) :
    keepsSyms e = true := by
  rw [keepsSyms, List.all_eq_true]
  intro f hf
  rw [h, Bool.or_eq_true]
  left
  simpa [syms] using ⟨f.2, hf⟩

/-- The canonical spelling of a canonical factor list is a fixed point. -/
theorem canon_spell (l : List Factor) (hl : CanonFactors l) : canon (spell l) = spell l := by
  obtain ⟨e, he, hf, hn⟩ := parse_spell l hl
  have hv : (norm2 e.factors).all (fun f => symOK f.1) = true := by
    rw [hn]; exact List.all_eq_true.mpr hl.2
  have hk := keepsSyms_of_normal e (hn.trans hf.symm)
  unfold canon
  rw [he]
  simp only [hn, ite_self]

/-- **Idempotence.** Canonicalizing a canonical spelling returns it unchanged. -/
theorem canon_idem : ∀ s : String, canon (canon s) = canon s := by
  intro s
  rcases canon_cases s with h | ⟨e, -, hl, -, h⟩
  · rw [h]; exact h
  · rw [h]; exact canon_spell _ hl

/-- **The canonical spelling keeps the factors.** If a unit string parses, its
canonical spelling parses too, to a tree with the same normalized factor list. -/
theorem parse_canon :
    ∀ (s : String) (e : UExpr), parseChars s.toList = .ok e →
      ∃ e', parseChars (canon s).toList = .ok e' ∧ norm2 e'.factors = norm2 e.factors := by
  intro s e h
  rcases canon_cases s with hc | ⟨e₀, he₀, hl, -, hc⟩
  · exact ⟨e, by rw [hc]; exact h, rfl⟩
  · rw [h] at he₀; cases he₀
    obtain ⟨e', he', -, hn⟩ := parse_spell _ hl
    exact ⟨e', by rw [hc]; exact he', hn⟩

/-- Two strings whose parses have the same normalized factor list, all of whose
symbols the spelling can write, and neither of which drops a symbol naming no unit,
have the same canonical spelling. (Strings that resolve never drop such a symbol:
`keepsSyms_of_eval`.) -/
theorem canon_eq_of_factors :
    ∀ (s t : String) (e e' : UExpr), parseChars s.toList = .ok e → parseChars t.toList = .ok e' →
      norm2 e.factors = norm2 e'.factors → (norm2 e.factors).all (fun f => symOK f.1) = true →
      keepsSyms e = true → keepsSyms e' = true → canon s = canon t := by
  intro s t e e' hs ht hn hv hk hk'
  have hv' : (norm2 e'.factors).all (fun f => symOK f.1) = true := hn ▸ hv
  unfold canon
  rw [hs, ht]
  simp only [hv', hk, hk', Bool.and_self, ite_true, hn]

/-! ## The canonical spelling denotes the same unit -/

/-- What a symbol denotes, as a vector (dimension, scale exponents). -/
def vsym (s : String) : Dim × (Base → ℚ) := (sym s).val

theorem wsum_append {M : Type*} [AddCommGroup M] [Module ℚ M] (v : String → M)
    (a b : List Factor) : wsum v (a ++ b) = wsum v a + wsum v b := by
  simp [wsum]

theorem wsum_scale {M : Type*} [AddCommGroup M] [Module ℚ M] (v : String → M) (q : ℚ)
    (a : List Factor) : wsum v (a.map fun f => (f.1, q * f.2)) = q • wsum v a := by
  induction a with
  | nil => simp [wsum]
  | cons f a ih =>
    simp only [wsum, List.map_cons, List.sum_cons] at ih ⊢
    rw [ih, smul_add, mul_smul]

theorem wsum_neg {M : Type*} [AddCommGroup M] [Module ℚ M] (v : String → M)
    (a : List Factor) : wsum v (a.map fun f => (f.1, -f.2)) = (-1 : ℚ) • wsum v a := by
  rw [← wsum_scale]; congr 1; simp

theorem val_dimensionless : (sym "dimensionless").val = 0 := by
  have h : (sym "dimensionless").Agree U.one := by
    rw [U.agree_iff]
    exact ⟨dim_ext fun a => by cases a <;> rfl, Scale.exp_ofRat_one⟩
  rw [U.Agree] at h; rw [h, U.val_one]

theorem lookup_eq_sym {s : String} {u : U} (h : lookup s = some u) : u = sym s := by
  simp [sym, h]

/-- A tree that evaluates names only table keys, and its unit is the weighted sum
of its factors. -/
theorem eval_factors :
    ∀ (e : UExpr) (u : U), e.eval = .ok u →
      (∀ f ∈ e.factors, f.1 ∈ keys) ∧ u.val = wsum vsym e.factors := by
  intro e
  induction e with
  | one => intro u h; cases h; simp [UExpr.factors, wsum, U.val_one]
  | sym s =>
    intro u h
    simp only [UExpr.eval] at h
    cases hl : lookup s with
    | none => rw [hl] at h; cases h
    | some u' =>
      rw [hl] at h; cases h
      have hk : s ∈ keys := (lookup_isSome_iff s).mp (by simp [hl])
      rw [lookup_eq_sym hl]
      by_cases hd : s = "dimensionless"
      · subst hd; simp [UExpr.factors, wsum, val_dimensionless]
      · simp [UExpr.factors, hd, wsum, vsym, hk]
  | mul a b iha ihb =>
    intro u h
    simp only [UExpr.eval] at h
    cases ha : a.eval with
    | error _ => rw [ha] at h; cases h
    | ok ua =>
      cases hb : b.eval with
      | error _ => rw [ha, hb] at h; cases h
      | ok ub =>
        rw [ha, hb] at h; cases h
        obtain ⟨ka, va⟩ := iha ua ha
        obtain ⟨kb, vb⟩ := ihb ub hb
        refine ⟨fun f hf => ?_, ?_⟩
        · simp only [UExpr.factors, List.mem_append] at hf
          rcases hf with hf | hf; exact ka f hf; exact kb f hf
        · simp [UExpr.factors, wsum_append, va, vb]
  | div a b iha ihb =>
    intro u h
    simp only [UExpr.eval] at h
    cases ha : a.eval with
    | error _ => rw [ha] at h; cases h
    | ok ua =>
      cases hb : b.eval with
      | error _ => rw [ha, hb] at h; cases h
      | ok ub =>
        rw [ha, hb] at h; cases h
        obtain ⟨ka, va⟩ := iha ua ha
        obtain ⟨kb, vb⟩ := ihb ub hb
        refine ⟨fun f hf => ?_, ?_⟩
        · simp only [UExpr.factors, List.mem_append, List.mem_map] at hf
          rcases hf with hf | ⟨g, hg, rfl⟩; exact ka f hf; exact kb g hg
        · simp [UExpr.factors, wsum_append, wsum_neg, va, vb, U.div, U.inv]
  | pow a q ih =>
    intro u h
    simp only [UExpr.eval] at h
    cases ha : a.eval with
    | error _ => rw [ha] at h; cases h
    | ok ua =>
      rw [ha] at h; cases h
      obtain ⟨ka, va⟩ := ih ua ha
      refine ⟨fun f hf => ?_, ?_⟩
      · simp only [UExpr.factors, List.mem_map] at hf
        obtain ⟨g, hg, rfl⟩ := hf; exact ka g hg
      · simp [UExpr.factors, wsum_scale, va]

/-- A tree whose factors are all table keys evaluates, to the weighted sum. -/
theorem eval_of_keys :
    ∀ e : UExpr, (∀ f ∈ e.factors, f.1 ∈ keys) →
      ∃ u, e.eval = .ok u ∧ u.val = wsum vsym e.factors := by
  intro e
  induction e with
  | one => intro _; exact ⟨U.one, rfl, by simp [UExpr.factors, wsum, U.val_one]⟩
  | sym s =>
    intro hk
    by_cases hd : s = "dimensionless"
    · subst hd
      exact ⟨sym "dimensionless", rfl, by simp [UExpr.factors, wsum, val_dimensionless]⟩
    · have hs : s ∈ keys := hk (s, 1) (by simp [UExpr.factors, hd])
      obtain ⟨u, hu⟩ := Option.isSome_iff_exists.mp ((lookup_isSome_iff s).mpr hs)
      refine ⟨u, by simp [UExpr.eval, hu], ?_⟩
      rw [lookup_eq_sym hu]; simp [UExpr.factors, hd, wsum, vsym]
  | mul a b iha ihb =>
    intro hk
    obtain ⟨ua, ha, va⟩ := iha (fun f hf => hk f (by simp [UExpr.factors, hf]))
    obtain ⟨ub, hb, vb⟩ := ihb (fun f hf => hk f (by simp [UExpr.factors, hf]))
    exact ⟨ua.mul ub, by rw [UExpr.eval, ha, hb]; rfl, by simp [UExpr.factors, wsum_append, va, vb]⟩
  | div a b iha ihb =>
    intro hk
    obtain ⟨ua, ha, va⟩ := iha (fun f hf => hk f (by simp [UExpr.factors, hf]))
    obtain ⟨ub, hb, vb⟩ := ihb (fun f hf => hk (f.1, -f.2)
      (by simp only [UExpr.factors, List.mem_append, List.mem_map]; exact Or.inr ⟨f, hf, rfl⟩))
    exact ⟨ua.div ub, by rw [UExpr.eval, ha, hb]; rfl,
      by simp [UExpr.factors, wsum_append, wsum_neg, va, vb, U.div, U.inv]⟩
  | pow a q ih =>
    intro hk
    obtain ⟨ua, ha, va⟩ := ih (fun f hf => hk (f.1, q * f.2)
      (by simp only [UExpr.factors, List.mem_map]; exact ⟨f, hf, rfl⟩))
    exact ⟨ua.rpow q, by rw [UExpr.eval, ha]; rfl, by simp [UExpr.factors, wsum_scale, va]⟩

theorem resolve_eq_parseChars (s : String) (h : s.toList ≠ []) :
    resolve s = parseChars s.toList >>= UExpr.eval := by
  rw [resolve, resolveChars_eq _ h, parseChars, ite_eq_right h]

theorem spell_ne_nil (l : List Factor) (hl : CanonFactors l) : (spell l).toList ≠ [] := by
  obtain ⟨e, he, -⟩ := parse_spell l hl
  intro h
  have := lexP_spellToks l hl
  unfold spell at h
  rw [String.toList_ofList] at h
  have h1 := this.1
  rw [h] at h1
  exact spellToks_ne_nil l (List.eq_nil_of_length_eq_zero (by simpa using h1))

/-- **The canonical spelling denotes the same unit.** If a unit string resolves
(§4.8.1, §4.8.2), its canonical spelling resolves to a unit that agrees with it:
same dimension, same exact scale. -/
theorem resolve_canon :
    ∀ (s : String) (u : U), resolve s = .ok u → ∃ u', resolve (canon s) = .ok u' ∧ u'.Agree u := by
  intro s u h
  rcases canon_cases s with hc | ⟨e, he, hl, -, hc⟩
  · exact ⟨u, by rw [hc]; exact h, U.agree_refl u⟩
  obtain ⟨e', he', hfac, -⟩ := parse_spell _ hl
  -- what the original denotes
  have hu : (∀ f ∈ e.factors, f.1 ∈ keys) ∧ u.val = wsum vsym e.factors ∨
      (s.toList = [] ∧ u = sym "") := by
    by_cases hs : s.toList = []
    · right; refine ⟨hs, ?_⟩
      rw [resolve, resolveChars, ite_eq_left hs] at h; cases h; rfl
    · left
      rw [resolve_eq_parseChars s hs, he] at h
      exact eval_factors e u h
  have hk' : ∀ f ∈ e'.factors, f.1 ∈ keys := by
    intro f hf
    have hfl : f ∈ norm2 e.factors := hfac ▸ hf
    have hfs := syms_norm2_sub e.factors f hfl
    rcases hu with ⟨hk, -⟩ | ⟨hs, -⟩
    · obtain ⟨g, hg, hgs⟩ := List.mem_map.mp hfs
      exact hgs ▸ hk g hg
    · simp only [parseChars, hs, ite_true] at he; cases he
      simp [UExpr.factors, syms] at hfs
  obtain ⟨u', hu', hv'⟩ := eval_of_keys e' hk'
  refine ⟨u', ?_, ?_⟩
  · rw [hc, resolve_eq_parseChars _ (spell_ne_nil _ hl), he']; exact hu'
  · show u'.val = u.val
    rw [hv', hfac, wsum_congr vsym (expOf_norm2 e.factors)]
    rcases hu with ⟨-, hv⟩ | ⟨hs, rfl⟩
    · exact hv.symm
    · simp only [parseChars, hs, ite_true] at he; cases he
      have : (sym "").Agree U.one := by
        rw [U.agree_iff]
        exact ⟨dim_ext fun a => by cases a <;> rfl, Scale.exp_ofRat_one⟩
      rw [U.Agree] at this
      simp [UExpr.factors, wsum, this, U.val_one]

/-- A tree that evaluates drops no symbol naming no unit. -/
theorem keepsSyms_of_eval (e : UExpr) (u : U) (h : e.eval = .ok u) : keepsSyms e = true := by
  rw [keepsSyms, List.all_eq_true]
  intro f hf
  rw [Bool.or_eq_true]
  right
  exact (lookup_isSome_iff f.1).mpr ((eval_factors e u h).1 f hf)

/-- **Canonicalization does not hide an unresolvable unit.** If the canonical
spelling of a string resolves, the string itself resolves, to a unit that agrees
with it. -/
theorem resolve_of_canon :
    ∀ (s : String) (u' : U), resolve (canon s) = .ok u' → ∃ u, resolve s = .ok u ∧ u'.Agree u := by
  intro s u' h
  suffices hs : ∃ u, resolve s = .ok u by
    obtain ⟨u, hu⟩ := hs
    obtain ⟨u'', h'', hag⟩ := resolve_canon s u hu
    rw [h] at h''; cases h''
    exact ⟨u, hu, hag⟩
  rcases canon_cases s with hc | ⟨e, he, hl, hk, hc⟩
  · exact ⟨u', hc ▸ h⟩
  by_cases hs : s.toList = []
  · exact ⟨_, by rw [resolve, resolveChars, ite_eq_left hs]⟩
  obtain ⟨e', he', hfac, -⟩ := parse_spell _ hl
  rw [hc, resolve_eq_parseChars _ (spell_ne_nil _ hl), he'] at h
  have hk' := (eval_factors e' u' h).1
  rw [hfac] at hk'
  have hkeys : ∀ f ∈ e.factors, f.1 ∈ keys := by
    intro f hf
    have := List.all_eq_true.mp hk f hf
    rw [Bool.or_eq_true] at this
    rcases this with h1 | h1
    · obtain ⟨g, hg, hgs⟩ : ∃ g ∈ norm2 e.factors, g.1 = f.1 := by
        simpa [syms] using h1
      exact hgs ▸ hk' g hg
    · exact (lookup_isSome_iff f.1).mp h1
  obtain ⟨u, hu, -⟩ := eval_of_keys e hkeys
  exact ⟨u, by rw [resolve_eq_parseChars s hs, he]; exact hu⟩

end Esm.Units
