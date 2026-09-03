//! `esm test` must INGEST a document's `data_sources`, or say why it cannot.
//!
//! The defect this file pins is not a wrong number — it is a *plausible* one.
//! A document that declares `data_sources` and binds a parameter to a column of
//! one gets its numbers from disk. The build-time provider contract
//! (`earthsci_ast::PrepareProvider`) is supplied by the CALLER, and the `esm`
//! binary supplied none: every subcommand that prepared a document therefore
//! evaluated each data-fed parameter at its `default` and printed the result as
//! the document's answer. No error, no warning, no diagnostic — a run that
//! reported `actual=0` for a column whose sum is six figures, and a test suite
//! that went green on it.
//!
//! So the assertions here are deliberately of that shape:
//!
//!   * a REAL file on disk, decoded by a real reader, with a column whose mean
//!     is a known non-zero number the document asserts inline. A binary that
//!     cannot ingest reports the `default` and FAILS this, which is the only
//!     way to catch a bug whose signature is passing-by-returning-a-default;
//!   * the no-reader build must produce that DIAGNOSTIC — naming the source and
//!     the missing feature — and a non-zero exit. Silence is the defect;
//!   * an unrecognised `reader_options` key must be an ERROR (esm-spec §8.9.1),
//!     surfaced through the CLI rather than decoded as something else;
//!   * and the row count comes from the DATA. A fixture must not hardcode its
//!     own extent — the next snapshot has a different number of rows — so
//!     esm-spec §8.9.4 lets a source measure itself and bind a metaparameter an
//!     index set is sized by. That only works if the source is sampled BEFORE
//!     the document's metaparameters are closed (§9.7.6 site 4); a runner that
//!     loads first freezes every such index set at the declaration's
//!     placeholder default, and a zero-length shape is a panic on one path and
//!     a sum over no rows — a plausible, silent 0 — on the other.
//!
//! Gated on the features the `esm` target itself requires: with `cli` or
//! `solve` off cargo skips the binary and `CARGO_BIN_EXE_esm` does not exist.

#![cfg(all(not(target_arch = "wasm32"), feature = "cli", feature = "solve"))]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Value, json};

/// The FF10 point schema's 77 columns, by the indices this fixture writes.
const C_POLID: usize = 12;
const C_ANN: usize = 13;
const C_LON: usize = 23;
const C_LAT: usize = 24;
const N_COL: usize = 77;

/// The three annual totals the document reads back. Their mean is the number
/// the inline test asserts, and it is not reachable from any `default`.
const ANN: [f64; 3] = [100.0, 50.0, 30.0];
const ANN_MEAN: f64 = 60.0;
/// The SUM of the same column — the value a 0-D observed over it must report,
/// and unreachable from any `default`.
const ANN_TOTAL: f64 = 180.0;

fn ff10_row(ann: f64, lon: f64, lat: f64) -> String {
    let mut r = vec![String::new(); N_COL];
    r[0] = "US".into();
    r[1] = "01001".into();
    r[C_POLID] = "NOX".into();
    r[C_ANN] = format!("{ann:.1}");
    r[C_LON] = format!("{lon:.1}");
    r[C_LAT] = format!("{lat:.1}");
    r.join(",")
}

/// An EPA-2016fd-shaped zip: a `#FORMAT` line + a header row per member, one
/// `*egu*` member the document's `member_glob` selects and one it excludes —
/// so a run that ignored `reader_options` would read four rows, not three, and
/// report a different mean.
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
            ANN.iter()
                .enumerate()
                .map(|(i, a)| ff10_row(*a, -90.0 - i as f64, 40.0 + i as f64))
                .collect::<Vec<_>>(),
        ),
        (
            "point/ptnonipm.csv",
            vec![ff10_row(999.0, -94.0, 45.0)],
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

/// One data source over the zip, one parameter bound to its `ANN_VALUE`
/// column, one observed over that parameter, and one §6.6 inline test whose
/// expected value is the column mean.
///
/// The model declares NO differential equation on purpose: a data document's
/// whole content is its build-time observed graph, and that is exactly the
/// shape the CLI could not run.
/// How the record index set gets its length.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Sizing {
    /// `size: 3` — the count written into the document by hand.
    Literal,
    /// `size: "N_REC"`, bound by the source's own `extent` (esm-spec §8.9.4):
    /// nothing in the document knows the row count, and nothing should.
    Extent,
}

