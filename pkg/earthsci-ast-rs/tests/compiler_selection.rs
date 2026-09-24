//! Choosing the compiler (API_SPEC §5.8, esm-libraries-spec §2.5.10).
//!
//! `ProblemOptions::compiler` names WHICH strategy builds a Problem's
//! right-hand side, over a closed vocabulary, and every Problem reports what
//! ran. What is pinned here is the part a caller can observe:
//!
//!   1. a member this binding does not provide is REFUSED, naming what would
//!      provide it — never answered by building a different one;
//!   2. a value outside the vocabulary is a different failure
//!      (`compiler_unknown`), raised by the entry points that take the
//!      compiler as TEXT, since an unknown value cannot exist in the enum;
//!   3. `native` is STRICT: a rule the tape cannot lower is a CONSTRUCTION
//!      error naming the compiler, the rule and the reason;
//!   4. the same document builds under `interpreter`, which is the reference
//!      and refuses nothing it can evaluate;
//!   5. `native` and `interpreter` agree BIT FOR BIT over a spread of document
//!      shapes — a scalar ODE, a reaction-systems-only chemistry document, a
//!      discretized PDE and an aggregate/contraction document. This is the
//!      whole reason `interpreter` exists: it shares no fast tier with the
//!      compiler it checks;
//!   6. the report names EVERY rule, not only the ones that declined;
//!   7. a document with CONST-tier observeds builds and solves under `native`
//!      with those observeds served from the tape — the pass that used to run
//!      off it, once per solve, through the whole-array overlay.
//!
//! Not pinned here: which documents `native` refuses today. That is the
//! coverage backlog, and `CONFORMANCE_SPEC.md` §5.44 is where it is read.

#![cfg(all(feature = "solve", not(target_arch = "wasm32")))]

use std::path::{Path, PathBuf};

use earthsci_ast::{
    CompileError, Compiler, EsmProblem, ProblemOptions, Rhs, SimulateError, SolveOptions,
    esm_problem, solve,
};

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is pkg/earthsci-ast-rs.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn fixture(rel: &str) -> PathBuf {
    let p = repo_root().join(rel);
    assert!(p.exists(), "fixture {} is missing", p.display());
    p
}

fn build(path: &Path, compiler: Compiler) -> Result<EsmProblem, SimulateError> {
    build_rhs(path, compiler, Rhs::Auto)
}

/// `Rhs::Always` for the fixtures a harness integrates as the conformance
/// adapters do, forcing a right-hand side rather than letting the routing
/// decide.
fn build_rhs(path: &Path, compiler: Compiler, rhs: Rhs) -> Result<EsmProblem, SimulateError> {
    esm_problem(
        path,
        (0.0, 1.0),
        ProblemOptions {
            rhs,
            compiler: Some(compiler),
            ..Default::default()
        },
    )
}

// ---------------------------------------------------------------------------
// 1 + 2: availability, and the vocabulary's edge
// ---------------------------------------------------------------------------

/// The members this binding never provides, whatever it was built with:
/// `mtk` is Julia's and `sympy` is Python's.
///
/// `xla` is NOT in this list. It is the one member whose availability is a
/// property of the BUILD — the `xla` Cargo feature plus a usable runtime — so
/// it has its own pair of tests, one per side of that feature.
#[test]
fn a_compiler_this_binding_does_not_provide_is_refused_not_substituted() {
    let path = fixture("tests/simulation/simple_ode.esm");
    for compiler in [Compiler::Mtk, Compiler::Sympy] {
        let err = match build(&path, compiler) {
            Err(e) => e,
            Ok(_) => panic!("{compiler} must be refused, not built"),
        };
        let msg = err.to_string();
        assert!(
            msg.contains("compiler_unavailable"),
            "the registry code must be in the message: {msg}"
        );
        match err {
            SimulateError::CompilerUnavailable {
                compiler: c,
                details,
            } => {
                assert_eq!(c, compiler.as_str());
                // §2.5.10: the message names what would have to be loaded or
                // built. A refusal that does not is a dead end.
                assert!(
                    details.contains("Julia") || details.contains("Python"),
                    "{compiler}: {details}"
                );
            }
            other => panic!("{compiler} must raise CompilerUnavailable, got {other:?}"),
        }
    }
}

