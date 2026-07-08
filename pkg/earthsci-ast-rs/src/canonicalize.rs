//! Canonical AST form per discretization RFC §5.4.
//!
//! Implements `canonicalize(expr) -> expr` and `canonical_json(expr) -> String`
//! such that two ASTs are canonically equal iff their `canonical_json` outputs
//! are byte-identical.
//!
//! See `docs/content/rfcs/discretization.md` §5.4.1–§5.4.7 for the normative rules.

use crate::types::{Expr, ExpressionNode};

/// Errors raised during canonicalization (per RFC §5.4.6 / §5.4.7).
#[derive(Debug, Clone, PartialEq)]
pub enum CanonicalizeError {
    /// `E_CANONICAL_NONFINITE` — NaN or ±Inf encountered (§5.4.6).
    NonFinite,
    /// `E_CANONICAL_DIVBY_ZERO` — `/(0, 0)` encountered (§5.4.7).
    DivByZero,
}

impl std::fmt::Display for CanonicalizeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CanonicalizeError::NonFinite => write!(f, "E_CANONICAL_NONFINITE"),
            CanonicalizeError::DivByZero => write!(f, "E_CANONICAL_DIVBY_ZERO"),
        }
    }
}

impl std::error::Error for CanonicalizeError {}

/// Canonicalize an [`Expr`] tree per RFC §5.4. Returns a new tree; input is not mutated.
pub fn canonicalize(expr: &Expr) -> Result<Expr, CanonicalizeError> {
    match expr {
        Expr::Integer(i) => Ok(Expr::Integer(*i)),
        Expr::Number(f) => {
            if !f.is_finite() {
                return Err(CanonicalizeError::NonFinite);
            }
            Ok(Expr::Number(*f))
        }
        Expr::Variable(s) => Ok(Expr::Variable(s.clone())),
        Expr::Operator(node) => canon_op(node),
    }
}

/// Emit the canonical on-wire JSON form of an expression (§5.4.6).
///
/// Calls `canonicalize` first, then serializes with sorted keys, no extraneous
/// whitespace, and the strict number formatting of §5.4.6.
pub fn canonical_json(expr: &Expr) -> Result<String, CanonicalizeError> {
    let c = canonicalize(expr)?;
    Ok(emit_canonical_json(&c))
}

fn canon_op(node: &ExpressionNode) -> Result<Expr, CanonicalizeError> {
    let mut new_args = Vec::with_capacity(node.args.len());
    for a in &node.args {
        new_args.push(canonicalize(a)?);
    }
    let mut work = node.clone();
    work.args = new_args;
    match work.op.as_str() {
        "+" => canon_add(&mut work),
        "*" => canon_mul(&mut work),
        "-" => canon_sub(&mut work),
        "/" => canon_div(&mut work),
        "neg" => canon_neg(&mut work),
        _ => Ok(Expr::Operator(work)),
    }
}

fn canon_add(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    let flat = flatten_same_op(std::mem::take(&mut node.args), "+");
    let (mut others, _had_int_zero, had_float_zero) = partition_identity(flat, 0);
    if had_float_zero && !all_float_literals(&others) {
        others.push(Expr::Number(0.0));
    }
    if others.is_empty() {
        return Ok(if had_float_zero {
            Expr::Number(0.0)
        } else {
            Expr::Integer(0)
        });
    }
    if others.len() == 1 {
        return Ok(others.pop().unwrap());
    }
    sort_args(&mut others);
    Ok(Expr::Operator(ExpressionNode {
        op: "+".into(),
        args: others,
        ..ExpressionNode::default()
    }))
}

fn canon_mul(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    let flat = flatten_same_op(std::mem::take(&mut node.args), "*");
    for a in &flat {
        if let Expr::Integer(0) = a {
            return Ok(Expr::Integer(0));
        }
        if let Expr::Number(f) = a
            && *f == 0.0
        {
            // Preserve signbit of zero.
            return Ok(Expr::Number(*f * 0.0_f64));
        }
    }
    let (mut others, _had_int_one, had_float_one) = partition_identity(flat, 1);
    if had_float_one && !all_float_literals(&others) {
        others.push(Expr::Number(1.0));
    }
    if others.is_empty() {
        return Ok(if had_float_one {
            Expr::Number(1.0)
        } else {
            Expr::Integer(1)
        });
    }
    if others.len() == 1 {
        return Ok(others.pop().unwrap());
    }
    sort_args(&mut others);
    Ok(Expr::Operator(ExpressionNode {
        op: "*".into(),
        args: others,
        ..ExpressionNode::default()
    }))
}

