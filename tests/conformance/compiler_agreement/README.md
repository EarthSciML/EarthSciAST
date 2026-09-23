# Compiler Agreement (`compiler_agreement`)

The gate for `esm_problem`'s **`compiler`** keyword (`API_SPEC.md` §5.8): every
compiler a binding offers must reproduce the **`interpreter` trajectory** of the
same document within a written band, or refuse it by name. Normative text is
`CONFORMANCE_SPEC.md` §5.44; the vocabulary's meaning is
`esm-libraries-spec.md` §2.5.10. This file is the contract the adapters and the
runner are built to.

`compiled_rhs` compares one right-hand side at fixed probe states, across
bindings. This tier compares a whole **run**, across the compilers of ONE
binding as well as across bindings. That is the axis nothing else covers: a
strict `native` default can be wrong in a way no cross-binding comparison sees,
because every binding's `native` could be wrong the same way.

Design decisions of record (2026-09-21) that this tier implements:

* The reference is the Julia **`interpreter`**, which shares no code with the
  compiled or vectorized tiers it gates.
* Agreement is **numerical within tolerance**. Nothing here inspects an emitted
  program, and a byte comparison on one must not be asserted.
* A compiler that cannot run a document **refuses** it, naming the rule and the
  reason. It never falls back. A refusal is a **named exclusion**, never a pass
  and never a silent skip — except from `interpreter`, where it is a failure.
* Fixtures are **referenced by path** from the tiers that already own them.
  Nothing about a document's physics is decided here.

> **Status.** `golden/` holds all six reference trajectories, minted from the
> Julia `interpreter` and committed; each one reproduces the analytic anchor its
> fixture carries. Julia, Rust and Python each answer for both `interpreter`
> and `native` with no refusals on any fixture, and all three are
> `bindings_required` for each; Python is `bindings_required` for `sympy`,
> which refuses the four array fixtures by name and runs the two scalar ones.
> **Julia is `bindings_required` for `mtk`** as of 2026-09-22:
> `esm_problem(…; compiler = :mtk)` builds every one of the six fixtures
> through `ModelingToolkit.System` → `mtkcompile` → `ODEProblem` and lands
> inside each fixture's band, with no refusals — the array fixtures included,
> because their stencils are already `arrayop` over an index set and so carry no
> continuous spatial dimension for that compiler to refuse. Julia's `xla` stays
> `bindings_optional` until its `esm_problem` can build with it, on the same
> one-way ratchet.
>
> Two things about the `mtk` stage that are properties of the compiler rather
> than of this tier. It needs ModelingToolkit **and a nonlinear solver** — an
> implicit equation compiles to a DAE whose consistent initialization is a
> nonlinear solve — which live in an adapter environment of their own
> (`scripts/compiler_agreement_mtk_env`) that the adapter activates, and whose
> packages it loads, for `--compiler mtk` only, at TOP LEVEL: a package loaded
> by `@eval` inside a running function defines its methods in a new world age
> that the running frame cannot call, which made every fixture report "method
> too new to be called from this world context" and read as a broken binding.
> And `mtk` refuses what the fixtures here do not exercise: a document fed by
> loaded data, one with a continuous spatial dimension, a geometry operator, or
> a time derivative of an expression. The stage is gated in
> `.github/workflows/mtk-compiler.yml` rather than in the default conformance
> run — same triggers, so the same frequency.
>
> **Rust crossed the ratchet for `xla` on 2026-09-22**: `esm_problem(…,
> compiler = Xla)` emits the model's tape as an XLA computation and runs the
> compiled right-hand side (and the finite-difference Jacobian differenced out
> of it) on the solve path, and all six fixtures agree with the golden with no
> refusals — so rust is `bindings_required` for `xla`. Read that entry with its
> build condition: `xla` is the member whose availability is a property of the
> BUILD, so "required" means a build that HAS the `xla` Cargo feature and an
> unpacked `xla_extension` must answer. A stage that runs this compiler is
> responsible for providing both, which is why the default run of
> `scripts/test-conformance.sh` registers no `xla` stage and the producer lives
> in the `rust-xla` job of the `XLA Compiled Backends` workflow, which fetches
> the extension first and then runs
> `./scripts/test-conformance.sh --compiler-agreement-only xla`.

