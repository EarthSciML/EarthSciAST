//! The template forms of the value-invention fixtures
//! (`tests/conformance/relational_templates/rewrites/manifest.json`) against
//! the expected values the manifest's `golden` files hold.
//!
//! Each rewrite writes value invention with lib/relational.esm templates
//! (`pair_key` / `edge_key` keys, per-component join columns, the loop index
//! for a set's own rank, `argmin_where` for a gated arg-witness). Built with
//! the case's caller data, under the interpreter and the strict native tape,
//! it must give the golden derived set's members (the template's integer keys,
//! decoded), the extents, the 1-based dense IDs, the arg-witness buffers, and
//! the right-hand side at the golden probe state, bit for bit. A
//! `value_invention_key_out_of_range` refusal names the column.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{
    Compiler, EsmProblem, InlineTestOptions, Key, LoadOptions, ProblemOptions, Rhs, esm_problem,
    load_string_with_options, materialize_value_invention, observed_field,
    run_inline_tests_with_options,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use crate::common;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn rewrites_dir() -> PathBuf {
    repo_root().join("tests/conformance/relational_templates/rewrites")
}

fn library() -> String {
    repo_root()
        .join("lib/relational.esm")
        .canonicalize()
        .expect("lib/relational.esm")
        .to_string_lossy()
        .into_owned()
}

fn manifest() -> Vec<Value> {
    let text = std::fs::read_to_string(rewrites_dir().join("manifest.json")).unwrap();
    let m: Value = serde_json::from_str(&text).unwrap();
    m["rewrites"].as_array().unwrap().clone()
}

/// The expected values of `entry` (its manifest `golden` file).
fn golden(entry: &Value) -> Value {
    let rel = entry["golden"]
        .as_str()
        .unwrap_or_else(|| panic!("{}: no golden", entry["id"]));
    read_doc(&rewrites_dir().join(rel))
}

/// A golden derived set's members as op-form keys.
fn golden_members(g: &Value) -> Vec<Key> {
    g["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            Key::Tuple(
                m.as_array()
                    .unwrap()
                    .iter()
                    .map(|c| Key::Int(c.as_i64().unwrap()))
                    .collect(),
            )
        })
        .collect()
}

fn golden_floats(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

/// A state element's golden key: `Model.var[1, 2]` -> `var[1,2]`.
fn elem_key(name: &str, model: &str) -> String {
    name.strip_prefix(&format!("{model}."))
        .unwrap_or(name)
        .replace(' ', "")
}

fn rewrite_path(entry: &Value) -> PathBuf {
    match entry.get("out").and_then(Value::as_str) {
        Some(out) => repo_root().join(out),
        None => rewrites_dir().join(format!("{}.esm", entry["id"].as_str().unwrap())),
    }
}

fn read_doc(path: &Path) -> Value {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    serde_json::from_str(&text).unwrap()
}

/// `path`'s document with only `model`, its template imports pointed at the
/// library by absolute path.
fn single_model(path: &Path, model: &str) -> Value {
    let mut doc = read_doc(path);
    let mut m = doc["models"][model].clone();
    if let Some(imports) = m
        .get_mut("expression_template_imports")
        .and_then(Value::as_array_mut)
    {
        for imp in imports {
            imp["ref"] = Value::String(library());
        }
    }
    doc["models"] = json!({ model: m });
    doc
}

/// An array from a (possibly nested) JSON list of numbers.
fn json_array(v: &Value) -> ArrayD<f64> {
    fn shape(v: &Value, out: &mut Vec<usize>) {
        if let Value::Array(a) = v {
            out.push(a.len());
            if let Some(first) = a.first() {
                shape(first, out);
            }
        }
    }
    fn flat(v: &Value, out: &mut Vec<f64>) {
        match v {
            Value::Array(a) => a.iter().for_each(|x| flat(x, out)),
            other => out.push(other.as_f64().expect("a number")),
        }
    }
    let mut s = Vec::new();
    shape(v, &mut s);
    let mut data = Vec::new();
    flat(v, &mut data);
    ArrayD::from_shape_vec(IxDyn(&s), data).unwrap()
}

fn case_arrays(case: &Value) -> HashMap<String, ArrayD<f64>> {
    case["const_arrays"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), json_array(v)))
        .collect()
}

