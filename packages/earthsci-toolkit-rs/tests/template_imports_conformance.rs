//! Conformance tests for esm-spec §9.7 — template-library files,
//! `expression_template_imports`, and load-time `metaparameters`
//! (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
//!
//! Mirrors the Julia reference suite
//! (`EarthSciSerialization.jl/test/template_imports_test.jl`): drives the
//! shared conformance fixtures under
//! `tests/conformance/expression_templates/` against the Julia-generated
//! goldens, the resolver-level invalid fixtures under
//! `tests/invalid/template_imports/` via `expected_errors.json`, and the
//! unit-level pinned semantics (exact 32/33 depth boundary, fold exactness,
//! expression-position substitution staying an AST, `only` visibility,
//! diamond bindings, the 0.8.0 version gate).

use earthsci_toolkit::lower_expression_templates::{
    MAX_TEMPLATE_EXPANSION_DEPTH, lower_expression_templates,
};
use earthsci_toolkit::template_imports::{
    reject_template_imports_pre_v08, resolve_template_machinery,
};
use earthsci_toolkit::types::Expr;
use earthsci_toolkit::{load_path, load_path_with_options, load_with_options, LoadOptions};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root from CARGO_MANIFEST_DIR")
        .to_path_buf()
}

fn conf(parts: &[&str]) -> PathBuf {
    let mut p = repo_root().join("tests/conformance/expression_templates");
    for part in parts {
        p = p.join(part);
    }
    p
}

/// Raw §9.7 pipeline (resolve → lower), mirroring the Julia golden
/// generator (`scripts/generate-template-import-goldens.jl`).
fn expand_raw(fixture_path: &Path) -> Value {
    let src = std::fs::read_to_string(fixture_path).expect("read fixture");
    let raw: Value = serde_json::from_str(&src).expect("parse fixture");
    let dir = fixture_path.parent().expect("fixture dir");
    let resolved = resolve_template_machinery(&raw, dir, &BTreeMap::new())
        .expect("resolve template machinery");
    let mut out = resolved.unwrap_or(raw);
    lower_expression_templates(&mut out).expect("lower to fixpoint");
    out
}

fn golden(path: &Path) -> Value {
    let src = std::fs::read_to_string(path).expect("read golden");
    serde_json::from_str(&src).expect("parse golden")
}

// ---------------------------------------------------------------------------
// Conformance fixture groups vs the Julia goldens
// ---------------------------------------------------------------------------

/// import_smoke: the normative §9.7.7 four-file layering (grid → interior
/// stencil → zero-gradient BC rule → consuming model binding
/// {NLON: 288, NLAT: 181} with `only`) expands to the committed golden.
#[test]
fn import_smoke_matches_golden() {
    assert_eq!(
        expand_raw(&conf(&["import_smoke", "fixture.esm"])),
        golden(&conf(&["import_smoke", "expanded.esm"]))
    );

    // Typed happy path: index sets merged and folded at the edge bindings.
    let f = load_path(conf(&["import_smoke", "fixture.esm"])).expect("typed load");
    let isets = f.index_sets.as_ref().expect("index_sets");
    assert_eq!(isets["lon"].size, Some(288));
    assert_eq!(isets["lat"].size, Some(181));
    // D(c, wrt: lon) lowered to the makearray rule body; D(c, wrt: t) not.
    let eq = &f.models.as_ref().expect("models")["Advection"].equations[0];
    let Expr::Operator(lhs) = &eq.lhs else {
        panic!("lhs must be an operator node");
    };
    assert_eq!(lhs.op, "D");
    let Expr::Operator(rhs) = &eq.rhs else {
        panic!("rhs must be an operator node");
    };
    let Expr::Operator(stencil) = &rhs.args[1] else {
        panic!("rhs.args[1] must be an operator node");
    };
    assert_eq!(stencil.op, "makearray");
}

/// import_diamond: grid_shared reaches the model twice (via lib_flux_a and
/// lib_flux_b, both unbound); the deep-equal duplicates dedup at first
/// occurrence (§9.7.4/§9.7.5) and NC closes by default (10) at the root.
#[test]
fn import_diamond_dedups_and_matches_golden() {
    assert_eq!(
        expand_raw(&conf(&["import_diamond", "fixture.esm"])),
        golden(&conf(&["import_diamond", "expanded.esm"]))
    );
    let f = load_path(conf(&["import_diamond", "fixture.esm"])).expect("typed load");
    assert_eq!(f.index_sets.as_ref().expect("index_sets")["cells"].size, Some(10));
}

