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

### `coupling_transform_expression/` (expanded.esm)

The v0.8.0 `variable_map.transform` expression widening (esm-spec §10.4/§10.5):
a coupling entry whose `transform` is an Expression invoking a template
declared by the RECEIVING component (`Sink.double_plus`). Template invocations
in a coupling transform expand at load (§9.6.4) against the registry of the
component that owns the entry's `to` target, so after load the transform is
the inline AST `2*Src.F + Sink.offset` (all references fully scoped —
`expanded.esm` pins the form, structurally identical across all five
bindings). The post-expansion twin lives in
`tests/valid/coupling_transform_expression.esm` and is registered in the
round_trip manifest; the flatten/evaluation contract (target parameter
becomes an observed defined by the transform; `u(1) = 9.5`) is exercised by
the executing bindings' unit suites.

### `scalar_field_param/` (expanded.esm)

Scalar-field template-parameter substitution (esm-spec §9.6.1 / §9.6.3
constraint 5): one `overlap_area` template whose `body` carries a parameter
name (`K_manifold`) as the string VALUE of the scalar `manifold` field of a
`polygon_intersection_area` node — a substitution site, the exact mirror of
the match-side scalar-field binding rule — instantiated twice with different
manifold literals (`planar`, `spherical`). All five bindings MUST expand both
observeds to the same post-substitution nodes (`expanded.esm`, Julia-generated
via `scripts/generate-template-import-goldens.jl`). The value bound to a
scalar-field parameter must be a literal admissible for the field, enforced on
the EXPANDED form per §9.6.4 (`geometry_manifold_invalid` for an out-of-set
manifold; the inadmissible-binding and params-shadow-literals cases are
exercised 1:1 by the per-binding unit suites). This is the rule that lets the
EarthSciDiscretizations conservative-regrid library serve every manifold from
one file instead of pinning `manifold: "planar"` per file.

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

## Match-scoping fixtures (esm-spec §9.6.1 `where` + ground patterns, 0.8.0)

These exercise the static match-scoping constraints of
`docs/content/rfcs/match-pattern-scoping-constraints.md`: the `where` field on
a `match` rule (index-set/shape scoping of captured params) and the sanctioned
ground-pattern per-variable selector. Constraint evaluation reads declared
variable shapes only — fully static — and filters BEFORE the §9.6.3
priority/declaration-order selection.

### `constrained_match_scope/` (expanded.esm)

One shape-constrained div rule (`where: {F: {shape: ["edges"]}}`), two shaped
variables. `div(F_edge)` (over `["edges"]`) is rewritten; `div(F_cell)` (over
`["cells"]`) is constraint-excluded and survives lowering intact — positive
and negative case in one golden. The surviving `div` would be rejected by
`unlowered_operator` only at evaluation (loading is permissive).

### `two_div_two_meshes/` (expanded.esm)

Two structurally IDENTICAL equal-priority `{op: "div", args: ["F"]}` rules,
each `where`-scoped to its own mesh's edge set (`edges_a` / `edges_b`). Each
`div` lowers by its own mesh's rule. Without the constraints, the §9.6.3
declaration-order tie-break would send both nodes to the first-declared rule —
the two-grids-two-schemes inexpressibility this mechanism closes.

### `per_variable_scheme_literal_args/` (expanded.esm)

The per-variable half of match scoping, which needs NO new construct: a
non-parameter string in an `args` position is a literal matching only that
exact bare variable reference. A `params: []` ground rule
`{op: "D", args: ["u"], wrt: "x"}` at `priority: 10` takes `u` (upwind);
the generic wildcard rule at `priority: 0` takes everything else (central).
Mixed schemes on one axis, ranked by explicit priority.

### `constraint_unknown_index_set/` (error.json, `template_constraint_unknown_index_set`, load)

A `where` shape constraint naming an index set the consuming document's merged
registry does not declare. Rejected at rule registration — a constraint typo
fails loudly (mirroring `template_import_unknown_name`); a constrained rule
that merely never fires is NOT an error.

