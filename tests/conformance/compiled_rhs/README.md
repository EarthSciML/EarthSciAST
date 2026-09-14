# Compiled Right-Hand-Side Conformance (`compiled_rhs`)

The gate for the two compiled backends (Julia direct StableHLO emission through
Reactant; Rust XlaBuilder emission through the `xla` crate): a compiled program
must reproduce the **interpreter** right-hand side `f(u, p, t)` at fixed probe
states within a written, per-class tolerance. It is also the cross-binding gate
for the interpreters themselves, so it runs today, before either compiled lane
has landed, and grows into the compiled gate as they do.

Design decisions of record (2026-09-12/13) that this tier implements:

* Agreement is **numerical within tolerance**. Emitted programs never have to
  match, and nothing here inspects them.
* A model a compiled path cannot lower completely is a **hard error** in that
  binding, not a fallback. The tier records such a refusal as a **named
  exclusion** in the report, never as a pass and never as a silent skip.
* Precision-changing fixtures are **excluded** until both emitters lower them,
  and are listed in the manifest with that reason.
* Python has no compiled backend in this plan; it participates with its
  interpreter only.

## Shape

| Comparison | Shape (see `../README.md`) |
|---|---|
| compiled engine vs golden | **reference-comparing** — the golden is the Julia *interpreter*, which lies entirely outside every compiled path |
| any engine vs `analytic_rhs` | **reference-comparing** — an anchor computed independently of every binding (an operator matrix, a closed form) |
| interpreter engines vs golden | **cross-binding-agreeing** for Rust and Python; for Julia's own interpreter it is a regression check against its committed output, which is why every fixture that *can* carry an `analytic_rhs` anchor must |

## Directory layout

```
tests/conformance/compiled_rhs/
├── README.md            # this file — the contract
├── manifest.json        # fixtures, probes, tolerance classes, exclusions
├── fixtures/            # fixtures authored for this tier only (others are referenced by path)
└── golden/<id>.json     # Julia-interpreter RHS at every probe, one file per fixture
```

## Fixtures

Every fixture already lives in the corpus and is referenced by its path relative
to the repository's `tests/` directory. `fixtures/` in the layout above is for
fixtures authored for this tier alone; phase 1 authored none, and phase 2 adds
exactly one — `datetime_log10`, below, which exists because no corpus fixture
exercises the closed calendar and no corpus fixture reachable by this tier
exercises `log10`.

