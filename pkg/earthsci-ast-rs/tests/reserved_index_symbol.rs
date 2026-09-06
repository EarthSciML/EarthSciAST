//! An `aggregate` binder that SHADOWS a globally-scoped name is rejected at
//! load — diagnostic `reserved_index_symbol`.
//!
//! `t` (the document's independent variable, esm-spec §11.3) and `_var` (the
//! §6.4 operator placeholder) are implicitly declared in every model's
//! expression scope (§4.9.1), and this crate resolves both by NAME before it
//! consults the loop bindings — `simulate_array/eval.rs::lookup_variable` and
//! `lookup_array_ref`, `vectorized.rs::eval_vec_variable`, `tape/lower.rs`,
//! `units.rs`, `simulate/resolve.rs`, and the scoping walkers
//! `flatten.rs::namespace_expr_scoped` / `scope_template_body`. A `ranges` key
//! or `output_idx` entry spelled with one of them therefore declares a loop its
//! own body can never address.
//!
//! What that cost before the rejection existed is the reason it is a HARD error
//! and not a lint: the collision is invisible at build time (a `join.on` key
//! column resolves against the node's own `ranges`, so `join.rs::resolve_side`
//! is perfectly happy) and only misfires at eval time. The two shapes it took
//! are both pinned below as fixtures — a data-column key column returned **0**
//! from a `sum_product` that should have been 2, with no error and no warning
//! and a document that validated; a `const`-array key column raised the
//! unrelated-looking `E_TREEWALK_CONSTARRAY_OOB: const array 'left_key' index 0
//! out of range 1..3`, because the lowered `code_lookup` addressed the constant
//! key table with the simulation TIME. CONFORMANCE_SPEC §5.5.8 already forbids
//! exactly that silence for a key column that resolves to nothing; this applies
//! the same rule one step earlier, at the binder.
//!
//! The control fixture is the same aggregate over the same data with the first
//! range symbol spelled `k`, and it still answers 2 — which is what makes the
//! rejection specific to the collision rather than to the join.
//!
//! Reported by the downstream EPA MOVES port as finding F4.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SolveOptions, load_path, load_string, run_pde_tests_with_base_dir};
use serde_json::{Value, json};

mod common;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/reserved_index_symbol")
        .join(name)
}

/// The load error for a fixture that must not load.
fn rejection(name: &str) -> String {
    let path = fixture(name);
    match load_path(&path) {
        Ok(_) => panic!("{name} loaded, but a binder shadowing `t` must be rejected"),
        Err(e) => e.to_string(),
    }
}

fn assert_reserved(message: &str, symbol: &str, what: &str) {
    assert!(
        message.contains("[reserved_index_symbol]"),
        "{what}: expected the `reserved_index_symbol` diagnostic, got: {message}"
    );
    assert!(
        message.contains(&format!("binds '{symbol}' as an index symbol")),
        "{what}: the diagnostic must name the offending symbol '{symbol}', got: {message}"
    );
}

/// A `ranges` key named `t` on an aggregate whose `join.on` key columns are
/// DATA COLUMNS. This is the silent shape: it used to load, validate, and
/// answer 0.
#[test]
fn a_ranges_key_named_t_is_rejected_at_load() {
    let msg = rejection("loop_symbol_named_t_data_column.esm");
    assert_reserved(&msg, "t", "data-column key columns");
    assert!(
        msg.contains("/models/SymbolCollision/equations/2/rhs"),
        "the diagnostic must point at the offending node, got: {msg}"
    );
    assert!(
        msg.contains("a `ranges` key"),
        "the diagnostic must name the field that binds it, got: {msg}"
    );
}

/// The same collision with `const`-array key columns — the shape that used to
/// surface as `E_TREEWALK_CONSTARRAY_OOB`, a diagnostic about the wrong thing
/// entirely. Both paths are one rejection now, so neither is reachable.
#[test]
fn the_const_array_key_column_variant_is_rejected_too() {
    let msg = rejection("loop_symbol_named_t_const_array.esm");
    assert_reserved(&msg, "t", "const-array key columns");
    assert!(
        !msg.contains("E_TREEWALK_CONSTARRAY_OOB"),
        "the const-array path must report the BINDER, not an out-of-range gather: {msg}"
    );
}

/// The control: identical aggregate, first range symbol spelled `k`. It loads
/// and the `sum_product` counts the two matching pairs — the answer the `t`
/// spelling silently turned into 0.
#[test]
fn the_control_spelling_loads_and_answers_two() {
    let path = fixture("loop_symbol_named_k_control.esm");
    let file = load_path(&path).expect("control loads");
    let results = run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());
    assert_eq!(results.len(), 1, "one inline assertion: {results:?}");
    let r = &results[0];
    assert!(
        r.passed,
        "the control must still count the two matching pairs: actual={:?} expected={} — {}",
        r.actual, r.expected, r.message
    );
    assert_eq!(
        r.actual,
        Some(2.0),
        "renaming a bound index must not change a result"
    );
}

