//! Version-migration utilities for the ESM format (esm-libraries-spec §8.3).
//!
//! A migration here is a pure version-MARKER bump: it changes the `esm` field
//! and touches nothing else. That is only ever sound along an ADDITIVE line — a
//! run of schema releases each of which introduced its changes as additive,
//! backward-compatible fields, so an older file already loads under the newer
//! schema without any mechanical transform. The current additive line is
//! `1.0.0 … <current schema version>` ([`crate::SCHEMA_VERSION`]).
//!
//! **There is no migration across the 1.0.0 boundary.** esm 1.0.0 is a clean
//! break with no deprecation path: the five declared variable types collapse to
//! two, an observed variable's `expression` becomes an equation, `data_loaders`
//! becomes a non-component `data_sources` registry, and parameter mutation moves
//! off events onto the parameter. None of that is a marker bump — every one of
//! them RESHAPES the document, and several need information (which unknowns are
//! ODE states) that only the equations carry. A 0.x source therefore yields no
//! supported targets rather than a bump that would produce a file claiming
//! 1.0.0 while still carrying 0.x shapes.
//!
//! That refusal is what the canonical fixture spec records:
//! `tests/version_compatibility/compatibility_matrix.json` states outright that
//! "there is no automatic path: a 0.x document must be rewritten", and its
//! `migration_test_from_0_0_5` → `migration_test_to_1_0_0` pair demonstrates a
//! rewrite a human performs — the SOURCE is deliberately unloadable by a 1.x
//! library and only the TARGET loads. The repo-level
//! `scripts/migrate-0x-to-1.0.0.py` draws the same line: it rewrites what is
//! mechanical and REFUSES `data_loaders`, event `functional_affect` /
//! `discrete_parameters`, and never-valid `type` values, because each needs
//! information the document does not carry.
//!
//! Until 1.0.0 this module carried a single pre-break rule (a 0.0.5 → 0.1.x
//! ppbv → mol/mol species-unit conversion). Both of its endpoints are on the
//! far side of the clean break, so a 1.x library can load neither, and it has
//! been removed rather than kept as an unreachable path.
//!
//! The single supported target for an additive-line source is the CURRENT
//! schema version; arbitrary intermediate targets are deliberately NOT offered
//! — there is no per-minor transform to encode, only "bring this file up to
//! current". Sources outside that line (newer than current, a different major,
//! or malformed) yield no supported targets.
//!
//! [`get_supported_migration_targets`] is the single source of truth:
//! [`can_migrate`] is defined as membership in it and [`migrate`] refuses
//! anything `can_migrate` rejects, so a caller can never be told a pair works
//! and then handed a [`MigrationError`]. The semantics match the other four
//! bindings exactly (`pkg/earthsci-ast-ts/src/migration.ts`,
//! `pkg/earthsci-ast-py/src/earthsci_ast/migration.py`,
//! `pkg/EarthSciAST.jl/src/migration.jl`,
//! `pkg/earthsci-ast-go/pkg/esm/migration.go`).

use crate::types::EsmFile;
use std::error::Error;
use std::fmt;

/// Migration error that occurs when migration fails.
///
/// Carries the endpoint versions alongside the message so a caller can report
/// the pair without re-deriving it (Go's `MigrationError` mirrors these fields).
#[derive(Debug, Clone)]
pub struct MigrationError {
    pub message: String,
    pub from_version: String,
    pub to_version: String,
}

impl fmt::Display for MigrationError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "Migration error: {} ({} → {})",
            self.message, self.from_version, self.to_version
        )
    }
}

impl Error for MigrationError {}

/// Parsed `major.minor.patch` components. Tuple order makes the derived `Ord`
/// exactly the NUMERIC, component-wise version comparison the compatibility
/// matrix mandates: `1.10.0` is newer than `1.2.0`, and `1.0.100` is a patch of
/// `1.0`, not a minor bump — both of which a lexicographic string comparison
/// gets wrong.
type SemVer = (u32, u32, u32);

/// The oldest version a marker bump can carry forward.
///
/// It is 1.0.0, not 0.1.0: the 0.x line ended at a clean break, so no 0.x
/// version can be carried forward. [`on_additive_line`] already requires the
/// majors to agree, which makes a 0.x source ineligible on its own; the floor
/// is stated at 1.0.0 as well so the intent survives the next major.
const ADDITIVE_FLOOR: SemVer = (1, 0, 0);

/// [`crate::SCHEMA_VERSION`] parsed. Derived from the crate's own constant —
/// itself pinned to the bundled schema's `$id` by
/// `lib.rs::schema_version_matches_bundled_schema` — so the additive line can
/// never hand-drift from the schema this library implements.
fn current_version() -> SemVer {
    crate::diagnostic::parse_semver(crate::SCHEMA_VERSION)
        .expect("SCHEMA_VERSION is a valid major.minor.patch string")
}

