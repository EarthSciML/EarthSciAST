# Static array semantics

These state-free fixtures cover the shaped-parameter and elementwise-observed
gather rules from the legacy trajectory tiers. The gather, prefix-scan, nested
reduction, and ragged cases reuse the authored `native_model_shapes` documents
and their reference outputs. The const-subscript mapping case spells clamping
and wrapping with ordinary ESM expressions. The evaluator's optional
`const_array_boundaries` input has no document spelling.

The shared runner grades against each document's assertions and the committed
reference output. Julia, Python, and Rust run with `--compiler native` in the
native conformance stage. Lean scores the same documents in formal CI.
