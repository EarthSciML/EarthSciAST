//! `earthsci-determinism-adapter-rust` — the Rust producer for the cross-binding
//! determinism conformance harness (`scripts/run-determinism-conformance.py`,
//! CONFORMANCE_SPEC.md §5.5.4).
//!
//! Everything of substance lives in the library, behind
//! [`earthsci_ast::adapter_support::run_determinism_adapter`].
//!
//! Invoked as `earthsci-determinism-adapter-rust --manifest <m.json> --output <r.json>`.

use earthsci_ast::adapter_support::{parse_manifest_output_args, run_determinism_adapter as run};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = match parse_manifest_output_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("determinism-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    match run(&args.manifest, &args.output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("determinism-adapter-rust: {e}");
            ExitCode::FAILURE
        }
    }
}
