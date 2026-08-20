//! The projection-pushdown desugar THROUGH surviving expression-template
//! references (esm-spec §9.6.4 Option B, CONFORMANCE_SPEC §5.5.7).
//!
//! Option B has `load` PRESERVE `apply_expression_template` references so the
//! build boundary can expand them once. `prepare` therefore hands
//! `desugar_pushdown` an UNEXPANDED document — and an author who factored a
//! binning body through a template used to hide the containment `ifelse` from
//! the recogniser, which then declined SILENTLY: no derived support set, no
//! gate, and the provider array fetched wholesale, with the numbers still
//! correct.
//!
//! Rule 4 ("patterns do not see through surviving references") governs the
//! §9.6.3 rewrite-rule ENGINE. This is a different consumer and rule 2 governs
//! it: a reference DENOTES its expansion. The invariant pinned here is
//!
//! > whether the pushdown fires MUST NOT depend on whether the author factored
//! > the binning body through a template
//!
//! with the corpus fixture `pushdown/template_body` pinning the emitted document
//! cross-binding and this file covering what a golden cannot express: the second
//! binding spelling, the hard post-condition error, and the diagnostic split.

use std::borrow::Cow;

use serde_json::{Value, json};

use earthsci_ast::pushdown_rewrite::{desugar_pushdown, pushdown_diagnostics};

fn ix(f: &str, i: &str) -> Value {
    json!({"op": "index", "args": [f, i]})
}

fn contain() -> Value {
    json!({"op": "and", "args": [
        {"op": "<=", "args": [ix("src_W", "c"), ix("px", "r")]},
        {"op": "<",  "args": [ix("px", "r"), ix("src_E", "c")]},
        {"op": "<=", "args": [ix("src_S", "c"), ix("py", "r")]},
        {"op": "<",  "args": [ix("py", "r"), ix("src_N", "c")]}]})
}

fn eranges() -> Value {
    json!({"c": {"from": "src_cells"}, "r": {"from": "emis_records"}})
}

fn eargs() -> Value {
    json!(["src_W", "src_S", "src_E", "src_N", "px", "py", "emis_annual"])
}

/// The minimal forward document: one provider-backed SR array, one binning
/// `E[c]`, one `conc[rcv]` — the `pushdown_gated_dense` shape.
fn base_doc() -> Value {
    let mut v = serde_json::Map::new();
    for n in ["src_W", "src_S", "src_E", "src_N"] {
        v.insert(n.into(), json!({"type": "parameter", "default": 0.0, "shape": ["src_cells"]}));
    }
    for n in ["px", "py", "emis_annual"] {
        v.insert(n.into(), json!({"type": "parameter", "default": 0.0, "shape": ["emis_records"]}));
    }
    v.insert(
        "SR_PM25".into(),
        json!({"type": "parameter", "default": 0.0, "shape": ["src_cells", "rcv_cells"]}),
    );
    v.insert("E_PM25".into(), json!({"type": "unknown", "shape": ["src_cells"]}));
    v.insert("conc_PM25".into(), json!({"type": "unknown", "shape": ["rcv_cells"]}));
    json!({
        "esm": "1.0.0",
        "metadata": {"name": "pd_tmpl"},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": 4},
            "rcv_cells": {"kind": "interval", "size": 2},
            "emis_records": {"kind": "interval", "size": 3}},
        "models": {"Binned": {
            "variables": Value::Object(v),
            // esm 1.0.0: an observed unknown's body is its DEFINING EQUATION
            // (esm-spec §6.3.1), listed here in the §5.5.7 canonical order —
            // definitions sorted by the name they define.
            "equations": [
                {"lhs": "E_PM25",
                 "rhs": {"op": "aggregate", "output_idx": ["c"], "ranges": eranges(),
                         "args": eargs(), "reduce": "+",
                         "expr": {"op": "*", "args": [
                             {"op": "ifelse", "args": [contain(), 1.0, 0.0]},
                             ix("emis_annual", "r")]}}},
                {"lhs": "conc_PM25",
                 "rhs": {"op": "aggregate", "output_idx": ["rcv"],
                         "ranges": {"s": {"from": "src_cells"},
                                    "rcv": {"from": "rcv_cells"}},
                         "args": ["SR_PM25", "E_PM25"], "reduce": "+",
                         "expr": {"op": "*", "args": [
                             {"op": "index", "args": ["SR_PM25", "s", "rcv"]},
                             ix("E_PM25", "s")]}}}]}}})
}

/// `name`'s defining right-hand side — where 0.x kept `variables[name].expression`.
fn def_of<'a>(doc: &'a Value, name: &str) -> &'a Value {
    doc["models"]["Binned"]["equations"]
        .as_array()
        .expect("equations is an array")
        .iter()
        .find(|eq| eq["lhs"] == json!(name))
        .map(|eq| &eq["rhs"])
        .unwrap_or_else(|| panic!("{name} has no defining equation"))
}

