//! `observed_field` on a document with NO state variables (API_SPEC §5.8).
//!
//! A document that declares no differential equations has nothing to integrate
//! — `solve` refuses it with `NotDynamic` — but its whole content is its
//! observed graph, and reading that back by name is what `observed_field` is
//! for. Two properties are pinned here:
//!
//! 1. **It works with no options set.** `observed_field` is stable API, so the
//!    plain `esm_problem(input, tspan, Default::default())` call has to answer.
//!    Before this it silently answered nothing unless the caller knew to pass
//!    `build_pipeline: true` AND to hand in raw JSON rather than a typed
//!    document — a precondition the surface contract never stated. Every
//!    `ProblemInput` shape is exercised, because the four of them used to
//!    disagree.
//!
//! 2. **The name-resolution rule.** A bare name resolves only on a
//!    SINGLE-component document. On a multi-component one it is refused with
//!    the candidates named, rather than bound to whichever sorted first —
//!    which is the wrong-answer-instead-of-missing-answer failure esm-spec
//!    §6.6.2 rules specifically non-conforming for override keys.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::path::Path;

use earthsci_ast::{ProblemInput, ProblemOptions, SimulateError, esm_problem, observed_field};

const ONE_COMPONENT: &str = "../../tests/valid/nonlinear_mogi_shape.esm";
const TWO_COMPONENT: &str = "../../tests/valid/nonlinear_two_component_static.esm";

/// The Mogi fixture's two closed-form displacements at the declared defaults
/// (`dV = 1e6`, `d = 3000`, `r = 1000`, `nu = 0.25`), computed independently of
/// the library so a shared bug in the evaluator cannot make this pass.
fn mogi_oracle() -> (f64, f64) {
    let (dv, d, r, nu) = (1.0e6f64, 3000.0f64, 1000.0f64, 0.25f64);
    let denom = std::f64::consts::PI * (r * r + d * d).powf(1.5);
    ((1.0 - nu) * dv * r / denom, (1.0 - nu) * dv * d / denom)
}

fn opts() -> ProblemOptions {
    ProblemOptions::default()
}

fn scalar(prob: &earthsci_ast::EsmProblem, name: &str) -> f64 {
    let a = observed_field(prob, name).unwrap_or_else(|e| panic!("observed_field({name}): {e}"));
    assert_eq!(a.len(), 1, "{name} is a rank-0 observed");
    a.iter().next().copied().unwrap()
}

/// Every `ProblemInput` shape, on the same document, must answer identically.
/// The typed-document and flattened-system shapes are the ones that used to
/// come back empty.
#[test]
fn every_input_shape_answers_the_same() {
    let (ur, uz) = mogi_oracle();
    let raw: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(ONE_COMPONENT).unwrap()).unwrap();
    let file = earthsci_ast::load_path_with_options(Path::new(ONE_COMPONENT), &BTreeMap::new())
        .expect("load");
    let flat = earthsci_ast::flatten(&file).expect("flatten");

    for (label, input) in [
        ("Json", ProblemInput::Json(&raw)),
        ("Path", ProblemInput::Path(Path::new(ONE_COMPONENT))),
        ("File", ProblemInput::File(&file)),
        ("Flattened", ProblemInput::Flattened(&flat)),
    ] {
        let prob = esm_problem(input, (0.0, 1.0), opts())
            .unwrap_or_else(|e| panic!("[{label}] esm_problem: {e}"));
        assert!(
            !prob.is_dynamic(),
            "[{label}] a state-free document is static"
        );
        assert_eq!(
            prob.observed_field_names(),
            vec!["MogiModel.ur".to_string(), "MogiModel.uz".to_string()],
            "[{label}] fields are reported component-qualified",
        );
        assert!(
            (scalar(&prob, "MogiModel.ur") - ur).abs() < 1e-12,
            "[{label}] ur"
        );
        assert!(
            (scalar(&prob, "MogiModel.uz") - uz).abs() < 1e-12,
            "[{label}] uz"
        );
        // One component, so the bare spelling resolves too.
        assert_eq!(scalar(&prob, "ur"), scalar(&prob, "MogiModel.ur"));
        assert_eq!(scalar(&prob, "uz"), scalar(&prob, "MogiModel.uz"));
    }
}

