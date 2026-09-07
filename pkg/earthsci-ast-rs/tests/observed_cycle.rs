//! A dependency cycle among observeds is named, at `validate`, by the names on
//! it — esm-spec §4.9.6, issue #181.
//!
//! The reported failure was two defects stacked. `esm validate` accepted a
//! document whose observeds were `wscale → gamfac → hpbl → wscale`, because
//! nothing checked the observed dependency graph; then `esm test` failed with
//! `E_TREEWALK_UNBOUND_NAME: 'in_pbl'` — naming a *fourth* observed, declared,
//! defined and referenced perfectly well, that merely happened to be the first
//! name the materialization walk tried to resolve once the cycle stalled it.
//! Bisecting from that message took an afternoon.
//!
//! So there are two things to hold here, and they are independent:
//!
//! 1. **`validate` rejects, naming the cycle.** The graph is a function of the
//!    equations alone — no shapes, no values, no solver — so there is no reason
//!    for a build to be the first thing that notices.
//! 2. **A DECLARED name is never reported as unbound.** Even where a cycle is
//!    not caught up front, the evaluator must not make a claim about the
//!    document ("bound by NOTHING in scope") that it is not in a position to
//!    make. That is `E_TREEWALK_UNRESOLVED_ORDER`, and it is a separate fix:
//!    the misattribution outlives this particular cause.

use earthsci_ast::{StructuralErrorCode, load_path, load_string, validate};
use serde_json::json;

fn repo_root() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The `(message, cycle)` of the one `observed_cycle` error a document
/// produces, at the expected path. Panics with the full finding list when the
/// document is accepted or reports something else, so a regression says which.
fn observed_cycle_finding(doc: &str, path: &str) -> (String, Vec<String>) {
    let file = load_string(doc).expect("fixture is schema-valid and must load");
    let result = validate(&file);
    let hits: Vec<_> = result
        .structural_errors
        .iter()
        .filter(|e| matches!(e.code, StructuralErrorCode::ObservedCycle))
        .collect();
    assert_eq!(
        hits.len(),
        1,
        "expected exactly one observed_cycle; got {:?}",
        result
            .structural_errors
            .iter()
            .map(|e| (e.code.to_string(), e.path.clone()))
            .collect::<Vec<_>>()
    );
    let hit = hits[0];
    assert_eq!(hit.path, path, "observed_cycle pins at the model");
    let cycle: Vec<String> =
        serde_json::from_value(hit.details["cycle"].clone()).expect("details.cycle is a name list");
    (hit.message.clone(), cycle)
}

// ---------------------------------------------------------------------------
// 1. `validate` rejects, and names the cycle
// ---------------------------------------------------------------------------

/// The shared corpus fixture — three ARRAY observeds over one index set reading
/// each other ELEMENTWISE, which is the shape the issue says is the easiest
/// minimal repro and the shape a scalar-only detector would miss.
#[test]
fn the_shared_fixture_is_rejected_and_names_the_cycle() {
    let path = repo_root().join("tests/invalid/observed_cycle_array_elementwise.esm");
    let doc = std::fs::read_to_string(&path).expect("fixture exists");
    let (message, cycle) = observed_cycle_finding(&doc, "/models/YSU");

    // Naming the cycle is the whole value of this diagnostic: "there is a
    // cycle" would not have saved the reporter's afternoon.
    for name in ["gamfac", "hpbl", "wscale"] {
        assert!(
            message.contains(name),
            "the message must name every observed on the cycle; '{name}' missing from: {message}"
        );
    }
    assert_eq!(
        cycle,
        vec!["gamfac", "hpbl", "wscale", "gamfac"],
        "the cycle is a PATH — traversal order, entry node repeated to close it"
    );

    // The regression, stated positively: `in_pbl` reads `hpbl` and is therefore
    // downstream of the cycle, but it is not ON one. The old diagnostic named
    // exactly this variable.
    assert!(
        !cycle.iter().any(|n| n == "in_pbl"),
        "in_pbl is not on the cycle and must not be reported as if it were: {cycle:?}"
    );
}

/// A two-variable SCALAR cycle. The array case is what the issue reported, but
/// the rule is about the observed graph, not about shapes.
#[test]
fn a_scalar_two_variable_cycle_is_rejected() {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "ScalarCycle"},
        "models": {"M": {
            "variables": {
                "a": {"type": "unknown", "units": "1"},
                "b": {"type": "unknown", "units": "1"}
            },
            "equations": [
                {"lhs": "a", "rhs": {"op": "+", "args": ["b", 1.0]}},
                {"lhs": "b", "rhs": {"op": "+", "args": ["a", 1.0]}}
            ]
        }}
    })
    .to_string();
    let (_, cycle) = observed_cycle_finding(&doc, "/models/M");
    assert_eq!(cycle, vec!["a", "b", "a"]);
}

