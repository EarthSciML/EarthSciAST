# earthsci-ast-cli

The `esm` command-line tool for [EarthSciML](https://github.com/EarthSciML)
Abstract Syntax Tree Format (`.esm`) documents: validate, convert,
pretty-print, analyze, test and simulate them. The library underneath is
[`earthsci-ast`](https://crates.io/crates/earthsci-ast).

```bash
cargo install earthsci-ast-cli --features esio
esm --help
```

Prebuilt binaries are attached to each
[GitHub release](https://github.com/EarthSciML/EarthSciAST/releases).

## Time integrators

`esm simulate` integrates a document's differential equations on one of two
backends. Each is a cargo feature, and they are additive:

| feature | backend | `--backend` |
| --- | --- | --- |
| `diffsol` (default) | [diffsol](https://crates.io/crates/diffsol), the solver `earthsci-ast` links | `diffsol` |
| `integrator` | [EarthSciIntegrator](https://github.com/EarthSciML/EarthSciIntegrator) | `integrator` |

```bash
# diffsol only (the default)
cargo install earthsci-ast-cli
# EarthSciIntegrator only
cargo install earthsci-ast-cli --no-default-features --features integrator
# both; pick one per run with --backend
cargo install earthsci-ast-cli --features integrator
```

Without `--backend`, `esm simulate` uses diffsol when the build has it and
the integrator otherwise. Naming a backend the build lacks is an error that
names the feature to build with. A build with neither still evaluates a
document with no differential equations.

The integrator plans a **run configuration** against the document (how the
right-hand side splits into operators, how they are scheduled, the macro
step) and then runs the plan:

```bash
# Default: the integrator's own schedule ("auto"), inside fixed macro steps
# of --dt seconds (default: a hundredth of the run)
esm simulate model.esm --time 3600 --backend integrator --dt 60 -o out.json

# Your own run configuration; its `model` must name model.esm
esm simulate model.esm --time 3600 --backend integrator --run-config run.json

# Keep the plan to inspect it (by default it is written to a temporary
# directory and removed)
esm simulate model.esm --time 3600 --backend integrator --plan-dir plan/
```

The integrator's runtime needs a fixed macro step, so a `--run-config` must
give `step.dt`.

With a fixed macro step, the integrator reports the state at the start and
at every macro-step boundary; otherwise at the end of the run. The diffsol
backend alone evaluates `--observed` fields along the trajectory, and
`esm test` and `esm benchmark --bench-type simulate` run on diffsol only.

EarthSciIntegrator depends on `earthsci-ast` by its own version requirement.
When this crate's version is outside that requirement (one was released before
the other), cargo builds a second copy of `earthsci-ast` for the integrator,
and its planner refuses a document in an esm format newer than that copy
reads.

Because the integrator reads the document from disk itself, it also refuses
what it cannot match with the Problem `esm` builds: `--observed`,
`--compiler`, a document whose data sizes an index set differently from the
document's own declaration, and a state it cannot label element by element.

## Other features

- `esio`: read the parquet, netcdf and zarr files a document's `data_sources`
  name.
- `xla`: the XLA right-hand-side compiler (`--compiler xla`); see the
  `earthsci-ast` README.

## License

AGPL-3.0-only.
