//! Cross-language `flatten` conformance for the Rust binding.
//!
//! Drives `tests/conformance/flatten/cases.json` — the shared corpus generated
//! by `scripts/generate-flatten-corpus.py` from the Python ORACLE — end to end
//! and compares the WHOLE canonical `FlattenedSystem` field set of
//! esm-libraries-spec §4.7.5 step 4, **in order**.
//!
//! Rust was the binding with no in-tree test against a shared corpus, and that
//! is exactly how a 19-of-50 printer divergence survived here undetected until
//! `display_conformance.rs` closed the same gap for `display`. Order is what
//! this test exists to pin: a parameter vector is positional, so a binding that
//! sorts lexicographically (which Rust's flatten did until the commit that
//! added this file) or iterates a hash map produces a `p` vector whose entries
//! mean different things than the oracle's — a silent, numerically-wrong result
//! rather than an error. Membership-only comparison would not see it.
//!
//! All 19 cases are compared, every recorded field included. `element_type` /
//! `array_type` were briefly exempt: the oracle DROPPED them at load, so the
//! corpus recorded `null` for fixtures that plainly declare them, and Rust —
//! which preserves them, as step 4's "the file's `domain` section, unchanged"
//! requires — was the one that disagreed. The oracle was fixed rather than Rust
//! degraded to match. [`domain_element_type_survives_flatten`] keeps a
//! corpus-independent check so the pass-through stays pinned regardless.
//!
//! Four of the cases (`advanced_coupling`, `full_coupled`,
//! `complete_coupling_types`, `coupled_atmospheric_system`) carry UNDISCRETIZED
//! `grad`/`laplacian`. Rust used to refuse them with `unlowered_operator`; it
//! now flattens them and derives their spatial `independent_variables` per
//! esm-libraries-spec §4.7.6, so they are ordinary compared cases. That list is
//! the one field whose order is lexicographic rather than document order — the
//! axes are discovered by scanning, not declared — and the comparison is an
//! ordered one, so a binding that emitted them in scan order would fail here.

use earthsci_ast::classification::SystemKind;
use earthsci_ast::flatten::{FlattenedSystem, flatten};
use earthsci_ast::parse::load_path;
use earthsci_ast::to_ascii;
use earthsci_ast::types::{ModelVariable, ParameterUpdateSpec};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// Repo-root `tests/` directory — the corpus's own path root.
fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn corpus() -> Value {
    let raw = std::fs::read_to_string(tests_dir().join("conformance/flatten/cases.json"))
        .expect("shared flatten corpus is readable");
    serde_json::from_str(&raw).expect("shared flatten corpus parses")
}

// ---------------------------------------------------------------------------
// Recording: the corpus's language-neutral shape, produced from Rust
// ---------------------------------------------------------------------------

/// The `update.kind` tags of a variable, in order, `[]` when it has none.
fn update_kinds(var: &ModelVariable) -> Vec<String> {
    match &var.update {
        None => Vec::new(),
        Some(ParameterUpdateSpec::Single(rule)) => vec![rule.kind().to_string()],
        Some(ParameterUpdateSpec::Several(rules)) => {
            rules.iter().map(|r| r.kind().to_string()).collect()
        }
    }
}

/// The owning component of a namespaced name — the corpus's `source_system`.
/// Namespacing is `<component>.<var>` (a subsystem-local var keeps further
/// dots), so the FIRST segment is the component.
fn owner(name: &str) -> &str {
    name.split_once('.').map(|(o, _)| o).unwrap_or(name)
}

/// The corpus's DERIVED `role` tag for one entry of one map.
///
/// Derived here rather than carried on Rust's `ModelVariable`, which models the
/// two DECLARED esm 1.0.0 types (`unknown` / `parameter`) and no third. The
/// mapping is total and was read off the corpus itself: bucket membership
/// decides `state` / `observed` / `parameter`, and a solved-for unknown owned by
/// a `reaction_systems` component is a `species`.
fn role(bucket: &str, name: &str, reaction_systems: &BTreeSet<String>) -> String {
    match bucket {
        "observed_variables" => "observed".to_string(),
        "parameters" => "parameter".to_string(),
        _ if reaction_systems.contains(owner(name)) => "species".to_string(),
        _ => "state".to_string(),
    }
}

