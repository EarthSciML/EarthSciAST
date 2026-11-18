//! The payload of a `const` node: [`ConstValue`].

use std::borrow::Cow;
use std::sync::{Arc, OnceLock};

use ndarray::{ArrayD, IxDyn};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// The inline literal a `const` node carries (`ExpressionNode::value`).
///
/// A rectangular array of numbers is held DENSE: a row-major `f64` array with
/// its shape, plus which of its numbers the document spelled as integers and
/// which as floats ([`Spelling`]). Every other literal — a number, a string,
/// an object (a `bc` value), an empty or ragged array, or an array with an
/// integer `f64` cannot hold exactly — is held as the JSON it was written as.
///
/// The payload is behind an [`Arc`], so cloning a node shares it, and it
/// carries its own evaluation-ready array: the first evaluation under a given
/// working precision materializes it once, and every later read (from any
/// clone) is served from there.
///
/// Both forms serialize to the JSON they were read from, in canonical-number
/// form (esm-spec §5.5.3.1): a dense payload writes exactly the nested array
/// its numbers came from.
#[derive(Clone)]
pub struct ConstValue(Arc<Payload>);

struct Payload {
    form: Form,
    /// The binary64 array of a [`Form::Json`] literal, built on first read.
    /// `None` inside for a literal with no array reading.
    json_f64: OnceLock<Option<Arc<ArrayD<f64>>>>,
    /// The binary32-rounded array, built on first read under Float32.
    f32: OnceLock<Option<Arc<ArrayD<f64>>>>,
}

enum Form {
    Json(Value),
    Dense {
        data: Arc<ArrayD<f64>>,
        spelling: Spelling,
    },
}

/// Which elements of a dense array the document spelled as integers (`1`)
/// and which as floats (`1.0`). The canonical form keeps the two apart
/// (`canonical_json` writes `1` and `1.0`), and so does interning.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Spelling {
    /// Every element a float: `[1.0, 2.5]`.
    Floats,
    /// Every element an integer: `[1, 2]`.
    Integers,
    /// Both: bit `k % 64` of word `k / 64` is set when row-major element
    /// `k` is an integer (`[1, 2.5]`).
    Mixed(Box<[u64]>),
}

impl Spelling {
    /// Whether row-major element `k` is spelled as an integer.
    fn is_integer(&self, k: usize) -> bool {
        match self {
            Spelling::Floats => false,
            Spelling::Integers => true,
            Spelling::Mixed(bits) => bits[k / 64] >> (k % 64) & 1 == 1,
        }
    }
}

/// The largest magnitude an integer element may have and still be held
/// dense: every integer up to 2^53 is exact in `f64`.
const EXACT_INT: u64 = 1 << 53;

impl ConstValue {
    fn new(form: Form) -> Self {
        ConstValue(Arc::new(Payload {
            form,
            json_f64: OnceLock::new(),
            f32: OnceLock::new(),
        }))
    }

    /// A literal from its JSON. A rectangular numeric array of rank one or
    /// more, with no empty extent, whose integer elements are within ±2^53,
    /// is held dense; anything else as the JSON.
    pub fn from_json(value: Value) -> Self {
        match dense_of(&value) {
            Some((data, spelling)) => ConstValue::new(Form::Dense {
                data: Arc::new(data),
                spelling,
            }),
            None => ConstValue::new(Form::Json(value)),
        }
    }

    /// A float array literal from row-major `values` of `shape`, written as
    /// the nested JSON array of floats it denotes.
    ///
    /// Data that nested JSON cannot spell as that array — rank zero, an empty
    /// extent, or a non-finite value (written `null`) — is held as the JSON
    /// it writes, so it reads back exactly as that JSON does.
    ///
    /// # Panics
    ///
    /// When `values.len()` is not the product of `shape`.
    pub fn from_dense(shape: &[usize], values: Vec<f64>) -> Self {
        assert_eq!(
            values.len(),
            shape.iter().product::<usize>(),
            "const payload: {} values for shape {shape:?}",
            values.len()
        );
        if shape.is_empty() || shape.contains(&0) || values.iter().any(|v| !v.is_finite()) {
            return ConstValue::new(Form::Json(nest(shape, &values, 0, &Spelling::Floats)));
        }
        let data = ArrayD::from_shape_vec(IxDyn(shape), values).expect("shape checked above");
        ConstValue::new(Form::Dense {
            data: Arc::new(data),
            spelling: Spelling::Floats,
        })
    }

