//! Closed function registry — Rust binding (esm-tzp / esm-1vr).
//!
//! Implements the spec-defined closed function set from esm-spec §9.2:
//!
//! * `datetime.year`, `month`, `day`, `hour`, `minute`, `second`,
//!   `day_of_year`, `julian_day`, `is_leap_year` — proleptic-Gregorian
//!   calendar decomposition of an IEEE-754 `binary64` UTC scalar
//!   (seconds since the Unix epoch, no leap-second consultation).
//! * `interp.searchsorted` — 1-based search-into-sorted-array (Julia
//!   `searchsortedfirst` semantics with explicit out-of-range / NaN /
//!   duplicate behavior pinned by spec).
//! * `interp.linear`, `interp.bilinear` — 1-D and 2-D linear tensor
//!   interpolation with extrapolate-flat clamping. Implemented as direct
//!   primitives (rather than as `interp.searchsorted` + `index` +
//!   AST-arithmetic compositions) to satisfy the §9.2 pinned evaluation
//!   order `result = a + w * (b - a)` for cross-binding bit-equivalence.
//!
//! The set is **closed**: callers MUST reject any `fn`-op `name` outside this
//! list (diagnostic `unknown_closed_function`). Bindings agreeing on this
//! contract is what gives v0.3.0 cross-binding bit-equivalence on the
//! integer-typed outputs (zero ulp drift) and ≤ 1 ulp on `julian_day`.

use std::collections::HashSet;
use std::sync::OnceLock;

use thiserror::Error;

/// Error type for closed-function dispatch failures (esm-spec §9.1–§9.2).
///
/// The `code` field carries one of the stable diagnostic codes pinned by the
/// spec; downstream tooling pattern-matches on these strings. The set is
/// kept in lockstep with the Julia / Python / TypeScript / Go bindings.
#[derive(Error, Debug, Clone, PartialEq, Eq)]
#[error("ClosedFunctionError({code}): {message}")]
pub struct ClosedFunctionError {
    /// Stable diagnostic code: `unknown_closed_function`,
    /// `closed_function_arity`, `closed_function_overflow`,
    /// `searchsorted_non_monotonic`, `searchsorted_nan_in_table`,
    /// `closed_function_arg_type`.
    pub code: String,

    /// Human-readable diagnostic message.
    pub message: String,
}

impl ClosedFunctionError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

/// Argument value passed to a closed function. The two cases mirror the
/// shapes the spec actually permits at call sites: a scalar (any AST node
/// that evaluates to `f64`) and an inline `const`-op array (used as the
/// `xs` table for `interp.searchsorted`).
#[derive(Debug, Clone)]
pub enum ClosedArg {
    /// Scalar argument (e.g. `t_utc`, `x`).
    Scalar(f64),

    /// Inline `const`-op array (e.g. the `xs` table for `searchsorted`,
    /// or an axis array for `interp.linear` / `interp.bilinear`).
    Array(Vec<f64>),

    /// Inline `const`-op 2-D array (e.g. the `table` arg for
    /// `interp.bilinear`). Outer index is the row (axis-x position),
    /// inner index the column (axis-y position); see esm-spec §9.2.
    Array2D(Vec<Vec<f64>>),
}

impl ClosedArg {
    // `position` is the 0-based argument index; diagnostics render it 1-based
    // ("arg #1" is the first argument), matching the 1-based element indexing
    // used by this module's table diagnostics. Only the diagnostic CODE is
    // pinned cross-binding; the prose is binding-local.
    fn expect_scalar(&self, name: &str, position: usize) -> Result<f64, ClosedFunctionError> {
        match self {
            ClosedArg::Scalar(v) => Ok(*v),
            ClosedArg::Array(_) | ClosedArg::Array2D(_) => Err(ClosedFunctionError::new(
                "closed_function_arg_type",
                format!("{name}: arg #{} must be scalar, got array", position + 1),
            )),
        }
    }

    fn expect_array(&self, name: &str, position: usize) -> Result<&[f64], ClosedFunctionError> {
        match self {
            ClosedArg::Array(v) => Ok(v.as_slice()),
            ClosedArg::Scalar(_) | ClosedArg::Array2D(_) => Err(ClosedFunctionError::new(
                "closed_function_arg_type",
                format!("{name}: arg #{} must be 1-D array, got other shape", position + 1),
            )),
        }
    }

