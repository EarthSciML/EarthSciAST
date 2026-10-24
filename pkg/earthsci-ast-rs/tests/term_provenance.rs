//! Per-term provenance through flatten (esm-libraries-spec §4.7.5,
//! CONFORMANCE_SPEC §5.48, issue #539).
//!
//! The flatten corpus (`flatten_conformance.rs`) pins every equation's rendered
//! contribution list. This file checks what a rendering cannot:
//!
//! * the INVARIANT, by evaluation: `body(eq)` evaluates bit for bit to the
//!   left-fold sum of the contributions' values, at sampled non-default states;
//! * the systems-order pair: the same contributions and origins in both
//!   argument orders, in `rhs_A + rhs_B` order;
//! * every contribution flatten produces has a non-empty, deduplicated origin
//!   list, and the list is parallel to `equations`;
//! * the serde form of [`TermOrigin`] is the untagged corpus form.

use earthsci_ast::{
    Contribution, Expr, FlattenedSystem, TermOrigin, evaluate, flatten, free_variables, load_path,
    to_ascii,
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn fixtures_dir() -> PathBuf {
    tests_dir().join("conformance/term_provenance/fixtures")
}

fn fixture_names() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(fixtures_dir())
        .expect("term_provenance fixtures directory")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".esm"))
        .collect();
    names.sort();
    names
}

fn flatten_path(path: &Path) -> FlattenedSystem {
    let file = load_path(path).unwrap_or_else(|e| panic!("{}: load: {e}", path.display()));
    let (flat, _warnings) = earthsci_ast::capture_coupling_diagnostics(|| flatten(&file));
    flat.unwrap_or_else(|e| panic!("{}: flatten: {e:?}", path.display()))
}

fn corpus_fixtures() -> Vec<(String, PathBuf)> {
    let raw = std::fs::read_to_string(tests_dir().join("conformance/flatten/cases.json"))
        .expect("flatten corpus");
    let corpus: Value = serde_json::from_str(&raw).expect("corpus parses");
    corpus["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .map(|c| {
            (
                c["id"].as_str().unwrap().to_string(),
                tests_dir().join(c["fixture"].as_str().unwrap()),
            )
        })
        .collect()
}

// --- the invariant, by evaluation --------------------------------------------

/// Independent sampled states per equation. One state can sum to the same bits
/// in every association by chance; several make that vanishingly unlikely.
const SAMPLES: u64 = 8;

/// A deterministic, non-default value for `name` in sample `salt`, spread over
/// many decades so that summing in another association rounds differently.
fn sample(name: &str, salt: u64) -> f64 {
    // FNV-1a.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ salt.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    for b in name.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    let mantissa = 1.0 + (h % 100_003) as f64 / 100_003.0;
    let exponent = ((h >> 17) % 13) as i32 - 6;
    mantissa * 10f64.powi(exponent)
}

/// The body the contributions stand for: the right-hand side, or the `faq` body
/// when the pointwise lift wrapped the equation — recognised from the
/// LEFT-hand side the lift writes, `faq(D(index(<lifted state>, …)))`.
fn body<'a>(flat: &FlattenedSystem, lhs: &Expr, rhs: &'a Expr) -> &'a Expr {
    let lifted = match lhs {
        Expr::Operator(node) if node.op == "faq" => match node.expr.as_deref() {
            Some(Expr::Operator(d)) if d.op == "D" => match d.args.first() {
                Some(Expr::Operator(ix)) if ix.op == "index" => matches!(
                    ix.args.first(),
                    Some(Expr::Variable(name)) if flat.lifted_shapes.contains_key(name)
                ),
                _ => false,
            },
            _ => false,
        },
        _ => false,
    };
    match rhs {
        Expr::Operator(node) if lifted => node.expr.as_deref().expect("lifted faq has a body"),
        _ => rhs,
    }
}

