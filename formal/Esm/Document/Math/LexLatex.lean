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

theorem rawB_escK (s X : List Char) : rawB 0 (escK s ++ '}' :: X) = some (escK s, X) := by
  induction s with
  | nil => rfl
  | cons c s ih =>
    by_cases h : keySpecial c = true
    · simp only [keySpecial, Bool.or_eq_true, decide_eq_true_eq] at h
      have d0 : Esm.digitChar 0 = '0' := rfl
      have d1 : Esm.digitChar 1 = '1' := rfl
      have d2 : Esm.digitChar 2 = '2' := rfl
      have d3 : Esm.digitChar 3 = '3' := rfl
      have d4 : Esm.digitChar 4 = '4' := rfl
      have d5 : Esm.digitChar 5 = '5' := rfl
      have d6 : Esm.digitChar 6 = '6' := rfl
      have d7 : Esm.digitChar 7 = '7' := rfl
      have d8 : Esm.digitChar 8 = '8' := rfl
      have d9 : Esm.digitChar 9 = '9' := rfl
      rcases h with ((((((rfl | rfl) | rfl) | rfl) | rfl) | rfl) | rfl) <;>
        simp [escK, keySpecial, dig3, rawB, ih, d0, d1, d2, d3, d4, d5, d6, d7, d8, d9]
    · have h1 : c ≠ '\\' := by rintro rfl; simp [keySpecial] at h
      by_cases h2 : c = '_' ∨ c = '{' ∨ c = '}'
      · simp only [escK, h, h2, Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
        rw [rawB, ih]; rfl
      · have h3 : c ≠ '{' := fun e => h2 (Or.inr (Or.inl e))
        have h4 : c ≠ '}' := fun e => h2 (Or.inr (Or.inr e))
        simp only [escK, h, h2, Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
        rw [rawB.eq_5 _ _ _ (fun _ _ e _ => h1 e) h3 (fun _ e => h4 e) (fun _ _ e => h4 e), ih]; rfl

/-! ## JSON strings -/

theorem rawB_plain (d : Nat) (Z : List Char) :
    ∀ (cs : List Char), (∀ c ∈ cs, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}') →
      rawB d (cs ++ Z) = (rawB d Z).map (fun p => (cs ++ p.1, p.2))
  | [], _ => by simp only [List.nil_append]; cases rawB d Z <;> rfl
  | c :: cs, h => by
    obtain ⟨h1, h2, h3⟩ := h c (by simp)
    rw [List.cons_append, rawB.eq_5 _ _ _ (fun _ _ e _ => h1 e) h2 (fun _ e => h3 e) (fun _ _ e => h3 e),
      rawB_plain d Z cs (fun x hx => h x (by simp [hx]))]
    cases rawB d Z <;> simp

theorem digitChar_plain : ∀ d : Fin 10, Esm.digitChar d.val ≠ '}' ∧ Esm.digitChar d.val ≠ '{' ∧
    Esm.digitChar d.val ≠ '\\' ∧ Esm.digitChar d.val ≠ '"' := by decide +kernel

theorem digitChar_plain' {d : Nat} (h : d < 10) : Esm.digitChar d ≠ '}' ∧ Esm.digitChar d ≠ '{' ∧
    Esm.digitChar d ≠ '\\' ∧ Esm.digitChar d ≠ '"' := digitChar_plain ⟨d, h⟩

theorem charDigit_digitChar {d : Nat} (h : d < 10) : Number.charDigit (Esm.digitChar d) = d :=
  (Number.digitChar_spec h).2.1

theorem unescS_plain (c : Char) (r : List Char) (h1 : c ≠ '{') (h2 : c ≠ '\\') :
    unescS (c :: r) = c :: unescS r :=
  unescS.eq_4 c r (fun _ _ _ _ e _ => h1 e) (fun _ _ _ _ _ _ _ _ e _ => h1 e) (fun _ _ e _ => h2 e)

theorem unescS_bs (c : Char) (r : List Char) : unescS ('\\' :: c :: r) = c :: unescS r :=
  unescS.eq_3 c r

theorem charL : "{\\char".toList = ['{', '\\', 'c', 'h', 'a', 'r'] := rfl

theorem unescS_three (n : Nat) (h : n < 1000) (r : List Char) :
    unescS ("{\\char".toList ++ (dig3 n ++ '}' :: r)) = Char.ofNat n :: unescS r := by
  have e1 := charDigit_digitChar (show n / 100 % 10 < 10 by omega)
  have e2 := charDigit_digitChar (show n / 10 % 10 < 10 by omega)
  have e3 := charDigit_digitChar (show n % 10 < 10 by omega)
  rw [charL]
  simp only [dig3, List.cons_append, List.nil_append]
  rw [unescS.eq_1, e1, e2, e3]
  congr 2
  omega

theorem unescS_seven (n : Nat) (h : n < 10000000) (r : List Char) :
    unescS ("{\\char".toList ++ (dig7 n ++ '}' :: r)) = Char.ofNat n :: unescS r := by
  have e1 := charDigit_digitChar (show n / 1000000 % 10 < 10 by omega)
  have e2 := charDigit_digitChar (show n / 100000 % 10 < 10 by omega)
  have e3 := charDigit_digitChar (show n / 10000 % 10 < 10 by omega)
  have e4 := charDigit_digitChar (show n / 1000 % 10 < 10 by omega)
  have e5 := charDigit_digitChar (show n / 100 % 10 < 10 by omega)
  have e6 := charDigit_digitChar (show n / 10 % 10 < 10 by omega)
  have e7 := charDigit_digitChar (show n % 10 < 10 by omega)
  have h4 := (digitChar_plain' (show n / 1000 % 10 < 10 by omega)).1
  rw [charL]
  simp only [dig7, List.cons_append, List.nil_append]
  rw [unescS.eq_2 _ _ _ _ _ _ _ _ h4, e1, e2, e3, e4, e5, e6, e7]
  congr 2
  omega

theorem char_toNat_lt (c : Char) : c.toNat < 10000000 := by
  have h := c.valid
  simp only [UInt32.isValidChar, Nat.isValidChar] at h
  show c.val.toNat < _
  omega

theorem unescS_escS : ∀ s : List Char, unescS (escS s) = s
  | [] => rfl
  | c :: cs => by
    have ih := unescS_escS cs
    by_cases hp : strPlain c = true
    · have h1 : c ≠ '{' := by rintro rfl; simp [strPlain] at hp
      have h2 : c ≠ '\\' := by rintro rfl; simp [strPlain, keySpecial] at hp
      simp only [escS, hp, ↓reduceIte, List.singleton_append]
      rw [unescS_plain c _ h1 h2, ih]
    · simp only [escS, hp, Bool.false_eq_true, ↓reduceIte]
      by_cases hu : c = '_' ∨ c = '{' ∨ c = '}'
      · simp only [hu, ↓reduceIte, List.cons_append, List.nil_append]
        rw [unescS_bs, ih]
      · simp only [hu, ↓reduceIte]
        by_cases hl : c.toNat < 1000
        · simp only [hl, ↓reduceIte, List.append_assoc, List.cons_append, List.nil_append]
          rw [unescS_three _ hl, ih, Char.ofNat_toNat]
        · simp only [hl, ↓reduceIte, List.append_assoc, List.cons_append, List.nil_append]
          rw [unescS_seven _ (char_toNat_lt c), ih, Char.ofNat_toNat]

theorem rawB_group (Z : List Char) (ds : List Char) (hd : ∀ c ∈ ds, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}') :
    rawB 0 ("{\\char".toList ++ (ds ++ '}' :: Z)) =
      (rawB 0 Z).map (fun p => ("{\\char".toList ++ (ds ++ '}' :: p.1), p.2)) := by
  have hh : ∀ c ∈ ['h', 'a', 'r'] ++ ds, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
    intro c hc
    rcases List.mem_append.1 hc with hc | hc
    · simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
      rcases hc with rfl | rfl | rfl <;> decide
    · exact hd c hc
  have e : "{\\char".toList ++ (ds ++ '}' :: Z) = '{' :: '\\' :: 'c' :: ((['h', 'a', 'r'] ++ ds) ++ '}' :: Z) := by
    simp
  rw [e, rawB, rawB, rawB_plain 1 _ _ hh, rawB]
  cases rawB 0 Z <;> simp

theorem digits_plain (ds : List Nat) (h : ∀ d ∈ ds, d < 10) :
    ∀ c ∈ ds.map Esm.digitChar, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
  intro c hc
  obtain ⟨d, hd, rfl⟩ := List.mem_map.1 hc
  have := digitChar_plain' (h d hd)
  exact ⟨this.2.2.1, this.2.1, this.1⟩

theorem dig3_plain (n : Nat) : ∀ c ∈ dig3 n, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
  have : dig3 n = [n / 100 % 10, n / 10 % 10, n % 10].map Esm.digitChar := rfl
  rw [this]; exact digits_plain _ (by simp; omega)

theorem dig7_plain (n : Nat) : ∀ c ∈ dig7 n, c ≠ '\\' ∧ c ≠ '{' ∧ c ≠ '}' := by
  have : dig7 n = [n / 1000000 % 10, n / 100000 % 10, n / 10000 % 10, n / 1000 % 10, n / 100 % 10,
    n / 10 % 10, n % 10].map Esm.digitChar := rfl
  rw [this]; exact digits_plain _ (by simp; omega)

theorem rawB_escS (Z : List Char) : ∀ s : List Char,
    rawB 0 (escS s ++ Z) = (rawB 0 Z).map (fun p => (escS s ++ p.1, p.2))
  | [] => by simp only [escS, List.nil_append]; cases rawB 0 Z <;> rfl
  | c :: cs => by
    have ih := rawB_escS Z cs
    by_cases hp : strPlain c = true
    · have h1 : c ≠ '{' := by rintro rfl; simp [strPlain] at hp
      have h2 : c ≠ '\\' := by rintro rfl; simp [strPlain, keySpecial] at hp
      have h3 : c ≠ '}' := by rintro rfl; simp [strPlain] at hp
      simp only [escS, hp, ↓reduceIte, List.cons_append]
      rw [rawB.eq_5 _ _ _ (fun _ _ e _ => h2 e) h1 (fun _ e => h3 e) (fun _ _ e => h3 e)]
      simp only [List.nil_append] at *
      rw [ih]
      cases rawB 0 Z <;> rfl
    · simp only [escS, hp, Bool.false_eq_true, ↓reduceIte]
      by_cases hu : c = '_' ∨ c = '{' ∨ c = '}'
      · simp only [hu, ↓reduceIte, List.cons_append, List.nil_append]
        rw [rawB, ih]
        cases rawB 0 Z <;> rfl
      · simp only [hu, ↓reduceIte]
        by_cases hl : c.toNat < 1000
        · simp only [hl, ↓reduceIte, List.append_assoc, List.cons_append, List.nil_append]
          rw [rawB_group _ _ (dig3_plain _), ih]
          cases rawB 0 Z <;> simp
        · simp only [hl, ↓reduceIte, List.append_assoc, List.cons_append, List.nil_append]
          rw [rawB_group _ _ (dig7_plain _), ih]
          cases rawB 0 Z <;> simp

theorem rawB_strL (s X : List Char) :
    rawB 0 ('"' :: (escS s ++ '"' :: '}' :: X)) = some ('"' :: (escS s ++ ['"']), X) := by
  rw [rawB.eq_5 _ _ _ (by intro _ _ e; cases e) (by intro e; cases e) (by intro _ e; cases e)
    (by intro _ _ e; cases e), rawB_escS, rawB.eq_5 _ _ _ (by intro _ _ e; cases e)
    (by intro e; cases e) (by intro _ e; cases e) (by intro _ _ e; cases e), rawB]
  rfl

theorem textTok_strL (s : List Char) :
    textTok ('"' :: (escS s ++ ['"'])) = .jstr (String.ofList s) := by
  simp [textTok, List.getLast?_append, unescS_escS]

theorem unquoteBody_escCharB (c : Char) (r : List Char) :
    Strings.unquoteBody false (escCharB c ++ r) = (Strings.unquoteBody false r).map fun p => (c :: p.1, p.2) := by
  unfold escCharB
  by_cases hs : specials.contains c = true
  · simp only [hs, ↓reduceIte]
    simp only [specials, List.contains_cons, List.contains_nil, Bool.or_false, Bool.or_eq_true,
      beq_iff_eq] at hs
    rcases hs with rfl | rfl | rfl | rfl | rfl <;> rfl
  · simp only [hs, Bool.false_eq_true, ↓reduceIte]
    exact Strings.unquoteBody_escChar false c r

theorem unquoteBody_quoteB (cs X : List Char) :
    Strings.unquoteBody false (cs.flatMap escCharB ++ '"' :: X) = some (cs, X) := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.flatMap_cons, List.append_assoc]
    rw [unquoteBody_escCharB, ih]; rfl

theorem hexChar_plain (d : Nat) (h : d < 16) : Strings.hexChar d ≠ '\\' ∧ Strings.hexChar d ≠ '"' ∧
    Strings.hexChar d ≠ '_' := by
  have : ∀ e : Fin 16, Strings.hexChar e.val ≠ '\\' ∧ Strings.hexChar e.val ≠ '"' ∧
      Strings.hexChar e.val ≠ '_' := by decide +kernel
  exact this ⟨d, h⟩

theorem fixUs_plain (c : Char) (r : List Char) (h1 : c ≠ '\\') (h2 : c ≠ '"') :
    fixUs (c :: r) = c :: fixUs r := by
  rw [fixUs.eq_def]; split <;> simp_all

theorem fixUs_escCharL (c : Char) (R : List Char) : fixUs (escCharL c ++ R) = escCharB c ++ fixUs R := by
  unfold escCharL
  by_cases hu : c = '_'
  · subst hu; simp only [↓reduceIte]; rfl
  simp only [hu, ↓reduceIte]
  unfold escCharB
  by_cases hs : specials.contains c = true
  · simp only [hs, ↓reduceIte]
    simp only [specials, List.contains_cons, List.contains_nil, Bool.or_false, Bool.or_eq_true,
      beq_iff_eq] at hs
    rcases hs with rfl | rfl | rfl | rfl | rfl <;> rfl
  simp only [hs, Bool.false_eq_true, ↓reduceIte]
  unfold Strings.escChar
  by_cases h1 : c = '"'
  · subst h1; rfl
  by_cases h2 : c = '\\'
  · subst h2; rfl
  by_cases h3 : c = '\n'
  · subst h3; rfl
  by_cases h4 : c = '\t'
  · subst h4; rfl
  by_cases h5 : c = '\r'
  · subst h5; rfl
  simp only [h1, h2, h3, h4, h5, ite_false]
  by_cases h6 : Strings.needsHex c = true
  · simp only [h6, ite_true, Bool.false_eq_true, Strings.hex4, List.cons_append, List.nil_append]
    have p := fun d (h : d < 16) => hexChar_plain d h
    rw [fixUs.eq_2]
    simp only [List.cons.injEq, true_and, ite_false, List.cons_append, List.nil_append]
    rw [fixUs_plain _ _ (p _ (Nat.mod_lt _ (by omega))).1 (p _ (Nat.mod_lt _ (by omega))).2.1,
      fixUs_plain _ _ (p _ (Nat.mod_lt _ (by omega))).1 (p _ (Nat.mod_lt _ (by omega))).2.1,
      fixUs_plain _ _ (p _ (Nat.mod_lt _ (by omega))).1 (p _ (Nat.mod_lt _ (by omega))).2.1,
      fixUs_plain _ _ (p _ (Nat.mod_lt _ (by omega))).1 (p _ (Nat.mod_lt _ (by omega))).2.1]
    exact fun e => absurd e (by decide)
  · simp only [h6, Bool.false_eq_true, ite_false, List.cons_append, List.nil_append]
    exact fixUs_plain _ _ h2 h1

theorem fixUs_quoteL (cs X : List Char) :
    fixUs (cs.flatMap escCharL ++ '"' :: X) = cs.flatMap escCharB ++ '"' :: X := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.flatMap_cons, List.append_assoc]
    rw [fixUs_escCharL, ih]

theorem unquoteBody_quoteL (cs X : List Char) :
    Strings.unquoteBody false (fixUs (cs.flatMap escCharL ++ '"' :: X)) = some (cs, X) := by
  rw [fixUs_quoteL, unquoteBody_quoteB]

/-! ## Numbers -/

theorem skipSp_space (Z : List Char) : skipSp (' ' :: Z) = skipSp Z := by
  conv_lhs => rw [skipSp.eq_def]
  simp [isWsL]

theorem skipSp_ws (c : Char) (r : List Char) (h : isWsL c = true) : skipSp (c :: r) = skipSp r := by
  conv_lhs => rw [skipSp.eq_def]
  simp [h]

theorem skipSp_plain (c : Char) (r : List Char) (h1 : isWsL c = false) (h2 : c ≠ '\\') :
    skipSp (c :: r) = c :: r := by
  rw [skipSp.eq_def]; simp [h1, h2]

theorem skipSp_bs (d : Char) (r : List Char) (h : ¬(d = ';' ∨ d = ':' ∨ d = '!' ∨ d = ' ' ∨ d = ',')) :
    skipSp ('\\' :: d :: r) = '\\' :: d :: r := by
  rw [skipSp.eq_def]; simp only [show isWsL '\\' = false from rfl, Bool.false_eq_true, ↓reduceIte, h]

theorem skipSp_comma (Z : List Char) : skipSp ('\\' :: ',' :: Z) = skipSp Z := by
  conv_lhs => rw [skipSp.eq_def]
  simp [isWsL]

/-- A spelling `skipSp` stops at: its first character is not white space and not `\`,
or it is `\` followed by something other than a spacing command. -/
def spOK : List Char → Bool
  | c :: d :: _ => !isWsL c && (c != '\\' || !(d == ';' || d == ':' || d == '!' || d == ' ' || d == ','))
  | [c] => !isWsL c && c != '\\'
  | [] => false

theorem skipSp_spOK (P Y : List Char) (h : spOK P = true) : skipSp (P ++ Y) = P ++ Y := by
  match P, h with
  | c :: d :: r, h =>
    simp only [spOK, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true, Bool.or_eq_true,
      bne_iff_ne, ne_eq, Bool.or_eq_false_iff, beq_eq_false_iff_ne] at h
    obtain ⟨h1, h2⟩ := h
    by_cases hc : c = '\\'
    · subst hc
      have h3 : ¬(d = ';' ∨ d = ':' ∨ d = '!' ∨ d = ' ' ∨ d = ',') := by
        rcases h2 with h2 | h2
        · exact absurd rfl h2
        · simp only [not_or]; exact ⟨h2.1.1.1.1, h2.1.1.1.2, h2.1.1.2, h2.1.2, h2.2⟩
      simp only [List.cons_append]; exact skipSp_bs d _ h3
    · simp only [List.cons_append]; exact skipSp_plain c _ h1 hc
  | [c], h =>
    simp only [spOK, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true, bne_iff_ne, ne_eq] at h
    simp only [List.cons_append, List.nil_append]; exact skipSp_plain c _ h.1 h.2

/-- Two spellings differ within the first one's length. -/
def clash : List Char → List Char → Bool
  | p :: ps, c :: cs => if p = c then clash ps cs else true
  | _, _ => false

theorem dropP_clash : ∀ (p P Y : List Char), clash p P = true → dropP p (P ++ Y) = none
  | p :: ps, c :: cs, Y, h => by
    simp only [clash] at h
    simp only [List.cons_append, dropP]
    split
    · rename_i he; simp only [he, ↓reduceIte] at h; exact dropP_clash ps cs Y h
    · rfl
  | [], _, _, h => by simp [clash] at h
  | _ :: _, [], _, h => by simp [clash] at h

/-- No scientific tail after a spelling that `skipSp` stops at and that is not `\times`. -/
theorem sciExp_pre (P Y : List Char) (h1 : spOK P = true) (h2 : clash "\\times".toList P = true) :
    sciExp (P ++ Y) = none := by
  unfold sciExp; rw [skipSp_spOK P Y h1, dropP_clash _ _ _ h2]

theorem sciExp_nil : sciExp [] = none := by decide

theorem sciExp_comma (Z : List Char) : sciExp ('\\' :: ',' :: Z) = sciExp Z := by
  unfold sciExp; rw [skipSp_comma]

/-- No scientific tail where `\times` does not come first. -/
theorem sciExp_none {Z : List Char} (h : dropP "\\times".toList (skipSp Z) = none) : sciExp Z = none := by
  unfold sciExp; rw [h]

theorem sciExp_space (Z : List Char) : sciExp (' ' :: Z) = sciExp Z := by
  unfold sciExp; rw [skipSp_space]

theorem printInt_head (z : Int) : ∃ c t, Number.printInt z = c :: t ∧ isWsL c = false ∧ c ≠ '\\' := by
  unfold Number.printInt
  split
  · exact ⟨_, _, rfl, rfl, by decide⟩
  · obtain ⟨c, t, ht, hd, -⟩ := Number.printNat_head z.natAbs
    refine ⟨c, t, ht, ?_, ?_⟩
    · cases h : isWsL c
      · rfl
      · simp only [isWsL, Bool.or_eq_true, beq_iff_eq] at h
        rcases h with ((rfl | rfl) | rfl) | rfl <;> exact absurd hd (by decide)
    · intro e; subst e; exact absurd hd (by decide)

/-- The printed scientific tail reads back as its exponent. -/
theorem sciExp_tail (e : Int) (X : List Char) :
    sciExp (timesTen ++ (Number.printInt e ++ '}' :: X)) = some (e, X) := by
  obtain ⟨c, t, ht, hc1, hc2⟩ := printInt_head e
  have hp : skipSp (Number.printInt e ++ '}' :: X) = Number.printInt e ++ '}' :: X := by
    rw [ht, List.cons_append, skipSp_plain _ _ hc1 hc2]
  have hT : timesTen ++ (Number.printInt e ++ '}' :: X) =
      ' ' :: '\\' :: 't' :: 'i' :: 'm' :: 'e' :: 's' :: ' ' :: '1' :: '0' :: '^' :: '{' ::
        (Number.printInt e ++ '}' :: X) := rfl
  rw [hT]
  unfold sciExp
  rw [skipSp_space, skipSp_bs _ _ (by decide),
    show "\\times".toList = ['\\', 't', 'i', 'm', 'e', 's'] from rfl,
    show "10".toList = ['1', '0'] from rfl]
  simp only [dropP, ↓reduceIte, List.head?_cons, Option.map_some, Option.getD_some,
    show isLetter ' ' = false from rfl, Bool.false_eq_true]
  rw [skipSp_space, skipSp_plain _ _ (by decide) (by decide)]
  simp only [dropP, ↓reduceIte]
  rw [skipSp_plain _ _ (by decide) (by decide)]
  simp only
  rw [skipSp_plain _ _ (by decide) (by decide)]
  simp only
  rw [hp, Number.parseInt_print e _ (fun c hc => by simp at hc; subst hc; decide)]
  simp only
  rw [skipSp_plain _ _ (by decide) (by decide)]
  rfl

/-- What may follow a number: nothing that extends it, and not a scientific tail. -/
def NumSep (X : List Char) : Prop := Number.NumStop X ∧ sciExp X = none

theorem lexNum_num (n : JNum) (hn : n.WF) (X : List Char) (hX : NumSep X) :
    lexNum sciExp (numChars n ++ X) = some (.num n, X) := by
  unfold numChars
  split
  · rename_i m e hs
    rw [show m ++ timesTen ++ Number.printInt e ++ ['}'] ++ X =
      m ++ (timesTen ++ (Number.printInt e ++ '}' :: X)) by simp]
    exact lexNum_sci sciExp n hn m e hs _ X (sciExp_tail e X) (by simp [timesTen])
  · exact lexNum_plain sciExp n hn X hX.1 hX.2

theorem numChars_neg (n : JNum) (hn : n.WF) (r : List Char) (h : numChars n = '-' :: r) :
    negNum n = true := by
  unfold numChars at h
  split at h
  · rename_i m e hs
    exact sciSplit_neg hn hs (T := timesTen ++ (Number.printInt e ++ ['}'])) (by rw [← h]; simp)
  · exact print_neg hn h

/-- A number token reads back with its sign: a printed `-` starts a negative number. -/
theorem lexSigned_num (n : JNum) (hn : n.WF) (X : List Char)
    (h : lexNum sciExp (numChars n ++ X) = some (.num n, X)) :
    lexSigned sciExp (numChars n ++ X) = some (.num n, X) := by
  refine lexSigned_of sciExp _ X n ?_ (numChars_neg n hn) h
  unfold numChars; split
  · simp [timesTen]
  · obtain ⟨c, t, he, -⟩ := Number.print_head n hn; rw [he]; simp

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
      (∀ Y, sciExp ('\\' :: g.toList ++ Y) = none) := by
  have hm : g ∈ greek := by
    simpa [isGreek, String.ofList_toList] using hg
  simp only [greek, List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    refine ⟨by decide, by decide, fun X => by simp [ctrlTok, isGreek, greek], by decide, by decide,
      fun Y => sciExp_pre ('\\' :: _) Y (by decide) (by decide)⟩

/-! ## Tokens -/

/-- LaTeX keywords: the ones with a LaTeX spelling, except `\times`, which the printer
never writes (it would run into the `\times 10^{…}` of a scientific number). -/
def kwOK : Kw → Bool
  | .abs | .floor | .ceil | .dif | .cases | .esmnode | .times | .vec | .mat
  | .limits | .lr => false
  | _ => true

/-- The LaTeX tokens: what the LaTeX printer writes. -/
def tokOK : Tok → Prop
  | .num n => n.WF
  | .letter c => isLetter c = true
  | .greek g => isGreek g.toList = true
  | .word s => s.toList.all isLetter = true ∧ 2 ≤ s.toList.length
  | .it _ | .opn _ | .esc _ | .jstr _ => True
  | .rm raw => balOK raw.toList = true
  | .txt s => balOK s.toList = true ∧ s.toList.head? ≠ some '"'
  | .units l => unitsOfRaw (String.ofList (Esm.Units.latexBody l)) = some l ∧
      balOK (Esm.Units.latexBody l) = true
  | .kw k => kwOK k = true
  | .ups _ | .code _ => False

/-- What may follow the spelling of `t`: nothing that extends it. -/
def Sep (t : Tok) (X : List Char) : Prop :=
  (∀ c ∈ X.head?, merges t c = false) ∧ ((t matches .num _) → sciExp X = none)

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
  case bmat =>
    have hc : kwChars .bmat = '\\' :: ("begin".toList ++ "{bmatrix}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]; rfl
  case emat =>
    have hc : kwChars .emat = '\\' :: ("end".toList ++ "{bmatrix}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]; rfl
  case vec => exact absurd hk (by decide)
  case mat => exact absurd hk (by decide)
  case sum =>
    have hc : kwChars .sum = '\\' :: "sum".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case prod =>
    have hc : kwChars .prod = '\\' :: "prod".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case inn =>
    have hc : kwChars .inn = '\\' :: "in".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case substack =>
    have hc : kwChars .substack = '\\' :: "substack".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case limitsL =>
    have hc : kwChars .limitsL = '\\' :: "limits".toList := by decide
    rw [hc, List.cons_append, lexOne_ctrl _ (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide))]
    rfl
  case lbkg =>
    have hc : kwChars .lbkg = '\\' :: ("left".toList ++ ['[']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case rbkg =>
    have hc : kwChars .rbkg = '\\' :: ("right".toList ++ [']']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append,
      lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok]
  case limits => exact absurd hk (by decide)
  case lr => exact absurd hk (by decide)


/-! ## Spaces -/

theorem skipWs_plain {c : Char} (r : List Char) (h1 : c ≠ ' ') (h2 : c ≠ '\n') (h3 : c ≠ '\t')
    (h4 : c ≠ '\r') (h5 : c ≠ '\\') (n : Nat) : skipWs n (c :: r) = c :: r := by
  cases n with
  | zero => rfl
  | succ f =>
    cases r with
    | nil => rw [skipWs.eq_3]; simp [h1, h2, h3, h4]
    | cons d r' => rw [skipWs.eq_2]; simp [h1, h2, h3, h4, h5]

theorem skipWs_bs (d : Char) (r : List Char) (h1 : d ≠ ';') (h2 : d ≠ ':') (h3 : d ≠ '!') (h4 : d ≠ ' ')
    (h5 : d ≠ ',') (hq : (letRun (d :: r)).1 ≠ "quad".toList) (hq2 : (letRun (d :: r)).1 ≠ "qquad".toList)
    (n : Nat) : skipWs n ('\\' :: d :: r) = '\\' :: d :: r := by
  cases n with
  | zero => rfl
  | succ f =>
    have hq' : (letRun (d :: r)).1 ≠ ['q', 'u', 'a', 'd'] := by simpa using hq
    have hq2' : (letRun (d :: r)).1 ≠ ['q', 'q', 'u', 'a', 'd'] := by simpa using hq2
    rw [skipWs.eq_2]; simp [h1, h2, h3, h4, h5, hq', hq2']

theorem skipWs_unit (r : List Char) (h : (unitTok r).isSome = true) (n : Nat) :
    skipWs n ('\\' :: ',' :: r) = '\\' :: ',' :: r := by
  cases n with
  | zero => rfl
  | succ f => rw [skipWs.eq_2]; simp [h]

theorem skipWs_space (R : List Char) (n : Nat) : skipWs (n + 1) (' ' :: R) = skipWs n R := by
  cases R with
  | nil => rw [skipWs.eq_3]; simp
  | cons d r => rw [skipWs.eq_2]; simp

theorem skipWs_ctrl (w : List Char) (hw : w ≠ []) (hl : ∀ c ∈ w, isLetter c = true)
    (hq : w ≠ "quad".toList) (hq2 : w ≠ "qquad".toList) (X : List Char)
    (hX : ∀ c ∈ X.head?, isLetter c = false) (n : Nat) :
    skipWs n ('\\' :: (w ++ X)) = '\\' :: (w ++ X) := by
  obtain ⟨d, w', rfl⟩ := List.exists_cons_of_ne_nil hw
  have hd := letter_facts (hl d (by simp))
  simp only [List.cons_append]
  have hcomma : d ≠ ',' := by
    intro e; subst e; exact absurd (hl ',' (by simp)) (by decide)
  refine skipWs_bs d _ hd.2.2.2.2.2.2.2.2.1 hd.2.2.2.2.2.2.2.2.2.1 hd.2.2.2.2.2.2.2.2.2.2 hd.2.2.2.2.1 hcomma ?_ ?_ n
  · rw [← List.cons_append, letRun_append _ _ hl hX]; exact hq
  · rw [← List.cons_append, letRun_append _ _ hl hX]; exact hq2

theorem skipWs_kw (k : Kw) (hk : kwOK k = true) (X : List Char)
    (hX : ∀ c ∈ X.head?, merges (.kw k) c = false) (n : Nat) :
    skipWs n (kwChars k ++ X) = kwChars k ++ X := by
  cases k
  case plus => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case minus => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case eq => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case ne =>
    have hc : kwChars .ne = '\\' :: "ne".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case lt => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case gt => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case le =>
    have hc : kwChars .le = '\\' :: "le".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case ge =>
    have hc : kwChars .ge = '\\' :: "ge".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case land =>
    have hc : kwChars .land = '\\' :: "land".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case lor =>
    have hc : kwChars .lor = '\\' :: "lor".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case lnot =>
    have hc : kwChars .lnot = '\\' :: "lnot".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case cdot =>
    have hc : kwChars .cdot = '\\' :: "cdot".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case times => exact absurd hk (by decide)
  case slash => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case caret => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case us => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case lp => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case rp => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case lpg =>
    have hc : kwChars .lpg = '\\' :: ("left".toList ++ ['(']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case rpg =>
    have hc : kwChars .rpg = '\\' :: ("right".toList ++ [')']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case lb => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case rb => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case lbk => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case rbk => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case comma => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case semi => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case colon => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case amp => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case nl =>
    exact skipWs_bs '\\' X (by decide) (by decide) (by decide) (by decide) (by decide)
      (by rw [show letRun ('\\' :: X) = ([], '\\' :: X) from rfl]; exact (by decide : ([] : List Char) ≠ "quad".toList))
      (by rw [show letRun ('\\' :: X) = ([], '\\' :: X) from rfl]; exact (by decide : ([] : List Char) ≠ "qquad".toList)) n
  case sdot => exact skipWs_plain X (by decide) (by decide) (by decide) (by decide) (by decide) n
  case frac =>
    have hc : kwChars .frac = '\\' :: "frac".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case sqrt =>
    have hc : kwChars .sqrt = '\\' :: "sqrt".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case exp =>
    have hc : kwChars .exp = '\\' :: "exp".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case ln =>
    have hc : kwChars .ln = '\\' :: "ln".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case log =>
    have hc : kwChars .log = '\\' :: "log".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case sin =>
    have hc : kwChars .sin = '\\' :: "sin".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case cos =>
    have hc : kwChars .cos = '\\' :: "cos".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case tan =>
    have hc : kwChars .tan = '\\' :: "tan".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case asin =>
    have hc : kwChars .asin = '\\' :: "arcsin".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case acos =>
    have hc : kwChars .acos = '\\' :: "arccos".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case atan =>
    have hc : kwChars .atan = '\\' :: "arctan".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case sinh =>
    have hc : kwChars .sinh = '\\' :: "sinh".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case cosh =>
    have hc : kwChars .cosh = '\\' :: "cosh".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case tanh =>
    have hc : kwChars .tanh = '\\' :: "tanh".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case min =>
    have hc : kwChars .min = '\\' :: "min".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case max =>
    have hc : kwChars .max = '\\' :: "max".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case labs =>
    have hc : kwChars .labs = '\\' :: ("left".toList ++ ['|']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case rabs =>
    have hc : kwChars .rabs = '\\' :: ("right".toList ++ ['|']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case lfloor =>
    have hc : kwChars .lfloor = '\\' :: "lfloor".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case rfloor =>
    have hc : kwChars .rfloor = '\\' :: "rfloor".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case lceil =>
    have hc : kwChars .lceil = '\\' :: "lceil".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case rceil =>
    have hc : kwChars .rceil = '\\' :: "rceil".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case abs => exact absurd hk (by decide)
  case floor => exact absurd hk (by decide)
  case ceil => exact absurd hk (by decide)
  case pdiff =>
    have hc : kwChars .pdiff = '\\' :: "partial".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case dif => exact absurd hk (by decide)
  case dotacc =>
    have hc : kwChars .dotacc = '\\' :: "dot".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case bcases =>
    have hc : kwChars .bcases = '\\' :: ("begin".toList ++ "{cases}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case ecases =>
    have hc : kwChars .ecases = '\\' :: ("end".toList ++ "{cases}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case cases => exact absurd hk (by decide)
  case esmnode => exact absurd hk (by decide)
  case bmat =>
    have hc : kwChars .bmat = '\\' :: ("begin".toList ++ "{bmatrix}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case emat =>
    have hc : kwChars .emat = '\\' :: ("end".toList ++ "{bmatrix}".toList) := by decide
    rw [hc, List.cons_append, List.append_assoc]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case vec => exact absurd hk (by decide)
  case mat => exact absurd hk (by decide)
  case sum =>
    have hc : kwChars .sum = '\\' :: "sum".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case prod =>
    have hc : kwChars .prod = '\\' :: "prod".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case inn =>
    have hc : kwChars .inn = '\\' :: "in".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case substack =>
    have hc : kwChars .substack = '\\' :: "substack".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case limitsL =>
    have hc : kwChars .limitsL = '\\' :: "limits".toList := by decide
    rw [hc, List.cons_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) X
      (fun d hd => by have := hX d hd; simp [merges, endsAlpha, kwChars] at this; exact this (by decide)) n
  case lbkg =>
    have hc : kwChars .lbkg = '\\' :: ("left".toList ++ ['[']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case rbkg =>
    have hc : kwChars .rbkg = '\\' :: ("right".toList ++ [']']) := by decide
    rw [hc, List.cons_append, List.append_assoc, List.singleton_append]
    exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  case limits => exact absurd hk (by decide)
  case lr => exact absurd hk (by decide)

theorem sciExp_kw (k : Kw) (hk : kwOK k = true) (Y : List Char) :
    sciExp (kwChars k ++ Y) = none :=
  sciExp_pre _ Y (by cases k <;> first | exact absurd hk (by decide) | decide)
    (by cases k <;> first | exact absurd hk (by decide) | decide)


/-! ## One token -/

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
        rw [← isDig_eq] at hd
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
      rw [← isDig_eq] at this
      exact ⟨_, _, rfl, Or.inr ⟨rfl, _, _, rfl, this⟩⟩
    · have := (Number.digitChar_spec hd).1
      rw [← isDig_eq] at this
      exact ⟨_, _, rfl, Or.inl this⟩

theorem lexOne_tok (t : Tok) (ht : tokOK t) (X : List Char) (hX : Sep t X) :
    lexOne (tokChars t ++ X) = some (t, X) := by
  cases t with
  | num n =>
    obtain ⟨c, r, he, hc⟩ := numChars_head n ht
    have hns : NumSep X := by
      refine ⟨fun d hd => ?_, hX.2 rfl⟩
      have h := hX.1 d hd
      have h1 : isDig d = false := by
        cases hd' : isDig d
        · rfl
        · simp [merges, hd'] at h
      have h2 : d ≠ '.' := by rintro rfl; simp [merges] at h
      have h3 : d ≠ 'e' := by rintro rfl; simp [merges] at h
      exact ⟨by rw [← isDig_eq]; exact h1, h2, h3⟩
    have hl := lexSigned_num n ht X (lexNum_num n ht X hns)
    simp only [tokChars] at hl ⊢
    rw [he] at hl ⊢
    simp only [List.cons_append] at hl ⊢
    have h1 : c ≠ '\\' := by
      rcases hc with h | ⟨rfl, -⟩
      · exact (dig_facts h).2.1
      · decide
    have h2 : c ≠ '"' := by
      rcases hc with h | ⟨rfl, -⟩
      · exact (dig_facts h).2.2.1
      · decide
    rw [lexOne.eq_3 _ _ (fun _ _ e _ => h1 e) h2]
    have hcond : (isDig c || c == '-' && ((r ++ X).head?.map isDig).getD false) = true := by
      rcases hc with h | ⟨rfl, d, r', rfl, hd⟩
      · simp [h]
      · simp [hd]
    simp only [hcond, ↓reduceIte]; exact hl
  | letter c =>
    have hc : isLetter c = true := ht
    have hf := letter_facts hc
    have hX' : ∀ d ∈ X.head?, isLetter d = false := by
      intro d hd; have := hX.1 d hd; simpa [merges, endsAlpha] using this
    simp only [tokChars, List.cons_append, List.nil_append]
    rw [lexOne.eq_3 _ _ (fun _ _ e _ => hf.2.1 e) hf.2.2.1]
    have hcond : (isDig c || c == '-' && (X.head?.map isDig).getD false) = false := by
      simp [hf.1, hf.2.2.2.1]
    simp only [hcond, hc, Bool.false_eq_true, ↓reduceIte]
    rw [show c :: X = [c] ++ X from rfl, letRun_append [c] X (by simp [hc]) hX']
  | greek g =>
    obtain ⟨hl, hne, hct, -, -, -⟩ := greek_facts g ht
    have hX' : ∀ d ∈ X.head?, isLetter d = false := by
      intro d hd; have := hX.1 d hd; simpa [merges, endsAlpha] using this
    simp only [tokChars, List.cons_append]
    rw [lexOne_ctrl _ hne hl X hX', String.ofList_toList, hct]
  | word s =>
    obtain ⟨hl, h2⟩ := (show s.toList.all isLetter = true ∧ 2 ≤ s.toList.length from ht)
    have hl' : ∀ c ∈ s.toList, isLetter c = true := List.all_eq_true.1 hl
    have hX' : ∀ d ∈ X.head?, isLetter d = false := by
      intro d hd; have := hX.1 d hd; simpa [merges, endsAlpha] using this
    obtain ⟨c0, c1, rest, hs⟩ : ∃ c0 c1 rest, s.toList = c0 :: c1 :: rest := by
      match h : s.toList, h2 with
      | c0 :: c1 :: rest, _ => exact ⟨c0, c1, rest, rfl⟩
    have hf := letter_facts (hl' c0 (by simp [hs]))
    simp only [tokChars]
    have hrun := letRun_append s.toList X hl' hX'
    rw [hs] at hrun ⊢
    simp only [List.cons_append] at hrun ⊢
    rw [lexOne.eq_3 _ _ (fun _ _ e _ => hf.2.1 e) hf.2.2.1]
    have hcond : (isDig c0 || c0 == '-' && ((c1 :: (rest ++ X)).head?.map isDig).getD false) = false := by
      simp [hf.1, hf.2.2.2.1]
    simp only [hcond, hl' c0 (by simp [hs]), Bool.false_eq_true, ↓reduceIte]
    rw [hrun]
    simp only
    rw [← hs, String.ofList_toList]
  | it s =>
    simp only [tokChars]
    have : "\\mathit{".toList ++ escT s.toList ++ ['}'] ++ X =
        '\\' :: ("mathit".toList ++ ('{' :: (escT s.toList ++ '}' :: X))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok, rawB_escT, unescT_escT]
  | rm raw =>
    simp only [tokChars]
    have : "\\mathrm{".toList ++ raw.toList ++ ['}'] ++ X =
        '\\' :: ("mathrm".toList ++ ('{' :: (raw.toList ++ '}' :: X))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok, rawB_bal (show balOK raw.toList = true from ht)]
  | opn s =>
    simp only [tokChars]
    have : "\\operatorname{".toList ++ escT s.toList ++ ['}'] ++ X =
        '\\' :: ("operatorname".toList ++ ('{' :: (escT s.toList ++ '}' :: X))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok, rawB_escT, unescT_escT]
  | txt s =>
    obtain ⟨hb, hq⟩ := (show _ ∧ _ from ht)
    simp only [tokChars]
    have : "\\text{".toList ++ s.toList ++ ['}'] ++ X =
        '\\' :: ("text".toList ++ ('{' :: (s.toList ++ '}' :: X))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    have htt : textTok s.toList = .txt s := by
      unfold textTok
      split
      · rename_i q hs; rw [hs] at hq; simp at hq
      · simp
    simp [ctrlTok, rawB_bal hb, htt]
  | esc o =>
    simp only [tokChars]
    have : "\\esm{".toList ++ escT o.toList ++ ['}'] ++ X =
        '\\' :: ("esm".toList ++ ('{' :: (escT o.toList ++ '}' :: X))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok, rawB_escT, unescT_escT]
  | jstr s =>
    simp only [tokChars, strL]
    have : "\\text{\"".toList ++ escS s.toList ++ ['"', '}'] ++ X =
        '\\' :: ("text".toList ++ ('{' :: ('"' :: (escS s.toList ++ '"' :: '}' :: X)))) := by simp
    rw [this, lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
    simp [ctrlTok, rawB_strL, textTok_strL]
  | units l =>
    obtain ⟨hu, hb⟩ := (show _ ∧ _ from ht)
    simp only [tokChars]
    rw [show "\\,\\mathrm{".toList ++ Esm.Units.latexBody l ++ ['}'] ++ X =
        '\\' :: ',' :: ("\\mathrm{".toList ++ (Esm.Units.latexBody l ++ '}' :: X)) by simp]
    simp only [lexOne, show isLetter ',' = false from rfl, Bool.false_eq_true, ↓reduceIte]
    simp [unitTok, isWsL, dropP, rawB_bal hb, hu]
  | kw k => exact lexOne_kw k ht X hX.1
  | ups _ => exact absurd ht id
  | code _ => exact absurd ht id

theorem unitTok_tok (l : List Esm.Units.Factor) (ht : tokOK (.units l)) (X : List Char) :
    (unitTok ("\\mathrm{".toList ++ (Esm.Units.latexBody l ++ '}' :: X))).isSome = true := by
  obtain ⟨hu, hb⟩ := (show _ ∧ _ from ht)
  simp [unitTok, isWsL, dropP, rawB_bal hb, hu]

theorem skipWs_tok (t : Tok) (ht : tokOK t) (X : List Char) (hX : Sep t X) (n : Nat) :
    skipWs n (tokChars t ++ X) = tokChars t ++ X := by
  cases t with
  | num m =>
    obtain ⟨c, r, he, hc⟩ := numChars_head m ht
    simp only [tokChars, he, List.cons_append]
    rcases hc with h | ⟨rfl, -⟩
    · have hf := dig_facts h
      exact skipWs_plain _ hf.2.2.2.1 hf.2.2.2.2.1 hf.2.2.2.2.2.1 hf.2.2.2.2.2.2 hf.2.1 n
    · exact skipWs_plain _ (by decide) (by decide) (by decide) (by decide) (by decide) n
  | letter c =>
    have hf := letter_facts (show isLetter c = true from ht)
    exact skipWs_plain _ hf.2.2.2.2.1 hf.2.2.2.2.2.1 hf.2.2.2.2.2.2.1 hf.2.2.2.2.2.2.2.1 hf.2.1 n
  | greek g =>
    obtain ⟨hl, hne, -, hq, hq2, -⟩ := greek_facts g ht
    have hX' : ∀ d ∈ X.head?, isLetter d = false := by
      intro d hd; have := hX.1 d hd; simpa [merges, endsAlpha] using this
    simp only [tokChars, List.cons_append]
    exact skipWs_ctrl _ hne hl hq hq2 X hX' n
  | word s =>
    obtain ⟨hl, h2⟩ := (show s.toList.all isLetter = true ∧ 2 ≤ s.toList.length from ht)
    obtain ⟨c0, rest, hs⟩ : ∃ c0 rest, s.toList = c0 :: rest := by
      match h : s.toList, h2 with
      | c0 :: rest, _ => exact ⟨c0, rest, rfl⟩
    have hf := letter_facts (List.all_eq_true.1 hl c0 (by simp [hs]))
    simp only [tokChars, hs, List.cons_append]
    exact skipWs_plain _ hf.2.2.2.2.1 hf.2.2.2.2.2.1 hf.2.2.2.2.2.2.1 hf.2.2.2.2.2.2.2.1 hf.2.1 n
  | it s =>
    simp only [tokChars]
    have : "\\mathit{".toList ++ escT s.toList ++ ['}'] ++ X =
        '\\' :: ("mathit".toList ++ ('{' :: (escT s.toList ++ '}' :: X))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | rm raw =>
    simp only [tokChars]
    have : "\\mathrm{".toList ++ raw.toList ++ ['}'] ++ X =
        '\\' :: ("mathrm".toList ++ ('{' :: (raw.toList ++ '}' :: X))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | opn s =>
    simp only [tokChars]
    have : "\\operatorname{".toList ++ escT s.toList ++ ['}'] ++ X =
        '\\' :: ("operatorname".toList ++ ('{' :: (escT s.toList ++ '}' :: X))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | txt s =>
    simp only [tokChars]
    have : "\\text{".toList ++ s.toList ++ ['}'] ++ X =
        '\\' :: ("text".toList ++ ('{' :: (s.toList ++ '}' :: X))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | esc o =>
    simp only [tokChars]
    have : "\\esm{".toList ++ escT o.toList ++ ['}'] ++ X =
        '\\' :: ("esm".toList ++ ('{' :: (escT o.toList ++ '}' :: X))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | jstr s =>
    simp only [tokChars, strL]
    have : "\\text{\"".toList ++ escS s.toList ++ ['"', '}'] ++ X =
        '\\' :: ("text".toList ++ ('{' :: ('"' :: (escS s.toList ++ '"' :: '}' :: X)))) := by simp
    rw [this]; exact skipWs_ctrl _ (by decide) (by decide) (by decide) (by decide) _ (by simp; decide) n
  | units l =>
    simp only [tokChars]
    rw [show "\\,\\mathrm{".toList ++ Esm.Units.latexBody l ++ ['}'] ++ X =
        '\\' :: ',' :: ("\\mathrm{".toList ++ (Esm.Units.latexBody l ++ '}' :: X)) by simp]
    exact skipWs_unit _ (unitTok_tok l ht X) n
  | kw k => exact skipWs_kw k ht X hX.1 n
  | ups _ => exact absurd ht id
  | code _ => exact absurd ht id

theorem sciExp_plain (c : Char) (r : List Char) (h1 : isWsL c = false) (h : c ≠ '\\') :
    sciExp (c :: r) = none := by
  apply sciExp_none
  rw [skipSp_plain _ _ h1 h]
  simp [dropP, Ne.symm h]

theorem isWsL_letter {c : Char} (h : isLetter c = true) : isWsL c = false := by
  have hf := letter_facts h
  simp [isWsL, hf.2.2.2.2.1, hf.2.2.2.2.2.1, hf.2.2.2.2.2.2.1, hf.2.2.2.2.2.2.2.1]

theorem isWsL_dig {c : Char} (h : isDig c = true) : isWsL c = false := by
  have hf := dig_facts h
  simp [isWsL, hf.2.2.2.1, hf.2.2.2.2.1, hf.2.2.2.2.2.1, hf.2.2.2.2.2.2]

theorem tok_head (t : Tok) (ht : tokOK t) : ∃ c r, tokChars t = c :: r ∧ c ≠ ' ' ∧
    ∀ Y, sciExp (tokChars t ++ Y) = none := by
  cases t with
  | num m =>
    obtain ⟨c, r, he, hc⟩ := numChars_head m ht
    have h1 : c ≠ '\\' ∧ c ≠ ' ' ∧ isWsL c = false := by
      rcases hc with h | ⟨rfl, -⟩
      · exact ⟨(dig_facts h).2.1, (dig_facts h).2.2.2.1, isWsL_dig h⟩
      · decide
    exact ⟨c, r, he, h1.2.1, fun Y => by
      simp only [tokChars, he, List.cons_append]; exact sciExp_plain _ _ h1.2.2 h1.1⟩
  | letter c =>
    have hf := letter_facts (show isLetter c = true from ht)
    exact ⟨c, [], rfl, hf.2.2.2.2.1, fun Y => sciExp_plain _ _ (isWsL_letter ht) hf.2.1⟩
  | greek g =>
    obtain ⟨-, -, -, -, -, hd⟩ := greek_facts g ht
    exact ⟨'\\', g.toList, rfl, by decide, hd⟩
  | word s =>
    obtain ⟨hl, h2⟩ := (show s.toList.all isLetter = true ∧ 2 ≤ s.toList.length from ht)
    obtain ⟨c0, rest, hs⟩ : ∃ c0 rest, s.toList = c0 :: rest := by
      match h : s.toList, h2 with
      | c0 :: rest, _ => exact ⟨c0, rest, rfl⟩
    have hf := letter_facts (List.all_eq_true.1 hl c0 (by simp [hs]))
    exact ⟨c0, rest, by simp [tokChars, hs], hf.2.2.2.2.1,
      fun Y => by
        simp only [tokChars, hs, List.cons_append]
        exact sciExp_plain _ _ (isWsL_letter (List.all_eq_true.1 hl c0 (by simp [hs]))) hf.2.1⟩
  | it s => exact ⟨'\\', "mathit{".toList ++ escT s.toList ++ ['}'], by simp [tokChars], by decide,
      fun Y => by simp only [tokChars, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | rm raw => exact ⟨'\\', "mathrm{".toList ++ raw.toList ++ ['}'], by simp [tokChars], by decide,
      fun Y => by simp only [tokChars, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | opn s => exact ⟨'\\', "operatorname{".toList ++ escT s.toList ++ ['}'], by simp [tokChars], by decide,
      fun Y => by simp only [tokChars, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | txt s => exact ⟨'\\', "text{".toList ++ s.toList ++ ['}'], by simp [tokChars], by decide,
      fun Y => by simp only [tokChars, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | esc o => exact ⟨'\\', "esm{".toList ++ escT o.toList ++ ['}'], by simp [tokChars], by decide,
      fun Y => by simp only [tokChars, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | units l => exact ⟨'\\', ",\\mathrm{".toList ++ Esm.Units.latexBody l ++ ['}'], by simp [tokChars], by decide,
      fun Y => by
        simp only [tokChars]
        rw [show "\\,\\mathrm{".toList ++ Esm.Units.latexBody l ++ ['}'] ++ Y =
          '\\' :: ',' :: ("\\mathrm{".toList ++ (Esm.Units.latexBody l ++ '}' :: Y)) by simp, sciExp_comma]
        exact sciExp_pre _ _ (by decide) (by decide)⟩
  | jstr s => exact ⟨'\\', "text{\"".toList ++ escS s.toList ++ ['"', '}'], by simp [tokChars, strL], by decide,
      fun Y => by simp only [tokChars, strL, List.append_assoc]; exact sciExp_pre _ _ (by decide) (by decide)⟩
  | kw k =>
    have hk : kwOK k = true := ht
    have hne : kwChars k ≠ [] := by cases k <;> first | exact absurd hk (by decide) | decide
    have hsp : (kwChars k).head? ≠ some ' ' := by cases k <;> first | exact absurd hk (by decide) | decide
    obtain ⟨c, r, he⟩ := List.exists_cons_of_ne_nil hne
    exact ⟨c, r, he, fun e => hsp (by rw [he, e]; rfl), sciExp_kw k ht⟩
  | ups _ => exact absurd ht id
  | code _ => exact absurd ht id

/-! ## Token lists -/

theorem merges_space (t : Tok) : merges t ' ' = false := by
  unfold merges
  simp [show isLetter ' ' = false from rfl, show isDig ' ' = false from rfl]

theorem renderAux_head (p : Option Tok) (t : Tok) (r : List Tok) :
    ∃ Y, renderAux p (t :: r) = tokChars t ++ Y := by
  cases r with
  | nil => exact ⟨[], by simp [renderAux]⟩
  | cons t2 r =>
    exact ⟨(if sp p t t2 then [' '] else []) ++ renderAux (some t) (t2 :: r),
      by simp only [renderAux, List.append_assoc]⟩

theorem lexAux_render : ∀ (ts : List Tok), (∀ t ∈ ts, tokOK t) → ∀ (p : Option Tok) (S : List Char),
    (S = [] ∨ S = [' ']) → ∀ f, ts.length < f → lexAux f (S ++ renderAux p ts) = some ts
  | [], _, p, S, hS, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    rw [lexAux.eq_2]
    rcases hS with rfl | rfl
    · cases g <;> rfl
    · cases g <;> rfl
  | [t], hok, p, S, hS, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 2 := ⟨f - 2, by simp at hf; omega⟩
    have ht := hok t (by simp)
    obtain ⟨c, r, he, -, -⟩ := tok_head t ht
    have hsk : ∀ m, skipWs (m + 1) (S ++ tokChars t) = tokChars t := by
      intro m
      have h0 := skipWs_tok t ht [] ⟨by simp, fun _ => sciExp_nil⟩
      simp only [List.append_nil] at h0
      rcases hS with rfl | rfl
      · exact h0 _
      · simp only [List.singleton_append]; rw [skipWs_space]; exact h0 _
    have hl := lexOne_tok t ht [] ⟨by simp, fun _ => sciExp_nil⟩
    simp only [List.append_nil] at hl
    simp only [renderAux]
    rw [lexAux.eq_2, hsk, he]
    simp only
    rw [← he, hl]
    simp only [Option.map_eq_some_iff]
    exact ⟨[], by rw [lexAux.eq_2]; rfl, rfl⟩
  | t1 :: t2 :: r, hok, p, S, hS, f, hf => by
    obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by simp at hf; omega⟩
    have ht1 := hok t1 (by simp)
    have ht2 := hok t2 (by simp)
    obtain ⟨c1, r1, he1, -, -⟩ := tok_head t1 ht1
    obtain ⟨c2, r2, he2, -, hd2⟩ := tok_head t2 ht2
    obtain ⟨Y, hY⟩ := renderAux_head (some t1) t2 r
    let S' : List Char := if sp p t1 t2 then [' '] else []
    have hS' : S' = [] ∨ S' = [' '] := by
      simp only [S']; split
      · exact Or.inr rfl
      · exact Or.inl rfl
    have hsep : Sep t1 (S' ++ renderAux (some t1) (t2 :: r)) := by
      rw [hY]
      simp only [S']
      split
      · exact ⟨fun c hc => by simp at hc; subst hc; exact merges_space t1,
          fun _ => by simp only [List.singleton_append]; rw [sciExp_space]; exact hd2 Y⟩
      · rename_i hsp
        have hn : needSpace t1 t2 = false := by
          simp only [sp, Bool.or_eq_true, not_or] at hsp; simpa using hsp.1
        refine ⟨fun c hc => ?_, fun _ => ?_⟩
        · simp only [List.nil_append, he2, List.cons_append, List.head?_cons, Option.mem_def,
            Option.some.injEq] at hc
          subst hc
          simpa [needSpace, he2] using hn
        · simp only [List.nil_append]; exact hd2 Y
    have hrend : renderAux p (t1 :: t2 :: r) = tokChars t1 ++ (S' ++ renderAux (some t1) (t2 :: r)) := by
      simp only [renderAux, S', List.append_assoc]
    have hsk : skipWs (g + 1) (S ++ renderAux p (t1 :: t2 :: r)) =
        tokChars t1 ++ (S' ++ renderAux (some t1) (t2 :: r)) := by
      rw [hrend]
      have h0 := skipWs_tok t1 ht1 _ hsep
      rcases hS with rfl | rfl
      · exact h0 _
      · simp only [List.singleton_append]; rw [skipWs_space]; exact h0 _
    rw [lexAux.eq_2, hsk, he1]
    simp only [List.cons_append]
    rw [← List.cons_append, ← he1, lexOne_tok t1 ht1 _ hsep]
    simp only
    have ih := lexAux_render (t2 :: r) (fun t ht => hok t (by simp [ht])) (some t1) S' hS' g
      (by simp at hf ⊢; omega)
    rw [ih]; rfl

theorem length_renderAux : ∀ (ts : List Tok), (∀ t ∈ ts, tokOK t) → ∀ p, ts.length ≤ (renderAux p ts).length
  | [], _, _ => by simp
  | [t], hok, p => by
    obtain ⟨c, r, he, -⟩ := tok_head t (hok t (by simp))
    simp [renderAux, he]
  | t1 :: t2 :: r, hok, p => by
    obtain ⟨c, r1, he, -⟩ := tok_head t1 (hok t1 (by simp))
    have := length_renderAux (t2 :: r) (fun t ht => hok t (by simp [ht])) (some t1)
    simp only [renderAux, List.length_append, he, List.length_cons] at this ⊢
    omega

/-- The LaTeX lexer lemma: a list of LaTeX tokens reads back from its rendering. -/
theorem lex_render (ts : List Tok) (h : ∀ t ∈ ts, tokOK t) : lex (render ts) = some ts := by
  unfold lex render
  have := lexAux_render ts h none [] (Or.inl rfl) ((renderAux none ts).length + 1)
    (by have := length_renderAux ts h none; omega)
  simpa using this

end Esm.Document.Math.Latex
