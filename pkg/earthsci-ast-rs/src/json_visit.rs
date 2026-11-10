//! Shared pre-order traversals over raw `serde_json::Value` trees.
//!
//! The load-time JSON passes (enum lowering, template machinery, import
//! resolution) all need the same skeleton: visit every value, act on the
//! interesting ones. Each function here visits EVERY node — the root
//! included, a container before its elements, array elements in index order,
//! object entries in map order (this crate builds serde_json with
//! `preserve_order`, so that is source order) — and makes no key-dependent
//! decisions. A walk that must skip certain keys or descend in a special
//! order stays hand-rolled at its call site, with a comment saying why.
//!
//! One exception: the elements of an array of numbers ([`is_number_data`],
//! a document's const data) are not visited, only the array itself. They
//! hold no object and no string, which is all any pass here acts on.
//!
//! Deliberately just three functions, not a visitor framework.

use serde_json::Value;
use std::fmt;

/// Where a visited value sits under the walk's root: a chain of the walk's own
/// stack frames, so descending costs nothing per node, and the slash-joined
/// path is formatted only when it is displayed: the root's own prefix (`""`
/// for a whole document), then `/<key-or-index>` per level (e.g.
/// `"/models/M/equations/0"`). Segments are the raw object keys / array
/// indices, unescaped — the same naive pointer syntax this crate's
/// diagnostics have always printed.
#[derive(Clone, Copy)]
pub(crate) enum JsonPath<'a> {
    Root(&'a str),
    Key(&'a JsonPath<'a>, &'a str),
    Index(&'a JsonPath<'a>, usize),
}

impl fmt::Display for JsonPath<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JsonPath::Root(prefix) => f.write_str(prefix),
            JsonPath::Key(parent, k) => {
                parent.fmt(f)?;
                f.write_str("/")?;
                f.write_str(k)
            }
            JsonPath::Index(parent, i) => {
                parent.fmt(f)?;
                write!(f, "/{i}")
            }
        }
    }
}

/// Read-only pre-order visit of `root` and every value nested under it.
///
/// `f` receives each value together with its [`JsonPath`] from `root` (`""`
/// for the root itself). Callers that don't need the path just ignore it; it
/// is formatted only by a caller that displays it.
/// `map.get(key)` for the small objects an expression tree is made of: for a
/// handful of entries, comparing the keys in order is cheaper than hashing the
/// one looked up.
pub(crate) fn small_get<'a>(
    map: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Option<&'a Value> {
    if map.len() > 8 {
        return map.get(key);
    }
    map.iter().find_map(|(k, v)| (k == key).then_some(v))
}

/// The fewest elements an array of numbers has for a walk to step over it.
const DATA_MIN_LEN: usize = 16;

/// Whether `v` is at least [`DATA_MIN_LEN`] long and holds only numbers or
/// arrays of numbers, at any depth: const data, which has no object or
/// string anywhere inside it.
pub(crate) fn is_number_data(v: &[Value]) -> bool {
    fn numbers(v: &Value) -> bool {
        match v {
            Value::Number(_) => true,
            Value::Array(a) => a.iter().all(numbers),
            _ => false,
        }
    }
    v.len() >= DATA_MIN_LEN && v.iter().all(numbers)
}

pub(crate) fn visit_values(root: &Value, f: &mut impl FnMut(&JsonPath<'_>, &Value)) {
    fn go(v: &Value, at: &JsonPath<'_>, f: &mut impl FnMut(&JsonPath<'_>, &Value)) {
        f(at, v);
        match v {
            Value::Array(arr) if is_number_data(arr) => {}
            Value::Array(arr) => {
                for (i, child) in arr.iter().enumerate() {
                    go(child, &JsonPath::Index(at, i), f);
                }
            }
            Value::Object(obj) => {
                for (k, child) in obj {
                    go(child, &JsonPath::Key(at, k), f);
                }
            }
            _ => {}
        }
    }
    go(root, &JsonPath::Root(""), f);
}