fn document(url: &str, extra_reader_options: Option<(&str, Value)>, sizing: Sizing) -> Value {
    let mut reader_options = json!({"member_glob": "*egu*", "skip_header_row": true});
    if let Some((k, v)) = extra_reader_options {
        reader_options[k] = v;
    }
    json!({
        "esm": "1.0.0",
        "metadata": {
            "name": "DataSourceIngestCli",
            "description": "One data source, one bound parameter, one inline test on its column mean."
        },
        "metaparameters": {
            "N_REC": {
                // Under `Sizing::Extent` this default is a PLACEHOLDER the
                // source overrides, and it is 0 on purpose: a default that
                // happened to be right would hide the very defect under test.
                "type": "integer",
                "default": if sizing == Sizing::Extent { 0 } else { ANN.len() },
                "description": "Records in the selected members."
            }
        },
        "index_sets": {"records": {"kind": "interval", "size": "N_REC"}},
        "data_sources": {
            "EGU_Emis": merge_extent(json!({
                "kind": "points",
                "source": {"url_template": url},
                "reader_options": reader_options,
                "metadata": {"esio_format": "ff10"}
            }), sizing)
        },
        "models": {
            "Ingest": {
                "system_kind": "nonlinear",
                "variables": {
                    "annual": {
                        "type": "parameter",
                        "units": "kg/yr",
                        "default": 0.0,
                        "shape": ["records"],
                        "description": "Per-record annual emissions, read from the source.",
                        "update": {
                            "kind": "data",
                            "source": "EGU_Emis",
                            "from": {"file_variable": "ANN_VALUE"}
                        }
                    },
                    "annual_obs": {
                        "type": "unknown",
                        "units": "kg/yr",
                        "shape": ["records"],
                        "description": "Identity over the ingested column, so the assertion's `mean` IS the column mean."
                    }
                },
                "equations": [{
                    "lhs": "annual_obs",
                    "rhs": {
                        "op": "aggregate",
                        "output_idx": ["r"],
                        "ranges": {"r": {"from": "records"}},
                        "args": ["annual"],
                        "expr": {"op": "index", "args": ["annual", "r"]}
                    }
                }],
                "tests": [{
                    "id": "column_mean_from_disk",
                    "description": "mean(ANN_VALUE) over the members the glob selects.",
                    "time_span": {"start": 0.0, "end": 0.0},
                    "assertions": [{
                        "variable": "annual_obs",
                        "time": 0.0,
                        "reduce": "mean",
                        "expected": ANN_MEAN,
                        "tolerance": {"rel": 1e-12}
                    }]
                }]
            }
        }
    })
}

/// The same document plus a SCALAR observed over the ingested column — the
/// total of the very rows `annual_obs` reduces — and a second inline test
/// asserting it POINTWISE (neither `coords` nor `reduce`, esm-spec §6.6.3).
///
/// This is finding F16. Bind a column to a `data_sources` entry and the
/// document has nothing to integrate, so its answers are the build's
/// materialized fields rather than a trajectory: the array read correctly and
/// every scalar derived from it reported `scalar state 'annual_total' not
/// found`, while the identical document with the column as a `const` array
/// passed — the array runtime exposes 0-D observeds as trajectory rows and the
/// build-static path had no route to them at all. The `mean` assertion on the
/// array is carried alongside as the control: both halves of one document must
/// answer.
fn document_with_scalar_total(url: &str, sizing: Sizing, expected_total: f64) -> Value {
    let mut doc = document(url, None, sizing);
    doc["models"]["Ingest"]["variables"]["annual_total"] = json!({
        "type": "unknown",
        "units": "kg/yr",
        "description": "Sum of the ingested column. A 0-D observed over ingested rows."
    });
    doc["models"]["Ingest"]["equations"]
        .as_array_mut()
        .expect("equations")
        .push(json!({
            "lhs": "annual_total",
            "rhs": {
                "op": "aggregate",
                "output_idx": [],
                "ranges": {"r": {"from": "records"}},
                "args": ["annual"],
                "expr": {"op": "index", "args": ["annual", "r"]}
            }
        }));
    doc["models"]["Ingest"]["tests"]
        .as_array_mut()
        .expect("tests")
        .push(json!({
            "id": "column_total_from_disk",
            "description": "sum(ANN_VALUE) as a POINTWISE scalar assertion.",
            "time_span": {"start": 0.0, "end": 0.0},
            "assertions": [{
                "variable": "annual_total",
                "time": 0.0,
                "expected": expected_total,
                "tolerance": {"rel": 1e-12}
            }]
        }));
    doc
}

/// Write the scalar-total fixture into `dir`, returning the .esm path.
fn fixture_with_scalar_total(dir: &Path, sizing: Sizing, expected_total: f64) -> PathBuf {
    let url = write_ff10_zip(dir);
    let doc = document_with_scalar_total(&url, sizing, expected_total);
    let path = dir.join("ingest_scalar.esm");
    fs::write(&path, serde_json::to_string_pretty(&doc).expect("doc renders"))
        .expect("write document");
    path
}

