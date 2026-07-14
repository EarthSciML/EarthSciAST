# ESM Format Specification

**EarthSciML Serialization Format — Version 0.8.0**

## 1. Overview

The ESM (`.esm`) format is a JSON-based serialization format for EarthSciML model components, their composition, and runtime configuration. It serves three primary use cases:

1. **Persistence** — Save and load model definitions to/from disk
2. **Interchange** — Transfer models between Julia, TypeScript/web frontends, Rust, Python, and other languages
3. **Version control** — Produce human-readable, diff-friendly model specifications

ESM is **language-agnostic**. Every model must be fully self-describing: all equations, variables, parameters, species, and reactions are specified in the format itself. A conforming parser in any language can reconstruct the complete mathematical system from the `.esm` file alone, without access to any particular software package.

The single exception to full specification is **data loaders**, which are inherently runtime-specific (file I/O, format adapters, regridding, large external grids) and are therefore referenced by type/name rather than fully defined. There is no in-file registry of arbitrary user-defined functions or operators: every callable invoked from an expression is drawn from the **closed function registry** (Section 9), whose entries are spec-defined with fixed names, signatures, and tolerances. See `docs/content/rfcs/closed-function-registry.md` for the rationale.

### 1.1 Authoring Policy: AST first, registry second, factoring third

Authors and reviewers MUST prefer the built-in expression AST (Section 4) over the closed function registry (Section 9). A `{"op": "fn", ...}` node is justified **only** when the desired primitive cannot be written as a finite closed-form composition of the AST ops in §4.2 — typically because it requires non-AST ingredients (calendar arithmetic, polygon clipping). Anything expressible in finite closed form (powers, polynomials, transcendentals, conditionals, piecewise, clip/clamp) belongs in the AST. Reviewers MUST reject `fn` nodes whose body can be written using existing AST ops; `^`, `min`, `max`, `ifelse`, `sign` and the trig / exp / log family already cover ordinary scalar math.

The closed function registry is **closed**: bindings MUST reject any `fn` node whose `name` is not in the spec-defined set for the file's declared `esm` version. There is no per-file declaration of new functions, no `handler_id` lookup, and no out-of-band runtime registry. Adding a primitive requires a spec rev (see `docs/content/rfcs/closed-function-registry.md` §7).

The full authoring stance, normatively:

> **AST first, registry second, factoring third.**
>
> 1. *AST first.* The closed AST op set in §4 is the primary authoring surface. New mathematics SHOULD be expressible as a finite tree of existing ops.
> 2. *Registry second.* Operations that genuinely cannot be written as AST trees (tabulated lookups, iterative solves, platform adapters) use the closed `fn`-op registry per §9.1; addition is normative spec work, not authoring.
> 3. *Factoring third.* An author MAY name a fixed Expression AST tree as an `expression_templates` entry (§9.6) — declared within a component, or shared from a template-library file and imported (§9.7) — and reference it elsewhere by name with parameter substitution. A template body MAY reference other match-less templates as a statically-checked acyclic DAG that is inlined at load (§9.7.3). Factoring is **not** programming: bodies are fixed AST trees, parameters are pure-syntactic substitution slots, no recursion, no metaprogramming.
>
> Mechanisms that require any capability beyond fixed-tree parameter substitution (conditional includes, generated definitions, computed bindings) are out of scope and require a separate RFC that revisits §1.1.

**File extension:** `.esm`  
**MIME type:** `application/vnd.earthsciml+json`  
**Encoding:** UTF-8

---

## 2. Top-Level Structure

```json
{
  "esm": "0.8.0",
  "metadata": { ... },
  "models": { ... },
  "reaction_systems": { ... },
  "data_loaders": { ... },
  "enums": { ... },
  "function_tables": { ... },
  "coupling": [ ... ],
  "domain": { ... },
  "index_sets": { ... },
  "expression_templates": { ... },
  "expression_template_imports": [ ... ],
  "metaparameters": { ... }
}
```

| Field | Required | Description |
|---|---|---|
| `esm` | ✓ | Format version string (semver) |
| `metadata` | ✓ | Authorship, provenance, description |
| `models` | | ODE-based model components (fully specified) |
| `reaction_systems` | | Reaction network components (fully specified) |
| `data_loaders` | | External data source registrations (by reference) |
| `enums` | | File-local symbol → positive-integer mappings used by the `enum` op to make categorical lookups cross-binding-portable (see Section 9.3) |
| `function_tables` | | Component-scoped sampled function tables — named axes plus literal nested-array data, referenced by the `table_lookup` AST op (see Section 9.5) |
| `coupling` | | Composition and coupling rules |
| `domain` | | The single temporal domain shared by all components (see Section 11) |
| `index_sets` | | Document-scoped registry of named iteration domains (grid axes, categorical dimensions, data-derived sets) referenced by `aggregate` ranges (RFC semiring-faq-unified-ir §5.2) |
| `expression_templates` | | Top-level rewrite rules / templates — the payload of a **template-library file** (§9.7.1). Only valid in a library file; component-local templates stay inside their `model` / `reaction_system` (§9.6.1) |
| `expression_template_imports` | | Ordered imports of template-library files (§9.7.2) — at top level, only valid in a library file layering on other libraries; inside a `model` / `reaction_system` (§9.7.2); or, as **scope-directed injection** into another component's scope, on a §4.7 subsystem-ref edge, a §10 coupling entry, or a §6.6 / §6.7 test / example (§9.7.10) |
| `metaparameters` | | Document-scoped named integers bound at load (import/subsystem edges, loader API, or defaults) and admissible in `index_sets` sizes, `aggregate` dense ranges, and `makearray` regions (§9.7.6) |

Spatial grid geometry is **not** a special top-level concept. Coordinates, extents, spacing, CRS parameters, connectivity, and metric arrays are ordinary data — loaded from a `data_loaders` primitive or declared as variables/parameters — and grid topology and metrics are constructed declaratively with the `aggregate` Functional Aggregate Query op (RFC semiring-faq-unified-ir). The `operators`, `registered_functions`, `grids`, `staggering_rules`, and `discretizations` blocks present in earlier drafts are **removed**.

At least one of `models`, `reaction_systems`, `data_loaders`, or `expression_templates` must be present. A document whose sole top-level component is `data_loaders` is a valid loader-only file — referenceable as a loader subsystem (§4.7). A document whose payload is top-level `expression_templates` is a **template-library file** (§9.7.1) — importable via `expression_template_imports`, and the carrier format of the [EarthSciDiscretizations](../earthscidiscretizations) standard library.

---

## 3. Metadata

```json
{
  "metadata": {
    "name": "FullChemistry_NorthAmerica",
    "description": "Coupled gas-phase chemistry with advection and meteorology over North America",
    "authors": ["Chris Tessum"],
    "license": "MIT",
    "created": "2026-02-11T00:00:00Z",
    "modified": "2026-02-11T00:00:00Z",
    "tags": ["atmospheric-chemistry", "advection", "north-america"],
    "references": [
      {
        "doi": "10.5194/acp-8-6365-2008",
        "citation": "Cameron-Smith et al., 2008. A new reduced mechanism for gas-phase chemistry.",
        "url": "https://doi.org/10.5194/acp-8-6365-2008"
      }
    ]
  }
}
```

**Extension point — `x_esd`.** The `metadata` object is closed (`additionalProperties: false` in the schema) with one reserved escape hatch: the optional `x_esd` property, a free-form JSON object set aside for **downstream-catalog machine-readable metadata** (e.g. the EarthSciDiscretizations rule-library catalog). The schema validates only that `x_esd` is an object. The core spec **never** interprets its contents: core tooling MUST NOT assign meaning to anything inside it, MUST NOT validate or transform it, and MUST preserve it across `parse → emit` like any other metadata field. Downstream catalogs define — and version — their own conventions within it.

---

## 4. Expression AST

Mathematical expressions are the foundation of the format. They are represented as a JSON tree that is unambiguous and parseable in any language without a math parser.

### 4.1 Grammar

```
Expr := number | string | ExprNode
ExprNode := { "op": string, "args": [Expr, ...], ...optional_fields }
```

- **Numbers** are JSON numbers: `3.14`, `-1`, `1.8e-12`
- **Strings** are variable/parameter references: `"O3"`, `"k1"`
- **ExprNodes** are operations

### 4.2 Operators

Every `op` string belongs to one of **two tiers**:

- **Evaluable core (closed).** The operators listed in this section — arithmetic,
  comparisons/booleans, elementary functions, `ifelse`, the calculus form-ops `D`/`ic`, and
  the array/query ops (§4.3) — are implemented directly by every binding's evaluator. This
  set is closed: adding one is a spec change, and each binding pins it as its evaluator's op
  registry.
- **Rewrite-target (open).** Any other `op` identifier — a spatial `D` on a right-hand
  side, the sugar ops `grad`/`div`/`laplacian`/`integral`, or a user op such as
  `godunov_hamiltonian`. A rewrite-target op has **no** evaluator; it MUST be eliminated by
  a rewrite rule (§9.6) before evaluation. Loading is permissive — a file MAY load with
  rewrite-target ops still present (e.g. a coupling or scoping example that never simulates)
  — but one that reaches evaluation/compilation without having been lowered is rejected with
  `unlowered_operator` (§9.6.6). The `op` schema `pattern` only
  rejects malformed strings — the open tier is otherwise unconstrained, so a custom op
  carries its scheme parameters in the `attrs` object rather than in dedicated schema
  fields.

#### Arithmetic

| Op | Arity | Example | Meaning |
|---|---|---|---|
| `+` | n-ary | `{"op": "+", "args": ["a", "b", "c"]}` | a + b + c |
| `-` | unary or binary | `{"op": "-", "args": ["a"]}` | −a |
| `*` | n-ary | `{"op": "*", "args": ["k", "A", "B"]}` | k·A·B |
| `/` | binary | `{"op": "/", "args": ["a", "b"]}` | a / b |
| `^` | binary | `{"op": "^", "args": ["x", 2]}` | x² |

#### Calculus

| Op | Additional fields | Meaning |
|---|---|---|
| `D` | `"wrt": "t"` or a spatial axis | Derivative ∂/∂(`wrt`). `wrt:"t"` is the **structural** time derivative (equation LHS, consumed by system assembly). A spatial `wrt` — or *any* `D` in a right-hand-side expression — is a **rewrite-target** (§9.6.8): lowered to a stencil by a discretization rule, never evaluated directly. |
| `ic` | — | Initial-condition declaration, used as an equation LHS: `ic(u) ~ <initial field>` (§11.4). `args[0]` is the state variable. |

Example: `{"op": "D", "args": ["O3"], "wrt": "t"}` represents ∂O₃/∂t.

`grad`, `div`, `laplacian`, and `integral` are **not** built-in operators — they are optional
**rewrite-target sugar** (open tier, §4.2). `grad(f, dim:x)` is just `D(f, wrt:x)`;
`div`/`laplacian` are sums/compositions of `D` (`div(F)=ΣᵢD(Fᵢ,xᵢ)`,
`laplacian(u)=ΣᵢD(D(u,xᵢ),xᵢ)`); `integral` is a PIDE term. This format ships **no** rewrite
rules for them — the discretization std-lib lives in
[EarthSciDiscretizations](../earthscidiscretizations). See §9.6.8.

The `integral` op encodes a spatial partial integral for use in partial integro-differential equations (PIDEs).
`args[0]` is the integrand expression; `var` names the spatial dimension variable being integrated over;
`lower` and `upper` are `Expression` values giving the integration bounds.

Two modes:
- **Partial / cumulative**: `"upper": "x"` (the spatial variable itself) — produces a field cumulative up to the current
  grid point, e.g. ∫ₓₘᵢₙˣ u(t, x′) dx′.
- **Whole-domain**: both bounds are constants (e.g. `"lower": 0, "upper": 1`) — produces a spatially uniform value;
  consumed via an auxiliary variable plus boundary extraction.

Reference lowering target: MethodOfLines.jl `Integral(x in DomainSets.ClosedInterval(lower, upper))`.
See https://docs.sciml.ai/MethodOfLines/stable/tutorials/PIDE/ for the auxiliary-variable PIDE idiom.
Discretization of the resulting integral term is handled by EarthSciDiscretizations (tracked in esd-yfj).

#### Elementary Functions

`exp`, `log`, `log10`, `sqrt`, `abs`, `sign`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `min`, `max`, `floor`, `ceil`

All take their standard mathematical arguments in `args`. Most are unary (one
scalar argument) except `atan2` (binary) and `min`/`max`, which are **n-ary
with arity ≥ 2** and return the element-wise extremum across all arguments
(left-fold of the binary operator). Conforming bindings MUST reject `min`/`max`
nodes with fewer than two arguments. `min`/`max` are the canonical, AST-level
encoding of clamp / clip / limiter primitives — `clamp(x, lo, hi)` is
`{"op": "min", "args": [hi, {"op": "max", "args": [lo, "x"]}]}` — and reviewers
MUST reject `fn` nodes that only re-implement these in disguise (see §9.2).

The hyperbolic family `sinh`, `cosh`, `tanh` and their inverses `asinh`,
`acosh`, `atanh` are unary, elementwise transcendentals evaluated exactly like
the trigonometric family — no new control primitive. They map to each binding's
standard-library hyperbolic functions (`sinh`/`asinh`/… ≡ Julia `Base`, NumPy
`np.sinh`/`np.arcsinh`/…, Rust `f64`, Go `math`, JS `Math`). Their real-valued
domains follow the usual conventions: `acosh` requires `x ≥ 1` and `atanh`
requires `|x| < 1` (paralleling the `[-1, 1]` domain of `asin`/`acos`). As with
the trigonometric inverses, behavior on out-of-domain inputs is binding-defined
(most bindings propagate their native `NaN`; some raise) and is not constrained
by this spec.

#### Conditionals

| Op | Args | Meaning |
|---|---|---|
| `ifelse` | `[condition, then_expr, else_expr]` | Ternary conditional |
| `>`, `<`, `>=`, `<=`, `==`, `!=` | `[lhs, rhs]` | Comparison (returns boolean) |
| `and`, `or`, `not` | `[a, b]` or `[a]` | Logical operators |

#### Event-specific

| Op | Args | Meaning |
|---|---|---|
| `Pre` | `[var]` | Value of variable immediately before an event fires (see Section 5) |

#### Closed-registry Invocation

| Op | Required extra fields | Meaning |
|---|---|---|
| `fn` | `name` | Invoke a spec-defined closed function. `name` is a dotted module path (e.g. `"datetime.julian_day"`) drawn from the closed registry in Section 9. `args` are the evaluated argument expressions, passed positionally. See Section 4.4. |
| `enum` | — | Resolve a file-local symbolic name to its declared positive integer. `args` is `[enum_name, symbol]`, both string literals; lowering happens at load time. See Section 4.5 and the `enums` top-level block (Section 9.3). |
| `table_lookup` | `table`, `axes` (object); optional `output` | Evaluate a sampled function table from the top-level `function_tables` block. `table` is the table id; `axes` maps each declared axis name to a scalar input expression; `output` selects which output (integer index or named entry) to return. `args` MUST be empty. Lowers at load time to the equivalent `interp.linear` / `interp.bilinear` / `index` form (bit-equivalent). See Section 9.5. |

#### Inline Constants

| Op | Required extra fields | Meaning |
|---|---|---|
| `const` | `value` | Inline literal value embedded in the expression tree. `value` is any JSON value (number, integer, or nested array of numbers/integers); `args` MUST be empty `[]`. Used to carry small inline tables that participate in `index` lookups, `interp.searchsorted` queries, and other AST positions where a JSON array is needed but a bare scalar number won't do. Large arrays belong in `data_loaders`. |

#### Array / Tensor

| Op | Required extra fields | Meaning |
|---|---|---|
| `aggregate` | `output_idx`, `expr` | Functional Aggregate Query node: a semiring aggregate of a product of factors over named index sets. Specializes to Einstein-notation tensor contraction with implicit reductions over non-output indices; its full surface (`semiring`, `from`/`of` ranges, `join`, `distinct`, `key`, `filter`) is specified in RFC semiring-faq-unified-ir. See Section 4.3.1. |
| `makearray` | `regions`, `values` | Block assembly of an array from overlapping sub-region assignments. Later regions overwrite earlier ones. See Section 4.3.2. |
| `index` | — | Element or sub-array access. `args[0]` is the array; `args[1..]` are the index expressions. See Section 4.3.3. |
| `broadcast` | `fn` | Element-wise application of scalar operator `fn` to broadcast-compatible operands. See Section 4.3.4. |
| `reshape` | `shape` | Reshape `args[0]` to the given target shape. See Section 4.3.5. |
| `transpose` | — (optional `perm`) | Axis permutation of `args[0]`. See Section 4.3.5. |
| `concat` | `axis` | Concatenate the operand arrays along the given axis. See Section 4.3.5. |

#### Relational / value-invention & geometry (FAQ companions)

These accompany `aggregate` in Functional Aggregate Query expressions (RFC semiring-faq-unified-ir §5). The relational ops (`skolem`, `rank`) run at build/setup time to invent index values and dense IDs; `argmin`/`argmax` are index-returning reductions; `intersect_polygon` is a geometry kernel leaf.

| Op | Fields | Meaning |
|---|---|---|
| `skolem` | — | Mint a canonical value (a tuple, not a hash) identifying a relation instance — e.g. an undirected edge sorts its endpoints to `(min, max)`; dense IDs then come from `rank`. Build-time value invention. See RFC semiring-faq-unified-ir §5.7. |
| `rank` | — | Assign a dense 0-based ID to each element by its position in the sorted `distinct` sequence of the input. Build-time. See RFC §5.7. |
| `argmin`, `argmax` | `output_idx`, `expr`, `arg` | Index-returning reductions: the index at which the aggregated body attains its minimum / maximum over the contracted index set. |
| `intersect_polygon` | `manifold` | Geometry kernel leaf: the clipped intersection polygon of two cells (a ring of data-dependent length), composed with a `polygon_area` `sum_product` FAQ for conservative regridding (§8.6). |
| `polygon_intersection_area` | `manifold` | Geometry kernel leaf returning the **scalar** overlap area of two cells — the fused `polygon_area ∘ intersect_polygon`. Exposes no ragged clip ring, so a per-pair overlap-area factor `A_ij = polygon_intersection_area(src_i, tgt_j)` is a dense, evaluable `aggregate` (§8.6.1). |
| `true` | — (`args: []`) | Nullary boolean-literal constant — e.g. an always-true join / `filter` predicate. |

### 4.3 Array / Tensor Semantics

Earth-system models frequently need to serialize operations on arrays and tensors — discretized PDEs, matrix multiplies, stencils, index contractions, block assemblies. The array ops listed in Section 4.2 cover these cases. Their data model mirrors [`SymbolicUtils.jl`](https://github.com/JuliaSymbolics/SymbolicUtils.jl)'s `ArrayOp` and `ArrayMaker` (see `src/types.jl`, `src/arrayop.jl`, `src/arraymaker.jl`).

**Implicit dimensions.** Array ops use an *implicit* dimension model: there is no per-variable `dimensions` field on schema variables. Index symbols are local to the enclosing `aggregate` node, and lengths are resolved at runtime from the declared `index_sets` and the shapes of the operand arrays. A given string can be a variable reference in most contexts but serves as an index symbol inside `aggregate.output_idx`, `aggregate.expr`, and `aggregate.ranges` keys. Callers must not rely on cross-node scoping of index symbols.

#### 4.3.1 `aggregate`

An `aggregate` node represents a generalized Einstein-notation expression — the `sum_product` specialization of the Functional Aggregate Query (RFC semiring-faq-unified-ir).

Fields:
- `output_idx`: array. Each entry is either a string (a symbolic index variable) or the integer literal `1` (a singleton dimension that can be inserted for reshape/broadcast, mirroring `@arrayop (i, 1, j, 1) ...`).
- `expr`: a sub-expression. This is the scalar body evaluated at each index point. It may reference any index symbol appearing in `output_idx` plus additional "contracted" index symbols that are reduced away.
- `reduce`: optional string, one of `"+"`, `"*"`, `"max"`, `"min"`. Default `"+"`. Applied to index symbols that appear in `expr` but not in `output_idx`.
- `ranges`: optional object mapping an index symbol name to either a 2-element array `[start, stop]` (unit step) or a 3-element array `[start, step, stop]`. Indices not listed are inferred at runtime from the operand shapes.
- `args`: the input array operands that `expr` references. These are included so that a serializer can attach the operand list without walking `expr`; at runtime they must match the arrays referenced in `expr`.

**Semantics.** Let `O = output_idx` and let `C` be the set of index symbols that occur in `expr` but not in `O`. Then

```
result[O] = reduce over C of expr
```

evaluated with each index taking every value in its inferred (or declared) range.

**Example — matrix multiply `C = A · B`:**

```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
  "expr": {
    "op": "*",
    "args": [
      { "op": "index", "args": ["A", "i", "k"] },
      { "op": "index", "args": ["B", "k", "j"] }
    ]
  },
  "args": ["A", "B"]
}
```

Here `k` is contracted (reduced with the default `+`) while `i` and `j` form the output.

**Example — 2D 5-point Laplacian stencil on `u`:**

```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
  "expr": {
    "op": "+",
    "args": [
      { "op": "index", "args": ["u", { "op": "+", "args": ["i", 1] }, "j"] },
      { "op": "index", "args": ["u", { "op": "-", "args": ["i", 1] }, "j"] },
      { "op": "index", "args": ["u", "i", { "op": "+", "args": ["j", 1] }] },
      { "op": "index", "args": ["u", "i", { "op": "-", "args": ["j", 1] }] },
      { "op": "*", "args": [-4, { "op": "index", "args": ["u", "i", "j"] }] }
    ]
  },
  "ranges": {
    "i": [2, 3],
    "j": [2, 3]
  },
  "args": ["u"]
}
```

The `ranges` entries use the form `[start, stop]` to say that the interior points start at `2` and stop one short of the last index in each direction. More complex offsets are permitted in `expr`; for non-affine offsets the author should declare `ranges` explicitly (see `SymbolicUtils/src/arrayop.jl` § "Axis offsets").

**Example — column-sum reduction:**

```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "reduce": "+",
  "args": ["A"]
}
```

Here `i` is contracted with `+`, yielding `result[j] = Σᵢ A[i, j]`.

#### 4.3.2 `makearray`

A `makearray` node assembles an output array from a sequence of sub-region assignments. It corresponds to `SymbolicUtils.ArrayMaker` / `@makearray`.

Fields:
- `regions`: array of regions. Each region is an array of `[start, stop]` integer pairs, one per output dimension (both endpoints inclusive, following SymbolicUtils convention).
- `values`: array of expressions, same length as `regions`. Each entry fills the corresponding region. A scalar expression is broadcast across the region; an array-valued expression must match the region's shape (excluding singleton dimensions).
- `args`: conventionally `[]` for `makearray` — the operands are carried inside `values`.

**Overlap semantics.** Regions may overlap. When they do, **later entries overwrite earlier ones**. This matches `@makearray`'s documented behavior and is useful for expressing "default fill, then override" patterns.

**Empty and inverted bounds.** A region bound pair `[start, stop]` with `stop == start − 1` is the canonical **empty** bound: the region covers no elements along that dimension, so the whole region contributes nothing to the assembled array and its `values` entry is never consulted. This is a legal, load-clean spelling — it is exactly what a metaparameter-folded interior region (§9.6.8) produces at the minimum admissible extent (`[2, N−1]` at `N = 2` folds to `[2, 1]`, leaving the boundary-face regions to cover the whole axis). A pair with `stop < start − 1` is **inverted** and MUST be rejected at load time with `makearray_region_inverted` (§9.6.6): a further-inverted bound is almost always an authoring error — an interior stencil instantiated below its scheme's minimum extent (`[2, N−1]` at `N = 1` folds to `[2, 0]`) — and silently treating it as empty would hide the defect. The check runs on the expanded, metaparameter-folded form (§9.6.4); bound pairs still carrying open metaparameter expressions inside a template-library body are not checked until they fold at a binding site (§9.7.6).

**Example — 3×3 block-diagonal with corner cells:**

```json
{
  "op": "makearray",
  "regions": [
    [[1, 1], [1, 3]],
    [[2, 2], [1, 3]],
    [[3, 3], [1, 1]],
    [[3, 3], [2, 2]],
    [[3, 3], [3, 3]]
  ],
  "values": [
    "x_row",
    {
      "op": "aggregate",
      "output_idx": [1, "i"],
      "expr": {
        "op": "+",
        "args": [
          { "op": "index", "args": ["y", "i"] },
          { "op": "index", "args": ["z", "i"] }
        ]
      },
      "args": ["y", "z"]
    },
    1,
    { "op": "index", "args": ["z", 1] },
    {
      "op": "aggregate",
      "output_idx": [],
      "expr": {
        "op": "*",
        "args": [
          { "op": "index", "args": ["z", "i"] },
          { "op": "index", "args": ["z", "i"] }
        ]
      },
      "args": ["z"]
    }
  ],
  "args": []
}
```

This mirrors the `@makearray` example in `SymbolicUtils/src/arraymaker.jl`.

#### 4.3.3 `index`

`index` performs array element or sub-array access.

- `args[0]`: the array expression to index.
- `args[1..]`: one index expression per dimension. Each index is an `Expression`, so it may be an integer literal, a symbolic index variable (as a string, when inside an `aggregate.expr`), or a composite expression (e.g. `{ "op": "+", "args": ["i", 1] }` for an offset stencil point).

Non-affine index expressions are legal; it is the author's responsibility to ensure runtime access is in-bounds (cf. `SymbolicUtils/src/arrayop.jl` § "Axis offsets"). Sparsity and other structured-array optimizations are runtime concerns and are not represented in the schema.

A stencil gather of a **const array** (a pre-computed factor: Fornberg weights, mesh connectivity, or a per-cell metric / geometry array) at an out-of-range index resolves per a declared **per-dimension boundary policy** — `periodic` (wrap, `mod1`), `clamp` (edge-extend), or the `error` default (raise `E_TREEWALK_CONSTARRAY_OOB`). This mirrors the grid periodicity honored by a state-variable gather and is normative across bindings; see `CONFORMANCE_SPEC.md` §5.5.5.

#### 4.3.4 `broadcast`

`broadcast` applies a scalar operator element-wise to one or more broadcast-compatible arrays. The operator is named in the `fn` field; the operands are in `args`.

```json
{
  "op": "broadcast",
  "fn": "+",
  "args": ["A", "B"]
}
```

The `fn` value must name a scalar operator (arithmetic, elementary function, comparison, etc.). Broadcasts do not fuse: a nested expression of broadcasts decomposes into primitive broadcast nodes. Runtimes are free to apply their own fusion.

#### 4.3.5 `reshape`, `transpose`, `concat`

**`reshape`.** `args[0]` is the array; `shape` is the target shape. Each entry of `shape` is an integer (concrete length) or a string (a symbolic length reference — resolved at runtime against the domain or operand shapes). The total number of elements must be preserved.

```json
{ "op": "reshape", "args": ["A"], "shape": [1, 9] }
```

**`transpose`.** `args[0]` is the array. The optional `perm` field gives the axis permutation as a list of 0-based axis indices. If `perm` is omitted, the convention is to reverse the axes (classic matrix transpose for 2D).

```json
{ "op": "transpose", "args": ["A"], "perm": [1, 0] }
```

**`concat`.** Concatenates the operand arrays along `axis` (0-based). All operands must have identical shape on every axis other than `axis`.

```json
{ "op": "concat", "args": ["A", "B"], "axis": 0 }
```

#### 4.3.6 Out of Scope

The following are intentionally *not* represented in the schema:

- Custom user-defined reduction operators (only `+`, `*`, `max`, `min` are supported).
- Sparsity patterns and structured-array metadata — these are runtime concerns.
- Broadcast fusion — handled by the runtime, not the serialization.
- The `term` optimization hint on `SymbolicUtils.ArrayOp` (a pre-computed array-valued form used to short-circuit codegen). It is an optimization cache, not part of the mathematical semantics, and is recomputed at load time.

### 4.4 Closed Function Invocation (`fn`)

The `fn` op invokes a function from the **closed function registry** defined in Section 9. The set of valid `name` values is fixed by the spec version: bindings MUST reject `fn` nodes whose `name` is not in the registry for the file's declared `esm` version. There is no per-file declaration of new functions and no `handler_id` lookup. See `docs/content/rfcs/closed-function-registry.md` for the rationale and addition process.

Fields:

- `op`: `"fn"`.
- `name`: string. Dotted module path of a function declared in Section 9 (e.g. `"datetime.julian_day"`, `"interp.searchsorted"`).
- `args`: array of sub-expressions. Evaluated in the current context and passed positionally to the named function.

**Semantics.** `name` resolves at load time to a spec-pinned implementation contract — argument types, return type, boundary semantics, and tolerance are defined in the registry entry (Section 9). Each binding ships a built-in implementation that satisfies the contract; the conformance suite verifies cross-binding agreement against per-function reference outputs. The return value takes the place of the `fn` node in the enclosing expression. All registry entries are **pure**: same inputs → same output, no hidden state.

**Validation.** A schema-valid `fn` node must carry a `name` listed in the §9 registry table for the file's `esm` version. Bindings MUST emit an `unknown_closed_function` error when this invariant is violated; loading MUST fail. Argument arity and type compatibility are checked against the registry entry's signature.

**Example — Julian day from UTC time:**

```json
{
  "op": "fn",
  "name": "datetime.julian_day",
  "args": ["t_utc"]
}
```

**Example — table search as a categorical index:**

```json
{
  "op": "index",
  "args": [
    "deposition_table",
    { "op": "fn",
      "name": "interp.searchsorted",
      "args": ["sza", { "op": "const", "value": [0.0, 0.5, 1.0, 1.5] }] }
  ]
}
```

### 4.5 Enum References (`enum`)

The `enum` op resolves a file-local symbolic name to its declared positive integer. It is the spec's mechanism for cross-binding-portable categorical lookups: authors keep human-readable names in the source file (`"summer"`, `"deciduous_forest"`), while bindings only ever see the resolved integers downstream of load.

Fields:

- `op`: `"enum"`.
- `args`: a 2-element array `[enum_name, symbol]`, both JSON string literals (not sub-expressions). `enum_name` MUST match a key in the top-level `enums` block (Section 9.3); `symbol` MUST match a key declared under that enum.

**Semantics.** Lowered at load time to the corresponding positive integer constant, equivalent to a `{"op": "const", "value": <integer>}` node. Bindings MUST reject references to undeclared enums or undeclared symbols within an enum at load time, with diagnostic codes `unknown_enum` and `unknown_enum_symbol` respectively.

**Example — categorical index into a tabulated coefficient array:**

```json
{
  "op": "index",
  "args": [
    "r_c_table",
    { "op": "enum", "args": ["land_use_class", "deciduous_forest"] },
    { "op": "enum", "args": ["season", "summer"] }
  ]
}
```

After load this lowers to `{"op": "index", "args": ["r_c_table", 3, 3]}` — the bindings see only integers and never need to know the symbolic vocabulary.

### 4.6 Scoped References

Variables are referenced across systems using **hierarchical dot notation**. Systems can contain subsystems to arbitrary depth, and the dot-separated path walks the hierarchy from the top-level system down to the variable:

```
"System.variable"              →  variable in a top-level system
"System.Subsystem.variable"    →  variable in a subsystem of a top-level system
"A.B.C.variable"               →  variable in A → B → C (nested subsystems)
```

The **last** segment is always the variable (or species/parameter) name. All preceding segments are system names forming a path through the subsystem hierarchy. For example:

| Reference | Meaning |
|---|---|
| `"SuperFast.O3"` | Variable `O3` in top-level model `SuperFast` |
| `"SuperFast.GasPhase.O3"` | Variable `O3` in subsystem `GasPhase` of model `SuperFast` |
| `"Atmosphere.Chemistry.FastChem.NO2"` | Variable `NO2` in `Atmosphere` → `Chemistry` → `FastChem` |

**Resolution algorithm:** Given a scoped reference string, split on `"."` to produce segments `[s₁, s₂, …, sₙ]`. The final segment `sₙ` is the variable name. The preceding segments `[s₁, …, sₙ₋₁]` form a path: `s₁` must match a key in the top-level `models`, `reaction_systems`, or `data_loaders` section, and each subsequent segment must match a key in the parent system's `subsystems` map. There is **no depth limit**, and a resolver MUST walk every segment — see §4.9.2 for the two-segment shortcut this rules out.

**Bare references** (no dot) refer to a variable within the current system context. In coupling entries, all references must be fully qualified from the top-level system name.

### 4.7 Subsystem Inclusion by Reference

Subsystems can be defined inline (as described in Sections 6 and 7) or included by reference from an external ESM file. A reference is an object with a `ref` field containing a local file path or URL, and optionally a `bindings` field closing the referenced document's metaparameters (§9.7.6):

```json
{
  "subsystems": {
    "Atmosphere": { "ref": "./atmosphere.esm" },
    "Ocean": { "ref": "https://example.com/models/ocean.esm" },
    "Land": {
      "variables": { ... },
      "equations": [ ... ]
    }
  }
}
```

In the example above, `Atmosphere` and `Ocean` are included by reference while `Land` is defined inline. Both forms can be freely mixed within the same `subsystems` map.

A subsystem may be a child **model**, a child **reaction system**, or a pure-I/O **data loader** (RFC pure-io-data-loaders §4.3). A loader subsystem — declared inline or included by reference — exposes its variables to the owning model under the existing dot-notation (`ParentModel.Loader.var`); the owning model is responsible for any reprojection or regridding of those variables (the loader itself performs neither). A loader subsystem has no `subsystems` of its own.

**Reference format:**

| Form | Example | Resolution |
|---|---|---|
| Relative path | `"./atmosphere.esm"` | Resolved relative to the directory of the referencing file |
| Absolute path | `"/models/atmosphere.esm"` | Used as-is |
| HTTP/HTTPS URL | `"https://example.com/models/atmosphere.esm"` | Fetched from the network |

A ref MAY contain `${VAR}` tokens (e.g. `"${ESD_ROOT}/grids/cartesian_uniform_1d/stencils/upwind1_D_interior.esm"`), expanded from the loader's environment **before** the resolution above — the mechanism for referencing a sibling library repository checked out at a deployment-chosen path. Expansion is an **OPTIONAL** capability, on the same footing as URL refs: only the braced `${VAR}` form is expanded (not bare `$VAR`); an **unset** variable is left literal, so the ref fails to resolve with the ordinary unresolved diagnostic (`template_import_unresolved` / the subsystem-ref error) rather than misresolving; and a binding without the capability treats `${VAR}` as a literal path segment, i.e. the same clean unresolved failure. Expansion applies equally to subsystem refs and template-import refs (§9.7.2). Current bindings: **Julia** and **Python** expand `${VAR}` in both mechanisms; **TypeScript**, **Rust**, and **Go** do not yet (a `${VAR}` ref fails as unresolved there). Because expansion feeds resolution, an expanded relative ref anchors against the referencing file's directory and an expanded absolute/URL ref is used as-is.

**URL (remote) references are an OPTIONAL binding capability.** Fetching `http(s)` refs is not required for conformance. A binding without remote support MUST reject a URL ref **cleanly** with the existing unresolved diagnostics — `template_import_unresolved` for a template import (§9.7.2), the subsystem-ref resolution error here — never by silently skipping or misresolving it. A binding that does support URLs MUST treat a URL-loaded document as the base for that document's own relative refs: they resolve by URL joining against the document's URL directory (RFC 3986 relative resolution over the forms above), and cycle detection treats URL identity **canonically** (dot segments removed, relative spellings joined against the base before comparison). Current bindings: **Julia** supports URL refs for both subsystem refs and template imports, including URL-base joining of nested relative refs and canonical-URL cycle detection; **TypeScript** fetches remote subsystem refs (with a remote base for recursive resolution) but rejects remote template-library imports with `template_import_unresolved`; **Rust** rejects remote refs in both mechanisms; **Python** and **Go** fetch both, but do not yet URL-base join relative refs inside a URL-loaded document (such refs fail as unresolved).

**Referenced file requirements (model, reaction-system, or data-loader subsystems):**

- The referenced file must be a valid ESM file (with `esm` version and `metadata` fields).
- It must contain exactly one top-level model, reaction system, or data loader and must NOT carry a `"kind"` field (absence of `"kind"` identifies a subsystem file). The single model, reaction system, or data loader defined in the file is used as the subsystem definition. Because the file is single-component, no fragment selector is required.
- A file whose sole top-level component is `data_loaders` (with exactly one entry) is itself a valid ESM document and is referenceable as a loader subsystem; this is the structural reason a co-located `model + loader` is split into separate files when the loader must be shared by reference.
- The subsystem key in the parent file determines the subsystem's name, not any name in the referenced file.

**Index-set merge (mirrors §9.7.5).** A referenced subsystem file's top-level `index_sets` merge into the importing **document's** document-scoped registry at resolution time, after the referenced document's metaparameters are closed and folded (a subsystem edge's `bindings` bind first, then defaults — §9.7.6 site 3). Deep-equal redeclaration is idempotent; a non-equal collision — the same name reaching the registry with a different definition, e.g. a mounted mesh file whose `cells` size disagrees with the importer's declaration — is a load-time error, `subsystem_index_set_conflict` (§9.6.6). This is what makes the mounted-mesh pattern sound: the importing model's variables may be shaped over the mesh file's axes without redeclaring them, the mesh file stays the source of truth for its own sizes, and a disagreement between an importer's declaration (or another mounted file's) and the mesh fails loudly at load instead of silently resolving against whichever declaration the binding happened to keep. The merge composes transitively: a mounted file's registry already contains whatever its own subsystem refs merged in.

**Scoped references** work identically for referenced subsystems as for inline subsystems. After resolution, `"Parent.RefSubsystem.variable"` works the same regardless of whether `RefSubsystem` was defined inline or loaded from a reference.

**Resolution timing:** Libraries must resolve all references at load time, before validation or any other processing. After resolution, the in-memory representation is identical to a file with all subsystems defined inline.

**Relation to template imports (§9.7):** `expression_template_imports` reuses this section's reference formats and resolution-timing rule but is a distinct mechanism with a distinct target kind. A subsystem `ref` MUST NOT target a template-library file (`subsystem_ref_is_template_library`), and a template import MUST NOT target a subsystem/component file (`template_import_not_library`).

**Injecting a discretization at the mount (§9.7.10).** A subsystem-ref object MAY additionally carry an `expression_template_imports` array — an ordered `TemplateImport[]` (§9.7.2 shape) registered into the **referenced** component's own template scope, so an assembler can choose the discretization for a mounted, discretization-agnostic PDE leaf without editing that leaf's file. The target is implicit (this edge mounts exactly one component); no selector is needed or allowed. It composes with the edge's other fields: `bindings` still closes the *referenced document's* metaparameters (site 3 above), while `expression_template_imports[k].bindings` closes the *imported library's* metaparameters (e.g. the stencil's grid size), and the injected list appends to the referenced component's own imports in the §9.7.10 merge order. Load-time only, consumed by the §9.6.3 fixpoint before the mounted form is finalized; it does not survive `parse → emit`. The injected `ref` MUST resolve to a template-library file (`template_import_not_library` otherwise); the subsystem `ref` itself still MUST resolve to a component file.

