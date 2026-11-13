import Esm.Document.Math.Typst
import Esm.Document.Math.LexLatex

/-!
# The Typst lexer lemma

Every list of Typst tokens (`tokOK`) in which each call parenthesis follows a token
after which `(` is a call parenthesis (`CallOK`) reads back from its rendering. The
proof goes token by token, as for LaTeX; the one Typst-specific step is the
parenthesis: the lexer tells a call `(` from a grouping `(` by the character before
it, and the renderer writes a space before a grouping `(` exactly when that
character would make it a call.
-/

namespace Esm.Document.Math.Typst

open Esm.Document Esm.Document.Math

/-! ## Tokens -/

/-- Typst keywords: the ones with a Typst spelling, except `times` (the printer
never writes it; it would run into the `times 10^…` of a scientific number). -/
def kwOK : Kw → Bool
  | .times | .rpg | .lb | .rb | .nl | .thin | .frac | .labs | .rabs | .lfloor | .rfloor
  | .lceil | .rceil | .dotacc | .bcases | .ecases => false
  | _ => true

/-- The Typst tokens: what the Typst printer writes. -/
def tokOK : Tok → Prop
  | .num n => n.WF
  | .letter c => isLetter c = true
  | .greek g => isGreek g.toList = true
  | .it _ | .opn _ => True
  | .ups ps => ps ≠ [] ∧ ∀ p ∈ ps, p.2 = "" ∨ (p.2.toList ≠ [] ∧ p.2.toList.all isDig = true)
  | .txt s => s ≠ "."
  | .code j => j.WF
  | .units l => l ≠ [] ∧ ∀ f ∈ l, Esm.Units.symOK f.1 = true ∧ f.2 ≠ 0
  | .kw k => kwOK k = true
  | .word _ | .rm _ | .jstr _ | .esc _ => False

/-- What may follow the spelling of `t`: nothing that extends it. -/
def Sep (t : Tok) (X : List Char) : Prop :=
  (∀ c ∈ X.head?, merges t c = false) ∧ ((t matches .num _) → dropP timesTen X = none) ∧
    ((t matches .units _) → Esm.Units.dropPfx Esm.Units.thinSep X = none) ∧ (∀ c ∈ X.head?, c ≠ '.')

/-! ## Characters -/

theorem isIdC_letter {c : Char} (h : isLetter c = true) : isIdC c = true := by simp [isIdC, h]
theorem isIdC_dig {c : Char} (h : isDig c = true) : isIdC c = true := by simp [isIdC, h]

theorem letter_ne {c : Char} (h : isLetter c = true) :
    c ≠ '(' ∧ c ≠ '"' ∧ c ≠ '#' ∧ c ≠ '<' ∧ c ≠ '>' ∧ c ≠ '!' ∧ c ≠ '-' ∧ c ≠ ' ' ∧ c ≠ '\n' ∧
      c ≠ '\t' ∧ c ≠ '\r' := by
  have hr := Latex.letter_range h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> refine Latex.ne_of_toNat ?_
  · have : ('(').toNat = 40 := rfl
    omega
  · have : ('"').toNat = 34 := rfl
    omega
  · have : ('#').toNat = 35 := rfl
    omega
  · have : ('<').toNat = 60 := rfl
    omega
  · have : ('>').toNat = 62 := rfl
    omega
  · have : ('!').toNat = 33 := rfl
    omega
  · have : ('-').toNat = 45 := rfl
    omega
  · have : (' ').toNat = 32 := rfl
    omega
  · have : ('\n').toNat = 10 := rfl
    omega
  · have : ('\t').toNat = 9 := rfl
    omega
  · have : ('\r').toNat = 13 := rfl
    omega

theorem dig_ne {c : Char} (h : isDig c = true) :
    c ≠ '(' ∧ c ≠ '"' ∧ c ≠ '#' ∧ c ≠ '<' ∧ c ≠ '>' ∧ c ≠ '!' ∧ c ≠ ' ' ∧ c ≠ '\n' ∧
      c ≠ '\t' ∧ c ≠ '\r' ∧ isLetter c = false := by
  have hr := Latex.dig_range h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, (Latex.dig_facts h).1⟩ <;> refine Latex.ne_of_toNat ?_
  · have : ('(').toNat = 40 := rfl
    omega
  · have : ('"').toNat = 34 := rfl
    omega
  · have : ('#').toNat = 35 := rfl
    omega
  · have : ('<').toNat = 60 := rfl
    omega
  · have : ('>').toNat = 62 := rfl
    omega
  · have : ('!').toNat = 33 := rfl
    omega
  · have : (' ').toNat = 32 := rfl
    omega
  · have : ('\n').toNat = 10 := rfl
    omega
  · have : ('\t').toNat = 9 := rfl
    omega
  · have : ('\r').toNat = 13 := rfl
    omega

theorem dropP_append (p rest : List Char) : dropP p (p ++ rest) = some rest := by
  induction p with
  | nil => rfl
  | cons c p ih => simp [dropP, ih]

