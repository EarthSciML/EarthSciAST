//! Cross-language pin for the EXACT TREE a reaction system lowers to.
//!
//! Drives the shared, hand-written corpus at
//! `tests/conformance/reactions/lowering_form.json`: every binding's
//! `derive_odes` and `flatten` must produce the same expressions for a reaction
//! network, compared as JSON with integer and non-integer numbers kept apart
//! (esm-libraries-spec §4.6.2). Derived documents copy flattened terms verbatim,
//! so a binding that lowers a reaction to a different tree writes different
//! bytes.
//!
//! The comparison runs on the crate's own serde form of [`Expr`], which is what
//! a derived document carries. That form narrows an integral float to an
//! integer, so it cannot show a stray `-1.0` by itself; [`integral_floats`]
//! checks the tree before it is written.

use earthsci_ast::{Expr, TermOrigin, derive_odes, flatten, load_document};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct DerivedEquation {
    lhs: Value,
    rhs: Value,
}

#[derive(Debug, Deserialize)]
struct FlattenedEntry {
    species: String,
    contribution: Value,
}

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    system: String,
    lifted: bool,
    derive_odes: Vec<DerivedEquation>,
    flatten: Vec<FlattenedEntry>,
    document: Value,
}

#[derive(Debug, Deserialize)]
struct Corpus {
    cases: Vec<Case>,
}

fn corpus() -> Corpus {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/reactions/lowering_form.json")
        .canonicalize()
        .unwrap_or_else(|e| panic!("locating the lowering-form corpus: {e}"));
    let json = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", PathBuf::from(&path).display()));
    serde_json::from_str(&json).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()))
}

/// Every integral float literal in `expr` — CONFORMANCE_SPEC §5.5.3.1 rule 3
/// makes each of them an integer literal.
fn integral_floats(expr: &Expr) -> Vec<f64> {
    match expr {
        Expr::Number(n) if n.is_finite() && n.fract() == 0.0 => vec![*n],
        Expr::Operator(node) => node.args.iter().flat_map(integral_floats).collect(),
        _ => vec![],
    }
}

/// `serde_json::Value` equality keeps `-1` and `-1.0` apart, which is the
/// comparison the corpus asks for.
fn check(actual: &Expr, expected: &Value, case: &str, at: &str) {
    let floats = integral_floats(actual);
    assert!(
        floats.is_empty(),
        "{case} {at}: integral float literal(s) {floats:?} in {actual:?}"
    );
    let written = serde_json::to_value(actual).expect("serialize expression");
    assert_eq!(&written, expected, "{case} {at}");
}

/// The species a flattened left-hand side differentiates: `D(x, t)`, or the
/// lift's `faq` over `D(index(x, ...), t)`.
fn species_of(lhs: &Value) -> String {
    let derivative = if lhs["op"] == "faq" {
        let d = &lhs["expr"];
        assert_eq!(d["args"][0]["op"], "index", "{lhs}");
        d
    } else {
        lhs
    };
    assert_eq!(derivative["op"], "D", "{lhs}");
    let target = &derivative["args"][0];
    let name = if target.is_object() {
        &target["args"][0]
    } else {
        target
    };
    name.as_str()
        .unwrap_or_else(|| panic!("no species in {lhs}"))
        .to_string()
}

#[test]
fn corpus_was_actually_read() {
    assert!(
        corpus().cases.len() >= 3,
        "expected at least 3 corpus cases"
    );
}

#[test]
fn derive_odes_tree() {
    for case in corpus().cases {
        let file = load_document(&case.document).expect("load document");
        let system = &file.reaction_systems.as_ref().expect("reaction systems")[&case.system];
        let model = derive_odes(system).expect("derive_odes");
        assert_eq!(
            model.equations.len(),
            case.derive_odes.len(),
            "{}",
            case.name
        );
        for (k, (eq, exp)) in model.equations.iter().zip(&case.derive_odes).enumerate() {
            check(
                &eq.lhs,
                &exp.lhs,
                &case.name,
                &format!("derive_odes[{k}].lhs"),
            );
            check(
                &eq.rhs,
                &exp.rhs,
                &case.name,
                &format!("derive_odes[{k}].rhs"),
            );
        }
    }
}

#[test]
fn flatten_tree() {
    for case in corpus().cases {
        let file = load_document(&case.document).expect("load document");
        let flat = flatten(&file).expect("flatten");
        let origin = vec![TermOrigin::Component {
            component: case.system.clone(),
        }];
        let mut selected = vec![];
        for (eq, contributions) in flat.equations.iter().zip(&flat.equation_contributions) {
            let mine: Vec<_> = contributions
                .iter()
                .filter(|c| c.origins == origin)
                .collect();
            if !mine.is_empty() {
                assert_eq!(
                    mine.len(),
                    1,
                    "{}: two contributions from one origin",
                    case.name
                );
                selected.push((eq, contributions, mine[0]));
            }
        }
        assert_eq!(selected.len(), case.flatten.len(), "{}", case.name);
        for (k, ((eq, contributions, contribution), exp)) in
            selected.into_iter().zip(&case.flatten).enumerate()
        {
            let lhs = serde_json::to_value(&eq.lhs).expect("serialize lhs");
            assert_eq!(species_of(&lhs), exp.species, "{} flatten[{k}]", case.name);
            check(
                &contribution.expr,
                &exp.contribution,
                &case.name,
                &format!("flatten[{k}].contribution"),
            );
            if !case.lifted {
                assert_eq!(contributions.len(), 1, "{} flatten[{k}]", case.name);
                check(
                    &eq.rhs,
                    &exp.contribution,
                    &case.name,
                    &format!("flatten[{k}].rhs"),
                );
                assert_eq!(
                    lhs,
                    json!({"op": "D", "args": [exp.species], "wrt": "t"}),
                    "{}",
                    case.name
                );
            }
        }
    }
}