fn case_params(case: &Value) -> HashMap<String, f64> {
    case["params"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_f64().unwrap()))
        .collect()
}

fn build(doc: &Value, case: &Value, compiler: Compiler) -> Result<EsmProblem, String> {
    build_with(doc, case, compiler, false)
}

/// [`build`], on the build pipeline when `pipeline` (a document with states
/// whose caller data are all shaped parameters takes the compile path, which
/// does not report the invented members).
fn build_with(
    doc: &Value,
    case: &Value,
    compiler: Compiler,
    pipeline: bool,
) -> Result<EsmProblem, String> {
    let mut doc = doc.clone();
    common::supply_state_defaults(&mut doc);
    let opts = ProblemOptions {
        compiler: Some(compiler),
        rhs: Rhs::Auto,
        const_arrays: case_arrays(case),
        p: case_params(case),
        build_pipeline: pipeline,
        ..Default::default()
    };
    esm_problem(&doc, (0.0, 1.0), opts).map_err(|e| e.to_string())
}

/// The raw model the value-invention engine reads: the model with the
/// document's index sets merged down.
fn engine_model(doc: &Value, model: &str) -> Value {
    let mut m = doc["models"][model].clone();
    m["index_sets"] = doc["index_sets"].clone();
    m
}

fn decode(k: i64, lo: &[i64], n_b: i64) -> Key {
    Key::Tuple(vec![
        Key::Int(k.div_euclid(n_b) + lo[0]),
        Key::Int(k.rem_euclid(n_b) + lo[1]),
    ])
}

/// `dy` at the golden probe state, keyed like it.
fn rhs_at_golden(
    prob: &EsmProblem,
    compiler: Compiler,
    label: &str,
    model: &str,
    g: &Value,
) -> HashMap<String, f64> {
    let names: Vec<String> = prob
        .debug_array_compiled()
        .expect("a right-hand side")
        .state_variable_names()
        .iter()
        .map(|n| elem_key(n, model))
        .collect();
    let gs = g["state"].as_object().unwrap();
    let mut sorted = names.clone();
    sorted.sort();
    let mut want: Vec<String> = gs.keys().cloned().collect();
    want.sort();
    assert_eq!(sorted, want, "{label}: state elements");
    let state: Vec<f64> = names.iter().map(|n| gs[n].as_f64().unwrap()).collect();
    let (_, dy) = rhs_at(prob, compiler, label, &state);
    names.into_iter().zip(dy).collect()
}

/// `dy` at `state`: the interpreter, or the strict native tape with no rule
/// off it.
fn rhs_at(
    prob: &EsmProblem,
    compiler: Compiler,
    label: &str,
    state: &[f64],
) -> (Vec<String>, Vec<f64>) {
    let comp = prob.debug_array_compiled().expect("a right-hand side");
    let names = comp.state_variable_names().to_vec();
    let state = state.to_vec();
    let dy = if compiler == Compiler::Native {
        let _precision = comp.debug_precision_env().enter();
        let params = comp.debug_resolve_params(prob.p());
        let mut dy = vec![0.0f64; state.len()];
        let mut scratch = comp
            .debug_new_scratch_taped()
            .unwrap_or_else(|e| panic!("{label}: strict native: {e}"));
        let mut stats = RhsStats::default();
        comp.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
        assert!(scratch.has_tape(), "{label}: the tape declined a rule");
        dy
    } else {
        comp.debug_eval_rhs(&state, 0.0, prob.p(), true).0
    };
    (names, dy)
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

/// `rank_of(x, members, n)` from lib/relational.esm for every member `x`.
fn rank_of_each(members: &[i64]) -> Vec<f64> {
    let mut variables = serde_json::Map::new();
    let mut equations = Vec::new();
    for (k, x) in members.iter().enumerate() {
        let name = format!("r{}", k + 1);
        variables.insert(name.clone(), json!({"type": "unknown", "units": "1"}));
        equations.push(json!({
            "lhs": name,
            "rhs": {"op": "apply_expression_template", "args": [], "name": "rank_of",
                    "bindings": {"x": x,
                                 "members": {"op": "const", "args": [], "value": members},
                                 "n": members.len()}}
        }));
    }
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "rank_of_probe", "authors": ["test"]},
        "models": {"M": {
            "expression_template_imports": [{"ref": library()}],
            "variables": variables,
            "equations": equations
        }}
    });
    let prob = esm_problem(&doc, (0.0, 1.0), ProblemOptions::default())
        .unwrap_or_else(|e| panic!("rank_of probe: {e}"));
    (1..=members.len())
        .map(|k| {
            let f = observed_field(&prob, &format!("r{k}")).unwrap();
            assert_eq!(f.len(), 1, "rank_of probe r{k}: {f:?}");
            f.iter().copied().next().unwrap()
        })
        .collect()
}

