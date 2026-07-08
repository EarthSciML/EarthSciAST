# RFC — Language-agnostic Discretization in ESM

> **SUPERSEDED (v0.8.0 clean break).** The bespoke discretization machinery this
> RFC defines — the `grids` / `staggering_rules` / `discretizations` blocks, the
> stencil-template rule grammar (`Discretization`, `Rule`, `PatternNode`,
> `NeighborSelector`, `StencilEntry`, `BoundaryPolicy`, `GhostWidth`, …),
> GridDiscretization Descriptors, and `Equation.region` — was **removed from the
> schema in v0.8.0**. Spatial grid geometry (topology, connectivity, metric
> arrays) and discretization stencils are now expressed directly as `aggregate`
> Functional Aggregate Query nodes; see **`semiring-faq-unified-ir.md`**. This
> document is retained for historical context only and is no longer normative.

**Status:** SUPERSEDED by `semiring-faq-unified-ir.md` (was: Draft v2.2 — §5.4.6 on-wire int/float disambiguation per gt-h9kt)
**Bead:** gt-dq0f (v1), gt-yx9y (v2 revision), gt-woe1 (v2.1 addenda), gt-h9kt (v2.2 addendum)
**Affects spec version:** 0.1.0 → 0.2.0 (**breaking**; see §10 and §16 for migration)
**Scope:** Spatial discretization only. Time integration remains a runtime concern.

---

## 1. Motivation

ESM today fully specifies continuous PDE systems (models, reactions, coupling,
domains, interfaces) but stops short of describing *how* those PDEs are
discretized in space. Every consumer must defer to a language-specific engine
— currently MethodOfLines.jl (rectangular grids) and EarthSciDiscretizations.jl
(unstructured FV). Python, Rust, Go, and TS bindings therefore cannot produce
an ODE/DAE system from a `.esm` file without re-implementing every discretization
in every language, and the Julia implementations have already diverged in
coverage and numerics.

The goal of this RFC is to extend the existing ESM format with a complete,
language-agnostic specification of spatial discretization that:

1. Covers the grid families that currently matter to earth-system modeling:
   logically-rectangular (MOL) and unstructured Voronoi (MPAS, including
   variable-valence cells).
2. Lets any binding turn a PDE `.esm` file into a discretized ODE/DAE system
   without calling into Julia.
3. Emits bitwise-identical expression output across bindings on the conformance
   harness, via a normatively-defined canonical AST form (§5.4).
4. Reuses the existing expression AST (including `index`, now extended per
   §5.1), `substitute` / `evaluate` / `free_variables` / `simplify` primitives,
   `parameters`, domains, and the `data_loaders` subsystem.
5. Does **not** introduce a second file format.

## 2. Non-goals

- Time integration. ODE/DAE systems produced by discretization are handed to
  MTK, SciPy/SUNDIALS/Diffrax, DifferentialEquations.jl, diffsol, etc.
  Time-stepping schemes, implicit solvers, operator-splitting, and adaptive
  timestep control are out of scope.
- New numerical methods. The RFC specifies a *serialization* for existing
  discretization strategies, not new ones.
- Runtime performance tuning. Sparsity patterns, tile sizes, vectorization
  hints, and GPU mappings are runtime concerns and are explicitly excluded from
  the schema (cf. §4.3.6 of the existing spec).
- Grid *generation* algorithms. The schema describes how metric arrays are
  *obtained* (analytic expression or opaque loader); it does not prescribe the
  algorithms that produce them.

## 3. Architectural commitment

Extend the existing ESM top-level object with three new sections:

| Section | Purpose |
|---|---|
| `grids` | Topology and metric-array declarations for a spatial grid |
| `discretizations` | Named numerical schemes (stencil templates) |
| `rules` | Pattern-match rewrite rules from PDE operators to schemes |

Discretization is the composition *rules ∘ discretizations ∘ grids*: a rule
matches a PDE operator on a variable whose `domain` uses a particular grid and
rewrites it, via a named scheme, into an expression that references the grid's
metric arrays as `index`-addressed variables.

Two further existing-section changes are required (see §10 for details and
§16 for migration):

- `models.<M>.boundary_conditions` is promoted to first-class (structurally
  parallel to `coupling`). `domains.<d>.boundary_conditions` is **removed**.
- `variables.<name>` gains optional `shape` and `location` fields to describe
  arrayed and staggered state variables (spec §6.1 amendment).

No new file format, no additional top-level sections beyond the three above,
and no new AST node types beyond the pattern/guard sub-language of §5.2. The
new §5.3 `regrid` op is specified below and is the only AST-level addition.

## 4. Unifying abstraction: the neighbor selector

All target grid families reduce to a single stencil template:

```
output[target] = ⊕_k coeff_k · var[neighbor_k(target)]
```

where `⊕` is `+` for linear schemes and may be `*`, `min`, or `max` for
reductions (see §4.2). They differ only in how `neighbor_k` is addressed. The
RFC introduces **one** selector abstraction with three concrete forms:

| Form | Fields | Grid family |
|---|---|---|
| `cartesian` | `axis`, `offset` | Logically-rectangular (MOL) |
| `indirect` | `table`, `index_expr` | Unstructured fixed-valence (e.g. edge→cell) |
| `reduction` | `table`, `count_expr`, `k_bound`, `combine ∈ {+,*,min,max}` | Unstructured variable-valence (e.g. cell→edges) |

Exactly one selector kind lives inside a stencil-template entry, chosen by the
grid family the scheme is declared for. Rules attach a scheme to a grid at
application time, so a scheme's selector kind must be compatible with the
grid's declared family.

The **reduction** selector (new in v2) closes the MPAS variable-valence gap
identified in review M2. It expands, at materialization time, into a reduction
over a loader-provided contiguous index range (e.g. `edgesOnCell[c, 0
.. nEdgesOnCell[c] - 1]`), combining via the declared operator. See §7.2 for
the expansion rule and §7.3 for the worked MPAS divergence example.

## 5. AST extensions

### 5.1 Extended contexts for `index` (resolves C1)

The existing `index` op (spec §4.3.3) is sufficient for every array-element
reference this RFC needs. `index` is **not** restricted to appearing inside
`arrayop.expr`; the parenthetical in §4.3.3 — "as a string, when inside an
`arrayop.expr`" — qualifies only the interpretation of a bare-string index
argument as a symbolic index variable, not the op's legal contexts.

This RFC normatively confirms and adds:

1. **`index` is legal in any expression context**, including the `rhs` of a
   model equation, a coupling expression, or a BC replacement AST. Outside
   `arrayop.expr`, bare-string index arguments are resolved as ordinary
   parameter references (§6.2 of the spec), not as symbolic index variables.
2. **Integer literals and composite index expressions** are permitted:
   `{op:"index", args:["u", 0]}`, `{op:"index", args:["u", {op:"+",
   args:["i", 1]}]}`, and `{op:"index", args:["cellsOnEdge", "$e", 1]}` are
   all valid. This is already consistent with §4.3.3 — this RFC only pins it.
3. **Resolution of `index` on a non-`arrayop` expression.** Given
   `{op:"index", args:[E, i_1, ..., i_n]}` where `E` is not a bare variable
   name:
   - If `E` is a `makearray`, reduce by the `makearray` axes' extents
     (spec §4.3.2) and return the element expression.
   - If `E` is a `broadcast`, distribute: `index(broadcast(fn, A, B), i) =
     broadcast_scalar(fn, index(A, i), index(B, i))`.
   - If `E` is a `reshape`/`transpose`/`concat`, inverse-map the indices per
     that op's semantics and recurse.
   - Otherwise, the expression is ill-formed and must be rejected by the
     loader.

Validation rule (new, applied by the loader after resolving `ref`s): given
`{op:"index", args:[V, i_1, ..., i_n]}` where `V` is a bare variable name,
`V` must resolve to either (a) a declared variable (model/reaction/grid
metric) whose `shape` field (see §11 below and spec §6.1 amendment) has
length `n`, or (b) a connectivity table declared under a grid (§6.3).
Integer bounds are **not** checked statically; out-of-bounds access is a
runtime concern.

**The parallel `idx` op proposed in v1 is dropped.** All of this RFC's
array-element references use `index`.

### 5.2 Pattern variables and rule engine

Rewrite rules cannot be expressed with positional `substitute`. The RFC adds a
small pattern sub-language, analogous to SymbolicUtils `@rule`, that is itself
serializable. A rule object has three fields:

| Field | Type | Purpose |
|---|---|---|
| `pattern` | AST with `$`-prefixed pattern variables | Matches an input expression |
| `where` | array of guard objects OR an expression-AST predicate | See §5.2.7 below. Array form is the legacy rule-selection-time guard vocabulary (§5.2.4). Object form (an `ExpressionNode`) is a per-query-point predicate: the rule applies only at points where the predicate evaluates true. |
| `replacement` | AST over the same pattern variables | Inline replacement expression. Mutually exclusive with `use`. |
| `use` | string — a scheme name from `discretizations.<name>` | Use the named scheme; its `applies_to` is matched as a guard (§7.2.1). Mutually exclusive with `replacement`. |
| `produces` | array of `{kind, emit|value, ...}` entries | Optional; emits additional equations or ghost variables (§9.4). A rule with `produces` alone (no `replacement`/`use`) is legal and means "leave the matched subtree alone and emit these side equations". |
| `region` | string OR object (optional) | See §5.2.7 below. String form is the legacy advisory tag (no runtime effect). Object form is a normative spatial-scope predicate: the rule applies only at points in scope. Variants: `{kind:"boundary",side:...}`, `{kind:"mask_field",field:...}`, `{kind:"index_range",axis:...,lo:int,hi:int}`. |

Pattern variables are strings prefixed by `$`: `"$u"`, `"$x"`. The sub-language
is a closed AST shape, not a DSL string; every binding can load it with its
ordinary JSON parser.

**`replacement` vs `use`.** The two forms are alternative syntaxes for
the same rewrite. Use `replacement` when the output is a small, inline
AST (e.g. `{op: "index", ...}` for periodic wrap); use `use` when the
output is a structured stencil expansion that belongs in
`discretizations.<name>`. Both produce the same rewritten AST after
§7.2 expansion. A second worked example using `replacement` is the
periodic-wrap rule in §9.2.1.

#### 5.2.1 What a pattern variable binds to

The binding class of a pattern variable depends on **where it appears in the
pattern tree**, not on the variable's name. The three binding classes are:

| Class | Appears in | Binds |
|---|---|---|
| **name** | a sibling-field position whose spec-defined type is a string identifier (`dim`, `wrt`, `side`, `kind`, `axis`, `fn`) | A bare string (variable, dimension, or enum name) |
| **leaf** | an `args` position whose surrounding op requires a bare name (e.g. the operand of `D`, the variable of `bc`, the target of `grad`) | A bare string (variable name) |
| **subtree** | an `args` position whose surrounding op permits any Expression | Any AST subtree |

The legal sibling-field positions for **name**-class pattern variables are
enumerated per op and are fixed by this RFC:

| Op | name-class fields |
|---|---|
| `D` | `wrt` |
| `grad`, `div`, `laplacian` | `dim` (when present) |
| `bc` | `kind`, `side` |
| `index` | (none — all args are Expression) |
| `arrayop` | `idx` (each entry), `reduce.op` |
| `broadcast` | `fn` |
| `transpose` | (none — `perm` is a literal list) |
| `regrid` (new; §5.3) | `from`, `to` |

Guards (§5.2.4) may additionally constrain a pattern variable.

#### 5.2.2 Non-linear patterns

A pattern variable that appears in multiple positions within the same pattern
must bind to equal values at every occurrence. Equality is **AST-equal after
canonicalization** (§5.4). Two different pattern variables may bind to equal
values; the RFC imposes no anti-unification.

#### 5.2.3 Associative / commutative matching

**No AC matching.** A pattern `{op:"+", args:["$a", "$b"]}` matches a `+`
node with exactly two args; it does not match a three-arg sum, and it does
not match `b + a` (the match is positional). Authors who want to match an
n-ary sum use a canonical-form preprocessing pass (§5.4) or write multiple
rules.

This choice is load-bearing: it lets the pattern matcher be a bounded-depth
tree-equality check with pattern-variable bindings, which is reimplementable
in ~50 lines per binding. The cost — authors must write patterns in canonical
form — is paid once per scheme, not per model.

#### 5.2.4 Guard vocabulary

A guard object constrains a pattern variable. Guards are combined by AND.

| Guard | Example | Meaning |
|---|---|---|
| `dim_is_spatial_dim_of` | `{guard: "dim_is_spatial_dim_of", pvar: "$x", grid: "atmos_rect"}` | `$x` must name a spatial dimension of the given grid (renamed from v1 `var_is_spatial_dim_of` for consistency with m4) |
| `var_location_is` | `{guard: "var_location_is", pvar: "$u", location: "cell_center"}` | `$u` must carry the given staggered location (§11) |
| `var_has_grid` | `{guard: "var_has_grid", pvar: "$u", grid: "$g"}` | `$u` must be bound to grid `$g` |
| `dim_is_periodic` | `{guard: "dim_is_periodic", pvar: "$x", grid: "$g"}` | `$x`'s dimension has periodic BC under `$g` |
| `dim_is_nonuniform` | `{guard: "dim_is_nonuniform", pvar: "$x", grid: "$g"}` | `$x`'s `extents.$x.spacing` is `"nonuniform"` |
| `var_shape_rank` | `{guard: "var_shape_rank", pvar: "$u", rank: 2}` | Integer check on `$u.shape` |

New guards require a spec version bump. This keeps the pattern-matcher
trivially reimplementable in each binding (tree equality plus a dozen type
checks).

#### 5.2.5 Termination

The engine is a fixed-point loop over passes. Each pass walks every equation's
AST top-down; at each subtree, each rule is tried in `rules`-listing order;
the first match fires; after a rewrite, **the rewritten subtree is sealed
for the remainder of the current pass**: the walker does **not** descend
into the rewritten subtree's children, nor re-attempt any rule at the
rewritten node, until the next pass begins at the root (rule (i) in
review C5.5; option (a) in gt-adhm C5). This is normative: option (b)
(descend into the rewrite) and option (c) (skip to post-order sibling)
are both non-conforming. A new pass begins once the previous pass
completes; a pass that produces no rewrites terminates the loop.

A fresh pass walks the current AST from the root and may re-enter
subtrees that were rewritten in a prior pass; those subtrees are sealed
only within the pass that produced them, not across passes.

If the iteration count exceeds `max_passes = 32` without converging, the
engine must abort with error code `E_RULES_NOT_CONVERGED`. Authors may raise
the limit via a model-level `rules.max_passes` override; this is a spec-level
field, not a runtime flag. The default of 32 is chosen as roughly 2× the
depth of the deepest MVP-scheme chain (BC → ghost rewrite → canonicalize
→ fuse); authors whose rule sets chain deeper set the override explicitly.

**Rule ordering under `rules`.** `rules` is authored as a JSON map keyed by
rule name, but the iteration order is the **declaration order of the
keys** in the source `.esm` file. Loaders MUST preserve insertion order
when reading `rules`; bindings whose default JSON parsers do not preserve
object-key order must wrap `rules` in an order-preserving container at
load time. Authors who need portable ordering may alternatively write
`rules` as a JSON array of `{name, pattern, where, replacement, produces}`
objects; both forms are legal and a loader MUST accept both.

#### 5.2.6 Worked example (one-page)

**Rule:**

```json
{
  "grad_x_interior": {
    "pattern":     { "op": "grad", "args": ["$u"], "dim": "$x" },
    "where":       [ { "guard": "var_has_grid", "pvar": "$u", "grid": "atmos_rect" },
                     { "guard": "dim_is_spatial_dim_of", "pvar": "$x", "grid": "atmos_rect" } ],
    "use":         "centered_2nd_uniform",
    "region":      "interior"
  }
}
```

**Input tree (one equation RHS):**

```json
{ "op": "grad", "args": ["T"], "dim": "x" }
```

After matching (with `$u := "T"`, `$x := "x"`), the engine invokes the
`centered_2nd_uniform` scheme (§7) which expands at target index `[i, j, k]`
(provided implicitly by the enclosing `models.<M>.grid` binding, see §7.2) to:

```json
{ "op": "+",
  "args": [
    { "op": "*", "args": [
       { "op": "/", "args": [ -1, { "op": "*", "args": [ 2, "dx" ] } ] },
       { "op": "index", "args": [ "T", { "op": "-", "args": ["i", 1] }, "j", "k" ] } ] },
    { "op": "*", "args": [
       { "op": "/", "args": [  1, { "op": "*", "args": [ 2, "dx" ] } ] },
       { "op": "index", "args": [ "T", { "op": "+", "args": ["i", 1] }, "j", "k" ] } ] }
  ]
}
```

After canonicalization (§5.4), every binding emits the **byte-identical** JSON
above. This is the byte-for-byte reference any binding must meet.

#### 5.2.7 `region` (object form) and `where` (expression form) — per-query-point scoping (resolves esm-b1n)

Several BC and regional-physics rules need to apply only at a **subset**
of the grid — a boundary edge, a set of seam cells, a mask-field-defined
region, or an index range. v0.2's `region` string (advisory only) and
`where` array (rule-selection-time guards only) cannot express these
scopes. v0.3 adds **two optional normative forms** on the Rule object,
both of which scope rule application **per query point**:

- **`region` object form.** A structural scoping predicate. Discriminated
  by a `kind` tag:
  | `kind` | Required fields | Semantics |
  |---|---|---|
  | `"boundary"` | `side` (axis-side name; e.g. `"xmin"`, `"north"`) | Rule applies only at query points on the named boundary of the enclosing grid. |
  | `"mask_field"` | `field` (name) | Rule applies only at query points where the named field (a `data_loaders` entry or a boolean-typed variable) evaluates truthy. Indexed per query point. |
  | `"index_range"` | `axis`, `lo`, `hi` (int, inclusive) | Rule applies only where the named canonical index (`i`, `j`, `k`, …) lies in `[lo, hi]`. |

- **`where` expression form.** A per-point boolean predicate authored as
  an `ExpressionNode` over canonical index names (`i`, `j`, `k`), the
  `$target` components, and any pattern-variable bindings produced by
  `pattern`. Ops are drawn from §4's expression vocabulary — comparison,
  `and`/`or`/`not`, arithmetic, `index`. Rule fires at a given query
  point iff the expression evaluates to true there (non-zero / non-false).

**Shape discrimination.** Loaders discriminate the two `where` forms by
JSON type: an ARRAY is a guard list (§5.2.4 legacy semantics, applied
once per rule match); an OBJECT is an expression predicate (applied per
query point). Similarly, `region` as a STRING is the legacy advisory
tag; `region` as an OBJECT is the new normative scope. Mixing is legal:
a rule may carry guards (array `where`), a structural scope (object
`region`), and a fine-grained predicate (the expression form of `where`
is authored under a separate field; see below).

**`where` overloading — authoring cost.** Because `where: [...]` and
`where: {...}` are structurally distinct but share the same field name,
a rule MUST NOT author both a guard list AND an expression predicate in
the same `where`. When a rule needs both, the guard list remains in
`where` and the expression predicate moves into `region.kind = "boundary"`
or a synthetic `mask_field` — or, equivalently, the author gates rule
firing with both a guard and a predicate by writing TWO rules.