/// `expr` with every `index(…)` node replaced by a scalar named after it, so a
/// lifted cell expression evaluates with the scalar evaluator. The same node
/// gets the same name on both sides of the comparison, so the arithmetic the
/// check is about — how the contributions are summed — is untouched.
fn scalarize(expr: &Expr) -> Expr {
    match expr {
        Expr::Operator(node) if node.op == "index" => {
            Expr::Variable(format!("<{}>", to_ascii(expr)))
        }
        Expr::Operator(node) => Expr::operator(node.map_children(&mut |c| scalarize(c))),
        _ => expr.clone(),
    }
}

/// `Some(discriminating)` when the equation was evaluated, `None` when the
/// scalar evaluator cannot evaluate it (an undiscretized spatial operator).
/// `discriminating` says whether some sampled state sums the contributions to
/// different bits in the right-nested association, i.e. whether the check
/// could tell the two orders apart.
fn check_invariant(
    case: &str,
    flat: &FlattenedSystem,
    lhs: &Expr,
    rhs: &Expr,
    contributions: &[Contribution],
) -> Option<bool> {
    let body = scalarize(body(flat, lhs, rhs));
    let parts: Vec<Expr> = contributions.iter().map(|c| scalarize(&c.expr)).collect();
    let mut names: HashSet<String> = free_variables(&body);
    for p in &parts {
        names.extend(free_variables(p));
    }
    let mut discriminating = false;
    for salt in 0..SAMPLES {
        let mut bindings: HashMap<String, f64> = names
            .iter()
            .filter(|n| n.as_str() != "t")
            .map(|n| (n.clone(), sample(n, salt)))
            .collect();
        bindings.insert("t".to_string(), 0.75);
        let got = evaluate(&body, &bindings).ok()?;
        let values: Vec<f64> = parts
            .iter()
            .map(|p| evaluate(p, &bindings).ok())
            .collect::<Option<_>>()?;
        let fold = values[1..].iter().fold(values[0], |acc, v| acc + v);
        assert_eq!(
            got.to_bits(),
            fold.to_bits(),
            "{case}: {} — body {got:?} is not the left fold {fold:?} of {values:?}",
            to_ascii(lhs)
        );
        let right = values[..values.len() - 1]
            .iter()
            .rev()
            .fold(values[values.len() - 1], |acc, v| v + acc);
        discriminating |= right.to_bits() != fold.to_bits();
    }
    Some(discriminating)
}

#[test]
fn body_is_the_left_fold_of_the_contributions() {
    for fixture in fixture_names() {
        let flat = flatten_path(&fixtures_dir().join(&fixture));
        for (eq, contributions) in flat.equations.iter().zip(&flat.equation_contributions) {
            let result = check_invariant(&fixture, &flat, &eq.lhs, &eq.rhs, contributions);
            // Only `grad` without a discretization is out of the evaluator's
            // reach.
            if fixture != "placeholder_expansion.esm" {
                assert!(
                    result.is_some(),
                    "{fixture}: {} could not be evaluated",
                    to_ascii(&eq.lhs)
                );
            }
            // With three or more contributions the check must be able to see
            // the order.
            if result.is_some() && contributions.len() >= 3 {
                assert_eq!(
                    result,
                    Some(true),
                    "{fixture}: {} cannot tell sum orders apart",
                    to_ascii(&eq.lhs)
                );
            }
        }
    }
}

#[test]
fn corpus_equations_keep_the_invariant() {
    for (id, path) in corpus_fixtures() {
        let flat = flatten_path(&path);
        for (eq, contributions) in flat.equations.iter().zip(&flat.equation_contributions) {
            check_invariant(&id, &flat, &eq.lhs, &eq.rhs, contributions);
        }
    }
}

// --- the shape of the field --------------------------------------------------

