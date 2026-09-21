//! Coupling-library files and `coupling_import` role binding (esm-spec
//! §10.9–§10.11). Rust port of the TypeScript reference
//! `coupling-imports.test.ts`: detection, import→edges expansion, equivalence
//! (an import and the equivalent inline edges flatten identically),
//! multiple-instantiation, and each of the §10.11 diagnostic codes.

use earthsci_ast::extension::diagnostic::DiagnosticError;
use earthsci_ast::{CouplingEntry, EsmFile};
use earthsci_ast::{CouplingImportOptions, expand_coupling_imports};
use earthsci_ast::{
    LoadOptions, flatten, flatten_with_options, is_coupling_library_doc, load_string_with_options,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// A coupling-library file: roles + role-scoped edges, no models/loaders.
fn lib() -> Value {
    json!({
        "esm": "1.0.0",
        "metadata": { "name": "RothermelFuelCoupling" },
        "coupling_roles": {
            "Fuel": { "description": "fuel-property source" },
            "Spread": { "description": "Rothermel spread model" }
        },
        "coupling": [
            { "type": "variable_map", "from": "Fuel.sigma", "to": "Spread.sigma", "transform": "param_to_var" },
            { "type": "variable_map", "from": "Fuel.w_0", "to": "Spread.w0", "transform": "param_to_var" }
        ]
    })
}

/// An assembly mounting the two components the library wires.
fn assembly(coupling: Value) -> EsmFile {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": { "name": "wildfire" },
        "models": {
            "FuelModelLookup": {
                "variables": {
                    "sigma": { "type": "parameter", "units": "1/m", "default": 1 },
                    "w_0": { "type": "parameter", "units": "kg/m^2", "default": 1 }
                },
                "equations": []
            },
            "RothermelFireSpread": {
                "variables": {
                    "sigma": { "type": "parameter", "units": "1/m", "default": 0 },
                    "w0": { "type": "parameter", "units": "kg/m^2", "default": 0 }
                },
                "equations": []
            }
        },
        "coupling": coupling
    });
    serde_json::from_value(doc).expect("assembly deserializes")
}

/// Options whose `load_ref` returns `doc` for any ref.
fn opts_for(doc: Value) -> CouplingImportOptions<'static> {
    CouplingImportOptions {
        base_path: ".".to_string(),
        load_ref: Some(Box::new(move |_ref, _base| Ok(doc.clone()))),
    }
}

fn default_lib_opts() -> CouplingImportOptions<'static> {
    opts_for(lib())
}

fn err_code(r: Result<Option<Vec<CouplingEntry>>, DiagnosticError>) -> String {
    match r {
        Ok(_) => "NO_ERROR".to_string(),
        Err(e) => e.code.to_string(),
    }
}