    /// The literal as JSON: borrowed for a JSON payload, built for a dense
    /// one (each element an integer or a float, as the document spelled it).
    pub fn to_json(&self) -> Cow<'_, Value> {
        match &self.0.form {
            Form::Json(v) => Cow::Borrowed(v),
            Form::Dense { data, spelling } => Cow::Owned(nest(
                data.shape(),
                data.as_slice().expect("dense payloads are standard layout"),
                0,
                spelling,
            )),
        }
    }

    /// The JSON of a payload held as JSON; `None` for a dense array. A
    /// reader of a scalar, a string or an object literal reads it here.
    pub fn as_json(&self) -> Option<&Value> {
        match &self.0.form {
            Form::Json(v) => Some(v),
            Form::Dense { .. } => None,
        }
    }

    /// The dense binary64 array, when the payload is held dense.
    pub fn as_dense(&self) -> Option<&Arc<ArrayD<f64>>> {
        match &self.0.form {
            Form::Dense { data, .. } => Some(data),
            Form::Json(_) => None,
        }
    }

    /// Whether the literal is a single JSON number.
    pub fn is_number(&self) -> bool {
        self.as_json().is_some_and(Value::is_number)
    }

    /// The literal as one number, when it is one.
    pub fn as_f64(&self) -> Option<f64> {
        self.as_json().and_then(Value::as_f64)
    }

    /// Whether the literal is an array (dense, or a JSON array of any kind).
    pub fn is_array(&self) -> bool {
        match &self.0.form {
            Form::Dense { .. } => true,
            Form::Json(v) => v.is_array(),
        }
    }

    /// Whether two handles share one payload.
    pub fn ptr_eq(a: &ConstValue, b: &ConstValue) -> bool {
        Arc::ptr_eq(&a.0, &b.0)
    }

    /// The array this literal evaluates to under the working precision in
    /// force ([`crate::precision::active`]), materialized once per precision
    /// and shared after that. A float literal rounds on ingress (esm-spec
    /// §11.3.1), so the binary32 reading is a different array.
    ///
    /// `None` for a literal with no array reading: a scalar, a non-numeric
    /// or ragged array.
    pub(crate) fn array(&self) -> Option<Arc<ArrayD<f64>>> {
        let p = &self.0;
        let f64_array = || match &p.form {
            Form::Dense { data, .. } => Some(Arc::clone(data)),
            Form::Json(v) => p
                .json_f64
                .get_or_init(|| json_array(v).map(Arc::new))
                .clone(),
        };
        let prec = crate::precision::active();
        if !prec.is_f32() {
            return f64_array();
        }
        p.f32
            .get_or_init(|| f64_array().map(|a| Arc::new(a.mapv(|x| prec.round(x)))))
            .clone()
    }

    /// Exact identity for hash-consing: the form, the spelling, the shape and
    /// every element's bit pattern. `None` for a JSON payload, which the
    /// caller keys by its JSON.
    pub(crate) fn dense_key(&self) -> Option<(&Spelling, &[usize], &[f64])> {
        match &self.0.form {
            Form::Dense { data, spelling } => Some((
                spelling,
                data.shape(),
                data.as_slice().expect("dense payloads are standard layout"),
            )),
            Form::Json(_) => None,
        }
    }
}

impl From<Value> for ConstValue {
    fn from(value: Value) -> Self {
        ConstValue::from_json(value)
    }
}

impl std::fmt::Debug for ConstValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.0.form {
            Form::Json(v) => v.fmt(f),
            Form::Dense { data, spelling } => f
                .debug_struct("Dense")
                .field("shape", &data.shape())
                .field("spelling", spelling)
                .field("values", &data.as_slice())
                .finish(),
        }
    }
}

/// Equal literals: the same form and, for a dense one, the same spelling,
/// shape and elements (`==`, as JSON numbers compare); a JSON one by its JSON.
impl PartialEq for ConstValue {
    fn eq(&self, other: &Self) -> bool {
        if ConstValue::ptr_eq(self, other) {
            return true;
        }
        match (&self.0.form, &other.0.form) {
            (Form::Json(a), Form::Json(b)) => a == b,
            (
                Form::Dense {
                    data: a,
                    spelling: sa,
                },
                Form::Dense {
                    data: b,
                    spelling: sb,
                },
            ) => sa == sb && a == b,
            _ => false,
        }
    }
}

impl Serialize for ConstValue {
    /// Canonical-number form (esm-spec §5.5.3.1): every integral number that
    /// fits `i64`, at any depth, is written as an integer.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match &self.0.form {
            Form::Json(v) => super::expression::CanonicalJson(v).serialize(serializer),
            Form::Dense { data, .. } => DenseRows {
                shape: data.shape(),
                values: data.as_slice().expect("dense payloads are standard layout"),
            }
            .serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for ConstValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Value::deserialize(deserializer).map(ConstValue::from_json)
    }
}

/// One nesting level of a dense payload, written without building its JSON.
struct DenseRows<'a> {
    shape: &'a [usize],
    values: &'a [f64],
}

