# Per-cell metric binding evaluator — scope and design (ess-jbe)

**Status:** Design note (spike) — produced for the S2 landing bead.  
**Bead:** ess-jbe (scope / spike; no evaluator code in this document).  
**Scope of S2:** Enable the ESS discretize pipeline and MMS harness to evaluate
per-cell metric bindings end-to-end, unblocking non-uniform rectilinear rules and
lat-lon / vertical curvilinear rules currently deferred in the ESD rig
(`dsc-7jc` marks Layer-B fixtures `applicable: false`).

---

## 1. The gap

The schema already declares the full per-cell contract:

- **§5.2.8 `RuleBinding`** — `kind: "per_cell"` marks a symbol in the
  rule's `replacement` AST that varies across grid cells at runtime
  (examples: `velocity[i]`, `cos_lat[j]`, `dx[i]` for non-uniform grids).
- **§6.2 metric arrays** — rank-1+ arrays on the grid (e.g. `"dz"` with
  `rank: 1, dim: "z"`) hold the non-uniform cell-spacing values.
- **§6.2.1 scalar → indexed metric rewrite** — bare `"dx"` references in
  stencil `coeff` expressions are auto-rewritten to
  `{op:"index", args:["dx", <target-index>]}` during scheme expansion when
  the corresponding dimension has `spacing: "nonuniform"`.

What is **not yet implemented**:

| Gap | Location |
|-----|----------|
| §6.2.1 auto-index rewrite is missing from scheme expansion | `scheme_expansion.jl` `_expand_stencil_entry` |
| `metric_array_names` not threaded through to scheme expander | `discretize.jl` / `scheme_expansion.jl` |
| MTK harness (`grid_assembly.jl`) explicitly rejects non-uniform cell widths | `grid_assembly.jl` `_uniform_dx` |
| Conformance fixture for non-uniform 1D diffusion missing | `tests/conformance/discretization/step2_nonuniform_1d/` |

The `cfl_sine_advection` conformance fixture already demonstrates parse/serialize
of `per_cell` rule bindings; what is absent is **evaluation** — the pipeline
that rewrites and materializes the indexed expressions.

---

## 2. Binding kinds that need per-cell evaluation

Three orthogonal mechanisms converge here:

### 2.1 Auto-indexed rank-1 metric arrays (§6.2.1)

These come from the grid's `metric_arrays` block.  When a dimension is
`"spacing": "nonuniform"` the metric array for that dimension **must** have
`rank: 1, dim: "<axis>"`.  The §6.2.1 rewrite converts any bare string
reference `"dz"` in a stencil `coeff` to the indexed form
`{op:"index", args:["dz", k]}` during scheme expansion.

| Binding name | Dimension | Grid family | How supplied |
|---|---|---|---|
| `dz` / `dz_k` | vertical `z` | cartesian (stretched levels) | rank-1 metric array; `kind: "loader"` or `"expression"` generator |
| `dx` | horizontal `x` | cartesian (non-uniform) | rank-1 metric array; usually `"expression"` |
| `dy` | horizontal `y` | cartesian (non-uniform) | rank-1 metric array |

**Authoring note:** `"spacing": "nonuniform"` on a dimension is both the
trigger for the §6.2.1 rewrite and the requirement that the metric array has
`rank: 1`.  A `rank: 0` scalar metric on a nonuniform dimension is a schema
violation; the evaluator MAY reject it.

### 2.2 Per-cell rule bindings (§5.2.8 `kind: "per_cell"`)

These are runtime-supplied arrays declared in the rule's `bindings` object.
They appear as bare names in the `replacement` AST and are supplied by the
host runtime (solver) at evaluation time, not from the grid schema.

| Binding name | Cadence | Examples |
|---|---|---|
| `velocity` | `per_cell` | Cell-centered wind speed in upwind advection |
| `cos_lat` | `per_cell` | Latitudinally-varying Coriolis metric on lat-lon grids |
| General metric tensor components | `per_cell` | `J`, `g_xixi` in curvilinear cross-metric stencils |

