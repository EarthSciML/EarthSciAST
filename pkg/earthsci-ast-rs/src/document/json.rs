//! JSON values of an ESM document, in canonical form.
//!
//! Port of `formal/Esm/Document/Json.lean`. The document codecs and the math
//! layer work on this value type, not on `serde_json::Value`: numbers are kept
//! in the canonical form of CONFORMANCE §5.5.3.1 (an integral value that fits in
//! `Int64` IS an integer; every other finite number is its shortest round-trip
//! decimal digits and the decimal exponent of the first digit), and object
//! entries keep their order. [`from_serde`] and [`to_serde`] convert at the
//! public boundary.

use crate::canonicalize::shortest_digits;

/// A JSON number in canonical form (`Esm.Document.JNum`).
///
/// * `Int(z)`: an integer literal (well formed when `z` fits in `i64`).
/// * `Dec { neg, digits, e10 }`: the value `±d₁.d₂d₃… × 10^e10`, with `digits`
///   the shortest round-trip digits (each below 10).
///
/// Lean's `Int` is unbounded; `i128` holds every value the readers produce
/// before the `Int64` check rejects it (see `number::parse_nat`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum JNum {
    Int(i128),
    Dec {
        neg: bool,
        digits: Vec<u8>,
        e10: i64,
    },
}

/// `JNum.InInt64`.
pub fn in_int64(z: i128) -> bool {
    (i64::MIN as i128) <= z && z <= (i64::MAX as i128)
}

/// `JNum.digitsVal`: the value of a big-endian digit list (`None` on overflow).
pub fn digits_val(ds: &[u8]) -> Option<i128> {
    let mut a: i128 = 0;
    for &d in ds {
        a = a.checked_mul(10)?.checked_add(d as i128)?;
    }
    Some(a)
}

/// `JNum.decInt?`: the integer a decimal denotes, when it is integral.
///
/// The outer `Option` is Lean's: `None` when the decimal is not integral. The
/// inner one is `None` when the integer does not fit in `i128` (so certainly
/// not in `Int64`).
pub fn dec_int(neg: bool, ds: &[u8], e10: i64) -> Option<Option<i128>> {
    let len = ds.len() as i64;
    if len <= e10 + 1 {
        let zeros = (e10 + 1 - len) as u32;
        let m =
            digits_val(ds).and_then(|v| 10i128.checked_pow(zeros).and_then(|p| v.checked_mul(p)));
        Some(m.map(|m| if neg { -m } else { m }))
    } else {
        None
    }
}

impl JNum {
    /// `JNum.wfb`: the number is in canonical form.
    pub fn wfb(&self) -> bool {
        match self {
            JNum::Int(z) => in_int64(*z),
            JNum::Dec { neg, digits, e10 } => {
                !digits.is_empty()
                    && digits.iter().all(|&d| d < 10)
                    && digits.first() != Some(&0)
                    && digits.last() != Some(&0)
                    && match dec_int(*neg, digits, *e10) {
                        Some(Some(z)) => !in_int64(z),
                        Some(None) => true,
                        None => true,
                    }
            }
        }
    }
}

/// A JSON value (`Esm.Document.Json`). Object entries keep their order.
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(JNum),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    /// `Json.wfb`: every number canonical, every object with distinct keys.
    pub fn wfb(&self) -> bool {
        match self {
            Json::Num(n) => n.wfb(),
            Json::Arr(xs) => xs.iter().all(Json::wfb),
            Json::Obj(kvs) => keys_distinct(kvs) && kvs.iter().all(|(_, v)| v.wfb()),
            _ => true,
        }
    }

    /// Shorthand for `Json::Str`.
    pub fn str(s: impl Into<String>) -> Json {
        Json::Str(s.into())
    }

    /// Shorthand for an integer `Json::Num`.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn int(z: i128) -> Json {
        Json::Num(JNum::Int(z))
    }
}

/// The keys of an entry list are pairwise distinct (`List.Nodup` on the keys).
pub fn keys_distinct(kvs: &[(String, Json)]) -> bool {
    let mut seen = std::collections::HashSet::new();
    kvs.iter().all(|(k, _)| seen.insert(k.as_str()))
}

/// The canonical number of a finite `f64` (§5.5.3.1): an integral value in
/// `Int64` is the integer, any other value its shortest round-trip digits.
pub fn jnum_of_f64(f: f64) -> Option<JNum> {
    if !f.is_finite() {
        return None;
    }
    if f == 0.0 {
        return Some(JNum::Int(0));
    }
    if f.fract() == 0.0 && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&f)
    {
        return Some(JNum::Int(f as i64 as i128));
    }
    let d = shortest_digits(f);
    let digits: Vec<u8> = d.as_str().bytes().map(|b| b - b'0').collect();
    Some(JNum::Dec {
        neg: f < 0.0,
        digits,
        e10: d.exp as i64,
    })
}

