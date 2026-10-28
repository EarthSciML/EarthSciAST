//! esm-spec §2.2.7 `solver.time_span`, against the SHARED pin.
//!
//! Reads `tests/conformance/solver_time_span/manifest.json` and asserts this
//! binding against it (CONFORMANCE_SPEC §5.49): for an accepted fixture, the
//! value [`earthsci_ast::resolve_time_span`] returns with no call-site interval
//! (binary64 equality — every pinned value is exact) and the root's `solver`
//! block as `emit` writes it (numbers compared by value); for a refused one,
//! the diagnostic code and the substrings its message must carry.

use serde_json::Value;
use std::path::{Path, PathBuf};

fn suite_dir() -> PathBuf {
    // <repo>/pkg/earthsci-ast-rs/tests/this_file.rs
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the crate sits two levels under the repository root")
        .join("tests/conformance/solver_time_span")
}

fn manifest() -> Value {
    let p = suite_dir().join("manifest.json");
    serde_json::from_str(
        &std::fs::read_to_string(&p)
            .unwrap_or_else(|e| panic!("the shared pin {} must be readable: {e}", p.display())),
    )
    .expect("manifest.json is JSON")
}

fn fixtures(m: &Value, expect: &str) -> Vec<Value> {
    m["fixtures"]
        .as_array()
        .expect("fixtures array")
        .iter()
        .filter(|f| f["expect"] == expect)
        .cloned()
        .collect()
}

fn load(f: &Value) -> Result<earthsci_ast::EsmFile, earthsci_ast::EsmError> {
    earthsci_ast::load_path(suite_dir().join(f["path"].as_str().expect("path")))
}

/// JSON equality with every number compared by its binary64 value, so an
/// authored `3600` and an emitted `3600.0` agree.
fn same_by_value(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same_by_value(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| same_by_value(v, w)))
        }
        _ => a == b,
    }
}

fn pair(v: &Value) -> Option<(f64, f64)> {
    let a = v.as_array()?;
    assert_eq!(a.len(), 2, "an interval pin is [start, end]");
    Some((
        a[0].as_f64().expect("number"),
        a[1].as_f64().expect("number"),
    ))
}

#[test]
fn every_accepted_fixture_converts_and_emits_as_the_shared_manifest_says() {
    let m = manifest();
    let accepted = fixtures(&m, "accepted");
    assert!(!accepted.is_empty(), "the manifest pins accepted fixtures");
    for f in accepted {
        let id = f["id"].as_str().expect("id");
        let doc = load(&f).unwrap_or_else(|e| panic!("{id} must load: {e}"));

        let seconds = earthsci_ast::resolve_time_span(&doc, None)
            .unwrap_or_else(|e| panic!("{id}: the accessor must resolve: {e}"));
        let want = pair(&f["seconds"]);
        // Exact binary64 equality, bit for bit (so -0.0 vs 0.0 is not hidden
        // by `==`… but the pins carry no signed zero, so `==` on the pair is
        // the manifest's rule).
        assert_eq!(seconds, want, "{id}: resolve_time_span(file)");

        let emitted: Value =
            serde_json::from_str(&earthsci_ast::to_json(&doc).expect("emits")).expect("JSON");
        let solver = emitted.get("solver").cloned().unwrap_or(Value::Null);
        assert!(
            same_by_value(&solver, &f["solver"]),
            "{id}: the emitted solver block {solver} must equal {}",
            f["solver"]
        );
    }
}

#[test]
fn every_refused_fixture_fails_with_the_pinned_code_and_message() {
    let m = manifest();
    let refused = fixtures(&m, "refused");
    assert!(!refused.is_empty(), "the manifest pins refused fixtures");
    for f in refused {
        let id = f["id"].as_str().expect("id");
        let msg = load(&f)
            .err()
            .unwrap_or_else(|| panic!("{id} must be REFUSED at load, not accepted"))
            .to_string();
        let code = f["error_code"].as_str().expect("error_code");
        assert!(
            earthsci_ast::ERROR_CODES.iter().any(|(_, v)| *v == code),
            "{id}: {code} must be a code this binding registers"
        );
        assert!(
            msg.contains(&format!("[{code}]")),
            "{id}: the diagnostic must carry [{code}]; got: {msg}"
        );
        for needle in f["message_contains"].as_array().expect("message_contains") {
            let needle = needle.as_str().expect("string");
            assert!(
                msg.contains(needle),
                "{id}: the diagnostic must name {needle:?}; got: {msg}"
            );
        }
    }
}

