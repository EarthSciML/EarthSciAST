//! Template rewrites of the skolem / rank / gated-argmin fixtures against the
//! op forms (`tests/conformance/relational_templates/rewrites/manifest.json`).
//!
//! Each rewrite replaces the value-invention ops with lib/relational.esm
//! templates (`pair_key` / `edge_key` keys, per-component join columns, the
//! loop index for a set's own rank, `argmin_where` for a gated arg-witness).
//! Both forms are built with the same caller data and must agree: the derived
//! set's members (the op's tuples against the template's integer keys,
//! decoded), the extents, the 1-based dense IDs, the arg-witness buffers, and
//! the right-hand side at a probe state, bit for bit. The template form is
//! built under the interpreter and the strict native tape. A
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

/// The op form's value invention, with the observeds the op reads that are
/// not value-invention outputs (a coordinate, `src_lon` from a polygon table)
/// supplied as factors alongside the caller's arrays. They are read from
/// `fields`, the template form's build-pipeline problem: both documents
/// define them identically, and the op form's skolem bin maps hide them from
/// its own pipeline.
fn op_value_invention(
    doc: &Value,
    model: &str,
    case: &Value,
    fields: &EsmProblem,
) -> earthsci_ast::ValueInventionResult {
    let mut arrays = case_arrays(case);
    for name in doc["models"][model]["variables"]
        .as_object()
        .unwrap()
        .keys()
    {
        if arrays.contains_key(name) {
            continue;
        }
        if let Ok(f) = observed_field(fields, name) {
            arrays.insert(name.clone(), f);
        }
    }
    materialize_value_invention(
        &engine_model(doc, model),
        &arrays,
        &case_params(case),
        &HashMap::new(),
    )
    .unwrap_or_else(|e| panic!("{model}: op value invention: {e}"))
}

fn decode(k: i64, lo: &[i64], n_b: i64) -> Key {
    Key::Tuple(vec![
        Key::Int(k.div_euclid(n_b) + lo[0]),
        Key::Int(k.rem_euclid(n_b) + lo[1]),
    ])
}