fn check_case(entry: &Value, idx: usize, case: &Value, label: &str) {
    let cmp = &entry["compare"];
    let model = entry["models"][0].as_str().unwrap();
    let tp_doc = single_model(&rewrite_path(entry), model);
    let gold = &golden(entry)["cases"][idx];
    if cmp.get("vi_only").and_then(Value::as_bool) == Some(true) {
        check_vi_only(entry, case, &tp_doc, model, label, gold);
        return;
    }
    let needs_vi =
        cmp.get("sets").is_some() || cmp.get("rank").is_some() || cmp.get("rank_lookup").is_some();
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let label = format!("{label} [{}]", compiler.as_str());
        let tp = build(&tp_doc, case, compiler)
            .unwrap_or_else(|e| panic!("{label}: template build: {e}"));
        // The pipeline reports the invented members and evaluates every
        // build-time observed, a rank variable among them.
        let pipe = needs_vi.then(|| {
            build_with(&tp_doc, case, compiler, true)
                .unwrap_or_else(|e| panic!("{label}: template pipeline build: {e}"))
        });
        let empty = HashMap::new();
        let tp_members = pipe.as_ref().map_or(&empty, EsmProblem::members);
        for s in cmp
            .get("sets")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let faq = s["faq"].as_str().unwrap();
            let lo: Vec<i64> = s["decode"]["lo"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_i64().unwrap())
                .collect();
            let n_b = s["decode"]["n_b"].as_i64().unwrap();
            let members = tp_members
                .get(faq)
                .unwrap_or_else(|| panic!("{label}: no integer members for {faq}"));
            let mut sorted = members.clone();
            sorted.sort_unstable();
            sorted.dedup();
            assert_eq!(*members, sorted, "{label}: members not ascending distinct");
            let decoded: Vec<Key> = members.iter().map(|&k| decode(k, &lo, n_b)).collect();
            let want = golden_members(&gold["sets"][faq]);
            assert_eq!(decoded, want, "{label}: template {faq} vs golden");
            assert_eq!(
                pipe.as_ref().unwrap().extents()[faq] as u64,
                gold["sets"][faq]["extent"].as_u64().unwrap(),
                "{label}: {faq} extent vs golden"
            );
        }
        if let Some(r) = cmp.get("rank") {
            let faq = r["faq"].as_str().unwrap();
            let want = golden_floats(&gold["rank"]["values"]);
            let got = observed_field(pipe.as_ref().unwrap(), r["variable"].as_str().unwrap())
                .unwrap_or_else(|e| panic!("{label}: rank variable: {e}"));
            assert_eq!(
                bits(&got.iter().copied().collect::<Vec<_>>()),
                bits(&want),
                "{label}: dense ids vs golden"
            );
            assert_eq!(
                rank_of_each(&tp_members[faq]),
                want,
                "{label}: rank_of over the template's members"
            );
        }
        if let Some(rl) = cmp.get("rank_lookup") {
            let got: Vec<f64> =
                observed_field(pipe.as_ref().unwrap(), rl["variable"].as_str().unwrap())
                    .unwrap_or_else(|e| panic!("{label}: rank lookup: {e}"))
                    .iter()
                    .copied()
                    .collect();
            let gw = golden_floats(&gold["rank_lookup"]["values"]);
            assert_eq!(bits(&got), bits(&gw), "{label}: rank lookup vs golden");
        }
        for a in cmp
            .get("assignments")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let name = a["template"].as_str().unwrap();
            let tp_buf: Vec<f64> = observed_field(&tp, name)
                .unwrap_or_else(|e| panic!("{label}: assignment: {e}"))
                .iter()
                .copied()
                .collect();
            let gw = golden_floats(&gold["assignments"][name]);
            assert_eq!(bits(&tp_buf), bits(&gw), "{label}: assignment vs golden");
        }
        if cmp.get("rhs").and_then(Value::as_bool) == Some(true) {
            let dy = rhs_at_golden(&tp, compiler, &label, model, &gold["rhs"]);
            let want = gold["rhs"]["dy"].as_object().unwrap();
            assert_eq!(dy.len(), want.len(), "{label}: state elements");
            for (n, w) in want {
                let w = w.as_f64().unwrap();
                assert_eq!(
                    dy[n].to_bits(),
                    w.to_bits(),
                    "{label}: template vs golden at {n}: {} vs {w}",
                    dy[n]
                );
            }
        }
    }
}

