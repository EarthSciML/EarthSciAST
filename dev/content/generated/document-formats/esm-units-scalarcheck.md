---
title: "Unit preservation for scalar expressions (esm-spec §4.8.3–4.8.4)"
type: lean
lean_module: "Esm.Units.ScalarCheck"
weight: 77
---

<p class="lean-meta">Lean module <code>Esm.Units.ScalarCheck</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean"><code>formal/Esm/Units/ScalarCheck.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <code>Esm.Expr.ArrayConformance</code>, <a href="/generated/document-formats/esm-units-laws"><code>Esm.Units.Laws</code></a></p>

These rules consume the unit verdicts of their child expressions. A successful
verdict can name a resolved unit or report an undeterminable one. Invalid
declarations and mismatches remain errors. A scalar expression's evaluator
does not need its unit annotation, so the verdicts are passed separately from
the expression AST.

<div class="lean-decl" id="Esm.Units.ScalarCheck.PureAngle">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.PureAngle" title="Esm.Units.ScalarCheck.PureAngle"><code>PureAngle</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L24">source</a></div>

```lean
def PureAngle (d : Dim) : Prop
```

A nonzero power of the plane-angle axis, with all other axes absent.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.Compatible">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.Compatible" title="Esm.Units.ScalarCheck.Compatible"><code>Compatible</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L31-L33">source</a></div>

```lean
def Compatible (u v : U) : Prop
```

The exact unit comparison for extrema and `ifelse`. A pure angle can
agree with a pure number at the same scale. Comparing two angular operands
still requires the same dimension.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.chooseUnit">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.chooseUnit" title="Esm.Units.ScalarCheck.chooseUnit"><code>chooseUnit</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L41-L44">source</a></div>

```lean
def chooseUnit (known : List U) : Option U
```

When a pure number and a pure angle meet, select the pure number's unit.
Otherwise retain the first determinable operand's unit.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.checkKnown">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checkKnown" title="Esm.Units.ScalarCheck.checkKnown"><code>checkKnown</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L59-L61">source</a></div>

```lean
def checkKnown (known : List U) : Verdict
```

Check every pair of determinable inputs. This also compares two angle
operands when a pure number appears between them.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.checkExtrema">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checkExtrema" title="Esm.Units.ScalarCheck.checkExtrema"><code>checkExtrema</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L64-L66">source</a></div>

```lean
def checkExtrema (operands : List Verdict) : Verdict
```

The `min`/`max` rule and the value-operand part of the `ifelse` rule.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.checkIfelse">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checkIfelse" title="Esm.Units.ScalarCheck.checkIfelse"><code>checkIfelse</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L69-L71">source</a></div>

```lean
def checkIfelse (condition yes no : Verdict) : Verdict
```

Check the condition for errors but derive the result from both branches.

</div>

## Sound rescaling on the exact scalar evaluator

<div class="lean-decl" id="Esm.Units.ScalarCheck.scaleValue">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.scaleValue" title="Esm.Units.ScalarCheck.scaleValue"><code>scaleValue</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L129-L130">source</a></div>

```lean
noncomputable def scaleValue (s : ℝ) (v : Num) : Num
```

Multiply a finite value by a scale and preserve a NaN.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.ScalarCheck.checked_extremum_scaling">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checked_extremum_scaling" title="Esm.Units.ScalarCheck.checked_extremum_scaling"><code>checked_extremum_scaling</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L200-L217">source</a></div>

```lean
theorem checked_extremum_scaling (maximum : Bool) (a b : U × Num)
    (rest : List (U × Num)) (result : U)
    (h : checkKnown ((a :: b :: rest).map Prod.fst) = .ok (some result)) :
    applyStrict (if maximum then .max else .min)
        ((a :: b :: rest).map (fun x => .num (scaleValue x.1.scale.real x.2))) =
      (applyStrict (if maximum then .max else .min)
        ((a :: b :: rest).map (fun x => .num x.2))).map (scaleValue result.scale.real)
```

With a determinable unit on every operand, the checked `min` or `max`
commutes with conversion from its authored units to their canonical scales.
Undeterminable operands need a separate semantic premise about their numbers.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.ScalarCheck.checked_ifelse_scaling">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checked_ifelse_scaling" title="Esm.Units.ScalarCheck.checked_ifelse_scaling"><code>checked_ifelse_scaling</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L230-L244">source</a></div>

