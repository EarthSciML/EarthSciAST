//! The bundled standard library and `esm:std/<file>.esm` refs (esm-spec §4.7).
//!
//! The crate carries a copy of the repo-root `lib/` in `src/stdlib/`
//! (written by `scripts/sync-lib.sh`), compiled in with `include_str!` through
//! the table `build.rs` generates, so a published crate resolves standard-
//! library refs with no filesystem access.
//!
//! A bundled file has the virtual identity `esm:std/<name>` and the virtual
//! base directory `esm:std`. Cycle detection uses that identity, and a relative
//! ref inside a bundled file joins onto the base to give `esm:std/<rel>`, which
//! resolves by the same rule, so the library's own relative imports
//! (a library file importing `calendar.esm`) stay inside the bundle.

use std::borrow::Cow;
use std::path::Path;

/// The reserved ref scheme. A ref beginning with it is never a path or a URL.
pub const SCHEME: &str = "esm:";
/// The virtual directory of the bundled files.
pub const STD_BASE: &str = "esm:std";

static FILES: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/stdlib_files.rs"));

#[cfg(test)]
thread_local! {
    static OVERRIDE: std::cell::RefCell<Option<Vec<(&'static str, &'static str)>>> =
        const { std::cell::RefCell::new(None) };
}

/// Replace the bundle for the current thread until the guard drops, so unit
/// tests can exercise library files the real `lib/` does not contain.
#[cfg(test)]
pub(crate) struct TestBundle;

#[cfg(test)]
impl Drop for TestBundle {
    fn drop(&mut self) {
        OVERRIDE.with(|o| *o.borrow_mut() = None);
    }
}

#[cfg(test)]
pub(crate) fn with_test_bundle(files: &[(&str, &str)]) -> TestBundle {
    let leaked = files
        .iter()
        .map(|(n, t)| -> (&'static str, &'static str) {
            (
                Box::leak(n.to_string().into_boxed_str()),
                Box::leak(t.to_string().into_boxed_str()),
            )
        })
        .collect();
    OVERRIDE.with(|o| *o.borrow_mut() = Some(leaked));
    TestBundle
}

fn find(name: &str) -> Option<&'static str> {
    #[cfg(test)]
    if let Some(hit) = OVERRIDE.with(|o| {
        o.borrow()
            .as_ref()
            .map(|files| files.iter().find(|(n, _)| *n == name).map(|(_, t)| *t))
    }) {
        return hit;
    }
    FILES.iter().find(|(n, _)| *n == name).map(|(_, t)| *t)
}

/// The names of the bundled library files, sorted.
pub fn bundled_names() -> Vec<&'static str> {
    FILES.iter().map(|(n, _)| *n).collect()
}

/// The text of the bundled library file `name` (e.g. `"interp.esm"`).
pub fn bundled_file(name: &str) -> Option<&'static str> {
    find(name)
}

/// Whether `ref_str` uses the reserved `esm:` scheme.
pub fn is_std_ref(ref_str: &str) -> bool {
    ref_str.starts_with(SCHEME)
}

/// Whether `base` is the virtual directory of the bundled files.
pub fn is_std_base(base: &Path) -> bool {
    base == Path::new(STD_BASE)
}

/// The §4.7 spelling step before resolution: an `esm:` ref is taken as
/// written, anything else has its `${VAR}` tokens expanded.
pub fn expand_ref(ref_str: &str) -> Cow<'_, str> {
    if is_std_ref(ref_str) {
        Cow::Borrowed(ref_str)
    } else {
        crate::ref_loading::expand_env_refs(ref_str)
    }
}

fn is_valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphanumeric() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        && name.ends_with(".esm")
}

/// Resolve an expanded ref (see [`expand_ref`]) read from a document whose
/// directory is `base`.
///
/// Returns `None` for an ordinary path or URL ref, which the caller resolves as
/// before. Otherwise — an `esm:` ref, or a relative ref inside a bundled file —
/// returns the bundled file's identity (`esm:std/<name>`) and text, or a
/// message saying why it does not resolve, which the caller reports with its
/// mechanism's unresolved code.
pub fn resolve(expanded: &str, base: &Path) -> Option<Result<(String, &'static str), String>> {
    let candidate = if is_std_ref(expanded) {
        Cow::Borrowed(expanded)
    } else if is_std_base(base)
        && !expanded.starts_with('/')
        && !expanded.starts_with("http://")
        && !expanded.starts_with("https://")
    {
        Cow::Owned(format!("{STD_BASE}/{expanded}"))
    } else {
        return None;
    };
    Some(lookup(&candidate))
}