/// Attach the `extent` declaration under [`Sizing::Extent`].
fn merge_extent(mut source: Value, sizing: Sizing) -> Value {
    if sizing == Sizing::Extent {
        source["extent"] = json!({"metaparameter": "N_REC"});
    }
    source
}

/// Write the fixture zip and the document into `dir`, returning the .esm path.
fn fixture(
    dir: &Path,
    extra_reader_options: Option<(&str, Value)>,
    sizing: Sizing,
) -> std::path::PathBuf {
    let url = write_ff10_zip(dir);
    let doc = document(&url, extra_reader_options, sizing);
    let path = dir.join("ingest.esm");
    fs::write(&path, serde_json::to_string_pretty(&doc).expect("doc renders"))
        .expect("write document");
    path
}

/// Run `esm <args>` with its data cache confined to `cache`, so concurrent
/// tests never share one.
fn esm(cache: &Path, args: &[&str]) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_esm"))
        .env("ESM_CACHE_DIR", cache)
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.success(), text)
}

/// The `pass | fail | err` triple from the summary's `TOTAL` row.
fn total_row(stdout: &str) -> (usize, usize, usize) {
    let line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with("TOTAL"))
        .unwrap_or_else(|| panic!("no TOTAL row in:\n{stdout}"));
    let counts: Vec<usize> = line
        .split_whitespace()
        .skip(1)
        .map(|tok| tok.parse().expect("numeric count"))
        .collect();
    assert_eq!(counts.len(), 3, "TOTAL row {line:?} is not pass/fail/err");
    (counts[0], counts[1], counts[2])
}

// --------------------------------------------------------------------------- //
// With a reader linked (`--features esio`)
// --------------------------------------------------------------------------- //

/// THE regression: the number the document asserts is on disk, and only a run
/// that actually read it can pass. Before the CLI bound a provider this reported
/// the parameter's `default` and failed — silently, as a plain wrong value.
#[cfg(feature = "esio")]
#[test]
fn esm_test_reads_the_declared_data_source() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture(tmp.path(), None, Sizing::Literal);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(
        ok,
        "a document whose data source is readable must pass; got:\n{out}"
    );
    assert_eq!(total_row(&out), (1, 0, 0), "in:\n{out}");
}

/// FINDING F16: a scalar derived from an ingested column is assertable, and
/// the array beside it still is. Both assertions of the one document pass, and
/// the scalar's value is the column SUM — a number no `default` can reach.
#[cfg(feature = "esio")]
#[test]
fn a_scalar_derived_from_an_ingested_column_is_assertable() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture_with_scalar_total(tmp.path(), Sizing::Literal, ANN_TOTAL);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(
        ok,
        "the array reduction AND the scalar total must both answer; got:\n{out}"
    );
    assert_eq!(total_row(&out), (2, 0, 0), "in:\n{out}");
}

/// The same document with the scalar's expectation moved off the true total
/// must FAIL — not error, and certainly not pass. Without this the test above
/// would be satisfied by a runner that reported any number at all.
#[cfg(feature = "esio")]
#[test]
fn an_ingested_scalar_assertion_is_judged_against_its_expectation() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture_with_scalar_total(tmp.path(), Sizing::Literal, ANN_TOTAL + 1.0);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(!ok, "a wrong expectation must not exit 0; got:\n{out}");
    assert_eq!(total_row(&out), (1, 1, 0), "in:\n{out}");
    assert!(
        out.contains(&format!("actual={ANN_TOTAL}")),
        "the FAIL must name the value read from disk:\n{out}"
    );
}

/// And with the row count discovered from the data (esm-spec §8.9.4) rather
/// than written into the document: the scalar contracts over the axis the
/// source's own `extent` sized.
#[cfg(feature = "esio")]
#[test]
fn an_ingested_scalar_contracts_over_the_discovered_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture_with_scalar_total(tmp.path(), Sizing::Extent, ANN_TOTAL);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(ok, "an extent-sized scalar must answer; got:\n{out}");
    assert_eq!(total_row(&out), (2, 0, 0), "in:\n{out}");
}

/// esm-spec §8.9.1: an unrecognised `reader_options` key MUST be an error, not
/// ignored — a mis-spelled option must never silently decode something else.
#[cfg(feature = "esio")]
#[test]
fn an_unrecognised_reader_option_is_an_error_naming_the_source() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture(tmp.path(), Some(("skip_headr_row", json!(true))), Sizing::Literal);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(!ok, "an unknown reader option must not exit 0; got:\n{out}");
    assert_eq!(total_row(&out), (0, 0, 1), "in:\n{out}");
    assert!(
        out.contains("EGU_Emis"),
        "the diagnostic must name the source:\n{out}"
    );
    assert!(
        out.contains("skip_headr_row"),
        "the diagnostic must name the offending key:\n{out}"
    );
}