#[test]
fn an_explicit_call_site_interval_wins_both_bounds() {
    let m = manifest();
    let cases = m["call_site"]["cases"].as_array().expect("call_site.cases");
    assert!(!cases.is_empty(), "the manifest pins call-site cases");
    for c in cases {
        let id = c["fixture"].as_str().expect("fixture");
        let f = m["fixtures"]
            .as_array()
            .expect("fixtures")
            .iter()
            .find(|f| f["id"] == id)
            .unwrap_or_else(|| panic!("call-site fixture {id} is pinned"));
        let doc = load(f).unwrap_or_else(|e| panic!("{id} must load: {e}"));
        let got = earthsci_ast::resolve_time_span(&doc, pair(&c["call_site"]))
            .unwrap_or_else(|e| panic!("{id}: resolves: {e}"));
        assert_eq!(
            got,
            pair(&c["resolved"]),
            "{id}: call site {}",
            c["call_site"]
        );
    }
}

#[test]
fn the_version_gate_refuses_time_span_below_1_3_0_before_the_schema() {
    let doc = |esm: &str, solver: Value| serde_json::json!({ "esm": esm, "solver": solver });
    let span = serde_json::json!({ "time_span": {"start": 0, "end": 1} });
    for esm in ["1.1.0", "1.2.0"] {
        let e = earthsci_ast::reject_solver_time_span_pre_v13(&doc(esm, span.clone()))
            .expect_err("time_span below 1.3.0 is refused");
        assert_eq!(e.code, "solver_time_span_version_too_old");
        assert!(e.message.contains("/solver/time_span"), "{}", e.message);
        earthsci_ast::reject_solver_time_span_pre_v13(&doc(
            esm,
            serde_json::json!({"reltol": 1e-6}),
        ))
        .unwrap_or_else(|e| panic!("a block without time_span stays valid at {esm}: {e}"));
    }
    earthsci_ast::reject_solver_time_span_pre_v13(&doc("1.3.0", span))
        .expect("1.3.0 admits time_span");

    // A schema-invalid bound beside the gate: the gate still answers first.
    let text = serde_json::json!({
        "esm": "1.2.0",
        "metadata": {"name": "t"},
        "solver": {"time_span": {"start": "yesterday", "end": 1}},
        "models": {"M": {"variables": {}, "equations": []}}
    })
    .to_string();
    let msg = earthsci_ast::load_string(&text)
        .expect_err("refused")
        .to_string();
    assert!(msg.contains("[solver_time_span_version_too_old]"), "{msg}");
}

fn decay_doc(solver: Value, temporal: Option<Value>) -> String {
    let mut d = serde_json::json!({
        "esm": "1.3.0",
        "metadata": {"name": "t"},
        "solver": solver,
        "models": {"M": {
            "variables": {"A": {"type": "unknown", "units": "1", "default": 1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["A"], "wrt": "t"}, "rhs": 0}]
        }}
    });
    if let Some(t) = temporal {
        d["domain"] = serde_json::json!({ "temporal": t });
    }
    d.to_string()
}

#[test]
fn the_invalid_check_skips_a_bound_the_schema_will_report() {
    // An offset on a BOUND is not the schema's timestamp form: the schema
    // reports it, the load-time check does not report it again.
    let text = decay_doc(
        serde_json::json!({"time_span": {"start": "2019-07-01T02:00:00+02:00", "end": 0}}),
        None,
    );
    let msg = earthsci_ast::load_string(&text)
        .expect_err("schema-invalid")
        .to_string();
    assert!(!msg.contains("solver_time_span_invalid"), "{msg}");
}