### 4.8 Units and Dimensional Analysis

Every `units` string in a document (variables, parameters, species, loader `provides`) is resolved against **one shared registry** with **one grammar**, and every dimensional judgement follows **one severity contract**. This section is normative. Before it existed, each binding invented its own answers and the five silently diverged — the units subsystem was broken in four of the five bindings, in four different ways, and no cross-binding test could see it because nothing was written down.

#### 4.8.1 The unit registry

**The eight canonical dimension axes.** A dimension is a vector of rational exponents over **exactly these eight axes and no others**:

```
m    kg    s    mol    K    A    cd    rad
```

A binding MUST NOT introduce a ninth axis, and MUST NOT map a registry symbol onto an axis the table below does not give it. This is pinned because it has been violated: one binding delegated the registry to a general-purpose units library, which typed the count noun `molec` as an *amount of substance* (`mol`) and the count noun `units` as **micro-nit — a luminance** — so a clinical concentration `units/L` resolved to `cd·m⁻⁵`. A general-purpose units library MAY be used as the arithmetic engine, but it MUST be constrained to this table and these axes.

**The registry is a flat table**: a symbol is either in it, exactly as spelled, or the unit string does not resolve. There is deliberately **no SI-prefix mechanism** — `mm` is a table entry, not `m` composed with `milli-`. A prefix rule would silently accept nonsense (`kmolec`, `nppb`), make the set of legal unit strings unbounded and un-pinnable across five languages, and reintroduce the prefix collisions the flat table avoids (`T` = tesla or tera? `M` = molar or mega?). The cost is that a new prefixed unit must be added to the table; that is a one-line change and a deliberate one. A binding whose underlying units library *does* have a prefix mechanism (pint, uom, Unitful) MUST disable it or gate lookups on this table.

| Group | Symbols |
|---|---|
| SI base | `m` `kg` `s` `mol` `K` `A` `cd` `rad` |
| Mass | `g` `mg` `ug` |
| Length | `dm` `cm` `mm` `um` `nm` `km` |
| Time | `ms` `us` `ns` `min` `h` `hr` `day` `yr` `year` |
| Volume | `L` `l` `mL` |
| Amount | `kmol` `mmol` `umol` `nmol` `M` |
| Derived | `Hz` `N` `Pa` `J` `kJ` `cal` `kcal` `W` `kW` `MW` |
| Pressure | `atm` `uatm` `bar` `hPa` `kPa` `mbar` `Torr` `mmHg` `psi` |
| Energy | `erg` `BTU` `Wh` `kWh` |
| Electromagnetic | `C` `V` `Ohm` `F` `T` |
| Temperature / angle | `degC` `degF` `deg` |
| Mixing ratios (dimensionless) | `ppm` `ppb` `ppt` `ppmv` `ppbv` `pptv` |
| Fractions (dimensionless) | `%` (scale 0.01) · `psu` (scale 1 — practical salinity is a pure number by definition) |
| Counts (dimensionless) | `molec` `molecule` `individuals` `vehicles` `units` `count` |
| Column amount | `Dobson` `DU` |
| Long-form aliases | `meter` `meters` → `m` · `hour` → `h` · `Celsius` → `degC` · `percent` → `%` · `degree` `degrees` → `deg` |
| Dimensionless spellings | `""` · `"1"` · `"dimensionless"` |

**Unit strings carry DIMENSIONS ONLY — never species tags.** A trailing chemical species is NOT part of a unit. `"kg C/m^2"` for "kilograms of carbon per square metre" is ILLEGAL: whitespace is multiplication (§4.8.2), so it parses as kg·coulomb·m⁻², a *silently wrong dimension* rather than an error, and no checker can catch it. The same trap holds for `"kg N/ha"`, `"mg C/m^3/d"`, `"ug S/m^3"`. **The species belongs in the variable's name or `description`; the unit is `"kg/m^2"`.**

```json
{ "carbon_pool": { "type": "state", "units": "kg/m^2",
                   "description": "Total soil carbon pool (kilograms of CARBON per m^2)" } }
```

**Counts are DIMENSIONLESS.** `molec`, `molecule`, `count`, `individuals`, `vehicles`, `units` carry NO dimension — not `mol`, not `cd`. A count is a pure number; `molec/cm^3` is a number density with dimension `m^-3`, and `cm^3/(molec*s)` is the second-order rate constant that pairs with it.

**`C` is the COULOMB**, per SI — never Celsius. Celsius has its own unambiguous spellings (`degC`, `°C`, `Celsius`); binding `C` to Celsius silently injects a temperature dimension into every electromagnetic expression, so that charge × field comes out as `kg*m*K/(s^3*A)` instead of a newton.

**The Dobson unit is `2.6867e20 molec/m^2`** — with counts dimensionless, `DU` has **dimension `m^-2`** and **scale exactly `2.6867e20`**. It is a column thickness of 10 µm of pure ozone at STP, so its magnitude is the Loschmidt constant (2.6867811e25 m⁻³ at 273.15 K, 101325 Pa) times 10⁻⁵ m. `Dobson` is a spelling of the same entry. The value is pinned to five significant figures because two bindings shipped *different* roundings (2.6867e20 and 2.69e20) and one of them then compared conversions to a 1e-9 tolerance — so the same file produced a unit error in one binding and not in the other. A binding MUST use `2.6867e20`.

**Affine offsets are not modelled.** `degC` and `degF` carry the Kelvin *dimension* and their *scale* (1 and 5/9); their zero offset is irrelevant to dimensional analysis and is not represented. A unit conversion that needs the offset is a `unit_conversion` expression (§8), not a dimensional judgement.

#### 4.8.2 Unit-string grammar

**Unicode normalisation is MANDATORY and happens BEFORE parsing.** These spellings are ordinary in the literature and in real model metadata (`W/m²`, `J/(kg·K)`, `µg/m^3`, `°C`), and they currently fail in every binding. A conforming parser rewrites the string first, then applies the grammar:

| From | To | Example |
|---|---|---|
| Superscript digits `⁰¹²³⁴⁵⁶⁷⁸⁹` | `^n` | `m²` → `m^2`, `cm³` → `cm^3` |
| Superscript minus `⁻` | `^-` (with the following superscript digits) | `s⁻¹` → `s^-1` |
| Middot `·` (U+00B7) and dot operator `⋅` (U+22C5) | `*` | `J/(kg·K)` → `J/(kg*K)`, `kg⋅m/s` → `kg*m/s` |
| Micro sign `µ` (U+00B5) and Greek mu `μ` (U+03BC) | `u` | `µg/m^3` → `ug/m^3` |
| `°C` | `degC` | `°C/min` → `degC/min` |
| `°F` | `degF` | |
| Ohm sign `Ω` (U+2126) and Greek omega `Ω` (U+03A9) | `Ohm` | `Ω*m` → `Ohm*m` |

Superscripts normalise **positionally**: a run of `⁻`? followed by superscript digits becomes `^` + the ASCII transliteration of that run.

**The grammar**, applied to the normalised string:

```
unit     := term (('*' | '/')? term)*
term     := atom (('^' | '**') exponent)?
exponent := integer | decimal | '(' integer '/' integer ')'
atom     := number | symbol | '(' unit ')'
```

- **Exponents are RATIONAL, not integer.** `2`, `-1`, `0.5`, `1.5`, `(1/2)` are all admissible. An integer-only grammar cannot express `1/s^0.5` — the intensity of a Wiener noise term, which is the unit of every `brownian` variable in an SDE (`tests/fixtures/sde/*.esm`) — and under the §4.8.4 hard-error severity an integer-only parser would FALSELY REJECT every conforming SDE file in the corpus. A *symbolic* exponent in a unit string remains inadmissible; a symbolic exponent in an *expression* is a different case (§4.8.4).
- **Whitespace between terms means MULTIPLICATION**, as in pint and UDUNITS — `"ppb^-1 s^-1"` is `ppb⁻¹·s⁻¹`. This is what makes a species tag (§4.8.1) illegal rather than merely discouraged.
- **`*` and `/` are ONE precedence level, evaluated LEFT to RIGHT.** `"J/mol*K"` is `(J/mol)*K` = `J·mol⁻¹·K`, NOT `J/(mol·K)`. A parser that gives `*` a higher precedence than `/` silently negates the exponent of every symbol after the first `/` — it read `J/mol*K` as `J·mol⁻¹·K⁻¹` — and, because the result is a *plausible* dimension, nothing downstream can detect it. Likewise `"kg/m*s"` is `kg·m⁻¹·s`, and `"L/mol/s"` is `L·mol⁻¹·s⁻¹`.
- **Parentheses are REQUIRED for a compound denominator**: `"J/(mol*K)"`, `"cm^3/(molec*s)"`. A parser that cannot handle parentheses reads `J/(mol*K)` as dimensionless and silently disables every check downstream of it.
- A `symbol` is a maximal run of characters that is a §4.8.1 table key. Table keys are alphanumeric with two exceptions — `%` and the empty string — so a lexer MUST admit `%` as a symbol token (`"%"`, `"%/h"`).
- A digit run that is NOT separated from a symbol by `^`/`**` is a *different symbol*, not an implicit exponent: `"cm3"` and `"m/s2"` do not resolve (`cm3` is not a table key). Write `"cm^3"`, `"m/s^2"`.

#### 4.8.3 Dimensional rules for operators

| Op | Rule |
|---|---|
| `+` `-` (n-ary) | All operands MUST share a dimension; the result is that dimension. A bare numeric literal is dimension-neutral in this position. |
| `*` `/` | Dimensions multiply / divide. |
| `^` | The exponent MUST be dimensionless. With a **literal integer or rational** exponent the base dimension is raised to it (`L^2` with `L` in `m` is `m^2`). With a **symbolic** exponent the result is UNDETERMINABLE (§4.8.4) — not dimensionless. |
| `sqrt` | **HALVES** every exponent of the operand's dimension — `sqrt(x)` with `x` in `m^2/s^2` is `m/s`. `sqrt` is NOT a transcendental and MUST NOT be given the dimensionless-argument rule; a checker that lists it with `log`/`exp` rejects the ordinary spelling of a wave speed or an RMS. |
| `D` (`wrt: t`) | `d(X)/dt` has dimension `[X]/[t]`. |
| `min` `max` `abs` `ifelse` `Pre` | PRESERVE the operand dimension (all value operands must agree); they are not dimensionless. |
| comparisons, `and` `or` `not` | Operands must be mutually commensurate; the result is dimensionless (a boolean). |
| **Transcendentals** | The argument MUST be **dimensionless**, and the result is dimensionless. The set is EXACTLY: `ln` `log` `log10` `exp` `sin` `cos` `tan` `asin` `acos` `atan` `sinh` `cosh` `tanh` `asinh` `acosh` `atanh` — sixteen ops, and no others. It is a CLOSED list, not a category to be extended by intuition: `sqrt`, `abs`, `min`, `max` are not members and have their own rules above. |
| any other op | No dimensional rule ⇒ the result is UNDETERMINABLE (§4.8.4). It is **not** dimensionless. |

**Transcendentals require a dimensionless argument.** `log(V)` with `V` in `m³` is an ERROR, not a warning and not a silent pass: the Taylor series of a transcendental adds powers of its argument, so an argument with a dimension is dimensionally meaningless. The physics is always written against a reference: the ideal-gas entropy is `n*R*log(V/V0)`, and Arrhenius is `exp(-Ea/(R*T))` — never `exp(-1000/T)` with a bare literal standing in for an activation temperature. `tests/invalid/units_invalid_logarithm.esm` pins the error; `tests/valid/units_dimensional_analysis.esm` and `tests/valid/expr_graphs_variable_deps.esm` pin the well-formed spellings.

#### 4.8.4 Severity contract

Three outcomes, and only three. The distinction that matters is between *"the file is wrong"* and *"the checker cannot tell"* — collapsing the two is what let the bindings diverge.

| Outcome | Severity | Code | When |
|---|---|---|---|
| **Provable dimensional mismatch** | **hard error** (`is_valid: false`) | `unit_dimension_mismatch` (emitted as `unit_inconsistency` by the structural layer) | Every operand dimension is known and the §4.8.3 rule is violated: adding metres to kilograms, a derivative whose two sides cannot be reconciled by any time unit, a transcendental with a dimensional argument, an observed variable whose declared units disagree with its expression, a reaction rate that does not match its stoichiometric order (§7.4). |
| **Unresolvable unit string** | **hard error** (`is_valid: false`) | `unit_parse_error` | The declared string does not parse under §4.8.2, or names a symbol absent from the §4.8.1 registry — `"not_a_unit"`, `"1/time"` (`time` is a DIMENSION name, not a unit), `"m/s2"`. This is a defect in the file, not a limit of the checker. |
| **Undeterminable dimension** | **warning**; report `unknown` and SKIP the enclosing check | — | The checker genuinely cannot compute a dimension: a **symbolic exponent** (`k * x^alpha` — a fitted reaction order is ordinary chemistry), an **op with no dimensional rule**, or an operand naming an **undeclared or out-of-scope** variable. |

Two consequences follow, and both have been violated in this repository:

1. **An undeterminable dimension MUST NOT be reported as dimensionless.** Returning "dimensionless" for an op the checker does not model manufactures *false* mismatches against real, well-formed files — every structural op (`index`, `fn`, `aggregate`, `table_lookup`, `makearray`, …) would poison the equation containing it. Return "unknown" and skip.
2. **An incomplete registry MUST NOT be papered over by downgrading the severity.** If a binding cannot parse `J/(mol*K)` or does not know `V`, the fix is the parser and the registry — *not* re-classifying an unresolvable unit as a warning, and not coercing it to dimensionless. Both of those turn a missing feature into a silently-disabled check across every file in the corpus.

An error is reported at the **JSON Pointer of the node that carries the defect** — `/models/<M>/equations/<i>` for an equation, `/models/<M>/variables/<v>` for an observed variable or a declaration, `/reaction_systems/<S>/reactions/<i>` for a rate.

### 4.9 Name Resolution: what a checker MUST NOT call undefined

`undefined_variable`, `undefined_parameter`, `event_var_undeclared` and `unresolved_scoped_ref` are hard errors, so every symbol this section declares to be **in scope** is a symbol a checker MUST resolve. Each rule below is pinned because a binding got it wrong and rejected a conforming file in the shared corpus.

#### 4.9.1 Implicitly-declared symbols

Three classes of symbol are in scope in a model's expressions **without appearing in its `variables` map**. None of them is an `undefined_variable`.

| Symbol | Where it comes from | Pinned by |
|---|---|---|
| **The independent variable** — `domain.independent_variable`, default `"t"` | §11.3. Every time-dependent model may write `t` in an equation, a condition, or an event affect; an analytic forcing `A*sin(omega*t)` is the ordinary spelling. Its dimension is the time dimension (`s`). | `tests/valid/cadence/pure_pointwise.esm` |
| **Spatial coordinate names** | §11.4. A coordinate expression's free symbols name spatial coordinates: `x`, `y`, `z`, `lon`, `lat`, `lev`. A checker resolves as a coordinate any free symbol that is (i) a key of `index_sets`, (ii) the `dim` of a spatial differential operator (`grad`, `div`, `curl`, `laplacian`) anywhere in the document, or (iii) a free symbol in the RHS of an `ic` equation — which §11.4 *defines* to be a coordinate expression. Its dimension is the coordinate's; where undeclared, treat it as `unknown` (§4.8.4), never as an error. | `tests/valid/initial_conditions/expression_ignition_front_1d.esm`, `tests/spatial/*.esm` |
| **`_var`** | §6.4. The operator-model placeholder, substituted with each matching state variable of the target system at `operator_compose` time. It is legal **wherever a state variable is legal** — including an equation LHS/RHS, a continuous-event `affects` / `affect_neg` LHS, and a `functional_affect`'s `read_vars`. A checker MUST NOT emit `event_var_undeclared` for `_var` in a model that is operator-composed or that is a coupling target. | `tests/valid/full_coupled.esm` |

#### 4.9.2 Scoped references are ARBITRARY DEPTH

§4.6 defines a scoped reference as a dot path of unbounded length: `A.B.C.variable` walks `A` → `B` → `C`. A resolver MUST **walk** the path — take the last segment as the name and resolve the preceding segments one at a time against each parent's `subsystems` map.

A resolver MUST NOT split on `"."` and treat segment `[0]` as the system and segment `[1]` as the variable. That two-segment shortcut turns every three-or-more-segment reference in the corpus into a spurious `unresolved_scoped_ref` (`"Meteorology.Temperature.surface_temp"` is reported as *variable `Temperature.surface_temp` not found in system `Meteorology`*), and it is the single defect behind the scoped-reference rejections in `tests/valid/scoped_refs_coupling.esm`, `tests/scoping/deep_nesting_scoped_references.esm`, `tests/scoping/hierarchical_scoped_references.esm` and `tests/scoping/scoped_reference_resolution.esm`.

The same walk applies to the **system** position of a coupling entry (`systems`, `from`, `to`): `"EarthSystem.Atmosphere.Chemistry"` names a subsystem three levels down, not a nonexistent top-level system (`undefined_system`).

#### 4.9.3 Where a scoped reference may appear

Anywhere an expression may name a symbol. In particular a **reaction `rate` expression MAY contain scoped references** — a rate that depends on a coupled system's temperature or photolysis rate (`"MeteorologicalSystem.solar_intensity"`, `"AtmosphericChemistry.O3"`) is ordinary atmospheric chemistry, and is exactly what `tests/valid/events_cross_system.esm` exists to pin. A checker that resolves a rate's free symbols against the *local* reaction system's species and parameters only, and reports `undefined_parameter` for anything dotted, is wrong.

#### 4.9.4 Equation balance (`equation_count_mismatch`)

The check is **unknowns vs equations**, not *state variables vs time-derivative equations*.

- An equation is **credited** whichever form its LHS takes: a derivative LHS (`D(x)/dt ~ …`), a bare-variable LHS (`x ~ …`, an observed/algebraic equation), or an **expression LHS** (`H*H*SO4 ~ Ksp`, an implicit algebraic constraint). A checker that credits only a *bare-variable derivative* LHS undercounts every algebraic equation in the system.
- For `system_kind: "nonlinear"` (algebraic equilibrium — no time derivative at all) and for the algebraic block of a DAE, the balance is between the **unknowns** (the `state` variables) and the **equations**, of any form. `tests/valid/nonlinear_isorropia_shape.esm` declares two states (`H`, `SO4`) and two algebraic equations (`H ~ …` and `H*H*SO4 ~ Ksp`) and is BALANCED; a checker that reports "1 ODE equation, 2 state variables" has miscounted, not found a defect.
- `initialization_equations` (§6.2) are a *separate* block with a separate balance and MUST NOT be counted into the main one.

## 5. Events

Events enable changes to system state or parameters when certain conditions are met, or detection of discontinuities during simulation. This section is designed to be compatible with ModelingToolkit.jl's `SymbolicContinuousCallback` and `SymbolicDiscreteCallback` semantics, while remaining language-agnostic.

Events are defined within `models` and `reaction_systems` via the `continuous_events` and `discrete_events` fields. They can also be attached at the coupling level for cross-system events.

### 5.1 Core Semantics: `Pre` and Affect Equations

Event affects (the state changes that occur when an event fires) use a **pre/post** convention for distinguishing values before and after the event:

- The **left-hand side** of an affect equation is the value *after* the event
- `Pre(var)` refers to the value *before* the event
- A variable that does not appear on the LHS of any affect equation is free to be modified by the runtime to maintain algebraic consistency (e.g., in DAE systems)

For example, to increment `x` by 1 when the event fires:

```json
{ "lhs": "x", "rhs": { "op": "+", "args": [{ "op": "Pre", "args": ["x"] }, 1] } }
```

The `Pre` operator is added to the expression AST:

| Op | Args | Meaning |
|---|---|---|
| `Pre` | `[var]` | Value of `var` immediately before the event fired |

### 5.2 Continuous Events

Continuous events fire when a **condition expression crosses zero**. The runtime uses root-finding to locate the precise crossing time. This corresponds to MTK's `SymbolicContinuousCallback` and DifferentialEquations.jl's `ContinuousCallback`.

```json
{
  "continuous_events": [
    {
      "name": "ground_bounce",
      "conditions": [
        { "op": "-", "args": ["x", 0] }
      ],
      "affects": [
        {
          "lhs": "v",
          "rhs": { "op": "*", "args": [-0.9, { "op": "Pre", "args": ["v"] }] }
        }
      ],
      "affect_neg": null,
      "root_find": "left",
      "description": "Ball bounces off ground at x=0 with 0.9 coefficient of restitution"
    },

    {
      "name": "wall_bounce",
      "conditions": [
        { "op": "-", "args": ["y", -1.5] },
        { "op": "-", "args": ["y", 1.5] }
      ],
      "affects": [
        {
          "lhs": "vy",
          "rhs": { "op": "*", "args": [-1, { "op": "Pre", "args": ["vy"] }] }
        }
      ],
      "description": "Bounce off walls at y = ±1.5"
    },

    {
      "name": "discontinuity_detection",
      "conditions": [
        { "op": "-", "args": ["v", 0] }
      ],
      "affects": [],
      "description": "Detect velocity zero crossing for friction discontinuity (no state change)"
    }
  ]
}
```

#### Continuous Event Fields

| Field | Required | Description |
|---|---|---|
| `name` | | Human-readable identifier |
| `conditions` | ✓ | Array of expressions. Event fires when any expression crosses zero. |
| `affects` | ✓ | Array of `{lhs, rhs}` affect equations. Empty array `[]` for pure detection (no state change). |
| `affect_neg` | | Separate affects for negative-going zero crossings. If `null` or absent, `affects` is used for both directions. |
| `root_find` | | Root-finding direction: `"left"` (default), `"right"`, or `"all"`. Maps to DiffEq `rootfind` option. |
| `reinitialize` | | Boolean. Whether to reinitialize the system after the event (default: `false`). |
| `description` | | Human-readable description |

#### Direction-dependent Affects

When a continuous event needs different behavior for positive vs. negative zero crossings (e.g., hysteresis control, quadrature encoding), use `affect_neg`:

```json
{
  "name": "thermostat",
  "conditions": [
    { "op": "-", "args": ["T", "T_setpoint"] }
  ],
  "affects": [
    {
      "lhs": "heater_on",
      "rhs": 0
    }
  ],
  "affect_neg": [
    {
      "lhs": "heater_on",
      "rhs": 1
    }
  ],
  "description": "Turn heater on when T drops below setpoint, off when above"
}
```

- `affects` fires on **positive-going** crossings (condition goes from negative to positive)
- `affect_neg` fires on **negative-going** crossings (condition goes from positive to negative)

### 5.3 Discrete Events

Discrete events fire when a **boolean condition evaluates to true** at the end of an integration step. They can also be triggered at specific times or periodically. This corresponds to MTK's `SymbolicDiscreteCallback`.