/// One flattened variable in the corpus's serialization.
fn variable_record(
    bucket: &str,
    name: &str,
    var: &ModelVariable,
    reaction_systems: &BTreeSet<String>,
) -> Value {
    serde_json::json!({
        "name": name,
        "role": role(bucket, name, reaction_systems),
        "units": var.units,
        "default": var.default,
        // THE CORPUS CANNOT DISTINGUISH A DECLARED-EMPTY SHAPE FROM AN ABSENT
        // ONE. The generator writes `list(var.shape) if var.shape else None`,
        // so `"shape": []` — which three `parameter_cadences` parameters
        // actually declare — records as `null`, indistinguishable from a
        // parameter that declares no `shape` at all. Both mean "scalar", so
        // nothing is lost today; but a future rule that had to tell the two
        // apart could not be pinned by this corpus without changing the
        // generator first.
        //
        // Rust keeps the declared `Some([])` on the variable — only this RECORD
        // normalizes, exactly as the generator does, so the comparison is
        // like-for-like rather than a degradation of the flattened form.
        "shape": var.shape.as_ref().filter(|s| !s.is_empty()),
        "update_kinds": update_kinds(var),
        "distribution_kind": var.distribution.as_ref().map(|d| d.kind()),
        "source_system": owner(name),
    })
}

fn variable_map(
    bucket: &str,
    m: &indexmap::IndexMap<String, ModelVariable>,
    reaction_systems: &BTreeSet<String>,
) -> Value {
    Value::Array(
        m.iter()
            .map(|(n, v)| variable_record(bucket, n, v, reaction_systems))
            .collect(),
    )
}

fn names(m: &indexmap::IndexMap<String, ModelVariable>) -> Value {
    Value::Array(m.keys().map(|k| Value::String(k.clone())).collect())
}

fn keys<V>(m: &indexmap::IndexMap<String, V>) -> Value {
    Value::Array(m.keys().map(|k| Value::String(k.clone())).collect())
}

/// `lifted_shapes` as the corpus records it: a plain object keyed by state
/// name. The generator sorts its keys, and a JSON object compares by key, so
/// this map is the one place the corpus does NOT pin order.
fn lifted_shapes(flat: &FlattenedSystem) -> Value {
    let mut out = serde_json::Map::new();
    let mut sorted: Vec<_> = flat.lifted_shapes.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    for (k, v) in sorted {
        out.insert(k.clone(), Value::from(v.clone()));
    }
    Value::Object(out)
}

fn kind_str(k: SystemKind) -> &'static str {
    k.as_str()
}

/// The whole step-4 field set of `flat`, in the corpus's own serialization.
///
/// Every field the generator's `_record()` pins is produced here, EXCEPT the
/// two it cannot be asked for:
///   * `equations[].source_system` — Rust's `Equation` carries `lhs`/`rhs` and
///     no provenance tag, so the equation comparison is `lhs`/`rhs` only.
///   * `metadata.operator_applies` / `metadata.callbacks` / the exact
///     `metadata.coupling_rules` PROSE — Rust records one flat
///     `coupling_rules_applied` list of human-readable descriptions with its own
///     wording. `metadata.source_systems`, the one metadata field that is a
///     contract rather than a debugging aid, IS compared.
fn record(flat: &FlattenedSystem, reaction_systems: &BTreeSet<String>) -> Value {
    serde_json::json!({
        "system_kind": kind_str(flat.system_kind()),
        "independent_variables": flat.independent_variables,
        "state_variables": variable_map("state_variables", &flat.state_variables, reaction_systems),
        "parameters": variable_map("parameters", &flat.parameters, reaction_systems),
        "observed_variables":
            variable_map("observed_variables", &flat.observed_variables, reaction_systems),
        "algebraic_variables": names(&flat.algebraic_variables),
        "brownian_parameters": names(&flat.brownian_parameters),
        "discrete_parameters": names(&flat.discrete_parameters),
        "equation_count": flat.equations.len(),
        "equations": flat
            .equations
            .iter()
            .map(|e| serde_json::json!({"lhs": to_ascii(&e.lhs), "rhs": to_ascii(&e.rhs)}))
            .collect::<Vec<_>>(),
        "continuous_events": flat
            .continuous_events
            .iter()
            .map(|e| serde_json::json!({
                "name": e.name,
                "conditions": e.conditions.iter().map(to_ascii).collect::<Vec<_>>(),
                "affects": e
                    .affects
                    .iter()
                    .map(|a| format!("{} = {}", a.lhs, to_ascii(&a.rhs)))
                    .collect::<Vec<_>>(),
            }))
            .collect::<Vec<_>>(),
        "discrete_events": flat
            .discrete_events
            .iter()
            .map(|e| serde_json::json!({"name": e.name}))
            .collect::<Vec<_>>(),
        "source_systems": flat.metadata.source_systems,
        "index_sets": keys(&flat.index_sets),
        "function_tables": keys(&flat.function_tables),
        "template_registry": keys(&flat.template_registry),
        "field_ics": flat
            .field_ics
            .iter()
            .map(|(s, e)| serde_json::json!({"state": s, "expr": to_ascii(e)}))
            .collect::<Vec<_>>(),
        "loader_fields": flat
            .loader_fields
            .iter()
            .map(|lf| serde_json::json!({
                "name": lf.name,
                "owner": lf.owner,
                "source": lf.source,
                "file_variable": lf.file_variable,
                "cadence": lf.cadence,
            }))
            .collect::<Vec<_>>(),
        "lifted_shapes": lifted_shapes(flat),
    })
}