## Shape

| Comparison | Shape (see `../README.md`) |
|---|---|
| any compiler vs the golden | **reference-comparing** — the golden is the Julia `interpreter` |
| any compiler vs a carried analytic anchor | **reference-comparing** — an anchor computed outside every binding |
| Julia `interpreter` vs the golden | a regression check against its own committed output, which is why a fixture that can carry an anchor must |
| Rust / Python `interpreter` vs the golden | **cross-binding-agreeing** |

## Directory layout

```
tests/conformance/compiler_agreement/
├── README.md            # this file — the contract
├── manifest.json        # fixtures, trajectories, tolerances, the `required` ledger
├── stub_adapter.py      # a canned stand-in adapter, for the runner's own test only
├── test_runner.py       # drives the runner through all five outcomes and both ledgers
└── golden/<id>.json     # Julia-interpreter trajectory, one file per fixture
```

`stub_adapter.py` is a test fixture for the HARNESS and never evaluates a
document: it answers the adapter CLI from a canned table so `test_runner.py` can
gate the runner in pure Python, with no binding installed and in under a second.
It is not a producer and must never be registered as one. Its goldens are minted
into the test's own temporary directory; nothing but the real Julia adapter ever
writes `golden/`.

There is no `fixtures/` directory and there should not be one: a fixture
authored here would be a document whose only reader is the compiler gate, which
is how a tier starts deciding physics.

## Fixtures

Every fixture already lives in the corpus and is referenced by its path relative
to the repository's `tests/` directory. The initial list is deliberately small —
one fixture from each shape the vocabulary has to survive — and phase 2 grows it
from `pde_simulation`, `pde_simulation_pipeline`, the `pde_inline_*` categories,
`simulate_faq`, `geometry`, `recurrence`, and the `tests/valid` documents that
carry an inline `tests` block.

| Fixture | Path (under `tests/`) | Model | Source tier | Tolerance | What it holds |
|---|---|---|---|---|---|
| `diffusion_1d_dirichlet_n4` | `conformance/pde_simulation/fixtures/diffusion_1d_dirichlet_n4.esm` | `Diff1D` | `pde_simulation` | copied | pre-discretized 1-D heat; a rank-1 stencil with an analytic trajectory |
| `diffusion_2d_dirichlet_n3` | `conformance/pde_simulation/fixtures/diffusion_2d_dirichlet_n3.esm` | `Diff2D` | `pde_simulation` | copied | the rank-2 twin: a neighbour-coupled 5-point stencil |
| `advection_1d_periodic_n4` | `conformance/pde_simulation/fixtures/advection_1d_periodic_n4.esm` | `Advect1D` | `pde_simulation` | copied | upwind advection — a wrap gather rather than a symmetric stencil |
| `faq_discretized_1d_heat` | `fixtures/faq/15_discretized_1d_heat.esm` | `Heat1D` | `simulate_faq` | `reduction` | the same physics written as a `faq` over a `makearray` with ghost regions, so the array machinery rather than a pre-discretized operator is what each compiler has to lower |
| `logistic_growth` | `valid/tests_analyses_comprehensive.esm` | `LogisticGrowth` | inline `tests` | `transcendental` | an **unshaped** ODE with a closed-form solution. `native` must run this on its compiled tiers, not a scalar interpreter: no document-type switch inside a compiler |
| `decay_solver_block` | `valid/solver_block.esm` | `Decay` | inline `tests` | `transcendental` | the smallest unshaped ODE with a closed form, and the one that carries a `solver` block. **Its `solver.stiffness: "high"` is load-bearing, and the stiff method must be a high-order one** (the golden is minted with `Rodas5P`) — see below |

**The `solver` block selects the ALGORITHM, and every binding must honour it.**
`decay_solver_block` declares `solver.stiffness: "high"` (esm-spec §2.2), so an
adapter integrates it with a stiff algorithm. Only the ALGORITHM comes from the
block: the tolerances are the fixture's own `integration` entry, because a
conformance tier has an opinion about the integrator's error and states it per
fixture. The block is the single place that choice is written, which is the
reason this fixture is in the tier.

