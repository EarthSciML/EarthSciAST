//! `providers_from_document_with` over a time-varying esm source (EarthSciIO
//! `spec/esm-sources.md`): esm URL templates, a bound custom substitution, a
//! mirror, and a calendar-month cadence. Mirrors the Python
//! `tests/test_esio_document_cadence.py` and the Julia
//! `test/esio_document_cadence_test.jl`.

#![cfg(feature = "esio")]

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use earthsci_ast::esio_provider::{
    DocumentProviderOptions, EsioProvider, providers_from_document_with,
};
use earthsci_ast::provider::CadenceProvider;
use earthsci_ast::{AxisSel, PrepareProvider};
use serde_json::{Value, json};
use time::OffsetDateTime;

/// A NetCDF-3 classic file holding one `float NOX(TSTEP=1, ROW=2)`.
fn write_month(path: &Path, values: [f32; 2]) {
    fn name(out: &mut Vec<u8>, s: &str) {
        out.extend((s.len() as u32).to_be_bytes());
        out.extend(s.as_bytes());
        while !out.len().is_multiple_of(4) {
            out.push(0);
        }
    }
    let mut h = b"CDF\x01".to_vec();
    h.extend(0u32.to_be_bytes()); // numrecs
    h.extend(0x0Au32.to_be_bytes()); // NC_DIMENSION
    h.extend(2u32.to_be_bytes());
    name(&mut h, "TSTEP");
    h.extend(1u32.to_be_bytes());
    name(&mut h, "ROW");
    h.extend(2u32.to_be_bytes());
    h.extend([0u8; 8]); // no global attributes
    h.extend(0x0Bu32.to_be_bytes()); // NC_VARIABLE
    h.extend(1u32.to_be_bytes());
    name(&mut h, "NOX");
    h.extend(2u32.to_be_bytes());
    h.extend(0u32.to_be_bytes());
    h.extend(1u32.to_be_bytes());
    h.extend([0u8; 8]); // no variable attributes
    h.extend(5u32.to_be_bytes()); // NC_FLOAT
    h.extend(8u32.to_be_bytes()); // vsize
    let begin = h.len() as u32 + 4;
    h.extend(begin.to_be_bytes());
    for v in values {
        h.extend(v.to_be_bytes());
    }
    std::fs::write(path, h).unwrap();
}

fn doc(dir: &Path) -> Value {
    let mirror = dir.join("mirror");
    std::fs::create_dir_all(&mirror).unwrap();
    for m in 1..=3u32 {
        let v = (m * 10) as f32;
        write_month(&mirror.join(format!("nei_agr_{m:02}.ncf")), [v, v + 1.0]);
    }
    json!({
        "esm": "2.0.0",
        "data_sources": {"NEI": {
            "kind": "grid",
            "source": {
                "url_template": format!("file://{}/primary/nei_{{sector}}_{{date:%m}}.ncf", dir.display()),
                "mirrors": [format!("file://{}/nei_{{sector}}_{{date:%m}}.ncf", mirror.display())]
            },
            "temporal": {
                "start": "2016-01-01T00:00:00Z", "end": "2016-12-31T23:59:59Z",
                "file_period": "P1M", "frequency": "P1M",
                "records_per_file": 1, "time_variable": "TSTEP"
            },
            "metadata": {"esio_format": "netcdf"}
        }},
        "models": {"Emis": {"variables": {"nox": {
            "type": "parameter", "units": "mol/s", "shape": ["row"],
            "update": {"kind": "data", "source": "NEI",
                       "from": {"file_variable": "NOX", "unit_conversion": 2.0}}
        }}}}
    })
}