/// Mutable pre-order visit: `f` sees each value BEFORE its children, so when
/// `f` replaces a value, the walk descends into the replacement's children
/// (the replacement itself is not re-visited).
///
/// Defined in terms of [`try_visit_values_mut`] so the two cannot drift.
pub(crate) fn visit_values_mut(root: &mut Value, f: &mut impl FnMut(&mut Value)) {
    let done: Result<(), std::convert::Infallible> = try_visit_values_mut(root, &mut |v| {
        f(v);
        Ok(())
    });
    match done {
        Ok(()) => {}
        Err(never) => match never {},
    }
}

/// Short-circuiting [`visit_values_mut`]: stops at, and returns, the first
/// error. On `Err` the tree is left as far as the walk got — a caller that
/// must not observe a partially transformed tree edits a clone.
pub(crate) fn try_visit_values_mut<E>(
    root: &mut Value,
    f: &mut impl FnMut(&mut Value) -> Result<(), E>,
) -> Result<(), E> {
    f(root)?;
    match root {
        Value::Array(arr) if is_number_data(arr) => {}
        Value::Array(arr) => {
            for child in arr {
                try_visit_values_mut(child, f)?;
            }
        }
        Value::Object(obj) => {
            for (_, child) in obj.iter_mut() {
                try_visit_values_mut(child, f)?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Pins the traversal contract: pre-order, root path `""`, array elements
    /// in index order, object entries in source order, leaves included.
    #[test]
    fn visit_values_order_and_paths() {
        let doc = json!({"b": [1, {"a": "x"}], "a": true});
        let mut seen = Vec::new();
        visit_values(&doc, &mut |path, v| {
            seen.push((path.to_string(), v.clone()));
        });
        assert_eq!(
            seen,
            vec![
                ("".to_string(), doc.clone()),
                ("/b".to_string(), json!([1, {"a": "x"}])),
                ("/b/0".to_string(), json!(1)),
                ("/b/1".to_string(), json!({"a": "x"})),
                ("/b/1/a".to_string(), json!("x")),
                ("/a".to_string(), json!(true)),
            ]
        );
    }

    /// A replacement installed by the visitor is descended into, not
    /// re-visited.
    #[test]
    fn visit_values_mut_descends_into_replacements() {
        let mut doc = json!({"x": {"expand": true}});
        let mut visits = 0usize;
        visit_values_mut(&mut doc, &mut |v| {
            visits += 1;
            if v.get("expand").is_some() {
                *v = json!({"child": 7});
            }
        });
        assert_eq!(doc, json!({"x": {"child": 7}}));
        // root, /x (replaced), /x/child — the replacement's own object is
        // not re-visited, its child is.
        assert_eq!(visits, 3);
    }

    #[test]
    fn try_visit_values_mut_short_circuits() {
        let mut doc = json!([1, 2, 3, 4]);
        let mut touched = Vec::new();
        let out: Result<(), String> = try_visit_values_mut(&mut doc, &mut |v| {
            if let Some(n) = v.as_i64() {
                touched.push(n);
                if n == 2 {
                    return Err("stop".to_string());
                }
            }
            Ok(())
        });
        assert_eq!(out, Err("stop".to_string()));
        assert_eq!(touched, vec![1, 2]);
    }

    /// An array of at least 16 numbers (at any depth) is visited as one value,
    /// its elements not; a shorter one, or one holding anything else, is
    /// walked element by element.
    #[test]
    fn number_data_is_stepped_over() {
        let long: Vec<Value> = (0..16).map(|i| json!([i, i + 1])).collect();
        let doc = json!({"d": long, "s": [1, 2, 3], "m": (0..16).map(|i| if i == 9 { json!("x") } else { json!(i) }).collect::<Vec<_>>()});
        let mut seen = Vec::new();
        visit_values(&doc, &mut |path, _| seen.push(path.to_string()));
        assert!(seen.contains(&"/d".to_string()));
        assert!(!seen.iter().any(|p| p.starts_with("/d/")));
        assert!(seen.contains(&"/s/2".to_string()));
        assert!(seen.contains(&"/m/9".to_string()));
        let mut doc = doc;
        let mut n = 0usize;
        visit_values_mut(&mut doc, &mut |_| n += 1);
        assert_eq!(n, seen.len());
    }
}