fn canon_sub(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    if node.args.len() == 1 {
        // Tolerate unary -, prefer neg on the wire.
        let arg = node.args.pop().unwrap();
        return canon_neg_value(arg);
    }
    if node.args.len() == 2 {
        let b = node.args.pop().unwrap();
        let a = node.args.pop().unwrap();
        // -(0, x) -> neg(x)
        if is_zero_any(&a) {
            return canon_neg_value(b);
        }
        // -(x, 0) -> x (type-preserving: float-zero with int x promotes)
        if is_zero_any(&b) {
            if matches!(b, Expr::Number(_))
                && matches!(a, Expr::Integer(_))
                && let Expr::Integer(i) = a
            {
                return Ok(Expr::Number(i as f64));
            }
            return Ok(a);
        }
        // Restore args.
        return Ok(Expr::Operator(ExpressionNode {
            op: "-".into(),
            args: vec![a, b],
            ..ExpressionNode::default()
        }));
    }
    Ok(Expr::Operator(std::mem::take(node)))
}

fn canon_div(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    if node.args.len() != 2 {
        return Ok(Expr::Operator(std::mem::take(node)));
    }
    let b = node.args.pop().unwrap();
    let a = node.args.pop().unwrap();
    if is_zero_any(&a) && is_zero_any(&b) {
        return Err(CanonicalizeError::DivByZero);
    }
    if is_one_any(&b) {
        if matches!(b, Expr::Number(_))
            && matches!(a, Expr::Integer(_))
            && let Expr::Integer(i) = a
        {
            return Ok(Expr::Number(i as f64));
        }
        return Ok(a);
    }
    if is_zero_any(&a) {
        return Ok(if matches!(a, Expr::Number(_)) {
            Expr::Number(0.0)
        } else {
            Expr::Integer(0)
        });
    }
    Ok(Expr::Operator(ExpressionNode {
        op: "/".into(),
        args: vec![a, b],
        ..ExpressionNode::default()
    }))
}

fn canon_neg(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    if node.args.len() != 1 {
        return Ok(Expr::Operator(std::mem::take(node)));
    }
    let arg = node.args.pop().unwrap();
    canon_neg_value(arg)
}

fn canon_neg_value(arg: Expr) -> Result<Expr, CanonicalizeError> {
    match arg {
        Expr::Integer(i) => Ok(Expr::Integer(-i)),
        Expr::Number(f) => Ok(Expr::Number(-f)),
        Expr::Operator(n) if n.op == "neg" && n.args.len() == 1 => {
            Ok(n.args.into_iter().next().unwrap())
        }
        other => Ok(Expr::Operator(ExpressionNode {
            op: "neg".into(),
            args: vec![other],
            ..ExpressionNode::default()
        })),
    }
}

fn flatten_same_op(args: Vec<Expr>, op: &str) -> Vec<Expr> {
    let mut out = Vec::with_capacity(args.len());
    for a in args {
        match a {
            Expr::Operator(node) if node.op == op => out.extend(node.args),
            other => out.push(other),
        }
    }
    out
}

fn partition_identity(args: Vec<Expr>, identity: i64) -> (Vec<Expr>, bool, bool) {
    let mut others = Vec::with_capacity(args.len());
    let (mut had_int, mut had_float) = (false, false);
    for a in args {
        match &a {
            Expr::Integer(i) if *i == identity => {
                had_int = true;
                continue;
            }
            Expr::Number(f) if *f == identity as f64 => {
                had_float = true;
                continue;
            }
            _ => {}
        }
        others.push(a);
    }
    (others, had_int, had_float)
}

fn all_float_literals(args: &[Expr]) -> bool {
    !args.is_empty() && args.iter().all(|a| matches!(a, Expr::Number(_)))
}

fn is_zero_any(e: &Expr) -> bool {
    matches!(e, Expr::Integer(0)) || matches!(e, Expr::Number(f) if *f == 0.0)
}

fn is_one_any(e: &Expr) -> bool {
    matches!(e, Expr::Integer(1)) || matches!(e, Expr::Number(f) if *f == 1.0)
}

