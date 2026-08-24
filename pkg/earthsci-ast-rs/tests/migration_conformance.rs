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
    EsmFile, SCHEMA_VERSION, can_migrate, get_supported_migration_targets, load_string, migrate,
};
use serde_json::Value;

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
/// sits on the additive line — which, for a 1.0.0 library, is exactly the 1.0.0
/// fixtures. Every `reject`ed 0.x and 2.x+ fixture is out of reach of a marker
/// bump.
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
                get_supported_migration_targets(file_version).is_empty(),
                "malformed {file_version} must have no targets"
            );
            checked += 1;
            continue;
        };
        let on_line = version.0 == current.0 && version >= (1, 0, 0) && version <= current;
        assert_eq!(
            !get_supported_migration_targets(file_version).is_empty(),
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
    assert!(get_supported_migration_targets(source_version).is_empty());
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

    // The target is a document this library reads, and migrating it to the
    // current schema is the identity no-op.
    assert_eq!(target_version, SCHEMA_VERSION);
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
