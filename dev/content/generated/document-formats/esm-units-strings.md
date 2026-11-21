---
title: "Whole unit strings, end to end (esm-spec §4.8.2)"
type: lean
lean_module: "Esm.Units.Strings"
weight: 65
---

<p class="lean-meta">Lean module <code>Esm.Units.Strings</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean"><code>formal/Esm/Units/Strings.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-units-identities"><code>Esm.Units.Identities</code></a>, <a href="/generated/document-formats/esm-units-grammarlaws"><code>Esm.Units.GrammarLaws</code></a></p>

Facts about [`resolve`](/generated/document-formats/esm-units-grammar#Esm.Units.resolve) on specific strings the spec names, and about the
scaling-factor diagnostic text. The parse step is checked by the kernel; the
table lookup and composition by `rfl`.

<div class="lean-decl lean-theorem" id="Esm.Units.resolveChars_eq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.resolveChars_eq" title="Esm.Units.resolveChars_eq"><code>resolveChars_eq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean#L15-L21">source</a></div>

```lean
theorem resolveChars_eq (cs : List Char) (h : cs ≠ []) :
    resolveChars cs = (lex (normalize cs) >>= parse) >>= UExpr.eval
```

Resolution of a nonempty string: normalise, lex, parse, then evaluate.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.percent_resolves">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.percent_resolves" title="Esm.Units.percent_resolves"><code>percent_resolves</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean#L25-L35">source</a></div>

```lean
theorem percent_resolves :
    (∃ u, resolve "%" = .ok u ∧ u.Agree (num 0.01)) ∧
    (∃ u, resolve "%/h" = .ok u ∧ u.Agree (mk (Dims.dimless - Dims.time) (1 / 360000)))
```

`%` is a symbol token (§4.8.2): `"%"` resolves to dimensionless scale 0.01, and
`"%/h"` to `h⁻¹` at scale `1/360000`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.m_per_s_pow_scaling_factor">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.m_per_s_pow_scaling_factor" title="Esm.Units.m_per_s_pow_scaling_factor"><code>m_per_s_pow_scaling_factor</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean#L38-L42">source</a></div>

```lean
theorem m_per_s_pow_scaling_factor :
    resolve "(m/s)^-1/3" = .error (.scalingFactor "3")
```

`"(m/s)^-1/3"` reads as `((m/s)^-1)/3`, and the `3` is a scaling factor.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.g_per_hp_hr_rejected">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.g_per_hp_hr_rejected" title="Esm.Units.g_per_hp_hr_rejected"><code>g_per_hp_hr_rejected</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean#L45-L51">source</a></div>

```lean
theorem g_per_hp_hr_rejected :
    resolve "g/hp-hr" =
      .error (.syntax "'-' is not an operator in a unit string (a negative exponent is ^-n)")
```

MOVES's `"g/hp-hr"` does not resolve: `-` is not an operator.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.scaling_factor_message">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.scaling_factor_message" title="Esm.Units.scaling_factor_message"><code>scaling_factor_message</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Units/Strings.lean#L55-L71">source</a></div>

```lean
theorem scaling_factor_message :
    ∀ lit : String,
      "scaling factor".toList <:+: (Err.scalingFactor lit).message.toList ∧
      "^(p/q)".toList <:+: (Err.scalingFactor lit).message.toList
```

The scaling-factor diagnostic, for every literal, says that the number is a
scaling factor and that a rational exponent is spelled `^(p/q)`.

</div>