fn options(rps: Option<u32>) -> DocumentProviderOptions {
    let mut subs = HashMap::new();
    subs.insert(
        "NEI".to_string(),
        BTreeMap::from([("sector".to_string(), "agr".to_string())]),
    );
    let mut records = HashMap::new();
    if let Some(n) = rps {
        records.insert("Emis.nox".to_string(), n);
    }
    DocumentProviderOptions {
        substitutions: subs,
        window: Some((
            OffsetDateTime::from_unix_timestamp(1451606400).unwrap(), // 2016-01-01
            OffsetDateTime::from_unix_timestamp(1459468800).unwrap(), // 2016-04-01
        )),
        records_per_sample: records,
        ..Default::default()
    }
}

fn values(p: &mut dyn CadenceProvider, t: f64) -> Vec<f64> {
    let fields = p.refresh(t).unwrap().expect("a sample");
    fields
        .values()
        .next()
        .unwrap()
        .array
        .iter()
        .copied()
        .collect()
}

#[test]
fn a_monthly_source_with_a_bound_sector_reads_each_month() {
    let dir = tempfile::tempdir().unwrap();
    let mut provs =
        providers_from_document_with(&doc(dir.path()), &dir.path().join("cache"), &options(None))
            .unwrap();
    let (key, p) = &mut provs[0];
    assert_eq!(key, "Emis.nox");
    // The document declares no time origin, so model time 0 is the window's
    // start (2016-01-01), and the anchors are model seconds from it:
    // calendar months, not a mean month of 30.436875 days.
    assert_eq!(p.time_origin(), JAN);
    assert_eq!(p.refresh_times(), vec![0.0, FEB - JAN, MAR - JAN]);
    // the primary location is missing: each month comes from its mirror,
    // converted by the declared unit_conversion
    assert_eq!(values(p, MAR - JAN - 3600.0), vec![40.0, 42.0]); // 2016-02-29T23:00Z
    assert_eq!(values(p, MAR - JAN), vec![60.0, 62.0]); // 2016-03-01
}

#[test]
fn an_unbound_sector_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut opts = options(None);
    opts.substitutions.clear();
    let e = providers_from_document_with(&doc(dir.path()), &dir.path().join("cache"), &opts)
        .err()
        .expect("unbound");
    assert!(e.to_string().contains("esm_template_unbound"), "{e}");
}

#[test]
fn the_two_record_bracket_is_the_consumers_choice() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["models"]["Emis"]["variables"]["nox"]["update"]["from"]["records_per_sample"] = json!(2);
    // A run-time entry equal to the document's value is accepted.
    let mut provs =
        providers_from_document_with(&d, &dir.path().join("cache"), &options(Some(2))).unwrap();
    let (_, p) = &mut provs[0];
    // 2016-02-15: [Feb, Mar] along the record axis, first
    assert_eq!(values(p, 1455494400.0 - JAN), vec![40.0, 42.0, 60.0, 62.0]);
}

const JAN: f64 = 1451606400.0; // 2016-01-01T00:00:00Z
const FEB: f64 = 1454284800.0; // 2016-02-01T00:00:00Z
const MAR: f64 = 1456790400.0; // 2016-03-01T00:00:00Z

fn build(doc: &Value, dir: &Path, opts: &DocumentProviderOptions) -> EsioProvider {
    let mut provs = providers_from_document_with(doc, &dir.join("cache"), opts).unwrap();
    assert_eq!(provs.len(), 1);
    provs.pop().unwrap().1
}

fn build_err(doc: &Value, dir: &Path, opts: &DocumentProviderOptions) -> String {
    providers_from_document_with(doc, &dir.join("cache"), opts)
        .err()
        .expect("refused")
        .to_string()
}

/// The `Emis.nox` binding's `from` object, to add a `select` to.
fn from_mut(d: &mut Value) -> &mut serde_json::Map<String, Value> {
    d["models"]["Emis"]["variables"]["nox"]["update"]["from"]
        .as_object_mut()
        .unwrap()
}