**Fall-through.** A rule whose `region` / `where`-point predicate
evaluates false at the current query point does NOT fire at that
point; the engine falls through to the **next** matching rule in
declaration order (§5.2.5). Fall-through preserves the v0.2
rule-ordering contract: a region-scoped rule listed first can
shadow a general rule listed second only at points inside its
scope.

**Evaluation timing (normative).** Predicate evaluation is a
**rewrite-time** concern, not a load-time or a run-time concern.
Specifically:

1. When a rule's `pattern` matches an AST subtree and its
   `where`-array guards pass, the engine enters the scope-check
   step.
2. The engine determines the **query point** for the match. For
   rules firing inside an equation parameterized by `$target`
   (cartesian: `[i, j, k, …]`; unstructured: `c` / `e` / `v`),
   the query point is `$target`. For
   rules firing outside a `$target` context (coupling-rule rewrites,
   top-level expressions), the engine MUST emit
   `E_SCOPE_OUTSIDE_TARGET` rather than silently widen scope.
3. If `region` is absent or a string → scope check passes.
4. If `region` is an object → evaluate the per-kind predicate against
   the query point; pass iff the predicate is true.
5. If `where` is an expression → evaluate against the query point
   with pattern-variable bindings in scope; pass iff the expression
   canonicalizes to a truthy constant (non-zero integer / float,
   non-empty string, or `true`).
6. If steps 4–5 pass, the rule fires as usual. Otherwise the engine
   falls through.

**Partial binding support.** Bindings that do not yet implement a
per-point evaluator MUST still **parse** both forms (load-time round-
trip), and MUST treat any rule carrying an object `region` or an
expression `where` as **disabled** (conservative fall-through) until
the evaluator lands. A load-time warning `W_UNEVAL_SCOPE` is
recommended so authors know their rule is inert in that binding.

**Conformance rollout.** The MVP for v0.3 requires Julia and Rust
to evaluate `region.boundary`, `region.index_range`,
`region.mask_field`, and the expression form of `where`.

**`region.mask_field` integration.** Bindings resolve a mask-field
scope by consulting a per-rewrite-context `mask_fields` table
(`Julia: RuleContext.mask_fields`, `Rust: RuleContext::mask_fields`):
each entry is a per-name list of truthy query-point coordinates. A
mask entry matches the current query point iff every (axis, value)
it declares agrees with the query point; axes the mask entry does
not declare are ignored, so a lower-dimensional surface mask can
scope rules on a higher-dimensional grid. The `field` name resolves
to either a `data_loaders` entry (materialized at rewrite time by
the caller) or to a boolean-typed variable — the evaluator is
agnostic to the upstream source; only the populated
`ctx.mask_fields[field]` is consulted. When the field is absent
from `ctx.mask_fields`, the rule falls through (same
W_UNEVAL_SCOPE handling as any unimplemented scope).

#### 5.2.8 `boundary_policy`, `ghost_width`, and `bindings` (new in v0.3.x; resolves esm-m5s, esm-bet)

Three additive optional fields on the Rule object (§5.2 schema, §7.2 expansion)
extend rules to flux-form transport schemes whose stencil semantics depend on
the rule's edge behavior and whose coefficients reference time-varying state
that is not authored as a model variable.

##### `boundary_policy`

Declares what the rule expects to happen when the matched pattern's stencil
reaches a domain edge. Two authorial forms are accepted:

**String form (axis-uniform).** A string drawn from the closed set
`{"periodic", "ghosted", "neumann_zero", "extrapolate", "reflecting",
"one_sided_extrapolation", "prescribed"}`, applied uniformly to every axis the
rule's stencil reaches.

**Object form (per-axis).** An object `{"by_axis": {<axis>: BoundaryPolicySpec, ...}}`
where each `BoundaryPolicySpec` is a `{kind, ...}` object. The per-axis form is
required for rules whose axes need different policies (e.g. periodic in
longitude, reflecting in vertical).

The closed set of policy kinds (string values and `BoundaryPolicySpec.kind`):

| Kind | Semantics at edge query points |
|---|---|
| `periodic` (default when omitted) | Wrap-around indexing on every spatial dimension. Equivalent to v0.2/v0.3 implicit behavior. Suitable for periodic Cartesian grids and for rules that emit `index` expressions that wrap around dimension extent. |
| `reflecting` | At the edge, the rule's stencil is mirrored across the domain edge so that any out-of-range `index` reads its in-range image. Suitable for closed walls / symmetry boundaries. |
| `one_sided_extrapolation` | The runtime fills ghost values by extrapolating from the interior. Carries an optional `degree` parameter (`0` constant, `1` linear (default), `2` quadratic, `3` cubic). |
| `prescribed` | The caller supplies ghost values in the input array; the runtime treats the input as already-extended and the rule fires unmodified at the edge. Used for hand-set Dirichlet, externally-driven BCs, and runtimes whose upstream BC pass already filled ghost cells. |
| `ghosted` | v0.3.x alias for `prescribed` — retained for backwards compatibility with rules authored before v0.3.x. New rules SHOULD use `prescribed`. |
| `neumann_zero` | v0.3.x alias for `reflecting` — retained for backwards compatibility. New rules SHOULD use `reflecting`. |
| `extrapolate` | v0.3.x alias for `one_sided_extrapolation` (defaulting to `degree: 1` when omitted). |

The field is **declarative**. The rule engine itself (§5.2 pattern matcher,
§7.2 expander) does not branch on `boundary_policy`; downstream pipeline
phases (BC pass §9, ghost-cell synthesis, edge-rule fall-through) consult
it. A binding that does not yet implement a
non-`periodic` kind MUST preserve the field through parse/serialize
roundtrips and MAY emit `W_UNEVAL_BOUNDARY_POLICY` at the first
non-`periodic` policy it encounters at rewrite time.

Omission is equivalent to the string form `"periodic"`, which is in turn
equivalent to `{by_axis: {<every-axis>: {kind: "periodic"}}}`. This
preserves the v0.2/v0.3 implicit contract on Cartesian periodic grids.

##### `ghost_width`

Declares the per-axis ghost-cell padding the rule's stencil reaches outside
the in-bounds region. The runtime preparing inputs to the rule SHALL extend
each axis's input array by at least `ghost_width[axis]` cells on each side,
using the rule's declared `boundary_policy` for that axis to fill the
extension.

Two authorial forms are accepted:

**Scalar form (axis-uniform).** A non-negative integer applied to every axis
the rule's stencil reaches. Example: `"ghost_width": 3` requests three ghost
cells per side on every axis.

**Object form (per-axis).** `{"by_axis": {<axis>: <int>, ...}}` declaring
the width independently per axis. Example:

```json
"ghost_width": {
  "by_axis": {"xi": 3, "eta": 3}
}
```

Omission is equivalent to `0` — the rule reads only in-bounds indices and
needs no input extension. The field is metadata; bindings preserve it across
roundtrips. Loaders that do not yet implement input extension MAY emit
`W_UNEVAL_GHOST_WIDTH` at the first non-zero `ghost_width` they encounter.

##### `bindings`

A JSON object mapping bare identifier names (e.g. `"dt"`, `"dx"`,
`"velocity"`, `"cos_lat"`) to a `RuleBinding` object. Declares the
non-pattern-variable, non-canonical-index symbols that the rule's
`replacement` AST may reference at runtime, together with the rate at which
the runtime updates each binding's value:

| `kind` | Cadence | Examples |
|---|---|---|
| `static` | Constant for the lifetime of the simulation | `R` (Earth radius), `dlon` (constant grid spacing), `cos_lat` (1D table indexed by latitude band) |
| `per_step` | May change once per time-step | `dt` (adaptive timestep), `max_velocity` (CFL-bounding) |
| `per_cell` | Varies per grid cell at runtime | `velocity[i]` (advected wind), `dx[i]` (nonuniform grid spacing) |

A binding entry MAY carry a `default` ExpressionNode (a literal or any §4
expression). For `static` bindings, the default is the value used when the
runtime supplies no override; for `per_step` and `per_cell` bindings it is
an authorial fallback the runtime is free to ignore.

Pattern variables (`$`-prefixed) and canonical grid indices (`i`, `j`, `k`,
`l`, `m` for cartesian; `c`, `e`, `v` for unstructured; etc.) are NOT
declared here. Pattern variables flow from `pattern`; canonical indices are
in scope by virtue of the model's grid binding (§7.2).

The field is metadata: the rule engine does not consult it during pattern
matching or expansion. Loaders MUST preserve it across roundtrips. The
contract is between the rule author and the host runtime that supplies
binding values during simulation. Conformance fixtures may exercise the
parse/serialize path; runtime-evaluation conformance is a binding-specific
concern outside RFC §11's deterministic pipeline scope.

##### Worked example — CFL-bounded 1D upwind advection

```json
{
  "name": "upwind_advect_x",
  "pattern": { "op": "grad", "args": ["$u"], "dim": "$x" },
  "where": [ { "guard": "var_has_grid", "pvar": "$u", "grid": "atmos1d" } ],
  "boundary_policy": "periodic",
  "bindings": {
    "dt":       { "kind": "per_step", "description": "Adaptive timestep, set from CFL <= 0.5." },
    "velocity": { "kind": "per_cell", "description": "Advected wind speed, cell-centered." },
    "dx":       { "kind": "static",   "default": 0.1 }
  },
  "replacement": {
    "op": "/",
    "args": [
      { "op": "*", "args": [
        "velocity",
        { "op": "-", "args": [
          "$u",
          { "op": "index", "args": ["$u", { "op": "-", "args": ["$x", 1] }] }
        ]}
      ]},
      "dx"
    ]
  }
}
```

The rule's replacement references `velocity` (per-cell) and `dx` (static)
without further qualification; the binding contract tells the runtime
which are time-varying. `boundary_policy: "periodic"` is explicit here
even though it is the default — explicitness is recommended for any rule
intended to port to non-periodic grids.

### 5.3 `regrid` op (new)

```json
{ "op": "regrid", "args": [<expr>], "from": "<grid>", "to": "<grid>", "method": "<name>" }
```

Required whenever a rewritten expression crosses grids — for example, when
`coupling.<c>` maps a variable from grid A to grid B and a downstream rule
re-indexes it on grid B. Without a `regrid` wrapper, the result is ill-formed.
This resolves review question Q6 (coupling ∘ rewrite interaction): rewrite
runs post-coupling (§11 pipeline), and cross-grid index expressions must be
wrapped in `regrid`.

`method` names a regridding algorithm; the v0.2.0 spec defines a **closed
set** of legal method names with normative semantics (resolves gt-adhm
M1 / gt-j6do open question 3). Any binding emitting a `regrid` node on
the canonical wire MUST use one of these names; bindings parsing a
`regrid` node MUST reject an unknown `method` at load time with error
code `E_UNKNOWN_REGRID_METHOD`.

| `method` | Semantics (normative) |
|---|---|
| `"nearest"` | Nearest-neighbor in the target's index space. Ties broken by lexicographic comparison of source indices. No interpolation; no extrapolation. |
| `"bilinear"` | Bilinear interpolation over the four surrounding source cells when both source and target are structured; extended to simplex-barycentric on unstructured source meshes. Outside the source convex hull, extrapolation is NOT performed; the result is undefined and bindings MUST either clip to boundary or error (`E_REGRID_OUTSIDE_HULL`). |
| `"conservative"` | First-order area-weighted conservative remap (preserves integral of the source field over the target cell). Implementations MUST match the reference area-overlap formulation; higher-order conservative schemes require a spec-version bump. |

`"custom"` and any other author-supplied method name are **out of MVP**
and MUST be rejected. Adding a new method name is a minor version bump
(0.2.x).

**Where `method` comes from at rewrite time (resolves gt-adhm M1).** A
`regrid` node emitted by scheme expansion (§7.2) carries a method
supplied by the **selector**, not by the author at rule-write time.
Specifically:

- `cartesian`, `indirect`, and `reduction` selectors do NOT emit
  `regrid` wrappers on their own — they address the same grid.
- When a **coupling** resolves to a cross-grid reference (§11 step 4),
  the `coupling.<c>` entry MUST declare `coupling.<c>.regrid_method`
  (one of the four names above); the resolver copies that method into
  any `regrid` wrapper it emits. This field is new; see §10.1 below
  for the minor schema addition.
- Authors writing a `regrid` node literally in a `.esm` expression MUST
  supply a `method` from the closed set; the loader validates at parse
  time.

This ties `method` determinism to the emitter (selector or coupling
resolver), so bit-identity across bindings holds whenever both
bindings read the same `.esm` file.

### 5.4 Canonical AST form (normative, new; resolves C3)

Every binding must apply the following canonicalization to every AST subtree
produced by the rule engine (and to every `.esm` expression at load time
when the file declares `spec.canonical_form_applied: true`). Two ASTs are
equal iff their canonical forms are JSON-equal.

#### 5.4.1 Integer / float promotion

An integer literal and a float literal are distinct AST nodes. Canonical form
**never auto-promotes**: `{op:"+", args:[1, 2.0]}` does not canonicalize to
`3.0`. Promotion happens only in `evaluate`, not in `simplify`/canonicalize.
The distinction is preserved through the on-wire form by §5.4.6's trailing-`.0`
override for integer-valued floats and its disambiguating parse rule.

#### 5.4.2 Commutative-op ordering

For `+` and `*`, the args list is sorted by the following total order, applied
lexicographically:

1. Numeric literals first, sorted ascending by numeric value (integer before
   float at equal magnitude).
2. Bare string references, sorted lexicographically (Unicode codepoint).
3. Non-leaf nodes, sorted by a stable serialization: recursively canonicalize,
   then compare their JSON serializations as byte strings (UTF-8, sorted keys,
   no extraneous whitespace).

The output argument list is stable, total, and deterministic.

#### 5.4.3 N-ary flattening

For `+` and `*`, nested same-op children are flattened: `+(+(a,b), c)` →
`+(a,b,c)`. Applied before §5.4.2 ordering.

#### 5.4.4 Zero / identity elimination

- `+(0, x, ...)` → `+(x, ...)`. Zero-elimination iterates until no numeric
  zero child remains; integer `0` and float `0.0` both qualify as
  eliminable zeros, and both are removed in the same pass (addresses
  gt-adhm m3). If only `0` remains, replace with `0`.
- `+()` → `0`. `+(x)` → `x`.
- `*(1, x, ...)` → `*(x, ...)`. Similar singleton rules.
- `*(0, ...)` → `0` (zero annihilates).
- `/(x, 1)` → `x`. `-(0)` → `0`. `-(x, 0)` → `x`.

**Type-preserving identity elimination (fixes gt-j6do New C1(c)).** Identity
elimination `*(1, x, ...) → *(x, ...)` and `+(0, x, ...) → +(x, ...)`
applies **only when the eliminated operand and the surviving operand(s)
have the same numeric type class** (both integer, or both float, or the
eliminated operand is of the same class as all surviving numeric
literals). If types differ — e.g. `*(1.0, x)` where `x` is a bare integer
variable reference — the identity is **not** eliminated; the canonical
form retains `*(1.0, x)`. This preserves the information that evaluation
will promote to float. Rationale: dropping a typed identity erases
type information that `evaluate` must honor (§5.4.1's non-promotion
rule is about literal-to-literal arithmetic; cross-type identity
elimination would effectively demote the type and is forbidden).

Zero-annihilation `*(0, ...) → 0` **preserves the numeric type of the
zero**: `*(0.0, x) → 0.0`, `*(0, x) → 0`. Signed zero is preserved:
`*(-0.0, x) → -0.0` (see §5.4.6 for NaN/Inf/signed-zero handling).

#### 5.4.5 String-vs-number in variable references

A bare variable reference is always a string. Numeric literals are always
JSON numbers. A name that happens to be all digits (`"0"` as a variable)
requires the authoring tool to quote it unambiguously; the canonicalizer
does not disambiguate.

#### 5.4.6 Normative JSON number formatting (resolves gt-j6do New C1 / gt-adhm C1 / gt-h9kt)

Without a pinned textual form for numeric literals, the byte-comparison
strategy of §5.4.2 and §13's bit-identity claim are infeasible: Julia
`JSON3`, Rust `serde_json`, Python `json`, Go `encoding/json`, and
TypeScript `JSON.stringify` all produce divergent representations of
the same `Float64`. This subsection pins the canonical number format
normatively. All bindings MUST emit numeric literals in canonical form
when producing a canonical AST; bindings MUST parse according to the
disambiguating rule below (**strict parse, strict emit** — see
"Round-trip invariant").

**Baseline: RFC 8785 JCS number format, with one normative override.**
Adopt RFC 8785 (JSON Canonicalization Scheme) §3.2.2.3
number-serialization as the normative float-formatting rule:
<https://datatracker.ietf.org/doc/html/rfc8785#section-3.2.2.3>.
JCS references ECMAScript 2019 §7.1.12.1 `ToString(Number)`, which is
the shortest-round-trip decimal string that round-trips bit-identically
to the source IEEE-754 double.

This RFC **overrides** JCS §3.2.2.3 in exactly one place: an
integer-valued float whose JCS form would be bare-integer-looking
(no `.`, no `e`/`E`) receives a trailing `.0` so that on-wire integers
and floats are never spelled the same way. All other JCS output is
adopted verbatim. Rationale: under pure JCS, a float node holding `1.0`
and an integer node holding `1` both serialize to the string `1`. On
parse-back, §5.4.1's mandated integer/float node distinction is
unrecoverable — the canonical round-trip invariant is broken. The `.0`
suffix is the minimum-diff override: it keeps JCS's shortest-round-trip
rule for every other float value and adds a single unambiguous token
for the integer-valued case.

Additional rules specific to this RFC:

- **Integer literals** are emitted as a JSON integer (no `.`, no `e`):
  `42`, `-1`, `0`. The canonical form never produces `42.0` for an
  integer-typed node.
- **Float literals that are integer-valued** (e.g. `1.0`, `-3.0`,
  `0.0`) are emitted with a trailing `.0` when the JCS form would
  otherwise be bare-integer-looking: float `1.0` → **`1.0`**,
  float `-3.0` → **`-3.0`**, float `0.0` → **`0.0`**. This applies
  for every integer-valued magnitude in the plain-decimal range
  `[−(1e21 − 1), 1e21 − 1]`. Integer-valued magnitudes that fall in
  the exponent range (`|x| ≥ 1e21`) are emitted with exponent notation
  by JCS (`1e21`, `1e25`, `-5e300`); the `e` already distinguishes
  them from a JSON integer, so no `.0` suffix is added. The AST node
  kind remains `float` in both cases.
- **Shortest round-trip for non-integer floats.** The shortest decimal
  string that parses back to the exact IEEE-754 double. For example,
  `0.1 + 0.2` (which rounds to `0.30000000000000004`) canonicalizes to
  the 17-digit form `0.30000000000000004`, not `0.3`. This matches
  Rust `ryu`, Go `strconv.FormatFloat(f, 'g', -1, 64)`, and Python
  `repr(float)` on 3.1+. The shortest form already contains `.`, so
  no override is needed.
