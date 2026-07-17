# Out-of-line expression templates — benchmark stack

RFC `docs/content/rfcs/out-of-line-expression-templates.md` §12 requires the
measurement stack to land in-repo so the reference-preserving factoring is
reproducible by anyone. This directory holds that stack.

## Fixture

`transport_3axis_7cubed.esm` — a 7×7×7 single-tracer transport whose RHS is
`-(Dx(q)+Dy(q)+Dz(q))`. Each spatial derivative is lowered by a `match` rule to
a per-axis `makearray` with three boundary-class regions (two one-sided faces +
a centered interior); every region value is an `apply_expression_template`
reference to a shared per-class stencil template (`sx_int`, `sx_lo`, `sx_hi`,
…). Grid size is a `metaparameters` integer `N` (default 7), so the same file
serves other resolutions by binding `N`. No external data.

Under **Option A** (expand-at-load) the region bodies inline into the makearrays;
under **Option B** the references survive and each stencil body is a single
factored declaration in the emitted registry.

## Measure

```
julia --project=pkg/EarthSciAST.jl scripts/bench-out-of-line.jl
```

Reports two things:

1. **Representation (load-time)** — distinct AST objects in the equation RHS
   under the Option-A `Expand` image vs the Option-B reference-preserving load.
   This is the factoring the compile-once optimization builds on. Measured on
   this fixture: RHS **181** distinct objects (Expand) vs **79** (references).

2. **Build (tree-walk)** — `_build_branch_template` spine-template count and
   `_compile` node-lowering count (the RFC's headline metrics), plus wall-clock,
   via the build-time counters (`src/tree_walk/build_helpers.jl`, off by
   default). Two columns: the default path vs `ESS_TEMPLATE_REF_DISABLE=1`
   (Expand-at-build).

## Status of the numbers

`ESS_TEMPLATE_REF_DISABLE` genuinely switches strategies: **default** carries the
surviving references through load and flatten (`expand_refs=false`) into the
tree-walk build, where the sound per-node `Expand` fallback expands them against
the merged `template_registry`; **`=1`** Expands at load up front. Gate (d)
(`test/out_of_line_templates_test.jl`) asserts the two build the **bit-identical**
`f!` (the RHS everywhere), proving the fallback equivalent.

The build columns are therefore **equal**: the sound fallback Expands the
references before `_compile`, so it does the same node-lowering as the Expand
path — no speedup, by design. The actual compile-once SHARING (one compiled body
per `(template, key)`, emitting a call/indirection — the RFC's ~100–200×) is
**step (c)**, explicitly out of scope here. The representation column
(181 → 79 RHS objects) is the honest in-repo demonstration of the factoring the
compile-once step would exploit; the build counters are the instrument it moves.

This fixture's whole-array RHS also does not, on its own, reproduce the 7×7×7
per-cell branch-template cross-product (that arises from the pointwise-lift of a
per-cell reaction-advection RHS); it is the committed reference-heavy §12 stack
and the substrate the compile-once follow-up measures against.