theorem idRun_append (cs X : List Char) (hc : ∀ c ∈ cs, isIdC c = true)
    (hX : ∀ c ∈ X.head?, isIdC c = false) : idRun (cs ++ X) = (cs, X) := by
  induction cs with
  | nil =>
    cases X with
    | nil => rfl
    | cons c r => simp [idRun, hX c rfl]
  | cons c cs ih =>
    simp only [List.mem_cons, forall_eq_or_imp] at hc
    simp [idRun, hc.1, ih hc.2]

theorem digRun_append (cs X : List Char) (hc : ∀ c ∈ cs, isDig c = true)
    (hX : ∀ c ∈ X.head?, isDig c = false) : digRun (cs ++ X) = (cs, X) := by
  induction cs with
  | nil =>
    cases X with
    | nil => rfl
    | cons c r => simp [digRun, hX c rfl]
  | cons c cs ih =>
    simp only [List.mem_cons, forall_eq_or_imp] at hc
    simp [digRun, hc.1, ih hc.2]

/-! ## Dispatch -/

theorem lexOne_letter (prev : Option Char) (c : Char) (r : List Char) (hc : isLetter c = true) :
    lexOne prev (c :: r) = lexIdent (c :: r) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, -⟩ := letter_ne hc
  rw [lexOne.eq_8 _ _ _ h1 h2 h3 (fun _ e _ => h4 e) (fun _ e _ => h5 e) (fun _ e _ => h6 e)]
  have hd := (Latex.letter_facts hc).1
  simp [hd, h7, hc]

theorem lexOne_numStart (prev : Option Char) (c : Char) (r : List Char)
    (hc : isDig c = true ∨ (c = '-' ∧ ∃ d r', r = d :: r' ∧ isDig d = true)) :
    lexOne prev (c :: r) = lexNum (c :: r) := by
  have hn : c ≠ '(' ∧ c ≠ '"' ∧ c ≠ '#' ∧ c ≠ '<' ∧ c ≠ '>' ∧ c ≠ '!' := by
    rcases hc with h | ⟨rfl, -⟩
    · obtain ⟨h1, h2, h3, h4, h5, h6, -⟩ := dig_ne h; exact ⟨h1, h2, h3, h4, h5, h6⟩
    · decide
  obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hn
  rw [lexOne.eq_8 _ _ _ h1 h2 h3 (fun _ e _ => h4 e) (fun _ e _ => h5 e) (fun _ e _ => h6 e)]
  have : (isDig c || c == '-' && (r.head?.map isDig).getD false) = true := by
    rcases hc with h | ⟨rfl, d, r', rfl, hd⟩
    · simp [h]
    · simp [hd]
  simp only [this, ↓reduceIte]

