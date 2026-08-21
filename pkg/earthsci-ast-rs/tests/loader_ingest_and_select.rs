//! The loader-ingest surface of esm-spec §8.9, executed: `reader_options`,
//! `codes`, `record_filter`, `extent` and `select` served by
//! `providers_from_document` + `prepare`, over real local fixtures (an FF10
//! zip and a Zarr v2 store, both over the `file` transport — no network).
//!
//! The document under test is the committed fixture
//! `tests/valid/data_sources_ingest_and_select.esm`; only its two
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
//!     array, so no caller samples the grid twice to slice a prefix; and
//!     `W` gated on `emis_cells` is a third, which DEFERS rather than reads,
//!     so no caller fetches the whole axis to keep three rows of it.
//!
//! Together they are the difference between a document a general-purpose
//! runner can run and a document only a model-aware runner can run.

#![cfg(feature = "esio")]

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;
use std::rc::Rc;

use earthsci_ast::esio_provider::{EsioProvider, providers_from_document};
use earthsci_ast::prepare::{AxisSel, PrepareError, PrepareOptions, PrepareProvider, prepare};
use earthsci_ast::pushdown_rewrite::GateAxis;
use ndarray::ArrayD;
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
        .join("../../tests/valid/data_sources_ingest_and_select.esm");
    let mut doc: Value = serde_json::from_str(
        &fs::read_to_string(&path).expect("read data_sources_ingest_and_select.esm"),
    )
    .expect("fixture parses");
    doc["data_sources"]["EGU_Emis"]["source"]["url_template"] = json!(write_ff10_zip(dir));
    doc["data_sources"]["Grid"]["source"]["url_template"] = json!(write_grid_store(dir, 10));
    doc
}

/// The `update.from` binding of the parameter a provider key names.
///
/// From esm 1.0.0 the data binding lives on the CONSUMER: `codes`, `select` and
/// `unit_conversion` are fields of the reading parameter's `update.from`, not of
/// a variable the source declares — a source declares none (esm-spec §8.5).
fn binding_mut<'a>(doc: &'a mut Value, key: &str) -> &'a mut Value {
    let (model, param) = key.split_once('.').expect("a provider key is Model.param");
    &mut doc["models"][model]["variables"][param]["update"]["from"]
}

/// The `data_sources` key the parameter a provider key names reads.
fn source_of(doc: &Value, key: &str) -> String {
    let (model, param) = key.split_once('.').expect("a provider key is Model.param");
    doc["models"][model]["variables"][param]["update"]["source"]
        .as_str()
        .expect("a data update names its source")
        .to_string()
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
        sample(&doc, &cache, "Ingest.pollutant"),
        vec![36.0, 36.0, 1.0],
        "POLID text -> the declared enum, unmapped records dropped"
    );
    assert_eq!(
        sample(&doc, &cache, "Ingest.annual"),
        vec![100.0, 7.0, 3.0]
    );
    assert_eq!(
        sample(&doc, &cache, "Ingest.lon"),
        vec![-90.0, -92.0, -93.0]
    );
    assert_eq!(sample(&doc, &cache, "Ingest.lat"), vec![40.0, 43.0, 44.0]);
}

#[test]
fn every_variable_of_a_filtered_loader_declares_the_same_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");
    for (key, p) in &provs {
        let declared = PrepareProvider::extent_metaparameter(p);
        // `extent` is the SOURCE's, inherited by every parameter that reads it.
        // A provider key names the consuming parameter, so the source comes from
        // that parameter's own `update` rather than from a prefix on the key.
        if source_of(&doc, key) == "EGU_Emis" {
            assert_eq!(
                declared.as_deref(),
                Some("N_REC"),
                "{key} must bind the source's extent metaparameter"
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
    binding_mut(&mut doc, "Ingest.pollutant")
        .as_object_mut()
        .expect("the binding is an object")
        .remove("codes");
    let mut provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");
    let (_, p) = provs
        .iter_mut()
        .find(|(k, _)| k == "Ingest.pollutant")
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

    let full = sample(&doc, &cache, "Ingest.W");
    assert_eq!(full.len(), 10, "the unselected variable is unaffected");
    assert_eq!(full[0], 100.0);

    // stop is the METAPARAMETER name N_SRC (default 4), not a repeated literal.
    let prefix = sample(&doc, &cache, "Ingest.src_W");
    assert_eq!(prefix, full[..4].to_vec());
    assert_eq!(prefix, vec![100.0, 101.0, 102.0, 103.0]);
}

#[test]
fn a_range_select_over_a_filtered_table_counts_surviving_records() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    // A loader-level select is the default for every variable of the loader —
    // which is what keeps a truncated table aligned.
    doc["data_sources"]["EGU_Emis"]["select"] =
        json!({"axes": [{"range": {"start": 0, "stop": 2}}]});
    let cache = tmp.path().join("cache");

    assert_eq!(
        sample(&doc, &cache, "Ingest.annual"),
        vec![100.0, 7.0],
        "[0:2] is the first two SURVIVING records (100, 7) — never the first two \
         raw rows (100, 50) of which one is dropped"
    );
    assert_eq!(sample(&doc, &cache, "Ingest.pollutant"), vec![36.0, 36.0]);
    assert_eq!(sample(&doc, &cache, "Ingest.lon"), vec![-90.0, -92.0]);
}

#[test]
fn a_truncated_table_re_discovers_its_own_smaller_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_sources"]["EGU_Emis"]["select"] =
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

/// FORMAT-08-A-006: a mis-typed decode option cannot quietly select nothing.
/// The Julia/Python mirrors of this file have asserted it since they were
/// written; Rust could not, because `DataSource` had no `reader_options` to
/// mis-type.
#[test]
fn an_unrecognised_reader_option_is_refused_at_construction() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_sources"]["EGU_Emis"]["reader_options"]["member_filter"] = json!("*egu*");
    let e = match providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
    {
        Ok(_) => panic!("a mis-typed reader option must not build a provider"),
        Err(e) => e.0,
    };
    assert!(e.contains("member_filter"), "{e}");
    assert!(e.contains("member_glob"), "{e}"); // names what it DOES accept
}

