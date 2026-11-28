---
title: "Accepted variants and refused spellings"
type: lean
lean_module: "Esm.Document.Math.Variants"
weight: 15
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Variants</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean"><code>formal/Esm/Document/Math/Variants.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-roundtriplatex"><code>Esm.Document.Math.RoundTripLatex</code></a>, <a href="/generated/document-formats/esm-document-math-roundtriptypst"><code>Esm.Document.Math.RoundTripTypst</code></a></p>

Each accepted variant spelling is a normalization step with one lemma: the variant
reads to the same token or the same value as the canonical spelling. Removed
operators are refused by name.

## LaTeX spellings the lexer normalizes

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_bigl">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_bigl" title="Esm.Document.Math.variant_bigl"><code>variant_bigl</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L34-L38">source</a></div>

```lean
theorem variant_bigl (X : List Char) :
    Latex.lexOne ('\\' :: ("bigl".toList ++ '(' :: X)) = Latex.lexOne ('\\' :: ("left".toList ++ '(' :: X))
```

`\bigl(` and `\Bigl(` read as the grouping `\left(`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_bigr">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_bigr" title="Esm.Document.Math.variant_bigr"><code>variant_bigr</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L41-L45">source</a></div>

```lean
theorem variant_bigr (X : List Char) :
    Latex.lexOne ('\\' :: ("bigr".toList ++ ')' :: X)) = Latex.lexOne ('\\' :: ("right".toList ++ ')' :: X))
```

`\bigr)` reads as the grouping `\right)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_thickspace">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_thickspace" title="Esm.Document.Math.variant_thickspace"><code>variant_thickspace</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L48-L50">source</a></div>

```lean
theorem variant_thickspace (n : Nat) (X : List Char) :
    Latex.skipWs (n + 1) ('\\' :: ';' :: X) = Latex.skipWs n X
```

The spacing command `\;` is skipped like a space.

</div>

## Variants the parser reads

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_times">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_times" title="Esm.Document.Math.variant_times"><code>variant_times</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L55-L57">source</a></div>

```lean
theorem variant_times (c : Ctx) (f : Nat) (acc : List Json) (r : List Tok) :
    mulLoop c (f + 1) acc (.kw .times :: r) = mulLoop c (f + 1) acc (.kw .cdot :: r)