fn import_entry(bind: Value) -> Value {
    json!([{ "type": "coupling_import", "ref": "lib.esm", "bind": bind }])
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

#[test]
fn identifies_a_coupling_library_by_top_level_coupling_roles() {
    assert!(is_coupling_library_doc(&lib()));
    assert!(!is_coupling_library_doc(
        &json!({ "esm": "1.0.0", "models": {} })
    ));
    assert!(!is_coupling_library_doc(&Value::Null));
}

// ---------------------------------------------------------------------------
// Expansion
// ---------------------------------------------------------------------------

#[test]
fn expands_an_import_into_library_edges_with_roles_substituted() {
    let file = assembly(import_entry(
        json!({ "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" }),
    ));
    let expanded = expand_coupling_imports(&file, &default_lib_opts())
        .expect("expansion succeeds")
        .expect("some coupling");
    let got = serde_json::to_value(&expanded).unwrap();
    assert_eq!(
        got,
        json!([
            { "type": "variable_map", "from": "FuelModelLookup.sigma", "to": "RothermelFireSpread.sigma", "transform": "param_to_var" },
            { "type": "variable_map", "from": "FuelModelLookup.w_0", "to": "RothermelFireSpread.w0", "transform": "param_to_var" }
        ])
    );
}

#[test]
fn leaves_a_file_without_import_entries_untouched() {
    let inline = json!([
        { "type": "variable_map", "from": "FuelModelLookup.sigma", "to": "RothermelFireSpread.sigma", "transform": "param_to_var" }
    ]);
    let file = assembly(inline.clone());
    // No options needed for the no-import path.
    let out = expand_coupling_imports(&file, &CouplingImportOptions::default())
        .expect("ok")
        .expect("some");
    assert_eq!(serde_json::to_value(&out).unwrap(), inline);
}

#[test]
fn supports_multiple_instantiation_with_different_binds() {
    let coupling = json!([
        { "type": "coupling_import", "ref": "lib.esm", "bind": { "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" } },
        { "type": "coupling_import", "ref": "lib.esm", "bind": { "Fuel": "RothermelFireSpread", "Spread": "FuelModelLookup" } }
    ]);
    let file = assembly(coupling);
    let expanded = expand_coupling_imports(&file, &default_lib_opts())
        .expect("ok")
        .expect("some");
    assert_eq!(expanded.len(), 4);
    let got = serde_json::to_value(&expanded).unwrap();
    assert_eq!(got[2]["from"], json!("RothermelFireSpread.sigma"));
    assert_eq!(got[2]["to"], json!("FuelModelLookup.sigma"));
}

// ---------------------------------------------------------------------------
// Flatten equivalence (esm-spec §10.10.3)
// ---------------------------------------------------------------------------

#[test]
fn import_and_equivalent_inline_edges_flatten_identically() {
    let imported = flatten_with_options(
        &assembly(import_entry(
            json!({ "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" }),
        )),
        &default_lib_opts(),
    )
    .expect("import flattens");

    let inline = flatten(&assembly(json!([
        { "type": "variable_map", "from": "FuelModelLookup.sigma", "to": "RothermelFireSpread.sigma", "transform": "param_to_var" },
        { "type": "variable_map", "from": "FuelModelLookup.w_0", "to": "RothermelFireSpread.w0", "transform": "param_to_var" }
    ])))
    .expect("inline flattens");

    // FlattenedSystem has no PartialEq; compare the serialized forms (mirrors
    // the TS `toEqual`): an import and the equivalent inline edges flatten
    // byte-identically.
    assert_eq!(
        serde_json::to_value(&imported).unwrap(),
        serde_json::to_value(&inline).unwrap()
    );
}

// ---------------------------------------------------------------------------
// Diagnostics (esm-spec §10.11)
// ---------------------------------------------------------------------------

#[test]
fn role_unbound_when_a_declared_role_has_no_bind() {
    let file = assembly(import_entry(json!({ "Fuel": "FuelModelLookup" })));
    assert_eq!(
        err_code(expand_coupling_imports(&file, &default_lib_opts())),
        "coupling_import_role_unbound"
    );
}

#[test]
fn unknown_role_when_a_bind_key_is_not_a_role() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Ghost": "FuelModelLookup"
    })));
    assert_eq!(
        err_code(expand_coupling_imports(&file, &default_lib_opts())),
        "coupling_import_unknown_role"
    );
}

#[test]
fn bind_not_a_component_when_a_bind_value_is_not_a_component() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "DoesNotExist"
    })));
    assert_eq!(
        err_code(expand_coupling_imports(&file, &default_lib_opts())),
        "coupling_import_bind_not_a_component"
    );
}

#[test]
fn not_library_when_the_ref_is_not_a_coupling_library() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"
    })));
    let opts = opts_for(json!({ "esm": "1.0.0", "metadata": { "name": "x" }, "models": {} }));
    assert_eq!(
        err_code(expand_coupling_imports(&file, &opts)),
        "coupling_import_not_library"
    );
}