/// A source whose bytes are not there is an ERROR that names it — never a run
/// that quietly falls back to the parameter's `default`.
#[cfg(feature = "esio")]
#[test]
fn a_missing_source_file_is_an_error_naming_the_source() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc_path = fixture(tmp.path(), None, Sizing::Literal);
    fs::remove_file(tmp.path().join("2016fd_inputs_point.zip")).expect("remove the fixture");
    let (ok, out) = esm(tmp.path(), &["test", doc_path.to_str().expect("utf-8 path")]);
    assert!(!ok, "a missing source file must not exit 0; got:\n{out}");
    assert_eq!(total_row(&out), (0, 0, 1), "in:\n{out}");
    assert!(
        out.contains("EGU_Emis") || out.contains("Ingest.annual"),
        "the diagnostic must name the source or its consumer:\n{out}"
    );
}


/// The row count comes from the DATA (esm-spec §8.9.4), not from the document.
///
/// The index set is sized by a metaparameter whose only declared value is the
/// placeholder 0, and the source's `extent` binds it. A runner that closes
/// metaparameters before it samples gets a 3-record table sized 0, and the
/// assertion then reduces an empty field or sums no rows. The expected value is
/// the same as the literal-sized case on purpose: the only thing that differs
/// is who decides the length.
#[cfg(feature = "esio")]
#[test]
fn esm_test_reads_a_source_that_measures_its_own_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture(tmp.path(), None, Sizing::Extent);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(
        ok,
        "an index set sized by the source's own extent must still assert the real \
         column mean; got:\n{out}"
    );
    assert_eq!(total_row(&out), (1, 0, 0), "in:\n{out}");
}

/// ...and the emit path agrees: one row per discovered record, carrying the
/// values that were on disk. This is the shape a row-by-row comparator reads,
/// and it is the path that PANICKED on a zero-length shape rather than
/// returning a wrong number, so it needs its own case.
#[cfg(feature = "esio")]
#[test]
fn csv_emit_sizes_its_rows_by_the_discovered_extent() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture(tmp.path(), None, Sizing::Extent);
    let out_csv = tmp.path().join("rows.csv");
    let (ok, out) = esm(
        tmp.path(),
        &[
            "simulate",
            doc.to_str().expect("utf-8 path"),
            "--time",
            "0",
            "--format",
            "csv",
            "--observed",
            "annual_obs",
            "--output",
            out_csv.to_str().expect("utf-8 path"),
        ],
    );
    assert!(ok, "csv emit over a discovered extent must succeed:\n{out}");
    assert_eq!(
        fs::read_to_string(&out_csv).expect("read csv"),
        "i1,annual_obs\n1,100\n2,50\n3,30\n",
        "one row per record the source measured, carrying what was on disk"
    );
}

// --------------------------------------------------------------------------- //
// With no reader linked (the default build)
// --------------------------------------------------------------------------- //

/// The other half of the defect: a binary that CANNOT ingest must say so.
/// Reporting the `default` and exiting 0 is what cost a day, so the no-reader
/// build fails loudly and names both the source and the missing feature.
#[cfg(not(feature = "esio"))]
#[test]
fn a_build_without_the_reader_refuses_and_names_the_source() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let doc = fixture(tmp.path(), None, Sizing::Literal);
    let (ok, out) = esm(tmp.path(), &["test", doc.to_str().expect("utf-8 path")]);
    assert!(
        !ok,
        "a binary that cannot read the document's data must not exit 0; got:\n{out}"
    );
    assert_eq!(total_row(&out), (0, 0, 1), "in:\n{out}");
    assert!(out.contains("EGU_Emis"), "must name the source:\n{out}");
    assert!(out.contains("esio"), "must name the missing feature:\n{out}");
    assert!(
        out.contains("Ingest.annual"),
        "must name the parameter that reads it:\n{out}"
    );
}

/// ...and a document that declares no data source is untouched by any of this:
/// the ingest path must cost nothing, and change nothing, for the documents
/// that do not use it.
#[test]
fn a_document_with_no_data_source_is_unaffected() {
    let (ok, out) = esm(
        Path::new("."),
        &[
            "test",
            &format!(
                "{}/tests/fixtures/inline_tests/passing_decay.esm",
                env!("CARGO_MANIFEST_DIR")
            ),
        ],
    );
    assert!(ok, "the no-data-source fixture must still pass:\n{out}");
    assert_eq!(total_row(&out), (3, 0, 0), "in:\n{out}");
}
