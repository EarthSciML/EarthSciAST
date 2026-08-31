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
//! Deliberately just three functions, not a visitor framework.

use serde_json::Value;

/// Read-only pre-order visit of `root` and every value nested under it.
///
/// `f` receives each value together with its slash-joined path from `root`:
/// `""` for the root itself, then `/<key-or-index>` per level (e.g.
/// `"/models/M/equations/0"`). Segments are the raw object keys / array
/// indices, unescaped — the same naive pointer syntax this crate's
/// diagnostics have always printed. Callers that don't need the path just
/// ignore it.
pub(crate) fn visit_values(root: &Value, f: &mut impl FnMut(&str, &Value)) {
    fn go(v: &Value, path: &mut String, f: &mut impl FnMut(&str, &Value)) {
        f(path, v);
        match v {
            Value::Array(arr) => {
                for (i, child) in arr.iter().enumerate() {
                    use std::fmt::Write;
                    let len = path.len();
                    let _ = write!(path, "/{i}");
                    go(child, path, f);
                    path.truncate(len);
                }
            }
            Value::Object(obj) => {
                for (k, child) in obj {
                    let len = path.len();
                    path.push('/');
                    path.push_str(k);
                    go(child, path, f);
                    path.truncate(len);
                }
            }
            _ => {}
        }
    }
    go(root, &mut String::new(), f);
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
}
