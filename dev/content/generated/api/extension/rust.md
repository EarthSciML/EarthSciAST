---
title: "Rust extension seams"
description: "Rust's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

The interiors of these public modules are extension seams too: `earthsci_ast::adapter_support`, `earthsci_ast::compiled_rhs_adapter`, `earthsci_ast::compiler_agreement_adapter`, `earthsci_ast::esio_provider`, `earthsci_ast::extension`, `earthsci_ast::inline_tests_adapter`, `earthsci_ast::intern`, `earthsci_ast::operator_refs`, `earthsci_ast::precision`, `earthsci_ast::precision_infer`, `earthsci_ast::provider`, `earthsci_ast::simulate_array`, `earthsci_ast::wasm`, `earthsci_ast::xla_runtime`.

161 names.

### `add_model` {#x-add_model}

*function* · canonical name `add_model`

```rust
pub fn add_model(esm_file: &EsmFile, model_id: &str, model: Model) -> EditResult<EsmFile>
```

Add a new model to an ESM file

**Arguments**

* `esm_file` - The ESM file to modify
* `model_id` - Unique identifier for the new model
* `model` - The model to add

**Returns**

* `EditResult<EsmFile>` - New ESM file with the added model

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L85) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_model.html)

### `add_reaction_system` {#x-add_reaction_system}

*function* · canonical name `add_reaction_system`

```rust
pub fn add_reaction_system(esm_file: &EsmFile, system_id: &str, system: ReactionSystem) -> EditResult<EsmFile>
```

Add a reaction system to an ESM file

**Arguments**

* `esm_file` - The ESM file to modify
* `system_id` - Unique identifier for the new reaction system
* `system` - The reaction system to add

**Returns**

* `EditResult<EsmFile>` - New ESM file with the added reaction system

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L244) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_reaction_system.html)

### `Alg` {#x-alg}

*type* · canonical name `alg`

```rust
pub enum Alg {
    Bdf,
    Sdirk,
    Erk,
}

impl Alg { pub fn from_name(name: &str) -> Option<Self> }

impl Alg { pub fn name(self) -> &'static str }
```

Which solver family to use inside diffsol.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L77) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Alg.html)

### `apply_value_invention` {#x-apply_value_invention}

*function* · canonical name `apply_value_invention`

```rust
pub fn apply_value_invention(model: &mut Model, index_sets: &mut HashMap<String, IndexSet>, result: &ValueInventionResult)
```

The combined front-door applied to a typed model: rewrite the derived index
sets to their materialised dense extents and drop the value-invention
equations. After this the existing resolver / array compiler handles the
model with no value-invention-specific path.

The `index_sets` registry is document-scoped, so it is passed in (and
mutated in place) alongside the model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/value_invention.rs#L2050) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.apply_value_invention.html)

### `AutoRecords` {#x-autorecords}

*type* · canonical name `auto_records`

```rust
pub enum AutoRecords {
    Auto,
}
```

Carrier for the `"auto"` literal in [`RecordsPerFile`](/generated/api/extension/rust#x-recordsperfile).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L351) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.AutoRecords.html)

### `AxisCut` {#x-axiscut}

*type* · canonical name `axis_cut`

```rust
pub struct AxisCut {
    pub index_set: String,
    pub period: Option<i64>,
}
```

One decomposed horizontal index set: its name and its period, when the
axis is periodic.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L78) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.AxisCut.html)

### `AxisSel` {#x-axissel}

*type* · canonical name `axis_sel`

```rust
pub enum AxisSel {
    All,
    Indices(Vec<usize>),
    Range { start: usize, stop: usize, step: usize },
}

impl AxisSel { pub fn indices(&self, dim_len: usize) -> Vec<usize> }
```

One axis of the per-axis selection handed to a gated provider — the Rust
spelling of the Python engine's `"all" | [0-based indices]` form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/provider.rs#L135) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/provider/enum.AxisSel.html)

### `bind_data_sources` {#x-bind_data_sources}

*function* · canonical name `bind_data_sources`

```rust
pub fn bind_data_sources(file: EsmFile, cache_root: &Path, reload: impl FnOnce(&BTreeMap<String, i64>) -> Result<EsmFile, EsmError>) -> Result<BoundDocument, ProviderError>
```

Bind `file`'s consumed `data_sources` to readers, closing every
metaparameter a source's `extent` binds first.

Returns the document to build, re-loaded through `reload` with the closed
metaparameters when a source measured one, and the provider factory for
it: call it once per build and put what it returns in
`crate::problem::ProblemOptions::providers` with
`crate::problem::ProblemOptions::build_pipeline` set, or hand it to the
inline-test runner as `InlineTestOptions::providers`. A document that
consumes no source comes back unchanged, with no factory and no cost.

**The ordering rule.** esm-spec §8.9.4 puts the sampling of a source that
measures its own extent BEFORE the document's metaparameters are closed
(§9.7.6 site 4). An index set declared `size: "N_REC"` is folded to an
integer at load, so a host that loads once has already frozen the row
count at the declaration's default, and every shape downstream is wrong
(for a count not knowable until the table is read, zero-length, so an
aggregate over it is a sum over no rows). `reload` is called with the
discovered extents, keyed by metaparameter, and must load the same document
with them bound, for example
`|mp| load_path_with_options(path, mp)`. Every source naming the same
metaparameter must measure the same number of records; a disagreement is
refused.

**Best effort sampling.** A source that cannot be constructed or sampled
during the extent pass is not reported here: the factory reports it, with
the source named, to the build that needed the data. Only a disagreement
between extents and a failed `reload` are errors of this pass.

`cache_root` is EarthSciIO's content-addressed cache directory.

**Without the `esio` feature** there is no reader, so a document that
consumes a source is refused, naming the source, the parameters that read
it, and the feature: running it would evaluate every data-fed parameter at
its `default`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/data_binding.rs#L83) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.bind_data_sources.html)

### `BoundaryKind` {#x-boundarykind}

*type* · canonical name `boundary_kind`

```rust
pub enum BoundaryKind {
    Periodic,
    Clamp,
    Error,
}
```

Per-dimension boundary policy for an out-of-range const-array stencil gather
Mirrors the Julia `_CONST_BOUNDARY_KINDS` (`:periodic` /
`:clamp` / `:error`): a gather at a 1-based index outside `1..=n` resolves
declaratively per the dimension's policy instead of panicking.

- `BoundaryKind::Periodic` — wrap into `1..=n` via 1-based mod (`mod1`);
  correct for a periodic axis (a lon-periodic metric factor).
- `BoundaryKind::Clamp` — edge-extend (clamp to `1..=n`); the correct finite
  policy for a metric / geometry factor at a non-periodic boundary (NOT a
  zero-ghost, which is physically wrong for a metric).
- `BoundaryKind::Error` — return a structured [`ValueInventionError`](/generated/api/ref/value_invention_error) (also
  the default for any dimension WITHOUT a declared policy), so genuine
  out-of-bounds bugs in connectivity / stencil-weight factors stay caught.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/value_invention.rs#L108) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.BoundaryKind.html)

### `BoundDocument` {#x-bounddocument}

*type* · canonical name `bound_document`

```rust
pub struct BoundDocument {
    pub file: EsmFile,
    pub providers: Option<Arc<BuildProviderFactory<'static>>>,
}
```

A document bound to its `data_sources`, as [`bind_data_sources`](/generated/api/extension/rust#x-bind_data_sources) returns it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/data_binding.rs#L26) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.BoundDocument.html)

### `BuildProviderFactory` {#x-buildproviderfactory}

*type* · canonical name `build_provider_factory`

```rust
pub type BuildProviderFactory<'a> = dyn Fn() -> Result<Vec<(String, Box<dyn DataProvider>)>, String> + 'a;
```

Builds a document's data providers, once per build, keyed as
`crate::problem::ProblemOptions::providers` keys them.

A factory rather than a set because `ProblemOptions` takes its `providers`
BY VALUE: one shared map would be moved out by the first build and missing
from the second. `Err` carries a message naming what could not be
constructed. [`crate::bind_data_sources`](/generated/api/extension/rust#x-bind_data_sources) returns one for a document's
`data_sources`, and `InlineTestOptions::providers` takes one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/provider.rs#L85) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/provider/type.BuildProviderFactory.html)

### `CallbackFn` {#x-callbackfn}

*type* · canonical name `callback_fn`

```rust
pub type CallbackFn = Arc<dyn for<'p> Fn(&Progress<'p>) -> Flow + Send + Sync>;
```

One callback. See the `wasm32` twin for the documentation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/mod.rs#L84) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.CallbackFn.html)

### `capture_coupling_diagnostics` {#x-capture_coupling_diagnostics}

*function* · canonical name `capture_coupling_diagnostics`

```rust
pub fn capture_coupling_diagnostics<T>(f: impl FnOnce() -> T) -> (T, Vec<String>)
```

Run `f`, collecting the WARNING-level coupling diagnostics it emits instead
of printing them, and return them alongside its result.

The side-effect-free counterpart of the stderr stream, in the shape
`crate::pushdown_rewrite::pushdown_diagnostics` established for the
projection-pushdown residuals. It exists because a diagnostic nothing can
assert on is a diagnostic that rots: the shared
`tests/conformance/operator_compose_merge/` corpus compares diagnostic
OUTCOMES, and without this the Rust adapter could check the `require_match`
refusals but not the warnings they were promoted from.

The sink is thread-local, so concurrent test threads do not capture each
other's findings, and it is restored on the way out even if `f` returns an
error (`f` is not unwind-safe by contract — a panic inside it leaves the sink
installed for that thread, which only affects a thread that is already
unwinding).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/flatten.rs#L4841) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.capture_coupling_diagnostics.html)

### `check_assertion` {#x-check_assertion}

*function* · canonical name `check_assertion`

```rust
pub fn check_assertion(actual: f64, expected: f64, rtol: f64, atol: f64) -> bool
```

The esm-spec §6.6.3 pass predicate — `actual == expected`, or both values
FINITE and `|a − e| ≤ max(atol, rtol·max(|a|, |e|))` — the same predicate
the Julia / Python `run_inline_tests` use (see also CONFORMANCE_SPEC §5.20).
This is Julia `isapprox`.

**The relative bound is SYMMETRIC** in `actual` and `expected`: its scale is
`max(|a|, |e|)`, the larger of the two magnitudes, not `|e|` alone. §6.6.3
used to state both readings at once — the normative box gave an
`|expected|`-only denominator while the finiteness rationale further down
that same section reasoned from `max(|inf|, |expected|)` — and this
function was written against the second. EarthSciML/EarthSciAST#193 settled
the spec as symmetric, so the two now agree and this line is normative
rather than merely conventional. The verdicts differ only inside
`rtol*|e| < |a − e| <= rtol*|a|`, which needs an overshoot
(`|actual| > |expected|`) of order `rtol`;
`relative_bound_is_symmetric_in_actual_and_expected` pins that seam.

**Finiteness is judged BEFORE tolerance**, and that clause is not a
corollary of the bound — it contradicts it. With `actual = ±inf` both sides
of `|actual − expected| ≤ max(atol, rtol·max(|actual|, |expected|))` are
`inf`, so the comparison held for EVERY finite `expected`: an assertion on
an overflowed product, a division by a zero denominator or a `log(0)`
reported PASS whatever it expected, and a document that computed nothing
meaningful would go green. NaN does not have the problem (every IEEE-754
comparison with NaN is false), so the rule matters for infinities. Julia's
`isapprox` behaves the same way:
`x == y || (isfinite(x) && isfinite(y) && …)`.

`actual == expected` keeps the one case a non-finite value legitimately
matches: the SAME infinity, with the same sign. A `.esm` document cannot
spell an infinite `expected` (JSON has no infinite literal), so within a
document the rule reduces to "a non-finite actual always fails"; the
equality clause governs an API caller. It also keeps the zero-tolerance
exact-equality mode, and `-0.0 == 0.0` under IEEE-754, so a signed zero is
unaffected.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L708) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.check_assertion.html)

### `check_dimensional_consistency` {#x-check_dimensional_consistency}

*function* · canonical name `check_dimensional_consistency`

```rust
pub fn check_dimensional_consistency(lhs_unit: &Unit, rhs_unit: &Unit) -> Result<(), UnitError>
```

Check dimensional consistency of an equation

**Arguments**

* `lhs_unit` - Units of the left-hand side
* `rhs_unit` - Units of the right-hand side

**Returns**

* `Result<(), UnitError>` - Ok if consistent, error otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L4325) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.check_dimensional_consistency.html)

### `check_equation_dimensions` {#x-check_equation_dimensions}

*function* · canonical name `check_equation_dimensions`

```rust
pub fn check_equation_dimensions(eq: &Equation, env: &HashMap<String, Unit>) -> Vec<UnitFinding>
```

Dimension-check an equation, returning EVERY finding.

Both sides are always walked — a finding on the LHS never short-circuits the
RHS — so one undeterminable subexpression cannot hide a provable mismatch
elsewhere in the same equation. The LHS/RHS comparison itself is only made
when BOTH sides resolved: comparing against an unknown dimension could only
ever produce a false mismatch.

`env` holds no operator registry, so an operator reference
(`apply_operator`, esm-spec §9.6.4) is undeterminable here and a mismatch
inside the body of the definition it names goes unreported. For an
equation of a loaded document use
[`check_equation_dimensions_with_operators`](/generated/api/extension/rust#x-check_equation_dimensions_with_operators) with its component's registry,
as validation does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L2635) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.check_equation_dimensions.html)

### `check_equation_dimensions_with_operators` {#x-check_equation_dimensions_with_operators}

*function* · canonical name `check_equation_dimensions_with_operators`

```rust
pub fn check_equation_dimensions_with_operators(eq: &Equation, env: &HashMap<String, Unit>, operators: &OperatorRegistry) -> Vec<UnitFinding>
```

[`check_equation_dimensions`](/generated/api/extension/rust#x-check_equation_dimensions) typing each operator reference against
`operators` (esm-spec §9.6.12 "Units"): the registry of the component the
equation belongs to (`crate::EsmFile::component_operators`), or a
flattened system's (`crate::FlattenedSystem::operators`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L2643) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.check_equation_dimensions_with_operators.html)

### `check_expression_dimensions` {#x-check_expression_dimensions}

*function* · canonical name `check_expression_dimensions`

```rust
pub fn check_expression_dimensions(expr: &Expr, declared: Option<&Unit>, env: &HashMap<String, Unit>) -> Vec<UnitFinding>
```

Dimension-check a standalone expression (an observed variable's defining
expression), returning EVERY finding.

When `declared` is `Some`, the expression's dimension is additionally
compared against the variable's declared units — the observed-variable
analogue of the equation LHS/RHS check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L2716) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.check_expression_dimensions.html)

### `Classification` {#x-classification}

*type* · canonical name `classification`