These do **not** go through the §6.2.1 auto-index rewrite.  The replacement
AST references them as bare names; the host runtime is responsible for
supplying the indexed array at the correct grid location.

### 2.3 Distinction from auto-indexed metrics

| | §6.2.1 metric arrays | §5.2.8 `per_cell` bindings |
|---|---|---|
| Declared in | `grids.<name>.metric_arrays` | `rules.<name>.bindings` |
| Value source | Grid schema (expression / loader generator) | Host runtime |
| Trigger for rewrite | `dim.spacing = "nonuniform"` | n/a (no auto-rewrite) |
| Appears in replacement AST | Bare name → auto-rewritten to `index` | Bare name; remains bare until runtime supplies array |

---

## 3. §6.2.1 auto-indexing: resolution rules

### 3.1 Trigger and rewrite

During `expand_scheme` (§7.2), before canonicalization, the expander walks
every `coeff` expression in the scheme's stencil entries.  For each bare
`VarExpr` node whose name matches an entry in the grid's `metric_array_names`
set AND whose associated dimension is in `nonuniform_dims`:

```
"dz"  →  {op:"index", args:["dz", <target-index-for-$z>]}
```

where `<target-index-for-$z>` is the canonical grid index for the axis
(e.g. `k` for a cartesian grid's third dimension).

### 3.2 Index source

The target index is the **expansion target's** canonical index for that axis —
not the stencil neighbor's index.  In a 1D cartesian scheme iterating over
`[k]`, the target index for axis `z` is `k`.

**Neighbor spacings require explicit indexing.** The auto-rewrite only
produces `dz[k]`.  Stencil coefficients that also need `dz[k-1]` or
`dz[k+1]` must express those as explicit `{op:"index"}` nodes:

```json
{"op": "index", "args": ["dz", {"op": "+", "args": ["k", 1]}]}
```

The canonical index variable `k` (and `i`, `j` for other axes) is in scope
in every `coeff` expression after scheme expansion begins.

### 3.3 Alignment with arrayop ranges

The `index` node produced by §6.2.1 uses the same symbolic variable as the
arrayop's loop range, so there is no misalignment.  A 1D cartesian arrayop
with range `1..N` iterates `k ∈ 1..N`, and `dz[k]` resolves correctly at
every position.  Boundary handling (periodic wrap, ghost cells) is governed
by the rule's `boundary_policy` and is out of scope for this spike.

### 3.4 Interaction with existing `apply_bindings`

The §6.2.1 rewrite is **separate** from `apply_bindings` (which substitutes
pattern-variable bindings like `$u`, `$x`).  It runs **after** `apply_bindings`
in the stencil-entry expansion step so that pattern variables are already
resolved when metric names are walked.

---

## 4. Conformance harness extension

### 4.1 New conformance fixture (step2_nonuniform_1d)

A new fixture class under `tests/conformance/discretization/step2_nonuniform_1d/`
exercises the §6.2.1 rewrite path:

```
tests/conformance/discretization/step2_nonuniform_1d/
  input.esm           # 1D diffusion model on geometric-progression z-grid
  expected.json       # Julia-emitted discretized AST (golden)
  manifest.json       # fixture metadata
```

The input `.esm` specifies a 1D model with:
- Grid: cartesian, 1 dimension `z`, `spacing: "nonuniform"`, rank-1 metric
  array `dz` with an `expression` generator: `{"op": "*", "args": ["h0", {"op": "^", "args": [1.2, "k"]}]}`
  where `h0 = 1.0` is a grid parameter.
- Discretization: `d2_nonuniform_z` scheme (see §5 worked example below).

The fixture checks bit-identity of the discretized AST across Julia and Rust,
confirming both bindings apply the same §6.2.1 rewrite.

### 4.2 MTK harness extension (grid_assembly.jl)

The function `_uniform_dx` in `grid_assembly.jl` currently throws on
non-uniform cell widths.  The S2 landing bead must replace the scalar `dξ`
assumption in the Laplacian stencil assembly with a per-cell width vector.

**Current signature (unchanged for uniform axes):**
```julia
function _uniform_dx(grid::AbstractGrid, axis::Symbol)::Float64
```

**New helper needed:**
```julia
function _cell_widths_vec(grid::AbstractGrid, axis::Symbol)::Vector{Float64}
    return Vector{Float64}(cell_widths(grid, axis))
end
```

`precompute_laplacian_stencil` (and any other caller of `_uniform_dx`) must
be updated to accept and use the per-cell width vector.  The arithmetic that
formerly read `dξ^2` or `dξ * dη` now reads `dξ[c] * dξ[c]` or
`dξ[c] * dη[c]` for cell `c`.

This change affects `precompute_laplacian_stencil` and any code path that
calls `_uniform_dx`.  No other trait method is needed; `cell_widths` already
exists on `AbstractGrid`.

### 4.3 Scheme expander change (scheme_expansion.jl)

**Function:** `_expand_stencil_entry`  
**Change:** After `coeff = apply_bindings(entry.coeff, bindings)`, walk the
`coeff` AST and apply the §6.2.1 rewrite:

```julia
# Pseudo-code for the rewrite pass:
function _rewrite_metric_refs(expr::Expr, axis_name::String,
                               target_idx::Expr,
                               metric_names::Set{String},
                               nonuniform_dims::Vector{String})::Expr
    if expr isa VarExpr && expr.name in metric_names &&
       axis_name in nonuniform_dims
        return OpExpr("index", [expr, target_idx])
    elseif expr isa OpExpr
        return OpExpr(expr.op, map(e -> _rewrite_metric_refs(
            e, axis_name, target_idx, metric_names, nonuniform_dims), expr.args))
    end
    return expr
end
```

`target_idx` is the canonical index `VarExpr` for `axis_name` — already
available in `target` (the expansion target's index vector).

**Threading needed:** `expand_scheme` must receive `metric_array_names` alongside
`nonuniform_dims` from the grid metadata dict.  Both are already available in
`_extract_grid_meta` (which populates `nonuniform_dims`); the same function
should also collect `metric_array_names = keys(metric_arrays_block)`.

### 4.4 Summary of change surface

| File | Function | Change |
|------|----------|--------|
| `src/discretize.jl` | `_extract_grid_meta` | Also collect `metric_array_names` from `metric_arrays` block |
| `src/scheme_expansion.jl` | `expand_scheme` | Accept `metric_array_names` from grid metadata |
| `src/scheme_expansion.jl` | `_expand_stencil_entry` | Apply §6.2.1 rewrite after `apply_bindings` |
| `src/grid_assembly.jl` | `_uniform_dx` / `precompute_laplacian_stencil` | Replace scalar `dξ` with per-cell vector |
| `tests/conformance/discretization/step2_nonuniform_1d/` | new | Non-uniform 1D diffusion fixture + golden |

### 4.5 Schema changes

**None required.** All necessary constructs are already in the v0.2.0+ schema:
- `RuleBinding` with `kind: "per_cell"` / `"per_step"` / `"static"` ✓
- Metric array `rank`, `dim`, `generator` fields ✓
- `spacing: "nonuniform"` on dimensions ✓
- `{op:"index"}` AST node ✓

This spike does **not** route through `mol-update-spec-schema`.

---

## 5. Worked example — non-uniform centered 2nd derivative on a geometric-progression grid

The example uses a 1D grid (one dimension `z`).  In a 1D cartesian grid the
single dimension receives canonical index `i`.  In a 3D grid `["x","y","z"]`,
the z-dimension would receive canonical index `k` — which is the realistic
atmospheric case (see §5.5 note).  For clarity this example uses 1D + `i`.

### 5.1 Grid definition (ESM)

```json
{
  "esm": "0.2.0",
  "grids": {
    "gz": {
      "family": "cartesian",
      "dimensions": [{"name": "z", "size": 8, "periodic": false, "spacing": "nonuniform"}],
      "metric_arrays": {
        "dz": {
          "rank": 1,
          "dim": "z",
          "generator": {
            "kind": "expression",
            "expr": {"op": "*", "args": [1.0, {"op": "^", "args": [1.2, "i"]}]}
          }
        }
      },
      "parameters": {"Nz": {"default": 8}}
    }
  }
}
```

Grid: `N = 8` cells, `dz_i = 1.0 × 1.2^i` (0-indexed: `i = 0, …, 7`).  
Cell spacings in metres: `1.0, 1.2, 1.44, 1.728, 2.074, 2.488, 2.986, 3.583`.  
Canonical index for the first (and only) cartesian dimension: `i`.

### 5.2 Discretization scheme

For the non-uniform 2nd derivative `∂²u/∂z²` at cell `i`, the standard
asymmetric stencil is:

```
u''_i ≈ 2·[  u_{i-1} / (dz_i · (dz_i + dz_{i+1}))
            − u_i    / (dz_i · dz_{i+1})
            + u_{i+1} / (dz_{i+1} · (dz_i + dz_{i+1}))  ]
```

where `dz_i` is the backward spacing (cell `i-1` to `i`) and `dz_{i+1}` is
the forward spacing (cell `i` to `i+1`).

In ESM stencil form, the three entries are:

```json
{
  "name": "d2_nonuniform_z",
  "applies_to": {"op": "laplacian", "args": ["$u"], "dim": "$z"},
  "grid_family": "cartesian",
  "combine": "+",
  "stencil": [
    {
      "selector": {"kind": "cartesian", "axis": "$z", "offset": -1},
      "coeff": {
        "op": "/",
        "args": [2, {
          "op": "*",
          "args": [
            "dz",
            {"op": "+", "args": [
              "dz",
              {"op": "index", "args": ["dz", {"op": "+", "args": ["i", 1]}]}
            ]}
          ]
        }]
      }
    },
    {
      "selector": {"kind": "cartesian", "axis": "$z", "offset": 0},
      "coeff": {
        "op": "neg",
        "args": [{
          "op": "/",
          "args": [2, {
            "op": "*",
            "args": [
              "dz",
              {"op": "index", "args": ["dz", {"op": "+", "args": ["i", 1]}]}
            ]
          }]
        }]
      }
    },
    {
      "selector": {"kind": "cartesian", "axis": "$z", "offset": 1},
      "coeff": {
        "op": "/",
        "args": [2, {
          "op": "*",
          "args": [
            {"op": "index", "args": ["dz", {"op": "+", "args": ["i", 1]}]},
            {"op": "+", "args": [
              "dz",
              {"op": "index", "args": ["dz", {"op": "+", "args": ["i", 1]}]}
            ]}
          ]
        }]
      }
    }
  ]
}
```

**Key observation:** The bare `"dz"` references in the first two stencil entries
are auto-rewritten by §6.2.1 to `{op:"index", args:["dz", i]}` (the target-cell
spacing).  The `{op:"index", args:["dz", {op:"+", args:["i", 1]}]}` references
are explicit neighbor indexing that the §6.2.1 rewrite does not touch (they are
already `index` nodes, not bare strings).

### 5.3 Expansion trace (step by step)

Suppose the scheme expands at target `i = 3` on the 8-cell grid.

**Step 1 — `apply_bindings`:** `$u` binds to the model variable `u`,
`$z` binds to dimension `z` → canonical index `i` (first dimension).

**Step 2 — §6.2.1 rewrite on `coeff` AST:**
Bare `"dz"` in the offset-(-1) entry becomes
`{op:"index", args:["dz", i]}` (i.e., `dz[i]`).  
`{op:"index", args:["dz", {op:"+", args:["i", 1]}]}` is already an
`index` node → **not rewritten** (pass-through).

After rewrite, the offset-(-1) coefficient is:
```
2 / (dz[i] * (dz[i] + dz[i+1]))
```

**Step 3 — Materialize stencil entries:**
- offset -1: `2 / (dz[i] * (dz[i] + dz[i+1])) * u[i-1]`
- offset  0: `-(2 / (dz[i] * dz[i+1])) * u[i]`
- offset +1: `2 / (dz[i+1] * (dz[i] + dz[i+1])) * u[i+1]`

Combined with the `"+"` combine operation, the full expansion is:

```
2·u[i-1] / (dz[i] · (dz[i] + dz[i+1]))
 - 2·u[i]  / (dz[i] · dz[i+1])
 + 2·u[i+1] / (dz[i+1] · (dz[i] + dz[i+1]))
```

which is the correct non-uniform centered 2nd-derivative formula.

**Step 4 — Metric materialization at evaluation:**
When the Julia harness evaluates this arrayop, it looks up `dz` in the
grid's materialized metric array vector.  For the geometric-progression
grid: `dz = [1.0, 1.2, 1.44, 1.728, 2.074, 2.488, 2.986, 3.583]`
(0-indexed: `dz[0]=1.0, dz[1]=1.2, …`).

At `i = 3`: `dz[i] = 1.728`, `dz[i+1] = 2.0736` (≈ 2.074).  
Coefficient for `u[i-1]`: `2 / (1.728 × (1.728 + 2.074)) = 2 / 6.572 ≈ 0.3044`.

**Step 5 — MMS check:**
For the exact solution `u(z) = z²` (where `z_i = Σ_{j<i} dz[j]`), the
exact 2nd derivative is `u''(z) = 2` everywhere.  The stencil recovers
this exactly for any non-uniform spacing, because the non-uniform centered
formula is derived from the Taylor expansion for arbitrary `dz[i], dz[i+1]`.

To verify convergence, use `u(z) = sin(z)` and compare the discretized
`∂²u/∂z²` against the analytic `−sin(z)` on a sequence of grid refinements.
With `r = 1.2` fixed and `N = 8, 16, 32`, the max-norm error should
converge at `O(h²)` where `h = max(dz[i])` (the max cell width at that level).

### 5.4 Note on 3D usage

In a 3D grid `"dimensions": ["x", "y", "z"]`, the canonical index for `z`
is `k` (third dimension).  All `i` references in the stencil JSON above
become `k`, and the generator expression uses `k`:
```json
"expr": {"op": "*", "args": [1.0, {"op": "^", "args": [1.2, "k"]}]}
```
The §6.2.1 rewrite produces `{op:"index", args:["dz", k]}` in that case.
The S2 landing bead conformance fixture may use either shape; 1D is simpler
for an isolated unit test.

---

## 6. Open questions deferred to S2 landing bead

1. **Loader-kind metric arrays at harness evaluation time.**  The fixture
   here uses `"kind": "expression"` generators, which can be evaluated
   analytically.  Loader-kind metrics (e.g. `zlev_file` in
   `tests/grids/cartesian_uniform.esm`) require I/O.  The S2 landing bead
   should use expression-kind only; loader-kind is deferred.

2. **Boundary handling for non-uniform 1D schemes.**  The §6.2.1 rewrite
   produces `dz[k+1]` at the last cell `k = N-1`, which is out-of-bounds.
   The correct behaviour (ghost-cell extension, one-sided stencil, or
   clamped index) depends on `boundary_policy` and is a Step 2 concern.
   The S2 landing bead fixture should use periodic boundaries to sidestep
   this until Step 2 lands.

3. **`cos_lat` as per-cell binding vs. metric array.**  `cos_lat` appears in
   the RFC as both a `static` binding example (§5.2.8 table note) and
   implicitly as a per-cell metric for lat-lon grids.  The correct
   representation on a lat-lon grid is a rank-1 metric array
   (`"dim": "lat"`) with an expression generator
   `{"op": "cos", "args": ["lat_k"]}`, not a `per_cell` rule binding.
   The S2 landing bead need not resolve this ambiguity; the design above
   handles either form correctly (metric-array path for lat-lon grids,
   `per_cell` path for rules that carry `cos_lat` as a runtime binding).

4. **Multi-axis non-uniform schemes** (e.g. non-uniform in both `y` and `z`).
   The §6.2.1 rewrite as specified handles one axis at a time; schemes with
   two nonuniform axes require two separate `"dz"` / `"dy"` rewrites.  The
   rewrite pass in `_expand_stencil_entry` should iterate over all nonuniform
   axes and apply the metric rewrite for each.  The S2 landing bead should
   cover the 1D case; 2D non-uniform is a follow-up.
