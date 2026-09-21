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

> **No goldens are minted yet.** `golden/` does not exist in this tree. Phase 2
> mints `golden/<id>.json` from the Julia `interpreter` and commits them, and
> only then does any producer stage have something to compare against. Until
> then the tier's contract is this file and `manifest.json`.

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
└── golden/<id>.json     # Julia-interpreter trajectory, one file per fixture (phase 2)
```

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
| `decay_solver_block` | `valid/solver_block.esm` | `Decay` | inline `tests` | `transcendental` | the smallest unshaped ODE with a closed form, and the one that carries a `solver` block |

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
      "tolerance": { "source": "pde_simulation | derived", "…": "…" },
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
and the band is that class widened by the integration tolerance:

```
rtol = rtol_class + reltol_integration
atol = atol_class + abstol_integration
```

For the `reduction` class the class floor is scaled rather than fixed, exactly
as `CONFORMANCE_SPEC.md` §5.38.2 defines it:

```
atol = atol_scaled_class · maxᵢ|wantᵢ|  +  abstol_integration
```

with the maximum taken over the saved row **of the reference**, so it is the
same number for every binding. The addition of the integration tolerance is the
whole difference from `compiled_rhs`: a trajectory carries the integrator's own
error on top of the arithmetic's, and a band that ignored it would fail every
binding for a defect none of them has.

An **anchor** is gated separately, at the tolerance its own source declares —
`pde_simulation`'s `traj_analytic_*` for a fixture from that tier, the inline
test's declared `tolerance` for one from a `tests` block. An anchor is a
statement about the physics and a golden is a statement about the arithmetic;
holding them to one band would mean loosening the arithmetic one.

A fixture MAY carry a tighter or looser bound than these rules give, with a
written reason in its entry, and only with one.

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

Planned paths, so the later phases build to the same places:

| Binding | Adapter |
|---|---|
| Julia (reference) | `pkg/EarthSciAST.jl/scripts/compiler_agreement_adapter.jl` |
| Rust | `pkg/earthsci-ast-rs/src/bin/earthsci-compiler-agreement-adapter-rust.rs`, feature `conformance-adapters` |
| Python | `pkg/earthsci-ast-py/src/earthsci_ast/cli/compiler_agreement_adapter.py` |

The adapter writes:

```json
{
  "binding": "<julia|rust|python>",
  "compiler": "<value>",
  "fixtures": {
    "<id>": {
      "state": { "<save time>": { "<element>": <f64> } },
      "observed": { "<name>": { "<save time>": <f64> } }
    }
  }
}
```

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

The named-exclusion list under a strict `native` default IS the coverage
backlog, and this tier is where it is read and burned down.

## Runner

`scripts/run-compiler-agreement-conformance.py`, mirroring
`run-compiled-rhs-conformance.py`:

```
--self-test                                   # goldens vs carried anchors + negative controls; no bindings
--write-golden --bindings julia               # mint golden/<id>.json from the reference interpreter
--bindings julia,rust,python --compiler native --output <report.json>
```

Exit codes: 0 every required binding within tolerance (or the self-test passed);
1 a mismatch, a refusal or an `unavailable` from a `required` binding, or a
self-test failure; 2 a manifest or configuration error. The report lists every
refusal and every unavailable compiler by name and reason.

Stages in `scripts/test-conformance.sh` are one per binding per compiler, named
`compiler-agreement <compiler> producer (<binding>)`: `interpreter` and `native`
for Julia, Rust and Python; `xla` for Julia and Rust; `mtk` for Julia; `sympy`
for Python. `compiler-agreement self-test` is the always-on guard and needs no
live binding.

## Adding a fixture

1. Pick a document that already exists under `tests/`. Do not author one here.
2. Append an entry to `manifest.json` with its trajectory source, its
   integration tolerances, its tolerance block and an anchor if the fixture can
   carry one.
3. Mint its golden with `--write-golden --bindings julia` and commit it.
4. Run every compiler. A refusal is a finding to record in the report, not a
   reason to drop the fixture.