/// True when `version` sits on the additive line `1.0.0 … <current>` and can
/// therefore be carried to the current schema version by a marker-only, no-op
/// migration.
fn on_additive_line(version: SemVer) -> bool {
    let current = current_version();
    version.0 == current.0 && version >= ADDITIVE_FLOOR && version <= current
}

/// The schema versions `from_version` can be migrated to.
///
/// - any version on the additive line `1.0.0 … <current schema version>` →
///   `[SCHEMA_VERSION]` (a no-op marker bump to the current schema);
/// - everything else — including EVERY 0.x version, which 1.0.0's clean break
///   puts out of reach of a marker bump, plus newer-than-current, other majors
///   and malformed strings — → an empty vector.
///
/// This is the single source of truth for the whole module: [`can_migrate`] is
/// membership in this list and [`migrate`] refuses whatever it omits.
pub fn get_supported_migration_targets(from_version: &str) -> Vec<String> {
    match crate::diagnostic::parse_semver(from_version) {
        Some(version) if on_additive_line(version) => vec![crate::SCHEMA_VERSION.to_string()],
        _ => Vec::new(),
    }
}

/// Whether [`migrate`] would succeed for this version pair — i.e. whether
/// `to_version` is among [`get_supported_migration_targets`]`(from_version)`.
///
/// Deliberately consults the same single source of truth `migrate` does, so a
/// caller is never told a pair is migratable and then handed a
/// [`MigrationError`].
pub fn can_migrate(from_version: &str, to_version: &str) -> bool {
    get_supported_migration_targets(from_version)
        .iter()
        .any(|target| target == to_version)
}

