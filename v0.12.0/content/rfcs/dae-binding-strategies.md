# DAE binding strategies (RFC §12 companion — gt-q7sh)

This document records each binding's **strategy** for satisfying the
RFC §12 DAE binding contract. It is normative for binding authors and
informative for model authors who want to know what will happen when
their `.esm` contains algebraic equations alongside differential ones.

RFC §12 requires every binding that implements `discretize()` to
either (a) hand a mixed DAE to a DAE assembler, or (b) abort with
`E_NO_DAE_SUPPORT`. The binding's documentation MUST name its DAE
assembler; this file is that documentation, centralized.

## Strategy per binding

| Binding | Strategy | Assembler | Index reduction | Disable knob |
|---|---|---|---|---|
| **Julia** (`EarthSciAST.jl`) | **Direct DAE hand-off.** `discretize(esm; dae_support=true)` is the default; when the output is a DAE, `metadata.system_class` is stamped `"dae"` and the caller's MTK export path (`mtk2esm`'s inverse, `MockMTKSystem`, or a user-supplied `System` constructor) receives a mixed equation set that ModelingToolkit.jl handles natively. No index reduction is attempted; MTK performs any required structural simplification. | ModelingToolkit.jl (`System` / `ODESystem` with algebraic equations; `DAEProblem` on solve) | Delegated to MTK (`structural_simplify`) at solve time. | `discretize(esm; dae_support=false)` or env `ESM_DAE_SUPPORT=0`. |
| **Rust** (`earthsci-ast-rs`) | **Trivial-DAE preprocessing.** `discretize(esm, DiscretizeOptions { dae_support: true })` runs a symbolic preprocessor that factors out algebraic equations of the form `var ~ expr` where `var` does not appear in `expr` (acyclic, transitively closable). The algorithm iteratively picks a factorable algebraic equation, substitutes `var -> expr` into every remaining equation, and drops the factored equation; this continues to a fixed point. If residual algebraic equations remain (cyclic, implicit like `x^2 + y^2 = 1`, or non-bare-LHS), the binding aborts with `E_NONTRIVIAL_DAE`. Rust has no in-ecosystem DAE assembler and the downstream ODE simulator ([`diffsol`](https://github.com/martinjrobins/diffsol)) only accepts pure ODE systems; full DAE support requires the Julia binding. Metadata on success: `metadata.system_class = "ode"` (factored output is a pure ODE), `metadata.dae_info.algebraic_equation_count = 0`, and `metadata.dae_info.factored_equation_count = <count>` recording how many observed-style equations were eliminated. | diffsol (ODE-only; DAE path is not used, see strategy notes). | Not applicable — the preprocessor rewrites trivial DAEs to ODEs; non-trivial DAEs are rejected before reaching the integrator. | Binding flag `DiscretizeOptions::dae_support = false` or env `ESM_DAE_SUPPORT=0` aborts with `E_NO_DAE_SUPPORT` on any algebraic equation (trivial or not). |
| **Python** (`earthsci_ast`) | **Trivial-factor + error otherwise.** `discretize()` classifies each equation as differential vs algebraic (same rule as Julia), then attempts to eliminate every algebraic equation whose LHS is a bare variable name and whose RHS does not reference that variable (transitively, via a topological substitution pass). Factored equations are substituted into downstream equations and removed; the output is a pure-ODE system (`metadata.system_class = "ode"`, `algebraic_equation_count = 0`). If any algebraic equation remains — because its LHS is an operator node (e.g. the unit-circle constraint `x²+y² = 1`), because the LHS variable appears in its own RHS, or because a cycle exists among observed equations — `discretize()` raises `DiscretizationError` with code `E_NONTRIVIAL_DAE`. The error message names each residual equation and points to the Julia binding for full DAE support. A future release may delegate the full-DAE path to SUNDIALS/IDA via scikits.odes or diffrax. | Deferred (trivial-factor only). | Python-specific kwarg `discretize(esm, dae_support=False)` or env `ESM_DAE_SUPPORT=0` — either bypasses factoring and emits `E_NO_DAE_SUPPORT` on any algebraic equation, matching Julia's error-path semantics. |
| **Go** (`earthsci-ast-go`) | **Trivial-factor.** `ApplyDAEContract(*EsmFile)` symbolically substitutes every algebraic equation of the form `y ~ f(...)` (where `y` is a plain variable and `f` does not reference `y`) into downstream equations, removing the factored equation from the model. Factoring runs to a fixed point so transitive chains `z ~ g(y); y ~ h(x)` fold into pure-ODE form. If any algebraic equations remain after factoring (cyclic observed equations or genuine constraints like `x^2 + y^2 = 1`), the binding aborts with `E_NONTRIVIAL_DAE`; the error names each residual equation and points the author at the Julia binding. Go has no in-ecosystem DAE assembler, so non-trivial DAEs require a different binding. | None (trivial cases reduce to ODE; non-trivial cases abort). | None — the DAE contract is informational-only in Go: pure-ODE output after factoring classifies as `"ode"`, otherwise the binding errors. |
| **TypeScript** (`@earthsciml/ast`) | **Stubbed.** v0.2.0 always emits `E_NO_DAE_SUPPORT` on mixed-DAE input. No native DAE assembler in the JS/TS ecosystem; expected to remain a pure-ODE binding unless a WASM DAE solver is vendored. | Deferred (TBD). | Env `ESM_DAE_SUPPORT=0`. |

## What counts as "algebraic"

For the purpose of this contract, an equation in a discretized model
is **algebraic** iff at least one of the following holds:

1. It carries a `produces: "algebraic"` or `algebraic: true` marker on
   the equation object (the output form of a rule with
   `produces: algebraic`, per RFC §9.4).
2. Its LHS is not a time derivative `D(x, wrt=<indep>)`, where
   `<indep>` is the enclosing model's domain's `independent_variable`
   (default `"t"`). This covers authored observed equations and
   authored constraints of the form `0 = g(x)`.

This is deliberately inclusive. A binding that claims ODE-only
support and runs the system through an ODE-only integrator would
drop an observed-equation LHS just as surely as a true DAE
constraint; the contract "hand to a DAE assembler, or abort" applies
in either case.

## Stamped output metadata (normative)

When `discretize()` succeeds with DAE support enabled, the output
metadata MUST carry:

- `metadata.system_class` — `"ode"` if no algebraic equations were
  found anywhere in the output, else `"dae"`.
- `metadata.dae_info.algebraic_equation_count` — integer, total over
  all models.
- `metadata.dae_info.per_model` — map of `<model name>` →
  `<algebraic equation count>`.

The conformance harness reads these fields from
`tests/conformance/discretization/dae_missing/` fixtures.

## Error message requirements

When `discretize()` aborts with `E_NO_DAE_SUPPORT`, the error message
MUST contain:

- The exact code string `E_NO_DAE_SUPPORT` (upper-case, ASCII, one
  underscore between each word).
- At least one `<model>.equations[<i>]` path naming an algebraic
  equation.
- An identification of the binding's disable knob (e.g.,
  `dae_support=false` or `ESM_DAE_SUPPORT=0`) so the author knows how
  to enable DAE support when available.

### Rust-specific: `E_NONTRIVIAL_DAE`

The Rust binding's **trivial-DAE preprocessing** strategy introduces a
second error code: `E_NONTRIVIAL_DAE`. Raised when `dae_support` is
enabled but the preprocessor cannot eliminate every algebraic equation
by acyclic substitution. The message MUST contain:

- The exact code string `E_NONTRIVIAL_DAE`.
- Every residual algebraic-equation path (`<model>.equations[<i>]`)
  that could not be factored — users need to see all of them to
  understand the obstruction.
- A pointer to the Julia binding (`EarthSciAST.jl`) as the
  currently full-DAE-capable implementation, and a reference to RFC §12
  and `docs/rfcs/dae-binding-strategies.md`.

Other bindings do not emit `E_NONTRIVIAL_DAE`: they either factor
(Julia — via MTK's `structural_simplify` at solve time, which handles
this case without a user-facing error) or simply emit `E_NO_DAE_SUPPORT`
on any algebraic equation (Python, Go, TypeScript stubs).

See `tests/conformance/discretization/dae_missing/README.md` for the
exact conformance harness expectations.

### Trivial-factor bindings: `E_NONTRIVIAL_DAE`

Bindings that use the trivial-factor strategy (Python, Go) emit a
second error code, `E_NONTRIVIAL_DAE`, when an algebraic equation
cannot be factored away (see the corresponding rows in the strategy
table above). The message MUST contain:

- The exact code string `E_NONTRIVIAL_DAE`.
- A `models.<name>.equations[<i>]` path for each residual equation.
- A pointer to the Julia binding as the current full-DAE-capable
  implementation.
- A citation of RFC §12.

This code is specific to trivial-factor bindings — bindings that
either (a) fully support DAEs or (b) stub as ODE-only do not need to
emit it.