#[test]
fn every_contribution_has_an_author() {
    for (id, path) in corpus_fixtures() {
        let flat = flatten_path(&path);
        assert_eq!(
            flat.equation_contributions.len(),
            flat.equations.len(),
            "{id}: one contribution list per equation"
        );
        for (eq, contributions) in flat.equations.iter().zip(&flat.equation_contributions) {
            assert!(!contributions.is_empty(), "{id}: {}", to_ascii(&eq.lhs));
            for c in contributions {
                assert!(
                    !c.origins.is_empty(),
                    "{id}: {} has an unattributed term",
                    to_ascii(&eq.lhs)
                );
                let unique: HashSet<&TermOrigin> = c.origins.iter().collect();
                assert_eq!(unique.len(), c.origins.len(), "{id}: duplicate origin");
            }
        }
    }
}

#[test]
fn systems_order_pair_has_the_same_contributions() {
    let rendered = |name: &str| -> Vec<(String, Vec<(String, Value)>)> {
        let flat = flatten_path(&fixtures_dir().join(name));
        flat.equations
            .iter()
            .zip(&flat.equation_contributions)
            .map(|(eq, contributions)| {
                (
                    to_ascii(&eq.lhs),
                    contributions
                        .iter()
                        .map(|c| {
                            (
                                to_ascii(&c.expr),
                                serde_json::to_value(&c.origins).expect("origins serialize"),
                            )
                        })
                        .collect(),
                )
            })
            .collect()
    };
    let ab = rendered("systems_order_ab.esm");
    let ba = rendered("systems_order_ba.esm");
    // The pair differs in which system is `systems[0]`, so the merged
    // equation's contributions come in `rhs_A + rhs_B` order in each. Compare
    // them as sets of (expression, origins) per equation, and check that the
    // origins never name a coupling entry: a merge adds none.
    let as_set = |eqs: &[(String, Vec<(String, Value)>)]| -> Vec<(String, Vec<(String, Value)>)> {
        let mut out: Vec<_> = eqs
            .iter()
            .map(|(lhs, cs)| {
                let mut cs = cs.clone();
                cs.sort_by(|a, b| a.0.cmp(&b.0));
                (lhs.clone(), cs)
            })
            .collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    };
    assert_eq!(as_set(&ab), as_set(&ba));
    for (_, cs) in ab.iter().chain(&ba) {
        for (_, origins) in cs {
            assert!(
                !origins.to_string().contains("coupling"),
                "a merge added a coupling origin: {origins}"
            );
        }
    }
}

#[test]
fn non_vacuity_keeps_identical_expressions_apart() {
    let flat = flatten_path(&fixtures_dir().join("non_vacuity.esm"));
    let found = flat.equation_contributions.iter().any(|cs| {
        cs.iter().enumerate().any(|(i, a)| {
            cs[i + 1..]
                .iter()
                .any(|b| a.expr == b.expr && a.origins != b.origins)
        })
    });
    assert!(
        found,
        "two structurally identical contributions with different origins must stay two"
    );
}

#[test]
fn term_origin_serializes_untagged() {
    let component = TermOrigin::Component {
        component: "Atmosphere.Chemistry".to_string(),
    };
    let coupling = TermOrigin::Coupling { coupling: 3 };
    assert_eq!(
        serde_json::to_value(&component).unwrap(),
        serde_json::json!({"component": "Atmosphere.Chemistry"})
    );
    assert_eq!(
        serde_json::to_value(&coupling).unwrap(),
        serde_json::json!({"coupling": 3})
    );
    let back: Vec<TermOrigin> =
        serde_json::from_value(serde_json::json!([{"component": "A"}, {"coupling": 0}]))
            .expect("deserializes");
    assert_eq!(
        back,
        vec![
            TermOrigin::Component {
                component: "A".to_string()
            },
            TermOrigin::Coupling { coupling: 0 }
        ]
    );
    // The field round-trips through the serde form of the whole system.
    let flat = flatten_path(&tests_dir().join("coupling/chained_operator_compose.esm"));
    let json = serde_json::to_value(&flat).expect("serializes");
    let again: FlattenedSystem = serde_json::from_value(json).expect("deserializes");
    assert_eq!(again.equation_contributions, flat.equation_contributions);
}