```rust
pub struct Classification {
    pub ode_states: Vec<String>,
    pub observed_unknowns: Vec<String>,
    pub inlined_unknowns: Vec<String>,
    pub algebraic_unknowns: Vec<String>,
    pub brownian_parameters: Vec<String>,
    pub discrete_parameters: Vec<String>,
    pub sampled_parameters: Vec<String>,
    pub constant_parameters: Vec<String>,
    pub system_kind: SystemKind,
    pub observed_definitions: BTreeMap<String, Expr>,
}

impl Classification { pub fn of(model: &Model) -> Classification }

impl Classification { pub fn from_parts(variables: &IndexMap<String, ModelVariable>, equations: &[Equation]) -> Classification }

impl Classification { pub fn from_json(model: &Value) -> Result<Classification, Error> }

impl Classification { pub fn is_ode_state(&self, name: &str) -> bool }

impl Classification { pub fn is_observed(&self, name: &str) -> bool }

impl Classification { pub fn is_inlined(&self, name: &str) -> bool }

impl Classification { pub fn is_brownian(&self, name: &str) -> bool }

impl Classification { pub fn is_discrete_parameter(&self, name: &str) -> bool }

impl Classification { pub fn unknowns(&self) -> Vec<String> }

impl Classification { pub fn parameters(&self) -> Vec<String> }

impl Classification { pub fn assert_partitions(&self, model: &Model) -> Result<(), String> }
```

One model's complete §6.3.1 classification, computed once. Every name list
is sorted.

The free functions below ([`ode_states`](/generated/api/ref/ode_states), [`brownian_parameters`](/generated/api/ref/brownian_parameters), …) are
thin wrappers over this; build it directly when a caller needs several sets,
so the equation walk happens once.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/classification.rs#L75) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Classification.html)

### `classify` {#x-classify}

*function* · canonical name `classify`

```rust
pub fn classify(node: &Value, model: &Value) -> Result<Cadence, CadenceError>
```

Derive a node's cadence class. For a leaf, seed it. For an operator node,
`class = max` over child classes — which, for a gather `index(A, e…)`, is
`max(class(A), class(e…))`: the index expressions are classed
**independently of the array**, so a stencil splits (§5.7.3 gather rule).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/cadence.rs#L390) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.classify.html)

### `ClassSummary` {#x-classsummary}

*type* · canonical name `class_summary`

```rust
pub struct ClassSummary {
    pub const_: u64,
    pub discrete: u64,
    pub continuous: u64,
}

impl ClassSummary { pub fn to_json(&self) -> Value }
```

Annotated-node counts by derived class — the golden `class_summary`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/cadence.rs#L804) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ClassSummary.html)

### `compile_array` {#x-compile_array}

*function* · canonical name `compile_array`

```rust
pub fn compile_array(file: EsmFile) -> Result<ArrayCompiled, SimulateError>
```

Two-step entry point for array/spatial files: CONSUME the parsed
[`EsmFile`](/generated/api/ref/esm_file) and compile it into the array runtime's
`crate::simulate_array::ArrayCompiled`, which the caller then solves
with `crate::simulate_array::ArrayCompiled::solve`. The one-shot
[`crate::problem::esm_problem`](/generated/api/ref/esm_problem-function) borrows `file` and so keeps it alive for the
whole build; for a large expanded discretization the typed file is on the
order of the compiled rules themselves, and taking the file by value lets
it die as soon as it is flattened.

```text
let compiled = compile_array(file)?;          // file is consumed here
let sol = compiled.solve(tspan, &params, &ics, &opts)?;
```

Routing matches the one-shot entry points (`build_array_compiled`): the
file is flattened, and dropped right after. Errors with
[`SimulateError`](/generated/api/ref/simulate_error) if `file` has no array-op or spatial structure — a
pure-scalar file is built by [`crate::problem::esm_problem`](/generated/api/ref/esm_problem-function), whose build
is cheap enough for it that a two-step split buys nothing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/driver.rs#L116) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.compile_array.html)

### `CompileError` {#x-compileerror}

*error* · canonical name `compile_error`

```rust
pub enum CompileError {
    UnsupportedConstruct { construct: &'static str, evaluator: &'static str, detail: String },
    DoublyDefinedUnknown { name: String, differential: String, algebraic: String },
    CompilerRefusedRule { compiler: &'static str, kind: &'static str, rule: String, tier: &'static str, reason: String },
    UnsupportedFeatureError { feature: String, message: String },
    UnsupportedDimensionalityError { independent_variables: Vec<String> },
    InterpreterBuildError { details: String },
    CodedBuildError { code: &'static str, details: String },
    UnloweredOperatorError { op: String, why: String },
    InvalidOperatorArity { op: String, got: usize, expected: String },
    MakearrayRegionInvalid { reason: String },
    InvalidBroadcastFn { reason: String },
    UnevaluableOperatorError { op: String },
    ValueInventionRefused { code: &'static str, reason: String },
    UnsupportedElementType { element_type: String },
    Float32Unsupported { construct: String, reason: String },
    ElementTypeUncarried { construct: String, reason: String },
    MixedElementType { op: String, lhs_name: String, lhs_type: String, rhs_name: String, rhs_type: String },
    UnalignableArrayShape { operand: String, axis: String, result: String, result_axes: Vec<String> },
    ObservedCycle { cycle: Vec<String> },
    MissingData { parameter: String, detail: String },
    MissingInitialValue { slot: String, detail: String },
    Flatten(FlattenError),
}

impl CompileError { pub fn code(&self) -> Option<&'static str> }

impl CompileError { pub fn build_err(details: impl Into<String>) -> Self }

impl CompileError { pub fn coded_build_err(code: &'static str, details: impl Into<String>) -> Self }
```

Errors raised when building a compiled model from a flattened system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/compile_error.rs#L17) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.CompileError.html)

### `CompilerRuleReport` {#x-compilerrulereport}

*type* · canonical name `compiler_rule_report`

```rust
pub struct CompilerRuleReport {
    pub rule: String,
    pub kind: &'static str,
    pub cadence: &'static str,
    pub tier: &'static str,
    pub reason: Option<String>,
}
```

Where ONE rule of a Problem landed, and at what cadence (API_SPEC §5.8,
"Every Problem reports what ran").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/mod.rs#L407) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CompilerRuleReport.html)

### `ComponentMetadata` {#x-componentmetadata}

*type* · canonical name `component_metadata`

```rust
pub struct ComponentMetadata {
    pub var_count: usize,
    pub eq_count: usize,
    pub species_count: usize,
}
```

Summary counts a component node carries (esm-libraries-spec §4.8.1).

A model reports its declared variables and its equations; a reaction system
reports its reactions as `eq_count`, its species as `species_count`, and its
PARAMETERS as `var_count` — the schema forbids a `variables` field there and
`species_count` already carries the species, so `parameters` is the only
thing left for §4.8.1's "variable count" to mean, and it is the exact
analogue of a model's `variables` (which likewise counts unknowns and
parameters together). Subsystems contribute NOTHING — the counts describe
the component's own body, matching the reference implementation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/graph.rs#L143) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ComponentMetadata.html)

### `ComponentType` {#x-componenttype}

*type* · canonical name `component_type`

```rust
pub enum ComponentType {
    Model,
    ReactionSystem,
}
```

Type of component in the graph.

There is no data-source arm. esm-libraries-spec §4.8.1 is explicit that "a
`data_sources` entry is not a component and is NOT a node": from 1.0.0
external data reaches a model as a PARAMETER whose `update` names the
source, so the dependency is already carried by that parameter's node.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/graph.rs#L173) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ComponentType.html)

### `compute_fold` {#x-compute_fold}

*function* · canonical name `compute_fold`

```rust
pub fn compute_fold(label: &str, spec: &Value, inputs: &Value) -> Result<String, CadenceError>
```

Compute a single CONST-folded buffer and return its **canonical byte form**.
`label` is the buffer name (the default array key when `spec.array` is
absent); `spec` is the golden's per-buffer fold descriptor (`fold` kind +
optional `array`); `inputs` is the CONST-fold input block (the document
literals — the fixtures are value-free, so the values live in the manifest).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/cadence.rs#L762) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.compute_fold.html)

### `ConstructSource` {#x-constructsource}

*type* · canonical name `construct_source`

```rust
pub struct ConstructSource {
    pub pointer: String,
    pub span: Range<usize>,
}
```

One construct of a document's source text: where its content is in the
document the text reads as, and where the text writes it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/document/mod.rs#L304) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ConstructSource.html)

### `ConstValue` {#x-constvalue}

*type* · canonical name `const_value`

```rust
pub struct ConstValue(/* private field */);
impl ConstValue { pub fn from_json(value: Value) -> Self }
impl ConstValue { pub fn from_dense(shape: &[usize], values: Vec<f64>) -> Self }
impl ConstValue { pub fn to_json(&self) -> Cow<'_, Value> }
impl ConstValue { pub fn as_json(&self) -> Option<&Value> }
impl ConstValue { pub fn as_dense(&self) -> Option<&Arc<ArrayD<f64>>> }
impl ConstValue { pub fn is_number(&self) -> bool }
impl ConstValue { pub fn as_f64(&self) -> Option<f64> }
impl ConstValue { pub fn is_array(&self) -> bool }
impl ConstValue { pub fn ptr_eq(a: &ConstValue, b: &ConstValue) -> bool }
```

The inline literal a `const` node carries (`ExpressionNode::value`).

A rectangular array of numbers is held DENSE: a row-major `f64` array with
its shape, plus which of its numbers the document spelled as integers and
which as floats (`Spelling`). Every other literal — a number, a string,
an object (a `bc` value), an empty or ragged array, or an array with an
integer `f64` cannot hold exactly — is held as the JSON it was written as.

The payload is behind an `Arc`, so cloning a node shares it, and it
carries its own evaluation-ready array: the first evaluation under a given
working precision materializes it once, and every later read (from any
clone) is served from there.

Both forms serialize to the JSON they were read from, in canonical-number
form (esm-spec §5.5.3.1): a dense payload writes exactly the nested array
its numbers came from.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/const_value.rs#L27) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ConstValue.html)

### `CoordPlan` {#x-coordplan}

*type* · canonical name `coord_plan`

```rust
pub struct CoordPlan {
    pub name: String,
    pub values: Vec<f64>,
    pub attrs: Map<String, Value>,
}
```

A CF **dimension coordinate** (§8.3): a 1-D coordinate variable named
exactly like its dimension, its values, and its CF attributes. Field-for-
field the shape of `earthsciio::format::WriteCoord`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/data_output.rs#L833) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CoordPlan.html)

### `CovarianceMatrix` {#x-covariancematrix}

*type* · canonical name `covariance_matrix`

```rust
pub type CovarianceMatrix = Vec<Vec<f64>>;
```

Symmetric positive-semidefinite covariance matrix, row-major: entry
`[i][j]` is the covariance of components `i` and `j`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L800) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.CovarianceMatrix.html)

### `DaeError` {#x-daeerror}

*error* · canonical name `dae_error`

```rust
pub struct DaeError {
    pub code: String,
    pub message: String,
}
```

Error returned by [`apply_dae_contract`](/generated/api/ref/apply_dae_contract) / [`discretize`](/generated/api/extension/rust#x-discretize) when the
RFC §12 DAE binding contract cannot be satisfied.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/dae.rs#L50) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DaeError.html)

### `DataProvider` {#x-dataprovider}

*type* · canonical name `data_provider`

```rust
pub trait DataProvider {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError>;
    fn refresh(&mut self, _t: f64) -> Result<Option<ArrayD<f64>>, ProviderError>;
    fn refresh_times(&self) -> Vec<f64>;
    fn supports_selection(&self) -> bool;
    fn sample_with_selection(&mut self, _selection: &[AxisSel]) -> Result<ArrayD<f64>, ProviderError>;
    fn gate_spec(&self) -> Option<ProviderGate>;
    fn extent_metaparameter(&self) -> Option<String>;
    fn primed(&self) -> bool;
}
```

A source of ONE parameter's data, keyed in
`crate::problem::ProblemOptions::providers` by that parameter (esm-spec
§6.6.2 spellings: `Fed.s`, `s`, or a partial qualification).

A provider with no `Self::refresh_times` is CONST: its one
`Self::sample` is the parameter's value for the whole run. A provider
with refresh times is DISCRETE: `Self::refresh` delivers the record in
effect from each of them. When the build pipeline is asked for
(`crate::problem::ProblemOptions::build_pipeline`), it consumes every
CONST provider — whole, or pre-sliced through
`Self::sample_with_selection` when a gate (`Self::gate_spec`, or the
pushdown rewrite's own) defers it past value invention — and may close a
metaparameter with a provider's own record count
(`Self::extent_metaparameter`). The run-time refresh executor consumes
the rest.

The array a provider delivers must have the parameter's declared shape,
its dimensions in the order the source stores them; it is refused
otherwise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/provider.rs#L188) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/provider/trait.DataProvider.html)

### `DataSourceMetadata` {#x-datasourcemetadata}

*type* · canonical name `data_source_metadata`

```rust
pub struct DataSourceMetadata {
    pub tags: Option<Vec<String>>,
    pub extra: HashMap<String, Value>,
}
```

Free-form metadata about a data loader.

The `tags` field is conventional for expressing scientific role
(e.g. `"emissions"`, `"reanalysis"`) and is not schema-validated.
Additional fields are preserved as raw JSON via `extra`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L378) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSourceMetadata.html)

### `default_dae_support` {#x-default_dae_support}

*function* · canonical name `default_dae_support`

```rust
pub fn default_dae_support() -> bool
```

Resolve the effective default for `dae_support` from the environment:
`ESM_DAE_SUPPORT=0` (or `false`/`no`/`off`) disables DAE support.
Anything else (including unset) defaults to enabled.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/dae.rs#L82) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.default_dae_support.html)

### `DependencyRelationship` {#x-dependencyrelationship}

*type* · canonical name `dependency_relationship`

```rust
pub enum DependencyRelationship {
    Additive,
    Multiplicative,
    Rate,
    Stoichiometric,
}
```