fn lookup(candidate: &str) -> Result<(String, &'static str), String> {
    let Some(rest) = candidate.strip_prefix("esm:std/") else {
        return Err(format!(
            "'{candidate}' is not a standard-library ref: the esm: scheme is reserved and only \
             esm:std/<file>.esm names a file"
        ));
    };
    let segments: Vec<&str> = rest.split('/').filter(|s| *s != ".").collect();
    let [name] = segments.as_slice() else {
        return Err(format!(
            "'{candidate}' does not name a standard-library file: the name must be one path segment"
        ));
    };
    if !is_valid_name(name) {
        return Err(format!(
            "'{candidate}' does not name a standard-library file"
        ));
    }
    match find(name) {
        Some(text) => Ok((format!("esm:std/{name}"), text)),
        None => Err(format!(
            "'{candidate}' is not in the bundled standard library (it has: {})",
            bundled_names().join(", ")
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_matches_the_repo_lib_directory() {
        let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../lib");
        if !lib.is_dir() {
            return; // a packaged crate, outside the repository
        }
        let mut names: Vec<String> = std::fs::read_dir(&lib)
            .expect("read lib/")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".esm"))
            .collect();
        names.sort();
        assert_eq!(bundled_names(), names, "run scripts/sync-lib.sh");
        for name in &names {
            let on_disk = std::fs::read_to_string(lib.join(name)).unwrap();
            assert_eq!(
                bundled_file(name),
                Some(on_disk.as_str()),
                "{name}: run scripts/sync-lib.sh"
            );
        }
    }

    #[test]
    fn std_refs_resolve_by_name_only() {
        let here = Path::new("/somewhere");
        let (id, text) = resolve("esm:std/interp.esm", here).unwrap().unwrap();
        assert_eq!(id, "esm:std/interp.esm");
        assert!(text.contains("searchsorted"));
        assert_eq!(
            resolve("esm:std/./interp.esm", here).unwrap().unwrap().0,
            "esm:std/interp.esm"
        );
        for bad in [
            "esm:std/nope.esm",
            "esm:std/../lib/interp.esm",
            "esm:std/sub/interp.esm",
            "esm:other/interp.esm",
            "esm:interp.esm",
            "esm:std/${X}.esm",
            "esm:std/interp",
        ] {
            assert!(resolve(bad, here).unwrap().is_err(), "{bad}");
        }
        assert!(resolve("./interp.esm", here).is_none());
        assert!(resolve("https://x/interp.esm", Path::new(STD_BASE)).is_none());
        assert!(resolve("/abs/interp.esm", Path::new(STD_BASE)).is_none());
    }

    #[test]
    fn relative_refs_inside_the_bundle_stay_inside_it() {
        let base = Path::new(STD_BASE);
        assert_eq!(
            resolve("interp.esm", base).unwrap().unwrap().0,
            "esm:std/interp.esm"
        );
        assert_eq!(
            resolve("./interp.esm", base).unwrap().unwrap().0,
            "esm:std/interp.esm"
        );
        assert!(resolve("../interp.esm", base).unwrap().is_err());
        assert!(resolve("missing.esm", base).unwrap().is_err());
    }

    #[test]
    fn env_tokens_are_not_expanded_inside_the_scheme() {
        // SAFETY: test-local variable name, no other thread reads it.
        unsafe { std::env::set_var("ESM_STDLIB_UNIT_NAME", "interp.esm") };
        assert_eq!(
            expand_ref("esm:std/${ESM_STDLIB_UNIT_NAME}"),
            "esm:std/${ESM_STDLIB_UNIT_NAME}"
        );
        assert_eq!(expand_ref("${ESM_STDLIB_UNIT_NAME}"), "interp.esm");
        unsafe { std::env::remove_var("ESM_STDLIB_UNIT_NAME") };
    }

    // -- loader-level rules over a substitute bundle -------------------------

    const TWICE_LIB: &str = r#"{"esm": "2.0.0", "metadata": {"name": "b"},
        "expression_templates": {"twice": {"params": ["x"],
            "body": {"op": "*", "args": [2, "x"]}}}}"#;

    fn importing_lib(name: &str, import: &str) -> String {
        format!(
            r#"{{"esm": "2.0.0", "metadata": {{"name": "{name}"}},
            "expression_template_imports": [{{"ref": "{import}"}}],
            "expression_templates": {{"quad": {{"params": ["x"], "body":
                {{"op": "apply_expression_template", "args": [], "name": "twice",
                  "bindings": {{"x": {{"op": "apply_expression_template", "args": [],
                      "name": "twice", "bindings": {{"x": "x"}}}}}}}}}}}}}}"#
        )
    }

    fn consumer(import: &str, template: &str) -> String {
        format!(
            r#"{{"esm": "2.0.0", "metadata": {{"name": "consumer"}},
            "models": {{"M": {{
                "expression_template_imports": [{{"ref": "{import}"}}],
                "variables": {{"x": {{"type": "parameter", "units": "1", "default": 1.0}},
                              "y": {{"type": "unknown", "units": "1"}}}},
                "equations": [{{"lhs": "y", "rhs": {{"op": "apply_expression_template",
                    "args": [], "name": "{template}", "bindings": {{"x": "x"}}}}}}]}}}}}}"#
        )
    }

    /// Every model's equations (subsystems included) with the surviving
    /// template references expanded (the loaded form keeps them, esm-spec
    /// §9.6.4 Option B).
    fn expanded_equations(file: &crate::EsmFile) -> String {
        let mut doc: serde_json::Value =
            serde_json::from_str(&crate::to_json(file).unwrap()).unwrap();
        crate::lower_expression_templates::expand(&mut doc).expect("expand");
        fn eqs(m: &serde_json::Value, out: &mut String) {
            out.push_str(&m["equations"].to_string());
            if let Some(subs) = m.get("subsystems").and_then(|v| v.as_object()) {
                subs.values().for_each(|s| eqs(s, out));
            }
        }
        let mut out = String::new();
        if let Some(models) = doc["models"].as_object() {
            models.values().for_each(|m| eqs(m, &mut out));
        }
        out
    }

    fn load_elsewhere(text: &str) -> Result<crate::EsmFile, String> {
        let dir = tempfile::TempDir::new().unwrap();
        let options = crate::LoadOptions {
            base_path: Some(dir.path().to_path_buf()),
            metaparameters: Default::default(),
        };
        crate::load_string_with_options(text, &options).map_err(|e| e.to_string())
    }

    #[test]
    fn a_bundled_file_imports_its_siblings() {
        let a = importing_lib("a", "b.esm");
        let a_dot = importing_lib("a_dot", "./b.esm");
        let a_std = importing_lib("a_std", "esm:std/b.esm");
        let up = importing_lib("up", "../b.esm");
        let _bundle = with_test_bundle(&[
            ("b.esm", TWICE_LIB),
            ("a.esm", &a),
            ("a_dot.esm", &a_dot),
            ("a_std.esm", &a_std),
            ("up.esm", &up),
        ]);
        for lib in ["a", "a_dot", "a_std"] {
            let file = load_elsewhere(&consumer(&format!("esm:std/{lib}.esm"), "quad"))
                .unwrap_or_else(|e| panic!("{lib}: {e}"));
            let json = expanded_equations(&file);
            assert!(!json.contains("apply_expression_template"), "{lib}: {json}");
        }
        let e = load_elsewhere(&consumer("esm:std/up.esm", "quad")).unwrap_err();
        assert!(e.contains("template_import_unresolved"), "{e}");
    }

    #[test]
    fn a_bundled_file_has_one_identity_for_cycle_detection() {
        let c1 = r#"{"esm": "2.0.0", "metadata": {"name": "c1"},
            "expression_template_imports": [{"ref": "esm:std/c2.esm"}],
            "expression_templates": {"one": {"params": [], "body": 1}}}"#;
        let c2 = r#"{"esm": "2.0.0", "metadata": {"name": "c2"},
            "expression_template_imports": [{"ref": "c1.esm"}],
            "expression_templates": {"two": {"params": [], "body": 2}}}"#;
        let _bundle = with_test_bundle(&[("c1.esm", c1), ("c2.esm", c2)]);
        let e = load_elsewhere(&consumer("esm:std/c1.esm", "one")).unwrap_err();
        assert!(e.contains("template_import_cycle"), "{e}");
    }

    #[test]
    fn a_bundled_subsystem_resolves_its_own_imports_in_the_bundle() {
        let sub = r#"{"esm": "2.0.0", "metadata": {"name": "sub"},
            "models": {"Sub": {
                "expression_template_imports": [{"ref": "b.esm"}],
                "variables": {"u": {"type": "parameter", "units": "1", "default": 3.0},
                              "w": {"type": "unknown", "units": "1"}},
                "equations": [{"lhs": "w", "rhs": {"op": "apply_expression_template",
                    "args": [], "name": "twice", "bindings": {"x": "u"}}}]}}}"#;
        let _bundle = with_test_bundle(&[("b.esm", TWICE_LIB), ("sub.esm", sub)]);
        for mount in [
            r#""models": {"Top": {"subsystems": {"S": {"ref": "esm:std/sub.esm"}},
                "variables": {"z": {"type": "unknown", "units": "1"}},
                "equations": [{"lhs": "z", "rhs": "S.w"}]}}"#,
            r#""models": {"S": {"ref": "esm:std/sub.esm"}}"#,
        ] {
            let text = format!(r#"{{"esm": "2.0.0", "metadata": {{"name": "mount"}}, {mount}}}"#);
            let file = load_elsewhere(&text).unwrap_or_else(|e| panic!("{mount}: {e}"));
            let json = expanded_equations(&file);
            assert!(!json.contains("apply_expression_template"), "{json}");
            assert!(json.contains("\"u\""), "{json}");
        }
    }
}