| Fixture | Path (under `tests/`) | Model | Class | State | Probes | Anchored | What it holds |
|---|---|---|---|---|---|---|---|
| `elementwise_gather` | `conformance/elementwise_observed_gather/fixtures/elementwise_gather.esm` | `Column` | `transcendental` | 5 | 4 | 4 | `f = 1 + cos(pi*zc)` written elementwise, read only through an `index` gather inside a `faq`; `colsum[i] = Σ_{j≤i} f[j]`, `total = Σ_j f[j]`. State-FREE RHS |
| `explicit_gather` | `conformance/elementwise_observed_gather/fixtures/explicit_gather.esm` | `Column` | `transcendental` | 5 | 4 | 4 | the identical field written as an explicit `faq(k from lev; 1 + cos(pi*index(zc,k)))` — the controlled twin; same anchor, so a divergence between the two is the index push-down and cannot be the physics |
| `diffusion_1d_dirichlet_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_dirichlet_n4.esm` | `Diff1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D heat, ghost = 0 |
| `diffusion_1d_neumann_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_neumann_n4.esm` | `Diff1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D heat, constant-flux ghost (inhomogeneous `b`) |
| `diffusion_1d_zero_gradient_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_zero_gradient_n4.esm` | `Diff1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D heat, mirror ghost |
| `diffusion_1d_robin_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_robin_n4.esm` | `Diff1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D heat, ghost = α·u + β |
| `diffusion_1d_periodic_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_periodic_n4.esm` | `Diff1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D heat, wrap ghost |
| `diffusion_1d_periodic_n8` | `conformance/pde_simulation/fixtures/diffusion_1d_periodic_n8.esm` | `Diff1D` | `reduction` | 8 | 6 | 6 | the same operator at a second grid size (shape generality) |
| `diffusion_2d_dirichlet_n3` | `conformance/pde_simulation/fixtures/diffusion_2d_dirichlet_n3.esm` | `Diff2D` | `reduction` | 9 | 6 | 6 | pre-discretized 2-D heat, neighbour-coupled 5-point stencil |
| `advection_1d_periodic_n4` | `conformance/pde_simulation/fixtures/advection_1d_periodic_n4.esm` | `Advect1D` | `reduction` | 4 | 6 | 6 | pre-discretized 1-D upwind advection |
| `events_cross_system_meteorology` | `valid/events_cross_system.esm` | `MeteorologicalSystem` | `transcendental` | 3 | 4 | 4 | diurnal relaxation — the one fixture whose RHS genuinely depends on `t`, so the probe's `t` is load-bearing |
| `expr_graphs_variable_deps` | `valid/expr_graphs_variable_deps.esm` | `VariableDependencyModel` | `transcendental` | 3 | 4 | 4 | Arrhenius + power law + `sqrt`/`log` kinetics; the densest transcendental RHS in the tier, and the only fixture with a restricted domain |
| `pde_inline_observed_indexed_lhs` | `conformance/pde_inline_observed_indexed_lhs/fixtures/observed_indexed_lhs.esm` | `M` | `algebraic` | 8 | 4 | 4 | state-free and state-dependent array observeds, both through an INDEXED (`faq`-shelled) LHS |
| `pde_inline_observed_rank2` | `conformance/pde_inline_observed_rank2/fixtures/observed_rank2.esm` | `M` | `algebraic` | 6 | 4 | 4 | rank-2 array observed, `D(u[i,j]) = 1.5*base[i,j]` |
| `pde_inline_observed_param_rank2` | `conformance/pde_inline_observed_param_rank2/fixtures/observed_param_rank2.esm` | `M` | `algebraic` | 6 | 4 | 4 | the same rank-2 observed scaled by a model PARAMETER instead of a literal |
| `pde_inline_observed_state_dependent` | `conformance/pde_inline_observed_state_dependent/fixtures/observed_state_dependent.esm` | `M` | `algebraic` | 8 | 4 | 4 | a state-dependent array observed beside its state-free twin, so the build-materialized and evaluate-at-state paths are both live |
| `mount_rename_atm_column` | `valid/mount_rename_atm_column.esm` | `AtmColumn` | `algebraic` | 59 | 4 | 4 | a 59-layer column — the tier's widest state, and its shape-generality probe |
| `mount_rename_soil_column` | `valid/mount_rename_soil_column.esm` | `SoilColumn` | `algebraic` | 4 | 4 | 4 | the 4-layer twin of the same column family |
| `units_registry_grammar` | `valid/units_registry_grammar.esm` | `UnitsRegistryGrammar` | `algebraic` | 1 | 4 | 4 | one first-order decay under a model whose observed set is a units-parsing discriminator |
| `datetime_log10` | `conformance/compiled_rhs/fixtures/datetime_log10.esm` | `DatetimeLog10` | `transcendental` | 11 | 8 | 8 | the nine `datetime.*` closed calendar functions, one equation each, plus `hour(t + tz_offset) + longitude/15` and `k_log * log10(lg)` — the tier's only fixture authored for it, and the only one with hand-chosen probe times |

All 20 fixtures carry an `analytic_rhs` anchor on **every** probe, so the
self-test gates the whole tier against references computed outside every binding.

### `datetime_log10`, and why its probe times are not the generator's

Its RHS is a CALENDAR, and the generator's 0.37 / 1.0 / 2.5 all land inside the
first three seconds of 1970-01-01: every one of them would read the same date,
the same hour and the same leap-year answer, so a binding that decomposed `t`
wrongly everywhere except there would pass. The eight times it probes instead
are the places a calendar goes wrong — the boundaries, in both directions from
the epoch:

| Probe | `t` | What it can catch |
|---|---:|---|
| `default` | `0.0` | the epoch itself, which is a day AND a year boundary at once |
| `pre_epoch_second` | `-1.0` | a NEGATIVE time: floored division, so 1969-12-31T23:59:59 and not "day 0, −1000 ms" |
| `pre_epoch_fraction` | `-0.5` | a negative time with a sub-second part — truncation toward zero, on the side of the epoch where truncation and flooring disagree |
| `pre_epoch_leap_1968` | `-58039200.0` | a leap day BEFORE the epoch (1968-02-29), where a year-of-era decomposition that assumed a non-negative day number breaks |
| `leap_day_2020` | `1582979696.0` | 2020-02-29T12:34:56 — a leap day with every field non-trivial |
| `year_end_2023` | `1704067199.5` | a year boundary half a second short of it, so a binding that decomposes SECONDS rather than whole milliseconds rolls the year over early |
| `day_boundary_below` | `86399.75` | `t` just below a day boundary |
| `day_boundary` | `86400.0` | `t` exactly on one |

`datetime.julian_day` is the one continuous member of the family (`d/dt =
1/86400` almost everywhere) and is the only element of this fixture that cannot
be exact in every binding; the eight integer fields are, and `transcendental`'s
1e-12 is slack on them. The class is carried for `julian_day` — one rounded
divide onto a ~2.4e6 day number — and for `log10`, which no XLA-class backend
has an opcode for and every one of them synthesizes as `log(x)/ln(10)`.

### Excluded, by name and reason

| Path (under `tests/`) | Reason |
|---|---|
| `fixtures/recurrence/06_recurrence_float32_state.esm` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13) |
| `valid/minimal_chemistry.esm` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13) |
| `valid/model_only.esm` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13) |
| `future/robustness/denormal_number_handling.esm` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13) |
| `future/robustness/schema_evolution_stress.esm` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13) |
| `conformance/flatten/cases.json` | precision-changing; excluded until both compiled emitters lower it (ruling 2026-09-13). Not a standalone .esm — a flatten case file whose embedded document declares element_type Float32. |
| `conformance/classification_indexed_lhs/fixtures/observed_indexed_lhs.esm` | the reference tree-walk evaluator refuses to build it: E_TREEWALK_UNSUPPORTED_SHAPE on the bare-index LHS `index(wb, i) ~ 5`, whose index `i` is bound by no range. There is no reference RHS to probe, so the fixture cannot enter a tier whose golden IS the reference RHS. Include it once the evaluator supports the bare-index LHS spelling of esm-spec §6.3.1. |

The precision block is the ruling of 2026-09-13 (CONFORMANCE_SPEC §5.38.4). The
last entry is a fixture from the phase-1 candidate list that had to be dropped:
the reference tree-walk evaluator cannot build it, so there is no reference RHS
to be the golden.

Two notes on what is *not* in that ledger, because neither is a fixture this
tier rejected:

* all four `conformance/pde_inline_observed_*` categories are carried above. The
  sibling `pde_inline_array_overrides`, `pde_inline_dead_observed`,
  `pde_inline_ic_param_override` and `pde_inline_reference_dimension_names`
  categories were not part of the phase-1 list and are unexamined here; phase 2
  can add them.
* no fixture in this tier needs external data or a forcing provider to evaluate,
  and none was dropped for needing one. A fixture that did would belong to the
  `pde_simulation_pipeline` tier's provider-injected shape rather than to this
  one, which builds every fixture standalone.

## Probe generation

`scripts/gen_compiled_rhs_manifest.py` writes `manifest.json`. It is
deterministic: re-running it reproduces the file byte-for-byte.

```bash
python3 scripts/gen_compiled_rhs_manifest.py
```

**`state_order`** is never written by hand. The generator shells out to Julia
once, builds every fixture through `build_evaluator`, and reads the flat layout
back off the evaluator's own variable map (the `Model.` namespace stripped). A
hand-kept order would drift silently and every binding would then probe the wrong
slots. The adapters check the manifest's order against that same map by name and
fail loudly on a mismatch rather than evaluating at the wrong index.

**The `default` probe** of each fixture is that fixture's own initial state — the
`default`/`ic` values the document declares — at `t = 0`. The eight
pre-discretized PDE fixtures instead keep their three committed probes
(`const1`, `ramp`, `ic`) verbatim, anchors included, copied from
`tests/conformance/pde_simulation/manifest.json`; re-deriving them here would
only be a second chance to get the operator wrong.

**The three perturbed probes** (`perturbed_1`, `perturbed_2`, `perturbed_3`) come
from one `random.Random(20260913)` stream, drawn in manifest order — fixture
order, then probe order, then element order (the evaluator's order) — so the
whole table regenerates identically.

A fixture entry may carry `probe_times`, which replaces those three `t` values
(and their probe ids) with its own — `datetime_log10` is the only one that does,
and the table above says why. It changes the TIMES only: the states still come
off the same seeded stream, drawn in the same order, so the manifest regenerates
byte-for-byte either way and adding such a fixture at the END of the generator's
table leaves every earlier fixture's probes untouched.

| Knob | Value |
|---|---|
| seed | `20260913` |
| `t` at `perturbed_1` / `_2` / `_3` | `0.37`, `1.0`, `2.5` |
| default rule | `v = base + max(1, |base|) * r`, `r` uniform on `[-1, 1]` |
| positive-domain rule | `v = (base or 1) * exp(r/2)` — strictly positive |
| rounding | 12 decimals, so the literal parses back to exactly the generated float |

The additive rule is scale-aware, so a 273 K column layer and a 0.5 mixing ratio
are both perturbed meaningfully. The multiplicative rule is used for the one
fixture whose RHS leaves the reals on a non-positive state:
`expr_graphs_variable_deps` takes `x^0.5` and `sqrt(x*y + (kappa*T)^2)`. The
`t` values are deliberately off any solver's grid, and `2.5` is far enough out
that the one genuinely time-dependent fixture
(`events_cross_system_meteorology`) has moved a long way.

**Domain safety is enforced, not assumed.** The generator recomputes every
anchor from the fixture's mathematics and refuses to write a probe whose anchor
is not finite, naming the element. A probe that produced a non-finite value would
therefore never reach the manifest; if a future fixture needs one, change that
fixture's perturbation rule rather than loosening the check.

## Readings taken where this contract was silent

Recorded here rather than in a commit message, because the next binding author
needs them:

1. **Where a golden lives.** The manifest schema carries no per-fixture `golden`
   field (the PDE tier's does), so the runner derives it: `golden/<id>.json`
   beside the manifest. An id and its golden cannot drift apart.
2. **What `path` is relative to.** The schema says "relative to the repository's
   `tests/` directory", and the manifest sits at
   `tests/conformance/compiled_rhs/manifest.json`, so an adapter resolves the
   corpus root two levels above the manifest's own directory rather than taking
   it from the environment. That keeps an adapter runnable from any working
   directory, which the runner's tempfile handoff assumes.
3. **Which build entry point the `model` field names.** The reference adapter
   uses `build_evaluator(load_path(path); model_name=...)` — per-model selection,
   the same shape the PDE-simulation adapter uses, with the document's index-set
   registry threaded in. It deliberately does NOT flatten the whole document
   (`_prepare_run_doc`), which would evaluate every coupled model at once and
   leave the `model` field meaning nothing. A fixture whose RHS only exists after
   coupling belongs to the `pde_simulation_pipeline` tier's shape, not this one.
4. **`state_order` sequence.** It is the reference evaluator's flat layout. The
   PDE-simulation tier's `state_order` for `diffusion_2d_dirichlet_n3` lists the
   elements row-major (`u[1,1], u[1,2], …`) while the evaluator lays them out
   column-major (`u[1,1], u[2,1], …`). That is inert there — that tier's probes,
   goldens and anchors are all keyed by element name and never by position — but
   it means the two tiers' `state_order` arrays for that fixture are permutations
   of each other. The generator checks the element SET, not the sequence.
5. **How `--engine` reaches the adapter.** The runner appends
   `--engine <interpreter|compiled>` to the adapter argv, after
   `--manifest`/`--output`. One adapter binary serves both engines.
6. **An `unavailable` payload has no `fixtures` map.** The shared harness
   classifies a payload without one as malformed and discards it, which would
   erase exactly the reason this contract requires the report to print. The
   runner re-does that classification locally so the reason survives.
7. **The eight pre-discretized PDE fixtures are `reduction`, not `algebraic`.**
   A method-of-lines stencil is a fold, and these eight are the tier's only
   fixtures with exact-cancellation rows: the `ramp` probe on
   `diffusion_1d_periodic_n8` has an interior row whose exact value is 0, which
   the AST stencil reaches as exactly `0.0` and the anchor's matrix-vector
   product reaches as `-2.842e-14`. That is a summation-order difference of one
   ulp of the row's operands and nothing more, but under `algebraic` (atol
   1e-300) a relative bound on an exact zero is an impossible bound, and that one
   cell would fail for every binding forever, for a defect none of them has. The
   `reduction` class's SCALED floor is what the case was written for — here
   `1e-14 * 200 = 2e-12`. The genuinely elementwise fixtures (`pde_inline_*`, the
   two mounted columns, `units_registry_grammar`) keep `algebraic` and its 1e-13.
8. **A compiled backend's `divide` is not the interpreter's divide, and
   `datetime_log10` is where that first mattered.** XLA's algebraic simplifier
   rewrites `x / c` for a floating-point constant `c` into `x * fl(1/c)` — the
   optimized module for `floor(x / 3600000.0)` is literally
   `multiply(x, 2.7777777777777776e-7)` then `floor`. That is a second rounding,
   and for `c = 3600000` (milliseconds per hour) and `c = 146097` (days per
   400-year era) the reciprocal is low, so `x` at an exact multiple comes back
   as `k - 1e-16` and `floor` reads it one short. Both of those constants are
   divisors in the closed calendar, so a binding that writes the decomposition
   as `floor(a/b)` in floating point gets the RIGHT answer at most times of day
   and the WRONG one exactly on an hour boundary — which is why this fixture's
   `default`, `day_boundary` and `pre_epoch_leap_1968` probes all sit on one.
   Julia's emitter recovers the floor from the remainder (`r = a - q*b`, two
   selects, exact for exact-integer operands) rather than trusting the quotient;
   a binding doing the decomposition in INTEGER arithmetic is immune and needs
   nothing. This is not a tolerance question — an hour that is one out is an
   error of 1.0 — so no class covers it and none should.

   Rust's tape lowering hit the SAME defect independently and now recovers its
   quotients the same way. Its divisors are different, because it decomposes
   whole seconds rather than milliseconds: `x * fl(1/86400)`, `fl(1/3600)` and
   `fl(1/60)` all round back to the exact integer, so the hour boundary is
   safe there, and `146097` is the one divisor that is not. That constant is
   the era, so the dates it moves are March 1 of 0400, 0800 and 1600 — none of
   which is a probe in this manifest, and none of which any fixture here
   should be contorted into reaching. **The lesson is that this tier's probes
   cannot be the only guard.** Which exact multiples round low is a property of
   each binding's own constants, so the check belongs in each binding's unit
   tests, at ITS divisors' boundaries, with the tier as the cross-binding
   backstop it already is.

9. **`float32` carries no fixture in phase 1**, because the precision fixtures
   that would use it are excluded by §5.38.4. `--self-test` therefore gates every
   class's floor arithmetic directly, on a synthetic probe, rather than leaving
   the one piece of arithmetic this file spells out unchecked until a fixture
   happens to need it: an exact zero beside a large entry must pass inside the
   scaled floor and fail outside it.

## Running

```bash
# Always-on regression guard: the committed Julia-interpreter golden vs every
# independent analytic anchor, plus the negative and injected-refusal controls.
# No live binding needed.
python3 scripts/run-compiled-rhs-conformance.py --self-test

