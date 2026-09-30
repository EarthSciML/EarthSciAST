# Scalar `bool_and_or` reductions (`bool_and_or_reductions`)

CONFORMANCE_SPEC §5.6.1: a `faq` whose semiring is `bool_and_or` and which has
NO output index is a number, and every numeric evaluator runs it, under every
compiler. From `0` (`false`), each admitted combination folds in as
`acc = (acc ≠ 0 ∨ term ≠ 0) ? 1 : 0`, so the result is exactly `0` or `1`, a
`NaN` term reads as true, a combination the `filter` excludes contributes
nothing and an empty reduction is `0`. Every step is crisp, so the visiting
order does not matter and native and the interpreter agree bit for bit.

An ARRAY-valued `bool_and_or` reduction (an output index, and a contracted one)
stays rejected at build in every binding. It is not a fixture here, because a
rejection is not an inline-test value.

## What it closed

Before this tier the four evaluators disagreed: Julia rejected every
`bool_and_or` reduction, scalar or array-valued; the Rust interpreter ran both
kinds; Rust's native compiler refused both; Python's interpreter ran both and its
native refused a filtered scalar one.

## The fixture

`fixtures/scalar_bool_and_or.esm`: `u` decays from five distinct values, so
`any_hot` (one contracted index) and `spread` (two, with a filter excluding the
diagonal) are 1 at t = 0 and 0 at t = 1, and `never` is 0 throughout. Every
binding runs it under `interpreter` and `native`; the golden is the Julia
interpreter's.

## Named exclusions

None.