/// import_order_determinism: equal-priority rules on the same pattern — the
/// winner is pinned by the effective declaration order (§9.7.4, depth-first
/// post-order = import array order), then flipped by explicit `priority`
/// (§9.6.3).
#[test]
fn import_order_pins_tie_break_and_priority_flips_it() {
    let d1 = expand_raw(&conf(&["import_order_determinism", "fixture_import_order.esm"]));
    assert_eq!(
        d1,
        golden(&conf(&["import_order_determinism", "expanded_import_order.esm"]))
    );
    let d2 = expand_raw(&conf(&[
        "import_order_determinism",
        "fixture_priority_override.esm",
    ]));
    assert_eq!(
        d2,
        golden(&conf(&[
            "import_order_determinism",
            "expanded_priority_override.esm"
        ]))
    );
    // Winner sanity, independent of the goldens: earlier import wins the
    // equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x).
    assert_eq!(d1["models"]["M"]["variables"]["y"]["expression"]["args"][0], json!(2));
    assert_eq!(d2["models"]["M"]["variables"]["y"]["expression"]["args"][0], json!(5));
}

// ---------------------------------------------------------------------------
// Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
// ---------------------------------------------------------------------------

/// import_rename_two_instances: the same grid library imported twice with
/// DIFFERENT `rename`/`prefix`, giving two distinct registrations that no longer
/// collide, expands to the committed golden.
#[test]
fn import_rename_two_instances_matches_golden() {
    assert_eq!(
        expand_raw(&conf(&["import_rename_two_instances", "fixture.esm"])),
        golden(&conf(&["import_rename_two_instances", "expanded.esm"]))
    );
}

/// import_where_rename_two_instances: a `where`-constrained div rule imported
/// twice under prefix has its `where.F.shape` rewritten x -> meshA.x / meshB.x
/// in lockstep with the index set, so each instance registers and fires only on
/// its own field. Without the rewrite this raised
/// template_constraint_unknown_index_set (§9.7.7 regression guard).
#[test]
fn import_where_rename_two_instances_matches_golden() {
    let d = expand_raw(&conf(&["import_where_rename_two_instances", "fixture.esm"]));
    assert_eq!(
        d,
        golden(&conf(&["import_where_rename_two_instances", "expanded.esm"]))
    );
    let vars = &d["models"]["TwoGrids"]["variables"];
    let va = &vars["div_A"]["expression"];
    let vb = &vars["div_B"]["expression"];
    assert_eq!(va["op"], "*"); // both div nodes lowered
    assert_eq!(vb["op"], "*");
    assert_eq!(va["args"][0]["op"], "/");
    assert_eq!(va["args"][0]["args"][1], 16);
    assert_eq!(vb["args"][0]["args"][1], 8);
    assert_eq!(va["args"][1], "F_A");
    assert_eq!(vb["args"][1], "F_B");
}

/// import_where_rename_unknown_index_set: a `where` shape naming a set the
/// library never declares survives the rename as spelled and is rejected at rule
/// registration — the fix does not paper over genuine typos.
#[test]
fn import_where_rename_unknown_index_set_rejected() {
    let e = load_path(conf(&["import_where_rename_unknown_index_set", "fixture.esm"]))
        .expect_err("bad where set must fail to load");
    let msg = e.to_string();
    assert!(
        msg.contains("[template_constraint_unknown_index_set]"),
        "got: {msg}"
    );
}

/// import_rebind_keyed_factors: `rebind` rewrites a free keyed-factor name in an
/// imported template body/registry, transitively through every occurrence.
#[test]
fn import_rebind_keyed_factors_matches_golden() {
    assert_eq!(
        expand_raw(&conf(&["import_rebind_keyed_factors", "fixture.esm"])),
        golden(&conf(&["import_rebind_keyed_factors", "expanded.esm"]))
    );
}

/// import_rename_diamond: a diamond import where each edge renames the shared
/// library differently, so the two arrive as distinct (non-deduped) names.
#[test]
fn import_rename_diamond_matches_golden() {
    assert_eq!(
        expand_raw(&conf(&["import_rename_diamond", "fixture.esm"])),
        golden(&conf(&["import_rename_diamond", "expanded.esm"]))
    );
}

// ---------------------------------------------------------------------------
// Spec pins: §4.7 subsystem index_sets merge, §4.3.2 makearray region bounds
// ---------------------------------------------------------------------------

