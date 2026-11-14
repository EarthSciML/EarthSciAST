import Esm.Document.Math.RoundTripLatex
import Esm.Document.Math.RoundTripTypst

/-!
# Accepted variants and refused spellings

Each accepted variant spelling is a normalization step with one lemma: the variant
reads to the same token or the same value as the canonical spelling. Removed
operators are refused by name.
-/

namespace Esm.Document.Math

open Esm.Document

/-! ## LaTeX spellings the lexer normalizes -/

theorem variant_leq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("leq".toList ++ X)) = Latex.lexOne ('\\' :: ("le".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

theorem variant_geq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("geq".toList ++ X)) = Latex.lexOne ('\\' :: ("ge".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

theorem variant_neq (X : List Char) (hX : ∀ c ∈ X.head?, isLetter c = false) :
    Latex.lexOne ('\\' :: ("neq".toList ++ X)) = Latex.lexOne ('\\' :: ("ne".toList ++ X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) X hX, Latex.lexOne_ctrl _ (by decide) (by decide) X hX]
  rfl

/-- `\bigl(` and `\Bigl(` read as the grouping `\left(`. -/
theorem variant_bigl (X : List Char) :
    Latex.lexOne ('\\' :: ("bigl".toList ++ '(' :: X)) = Latex.lexOne ('\\' :: ("left".toList ++ '(' :: X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide),
    Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
  rfl

/-- `\bigr)` reads as the grouping `\right)`. -/
theorem variant_bigr (X : List Char) :
    Latex.lexOne ('\\' :: ("bigr".toList ++ ')' :: X)) = Latex.lexOne ('\\' :: ("right".toList ++ ')' :: X)) := by
  rw [Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide),
    Latex.lexOne_ctrl _ (by decide) (by decide) _ (by simp; decide)]
  rfl

/-- The spacing command `\;` is skipped like a space. -/
theorem variant_thickspace (n : Nat) (X : List Char) :
    Latex.skipWs (n + 1) ('\\' :: ';' :: X) = Latex.skipWs n X := by
  rw [Latex.skipWs.eq_2]; simp

/-! ## Variants the parser reads -/

/-- `\times` reads as the product `\cdot`. -/
theorem variant_times (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) :
    mulLoop c (f + 1) acc (.kw .times :: r) = mulLoop c (f + 1) acc (.kw .cdot :: r) := by
  rw [mulLoop.eq_2, mulLoop.eq_3]

/-- `\dot{x}` (LaTeX) reads as the time derivative of `x`. -/
theorem variant_dot (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .dotacc :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (dNode a "t", rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_rb c.sf rest) f hf]

/-- Typst `dot(x)` reads as the time derivative of `x`. -/
theorem variant_dot_typst (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .cdot :: .kw .lp :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (dNode a "t", rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_rp c.sf rest) f hf]

/-- `[x]` reads as the grouping `(x)`. -/
theorem variant_brackets (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .lbk :: ((pr c a).at c.sf 1 ++ .kw .rbk :: rest)) = some (a, rest) := by
  rw [pPrim.eq_def]; simp only
  rw [pOr_at ha _ (fol1_kw c.sf .rbk (by simp) rest) f hf]

/-- `\log(x)` reads as `\ln(x)`. -/
theorem variant_log (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .log :: .kw .lp :: r) = pPrim c (f + 1) (.kw .ln :: .kw .lp :: r) := by
  rw [pPrim.eq_def, pPrim.eq_def]; rfl

/-- `\mathrm{e}^{x}` (LaTeX) reads as `\exp(x)`. -/
theorem variant_euler (c : Ctx) (hc : c.sf = .latex) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.rm "e" :: .kw .caret :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "exp" [a], rest) := by
  rw [pPrim.eq_def]; simp only [eulerHead]
  simp only [beq_self_eq_true, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
  rw [pEulerExp.eq_def]; simp only
  rw [pExpo.eq_def]; simp only; rw [hc]; simp only
  have hp := pOr_at ha _ (fol1_rb c.sf rest) f hf
  rw [hc] at hp
  rw [hp]

/-- The deprecated call form `\operatorname{pow}(x, y)` reads as the power `x^{y}`. -/
theorem variant_pow (c : Ctx) (x y : Json) (hx : M c x) (hy : M c y) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "pow" (.kw .lp :: (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "^" [x, y], rest) := by
  have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart])) (Or.inl rfl)
    [x, y] (by simp [hx, hy]) rest f hf
  rw [pOpn.eq_def]; simp only [isLp, ↓reduceIte]
  rw [hca]; simp [callOps, allPos]

/-- The deprecated call form `\operatorname{neg}(x)` reads as the negation `-x`. -/
theorem variant_neg (c : Ctx) (x : Json) (hx : M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "neg" (.kw .lp :: (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "-" [x], rest) := by
  have hca := pCallArgs_list c (.kw .rp) (fun r => fol_kw _ _ _ r (by simp [conts, atomStart])) (Or.inl rfl)
    [x] (by simp [hx]) rest f hf
  rw [pOpn.eq_def]; simp only [isLp, ↓reduceIte]
  rw [hca]; simp [callOps, allPos]

/-- The spacing command `\,` is skipped like a space where no unit follows it (`k\,T`);
before `\mathrm{…}` spelling a unit it is the quantity's unit separator. -/
theorem variant_thinspace (n : Nat) (X : List Char) (hX : Latex.unitTok X = none) :
    Latex.skipWs (n + 1) ('\\' :: ',' :: X) = Latex.skipWs n X := by
  rw [Latex.skipWs.eq_2]; simp [hX]

/-- A scientific literal reads the same with any spacing around `\times`, `10`, `^` and
the braces, none included: the tail after the mantissa is read past white space and the
spacing commands (`Latex.skipSp`), so `2\times10^{3}` and `2 \times  10^{3}` are the
literal `2 \times 10^{3}` is. -/
theorem variant_sci_spacing (c : Char) (r : List Char) (h : Latex.isWsL c = true) :
    Latex.sciExp (c :: r) = Latex.sciExp r := by
  unfold Latex.sciExp; rw [Latex.skipSp_ws c r h]

/-- Typst: the same for `times 10^(…)`. -/
theorem variant_sci_spacing_typst (c : Char) (r : List Char) (h : Typst.isWsT c = true) :
    Typst.sciExp (c :: r) = Typst.sciExp r := by
  unfold Typst.sciExp; rw [List.dropWhile_cons_of_pos h]

/-- A negative literal right after an operand (`k-1`, `k -1`) reads as a binary minus and
the positive number, the same as `k - 1`. -/
theorem variant_minus_literal (c : Ctx) (f : Nat) (acc : List Json) (n : JNum) (r : List Tok)
    (hn : negNum n = true) (hw : (negate n).wfb = true) :
    addLoop c (f + 1) acc (.num n :: r) = addLoop c (f + 1) acc (.kw .minus :: .num (negate n) :: r) := by
  rw [addLoop.eq_4 _ _ _ _ (by intro r' e; cases e) (by intro r' e; cases e), addLoop.eq_3]
  simp [negTail, hn, hw]

/-- A plain `(` in LaTeX groups like `\left(` (a primary's `(` reads alike on both
surfaces). -/
theorem variant_paren (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .lp :: r) = pPrim c (f + 1) (.kw .lpg :: r) := by
  rw [pPrim.eq_def, pPrim.eq_def]

/-! ## Variants the parser reads: derivatives, names, Euler's number, `/`, templates -/

/-- `\frac{dN}{dt}` with an italic `d`, written as two words, reads as the time derivative
of `N` when no variable `d` is declared and neither word is a declared name. -/
theorem variant_italic_d (c : Ctx) (hc : c.sf = .latex) (n : String) (hd : c.S.names.contains "d" = false)
    (hw : c.S.names.contains ("d" ++ n) = false) (ht : c.S.names.contains "dt" = false)
    (rest : List Tok) (f : Nat) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .word ("d" ++ n) :: .kw .rb :: .kw .lb :: .word "dt" ::
      .kw .rb :: rest) = some (dNode (.str n) "t", rest) := by
  rw [pPrim_frac, pFracL.eq_def]
  simp only
  unfold pItalicD
  simp only [hd, Bool.false_eq_true, ↓reduceIte]
  have hdn : ("d" ++ n).toList = 'd' :: n.toList := by simp [String.toList_append]
  have hdt : "dt".toList = ['d', 't'] := rfl
  have hw' : "d" ++ n ∉ c.S.names := by simpa using hw
  have ht' : "dt" ∉ c.S.names := by simpa using ht
  simp [hc, dName, hw', ht', hdn, hdt]

/-- `\frac{d N}{d t}` with an italic `d` and `N` in its printed spelling reads as the time
derivative of `N`, when no variable `d` is declared. -/
theorem variant_italic_d_sep (c : Ctx) (hc : c.sf = .latex) (n : String) (hn : nameOK n = true)
    (hd : c.S.names.contains "d" = false) (rest : List Tok) (f : Nat) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .letter 'd' :: (nameToks c n ++ .kw .rb :: .kw .lb ::
      .letter 'd' :: .letter 't' :: .kw .rb :: rest)) = some (dNode (.str n) "t", rest) := by
  rw [pPrim_frac, pFracL.eq_def]
  simp only
  unfold pItalicD
  simp only [hd, Bool.false_eq_true, ↓reduceIte, hc]
  rw [dName.eq_2, pName_nameToks c n hn _ (nameStop_kw c.sf .rb (by decide) (by decide) _)]
  simp only [↓reduceIte]
  rw [dName.eq_2, pName_t c.sf _ (nameStop_kw c.sf .rb (by decide) (by decide) _)]
  simp

/-- Typst `(d N)/(d t)` with an italic `d` reads as the time derivative of `N`, when no
variable `d` is declared. -/
theorem variant_italic_d_typst (c : Ctx) (hc : c.sf = .typst) (n : String) (hn : nameOK n = true)
    (hd : c.S.names.contains "d" = false) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (.kw .lpg :: .letter 'd' :: (nameToks c n ++ .kw .rp :: .kw .slash :: .kw .lpg ::
      .letter 'd' :: .letter 't' :: .kw .rp :: rest)) = some (dNode (.str n) "t", rest) := by
  rw [pPrim.eq_def]
  simp only [hc]
  unfold pItalicD
  simp only [hd, hc, Bool.false_eq_true, ↓reduceIte]
  rw [dName.eq_2, pName_nameToks c n hn _ (nameStop_kw c.sf .rp (by decide) (by decide) _)]
  simp only [↓reduceIte]
  rw [dName.eq_2, pName_t c.sf _ (nameStop_kw c.sf .rp (by decide) (by decide) _)]
  simp

/-- `\frac{\partial N}{\partial t}` reads as the time derivative of `N`, the same node as
the canonical `\frac{\mathrm{d} N}{\mathrm{d} t}`. -/
theorem variant_partial_t (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .kw .pdiff :: ((pr c a).at c.sf 1 ++
      .kw .rb :: .kw .lb :: .kw .pdiff :: .letter 't' :: .kw .rb :: rest)) = some (dNode a "t", rest) := by
  obtain ⟨t, tr, hA, hrb, -, -⟩ := headA ha 1
  have hp := pOr_at ha _ (fol1_rb c.sf (.kw .lb :: .kw .pdiff :: .letter 't' :: .kw .rb :: rest)) f hf
  rw [pPrim_frac, pFracL.eq_5 _ _ _ (by intro r1 e; rw [hA] at e; simp at e; exact hrb e.1), hp]
  simp only
  rw [pName_t c.sf _ (nameStop_kw c.sf .rb (by decide) (by decide) rest)]

/-- Typst `(partial N)/(partial t)` reads as the time derivative of `N`, the same node as
the canonical `(dif N)/(dif t)`. -/
theorem variant_partial_t_typst (c : Ctx) (hc : c.sf = .typst) (a : Json) (ha : M c a) (rest : List Tok)
    (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 2) (.kw .lpg :: .kw .pdiff :: ((pr c a).at c.sf 1 ++
      .kw .rp :: .kw .slash :: .kw .lpg :: .kw .pdiff :: .letter 't' :: .kw .rp :: rest)) =
      some (dNode a "t", rest) := by
  obtain ⟨t, tr, hA, -, hrp, -⟩ := headA ha 1
  have hp := pOr_at ha _ (fol1_rp c.sf (.kw .slash :: .kw .lpg :: .kw .pdiff :: .letter 't' :: .kw .rp :: rest)) f hf
  rw [pPrim_pdiff hc, pDT.eq_3 _ _ _ _ (by intro k r1 e; rw [hA] at e; simp at e; exact hrp e.1), hp]
  simp only [↓reduceIte]
  rw [pName_t c.sf _ (nameStop_kw c.sf .rp (by decide) (by decide) rest)]
  simp

/-- `\mathit{name}` / `italic("name")` reads as the name, for any name (the explicit name
shape), before anything that does not continue a name. -/
theorem variant_italic_name (c : Ctx) (s : String) (rest : List Tok) (hr : Fol c.sf 10 rest) (f : Nat) :
    pPrim c (f + 1) (.it s :: rest) = some (.str s, rest) := by
  have hp : pPrim c (f + 1) (.it s :: rest) = pNamePrim c (.it s :: rest) := by rw [pPrim.eq_def]; rfl
  have hn : pName c.sf (.it s :: rest) = some (s, rest) := by
    simp only [pName, pSeg]
    rw [pNameLoop_stop c.sf _ _ rest (fol10_name hr).1]
    simp
  rw [hp]
  unfold pNamePrim
  rw [hn]
  simp only
  rw [icTailP_none c.sf rest (fun r e => by have := hr _ _ e; simp [conts] at this)]

/-- An inline LaTeX `a / b` reads as the quotient node, the same node as the canonical
`\frac{a}{b}`. -/
theorem variant_slash (c : Ctx) (hc : c.sf = .latex) (a b : Json) (ha : M c a) (hb : M c b)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : need 6 ((pr c a).at c.sf 6).length + need 6 ((pr c b).at c.sf 6).length ≤ f) :
    pMul c (f + 2) ((pr c a).at c.sf 6 ++ .kw .slash :: ((pr c b).at c.sf 6 ++ rest)) =
      some (node "/" [a, b], rest) := by
  have hfa : Fol c.sf 6 (.kw .slash :: ((pr c b).at c.sf 6 ++ rest)) :=
    fol_kw _ _ _ _ (by simp [conts, hc])
  have h1 := PL_at ha 6 (by omega) (by omega) _ hfa (f + 1) (by unfold need at hf ⊢; omega)
  rw [pLvl6] at h1
  have hnm : ∀ r', (pr c a).at c.sf 6 ++ .kw .slash :: ((pr c b).at c.sf 6 ++ rest) ≠ .kw .minus :: r' := by
    intro r' e; rw [e, pNot_minus] at h1; cases h1
  rw [pMul.eq_3 _ _ _ hnm, h1]
  simp only
  have h2 := PL_at hb 6 (by omega) (by omega) rest (hr.mono (by omega)) f (by unfold need at hf ⊢; omega)
  rw [pLvl6] at h2
  obtain ⟨g, rfl⟩ : ∃ g, f = g + 1 := ⟨f - 1, by unfold need at hf; omega⟩
  rw [mulLoop.eq_4]
  split
  · rw [h2]
    simp only
    rw [mulLoop_stop c g _ rest hr]
    rfl
  · rename_i h; exact absurd hc h