## Template-library import fixtures (esm-spec §9.7, 0.8.0)

These exercise `expression_template_imports`, template-library files, and
load-time `metaparameters` (RFC `docs/content/rfcs/template-library-imports.md`).
Goldens are generated by the Julia reference implementation:

```
julia --project=packages/EarthSciSerialization.jl scripts/generate-template-import-goldens.jl
```

Golden formatting is sorted-keys / 2-space-indent JSON; bindings compare
STRUCTURALLY (parse both sides with your own JSON parser). Fixture scalar
literals avoid integral-valued floats (e.g. `1.5`, not `1.0`) so parser
int/float narrowing cannot skew the comparison.

### `import_smoke/` (expanded.esm)

The normative §9.7.8 four-file layering, from RFC §6: `grid_latlon.esm`
(metaparameters NLON/NLAT, `lon`/`lat` index sets, zero-parameter `dlon_deg`) ←
`central_D_lon_interior.esm` (match-less interior stencil; body references
`dlon_deg`) ← `central_D_lon_zero_grad_bc.esm` (the complete `match` rule on
`D(f, wrt: lon)`; body references the interior stencil) ← `fixture.esm` (the
consuming model, binding `{"NLON": 288, "NLAT": 181}` at its import edge with
`only`). The golden shows: index sets merged at 288/181, regions and dense
ranges folded to concrete integers, `dlon_deg` substituted (`360 / 288`
staying an AST division in expression position), and the lowered equation RHS.

### `import_diamond/` (expanded.esm)

`fixture.esm` imports `lib_flux_a.esm` and `lib_flux_b.esm`, both of which
import `grid_shared.esm` unbound — the shared grid's `cell_count` template,
`NC` metaparameter, and `cells` index set arrive twice deep-equal and dedup at
first occurrence (§9.7.4/§9.7.5); `NC` closes by default (10) at the root.

### `import_order_determinism/` (expanded_import_order.esm, expanded_priority_override.esm)

`lib_rule_first.esm` and `lib_rule_second.esm` declare equal-priority `match`
rules on the same `{op: "lowerme"}` pattern. `fixture_import_order.esm`
imports [first, second]: the effective declaration order (§9.7.4, depth-first
post-order = import array order) pins the winner → `y = 2 * x`.
`fixture_priority_override.esm` imports [first, second_hi] where
`lib_rule_second_hi.esm` declares `priority: 10`: explicit priority out-ranks
the order tie-break (§9.6.3) → `y = 5 * x`.

### `metaparameter_resolutions/` (expanded_n4.esm, expanded_n8.esm)

`problem.esm` is a model file sized by metaparameter `N` (default 2): `N`
appears in an expression position (`npts`), inside an AST division that must
NOT fold (`half`), and in an `aggregate` dense range bound that MUST fold
(`ramp`). `wrapper_n4.esm` / `wrapper_n8.esm` instantiate it at `N = 4` / `8`
through §4.7 subsystem-ref `bindings` (§9.7.6 binding site 3). Goldens are the
full typed round-trip (`load → serialize`), wrapper subsystem inlined.

### `import_rename_two_instances/` (expanded.esm)

The normative §9.7.7 two-instance example (RFC
`docs/content/rfcs/template-import-renaming.md` §5): `grid_uniform_1d.esm` is
a generic grid family (metaparameter `N`, index set `x`, zero-parameter `dx`,
a centered-difference rule matching `D(f, wrt: "x")`), imported twice by
`fixture.esm` under `prefix: "fine"` (`N = 16`) and `prefix: "coarse"`
(`N = 8`). The golden shows the transitive rename: index sets `fine.x` (16) /
`coarse.x` (8), each rule instance fired only on its own axis (`wrt` in the
match followed the index-set rename), ranges folded per instance ([2, 15] vs
[2, 7]), and `dx` instantiated per edge (`1 / 16` vs `1 / 8`, both staying AST
divisions).

### `import_rebind_keyed_factors/` (expanded.esm)

