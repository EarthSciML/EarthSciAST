//! Conformance tests for the out-of-line-expression-templates RFC (Option B,
//! reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
//! §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten
//! registry merge). Mirrors the Julia reference suite
//! `EarthSciAST.jl/test/out_of_line_templates_test.jl` and drives the SAME
//! shared fixtures under `tests/conformance/expression_templates/`.

use earthsci_ast::lower_expression_templates as oob;
use earthsci_ast::template_imports::resolve_template_machinery;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

mod common;

fn conf(dir: &str) -> PathBuf {
    common::repo_fixture("conformance/expression_templates").join(dir)
}

/// Option-B load: resolve_template_machinery + lower_expression_templates
/// (surviving references preserved). Mirrors the Julia `_load`.
fn load_b(dir: &str, fixture: &str) -> Result<Value, earthsci_ast::diagnostic::DiagnosticError> {
    let p = conf(dir);
    let src = std::fs::read_to_string(p.join(fixture)).expect("read fixture");
    let raw: Value = serde_json::from_str(&src).expect("parse fixture");
    let resolved = resolve_template_machinery(&raw, &p, &BTreeMap::new())?;
    let mut loaded = resolved.unwrap_or(raw);
    oob::lower_expression_templates(&mut loaded)?;
    Ok(loaded)
}

/// emit_esm_string(emit_document(raw, dir)). Mirrors the Julia `_emit`.
fn emit(dir: &str, fixture: &str) -> String {
    let p = conf(dir);
    let src = std::fs::read_to_string(p.join(fixture)).expect("read fixture");
    let raw: Value = serde_json::from_str(&src).expect("parse fixture");
    let doc = oob::emit_document(&raw, &p).expect("emit_document");
    oob::emit_esm_string(&doc)
}

/// Normalize numbers (integral float -> int) recursively for structural compare
/// (JSON3 reads `0.0` as `0`; serde_json keeps it a float). Mirrors `_normj`.
fn normj(v: &Value) -> Value {
    match v {
        Value::Number(n) => {
            if let Some(f) = n.as_f64()
                && !n.is_i64()
                && !n.is_u64()
                && f.is_finite()
                && f.fract() == 0.0
            {
                return Value::Number(serde_json::Number::from(f as i64));
            }
            v.clone()
        }
        Value::Array(a) => Value::Array(a.iter().map(normj).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), normj(x))).collect()),
        _ => v.clone(),
    }
}

fn is_apply(v: &Value) -> bool {
    v.get("op").and_then(|o| o.as_str()) == Some("apply_expression_template")
}

// ---------------------------------------------------------------------------
// BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(load(fixture)) is
// structurally equal to the existing expanded*.esm oracle. The 21 goldens are
// NOT regenerated — they are the Option-A image `expand` must reproduce.
// ---------------------------------------------------------------------------
#[test]
fn bridge_expand_equals_expanded_oracle() {
    let cases: &[(&str, &str, &str)] = &[
        ("aggregate_int_ratio_golden", "fixture.esm", "expanded.esm"),
        ("arrhenius_smoke", "fixture.esm", "expanded.esm"),
        ("constrained_match_scope", "fixture.esm", "expanded.esm"),
        ("coupling_transform_expression", "fixture.esm", "expanded.esm"),
        ("fixpoint_nested_deriv", "fixture.esm", "expanded.esm"),
        ("godunov_beats_inner_deriv", "fixture.esm", "expanded.esm"),
        ("import_diamond", "fixture.esm", "expanded.esm"),
        (
            "import_order_determinism",
            "fixture_import_order.esm",
            "expanded_import_order.esm",
        ),
        (
            "import_order_determinism",
            "fixture_priority_override.esm",
            "expanded_priority_override.esm",
        ),
        ("import_rebind_keyed_factors", "fixture.esm", "expanded.esm"),
        ("import_rename_diamond", "fixture.esm", "expanded.esm"),
        ("import_rename_two_instances", "fixture.esm", "expanded.esm"),
        ("import_smoke", "fixture.esm", "expanded.esm"),
        (
            "import_where_rename_two_instances",
            "fixture.esm",
            "expanded.esm",
        ),
        ("per_variable_scheme_literal_args", "fixture.esm", "expanded.esm"),
        ("scalar_field_param", "fixture.esm", "expanded.esm"),
        ("two_div_two_meshes", "fixture.esm", "expanded.esm"),
    ];
    for (dir, fix, gold) in cases {
        let mut loaded = load_b(dir, fix).unwrap_or_else(|e| panic!("[{dir}] load: {e}"));
        oob::expand(&mut loaded).unwrap_or_else(|e| panic!("[{dir}] expand: {e}"));
        let golden: Value =
            serde_json::from_str(&std::fs::read_to_string(conf(dir).join(gold)).unwrap()).unwrap();
        for key in ["models", "reaction_systems", "coupling", "index_sets"] {
            assert_eq!(
                loaded.get(key).map(normj),
                golden.get(key).map(normj),
                "[{dir}] bridge key {key} mismatch"
            );
        }
    }
}