/// Without the declared glob the loader reads the WRONG members — which is why
/// an ignored option is a defect rather than a nicety.
#[test]
fn reader_options_are_load_bearing_not_decorative() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    doc["data_sources"]["EGU_Emis"]["reader_options"] = json!({});
    let mut provs =
        providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
            .expect("providers build");
    let (_, p) = provs
        .iter_mut()
        .find(|(k, _)| k == "Ingest.annual")
        .expect("no provider Ingest.annual");
    assert!(
        p.sample().is_err(),
        "a whole-zip read cannot decode as one FF10 table"
    );
}

#[test]
fn an_unrecognised_axis_selector_is_refused_at_construction() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let mut doc = document(tmp.path());
    binding_mut(&mut doc, "Ingest.src_W")["select"] = json!({"axes": [{"prefix": 4}]});
    let e = match providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new()) {
        Err(e) => e.to_string(),
        Ok(_) => panic!("an unknown selector must not be ignored"),
    };
    assert!(e.contains("unrecognised axis selector keys"), "{e}");
}

// --------------------------------------------------------------------------- //
// U3 — a GATED select in the loader
//
// `gated_by` is the one selector of the §8.9.2 vocabulary that is not
// resolvable at read time: its axis is a derived index set whose members the
// graph invents, so the fetch must wait for value-invention and then ask for
// exactly those members. `CONFORMANCE_SPEC §5.5`: *"Only `gated_by` defers; the
// other three are resolvable at read time."*
//
// The failure these pin is silent and expensive rather than loud: a gate that
// does NOT defer is flattened to the full axis and read eagerly, so the answer
// is still an array — just one built from the whole store. On the ISRM SR
// matrix that is a 52,411-row source axis instead of 1,520 members.
// --------------------------------------------------------------------------- //

/// What the engine actually ASKED a provider for. `Whole` is the wholesale
/// read a gate is supposed to make unnecessary.
#[derive(Debug, Clone, PartialEq)]
enum Fetch {
    Whole,
    Selection(Vec<AxisSel>),
}

/// A recording pass-through, so a test can assert on the REQUEST rather than
/// only on the array that comes back. Delegates every decision to the real
/// provider — it observes the fetch, it does not change it.
struct SpyProvider {
    inner: EsioProvider,
    calls: Rc<RefCell<Vec<Fetch>>>,
}

impl PrepareProvider for SpyProvider {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        self.calls.borrow_mut().push(Fetch::Whole);
        self.inner.sample()
    }

    fn supports_selection(&self) -> bool {
        PrepareProvider::supports_selection(&self.inner)
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        self.calls
            .borrow_mut()
            .push(Fetch::Selection(selection.to_vec()));
        self.inner.sample_with_selection(selection)
    }

    fn is_const(&self) -> bool {
        self.inner.is_const()
    }

    fn gate_spec(&self) -> Option<earthsci_ast::pushdown_rewrite::ProviderGate> {
        self.inner.gate_spec()
    }

    fn extent_metaparameter(&self) -> Option<String> {
        PrepareProvider::extent_metaparameter(&self.inner)
    }
}

/// The document's providers, each wrapped in a [`SpyProvider`], plus the shared
/// per-key call logs.
#[allow(clippy::type_complexity)]
fn spied_providers(
    doc: &Value,
    cache_root: &Path,
) -> (
    Vec<(String, Box<dyn PrepareProvider>)>,
    HashMap<String, Rc<RefCell<Vec<Fetch>>>>,
) {
    let mut logs = HashMap::new();
    let provs = providers_from_document(doc, cache_root, None, &HashMap::new())
        .expect("providers build from the document")
        .into_iter()
        .map(|(k, p)| {
            let calls = Rc::new(RefCell::new(Vec::new()));
            logs.insert(k.clone(), calls.clone());
            let spy: Box<dyn PrepareProvider> = Box::new(SpyProvider { inner: p, calls });
            (k, spy)
        })
        .collect();
    (provs, logs)
}