- **Exponent form.** For magnitudes `|x| < 1e-6` or `|x| ≥ 1e21`, use
  exponent notation with lowercase `e` and no leading `+` on the
  exponent: `1e-7`, `3.14e25`, `-5e-300`. For magnitudes inside
  `[1e-6, 1e21)`, use plain decimal notation. These breakpoints match
  ECMAScript `ToString(Number)` (and thus JCS). The `e` in exponent
  form unambiguously marks the token as a float (JSON integers cannot
  contain `e`), so no `.0` suffix is added — `1e25` is a valid
  canonical float emission.
- **Zero.** Positive zero is `0` (integer node) or **`0.0`** (float
  node). Negative zero `-0.0` in a float node is spelled **`-0.0`**
  on the wire. Integer nodes cannot hold negative zero; a leading `-`
  before an integer literal `0` is non-conforming.
- **Subnormals.** IEEE-754 subnormals (`|x| < 2^-1022` for double) are
  serialized by the same shortest-round-trip rule; all shortest-round-trip
  algorithms (Grisu3, Ryu, Dragon4) produce identical output for
  subnormals. Example: the smallest positive subnormal `5e-324`
  canonicalizes to `5e-324` (exponent form, unambiguously float).
  Subnormals are **valid** in canonical form.
- **NaN and Infinity are NOT representable in canonical form.** Any
  canonicalization pass that encounters a NaN or ±Inf literal MUST
  abort with error code `E_CANONICAL_NONFINITE` and the path to the
  offending node. Rationale: JSON does not represent NaN/Inf; each
  binding's encoder produces a different non-JSON spelling (`null`,
  `"NaN"`, `"Infinity"`, `{"op":"special", ...}`, …); no canonical
  form is possible without inventing a new AST node, which is out of
  scope for 0.2.0. Authors who need NaN/Inf as sentinel values MUST
  represent them explicitly (e.g. as a parameter with a binding-side
  resolution); canonical ASTs are finite.

**Round-trip invariant (normative parse rule).** Because the on-wire
emitter is disambiguating, the parser MUST be disambiguating too. For
any canonical-form JSON number token `T`:

- If `T` contains a `.` **or** an `e`/`E`, it parses to a **float node**.
- Otherwise (`T` matches the JSON-integer grammar `-?(0|[1-9][0-9]*)`),
  it parses to an **integer node**.

This is a strict parse, not lenient: a canonicalizer that accepts `1`
as a float is non-conforming (it would break the round-trip). Bindings
that ingest non-canonical JSON (e.g. author input with mixed
conventions) MUST canonicalize before admitting the document as a
valid ESM AST; the canonicalization pass is the trust boundary. The
result: `canonicalize(parse(emit(A))) == A` as a byte-for-byte JSON
equality on the on-wire form, for every canonical AST `A`. This is
the invariant §5.4's opening paragraph requires.

**Worked example — the disambiguation in action:**

Input A (float node `1.0` + float node `2.5`):
`{"op":"+","args":[{"kind":"float","value":1.0},{"kind":"float","value":2.5}]}`

Input B (integer node `1` + float node `2.5`):
`{"op":"+","args":[{"kind":"int","value":1},{"kind":"float","value":2.5}]}`

Canonical on-wire forms (using the compact primitive-literal encoding
where a bare JSON number denotes the literal node and the node kind is
recovered from the token's shape per the round-trip parse rule):

- A → `{"op":"+","args":[1.0,2.5]}`
- B → `{"op":"+","args":[1,2.5]}`

Pure JCS (pre-override) would have emitted both as
`{"op":"+","args":[1,2.5]}`, destroying the §5.4.1 distinction. With
the override, A and B produce distinct on-wire forms, and re-parsing
each yields back the original integer-vs-float node kind.

**Inline round-trip fixture.** The following table is normative — every
binding MUST reproduce these emissions for the given AST leaf and, on
parse-back, MUST recover the indicated node kind. (A binding fixture
under `tests/fixtures/canonical_numbers/` materializes this table as a
conformance test when §13.1 Step 1 lands.)

| AST node kind | Value                     | Canonical on-wire | Parse-back kind |
|---------------|---------------------------|-------------------|-----------------|
| integer       | 1                         | `1`               | integer         |
| integer       | -42                       | `-42`             | integer         |
| integer       | 0                         | `0`               | integer         |
| float         | 1.0                       | `1.0`             | float           |
| float         | -3.0                      | `-3.0`            | float           |
| float         | 0.0                       | `0.0`             | float           |
| float         | -0.0                      | `-0.0`            | float           |
| float         | 2.5                       | `2.5`             | float           |
| float         | 0.30000000000000004       | `0.30000000000000004` | float       |
| float         | 1e25                      | `1e25`            | float           |
| float         | 5e-324 (subnormal)        | `5e-324`          | float           |

A binding that emits `3.14159E-10` (capital E), `+3.14159e-10` (leading
`+`), `1` for a float-valued `1.0`, or `1.0` for an integer `1` is
non-conforming.

**Spec preservation of integer/float distinction.** §5.4.1 says integer
and float literals are distinct AST nodes. This subsection confirms
the distinction survives canonicalization **and** round-trips through
the on-wire form: the integer node with value `1` emits as `1` and
re-parses as an integer node; the float node with value `1.0` emits
as `1.0` and re-parses as a float node. Canonical-form equality
compares node kind first, value second; neither side of an
integer/float pair can be substituted for the other without changing
the canonical serialization.

#### 5.4.7 Canonicalization for `-`, `/`, unary `neg` (resolves gt-adhm M6)

§5.4.2 and §5.4.3 specify ordering and flattening for `+` and `*` only.
This subsection pins the canonical form for the remaining arithmetic
ops.

**Binary `-`.** `{op:"-", args:[a, b]}` is **kept as a distinct op**;
it is NOT rewritten to `+(a, *(-1, b))`. `-` is non-commutative: the
canonicalizer preserves argument order (`args[0]` is the minuend,
`args[1]` is the subtrahend). Nested same-op `-` is NOT flattened:
`-(a, -(b, c))` canonicalizes to `-(canonicalize(a), -(canonicalize(b),
canonicalize(c)))`, not to `+(a, -b, c)`. Identity rules: `-(x, 0)` →
`x`, `-(0, 0)` → `0`. `-(x, x)` is NOT simplified to `0` (that is an
algebraic rewrite, not a canonical-form operation; see §5.4 closing
paragraph).

**Unary `-` (unary negation, `neg`).** The spec permits both a dedicated
`{op:"neg", args:[x]}` node and a binary `-` applied with a literal
zero minuend (`{op:"-", args:[0, x]}`). The canonical form picks **the
dedicated `neg` node** when the operand is not itself a literal: any
`{op:"-", args:[0, x]}` canonicalizes to `{op:"neg", args:[x]}`. A
numeric literal that happens to be negative is kept as the literal
itself (no `neg` wrapper around numerics): `{op:"neg", args:[5]}`
canonicalizes to `-5` (a literal integer or float node with negative
value). Identity rules: `neg(0) → 0`, `neg(0.0) → 0.0`,
`neg(neg(x)) → x`.

**Binary `/`.** `{op:"/", args:[a, b]}` is **kept as a distinct op**;
it is NOT rewritten to `*(a, inv(b))` (no `inv` node exists in the
MVP). `/` is non-commutative: argument order is preserved (numerator,
denominator). Nested same-op `/` is NOT flattened: `/(/(a, b), c)`
stays as-is. Identity rules: `/(x, 1)` → `x`, `/(0, x)` → `0` (only
when `x` is not itself `0`; `/(0, 0)` is undefined — the canonicalizer
emits `E_CANONICAL_DIVBY_ZERO` and aborts). `/(x, x)` is NOT simplified
to `1`.

**No new AST ops.** `neg` is already permitted by the base spec's op
taxonomy; this subsection pins its role. No new node types are
introduced. Bindings that internally represent unary minus as a binary
`-` with implicit `0` minuend MUST serialize as `{op:"neg", args:[x]}`
on the canonical wire.

#### 5.4.8 Worked example

Input: `{op:"+", args:[{op:"*", args:["a", 0]}, "b", {op:"+", args:["a", 1]}]}`

1. Flatten: outer `+` has an inner `+`: `{op:"+", args:[{op:"*",
   args:["a", 0]}, "b", "a", 1]}`.
2. Eliminate: `*(a, 0)` → `0`: `{op:"+", args:[0, "b", "a", 1]}`.
3. Order: numerics first (`0, 1`), then strings (`"a", "b"`): `{op:"+",
   args:[0, 1, "a", "b"]}`.
4. Eliminate: `+(0, ...)` → remove 0: `{op:"+", args:[1, "a", "b"]}`.

Every binding must produce exactly this output. The conformance harness
compares post-canonicalization JSON byte-wise (keys sorted, no optional
whitespace). Algebraic equivalence beyond this list (e.g. distributivity,
factoring, `-(x,x)→0`, `/(x,x)→1`) is **not** part of canonical form.

#### 5.4.9 Implementation note — memoize serialization during comparator (gt-adhm m1)

§5.4.2's comparator recursively canonicalizes and JSON-serializes each
operand to compare as byte strings. A naive implementation re-serializes
at each comparator call, giving O(N² log N) in total AST size. Bindings
SHOULD memoize the canonical JSON serialization at each canonicalized
node so each subtree is serialized at most once per sort. This is an
implementation note, not a conformance requirement — any implementation
whose output matches the canonical form is conforming regardless of
complexity.

### 5.5 No other new calculus ops

`D`, `grad`, `div`, `laplacian` already exist. Beyond `regrid` (§5.3), no
additional continuous-math ops are introduced. Ghost-cell addressing and
boundary regions are expressed through `index` plus rule replacements; no new
op for "boundary region" is defined in the MVP slice.

## 6. Schema — `grids`

### 6.1 Top-level

```json
{
  "grids": {
    "atmos_rect":   { "family": "cartesian",     ... },
    "mpas_cvmesh":  { "family": "unstructured",  ... }
  }
}
```

Each key is a grid name; the value is an object whose `family` field selects
one of the schemas below. All grids support the following common fields:

| Field | Required | Description |
|---|---|---|
| `family` | ✓ | `"cartesian"` or `"unstructured"` |
| `crs` | | Coordinate reference system, **orthogonal to `family`** (see §6.1.1) |
| `dimensions` | ✓ | Ordered list of logical dimension names |
| `locations` | | Declared stagger locations (see §11) |
| `metric_arrays` | | Declarations of metric arrays (see §6.5) |
| `parameters` | | Ordinary ESM parameter entries (see §6.6) |
| `domain` | | Name of the `domains` entry this grid refines (optional) |

The `parameters` block **reuses** the existing ESM `parameters` schema (§6.2
of the spec) verbatim. Grid-level parameters are visible to `substitute`,
`free_variables`, and the conformance harness without any new machinery.

#### 6.1.1 Coordinate reference system — `crs`

`crs` is an **optional** descriptor recording the grid's coordinate reference
system. It is **orthogonal to `family`** (RFC pure-io-data-loaders §4.2): the
topological `family` (`cartesian` / `unstructured`) says how cells connect,
while `crs` says what projection the cell coordinates live in. A geographic
lat-lon grid and a Lambert-Conformal grid can share `family: "cartesian"` and
differ only in `crs`; a point-station dataset can be `unstructured` +
`longlat`. Grids without a `crs` are unchanged.

```json
"crs": {
  "projection": "lambert_conformal",
  "datum": "sphere",
  "R": 6370000.0,
  "parameters": { "lat_1": 30.0, "lat_2": 60.0, "lat_0": 38.999996, "lon_0": -97.0 }
}
```

| Field | Required | Description |
|---|---|---|
| `projection` | ✓ | One of `longlat`, `lambert_conformal`, `mercator`, `polar_stereographic`, `rotated_pole`. `longlat` is the geographic identity case (no projection). |
| `datum` | | `"sphere"` (a spherical Earth of radius `R`) or `"WGS84"`. |
| `R` | | Sphere radius in metres. **Required when `datum` is `"sphere"`** (e.g. WRF `6370000`, NEI2016 `6370997`). |
| `parameters` | | Projection parameters consumed verbatim by a downstream reprojection rule (e.g. Lambert Conformal `{lat_1, lat_2, lat_0, lon_0}`). Absent or empty for `longlat`. |

The grid itself performs **no** reprojection — `crs` only *names* the projection
and its parameters so a downstream consumer (an ESD `reprojection/` rule) can
transform native coordinates to a common CRS. The descriptor that *names* the
projection and the rule that *evaluates* it therefore share one parameter set.

**Interaction with `domains.<d>.spatial.<dim>.grid_spacing`** (review m1):
if a grid names a domain, any `grid_spacing` the domain declares is advisory
only. The grid's `extents.<dim>.spacing` wins; authors may set
`spatial.<dim>.grid_spacing` to the same value for documentation, but the
loader does not cross-check. (Future work: deprecate the domain-level field.)

### 6.2 Family: `cartesian`

```json
{
  "family": "cartesian",
  "dimensions": ["x", "y", "z"],
  "extents": {
    "x": { "n": "Nx", "spacing": "uniform" },
    "y": { "n": "Ny", "spacing": "uniform" },
    "z": { "n": "Nz", "spacing": "nonuniform" }
  },
  "locations": ["cell_center", "x_face", "y_face", "z_face"],
  "metric_arrays": {
    "dx": { "rank": 0, "generator": { "kind": "expression",
             "expr": { "op": "/", "args": [ { "op": "-", "args": ["x_max", "x_min"] }, "Nx" ] } } },
    "dz": { "rank": 1, "dim": "z", "generator": { "kind": "loader", "loader": "zlev_csv", "field": "dz" } }
  },
  "parameters": {
    "Nx": { "value": 64 }, "Ny": { "value": 64 }, "Nz": { "value": 32 },
    "x_min": { "value": 0.0 }, "x_max": { "value": 1.0 }
  }
}
```

- `extents[<dim>].n` — expression referencing a parameter giving the count
  along that dimension.
- `extents[<dim>].spacing` — `"uniform"` lets rules reference `dx` as a
  rank-0 scalar; `"nonuniform"` **requires** the metric array to have
  `rank: 1` with `dim: "<x>"`. The engine auto-rewrites scalar references
  to `index`ed references when `spacing = "nonuniform"` (§6.2.1 below;
  resolves M1 per option (b)).

#### 6.2.1 Scalar → indexed metric rewrite

When a scheme's `coeff` expression contains a bare string reference `"dx"`
(or any other metric-array name) and the enclosing rule's operand axis `$x`
binds to a dimension whose `extents.$x.spacing = "nonuniform"`, the engine
rewrites the reference to `{op:"index", args:["dx", <target-index-for-$x>]}`
during scheme expansion (§7.2), *before* canonicalization.

Lookup rule: the target index for axis `$x` is the expansion target's index
for that axis (i.e., `i` for a cartesian scheme whose stencil offsets along
`x` from target `[i, j, k]`; neighbor offsets are applied separately to the
operand variable, not to the metric).

This is a pure AST transform; it preserves bit-identity because all bindings
apply the same rewrite rule at the same point in the pipeline.

### 6.3 Family: `unstructured`

```json
{
  "family": "unstructured",
  "dimensions": ["cell", "edge", "vertex"],
  "locations": ["cell_center", "edge_normal", "vertex"],
  "connectivity": {
    "cellsOnEdge":   { "shape": ["nEdges", 2],    "rank": 2, "loader": "mpas_mesh", "field": "cellsOnEdge" },
    "edgesOnCell":   { "shape": ["nCells", "maxEdges"], "rank": 2, "loader": "mpas_mesh", "field": "edgesOnCell" },
    "verticesOnEdge":{ "shape": ["nEdges", 2],    "rank": 2, "loader": "mpas_mesh", "field": "verticesOnEdge" },
    "nEdgesOnCell":  { "shape": ["nCells"],       "rank": 1, "loader": "mpas_mesh", "field": "nEdgesOnCell" }
  },
  "metric_arrays": {
    "dcEdge":  { "rank": 1, "dim": "edge", "generator": { "kind": "loader", "loader": "mpas_mesh", "field": "dcEdge" } },
    "dvEdge":  { "rank": 1, "dim": "edge", "generator": { "kind": "loader", "loader": "mpas_mesh", "field": "dvEdge" } },
    "areaCell":{ "rank": 1, "dim": "cell", "generator": { "kind": "loader", "loader": "mpas_mesh", "field": "areaCell" } }
  },
  "parameters": {
    "nCells": { "value": "from_loader" },
    "nEdges": { "value": "from_loader" },
    "maxEdges": { "value": "from_loader" }
  }
}
```

`connectivity[<name>]` declares an integer table addressable by rules. Rules
that use the `indirect` or `reduction` selector name one of these tables in
`selector.table`.

The `{loader, field}` pair references an entry of the top-level
`data_loaders` section; see §8 for the mesh-loader extension this RFC adds.

### 6.5 Metric-array generators

A metric array's contents come from exactly one of:

| Kind | Fields | Semantics |
|---|---|---|
| `expression` | `expr` | An ordinary ESM expression; all free variables must be grid `parameters` or (for analytic grids) dimension indices. Computed at discretization time, cached per-session within the rewriting binding. |
| `loader` | `loader`, `field` | Names an entry in the top-level `data_loaders` map, and a named field produced by that loader. Grid JSON never contains bulk values. See §8 for the loader-extension this RFC adds. |
| `builtin` | `name` | Names a built-in, canonical generator from a closed list. Used for mathematical tables (standard connectivity) whose definition is textual rather than file-resident. |

Per design decision, analytic grids use `expression`; irregular grids (MPAS)
use `loader`. This matches existing loader semantics and keeps `.esm` files
diff-friendly.

### 6.6 Parameter flow

Grid generator parameters are ordinary ESM parameters. A rectangular grid
with `Nx` cells exposes `Nx` exactly like any other scalar parameter: it
appears in `free_variables`, participates in `substitute`, and the
conformance harness validates its presence via the existing schema.

Grid-level parameters with `value: "from_loader"` are resolved at load time
by reading the metadata of the referenced loader; this is a loader-side
obligation specified in §8 below.

## 7. Schema — `discretizations`

A discretization is a named stencil template. Each template maps an operator
class to a combination (sum, product, min/max reduction) over neighbors with
symbolic coefficients.

```json
{
  "discretizations": {
    "centered_2nd_uniform": {
      "applies_to": { "op": "grad", "args": ["$u"], "dim": "$x" },
      "grid_family": "cartesian",
      "combine": "+",
      "stencil": [
        { "selector": { "kind": "cartesian", "axis": "$x", "offset": -1 },
          "coeff":    { "op": "/", "args": [-1, { "op": "*", "args": [2, "dx"] }] } },
        { "selector": { "kind": "cartesian", "axis": "$x", "offset":  1 },
          "coeff":    { "op": "/", "args": [ 1, { "op": "*", "args": [2, "dx"] }] } }
      ]
    }
  }
}
```

### 7.1 Discretization fields

| Field | Required | Description |
|---|---|---|
| `applies_to` | ✓ | A shallow AST pattern (§5.2 syntax; depth-1, per §7.2.1) identifying the operator this scheme discretizes. It is a **guard only** — pattern-variable bindings flow from the triggering rule by name (§7.2.1); `applies_to` does not itself introduce bindings, and `stencil` / `coeff` see the rule's bindings. |
| `grid_family` | ✓ | `"cartesian"` or `"unstructured"` |
| `combine` | | `"+"` (default), `"*"`, `"min"`, or `"max"` — how stencil entries are combined. |
| `stencil` | ✓ | Array of `{ selector, coeff }` entries (see §4). Exactly one entry for a `reduction` selector; one-or-more for the others. |
| `accuracy` | | Informational: truncation order (string) |
| `order` | | Optional positive integer selecting stencil width / truncation order for families that admit a parameterized order (e.g. centered uniform finite differences via Fornberg-recursion weights: `order: 2` is the classical 3-point stencil, `order: 4` is the 5-point stencil, `order: 6` is the 7-point stencil, …). Centered uniform schemes require even orders; one-sided / upwind schemes may use any positive integer. The parity constraint is enforced by the rule implementation, not the schema. Absence means the rule's per-scheme default applies. See §7.1.2 for a worked comparison of `order: 2` vs `order: 4`. |
| `requires_locations` | | If set, the operand variable must carry one of these locations |
| `emits_location` | | The output's staggered location (for staggered schemes) |
| `target_binding` | | Reserved name for the target index (default: `"$target"`). Per grid family, `$target` resolves to the enclosing equation's LHS index (cartesian: `[i, j, k, ...]`; unstructured: bound to the iteration index of the operand's location, e.g. `c` for `cell`, `e` for `edge`, `v` for `vertex`). |

