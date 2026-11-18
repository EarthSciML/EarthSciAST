//! Rust adapter for the `compiler_agreement` conformance tier
//! (CONFORMANCE_SPEC §5.44).
//!
//! ```text
//! earthsci-compiler-agreement-adapter-rust --manifest <manifest.json> \
//!     --output <out.json> --compiler <interpreter|native|xla|mtk|sympy>
//! ```
//!
//! Discovered by the runner via `$EARTHSCI_COMPILER_AGREEMENT_ADAPTER_RUST` or
//! on PATH as `earthsci-compiler-agreement-adapter-rust`. `--compiler` is
//! REQUIRED and is passed straight to `esm_problem`: one binary serves every
//! compiler this binding offers, and it does not interpret the value.
//!
//! It writes
//!
//! ```text
//! {"binding":"rust","compiler":"<value>",
//!  "fixtures":{<id>:{"state_order":[…],
//!                    "state":{<save time>:{<element>:<f64>}},
//!                    "observed":{<name>:{<save time>:<f64>}}}}}
//! ```
//!
//! with bare `u[i]` / `u[i,j]` / `s` element names; a compiler that cannot
//! lower a document answers that fixture's `refused`, and one this build
//! cannot provide at all answers the whole output's `unavailable`.
//!
//! Everything of substance lives in
//! [`earthsci_ast::compiler_agreement_adapter`], so a test runs this exact
//! path in-process.

use std::process::ExitCode;

use earthsci_ast::adapter_support::adapter_main;
use earthsci_ast::compiler_agreement_adapter::configure;

fn main() -> ExitCode {
    adapter_main(
        "compiler-agreement-adapter-rust",
        Some("--compiler"),
        configure,
    )
}