impl Serialize for DenseRows<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeSeq;
        let Some((&axis, rest)) = self.shape.split_first() else {
            return super::expression::serialize_canonical_f64(self.values[0], serializer);
        };
        let stride: usize = rest.iter().product();
        let mut seq = serializer.serialize_seq(Some(axis))?;
        for i in 0..axis {
            seq.serialize_element(&DenseRows {
                shape: rest,
                values: &self.values[i * stride..(i + 1) * stride],
            })?;
        }
        seq.end()
    }
}

/// The dense reading of a JSON literal, when it has one (see
/// [`ConstValue::from_json`]): the array and how its elements are spelled.
fn dense_of(v: &Value) -> Option<(ArrayD<f64>, Spelling)> {
    if !v.is_array() {
        return None;
    }
    let mut shape = Vec::new();
    let mut flat = Vec::new();
    let mut ints = IntBits::default();
    walk_dense(v, 0, &mut shape, &mut flat, &mut ints)?;
    if shape.contains(&0) {
        return None;
    }
    let spelling = ints.spelling(flat.len());
    ArrayD::from_shape_vec(IxDyn(&shape), flat)
        .ok()
        .map(|a| (a, spelling))
}

/// The integer-spelled elements seen so far, one bit per element.
#[derive(Default)]
struct IntBits {
    bits: Vec<u64>,
    count: usize,
}

impl IntBits {
    fn set(&mut self, k: usize) {
        if self.bits.len() <= k / 64 {
            self.bits.resize(k / 64 + 1, 0);
        }
        self.bits[k / 64] |= 1 << (k % 64);
        self.count += 1;
    }

    fn spelling(self, n: usize) -> Spelling {
        match self.count {
            0 => Spelling::Floats,
            c if c == n => Spelling::Integers,
            _ => {
                let mut bits = self.bits;
                bits.resize(n.div_ceil(64), 0);
                Spelling::Mixed(bits.into_boxed_slice())
            }
        }
    }
}

fn walk_dense(
    v: &Value,
    depth: usize,
    shape: &mut Vec<usize>,
    flat: &mut Vec<f64>,
    ints: &mut IntBits,
) -> Option<()> {
    match v {
        Value::Array(items) => {
            if depth == shape.len() {
                // A sub-array where an earlier branch had a number, or the
                // reverse, is ragged.
                if !flat.is_empty() {
                    return None;
                }
                shape.push(items.len());
            } else if shape[depth] != items.len() {
                return None;
            }
            for item in items {
                walk_dense(item, depth + 1, shape, flat, ints)?;
            }
            Some(())
        }
        Value::Number(n) => {
            if depth != shape.len() {
                return None;
            }
            let (x, int) = if n.is_f64() {
                (n.as_f64()?, false)
            } else if let Some(i) = n.as_i64() {
                (i.unsigned_abs() <= EXACT_INT).then_some((i as f64, true))?
            } else {
                let u = n.as_u64()?;
                (u <= EXACT_INT).then_some((u as f64, true))?
            };
            if int {
                ints.set(flat.len());
            }
            flat.push(x);
            Some(())
        }
        _ => None,
    }
}

/// The binary64 array a JSON literal reads as: a rectangular numeric array of
/// any spelling, in row-major order. `None` for a scalar, a non-numeric leaf
/// or a ragged array.
fn json_array(v: &Value) -> Option<ArrayD<f64>> {
    if !v.is_array() {
        return None;
    }
    let mut shape = Vec::new();
    let mut flat = Vec::new();
    collect_json_array(v, 0, &mut shape, &mut flat)?;
    ArrayD::from_shape_vec(IxDyn(&shape), flat).ok()
}

/// Walk a nested JSON numeric array, recording its shape (from the first
/// branch at each depth) and pushing every leaf number in row-major order.
/// `None` on a non-numeric leaf or a sub-array whose length disagrees with
/// the recorded shape at that depth (a ragged literal).
fn collect_json_array(
    v: &Value,
    depth: usize,
    shape: &mut Vec<usize>,
    flat: &mut Vec<f64>,
) -> Option<()> {
    match v {
        Value::Array(items) => {
            if depth == shape.len() {
                shape.push(items.len());
            } else if shape[depth] != items.len() {
                return None;
            }
            for item in items {
                collect_json_array(item, depth + 1, shape, flat)?;
            }
            Some(())
        }
        Value::Number(n) => {
            flat.push(n.as_f64()?);
            Some(())
        }
        _ => None,
    }
}