**A golden's own integration error must sit far below the band it is compared
at** (ruling 2026-09-21), or the tier stops measuring the compiler and starts
measuring the integrator. This fixture is where that bites, and the numbers say
why. Against the closed form `2*exp(-2)`, at this fixture's `integration`
tolerances:

| Method | error vs the closed form | against the 2.8e-11 band vs the golden |
|---|---|---|
| `Rosenbrock23` | 2.5e-8 | ~900x OUTSIDE it |
| `Rodas4` | 2.0e-12 | inside |
| `Rodas5P` | **2.2e-14** | ~1300x inside — **what the golden is minted with** |

A golden carrying 2.5e-8 of its own integration error cannot gate a 2.8e-11
band: every binding MORE accurate than the reference reads as a mismatch, which
is exactly how the Rust adapter's first run against this fixture failed — its
stiff arm landed 6e-11 from the closed form and was marked red for being right.
The fix is the reference's accuracy, not a widened band: widening would stop the
fixture gating the arithmetic at all.

So a binding integrates this document with a **high-order stiff method**. Naming
a non-stiff method ignores the document's own declaration; naming a low-order
stiff one reintroduces the problem above from the other side.

### Excluded, by name and reason

| Path (under `tests/`) | Reason |
|---|---|
| `fixtures/recurrence/06_recurrence_float32_state.esm` | precision-changing; excluded until every compiler lowers a precision change (`CONFORMANCE_SPEC.md` §5.38.4, ruling 2026-09-13) |

The exclusion list is a ledger, not a licence: an excluded fixture never reports
as passing.

## Manifest schema

```json
{
  "category": "compiler_agreement",
  "version": "1.0",
  "reference_binding": "julia",
  "reference_compiler": "interpreter",
  "compilers": {
    "<value>": { "bindings_required": [...], "bindings_optional": [...], "note": "…" }
  },
  "scope_excluded": { "typescript": "…", "go": "…" },
  "tolerance_classes": { "algebraic": {...}, "transcendental": {...},
                         "reduction": {...}, "float32": {...} },
  "excluded": [ { "path": "…", "reason": "…" } ],
  "fixtures": [
    {
      "id": "<unique id>",
      "path": "<path relative to the repository's tests/ directory>",
      "model": "<model name to build>",
      "tags": ["…"],
      "source_tier": "pde_simulation | simulate_faq | inline_tests | …",
      "trajectory": { "from": "manifest | inline_tests", "…": "…" },
      "integration": { "reltol": 1e-10, "abstol": 1e-12 },
      "tolerance": { "source": "pde_simulation | derived",
                     "integration_factor": 100, "…": "…" },
      "anchor": { "source": "pde_simulation | inline_tests | none" },
      "required": { "julia": [], "rust": [], "python": [] }
    }
  ]
}
```

Field rules:

* **`path`** is relative to the repository's `tests/` directory. An adapter
  resolves it by walking up from the manifest's ABSOLUTE path to the nearest
  ancestor directory named `tests` — the same rule `compiled_rhs` uses, and for
  the same reason: a fixed number of parent hops breaks the moment a manifest
  moves a level.
* **`trajectory.from`** says where the run comes from.
  * `"manifest"` — the entry carries `initial_conditions` (every state element,
    written literally), `parameter_overrides`, `tspan` as `[t0, t1]`, `saveat`
    as the save times, and `observed` as the observed field names to report
    beside the state rows.
  * `"inline_tests"` — the entry carries `test_id`, and the run is that inline
    test's own `initial_conditions`, `parameter_overrides` and `time_span`. The
    save times are the test's assertion times. Nothing is restated in the
    manifest, so the document stays the single source of truth for its own run.
* **`integration`** is what the adapter passes to `solve`. It is written per
  fixture and never left to the library default: a default is what a document
  gets when nobody has an opinion, and a conformance tier has one
  (`API_SPEC.md` §5.8).
* **`required`** maps a binding to the compilers that MUST run this fixture. It
  is empty for every fixture today. Each name added is a one-way ratchet, the
  same shape `compiled_rhs`'s `compiled_required` has.

