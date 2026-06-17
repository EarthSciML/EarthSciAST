//! Per-rule application logic for the rule engine (RFC §5.2).
//!
//! Houses the four phases that fire once a candidate rule has been
//! selected by the [`crate::rule_engine`] dispatcher:
//!
//! 1. **Match** ([`match_pattern`]): unify a pattern AST against an
//!    `Expr`, collecting pattern-variable bindings (RFC §5.2.3).
//! 2. **Apply bindings** ([`apply_bindings`]): substitute bound
//!    pattern variables into the `replacement` template AST.
//! 3. **Guards** ([`check_guards`]): evaluate the closed set of
//!    `where_` constraints over the bindings + [`RuleContext`]
//!    (RFC §5.2.4).
//! 4. **Scope** ([`check_scope`]): evaluate `region` and `where_expr`
//!    against the per-query-point context (RFC §5.2.7).
//!
//! The dispatcher in [`crate::rule_engine`] orchestrates these phases;
//! the AST types and rule data structures themselves live there too.

use crate::canonicalize::canonical_json;
use crate::rule_engine::{Guard, Rule, RuleContext, RuleEngineError, RuleRegion};
use crate::types::{Expr, ExpressionNode};
use std::collections::HashMap;

// ============================================================================
// Pattern variable detection
// ============================================================================

pub(crate) fn is_pvar_string(s: &str) -> bool {
    s.len() >= 2 && s.starts_with('$')
}

// ============================================================================
// Match
// ============================================================================

/// Attempt to match `pattern` against `expr`. On success, returns a
/// substitution mapping each pattern-variable name (including the
/// leading `$`) to the bound [`Expr`]. Bare-name bindings (for sibling
/// fields like `wrt` or `dim`) are wrapped as `Expr::Variable` so the
/// substitution has a uniform type. On failure, returns `None`.
pub fn match_pattern(pattern: &Expr, expr: &Expr) -> Option<HashMap<String, Expr>> {
    match_inner(pattern, expr, HashMap::new())
}

fn match_inner(pat: &Expr, expr: &Expr, b: HashMap<String, Expr>) -> Option<HashMap<String, Expr>> {
    if let Expr::Variable(name) = pat
        && is_pvar_string(name)
    {
        return unify(name, expr.clone(), b);
    }
    match (pat, expr) {
        (Expr::Integer(pi), Expr::Integer(ei)) if pi == ei => Some(b),
        (Expr::Number(pf), Expr::Number(ef)) if pf == ef => Some(b),
        (Expr::Variable(pn), Expr::Variable(en)) if pn == en => Some(b),
        (Expr::Operator(pn), Expr::Operator(en)) => match_op(pn, en, b),
        _ => None,
    }
}

fn match_op(
    pat: &ExpressionNode,
    expr: &ExpressionNode,
    b: HashMap<String, Expr>,
) -> Option<HashMap<String, Expr>> {
    if pat.op != expr.op || pat.args.len() != expr.args.len() {
        return None;
    }
    let b = match_sibling_name(pat.wrt.as_deref(), expr.wrt.as_deref(), b)?;
    let b = match_sibling_name(pat.dim.as_deref(), expr.dim.as_deref(), b)?;
    let b = match_sibling_name(pat.broadcast_fn.as_deref(), expr.broadcast_fn.as_deref(), b)?;
    let mut cur = b;
    for (pa, ea) in pat.args.iter().zip(expr.args.iter()) {
        cur = match_inner(pa, ea, cur)?;
    }
    Some(cur)
}

fn match_sibling_name(
    pat: Option<&str>,
    val: Option<&str>,
    b: HashMap<String, Expr>,
) -> Option<HashMap<String, Expr>> {
    match (pat, val) {
        (None, None) => Some(b),
        (None, Some(_)) | (Some(_), None) => None,
        (Some(p), Some(v)) => {
            if is_pvar_string(p) {
                unify(p, Expr::Variable(v.to_string()), b)
            } else if p == v {
                Some(b)
            } else {
                None
            }
        }
    }
}

