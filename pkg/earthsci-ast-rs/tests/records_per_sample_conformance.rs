//! Conformance: record axes and the deprecated `records_per_sample`
//! (esm-spec §8.5.1).
//!
//! Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
//! must validate with none of the manifest's `record_codes`, and flatten with
//! each listed `LoaderField` reporting the number of records the parameter's
//! record shape gives it; the flattened parameter's `update.from` keeps the
//! deprecated field as written; the field and each index set's `records` flag
//! survive emit then load; and `deprecated_records_per_sample_sites` returns
//! exactly the case's `deprecated_fields`, the sites the load warning names.
//! An invalid case must be refused by structural validation with exactly one
//! `record_codes` diagnostic, `code` at `pointer`; a flatten-invalid case must
//! pass validation and be refused by flatten with that code and pointer; a
//! refused case may be refused by either stage.

use earthsci_ast::{
    CouplingImportOptions, EsmFile, FlattenError, FlattenedSystem,
    deprecated_records_per_sample_sites, flatten_with_options, load_path, load_string, to_json,
    validate,
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

fn cases<'a>(m: &'a Value, expect: &str) -> Vec<&'a Value> {
    m["cases"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["expect"] == expect)
        .collect()
}

fn case_path(case: &Value) -> PathBuf {
    tier_dir().join(case["path"].as_str().unwrap())
}

fn load(case: &Value) -> EsmFile {
    load_path(case_path(case)).unwrap_or_else(|e| panic!("{}: {e}", case["id"]))
}

/// Flatten `case`, resolving `coupling_import` refs against its directory.
fn flatten_case(case: &Value, file: &EsmFile) -> Result<FlattenedSystem, FlattenError> {
    let path = case_path(case);
    let options = CouplingImportOptions {
        base_path: path.parent().unwrap().to_string_lossy().into_owned(),
        ..Default::default()
    };
    flatten_with_options(file, &options)
}

