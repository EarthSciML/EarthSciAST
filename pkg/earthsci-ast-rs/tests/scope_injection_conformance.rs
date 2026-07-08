//! Conformance tests for esm-spec §9.7.10 — scope-directed template injection
//! (docs/content/rfcs/scoped-template-injection.md): the assembler- or
//! test-chosen discretization for a discretization-agnostic PDE leaf, via
//! `expression_template_imports` on a §4.7 subsystem-ref edge (form A), a §10
//! coupling entry (form B), or a §6.6/§6.7 test/example (form C). Mirrors the
//! Julia reference suite
//! (`EarthSciAST.jl/test/scope_injection_test.jl`), driving the shared
//! conformance fixtures under `tests/conformance/expression_templates/` against
//! the Julia-generated goldens.

use earthsci_ast::pde_inline_tests::ephemeral_injected_file;
use earthsci_ast::{load_path, save};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root from CARGO_MANIFEST_DIR")
        .to_path_buf()
}

fn conf(parts: &[&str]) -> PathBuf {
    let mut p = repo_root().join("tests/conformance/expression_templates");
    for part in parts {
        p = p.join(part);
    }
    p
}

fn golden(path: &Path) -> Value {
    let src = std::fs::read_to_string(path).expect("read golden");
    serde_json::from_str(&src).expect("parse golden")
}

/// Full typed load then re-serialize as a JSON `Value` — the exact contract the
/// Julia golden generator drives (`serialize_esm_file(load(fixture))`).
fn loaded_as_value(fixture: &Path) -> Value {
    let f = load_path(fixture).expect("typed load");
    let text = save(&f).expect("save");
    serde_json::from_str(&text).expect("parse serialized")
}

/// Number-tolerant structural equality. JSON numbers compare by `f64` value, so
/// the goldens' AST-position integral floats (narrowed to integers in Julia's
/// canonical-number form, e.g. `"rhs": 0`) match this binding's plain `f64`
/// re-emission (`0.0`), while structural float fields (`"default": 5.5`) still
/// compare exactly. Objects compare key-by-key (order-independent); arrays
/// element-by-element (order significant, as in an AST `args` list).
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(x), Some(y)) => x == y,
            _ => x == y,
        },
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, xv)| y.get(k).is_some_and(|yv| json_eq(xv, yv)))
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(xv, yv)| json_eq(xv, yv))
        }
        _ => a == b,
    }
}

fn assert_json_eq(actual: &Value, expected: &Value, ctx: &str) {
    assert!(
        json_eq(actual, expected),
        "{ctx}: serialized document does not match golden.\n--- actual ---\n{}\n--- golden ---\n{}",
        serde_json::to_string_pretty(actual).unwrap(),
        serde_json::to_string_pretty(expected).unwrap(),
    );
}

// ---------------------------------------------------------------------------
// Form A — subsystem-ref injection (§4.7 / §9.7.10)
// ---------------------------------------------------------------------------

#[test]
fn form_a_subsystem_ref_injection() {
    let fixture = conf(&["inject_subsystem_ref", "fixture.esm"]);
    let f = load_path(&fixture).expect("load form-A fixture");

    // The mounted, agnostic leaf's D(c, wrt: lon) is lowered by the injected
    // rule at the mount; the subsystem resolves to an inline component whose
    // rhs is `(-u) * makearray{...}`.
    let models = f.models.as_ref().expect("models");
    let runoff = &models["Assembly"]
        .subsystems
        .as_ref()
        .expect("Assembly subsystems")["Runoff"];
    assert_eq!(
        runoff["equations"][0]["rhs"]["args"][1]["op"], "makearray",
        "the injected central-difference rule must lower the leaf's lon-derivative"
    );

    // The injected library brought its grid into the importing registry, folded
    // at the edge bindings {NLON: 288, NLAT: 181}.
    let isets = f.index_sets.as_ref().expect("index_sets");
    assert_eq!(isets["lon"].size, Some(288));
    assert_eq!(isets["lat"].size, Some(181));

    // Round-trip golden: the resolved+lowered assembly; the injection field is
    // gone (form A does not survive parse → emit).
    assert_json_eq(
        &loaded_as_value(&fixture),
        &golden(&conf(&["inject_subsystem_ref", "expanded.esm"])),
        "form A expanded.esm",
    );

    // The leaf loads standalone with its D intact (agnostic; unlowered — the op
    // namespace is open, so this is not a load error).
    let leaf = loaded_as_value(&conf(&["inject_subsystem_ref", "leaf.esm"]));
    assert_eq!(
        leaf["models"]["Advection"]["equations"][0]["rhs"]["args"][1]["op"], "D",
        "the standalone agnostic leaf keeps its spatial D"
    );

    // Negative twin: mounting WITHOUT injection loads cleanly (the D survives —
    // the unlowered_operator gate is an evaluation-time concern, not a load
    // error), and the mounted subsystem still carries the un-lowered D.
    let ni = loaded_as_value(&conf(&["inject_subsystem_ref", "no_inject.esm"]));
    assert_eq!(
        ni["models"]["Assembly"]["subsystems"]["Runoff"]["equations"][0]["rhs"]["args"][1]["op"],
        "D",
        "without injection the mounted leaf's spatial D is not lowered"
    );
}

