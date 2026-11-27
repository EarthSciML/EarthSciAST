# Static array semantics

These state-free fixtures cover the shaped-parameter and elementwise-observed
gather rules from the legacy trajectory tiers. The gather, prefix-scan, nested
reduction, and ragged cases reuse the authored `native_model_shapes` documents
and their reference outputs. The const-subscript mapping case spells clamping
and wrapping with ordinary ESM expressions. The evaluator's optional
`const_array_boundaries` input has no document spelling.

The shared runner grades against each document's assertions and the committed
reference output. The manifest requires Julia, Python, and Rust to run every
document under both the `interpreter` and `native` compilers, so each binding
is graded in both inline-test conformance stages. Lean scores the same
documents in formal CI.

The seven entries that point at `native_model_shapes` documents are graded for
Julia and Rust in that tier as well. They are listed here because
`native_model_shapes` requires neither Python nor Lean, and this tier is how
those two participants reach them.
