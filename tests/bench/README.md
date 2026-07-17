# Out-of-line expression templates — benchmark stack

RFC `docs/content/rfcs/out-of-line-expression-templates.md` §12 requires the
measurement stack to land in-repo so the reference-preserving factoring is
reproducible by anyone. This directory holds that stack.

## Fixtures

`transport_3axis_7cubed.esm` — a 7×7×7 single-tracer transport whose RHS is
`-(Dx(q)+Dy(q)+Dz(q))`. Each spatial derivative is lowered by a `match` rule to
a per-axis `makearray` with three boundary-class regions (two one-sided faces +
a centered interior); every region value is an `apply_expression_template`
reference to a shared per-class stencil template (`sx_int`, `sx_lo`, `sx_hi`,
…). Grid size is a `metaparameters` integer `N` (default 7), so the same file
serves other resolutions by binding `N`. No external data.

Under **Option A** (expand-at-load) the region bodies inline into the makearrays;
under **Option B** the references survive and each stencil body is a single
factored declaration in the emitted registry. Its one-sided faces are RANK-2
aggregates inside a rank-3 makearray, which the affine/symbolic stencil paths
decline ("reduced-rank region value") — so this fixture measures the
REPRESENTATION factoring and pins the per-cell fallback chain, not the
compile-once build.

`transport_3axis_7cubed_fullrank.esm` — the compile-once measurement fixture
(RFC step c). Same equation shape, but each axis's `match` rule lowers to a
makearray with FIVE full-rank boundary-class regions (two one-sided faces, two
near-face centered classes, a wide-stencil interior), and every region body is a
rank-3 aggregate. The affine box processor therefore fires, and the per-cell
branch keys form the genuine cross-product: a fused (expanded) build compiles
one spine per `(x-class, y-class, z-class)` = **5×5×5 = 125** branch keys, while
the compile-once tier compiles **5+5+5 = 15** template-body variants plus 125
tiny parent spines that call them as sub-kernels.

## Measure

```
julia --project=pkg/EarthSciAST.jl scripts/bench-out-of-line.jl
```

Reports:

1. **Representation (load-time)** — distinct AST objects in the equation RHS
   under the Option-A `Expand` image vs the Option-B reference-preserving load.
   Measured on `transport_3axis_7cubed.esm`: RHS **181** distinct objects
   (Expand) vs **79** (references).

2. **Build (tree-walk)** — `_build_branch_template` spine-template count,
   compiled template-body variant count, and `_compile` node-lowering count
   (the RFC's headline metrics), plus wall-clock, via the build-time counters
   (`src/tree_walk/build_helpers.jl`, off by default). Both fixtures, two
   columns each: the default compile-once path vs `ESS_TEMPLATE_REF_DISABLE=1`
   (Expand-at-load → fused build).

## Status of the numbers

The compile-once tier (RFC §5/§7.7 "compile references natively") is
implemented in the Julia affine stencil build: each surviving reference's body
is compiled once per (use site, region class) and called at runtime as a
sub-kernel (`_NK_SUBCALL`), with the body's lane recipes re-based into the
parent's recipe vector so grouping, ghost keys, and box cuts are exactly the
fused ones. Measured on `transport_3axis_7cubed_fullrank.esm`:

| | branch templates | body variants | node-lowerings |
|---|---|---|---|
| compile-once (default) | 125 (tiny parents) | **15** | **331** |
| `ESS_TEMPLATE_REF_DISABLE=1` (fused) | 125 (full spines) | 0 | **2,275** |

**5+5+5 replaces 5×5×5.** The node-lowering ratio here (~7×) is bounded by this
fixture's small bodies (~25 nodes); the ratio scales with body size / parent
size. On the real ESD PPM + SuperFast pointwise-lift stack (the reseact.esm
probe6 gate, 2 species on the 7×7×7 grid — outside this repo, not
CI-reproducible here), the same build measured **33,881,439** fused
node-lowerings vs **695,139** with the tier (48.7× fewer; 57 outermost body
variants), with bit-identical solutions. Compile-once boundaries are the
OUTERMOST expansion roots only — per-nested-root boundaries exploded 8,297 tiny
variants on ESD's deeply factored templates and cost more than they saved.

Gate 3 (§12) is pinned by `test/compile_once_templates_test.jl`: the fast path,
the fused build (`ESS_TEMPLATE_REF_DISABLE=1`), the boundary-expanded build
(`ESS_TEMPLATE_COMPILE_ONCE_DISABLE=1`), the per-cell reference
(`ESS_STENCIL_DISABLE=1`), and the out-of-place emitter all produce the
**bit-identical** RHS on both fixtures (exact `==` on `du`, multiple states and
times), and the reduced-rank fixture pins the sound fallback chain
(ref-aware attempt → fused retry → symbolic → per-cell).