    fn expect_array2d(
        &self,
        name: &str,
        position: usize,
    ) -> Result<&[Vec<f64>], ClosedFunctionError> {
        match self {
            ClosedArg::Array2D(v) => Ok(v.as_slice()),
            ClosedArg::Scalar(_) | ClosedArg::Array(_) => Err(ClosedFunctionError::new(
                "closed_function_arg_type",
                format!("{name}: arg #{} must be 2-D array, got other shape", position + 1),
            )),
        }
    }
}

/// Scalar return value from a closed function. Integer-typed entries (every
/// `datetime.*` except `julian_day`, plus `interp.searchsorted`) are kept
/// distinct from float entries so callers can recover the spec-pinned integer
/// contract without ulp loss.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ClosedValue {
    /// Signed 32-bit integer result. Boxed as `i32` because the spec pins
    /// integer outputs to that width and bindings MUST raise
    /// `closed_function_overflow` if a result would overflow.
    Integer(i32),

    /// Float result (only `datetime.julian_day` in v0.3.0).
    Float(f64),
}

impl ClosedValue {
    /// Promote to f64 for AST evaluators that drive everything as `binary64`.
    /// Integer→float conversion is exact for the i32 domain (i32 fits in
    /// f64's 53-bit mantissa with no loss), so the spec's zero-ulp integer
    /// contract survives the lift.
    pub fn as_f64(self) -> f64 {
        match self {
            ClosedValue::Integer(i) => i as f64,
            ClosedValue::Float(f) => f,
        }
    }
}

/// Native handler signature for one closed function: the dotted spec name
/// (for diagnostics) plus the evaluated argument list.
type ClosedHandler = fn(&str, &[ClosedArg]) -> Result<ClosedValue, ClosedFunctionError>;

/// The v0.3.0 closed function registry (esm-spec §9.1/§9.2): one row per
/// primitive, dotted name → native handler. Membership
/// ([`closed_function_names`]) and dispatch ([`evaluate_closed_function`])
/// both derive from this single table, so a name can never be registered
/// without a handler (the old hand-synced set + match could drift and only
/// failed at runtime). Adding a primitive requires a spec rev.
const CLOSED_FUNCTIONS: &[(&str, ClosedHandler)] = &[
    ("datetime.year", cf_datetime_year),
    ("datetime.month", |name, args| {
        datetime_field(name, args, |(_, m, _, _, _, _)| m)
    }),
    ("datetime.day", |name, args| {
        datetime_field(name, args, |(_, _, d, _, _, _)| d)
    }),
    ("datetime.hour", |name, args| {
        datetime_field(name, args, |(_, _, _, h, _, _)| h)
    }),
    ("datetime.minute", |name, args| {
        datetime_field(name, args, |(_, _, _, _, mi, _)| mi)
    }),
    ("datetime.second", |name, args| {
        datetime_field(name, args, |(_, _, _, _, _, s)| s)
    }),
    ("datetime.day_of_year", cf_datetime_day_of_year),
    ("datetime.julian_day", cf_datetime_julian_day),
    ("datetime.is_leap_year", cf_datetime_is_leap_year),
    ("interp.searchsorted", cf_interp_searchsorted),
    ("interp.linear", cf_interp_linear),
    ("interp.bilinear", cf_interp_bilinear),
];

/// The v0.3.0 closed function set. Bindings MUST reject any `fn`-op `name`
/// not in this set (esm-spec §9.1). Derived from [`CLOSED_FUNCTIONS`].
pub fn closed_function_names() -> &'static HashSet<String> {
    static NAMES: OnceLock<HashSet<String>> = OnceLock::new();
    NAMES.get_or_init(|| {
        CLOSED_FUNCTIONS
            .iter()
            .map(|(n, _)| (*n).to_string())
            .collect()
    })
}