PROVENANCE of a dependency — which structural site produced it, NOT a
classification of the operators involved. An equation edge is always
`Additive` (even for `w ~ u * v`) and a definition edge always
`Multiplicative` (even for `w ~ u + v`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/graph.rs#L490) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.DependencyRelationship.html)

### `DeriveError` {#x-deriveerror}

*error* · canonical name `derive_error`

```rust
pub enum DeriveError {
    InvalidStoichiometry(String),
}
```

Error type for ODE derivation operations

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/reactions.rs#L19) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.DeriveError.html)

### `DimensionPromotionRecord` {#x-dimensionpromotionrecord}

*type* · canonical name `dimension_promotion_record`

```rust
pub struct DimensionPromotionRecord {
    pub variable: String,
    pub source_domain: String,
    pub target_domain: String,
    pub mapping_type: String,
}
```

Record of a dimension promotion applied during flattening.

**Reserved / parity-only — never currently populated.** [`flatten`](/generated/api/ref/flatten) always
emits an empty `FlattenMetadata::dimension_promotions_applied`: this crate
inspects no `dimension_mapping` declarations and rewrites no variable onto a
different spatial domain. The struct is defined so the metadata shape matches
the sibling bindings (which may populate it) and so a future Rust tier can
fill it without a wire-format change.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/flatten.rs#L449) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DimensionPromotionRecord.html)

### `discretize` {#x-discretize}

*function* · canonical name `discretize`

```rust
pub fn discretize(esm: &EsmFile, options: DiscretizeOptions) -> Result<EsmFile, DaeError>
```

Top-level `discretize()` entry point per RFC §11/§12 for the rust binding.

This function applies the RFC §12 DAE binding contract (trivial
factoring, an error otherwise). It does not run the RFC §11 pipeline
(canonicalize, rule engine, PDE-op check, provenance).

Returns a discretized [`EsmFile`](/generated/api/ref/esm_file) with `metadata.system_class`,
`metadata.dae_info`, and `metadata.discretized_from` stamped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/dae.rs#L214) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.discretize.html)

### `DiscretizedFrom` {#x-discretizedfrom}

*type* · canonical name `discretized_from`

```rust
pub struct DiscretizedFrom {
    pub name: Option<String>,
}
```

Provenance stamp written to `metadata.discretized_from` by `discretize()`
per RFC §12: identifies the source document the discretized one came from.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/document.rs#L310) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DiscretizedFrom.html)

### `DiscretizeOptions` {#x-discretizeoptions}

*type* · canonical name `discretize_options`

```rust
pub struct DiscretizeOptions {
    pub dae_support: bool,
}
```

Options for [`discretize`](/generated/api/extension/rust#x-discretize). The §11 pipeline options (max passes,
strict unrewritten) will be added when that pipeline lands; today
only the DAE knob exists.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/dae.rs#L62) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DiscretizeOptions.html)

### `DistributionParam` {#x-distributionparam}

*type* · canonical name `distribution_param`

```rust
pub enum DistributionParam {
    Scalar(f64),
    Vector(Vec<f64>),
}

impl DistributionParam { pub fn is_vector(&self) -> bool }
```

A distribution's location/scale parameter: a number for a scalar parameter,
an array for a vector-valued one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L784) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.DistributionParam.html)

### `document_json_text` {#x-document_json_text}

*function* · canonical name `document_json_text`

```rust
pub fn document_json_text<'a>(text: &'a str, location: &Path) -> Result<Cow<'a, str>, EsmError>
```

A document file's `text` as JSON text, read in the format its `location`
names (esm-spec §1.2.1): JSON text is returned as it is, and a Markdown
(`.md`) or Typst (`.typ`) source document is read and rendered as JSON. For
a caller that has a file's text in hand and goes on to load or validate it
as a string (the `esm` CLI's subcommands); [`load_path`](/generated/api/ref/load_path) reads files
directly.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/parse.rs#L797) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.document_json_text.html)

### `equation_dimension_verdict` {#x-equation_dimension_verdict}

*function* · canonical name `equation_dimension_verdict`

```rust
pub fn equation_dimension_verdict(eq: &Equation, env: &HashMap<String, Unit>) -> EquationDimensionVerdict
```

Classify one equation the way [`check_equation_dimensions`](/generated/api/extension/rust#x-check_equation_dimensions) judges it, and
say WHY when it could not be judged.

A `Consistent` verdict is only returned when the comparison actually ran, so
an equation skipped because of an indeterminate operand — a bare literal in a
product, a `const` node that declares no `units`, a variable with no declared
units — is never reported as fine.

As with [`check_equation_dimensions`](/generated/api/extension/rust#x-check_equation_dimensions), `env` holds no operator registry:
an equation with an operator reference is judged by
[`equation_dimension_verdict_with_operators`](/generated/api/extension/rust#x-equation_dimension_verdict_with_operators).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L3058) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.equation_dimension_verdict.html)

### `equation_dimension_verdict_with_operators` {#x-equation_dimension_verdict_with_operators}

*function* · canonical name `equation_dimension_verdict_with_operators`

```rust
pub fn equation_dimension_verdict_with_operators(eq: &Equation, env: &HashMap<String, Unit>, operators: &OperatorRegistry) -> EquationDimensionVerdict
```

[`equation_dimension_verdict`](/generated/api/extension/rust#x-equation_dimension_verdict) typing each operator reference against
`operators`, the registry of the component the equation belongs to
(`crate::EsmFile::component_operators`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L3068) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.equation_dimension_verdict_with_operators.html)

### `EquationDimensionVerdict` {#x-equationdimensionverdict}

*type* · canonical name `equation_dimension_verdict`

```rust
pub enum EquationDimensionVerdict {
    Consistent(String),
    Mismatch(Vec<String>),
    NotChecked(String),
}
```

The dimensional analyser's verdict on one equation, in the form a report
prints: checked and consistent, provably inconsistent, or not checked.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L3036) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.EquationDimensionVerdict.html)

### `EsmError` {#x-esmerror}

*error* · canonical name `esm_error`

```rust
pub enum EsmError {
    JsonParse(Error),
    SourceParse { code: &'static str, message: String },
    SchemaValidation(String),
    StructuralValidation(String),
    FileRead { path: String, source: Error },
    FileWrite { path: String, source: Error },
    SchemaDiagnostic { code: &'static str, message: String, findings: Vec<StructuralError> },
    StructuralDiagnostic { code: &'static str, message: String, findings: Vec<StructuralError> },
}

impl EsmError { pub fn code(&self) -> Option<&'static str> }

impl EsmError { pub fn findings(&self) -> &[StructuralError] }
```

Main error type for the ESM format library

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/error.rs#L7) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.EsmError.html)

### `evaluate_cellwise_with_operators` {#x-evaluate_cellwise_with_operators}

*function* · canonical name `evaluate_cellwise_with_operators`

```rust
pub fn evaluate_cellwise_with_operators(expr: &Expr, cells: &[Vec<i64>], index_sets: &HashMap<String, IndexSet>, params: &HashMap<String, f64>, operators: &OperatorRegistry) -> Result<Vec<f64>, String>
```

[`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise) of an expression whose operator references
(esm-spec §9.6.4) resolve against `operators`: the registry of the
component the expression belongs to
(`crate::EsmFile::component_operators`), which is how the runner
evaluates an inline test's analytic `reference`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L270) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.evaluate_cellwise_with_operators.html)

### `evaluate_with_operators` {#x-evaluate_with_operators}

*function* · canonical name `evaluate_with_operators`

```rust
pub fn evaluate_with_operators(expr: &Expr, bindings: &HashMap<String, f64>, operators: &OperatorRegistry) -> Result<f64, Vec<String>>
```

[`evaluate`](/generated/api/ref/evaluate) of an expression that may hold operator references
(esm-spec §9.6.4), each resolved against `operators` (a flattened
system's `crate::FlattenedSystem::operators`, or a component's
`crate::EsmFile::component_operators`) and evaluated as a call of the
instance it names, never expanded.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/expression.rs#L202) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.evaluate_with_operators.html)

### `EventKind` {#x-eventkind}

*type* · canonical name `event_kind`

```rust
pub enum EventKind {
    Continuous,
    Discrete,
}
```

`"continuous"` or `"discrete"`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L127) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.EventKind.html)

### `expression_graph_with_options` {#x-expression_graph_with_options}

*function* · canonical name `expression_graph_with_options`

```rust
pub fn expression_graph_with_options<T>(input: &T, options: &ExpressionGraphOptions) -> ExpressionGraph where T: ExpressionGraphInput
```

Build an expression graph with explicit [`ExpressionGraphOptions`](/generated/api/ref/expression_graph_options).

**Arguments**

* `input` - Can be an ESM file, model, reaction system, equation, reaction, or expression
* `options` - Settings; options that do not apply to `input` are ignored

**Returns**

* `ExpressionGraph` - Graph showing variable dependencies

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/graph.rs#L537) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.expression_graph_with_options.html)

### `ExpressionGraphInput` {#x-expressiongraphinput}

*type* · canonical name `expression_graph_input`

```rust
pub trait ExpressionGraphInput {
    fn build_expression_graph(&self) -> ExpressionGraph;
    fn build_expression_graph_with_options(&self, _options: &ExpressionGraphOptions) -> ExpressionGraph;
}
```

Trait for types that can build expression graphs

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/graph.rs#L548) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/trait.ExpressionGraphInput.html)

### `ExpressionNode` {#x-expressionnode}

*type* · canonical name `expression_node`

```rust
pub struct ExpressionNode {
    pub op: String,
    pub args: Vec<Expr>,
    pub wrt: Option<String>,
    pub dim: Option<String>,
    pub int_var: Option<String>,
    pub lower: Option<Box<Expr>>,
    pub upper: Option<Box<Expr>>,
    pub expr: Option<Box<Expr>>,
    pub output_idx: Option<Vec<String>>,
    pub ranges: Option<HashMap<String, RangeSpec>>,
    pub reduce: Option<String>,
    pub semiring: Option<String>,
    pub join: Option<Vec<JoinClause>>,
    pub filter: Option<Box<Expr>>,
    pub regions: Option<Vec<Vec<[RegionBound; 2]>>>,
    pub values: Option<Vec<Expr>>,
    pub shape: Option<Vec<i64>>,
    pub perm: Option<Vec<i64>>,
    pub axis: Option<i64>,
    pub broadcast_fn: Option<String>,
    pub name: Option<String>,
    pub value: Option<ConstValue>,
    pub units: Option<String>,
    pub id: Option<String>,
    pub bindings: Option<HashMap<String, Expr>>,
    pub distinct: Option<bool>,
    pub key: Option<Box<Expr>>,
    pub expect_cadence: Option<String>,
    pub attrs: Option<Value>,
    pub template_origin: Option<String>,
}

impl ExpressionNode { pub fn for_each_child<'a>(self: &'a Self, f: &mut impl FnMut(&'a Expr)) }

impl ExpressionNode { pub fn for_each_child_mut(&mut self, f: &mut impl FnMut(&mut Expr)) }

impl ExpressionNode { pub fn any_child(&self, f: &mut impl FnMut(&Expr) -> bool) -> bool }

impl ExpressionNode { pub fn map_children(&self, f: &mut impl FnMut(&Expr) -> Expr) -> ExpressionNode }

impl ExpressionNode { pub fn try_for_each_child<'a, E>(self: &'a Self, f: &mut impl FnMut(&'a Expr) -> Result<(), E>) -> Result<(), E> }

impl ExpressionNode { pub fn try_for_each_child_mut<E>(&mut self, f: &mut impl FnMut(&mut Expr) -> Result<(), E>) -> Result<(), E> }
```

Expression node representing an operator with operands.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/expression.rs#L567) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ExpressionNode.html)

### `flatten_model` {#x-flatten_model}

*function* · canonical name `flatten_model`

```rust
pub fn flatten_model(model: &Model) -> Result<FlattenedSystem, FlattenError>
```

Flatten a single [`Model`](/generated/api/ref/model) as a convenience wrapper around [`flatten`](/generated/api/ref/flatten).

The model is wrapped in a synthetic single-component [`EsmFile`](/generated/api/ref/esm_file) under the
name `"model"` (or its declared `name` field if present) and run through
the full pipeline — so the result is still dot-namespaced and has real
[`FlattenMetadata`](/generated/api/ref/flatten_metadata). Use this when you want the spec-compliant output for
a standalone component without hand-building an [`EsmFile`](/generated/api/ref/esm_file).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/flatten.rs#L3315) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.flatten_model.html)

### `Flow` {#x-flow}

*type* · canonical name `flow`

```rust
pub enum Flow {
    Continue,
    Cancel,
}
```

What a `SolveOptions::progress` observer wants the integrator to do
next.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L168) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Flow.html)

### `GateAxis` {#x-gateaxis}

*type* · canonical name `gate_axis`

```rust
pub enum GateAxis {
    All,
    Fixed(usize),
    Range { start: usize, stop: usize, step: usize },
    GatedBy(String),
}
```

One native axis of a loader selection — the vocabulary shared by a data
loader's declared `select.axes` (esm-spec §8.9) and by the pushdown record's
gate template. JSON spellings, in the same order as the variants:

```text
"all"                                    every index of the axis
{"fixed": 0}  /  {"fixed": [0]}          index 0, and the axis is DROPPED
{"range": {"start": 0, "stop": 52411}}   a strided prefix/window (step ≥ 1)
{"gated_by": "<derived index set>"}      the set's materialised members
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L2303) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.GateAxis.html)

### `GroupPrecisionRecord` {#x-groupprecisionrecord}

*type* · canonical name `group_precision_record`

```rust
pub struct GroupPrecisionRecord {
    pub evaluation: Precision,
    pub state: BTreeMap<String, Precision>,
}
```

Working and storage precision of one group of equations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L255) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/struct.GroupPrecisionRecord.html)

### `HaloReport` {#x-haloreport}

*type* · canonical name `halo_report`

```rust
pub struct HaloReport {
    pub reach: BTreeMap<(String, String), (i64, i64)>,
}

impl HaloReport { pub fn get(&self, variable: &str, index_set: &str) -> Option<(i64, i64)> }
```

`RhsProgram::halo`'s report (RFC U3 §3): for each state the program
reads and each decomposed or face index set on its shape, keyed
`(variable, index set)`, how far the owned output reaches into it: `lo`
cells below the owned box, `hi` above it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L126) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.HaloReport.html)

### `has_coupling_import` {#x-has_coupling_import}

*function* · canonical name `has_coupling_import`

```rust
pub fn has_coupling_import(file: &EsmFile) -> bool
```

True when `file` carries at least one `coupling_import` entry in its
`coupling` array.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/coupling_imports.rs#L83) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.has_coupling_import.html)

### `HasSubsystems` {#x-hassubsystems}

*type* · canonical name `has_subsystems`

```rust
pub trait HasSubsystems: Sized {
    fn subsystems(&self) -> Option<&IndexMap<String, Subsystem<Self>>>;
    fn subsystems_mut(&mut self) -> Option<&mut IndexMap<String, Subsystem<Self>>>;
    fn inline_subsystems(&self) -> impl Iterator<Item = (&String, &Self)>;
    fn inline_subsystems_mut(&mut self) -> impl Iterator<Item = (&String, &mut Self)>;
    fn inline_subsystem(&self, name: &str) -> Option<&Self>;
    fn inline_subsystem_at<'a>(self: &'a Self, path: &[&str]) -> Option<&'a Self>;
}
```

A component that holds `subsystems` of its own kind: [`Model`](/generated/api/ref/model) and
[`ReactionSystem`](/generated/api/ref/reaction_system).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/subsystem.rs#L90) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/trait.HasSubsystems.html)

### `initial_state` {#x-initial_state}

*function* · canonical name `initial_state`

```rust
pub fn initial_state(prob: &EsmProblem) -> Result<Vec<f64>, SimulateError>
```

The initial state `prob` integrates from, one value per state element,
aligned with `EsmProblem::state_variable_names`.

This is the state every solve of `prob` starts from at `tspan.0`, built
the same way: per element, the first of the Problem's `u0` override
(`ProblemOptions::u0`), an initialization equation (esm-spec §6.2), an
`ic` equation or field initial condition (§11.4, §11.4.1; a scoped or
coordinate-expression `ic` included), and the variable's declared
`default`, with the Problem's parameters (`ProblemOptions::p`, else
their defaults) bound in every initial condition's scope (§6.6.5).
`crate::RhsProgram::default_state` is the declared defaults alone.