#[test]
fn an_origin_start_that_names_no_day_is_refused_with_its_pointer() {
    let text = decay_doc(
        serde_json::json!({"time_span": {"start": "2019-07-01T00:00:00Z", "end": "2019-07-02T00:00:00Z"}}),
        Some(serde_json::json!({"start": "2019-02-29T00:00:00Z"})),
    );
    let msg = earthsci_ast::load_string(&text)
        .expect_err("refused")
        .to_string();
    assert!(
        msg.contains("[solver_time_span_invalid]")
            && msg.contains("/solver/time_span")
            && msg.contains("/domain/temporal/start"),
        "{msg}"
    );

    // A PRESENT origin key selects its field whatever its value: a null, a
    // `:60` second or an out-of-range offset is unreadable, and the origin
    // never falls back to the next field.
    for (temporal, pointer) in [
        (
            serde_json::json!({"reference_time": null, "start": "2019-07-01T00:00:00Z"}),
            "/domain/temporal/reference_time",
        ),
        (serde_json::json!({"start": null}), "/domain/temporal/start"),
        (
            serde_json::json!({"reference_time": "2019-06-30T23:59:60Z"}),
            "/domain/temporal/reference_time",
        ),
        (
            serde_json::json!({"reference_time": "2019-07-01T00:00:00+24:00"}),
            "/domain/temporal/reference_time",
        ),
        (
            serde_json::json!({"reference_time": "2019-07-01T00:00:00+01:60"}),
            "/domain/temporal/reference_time",
        ),
    ] {
        let text = decay_doc(
            serde_json::json!({"time_span": {"start": "2019-07-01T00:00:00Z", "end": "2019-07-02T00:00:00Z"}}),
            Some(temporal.clone()),
        );
        let msg = earthsci_ast::load_string(&text)
            .expect_err("an unreadable origin is refused")
            .to_string();
        assert!(
            msg.contains("[solver_time_span_invalid]")
                && msg.contains("/solver/time_span")
                && msg.contains(pointer),
            "{temporal}: {msg}"
        );
    }

    // Numbers never read the origin, however unreadable it is. (Built in
    // memory: a load would have the schema's `date-time` format refuse the
    // origin itself.)
    let text = decay_doc(
        serde_json::json!({"time_span": {"start": 0, "end": 1}}),
        Some(serde_json::json!({"start": null})),
    );
    let doc: earthsci_ast::EsmFile = serde_json::from_str(&text).expect("typed document");
    assert_eq!(
        earthsci_ast::resolve_time_span(&doc, None).expect("numbers need no origin"),
        Some((0.0, 1.0))
    );
}

#[test]
fn a_document_built_in_memory_converts_and_is_checked_by_the_accessor() {
    use earthsci_ast::{EsmFile, Solver, SolverTimeSpan, TimePoint};
    let with = |start: TimePoint, end: TimePoint| EsmFile {
        solver: Some(Solver {
            stiffness: None,
            abstol: None,
            reltol: None,
            splitting: None,
            external: None,
            time_span: Some(SolverTimeSpan { start, end }),
        }),
        ..Default::default()
    };
    let ts = |s: &str| TimePoint::Timestamp(s.to_string());
    let n = |v: i64| TimePoint::Seconds(v.into());

    // POSIX origin, far past and leap-day arithmetic, exactly.
    let doc = with(ts("1600-02-29T00:00:00Z"), ts("2400-03-01T00:00:00Z"));
    assert_eq!(
        earthsci_ast::resolve_time_span(&doc, None).expect("resolves"),
        Some((-11_670_998_400.0, 13_574_649_600.0))
    );
    let doc = with(n(0), ts("1970-01-01T00:00:00Z"));
    let e = earthsci_ast::resolve_time_span(&doc, None).expect_err("empty interval");
    assert_eq!(e.code, "solver_time_span_invalid");
    let doc = with(ts("1900-02-29T00:00:00Z"), n(0));
    let e = earthsci_ast::resolve_time_span(&doc, None).expect_err("1900 is no leap year");
    assert_eq!(e.code, "solver_time_span_invalid");
}

// --- the §2.2.7 public accessors: time_origin / timestamp_to_seconds ---------

fn fixture_by_id(m: &Value, id: &str) -> Value {
    m["fixtures"]
        .as_array()
        .expect("fixtures")
        .iter()
        .find(|f| f["id"] == id)
        .cloned()
        .unwrap_or_else(|| panic!("fixture {id} is pinned"))
}

#[test]
fn time_origin_is_the_instant_the_document_names() {
    let m = manifest();
    for (id, want) in [
        ("timestamps_posix", 0.0),
        ("timestamps_reference_time", 1_561_939_200.0),
        ("timestamps_temporal_start", 1_561_852_800.0),
        ("origin_with_offset", 1_561_939_200.0),
        ("fractional_seconds", 1_561_939_200.25),
        ("numbers", 0.0),
    ] {
        let doc = load(&fixture_by_id(&m, id)).unwrap_or_else(|e| panic!("{id} must load: {e}"));
        assert_eq!(
            earthsci_ast::time_origin(&doc).expect("an origin"),
            want,
            "{id}"
        );
    }
}