```json
{
  "discrete_events": [
    {
      "name": "injection",
      "trigger": {
        "type": "condition",
        "expression": { "op": "==", "args": ["t", "t_inject"] }
      },
      "affects": [
        {
          "lhs": "N",
          "rhs": { "op": "+", "args": [{ "op": "Pre", "args": ["N"] }, "M"] }
        }
      ],
      "description": "Add M cells at time t_inject"
    },

    {
      "name": "kill_production",
      "trigger": {
        "type": "condition",
        "expression": { "op": "==", "args": ["t", "t_kill"] }
      },
      "affects": [
        {
          "lhs": "alpha",
          "rhs": 0.0
        }
      ],
      "discrete_parameters": ["alpha"],
      "description": "Set production rate to zero at t_kill"
    },

    {
      "name": "periodic_emission_decay",
      "trigger": {
        "type": "periodic",
        "interval": 3600.0
      },
      "affects": [
        {
          "lhs": "emission_scale",
          "rhs": { "op": "*", "args": [{ "op": "Pre", "args": ["emission_scale"] }, 0.95] }
        }
      ],
      "discrete_parameters": ["emission_scale"],
      "description": "Reduce emission scaling factor by 5% every hour"
    },

    {
      "name": "preset_measurements",
      "trigger": {
        "type": "preset_times",
        "times": [3600.0, 7200.0, 14400.0, 28800.0]
      },
      "affects": [
        {
          "lhs": "sample_flag",
          "rhs": { "op": "+", "args": [{ "op": "Pre", "args": ["sample_flag"] }, 1] }
        }
      ],
      "discrete_parameters": ["sample_flag"],
      "description": "Mark measurement times"
    }
  ]
}
```

#### Discrete Event Fields

| Field | Required | Description |
|---|---|---|
| `name` | | Human-readable identifier |
| `trigger` | ✓ | Trigger specification (see trigger types below) |
| `affects` | ✓* | Array of `{lhs, rhs}` affect equations. *Required unless `functional_affect` is provided. |
| `discrete_parameters` | | Array of parameter names that are modified by this event. Parameters not listed here are treated as immutable. Required when affects modify parameters rather than state variables. |
| `reinitialize` | | Boolean. Whether to reinitialize the system after the event. |
| `description` | | Human-readable description |

#### Trigger Types

| Type | Fields | Description |
|---|---|---|
| `condition` | `expression` | Fires when the boolean expression is true at the end of a timestep |
| `periodic` | `interval`, `initial_offset` (optional) | Fires every `interval` time units |
| `preset_times` | `times` (array of numbers) | Fires at each specified time |

### 5.4 Discrete Parameters

Some events need to modify parameters rather than state variables. In the MTK model, parameters are immutable by default — they can only be changed by events if explicitly declared as `discrete_parameters`. This convention is preserved in ESM.

A parameter listed in `discrete_parameters` of an event:
- Must also be declared in the model's `variables` (with `"type": "parameter"`) or reaction system's `parameters`
- Will be modifiable by the event's affect equations
- Must be time-dependent in the underlying mathematical sense (even if constant between events)

### 5.5 Functional Affects (Registered)

Some events require behavior too complex for symbolic affect equations — for example, calling external code, performing interpolation lookups, or implementing control logic. These are analogous to MTK's functional affects.

Since ESM is language-agnostic, functional affects cannot embed executable code. Instead, they reference a **registered affect handler**, analogous to how data loaders are registered. Affect handlers are intentionally *out of scope* for the §9 closed function registry: handlers mutate simulator state at event-firing time, while §9 entries are pure expression-embedded callables. The `handler_id` mechanism survives only here, only for event affects.

```json
{
  "name": "complex_controller",
  "trigger": {
    "type": "periodic",
    "interval": 60.0
  },
  "functional_affect": {
    "handler_id": "PIDController",
    "read_vars": ["T", "T_setpoint", "error_integral"],
    "read_params": ["Kp", "Ki", "Kd"],
    "modified_params": ["heater_power"],
    "config": {
      "anti_windup": true,
      "output_clamp": [0.0, 100.0]
    }
  },
  "reinitialize": true,
  "description": "PID temperature controller, updates heater power every 60s"
}
```

#### Functional Affect Fields

| Field | Required | Description |
|---|---|---|
| `handler_id` | ✓ | Registered identifier for the affect implementation |
| `read_vars` | ✓ | State variables accessed by the handler |
| `read_params` | ✓ | Parameters accessed by the handler |
| `modified_params` | | Parameters modified by the handler (these are implicitly discrete parameters) |
| `config` | | Handler-specific configuration |

### 5.6 Cross-System Events

Events that involve variables from multiple coupled systems can be specified at the coupling level rather than within a single model:

```json
{
  "coupling": [
    {
      "type": "event",
      "event_type": "continuous",
      "conditions": [
        { "op": "-", "args": ["ChemModel.O3", 1e-7] }
      ],
      "affects": [
        {
          "lhs": "EmissionModel.NOx_scale",
          "rhs": 0.5
        }
      ],
      "discrete_parameters": ["EmissionModel.NOx_scale"],
      "description": "Reduce NOx emissions by half when O3 exceeds threshold"
    }
  ]
}
```

---

## 6. Models (ODE Systems)

Each model corresponds to an ODE system — a set of time-dependent equations with state variables and parameters. Models are keyed by a unique identifier.

**All models must be fully specified.** Every equation, variable, and parameter must be present in the `.esm` file. This ensures any conforming parser can reconstruct the model without external dependencies.

### 6.1 Schema

```json
{
  "models": {
    "SuperFast": {

      "reference": {
        "doi": "10.5194/acp-8-6365-2008",
        "citation": "Cameron-Smith et al., 2008",
        "url": "https://doi.org/10.5194/acp-8-6365-2008",
        "notes": "Simplified tropospheric chemistry mechanism with 16 species"
      },

      "variables": {
        "O3": {
          "type": "state",
          "units": "mol/mol",
          "default": 1.0e-8,
          "description": "Ozone mixing ratio"
        },
        "NO": {
          "type": "state",
          "units": "mol/mol",
          "default": 1.0e-10,
          "description": "Nitric oxide mixing ratio"
        },
        "NO2": {
          "type": "state",
          "units": "mol/mol",
          "default": 1.0e-10,
          "description": "Nitrogen dioxide mixing ratio"
        },
        "jNO2": {
          "type": "parameter",
          "units": "1/s",
          "default": 0.0,
          "description": "NO2 photolysis rate"
        },
        "k_NO_O3": {
          "type": "parameter",
          "units": "cm^3/molec/s",
          "default": 1.8e-12,
          "description": "Rate constant for NO + O3 → NO2 + O2"
        },
        "T": {
          "type": "parameter",
          "units": "K",
          "default": 298.15,
          "description": "Temperature"
        },
        "M": {
          "type": "parameter",
          "units": "molec/cm^3",
          "default": 2.46e19,
          "description": "Number density of air"
        },
        "total_O3_loss": {
          "type": "observed",
          "units": "mol/mol/s",
          "expression": {
            "op": "*",
            "args": ["k_NO_O3", "O3", "NO", "M"]
          },
          "description": "Total ozone chemical loss rate"
        }
      },

      "equations": [
        {
          "lhs": { "op": "D", "args": ["O3"], "wrt": "t" },
          "rhs": {
            "op": "+",
            "args": [
              { "op": "*", "args": [
                  { "op": "-", "args": ["k_NO_O3"] },
                  "O3", "NO", "M"
              ]},
              { "op": "*", "args": ["jNO2", "NO2"] }
            ]
          }
        },
        {
          "lhs": { "op": "D", "args": ["NO2"], "wrt": "t" },
          "rhs": {
            "op": "+",
            "args": [
              { "op": "*", "args": ["k_NO_O3", "O3", "NO", "M"] },
              { "op": "*", "args": [
                  { "op": "-", "args": ["jNO2"] },
                  "NO2"
              ]}
            ]
          }
        }
      ],

      "discrete_events": [],
      "continuous_events": []
    }
  }
}
```

### 6.2 Model Fields

| Field | Required | Description |
|---|---|---|
| `reference` | | Academic citation: `doi`, `citation`, `url`, `notes` |
| `variables` | ✓ | All variables, keyed by name |
| `equations` | ✓ | Array of `{lhs, rhs}` equation objects |
| `discrete_events` | | Discrete events (see Section 5.3) |
| `continuous_events` | | Continuous events (see Section 5.2) |
| `initialization_equations` | | Equations that hold only at t=0, solved before time-stepping begins. Typical uses: aerosol equilibrium / plume-rise style models (`system_kind='nonlinear'`) that need extra constraints for initialization, and ODE models whose initial state is determined by solving an auxiliary system. |
| `guesses` | | Initial-guess seeds for nonlinear solvers during initialization, keyed by variable name. Values are `Expression` graphs (numbers, strings, or nodes). |
| `system_kind` | | Discriminates the MTK system type: `"ode"` (default; time-stepped), `"nonlinear"` (algebraic-only equilibrium — no time derivative), `"sde"` (stochastic — brownian variables present), `"pde"` (spatial domain + differential operators). Each binding's MTK integration uses this to select between `System`, `NonlinearSystem`, `SDESystem`, and `PDESystem` constructors. A `"nonlinear"` model has NO time-derivative equations at all; its equation balance is unknowns-vs-equations and every algebraic LHS counts (§4.9.4). |
| `subsystems` | | Named child models (subsystems), keyed by unique identifier. Each subsystem can be defined inline or included by reference (see Section 4.7). Enables hierarchical composition — variables in subsystems are referenced via dot notation (see Section 4.6). |
| `tolerance` | | Model-level default numerical tolerance used by tests (see Section 6.6). Object with optional `abs` and/or `rel` fields. |
| `tests` | | Inline validation tests that exercise this model in isolation (see Section 6.6). |
| `examples` | | Inline illustrative examples showing how to run this model (see Section 6.7). |

### 6.3 Variable Types

| Type | Description |
|---|---|
| `state` | Time-dependent unknowns; appear on the LHS of ODEs as D(var, t) |
| `parameter` | Values set externally or held constant during integration |
| `observed` | Derived quantities; must include an `expression` field |

Optional arrayed-variable fields:

| Field | Description |
|---|---|
| `shape` | Ordered list of index-set names (keys in the document-scoped `index_sets` registry) the variable is arrayed over. Omitted or null means the variable is scalar. Index expressions into the variable (`index`, `aggregate` ranges) resolve against these sets. |
| `location` | Optional advisory placement tag for a staggered quantity (e.g., `"cell_center"`, `"edge_normal"`, `"x_face"`, `"vertex"`). Metadata only — the index set a quantity lives on is given by `shape`. Omitted means no explicit placement. |

### 6.4 Advection Model Example

Advection is a model like any other — fully specified:

```json
{
  "Advection": {
    "reference": {
      "notes": "First-order upwind advection operator"
    },
    "variables": {
      "u_wind": { "type": "parameter", "units": "m/s", "default": 0.0, "description": "Eastward wind speed" },
      "v_wind": { "type": "parameter", "units": "m/s", "default": 0.0, "description": "Northward wind speed" }
    },
    "equations": [
      {
        "_comment": "Applied to each coupled state variable via operator_compose",
        "lhs": { "op": "D", "args": ["_var"], "wrt": "t" },
        "rhs": {
          "op": "+",
          "args": [
            { "op": "*", "args": [
                { "op": "-", "args": ["u_wind"] },
                { "op": "grad", "args": ["_var"], "dim": "x" }
            ]},
            { "op": "*", "args": [
                { "op": "-", "args": ["v_wind"] },
                { "op": "grad", "args": ["_var"], "dim": "y" }
            ]}
          ]
        }
      }
    ]
  }
}
```

The special variable `"_var"` is a placeholder used in operator-style models. When coupled via `operator_compose`, it is substituted with each matching state variable from the target system.

`_var` is legal **wherever a state variable is legal** — not only on an equation LHS/RHS but also on the LHS of a continuous event's `affects` / `affect_neg`, and inside a `functional_affect`'s `read_vars` (a flux limiter that clamps whichever variable the operator is composed over is the ordinary use). It is implicitly declared (§4.9.1): a checker MUST NOT report it as `undefined_variable` or `event_var_undeclared`.

### 6.5 Dry Deposition Model Example

A model that computes deposition velocities from surface resistance parameters. This model is coupled to a chemistry system via `couple` to provide deposition loss terms; grid-level application of those losses is expressed via `grad`/`div`/`laplacian` PDE operators in the model equations, lowered by discretization rewrite rules (§9.6.8), not as an opaque registered operator.

```json
{
  "DryDeposition": {
    "reference": {
      "doi": "10.1016/0004-6981(89)90153-4",
      "citation": "Wesely, 1989. Parameterization of surface resistances to gaseous dry deposition.",
      "notes": "Resistance-based model: v_dep = 1 / (r_a + r_b + r_c)"
    },
    "variables": {
      "r_a": {
        "type": "parameter",
        "units": "s/m",
        "default": 100.0,
        "description": "Aerodynamic resistance"
      },
      "r_b": {
        "type": "parameter",
        "units": "s/m",
        "default": 50.0,
        "description": "Quasi-laminar sublayer resistance"
      },
      "r_c_O3": {
        "type": "parameter",
        "units": "s/m",
        "default": 200.0,
        "description": "Surface resistance for O3"
      },
      "v_dep_O3": {
        "type": "observed",
        "units": "m/s",
        "expression": {
          "op": "/",
          "args": [
            1,
            { "op": "+", "args": ["r_a", "r_b", "r_c_O3"] }
          ]
        },
        "description": "Dry deposition velocity for O3"
      }
    },
    "equations": []
  }
}
```

### 6.6 Tests

A model may carry an array of **inline tests**. Each test pins down a specific run configuration for the enclosing model and declares the scalar values that must hold at specific (variable, time) points. Tests travel with the model in the `.esm` document — they are not stored in a parallel filesystem hierarchy.

Tests are **per-component** by design: they exercise one model (or one reaction system) in isolation. They do not reach across coupled systems. Integrated / coupled / cross-system testing is a separate concern.

Because a test lives inside its parent component, there is no `model_ref` field: the target is implicit from document location.

#### 6.6.1 Test Schema

```json
{
  "tests": [
    {
      "id": "photostationary_approach",
      "description": "Starting from NO=10, NO2=20, O3=50 ppbv, the system approaches photostationary state.",
      "parameter_overrides": {
        "j_NO2": 0.008,
        "k_NO_O3": 1.8e-5
      },
      "time_span": { "start": 0.0, "end": 3600.0 },
      "tolerance": { "abs": 1e-6, "rel": 1e-5 },
      "assertions": [
        { "variable": "NO",  "time":    0.0, "expected": 10.0 },
        { "variable": "NO",  "time": 1140.0, "expected": 26.114863 },
        { "variable": "O3",  "time": 3600.0, "expected": 66.115137,
          "tolerance": { "abs": 1e-4 } }
      ]
    }
  ]
}
```

#### 6.6.2 Test Fields

| Field | Required | Description |
|---|---|---|
| `id` | ✓ | Identifier unique within this component's `tests` array. |
| `description` | | Human-readable description of what this test verifies. |
| `initial_conditions` | | Initial-value overrides for state variables, keyed by local variable name. Variables not listed fall back to their declared `default`. |
| `parameter_overrides` | | Parameter value overrides, keyed by local parameter name. |
| `time_span` | ✓ | `{start, end}` — simulation time interval in the component's time units. |
| `tolerance` | | Test-level default tolerance; see Section 6.6.4. |
| `expression_template_imports` | | Ordered `TemplateImport[]` (§9.7.2 shape) registered into the enclosing component's template scope **for this run only** — the discretization under which this test runs (§6.6.6, §9.7.10). |
| `assertions` | ✓ | Array of scalar checks; must contain at least one. |

#### 6.6.3 Assertion Semantics

Each assertion is a per-(variable, time) check against a scalar expected value:

| Field | Required | Description |
|---|---|---|
| `variable` | ✓ | Variable or species name. Local names (e.g., `"O3"`) or scoped references into subsystems (e.g., `"inner.X"`) are both allowed. |
| `time` | ✓ | Simulation time at which to evaluate the assertion; must lie in `[time_span.start, time_span.end]`. |
| `expected` | ✓ | Expected scalar value (compared within `tolerance`). |
| `tolerance` | | Per-assertion tolerance override. |
| `coords` | | PDE only: spatial-point sample. Map from spatial index-set (dimension) name to a **1-based, fractional index-space position** along that interval index set — not a physical coordinate (§6.6.5 convention 1). Mutually exclusive with `reduce`. |
| `reduce` | | PDE only: collapse the spatial field to a scalar before comparison. One of `integral`, `mean`, `max`, `min`, `L2_error`, `Linf_error`. Mutually exclusive with `coords`. |

Assertions are stored **inline** only — there is no file-reference option. Tests should be small (a handful of assertion points), not full reference trajectories.

An assertion passes when the computed value `actual` satisfies

```
|actual - expected| ≤ abs    OR    |actual - expected| / max(|expected|, ε) ≤ rel
```

for the resolved absolute and relative tolerances. If both bounds are given, passing either is sufficient — the standard numerical convention. An implementation-defined small `ε` (e.g., `1e-300`) protects the relative check when `expected` is zero.

#### 6.6.4 Tolerance Resolution Order

Tolerance is resolved most-specific first:

1. **Per-assertion** `tolerance` (if present) — wins outright.
2. Otherwise, **per-test** `tolerance` — the test's default.
3. Otherwise, the enclosing component's **model-level** `tolerance` field.
4. Otherwise, an **implementation default** — conforming runtimes should use `rel = 1e-6` and no `abs` bound.

Each level is a `{abs?, rel?}` object; absent fields fall through to the next level independently. Specifying only `abs` at a lower level does not mask `rel` from an upper level — they are merged per-field.

#### 6.6.5 PDE-Aware Assertions

Pointwise scalar assertions (the default — neither `coords` nor `reduce`) only make sense on 0-D components: there is one trajectory per variable, indexed by time alone. On a component whose variables are shaped over one or more spatial index sets, every assertion MUST select a scalar via either `coords` or `reduce`. Validators MUST reject:

- a 0-D component carrying an assertion with `coords` or `reduce` set; and
- a PDE component carrying a pointwise assertion (no `coords`, no `reduce`).

`coords` keys MUST match the spatial index-set names the field is shaped over. Three conventions, established by the cross-binding parity implementations, are **pinned** (determinism requires one answer; conforming runtimes MUST implement exactly these):

1. **`coords` are index-space positions.** `coords` values are positions in **index space** — 1-based, fractional allowed — along the named interval index sets, not physical coordinates. Sampling picks the **nearest grid index**, with exact half-way ties rounding **down** toward the lower index: `idx = ceil(c − 1/2)`. The resolved index MUST lie in `1..size`. `coords` may pin a strict subset of dimensions only when every remaining dimension resolves to a single sample (e.g., a 1-D component with a single dimension); otherwise the assertion is ill-defined and validators MUST reject.

2. **`integral` measure.** `integral` is the uniform-cell Riemann sum under a **unit total domain measure per axis** — i.e. `Σ field / N_cells`, identical to `mean` over interval index sets. Authors asserting over non-unit physical domains scale the expected value accordingly until the format grows a measure concept. This is exactly the measure convention under which the relative-L2 reduction is measure-free: the per-cell measure cancels between numerator and denominator.

3. **`from_file` resolution and format.** In a `{type: "from_file", path, format?}` reference, `path` resolves relative to the **`.esm` file's directory**. The default and only v1 `format` is `"json"`: a row-major nested JSON array exactly matching the field's shape. Implementations MUST validate the shape and reject mismatches.

`reduce` collapses the field over the entire spatial domain at the given `time`. The pure reductions (`integral`, `mean`, `max`, `min`) compare directly against `expected` (`integral` under convention 2 above). The error-norm reductions compare against a `reference` solution:

- `L2_error`: `expected ≈ ||u_actual − u_reference||_2 / ||u_reference||_2` (relative L2), evaluated as a domain integral.
- `Linf_error`: `expected ≈ max_x |u_actual(x) − u_reference(x)|` (uniform norm).

`reference` may be:

- an inline `Expression` whose free variables are the domain dimension names (e.g., `sin(π x)`), evaluated by the runtime over every grid point at the assertion `time`; or
- `{type: "from_file", path, format?}` pointing at a precomputed snapshot in the same shape as the field (resolved and validated per convention 3 above).

**Build-time evaluation scope.** Every reference resolved *before* the simulation runs — an inline `Expression` `reference` (above), the analytic materialization of a directly-asserted state-free array observed, and a coordinate-expression `ic` (§11.4.1) — resolves the model's **parameters** as in-scope names, bound to their load-time constant values (`parameter_overrides`-or-default), in addition to the domain dimension names. Model **state** variables are NOT in scope (there is no trajectory value at build time); a build-time reference to a state variable is an error. Parameters are load-time constants, so binding them is deterministic and does not depend on the trajectory. This lets a parameter-dependent reference / observed / `ic` resolve directly — e.g. a free-name grid-geometry template `x0 + (i − 1/2)·dx` whose `x0`/`dx` are parameters — without declaring those scalars as constant-backed observeds.

Worked example — 1-D heat equation `u_t = α u_xx` on `x ∈ [0, 1]` with `u(x,0) = sin(π x)` and zero-Dirichlet BCs has analytic solution `u(x,t) = exp(−α π² t) · sin(π x)`. The corresponding L2-error assertion is:

```json
{
  "variable": "u",
  "time": 0.1,
  "expected": 0.0,
  "tolerance": { "abs": 1e-3 },
  "reduce": "L2_error",
  "reference": {
    "op": "*",
    "args": [
      { "op": "exp", "args": [{ "op": "*", "args": [-0.01, 9.8696, 0.1] }] },
      { "op": "sin", "args": [{ "op": "*", "args": [3.14159, "x"] }] }
    ]
  }
}
```

#### 6.6.6 Running a discretization-agnostic PDE component (test injection)

A reusable PDE leaf is written against the operator sugar (`grad`, `div`, `laplacian`, spatial `D`) and deliberately imports **no** discretization, so it can be composed under different schemes (§9.7.10). Such a component is un-runnable in isolation — its rewrite-targets have no `match` rule to lower them (`unlowered_operator`, §9.6.3 constraint 6) — so its inline tests could not run against any concrete scheme. A `Test` therefore MAY carry an `expression_template_imports` array (§9.7.2 shape) naming the discretization library to lower the enclosing component under, **for that test's run only**:

```json
{
  "id": "runoff_central_n64",
  "description": "Saint-Venant runoff under central differences at n = 64.",
  "time_span": { "start": 0.0, "end": 100.0 },
  "expression_template_imports": [
    { "ref": "esd://cartesian/central_grad_zero_grad_bc.esm",
      "bindings": { "NX": 64, "NY": 64 } }
  ],
  "assertions": [
    { "variable": "h", "time": 100.0, "expected": 0.0, "reduce": "L2_error",
      "reference": { "op": "sin", "args": [{ "op": "*", "args": [3.14159, "x"] }] },
      "tolerance": { "abs": 1e-3 } }
  ]
}
```

The target is implicit — the enclosing model/reaction system, exactly as the assertion target is (§6.6). The injected rule lowers the component's rewrite-targets in the **per-test ephemeral build** (§9.7.10 timing): the resulting spatial field is collapsed to a scalar via `coords` or `reduce` at the assertion `time` and checked by the §6.6.5 machinery. Because each test carries its own list and runs as an independent build, one suite may exercise the component under several schemes (central vs. upwind, a convergence sweep over `bindings`) with no conflict between tests and no edit to the component. `bindings` close the library's grid-size metaparameters, which must agree with the index-set sizes the component's variables are shaped over (an inconsistency is the ordinary `template_import_index_set_conflict` / shape error at the build). Unlike the component's own `expression_template_imports` (§9.7.6), a test's list is authored per-run configuration and **does** survive `parse → emit` (§9.7.10 round-trip); the enclosing component round-trips with its operator sugar intact.

### 6.7 Examples

A model may also carry an array of **inline examples**. An example is an illustrative run (or family of runs) showing how the component is intended to be used. Examples do not produce pass/fail outcomes — they produce trajectories and plots.

Like tests, examples are per-component and travel with the model in the `.esm` document.

#### 6.7.1 Example Schema

```json
{
  "examples": [
    {
      "id": "rate_constant_sweep",
      "description": "Sweep over photolysis rates to explore the NO-NO2-O3 partitioning.",
      "initial_state": { "NO": 10.0, "NO2": 20.0, "O3": 50.0 },
      "parameters": {
        "k_NO_O3": 1.8e-5
      },
      "time_span": { "start": 0.0, "end": 3600.0 },
      "parameter_sweep": {
        "type": "cartesian",
        "dimensions": [
          { "parameter": "j_NO2",
            "range": { "start": 0.001, "stop": 0.02, "count": 20, "scale": "linear" } },
          { "parameter": "k_NO_O3",
            "range": { "start": 1e-6,  "stop": 1e-4, "count": 10, "scale": "log" } }
        ]
      },
      "plots": [
        {
          "id": "o3_vs_rates",
          "type": "heatmap",
          "description": "Final O3 as a function of j_NO2 and k_NO_O3.",
          "x": { "variable": "j_NO2",   "label": "j_{NO2} (s^-1)" },
          "y": { "variable": "k_NO_O3", "label": "k_{NO+O3} (ppbv^-1 s^-1)" },
          "value": { "variable": "O3", "reduce": "final" }
        }
      ]
    }
  ]
}
```

#### 6.7.2 Example Fields

| Field | Required | Description |
|---|---|---|
| `id` | ✓ | Identifier unique within this component's `examples` array. |
| `description` | | Human-readable description. |
| `initial_state` | | Scalar initial-value overrides for this run, keyed by state-variable name (`{var: number}`). A component's initial fields are declared with `ic` equations in the model (§11.4); this map overrides their scalar values for this run only. |
| `parameters` | | Parameter overrides, keyed by local parameter name. |
| `time_span` | ✓ | `{start, end}` in the component's time units. |
| `parameter_sweep` | | Optional parameter sweep; see Section 6.7.3. When present, the example represents a family of runs rather than a single trajectory. |
| `expression_template_imports` | | Ordered `TemplateImport[]` (§9.7.2 shape) registered into the enclosing component's template scope **for this run only** — the discretization under which this example runs (§9.7.10). Semantics mirror a test's `expression_template_imports` (§6.6.6): implicit target, per-run ephemeral build, survives `parse → emit`. |
| `plots` | | Plot specifications derived from the run(s); see Section 6.7.4. |

#### 6.7.3 Parameter Sweeps

```json
{
  "parameter_sweep": {
    "type": "cartesian",
    "dimensions": [
      { "parameter": "T",       "values": [280, 290, 300, 310] },
      { "parameter": "k_NO_O3", "range":  { "start": 1e-6, "stop": 1e-4, "count": 10, "scale": "log" } }
    ]
  }
}
```

Sweeps are currently **Cartesian** only: the total run count is the product of the dimension lengths. Linked / zipped sweeps are deferred to a future extension.

Each dimension specifies one parameter and either:

- `values: [number, ...]` — an explicit enumeration, or
- `range: {start, stop, count, scale}` — a generated range, where `scale` is `"linear"` (default) or `"log"` (both `start` and `stop` must be strictly positive for log scale).

Exactly one of `values` or `range` must be given per dimension.

#### 6.7.4 Plots

Plots describe how the run (or sweep) result is turned into a visualization. Only **structural** information is recorded: axes, series selection, and value reduction. Styling — colors, fonts, legend placement, themes — is the viewer's concern.

Five plot types are defined:

- `line` — one or more trajectories plotted as lines against a shared x axis.
- `scatter` — one or more trajectories as scatter points.
- `heatmap` — a 2-D grid over two swept parameters with a per-run color channel.
- `field_slice` — a 1-D cut through an N-D PDE field at fixed `at_time`. `x` names a spatial dimension; `y` names the variable plotted as a function of that dimension. Non-plotted spatial dimensions MUST be pinned in `pinned_coords`.
- `field_snapshot` — a 2-D field at fixed `at_time` with the variable as a color channel. `x` and `y` name two spatial dimensions; `value.variable` names the field. Non-plotted spatial dimensions MUST be pinned in `pinned_coords`.

| Field | Required | Description |
|---|---|---|
| `id` | ✓ | Identifier unique within this example's `plots` array. |
| `type` | ✓ | `line`, `scatter`, `heatmap`, `field_slice`, or `field_snapshot`. |
| `description` | | Human-readable description. |
| `x` | ✓ | X-axis specification (`{variable, label?}`). For trajectory/sweep plots `variable` may be any state variable, observed variable, parameter name, or swept parameter; for `field_slice` and `field_snapshot`, `x` MUST name a domain spatial dimension. |
| `y` | ✓ | Y-axis specification. May be a single `PlotAxis` (`{variable, label?}`) or, for `line`/`scatter` plots, an array of `PlotAxis` objects as an inline multi-series shorthand (see below). For `field_slice` and `field_snapshot`, `y` MUST be a single `PlotAxis` naming a domain spatial dimension. |
| `value` | heatmap, field_snapshot | Color channel for `heatmap` (a `PlotValue`) and for `field_snapshot` (only `value.variable` is used; `at_time` and `reduce` are ignored — the field is sampled at the plot-level `at_time`). |
| `series` | | For `line`/`scatter`: an array of `{name, variable}` pairs selecting multiple trajectories to overlay. Ignored for heatmap/field plots. |
| `at_time` | field_slice, field_snapshot | Required for field plots: simulation time at which to extract the spatial field. Must lie within the example's `time_span`. |
| `pinned_coords` | field plots, when domain has higher dimensionality than the plot | Map from each non-plotted spatial dimension name to a numeric coordinate. Required when the component domain has more spatial dimensions than the plot uses (1 axis for `field_slice`, 2 for `field_snapshot`). |

**Plot axes are flexible.** Any state variable, observed variable, parameter, or swept-parameter name is allowed for `x`, `y`, and (for heatmaps) the `value.variable`. The independent variable of the simulation is typically spelled `"t"`.

**Inline multi-series shorthand for `y`.** For `line` and `scatter` plots, `y` may be an array of `PlotAxis` objects instead of a single object. The first entry is the canonical y-axis; each entry is projected onto the `series` list using `label` as the series name (falling back to `variable` when `label` is absent). Using `y: [a, b, c]` is equivalent to writing `y: a` with `series: [{name: a.label || a.variable, variable: a.variable}, {name: b.label || b.variable, variable: b.variable}, {name: c.label || c.variable, variable: c.variable}]` explicitly. If an explicit `series` array is also present, it takes precedence over the inline array.

```json
{
  "id": "concentrations",
  "type": "line",
  "x": { "variable": "t", "label": "Time (s)" },
  "y": [
    { "variable": "O3",  "label": "O3"  },
    { "variable": "NO",  "label": "NO"  },
    { "variable": "NO2", "label": "NO2" }
  ]
}
```

This is equivalent to specifying `y: {"variable": "O3", "label": "O3"}` and `series: [{"name": "O3", "variable": "O3"}, {"name": "NO", "variable": "NO"}, {"name": "NO2", "variable": "NO2"}]`.

**PlotValue** (required for heatmaps, optional otherwise) reduces the per-run trajectory of one variable to a scalar:

```json
{ "variable": "O3", "reduce": "final" }
{ "variable": "O3", "reduce": "max"   }
{ "variable": "O3", "at_time": 1800.0 }
```

