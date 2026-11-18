//! Rust adapter for the INLINE-TEST conformance tiers (CONFORMANCE_SPEC §5.45).
//!
//! ```text
//! earthsci-inline-tests-adapter-rust --manifest <manifest.json> \
//!     --output <out.json> --compiler <interpreter|native|xla|mtk|sympy>
//! ```
//!
//! Discovered by the runner via `$EARTHSCI_INLINE_TESTS_ADAPTER_RUST` or on
//! PATH as `earthsci-inline-tests-adapter-rust`. `--compiler` is REQUIRED and
//! is passed straight through to the inline-test runner: one binary serves
//! every compiler this binding offers, and it does not interpret the value.
//!
//! It writes
//!
//! ```text
//! {"binding":"rust","compiler":"<value>",
//!  "fixtures":{<id>:{"assertions":[{"test_id":…,"assertion_idx":…,
//!                                   "variable":…,"passed":…,"actual":…,
//!                                   "message":…}]}}}
//! ```
//!
//! A compiler that cannot evaluate a document answers that fixture's
//! `refused` with the coded diagnostic it declined with, and one this build
//! cannot provide at all answers the whole output's `unavailable`.
//!
//! Everything of substance lives in [`earthsci_ast::inline_tests_adapter`], so
//! a test runs this exact path in-process.

use std::process::ExitCode;

use earthsci_ast::adapter_support::adapter_main;
use earthsci_ast::inline_tests_adapter::configure;

fn main() -> ExitCode {
    adapter_main("inline-tests-adapter-rust", Some("--compiler"), configure)
}
