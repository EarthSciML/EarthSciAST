---
title: "The identities §4.8.1 states, checked against the table"
type: lean
lean_module: "Esm.Units.Identities"
weight: 72
---

<p class="lean-meta">Lean module <code>Esm.Units.Identities</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean"><code>formal/Esm/Units/Identities.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-units-laws"><code>Esm.Units.Laws</code></a>, <code>Esm.Float64</code></p>

Every entry of [`table`](/generated/document-formats/esm-units-registry#Esm.Units.table) is built from the scale the spec states for it, so each
identity below is a genuine check that the stated scales are consistent with
the stated relations, exactly (rational arithmetic on exponent maps).

<div class="lean-decl" id="Esm.Units.num">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.num" title="Esm.Units.num"><code>num</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L17">source</a></div>

```lean
def num (q : ℚ) : U
```

A dimensionless exact rational scale.

</div>

### Table entries, by key (each is `rfl`: the table says so)

### The stated identities

<div class="lean-decl lean-theorem" id="Esm.Units.mi_eq_5280_ft">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.mi_eq_5280_ft" title="Esm.Units.mi_eq_5280_ft"><code>mi_eq_5280_ft</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L90-L93">source</a></div>

```lean
theorem mi_eq_5280_ft : (sym "mi").Agree ((num 5280).mul (sym "ft"))
```

`mi` is exactly `5280 × ft` (§4.8.1 customary table).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.mi_factorization">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.mi_factorization" title="Esm.Units.mi_factorization"><code>mi_factorization</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L97-L141">source</a></div>

```lean
theorem mi_factorization :
    (sym "mi").scale.exp = Scale.exp
      [(.prime ⟨2, Nat.prime_two⟩, 4), (.prime ⟨3, Nat.prime_three⟩, 2),
       (.prime ⟨5, Nat.prime_five⟩, -3), (.prime ⟨11, by norm_num⟩, 1),
       (.prime ⟨127, by norm_num⟩, 1)]
```

`mi` is `201168/125` m `= 2⁴ · 3² · 5⁻³ · 11 · 127` m, the factorization the
spec writes out.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.lb_eq_short_ton_div_2000">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.lb_eq_short_ton_div_2000" title="Esm.Units.lb_eq_short_ton_div_2000"><code>lb_eq_short_ton_div_2000</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L144-L147">source</a></div>

```lean
theorem lb_eq_short_ton_div_2000 : (sym "lb").Agree ((sym "short_ton").div (num 2000))
```

`lb` is exactly `short_ton / 2000`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.short_ton_eq_ug">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.short_ton_eq_ug" title="Esm.Units.short_ton_eq_ug"><code>short_ton_eq_ug</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L150-L153">source</a></div>

```lean
theorem short_ton_eq_ug : (sym "short_ton").Agree ((num 907184740000).mul (sym "ug"))
```

`short_ton` is exactly `907184740000 ug` — InMAP's conversion constant.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.torr_eq_atm_div_760">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.torr_eq_atm_div_760" title="Esm.Units.torr_eq_atm_div_760"><code>torr_eq_atm_div_760</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L156-L162">source</a></div>

```lean
theorem torr_eq_atm_div_760 :
    (sym "Torr").Agree ((sym "atm").div (num 760)) ∧
    (sym "Torr").Agree (mk pressure (20265 / 152))
```

`Torr` is exactly `atm / 760`, i.e. `20265/152` Pa.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.torr_ne_mmHg">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.torr_ne_mmHg" title="Esm.Units.torr_ne_mmHg"><code>torr_ne_mmHg</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L165-L169">source</a></div>

```lean
theorem torr_ne_mmHg : ¬ (sym "Torr").Agree (sym "mmHg")
```

`Torr` is NOT `mmHg`: same dimension, different exact scale.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.inHg_eq_25_4_mmHg">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.inHg_eq_25_4_mmHg" title="Esm.Units.inHg_eq_25_4_mmHg"><code>inHg_eq_25_4_mmHg</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L172-L175">source</a></div>

```lean
theorem inHg_eq_25_4_mmHg : (sym "inHg").Agree ((num 25.4).mul (sym "mmHg"))
```

`inHg` is exactly `25.4 × mmHg`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.psi_eq_lbf_per_in2">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.psi_eq_lbf_per_in2" title="Esm.Units.psi_eq_lbf_per_in2"><code>psi_eq_lbf_per_in2</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L178-L193">source</a></div>

```lean
theorem psi_eq_lbf_per_in2 :
    (sym "psi").Agree
      ((((num 9.80665).mul (sym "lb")).mul ((sym "m").mul ((sym "s").rpow (-2)))).div
        (((num 0.0254).mul (sym "m")).rpow 2))
```

`psi` is lbf/in²: `lb × 9.80665 m/s²` over `(0.0254 m)²`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.hp_eq_550_ft_lbf_per_s">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.hp_eq_550_ft_lbf_per_s" title="Esm.Units.hp_eq_550_ft_lbf_per_s"><code>hp_eq_550_ft_lbf_per_s</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L196-L211">source</a></div>

```lean
theorem hp_eq_550_ft_lbf_per_s :
    (sym "hp").Agree
      (((((num 550).mul (sym "ft")).mul (sym "lb")).mul (num 9.80665)).mul
        ((sym "m").mul ((sym "s").rpow (-3))))
```

`hp` is `550 ft·lbf/s = 550 × ft × lb × 9.80665` W, exactly.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.yr_julian">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.yr_julian" title="Esm.Units.yr_julian"><code>yr_julian</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L214-L221">source</a></div>

```lean
theorem yr_julian :
    sym "yr" = sym "year" ∧
    (sym "yr").Agree (mk time 31557600) ∧
    (sym "yr").Agree ((num 365.25).mul (sym "day"))
```

`yr` = `year` = the Julian year, `31557600 s` = `365.25 day`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.deg_eq_pi_div_180">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.deg_eq_pi_div_180" title="Esm.Units.deg_eq_pi_div_180"><code>deg_eq_pi_div_180</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L224-L230">source</a></div>

```lean
theorem deg_eq_pi_div_180 :
    (sym "deg").dim = angle ∧ Scale.real (sym "deg").scale = Real.pi / 180
```

`deg` is `π/180 rad`: dimension `rad¹`, real scale `π / 180`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.sr_eq_rad_sq">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.sr_eq_rad_sq" title="Esm.Units.sr_eq_rad_sq"><code>sr_eq_rad_sq</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L233-L237">source</a></div>

```lean
theorem sr_eq_rad_sq : (sym "sr").Agree ((sym "rad").rpow 2)
```

`sr = rad²`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.dimensionless_entries">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.dimensionless_entries" title="Esm.Units.dimensionless_entries"><code>dimensionless_entries</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L240-L247">source</a></div>

```lean
theorem dimensionless_entries :
    ∀ k ∈ ["ppm", "ppb", "ppt", "ppmv", "ppbv", "pptv", "%", "percent", "psu",
      "molec", "molecule", "individuals", "vehicles", "units", "count",
      "", "1", "dimensionless"], (sym k).dim = 0
```

The mixing ratios, fractions and counts are dimensionless.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.percent_and_counts">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.percent_and_counts" title="Esm.Units.percent_and_counts"><code>percent_and_counts</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L251-L261">source</a></div>

```lean
theorem percent_and_counts :
    (sym "%").Agree (num 0.01) ∧ (sym "percent").Agree (num 0.01) ∧
    ∀ k ∈ ["molec", "molecule", "individuals", "vehicles", "units", "count", "psu"],
      (sym k).Agree U.one
```

`%` (and `percent`) is dimensionless at scale exactly `0.01`; the counts are
dimensionless at scale 1 (not `mol`, not `cd`).

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.C_is_coulomb">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.C_is_coulomb" title="Esm.Units.C_is_coulomb"><code>C_is_coulomb</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L264-L268">source</a></div>

```lean
theorem C_is_coulomb : (sym "C").Agree ((sym "A").mul (sym "s")) ∧ (sym "C").dim .K = 0
```

`C` is the coulomb, `A·s` — no temperature component.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.dobson">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.dobson" title="Esm.Units.dobson"><code>dobson</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L271-L278">source</a></div>

```lean
theorem dobson :
    (sym "DU").Agree (mk ((-2 : ℚ) • len) 2.6867e20) ∧ sym "Dobson" = sym "DU" ∧
    Scale.real (sym "DU").scale = 2.6867e20
```

`DU` and `Dobson` have dimension `m⁻²` and scale exactly `2.6867e20`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.customary_scales">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.customary_scales" title="Esm.Units.customary_scales"><code>customary_scales</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L282-L295">source</a></div>

```lean
theorem customary_scales :
    Scale.real (sym "ft").scale = 0.3048 ∧ Scale.real (sym "mi").scale = 1609.344 ∧
    Scale.real (sym "lb").scale = 0.45359237 ∧
    Scale.real (sym "hp").scale = 550 * 0.3048 * 0.45359237 * 9.80665 ∧
    Scale.real (sym "gal").scale = 0.003785411784 ∧
    Scale.real (sym "inHg").scale = 3386.388640341 ∧
    Scale.real (sym "Torr").scale = 101325 / 760 ∧
    Scale.real (sym "psi").scale = 0.45359237 * 9.80665 / 0.0254 ^ 2 ∧
    Scale.real (sym "degF").scale = 5 / 9 ∧
    Scale.real (sym "BTU").scale = 1055.05585262
```

The pinned customary scales (§4.8.1 "A binding MUST use the values above"):
each entry's real scale is the stated exact value.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.mi_per_h">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.mi_per_h" title="Esm.Units.mi_per_h"><code>mi_per_h</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L298-L300">source</a></div>

```lean
theorem mi_per_h : ((sym "mi").div (sym "h")).Agree (mk (len - time) 0.44704)
```

`mi/h` is exactly `0.44704 m/s`, the constant MOVES's SQL writes.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.gal_eq_231_in3">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.gal_eq_231_in3" title="Esm.Units.gal_eq_231_in3"><code>gal_eq_231_in3</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L303-L317">source</a></div>

```lean
theorem gal_eq_231_in3 :
    (sym "gal").Agree ((num 231).mul (((num 0.0254).mul (sym "m")).rpow 3))
```

`gal` is 231 in³ with the international inch `0.0254 m`.

</div>

### `hp` in binary64 (§4.8.1: "folded LEFT TO RIGHT")

<div class="lean-decl lean-theorem" id="Esm.Units.hp_fold_left_to_right">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.hp_fold_left_to_right" title="Esm.Units.hp_fold_left_to_right"><code>hp_fold_left_to_right</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L325-L329">source</a></div>

```lean
theorem hp_fold_left_to_right :
    fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 0.45359237)) (rn 9.80665)
      = rn (745.6998715822702 : ℚ) ∧
    rn (745.6998715822702 : ℚ) = rn (550 * 0.3048 * 0.45359237 * 9.80665 : ℚ)
```

The left-to-right binary64 fold `((550 × ft) × lb) × 9.80665`, from the
doubles nearest each literal, lands on the double nearest `745.6998715822702`,
which is also the double nearest the exact product.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.hp_fold_order_matters">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.hp_fold_order_matters" title="Esm.Units.hp_fold_order_matters"><code>hp_fold_order_matters</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean#L334-L338">source</a></div>

```lean
theorem hp_fold_order_matters :
    fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 9.80665)) (rn 0.45359237)
      ≠ fmul (fmul (fmul (rn (550 : ℚ)) (rn 0.3048)) (rn 0.45359237)) (rn 9.80665) ∧
    rn (550 * 0.3048 * 0.45359237 * 9.80665 : ℚ) ≠ 550 * 0.3048 * 0.45359237 * 9.80665
```

The fold order matters: `((550 × ft) × 9.80665) × lb` lands on a different
double, and the exact product is not a double.

</div>

<p class="lean-meta">This module also proves 36 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Units/Identities.lean">the source</a>.</p>