```

`\times` reads as the product `\cdot`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_dot">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_dot" title="Esm.Document.Math.variant_dot"><code>variant_dot</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L60-L65">source</a></div>

```lean
theorem variant_dot (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .dotacc :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (dNode a "t", rest)
```

`\dot{x}` (LaTeX) reads as the time derivative of `x`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_dot_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_dot_typst" title="Esm.Document.Math.variant_dot_typst"><code>variant_dot_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L68-L73">source</a></div>

```lean
theorem variant_dot_typst (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .cdot :: .kw .lp :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (dNode a "t", rest)
```

Typst `dot(x)` reads as the time derivative of `x`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_brackets">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_brackets" title="Esm.Document.Math.variant_brackets"><code>variant_brackets</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L76-L80">source</a></div>

```lean
theorem variant_brackets (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 1) (.kw .lbk :: ((pr c a).at c.sf 1 ++ .kw .rbk :: rest)) = some (a, rest)
```

`[x]` reads as the grouping `(x)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_log">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_log" title="Esm.Document.Math.variant_log"><code>variant_log</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L83-L85">source</a></div>

```lean
theorem variant_log (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .log :: .kw .lp :: r) = pPrim c (f + 1) (.kw .ln :: .kw .lp :: r)
```

`\log(x)` reads as `\ln(x)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_euler">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_euler" title="Esm.Document.Math.variant_euler"><code>variant_euler</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L88-L98">source</a></div>

```lean
theorem variant_euler (c : Ctx) (hc : c.sf = .latex) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.rm "e" :: .kw .caret :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "exp" [a], rest)
```

`\mathrm{e}^{x}` (LaTeX) reads as `\exp(x)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_pow">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_pow" title="Esm.Document.Math.variant_pow"><code>variant_pow</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L101-L108">source</a></div>

```lean
theorem variant_pow (c : Ctx) (x y : Json) (hx : M c x) (hy : M c y) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "pow" (.kw .lp :: (sepBy [.kw .comma] ([x, y].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "^" [x, y], rest)
```

The deprecated call form `\operatorname{pow}(x, y)` reads as the power `x^{y}`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_neg">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_neg" title="Esm.Document.Math.variant_neg"><code>variant_neg</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L111-L118">source</a></div>

```lean
theorem variant_neg (c : Ctx) (x : Json) (hx : M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4)).length + 3 ≤ f) :
    pOpn c (f + 1) "neg" (.kw .lp :: (sepBy [.kw .comma] ([x].map fun z => (pr c z).at c.sf 4) ++
      .kw .rp :: rest)) = some (node "-" [x], rest)
```

The deprecated call form `\operatorname{neg}(x)` reads as the negation `-x`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_thinspace">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_thinspace" title="Esm.Document.Math.variant_thinspace"><code>variant_thinspace</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L122-L124">source</a></div>

```lean
theorem variant_thinspace (n : Nat) (X : List Char) (hX : Latex.unitTok X = none) :
    Latex.skipWs (n + 1) ('\\' :: ',' :: X) = Latex.skipWs n X
```

The spacing command `\,` is skipped like a space where no unit follows it (`k\,T`);
before `\mathrm{…}` spelling a unit it is the quantity's unit separator.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_sci_spacing">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_sci_spacing" title="Esm.Document.Math.variant_sci_spacing"><code>variant_sci_spacing</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L130-L132">source</a></div>

```lean
theorem variant_sci_spacing (c : Char) (r : List Char) (h : Latex.isWsL c = true) :
    Latex.sciExp (c :: r) = Latex.sciExp r
```

A scientific literal reads the same with any spacing around `\times`, `10`, `^` and
the braces, none included: the tail after the mantissa is read past white space and the
spacing commands ([`Latex.skipSp`](/generated/document-formats/esm-document-math-latex#Esm.Document.Math.Latex.skipSp)), so `2\times10^{3}` and `2 \times  10^{3}` are the
literal `2 \times 10^{3}` is.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_sci_spacing_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_sci_spacing_typst" title="Esm.Document.Math.variant_sci_spacing_typst"><code>variant_sci_spacing_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L135-L137">source</a></div>

```lean
theorem variant_sci_spacing_typst (c : Char) (r : List Char) (h : Typst.isWsT c = true) :
    Typst.sciExp (c :: r) = Typst.sciExp r
```

Typst: the same for `times 10^(…)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_minus_literal">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_minus_literal" title="Esm.Document.Math.variant_minus_literal"><code>variant_minus_literal</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L141-L145">source</a></div>

```lean
theorem variant_minus_literal (c : Ctx) (f : Nat) (acc : List Json) (n : JNum) (r : List Tok)
    (hn : negNum n = true) (hw : (negate n).wfb = true) :
    addLoop c (f + 1) acc (.num n :: r) = addLoop c (f + 1) acc (.kw .minus :: .num (negate n) :: r)
```

A negative literal right after an operand (`k-1`, `k -1`) reads as a binary minus and
the positive number, the same as `k - 1`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_paren">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_paren" title="Esm.Document.Math.variant_paren"><code>variant_paren</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L149-L151">source</a></div>

```lean
theorem variant_paren (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.kw .lp :: r) = pPrim c (f + 1) (.kw .lpg :: r)
```

A plain `(` in LaTeX groups like `\left(` (a primary's `(` reads alike on both
surfaces).

</div>

## Variants the parser reads: derivatives, names, Euler's number, `/`, templates

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_italic_d">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_italic_d" title="Esm.Document.Math.variant_italic_d"><code>variant_italic_d</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L157-L170">source</a></div>

```lean
theorem variant_italic_d (c : Ctx) (hc : c.sf = .latex) (n : String) (hd : c.S.names.contains "d" = false)
    (hw : c.S.names.contains ("d" ++ n) = false) (ht : c.S.names.contains "dt" = false)
    (rest : List Tok) (f : Nat) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .word ("d" ++ n) :: .kw .rb :: .kw .lb :: .word "dt" ::
      .kw .rb :: rest) = some (dNode (.str n) "t", rest)
```

`\frac{dN}{dt}` with an italic `d`, written as two words, reads as the time derivative
of `N` when no variable `d` is declared and neither word is a declared name.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_italic_d_sep">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_italic_d_sep" title="Esm.Document.Math.variant_italic_d_sep"><code>variant_italic_d_sep</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L174-L185">source</a></div>

```lean
theorem variant_italic_d_sep (c : Ctx) (hc : c.sf = .latex) (n : String) (hn : nameOK n = true)
    (hd : c.S.names.contains "d" = false) (rest : List Tok) (f : Nat) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .letter 'd' :: (nameToks c n ++ .kw .rb :: .kw .lb ::
      .letter 'd' :: .letter 't' :: .kw .rb :: rest)) = some (dNode (.str n) "t", rest)
```

`\frac{d N}{d t}` with an italic `d` and `N` in its printed spelling reads as the time
derivative of `N`, when no variable `d` is declared.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_italic_d_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_italic_d_typst" title="Esm.Document.Math.variant_italic_d_typst"><code>variant_italic_d_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L189-L200">source</a></div>

```lean
theorem variant_italic_d_typst (c : Ctx) (hc : c.sf = .typst) (n : String) (hn : nameOK n = true)
    (hd : c.S.names.contains "d" = false) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (.kw .lpg :: .letter 'd' :: (nameToks c n ++ .kw .rp :: .kw .slash :: .kw .lpg ::
      .letter 'd' :: .letter 't' :: .kw .rp :: rest)) = some (dNode (.str n) "t", rest)
```

Typst `(d N)/(d t)` with an italic `d` reads as the time derivative of `N`, when no
variable `d` is declared.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_partial_t">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_partial_t" title="Esm.Document.Math.variant_partial_t"><code>variant_partial_t</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L204-L215">source</a></div>

```lean
theorem variant_partial_t (c : Ctx) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 2) (.kw .frac :: .kw .lb :: .kw .pdiff :: ((pr c a).at c.sf 1 ++
      .kw .rb :: .kw .lb :: .kw .pdiff :: .letter 't' :: .kw .rb :: rest)) = some (dNode a "t", rest)
```

`\frac{\partial N}{\partial t}` reads as the time derivative of `N`, the same node as
the canonical `\frac{\mathrm{d} N}{\mathrm{d} t}`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_partial_t_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_partial_t_typst" title="Esm.Document.Math.variant_partial_t_typst"><code>variant_partial_t_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L219-L231">source</a></div>

```lean
theorem variant_partial_t_typst (c : Ctx) (hc : c.sf = .typst) (a : Json) (ha : M c a) (rest : List Tok)
    (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 2) (.kw .lpg :: .kw .pdiff :: ((pr c a).at c.sf 1 ++
      .kw .rp :: .kw .slash :: .kw .lpg :: .kw .pdiff :: .letter 't' :: .kw .rp :: rest)) =
      some (dNode a "t", rest)
```

Typst `(partial N)/(partial t)` reads as the time derivative of `N`, the same node as
the canonical `(dif N)/(dif t)`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_operatorname_d">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_operatorname_d" title="Esm.Document.Math.variant_operatorname_d"><code>variant_operatorname_d</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L236-L238">source</a></div>

```lean
theorem variant_operatorname_d (c : Ctx) (f : Nat) (r : List Tok) :
    pPrim c (f + 2) (.opn "D" :: .kw .us :: r) = pPrim c (f + 1) (.kw .pdiff :: .kw .us :: r)
```

The earlier trailing-operand form `\operatorname{D}_{x}(u, a, b)` / `op("D")_(x)(u, a, b)`
reads exactly as `\partial_{x}(u, a, b)` / `partial_(x)(u, a, b)`: as `partial` with trailing
operands (spec §1.2).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_partial_axis">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_partial_axis" title="Esm.Document.Math.variant_partial_axis"><code>variant_partial_axis</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L241-L242">source</a></div>

```lean
theorem variant_partial_axis (x : Json) (w : String) (hw : w ≠ "t") : derivNode x w = pNode x w
```

A fraction of differentials along an axis other than `t` reads as `partial`, never `D`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_italic_name">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_italic_name" title="Esm.Document.Math.variant_italic_name"><code>variant_italic_name</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L246-L257">source</a></div>

```lean
theorem variant_italic_name (c : Ctx) (s : String) (rest : List Tok) (hr : Fol c.sf 10 rest) (f : Nat) :
    pPrim c (f + 1) (.it s :: rest) = some (.str s, rest)
```

`\mathit{name}` / `italic("name")` reads as the name, for any name (the explicit name
shape), before anything that does not continue a name.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_slash">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_slash" title="Esm.Document.Math.variant_slash"><code>variant_slash</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L261-L283">source</a></div>

```lean
theorem variant_slash (c : Ctx) (hc : c.sf = .latex) (a b : Json) (ha : M c a) (hb : M c b)
    (rest : List Tok) (hr : Fol c.sf 5 rest) (f : Nat)
    (hf : need 6 ((pr c a).at c.sf 6).length + need 6 ((pr c b).at c.sf 6).length ≤ f) :
    pMul c (f + 2) ((pr c a).at c.sf 6 ++ .kw .slash :: ((pr c b).at c.sf 6 ++ rest)) =
      some (node "/" [a, b], rest)
```

An inline LaTeX `a / b` reads as the quotient node, the same node as the canonical
`\frac{a}{b}`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_named_args">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_named_args" title="Esm.Document.Math.variant_named_args"><code>variant_named_args</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L288-L294">source</a></div>

```lean
theorem variant_named_args (c : Ctx) (n : String) (bs : List (String × Json))
    (hn : tnameOK n = true) (hM : ∀ kv ∈ bs, M c kv.2) (hne : bs ≠ [])
    (hk : ∀ kv ∈ bs, nameOK kv.1 = true) (hnd : (bs.map Prod.fst).Nodup) (rest : List Tok) (f : Nat)
    (hf : need 10 (callToks c.sf [.opn n] (bs.map (itemToks c))).length ≤ f) :
    pPrim c f (callToks c.sf [.opn n] (bs.map (itemToks c)) ++ rest) =
      some (tNode n (sortKV bs), rest)
```

Named template arguments read as the template application, in any order (distinct
names; the bindings are sorted to the printed order), and even when the symbol table knows
the template's parameters (the printer then writes them positionally).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_euler_italic">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_euler_italic" title="Esm.Document.Math.variant_euler_italic"><code>variant_euler_italic</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L297-L307">source</a></div>

```lean
theorem variant_euler_italic (c : Ctx) (hc : c.sf = .latex) (he : c.S.names.contains "e" = false)
    (a : Json) (ha : M c a) (rest : List Tok) (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.letter 'e' :: .kw .caret :: .kw .lb :: ((pr c a).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "exp" [a], rest)
```

An italic `e^{x}` (LaTeX) reads as `\exp(x)` when no variable `e` is declared.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_upright_e">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_upright_e" title="Esm.Document.Math.variant_upright_e"><code>variant_upright_e</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L310-L313">source</a></div>

```lean
theorem variant_upright_e (r : List Char) :
    Typst.lexIdent ("upright(e)".toList ++ r) = some (.ups [("e", "")], r)
```

`upright(e)`, unquoted, lexes to the token of `upright("e")`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_euler_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_euler_typst" title="Esm.Document.Math.variant_euler_typst"><code>variant_euler_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L317-L327">source</a></div>

```lean
theorem variant_euler_typst (c : Ctx) (hc : c.sf = .typst) (a : Json) (ha : M c a) (rest : List Tok) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.ups [("e", "")] :: .kw .caret :: .kw .lpg :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (node "exp" [a], rest)
```

Typst `upright(e)^x` and `upright("e")^x` read as `exp(x)`, always (both lex to the
token `.ups [("e", "")]`, [`variant_upright_e`](#Esm.Document.Math.variant_upright_e)).

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_euler_italic_typst">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_euler_italic_typst" title="Esm.Document.Math.variant_euler_italic_typst"><code>variant_euler_italic_typst</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L330-L340">source</a></div>

```lean
theorem variant_euler_italic_typst (c : Ctx) (hc : c.sf = .typst) (he : c.S.names.contains "e" = false)
    (a : Json) (ha : M c a) (rest : List Tok) (f : Nat) (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pPrim c (f + 3) (.letter 'e' :: .kw .caret :: .kw .lpg :: ((pr c a).at c.sf 1 ++ .kw .rp :: rest)) =
      some (node "exp" [a], rest)
```

Typst `e^x` with an italic `e` reads as `exp(x)` when no variable `e` is declared.

</div>

## Refused spellings

<div class="lean-decl lean-theorem" id="Esm.Document.Math.refuse_removed_call">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.refuse_removed_call" title="Esm.Document.Math.refuse_removed_call"><code>refuse_removed_call</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L348-L378">source</a></div>

```lean
theorem refuse_removed_call (c : Ctx) (n : String) (hn : removedOps.contains n = true) :
    ∀ f ts, pOpn c f n ts = none
```

A removed operator is refused by name in the call form.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.refuse_removed_esc">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.refuse_removed_esc" title="Esm.Document.Math.refuse_removed_esc"><code>refuse_removed_esc</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L381-L387">source</a></div>

```lean
theorem refuse_removed_esc (c : Ctx) (o : String) (hn : removedOps.contains o = true) (f : Nat) (r : List Tok) :
    pPrim c (f + 1) (.esc o :: .kw .lb :: r) = none
```

A removed operator is refused by name in the LaTeX escape form.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.variant_native_call">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.variant_native_call" title="Esm.Document.Math.variant_native_call"><code>variant_native_call</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean#L396-L407">source</a></div>

```lean
theorem variant_native_call (c : Ctx) (n : String) (hcall : callOps.contains n = false)
    (hneg : n ≠ "neg") (hpow : n ≠ "pow") (hD : n ≠ "D") (hrem : removedOps.contains n = false)
    (ht : tparams c.S n = none) (f : Nat) (r : List Tok) (x : Json) (xs : List Json) (r' : List Tok)
    (ha : pCallArgs c f r = some ((x :: xs).map CallArg.pos, .kw .rp :: r')) :
    pOpn c (f + 1) n (.kw .lp :: r) = some (node n (x :: xs), r')
```

A native operator written in the call form, `\operatorname{exp}(x)` or `op("exp")(x)`,
reads as the native node `exp(x)`: an operator name that is not a call-tier, deprecated,
removed or template name reads as the node it names.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Variants.lean">the source</a>.</p>