Exactly one of `at_time` or `reduce` should be specified; if both are present, `at_time` wins. Supported `reduce` values are `max`, `min`, `mean`, `integral`, and `final`. The preferred idiom for "at the end of the run" is `"reduce": "final"` — it is robust to changes in `time_span.end` and does not require the runtime to interpolate onto a specific output time.

When `at_time` does not land exactly on an output time, whether the runtime interpolates or snaps to the nearest sample is a runtime concern, not part of this specification.

#### 6.7.5 Worked Example: Heatmap Over a Sweep

A heatmap of the maximum O3 concentration over a 20 × 10 sweep of `j_NO2` and `k_NO_O3`, using the box-model ozone model:

```json
{
  "id": "o3_max_heatmap",
  "type": "heatmap",
  "x": { "variable": "j_NO2" },
  "y": { "variable": "k_NO_O3" },
  "value": { "variable": "O3", "reduce": "max" }
}
```

For each Cartesian combination of `(j_NO2, k_NO_O3)`, the runtime simulates once, takes the maximum O3 over the trajectory, and places that scalar at the corresponding grid cell.

#### 6.7.6 Worked Example: Field Plots for a 1-D Heat Equation

A 1-D field slice and (for a 2-D companion model) a 2-D field snapshot at `t = 0.1`:

```json
[
  {
    "id": "u_at_t_0_1",
    "type": "field_slice",
    "description": "u(x, t=0.1) along the spatial axis.",
    "x": { "variable": "x", "label": "x" },
    "y": { "variable": "u", "label": "u(x, 0.1)" },
    "at_time": 0.1
  },
  {
    "id": "u_xy_at_t_0_1",
    "type": "field_snapshot",
    "x": { "variable": "x" },
    "y": { "variable": "y" },
    "value": { "variable": "u" },
    "at_time": 0.1
  }
]
```

If the underlying domain has more spatial dimensions than the plot uses, the extras MUST be pinned, e.g. `"pinned_coords": { "z": 0.0 }`.

---

## 7. Reaction Systems

Reaction systems provide a declarative representation of chemical or biological reaction networks. They are an alternative to writing raw ODEs — the ODE form is derived automatically from the reaction stoichiometry and rate laws.

This section maps to Catalyst.jl's `ReactionSystem` but is fully self-contained.

### 7.1 Schema

```json
{
  "reaction_systems": {
    "SuperFastReactions": {

      "reference": {
        "doi": "10.5194/acp-8-6365-2008",
        "citation": "Cameron-Smith et al., 2008"
      },

      "species": {
        "O3":  { "units": "mol/mol", "default": 1.0e-8,  "description": "Ozone" },
        "NO":  { "units": "mol/mol", "default": 1.0e-10, "description": "Nitric oxide" },
        "NO2": { "units": "mol/mol", "default": 1.0e-10, "description": "Nitrogen dioxide" },
        "HO2": { "units": "mol/mol", "default": 1.0e-12, "description": "Hydroperoxyl radical" },
        "OH":  { "units": "mol/mol", "default": 1.0e-12, "description": "Hydroxyl radical" },
        "CO":  { "units": "mol/mol", "default": 1.0e-7,  "description": "Carbon monoxide" },
        "CO2": { "units": "mol/mol", "default": 4.0e-4,  "description": "Carbon dioxide" },
        "CH4": { "units": "mol/mol", "default": 1.8e-6,  "description": "Methane" },
        "CH2O":{ "units": "mol/mol", "default": 1.0e-10, "description": "Formaldehyde" },
        "H2O2":{ "units": "mol/mol", "default": 1.0e-10, "description": "Hydrogen peroxide" }
      },

      "parameters": {
        "T":    { "units": "K",          "default": 298.15,  "description": "Temperature" },
        "M":    { "units": "molec/cm^3", "default": 2.46e19, "description": "Air number density" },
        "jNO2": { "units": "1/s",        "default": 0.005,   "description": "NO2 photolysis rate" },
        "jH2O2":{ "units": "1/s",        "default": 5.0e-6,  "description": "H2O2 photolysis rate" },
        "jCH2O":{ "units": "1/s",        "default": 2.0e-5,  "description": "CH2O photolysis rate" },
        "emission_rate_NO": { "units": "mol/mol/s", "default": 0.0, "description": "NO emission rate" }
      },

      "reactions": [
        {
          "id": "R1",
          "name": "NO_O3",
          "substrates": [
            { "species": "NO", "stoichiometry": 1 },
            { "species": "O3", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "NO2", "stoichiometry": 1 }
          ],
          "rate": {
            "op": "*",
            "args": [
              1.8e-12,
              { "op": "exp", "args": [
                  { "op": "/", "args": [-1370, "T"] }
              ]},
              "M"
            ]
          },
          "reference": { "notes": "JPL 2015 recommendation. Rate includes M factor for mixing-ratio species." }
        },
        {
          "id": "R2",
          "name": "NO2_photolysis",
          "substrates": [
            { "species": "NO2", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "NO", "stoichiometry": 1 },
            { "species": "O3", "stoichiometry": 1 }
          ],
          "rate": "jNO2",
          "reference": { "notes": "NO2 + hν → NO + O(³P); O(³P) + O2 + M → O3" }
        },
        {
          "id": "R3",
          "name": "CO_OH",
          "substrates": [
            { "species": "CO", "stoichiometry": 1 },
            { "species": "OH", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "CO2", "stoichiometry": 1 },
            { "species": "HO2", "stoichiometry": 1 }
          ],
          "rate": {
            "op": "*",
            "args": [
              { "op": "+",
                "args": [
                  1.44e-13,
                  { "op": "/", "args": ["M", 3.43e11] }
                ]
              },
              "M"
            ]
          }
        },
        {
          "id": "R4",
          "name": "H2O2_photolysis",
          "substrates": [
            { "species": "H2O2", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "OH", "stoichiometry": 2 }
          ],
          "rate": "jH2O2"
        },
        {
          "id": "R5",
          "name": "HO2_self",
          "substrates": [
            { "species": "HO2", "stoichiometry": 2 }
          ],
          "products": [
            { "species": "H2O2", "stoichiometry": 1 }
          ],
          "rate": {
            "op": "*",
            "args": [
              2.2e-13,
              { "op": "exp", "args": [
                  { "op": "/", "args": [600, "T"] }
              ]},
              "M"
            ]
          }
        },
        {
          "id": "R6",
          "name": "CH4_OH",
          "substrates": [
            { "species": "CH4", "stoichiometry": 1 },
            { "species": "OH", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "CH2O", "stoichiometry": 1 },
            { "species": "HO2", "stoichiometry": 1 }
          ],
          "rate": {
            "op": "*",
            "args": [
              1.85e-12,
              { "op": "exp", "args": [
                  { "op": "/", "args": [-1690, "T"] }
              ]},
              "M"
            ]
          }
        },
        {
          "id": "R7",
          "name": "CH2O_photolysis",
          "substrates": [
            { "species": "CH2O", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "CO", "stoichiometry": 1 },
            { "species": "HO2", "stoichiometry": 2 }
          ],
          "rate": "jCH2O"
        },
        {
          "id": "R8",
          "name": "emission_NO",
          "substrates": null,
          "products": [
            { "species": "NO", "stoichiometry": 1 }
          ],
          "rate": "emission_rate_NO",
          "reference": { "notes": "Source term from emissions data" }
        }
      ],

      "constraint_equations": [],

      "discrete_events": [],
      "continuous_events": []
    }
  }
}
```

### 7.2 Reaction System Fields

| Field | Required | Description |
|---|---|---|
| `reference` | | Academic citation |
| `species` | ✓ | Named reactive species with units, defaults, descriptions. Each species may set `constant: true` to declare a **reservoir species** whose concentration is held fixed (no ODE integration) while it still participates in reactions as a substrate or product (see §7.4). |
| `parameters` | ✓ | Named parameters (rate constants, temperature, photolysis rates, etc.) |
| `reactions` | ✓ | Array of reaction definitions |
| `constraint_equations` | | Additional algebraic or ODE constraints (in expression AST form) |
| `discrete_events` | | Discrete events (see Section 5.3) |
| `continuous_events` | | Continuous events (see Section 5.2) |
| `subsystems` | | Named child reaction systems (subsystems), keyed by unique identifier. Each subsystem can be defined inline or included by reference (see Section 4.7). Enables hierarchical composition — variables in subsystems are referenced via dot notation (see Section 4.6). |
| `tolerance` | | System-level default numerical tolerance for tests. Same semantics as Section 6.6.4. |
| `tests` | | Inline validation tests for this reaction system. Semantics, field shape, and tolerance resolution are identical to Section 6.6. Assertion `variable` names refer to species or observed quantities of this reaction system. |
| `examples` | | Inline illustrative examples. Semantics, field shape, and plot/sweep rules are identical to Section 6.7. |

### 7.3 Reaction Fields

| Field | Required | Description |
|---|---|---|
| `id` | ✓ | Unique reaction identifier (e.g., `"R1"`) |
| `name` | | Human-readable name |
| `substrates` | ✓ | Array of `{species, stoichiometry}` or `null` for source reactions (∅ → X) |
| `products` | ✓ | Array of `{species, stoichiometry}` or `null` for sink reactions (X → ∅) |
| `rate` | ✓ | Rate expression: a string (parameter ref), number, or expression AST. It MAY name **scoped references** into other systems (`"MeteorologicalSystem.solar_intensity"`) — see §4.9.3; resolving a rate's symbols against the local reaction system only is a checker defect, not a file defect. |
| `reference` | | Per-reaction citation or notes |

### 7.3a Stoichiometric Coefficients

`stoichiometry` is a **positive finite number**. Integer coefficients (the only form accepted in v0.1.x) remain valid; fractional coefficients are accepted in v0.2.x so reaction mechanisms whose product yields are non-integer (e.g. `CH3O2 + CH3O2 → 2.0 CH2O + 0.8 HO2`, `ISOP + O3 → 0.87 CH2O + 1.86 CH3O2 + 0.06 HO2 + 0.05 CO`) can be expressed directly rather than encoded as multiple shadow reactions. NaN and ±Infinity are rejected at parse time.

Integer fixtures and fractional fixtures share one on-disk representation: the JSON number. Implementations SHOULD emit integer-valued coefficients without a decimal point so existing integer-only files round-trip byte-identically.

### 7.4 ODE Generation from Reactions

A conforming implementation generates ODEs from the reaction list using standard mass action kinetics. For a reaction with rate `k`, substrates `{S_i}` with stoichiometries `{n_i}`, and products `{P_j}` with stoichiometries `{m_j}`:

**Rate law:**
```
v = k · ∏ᵢ Sᵢ^nᵢ
```

**ODE contribution** for species X:
```
dX/dt += (net_stoich_X) · v
```

where `net_stoich_X = (stoich as product) − (stoich as substrate)`.

**Unit convention:** The `rate` field in each reaction must be the **effective rate** for the species units used — i.e., mass action applied to the rate and species values must produce the correct ODE tendency in the declared species units. When species are in mixing ratios (e.g., `mol/mol`) but rate constants are in concentration units (e.g., `cm³/molec/s`), the rate expression must include the appropriate number density factor(s) `M` to convert. For a reaction of total substrate order `n`, the rate should include `M^(n−1)`.

**Reservoir species (`constant: true`).** A species declared with `constant: true` is a *reservoir*: it appears in rate laws as a concentration but no `dX/dt` equation is generated for it. Bindings that target Catalyst emit it as a parameter with `isconstantspecies=true` metadata; other bindings skip the ODE for that species while still evaluating mass-action contributions from it. Typical use: O₂, CH₄, H₂O in tropospheric chemistry where the species participates in many reactions but its concentration is effectively unchanged on the simulation timescale.

**Initial conditions.** A species' initial value is its scalar `species.default` (overridable per run via `test.initial_conditions` / `example.initial_state`). A reaction system has no `equations` field and hosts no `ic` equations of its own; a non-constant, coordinate-dependent, or loaded-field species IC — for example once the reaction system is spatially lifted onto a grid (§10.5) — is declared with a scoped-reference `ic` equation in a model, `ic(Sys.species) ~ <field>` (§11.4.1), not inside the reaction system.

---

## 8. Data Loaders

Data loaders are generic, runtime-agnostic descriptions of external data sources, reduced to a single responsibility: **locate, read, and slice** data from disk and **describe its native grid**. The schema carries enough information to locate files, map timestamps to files, and describe variable semantics and the native grid — **not** just a pointer at a runtime handler. A loader performs **no** reprojection and **no** regridding: transferring its native fields onto a consuming model's target grid (and the choice of method) is a **model** concern, selected per variable on the model that owns the loader as a subsystem (RFC pure-io-data-loaders §4.1).

The shape is loosely modeled on a STAC catalog: it is usable for any gridded or point dataset (reanalysis, emissions inventories, static fields), not tied to any specific runtime or library.

Authentication, credential management, and per-variable temporal availability constraints are **out of scope** for the schema. Those are runtime concerns.

### 8.1 Data Loader Fields

| Field | Required | Description |
|---|---|---|
| `kind` | ✓ | Structural kind: `"grid"` (gridded array source), `"points"` (scattered point/station source), or `"static"` (time-invariant source). Any grid geometry the loader reads — coordinates, connectivity, metric arrays — is exposed as ordinary loader `variables` and consumed downstream by `aggregate` FAQs; it needs no special descriptor. Scientific role (emissions, meteorology, elevation, …) is **not** schema-validated and belongs in `metadata.tags`. |
| `source` | ✓ | File discovery object (see §8.2). |
| `variables` | ✓ | Map of schema-level variable name → variable descriptor (see §8.5). At least one entry required. |
| `temporal` | | Temporal coverage and record layout (see §8.3). |
| `determinism` | | Reproducibility contract for binary formats — endian / float format / integer width. A binding that cannot honor the declared layout MUST reject the file at load rather than reinterpret bytes. |
| `reference` | | Data source citation. |
| `metadata` | | Free-form metadata. The `tags` array is conventional for scientific role. |

### 8.2 `source` — file discovery

```
source:
  url_template: string    # required
  mirrors: [string]       # optional, ordered fallback list
```

`url_template` is a Jinja-style template with substitutions that runtimes resolve at load time. The following substitutions are supported:

| Substitution | Meaning |
|---|---|
| `{date:<strftime>}` | Date/time formatted with a strftime pattern. Example: `{date:%Y%m%d}` → `20240501`, `{date:%Y-%m-%dT%H%M}` → `2024-05-01T0000`. |
| `{var}` | Variable name (for datasets that split variables across files). |
| `{sector}` | User-defined sector key (for emissions inventories). |
| `{species}` | User-defined species key. |

Custom substitutions are allowed. Runtimes **must** accept and pass through unrecognized substitutions rather than rejecting them, so that domain-specific keys (e.g. `{grid_res}`, `{ensemble_member}`) can be added without schema changes.

`mirrors` is an optional ordered list of fallback templates following the same grammar. If present, runtimes try `url_template` first, then each mirror in order.

### 8.3 `temporal` — coverage and records

```
temporal:
  start: ISO8601 datetime      # first timestamp available
  end:   ISO8601 datetime      # last timestamp available
  file_period: ISO8601 duration   # how much time one file covers, e.g. "P1D", "P1M", "PT3H"
  frequency:   ISO8601 duration   # spacing between samples within a file
  records_per_file: integer | "auto"
  time_variable: string        # name of the time coord inside the file
```

Both **static declaration** (`records_per_file` + `frequency`) and **runtime discovery** (`time_variable`) are allowed. If both are present, the static declaration wins and `time_variable` acts as a fallback. `records_per_file: "auto"` explicitly defers to runtime discovery.

### 8.4 (Reserved)

The former native-grid descriptor was removed in v0.8.0: a loader exposes any grid geometry it reads (coordinates, connectivity, metric arrays) as ordinary `variables` (§8.5), consumed downstream by `aggregate` FAQs. The subsection number is retained so §8.5–§8.8 references stay stable.

### 8.5 `variables` — variable mapping

```
variables:
  <schema_var_name>:
    file_variable: string        # required; name in the source file
    units: string                # required; units as exposed to the schema
    unit_conversion: number | Expression   # optional
    description: string
    reference: Reference
```

`file_variable` lets the schema-level variable name differ from the on-disk name. `unit_conversion` is either a plain multiplicative factor or a full `Expression` AST (§4); the runtime applies it when producing values in the declared `units`.

### 8.6 Regridding — a coupling expression

A data loader is pure I/O and performs no regridding. There is no `regridding`
block on the loader and no `Model.regrid` map: transferring a loaded field onto a
consuming variable's grid is expressed like any other coupling, as an ordinary
expression in the coupling relationship between the two variables (§10). Because
the numeric core of every standard regridder is a Functional Aggregate Query —
the overlap-area `sum_product` apply, the normalization group-by, and the
temporal-interpolation blend are all `aggregate` nodes (RFC
semiring-faq-unified-ir §A.8) — a regridding coupling is just an `aggregate`
expression over the source field and the (FAQ-constructed or loaded) overlap
weights. The kernels map cleanly:

- **conservative** (area-weighted, mass-conserving): the per-pair overlap area
  `A_ij = area(src_i ∩ tgt_j)`, then a `sum_product` apply normalized by a
  group-by row-sum. `A_ij` has two spellings (§8.6.1): the explicit
  `polygon_area` `sum_product` FAQ over the `intersect_polygon` clip ring, or the
  fused `polygon_intersection_area` scalar leaf (the densely-evaluable form).
- **B-spline / bilinear** (interpolating): a `sum_product` over an interpolation
  stencil whose weights are an ordinary FAQ of the source coordinates.
- **cell-averaging** (scattered points → cells): a bin/`skolem` spatial join
  followed by a `sum_product` mean, with a `missing_value` fill expressed as an
  `ifelse` over the per-cell contributor count.

None of this needs schema support beyond `aggregate` and the geometry leaves
(`intersect_polygon`, `polygon_intersection_area`): a regridding rule is a normal
coupling expression, authored inline or referenced as an ESD subsystem. The
carrier is the `variable_map` entry's `transform` field, which admits a full
Expression alongside the legacy named transforms (§10.4 defines the evaluation
contract; §10.5 shows the spelling — typically an `apply_expression_template`
invocation of an imported overlap-weight library, expanded at load per §9.6.4).

#### 8.6.1 Evaluating the overlap weights: the `polygon_intersection_area` leaf

A conservative regrid has two phases. The **broad phase** finds which
`(src_i, tgt_j)` pairs can overlap — a bin/`skolem` spatial join
(`floor(coord/dx)` → `skolem` bin key → `distinct` → `join.on` shared bin) that
produces a sparse `candidate_pairs` index set. This phase is required in
production: it keeps the regrid `O(#overlaps)` rather than `O(N_src·N_tgt)`. It
is **build-time value invention** (`skolem`/`distinct`/`rank`), run once when the
regridder is constructed.

The **narrow phase** computes the overlap area of each candidate pair. Written
with the general `intersect_polygon` leaf, the clip returns an intersection ring
whose vertex count is **data-dependent** — a `derived` (`from_faq`) index set of
per-pair-varying length — and `polygon_area` is an ordinary `sum_product` FAQ
over that ring. Because the ring extent is ragged and differs per pair, the
*full-mesh* narrow phase in that form is **not a dense tensor contraction**: it
is declared structurally but cannot be walked by the dense evaluator (only a
single fixed-extent clip can). This is the status the worked fixture
`conservative_regrid_overlap_join.esm` documents.

The `polygon_intersection_area` leaf removes that obstacle. It is the **fused,
opaque** form of `polygon_area ∘ intersect_polygon`: it takes the two operand
polygons plus a required `manifold` and returns the **scalar** overlap area
directly, hiding the clip ring inside the kernel (never surfacing it as an index
set). Its value is defined to equal `polygon_area(intersect_polygon(a, b))` at
the same manifold and tolerance, so cross-binding agreement is inherited from its
two constituent kernels — exactly the `interp.linear` / `interp.bilinear`
fused-leaf pattern of §9.2 (a named opaque op standing in for an AST composition
whose intermediate is problematic, here ragged rather than merely verbose). With
it, the narrow phase over the candidate set is an ordinary **dense** `aggregate`:

```
A_ij[i, j] = polygon_intersection_area(src_poly_i, tgt_poly_j)     // over candidate_pairs
```

carrying no ragged intermediate. The whole regrid — build-time candidate set,
dense narrow-phase `A_ij`, group-by row-sum `A_j`, and the `sum_product` apply
`F_tgt[j] = Σ_i (A_ij / A_j)·F_src[i]` — is then evaluable end to end, with only
the candidate-set construction living in the build-time value-invention layer.

Keep both leaves: `intersect_polygon` when the overlap **geometry** itself is
needed (a centroid, a higher moment, or the ring fed onward), and
`polygon_intersection_area` for the dominant area-weight case, where only the
scalar area matters. `polygon_intersection_area` carries the same required
`manifold` field and the same tolerance-based conformance contract as
`intersect_polygon` (CONFORMANCE_SPEC §5.8.4).

**Operand rings, padding, and degenerate vertices.** Each polygon operand of
`intersect_polygon` / `polygon_intersection_area` is an `[verts, 2]` lon-lat
vertex array with **implicit closure** (edge `n→1` implied). Two departures
from the plain distinct-vertex ring MUST be accepted by every binding:

1. **Explicit closure** — a closing duplicate final vertex
   (`ring[last] == ring[first]`) is dropped.
2. **Consecutive duplicate vertices** — in particular trailing repeats of the
   final vertex. This is the rectangular-storage padding a mixed-valence mesh
   requires: an MPAS pentagon stored in a hexagon-shaped `[cells, NVERT, 2]`
   ring stack repeats its last vertex to fill the fixed `NVERT` slots, so the
   dense narrow-phase `A_ij` aggregate can gather per-cell rings of uniform
   extent.

A binding MUST evaluate such a ring as its **deduplicated** form: consecutive
duplicates (wrap pair included) are removed under the shared point-equality
tolerance (`atol 1e-8`, `rtol 1e-5` — the `np.allclose` defaults all bindings
pin), and the op's value MUST equal the same op over the already-distinct ring.
Deduplication is the **binding kernel's** job, performed in its operand
coercion *before* the backend clip — never delegated to the backend and never
imposed on the caller — because backend tolerance differs: a zero-length edge
is a no-op for a Sutherland–Hodgman half-plane pass but a **rejected degenerate
edge for S2** (the Python/Rust spherical backend). A ring with fewer than 3
*distinct* vertices after deduplication is a degenerate operand and is
rejected (the existing ≥3-distinct-vertices operand error). `intersect_polygon`
returns its overlap ring in the same normal form — distinct vertices, implicit
closure — on every manifold.

### 8.7 Out of scope

- **Authentication / credentials.** Env vars, API keys, S3 credentials, CDS API tokens — all runtime-side. The schema stores **no** credential information.
- **Per-variable temporal availability windows** (e.g. "CEDS covers 1750–2023 for NOx but 1850–2023 for CH4"). Runtime validation concern.
- **Reprojection and regridding.** A loader describes its native grid only; transforming onto a target grid is a model concern (§8.6).

### 8.8 Worked examples

#### GEOSFP reanalysis (gridded meteorology, 3-hourly, one file per timestep)

```json
{
  "GEOSFP_A1": {
    "kind": "grid",
    "source": {
      "url_template": "https://portal.nccs.nasa.gov/datashare/gmao/geos-fp/das/Y{date:%Y}/M{date:%m}/D{date:%d}/GEOS.fp.asm.tavg1_2d_slv_Nx.{date:%Y%m%d_%H%M}.V01.nc4"
    },
    "temporal": {
      "start": "2014-01-01T00:00:00Z",
      "end":   "2099-12-31T23:59:59Z",
      "file_period": "PT1H",
      "frequency":   "PT1H",
      "records_per_file": 1
    },
    "variables": {
      "u": { "file_variable": "U10M", "units": "m/s", "description": "10-m eastward wind" },
      "v": { "file_variable": "V10M", "units": "m/s", "description": "10-m northward wind" },
      "T": { "file_variable": "T2M",  "units": "K",   "description": "2-m temperature" },
      "PBLH": { "file_variable": "PBLH", "units": "m", "description": "PBL height" }
    },
    "reference": {
      "citation": "Global Modeling and Assimilation Office (GMAO), NASA GSFC",
      "url": "https://gmao.gsfc.nasa.gov/GEOS_systems/",
      "doi": "10.5067/8D5L8QSF2Y6L"
    },
    "metadata": { "tags": ["meteorology", "reanalysis", "hourly"] }
  }
}
```

#### CEDS emissions (per-species monthly files, multi-decade)

```json
{
  "CEDS_anthro": {
    "kind": "grid",
    "source": {
      "url_template": "https://data.pnnl.gov/ceds/v2021/{species}-em-anthro_input4MIPs_emissions_CMIP_CEDS-2021-04-21-supplemental-data_gn_{date:%Y}01-{date:%Y}12.nc",
      "mirrors": [
        "s3://ceds-mirror/v2021/{species}-em-anthro_{date:%Y}.nc"
      ]
    },
    "temporal": {
      "start": "1750-01-01T00:00:00Z",
      "end":   "2023-12-31T00:00:00Z",
      "file_period": "P1Y",
      "frequency":   "P1M",
      "records_per_file": 12,
      "time_variable": "time"
    },
    "variables": {
      "emis_NOx": {
        "file_variable": "NOx_em_anthro",
        "units": "kg/m^2/s",
        "description": "Anthropogenic NOx emissions (sum of sectors)"
      },
      "emis_CO": {
        "file_variable": "CO_em_anthro",
        "units": "kg/m^2/s",
        "description": "Anthropogenic CO emissions"
      }
    },
    "reference": {
      "citation": "Hoesly et al. (2018), CEDS historical emissions",
      "doi": "10.5194/gmd-11-369-2018"
    },
    "metadata": { "tags": ["emissions", "anthropogenic", "monthly"] }
  }
}
```

#### ERA5 pressure-level reanalysis (multi-variable monthly files)

```json
{
  "ERA5_PL": {
    "kind": "grid",
    "source": {
      "url_template": "cds://reanalysis-era5-pressure-levels/{date:%Y%m}.nc"
    },
    "temporal": {
      "start": "1979-01-01T00:00:00Z",
      "end":   "2099-12-31T23:59:59Z",
      "file_period": "P1M",
      "frequency":   "PT1H",
      "records_per_file": "auto",
      "time_variable": "time"
    },
    "variables": {
      "T": {
        "file_variable": "t",
        "units": "K",
        "description": "Temperature on pressure levels"
      },
      "Q": {
        "file_variable": "q",
        "units": "kg/kg",
        "description": "Specific humidity"
      },
      "Z": {
        "file_variable": "z",
        "units": "m^2/s^2",
        "description": "Geopotential"
      }
    },
    "reference": {
      "citation": "Hersbach et al. (2020), ERA5",
      "doi": "10.1002/qj.3803"
    },
    "metadata": { "tags": ["meteorology", "reanalysis", "pressure-levels"] }
  }
}
```

*Note: the CDS API requires credentials. Those are runtime-side and intentionally absent from the schema.*

#### USGS 3DEP elevation (static, single file)

```json
{
  "USGS_3DEP": {
    "kind": "static",
    "source": {
      "url_template": "s3://prd-tnm/StagedProducts/Elevation/1/TIFF/USGS_Seamless_DEM_1.tif"
    },
    "variables": {
      "elevation": {
        "file_variable": "Band1",
        "units": "m",
        "description": "Ground-surface elevation above geoid"
      }
    },
    "reference": {
      "citation": "USGS 3D Elevation Program (3DEP)",
      "url": "https://www.usgs.gov/3d-elevation-program"
    },
    "metadata": { "tags": ["elevation", "static", "topography"] }
  }
}
```

## 9. Closed Function Registry

### 9.1 Closed-set principle

Every callable that may appear inside an expression is drawn from this section's **closed registry**. There is no per-file declaration of new functions, no `handler_id` lookup, and no out-of-band runtime extension point. The set of valid `fn` `name` values is fixed by the spec version: bindings MUST reject any `fn` node whose `name` is not declared in §9.2 for the file's `esm` version, with diagnostic code `unknown_closed_function`. Loading MUST fail.

The closed-set rule is a deliberate constraint that recovers cross-binding bit-equivalence: an `.esm` file plus the spec version uniquely determines numerical behavior. The trade-off is that adding a primitive requires a spec rev (the addition process, deprecation policy, and compatibility-matrix discipline are described in `docs/content/rfcs/closed-function-registry.md` §7).

A function belongs in the closed registry **only** when **all three** of the following hold:

- Not expressible in finite closed form using the §4.2 AST ops (powers, polynomials, `min`/`max`/`ifelse`/`sign`, trig / exp / log / sqrt, comparisons, n-ary arithmetic).
- Has well-defined cross-binding semantics that the proposer can pin (formula, edge cases, tolerance).
- There is no cleaner `data_loaders` path: the function operates on inline scalars or small arrays passed via `const`, not on bulk gridded fields.

Anything that fails one of these tests does not belong here. The §1.1 authoring policy MUST be enforced at review time.

### 9.2 v1 closed function set

The v1 set is intentionally narrow: calendar arithmetic on UTC time, plus a single search-into-sorted-table primitive that, composed with the existing `index` op, covers the categorical / interpolation lookups motivated in `docs/content/rfcs/closed-function-registry.md`. All real-valued time inputs are IEEE-754 `binary64` UTC seconds since the Unix epoch (1970-01-01T00:00:00Z, proleptic Gregorian, no leap-second consultation — the deliberate cross-binding contract). All integer outputs are signed 32-bit; bindings MUST raise `closed_function_overflow` if a result would overflow.

#### `datetime.*` — calendar decomposition

Decomposes a UTC scalar time into proleptic-Gregorian calendar fields. All entries are pure: same input → same output, no system-clock or timezone consultation. Bindings MUST use exact integer arithmetic on the decomposed `(date, time-of-day)` pair after a single floor-divmod by 86400; this guarantees per-binding agreement to the integer (zero ulp drift on the integer outputs, ≤ 1 ulp on `julian_day` because of one floating-point divide).

| Name | Arity | Args | Return | Range / convention |
|---|---|---|---|---|
| `datetime.year` | 1 | `t_utc: scalar [s]` | integer scalar | proleptic-Gregorian year (e.g. 2026) |
| `datetime.month` | 1 | `t_utc: scalar [s]` | integer scalar (1..12) | 1 = January |
| `datetime.day` | 1 | `t_utc: scalar [s]` | integer scalar (1..31) | day of month |
| `datetime.hour` | 1 | `t_utc: scalar [s]` | integer scalar (0..23) | UTC hour |
| `datetime.minute` | 1 | `t_utc: scalar [s]` | integer scalar (0..59) | UTC minute |
| `datetime.second` | 1 | `t_utc: scalar [s]` | integer scalar (0..59) | UTC second (no leap-second slot) |
| `datetime.day_of_year` | 1 | `t_utc: scalar [s]` | integer scalar (1..366) | 1 = Jan 1 |
| `datetime.julian_day` | 1 | `t_utc: scalar [s]` | scalar | continuous Julian Day Number incl. fractional time-of-day |
| `datetime.is_leap_year` | 1 | `t_utc: scalar [s]` | integer scalar (0 or 1) | 1 if the proleptic-Gregorian year of `t_utc` is a leap year, else 0 |

**Boundary semantics:**