/// The DEFINITIONS of a rewritten document as `{name: rhs}`, dropping the
/// structural equations (the generated `distinct` producer has no bare-variable
/// LHS).
fn defs_of(doc: &Value) -> std::collections::BTreeMap<String, Value> {
    doc["models"]["Binned"]["equations"]
        .as_array()
        .expect("equations is an array")
        .iter()
        .filter_map(|eq| eq["lhs"].as_str().map(|n| (n.to_string(), eq["rhs"].clone())))
        .collect()
}

/// The equations that are NOT definitions, in order.
fn structural_of(doc: &Value) -> Vec<Value> {
    doc["models"]["Binned"]["equations"]
        .as_array()
        .expect("equations is an array")
        .iter()
        .filter(|eq| !eq["lhs"].is_string())
        .cloned()
        .collect()
}

/// Rebind `E_PM25`'s defining equation to an aggregate over `expr`.
fn set_e(doc: &mut Value, expr: Value) {
    let rhs = json!({"op": "aggregate", "output_idx": ["c"], "ranges": eranges(),
                     "args": eargs(), "reduce": "+", "expr": expr});
    for eq in doc["models"]["Binned"]["equations"].as_array_mut().unwrap() {
        if eq["lhs"] == json!("E_PM25") {
            eq["rhs"] = rhs;
            return;
        }
    }
    unreachable!("base_doc always defines E_PM25");
}

/// Spelling 1 — the binding IS the factor name (the corpus fixture's spelling).
/// The rewritten document must be the longhand rewrite in everything but
/// `E_PM25`, and the shared template body must come through untouched.
#[test]
fn bare_factor_name_bindings_are_repointed() {
    let longhand = base_doc();
    let lr = desugar_pushdown(&longhand, Some("Binned")).unwrap();
    assert!(matches!(lr, Cow::Owned(_)));

    let mut d = base_doc();
    d["models"]["Binned"]["expression_templates"] = json!({"bin_into_cell": {
        "params": ["xmin", "ymin", "xmax", "ymax", "ptx", "pty", "wgt"],
        "body": {"op": "*", "args": [
            {"op": "ifelse", "args": [{"op": "and", "args": [
                {"op": "<=", "args": [ix("xmin", "c"), ix("ptx", "r")]},
                {"op": "<",  "args": [ix("ptx", "r"), ix("xmax", "c")]},
                {"op": "<=", "args": [ix("ymin", "c"), ix("pty", "r")]},
                {"op": "<",  "args": [ix("pty", "r"), ix("ymax", "c")]}]}, 1.0, 0.0]},
            ix("wgt", "r")]}}});
    set_e(&mut d, json!({"op": "apply_expression_template", "args": [],
                         "name": "bin_into_cell",
                         "bindings": {"xmin": "src_W", "ymin": "src_S",
                                      "xmax": "src_E", "ymax": "src_N",
                                      "ptx": "px", "pty": "py", "wgt": "emis_annual"}}));
    let tpl_before = d["models"]["Binned"]["expression_templates"].clone();

    let r = desugar_pushdown(&d, Some("Binned")).unwrap();
    assert!(matches!(r, Cow::Owned(_)), "the rewrite must fire on the factored body");
    // The DECLARATIONS match exactly: the two forms differ in how the binning
    // body is written, which in 1.0.0 lives in the defining equation — so even
    // E_PM25's declaration, re-pointed onto the derived axis either way, is
    // identical between them.
    assert_eq!(
        r["models"]["Binned"]["variables"],
        lr["models"]["Binned"]["variables"]
    );
    assert_eq!(r["metadata"]["x_esd"], lr["metadata"]["x_esd"]);
    assert_eq!(r["index_sets"], lr["index_sets"]);
    // The generated `distinct` producer is identical…
    assert_eq!(structural_of(&r), structural_of(&lr));
    // …and among the DEFINITIONS only E_PM25's body differs.
    let (rdef, ldef) = (defs_of(&r), defs_of(&lr));
    let differing: Vec<&String> =
        rdef.keys().filter(|k| rdef[*k] != ldef[*k]).collect();
    assert_eq!(rdef.keys().collect::<Vec<_>>(), ldef.keys().collect::<Vec<_>>());
    assert_eq!(differing, vec!["E_PM25"]);
    // the CALL SITE moved; the shared body did not (Option B survives)
    let b = &def_of(&r, "E_PM25")["expr"]["bindings"];
    assert_eq!(b["xmin"], json!("pd_cell__src_cells__src_W"));
    assert_eq!(b["ymax"], json!("pd_cell__src_cells__src_N"));
    assert_eq!(b["ptx"], json!("px"));
    assert_eq!(r["models"]["Binned"]["expression_templates"], tpl_before);
    // idempotent
    assert!(matches!(desugar_pushdown(&r, Some("Binned")).unwrap(), Cow::Borrowed(_)));
    assert!(pushdown_diagnostics(&d, Some("Binned")).is_empty());
}