/// Without the `xla` feature, `xla` is `compiler_unavailable` and the message
/// says how to get it — never a fallback to `native`, and never `unknown`,
/// which is a different failure about a different thing.
#[cfg(not(feature = "xla"))]
#[test]
fn xla_is_unavailable_in_a_build_without_the_feature() {
    let path = fixture("tests/simulation/simple_ode.esm");
    match build(&path, Compiler::Xla) {
        Err(SimulateError::CompilerUnavailable { compiler, details }) => {
            assert_eq!(compiler, "xla");
            // §2.5.10: the message names what would have to be built.
            assert!(details.contains("feature"), "{details}");
            assert!(details.contains("XLA_EXTENSION_DIR"), "{details}");
        }
        other => panic!("xla must raise CompilerUnavailable here, got {other:?}"),
    }
}

#[test]
fn a_value_outside_the_vocabulary_is_compiler_unknown() {
    // The enum cannot hold one, so the failure lives where the compiler
    // arrives as TEXT — the CLI flag and the wasm handle both go through here.
    let err = Compiler::parse_named("numba").expect_err("numba is not in the vocabulary");
    assert!(err.contains("compiler_unknown"), "{err}");
    for c in Compiler::vocabulary() {
        assert!(
            err.contains(c.as_str()),
            "the refusal lists the whole vocabulary: {err}"
        );
        assert_eq!(Compiler::parse_named(c.as_str()), Ok(*c));
    }
}

// ---------------------------------------------------------------------------
// 3 + 4: a strict `native`, and the reference that takes the same document
// ---------------------------------------------------------------------------

/// The document `native` refuses, and the reason it refuses for.
///
/// This used to be an `interp.linear` fixture, which was then the largest
/// single decline in the corpus census (405 rules of 1057). That family is on
/// the tape now, so the canonical refusal moved to the next one that is a
/// genuine CAPABILITY gap rather than a cost choice:
/// `polygon_intersection_area` has no array evaluator at all, so nothing about
/// this test can quietly become a tautology the way a lowered `interp.linear`
/// would have.
const REFUSED_FIXTURE: &str = "tests/coupling/interfaces.esm";

/// The refusal must name the RULE, not just the document.
#[test]
fn native_refuses_a_rule_the_tape_cannot_lower_and_names_it() {
    let path = fixture(REFUSED_FIXTURE);
    match build(&path, Compiler::Native) {
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule {
            compiler,
            kind,
            rule,
            tier,
            reason,
        })) => {
            assert_eq!(compiler, "native");
            assert!(
                kind == "observed" || kind == "state derivative",
                "the rule kind is one of the two: {kind}"
            );
            assert!(!rule.is_empty(), "the rule is named");
            assert!(
                tier == "const" || tier == "segment" || tier == "continuous",
                "the cadence tier is reported: {tier}"
            );
            assert!(
                reason.contains("polygon_intersection_area"),
                "the deepest decline reason is carried: {reason}"
            );
        }
        other => panic!("native must refuse a polygon_intersection_area rule, got {other:?}"),
    }
}

#[test]
fn the_default_compiler_is_the_strict_native() {
    // No `compiler` at all: the same refusal, because an unspecified compiler
    // IS `native` and `native` is strict (§2.5.10).
    let path = fixture(REFUSED_FIXTURE);
    let err = esm_problem(path.as_path(), (0.0, 1.0), ProblemOptions::default())
        .expect_err("the default is strict");
    assert!(
        matches!(
            err,
            SimulateError::Compile(CompileError::CompilerRefusedRule { .. })
        ),
        "{err:?}"
    );
}

