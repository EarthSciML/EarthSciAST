---
title: "Exact scales of rational numbers"
type: lean
lean_module: "Esm.Units.Rat"
weight: 75
---

<p class="lean-meta">Lean module <code>Esm.Units.Rat</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean"><code>formal/Esm/Units/Rat.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-units-core"><code>Esm.Units.Core</code></a></p>

`Scale.ofRat q` is the prime factorization of a positive rational `q` in the
formal-product representation: every prime of the numerator with exponent `1`
and every prime of the denominator with exponent `-1`. Its exponent at a prime
`p` is the `p`-adic valuation of `q`, so multiplication of rationals is addition
of exponent maps — which is what lets every registry identity be checked exactly.

<div class="lean-decl" id="Esm.Units.Scale.ofPrimes">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.ofPrimes" title="Esm.Units.Scale.ofPrimes"><code>Scale.ofPrimes</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L16-L20">source</a></div>

```lean
def Scale.ofPrimes : (l : List ℕ) → (∀ p ∈ l, p.Prime) → ℚ → Scale
```

Each prime in the list, with exponent `e`.

</div>

<div class="lean-decl" id="Esm.Units.Scale.ofNat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.ofNat" title="Esm.Units.Scale.ofNat"><code>Scale.ofNat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L23-L24">source</a></div>

```lean
def Scale.ofNat (n : ℕ) (e : ℚ) : Scale
```

The prime factorization of `n`, each prime with exponent `e`.

</div>

<div class="lean-decl" id="Esm.Units.Scale.ofRat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.ofRat" title="Esm.Units.Scale.ofRat"><code>Scale.ofRat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L27">source</a></div>

```lean
def Scale.ofRat (q : ℚ) : Scale
```

The exact scale of a positive rational.

</div>

<div class="lean-decl" id="Esm.Units.Scale.pi">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.pi" title="Esm.Units.Scale.pi"><code>Scale.pi</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L30">source</a></div>

```lean
def Scale.pi (e : ℚ) : Scale
```

`π ^ e`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.exp_ofRat_prime">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.exp_ofRat_prime" title="Esm.Units.Scale.exp_ofRat_prime"><code>Scale.exp_ofRat_prime</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L78-L83">source</a></div>

```lean
@[simp] theorem Scale.exp_ofRat_prime (q : ℚ) (p : Nat.Primes) :
    Scale.exp (Scale.ofRat q) (.prime p) = (padicValRat p.1 q : ℚ)
```

The exponent of a prime in `ofRat q` is the `p`-adic valuation of `q`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.real_ofRat">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.real_ofRat" title="Esm.Units.Scale.real_ofRat"><code>Scale.real_ofRat</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L86-L94">source</a></div>

```lean
theorem Scale.real_ofRat (q : ℚ) (hq : 0 < q) : Scale.real (Scale.ofRat q) = (q : ℝ)
```

`ofRat q` denotes `q`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.exp_ofRat_mul">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.exp_ofRat_mul" title="Esm.Units.Scale.exp_ofRat_mul"><code>Scale.exp_ofRat_mul</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L107-L114">source</a></div>

```lean
theorem Scale.exp_ofRat_mul (q r : ℚ) (hq : q ≠ 0) (hr : r ≠ 0) :
    Scale.exp (Scale.ofRat (q * r)) = Scale.exp (Scale.ofRat q ++ Scale.ofRat r)
```

Multiplying rationals adds their exact scales.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.Scale.exp_ofRat_inj">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.Scale.exp_ofRat_inj" title="Esm.Units.Scale.exp_ofRat_inj"><code>Scale.exp_ofRat_inj</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean#L132-L139">source</a></div>

```lean
theorem Scale.exp_ofRat_inj (q r : ℚ) (hq : 0 < q) (hr : 0 < r) :
    Scale.exp (Scale.ofRat q) = Scale.exp (Scale.ofRat r) ↔ q = r
```

Two positive rationals have the same exact scale iff they are equal.

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Rat.lean">the source</a>.</p>