#[test]
fn illegal_payload_when_the_library_declares_models() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"
    })));
    let mut bad = lib();
    bad["models"] = json!({});
    let opts = opts_for(bad);
    assert_eq!(
        err_code(expand_coupling_imports(&file, &opts)),
        "coupling_library_illegal_payload"
    );
}

#[test]
fn role_unused_when_a_declared_role_is_referenced_by_no_edge() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Extra": "FuelModelLookup"
    })));
    let mut extra = lib();
    extra["coupling_roles"]["Extra"] = json!({});
    let opts = opts_for(extra);
    assert_eq!(
        err_code(expand_coupling_imports(&file, &opts)),
        "coupling_role_unused"
    );
}

#[test]
fn edge_unknown_role_when_an_edge_references_an_undeclared_role() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"
    })));
    let mut ghost = lib();
    ghost["coupling"] = json!([
        { "type": "variable_map", "from": "Ghost.sigma", "to": "Spread.sigma", "transform": "param_to_var" }
    ]);
    let opts = opts_for(ghost);
    assert_eq!(
        err_code(expand_coupling_imports(&file, &opts)),
        "coupling_edge_unknown_role"
    );
}

#[test]
fn nested_import_when_the_library_contains_a_coupling_import() {
    let file = assembly(import_entry(json!({
        "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"
    })));
    let mut nested = lib();
    nested["coupling"] = json!([
        { "type": "coupling_import", "ref": "other.esm", "bind": {} }
    ]);
    let opts = opts_for(nested);
    assert_eq!(
        err_code(expand_coupling_imports(&file, &opts)),
        "coupling_library_nested_import"
    );
}

// ---------------------------------------------------------------------------
// Cross-kind gates: a coupling-library file is imported ONLY via a
// `coupling_import`, never mounted as a subsystem ref nor imported as a
// template library (esm-spec §10.9).
// ---------------------------------------------------------------------------

fn load_opts(dir: &std::path::Path) -> LoadOptions {
    LoadOptions {
        base_path: Some(dir.to_path_buf()),
        metaparameters: BTreeMap::new(),
    }
}

#[test]
fn subsystem_ref_targeting_a_coupling_library_is_rejected() {
    let dir = tempfile::TempDir::new().unwrap();
    std::fs::write(
        dir.path().join("clib.esm"),
        serde_json::to_string(&lib()).unwrap(),
    )
    .unwrap();
    let wrapper = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "t"
          },
          "models": {
            "M": {
              "variables": {
                "x": {
                  "type": "unknown",
                  "units": "1",
                  "default": 0.5
                }
              },
              "equations": [
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "x"
                    ],
                    "wrt": "t"
                  },
                  "rhs": {
                    "op": "-",
                    "args": [
                      "x"
                    ]
                  }
                }
              ],
              "subsystems": {
                "Sub": {
                  "ref": "clib.esm"
                }
              }
            }
          }
        }
        "#;
    let e = load_string_with_options(wrapper, &load_opts(dir.path()))
        .expect_err("subsystem ref to a coupling library must fail");
    assert!(
        e.to_string()
            .contains("[subsystem_ref_is_coupling_library]"),
        "got: {e}"
    );
}

#[test]
fn template_import_targeting_a_coupling_library_is_rejected() {
    let dir = tempfile::TempDir::new().unwrap();
    std::fs::write(
        dir.path().join("clib.esm"),
        serde_json::to_string(&lib()).unwrap(),
    )
    .unwrap();
    let wrapper = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "t"
          },
          "models": {
            "M": {
              "expression_template_imports": [
                {
                  "ref": "clib.esm"
                }
              ],
              "variables": {
                "x": {
                  "type": "unknown",
                  "units": "1",
                  "default": 0.5
                }
              },
              "equations": [
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "x"
                    ],
                    "wrt": "t"
                  },
                  "rhs": {
                    "op": "-",
                    "args": [
                      "x"
                    ]
                  }
                }
              ]
            }
          }
        }
        "#;
    let e = load_string_with_options(wrapper, &load_opts(dir.path()))
        .expect_err("template import of a coupling library must fail");
    assert!(
        e.to_string()
            .contains("[template_import_is_coupling_library]"),
        "got: {e}"
    );
}

