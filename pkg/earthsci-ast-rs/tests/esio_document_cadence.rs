//! `providers_from_document_with` over a time-varying esm source (EarthSciIO
//! `spec/esm-sources.md`): esm URL templates, a bound custom substitution, a
//! mirror, and a calendar-month cadence. Mirrors the Python
//! `tests/test_esio_document_cadence.py` and the Julia
//! `test/esio_document_cadence_test.jl`.

#![cfg(feature = "esio")]

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use earthsci_ast::esio_provider::{DocumentProviderOptions, providers_from_document_with};
use earthsci_ast::provider::CadenceProvider;
use serde_json::{Value, json};
use time::OffsetDateTime;

/// A NetCDF-3 classic file holding one `float NOX(TSTEP=1, ROW=2)`.
fn write_month(path: &Path, values: [f32; 2]) {
    fn name(out: &mut Vec<u8>, s: &str) {
        out.extend((s.len() as u32).to_be_bytes());
        out.extend(s.as_bytes());
        while out.len() % 4 != 0 {
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
        "esm": "1.0.0",
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
    // calendar months, not a mean month of 30.436875 days
    assert_eq!(
        p.refresh_times(),
        vec![1451606400.0, 1454284800.0, 1456790400.0]
    );
    // the primary location is missing: each month comes from its mirror,
    // converted by the declared unit_conversion
    assert_eq!(values(p, 1456786800.0), vec![40.0, 42.0]); // 2016-02-29T23:00Z
    assert_eq!(values(p, 1456790400.0), vec![60.0, 62.0]); // 2016-03-01
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
    let mut provs = providers_from_document_with(
        &doc(dir.path()),
        &dir.path().join("cache"),
        &options(Some(2)),
    )
    .unwrap();
    let (_, p) = &mut provs[0];
    // 2016-02-15: [Feb, Mar] along the record axis, first
    assert_eq!(values(p, 1455494400.0), vec![40.0, 42.0, 60.0, 62.0]);
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
    let feb15 = 1455494400.0;
    // February's record (at or before t) and March's, stacked along the first
    // declared dimension.
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(
        field(&mut provs[i].1, feb15),
        (vec![20.0, 21.0, 30.0, 31.0], vec![2, 2])
    );
    for key in ["Emis.single", "Emis.inherited"] {
        let i = by_key(&provs, key);
        assert_eq!(field(&mut provs[i].1, feb15).0, vec![20.0, 21.0], "{key}");
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
    let jan1 = 1451606400.0;
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
fn the_run_time_option_overrides_the_document() {
    let dir = tempfile::tempdir().unwrap();
    let mut opts = options(None);
    opts.records_per_sample.insert("Emis.pair".to_string(), 1);
    let mut provs = providers_from_document_with(
        &two_record_doc(dir.path(), None),
        &dir.path().join("cache"),
        &opts,
    )
    .unwrap();
    let i = by_key(&provs, "Emis.pair");
    assert_eq!(field(&mut provs[i].1, 1455494400.0).0, vec![20.0, 21.0]);
}