# The three interpreters (all bindings_required for that engine):
./scripts/test-conformance.sh

# Regenerate the goldens (e.g. after changing a fixture or a probe):
EARTHSCI_COMPILED_RHS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/compiled_rhs_adapter.jl" \
  python3 scripts/run-compiled-rhs-conformance.py --write-golden --bindings julia
```

## Manifest schema

```json
{
  "category": "compiled_rhs",
  "version": "1.0",
  "reference_binding": "julia",
  "engines": {
    "interpreter": { "bindings_required": ["julia", "rust", "python"] },
    "compiled":    { "bindings_required": [], "bindings_optional": ["julia", "rust"] }
  },
  "tolerance_classes": {
    "algebraic":      { "rtol": 1e-13, "atol": 1e-300 },
    "transcendental": { "rtol": 1e-12, "atol": 1e-300 },
    "reduction":      { "rtol": 1e-11, "atol_scaled": 1e-14 },
    "float32":        { "rtol": 1e-5,  "atol": 1e-30 }
  },
  "excluded": [
    { "path": "valid/<file>.esm", "reason": "<why, and what must change to include it>" }
  ],
  "fixtures": [
    {
      "id": "<unique id>",
      "path": "<path relative to the repository's tests/ directory>",
      "model": "<model name to evaluate>",
      "tolerance_class": "algebraic | transcendental | reduction | float32",
      "compiled_required": [],
      "state_order": ["u[1]", "u[2]", "s"],
      "parameters": {},
      "rhs_probes": [
        {
          "id": "<probe id>",
          "t": 0.0,
          "state": { "u[1]": 0.0, "u[2]": 0.0, "s": 0.0 },
          "analytic_rhs": { "u[1]": 2.0, "u[2]": 2.0, "s": 4.0 }
        }
      ]
    }
  ]
}
```

Field rules:

* `state_order` is the flat state layout of the reference binding's evaluator:
  bare column-major element names (`u[1]`, `u[i,j]`, scalar `s`), the model
  namespace stripped, exactly as the PDE-simulation tier spells them.
* Every probe `state` names every element of `state_order`. Probe values are
  written literally in the manifest so that every binding evaluates the same
  inputs; how they were generated (fixture defaults, then seeded deterministic
  perturbations) is documented in this README when the generator lands, and the
  generator script is committed.
* `parameters` is a map of parameter overrides; empty means the fixture's own
  default values. Phase 1 uses empty maps only.
* `analytic_rhs` is optional per probe and is an anchor computed **without** any
  binding. Omit it rather than copy a binding's output into it.
* `compiled_required` lists the bindings whose compiled engine must compile this
  fixture. Since phase 2 (2026-09-13) every fixture lists both `julia` and
  `rust`: both compiled engines compile the whole tier, so a refusal from
  either is a failure. A refusal from a
  binding not listed is reported as an exclusion; a refusal from a listed binding
  fails the gate.
* Tolerance semantics: a value passes when `|got - want| <= atol + rtol * |want|`.
  For the `reduction` class `atol = atol_scaled * max_i |want_i|` over the probe,
  so exact zeros in a reduction do not force an impossible bound.

## Adapter contract

Each binding ships a thin adapter discovered by the runner via
`$EARTHSCI_COMPILED_RHS_ADAPTER_<BINDING>` (or on PATH as
`earthsci-compiled-rhs-adapter-<binding>`):

```
adapter --manifest <manifest.json> --output <out.json> [--engine interpreter|compiled]
```

`--engine` defaults to `interpreter`. The adapter loads every fixture, evaluates
`f(u, p, t)` at every probe with the requested engine, and writes:

```json
{
  "binding": "<julia|rust|python>",
  "engine": "<interpreter|compiled>",
  "fixtures": {
    "<id>": { "rhs": { "<probe_id>": { "u[1]": <f64>, "u[2]": <f64>, "s": <f64> } } }
  }
}
```

The `rhs` map for a probe carries **exactly** the fixture's `state_order`
elements, in that order, with the model namespace stripped. A binding whose shape
inference reaches an element the manifest does not name (Python's reaches a fifth
flat `u[5]` on `diffusion_1d_dirichlet_n4`) drops it rather than emitting it: an
extra element in a golden becomes a requirement every other binding has to
reproduce. Values are compared **numerically**, never as strings or reprs — `-0.0`
and `0.0` are the same value, and some bindings emit the signed zero (Python does,
on `advection_1d_periodic_n4`'s `const1`).

Fixture `path` is relative to the repository's `tests/` directory. Every adapter
and the runner resolve it the same way: walk up from the manifest's ABSOLUTE path
to the **nearest ancestor directory named `tests`**, falling back to the
manifest's own directory when there is none. A fixed number of parent hops would
break the moment a manifest moved a level. (An adapter may additionally accept a
path spelled relative to the manifest directory; the runner's own check uses the
rule above.)

Goldens are **not bit-comparable across bindings**, and nothing here asks them to
be. Rust reaches `diffusion_1d_dirichlet_n4`'s `ic` probe about 2e-16 relative
from the anchor and not left-right symmetric in the last bit; Python differs from
the Julia golden by up to about 3e-16 relative on the same fixture. Both are far
inside the `algebraic` class. The golden is a numeric reference, not a wire
format.

**A non-zero adapter exit with a valid report is allowed**, and means at least
one fixture errored. An adapter that cannot evaluate a fixture writes the whole
report — per-fixture `error` entries included — and may then exit non-zero (the
Rust adapter does). The runner reads and gates the report regardless of the exit
code: aborting on it would throw away the entries that say WHICH fixture broke
and why, and would collapse "one fixture errored" into the same indistinguishable
"the adapter fell over" the harness reports for a crash. The per-fixture entries
decide the verdict. An adapter that exits non-zero **without** writing a parsable
report is still classified as a broken adapter.

Three other outcomes exist, and all three must be explicit:

* **Refused** (compiled engine only). The engine cannot lower the model
  completely. The fixture entry is
  `{ "status": "refused", "rule": "<rule or node name>", "reason": "<text>" }`
  and the adapter continues with the next fixture. This is the hard-error
  ruling made visible.
* **Errored**. The adapter could not evaluate the fixture at all — the load
  threw, the build threw, the evaluation threw. The fixture entry is
  `{ "error": "<ExcType>: <message>" }`, the convention the existing per-binding
  adapters share, and the adapter continues with the next fixture. This is a
  FAILURE for any binding and any engine: unlike a refusal it says nothing about
  what an engine can lower, so `compiled_required` does not excuse it.
* **Unavailable**. The engine does not exist in this binding, or its runtime is
  not configured on this machine (no XLA extension, no GPU where one is
  required). The whole output is
  `{ "binding": "<name>", "engine": "<engine>", "status": "unavailable", "reason": "<text>" }`.
  The runner prints the reason and skips, and only for a binding listed in
  `bindings_optional` for that engine; for a required binding it fails.

Hooks per binding (interpreter engine):

| Binding | RHS hook | Adapter |
|---|---|---|
| Julia (reference) | `build_evaluator` → `f!(du, u, p, t)` | `pkg/EarthSciAST.jl/scripts/compiled_rhs_adapter.jl` |
| Rust | `ArrayCompiled::debug_eval_rhs` (or the tape executor) | `pkg/earthsci-ast-rs/src/bin/earthsci-compiled-rhs-adapter-rust.rs`, feature `conformance-adapters` |
| Python | `earthsci_ast.evaluate_rhs` | `pkg/earthsci-ast-py/src/earthsci_ast/cli/compiled_rhs_adapter.py` |

Hooks per binding (compiled engine):

| Binding | RHS hook | Adapter |
|---|---|---|
| Julia | `EarthSciASTReactantExt.direct_rhs` → `Reactant.@compile` (direct StableHLO emission, `pkg/EarthSciAST.jl/ext/reactant_direct/`) | the same `compiled_rhs_adapter.jl`, under its own `scripts/compiled_rhs_reactant_env`; `EARTHSCI_JULIA_XLA_DEVICE=cpu|gpu` (default `cpu`) picks the XLA client |
| Rust | the XlaBuilder emitter over the tape (`pkg/earthsci-ast-rs/src/simulate_array/tape/xla_emit.rs`, runtime `src/xla_runtime.rs`) | the same `earthsci-compiled-rhs-adapter-rust`, built with `--features conformance-adapters,xla` and `XLA_EXTENSION_DIR` set. `EARTHSCI_XLA_PLATFORM=gpu` runs the same adapter on a CUDA device instead of the CPU — the emitter is platform-independent, so the tier's outcomes and tolerance classes are expected to be identical; `EARTHSCI_XLA_GPU_MEMORY_FRACTION` (default 0.75) and `EARTHSCI_XLA_GPU_PREALLOCATE=1` tune the device allocator. A GPU run additionally needs the `cuda12` extension and the CUDA libraries it hard-links: `pkg/earthsci-ast-rs/README.md` and `scripts/setup-xla-gpu-libs.sh`. |
| Python | — | no compiled backend in this plan |

An adapter whose compiled engine has not landed, or whose runtime is not
configured on this machine, answers `--engine compiled` with `unavailable` and a
reason that says so. Julia's answers `unavailable` in exactly two cases —
Reactant cannot be loaded at all, or `EARTHSCI_JULIA_XLA_DEVICE` named a client
that cannot be created here (asking for `gpu` on a machine with none). A model
its emitter cannot lower is a `refused` fixture, never an unavailable engine,
because the two readings are different facts; and a GPU that is not there is
never answered by falling back to the CPU, because that would report a CPU run
under a GPU label.

**Which device a Julia compiled run used is not in the report.** A fixture entry
is the probe values, a `refused`, or an `error`, and this contract admits no
extra keys — a key one binding invents becomes a key every other binding has to
reproduce. The adapter therefore announces the platform once on **stderr**,

```
compiled_rhs_adapter: julia engine=compiled device=gpu platform=cuda addressable_devices=1
```

which the runner captures with the rest of the adapter's stderr. Nothing parses
that line. The tolerance classes are the same on either device: they are the
contract, not a property of the hardware.

## Runner

`scripts/run-compiled-rhs-conformance.py`, mirroring
`run-pde-simulation-conformance.py`:

```
--self-test                      # golden vs analytic anchors + negative controls; no bindings
--write-golden --bindings julia  # (re)mint golden/<id>.json from the reference interpreter
--bindings julia,rust,python --engine interpreter --output <report.json>
--bindings julia,rust --engine compiled --output <report.json>
```

Exit codes: 0 all required bindings within tolerance (or self-test passed);
1 a mismatch, a refusal from a `compiled_required` binding, an `unavailable`
from a required binding, or a self-test failure; 2 manifest or configuration
error. The report lists every refusal and every unavailable engine by name and
reason.

## Tolerance policy

Normative text lives in `CONFORMANCE_SPEC.md` (§5.38). The four classes above
are the ruling of 2026-09-13; a fixture may carry a tighter or looser bound in
the manifest only with a written reason in its entry.
