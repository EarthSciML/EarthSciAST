//! Migration functionality for ESM format version compatibility
//!
//! Implements Section 8.3 of the ESM Libraries Specification:
//! migrate(file: EsmFile, target_version: String) → EsmFile

use crate::types::EsmFile;
use std::error::Error;
use std::fmt;

/// Migration error that occurs when migration fails
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

/// Semantic version information
#[derive(Debug, Clone, PartialEq)]
pub struct VersionInfo {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

/// Parse a semantic version string into components
fn parse_version(version: &str) -> Result<VersionInfo, MigrationError> {
    let (major, minor, patch) =
        crate::diagnostic::parse_semver(version).ok_or_else(|| MigrationError {
            message: format!("Invalid version format: {version}"),
            from_version: version.to_string(),
            to_version: String::new(),
        })?;
    Ok(VersionInfo {
        major,
        minor,
        patch,
    })
}

/// Compare two semantic versions
/// Returns: -1 if a < b, 0 if a == b, 1 if a > b
fn compare_versions(a: &str, b: &str) -> Result<i32, MigrationError> {
    let version_a = parse_version(a)?;
    let version_b = parse_version(b)?;

    if version_a.major != version_b.major {
        return Ok((version_a.major as i32) - (version_b.major as i32));
    }
    if version_a.minor != version_b.minor {
        return Ok((version_a.minor as i32) - (version_b.minor as i32));
    }
    Ok((version_a.patch as i32) - (version_b.patch as i32))
}

/// Convert units from ppbv to mol/mol (for migration from 0.0.5 to 0.1.0+)
fn convert_ppbv_to_mol_mol(value: f64) -> f64 {
    // ppbv to mol/mol conversion: divide by 1e9
    value / 1e9
}

/// Migrate species units from older format (e.g., ppbv) to newer format (mol/mol)
/// This handles the specific migration example shown in the tests
fn migrate_species_units(
    file: &EsmFile,
    from_version: &str,
    to_version: &str,
) -> Result<EsmFile, MigrationError> {
    let from_ver = parse_version(from_version)?;
    let to_ver = parse_version(to_version)?;

    // Migration from 0.0.5 to 0.1.0: convert ppbv to mol/mol
    if from_ver.major == 0
        && from_ver.minor == 0
        && from_ver.patch == 5
        && to_ver.major == 0
        && to_ver.minor >= 1
    {
        let mut new_file = file.clone();

        // Convert species units in all reaction systems
        if let Some(ref mut reaction_systems) = new_file.reaction_systems {
            for system in reaction_systems.values_mut() {
                for species in system.species.values_mut() {
                    if species.units == Some("ppbv".to_string())
                        && let Some(val) = species.default
                    {
                        species.units = Some("mol/mol".to_string());
                        species.default = Some(convert_ppbv_to_mol_mol(val));
                    }
                }
            }
        }

        return Ok(new_file);
    }

    Ok(file.clone())
}

/// Add migration notes to the metadata
fn add_migration_notes(file: &EsmFile, from_version: &str, to_version: &str) -> EsmFile {
    let mut new_file = file.clone();

    let migration_note = format!("Migrated from version {from_version} to version {to_version}");

    // Add migration note to description
    match &new_file.metadata.description {
        Some(desc) if !desc.is_empty() => {
            new_file.metadata.description =
                Some(format!("{desc}\nMigration notes: {migration_note}"));
        }
        _ => {
            new_file.metadata.description = Some(format!("Migration notes: {migration_note}"));
        }
    }

    new_file
}

/// Migrate an ESM file to a target version
pub fn migrate(file: &EsmFile, target_version: &str) -> Result<EsmFile, MigrationError> {
    let current_version = &file.esm;

    // Parse versions to validate format
    let current = parse_version(current_version)?;
    let target = parse_version(target_version)?;

    // Check if migration is needed
    if current_version == target_version {
        return Ok(file.clone());
    }

    // Check if we can migrate (same major version for now)
    if current.major != target.major {
        return Err(MigrationError {
            message: format!(
                "Cannot migrate across major versions: {current_version} to {target_version}"
            ),
            from_version: current_version.clone(),
            to_version: target_version.to_string(),
        });
    }

    // For now, only support forward migration (upgrading)
    let comparison = compare_versions(current_version, target_version)?;
    if comparison > 0 {
        return Err(MigrationError {
            message: format!(
                "Backward migration not supported: {current_version} to {target_version}"
            ),
            from_version: current_version.clone(),
            to_version: target_version.to_string(),
        });
    }

    let mut migrated_file = file.clone();

    // Update the version
    migrated_file.esm = target_version.to_string();

    // Apply version-specific migrations
    migrated_file = migrate_species_units(&migrated_file, current_version, target_version)?;

    // Add migration notes
    migrated_file = add_migration_notes(&migrated_file, current_version, target_version);

    Ok(migrated_file)
}

/// Check if migration is supported between two versions
pub fn can_migrate(from_version: &str, to_version: &str) -> bool {
    let Ok(from_ver) = parse_version(from_version) else {
        return false;
    };
    let Ok(to_ver) = parse_version(to_version) else {
        return false;
    };

    // Only support migration within the same major version
    if from_ver.major != to_ver.major {
        return false;
    }

    // Only support forward migration for now
    compare_versions(from_version, to_version).is_ok_and(|cmp| cmp <= 0)
}

/// Get supported migration paths from a given version
pub fn get_supported_migration_targets(from_version: &str) -> Vec<String> {
    let Ok(from_ver) = parse_version(from_version) else {
        return vec![];
    };

    // For now, support migration to any later version in the same major version
    // In a real implementation, this would be based on available migration rules
    let mut targets = Vec::new();

    // Add some common target versions (this could be made more sophisticated)
    if from_ver.major == 0 {
        if from_ver.minor == 0 {
            targets.push("0.1.0".to_string());
        }
        if from_ver.minor <= 1 {
            targets.extend(vec![
                "0.1.0".to_string(),
                "0.1.1".to_string(),
                "0.2.0".to_string(),
            ]);
        }
    }

    // Filter to only include versions that are later than the from version
    targets
        .into_iter()
        .filter(|target| compare_versions(from_version, target).is_ok_and(|cmp| cmp < 0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_version() {
        let version = parse_version("1.2.3").unwrap();
        assert_eq!(version.major, 1);
        assert_eq!(version.minor, 2);
        assert_eq!(version.patch, 3);

        assert!(parse_version("invalid").is_err());
    }

    #[test]
    fn test_compare_versions() {
        assert_eq!(compare_versions("1.0.0", "1.0.0").unwrap(), 0);
        assert!(compare_versions("1.0.0", "1.1.0").unwrap() < 0);
        assert!(compare_versions("1.1.0", "1.0.0").unwrap() > 0);
    }

    #[test]
    fn test_convert_ppbv_to_mol_mol() {
        assert_eq!(convert_ppbv_to_mol_mol(1900.0), 1.9e-6);
    }

    #[test]
    fn test_can_migrate() {
        assert!(can_migrate("0.0.5", "0.1.0"));
        assert!(!can_migrate("1.0.0", "0.1.0"));
        assert!(!can_migrate("0.1.0", "0.0.5"));
        assert!(can_migrate("0.1.0", "0.1.0"));
    }
}