/// Migrate an ESM file from the version it declares to `target_version`.
///
/// Every supported step is a pure version-marker bump with no structural
/// transform: an additive-line source (`1.0.0 … <current>`) advanced to the
/// current schema version (see the module header). Any other version pair — a
/// 0.x source included — yields a [`MigrationError`]. Content-level changes are
/// not performed; they are modeling decisions, not mechanical migrations.
///
/// The input is never mutated: a clone carrying the updated `esm` marker and
/// every other field unchanged is returned.
pub fn migrate(file: &EsmFile, target_version: &str) -> Result<EsmFile, MigrationError> {
    let source_version = &file.esm;

    if source_version.is_empty() {
        return Err(MigrationError {
            message: "Source file has no 'esm' version field".to_string(),
            from_version: String::new(),
            to_version: target_version.to_string(),
        });
    }

    if !can_migrate(source_version, target_version) {
        return Err(MigrationError {
            message: format!(
                "Migration from {source_version} to {target_version} is not supported"
            ),
            from_version: source_version.clone(),
            to_version: target_version.to_string(),
        });
    }

    let mut migrated = file.clone();
    migrated.esm = target_version.to_string();
    Ok(migrated)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CURRENT: &str = crate::SCHEMA_VERSION;

    /// A minimal in-memory document at a chosen declared version. Built by
    /// deserializing rather than loading, because most of these versions are
    /// ones `load` REFUSES — the migration surface has to be reachable for a
    /// document the loader would reject, which is exactly the 0.x case.
    fn file_at(version: &str) -> EsmFile {
        serde_json::from_value(serde_json::json!({
            "esm": version,
            "metadata": {"name": "test"},
        }))
        .expect("minimal ESM skeleton deserializes")
    }

    #[test]
    fn no_target_for_any_0x_source_the_clean_break_being_uncrossable() {
        for source in ["0.0.1", "0.0.5", "0.1.0", "0.3.0", "0.8.0", "0.9.0"] {
            assert_eq!(
                get_supported_migration_targets(source),
                Vec::<String>::new(),
                "0.x source {source} must have no automated target"
            );
        }
    }

    #[test]
    fn additive_line_sources_bump_to_the_current_schema() {
        for source in ["1.0.0", CURRENT] {
            assert_eq!(
                get_supported_migration_targets(source),
                vec![CURRENT.to_string()],
                "additive-line source {source}"
            );
        }
    }

    #[test]
    fn sources_off_the_additive_line_have_no_targets() {
        // Past the ceiling, and other majors in both directions.
        for source in ["1.99.0", "2.0.0", "12.34.56"] {
            assert_eq!(
                get_supported_migration_targets(source),
                Vec::<String>::new()
            );
        }
    }

    #[test]
    fn malformed_version_strings_have_no_targets() {
        for source in [
            "not-a-version",
            "1.0",
            "",
            "1.0.0-alpha.1",
            "v1.0.0",
            "1.0.0 ",
            "1.0.0.0",
        ] {
            assert_eq!(
                get_supported_migration_targets(source),
                Vec::<String>::new(),
                "malformed source {source:?}"
            );
        }
    }

    #[test]
    fn version_comparison_is_numeric_not_lexicographic() {
        // `1.10.0` is NEWER than the current 1.0.0 and so off the line, and a
        // large patch of the current minor is off it too. A string comparison
        // would get "1.10.0" < "1.9.0" and could place either on the line.
        assert_eq!(
            get_supported_migration_targets("1.10.0"),
            Vec::<String>::new()
        );
        assert_eq!(
            get_supported_migration_targets("1.0.100"),
            Vec::<String>::new()
        );
    }

    #[test]
    fn can_migrate_rejects_every_0x_source_whatever_the_target() {
        assert!(!can_migrate("0.0.5", "0.1.0"));
        assert!(!can_migrate("0.9.0", "1.0.0"));
        assert!(!can_migrate("0.9.0", CURRENT));
    }

    #[test]
    fn can_migrate_accepts_an_additive_line_source_to_current() {
        assert!(can_migrate("1.0.0", CURRENT));
        // Identity no-op: the current version migrated to itself.
        assert!(can_migrate(CURRENT, CURRENT));
    }

    #[test]
    fn can_migrate_rejects_an_intermediate_non_current_target() {
        // Only the current schema is a valid target; per-minor jumps are not
        // offered, because there is no per-minor transform to encode.
        assert!(!can_migrate("1.0.0", "1.0.1"));
        assert!(!can_migrate("1.0.0", "1.1.0"));
        assert!(!can_migrate("1.0.0", "2.0.0"));
        assert!(!can_migrate("not-a-version", CURRENT));
        assert!(!can_migrate("1.0.0", "not-a-version"));
    }

    /// The equivalence that makes the three entry points agree BY CONSTRUCTION:
    /// over a source × target grid, `can_migrate` is exactly membership in
    /// `get_supported_migration_targets`, and `migrate` succeeds on exactly the
    /// pairs `can_migrate` accepts. A caller is therefore never told a pair
    /// works and then handed a `MigrationError` — the self-contradiction this
    /// module carried before the 1.0.0 re-base.
    #[test]
    fn can_migrate_migrate_and_targets_agree_across_the_grid() {
        let sources = [
            "0.0.5", "0.1.0", "0.9.0", "1.0.0", CURRENT, "1.0.1", "1.99.0", "2.0.0", "nonsense",
        ];
        let targets = [CURRENT, "0.1.0", "1.0.0", "1.0.1", "2.0.0", "nonsense"];

        for source in sources {
            let supported = get_supported_migration_targets(source);
            for target in targets {
                let listed = supported.iter().any(|t| t == target);
                assert_eq!(
                    can_migrate(source, target),
                    listed,
                    "can_migrate({source}, {target}) disagrees with the target list"
                );
                assert_eq!(
                    migrate(&file_at(source), target).is_ok(),
                    listed,
                    "migrate({source} → {target}) disagrees with can_migrate"
                );
            }
        }
    }

    #[test]
    fn migrate_refuses_a_0x_source_rather_than_bumping_its_marker() {
        let source = file_at("0.9.0");
        let err = migrate(&source, CURRENT).expect_err("0.x must not migrate");
        assert_eq!(err.from_version, "0.9.0");
        assert_eq!(err.to_version, CURRENT);
        let rendered = err.to_string();
        assert!(rendered.contains("0.9.0"), "{rendered}");
        assert!(rendered.contains(CURRENT), "{rendered}");
        assert!(rendered.contains("not supported"), "{rendered}");
        // The input is left alone.
        assert_eq!(source.esm, "0.9.0");
    }

    #[test]
    fn migrate_bumps_an_additive_line_file_and_leaves_the_input_alone() {
        let source = file_at("1.0.0");
        let migrated = migrate(&source, CURRENT).expect("additive-line bump");
        assert_eq!(migrated.esm, CURRENT);
        assert_eq!(source.esm, "1.0.0");
    }

    #[test]
    fn migrate_is_a_no_op_for_a_current_version_file() {
        let source = file_at(CURRENT);
        let migrated = migrate(&source, CURRENT).expect("identity no-op");
        assert_eq!(migrated.esm, CURRENT);
    }

    #[test]
    fn migrate_errors_for_unsupported_version_pairs() {
        assert!(migrate(&file_at("1.0.0"), "2.0.0").is_err());
        assert!(migrate(&file_at("1.0.0"), "1.0.1").is_err());
        assert!(migrate(&file_at("0.1.0"), CURRENT).is_err());
        assert!(migrate(&file_at("1.0.0"), "not-a-version").is_err());
    }

    #[test]
    fn migrate_errors_when_the_source_declares_no_version() {
        // `EsmFile.esm` is a non-optional `String`, so TypeScript's "missing
        // `esm` field" case surfaces here as the empty string.
        let err = migrate(&file_at(""), CURRENT).expect_err("no source version");
        assert!(err.message.contains("no 'esm' version field"), "{err}");
    }
}