/// Value invention alone, for a document whose right-hand side needs data the
/// manifest does not carry: the template form's model as loaded (templates
/// expanded) against the golden.
fn check_vi_only(
    entry: &Value,
    case: &Value,
    tp_doc: &Value,
    model: &str,
    label: &str,
    gold: &Value,
) {
    let arrays = case_arrays(case);
    let params = case_params(case);
    let options = LoadOptions {
        base_path: Some(repo_root()),
        ..Default::default()
    };
    let file = load_string_with_options(&tp_doc.to_string(), &options)
        .unwrap_or_else(|e| panic!("{label}: load: {e}"));
    let mut expanded = serde_json::to_value(&file).unwrap();
    assert!(
        !expanded.to_string().contains("apply_expression_template"),
        "{label}: templates not expanded at load"
    );
    expanded["index_sets"] = tp_doc["index_sets"].clone();
    let tp = materialize_value_invention(
        &engine_model(&expanded, model),
        &arrays,
        &params,
        &HashMap::new(),
    )
    .unwrap_or_else(|e| panic!("{label}: template: {e}"));
    for s in entry["compare"]["sets"].as_array().unwrap() {
        let faq = s["faq"].as_str().unwrap();
        let lo: Vec<i64> = s["decode"]["lo"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap())
            .collect();
        let n_b = s["decode"]["n_b"].as_i64().unwrap();
        let decoded: Vec<Key> = tp.members[faq]
            .iter()
            .map(|k| match k {
                Key::Int(i) => decode(*i, &lo, n_b),
                other => panic!("{label}: template key {other:?} is not an integer"),
            })
            .collect();
        let want = golden_members(&gold["sets"][faq]);
        assert_eq!(decoded, want, "{label}: template {faq} vs golden");
        assert_eq!(
            tp.extents[faq] as u64,
            gold["sets"][faq]["extent"].as_u64().unwrap(),
            "{label}: {faq} extent vs golden"
        );
    }
}

#[test]
fn every_rewrite_matches_its_golden() {
    let mut ran = 0;
    for entry in manifest() {
        if entry["compare"].get("tier").is_some() {
            continue;
        }
        let id = entry["id"].as_str().unwrap();
        for (i, case) in entry["cases"].as_array().unwrap().iter().enumerate() {
            check_case(&entry, i, case, &format!("{id}-{i}"));
            ran += 1;
        }
    }
    assert!(ran >= 9, "only {ran} rewrite cases ran");
}