/// Dispatch a closed function call. `name` is the dotted-module spec path
/// (e.g. `"datetime.julian_day"`); `args` is the list of evaluated argument
/// values. Returns [`ClosedValue`] so callers can preserve the integer/float
/// distinction; promotion to `f64` is available via [`ClosedValue::as_f64`].
pub fn evaluate_closed_function(
    name: &str,
    args: &[ClosedArg],
) -> Result<ClosedValue, ClosedFunctionError> {
    match CLOSED_FUNCTIONS.iter().find(|(n, _)| *n == name) {
        Some((n, handler)) => handler(n, args),
        None => Err(ClosedFunctionError::new(
            "unknown_closed_function",
            format!(
                "`fn` name `{name}` is not in the v0.3.0 closed function registry \
                 (esm-spec §9.2). Adding a primitive requires a spec rev."
            ),
        )),
    }
}

fn cf_datetime_year(name: &str, args: &[ClosedArg]) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 1)?;
    let t = args[0].expect_scalar(name, 0)?;
    let (y, _, _, _, _, _) = decompose_utc(t);
    Ok(ClosedValue::Integer(check_i32(name, y as i64)?))
}

fn cf_datetime_day_of_year(
    name: &str,
    args: &[ClosedArg],
) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 1)?;
    let t = args[0].expect_scalar(name, 0)?;
    let (y, m, d, _, _, _) = decompose_utc(t);
    Ok(ClosedValue::Integer(day_of_year(y, m, d) as i32))
}

fn cf_datetime_julian_day(
    name: &str,
    args: &[ClosedArg],
) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 1)?;
    let t = args[0].expect_scalar(name, 0)?;
    Ok(ClosedValue::Float(julian_day(t)))
}

fn cf_datetime_is_leap_year(
    name: &str,
    args: &[ClosedArg],
) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 1)?;
    let t = args[0].expect_scalar(name, 0)?;
    let (y, _, _, _, _, _) = decompose_utc(t);
    Ok(ClosedValue::Integer(if is_leap_year(y) { 1 } else { 0 }))
}

fn cf_interp_searchsorted(
    name: &str,
    args: &[ClosedArg],
) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 2)?;
    let x = args[0].expect_scalar(name, 0)?;
    let xs = args[1].expect_array(name, 1)?;
    Ok(ClosedValue::Integer(check_i32(
        name,
        searchsorted(name, x, xs)?,
    )?))
}

fn cf_interp_linear(name: &str, args: &[ClosedArg]) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 3)?;
    let table = args[0].expect_array(name, 0)?;
    let axis = args[1].expect_array(name, 1)?;
    let x = args[2].expect_scalar(name, 2)?;
    Ok(ClosedValue::Float(interp_linear(table, axis, x)?))
}

fn cf_interp_bilinear(name: &str, args: &[ClosedArg]) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 5)?;
    let table = args[0].expect_array2d(name, 0)?;
    let axis_x = args[1].expect_array(name, 1)?;
    let axis_y = args[2].expect_array(name, 2)?;
    let x = args[3].expect_scalar(name, 3)?;
    let y = args[4].expect_scalar(name, 4)?;
    Ok(ClosedValue::Float(interp_bilinear(
        table, axis_x, axis_y, x, y,
    )?))
}

/// Evaluate a unary `datetime.*` accessor that returns one `u32` field of the
/// UTC decomposition as an integer (month, day, hour, minute, second).
fn datetime_field(
    name: &str,
    args: &[ClosedArg],
    select: impl Fn((i32, u32, u32, u32, u32, u32)) -> u32,
) -> Result<ClosedValue, ClosedFunctionError> {
    expect_arity(name, args, 1)?;
    let t = args[0].expect_scalar(name, 0)?;
    Ok(ClosedValue::Integer(select(decompose_utc(t)) as i32))
}

fn expect_arity(name: &str, args: &[ClosedArg], n: usize) -> Result<(), ClosedFunctionError> {
    if args.len() != n {
        return Err(ClosedFunctionError::new(
            "closed_function_arity",
            format!("{name} expects {n} argument(s), got {}", args.len()),
        ));
    }
    Ok(())
}

fn check_i32(name: &str, v: i64) -> Result<i32, ClosedFunctionError> {
    if v < i32::MIN as i64 || v > i32::MAX as i64 {
        return Err(ClosedFunctionError::new(
            "closed_function_overflow",
            format!("{name}: result {v} overflows Int32"),
        ));
    }
    Ok(v as i32)
}

// ---------------------------------------------------------------------------
// Calendar arithmetic — integer ymd/hms decomposition, Fliegel–van Flandern
// JDN. The spec pins floored division by 86400 to split (date, time-of-day);
// we use Python-style floor / mod so negative `t_utc` decomposes the same as
// Julia's `unix2datetime`.
// ---------------------------------------------------------------------------