- Negative `t_utc` (pre-1970) is supported. The proleptic-Gregorian calendar extends backwards without modification; `datetime.year` of a pre-1970 instant is the proleptic-Gregorian year (e.g. `1969`, `1900`, `-1` for 2 BC by ISO 8601 convention).
- `datetime.julian_day` returns the standard JDN convention (JD 0 = noon UTC on 4713 BC Jan 1, proleptic Julian calendar). The reference computation is the Fliegel–van Flandern (1968) integer formula applied to the date part of `t_utc`, plus `(time_of_day_seconds − 43200) / 86400` for the fractional part. Bindings MAY use a faster equivalent if it is bit-exact on the supported domain.
- All other entries decompose using the rule that the calendar date is `floor(t_utc / 86400)` days after 1970-01-01, with `t_utc mod 86400` giving the time-of-day seconds. Negative-modulo edge cases use Python-style floored division (so `floor(-1.0 / 86400) = -1` and `(-1.0) mod 86400 = 86399`).

**Tolerance:** integer outputs are exact (zero error). `datetime.julian_day` is ≤ 1 ulp.

#### `interp.*` — search

| Name | Arity | Args | Return |
|---|---|---|---|
| `interp.searchsorted` | 2 | `x: scalar, xs: const array[N]` | integer scalar (1..N) |

**Semantics — `interp.searchsorted`:**

Returns the 1-based index `i` of the first element of `xs` that is `≥ x` (left-side bias, equivalent to Julia's `searchsortedfirst`).

- `xs` MUST be a `const`-op array of strictly non-decreasing floats. Bindings MUST reject non-monotonic `xs` at load time with diagnostic `searchsorted_non_monotonic`.
- Equal values in `xs` (duplicates): the returned index is the **smallest** `i` for which `xs[i] ≥ x`. This makes the result deterministic on duplicate runs and lets authors compose searches (e.g. find the first interval containing `x` even when boundaries coincide).
- Out-of-range query: if `x ≤ xs[1]`, return `1`. If `x > xs[N]`, return `N + 1` (one past the end). Authors who need clamping wrap the result in `min(N, ...)` using the AST.
- NaN `x`: result is `N + 1` (treated as "greater than every finite element"). NaN entries in `xs` are forbidden.

**Tolerance:** exact (the returned index is integer; the comparison is the IEEE-754 `≥` predicate, which has no rounding tolerance).

The `interp.searchsorted` primitive composes with the existing `index` op (§4.3.3) to express tabulated lookups: `{"op": "index", "args": ["table", {"op": "fn", "name": "interp.searchsorted", "args": ["x", {"op": "const", "value": [...]}]}]}`. Linear blends between adjacent table entries can be written in pure AST (subtract neighbouring `index`-ed values, multiply by a fractional weight, add); the `interp.linear` and `interp.bilinear` primitives below are the **named, opaque** form of those blends — semantically equivalent to the AST composition but exposed as a single `fn` node so that bindings with symbolic-rewriting layers (notably the Julia / MTK extension) can register them as opaque operators and avoid the alias-elimination blow-up that ~10-node-per-lookup AST inlining causes for components with hundreds of lookups (see `docs/content/rfcs/closed-function-registry.md` and the `interp.linear` / `interp.bilinear` rationale in §9.2 below).

#### `interp.*` — tensor interpolation

| Name | Arity | Args | Return |
|---|---|---|---|
| `interp.linear` | 3 | `table: const array[N], axis: const array[N], x: scalar` | scalar |
| `interp.bilinear` | 5 | `table: const array[Nx][Ny], axis_x: const array[Nx], axis_y: const array[Ny], x: scalar, y: scalar` | scalar |

These primitives are the named, opaque form of the searchsorted-plus-index-plus-AST-arithmetic pattern that produces a 1-D or 2-D linear interpolation into a tabulated dataset. They exist for the perf reason described in the paragraph above (pinning a single `fn` node lets bindings with symbolic layers stop alias-eliminating tens of intermediate nodes per lookup), not because the math is novel. Bindings MAY satisfy these by composing existing primitives internally (`interp.searchsorted` + `index` + AST blend) OR by direct implementation; either is conformant as long as the conformance fixtures in `tests/closed_functions/interp/linear/` and `tests/closed_functions/interp/bilinear/` pass.

**Argument shape contract (loaded at file-load time, not at evaluation):**

- `table` and the axis array(s) MUST be `const`-op arrays of finite floats. Loaders MUST resolve their nested shapes at load time. The shape relation MUST hold:
  - `interp.linear`: `len(table) == len(axis) == N` with `N ≥ 2`.
  - `interp.bilinear`: outer length of `table` MUST equal `Nx == len(axis_x)` and every inner row of `table` MUST have length `Ny == len(axis_y)`, with `Nx ≥ 2` and `Ny ≥ 2`. The table is row-major: `table[i][j]` is the value at `(axis_x[i], axis_y[j])`.
- Each axis array MUST be **strictly increasing**. Equal adjacent axis values are not allowed (they would make a denominator zero in the blend). `interp.searchsorted` permits equal-adjacent (§9.2) because it returns an index, not a blend; `interp.linear` / `interp.bilinear` do not.
- Axis arrays MUST NOT contain NaN. Table arrays MAY contain NaN (a query landing in a cell whose corner is NaN will produce NaN in the output; this is intentional, since "missing data" is a real use case).
- Bindings MUST reject violations at file-load time with the diagnostic codes listed under "Errors" below. Loading MUST fail.

**Semantics — `interp.linear`:**

Let `axis = [a₁, ..., aₙ]` (1-based indexing for spec exposition) and `table = [t₁, ..., tₙ]`. For a scalar query `x`:

1. **Below-range clamp.** If `x ≤ a₁`, return `t₁`.
2. **Above-range clamp.** If `x ≥ aₙ`, return `tₙ`.
3. **In-range blend.** Otherwise let `i` be the unique index in `[1, n−1]` satisfying `aᵢ ≤ x < aᵢ₊₁` (existence and uniqueness are guaranteed by strict monotonicity and the clamps in steps 1–2). Compute the weight and blend in this exact order (pinned for cross-binding bit-equivalence):

   ```
   w      = (x − aᵢ) / (aᵢ₊₁ − aᵢ)
   result = tᵢ + w · (tᵢ₊₁ − tᵢ)
   ```

   This form (rather than `(1 − w)·tᵢ + w·tᵢ₊₁`) is required because it is **exact at the endpoints**: `w = 0` ⇒ `result = tᵢ` exactly, and `w = 1` ⇒ `result = tᵢ + (tᵢ₊₁ − tᵢ) = tᵢ₊₁` to within IEEE-754 round-to-nearest, with no rounding error from `1 − w` cancellation when `x` is near `aᵢ₊₁`.

4. **NaN propagation.** If `x` is NaN, the result is NaN. (The clamp comparisons in steps 1–2 are IEEE-754 `≤` and `≥`, which both return false for NaN, so the function falls through to step 3, where `aᵢ − x` and `(aᵢ₊₁ − aᵢ)` produce a NaN weight that propagates through the blend.)

**Semantics — `interp.bilinear`:**

Let `axis_x = [x₁, ..., x_{Nx}]`, `axis_y = [y₁, ..., y_{Ny}]`, and `table[i][j]` be the value at `(xᵢ, yⱼ)`. For scalar queries `(x, y)`:

1. **Per-axis clamp.** Compute `x_q = clamp(x, x₁, x_{Nx})` and `y_q = clamp(y, y₁, y_{Ny})`, where `clamp(v, lo, hi)` is `lo` if `v ≤ lo`, `hi` if `v ≥ hi`, else `v`. This is the 2-D extrapolate-flat rule: queries outside the table are pinned to the nearest edge.
2. **Cell location.** Choose `i` as the **largest** index in `[1, Nx − 1]` with `xᵢ ≤ x_q`, and `j` as the largest index in `[1, Ny − 1]` with `yⱼ ≤ y_q`. (Equivalent formulation: clamp the result of `interp.searchsorted(x_q, axis_x)` to `[2, Nx]`, then subtract 1; analogously for `y`.) Both assignments are unique because step 1 guarantees `x₁ ≤ x_q ≤ x_{Nx}` and `y₁ ≤ y_q ≤ y_{Ny}`. When `x_q` lands exactly on an interior knot `xₖ` the convention selects `i = k` (so `wx = 0` and the x-blend reduces to the row at knot `k` exactly); the same blend evaluated under the alternative `i = k − 1` (so `wx = 1`) produces the bit-identical result under the pinned form, but the spec pins the convention for definiteness.
3. **Weights.**

   ```
   wx = (x_q − xᵢ) / (xᵢ₊₁ − xᵢ)
   wy = (y_q − yⱼ) / (yⱼ₊₁ − yⱼ)
   ```

4. **Two 1-D blends in x, then one in y.** Pinned evaluation order (cross-binding bit-equivalence requires this exact form, as it is the natural composition of two `interp.linear` calls along the inner axis):

   ```
   row_j   = table[i][j]   + wx · (table[i+1][j]   − table[i][j])
   row_jp1 = table[i][j+1] + wx · (table[i+1][j+1] − table[i][j+1])
   result  = row_j + wy · (row_jp1 − row_j)
   ```

5. **NaN propagation.** If `x` or `y` is NaN, the corresponding axis weight is NaN, and the result is NaN. NaN entries in `table` propagate through whichever blend touches them.

**Errors (load time):**

| Diagnostic code | Condition |
|---|---|
| `interp_non_monotonic_axis` | Any `axis` (or `axis_x`, `axis_y`) is not strictly increasing. Includes equal-adjacent and decreasing pairs. |
| `interp_axis_length_mismatch` | `interp.linear`: `len(table) != len(axis)`. `interp.bilinear`: outer length of `table` differs from `len(axis_x)`, or any row's length differs from `len(axis_y)`. |
| `interp_nan_in_axis` | Any axis contains NaN. |
| `interp_axis_too_short` | Any axis has fewer than 2 entries (no interval to blend across). |
| `interp_table_not_const` / `interp_axis_not_const` | The `table` or any axis argument is not a literal `const`-op array (e.g. it is a variable reference or a non-`const` expression). |

**Tolerance:** when bindings implement the pinned evaluation order in IEEE-754 `binary64` arithmetic, agreement is **bit-exact** (`{ "abs": 0, "rel": 0 }`) for fixtures whose inputs are exactly representable and whose intermediate arithmetic does not require an FMA (the spec does not require FMA usage; bindings that use FMA selectively MUST ensure their results still match the non-FMA reference within the per-fixture tolerance). For mixed-FMA / non-FMA cross-binding comparisons the harness MAY relax to `{ "abs": 0, "rel": 4e-16 }` (~2 ulp at unit magnitude); see `tests/closed_functions/interp/linear/expected.json` and `bilinear/expected.json` for the per-fixture tolerance fields actually applied in CI.

**Composition rationale (informative):** `interp.linear(table, axis, x)` is exactly equivalent to the following AST composition (modulo evaluation order / FMA effects, which the spec pins above):

```jsonc
// Let i = interp.searchsorted(x, axis) clamped to [2, N], i_lo = i − 1.
// Then the linear blend is:
//   table[i_lo] + (x − axis[i_lo]) / (axis[i] − axis[i_lo]) · (table[i] − table[i_lo])
// (with extrapolate-flat handled by clamping the search result before the index lookup).
```

The named primitive exists so that symbolic layers in bindings (notably the Julia MTK extension) can mark each lookup as opaque to alias elimination via `@register_symbolic`, instead of paying the structural-simplify cost of ~10 alias-eliminated intermediates per lookup. With ~230 lookups per `fastjx` photolysis evaluation (18 wavelengths × 13 species), that difference is the gap between MTK simplification finishing in seconds versus minutes-to-hours (see escalation `hq-wisp-y6g6`).

### 9.3 The `enums` block

The `enums` top-level block declares file-local symbol → positive-integer mappings used by the `enum` op (§4.5). The block's purpose is to keep human-readable categorical labels in the source file while ensuring bindings only see resolved integers downstream of load — no per-binding string-to-int convention is required.

```json
{
  "enums": {
    "land_use_class": {
      "urban": 1,
      "agricultural": 2,
      "deciduous_forest": 3,
      "coniferous_forest": 4,
      "mixed_forest": 5,
      "shrubland": 6,
      "grassland": 7,
      "wetland": 8,
      "water": 9,
      "barren": 10,
      "snow_ice": 11
    },
    "season": {
      "winter": 1,
      "spring": 2,
      "summer": 3,
      "autumn": 4
    }
  }
}
```

**Schema:**

- `enums` is a JSON object. Keys are enum names (strings); values are objects mapping **string** keys (the symbolic names) to **positive integers** (the resolved values).
- Within a single enum, integer values MUST be unique. Across enums, values MAY collide (each enum defines its own namespace).
- Two `.esm` files may declare an enum of the same name with different mappings: enums are file-local and never merged across files. References from a subsystem `ref` (§4.7) inherit the enums declared in the *referenced* file, not the enclosing one.

**Lowering contract:**

- The `enum` op (§4.5) MUST resolve at load time, before any expression evaluation. After lowering, no `enum`-op nodes remain in the in-memory representation; each is replaced by a `{"op": "const", "value": <integer>}` node. Bindings MUST NOT propagate enum strings into evaluated expressions.
- An `enum` op that names an undeclared enum (`unknown_enum`) or a symbol not declared under that enum (`unknown_enum_symbol`) MUST be rejected at load time. Loading MUST fail.

**Use with the `index` op:** the canonical use of `enums` is to keep categorical lookups portable. Tables are encoded as `const` arrays; categorical keys are written as `enum` ops; the existing `index` op (§4.3.3) does the actual lookup — the portable form of, e.g., a Wesely-style canopy resistance lookup (`enum` keys indexing a `const` resistance table, as in §4.5).

### 9.4 Conformance contract

Each function in §9.2 ships, in lockstep with the spec rev that introduces it, with:

1. A spec section (§9.2) defining arity, types, units, boundary semantics, tolerance.
2. A conformance fixture under `tests/closed_functions/<module>/<name>/` containing a canonical `.esm` file invoking the function from a trivial RHS, a reference output (`expected_<scenario>.json`) at the spec tolerance, and at least one boundary-case scenario (NaN input, edge index, leap-year boundary, negative epoch, etc.).
3. A binding implementation contract: each binding's test harness loads the fixture, evaluates the `fn` node against the inputs, and asserts per-element agreement with the reference output within the declared tolerance.

`scripts/test-conformance.sh` MUST run the closed-function fixtures across all five bindings on every PR. A binding that fails any fixture fails CI.

### 9.5 Function tables (v0.4.0)

Components that depend on tabulated functions — most prominently the `fastjx` photolysis component, with 18 actinic-flux slabs and ~220 σ-chain bindings sharing the same `(P, cos_sza, T)` axes — would otherwise inline the same data and the same axis declarations on every binding. The top-level `function_tables` block lifts each table once; the new `table_lookup` AST op references it by id. Tables are **syntactic sugar over §9.2's `interp.linear` / `interp.bilinear` / `index`**: the materialized AST a binding produces from a `table_lookup` MUST be bit-equivalent to the equivalent inline-`const` lookup. Lifting data does not change semantics.

#### 9.5.1 `function_tables` block

```jsonc
{
  "function_tables": {
    "sigma_O3_298": {
      "description": "O3 absorption cross-section vs. wavelength bin index, T=298 K.",
      "axes": [
        { "name": "lambda_idx", "values": [1, 2, 3, 4, 5, 6, 7, 8] }
      ],
      "interpolation": "linear",
      "out_of_bounds": "clamp",
      "data": [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18, 7.9e-18, 7.0e-18, 6.1e-18, 5.2e-18]
    },
    "F_actinic": {
      "description": "Actinic flux F vs. (P, cos_sza), 3 species outputs.",
      "axes": [
        { "name": "P",       "units": "Pa", "values": [10.0, 100.0, 1000.0] },
        { "name": "cos_sza",                "values": [0.1, 0.5, 1.0] }
      ],
      "interpolation": "bilinear",
      "outputs": ["NO2", "O3", "HCHO"],
      "data": [
        [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
        [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]],
        [[3.0, 3.5, 4.0], [3.1, 3.6, 4.1], [3.2, 3.7, 4.2]]
      ]
    }
  }
}
```

**Schema:**

- Each entry is a `FunctionTable` carrying `axes`, `data`, and (optionally) `description`, `interpolation`, `out_of_bounds`, `outputs`, `shape`, `schema_version`.
- `axes` is an ordered list of named `FunctionTableAxis` entries. Axis order defines the order of inner dimensions of `data` (after the leading output dimension when `outputs` is present). Axis names within a single table MUST be unique. v0.4.0 caps axis count at 2 (matching the §9.2 `interp.linear` / `interp.bilinear` set); higher-dimensional lookups are deferred until the closed registry adds `interp.trilinear`.
- Each axis declares `name`, `values` (strictly-increasing finite floats, ≥ 2 entries), and an optional advisory `units` string. **`units` is advisory in v0.4.0** — bindings record it for documentation only; load-time unit-checking against `table_lookup.axes` input expressions is deferred to a future units RFC.
- `interpolation` is `"linear"` (1 axis), `"bilinear"` (2 axes), or `"nearest"` (1 axis, lowering to `index` after `interp.searchsorted`). Default is `"linear"`. Bindings MUST reject mismatched (`linear` with 2 axes, `bilinear` with 1 axis, etc.) at load time with diagnostic `table_interpolation_axes_mismatch`.
- `out_of_bounds` is `"clamp"` (default, matches `interp.linear` / `interp.bilinear` extrapolate-flat semantics) or `"error"` (raise at evaluation time with `table_lookup_out_of_bounds`). v0.4.0 requires all five bindings to implement `"clamp"`; `"error"` is conformant when implemented.
- `outputs` is an optional ordered list of output names (strings, unique within the table). When present, the leading dimension of `data` MUST equal the length of `outputs`, and `table_lookup.output` MAY name an entry of this list in addition to using a 0-based integer index. When absent, the table is single-output and `table_lookup.output` defaults to `0`.
- `data` is the canonical, nested-array literal. Leaves MUST be finite numbers — NaN entries are rejected at load time with `table_data_nan`. Shape: `[len(outputs), len(axes[0].values), len(axes[1].values), ...]` when `outputs` is present; `[len(axes[0].values), len(axes[1].values), ...]` otherwise. Loaders verify the actual nesting; mismatched shapes raise `table_data_shape_mismatch`.
- `shape` is an optional redundant assertion on `data`'s shape. If present, MUST match the actual nesting; loaders reject mismatches. **`data` is the source of truth — `shape` is a load-time assertion only.** Round-trippers MUST NOT fabricate a `shape` field when the author did not write one.

**Authoring policy:** tables are **opt-in**. Loaders MUST NOT silently auto-promote inline `const`-op arrays into `function_tables` entries during round-trip. The migration of an existing inline-const-heavy `.esm` to `function_tables` is a one-shot author-driven refactor, not a load-time canonicalization. This preserves the existing `tests/` corpus, the `earthsci-ast-editor` round-trip property, and the `earthsci-ast-go` byte-exact reload guarantee.

#### 9.5.2 `table_lookup` AST op

```jsonc
{
  "op": "table_lookup",
  "table": "F_actinic",
  "axes": {
    "P":        "P_atm",
    "cos_sza":  { "op": "cos", "args": ["sza"] }
  },
  "output": "O3"
}
```

**Fields:**

- `table` (string, required): id of a `function_tables` entry. References to undeclared tables raise `table_lookup_unknown_table` at load time.
- `axes` (object, required): map from axis name to scalar input expression. The set of keys MUST exactly match the names of the referenced table's `axes[]` (same set, no extras, no omissions); mismatch raises `table_lookup_axis_name_mismatch`. Each value is an arbitrary scalar `Expression` (number literal, variable reference, or AST node).
- `output` (integer ≥ 0 OR string): which output to return. Integer is a 0-based index into the table's leading data dimension. String MUST be an entry of the table's `outputs` array. Out-of-range integer or unknown name raises `table_lookup_output_out_of_range`. May be omitted when the table has no `outputs` declaration (defaults to `0`).
- `args` MUST be empty `[]` for a `table_lookup` node — the per-axis input expressions live under `axes`, not `args`.

#### 9.5.3 Lowering to `interp.linear` / `interp.bilinear` / `index`

A `table_lookup` node lowers at load time to a structurally-equivalent `fn` (or `index`) tree using the existing §9.2 closed-function set. The lowered tree is bit-equivalent: a `table_lookup` query and the equivalent inline lookup that an author would have written by hand produce the same IEEE-754 `binary64` result on the same axis weights and table values, modulo the same FMA caveats described in §9.2.

For a `table_lookup` referencing a 1-axis table with `interpolation: "linear"`, output `i`, the lowered AST is:

```jsonc
{ "op": "fn", "name": "interp.linear", "args": [
    { "op": "const", "value": data[i] },           // 1-D table slice for output i
    { "op": "const", "value": axes[0].values },    // axis values
    <axis_input_expression>                         // the user-supplied axes[axis[0].name]
] }
```

For a 2-axis table with `interpolation: "bilinear"`, output `i`:

```jsonc
{ "op": "fn", "name": "interp.bilinear", "args": [
    { "op": "const", "value": data[i] },           // 2-D table slice for output i (Nx × Ny)
    { "op": "const", "value": axes[0].values },    // axis_x values
    { "op": "const", "value": axes[1].values },    // axis_y values
    <x_input_expression>,                           // axes[axes[0].name]
    <y_input_expression>                            // axes[axes[1].name]
] }
```

For `interpolation: "nearest"` on a 1-axis table:

```jsonc
{ "op": "index", "args": [
    { "op": "const", "value": data[i] },
    { "op": "fn", "name": "interp.searchsorted", "args": [
        <axis_input_expression>,
        { "op": "const", "value": axes[0].values } ] }
] }
```

Bindings MAY satisfy this lowering by an in-memory transformation at load time (resulting AST contains no `table_lookup` nodes after load) or by a thin evaluator that dispatches on `table_lookup` directly to the existing `interp.linear` / `interp.bilinear` / `index` implementations. Both are conformant. The serializer of every binding MUST round-trip the authored form (see §9.5.4).

#### 9.5.4 Round-tripping

`function_tables` and `table_lookup` are first-class authored constructs. Loaders MUST preserve them on save:

- A file whose source contains `table_lookup` nodes serializes back with `table_lookup` nodes — bindings MUST NOT canonicalize a `table_lookup` to its lowered `fn` form on save.
- A file whose source contains inline `const` lookups serializes back with inline `const` lookups — bindings MUST NOT canonicalize inline lookups into `table_lookup` references.

The migration of inline-const lookups to tables is a one-shot author-driven refactor, recorded as its own bead per component, never a load-time rewrite.

#### 9.5.5 Errors (load time)

| Diagnostic code | Condition |
|---|---|
| `table_axis_non_monotonic` | An axis's `values` is not strictly increasing. |
| `table_axis_nan` | An axis's `values` contains NaN. |
| `table_data_shape_mismatch` | The actual nesting of `data` does not match the shape implied by `axes` (and `outputs`, when present), or the redundant `shape` assertion does not match `data`. |
| `table_data_nan` | A leaf of `data` is NaN. |
| `table_interpolation_axes_mismatch` | `interpolation` and the number of axes are inconsistent (`linear` requires 1, `bilinear` requires 2, `nearest` requires 1). |
| `table_outputs_length_mismatch` | The leading dimension of `data` does not equal `len(outputs)` when `outputs` is declared. |
| `table_axis_duplicate_name` | Two axes within a single table share the same `name`. |
| `table_outputs_duplicate_name` | Two entries of `outputs` share the same name. |
| `table_lookup_unknown_table` | `table_lookup.table` references an id not declared in `function_tables`. |
| `table_lookup_axis_name_mismatch` | The set of keys in `table_lookup.axes` does not match the set of axis names declared on the referenced table. |
| `table_lookup_output_out_of_range` | `table_lookup.output` integer is ≥ `len(outputs)` (or ≥ leading dimension of `data` when `outputs` is absent), or its string is not an entry of `outputs`. |

#### 9.5.6 Conformance fixtures

Conformance fixtures under `tests/conformance/function_tables/` exercise:

1. A single-output 1-axis linear table (canonical 1-D blend) — `linear/`.
2. A multi-output 2-axis bilinear table with named outputs — `bilinear/`.
3. A roundtrip-preservation case (load + save reproduces the authored byte sequence modulo whitespace, with NO promotion or demotion across the inline-const ↔ table_lookup boundary) — `roundtrip/`.

Each fixture pairs an `.esm` file with a small numeric harness that asserts the lowered evaluation matches the equivalent inline-const lookup at the §9.2 tolerance contract (`abs: 0, rel: 0` non-FMA, `abs: 0, rel: 4e-16` mixed-FMA cross-binding). All five bindings MUST pass.

### 9.6 Rewrite rules (expression templates)

An `expression_templates` entry is a **rewrite rule**: a set of metavariable `params`, an Expression `body` (the replacement), and an optional `match` pattern. It is the **single** structural-substitution mechanism in the format, covering three cases with one engine:

| Case | `match` | Applied by |
|---|---|---|
| **Variable substitution** | a bare metavariable | binding a name → AST |
| **Named template expansion** | *absent* | an explicit `apply_expression_template` node |
| **Operator lowering** (e.g. `grad`, `div`, `laplacian`) | an operator pattern like `{op:"grad", args:["f"], dim:"d"}` | auto-applied wherever the pattern matches |

The mechanism is purely structural — no evaluation, no metaprogramming. **PDE-operator discretization — including its boundary conditions — is not special schema machinery; it is an ordinary rewrite rule** that lowers a rewrite-target op (a spatial `D` on a right-hand side, or the `grad`/`div`/`laplacian` sugar, §4.2) into an `aggregate` + `makearray` stencil with the boundary treatment baked into the `makearray` (§9.6.8). There is no separate boundary-condition declaration anywhere in the format. See `docs/content/rfcs/ast-expression-templates.md` for motivation; this section pins the normative load-time behavior.

#### 9.6.1 The `expression_templates` block

`expression_templates` is declared **inside a single `model` or `reaction_system`**, or at the top level of a **template-library file** shared across components and files via `expression_template_imports` (§9.7). It is a JSON object whose keys are template names and whose values are rewrite-rule definitions:

```json
"expression_templates": {
  "arrhenius": {
    "params": ["A_pre", "Ea"],
    "body": {
      "op": "*",
      "args": [
        "A_pre",
        {"op": "exp", "args": [{"op": "/", "args": [{"op": "-", "args": ["Ea"]}, "T"]}]},
        "num_density"
      ]
    }
  }
}
```

Required fields:

- `params`: ordered array of unique non-empty parameter (metavariable) names (strings). MAY be empty — a zero-parameter template is a named constant fragment (common in library files, e.g. a grid-spacing expression).
- `body`: a normal Expression AST (the replacement). Parameter occurrences appear as bare parameter-name strings in any variable-reference position, **and in scalar-field position**: a parameter name appearing as the string value of a scalar (non-`args`, non-Expression-valued) Expression-node field in `body` (e.g. `dim`, `side`, `wrt`, `manifold`) is a substitution site — the exact mirror of the match-side scalar-field binding rule below. The value bound to a scalar-field parameter MUST be a literal admissible for that field; substitution itself never checks this (it is pure-syntactic, §9.6.3 constraint 5) — validators run on the expanded form (§9.6.4), so an inadmissible substituted value (e.g. `manifold: "bogus"`) is rejected post-expansion by the field's own validation. **Params shadow literals**: inside `body`, a declared parameter name shadows any coincident literal string — every string value equal to a declared parameter name is a substitution site — so an author MUST NOT name a parameter after a field literal its body means literally (e.g. a parameter named `planar` over a body that pins `manifold: "planar"`), nor after an index symbol the body uses; bindings MAY surface a lint-grade diagnostic for such a collision but MUST still substitute. A body MAY reference other **match-less** in-scope templates via `apply_expression_template` nodes; these are resolved at registration time as a statically-checked acyclic DAG (§9.7.3).

Optional fields:

- `match`: a pattern Expression that makes the entry an **auto-applied rewrite rule**. Parameter names appearing as bare strings in `match` are wildcards: a parameter in an operand/`args` position binds to the matched sub-AST; a parameter in a scalar field (e.g. `dim`, `side`) binds to the matched literal. A **non-parameter** string in an operand/`args` position is a **literal**: it matches only that exact bare variable reference (numbers and booleans likewise match literally; arrays match elementwise at equal length; an object pattern constrains exactly the fields it names, extra node fields are permitted). A ground `args` entry is the sanctioned **per-variable selector** — `{"op": "D", "args": ["u"], "wrt": "x"}` with `u` not in `params` fires only on the derivative of `u`, so mixed schemes on one axis (upwind for `u`, central for `v`) are two rules with ground patterns, ranked by explicit `priority` (§9.6.8). The rule fires wherever `match` structurally matches a node and its `where` constraints (below), if any, are satisfied. When `match` is absent the entry is applied only by explicit `apply_expression_template` invocation (§9.6.2).

- `where`: **static match-scoping constraints** on the captured parameters — admissible only alongside `match` (a `where` on a match-less template is `apply_expression_template_invalid_declaration`). A JSON object whose keys are declared `params` (a non-param key is `apply_expression_template_invalid_declaration`) and whose values are constraint objects. The v1 constraint vocabulary is exactly one kind:
  - `shape`: a non-empty ordered array of index-set names. The constraint on parameter `p` is satisfied iff the sub-AST bound to `p` by the structural match is a **bare variable-reference string** naming a declaration in the enclosing component whose declared `shape` (§6, the ordered list of index-set names) equals the constraint's list exactly — same names, same order. Anything else fails the constraint: a compound sub-AST, a numeric literal, a scalar-field-bound literal, a scoped (`System.var`) reference, an undeclared name, a scalar (shapeless) variable, or a parameter that never bound. The judgment is deliberately **syntactic and conservative** — no shape inference over compound expressions — so eligibility depends only on *declarations* visible at lowering time, never on runtime values, and the §9.6.3 determinism contract (priority order, declaration-order tie-break, bounded fixpoint, byte-identical results) is untouched.

  Constraint evaluation is part of **match eligibility**: a rule whose pattern structurally matches a node but whose `where` constraints are not satisfied there is treated exactly like a non-matching rule at that node — it is filtered **before** the §9.6.3 priority/declaration-order selection, and the next candidate is considered. A constrained rule that never fires anywhere is **not** an error; if no rule remains for a rewrite-target op, the op simply survives lowering and the ordinary pre-evaluation `unlowered_operator` gate applies (§9.6.3 constraint 6, §9.6.8).

  Index-set names in a `shape` constraint resolve against the **consuming document's** merged `index_sets` registry (§9.7.5) at rule **registration** — the point where the rule enters a component's effective sequence (§9.7.4). A constraint naming an index set the registry does not declare is rejected with `template_constraint_unknown_index_set` (§9.6.6); a library file that constrains against index sets it declares itself passes when imported, because its `index_sets` merge into the consumer's registry before registration. Loading or validating a library file standalone does not run this check (no component registers its rules). Because resolution happens in the consuming registry, the mechanism composes with import-edge **index-set renaming**: a rename applied at an `expression_template_imports` edge MUST rewrite the imported templates' `where.*.shape` entries together with the imported `index_sets` and range references, so a renamed grid instance arrives with its rules constrained to the renamed sets. `where` is a structural field: metaparameter substitution (§9.7.6) never rewrites its contents.

  This is the scoping mechanism for discretization rules shared across meshes: an MPAS-style finite-volume divergence rule declares `"where": {"F": {"shape": ["edges"]}}` so it fires only on divergences of edge-fields of *its* mesh, and a second mesh's rule — constrained to `["edges_b"]` — coexists in the same component without priority games (§9.6.8).

#### 9.6.2 The `apply_expression_template` op

Reactions and any other expression positions within the same component reference templates via:

```json
"rate": {
  "op": "apply_expression_template",
  "args": [],
  "name": "arrhenius",
  "bindings": {"A_pre": 1.8e-12, "Ea": 1500}
}
```

Required fields:

- `name`: id of an `expression_templates` entry declared in the same component or imported into it via `expression_template_imports` (§9.7.2). Only match-less entries are invocable by name; a `match` rule is a rewrite step, not a named fragment.
- `bindings`: object mapping each parameter in the referenced template's `params` to a value. Values MAY be numeric literals, variable name references, or arbitrary Expression ASTs (full subtrees).
- `args`: MUST be an empty array.

#### 9.6.3 Constraints (normative)

1. **AST → AST only.** Rules take Expression args and produce an Expression. No string interpolation, no schema-level substitution, no metaprogramming.
2. **Outermost-first, priority-ordered, bounded fixpoint.** Rule application is a sequence of **passes**; one pass is a single **pre-order (outermost-first)** walk of the expression tree. At each node visited, the engine considers every `match` rule whose pattern structurally matches that node **and whose `where` constraints (§9.6.1), if any, are satisfied by the resulting bindings** — constraint filtering is part of match *eligibility* and therefore happens **before** the priority/declaration-order selection: a constraint-excluded rule is a non-matching rule at this node, exactly as if its pattern had failed structurally (in particular, a high-`priority` constraint-excluded rule never shadows a lower-priority rule that does fire). From the eligible set the engine selects the winner **deterministically**: highest `priority` (integer, default `0`); ties broken by **declaration order** (earliest wins). Constraint evaluation reads only declared variable shapes (§9.6.1) — static, load-time information — so eligibility, and with it the fixpoint, remains byte-identical across bindings. The winner's `body` (instantiated by pure substitution, constraint 5) replaces the node, and the engine does **not** descend into the freshly-produced body during the current pass; if no rule matches a node, the walk descends into its children. Passes repeat until a pass performs **zero** rewrites (the fixpoint) or until `MAX_REWRITE_PASSES = 64` passes have run without converging, in which case the file is rejected with diagnostic `rewrite_rule_nonterminating` (naming the last-rewritten node). The pass bound is the authoritative termination guard — a self-reintroducing rule simply fails to converge. "Declaration order" is the **effective sequence** of §9.7.4 (imports depth-first post-order, then local declarations); without imports it degenerates to file order as before. A `body`'s `apply_expression_template` references are resolved at registration time (§9.7.3) into a statically-checked acyclic DAG — cyclic reference is `apply_expression_template_recursive_body` — so by the time the engine runs, every rule body is a closed AST; `match` patterns MUST NOT contain `apply_expression_template` nodes. Because selection and traversal are fully deterministic, all five bindings MUST produce byte-identical fixpoints (or the same non-convergence rejection). **Compound precedence:** a rule matching a *compound* term (e.g. a Godunov Hamiltonian `sqrt(add(pow(D(u,x),2), pow(D(u,y),2)))`) declares a higher `priority` than the plain per-derivative rule, so under outermost-first selection it fires on the whole compound **before** the inner `D(u,x)` is lowered. The engine never *infers* specificity; precedence is the author's explicit, portable choice.
3. **Typed signatures (positional-by-name).** Bindings MUST cover every entry of the template's `params` exactly — no missing keys, no extras.
4. **Component-local scope.** Templates declared inside — or imported into (§9.7.2) — one `model` / `reaction_system` are visible only within that component's expression positions.
5. **Pure syntactic substitution.** Every parameter occurrence in `body` — a bare parameter-name string in a variable-reference position, or the string value of a scalar Expression-node field (§9.6.1) — is replaced by the bound argument's AST in source order. Substitution is position-blind and purely syntactic: a declared parameter name shadows any coincident field literal or index symbol inside `body`, no evaluation occurs, and no field-specific admissibility is checked at substitution time — a value substituted into a scalar-field position MUST be a literal admissible for that field, enforced by the post-expansion validators (§9.6.4), never by the substitution engine. Expansion MUST NOT depend on argument evaluation.
6. **Rewrite-target operator gate (before evaluation).** Loading is permissive: a file MAY load with rewrite-target ops still present, so fixtures that merely carry `grad`/`div`/`laplacian`/spatial-`D` as content (coupling, scoping, units examples that never simulate) are unaffected. But before a component is EVALUATED or COMPILED for simulation, its expression trees are walked; any node whose `op` is not in the evaluable-core set (§4.2) — including a spatial `D`, or any `D` in a right-hand-side / evaluation position — is rejected with diagnostic `unlowered_operator` (naming the op and node path). This is the sole guarantee that a rewrite-target op cannot reach evaluation. Parse/validate-only tooling that never builds an evaluator need not run the gate.

#### 9.6.4 Round-trip — Option A (always-expanded)

The v1 round-trip model is **Option A: parse-time expansion**. There is no Option B in v1.

1. **Expansion happens at load.** Loaders MUST expand `apply_expression_template` to a fully-substituted Expression AST before any validator, evaluator, doc generator, or `esm-write` sees the tree. After load, downstream code operates on a normal Expression AST and MUST NOT branch on whether a node was produced by template expansion.
2. **Round-trip emits the expanded form.** The canonical AST stored on disk after `parse → emit` is the expanded form. Source `.esm` files that author with `expression_templates` and `apply_expression_template` are the **source of truth**; the emitter does not re-derive template references from an expanded AST.
3. **Determinism.** Two fresh expansions of the same `(template, bindings)` pair MUST produce structurally identical ASTs (same op tree, bit-equal constants). Bindings MAY cache expanded ASTs but caching MUST NOT be observable.
4. **Validators run on the expanded form.** Schema validation, type checks, and domain checks (every check defined in §4 / §9 of the spec) run on the post-expansion AST.

#### 9.6.5 Spec-version gate

`expression_templates` and `apply_expression_template` arrive at `esm: 0.4.0`. Files declaring `esm: 0.3.x` or earlier MUST be rejected by all five bindings if they carry either construct, with diagnostic `apply_expression_template_version_too_old`.

`expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at `esm: 0.8.0`. Files declaring an earlier version MUST be rejected by all five bindings if they carry any of these constructs, with diagnostic `template_import_version_too_old`.

#### 9.6.6 Diagnostics

Bindings MUST emit the following stable diagnostic codes (cross-language uniform; see RFC §1).

| Code | Meaning |
|---|---|
| `apply_expression_template_version_too_old` | File declares `esm` < 0.4.0 but uses `expression_templates` or `apply_expression_template`. |
| `apply_expression_template_unknown_template` | `apply_expression_template.name` references a template not declared in the enclosing component. |
| `apply_expression_template_bindings_mismatch` | `bindings` does not exactly match the template's `params` (missing or extra keys). |
| `apply_expression_template_recursive_body` | A template-body reference cycle (self or mutual) in the §9.7.3 registration-time DAG. (Redefined by the template-library RFC: acyclic body references are now legal and inlined at load.) |
| `apply_expression_template_invalid_declaration` | `params` is missing/empty/duplicates entries, `body` is missing, a malformed `where` block (§9.6.1: `where` without `match`, a key that is not a declared param, an unknown constraint kind — v1 admits exactly `shape` — or an empty/non-string `shape` list), or other structural defects. |
| `rewrite_rule_nonterminating` | The rewrite fixpoint did not converge within `MAX_REWRITE_PASSES` (64) passes (§9.6.3). |
| `unlowered_operator` | A rewrite-target op (§4.2) reached evaluation/compilation without being lowered — no rule eliminated it. Fires before evaluation, not necessarily at load (loading is permissive). One uniform code superseding the former per-language spatial-op errors (`E_TREEWALK_UNREACHABLE_SPATIAL_OP` / `UnreachableSpatialOperatorError` / `UnsupportedDimensionalityError`). |
| `template_import_version_too_old` | File declares `esm` < 0.8.0 but carries `expression_template_imports`, top-level `expression_templates`, or `metaparameters` (§9.6.5). |
| `template_import_unresolved` | An import `ref` failed to load or parse (reports path/URL and cause) (§9.7.2). |
| `template_import_not_library` | Import target is not a pure template-library file (§9.7.1). |
| `subsystem_ref_is_template_library` | A §4.7 subsystem `ref` targets a template-library file. |
| `template_inject_target_unknown` | A `CouplingEntry.expression_template_imports` key (§9.7.10) names no system referenced by that entry. |
| `template_inject_target_is_loader` | A coupling-entry injection key (§9.7.10) resolves to a data loader — pure I/O with no expression positions to rewrite. |
| `template_inject_target_not_component` | A coupling-entry injection key (§9.7.10) resolves to something that is neither model, reaction system, nor loader. |
| `subsystem_index_set_conflict` | A §4.7 subsystem ref's merged top-level `index_sets` name collides with a non-deep-equal definition in the importing document's registry (§4.7 "Index-set merge"; the subsystem-edge mirror of `template_import_index_set_conflict`). |
| `template_import_cycle` | Import-graph cycle over canonical paths (§9.7.2). |
| `template_import_name_conflict` | Same template or metaparameter name reaches one scope with non-deep-equal definitions (§9.7.4). |
| `template_import_unknown_name` | `only` names a template the target does not declare (§9.7.2); or a metaparameter binding — at an import edge, a subsystem edge, or the loader API — names a metaparameter the target document neither declares nor re-exports (§9.7.6). |
| `template_import_index_set_conflict` | Merged `index_sets` name collides with a non-deep-equal definition (§9.7.5). |
| `template_import_rename_unknown_name` | An import edge's `rename` names a name the target does not export at that edge — the surviving exports are templates after `only`, index sets, and metaparameters left open by the edge's `bindings` (§9.7.7). |
| `template_import_rebind_unknown_name` | An import edge's `rebind` names a name that does not occur free in the imported declarations — including a key that names a *declared* name, which is a rename, not a rebind (§9.7.7). |
| `template_import_rename_collision` | Renaming/rebinding produced a collision: two names of one namespace mapped onto one target, or a renamed/rebound name collides with a name still in use inside the imported declarations (a remaining free name, bound index symbol, template param, or another target) (§9.7.7). |
| `template_import_rename_invalid` | A `prefix` or rename/rebind target is not a valid dotted identifier, a rename/rebind map is malformed, or a `rebind` key addresses a bound index symbol (§9.7.7). |
| `template_body_expansion_too_deep` | Body-reference chain exceeds `MAX_TEMPLATE_EXPANSION_DEPTH` (32) (§9.7.3). |
| `metaparameter_unbound` | A metaparameter is still open after edge bindings, API bindings, and defaults (§9.7.6). |
| `metaparameter_type_error` | A metaparameter binding is not an integer; a fold divides inexactly or overflows 64-bit; or a metaparameter expression uses an op outside `+ - * /` (§9.7.6). |
| `metaparameter_name_conflict` | A metaparameter name collides with a visible variable/parameter/species/index-set name (§9.7.6). |
| `makearray_region_inverted` | A `makearray` region bound pair on the expanded, metaparameter-folded form has `stop < start − 1` (§4.3.2). The empty spelling `stop == start − 1` is legal and contributes no elements; anything further inverted is rejected — typically a §9.6.8 interior region instantiated below the scheme’s minimum extent. |
| `geometry_manifold_invalid` | A geometry-kernel node's `manifold` is not an admissible literal (`planar`/`spherical`/`geodesic`) on the **expanded** tree — the post-expansion enforcement for the scalar-field substitution sites of §9.6.1 (the schema admits arbitrary strings there so template bodies may carry parameter names; §9.6.4). |
| `template_constraint_unknown_index_set` | A `where` `shape` constraint (§9.6.1) names an index set the consuming document's merged `index_sets` registry (§9.7.5) does not declare. Raised at rule registration in the consuming component — a loud typo failure, mirroring `template_import_unknown_name`. A constrained rule that merely never fires is NOT an error. |

#### 9.6.7 Conformance fixtures

Conformance fixtures live under `tests/conformance/expression_templates/`. The v1 set:

- `arrhenius_smoke/fixture.esm` — a 2-parameter `arrhenius` template applied across three reactions with different scalar bindings.
- `arrhenius_smoke/expanded.esm` — the canonical post-expansion form. All five bindings (Julia, Python, Rust, TypeScript, Go) MUST produce a structurally-equal `reactions` array on load.
- `scalar_field_param/` — the §9.6.1 scalar-field substitution site: one template parameterized on the `manifold` scalar field of a `polygon_intersection_area` node, instantiated twice (`planar` / `spherical`), plus the Julia-generated `expanded.esm`. All five bindings MUST produce structurally-equal post-substitution nodes; an inadmissible bound value is rejected on the expanded form (§9.6.4).

The template-library RFC adds (see `docs/content/rfcs/template-library-imports.md` §11):

- `import_smoke/` — the §9.7 four-file layering (grid → interior stencil → BC rule → consuming model) plus `expanded.esm`.
- `import_diamond/` — diamond import with deep-equal dedup.
- `import_order_determinism/` — equal-priority rules from two libraries: winner pinned by import order, then flipped by explicit `priority`.
- `metaparameter_resolutions/` — one problem file instantiated at two sizes via subsystem-ref `bindings` → two goldens.

The import-renaming RFC adds (see `docs/content/rfcs/template-import-renaming.md` §7):

- `import_rename_two_instances/` — one grid-family library imported twice under prefixes `fine`/`coarse` at N = 16/8; transitive rename through index sets, ranges, and match `wrt` (§9.7.7).
- `import_rebind_keyed_factors/` — an MPAS-style ragged keyed-factor rule with its factor contract rebound to the consumer's `meshA_*` arrays (§9.7.7).
- `import_rename_diamond/` — identical renamed edges dedupe; a differently-renamed edge registers distinctly; the equal-priority tie between two axis-less rule instances is pinned by the §9.7.4 order (§9.7.7).

The match-scoping RFC adds (see `docs/content/rfcs/match-pattern-scoping-constraints.md`):

- `constrained_match_scope/` — one document, one shape-constrained `div` rule, two shaped variables: only the conforming variable's `div` is rewritten; the other survives lowering intact (positive + negative in one expanded golden).
- `two_div_two_meshes/` — two equal-priority `div` rules, each `where`-scoped to its own mesh's edge set: each `div` lowers by its own mesh's rule, with no `priority` games (the pre-`where` engine would have sent both to the first-declared rule).
- `per_variable_scheme_literal_args/` — the sanctioned ground-pattern per-variable selector: an upwind rule matching literal `u` (priority 10) and a generic central rule capturing everything else, mixed schemes on one axis.
- `constraint_unknown_index_set/` — invalid: a `shape` constraint naming an undeclared index set → `template_constraint_unknown_index_set` at load.

#### 9.6.8 Discretizing spatial derivatives (rewrite rules over `D`)

A spatial derivative — a `D` op with a spatial `wrt`, appearing on a right-hand side — is a **rewrite-target** (§4.2): it has no evaluator and MUST be lowered to an `aggregate` + `makearray` stencil by a `match` rewrite rule (§9.6) before evaluation, exactly as `table_lookup` lowers to `interp.*` (§9.5). There is **no** discretization block and **no** boundary-condition declaration anywhere in the format. A discretized derivative over a finite domain is inseparable from its boundary treatment, so **the boundary conditions are part of the rewrite rule itself**: the rule body is a single `makearray` whose interior region is the stencil `aggregate` and whose boundary-face regions encode the BC (later regions overwrite earlier, §4.3.2). Boundary conditions cannot be — and must not be — specified anywhere else.

**This format ships no discretization rules.** The standard library of finite-difference / finite-volume rules (central, upwind, WENO, Godunov, the BC variants) and its conformance golden live in [EarthSciDiscretizations](../earthscidiscretizations). A `.esm` file obtains discretization either by declaring in-file `expression_templates` with a `match` on `D`, or by importing a rule from that library via `expression_template_imports` (§9.7). The library is layered — a grid file (index sets + geometry metaparameters), an interior-stencil file importing it, and a BC file importing *that* and wrapping the stencil into the complete `match` rule — so one rule file serves every resolution through metaparameter bindings (§9.7.6).

A discretization rule names its scheme and BC in its identity. `central_D_lon_zero_grad_bc` matches `D(f, wrt: "lon")` and builds a `makearray` from the interior central-difference `aggregate` plus two one-sided boundary faces for the zero-gradient condition (here over a grid with `lon` size 144, `lat` size 91):

```json
"central_D_lon_zero_grad_bc": {
  "params": ["f"],
  "match": { "op": "D", "args": ["f"], "wrt": "lon" },
  "body": {
    "op": "makearray",
    "regions": [ [[2, 143], [1, 91]], [[1, 1], [1, 91]], [[144, 144], [1, 91]] ],
    "values": [
      { "op": "aggregate", "output_idx": ["i", "j"], "args": ["f"],
        "ranges": { "i": [2, 143], "j": { "from": "lat" } },
        "expr": { "op": "/", "args": [
          { "op": "-", "args": [
            { "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }, "j"] },
            { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }, "j"] } ] },
          { "op": "*", "args": [2, "dx"] } ] } },
      { "op": "aggregate", "output_idx": ["j"], "args": ["f"],
        "ranges": { "j": { "from": "lat" } },
        "expr": { "op": "/", "args": [
          { "op": "-", "args": [ { "op": "index", "args": ["f", 2, "j"] },
                                 { "op": "index", "args": ["f", 1, "j"] } ] }, "dx" ] } },
      { "op": "aggregate", "output_idx": ["j"], "args": ["f"],
        "ranges": { "j": { "from": "lat" } },
        "expr": { "op": "/", "args": [
          { "op": "-", "args": [ { "op": "index", "args": ["f", 144, "j"] },
                                 { "op": "index", "args": ["f", 143, "j"] } ] }, "dx" ] } }
    ]
  }
}
```

The first region fills the interior columns (`i ∈ [2,143]`) with the centered difference; the two single-cell faces (`i=1`, `i=144`) hold the one-sided (zero-gradient) difference. The three regions tile the axis, so the discretized derivative is fully defined with its BC and there is nowhere else a boundary condition could live. At the scheme's **minimum admissible extent** the interior region folds **empty** — a metaparameterized `[2, N−1]` (§9.7.6) at `N = 2` folds to `[2, 1]`, contributing no cells while the two faces still tile the axis; this loads cleanly (§4.3.2). Binding **below** the minimum extent folds the region **inverted** (`[2, N−1]` at `N = 1` → `[2, 0]`) and is rejected at load with `makearray_region_inverted` (§4.3.2, §9.6.6) — the rule's stencil cannot exist on that grid, and failing loudly at the binding site is what surfaces the mis-sized instantiation.

**Choosing a scheme = choosing a rule** (central, upwind, WENO, a specific BC). A periodic-BC rule gathers with the `periodic` boundary policy (CONFORMANCE_SPEC §5.5.5) and needs no face overrides; a Dirichlet rule overwrites the faces with the fixed value; a Robin rule overwrites with the solved boundary expression; a rule for a seam shared with another variable overwrites the face with an `index` into that variable. A **compound** scheme (Godunov / WENO / flux-limited) out-ranks the plain per-derivative rule via `priority` (§9.6.3), so it fires on the whole compound before the inner `D`s are lowered.

**Scoping a rule = constraining or grounding its match** (§9.6.1). A rule that matches only on `(op, wrt)` — or, like a finite-volume `div` rule, on the bare op — fires on *every* such node in the importing component, so two grids each contributing a `div` scheme, or two different schemes on one axis, would otherwise collide. Two orthogonal, fully static selectors close this:

- **Mesh/shape scoping (`where`)**: the rule declares which index sets its operand must be declared over — e.g. an MPAS finite-volume divergence adds `"where": {"F": {"shape": ["edges"]}}`, so it lowers `div` only of edge-fields of its own mesh; a second mesh's rule, constrained to its own (possibly import-renamed) edge set, coexists in the same component with no `priority` arbitration. An unrelated consumer variable that merely reuses an axis *name* from some other grid is not captured unless it is literally declared over that registry entry.
- **Per-variable selection (ground `args`)**: a non-parameter string in an `args` position matches only that exact variable reference, so `{"op": "D", "args": ["u"], "wrt": "x"}` is the upwind-for-`u` rule and a generic `{"op": "D", "args": ["f"], "wrt": "x"}` rule (declared alongside, out-ranked via `priority`) carries every other variable — mixed schemes on one axis without touching the engine.

Both selectors filter **before** the §9.6.3 priority/declaration-order selection, and both compose with the `unlowered_operator` gate unchanged: if the only candidate rule for a spatial `D`/`div` is constraint-excluded (or ground-mismatched), the node is simply not rewritten, the fixpoint converges with the rewrite-target intact, and the pre-evaluation gate rejects it exactly as if no rule had been imported at all. An unsatisfied constraint is never itself an error.

**`grad`/`div`/`laplacian` are not privileged** — they are not evaluable-core ops and this format ships no rules for them. They exist only as *optional author sugar*, definable by a one-line rewrite rule, e.g.:

```json
"grad_is_Dx": {
  "params": ["f"],
  "match": { "op": "grad", "args": ["f"], "dim": "x" },
  "body":  { "op": "D",    "args": ["f"], "wrt": "x" }
}
```

after which the ordinary `D`-discretization rules apply. `div`/`laplacian` are sugar for sums/compositions of `D`; the bounded fixpoint (§9.6.3) lowers the resulting nested `D`s on subsequent passes. A rule author MAY instead match `laplacian` directly and emit a one-shot 5-point stencil — the open namespace (§4.2) permits either.

**Determinism.** Lowering is the outermost-first, priority-ordered, bounded-fixpoint rewrite of §9.6.3. Two bindings expanding the same file MUST produce byte-identical post-lowering ASTs (or the same non-convergence / `unlowered_operator` rejection).

### 9.7 Template libraries, cross-file imports, and metaparameters

This section makes `expression_templates` shareable across files and components, and makes structurally integer sites (index-set sizes, dense ranges, region bounds) parameterizable at load. All resolution happens at load, before validation and before the §9.6.3 fixpoint — the engine, its determinism contract, and the `unlowered_operator` gate are untouched. Motivation and design history: `docs/content/rfcs/template-library-imports.md`.

#### 9.7.1 Template-library files

A **template-library file** is a valid ESM document (`esm`, `metadata`) whose payload is top-level `expression_templates` (required, non-empty), plus optionally top-level `index_sets`, `metaparameters` (§9.7.6), and `expression_template_imports` (libraries may layer on other libraries). It MUST NOT declare `models`, `reaction_systems`, `data_loaders`, `coupling`, or `domain`. Purity keeps the two reference mechanisms disjoint: a §4.7 subsystem file is never importable as a library (`template_import_not_library`), and a library file is never includable as a subsystem (`subsystem_ref_is_template_library`).

#### 9.7.2 The `expression_template_imports` field

An **ordered array** appearing (i) inside a `model` or `reaction_system`, or (ii) at the top level of a library file. Each entry:

| Field | Required | Meaning |
|---|---|---|
| `ref` | ✓ | Path or URL of a template-library file. Reference format and resolution timing are §4.7's, verbatim: relative paths resolve against the referencing file's directory — for a URL-loaded library, against its URL directory by URL joining; resolution happens at load, before validation; cycle detection over canonical paths, with URL identity canonicalized (dot segments removed, relative spellings joined) (`template_import_cycle`). A `ref` that fails to load or parse is `template_import_unresolved`. URL refs are an OPTIONAL binding capability (§4.7): a binding without remote support MUST reject them with `template_import_unresolved`. |
| `only` | | Array of template names to import; absent = all. Naming a template the target does not declare is `template_import_unknown_name`. `only` filters visibility for the importer — the target file's own internal wiring resolves in its own scope first. |
| `bindings` | | Object binding the target document's open metaparameters to integers (§9.7.6). Binding a name the target neither declares nor re-exports is `template_import_unknown_name` (§9.7.6). |
| `prefix` | | Namespace prefix (§9.7.7): every surviving exported name — templates after `only`, index sets, metaparameters still open after this edge's `bindings` — without an explicit `rename` entry is renamed to `<prefix>.<name>`, transitively through the imported declarations. Grammar: dotted identifier, else `template_import_rename_invalid`. |
| `rename` | | Explicit per-name renames, exported name → importer-visible name; entries override `prefix` (§9.7.7). A key that names nothing the target exports at this edge is `template_import_rename_unknown_name`; targets are dotted identifiers; post-rename collisions are `template_import_rename_collision`. |
| `rebind` | | Free-name rebinding map, free name → replacement variable name (§9.7.7): rewrites free variable names occurring in the imported template bodies/matches and in ragged index-set `offsets`/`values` keyed factors (e.g. `areaCell` → `meshA.areaCell`). A key that does not occur free in the surviving declarations is `template_import_rebind_unknown_name`. |

#### 9.7.3 Registration-time body composition

A template `body` MAY contain `apply_expression_template` nodes referencing other templates that are **in scope** (declared locally or imported) and **match-less**. After the effective sequence (§9.7.4) is fixed and before the §9.6.3 fixpoint runs, the loader builds the body-reference graph, rejects cycles (`apply_expression_template_recursive_body`) and chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH = 32` (`template_body_expansion_too_deep`), and inlines in topological order by pure substitution (§9.6.3 constraint 5). Substitution is confluent, so topological order cannot affect the result. By the time any `match` rule is considered, every rule body is a closed Expression AST containing zero `apply_expression_template` nodes. `match` patterns MUST NOT contain `apply_expression_template` nodes.

