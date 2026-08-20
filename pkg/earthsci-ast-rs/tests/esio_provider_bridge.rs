//! The opt-in EarthSciIO bridge (`--features esio`) really serves an ESS
//! `CadenceProvider` from a real `earthsciio::Provider`.
//!
//! Everything here runs against a local Zarr **v2** store over the `file`
//! transport — no network, no fixture corpus. Two properties matter and are
//! asserted end to end:
//!
//!   1. **Renaming.** The adapter keys its output by the MODEL variable, not the
//!      on-disk name, so an `.esm` referring to `SR_SOA` resolves an array stored
//!      as `SOA`.
//!   2. **Projection pushdown.** A `Selection` reaches the store-backed reader,
//!      so only the selected indices come back. This is the property the ISRM
//!      gated fetch depends on: 1,520 of 52,411 SR rows, chosen after value
//!      invention has run.

#![cfg(feature = "esio")]

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use earthsci_ast::esio_provider::EsioProvider;
use earthsci_ast::provider::CadenceProvider;
use earthsciio::format::{AxisSelect, Selection};
use earthsciio::{Cache, DataSource};

/// Write an UNCOMPRESSED Zarr v2 array: `.zarray` + `.zattrs` + raw
/// little-endian f64 chunks. Uncompressed keeps the fixture dependency-free —
/// the codec path is EarthSciIO's own concern and is covered by its suite.
fn write_v2_array(root: &Path, name: &str, shape: [usize; 2], chunks: [usize; 2], data: &[f64]) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).expect("create array dir");
    fs::write(
        dir.join(".zarray"),
        format!(
            r#"{{"zarr_format":2,"shape":[{},{}],"chunks":[{},{}],"dtype":"<f8",
                "compressor":null,"fill_value":0.0,"order":"C","filters":null}}"#,
            shape[0], shape[1], chunks[0], chunks[1]
        ),
    )
    .expect("write .zarray");
    fs::write(dir.join(".zattrs"), r#"{"_ARRAY_DIMENSIONS":["src","rcv"]}"#)
        .expect("write .zattrs");

    let (nc0, nc1) = (shape[0].div_ceil(chunks[0]), shape[1].div_ceil(chunks[1]));
    for c0 in 0..nc0 {
        for c1 in 0..nc1 {
            let mut buf = Vec::with_capacity(chunks[0] * chunks[1] * 8);
            for i in 0..chunks[0] {
                for j in 0..chunks[1] {
                    let (r, c) = (c0 * chunks[0] + i, c1 * chunks[1] + j);
                    // Edge chunks are full-size on disk, zero-padded past the shape.
                    let v = if r < shape[0] && c < shape[1] {
                        data[r * shape[1] + c]
                    } else {
                        0.0
                    };
                    buf.extend_from_slice(&v.to_le_bytes());
                }
            }
            fs::write(dir.join(format!("{c0}.{c1}")), &buf).expect("write chunk");
        }
    }
}

/// A 3x4 "SR" array: value = row*10 + col.
fn fixture(tmp: &Path) -> String {
    let store = tmp.join("mini.zarr");
    let data: Vec<f64> = (0..3)
        .flat_map(|r| (0..4).map(move |c| (r * 10 + c) as f64))
        .collect();
    write_v2_array(&store, "SOA", [3, 4], [1, 4], &data);
    format!("file://{}", store.display())
}

fn cache(tmp: &Path) -> Arc<Cache> {
    Arc::new(
        Cache::builder()
            .data_dir(tmp.join("cache"))
            .offline(false)
            .build()
            .expect("cache builds"),
    )
}

#[test]
fn materialize_renames_to_the_model_variable() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);

    let mut p = EsioProvider::builder(loader, cache(tmp.path()))
        .var("SOA", "SR_SOA")
        .build()
        .expect("provider builds");

    let fields = p.materialize().expect("materialize");

    assert!(
        fields.contains_key("SR_SOA"),
        "adapter must key by the MODEL variable; got {:?}",
        fields.keys().collect::<Vec<_>>()
    );
    assert!(!fields.contains_key("SOA"), "the on-disk name must not leak through");
    let f = &fields["SR_SOA"];
    assert_eq!(f.array.shape(), &[3, 4]);
    assert_eq!(f.array[ndarray::IxDyn(&[0, 0])], 0.0);
    assert_eq!(f.array[ndarray::IxDyn(&[2, 3])], 23.0);
}

#[test]
fn an_undeclared_variable_keeps_its_on_disk_name() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);

    // No `.var(...)` mapping — the common case where the loader already names
    // variables the way the model refers to them.
    let mut p = EsioProvider::builder(loader, cache(tmp.path()))
        .build()
        .expect("provider builds");

    let fields = p.materialize().expect("materialize");
    assert!(fields.contains_key("SOA"));
}

#[test]
fn a_selection_is_pushed_down_to_the_reader() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);

    let mut p = EsioProvider::builder(loader, cache(tmp.path()))
        .var("SOA", "SR_SOA")
        .select(Selection::Orthogonal(vec![
            AxisSelect::Indices(vec![0, 2]), // rows 0 and 2 — the "gated" rows
            AxisSelect::All,
        ]))
        .build()
        .expect("provider builds");

    assert!(
        p.supports_selection(),
        "a store-backed zarr reader must report that it can honour a pushdown"
    );

    let fields = p.materialize().expect("materialize");
    let f = &fields["SR_SOA"];
    assert_eq!(
        f.array.shape(),
        &[2, 4],
        "the selection must shrink the result, not be applied after a whole read"
    );
    // Row 0 -> 0..3, row 2 -> 20..23. Row 1 must be absent entirely.
    assert_eq!(f.array[ndarray::IxDyn(&[0, 0])], 0.0);
    assert_eq!(f.array[ndarray::IxDyn(&[1, 0])], 20.0);
    assert_eq!(f.array[ndarray::IxDyn(&[1, 3])], 23.0);
}

#[test]
fn a_const_loader_schedules_no_refreshes() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);
    let p = EsioProvider::builder(loader, cache(tmp.path()))
        .build()
        .expect("provider builds");

    // No `temporal` block => CONST => contributes no driver tstop.
    assert!(CadenceProvider::refresh_times(&p).is_empty());
}

#[test]
fn array_shape_reads_metadata_without_a_chunk() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);
    let p = EsioProvider::builder(loader, cache(tmp.path()))
        .build()
        .expect("provider builds");

    // This is how a gated caller decides a pushdown is worth building at all.
    assert_eq!(p.array_shape("SOA").expect("array_shape"), Some(vec![3, 4]));
}

#[test]
fn an_unknown_format_fails_at_construction_not_mid_solve() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let loader = DataSource::new("bogus", "not-a-format", "file:///nowhere");
    let built = EsioProvider::builder(loader, cache(tmp.path())).build();
    assert!(built.is_err(), "an unresolvable reader must fail at build()");
}

/// A HashMap of model-variable -> array is exactly what the refresh executor
/// consumes, so the adapter is usable through the trait object the executor holds.
#[test]
fn usable_as_a_boxed_cadence_provider() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let base = fixture(tmp.path());
    let loader = DataSource::new("ISRM_SR", "zarr", base).variables(["SOA"]);
    let p = EsioProvider::builder(loader, cache(tmp.path()))
        .var("SOA", "SR_SOA")
        .build()
        .expect("provider builds");

    let mut boxed: Box<dyn CadenceProvider> = Box::new(p);
    let fields: HashMap<_, _> = boxed.materialize().expect("materialize");
    assert_eq!(fields["SR_SOA"].array.len(), 12);
}