theorem lexOne_punct (prev : Option Char) (c : Char) (k : Kw) (X : List Char) (hp : punct c = some k)
    (h1 : c ≠ '(') (h2 : c ≠ '"') (h3 : c ≠ '#') (h4 : c = '<' → ∀ d ∈ X.head?, d ≠ '=')
    (h5 : c = '>' → ∀ d ∈ X.head?, d ≠ '=') (h6 : c ≠ '!') (h7 : isDig c = false)
    (h8 : isLetter c = false) (hm : c = '-' → ∀ d ∈ X.head?, isDig d = false) :
    lexOne prev (c :: X) = some (.kw k, X) := by
  rw [lexOne.eq_8 _ _ _ h1 h2 h3 (fun r e e' => h4 e '=' (by rw [e']; rfl) rfl)
    (fun r e e' => h5 e '=' (by rw [e']; rfl) rfl) (fun _ e _ => h6 e)]
  have hc : (isDig c || c == '-' && (X.head?.map isDig).getD false) = false := by
    rw [h7, Bool.false_or]
    by_cases hm' : c = '-'
    · cases X with
      | nil => simp
      | cons d r => have := hm hm' d rfl; simp [hm', this]
    · simp [hm']
  simp only [hc, h8, Bool.false_eq_true, ↓reduceIte, hp, Option.map_some]

theorem lexOne_kw (prev : Option Char) (k : Kw) (hk : kwOK k = true) (hlp : k ≠ .lp) (hlpg : k ≠ .lpg)
    (X : List Char) (hX : ∀ c ∈ X.head?, merges (.kw k) c = false) :
    lexOne prev (kwChars k ++ X) = some (.kw k, X) := by
  cases k
  case plus =>
    exact lexOne_punct prev '+' .plus X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case minus =>
    exact lexOne_punct prev '-' .minus X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (fun _ d hd => by have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this.2)
  case eq =>
    exact lexOne_punct prev '=' .eq X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case ne => rfl
  case lt =>
    exact lexOne_punct prev '<' .lt X rfl (by decide) (by decide) (by decide)
      (fun _ d hd e => by have := hX d hd; subst e; simp [merges, tokChars, kwChars] at this) (fun _ d hd e => by have := hX d hd; subst e; simp [merges, tokChars, kwChars] at this)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case gt =>
    exact lexOne_punct prev '>' .gt X rfl (by decide) (by decide) (by decide)
      (fun _ d hd e => by have := hX d hd; subst e; simp [merges, tokChars, kwChars] at this) (fun _ d hd e => by have := hX d hd; subst e; simp [merges, tokChars, kwChars] at this)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case le => rfl
  case ge => rfl
  case land =>
    have hc : kwChars .land = "and".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "and".toList ++ X = 'a' :: ("nd".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "and".toList ++ X = 'a' :: ("nd".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case lor =>
    have hc : kwChars .lor = "or".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "or".toList ++ X = 'o' :: ("r".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "or".toList ++ X = 'o' :: ("r".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case lnot =>
    have hc : kwChars .lnot = "not".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "not".toList ++ X = 'n' :: ("ot".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "not".toList ++ X = 'n' :: ("ot".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case cdot =>
    have hc : kwChars .cdot = "dot".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "dot".toList ++ X = 'd' :: ("ot".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "dot".toList ++ X = 'd' :: ("ot".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case times => exact absurd hk (by decide)
  case slash =>
    exact lexOne_punct prev '/' .slash X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case caret =>
    exact lexOne_punct prev '^' .caret X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case us =>
    exact lexOne_punct prev '_' .us X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case lp => exact absurd rfl hlp
  case rp =>
    exact lexOne_punct prev ')' .rp X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case lpg => exact absurd rfl hlpg
  case rpg => exact absurd hk (by decide)
  case lb => exact absurd hk (by decide)
  case rb => exact absurd hk (by decide)
  case lbk =>
    exact lexOne_punct prev '[' .lbk X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case rbk =>
    exact lexOne_punct prev ']' .rbk X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case comma =>
    exact lexOne_punct prev ',' .comma X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case semi =>
    exact lexOne_punct prev ';' .semi X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case colon =>
    exact lexOne_punct prev ':' .colon X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case amp =>
    exact lexOne_punct prev '&' .amp X rfl (by decide) (by decide) (by decide) (by intro h; cases h) (by intro h; cases h)
      (by decide) (by decide) (by decide) (by intro h; cases h)
  case nl => exact absurd hk (by decide)
  case sdot =>
    simp only [kwChars, List.cons_append, List.nil_append]
    rw [lexOne.eq_3]
    have h : Strings.parseQuoted true ('"' :: '.' :: '"' :: X) = some (".", X) := by
      simp [Strings.parseQuoted, Strings.unquoteBody]
    rw [h]; rfl
  case thin => exact absurd hk (by decide)
  case frac => exact absurd hk (by decide)
  case sqrt =>
    have hc : kwChars .sqrt = "sqrt".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "sqrt".toList ++ X = 's' :: ("qrt".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "sqrt".toList ++ X = 's' :: ("qrt".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case exp =>
    have hc : kwChars .exp = "exp".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "exp".toList ++ X = 'e' :: ("xp".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "exp".toList ++ X = 'e' :: ("xp".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case ln =>
    have hc : kwChars .ln = "ln".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "ln".toList ++ X = 'l' :: ("n".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "ln".toList ++ X = 'l' :: ("n".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case log =>
    have hc : kwChars .log = "log".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "log".toList ++ X = 'l' :: ("og".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "log".toList ++ X = 'l' :: ("og".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case sin =>
    have hc : kwChars .sin = "sin".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "sin".toList ++ X = 's' :: ("in".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "sin".toList ++ X = 's' :: ("in".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case cos =>
    have hc : kwChars .cos = "cos".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "cos".toList ++ X = 'c' :: ("os".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "cos".toList ++ X = 'c' :: ("os".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case tan =>
    have hc : kwChars .tan = "tan".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "tan".toList ++ X = 't' :: ("an".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "tan".toList ++ X = 't' :: ("an".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case asin =>
    have hc : kwChars .asin = "arcsin".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "arcsin".toList ++ X = 'a' :: ("rcsin".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "arcsin".toList ++ X = 'a' :: ("rcsin".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case acos =>
    have hc : kwChars .acos = "arccos".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "arccos".toList ++ X = 'a' :: ("rccos".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "arccos".toList ++ X = 'a' :: ("rccos".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case atan =>
    have hc : kwChars .atan = "arctan".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "arctan".toList ++ X = 'a' :: ("rctan".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "arctan".toList ++ X = 'a' :: ("rctan".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case sinh =>
    have hc : kwChars .sinh = "sinh".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "sinh".toList ++ X = 's' :: ("inh".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "sinh".toList ++ X = 's' :: ("inh".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case cosh =>
    have hc : kwChars .cosh = "cosh".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "cosh".toList ++ X = 'c' :: ("osh".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "cosh".toList ++ X = 'c' :: ("osh".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case tanh =>
    have hc : kwChars .tanh = "tanh".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "tanh".toList ++ X = 't' :: ("anh".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "tanh".toList ++ X = 't' :: ("anh".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case min =>
    have hc : kwChars .min = "min".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "min".toList ++ X = 'm' :: ("in".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "min".toList ++ X = 'm' :: ("in".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case max =>
    have hc : kwChars .max = "max".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "max".toList ++ X = 'm' :: ("ax".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "max".toList ++ X = 'm' :: ("ax".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case labs => exact absurd hk (by decide)
  case rabs => exact absurd hk (by decide)
  case lfloor => exact absurd hk (by decide)
  case rfloor => exact absurd hk (by decide)
  case lceil => exact absurd hk (by decide)
  case rceil => exact absurd hk (by decide)
  case abs =>
    have hc : kwChars .abs = "abs".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "abs".toList ++ X = 'a' :: ("bs".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "abs".toList ++ X = 'a' :: ("bs".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case floor =>
    have hc : kwChars .floor = "floor".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "floor".toList ++ X = 'f' :: ("loor".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "floor".toList ++ X = 'f' :: ("loor".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case ceil =>
    have hc : kwChars .ceil = "ceil".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "ceil".toList ++ X = 'c' :: ("eil".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "ceil".toList ++ X = 'c' :: ("eil".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case pdiff =>
    have hc : kwChars .pdiff = "partial".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "partial".toList ++ X = 'p' :: ("artial".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "partial".toList ++ X = 'p' :: ("artial".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case dif =>
    have hc : kwChars .dif = "dif".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "dif".toList ++ X = 'd' :: ("if".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "dif".toList ++ X = 'd' :: ("if".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case dotacc => exact absurd hk (by decide)
  case bcases => exact absurd hk (by decide)
  case ecases => exact absurd hk (by decide)
  case cases =>
    have hc : kwChars .cases = "cases".toList := by decide
    have hX' : ∀ c ∈ X.head?, isIdC c = false := by
      intro d hd; have := hX d hd; simp [merges, tokChars, kwChars] at this; exact this (by decide)
    rw [hc, show "cases".toList ++ X = 'c' :: ("ases".toList ++ X) by simp,
      lexOne_letter _ _ _ (by decide), ← show "cases".toList ++ X = 'c' :: ("ases".toList ++ X) by simp]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) hX']
    rfl
  case esmnode =>
    have hc : kwChars .esmnode = "esm".toList ++ ".node".toList := by decide
    rw [hc, List.append_assoc, show "esm".toList ++ (".node".toList ++ X) = 'e' :: ("sm".toList ++ (".node".toList ++ X)) by simp,
      lexOne_letter _ _ _ (by decide)]
    unfold lexIdent
    rw [show 'e' :: ("sm".toList ++ (".node".toList ++ X)) = "esm".toList ++ (".node".toList ++ X) by simp,
      idRun_append _ _ (by decide) (by simp; decide)]
    simp; rfl

/-! ## Numbers -/

def NumSep (X : List Char) : Prop := Number.NumStop X ∧ dropP timesTen X = none

theorem lexNum_num (n : JNum) (hn : n.WF) (X : List Char) (hX : NumSep X) :
    lexNum (numChars n ++ X) = some (.num n, X) := by
  unfold numChars
  split
  · rename_i m e hs
    unfold sciSplit at hs
    split at hs
    · rename_i neg d fp e10
      split at hs
      · rename_i hout
        simp only [Option.some.injEq, Prod.mk.injEq] at hs
        obtain ⟨rfl, rfl⟩ := hs
        have hn' := hn
        obtain ⟨-, hlt, -⟩ := hn'
        have hd : d < 10 := hlt d (by simp)
        have hfp : ∀ x ∈ Number.fracDigits fp, x < 10 :=
          Number.fracDigits_lt fp (fun x hx => hlt x (by simp [hx]))
        let Ez : List Char := if e10 < 0 then '(' :: Number.printInt e10 ++ [')'] else Number.printInt e10
        have hsp : ∀ (Z : List Char), ∀ c ∈ (timesTen ++ Z).head?, c = ' ' := by
          intro Z c hc; simp [timesTen] at hc; exact hc.symm
        have hp := Number.parse_shape neg [d] (Number.fracDigits fp) (timesTen ++ (Ez ++ X)) (by simp)
          (Number.fracDigits_ne fp) (by simpa using hd) hfp (fun c hc => by rw [hsp _ c hc]; decide)
        rw [Number.finishDec_noE _ _ _ _ (fun c hc => by rw [hsp _ c hc]; decide)] at hp
        have hN := Number.parse_print (.dec neg (d :: fp) e10) [] hn (fun c hc => by simp at hc)
        simp only [Number.print, Number.decBody, hout, ↓reduceIte, List.append_nil] at hN
        let M : List Char := (if neg then ['-'] else []) ++ Number.digitChar d :: '.' ::
          (Number.fracDigits fp).map Number.digitChar
        have e1 : (if neg then ['-'] else []) ++ Number.digitChar d :: '.' ::
              (Number.fracDigits fp).map Number.digitChar ++ timesTen ++ Ez ++ X =
            M ++ (timesTen ++ (Ez ++ X)) := by simp [M]
        have e1' : (if neg then ['-'] else []) ++ Number.digitChar d :: '.' ::
              (Number.fracDigits fp).map Number.digitChar ++ timesTen ++
              (if e10 < 0 then '(' :: Number.printInt e10 ++ [')'] else Number.printInt e10) ++ X =
            M ++ (timesTen ++ (Ez ++ X)) := e1
        rw [e1']
        unfold lexNum
        rw [show Number.parse (M ++ (timesTen ++ (Ez ++ X))) =
            some (Number.mkDec neg ([d] ++ Number.fracDigits fp) (↑[d].length - 1), timesTen ++ (Ez ++ X))
            by simpa [M] using hp]
        simp only
        rw [dropP_append]
        simp only
        have hfin : M ++ 'e' :: Number.printInt e10 = (if neg then ['-'] else []) ++
            (Number.digitChar d :: '.' :: (Number.fracDigits fp).map Number.digitChar ++ 'e' :: Number.printInt e10) := by
          simp [M]
        by_cases hneg : e10 < 0
        · have hE : Ez ++ X = '(' :: (Number.printInt e10 ++ ')' :: X) := by simp [Ez, hneg]
          rw [hE]
          simp only [List.head?_cons, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
          rw [Number.parseInt_print e10 _ (fun c hc => by simp at hc; subst hc; decide)]
          simp only
          rw [List.take_left' (by simp), hfin, hN]
        · obtain ⟨c, t, he, hc, -⟩ := Number.printNat_head e10.natAbs
          have hpi : Number.printInt e10 = c :: t := by simp [Number.printInt, hneg, he]
          have hE : Ez ++ X = c :: (t ++ X) := by simp [Ez, hneg, hpi]
          have hc' : c ≠ '(' := by intro h; subst h; simp at hc
          rw [hE]
          simp only [List.head?_cons, Option.some.injEq, hc', ↓reduceIte]
          rw [← List.cons_append, ← hpi, Number.parseInt_print e10 _ hX.1.noDigit]
          simp only
          rw [List.take_left' (by simp), hfin, hN]
      · cases hs
    · cases hs
  · unfold lexNum
    rw [Number.parse_print n X hn hX.1]
    simp only
    rw [hX.2]

theorem numChars_head (n : JNum) (hn : n.WF) : ∃ c r, numChars n = c :: r ∧
    (isDig c = true ∨ (c = '-' ∧ ∃ d r', r = d :: r' ∧ isDig d = true)) := by
  unfold numChars
  split
  · rename_i m e hs
    unfold sciSplit at hs
    split at hs
    · rename_i neg d fp e10
      split at hs
      · simp only [Option.some.injEq, Prod.mk.injEq] at hs
        obtain ⟨rfl, rfl⟩ := hs
        obtain ⟨-, hlt, -⟩ := hn
        have hd := (Number.digitChar_spec (hlt d (by simp))).1
        rw [← Latex.isDig_eq] at hd
        cases neg
        · exact ⟨_, _, rfl, Or.inl hd⟩
        · exact ⟨_, _, rfl, Or.inr ⟨rfl, _, _, rfl, hd⟩⟩
      · cases hs
    · cases hs
  · obtain ⟨c, t, he, hh⟩ := Number.print_head n hn
    rw [he]
    rcases hh with rfl | ⟨d, hd, rfl⟩
    · obtain ⟨d, t', hd, rfl⟩ := Number.print_neg_head n hn t he
      have := (Number.digitChar_spec hd).1
      rw [← Latex.isDig_eq] at this
      exact ⟨_, _, rfl, Or.inr ⟨rfl, _, _, rfl, this⟩⟩
    · have := (Number.digitChar_spec hd).1
      rw [← Latex.isDig_eq] at this
      exact ⟨_, _, rfl, Or.inl this⟩

/-! ## Identifier tokens -/

theorem lookup_none {β : Type} (a : String) : ∀ (l : List (String × β)), (∀ p ∈ l, a ≠ p.1) →
    l.lookup a = none
  | [], _ => rfl
  | p :: l, h => by
    have h1 := h p (by simp)
    have : (a == p.1) = false := by simpa using h1
    simp only [List.lookup, this]
    exact lookup_none a l (fun q hq => h q (by simp [hq]))

theorem ofList_single_ne (c : Char) (s : String) (hs : 2 ≤ s.toList.length) : String.ofList [c] ≠ s := by
  intro e; rw [← e, String.toList_ofList] at hs; simp at hs

theorem quotedArg_quote (s : String) (r : List Char) :
    quotedArg ('(' :: (Strings.quote true s ++ ')' :: r)) = some (s, r) := by
  unfold quotedArg
  simp only
  rw [Strings.parseQuoted_quote]
  rfl

theorem lexIdent_letter (c : Char) (hc : isLetter c = true) (X : List Char)
    (hX : ∀ d ∈ X.head?, isIdC d = false) : lexIdent (c :: X) = some (.letter c, X) := by
  unfold lexIdent
  rw [show c :: X = [c] ++ X from rfl, idRun_append [c] X (by simp [isIdC_letter hc]) hX]
  have h1 := ofList_single_ne c "upright" (by decide)
  have h2 := ofList_single_ne c "italic" (by decide)
  have h3 := ofList_single_ne c "op" (by decide)
  have h4 := ofList_single_ne c "thin" (by decide)
  have h5 := ofList_single_ne c "esm" (by decide)
  have hk : identKw.lookup (String.ofList [c]) = none :=
    lookup_none _ _ (fun p hp => ofList_single_ne c p.1 (by
      have : ∀ q ∈ identKw, 2 ≤ q.1.toList.length := by decide
      exact this p hp))
  have hg : isGreek [c] = false := by
    unfold isGreek
    rw [Bool.eq_false_iff]
    intro h
    have hm := List.contains_iff_mem.1 h
    have : ∀ g ∈ greek, 2 ≤ g.toList.length := by decide
    exact ofList_single_ne c _ (this _ hm) rfl
  simp only [h1, h2, h3, h4, h5, hk, hg, ↓reduceIte, Bool.false_eq_true]

theorem greek_lex (g : String) (hg : isGreek g.toList = true) :
    (∀ c ∈ g.toList, isLetter c = true) ∧ (∃ c0 r, g.toList = c0 :: r) ∧
      ∀ X, (∀ d ∈ X.head?, isIdC d = false) → lexIdent (g.toList ++ X) = some (.greek g, X) := by
  have hm : g ∈ greek := by
    simpa [isGreek, String.ofList_toList] using hg
  simp only [greek, List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    refine ⟨by decide, ⟨_, _, rfl⟩, fun X hX => ?_⟩ <;>
    (unfold lexIdent; rw [idRun_append _ _ (by decide) hX]; rfl)

/-! ## Upright pieces -/

theorem pieceChars_eq (p : String × String) :
    pieceChars p = "upright".toList ++ ('(' :: (Strings.quote true p.1 ++ ')' ::
      (if p.2 = "" then [] else '_' :: p.2.toList))) := by
  simp [pieceChars]

def PieceOK (p : String × String) : Prop :=
  p.2 = "" ∨ (p.2.toList ≠ [] ∧ p.2.toList.all isDig = true)

theorem pieces_read (X : List Char) (hX : ∀ c ∈ X.head?, c ≠ 'u' ∧ c ≠ '_' ∧ isDig c = false) :
    ∀ (ps : List (String × String)) (f : Nat), (∀ p ∈ ps, PieceOK p) → ps.length < f →
      pieces f (ps.flatMap pieceChars ++ X) = (ps, X)
  | [], f, _, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    rw [pieces.eq_2]
    simp only [List.flatMap_nil, List.nil_append]
    have : dropP "upright".toList X = none := by
      cases X with
      | nil => rfl
      | cons c r =>
        have := (hX c rfl).1
        simp [dropP, Ne.symm this]
    rw [this]
  | p :: ps, f, hok, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    have ih := pieces_read X hX ps g (fun q hq => hok q (by simp [hq])) (by simp at hf; omega)
    -- what follows this piece's subscript
    have hR : ∀ c ∈ (ps.flatMap pieceChars ++ X).head?, c ≠ '_' ∧ isDig c = false := by
      cases ps with
      | nil => intro c hc; simp at hc; exact ⟨(hX c hc).2.1, (hX c hc).2.2⟩
      | cons q qs =>
        intro c hc
        simp only [List.flatMap_cons, pieceChars_eq, List.append_assoc] at hc
        simp at hc; subst hc; exact ⟨by decide, by decide⟩
    rw [pieces.eq_2]
    simp only [List.flatMap_cons, List.append_assoc]
    rw [pieceChars_eq, List.append_assoc, dropP_append]
    simp only [List.cons_append, List.append_assoc]
    rw [quotedArg_quote]
    simp only
    have hp := hok p (by simp)
    rcases hp with h0 | ⟨hne, hdig⟩
    · simp only [h0, ↓reduceIte, List.nil_append]
      split
      · rename_i r2 heq
        exfalso
        have := (hR '_' (by rw [heq]; rfl)).1
        exact this rfl
      · simp only [String.ofList_nil]
        rw [ih]
        simp [← h0]
    · have h0 : p.2 ≠ "" := by
        intro e; rw [e] at hne; exact hne rfl
      simp only [h0, ↓reduceIte, List.cons_append]
      have hd : digRun (p.2.toList ++ (ps.flatMap pieceChars ++ X)) = (p.2.toList, ps.flatMap pieceChars ++ X) :=
        digRun_append _ _ (List.all_eq_true.1 hdig) (fun c hc => (hR c hc).2)
      simp only [hd, hne, ↓reduceIte]
      rw [ih]
      simp [String.ofList_toList]

/-! ## One token -/

theorem lexOne_tok (prev : Option Char) (t : Tok) (ht : tokOK t) (hl : t ≠ .kw .lp)
    (hlg : t ≠ .kw .lpg) (X : List Char) (hX : Sep t X) :
    lexOne prev (tokChars t ++ X) = some (t, X) := by
  cases t with
  | num n =>
    obtain ⟨c, r, he, hc⟩ := numChars_head n ht
    have hns : NumSep X := by
      refine ⟨fun d hd => ?_, hX.2.1 rfl⟩
      have h := hX.1 d hd
      have h1 : isDig d = false := by
        cases hd' : isDig d
        · rfl
        · simp [merges, isIdC, hd'] at h
      have h2 : d ≠ '.' := by rintro rfl; simp [merges] at h
      have h3 : d ≠ 'e' := by rintro rfl; simp (config := {decide := true}) [merges, isIdC] at h
      exact ⟨by rw [← Latex.isDig_eq]; exact h1, h2, h3⟩
    have hl := lexNum_num n ht X hns
    simp only [tokChars] at hl ⊢
    rw [he] at hl ⊢
    simp only [List.cons_append] at hl ⊢
    rw [lexOne_numStart _ _ _ (by
      rcases hc with h | ⟨rfl, d, r', rfl, hd⟩
      · exact Or.inl h
      · exact Or.inr ⟨rfl, d, r' ++ X, rfl, hd⟩)]
    exact hl
  | letter c =>
    have hc : isLetter c = true := ht
    have hX' : ∀ d ∈ X.head?, isIdC d = false := by
      intro d hd; have := hX.1 d hd; simpa [merges, tokChars, hc] using this
    simp only [tokChars, List.cons_append, List.nil_append]
    rw [lexOne_letter _ _ _ hc, lexIdent_letter c hc X hX']
  | greek g =>
    obtain ⟨hl, ⟨c0, r, he⟩, hlex⟩ := greek_lex g ht
    have hX' : ∀ d ∈ X.head?, isIdC d = false := by
      intro d hd; have := hX.1 d hd
      have hlast : ∃ e, g.toList.getLast? = some e ∧ isLetter e = true := by
        have hgl : g.toList.getLast? ≠ none := by rw [he]; simp
        obtain ⟨e, he'⟩ := Option.ne_none_iff_exists'.1 hgl
        exact ⟨e, he', hl e (List.mem_of_getLast? he')⟩
      obtain ⟨e, he1, he2⟩ := hlast
      simp only [merges, tokChars, he1, he2, Bool.true_and] at this
      simpa using this
    simp only [tokChars]
    rw [he, List.cons_append, lexOne_letter _ _ _ (hl c0 (by simp [he])), ← List.cons_append, ← he,
      hlex X hX']
  | it s =>
    simp only [tokChars]
    rw [show "italic(".toList ++ Strings.quote true s ++ [')'] ++ X =
        'i' :: ("talic".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X))) by simp,
      lexOne_letter _ _ _ (by decide)]
    unfold lexIdent
    rw [show 'i' :: ("talic".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X))) =
        "italic".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X)) by simp,
      idRun_append _ _ (by decide) (by simp; decide)]
    simp [quotedArg_quote]
  | opn s =>
    simp only [tokChars]
    rw [show "op(".toList ++ Strings.quote true s ++ [')'] ++ X =
        'o' :: ("p".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X))) by simp,
      lexOne_letter _ _ _ (by decide)]
    unfold lexIdent
    rw [show 'o' :: ("p".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X))) =
        "op".toList ++ ('(' :: (Strings.quote true s ++ ')' :: X)) by simp,
      idRun_append _ _ (by decide) (by simp; decide)]
    simp [quotedArg_quote]
  | ups ps =>
    obtain ⟨hne, hok⟩ := (show ps ≠ [] ∧ ∀ p ∈ ps, PieceOK p from ht)
    have hX' : ∀ c ∈ X.head?, c ≠ 'u' ∧ c ≠ '_' ∧ isDig c = false := by
      intro c hc; have := hX.1 c hc
      refine ⟨?_, ?_, ?_⟩
      · rintro rfl; simp [merges] at this
      · rintro rfl; simp [merges] at this
      · cases hd : isDig c
        · rfl
        · simp [merges, hd] at this
    obtain ⟨p, ps', rfl⟩ := List.exists_cons_of_ne_nil hne
    have hform : (p :: ps').flatMap pieceChars ++ X = "upright".toList ++ ('(' ::
        (Strings.quote true p.1 ++ ')' :: ((if p.2 = "" then [] else '_' :: p.2.toList) ++
          (ps'.flatMap pieceChars ++ X)))) := by
      simp [pieceChars_eq]
    have hu : ∀ W : List Char, "upright".toList ++ ('(' :: W) = 'u' :: ("pright".toList ++ ('(' :: W)) := by
      intro W; simp
    simp only [tokChars]
    rw [hform, hu, lexOne_letter _ _ _ (by decide), ← hu]
    unfold lexIdent
    rw [idRun_append _ _ (by decide) (by simp; decide)]
    simp only [String.ofList_toList, ↓reduceIte]
    rw [← hform]
    have hlen : ∀ qs : List (String × String), qs.length ≤ (qs.flatMap pieceChars).length := by
      intro qs
      induction qs with
      | nil => simp
      | cons q qs ih =>
        simp only [List.flatMap_cons, List.length_cons, List.length_append, pieceChars_eq] at ih ⊢
        omega
    have hrd := pieces_read X hX' (p :: ps') ((p :: ps').flatMap pieceChars ++ X).length hok (by
      have := hlen ps'
      simp only [List.flatMap_cons, List.length_cons, List.length_append, pieceChars_eq] at this ⊢
      omega)
    rw [hrd]
  | txt s =>
    have hs : s ≠ "." := ht
    simp only [tokChars]
    rw [show Strings.quote true s ++ X = '"' :: (Strings.escape true s.toList ++ '"' :: X) by
      simp [Strings.quote]]
    rw [lexOne.eq_3, ← show Strings.quote true s ++ X = '"' :: (Strings.escape true s.toList ++ '"' :: X) by
      simp [Strings.quote], Strings.parseQuoted_quote]
    simp [hs]
  | code j =>
    have hj : j.WF := ht
    simp only [tokChars, List.cons_append]
    rw [lexOne.eq_4]
    have hstop : Number.NumStop X := by
      intro d hd
      have h := hX.1 d hd
      refine ⟨?_, ?_, ?_⟩
      · cases hd' : d.isDigit
        · rfl
        · rw [← Latex.isDig_eq] at hd'; simp [merges, isIdC, hd'] at h
      · exact hX.2.2.2 d hd
      · rintro rfl; simp (config := {decide := true}) [merges, isIdC] at h
    have := TypstDict.pVal_enc 0 j (3 * ((TypstDict.encode j ++ X).length + 1)) X hj hstop (by
      have := TypstDict.size_le 0 j; simp [TypstDict.encode]; omega)
    simp only [TypstDict.encode] at this ⊢
    rw [this]; rfl
  | units l =>
    obtain ⟨hne, hfs⟩ := (show l ≠ [] ∧ ∀ f ∈ l, Esm.Units.symOK f.1 = true ∧ f.2 ≠ 0 from ht)
    obtain ⟨f, fs, rfl⟩ := List.exists_cons_of_ne_nil hne
    have hts : Esm.Units.TStop X := by
      refine ⟨fun r e => ?_, fun c r e => ?_⟩
      · have := hX.1 '^' (by rw [e]; rfl); simp [merges] at this
      · have := hX.1 c (by rw [e]; rfl)
        show isDig c = false
        cases hd : isDig c
        · rfl
        · simp [merges, hd] at this
    have hlen := Esm.Units.length_joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs)
      (fun g _ => by simp [Esm.Units.typstFactor, Esm.Units.uprightOpen])
    have hp := Esm.Units.pSepBy_joinWith Esm.Units.pTFactor Esm.Units.typstFactor Esm.Units.thinSep
      (fun g => Esm.Units.symOK g.1 = true ∧ g.2 ≠ 0) Esm.Units.TStop
      (fun g hg rest hr => Esm.Units.pTFactor_typstFactor g hg.1 hg.2 rest hr) Esm.Units.tStop_sep fs f X
      hfs hts (hX.2.2.1 rfl) (Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs) ++ X).length
      (by simp only [List.length_append, List.length_cons] at hlen ⊢; omega)
    simp only [tokChars, unitChars]
    rw [show "thin ".toList ++ Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs) ++ X =
        't' :: ("hin".toList ++ (' ' :: (Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs) ++ X)))
        by simp,
      lexOne_letter _ _ _ (by decide)]
    unfold lexIdent
    rw [show 't' :: ("hin".toList ++ (' ' :: (Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs) ++ X))) =
        "thin".toList ++ (' ' :: (Esm.Units.joinWith Esm.Units.typstFactor Esm.Units.thinSep (f :: fs) ++ X)) by simp,
      idRun_append _ _ (by decide) (by simp; decide)]
    simp only [String.ofList_toList]
    rw [hp]
    rfl
  | kw k => exact lexOne_kw prev k ht (fun e => hl (by rw [e])) (fun e => hlg (by rw [e])) X hX.1
  | word _ => exact absurd ht id
  | rm _ => exact absurd ht id
  | jstr _ => exact absurd ht id
  | esc _ => exact absurd ht id

end Esm.Document.Math.Typst