/// `dy` at `u = 1 + 0.1 sin(0.37 k)`: the interpreter, or the strict native
/// tape with no rule off it.
fn rhs_at_probe(prob: &EsmProblem, compiler: Compiler, label: &str) -> (Vec<String>, Vec<f64>) {
    let comp = prob.debug_array_compiled().expect("a right-hand side");
    let names = comp.state_variable_names().to_vec();
    let state: Vec<f64> = (0..names.len())
        .map(|k| 1.0 + 0.1 * (0.37 * k as f64).sin())
        .collect();
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
        "esm": "1.1.0",
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

fn check_case(entry: &Value, case: &Value, label: &str) {
    let cmp = &entry["compare"];
    let model = entry["models"][0].as_str().unwrap();
    let source = repo_root().join(entry["source"].as_str().unwrap());
    let op_doc = single_model(&source, model);
    let tp_doc = single_model(&rewrite_path(entry), model);
    if cmp.get("vi_only").and_then(Value::as_bool) == Some(true) {
        check_vi_only(entry, case, &op_doc, &tp_doc, model, label);
        return;
    }
    let op_prob = build(&op_doc, case, Compiler::Interpreter)
        .unwrap_or_else(|e| panic!("{label}: op build: {e}"));
    let needs_vi = cmp.get("sets").is_some()
        || cmp.get("rank").is_some()
        || cmp.get("rank_lookup").is_some()
        || cmp.get("assignments").is_some();
    let op_vi = needs_vi.then(|| {
        let fields = build_with(&tp_doc, case, Compiler::Interpreter, true)
            .unwrap_or_else(|e| panic!("{label}: template pipeline build: {e}"));
        op_value_invention(&op_doc, model, case, &fields)
    });
    let op_rhs = (cmp.get("rhs").and_then(Value::as_bool) == Some(true))
        .then(|| rhs_at_probe(&op_prob, Compiler::Interpreter, label));
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
            let op = op_vi.as_ref().unwrap();
            assert_eq!(decoded, op.members[faq], "{label}: {faq} members");
            let tp_extent = pipe.as_ref().unwrap().extents()[faq];
            assert_eq!(tp_extent, op.extents[faq], "{label}: {faq} extent");
        }
        if let Some(r) = cmp.get("rank") {
            let faq = r["faq"].as_str().unwrap();
            let n = op_vi.as_ref().unwrap().members[faq].len();
            // The op set is in sorted order, so its 0-based rank is the
            // position; the 0 -> 1 shift gives the template's loop index.
            let want: Vec<f64> = (1..=n).map(|k| k as f64).collect();
            let got = observed_field(pipe.as_ref().unwrap(), r["variable"].as_str().unwrap())
                .unwrap_or_else(|e| panic!("{label}: rank variable: {e}"));
            assert_eq!(
                got.iter().copied().collect::<Vec<_>>(),
                want,
                "{label}: dense ids"
            );
            assert_eq!(
                rank_of_each(&tp_members[faq]),
                want,
                "{label}: rank_of over the template's members"
            );
        }
        if let Some(rl) = cmp.get("rank_lookup") {
            // A rank looked up against the derived set (rank_of_set over its
            // members): the op set's 0-based rank of each row's tuple, + 1.
            let op_members = &op_vi.as_ref().unwrap().members[rl["faq"].as_str().unwrap()];
            let cols: Vec<ArrayD<f64>> = rl["columns"]
                .as_array()
                .unwrap()
                .iter()
                .map(|c| json_array(&case["const_arrays"][c.as_str().unwrap()]))
                .collect();
            let want: Vec<f64> = (0..cols[0].len())
                .map(|i| {
                    let mut t: Vec<i64> = cols
                        .iter()
                        .map(|c| c.as_slice().unwrap()[i] as i64)
                        .collect();
                    t.sort_unstable();
                    let key = Key::Tuple(t.into_iter().map(Key::Int).collect());
                    let pos = op_members
                        .iter()
                        .position(|m| *m == key)
                        .unwrap_or_else(|| panic!("{label}: {key:?} is not a member"));
                    (pos + 1) as f64
                })
                .collect();
            let got: Vec<f64> =
                observed_field(pipe.as_ref().unwrap(), rl["variable"].as_str().unwrap())
                    .unwrap_or_else(|e| panic!("{label}: rank lookup: {e}"))
                    .iter()
                    .copied()
                    .collect();
            assert_eq!(bits(&got), bits(&want), "{label}: {got:?} vs {want:?}");
        }
        for a in cmp
            .get("assignments")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let op_buf: Vec<f64> = op_vi.as_ref().unwrap().assignments[a["op"].as_str().unwrap()]
                .iter()
                .map(|&i| i as f64)
                .collect();
            let tp_buf: Vec<f64> = observed_field(&tp, a["template"].as_str().unwrap())
                .unwrap_or_else(|e| panic!("{label}: assignment: {e}"))
                .iter()
                .copied()
                .collect();
            assert_eq!(
                bits(&tp_buf),
                bits(&op_buf),
                "{label}: {tp_buf:?} vs {op_buf:?}"
            );
        }
        if let Some((op_names, op_dy)) = &op_rhs {
            let (names, dy) = rhs_at_probe(&tp, compiler, &label);
            assert_eq!(names, *op_names, "{label}: state order");
            assert_eq!(bits(&dy), bits(op_dy), "{label}: {dy:?} vs {op_dy:?}");
        }
    }
}

/// Value invention alone, for a document whose right-hand side needs data the
/// manifest does not carry: the op form's raw model against the template
/// form's model as loaded (templates expanded).
fn check_vi_only(
    entry: &Value,
    case: &Value,
    op_doc: &Value,
    tp_doc: &Value,
    model: &str,
    label: &str,
) {
    let arrays = case_arrays(case);
    let params = case_params(case);
    let op = materialize_value_invention(
        &engine_model(op_doc, model),
        &arrays,
        &params,
        &HashMap::new(),
    )
    .unwrap_or_else(|e| panic!("{label}: op: {e}"));
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
        assert_eq!(decoded, op.members[faq], "{label}: {faq} members");
        assert_eq!(tp.extents[faq], op.extents[faq], "{label}: {faq} extent");
    }
}

#[test]
fn every_rewrite_agrees_with_its_op_form() {
    let mut ran = 0;
    for entry in manifest() {
        if entry["compare"].get("tier").is_some() {
            continue;
        }
        let id = entry["id"].as_str().unwrap();
        for (i, case) in entry["cases"].as_array().unwrap().iter().enumerate() {
            check_case(&entry, case, &format!("{id}-{i}"));
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
fn rewrites_load_and_inline_tests_match_the_op_form() {
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
            let source = repo_root().join(entry["source"].as_str().unwrap());
            let op: Vec<Option<f64>> = inline(&source, Compiler::Interpreter)
                .into_iter()
                .map(|r| r.1)
                .collect();
            let tp: Vec<Option<f64>> = inline(&path, Compiler::Interpreter)
                .into_iter()
                .map(|r| r.1)
                .collect();
            assert_eq!(tp, op, "{id}: inline-test actuals");
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
