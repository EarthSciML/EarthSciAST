---
title: "Factor lists: the flattened form of a parsed unit"
type: lean
lean_module: "Esm.Units.Factors"
weight: 71
---

<p class="lean-meta">Lean module <code>Esm.Units.Factors</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean"><code>formal/Esm/Units/Factors.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-units-grammarlaws"><code>Esm.Units.GrammarLaws</code></a>, <code>Mathlib.Data.String.Basic</code>, <code>Mathlib.Data.List.Sort</code>, <code>Mathlib.Algebra.BigOperators.Group.Finset.Basic</code></p>

The canonical unit spelling ([`Esm.Units.Canonical`](/generated/document-formats/esm-units-canonical)) is computed from a parsed
unit tree (`UExpr`, esm-spec §4.8.2) by flattening it to a list of factors
(symbol, rational exponent) and normalizing that list:

* [`UExpr.factors`](#Esm.Units.UExpr.factors) flattens: `*` concatenates, `/` negates the exponents of its
  right operand, `^q` multiplies every exponent below it by `q`. The atom `1`
  and the symbol `dimensionless` contribute nothing: §4.8.1 lists `""`, `"1"`
  and `"dimensionless"` as the three spellings of ONE dimensionless entry, so
  `dimensionless` is a spelling of the atom `1`, not a symbol to be kept.
* [`norm`](#Esm.Units.norm) sums the exponents of each symbol, drops the symbols whose sum is
  zero, and sorts by symbol (`String`'s order: codepoint order, so uppercase
  before lowercase).
* [`norm2`](#Esm.Units.norm2) splits the list into its numerator side (positive exponents) and its
  denominator side (the rest) and applies [`norm`](#Esm.Units.norm) to each side separately, so a
  symbol on both sides stays on both: `mol/mol` is not cancelled (ruling of
  2026-11-12). This is the canonical form; [`norm`](#Esm.Units.norm) is its building block.

This is purely syntactic: no symbol is looked up, so `km` stays `km` and `ppm`
stays `ppm`. Two factor lists denote the same product iff they have the same
exponent function [`expOf`](#Esm.Units.expOf); [`norm`](#Esm.Units.norm) picks the one sorted, zero-free list with a
given exponent function ([`eq_of_expOf_eq`](#Esm.Units.eq_of_expOf_eq)), and [`norm2`](#Esm.Units.norm2) keeps that exponent
function too (`expOf_norm2`).

<div class="lean-decl" id="Esm.Units.Factor">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Units.Factor" title="Esm.Units.Factor"><code>Factor</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L36">source</a></div>

```lean
abbrev Factor
```

A unit factor: a symbol and its rational exponent.

</div>

<div class="lean-decl" id="Esm.Units.UExpr.factors">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.UExpr.factors" title="Esm.Units.UExpr.factors"><code>UExpr.factors</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L39-L44">source</a></div>

```lean
def UExpr.factors : UExpr → List Factor
```

Flatten a parsed unit to its factor list.

</div>

<div class="lean-decl" id="Esm.Units.expOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.expOf" title="Esm.Units.expOf"><code>expOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L47-L48">source</a></div>

```lean
def expOf (l : List Factor) (s : String) : ℚ
```

The total exponent of symbol `s` in a factor list.

</div>

<div class="lean-decl" id="Esm.Units.syms">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.syms" title="Esm.Units.syms"><code>syms</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L51">source</a></div>

```lean
def syms (l : List Factor) : List String
```

The symbols of a factor list.

</div>

<div class="lean-decl" id="Esm.Units.norm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.norm" title="Esm.Units.norm"><code>norm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L54-L56">source</a></div>

```lean
def norm (l : List Factor) : List Factor
```

Sum exponents per symbol, drop zero sums, sort by symbol.

</div>

<div class="lean-decl" id="Esm.Units.Normal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Normal" title="Esm.Units.Normal"><code>Normal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L59-L60">source</a></div>

```lean
def Normal (l : List Factor) : Prop
```

A normalized factor list: strictly increasing symbols, no zero exponent.

</div>

## The exponent function

## [`norm`](#Esm.Units.norm)

<div class="lean-decl lean-theorem" id="Esm.Units.expOf_of_mem_normal">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.expOf_of_mem_normal" title="Esm.Units.expOf_of_mem_normal"><code>expOf_of_mem_normal</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L148-L163">source</a></div>

```lean
theorem expOf_of_mem_normal {l : List Factor} (hl : Normal l) {f : Factor} (hf : f ∈ l) :
    expOf l f.1 = f.2
```

In a normal list, a member's exponent is its symbol's total exponent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.eq_of_expOf_eq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.eq_of_expOf_eq" title="Esm.Units.eq_of_expOf_eq"><code>eq_of_expOf_eq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L178-L185">source</a></div>

```lean
theorem eq_of_expOf_eq {l l' : List Factor} (hl : Normal l) (hl' : Normal l')
    (h : expOf l = expOf l') : l = l'
```

A normal list is determined by its exponent function.

</div>

## The two-sided normal form

The canonical spelling never cancels a symbol across the fraction bar: `mol/mol`
stays `mol/mol`. A factor is on the numerator side when its net exponent (after
`/` and negative exponents) is positive, and on the denominator side otherwise;
each side is normalized on its own ([`norm2`](#Esm.Units.norm2)). A zero exponent (`m^0`) is dropped.

<div class="lean-decl" id="Esm.Units.numFactors">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.numFactors" title="Esm.Units.numFactors"><code>numFactors</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L204">source</a></div>

```lean
def numFactors (l : List Factor) : List Factor
```

The factors with a positive exponent.

</div>

<div class="lean-decl" id="Esm.Units.denFactors">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.denFactors" title="Esm.Units.denFactors"><code>denFactors</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L206">source</a></div>

```lean
def denFactors (l : List Factor) : List Factor
```

The factors with a nonpositive exponent.

</div>

<div class="lean-decl" id="Esm.Units.norm2">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.norm2" title="Esm.Units.norm2"><code>norm2</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L221">source</a></div>

```lean
def norm2 (l : List Factor) : List Factor
```

Each side normalized on its own: numerator side, then denominator side.

</div>

<div class="lean-decl" id="Esm.Units.Normal2">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Normal2" title="Esm.Units.Normal2"><code>Normal2</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L225-L227">source</a></div>

```lean
def Normal2 (l : List Factor) : Prop
```

A two-sided normal list: its positive factors, then its negative ones, each
side normal; no zero exponent.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.exp_of_mem_norm">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.exp_of_mem_norm" title="Esm.Units.exp_of_mem_norm"><code>exp_of_mem_norm</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L261-L262">source</a></div>

```lean
theorem exp_of_mem_norm (l : List Factor) {f : Factor} (hf : f ∈ norm l) : f.2 = expOf l f.1
```

In `norm l`, each member's exponent is the total exponent of its symbol in `l`.

</div>

## Weighted sums depend only on the exponent function

<div class="lean-decl" id="Esm.Units.wsum">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.wsum" title="Esm.Units.wsum"><code>wsum</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean#L313">source</a></div>

```lean
def wsum (v : String → M) (l : List Factor) : M
```

`Σ q • v s` over a factor list.

</div>

<p class="lean-meta">This module also proves 31 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Factors.lean">the source</a>.</p>
