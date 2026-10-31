//! Document-scoped solver hints (esm-spec §2.2).
//!
//! The `solver` block records numerics the document knows about *itself* —
//! stiffness, integration tolerances, and a splitting hint — which each binding
//! maps to its own integrator.
//!
//! Every field is ADVISORY: a binding may ignore any or all of them and still
//! conform. Advisory governs the MECHANISM, never the OUTCOME — the
//! CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
//! the error band is untouched by this block and is not excused by it.
//!
//! This module carries the parts that are NOT advisory: the spec-version gates
//! (§2.2.4), the §2.2.2 tolerance resolution order, the §2.2.6 resolution
//! of `solver.external` to a location, and the §2.2.7 conversion and check of
//! `solver.time_span`.

use crate::diagnostic::{DiagnosticError, codes, err};
// The binding defaults (API_SPEC §5.8) live with `SolveOptions`, which is where
// they are applied; the §2.2.2 chain bottoms out on the same two constants
// rather than a second copy that could drift from them.
use crate::simulate::{DEFAULT_ABSTOL, DEFAULT_RELTOL};
use serde_json::Value;
use std::path::Path;

/// Reject a top-level `solver` block in a file declaring esm < 1.1.0.
///
/// The block arrives at `esm: 1.1.0`; a document declaring an earlier version
/// that carries one is rejected with `solver_version_too_old` (esm-spec
/// §2.2.4). Mirrors [`crate::template_imports::reject_template_imports_pre_v08`].
pub fn reject_solver_pre_v11(view: &Value) -> Result<(), DiagnosticError> {
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    if !obj.contains_key("solver") {
        return Ok(());
    }
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (1, 1) {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_VERSION_TOO_OLD,
        format!(
            "the top-level `solver` block requires esm >= 1.1.0; file declares {esm}. \
             Offending path: /solver"
        ),
    ))
}

/// Reject `solver.external` in a file declaring esm < 1.3.0.
///
/// The field arrives at `esm: 1.3.0`, after the block itself, so it carries
/// its own code (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document
/// whose block has no `external` stays valid. Below 1.1.0 the whole block is
/// already refused by [`reject_solver_pre_v11`], which runs first.
pub fn reject_solver_external_pre_v13(view: &Value) -> Result<(), DiagnosticError> {
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    let carries_external = obj
        .get("solver")
        .and_then(Value::as_object)
        .is_some_and(|s| s.contains_key("external"));
    if !carries_external {
        return Ok(());
    }
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (1, 3) {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_EXTERNAL_VERSION_TOO_OLD,
        format!(
            "`solver.external` requires esm >= 1.3.0; file declares {esm}. \
             Offending path: /solver/external"
        ),
    ))
}

/// Refuse a `solver.external` containing `${` (esm-spec §2.2.6).
///
/// Nothing is ever substituted into the reference: numerics chosen by the
/// environment are not reproducible, so a deployment-chosen run configuration
/// is a call-site argument, not a variable in the document.
fn refuse_unexpanded(external: &str) -> Result<(), DiagnosticError> {
    if !external.contains("${") {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_EXTERNAL_UNRESOLVED,
        format!(
            "/solver/external: \"{external}\" carries an unexpanded '${{...}}' variable. \
             esm-spec §2.2.6 never expands environment variables into a run-configuration \
             reference; write a path relative to this document, or pass the run \
             configuration at the call site."
        ),
    ))
}

/// The load-time half of [`refuse_unexpanded`], over the raw document. A
/// non-string `external` is left to schema validation.
pub(crate) fn reject_solver_external_unresolved(view: &Value) -> Result<(), DiagnosticError> {
    match view.pointer("/solver/external").and_then(Value::as_str) {
        Some(external) => refuse_unexpanded(external),
        None => Ok(()),
    }
}

/// Whether `path` begins with a drive letter, `C:/` or `C:\`, which esm-spec
/// §2.2.6 reads as absolute on every host.
fn is_drive_path(path: &str) -> bool {
    let b = path.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'/' | b'\\')
}

fn is_absolute_location_path(path: &str) -> bool {
    path.starts_with('/') || is_drive_path(path)
}

