//! `${VAR}` expansion in a `ref` (esm-spec §4.7, and §10.10 for a
//! `coupling_import` ref).
//!
//! Expansion is an OPTIONAL capability. The spec fixes three things about it:
//! only the braced form with a C-identifier name expands, an unset variable is
//! left literal so the ref fails with the ordinary unresolved diagnostic
//! instead of misresolving, and the capability applies to subsystem refs,
//! template-import refs and coupling-import refs alike.
//!
//! `std::env::set_var` mutates process-global state, so every test here takes
//! `ENV_LOCK` for the whole window in which a variable is set and a document is
//! loaded. Nothing else in this binary reads the environment outside that lock,
//! so the loads cannot observe another test's variable.

use earthsci_ast::{CouplingEntry, CouplingImportOptions, EsmFile, expand_coupling_imports};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn env_lock() -> MutexGuard<'static, ()> {
    ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// Set `name` for the lifetime of the returned guard, then remove it.
///
/// SAFETY: the caller holds `ENV_LOCK`, so no other test in this binary reads
/// or writes the environment concurrently.
struct EnvVar(&'static str);

impl EnvVar {
    fn set(name: &'static str, value: &str) -> Self {
        unsafe { std::env::set_var(name, value) };
        Self(name)
    }
}

impl Drop for EnvVar {
    fn drop(&mut self) {
        unsafe { std::env::remove_var(self.0) };
    }
}

/// The shared `tests/valid` directory, which holds `template_import_lib.esm`.
fn valid_dir() -> std::path::PathBuf {
    let d = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/valid");
    assert!(
        d.join("template_import_lib.esm").is_file(),
        "the shared library fixture must exist for these tests to mean anything"
    );
    d
}

/// A document importing the shared template library through `import_ref`.
///
/// Written to a temp directory rather than added to `tests/valid`: the shared
/// corpus is swept by every binding and must stay free of documents that need a
/// particular environment to resolve.
fn importer(import_ref: &str) -> String {
    json!({
        "esm": "1.0.0",
        "metadata": { "name": "env_var_ref_importer",
                      "description": "Imports a template library through a ref (esm-spec 4.7)." },
        "models": { "M": {
            "expression_template_imports": [ { "ref": import_ref } ],
            "variables": { "x": { "type": "unknown", "units": "1", "default": 1.0 },
                           "y": { "type": "unknown", "units": "1" } },
            "equations": [
                { "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": { "op": "-", "args": ["x"] } },
                { "lhs": "y", "rhs": { "op": "scale_by_n", "args": ["x"] } }
            ]
        } }
    })
    .to_string()
}

/// Write `contents` into `dir` as `name` and return the path.
fn write(dir: &Path, name: &str, contents: &str) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, contents).expect("write fixture");
    p
}

#[test]
fn a_set_variable_expands_in_a_template_import_ref() {
    const VAR: &str = "ESM_RS_ENVREF_TEMPLATE_LIB_DIR";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    let doc = write(
        dir.path(),
        "importer.esm",
        &importer(&format!("${{{VAR}}}/template_import_lib.esm")),
    );

    let _var = EnvVar::set(VAR, valid_dir().to_str().expect("utf-8 path"));
    earthsci_ast::load_path(&doc).expect("a set ${VAR} expands and the library resolves");
}

#[test]
fn an_unset_variable_stays_literal_and_the_ref_fails_unresolved() {
    const VAR: &str = "ESM_RS_ENVREF_DEFINITELY_UNSET";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    let doc = write(
        dir.path(),
        "importer.esm",
        &importer(&format!("${{{VAR}}}/template_import_lib.esm")),
    );

    let message = format!(
        "{}",
        earthsci_ast::load_path(&doc).expect_err("an unset ${VAR} cannot resolve")
    );
    assert!(
        message.contains(&format!("${{{VAR}}}")),
        "an unset variable stays literal so the ref fails unresolved, got: {message}"
    );
}