fn sort_args(args: &mut [Expr]) {
    // Memoize canonical JSON for non-leaf nodes to avoid quadratic work (§5.4.9).
    let mut cache: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
    let mut indices: Vec<usize> = (0..args.len()).collect();
    indices.sort_by(|&i, &j| compare_exprs(&args[i], &args[j], i, j, &mut cache));
    let cloned: Vec<Expr> = indices.iter().map(|&i| args[i].clone()).collect();
    for (slot, e) in args.iter_mut().zip(cloned) {
        *slot = e;
    }
}

fn arg_tier(e: &Expr) -> u8 {
    match e {
        Expr::Integer(_) | Expr::Number(_) => 0,
        Expr::Variable(_) => 1,
        Expr::Operator(_) => 2,
    }
}

fn numeric_key(e: &Expr) -> f64 {
    match e {
        Expr::Integer(i) => *i as f64,
        Expr::Number(f) => *f,
        _ => 0.0,
    }
}

fn compare_exprs(
    a: &Expr,
    b: &Expr,
    ia: usize,
    ib: usize,
    cache: &mut std::collections::HashMap<usize, String>,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (ta, tb) = (arg_tier(a), arg_tier(b));
    if ta != tb {
        return ta.cmp(&tb);
    }
    match ta {
        0 => {
            let av = numeric_key(a);
            let bv = numeric_key(b);
            match av.partial_cmp(&bv).unwrap_or(Ordering::Equal) {
                Ordering::Equal => {
                    // int before float at equal magnitude.
                    let af = matches!(a, Expr::Number(_));
                    let bf = matches!(b, Expr::Number(_));
                    af.cmp(&bf)
                }
                ord => ord,
            }
        }
        1 => match (a, b) {
            (Expr::Variable(x), Expr::Variable(y)) => x.cmp(y),
            _ => Ordering::Equal,
        },
        _ => {
            let aj = cache
                .entry(ia)
                .or_insert_with(|| emit_canonical_json(a))
                .clone();
            let bj = cache
                .entry(ib)
                .or_insert_with(|| emit_canonical_json(b))
                .clone();
            aj.cmp(&bj)
        }
    }
}

fn emit_canonical_json(e: &Expr) -> String {
    match e {
        Expr::Integer(i) => i.to_string(),
        Expr::Number(f) => format_canonical_float(*f),
        Expr::Variable(s) => json_string(s),
        Expr::Operator(n) => emit_node_json(n),
    }
}

fn emit_node_json(n: &ExpressionNode) -> String {
    let mut entries: Vec<(String, String)> = Vec::new();
    entries.push(("op".into(), json_string(&n.op)));
    let arg_parts: Vec<String> = n.args.iter().map(emit_canonical_json).collect();
    entries.push(("args".into(), format!("[{}]", arg_parts.join(","))));
    if let Some(ref s) = n.wrt {
        entries.push(("wrt".into(), json_string(s)));
    }
    if let Some(ref s) = n.dim {
        entries.push(("dim".into(), json_string(s)));
    }
    if let Some(ref s) = n.name {
        entries.push(("name".into(), json_string(s)));
    }
    if let Some(ref v) = n.value {
        entries.push(("value".into(), emit_canonical_json_value(v)));
    }
    if let Some(ref s) = n.broadcast_fn {
        entries.push(("fn".into(), json_string(s)));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let body: Vec<String> = entries
        .into_iter()
        .map(|(k, v)| format!("{}:{}", json_string(&k), v))
        .collect();
    format!("{{{}}}", body.join(","))
}

fn json_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| format!("\"{s}\""))
}

// Canonicalize a `const`-op `value` JSON payload. Numbers carrying a fraction
// or exponent emit using `format_canonical_float`; integers emit verbatim;
// arrays recurse. Strings/objects/booleans/null fall through to serde_json's
// default rendering — `value` is constrained to numeric / nested-numeric in the
// schema, but we keep the fallback so a stray string doesn't crash canonical
// emission.
fn emit_canonical_json_value(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else if let Some(u) = n.as_u64() {
                u.to_string()
            } else if let Some(f) = n.as_f64() {
                format_canonical_float(f)
            } else {
                n.to_string()
            }
        }
        serde_json::Value::Array(arr) => {
            let parts: Vec<String> = arr.iter().map(emit_canonical_json_value).collect();
            format!("[{}]", parts.join(","))
        }
        _ => v.to_string(),
    }
}

