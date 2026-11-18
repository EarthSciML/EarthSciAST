//! The migration surface, driven by the canonical fixture spec.
//!
//! `tests/version_compatibility/compatibility_matrix.json` is, by its own
//! README, "the canonical specification" for version handling. Its
//! `migration_notes` state that esm 1.0.0 is a clean break and that "there is
//! no automatic path: a 0.x document must be rewritten", and its
//! `migration_tests` pair demonstrates what that rewrite looks like — the
//! SOURCE is deliberately unloadable by a 1.x library and only the TARGET
//! loads. These assertions READ those fixtures rather than restating them, so
//! the binding cannot drift from the shared corpus.
//!
//! The Julia mirror is `pkg/EarthSciAST.jl/test/migration_test.jl`; the same
//! expectations hold in TypeScript, Python and Go.

use earthsci_ast::{
    EsmFile, SCHEMA_VERSION, can_migrate, load_string, migrate, supported_migration_targets,
};
use serde_json::Value;

use crate::common;

const MATRIX: &str = include_str!("../../../tests/version_compatibility/compatibility_matrix.json");
const MIGRATION_SOURCE: &str =
    include_str!("../../../tests/version_compatibility/migration_test_from_0_0_5.esm");
const MIGRATION_TARGET: &str =
    include_str!("../../../tests/version_compatibility/migration_test_to_1_0_0.esm");
const BASELINE: &str =
    include_str!("../../../tests/version_compatibility/version_1_0_0_baseline.esm");

fn matrix() -> Value {
    let parsed: Value = serde_json::from_str(MATRIX).expect("compatibility_matrix.json parses");
    parsed["version_compatibility_test_matrix"].clone()
}

fn parse_semver(version: &str) -> Option<(u32, u32, u32)> {
    let parts: Vec<&str> = version.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    Some((
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
    ))
}

/// A document at a chosen declared version, without going through `load` —
/// most of these versions are ones the loader REFUSES, and the migration
/// surface has to be reachable for exactly those.
fn file_at(version: &str) -> EsmFile {
    serde_json::from_value(serde_json::json!({
        "esm": version,
        "metadata": {"name": "migration fixture"},
    }))
    .expect("minimal ESM skeleton deserializes")
}

/// The matrix pins the library version these expectations are written against.
/// If it names another version, everything below is about another library.
#[test]
fn matrix_library_version_is_the_one_this_binding_implements() {
    assert_eq!(
        matrix()["library_version"]
            .as_str()
            .expect("library_version"),
        SCHEMA_VERSION
    );
}

/// Every fixture version the matrix declares has an automated target IFF it
/// is a released 1.x version, 1.0.0 to 1.3.0 (relabelled to the current version when it
/// uses no removed op), or sits
/// on the 2.x additive line at or below this library. Every 0.x fixture, and
/// one newer than this library, is out of reach of a marker bump.
#[test]
fn matrix_fixture_versions_have_targets_only_on_the_additive_line() {
    let current = parse_semver(SCHEMA_VERSION).expect("SCHEMA_VERSION is semver");
    let root = matrix();
    let cases = root["test_cases"].as_array().expect("test_cases");
    assert!(!cases.is_empty(), "the matrix declares no test cases");

    let mut checked = 0usize;
    for case in cases {
        let Some(file_version) = case["file_version"].as_str() else {
            continue; // null (missing field) or a JSON number (malformed) fixture
        };
        let Some(version) = parse_semver(file_version) else {
            // Not a well-formed semver (`not.a.version`, a prerelease): no
            // targets, unconditionally.
            assert!(
                supported_migration_targets(file_version).is_empty(),
                "malformed {file_version} must have no targets"
            );
            checked += 1;
            continue;
        };
        let on_line = ((1, 0, 0)..=(1, 3, 0)).contains(&version)
            || (version.0 == current.0 && version <= current);
        assert_eq!(
            !supported_migration_targets(file_version).is_empty(),
            on_line,
            "fixture version {file_version}: on_additive_line={on_line}"
        );
        checked += 1;
    }
    assert!(
        checked >= 10,
        "expected the matrix's full fixture list, saw {checked}"
    );
}