#[test]
fn the_interpreter_takes_the_document_native_refused() {
    let path = fixture(REFUSED_FIXTURE);
    let prob = build(&path, Compiler::Interpreter).expect("the reference evaluates the core");
    assert_eq!(prob.compiler(), Compiler::Interpreter);
    let report = prob.compiler_report();
    assert_eq!(report.compiler(), Compiler::Interpreter);
    assert!(!report.rules().is_empty());
    // Every rule on the oracle, by design rather than by decline: the
    // interpreter compiles no program, so nothing is "taped" and nothing is a
    // "fallback".
    assert_eq!(report.n_taped(), 0);
    for r in report.rules() {
        assert_eq!(r.tier, "oracle", "{}", r.rule);
        assert!(r.reason.is_none(), "{}", r.rule);
    }
    assert_eq!(report.fused_groups(), 0);
}

// ---------------------------------------------------------------------------
// 5: the reference's whole job
// ---------------------------------------------------------------------------

/// One fixture per document SHAPE, because the two compilers diverge by shape
/// and not by document: a 0-D system, a reaction-systems-only document (no
/// `models` map at all until flattening), a discretized PDE, and an
/// aggregate/contraction document.
const AGREEMENT_FIXTURES: &[&str] = &[
    // A 0-D ODE.
    "tests/simulation/simple_ode.esm",
    // A `reaction_systems`-only document: no `models` map at all until
    // flattening lowers its reactions, which is the routing the `!= 1` fix
    // exists for.
    "tests/simulation/autocatalytic_reaction.esm",
    // A gridded document, whose rows are per-cell keys.
    "tests/conformance/output_derivation/fixtures/gridded.esm",
    // An aggregate over a mounted mesh subsystem, with a CONST-tier rule
    // beside the continuous one.
    "tests/valid/subsystem_mesh_lib.esm",
];