/// RFC 3986 §5.2.4 dot-segment removal on a `/`-separated absolute path,
/// lexically: `.` dropped, `..` removes the preceding segment, a `..` at the
/// root dropped.
fn remove_dot_segments(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    format!("/{}", out.join("/"))
}

/// An absolute `path` with its dot segments removed. A drive-letter path comes
/// back as `C:/…`, its `\` read as `/` and its drive a root that `..` does not
/// climb above.
fn lexical_absolute(path: &str) -> String {
    if is_drive_path(path) {
        format!(
            "{}{}",
            &path[..2],
            remove_dot_segments(&path[2..].replace('\\', "/"))
        )
    } else {
        remove_dot_segments(path)
    }
}

/// A host path as a `/`-separated string, or `None` when it is not UTF-8.
fn slashed(path: &Path) -> Option<String> {
    let s = path.to_str()?;
    Some(if std::path::MAIN_SEPARATOR == '/' {
        s.to_string()
    } else {
        s.replace(std::path::MAIN_SEPARATOR, "/")
    })
}

/// `dir` as the absolute, dot-segment-free directory *D* of esm-spec §2.2.6,
/// or `None` when it is not UTF-8. A relative `dir` is taken against the
/// process working directory. Purely lexical: never `realpath`, never the
/// filesystem.
pub(crate) fn absolute_directory(dir: &Path) -> Option<String> {
    let d = slashed(dir)?;
    let d = if d.is_empty() { ".".to_string() } else { d };
    if is_absolute_location_path(&d) {
        return Some(lexical_absolute(&d));
    }
    let cwd = std::env::current_dir()
        .ok()
        .and_then(|c| slashed(&c))
        .unwrap_or_else(|| "/".to_string());
    Some(lexical_absolute(&format!("{cwd}/{d}")))
}

/// `file://` plus an absolute, dot-segment-free path, each byte of its UTF-8
/// encoding outside `A-Za-z0-9-._~/:` written `%XX` (esm-spec §2.2.6). A drive
/// path gets the third slash: `file:///C:/…`.
fn file_location_url(path: &str) -> String {
    use std::fmt::Write as _;
    let mut url = String::from("file://");
    if !path.starts_with('/') {
        url.push('/');
    }
    for &b in path.as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/:".contains(&b) {
            url.push(b as char);
        } else {
            let _ = write!(url, "%{b:02X}");
        }
    }
    url
}

/// Where the document's `solver.external` points (esm-spec §2.2.6), or
/// `Ok(None)` when the document names no run configuration.
///
/// A URL (`scheme://…`) is returned unchanged. An absolute path — `/…`, or a
/// drive-letter `C:/…` / `C:\…` — has its dot segments removed, is
/// percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
/// Anything else is joined onto the base first: `base` when given (a relative
/// `base` is taken against the process working directory), otherwise the
/// directory recorded at load ([`EsmFile::document_base`]), otherwise, for a
/// document built in memory, the process working directory. Percent-encoding
/// writes each byte of the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as
/// `%XX`, `%` included: the input is a path, not a URL.
///
/// Purely lexical (RFC 3986 §5.2.4): never `realpath`, never the filesystem or
/// the network, so a location that does not exist resolves like any other.
/// The document is not changed — `emit` writes the authored string.
///
/// [`EsmFile::document_base`]: crate::EsmFile::document_base
pub fn solver_external_location(
    file: &crate::EsmFile,
    base: Option<&Path>,
) -> Result<Option<String>, DiagnosticError> {
    let Some(external) = file.solver.as_ref().and_then(|s| s.external.as_deref()) else {
        return Ok(None);
    };
    refuse_unexpanded(external)?;
    if crate::data_source_urls::is_scheme_led(external) {
        return Ok(Some(external.to_string()));
    }
    if is_absolute_location_path(external) {
        return Ok(Some(file_location_url(&lexical_absolute(external))));
    }
    let dir = match (base, file.document_base.as_deref()) {
        (Some(b), _) => absolute_directory(b),
        (None, Some(recorded)) => Some(recorded.to_string()),
        (None, None) => absolute_directory(Path::new(".")),
    };
    let Some(dir) = dir else {
        return Err(err(
            codes::SOLVER_EXTERNAL_UNRESOLVED,
            format!(
                "/solver/external: \"{external}\" is relative, and the directory it \
                 resolves against is not valid UTF-8, so it cannot be spelled as a URL \
                 (esm-spec §2.2.6)."
            ),
        ));
    };
    Ok(Some(file_location_url(&lexical_absolute(&format!(
        "{dir}/{external}"
    )))))
}

