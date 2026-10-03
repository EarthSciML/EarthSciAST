//! What `esm_problem` builds from a path, whatever the right-hand-side mode.
//!
//! Construction is the front door every caller goes through, so a document it
//! accepts is one the binding answers for. Three things are pinned here:
//!
//!   1. a document that does not LOAD — a schema violation, a major version
//!      this library does not read — is refused under `Rhs::Auto` too, not
//!      built as an empty static problem (esm-libraries-spec §2.1a: a library
//!      MUST NOT silently accept an invalid file);
//!   2. a relative `{ref}` resolves against the referencing file's directory
//!      (esm-spec §4.7), not the process's working directory;
//!   3. a document with nothing to integrate that carries an implicit equation
//!      or an event is refused with `unsupported_construct` (esm-spec §9.6.6),
//!      exactly as the array route refuses it, rather than evaluated without it.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{
    CompileError, Compiler, EsmProblem, ProblemOptions, SimulateError, esm_problem,
};

fn fixture(rel: &str) -> PathBuf {
    // CARGO_MANIFEST_DIR is pkg/earthsci-ast-rs.
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    assert!(p.exists(), "fixture {} is missing", p.display());
    p
}

fn build(rel: &str, compiler: Compiler) -> Result<EsmProblem, SimulateError> {
    esm_problem(
        fixture(rel).as_path(),
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        },
    )
}

const COMPILERS: [Compiler; 2] = [Compiler::Native, Compiler::Interpreter];

#[test]
fn a_document_that_does_not_load_is_refused() {
    for (rel, needle) in [
        ("tests/invalid/missing_metadata.esm", "Schema validation"),
        (
            "tests/version_compatibility/version_2_5_1_major_rejection.esm",
            "major version",
        ),
        ("tests/invalid/faq/arrayop_op_removed.esm", "removed_op"),
    ] {
        for compiler in COMPILERS {
            let err = build(rel, compiler)
                .err()
                .unwrap_or_else(|| panic!("{rel} does not load, yet {compiler:?} built it"));
            let msg = err.to_string();
            assert!(
                msg.contains("loading the document") && msg.contains(needle),
                "{rel} ({compiler:?}): {msg}"
            );
        }
    }
}

#[test]
fn a_relative_ref_resolves_against_the_document_directory() {
    // The test process runs in the crate directory, two levels above the
    // fixture's: the ref resolves only if the loader anchors it on the file.
    for compiler in COMPILERS {
        build("tests/coupling_libraries/assembly_import.esm", compiler)
            .unwrap_or_else(|e| panic!("{compiler:?}: {e}"));
    }
}

#[test]
fn a_state_free_document_with_an_implicit_equation_is_refused() {
    for compiler in COMPILERS {
        let err = build(
            "tests/conformance/unsupported_construct/fixtures/implicit_equation_on_the_scalar_path.esm",
            compiler,
        )
        .err()
        .unwrap_or_else(|| panic!("{compiler:?} built a document without its implicit equation"));
        assert!(
            matches!(
                err,
                SimulateError::Compile(CompileError::UnsupportedConstruct {
                    construct: "implicit equation",
                    ..
                })
            ),
            "{compiler:?}: {err:?}"
        );
    }
}

fn refusal(rel: &str, compiler: Compiler) -> String {
    build(rel, compiler)
        .err()
        .unwrap_or_else(|| panic!("{compiler:?} built {rel}"))
        .to_string()
}

#[test]
fn a_callback_variable_no_callback_supplies_is_refused() {
    // esm-spec §9.6.6 `callback_unregistered`: at construction, and under the
    // interpreter too, which used to build and fault at its first call.
    for compiler in COMPILERS {
        let msg = refusal("tests/coupling/callback_examples.esm", compiler);
        assert!(
            msg.contains("callback_unregistered") && msg.contains("CropWeatherCoupling"),
            "{compiler:?}: {msg}"
        );
    }
}

#[test]
fn a_degenerate_polygon_operand_nothing_reads_is_refused() {
    // esm-spec §8.6.1: the all-zero default rings are degenerate operands; the
    // state-free observed that clips them is evaluated at build, so refused.
    for compiler in COMPILERS {
        let msg = refusal(
            "tests/conformance/pushdown/fixtures/pushdown_polygon_area.esm",
            compiler,
        );
        assert!(
            msg.contains("E_TREEWALK_GEOMETRY_CLIP"),
            "{compiler:?}: {msg}"
        );
    }
}

#[test]
fn a_control_character_in_a_declared_name_is_a_load_error() {
    // esm-spec §4.9.1.2, enforced by the schema's `$defs/Identifier`.
    for compiler in COMPILERS {
        let msg = refusal("tests/future/security/null_byte_injection.esm", compiler);
        assert!(
            msg.contains("loading the document") && msg.contains("does not match"),
            "{compiler:?}: {msg}"
        );
    }
}

#[test]
fn a_reference_integrity_error_is_refused_with_the_validator_code() {
    // esm-libraries-spec §2.5.2: construction refuses on the validator's
    // reference-integrity findings.
    for compiler in COMPILERS {
        let msg = refusal("tests/invalid/undefined_parameter.esm", compiler);
        assert!(msg.contains("[undefined_parameter]"), "{compiler:?}: {msg}");
    }
}

#[test]
fn a_rate_law_reading_a_species_is_not_an_undefined_parameter() {
    // `k / A`, with `A` a species of the system: a valid rate law.
    for compiler in COMPILERS {
        build(
            "tests/simulation/mass_action_substrate_cancellation.esm",
            compiler,
        )
        .unwrap_or_else(|e| panic!("{compiler:?}: {e}"));
    }
}