/// The same shape, read out of one corpus case, so the two are compared as
/// like-for-like JSON and a diff names the field.
fn expected(case: &Value) -> Value {
    let strip_source = |eqs: &Value| -> Vec<Value> {
        eqs.as_array()
            .unwrap()
            .iter()
            .map(|e| serde_json::json!({"lhs": e["lhs"], "rhs": e["rhs"]}))
            .collect()
    };
    serde_json::json!({
        "system_kind": case["system_kind"],
        "independent_variables": case["independent_variables"],
        "state_variables": case["state_variables"],
        "parameters": case["parameters"],
        "observed_variables": case["observed_variables"],
        "algebraic_variables": case["algebraic_variables"],
        "brownian_parameters": case["brownian_parameters"],
        "discrete_parameters": case["discrete_parameters"],
        "equation_count": case["equation_count"],
        "equations": strip_source(&case["equations"]),
        "continuous_events": case["continuous_events"],
        "discrete_events": case["discrete_events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| serde_json::json!({"name": e["name"]}))
            .collect::<Vec<_>>(),
        "source_systems": case["metadata"]["source_systems"],
        "index_sets": case["index_sets"],
        "function_tables": case["function_tables"],
        "template_registry": case["template_registry"],
        "field_ics": case["field_ics"],
        "loader_fields": case["loader_fields"],
        "lifted_shapes": case["lifted_shapes"],
    })
}

/// Numeric equality that does not care whether the oracle emitted `40` or
/// `40.0` — JSON has one number type and Python's `json` renders an int-valued
/// float as an int. Everything else compares structurally.
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(x), Some(y)) => x == y,
            _ => x == y,
        },
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| json_eq(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|other| json_eq(v, other)))
        }
        _ => a == b,
    }
}

/// Walk two records together and report every FIELD that differs, by path.
fn diffs(path: &str, got: &Value, want: &Value, out: &mut Vec<String>) {
    if json_eq(got, want) {
        return;
    }
    match (got, want) {
        (Value::Object(g), Value::Object(w)) => {
            let mut ks: BTreeSet<&String> = g.keys().collect();
            ks.extend(w.keys());
            for k in ks {
                let null = Value::Null;
                diffs(
                    &format!("{path}.{k}"),
                    g.get(k).unwrap_or(&null),
                    w.get(k).unwrap_or(&null),
                    out,
                );
            }
        }
        (Value::Array(g), Value::Array(w)) if g.len() == w.len() => {
            for (i, (a, b)) in g.iter().zip(w).enumerate() {
                diffs(&format!("{path}[{i}]"), a, b, out);
            }
        }
        _ => out.push(format!(
            "{path}:\n      rust   = {got}\n      oracle = {want}"
        )),
    }
}

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------