/// §4.7 subsystem index-set merge: mounting `subsystem_mesh_lib.esm` merges its
/// top-level `index_sets` into the importing document's registry — the
/// deep-equal `cells` (size 5) is idempotent and the undeclared `vertices`
/// (size 4) is brought in.
#[test]
fn subsystem_index_sets_merge_into_document() {
    let valid = repo_root().join("tests/valid");
    let f = load_path(valid.join("subsystem_index_set_merge.esm")).expect("merge load");
    let isets = f.index_sets.as_ref().expect("index_sets");
    assert_eq!(isets["cells"].size, Some(5));
    assert_eq!(isets["vertices"].size, Some(4));

    // The mesh file also loads standalone as an ordinary single-model document.
    let mesh = load_path(valid.join("subsystem_mesh_lib.esm")).expect("mesh standalone load");
    let mesh_isets = mesh.index_sets.as_ref().expect("index_sets");
    assert_eq!(mesh_isets["cells"].size, Some(5));
    assert_eq!(mesh_isets["vertices"].size, Some(4));
}

/// §4.3.2 makearray region bounds: the empty bound `[start, start-1]` (here
/// `[2, N-1]` folding to `[2, 1]` at the default N = 2) loads clean; rebinding
/// N = 1 folds it to `[2, 0]`, INVERTED, rejected with `makearray_region_inverted`.
#[test]
fn makearray_empty_region_min_extent_and_inverted() {
    let path = repo_root().join("tests/valid/makearray_empty_region_min_extent.esm");
    // Default N = 2 → interior region [2, 1] (empty, legal): loads clean.
    load_path(&path).expect("empty min-extent region loads clean");

    // Loader-API N = 1 → interior region [2, 0] (inverted): rejected.
    let mut api = BTreeMap::new();
    api.insert("N".to_string(), 1i64);
    let e = load_path_with_options(&path, &api).expect_err("inverted region must be rejected");
    assert!(
        e.to_string().contains("[makearray_region_inverted]"),
        "got: {e}"
    );
}

// ---------------------------------------------------------------------------
// JSON float round-trip exactness (serde_json `float_roundtrip`)
// ---------------------------------------------------------------------------

/// A 16-17-significant-digit JSON float literal MUST parse to the SAME f64 bits
/// as `str::parse::<f64>` (the correctly-rounded nearest f64 Julia/Python
/// produce) and re-emit byte-identically. The default serde_json fast path is
/// 1 ulp off on these two literals — the `float_roundtrip` feature fixes it,
/// restoring AST byte identity on parse→emit for full-precision coordinates.
#[test]
fn json_float_literals_round_trip_bit_exact() {
    for lit in ["-104.52369275835723", "42.059133583516356"] {
        let v: Value = serde_json::from_str(lit).expect("parse float literal");
        let parsed = v.as_f64().expect("f64");
        let truth: f64 = lit.parse().expect("std parse");
        assert_eq!(
            parsed.to_bits(),
            truth.to_bits(),
            "{lit}: serde_json parsed {parsed:?} (bits {:016x}), std parses {truth:?} (bits {:016x})",
            parsed.to_bits(),
            truth.to_bits()
        );
        assert_eq!(
            serde_json::to_string(&v).expect("re-emit"),
            lit,
            "{lit} must re-emit byte-identically"
        );
    }

    // End-to-end through the crate load→emit: a const carrying the full-precision
    // coordinates survives parse→emit verbatim (AST byte identity).
    let doc = format!(
        r#"{{
      "esm": "0.8.0",
      "metadata": {{"name": "ulp"}},
      "models": {{"M": {{
        "variables": {{
          "x": {{"type": "state", "units": "1", "default": 0.5}},
          "pt": {{"type": "observed", "units": "1",
                  "expression": {{"op": "const", "args": [],
                                 "value": [-104.52369275835723, 42.059133583516356]}}}}
        }},
        "equations": [{{"lhs": {{"op": "D", "args": ["x"], "wrt": "t"}},
                       "rhs": {{"op": "-", "args": ["x"]}}}}]
      }}}}
    }}"#
    );
    let f = earthsci_toolkit::load(&doc).expect("load ulp doc");
    let text = earthsci_toolkit::save(&f).expect("save ulp doc");
    assert!(
        text.contains("-104.52369275835723"),
        "longitude literal must survive verbatim: {text}"
    );
    assert!(
        text.contains("42.059133583516356"),
        "latitude literal must survive verbatim: {text}"
    );
}