#[test]
fn the_time_origin_is_reference_time_first() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["domain"] = json!({"temporal": {
        "reference_time": "2016-02-01T00:00:00Z", "start": "2016-03-01T00:00:00Z"
    }});
    let mut p = build(&d, dir.path(), &options(None));
    assert_eq!(p.time_origin(), FEB);
    assert_eq!(p.refresh_times(), vec![JAN - FEB, 0.0, MAR - FEB]);
    // model time 0 reads February, not 1970
    assert_eq!(values(&mut p, 0.0), vec![40.0, 42.0]);
}

#[test]
fn an_empty_reference_time_falls_to_start() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["domain"] = json!({"temporal": {"reference_time": "", "start": "2016-03-01T00:00:00Z"}});
    let mut p = build(&d, dir.path(), &options(None));
    assert_eq!(p.time_origin(), MAR);
    assert_eq!(values(&mut p, 0.0), vec![60.0, 62.0]);
}

#[test]
fn an_unreadable_time_origin_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["domain"] = json!({"temporal": {"reference_time": "Feb 2016"}});
    let e = build_err(&d, dir.path(), &options(None));
    assert!(e.contains("time_origin_invalid"), "{e}");
    assert!(e.contains("/domain/temporal/reference_time"), "{e}");
}

#[test]
fn without_any_origin_model_time_is_unix_seconds() {
    let dir = tempfile::tempdir().unwrap();
    let mut opts = options(None);
    opts.window = None;
    let mut p = build(&doc(dir.path()), dir.path(), &opts);
    assert_eq!(p.time_origin(), 0.0);
    // unbounded by a window: the source's own declared end bounds it
    let times = p.refresh_times();
    assert_eq!(times.len(), 12);
    assert_eq!(&times[..3], &[JAN, FEB, MAR]);
    assert_eq!(values(&mut p, MAR), vec![60.0, 62.0]);
}

#[test]
fn the_default_window_is_the_documents_time_span() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["esm"] = json!("1.3.0");
    d["domain"] = json!({"temporal": {"start": "2016-01-01T00:00:00Z"}});
    // a number counts from the origin, a timestamp is an instant
    d["solver"] = json!({"time_span": {"start": FEB - JAN, "end": "2016-04-01T00:00:00Z"}});
    let mut opts = options(None);
    opts.window = None;
    let p = build(&d, dir.path(), &opts);
    assert_eq!(p.time_origin(), JAN);
    assert_eq!(p.refresh_times(), vec![FEB - JAN, MAR - JAN]);
}

#[test]
fn a_monthly_record_table_follows_time() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    // a record filter makes the source a shared record table
    d["data_sources"]["NEI"]["record_filter"] = json!({"require_finite": ["NOX"]});
    let mut p = build(&d, dir.path(), &options(None));
    // materialize primes at the window's start: January
    let jan = CadenceProvider::materialize(&mut p).unwrap();
    let jan: Vec<f64> = jan.values().next().unwrap().array.iter().copied().collect();
    assert_eq!(jan, vec![20.0, 22.0]);
    // the record has not advanced
    assert!(p.refresh(3600.0).unwrap().is_none());
    // a later t reads ITS month, through the table's filter and conversion
    assert_eq!(values(&mut p, MAR - JAN + 3600.0), vec![60.0, 62.0]);
    assert!(p.refresh(MAR - JAN + 7200.0).unwrap().is_none());
    assert_eq!(values(&mut p, FEB - JAN), vec![40.0, 42.0]);
}

#[test]
fn a_record_table_refuses_the_two_record_bracket() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    d["data_sources"]["NEI"]["record_filter"] = json!({"require_finite": ["NOX"]});
    from_mut(&mut d).insert("records_per_sample".into(), json!(2));
    let e = build_err(&d, dir.path(), &options(None));
    assert!(e.contains("two records per sample"), "{e}");
    assert!(e.contains("record table"), "{e}");
}