/// Format a finite f64 per RFC §5.4.6.
pub fn format_canonical_float(f: f64) -> String {
    if !f.is_finite() {
        // Caller is responsible for guarding; render a stable token.
        return "NaN".into();
    }
    if f == 0.0 {
        return if f.is_sign_negative() {
            "-0.0".into()
        } else {
            "0.0".into()
        };
    }
    let abs = f.abs();
    let use_exp = !(1e-6..1e21).contains(&abs);
    if use_exp {
        // Use Rust's shortest round-trip; format!("{:e}", f) emits e.g. "1e25", "3e-7"
        // (no leading + on exponent).
        let s = format!("{f:e}");
        // Strip leading + (Rust doesn't emit it but be safe) and leading exponent zeros.
        normalize_exponent(&s)
    } else {
        // Plain decimal — use Rust default Display which is the shortest round-trip
        // but may print `1` for `1.0`. Add trailing `.0` if no `.` present.
        let s = shortest_float_plain(f);
        if !s.contains('.') {
            format!("{s}.0")
        } else {
            s
        }
    }
}

/// Render a float in plain (non-exponent) shortest round-trip form.
fn shortest_float_plain(f: f64) -> String {
    // Rust's Display for f64 may switch to exponent notation only for very large/small;
    // for the [1e-6, 1e21) range it emits plain decimal. But integer-valued floats
    // are printed as e.g. "1" (without decimal) — handled by the caller adding ".0".
    let s = format!("{f}");
    // For values like 1e20, Rust may print "100000000000000000000" — that's fine.
    // For 1e-5, Rust prints "0.00001" — also fine.
    s
}