#### 9.7.4 Effective declaration order

The §9.6.3 tie-break order with imports is the **depth-first post-order over the import DAG**: the effective sequence of a component (or library file) is, for each entry of its `expression_template_imports` in array order, the imported file's effective sequence; then its own declarations in declaration order. Deep-equal duplicates arriving via diamond imports deduplicate at first occurrence; a same-name collision with non-deep-equal definitions — import/import or import/local — is `template_import_name_conflict`. The engine never infers precedence across libraries: inter-library precedence is stated with explicit `priority`; the effective sequence only breaks exact ties.

Renaming (§9.7.7) applies per edge **before** this merge, so the effective sequence and its dedup/conflict checks operate on post-rename names and post-rebind definitions: the same file imported under different renames contributes **distinct registrations** (there is no deep-equal dedup *across* renames — that is the point; two instances of one library coexist), each entering the sequence at its own edge's position; edges identical in `ref`, instantiation, and renames/rebinds still produce deep-equal definitions and dedupe at first occurrence as before. A renamed `match`-rule instance keeps its authored `priority`; when two instances' patterns still match the same node (a pattern that mentions no renamed name), the earlier edge wins exact ties by this order (§9.7.7).

#### 9.7.5 `index_sets` merge

An imported file's top-level `index_sets` merge into the importing **document's** document-scoped registry, after metaparameter instantiation and after any edge renaming (§9.7.7) — i.e. under their **post-rename** names, with any rebound keyed factors already rewritten. This lets a grid library file own its axes: a consuming model's variables are shaped over the merged names without redeclaring them — and lets two instances of one grid family coexist as, e.g., `fine.x` and `coarse.x`. Deep-equal redeclaration is idempotent; a non-equal collision is `template_import_index_set_conflict`. A §4.7 subsystem reference edge merges the referenced file's top-level `index_sets` the same way, with its own diagnostic (`subsystem_index_set_conflict`, §4.7).

#### 9.7.6 Load-time metaparameters

A top-level `metaparameters` object declares document-scoped named integers:

```json
"metaparameters": {
  "NLON": { "type": "integer", "default": 144, "description": "zonal cell count" },
  "NLAT": { "type": "integer", "default": 91 }
}
```

`type` is required and MUST be `"integer"` (the only kind). A metaparameter name MUST NOT collide with any variable, parameter, species, or index-set name visible in the document (`metaparameter_name_conflict`); there is no shadowing.

**Admissible sites.** A *metaparameter expression* is an integer literal, a declared metaparameter name, or `{"op": <"+"|"-"|"*"|"/">, "args": [...]}` over metaparameter expressions (unary `-` allowed). Metaparameter expressions are admissible wherever the schema previously required a bare integer in a structural position: `index_sets.<name>.size` (interval kind), `aggregate` dense `ranges` tuple entries, `makearray` `regions` bound pairs, **and as an import-edge / subsystem-edge binding VALUE** (`expression_template_imports[k].bindings` / a §4.7 subsystem-ref `bindings`, below). These sites fold to concrete integers at load with exact 64-bit integer arithmetic; `/` MUST divide exactly, and overflow is an error (`metaparameter_type_error`). A binding value's free names resolve in the **importing** document's metaparameter scope, so a child metaparameter may be *derived* from the importer's — e.g. a regridder mounted with `{"NTGT": {"op": "*", "args": ["NX", "NY"]}}` closes its target-cell count from the fire grid's `NX`/`NY` in one edge, which import renaming (name→name, §9.7.7) cannot express. In ordinary **expression positions**, a metaparameter name appears as a bare string (the variable-reference surface syntax) and is substituted as an integer literal at load; no folding happens in expression positions — `{"op": "/", "args": [360, "NLON"]}` becomes `{"op": "/", "args": [360, 144]}` and stays an AST division.

**Binding sites and value flow.** Bindings flow down the reference DAG; open metaparameters flow up:

1. **Import edge** — `expression_template_imports[k].bindings` closes the named metaparameters of the imported document; the imported subtree is instantiated with those values before its templates and index sets enter the importer's scope. A binding value is a metaparameter expression (above); because the importer's own metaparameters are not yet closed at edge time (innermost-first, "Ordering within load" below), a value carrying open importer names is substituted **symbolically** into the child and **folds when the importing document closes** — the same deferred fold that leaves an open index-set size symbolic until its binding site.
2. **Re-export** — metaparameters left unbound at an edge are inherited into the importing document's own metaparameter scope (deep-equal declarations dedupe; conflicts are `template_import_name_conflict`), so binding once at the top of a chain reaches the grid file at the bottom.
3. **Subsystem edge** — a §4.7 `{"ref": …}` reference MAY carry the same `bindings` field, closing the referenced document's metaparameters (e.g. a convergence wrapper instantiating a problem file at a given size, or a regridder deriving `NTGT` from the mount's `NX`/`NY`). A subsystem ref is resolved as a **complete document and folded to concrete integers at the mount**, so — unlike an import edge — its binding values cannot be carried symbolically: each folds **immediately** against the mounting document's already-closed metaparameter environment (the mounting document closes its own metaparameters before its refs resolve, "Ordering within load"). Consequently a subsystem-edge binding value's free names MUST already be closed in the mounting scope.
4. **Loader API** — hosts MAY bind the root document's open metaparameters at load.
5. **Defaults, last** — after API bindings, a still-open metaparameter takes its `default`; one with no default is `metaparameter_unbound`.