**The two ledgers mean different things and must never be merged.** The
top-level `compilers.<value>.bindings_required` / `bindings_optional` lists
govern **availability**: whether a binding must be able to ANSWER for that
compiler at all. A fixture's `required` map governs **refusals**: whether that
compiler must be able to run THIS document. A compiler can be required to exist
and still be allowed to refuse a particular fixture, which is the normal state
of a coverage backlog; the reverse — required on a fixture but not required to
exist — is a manifest error the runner reports.
* **`anchor`** names where the independent reference comes from, or `none`. A
  fixture that CAN carry one MUST, because without it the Julia leg is only a
  regression check against its own output.

### Tolerance — the exact rule

A value passes when `|got − want| ≤ atol + rtol · |want|`, and the fixture's
`tolerance` block fixes `rtol` and `atol` one of two ways.

**`"source": "pde_simulation"`** — the fixture is one that tier also carries,
and its trajectory-versus-golden bounds are COPIED verbatim into `rtol` /
`atol`. They are written per fixture here even though that tier carries them
tier-wide, so a later change to either tier cannot silently move the other's
gate.

**`"source": "derived"`** — the fixture declares a `class` from the four above,
and the band is that class widened by the integration tolerance times the
**integration safety factor** `F` (`tolerance.integration_factor`, default
`100`):

```
rtol = rtol_class + F · reltol_integration
atol = atol_class + F · abstol_integration
```

For the `reduction` class the class floor is scaled rather than fixed, exactly
as `CONFORMANCE_SPEC.md` §5.38.2 defines it:

```
atol = atol_scaled_class · maxᵢ|wantᵢ|  +  F · abstol_integration
```

with the maximum taken over the saved row **of the reference**, so it is the
same number for every binding. Carrying the integration tolerance at all is the
difference from `compiled_rhs`: a trajectory carries the integrator's own error
on top of the arithmetic's, and a band that ignored it would fail every binding
for a defect none of them has.

**Why the factor, and why it does not loosen the gate.** A solver's `reltol` /
`abstol` bound its **local** error per step. What is compared here is the value
at a save time, which carries the accumulated **global** error — larger by a
factor that depends on the method, the step count and the problem, and which no
integrator undertakes to bound. A band equal to the local tolerance therefore
demands of every binding something its integrator never promised, and fails it
for the difference between two CORRECT integrators. That is not this tier's
question: it asks whether compilers agree, not whether BDF and `Rodas5P` do.
This was not hypothetical — under the unfactored band Rust's
`decay_solver_block` sat 21x outside it and Python's `decay_solver_block` and
`logistic_growth` likewise, every one of them an integrator difference.

The factor applies to the **integration half only**. The class half — the
arithmetic, which is what the tier is actually gating — is never multiplied, so
the gate on the thing under test is unchanged. And `100 × 1e-10` is still some
six orders of magnitude below anything a compiler-level defect produces, so the
band remains far tighter than the failures it exists to catch.

A fixture may state its own `integration_factor`; the runner requires it to be
a number `≥ 1`, since a factor below one would tighten the band back below the
integrator's own local tolerance. **A copied `pde_simulation` band gets no
factor** — that tier measured its bounds as trajectory bounds already — and
**anchors get no factor either** (below).

An **anchor** is gated separately, at the tolerance its own source declares —
`pde_simulation`'s `traj_analytic_*` for a fixture from that tier, the inline
test's declared `tolerance` for one from a `tests` block — and **the integration
safety factor does not apply to it**. An anchor's band is the fixture's own
statement about how close to the physics it must land, already written with the
integrator in mind; multiplying it would weaken a claim this tier did not make
and does not own. An anchor is a statement about the physics and a golden is a
statement about the arithmetic; holding them to one band would mean loosening
the arithmetic one.

A fixture MAY carry a tighter or looser bound than these rules give, with a
written reason in its entry, and only with one. The runner reads that override as
an explicit `rtol` AND `atol` on a `"source": "derived"` block plus a non-empty
`reason` string in the same block; an override missing either number, or missing
the reason, is a manifest error (exit 2) rather than a quietly widened gate.

