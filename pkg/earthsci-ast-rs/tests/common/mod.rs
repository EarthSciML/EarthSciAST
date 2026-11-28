//! Shared helpers for the integration-test suite.
//!
//! Fixture files live in the REPO-ROOT `tests/` tree (shared across the five
//! language bindings), two directories above this crate. Use these helpers
//! rather than climbing from `CARGO_MANIFEST_DIR` in a test file: the paths,
//! a conformance tier's directory and manifest, its pinned solver options and
//! assertion tolerances, and the mock data providers several suites share.
//!
//! The `integration` binary and the few standalone `[[test]]` targets each
//! compile their own copy of this module, so helpers a given binary does not
//! use are expected — hence the allow.
#![allow(dead_code)]

pub use crate::portable::rhs;

pub mod tier;

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use earthsci_ast::{Alg, AxisSel, DataProvider, ProviderError, SolveOptions};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

/// The repository root, two directories above this crate.
pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("the crate sits two levels under the repository root")
}

/// The repo-root `tests/` directory (the cross-binding fixture tree).
pub fn repo_tests_dir() -> PathBuf {
    repo_root().join("tests")
}

/// Absolute path of a fixture given its path relative to the repo-root
/// `tests/` directory (e.g. `"valid/units_conversions.esm"`).
pub fn repo_fixture(rel: &str) -> PathBuf {
    repo_tests_dir().join(rel)
}

/// The directory of the conformance tier `category`
/// (`tests/conformance/<category>`).
pub fn category_dir(category: &str) -> PathBuf {
    repo_fixture(&format!("conformance/{category}"))
}