**Binding an unknown name is an error.** At every binding site that names metaparameters — an import edge's `bindings` (site 1), a subsystem edge's `bindings` (site 3), or the loader API (site 4) — naming a metaparameter the target document neither declares nor re-exports raises `template_import_unknown_name` (§9.6.6). The same diagnostic covers a binding VALUE whose metaparameter expression references a **free name absent from the importing document's scope** (a mount-edge typo): the failure is reported at the edge that authored the expression, not deferred to a downstream size mismatch. Bindings never invent metaparameters; a typo fails loudly instead of silently binding nothing.

Because instantiation happens per edge, a diamond whose two paths bind the same file differently produces non-deep-equal definitions and is rejected by the existing conflict diagnostics.

**Ordering within load.** Per document, innermost-first: resolve imports (recursively, instantiating at each edge) → merge index sets → close and fold this document's metaparameters → §9.7.3 body composition → the §9.6.3 fixpoint on fully-concrete trees. An import-edge binding expression carrying open importer names is substituted at the edge but only **folds at the "close and fold this document's metaparameters" step**, once those names are bound — so a child index-set size derived from an importer metaparameter (`NTGT = NX*NY`) becomes concrete together with the importer's own sizes, not before. Because a §4.7 subsystem ref is resolved as its own complete document only **after** the mounting document has closed its metaparameters (subsystem refs resolve post-close), its binding expressions fold against that closed environment and the mounted form is fully concrete when it splices in — the load stays deterministic and byte-identical across bindings. Validators run on the folded, expanded form (§9.6.4). Round-trip emits the expanded, folded form; `expression_template_imports`, `metaparameters`, and top-level `expression_templates` do not survive `parse → emit`; source files remain the source of truth.

#### 9.7.7 Import renaming, namespacing, and free-name rebinding

A library's declared names are generic by design — a grid family declares index set `x` and metaparameter `N`, not `x_fine_run3` — and the no-edit bar of §9.7.1 forbids copying-and-renaming library files. Deep-equal merging (§9.7.4/§9.7.5) makes name collisions loud but, alone, leaves no way to instantiate one library twice (two grids of one family at different sizes, two regrid pairs, two meshes) or to import a library whose names collide with the consumer's own. Import edges therefore carry three OPTIONAL renaming fields — `prefix`, `rename`, `rebind` (§9.7.2) — that translate the imported names into the importer's vocabulary at load. Renaming is **pure load-time substitution**: it runs before the §9.7.4 merge, before §9.7.3 body composition in the consumer's scope, and before the root document's metaparameter close, and it has no effect on canonical bytes, on §9.6.3 selection/tie-breaking (beyond the names themselves), or on `MAX_TEMPLATE_EXPANSION_DEPTH`.

**Edge pipeline (normative).** For one `expression_template_imports` entry, in order: (1) the target resolves in its OWN scope — its own imports (with *their* renames), its own declarations, §9.7.3 body composition — under its authored names; (2) `bindings` instantiate (§9.7.6 site 1); (3) `only` filters template visibility; (4) `prefix`/`rename`/`rebind` apply to everything that survives; (5) the result merges (§9.7.4/§9.7.5). Consequently `only`, `bindings`, `rename`, and `rebind` all speak the **target's export vocabulary** — post the target's own internal renames, pre this edge's. At a deeper edge the already-renamed name IS the export name: a library that mounted a grid under `prefix: "g"` re-exports the still-open metaparameter as `g.N`, and its importer binds `{"g.N": 16}` (or the loader API binds `l.g.N` after another prefix). Prefixes nest.

**Rename domain and targets.** The *surviving export set* of an edge is: templates after `only`; all index sets; metaparameters still open after this edge's `bindings`. A `rename` key MUST name a member of that set — renaming a metaparameter the same edge just closed, a template `only` filtered out, or a misspelled name is `template_import_rename_unknown_name`; renames never invent names. `prefix` renames every surviving name without an explicit `rename` entry to `<prefix>.<name>`; `rename` entries override the prefix. Targets (and `prefix`) MUST be dotted identifiers — segments `[A-Za-z_][A-Za-z0-9_]*` joined by single dots — else `template_import_rename_invalid`. Identity renames are no-ops. Within each namespace (templates, index sets, metaparameters) the post-rename names MUST be distinct, else `template_import_rename_collision`.

**Transitivity (normative occurrence sites).** A rename rewrites the declaration key AND every reference to the old name inside the surviving imported declarations:

- *index set*: registry key; `of` parent lists of ragged/derived index-set definitions; `{"from": <name>}` references wherever the form is admitted; and the `wrt`/`dim` axis scalar fields of Expression nodes in template `body` **and `match`** — so a rule matching `D(f, wrt: "x")` imported under `prefix: "fine"` becomes an instance matching `D(f, wrt: "fine.x")`, firing only on its own axis. Template `params` shadow coincident names exactly as in §9.6.1.
- *metaparameter*: declaration key; every bare-string occurrence in expression positions of template bodies/matches (the §9.7.6 variable-reference surface syntax, param-shadowed); and names inside metaparameter expressions in the structural integer sites (index-set `size`, `aggregate` dense `ranges`, `makearray` `regions`). Later binding sites (deeper edges, loader API, defaults) close the metaparameter under its new name.
- *template*: scope key; `apply_expression_template.name` references in the surviving bodies (in practice already inlined by the target's own §9.7.3 composition, but bindings that compose lazily MUST rewrite them).

**Free-name rebinding.** `rebind` maps *free* names — names the target does not declare: strings in variable-reference positions of template bodies/matches (including `aggregate` `args` entries and `index` gathers) and the `offsets`/`values` keyed factors of ragged index sets — to replacement variable names. This is the mechanism that (a) lets two instances of a keyed-factor rule family (the MPAS pattern: `areaCell`, `dvEdge`, `nEdgesOnCell`, `edgesOnCell`, `edgeSignOnCell`) coexist by pointing each instance at its own mesh's arrays, and (b) un-reserves the library's factor names in the consumer, which may then use them for unrelated variables. A dotted target is an ordinary §4.6 scoped reference (e.g. `meshA.areaCell` into a mounted subsystem) — exactly the alias the bare-name-observed-alias pattern builds by hand. A `rebind` key MUST occur free in the surviving declarations: a key that occurs nowhere, or that names a *declared* name (use `rename`), is `template_import_rebind_unknown_name`; a key that addresses a bound index symbol (`output_idx` entry or `ranges` key) is `template_import_rename_invalid`. Targets MUST be fresh — colliding with a remaining free name, a bound index symbol, a template param, or another rename/rebind target would silently merge or capture and is `template_import_rename_collision`. Rebinds and renames apply as ONE simultaneous substitution (swaps are well-defined; chains do not cascade).

**Two instances, dedup, and diamonds.** Because renaming precedes the merge, §9.7.4/§9.7.5 need no new machinery: different renames of the same file yield differently-named, independently-registered definitions; identical edges (same `ref`, instantiation, renames, rebinds) yield deep-equal definitions that dedupe at first occurrence. There is deliberately no dedup *across* renames.

**Match-rule instances.** An imported `match` rule registers once per (renamed) import, each instance at its edge's §9.7.4 position, with its authored `priority`. Renaming distinguishes instances only through the renamed names the pattern mentions: an axis-carrying pattern (`wrt`/`dim` naming a library index set) becomes instance-specific under rename, while a pattern of bare op + wildcards (e.g. `{op: "div", args: ["F"]}`) is identical across instances — both register, both match the same nodes, and the earlier edge wins every exact tie. Library authors who intend per-grid instantiation of auto-applied rules SHOULD carry the grid's identity in the pattern via a scalar field naming a library index set.

**Version gate.** The three fields ride on `expression_template_imports` and are gated with it: a pre-0.8.0 file carrying them is rejected as `template_import_version_too_old` (§9.6.5).

#### 9.7.8 Worked example

The conformance fixture `tests/conformance/expression_templates/import_smoke/` is the normative four-file layering — `grid_latlon.esm` (metaparameters NLON/NLAT, index sets, a zero-parameter `dlon_deg` template), `central_D_lon_interior.esm` (interior stencil importing the grid), `central_D_lon_zero_grad_bc.esm` (the complete `match` rule on `D(f, wrt: lon)`: a `makearray` whose interior region invokes the imported stencil and whose two face regions encode the zero-gradient condition), and a consuming model binding `{"NLON": 288, "NLAT": 181}` at its import edge. The full listing appears in `docs/content/rfcs/template-library-imports.md` §6. The same four files serve a convergence sweep by re-binding at the edge — no generated fixtures. For §9.7.7, `tests/conformance/expression_templates/import_rename_two_instances/` is the normative two-instance example — one grid-family library imported under `prefix: "fine"` (N = 16) and `prefix: "coarse"` (N = 8) into one model — with the full listing in `docs/content/rfcs/template-import-renaming.md` §5; `import_rebind_keyed_factors/` is the keyed-factor rebinding example.

#### 9.7.9 Diagnostics

The §9.7 diagnostic codes are listed in the §9.6.6 table (`template_import_*` — including the §9.7.7 `template_import_rename_*` / `template_import_rebind_*` codes — `template_body_expansion_too_deep`, `metaparameter_*`, `subsystem_ref_is_template_library`).

#### 9.7.10 Scope-directed template injection

§9.6.3 constraint 4 makes rewrite rules **component-local**: a rule declared in — or imported into (§9.7.2) — one `model` / `reaction_system` is visible only within *that* component's expression positions. A discretization is a `match` rule (§9.6.8), so this welds a reusable PDE leaf to whatever discretization its own file imports. To keep a leaf discretization-agnostic while still lowering its `grad`/`div`/spatial-`D`, the **consuming surface** — a composing document, or an inline test — MAY register an `expression_template_imports` list into a *target component's* scope, at three attachment points:

- **§4.7 subsystem-ref edge** — `SubsystemRef.expression_template_imports`, an ordered `TemplateImport[]`; target **implicit** (the one component the edge mounts).
- **§10 coupling entry** — `CouplingEntry.expression_template_imports`, a **map** `{ <target-system>: TemplateImport[] }`; target **explicit** (an entry references two-plus systems).
- **§6.6 / §6.7 inline test / example** — `Test.expression_template_imports` / `Example.expression_template_imports`, an ordered `TemplateImport[]`; target **implicit** (the enclosing component).

Each entry uses the §9.7.2 `TemplateImport` shape verbatim (`ref`, `only?`, `bindings?`, `prefix?`, `rename?`, `rebind?`); the injected `ref` MUST resolve to a template-library file (§9.7.1) — `template_import_not_library` otherwise, exactly as an ordinary import.

**The shared operation.** All three forms compile to the same load operation: **extend a target component's effective template scope (§9.7.4) with an appended `TemplateImport[]`**, as if the target had added those entries to the *end* of its own `expression_template_imports`. Component-local scope is **preserved, not escaped**: the injected rules become part of the target's own scope and do not leak to its parent or siblings; the only new capability is *who may write into that scope* — now also the consuming surface. A rule injected into a component still fires only on that component's expression positions, and a parent still cannot discretize a grandchild it does not directly mount (deeper nested targeting is deferred). Determinism (§9.6.3) is untouched: injection only widens the rule set handed to the already-deterministic engine.

**Merge order.** When one target receives imports from more than one source, they concatenate into its §9.7.4 effective declaration order in this fixed, structure-determined order: (1) the target's own `expression_template_imports`; (2) its subsystem-ref edge's injection, if mounted by ref; (3) coupling-entry injections in `coupling`-array order; (4) for a test/example run, that test's injection. The concatenation then feeds §9.7.4 unchanged — depth-first post-order, deep-equal diamond dedup at first occurrence, non-deep-equal same-name collision `template_import_name_conflict`. Forms (2)/(3) and form (4) never mix in one build: (2)/(3) build the assembled document, (4) builds an ephemeral per-test instance of a leaf.

**Timing — two regimes.** *Composition forms (subsystem-ref, coupling-entry) resolve at load and are consumed by the fixpoint.* §4.7 resolution mounts the target "before validation or any other processing"; injection rides that step — the resolver extends the mounted/target component's scope with its edge injection (merge steps 2–3) **before** the §9.6.3 fixpoint (within-load order §9.7.6: resolve imports → merge index sets → close metaparameters → body composition → fixpoint). Coupling-entry injections are collected after all `coupling`-named systems resolve, so an entry may target an inline-declared system as well as a referenced one. The fixpoint then lowers the target's rewrite-targets; the `unlowered_operator` gate (§9.6.3 constraint 6) never trips on it. A composition that mounts a PDE component **without** injecting (and where the component imports nothing itself) still fails cleanly at evaluation with `unlowered_operator` naming the surviving op — the same failure as today, now with an obvious fix. *The test/example form resolves at execution time, in an ephemeral build.* A test's injection MUST NOT run at component load — doing so would lower the enclosing component's `grad` in the canonical document and prevent a sibling test from choosing a different scheme. Instead the inline runner (§6.6) constructs, per test, an ephemeral instance of the enclosing component with that test's imports appended to its scope (merge steps 1 + 4), runs the §9.6.3 fixpoint on *that* instance, and evaluates. The persisted component is never mutated. This is what makes **one suite, many schemes** sound: a single component's tests may exercise it under central vs. upwind, or across a convergence sweep, by varying the injected `ref`/`bindings` per test.

**Round-trip.** Injection fields share the round-trip fate of their timing regime. *Composition forms do not survive `parse → emit`.* Like a component's own `expression_template_imports` (§9.7.6), they are load-time constructs consumed by the fixpoint; the canonical emitted form is the assembled document with the mounted/target component's operators already lowered (Option A always-expanded, §9.6.4), the injection field subsumed into that component's now-lowered scope and gone. *The test/example form survives `parse → emit` verbatim.* A `Test`/`Example` injection is authored per-run configuration, a peer of `parameter_overrides`, `initial_conditions`, and `tolerance`. The enclosing component round-trips with its rewrite-targets **intact** (§9.6.3 constraint 6), and the test's `expression_template_imports` is preserved so the runner can rebuild the ephemeral instance on the next run. Source files remain the source of truth in both regimes.

**Index sets and metaparameters.** In every form the injected library's `index_sets` merge into the **document's** registry as a §9.7.5 import would (deep-equal idempotent; non-equal collision `template_import_index_set_conflict`), so the stencil's axes and the target component's variable shapes resolve against one registry; the library's metaparameters close via `expression_template_imports[k].bindings` at the injection edge (left-open names re-export per §9.7.6 site 2). One rule file therefore serves every resolution — the assembler (or the test) binds the grid size at the edge, and re-binding serves a convergence sweep. An injected grid size inconsistent with the index-set sizes the target's variables are shaped over surfaces at the (ephemeral, for a test) build as the ordinary `template_import_index_set_conflict` / shape error.

---

## 10. Coupling

The coupling section defines how models, reaction systems, and data loaders connect to form a `CoupledSystem`. Each entry maps to an EarthSciML composition mechanism.

```json
{
  "coupling": [
    {
      "type": "operator_compose",
      "systems": ["SuperFastReactions", "Advection"],
      "description": "Add advection terms to all state variables in chemistry system"
    },

    {
      "type": "couple",
      "systems": ["SuperFastReactions", "DryDeposition"],
      "connector": {
        "equations": [
          {
            "from": "DryDeposition.v_dep_O3",
            "to": "SuperFastReactions.O3",
            "transform": "additive",
            "expression": {
              "op": "*",
              "args": [
                { "op": "-", "args": ["DryDeposition.v_dep_O3"] },
                "SuperFastReactions.O3"
              ]
            }
          }
        ]
      },
      "description": "Bi-directional: deposition velocities computed from chemistry state"
    },

    {
      "type": "variable_map",
      "from": "GEOSFP.T",
      "to": "SuperFastReactions.T",
      "transform": "param_to_var",
      "description": "Replace constant temperature with GEOS-FP field"
    },

    {
      "type": "variable_map",
      "from": "GEOSFP.u",
      "to": "Advection.u_wind",
      "transform": "param_to_var"
    },

    {
      "type": "variable_map",
      "from": "GEOSFP.v",
      "to": "Advection.v_wind",
      "transform": "param_to_var"
    },

    {
      "type": "variable_map",
      "from": "NEI_Emissions.emission_rate_NO",
      "to": "SuperFastReactions.emission_rate_NO",
      "transform": "param_to_var"
    }
  ]
}
```

Grid-level loss processes (dry deposition, below-cloud scavenging) that earlier drafts expressed as `operator_apply` coupling entries are now expressed via `grad`/`div`/`laplacian` PDE operators in the model equations, lowered by discretization rewrite rules (§9.6.8).

### 10.1 Coupling Types

| Type | EarthSciML Mechanism | Description |
|---|---|---|
| `operator_compose` | `operator_compose(a, b)` | Match LHS time derivatives and add RHS terms together |
| `couple` | `couple(a, b, connector)` | Bi-directional coupling via explicit `ConnectorSystem` equations. The `connector` field specifies the equations that link the two systems. |
| `variable_map` | `param_to_var` + connection | Replace a parameter in one system with a variable from another, or with an expression computed from it (§10.4) |
| `callback` | `init_callback` | Register a callback for simulation events |
| `event` | Cross-system event | Continuous or discrete event involving multiple coupled systems (see Section 5.6) |
| `coupling_import` | Reuse a coupling library | Import a coupling-library file (§10.9) and bind its declared roles to local components; expands at flatten into concrete `variable_map` / `couple` / `operator_compose` / `event` edges (§10.10). |

### 10.2 The `translate` Field

For `operator_compose`, `translate` specifies variable mappings when LHS variables don't have matching names. Keys and values use scoped references (`"System.var"`). Note that the `_var` placeholder (Section 6.4) is automatically expanded to all state variables in the target system, so `translate` is only needed when two non-placeholder systems have differently-named variables representing the same quantity:

```json
"translate": {
  "ChemModel.ozone": "PhotolysisModel.O3"
}
```

Optionally with a conversion factor:

```json
"translate": {
  "ChemModel.ozone": { "var": "PhotolysisModel.O3", "factor": 1e-9 }
}
```

### 10.3 The `connector` Field

For `couple`, `connector` defines the `ConnectorSystem` — the set of equations that link two systems. Each equation is explicitly provided by the user and specifies which variable is affected and how:

| Transform | Description |
|---|---|
| `additive` | Add expression as source/sink term |
| `multiplicative` | Multiply existing tendency by expression |
| `replacement` | Replace the variable value entirely |

### 10.4 The `variable_map` Transforms

For `variable_map` coupling entries, `transform` specifies how the source variable maps to the target. It is **either** one of the named transform strings below **or** an Expression AST (§4) evaluated on the source value(s):

| Transform | Description |
|---|---|
| `param_to_var` | Replace a constant parameter with a time-varying variable from another system. Takes no `factor`. |
| `identity` | Direct assignment without type change. Takes no `factor`. |
| `additive` | Scaled replacement: `target := factor · source`. (To *add* a source/sink term to an existing tendency, use a `couple` `additive` equation — §10.3.) |
| `multiplicative` | Scaled replacement: `target := factor · source`. (To *scale* an existing tendency by a source, use a `couple` `multiplicative` equation — §10.3.) |
| `conversion_factor` | Scaled replacement applying a unit conversion: `target := factor · source`. |
| *Expression* (object) | Computed replacement: `target := transform-expression`, an ordinary Expression AST evaluated in the flattened coupled system's scope. This is the regridding form of §8.6/§10.5, and the general spelling any of the string transforms desugar to. Takes no `factor` — fold scaling into the expression. |

Every `variable_map` transform performs a **replacement**: the target is bound to the source, optionally scaled by `factor`. `factor` is a scaling coefficient valid only on the scaling transforms (`additive`, `multiplicative`, `conversion_factor`); a `factor` on `param_to_var` or `identity` — which have nothing to scale — or alongside an Expression transform — which spells its own arithmetic — is rejected at load. The three scaling transforms are equivalent in effect for a `variable_map` and differ only in documented intent. Genuine additive/multiplicative **term composition** (adding a source/sink term, or multiplying a tendency in place) is a `couple`/ConnectorSystem concern (§10.3), not a `variable_map`.

**Expression-transform evaluation contract.** When `transform` is an Expression — always an **operator node** (the degenerate bare-reference and literal Expression spellings are not admissible in this slot: bare replacement is what the named transforms already provide, and the string space is reserved for their names) — the entry binds the target to a **derived value**: flattening (§10.7) removes the `to` parameter and introduces in its place a derived (observed) variable — same name, units, and shape — whose defining expression is the transform, so every reference to the target evaluates the expression's value exactly as an authored observed would. The expression's free variables follow the connector-equation convention (§10.3, §4.6): every variable reference MUST be a fully-scoped reference (`System.var`) resolvable in the flattened coupled system. The expression MUST reference the entry's `from` variable — it is the data-flow edge the entry declares — and MAY reference any other variable, parameter, or observed in scope of the flattened system (this is what the §8.6 regridding form relies on: the receiving component's build-once overlap weights, normalization row-sums, and sliver tolerance appear alongside the source field). The expression's value must be shaped like the target (its units are the target's declared units; validators MAY check consistency as for `identity`). Template invocations (`apply_expression_template`) are legal anywhere in the transform: they expand at load (§9.6.4), before validation and flattening, against the template registry of the component that owns the `to` target — the receiving component — which is where a regridding library import (§9.7) naturally lives. As with all of §9.6.4, round-trip emits the expanded form. **One carve-out for coupling-library edges (§10.9).** When a `variable_map` edge arrives via a `coupling_import` expansion (§10.10) rather than being authored inline, its `to` owner is a role and is not known until binding, so its transform templates cannot expand at load. For such an edge, transform-template expansion is deferred to the flatten-time expansion step (§10.10, `esm-libraries-spec.md` §4.7.5): the invocations expand against the *bound* `to` owner's registry immediately after role substitution. Because this is *after* the §9.6.3 fixpoint, a library edge's transform MUST expand to an already-lowered form (a regridding `aggregate`/`index` carries no rewrite-target operator); a transform template that would introduce `grad` / `div` / spatial `D` is rejected with `coupling_library_illegal_payload`.

### 10.5 Coupling across grids and dimensionality

Coupled components may live on different index sets (resolutions), or differ in dimensionality (a 0-D box model feeding a spatial PDE), or read from a data loader whose native grid differs from the model's. The coupling entry handles the mismatch in one of two ways: a **regridding expression** (different grids/resolutions) or **lifting** (0-D ↔ spatial).

#### Regridding

When a variable is mapped between two components on different index sets — or from a data loader's native grid onto a model's grid — the coupling entry's `transform` is a **regridding expression**: an ordinary `aggregate` (FAQ) that maps the source field onto the target grid (overlap-area weighting, interpolation, or slicing a higher-dimensional field at a fixed level are all just `aggregate` index expressions; §8.6, RFC semiring-faq-unified-ir §A.8). There is no separate geometric-relationship declaration. This is the Expression form of `transform` (§10.4): the target parameter becomes a derived variable defined by the expression, whose scoped references reach the source field and the receiving component's build-once weight arrays. The expression is authored inline, or — the usual factoring — invokes overlap-weight templates imported from a regridding library (§9.7), expanded at load per §9.6.4:

```json
{
  "type": "variable_map",
  "from": "GEOSFP.u",
  "to": "Advection.u_wind",
  "transform": {
    "op": "apply_expression_template",
    "name": "conservative_overlap_apply",
    "args": [],
    "bindings": { "A_ij": "Advection.A_ij", "A_j": "Advection.A_j", "F_src": "GEOSFP.u", "atol": "Advection.atol" }
  },
  "description": "Eastward wind conservatively regridded onto the model grid via the imported overlap-weight templates"
}
```

#### The `lifting` Field

For coupling between a 0-D (scalar-shaped) system and a spatially-resolved system, the `lifting` field specifies how the 0-D system's inputs and outputs map to the spatial grid.

```json
{
  "type": "variable_map",
  "from": "FireSpreadCalculator.spread_rate",
  "to": "WildfirePropagation.spread_rate",
  "transform": "param_to_var",
  "lifting": "pointwise",
  "description": "Wind-computed spread rate feeds the wildfire PDE at each grid point"
}
```

| Lifting | Description |
|---|---|
| `pointwise` | **(Default.)** The 0-D system is evaluated independently at each grid point. This is how column physics parameterizations work in climate models. |
| `broadcast` | A single scalar output from the 0-D system is applied uniformly to all grid points. |
| `mean` | Inputs to the 0-D system are the spatial mean of the source fields; output is scalar. |
| `integral` | Inputs to the 0-D system are the spatial integral of the source fields; output is scalar. |

When `lifting` is omitted and one side has scalar-shaped (0-D) variables, pointwise lifting is assumed.

#### Combining regridding and lifting

A coupling chain may need both a regridding expression and lifting; express each as a separate coupling entry — e.g. loaded winds regridded onto the model grid, then a 0-D fire-spread calculator lifted pointwise into a spatial wildfire model.

### 10.6 Coupling Rules

1. **Same-grid coupling** needs neither a regridding transform nor `lifting` (§10.1–10.4).
2. **Different grids / resolutions** → a regridding `transform` expression (an `aggregate`).
3. **0-D ↔ spatial coupling** → a `lifting` strategy (default `pointwise`).
4. **0-D ↔ 0-D coupling** → standard scalar coupling.
5. **0-D intermediary between two spatial components** → separate entries (regrid in, lift out).
6. **`operator_compose` across grids** → evaluated on the target grid; the regridding transform maps the source fields onto it first.

### 10.7 Coupled System Flattening

The coupling section defines relationships between component systems, but simulation and analysis require a single unified equation system. **Flattening** is the process of resolving all coupling rules and producing a single flat system with dot-namespaced variables.

**Dot-namespaced variables:** In the flattened system, every variable, parameter, and species is prefixed with its owning system's name using dot notation. For nested subsystems, each level is included:

```
SimpleOzone.O3            # species O3 from the SimpleOzone reaction system
Advection.u_wind          # parameter u_wind from the Advection model
Atmosphere.Chemistry.NO2  # species NO2 from a nested subsystem
```

The last dot-separated segment is always the variable name; all preceding segments form the system path. This convention is consistent with the scoped reference notation used in coupling entries (Section 4.6) — the difference is that in the flattened system, **all** variable references are fully qualified, not just cross-system references.

**Flattening is a core operation.** All libraries (not just simulation-tier) must be able to flatten a coupled system. The flattened representation is the input to:

- **Graph construction** — the expression graph (Section 4.8.2 of the library spec) operates on the flattened system to produce cross-system dependency edges.
- **Coupled system validation** — checking that all coupling references resolve, no variables are orphaned, and equation–unknown balance holds across the full system.
- **Simulation** — Julia libraries might convert the flattened system to a single MTK `ODESystem` (for 0D/ODE-only systems) or `PDESystem` (for systems with spatial derivatives), using MTK's native namespace separator (`₊`) in place of dots.
- **Export and display** — pretty-printing the full coupled system as a single set of equations.

The flattening algorithm is specified in detail in the ESM Library Specification (Section 4.7.5).

### 10.8 Choosing a discretization while wiring (coupling-entry injection)

A coupling entry mounts PDE components into an assembly, and — like a §4.7 subsystem-ref edge (§9.7.10) — it MAY choose the discretization for a mounted, discretization-agnostic component without editing that component's file. Every coupling entry (`operator_compose`, `couple`, `variable_map`, `callback`, `event`) MAY carry an `expression_template_imports` field: a **map** from a target system name to an ordered `TemplateImport[]` (§9.7.2 shape) registered into that system's own template scope (§9.7.10).

```json
{
  "type": "operator_compose",
  "systems": ["SimpleOzone", "Advection"],
  "expression_template_imports": {
    "Advection": [
      { "ref": "esd://latlon/central_grad_zero_grad_bc.esm",
        "bindings": { "NLON": 144, "NLAT": 91 } }
    ]
  },
  "description": "Compose chemistry onto advection; lower Advection's grad with central differences."
}
```

Reads as: *compose these two, and discretize `Advection` with central differences.* The 0-D chemistry system `SimpleOzone` names no key and receives nothing. Unlike the subsystem-ref form the target is **explicit**, because a coupling entry references two or more systems and some (a data loader in a `variable_map`) cannot host rules.

**Target resolution.** Each map key MUST name a system **referenced by that entry**: `operator_compose`/`couple` → a member of `systems`; `variable_map`/`callback`/`event` → a system named by that entry's reference fields (`variable_map` `from`/`to`; an `event`'s `conditions`/`affects` variable scopes). A key naming no such system is `template_inject_target_unknown` (§9.6.6). A key resolving to a data loader — pure I/O with no expression positions (§14) — is `template_inject_target_is_loader`; a key resolving to neither model, reaction system, nor loader is `template_inject_target_not_component`. Resolution follows §4.6 scoped-reference rules, so a subsystem path (`"Parent.RefSubsystem"`) is a valid key when the entry references a nested system.

**Timing and round-trip** are the load-time-composition regime of §9.7.10: coupling-entry injections are collected after all `coupling`-named systems resolve (so an entry may target an inline-declared system as well as a referenced one), appended to the target's scope in the §9.7.10 merge order, and consumed by the §9.6.3 fixpoint before flattening; they do **not** survive `parse → emit`. Hanging the discretization on the entry that mounts a PDE component keeps the choice next to the wiring that makes it necessary and needs no new top-level section.

### 10.9 Coupling-library files

Coupling is the one part of an assembly that could not, until now, be factored and reused: the
`coupling` array of `variable_map` / `couple` edges could only be authored inline in the assembling
document. A **coupling-library file** lifts a *recurring* wiring pattern into a referenceable,
role-parameterized document, exactly as a template-library file (§9.7.1) does for rewrite rules.

A coupling-library file is a valid ESM document (`esm`, `metadata`) whose payload is:

- **`coupling_roles`** (required, non-empty) — a map from role name to a role descriptor. A role is
  the library's *formal component parameter*: a name, not a type or shape. A descriptor carries a
  single optional `description` (documentation only; it never affects binding or expansion and
  round-trips verbatim). There is deliberately **no** structural contract — no interface, no
  variable-name list — because the library's edges already spell which variables each role must
  expose, and after binding the ordinary flatten-time scoped-reference resolution
  (`unresolved_scoped_ref`) checks that the bound component exposes them.
- **`coupling`** (required, non-empty) — an array of §10.1 coupling entries whose system-naming
  fields are written against **role names** as their top-level system segment (§10.10.2 enumerates
  every such site).

A coupling-library file **MUST NOT** declare `models`, `reaction_systems`, `data_loaders`,
`domain`, `index_sets`, `metaparameters`, or `expression_templates` (`coupling_library_illegal_payload`).
Purity keeps the three reference mechanisms disjoint: a §4.7 subsystem file is not importable as a
coupling library, a template-library file is not importable as a coupling library, and a
coupling-library file is includable **only** through `coupling_import` — never as a subsystem
(`subsystem_ref_is_coupling_library`) or a template import (`template_import_is_coupling_library`).
**Presence of top-level `coupling_roles` is the sole positive identifier of the file kind:** a
document carrying both `coupling_roles` and a forbidden payload is classified as a *malformed
coupling library* (`coupling_library_illegal_payload`), never as an assembly with a stray
`coupling_roles`.

