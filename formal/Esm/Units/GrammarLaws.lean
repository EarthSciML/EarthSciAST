import Esm.Units.Grammar

/-!
# Laws of the unit-string grammar (esm-spec §4.8.2)

* `*`, `/` and juxtaposition are one precedence level, folded LEFT to right
  (`parse_fold`), and `^`/`**` binds tighter than all three (`parse_pow_binds`).
* A numeric atom other than 1 is a scaling factor wherever it stands
  (`parse_scaling_factor_head`, `parse_scaling_factor_after`).
* `-` is not an operator (`parse_minus_rejected`, `resolve_minus_rejected`).
* Whitespace between terms is multiplication (`resolve_space_eq_star`).
* The table is flat: a single run of identifier characters resolves iff it is a
  table key exactly as spelled — no SI-prefix mechanism, no implicit split
  (`resolve_ident_run`).
-/

namespace Esm.Units

/-! ## Token level -/

/-- The three spellings of the one precedence level. -/
inductive Op
  | star | slash | juxt
  deriving DecidableEq, Repr

/-- `op b` sequences as tokens. -/
def opToks : List (Op × String) → List Tok
  | [] => []
  | (.star, b) :: r => .star :: .sym b :: opToks r
  | (.slash, b) :: r => .slash :: .sym b :: opToks r
  | (.juxt, b) :: r => .sym b :: opToks r

/-- The left fold the spec prescribes. -/
def foldOps (acc : UExpr) : List (Op × String) → UExpr
  | [] => acc
  | (.star, b) :: r => foldOps (.mul acc (.sym b)) r
  | (.slash, b) :: r => foldOps (.div acc (.sym b)) r
  | (.juxt, b) :: r => foldOps (.mul acc (.sym b)) r

/-- The token list does not start with `^` or `**`. -/
def NoPowHead (ts : List Tok) : Prop := ∀ ts', ts ≠ .caret :: ts' ∧ ts ≠ .dstar :: ts'

theorem pTerm_sym (n : ℕ) (s : String) (ts : List Tok) (h : NoPowHead ts) :
    pTerm (n + 2) (.sym s :: ts) = .ok (.sym s, ts) := by
  cases ts with
  | nil => simp [pTerm, pAtom]
  | cons t ts =>
    cases t <;> simp_all [pTerm, pAtom, NoPowHead]

theorem noPowHead_opToks_append (ops : List (Op × String)) (ts : List Tok) (h : NoPowHead ts) :
    NoPowHead (opToks ops ++ ts) := by
  match ops with
  | [] => simpa [opToks] using h
  | (.star, _) :: _ => simp [opToks, NoPowHead]
  | (.slash, _) :: _ => simp [opToks, NoPowHead]
  | (.juxt, _) :: _ => simp [opToks, NoPowHead]

theorem pTail_ops (ops : List (Op × String)) (ts : List Tok) (hts : NoPowHead ts) :
    ∀ (acc : UExpr) (n k : ℕ), 3 * ops.length + k ≤ n →
      ∃ m, k ≤ m ∧ pTail n acc (opToks ops ++ ts) = pTail m (foldOps acc ops) ts := by
  induction ops with
  | nil => intro acc n k h; exact ⟨n, by simpa using h, by simp [opToks, foldOps]⟩
  | cons x r ih =>
    intro acc n k h
    obtain ⟨op, b⟩ := x
    have hX := noPowHead_opToks_append r ts hts
    obtain ⟨j, rfl⟩ : ∃ j, n = j + 3 := ⟨n - 3, by simp at h; omega⟩
    have hlen : 3 * r.length + k ≤ j + 2 := by simp at h; omega
    cases op with
    | star =>
      obtain ⟨m, hm, e⟩ := ih (.mul acc (.sym b)) (j + 2) k hlen
      refine ⟨m, hm, ?_⟩
      simp only [opToks, List.cons_append, foldOps]
      rw [pTail, pTerm_sym j b _ hX]; exact e
    | slash =>
      obtain ⟨m, hm, e⟩ := ih (.div acc (.sym b)) (j + 2) k hlen
      refine ⟨m, hm, ?_⟩
      simp only [opToks, List.cons_append, foldOps]
      rw [pTail, pTerm_sym j b _ hX]; exact e
    | juxt =>
      obtain ⟨m, hm, e⟩ := ih (.mul acc (.sym b)) (j + 2) k hlen
      refine ⟨m, hm, ?_⟩
      simp only [opToks, List.cons_append, foldOps]
      rw [pTail.eq_def]
      simp only [startsTerm, if_true]
      rw [pTerm_sym j b _ hX]; exact e

