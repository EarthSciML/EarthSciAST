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

use earthsci_ast::adapter_support::write_report;
use earthsci_ast::compiler_agreement_adapter::{parse_args, run_manifest};

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("compiler-agreement-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    let report = match run_manifest(&args.manifest, args.compiler) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("compiler-agreement-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    // Write the report FIRST so the runner still gets the per-fixture detail
    // for whatever failed, then fail the process: the contract allows a
    // non-zero exit WITH a valid report and reads it either way.
    if let Err(e) = write_report(&args.output, &report.payload) {
        eprintln!("compiler-agreement-adapter-rust: failed to write output: {e}");
        return ExitCode::FAILURE;
    }
    if !report.failed.is_empty() {
        eprintln!(
            "compiler-agreement-adapter-rust: {} fixture(s) errored: {}",
            report.failed.len(),
            report.failed.join(", ")
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
