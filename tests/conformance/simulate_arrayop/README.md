# Simulate-ArrayOp Conformance Fixtures (ess-zmm)

Cross-port numeric conformance fixtures for the **arrayop contraction** path.
The schema advertises a general einsum — `out[output_idx] = REDUCE over contracted
indices of expr`, reduce ∈ {+, *, max, min} — but no prior conformance fixture
exercised an index that appears in `ranges` but NOT in `output_idx` (a true
contracted index). This category closes that gap.

## Fixture set

| Fixture | Contracted index | Reducer | Output rank | Notes |
|---------|-----------------|---------|-------------|-------|
| `23_arrayop_pure_matvec_contraction` | j | +, max | 1 (vector) | Pure index body, no state vars in contraction |
| `21_reduce_max_min_ode` | j | max | 1 | State var (u[i]) appears in body alongside j |
| `22_reduce_min_ode` | j | min | 1 | State var (v[i]) appears in body alongside j |
| `20_arrayop_contraction_embedded` | j | +, max | 0 (scalar) / 1 | Embedded form: arrayop is RHS of scalar D eq |

### Spatial PDE stencils (ess-bdm)

Discretized method-of-lines diffusion fixtures — pure-map LHS-arrayops whose RHS
body is `index(makearray(interior + Dirichlet ghost regions), …)`. Conformance is
on a **numeric-tolerance** basis against the exact discrete eigenvalue solution
(rel tol 1e-3). Rust evaluates these **vectorized** (whole-array shifted-slice
stencils, no per-cell scalarization — ess-bdm).

| Fixture | Grid | Reducer | Output rank | Notes |
|---------|------|---------|-------------|-------|
| `15_discretized_1d_heat` | 4 cells | (pure map) | 1 | 1-D heat, Dirichlet ghosts; λ₁=−9.5492 |
| `16_discretized_2d_heat` | 3×3 | (pure map) | 2 | 2-D heat, edge/corner ghost regions |

## Executing ports

| Port | Contraction (23/20) | PDE stencils (15/16) | How |
|------|---------------------|----------------------|-----|
| Python | ✅ yes | ✅ yes | `simulation.py` Case B + numpy vectorized stencil path (PR #25); `test_arrayop_simulation.py` globs all fixtures |
| Rust | ✅ yes | ✅ yes (vectorized) | `arrayop_simulate_tests.rs`; vectorized path verified in `pde_vectorized_eval.rs` (ess-bdm) |
| Julia | ✅ yes (MTK + tree-walk) | ✅ yes (tree-walk) | tree-walk LHS-arrayop unroller; `tree_walk_arrayop_test.jl` testsets 6 (15) & 7 (16) |
| TypeScript | ❌ skip | ❌ skip | No arrayop numeric executor |
| Go | ❌ skip | ❌ skip | No arrayop numeric executor |

## Adapter contract

An executing port's test adapter MUST:

1. **Load** the fixture path (relative to `tests/`) via the binding's official parser.
2. **Simulate** every model with the declared `initial_conditions` and `time_span`.
3. **Assert** every `(variable, time, expected)` entry passes within the model's `tolerance`.
4. **Report** per-fixture, per-test-id, per-assertion pass/fail using the binding's
   native framework. Use the fixture `id` as the test case label.

## Skip discipline

Non-executing ports MUST explicitly skip (not silently pass) any fixture in this
category. In-code documentation MUST name this manifest as the source. Example:

```typescript
// TypeScript has no arrayop numeric executor.
// See tests/conformance/simulate_arrayop/README.md for the skip contract.
test.skip('simulate_arrayop/23_arrayop_pure_matvec_contraction', () => { ... });
```

Skips are correct behavior, not gaps — the fixtures exist so that when a port adds
numeric arrayop execution, the conformance test is already there to validate it.

## Julia support boundary

Julia supports contraction for the **LHS-arrayop form**
(`arrayop(D(index(var,i))) = arrayop(body, reduce=R, contracted_j)`) via two paths:
- **tree-walk** (`build_evaluator`): generalized-einsum unroll at build time
  (`tree_walk.jl:294-370`). Handles reduce ∈ {+, *, max, min}.
- **MTK**: `_build_arrayop_sym` in `EarthSciASTMTKExt`, which delegates to
  Symbolics `ArrayOp`.

Julia does NOT support the **embedded form** (`D(z) = arrayop(...)` where `z` is a
scalar state): `tree_walk.jl:631` throws `E_TREEWALK_UNSUPPORTED_OP`. The embedded
form is tracked in bead `ess-n0w`. Fixture 20 (which exercises the embedded form) is
listed with `executing_bindings: ["python", "rust"]` and Julia in `skip_bindings`.