The `stencil` entries' `selector.kind` must match `grid_family`. `coeff`
expressions may reference the grid's metric arrays (as bare strings or
`index` nodes), the grid's parameters, pattern variables bound by the
triggering rule (§7.2.1), and the reserved `$target` components (see below).

#### 7.1.1 `$target` and implicit location indices (resolves M3; refines per gt-j6do new-m7 and gt-adhm C2/C3/M4)

`$target` names the LHS index of the equation being rewritten, decomposed
per the grid family:

| Grid family | `$target` components |
|---|---|
| `cartesian` | `[i, j, k, l, m, ...]` — one per dimension, in declaration order of `dimensions` |
| `unstructured` | **scalar** — one of `c` (cell), `e` (edge), `v` (vertex); the choice is pinned by the rule below |

**`$target` chooser on unstructured grids (resolves gt-adhm C2).** The
scalar value of `$target` for an unstructured scheme is:

- if the scheme declares `emits_location`, the target binds to the
  enumeration letter of `emits_location` (`cell_center` → `c`,
  `edge_normal` → `e`, `vertex` → `v`);
- otherwise, the target binds to the enumeration letter of the
  operand's `location` (from `requires_locations` if singular; otherwise
  the operand's variable-level `location`).

The §7.3 MPAS divergence example's scheme sets `emits_location:
"cell_center"`, so `$target` binds to `c` — consistent with that
section's worked expansion. Every other worked example in this RFC has
been re-verified under this rule.

**Operand references inside a scheme (resolves gt-adhm C2 follow-on).**
On unstructured grids, `$target` alone does not locate the operand when
the operand's location differs from the emit location. References to
the operand variable inside the scheme's `coeff` or `stencil.selector`
go via a connectivity table: `index(operand_var, index(<table>, $target,
<k>))` — not `index(operand_var, $target)`. The `reduction` selector's
`materialize` row (§7.2) encodes this convention: the materialized
operand reference is `index(operand, table[$target, k])`, where `table`
is declared on the selector and `k` is the reduction index.

**`k_bound` as a second in-scope index (resolves gt-j6do new-m7 and
gt-adhm M4).** A `reduction` selector's `k_bound` field names an
iteration variable that becomes **in scope inside the scheme's `coeff`
tree alongside `$target`**. The name is a string identifier (typically
`"k"`); the `coeff` may reference it as a bare string (which the
engine binds to the `arrayop`'s index variable at materialization time,
§7.2), exactly like `$target`. The `k_bound` identifier is **not**
prefixed with `$` — it is a local binding, not a pattern variable. The
following are reserved local index names per grid family (not available
as user variable names within a scheme):

| Grid family | Reserved local names |
|---|---|
| `cartesian` | `i, j, k, l, m` (up to five dims; deeper requires spec bump) |
| `unstructured` | `c, e, v` (target letter) plus any `k_bound` name introduced by a `reduction` selector |

If a scheme needs >5 cartesian dimensions it must bump the spec version.

**Dimension-name → `$target`-component mapping (resolves gt-adhm C3).**
For cartesian grids, axis `A` in a scheme's selector binds to the
`$target` component at index `dimensions.indexOf(A)`, using the canonical
component names `[i, j, k, l, m]` in the enumeration order of
`dimensions`. Example: a grid declared as `dimensions: ["lat", "lon",
"lev"]` exposes `$target = [i, j, k]` with `lat → i`, `lon → j`,
`lev → k`. A scheme selector `{kind: "cartesian", axis: "$x",
offset: -1}` with `$x := "lon"` materializes at `$target` by replacing
`j` with `j - 1`; the other components are unchanged.

Within a scheme, authors may reference `$target`'s components by their
canonical names above; the component names are reserved keywords and may
not be used as user variable names within a scheme. The v1 `mpas_edge_grad`
example's `$e` is an implicit binding to `$target` for an edge-operand
scheme; `$e` in that position is synonymous with `$target`.

**`dim` overloading on unstructured grids (resolves gt-adhm M7).** The
guard `dim_is_spatial_dim_of` (§5.2.4) and the pattern's `dim` sibling
field name spatial axes on cartesian grids (`x`, `y`, `z`) but
topological/emit-location names on unstructured grids (`cell`, `edge`,
`vertex`). This dual meaning is intentional: `dim` always names *the
axis along which the operator acts*, which for cartesian is a spatial
coordinate and for unstructured is a topological location. The guard
name is unchanged for v0.2.0 (renaming breaks every existing pattern);
authors authoring unstructured schemes should read `dim` as "along
which location does the operator reduce/emit".

#### 7.1.2 The `order` field — worked comparison (esm-z6d)

The optional `order` field selects stencil width / truncation order for
families that admit a parameterized order. The schema accepts any
positive integer; family-specific parity constraints (centered uniform
FD: even; one-sided: any positive) are enforced by the rule
implementation, not the schema. Absent `order` means the rule's
per-scheme default (e.g. the hard-coded `order: 2` of
`centered_2nd_uniform`).

**`centered_2nd_uniform` — order implicit in shape.** The classical
3-point centered second-order FD stores weights `[-1/(2·dx), 0,
+1/(2·dx)]` directly in `stencil` entries at offsets `-1, 0, +1`. The
truncation order is `O(dx^2)`, recorded informally in `accuracy`; no
`order` field is required because the width is hard-coded in the two
`stencil` rows:

```json
{
  "centered_2nd_uniform": {
    "applies_to":  { "op": "grad", "args": ["$u"], "dim": "$x" },
    "grid_family": "cartesian",
    "combine":     "+",
    "accuracy":    "O(dx^2)",
    "stencil": [
      { "selector": { "kind": "cartesian", "axis": "$x", "offset": -1 },
        "coeff":    { "op": "/", "args": [-1, { "op": "*", "args": [2, "dx"] }] } },
      { "selector": { "kind": "cartesian", "axis": "$x", "offset":  1 },
        "coeff":    { "op": "/", "args": [ 1, { "op": "*", "args": [2, "dx"] }] } }
    ]
  }
}
```

**`centered_arbitrary_order_uniform` — order selects a stencil
family.** The arbitrary-order scheme is authored once against a
selector family and delegates weight computation to the rule engine
via Fornberg recursion. The `order` field picks the concrete scheme at
materialization time — `order: 4` expands to a 5-point stencil with
weights `[+1/(12·dx), -8/(12·dx), 0, +8/(12·dx), -1/(12·dx)]` at
offsets `-2, -1, 0, +1, +2`; `order: 6` expands to a 7-point stencil;
and so on. For authoring convenience, a scheme may either (a) inline
the full stencil for a fixed `order` as in the example below, or (b)
declare `order` alongside a `reduction`-selector that the rule engine
materializes via `fornberg_weights`:

```json
{
  "centered_arbitrary_order_uniform": {
    "applies_to":  { "op": "grad", "args": ["$u"], "dim": "$x" },
    "grid_family": "cartesian",
    "combine":     "+",
    "accuracy":    "O(dx^4)",
    "order":       4,
    "stencil": [
      { "selector": { "kind": "cartesian", "axis": "$x", "offset": -2 },
        "coeff":    { "op": "/", "args": [ 1, { "op": "*", "args": [12, "dx"] }] } },
      { "selector": { "kind": "cartesian", "axis": "$x", "offset": -1 },
        "coeff":    { "op": "/", "args": [-8, { "op": "*", "args": [12, "dx"] }] } },
      { "selector": { "kind": "cartesian", "axis": "$x", "offset":  1 },
        "coeff":    { "op": "/", "args": [ 8, { "op": "*", "args": [12, "dx"] }] } },
      { "selector": { "kind": "cartesian", "axis": "$x", "offset":  2 },
        "coeff":    { "op": "/", "args": [-1, { "op": "*", "args": [12, "dx"] }] } }
    ]
  }
}
```

**Parity.** Centered uniform FD admits only even orders (2, 4, 6, 8,
…); the authoring layer rejects `order: 3` for this family with an
explicit diagnostic. One-sided and upwind schemes may use any positive
integer order. The schema does not encode the parity rule so that the
same `$def` can serve both families.

**Backwards compatibility.** Omitting `order` is the v0.2.0 default
and leaves every pre-existing scheme (including `centered_2nd_uniform`)
unchanged. No runtime semantic change occurs when `order` is absent.

### 7.2 Expansion semantics

Given a PDE operator match at point `$target`, the discretization expands to

```
combine_k( coeff_k · operand_ref_k )
```

where `combine_k` is the `combine` op (default `+`), `coeff_k` is
`coeff` after §6.2.1 auto-indexing, and `operand_ref_k` is
`{op:"index", args:[operand_var, ...materialize(selector_k, $target)]}`.

`materialize` turns a neighbor selector into a concrete list of index
expressions:

| Selector kind | `materialize(selector, target)` |
|---|---|
| `cartesian` | For target `[..., axis_idx, ...]`, output the same list with `axis_idx` replaced by `{op:"+", args:[axis_idx, offset]}`. |
| `indirect` | Emit `[index_expr]` after `$target`-substitution. `index_expr` is a single index expression into the indexed variable. |
| `reduction` | Lower to an `arrayop` over the index `k` running `0 .. count_expr - 1`, with element `coeff · index(operand, table[target, k])`, reducing via `combine`. |

All cases are pure AST transforms; no runtime array data is touched.

### 7.2.1 Scheme `applies_to` vs rule `pattern` — expansion protocol (resolves gt-adhm C4 / gt-j6do new-m6 / m8)

The rule engine (§5.2) and scheme expansion (§7.2) are **sequential,
not interleaved**. The protocol is:

1. **Rule match.** A rule's `pattern` is tried against each AST subtree
   during a rule-engine pass (§5.2.5). The first rule whose `pattern`
   matches (and whose `where` guards pass) fires. This produces pattern-
   variable bindings: `$u`, `$target`, `$x`, … are bound to AST
   subtrees or bare strings per §5.2.1.
2. **Scheme selection.** If the rule's replacement is `use: <scheme>`,
   the named scheme is retrieved from `discretizations.<scheme>`.
   If the replacement is an inline AST (the `replacement` field), no
   scheme is involved and this step is skipped.
3. **`applies_to` guard check.** The scheme's `applies_to` pattern is
   matched against the **rule-matched subtree**, using the rule's
   pattern-variable bindings as the starting substitution. This match
   is a **guard only**, not a rebinder: its purpose is to verify that
   the rule and the scheme agree on the operator class and variable
   positions. Pattern-variable bindings from the rule **dominate**;
   the scheme's `applies_to` neither introduces new bindings nor
   shadows existing ones.
   - If `applies_to` **matches**, expansion proceeds with the rule's
     bindings.
   - If `applies_to` **fails to match**, the engine aborts with error
     code `E_SCHEME_MISMATCH`, identifying the rule, scheme, and
     mismatched field. This is an **authoring error** — the rule and
     scheme do not agree on the operator class — and is caught at
     rewrite time (not at loader time), because the rule may have
     bound pattern variables that the scheme's shallower pattern would
     not have constrained.
4. **Pattern-variable name alignment.** Pattern variables flow by
   **name** from rule into scheme. If the rule binds `$u` and the
   scheme references `$u`, the binding flows. If the rule binds `$X`
   and the scheme references `$u`, the scheme's `$u` is **unbound**
   at expansion, and the engine aborts with `E_SCHEME_MISMATCH`. There
   is no implicit renaming. Authors are expected to use consistent
   pattern-variable names across the rule and the scheme.
5. **Expansion.** The scheme's `stencil`, `combine`, and `coeff`
   entries are materialized per §7.2 using the inherited bindings.
   The resulting AST replaces the matched subtree.

**`applies_to` depth (resolves gt-adhm m5).** An `applies_to` pattern
is syntactically **depth-1** in v0.2.0: the top-level op and its
immediate children only. Deeper patterns require authors to use the
rule's `pattern` field. This keeps scheme authorship simple and keeps
the cost of the `applies_to` guard check bounded.

**No second pass of rule matching.** `applies_to` is NOT a sibling of
the rule `pattern` in the fixed-point loop. The engine does not match
schemes against unmatched subtrees. A scheme is invoked only via a
rule that names it.

### 7.3 Worked MPAS divergence (resolves M2 / C4)

Scheme:

```json
{
  "mpas_cell_div": {
    "applies_to":   { "op": "div", "args": ["$F"], "dim": "cell" },
    "grid_family":  "unstructured",
    "requires_locations": ["edge_normal"],
    "emits_location":     "cell_center",
    "combine":      "+",
    "stencil": [
      {
        "selector": {
          "kind":       "reduction",
          "table":      "edgesOnCell",
          "count_expr": { "op": "index", "args": ["nEdgesOnCell", "$target"] },
          "k_bound":    "k",
          "combine":    "+"
        },
        "coeff": {
          "op": "/",
          "args": [
            { "op": "index", "args": ["dvEdge", { "op": "index", "args": ["edgesOnCell", "$target", "k"] } ] },
            { "op": "index", "args": ["areaCell", "$target"] }
          ]
        }
      }
    ]
  }
}
```

Expansion at cell `c` lowers (§7.2 `reduction` row) to the following,
which conforms **exactly** to base-spec §4.3.1 `arrayop` (resolves
gt-j6do New C2):

```json
{ "op": "arrayop",
  "output_idx": [],
  "expr": { "op": "*", "args": [
      { "op": "/", "args": [
          { "op": "index", "args": ["dvEdge", { "op": "index", "args": ["edgesOnCell", "c", "k"] } ] },
          { "op": "index", "args": ["areaCell", "c"] } ] },
      { "op": "index", "args": [ "F", { "op": "index", "args": ["edgesOnCell", "c", "k"] } ] }
  ]},
  "ranges": {
    "k": [ 0, { "op": "-", "args": [ { "op": "index", "args": ["nEdgesOnCell", "c"] }, 1 ] } ]
  },
  "reduce": "+",
  "args": ["F", "dvEdge", "areaCell", "edgesOnCell", "nEdgesOnCell"]
}
```

**Field-by-field base-spec conformance check** (self-validation note,
per gt-j6do New C2):

- `output_idx: []` — empty list because the expansion at fixed cell `c`
  produces a scalar; the outer per-cell iteration is implicit in the
  equation's `$target`-parameterized LHS.
- `expr` — the per-iteration element expression over the contracted
  index `k`. Matches base-spec §4.3.1's `expr` slot.
- `ranges` — uses the `[start, stop]` integer-pair form (base spec
  §4.3.1 L210–213). `stop` here is an expression; the base-spec
  matrix-multiply example uses integer literals, and the spec explicitly
  permits complex offsets inside `expr` (L218). The expression form of
  `stop` is within the stated non-affine-offset convention.
- `reduce: "+"` — string op, matching the base-spec column-sum example
  (L227). The v2 draft's object-shaped `{op: "+", init: 0}` form is
  dropped.
- `args` — lists every array referenced in `expr` or `ranges` by bare
  name, as the base-spec matmul example does (L214, L228). `k` is not
  listed (it is an index variable, not an array).

This is the same `arrayop` shape the existing spec §4.3.1 supports; no new
AST node is introduced for the reduction. The MPAS worked example **parses
against the base-spec `arrayop` schema** — a conformance fixture under
`tests/conformance/discretization/step3_mpas/` MUST include a JSON-schema
validation assertion that this lowered form validates against
`esm-schema.json`'s `arrayop` definition. MPAS thus "reduces to" the stencil
template after one lowering step to `arrayop`, consistent with §4's
architectural claim.

The inner `index` on `edgesOnCell` is a dynamic index: `k` is a symbolic
index variable valid inside `arrayop.expr` (per spec §4.3.3), so `"k"` as a
bare string is permitted and resolves to the arrayop index variable — no
`regrid` is needed because we remain on grid `mpas_cvmesh`.

### 7.4 Schema — `staggering_rules` (unstructured C-grid, resolves esm-15f)

The §7.3 worked example consumes normal-velocity `F` at `edge_midpoint` and
emits flux divergence at `cell_center`. Before a binding can wire such a
scheme end-to-end (i.e. author `mpas_divergence_flux_form` or
`mpas_gradient_edge_difference` against a concrete MPAS mesh), the format
must carry an explicit declaration of where each quantity lives: scalars at
Voronoi cell centers, normal velocities at edge midpoints, vorticity at
triangle vertices.

v0.2.0 adds a new top-level section `staggering_rules`, keyed by rule name.
Each entry is a `StaggeringRule` object with a `kind` discriminant:

| Field | Required | Description |
|---|---|---|
| `kind` | ✓ | Staggering family. v0.2.0 defines `"unstructured_c_grid"` (MPAS Voronoi). Future kinds (e.g. `"arakawa_c_structured"`) require a spec bump. |
| `grid` | ✓ | Name of a `grids.<g>` entry this rule applies to. For `kind="unstructured_c_grid"`, the referenced grid's `family` must be `"unstructured"`. Bindings enforce this as a semantic post-parse check. |
| `cell_quantity_locations` | ✓ (for `unstructured_c_grid`) | Map: quantity name → one of `"cell_center"`, `"edge_midpoint"`, `"vertex"`. Consumers (§7.3) read this map to know that e.g. normal-velocity `u` lives at `edge_midpoint`, so flux divergence emits at `cell_center` via a reduction selector over `edgesOnCell`. |
| `edge_normal_convention` | ✓ (for `unstructured_c_grid`) | Orientation semantics for edge-normal fluxes. `"outward_from_first_cell"` is the MPAS convention (normal at edge `e` points from `cellsOnEdge[e, 0]` to `cellsOnEdge[e, 1]`); `"outward_from_second_cell"` is the reverse; `"right_hand_tangent"` orients by `verticesOnEdge` (used by some vorticity schemes). |
| `dual_mesh_ref` | | Optional name of a `grids.<g>` entry representing the Delaunay dual of the Voronoi primal grid. MPAS needs the dual mesh for vorticity at triangle vertices; omit when the rule is used only for divergence/gradient schemes. |
| `description` | | Human-readable note. |
| `reference` | | Optional bibliographic reference (same shape as `Reference` elsewhere). |

**Worked example** — the MPAS C-grid staggering (Skamarock et al. 2012,
Eq. 24):

```json
{
  "staggering_rules": {
    "mpas_c_grid_staggering": {
      "kind":  "unstructured_c_grid",
      "grid":  "mpas_cvmesh",
      "cell_quantity_locations": {
        "h": "cell_center", "q": "cell_center", "theta": "cell_center",
        "u": "edge_midpoint", "F": "edge_midpoint",
        "zeta": "vertex"
      },
      "edge_normal_convention": "outward_from_first_cell"
    }
  }
}
```

**Validation.** Bindings enforce three semantic constraints beyond JSON
Schema:

1. The referenced `grid` name must exist in the top-level `grids` map.
2. For `kind="unstructured_c_grid"`, that grid's family must be
   `"unstructured"` (otherwise the cell/edge/vertex vocabulary is
   meaningless).
3. `dual_mesh_ref`, if present, must also resolve to an `unstructured`
   grid.

**Relationship to §6 and §7.3.** `staggering_rules` is a sibling of `grids`
(§6) and `discretizations` (§7.1–§7.3): `grids` owns topology and metric
arrays; `staggering_rules` owns the quantity-location map over that
topology; `discretizations` owns the stencil templates that consume both.
The §7.3 worked example (`mpas_cell_div`) does not yet reference a
staggering rule by name because it reads locations off the scheme's
`requires_locations` / `emits_location` tags; `staggering_rules` formalizes
the same information at the *model* level so the same mesh can serve
multiple schemes without re-declaration. A follow-up bead will wire
`mpas_divergence_flux_form` (P0) and `mpas_gradient_edge_difference` (P1)
to read from `staggering_rules.<name>` explicitly.

**Round-trip contract.** The `staggering_rules` subtree must survive a
binding's load → save → load cycle byte-for-byte at the JSON-value level.
All five bindings (Julia, Python, TypeScript, Rust, Go) carry explicit
round-trip tests against the `tests/grids/mpas_c_grid_staggering.esm`
fixture.

### 7.5 Dimensional-split schemes (new; resolves esm-okt)

Certain families of transport operators — notably the Lin–Rood PPM
advection (Lin & Rood 1996 MWR) and the CAM5 flux-form semi-Lagrangian
scheme — are most naturally authored as a **sequence of 1D applications
along orthogonal axes**, not as a native N-D stencil. A `Discretization`
entry with

```json
{ "kind": "dimensional_split",
  "axes": ["x", "y"],
  "inner_rule": "centered_2nd_uniform",
  "splitting": "strang",
  "order_of_sweeps": "alternating" }