/// Reject `solver.time_span` in a file declaring esm < 1.3.0.
///
/// The field arrives at `esm: 1.3.0`, after the block itself, so it carries
/// its own code (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document
/// whose block has no `time_span` stays valid. Below 1.1.0 the whole block is
/// already refused by [`reject_solver_pre_v11`], which runs first. Reads the
/// ROOT's block only: a mounted document's `solver` block does not cross the
/// mount edge (§4.7).
pub fn reject_solver_time_span_pre_v13(view: &Value) -> Result<(), DiagnosticError> {
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    let carries_time_span = obj
        .get("solver")
        .and_then(Value::as_object)
        .is_some_and(|s| s.contains_key("time_span"));
    if !carries_time_span {
        return Ok(());
    }
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (1, 3) {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_TIME_SPAN_VERSION_TOO_OLD,
        format!(
            "`solver.time_span` requires esm >= 1.3.0; file declares {esm}. \
             Offending path: /solver/time_span"
        ),
    ))
}

/// Why a date-time string did not convert.
enum StampError {
    /// Not in the accepted form at all (for a bound: the schema pattern).
    Form,
    /// In the form, but `YYYY-MM-DD` names no calendar day.
    NoDay,
}

/// A date-time as esm-spec §2.2.7 converts it: its whole part *W* (integer
/// POSIX seconds, proleptic Gregorian, offset subtracted) and its fraction *f*
/// (the digits after the point read as a binary64 in `[0, 1)`).
#[derive(Clone, Copy)]
struct Instant {
    whole: i64,
    frac: f64,
}

/// Days from 1970-01-01 to `y-m-d` in the proleptic Gregorian calendar
/// (H. Hinnant's `days_from_civil`), exact integer arithmetic.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// The value of an all-ASCII-digit field, or `None`.
fn digits(b: &[u8]) -> Option<i64> {
    if b.is_empty() || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(b.iter().fold(0, |acc, &c| acc * 10 + i64::from(c - b'0')))
}

/// Read `YYYY-MM-DDThh:mm:ss(.f+)?` then a zone, exactly by the fields — never
/// a host date library (esm-spec §2.2.7). `utc_only` is the form of a
/// `time_span` bound (the schema pattern: `T` and `Z` only); otherwise it is
/// the form of a time origin (`T` or `t`, then `Z`, `z` or `±hh:mm`). Hours run
/// 00–23, minutes and seconds 00–59 (`:60` is not admitted), months 01–12,
/// days 01–31; a day past its month's end is [`StampError::NoDay`].
fn parse_date_time(s: &str, utc_only: bool) -> Result<Instant, StampError> {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || !(b[10] == b'T' || (!utc_only && b[10] == b't'))
        || b[13] != b':'
        || b[16] != b':'
    {
        return Err(StampError::Form);
    }
    let field = |r: std::ops::Range<usize>| digits(&b[r]).ok_or(StampError::Form);
    let (year, month, day) = (field(0..4)?, field(5..7)?, field(8..10)?);
    let (hour, minute, second) = (field(11..13)?, field(14..16)?, field(17..19)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return Err(StampError::Form);
    }
    let mut i = 19;
    let mut frac = 0.0;
    if b[i] == b'.' {
        let start = i + 1;
        let mut j = start;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j == start {
            return Err(StampError::Form);
        }
        frac = format!("0.{}", &s[start..j])
            .parse::<f64>()
            .map_err(|_| StampError::Form)?;
        i = j;
    }
    let offset = match &b[i..] {
        [b'Z'] => 0,
        [b'z'] if !utc_only => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] if !utc_only => {
            let oh = digits(&[*h1, *h2]).ok_or(StampError::Form)?;
            let om = digits(&[*m1, *m2]).ok_or(StampError::Form)?;
            if oh > 23 || om > 59 {
                return Err(StampError::Form);
            }
            let off = oh * 3600 + om * 60;
            if *sign == b'-' { -off } else { off }
        }
        _ => return Err(StampError::Form),
    };
    if day > days_in_month(year, month) {
        return Err(StampError::NoDay);
    }
    let whole =
        days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Ok(Instant { whole, frac })
}