// Floored division/modulus on f64 → integer day count and seconds-of-day.
// `seconds_in_day` lands in `[0.0, 86400.0)` (inclusive of 0, exclusive of
// 86400) so the per-component decomposition is unambiguous.
#[inline]
fn floor_div_mod(t_utc: f64) -> (i64, f64) {
    let day = (t_utc / 86400.0).floor();
    let mut sec = t_utc - day * 86400.0;
    // Defensive: floating-point rounding may push `sec` to exactly 86400.0
    // for inputs near a day boundary. Re-map onto the half-open interval.
    if sec >= 86400.0 {
        sec -= 86400.0;
    } else if sec < 0.0 {
        sec += 86400.0;
    }
    (day as i64, sec)
}

// Decompose a UTC scalar into (year, month, day, hour, minute, second). Uses
// the Hinnant civil_from_days algorithm (see howardhinnant.github.io/date_algorithms.html)
// extended to the proleptic-Gregorian calendar; the algorithm is exact on
// the full i64 day-count domain, far beyond the i32 year contract.
fn decompose_utc(t_utc: f64) -> (i32, u32, u32, u32, u32, u32) {
    let (day_count, sec_in_day) = floor_div_mod(t_utc);
    let (y, m, d) = civil_from_days(day_count);
    // Truncate fractional seconds — the spec pins integer outputs and
    // forbids leap-second slots (so seconds ∈ 0..=59).
    let s = sec_in_day.trunc() as i64;
    let hour = (s / 3600) as u32;
    let minute = ((s % 3600) / 60) as u32;
    let second = (s % 60) as u32;
    (y, m, d, hour, minute, second)
}

// Hinnant's algorithm: days since 1970-01-01 → (y, m, d) on the proleptic-
// Gregorian calendar. Negative day counts produce negative / pre-Common-Era
// years per ISO 8601 (1 BC = 0, 2 BC = -1).
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d)
}

fn is_leap_year(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
}