/// A minimal single-aggregate document binding `sym`, optionally under a
/// renamed independent variable.
fn doc_binding(sym: &str, independent: Option<&str>) -> Value {
    let mut doc = json!({
        "esm": "1.0.0",
        "metadata": { "name": "BinderProbe" },
        "index_sets": { "rows": { "kind": "interval", "size": 3 } },
        "models": {
            "M": {
                "variables": { "total": { "type": "unknown" } },
                "equations": [
                    { "lhs": "total",
                      "rhs": { "op": "aggregate", "args": [], "semiring": "sum_product",
                               "output_idx": [],
                               "ranges": { sym: { "from": "rows" } },
                               "expr": 1.0 } }
                ]
            }
        }
    });
    if let Some(name) = independent {
        doc["domain"] = json!({ "independent_variable": name });
    }
    doc
}

/// The rule is not hardcoded to the literal `t`: it follows
/// `domain.independent_variable`. A document that RENAMES it moves the
/// rejection onto the new name — and frees `t`, which is then an ordinary
/// symbol like any other.
#[test]
fn a_renamed_independent_variable_moves_the_rejection() {
    let renamed = doc_binding("s", Some("s"));
    let msg = match load_string(&renamed.to_string()) {
        Ok(_) => panic!("a binder named `s` must be rejected when `s` is the independent variable"),
        Err(e) => e.to_string(),
    };
    assert_reserved(&msg, "s", "renamed independent variable");

    load_string(&doc_binding("t", Some("s")).to_string())
        .expect("`t` is an ordinary symbol in a document whose independent variable is `s`");
}

/// `_var` is the other globally-scoped name the scoping walkers resolve ahead
/// of the loop bindings (`flatten.rs::VAR_PLACEHOLDER`), and it is rejected on
/// `output_idx` as well as on `ranges` — the two fields that BIND.
#[test]
fn the_operator_placeholder_is_rejected_on_both_binding_fields() {
    let by_range = match load_string(&doc_binding("_var", None).to_string()) {
        Ok(_) => panic!("a `ranges` key named `_var` must be rejected"),
        Err(e) => e.to_string(),
    };
    assert_reserved(&by_range, "_var", "`_var` as a ranges key");

    let mut doc = doc_binding("i", None);
    doc["models"]["M"]["equations"][0]["rhs"]["output_idx"] = json!(["_var"]);
    doc["models"]["M"]["variables"]["total"] = json!({ "type": "unknown", "shape": ["rows"] });
    let by_output = match load_string(&doc.to_string()) {
        Ok(_) => panic!("an `output_idx` entry named `_var` must be rejected"),
        Err(e) => e.to_string(),
    };
    assert_reserved(&by_output, "_var", "`_var` as an output_idx entry");
    assert!(
        by_output.contains("an `output_idx` entry"),
        "the diagnostic must name the binding field, got: {by_output}"
    );
}

/// An `integral`'s `var` is deliberately NOT covered: `∫f dt` binds the
/// independent variable because it is integrating over it — the authored form
/// esm-spec §4.2 documents, not a shadow of it. A rejection that swept `var` in
/// with the aggregate binders would refuse a legitimate PIDE.
#[test]
fn an_integral_over_the_independent_variable_still_loads() {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": { "name": "TimeIntegral" },
        "models": {
            "M": {
                "variables": {
                    "u": { "type": "unknown", "units": "1", "default": 1.0 },
                    "cumu": { "type": "unknown", "units": "1" }
                },
                "equations": [
                    { "lhs": { "op": "D", "args": ["u"], "wrt": "t" },
                      "rhs": { "op": "-", "args": ["u"] } },
                    { "lhs": "cumu",
                      "rhs": { "op": "integral", "args": ["u"], "var": "t",
                               "lower": 0.0, "upper": "t" } }
                ]
            }
        }
    });
    load_string(&doc.to_string()).expect("a time integral binds `t` legitimately");
}

/// Every document in the shared cross-binding corpus still loads: the rule
/// rejects a collision no conforming fixture has, which is what makes it safe
/// to apply at load rather than behind a flag.
#[test]
fn the_shared_corpus_carries_no_reserved_binder() {
    let root = common::repo_tests_dir();
    let mut checked = 0usize;
    for entry in walk(&root) {
        let Ok(text) = std::fs::read_to_string(&entry) else {
            continue;
        };
        let Ok(doc) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        checked += 1;
        assert!(
            !binds_reserved(&doc),
            "{} binds a reserved index symbol",
            entry.display()
        );
    }
    assert!(checked > 100, "expected the corpus, found {checked} files");
}

/// Every `.esm` under `dir`, recursively.
fn walk(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else if path.extension().is_some_and(|e| e == "esm") {
            out.push(path);
        }
    }
    out
}

/// A purely local restatement of the rule, so this scan cannot pass merely
/// because the implementation stopped looking.
fn binds_reserved(doc: &Value) -> bool {
    let independent = doc
        .get("domain")
        .and_then(|d| d.get("independent_variable"))
        .and_then(Value::as_str)
        .unwrap_or("t");
    fn go(v: &Value, independent: &str) -> bool {
        match v {
            Value::Object(obj) => {
                let binds = obj
                    .get("ranges")
                    .and_then(Value::as_object)
                    .is_some_and(|r| r.keys().any(|k| k == independent || k == "_var"))
                    || obj
                        .get("output_idx")
                        .and_then(Value::as_array)
                        .is_some_and(|a| {
                            a.iter()
                                .filter_map(Value::as_str)
                                .any(|s| s == independent || s == "_var")
                        });
                binds || obj.values().any(|c| go(c, independent))
            }
            Value::Array(arr) => arr.iter().any(|c| go(c, independent)),
            _ => false,
        }
    }
    go(doc, independent)
}