/// One bound of a `time_span`, borrowed from either the raw document or the
/// typed one.
#[derive(Clone, Copy)]
enum Bound<'a> {
    Seconds(f64),
    Timestamp(&'a str),
}

impl<'a> Bound<'a> {
    fn of_point(p: &'a crate::types::TimePoint) -> Self {
        match p {
            crate::types::TimePoint::Seconds(n) => Bound::Seconds(n.as_f64().unwrap_or(f64::NAN)),
            crate::types::TimePoint::Timestamp(s) => Bound::Timestamp(s),
        }
    }
}

fn time_span_invalid(why: impl std::fmt::Display) -> DiagnosticError {
    err(
        codes::SOLVER_TIME_SPAN_INVALID,
        format!("/solver/time_span: {why} (esm-spec §2.2.7)."),
    )
}

/// Why the origin field that applies cannot serve as a time origin.
///
/// The message is assembled by [`OriginFault::message`] with a caller-supplied
/// subject: the `resolve_time_span` path names a timestamp bound, the public
/// accessors name the input they were handed.
struct OriginFault {
    /// JSON pointer of the offending field.
    pointer: String,
    /// The authored value's text, when it was a string.
    text: Option<String>,
    /// The text matched the RFC 3339 shape but names no calendar day.
    no_day: bool,
}

impl OriginFault {
    fn message(&self, subject: &str) -> String {
        let pointer = &self.pointer;
        match (&self.text, self.no_day) {
            (Some(t), true) => {
                format!("{subject} {pointer} = \"{t}\", which names no calendar day")
            }
            (Some(t), false) => {
                format!("{subject} {pointer} = \"{t}\", which is not an RFC 3339 date-time")
            }
            (None, _) => format!("{subject} {pointer}, which is not an RFC 3339 date-time"),
        }
    }
}

/// The time origin of esm-spec §2.2.7, first match wins:
/// `domain.temporal.reference_time`, then `domain.temporal.start`, then the
/// POSIX epoch.
fn time_origin_of(temporal: Option<&Value>) -> Result<Instant, OriginFault> {
    let epoch = Instant {
        whole: 0,
        frac: 0.0,
    };
    let Some(temporal) = temporal.and_then(Value::as_object) else {
        return Ok(epoch);
    };
    for key in ["reference_time", "start"] {
        let Some(v) = temporal.get(key) else {
            continue;
        };
        let pointer = format!("/domain/temporal/{key}");
        let Some(text) = v.as_str() else {
            return Err(OriginFault {
                pointer,
                text: None,
                no_day: false,
            });
        };
        return match parse_date_time(text, false) {
            Ok(origin) => Ok(origin),
            Err(kind) => Err(OriginFault {
                pointer,
                text: Some(text.to_string()),
                no_day: matches!(kind, StampError::NoDay),
            }),
        };
    }
    Ok(epoch)
}

/// The §2.2.7 message for a timestamp that did not convert, `label` naming it
/// (`start`, `end`, `timestamp`). Shared by the `time_span` path and the public
/// accessor so their wording cannot drift.
fn stamp_error(label: &str, text: &str, kind: StampError) -> String {
    match kind {
        StampError::NoDay => format!("{label} \"{text}\" names no calendar day"),
        StampError::Form => format!(
            "{label} \"{text}\" is not an RFC 3339 UTC timestamp \
             (YYYY-MM-DDThh:mm:ss[.f]Z)"
        ),
    }
}