/// A `serde_json` number as a canonical number.
pub fn jnum_of_serde(n: &serde_json::Number) -> Option<JNum> {
    if let Some(i) = n.as_i64() {
        return Some(JNum::Int(i as i128));
    }
    if let Some(u) = n.as_u64() {
        // above i64::MAX: an integral decimal outside Int64
        let mut digits: Vec<u8> = u.to_string().bytes().map(|b| b - b'0').collect();
        let e10 = digits.len() as i64 - 1;
        while digits.last() == Some(&0) {
            digits.pop();
        }
        return Some(JNum::Dec {
            neg: false,
            digits,
            e10,
        });
    }
    jnum_of_f64(n.as_f64()?)
}

/// A canonical number as a `serde_json` number.
pub fn jnum_to_serde(n: &JNum) -> serde_json::Number {
    match n {
        JNum::Int(z) => {
            if let Ok(i) = i64::try_from(*z) {
                serde_json::Number::from(i)
            } else if let Ok(u) = u64::try_from(*z) {
                serde_json::Number::from(u)
            } else {
                serde_json::Number::from_f64(*z as f64).expect("finite")
            }
        }
        JNum::Dec { .. } => {
            // The value `serde_json` reads from the canonical spelling, which
            // always has a decimal point: a float, even for an integral decimal
            // outside `Int64` (`1.0e19`).
            let text: String = super::number::print(n).into_iter().collect();
            let f: f64 = text.parse().expect("a printed number parses");
            serde_json::Number::from_f64(f).unwrap_or_else(|| serde_json::Number::from(0))
        }
    }
}

/// A `serde_json` value as a document value (`None` for a non-finite number,
/// which `serde_json` cannot hold anyway).
pub fn from_serde(v: &serde_json::Value) -> Json {
    match v {
        serde_json::Value::Null => Json::Null,
        serde_json::Value::Bool(b) => Json::Bool(*b),
        serde_json::Value::Number(n) => match jnum_of_serde(n) {
            Some(j) => Json::Num(j),
            None => Json::Null,
        },
        serde_json::Value::String(s) => Json::Str(s.clone()),
        serde_json::Value::Array(xs) => Json::Arr(xs.iter().map(from_serde).collect()),
        serde_json::Value::Object(m) => {
            Json::Obj(m.iter().map(|(k, v)| (k.clone(), from_serde(v))).collect())
        }
    }
}

/// A document value as a `serde_json` value (entry order kept).
pub fn to_serde(j: &Json) -> serde_json::Value {
    match j {
        Json::Null => serde_json::Value::Null,
        Json::Bool(b) => serde_json::Value::Bool(*b),
        Json::Num(n) => serde_json::Value::Number(jnum_to_serde(n)),
        Json::Str(s) => serde_json::Value::String(s.clone()),
        Json::Arr(xs) => serde_json::Value::Array(xs.iter().map(to_serde).collect()),
        Json::Obj(kvs) => {
            let mut m = serde_json::Map::new();
            for (k, v) in kvs {
                m.insert(k.clone(), to_serde(v));
            }
            serde_json::Value::Object(m)
        }
    }
}

/// The value with every object's entries sorted by key (code point order), the
/// key order of the canonical serialization.
pub fn sort_keys(j: &Json) -> Json {
    match j {
        Json::Arr(xs) => Json::Arr(xs.iter().map(sort_keys).collect()),
        Json::Obj(kvs) => {
            let mut kvs: Vec<(String, Json)> =
                kvs.iter().map(|(k, v)| (k.clone(), sort_keys(v))).collect();
            kvs.sort_by(|a, b| a.0.cmp(&b.0));
            Json::Obj(kvs)
        }
        _ => j.clone(),
    }
}

/// Compact canonical JSON text (`Adapter.Doc.render`), as `esm-lean` prints a
/// parsed document; used by the tests: entries in their order,
/// canonical numbers, strings quoted with `\uXXXX` escapes.
#[cfg_attr(not(test), allow(dead_code))]
pub fn render(j: &Json) -> String {
    let mut out = String::new();
    render_into(j, &mut out);
    out
}

fn render_into(j: &Json, out: &mut String) {
    match j {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Num(n) => out.extend(super::number::print(n)),
        Json::Str(s) => out.extend(super::strings::quote(false, s)),
        Json::Arr(xs) => {
            out.push('[');
            for (i, x) in xs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                render_into(x, out);
            }
            out.push(']');
        }
        Json::Obj(kvs) => {
            out.push('{');
            for (i, (k, v)) in kvs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.extend(super::strings::quote(false, k));
                out.push(':');
                render_into(v, out);
            }
            out.push('}');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_convert_canonically() {
        let n: serde_json::Value = serde_json::from_str("[1.0, 2.5, 1e-9, 1e300, -3]").unwrap();
        let j = from_serde(&n);
        assert_eq!(render(&j), "[1,2.5,1.0e-9,1.0e300,-3]");
        assert_eq!(to_serde(&j), serde_json::json!([1, 2.5, 1e-9, 1e300, -3]));
    }
}
