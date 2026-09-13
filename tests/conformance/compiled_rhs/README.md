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
  fixture. Empty in phase 1; phase 2 fills it as coverage lands. A refusal from a
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

Two other outcomes exist, and both must be explicit:

* **Refused** (compiled engine only). The engine cannot lower the model
  completely. The fixture entry is
  `{ "status": "refused", "rule": "<rule or node name>", "reason": "<text>" }`
  and the adapter continues with the next fixture. This is the hard-error
  ruling made visible.
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

Compiled-engine hooks land in phase 2 (Julia: the direct StableHLO emitter in
the Reactant extension; Rust: the XlaBuilder emitter over the tape). Until
then each adapter answers `--engine compiled` with `unavailable` and a reason
that says so.

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