/// metaparameter_resolutions: one problem file instantiated at N = 4 / 8 via
/// §4.7 subsystem-ref `bindings` (§9.7.6 binding site 3), compared against
/// the typed round-trip goldens.
#[test]
fn metaparameter_resolutions_via_subsystem_ref_bindings() {
    for (wrapper, golden_name, n) in [
        ("wrapper_n4.esm", "expanded_n4.esm", 4i64),
        ("wrapper_n8.esm", "expanded_n8.esm", 8i64),
    ] {
        let wrapper_path = conf(&["metaparameter_resolutions", wrapper]);
        // Raw pipeline: parse the wrapper and resolve its subsystem refs —
        // the §9.7 machinery of problem.esm closes with the edge bindings.
        let src = std::fs::read_to_string(&wrapper_path).expect("read wrapper");
        let mut v: Value = serde_json::from_str(&src).expect("parse wrapper");
        earthsci_toolkit::resolve_subsystem_refs(&mut v, wrapper_path.parent().unwrap())
            .expect("resolve subsystem refs");
        assert_eq!(v, golden(&conf(&["metaparameter_resolutions", golden_name])));

        // Typed anchors through the full load.
        let f = load_path(&wrapper_path).expect("typed load");
        let sweep = &f.models.as_ref().expect("models")["Sweep"];
        let problem = &sweep.subsystems.as_ref().expect("subsystems")["Problem"];
        // Expression position: bare "N" substituted as an integer literal.
        assert_eq!(problem["variables"]["npts"]["expression"], json!(n));
        // Expression-position division stays an AST division (no folding).
        assert_eq!(
            problem["variables"]["half"]["expression"],
            json!({"op": "/", "args": [n, 2]})
        );
        // Structural site: the aggregate dense range folded exactly.
        assert_eq!(
            problem["variables"]["ramp"]["expression"]["ranges"]["i"],
            json!([1, n / 2])
        );
    }
}

/// Loader-API bindings (§9.7.6 site 4) beat defaults (site 5); binding an
/// undeclared name is `template_import_unknown_name`.
#[test]
fn loader_api_bindings_and_defaults() {
    let problem = conf(&["metaparameter_resolutions", "problem.esm"]);
    let fdef = load_path(&problem).expect("default load");
    let models = fdef.models.as_ref().expect("models");
    let npts = models["Problem"].variables["npts"]
        .expression
        .as_ref()
        .expect("npts expression");
    assert_eq!(*npts, Expr::Integer(2)); // default

    let mut api = BTreeMap::new();
    api.insert("N".to_string(), 6i64);
    let fapi = load_path_with_options(&problem, &api).expect("API-bound load");
    let models = fapi.models.as_ref().expect("models");
    let npts = models["Problem"].variables["npts"]
        .expression
        .as_ref()
        .expect("npts expression");
    assert_eq!(*npts, Expr::Integer(6)); // API > default

    let mut bogus = BTreeMap::new();
    bogus.insert("Q".to_string(), 1i64);
    let e = load_path_with_options(&problem, &bogus).expect_err("unknown API binding");
    assert!(
        e.to_string().contains("[template_import_unknown_name]"),
        "got: {e}"
    );
}

/// The valid-suite fixtures: a model-less template-library document loads
/// clean (esm-spec §9.7.1) with its §9.7 constructs consumed, and the
/// minimal consumer lowers the imported match rule at load.
#[test]
fn valid_suite_library_and_minimal_consumer() {
    let valid = repo_root().join("tests/valid");
    let lib = load_path(valid.join("template_import_lib.esm")).expect("library load");
    assert!(lib.models.is_none());
    assert_eq!(lib.index_sets.as_ref().expect("index_sets")["cells"].size, Some(8));

    // Loader-API binding overrides the default on the library itself.
    let mut api = BTreeMap::new();
    api.insert("N".to_string(), 12i64);
    let lib12 =
        load_path_with_options(valid.join("template_import_lib.esm"), &api).expect("N=12 load");
    assert_eq!(lib12.index_sets.as_ref().expect("index_sets")["cells"].size, Some(12));

    let m = load_path(valid.join("template_import_minimal.esm")).expect("consumer load");
    assert_eq!(m.index_sets.as_ref().expect("index_sets")["cells"].size, Some(8));
    // scale_by_n(x) lowered by the imported match rule to x * 8 (the
    // zero-parameter n_cells body composed and N folded at registration).
    let y = m.models.as_ref().expect("models")["M"].variables["y"]
        .expression
        .as_ref()
        .expect("y expression");
    assert_eq!(
        serde_json::to_value(y).expect("serialize y"),
        json!({"op": "*", "args": ["x", 8]})
    );
}