/// Expand determinism (§9.6.4 rule 2) + non-destructive load: two expansions of
/// the same load are structurally identical, and the loaded view still carries
/// the surviving reference.
#[test]
fn expand_is_deterministic_and_load_non_destructive() {
    let loaded = load_b("import_smoke", "fixture.esm").unwrap();
    let mut a = loaded.clone();
    let mut b = loaded.clone();
    oob::expand(&mut a).unwrap();
    oob::expand(&mut b).unwrap();
    assert_eq!(normj(&a), normj(&b));
    // The un-expanded load still carries a makearray call site (surviving ref).
    let mk = &loaded["models"]["Advection"]["equations"][0]["rhs"]["args"][1];
    assert_eq!(mk["op"], "makearray");
}

// ---------------------------------------------------------------------------
// emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
// ---------------------------------------------------------------------------
#[test]
fn emit_materialized_registry_imports_gone_stencils_materialized() {
    let s = emit("emit_materialized_registry", "fixture.esm");
    assert_eq!(
        s,
        std::fs::read_to_string(conf("emit_materialized_registry").join("emitted.esm")).unwrap()
    );
    let doc: Value = serde_json::from_str(&s).unwrap();
    let adv = &doc["models"]["Advection"];
    assert_eq!(doc["esm"], "0.9.0"); // rule 8 version stamp
    assert!(adv.get("expression_template_imports").is_none()); // imports consumed
    let reg = adv["expression_templates"].as_object().unwrap();
    let keys: std::collections::HashSet<&str> = reg.keys().map(String::as_str).collect();
    assert_eq!(
        keys,
        ["central_D_lon_interior", "dlon_deg"]
            .into_iter()
            .collect()
    ); // match-less only; match rule not materialized
    // Call site intact: the makearray interior region is a surviving reference.
    let interior = &adv["equations"][0]["rhs"]["args"][1]["values"][0];
    assert!(is_apply(interior) && interior["name"] == "central_D_lon_interior");
}

// ---------------------------------------------------------------------------
// emit_rename_dotted_keys (§9.6.4 rule 5, §7.5.6 dotted keys)
// ---------------------------------------------------------------------------
#[test]
fn emit_rename_dotted_keys_on_disk() {
    let s = emit("emit_rename_dotted_keys", "fixture.esm");
    assert_eq!(
        s,
        std::fs::read_to_string(conf("emit_rename_dotted_keys").join("emitted.esm")).unwrap()
    );
    let doc: Value = serde_json::from_str(&s).unwrap();
    let reg = doc["models"]["TwoGrids"]["expression_templates"]
        .as_object()
        .unwrap();
    let keys: std::collections::HashSet<&str> = reg.keys().map(String::as_str).collect();
    assert_eq!(keys, ["fine.dx", "coarse.dx"].into_iter().collect());
    let isets: std::collections::HashSet<&str> =
        doc["index_sets"].as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(isets, ["fine.x", "coarse.x"].into_iter().collect());
}

// ---------------------------------------------------------------------------
// eager_target_bearing (§9.6.4 rule 3, §9.6.7): positive + negative.
// ---------------------------------------------------------------------------
#[test]
fn eager_target_bearing_positive_and_negative() {
    let loaded = load_b("eager_target_bearing", "fixture.esm").unwrap();
    let vars = &loaded["models"]["m"]["variables"];
    // POSITIVE: deriv_c (D-bearing) reference eagerly expanded, then the D
    // lowered by the `central` rule -> an aggregate. No surviving reference.
    let deager = normj(&vars["d_eager"]["expression"]);
    assert_eq!(deager["op"], "index");
    assert_eq!(deager["args"][0]["op"], "aggregate");
    // NEGATIVE: scale_c (target-free) reference SURVIVES.
    let dsurv = normj(&vars["d_survive"]["expression"]);
    assert!(is_apply(&dsurv["args"][0]) && dsurv["args"][0]["name"] == "scale_c");
    // Emit golden.
    assert_eq!(
        emit("eager_target_bearing", "fixture.esm"),
        std::fs::read_to_string(conf("eager_target_bearing").join("emitted.esm")).unwrap()
    );
}

// ---------------------------------------------------------------------------
// opacity_negative (§9.6.4 rule 4): compound pattern MUST NOT fire across a
// surviving-reference boundary.
// ---------------------------------------------------------------------------
#[test]
fn opacity_negative_compound_does_not_see_through_reference() {
    let loaded = load_b("opacity_negative", "fixture.esm").unwrap();
    let flux = normj(&loaded["models"]["m"]["variables"]["flux"]["expression"]);
    assert_eq!(flux["op"], "D"); // compound did NOT fire (no marker 999)
    assert!(is_apply(&flux["args"][0])); // its arg is the surviving reference
    assert_eq!(flux["args"][0]["name"], "flux_prod");
    assert_eq!(
        emit("opacity_negative", "fixture.esm"),
        std::fs::read_to_string(conf("opacity_negative").join("emitted.esm")).unwrap()
    );
}