```

declares this composition structurally. The rule engine is not required
to materialize dimensional-split schemes into a single stencil body at
loader time; runtimes that own the sweep loop (e.g. ESD) consume the
declaration directly and orchestrate the 1D applications themselves.

| Field | Required | Description |
|---|---|---|
| `kind` | ✓ (value `"dimensional_split"`) | Discriminates this scheme from classic `"stencil"` entries. |
| `applies_to` | ✓ | Shallow AST pattern for the N-D operator this composite stands in for (guard only, per §7.2.1). |
| `grid_family` | ✓ | Must be `"cartesian"` — unstructured grids have no intrinsic orthogonal-axis ordering. |
| `axes` | ✓ | Ordered list of spatial axis names (from the target grid's `dimensions`). Each axis is swept once per Lie step and twice (symmetrically) per Strang step. |
| `inner_rule` | ✓ | Name of a sibling scheme in the file's `discretizations` section. The inner scheme provides the 1D operator applied on each axis; it is typically `kind: "stencil"`, `grid_family: "cartesian"`, with a single-axis cartesian selector. |
| `splitting` | ✓ | `"lie"`, `"strang"`, or `"none"` — operator-splitting convention (see below). |
| `order_of_sweeps` | | `"forward"` (default), `"reverse"`, or `"alternating"` — per-timestep axis traversal direction. Ignored when `splitting` is `"strang"` (which prescribes its own symmetric order) or `"none"`. |
| `accuracy`, `requires_locations`, `emits_location`, `target_binding`, `ghost_vars`, `free_variables`, `description`, `reference` | | Same meaning as for stencil schemes; `ghost_vars` declared here apply to the composite's outer boundary, not the inner scheme's. |
| `stencil`, `combine` | ✗ | Must **not** appear on `kind: "dimensional_split"` entries. The loader-level schema enforces this via conditional `required` / `not.required`. |

**Splitting semantics.**

- `lie`: apply the inner rule along `axes[0]` for time Δt, then `axes[1]`
  for Δt, … then `axes[N−1]` for Δt. First-order accurate in time.
- `strang`: apply the inner rule along `axes[0]` for Δt/2, then
  `axes[1]` for Δt/2, … then `axes[N−1]` for Δt, then `axes[N−2]` for
  Δt/2, … back to `axes[0]` for Δt/2. Symmetric, second-order accurate
  in time.
- `none`: structurally declares the composite without prescribing a
  timestep order. Useful when the consuming runtime chooses the
  splitting at dispatch time (e.g. parallel-split solvers), or when the
  file is a static catalogue entry used for documentation only.

**Worked sketch.** A 2D PPM advection on a cartesian grid would look like

```json
{ "discretizations": {
    "ppm_1d": {
      "kind": "stencil",
      "grid_family": "cartesian",
      "applies_to": { "op": "adv", "args": ["$u"], "dim": "$x" },
      "stencil": [ /* PPM reconstruction entries, omitted for brevity */ ]
    },
    "ppm_advection": {
      "kind": "dimensional_split",
      "applies_to": { "op": "adv", "args": ["$u"] },
      "grid_family": "cartesian",
      "axes": ["x", "y"],
      "inner_rule": "ppm_1d",
      "splitting": "strang",
      "order_of_sweeps": "alternating"
    }
  }
}
```

The rule engine matches the 2D `adv` operator to `ppm_advection`.
Runtimes that can lower Strang-split advection into the inner 1D calls
do so using `inner_rule` and `axes`; those that cannot simply carry the
composite through as-is for ESD to execute.

**Binding contract.** All five bindings (Julia, TypeScript, Python, Rust,
Go) parse and round-trip `kind: "dimensional_split"` schemes losslessly.
Structured expansion semantics (inlining the N·Δt/2 sweep into a single
AST) is **out of scope** for v0.2.0 and tracked separately in ESD. The
conformance manifest adds `tests/discretizations/dim_split_2d_strang.esm`
— a 2D Strang-split scheme over `centered_2nd_uniform` — as the
cross-binding fixture.

### 7.6 Cross-metric stencil composition — removed (was esm-vwo; retired by ess-oqx)

> **Status: removed.** The `CrossMetricStencilRule` composite
> (`kind: "cross_metric"`) introduced for esm-vwo has been withdrawn from
> the schema and from every binding's type mirror. It was a
> naming/composition convenience for a sum of
> `sign · metric_component(i,j) · per-axis-1D-stencil` terms that — by its
> own former expansion semantics — reduced to a sum of standard §4.3.1
> `arrayop` nodes after a single lowering step. It was never an
> irreducible primitive, and it had no production consumers at removal
> time.
>
> The covariant operators it was meant for — the full covariant Laplacian
> and gradient on curvilinear / lat–lon grids — are now expressed directly
> as generic **`arrayop`-einsum replacement rules** built from base AST
> ops only: multi-axis `index` gathers (including the four NE/NW/SE/SW
> corner gathers for the off-diagonal `g_xieta` cross-derivative),
> arithmetic, and `const`-array metric coefficients. No dedicated
> composite scheme kind is required. Authors needing a covariant operator
> should compose it from the §4.3.1 `arrayop` / `index` ops (see the ESD
> covariant finite-volume rule set) rather than a discretization
> composite.
>
> Section numbers §7.7–§7.9 are intentionally left unchanged so existing
> cross-references stay valid.

### 7.7 Flux-form semi-Lagrangian schemes (new; resolves esm-1rj)

The CAM5 finite-volume dycore and related transport solvers build advection
as a **flux-form semi-Lagrangian (FFSL)** family (Lin & Rood, *Mon. Wea. Rev.*
124, 2046–2070, 1996): a sub-cell reconstruction is combined with flux-form
remapping so that advection conserves the volume-integrated tracer mass. FFSL
rules are structurally distinct from stencil entries (they do not enumerate a
neighbor list with symbolic coefficients) and from dimensional-split composites
(they name a concrete reconstruction/remap/limiter triple and the axes along
which the rule advects). A `Discretization` entry with

```json
{ "kind": "flux_form_semi_lagrangian",
  "applies_to": { "op": "adv", "args": ["$u"], "dim": "$x" },
  "grid_family": "cartesian",
  "reconstruction": { "order": "PPM" },
  "remap": { "semantics": "conservative", "flux_form": "lin_rood_1996" },
  "cfl_policy": "conservative",
  "dimensions": ["x"] }
```

declares a 1D FFSL rule. v0.2.0 treats parse + round-trip + structural
rejection as the binding contract; concrete runtime dispatch (execution of
the reconstruction / remap pair) lives in ESD.

| Field | Required | Description |
|---|---|---|
| `kind` | ✓ (value `"flux_form_semi_lagrangian"`) | Discriminates FFSL rules from `"stencil"` and `"dimensional_split"`. |
| `applies_to` | ✓ | Shallow AST pattern identifying the operator the rule discretizes (guard only, per §7.2.1). |
| `grid_family` | ✓ | Target grid family. |
| `reconstruction` | ✓ | Either a **string** naming a sibling `discretizations.<name>` entry that provides the reconstruction stencil, or an inline object `{ "order": <name>, "parameters": {…} }`. `order` is a free-form family tag (`"PPM"`, `"PLM"`, `"centered"`, `"WENO5"`, …) — the schema does not enumerate orders because runtimes may add families; unknown values are the rule engine's responsibility to reject. |
| `remap` | ✓ | Object `{ "semantics": "conservative" \| "non_conservative", "flux_form"?: string, "parameters"?: object }`. `conservative` preserves cell-integrated mass per Lin & Rood (1996) §2; `non_conservative` uses pointwise semi-Lagrangian trajectory remap (Staniforth & Côté 1991). `flux_form` is an optional sub-kind tag (e.g. `"lin_rood_1996"`). |
| `limiter` |   | Optional monotonicity limiter. Either a string rule-ref (a sibling `discretizations.<name>` providing the limiter stencil), or an inline `{ "family": <name>, "parameters"?: object }` object. |
| `cfl_policy` | ✓ | `"conservative"` or `"non_conservative"` — governs the reconstruction/remap pairing. |
| `dimensions` | ✓ | Ordered list of axis names along which the rule advects. Each axis must appear in the enclosing grid's `dimensions`. Composes with §7.5 dimensional-split: a dimensional-split scheme's `inner_rule` may reference an FFSL rule whose `dimensions` is a single axis. |
| `accuracy`, `requires_locations`, `emits_location`, `target_binding`, `ghost_vars`, `free_variables`, `description`, `reference` |   | Same meaning as for stencil schemes. |
| `stencil`, `combine`, `axes`, `inner_rule`, `splitting`, `order_of_sweeps` | ✗ | Must **not** appear on `kind: "flux_form_semi_lagrangian"` entries; `axes`/`inner_rule`/`splitting` are the §7.5 dimensional-split fields. The loader-level schema enforces this via conditional `required` / `not.required`. |

**CAM5 worked sketch.** The full 2D CAM5 FV FFSL advection is assembled by
composing a 1D FFSL rule under a §7.5 dimensional-split composite:

```json
{ "discretizations": {
    "cam5_ffsl_1d": {
      "kind": "flux_form_semi_lagrangian",
      "applies_to": { "op": "adv", "args": ["$u"], "dim": "$x" },
      "grid_family": "cartesian",
      "reconstruction": { "order": "PPM" },
      "remap": { "semantics": "conservative", "flux_form": "lin_rood_1996" },
      "limiter": { "family": "monotonic" },
      "cfl_policy": "conservative",
      "dimensions": ["x"]
    },
    "cam5_fv_ffsl_advection": {
      "kind": "dimensional_split",
      "applies_to": { "op": "adv", "args": ["$u"] },
      "grid_family": "cartesian",
      "axes": ["x", "y"],
      "inner_rule": "cam5_ffsl_1d",
      "splitting": "strang",
      "order_of_sweeps": "alternating"
    }
  }
}
```

The rule engine matches the 2D `adv` operator to `cam5_fv_ffsl_advection`;
the dimensional-split composite delegates each per-axis Δt/2 (or Δt) sweep
to the 1D `cam5_ffsl_1d` rule.

**Binding contract.** All five bindings (Julia, TypeScript, Python, Rust,
Go) parse and round-trip `kind: "flux_form_semi_lagrangian"` schemes
losslessly and reject structural violations of the discriminator contract
(stencil-on-FFSL, missing `cfl_policy`, FFSL-field-on-stencil). Execution
of the reconstruction / remap pair is **out of scope** for v0.2.0 and is
tracked in ESD (`cam5_fv_ffsl_advection`, P1). The conformance manifest adds
`tests/discretizations/cam5_ffsl_advection.esm` — a minimal 1D FFSL rule
with centered reconstruction and conservative remap — as the cross-binding
fixture.


### 7.8 Grid-family dispatch (`grid_dispatch`, resolves esm-fpb)

Several earth-system operators take a different concrete form depending on
the grid family on which they are evaluated. The canonical example is PPM
advection: on a Cartesian interior the scheme is the 4-point Colella–Woodward
stencil; on an unstructured mesh the scheme uses the indirect/reduction
selectors of §7 to walk the connectivity tables. v0.2 forced authors to fork a
single operator into two named `discretizations` entries (one per family) and a
sibling rule for each; this duplicated metadata (`applies_to`, `accuracy`,
`order`, `requires_locations`, `emits_location`, …) and entangled the
operator name with the grid topology.

v0.3 adds an optional **`grid_dispatch`** block to a Discretization. When
present, `grid_dispatch` is an array of two or more `DiscretizationVariant`
objects, each carrying its own `grid_family` plus the body fields (`stencil`
/ `kind` / `axes` / `inner_rule` / `splitting` / `order_of_sweeps` /
`reconstruction` / `remap` / `limiter` / `cfl_policy` / `dimensions` /
`combine`) that would otherwise live on the parent. The loader picks the
variant whose `grid_family` matches the active grid's family at expansion
time and substitutes its body in place of the parent's. Shared metadata
(`applies_to`, `accuracy`, `order`, `requires_locations`, `emits_location`,
`target_binding`, `ghost_vars`, `free_variables`, `description`,
`reference`) remains on the parent and applies to every variant.

**Mutual exclusion.** When `grid_dispatch` is present:
- Top-level `grid_family` MUST be absent (the variants own family selection).
- Inline body fields (`stencil`, `kind`, `combine`, `axes`, `inner_rule`,
  `splitting`, `order_of_sweeps`, `reconstruction`, `remap`, `limiter`,
  `cfl_policy`, `dimensions`) MUST be absent at the parent level.
- Each variant's `grid_family` MUST be unique within the array; ordering is
  not significant. A variant whose `grid_family` matches no active grid is
  inert.

**Worked example.** A single PPM scheme covering both a Cartesian interior
and an unstructured mesh:

```json
{
  "discretizations": {
    "ppm_advection": {
      "applies_to": { "op": "grad", "args": ["$u"], "dim": "$x" },
      "accuracy":   "O(dx^3)",
      "free_variables": ["$u", "$x"],
      "grid_dispatch": [
        {
          "grid_family": "cartesian",
          "kind":        "stencil",
          "stencil":     [ /* 4-point Colella–Woodward */ ]
        },
        {
          "grid_family": "unstructured",
          "kind":        "stencil",
          "stencil":     [ /* reduction-selector stencil */ ]
        }
      ]
    }
  }
}
```

A single rule firing on `grad($u, $x)` selects `ppm_advection`; the loader
inspects the active grid's `family` and substitutes the matching variant's
body into the §7.2 expansion. No duplicated rule, no fork.

**Binding contract.** All five bindings (Julia, TypeScript, Python, Rust,
Go) parse and round-trip `grid_dispatch` losslessly and reject structural
violations (parent `grid_family` alongside `grid_dispatch`, inline body
fields alongside `grid_dispatch`, fewer than two variants, duplicate
`grid_family` within the array — schema-enforced; uniqueness is enforced
by the loader, since JSON Schema cannot express it directly). Runtime
selection of a matching variant during §7.2 expansion is **out of scope**
for the v0.3 schema bump and is tracked as follow-up beads
(`esm-fpb` MVP delivers the schema + parse/round-trip; per-binding rule
engines pick up runtime selection separately, mirroring the FFSL
trajectory of §7.7). The conformance manifest adds
`tests/discretizations/grid_dispatch_ppm.esm` — a PPM scheme with
a cartesian variant — as the cross-binding fixture.


### 7.9 Multi-output stencil schemes (`multi_output_stencil`, resolves ess-7hb)

Several authoritative catalog rules emit **multiple named outputs** from one
stencil application. `ppm_reconstruction` produces `q_left_edge` and
`q_right_edge` from a single `reconstruct(q, dim=x)` match; `weno5_advection_2d`
produces four edge values. The §7.2 rewrite contract cannot express these: one
rule match replaces one expression occurrence with one expression, and two rules
with the same pattern cannot both fire on a single occurrence.

`kind: "multi_output_stencil"` adds a new top-level scheme shape (a sibling of
`Discretization` in the `discretizations` value
space). It shares the `applies_to` / `grid_family` / `emits_location` /
`accuracy` / `free_variables` / `target_binding` fields with §7.1 but replaces
the flat `stencil` array with a **stencil object keyed by output name**, plus an
explicit `outputs` array and a nullable `primary` field.

**Schema shape (§7.9 normative):**

```jsonc
{
  "discretizations": {
    "ppm_reconstruction": {
      "kind": "multi_output_stencil",
      "applies_to": { "op": "reconstruct", "args": ["$q"], "dim": "$x" },
      "grid_family": "cartesian",
      "outputs": ["q_left_edge", "q_right_edge"],
      "emits_location": "face",
      "primary": null,                // provider-only: fire only via consumer requires
      "stencil": {
        "q_left_edge":  [ { "selector": { "kind": "cartesian", "axis": "$x", "offset": -1 }, "coeff": 0.5 },
                          { "selector": { "kind": "cartesian", "axis": "$x", "offset":  0 }, "coeff": 0.5 } ],
        "q_right_edge": [ { "selector": { "kind": "cartesian", "axis": "$x", "offset":  0 }, "coeff": 0.5 },
                          { "selector": { "kind": "cartesian", "axis": "$x", "offset":  1 }, "coeff": 0.5 } ]
      }
    },
    "ppm_flux": {
      "kind": "stencil",
      "applies_to": { "op": "flux", "args": ["$q", "$c"], "dim": "$x" },
      "requires": {
        "q_left_edge":  "ppm_reconstruction#q_left_edge",
        "q_right_edge": "ppm_reconstruction#q_right_edge"
      },
      "stencil": [
        { "selector": { "kind": "cartesian", "axis": "$x", "offset": 0 },
          "coeff": { "op": "-", "args": [
            { "op": "*", "args": ["$c", "q_right_edge"] },
            { "op": "*", "args": ["$c", "q_left_edge"] }
          ] }
        }
      ]
    }
  }
}
```

**Field reference:**

| Field | Required | Description |
|-------|----------|-------------|
| `kind` | optional | `"multi_output_stencil"` — discriminator for statically-typed bindings |
| `applies_to` | ✓ | Shallow AST pattern (guard only, per §7.2.1) |
| `outputs` | ✓ | Ordered array of output names; MUST equal the `stencil` object key set |
| `stencil` | ✓ | Object keyed by output name; each value is a §7.1 stencil-entry list |
| `primary` | | Name of the output substituted at the matched expression site; `null` for provider-only schemes |
| `emits_location` | | Default staggered-grid location for all emitted output variables |
| `grid_family` | | Grid family constraint (same values as §7.1) |
| `accuracy`, `order`, `requires_locations`, `target_binding`, `free_variables`, `description`, `reference` | | Same semantics as §7.1 |

**Consumer side — `requires` on a sibling Discretization:**

A standard `Discretization` (kind `"stencil"`, `"dimensional_split"`, etc.) may
carry a `requires` map:

```jsonc
"requires": {
  "<local-name>": "<sibling-scheme>#<declared-output>",
  ...
}
```

The engine instantiates the referenced provider with the consumer's inherited
bindings (the same §7.2.1 name-flow used by `dimensional_split.inner_rule`)
and emits the observed equations on first reference.
The local names are ordinary shaped variables after emission — the consumer's own
stencil/coeff expressions reference them by name.

**Trigger paths:**

1. **Consumed directly** — a `use:` rule matches the provider's `applies_to`;
   the engine emits one observed arrayop equation per declared output and rewrites
   the matched expression to the output named by `primary`.

2. **Demanded by a consumer** — the provider's `applies_to` has no occurrence in
   any model equation; a downstream scheme's `requires` map names one or more of
   its outputs. The engine instantiates the provider with the consumer's bindings
   on first demand, emits the observed equations, and memoizes the instantiation
   by `(scheme name, canonical bindings)` so diamond dependencies emit once.

**Loader contract (parse-time checks):**

- `outputs` MUST equal the key set of `stencil`. Violation: `E_OUTPUTS_STENCIL_MISMATCH`.
- `primary`, when non-null, MUST name a declared output. Violation: `E_PRIMARY_NOT_AN_OUTPUT`.
- Every `requires` value MUST resolve to `<sibling scheme>#<declared output>` where the
  sibling is a `multi_output_stencil` and the output is in its `outputs` array.
  Violations: `E_PROVIDER_NOT_FOUND`, `E_OUTPUT_NOT_FOUND`.