#[test]
fn native_and_the_interpreter_agree_bit_for_bit() {
    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.25, 0.5, 0.75, 1.0]),
        ..Default::default()
    };
    for rel in AGREEMENT_FIXTURES {
        let path = fixture(rel);
        let native = build_rhs(&path, Compiler::Native, Rhs::Always)
            .unwrap_or_else(|e| panic!("{rel} must build under native: {e}"));
        assert_eq!(native.compiler(), Compiler::Native);
        // §5.8: `native` is the array runtime for EVERY document, whatever its
        // shape — a 0-D one included. Nothing here may land on the scalar
        // interpreter.
        assert_eq!(native.backend_kind(), "array", "{rel}");
        let reference = build_rhs(&path, Compiler::Interpreter, Rhs::Always)
            .unwrap_or_else(|e| panic!("{rel} must build under the interpreter: {e}"));

        let a = solve(&native, &opts).unwrap_or_else(|e| panic!("{rel} native solve: {e}"));
        let b = solve(&reference, &opts).unwrap_or_else(|e| panic!("{rel} interpreter solve: {e}"));

        assert_eq!(a.state_variable_names, b.state_variable_names, "{rel}");
        assert_eq!(a.time.len(), b.time.len(), "{rel}");
        for (i, (x, y)) in a.time.iter().zip(b.time.iter()).enumerate() {
            assert_eq!(x.to_bits(), y.to_bits(), "{rel}: time[{i}]");
        }
        for (r, (row_a, row_b)) in a.state.iter().zip(b.state.iter()).enumerate() {
            assert_eq!(row_a.len(), row_b.len(), "{rel}: row {r}");
            for (k, (x, y)) in row_a.iter().zip(row_b.iter()).enumerate() {
                assert_eq!(
                    x.to_bits(),
                    y.to_bits(),
                    "{rel}: {} at t index {k}: native {x:e} vs interpreter {y:e}",
                    a.state_variable_names[r]
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 6: the report
// ---------------------------------------------------------------------------

#[test]
fn the_report_names_every_rule_not_only_the_declines() {
    // The half `SolutionMetadata::tape_fallbacks` cannot answer: a document
    // with no declines reports an empty fallback list and says nothing about
    // the rules that DID lower, nor at which cadence they run.
    let path = fixture("tests/conformance/output_derivation/fixtures/gridded.esm");
    let prob = build_rhs(&path, Compiler::Native, Rhs::Always).expect("builds");
    let report = prob.compiler_report();
    assert!(!report.rules().is_empty());
    assert_eq!(
        report.n_oracle(),
        0,
        "a native build has no rule off the tape"
    );
    assert_eq!(report.n_taped(), report.rules().len());
    let mut derivatives = 0;
    for r in report.rules() {
        assert!(!r.rule.is_empty());
        assert!(
            matches!(r.cadence, "const" | "segment" | "continuous"),
            "{}: {}",
            r.rule,
            r.cadence
        );
        assert!(
            matches!(r.kind, "observed" | "state derivative"),
            "{}",
            r.kind
        );
        if r.kind == "state derivative" {
            derivatives += 1;
        }
    }
    assert!(derivatives > 0, "a gridded document has state derivatives");
    // The summary line `esm simulate` prints.
    let line = report.to_string();
    assert!(line.contains("compiler native"), "{line}");
}

#[test]
fn a_static_document_reports_its_observeds_on_the_named_compiler() {
    // A document with nothing to integrate has no right-hand side, but its
    // observed graph is still evaluated at construction, and §2.5.10 puts that
    // evaluation under the compiler the caller named (issue #484): the tape
    // under `native`, the per-cell oracle under `interpreter`.
    let path = fixture("tests/valid/nonlinear_two_component_static.esm");
    for (compiler, tier) in [
        (Compiler::Native, "taped"),
        (Compiler::Interpreter, "oracle"),
    ] {
        let prob = build(&path, compiler).expect("a static document still builds");
        assert_eq!(prob.backend_kind(), "static");
        let report = prob.compiler_report();
        assert!(!report.rules().is_empty(), "[{compiler}] {report}");
        for r in report.rules() {
            assert_eq!(r.kind, "observed", "[{compiler}] {}", r.rule);
            assert_eq!(r.tier, tier, "[{compiler}] {}", r.rule);
            assert!(r.reason.is_none(), "[{compiler}] {}", r.rule);
        }
        assert!(
            !prob.observed_field_names().is_empty(),
            "[{compiler}] the observeds were evaluated"
        );
    }
}

// ---------------------------------------------------------------------------
// 7: the CONST-tier observeds, served from the tape
// ---------------------------------------------------------------------------

/// 507 of the 808 documents the 2026-09-21 census built carry at least one
/// CONST-tier observed, and every one of them used to be materialized off the
/// tape — `hoist_static_observeds` ran BEFORE `build_solve_tape` and evaluated
/// them through the whole-array overlay, with the per-cell oracle beneath it
/// and no entry in any report. Under `native` the tape's own CONST section
/// computes them, so the document must build, solve, and agree with the
/// reference.
#[test]
fn a_const_tier_observed_document_is_served_from_the_tape() {
    let path = fixture(
        "tests/conformance/shaped_parameter_broadcast/fixtures/shaped_parameter_scalar_default.esm",
    );
    let prob = build_rhs(&path, Compiler::Native, Rhs::Always).expect("builds under native");
    let report = prob.compiler_report();
    let n_const = report
        .rules()
        .iter()
        .filter(|r| r.cadence == "const")
        .count();
    assert!(
        n_const > 0,
        "the fixture must carry a CONST-tier observed, or this test proves nothing"
    );
    assert_eq!(report.n_oracle(), 0);

    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.5, 1.0]),
        ..Default::default()
    };
    let native = solve(&prob, &opts).expect("solves under native");
    let reference = solve(
        &build_rhs(&path, Compiler::Interpreter, Rhs::Always)
            .expect("builds under the interpreter"),
        &opts,
    )
    .expect("solves under the interpreter");
    assert_eq!(native.state_variable_names, reference.state_variable_names);
    for (r, (a, b)) in native.state.iter().zip(reference.state.iter()).enumerate() {
        for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "{} at t index {k}",
                native.state_variable_names[r]
            );
        }
    }
}

