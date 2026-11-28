---
title: "The unit registry table (esm-spec §4.8.1)"
type: lean
lean_module: "Esm.Units.Registry"
weight: 64
---

<p class="lean-meta">Lean module <code>Esm.Units.Registry</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean"><code>formal/Esm/Units/Registry.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-units-rat"><code>Esm.Units.Rat</code></a></p>

The flat table, exactly as written in §4.8.1: a symbol is in it, spelled exactly,
or it does not resolve. Each entry is built from the scale the spec STATES for it,
so the identities in [`Esm.Units.Identities`](/generated/document-formats/esm-units-identities) are checks of the table rather than
restatements — with three exceptions, where the spec states the scale AS a
product: `hp` (`550 × 0.3048 × 0.45359237 × 9.80665`), `psi`
(`0.45359237 × 9.80665 / 0.0254²`) and `Torr` (`101325/760`). Their identities
confirm only that those products agree with the `ft`, `lb` and `atm` entries;
the independent check on `hp` is its binary64 fold ([`hp_fold_left_to_right`](/generated/document-formats/esm-units-identities#Esm.Units.hp_fold_left_to_right)).

Scales the spec does not state are the SI definitions the symbol names (`km` is
1000 m, `bar` is 10⁵ Pa, …), except for three choices recorded as questions in
the phase-1 report: `cal` (thermochemical 4.184 J — the spec names no
calorie), and the scales of the mixing ratios `ppm`/`ppb`/`ppt` (the spec calls
them dimensionless and gives no scale; `ppt` is read as 10⁻¹², parts per
trillion), each matching every binding.

<div class="lean-decl" id="Esm.Units.D">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.D" title="Esm.Units.D"><code>D</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L26-L28">source</a></div>

```lean
def D (m kg s mol K A cd rad : ℚ) : Dim
```

A dimension from its eight exponents, in axis order.

</div>

<div class="lean-decl" id="Esm.Units.mk">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.mk" title="Esm.Units.mk"><code>mk</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L31">source</a></div>

```lean
def mk (d : Dim) (q : ℚ) : U
```

A registry entry: a dimension and an exact positive rational scale.

</div>

<div class="lean-decl" id="Esm.Units.mkPi">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.mkPi" title="Esm.Units.mkPi"><code>mkPi</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L34">source</a></div>

```lean
def mkPi (d : Dim) (q : ℚ) (k : ℚ) : U
```

A registry entry with a power of π in its scale.

</div>

<div class="lean-decl" id="Esm.Units.table">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.table" title="Esm.Units.table"><code>table</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L64-L124">source</a></div>

```lean
def table : List (String × U)
```

The §4.8.1 table, group by group, in the spec's order.

</div>

<div class="lean-decl" id="Esm.Units.keys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.keys" title="Esm.Units.keys"><code>keys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L128">source</a></div>

```lean
def keys : List String
```

The table's keys.

</div>

<div class="lean-decl" id="Esm.Units.lookup">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.lookup" title="Esm.Units.lookup"><code>lookup</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L131">source</a></div>

```lean
def lookup (s : String) : Option U
```

Look a symbol up, exactly as spelled.

</div>

<div class="lean-decl" id="Esm.Units.sym">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.sym" title="Esm.Units.sym"><code>sym</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L134">source</a></div>

```lean
def sym (s : String) : U
```

The table entry for a key (dimensionless 1 for a non-key; used only on keys).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.lookup_isSome_iff">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.lookup_isSome_iff" title="Esm.Units.lookup_isSome_iff"><code>lookup_isSome_iff</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean#L148-L149">source</a></div>

```lean
theorem lookup_isSome_iff (s : String) : (lookup s).isSome ↔ s ∈ keys
```

The table is flat: a symbol resolves iff it is a key exactly as spelled.

</div>

<p class="lean-meta">This module also proves 1 lemma without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/Registry.lean">the source</a>.</p>