/// Inline-test results of `path` under `compiler`: `(passed, actual)` per
/// assertion, with each failure's message.
fn inline(path: &Path, compiler: Compiler) -> Vec<(bool, Option<f64>, String)> {
    let options = LoadOptions {
        base_path: path.parent().map(Path::to_path_buf),
        ..Default::default()
    };
    let text = std::fs::read_to_string(path).unwrap();
    let file =
        load_string_with_options(&text, &options).unwrap_or_else(|e| panic!("{path:?}: load: {e}"));
    let opts = InlineTestOptions {
        base_dir: path.parent().map(Path::to_path_buf),
        compiler: Some(compiler),
        ..Default::default()
    };
    run_inline_tests_with_options(&file, &opts, None)
        .into_iter()
        .map(|r| (r.passed, r.actual, r.message))
        .collect()
}

#[test]
fn rewrites_load_and_inline_tests_match_the_golden() {
    for entry in manifest() {
        let cmp = &entry["compare"];
        let id = entry["id"].as_str().unwrap();
        let path = rewrite_path(&entry);
        let tier = cmp.get("tier").and_then(Value::as_str);
        if cmp.get("load_only").and_then(Value::as_bool) == Some(true) {
            let options = LoadOptions {
                base_path: path.parent().map(Path::to_path_buf),
                ..Default::default()
            };
            let text = std::fs::read_to_string(&path).unwrap();
            load_string_with_options(&text, &options).unwrap_or_else(|e| panic!("{id}: load: {e}"));
        } else if cmp.get("inline_tests").and_then(Value::as_bool) == Some(true) {
            let tp: Vec<Option<f64>> = inline(&path, Compiler::Interpreter)
                .into_iter()
                .map(|r| r.1)
                .collect();
            // Integrator outputs: within each assertion's tolerance, not bit for bit.
            let gold = golden(&entry)["inline_tests"].as_array().unwrap().clone();
            assert_eq!(tp.len(), gold.len(), "{id}: inline-test count");
            for (r, g) in tp.iter().zip(&gold) {
                let (want, rtol, atol) = (
                    g["actual"].as_f64().unwrap(),
                    g["rtol"].as_f64().unwrap(),
                    g["atol"].as_f64().unwrap(),
                );
                let got = r.unwrap_or_else(|| panic!("{id}: no actual"));
                assert!(
                    (got - want).abs() <= atol.max(rtol * want.abs()),
                    "{id}: inline-test actual {got} vs golden {want}"
                );
            }
        } else if tier == Some("relational_templates") {
            // The rewrite's own inline tests, under both compilers.
            for compiler in [Compiler::Interpreter, Compiler::Native] {
                let results = inline(&path, compiler);
                assert!(!results.is_empty(), "{id}: no inline tests");
                for (passed, actual, message) in results {
                    assert!(
                        passed,
                        "{id} [{}]: {actual:?}: {message}",
                        compiler.as_str()
                    );
                }
            }
        }
    }
}

#[test]
fn an_out_of_range_key_component_is_refused_naming_the_column() {
    let entry = manifest()
        .into_iter()
        .find(|e| e["id"] == "bin_skolem_spatial_join")
        .unwrap();
    let mut doc = single_model(&rewrite_path(&entry), "BinSkolemSpatialJoin");
    for eq in doc["models"]["BinSkolemSpatialJoin"]["equations"]
        .as_array_mut()
        .unwrap()
    {
        if eq["rhs"]["distinct"] == json!(true) {
            // j = 3, 4 fall outside [1, 3).
            eq["rhs"]["key"]["bindings"]["n_b"] = json!(2);
        }
    }
    let case = &entry["cases"][0];
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let Err(e) = build(&doc, case, compiler) else {
            panic!("[{}]: an out-of-range key built", compiler.as_str());
        };
        assert!(
            e.contains("value_invention_key_out_of_range") && e.contains("candidate_set"),
            "[{}]: {e}",
            compiler.as_str()
        );
        assert!(
            !e.contains("derived_index_set_unmaterialized"),
            "[{}]: rewrapped: {e}",
            compiler.as_str()
        );
    }
}
