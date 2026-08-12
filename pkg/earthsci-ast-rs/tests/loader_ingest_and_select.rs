//! The loader-ingest surface of esm-spec §8.9, executed: `reader_options`,
//! `codes`, `record_filter`, `extent` and `select` served by
//! `providers_from_document` + `prepare`, over real local fixtures (an FF10
//! zip and a Zarr v2 store, both over the `file` transport — no network).
//!
//! The document under test is the committed fixture
//! `tests/valid/data_loaders_ingest_and_select.esm`; only its two
//! `url_template`s are patched onto the temporary fixtures, so what the
//! validation sweep checks and what this file runs are the same declaration.
//!
//! What each property BUYS, since that is what the tests are really pinning:
//!
//!   * `reader_options` — the zip member glob and the asserted header row come
//!     from the document, so no caller injects a configured reader;
//!   * `codes` + `record_filter` — the POLID text column becomes the pollutant
//!     enum and the unrecognised / uncoordinated records disappear, ONCE, for
//!     every variable of the loader at the same time;
//!   * `extent` — the surviving count binds `N_REC`, so no caller counts rows;
//!   * `select` — `W[0:N_SRC]` is a second variable over the same on-disk
//!     array, so no caller samples the grid twice to slice a prefix.
//!
//! Together they are the difference between a document a general-purpose
//! runner can run and a document only a model-aware runner can run.

#![cfg(feature = "esio")]

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;

use earthsci_ast::esio_provider::providers_from_document;
use earthsci_ast::prepare::{PrepareOptions, PrepareProvider, prepare};
use serde_json::{Value, json};

// --------------------------------------------------------------------------- //
// Fixtures
// --------------------------------------------------------------------------- //

/// The FF10 point schema's 77 columns, by the indices this fixture writes.
const C_POLID: usize = 12;
const C_ANN: usize = 13;
const C_LON: usize = 23;
const C_LAT: usize = 24;
const N_COL: usize = 77;

fn ff10_row(polid: &str, ann: &str, lon: &str, lat: &str) -> String {
    let mut r = vec![String::new(); N_COL];
    r[0] = "US".into();
    r[1] = "01001".into();
    r[C_POLID] = polid.into();
    r[C_ANN] = ann.into();
    r[C_LON] = lon.into();
    r[C_LAT] = lat.into();
    r.join(",")
}

/// An EPA-2016fd-shaped zip: a `#` comment block + a `country_cd,…` header line
/// per member, two `*egu*` members and one the glob must exclude.
///
/// The `*egu*` rows, in the order the reader concatenates them (member name
/// ascending), and what the document's declarations do to each:
///
/// | POLID | ann | lon | fate |
/// |---|---|---|---|
/// | NOX  | 100 | -90 | kept, code 36 |
/// | CO   |  50 | -91 | DROPPED — not in the `codes` map |
/// | SO2  |  25 |     | DROPPED — blank longitude is not finite |
/// | nox  |   7 | -92 | kept, code 36 (`case_insensitive`) |
/// | VOC  |   3 | -93 | kept, code 1 |
fn write_ff10_zip(dir: &Path) -> String {
    use std::io::Write;
    let header: String = [
        "country_cd",
        "region_cd",
        "tribal_code",
        "facility_id",
        "unit_id",
        "rel_point_id",
        "process_id",
        "agy_facility_id",
        "agy_unit_id",
        "agy_rel_point_id",
        "agy_process_id",
        "scc",
        "polid",
        "ann_value",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain((14..N_COL).map(|i| format!("col{i}")))
    .collect::<Vec<_>>()
    .join(",");

    let member = |rows: &[String]| format!("#FORMAT=FF10_POINT\n{header}\n{}\n", rows.join("\n"));
    let path = dir.join("2016fd_inputs_point.zip");
    let f = fs::File::create(&path).expect("create zip");
    let mut zw = zip::ZipWriter::new(f);
    for (name, rows) in [
        (
            "point/egu_alpha.csv",
            vec![
                ff10_row("NOX", "100.0", "-90.0", "40.0"),
                ff10_row("CO", "50.0", "-91.0", "41.0"),
                ff10_row("SO2", "25.0", "", "42.0"),
            ],
        ),
        (
            "point/egu_beta.csv",
            vec![
                ff10_row("nox", "7.0", "-92.0", "43.0"),
                ff10_row("VOC", "3.0", "-93.0", "44.0"),
            ],
        ),
        (
            "point/ptnonipm.csv",
            vec![ff10_row("NOX", "999.0", "-94.0", "45.0")],
        ),
    ] {
        zw.start_file::<_, ()>(name, zip::write::SimpleFileOptions::default())
            .expect("start member");
        zw.write_all(member(&rows).as_bytes())
            .expect("write member");
    }
    zw.finish().expect("finish zip");
    format!("file://{}", path.display())
}

/// A Zarr v2 store with one uncompressed 1-D `W` array, `W[i] = 100 + i`.
fn write_grid_store(dir: &Path, n: usize) -> String {
    let store = dir.join("grid.zarr");
    let arr = store.join("W");
    fs::create_dir_all(&arr).expect("create array dir");
    fs::write(
        arr.join(".zarray"),
        format!(
            r#"{{"zarr_format":2,"shape":[{n}],"chunks":[{n}],"dtype":"<f8",
                "compressor":null,"fill_value":0.0,"order":"C","filters":null}}"#
        ),
    )
    .expect("write .zarray");
    fs::write(arr.join(".zattrs"), r#"{"_ARRAY_DIMENSIONS":["cell"]}"#).expect("write .zattrs");
    let mut buf = Vec::with_capacity(n * 8);
    for i in 0..n {
        buf.extend_from_slice(&(100.0 + i as f64).to_le_bytes());
    }
    fs::write(arr.join("0"), &buf).expect("write chunk");
    format!("file://{}/", store.display())
}

