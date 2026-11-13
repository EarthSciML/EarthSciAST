import Esm.Document.Math.Latex
import Esm.Document.Math.Induct

/-!
# The LaTeX lexer lemma

Every list of LaTeX tokens (`tokOK`) reads back from its rendering: `lex (render ts) =
some ts`. The proof goes token by token: each token reads back from its spelling
whatever follows it, as long as what follows does not extend it (`Sep`), and the
renderer writes a space exactly where a following token would extend the previous
one.
-/

namespace Esm.Document.Math.Latex

open Esm.Document Esm.Document.Math

/-! ## Characters -/

theorem isDig_eq (c : Char) : isDig c = c.isDigit := by
  unfold isDig Char.isDigit; rfl

theorem dropP_append (p rest : List Char) : dropP p (p ++ rest) = some rest := by
  induction p with
  | nil => rfl
  | cons c p ih => simp [dropP, ih]

theorem letRun_append (cs X : List Char) (hc : ∀ c ∈ cs, isLetter c = true)
    (hX : ∀ c ∈ X.head?, isLetter c = false) : letRun (cs ++ X) = (cs, X) := by
  induction cs with
  | nil =>
    cases X with
    | nil => rfl
    | cons c r => simp [letRun, hX c rfl]
  | cons c cs ih =>
    simp only [List.mem_cons, forall_eq_or_imp] at hc
    simp [letRun, hc.1, ih hc.2]

/-! ## Balanced raw text -/

theorem rawB_append (X : List Char) :
    ∀ d cs a r, rawB d cs = some (a, r) → rawB d (cs ++ X) = some (a, r ++ X) := by
  intro d cs
  induction d, cs using rawB.induct with
  | case1 d c r ih =>
    intro a r' h
    simp only [rawB, List.cons_append] at h ⊢
    obtain ⟨⟨p1, p2⟩, hp, he⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at he; obtain ⟨rfl, rfl⟩ := he
    rw [ih _ _ hp]; rfl
  | case2 r =>
    intro a r' h
    simp only [rawB, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h; rfl
  | case3 d r ih =>
    intro a r' h
    simp only [rawB, List.cons_append] at h ⊢
    obtain ⟨⟨p1, p2⟩, hp, he⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at he; obtain ⟨rfl, rfl⟩ := he
    rw [ih _ _ hp]; rfl
  | case4 d r ih =>
    intro a r' h
    simp only [rawB, List.cons_append] at h ⊢
    obtain ⟨⟨p1, p2⟩, hp, he⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at he; obtain ⟨rfl, rfl⟩ := he
    rw [ih _ _ hp]; rfl
  | case5 d c r h1 h2 h3 h4 ih =>
    intro a r' h
    rw [rawB.eq_5 _ _ _ h1 h4 h2 h3] at h
    obtain ⟨⟨p1, p2⟩, hp, he⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at he; obtain ⟨rfl, rfl⟩ := he
    by_cases hc : c = '\\'
    · subst hc
      cases r with
      | nil => simp [rawB] at hp
      | cons c1 r1 => exact absurd (h1 c1 r1 rfl rfl) id
    · rw [List.cons_append, rawB.eq_5 _ _ _ (fun c1 r1 e _ => hc e) h4 h2 h3, ih _ _ hp]; rfl
  | case6 x => intro a r h; simp [rawB] at h

theorem rawB_bal {raw : List Char} (h : balOK raw = true) (X : List Char) :
    rawB 0 (raw ++ '}' :: X) = some (raw, X) := by
  have h' : rawB 0 (raw ++ ['}']) = some (raw, []) := by simpa [balOK] using h
  have := rawB_append X 0 _ _ _ h'
  simpa using this