/// Read and parse a JSON file, panicking with the offending path on failure.
pub fn read_json(path: impl AsRef<Path>) -> Value {
    let path = path.as_ref();
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// The manifest of the conformance tier `category`.
pub fn tier_manifest(category: &str) -> Value {
    read_json(category_dir(category).join("manifest.json"))
}

/// The header every cross-binding tier manifest carries: its own `category`,
/// Julia as the reference binding, and Julia, Python and Rust all required.
pub fn assert_tier_header(manifest: &Value, category: &str) {
    assert_eq!(manifest["category"].as_str(), Some(category));
    assert_eq!(manifest["reference_binding"].as_str(), Some("julia"));
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["julia", "python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }
}

/// The manifest's `(assertion_rtol, assertion_atol)`.
pub fn assertion_tolerances(manifest: &Value) -> (f64, f64) {
    let tol = &manifest["tolerances"];
    (
        tol["assertion_rtol"].as_f64().expect("rtol"),
        tol["assertion_atol"].as_f64().expect("atol"),
    )
}

/// The solver options a tier pins for this binding (`integrators.rust`), whose
/// solver must be the explicit Runge-Kutta family.
pub fn erk_solve_options(manifest: &Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        // `Some`: the manifest NAMES both tolerances, and `SolveOptions` takes
        // `Option<f64>` so that "the caller said nothing" stays distinguishable
        // from "the caller asked for the default" (esm-spec §2.2.2).
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    }
}

/// Whether `actual` is within `atol` of `want`, or within `rtol` of the larger
/// magnitude of the two.
pub fn close(actual: f64, want: f64, rtol: f64, atol: f64) -> bool {
    let diff = (actual - want).abs();
    diff <= atol || diff <= rtol * want.abs().max(actual.abs())
}

/// A data provider that serves one fixed 1-D array, wholesale.
pub struct MockConst(pub Vec<f64>);

impl DataProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

/// One fetch a [`MockGated`] served.
#[derive(Debug, Clone, PartialEq)]
pub enum Fetch {
    /// The whole array.
    Wholesale,
    /// The pushdown selection it was asked for.
    Selection(Vec<AxisSel>),
}

/// The fetches a [`MockGated`] served, in order, shared with the test.
pub type FetchLog = Rc<RefCell<Vec<Fetch>>>;

/// A pushdown-capable provider over `full`: it records each fetch, a
/// selection or the whole array, in `calls`, and with `refuse_wholesale`
/// panics when asked for the whole array.
pub struct MockGated {
    pub full: ArrayD<f64>,
    pub calls: FetchLog,
    pub refuse_wholesale: bool,
}

impl MockGated {
    /// A mock serving `full` either way, recording into `calls`.
    pub fn new(full: ArrayD<f64>, calls: FetchLog) -> Self {
        MockGated {
            full,
            calls,
            refuse_wholesale: false,
        }
    }
}

impl DataProvider for MockGated {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        assert!(
            !self.refuse_wholesale,
            "the gated mock must never be fetched wholesale"
        );
        self.calls.borrow_mut().push(Fetch::Wholesale);
        Ok(self.full.clone())
    }

    fn supports_selection(&self) -> bool {
        true
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, ProviderError> {
        self.calls
            .borrow_mut()
            .push(Fetch::Selection(selection.to_vec()));
        Ok(select_axes(&self.full, selection))
    }
}

/// A JSON array of numbers.
pub fn floats(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("an array")
        .iter()
        .map(|x| x.as_f64().expect("a number"))
        .collect()
}

/// A manifest's provider: one field, `base + slope * t` elementwise,
/// refreshed at `times`.
pub struct LinearProvider {
    pub key: String,
    pub times: Vec<f64>,
    pub shape: Vec<usize>,
    /// Row-major.
    pub base: Vec<f64>,
    pub slope: f64,
    /// A provider primed at this time (`primed_at`): it holds the record in
    /// effect there before any refresh ([`DataProvider::sample`]), lists the
    /// time among its refresh times and answers "unchanged" for the record it
    /// last delivered, the primed one first, as EarthSciIO's providers do for
    /// a run window that starts between two records.
    pub primed_at: Option<f64>,
    /// The time of the record last delivered (primed providers only).
    pub last: Option<f64>,
}

impl LinearProvider {
    /// The provider a manifest entry describes (`key`, `refresh_times`,
    /// `shape`, nested `base`, `slope`).
    pub fn from_manifest(p: &Value) -> Self {
        fn flatten(v: &Value, out: &mut Vec<f64>) {
            match v {
                Value::Array(a) => a.iter().for_each(|x| flatten(x, out)),
                x => out.push(x.as_f64().expect("a number")),
            }
        }
        let mut base = Vec::new();
        flatten(&p["base"], &mut base);
        LinearProvider {
            key: p["key"].as_str().unwrap().to_string(),
            times: floats(&p["refresh_times"]),
            shape: p["shape"]
                .as_array()
                .unwrap()
                .iter()
                .map(|d| d.as_u64().unwrap() as usize)
                .collect(),
            base,
            slope: p["slope"].as_f64().unwrap(),
            primed_at: p["primed_at"].as_f64(),
            last: p["primed_at"].as_f64(),
        }
    }

    /// The field at `t`.
    pub fn at(&self, t: f64) -> ArrayD<f64> {
        let values = self.base.iter().map(|b| b + self.slope * t).collect();
        ArrayD::from_shape_vec(IxDyn(&self.shape), values).expect("field")
    }
}

impl DataProvider for LinearProvider {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        if let Some(t) = self.primed_at {
            return Ok(self.at(t));
        }
        assert!(self.slope == 0.0, "only a const provider is materialized");
        Ok(self.at(0.0))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        if self.primed_at.is_some() {
            if self.last == Some(t) {
                return Ok(None);
            }
            self.last = Some(t);
        }
        Ok(Some(self.at(t)))
    }
    fn refresh_times(&self) -> Vec<f64> {
        let mut out = self.times.clone();
        if let Some(t) = self.primed_at
            && !out.contains(&t)
        {
            out.push(t);
            out.sort_by(f64::total_cmp);
        }
        out
    }
    fn primed(&self) -> bool {
        self.primed_at.is_some()
    }
}

/// `full` cut down by a pushdown selection: each `Indices` axis keeps the
/// listed positions, every other axis is kept whole.
pub fn select_axes(full: &ArrayD<f64>, selection: &[AxisSel]) -> ArrayD<f64> {
    let mut arr = full.clone();
    for (i, ax) in selection.iter().enumerate() {
        if let AxisSel::Indices(idx) = ax {
            arr = arr.select(ndarray::Axis(i), idx);
        }
    }
    arr
}

/// Read and `load_string()` a fixture given its repo-root-relative `tests/` path,
/// panicking with the offending path on failure.
pub fn load_repo_fixture(rel: &str) -> earthsci_ast::EsmFile {
    let path = repo_fixture(rel);
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    earthsci_ast::load_string(&content)
        .unwrap_or_else(|e| panic!("fixture {} does not load: {e}", path.display()))
}