#[test]
fn a_fixed_select_addresses_the_record_axes_not_the_bracket() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = doc(dir.path());
    from_mut(&mut d).insert("select".into(), json!({"axes": [{"fixed": 1}]}));
    // one record: ROW 1 of March
    let mut p = build(&d, dir.path(), &options(None));
    assert_eq!(values(&mut p, MAR - JAN), vec![62.0]);
    // the bracket: ROW 1 of [Feb, Mar], the leading record axis taken whole
    from_mut(&mut d).insert("records_per_sample".into(), json!(2));
    let mut p = build(&d, dir.path(), &options(None));
    assert_eq!(values(&mut p, 1455494400.0 - JAN), vec![42.0, 62.0]);
}

#[test]
fn a_time_varying_source_selects_engine_side() {
    let dir = tempfile::tempdir().unwrap();
    let mut p = build(&doc(dir.path()), dir.path(), &options(None));
    // a reader-side select would address the file's record axis too
    assert!(!PrepareProvider::supports_selection(&p));
    // reached anyway: the record a time-less sample reads (the window's
    // start), sliced here, every requested axis kept
    let a = p
        .sample_with_selection(&[AxisSel::Indices(vec![1])])
        .unwrap();
    assert_eq!(a.shape(), &[1]);
    assert_eq!(a.iter().copied().collect::<Vec<_>>(), vec![22.0]);
}

