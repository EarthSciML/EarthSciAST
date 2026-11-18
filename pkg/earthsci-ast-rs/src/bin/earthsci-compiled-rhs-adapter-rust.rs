//! Rust adapter for the `compiled_rhs` cross-language conformance tier.
//!
//! ```text
//! earthsci-compiled-rhs-adapter-rust --manifest <manifest.json> \
//!     --output <out.json> [--engine interpreter|compiled]
//! ```
//!
//! Discovered by the runner via `$EARTHSCI_COMPILED_RHS_ADAPTER_RUST` or on
//! PATH as `earthsci-compiled-rhs-adapter-rust`. `--engine` defaults to
//! `interpreter`, which evaluates `f(u, p, t)` at every manifest probe through
//! the per-cell oracle (`ArrayCompiled::debug_eval_rhs`) and writes
//!
//! ```text
//! {"binding":"rust","engine":"interpreter",
//!  "fixtures":{<id>:{"rhs":{<probe>:{<element>:<f64>}}}}}
//! ```
//!
//! with bare `u[i]` / `u[i,j]` / `s` element names.
//!
//! `--engine compiled` runs the XlaBuilder emitter over the tape through PJRT
//! (feature `xla`, OFF by default). A model the emitter cannot lower
//! completely becomes that fixture's `refused` entry, naming the rule and the
//! reason. A binary built WITHOUT the feature — or one built with it on a
//! machine whose PJRT client will not start — writes the contract's
//! whole-output `unavailable` form instead, which is why this binary still
//! builds and answers without any XLA installation at all.
//!
//! Everything of substance lives in
//! [`earthsci_ast::compiled_rhs_adapter`], so the integration test runs this
//! exact path in-process.

use std::process::ExitCode;

use earthsci_ast::adapter_support::adapter_main;
use earthsci_ast::compiled_rhs_adapter::Engine;

fn main() -> ExitCode {
    adapter_main(
        "compiled-rhs-adapter-rust",
        Some("--engine"),
        Engine::configure,
    )
}