// ---------------------------------------------------------------------------
// 8: `xla`, the specialty compiler that needs a heavy external dependency
// ---------------------------------------------------------------------------
//
// These run only in a build that HAS the dependency (`--features xla` against
// an unpacked `xla_extension`). The other side of the feature is pinned by
// `xla_is_unavailable_in_a_build_without_the_feature` above; between them, no
// build of this crate leaves `xla` untested.

/// The trajectory band `xla` is held to against the `interpreter` reference.
///
/// NOT bit-for-bit, and that is the standing ruling rather than a slack
/// tolerance: XLA's `exp`/`log`/`pow` are not Rust's libm, and XLA's `reduce`
/// does not pin the summation order a reduction's per-cell odometer does
/// (`simulate_array::tape::xla_emit`'s module docs). Those differences enter
/// the right-hand side at the last bits and the integrator then amplifies
/// them over the run, which is what the loose end of this band pays for. The
/// per-fixture bands the compiler-agreement tier writes (CONFORMANCE_SPEC
/// §5.44) are the authority; this is a unit-test band over four documents.
#[cfg(feature = "xla")]
const XLA_RTOL: f64 = 1e-7;
#[cfg(feature = "xla")]
const XLA_ATOL: f64 = 1e-10;

/// The whole deliverable, from the caller's side: naming `xla` builds a
/// Problem whose right-hand side IS the compiled program, it solves, it
/// reports itself as `xla`, and it lands where the reference lands.
#[cfg(feature = "xla")]
#[test]
fn xla_solves_and_agrees_with_the_interpreter() {
    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.25, 0.5, 0.75, 1.0]),
        ..Default::default()
    };
    for rel in AGREEMENT_FIXTURES {
        let path = fixture(rel);
        let xla = build_rhs(&path, Compiler::Xla, Rhs::Always)
            .unwrap_or_else(|e| panic!("{rel} must build under xla: {e}"));
        assert_eq!(xla.compiler(), Compiler::Xla);
        assert_eq!(xla.backend_kind(), "array", "{rel}");

        // Every rule of the model is in the emitted program: `xla` is strict
        // twice over, so a rule anywhere else would have been a build refusal.
        // The setup evaluations outside the rule set — a field initial
        // condition — are reported beside them, served by the whole-array
        // overlay rather than walked per cell.
        let report = xla.compiler_report();
        assert_eq!(report.compiler(), Compiler::Xla, "{rel}");
        assert!(!report.rules().is_empty(), "{rel}");
        assert_eq!(report.n_oracle(), 0, "{rel}");
        assert_eq!(report.n_taped(), 0, "{rel}");
        assert_eq!(
            report.n_xla() + report.n_vectorized(),
            report.rules().len(),
            "{rel}"
        );
        for r in report.rules() {
            let want = match r.kind {
                "observed" | "state derivative" => "xla",
                _ => "vectorized",
            };
            assert_eq!(r.tier, want, "{rel}: {}", r.rule);
            assert!(r.reason.is_none(), "{rel}: {}", r.rule);
        }
        assert!(report.to_string().contains("compiler xla"), "{rel}");

        let reference = build_rhs(&path, Compiler::Interpreter, Rhs::Always)
            .unwrap_or_else(|e| panic!("{rel} must build under the interpreter: {e}"));
        let a = solve(&xla, &opts).unwrap_or_else(|e| panic!("{rel} xla solve: {e}"));
        let b = solve(&reference, &opts).unwrap_or_else(|e| panic!("{rel} interpreter solve: {e}"));

        assert_eq!(a.state_variable_names, b.state_variable_names, "{rel}");
        assert_eq!(a.time.len(), b.time.len(), "{rel}");
        for (r, (row_a, row_b)) in a.state.iter().zip(b.state.iter()).enumerate() {
            assert_eq!(row_a.len(), row_b.len(), "{rel}: row {r}");
            for (k, (x, y)) in row_a.iter().zip(row_b.iter()).enumerate() {
                assert!(
                    (x - y).abs() <= XLA_ATOL + XLA_RTOL * y.abs(),
                    "{rel}: {} at t index {k}: xla {x:e} vs interpreter {y:e}",
                    a.state_variable_names[r]
                );
            }
        }
    }
}

