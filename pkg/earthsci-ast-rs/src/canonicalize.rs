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
    /// `E_CANONICAL_UNSUPPORTED_FIELD` — an operator node reached during
    /// emission carries a field with no slot in the closed canonical JSON node
    /// encoding (`op`/`args`/`wrt`/`dim`/`fn`/`name`/`value`), so no faithful
    /// canonical JSON exists for it (see [`canonical_json`]). The `String`
    /// names the first offending field. Fail-closed to match Julia's
    /// `_emit_node_json` guard (`_NON_EMISSIBLE_FIELDS`) and the TS/Python
    /// siblings, rather than silently dropping the field and emitting ambiguous
    /// bytes.
    UnsupportedField(String),
}

impl std::fmt::Display for CanonicalizeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Render the stable cross-language error CODE only (the `String` payload
        // of `UnsupportedField` is diagnostic and lives in the `Debug`/variant,
        // matching how `NonFinite`/`DivByZero` render just their codes).
        match self {
            CanonicalizeError::NonFinite => write!(f, "E_CANONICAL_NONFINITE"),
            CanonicalizeError::DivByZero => write!(f, "E_CANONICAL_DIVBY_ZERO"),
            CanonicalizeError::UnsupportedField(_) => write!(f, "E_CANONICAL_UNSUPPORTED_FIELD"),
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
    // `canonicalize` PRESERVES every field on pass-through (non-arithmetic)
    // nodes, so the returned tree may still carry a field with no slot in the
    // closed canonical JSON node encoding. Emitting only the emissible fields
    // would make structurally-different nodes byte-identical (the defect class
    // behind the `fn` bc-node bug). Fail closed instead, matching Julia's
    // `_emit_node_json` guard — see `validate_emissible`.
    validate_emissible(&c)?;
    Ok(emit_canonical_json(&c))
}

/// Reject any operator node reached through the `args` spine (the same nodes
/// `emit_node_json` recurses into) that carries a NON-EMISSIBLE field, per the
/// cross-binding canonical contract. Returns the code
/// `E_CANONICAL_UNSUPPORTED_FIELD` naming the first offending field.
///
/// This mirrors Julia's `_emit_node_json`, which checks each node's
/// `_NON_EMISSIBLE_FIELDS` before emitting and recurses only into `args`. A
/// non-emissible field carried by a node buried ONLY in a sidecar sub-tree
/// (`filter`/`expr`/…) is never emitted, hence never validated — exactly as in
/// Julia, since that node whose sidecar holds it is itself flagged first.
fn validate_emissible(e: &Expr) -> Result<(), CanonicalizeError> {
    if let Expr::Operator(n) = e {
        if let Some(field) = first_non_emissible_field(n) {
            return Err(CanonicalizeError::UnsupportedField(field.into()));
        }
        for a in &n.args {
            validate_emissible(a)?;
        }
    }
    Ok(())
}

/// The first set field of `n` that has NO slot in the canonical JSON node
/// encoding, or `None` if the node is fully emissible.
///
/// EMISSIBLE (have a wire slot): `op`, `args`, `wrt`, `dim`, `fn`
/// (`broadcast_fn`), `name`, `value`. TOLERATED-AND-IGNORED (may be present, no
/// wire slot, NOT an error — matching Julia's `_CANONICAL_IGNORED_FIELDS`):
/// `bindings`. Every OTHER `ExpressionNode` field is NON-EMISSIBLE.
///
/// SINGLE-SOURCE / FAIL-CLOSED: the leading `let ExpressionNode { … } = n;`
/// destructures EVERY field with no `..` rest pattern, so classifying each field
/// into one of the three groups is mandatory — adding a field to
/// `ExpressionNode` produces a missing-field compile error here until it is
/// deliberately classified, and therefore can never be silently dropped from
/// (nor wrongly slipped into) the canonical form. This is the Rust analogue of
/// Julia's derived `_NON_EMISSIBLE_FIELDS = setdiff(fieldnames(OpExpr),
/// emissible ∪ ignored)`; kept in lockstep with it.
fn first_non_emissible_field(n: &ExpressionNode) -> Option<&'static str> {
    let ExpressionNode {
        // EMISSIBLE — pinned wire slot, emitted by `emit_node_json`.
        op: _,
        args: _,
        wrt: _,
        dim: _,
        broadcast_fn: _, // JSON key `fn`
        name: _,
        value: _,
        units: _,
        // TOLERATED-AND-IGNORED — no wire slot, presence is NOT an error
        // (Julia's `_CANONICAL_IGNORED_FIELDS`).
        bindings: _,
        // Load provenance, never on the wire (Julia lists it ignored too).
        template_origin: _,
        // NON-EMISSIBLE — no wire slot; a set value fails canonical emission
        // closed. Checked below in struct-declaration order.
        int_var,
        lower,
        upper,
        expr,
        output_idx,
        ranges,
        reduce,
        semiring,
        join,
        filter,
        regions,
        values,
        shape,
        perm,
        axis,
        id,
        distinct,
        key,
        expect_cadence,
        attrs,
    } = n;

    // JSON wire name reported where it differs from the Rust field name
    // (`int_var` serializes as `var`).
    if int_var.is_some() {
        return Some("var");
    }
    if lower.is_some() {
        return Some("lower");
    }
    if upper.is_some() {
        return Some("upper");
    }
    if expr.is_some() {
        return Some("expr");
    }
    if output_idx.is_some() {
        return Some("output_idx");
    }
    if ranges.is_some() {
        return Some("ranges");
    }
    if reduce.is_some() {
        return Some("reduce");
    }
    if semiring.is_some() {
        return Some("semiring");
    }
    if join.is_some() {
        return Some("join");
    }
    if filter.is_some() {
        return Some("filter");
    }
    if regions.is_some() {
        return Some("regions");
    }
    if values.is_some() {
        return Some("values");
    }
    if shape.is_some() {
        return Some("shape");
    }
    if perm.is_some() {
        return Some("perm");
    }
    if axis.is_some() {
        return Some("axis");
    }
    if id.is_some() {
        return Some("id");
    }
    if distinct.is_some() {
        return Some("distinct");
    }
    if key.is_some() {
        return Some("key");
    }
    // `expect_cadence` (author cadence assertion) and `attrs` (open
    // rewrite-target op attributes) have no canonical wire slot either.
    // `tests/conformance/canonical/README.md` names both classes of field as
    // ones that MUST raise `E_CANONICAL_UNSUPPORTED_FIELD`; until 2026-08-31
    // neither could reach here, because the typed node dropped them at load.
    if expect_cadence.is_some() {
        return Some("expect_cadence");
    }
    if attrs.is_some() {
        return Some("attrs");
    }
    None
}