fn unify(pvar: &str, candidate: Expr, b: HashMap<String, Expr>) -> Option<HashMap<String, Expr>> {
    if let Some(prev) = b.get(pvar) {
        // Non-linear: existing binding must match canonically.
        let prev_json = canonical_json(prev).ok()?;
        let new_json = canonical_json(&candidate).ok()?;
        if prev_json == new_json { Some(b) } else { None }
    } else {
        let mut nb = b;
        nb.insert(pvar.to_string(), candidate);
        Some(nb)
    }
}

// ============================================================================
// Apply bindings (build replacement AST)
// ============================================================================

/// Substitute pattern variables in `template` with their bound values.
///
/// Returns `Err(E_PATTERN_VAR_UNBOUND)` if `template` references a
/// pattern variable that is not in `bindings`.
pub fn apply_bindings(template: &Expr, b: &HashMap<String, Expr>) -> Result<Expr, RuleEngineError> {
    match template {
        Expr::Variable(name) if is_pvar_string(name) => b.get(name).cloned().ok_or_else(|| {
            RuleEngineError::new(
                "E_PATTERN_VAR_UNBOUND",
                format!("pattern variable {name} is not bound"),
            )
        }),
        Expr::Operator(node) => {
            let mut new_args = Vec::with_capacity(node.args.len());
            for a in &node.args {
                new_args.push(apply_bindings(a, b)?);
            }
            let new_wrt = apply_name_field(node.wrt.as_deref(), b)?;
            let new_dim = apply_name_field(node.dim.as_deref(), b)?;
            let mut out = node.clone();
            out.args = new_args;
            out.wrt = new_wrt;
            out.dim = new_dim;
            Ok(Expr::Operator(out))
        }
        other => Ok(other.clone()),
    }
}

fn apply_name_field(
    field: Option<&str>,
    b: &HashMap<String, Expr>,
) -> Result<Option<String>, RuleEngineError> {
    let Some(f) = field else { return Ok(None) };
    if is_pvar_string(f) {
        let val = b.get(f).ok_or_else(|| {
            RuleEngineError::new(
                "E_PATTERN_VAR_UNBOUND",
                format!("pattern variable {f} is not bound"),
            )
        })?;
        match val {
            Expr::Variable(s) => Ok(Some(s.clone())),
            _ => Err(RuleEngineError::new(
                "E_PATTERN_VAR_TYPE",
                format!("pattern variable {f} used in name-class field must bind a bare name"),
            )),
        }
    } else {
        Ok(Some(f.to_string()))
    }
}

// ============================================================================
// Guards (§5.2.4)
// ============================================================================