/// Convert both bounds to binary64 seconds on the document's clock and check
/// that they describe an interval (esm-spec §2.2.7). A timestamp is
/// `(W − W₀) + (f − f₀)`: the whole-second difference in integers, then
/// converted, then added to the fraction difference taken in binary64.
fn time_span_seconds(
    start: Bound<'_>,
    end: Bound<'_>,
    temporal: Option<&Value>,
) -> Result<(f64, f64), DiagnosticError> {
    let mut stamps = [None, None];
    for (slot, (name, bound)) in stamps.iter_mut().zip([("start", start), ("end", end)]) {
        if let Bound::Timestamp(text) = bound {
            *slot = Some(
                parse_date_time(text, true)
                    .map_err(|e| time_span_invalid(stamp_error(name, text, e)))?,
            );
        }
    }
    let origin = if stamps.iter().any(Option::is_some) {
        Some(time_origin_of(temporal).map_err(|f| {
            time_span_invalid(format_args!(
                "{}",
                f.message("a timestamp is counted from the time origin")
            ))
        })?)
    } else {
        None
    };
    let seconds = |bound: Bound<'_>, stamp: Option<Instant>| match (bound, stamp, origin) {
        (_, Some(t), Some(o)) => (t.whole - o.whole) as f64 + (t.frac - o.frac),
        (Bound::Seconds(v), ..) => v,
        // A timestamp always has a stamp and an origin by now.
        (Bound::Timestamp(_), ..) => f64::NAN,
    };
    let (s, e) = (seconds(start, stamps[0]), seconds(end, stamps[1]));
    // "Not after", not `e <= s`: a NaN bound is no interval either.
    if e.partial_cmp(&s) != Some(std::cmp::Ordering::Greater) {
        return Err(time_span_invalid(format_args!(
            "end ({e} s) is not after start ({s} s); the interval is empty or reversed"
        )));
    }
    Ok((s, e))
}

/// A raw bound in a schema-valid form — a number, or a string matching the
/// schema's timestamp pattern (a day past its month's end still matches) — or
/// `None`, which the schema reports.
fn raw_bound(v: &Value) -> Option<Bound<'_>> {
    match v {
        Value::Number(n) => n.as_f64().map(Bound::Seconds),
        Value::String(s) => match parse_date_time(s, true) {
            Ok(_) | Err(StampError::NoDay) => Some(Bound::Timestamp(s)),
            Err(StampError::Form) => None,
        },
        _ => None,
    }
}

/// The load-time check of esm-spec §2.2.7 over the raw ROOT document, run
/// after the version gate and before schema validation: refuse a `time_span`
/// that is no interval with `solver_time_span_invalid`. Runs only when both
/// bounds have a schema-valid form; anything else is the schema's to report.
pub(crate) fn reject_solver_time_span_invalid(view: &Value) -> Result<(), DiagnosticError> {
    let Some(span) = view.pointer("/solver/time_span").and_then(Value::as_object) else {
        return Ok(());
    };
    let (Some(start), Some(end)) = (
        span.get("start").and_then(raw_bound),
        span.get("end").and_then(raw_bound),
    ) else {
        return Ok(());
    };
    time_span_seconds(start, end, view.pointer("/domain/temporal")).map(|_| ())
}

/// The run interval, most specific first (esm-spec §2.2.7, by the §2.2.2
/// order):
///
/// 1. `tspan`, an explicit interval at the call site — it always wins, both
///    bounds.
/// 2. Otherwise the document's `solver.time_span`, converted to binary64
///    seconds on the document's clock (a timestamp counts from
///    `domain.temporal.reference_time`, else `domain.temporal.start`, else the
///    POSIX epoch).
/// 3. Otherwise `Ok(None)`: no interval, not a default one.
///
/// The document is not changed — `emit` writes the authored bounds. A loaded
/// document has already passed the load-time check; one built in memory that
/// describes no interval fails here with `solver_time_span_invalid`.
pub fn resolve_time_span(
    file: &crate::EsmFile,
    tspan: Option<(f64, f64)>,
) -> Result<Option<(f64, f64)>, DiagnosticError> {
    if tspan.is_some() {
        return Ok(tspan);
    }
    let Some(span) = file.solver.as_ref().and_then(|s| s.time_span.as_ref()) else {
        return Ok(None);
    };
    let temporal = file.domain.as_ref().and_then(|d| d.temporal.as_ref());
    time_span_seconds(
        Bound::of_point(&span.start),
        Bound::of_point(&span.end),
        temporal,
    )
    .map(Some)
}

mod sealed {
    /// Where a [`super::TimeOriginSource`] keeps its `domain.temporal`. Private,
    /// so the set of sources is this crate's to extend.
    pub trait Temporal {
        /// `Ok(temporal)` (`None`: no `temporal`), or `Err(domain)` for a raw
        /// `domain` that is neither an object nor `null`, which has no origin
        /// to read.
        fn temporal(&self) -> Result<Option<&serde_json::Value>, &serde_json::Value>;
    }
}