```lean
theorem checked_ifelse_scaling (condition : Verdict) (c : Num) (cs : ℝ) (hc : 0 < cs)
    (yes no : U × Num) (result : U)
    (h : checkIfelse condition (.ok (some yes.1)) (.ok (some no.1)) = .ok (some result)) :
    (if truthy (scaleValue cs c) then scaleValue yes.1.scale.real yes.2
      else scaleValue no.1.scale.real no.2) =
    scaleValue result.scale.real (if truthy c then yes.2 else no.2)
```

The `ifelse` truth test selects the same branch under a positive condition
rescaling. Given the evaluated branch values in determinable units, converting
the selected branch and converting the result give the same value.

</div>

## Compositional soundness for resolved scalar arithmetic

This fragment uses the same numeric expression AST and evaluator as the
conformance adapter. Its inputs carry their exact declared units. Inference
here requires every subexpression to have a determinable unit. The neutral
literal rule permits a broader set of expressions in a document, but does
not assign a conversion scale to a bare number (§4.8.4–4.8.6).

<div class="lean-decl" id="Esm.Units.ScalarCheck.checkPure">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checkPure" title="Esm.Units.ScalarCheck.checkPure"><code>checkPure</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L280-L281">source</a></div>

```lean
def checkPure (u : U) : Verdict
```

Strict transcendentals admit a scale-one pure number, including the
pure-angle exception of §4.8.3.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.checkAtan2">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checkAtan2" title="Esm.Units.ScalarCheck.checkAtan2"><code>checkAtan2</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L328-L329">source</a></div>

```lean
def checkAtan2 (y x : U) : Verdict
```

The two coordinates passed to `atan2` must have the same dimension and
exact scale (§4.8.3).

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.rationalExponent">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.rationalExponent" title="Esm.Units.ScalarCheck.rationalExponent"><code>rationalExponent</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L342">source</a></div>

```lean
def rationalExponent (q : ℚ) : Ast
```

A folded rational exponent is written as the exact numerator divided by
its nonzero denominator, both integer literals.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.ScalarTerm">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.ScalarTerm" title="Esm.Units.ScalarCheck.ScalarTerm"><code>ScalarTerm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L346-L351">source</a></div>

```lean
inductive ScalarTerm where
  | var (name : String)
  | unary (op : Unary) (arg : ScalarTerm)
  | binary (op : Binary) (left right : ScalarTerm)
  | power (base : ScalarTerm) (exponent : ℚ)
  | ifelse (condition yes no : ScalarTerm)
```

A scalar expression over declared inputs and the operator forms handled by
the exact unit rescaling theorem. Conditions can carry a unit of their own.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.ScalarTerm.check">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.ScalarTerm.check" title="Esm.Units.ScalarCheck.ScalarTerm.check"><code>ScalarTerm.check</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L362-L381">source</a></div>

```lean
def ScalarTerm.check (units : List (String × U)) : ScalarTerm → Verdict
```

The checker for the resolved fragment. An absent declaration yields an
undeterminable unit and keeps the tree outside the rescaling guarantee.

</div>

<div class="lean-decl" id="Esm.Units.ScalarCheck.ScalarBindings">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.ScalarBindings" title="Esm.Units.ScalarCheck.ScalarBindings"><code>ScalarBindings</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L385">source</a></div>

```lean
abbrev ScalarBindings
```

Declarations pairing each unit with its authored numeric input. Both
numeric environments use the same names and shadowing as the checker.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.ScalarCheck.checked_scalar_rescaling">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.ScalarCheck.checked_scalar_rescaling" title="Esm.Units.ScalarCheck.checked_scalar_rescaling"><code>checked_scalar_rescaling</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean#L641-L735">source</a></div>

```lean
theorem checked_scalar_rescaling (bindings : ScalarBindings) (term : ScalarTerm) (result : U)
    (checked : term.check (scalarUnits bindings) = .ok (some result)) :
    ∃ value : Num, eval term.ast (scalarInputs bindings) = .ok (.num value) ∧
      eval term.ast (canonicalInputs bindings) = .ok (.num (scaleValue result.scale.real value))
```

For any expression in the resolved scalar fragment, checking fixes the
conversion scale of the result. Converting all of its declared inputs before
evaluation gives exactly the canonical value of the authored computation.

</div>

A bare additive literal can pass dimensional checking without specifying
how that literal must change when the surrounding expression is converted.

Checker controls. These compute the verdicts with the exact scale comparison.

<p class="lean-meta">This module also proves 43 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Units/ScalarCheck.lean">the source</a>.</p>