/// Evaluate `guards` left-to-right, threading bindings. A guard whose
/// pvar-valued `grid` field is unbound at entry binds it to the
/// variable's actual grid (§9.2.1 pattern). Returns the extended
/// bindings on success, `None` on failure.
pub fn check_guards(
    guards: &[Guard],
    bindings: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Result<Option<HashMap<String, Expr>>, RuleEngineError> {
    let mut b = bindings.clone();
    for g in guards {
        match check_guard(g, &b, ctx)? {
            Some(nb) => b = nb,
            None => return Ok(None),
        }
    }
    Ok(Some(b))
}

/// Evaluate a single guard. Returns `Some(extended_bindings)` on match,
/// `None` on miss, or `Err` for unknown guards.
pub fn check_guard(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Result<Option<HashMap<String, Expr>>, RuleEngineError> {
    match g.name.as_str() {
        "var_has_grid" => Ok(guard_var_has_grid(g, b, ctx)),
        "dim_is_spatial_dim_of" => Ok(guard_dim_is_spatial_dim_of(g, b, ctx)),
        "dim_is_periodic" => Ok(guard_dim_is_periodic(g, b, ctx)),
        "dim_is_nonuniform" => Ok(guard_dim_is_nonuniform(g, b, ctx)),
        "var_location_is" => Ok(guard_var_location_is(g, b, ctx)),
        "var_shape_rank" => Ok(guard_var_shape_rank(g, b, ctx)),
        "bind_side_axis" => Ok(guard_bind_side_axis(g, b)),
        "bind_side_spacing" => Ok(guard_bind_side_spacing(g, b, ctx)),
        "bind_side_dim_size" => Ok(guard_bind_side_dim_size(g, b, ctx)),
        other => Err(RuleEngineError::new(
            "E_UNKNOWN_GUARD",
            format!("unknown guard: {other} (§5.2.4 closed set)"),
        )),
    }
}

fn resolve_name(b: &HashMap<String, Expr>, key: &str) -> Option<String> {
    match b.get(key)? {
        Expr::Variable(s) => Some(s.clone()),
        _ => None,
    }
}

fn param_str<'a>(g: &'a Guard, field: &str) -> Option<&'a str> {
    g.params.get(field).and_then(|v| v.as_str())
}

/// Resolve a guard field that may be a literal string or a pvar
/// reference. Returns `(resolved_value, pvar_name_if_unbound)`.
fn resolve_or_mark(
    g: &Guard,
    b: &HashMap<String, Expr>,
    field: &str,
) -> (Option<String>, Option<String>) {
    let Some(raw) = param_str(g, field) else {
        return (None, None);
    };
    if is_pvar_string(raw) {
        match b.get(raw) {
            Some(Expr::Variable(s)) => (Some(s.clone()), None),
            Some(_) => (None, None),
            None => (None, Some(raw.to_string())),
        }
    } else {
        (Some(raw.to_string()), None)
    }
}

fn bind_pvar_name(b: &HashMap<String, Expr>, pvar: &str, name: &str) -> HashMap<String, Expr> {
    let mut nb = b.clone();
    nb.insert(pvar.to_string(), Expr::Variable(name.to_string()));
    nb
}

fn guard_var_has_grid(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let var_name = resolve_name(b, pvar)?;
    let meta = ctx.variables.get(&var_name)?;
    let actual = meta.grid.as_deref()?;
    let (wanted, need_bind) = resolve_or_mark(g, b, "grid");
    if let Some(pname) = need_bind {
        return Some(bind_pvar_name(b, &pname, actual));
    }
    if wanted.as_deref() == Some(actual) {
        Some(b.clone())
    } else {
        None
    }
}

fn dim_from_pvar_or_literal(g: &Guard, b: &HashMap<String, Expr>) -> Option<String> {
    let pvar = param_str(g, "pvar")?;
    if is_pvar_string(pvar) {
        resolve_name(b, pvar)
    } else {
        Some(pvar.to_string())
    }
}

fn guard_dim_is_spatial_dim_of(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let dim_name = dim_from_pvar_or_literal(g, b)?;
    let (grid, _) = resolve_or_mark(g, b, "grid");
    let grid = grid?;
    let meta = ctx.grids.get(&grid)?;
    if meta.spatial_dims.iter().any(|d| d == &dim_name) {
        Some(b.clone())
    } else {
        None
    }
}

fn guard_dim_is_periodic(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let dim_name = dim_from_pvar_or_literal(g, b)?;
    let (grid, _) = resolve_or_mark(g, b, "grid");
    let grid = grid?;
    let meta = ctx.grids.get(&grid)?;
    if meta.periodic_dims.iter().any(|d| d == &dim_name) {
        Some(b.clone())
    } else {
        None
    }
}

fn guard_dim_is_nonuniform(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let dim_name = dim_from_pvar_or_literal(g, b)?;
    let (grid, _) = resolve_or_mark(g, b, "grid");
    let grid = grid?;
    let meta = ctx.grids.get(&grid)?;
    if meta.nonuniform_dims.iter().any(|d| d == &dim_name) {
        Some(b.clone())
    } else {
        None
    }
}

