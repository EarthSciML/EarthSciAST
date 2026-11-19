//! Cross-binding conformance for the esm-spec §6.3.1 classification API.
//!
//! esm 1.0.0 declares two variable types and DERIVES everything finer. Five
//! bindings deriving it independently is five chances to disagree, so
//! `tests/conformance/classification/` pins one answer: per model node, the
//! three unknown sets (which partition the unknowns), the four parameter sets
//! (which partition the parameters), and the derived `system_kind`.
//!
//! This driver asserts the Rust derivation reproduces that golden — the same
//! golden the Julia / TypeScript / Python / Go siblings assert against, so
//! golden agreement *is* cross-binding agreement.
//!
//! Two properties beyond equality are checked here because a golden cannot
//! state them: that each pair of sets really PARTITIONS (disjoint and total,
//! [`Classification::assert_partitions`]), and that classification is per MODEL
//! NODE — a subsystem's equations classify the subsystem's variables, which is
//! what `subsystem_scope` discriminates.

use earthsci_ast::Classification;
use earthsci_ast::HasSubsystems;
use earthsci_ast::{EsmFile, Model, SystemKind, flatten};
use serde_json::Value;

use crate::common;

fn load_json(rel: &str) -> Value {
    let path = common::repo_root().join(rel);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

/// Every model node of a document, keyed by its DOT-PATH from the root, so a
/// subsystem is `Parent.Child` — the golden's own key convention.
///
/// Classification never crosses a subsystem boundary: that is the point of
/// keying by node.
fn model_nodes(doc: &Value) -> Vec<(String, Model)> {
    fn walk(prefix: &str, model: &Model, out: &mut Vec<(String, Model)>) {
        let mut subs: Vec<(&String, &Model)> = model.inline_subsystems().collect();
        subs.sort_by(|a, b| a.0.cmp(b.0));
        for (name, sub) in subs {
            walk(&format!("{prefix}.{name}"), sub, out);
        }
        out.push((prefix.to_string(), model.clone()));
    }

    let mut out = Vec::new();
    let Some(models) = doc.get("models").and_then(Value::as_object) else {
        return out;
    };
    let mut names: Vec<&String> = models.keys().collect();
    names.sort();
    for name in names {
        let Ok(model) = serde_json::from_value::<Model>(models[name].clone()) else {
            continue;
        };
        walk(name, &model, &mut out);
    }
    out
}

fn want_list(golden: &Value, key: &str) -> Vec<String> {
    golden[key]
        .as_array()
        .unwrap_or_else(|| panic!("golden has no `{key}` array"))
        .iter()
        .map(|v| v.as_str().expect("golden name is a string").to_string())
        .collect()
}

#[test]
fn rust_classification_matches_golden() {
    run_classification_category("classification");
}

/// The INDEXED LHS spelling of an arrayed definition (esm-spec §6.3.1), which
/// the `classification` category cannot state: it carries no `index` or
/// `aggregate` LHS at all, which is why four of the five bindings drifted onto
/// the same wrong answer independently. Rust was the one that did not — its
/// `lhs_form` peels both the `index` and the `aggregate` shell — so this is the
/// regression pin for that, not a fix. Same golden shape, same driver.
/// See `tests/conformance/classification_indexed_lhs/README.md`.
#[test]
fn rust_classification_indexed_lhs_matches_golden() {
    run_classification_category("classification_indexed_lhs");
}

fn run_classification_category(category: &str) {
    let manifest = load_json(&format!("tests/conformance/{category}/manifest.json"));
    let fixtures = manifest["fixtures"].as_array().expect("fixtures array");
    assert!(!fixtures.is_empty());
    assert!(
        manifest["bindings_required"]
            .as_array()
            .expect("bindings_required")
            .iter()
            .any(|b| b.as_str() == Some("rust")),
        "the {category} manifest no longer lists rust in bindings_required"
    );

    for fx in fixtures {
        let id = fx["id"].as_str().expect("fixture id");
        let doc = load_json(&format!(
            "tests/conformance/{category}/{}",
            fx["fixture"].as_str().expect("fixture path")
        ));
        let golden = load_json(&format!(
            "tests/conformance/{category}/{}",
            fx["golden"].as_str().expect("golden path")
        ));
        let golden_models = golden["models"].as_object().expect("golden models");

        // Which flattened MAP an unknown lands in is a different question from
        // which §6.3.1 set classifies it, and esm-libraries-spec §4.7.5 step 4
        // answers it with two maps that are NOT a partition: an arrayed
        // observed is in `observed_variables` (an equation defines it) AND in
        // `state_variables` (it materializes into a buffer the solver
        // allocates). Optional — only a golden whose fixture makes the
        // distinction interesting carries it. Issue #270.
        if let Some(buckets) = golden.get("flatten_buckets") {
            let file: EsmFile = serde_json::from_value(doc.clone()).expect("fixture parses");
            let flat = flatten(&file).expect("fixture flattens");
            for (label, got) in [
                (
                    "state_variables",
                    flat.state_variables
                        .keys()
                        .cloned()
                        .collect::<Vec<String>>(),
                ),
                (
                    "observed_variables",
                    flat.observed_variables
                        .keys()
                        .cloned()
                        .collect::<Vec<String>>(),
                ),
                (
                    "algebraic_variables",
                    flat.algebraic_variables
                        .keys()
                        .cloned()
                        .collect::<Vec<String>>(),
                ),
            ] {
                assert_eq!(got, want_list(buckets, label), "[{id}] flatten {label}");
            }
        }

        let nodes = model_nodes(&doc);
        let got_keys: Vec<&str> = nodes.iter().map(|(k, _)| k.as_str()).collect();
        let mut want_keys: Vec<&str> = golden_models.keys().map(String::as_str).collect();
        want_keys.sort();
        let mut got_sorted = got_keys.clone();
        got_sorted.sort();
        assert_eq!(got_sorted, want_keys, "[{id}] model node set");

        for (key, model) in &nodes {
            let want = &golden_models[key];
            let class = Classification::of(model);

            // The seven sets, exactly.
            for (name, got) in [
                ("ode_states", &class.ode_states),
                ("observed_unknowns", &class.observed_unknowns),
                ("algebraic_unknowns", &class.algebraic_unknowns),
                ("brownian_parameters", &class.brownian_parameters),
                ("discrete_parameters", &class.discrete_parameters),
                ("sampled_parameters", &class.sampled_parameters),
                ("constant_parameters", &class.constant_parameters),
            ] {
                assert_eq!(*got, want_list(want, name), "[{id}] {key}.{name}");
            }

            // `is_ode_state` is the membership test for the first set, so it
            // must agree with it on EVERY declared variable — not just on the
            // ones that happen to be states.
            for var in model.variables.keys() {
                assert_eq!(
                    class.is_ode_state(var),
                    class.ode_states.iter().any(|s| s == var),
                    "[{id}] {key}: is_ode_state disagrees with ode_states on {var}"
                );
            }

            // The derived system kind, and the mismatch rule: a PRESENT
            // `system_kind` field never overrides the derivation, it only has
            // to agree with it.
            let want_kind = want["system_kind"].as_str().expect("golden system_kind");
            assert_eq!(
                class.system_kind.as_str(),
                want_kind,
                "[{id}] {key}.system_kind"
            );
            // A declared `"pde"` (deprecated at esm 2.4.0) counts as absent.
            let declared = declared_kind(model);
            assert_eq!(
                want["declared_system_kind"],
                declared.map_or(Value::Null, |k| Value::String(k.to_string())),
                "[{id}] {key}.declared_system_kind"
            );
            if let Some(declared) = declared {
                assert_eq!(
                    declared, want_kind,
                    "[{id}] {key}: a declared system_kind that disagrees with the \
                     derivation is `system_kind_mismatch`, and no golden carries one"
                );
            }

            // Both partition laws, which no golden can state.
            class
                .assert_partitions(model)
                .unwrap_or_else(|e| panic!("[{id}] {key}: {e}"));
        }
    }
}

/// The `system_kind` table is ORDERED and first-match-wins (`sde`, then
/// `nonlinear`, then `ode`), and since esm 2.4.0 has no `pde` row: spatial
/// derivatives do not affect the kind. `system_kind_pde` (name kept) pins
/// that; this test says out loud what each of its models is there to catch.
#[test]
fn system_kind_order_is_first_match_wins() {
    let doc = load_json("tests/conformance/classification/fixtures/system_kind_pde.esm");
    let nodes: std::collections::HashMap<String, Model> = model_nodes(&doc).into_iter().collect();

    let kind = |name: &str| Classification::of(&nodes[name]).system_kind;

    // No time-derivative equation: nonlinear, spatial derivatives or not.
    assert_eq!(kind("SteadyState"), SystemKind::Nonlinear);
    // A Brownian parameter wins first.
    assert_eq!(kind("StochasticSpatial"), SystemKind::Sde);
    // A spatial `D` (alone or nested) does not make a model anything but `ode`.
    assert_eq!(kind("Transient"), SystemKind::Ode);
    assert_eq!(kind("SugarOps"), SystemKind::Ode);
    // A declared `"pde"` is ignored: the derived kind, no declared kind, no
    // mismatch.
    assert_eq!(kind("DeclaredPde"), SystemKind::Ode);
    assert_eq!(nodes["DeclaredPde"].system_kind.as_deref(), Some("pde"));
    assert_eq!(declared_kind(&nodes["DeclaredPde"]), None);
}

/// The declared `system_kind` the comparison uses: a declared `"pde"`
/// (deprecated at esm 2.4.0, warned `deprecated_system_kind` at load) counts as
/// absent and never mismatches.
fn declared_kind(model: &Model) -> Option<&str> {
    model.system_kind.as_deref().filter(|k| *k != "pde")
}