/// Round-trip emits the expanded, folded form (§9.7.6): no §9.7 construct
/// survives parse → emit.
#[test]
fn round_trip_emits_expanded_folded_form() {
    let f = load_path(conf(&["import_smoke", "fixture.esm"])).expect("load");
    let text = earthsci_toolkit::save(&f).expect("save");
    assert!(!text.contains("expression_template_imports"));
    assert!(!text.contains("metaparameters"));
    assert!(!text.contains("expression_templates"));
    assert!(!text.contains("apply_expression_template"));
    let reloaded = earthsci_toolkit::load(&text).expect("reload");
    assert_eq!(
        reloaded.index_sets.as_ref().expect("index_sets")["lon"].size,
        Some(288)
    );
}

/// Every resolver-level invalid fixture fails with the exact stable
/// diagnostic code pinned in tests/invalid/expected_errors.json
/// (`resolver_error_code`). The codes are embedded as `[<code>]` in the
/// error string — the crate's established surfacing convention for
/// `ExpressionTemplateError` through `load()`.
#[test]
fn invalid_fixtures_fail_with_exact_codes() {
    let invalid_dir = repo_root().join("tests/invalid/template_imports");
    let expected: Value = serde_json::from_str(
        &std::fs::read_to_string(repo_root().join("tests/invalid/expected_errors.json"))
            .expect("read expected_errors.json"),
    )
    .expect("parse expected_errors.json");

    let mut fixtures: Vec<PathBuf> = std::fs::read_dir(&invalid_dir)
        .expect("read invalid dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "esm"))
        .collect();
    fixtures.sort();
    assert!(!fixtures.is_empty());

    let mut seen_codes: std::collections::HashSet<String> = std::collections::HashSet::new();
    for fixture in &fixtures {
        let fname = fixture.file_name().unwrap().to_string_lossy().into_owned();
        let entry = expected
            .get(&fname)
            .unwrap_or_else(|| panic!("expected_errors.json entry for {fname}"));
        assert_eq!(entry["resolver_only"], json!(true), "{fname}");
        let want = entry["resolver_error_code"]
            .as_str()
            .unwrap_or_else(|| panic!("resolver_error_code for {fname}"));
        let e = load_path(fixture).expect_err(&format!("{fname} must fail to load"));
        let msg = e.to_string();
        assert!(
            msg.contains(&format!("[{want}]")),
            "{fname}: expected code [{want}], got: {msg}"
        );
        seen_codes.insert(want.to_string());
    }
    // The fixture set exercises the full §9.6.6 §9.7 code table (the 12th,
    // template_import_unresolved, is exercised in the unit tests below — a
    // missing file is not representable as a fixture).
    for code in [
        "template_import_version_too_old",
        "template_import_not_library",
        "subsystem_ref_is_template_library",
        "template_import_cycle",
        "template_import_name_conflict",
        "template_import_unknown_name",
        "template_import_index_set_conflict",
        "apply_expression_template_recursive_body",
        "template_body_expansion_too_deep",
        "metaparameter_unbound",
        "metaparameter_type_error",
        "metaparameter_name_conflict",
    ] {
        assert!(seen_codes.contains(code), "code not exercised: {code}");
    }
}

// ---------------------------------------------------------------------------
// Unit-level behavior over generated files
// ---------------------------------------------------------------------------

fn model_json(extra_model_fields: &str, top_fields: &str) -> String {
    format!(
        r#"{{
  "esm": "0.8.0",
  "metadata": {{"name": "t"}},{top_fields}
  "models": {{
    "M": {{{extra_model_fields}
      "variables": {{"x": {{"type": "state", "units": "1", "default": 0.5}}}},
      "equations": [{{"lhs": {{"op": "D", "args": ["x"], "wrt": "t"}},
                     "rhs": {{"op": "-", "args": ["x"]}}}}]
    }}
  }}
}}"#
    )
}

