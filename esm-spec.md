# ESM Format Specification

**EarthSciML Serialization Format — Version 0.5.0**

## 1. Overview

The ESM (`.esm`) format is a JSON-based serialization format for EarthSciML model components, their composition, and runtime configuration. It serves three primary use cases:

1. **Persistence** — Save and load model definitions to/from disk
2. **Interchange** — Transfer models between Julia, TypeScript/web frontends, Rust, Python, and other languages
3. **Version control** — Produce human-readable, diff-friendly model specifications

ESM is **language-agnostic**. Every model must be fully self-describing: all equations, variables, parameters, species, and reactions are specified in the format itself. A conforming parser in any language can reconstruct the complete mathematical system from the `.esm` file alone, without access to any particular software package.

The single exception to full specification is **data loaders**, which are inherently runtime-specific (file I/O, format adapters, regridding, large external grids) and are therefore referenced by type/name rather than fully defined. There is no in-file registry of arbitrary user-defined functions or operators: every callable invoked from an expression is drawn from the **closed function registry** (Section 9), whose entries are spec-defined with fixed names, signatures, and tolerances. See `docs/rfcs/closed-function-registry.md` for the rationale.

### 1.1 Authoring Policy: AST first, registry second, factoring third

Authors and reviewers MUST prefer the built-in expression AST (Section 4) over the closed function registry (Section 9). A `{"op": "fn", ...}` node is justified **only** when the desired primitive cannot be written as a finite closed-form composition of the AST ops in §4.2 — typically because it requires non-AST ingredients (calendar arithmetic, table search). Anything expressible in finite closed form (powers, polynomials, transcendentals, conditionals, piecewise, clip/clamp) belongs in the AST. Reviewers MUST reject `fn` nodes whose body can be written using existing AST ops; `^`, `min`, `max`, `ifelse`, `sign` and the trig / exp / log family already cover ordinary scalar math.

The closed function registry is **closed**: bindings MUST reject any `fn` node whose `name` is not in the spec-defined set for the file's declared `esm` version. There is no per-file declaration of new functions, no `handler_id` lookup, and no out-of-band runtime registry. Adding a primitive requires a spec rev (see `docs/rfcs/closed-function-registry.md` §7).

The full authoring stance, normatively:

> **AST first, registry second, factoring third.**
>
> 1. *AST first.* The closed AST op set in §4 is the primary authoring surface. New mathematics SHOULD be expressible as a finite tree of existing ops.
> 2. *Registry second.* Operations that genuinely cannot be written as AST trees (tabulated lookups, iterative solves, platform adapters) use the closed `fn`-op registry per §9.1; addition is normative spec work, not authoring.
> 3. *Factoring third.* Within a single component, an author MAY name a fixed Expression AST tree as an `expression_templates` entry (§9.6) and reference it elsewhere by name with parameter substitution. Factoring is **not** programming: bodies are fixed AST trees, parameters are pure-syntactic substitution slots, no recursion, no cross-template calls, no metaprogramming.
>
> Mechanisms that require any capability beyond fixed-tree parameter substitution (conditional includes, generated definitions, computed bindings) are out of scope and require a separate RFC that revisits §1.1.

**File extension:** `.esm`  
**MIME type:** `application/vnd.earthsciml+json`  
**Encoding:** UTF-8

---

## 2. Top-Level Structure