A `derived` block MAY also restate the figures it derives from — `rtol_class`,
`atol_class`, `atol_scaled_class`, `reltol_integration`, `abstol_integration` —
for legibility, and the entries here do. (`integration_factor` is not a restated
figure: it is stated here and nowhere else, so nothing checks it against an
authority.) Each restated figure is checked against
its authority (`tolerance_classes` and the fixture's `integration` block) and a
disagreement is a manifest error. Writing a number twice is only worth doing if
the two copies are made to agree.

## Golden format

`golden/<id>.json`, derived from the id — the manifest carries no per-fixture
`golden` field, so an id and its golden cannot drift apart.

```json
{
  "id": "<fixture id>",
  "binding": "julia",
  "compiler": "interpreter",
  "state_order": ["u[1]", "u[2]", "…"],
  "saveat": [0.025, 0.05],
  "state": {
    "0.025": { "u[1]": 0.0, "u[2]": 0.0 },
    "0.05":  { "u[1]": 0.0, "u[2]": 0.0 }
  },
  "observed": {
    "<name>": { "0.025": 0.0, "0.05": 0.0 }
  }
}
```

Keys are bare column-major element names with the model namespace stripped, the
spelling `compiled_rhs` and `pde_simulation` already use. Save-time keys are the
manifest's `saveat` values rendered as the adapter's own float repr; the runner
matches them by numeric value, not by string. Goldens are **not** bit-comparable
across bindings and nothing asks them to be — the golden is a numeric reference,
not a wire format.

Three fields the contract did not pin, pinned by the runner that writes them:

* **`saveat`** is the fixture's save times, from whichever source defines the run
  — the manifest's `trajectory.saveat` for a `"from": "manifest"` entry, and the
  ASSERTION TIMES of the named inline test for a `"from": "inline_tests"` one.
  The document stays the single source of truth for its own run, so the runner
  reads the inline test rather than have the manifest restate it.
* **`state_order`** is what the adapter declared in its output, else the
  manifest's `initial_conditions` keys in document order, else the row's element
  names SORTED. Sorted last so the fallback is binding-independent rather than
  whichever order one adapter's dictionary happened to iterate in. Every saved
  row carries exactly these names and no others: a binding whose shape inference
  invents an extra flat element must not put it in the golden, where it would
  become a requirement every other binding had to reproduce.
* **`observed`** carries one series per name in the fixture's
  `trajectory.observed`, and is `{}` when the fixture names none.

The runner's `--self-test` checks every committed golden against this shape —
the ids, the reference binding and compiler, a non-empty duplicate-free
`state_order`, a row at every declared save time, exactly the `state_order`
names in each row, every value finite — before it believes a number in it.

## Adapter contract

Each binding ships one adapter, discovered by the runner through
`$EARTHSCI_COMPILER_AGREEMENT_ADAPTER_<BINDING>` (or on PATH as
`earthsci-compiler-agreement-adapter-<binding>`):

```
adapter --manifest <manifest.json> --output <out.json> --compiler <value>
```

`--compiler` is REQUIRED and takes one member of the vocabulary. One adapter
binary serves every compiler its binding offers; the adapter passes the value
straight to `esm_problem` and does not interpret it. An adapter that inspected
the value and chose a build itself would be reimplementing the thing under test.

The paths, so every binding's adapter lands in the place the runner already
looks for it:

| Binding | Adapter |
|---|---|
| Julia (reference) | `pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl` — on disk; bootstraps `scripts/compiler_agreement_env`, or `scripts/compiler_agreement_mtk_env` for `--compiler mtk` |
| Rust | `pkg/earthsci-ast-rs/src/bin/earthsci-compiler-agreement-adapter-rust.rs`, feature `conformance-adapters` |
| Python | `pkg/earthsci-ast-py/src/earthsci_ast/cli/compiler_agreement_adapter.py` |

The adapter writes:

```json
{
  "binding": "<julia|rust|python>",
  "compiler": "<value>",
  "fixtures": {
    "<id>": {
      "state_order": ["u[1]", "u[2]", "…"],
      "state": { "<save time>": { "<element>": <f64> } },
      "observed": { "<name>": { "<save time>": <f64> } }
    }
  }
}
```

Field by field, so three adapters written independently produce the same thing:

| Field | Required | Meaning |
|---|---|---|
| `binding` | yes | the binding answering. The runner supplies it when absent |
| `compiler` | yes | the value that was passed in `--compiler`. Answering for a DIFFERENT compiler is a broken adapter, and the runner says so rather than filing the verdict under the wrong name |
| `fixtures` | yes | one entry per manifest fixture id. A fixture the adapter omits is a failure — it is not a way to skip one |
| `fixtures.<id>.state` | for an `ok` entry | the state rows: `{ save time: { element: value } }`. One row per save time the fixture defines, each naming every state element |
| `fixtures.<id>.state_order` | no | the column-major element order. The runner uses it only when MINTING a golden and never for comparison; when it is absent the golden falls back to the manifest's `initial_conditions` order, then to sorted names |
| `fixtures.<id>.observed` | no | one series per observed field: `{ name: { save time: value } }`. `{}` or absent when the fixture names none. Every name in the fixture's `trajectory.observed` must be present, and is gated at the same band as the state |

**Save-time keys** are written as the adapter's own float repr of the save time.
The runner canonicalizes both sides to `repr(float(t))` and matches BY NUMERIC
VALUE; a key that lands within an ulp of a declared save time still matches, so a
whole trajectory is never unreadable over the last bit of a time stamp.

**Element keys** are bare column-major names. A leading `Model.` namespace is
stripped by the runner, so either spelling is accepted. An element the reference
does not carry is ignored — the reference decides what the trajectory IS — and an
element it does carry and the producer does not is a mismatch, named.

**Save times are not the adapter's to choose.** They are the manifest's `saveat`
for a `"from": "manifest"` fixture and the named inline test's assertion times for
a `"from": "inline_tests"` one, and the adapter reads them the same way the runner
does. The adapter resolves a fixture's `path` by walking up from the manifest's
ABSOLUTE path to the nearest ancestor directory named `tests`.

Plain JSON has no literal for a non-finite value. The runner reads one spelled
as a string `float()` parses (`"NaN"`, `"Infinity"`, `"-Infinity"`), as a bare
`NaN`/`Infinity` token, or as `null`, which it takes as NaN — so the element
fails its comparison by name instead of aborting the run.

### The five outcomes

| Outcome | Written as | Who decides |
|---|---|---|
| `ok` | a fixture entry with `state` (and `observed`) | the adapter produces it; the runner calls it ok |
| `mismatch` | — | the RUNNER's verdict on an `ok` entry outside the band. An adapter never writes it |
| `refused` | `{ "status": "refused", "rule": "<rule or node name>", "reason": "<text>" }` | the adapter, per fixture, continuing with the next |
| `unavailable` | the WHOLE output: `{ "binding": …, "compiler": …, "status": "unavailable", "reason": "<text>" }` | the adapter, when the compiler does not exist in this binding or its runtime is not configured here |
| `error` | `{ "error": "<ExcType>: <message>" }` | the adapter, per fixture, when the load, the build or the run threw |

`refused` and `unavailable` are different facts and must never be merged: a
model a compiler cannot lower is a refusal, and a runtime that is not installed
is an unavailable compiler. An `unavailable` payload has no `fixtures` map;
the runner classifies it locally so the reason survives.

**A non-zero adapter exit with a valid report is allowed** and means at least
one fixture errored. The runner reads and gates the report regardless of the
exit code — aborting on it would throw away the entries that say which fixture
broke. An adapter that exits non-zero WITHOUT a parsable report is a broken
adapter.

## Gate

* a **mismatch** is RED, for every compiler and every binding;
* an **`interpreter` refusal** is always RED: the interpreter is complete over
  the evaluable core (`esm-libraries-spec.md` §2.5.10), so a refusal there is a
  defect rather than coverage;
* a **refusal from any other compiler** is a **named exclusion** — reported with
  the binding, the compiler, the fixture, the rule and the reason, in the report
  and on the console, and green for now — unless this fixture's `required` map
  lists that compiler for that binding, in which case it is RED;
* an **`unavailable`** compiler is reported with its reason and skipped, but
  only for a binding listed in that compiler's `bindings_optional`; an
  unavailable compiler in a `bindings_required` binding is RED;
* an **`error`** is RED for any binding and any compiler. Unlike a refusal it
  says nothing about what a compiler can run, so `required` does not excuse it.

Two cases the outcome table does not name, decided by the runner:

* **no adapter registered at all** — no discovery variable, nothing on PATH, and
  no planned adapter on disk — is the same FACT as an `unavailable` payload,
  reported from the other side, and is governed by the same availability ledger:
  green and named for a `bindings_optional` binding, RED for a required one. It
  is never a refusal, because nothing was asked to lower anything;
* **a broken adapter** — a timeout, no output, unparsable output, or output
  answering for another compiler — is RED for EVERY binding, required or not. An
  optional compiler's build failing is a build failure, and letting it read as a
  legal skip is how a whole lane goes untested while the log says "skipped".

The named-exclusion list under a strict `native` default IS the coverage
backlog, and this tier is where it is read and burned down.

A fixture's `required` map is also checked against the availability ledger: a
fixture that requires `<binding>/<compiler>` to RUN it while
`compilers.<compiler>.bindings_required` does not require that binding to OFFER
the compiler is a manifest error, not a gate.

## Runner

`scripts/run-compiler-agreement-conformance.py`, mirroring
`run-compiled-rhs-conformance.py`:

```
--self-test                                   # goldens vs carried anchors + negative controls; no bindings
--write-golden --bindings julia --compiler interpreter   # mint golden/<id>.json from the reference
--bindings julia,rust,python --compiler native --output <report.json>
```

Flags, in `run-compiled-rhs-conformance.py`'s spelling:

| Flag | Meaning |
|---|---|
| `--manifest <path>` | the manifest to run (default: this directory's) |
| `--bindings a,b,c` | comma-separated bindings (default: the compiler's required + optional bindings) |
| `--compiler`, `--compilers` | comma-separated compilers from `API_SPEC.md` §5.8's vocabulary. The two spellings are one flag; the singular reads better for the one-compiler producer stages and the plural for a whole sweep. Default: every compiler the manifest carries |
| `--output <file>` | where the aggregated report goes (default `conformance-results/compiler_agreement/report.json`) |
| `--results-dir <dir>` | `<dir>/report.json`, for a caller that owns the directory rather than the filename. An explicit `--output` always wins |
| `--timeout <s>` | per-adapter wall clock |
| `--write-golden` | mint from the reference binding and the reference compiler, and refuse any other |
| `--self-test` | the always-on guard; needs no live binding |

`--write-golden` accepts `--bindings julia --compiler interpreter` and nothing
else: the golden IS the Julia `interpreter` trajectory, and minting it from a
compiled path would make the tier compare that path against itself.

`--self-test` checks, in this order: the manifest's shape and both ledgers; every
fixture's run resolves and every anchor point lands on a saved row; every
COMMITTED golden's file shape and its agreement with the anchor it carries; and
then the negative controls — a value moved off its band, a missing element, a
missing save time, an error (required and not), a `required` refusal, an
`interpreter` refusal, an unrequired refusal reported as a named exclusion with
its rule and reason, both arms of the availability ledger, and the §5.44.2
arithmetic itself including the scaled `reduction` floor. The controls run
against a SYNTHETIC reference rather than a committed golden, so the harness is
gated from the day it lands rather than only once phase 2 mints the goldens; with
`golden/` empty the self-test says so and exits 0.

One report holds every compiler a run asked for, keyed
`compilers.<compiler>.bindings.<binding>`, beside the two ledgers the contract
requires it to print by name: `refusals` (each with its rule, its reason and a
verdict of `fail` or `named exclusion`) and `unavailable` (each with its reason).
`scripts/test-conformance.sh` runs one binding and one compiler per stage and
writes `conformance-results/compiler_agreement/<binding>_<compiler>_report.json`.

Exit codes:

| Code | When |
|---|---|
| 0 | the self-test passed, or every required binding answered within tolerance. An unrequired refusal and an unavailable optional compiler are both green, and both are named in the report AND on the console |
| 1 | a mismatch; an `error`; an `interpreter` refusal; a refusal from a binding+compiler a fixture's `required` map names; an `unavailable` (or an unregistered adapter) from a `bindings_required` binding; a broken adapter; or a self-test failure |
| 2 | a manifest or configuration error and no run attempted: the manifest is missing or malformed, the two ledgers contradict each other, a tolerance override carries no reason, a requested compiler is not in the manifest, a requested binding is `scope_excluded`, or a golden is missing for a producer run |

Because the runner exits 0 on a legal skip, a workflow whose point is that a
particular compiler RAN cannot read the exit code alone.
`scripts/assert-compiler-agreement-available.py <report.json> <binding>
<compiler>` reads the report and fails unless that binding's status under that
compiler is literally `ok` — the analog of `assert-compiled-rhs-available.py`,
and for the same reason.

Stages in `scripts/test-conformance.sh` are one per binding per compiler, named
`compiler-agreement <compiler> producer (<binding>)`: `interpreter` and `native`
for Julia, Rust and Python; `xla` for Julia and Rust; `mtk` for Julia; `sympy`
for Python. `compiler-agreement self-test` is the always-on guard and needs no
live binding.

**Where each compiler is gated.** The DEFAULT run of `test-conformance.sh` is
what a plain checkout runs, so it registers only the compilers a plain checkout
can answer for: `interpreter` and `native`. The others have runtimes that must
be provisioned first — an unconfigured one answers `unavailable`, which for a
`bindings_required` binding is RED — so each is gated by
`./scripts/test-conformance.sh --compiler-agreement-only <compiler>` in a
workflow that provisions it, at the same frequency as the main conformance run:

| Compiler | Where it is gated |
|---|---|
| `interpreter`, `native` | the default run (`.github/workflows/conformance-testing.yml`) |
| `mtk` | `.github/workflows/mtk-compiler.yml` — Julia only, same triggers as the conformance workflow, its own depot cache keyed on `scripts/compiler_agreement_mtk_env/Project.toml` |
| `xla` | the `rust-xla` job of `.github/workflows/xla-backends.yml`, which fetches the 144 MB `xla_extension` and exports `XLA_EXTENSION_DIR` first |
| `sympy` | not yet wired |

`--compiler-agreement-only` runs the self-test plus that compiler's producer
stages and nothing else — not the per-binding test suites, not another tier.
Which bindings it runs comes from THIS manifest (`bindings_required` plus
`bindings_optional`), so the option cannot drift from the ledger; a binding that
is only optional for the compiler and whose toolchain is missing on that runner
skips with a warning, which is what `bindings_optional` means, while a required
one with no toolchain still fails. An unrecognised compiler exits 2.

For Rust, the runner adds the `xla` Cargo feature to the adapter's `cargo run
--features …` command when, and only when, `--compiler xla` is what was asked
for and `XLA_EXTENSION_DIR` is set. That choice is made in ONE place, the
runner's `with_compiler_features`, and it applies to the command wherever
discovery found it — the planned one, or the one `scripts/test-conformance.sh`
exports as `EARTHSCI_COMPILER_AGREEMENT_ADAPTER_RUST`, which names only
`conformance-adapters`. So the `interpreter` and `native` stages never build the
`xla` crate graph, and an `xla` run without `XLA_EXTENSION_DIR` builds the
feature-less adapter, which answers `unavailable` naming what is missing; rust
is `bindings_required` for `xla`, so that is RED. That is why the workflow step
exports `XLA_EXTENSION_DIR`. An override command with no `--features` (a
prebuilt binary) is run as given.

For Julia and `mtk`, the two packages that compiler needs — ModelingToolkit and
OrdinaryDiffEqNonlinearSolve — are in an adapter environment of their own,
`pkg/EarthSciAST.jl/scripts/compiler_agreement_mtk_env`, which the adapter
activates for that `--compiler` value alone. They are deliberately NOT in the
sibling `scripts/compiler_agreement_env`: that project is activated by every
other Julia stage of this tier and by the whole inline-test tier, all of which
were resolving and precompiling the SciML symbolic stack for a compiler none of
them names.

A producer stage **declines to start**, with a warning naming exactly what is
missing, when its binding's adapter is not on disk or when `golden/` holds no
reference trajectory. Neither is a silent pass: the stage log says `UNAVAILABLE`
and why. `golden/` is populated, so only a missing adapter can trigger it now,
and the Julia stages run for real with the gate above deciding.

## Adding a fixture

1. Pick a document that already exists under `tests/`. Do not author one here.
2. Append an entry to `manifest.json` with its trajectory source, its
   integration tolerances, its tolerance block and an anchor if the fixture can
   carry one.
3. Mint its golden with `--write-golden --bindings julia` and commit it.
4. Run every compiler. A refusal is a finding to record in the report, not a
   reason to drop the fixture.