- Resolution is static (at load time) — binding compatibility is a runtime check.
- Provider instantiations are memoized by `(scheme name, canonical bindings)`.
  A conflicting second instantiation (same provider, same bindings, author-declared
  name collision) is `E_PROVIDER_NAME_CLASH`.
- Providers nobody demands never emit (lazy instantiation).
- Emitted variable names are mangled as `<output>__<operand>__<axis>` per
  instantiation unless the author pre-declares the variable (pre-declared name wins).

**Staggered extents (OQ1 resolved):** For a face-located output
(`emits_location: "face"`) on a bounded (non-periodic) dimension, the emitted
arrayop `ranges` along the stencil axis extend to `n+1` (bounded dimension with
`n` cells has `n+1` faces). Periodic dimensions retain `n` faces (face extent
equals cell extent). All other output locations keep `n` on bounded dimensions.
The `derived:` block for non-stencil outputs (OQ3) is deferred to a follow-on
bead.

**Relationship to §7.5/§7.6.** The `requires` binding name-flow is the fourth
instance of the sibling-scheme reference pattern (after §7.5 `inner_rule`, §7.6
`axis_stencil`, and §7.8 `grid_dispatch` inner rules). Provider chains are
recursive with cycle detection (`E_SCHEME_CYCLE`). `grid_dispatch` and
`multi_output_stencil` are orthogonal: a `DiscretizationVariant` body does not
accept `outputs`/`stencil`-object; authors who need per-family multi-output
schemes declare separate top-level entries.

**Binding contract.** All five bindings (Julia, TypeScript, Python, Rust, Go)
parse and round-trip `multi_output_stencil` entries losslessly and reject the
four structural violations listed in the loader contract above. Runtime expansion
(demand-driven instantiation and observed-equation emission) is out of scope for
the v0.7.0 schema bump and is tracked as follow-on beads (mirroring the FFSL
§7.7 trajectory). The conformance manifest adds
`tests/discretizations/multi_output_ppm_reconstruction.esm` — a PPM
reconstruction provider with a flux consumer — as the cross-binding fixture.

*Draft source: `docs/content/rfcs/multi-output-discretizations-draft.md` (Option B,
demand-driven provider resolution, open question 2 resolved 2026-06-13). That
document is now superseded by this normative section.*


## 8. Amendments to §8 (`data_loaders`) — inline (resolves C4)

v0.2.0 extends `data_loaders` with a new `kind: "mesh"` that covers MPAS-
style connectivity and metric provision. The RFC's Step 3 acceptance depends
on these additions; they are therefore part of this RFC, not an unscheduled
follow-up.

### 8.A New `kind: "mesh"`

```json
{
  "data_loaders": {
    "mpas_mesh": {
      "kind": "mesh",
      "source": { "url_template": "./mpas/x1.2562.grid.nc" },
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
      "reference": { "doi": "10.5194/gmd-5-1115-2012" }
    }
  }
}
```

#### 8.A.1 Mesh-loader fields (additions to the §8.1 table)

| Field | Required | Description |
|---|---|---|
| `kind: "mesh"` | ✓ | Distinguishes from `"grid"`, `"points"`, `"static"`. |
| `mesh.topology` | ✓ | Closed enum: `"mpas_voronoi"` (MVP), `"fesom_triangular"` (future), `"icon_triangular"` (future). Adding a value is a minor version bump. |
| `mesh.connectivity_fields` | ✓ | List of integer-typed fields exposed under `grids.<g>.connectivity.<name>`. |
| `mesh.metric_fields` | ✓ | List of float-typed fields exposed under `grids.<g>.metric_arrays.<name>`. |
| `mesh.dimension_sizes` | | Map of dimension name → integer or `"from_file"`. Values populate grid-level `parameters` marked `from_loader`. |
| `determinism` | | Endian / format / integer-width declarations. Required for bit-exact reproducibility guarantees. A binding that cannot honor these must reject at load. |

#### 8.A.2 Addressing

A grid's `metric_arrays.<m>.generator.{loader, field}` or
`connectivity.<c>.{loader, field}` references a mesh loader by its top-level
`data_loaders` key and picks out one field by name from the loader's exposed
`metric_fields` / `connectivity_fields`. This resolves review C4's
"addressing inconsistency" (the RFC v1's `{kind, name, params}` shape was
incompatible with existing loader keying; v2 uses the existing-key + field
pattern).

#### 8.A.3 Time-dependent loader fields for BCs (resolves M5)

A loader with `kind: "grid"` or `kind: "mesh"` may expose time-varying
fields (e.g., observed SST at prescribed BCs) that are referenceable from
a model-level `boundary_conditions` entry's `value` AST. The mechanism:

1. The loader declares the time-varying field under `variables.<schema_name>`
   (existing §8.5 mechanism). No schema change here.