/// A scalar self-reference is a cycle of length one, and CONFORMANCE_SPEC
/// §5.19.5 is explicit that it must stay one: `x ~ x + 1` has no axis to fold
/// along and can never be a recurrence, so the recurrence exemption — which is
/// gated on CANDIDACY — does not reach it. Exempting every self-edge instead is
/// the mirror-image mis-gating that section names, and it loses this error.
#[test]
fn a_scalar_self_reference_is_a_cycle_of_length_one() {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "SelfScalar"},
        "models": {"M": {
            "variables": {"x": {"type": "unknown", "units": "1"}},
            "equations": [{"lhs": "x", "rhs": {"op": "+", "args": ["x", 1.0]}}]
        }}
    })
    .to_string();
    let (_, cycle) = observed_cycle_finding(&doc, "/models/M");
    assert_eq!(cycle, vec!["x", "x"]);
}

/// The other half of the candidacy gate: a WELL-FOUNDED causal self-read is an
/// ordering *within* one array (esm-spec §4.3.1.1), not a dependency between
/// two variables, so its self-edge is dropped and the document validates clean.
/// A detector that flagged it would make the recurrence construct unusable.
#[test]
fn a_recurrence_candidate_self_edge_is_not_a_cycle() {
    let path = repo_root().join("tests/valid/recurrence_causal_self_reference.esm");
    let file = load_path(&path).expect("the recurrence fixture loads");
    let result = validate(&file);
    let cycles: Vec<_> = result
        .structural_errors
        .iter()
        .filter(|e| matches!(e.code, StructuralErrorCode::ObservedCycle))
        .map(|e| (e.path.clone(), e.message.clone()))
        .collect();
    assert!(
        cycles.is_empty(),
        "a well-founded recurrence must not be reported as an observed cycle: {cycles:?}"
    );
}

/// The corpus guard, stated where a reader will find it: no document this repo
/// ships as VALID may acquire an `observed_cycle`. A new hard error that
/// rejects working files is a worse defect than the one it fixes.
#[test]
fn no_valid_fixture_acquires_an_observed_cycle() {
    let mut checked = 0usize;
    let mut offenders: Vec<String> = Vec::new();
    for dir in ["tests/valid", "lib"] {
        let root = repo_root().join(dir);
        let mut stack = vec![root];
        while let Some(d) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&d) else {
                continue;
            };
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    stack.push(p);
                    continue;
                }
                if p.extension().and_then(|e| e.to_str()) != Some("esm") {
                    continue;
                }
                let Ok(file) = load_path(&p) else {
                    // Fixtures that need a `base_path` anchor (subsystem refs,
                    // template imports) are covered by their own suites; a load
                    // failure here is not this test's business.
                    continue;
                };
                checked += 1;
                for e in validate(&file).structural_errors {
                    if matches!(e.code, StructuralErrorCode::ObservedCycle) {
                        offenders.push(format!("{}: {}", p.display(), e.message));
                    }
                }
            }
        }
    }
    assert!(checked > 50, "the sweep must actually read the corpus");
    assert!(
        offenders.is_empty(),
        "valid documents rejected by the new check: {offenders:#?}"
    );
}

// ---------------------------------------------------------------------------
// 2. The build path, and the misattributed unbound name
// ---------------------------------------------------------------------------

/// The build must refuse the cycle by name too. This is the backstop for a
/// document compiled without being validated first — and it is what the array
/// runtime's ordering sweep used to do INSTEAD of proceeding: it appended the
/// unorderable rules in declaration order, "so the build still proceeds", and
/// what proceeded was a materialization that read a value that did not exist.
#[test]
fn the_build_refuses_the_cycle_and_names_it() {
    let path = repo_root().join("tests/invalid/observed_cycle_array_elementwise.esm");
    let file = load_path(&path).expect("fixture loads");
    let err = earthsci_ast::simulate_array::ArrayCompiled::from_file(&file)
        .err()
        .expect("a cyclic observed graph has no build");
    let msg = err.to_string();
    assert!(
        msg.contains("observed_cycle"),
        "the build error carries the code: {msg}"
    );
    for name in ["gamfac", "hpbl", "wscale"] {
        assert!(msg.contains(name), "the build names the cycle: {msg}");
    }
    assert!(
        !msg.contains("in_pbl"),
        "and does not name the bystander: {msg}"
    );
}