fn guard_var_location_is(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let var_name = resolve_name(b, pvar)?;
    let target = param_str(g, "location")?;
    let meta = ctx.variables.get(&var_name)?;
    if meta.location.as_deref() == Some(target) {
        Some(b.clone())
    } else {
        None
    }
}

fn guard_var_shape_rank(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let var_name = resolve_name(b, pvar)?;
    let want = g.params.get("rank").and_then(|v| v.as_u64())? as usize;
    let meta = ctx.variables.get(&var_name)?;
    let shape = meta.shape.as_ref()?;
    if shape.len() == want {
        Some(b.clone())
    } else {
        None
    }
}

fn side_to_axis(side: &str) -> Option<&'static str> {
    match side {
        "xmin" | "xmax" | "west" | "east" => Some("x"),
        "ymin" | "ymax" | "south" | "north" => Some("y"),
        "zmin" | "zmax" | "bottom" | "top" => Some("z"),
        _ => None,
    }
}

fn side_to_axis_idx(side: &str) -> Option<usize> {
    match side {
        "xmin" | "xmax" | "west" | "east" => Some(0),
        "ymin" | "ymax" | "south" | "north" => Some(1),
        "zmin" | "zmax" | "bottom" | "top" => Some(2),
        _ => None,
    }
}

fn resolve_side_or_literal(g: &Guard, b: &HashMap<String, Expr>, field: &str) -> Option<String> {
    let raw = param_str(g, field)?;
    if is_pvar_string(raw) {
        resolve_name(b, raw)
    } else {
        Some(raw.to_string())
    }
}

fn guard_bind_side_axis(g: &Guard, b: &HashMap<String, Expr>) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let side_name = resolve_side_or_literal(g, b, "side")?;
    let axis = side_to_axis(&side_name)?;
    Some(bind_pvar_name(b, pvar, axis))
}

fn guard_bind_side_spacing(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let side_name = resolve_side_or_literal(g, b, "side")?;
    let grid_raw = param_str(g, "grid")?;
    let grid_name = if is_pvar_string(grid_raw) {
        resolve_name(b, grid_raw)?
    } else {
        grid_raw.to_string()
    };
    let meta = ctx.grids.get(&grid_name)?;
    let axis_idx = side_to_axis_idx(&side_name)?;
    let dim_name = meta.spatial_dims.get(axis_idx)?;
    let n = *meta.dim_sizes.get(dim_name)? as f64;
    let mut nb = b.clone();
    nb.insert(pvar.to_string(), Expr::Number(1.0 / n));
    Some(nb)
}