/// Spelling 2 — the binding carries `index(src_W, c)` and the body names its
/// params as plain operands.
#[test]
fn subscripted_bindings_are_repointed() {
    let mut d = base_doc();
    d["models"]["Binned"]["expression_templates"] = json!({"bin2": {
        "params": ["lo_x", "lo_y", "hi_x", "hi_y", "x", "y", "wgt"],
        "body": {"op": "*", "args": [
            {"op": "ifelse", "args": [{"op": "and", "args": [
                {"op": "<=", "args": ["lo_x", "x"]},
                {"op": "<",  "args": ["x", "hi_x"]},
                {"op": "<=", "args": ["lo_y", "y"]},
                {"op": "<",  "args": ["y", "hi_y"]}]}, 1.0, 0.0]},
            "wgt"]}}});
    set_e(&mut d, json!({"op": "apply_expression_template", "args": [], "name": "bin2",
                         "bindings": {"lo_x": ix("src_W", "c"), "lo_y": ix("src_S", "c"),
                                      "hi_x": ix("src_E", "c"), "hi_y": ix("src_N", "c"),
                                      "x": ix("px", "r"), "y": ix("py", "r"),
                                      "wgt": ix("emis_annual", "r")}}));
    let tpl_before = d["models"]["Binned"]["expression_templates"].clone();

    let r = desugar_pushdown(&d, Some("Binned")).unwrap();
    assert!(matches!(r, Cow::Owned(_)));
    let e = &r["models"]["Binned"]["variables"]["E_PM25"];
    assert_eq!(e["shape"], json!(["pd_support__src_cells"]));
    let edef = def_of(&r, "E_PM25");
    assert_eq!(edef["ranges"]["c"]["from"], json!("pd_support__src_cells"));
    let b = &edef["expr"]["bindings"];
    assert_eq!(b["lo_x"]["args"][0], json!("pd_cell__src_cells__src_W"));
    assert_eq!(b["hi_y"]["args"][0], json!("pd_cell__src_cells__src_N"));
    assert_eq!(b["x"]["args"][0], json!("px")); // records untouched
    assert_eq!(r["models"]["Binned"]["expression_templates"], tpl_before);
    assert!(matches!(desugar_pushdown(&r, Some("Binned")).unwrap(), Cow::Borrowed(_)));
}

/// The rewrite edits call sites only (that is what keeps the body shared and
/// singly-lowered), so a rect factor named FREE in a body cannot be re-pointed.
/// Left alone it would index the compact per-support gathers with FULL-GRID
/// positions — wrong numbers, silently. Hence an error, not a warning.
#[test]
fn free_rect_in_template_body_is_rejected() {
    let mut d = base_doc();
    d["models"]["Binned"]["expression_templates"] = json!({"bin3": {
        "params": ["wgt"],
        "body": {"op": "*", "args": [
            {"op": "ifelse", "args": [contain(), 1.0, 0.0]}, ix("wgt", "r")]}}});
    set_e(&mut d, json!({"op": "apply_expression_template", "args": [], "name": "bin3",
                         "bindings": {"wgt": "emis_annual"}}));
    let err = desugar_pushdown(&d, Some("Binned")).expect_err("must be rejected");
    let msg = err.0;
    assert!(msg.contains("template_body_references_pushdown_rewritten_variable"), "{msg}");
    assert!(msg.contains("src_W"), "{msg}");
    assert!(msg.contains("E_PM25"), "{msg}");
    assert!(msg.contains("Bind the value through the template's params"), "{msg}");
}

/// "Not a join" is not a defect: an aggregate with no containment predicate is a
/// legitimately dense factor and MUST NOT be reported.
#[test]
fn dense_reduction_is_silent() {
    let mut d = base_doc();
    for eq in d["models"]["Binned"]["equations"].as_array_mut().unwrap() {
        if eq["lhs"] == json!("E_PM25") {
            eq["rhs"] = json!({"op": "aggregate", "output_idx": ["c"],
                               "ranges": eranges(), "args": ["emis_annual"],
                               "reduce": "+",
                               "expr": {"op": "*",
                                        "args": [ix("emis_annual", "r"), 1.0]}});
        }
    }
    assert!(pushdown_diagnostics(&d, Some("Binned")).is_empty());
    assert!(matches!(desugar_pushdown(&d, Some("Binned")).unwrap(), Cow::Borrowed(_)));
}

/// A surviving reference the detector could NOT see through — here because the
/// registry is gone. The document IS join-shaped, so this is reported, naming the
/// template, and the document comes back untouched.
#[test]
fn unexpandable_reference_in_the_join_position_is_reported() {
    let mut d = base_doc();
    set_e(&mut d, json!({"op": "apply_expression_template", "args": [], "name": "gone",
                         "bindings": {"wgt": "emis_annual"}}));
    let dg = pushdown_diagnostics(&d, Some("Binned"));
    assert_eq!(dg.len(), 1);
    assert_eq!(dg[0]["code"], json!("pushdown_join_unrecognised"));
    assert_eq!(dg[0]["reason"], json!("surviving_template_reference"));
    assert_eq!(dg[0]["template"], json!("gone"));
    assert_eq!(dg[0]["variable"], json!("E_PM25"));
    assert_eq!(dg[0]["array"], json!("SR_PM25"));
    assert_eq!(dg[0]["index_set"], json!("src_cells"));
    assert!(matches!(desugar_pushdown(&d, Some("Binned")).unwrap(), Cow::Borrowed(_)));
}