2. A BC's `value` AST may contain `{op:"index", args:["observed_SST",
   "t", <face_coord_0>, <face_coord_1>]}`. `observed_SST` is a bare string
   that the loader resolves. The `t` argument is **explicit**: `t` is the
   model's time variable (spec §11.3 `independent_variable`, default
   `"t"`), bound as a free variable of the BC expression. It is **not**
   implicit. The face-coordinate arguments are the face's (dim-reduced)
   index within the BC's `side` (see §9.2 below for the exact shape).
3. The rule engine does not evaluate the loader field at rewrite time; it
   passes the `index` expression through. The downstream ODE/DAE assembler
   wires `"observed_SST"` to a runtime handle.
4. The canonical form (§5.4) preserves the ordering of arguments: `t` is
   always first, spatial coords follow in declaration order of `side`'s
   reduced dimensions.

This keeps rewrite static while letting loader outputs serve as BC sources.

## 9. Schema — model-level `boundary_conditions` (resolves C2)

Boundary conditions are promoted from a domain property to a first-class
model-level section, structurally parallel to `coupling`. This is a
**breaking change** from v0.1; see §10 for migration.

### 9.1 Top-level under a model

```json
{
  "models": {
    "atmos": {
      "domain": "atmosphere",
      "grid":   "atmos_rect",
      "boundary_conditions": {
        "u_dirichlet_xmin": {
          "variable": "u",
          "side":     "xmin",
          "kind":     "dirichlet",
          "value":    "u_xmin_value"
        },
        "SO2_flux_zmin": {
          "variable": "SO2",
          "side":     "zmin",
          "kind":     "neumann",
          "value": {
            "op": "*",
            "args": [ { "op": "-", "args": ["v_dep"] }, { "op": "index", "args": ["SO2", "i", "j", 0] } ]
          },
          "contributed_by": { "component": "dry_deposition", "flux_sign": "-" }
        }
      }
    }
  }
}
```

### 9.2 Boundary condition fields

| Field | Required | Description |
|---|---|---|
| `variable` | ✓ | Name of the model variable the BC constrains. |
| `side` | ✓ | Boundary side: `"xmin"`, `"xmax"`, `"ymin"`, ..., `"mesh_boundary"` (unstructured). |
| `kind` | ✓ | `"constant"`, `"dirichlet"`, `"neumann"`, `"robin"`, `"zero_gradient"`, `"periodic"`, `"flux_contrib"` (for component-contributed flux terms, see §9.3). |
| `value` | | Expression or number; semantics per `kind`. |
| `robin_alpha` / `_beta` / `_gamma` | | As in spec §11.5, when `kind: "robin"`. |
| `face_coords` | | Declares the reduced face-coordinate index names used when `value` contains `index` into a loader-provided time-varying field. E.g., for `side: "zmin"` on a 3D grid, `face_coords: ["i", "j"]`. |
| `contributed_by` | | Optional; identifies the model component contributing this flux. The v2 canonical way for a deposition module (or any component) to declare a boundary-flux contribution (resolves decision 3(c)). |

Rules (§10) rewrite `boundary_conditions` entries into discretized form the
same way they rewrite interior equations. A BC pattern is matched via
`{op: "bc", args:["$u"], kind: "dirichlet", side: "xmin"}` against the
entry's `{variable, kind, side}` (synthetic `op: "bc"` node; the entry's
`value` is carried as the sole Expression arg after `$u`).

### 9.2.1 Worked periodic BC (resolves gt-adhm M2)

Periodic BCs were previously declared at domain level (v0.1). In v0.2,
they are declared in `models.<M>.boundary_conditions` like any other
BC. Periodicity is inherently a **pair** relationship between a pair
of opposing sides, not a side-local property; this subsection pins the
authoring convention and the rule rewrite.

**Authoring: declare once, at either side of the periodic pair.** A
model with periodic BC on the `x` axis declares ONE `boundary_conditions`
entry with `kind: "periodic"` on either `xmin` or `xmax` (authors choose;
the canonical form is `xmin`). The paired side is implicit. Declaring
the same periodic pair at both sides is accepted but redundant; the
loader normalizes to the single-side form (emit a warning if both
sides are declared and differ in any field).

**Example — 1D advection on `[0, L]` with periodic BC:**

```json
{
  "models": {
    "adv_1d": {
      "domain": "line",
      "grid":   "x_uniform",
      "variables": {
        "u": { "shape": ["x"], "location": "cell_center" }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["u"], "wrt": "t" },
          "rhs": { "op": "*", "args": [ { "op": "-", "args": ["v_adv"] }, { "op": "grad", "args": ["u"], "dim": "x" } ] } }
      ],
      "boundary_conditions": {
        "u_periodic_x": {
          "variable": "u",
          "side":     "xmin",
          "kind":     "periodic"
        }
      }
    }
  }
}
```

**Rewrite rule.** A BC rule matches the `bc` node and rewrites each
edge-cell stencil that would reach outside the domain to use the
periodic-wrapped neighbor. For a cartesian grid with `N = Nx` cells,
the rule is:

```json
{
  "rules": {
    "periodic_wrap_x": {
      "pattern": { "op": "index", "args": ["$u", "$expr_i", "$rest"] },
      "where":   [ { "guard": "dim_is_periodic", "pvar": "x", "grid": "$g" },
                   { "guard": "var_has_grid", "pvar": "$u", "grid": "$g" } ],
      "replacement": { "op": "index", "args": ["$u",
          { "op": "mod", "args": [ { "op": "+", "args": ["$expr_i", "Nx"] }, "Nx" ] },
          "$rest" ] }
    }
  }
}
```

Under the `centered_2nd_uniform` scheme at `i = 0`, the neighbor index
`{op:"-", args:["i", 1]}` evaluates to `-1`; the periodic rule
rewrites the `index` node to wrap via `mod(i - 1 + Nx, Nx)`. At
`i = Nx - 1`, the `+1` neighbor wraps to `0`. Canonical-form output at
`i = 0` is:

```json
{ "op": "+",
  "args": [
    { "op": "*", "args": [
       { "op": "/", "args": [ -1, { "op": "*", "args": [ 2, "dx" ] } ] },
       { "op": "index", "args": [ "u",
           { "op": "mod", "args": [ { "op": "+", "args": [ { "op": "-", "args": ["i", 1] }, "Nx" ] }, "Nx" ] } ] } ] },
    { "op": "*", "args": [
       { "op": "/", "args": [  1, { "op": "*", "args": [ 2, "dx" ] } ] },
       { "op": "index", "args": [ "u",
           { "op": "mod", "args": [ { "op": "+", "args": [ { "op": "+", "args": ["i", 1] }, "Nx" ] }, "Nx" ] } ] } ] }
  ]
}
```

After canonicalization (§5.4) the double-wrapped form stays; the
canonicalizer does not collapse `mod(i-1+Nx, Nx)` to `Nx-1` symbolically
(that would require knowing `i = 0`, which is a per-equation lowering,
not canonicalization).

**Conformance fixture.** `tests/conformance/discretization/step1b/
rect_1d_advection_centered_periodic.esm` exercises this path end-to-end;
§13.1 Step 1b acceptance requires Julia + Rust bit-identical output.

### 9.3 Components as BC contributors

Per owner decision 3(c): a model-level component (deposition, emissions,
surface-flux scheme) declares a boundary-flux contribution as an entry in
the target model's `boundary_conditions` map, with `kind: "flux_contrib"`,
`contributed_by.component = "<its own name>"`, and a `value` AST that
references its local state and parameters. The rewrite engine sums all
`flux_contrib` entries for the same (variable, side) pair into a single
aggregated flux, then applies the enclosing `kind`'s BC template.

### 9.4 `produces`: emitting new equations

A rule may emit additional equations via `produces[k]`:

| `kind` | Meaning |
|---|---|
| `algebraic` | Emit the `emit`/`value` expression as an algebraic constraint (= 0). |
| `ghost_var` | Declare a new ghost-cell variable with indices; the rule body defines it. Ghost variables are local to the discretized output and are not visible to `free_variables` on the original continuous model (validation rule: loader must reject a pre-discretization `.esm` that references a `ghost_var`). **Naming discipline** (resolves gt-j6do open question 5): ghost variable names are **scheme-scoped** and MUST follow the pattern `<scheme_name>__<logical_name>__<side>` — double-underscore separated, where `<scheme_name>` is the containing `discretizations.<name>` key, `<logical_name>` is author-supplied (typically the variable being ghosted, e.g. `u`), and `<side>` is the BC side (`xmin`, `xmax`, `mesh_boundary`, …) or `interior` if the ghost is not side-specific. Two schemes declaring `ghost_u_xmin` collide unless the scheme names differ; the `<scheme_name>__` prefix makes collisions impossible at the spec level. The canonical on-wire form uses this naming; a scheme author who writes a bare `ghost_u_xmin` has it rewritten to `<scheme>__u__xmin` at loader time, with a warning. |

The v1 `state_var` option is **removed** from the MVP (resolves m9); there
was no compelling worked example. It can be re-added with a spec-version
bump if a use case surfaces.

## 10. Interaction with existing sections and migration

| Section | Interaction |
|---|---|
| `domains` | `boundary_conditions` **removed** (breaking — see §16 migration). `spatial.<dim>.grid_spacing` becomes advisory if a grid refines the domain (§6.1). |
| `models.<M>.domain` | Unchanged; still names a domain. A new optional field `models.<M>.grid` names a grid that refines that domain. |
| `models.<M>.boundary_conditions` | **New** first-class section (§9). |
| `models.<M>.equations` | Equations stay continuous. Discretization is an out-of-band operation (§11). |
| `data_loaders` | Extended with `kind: "mesh"` (§8.A). |
| `interfaces` | Unchanged. Regridding between domains continues to use `interfaces.<I>.regridding`. For grid-to-grid regridding *within* a rewrite, use the §5.3 `regrid` op. |
| `coupling` | **Extended** with a new optional field `coupling.<c>.regrid_method` (string from the §5.3 closed set). The coupling resolver uses this method when wrapping cross-grid references at §11 Step 4. If the field is absent and the coupling does not cross grids, behavior is unchanged; if absent and the coupling DOES cross grids, the loader emits `E_MISSING_REGRID_METHOD`. Cross-system coupling still refers to continuous variables; the discretized pipeline applies rules *post-coupling* (§11). |
| `variables.<name>` | Gains optional `shape` (list of dimension names) and `location` fields (spec §6.1 amendment below). |

### 10.1 Breaking-change summary (version 0.1 → 0.2)

1. `domains.<d>.boundary_conditions` **removed**. Pre-0.2 files carrying
   this field are invalid under the 0.2 schema. Migration rule in §16.
2. `variables.<name>` adds `shape` and `location` optional fields. Pre-0.2
   files without these remain valid (default: `shape: null` = scalar,
   `location: "cell_center"` when a grid is attached).
3. `data_loaders.<ℓ>.kind` accepts `"mesh"`. Pre-0.2 files without it are
   unaffected.
4. `coupling.<c>.regrid_method` (new optional field, v2.1 addenda §10 row)
   is additive; pre-0.2 files without it remain valid.

A file carrying `spec.version: "0.1"` is not loadable by a 0.2-only
binding; it must be migrated with the `spec.migrate_0_1_to_0_2` convention
described in §16.

### 10.2 Spec §6.1 amendment — inline

Add to the per-variable field table (spec §6.3 Variable Types):

| Field | Required | Description |
|---|---|---|
| `shape` | | List of dimension names (from the variable's domain's grid). A scalar has `shape: null` or omitted. Used by the discretization pipeline's output and validated by `index` in §5.1. |
| `location` | | Staggered location within the grid (e.g. `"cell_center"`, `"x_face"`, `"edge_normal"`). Default: `"cell_center"` if the variable's model has a `grid`, else omitted. Assignment of non-default `location` is the job of the spatialization tooling (see §11, m5). |

This amendment is part of this RFC's deliverable (§16), not a dangling
spec change.

## 11. Discretization as a pipeline

Given a model + grid + discretization + rules, a binding produces a
discretized ODE/DAE system via the following deterministic pipeline:

1. **Load and resolve** — parse the `.esm` file; resolve `ref` subsystems;
   validate against the schema. Reject files with `spec.version < "0.2"`
   unless the `spec.migrate_0_1_to_0_2` flag is present (§16).
2. **Tag locations** — for each variable on a model bound to a grid, assign
   a `location` (default `cell_center`; explicit overrides propagate).
   "Spatialization" here is the sub-phase that writes `location` onto
   previously-scalar variables; it is part of pipeline Step 2 (resolves m5),
   not an out-of-spec tooling concern.
3. **Expand metric generators** — for each metric array declared with
   `generator.kind = "expression"`, evaluate and cache the expression
   (cache scope: current process / session; §15 Q4 pins this). For
   `loader` or `builtin`, record the handle; do not materialize bulk data.
4. **Apply couplings** — resolve `coupling.<c>.variable_map.transforms`
   on continuous variables. After this step the equation system is on
   possibly-multiple grids. **The coupling resolver** is responsible
   for wrapping any cross-grid reference it emits in a `regrid` node,
   using the `coupling.<c>.regrid_method` field (§5.3 closed set). This
   is the one place where cross-grid wrapping is emitted during Step 4
   (resolves gt-adhm m6).
5. **Rewrite** — apply the rule engine (§5.2) to every equation in
   `models.*` and to every entry of `models.*.boundary_conditions`. Emit
   additional equations from `rules[*].produces`. **The rule engine**
   is responsible for wrapping any cross-grid `index` expression it
   emits (e.g. a scheme's cross-grid stencil reference) in a `regrid`
   node with `method` supplied by the emitting selector (§5.3,
   §7.2). A rule that emits a cross-grid reference without a `regrid`
   wrapper is a scheme bug and MUST be flagged by the loader's validator
   with `E_MISSING_REGRID`.
6. **Canonicalize** — apply §5.4 canonical form to every emitted AST.
7. **Check rule coverage** — for every equation, if `models.<M>.grid` is
   set and the post-rewrite AST still contains a PDE operator on a gridded
   variable (resolves review Q3, decision 7):
   - Error by default with code `E_UNREWRITTEN_PDE_OP`.
   - If the equation (or boundary_condition) has `passthrough: true`, skip.
     `passthrough` is a new boolean field on equations and BCs; it is
     authorial opt-in and must be paired with a note in the file describing
     why.
8. **Collect** — the output is a set of equations over `index`-addressed
   variables plus the original scalar variables, ready to be handed to the
   host-language ODE/DAE assembler.

Step 8 output is still ESM-representable: it is a `models` entry with
arrayed variables (per §10.2 shape) plus algebraic constraints, no new
node types introduced. A `discretized: true` boolean on the output model
is the only metadata change.

## 12. DAE support and binding contract (resolves review Q5, decision 6)

If the rewrite produces an equation with `produces: algebraic`, the
resulting system is a DAE, not an ODE. A binding that receives a
discretized model containing algebraic equations **must** either:

(a) hand the system to a DAE assembler (MTK for Julia; SUNDIALS/IDA or
Diffrax's DAE modes for Python; diffsol for Rust; TBD for Go/TS), or

(b) abort with error code `E_NO_DAE_SUPPORT` and a message identifying
the binding and the algebraic-equation-producing rules. Silent omission
of constraints, or demotion of an algebraic constraint to an ODE residual,
is **non-conforming**.

Spec-level contract: if a binding advertises discretization support without
DAE support, that is the binding's bug, not the model author's problem.
Each binding's documentation must state its DAE assembler. The
per-binding strategies table (direct hand-off vs deferred/stubbed),
the default enable state, and each binding's disable knob are
catalogued centrally in [`dae-binding-strategies.md`](./dae-binding-strategies.md)
so that a model author can find out in one place what will happen
with their mixed-DAE `.esm` under each binding.

**Error code pinned.** The error code name is exactly
`E_NO_DAE_SUPPORT` (upper-case, ASCII, with a single underscore between
each word). Bindings MUST emit this exact string, not a paraphrase.

**Conformance test (resolves gt-j6do New M5 / bead F10).** The
conformance harness ships fixtures under
`tests/conformance/discretization/dae_missing/` (underscore, to match
the `infra/rule_engine/` sibling). The minimum set includes
`mixed_dae_observed.json` — a model with one differential equation
plus one authored algebraic (observed-equation) constraint — and
`pure_ode_baseline.json` — a pure-ODE baseline that guards against
false-positive `E_NO_DAE_SUPPORT` emission. A later fixture will
exercise rules with `produces: algebraic` once that mechanism lands
(RFC §13.1 Step 1b+). The harness:

1. Loads the fixture under each binding with DAE support enabled —
   expects the binding to produce a DAE-assembled system and return
   exit code 0.
2. Loads the fixture under each binding with DAE support
   **explicitly disabled** (via an env var or a binding-specific flag
   that each binding documents) — expects the binding to emit exit
   code ≠ 0 and an error message containing the string
   `E_NO_DAE_SUPPORT`.
3. **Silent success (exit code 0 with no DAE assembly) is a test
   failure.** Demotion of an algebraic constraint to an ODE residual
   is also a test failure — the harness inspects the binding's emitted
   system (via a binding-provided introspection verb) and asserts the
   algebraic equations are present as constraints, not as ODE terms.

Binding coverage: Julia and Rust MUST implement both the success and
the disabled-DAE paths. Python and TS MAY stub the DAE-success path
(return `E_NO_DAE_SUPPORT` always) in v0.2.0; they MUST still emit
the exact error code on the failure path. Go implements a
**trivial-factor** strategy (see `dae-binding-strategies.md`): it
symbolically substitutes and removes `y ~ f(...)` observed-style
algebraic equations where `y` does not appear in `f`, classifies the
result as `"ode"` when no algebraic equation remains, and aborts with
`E_NONTRIVIAL_DAE` (not `E_NO_DAE_SUPPORT`) otherwise. Bindings that
gain DAE support in subsequent minor versions extend the success-path
coverage without a spec change.

## 13. Conformance

The conformance harness (`CONFORMANCE_SPEC.md`) gains a new fixture class
`tests/conformance/discretization/`. Each fixture is an input `.esm`
(model + grid + discretizations + rules) plus a canonical discretized
`.esm` output. Each binding must produce byte-identical output after the
§5.4 canonical form is applied by the harness.

Because coefficients are kept symbolic and §5.4 defines a normative normal
form, bit-identity across bindings reduces to AST equality after
canonicalization. This closes the gap identified in review C3.

### 13.1 Rollout — 3 steps with acceptance criteria

Each step lands reference implementations in **at least Julia + Rust** and
extends the conformance harness such that Julia and Rust emit bitwise-
identical discretized expressions (post-canonicalization).

#### Step 1 — Infrastructure (new; absorbs prior Step 1 + review M8)

**Scope.** Everything Step 2 onwards depends on:

- `index` extension for out-of-`arrayop` contexts in all five bindings
  (§5.1).
- Pattern-match / rule engine in all five bindings (§5.2).
- `regrid` AST op in all five bindings (§5.3).
- Canonical AST form in all five bindings (§5.4).
- Arrayed-variable schema: `shape`, `location` on `variables.<name>` (§10.2).
- Model-level `boundary_conditions` section (§9).
- `passthrough` annotation on equations / BCs (§11).
- `rules.max_passes` model-level override (§5.2.5).
- Migration tooling: the `spec.migrate_0_1_to_0_2` convention (§16), with
  a command-line verb `esm migrate` in each binding that performs the
  BC relocation rule.
- A schema-migration fixture test (bead filed as follow-up to gt-yx9y)
  with at least three input files carrying `domains.<d>.boundary_conditions`
  and their expected 0.2-form equivalents.

**Acceptance (extended per gt-j6do New M2):**

- All five bindings parse, canonicalize, and serialize every fixture in
  `tests/conformance/discretization/infra/` to the byte-identical canonical
  form.
- `esm migrate` on the three schema-migration fixtures produces expected
  output (tests/conformance/migration/0_1_to_0_2/*).
- **Rule-engine exercise.** Fixtures under
  `tests/conformance/discretization/infra/rule_engine/` load a trivial
  rule (e.g. `{pattern: {op:"+", args:["$a", 0]}, replacement: "$a"}`)
  plus a seed AST, and assert that all five bindings produce the
  expected post-rewrite AST byte-identically. At least three fixtures:
  a pattern that matches once, a pattern that fixed-points, and a
  pattern that hits `E_RULES_NOT_CONVERGED` at `max_passes = 3`.
- **`regrid` canonicalization exercise.** A fixture under
  `tests/conformance/discretization/infra/regrid/` contains a `regrid`
  node with `method: "bilinear"`; all bindings must round-trip it
  through canonicalization without mutation and must reject
  `method: "unknown"` with `E_UNKNOWN_REGRID_METHOD`.
- **`passthrough` annotation exercise.** A fixture under
  `tests/conformance/discretization/infra/passthrough/` contains a
  gridded equation still carrying `grad`; with `passthrough: true`,
  all bindings pass the rule-coverage check; without it, all bindings
  emit `E_UNREWRITTEN_PDE_OP`.
- **Canonical form — numeric-literal fixtures** (resolves gt-j6do New C1
  / gt-adhm C1). Fixtures under
  `tests/conformance/discretization/infra/numbers/` assert byte-
  identical serialization of: integer-valued floats, shortest-round-trip
  floats, subnormals, negative zero. A fixture containing NaN or Inf
  MUST be rejected with `E_CANONICAL_NONFINITE`.
- No `discretizations` / `grids` / model-equation-rewrite fixtures are
  exercised yet — Step 1 ships only the infrastructure (rule engine,
  canonicalizer, migration tool, schema additions). Scheme work begins
  in Step 1b.

#### Step 1b — Rectangular grids, first scheme set (absorbs prior Step 1 schemes)

**Scope:** `cartesian` family, uniform spacing, periodic BCs. Centered and
upwind stencils for `grad` and `laplacian`.

**Acceptance:**
- Julia binding reproduces the `ArrayDiscretization` output captured as
  fixtures in `tests/conformance/discretization/rect_1d_*.esm` and
  `rect_2d_diffusion_5point_periodic.esm`. These fixtures were produced
  once from MethodOfLines.jl PR #531 at commit SHA pinned in the fixture
  header; subsequent upstream changes to that PR do not invalidate the
  fixtures (resolves M7).
- Rust binding emits bit-identical canonical AST.
- Python, Go, TS bindings: `index`-extension and rule-engine already
  present from Step 1; need not emit discretized output yet, but must
  round-trip the fixtures without loss.

The MVP fixtures are:

- `rect_1d_advection_centered_periodic.esm`
- `rect_1d_advection_upwind_periodic.esm`
- `rect_2d_diffusion_5point_periodic.esm`

#### Step 2 — Dirichlet / Neumann / Robin BCs

**Scope:** Model-level `boundary_conditions`. BC rewrite rules with `emit`
(or `value`) + `produces`. Ghost-cell `produces` variant. Time-dependent
BCs from loaders (§8.A.3). Auto scalar→indexed metric rewrite for
non-uniform spacing (§6.2.1) — this folds in what v1 called Step 3.

**Acceptance:**
- All three BC kinds on a 1D diffusion problem match an analytic reference
  to 1e-12 per cell in a Julia runtime solve.
- Conformance harness gains fixtures (Dirichlet at xmin, Neumann at xmax,
  Robin at both sides, mixed, SST-forced Dirichlet from a loader). Julia
  + Rust bit-identical.
- A non-uniform 1D diffusion fixture on a stretched grid (geometric
  progression) round-trips Julia → ESM → Rust bit-identical.

#### Step 3 — Unstructured neighbor + reduction selectors (MPAS)

**Scope:** `unstructured` family. `indirect` and `reduction` selectors.
`connectivity` tables. `kind: "mesh"` data loader (§8.A). Scheme set:
MPAS edge-gradient + cell-divergence (§7.3).

**Acceptance:**
- An icosahedral-mesh diffusion problem is discretized from
  `.esm` + an MPAS mesh loader and solved; Julia + Rust emit bit-identical
  canonical AST.
- Full MPAS `x1.2562` mesh loads and the discretization step completes
  without error in both Julia and Rust (solve step not required in CI).

## 14. Risks and open questions

1. **Pattern-matcher vocabulary.** §5.2.4 ships a closed guard list. Known
   limitations (review m6), explicitly acknowledged as out of MVP:
   - Negation guards.
   - Constant-folding guards (is-numeric-literal).
   - Arity guards (n-ary vs. binary `+`).
   - Structural guards (subtree-contains).
   These can be added with a minor spec version bump once scheme authors
   demonstrate the need.
2. **Rule ordering.** Deterministic top-down fixed-point (§5.2.5) is
   adequate for the current schemes. If two rules legitimately match the
   same subtree, the first-listed rule wins; authors can reorder to express
   priority explicitly. Non-convergence aborts with `E_RULES_NOT_CONVERGED`.
3. **Ghost-cell lifetime.** `produces: ghost_var` declares a variable that
   exists only in the discretized system; the loader must reject a pre-
   discretization `.esm` that references a `ghost_var` (§9.4). This is a
   validator rule, shipped in Step 1.
4. **Loader determinism.** Mesh loaders expose a `determinism` block
   (§8.A). Bindings that cannot guarantee the declared endian / format /
   integer width must reject at load.
5. **Cache scope.** Expression-kind metric generators cache per-session
   within the rewriting binding (resolves review Q4). Cross-session
   caching is a runtime concern and is not part of the spec.
6. **ODE/DAE assembler coverage.** Per §12, each binding must declare its
   DAE assembler or reject algebraic-producing rewrites (resolves review
   Q5). This is a binding-documentation requirement, not a spec gap.
7. **Spec-version gate.** The RFC is a breaking change (0.1 → 0.2) but
   Steps 2 and 3 extend 0.2 additively within 0.2.x. Step 1 lands the
   0.2.0 release; subsequent steps roll in as 0.2.x minor versions.

## 15. Why not alternatives

### 15.1 MLIR / StableHLO as the discretized IR

**Rejected.** MLIR is a compiler IR; emitting it as a sibling format would
either (a) double the authoring surface (`.esm` for continuous, `.mlir` for
discretized) — violating §1 goal 5 — or (b) require the `.esm` AST to
embed MLIR textual payloads, pushing round-trip fidelity onto every binding
and re-introducing the "math parser" dependency §4 of the base spec forbids.
Additionally, MLIR's dialect space is a moving target; pinning to a dialect
would couple ESM's stability to LLVM's release cadence. We prefer the
in-format `arrayop` lowering (§7.3) for MPAS because it reuses the existing
AST and stays diff-friendly.

### 15.2 SymPy Wild / Replacer DSL

**Rejected as an on-wire format; subset borrowed for §5.2.** SymPy's
`Wild`/`Replacer` has well-tested semantics and arguably richer guards
than the RFC's closed vocabulary (§5.2.4). But Wild/Replacer is not
serializable without a Python runtime, and several of its features (AC
matching, non-commutative Wild) are precisely the features §5.2.3 rejects
for cross-binding determinism. The RFC's pattern language *is* a subset of
SymPy's Replacer, intentionally: binding-authors who want richer matching
can compose multiple rules, at the cost of verbosity — not at the cost of
cross-binding divergence.

### 15.3 OpenFOAM `fvSchemes` as the architectural analog

**Partially accepted; see §8 `data_loaders` and §9 BC scheme contributions.**
Review gt-tlw2 is right that OpenFOAM's field-operator formalism is the
closest architectural analog: `fvc::grad(p)` with the scheme chosen from
`fvSchemes`, plus stored boundary conditions on the mesh, is a near-mirror
of `{grid, discretizations, rules}` with model-level `boundary_conditions`.
The RFC differs from OpenFOAM in three deliberate ways:

1. **Declarative, not callable.** `fvc::grad` is a C++ function that
   resolves at link time against a scheme library. ESM rules are data; a
   `.esm` file carries the rule binding explicitly, so the same file runs
   under any conforming binding. This is the cross-language commitment
   from §1.
2. **Symbolic coefficients, not runtime arrays.** OpenFOAM's schemes
   materialize matrix coefficients numerically; ESM's schemes emit
   symbolic AST and defer numerics to the ODE/DAE assembler. This is
   what lets §13 demand bit-identity.
3. **Grid families are closed; schemes are open.** OpenFOAM's
   `fvSchemes` assumes a polyhedral FV mesh. ESM declares its grid
   families up front (cartesian, unstructured) and closes
   that list at v0.2; new families require a spec version bump. This
   trades OpenFOAM's flexibility for cross-binding testability.

Authors coming from OpenFOAM should find ESM's authoring surface familiar.
The RFC's choice to model schemes as data (rather than library hooks) is
the specific departure.

### 15.4 `makearray + single arrayop` compression

**Rejected for the general case, accepted for reductions (§7.3).**
Review gt-tlw2 correctly notes that the v1 rejection of "fully-materialized
arrayop" was too strong. For *rectangular* interior regions the output
compresses to a single `makearray` with one `arrayop` body — O(1) file
size. But boundary regions (ghost cells, side-specific rules) require
region-specific rewrites; a single arrayop per region is necessary.
The MVP keeps interior regions as per-cell expressions (consistent with
MOL PR #531's output) and uses `arrayop` for reductions (§7.3). A later
optimization pass could collapse identical per-cell forms into `makearray`
without any schema change — this is a runtime/binding concern and out of
scope for v0.2.

### 15.5 Reuse the existing `operators` section as opaque transforms

**Rejected.** Spec §9 `operators` registers opaque, binding-specific
transforms with only an input/output descriptor. Using it for
discretization would satisfy §1 goal 5 (no second format) but fail goal 3
(bit-identical output): the transform is a runtime box, not a data-level
spec, so two bindings can legitimately produce different ASTs. This is
the status-quo-plus option the RFC set out to replace.

### 15.6 Status quo (runtime side-effect)

**Rejected by the architectural goal.** Every non-Julia binding currently
cannot round-trip discretized PDEs; this RFC exists because that gap is
blocking.

### 15.7 Introduce a second file format for discretized systems

**Rejected.** Every additional format is a perennial cross-language-drift
liability; this is the mistake §15.1 would make in a different dialect.

## 16. Deliverable checklist

This RFC is the deliverable of gt-dq0f (v1) and gt-yx9y (v2 revision).
Implementation work is tracked separately under the 3-step rollout. On
acceptance of this RFC:

- `spec.version` bumps to `0.2.0-draft` on the branch that lands Step 1,
  and to `0.2.0` on merge of Step 1 to main.
- `esm-schema.json` gains JSON-schema entries for:
  - `grids` section (per §6)
  - `discretizations` section (per §7)
  - `rules` section (per §5.2 and §9)
  - Extended `index` contexts (per §5.1)
  - `regrid` op (per §5.3)
  - `variables.<name>.shape` and `.location` (per §10.2)
  - Model-level `boundary_conditions` (per §9)
  - `data_loaders.<ℓ>.kind: "mesh"` (per §8.A)
  - `rules.max_passes`, `passthrough` flags (per §5.2.5, §11)
  - `coupling.<c>.regrid_method` (v2.1 addenda; closed set per §5.3)
  - Closed `regrid.method` enum per §5.3 (v2.1 addenda)
- `esm-spec.md` gains:
  - A new top-level section §16 "Discretization" that cross-references
    this RFC for rationale and §6/§7/§5 for normative grammar.
  - Inline §6.1 amendment adding `shape` / `location` fields to variables.
  - Inline §8 amendment adding `kind: "mesh"` to data loaders.
  - **Removal** of §11.5 `boundary_conditions` from the `domains` schema.
- `CONFORMANCE_SPEC.md` gains:
  - `discretization/` fixture class (per Steps 1b–4).
  - `migration/0_1_to_0_2/` fixture class for the breaking change.
- A new **migration tool** per binding, invokable as `esm migrate
  <infile.esm> <outfile.esm>`, that applies the `spec.migrate_0_1_to_0_2`
  convention (below).
- A follow-up bead (to be filed) for a schema-migration fixture-test suite
  under `tests/conformance/migration/` with at least three input fixtures.

### 16.1 The `spec.migrate_0_1_to_0_2` convention

A file carrying `spec.version: "0.1"` is migrated to `0.2` by applying:

1. **BC relocation.** For each `domains.<d>.boundary_conditions[k]`:
   - Find every `models.<M>` with `models.<M>.domain == "<d>"`.
   - For each such model and each variable whose domain includes the BC's
     `side`, emit a `models.<M>.boundary_conditions["<auto-key>"]` entry
     with `variable`, `side`, `kind`, and `value`/`robin_*` copied from
     the domain-level entry.
   - Delete `domains.<d>.boundary_conditions`.
2. **Bump version.** Set `spec.version = "0.2.0"`.
3. **Add marker.** Set `spec.migrated_from = "0.1"` for provenance (loaders
   must preserve this field on subsequent saves).

The migration is 1-to-1 per (domain-BC × applicable variable). If a single
domain-level `periodic` BC applies to five models, it fans out to five
model-level entries; this is intentional (explicit per-model BC makes the
eventual rewrite rules straightforward).

A binding may expose the migration as a one-off verb (`esm migrate`) or
fold it into its loader for `version < 0.2` files. The canonical output
of the migration is defined by Step 1 fixtures (`tests/conformance/
migration/0_1_to_0_2/`), so all bindings migrate to the same byte form.

## 17. Review response

This section summarizes how v2 addresses the critical and major review
findings in `docs/rfcs/discretization-review.md`, so a second reviewer can
diff quickly.

**Critical issues:**

- **C1 (idx vs index).** Resolved: `idx` dropped; §5.1 extends `index`
  contexts and documents composite index expressions and non-`arrayop`
  resolution semantics.
- **C2 (BCs duplicate domain BCs).** Resolved: §9 introduces model-level
  `boundary_conditions`; §10.1 documents removal of
  `domains.<d>.boundary_conditions` as a breaking change; §16.1 gives
  the migration rule.
- **C3 (canonical form missing).** Resolved: §5.4 defines canonical form
  normatively (argument ordering, n-ary flattening, zero/identity
  elimination, integer/float non-promotion, string-vs-number canonical).
  A worked example and byte-exact output is given. §13 acceptance
  explicitly tests post-canonicalization bit-identity.
- **C4 (metric loader refs a nonexistent extension).** Resolved: §8
  amendments (§8.A) extend `data_loaders` with `kind: "mesh"` inline, so
  Step 3 acceptance is provable.
- **C5 (pattern-match semantics underspecified).** Resolved: §5.2.1
  defines binding classes per position; §5.2.2 pins non-linear patterns
  to post-canonicalization AST-equality; §5.2.3 rejects AC matching and
  explains why; §5.2.4 enumerates legal sibling-field positions; §5.2.5
  picks termination rule (i) with a pass budget. §5.2.6 ships a one-page
  worked example.

**Major issues:**

- **M1 (scalar dx vs dx[i]).** Resolved: §6.2.1 option (b) — engine
  auto-rewrites scalar metric refs to `index` when `spacing: "nonuniform"`.
- **M2 (MPAS variable-valence).** Resolved: §4 + §7 add the `reduction`
  selector; §7.3 ships a worked MPAS divergence that lowers to `arrayop`.
- **M3 (`$e` target binding).** Resolved: §7.1.1 defines `$target` and
  its components per grid family; `$e` for edge-operand schemes is an
  implicit alias for `$target`.
- **M5 (time-dependent loader BCs).** Resolved: §8.A.3 specifies the
  mechanism end-to-end; `t` is explicit, face coords declared via
  `face_coords` on the BC entry.
- **M6 (arrayed variables have no schema).** Resolved: §10.2 adds
  `shape` and `location` to `variables.<name>` inline.
- **M7 (PR #531 moving target).** Resolved: §13 Step 1b captures outputs
  as fixtures and states acceptance as "fixtures pass"; PR #531 cited as
  origin of the initial fixture set, not an ongoing pin.
- **M8 (rollout skipped infrastructure).** Resolved: §13 rewritten. Step 1
  is pure infrastructure (rule engine, canonical form, index extension,
  arrayed-variable schema, BC-op schema, migration tooling). Step 1b is
  the first scheme set. Steps 2 and 3 follow.

**Minor issues:**

- **m1 (`grid_spacing` duplication).** Addressed in §6.1: domain-level
  field becomes advisory when a grid refines the domain.
- **m4 (guard name inconsistency).** Addressed: renamed to
  `dim_is_spatial_dim_of` (§5.2.4).
- **m5 (spatialization responsibility vague).** Addressed in §11
  pipeline Step 2.
- **m6 (closed vocabulary risks).** Addressed in §14 risk 1 as a
  known-limitations list.
- **m7 (CSV loader by name).** Addressed: §13 Step 2 fixtures do not
  promise a CSV loader; the `loader:` form points to whatever loader the
  fixture declares (`zlev_csv` in §6.2 is an authored loader name, not a
  schema-reserved one).
- **m8 (two-stage matching).** Clarified in §7.1: a rule fires first; a
  scheme's `applies_to` is matched against the rule's `$u` / `$target`
  binding at expansion time. There is no second pass of rule matching
  against `applies_to`.
- **m9 (`produces: state_var`).** Removed from MVP (§9.4).

**Review questions:**

- **Q1 (nested scheme determinism).** §5.2.5 termination rule (i): a
  rewritten subtree is not re-matched in the same pass. Cross-pass
  ordering is top-down each time. This gives determinism.
- **Q2 (schema-validation reach).** §16 deliverable explicitly enumerates
  the JSON-schema additions. Rule-cycle detection, pattern-variable
  scoping, and grid/scheme compatibility are loader-side validations
  beyond what JSON Schema can encode.
- **Q3 (rule miss behavior).** §11 Step 7 errors by default;
  `passthrough: true` opts out.
- **Q4 (output caching).** §14 risk 5: per-session, within the rewriting
  binding.
- **Q5 (DAE interop assumption).** §12 pins the binding contract: DAE
  assembler or explicit error.
- **Q6 (coupling × rewrite).** §11 Step 4 runs coupling before rewrite;
  §5.3 `regrid` wraps cross-grid references.

### 17.1 v2.1 addenda — resolution of dual-review findings (gt-j6do + gt-adhm)

v2.1 applies targeted fixes on top of v2 per the dual review of v2
(brahmin self-review `discretization-review-v2.md` and ghoul parallel
review `discretization-review-v2-parallel.md`). All edits land in place;
the spec version stays at 0.2.0. Each fix below cites the review
findings it resolves and the section(s) that carry the normative text.

**Blocking fixes (F1–F10 from gt-woe1):**

- **F1 — §7.3 MPAS worked example.** Two independent bugs closed in a
  single pass:
  - Arrayop schema now conforms to base-spec §4.3.1 (`output_idx: []`,
    `[start, stop]` ranges, string `reduce`, explicit `args` list).
    Resolves gt-j6do **New C2**. §7.3 now carries a self-validation
    note requiring the conformance fixture to assert JSON-schema
    validation against the base-spec `arrayop`.
  - `$target` chooser for unstructured grids now reads "emits_location
    if set, else operand's location" (§7.1.1). §7.3 conforms:
    `emits_location: cell_center` → `$target = c`. Every `index`
    reference inside the expanded `arrayop` uses connectivity tables
    (`index(edgesOnCell, c, k)`) rather than bare `$target` for edge
    operands. Resolves gt-adhm **C2**.

- **F2 — §5.4.6 normative JSON number formatting.** New subsection
  adopts RFC 8785 JCS (<https://datatracker.ietf.org/doc/html/rfc8785>
  §3.2.2.3) as the canonical number format. Adds explicit rules for
  integer-valued floats, shortest round-trip non-integer floats,
  subnormals, negative zero, and NaN/Inf (forbidden in canonical form;
  `E_CANONICAL_NONFINITE`). Preserves §5.4.1's integer/float node
  distinction. **Superseded in part by v2.2 §17.2:** the
  integer-valued-float on-wire rule changed from "emit as `1`" to
  "emit as `1.0`" to close the round-trip gap. See §5.4.6 and §17.2
  for the current normative text. Resolves gt-j6do **New C1** and
  gt-adhm **C1**; gap closed by gt-h9kt.

- **F3 — §7.1.1 `$target` chooser + dim→component mapping.** Adds
  the emits-location-first rule for unstructured grids; adds the
  cartesian dim-name → component-letter mapping by `dimensions.indexOf`;
  extends the reserved-letter table to five cartesian dimensions
  (`i, j, k, l, m`); documents `k_bound` as a second in-scope index
  introduced by `reduction` selectors; clarifies `dim` overloading
  on unstructured grids (gt-adhm M7). Resolves gt-j6do **new-m7**
  and gt-adhm **C2, C3, M4, M7**.

- **F4 — §7.2.1 scheme `applies_to` vs rule `pattern` protocol.** New
  subsection pins the five-step expansion protocol: rule match →
  scheme selection → `applies_to` guard check → name-aligned binding
  flow → expansion. `applies_to` is guard-only, not a rebinder;
  mismatch raises `E_SCHEME_MISMATCH` at rewrite time. Pattern variables
  flow by name; missing bindings are errors, not implicit renames.
  `applies_to` depth is fixed at 1. Resolves gt-adhm **C4** and
  gt-j6do **new-m6, m8**.

- **F5 — §5.2.5 post-rewrite walker.** Pinned to option (a): rewritten
  subtrees are sealed for the remainder of the current pass; the
  walker does not descend into them, nor re-attempt any rule at the
  rewritten node, until the next pass begins at the root. Options (b)
  and (c) are explicitly non-conforming. Cross-pass re-entry is
  permitted. Adds `max_passes = 32` justification (2× the deepest
  MVP scheme chain) and the `rules` ordering rule (insertion order;
  array form also permitted). Resolves gt-adhm **C5** and gt-j6do
  **open question 4, m7**.

- **F6 — §5.4.7 canonicalization for `-`, `/`, unary `neg`.** New
  subsection. Binary `-` and `/` kept as distinct non-commutative
  ops; args order preserved; no flattening; identity rules enumerated.
  Unary negation canonicalized as `{op:"neg", args:[x]}`; numeric
  literals absorb the sign. No new AST ops. Resolves gt-adhm **M6**.

- **F7 — §5.3 / §7.2 `regrid.method` closed set.** `method` now
  validates against a closed enum (`"nearest"`, `"bilinear"`,
  `"conservative"`) with normative semantics.
  Unknown methods raise `E_UNKNOWN_REGRID_METHOD` at load.
  Emitter discipline pinned: couplings supply method via new
  `coupling.<c>.regrid_method` field; authored literals validate at
  parse. Resolves gt-adhm **M1** and gt-j6do **open question 3**.

- **F8 — §9.2.1 worked periodic-BC example.** New subsection. Periodic
  declared once at the canonical side (xmin); the pair is implicit.
  Includes a 1D advection fixture, the periodic-wrap rule (using
  `replacement`, not `use`), and the canonical-form output at
  `i = 0` with `mod(i - 1 + Nx, Nx)`. Resolves gt-adhm **M2**.

- **F9 — §13.1 Step 1 rule-engine acceptance.** Acceptance extended
  from "parse/canonicalize/serialize" to include rule-engine exercise
  (three fixtures: single match, fixed-point, non-convergence),
  `regrid` canonicalization + unknown-method rejection,
  `passthrough` behavior, and numeric-literal corner cases
  (integer-valued float, shortest round-trip, subnormals, negative
  zero, NaN/Inf rejection). Resolves gt-j6do **New M2**.

- **F10 — §12 DAE-abort conformance test.** Error code pinned as
  exactly `E_NO_DAE_SUPPORT`. Conformance test under
  `tests/conformance/discretization/dae-missing/` exercises both the
  success path (DAE enabled) and the disabled path (exit ≠ 0 with
  the error string). Silent success and constraint demotion are
  explicit test failures. Binding coverage: Julia/Rust must implement
  both paths; Python/Go/TS may stub the success path but must emit
  the exact error on the failure path. Resolves gt-j6do **New M5**.

**Editorial cleanup rolled in:**

- §9.4 ghost-variable naming discipline (scheme-scoped,
  `<scheme>__<logical>__<side>`). Resolves gt-j6do **open question 5**.
- §5.2 rule-field table adds `use`, `produces`, and `region`; defines
  `region` as advisory. Resolves gt-j6do **new-m2, new-m3, new-m4**.
- §5.4.9 comparator-memoization implementation note. Resolves gt-adhm **m1**.
- §5.4.4 zero-elimination iterates across integer and float zeros
  together. Resolves gt-adhm **m3**.
- §11 Step 4 / Step 5 pin **where** `regrid` wrapping happens
  (coupling resolver vs rule engine). Resolves gt-adhm **m6**.
- §5.2.5 `max_passes = 32` justified (2× deepest MVP scheme chain).
  Resolves gt-adhm **m7**.
- §10 `coupling.<c>.regrid_method` added; §10.1 extended; §16 deliverable
  list extended accordingly.

**Findings explicitly deferred to later minor versions:**

- gt-j6do **New M1** (three mesh-loader field paths) — addressed by
  documentation, not schema collapse; a `mesh_fields` unification is a
  minor-bump candidate in 0.2.x.
- gt-j6do **New M3** (per-op `args` leaf-vs-subtree table for
  `grad`/`div`/`laplacian`) — convention continues to be "leaf-class
  on calculus ops"; an explicit table lands with the next rule-engine
  amendment.
- gt-j6do **New M4** (loader `determinism.temporal_interpolation`) —
  in scope for Step 2 when time-varying loader BCs land.
- gt-j6do **New M6** (shape-mismatched couplings) — in scope for
  Step 2/Step 3 when cross-grid couplings are authored.
- gt-j6do **new-m1** (≥4D cartesian component names beyond `i, j, k,
  l, m`) — deferred; current v2.1 caps at 5 dimensions.
- gt-adhm **M3** (extended bare-string resolution for `face_coords` /
  `independent_variable`) — spec text already allows this in §8.A.3
  and §9.2; a §5.1 enumeration update will land with the Step 2
  schema additions.
- gt-adhm **M5** (axis-specific schemes vs axis-parameterized metric
  lookup) — continue the one-scheme-per-axis convention in v0.2.0;
  an axis-parameterized metric op is a 0.3 candidate.
- gt-adhm **M8** (Python/Go/TS Step 2–4 disposition) — §13.1 Step 2
  acceptance language to be refined when Step 2 fixtures are authored.

---

### 17.2 v2.2 addendum — §5.4.6 on-wire int/float disambiguation (gt-h9kt)

Scope: single-subsection normative clarification. No schema change, no
new fields, no AST shape change.

**The gap.** v2.1's §5.4.6 adopted RFC 8785 JCS verbatim. Under JCS
(via ECMAScript `ToString(Number)`), an integer node with value `1`
and a float node with value `1.0` both serialize to the string `1`.
§5.4.1 mandates that integer and float are distinct AST nodes, but the
v2.1 on-wire form silently collapses them — on parse-back, the original
node kind is unrecoverable. This breaks the canonical-form round-trip
invariant the opening paragraph of §5.4 requires.

**The fix.** v2.2 adds one normative override to JCS: an integer-valued
float whose shortest-round-trip form is bare-integer-looking receives
a trailing `.0`. Float `1.0` → on-wire `1.0`; integer `1` → on-wire
`1`. Exponent-form emissions (e.g. `1e25`, `5e-324`) already contain
`e` and are unambiguously float under the JSON integer grammar, so no
suffix is added there.

**Complementary parse rule.** §5.4.6 now also pins the parse-side rule:
a JSON number token containing `.` or `e`/`E` is a float node;
otherwise it is an integer node. Together, the emit override and the
parse rule close the round-trip loop (`canonicalize(parse(emit(A)))
== A` byte-for-byte, for every canonical AST `A`).

**Alternatives considered.**

- **Explicit type tag** (`{"type":"int","value":1}` vs
  `{"type":"float","value":1}`). Unambiguous, but every numeric leaf
  grows from a bare JSON number to a 3-key object. Verbose, and
  inflates on-wire size for the 99% case where the type tag is
  implicit in the token shape. Rejected.
- **Abandon the int/float distinction** (collapse to a single numeric
  node type, everything is float). Simpler wire form, but breaks
  §5.4.1 and forces bindings that model integer arithmetic (Julia
  `Int64`, Go `int64`) to round-trip through `Float64`, with loss for
  magnitudes `> 2^53`. Rejected.
- **Trailing `.0` override (chosen).** Minimum diff. Keeps the compact
  on-wire form (bare JSON number). Preserves the §5.4.1 node
  distinction without a schema change. Narrowly scoped override of a
  single JCS rule; every other JCS output is adopted verbatim.

**Affected conformance surface.**

- §13.1 Step 1 acceptance (F9 in §17.1) already requires
  integer-valued-float corner cases. Under v2.2 the expected on-wire
  for `float(1.0)` is `1.0`, not `1` — binding fixtures drafted
  against v2.1 must be updated before Step 1 lands. A normative inline
  fixture table is embedded in §5.4.6; a materialized fixture directory
  `tests/fixtures/canonical_numbers/` is a deliverable for Step 1.
- §5.4.2 byte-comparator: no behavior change. The comparator sorts by
  byte-string of the canonical JSON serialization, which now includes
  the `.0` for integer-valued floats. Float `1.0` and integer `1`
  now sort to different byte strings (`"1.0"` vs `"1"`), reinforcing
  §5.4.1's "integer before float at equal magnitude" rule — the
  comparator rule already handled this at the AST-kind level; the
  wire form now mirrors it.
- §5.4.8 worked example: integer-only; unaffected.

**Error codes.** No new error codes. A binding that emits `1` for a
float node or `1.0` for an integer node is non-conforming under
§13.1 Step 1 and fails the canonical-round-trip test.

*End of v2.2 addendum.*

---

*End of v2.2.*
