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
//! the vectorized faq evaluator (`ArrayCompiled::debug_eval_rhs`) and writes
//!
//! ```text
//! {"binding":"rust","engine":"interpreter",
//!  "fixtures":{<id>:{"rhs":{<probe>:{<element>:<f64>}}}}}
//! ```
//!
//! with bare `u[i]` / `u[i,j]` / `s` element names. `--engine compiled` writes
//! the contract's whole-output `unavailable` form until the XlaBuilder emitter
//! lands in phase 2.
//!
//! Everything of substance lives in
//! [`earthsci_ast::compiled_rhs_adapter`], so the integration test runs this
//! exact path in-process.

use std::process::ExitCode;

use earthsci_ast::adapter_support::write_report;
use earthsci_ast::compiled_rhs_adapter::{parse_args, run_manifest};

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("compiled-rhs-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    let report = match run_manifest(&args.manifest, args.engine) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("compiled-rhs-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    // Write the report FIRST, so the runner still gets the per-fixture detail
    // for whatever failed, then fail the process.
    if let Err(e) = write_report(&args.output, &report.payload) {
        eprintln!("compiled-rhs-adapter-rust: failed to write output: {e}");
        return ExitCode::FAILURE;
    }
    if !report.failed.is_empty() {
        eprintln!(
            "compiled-rhs-adapter-rust: {} fixture(s) produced no numbers: {}",
            report.failed.len(),
            report.failed.join(", ")
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