/// The demonstration pair, read straight out of the fixtures: the 0.0.5 source
/// has no automated path to the 1.0.0 target (or anywhere else), while the
/// target is a document this library reads and re-migrates as the identity
/// no-op.
#[test]
fn the_matrix_migration_pair_is_a_rewrite_not_an_automated_migration() {
    let root = matrix();
    let tests = root["migration_tests"].as_array().expect("migration_tests");
    assert_eq!(tests.len(), 1, "the matrix declares exactly one pair today");
    assert_eq!(
        tests[0]["source"].as_str(),
        Some("migration_test_from_0_0_5.esm")
    );
    assert_eq!(
        tests[0]["target"].as_str(),
        Some("migration_test_to_1_0_0.esm")
    );

    let source_doc: Value = serde_json::from_str(MIGRATION_SOURCE).expect("source fixture parses");
    let target_doc: Value = serde_json::from_str(MIGRATION_TARGET).expect("target fixture parses");
    let source_version = source_doc["esm"].as_str().expect("source esm");
    let target_version = target_doc["esm"].as_str().expect("target esm");

    // The source is pre-break: no automated path off it, to the target's
    // version or to any other.
    assert!(supported_migration_targets(source_version).is_empty());
    assert!(!can_migrate(source_version, target_version));
    let err = migrate(&file_at(source_version), target_version)
        .expect_err("a 0.x source must not migrate");
    assert!(err.to_string().contains("not supported"), "{err}");

    // The source is also unloadable by this 1.x library — the asymmetry the
    // matrix calls "the point".
    assert!(
        load_string(MIGRATION_SOURCE).is_err(),
        "the 0.0.5 source must be rejected by a 1.x loader"
    );

    // The target is a document this library reads. It keeps the version it is
    // NAMED for (1.0.0) rather than being restamped as the library advances —
    // what matters is that it sits ON the additive line, i.e. that migrating it
    // to the current schema is offered (a marker bump; the identity no-op when
    // the two versions coincide). `assert_eq!(target_version, SCHEMA_VERSION)`
    // asserted the restamping instead, and only agreed while the two were both
    // 1.0.0.
    assert!(!supported_migration_targets(target_version).is_empty());
    assert!(can_migrate(target_version, SCHEMA_VERSION));
    let target_file = load_string(MIGRATION_TARGET).expect("the 1.0.0 target loads");
    assert_eq!(
        migrate(&target_file, SCHEMA_VERSION)
            .expect("identity no-op")
            .esm,
        SCHEMA_VERSION
    );
}

/// Marker-only: a real loaded document keeps every field but `esm`.
///
/// Comparing the SERIALIZED forms (rather than a hand-listed set of fields) is
/// what would catch a field added to `EsmFile` and dropped by a future
/// structural rewrite of `migrate`.
#[test]
fn migration_is_a_marker_only_bump_over_a_real_document() {
    let source = load_string(BASELINE).expect("baseline fixture loads");
    assert_eq!(source.esm, "1.0.0");

    let migrated = migrate(&source, SCHEMA_VERSION).expect("additive-line bump");
    assert_eq!(migrated.esm, SCHEMA_VERSION);
    assert_eq!(source.esm, "1.0.0", "the input is never mutated");

    let mut before = serde_json::to_value(&source).expect("source serializes");
    let mut after = serde_json::to_value(&migrated).expect("migrated serializes");
    before.as_object_mut().expect("object").remove("esm");
    after.as_object_mut().expect("object").remove("esm");
    assert_eq!(before, after, "migrate touched a field other than `esm`");
}