Free-name rebinding (§9.7.7) in the MPAS keyed-factor style:
`ragged_rowsum.esm` declares a ragged index set (`offsets: "row_count"`,
`values: "row_cols"`) and a `weighted_rowsum` rule over it with a free weight
factor `row_w`. `fixture.esm` imports it with
`rebind: {row_count → meshA_count, row_cols → meshA_cols, row_w → meshA_w}`.
The golden shows the rebound names in the merged registry (offsets/values)
AND throughout the rule body (aggregate `args`, `index` gathers); the
consumer's own unrelated `row_count` parameter coexists — rebinding
un-reserves the library's factor names.

### `import_rename_diamond/` (expanded.esm)

Rename-aware dedup (§9.7.4 + §9.7.7): `cellgrid.esm` imported three times —
twice identically (`prefix: "a"`, `NC = 6`; dedupes at first occurrence) and
once as a distinct instance (`prefix: "b"`, `NC = 9`; no deep-equal dedup
across renames). Both renamed instances of the axis-less `scale_by_cells`
rule register; the §9.6.3 equal-priority tie breaks by the §9.7.4 effective
order (DFS post-order over the edges), so the first instance wins:
`y = 6 * x`, and the registry carries `a.cells` (6) and `b.cells` (9).

## Scope-directed template injection (esm-spec §9.7.10)

These fixtures exercise the assembler- or test-chosen discretization for a
discretization-agnostic PDE leaf (`docs/content/rfcs/scoped-template-injection.md`):
an `expression_template_imports` list registered into a *target* component's
own scope from the consuming surface, without editing the leaf. All three forms
reuse the §9.7.2 `TemplateImport` shape and the §9.6.3 fixpoint verbatim — the
only new capability is *who may write into a component's scope*. They share the
`grid_latlon.esm` → `central_D_lon_interior.esm` → `central_D_lon_zero_grad_bc.esm`
central-difference library from `import_smoke/`.

### `inject_subsystem_ref/` (form A — §4.7 / §9.7.10)

`leaf.esm` is a bare-`D(c, wrt: lon)` PDE leaf with NO import of its own.
`fixture.esm` mounts it as a subsystem by `ref` and injects the BC rule via the
subsystem-ref edge's `expression_template_imports` (bound `NLON=288, NLAT=181`).
The golden `expanded.esm` (full typed load, re-emitted) is the assembled
document with the mounted leaf's derivative lowered to the `makearray` stencil
and the injection field GONE — form A is consumed by the fixpoint and does not
survive `parse → emit`. `no_inject.esm` is the negative twin: the same mount
without injection loads cleanly (the `D` survives) but is `unlowered_operator`
at the evaluation gate (parse/validate-only bindings mark it N/A).

### `inject_coupling_entry/` (form B — §10.8 / §9.7.10)

`fixture.esm` composes a 0-D system (`Emit`) and a spatial model (`Advection`,
agnostic) with `operator_compose`, injecting the BC rule into `Advection` by
name through the entry's `expression_template_imports` map. The golden
`expanded.esm` has `Advection`'s derivative lowered and the coupling entry's
injection map consumed (form B does not survive `parse → emit`); `Emit` names no
key and is untouched. Negatives (load-time `ExpressionTemplateError`):
`neg_target_unknown.esm` (key names no referenced system →
`template_inject_target_unknown`) and `neg_target_is_loader.esm` (key resolves
to a data loader → `template_inject_target_is_loader`).

### `inject_test_block/` (form C — §6.6.6 / §9.7.10)

`fixture.esm` is an agnostic PDE leaf whose two inline tests each carry
`expression_template_imports` naming the discretization to run under (grids
288×181 and 144×91 — one suite, many schemes). The golden `roundtrip.esm` is the
full typed load re-emitted: unlike a component's own imports, a test's imports
are authored per-run config, so the enclosing component round-trips with its `D`
INTACT and each test KEEPS its import field (form C survives `parse → emit`).
Each test runs as an independent per-test ephemeral build in which the leaf's
derivative is lowered under that test's grid; the persisted component is never
mutated (the Julia reference runs this through `run_pde_tests`).