#[test]
fn a_bare_dollar_form_is_not_expanded() {
    const VAR: &str = "ESM_RS_ENVREF_BARE_DOLLAR_DIR";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    // The variable IS set; only the braced form may expand (esm-spec §4.7).
    let doc = write(
        dir.path(),
        "importer.esm",
        &importer(&format!("${VAR}/template_import_lib.esm")),
    );

    let _var = EnvVar::set(VAR, valid_dir().to_str().expect("utf-8 path"));
    let message = format!(
        "{}",
        earthsci_ast::load_path(&doc).expect_err("a bare $VAR is a literal path segment")
    );
    assert!(
        message.contains(&format!("${VAR}")),
        "the bare form is carried through verbatim, got: {message}"
    );
}

#[test]
fn a_non_identifier_name_is_not_a_token() {
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    // `${...}` whose name is not a C-identifier is an ordinary path segment, as
    // in Julia and Python (regex `\$\{([A-Za-z_][A-Za-z0-9_]*)\}`).
    let doc = write(
        dir.path(),
        "importer.esm",
        &importer("${not an ident}/template_import_lib.esm"),
    );

    let message = format!(
        "{}",
        earthsci_ast::load_path(&doc).expect_err("a non-identifier name cannot expand")
    );
    assert!(
        message.contains("${not an ident}"),
        "a non-identifier `${{...}}` is carried through verbatim, got: {message}"
    );
}

#[test]
fn an_expanded_relative_ref_anchors_at_the_referencing_document() {
    const VAR: &str = "ESM_RS_ENVREF_RELATIVE_SUBDIR";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    // The variable holds a RELATIVE fragment. The library sits under the
    // document's own `libs/`, which does not exist relative to the test
    // process's working directory — so resolving proves the expanded ref is
    // anchored at the referencing file's directory (esm-spec §4.7).
    std::fs::create_dir(dir.path().join("libs")).expect("libs dir");
    std::fs::copy(
        valid_dir().join("template_import_lib.esm"),
        dir.path().join("libs/template_import_lib.esm"),
    )
    .expect("copy library");
    let doc = write(
        dir.path(),
        "importer.esm",
        &importer(&format!("${{{VAR}}}/template_import_lib.esm")),
    );

    let _var = EnvVar::set(VAR, "libs");
    earthsci_ast::load_path(&doc).expect("an expanded relative ref anchors at the document");
}

#[test]
fn a_set_variable_expands_in_a_subsystem_ref() {
    const VAR: &str = "ESM_RS_ENVREF_SUBSYSTEM_DIR";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    let leaf = json!({
        "esm": "1.0.0",
        "metadata": { "name": "leaf" },
        "models": { "Leaf": {
            "variables": { "x": { "type": "unknown", "units": "1", "default": 1.0 } },
            "equations": [ { "lhs": { "op": "D", "args": ["x"], "wrt": "t" },
                             "rhs": { "op": "-", "args": ["x"] } } ]
        } }
    })
    .to_string();
    std::fs::create_dir(dir.path().join("leaves")).expect("leaves dir");
    write(&dir.path().join("leaves"), "leaf.esm", &leaf);

    let parent = json!({
        "esm": "1.0.0",
        "metadata": { "name": "parent" },
        "models": { "Parent": {
            "variables": { "y": { "type": "unknown", "units": "1", "default": 1.0 } },
            "equations": [ { "lhs": { "op": "D", "args": ["y"], "wrt": "t" },
                             "rhs": { "op": "-", "args": ["y"] } } ],
            "subsystems": { "child": { "ref": format!("${{{VAR}}}/leaf.esm") } }
        } }
    })
    .to_string();
    let doc = write(dir.path(), "parent.esm", &parent);

    let _var = EnvVar::set(VAR, dir.path().join("leaves").to_str().expect("utf-8 path"));
    earthsci_ast::load_path(&doc).expect("a set ${VAR} expands in a subsystem ref");
}

/// A coupling-library file: roles + role-scoped edges (esm-spec §10.9).
fn coupling_lib() -> Value {
    json!({
        "esm": "1.0.0",
        "metadata": { "name": "EnvRefCouplingLib" },
        "coupling_roles": { "Src": { "description": "source" }, "Dst": { "description": "sink" } },
        "coupling": [
            { "type": "variable_map", "from": "Src.a", "to": "Dst.b", "transform": "param_to_var" }
        ]
    })
}