theorem rawB_escT (s X : List Char) : rawB 0 (escT s ++ '}' :: X) = some (escT s, X) := by
  induction s with
  | nil => rfl
  | cons c s ih =>
    by_cases he : escSet c = true
    · simp only [escT, he, ↓reduceIte, List.cons_append, List.nil_append]
      rw [rawB]; rw [ih]; rfl
    · have h1 : c ≠ '\\' := by rintro rfl; simp [escSet] at he
      have h2 : c ≠ '{' := by rintro rfl; simp [escSet] at he
      have h3 : c ≠ '}' := by rintro rfl; simp [escSet] at he
      simp only [escT, he, Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
      rw [rawB.eq_5 _ _ _ (fun _ _ e _ => h1 e) h2 (fun _ e => h3 e) (fun _ _ e => h3 e), ih]; rfl

/-! ## JSON strings -/

theorem unquoteBody_escCharL (c : Char) (r : List Char) :
    Strings.unquoteBody false (escCharL c ++ r) = (Strings.unquoteBody false r).map fun p => (c :: p.1, p.2) := by
  unfold escCharL
  by_cases hs : specials.contains c = true
  · simp only [hs, ↓reduceIte]
    simp only [specials, List.contains_cons, List.contains_nil, Bool.or_false, Bool.or_eq_true,
      beq_iff_eq] at hs
    rcases hs with rfl | rfl | rfl | rfl | rfl <;> rfl
  · simp only [hs, Bool.false_eq_true, ↓reduceIte]
    exact Strings.unquoteBody_escChar false c r

theorem unquoteBody_quoteL (cs X : List Char) :
    Strings.unquoteBody false (cs.flatMap escCharL ++ '"' :: X) = some (cs, X) := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.flatMap_cons, List.append_assoc]
    rw [unquoteBody_escCharL, ih]; rfl

/-! ## Numbers -/

/-- What may follow a number: nothing that extends it, and not the `\times 10^{…}` of
a scientific spelling. -/
def NumSep (X : List Char) : Prop := Number.NumStop X ∧ dropP timesTen X = none

theorem timesTen_head : ∀ c ∈ (timesTen ++ ([] : List Char)).head?, c = ' ' := by
  intro c hc; simp [timesTen] at hc; exact hc.symm