Nothing is integrated, and the result does not depend on any solver
option. An `ic` right-hand side reads each data-fed field at `tspan.0`
(esm-spec §11.4.2): the providers of the discrete-cadence fields it reads
are sampled there into a buffer of their own, without writing the
Problem's forcing, so calling this before or after a solve gives the same
state, and a solve after it still starts from the record in effect at its
start. Julia's equivalent is the `prob.u0` field, indexed through
`prob.var_map`.

**Errors**

`SimulateError::NotDynamic` for a Problem with no right-hand side to
integrate, and every error building the initial state raises in a solve:
`SimulateError::InvalidInitialCondition` for an element none of the four
sources values, and the error of an initial condition that cannot be
evaluated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/solve.rs#L176) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.initial_state.html)

### `InlineValue` {#x-inlinevalue}

*type* · canonical name `inline_value`

```rust
pub enum InlineValue {
    Scalar(f64),
    Array(Vec<InlineValue>),
}

impl InlineValue { pub fn as_scalar(&self) -> Option<f64> }

impl InlineValue { pub fn is_array(&self) -> bool }

impl InlineValue { pub fn to_dense(&self) -> Result<(Vec<usize>, Vec<f64>), String> }
```

A `default` / override VALUE: either a scalar, or inline row-major nested
array data (esm-spec §6.3, §6.6.2 — the `NumericArrayLiteral` of the schema).

A SHAPED variable's `default`, and a shaped variable's entry in a test's
`parameter_overrides` / `initial_conditions`, may carry the whole field as a
nested JSON array whose nesting matches the declared `shape` after
metaparameter folding; a mismatch is a load-time error. A scalar in the same
position keeps its broadcast meaning — the one value applies to every element.
This is what lets a column test supply its θ, q_v, u, v, p profiles inline
rather than through a per-regime generated rewrite-rule library.

`#[serde(untagged)]`, so a scalar round-trips as a bare JSON number and array
data as the nested array it was authored as.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L21) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.InlineValue.html)

### `IntegratorPrecision` {#x-integratorprecision}

*type* · canonical name `integrator_precision`

```rust
pub struct IntegratorPrecision {
    pub state: Precision,
    pub time: Precision,
    pub norms: Precision,
    pub linear_algebra: Precision,
}
```

Arithmetic used by the integrator for each class of quantities.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L488) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.IntegratorPrecision.html)

### `KernelOutput` {#x-kerneloutput}

*type* · canonical name `kernel_output`

```rust
pub enum KernelOutput {
    Observed { name: String, label: Option<String> },
    Expr { expr: Expr, label: Option<String> },
    Residual { id: String, label: Option<String> },
    Condition { event: String, index: usize, label: Option<String> },
    Update { parameter: String, index: Option<usize>, label: Option<String> },
    Affect { event: String, negative: bool },
    Assign { target: String, from: Expr },
}
```

One output of a kernel spec (API_SPEC §5.8, "Kernel specs").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L28) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.KernelOutput.html)

### `KernelSpec` {#x-kernelspec}

*type* · canonical name `kernel_spec`

```rust
pub struct KernelSpec {
    pub name: String,
    pub dt_params: Vec<String>,
    pub outputs: Vec<KernelOutput>,
}

impl KernelSpec { pub fn from_json(v: &Json) -> Result<KernelSpec, SimulateError> }

impl KernelSpec { pub fn list_from_json(v: &Json) -> Result<Vec<KernelSpec>, SimulateError> }
```

A kernel spec: a name, the parameters that read `dt`, and the outputs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L66) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.KernelSpec.html)

### `Key` {#x-key}

*type* · canonical name `key`

```rust
pub enum Key {
    Int(i64),
    Str(String),
    Bool(bool),
    Tuple(Vec<Key>),
}

impl Key { pub fn try_from_json(value: &Value) -> Result<Key, FloatKeyError> }
```

A relational **key** component: an integer / categorical ID, or a tuple
thereof. This is the orderable, float-free domain over which the five
primitives operate.

The derived `Ord` *is* the `CONFORMANCE_SPEC.md` §5.5.1 rule-1 total order
**within a type**: `Key::Int` by value, `Key::Str` by UTF-8 byte order
(= Unicode code-point order, *not* locale collation), and `Key::Tuple`
lexicographically. Cross-type comparison (e.g. an `Int` against a `Str`) falls
back to the variant declaration order; it is deterministic but never exercised
by a conformant index set, whose rows are homogeneous.

There is deliberately **no float variant** — that is how rule 1 ("floats are
forbidden in keys") is enforced in a statically-typed binding. Float *values*
for aggregation live in [`Num`](/generated/api/extension/rust#x-num), not here.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/relational.rs#L94) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Key.html)

### `LaneBlock` {#x-laneblock}

*type* · canonical name `lane_block`

```rust
pub struct LaneBlock {
    pub name: String,
    pub sets: Vec<String>,
    pub extents: Vec<usize>,
    pub offset: usize,
}
```

One variable's block in a lane program's inputs (API_SPEC §5.8, "Lanes"):
its index sets outside the lane sets, their extents, and its offset in
units of lanes. Element `e` (1-based, column-major over `sets`) of lane `l`
is at slot `(offset + e - 1)·L + l` (`l` 0-based in Rust).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L248) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LaneBlock.html)

### `LaneInputs` {#x-laneinputs}

*type* · canonical name `lane_inputs`

```rust
pub struct LaneInputs {
    /* private fields */
}

impl LaneInputs { pub fn values(&self) -> &[f64] }
```

The per-lane buffers of a lane program's pre-gather plan: one run of
`capacity` values per hoisted read. Filled by
`LaneProgram::gather_lane_inputs`, read by
`LaneProgram::eval_gathered_into`, which reads the forcing set they
were gathered from. `Send`, like a workspace.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/lanes.rs#L175) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LaneInputs.html)

### `LaneKind` {#x-lanekind}

*type* · canonical name `lane_kind`

```rust
pub enum LaneKind {
    Cells { sets: Vec<String> },
    Columns { sets: Vec<String> },
}

impl LaneKind { pub fn sets(&self) -> &[String] }
```

The locality a lane program evaluates over (RFC U3 §6), with the index
sets one lane's `cells` column names, in order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L104) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.LaneKind.html)

### `LaneLayout` {#x-lanelayout}

*type* · canonical name `lane_layout`

```rust
pub struct LaneLayout {
    pub u: Vec<LaneBlock>,
    pub aux: Vec<LaneBlock>,
    pub sets: Vec<String>,
    pub capacity: usize,
    pub u_len: usize,
    pub aux_len: usize,
}

impl LaneLayout { pub fn block(&self, name: &str) -> Option<&LaneBlock> }
```

A lane program's `u` and `aux` layout, with the lane sets a column of
`cells` indexes and the capacity `L`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L258) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LaneLayout.html)

### `LaneProgram` {#x-laneprogram}

*type* · canonical name `lane_program`

```rust
pub struct LaneProgram {
    /* private fields */
}

impl LaneProgram { pub fn layout(&self) -> &LaneLayout }

impl LaneProgram { pub fn capacity(&self) -> usize }

impl LaneProgram { pub fn n_lane_inputs(&self) -> usize }

impl LaneProgram { pub fn forcing_slots(&self) -> &[ForcingSlot] }

impl LaneProgram { pub fn new_workspace(&self) -> RhsWorkspace }

impl LaneProgram { pub fn eval_into(&self, u: &[f64], aux: &[f64], p: &[f64], t: f64, forcing: &ForcingSet, cells: &[i32], n: usize, du: &mut [f64], ws: &mut RhsWorkspace) -> Result<(), RhsError> }

impl LaneProgram { pub fn eval_times_into(&self, u: &[f64], aux: &[f64], p: &[f64], ts: &[f64], forcing: &ForcingSet, cells: &[i32], n: usize, du: &mut [f64], ws: &mut RhsWorkspace) -> Result<(), RhsError> }

impl LaneProgram { pub fn lane_inputs(&self) -> LaneInputs }

impl LaneProgram { pub fn gather_lane_inputs(&self, inputs: &mut LaneInputs, p: &[f64], t: f64, forcing: &ForcingSet, cells: &[i32], n: usize) -> Result<(), RhsError> }

impl LaneProgram { pub fn eval_gathered_into(&self, u: &[f64], aux: &[f64], inputs: &LaneInputs, p: &[f64], t: f64, cells: &[i32], n: usize, du: &mut [f64], ws: &mut RhsWorkspace) -> Result<(), RhsError> }

impl LaneProgram { pub fn eval_gathered_times_into(&self, u: &[f64], aux: &[f64], inputs: &LaneInputs, p: &[f64], ts: &[f64], cells: &[i32], n: usize, du: &mut [f64], ws: &mut RhsWorkspace) -> Result<(), RhsError> }
```

A lane program (RFC U3 §6). `Send + Sync + Clone`; it reads the forcing
sets of the program it was built from.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/lanes.rs#L74) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LaneProgram.html)

### `LhsForm` {#x-lhsform}

*type* · canonical name `lhs_form`

```rust
pub enum LhsForm {
    Derivative(String),
    Bare(String),
    Expression,
}
```

What an equation's LHS says about the unknown it names (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/classification.rs#L583) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.LhsForm.html)

### `load_document_with_options` {#x-load_document_with_options}

*function* · canonical name `load_document_with_options`

```rust
pub fn load_document_with_options(document: &Value, options: &LoadOptions) -> Result<EsmFile, EsmError>
```

