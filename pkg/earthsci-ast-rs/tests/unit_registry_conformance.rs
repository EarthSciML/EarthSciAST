//! Manifest-driven adapter for `tests/conformance/unit_registry`.
//!
//! The Rust side of that directory's contract: esm-spec §4.8, asserted at the
//! level a document actually meets it — a unit STRING at a time. Every other
//! units fixture in the corpus is a `.esm` document and can only pin the verdict
//! a whole FILE gets; this one pins whether each string resolves, the DIMENSION
//! it resolves to, and its SCALE.
//!
//! Scale is not decoration: `short_ton` and `tonne` have the same dimension and
//! differ only in scale, so a dimension-only check would pass a binding that
//! defined the short ton as 1000 kg and mis-scaled every US emissions inventory
//! by 10%.
//!
//! The Julia mirror is `pkg/EarthSciAST.jl/test/unit_registry_conformance_test.jl`,
//! the Python one `pkg/earthsci-ast-py/tests/test_unit_registry_conformance.py`
//! — same golden.

use std::fs;
use std::path::{Path, PathBuf};

use earthsci_ast::units::parse_unit;
use serde_json::Value;

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_str(
        &fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display())),
    )
    .unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn golden() -> Value {
    let tests = tests_dir();
    let manifest = read_json(&tests.join("conformance/unit_registry/manifest.json"));
    let rel = manifest["golden"].as_str().expect("manifest names a golden");
    read_json(&tests.join(rel))
}

fn entries<'a>(g: &'a Value, key: &str) -> &'a Vec<Value> {
    let list = g[key].as_array().unwrap_or_else(|| panic!("golden has no `{key}` array"));
    assert!(!list.is_empty(), "golden's `{key}` list is empty");
    list
}

#[test]
fn unit_registry_conformance_accepts() {
    let g = golden();
    for e in entries(&g, "accept") {
        let s = e["units"].as_str().unwrap();
        let canon = e["canonical"].as_str().unwrap();
        let got = parse_unit(s).unwrap_or_else(|err| panic!("{s:?} must resolve: {err}"));
        let want = parse_unit(canon).unwrap_or_else(|err| panic!("{canon:?} must resolve: {err}"));
        assert!(
            got.same_dimensions(&want),
            "{s:?} must have the dimension of {canon:?}"
        );
        // `null` is exactly the affine units, whose offset §4.8.1 deliberately
        // does not model — their pure multiplicative factor is not a physically
        // meaningful conversion.
        if let Some(expected) = e["scale_to_canonical"].as_f64() {
            let factor = got.scale() / want.scale();
            assert!(
                (factor - expected).abs() <= 1e-12 * expected.abs(),
                "{s:?} -> {canon:?}: scale {factor} != pinned {expected}"
            );
        }
    }
}

#[test]
fn unit_registry_conformance_rejects() {
    let g = golden();
    for e in entries(&g, "reject") {
        let s = e["units"].as_str().unwrap();
        assert!(
            parse_unit(s).is_err(),
            "{s:?} must NOT resolve — {}",
            e["why"].as_str().unwrap_or("")
        );
    }
}

/// The one rejection whose REASON an author cannot guess from the string: it
/// LOOKS like a rational exponent and the §4.8.2 grammar reads it as a division
/// by a number. The message is pinned here, and nowhere else, for that reason.
#[test]
fn unit_registry_conformance_rejects_scaling_factors_and_says_so() {
    let g = golden();
    for e in entries(&g, "reject_scaling_factor") {
        let s = e["units"].as_str().unwrap();
        let err = parse_unit(s).expect_err(&format!("{s:?} must NOT resolve"));
        let msg = err.to_string();
        assert!(
            msg.contains("scaling factor"),
            "{s:?}: diagnostic must name the scaling factor, got {msg:?}"
        );
    }
}
