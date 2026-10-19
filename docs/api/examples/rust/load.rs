//! Read a document from a path and from a JSON string, check the version
//! constants, and migrate a document between format versions.

use earthsci_ast::{
    LIBRARY_VERSION, SCHEMA_VERSION, can_migrate, load_path, load_string, migrate,
    supported_migration_targets,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: load ops=load_path,load_string
    let doc = load_path(fixture("decay.esm"))?;
    let models = doc.models.as_ref().expect("decay.esm has models");
    assert_eq!(models.keys().collect::<Vec<_>>(), ["Decay"]);
    assert_eq!(doc.metadata.name.as_deref(), Some("Decay"));

    let text = std::fs::read_to_string(fixture("decay.esm"))?;
    let same = load_string(&text)?;
    assert_eq!(same.models.as_ref().unwrap().len(), 1);

    // A document that is not valid JSON is an error, not a panic.
    assert!(load_string("{ not json").is_err());
    // endregion

    // region: version_constants ops=schema_version,library_version
    // The `.esm` format version this library reads and writes, and the
    // version of the library itself: two unrelated numbers.
    println!("format {SCHEMA_VERSION}, library {LIBRARY_VERSION}");
    assert_eq!(SCHEMA_VERSION.split('.').count(), 3);
    // endregion

    // region: migrate ops=migrate,can_migrate,supported_migration_targets
    // decay.esm is written at format 1.0.0; the current format is a newer
    // 1.x, reached by a version-marker bump with no structural change.
    assert_eq!(doc.esm, "1.0.0");
    assert_eq!(supported_migration_targets(&doc.esm), [SCHEMA_VERSION]);
    assert!(can_migrate(&doc.esm, SCHEMA_VERSION));
    let migrated = migrate(&doc, SCHEMA_VERSION)?;
    assert_eq!(migrated.esm, SCHEMA_VERSION);

    // A 0.x document is out of reach: 1.0.0 was a clean break.
    assert!(!can_migrate("0.9.0", SCHEMA_VERSION));
    // endregion

    Ok(())
}