[`load_document`](/generated/api/ref/load_document) with explicit [`LoadOptions`](/generated/api/ref/load_options) (base path for relative
refs, loader-API metaparameter bindings; esm-spec §9.7.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/parse.rs#L105) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_document_with_options.html)

### `load_path_with_options` {#x-load_path_with_options}

*function* · canonical name `load_path_with_options`

```rust
pub fn load_path_with_options<P: AsRef<Path>>(path: P, metaparameters: &BTreeMap<String, i64>) -> Result<EsmFile, EsmError>
```

Load an ESM file from a filesystem path, binding the root document's open
metaparameters at the loader API (esm-spec §9.7.6 binding site 4). The
file's own directory anchors relative subsystem and template-import refs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/parse.rs#L769) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_path_with_options.html)

### `load_string_with_options` {#x-load_string_with_options}

*function* · canonical name `load_string_with_options`

```rust
pub fn load_string_with_options(json_str: &str, options: &LoadOptions) -> Result<EsmFile, EsmError>
```

Load and parse an ESM file from a JSON string with explicit
[`LoadOptions`](/generated/api/ref/load_options) (base path for relative refs, loader-API metaparameter
bindings; esm-spec §9.7.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/parse.rs#L141) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_string_with_options.html)

### `lower_enums_raw` {#x-lower_enums_raw}

*function* · canonical name `lower_enums_raw`

```rust
pub fn lower_enums_raw(value: &mut Value) -> Result<(), EnumLoweringError>
```

Lower every `enum`-op node in `value` to a `{op: "const", value: <int>}`
node using the file's top-level `enums` block. Mutates `value` in place.

The raw-`serde_json::Value` extension seam (API_SPEC.md §8 item 14): this
is what the loader runs, BEFORE the document is coerced to an
[`crate::EsmFile`](/generated/api/ref/esm_file), so that JSON-typed subsystem blobs are covered by the
same walk. Callers holding a typed document want [`lower_enums`](/generated/api/ref/lower_enums).

Pre-condition: the input has been schema-validated and any
`apply_expression_template` ops have already been expanded.

Errors with diagnostic codes:
- `unknown_enum` — `enum` op references an undeclared enum name
- `unknown_enum_symbol` — `enum` op references an undeclared symbol
- `enum_invalid_args` — `enum` op has a non-positional or wrong-arity body
- `invalid_enums_block` — top-level `enums` block is malformed
- `enum_duplicate_value` — two symbols of one enum map to the same integer

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/lower_enums.rs#L349) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.lower_enums_raw.html)

### `MaterializationPoint` {#x-materializationpoint}

*type* · canonical name `materialization_point`

```rust
pub struct MaterializationPoint {
    pub label: Option<String>,
    pub kind: &'static str,
    pub threshold: String,
}
```

A materialization point: where the frontier cut fires (§5.7.4). Either an
`expr_edge` cadence drop inside a hot/per-event RHS, or an `output_buffer` —
a top-level CONST equation whose entire output folds into the artifact.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/cadence.rs#L836) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.MaterializationPoint.html)

### `MathError` {#x-matherror}

*error* · canonical name `math_error`

```rust
pub struct MathError {
    pub code: &'static str,
    pub message: String,
    pub at: Option<usize>,
}
```

Why [`parse_math`](/generated/api/ref/parse_math) refused a text, and where in it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/document/mod.rs#L168) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.MathError.html)

### `model_unit_env` {#x-model_unit_env}

*function* · canonical name `model_unit_env`

```rust
pub fn model_unit_env(esm_file: &EsmFile, model: &Model) -> (HashMap<String, Unit>, Vec<UnitParseFailure>)
```

The unit environment a model's equations are checked against, as one map:
its own declarations ([`build_unit_env`](/generated/api/ref/build_unit_env)) plus every scoped reference its
expressions can make, with the precedence of `ComponentUnitEnv`. The
parse failures returned are the model's own.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L2559) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.model_unit_env.html)

### `ModelAnalysis` {#x-modelanalysis}

*type* · canonical name `model_analysis`

```rust
pub struct ModelAnalysis {
    pub id: String,
    pub description: Option<String>,
    pub initial_state: Option<Value>,
    pub parameters: Option<HashMap<String, f64>>,
    pub time_span: TimeSpan,
    pub parameter_sweep: Option<ParameterSweep>,
    pub plots: Option<Vec<Plot>>,
    pub expression_template_imports: Vec<Value>,
}
```

Inline illustrative analysis of how to run the enclosing component
(schema `Analysis`): run configuration plus plots derived from the
result. Carried by `Model::analyses` and `ReactionSystem::analyses`,
the same way [`ModelTest`](/generated/api/extension/rust#x-modeltest) serves both components' `tests`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/analysis.rs#L356) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ModelAnalysis.html)

### `ModelTest` {#x-modeltest}

*type* · canonical name `model_test`

```rust
pub struct ModelTest {
    pub id: String,
    pub description: Option<String>,
    pub initial_conditions: Option<HashMap<String, InlineValue>>,
    pub parameter_overrides: Option<HashMap<String, InlineValue>>,
    pub time_span: TimeSpan,
    pub tolerance: Option<Tolerance>,
    pub assertions: Vec<ModelTestAssertion>,
    pub expression_template_imports: Vec<Value>,
}

impl ModelTest { pub fn scalar_initial_conditions(&self) -> HashMap<String, f64> }

impl ModelTest { pub fn scalar_parameter_overrides(&self) -> HashMap<String, f64> }
```

Inline validation test for a [`Model`](/generated/api/ref/model).

Defines the run configuration — initial conditions, parameter overrides,
simulation time span — and a list of scalar assertions that must hold.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/analysis.rs#L119) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ModelTest.html)

### `ModelTestAssertion` {#x-modeltestassertion}

*type* · canonical name `model_test_assertion`

```rust
pub struct ModelTestAssertion {
    pub variable: String,
    pub time: f64,
    pub expected: f64,
    pub tolerance: Option<Tolerance>,
    pub coords: Option<HashMap<String, f64>>,
    pub reduce: Option<String>,
    pub reference: Option<AssertionReference>,
}
```

A single scalar `(variable, time, expected)` check inside a [`ModelTest`](/generated/api/extension/rust#x-modeltest),
or one of its §6.6.5 PDE-aware variants: `coords` point-samples an array
state at physical coordinates, `reduce` collapses the variable's spatial
field to a scalar (`L2_error`/`Linf_error` against `reference`, or the
pure collapsers `integral`/`mean`/`max`/`min`). `coords` and `reduce` are
mutually exclusive per the schema.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/analysis.rs#L80) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ModelTestAssertion.html)

### `mount_edge_errors` {#x-mount_edge_errors}

*function* · canonical name `mount_edge_errors`

```rust
pub fn mount_edge_errors(document: &Value, base_dir: &Path) -> Vec<StructuralError>
```

The document's own §4.7 mount edges that do not resolve, as structured
`(code, path)` findings: every `subsystems.<k>` `{ref}` of a top-level
model or reaction system, at `/<block>/<system>/subsystems/<k>`, then every
top-level `models.<k>` / `reaction_systems.<k>` `{ref}` stub, at
`/<block>/<k>`.

Each edge is judged on its own, by the rules the loader applies at that
edge before resolving the leaf: the ref must locate, read and parse
(`unresolved_subsystem_ref` otherwise), and the leaf must yield the
component — exactly one system for a subsystem mount
(`ambiguous_subsystem_ref` otherwise), and for a top-level mount one
component of the form's kind, or the one its selector names
(`unresolved_subsystem_ref` otherwise). An edge that passes contributes
nothing, even when something deeper in the leaf fails; nested edges are
the leaf's own to report. Relative refs resolve against `base_dir`, the
document's directory.

A load that refuses the document while resolving its mounts carries these
as its `crate::EsmError::findings`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/ref_loading.rs#L1561) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.mount_edge_errors.html)

### `Num` {#x-num}

*type* · canonical name `num`

```rust
pub enum Num {
    Int(i64),
    Float(f64),
}
```

A numeric **value** for [`group_aggregate`](/generated/api/ref/group_aggregate). Unlike [`Key`](/generated/api/extension/rust#x-key), values may be
floating-point (only *keys* are float-forbidden, rule 1). Integer aggregates
stay integer (so a sum serialises as `5`, not `5.0`); a float anywhere in a
bucket promotes the reduction to `f64`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/relational.rs#L171) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Num.html)

### `observed_definition_json` {#x-observed_definition_json}

*function* · canonical name `observed_definition_json`

```rust
pub fn observed_definition_json<'a>(model: &'a Value, name: &str) -> Option<&'a Value>
```

An observed unknown's defining RHS, read from a model held as RAW JSON.

The JSON-view counterpart of [`observed_definitions`](/generated/api/ref/observed_definitions), for the passes and
tools that work on `serde_json::Value` (the cadence partition, the
projection-pushdown desugar, the CLI).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/classification.rs#L562) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.observed_definition_json.html)

### `observed_trajectories` {#x-observed_trajectories}

*function* · canonical name `observed_trajectories`

```rust
pub fn observed_trajectories(prob: &EsmProblem, sol: &Solution, names: &[String]) -> Result<Vec<(String, Vec<f64>)>, SimulateError>
```

[`observed_trajectory`](/generated/api/extension/rust#x-observed_trajectory) for several names, in ONE pass over the output grid.

The graph is walked once per output time however many names are asked for,
so a caller wanting five observeds should ask once rather than five times.

**Tolerant where the singular form is strict**, and returns `(name, values)`
pairs so a caller can tell which is which. A name that is not an observed
variable — most often a STATE, which the caller already has in `sol` — is
omitted rather than failing the whole call. That is what a host asking "give
me whichever of these are observed" needs: a test harness reading a model's
authored assertions knows the variable names but not which kind each is, and
one state in the list must not cost it the other four answers.

The returned names are the spellings that were ASKED FOR, not the resolved
ones, so a caller can key its own lookup by them.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/observed.rs#L330) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.observed_trajectories.html)

### `observed_trajectory` {#x-observed_trajectory}

*function* · canonical name `observed_trajectory`

```rust
pub fn observed_trajectory(prob: &EsmProblem, sol: &Solution, name: &str) -> Result<Vec<f64>, SimulateError>
```

The trajectory of the observed variable `name` over `sol`'s output grid.

The solution-aware half of [`observed_field`](/generated/api/ref/observed_field), and the answer to a question
neither argument can answer alone. An observed is a pure function of
`(state, params, t)`: `prob` holds the function — the topo-sorted observed
graph and the parameter bindings — and `sol` holds the arguments. That is
why this takes both, and why [`observed_field`](/generated/api/ref/observed_field) can only ever report fields
the BUILD materialized. A [`Solution`](/generated/api/ref/solution) carries state rows only, so an
observed of a model that does integrate has no other way out.

Named `observed_trajectory` rather than being a second arity of
`observed_field` because the return RANK differs: a field is the shape the
document declares, a trajectory is that shape with a time axis added. Two
ranks under one name is a contract a caller cannot read off the call. (A
binding that can overload — Julia, Python — may still spell it as an extra
arity of `observed_field`; API_SPEC §5.8 records the transliteration.)

Name resolution is §5.8's rule, the same one [`observed_field`](/generated/api/ref/observed_field) applies:
exact hit, then the component-qualified spelling, then a bare name only when
the problem has exactly one component.

A static problem has no trajectory at all and wants [`observed_field`](/generated/api/ref/observed_field).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/observed.rs#L285) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.observed_trajectory.html)

### `ParameterUpdateSpec` {#x-parameterupdatespec}

*type* · canonical name `parameter_update_spec`

```rust
pub enum ParameterUpdateSpec {
    Single(ParameterUpdate),
    Several(Vec<ParameterUpdate>),
}

impl ParameterUpdateSpec { pub fn for_each_expression_at(&self, f: &mut impl FnMut(&Expr, &str)) }

impl ParameterUpdateSpec { pub fn rules(&self) -> &[ParameterUpdate] }

impl ParameterUpdateSpec { pub fn is_wiener(&self) -> bool }

impl ParameterUpdateSpec { pub fn requires_shape(&self) -> bool }
```

A parameter's update behaviour (esm-spec §5.4, schema
`ParameterUpdateSpec`): EITHER a single rule, OR an ordered array of two or
more applied in declaration order.

A single rule MUST be the object form — a one-element array is invalid — so
every update set has exactly one spelling and the round trip is stable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L817) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ParameterUpdateSpec.html)

### `parse_cell_key` {#x-parse_cell_key}

*function* · canonical name `parse_cell_key`

```rust
pub fn parse_cell_key(key: &str) -> Option<(&str, Vec<usize>)>
```

Split a flat state-element name into `(base, 1-based indices)`, or `None`
when it is not a well-formed cell key (no bracket suffix, an empty base
name, or a non-integer index). The exact inverse of the `"{name}[{i},{j}]"`
formatting in `simulate_array::compile::build_slot_tables`, and the Rust
twin of Julia's `_parse_cell_key` / Python's equivalent.

Matches the Julia regex `^([^\[]+)\[([0-9]+(?:,[0-9]+)*)\]$`: the base name
may not itself contain `[`, so the FIRST bracket opens the index list.

```rust
use earthsci_ast::parse_cell_key;
assert_eq!(parse_cell_key("u[2,3]"), Some(("u", vec![2, 3])));
assert_eq!(parse_cell_key("Model.u[7]"), Some(("Model.u", vec![7])));
assert_eq!(parse_cell_key("plain"), None);
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/data_output.rs#L260) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_cell_key.html)

### `parse_document_with_sources` {#x-parse_document_with_sources}

*function* · canonical name `parse_document_with_sources`

```rust
pub fn parse_document_with_sources(text: &str, format: DocumentFormat) -> Result<(Value, Vec<ConstructSource>), DiagnosticError>
```

Read an ESM document as [`parse_document`](/generated/api/ref/parse_document) does, with where each of its
constructs is: one [`ConstructSource`](/generated/api/extension/rust#x-constructsource) per pointer, in the order the text
writes them. A construct that reads as several entries (a display holding
several equations, a container of initialization equations or
constraints, a table of declarations) gives one per entry, all with its
span. Prose, front matter and anything else that is not a construct of
the format gives none.

**Errors**

As [`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/document/mod.rs#L326) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_document_with_sources.html)

### `partition_model` {#x-partition_model}

*function* · canonical name `partition_model`

```rust
pub fn partition_model(model: &Value) -> Result<Partition, CadenceError>
```

Run the cadence-partition pass over one model: classify every annotated node,
derive the materialization frontier (both thresholds), check the guards
(expect-cadence agreement, no `CONTINUOUS` relational, acyclic `≤DISCRETE`
graph), and report the three execution outputs' emptiness. The model is the
inner `models.<name>` object (use `model_with_loaders` to attach the
document's `data_sources` first when the model reads loader-seeded variables).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/cadence.rs#L933) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.partition_model.html)

### `PlotY` {#x-ploty}

*type* · canonical name `plot_y`

```rust
pub enum PlotY {
    Axis(PlotAxis),
    Axes(Vec<PlotAxis>),
}
```

A [`Plot`](/generated/api/ref/plot)'s `y` field (schema `Plot.y` oneOf): a single axis, or an array
of axes for inline multi-series line/scatter plots. Untagged: an object is
the single-axis form, an array the multi-series form — the two JSON shapes
never collide.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/analysis.rs#L267) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.PlotY.html)

### `PrecisionRecord` {#x-precisionrecord}

*type* · canonical name `precision_record`

```rust
pub struct PrecisionRecord {
    pub variables: BTreeMap<String, VariablePrecisionRecord>,
    pub groups: BTreeMap<String, GroupPrecisionRecord>,
    pub integrator: BTreeMap<String, Value>,
    /* private fields */
}

impl PrecisionRecord { pub fn canonical_json(&self) -> Result<String, Error> }
```

Precision metadata an external integrator attaches to its results (§11.3.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L265) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/struct.PrecisionRecord.html)

### `PrecisionSource` {#x-precisionsource}

*type* · canonical name `precision_source`

```rust
pub enum PrecisionSource {
    Declared(Precision),
    Unspecified,
}
```

Whether a variable's evaluation precision is bound by the document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L197) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/enum.PrecisionSource.html)

### `PreparePhase` {#x-preparephase}

*type* · canonical name `prepare_phase`

```rust
pub enum PreparePhase {
    Rewrite,
    Load,
    ConstProviders,
    Coordinates,
    ValueInvention,
    MemberFactors,
    GatedFetch,
    Observeds,
}

impl PreparePhase { pub fn index(self) -> usize }

impl PreparePhase { pub fn label(self) -> &'static str }
```

Which stage of the build [`crate::problem::esm_problem`](/generated/api/ref/esm_problem-function) is in when it reports.

These are the document-independent stages of the build pipeline, in
the order it runs them, and they are exactly the stages
`crate::problem::ProblemOptions::verbose` already narrates — the observer did not invent a
structure, it made the existing one addressable.

**The stages are nowhere near equal in cost.** On the InMAP ISRM document a
`PreparePhase::GatedFetch` is tens of gigabytes over the network and
`PreparePhase::Observeds` is a source-by-receptor contraction, while
`PreparePhase::Rewrite` and `PreparePhase::Load` are milliseconds. A
host that renders `index() / COUNT` as a percentage will show a bar that
sprints to 60% and then sits still for ten minutes. Drive the bar from
`PrepareProgress::fraction` *within* the reported phase and name the phase
(and `PrepareProgress::item`) beside it instead — the same advice
[`crate::simulate::Progress`](/generated/api/extension/rust#x-progress) gives about a stiff solve's non-linear `t`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/prepare.rs#L150) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.PreparePhase.html)

### `PrepareProgress` {#x-prepareprogress}

*type* · canonical name `prepare_progress`

```rust
pub struct PrepareProgress<'a> {
    pub phase: PreparePhase,
    pub done: usize,
    pub total: Option<usize>,
    pub item: &'a str,
}

impl PrepareProgress<'_> { pub fn fraction(&self) -> f64 }
```

How far along an in-flight build is, handed to
`crate::problem::ProblemOptions::progress` at every phase boundary AND at every unit of
work inside the two phases that dominate a large build.

A report is delivered BEFORE the unit it names is done, so `item` is what
`prepare` is about to spend its time on — which is the useful thing to show,
and the only placement at which returning `Flow::Cancel` avoids the work
rather than following it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/prepare.rs#L225) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.PrepareProgress.html)

### `PrepareProgressFn` {#x-prepareprogressfn}

*type* · canonical name `prepare_progress_fn`

```rust
pub type PrepareProgressFn = Arc<dyn Fn(&PrepareProgress<'_>) -> Flow + Send + Sync>;
```

A build progress observer. See `crate::problem::ProblemOptions::progress`.

Unconditionally `Send + Sync`, unlike [`crate::simulate::ProgressFn`](/generated/api/extension/rust#x-progressfn), which
drops the bound on `wasm32` for a `js_sys::Function` observer: the whole
`prepare` module is `#[cfg(not(target_arch = "wasm32"))]`, so there is no
wasm host to accommodate and no reason to make native callers pay for one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/prepare.rs#L260) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.PrepareProgressFn.html)

### `ProblemInput` {#x-probleminput}

*type* · canonical name `problem_input`

```rust
pub enum ProblemInput<'a> {
    Path(&'a Path),
    Json(&'a Value),
    File(&'a EsmFile),
    Flattened(&'a FlattenedSystem),
}
```

What [`esm_problem`](/generated/api/ref/esm_problem-function) can be built from: a path on disk, a raw JSON
document, a typed document, or an already-flattened system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/mod.rs#L179) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ProblemInput.html)

### `ProblemOptions` {#x-problemoptions}

*type* · canonical name `problem_options`

```rust
pub struct ProblemOptions {
    pub p: HashMap<String, f64>,
    pub u0: HashMap<String, f64>,
    pub model_name: Option<String>,
    pub metaparameters: BTreeMap<String, i64>,
    pub base_path: Option<PathBuf>,
    pub callbacks: CallbackSet,
    pub rhs: Rhs,
    pub compiler: Option<Compiler>,
    pub pushdown_rewrite: bool,
    pub providers: HashMap<String, Box<dyn DataProvider>>,
    pub const_arrays: HashMap<String, ArrayD<f64>>,
    pub build_pipeline: bool,
    pub gated_fetch_batch: Option<usize>,
    pub verbose: bool,
    pub progress: Option<PrepareProgressFn>,
    pub inspect: bool,
    pub retain_data_fields: Vec<String>,
    pub observed_cone: Option<Vec<String>>,
    pub sample_time: Option<f64>,
    pub runtime_array_parameters: bool,
    pub strip: StripSet,
    /* private fields */
}
```

Build-time bindings for [`esm_problem`](/generated/api/ref/esm_problem-function) — everything that fixes a
*document* rather than a *run*.

The per-run knobs (`alg`, `abstol`, `reltol`, `saveat`, `callback`,
`maxiters`) live on [`SolveOptions`](/generated/api/extension/rust#x-solveoptions) instead. That split is the whole point
of §2.5: construction is deterministic per document and expensive, `solve`
is cheap and varies.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/mod.rs#L575) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ProblemOptions.html)

### `Progress` {#x-progress}

*type* · canonical name `progress`

```rust
pub struct Progress<'a> {
    pub t0: f64,
    pub t: f64,
    pub t_end: f64,
    pub step: usize,
    pub maxiters: Option<usize>,
    pub u: &'a [f64],
}

impl Progress<'_> { pub fn fraction(&self) -> f64 }
```

How far along an in-flight integration is, handed to
`SolveOptions::progress` once per accepted step.

`t` advances non-uniformly: an adaptive solver crawls through a stiff
startup and then takes large steps, so `Progress::fraction` is *not*
linear in wall clock. A host driving a progress bar from it should expect
the early part of a stiff run to look stalled, and is usually better off
showing `step` alongside the bar so a slow start still reads as alive.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L129) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Progress.html)

### `ProgressFn` {#x-progressfn}

*type* · canonical name `progress_fn`

```rust
pub type ProgressFn = Arc<dyn for<'p> Fn(&Progress<'p>) -> Flow + Send + Sync>;
```

A progress observer. See `SolveOptions::progress`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L185) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.ProgressFn.html)

### `ProviderError` {#x-providererror}

*error* · canonical name `provider_error`

```rust
pub type ProviderError = MessageError;
```

A provider or refresh-executor failure: a provider that cannot deliver, a
malformed loader-fed variable, a missing provider, a cadence-classification
disagreement, or a sample of the wrong shape.

Alias of the shared `crate::error::MessageError` newtype; its `Display` is
the bare message.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/provider.rs#L74) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/provider/type.ProviderError.html)

### `ProviderGate` {#x-providergate}

*type* · canonical name `provider_gate`

```rust
pub struct ProviderGate {
    pub axes: Vec<GateAxis>,
    pub applies_to: Vec<String>,
}
```

A provider-key ⇒ engine gate: per-NATIVE-axis selection plus the LOADER
variable tails the gate applies to.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L2404) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ProviderGate.html)