```json
{
  "esm": "0.5.0",
  "metadata": { ... },
  "models": { ... },
  "reaction_systems": { ... },
  "data_loaders": { ... },
  "enums": { ... },
  "function_tables": { ... },
  "coupling": [ ... ],
  "domains": { ... },
  "interfaces": { ... },
  "grids": { ... }
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
| `domains` | | Named spatial/temporal domain specifications (see Section 11) |
| `interfaces` | | Geometric connections between domains of different dimensionality (see Section 12) |
| `grids` | | Named discretization grids (cartesian / unstructured / cubed_sphere) — see docs/rfcs/discretization.md §6 |
| `staggering_rules` | | Named staggering conventions that declare where quantities live on a grid (e.g. MPAS unstructured C-grid) — see docs/rfcs/discretization.md §7.4 |
| `discretizations` | | Named discretization schemes mapping PDE operators to stencil templates (§7.1) or cross-metric composites for curvilinear covariant operators (§7.4) — see docs/rfcs/discretization.md §7 |

The `operators` and `registered_functions` blocks present in earlier drafts are **removed** in this revision. State-mutating numerical schemes (advection, gridded diffusion) are now expressed as discretization schemes (`discretizations`) with PDE operators in the model equations; pure functions are drawn from the closed function registry (Section 9) via the `fn` op. See `docs/rfcs/closed-function-registry.md` for the migration plan.

At least one of `models` or `reaction_systems` must be present.

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

### 4.2 Built-in Operators

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
| `D` | `"wrt": "t"` | Time derivative: ∂/∂t |
| `grad` | `"dim": "x"` | Spatial gradient: ∂/∂x |
| `div` | | Divergence: ∇· |
| `laplacian` | | Laplacian: ∇² |

Example: `{"op": "D", "args": ["O3"], "wrt": "t"}` represents ∂O₃/∂t.

#### Elementary Functions

`exp`, `log`, `log10`, `sqrt`, `abs`, `sign`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `min`, `max`, `floor`, `ceil`

All take their standard mathematical arguments in `args`. Most are unary (one
scalar argument) except `atan2` (binary) and `min`/`max`, which are **n-ary
with arity ≥ 2** and return the element-wise extremum across all arguments
(left-fold of the binary operator). Conforming bindings MUST reject `min`/`max`
nodes with fewer than two arguments. `min`/`max` are the canonical, AST-level
encoding of clamp / clip / limiter primitives — `clamp(x, lo, hi)` is
`{"op": "min", "args": [hi, {"op": "max", "args": [lo, "x"]}]}` — and reviewers
MUST reject `fn` nodes that only re-implement these in disguise (see §0).

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
| `arrayop` | `output_idx`, `expr` | Generalized Einstein-notation tensor expression with implicit reductions over non-output indices. See Section 4.3.1. |
| `makearray` | `regions`, `values` | Block assembly of an array from overlapping sub-region assignments. Later regions overwrite earlier ones. See Section 4.3.2. |
| `index` | — | Element or sub-array access. `args[0]` is the array; `args[1..]` are the index expressions. See Section 4.3.3. |
| `broadcast` | `fn` | Element-wise application of scalar operator `fn` to broadcast-compatible operands. See Section 4.3.4. |
| `reshape` | `shape` | Reshape `args[0]` to the given target shape. See Section 4.3.5. |
| `transpose` | — (optional `perm`) | Axis permutation of `args[0]`. See Section 4.3.5. |
| `concat` | `axis` | Concatenate the operand arrays along the given axis. See Section 4.3.5. |

### 4.3 Array / Tensor Semantics

Earth-system models frequently need to serialize operations on arrays and tensors — discretized PDEs, matrix multiplies, stencils, index contractions, block assemblies. The array ops listed in Section 4.2 cover these cases. Their data model mirrors [`SymbolicUtils.jl`](https://github.com/JuliaSymbolics/SymbolicUtils.jl)'s `ArrayOp` and `ArrayMaker` (see `src/types.jl`, `src/arrayop.jl`, `src/arraymaker.jl`).

**Implicit dimensions.** Array ops use an *implicit* dimension model: there is no per-variable `dimensions` field on schema variables. Index symbols are local to the enclosing `arrayop` node, and lengths are resolved at runtime from the `domain` section and the shapes of the operand arrays. A given string can be a variable reference in most contexts but serves as an index symbol inside `arrayop.output_idx`, `arrayop.expr`, and `arrayop.ranges` keys. Callers must not rely on cross-node scoping of index symbols.

#### 4.3.1 `arrayop`

An `arrayop` node represents a generalized Einstein-notation expression.

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
  "op": "arrayop",
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
  "op": "arrayop",
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
  "op": "arrayop",
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
      "op": "arrayop",
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
      "op": "arrayop",
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
- `args[1..]`: one index expression per dimension. Each index is an `Expression`, so it may be an integer literal, a symbolic index variable (as a string, when inside an `arrayop.expr`), or a composite expression (e.g. `{ "op": "+", "args": ["i", 1] }` for an offset stencil point).

Non-affine index expressions are legal; it is the author's responsibility to ensure runtime access is in-bounds (cf. `SymbolicUtils/src/arrayop.jl` § "Axis offsets"). Sparsity and other structured-array optimizations are runtime concerns and are not represented in the schema.

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

The `fn` op invokes a function from the **closed function registry** defined in Section 9. The set of valid `name` values is fixed by the spec version: bindings MUST reject `fn` nodes whose `name` is not in the registry for the file's declared `esm` version. There is no per-file declaration of new functions and no `handler_id` lookup. See `docs/rfcs/closed-function-registry.md` for the rationale and addition process.

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

**Resolution algorithm:** Given a scoped reference string, split on `"."` to produce segments `[s₁, s₂, …, sₙ]`. The final segment `sₙ` is the variable name. The preceding segments `[s₁, …, sₙ₋₁]` form a path: `s₁` must match a key in the top-level `models`, `reaction_systems`, or `data_loaders` section, and each subsequent segment must match a key in the parent system's `subsystems` map.

**Bare references** (no dot) refer to a variable within the current system context. In coupling entries, all references must be fully qualified from the top-level system name.

### 4.7 Subsystem Inclusion by Reference

Subsystems can be defined inline (as described in Sections 6 and 7) or included by reference from an external ESM file. A reference is an object with a single `ref` field containing a local file path or URL:

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

**Reference format:**

| Form | Example | Resolution |
|---|---|---|
| Relative path | `"./atmosphere.esm"` | Resolved relative to the directory of the referencing file |
| Absolute path | `"/models/atmosphere.esm"` | Used as-is |
| HTTP/HTTPS URL | `"https://example.com/models/atmosphere.esm"` | Fetched from the network |

**Referenced file requirements (model/reaction-system subsystems):**

- The referenced file must be a valid ESM file (with `esm` version and `metadata` fields).
- It must contain exactly one top-level model or reaction system and must NOT carry a `"kind"` field (absence of `"kind"` identifies a subsystem file). The single model or reaction system defined in the file is used as the subsystem definition.
- The subsystem key in the parent file determines the subsystem's name, not any name in the referenced file.

**Scoped references** work identically for referenced subsystems as for inline subsystems. After resolution, `"Parent.RefSubsystem.variable"` works the same regardless of whether `RefSubsystem` was defined inline or loaded from a reference.

**Resolution timing:** Libraries must resolve all references at load time, before validation or any other processing. After resolution, the in-memory representation is identical to a file with all subsystems defined inline.

#### 4.7.1 GridDiscretization Descriptors

A **GridDiscretization Descriptor** (GDD) is a second referenceable file type distinct from model/reaction-system subsystems. A GDD carries grid geometry and discretization rules together in a single document, enabling test and example blocks to specify exactly how a PDE component is discretized without embedding that information in the component definition itself.

GDD files are published by the EarthSciDiscretizations (ESD) project at stable URLs. Authors may also supply local paths or any HTTPS URL.

**GDD file format:**

```json
{
  "esm": "0.5.0",
  "kind": "grid_discretization_descriptor",
  "metadata": {
    "title": "Cartesian 1-D N=32 with centered-2nd FD",
    "description": "Uniform 1-D domain [0,1], 32 cells, second-order centered finite differences"
  },
  "grids": {
    "domain": {
      "spatial": {
        "x": { "min": 0.0, "max": 1.0, "units": "m", "cells": 32 }
      }
    }
  },
  "discretizations": {
    "grad": { "ref": "https://esd.earthsciml.org/rules/centered_2nd_uniform.json" }
  }
}
```

A GDD file is identified by `"kind": "grid_discretization_descriptor"`. It MUST NOT be placed in the `subsystems` map — it is not a model or reaction system. GDD files are referenced exclusively from test and example `grid_refs` fields (§6.6.2 and §6.7.2).

**GDD file fields:**

| Field | Required | Description |
|---|---|---|
| `esm` | ✓ | ESM format version string. |
| `kind` | ✓ | Must be `"grid_discretization_descriptor"`. |
| `metadata` | | Optional title and description. |
| `grids` | ✓ | Dictionary mapping domain names to spatial grid specs. Domain names must match the `domain` field of the referencing component. Each entry overrides the component's declared `spatial` block for that domain when the test or example runs; `temporal`, `boundary_conditions`, and other domain fields are inherited from the component unchanged. |
| `discretizations` | | Dictionary mapping operator names (e.g., `"grad"`, `"div"`) to discretization rules. Each value may be an inline rule object or a `{ref: URL-or-path}` pointing to an ESD rule file. Overrides the component's declared discretizations for this run. |

**Dependency note:** For `grid_refs` to work in production, ESD must publish GDD files at stable, resolvable URLs or paths. Authors referencing ESD-published GDDs should pin a versioned URL to guard against upstream changes.

---

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
      "coupletype": "SuperFastCoupler",

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
| `domain` | | Name of a domain from the `domains` section that this model is defined on. Omit or set to `null` for 0D (non-spatial) models — ODE or algebraic systems with no spatial dimensions. |
| `coupletype` | | Coupling type name (maps to EarthSciML `:coupletype` metadata). Informational label identifying this system's role in coupling. |
| `reference` | | Academic citation: `doi`, `citation`, `url`, `notes` |
| `variables` | ✓ | All variables, keyed by name |
| `equations` | ✓ | Array of `{lhs, rhs}` equation objects |
| `discrete_events` | | Discrete events (see Section 5.3) |
| `continuous_events` | | Continuous events (see Section 5.2) |
| `initialization_equations` | | Equations that hold only at t=0, solved before time-stepping begins. Typical uses: aerosol equilibrium / plume-rise style models (`system_kind='nonlinear'`) that need extra constraints for initialization, and ODE models whose initial state is determined by solving an auxiliary system. |
| `guesses` | | Initial-guess seeds for nonlinear solvers during initialization, keyed by variable name. Values are `Expression` graphs (numbers, strings, or nodes). |
| `system_kind` | | Discriminates the MTK system type: `"ode"` (default; time-stepped), `"nonlinear"` (algebraic-only equilibrium — no time derivative), `"sde"` (stochastic — brownian variables present), `"pde"` (spatial domain + differential operators). Each binding's MTK integration uses this to select between `System`, `NonlinearSystem`, `SDESystem`, and `PDESystem` constructors. |
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

Optional arrayed-variable fields (introduced in spec 0.2, discretization RFC §10.2):

| Field | Description |
|---|---|
| `shape` | Ordered list of dimension names drawn from the enclosing model's domain `spatial` map. Omitted or null means the variable is scalar. Used by the discretization pipeline and validated by `index` in discretization RFC §5.1. |
| `location` | Staggered-grid location tag (e.g., `"cell_center"`, `"edge_normal"`, `"x_face"`, `"vertex"`). Omitted means no explicit staggering; spatialization (discretization RFC §11 step 2) defaults this to `"cell_center"` when the variable's model has a grid. |

### 6.4 Advection Model Example

Advection is a model like any other — fully specified:

```json
{
  "Advection": {
    "coupletype": null,
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

### 6.5 Dry Deposition Model Example

A model that computes deposition velocities from surface resistance parameters. This model is coupled to a chemistry system via `couple` to provide deposition loss terms; grid-level application of those losses is expressed via the `discretizations` block (`docs/rfcs/discretization.md` §7), not as an opaque registered operator.

```json
{
  "DryDeposition": {
    "coupletype": "DryDepositionCoupler",
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
      "initial_conditions": {
        "NO": 10.0,
        "NO2": 20.0,
        "O3": 50.0
      },
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
| `assertions` | ✓ | Array of scalar checks; must contain at least one. |
| `grid_refs` | | PDE only. Array of `{"ref": URL-or-path}` objects pointing to GridDiscretization Descriptor files (§4.7.1). Each entry overrides the component's declared spatial grid and discretization for one run. A single-element list runs the test on exactly that grid configuration. A list of two or more entries enables a resolution sweep — the test is executed once per entry and the results are available to `convergence_order` assertions (§6.6.5). Validators MUST reject `convergence_order` assertions in tests with fewer than two `grid_refs` entries. |

#### 6.6.3 Assertion Semantics

Each assertion is a per-(variable, time) check against a scalar expected value:

| Field | Required | Description |
|---|---|---|
| `variable` | ✓ | Variable or species name. Local names (e.g., `"O3"`) or scoped references into subsystems (e.g., `"inner.X"`) are both allowed. |
| `time` | ✓ | Simulation time at which to evaluate the assertion; must lie in `[time_span.start, time_span.end]`. |
| `expected` | ✓ (except `convergence_order`) | Expected scalar value. Not used for `convergence_order` assertions — use `expected_order` instead. |
| `tolerance` | | Per-assertion tolerance override. |
| `coords` | | PDE only: spatial-point sample. Map from domain dimension name to the numeric coordinate at which to evaluate the field. Mutually exclusive with `reduce`. |
| `reduce` | | PDE only: collapse the spatial field to a scalar before comparison. One of `integral`, `mean`, `max`, `min`, `L2_error`, `Linf_error`, `convergence_order`. Mutually exclusive with `coords`. |
| `reference` | error-norms and convergence | Required when `reduce` is `L2_error`, `Linf_error`, or `convergence_order`: an inline `Expression` (evaluated over the component's domain coordinates) or `{type: "from_file", path, format?}`. |
| `expected_order` | `convergence_order` only | Required when `reduce` is `convergence_order`. The expected numerical convergence rate (e.g., `2.0` for second-order methods). |

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

Pointwise scalar assertions (the default — neither `coords` nor `reduce`) only make sense on 0-D components: there is one trajectory per variable, indexed by time alone. On a component with a spatial domain (`component.domain.spatial` non-empty), every assertion MUST select a scalar via either `coords` or `reduce`. Validators MUST reject:

- a 0-D component carrying an assertion with `coords` or `reduce` set; and
- a PDE component carrying a pointwise assertion (no `coords`, no `reduce`).

`coords` keys MUST match dimension names declared in `component.domain.spatial`. The runtime samples the field at the named point (interpolation vs nearest-grid is a runtime concern). `coords` may pin a strict subset of dimensions only when the remaining dimensions resolve to a single sample (e.g., a 1-D component with a single dimension); otherwise the assertion is ill-defined and validators MUST reject.

`reduce` collapses the field over the entire spatial domain at the given `time`. The pure reductions (`integral`, `mean`, `max`, `min`) compare directly against `expected`. The error-norm reductions compare against a `reference` solution:

- `L2_error`: `expected ≈ ||u_actual − u_reference||_2 / ||u_reference||_2` (relative L2), evaluated as a domain integral.
- `Linf_error`: `expected ≈ max_x |u_actual(x) − u_reference(x)|` (uniform norm).

`reference` may be:

- an inline `Expression` whose free variables are the domain dimension names (e.g., `sin(π x)`), evaluated by the runtime over every grid point at the assertion `time`; or
- `{type: "from_file", path, format?}` pointing at a precomputed snapshot in the same shape as the field.

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

#### 6.6.6 Convergence-Order Assertions

The `reduce: "convergence_order"` assertion is the **gold-standard PDE validation** for discretization accuracy. It runs the enclosing test at each resolution listed in `grid_refs` (§6.6.2), computes the relative L2 error against `reference` at each resolution, and asserts that the measured rate matches `expected_order`.

**Mechanics:**

1. The test is executed once per entry in `grid_refs`, substituting the GDD's grid and discretizations into the component's declared domain.
2. At each run, the relative L2 error is computed: `e_k = ||u_k − u_ref||_2 / ||u_ref||_2`.
3. The representative grid spacing `h_k` for each run is taken as the geometric mean of the per-dimension `grid_spacing` values declared in the GDD's `grids` block. For runs with the same topology but different `cells` counts, `h` scales as `1 / cells`.
4. The observed convergence order is estimated by linear regression of `log(e_k)` on `log(h_k)`: `p_obs = Δ log(e) / Δ log(h)`.
5. The assertion passes when `p_obs ≥ expected_order × (1 − rel)` where `rel` is resolved from the assertion's `tolerance.rel` (default: `0.1` — allowing 10% under the nominal order).

**Validator requirements:**

- Validators MUST reject a `convergence_order` assertion in a test with fewer than two `grid_refs` entries.
- Validators MUST reject a `convergence_order` assertion that omits `reference` or `expected_order`.
- Validators MUST reject a `convergence_order` assertion that includes `expected` (the scalar-comparison field is inapplicable).

**Worked example — 1-D heat equation MMS convergence test** at three grid refinement levels (N = 16, 32, 64), expecting second-order convergence:

```json
{
  "id": "mms_order2",
  "description": "MMS convergence test: 1-D heat equation u_t = 0.01 u_xx, expect O(dx^2)",
  "initial_conditions": {
    "type": "expression",
    "values": {
      "u": { "op": "sin", "args": [{ "op": "*", "args": [3.14159265, "x"] }] }
    }
  },
  "time_span": { "start": 0.0, "end": 0.1 },
  "grid_refs": [
    { "ref": "https://esd.earthsciml.org/grids/cartesian_1d_n16_fd2.gdd.json" },
    { "ref": "https://esd.earthsciml.org/grids/cartesian_1d_n32_fd2.gdd.json" },
    { "ref": "https://esd.earthsciml.org/grids/cartesian_1d_n64_fd2.gdd.json" }
  ],
  "assertions": [
    {
      "variable": "u",
      "time": 0.1,
      "reduce": "convergence_order",
      "reference": {
        "op": "*",
        "args": [
          { "op": "exp", "args": [{ "op": "*", "args": [-0.01, 9.8696, 0.1] }] },
          { "op": "sin", "args": [{ "op": "*", "args": [3.14159265, "x"] }] }
        ]
      },
      "expected_order": 2.0,
      "tolerance": { "rel": 0.1 }
    }
  ]
}
```

The three GDD files encode grids at N = 16, 32, 64 cells. Assuming second-order centered FD, the runtime should observe `p_obs ≈ 2.0`. With `tolerance.rel = 0.1`, the test passes when `p_obs ≥ 1.8`.

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
      "initial_state": {
        "type": "per_variable",
        "values": { "NO": 10.0, "NO2": 20.0, "O3": 50.0 }
      },
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
| `initial_state` | | Initial conditions. Reuses the same `InitialConditions` schema as the `domains` section: `{type: "constant", value}`, `{type: "per_variable", values: {...}}`, `{type: "from_file", path, format?}`, or — for PDE components — `{type: "expression", values: {var: Expression}}` (see §11.4). |
| `parameters` | | Parameter overrides, keyed by local parameter name. |
| `time_span` | ✓ | `{start, end}` in the component's time units. |
| `parameter_sweep` | | Optional parameter sweep; see Section 6.7.3. When present, the example represents a family of runs rather than a single trajectory. |
| `grid_refs` | | PDE only. Array of `{"ref": URL-or-path}` objects pointing to GridDiscretization Descriptor files (§4.7.1). Each entry overrides the component's declared spatial grid and discretization for one run. A single-element list runs the example on exactly that grid configuration. When multiple entries are provided, the example represents a family of runs at different grid configurations — analogous to `parameter_sweep` but varying the grid rather than parameters. `grid_refs` and `parameter_sweep` may be combined; the total run count is their Cartesian product. |
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
      "coupletype": "SuperFastCoupler",

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
| `domain` | | Name of a domain from the `domains` section that this reaction system is defined on. Omit or set to `null` for 0D (non-spatial) systems. |
| `coupletype` | | Coupling type name. Informational label identifying this system's role in coupling. |
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
| `rate` | ✓ | Rate expression: a string (parameter ref), number, or expression AST |
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

---

## 8. Data Loaders

Data loaders are generic, runtime-agnostic descriptions of external data sources. The schema carries enough information to locate files, map timestamps to files, describe spatial/variable semantics, and regrid — **not** just a pointer at a runtime handler.

The shape is loosely modeled on a STAC catalog: it is usable for any gridded or point dataset (reanalysis, emissions inventories, static fields), not tied to any specific runtime or library.

Authentication, credential management, algorithm-specific regridding tuning, and per-variable temporal availability constraints are **out of scope** for the schema. Those are runtime concerns.

### 8.1 Data Loader Fields

| Field | Required | Description |
|---|---|---|
| `kind` | ✓ | Structural kind: `"grid"`, `"points"`, `"static"`, or `"mesh"`. The first three are the classical kinds (§8.2–§8.6); `"mesh"` (discretization RFC §8.A, see §8.9 below) declares a loader that publishes integer connectivity tables and float metric arrays for an unstructured grid. Scientific role (emissions, meteorology, elevation, …) is **not** schema-validated and belongs in `metadata.tags`. |
| `source` | ✓ | File discovery object (see §8.2). |
| `variables` | ✓ | Map of schema-level variable name → variable descriptor (see §8.5). At least one entry required. |
| `temporal` | | Temporal coverage and record layout (see §8.3). |
| `spatial` | | Spatial grid description (see §8.4). |
| `mesh` | conditional | Mesh descriptor (see §8.9). **Required when `kind: "mesh"`**, ignored otherwise. |
| `determinism` | | Reproducibility contract — endian / float format / integer width (see §8.9). Applies to any loader kind, but is most commonly declared on mesh loaders. |
| `regridding` | | Regridding configuration (see §8.6). |
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

### 8.4 `spatial` — grid description

```
spatial:
  crs: string                              # PROJ string or EPSG code (required)
  grid_type: enum                          # required; see below
  staggering:                              # optional, per-dimension
    lon: "center" | "edge"
    lat: "center" | "edge"
    lev: "center" | "edge"
  resolution:                              # optional; in native CRS units
    <dim>: number
  extent:                                  # optional; runtime can infer from files
    <dim>: [min, max]
```

`grid_type` is one of: `"latlon"`, `"lambert_conformal"`, `"mercator"`, `"polar_stereographic"`, `"rotated_pole"`, `"unstructured"`. Use `"unstructured"` (in combination with `kind: "points"`) for point-cloud datasets. For mesh datasets with connectivity, prefer `kind: "mesh"` and declare topology + connectivity / metric fields under `mesh` (see §8.9); `spatial` may be omitted for mesh loaders.

`staggering` is first-class rather than buried in `config`, because it changes how variables align to the grid and is needed for regridding. Dimensions not listed default to `"center"`.

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

### 8.6 `regridding` — regridding configuration

```
regridding:
  fill_value: number                         # optional
  extrapolation: "clamp" | "nan" | "periodic"  # optional, default "clamp"
```

Algorithm-specific tuning (mass-conservative vs. bilinear, smoothing parameters, etc.) is runtime-only and not part of the schema.

### 8.7 Out of scope

- **Authentication / credentials.** Env vars, API keys, S3 credentials, CDS API tokens — all runtime-side. The schema stores **no** credential information.
- **Per-variable temporal availability windows** (e.g. "CEDS covers 1750–2023 for NOx but 1850–2023 for CH4"). Runtime validation concern.
- **Regridding algorithm tuning parameters.**

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
    "spatial": {
      "crs": "EPSG:4326",
      "grid_type": "latlon",
      "staggering": { "lon": "center", "lat": "center" },
      "resolution": { "lon": 0.3125, "lat": 0.25 }
    },
    "variables": {
      "u": { "file_variable": "U10M", "units": "m/s", "description": "10-m eastward wind" },
      "v": { "file_variable": "V10M", "units": "m/s", "description": "10-m northward wind" },
      "T": { "file_variable": "T2M",  "units": "K",   "description": "2-m temperature" },
      "PBLH": { "file_variable": "PBLH", "units": "m", "description": "PBL height" }
    },
    "regridding": { "extrapolation": "clamp" },
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
    "spatial": {
      "crs": "EPSG:4326",
      "grid_type": "latlon",
      "staggering": { "lon": "center", "lat": "center" },
      "resolution": { "lon": 0.5, "lat": 0.5 }
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
    "spatial": {
      "crs": "EPSG:4326",
      "grid_type": "latlon",
      "staggering": { "lon": "center", "lat": "center", "lev": "center" },
      "resolution": { "lon": 0.25, "lat": 0.25 }
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
    "spatial": {
      "crs": "EPSG:4326",
      "grid_type": "latlon",
      "staggering": { "lon": "center", "lat": "center" },
      "resolution": { "lon": 0.00027778, "lat": 0.00027778 }
    },
    "variables": {
      "elevation": {
        "file_variable": "Band1",
        "units": "m",
        "description": "Ground-surface elevation above geoid"
      }
    },
    "regridding": { "fill_value": -9999.0, "extrapolation": "nan" },
    "reference": {
      "citation": "USGS 3D Elevation Program (3DEP)",
      "url": "https://www.usgs.gov/3d-elevation-program"
    },
    "metadata": { "tags": ["elevation", "static", "topography"] }
  }
}
```

### 8.9 `kind: "mesh"` — mesh loaders (discretization RFC §8.A)

A loader declared with `kind: "mesh"` publishes the integer connectivity tables and float metric arrays that an unstructured `grids.<g>` entry (see the discretization RFC §6) resolves by `{loader, field}` reference. `"mesh"` is distinct from `kind: "grid"` (which describes a regular gridded dataset with a CRS under `spatial`) and from `kind: "points"` (which is a point-cloud placeholder with no connectivity).

#### 8.9.1 `mesh` — mesh descriptor

```
mesh:
  topology: enum                    # required — closed set, see below
  connectivity_fields: [string]     # required — integer-typed fields
  metric_fields: [string]           # required — float-typed fields
  dimension_sizes:                  # optional
    <dim>: integer | "from_file"
```

| Field | Required | Description |
|---|---|---|
| `topology` | ✓ | Closed enum: `"mpas_voronoi"` (v0.2.0 MVP), `"fesom_triangular"` (reserved), `"icon_triangular"` (reserved). Adding a new value is a minor version bump. |
| `connectivity_fields` | ✓ | List of integer-typed fields the loader exposes. Entries are referenceable from `grids.<g>.connectivity.<name>.field`. |
| `metric_fields` | ✓ | List of float-typed fields the loader exposes. Entries are referenceable from `grids.<g>.metric_arrays.<name>.generator.field`. |
| `dimension_sizes` | | Map of dimension name → integer extent or the literal string `"from_file"`. Values populate grid-level `parameters` marked `value: "from_loader"`. |

#### 8.9.2 `determinism` — reproducibility contract

```
determinism:
  endian: "little" | "big"
  float_format: "ieee754_single" | "ieee754_double"
  integer_width: 32 | 64
```

`determinism` is a loader-level contract for bit-exact reproducibility. All fields are optional; declared fields are a contract that bindings MUST honor. A binding that cannot honor a declared endian / float format / integer width MUST reject the file at load rather than silently reinterpreting bytes. `determinism` is meaningful for any loader kind but is most commonly declared on mesh loaders where on-wire integer layouts vary.

#### 8.9.3 Worked example — MPAS cvmesh

```json
{
  "data_loaders": {
    "mpas_mesh": {
      "kind": "mesh",
      "source": { "url_template": "file:///data/mpas/x1.2562.grid.nc" },
      "mesh": {
        "topology": "mpas_voronoi",
        "connectivity_fields": ["cellsOnEdge", "edgesOnCell", "verticesOnEdge", "nEdgesOnCell"],
        "metric_fields":       ["dcEdge", "dvEdge", "areaCell"],
        "dimension_sizes":     { "nCells": "from_file", "nEdges": "from_file", "maxEdges": "from_file" }
      },
      "determinism": {
        "endian": "little",
        "float_format": "ieee754_double",
        "integer_width": 32
      },
      "variables": {
        "cellsOnEdge":    { "file_variable": "cellsOnEdge",    "units": "1" },
        "edgesOnCell":    { "file_variable": "edgesOnCell",    "units": "1" },
        "verticesOnEdge": { "file_variable": "verticesOnEdge", "units": "1" },
        "nEdgesOnCell":   { "file_variable": "nEdgesOnCell",   "units": "1" },
        "dcEdge":         { "file_variable": "dcEdge",         "units": "m" },
        "dvEdge":         { "file_variable": "dvEdge",         "units": "m" },
        "areaCell":       { "file_variable": "areaCell",       "units": "m^2" }
      },
      "reference": { "doi": "10.5194/gmd-5-1115-2012" }
    }
  }
}
```

The grid that consumes this loader references fields by name, not by kind:

```json
"grids": {
  "mpas_cvmesh": {
    "family": "unstructured",
    "dimensions": ["cell", "edge", "vertex"],
    "connectivity": {
      "cellsOnEdge": { "shape": ["nEdges", 2], "rank": 2, "loader": "mpas_mesh", "field": "cellsOnEdge" }
    },
    "metric_arrays": {
      "dcEdge": { "rank": 1, "dim": "edge", "generator": { "kind": "loader", "loader": "mpas_mesh", "field": "dcEdge" } }
    }
  }
}
```

---

## 9. Closed Function Registry

### 9.1 Closed-set principle

Every callable that may appear inside an expression is drawn from this section's **closed registry**. There is no per-file declaration of new functions, no `handler_id` lookup, and no out-of-band runtime extension point. The set of valid `fn` `name` values is fixed by the spec version: bindings MUST reject any `fn` node whose `name` is not declared in §9.2 for the file's `esm` version, with diagnostic code `unknown_closed_function`. Loading MUST fail.

The closed-set rule is a deliberate constraint that recovers cross-binding bit-equivalence: an `.esm` file plus the spec version uniquely determines numerical behavior. The trade-off is that adding a primitive requires a spec rev (the addition process, deprecation policy, and compatibility-matrix discipline are described in `docs/rfcs/closed-function-registry.md` §7).

A function belongs in the closed registry **only** when **all three** of the following hold:

- Not expressible in finite closed form using the §4.2 AST ops (powers, polynomials, `min`/`max`/`ifelse`/`sign`, trig / exp / log / sqrt, comparisons, n-ary arithmetic).
- Has well-defined cross-binding semantics that the proposer can pin (formula, edge cases, tolerance).
- There is no cleaner `data_loaders` path: the function operates on inline scalars or small arrays passed via `const`, not on bulk gridded fields.

Anything that fails one of these tests does not belong here. The §1.1 authoring policy MUST be enforced at review time.

### 9.2 v1 closed function set

The v1 set is intentionally narrow: calendar arithmetic on UTC time, plus a single search-into-sorted-table primitive that, composed with the existing `index` op, covers the categorical / interpolation lookups motivated in `docs/rfcs/closed-function-registry.md`. All real-valued time inputs are IEEE-754 `binary64` UTC seconds since the Unix epoch (1970-01-01T00:00:00Z, proleptic Gregorian, no leap-second consultation — the deliberate cross-binding contract). All integer outputs are signed 32-bit; bindings MUST raise `closed_function_overflow` if a result would overflow.

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

The `interp.searchsorted` primitive composes with the existing `index` op (§4.3.3) to express tabulated lookups: `{"op": "index", "args": ["table", {"op": "fn", "name": "interp.searchsorted", "args": ["x", {"op": "const", "value": [...]}]}]}`. Linear blends between adjacent table entries can be written in pure AST (subtract neighbouring `index`-ed values, multiply by a fractional weight, add); the `interp.linear` and `interp.bilinear` primitives below are the **named, opaque** form of those blends — semantically equivalent to the AST composition but exposed as a single `fn` node so that bindings with symbolic-rewriting layers (notably the Julia / MTK extension) can register them as opaque operators and avoid the alias-elimination blow-up that ~10-node-per-lookup AST inlining causes for components with hundreds of lookups (see `docs/rfcs/closed-function-registry.md` and the `interp.linear` / `interp.bilinear` rationale in §9.2 below).

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

**Use with the `index` op:** the canonical use of `enums` is to keep categorical lookups portable. Tables are encoded as `const` arrays; categorical keys are written as `enum` ops; the existing `index` op (§4.3.3) does the actual lookup. See §13 for a worked example using a Wesely-style canopy resistance table.

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

**Authoring policy:** tables are **opt-in**. Loaders MUST NOT silently auto-promote inline `const`-op arrays into `function_tables` entries during round-trip. The migration of an existing inline-const-heavy `.esm` to `function_tables` is a one-shot author-driven refactor, not a load-time canonicalization. This preserves the existing `tests/` corpus, the `esm-editor` round-trip property, and the `esm-format-go` byte-exact reload guarantee.

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

### 9.6 Expression templates (v0.4.0)

v0.4.0 adds **component-scoped in-file Expression-AST templates** for factoring repeated kinetic / rate forms. The mechanism is purely structural: a template names a fixed Expression body with parameter substitution slots, and `apply_expression_template` AST nodes elsewhere in the same component reference the template by name with per-parameter bindings. See `docs/content/rfcs/ast-expression-templates.md` for the full RFC and motivation; this section pins the normative load-time behavior.

#### 9.6.1 The `expression_templates` block

`expression_templates` is declared **inside a single `model` or `reaction_system`** (top-level templates and cross-component sharing are deferred to a follow-up RFC). It is a JSON object whose keys are template names and whose values are template definitions:

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

- `params`: ordered array of unique non-empty parameter names (strings).
- `body`: a normal Expression AST. Parameter occurrences appear as bare parameter-name strings in any variable-reference position.

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

- `name`: id of an `expression_templates` entry declared in the same component.
- `bindings`: object mapping each parameter in the referenced template's `params` to a value. Values MAY be numeric literals, variable name references, or arbitrary Expression ASTs (full subtrees).
- `args`: MUST be an empty array.

#### 9.6.3 Constraints (normative)

1. **AST → AST only.** Templates take Expression args and produce an Expression. No string interpolation, no schema-level substitution, no metaprogramming.
2. **No template-calls-template, no recursion.** A template `body` MUST NOT contain `apply_expression_template` nodes itself.
3. **Typed signatures (positional-by-name).** Bindings MUST cover every entry of the template's `params` exactly — no missing keys, no extras.
4. **Component-local scope.** Templates declared inside one `model` / `reaction_system` are visible only within that component's expression positions.
5. **Pure syntactic substitution.** Every parameter occurrence in `body` is replaced by the bound argument's AST in source order. Expansion MUST NOT depend on argument evaluation.

#### 9.6.4 Round-trip — Option A (always-expanded)

The v1 round-trip model is **Option A: parse-time expansion**. There is no Option B in v1.

1. **Expansion happens at load.** Loaders MUST expand `apply_expression_template` to a fully-substituted Expression AST before any validator, evaluator, doc generator, or `esm-write` sees the tree. After load, downstream code operates on a normal Expression AST and MUST NOT branch on whether a node was produced by template expansion.
2. **Round-trip emits the expanded form.** The canonical AST stored on disk after `parse → emit` is the expanded form. Source `.esm` files that author with `expression_templates` and `apply_expression_template` are the **source of truth**; the emitter does not re-derive template references from an expanded AST.
3. **Determinism.** Two fresh expansions of the same `(template, bindings)` pair MUST produce structurally identical ASTs (same op tree, bit-equal constants). Bindings MAY cache expanded ASTs but caching MUST NOT be observable.
4. **Validators run on the expanded form.** Schema validation, type checks, and domain checks (every check defined in §4 / §9 of the spec) run on the post-expansion AST.

#### 9.6.5 Spec-version gate

`expression_templates` and `apply_expression_template` arrive at `esm: 0.4.0`. Files declaring `esm: 0.3.x` or earlier MUST be rejected by all five bindings if they carry either construct, with diagnostic `apply_expression_template_version_too_old`.

#### 9.6.6 Diagnostics

Bindings MUST emit the following stable diagnostic codes (cross-language uniform; see RFC §1).

| Code | Meaning |
|---|---|
| `apply_expression_template_version_too_old` | File declares `esm` < 0.4.0 but uses `expression_templates` or `apply_expression_template`. |
| `apply_expression_template_unknown_template` | `apply_expression_template.name` references a template not declared in the enclosing component. |
| `apply_expression_template_bindings_mismatch` | `bindings` does not exactly match the template's `params` (missing or extra keys). |
| `apply_expression_template_recursive_body` | A template `body` contains an `apply_expression_template` node (template-calls-template forbidden). |
| `apply_expression_template_invalid_declaration` | `params` is missing/empty/duplicates entries, `body` is missing, or other structural defects. |

#### 9.6.7 Conformance fixtures

Conformance fixtures live under `tests/conformance/expression_templates/`. The v1 set:

- `arrhenius_smoke/fixture.esm` — a 2-parameter `arrhenius` template applied across three reactions with different scalar bindings.
- `arrhenius_smoke/expanded.esm` — the canonical post-expansion form. All five bindings (Julia, Python, Rust, TypeScript, Go) MUST produce a structurally-equal `reactions` array on load.

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

Grid-level loss processes (dry deposition, below-cloud scavenging) that earlier drafts expressed as `operator_apply` coupling entries are now expressed via the `discretizations` block plus PDE operators in the model equations themselves; see `docs/rfcs/discretization.md` §7.

### 10.1 Coupling Types

| Type | EarthSciML Mechanism | Description |
|---|---|---|
| `operator_compose` | `operator_compose(a, b)` | Match LHS time derivatives and add RHS terms together |
| `couple` | `couple(a, b, connector)` | Bi-directional coupling via explicit `ConnectorSystem` equations. The `connector` field specifies the equations that link the two systems. |
| `variable_map` | `param_to_var` + connection | Replace a parameter in one system with a variable from another |
| `callback` | `init_callback` | Register a callback for simulation events |
| `event` | Cross-system event | Continuous or discrete event involving multiple coupled systems (see Section 5.6) |

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

For `variable_map` coupling entries, `transform` specifies how the source variable maps to the target:

| Transform | Description |
|---|---|
| `param_to_var` | Replace a constant parameter with a time-varying variable from another system |
| `identity` | Direct assignment without type change |
| `additive` | Add the source variable as an additional term |
| `multiplicative` | Multiply the target by the source variable |
| `conversion_factor` | Apply a unit conversion factor (specified in the `factor` field) |

### 10.5 Cross-Domain Coupling

When two coupled systems live on different domains, the coupling entry must specify how to handle the dimension mismatch. There are two mechanisms: **interface-mediated** coupling (for spatial domains that share a geometric boundary) and **lifting** (for coupling between 0D and spatial systems).

#### The `interface` Field

For coupling between spatial domains of different dimensionality, reference a named interface from the `interfaces` section (see Section 12). The interface defines the geometric relationship — which dimensions are shared, how non-shared dimensions are constrained, and what regridding strategy to use.

```json
{
  "type": "variable_map",
  "from": "AtmosphericDynamics.wind_u",
  "to": "WildfirePropagation.wind_u",
  "transform": "param_to_var",
  "interface": "ground_surface",
  "description": "Ground-level eastward wind drives wildfire spread"
}
```

The interface handles both dimension reduction (e.g., extracting a 2D slice from a 3D field) and regridding (when shared dimensions have different resolutions across domains). The coupling entry only needs to name the interface — the dimensional details are defined once in the interface specification.

For `operator_compose` and `couple`, the `interface` field works similarly:

```json
{
  "type": "operator_compose",
  "systems": ["AtmosphericDynamics", "WildfireHeatSource"],
  "interface": "ground_surface",
  "description": "Inject wildfire heat release into lowest atmospheric layer"
}
```

#### The `lifting` Field

For coupling between a 0D (non-spatial) system and a spatially-resolved system, the `lifting` field specifies how the 0D system's inputs and outputs map to the spatial grid. The lifting is relative to the **target system's domain** — i.e., the spatial grid on which the operation is evaluated.

```json
{
  "type": "variable_map",
  "from": "FireSpreadCalculator.spread_rate",
  "to": "WildfirePropagation.spread_rate",
  "transform": "param_to_var",
  "lifting": "pointwise",
  "description": "Wind-computed spread rate feeds wildfire PDE at each grid point"
}
```

| Lifting | Description |
|---|---|
| `pointwise` | **(Default.)** The 0D system is evaluated independently at each grid point. Inputs are pointwise values extracted from spatial fields; outputs are pointwise values applied to the spatial grid. This is how column physics parameterizations work in climate models. |
| `broadcast` | A single scalar output from the 0D system is applied uniformly to all grid points. Use when the 0D system computes a domain-wide quantity (e.g., a global scaling factor). |
| `mean` | Inputs to the 0D system are the spatial mean of the source fields. Output is scalar (combine with `broadcast` on the output side if needed). |
| `integral` | Inputs to the 0D system are the spatial integral of the source fields. Output is scalar. |

When `lifting` is omitted and the source or target system has `"domain": null`, pointwise lifting is assumed.

#### Combining `interface` and `lifting`

A coupling chain may require both an interface (for dimension reduction between spatial domains) and lifting (for 0D intermediaries). This is expressed as separate coupling entries. For example, extracting ground-level winds from a 3D atmosphere, passing them through a 0D algebraic fire-spread calculator, and feeding the result into a 2D wildfire model:

```json
[
  {
    "type": "variable_map",
    "from": "AtmosphericDynamics.wind_u",
    "to": "FireSpreadCalculator.wind_u",
    "transform": "param_to_var",
    "interface": "ground_surface",
    "lifting": "pointwise",
    "description": "Ground-level u-wind to fire spread calculator"
  },
  {
    "type": "variable_map",
    "from": "FireSpreadCalculator.spread_rate",
    "to": "WildfirePropagation.R_spread",
    "transform": "param_to_var",
    "lifting": "pointwise",
    "description": "Calculated spread rate drives wildfire propagation"
  }
]
```

In the first entry, `interface` reduces 3D→2D (extracting at the ground surface) and `lifting: "pointwise"` maps the resulting 2D field into the 0D system at each grid point. In the second entry, `lifting: "pointwise"` maps the 0D output to the 2D wildfire grid.

### 10.6 Cross-Domain Coupling Rules

1. **Same-domain coupling** requires no `interface` or `lifting` field and works as described in Sections 10.1–10.4.

2. **Cross-domain spatial coupling** (between domains that share a geometric boundary) **must** reference a named `interface`. The interface defines dimension mapping and regridding. It is an error to couple systems on different spatial domains without an interface.

3. **0D ↔ spatial coupling** **must** specify a `lifting` strategy (or accept the default `pointwise`). A 0D system coupled to a spatial system is evaluated on the spatial system's grid according to the lifting strategy.

4. **0D ↔ 0D coupling** requires neither `interface` nor `lifting` — it is standard scalar coupling.

5. **Cross-domain with 0D intermediary**: When a 0D system mediates between two spatial domains (e.g., atmosphere → 0D calculator → wildfire), each leg of the coupling is a separate entry. The first entry uses `interface` + `lifting`, the second uses `lifting` alone.

6. **Interface-mediated `operator_compose`**: When `operator_compose` crosses an interface, the operator's equations are evaluated on the *lower-dimensional* domain's grid. The interface handles projection/injection automatically — the operator adds terms to the target system's equations after the interface has mapped the fields.

7. **Bidirectional interfaces**: An interface can be traversed in either direction. Coupling from a 3D domain to a 2D domain through an interface performs restriction (slicing + regridding). Coupling from a 2D domain to a 3D domain through the same interface performs prolongation (injection into the constrained dimension level + regridding).

8. **Multiple interfaces between the same domain pair**: Different interfaces between the same two domains are permitted (e.g., `ground_surface` at `lev=min` and `tropopause` at a specific pressure level). Each coupling entry references the specific interface it uses.

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
- **Simulation** — Julia libraries convert the flattened system to a single MTK `ODESystem` (for 0D/ODE-only systems) or `PDESystem` (for systems with spatial derivatives), using MTK's native namespace separator (`₊`) in place of dots.
- **Export and display** — pretty-printing the full coupled system as a single set of equations.

The flattening algorithm is specified in detail in the ESM Library Specification (Section 4.7.5).

---

## 11. Domains

The `domains` section is a dictionary of named spatiotemporal domains. Each domain corresponds to an `EarthSciMLBase.DomainInfo` and specifies the extent, discretization, coordinate system, and boundary/initial conditions for one spatial region. Models and reaction systems reference domains by name via their `domain` field.

Multi-domain configurations enable coupling between systems of different dimensionality — for example, a 3D atmospheric dynamics PDE coupled to a 2D wildfire propagation PDE, or a 3D ocean coupled to the atmosphere at the sea surface.

### 11.1 Schema

```json
{
  "domains": {
    "atmosphere": {
      "independent_variable": "t",

      "temporal": {
        "start": "2024-07-15T00:00:00Z",
        "end": "2024-07-16T00:00:00Z",
        "reference_time": "2024-07-15T00:00:00Z"
      },

      "spatial": {
        "lon": { "min": -120.0, "max": -115.0, "units": "degrees", "grid_spacing": 0.1 },
        "lat": { "min": 33.0, "max": 36.0, "units": "degrees", "grid_spacing": 0.1 },
        "lev": { "min": 0.0, "max": 20000.0, "units": "m", "grid_spacing": 500.0 }
      },

      "coordinate_transforms": [
        { "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }
      ],
      "spatial_ref": "WGS84",

      "initial_conditions": { "type": "constant", "value": 0.0 },
      "boundary_conditions": [
        { "type": "zero_gradient", "dimensions": ["lon", "lat"] },
        { "type": "zero_gradient", "dimensions": ["lev"] }
      ],
      "element_type": "Float64",
      "array_type": "Array"
    },

    "wildfire_surface": {
      "independent_variable": "t",

      "temporal": {
        "start": "2024-07-15T00:00:00Z",
        "end": "2024-07-16T00:00:00Z"
      },

      "spatial": {
        "lon": { "min": -119.0, "max": -117.0, "units": "degrees", "grid_spacing": 0.01 },
        "lat": { "min": 34.0, "max": 35.0, "units": "degrees", "grid_spacing": 0.01 }
      },

      "coordinate_transforms": [
        { "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }
      ],
      "spatial_ref": "WGS84",

      "initial_conditions": { "type": "constant", "value": 0.0 },
      "boundary_conditions": [
        { "type": "zero_gradient", "dimensions": ["lon", "lat"] }
      ],
      "element_type": "Float64"
    },

    "ocean": {
      "independent_variable": "t",

      "temporal": {
        "start": "2024-07-15T00:00:00Z",
        "end": "2024-07-16T00:00:00Z"
      },

      "spatial": {
        "lon": { "min": -120.0, "max": -115.0, "units": "degrees", "grid_spacing": 0.25 },
        "lat": { "min": 33.0, "max": 36.0, "units": "degrees", "grid_spacing": 0.25 },
        "depth": { "min": 0.0, "max": 5000.0, "units": "m", "grid_spacing": 50.0 }
      },

      "coordinate_transforms": [
        { "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }
      ],
      "spatial_ref": "WGS84",

      "initial_conditions": { "type": "constant", "value": 0.0 },
      "boundary_conditions": [
        { "type": "periodic", "dimensions": ["lon"] },
        { "type": "zero_gradient", "dimensions": ["lat"] },
        { "type": "zero_gradient", "dimensions": ["depth"] }
      ],
      "element_type": "Float64"
    }
  }
}
```

### 11.2 Domain Dimensionality

Domains are categorized by their spatial dimensionality:

| Dimensionality | `spatial` field | Example use cases |
|---|---|---|
| **0D** | Omitted or `{}` | Box models, point-source chemistry, algebraic parameterizations |
| **1D** | 1 spatial dimension | Column models, vertical profiles, transect models |
| **2D** | 2 spatial dimensions | Surface fire spread, sea-ice extent, land surface models |
| **3D** | 3 spatial dimensions | Atmospheric dynamics, ocean circulation, subsurface flow |

Models with `"domain": null` are 0D regardless of whether a 0D domain exists. A 0D model has no spatial grid — when coupled to a spatial system, the lifting strategy (Section 10.5) determines how it maps to the spatial grid.

### 11.3 Domain Fields

Each named domain supports the following fields:

| Field | Required | Description |
|---|---|---|
| `independent_variable` | | Name of the time variable (default: `"t"`) |
| `temporal` | | Temporal extent: `start`, `end`, `reference_time` (ISO 8601) |
| `spatial` | | Dictionary of named spatial dimensions, each with `min`, `max`, `units`, `grid_spacing` |
| `coordinate_transforms` | | Array of coordinate transform specifications |
| `spatial_ref` | | Spatial reference system (e.g., `"WGS84"`) |
| `initial_conditions` | | Initial condition specification (see Section 11.4) |
| `boundary_conditions` | | Array of boundary condition specifications (see Section 11.5) |
| `element_type` | | Numeric element type (e.g., `"Float32"`, `"Float64"`) |
| `array_type` | | Array implementation type (e.g., `"Array"`) |

### 11.4 Initial Condition Types

| Type | Fields | Description |
|---|---|---|
| `constant` | `value` | Uniform initial value for all state variables |
| `per_variable` | `values: {var: value}` | Per-variable initial values |
| `from_file` | `path`, `format` | Load from external file |
| `expression` | `values: {var: Expression}` | Per-variable closed-form initial fields. Each value is an `Expression` whose free symbols MUST be names of the component domain's spatial dimensions; the runtime evaluates the expression at every grid point to produce the initial field. PDE components only — meaningless on 0-D components, where validators MUST reject. |

The `expression` shape replaces the prior need to spill PDE initial conditions into a sidecar file: a closed-form initial field (e.g., `u(x, 0) = sin(π x)`) round-trips through the document just like any other inline math.

**Example** — heat equation initial profile on a 1-D domain with dimension `x ∈ [0, 1]`:

```json
{
  "type": "expression",
  "values": {
    "u": { "op": "sin", "args": [{ "op": "*", "args": [3.141592653589793, "x"] }] }
  }
}
```

#### Consumer contract for `expression` entries

**Simulators** (consumers that integrate the model equations) MUST evaluate each variable's expression at every spatial grid point to produce the initial field. Every free symbol in the expression MUST be bound to the corresponding domain spatial-dimension coordinate. Failing to evaluate an `expression` IC is an error for these consumers.

**Non-integrating consumers** (renderers, schema validators, documentation generators) that do not have access to discretization infrastructure MUST NOT raise an error when they encounter `{type: "expression"}`. They MUST handle it one of the following two ways:

1. **Skip with placeholder** *(minimum requirement)*: omit the variable from any scalar display and MAY substitute a human-readable label such as `"⟨expression IC: varname⟩"` wherever a scalar value would otherwise appear.
2. **Sample for illustration** *(optional enrichment)*: evaluate the expression on a coarse uniform grid derived from the declared domain spatial dimensions, and render the result as an illustrative thumbnail. This requires the consumer to implement the ESM expression AST evaluator (§4).

Option 1 is always acceptable. Silently dropping the variable from all output without any indication to the user is PERMITTED but DISCOURAGED — it makes the IC invisible without explanation. Option 2 is reserved for consumers that already embed an expression evaluator.

The key invariant: **a consumer MUST NOT crash or return an error code merely because an IC is expression-typed.** Unrecognised IC shapes MUST be surfaced as validation warnings, not unhandled exceptions.

#### Design rationale: discriminated union

`InitialConditions` uses a **discriminated union on the `type` field**. Any consumer can short-circuit on `type !== "expression"` without inspecting the structure of `values`.

Two alternative designs were considered and rejected:

- **Polymorphic `values` map** (scalars and expressions intermixed in one map without a type tag): consumers must duck-type or speculatively parse every entry to distinguish scalars from expression trees. This is the failure mode that motivated this contract — a renderer that iterated `values` assuming all entries were numbers would silently drop or misrender expression entries.
- **Two-channel split** (`values` for scalars, `value_expressions` for symbolic): readers must consult two sibling fields to reconstruct the full IC picture; merging, copying, or validating IC objects becomes more complex with no compensating benefit.

The discriminated union is the canonical JSON Schema pattern for variant records. Bindings in all five languages can dispatch cleanly on a single string field.

### 11.5 Boundary Condition Types

| Type | Description |
|---|---|
| `constant` | Fixed value at boundaries |
| `zero_gradient` | ∂u/∂n = 0 at boundaries (Neumann) |
| `periodic` | Wrap-around boundaries |
| `dirichlet` | Fixed value at boundaries (equivalent to `constant`) |
| `neumann` | ∂u/∂n = 0 at boundaries (equivalent to `zero_gradient`) |
| `robin` | Mixed boundary condition: αu + β∂u/∂n = γ |

#### Additional Boundary Condition Fields

| Field | Type | Description |
|---|---|---|
| `value` | number | Boundary value (for `constant`/`dirichlet` types) |
| `function` | string | Function specification for time/space-varying boundaries |
| `robin_alpha` | number | Robin BC coefficient α for u term in αu + β∂u/∂n = γ |
| `robin_beta` | number | Robin BC coefficient β for ∂u/∂n term in αu + β∂u/∂n = γ |
| `robin_gamma` | number | Robin BC RHS value γ in αu + β∂u/∂n = γ |

**Note:** `dirichlet` and `neumann` are alternative names for `constant` and `zero_gradient` respectively. The Robin boundary condition provides a general mixed formulation where appropriate coefficients can recover Dirichlet (α=1, β=0) or Neumann (α=0, β=1) conditions as special cases.

### 11.6 Shared Temporal Domain

All domains in a coupled system must have compatible temporal extents. Individual domains may use different spatial discretizations but share the same simulation time window. If temporal extents differ, the runtime uses the intersection of all domain temporal ranges.

---

## 12. Interfaces

Interfaces define the geometric relationship between two domains of potentially different dimensionality. They specify which spatial dimensions are shared, how non-shared dimensions are constrained at the interface, and what regridding strategy is used when shared dimensions have different resolutions.

### 12.1 Schema

```json
{
  "interfaces": {
    "ground_surface": {
      "description": "Ground-level interface between atmosphere and land surface / wildfire domain",
      "domains": ["atmosphere", "wildfire_surface"],
      "dimension_mapping": {
        "shared": {
          "atmosphere.lon": "wildfire_surface.lon",
          "atmosphere.lat": "wildfire_surface.lat"
        },
        "constraints": {
          "atmosphere.lev": {
            "value": "min",
            "description": "Ground level (lowest atmospheric layer)"
          }
        }
      },
      "regridding": {
        "method": "bilinear"
      }
    },

    "sea_surface": {
      "description": "Air-sea interface between atmosphere and ocean",
      "domains": ["atmosphere", "ocean"],
      "dimension_mapping": {
        "shared": {
          "atmosphere.lon": "ocean.lon",
          "atmosphere.lat": "ocean.lat"
        },
        "constraints": {
          "atmosphere.lev": {
            "value": "min",
            "description": "Lowest atmospheric level"
          },
          "ocean.depth": {
            "value": "min",
            "description": "Ocean surface layer"
          }
        }
      },
      "regridding": {
        "method": "conservative",
        "description": "Flux-conserving interpolation for energy and mass exchange"
      }
    }
  }
}
```

### 12.2 Interface Fields

| Field | Required | Description |
|---|---|---|
| `description` | | Human-readable description of the interface |
| `domains` | ✓ | Two-element array naming the domains connected by this interface |
| `dimension_mapping` | ✓ | Specifies shared dimensions and constraints (see below) |
| `regridding` | | Regridding strategy when shared dimensions differ in resolution |

### 12.3 Dimension Mapping

The `dimension_mapping` object has two sub-fields:

**`shared`**: A dictionary mapping dimensions that correspond across the two domains. Keys and values use `"domain.dimension"` notation. Shared dimensions define the geometric surface where the two domains meet. If the shared dimensions have different extents, the interface surface is their intersection.

```json
"shared": {
  "atmosphere.lon": "wildfire_surface.lon",
  "atmosphere.lat": "wildfire_surface.lat"
}
```

**`constraints`**: A dictionary specifying how non-shared dimensions are fixed at the interface. Each key is a `"domain.dimension"` reference; the value specifies where that dimension is constrained.

| Constraint value | Description |
|---|---|
| `"min"` | The minimum value of the dimension's range |
| `"max"` | The maximum value of the dimension's range |
| *(number)* | A specific coordinate value within the dimension's range |
| `"boundary"` | The domain boundary (equivalent to `"min"` or `"max"` depending on orientation) |

```json
"constraints": {
  "atmosphere.lev": { "value": "min", "description": "Ground level" },
  "ocean.depth": { "value": 0.0, "description": "Sea surface" }
}
```

**Constraint semantics**: When a variable is transferred **from** a domain with a constrained dimension, the field is *sliced* (restricted) at that coordinate — reducing dimensionality by one per constraint. When a variable is transferred **to** a domain with a constrained dimension, the lower-dimensional field is *injected* (prolongated) at that coordinate — embedded into the higher-dimensional grid at the specified level.

### 12.4 Regridding

When shared dimensions have different resolutions or extents across the two domains, regridding interpolates fields between the grids. The `regridding` field specifies the interpolation strategy.

| Method | Description |
|---|---|
| `bilinear` | Bilinear interpolation. Suitable for smooth fields (temperature, pressure, winds). |
| `conservative` | Flux-conserving remapping. Preserves integrated quantities (mass, energy). Required for budget-critical exchanges. |
| `nearest` | Nearest-neighbor assignment. Suitable for categorical or discontinuous fields (land use type, fire/no-fire mask). |
| `patch` | Higher-order patch recovery interpolation. Smooth and accurate but more expensive. |

If `regridding` is omitted and the shared dimensions have identical grids (same min, max, and grid_spacing), no regridding is needed. If grids differ and `regridding` is omitted, it is an error.

### 12.5 Interface Examples

#### 3D Atmosphere ↔ 2D Wildfire Surface

The atmosphere has 3 spatial dimensions (lon, lat, lev). The wildfire model has 2 (lon, lat). They share the horizontal dimensions; the vertical dimension is constrained at ground level.

```json
{
  "ground_surface": {
    "description": "Ground-level interface: atmosphere ↔ wildfire",
    "domains": ["atmosphere", "wildfire_surface"],
    "dimension_mapping": {
      "shared": {
        "atmosphere.lon": "wildfire_surface.lon",
        "atmosphere.lat": "wildfire_surface.lat"
      },
      "constraints": {
        "atmosphere.lev": { "value": "min" }
      }
    },
    "regridding": { "method": "bilinear" }
  }
}
```

Transferring `atmosphere.wind_u` through this interface: the 3D field is sliced at `lev=min` to produce a 2D field on the atmosphere's horizontal grid, then regridded to the wildfire grid via bilinear interpolation.

Transferring `wildfire.heat_flux` through this interface in reverse: the 2D field on the wildfire grid is regridded to the atmosphere's horizontal grid, then injected into the 3D atmospheric grid at `lev=min`.

#### 3D Atmosphere ↔ 3D Ocean

Both domains are 3D, but they share only the horizontal dimensions. The vertical dimensions are independent (atmospheric levels vs. ocean depth), and both are constrained at their interface values.

```json
{
  "sea_surface": {
    "description": "Air-sea interface: atmosphere ↔ ocean",
    "domains": ["atmosphere", "ocean"],
    "dimension_mapping": {
      "shared": {
        "atmosphere.lon": "ocean.lon",
        "atmosphere.lat": "ocean.lat"
      },
      "constraints": {
        "atmosphere.lev": { "value": "min" },
        "ocean.depth": { "value": "min" }
      }
    },
    "regridding": { "method": "conservative" }
  }
}
```

Transferring `atmosphere.surface_stress` through this interface: the 3D atmospheric field is sliced at `lev=min` to produce a 2D field, regridded from the atmosphere's horizontal grid to the ocean's horizontal grid (conservative), then injected into the ocean at `depth=min`.

#### 1D Column ↔ 3D Atmosphere

A 1D column model (e.g., vertical turbulence parameterization) coupled to a 3D atmosphere. The column model has one spatial dimension (height); the interface constrains the atmospheric horizontal coordinates to a specific column.

```json
{
  "observation_column": {
    "description": "Single column extracted from 3D atmosphere",
    "domains": ["atmosphere", "column_model"],
    "dimension_mapping": {
      "shared": {
        "atmosphere.lev": "column_model.z"
      },
      "constraints": {
        "atmosphere.lon": { "value": -118.0 },
        "atmosphere.lat": { "value": 34.0 }
      }
    }
  }
}
```

---

## 13. Complete Examples

### 13.1 Single-Domain: Atmospheric Chemistry with Advection

A minimal but complete `.esm` file representing atmospheric chemistry with advection:

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "MinimalChemAdvection",
    "description": "O3-NO-NO2 chemistry with advection and external meteorology",
    "authors": ["Chris Tessum"],
    "created": "2026-02-11T00:00:00Z"
  },

  "reaction_systems": {
    "SimpleOzone": {
      "coupletype": "SimpleOzoneCoupler",
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
      "reference": { "notes": "First-order advection" },
      "variables": {
        "u_wind": { "type": "parameter", "units": "m/s", "default": 0.0 },
        "v_wind": { "type": "parameter", "units": "m/s", "default": 0.0 }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["_var"], "wrt": "t" },
          "rhs": {
            "op": "+", "args": [
              { "op": "*", "args": [{ "op": "-", "args": ["u_wind"] }, { "op": "grad", "args": ["_var"], "dim": "x" }] },
              { "op": "*", "args": [{ "op": "-", "args": ["v_wind"] }, { "op": "grad", "args": ["_var"], "dim": "y" }] }
            ]
          }
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
      "spatial": {
        "crs": "EPSG:4326",
        "grid_type": "latlon",
        "staggering": { "lon": "center", "lat": "center" },
        "resolution": { "lon": 0.3125, "lat": 0.25 }
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

  "domains": {
    "default": {
      "temporal": { "start": "2024-05-01T00:00:00Z", "end": "2024-05-03T00:00:00Z" },
      "spatial": {
        "lon": { "min": -130.0, "max": -100.0, "grid_spacing": 0.3125, "units": "degrees" }
      },
      "coordinate_transforms": [
        { "id": "lonlat_to_meters", "dimensions": ["lon"] }
      ],
      "initial_conditions": { "type": "constant", "value": 1.0e-9 },
      "boundary_conditions": [
        { "type": "zero_gradient", "dimensions": ["lon"] }
      ],
      "element_type": "Float32"
    }
  }
}
```

**Note:** When all models share a single domain, `"domain"` fields on individual models may be omitted — all models default to the sole domain.

### 13.2 Multi-Domain: Wildfire–Atmosphere–Ocean Coupling

A coupled system with a 3D atmospheric dynamics PDE, a 2D wildfire propagation PDE, a 3D ocean dynamics PDE, and 0D algebraic intermediaries. This example demonstrates mixed-dimension coupling through interfaces and pointwise lifting of 0D systems.

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "WildfireAtmosphereOcean",
    "description": "Coupled wildfire-atmosphere-ocean system with 0D parameterizations",
    "authors": ["EarthSciML"],
    "created": "2026-04-08T00:00:00Z"
  },

  "models": {
    "AtmosphericDynamics": {
      "domain": "atmosphere",
      "reference": { "notes": "Simplified 3D atmospheric dynamics" },
      "variables": {
        "T": { "type": "state", "units": "K", "default": 288.0, "description": "Temperature" },
        "wind_u": { "type": "state", "units": "m/s", "default": 0.0, "description": "Eastward wind" },
        "wind_v": { "type": "state", "units": "m/s", "default": 0.0, "description": "Northward wind" },
        "q_heat": { "type": "parameter", "units": "K/s", "default": 0.0, "description": "External heating rate" }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["T"], "wrt": "t" },
          "rhs": {
            "op": "+",
            "args": [
              { "op": "*", "args": [{ "op": "-", "args": ["wind_u"] }, { "op": "grad", "args": ["T"], "dim": "x" }] },
              { "op": "*", "args": [{ "op": "-", "args": ["wind_v"] }, { "op": "grad", "args": ["T"], "dim": "y" }] },
              "q_heat"
            ]
          }
        }
      ]
    },

    "WildfirePropagation": {
      "domain": "wildfire_surface",
      "reference": { "notes": "Level-set wildfire spread model" },
      "variables": {
        "phi": { "type": "state", "units": "1", "default": 1.0, "description": "Level-set function (phi<0 = burned)" },
        "R_spread": { "type": "parameter", "units": "m/s", "default": 0.0, "description": "Fire spread rate" },
        "fuel": { "type": "state", "units": "kg/m^2", "default": 10.0, "description": "Fuel load" },
        "heat_release": {
          "type": "observed", "units": "W/m^2",
          "expression": {
            "op": "*",
            "args": [
              "R_spread", "fuel",
              { "op": "ifelse", "args": [
                { "op": "<", "args": ["phi", 0] }, 18000.0, 0.0
              ]}
            ]
          },
          "description": "Heat release rate at fire front"
        }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["phi"], "wrt": "t" },
          "rhs": {
            "op": "*",
            "args": [
              { "op": "-", "args": ["R_spread"] },
              { "op": "sqrt", "args": [
                { "op": "+", "args": [
                  { "op": "^", "args": [{ "op": "grad", "args": ["phi"], "dim": "x" }, 2] },
                  { "op": "^", "args": [{ "op": "grad", "args": ["phi"], "dim": "y" }, 2] }
                ]}
              ]}
            ]
          }
        },
        {
          "lhs": { "op": "D", "args": ["fuel"], "wrt": "t" },
          "rhs": {
            "op": "ifelse",
            "args": [
              { "op": "<", "args": ["phi", 0] },
              { "op": "*", "args": [-0.01, "fuel"] },
              0.0
            ]
          }
        }
      ]
    },

    "FireSpreadCalculator": {
      "domain": null,
      "reference": { "notes": "Rothermel-style wind-driven spread rate (algebraic)" },
      "variables": {
        "wind_u": { "type": "parameter", "units": "m/s", "default": 0.0, "description": "Eastward wind at ground level" },
        "wind_v": { "type": "parameter", "units": "m/s", "default": 0.0, "description": "Northward wind at ground level" },
        "R_base": { "type": "parameter", "units": "m/s", "default": 0.05, "description": "Base spread rate (no wind)" },
        "wind_factor": { "type": "parameter", "units": "1", "default": 0.3, "description": "Wind enhancement coefficient" },
        "wind_speed": {
          "type": "observed", "units": "m/s",
          "expression": {
            "op": "sqrt",
            "args": [{ "op": "+", "args": [
              { "op": "^", "args": ["wind_u", 2] },
              { "op": "^", "args": ["wind_v", 2] }
            ]}]
          },
          "description": "Wind speed magnitude"
        },
        "spread_rate": {
          "type": "observed", "units": "m/s",
          "expression": {
            "op": "*",
            "args": [
              "R_base",
              { "op": "+", "args": [1.0, { "op": "*", "args": ["wind_factor", "wind_speed"] }] }
            ]
          },
          "description": "Wind-enhanced fire spread rate"
        }
      },
      "equations": []
    },

    "OceanDynamics": {
      "domain": "ocean",
      "reference": { "notes": "Simplified 3D ocean dynamics" },
      "variables": {
        "SST": { "type": "state", "units": "K", "default": 290.0, "description": "Sea surface temperature" },
        "u_ocean": { "type": "state", "units": "m/s", "default": 0.0, "description": "Eastward ocean current" },
        "surface_heat_flux": { "type": "parameter", "units": "W/m^2", "default": 0.0, "description": "Net heat flux from atmosphere" }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["SST"], "wrt": "t" },
          "rhs": {
            "op": "+",
            "args": [
              { "op": "*", "args": [{ "op": "-", "args": ["u_ocean"] }, { "op": "grad", "args": ["SST"], "dim": "x" }] },
              { "op": "/", "args": ["surface_heat_flux", 4.18e6] }
            ]
          }
        }
      ]
    },

    "AirSeaFluxCalculator": {
      "domain": null,
      "reference": { "notes": "Bulk formula for air-sea heat exchange (algebraic)" },
      "variables": {
        "T_atm": { "type": "parameter", "units": "K", "default": 288.0, "description": "Atmospheric temperature at surface" },
        "SST": { "type": "parameter", "units": "K", "default": 290.0, "description": "Sea surface temperature" },
        "wind_speed": { "type": "parameter", "units": "m/s", "default": 5.0, "description": "Surface wind speed" },
        "C_H": { "type": "parameter", "units": "1", "default": 1.2e-3, "description": "Heat transfer coefficient" },
        "rho_air": { "type": "parameter", "units": "kg/m^3", "default": 1.225, "description": "Air density" },
        "c_p": { "type": "parameter", "units": "J/(kg*K)", "default": 1005.0, "description": "Specific heat of air" },
        "sensible_heat_flux": {
          "type": "observed", "units": "W/m^2",
          "expression": {
            "op": "*",
            "args": ["rho_air", "c_p", "C_H", "wind_speed",
              { "op": "-", "args": ["T_atm", "SST"] }
            ]
          },
          "description": "Sensible heat flux (positive = ocean to atmosphere)"
        }
      },
      "equations": []
    }
  },

  "domains": {
    "atmosphere": {
      "temporal": { "start": "2024-07-15T00:00:00Z", "end": "2024-07-16T00:00:00Z" },
      "spatial": {
        "lon": { "min": -120.0, "max": -115.0, "units": "degrees", "grid_spacing": 0.1 },
        "lat": { "min": 33.0, "max": 36.0, "units": "degrees", "grid_spacing": 0.1 },
        "lev": { "min": 0.0, "max": 20000.0, "units": "m", "grid_spacing": 500.0 }
      },
      "coordinate_transforms": [{ "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }],
      "spatial_ref": "WGS84",
      "initial_conditions": { "type": "constant", "value": 0.0 },
      "boundary_conditions": [
        { "type": "zero_gradient", "dimensions": ["lon", "lat"] },
        { "type": "zero_gradient", "dimensions": ["lev"] }
      ],
      "element_type": "Float64"
    },
    "wildfire_surface": {
      "temporal": { "start": "2024-07-15T00:00:00Z", "end": "2024-07-16T00:00:00Z" },
      "spatial": {
        "lon": { "min": -119.0, "max": -117.0, "units": "degrees", "grid_spacing": 0.01 },
        "lat": { "min": 34.0, "max": 35.0, "units": "degrees", "grid_spacing": 0.01 }
      },
      "coordinate_transforms": [{ "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }],
      "spatial_ref": "WGS84",
      "initial_conditions": { "type": "constant", "value": 1.0 },
      "boundary_conditions": [
        { "type": "zero_gradient", "dimensions": ["lon", "lat"] }
      ],
      "element_type": "Float64"
    },
    "ocean": {
      "temporal": { "start": "2024-07-15T00:00:00Z", "end": "2024-07-16T00:00:00Z" },
      "spatial": {
        "lon": { "min": -120.0, "max": -115.0, "units": "degrees", "grid_spacing": 0.25 },
        "lat": { "min": 33.0, "max": 36.0, "units": "degrees", "grid_spacing": 0.25 },
        "depth": { "min": 0.0, "max": 5000.0, "units": "m", "grid_spacing": 50.0 }
      },
      "coordinate_transforms": [{ "id": "lonlat_to_meters", "dimensions": ["lon", "lat"] }],
      "spatial_ref": "WGS84",
      "initial_conditions": { "type": "constant", "value": 290.0 },
      "boundary_conditions": [
        { "type": "periodic", "dimensions": ["lon"] },
        { "type": "zero_gradient", "dimensions": ["lat", "depth"] }
      ],
      "element_type": "Float64"
    }
  },

  "interfaces": {
    "ground_surface": {
      "description": "Ground-level interface: atmosphere ↔ wildfire",
      "domains": ["atmosphere", "wildfire_surface"],
      "dimension_mapping": {
        "shared": {
          "atmosphere.lon": "wildfire_surface.lon",
          "atmosphere.lat": "wildfire_surface.lat"
        },
        "constraints": {
          "atmosphere.lev": { "value": "min" }
        }
      },
      "regridding": { "method": "bilinear" }
    },
    "sea_surface": {
      "description": "Air-sea interface: atmosphere ↔ ocean",
      "domains": ["atmosphere", "ocean"],
      "dimension_mapping": {
        "shared": {
          "atmosphere.lon": "ocean.lon",
          "atmosphere.lat": "ocean.lat"
        },
        "constraints": {
          "atmosphere.lev": { "value": "min" },
          "ocean.depth": { "value": "min" }
        }
      },
      "regridding": { "method": "conservative" }
    }
  },

  "coupling": [
    {
      "type": "variable_map",
      "from": "AtmosphericDynamics.wind_u",
      "to": "FireSpreadCalculator.wind_u",
      "transform": "param_to_var",
      "interface": "ground_surface",
      "lifting": "pointwise",
      "description": "Ground-level u-wind to fire spread calculator"
    },
    {
      "type": "variable_map",
      "from": "AtmosphericDynamics.wind_v",
      "to": "FireSpreadCalculator.wind_v",
      "transform": "param_to_var",
      "interface": "ground_surface",
      "lifting": "pointwise",
      "description": "Ground-level v-wind to fire spread calculator"
    },
    {
      "type": "variable_map",
      "from": "FireSpreadCalculator.spread_rate",
      "to": "WildfirePropagation.R_spread",
      "transform": "param_to_var",
      "lifting": "pointwise",
      "description": "Calculated spread rate drives wildfire propagation"
    },
    {
      "type": "variable_map",
      "from": "WildfirePropagation.heat_release",
      "to": "AtmosphericDynamics.q_heat",
      "transform": "param_to_var",
      "interface": "ground_surface",
      "factor": 2.4e-7,
      "description": "Wildfire heat injection into lowest atmospheric layer (W/m^2 → K/s)"
    },
    {
      "type": "variable_map",
      "from": "AtmosphericDynamics.T",
      "to": "AirSeaFluxCalculator.T_atm",
      "transform": "param_to_var",
      "interface": "sea_surface",
      "lifting": "pointwise",
      "description": "Surface air temperature to air-sea flux calculator"
    },
    {
      "type": "variable_map",
      "from": "OceanDynamics.SST",
      "to": "AirSeaFluxCalculator.SST",
      "transform": "param_to_var",
      "interface": "sea_surface",
      "lifting": "pointwise",
      "description": "Sea surface temperature to air-sea flux calculator"
    },
    {
      "type": "variable_map",
      "from": "AirSeaFluxCalculator.sensible_heat_flux",
      "to": "OceanDynamics.surface_heat_flux",
      "transform": "param_to_var",
      "lifting": "pointwise",
      "description": "Calculated heat flux drives ocean surface temperature"
    }
  ]
}
```

This example demonstrates:
- **3D → 2D coupling** via the `ground_surface` interface (atmospheric winds → fire spread)
- **2D → 3D coupling** via the same interface in reverse (wildfire heat → atmosphere)
- **3D → 3D coupling** via the `sea_surface` interface (atmosphere ↔ ocean, both constrained to surface)
- **0D intermediaries** with `"lifting": "pointwise"` (`FireSpreadCalculator`, `AirSeaFluxCalculator`)
- **Cross-domain 0D algebraic systems** that take inputs from one domain and produce outputs for another

---

## 14. Design Principles

### Full specification is mandatory for models and reactions

Every equation, species, reaction, parameter, and variable must be present in the `.esm` file. This guarantees:

- A parser in **any language** can reconstruct the mathematical system
- Models are **reproducible** without access to specific software versions
- The format is **archival** — it remains meaningful years later even if packages change
- **Diffs are meaningful** — every change to the science is visible in version control

### Data loaders are the only externally-registered mechanism

Data loaders are runtime-specific: they involve I/O, format adapters, regridding, and large external grids that cannot be meaningfully serialized as math. The `.esm` file declares *what* they provide and *what* they need, but delegates *how* to the runtime. State-mutating numerical schemes (advection, diffusion stencils, deposition algorithms) are **not** an externally-registered mechanism: they are expressed via PDE operators in model equations and named entries in the `discretizations` block (`docs/rfcs/discretization.md` §7). Pure callables embedded inside expressions are **not** an externally-registered mechanism either: they are drawn from the closed function registry (Section 9), whose entries are spec-pinned with fixed names, signatures, and tolerances.

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

### Interfaces separate geometry from physics

Cross-domain coupling requires two distinct concerns: the *geometric relationship* between domains (shared dimensions, constraints, regridding) and the *physical coupling* (which variables connect, how they transform). Interfaces capture the geometry once; coupling entries reference interfaces and specify the physics. This separation means:

- The same interface can be reused by many coupling entries (e.g., dozens of variables exchanged at the sea surface)
- Geometric details don't clutter individual coupling rules
- Changes to grid resolution or regridding strategy propagate automatically to all couplings that use the interface

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
