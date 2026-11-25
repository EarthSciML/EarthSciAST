# Scalar differential testing

Build `formal/.lake/build/bin/esm-lean` with `lake build`, then run from the
repository root in a Python environment with the binding and Hypothesis.

```sh
python -m pip install ./pkg/earthsci-ast-py hypothesis==6.170.17
python scripts/difftest/scalar.py --seed 20261026 --cases 200
```

Each case is an ESM document with one static scalar observation. Lean calls the
same AST evaluator as `static-assertions`, and Python calls its public inline
test runner using the native compiler. The optional Julia and Rust participants
also use their native compilers. The driver compares actual results
and ignores the inline assertion's placeholder expectation. Arithmetic,
comparisons, logical operations, extrema and conditionals use bit comparison.
Two NaNs agree for propagation checks, with any sign or payload.

The generator varies tree shape, arity, and parameters. Its inputs include
subnormals, zero, and values near integer and binary64 boundaries. Unary
negation constructs negative zero from integer zero, so the result survives
the canonical number rule that normalizes integral-valued input floats.
Arithmetic can produce infinities and NaNs from finite inputs. The sweep
reports operation and edge coverage. Agreement here covers
the generated static slice. Angle conversion, libm tolerances, validator
diagnostics, and arrays have separate test surfaces.

Each participant stays alive for the sweep. Use `--adapter NAME=COMMAND` to
add a participant. `--timeout` bounds each complete request and response.
Each input line is a JSON object with `document` and
`requests` fields. Requests identify inline assertions by `test_id` and
one-based `assertion_idx`. The response line has `values` in request order,
encoded as decimal strings containing the unsigned binary64 bits, or an
`error` string. Write diagnostics to standard error.

For an additional Julia comparison, use an environment containing the local
`EarthSciAST` package, `JSON3`, and `OrdinaryDiffEqTsit5`.

```sh
julia --project=formal/.lake/difftest-julia -e \
  'using Pkg; Pkg.develop(path="pkg/EarthSciAST.jl"); Pkg.add(["JSON3", "OrdinaryDiffEqTsit5"])'
python scripts/difftest/scalar.py --timeout 300 \
  --adapter 'julia=julia --project=formal/.lake/difftest-julia scripts/difftest/scalar_julia.jl'
```

For Rust, use the `--jsonl` mode of the inline-test conformance adapter.

```sh
cargo build --locked --manifest-path pkg/earthsci-ast-rs/Cargo.toml \
  --features conformance-adapters --bin earthsci-inline-tests-adapter-rust
python scripts/difftest/scalar.py \
  --adapter 'rust=pkg/earthsci-ast-rs/target/debug/earthsci-inline-tests-adapter-rust --jsonl'
```

A disagreement exits with status 1 and Hypothesis shrinks it to an ordinary ESM
document at `conformance-results/scalar-difftest.esm` (or `--reproducer PATH`).
Replay a document with `--fixture PATH`. CI uses `--observer` to finish the
sweep, report disagreement counts, and upload a shrunk reproducer. Startup
and protocol failures still fail the workflow.

The 1,200-case sweep with seed 20261026 shrank one disagreement to
`min(+0, -0)`. The model returned positive zero and Python returned negative
zero. The Lean model now returns negative zero for both operand orders.
Replay `tests/differential/scalar/negative_zero_min.esm` to check those bits.