theorem lexNum_sci (M : List Char) (n0 n : JNum) (z : Int) (X : List Char)
    (hM : Number.parse (M ++ (timesTen ++ (Number.printInt z ++ '}' :: X))) =
      some (n0, timesTen ++ (Number.printInt z ++ '}' :: X)))
    (hN : Number.parse (M ++ 'e' :: Number.printInt z) = some (n, [])) :
    lexNum (M ++ (timesTen ++ (Number.printInt z ++ '}' :: X))) = some (.num n, X) := by
  unfold lexNum
  rw [hM]; simp only
  rw [dropP_append]; simp only
  rw [Number.parseInt_print z _ (fun c hc => by simp at hc; subst hc; decide)]
  simp only
  rw [List.take_left' (by simp)]
  rw [hN]

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
        have hsp : ∀ (Z : List Char), ∀ c ∈ (timesTen ++ Z).head?, c = ' ' := by
          intro Z c hc; simp [timesTen] at hc; exact hc.symm
        have hp := Number.parse_shape neg [d] (Number.fracDigits fp)
          (timesTen ++ (Number.printInt e10 ++ '}' :: X)) (by simp) (Number.fracDigits_ne fp)
          (by simpa using hd) hfp (fun c hc => by rw [hsp _ c hc]; decide)
        rw [Number.finishDec_noE _ _ _ _ (fun c hc => by rw [hsp _ c hc]; decide)] at hp
        have hN := Number.parse_print (.dec neg (d :: fp) e10) [] hn (fun c hc => by simp at hc)
        simp only [Number.print, Number.decBody, hout, ↓reduceIte, List.append_nil] at hN
        have e1 : (if neg then ['-'] else []) ++ Number.digitChar d :: '.' ::
              (Number.fracDigits fp).map Number.digitChar ++ timesTen ++ Number.printInt e10 ++ ['}'] ++ X =
            ((if neg then ['-'] else []) ++ Number.digitChar d :: '.' ::
              (Number.fracDigits fp).map Number.digitChar) ++
              (timesTen ++ (Number.printInt e10 ++ '}' :: X)) := by simp
        rw [e1]
        refine lexNum_sci _ (Number.mkDec neg ([d] ++ Number.fracDigits fp) (↑[d].length - 1)) _ _ _ ?_ ?_
        · simpa using hp
        · simpa using hN
      · cases hs
    · cases hs
  · unfold lexNum
    rw [Number.parse_print n X hn hX.1]
    simp only
    rw [hX.2]

/-! ## Character classes -/

theorem cle (a c : Char) : a ≤ c ↔ a.toNat ≤ c.toNat := Iff.rfl

theorem letter_range {c : Char} (h : isLetter c = true) :
    (65 ≤ c.toNat ∧ c.toNat ≤ 90) ∨ (97 ≤ c.toNat ∧ c.toNat ≤ 122) := by
  simp only [isLetter, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, cle] at h
  have : ('a').toNat = 97 := rfl
  have : ('z').toNat = 122 := rfl
  have : ('A').toNat = 65 := rfl
  have : ('Z').toNat = 90 := rfl
  omega

theorem dig_range {c : Char} (h : isDig c = true) : 48 ≤ c.toNat ∧ c.toNat ≤ 57 := by
  simp only [isDig, Bool.and_eq_true, decide_eq_true_eq, cle] at h
  have : ('0').toNat = 48 := rfl
  have : ('9').toNat = 57 := rfl
  omega

theorem ne_of_toNat {c d : Char} (h : c.toNat ≠ d.toNat) : c ≠ d := fun e => h (e ▸ rfl)

/-- A letter is none of the characters the lexer dispatches on. -/
theorem letter_facts {c : Char} (h : isLetter c = true) :
    isDig c = false ∧ c ≠ '\\' ∧ c ≠ '"' ∧ c ≠ '-' ∧ c ≠ ' ' ∧ c ≠ '\n' ∧ c ≠ '\t' ∧ c ≠ '\r' ∧
      c ≠ ';' ∧ c ≠ ':' ∧ c ≠ '!' := by
  have hr := letter_range h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [Bool.eq_false_iff]; intro h2; have := dig_range h2; omega
  all_goals exact ne_of_toNat (by
    first
      | (have : ('\\').toNat = 92 := rfl); omega
      | (have : ('"').toNat = 34 := rfl); omega
      | (have : ('-').toNat = 45 := rfl); omega
      | (have : (' ').toNat = 32 := rfl); omega
      | (have : ('\n').toNat = 10 := rfl); omega
      | (have : ('\t').toNat = 9 := rfl); omega
      | (have : ('\r').toNat = 13 := rfl); omega
      | (have : (';').toNat = 59 := rfl); omega
      | (have : (':').toNat = 58 := rfl); omega
      | (have : ('!').toNat = 33 := rfl); omega)

theorem dig_facts {c : Char} (h : isDig c = true) :
    isLetter c = false ∧ c ≠ '\\' ∧ c ≠ '"' ∧ c ≠ ' ' ∧ c ≠ '\n' ∧ c ≠ '\t' ∧ c ≠ '\r' := by
  have hr := dig_range h
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [Bool.eq_false_iff]; intro h2; have := letter_range h2; omega
  all_goals exact ne_of_toNat (by
    first
      | (have : ('\\').toNat = 92 := rfl); omega
      | (have : ('"').toNat = 34 := rfl); omega
      | (have : (' ').toNat = 32 := rfl); omega
      | (have : ('\n').toNat = 10 := rfl); omega
      | (have : ('\t').toNat = 9 := rfl); omega
      | (have : ('\r').toNat = 13 := rfl); omega)

/-! ## Greek names -/

theorem greek_facts (g : String) (hg : isGreek g.toList = true) :
    (∀ c ∈ g.toList, isLetter c = true) ∧ g.toList ≠ [] ∧
      (∀ X, ctrlTok g X = some (.greek g, X)) ∧ g.toList ≠ "quad".toList ∧ g.toList ≠ "qquad".toList ∧
      (∀ Y, dropP timesTen (' ' :: ('\\' :: g.toList ++ Y)) = none) := by
  have hm : g ∈ greek := by
    simpa [isGreek, String.ofList_toList] using hg
  simp only [greek, List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    refine ⟨by decide, by decide, fun X => by simp [ctrlTok, isGreek, greek], by decide, by decide,
      fun Y => by simp [timesTen, dropP]⟩

/-! ## Tokens -/

/-- LaTeX keywords: the ones with a LaTeX spelling, except `\times`, which the printer
never writes (it would run into the `\times 10^{…}` of a scientific number). -/
def kwOK : Kw → Bool
  | .abs | .floor | .ceil | .dif | .cases | .esmnode | .times => false
  | _ => true

/-- The LaTeX tokens: what the LaTeX printer writes. -/
def tokOK : Tok → Prop
  | .num n => n.WF
  | .letter c => isLetter c = true
  | .greek g => isGreek g.toList = true
  | .word s => s.toList.all isLetter = true ∧ 2 ≤ s.toList.length
  | .it _ | .opn _ | .esc _ | .jstr _ => True
  | .rm raw => balOK raw.toList = true
  | .txt s => balOK s.toList = true
  | .kw k => kwOK k = true
  | .ups _ | .code _ | .units _ => False

/-- What may follow the spelling of `t`: nothing that extends it. -/
def Sep (t : Tok) (X : List Char) : Prop :=
  (∀ c ∈ X.head?, merges t c = false) ∧ ((t matches .num _) → dropP timesTen X = none)

theorem lexOne_punct (c : Char) (k : Kw) (X : List Char) (hp : punct c = some k) (h1 : c ≠ '\\')
    (h2 : c ≠ '"') (h3 : isDig c = false) (h4 : isLetter c = false)
    (hm : c = '-' → ∀ d ∈ X.head?, isDig d = false) : lexOne (c :: X) = some (.kw k, X) := by
  rw [lexOne.eq_3 _ _ (fun _ _ e _ => h1 e) h2]
  have hc : (isDig c || c == '-' && (X.head?.map isDig).getD false) = false := by
    rw [h3, Bool.false_or]
    by_cases hm' : c = '-'
    · cases X with
      | nil => simp
      | cons d r => have := hm hm' d rfl; simp [hm', this]
    · simp [hm']
  simp only [hc, h4, Bool.false_eq_true, ↓reduceIte, hp, Option.map_some]

theorem lexOne_ctrl (w : List Char) (hw : w ≠ []) (hl : ∀ c ∈ w, isLetter c = true) (X : List Char)
    (hX : ∀ c ∈ X.head?, isLetter c = false) :
    lexOne ('\\' :: (w ++ X)) = ctrlTok (String.ofList w) X := by
  obtain ⟨c0, wr, rfl⟩ := List.exists_cons_of_ne_nil hw
  have h0 := hl c0 (by simp)
  simp only [List.cons_append, lexOne, h0, ↓reduceIte]
  rw [← List.cons_append, letRun_append _ _ hl hX]

theorem lexOne_kw (k : Kw) (hk : kwOK k = true) (X : List Char)
    (hX : ∀ c ∈ X.head?, merges (.kw k) c = false) : lexOne (kwChars k ++ X) = some (.kw k, X) := by
  cases k
  case plus => exact lexOne_punct '+' .plus X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case minus => exact lexOne_punct '-' .minus X rfl (by decide) (by decide) (by decide) (by decide) (fun _ d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this.2)
  case eq => exact lexOne_punct '=' .eq X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case ne =>
    have hc : kwChars .ne = '\\' :: "ne".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case lt => exact lexOne_punct '<' .lt X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case gt => exact lexOne_punct '>' .gt X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case le =>
    have hc : kwChars .le = '\\' :: "le".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case ge =>
    have hc : kwChars .ge = '\\' :: "ge".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case land =>
    have hc : kwChars .land = '\\' :: "land".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case lor =>
    have hc : kwChars .lor = '\\' :: "lor".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case lnot =>
    have hc : kwChars .lnot = '\\' :: "lnot".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case cdot =>
    have hc : kwChars .cdot = '\\' :: "cdot".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case times => exact absurd hk (by decide)
  case slash => exact lexOne_punct '/' .slash X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case caret => exact lexOne_punct '^' .caret X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case us => exact lexOne_punct '_' .us X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case lp => exact lexOne_punct '(' .lp X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case rp => exact lexOne_punct ')' .rp X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case lpg =>
    have hc : kwChars .lpg = '\\' :: ("left".toList ++ ['(']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case rpg =>
    have hc : kwChars .rpg = '\\' :: ("right".toList ++ [')']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case lb => exact lexOne_punct '{' .lb X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case rb => exact lexOne_punct '}' .rb X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case lbk => exact lexOne_punct '[' .lbk X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case rbk => exact lexOne_punct ']' .rbk X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case comma => exact lexOne_punct ',' .comma X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case semi => exact lexOne_punct ';' .semi X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case colon => exact lexOne_punct ':' .colon X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case amp => exact lexOne_punct '&' .amp X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case nl => rfl
  case sdot => exact lexOne_punct '.' .sdot X rfl (by decide) (by decide) (by decide) (by decide) (by intro h; cases h)
  case thin => rfl
  case frac =>
    have hc : kwChars .frac = '\\' :: "frac".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case sqrt =>
    have hc : kwChars .sqrt = '\\' :: "sqrt".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case exp =>
    have hc : kwChars .exp = '\\' :: "exp".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case ln =>
    have hc : kwChars .ln = '\\' :: "ln".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case log =>
    have hc : kwChars .log = '\\' :: "log".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case sin =>
    have hc : kwChars .sin = '\\' :: "sin".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case cos =>
    have hc : kwChars .cos = '\\' :: "cos".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case tan =>
    have hc : kwChars .tan = '\\' :: "tan".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case asin =>
    have hc : kwChars .asin = '\\' :: "arcsin".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case acos =>
    have hc : kwChars .acos = '\\' :: "arccos".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case atan =>
    have hc : kwChars .atan = '\\' :: "arctan".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case sinh =>
    have hc : kwChars .sinh = '\\' :: "sinh".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case cosh =>
    have hc : kwChars .cosh = '\\' :: "cosh".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case tanh =>
    have hc : kwChars .tanh = '\\' :: "tanh".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case min =>
    have hc : kwChars .min = '\\' :: "min".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case max =>
    have hc : kwChars .max = '\\' :: "max".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case labs =>
    have hc : kwChars .labs = '\\' :: ("left".toList ++ ['|']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case rabs =>
    have hc : kwChars .rabs = '\\' :: ("right".toList ++ ['|']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case lfloor =>
    have hc : kwChars .lfloor = '\\' :: "lfloor".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case rfloor =>
    have hc : kwChars .rfloor = '\\' :: "rfloor".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case lceil =>
    have hc : kwChars .lceil = '\\' :: "lceil".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case rceil =>
    have hc : kwChars .rceil = '\\' :: "rceil".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case abs => exact absurd hk (by decide)
  case floor => exact absurd hk (by decide)
  case ceil => exact absurd hk (by decide)
  case pdiff =>
    have hc : kwChars .pdiff = '\\' :: "partial".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case dif => exact absurd hk (by decide)
  case dotacc =>
    have hc : kwChars .dotacc = '\\' :: "dot".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case bcases =>
    have hc : kwChars .bcases = '\\' :: ("begin".toList ++ "{cases}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]; rfl
  case ecases =>
    have hc : kwChars .ecases = '\\' :: ("end".toList ++ "{cases}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]; rfl
  case cases => exact absurd hk (by decide)
  case esmnode => exact absurd hk (by decide)

end Esm.Document.Math.Latex
