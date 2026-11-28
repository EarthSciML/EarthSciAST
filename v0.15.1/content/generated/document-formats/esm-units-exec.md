---
title: "Executable read-outs of a resolved unit"
type: lean
lean_module: "Esm.Units.Exec"
weight: 70
---

<p class="lean-meta">Lean module <code>Esm.Units.Exec</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean"><code>formal/Esm/Units/Exec.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-units-grammar"><code>Esm.Units.Grammar</code></a></p>

Rendering for the `esm-lean units` adapter: the exponent map of a scale in
normal form, the exact scale as the `p/q*pi^k` string the unit-registry golden
uses, and a floating-point conversion factor (for the golden's 1e-12 check only;
no verdict reads it, §4.8.1).

<div class="lean-decl" id="Esm.Units.Scale.bases">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.bases" title="Esm.Units.Scale.bases"><code>Scale.bases</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean#L19">source</a></div>

```lean
def Scale.bases (s : Scale) : List Base
```

The distinct bases of a scale, in first-occurrence order.

</div>

<div class="lean-decl" id="Esm.Units.Scale.normal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.normal" title="Esm.Units.Scale.normal"><code>Scale.normal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean#L22-L27">source</a></div>

```lean
def Scale.normal (s : Scale) : List (Base × ℚ)
```

The nonzero exponents of a scale, primes ascending, π last.

</div>

<div class="lean-decl" id="Esm.Units.Scale.exactString">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.exactString" title="Esm.Units.Scale.exactString"><code>Scale.exactString</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean#L34-L48">source</a></div>

```lean
def Scale.exactString (s : Scale) : String
```

The exact scale as a string: `p/q` (lowest terms, `/q` omitted when 1), then
`*pi` or `*pi^k`. A prime with a non-integer exponent is written `*p^(a/b)`.

</div>

<div class="lean-decl" id="Esm.Units.Scale.toFloat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Scale.toFloat" title="Esm.Units.Scale.toFloat"><code>Scale.toFloat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean#L53-L61">source</a></div>

```lean
def Scale.toFloat (s : Scale) : Float
```

A floating-point value of the scale (product of `p ^ e`, `π ^ k`).

</div>

<div class="lean-decl" id="Esm.Units.Dim.entries">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.Dim.entries" title="Esm.Units.Dim.entries"><code>Dim.entries</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Exec.lean#L64-L65">source</a></div>

```lean
def Dim.entries (d : Dim) : List (String × ℚ)
```

The dimension's nonzero exponents, by axis name.

</div>