/// An assembly whose `coupling_import` reaches the library through `import_ref`.
fn coupling_assembly(import_ref: &str) -> EsmFile {
    serde_json::from_value(json!({
        "esm": "1.0.0",
        "metadata": { "name": "env_ref_assembly" },
        "models": {
            "A": { "variables": { "a": { "type": "parameter", "units": "1", "default": 1 } },
                   "equations": [] },
            "B": { "variables": { "b": { "type": "parameter", "units": "1", "default": 0 } },
                   "equations": [] }
        },
        "coupling": [
            { "type": "coupling_import", "ref": import_ref, "bind": { "Src": "A", "Dst": "B" } }
        ]
    }))
    .expect("assembly deserializes")
}

#[test]
fn a_set_variable_expands_in_a_coupling_import_ref() {
    const VAR: &str = "ESM_RS_ENVREF_COUPLING_LIB_DIR";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    std::fs::create_dir(dir.path().join("libs")).expect("libs dir");
    write(
        &dir.path().join("libs"),
        "coupling_lib.esm",
        &coupling_lib().to_string(),
    );

    let file = coupling_assembly(&format!("${{{VAR}}}/coupling_lib.esm"));
    let _var = EnvVar::set(VAR, "libs");
    let options = CouplingImportOptions {
        base_path: dir.path().to_string_lossy().into_owned(),
        ..Default::default()
    };
    let edges = expand_coupling_imports(&file, &options)
        .expect("a set ${VAR} expands in a coupling_import ref (esm-spec §10.10)")
        .expect("the assembly has a coupling block");
    assert_eq!(edges.len(), 1, "the library's one edge is spliced in");
    assert!(matches!(edges[0], CouplingEntry::VariableMap { .. }));
}

#[test]
fn an_unset_variable_in_a_coupling_import_ref_fails_unresolved() {
    const VAR: &str = "ESM_RS_ENVREF_COUPLING_UNSET";
    let _lock = env_lock();
    let dir = tempfile::tempdir().expect("temp dir");
    let file = coupling_assembly(&format!("${{{VAR}}}/coupling_lib.esm"));
    let options = CouplingImportOptions {
        base_path: dir.path().to_string_lossy().into_owned(),
        ..Default::default()
    };
    let e = expand_coupling_imports(&file, &options).expect_err("an unset ${VAR} cannot resolve");
    assert_eq!(e.code, "coupling_import_unresolved");
    assert!(
        e.message.contains(&format!("${{{VAR}}}")),
        "an unset variable stays literal, got: {}",
        e.message
    );
}

#[test]
fn a_set_variable_expands_in_an_injected_template_import_ref() {
    const VAR: &str = "ESM_RS_ENVREF_INJECTED_LIB_DIR";
    let _lock = env_lock();
    // esm-spec §9.7.10 form A: a mount edge's `expression_template_imports` are
    // authored by the assembler and spliced into the mounted leaf's scope, so
    // the §4.7 expansion has to reach that ref too.
    let conf = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/expression_templates/inject_subsystem_ref");
    let dir = tempfile::tempdir().expect("temp dir");
    std::fs::copy(conf.join("leaf.esm"), dir.path().join("leaf.esm")).expect("copy leaf");
    let fixture = std::fs::read_to_string(conf.join("fixture.esm")).expect("read fixture");
    let doc = write(
        dir.path(),
        "fixture.esm",
        &fixture.replace(
            "\"./central_D_lon_zero_grad_bc.esm\"",
            &format!("\"${{{VAR}}}/central_D_lon_zero_grad_bc.esm\""),
        ),
    );

    // Negative control: the injected import is load-bearing. Point the variable
    // at a directory that holds no library and the load MUST fail, so a pass
    // below cannot come from the injection being ignored.
    {
        let _var = EnvVar::set(VAR, dir.path().to_str().expect("utf-8 path"));
        earthsci_ast::load_path(&doc)
            .expect_err("the injected import is load-bearing, so a bad one must fail");
    }

    let _var = EnvVar::set(VAR, conf.to_str().expect("utf-8 path"));
    earthsci_ast::load_path(&doc).expect("an injected `${VAR}` import expands before anchoring");
}