fn load_in(dir: &Path, text: &str) -> Result<earthsci_toolkit::EsmFile, earthsci_toolkit::EsmError>
{
    let options = LoadOptions {
        base_path: Some(dir.to_path_buf()),
        metaparameters: BTreeMap::new(),
    };
    load_with_options(text, &options)
}

fn load_err_code(dir: &Path, text: &str) -> String {
    let e = load_in(dir, text).expect_err("load must fail");
    e.to_string()
}

#[test]
fn unresolved_missing_and_unparsable_refs() {
    let dir = tempfile::TempDir::new().unwrap();
    let msg = load_err_code(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [{"ref": "./nope.esm"}],"#,
            "",
        ),
    );
    assert!(msg.contains("[template_import_unresolved]"), "got: {msg}");

    std::fs::write(dir.path().join("junk.esm"), "{not json").unwrap();
    let msg = load_err_code(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [{"ref": "./junk.esm"}],"#,
            "",
        ),
    );
    assert!(msg.contains("[template_import_unresolved]"), "got: {msg}");
}

#[test]
fn only_filters_visibility_not_internal_wiring() {
    let dir = tempfile::TempDir::new().unwrap();
    std::fs::write(
        dir.path().join("lib.esm"),
        serde_json::to_string(&json!({
            "esm": "0.8.0",
            "metadata": {"name": "lib"},
            "expression_templates": {
                "t_inner": {"params": [], "body": 7},
                "t_keep": {"params": [], "body": {"op": "*", "args": [2,
                    {"op": "apply_expression_template", "args": [], "name": "t_inner", "bindings": {}}]}},
                "t_drop": {"params": [], "body": 9}
            }
        }))
        .unwrap(),
    )
    .unwrap();

    // t_keep's body reference to t_inner resolved in the LIBRARY's own
    // scope, so importing only t_keep still yields 2 * 7.
    let raw: Value = serde_json::from_str(&model_json(
        r#"
      "expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],"#,
        "",
    ))
    .unwrap();
    let resolved = resolve_template_machinery(&raw, dir.path(), &BTreeMap::new())
        .expect("resolve")
        .expect("machinery present");
    let tpl = &resolved["models"]["M"]["expression_templates"];
    let names: Vec<&String> = tpl.as_object().unwrap().keys().collect();
    assert_eq!(names, vec!["t_keep"]);
    assert_eq!(tpl["t_keep"]["body"], json!({"op": "*", "args": [2, 7]}));

    // Referencing a filtered-out name from an expression position fails.
    let msg = load_err_code(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],
      "expression_templates": {"local_uses_drop": {"params": [],
        "body": {"op": "apply_expression_template", "args": [], "name": "t_drop", "bindings": {}}}},"#,
            "",
        ),
    );
    assert!(
        msg.contains("[apply_expression_template_unknown_template]"),
        "got: {msg}"
    );
}

#[test]
fn diamond_with_conflicting_edge_bindings_is_rejected() {
    let dir = tempfile::TempDir::new().unwrap();
    std::fs::write(
        dir.path().join("grid.esm"),
        serde_json::to_string(&json!({
            "esm": "0.8.0",
            "metadata": {"name": "grid"},
            "metaparameters": {"NC": {"type": "integer"}},
            "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
            "expression_templates": {"nc": {"params": [], "body": "NC"}}
        }))
        .unwrap(),
    )
    .unwrap();

    let msg = load_err_code(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [
        {"ref": "./grid.esm", "bindings": {"NC": 4}},
        {"ref": "./grid.esm", "bindings": {"NC": 8}}],"#,
            "",
        ),
    );
    assert!(
        msg.contains("[template_import_name_conflict]")
            || msg.contains("[template_import_index_set_conflict]"),
        "got: {msg}"
    );

    // Equal instantiation on both edges dedups cleanly.
    let f = load_in(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [
        {"ref": "./grid.esm", "bindings": {"NC": 4}},
        {"ref": "./grid.esm", "bindings": {"NC": 4}}],"#,
            "",
        ),
    )
    .expect("equal diamond loads");
    assert_eq!(f.index_sets.as_ref().expect("index_sets")["cells"].size, Some(4));
}

