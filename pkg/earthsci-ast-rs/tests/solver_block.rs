//! The document-scoped `solver` block (esm-spec §2.2).

use earthsci_ast::{DEFAULT_ABSTOL, DEFAULT_RELTOL, load_string, resolve_tolerances, to_json};

fn doc(solver: &str, esm: &str) -> String {
    format!(
        r#"{{"esm":"{esm}","metadata":{{"name":"T"}},{solver}"models":{{"M":{{
             "variables":{{"x":{{"type":"unknown","units":"m","default":1.0}}}},
             "equations":[{{"lhs":{{"op":"D","args":["x"],"wrt":"t"}},
                            "rhs":{{"op":"neg","args":["x"]}}}}]}}}}}}"#
    )
}

#[test]
fn a_declared_block_round_trips_verbatim() {
    let f = load_string(&doc(r#""solver":{"stiffness":"high","abstol":1e-8},"#, "1.1.0")).unwrap();
    let s = f.solver.as_ref().expect("block parsed");
    assert_eq!(s.stiffness.as_deref(), Some("high"));
    assert_eq!(s.abstol, Some(1e-8));

    let out: serde_json::Value = serde_json::from_str(&to_json(&f).unwrap()).unwrap();
    assert_eq!(out["solver"]["stiffness"], "high");
    assert_eq!(out["solver"]["abstol"], 1e-8);
}

/// `{}` is legal — every other optional top-level container admits one — but it
/// means what omitting the block means, so it normalizes to absence AT LOAD.
///
/// Pinned here because `skip_serializing_if` does not give this for free: it is
/// per-FIELD, so a `Some(Solver)` with every field `None` would still emit its
/// enclosing `"solver": {}` while Python and Julia dropped it.
#[test]
fn an_empty_block_normalizes_to_absence() {
    let f = load_string(&doc(r#""solver":{},"#, "1.1.0")).expect("an empty block is LEGAL");
    assert!(f.solver.is_none(), "empty block must normalize away at load");

    let out: serde_json::Value = serde_json::from_str(&to_json(&f).unwrap()).unwrap();
    assert!(out.get("solver").is_none(), "and must not reach emit");
}

#[test]
fn the_block_is_rejected_below_esm_1_1_0() {
    let err = load_string(&doc(r#""solver":{"stiffness":"high"},"#, "1.0.0"))
        .expect_err("the block arrives at 1.1.0");
    assert!(
        err.to_string().contains("solver_version_too_old"),
        "want solver_version_too_old, got: {err}"
    );
}

/// esm-spec §2.2.2, most-specific first: caller, then document, then default —
/// resolved per field, so a document declaring only `reltol` leaves `abstol` on
/// the binding default.
#[test]
fn tolerances_resolve_most_specific_first() {
    let f = load_string(&doc(r#""solver":{"abstol":1e-8,"reltol":1e-6},"#, "1.1.0")).unwrap();
    let s = f.solver.clone();

    assert_eq!(
        resolve_tolerances(s.as_ref(), Some(1e-12), Some(1e-11)),
        (1e-12, 1e-11)
    );
    assert_eq!(resolve_tolerances(s.as_ref(), None, None), (1e-8, 1e-6));
    assert_eq!(
        resolve_tolerances(None, None, None),
        (DEFAULT_ABSTOL, DEFAULT_RELTOL)
    );

    let only_reltol = load_string(&doc(r#""solver":{"reltol":1e-9},"#, "1.1.0")).unwrap();
    assert_eq!(
        resolve_tolerances(only_reltol.solver.as_ref(), None, None),
        (DEFAULT_ABSTOL, 1e-9)
    );
}