/// `xla` is strict the way `native` is, and refuses the same document for the
/// same reason — because the FIRST gate it meets is the tape's, which names
/// the rule and its cadence tier. An emitter that saw the `Instr::Fallback`
/// instead could only name the instruction.
#[cfg(feature = "xla")]
#[test]
fn xla_refuses_a_rule_the_tape_cannot_lower_and_names_it() {
    let path = fixture(REFUSED_FIXTURE);
    match build(&path, Compiler::Xla) {
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule {
            compiler,
            rule,
            tier,
            reason,
            ..
        })) => {
            assert_eq!(compiler, "xla");
            assert!(!rule.is_empty(), "the rule is named");
            assert!(
                tier == "const" || tier == "segment" || tier == "continuous",
                "the cadence tier is reported: {tier}"
            );
            assert!(
                reason.contains("polygon_intersection_area"),
                "the deepest decline reason is carried: {reason}"
            );
        }
        other => panic!("xla must refuse a polygon_intersection_area rule, got {other:?}"),
    }
}

/// The observed passes under `xla`. The emitted program's only output is `du`,
/// so the observeds reported at output times are served from the same tape the
/// emitter was built from — and must still agree with the reference, or the
/// two halves of the build have drifted apart.
///
/// Read through `output_observed`, which makes the array-valued CONST
/// observeds appear as per-cell rows beside the states: that is the pass
/// esm-libraries-spec §2.5.10 names ("the observeds reported at output
/// times"), and the one that runs most often.
#[cfg(feature = "xla")]
#[test]
fn xla_reports_observeds_from_the_tape_the_emitter_was_built_from() {
    // The fixture the `native` arm above uses for the same question: two
    // CONST-tier observeds, which is the pass that used to run off the tape.
    let path = fixture(
        "tests/conformance/shaped_parameter_broadcast/fixtures/shaped_parameter_scalar_default.esm",
    );
    let xla = build_rhs(&path, Compiler::Xla, Rhs::Always).expect("builds under xla");
    let reference =
        build_rhs(&path, Compiler::Interpreter, Rhs::Always).expect("builds under the interpreter");
    let names = xla.observed_variable_names();
    assert!(!names.is_empty(), "the fixture must carry observeds");
    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.5, 1.0]),
        output_observed: names.clone(),
        ..Default::default()
    };

    let a = solve(&xla, &opts).expect("xla solves");
    let b = solve(&reference, &opts).expect("the interpreter solves");
    assert_eq!(a.state_variable_names, b.state_variable_names);
    // The observed rows are the ones the states do not account for; without
    // them this compares nothing the state comparison did not already.
    assert!(
        a.state_variable_names.len() > xla.state_variable_names().len(),
        "the observeds must reach the solution as rows beside the states, got {:?}",
        a.state_variable_names
    );
    for (r, (row_a, row_b)) in a.state.iter().zip(b.state.iter()).enumerate() {
        for (k, (x, y)) in row_a.iter().zip(row_b.iter()).enumerate() {
            assert!(
                (x - y).abs() <= XLA_ATOL + XLA_RTOL * y.abs(),
                "{} at t index {k}: xla {x:e} vs interpreter {y:e}",
                a.state_variable_names[r]
            );
        }
    }
}