#[test]
fn edge_bindings_unknown_names_and_non_integer_values() {
    let dir = tempfile::TempDir::new().unwrap();
    std::fs::write(
        dir.path().join("lib.esm"),
        serde_json::to_string(&json!({
            "esm": "0.8.0",
            "metadata": {"name": "lib"},
            "metaparameters": {"N": {"type": "integer", "default": 8}},
            "expression_templates": {"n": {"params": [], "body": "N"}}
        }))
        .unwrap(),
    )
    .unwrap();

    let msg = load_err_code(
        dir.path(),
        &model_json(
            r#"
      "expression_template_imports": [{"ref": "./lib.esm", "bindings": {"Q": 1}}],"#,
            "",
        ),
    );
    assert!(msg.contains("[template_import_unknown_name]"), "got: {msg}");

    // A non-integer binding is rejected at the resolver level
    // (metaparameter_type_error); the schema also rejects it in the full
    // load() pipeline (TemplateImport.bindings is integer-typed).
    let raw: Value = serde_json::from_str(&model_json(
        r#"
      "expression_template_imports": [{"ref": "./lib.esm", "bindings": {"N": 2.5}}],"#,
        "",
    ))
    .unwrap();
    let e = resolve_template_machinery(&raw, dir.path(), &BTreeMap::new())
        .expect_err("non-integer binding");
    assert_eq!(e.code, "metaparameter_type_error");
}