/// What the §2.2.7 clock accessors read a time origin from: a document, or
/// its `domain` alone (esm-spec §2.2.7).
///
/// Implemented for
///
/// - [`crate::EsmFile`], a loaded or in-memory document;
/// - [`crate::Domain`], a typed domain;
/// - [`serde_json::Value`], the raw JSON `domain` of a document that has not
///   been loaded — read as the load-time check reads it, so a present key
///   selects its field, `null` included, and a `domain` or `temporal` that is
///   not an object has no origin field (a missing domain is `Value::Null`);
/// - `Option<T>` (`None` is a document without a domain), `&T`, `Box<T>`,
///   `Rc<T>` and `Arc<T>`, for any source `T`, so a caller holding a document
///   behind a pointer passes it as it is.
///
/// A raw `domain` that is neither an object nor `null` (a string, an array, a
/// number or a boolean) has no origin to read: the accessors refuse it with
/// `time_origin_invalid`, naming `/domain`.
///
/// The trait is sealed: its one method is private to this crate.
pub trait TimeOriginSource: sealed::Temporal {}

impl sealed::Temporal for crate::EsmFile {
    fn temporal(&self) -> Result<Option<&Value>, &Value> {
        Ok(self.domain.as_ref().and_then(|d| d.temporal.as_ref()))
    }
}
impl TimeOriginSource for crate::EsmFile {}

impl sealed::Temporal for crate::Domain {
    fn temporal(&self) -> Result<Option<&Value>, &Value> {
        Ok(self.temporal.as_ref())
    }
}
impl TimeOriginSource for crate::Domain {}

impl sealed::Temporal for Value {
    fn temporal(&self) -> Result<Option<&Value>, &Value> {
        match self {
            Value::Null => Ok(None),
            Value::Object(domain) => Ok(domain.get("temporal")),
            _ => Err(self),
        }
    }
}
impl TimeOriginSource for Value {}

impl<T: TimeOriginSource> sealed::Temporal for Option<T> {
    fn temporal(&self) -> Result<Option<&Value>, &Value> {
        self.as_ref().map_or(Ok(None), sealed::Temporal::temporal)
    }
}
impl<T: TimeOriginSource> TimeOriginSource for Option<T> {}

/// A source behind a reference or an owning pointer reads as the source
/// itself. Without these, a generic `&S` would no longer deref `&Arc<EsmFile>`
/// to `&EsmFile` the way the old `&EsmFile` parameter did.
macro_rules! forward_time_origin_source {
    ($($ptr:ty),*) => {$(
        impl<T: TimeOriginSource + ?Sized> sealed::Temporal for $ptr {
            fn temporal(&self) -> Result<Option<&Value>, &Value> {
                (**self).temporal()
            }
        }
        impl<T: TimeOriginSource + ?Sized> TimeOriginSource for $ptr {}
    )*};
}
forward_time_origin_source!(&T, Box<T>, std::rc::Rc<T>, std::sync::Arc<T>);

/// The source's time origin as an [`Instant`], or `time_origin_invalid`
/// naming the field (or `/domain`, for a raw domain that is not an object).
/// One lookup path, shared by [`time_origin`] and [`timestamp_to_seconds`].
fn origin_instant<S: TimeOriginSource + ?Sized>(source: &S) -> Result<Instant, DiagnosticError> {
    let temporal = sealed::Temporal::temporal(source).map_err(|domain| {
        err(
            codes::TIME_ORIGIN_INVALID,
            format!(
                "/domain is {domain}, which is not an object, so it has no time origin \
                 to count a timestamp from (esm-spec §2.2.7)."
            ),
        )
    })?;
    time_origin_of(temporal).map_err(|fault| {
        err(
            codes::TIME_ORIGIN_INVALID,
            format!("{} (esm-spec §2.2.7).", fault.message("the time origin")),
        )
    })
}

