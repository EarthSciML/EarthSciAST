//! Conformance: `from.records_per_sample` (esm-spec §8.5.1).
//!
//! Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
//! must validate, round-trip the field, and flatten with each data-fed
//! parameter's `LoaderField` reporting the EFFECTIVE value (the binding's own,
//! else the source's `temporal.records_per_sample`, else 1) and the flattened
//! parameter's `update.from` carrying the field as written. An invalid case
//! must be refused with `records_per_sample_invalid` at the pinned pointer.

use earthsci_ast::{EsmFile, flatten, load_path, load_string, to_json, validate};
use serde_json::Value;
use std::path::PathBuf;

fn tier_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/records_per_sample")
}

fn manifest() -> Value {
    serde_json::from_str(&std::fs::read_to_string(tier_dir().join("manifest.json")).unwrap())
        .unwrap()
}

fn load(case: &Value) -> EsmFile {
    load_path(tier_dir().join(case["path"].as_str().unwrap())).unwrap()
}

fn from_records(var: &earthsci_ast::ModelVariable) -> Option<u8> {
    var.update
        .as_ref()?
        .rules()
        .iter()
        .find_map(|r| r.value()?.from.as_ref())?
        .records_per_sample
}

#[test]
fn valid_cases_report_the_effective_value() {
    let m = manifest();
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "valid" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        let result = validate(&file);
        assert!(
            result.structural_errors.is_empty() && result.schema_errors.is_empty(),
            "{id}: {:?}",
            result.structural_errors
        );
        let flat = flatten(&file).unwrap();
        for want in case["loader_fields"].as_array().unwrap() {
            let name = want["name"].as_str().unwrap();
            let lf = flat
                .loader_fields
                .iter()
                .find(|lf| lf.name == name)
                .unwrap_or_else(|| panic!("{id}: no loader field {name}"));
            assert_eq!(lf.source, want["source"].as_str().unwrap(), "{id} {name}");
            assert_eq!(
                lf.file_variable,
                want["file_variable"].as_str().unwrap(),
                "{id} {name}"
            );
            assert_eq!(lf.cadence, want["cadence"].as_str().unwrap(), "{id} {name}");
            assert_eq!(
                u64::from(lf.records_per_sample),
                want["records_per_sample"].as_u64().unwrap(),
                "{id} {name}"
            );
        }
        if let Some(written) = case.get("flattened_from_records_per_sample") {
            for (name, value) in written.as_object().unwrap() {
                let var = &flat.parameters[name.as_str()];
                assert_eq!(
                    from_records(var).map(u64::from),
                    value.as_u64(),
                    "{id}: flattened {name}"
                );
            }
        }
        // The field survives emit -> load unchanged.
        let again = load_string(&to_json(&file).unwrap()).unwrap();
        for (mname, model) in file.models.iter().flatten() {
            for (vname, var) in &model.variables {
                let other = &again.models.as_ref().unwrap()[mname].variables[vname];
                assert_eq!(
                    from_records(var),
                    from_records(other),
                    "{id}: {mname}.{vname}"
                );
            }
        }
    }
}

#[test]
fn invalid_cases_are_refused_at_the_pinned_pointer() {
    let m = manifest();
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "invalid" {
            continue;
        }
        let id = case["id"].as_str().unwrap();
        let result = validate(&load(case));
        let found: Vec<&str> = result
            .structural_errors
            .iter()
            .filter(|e| e.code.to_string() == case["code"].as_str().unwrap())
            .map(|e| e.path.as_str())
            .collect();
        assert_eq!(found, vec![case["pointer"].as_str().unwrap()], "{id}");
    }
}