/// The `(code, pointer)` of each diagnostic in the manifest's `record_codes`
/// that structural validation reports.
fn record_findings(m: &Value, file: &EsmFile) -> Vec<(String, String)> {
    let codes: Vec<&str> = m["record_codes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c.as_str().unwrap())
        .collect();
    validate(file)
        .structural_errors
        .iter()
        .map(|e| (e.code.to_string(), e.path.clone()))
        .filter(|(code, _)| codes.contains(&code.as_str()))
        .collect()
}

fn expected_finding(case: &Value) -> Vec<(String, String)> {
    vec![(
        case["code"].as_str().unwrap().to_string(),
        case["pointer"].as_str().unwrap().to_string(),
    )]
}

/// Asserts that flatten refuses `file` with the case's code, naming its pointer.
fn assert_flatten_refuses(case: &Value, file: &EsmFile) {
    let id = case["id"].as_str().unwrap();
    let err = match flatten_case(case, file) {
        Ok(_) => panic!("{id}: flatten accepted the document"),
        Err(e) => e.to_string(),
    };
    assert!(
        err.contains(&format!("[{}]", case["code"].as_str().unwrap()))
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

/// Each index set's `records` flag, by name.
fn record_flags(file: &EsmFile) -> Vec<(String, Option<bool>)> {
    let mut flags: Vec<(String, Option<bool>)> = file
        .index_sets
        .iter()
        .flatten()
        .map(|(name, set)| (name.clone(), set.records))
        .collect();
    flags.sort();
    flags
}

fn expected_sites(case: &Value) -> Vec<String> {
    case["deprecated_fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn valid_cases_report_the_records_their_record_shape_gives() {
    let m = manifest();
    let valid = cases(&m, "valid");
    assert!(!valid.is_empty());
    for case in valid {
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        assert_eq!(record_findings(&m, &file), vec![], "{id}");
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
        // The deprecated sites are exactly the manifest's.
        let sites = deprecated_records_per_sample_sites(&file);
        assert_eq!(sites, expected_sites(case), "{id}: deprecated sites");
        // The field and the `records` flag survive emit -> load unchanged.
        let again = load_string(&to_json(&file).unwrap()).unwrap();
        assert_eq!(
            deprecated_records_per_sample_sites(&again),
            sites,
            "{id}: sites after emit -> load"
        );
        assert_eq!(record_flags(&again), record_flags(&file), "{id}: records");
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
fn the_record_axis_flag_is_loaded_and_emitted() {
    let m = manifest();
    let case = cases(&m, "valid")
        .into_iter()
        .find(|c| c["id"] == "record_axis")
        .unwrap();
    let file = load(case);
    let sets = file.index_sets.as_ref().unwrap();
    assert_eq!(sets["rec"].records, Some(true));
    assert_eq!(sets["pair2"].records, None);
    let emitted: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
    assert_eq!(emitted["index_sets"]["rec"]["records"], Value::Bool(true));
    assert!(emitted["index_sets"]["pair2"].get("records").is_none());
}

#[test]
fn invalid_cases_are_refused_at_the_pinned_pointer() {
    let m = manifest();
    let invalid = cases(&m, "invalid");
    assert!(!invalid.is_empty());
    for case in invalid {
        let id = case["id"].as_str().unwrap();
        assert_eq!(
            record_findings(&m, &load(case)),
            expected_finding(case),
            "{id}"
        );
    }
}

#[test]
fn flatten_invalid_cases_pass_validation_and_are_refused_by_flatten() {
    let m = manifest();
    let flatten_invalid = cases(&m, "flatten_invalid");
    assert!(!flatten_invalid.is_empty());
    for case in flatten_invalid {
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        assert_eq!(
            record_findings(&m, &file),
            vec![],
            "{id}: validation refused what only flatten can see"
        );
        assert_flatten_refuses(case, &file);
    }
}

#[test]
fn refused_cases_are_refused_by_validation_or_flatten() {
    let m = manifest();
    let refused = cases(&m, "refused");
    assert!(!refused.is_empty());
    for case in refused {
        let id = case["id"].as_str().unwrap();
        let file = load(case);
        let found = record_findings(&m, &file);
        if found.is_empty() {
            assert_flatten_refuses(case, &file);
        } else {
            assert_eq!(found, expected_finding(case), "{id}");
        }
    }
}

#[test]
fn a_target_validation_cannot_reach_is_not_an_empty_record_shape() {
    // Retarget the param_to_var edge onto a model the document does not
    // declare: the record shape is not decidable, so validation is silent
    // although the parameter writes the deprecated 2.
    let m = manifest();
    let case = cases(&m, "valid")
        .into_iter()
        .find(|c| c["id"] == "records_per_sample_deprecated_param_to_var")
        .unwrap();
    let mut file = load(case);
    for entry in file.coupling.iter_mut().flatten() {
        if let earthsci_ast::CouplingEntry::VariableMap { to, .. } = entry {
            *to = "Nowhere.F_k".to_string();
        }
    }
    assert_eq!(record_findings(&m, &file), vec![]);
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

/// Loading warns `deprecated_records_per_sample` once, naming the sites,
/// exactly when the deprecated field is written; checked through the `esm`
/// binary, whose `validate` loads the file once, so its stderr is the load's.
#[cfg(all(not(target_arch = "wasm32"), feature = "cli", feature = "solve"))]
#[test]
fn loading_warns_once_exactly_when_the_field_is_written() {
    let m = manifest();
    for case in cases(&m, "valid") {
        let id = case["id"].as_str().unwrap();
        let out = std::process::Command::new(env!("CARGO_BIN_EXE_esm"))
            .arg("validate")
            .arg(case_path(case))
            .output()
            .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
        let stderr = String::from_utf8_lossy(&out.stderr);
        let warnings = stderr
            .matches("warning: deprecated_records_per_sample:")
            .count();
        let sites = expected_sites(case);
        if sites.is_empty() {
            assert_eq!(warnings, 0, "{id}: {stderr}");
        } else {
            assert_eq!(warnings, 1, "{id}: {stderr}");
            assert!(
                stderr.contains(&format!("Written at: {}.", sites.join(", "))),
                "{id}: {stderr}"
            );
        }
    }
}
