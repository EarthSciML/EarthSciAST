---
title: "Units: dimensions and exact scales (esm-spec §4.8.1)"
type: lean
lean_module: "Esm.Units.Core"
weight: 62
---

<p class="lean-meta">Lean module <code>Esm.Units.Core</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean"><code>formal/Esm/Units/Core.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <code>Mathlib.Analysis.SpecialFunctions.Pow.Real</code>, <code>Mathlib.Analysis.Real.Pi.Bounds</code>, <code>Mathlib.Data.Nat.Factors</code>, <code>Mathlib.NumberTheory.Padics.PadicVal.Basic</code></p>

A **dimension** is a vector of rational exponents over exactly the eight axes
`m kg s mol K A cd rad` (§4.8.1 "The eight canonical dimension axes").

A **scale** is exact. §4.8.1 recommends representing it as "a map from prime
factor (and the symbol `π`) to a rational exponent"; this module does exactly
that. A scale is written as a formal product `∏ bᵢ ^ eᵢ` (a list of base/exponent
pairs, [`Scale`](#Esm.Units.Scale)), and what it MEANS is its exponent map `Scale.exp : Base → ℚ`:
two scales are the same scale iff their exponent maps are equal. Multiplying
units appends the lists (adds exponent maps), a rational power multiplies every
exponent, so a composite unit's scale stays exact (§4.8.1 "Scales are EXACT").

[`Scale.real`](#Esm.Units.Scale.real) is the real number a scale denotes. It is a homomorphism, depends
only on the exponent map, and is positive; these are the facts that make the
formal representation a faithful exact model of the spec's real-valued scales.

<div class="lean-decl" id="Esm.Units.Axis">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Units.Axis" title="Esm.Units.Axis"><code>Axis</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L28-L30">source</a></div>

```lean
inductive Axis
  | m | kg | s | mol | K | A | cd | rad
  deriving DecidableEq, Repr, Inhabited
```

The eight canonical dimension axes, and no others (§4.8.1).

</div>

<div class="lean-decl" id="Esm.Units.Axis.all">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Axis.all" title="Esm.Units.Axis.all"><code>Axis.all</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L33">source</a></div>

```lean
def Axis.all : List Axis
```

Every axis, in the spec's order.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Axis.exactly_eight">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Axis.exactly_eight" title="Esm.Units.Axis.exactly_eight"><code>Axis.exactly_eight</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L38-L40">source</a></div>

```lean
theorem Axis.exactly_eight :
    (∀ a : Axis, a ∈ Axis.all) ∧ Axis.all.length = 8 ∧ Axis.all.Nodup
```

Exactly eight axes, and no others.

</div>

<div class="lean-decl" id="Esm.Units.Dim">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Units.Dim" title="Esm.Units.Dim"><code>Dim</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L51">source</a></div>

```lean
abbrev Dim
```

A dimension: a rational exponent per axis. Unit multiplication is `+`, a
rational power `q` is `q • ·`.

</div>

<div class="lean-decl" id="Esm.Units.Dim.of">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Dim.of" title="Esm.Units.Dim.of"><code>Dim.of</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L54">source</a></div>

```lean
def Dim.of (a : Axis) : Dim
```

The dimension of one axis to the first power.

</div>

<div class="lean-decl" id="Esm.Units.Base">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Units.Base" title="Esm.Units.Base"><code>Base</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L57-L60">source</a></div>

```lean
inductive Base
  | pi
  | prime (p : Nat.Primes)
  deriving DecidableEq
```

A base of the exact-scale representation: `π` or a prime.

</div>

<div class="lean-decl" id="Esm.Units.Base.real">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Base.real" title="Esm.Units.Base.real"><code>Base.real</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L69-L71">source</a></div>

```lean
noncomputable def Base.real : Base → ℝ
```

The real number a base denotes.

</div>

<div class="lean-decl" id="Esm.Units.Scale">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Units.Scale" title="Esm.Units.Scale"><code>Scale</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L79">source</a></div>

```lean
abbrev Scale
```

An exact scale as a formal product `∏ b ^ e`. Only its exponent map
([`Scale.exp`](#Esm.Units.Scale.exp)) is meaningful; the list order and repetitions are not.

</div>

<div class="lean-decl" id="Esm.Units.Scale.exp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.exp" title="Esm.Units.Scale.exp"><code>Scale.exp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L82-L84">source</a></div>

```lean
def Scale.exp : Scale → Base → ℚ
```

The exponent of base `b` in a scale.

</div>

<div class="lean-decl" id="Esm.Units.Scale.rpow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.rpow" title="Esm.Units.Scale.rpow"><code>Scale.rpow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L87">source</a></div>

```lean
def Scale.rpow (s : Scale) (q : ℚ) : Scale
```

Raise a scale to a rational power.

</div>

<div class="lean-decl" id="Esm.Units.Scale.real">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.real" title="Esm.Units.Scale.real"><code>Scale.real</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L90-L91">source</a></div>

```lean
noncomputable def Scale.real (s : Scale) : ℝ
```

The real number a scale denotes.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.exp_eq_zero_of_not_mem">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.exp_eq_zero_of_not_mem" title="Esm.Units.Scale.exp_eq_zero_of_not_mem"><code>Scale.exp_eq_zero_of_not_mem</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L115-L122">source</a></div>

```lean
theorem Scale.exp_eq_zero_of_not_mem (s : Scale) (b : Base) (h : b ∉ s.map Prod.fst) :
    Scale.exp s b = 0
```

A base outside a scale's support has exponent 0.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.exp_eq_iff">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.exp_eq_iff" title="Esm.Units.Scale.exp_eq_iff"><code>Scale.exp_eq_iff</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L125-L134">source</a></div>

```lean
theorem Scale.exp_eq_iff (s t : Scale) :
    Scale.exp s = Scale.exp t ↔ ∀ b ∈ (s ++ t).map Prod.fst, Scale.exp s b = Scale.exp t b
```

Equality of exponent maps is decided on the finitely many bases that occur.

</div>

### The real value of a scale

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.real_eq_prod">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.real_eq_prod" title="Esm.Units.Scale.real_eq_prod"><code>Scale.real_eq_prod</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L174-L193">source</a></div>

```lean
theorem Scale.real_eq_prod (s : Scale) (S : Finset Base) (hS : ∀ x ∈ s, x.1 ∈ S) :
    Scale.real s = ∏ b ∈ S, b.real ^ ((Scale.exp s b : ℚ) : ℝ)
```

The real value as a product over any finite set of bases containing the
support.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.real_congr">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.real_congr" title="Esm.Units.Scale.real_congr"><code>Scale.real_congr</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L197-L207">source</a></div>

```lean
theorem Scale.real_congr (s t : Scale) (h : Scale.exp s = Scale.exp t) :
    Scale.real s = Scale.real t
```

The real value depends only on the exponent map: the formal representation
never distinguishes a scale from itself.

</div>

### Units

<div class="lean-decl" id="Esm.Units.U">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Units.U" title="Esm.Units.U"><code>U</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L212-L214">source</a></div>

```lean
structure U where
  dim : Dim
  scale : Scale
```

A resolved unit: a dimension and an exact scale.

</div>

<div class="lean-decl" id="Esm.Units.U.one">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.one" title="Esm.Units.U.one"><code>one</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L219">source</a></div>

```lean
def one : U
```

The dimensionless unit at scale 1.

</div>

<div class="lean-decl" id="Esm.Units.U.rpow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.rpow" title="Esm.Units.U.rpow"><code>rpow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L224">source</a></div>

```lean
def rpow (u : U) (q : ℚ) : U
```

A rational power.

</div>

<div class="lean-decl" id="Esm.Units.U.val">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.val" title="Esm.Units.U.val"><code>val</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L231">source</a></div>

```lean
def val (u : U) : Dim × (Base → ℚ)
```

What a unit means: its dimension and its scale's exponent map.

</div>

<div class="lean-decl" id="Esm.Units.U.Agree">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.Agree" title="Esm.Units.U.Agree"><code>Agree</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L235">source</a></div>

```lean
def Agree (u v : U) : Prop
```

Two units agree iff they have the same dimension and the same exact scale
(§4.8.3 "agreement"; decided exactly, §4.8.1).

</div>

<div class="lean-decl" id="Esm.Units.U.ofScale">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.ofScale" title="Esm.Units.U.ofScale"><code>ofScale</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L243">source</a></div>

```lean
def ofScale (s : Scale) : U
```

The unit that is the given exact positive rational, dimensionless.

</div>

<div class="lean-decl" id="Esm.Units.U.base">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.U.base" title="Esm.Units.U.base"><code>base</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean#L246">source</a></div>

```lean
def base (a : Axis) : U
```

A unit of one axis at scale 1.

</div>

<p class="lean-meta">This module also proves 15 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Units/Core.lean">the source</a>.</p>
