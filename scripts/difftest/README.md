# Seeded differential testing

Build `formal/.lake/build/bin/esm-lean` with `lake build`, then run from the
repository root in a Python environment with the binding and Hypothesis.

```sh
python -m pip install './pkg/earthsci-ast-py[simulate]' hypothesis==6.170.17
python scripts/difftest/scalar.py --seed 20261026 --cases 200
```

Each scalar case is an ESM document with one static observation. Lean calls the
same AST evaluator as `static-assertions`, and Python calls its public inline
test runner using the native compiler. The optional Julia and Rust participants
also use their native compilers. The driver compares actual results
and ignores the inline assertion's placeholder expectation. Arithmetic,
comparisons, logical operations, extrema and conditionals use bit comparison.
Two NaNs agree for propagation checks, with any sign or payload.

The scalar generator varies tree shape, arity, and parameters. Its inputs include
subnormals, zero, and values near integer and binary64 boundaries. Unary
negation constructs negative zero from integer zero, so the result survives
the canonical number rule that normalizes integral-valued input floats.
Arithmetic can produce infinities and NaNs from finite inputs. The sweep
reports operation and edge coverage. Agreement here covers
the generated static slice. Angle conversion, libm tolerances, and validator
diagnostics have separate test surfaces.

Pass `--shaped` to generate documents with static arrays. The shaped sweep
allocates cases across seven families and compares every cell of the result.
It covers filtered `faq` reductions, indirect gathers, transpose, reshape,
concat, scalar broadcast, and overlapping `makearray` regions. Cases vary
interval extents from one to four and use small integer inputs. Transpose is
tested as a bare array definition, including singleton axes. The reshape and
concat cases start at extent two and observe each transformed cell through a
literal gather. The shaped results compare exactly in binary64, including the
sign of zero.

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
document at `conformance-results/scalar-difftest.esm` or
`conformance-results/shaped-difftest.esm`. Use `--reproducer PATH` to choose
another location or `--fixture PATH` to replay that document. The driver prints
the test ID and assertion number for the first differing cell.

Formal CI runs 200 scalar and 140 shaped cases with seed `20261026`. The
nightly workflow runs 1,200 scalar and 700 shaped cases with its GitHub run ID
as the seed, so a rerun uses the same cases. Both runs compare Lean with the
native compilers of Python, Julia and Rust, fail on disagreement, and upload
the shrunk reproducer.

The 1,200-case sweep with seed 20261026 shrank one disagreement to
`min(+0, -0)`. The model returned positive zero and Python returned negative
zero. The Lean model now returns negative zero for both operand orders.
Replay `tests/differential/scalar/negative_zero_min.esm` to check those bits.

The 1×1 bare transpose in `tests/differential/shaped/bare_transpose_1x1.esm`
preserves both axes of a one-cell const array and returns positive zero.
`tests/differential/shaped/permuted_static_alias.esm` checks a state-free alias
that reverses its operand's declared axes and returns `3` for the saved cell.

Pass `--fixture` more than once to replay several documents with one set of
adapters. Formal CI replays every document under `tests/differential` this way
before the generated sweeps.

```sh
python scripts/difftest/scalar.py --timeout 300 \
  --fixture tests/differential/shaped/bare_transpose_1x1.esm \
  --fixture tests/differential/shaped/permuted_static_alias.esm \
  --adapter 'julia=julia --project=formal/.lake/difftest-julia scripts/difftest/scalar_julia.jl'
```