### `pushdown_coupling_pairs` {#x-pushdown_coupling_pairs}

*function* · canonical name `pushdown_coupling_pairs`

```rust
pub fn pushdown_coupling_pairs(doc: &Value) -> Vec<(String, String)>
```

The `(external name, model variable)` routings of a raw document: which
external field feeds which declared array.

The `from` side is `"<source>.<file_variable>"` and the `to` side is the
consuming parameter's namespaced name. A PROVIDER is keyed by the `to` side —
the consuming parameter is the only spelling that names one field and every
field, since a source declares no variables — so [`pushdown_provider_gates`](/generated/api/extension/rust#x-pushdown_provider_gates)
matches on `to`. These pairs remain the routing that lets an array supplied
under the SOURCE's spelling still reach its consumer.

Two spellings are read. A data source binds to the consuming parameter
through that parameter's own
`update: {kind: "data", source, from: {file_variable}}` (esm-spec §5.4,
§8.5); a NON-source producer may still feed a parameter through a
`variable_map` coupling edge. Either way the pair is "what feeds what".

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L2424) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.pushdown_coupling_pairs.html)

### `pushdown_provider_gates` {#x-pushdown_provider_gates}

*function* · canonical name `pushdown_provider_gates`

```rust
pub fn pushdown_provider_gates(doc: &Value, provider_keys: &[String]) -> Result<HashMap<String, ProviderGate>, PushdownRewriteError>
```

Provider-key ⇒ engine gate, derived from `doc`'s rewrite record
(`metadata.x_esd.pushdown.gated_select`).

A provider is GATED when its key names a `data_sources` variable
(`"<Loader>"` or `"<ModelPath>.<param>"`) that the document's `update`
rules — or a coupling `variable_map` — route
onto one of the record's `applies_to` model arrays. The gate's per-NATIVE-
axis `axes` come from the loader's own `metadata.x_esd.gated_select.axes`
template when it declares one (with the record's GENERATED set name
substituted), else from the model array's rank with `gated_by` at the
record's `gated_axis`. `applies_to` carries the LOADER-variable tails.
Empty when `doc` carries no record or no coupling routes a provider onto a
gated array.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L2572) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.pushdown_provider_gates.html)

### `pushdown_record` {#x-pushdown_record}

*function* · canonical name `pushdown_record`

```rust
pub fn pushdown_record(doc: &Value) -> Option<&Map<String, Value>>
```

The rewrite's provenance record `metadata.x_esd.pushdown` (written by
[`desugar_pushdown`](/generated/api/ref/desugar_pushdown)), or `None` when `doc` carries none. This is the
record the engine reads BACK to derive provider gates.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L68) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.pushdown_record.html)

### `PushdownRewriteError` {#x-pushdownrewriteerror}

*error* · canonical name `pushdown_rewrite_error`

```rust
pub struct PushdownRewriteError(pub String);
```

A malformed gate/record encountered while deriving provider gates (mirrors
the Julia `RefreshError` sites in pushdown_rewrite.jl and the Python
`PushdownRewriteError`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L51) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.PushdownRewriteError.html)

### `Rational` {#x-rational}

*type* · canonical name `rational`

```rust
pub struct Rational {
    /* private fields */
}

impl Rational { pub fn int(n: i32) -> Self }

impl Rational { pub fn new(num: i32, den: i32) -> Self }

impl Rational { pub fn from_f64(x: f64) -> Option<Self> }
```

A dimension exponent.

Exponents are RATIONAL, not integer: `1/s^0.5` — the intensity of an SDE
noise term — is a legitimate unit that appears in the shared corpus
(`tests/fixtures/sde/*.esm`), and `sqrt` halves whatever it is given. An
integer exponent could represent neither `sqrt(m^3)` nor `s^0.5`, and since
a dimensional mismatch is a hard error, legitimate files would be
rejected.

Always stored in lowest terms with a positive denominator, so `PartialEq`
is exact dimensional equality (½ and 2/4 compare equal) and `HashMap` lookups
are sound.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L41) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Rational.html)

### `RecordsPerFile` {#x-recordsperfile}

*type* · canonical name `records_per_file`

```rust
pub enum RecordsPerFile {
    Count(u32),
    Auto(AutoRecords),
}
```

Number of records per file — an integer, or the literal `"auto"`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L341) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.RecordsPerFile.html)

### `RegionBound` {#x-regionbound}

*type* · canonical name `region_bound`

```rust
pub enum RegionBound {
    Int(i64),
    Expr(Expr),
}

impl RegionBound { pub fn as_i64(&self) -> Option<i64> }
```

One bound of a `makearray` region box (esm-spec §4.3.2).

Almost always a concrete integer: esm-spec §9.7.6 folds metaparameter bound
expressions to integers at LOAD time, so every `regions` entry that reaches
an evaluator is an `RegionBound::Int`, and every consumer here treats a
still-symbolic bound the way it treats a malformed region — it refuses the
node rather than guessing an extent.

The `RegionBound::Expr` variant exists for the PRE-load form the schema
admits (`"regions": [[[2, {"op": "-", "args": ["NLON", 1]}]]]`, whose bound
pairs are `MetaparameterExpression`s). Without it the Rust AST could not
hold a document the other bindings load unchanged.

`RegionBound::Int` is listed FIRST in this untagged enum so a JSON integer
still binds to it (and round-trips as an integer), exactly as before.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/expression.rs#L265) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.RegionBound.html)

### `Remake` {#x-remake}

*type* · canonical name `remake`

```rust
pub struct Remake {
    pub p: HashMap<String, f64>,
    pub u0: HashMap<String, f64>,
    pub tspan: Option<(f64, f64)>,
    pub callbacks: Option<CallbackSet>,
}
```

The substitutions [`remake`](/generated/api/ref/remake) applies. Every field is optional; an omitted
field is inherited unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/remake.rs#L12) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Remake.html)

### `remove_model` {#x-remove_model}

*function* · canonical name `remove_model`

```rust
pub fn remove_model(esm_file: &EsmFile, model_id: &str) -> EditResult<EsmFile>
```

Remove a model from an ESM file

**Arguments**

* `esm_file` - The ESM file to modify
* `model_id` - Identifier of the model to remove

**Returns**

* `EditResult<EsmFile>` - New ESM file without the model

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L120) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_model.html)

### `replace_coupling` {#x-replace_coupling}

*function* · canonical name `replace_coupling`

```rust
pub fn replace_coupling(esm_file: &EsmFile, index: usize, coupling: CouplingEntry) -> EditResult<EsmFile>
```

Replace a coupling entry in an ESM file

**Arguments**

* `esm_file` - The ESM file to modify
* `index` - Index of the coupling entry to replace
* `coupling` - The new coupling entry

**Returns**

* `EditResult<EsmFile>` - New ESM file with the replaced coupling entry

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L515) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.replace_coupling.html)

### `replace_equation` {#x-replace_equation}

*function* · canonical name `replace_equation`

```rust
pub fn replace_equation(model: &Model, index: usize, equation: Equation) -> EditResult<Model>
```

Replace an equation in a model

**Arguments**

* `model` - The model to modify
* `index` - Index of the equation to replace
* `equation` - The new equation

**Returns**

* `EditResult<Model>` - New model with the replaced equation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L223) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.replace_equation.html)

### `resolve_subsystem_refs_raw` {#x-resolve_subsystem_refs_raw}

*function* · canonical name `resolve_subsystem_refs_raw`

```rust
pub fn resolve_subsystem_refs_raw(value: &mut Value, base_path: &Path) -> Result<(), DiagnosticError>
```

Resolve all subsystem references in a parsed JSON value representing an
ESM file.

Walks every `subsystems` map in models and reaction systems and inlines
the referenced content. Resolution is recursive (referenced files may
contain their own refs) and circular references are detected.

A referenced subsystem file's top-level `index_sets` merge into the
importing document's registry (esm-spec §4.7, mirroring the §9.7.5
template-import merge): deep-equal redeclaration is idempotent, an absent
name is added, and a non-deep-equal collision is `subsystem_index_set_conflict`.
The merge is scoped to MODEL mounts, matching the Julia resolver (a mounted
mesh file whose axis size disagrees with the importer must fail at load
rather than the importer silently winning) — and it applies to BOTH model
mount forms: a `subsystems.<k>` ref and a top-level `models.<k>` ref
(`inline_toplevel_refs`) merge identically.

**Arguments**

* `value` - the parsed ESM JSON to resolve (modified in place)
* `base_path` - directory to resolve relative file paths against

This is the raw-`serde_json::Value` extension seam (API_SPEC.md §8 item
14): it is what the LOADER runs, before the document is coerced to an
[`crate::EsmFile`](/generated/api/ref/esm_file). A caller holding a typed document wants
[`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/ref_loading.rs#L84) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_subsystem_refs_raw.html)

### `resolve_subsystem_refs_with_metaparameters` {#x-resolve_subsystem_refs_with_metaparameters}

*function* · canonical name `resolve_subsystem_refs_with_metaparameters`

```rust
pub fn resolve_subsystem_refs_with_metaparameters(value: &mut Value, base_path: &Path, api_meta: &BTreeMap<String, i64>) -> Result<Map<String, Value>, DiagnosticError>
```

Like [`resolve_subsystem_refs_raw`](/generated/api/extension/rust#x-resolve_subsystem_refs_raw), but with the loader-API metaparameter
bindings (esm-spec §9.7.6 site 4) available, so a §4.7 subsystem-edge
binding EXPRESSION (`NTGT = NX*NY`, §9.7.6 site 3) folds against the root
document's closed metaparameter environment (defaults overlaid with the API
bindings) at the mount. Mirrors the Python `resolve_model_refs(...,
parent_metaparameters=root_meta_env)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/ref_loading.rs#L162) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_subsystem_refs_with_metaparameters.html)

### `resolve_tolerance` {#x-resolve_tolerance}

*function* · canonical name `resolve_tolerance`

```rust
pub fn resolve_tolerance(model_tol: Option<&Tolerance>, test_tol: Option<&Tolerance>, assertion_tol: Option<&Tolerance>) -> (f64, f64)
```

esm-spec §6.6.4, resolved PER FIELD over FOUR levels: assertion > test >
model > the implementation default. Each of `rel` and `abs` independently
takes its value from the innermost level that declares it; the default
supplies `rel = 1e-6` and no `abs` bound to whatever is still undeclared
after the three document levels. Identical to the Julia
`_resolve_tolerance` reference and the Python `_resolve_tolerance`. Returns
`(rtol, atol)`.

The merge is per-field and NOT wholesale. A level that declares only `abs`
does not mask an outer level's `rel`: with a model `{rel: 1e-6}` and an
assertion `{abs: 1e-9}` the resolved pair is `(1e-6, 1e-9)`, not
`(0, 1e-9)`. Returning the first `Some` block whole — what this did before
#228 — ran such an assertion with NO relative bound at all, silently
dropping a tolerance its author declared one level up.

**Absent vs zero.** A field is absent when the key is missing or JSON-null
(the schema admits only a number, so `null` is non-conforming input treated
as absent); only an absent field falls through. An explicit `0` is a
DECLARATION — "no bound of this kind" — and stops the fallthrough, the
default included. That distinction carries the whole rule: the recurrence
fixtures pin exactness with a model-level `{rel: 0, abs: 0}`
(CONFORMANCE_SPEC §5.19), and `rel: 0` is how a document says "this
absolute bound and nothing else" now that the default is not terminal.

**The implementation default is the FOURTH LEVEL** of the same per-field
merge, not a fallback reached only when levels 1-3 are silent. An assertion
declaring only `{abs: 1e-4}` therefore resolves to `rel = 1e-6`, not
`rel = 0`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L660) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_tolerance.html)