#[test]
fn a_gated_select_is_reported_as_a_gate_not_pushed_to_the_reader() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");

    for (key, p) in &provs {
        let gate = PrepareProvider::gate_spec(p);
        if key == "Ingest.emis_W" {
            let gate = gate.unwrap_or_else(|| {
                panic!(
                    "{key} declares select.axes = [{{gated_by: emis_cells}}] on a store-backed \
                     reader with no record filter, so it MUST defer. Reporting no gate means \
                     the select was pushed to the reader instead, where a gated axis has no \
                     spelling and flattens to the FULL axis — a whole-store read."
                )
            });
            assert_eq!(
                gate.axes,
                vec![GateAxis::GatedBy("emis_cells".to_string())],
                "the gate carries the declared axis verbatim"
            );
            assert_eq!(
                gate.applies_to,
                vec!["emis_W".to_string()],
                "one provider per fed variable"
            );
        } else {
            assert!(
                gate.is_none(),
                "{key} declares no gated axis, so it stays an ordinary eager read"
            );
        }
    }

    // The reader-resolvable neighbours are the control: `gated_by` defers, the
    // other three selectors do not, and this fixture holds one of each on the
    // SAME `file_variable`.
    assert!(
        provs.iter().any(|(k, _)| k == "Ingest.src_W"),
        "the range-selected sibling must still be built"
    );
}

#[test]
fn a_gated_fetch_asks_for_the_support_set_and_never_the_full_axis() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let (providers, logs) = spied_providers(&doc, &tmp.path().join("cache"));

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

    // The graph invented the support set from the emission records: the three
    // surviving points at -90, -92 and -93 fall in 1-based cells 5, 3 and 2.
    assert_eq!(
        prep.members.get("emis_cell_set"),
        Some(&vec![2i64, 3, 5]),
        "the distinct member set is sorted, not insertion-ordered"
    );
    assert_eq!(
        prep.gated_provider_keys,
        vec!["Ingest.emis_W".to_string()],
        "exactly the gated loader variable was deferred"
    );

    // THE ASSERTION THIS FILE EXISTS FOR: the request names the support set's
    // members (0-based for the reader), not the whole 10-cell axis.
    let calls = logs["Ingest.emis_W"].borrow();
    assert_eq!(
        *calls,
        vec![Fetch::Selection(vec![AxisSel::Indices(vec![1, 2, 4])])],
        "the gated fetch must be ONE pre-sliced request for the invented members; \
         a `Whole` call (or an `AxisSel::All`) means the gate was flattened and the \
         entire array was read"
    );

    // ... and the values that arrive are those cells' — W[1], W[2], W[4] of the
    // 100+i store — so the compact slab is the right slab, not merely the right
    // length.
    assert_eq!(
        prep.observed_field("emis_width")
            .expect("emis_width")
            .iter()
            .copied()
            .collect::<Vec<f64>>(),
        vec![102.0, 103.0, 105.0],
        "101, 102, 104 delivered on the derived axis, each + 1"
    );
}

#[test]
fn the_ungated_siblings_are_still_read_eagerly_and_whole() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let (providers, logs) = spied_providers(&doc, &tmp.path().join("cache"));
    prepare(
        &doc,
        HashMap::new(),
        providers,
        &PrepareOptions {
            pushdown_rewrite: true,
            ..Default::default()
        },
    )
    .expect("prepare");

    // Deferral is NOT the new default: a `range` select is still resolvable at
    // read time and still taken eagerly, so the fix cannot have been "defer
    // everything".
    for key in ["Ingest.W", "Ingest.src_W"] {
        assert_eq!(
            *logs[key].borrow(),
            vec![Fetch::Whole],
            "{key} declares no gate, so prepare samples it once, eagerly"
        );
    }
}

#[test]
fn an_eager_sample_of_a_gated_variable_refuses_rather_than_reading_everything() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = document(tmp.path());
    let mut provs = providers_from_document(&doc, &tmp.path().join("cache"), None, &HashMap::new())
        .expect("providers build");
    let (_, p) = provs
        .iter_mut()
        .find(|(k, _)| k == "Ingest.emis_W")
        .expect("no provider Ingest.emis_W");

    // Sampling a gated provider out of band is a caller error, and it must SAY
    // so. Silently returning the full axis here is the same defect one layer
    // down: the whole store, dressed up as an answer.
    let msg = p
        .sample()
        .expect_err("an eager sample cannot resolve a gate")
        .0;
    assert!(msg.contains("emis_cells"), "{msg}");
    assert!(msg.contains("value-invention"), "{msg}");
}