/// Set to a fixture path, it makes [`deprecated_op_load_child`] load that
/// fixture in a child process of this test binary.
const DEPRECATED_OP_CHILD_ENV: &str = "ESM_TEST_DEPRECATED_OP_CHILD";

/// The child half of [`matrix_deprecated_op_entries_warn_once_naming_their_pointers`]:
/// a no-op unless [`DEPRECATED_OP_CHILD_ENV`] names a fixture, which it then
/// loads through `load_path`. The load writes its warnings to stderr
/// (`eprintln!`), which only a parent process can read, so the parent runs
/// this test alone with `--nocapture` and reads the child's stderr.
#[test]
fn deprecated_op_load_child() {
    let Some(path) = std::env::var_os(DEPRECATED_OP_CHILD_ENV) else {
        return;
    };
    let file = earthsci_ast::load_path(&path).expect("fixture loads");
    if std::path::Path::new(&path).ends_with("version_2_3_0_deprecated_neg.esm") {
        let decay = &file.models.as_ref().expect("models")["Decay"];
        let earthsci_ast::Expr::Operator(rhs) = &decay.equations[0].rhs else {
            panic!("Decay rhs is not an operator: {:?}", decay.equations[0].rhs);
        };
        let earthsci_ast::Expr::Operator(arg) = &rhs.args[0] else {
            panic!("Decay rhs args[0] is not an operator: {:?}", rhs.args[0]);
        };
        assert_eq!(arg.op, "-", "neg was not rewritten to unary minus");
    }
}

/// Every matrix entry carrying a `deprecated_op` list: loading its fixture
/// writes exactly ONE `deprecated_op` warning, naming exactly the listed JSON
/// pointers (esm-spec §4.2 "Deprecated ops"), and no forward-compatibility
/// version warning.
#[test]
fn matrix_deprecated_op_entries_warn_once_naming_their_pointers() {
    let cases: Vec<Value> = matrix()["test_cases"]
        .as_array()
        .expect("test_cases")
        .iter()
        .filter(|c| c.get("deprecated_op").is_some())
        .cloned()
        .collect();
    assert!(
        !cases.is_empty(),
        "no matrix entry carries a deprecated_op list"
    );
    let module = module_path!()
        .split_once("::")
        .map_or(module_path!(), |(_, m)| m);
    let child = format!("{module}::deprecated_op_load_child");
    let dir = common::repo_fixture("version_compatibility");
    for case in cases {
        let file = case["file"].as_str().expect("file");
        let want: Vec<&str> = case["deprecated_op"]
            .as_array()
            .expect("deprecated_op is a list")
            .iter()
            .map(|p| p.as_str().expect("pointer string"))
            .collect();
        let out = std::process::Command::new(std::env::current_exe().expect("test binary"))
            .args([child.as_str(), "--exact", "--nocapture", "--test-threads=1"])
            .env(DEPRECATED_OP_CHILD_ENV, dir.join(file))
            .output()
            .expect("run the child load");
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && stdout.contains("1 passed"),
            "{file}: child load failed\nstdout: {stdout}\nstderr: {stderr}"
        );
        let warnings: Vec<&str> = stderr
            .lines()
            .filter(|l| l.contains("deprecated_op"))
            .collect();
        assert_eq!(
            warnings.len(),
            1,
            "{file}: want ONE deprecated_op warning: {stderr}"
        );
        let list = warnings[0]
            .split_once("Rewritten at: ")
            .unwrap_or_else(|| panic!("{file}: warning names no nodes: {}", warnings[0]))
            .1;
        let named: Vec<&str> = list
            .trim_end()
            .trim_end_matches('.')
            .split(", ")
            .map(|site| site.rsplit_once(" (").map_or(site, |(pointer, _)| pointer))
            .collect();
        assert_eq!(named, want, "{file}: pointers the warning names");
        assert!(
            !stderr.contains("is newer than"),
            "{file}: version warning: {stderr}"
        );
    }
}