/// Every corpus case, compared field-for-field INCLUDING ORDER.
#[test]
fn flatten_matches_the_shared_corpus() {
    let corpus = corpus();
    let cases = corpus["cases"].as_array().expect("corpus has cases");
    assert!(
        cases.len() >= 19,
        "corpus shrank unexpectedly: {} cases",
        cases.len()
    );

    let mut failures: Vec<String> = Vec::new();
    let mut compared = 0usize;
    for case in cases {
        let id = case["id"].as_str().unwrap();
        let path = tests_dir().join(case["fixture"].as_str().unwrap());
        let file = match load_path(&path) {
            Ok(f) => f,
            Err(e) => {
                failures.push(format!("{id}: load failed: {e}"));
                continue;
            }
        };
        let reaction_systems: BTreeSet<String> = file
            .reaction_systems
            .as_ref()
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        let flat = match flatten(&file) {
            Ok(f) => f,
            Err(e) => {
                failures.push(format!("{id}: flatten failed: {e:?}"));
                continue;
            }
        };
        compared += 1;
        let mut case_diffs = Vec::new();
        diffs(
            id,
            &record(&flat, &reaction_systems),
            &expected(case),
            &mut case_diffs,
        );
        failures.extend(case_diffs);
    }

    assert_eq!(
        compared,
        cases.len(),
        "every corpus case must be flattened and compared"
    );
    assert!(
        failures.is_empty(),
        "{} field(s) diverge from the flatten oracle:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

/// The two documents the corpus records as REFUSALS must be refused here too.
///
/// The corpus names the oracle's exception CLASS; Rust's taxonomy is its own,
/// so what is pinned is the refusal itself and the STAGE it happens at — the
/// nonterminating-rewrite fixture is rejected at LOAD (esm-spec §9.6.3), which
/// is the corpus's own stated reason for recording it, and never reaches step 4.
#[test]
fn corpus_refusals_are_refused() {
    let corpus = corpus();
    let mut failures = Vec::new();
    for entry in corpus["refusals"].as_array().expect("corpus has refusals") {
        let rel = entry["fixture"].as_str().unwrap();
        let path = tests_dir().join(rel);
        match load_path(&path) {
            Err(_) => {} // refused at load — never reaches step 4
            Ok(file) => {
                if flatten(&file).is_ok() {
                    failures.push(format!(
                        "{rel}: flattened, but the oracle refuses it with {}",
                        entry["error"]
                    ));
                }
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// `domain.element_type` survives flatten — pinned independently of the corpus.
///
/// `domain` is, per esm-libraries-spec §4.7.5 step 4, "the file's `domain`
/// section, unchanged" — `element_type` (float precision) and `array_type`
/// (array backend, e.g. `"CuArray"`) included.
///
/// HISTORY. Both fields used to be `null` for EVERY corpus case: the Python
/// oracle's `Domain` dataclass modelled neither, so it dropped them at load
/// (and its round trip was lossy too). Rust preserved them and was right, so
/// the comparison below skipped them and this test asserted the gap from both
/// sides. The oracle was fixed on 2026-08-24 and the corpus regenerated, so
/// `domain_passthrough_matches_the_corpus` now compares BOTH fields for all 19
/// cases. What survives here is the corpus-INDEPENDENT half, so the
/// pass-through stays pinned even if no corpus fixture declares the field.
#[test]
fn domain_element_type_survives_flatten() {
    let path = tests_dir().join("valid/model_only.esm");
    let file = load_path(&path).expect("load");
    let flat = flatten(&file).expect("flatten");
    assert_eq!(
        flat.domain.as_ref().and_then(|d| d.element_type.as_deref()),
        Some("Float32"),
        "valid/model_only.esm declares Float32; it must survive flatten"
    );
}

/// The whole `domain` record, compared for every case.
///
/// `element_type` / `array_type` were once exempt here because the oracle could
/// not represent them (see `domain_element_type_survives_flatten`). That gap is
/// closed, so all of `independent_variable`, `element_type` and `array_type` are
/// compared, along with the presence/absence of the section itself.
#[test]
fn domain_passthrough_matches_the_corpus() {
    let corpus = corpus();
    let mut failures = Vec::new();
    for case in corpus["cases"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let file = load_path(tests_dir().join(case["fixture"].as_str().unwrap())).expect("load");
        let domain = flatten(&file)
            .unwrap_or_else(|e| panic!("{id}: flatten failed: {e:?}"))
            .domain;
        let want = &case["domain"];
        if want.is_null() {
            if domain.is_some() {
                failures.push(format!("{id}: oracle has no domain, Rust has one"));
            }
            continue;
        }
        let Some(domain) = domain else {
            failures.push(format!("{id}: oracle has a domain, Rust has none"));
            continue;
        };
        let got = domain.independent_variable.clone();
        let expect = want["independent_variable"].as_str().map(str::to_string);
        if got != expect {
            failures.push(format!(
                "{id}: domain.independent_variable rust={got:?} oracle={expect:?}"
            ));
        }
        let got_elem = domain.element_type.clone();
        let want_elem = want["element_type"].as_str().map(str::to_string);
        if got_elem != want_elem {
            failures.push(format!(
                "{id}: domain.element_type rust={got_elem:?} oracle={want_elem:?}"
            ));
        }
        let got_arr = domain.array_type.clone();
        let want_arr = want["array_type"].as_str().map(str::to_string);
        if got_arr != want_arr {
            failures.push(format!(
                "{id}: domain.array_type rust={got_arr:?} oracle={want_arr:?}"
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