/-- Named template arguments read as the template application even when the symbol table
knows the template's parameters (the printer then writes them positionally). -/
theorem variant_named_args (c : Ctx) (n : String) (bs : List (String × Json))
    (hn : tnameOK n = true) (hM : ∀ kv ∈ bs, M c kv.2) (hne : bs ≠ [])
    (hk : ∀ kv ∈ bs, nameOK kv.1 = true) (rest : List Tok) (f : Nat)
    (hf : need 10 (callToks c.sf [.opn n] (bs.map (itemToks c))).length ≤ f) :
    pPrim c f (callToks c.sf [.opn n] (bs.map (itemToks c)) ++ rest) = some (tNode n bs, rest) :=
  pPrim_named c n bs hn hM hne hk rest f hf

/-- An italic `e^{x}` (LaTeX) reads as `\exp(x)` when no variable `e` is declared. -/
theorem variant_euler_italic (c : Ctx) (hc : c.sf = .latex) (he : c.S.names.contains "e" = false)
    (a : Json) (ha : M c a) (rest : List Tok) (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.letter 'e' :: .kw .caret :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "exp" [a], rest) := by
  rw [pPrim.eq_def]; simp only [eulerHead, he]
  simp only [beq_self_eq_true, Bool.not_false, Bool.and_self, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
  rw [pEulerExp.eq_def]; simp only
  rw [pExpo.eq_def]; simp only; rw [hc]; simp only
  have hp := pOr_at ha _ (fol1_rb c.sf rest) f hf
  rw [hc] at hp
  rw [hp]

/-- Typst `upright(e)^x` reads as `exp(x)`, always. -/
theorem variant_euler_typst (c : Ctx) (hc : c.sf = .typst) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.ups [("e", "")] :: .kw .caret :: .kw .lpg :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (node "exp" [a], rest) := by
  rw [pPrim.eq_def]; simp only [eulerHead]
  simp only [beq_self_eq_true, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
  rw [pEulerExp.eq_def]; simp only
  rw [pExpo.eq_def]; simp only; rw [hc]; simp only
  have hp := pOr_at ha _ (fol1_rp c.sf rest) f hf
  rw [hc] at hp
  rw [hp]; simp [isRp]

/-- Typst `e^x` with an italic `e` reads as `exp(x)` when no variable `e` is declared. -/
theorem variant_euler_italic_typst (c : Ctx) (hc : c.sf = .typst) (he : c.S.names.contains "e" = false)
    (a : Json) (ha : M c a) (rest : List Tok) (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.letter 'e' :: .kw .caret :: .kw .lpg :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (node "exp" [a], rest) := by
  rw [pPrim.eq_def]; simp only [eulerHead, he]
  simp only [beq_self_eq_true, Bool.not_false, Bool.and_self, ↓reduceIte, List.drop_succ_cons, List.drop_zero]
  rw [pEulerExp.eq_def]; simp only
  rw [pExpo.eq_def]; simp only; rw [hc]; simp only
  have hp := pOr_at ha _ (fol1_rp c.sf rest) f hf
  rw [hc] at hp
  rw [hp]; simp [isRp]

/-! ## Refused spellings -/

-- The simp calls below need the facts they are given jointly, which the unused-argument
-- linter, testing one at a time, does not see.
set_option linter.unusedSimpArgs false in
/-- A removed operator is refused by name in the call form. -/
theorem refuse_removed_call (c : Ctx) (n : String) (hn : removedOps.contains n = true) :
    ∀ f ts, pOpn c f n ts = none := by
  have hco : callOps.contains n = false := by
    cases h : callOps.contains n
    · rfl
    · simp only [callOps, removedOps, List.contains_cons, List.contains_nil, Bool.or_false,
        Bool.or_eq_true, beq_iff_eq] at h hn
      rcases h with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp at hn
  have hn' : n ∈ removedOps := by simpa using hn
  have hco' : n ∉ callOps := by simpa using hco
  have hneg : n ≠ "neg" := by rintro rfl; exact absurd hn (by decide)
  have hpow : n ≠ "pow" := by rintro rfl; exact absurd hn (by decide)
  have hD : n ≠ "D" := by rintro rfl; exact absurd hn (by decide)
  intro f ts
  match f, ts with
  | 0, _ => rfl
  | f + 1, [] => rfl
  | f + 1, t0 :: r =>
    rw [pOpn.eq_def]; simp only
    split
    · split
      · simp [hco', hn', hneg, hpow]
      · simp [hn']
      · rfl
    · split
      · simp [hD]
      · rfl

/-- A removed operator is refused by name in the LaTeX escape form. -/
theorem refuse_removed_esc (c : Ctx) (o : String) (hn : removedOps.contains o = true) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.esc o :: .kw .lb :: r) = none := by
  rw [pPrim.eq_def]; simp only
  have hn' : o ∈ removedOps := by simpa using hn
  split
  · split <;> simp [hn']
  · rfl

end Esm.Document.Math
