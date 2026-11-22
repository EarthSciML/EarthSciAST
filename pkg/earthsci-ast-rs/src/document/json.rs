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
    // In `i128`, where `e10 + 1 - len` cannot overflow for any `i64` exponent
    // and any digit list that fits in memory.
    let zeros = i128::from(e10) + 1 - ds.len() as i128;
    if zeros < 0 {
        return None;
    }
    let m = digits_val(ds).and_then(|v| {
        if v == 0 {
            return Some(0);
        }
        // `10^zeros` overflows `i128` well before `zeros` leaves `u32`.
        let p = 10i128.checked_pow(u32::try_from(zeros).ok()?)?;
        v.checked_mul(p)
    });
    Some(m.map(|m| if neg { -m } else { m }))
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
///
/// `Math(s)` is not JSON: it is the math text of an expression inside a path
/// block, the form a container prints and reads there (`Source.mathify`,
/// `Source.cookBlocks`). It lives only between a container's text and the
/// skeleton; a document never holds one ([`Json::wfb`] is false on it).
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(JNum),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
    Math(String),
}

/// `Json.mathOK`: math text a container can delimit with `$`: not empty, no
/// `$`, no line break, and not ending in a backslash (which would escape the
/// closing `$`).
pub fn math_ok(s: &str) -> bool {
    !s.is_empty()
        && !s.contains('$')
        && !s.contains('\n')
        && !s.contains('\r')
        && !s.ends_with('\\')
}

/// `Json.pMath`: a math leaf after its `$`: the text up to the next `$`, which
/// must be [`math_ok`].
pub fn p_math(r: &[char]) -> Option<(Json, &[char])> {
    let j = r.iter().position(|&c| c == '$')?;
    let t: String = r[..j].iter().collect();
    if math_ok(&t) {
        Some((Json::Math(t), &r[j + 1..]))
    } else {
        None
    }
}

impl Json {
    /// `Json.wfb`: every number canonical, every object with distinct keys, and
    /// no math leaf. (The readers check [`Json::wfmb`]; the final canonical
    /// check is `Math.jwf`.)
    #[allow(dead_code)]
    pub fn wfb(&self) -> bool {
        match self {
            Json::Num(n) => n.wfb(),
            Json::Arr(xs) => xs.iter().all(Json::wfb),
            Json::Obj(kvs) => keys_distinct(kvs) && kvs.iter().all(|(_, v)| v.wfb()),
            Json::Math(_) => false,
            _ => true,
        }
    }

    /// `Json.wfmb`: [`Json::wfb`], with math leaves of [`math_ok`] text allowed
    /// (what the codecs print and read).
    pub fn wfmb(&self) -> bool {
        match self {
            Json::Num(n) => n.wfb(),
            Json::Arr(xs) => xs.iter().all(Json::wfmb),
            Json::Obj(kvs) => keys_distinct(kvs) && kvs.iter().all(|(_, v)| v.wfmb()),
            Json::Math(s) => math_ok(s),
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

/// A canonical number as a `serde_json` number: the binary64 value nearest to
/// it, as `serde_json` reads its spelling.
///
/// `None` for a decimal beyond the binary64 range (`1.0e400`), which has no
/// nearest finite binary64 value; `serde_json` refuses that literal in a JSON
/// document too. A nonzero decimal below the smallest subnormal (`1.0e-400`)
/// rounds to zero, as every binding's JSON reader rounds it, and is the
/// canonical zero, the integer `0`, as `canonicalize_document` makes a JSON
/// `1e-400`.
pub fn jnum_to_serde(n: &JNum) -> Option<serde_json::Number> {
    match n {
        JNum::Int(z) => Some(if let Ok(i) = i64::try_from(*z) {
            serde_json::Number::from(i)
        } else if let Ok(u) = u64::try_from(*z) {
            serde_json::Number::from(u)
        } else {
            // Finite: every `i128` is far inside the binary64 range.
            serde_json::Number::from_f64(*z as f64)?
        }),
        JNum::Dec { .. } => {
            // The value `serde_json` reads from the canonical spelling, which
            // always has a decimal point: a float, even for an integral decimal
            // outside `Int64` (`1.0e19`).
            let text: String = super::number::print(n).into_iter().collect();
            let f: f64 = text.parse().ok()?;
            if f == 0.0 {
                Some(serde_json::Number::from(0))
            } else {
                serde_json::Number::from_f64(f)
            }
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
///
/// # Errors
///
/// The first number with no `serde_json` value ([`jnum_to_serde`]).
pub fn to_serde(j: &Json) -> Result<serde_json::Value, JNum> {
    Ok(match j {
        Json::Null => serde_json::Value::Null,
        Json::Bool(b) => serde_json::Value::Bool(*b),
        Json::Num(n) => serde_json::Value::Number(jnum_to_serde(n).ok_or_else(|| n.clone())?),
        Json::Str(s) => serde_json::Value::String(s.clone()),
        // Never reached: a document read back holds no math leaf (`Json.WF`).
        Json::Math(s) => serde_json::Value::String(s.clone()),
        Json::Arr(xs) => {
            serde_json::Value::Array(xs.iter().map(to_serde).collect::<Result<_, _>>()?)
        }
        Json::Obj(kvs) => {
            let mut m = serde_json::Map::new();
            for (k, v) in kvs {
                m.insert(k.clone(), to_serde(v)?);
            }
            serde_json::Value::Object(m)
        }
    })
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
        // Never reached: a document read back holds no math leaf
        // (`Adapter.Doc.render`).
        Json::Str(s) | Json::Math(s) => out.extend(super::strings::quote(false, s)),
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
        assert_eq!(
            to_serde(&j).unwrap(),
            serde_json::json!([1, 2.5, 1e-9, 1e300, -3])
        );
    }

    fn dec(digits: &[u8], e10: i64) -> JNum {
        JNum::Dec {
            neg: false,
            digits: digits.to_vec(),
            e10,
        }
    }

    #[test]
    fn a_decimal_beyond_binary64_has_no_serde_value() {
        assert_eq!(jnum_to_serde(&dec(&[1], 400)), None);
        assert_eq!(
            to_serde(&Json::Arr(vec![Json::Num(dec(&[1], 400))])),
            Err(dec(&[1], 400))
        );
        // Below the smallest subnormal: the canonical zero.
        assert_eq!(
            jnum_to_serde(&dec(&[1], -400)),
            Some(serde_json::Number::from(0))
        );
        assert_eq!(
            jnum_to_serde(&dec(&[1, 7, 9], 308)),
            serde_json::Number::from_f64(1.79e308)
        );
    }

    #[test]
    fn dec_int_never_wraps_the_exponent() {
        assert_eq!(dec_int(false, &[1], 2), Some(Some(100)));
        assert_eq!(dec_int(false, &[1, 5], 0), None);
        // `10^(2^32)` is no `i128`; a wrapped `u32` would make it `10^0`.
        assert_eq!(dec_int(false, &[1], 4_294_967_296), Some(None));
        assert_eq!(dec_int(false, &[1], i64::MAX), Some(None));
        assert_eq!(dec_int(true, &[1], i64::MIN), None);
    }
}