// ---------------------------------------------------------------------------
// opacity_priority_shadowing (§9.6.4 rule 4): the silent divergence — the
// high-priority compound rule does NOT fire; a lower-priority generic rule
// DOES, binding the surviving reference whole.
// ---------------------------------------------------------------------------
#[test]
fn opacity_priority_shadowing_generic_fires_compound_silently_does_not() {
    let loaded = load_b("opacity_priority_shadowing", "fixture.esm").unwrap();
    let flux = normj(&loaded["models"]["m"]["variables"]["flux"]["expression"]);
    assert_eq!(flux["op"], "*");
    assert_eq!(flux["args"][0], 1); // generic marker (NOT compound 999)
    assert!(is_apply(&flux["args"][1])); // reference bound WHOLE by metavariable f
    assert_eq!(flux["args"][1]["name"], "flux_prod");
    assert_eq!(
        emit("opacity_priority_shadowing", "fixture.esm"),
        std::fs::read_to_string(conf("opacity_priority_shadowing").join("emitted.esm")).unwrap()
    );
}

// ---------------------------------------------------------------------------
// per_instantiation_validation (§9.6.9): manifold param, two call sites, one
// inadmissible -> geometry_manifold_invalid naming the call site.
// ---------------------------------------------------------------------------
#[test]
fn per_instantiation_validation_names_call_site() {
    let err = load_b("per_instantiation_validation", "fixture.esm").expect_err("must reject");
    assert_eq!(err.code, "geometry_manifold_invalid");
    assert!(err.message.contains("area_bad"), "call site: {}", err.message);
    assert!(err.message.contains("overlap"), "template: {}", err.message);
}

// ---------------------------------------------------------------------------
// flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
// ---------------------------------------------------------------------------
#[test]
fn flatten_registry_merge_dedup_and_collision_rename() {
    let loaded = load_b("flatten_registry_merge", "fixture.esm").unwrap();
    let (root, merged) = oob::flatten_template_registries(&loaded);
    let keys: std::collections::HashSet<&str> = merged.keys().map(String::as_str).collect();
    assert_eq!(keys, ["sten", "A.s", "B.s"].into_iter().collect());
    assert_eq!(
        normj(&merged["sten"]["body"]),
        serde_json::json!({"op": "*", "args": [2, "f"]})
    );
    // references rewritten in lockstep
    assert_eq!(root["models"]["A"]["variables"]["za"]["expression"]["name"], "A.s");
    assert_eq!(root["models"]["B"]["variables"]["zb"]["expression"]["name"], "B.s");
    assert_eq!(root["models"]["A"]["variables"]["ya"]["expression"]["name"], "sten");
    assert_eq!(root["models"]["B"]["variables"]["yb"]["expression"]["name"], "sten");
    // per-component blocks surrendered to the merged registry
    assert!(root["models"]["A"].get("expression_templates").is_none());
    assert!(root["models"]["B"].get("expression_templates").is_none());
}

// ---------------------------------------------------------------------------
// Idempotency property (RFC §12 gate 2): emit ∘ load is a byte-wise fixed
// point. Runs over EVERY conformance `fixture*.esm` that emits successfully
// (error fixtures are skipped by construction — they never emit).
// ---------------------------------------------------------------------------
#[test]
fn emit_load_byte_wise_fixed_point_all_fixtures() {
    let base = common::repo_fixture("conformance/expression_templates");
    let mut checked = 0usize;
    for entry in std::fs::read_dir(&base).expect("read conformance dir") {
        let dir = entry.unwrap().path();
        if !dir.is_dir() {
            continue;
        }
        let dname = dir.file_name().unwrap().to_string_lossy().to_string();
        for f in std::fs::read_dir(&dir).unwrap() {
            let fp = f.unwrap().path();
            let fname = fp.file_name().unwrap().to_string_lossy().to_string();
            if !(fname.starts_with("fixture") && fname.ends_with(".esm")) {
                continue;
            }
            let src = std::fs::read_to_string(&fp).unwrap();
            let raw: Value = match serde_json::from_str(&src) {
                Ok(v) => v,
                Err(_) => continue,
            };
            // First emit; if the fixture is an error/invalid fixture it will
            // fail to load — skip it (idempotency is a property of emittable
            // documents).
            let s1 = match oob::emit_document(&raw, &dir) {
                Ok(d) => oob::emit_esm_string(&d),
                Err(_) => continue,
            };
            let raw2: Value = serde_json::from_str(&s1).expect("re-parse emitted");
            let s2 = oob::emit_esm_string(
                &oob::emit_document(&raw2, &dir).expect("re-emit emitted document"),
            );
            assert_eq!(s1, s2, "idempotency failed for {dname}/{fname}");
            checked += 1;
        }
    }
    assert!(checked >= 15, "expected many emittable fixtures, got {checked}");
}
