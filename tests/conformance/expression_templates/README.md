# Expression Templates Conformance Fixtures (esm-spec §9.6)

These fixtures exercise the `expression_templates` block and the
`apply_expression_template` AST op landed in v0.4.0 (RFC
`docs/content/rfcs/ast-expression-templates.md`, bead esm-giy).

## Fixtures

### `arrhenius_smoke/fixture.esm`

A reaction system declaring a 2-parameter `arrhenius` template
(`A · exp(-Ea / T) · num_density`) and three reactions whose rates use it
with different scalar bindings. After load-time expansion (Option A
round-trip; esm-spec §9.6.4 rule 1), every `apply_expression_template`
node MUST be replaced by the structurally-identical inline AST that
authoring the same form by hand would produce. All five bindings (Julia,
TypeScript, Python, Rust, Go) must agree on the post-expansion AST
byte-for-byte after canonical serialization.

### `arrhenius_smoke/expanded.esm`

The expected post-expansion form of `arrhenius_smoke/fixture.esm` —
i.e. what `load(fixture.esm)` then re-serialize MUST emit
(Option A round-trip is "always-expanded": the canonical AST after parse-then-emit
is the expanded form, never the source). Conformance harnesses load the
template fixture, re-serialize, and assert structural equality with this file.

## Rewrite-engine fixtures (0.8.0: outermost-first + priority + bounded fixpoint)

These exercise the auto-applied `match` rewrite engine (esm-spec §9.6.3) and the
`unlowered_operator` gate (§9.6.3 constraint 6 / §9.6.8) introduced by the
open-op-namespace RFC (`docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md`).
grad/div/laplacian/`D` here are **rewrite-target sugar**, privileged in no way —
this format ships no discretization rules (they live in `../earthscidiscretizations`).

**Two fixture shapes.** A fixture that lowers cleanly ships a `fixture.esm` + an
`expanded.esm` golden (compare post-lowering trees, as with `arrhenius_smoke`). A
fixture that MUST be rejected ships a `fixture.esm` + an `error.json`:

```json
{ "code": "<stable diagnostic>", "stage": "load" | "evaluate", "description": "..." }
```

`stage: "load"` — the error fires during load-time template lowering.
`stage: "evaluate"` — the file loads (open namespace) but is rejected when it
reaches evaluation/compilation; parse/validate-only bindings mark it N/A.

### `godunov_beats_inner_deriv/` (expanded.esm)

Compound `sqrt(D(u,x)² + D(u,y)²)` with a `priority: 100` rule matching the whole
compound (→ `godunov_coef · u`) and `priority: 0` per-derivative central-difference
rules on `D` (→ `inv_dx · …`). Asserts the compound rule fires on the whole term
FIRST — the expanded form is `godunov_coef · u`, with **no** `inv_dx` — proving the
inner `D`s are never independently lowered. Anti-regression for the old
bottom-up/innermost-first single pass, which could not match a compound before its
parts.

### `fixpoint_nested_deriv/` (expanded.esm)

`laplacian(u)` lowered by a sugar rule to `D(D(u,x),x) + D(D(u,y),y)` (pass 1),
whose nested `D`s are then lowered to stencils by second-derivative rules (pass 2).
Asserts convergence in exactly 2 productive passes to
`inv_dx2·u + inv_dy2·u`, identical in every binding — exercising the bounded
fixpoint (a produced body is re-scanned in a SUBSEQUENT pass, never within the
pass that produced it).

### `nonterminating_rewrite/` (error.json, `rewrite_rule_nonterminating`, load)

A self-reintroducing rule (`grad(f) → grad(grad(f))`) that grows the tree every
pass and never converges. Asserts the engine rejects the file with
`rewrite_rule_nonterminating` once `MAX_REWRITE_PASSES = 64` productive passes have
run — nontermination is caught by the pass bound, NOT by a static pre-check.

### `unlowered_operator/` (error.json, `unlowered_operator`, evaluate)

A spatial `D(u, wrt=x)` in an equation RHS with no rewrite rule. Loads cleanly, but
is rejected with `unlowered_operator` when the model reaches evaluation/compilation.
The uniform diagnostic supersedes the old per-binding UnreachableSpatialOperator /
UnsupportedDimensionality codes.