/// The committed fixture with its two placeholder URLs pointed at `dir`.
fn document(dir: &Path) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/valid/data_loaders_ingest_and_select.esm");
    let mut doc: Value = serde_json::from_str(
        &fs::read_to_string(&path).expect("read data_loaders_ingest_and_select.esm"),
    )
    .expect("fixture parses");
    doc["data_loaders"]["EGU_Emis"]["source"]["url_template"] = json!(write_ff10_zip(dir));
    doc["data_loaders"]["Grid"]["source"]["url_template"] = json!(write_grid_store(dir, 10));
    doc
}

fn sample(doc: &Value, cache_root: &Path, key: &str) -> Vec<f64> {
    let mut provs = providers_from_document(doc, cache_root, None, &HashMap::new())
        .expect("providers build from the document");
    let (_, p) = provs
        .iter_mut()
        .find(|(k, _)| k == key)
        .unwrap_or_else(|| panic!("no provider {key}"));
    p.sample()
        .unwrap_or_else(|e| panic!("sample {key}: {e}"))
        .iter()
        .copied()
        .collect()
}

// --------------------------------------------------------------------------- //
// U1 — the ingest is the loader's, not the caller's
// --------------------------------------------------------------------------- //

#[test]
fn the_document_alone_decodes_maps_and_filters_the_ff10_table() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let cache = tmp.path().join("cache");

    // reader_options selected the two *egu* members and dropped their header
    // lines; codes mapped POLID; record_filter removed the unmapped CO record
    // and the SO2 record with no longitude. All of it from the declaration.
    assert_eq!(
        sample(&doc, &cache, "EGU_Emis.pollutant"),
        vec![36.0, 36.0, 1.0],
        "POLID text -> the declared enum, unmapped records dropped"
    );
    assert_eq!(
        sample(&doc, &cache, "EGU_Emis.annual"),
        vec![100.0, 7.0, 3.0]
    );
    assert_eq!(
        sample(&doc, &cache, "EGU_Emis.lon"),
        vec![-90.0, -92.0, -93.0]
    );
    assert_eq!(sample(&doc, &cache, "EGU_Emis.lat"), vec![40.0, 43.0, 44.0]);
}

#[test]
fn every_variable_of_a_filtered_loader_declares_the_same_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");
    for (key, p) in &provs {
        let declared = PrepareProvider::extent_metaparameter(p);
        if key.starts_with("EGU_Emis.") {
            assert_eq!(
                declared.as_deref(),
                Some("N_REC"),
                "{key} must bind the loader's extent metaparameter"
            );
        } else {
            assert_eq!(declared, None, "{key} declares no extent");
        }
    }
}

#[test]
fn prepare_discovers_n_rec_and_the_graph_is_sized_by_it() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let providers = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build")
        .into_iter()
        .map(|(k, p)| (k, Box::new(p) as Box<dyn PrepareProvider>))
        .collect();

    // NOTE the empty metaparameters: the caller passes NO N_REC. The document
    // declares that the loader knows it.
    let prep = prepare(
        &doc,
        HashMap::new(),
        providers,
        &PrepareOptions {
            metaparameters: BTreeMap::new(),
            pushdown_rewrite: true,
            ..Default::default()
        },
    )
    .expect("prepare");

    let is_nox: Vec<f64> = prep
        .observed_field("is_NOx")
        .expect("is_NOx")
        .iter()
        .copied()
        .collect();
    assert_eq!(
        is_nox,
        vec![1.0, 1.0, 0.0],
        "the observed graph is evaluated over the 3 SURVIVING records"
    );
    let e_nox = prep.observed_field("E_NOx").expect("E_NOx");
    assert_eq!(
        e_nox.iter().copied().collect::<Vec<f64>>(),
        vec![107.0],
        "100 + 7 — the dropped CO/SO2 records contribute nothing because they \
         are not records"
    );
}