fn guard_bind_side_dim_size(
    g: &Guard,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<HashMap<String, Expr>> {
    let pvar = param_str(g, "pvar")?;
    let side_name = resolve_side_or_literal(g, b, "side")?;
    let grid_raw = param_str(g, "grid")?;
    let grid_name = if is_pvar_string(grid_raw) {
        resolve_name(b, grid_raw)?
    } else {
        grid_raw.to_string()
    };
    let meta = ctx.grids.get(&grid_name)?;
    let axis_idx = side_to_axis_idx(&side_name)?;
    let dim_name = meta.spatial_dims.get(axis_idx)?;
    let n = *meta.dim_sizes.get(dim_name)?;
    let mut nb = b.clone();
    nb.insert(pvar.to_string(), Expr::Integer(n));
    Some(nb)
}

// ============================================================================
// Scope evaluation — region object + where expression (RFC §5.2.7)
// ============================================================================

/// Evaluate a rule's per-query-point scope: `region` (when an object
/// variant) and `where_expr` (expression predicate). Returns `true`
/// when the rule should fire at the current query point, `false`
/// otherwise (conservative fall-through).
///
/// A legacy string `region` and a missing `where_expr` pass
/// unconditionally, preserving v0.2 semantics.
pub fn check_scope(
    rule: &Rule,
    bindings: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Result<bool, RuleEngineError> {
    if let Some(region) = &rule.region
        && !eval_region(region, ctx)?
    {
        return Ok(false);
    }
    if let Some(where_expr) = &rule.where_expr
        && !eval_where_expr(where_expr, bindings, ctx)
    {
        return Ok(false);
    }
    Ok(true)
}

fn eval_region(region: &RuleRegion, ctx: &RuleContext) -> Result<bool, RuleEngineError> {
    match region {
        // Legacy advisory tag: no runtime effect.
        RuleRegion::Tag(_) => Ok(true),
        RuleRegion::IndexRange { axis, lo, hi } => Ok(match ctx.query_point.get(axis) {
            Some(v) => lo <= v && v <= hi,
            None => false,
        }),
        RuleRegion::Boundary { side } => Ok(eval_boundary(side, ctx)),
        RuleRegion::MaskField { field } => Ok(eval_mask_field(field, ctx)),
    }
}

fn eval_mask_field(field: &str, ctx: &RuleContext) -> bool {
    if ctx.query_point.is_empty() {
        return false;
    }
    let Some(points) = ctx.mask_fields.get(field) else {
        return false;
    };
    points
        .iter()
        .any(|pt| mask_entry_matches(pt, &ctx.query_point))
}

// A mask entry matches when every (axis, value) it declares agrees
// with the corresponding entry in `query_point`. Axes present in the
// query point but absent from the mask entry are ignored, so a 2D
// surface mask can scope rules on a 3D grid (matches on i,j for any k).
fn mask_entry_matches(mask_pt: &HashMap<String, i64>, query_pt: &HashMap<String, i64>) -> bool {
    if mask_pt.is_empty() {
        return false;
    }
    mask_pt
        .iter()
        .all(|(axis, v)| query_pt.get(axis) == Some(v))
}

fn eval_boundary(side: &str, ctx: &RuleContext) -> bool {
    let Some(grid_name) = &ctx.grid_name else {
        return false;
    };
    let Some(meta) = ctx.grids.get(grid_name) else {
        return false;
    };
    let (dim, which_hi) = match side {
        "xmin" | "west" => ("x", false),
        "xmax" | "east" => ("x", true),
        "ymin" | "south" => ("y", false),
        "ymax" | "north" => ("y", true),
        "zmin" | "bottom" => ("z", false),
        "zmax" | "top" => ("z", true),
        _ => return false,
    };
    let Some(bounds) = meta.dim_bounds.get(dim) else {
        return false;
    };
    let Some(idx_pos) = meta.spatial_dims.iter().position(|d| d == dim) else {
        return false;
    };
    let canonical = ["i", "j", "k", "l", "m"];
    if idx_pos >= canonical.len() {
        return false;
    }
    let idx_name = canonical[idx_pos];
    let Some(v) = ctx.query_point.get(idx_name) else {
        return false;
    };
    let target = if which_hi { bounds[1] } else { bounds[0] };
    *v == target
}

fn eval_where_expr(expr: &Expr, bindings: &HashMap<String, Expr>, ctx: &RuleContext) -> bool {
    if ctx.query_point.is_empty() {
        return false;
    }
    match eval_scalar(expr, bindings, ctx) {
        Some(ScalarValue::Bool(b)) => b,
        Some(ScalarValue::Int(i)) => i != 0,
        Some(ScalarValue::Float(f)) => f != 0.0,
        _ => false,
    }
}

#[derive(Debug, Clone, Copy)]
enum ScalarValue {
    Bool(bool),
    Int(i64),
    Float(f64),
}

impl ScalarValue {
    fn to_f64(self) -> f64 {
        match self {
            ScalarValue::Bool(b) => {
                if b {
                    1.0
                } else {
                    0.0
                }
            }
            ScalarValue::Int(i) => i as f64,
            ScalarValue::Float(f) => f,
        }
    }

    fn truthy(self) -> bool {
        match self {
            ScalarValue::Bool(b) => b,
            ScalarValue::Int(i) => i != 0,
            ScalarValue::Float(f) => f != 0.0,
        }
    }
}

fn eval_scalar(e: &Expr, b: &HashMap<String, Expr>, ctx: &RuleContext) -> Option<ScalarValue> {
    match e {
        Expr::Integer(i) => Some(ScalarValue::Int(*i)),
        Expr::Number(f) => Some(ScalarValue::Float(*f)),
        Expr::Variable(name) => {
            if is_pvar_string(name)
                && let Some(bound) = b.get(name)
            {
                return eval_scalar(bound, b, ctx);
            }
            ctx.query_point.get(name).map(|v| ScalarValue::Int(*v))
        }
        Expr::Operator(node) => eval_op(node, b, ctx),
    }
}

fn eval_op(
    node: &ExpressionNode,
    b: &HashMap<String, Expr>,
    ctx: &RuleContext,
) -> Option<ScalarValue> {
    let args: Option<Vec<ScalarValue>> = node.args.iter().map(|a| eval_scalar(a, b, ctx)).collect();
    match node.op.as_str() {
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
            let args = args?;
            if args.len() != 2 {
                return None;
            }
            let (l, r) = (args[0].to_f64(), args[1].to_f64());
            let b = match node.op.as_str() {
                "==" => l == r,
                "!=" => l != r,
                "<" => l < r,
                "<=" => l <= r,
                ">" => l > r,
                ">=" => l >= r,
                _ => unreachable!(),
            };
            Some(ScalarValue::Bool(b))
        }
        "+" => {
            let args = args?;
            let all_int = args.iter().all(|v| matches!(v, ScalarValue::Int(_)));
            if all_int {
                Some(ScalarValue::Int(
                    args.into_iter()
                        .map(|v| match v {
                            ScalarValue::Int(i) => i,
                            _ => unreachable!(),
                        })
                        .sum(),
                ))
            } else {
                Some(ScalarValue::Float(
                    args.into_iter().map(|v| v.to_f64()).sum(),
                ))
            }
        }
        "-" => {
            let args = args?;
            if args.len() == 1 {
                return match args[0] {
                    ScalarValue::Int(i) => Some(ScalarValue::Int(-i)),
                    ScalarValue::Float(f) => Some(ScalarValue::Float(-f)),
                    ScalarValue::Bool(_) => None,
                };
            }
            if args.len() != 2 {
                return None;
            }
            let (l, r) = (args[0], args[1]);
            if let (ScalarValue::Int(li), ScalarValue::Int(ri)) = (l, r) {
                Some(ScalarValue::Int(li - ri))
            } else {
                Some(ScalarValue::Float(l.to_f64() - r.to_f64()))
            }
        }
        "*" => {
            let args = args?;
            let all_int = args.iter().all(|v| matches!(v, ScalarValue::Int(_)));
            if all_int {
                Some(ScalarValue::Int(
                    args.into_iter()
                        .map(|v| match v {
                            ScalarValue::Int(i) => i,
                            _ => unreachable!(),
                        })
                        .product(),
                ))
            } else {
                Some(ScalarValue::Float(
                    args.into_iter().map(|v| v.to_f64()).product(),
                ))
            }
        }
        "and" => {
            let args = args?;
            Some(ScalarValue::Bool(args.iter().all(|v| v.truthy())))
        }
        "or" => {
            let args = args?;
            Some(ScalarValue::Bool(args.iter().any(|v| v.truthy())))
        }
        "not" => {
            let args = args?;
            if args.len() != 1 {
                return None;
            }
            Some(ScalarValue::Bool(!args[0].truthy()))
        }
        _ => None,
    }
}