#[test]
fn an_empty_url_override_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut opts = options(None);
    opts.url_overrides.insert("NEI".to_string(), String::new());
    let e = build_err(&doc(dir.path()), dir.path(), &opts);
    assert!(e.contains(r#"url_overrides["NEI"] is empty"#), "{e}");
}

/// `doc` with three parameters reading NEI: `pair` sets
/// `from.records_per_sample: 2` and declares the record axis `rec` (an interval
/// of size 2) first, `single` sets 1, and `inherited` sets nothing, so it takes
/// the source's `temporal.records_per_sample`.
fn two_record_doc(dir: &Path, source_rps: Option<u32>) -> Value {
    let mut d = doc(dir);
    d["index_sets"] = json!({
        "rec": {"kind": "interval", "size": 2},
        "row": {"kind": "interval", "size": 2}
    });
    if let Some(n) = source_rps {
        d["data_sources"]["NEI"]["temporal"]["records_per_sample"] = json!(n);
    }
    let param = |shape: Value, rps: Option<u32>| {
        let mut from = json!({"file_variable": "NOX"});
        if let Some(n) = rps {
            from["records_per_sample"] = json!(n);
        }
        json!({"type": "parameter", "units": "mol/s", "shape": shape,
               "update": {"kind": "data", "source": "NEI", "from": from}})
    };
    let inherited_shape = if source_rps == Some(2) {
        json!(["rec", "row"])
    } else {
        json!(["row"])
    };
    d["models"]["Emis"]["variables"] = json!({
        "pair": param(json!(["rec", "row"]), Some(2)),
        "single": param(json!(["row"]), Some(1)),
        "inherited": param(inherited_shape, None),
    });
    d
}

/// The values and the shape of the one field `p` returns at `t`.
fn field(p: &mut dyn CadenceProvider, t: f64) -> (Vec<f64>, Vec<usize>) {
    let fields = p.refresh(t).unwrap().expect("a sample");
    let f = fields.values().next().unwrap();
    (f.array.iter().copied().collect(), f.array.shape().to_vec())
}

fn by_key(provs: &[(String, earthsci_ast::esio_provider::EsioProvider)], key: &str) -> usize {
    provs.iter().position(|(k, _)| k == key).expect(key)
}

#[test]
fn a_two_record_parameter_gets_the_records_before_and_after_t() {
    let dir = tempfile::tempdir().unwrap();
    let mut provs = providers_from_document_with(
        &two_record_doc(dir.path(), None),
        &dir.path().join("cache"),
        &options(None),
    )
    .unwrap();
    // February's record (at or before t) and March's, stacked along the first
    // declared dimension.
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(
        field(&mut provs[i].1, FEB15),
        (vec![20.0, 21.0, 30.0, 31.0], vec![2, 2])
    );
    for key in ["Emis.single", "Emis.inherited"] {
        let i = by_key(&provs, key);
        assert_eq!(field(&mut provs[i].1, FEB15).0, vec![20.0, 21.0], "{key}");
    }
}

#[test]
fn the_sources_records_per_sample_is_the_default() {
    let dir = tempfile::tempdir().unwrap();
    let mut provs = providers_from_document_with(
        &two_record_doc(dir.path(), Some(2)),
        &dir.path().join("cache"),
        &options(None),
    )
    .unwrap();
    // model time 0 is the source's start, 2016-01-01
    let jan1 = 0.0;
    let i = by_key(&provs, "Emis.inherited");
    assert_eq!(
        field(&mut provs[i].1, jan1),
        (vec![10.0, 11.0, 20.0, 21.0], vec![2, 2])
    );
    // A parameter's own value overrides the source's.
    let i = by_key(&provs, "Emis.single");
    assert_eq!(field(&mut provs[i].1, jan1).0, vec![10.0, 11.0]);
}

#[test]
fn the_run_time_option_may_not_contradict_the_document() {
    let dir = tempfile::tempdir().unwrap();
    for (key, n) in [("Emis.pair", 1), ("Emis.single", 2), ("Emis.inherited", 2)] {
        let mut opts = options(None);
        opts.records_per_sample.insert(key.to_string(), n);
        let e = providers_from_document_with(
            &two_record_doc(dir.path(), None),
            &dir.path().join("cache"),
            &opts,
        )
        .err()
        .expect("a contradicting entry is refused")
        .to_string();
        assert!(e.contains(key), "{e}");
        assert!(e.contains("update.from.records_per_sample"), "{e}");
    }
    // An entry outside 1 and 2 is refused as a value.
    let mut opts = options(None);
    opts.records_per_sample.insert("Emis.pair".to_string(), 3);
    let e = providers_from_document_with(
        &two_record_doc(dir.path(), None),
        &dir.path().join("cache"),
        &opts,
    )
    .err()
    .expect("3 is refused")
    .to_string();
    assert!(e.contains("Emis.pair") && e.contains("got 3"), "{e}");
}

#[test]
fn a_run_time_entry_equal_to_the_document_is_accepted() {
    let dir = tempfile::tempdir().unwrap();
    let mut opts = options(None);
    opts.records_per_sample.insert("Emis.pair".to_string(), 2);
    opts.records_per_sample.insert("Emis.single".to_string(), 1);
    opts.records_per_sample
        .insert("Emis.inherited".to_string(), 1);
    let mut provs = providers_from_document_with(
        &two_record_doc(dir.path(), None),
        &dir.path().join("cache"),
        &opts,
    )
    .unwrap();
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(
        field(&mut provs[i].1, FEB15),
        (vec![20.0, 21.0, 30.0, 31.0], vec![2, 2])
    );
}

const FEB15: f64 = 1455494400.0 - JAN; // 2016-02-15, in model seconds

/// The error `providers_from_document_with` gives for `d`.
fn refusal(d: &Value, dir: &Path) -> String {
    providers_from_document_with(d, &dir.join("cache"), &options(None))
        .err()
        .expect("refused")
        .to_string()
}

#[test]
fn an_integral_float_is_accepted() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = two_record_doc(dir.path(), None);
    d["models"]["Emis"]["variables"]["pair"]["update"]["from"]["records_per_sample"] = json!(2.0);
    let mut provs =
        providers_from_document_with(&d, &dir.path().join("cache"), &options(None)).unwrap();
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(
        field(&mut provs[i].1, FEB15),
        (vec![20.0, 21.0, 30.0, 31.0], vec![2, 2])
    );
}

