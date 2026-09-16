//! `${VAR}` expansion in a `ref` (esm-spec §4.7).
//!
//! Expansion is an OPTIONAL capability. The spec fixes three things about it:
//! only the braced form expands, an unset variable is left literal so the ref
//! fails with the ordinary unresolved diagnostic instead of misresolving, and
//! the capability applies to subsystem refs and template-import refs alike.

/// The importing document, pointing at the shared library in `tests/valid`
/// through `var`. Written to a temp directory so that no `${VAR}` fixture
/// enters the shared corpus: the bindings that do not implement expansion
/// (Go, TypeScript) must keep sweeping that corpus clean.
fn importer(var: &str) -> String {
    format!(
        r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "env_var_ref_importer", "description": "Imports a template library through a ${{VAR}} ref (esm-spec 4.7)." }},
  "models": {{ "M": {{
    "expression_template_imports": [ {{ "ref": "${{{var}}}/template_import_lib.esm" }} ],
    "variables": {{ "x": {{ "type": "unknown", "units": "1", "default": 1.0 }},
                   "y": {{ "type": "unknown", "units": "1" }} }},
    "equations": [ {{ "lhs": {{ "op": "D", "args": ["x"], "wrt": "t" }}, "rhs": {{ "op": "-", "args": ["x"] }} }},
                   {{ "lhs": "y", "rhs": {{ "op": "scale_by_n", "args": ["x"] }} }} ]
  }} }}
}}"#
    )
}

#[test]
fn a_braced_env_var_expands_in_a_template_import_ref_and_an_unset_one_stays_literal() {
    const VAR: &str = "ESM_TEST_TEMPLATE_LIB_DIR";
    let valid = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/valid");
    assert!(
        valid.join("template_import_lib.esm").is_file(),
        "the shared library fixture must exist for this test to mean anything"
    );

    let dir = std::env::temp_dir().join(format!("esm_env_var_refs_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let doc = dir.join("importer.esm");
    std::fs::write(&doc, importer(VAR)).expect("write importer");

    // SAFETY: this test owns the variable — the name is unique to it, and it is
    // restored before returning. Reading an env var is what expansion does.
    unsafe { std::env::remove_var(VAR) };
    let unset = earthsci_ast::load_path(&doc).expect_err("an unset ${VAR} cannot resolve");
    let message = format!("{unset}");
    assert!(
        message.contains(&format!("${{{VAR}}}")),
        "an unset variable stays literal so the ref fails unresolved, got: {message}"
    );

    unsafe { std::env::set_var(VAR, &valid) };
    earthsci_ast::load_path(&doc).expect("a set ${VAR} expands and the library resolves");
    unsafe { std::env::remove_var(VAR) };

    std::fs::remove_dir_all(&dir).ok();
}