### `Rhs` {#x-rhs}

*type* · canonical name `rhs`

```rust
pub enum Rhs {
    Auto,
    Always,
    Never,
}
```

Whether [`esm_problem`](/generated/api/ref/esm_problem-function) compiles a right-hand side.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/mod.rs#L213) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Rhs.html)

### `rhs_program_with_options` {#x-rhs_program_with_options}

*function* · canonical name `rhs_program_with_options`

```rust
pub fn rhs_program_with_options(file: &EsmFile, tspan: (f64, f64), problem_options: ProblemOptions, options: RhsOptions) -> Result<RhsProgram, SimulateError>
```

Build an external RHS with a working precision for unspecified variables.

The choice applies before the ordinary Problem build so compiler passes,
constant folding and provider ingress run at the same working precision
as the resulting program. The input file remains unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L629) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.rhs_program_with_options.html)

### `RhsError` {#x-rhserror}

*error* · canonical name `rhs_error`

```rust
pub enum RhsError {
    StatePrecision { variable: String, declared: Precision },
    Fault { code: &'static str, message: String },
    Shape { what: &'static str, expected: usize, got: usize },
    ForeignProgram { what: &'static str },
    ForcingSignature { detail: String },
    SlotIndex { slot: usize, slots: usize },
    NotGathered,
    MixedTimes { detail: String },
}
```

Why a program evaluation (`eval_into`) failed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L14) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.RhsError.html)

### `RhsOptions` {#x-rhsoptions}

*type* · canonical name `rhs_options`

```rust
pub struct RhsOptions {
    pub unspecified_evaluation: Precision,
}
```

External evaluation options for one RHS evaluation group.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L59) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.RhsOptions.html)

### `RhsProgram` {#x-rhsprogram}

*type* · canonical name `rhs_program`

```rust
pub struct RhsProgram {
    /* private fields */
}

impl RhsProgram { pub fn compiler(&self) -> Compiler }

impl RhsProgram { pub fn writes(&self) -> &[String] }

impl RhsProgram { pub fn aux(&self) -> &[String] }

impl RhsProgram { pub fn layout(&self) -> &TileLayout }

impl RhsProgram { pub fn n_states(&self) -> usize }

impl RhsProgram { pub fn state_layout(&self) -> &[StateBlock] }

impl RhsProgram { pub fn precision(&self) -> Precision }

impl RhsProgram { pub fn state_precisions(&self) -> &[Precision] }

impl RhsProgram { pub fn round_state(&self, u: &mut [f64]) -> Result<(), RhsError> }

impl RhsProgram { pub fn parameters(&self) -> &[ParamSlot] }

impl RhsProgram { pub fn parameter_vector(&self, overrides: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> }

impl RhsProgram { pub fn forcing_slots(&self) -> &[ForcingSlot] }

impl RhsProgram { pub fn default_forcing(&self) -> ForcingSet }

impl RhsProgram { pub fn default_state(&self) -> (Vec<f64>, Vec<f64>) }

impl RhsProgram { pub fn precision_sources(&self) -> &[PrecisionSource] }

impl RhsProgram { pub fn flattened(&self) -> &FlattenedSystem }

impl RhsProgram { pub fn select(&self, sel: &RhsSelection) -> Result<RhsProgram, SimulateError> }

impl RhsProgram { pub fn halo(&self, dec: &Decomposition) -> Result<HaloReport, SimulateError> }

impl RhsProgram { pub fn tile(&self, dec: &Decomposition, bx: &TileBox) -> Result<TileProgram, SimulateError> }

impl RhsProgram { pub fn lanes(&self, kind: LaneKind, capacity: usize) -> Result<LaneProgram, SimulateError> }

impl RhsProgram { pub fn new_workspace(&self) -> RhsWorkspace }

impl RhsProgram { pub fn eval_into<T: StateScalar>(&self, u: &[T], aux: &[f64], p: &[f64], t: f64, forcing: &ForcingSet, du: &mut [T], ws: &mut RhsWorkspace) -> Result<(), RhsError> }
```

A compiled right-hand side, possibly restricted to one operator's terms
and writes (API_SPEC §5.8). Made by [`rhs_program`](/generated/api/ref/rhs_program).

Built once and immutable: `Send + Sync`, and cheap to clone (every clone
shares one program). Evaluate it concurrently with one [`RhsWorkspace`](/generated/api/extension/rust#x-rhsworkspace)
per thread; a call never starts a thread of its own.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L538) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.RhsProgram.html)

### `RhsWorkspace` {#x-rhsworkspace}

*type* · canonical name `rhs_workspace`

```rust
pub struct RhsWorkspace {
    /* private fields */
}
```

The per-call buffers of one program (API_SPEC §5.8): reused across calls,
so a warm call allocates nothing. Made by the program that runs it, and
usable only with that program (or a clone of it), one call at a time. It
may move between threads (`Send`); it is not `Sync`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L397) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.RhsWorkspace.html)

### `run_inline_tests_paths` {#x-run_inline_tests_paths}

*function* · canonical name `run_inline_tests_paths`

```rust
pub fn run_inline_tests_paths(paths: &[impl AsRef<Path>], options_for: &dyn Fn(&Path) -> InlineTestOptions) -> Vec<AssertionResult>
```

Run the inline tests of every document in `paths`, asking `options_for` for
each document's options.

This is the corpus entry: it takes PATHS rather than a loaded [`EsmFile`](/generated/api/ref/esm_file),
because the thing a caller varies per document — the solver, the tolerances,
an initial-condition seed — is keyed by the document, and a caller that had
to load each file itself to get at that would be back to writing the loop
this function is. A `paths` entry that is a DIRECTORY expands to the `.esm`
files under it, recursively and sorted; results are concatenated in that
order.

A document that fails to load contributes one ERROR row naming the path and
the run continues, so one unreadable file cannot cost the run every other
file's verdicts. `options_for` is consulted BEFORE the load, so it is asked
about the unreadable file too and wants a default rather than a panic.

What stays with the CALLER, deliberately: per-file process isolation and
memory limits, JUnit emission, summary formatting, and root discovery. A
library should not impose a process model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L3435) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.run_inline_tests_paths.html)

### `run_inline_tests_with_options` {#x-run_inline_tests_with_options}

*function* · canonical name `run_inline_tests_with_options`

```rust
pub fn run_inline_tests_with_options(file: &EsmFile, opts: &InlineTestOptions) -> Vec<AssertionResult>
```

[`run_inline_tests`](/generated/api/ref/run_inline_tests) driven by a whole [`InlineTestOptions`](/generated/api/ref/inline_test_options) — the entry a
caller with one loaded document and any knob beyond the solver wants: the
`from_file` anchor, a test filter, override seeds, the compiler, and the
document's `data_sources` ingested through
`InlineTestOptions::providers`.

`opts.base_dir` is used as given: unlike [`run_inline_tests_paths`](/generated/api/extension/rust#x-run_inline_tests_paths), there
is no path here to fall back to, so a caller with `from_file` references
must set it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L3199) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.run_inline_tests_with_options.html)

### `ScaleFactor` {#x-scalefactor}

*type* · canonical name `scale_factor`

```rust
pub enum ScaleFactor {
    Prime(u64),
    Pi,
}
```

One factor of an [`ExactScale`](/generated/api/ref/exact_scale): a prime number, or π.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L195) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ScaleFactor.html)

### `ScopedContext` {#x-scopedcontext}

*type* · canonical name `scoped_context`

```rust
pub struct ScopedContext {
    pub models: IndexMap<String, Model>,
    pub reaction_systems: IndexMap<String, ReactionSystem>,
    pub current_scope: Vec<String>,
}

impl ScopedContext { pub fn from_esm_file(esm_file: &EsmFile) -> Self }

impl ScopedContext { pub fn with_scope(self, scope: Vec<String>) -> Self }

impl ScopedContext { pub fn resolve_scoped_reference(&self, scoped_ref: &str) -> Option<String> }
```

Context for hierarchical scoped reference resolution

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/substitute.rs#L229) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ScopedContext.html)

### `SemiringOp` {#x-semiringop}

*type* · canonical name `semiring_op`

```rust
pub enum SemiringOp {
    Sum,
    Prod,
    Min,
    Max,
}
```

An associative + commutative semiring combiner for [`group_aggregate`](/generated/api/ref/group_aggregate)
(rule 5). Every registry `⊕` is one of these, so input and bucket order can
never change the result.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/relational.rs#L214) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.SemiringOp.html)

### `serialize_keys` {#x-serialize_keys}

*function* · canonical name `serialize_keys`

```rust
pub fn serialize_keys(rows: &[Key]) -> String
```

Serialise an already-distinct, already-sorted slice of keys to the canonical
compact-JSON index-set form (no further dedup/sort).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/relational.rs#L443) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.serialize_keys.html)

### `serialize_pairs` {#x-serialize_pairs}

*function* · canonical name `serialize_pairs`

```rust
pub fn serialize_pairs(rows: &[(Key, Num)]) -> String
```

Serialise the `(key, aggregate)` output of [`group_aggregate`](/generated/api/ref/group_aggregate) to the
canonical compact-JSON form, each pair as a two-element array `[key, value]`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/relational.rs#L451) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.serialize_pairs.html)

### `SlotKind` {#x-slotkind}

*type* · canonical name `slot_kind`

```rust
pub enum SlotKind {
    Forcing,
    ArrayParameter,
}
```

What a forcing slot carries.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L130) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.SlotKind.html)

### `SolutionMetadata` {#x-solutionmetadata}

*type* · canonical name `solution_metadata`

```rust
pub struct SolutionMetadata {
    pub alg: String,
    pub integrator_precision: Option<IntegratorPrecision>,
    pub n_rhs_calls: usize,
    pub n_jacobian_calls: usize,
    pub n_accepted_steps: usize,
    pub n_rejected_steps: usize,
    pub merged_variable_renames: HashMap<String, String>,
    pub namespace: Option<String>,
}
```

Provenance metadata for a [`Solution`](/generated/api/ref/solution).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L497) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SolutionMetadata.html)

### `solve_ensemble` {#x-solve_ensemble}

*function* · canonical name `solve_ensemble`

```rust
pub fn solve_ensemble(ens: &EnsembleProblem<'_>, opts: &SolveOptions) -> Result<Vec<Solution>, SimulateError>
```

Solve every trajectory of `ens`, in index order (§2.5.8).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/remake.rs#L226) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.solve_ensemble.html)

### `solve_to_completion` {#x-solve_to_completion}

*function* · canonical name `solve_to_completion`

```rust
pub fn solve_to_completion(integrator: &mut Integrator<'_>) -> Result<Solution, SimulateError>
```

Run `integrator` to completion (§2.5.6's `solve!`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/solve.rs#L598) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.solve_to_completion.html)

### `SolveOptions` {#x-solveoptions}

*type* · canonical name `solve_options`

```rust
pub struct SolveOptions {
    pub alg: Alg,
    pub abstol: Option<f64>,
    pub reltol: Option<f64>,
    pub maxiters: Option<usize>,
    pub saveat: Option<Vec<f64>>,
    pub callback: Option<CallbackSet>,
    pub progress: Option<ProgressFn>,
    pub output_observed: Vec<String>,
}

impl SolveOptions { pub fn abstol_or_default(&self) -> f64 }

impl SolveOptions { pub fn reltol_or_default(&self) -> f64 }

impl SolveOptions { pub fn sample_evenly(&mut self, t0: f64, t_end: f64, n: usize) }
```

Per-run knobs for [`crate::problem::solve`](/generated/api/ref/solve).

Every field carries the canonical SciML spelling (`API_SPEC.md` §4):
`alg`, `abstol`, `reltol`, `saveat`, `maxiters`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/api.rs#L192) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SolveOptions.html)

### `state_cells` {#x-state_cells}

*function* · canonical name `state_cells`

```rust
pub fn state_cells(element_names: &[String], variable: &str, model: &str) -> Vec<(Vec<i64>, usize)>
```

Collect the (cell-index-tuple, row) pairs of one array state from the
simulation's element names (`element_names[row]` is the name of state row
`row`, e.g. `"Heat.u[3]"`). Flattening prefixes element names with the
owning model, and a coupled build may reuse the same bare array name across
components (`M1.u`, `M2.u`); to avoid mixing every model's cells into one
field, the model-qualified stem wins — an exact `model.variable` /
bare-`variable` stem match first, then a bare-suffix fallback reached only
when no exact stem exists (a bare-keyed single-model build). This is the
array analog of `scalar_slot`'s qualified-first two-pass resolution.
Sorted by cell tuple so callers get a deterministic pairing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/inline_tests.rs#L563) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.state_cells.html)

### `StateScalar` {#x-statescalar}

*type* · canonical name `state_scalar`

```rust
pub trait StateScalar: Sealed + Copy + Send + Sync + 'static {
    const PRECISION: Precision;
    fn widen(self) -> f64;
    fn narrow(value: f64) -> Self;
}
```

A scalar exchanged with an external integrator by the compiled RHS.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L147) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/trait.StateScalar.html)

### `StepStatus` {#x-stepstatus}

*type* · canonical name `step_status`

```rust
pub enum StepStatus {
    Advanced,
    Done,
}
```

Whether an [`Integrator`](/generated/api/ref/integrator) has more to do.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/problem/solve.rs#L431) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.StepStatus.html)

### `StoichiometricEntry` {#x-stoichiometricentry}

*type* · canonical name `stoichiometric_entry`

```rust
pub struct StoichiometricEntry {
    pub species: String,
    pub coefficient: f64,
}
```

Species with stoichiometric coefficient.

Coefficients may be fractional (e.g. `0.87 CH2O` in atmospheric
chemistry) as well as integer. The coefficient MUST be positive and
finite: NaN, ±∞, zero and negative values are rejected when the document
loads ([`load_string`](/generated/api/ref/load_string), [`load_path`](/generated/api/ref/load_path)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L166) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StoichiometricEntry.html)

### `StrippedEvent` {#x-strippedevent}

*type* · canonical name `stripped_event`

```rust
pub struct StrippedEvent {
    pub id: String,
    pub origin: TermOrigin,
    pub kind: EventKind,
    pub body: Map<String, Value>,
    /* private fields */
}
```

One removed event, flattened and namespaced.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L145) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StrippedEvent.html)

### `StrippedInitialization` {#x-strippedinitialization}

*type* · canonical name `stripped_initialization`

```rust
pub struct StrippedInitialization {
    pub unknowns: Vec<String>,
    pub x0: Vec<Option<f64>>,
    pub residuals: Vec<StrippedResidual>,
}
```

