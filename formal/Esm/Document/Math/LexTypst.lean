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
    ((t matches .units _) → Esm.Units.dropPfx Esm.Units.thinSep X = none)

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

end Esm.Document.Math.Typst