fn normalize_exponent(s: &str) -> String {
    if let Some(idx) = s.find('e') {
        let (mant, exp) = s.split_at(idx);
        let exp = &exp[1..]; // strip 'e'
        let exp = exp.strip_prefix('+').unwrap_or(exp);
        let (sign, digits) = if let Some(rest) = exp.strip_prefix('-') {
            ("-", rest)
        } else {
            ("", exp)
        };
        let digits = digits.trim_start_matches('0');
        let digits = if digits.is_empty() { "0" } else { digits };
        format!("{mant}e{sign}{digits}")
    } else {
        s.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.into(),
            args,
            ..ExpressionNode::default()
        })
    }

    #[test]
    fn float_format_table() {
        let cases = [
            (1.0_f64, "1.0"),
            (-3.0, "-3.0"),
            (0.0, "0.0"),
            (-0.0_f64, "-0.0"),
            (2.5, "2.5"),
            (1e25, "1e25"),
            (5e-324, "5e-324"),
            (1e-7, "1e-7"),
        ];
        for (v, want) in cases {
            assert_eq!(format_canonical_float(v), want, "for {v}");
        }
        let mixed = 0.1_f64 + 0.2_f64;
        assert_eq!(format_canonical_float(mixed), "0.30000000000000004");
    }

    #[test]
    fn integer_emission() {
        for (v, want) in [(1_i64, "1"), (-42, "-42"), (0, "0")] {
            assert_eq!(canonical_json(&Expr::Integer(v)).unwrap(), want);
        }
    }

    #[test]
    fn nonfinite_errors() {
        for f in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(
                canonicalize(&Expr::Number(f)).unwrap_err(),
                CanonicalizeError::NonFinite
            );
        }
    }

    #[test]
    fn worked_example() {
        // +(*(a, 0), b, +(a, 1)) -> +(1, "a", "b")
        let e = op(
            "+",
            vec![
                op("*", vec![Expr::Variable("a".into()), Expr::Integer(0)]),
                Expr::Variable("b".into()),
                op("+", vec![Expr::Variable("a".into()), Expr::Integer(1)]),
            ],
        );
        let got = canonical_json(&e).unwrap();
        assert_eq!(got, r#"{"args":[1,"a","b"],"op":"+"}"#);
    }

    #[test]
    fn flatten_basic() {
        let e = op(
            "+",
            vec![
                op(
                    "+",
                    vec![Expr::Variable("a".into()), Expr::Variable("b".into())],
                ),
                Expr::Variable("c".into()),
            ],
        );
        assert_eq!(
            canonical_json(&e).unwrap(),
            r#"{"args":["a","b","c"],"op":"+"}"#
        );
    }

    #[test]
    fn type_preserving_identity() {
        // *(1, x) -> "x"
        let e1 = op("*", vec![Expr::Integer(1), Expr::Variable("x".into())]);
        assert_eq!(canonical_json(&e1).unwrap(), r#""x""#);
        // *(1.0, x) keeps the 1.0
        let e2 = op("*", vec![Expr::Number(1.0), Expr::Variable("x".into())]);
        assert_eq!(
            canonical_json(&e2).unwrap(),
            r#"{"args":[1.0,"x"],"op":"*"}"#
        );
    }

    #[test]
    fn zero_annihilation_type_preserve() {
        // *(0, x) -> 0
        let e1 = op("*", vec![Expr::Integer(0), Expr::Variable("x".into())]);
        assert_eq!(canonical_json(&e1).unwrap(), "0");
        // *(0.0, x) -> 0.0
        let e2 = op("*", vec![Expr::Number(0.0), Expr::Variable("x".into())]);
        assert_eq!(canonical_json(&e2).unwrap(), "0.0");
        // *(-0.0, x) -> -0.0
        let e3 = op("*", vec![Expr::Number(-0.0), Expr::Variable("x".into())]);
        assert_eq!(canonical_json(&e3).unwrap(), "-0.0");
    }

    #[test]
    fn int_float_disambiguation() {
        let a = op("+", vec![Expr::Number(1.0), Expr::Number(2.5)]);
        let b = op("+", vec![Expr::Integer(1), Expr::Number(2.5)]);
        let ja = canonical_json(&a).unwrap();
        let jb = canonical_json(&b).unwrap();
        assert_ne!(ja, jb, "int/float distinction lost: {ja} == {jb}");
        assert!(ja.contains("1.0"), "float 1.0 not emitted as 1.0: {ja}");
    }

    #[test]
    fn neg_canonical() {
        let inner = op("neg", vec![Expr::Variable("x".into())]);
        let outer = op("neg", vec![inner]);
        assert_eq!(canonical_json(&outer).unwrap(), r#""x""#);
        let lit = op("neg", vec![Expr::Integer(5)]);
        assert_eq!(canonical_json(&lit).unwrap(), "-5");
        let sub = op("-", vec![Expr::Integer(0), Expr::Variable("x".into())]);
        assert_eq!(
            canonical_json(&sub).unwrap(),
            r#"{"args":["x"],"op":"neg"}"#
        );
    }

    #[test]
    fn div_zero_by_zero() {
        let e = op("/", vec![Expr::Integer(0), Expr::Integer(0)]);
        assert_eq!(canonicalize(&e).unwrap_err(), CanonicalizeError::DivByZero);
    }

    /// Conformance fixture consumer — the same fixture set is run by every
    /// binding's tests; passing here means this binding produces canonical
    /// output that matches the cross-binding contract.
    #[test]
    fn cross_binding_conformance_fixtures() {
        use std::path::PathBuf;
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        // pkg/earthsci-ast-rs -> repo root is 2 levels up.
        let repo_root: PathBuf = PathBuf::from(manifest_dir)
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        let dir = repo_root
            .join("tests")
            .join("conformance")
            .join("canonical");
        let manifest_bytes = std::fs::read(dir.join("manifest.json")).expect("read manifest");
        let manifest: serde_json::Value =
            serde_json::from_slice(&manifest_bytes).expect("parse manifest");
        let fixtures = manifest["fixtures"].as_array().expect("fixtures array");
        assert!(!fixtures.is_empty(), "manifest has no fixtures");
        for f in fixtures {
            let id = f["id"].as_str().unwrap();
            let path = dir.join(f["path"].as_str().unwrap());
            let raw = std::fs::read(&path).expect("read fixture");
            let fixture: serde_json::Value = serde_json::from_slice(&raw).expect("parse fixture");
            let input_json = fixture["input"].clone();
            let expr: Expr = serde_json::from_value(input_json).expect("decode input as Expr");
            let got = canonical_json(&expr).expect("canonicalize");
            let want = fixture["expected"].as_str().unwrap();
            assert_eq!(got, want, "fixture {id}: got {got}, want {want}");
        }
    }
}