#[test]
fn a_caller_binding_that_contradicts_the_discovered_extent_is_an_error() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let providers = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build")
        .into_iter()
        .map(|(k, p)| (k, Box::new(p) as Box<dyn PrepareProvider>))
        .collect();
    let mut metaparameters = BTreeMap::new();
    metaparameters.insert("N_REC".to_string(), 5); // the RAW row count, a stale guess
    let msg = match prepare(
        &doc,
        HashMap::new(),
        providers,
        &PrepareOptions {
            metaparameters,
            pushdown_rewrite: true,
            ..Default::default()
        },
    ) {
        Err(e) => e.to_string(),
        Ok(_) => panic!("a contradicted extent must not be silently preferred either way"),
    };
    assert!(msg.contains("N_REC"), "{msg}");
    assert!(msg.contains("discovers 3"), "{msg}");
}

#[test]
fn a_text_column_with_no_codes_map_is_a_boundary_error() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_loaders"]["EGU_Emis"]["variables"]["pollutant"]
        .as_object_mut()
        .unwrap()
        .remove("codes");
    let mut provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");
    let (_, p) = provs
        .iter_mut()
        .find(|(k, _)| k == "EGU_Emis.pollutant")
        .unwrap();
    let msg = p.sample().expect_err("a text forcing must not load").0;
    assert!(msg.contains("decoded as strings"), "{msg}");
    assert!(msg.contains("codes"), "{msg}");
}

// --------------------------------------------------------------------------- //
// U2 — a range select in the loader
// --------------------------------------------------------------------------- //

#[test]
fn a_range_select_delivers_a_prefix_of_the_same_on_disk_array() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let cache = tmp.path().join("cache");

    let full = sample(&doc, &cache, "Grid.W");
    assert_eq!(full.len(), 10, "the unselected variable is unaffected");
    assert_eq!(full[0], 100.0);

    // stop is the METAPARAMETER name N_SRC (default 4), not a repeated literal.
    let prefix = sample(&doc, &cache, "Grid.src_W");
    assert_eq!(prefix, full[..4].to_vec());
    assert_eq!(prefix, vec![100.0, 101.0, 102.0, 103.0]);
}

#[test]
fn a_range_select_over_a_filtered_table_counts_surviving_records() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    // A loader-level select is the default for every variable of the loader —
    // which is what keeps a truncated table aligned.
    doc["data_loaders"]["EGU_Emis"]["select"] =
        json!({"axes": [{"range": {"start": 0, "stop": 2}}]});
    let cache = tmp.path().join("cache");

    assert_eq!(
        sample(&doc, &cache, "EGU_Emis.annual"),
        vec![100.0, 7.0],
        "[0:2] is the first two SURVIVING records (100, 7) — never the first two \
         raw rows (100, 50) of which one is dropped"
    );
    assert_eq!(sample(&doc, &cache, "EGU_Emis.pollutant"), vec![36.0, 36.0]);
    assert_eq!(sample(&doc, &cache, "EGU_Emis.lon"), vec![-90.0, -92.0]);
}

#[test]
fn a_truncated_table_re_discovers_its_own_smaller_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_loaders"]["EGU_Emis"]["select"] =
        json!({"axes": [{"range": {"start": 0, "stop": 2}}]});
    let providers = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build")
        .into_iter()
        .map(|(k, p)| (k, Box::new(p) as Box<dyn PrepareProvider>))
        .collect();
    let prep = prepare(
        &doc,
        HashMap::new(),
        providers,
        &PrepareOptions {
            pushdown_rewrite: true,
            ..Default::default()
        },
    )
    .expect("prepare");
    assert_eq!(
        prep.observed_field("E_NOx")
            .expect("E_NOx")
            .iter()
            .copied()
            .collect::<Vec<f64>>(),
        vec![107.0]
    );
    assert_eq!(
        prep.observed_field("is_NOx").expect("is_NOx").len(),
        2,
        "N_REC follows the DELIVERED records, so a reduced run needs no other knob"
    );
}

#[test]
fn the_selected_prefix_reaches_the_model_as_its_own_axis() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let providers = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build")
        .into_iter()
        .map(|(k, p)| (k, Box::new(p) as Box<dyn PrepareProvider>))
        .collect();
    let prep = prepare(
        &doc,
        HashMap::new(),
        providers,
        &PrepareOptions {
            pushdown_rewrite: true,
            ..Default::default()
        },
    )
    .expect("prepare");
    let w = prep.observed_field("src_width").expect("src_width");
    assert_eq!(
        w.shape(),
        &[4],
        "src_W is delivered on src_cells (N_SRC), not on the full pop_cells axis"
    );
    assert_eq!(
        w.iter().copied().collect::<Vec<f64>>(),
        vec![101.0, 102.0, 103.0, 104.0]
    );
}

#[test]
fn an_unrecognised_axis_selector_is_refused_at_construction() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_loaders"]["Grid"]["variables"]["src_W"]["select"] = json!({"axes": [{"prefix": 4}]});
    let e = match providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new()) {
        Err(e) => e.to_string(),
        Ok(_) => panic!("an unknown selector must not be ignored"),
    };
    assert!(e.contains("unrecognised axis selector keys"), "{e}");
}
