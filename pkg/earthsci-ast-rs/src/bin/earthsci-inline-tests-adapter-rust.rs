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

use earthsci_ast::adapter_support::write_report;
use earthsci_ast::inline_tests_adapter::{parse_args, run_manifest};

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("inline-tests-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    let report = match run_manifest(&args.manifest, args.compiler) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("inline-tests-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    // Write the report FIRST so the runner still gets the per-fixture detail
    // for whatever failed, then fail the process: the contract allows a
    // non-zero exit WITH a valid report and reads it either way.
    if let Err(e) = write_report(&args.output, &report.payload) {
        eprintln!("inline-tests-adapter-rust: failed to write output: {e}");
        return ExitCode::FAILURE;
    }
    if !report.failed.is_empty() {
        eprintln!(
            "inline-tests-adapter-rust: {} fixture(s) errored: {}",
            report.failed.len(),
            report.failed.join(", ")
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