fn canon_op(node: &ExpressionNode) -> Result<Expr, CanonicalizeError> {
    let mut work = node.clone();
    // Canonicalize EVERY expression-bearing child — `args` plus the sidecar
    // bodies (`lower`/`upper`/`expr`/`filter`/`values`/`key`/`bindings`),
    // enumerated once by `ExpressionNode::for_each_child_mut` (the crate's single
    // source of truth for which fields carry child `Expr`s). This guarantees a
    // non-finite float or `0/0` buried in an aggregate body, integral bound,
    // `filter` predicate, or template binding is caught by
    // the same `NonFinite`/`DivByZero` guards as one in `args` — previously only
    // `args` was descended, so such a NaN escaped the guard.
    //
    // Sidecar fields are NOT part of the emitted canonical JSON (see
    // `emit_node_json`, which emits only op/args/wrt/dim/fn/name/value/units — the
    // closed cross-binding field set the TS/Python/Julia siblings pin), so
    // normalizing the sidecar sub-trees here only strengthens the finiteness
    // guard and normalizes the returned tree. A node that still carries a
    // non-emissible sidecar field after canonicalization makes `canonical_json`
    // fail closed with `E_CANONICAL_UNSUPPORTED_FIELD` (see `validate_emissible`)
    // rather than emitting ambiguous bytes.
    let mut err: Option<CanonicalizeError> = None;
    work.for_each_child_mut(&mut |child| {
        if err.is_some() {
            return;
        }
        match canonicalize(&*child) {
            Ok(c) => *child = c,
            Err(e) => err = Some(e),
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    // A `const` node's declared units take the canonical unit spelling
    // (esm-spec §4.8.2), so two spellings of one unit canonicalize alike.
    if let Some(units) = work.units.as_mut() {
        *units = crate::units::canonical_unit_spelling(units);
    }
    match work.op.as_str() {
        "+" => canon_add(&mut work),
        "*" => canon_mul(&mut work),
        "-" => canon_sub(&mut work),
        "/" => canon_div(&mut work),
        "neg" => canon_neg(&mut work),
        _ => Ok(Expr::operator(work)),
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
    Ok(Expr::operator(ExpressionNode {
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
    Ok(Expr::operator(ExpressionNode {
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
                && let Expr::Integer(i) = a
            {
                return Ok(Expr::Number(i as f64));
            }
            return Ok(a);
        }
        // Restore args.
        return Ok(Expr::operator(ExpressionNode {
            op: "-".into(),
            args: vec![a, b],
            ..ExpressionNode::default()
        }));
    }
    Ok(Expr::operator(std::mem::take(node)))
}

fn canon_div(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    if node.args.len() != 2 {
        return Ok(Expr::operator(std::mem::take(node)));
    }
    let b = node.args.pop().unwrap();
    let a = node.args.pop().unwrap();
    if is_zero_any(&a) && is_zero_any(&b) {
        return Err(CanonicalizeError::DivByZero);
    }
    if is_one_any(&b) {
        if matches!(b, Expr::Number(_))
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
    Ok(Expr::operator(ExpressionNode {
        op: "/".into(),
        args: vec![a, b],
        ..ExpressionNode::default()
    }))
}

fn canon_neg(node: &mut ExpressionNode) -> Result<Expr, CanonicalizeError> {
    if node.args.len() != 1 {
        return Ok(Expr::operator(std::mem::take(node)));
    }
    let arg = node.args.pop().unwrap();
    canon_neg_value(arg)
}

fn canon_neg_value(arg: Expr) -> Result<Expr, CanonicalizeError> {
    match arg {
        Expr::Integer(i) => Ok(Expr::Integer(-i)),
        Expr::Number(f) => Ok(Expr::Number(-f)),
        Expr::Operator(n) if n.op == "neg" && n.args.len() == 1 => Ok(n.args[0].clone()),
        other => Ok(Expr::operator(ExpressionNode {
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
            Expr::Operator(node) if node.op == op => out.extend(node.args.iter().cloned()),
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

// Emit the canonical JSON object for an operator node. Infallible internal sort
// key: `canonical_json` runs `validate_emissible` BEFORE any emission, so every
// node reaching here is already known to be fully emissible.
//
// Emissible field set (CLOSED, cross-binding-pinned): exactly
// `op`/`args`/`wrt`/`dim`/`fn`/`name`/`value`. This is the identical set the
// sibling bindings serialize — Julia's `_EMISSIBLE_FIELDS` tuple, and the
// `emitNodeJson`/`_emit_node_json` emitters in TS/Python — and it is the set the
// cross-binding `tests/conformance/canonical/` fixtures pin. Extending it is a
// coordinated cross-binding format change, NEVER a Rust-local edit: emitting an
// extra field here would make this binding's `canonical_json` bytes diverge from
// the siblings and break the byte contract.
//
// The former field-coverage gap (a node's other set fields — `expr`/`ranges`/
// `reduce`/`semiring`/`join`/`filter`, `regions`/`values`,
// `shape`/`perm`/`axis`, `id`, `key`/`distinct`, … — had
// no slot here, so two nodes differing ONLY in those fields produced identical
// canonical JSON) is now CLOSED by failing closed: `validate_emissible` rejects
// any such node with `E_CANONICAL_UNSUPPORTED_FIELD`, matching Julia.
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
    if let Some(ref u) = n.units {
        entries.push(("units".into(), json_string(u)));
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
        // Non-finite floats have NO canonical JSON form: `canonicalize` /
        // `canonical_json` reject them with `E_CANONICAL_NONFINITE` before any
        // value reaches here (the TS/Python/Julia siblings `throw`/`raise` at the
        // equivalent point). This helper returns `String`, so it cannot signal an
        // error; if an unguarded external caller does reach this branch, emit a
        // DISTINCT, human-readable token per value — never a valid JSON number, so
        // it can never masquerade as finite — instead of collapsing +Inf, -Inf,
        // and NaN to the same misleading `"NaN"`.
        return if f.is_nan() {
            "NaN".into()
        } else if f > 0.0 {
            "Infinity".into()
        } else {
            "-Infinity".into()
        };
    }
    if f == 0.0 {
        return if f.is_sign_negative() {
            "-0.0".into()
        } else {
            "0.0".into()
        };
    }
    let d = shortest_digits(f);
    let mut out = String::with_capacity(32);
    if f < 0.0 {
        out.push('-');
    }
    if (1e-6..1e21).contains(&f.abs()) {
        // plain decimal, with a `.0` on an integral value
        push_positional(&mut out, d.as_str(), d.exp, true);
    } else {
        // `d[.ddd]e<exp>`, no `+` on the exponent ("1e25", "3e-7")
        push_scientific(&mut out, d.as_str(), d.exp, false);
    }
    out
}

/// `v` as Julia's `print(::Float64)` writes it: shortest round-tripping digits
/// (a decimal tie takes the even last digit), positional when the decimal
/// exponent of the first digit is in `-4..=5` (`0.0001`, `100000.0`) and
/// `d.ddd…e<exp>` outside it (`9.99e-5`, `1.0e6`, `1.0e16`), always with a
/// digit after the point; `0.0`, `-0.0`, `NaN`, `Inf`, `-Inf`.
pub fn format_julia_float(v: f64) -> String {
    if v.is_nan() {
        return "NaN".into();
    }
    if v.is_infinite() {
        return if v > 0.0 { "Inf" } else { "-Inf" }.into();
    }
    if v == 0.0 {
        return if v.is_sign_negative() { "-0.0" } else { "0.0" }.into();
    }
    let d = shortest_digits(v);
    let mut out = String::with_capacity(32);
    if v < 0.0 {
        out.push('-');
    }
    if (-4..=5).contains(&d.exp) {
        push_positional(&mut out, d.as_str(), d.exp, true);
    } else {
        push_scientific(&mut out, d.as_str(), d.exp, true);
    }
    out
}

/// `v` laid out as std's `Display` lays it out — always positional, an
/// integral value with no point (`100`, `0.001`, `1e300` as 301 digits) — but
/// with the digits from [`shortest_digits`], so a decimal tie takes the even
/// last digit as every other binding writes it. Non-finite values and zero
/// are std's (`NaN`, `inf`, `-0`).
pub fn format_plain_float(v: f64) -> String {
    if !v.is_finite() || v == 0.0 {
        return format!("{v}");
    }
    let d = shortest_digits(v);
    let mut out = String::with_capacity(32);
    if v < 0.0 {
        out.push('-');
    }
    push_positional(&mut out, d.as_str(), d.exp, false);
    out
}

/// The shortest decimal digits that read back as a float, without leading or
/// trailing zeros, and the decimal exponent of the first one:
/// `705129328097.90625` is `"7051293280979062"` with `exp` 11. Kept on the
/// stack; [`Self::as_str`] borrows the digits.
pub(crate) struct ShortestDigits {
    buf: [u8; 24],
    len: usize,
    /// Decimal exponent of the first digit: the value is `d.ddd… × 10^exp`.
    pub(crate) exp: i32,
}

impl ShortestDigits {
    pub(crate) fn as_str(&self) -> &str {
        // only ASCII digits are ever stored
        std::str::from_utf8(&self.buf[..self.len]).expect("ASCII digits")
    }
}

/// The shortest decimal digits that read back as `|f|` (finite, non-zero).
/// Every float writer that must match the other bindings byte for byte takes
/// its digits from here.
///
/// When the exact binary value lies halfway between two shortest candidates
/// that both read back (705129328097.90625, between …9062 and …9063), the one
/// with the even last digit is taken, as Julia's Ryu, Python's `repr`,
/// JavaScript's `Number::toString` and Go's `strconv` take it; when that one
/// does not read back — at a power of two, where the rounding interval below
/// is half as wide as the one above (2^-24 = 5.9604644775390625e-8 reads back
/// from …063 but not from …062) — the other is. The `ryu` crate does both.
/// Rust's own `{:e}` / `Display` do not: they find the right digit count but
/// take the upper candidate on a tie, so no writer here may take its digits
/// from them.
pub(crate) fn shortest_digits(f: f64) -> ShortestDigits {
    debug_assert!(f.is_finite() && f != 0.0);
    let mut ryu_buf = ryu::Buffer::new();
    // ryu writes `ddd.ddd`, `0.000ddd` or `d[.ddd]e<exp>`
    let s = ryu_buf.format_finite(f.abs());
    let (mant, e) = match s.split_once('e') {
        Some((m, e)) => (m, e.parse::<i32>().expect("ryu exponent is an integer")),
        None => (s, 0),
    };
    let int_len = mant.find('.').unwrap_or(mant.len());
    let mut out = ShortestDigits {
        buf: [0; 24],
        len: 0,
        exp: 0,
    };
    let mut leading_zeros = 0;
    for b in mant.bytes().filter(|&b| b != b'.') {
        if out.len == 0 && b == b'0' {
            leading_zeros += 1;
        } else {
            out.buf[out.len] = b;
            out.len += 1;
        }
    }
    while out.len > 1 && out.buf[out.len - 1] == b'0' {
        out.len -= 1;
    }
    out.exp = int_len as i32 - 1 - leading_zeros + e;
    out
}

/// Append `digits` × 10^(`exp` − digits + 1) in positional notation
/// (`("25", 0)` → `2.5`, `("5", -3)` → `0.005`). An integral value gets a
/// `.0` when `force_frac` is set (`("1", 2)` → `100.0`) and no point
/// otherwise (`100`).
pub(crate) fn push_positional(out: &mut String, digits: &str, exp: i32, force_frac: bool) {
    if exp < 0 {
        out.push_str("0.");
        out.extend(std::iter::repeat_n('0', (-exp - 1) as usize));
        out.push_str(digits);
        return;
    }
    let k = exp as usize + 1;
    if k >= digits.len() {
        out.push_str(digits);
        out.extend(std::iter::repeat_n('0', k - digits.len()));
        if force_frac {
            out.push_str(".0");
        }
    } else {
        out.push_str(&digits[..k]);
        out.push('.');
        out.push_str(&digits[k..]);
    }
}

/// Append the scientific mantissa `d[.ddd]` of `digits`; a single digit gets
/// a `.0` when `force_frac` is set (`"1"` → `1.0`) and stays bare otherwise.
pub(crate) fn push_mantissa(out: &mut String, digits: &str, force_frac: bool) {
    out.push_str(&digits[..1]);
    match &digits[1..] {
        "" if force_frac => out.push_str(".0"),
        "" => {}
        frac => {
            out.push('.');
            out.push_str(frac);
        }
    }
}

/// Append `d[.ddd]e<exp>`: [`push_mantissa`], then the exponent with no `+`
/// and no leading zeros (`1e25`, `3.5e-7`, or `1.0e25` with `force_frac`).
pub(crate) fn push_scientific(out: &mut String, digits: &str, exp: i32, force_frac: bool) {
    use std::fmt::Write as _;
    push_mantissa(out, digits, force_frac);
    write!(out, "e{exp}").expect("writing to a String cannot fail");
}

// ---------------------------------------------------------------------------
// The document-level canonical step (esm-spec §4.8.2 "Canonical spelling").
// ---------------------------------------------------------------------------

/// Object properties whose value is a NAME-KEYED map (esm-schema.json): a map's
/// keys are names, never fields, so a variable NAMED `units` is not a units
/// string. The same list in every binding.
const DOCUMENT_MAP_KEYS: &[&str] = &[
    "bind",
    "bindings",
    "coordinates",
    "coords",
    "coupling_roles",
    "data_sources",
    "enums",
    "expression_template_imports",
    "expression_templates",
    "guesses",
    "index_set_rename",
    "index_sets",
    "initial_conditions",
    "map",
    "metaparameters",
    "models",
    "parameter_overrides",
    "parameters",
    "pinned_coords",
    "ranges",
    "reaction_systems",
    "rebind",
    "rename",
    "species",
    "subsystems",
    "translate",
    "url_substitutions",
    "variables",
    "where",
];

/// Free-form objects (schema `additionalProperties: true`), never descended.
const DOCUMENT_FREE_KEYS: &[&str] = &["attrs", "config", "metadata", "reader_options", "x_esd"];

/// The document-level canonical step: every units string of a decoded document
/// (the JSON value `to_json` writes and `load_document` reads) takes the
/// canonical unit spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).
///
/// That is every `units` and `default_units` string of a variable, species,
/// parameter, coordinate or `const` node, wherever it sits: nested subsystems,
/// template bodies, tests, coupling entries. Free-form objects (`metadata`,
/// `x_esd`, `attrs`, `config`, `reader_options`) are not touched, and neither
/// are the keys of name-keyed maps. Nothing else changes.
#[must_use]
pub fn canonicalize_document(doc: &serde_json::Value) -> serde_json::Value {
    fn walk(value: &serde_json::Value, is_map: bool) -> serde_json::Value {
        use serde_json::Value;
        match value {
            Value::Array(items) => Value::Array(items.iter().map(|v| walk(v, false)).collect()),
            Value::Object(obj) => Value::Object(
                obj.iter()
                    .map(|(k, v)| {
                        let out = match v {
                            _ if is_map => walk(v, false),
                            Value::String(u) if k == "units" || k == "default_units" => {
                                Value::String(crate::units::canonical_unit_spelling(u))
                            }
                            _ if DOCUMENT_FREE_KEYS.contains(&k.as_str()) => v.clone(),
                            _ => walk(v, DOCUMENT_MAP_KEYS.contains(&k.as_str())),
                        };
                        (k.clone(), out)
                    })
                    .collect(),
            ),
            other => other.clone(),
        }
    }
    walk(doc, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::operator(ExpressionNode {
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
    fn decimal_ties_take_the_even_digit() {
        // An exact value halfway between two shortest candidates that both
        // read back is written with the even last digit, as every other
        // binding writes it (tests/conformance/canonical/float_ties.json).
        // Each literal is that shortest form; the exact values are
        // 705129328097.90625, -227821227903782.625, 2^-25 and
        // -5.9604644775390625e-7.
        let x = |bits: u64| f64::from_bits(bits);
        let cases = [
            (705129328097.9062, "705129328097.9062"),
            (-227821227903782.62, "-227821227903782.62"),
            (2.0_f64.powi(-25), "2.9802322387695312e-8"),
            (-5.960464477539062e-7, "-5.960464477539062e-7"),
            // 2^-24: the even candidate (…062) does not read back, since the
            // rounding interval below a power of two is half as wide
            (2.0_f64.powi(-24), "5.960464477539063e-8"),
            // RFC 8785 Appendix B (an integral value keeps its `.0`, and an
            // exponent has no `+`)
            (x(0x43143ff3c1cb0959), "1424953923781206.2"),
            (x(0x41b3de4355555553), "333333333.3333332"),
            (x(0x41b3de4355555554), "333333333.33333325"),
            (x(0x41b3de4355555555), "333333333.3333333"),
            (x(0x41b3de4355555556), "333333333.3333334"),
            (x(0x41b3de4355555557), "333333333.33333343"),
            (x(0x44b52d02c7e14af5), "9.999999999999997e22"),
            (x(0x44b52d02c7e14af6), "1e23"),
            (x(0x44b52d02c7e14af7), "1.0000000000000001e23"),
            (x(0x444b1ae4d6e2ef4e), "999999999999999700000.0"),
            (x(0x444b1ae4d6e2ef4f), "999999999999999900000.0"),
            (x(0x444b1ae4d6e2ef50), "1e21"),
            (x(0x4430000000000000), "295147905179352830000.0"),
            (x(0x3eb0c6f7a0b5ed8c), "9.999999999999997e-7"),
            (x(0x3eb0c6f7a0b5ed8d), "0.000001"),
            (x(0xbecbf647612f3696), "-0.0000033333333333333333"),
            (x(0x7fefffffffffffff), "1.7976931348623157e308"),
            (x(0x000fffffffffffff), "2.225073858507201e-308"),
        ];
        for (v, want) in cases {
            assert_eq!(format_canonical_float(v), want, "for {:016x}", v.to_bits());
        }
    }

    /// The tie-to-even shortest digits by exact decimal conversion: std's
    /// `{:e}` gives the shortest digit count, re-printing at that precision
    /// rounds the exact value half to even, and that candidate is kept only
    /// if it reads back. The oracle `shortest_digits` must agree with.
    fn exact_shortest(f: f64) -> (String, i32) {
        let a = f.abs();
        let sci = format!("{a:e}");
        let prec = sci.find('e').map_or(0, |i| i.saturating_sub(2));
        let even = format!("{a:.prec$e}");
        let pick = if even.parse::<f64>() == Ok(a) {
            even
        } else {
            sci
        };
        let (mant, exp) = pick.split_once('e').unwrap();
        (mant.replace('.', ""), exp.parse().unwrap())
    }

    #[test]
    fn shortest_digits_agree_with_exact_tie_to_even() {
        let check = |v: f64| {
            if !v.is_finite() || v == 0.0 {
                return;
            }
            let d = shortest_digits(v);
            let (want, exp) = exact_shortest(v);
            assert_eq!(
                (d.as_str(), d.exp),
                (want.as_str(), exp),
                "for {:016x}",
                v.to_bits()
            );
        };
        // xorshift, fixed seed: random bit patterns across the whole range
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        for _ in 0..200_000 {
            check(f64::from_bits(next()));
        }
        // dyadic values n·2^-j with a 48-53 bit n: short exact decimal
        // expansions, so many are exact ties between two shortest candidates
        for _ in 0..200_000 {
            let r = next();
            let n = ((r >> 11) | (1 << 47)) >> (r % 6);
            let j = (r >> 3) % 40;
            check(n as f64 / 2f64.powi(j as i32));
            check(n as f64 * 2f64.powi(-(j as i32) - 20));
        }
        // every power of two: the asymmetric rounding interval
        for k in -1074..=1023 {
            check(2f64.powi(k));
            check(f64::from_bits(2f64.powi(k).to_bits() + 1));
            check(f64::from_bits(2f64.powi(k).to_bits().saturating_sub(1)));
        }
    }

    #[test]
    fn julia_and_plain_layouts() {
        // `julia -e 'print(x)'` for each x
        for (v, want) in [
            (1e15, "1.0e15"),
            (1e16, "1.0e16"),
            (123456789012345.0, "1.23456789012345e14"),
            (100000.0, "100000.0"),
            (999999.9, "999999.9"),
            (-1234567.5, "-1.2345675e6"),
            (1e6, "1.0e6"),
            (0.0001, "0.0001"),
            (0.00012, "0.00012"),
            (9.99e-5, "9.99e-5"),
            (100.0, "100.0"),
            (705129328097.9062, "7.051293280979062e11"),
            (2.0_f64.powi(-24), "5.960464477539063e-8"),
            (1e300, "1.0e300"),
            (5e-324, "5.0e-324"),
            (-0.0, "-0.0"),
            (f64::NAN, "NaN"),
            (f64::NEG_INFINITY, "-Inf"),
        ] {
            assert_eq!(format_julia_float(v), want);
        }
        // std's `Display` layout, tie-to-even digits
        for (v, want) in [
            (100.0, "100"),
            (0.25, "0.25"),
            (-0.001, "-0.001"),
            (1e21, "1000000000000000000000"),
            (705129328097.9062, "705129328097.9062"),
            (-0.0, "-0"),
            (f64::INFINITY, "inf"),
        ] {
            assert_eq!(format_plain_float(v), want);
        }
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

    /// A node carrying any NON-EMISSIBLE field fails closed with the pinned
    /// cross-language code `E_CANONICAL_UNSUPPORTED_FIELD`, matching Julia's
    /// `_emit_node_json` guard. Covers a single-child sidecar (`filter`,
    /// `expr`), a scalar sidecar (`distinct`), and a bare-string sidecar (`id`).
    #[test]
    fn non_emissible_field_fails_closed() {
        // filter (Option<Box<Expr>>).
        let filtered = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![Expr::Variable("x".into())],
            filter: Some(Box::new(Expr::Variable("p".into()))),
            ..ExpressionNode::default()
        });
        // expr (Option<Box<Expr>>).
        let bodied = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![Expr::Variable("A".into())],
            expr: Some(Box::new(Expr::Variable("A".into()))),
            ..ExpressionNode::default()
        });
        // distinct (Option<bool>).
        let distinct = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![],
            distinct: Some(true),
            ..ExpressionNode::default()
        });
        // id (Option<String>).
        let ided = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![Expr::Variable("poly".into())],
            id: Some("g0".into()),
            ..ExpressionNode::default()
        });
        for e in [&filtered, &bodied, &distinct, &ided] {
            let err = canonical_json(e).unwrap_err();
            assert!(
                matches!(err, CanonicalizeError::UnsupportedField(_)),
                "expected UnsupportedField, got {err:?}"
            );
            assert_eq!(err.to_string(), "E_CANONICAL_UNSUPPORTED_FIELD");
        }
    }

    /// A non-emissible field on a node reached through the `args` spine (not
    /// just the root) is also caught — matching Julia's recursion into `args`.
    #[test]
    fn non_emissible_field_in_args_fails_closed() {
        let e = op(
            "+",
            vec![
                Expr::Variable("x".into()),
                Expr::operator(ExpressionNode {
                    op: "faq".into(),
                    args: vec![],
                    id: Some("t".into()),
                    ..ExpressionNode::default()
                }),
            ],
        );
        assert_eq!(
            canonical_json(&e).unwrap_err().to_string(),
            "E_CANONICAL_UNSUPPORTED_FIELD"
        );
    }

    /// The EMISSIBLE `fn`/`name` fields still round-trip (they have a wire
    /// slot), and the TOLERATED-AND-IGNORED `bindings` field is NOT an
    /// error — they canonicalize, emitting the pinned fields only. Matches
    /// Julia's `_EMISSIBLE_FIELDS` / `_CANONICAL_IGNORED_FIELDS`.
    #[test]
    fn emissible_and_tolerated_fields_round_trip() {
        // `fn` (broadcast_fn) is emissible → emitted.
        let bc = Expr::operator(ExpressionNode {
            op: "broadcast".into(),
            args: vec![Expr::Variable("u".into())],
            broadcast_fn: Some("sin".into()),
            ..ExpressionNode::default()
        });
        let got = canonical_json(&bc).unwrap();
        assert!(got.contains(r#""fn":"sin""#), "fn not emitted: {got}");

        // `name` is emissible → emitted.
        let named = Expr::operator(ExpressionNode {
            op: "enum".into(),
            args: vec![Expr::Variable("x".into())],
            name: Some("m.f".into()),
            ..ExpressionNode::default()
        });
        assert!(
            canonical_json(&named).unwrap().contains(r#""name":"m.f""#),
            "name not emitted"
        );

        // `bindings` is tolerated-and-ignored → no error, not emitted.
        let mut bindings = std::collections::HashMap::new();
        bindings.insert("t".to_string(), Expr::Variable("z".into()));
        let tolerated = Expr::operator(ExpressionNode {
            op: "apply_expression_template".into(),
            args: vec![Expr::Variable("x".into())],
            bindings: Some(bindings),
            ..ExpressionNode::default()
        });
        let got = canonical_json(&tolerated).expect("tolerated fields must not error");
        assert!(
            !got.contains("bindings"),
            "bindings leaked into emission: {got}"
        );
    }

    /// `canonicalize` alone STILL preserves every field on pass-through nodes
    /// (only `canonical_json` fails closed). The fail-close lives in
    /// `validate_emissible`, not in the tree rewrite.
    #[test]
    fn canonicalize_alone_preserves_fields() {
        let e = Expr::operator(ExpressionNode {
            op: "faq".into(),
            args: vec![],
            id: Some("mytable".into()),
            distinct: Some(true),
            ..ExpressionNode::default()
        });
        let c = canonicalize(&e).expect("canonicalize must not fail-close");
        match c {
            Expr::Operator(n) => {
                assert_eq!(n.id.as_deref(), Some("mytable"));
                assert_eq!(n.distinct, Some(true));
            }
            other => panic!("expected preserved operator, got {other:?}"),
        }
        // But emission fails closed.
        assert_eq!(
            canonical_json(&e).unwrap_err().to_string(),
            "E_CANONICAL_UNSUPPORTED_FIELD"
        );
    }

    /// The document-level fixtures (tests/conformance/canonical_document):
    /// `canonicalize_document(input)` equals `expected` as a JSON value.
    #[test]
    fn canonical_document_conformance_fixtures() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/conformance/canonical_document");
        let read = |name: &str| -> serde_json::Value {
            serde_json::from_str(&std::fs::read_to_string(dir.join(name)).unwrap()).unwrap()
        };
        let manifest = read("manifest.json");
        let fixtures = manifest["fixtures"].as_array().unwrap();
        assert!(!fixtures.is_empty());
        for entry in fixtures {
            let fixture = read(entry["path"].as_str().unwrap());
            assert_eq!(
                canonicalize_document(&fixture["input"]),
                fixture["expected"],
                "fixture {}",
                entry["id"]
            );
        }
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
            if let Some(code) = fixture.get("expect_error").and_then(|v| v.as_str()) {
                // Fail-closed fixture: `canonical_json` must return the pinned
                // stable error code (e.g. `E_CANONICAL_UNSUPPORTED_FIELD`).
                let err = canonical_json(&expr)
                    .expect_err(&format!("fixture {id}: expected error {code}, got Ok"));
                assert_eq!(
                    err.to_string(),
                    code,
                    "fixture {id}: error code mismatch (got {err}, want {code})"
                );
            } else {
                let got = canonical_json(&expr).expect("canonicalize");
                let want = fixture["expected"].as_str().unwrap();
                assert_eq!(got, want, "fixture {id}: got {got}, want {want}");
            }
        }
    }
}