The removed implicit part of the initialization system (`strip` class
`initialization`, API_SPEC §5.8; the member's shape as PR #820 drafted it).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L215) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StrippedInitialization.html)

### `StrippedResidual` {#x-strippedresidual}

*type* · canonical name `stripped_residual`

```rust
pub struct StrippedResidual {
    pub id: String,
    pub origin: TermOrigin,
    pub shape: Vec<usize>,
    pub expr: Expr,
    /* private fields */
}
```

One stripped implicit equation, as the residual `lhs - rhs`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L176) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StrippedResidual.html)

### `StrippedUpdate` {#x-strippedupdate}

*type* · canonical name `stripped_update`

```rust
pub struct StrippedUpdate {
    pub parameter: String,
    pub origin: TermOrigin,
    pub rules: Vec<Value>,
    /* private fields */
}
```

One stripped parameter and its update rules.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L164) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StrippedUpdate.html)

### `StripSet` {#x-stripset}

*type* · canonical name `strip_set`

```rust
pub struct StripSet(/* private field */);
impl StripSet { pub fn parse(name: &str) -> Option<StripSet> }
impl StripSet { pub fn from_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Result<StripSet, String> }
impl StripSet { pub fn contains(self, other: StripSet) -> bool }
impl StripSet { pub fn is_empty(self) -> bool }
impl StripSet { pub fn names(self) -> Vec<&'static str> }
```

The construct classes `esm_problem` strips (API_SPEC §5.8). Combine with
`|`; the empty set is the default and changes nothing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L30) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StripSet.html)

### `StructuralErrorCode` {#x-structuralerrorcode}

*type* · canonical name `structural_error_code`

```rust
pub enum StructuralErrorCode {
    DefinitionUnitMismatch,
    IcSystemUnbalanced,
    UnresolvedSubsystemRef,
    AmbiguousSubsystemRef,
    MountFormUnsupported,
    ArrayShapeMismatch,
    ArrayDefaultWithoutShape,
    VariableBoundCircular,
    VariableBoundShapeMismatch,
    VariableBoundsInverted,
    CircularDependency,
    DataSourceUndefined,
    RecordsPerSampleInvalid,
    RecordAxisInvalid,
    RecordAxisMisplaced,
    RecordAxisTimeInvariantSource,
    DomainUnitMismatch,
    EquationCountMismatch,
    EquationDefinesParameter,
    EventAffectsParameter,
    EventVarUndeclared,
    FactorWithExpressionTransform,
    FaqBareArrayOperand,
    IcInReactionSystem,
    InvalidBroadcastFn,
    JoinKeyInvalidType,
    JoinSideAmbiguous,
    JoinSymsUnknownSymbol,
    NullReaction,
    ObservedCycle,
    OperatorVariableMissing,
    RaggedValuesNotGathered,
    RecurrenceNotWellfounded,
    RecurrenceUnsupportedForm,
    RecurrenceGroupAxisMismatch,
    RelationalNodeInContinuous,
    ReservedVariableName,
    UnknownOverrideKey,
    AssertionRankMismatch,
    UnitInconsistency,
    UnitParseError,
    UndefinedIndexSet,
    UndefinedOperator,
    UndefinedParameter,
    UndefinedSpecies,
    UndefinedSystem,
    UndefinedVariable,
    UnboundIndexSymbol,
    UnresolvedScopedRef,
}

impl StructuralErrorCode { pub fn as_str(&self) -> &'static str }
```

The codes a structural validation finding carries
(`crate::validate::StructuralError::code`): the registry entries
marked `=> Variant`, one variant each.

Serialized in `snake_case`, which is each code's own value, so the
wasm-boundary JSON matches this type's `std::fmt::Display` output
and the cross-binding contract in `tests/invalid/expected_errors.json`
(e.g. `undefined_variable`, not the default PascalCase
`UndefinedVariable`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/diagnostic.rs#L141) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.StructuralErrorCode.html)

### `Subsystem` {#x-subsystem}

*type* · canonical name `subsystem`

```rust
pub enum Subsystem<C> {
    Inline(Box<C>),
    Reference(SubsystemRef),
}

impl<C> Subsystem<C> { pub fn inline(component: C) -> Self }

impl<C> Subsystem<C> { pub fn as_inline(&self) -> Option<&C> }

impl<C> Subsystem<C> { pub fn as_inline_mut(&mut self) -> Option<&mut C> }

impl<C> Subsystem<C> { pub fn as_reference(&self) -> Option<&SubsystemRef> }
```

One entry of a component's `subsystems` map (esm-spec §4.7): a child
component written inline, or a `{"ref": …}` mount edge.

`C` is the owning component's kind: a [`Model`](/generated/api/ref/model)'s subsystems are models,
a [`ReactionSystem`](/generated/api/ref/reaction_system)'s are reaction systems. Every `load_*` entry point
resolves each mount edge before it types the document, so a loaded
document holds only `Subsystem::Inline` entries; a
`Subsystem::Reference` is what a document built in code holds before it
is resolved.

An entry with a `ref` key reads as a reference; any other entry must
decode as `C`, and one that does not is a decode error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/subsystem.rs#L23) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Subsystem.html)

### `TileBlock` {#x-tileblock}

*type* · canonical name `tile_block`

```rust
pub struct TileBlock {
    pub name: String,
    pub sets: Vec<String>,
    pub storage: Vec<(i64, i64)>,
    pub owned: Vec<(i64, i64)>,
    pub base: usize,
    pub strides: Vec<usize>,
}

impl TileBlock { pub fn slot(&self, g: &[i64]) -> Option<usize> }

impl TileBlock { pub fn len(&self) -> usize }

impl TileBlock { pub fn is_empty(&self) -> bool }
```

One variable's block in a tile's (or a whole-domain program's) inputs
(API_SPEC §5.8, "Tile layout"): a column-major block over its storage box,
first index fastest.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L181) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.TileBlock.html)

### `TileBox` {#x-tilebox}

*type* · canonical name `tile_box`

```rust
pub struct TileBox {
    pub owned: Vec<(String, RangeInclusive<i64>)>,
    pub storage: Vec<(String, RangeInclusive<i64>)>,
}
```

One tile's owned box and storage box, one inclusive range per decomposed
index set, in global 1-based indices; a periodic storage range is
unwrapped (it may run below 1 or past `N`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L96) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.TileBox.html)

### `TileLayout` {#x-tilelayout}

*type* · canonical name `tile_layout`

```rust
pub struct TileLayout {
    pub u: Vec<TileBlock>,
    pub aux: Vec<TileBlock>,
    pub u_len: usize,
    pub aux_len: usize,
}

impl TileLayout { pub fn block(&self, name: &str) -> Option<&TileBlock> }
```

A program's `u` and `aux` layout (API_SPEC §5.8): the written variables'
blocks, then the read-only ones, each list in flat-layout order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L229) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.TileLayout.html)

### `TileProgram` {#x-tileprogram}

*type* · canonical name `tile_program`

```rust
pub struct TileProgram {
    /* private fields */
}

impl TileProgram { pub fn layout(&self) -> &TileLayout }

impl TileProgram { pub fn forcing_slots(&self) -> &[ForcingSlot] }

impl TileProgram { pub fn new_workspace(&self) -> RhsWorkspace }

impl TileProgram { pub fn eval_into(&self, u: &[f64], aux: &[f64], p: &[f64], t: f64, forcing: &ForcingSet, du: &mut [f64], ws: &mut RhsWorkspace) -> Result<(), RhsError> }
```

One tile of a [`RhsProgram`](/generated/api/extension/rust#x-rhsprogram) (RFC U3 §4): it reads `u` and `aux` over their
storage boxes and writes only the owned rows of `du`.

`Send + Sync + Clone`: it holds the program and plain layout data, so
tiles of one rank can share it across threads, each with its own
[`RhsWorkspace`](/generated/api/extension/rust#x-rhsworkspace). It reads the forcing sets of the program it was cut
from.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/tile.rs#L42) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.TileProgram.html)

### `TimeOriginSource` {#x-timeoriginsource}

*type* · canonical name `time_origin_source`

```rust
pub trait TimeOriginSource: Temporal {}
```

What the §2.2.7 clock accessors read a time origin from: a document, or
its `domain` alone (esm-spec §2.2.7).

Implemented for

- [`crate::EsmFile`](/generated/api/ref/esm_file), a loaded or in-memory document;
- [`crate::Domain`](/generated/api/ref/domain), a typed domain;
- `serde_json::Value`, the raw JSON `domain` of a document that has not
  been loaded — read as the load-time check reads it, so a present key
  selects its field, `null` included, and a `domain` or `temporal` that is
  not an object has no origin field (a missing domain is `Value::Null`);
- `Option<T>` (`None` is a document without a domain), `&T`, `Box<T>`,
  `Rc<T>` and `Arc<T>`, for any source `T`, so a caller holding a document
  behind a pointer passes it as it is.

A raw `domain` that is neither an object nor `null` (a string, an array, a
number or a boolean) has no origin to read: the accessors refuse it with
`time_origin_invalid`, naming `/domain`.

The trait is sealed: its one method is private to this crate.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/solver.rs#L604) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/trait.TimeOriginSource.html)

### `UnitConversion` {#x-unitconversion}

*type* · canonical name `unit_conversion`

```rust
pub enum UnitConversion {
    Factor(f64),
    Expression(Expr),
}
```

Multiplicative factor (number) or Expression AST used to convert source-
file values to the declared units.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L365) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.UnitConversion.html)

### `UnitError` {#x-uniterror}

*error* · canonical name `unit_error`

```rust
pub enum UnitError {
    ParseError(String),
    DimensionMismatch(String),
    UnknownUnit(String),
}
```

Error types for unit operations

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L440) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.UnitError.html)

### `UnitParseFailure` {#x-unitparsefailure}

*type* · canonical name `unit_parse_failure`

```rust
pub struct UnitParseFailure {
    pub name: String,
    pub units: String,
}
```

A declared unit string that denotes no real unit.

Carries the NAME of the declaration alongside the offending string so the
caller can report `unit_parse_error` at the declaration's JSON-Pointer
rather than at the model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L2575) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.UnitParseFailure.html)

### `UnitSeverity` {#x-unitseverity}

*type* · canonical name `unit_severity`

```rust
pub enum UnitSeverity {
    Error,
    Analysis,
    DefinitionMismatch,
    DefinitionUndetermined,
}
```

Severity of a dimensional finding — the cross-binding policy that decides
whether a finding blocks validation.

The split is drawn at *provability*, and it is decided AT THE POINT the
finding is raised (mirroring the TypeScript reference, whose `UnitWarning`
carries the same classification):

* `UnitSeverity::Error` — a PROVABLE dimensional inconsistency: every
  operand's dimension was determined, and they are incompatible. That is a
  defect in the FILE, so it is promoted by `structural.rs` to a
  `unit_inconsistency` structural error and makes `is_valid` false. The
  shared corpus requires this: `tests/invalid/expected_errors.json` pins the
  `units_*.esm` fixtures as `is_valid: false` with a structural error, so a
  binding that keeps them as warnings ACCEPTS files the corpus pins invalid.

* `UnitSeverity::Analysis` — the checker could not DETERMINE a dimension
  (unknown variable, unparseable unit string, symbolic/non-literal exponent,
  wrong arity, a broadcast missing its `fn`). This reports what the checker
  could not conclude, NOT a defect in the file, so it stays a non-blocking
  warning and the affected subexpression propagates as `Dim::Unknown`.

An operator with NO dimensional rule (an open-tier rewrite target such as
`integral`, or any unregistered user op) is the one
undeterminable case that emits NO finding at all: per esm-spec §4.8.4 the
checker reports UNKNOWN and skips silently, matching the other four bindings
(Julia/TS/Python/Go). See `propagate_operator_dim`.

An unknown *variable* stays `Analysis` here only because it is already a
hard `undefined_variable` structural error — the file is still rejected; we
just do not double-report it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/units.rs#L480) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.UnitSeverity.html)

### `update_model_metadata` {#x-update_model_metadata}

*function* · canonical name `update_model_metadata`

```rust
pub fn update_model_metadata(model: &Model, name: Option<String>, description: Option<String>) -> EditResult<Model>
```

Update model metadata

**Arguments**

* `model` - The model to modify
* `name` - New name (None to keep current)
* `description` - New description (None to keep current)

**Returns**

* `EditResult<Model>` - New model with updated metadata

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/edit.rs#L373) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.update_model_metadata.html)

### `UpdateValue` {#x-updatevalue}

*type* · canonical name `update_value`

```rust
pub struct UpdateValue {
    pub expression: Option<Expr>,
    pub from: Option<DataSourceBinding>,
    pub handler: Option<FunctionalUpdate>,
}
```

The value form of an update rule: exactly one of `expression`, `from`, or
`handler` (esm-spec §5.4, "What: exactly one value form"). Modelled as three
options rather than an enum so the flattened round trip stays verbatim; the
"exactly one" constraint is a schema-layer check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L1024) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.UpdateValue.html)

### `VariableMapTransform` {#x-variablemaptransform}

*type* · canonical name `variable_map_transform`

```rust
pub enum VariableMapTransform {
    Named(String),
    Expression(ExpressionNode),
}

impl VariableMapTransform { pub fn as_named(&self) -> Option<&str> }

impl VariableMapTransform { pub fn as_expression(&self) -> Option<&ExpressionNode> }

impl VariableMapTransform { pub fn is_expression(&self) -> bool }
```

A `variable_map` coupling `transform` (esm-spec §10.4): either one of the
NAMED transform strings (`"param_to_var"`, `"identity"`,
`"additive"`, `"multiplicative"`, `"conversion_factor"`) or an Expression
evaluated on the source value(s) in the flattened coupled system's scope
(the regridding form).

On the wire an Expression transform is always an operator-node OBJECT: the
degenerate bare-reference and literal Expression spellings are not
admissible (the named string transforms already cover bare replacement,
and the string space is reserved for them), so a JSON string deserializes
to `VariableMapTransform::Named`, an object to
`VariableMapTransform::Expression`, and a bare number is rejected.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/components.rs#L433) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.VariableMapTransform.html)

### `VariablePrecisionRecord` {#x-variableprecisionrecord}

*type* · canonical name `variable_precision_record`

```rust
pub enum VariablePrecisionRecord {
    Declared { element_type: Precision },
    Unspecified { between_groups: Precision },
}
```

Precision of a variable crossing evaluation groups (§11.3.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L246) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/enum.VariablePrecisionRecord.html)

### `VariableType` {#x-variabletype}

*type* · canonical name `variable_type`

```rust
pub enum VariableType {
    Unknown,
    Parameter,
}
```

Type of model variable (esm-spec §6.3). There are **two** declared types
and no third: everything else a solver needs — which unknowns are ODE
states, which parameters are Brownian — is DERIVED by
`crate::classification`, never declared.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/types/model.rs#L1116) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.VariableType.html)

### `ZBlock` {#x-zblock}

*type* · canonical name `z_block`

```rust
pub struct ZBlock {
    pub name: String,
    pub offset: usize,
    pub shape: Vec<usize>,
}
```

One block of the `z` layout.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/strip.rs#L190) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ZBlock.html)