/// Row-major `values` of `shape`, the first of which is element `first` of
/// the whole array, as nested JSON: each element an integer or a float as
/// `spelling` has it (a non-finite float as `null`).
fn nest(shape: &[usize], values: &[f64], first: usize, spelling: &Spelling) -> Value {
    let Some((&axis, rest)) = shape.split_first() else {
        let x = values[0];
        return if spelling.is_integer(first) {
            Value::from(x as i64)
        } else {
            serde_json::Number::from_f64(x).map_or(Value::Null, Value::Number)
        };
    };
    let stride: usize = rest.iter().product();
    Value::Array(
        (0..axis)
            .map(|i| {
                nest(
                    rest,
                    &values[i * stride..(i + 1) * stride],
                    first + i * stride,
                    spelling,
                )
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn written(v: &ConstValue) -> String {
        serde_json::to_string(v).unwrap()
    }

    /// A rectangular numeric array is held dense, whatever mix of integer and
    /// float spellings it has; anything else keeps its JSON. Either way it
    /// writes what was read, in canonical-number form.
    #[test]
    fn dense_only_where_the_json_reads_back_exactly() {
        let dense = [
            (json!([1.5, 2.0]), "[1.5,2]"),
            (json!([[1, 2], [3, 4]]), "[[1,2],[3,4]]"),
            (json!([-0.0, 1e300]), "[0,1e+300]"),
            (json!([9_007_199_254_740_992_i64]), "[9007199254740992]"),
            (json!([1, 2.5]), "[1,2.5]"),
            (json!([[1, 2.0], [-0.0, 4]]), "[[1,2],[0,4]]"),
        ];
        for (src, want) in dense {
            let v = ConstValue::from_json(src.clone());
            assert!(v.as_dense().is_some(), "{src}");
            assert_eq!(written(&v), want);
            assert_eq!(*v.to_json(), src, "{src}");
        }
        for src in [
            json!(4.0),
            json!("NO2"),
            json!([]),
            json!([[], []]),
            json!([[1.0, 2.0], [3.0]]),
            json!([1.0, [2.0]]),
            json!([9_007_199_254_740_993_i64]),
            json!([u64::MAX]),
            json!({"op": "+"}),
        ] {
            let v = ConstValue::from_json(src.clone());
            assert!(v.as_dense().is_none(), "{src}");
            assert_eq!(v.as_json(), Some(&src));
        }
    }

    /// Built data writes the nested float array it denotes; data nested JSON
    /// cannot spell as that array is held as the JSON it writes.
    #[test]
    fn from_dense_writes_the_nested_float_array() {
        let v = ConstValue::from_dense(&[2, 2], vec![1.0, 2.5, -0.0, 4.0]);
        assert!(v.as_dense().is_some());
        assert_eq!(written(&v), "[[1,2.5],[0,4]]");
        assert_eq!(v, ConstValue::from_json(json!([[1.0, 2.5], [-0.0, 4.0]])));
        assert_ne!(v, ConstValue::from_json(json!([[1, 2], [0, 4]])));
        let nan = ConstValue::from_dense(&[2], vec![1.0, f64::NAN]);
        assert_eq!(nan.as_json(), Some(&json!([1.0, null])));
        assert!(nan.array().is_none());
        let empty = ConstValue::from_dense(&[0, 3], vec![]);
        assert_eq!(empty.as_json(), Some(&json!([])));
    }

    /// A mixed array keeps each element's spelling past the 64th element, and
    /// two arrays with the same values spelled differently are different
    /// literals.
    #[test]
    fn mixed_spelling_is_kept_per_element() {
        let src = Value::Array(
            (0..130)
                .map(|k| {
                    if k % 3 == 0 {
                        json!(k)
                    } else {
                        json!(k as f64 + 0.5)
                    }
                })
                .collect(),
        );
        let v = ConstValue::from_json(src.clone());
        assert!(matches!(v.dense_key(), Some((Spelling::Mixed(_), _, _))));
        assert_eq!(*v.to_json(), src);
        assert_eq!(
            written(&v),
            serde_json::to_string(&super::super::expression::CanonicalJson(&src)).unwrap()
        );
        let floats = ConstValue::from_json(json!([1.0, 2.5]));
        let mixed = ConstValue::from_json(json!([1, 2.5]));
        assert_eq!(floats.as_dense(), mixed.as_dense());
        assert_ne!(floats, mixed);
        assert_ne!(mixed, ConstValue::from_json(json!([1.0, 2])));
        assert_eq!(*mixed.to_json(), json!([1, 2.5]));
    }

    /// Clones share the payload, and with it the materialized array.
    #[test]
    fn clones_share_the_payload_and_its_array() {
        let v = ConstValue::from_json(json!([1, 2, 3]));
        let w = v.clone();
        assert!(ConstValue::ptr_eq(&v, &w));
        assert!(Arc::ptr_eq(&v.array().unwrap(), &w.array().unwrap()));
        let j = ConstValue::from_json(json!([1, 2.5]));
        assert!(Arc::ptr_eq(
            &j.array().unwrap(),
            &j.clone().array().unwrap()
        ));
    }
}