// ---------------------------------------------------------------------------
// Form B — coupling-entry injection (§10.8 / §9.7.10)
// ---------------------------------------------------------------------------

#[test]
fn form_b_coupling_entry_injection() {
    let fixture = conf(&["inject_coupling_entry", "fixture.esm"]);
    let f = load_path(&fixture).expect("load form-B fixture");

    // Advection is discretized by name; its lon-derivative is lowered.
    let models = f.models.as_ref().expect("models");
    let adv_rhs = serde_json::to_value(&models["Advection"].equations[0].rhs).unwrap();
    assert_eq!(
        adv_rhs["args"][1]["op"], "makearray",
        "the coupling-entry injection must lower Advection's lon-derivative"
    );
    assert_eq!(
        f.index_sets.as_ref().expect("index_sets")["lon"].size,
        Some(288)
    );

    // Emit (the 0-D partner) named no key and stays untouched (D(e)/dt intact).
    let emit_lhs = serde_json::to_value(&models["Emit"].equations[0].lhs).unwrap();
    assert_eq!(emit_lhs["op"], "D");

    // The injection map is consumed — form B does not survive parse → emit — and
    // the emitted document matches the golden.
    let ser = loaded_as_value(&fixture);
    assert!(
        ser["coupling"][0]
            .get("expression_template_imports")
            .is_none(),
        "the coupling-entry injection map must not survive parse → emit"
    );
    assert_json_eq(
        &ser,
        &golden(&conf(&["inject_coupling_entry", "expanded.esm"])),
        "form B expanded.esm",
    );
}

#[test]
fn form_b_target_unknown_diagnostic() {
    let e = load_path(conf(&["inject_coupling_entry", "neg_target_unknown.esm"]))
        .expect_err("unknown injection target must be rejected at load");
    assert!(
        e.to_string().contains("[template_inject_target_unknown]"),
        "got: {e}"
    );
}

#[test]
fn form_b_target_is_loader_diagnostic() {
    let e = load_path(conf(&["inject_coupling_entry", "neg_target_is_loader.esm"]))
        .expect_err("data-loader injection target must be rejected at load");
    assert!(
        e.to_string().contains("[template_inject_target_is_loader]"),
        "got: {e}"
    );
}

// ---------------------------------------------------------------------------
// Form C — test/example injection (§6.6.6 / §9.7.10)
// ---------------------------------------------------------------------------

#[test]
fn form_c_test_block_injection() {
    let fixture = conf(&["inject_test_block", "fixture.esm"]);
    let f = load_path(&fixture).expect("load form-C fixture");
    let models = f.models.as_ref().expect("models");
    let adv = &models["Advection"];

    // The enclosing component round-trips with its D INTACT (form C does not
    // lower it at load) and each test keeps its import field (survives emit).
    let adv_rhs = serde_json::to_value(&adv.equations[0].rhs).unwrap();
    assert_eq!(
        adv_rhs["args"][1]["op"], "D",
        "form C must NOT lower the enclosing component at load"
    );
    let tests = adv.tests.as_ref().expect("tests");
    assert_eq!(tests.len(), 2);
    assert!(
        tests
            .iter()
            .all(|t| !t.expression_template_imports.is_empty()),
        "each test keeps its injected discretization imports"
    );

    // Round-trip golden: the D-intact component + both tests' import fields.
    assert_json_eq(
        &loaded_as_value(&fixture),
        &golden(&conf(&["inject_test_block", "roundtrip.esm"])),
        "form C roundtrip.esm",
    );

    // One suite, many schemes: each test builds an INDEPENDENT ephemeral instance
    // with its own grid, with the D lowered in that build only — the persisted
    // component is never mutated.
    let base_dir = conf(&["inject_test_block"]);
    let e1 = ephemeral_injected_file(
        &f,
        Some(&fixture),
        "Advection",
        &tests[0].expression_template_imports,
        &base_dir,
    )
    .expect("ephemeral build for test 1");
    let e2 = ephemeral_injected_file(
        &f,
        Some(&fixture),
        "Advection",
        &tests[1].expression_template_imports,
        &base_dir,
    )
    .expect("ephemeral build for test 2");

    let e1v = serde_json::to_value(&e1).unwrap();
    let e2v = serde_json::to_value(&e2).unwrap();
    assert_eq!(
        e1v["models"]["Advection"]["equations"][0]["rhs"]["args"][1]["op"],
        "makearray"
    );
    assert_eq!(
        e2v["models"]["Advection"]["equations"][0]["rhs"]["args"][1]["op"],
        "makearray"
    );
    assert_eq!(
        e1.index_sets.as_ref().expect("e1 index_sets")["lon"].size,
        Some(288)
    );
    assert_eq!(
        e2.index_sets.as_ref().expect("e2 index_sets")["lon"].size,
        Some(144)
    );

    // The persisted file is untouched by the ephemeral builds.
    let adv_rhs_after =
        serde_json::to_value(&f.models.as_ref().unwrap()["Advection"].equations[0].rhs).unwrap();
    assert_eq!(adv_rhs_after["args"][1]["op"], "D");
}