theorem length_opToks (ops : List (Op × String)) : ops.length ≤ (opToks ops).length := by
  induction ops with
  | nil => simp [opToks]
  | cons x r ih => obtain ⟨op, b⟩ := x; cases op <;> simp [opToks] <;> omega

/-- The parse of `a`, and of `pUnit` after it, through the left fold. -/
theorem pUnit_fold (a : String) (ops : List (Op × String)) (ts : List Tok) (hts : NoPowHead ts)
    (n k : ℕ) (h : 3 * ops.length + k + 3 ≤ n) :
    ∃ m, k ≤ m ∧ pUnit n (.sym a :: opToks ops ++ ts) = pTail m (foldOps (.sym a) ops) ts := by
  obtain ⟨j, rfl⟩ : ∃ j, n = j + 3 := ⟨n - 3, by omega⟩
  have hX := noPowHead_opToks_append ops ts hts
  rw [pUnit, List.cons_append, pTerm_sym j a _ hX]
  exact pTail_ops ops ts hts (.sym a) (j + 2) k (by omega)

/-- `*`, `/` and juxtaposition are ONE precedence level, evaluated LEFT to RIGHT:
any chain of symbols joined by them parses as the left fold. (`J/mol*K` is
`(J/mol)*K`; `L/mol/s` is `(L/mol)/s`; `kg/m*s` is `(kg/m)*s`.) -/
theorem parse_fold :
    ∀ (a : String) (ops : List (Op × String)),
      parse (.sym a :: opToks ops) = .ok (foldOps (.sym a) ops) := by
  intro a ops
  have hl := length_opToks ops
  obtain ⟨m, hm, e⟩ := pUnit_fold a ops [] (by simp [NoPowHead]) (4 * (Tok.sym a :: opToks ops).length + 8)
    1 (by simp; omega)
  obtain ⟨m', rfl⟩ : ∃ m', m = m' + 1 := ⟨m - 1, by omega⟩
  have e' : pUnit (4 * (Tok.sym a :: opToks ops).length + 8) (.sym a :: opToks ops)
      = .ok (foldOps (.sym a) ops, []) := by
    simpa [pTail, startsTerm] using e
  unfold parse
  rw [e']

/-- `-` is not an operator: a `-` after any chain of terms is rejected. (This is
why MOVES's `g/hp-hr` does not resolve.) -/
theorem parse_minus_rejected :
    ∀ (a : String) (ops : List (Op × String)) (rest : List Tok),
      ∃ err, parse (.sym a :: opToks ops ++ .minus :: rest) = .error err := by
  intro a ops rest
  have hl := length_opToks ops
  obtain ⟨m, hm, e⟩ := pUnit_fold a ops (.minus :: rest) (by simp [NoPowHead])
    (4 * (Tok.sym a :: opToks ops ++ .minus :: rest).length + 8) 1 (by simp; omega)
  obtain ⟨m', rfl⟩ : ∃ m', m = m' + 1 := ⟨m - 1, by omega⟩
  rw [pTail] at e
  unfold parse
  rw [e]
  exact ⟨_, rfl⟩

/-- A numeric atom whose value is not 1 is a scaling factor — at the head of
a unit string (`1000/s`, `0.5 m`) … -/
theorem parse_scaling_factor_head :
    ∀ (lit : String) (v : ℚ) (i : Bool) (ts : List Tok), v ≠ 1 →
      parse (.num lit v i :: ts) = .error (.scalingFactor lit) := by
  intro lit v i ts hv
  have : 4 * (Tok.num lit v i :: ts).length + 8 = (4 * ts.length + 9) + 3 := by simp; ring
  unfold parse
  rw [this]
  simp [pUnit, pTerm, pAtom, hv]

/-- … and after any chain of terms and an operator (`(m/s)^-1/3` reads as
`((m/s)^-1)/3`: the `3` is a scaling factor, not part of an exponent). -/
theorem parse_scaling_factor_after :
    ∀ (a : String) (ops : List (Op × String)) (op : Tok) (lit : String) (v : ℚ) (i : Bool)
      (rest : List Tok), (op = .star ∨ op = .slash) → v ≠ 1 →
      parse (.sym a :: opToks ops ++ op :: .num lit v i :: rest) = .error (.scalingFactor lit) := by
  intro a ops op lit v i rest hop hv
  have hl := length_opToks ops
  obtain ⟨m, hm, e⟩ := pUnit_fold a ops (op :: .num lit v i :: rest)
    (by rcases hop with rfl | rfl <;> simp [NoPowHead])
    (4 * (Tok.sym a :: opToks ops ++ op :: .num lit v i :: rest).length + 8) 3 (by simp; omega)
  obtain ⟨m', rfl⟩ : ∃ m', m = m' + 3 := ⟨m - 3, by omega⟩
  unfold parse
  rw [e]
  rcases hop with rfl | rfl <;> simp [pTail, pTerm, pAtom, hv]

/-- `^` and `**` bind tighter than `/` (and `*`, juxtaposition): `a/b^q` is
`a / (b^q)`, for a signed or unsigned numeric exponent. -/
theorem parse_pow_binds :
    ∀ (a b lit : String) (q : ℚ) (i : Bool) (pw : Tok), (pw = .caret ∨ pw = .dstar) →
      parse [.sym a, .slash, .sym b, pw, .num lit q i] = .ok (.div (.sym a) (.pow (.sym b) q)) ∧
      parse [.sym a, .slash, .sym b, pw, .minus, .num lit q i] =
        .ok (.div (.sym a) (.pow (.sym b) (-q))) := by
  intro a b lit q i pw hpw
  rcases hpw with rfl | rfl <;>
    exact ⟨by simp [parse, pUnit, pTerm, pAtom, pTail, pExp, startsTerm],
      by simp [parse, pUnit, pTerm, pAtom, pTail, pExp, startsTerm]⟩

/-- Rational exponents: `^(p/q)` and `^(-p/q)` are the exponent `±p/q`, exactly. -/
theorem pExp_rational :
    ∀ (p q : ℕ) (neg : Bool) (lp lq : String) (ts : List Tok), q ≠ 0 →
      pExp (.lp :: (if neg then [Tok.minus] else []) ++
        .num lp (p : ℚ) true :: .slash :: .num lq (q : ℚ) true :: .rp :: ts)
        = .ok ((if neg then -(p : ℚ) else p) / q, ts) := by
  intro p q neg lp lq ts hq
  have hq' : (q : ℚ) ≠ 0 := by exact_mod_cast hq
  cases neg <;> simp [pExp, pInt, hq']

/-! ## Character level -/

/-- A run of identifier characters that starts with a letter: what the lexer
reads as ONE symbol token. -/
def IdentRun (a : List Char) : Prop :=
  ∃ c t, a = c :: t ∧ isAlphaC c = true ∧ ∀ x ∈ t, isIdent x = true

def identRunB : List Char → Bool
  | [] => false
  | c :: t => isAlphaC c && t.all isIdent

theorem identRun_of_B (a : List Char) (h : identRunB a = true) : IdentRun a := by
  cases a with
  | nil => simp [identRunB] at h
  | cons c t =>
    simp only [identRunB, Bool.and_eq_true, List.all_eq_true] at h
    exact ⟨c, t, rfl, h.1, h.2⟩

theorem isIdent_of_alpha {c : Char} (h : isAlphaC c = true) : isIdent c = true := by
  simp [isIdent, h]

theorem not_digit_of_alpha {c : Char} (h : isAlphaC c = true) : isDigitC c = false := by
  simp [isAlphaC, isDigitC, Char.le_def, UInt32.le_iff_toNat_le] at *
  omega

theorem ascii_of_ident {c : Char} (h : isIdent c = true) : c.toNat < 128 := by
  simp [isIdent, isAlphaC, isDigitC, Char.le_def, UInt32.le_iff_toNat_le] at h
  have : c.toNat = c.val.toNat := rfl
  rcases h with (h | h) | h | h <;> first | omega | decide | (subst h; decide)

theorem ne_of_alpha {c : Char} (h : isAlphaC c = true) (d : Char) (hd : isAlphaC d = false) :
    c ≠ d := by
  rintro rfl; rw [h] at hd; exact Bool.noConfusion hd

theorem isSpace_of_alpha {c : Char} (h : isAlphaC c = true) : isSpace c = false := by
  unfold isSpace
  have h1 := ne_of_alpha h ' ' (by decide)
  have h2 := ne_of_alpha h '\t' (by decide)
  have h3 := ne_of_alpha h '\n' (by decide)
  have h4 := ne_of_alpha h '\r' (by decide)
  simp [h1, h2, h3, h4]

theorem span_append (p : Char → Bool) (a rest : List Char) (ha : ∀ x ∈ a, p x = true)
    (hr : ∀ c r, rest = c :: r → p c = false) : (a ++ rest).span p = (a, rest) := by
  rw [List.span_eq_takeWhile_dropWhile]
  induction a with
  | nil =>
    cases rest with
    | nil => simp
    | cons c r => have := hr c r rfl; simp [List.takeWhile_cons, List.dropWhile_cons, this]
  | cons x a ih =>
    have hx := ha x (by simp)
    have ih' := ih (fun y hy => ha y (by simp [hy]))
    simp only [Prod.mk.injEq] at ih'
    simp [List.takeWhile_cons_of_pos hx, List.dropWhile_cons_of_pos hx, ih'.1, ih'.2]

/-- The rest after a symbol run: empty or starting with a non-identifier
character. -/
def RunEnds (rest : List Char) : Prop := ∀ c r, rest = c :: r → isIdent c = false

theorem lexAux_run (a rest : List Char) (ha : IdentRun a) (hr : RunEnds rest) (k : ℕ) :
    lexAux (k + 1) (a ++ rest) = (Tok.sym (String.ofList a) :: ·) <$> lexAux k rest := by
  obtain ⟨c, t, rfl, hc, ht⟩ := ha
  have hspan : (c :: (t ++ rest)).span isIdent = (c :: t, rest) := by
    have := span_append isIdent (c :: t) rest
      (by intro x hx; simp at hx; rcases hx with rfl | hx; exact isIdent_of_alpha hc; exact ht x hx)
      hr
    simpa using this
  have hall : (c :: t).all isDigitC = false := by simp [not_digit_of_alpha hc]
  rw [List.cons_append, lexAux.eq_def]
  dsimp only
  rw [if_neg (by simp [isSpace_of_alpha hc]), if_neg (ne_of_alpha hc '*' (by decide)),
    if_neg (ne_of_alpha hc '/' (by decide)), if_neg (ne_of_alpha hc '^' (by decide)),
    if_neg (ne_of_alpha hc '(' (by decide)), if_neg (ne_of_alpha hc ')' (by decide)),
    if_neg (ne_of_alpha hc '-' (by decide)), if_neg (ne_of_alpha hc '%' (by decide)),
    if_pos (isIdent_of_alpha hc)]
  simp only [hspan, hall, Bool.false_eq_true, ite_false]

theorem lexAux_nil (k : ℕ) : lexAux (k + 1) [] = .ok [] := by simp [lexAux]

/-- On ASCII input the Unicode rewrite is the identity. -/
theorem normalizeAux_ascii : ∀ (n : ℕ) (cs : List Char), (∀ x ∈ cs, x.toNat < 128) →
    normalizeAux n cs = cs := by
  intro n
  induction n with
  | zero => intro cs _; rfl
  | succ n ih =>
    intro cs h
    cases cs with
    | nil => rfl
    | cons c cs =>
      have hc : c.toNat < 128 := h c (by simp)
      have hcs := ih cs (fun x hx => h x (by simp [hx]))
      have ne : ∀ d : Char, 128 ≤ d.toNat → c ≠ d := by
        rintro d hd rfl; omega
      have hsup : isSup c = false := by
        unfold isSup supDigit
        simp [ne '⁰' (by decide), ne '¹' (by decide), ne '²' (by decide),
          ne '³' (by decide), ne '⁴' (by decide), ne '⁵' (by decide),
          ne '⁶' (by decide), ne '⁷' (by decide), ne '⁸' (by decide),
          ne '⁹' (by decide)]
      rw [normalizeAux]
      simp [ne '°' (by decide), ne '·' (by decide), ne '⋅' (by decide),
        ne 'µ' (by decide), ne 'μ' (by decide), ne 'Ω' (by decide),
        ne 'Ω' (by decide), ne '⁻' (by decide), hsup, hcs]

theorem normalize_ascii (cs : List Char) (h : ∀ x ∈ cs, x.toNat < 128) : normalize cs = cs :=
  normalizeAux_ascii _ cs h

theorem identRun_ascii {a : List Char} (ha : IdentRun a) : ∀ x ∈ a, x.toNat < 128 := by
  obtain ⟨c, t, rfl, hc, ht⟩ := ha
  intro x hx
  simp at hx
  rcases hx with rfl | hx
  · exact ascii_of_ident (isIdent_of_alpha hc)
  · exact ascii_of_ident (ht x hx)

theorem identRun_ne_nil {a : List Char} (ha : IdentRun a) : a ≠ [] := by
  obtain ⟨c, t, rfl, -, -⟩ := ha; simp

theorem lex_run (a : List Char) (ha : IdentRun a) : lex a = .ok [.sym (String.ofList a)] := by
  have := lexAux_run a [] ha (by intro c r h; cases h) a.length
  simp only [List.append_nil] at this
  obtain ⟨c, t, rfl, -, -⟩ := ha
  rw [lex, this]
  simp only [List.length_cons, lexAux_nil]; rfl

/-- The table is FLAT, and there is NO SI-prefix mechanism: a run of identifier
characters resolves iff it is a §4.8.1 key exactly as spelled. So `mm` resolves
because it is a key, and `kmolec`, `nppb`, `Tm`, `cm3` do not, because they are
not — nothing composes a prefix with a symbol, or splits a run. -/
theorem resolve_ident_run :
    ∀ a : List Char, IdentRun a → ((∃ u, resolveChars a = .ok u) ↔ String.ofList a ∈ keys) := by
  intro a ha
  have hp : parse [.sym (String.ofList a)] = .ok (.sym (String.ofList a)) := by
    simpa [opToks, foldOps] using parse_fold (String.ofList a) []
  unfold resolveChars
  rw [if_neg (identRun_ne_nil ha), normalize_ascii a (identRun_ascii ha), lex_run a ha]
  simp only [bind, Except.bind, hp, UExpr.eval]
  rw [← lookup_isSome_iff]
  cases lookup (String.ofList a) <;> simp

/-- The same, for strings. -/
theorem resolves_ident_run :
    ∀ s : String, IdentRun s.toList → (Resolves s ↔ s ∈ keys) := by
  intro s hs
  have := resolve_ident_run s.toList hs
  rw [String.ofList_toList] at this
  exact this

theorem lex_two (a b : List Char) (sep : Char) (ha : IdentRun a) (hb : IdentRun b)
    (hsep : isIdent sep = false) (tok : List Tok)
    (hstep : ∀ k, lexAux (k + 1) (sep :: b) = (tok ++ ·) <$> lexAux k b) :
    lex (a ++ sep :: b) = .ok (.sym (String.ofList a) :: tok ++ [.sym (String.ofList b)]) := by
  have hr : RunEnds (sep :: b) := by intro c r h; cases h; exact hsep
  have ha' := ha
  have hb' := hb
  obtain ⟨c, t, rfl, -, -⟩ := ha'
  obtain ⟨d, u, rfl, -, -⟩ := hb'
  have hlen : (c :: t ++ sep :: d :: u).length + 1 = (t.length + u.length + 3) + 1 := by
    simp; omega
  rw [lex, hlen, lexAux_run _ (sep :: d :: u) ha hr, hstep]
  have e := lexAux_run (d :: u) [] hb (by intro c r h; cases h) (t.length + u.length + 1)
  simp only [List.append_nil] at e
  rw [e, lexAux_nil]; rfl

/-- WHITESPACE between terms means MULTIPLICATION: `a b` resolves exactly as
`a*b`, for any two symbol runs. -/
theorem resolve_space_eq_star :
    ∀ a b : List Char, IdentRun a → IdentRun b →
      resolveChars (a ++ ' ' :: b) = resolveChars (a ++ '*' :: b) := by
  intro a b ha hb
  have hascii : ∀ sep : Char, sep.toNat < 128 → ∀ x ∈ a ++ sep :: b, x.toNat < 128 := by
    intro sep hs x hx
    simp only [List.mem_append, List.mem_cons] at hx
    rcases hx with hx | rfl | hx
    · exact identRun_ascii ha x hx
    · exact hs
    · exact identRun_ascii hb x hx
  have lsp : lex (a ++ ' ' :: b) = .ok [.sym (String.ofList a), .sym (String.ofList b)] := by
    simpa using lex_two a b ' ' ha hb (by decide) [] (fun k => by simp [lexAux, isSpace])
  have lst : lex (a ++ '*' :: b) =
      .ok [.sym (String.ofList a), .star, .sym (String.ofList b)] := by
    refine (lex_two a b '*' ha hb (by decide) [.star] (fun k => ?_)).trans (by simp)
    obtain ⟨c, t, rfl, hc, -⟩ := hb
    simp [lexAux, isSpace, ne_of_alpha hc '*' (by decide)]
  have pj : parse [.sym (String.ofList a), .sym (String.ofList b)] =
      .ok (.mul (.sym (String.ofList a)) (.sym (String.ofList b))) := by
    simpa [opToks, foldOps] using parse_fold (String.ofList a) [(.juxt, String.ofList b)]
  have ps : parse [.sym (String.ofList a), .star, .sym (String.ofList b)] =
      .ok (.mul (.sym (String.ofList a)) (.sym (String.ofList b))) := by
    simpa [opToks, foldOps] using parse_fold (String.ofList a) [(.star, String.ofList b)]
  unfold resolveChars
  have ne : ∀ sep : Char, a ++ sep :: b ≠ [] := by simp
  rw [if_neg (ne ' '), if_neg (ne '*'), normalize_ascii _ (hascii ' ' (by decide)),
    normalize_ascii _ (hascii '*' (by decide)), lsp, lst]
  simp only [bind, Except.bind, pj, ps]

/-- `-` is not an operator, at the string level: `a-b` never resolves. -/
theorem resolve_minus_rejected :
    ∀ a b : List Char, IdentRun a → IdentRun b → ¬ ∃ u, resolveChars (a ++ '-' :: b) = .ok u := by
  intro a b ha hb
  have hascii : ∀ x ∈ a ++ '-' :: b, x.toNat < 128 := by
    intro x hx
    simp only [List.mem_append, List.mem_cons] at hx
    rcases hx with hx | rfl | hx
    · exact identRun_ascii ha x hx
    · decide
    · exact identRun_ascii hb x hx
  have lm : lex (a ++ '-' :: b) =
      .ok [.sym (String.ofList a), .minus, .sym (String.ofList b)] := by
    refine (lex_two a b '-' ha hb (by decide) [.minus] (fun k => ?_)).trans (by simp)
    obtain ⟨c, t, rfl, hc, -⟩ := hb
    simp [lexAux, isSpace]
  obtain ⟨err, he⟩ := parse_minus_rejected (String.ofList a) [] [.sym (String.ofList b)]
  simp only [opToks, List.cons_append, List.nil_append] at he
  unfold resolveChars
  rw [if_neg (by simp), normalize_ascii _ hascii, lm]
  simp [bind, Except.bind, he]

/-! ## The listed exclusions -/

/-- The exclusions §4.8.1 states (no `ton`, no `t`, no `d`; the imperial family is
symbol-only: no `in`, `yd`, `foot`, `feet`, `mile`, `miles`, fused `mph`; full
spellings only), plus prefixed spellings the flat table does not hold
(`kmolec`, `nppb`, `Tm`, `dam`, `cm3`). None of them resolves. -/
theorem exclusions_do_not_resolve :
    ∀ s ∈ ["ton", "t", "d", "in", "yd", "foot", "feet", "mile", "miles", "mph", "tons",
      "metric_ton", "short_tons", "gallon", "pound", "kmolec", "nppb", "Tm", "dam", "dg",
      "PW", "fs", "cm3", "s2"], ¬ Resolves s := by
  intro s hs
  have hrun : identRunB s.toList = true := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
      rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  have hkey : s ∉ keys := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
      rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  rw [resolves_ident_run s (identRun_of_B _ hrun)]
  exact hkey

/-- `hp-hr` (MOVES's spelling of `g/hp-hr`'s denominator) does not resolve. -/
theorem hp_hr_rejected : ¬ Resolves "hp-hr" := by
  rintro ⟨u, hu⟩
  exact resolve_minus_rejected ['h', 'p'] ['h', 'r'] (identRun_of_B _ (by decide))
    (identRun_of_B _ (by decide)) ⟨u, hu⟩

end Esm.Units