fn day_of_year(y: i32, m: u32, d: u32) -> u32 {
    const CUM: [u32; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let mut doy = CUM[(m - 1) as usize] + d;
    if m > 2 && is_leap_year(y) {
        doy += 1;
    }
    doy
}

// Fliegel–van Flandern (1968) JDN on the integer date component, plus the
// fractional-day offset relative to noon UTC. Matches the Julia reference
// (which uses Julia's `÷` — truncate-toward-zero — for the inner divides) to
// within ≤ 1 ulp; the only float op is the final divide by 86400. Rust's
// integer `/` is also truncate-toward-zero, so the inner divides match Julia
// directly. Using `div_euclid` here would shift the (m − 14)/12 term by one
// for Jan/Feb (off by ±2 days) and fail epoch — keep `/`.
fn julian_day(t_utc: f64) -> f64 {
    let (day_count, sec_in_day) = floor_div_mod(t_utc);
    let (y, m, d) = civil_from_days(day_count);
    let y = y as i64;
    let m = m as i64;
    let d = d as i64;
    let jdn = (1461 * (y + 4800 + (m - 14) / 12)) / 4 + (367 * (m - 2 - 12 * ((m - 14) / 12))) / 12
        - (3 * ((y + 4900 + (m - 14) / 12) / 100)) / 4
        + d
        - 32075;
    (jdn as f64) + (sec_in_day - 43200.0) / 86400.0
}

// `interp.searchsorted` per esm-spec §9.2: 1-based, left-side bias on
// duplicates / exact matches; out-of-range below → 1, above → N+1; NaN x →
// N+1; NaN entries in xs → error; non-monotonic xs → error.
fn searchsorted(name: &str, x: f64, xs: &[f64]) -> Result<i64, ClosedFunctionError> {
    let n = xs.len();
    // Validate monotonicity + NaN-in-table once per call (matches Julia).
    let mut prev = f64::NAN;
    for (i, v) in xs.iter().copied().enumerate() {
        if v.is_nan() {
            return Err(ClosedFunctionError::new(
                "searchsorted_nan_in_table",
                format!(
                    "{name}: xs[{idx}] is NaN; NaN entries in xs are forbidden",
                    idx = i + 1
                ),
            ));
        }
        if i > 0 && v < prev {
            return Err(ClosedFunctionError::new(
                "searchsorted_non_monotonic",
                format!(
                    "{name}: xs is not non-decreasing (xs[{idx}]={v} < xs[{prev_idx}]={prev})",
                    idx = i + 1,
                    prev_idx = i,
                ),
            ));
        }
        prev = v;
    }
    // Empty table: degenerate "above-range → N+1" with N=0 returns 1.
    if n == 0 {
        return Ok(1);
    }
    if x.is_nan() {
        return Ok((n as i64) + 1);
    }
    for (i, v) in xs.iter().copied().enumerate() {
        if v >= x {
            return Ok((i as i64) + 1);
        }
    }
    Ok((n as i64) + 1)
}

// `interp.linear` per esm-spec §9.2: 1-D linear interpolation with
// extrapolate-flat clamping. Load-time validation diagnostics:
// `interp_axis_too_short`, `interp_axis_length_mismatch`,
// `interp_nan_in_axis`, `interp_non_monotonic_axis`. Evaluation uses the
// pinned form `result = t[i] + w * (t[i+1] - t[i])` so endpoints are
// recovered exactly under IEEE-754 round-to-nearest.
fn interp_linear(table: &[f64], axis: &[f64], x: f64) -> Result<f64, ClosedFunctionError> {
    validate_axis("interp.linear", "axis", axis)?;
    if table.len() != axis.len() {
        return Err(ClosedFunctionError::new(
            "interp_axis_length_mismatch",
            format!(
                "interp.linear: len(table)={} != len(axis)={}",
                table.len(),
                axis.len()
            ),
        ));
    }
    let n = axis.len();
    if x <= axis[0] {
        return Ok(table[0]);
    }
    if x >= axis[n - 1] {
        return Ok(table[n - 1]);
    }
    // Strict monotonicity + the in-range tests above guarantee that some
    // interior cell exists. NaN x falls through both clamps (IEEE-754 ≤ /
    // ≥ are false on NaN) into the blend, where it propagates via `w`.
    let mut i = 0usize;
    if x.is_nan() {
        // NaN must propagate, not produce a misleading "no cell found"
        // error; pick any cell, the blend will yield NaN anyway.
        i = 0;
    } else {
        for k in 0..(n - 1) {
            if axis[k] <= x && x < axis[k + 1] {
                i = k;
                break;
            }
        }
    }
    let w = (x - axis[i]) / (axis[i + 1] - axis[i]);
    Ok(table[i] + w * (table[i + 1] - table[i]))
}

// `interp.bilinear` per esm-spec §9.2: 2-D linear interpolation,
// row-major (`table[i][j]` lives at `(axis_x[i], axis_y[j])`), with
// per-axis extrapolate-flat clamping. Pinned evaluation order is two
// 1-D x-blends followed by one 1-D y-blend, each in the form
// `a + w * (b - a)`; the clamp-then-cell-locate sequence guarantees a
// unique cell in `[1, Nx-1] × [1, Ny-1]`.
fn interp_bilinear(
    table: &[Vec<f64>],
    axis_x: &[f64],
    axis_y: &[f64],
    x: f64,
    y: f64,
) -> Result<f64, ClosedFunctionError> {
    validate_axis("interp.bilinear", "axis_x", axis_x)?;
    validate_axis("interp.bilinear", "axis_y", axis_y)?;
    if table.len() != axis_x.len() {
        return Err(ClosedFunctionError::new(
            "interp_axis_length_mismatch",
            format!(
                "interp.bilinear: outer len(table)={} != len(axis_x)={}",
                table.len(),
                axis_x.len()
            ),
        ));
    }
    let ny = axis_y.len();
    for (i, row) in table.iter().enumerate() {
        if row.len() != ny {
            return Err(ClosedFunctionError::new(
                "interp_axis_length_mismatch",
                format!(
                    "interp.bilinear: table row {row_idx} has len={got} but len(axis_y)={ny}",
                    row_idx = i + 1,
                    got = row.len(),
                ),
            ));
        }
    }
    let nx = axis_x.len();
    // Per-axis clamp (extrapolate-flat). NaN falls through both branches
    // because `<=` / `>=` are false for NaN — the resulting NaN
    // propagates via the weight into the final blend.
    let x_q = if x <= axis_x[0] {
        axis_x[0]
    } else if x >= axis_x[nx - 1] {
        axis_x[nx - 1]
    } else {
        x
    };
    let y_q = if y <= axis_y[0] {
        axis_y[0]
    } else if y >= axis_y[ny - 1] {
        axis_y[ny - 1]
    } else {
        y
    };
    // Cell location: largest i in [0, nx-2] (0-based) with axis_x[i] <=
    // x_q. The clamp puts x_q in [axis_x[0], axis_x[nx-1]], so the
    // search is well-defined whenever x is finite. NaN x produces NaN
    // x_q; the comparisons all return false, so we fall back to cell 0
    // and let the NaN weight propagate.
    let i = locate_cell(axis_x, x_q);
    let j = locate_cell(axis_y, y_q);
    let wx = (x_q - axis_x[i]) / (axis_x[i + 1] - axis_x[i]);
    let wy = (y_q - axis_y[j]) / (axis_y[j + 1] - axis_y[j]);
    let row_j = table[i][j] + wx * (table[i + 1][j] - table[i][j]);
    let row_jp1 = table[i][j + 1] + wx * (table[i + 1][j + 1] - table[i][j + 1]);
    Ok(row_j + wy * (row_jp1 - row_j))
}

// Largest 0-based index `i` in `[0, axis.len() - 2]` with `axis[i] <=
// q`. Falls back to 0 when no such index exists (only possible for NaN
// q after clamping, where the comparisons are all false; the blend
// then propagates NaN regardless of which cell we pick).
fn locate_cell(axis: &[f64], q: f64) -> usize {
    let last = axis.len() - 2;
    let mut i = 0usize;
    for (k, v) in axis.iter().take(last + 1).enumerate() {
        if *v <= q {
            i = k;
        } else {
            break;
        }
    }
    i
}

// Shared axis-validation helper for `interp.linear` and
// `interp.bilinear`. Diagnoses (in order of precedence): too-short,
// NaN-in-axis, non-monotonic. Strict monotonicity (`<`, not `≤`) is
// required because equal-adjacent entries would zero the blend
// denominator — `interp.searchsorted` permits non-decreasing because it
// returns an index, not a blend.
fn validate_axis(fn_name: &str, label: &str, axis: &[f64]) -> Result<(), ClosedFunctionError> {
    if axis.len() < 2 {
        return Err(ClosedFunctionError::new(
            "interp_axis_too_short",
            format!(
                "{fn_name}: {label} has {len} entries; need at least 2 (no interval to blend across)",
                len = axis.len()
            ),
        ));
    }
    for (i, v) in axis.iter().copied().enumerate() {
        if v.is_nan() {
            return Err(ClosedFunctionError::new(
                "interp_nan_in_axis",
                format!(
                    "{fn_name}: {label}[{idx}] is NaN; NaN entries in axes are forbidden",
                    idx = i + 1
                ),
            ));
        }
    }
    // NaN was filtered above, so `>=` here is well-defined and detects
    // both equal-adjacent and decreasing pairs (the strict-monotonicity
    // requirement that distinguishes interp.linear/bilinear from
    // searchsorted's non-decreasing rule).
    for w in axis.windows(2) {
        if w[0] >= w[1] {
            return Err(ClosedFunctionError::new(
                "interp_non_monotonic_axis",
                format!(
                    "{fn_name}: {label} is not strictly increasing (encountered {a} then {b})",
                    a = w[0],
                    b = w[1]
                ),
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: f64) -> ClosedArg {
        ClosedArg::Scalar(v)
    }
    fn a(vs: &[f64]) -> ClosedArg {
        ClosedArg::Array(vs.to_vec())
    }
    fn a2(rows: &[&[f64]]) -> ClosedArg {
        ClosedArg::Array2D(rows.iter().map(|r| r.to_vec()).collect())
    }

    #[test]
    fn unknown_name_diagnostic() {
        let err = evaluate_closed_function("datetime.century", &[s(0.0)]).unwrap_err();
        assert_eq!(err.code, "unknown_closed_function");
    }

    #[test]
    fn closed_function_names_v030() {
        let names = closed_function_names();
        assert_eq!(names.len(), 12);
        for n in [
            "datetime.year",
            "datetime.month",
            "datetime.day",
            "datetime.hour",
            "datetime.minute",
            "datetime.second",
            "datetime.day_of_year",
            "datetime.julian_day",
            "datetime.is_leap_year",
            "interp.searchsorted",
            "interp.linear",
            "interp.bilinear",
        ] {
            assert!(names.contains(n), "missing {n}");
        }
    }

    #[test]
    fn epoch_year() {
        let v = evaluate_closed_function("datetime.year", &[s(0.0)]).unwrap();
        assert_eq!(v, ClosedValue::Integer(1970));
    }

    #[test]
    fn pre_epoch_year() {
        // -1 second is 1969-12-31T23:59:59 UTC.
        let v = evaluate_closed_function("datetime.year", &[s(-1.0)]).unwrap();
        assert_eq!(v, ClosedValue::Integer(1969));
    }

    #[test]
    fn leap_year_2000() {
        // 2000-02-29T12:00:00 UTC = 951825600 s.
        let v = evaluate_closed_function("datetime.is_leap_year", &[s(951825600.0)]).unwrap();
        assert_eq!(v, ClosedValue::Integer(1));
    }

    #[test]
    fn not_leap_2100() {
        // 2100-02-28T23:59:59 UTC.
        let v = evaluate_closed_function("datetime.is_leap_year", &[s(4107542399.0)]).unwrap();
        assert_eq!(v, ClosedValue::Integer(0));
    }

    #[test]
    fn day_of_year_leap_dec31() {
        // 2024-12-31 — day 366 in a leap year.
        let v = evaluate_closed_function("datetime.day_of_year", &[s(1735689599.0)]).unwrap();
        assert_eq!(v, ClosedValue::Integer(366));
    }

    #[test]
    fn searchsorted_exact_boundary() {
        let v = evaluate_closed_function(
            "interp.searchsorted",
            &[s(2.0), a(&[1.0, 2.0, 3.0, 4.0, 5.0])],
        )
        .unwrap();
        assert_eq!(v, ClosedValue::Integer(2));
    }

    #[test]
    fn searchsorted_above_range() {
        let v = evaluate_closed_function(
            "interp.searchsorted",
            &[s(10.0), a(&[1.0, 2.0, 3.0, 4.0, 5.0])],
        )
        .unwrap();
        assert_eq!(v, ClosedValue::Integer(6));
    }

    #[test]
    fn searchsorted_nan_x() {
        let v = evaluate_closed_function(
            "interp.searchsorted",
            &[s(f64::NAN), a(&[1.0, 2.0, 3.0, 4.0, 5.0])],
        )
        .unwrap();
        assert_eq!(v, ClosedValue::Integer(6));
    }

    #[test]
    fn searchsorted_non_monotonic_rejects() {
        let err = evaluate_closed_function(
            "interp.searchsorted",
            &[s(2.0), a(&[1.0, 3.0, 2.0, 4.0, 5.0])],
        )
        .unwrap_err();
        assert_eq!(err.code, "searchsorted_non_monotonic");
    }

    #[test]
    fn searchsorted_nan_in_xs_rejects() {
        let err =
            evaluate_closed_function("interp.searchsorted", &[s(2.0), a(&[1.0, f64::NAN, 3.0])])
                .unwrap_err();
        assert_eq!(err.code, "searchsorted_nan_in_table");
    }

    #[test]
    fn searchsorted_duplicates_left_bias() {
        let v = evaluate_closed_function(
            "interp.searchsorted",
            &[s(2.0), a(&[1.0, 2.0, 2.0, 2.0, 3.0])],
        )
        .unwrap();
        assert_eq!(v, ClosedValue::Integer(2));
    }

    #[test]
    fn interp_linear_exact_at_knot() {
        let v = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 40.0, 80.0, 160.0]),
                a(&[0.0, 1.0, 2.0, 3.0, 4.0]),
                s(2.0),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 40.0);
    }

    #[test]
    fn interp_linear_midpoint_blend() {
        let v = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 40.0, 80.0, 160.0]),
                a(&[0.0, 1.0, 2.0, 3.0, 4.0]),
                s(0.5),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 15.0);
    }

    #[test]
    fn interp_linear_below_clamps() {
        let v = evaluate_closed_function(
            "interp.linear",
            &[a(&[3.0, 7.0]), a(&[10.0, 20.0]), s(-100.0)],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 3.0);
    }

    #[test]
    fn interp_linear_above_clamps_exact_endpoint() {
        // Pinned form `t[i] + w*(t[i+1]-t[i])` recovers the endpoint
        // exactly under round-to-nearest when w = 1.
        let v = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 40.0, 80.0, 160.0]),
                a(&[0.0, 1.0, 2.0, 3.0, 4.0]),
                s(99.0),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 160.0);
    }

    #[test]
    fn interp_linear_nan_propagates() {
        let v = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 40.0, 80.0, 160.0]),
                a(&[0.0, 1.0, 2.0, 3.0, 4.0]),
                s(f64::NAN),
            ],
        )
        .unwrap();
        assert!(v.as_f64().is_nan());
    }

    #[test]
    fn interp_linear_non_monotonic_rejects() {
        let err = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 30.0, 40.0]),
                a(&[0.0, 2.0, 1.0, 3.0]),
                s(1.5),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_non_monotonic_axis");
    }

    #[test]
    fn interp_linear_equal_adjacent_rejects() {
        let err = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 30.0, 40.0]),
                a(&[0.0, 1.0, 1.0, 2.0]),
                s(0.5),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_non_monotonic_axis");
    }

    #[test]
    fn interp_linear_length_mismatch_rejects() {
        let err = evaluate_closed_function(
            "interp.linear",
            &[a(&[10.0, 20.0, 30.0, 40.0]), a(&[0.0, 1.0, 2.0]), s(1.0)],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_axis_length_mismatch");
    }

    #[test]
    fn interp_linear_nan_in_axis_rejects() {
        let err = evaluate_closed_function(
            "interp.linear",
            &[
                a(&[10.0, 20.0, 30.0, 40.0]),
                a(&[0.0, f64::NAN, 2.0, 3.0]),
                s(1.0),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_nan_in_axis");
    }

    #[test]
    fn interp_linear_axis_too_short_rejects() {
        let err = evaluate_closed_function("interp.linear", &[a(&[42.0]), a(&[0.0]), s(0.0)])
            .unwrap_err();
        assert_eq!(err.code, "interp_axis_too_short");
    }

    #[test]
    fn interp_bilinear_exact_corner() {
        let v = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0, 2.0]),
                a(&[0.0, 10.0, 20.0]),
                s(2.0),
                s(20.0),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 22.0);
    }

    #[test]
    fn interp_bilinear_center_blend() {
        let v = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0, 2.0]),
                a(&[0.0, 10.0, 20.0]),
                s(0.5),
                s(5.0),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 5.5);
    }

    #[test]
    fn interp_bilinear_clamps_to_corner() {
        let v = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0, 2.0]),
                a(&[0.0, 10.0, 20.0]),
                s(1000.0),
                s(1000.0),
            ],
        )
        .unwrap();
        assert_eq!(v.as_f64(), 22.0);
    }

    #[test]
    fn interp_bilinear_nan_x_propagates() {
        let v = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0, 2.0]),
                a(&[0.0, 10.0, 20.0]),
                s(f64::NAN),
                s(5.0),
            ],
        )
        .unwrap();
        assert!(v.as_f64().is_nan());
    }

    #[test]
    fn interp_bilinear_ragged_rows_reject() {
        let err = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0, 2.0]),
                a(&[0.0, 10.0, 20.0]),
                s(0.5),
                s(5.0),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_axis_length_mismatch");
    }

    #[test]
    fn interp_bilinear_axis_x_length_mismatch_rejects() {
        let err = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 1.0]),
                a(&[0.0, 10.0, 20.0]),
                s(0.5),
                s(5.0),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_axis_length_mismatch");
    }

    #[test]
    fn interp_bilinear_non_monotonic_axis_rejects() {
        let err = evaluate_closed_function(
            "interp.bilinear",
            &[
                a2(&[&[0.0, 1.0, 2.0], &[10.0, 11.0, 12.0], &[20.0, 21.0, 22.0]]),
                a(&[0.0, 2.0, 1.0]),
                a(&[0.0, 10.0, 20.0]),
                s(0.5),
                s(5.0),
            ],
        )
        .unwrap_err();
        assert_eq!(err.code, "interp_non_monotonic_axis");
    }
}