#[test]
fn timestamp_to_seconds_agrees_with_resolve_time_span_on_every_fixture() {
    let m = manifest();
    for f in fixtures(&m, "accepted") {
        let id = f["id"].as_str().expect("id");
        let span = &f["solver"]["time_span"];
        if span.is_null() {
            continue;
        }
        let doc = load(&f).unwrap_or_else(|e| panic!("{id} must load: {e}"));
        let resolved = earthsci_ast::resolve_time_span(&doc, None)
            .unwrap_or_else(|e| panic!("{id} resolves: {e}"))
            .unwrap_or_else(|| panic!("{id} pins a time_span"));
        for (index, key) in [(0usize, "start"), (1, "end")] {
            if let Some(stamp) = span[key].as_str() {
                assert_eq!(
                    earthsci_ast::timestamp_to_seconds(&doc, stamp).expect("converts"),
                    [resolved.0, resolved.1][index],
                    "{id}: {key}"
                );
            }
        }
    }
}

#[test]
fn timestamp_to_seconds_counts_from_the_document_origin() {
    let m = manifest();
    let reference = load(&fixture_by_id(&m, "timestamps_reference_time")).expect("loads");
    assert_eq!(
        earthsci_ast::timestamp_to_seconds(&reference, "2019-07-01T00:00:00Z").expect("converts"),
        0.0
    );
    assert_eq!(
        earthsci_ast::timestamp_to_seconds(&reference, "2019-07-03T00:00:00Z").expect("converts"),
        172_800.0
    );
    let fractional = load(&fixture_by_id(&m, "fractional_seconds")).expect("loads");
    assert_eq!(
        earthsci_ast::timestamp_to_seconds(&fractional, "2019-07-01T00:00:00.5Z")
            .expect("converts"),
        0.25
    );
    assert_eq!(
        earthsci_ast::timestamp_to_seconds(&fractional, "2019-07-01T00:00:01.25Z")
            .expect("converts"),
        1.0
    );
}

#[test]
fn the_origin_and_converter_are_consistent_for_any_timestamp() {
    let m = manifest();
    let posix = load(&fixture_by_id(&m, "timestamps_posix")).expect("loads");
    let reference = load(&fixture_by_id(&m, "timestamps_reference_time")).expect("loads");
    let origin = earthsci_ast::time_origin(&reference).expect("an origin");
    for stamp in [
        "2019-07-01T00:00:00Z",
        "2019-07-03T00:00:00Z",
        "2019-07-01T00:00:00.5Z",
    ] {
        assert_eq!(
            earthsci_ast::timestamp_to_seconds(&posix, stamp).expect("converts"),
            origin + earthsci_ast::timestamp_to_seconds(&reference, stamp).expect("converts"),
            "{stamp}"
        );
    }
}

#[test]
fn the_accessors_refuse_a_bad_origin_or_timestamp() {
    let m = manifest();
    // A present origin that is not a date-time: built in memory, so the schema
    // format has no chance to refuse it first.
    let bad: earthsci_ast::EsmFile = serde_json::from_str(&decay_doc(
        serde_json::json!({"time_span": {"start": 0, "end": 1}}),
        Some(serde_json::json!({"reference_time": "not-a-date"})),
    ))
    .expect("typed document");

    let e = earthsci_ast::time_origin(&bad).expect_err("an unreadable origin is refused");
    assert_eq!(e.code, "solver_time_span_invalid");
    assert!(
        e.message.contains("/domain/temporal/reference_time"),
        "{}",
        e.message
    );
    let e = earthsci_ast::timestamp_to_seconds(&bad, "2019-07-01T00:00:00Z")
        .expect_err("an unreadable origin is refused");
    assert_eq!(e.code, "solver_time_span_invalid");
    assert!(
        e.message.contains("/domain/temporal/reference_time"),
        "{}",
        e.message
    );

    let reference = load(&fixture_by_id(&m, "timestamps_reference_time")).expect("loads");
    let e = earthsci_ast::timestamp_to_seconds(&reference, "2019-07-01").expect_err("bad form");
    assert_eq!(e.code, "solver_time_span_invalid");
    assert!(
        e.message.contains("not an RFC 3339 UTC timestamp"),
        "{}",
        e.message
    );
    let e = earthsci_ast::timestamp_to_seconds(&reference, "2019-02-30T00:00:00Z")
        .expect_err("no such day");
    assert_eq!(e.code, "solver_time_span_invalid");
    assert!(e.message.contains("names no calendar day"), "{}", e.message);
}