#[test]
fn metaparameter_fold_ranges_regions_size_exact() {
    let dir = tempfile::TempDir::new().unwrap();
    let f = load_in(
        dir.path(),
        r#"
    {
      "esm": "0.8.0",
      "metadata": {"name": "fold"},
      "metaparameters": {"N": {"type": "integer", "default": 6}},
      "index_sets": {"cells": {"kind": "interval", "size": {"op": "*", "args": ["N", 2]}}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "agg": {"type": "observed", "units": "1",
              "expression": {"op": "aggregate", "output_idx": ["i"], "args": ["x"],
                "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                "expr": {"op": "*", "args": ["x", "i"]}}},
            "ma": {"type": "observed", "units": "1",
              "expression": {"op": "makearray", "args": [],
                "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                "values": [1.5]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }
    "#,
    )
    .expect("fold load");
    assert_eq!(f.index_sets.as_ref().expect("index_sets")["cells"].size, Some(12));
    let m = &f.models.as_ref().expect("models")["M"];
    let agg = serde_json::to_value(m.variables["agg"].expression.as_ref().unwrap()).unwrap();
    assert_eq!(agg["ranges"]["i"], json!([1, 5]));
    let ma = serde_json::to_value(m.variables["ma"].expression.as_ref().unwrap()).unwrap();
    assert_eq!(ma["regions"], json!([[[3, 6]]]));
}

#[test]
fn inexact_division_and_unbound_metaparameters_rejected() {
    let dir = tempfile::TempDir::new().unwrap();
    let msg = load_err_code(
        dir.path(),
        &model_json(
            "",
            r#"
  "metaparameters": {"NX": {"type": "integer", "default": 5}},
  "index_sets": {"half": {"kind": "interval", "size": {"op": "/", "args": ["NX", 2]}}},"#,
        ),
    );
    assert!(msg.contains("[metaparameter_type_error]"), "got: {msg}");

    let msg = load_err_code(
        dir.path(),
        &model_json(
            "",
            r#"
  "metaparameters": {"NX": {"type": "integer"}},"#,
        ),
    );
    assert!(msg.contains("[metaparameter_unbound]"), "got: {msg}");
}

#[test]
fn expression_position_substitution_never_folds() {
    let dir = tempfile::TempDir::new().unwrap();
    let f = load_in(
        dir.path(),
        r#"
    {
      "esm": "0.8.0",
      "metadata": {"name": "subst"},
      "metaparameters": {"N": {"type": "integer", "default": 144}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "dlon": {"type": "observed", "units": "1",
                     "expression": {"op": "/", "args": [360, "N"]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }
    "#,
    )
    .expect("subst load");
    let dlon = f.models.as_ref().expect("models")["M"].variables["dlon"]
        .expression
        .as_ref()
        .unwrap();
    assert_eq!(
        serde_json::to_value(dlon).unwrap(),
        json!({"op": "/", "args": [360, 144]})
    );
}

fn chain_doc(n: usize) -> Value {
    let mut tpl = serde_json::Map::new();
    for i in 1..=n {
        let name = format!("c_{i:02}");
        let decl = if i == n {
            json!({"params": [], "body": 1})
        } else {
            json!({"params": [], "body": {
                "op": "apply_expression_template", "args": [],
                "name": format!("c_{:02}", i + 1), "bindings": {}}})
        };
        tpl.insert(name, decl);
    }
    json!({
        "esm": "0.8.0",
        "metadata": {"name": "chain"},
        "models": {"M": {
            "expression_templates": Value::Object(tpl),
            "variables": {"x": {"type": "state", "default": 0.5}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "-", "args": ["x"]}}]
        }}
    })
}

#[test]
fn body_composition_inlines_and_depth_bound_is_exact() {
    // A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
    let mut doc = json!({
        "esm": "0.8.0",
        "metadata": {"name": "chain3"},
        "models": {"M": {
            "expression_templates": {
                "c1": {"params": [], "body": {"op": "+", "args": [1,
                    {"op": "apply_expression_template", "args": [], "name": "c2", "bindings": {}}]}},
                "c2": {"params": [], "body": {"op": "+", "args": [2,
                    {"op": "apply_expression_template", "args": [], "name": "c3", "bindings": {}}]}},
                "c3": {"params": [], "body": 3}
            },
            "variables": {"x": {"type": "state", "units": "1", "default": 0.5},
                          "y": {"type": "observed", "units": "1",
                                "expression": {"op": "apply_expression_template",
                                               "args": [], "name": "c1", "bindings": {}}}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "-", "args": ["x"]}}]
        }}
    });
    lower_expression_templates(&mut doc).expect("lower");
    assert_eq!(
        doc["models"]["M"]["variables"]["y"]["expression"],
        json!({"op": "+", "args": [1, {"op": "+", "args": [2, 3]}]})
    );

    // Exactly MAX_TEMPLATE_EXPANSION_DEPTH templates chain: accepted; one
    // more: template_body_expansion_too_deep (the shared generated fixture
    // pins the reject side; this pins the boundary).
    let mut ok = chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH);
    lower_expression_templates(&mut ok).expect("32-template chain accepted");
    let mut too_deep = chain_doc(MAX_TEMPLATE_EXPANSION_DEPTH + 1);
    let e = lower_expression_templates(&mut too_deep).expect_err("33-template chain rejected");
    assert_eq!(e.code, "template_body_expansion_too_deep");

    // A body may not reference a `match` rule by name.
    let mut match_ref: Value = serde_json::from_str(&model_json(
        r#"
      "expression_templates": {
        "rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                 "body": {"op": "*", "args": [2, "f"]}},
        "uses_rule": {"params": [], "body": {"op": "apply_expression_template",
                      "args": [], "name": "rule", "bindings": {"f": 1}}}
      },"#,
        "",
    ))
    .unwrap();
    let e = lower_expression_templates(&mut match_ref).expect_err("match rule not invocable");
    assert_eq!(e.code, "apply_expression_template_unknown_template");

    // A `match` pattern may not contain apply nodes.
    let mut match_with_apply: Value = serde_json::from_str(&model_json(
        r#"
      "expression_templates": {
        "frag": {"params": [], "body": 1},
        "rule": {"params": ["f"],
                 "match": {"op": "lowerme", "args": [{"op": "apply_expression_template",
                           "args": [], "name": "frag", "bindings": {}}]},
                 "body": {"op": "*", "args": [2, "f"]}}
      },"#,
        "",
    ))
    .unwrap();
    let e = lower_expression_templates(&mut match_with_apply).expect_err("apply in match pattern");
    assert_eq!(e.code, "apply_expression_template_invalid_declaration");
}

#[test]
fn version_gate_flags_every_9_7_construct() {
    for snippet in [
        r#""metaparameters": {"N": {"type": "integer"}},"#,
        r#""expression_templates": {"t": {"params": [], "body": 1}},"#,
    ] {
        let doc: Value = serde_json::from_str(&format!(
            r#"{{"esm": "0.7.0", "metadata": {{"name": "old"}},{snippet}
             "models": {{"M": {{"variables": {{"x": {{"type": "state", "default": 0.5}}}},
                              "equations": []}}}}}}"#
        ))
        .unwrap();
        let e = reject_template_imports_pre_v08(&doc).expect_err("pre-0.8.0 gate");
        assert_eq!(e.code, "template_import_version_too_old");
    }
    // 0.8.0 files pass the gate.
    let ok: Value = serde_json::from_str(
        r#"{"esm": "0.8.0", "metadata": {"name": "new"},
            "metaparameters": {"N": {"type": "integer", "default": 1}},
            "expression_templates": {"t": {"params": [], "body": 1}}}"#,
    )
    .unwrap();
    reject_template_imports_pre_v08(&ok).expect("0.8.0 passes");
}