/// `solve` still refuses a state-free document; the fields are the way in.
#[test]
fn solve_refuses_but_the_fields_are_readable() {
    let prob = esm_problem(
        ProblemInput::Path(Path::new(ONE_COMPONENT)),
        (0.0, 1.0),
        opts(),
    )
    .expect("esm_problem");
    match earthsci_ast::solve(&prob, &Default::default()) {
        Err(SimulateError::NotDynamic { .. }) => {}
        other => panic!("expected NotDynamic, got {other:?}"),
    }
    assert!(observed_field(&prob, "MogiModel.ur").is_ok());
}

/// A caller's `p` binding reaches the static evaluation, so the fields describe
/// the problem that was built rather than the document's declared defaults.
#[test]
fn parameter_overrides_reach_the_static_fields() {
    let mut o = opts();
    o.p = HashMap::from([("MogiModel.dV".to_string(), 2.0e6)]);
    let prob = esm_problem(ProblemInput::Path(Path::new(ONE_COMPONENT)), (0.0, 1.0), o)
        .expect("esm_problem");
    let (ur, _) = mogi_oracle();
    // `ur` is linear in `dV`, so doubling the source volume doubles it.
    assert!((scalar(&prob, "MogiModel.ur") - 2.0 * ur).abs() < 1e-12);
}

/// On a TWO-component document the qualified spellings resolve and every bare
/// one is refused — including `ur`, which has no twin. The gate is the
/// component count, not ambiguity.
#[test]
fn a_bare_name_is_refused_on_a_multi_component_document() {
    let prob = esm_problem(
        ProblemInput::Path(Path::new(TWO_COMPONENT)),
        (0.0, 1.0),
        opts(),
    )
    .expect("esm_problem");

    assert_eq!(
        prob.observed_field_names(),
        vec![
            "Sites.North.u".to_string(),
            "Sites.North.ur".to_string(),
            "Sites.South.u".to_string(),
        ]
    );
    assert_eq!(scalar(&prob, "Sites.North.u"), 6.0);
    assert_eq!(scalar(&prob, "Sites.North.ur"), 3.0);
    assert_eq!(scalar(&prob, "Sites.South.u"), 35.0);

    // Shared local name: refused, and both candidates named.
    let e = observed_field(&prob, "u")
        .expect_err("bare 'u' must be refused")
        .to_string();
    assert!(e.contains("bare name"), "{e}");
    assert!(
        e.contains("Sites.North.u") && e.contains("Sites.South.u"),
        "{e}"
    );

    // UNIQUE local name: still refused. The component count is the gate.
    let e = observed_field(&prob, "ur")
        .expect_err("bare 'ur' must be refused")
        .to_string();
    assert!(e.contains("bare name"), "{e}");
    assert!(e.contains("Sites.North.ur"), "{e}");

    // A partial qualification is not a spelling of anything.
    assert!(observed_field(&prob, "North.u").is_err());
    // Neither is a name the document does not declare.
    assert!(observed_field(&prob, "nope").is_err());
}

/// `qualify` must be idempotent. When the caller names the model explicitly,
/// construction carries that name AND the static evaluation's keys are already
/// flattened under it — qualifying a second time would produce
/// `MogiModel.MogiModel.ur` and make every spelling fail.
#[test]
fn an_explicit_model_name_does_not_double_qualify() {
    let mut o = opts();
    o.model_name = Some("MogiModel".to_string());
    let prob = esm_problem(ProblemInput::Path(Path::new(ONE_COMPONENT)), (0.0, 1.0), o)
        .expect("esm_problem");
    assert_eq!(
        prob.observed_field_names(),
        vec!["MogiModel.ur".to_string(), "MogiModel.uz".to_string()]
    );
    let (ur, _) = mogi_oracle();
    assert!((scalar(&prob, "MogiModel.ur") - ur).abs() < 1e-12);
    assert!((scalar(&prob, "ur") - ur).abs() < 1e-12);
}