/// The time origin in seconds from the POSIX epoch (esm-spec §2.2.7):
/// `domain.temporal.reference_time`, else `domain.temporal.start`, else the
/// epoch itself, as `W0 + f0` -- whole seconds converted, the fraction added in
/// binary64.
///
/// This is the origin a `solver.time_span` timestamp counts from: the `W0`/`f0`
/// half of what [`resolve_time_span`] does, exposed so a caller can convert a
/// timestamp of its own with [`timestamp_to_seconds`]. `source` is a document
/// or its domain, typed or raw JSON ([`TimeOriginSource`]):
/// `time_origin(&file)`, `time_origin(&domain)`, `time_origin(&doc["domain"])`.
///
/// A field that is present but is not an RFC 3339 date-time naming a calendar
/// day fails with `time_origin_invalid`, naming its pointer; so does a raw
/// `domain` that is not an object, naming `/domain`.
pub fn time_origin<S: TimeOriginSource + ?Sized>(source: &S) -> Result<f64, DiagnosticError> {
    let origin = origin_instant(source)?;
    Ok(origin.whole as f64 + origin.frac)
}

/// `timestamp` as seconds from `source`'s time origin (esm-spec §2.2.7).
///
/// `timestamp` is an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z`, the
/// `solver.time_span` bound form). The result is `(W - W0) + (f - f0)`: the
/// whole-second difference in integers, then the fractions added in binary64,
/// exactly as [`resolve_time_span`] converts a `time_span` timestamp. `source`
/// and the origin are as for [`time_origin`].
///
/// Each cause has its own code, checked in this order, so the first that
/// applies is the one returned:
///
/// 1. `timestamp_malformed` -- `timestamp` is not of that form;
/// 2. `timestamp_no_calendar_day` -- it is, but its day is not in its month
///    (`2019-02-30`, `02-29` outside a leap year);
/// 3. `time_origin_invalid` -- the origin field that applies cannot be read,
///    or a raw `domain` is not an object.
pub fn timestamp_to_seconds<S: TimeOriginSource + ?Sized>(
    source: &S,
    timestamp: &str,
) -> Result<f64, DiagnosticError> {
    let stamp = parse_date_time(timestamp, true).map_err(|kind| {
        let code = match &kind {
            StampError::Form => codes::TIMESTAMP_MALFORMED,
            StampError::NoDay => codes::TIMESTAMP_NO_CALENDAR_DAY,
        };
        err(
            code,
            format!(
                "{} (esm-spec §2.2.7).",
                stamp_error("timestamp", timestamp, kind)
            ),
        )
    })?;
    let origin = origin_instant(source)?;
    Ok((stamp.whole - origin.whole) as f64 + (stamp.frac - origin.frac))
}

/// Resolve integration tolerances most-specific first (esm-spec §2.2.2):
///
/// 1. An explicit argument at the `solve` call site — wins outright.
/// 2. Otherwise the document's `solver.abstol` / `solver.reltol`.
/// 3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).
///
/// The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
/// `abstol` on the default — the same per-field fall-through §6.6.4 uses.
///
/// These are INTEGRATION tolerances, a different quantity from the `tolerance`
/// object an assertion is COMPARED at (§6.6.4).
pub fn resolve_tolerances(
    solver: Option<&crate::types::Solver>,
    abstol: Option<f64>,
    reltol: Option<f64>,
) -> (f64, f64) {
    (
        abstol
            .or_else(|| solver.and_then(|s| s.abstol))
            .unwrap_or(DEFAULT_ABSTOL),
        reltol
            .or_else(|| solver.and_then(|s| s.reltol))
            .unwrap_or(DEFAULT_RELTOL),
    )
}

/// Map a `solver` block with nothing set to absence (esm-spec §2.2).
///
/// `"solver": {}` is legal — every other optional top-level container admits an
/// empty object, and making this one the exception would be a rule with no
/// payoff — but it means exactly what omitting the block means, so it is
/// normalized away AT LOAD. The typed document then never holds a block with
/// nothing set, and `parse -> emit` cannot disagree across bindings about
/// whether `{}` survives. Not covered by `skip_serializing_if`: that is
/// per-FIELD, so an empty `Solver` would still emit its enclosing `{}`.
pub(crate) fn normalize_empty(
    solver: Option<crate::types::Solver>,
) -> Option<crate::types::Solver> {
    let s = solver?;
    if s.stiffness.is_none()
        && s.abstol.is_none()
        && s.reltol.is_none()
        && s.splitting.is_none()
        && s.external.is_none()
        && s.time_span.is_none()
    {
        return None;
    }
    Some(s)
}