/// Give every ODE state (a `D` target on some equation's left-hand side) that
/// declares no `default` a starting value of 0.0. Several corpus documents
/// leave their states' starting values to the harness; built without one they
/// are refused (`E_TREEWALK_MISSING_INITIAL_VALUE`, esm-spec §11.4).
pub fn supply_state_defaults(doc: &mut serde_json::Value) {
    fn d_target(lhs: &serde_json::Value) -> Option<String> {
        match lhs.get("op").and_then(|o| o.as_str()) {
            Some("D") => {
                let a = lhs.get("args")?.get(0)?;
                a.as_str()
                    .map(str::to_string)
                    .or_else(|| a.get("args")?.get(0)?.as_str().map(str::to_string))
            }
            Some("faq") => d_target(lhs.get("expr")?),
            _ => None,
        }
    }
    let Some(models) = doc.get_mut("models").and_then(|m| m.as_object_mut()) else {
        return;
    };
    for model in models.values_mut() {
        let targets: Vec<String> = model
            .get("equations")
            .and_then(|e| e.as_array())
            .map(|eqs| eqs.iter().filter_map(|e| d_target(e.get("lhs")?)).collect())
            .unwrap_or_default();
        let Some(vars) = model.get_mut("variables").and_then(|v| v.as_object_mut()) else {
            continue;
        };
        for t in targets {
            if let Some(v) = vars.get_mut(&t)
                && v.get("default").is_none()
            {
                v["default"] = serde_json::json!(0.0);
            }
        }
    }
}

/// An expression, equation or any other serializable AST value in canonical
/// JSON (`canonicalize_document`: CONFORMANCE §5.4, numbers in their
/// canonical kind), the form tests compare expressions in.
pub fn canon<T: serde::Serialize + ?Sized>(value: &T) -> serde_json::Value {
    earthsci_ast::canonicalize_document(
        &serde_json::to_value(value).expect("an AST value serializes"),
    )
}

