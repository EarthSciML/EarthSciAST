//! Conformance: `from.records_per_sample` (esm-spec §8.5.1).
//!
//! Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
//! must validate, round-trip the field, and flatten with each data-fed
//! parameter's `LoaderField` reporting the EFFECTIVE value (the binding's own,
//! else the source's `temporal.records_per_sample`, else 1) and the flattened
//! parameter's `update.from` carrying the field as written. An invalid case
//! must be refused by structural validation with exactly one
//! `records_per_sample_invalid` at the pinned pointer; a flatten-invalid case
//! must pass validation and be refused by flatten with that code and pointer;
//! a refused case may be refused by either stage.

use earthsci_ast::{
    CouplingImportOptions, EsmFile, FlattenError, FlattenedSystem, flatten_with_options, load_path,
    load_string, to_json, validate,
};
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

/// Flatten `case`, resolving `coupling_import` refs against its directory.
fn flatten_case(case: &Value, file: &EsmFile) -> Result<FlattenedSystem, FlattenError> {
    let path = tier_dir().join(case["path"].as_str().unwrap());
    let options = CouplingImportOptions {
        base_path: path.parent().unwrap().to_string_lossy().into_owned(),
        ..Default::default()
    };
    flatten_with_options(file, &options)
}

/// The `records_per_sample_invalid` pointers structural validation reports.
fn validation_pointers(file: &EsmFile) -> Vec<String> {
    validate(file)
        .structural_errors
        .iter()
        .filter(|e| e.code.to_string() == "records_per_sample_invalid")
        .map(|e| e.path.clone())
        .collect()
}

/// Asserts that flatten refuses `file` with the case's code, naming its pointer.
fn assert_flatten_refuses(case: &Value, file: &EsmFile) {
    let id = case["id"].as_str().unwrap();
    let err = match flatten_case(case, file) {
        Ok(_) => panic!("{id}: flatten accepted the document"),
        Err(e) => e.to_string(),
    };
    assert!(
        err.contains(case["code"].as_str().unwrap())
            && err.contains(case["pointer"].as_str().unwrap()),
        "{id}: {err}"
    );
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
        let flat = flatten_case(case, &file).unwrap_or_else(|e| panic!("{id}: {e}"));
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
        let found = validation_pointers(&load(case));
        assert_eq!(found, vec![case["pointer"].as_str().unwrap()], "{id}");
    }
}

#[test]
fn flatten_invalid_cases_pass_validation_and_are_refused_by_flatten() {
    let m = manifest();
    let mut seen = 0;
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "flatten_invalid" {
            continue;
        }
        seen += 1;
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        assert!(
            validation_pointers(&file).is_empty(),
            "{id}: validation refused what only flatten can see"
        );
        assert_flatten_refuses(case, &file);
    }
    assert!(seen > 0, "no flatten_invalid cases in the manifest");
}

#[test]
fn refused_cases_are_refused_by_validation_or_flatten() {
    let m = manifest();
    let mut seen = 0;
    for case in m["cases"].as_array().unwrap() {
        if case["expect"] != "refused" {
            continue;
        }
        seen += 1;
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        let found = validation_pointers(&file);
        if found.is_empty() {
            assert_flatten_refuses(case, &file);
        } else {
            assert_eq!(found, vec![case["pointer"].as_str().unwrap()], "{id}");
        }
    }
    assert!(seen > 0, "no refused cases in the manifest");
}

#[test]
fn a_target_validation_cannot_reach_is_not_an_empty_record_shape() {
    // Retarget the param_to_var edge onto a model the document does not
    // declare: the record shape is not decidable, so validation is silent.
    let m = manifest();
    let case = m["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "records_per_sample_param_to_var")
        .unwrap();
    let mut file = load(case);
    for entry in file.coupling.iter_mut().flatten() {
        if let earthsci_ast::CouplingEntry::VariableMap { to, .. } = entry {
            *to = "Nowhere.F_k".to_string();
        }
    }
    assert!(validation_pointers(&file).is_empty());
}

#[test]
fn loader_field_without_records_per_sample_reads_as_one() {
    let lf: earthsci_ast::LoaderField = serde_json::from_value(serde_json::json!({
        "name": "Box.F", "owner": "Box", "source": "Met",
        "file_variable": "F", "cadence": "discrete"
    }))
    .unwrap();
    assert_eq!(lf.records_per_sample, 1);
}