#[test]
fn a_value_other_than_one_or_two_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    // 4294967298 is 2 once truncated to 32 bits.
    for bad in [
        json!(1.5),
        json!("2"),
        json!(true),
        json!(-1),
        json!(3),
        json!(4294967298u64),
    ] {
        let mut d = two_record_doc(dir.path(), None);
        d["models"]["Emis"]["variables"]["pair"]["update"]["from"]["records_per_sample"] =
            bad.clone();
        let e = refusal(&d, dir.path());
        assert!(
            e.contains("Emis.pair") && e.contains("update.from") && e.contains(&bad.to_string()),
            "{bad}: {e}"
        );
    }
    // The source's value is held to the same rule, for the parameter that
    // inherits it.
    let mut d = two_record_doc(dir.path(), None);
    d["data_sources"]["NEI"]["temporal"]["records_per_sample"] = json!("2");
    let e = refusal(&d, dir.path());
    assert!(
        e.contains("data_sources.NEI.temporal") && e.contains("\"2\""),
        "{e}"
    );
}

#[test]
fn two_records_from_a_record_table_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = two_record_doc(dir.path(), None);
    d["data_sources"]["NEI"]["record_filter"] = json!({"require_finite": ["NOX"]});
    let e = refusal(&d, dir.path());
    assert!(e.contains("Emis.pair") && e.contains("'NEI'"), "{e}");
}

#[test]
fn two_records_from_a_source_without_a_temporal_start_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = two_record_doc(dir.path(), None);
    d["data_sources"]["NEI"]["temporal"]
        .as_object_mut()
        .unwrap()
        .remove("start");
    let e = refusal(&d, dir.path());
    assert!(e.contains("Emis.pair") && e.contains("'NEI'"), "{e}");

    // Validation reports the same document as records_per_sample_invalid.
    d["metadata"] = json!({"name": "startless"});
    d["models"]["Emis"]["equations"] = json!([]);
    let file = earthsci_ast::load_string(&d.to_string()).unwrap();
    let found: Vec<String> = earthsci_ast::validate(&file)
        .structural_errors
        .iter()
        .filter(|e| e.code.to_string() == "records_per_sample_invalid")
        .map(|e| e.path.clone())
        .collect();
    assert_eq!(
        found,
        vec!["/models/Emis/variables/pair/update".to_string()]
    );
}

#[test]
fn a_declared_select_on_a_time_varying_source_skips_the_record_axis() {
    let dir = tempfile::tempdir().unwrap();
    let mut d = two_record_doc(dir.path(), None);
    for key in ["pair", "single"] {
        d["models"]["Emis"]["variables"][key]["update"]["from"]["select"] =
            json!({"axes": [{"fixed": 1}]});
    }
    let mut provs =
        providers_from_document_with(&d, &dir.path().join("cache"), &options(None)).unwrap();
    // Row 1 of February's record and of March's, record axis first.
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(field(&mut provs[i].1, FEB15), (vec![21.0, 31.0], vec![2]));
    // Row 1 of February's record alone.
    let i = by_key(&provs, "Emis.single");
    assert_eq!(field(&mut provs[i].1, FEB15), (vec![21.0], vec![]));
}

#[test]
fn a_selection_at_t_reads_the_records_of_t() {
    let dir = tempfile::tempdir().unwrap();
    let mut provs = providers_from_document_with(
        &two_record_doc(dir.path(), None),
        &dir.path().join("cache"),
        &options(None),
    )
    .unwrap();
    let i = by_key(&provs, "Emis.pair");
    let a = provs[i]
        .1
        .sample_with_selection_at(FEB15, &[AxisSel::All, AxisSel::Indices(vec![1])])
        .unwrap();
    // February's and March's row 1; every selected axis is kept.
    assert_eq!(a.shape(), &[2, 1]);
    assert_eq!(a.iter().copied().collect::<Vec<_>>(), vec![21.0, 31.0]);
    let i = by_key(&provs, "Emis.single");
    let a = provs[i]
        .1
        .sample_with_selection_at(FEB15, &[AxisSel::Indices(vec![1])])
        .unwrap();
    assert_eq!(a.iter().copied().collect::<Vec<_>>(), vec![21.0]);
}
