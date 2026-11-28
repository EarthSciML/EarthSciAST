---
title: "Laws of the unit-string grammar (esm-spec §4.8.2)"
type: lean
lean_module: "Esm.Units.GrammarLaws"
weight: 72
---

<p class="lean-meta">Lean module <code>Esm.Units.GrammarLaws</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean"><code>formal/Esm/Units/GrammarLaws.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-units-grammar"><code>Esm.Units.Grammar</code></a></p>

* `*`, `/` and juxtaposition are one precedence level, folded LEFT to right
  ([`parse_fold`](#Esm.Units.parse_fold)), and `^`/`**` binds tighter than all three ([`parse_pow_binds`](#Esm.Units.parse_pow_binds)).
* A numeric atom other than 1 is a scaling factor wherever it stands
  ([`parse_scaling_factor_head`](#Esm.Units.parse_scaling_factor_head), [`parse_scaling_factor_after`](#Esm.Units.parse_scaling_factor_after)).
* `-` is not an operator ([`parse_minus_rejected`](#Esm.Units.parse_minus_rejected), [`resolve_minus_rejected`](#Esm.Units.resolve_minus_rejected)).
* Whitespace between terms is multiplication ([`resolve_space_eq_star`](#Esm.Units.resolve_space_eq_star)).
* The table is flat: a single run of identifier characters resolves iff it is a
  table key exactly as spelled — no SI-prefix mechanism, no implicit split
  ([`resolve_ident_run`](#Esm.Units.resolve_ident_run)).

## Token level

<div class="lean-decl" id="Esm.Units.Op">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Units.Op" title="Esm.Units.Op"><code>Op</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L22-L24">source</a></div>

```lean
inductive Op
  | star | slash | juxt
  deriving DecidableEq, Repr
```

The three spellings of the one precedence level.

</div>

<div class="lean-decl" id="Esm.Units.opToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.opToks" title="Esm.Units.opToks"><code>opToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L27-L31">source</a></div>

```lean
def opToks : List (Op × String) → List Tok
```

`op b` sequences as tokens.

</div>

<div class="lean-decl" id="Esm.Units.foldOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.foldOps" title="Esm.Units.foldOps"><code>foldOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L34-L38">source</a></div>

```lean
def foldOps (acc : UExpr) : List (Op × String) → UExpr
```

The left fold the spec prescribes.

</div>

<div class="lean-decl" id="Esm.Units.NoPowHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.NoPowHead" title="Esm.Units.NoPowHead"><code>NoPowHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L41">source</a></div>

```lean
def NoPowHead (ts : List Tok) : Prop
```

The token list does not start with `^` or `**`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pUnit_fold">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pUnit_fold" title="Esm.Units.pUnit_fold"><code>pUnit_fold</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L94-L100">source</a></div>

```lean
theorem pUnit_fold (a : String) (ops : List (Op × String)) (ts : List Tok) (hts : NoPowHead ts)
    (n k : ℕ) (h : 3 * ops.length + k + 3 ≤ n) :
    ∃ m, k ≤ m ∧ pUnit n (.sym a :: opToks ops ++ ts) = pTail m (foldOps (.sym a) ops) ts
```

The parse of `a`, and of `pUnit` after it, through the left fold.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_fold">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_fold" title="Esm.Units.parse_fold"><code>parse_fold</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L105-L117">source</a></div>

```lean
theorem parse_fold :
    ∀ (a : String) (ops : List (Op × String)),
      parse (.sym a :: opToks ops) = .ok (foldOps (.sym a) ops)
```

`*`, `/` and juxtaposition are ONE precedence level, evaluated LEFT to RIGHT:
any chain of symbols joined by them parses as the left fold. (`J/mol*K` is
`(J/mol)*K`; `L/mol/s` is `(L/mol)/s`; `kg/m*s` is `(kg/m)*s`.)

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_minus_rejected">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_minus_rejected" title="Esm.Units.parse_minus_rejected"><code>parse_minus_rejected</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L121-L132">source</a></div>

```lean
theorem parse_minus_rejected :
    ∀ (a : String) (ops : List (Op × String)) (rest : List Tok),
      ∃ err, parse (.sym a :: opToks ops ++ .minus :: rest) = .error err
```

`-` is not an operator: a `-` after any chain of terms is rejected. (This is
why MOVES's `g/hp-hr` does not resolve.)

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_scaling_factor_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_scaling_factor_head" title="Esm.Units.parse_scaling_factor_head"><code>parse_scaling_factor_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L137-L144">source</a></div>

```lean
theorem parse_scaling_factor_head :
    ∀ (lit : String) (v : ℚ) (i : Bool) (ts : List Tok), lit ≠ "1" →
      parse (.num lit v i :: ts) = .error (.scalingFactor lit)
```

A numeric atom other than the literal `1` is a scaling factor (ruling
Q-104: `01` and `1.0` are too) — at the head of a unit string (`1000/s`,
`0.5 m`) …

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_scaling_factor_after">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_scaling_factor_after" title="Esm.Units.parse_scaling_factor_after"><code>parse_scaling_factor_after</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L148-L160">source</a></div>

```lean
theorem parse_scaling_factor_after :
    ∀ (a : String) (ops : List (Op × String)) (op : Tok) (lit : String) (v : ℚ) (i : Bool)
      (rest : List Tok), (op = .star ∨ op = .slash) → lit ≠ "1" →
      parse (.sym a :: opToks ops ++ op :: .num lit v i :: rest) = .error (.scalingFactor lit)
```

… and after any chain of terms and an operator (`(m/s)^-1/3` reads as
`((m/s)^-1)/3`: the `3` is a scaling factor, not part of an exponent).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.parse_pow_binds">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.parse_pow_binds" title="Esm.Units.parse_pow_binds"><code>parse_pow_binds</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L164-L172">source</a></div>

```lean
theorem parse_pow_binds :
    ∀ (a b lit : String) (q : ℚ) (i : Bool) (pw : Tok), (pw = .caret ∨ pw = .dstar) →
      parse [.sym a, .slash, .sym b, pw, .num lit q i] = .ok (.div (.sym a) (.pow (.sym b) q)) ∧
      parse [.sym a, .slash, .sym b, pw, .minus, .num lit q i] =
        .ok (.div (.sym a) (.pow (.sym b) (-q)))
```

`^` and `**` bind tighter than `/` (and `*`, juxtaposition): `a/b^q` is
`a / (b^q)`, for a signed or unsigned numeric exponent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.pExp_rational">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.pExp_rational" title="Esm.Units.pExp_rational"><code>pExp_rational</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L175-L182">source</a></div>

```lean
theorem pExp_rational :
    ∀ (p q : ℕ) (neg : Bool) (lp lq : String) (ts : List Tok), q ≠ 0 →
      pExp (.lp :: (if neg then [Tok.minus] else []) ++
        .num lp (p : ℚ) true :: .slash :: .num lq (q : ℚ) true :: .rp :: ts)
        = .ok ((if neg then -(p : ℚ) else p) / q, ts)
```

Rational exponents: `^(p/q)` and `^(-p/q)` are the exponent `±p/q`, exactly.

</div>

## Character level

<div class="lean-decl" id="Esm.Units.IdentRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.IdentRun" title="Esm.Units.IdentRun"><code>IdentRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L188-L189">source</a></div>

```lean
def IdentRun (a : List Char) : Prop
```

A run of identifier characters that starts with a letter: what the lexer
reads as ONE symbol token.

</div>

<div class="lean-decl" id="Esm.Units.RunEnds">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.RunEnds" title="Esm.Units.RunEnds"><code>RunEnds</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L242">source</a></div>

```lean
def RunEnds (rest : List Char) : Prop
```

The rest after a symbol run: empty or starting with a non-identifier
character.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.normalizeAux_ascii">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.normalizeAux_ascii" title="Esm.Units.normalizeAux_ascii"><code>normalizeAux_ascii</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L265-L288">source</a></div>

```lean
theorem normalizeAux_ascii : ∀ (n : ℕ) (cs : List Char), (∀ x ∈ cs, x.toNat < 128) →
    normalizeAux n cs = cs
```

On ASCII input the Unicode rewrite is the identity.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolve_ident_run">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolve_ident_run" title="Esm.Units.resolve_ident_run"><code>resolve_ident_run</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L315-L324">source</a></div>

```lean
theorem resolve_ident_run :
    ∀ a : List Char, IdentRun a → ((∃ u, resolveChars a = .ok u) ↔ String.ofList a ∈ keys)
```

The table is FLAT, and there is NO SI-prefix mechanism: a run of identifier
characters resolves iff it is a §4.8.1 key exactly as spelled. So `mm` resolves
because it is a key, and `kmolec`, `nppb`, `Tm`, `cm3` do not, because they are
not — nothing composes a prefix with a symbol, or splits a run.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolves_ident_run">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolves_ident_run" title="Esm.Units.resolves_ident_run"><code>resolves_ident_run</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L327-L332">source</a></div>

```lean
theorem resolves_ident_run :
    ∀ s : String, IdentRun s.toList → (Resolves s ↔ s ∈ keys)
```

The same, for strings.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolve_space_eq_star">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolve_space_eq_star" title="Esm.Units.resolve_space_eq_star"><code>resolve_space_eq_star</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L352-L380">source</a></div>

```lean
theorem resolve_space_eq_star :
    ∀ a b : List Char, IdentRun a → IdentRun b →
      resolveChars (a ++ ' ' :: b) = resolveChars (a ++ '*' :: b)
```

WHITESPACE between terms means MULTIPLICATION: `a b` resolves exactly as
`a*b`, for any two symbol runs.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.resolve_minus_rejected">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolve_minus_rejected" title="Esm.Units.resolve_minus_rejected"><code>resolve_minus_rejected</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L383-L402">source</a></div>

```lean
theorem resolve_minus_rejected :
    ∀ a b : List Char, IdentRun a → IdentRun b → ¬ ∃ u, resolveChars (a ++ '-' :: b) = .ok u
```

`-` is not an operator, at the string level: `a-b` never resolves.

</div>

## The listed exclusions

<div class="lean-decl lean-theorem" id="Esm.Units.exclusions_do_not_resolve">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.exclusions_do_not_resolve" title="Esm.Units.exclusions_do_not_resolve"><code>exclusions_do_not_resolve</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L410-L424">source</a></div>

```lean
theorem exclusions_do_not_resolve :
    ∀ s ∈ ["ton", "t", "d", "in", "yd", "foot", "feet", "mile", "miles", "mph", "tons",
      "metric_ton", "short_tons", "gallon", "pound", "kmolec", "nppb", "Tm", "dam", "dg",
      "PW", "fs", "cm3", "s2"], ¬ Resolves s
```

The exclusions §4.8.1 states (no `ton`, no `t`, no `d`; the imperial family is
symbol-only: no `in`, `yd`, `foot`, `feet`, `mile`, `miles`, fused `mph`; full
spellings only), plus prefixed spellings the flat table does not hold
(`kmolec`, `nppb`, `Tm`, `dam`, `cm3`). None of them resolves.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.hp_hr_rejected">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.hp_hr_rejected" title="Esm.Units.hp_hr_rejected"><code>hp_hr_rejected</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean#L427-L430">source</a></div>

```lean
theorem hp_hr_rejected : ¬ Resolves "hp-hr"
```

`hp-hr` (MOVES's spelling of `g/hp-hr`'s denominator) does not resolve.

</div>

<p class="lean-meta">This module also proves 18 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/GrammarLaws.lean">the source</a>.</p>