**Permitted edge types.** The role-bearing entry types a library MAY contain are exactly
`variable_map`, `couple`, `operator_compose`, and `event`. It MUST NOT contain a `callback` entry,
and no library edge may carry an `expression_template_imports` map (both
`coupling_library_illegal_payload`). A `callback` exposes only a registered id and an opaque
`config` bag with no structured system-reference field, so a role reference inside it could be
neither located nor rewritten; and an `expression_template_imports` map is a §9.7.10/§10.8
*pre-fixpoint* injection, consumed by the §9.6.3 fixpoint **before** flattening, whereas a
`coupling_import` expands **at** flatten — strictly after the fixpoint — so such a map on a library
edge could never reach the engine that consumes it. Both are therefore forbidden rather than
silently dropped. An implementation MAY further restrict the permitted set (e.g. `variable_map` +
`couple` only), enforcing the narrowing with `coupling_library_illegal_payload`.

A coupling-library file **MUST NOT** itself contain a `coupling_import` entry
(`coupling_library_nested_import`); layering coupling libraries on coupling libraries is deferred.

**No discretization inside a library edge, and no rewrite-target transform templates.** A regridding
`transform` (§10.4) references the *receiving* component's build-once weight arrays and index sets;
after binding, the `to` target is a real component whose registry is in scope, so the library needs
no `index_sets` or templates of its own. Because a library edge's transform templates expand at
flatten (§10.4 carve-out, §10.10.3) — after the §9.6.3 fixpoint — a library transform MUST expand
to an already-lowered form; a transform template that would introduce a rewrite-target operator
(`grad` / `div` / spatial `D`) is rejected with `coupling_library_illegal_payload`.

**Role-scoped reference resolution.** In an ordinary document a coupling edge's top-level segment
must resolve to a top-level `models` / `reaction_systems` / `data_loaders` key (§4.6). A library
file has no such systems, so that resolution is **suspended** when a coupling-library file is
validated on its own: at every role-occurrence site (§10.10.2) the top-level segment must instead
name a declared role (`coupling_edge_unknown_role` otherwise), and a role that appears in
`coupling_roles` but at no occurrence site is `coupling_role_unused`. Ordinary §4.6 resolution
applies only *after* binding, when each role segment has been rewritten to a real component.

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "RothermelFuelCoupling",
    "description": "Anderson-13 fuel properties → Rothermel (1972) spread inputs." },
  "coupling_roles": {
    "Fuel":   { "description": "fuel-property source" },
    "Spread": { "description": "Rothermel spread model" }
  },
  "coupling": [
    { "type": "variable_map", "from": "Fuel.sigma", "to": "Spread.sigma", "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.w_0",   "to": "Spread.w0",    "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.delta", "to": "Spread.delta", "transform": "param_to_var" }
  ]
}
```

### 10.10 Coupling imports and role binding

An assembly reuses a coupling library with a `coupling_import` entry in its ordinary `coupling`
array:

```json
{
  "type": "coupling_import",
  "ref":  "../earthscimodels/couplings/rothermel_fuel.esm",
  "bind": { "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" },
  "description": "Optional; documentation only, round-trips verbatim."
}
```

`ref` resolves by the §4.7 reference formats (relative path, absolute path, URL, `${VAR}`), with
the same per-binding capability rules as a template import; a `ref` that fails to load or parse is
`coupling_import_unresolved`, and a `ref` that targets a document without top-level `coupling_roles`
is `coupling_import_not_library`.

#### 10.10.1 Binding — total and checked by name

For a `coupling_import` referencing a library that declares roles `R₁ … Rₙ`, binding is a **total,
explicit map** — there is no search, no inference, no auto-binding:

1. **Every role MUST have a `bind` entry.** A declared role absent from `bind` is
   `coupling_import_role_unbound`.
2. **Every `bind` key MUST name a declared role.** A key that is not one of `R₁ … Rₙ` is
   `coupling_import_unknown_role`.
3. **Every `bind` value MUST resolve to a component.** A value that does not resolve to a top-level
   or nested `models` / `reaction_systems` / `data_loaders` component is
   `coupling_import_bind_not_a_component`.

**Component-reference resolution (distinct from §4.6).** A `bind` value names a *component* all the
way down, not a variable: split the value on `"."` into segments `[s₁, …, sₖ]`; `s₁` MUST name a
top-level `models` / `reaction_systems` / `data_loaders` key, and each subsequent `sᵢ` MUST name a
key in the preceding system's `subsystems` map. The whole path MUST terminate on a system or loader
node — a path that bottoms out at (or passes through) a variable, parameter, or species is
`coupling_import_bind_not_a_component`. Data loaders are bindable (a `Loader` role binds a
`data_loaders` entry), consistent with §10 treating a loader as a coupling endpoint. This is the
§4.6 hierarchy walk stopped one segment short of a variable.

Because binding is total and explicit, it is unambiguous by construction: two components of the same
kind that must couple differently (two fuel sources feeding two spread models) are disambiguated
simply by writing two different `bind` values — the case a type-dispatch mechanism could not
express. A `bind` whose keys are all correct but whose value names a component that does not expose
a variable the library's edges reference is **not** caught here; it surfaces at flatten as
`unresolved_scoped_ref` (§10.10.3), the same diagnostic a hand-authored edge to a nonexistent
variable produces.

#### 10.10.2 Expansion and the role-substitution occurrence surface

Once every role is bound, each edge in the library's `coupling` array is emitted into the assembly's
effective coupling sequence with **every role-named top-level segment rewritten to its bound
actual**, as **one simultaneous substitution** (all roles at once). A role bound to a dotted path
replaces the single role segment with the full path, so `Fuel.w_0` under `bind: { "Fuel":
"Parent.Child" }` becomes `Parent.Child.w_0` (a well-formed §4.6 reference). A role name occurs, and
is rewritten, at exactly these sites of a library edge:

| Entry field | Occurrence of a role name | In |
|---|---|---|
| `from`, `to` | top-level segment of the scoped reference | `variable_map` |
| `systems[]` | each array element (a bare system name) | `couple`, `operator_compose` |
| `connector.equations[].from` / `.to` | top-level segment of the scoped reference | `couple` |
| `connector.equations[].expression` | top-level segment of every scoped reference in the Expression | `couple` |
| `transform` (Expression form) | top-level segment of every scoped reference in the Expression | `variable_map` |
| `apply_expression_template` node `bindings` **values** | top-level segment of each bound scoped reference; occurs inside **any** Expression above — a `transform`, a `connector` expression, or any `event` Expression | `variable_map`, `couple`, `event` |
| `translate` map | each **key** and each **value** | `operator_compose` |
| `conditions[]` | top-level segment of every scoped reference in each condition Expression | `event` |
| `affects[]`, `affect_neg[]` | top-level segment of `.lhs` and of every scoped reference in `.rhs` | `event` |
| `trigger.expression` | top-level segment of every scoped reference in the Expression (`condition` trigger form only) | `event` |
| `functional_affect` | top-level segment of each entry of `read_vars`, `read_params`, `modified_params` | `event` |
| `discrete_parameters[]` | top-level segment of each scoped-parameter reference | `event` |

Non-reference fields (`transform` string values, `factor`, `lifting`, `description`, `event_type`,
`name`, `handler_id`, `root_find`, `reinitialize`, literal Expression operands) copy unchanged. An
opaque `config` bag (a `functional_affect`'s `config`) is copied verbatim and is **not** a
substitution surface — a library MUST NOT hide a component reference there. `callback` entries and
edge-level `expression_template_imports` never appear because §10.9 forbids them.

#### 10.10.3 Timing, ordering, and round-trip

`coupling_import` expands **at flatten time**, as a new sub-step of the §4.7.5 flattening algorithm
inserted after variable-namespacing (§4.7.5 step 2) and before the coupling-rule step (§4.7.5 step
3). Subsystem mounting and template-import resolution happen earlier, at load (§2.1b / §2.1c), so
every `bind` target and every expanded edge resolves against fully-mounted components. Expanded
edges are spliced into the coupling sequence **in the position of the import entry**, preserving
`coupling`-array order; two import entries never interleave. This is expressly **not** the §9.7.10
pre-fixpoint injection regime.

Because expansion is a flatten-time step, the **source document round-trips with the
`coupling_import` entry intact** — `{ type, ref, bind }` survives `parse → emit`, exactly like every
other coupling entry, while the *flattened* system contains the expanded edges. An assembly that
inlines the library's edges by hand and an assembly that imports them flatten to the **same** system
(the same equations *and* the same §4.7.5 "coupling rules applied" metadata, which records the
expanded edges in both builds, never the `coupling_import` indirection), because both resolve at the
same §4.7.5 step.

Two consequences of expanding inside flatten are normative:

- **A mis-bind is caught by validating the expanded edges, exactly as any bad edge is.** The
  structural `unresolved_scoped_ref` check (§ libraries-spec 4.7.5, §3) resolves a coupling edge's
  scoped references against the coupled system. It runs at load on the pre-flatten representation,
  where a `coupling_import` is still `{ type, ref, bind }` and the expanded edges do not yet exist —
  so a bad binding cannot be seen there. A conforming implementation therefore MUST apply the
  coupled-system reference validation to the **expanded** coupling (the edges produced by §10.10.2),
  not the source `coupling` array; a bound component that resolves but lacks a referenced variable
  then fails with `unresolved_scoped_ref` naming the missing `Component.var` — the same diagnostic,
  over the same expanded edge, that a hand-authored edge to a nonexistent variable produces. Whether
  that validation is folded into the flatten pass or run as a separate coupled-system check over the
  flattened form is a binding-implementation choice; the requirement is only that it sees the
  expanded edges.
- **A library-edge transform's templates expand at flatten** against the bound `to` owner's
  registry (§10.4 carve-out), to an already-lowered form.

Two independent import edges referencing the same library with *different* `bind` maps expand to two
independent edge sets. A double-driven `param_to_var` target (two edges, imported or inline, whose
targets collide on one parameter) is neither created nor specially diagnosed by imports: it is
handled exactly as two inline edges doing the same, and the flattening algorithm is commutative
(libraries-spec §4.7), so no order-dependent outcome is asserted. Authors should route each role to
its own target rather than share one.

### 10.11 Coupling-import diagnostics

| Code | Raised when |
|---|---|
| `coupling_import_unresolved` | A `coupling_import` `ref` failed to load or parse. |
| `coupling_import_not_library` | A `coupling_import` `ref` targets a document that is not a coupling-library file (no top-level `coupling_roles`). |
| `subsystem_ref_is_coupling_library` | A §4.7 subsystem `ref` targets a coupling-library file. |
| `template_import_is_coupling_library` | A §9.7.2 template import targets a coupling-library file. |
| `coupling_library_illegal_payload` | A coupling-library file declares `models` / `reaction_systems` / `data_loaders` / `domain` / `index_sets` / `metaparameters` / `expression_templates`; **or** contains a `callback` entry or a library edge carrying `expression_template_imports`; **or** carries a library edge whose transform template would expand to a rewrite-target operator; **or** (if the binding narrows the entry set) an entry type it does not permit. |
| `coupling_library_nested_import` | A coupling-library file contains a `coupling_import` entry. |
| `coupling_edge_unknown_role` | A library edge's top-level system segment, at any occurrence site, is not a declared role. |
| `coupling_role_unused` | A declared role appears at no occurrence site in any library edge. |
| `coupling_import_unknown_role` | A `bind` key names a role the referenced library does not declare. |
| `coupling_import_role_unbound` | A role the referenced library declares has no `bind` entry. |
| `coupling_import_bind_not_a_component` | A `bind` value does not resolve to a top-level or subsystem component in the assembly. |

A bound component that resolves but lacks a referenced variable is **not** a new code: it surfaces
at flatten as the existing `unresolved_scoped_ref`.

---

## 11. Domain

The `domain` is a **single** object giving the temporal extent and numeric representation shared by every component in the document. A document has at most one domain: all spatial models live on it, and a 0-D model simply has scalar-shaped variables (§11.2). There is no `domains` collection and no per-model domain selector.

A domain does **not** carry spatial-grid geometry. The spatial axes a PDE iterates over are entries in the document-scoped `index_sets` registry (RFC semiring-faq-unified-ir §5.2); their physical coordinates, spacing, and CRS parameters are ordinary data — loaded from a `data_loaders` primitive or declared as variables/parameters. Initial conditions are `ic` equations (§11.4) and boundary conditions are baked into discretization rewrite rules (§9.6.8); neither is a domain field.

### 11.1 Schema

```json
{
  "index_sets": {
    "lon": { "kind": "interval", "size": 50 },
    "lat": { "kind": "interval", "size": 30 },
    "lev": { "kind": "interval", "size": 40 }
  },
  "domain": {
    "independent_variable": "t",
    "temporal": {
      "start": "2024-07-15T00:00:00Z",
      "end": "2024-07-16T00:00:00Z",
      "reference_time": "2024-07-15T00:00:00Z"
    },
    "element_type": "Float64",
    "array_type": "Array"
  }
}
```

The spatial axes a model iterates over (here `lon`, `lat`, `lev`) are `index_sets` entries; each state variable names them in its `shape`. Their coordinate arrays, spacing, and any CRS parameters are bound from a loader field or a coordinate expression — not from the domain.

### 11.2 Model Dimensionality

A model's dimensionality is the number of spatial `index_sets` its state variables are shaped over (via each variable's `shape`) — it is a property of the model, not the domain:

| Dimensionality | Spatial index sets in variable `shape` | Example use cases |
|---|---|---|
| **0D** | none (scalar variables) | Box models, point-source chemistry, algebraic parameterizations |
| **1D** | 1 | Column models, vertical profiles, transect models |
| **2D** | 2 | Surface fire spread, sea-ice extent, land surface models |
| **3D** | 3 | Atmospheric dynamics, ocean circulation, subsurface flow |

Models whose state variables carry no (or empty) `shape` are 0D. A 0D model has no spatial axes; when coupled to a spatial system, the lifting strategy (Section 10.5) determines how it maps onto the spatial index sets.

### 11.3 Domain Fields

The `domain` supports the following fields:

| Field | Required | Description |
|---|---|---|
| `independent_variable` | | Name of the time variable (default: `"t"`). It is **implicitly declared** in every model's expression scope — writing `t` in an equation, an event condition or an affect is never `undefined_variable` (§4.9.1). |
| `temporal` | | Temporal extent: `start`, `end`, `reference_time` (ISO 8601) |
| `element_type` | | Numeric element type (e.g., `"Float32"`, `"Float64"`) |
| `array_type` | | Array implementation type (e.g., `"Array"`) |

### 11.4 Initial conditions (the `ic` op)

An initial condition is an **equation** whose left-hand side is an `ic` op — `{op: "ic", args: [<variable>]}` — and whose right-hand side is the initial field. There is **no** `initial_conditions` field on domains and no initial-condition type: ICs live in a model's `equations` array alongside its dynamics, exactly like `D(u)/dt ~ …`:

```json
{ "lhs": { "op": "ic", "args": ["u"] },
  "rhs": { "op": "sin", "args": [{ "op": "*", "args": [3.141592653589793, "x"] }] } }
```

The RHS is an ordinary Expression:

- **uniform value** → a constant: `ic(u) ~ 0.0`.
- **closed-form field** → a coordinate expression whose free symbols are **spatial coordinate names** (`x`, `y`, `z`, `lon`, `lat`, `lev` — not necessarily the index-set key, which may be a bare index like `i`): `ic(u) ~ 0.2 * x`, evaluated at every grid point. Those symbols are implicitly declared and MUST NOT be reported as `undefined_variable` (§4.9.1).
- **externally-supplied field** → a reference to a loaded variable.

A 0-D component's `ic` RHS is a scalar; a PDE component's may be a coordinate expression. Every state variable SHOULD have exactly one `ic` equation; a missing one defaults to the variable's declared `default`.

**Run-time overrides.** A test or example MAY override the *scalar* initial value of a state variable for one run via `test.initial_conditions` / `example.initial_state` (a `{var: number}` map, §6.6 / §6.7) — this overrides the `ic` equation's value for that run without changing the model.

#### 11.4.1 Scoped-reference ICs (reaction-system species and cross-component ICs)

The `ic` argument MAY be a **scoped reference** (§4.6) to any state variable or species elsewhere in the document — `ic(Chemistry.O3) ~ …` — not only a variable of the enclosing model. The equation still lives in a **model's** `equations` array (ICs are model-hosted): a model whose sole purpose is to declare ICs for other components MAY have an empty `variables` map and carry only `ic` equations (a *dedicated IC model*).

This is how a **reaction system** gets a non-scalar initial condition. A reaction system has no `equations` field, so it cannot host an `ic` equation of its own; a species' initial value is otherwise the scalar `species.default` (§7). When a species needs a coordinate-dependent, loaded-field, or otherwise non-constant IC — most commonly once the reaction system is spatially **lifted** onto a grid through coupling (§10.5) — declare it with a scoped-reference `ic` equation in a model: `ic(Chemistry.O3) ~ InitialFields.O3_field`.

**Resolution timing.** A scoped-reference `ic` equation is resolved on the **flattened** system (§10.7), after the target's owning system is composed and, where the target is spatially lifted, **after the lift** — so the target is the spatially-arrayed variable and the RHS may be a coordinate expression evaluated per grid point, or a reference to a loaded field. Before lifting, a 0-D reaction system's species is scalar and a coordinate-expression IC for it is meaningless.

An `ic` equation MUST NOT be placed inside a reaction system's `constraint_equations` (or anywhere but a model's `equations`); bindings reject it with diagnostic `ic_in_reaction_system`.

### 11.5 Boundary conditions

Boundary conditions are **not** a declarable construct — there is no `boundary_conditions` field and no boundary-condition op. A discretized spatial operator over a finite domain is inseparable from its boundary treatment, so the boundary condition lives **inside the discretization rewrite rule** that lowers `grad`/`div`/`laplacian` to an `aggregate` + `makearray` stencil: the interior region is the stencil, and the boundary-face `makearray` regions encode the BC (Dirichlet → fixed value; Neumann/zero-gradient → one-sided difference; Robin → the solved boundary expression; a seam shared with another variable → an `index` into that variable; periodic → the gather's periodic policy, no override). See §9.6.8. A boundary condition therefore cannot be specified anywhere outside its discretization rule.

**BCs from data.** The boundary-face value may be an `index` into a **loaded variable** (a `data_loaders` field) exactly as it may index any other variable — so a Dirichlet or seam boundary value can be supplied from data (`index(BoundaryData.O3_boundary, …)` in the boundary region). This is the same index-into-another-variable mechanism, with the other variable being a loader field; it needs no special construct.

---

## 12. (Reserved)

The former **Interfaces** section was removed in v0.8.0. Cross-grid coupling between components on different domains is now expressed as ordinary regridding expressions in the coupling relationship between two variables (§8.6, §10.5) — an `aggregate` (FAQ) over index sets, not a separate interface construct. The section number is retained so §13–§15 references stay stable.

---

## 13. Complete Examples

### 13.1 Atmospheric Chemistry with Advection

A minimal but complete `.esm` file representing atmospheric chemistry with advection:

```json
{
  "esm": "0.8.0",
  "metadata": {
    "name": "MinimalChemAdvection",
    "description": "O3-NO-NO2 chemistry with advection over a lon-lat grid and external meteorology",
    "authors": ["Chris Tessum"],
    "created": "2026-06-30T00:00:00Z"
  },

  "index_sets": {
    "lon": { "kind": "interval", "size": 144 },
    "lat": { "kind": "interval", "size": 91 }
  },

  "reaction_systems": {
    "SimpleOzone": {
      "reference": { "notes": "Minimal O3-NOx photochemical cycle" },
      "species": {
        "O3":  { "units": "mol/mol", "default": 40e-9,  "description": "Ozone" },
        "NO":  { "units": "mol/mol", "default": 0.1e-9, "description": "Nitric oxide" },
        "NO2": { "units": "mol/mol", "default": 1.0e-9, "description": "Nitrogen dioxide" }
      },
      "parameters": {
        "T":    { "units": "K", "default": 298.15, "description": "Temperature" },
        "M":    { "units": "molec/cm^3", "default": 2.46e19, "description": "Air number density" },
        "jNO2": { "units": "1/s", "default": 0.005, "description": "NO2 photolysis rate" }
      },
      "reactions": [
        {
          "id": "R1",
          "name": "NO_O3",
          "substrates": [
            { "species": "NO", "stoichiometry": 1 },
            { "species": "O3", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "NO2", "stoichiometry": 1 }
          ],
          "rate": { "op": "*", "args": [1.8e-12, { "op": "exp", "args": [{ "op": "/", "args": [-1370, "T"] }] }, "M"] }
        },
        {
          "id": "R2",
          "name": "NO2_photolysis",
          "substrates": [ { "species": "NO2", "stoichiometry": 1 } ],
          "products": [
            { "species": "NO", "stoichiometry": 1 },
            { "species": "O3", "stoichiometry": 1 }
          ],
          "rate": "jNO2"
        }
      ]
    }
  },

  "models": {
    "Advection": {
      "reference": { "notes": "First-order advection of each transported field over the lon-lat grid" },
      "variables": {
        "u_wind": { "type": "parameter", "units": "m/s", "default": 0.0, "shape": ["lon", "lat"] },
        "v_wind": { "type": "parameter", "units": "m/s", "default": 0.0, "shape": ["lon", "lat"] },
        "dx": { "type": "parameter", "units": "m", "default": 27750.0, "description": "Eastward grid spacing" },
        "dy": { "type": "parameter", "units": "m", "default": 27750.0, "description": "Northward grid spacing" }
      },
      "expression_templates": {
        "central_grad_lon_zero_grad_bc": {
          "params": ["f"],
          "match": { "op": "grad", "args": ["f"], "dim": "lon" },
          "body": {
            "op": "makearray",
            "regions": [ [[2, 143], [1, 91]], [[1, 1], [1, 91]], [[144, 144], [1, 91]] ],
            "values": [
              { "op": "aggregate", "output_idx": ["i", "j"], "args": ["f"],
                "ranges": { "i": [2, 143], "j": { "from": "lat" } },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [
                    { "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }, "j"] },
                    { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }, "j"] } ] },
                  { "op": "*", "args": [2, "dx"] } ] } },
              { "op": "aggregate", "output_idx": ["j"], "args": ["f"], "ranges": { "j": { "from": "lat" } },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [ { "op": "index", "args": ["f", 2, "j"] }, { "op": "index", "args": ["f", 1, "j"] } ] }, "dx" ] } },
              { "op": "aggregate", "output_idx": ["j"], "args": ["f"], "ranges": { "j": { "from": "lat" } },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [ { "op": "index", "args": ["f", 144, "j"] }, { "op": "index", "args": ["f", 143, "j"] } ] }, "dx" ] } }
            ]
          }
        },
        "central_grad_lat_zero_grad_bc": {
          "params": ["f"],
          "match": { "op": "grad", "args": ["f"], "dim": "lat" },
          "body": {
            "op": "makearray",
            "regions": [ [[1, 144], [2, 90]], [[1, 144], [1, 1]], [[1, 144], [91, 91]] ],
            "values": [
              { "op": "aggregate", "output_idx": ["i", "j"], "args": ["f"],
                "ranges": { "i": { "from": "lon" }, "j": [2, 90] },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [
                    { "op": "index", "args": ["f", "i", { "op": "+", "args": ["j", 1] }] },
                    { "op": "index", "args": ["f", "i", { "op": "-", "args": ["j", 1] }] } ] },
                  { "op": "*", "args": [2, "dy"] } ] } },
              { "op": "aggregate", "output_idx": ["i"], "args": ["f"], "ranges": { "i": { "from": "lon" } },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [ { "op": "index", "args": ["f", "i", 2] }, { "op": "index", "args": ["f", "i", 1] } ] }, "dy" ] } },
              { "op": "aggregate", "output_idx": ["i"], "args": ["f"], "ranges": { "i": { "from": "lon" } },
                "expr": { "op": "/", "args": [
                  { "op": "-", "args": [ { "op": "index", "args": ["f", "i", 91] }, { "op": "index", "args": ["f", "i", 90] } ] }, "dy" ] } }
            ]
          }
        }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["_var"], "wrt": "t" },
          "rhs": {
            "op": "+", "args": [
              { "op": "*", "args": [{ "op": "-", "args": ["u_wind"] }, { "op": "grad", "args": ["_var"], "dim": "lon" }] },
              { "op": "*", "args": [{ "op": "-", "args": ["v_wind"] }, { "op": "grad", "args": ["_var"], "dim": "lat" }] }
            ]
          }
        },
        {
          "lhs": { "op": "ic", "args": ["_var"] },
          "rhs": 1.0e-9
        }
      ]
    }
  },

  "data_loaders": {
    "GEOSFP": {
      "kind": "grid",
      "source": {
        "url_template": "https://portal.nccs.nasa.gov/datashare/gmao/geos-fp/das/Y{date:%Y}/M{date:%m}/D{date:%d}/GEOS.fp.asm.tavg1_2d_slv_Nx.{date:%Y%m%d_%H%M}.V01.nc4"
      },
      "temporal": {
        "start": "2014-01-01T00:00:00Z",
        "end":   "2099-12-31T23:59:59Z",
        "file_period": "PT1H",
        "frequency":   "PT1H",
        "records_per_file": 1
      },
      "variables": {
        "u": { "file_variable": "U10M", "units": "m/s", "description": "Eastward wind" },
        "v": { "file_variable": "V10M", "units": "m/s", "description": "Northward wind" },
        "T": { "file_variable": "T2M",  "units": "K",   "description": "Temperature" }
      },
      "metadata": { "tags": ["meteorology", "reanalysis"] }
    }
  },

  "coupling": [
    { "type": "operator_compose", "systems": ["SimpleOzone", "Advection"] },
    { "type": "variable_map", "from": "GEOSFP.T", "to": "SimpleOzone.T", "transform": "param_to_var" },
    { "type": "variable_map", "from": "GEOSFP.u", "to": "Advection.u_wind", "transform": "param_to_var" },
    { "type": "variable_map", "from": "GEOSFP.v", "to": "Advection.v_wind", "transform": "param_to_var" }
  ],

  "domain": {
    "temporal": { "start": "2024-05-01T00:00:00Z", "end": "2024-05-03T00:00:00Z" },
    "element_type": "Float32"
  }
}
```

The spatial axes (`lon`, `lat`) are `index_sets`; the `Advection` model's variables are shaped over them, and `grad` is lowered by the in-file `central_grad_*_zero_grad_bc` rewrite rules (§9.6.8) — each a `makearray` that combines the interior central-difference `aggregate` with the two boundary-face regions encoding the zero-gradient condition. The boundary conditions live **inside** the discretization rule; there is no separate boundary-condition declaration. Wind and temperature come from the `GEOSFP` loader as ordinary variables.

**Note:** Every component shares the single `domain`; there is no per-model domain field. A model is spatial if its variables are shaped over index sets, 0-D otherwise.

## 14. Design Principles

### Full specification is mandatory for models and reactions

Every equation, species, reaction, parameter, and variable must be present in the `.esm` file. This guarantees:

- A parser in **any language** can reconstruct the mathematical system
- Models are **reproducible** without access to specific software versions
- The format is **archival** — it remains meaningful years later even if packages change
- **Diffs are meaningful** — every change to the science is visible in version control

### Data loaders are the only externally-registered mechanism

Data loaders are runtime-specific: they involve I/O, format adapters, and large external grids that cannot be meaningfully serialized as math. (A loader is pure I/O — it does not regrid; transferring its fields onto a model's target grid is a model concern, §8.) The `.esm` file declares *what* they provide and *what* they need, but delegates *how* to the runtime. State-mutating numerical schemes (advection, diffusion stencils, deposition algorithms) are **not** an externally-registered mechanism: they are expressed via `grad`/`div`/`laplacian` PDE operators in model equations, lowered by discretization rewrite rules (§9.6.8). Pure callables embedded inside expressions are **not** an externally-registered mechanism either: they are drawn from the closed function registry (Section 9), whose entries are spec-pinned with fixed names, signatures, and tolerances.

### Expression AST over string math

String-based math (LaTeX, Mathematica, sympy) requires building a parser for every target language. The JSON AST is immediately parseable everywhere and supports programmatic transformation.

### Reaction systems are distinct from ODE models

Reaction networks are a higher-level, more constrained representation. Keeping them separate from raw ODE models:

- Preserves **chemical meaning** (stoichiometry, mass action semantics)
- Enables **analysis** (conservation laws, stoichiometric matrices, deficiency theory) without equation manipulation
- Maps naturally to **multiple simulation types** (ODE, SDE, jump/Gillespie) from the same declaration
- Avoids the error-prone manual derivation of ODEs from reaction networks

### Coupling is first-class

The composition rules are arguably more important than the individual models, since they capture the scientific decisions about how processes interact. Making coupling explicit and inspectable is essential for understanding and reproducing complex Earth system models.

### Coupling across grids is a regridding expression

Coupling between components on different grids (or from a loader's native grid onto a model's) carries its geometry in the coupling entry's `transform` — an `aggregate` regridding expression that maps the source field onto the target grid (slicing, overlap-area weighting, interpolation). There is no separate interface or geometry-relationship construct; the regridding is an ordinary FAQ over index sets, the same algebra as everything else in the format. This means:

- Grid transfer is expressed with the same `aggregate` machinery as discretization and reductions — one mechanism, not a special geometry layer.
- A reusable regridding rule can be factored as an `expression_templates` rewrite rule and shared across coupling entries.

### 0D systems are first-class coupling intermediaries

Many physical parameterizations are algebraic or ODE systems with no intrinsic spatial dimensions — they compute pointwise relationships (e.g., wind speed → fire spread rate, bulk surface fluxes). Rather than embedding these calculations in the spatial model's equations, they are declared as separate 0D models with explicit coupling. This preserves modularity: the same 0D parameterization can be swapped, tested independently, or coupled to different spatial domains.

### Coupled systems flatten to a single equation system

The composition of multiple models, reaction systems, and data loaders resolves to a **single flat equation system** with dot-namespaced variables (`Atmosphere.Chemistry.O3`). This is not merely a convenience — it is the canonical intermediate representation that all downstream operations (simulation, validation, graph construction) consume. Dot-namespacing preserves provenance (you can always trace a variable back to its originating component) while producing a system that maps directly to a single solver object (MTK `ODESystem` or `PDESystem` in Julia, a single ODE integrator call in Python). The separation between modular component definitions (in the `.esm` file) and the unified flat system (produced by flattening) mirrors the distinction between source code and compiled output: the file is for humans and version control, the flattened system is for machines and solvers.

---

## 15. Future Considerations

- **Formal JSON Schema** — A `.json` schema file for automated validation
- **Binary variant** — MessagePack or CBOR for large mechanisms (hundreds of species/reactions)
- **Semantic diffing** — CLI tools that understand `.esm` structure for meaningful diffs
- **Stoichiometric matrix export** — Direct computation of substrate/product/net stoichiometry matrices from the reaction system section
- **Unit validation** — Tooling for dimensional analysis across coupled systems
- **Provenance hashing** — Content-addressable hashing of model components for reproducibility
- **SBML interop** — Import/export to Systems Biology Markup Language for broader compatibility
- **Web editor** — Visual model composition interface producing `.esm` files
