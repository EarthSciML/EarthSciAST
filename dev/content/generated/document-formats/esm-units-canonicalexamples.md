---
title: "Closed examples of the canonical unit spelling"
type: lean
lean_module: "Esm.Units.CanonicalExamples"
weight: 68
---

<p class="lean-meta">Lean module <code>Esm.Units.CanonicalExamples</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/CanonicalExamples.lean"><code>formal/Esm/Units/CanonicalExamples.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-units-typeset"><code>Esm.Units.Typeset</code></a></p>

Tests, not properties: the theorems quantifying over all inputs are in
[`Esm.Units.Canonical`](/generated/document-formats/esm-units-canonical) and [`Esm.Units.Typeset`](/generated/document-formats/esm-units-typeset). Each example is checked by the kernel.

<div class="lean-decl" id="Esm.Units.CanonicalExamples.factorsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.CanonicalExamples.factorsOf" title="Esm.Units.CanonicalExamples.factorsOf"><code>factorsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/CanonicalExamples.lean#L15-L18">source</a></div>

```lean
def factorsOf (s : String) : List Factor
```

The two-sided normal form of a unit string (empty when it does not parse).

</div>

## Spellings that canonicalize alike

## Rational exponents, `%`, kept symbols

## No cancellation across the fraction bar

<div class="lean-decl" id="Esm.Units.CanonicalExamples.L58">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Units.CanonicalExamples.L58">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/CanonicalExamples.lean#L58">source</a></div>

```lean
example : canon "bogus^0*s" = "bogus^0*s"
```

A dropped symbol must still name a unit: `bogus` does not, so the string is
left as written (and keeps failing to resolve).

</div>

## The dimensionless spellings and unparseable strings

## Typeset forms