/// Every operator node with op `op` in a JSON expression tree, outermost first.
pub fn nodes_with_op<'a>(value: &'a serde_json::Value, op: &str) -> Vec<&'a serde_json::Value> {
    fn walk<'a>(v: &'a serde_json::Value, op: &str, out: &mut Vec<&'a serde_json::Value>) {
        match v {
            serde_json::Value::Object(fields) => {
                if fields.get("op").and_then(|o| o.as_str()) == Some(op) {
                    out.push(v);
                }
                fields.values().for_each(|c| walk(c, op, out));
            }
            serde_json::Value::Array(items) => items.iter().for_each(|c| walk(c, op, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(value, op, &mut out);
    out
}

/// `doc` read through the esm 2.4.0 wire spellings (esm-spec §9.6.12 "Old
/// names", §4.2 "Reading earlier documents"), as a load reads it: the fields
/// `expression_templates` / `expression_template_imports` as `operators` /
/// `operator_imports` (never among a name-keyed map's keys), the op
/// `apply_expression_template` as `apply_operator`, and `δ`, `∂` and a `D`
/// whose `wrt` is present, not `"t"` and not a param of the enclosing
/// definition as `partial`. For comparing a document as written with what a
/// load writes back.
#[allow(dead_code)]
pub fn read_old_spellings(doc: &mut Value) {
    const NAME_MAPS: [&str; 27] = [
        "variables",
        "species",
        "parameters",
        "guesses",
        "subsystems",
        "operators",
        "ranges",
        "bindings",
        "config",
        "coords",
        "initial_conditions",
        "parameter_overrides",
        "pinned_coords",
        "map",
        "rename",
        "rebind",
        "index_set_rename",
        "url_substitutions",
        "where",
        "models",
        "reaction_systems",
        "data_sources",
        "index_sets",
        "enums",
        "metaparameters",
        "domains",
        "coupling_roles",
    ];
    fn walk(node: &mut Value, namemap: bool, params: Option<&[String]>) {
        match node {
            Value::Object(map) => {
                if !namemap {
                    for (old, new) in [
                        ("expression_templates", "operators"),
                        ("expression_template_imports", "operator_imports"),
                    ] {
                        if map.contains_key(old) {
                            let entries = std::mem::take(map);
                            for (k, v) in entries {
                                map.insert(if k == old { new.to_string() } else { k }, v);
                            }
                        }
                    }
                    let new_op = match map.get("op").and_then(Value::as_str) {
                        Some("apply_expression_template") => Some("apply_operator"),
                        Some("δ" | "∂") => Some("partial"),
                        Some("D") => match map.get("wrt") {
                            None | Some(Value::Null) => None,
                            Some(Value::String(w))
                                if w == "t" || params.is_some_and(|p| p.contains(w)) =>
                            {
                                None
                            }
                            Some(_) => Some("partial"),
                        },
                        _ => None,
                    };
                    if let Some(op) = new_op {
                        map.insert("op".to_string(), Value::from(op));
                    }
                }
                for (k, v) in map.iter_mut() {
                    if !namemap
                        && k == "operators"
                        && let Value::Object(defs) = v
                    {
                        for dv in defs.values_mut() {
                            let p: Option<Vec<String>> =
                                dv.get("params").and_then(Value::as_array).map(|a| {
                                    a.iter()
                                        .filter_map(|x| x.as_str().map(str::to_string))
                                        .collect()
                                });
                            walk(dv, false, p.as_deref());
                        }
                        continue;
                    }
                    walk(v, !namemap && NAME_MAPS.contains(&k.as_str()), params);
                }
            }
            Value::Array(items) => items.iter_mut().for_each(|v| walk(v, false, params)),
            _ => {}
        }
    }
    walk(doc, false, None);
    migrate_initialization_equations(doc);
}

/// esm 2.5.0 (esm-spec §11.4.4), as a load reads it: each model's
/// `initialization_equations` move into `equations` with every local unknown
/// `w` written `ic(w)` and every `D(w)` written `ic(D(w))`, or — for a model
/// with no time derivative — into `guesses` (an existing entry kept). Local
/// names only; for comparing a document as written with what a load writes.
#[allow(dead_code)]
pub fn migrate_initialization_equations(doc: &mut Value) {
    fn has_d(e: &Value) -> bool {
        match e {
            Value::Object(m) => {
                m.get("op").and_then(Value::as_str) == Some("D") || m.values().any(has_d)
            }
            Value::Array(a) => a.iter().any(has_d),
            _ => false,
        }
    }
    fn ic(arg: Value) -> Value {
        serde_json::json!({"op": "ic", "args": [arg]})
    }
    fn wrap(e: &Value, unknown: &dyn Fn(&str) -> bool) -> Value {
        match e {
            Value::String(s) if unknown(s) => ic(e.clone()),
            Value::Object(m) => {
                if m.get("op").and_then(Value::as_str) == Some("D")
                    && m.get("args")
                        .and_then(|a| a.get(0))
                        .and_then(Value::as_str)
                        .is_some_and(unknown)
                {
                    return ic(e.clone());
                }
                let mut out = serde_json::Map::new();
                for (k, v) in m {
                    let nv = match k.as_str() {
                        "args" | "expr" | "filter" | "values" => match v {
                            Value::Array(a) => Value::Array(a.iter().map(|x| wrap(x, unknown)).collect()),
                            other => wrap(other, unknown),
                        },
                        _ => v.clone(),
                    };
                    out.insert(k.clone(), nv);
                }
                Value::Object(out)
            }
            other => other.clone(),
        }
    }
    fn model(m: &mut Value) {
        let Some(o) = m.as_object_mut() else { return };
        if let Some(Value::Object(subs)) = o.get_mut("subsystems") {
            for sub in subs.values_mut() {
                model(sub);
            }
        }
        let Some(Value::Array(eqs)) = o.remove("initialization_equations") else {
            return;
        };
        if eqs.is_empty() {
            return;
        }
        let vars = o.get("variables").cloned().unwrap_or(Value::Null);
        let unknown = |n: &str| {
            vars.get(n).and_then(|v| v.get("type")).and_then(Value::as_str) == Some("unknown")
        };
        let time = o
            .get("equations")
            .and_then(Value::as_array)
            .is_some_and(|es| es.iter().any(|e| e.get("lhs").is_some_and(has_d)));
        if time {
            let moved: Vec<Value> = eqs
                .iter()
                .map(|eq| {
                    let mut eq = eq.clone();
                    for side in ["lhs", "rhs"] {
                        if let Some(v) = eq.get(side).cloned() {
                            eq[side] = wrap(&v, &unknown);
                        }
                    }
                    eq
                })
                .collect();
            if let Value::Array(list) = o.entry("equations").or_insert(Value::Array(Vec::new())) {
                list.extend(moved);
            }
        } else {
            let mut guesses = o
                .get("guesses")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            for eq in &eqs {
                if let Some(v) = eq.get("lhs").and_then(Value::as_str)
                    && !guesses.contains_key(v)
                {
                    guesses.insert(v.to_string(), eq.get("rhs").cloned().unwrap_or(Value::Null));
                }
            }
            o.insert("guesses".to_string(), Value::Object(guesses));
        }
    }
    if let Some(Value::Object(models)) = doc.get_mut("models") {
        for m in models.values_mut() {
            model(m);
        }
    }
}