#[test]
fn unresolved_when_the_ref_is_a_remote_url_under_the_default_loader() {
    // Default (filesystem) loader rejects http(s) refs as unresolved.
    let coupling = json!([{ "type": "coupling_import", "ref": "https://example.com/lib.esm", "bind": {
            "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"
        } }]);
    let file = assembly(coupling);
    assert_eq!(
        err_code(expand_coupling_imports(
            &file,
            &CouplingImportOptions::default()
        )),
        "coupling_import_unresolved"
    );
}

// ---------------------------------------------------------------------------
// Ref resolution base (esm-spec §10.10 -> §4.7)
// ---------------------------------------------------------------------------

/// The conformance corpus directory, from this crate's manifest.
fn coupling_corpus(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/coupling_libraries")
        .join(name)
}

/// A relative `coupling_import` `ref` names a file relative to the IMPORTING
/// document (§4.7 "Resolved relative to the directory of the referencing file"),
/// so `flatten` with default options must find `./rothermel_fuel.esm` next to
/// `assembly_import.esm` even though the test process runs in this crate's
/// directory, where no such file exists. Before the fix the import resolved
/// against the working directory and flatten failed with
/// `coupling_import_unresolved`.
#[test]
fn a_relative_import_resolves_against_the_importing_document_not_the_working_directory() {
    let import = earthsci_ast::load_path(coupling_corpus("assembly_import.esm"))
        .expect("assembly_import.esm loads");
    let inline = earthsci_ast::load_path(coupling_corpus("assembly_inline.esm"))
        .expect("assembly_inline.esm loads");
    assert!(
        !std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("rothermel_fuel.esm")
            .exists(),
        "the test is only meaningful if the library is NOT beside the working directory"
    );
    let imported = flatten(&import).expect("import flattens with default options");
    let expected = flatten(&inline).expect("inline flattens");
    assert_eq!(
        serde_json::to_value(&imported).unwrap(),
        serde_json::to_value(&expected).unwrap()
    );
}

/// The document's own base wins over an unrelated option, and the authored `ref`
/// round-trips verbatim (esm-spec §10.10.3): the base is recorded beside the
/// document, never written into the entry.
#[test]
fn a_loaded_documents_base_wins_and_its_ref_round_trips_verbatim() {
    let file = earthsci_ast::load_path(coupling_corpus("assembly_import.esm"))
        .expect("assembly_import.esm loads");
    flatten_with_options(
        &file,
        &CouplingImportOptions {
            base_path: "does/not/exist".to_string(),
            load_ref: None,
        },
    )
    .expect("the document's base wins over the option");
    let refs: Vec<&str> = file
        .coupling
        .as_ref()
        .expect("coupling present")
        .iter()
        .filter_map(|e| match e {
            CouplingEntry::CouplingImport { reference, .. } => Some(reference.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(refs, vec!["./rothermel_fuel.esm"]);
    let json = earthsci_ast::to_json(&file).expect("serializes");
    assert!(
        json.contains("\"./rothermel_fuel.esm\""),
        "authored ref lost on emit"
    );
    assert!(
        !json.contains("coupling_import_base"),
        "loader-only base leaked into the document"
    );
}

// ---------------------------------------------------------------------------
// Validation of imported edges and required targets (esm-spec §10.10.3)
// ---------------------------------------------------------------------------

/// A structurally complete `bind` that points a role at a component lacking a
/// referenced variable is reported by `validate` on the SOURCE document, not
/// only at flatten, and the finding names the import, role and component.
#[test]
fn validate_reports_a_mis_bound_import_on_the_source_document() {
    let file = earthsci_ast::load_path(coupling_corpus("import_misbind_downstream.esm"))
        .expect("import_misbind_downstream.esm loads");
    let result = earthsci_ast::validate(&file);
    let misbind = result
        .structural_errors
        .iter()
        .find(|e| {
            e.code.to_string() == "unresolved_scoped_ref"
                && e.details.get("coupling_import").is_some()
        })
        .unwrap_or_else(|| {
            panic!(
                "no import-attributed unresolved_scoped_ref in {:?}",
                result.structural_errors
            )
        });
    assert_eq!(misbind.details["bound_component"], "RothermelNoW0");
    assert!(
        misbind.details["reference"]
            .as_str()
            .unwrap()
            .ends_with(".w0")
    );
    assert!(!result.is_valid);
}

/// A coupling target declared without a `default` makes an omitted import an
/// error at build, naming the target (esm-spec §10.10.3, "Making an import
/// required"); a value supplied at run time still satisfies it, which is why
/// `validate` cannot reject the uncoupled parameter on its own.
#[test]
fn a_default_less_coupling_target_makes_an_omitted_import_an_error() {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": { "name": "required_target" },
        "models": {
            "FuelModelLookup": {
                "variables": { "sigma": { "type": "parameter", "units": "1/m", "default": 2 } },
                "equations": []
            },
            "Spread": {
                "variables": {
                    "sigma": { "type": "parameter", "units": "1/m" },
                    "r": { "type": "unknown", "units": "1/m", "default": 0 }
                },
                "equations": [ { "lhs": { "op": "D", "args": ["r"], "wrt": "t" }, "rhs": "sigma" } ]
            }
        },
        "coupling": []
    });
    let file = load_string_with_options(
        &doc.to_string(),
        &LoadOptions {
            base_path: None,
            metaparameters: BTreeMap::new(),
        },
    )
    .expect("loads");
    let opts = earthsci_ast::SolveOptions::default();
    let run = |p: std::collections::HashMap<String, f64>| {
        earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                p,
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    };
    match run(std::collections::HashMap::new()) {
        Err(earthsci_ast::SimulateError::InvalidParameter { name }) => {
            assert_eq!(name, "Spread.sigma")
        }
        other => panic!("expected InvalidParameter for the uncoupled target, got {other:?}"),
    }
    run(std::collections::HashMap::from([(
        "Spread.sigma".to_string(),
        2.0,
    )]))
    .expect("a run-time value satisfies the default-less target");
}

/// A document with no location of its own — built in memory, or parsed from a
/// string with no base — leaves [`CouplingImportOptions::base_path`] in charge,
/// and one given an explicit base at load anchors on it with no option at all.
/// All five bindings agree on this, so a caller's base is never silently
/// replaced by the working directory.
#[test]
fn an_in_memory_document_keeps_the_callers_base() {
    let corpus = coupling_corpus("assembly_import.esm");
    let dir = corpus
        .parent()
        .expect("corpus directory")
        .to_string_lossy()
        .into_owned();
    let text = std::fs::read_to_string(&corpus).expect("assembly_import.esm reads");
    let value: serde_json::Value = serde_json::from_str(&text).expect("parses");

    // No base of its own -> the option resolves the import.
    for file in [
        earthsci_ast::load_string(&text).expect("load_string"),
        earthsci_ast::load_document(&value).expect("load_document"),
    ] {
        flatten_with_options(
            &file,
            &CouplingImportOptions {
                base_path: dir.clone(),
                load_ref: None,
            },
        )
        .expect("the caller's base_path resolves the import");
    }

    // An explicit base of its own -> it wins, with no option at all.
    let opts = earthsci_ast::LoadOptions {
        base_path: Some(std::path::PathBuf::from(&dir)),
        ..Default::default()
    };
    for file in [
        earthsci_ast::load_string_with_options(&text, &opts).expect("load_string_with_options"),
        earthsci_ast::load_document_with_options(&value, &opts)
            .expect("load_document_with_options"),
    ] {
        flatten(&file).expect("the explicit load base resolves the import");
    }
}
