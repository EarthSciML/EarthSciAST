//! Rule engine per discretization RFC §5.2.
//!
//! This module hosts the canonical-form dispatch loop, the rule and
//! context data types, JSON parsing, and the post-rewrite unrewritten-
//! PDE-op check. The per-rule application phases (match, apply
//! bindings, guards, scope) live in [`crate::rule_applier`] and are
//! re-exported here for source-compatibility with the historical
//! `rule_engine::*` public path.
//!
//! Pattern-match rewriting over the ESM expression AST with typed pattern
//! variables, guards, non-linear matching (via canonical equality), and a
//! top-down fixed-point loop with per-pass sealing of rewritten subtrees.
//!
//! The MVP supports only the inline `replacement` form; `use:<scheme>`
//! (RFC §7.2.1) is deferred to Step 1b.
//!
//! See `docs/rfcs/discretization.md` §5.2 for the normative rules.
//!
//! Design note: this implementation mirrors the Julia reference in
//! `packages/EarthSciSerialization.jl/src/rule_engine.jl`. Each rewrite
//! pass walks top-down; the first rule whose pattern matches and whose
//! guards pass fires, and the rewritten subtree is sealed (the walker
//! does not descend into it for the remainder of the current pass). A
//! pass that produces no rewrites terminates the loop; if `max_passes`
//! is reached the engine aborts with `E_RULES_NOT_CONVERGED`.

use crate::types::{Expr, ExpressionNode};
use std::collections::HashMap;

// Re-export the per-rule application API at this module's historical
// public path so `rule_engine::match_pattern` (and the lib.rs re-exports)
// continue to resolve after the split into `rule_applier`. The dispatcher
// in this module also calls these directly.
pub use crate::rule_applier::{
    apply_bindings, check_guard, check_guards, check_scope, match_pattern,
};

// ============================================================================
// Error type
// ============================================================================

/// Errors raised by the rule engine.
///
/// `code()` returns one of the RFC stable error codes:
/// - `E_RULES_NOT_CONVERGED` (§5.2.5)
/// - `E_UNREWRITTEN_PDE_OP` (§11 Step 7)
/// - `E_SCHEME_MISMATCH` (§7.2.1; reserved for the deferred `use:` form)
/// - `E_UNKNOWN_GUARD`, `E_PATTERN_VAR_UNBOUND`, `E_PATTERN_VAR_TYPE`,
///   `E_RULE_PARSE`, `E_RULE_REPLACEMENT_MISSING` (implementation-level).
#[derive(Debug, Clone, PartialEq)]
pub struct RuleEngineError {
    pub code: String,
    pub message: String,
}

impl RuleEngineError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    pub fn code(&self) -> &str {
        &self.code
    }
}

impl std::fmt::Display for RuleEngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RuleEngineError({}): {}", self.code, self.message)
    }
}

impl std::error::Error for RuleEngineError {}

// ============================================================================
// Guard
// ============================================================================

/// A single constraint on pattern-variable bindings (RFC §5.2.4).
///
/// `name` is one of the closed-set guard names; `params` carries the
/// fields from the JSON guard object (`pvar`, `grid`, `location`, …).
#[derive(Debug, Clone)]
pub struct Guard {
    pub name: String,
    pub params: HashMap<String, serde_json::Value>,
}

// ============================================================================
// Rule
// ============================================================================

/// Spatial scope of a rule (RFC §5.2.7). Absent when the rule applies
/// everywhere its pattern matches, a legacy advisory [`RuleRegion::Tag`]
/// string with no runtime effect, or a concrete per-query-point scope.
#[derive(Debug, Clone)]
pub enum RuleRegion {
    /// Legacy advisory tag (no runtime effect). Pre-v0.3 authoring idiom.
    Tag(String),
    /// `{kind:"boundary", side}` — rule applies only on the named axis side.
    Boundary { side: String },
    /// `{kind:"mask_field", field}` — rule applies where the named
    /// field is truthy. Resolved at rewrite time against
    /// [`RuleContext::mask_fields`].
    MaskField { field: String },
    /// `{kind:"index_range", axis, lo, hi}` — inclusive index-range scope.
    IndexRange { axis: String, lo: i64, hi: i64 },
}

/// Closed set of policy kinds accepted in either the string-form
/// `boundary_policy` or as [`BoundaryPolicySpec::kind`] (RFC §5.2.8 / §7).
///
/// `Ghosted`/`NeumannZero`/`Extrapolate` are v0.3.x backwards-compatible
/// aliases for `Prescribed`/`Reflecting`/`OneSidedExtrapolation`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundaryPolicyKind {
    Periodic,
    Reflecting,
    OneSidedExtrapolation,
    Prescribed,
    Ghosted,
    NeumannZero,
    Extrapolate,
}

impl BoundaryPolicyKind {
    /// Wire-form value as it appears in JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            BoundaryPolicyKind::Periodic => "periodic",
            BoundaryPolicyKind::Reflecting => "reflecting",
            BoundaryPolicyKind::OneSidedExtrapolation => "one_sided_extrapolation",
            BoundaryPolicyKind::Prescribed => "prescribed",
            BoundaryPolicyKind::Ghosted => "ghosted",
            BoundaryPolicyKind::NeumannZero => "neumann_zero",
            BoundaryPolicyKind::Extrapolate => "extrapolate",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "periodic" => Some(BoundaryPolicyKind::Periodic),
            "reflecting" => Some(BoundaryPolicyKind::Reflecting),
            "one_sided_extrapolation" => Some(BoundaryPolicyKind::OneSidedExtrapolation),
            "prescribed" => Some(BoundaryPolicyKind::Prescribed),
            "ghosted" => Some(BoundaryPolicyKind::Ghosted),
            "neumann_zero" => Some(BoundaryPolicyKind::NeumannZero),
            "extrapolate" => Some(BoundaryPolicyKind::Extrapolate),
            _ => None,
        }
    }
}

/// Per-axis boundary-policy entry (RFC §5.2.8 / §7). `kind` selects the
/// policy; sibling fields carry kind-specific parameters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundaryPolicySpec {
    pub kind: BoundaryPolicyKind,
    /// `OneSidedExtrapolation` / `Extrapolate`: extrapolation order
    /// (0..=3). `None` means default (linear).
    pub degree: Option<i64>,
    pub description: Option<String>,
}

impl BoundaryPolicySpec {
    pub fn new(kind: BoundaryPolicyKind) -> Self {
        Self {
            kind,
            degree: None,
            description: None,
        }
    }
}

/// Authorial form of a rule's `boundary_policy` (RFC §5.2.8 / §7). Either
/// a closed-set string applied uniformly to every axis the rule's stencil
/// reaches, or a per-axis map (required for axis-heterogeneous rules).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BoundaryPolicy {
    /// Uniform string form.
    Uniform(BoundaryPolicyKind),
    /// `{by_axis: {<axis>: BoundaryPolicySpec}}` per-axis form.
    PerAxis(HashMap<String, BoundaryPolicySpec>),
}

/// Authorial form of a rule's `ghost_width` (RFC §5.2.8 / §7). Either a
/// non-negative integer applied uniformly to every axis, or a per-axis map.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GhostWidth {
    Uniform(i64),
    PerAxis(HashMap<String, i64>),
}

/// Rule binding cadence (RFC §5.2.8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleBindingKind {
    Static,
    PerStep,
    PerCell,
}

impl RuleBindingKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            RuleBindingKind::Static => "static",
            RuleBindingKind::PerStep => "per_step",
            RuleBindingKind::PerCell => "per_cell",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "static" => Some(RuleBindingKind::Static),
            "per_step" => Some(RuleBindingKind::PerStep),
            "per_cell" => Some(RuleBindingKind::PerCell),
            _ => None,
        }
    }
}

/// A single rule binding declaration (RFC §5.2.8). Loaders preserve
/// `RuleBinding` entries across parse/serialize roundtrips; the rule
/// engine itself does not consult them during pattern matching or
/// expansion.
#[derive(Debug, Clone)]
pub struct RuleBinding {
    pub kind: RuleBindingKind,
    pub default: Option<Expr>,
    pub description: Option<String>,
}

/// A rewrite rule (RFC §5.2). MVP supports the inline `replacement`
/// form only; `use:<scheme>` is tracked as Step 1b follow-up.
///
/// `where_expr`, if present, is a per-query-point boolean predicate
/// AST (RFC §5.2.7) — mutually exclusive with the guard-list `where_`
/// at the author level, structurally distinguished by JSON shape at
/// parse time.
///
/// `boundary_policy` declares behavior at domain edges (RFC §5.2.8 / §7) —
/// either a uniform string form or a per-axis map. `ghost_width` declares
/// per-axis ghost-cell padding
/// the rule's stencil reaches (RFC §5.2.8 / §7). `bindings` declares the
/// time-varying / static symbols the replacement may reference
/// (RFC §5.2.8). All three fields are stored verbatim; the rule engine
/// does not branch on them.
#[derive(Debug, Clone)]
pub struct Rule {
    pub name: String,
    pub pattern: Expr,
    pub where_: Vec<Guard>,
    pub replacement: Expr,
    pub region: Option<RuleRegion>,
    pub where_expr: Option<Expr>,
    pub boundary_policy: Option<BoundaryPolicy>,
    pub ghost_width: Option<GhostWidth>,
    pub bindings: Option<HashMap<String, RuleBinding>>,
}

impl Rule {
    pub fn new(name: impl Into<String>, pattern: Expr, replacement: Expr) -> Self {
        Self {
            name: name.into(),
            pattern,
            where_: Vec::new(),
            replacement,
            region: None,
            where_expr: None,
            boundary_policy: None,
            ghost_width: None,
            bindings: None,
        }
    }
}

// ============================================================================
// RuleContext
// ============================================================================

/// Context supplied to [`rewrite`] and guard evaluation (RFC §5.2.4).
///
/// - `grids`: per-grid metadata. Each entry may carry `spatial_dims`,
///   `periodic_dims`, `nonuniform_dims` as string vectors.
/// - `variables`: per-variable metadata. Each entry may carry `grid`
///   (string), `location` (string), `shape` (string vector).
#[derive(Debug, Clone, Default)]
pub struct RuleContext {
    pub grids: HashMap<String, GridMeta>,
    pub variables: HashMap<String, VariableMeta>,
    /// Per-query-point index bindings used to evaluate RFC §5.2.7
    /// region / where-expression scopes. Empty for ordinary tree
    /// rewriting (scope-bearing rules then fall through).
    pub query_point: HashMap<String, i64>,
    /// Name of the grid the `query_point` refers to (used to resolve
    /// `region.boundary.side` against `GridMeta::dim_bounds`).
    pub grid_name: Option<String>,
    /// Resolved per-point boolean masks for [`RuleRegion::MaskField`]
    /// scope (RFC §5.2.7). Each entry lists the query points at which
    /// the named mask is truthy; the evaluator fires the rule iff
    /// `query_point` agrees with one of those entries on every axis
    /// the entry declares. Production callers materialize this from
    /// the referenced `data_loaders` entry (or a boolean variable) at
    /// rewrite time; tests inject it directly.
    pub mask_fields: HashMap<String, Vec<HashMap<String, i64>>>,
}

/// Subset of grid metadata consumed by the closed-set guards.
#[derive(Debug, Clone, Default)]
pub struct GridMeta {
    pub spatial_dims: Vec<String>,
    pub periodic_dims: Vec<String>,
    pub nonuniform_dims: Vec<String>,
    /// Optional per-dim `[lo, hi]` index bounds, used by
    /// `region.boundary` scope evaluation (RFC §5.2.7). Absence is
    /// equivalent to "scope disabled" (conservative fall-through).
    pub dim_bounds: HashMap<String, [i64; 2]>,
    /// Per-dim cell counts (from `dimensions[].size`), used by
    /// `bind_side_spacing` / `bind_side_dim_size` guards (§5.2.4).
    pub dim_sizes: HashMap<String, i64>,
}

/// Subset of variable metadata consumed by the closed-set guards.
#[derive(Debug, Clone, Default)]
pub struct VariableMeta {
    pub grid: Option<String>,
    pub location: Option<String>,
    pub shape: Option<Vec<String>>,
}

// ============================================================================
// Rewriter (§5.2.5)
// ============================================================================

pub const DEFAULT_MAX_PASSES: usize = 32;

/// Run the rule engine on `expr` per RFC §5.2.5. Top-down walker, per-
/// pass sealing of rewritten subtrees, fixed-point loop bounded by
/// `max_passes`. On non-convergence returns `E_RULES_NOT_CONVERGED`.
pub fn rewrite(
    expr: &Expr,
    rules: &[Rule],
    ctx: &RuleContext,
    max_passes: usize,
) -> Result<Expr, RuleEngineError> {
    let mut current = expr.clone();
    for _ in 0..max_passes {
        let mut changed = false;
        current = rewrite_pass(&current, rules, ctx, &mut changed)?;
        if !changed {
            return Ok(current);
        }
    }
    Err(RuleEngineError::new(
        "E_RULES_NOT_CONVERGED",
        format!("rule engine did not converge within {max_passes} passes"),
    ))
}

fn rewrite_pass(
    expr: &Expr,
    rules: &[Rule],
    ctx: &RuleContext,
    changed: &mut bool,
) -> Result<Expr, RuleEngineError> {
    for rule in rules {
        if let Some(m) = match_pattern(&rule.pattern, expr)
            && let Some(m2) = check_guards(&rule.where_, &m, ctx)?
            && check_scope(rule, &m2, ctx)?
        {
            let new_expr = apply_bindings(&rule.replacement, &m2)?;
            *changed = true;
            return Ok(new_expr); // sealed: do not descend
        }
    }
    if let Expr::Operator(node) = expr {
        let mut new_args = Vec::with_capacity(node.args.len());
        for a in &node.args {
            new_args.push(rewrite_pass(a, rules, ctx, changed)?);
        }
        let mut out = node.clone();
        out.args = new_args;
        return Ok(Expr::Operator(out));
    }
    Ok(expr.clone())
}

// ============================================================================
// JSON parsing (rules and expressions)
// ============================================================================

/// Parse a `rules` section into an ordered vector. Accepts either the
/// JSON-object-keyed-by-name form or the array form (RFC §5.2.5).
pub fn parse_rules(value: &serde_json::Value) -> Result<Vec<Rule>, RuleEngineError> {
    if let Some(arr) = value.as_array() {
        return arr.iter().map(parse_rule_value).collect();
    }
    if let Some(obj) = value.as_object() {
        let mut out = Vec::with_capacity(obj.len());
        for (name, v) in obj {
            out.push(parse_rule_named(name, v)?);
        }
        return Ok(out);
    }
    Err(RuleEngineError::new(
        "E_RULE_PARSE",
        "`rules` must be an object or array".to_string(),
    ))
}

fn parse_rule_value(v: &serde_json::Value) -> Result<Rule, RuleEngineError> {
    let name = v
        .get("name")
        .and_then(|s| s.as_str())
        .ok_or_else(|| RuleEngineError::new("E_RULE_PARSE", "array-form rule missing `name`"))?;
    parse_rule_named(name, v)
}

fn parse_rule_named(name: &str, v: &serde_json::Value) -> Result<Rule, RuleEngineError> {
    let pattern = parse_expr(v.get("pattern").ok_or_else(|| {
        RuleEngineError::new("E_RULE_PARSE", format!("rule `{name}` missing `pattern`"))
    })?)?;
    let replacement = v.get("replacement").ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_REPLACEMENT_MISSING",
            format!(
                "rule `{name}`: MVP supports only the `replacement` form; \
                 `use:` rules are deferred"
            ),
        )
    })?;
    let replacement = parse_expr(replacement)?;
    let (where_, where_expr) = parse_where(name, v.get("where"))?;
    let region = parse_region(name, v.get("region"))?;
    let boundary_policy = parse_boundary_policy(name, v.get("boundary_policy"))?;
    let ghost_width = parse_ghost_width(name, v.get("ghost_width"))?;
    let bindings = parse_bindings(name, v.get("bindings"))?;
    Ok(Rule {
        name: name.to_string(),
        pattern,
        where_,
        replacement,
        region,
        where_expr,
        boundary_policy,
        ghost_width,
        bindings,
    })
}

const BOUNDARY_POLICY_STRING_VALUES: &[&str] = &[
    "periodic",
    "reflecting",
    "one_sided_extrapolation",
    "prescribed",
    "ghosted",
    "neumann_zero",
    "extrapolate",
];

const BOUNDARY_POLICY_KIND_VALUES: &[&str] = &[
    "periodic",
    "reflecting",
    "one_sided_extrapolation",
    "prescribed",
    "ghosted",
    "neumann_zero",
    "extrapolate",
];

fn parse_boundary_policy(
    name: &str,
    v: Option<&serde_json::Value>,
) -> Result<Option<BoundaryPolicy>, RuleEngineError> {
    let Some(v) = v else {
        return Ok(None);
    };
    if let Some(s) = v.as_str() {
        if !BOUNDARY_POLICY_STRING_VALUES.contains(&s) {
            return Err(RuleEngineError::new(
                "E_RULE_PARSE",
                format!(
                    "rule `{name}`: unknown boundary_policy `{s}` (closed set: {})",
                    BOUNDARY_POLICY_STRING_VALUES.join(", ")
                ),
            ));
        }
        // Safe: we just validated against the string-values list above.
        let kind = BoundaryPolicyKind::from_str(s).expect("validated above");
        return Ok(Some(BoundaryPolicy::Uniform(kind)));
    }
    if let Some(obj) = v.as_object() {
        let by_axis_raw = obj.get("by_axis").ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{name}`: `boundary_policy` object must have a `by_axis` field"),
            )
        })?;
        let by_axis_obj = by_axis_raw.as_object().ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{name}`: `boundary_policy.by_axis` must be an object"),
            )
        })?;
        let mut out = HashMap::with_capacity(by_axis_obj.len());
        for (axis, spec_raw) in by_axis_obj {
            out.insert(
                axis.clone(),
                parse_boundary_policy_spec(name, axis, spec_raw)?,
            );
        }
        return Ok(Some(BoundaryPolicy::PerAxis(out)));
    }
    Err(RuleEngineError::new(
        "E_RULE_PARSE",
        format!(
            "rule `{name}`: `boundary_policy` must be a string or an object with a `by_axis` field"
        ),
    ))
}

fn parse_boundary_policy_spec(
    rule_name: &str,
    axis: &str,
    v: &serde_json::Value,
) -> Result<BoundaryPolicySpec, RuleEngineError> {
    let obj = v.as_object().ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{rule_name}`: boundary_policy.by_axis.{axis} must be an object"),
        )
    })?;
    let kind_raw = obj.get("kind").and_then(|s| s.as_str()).ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!(
                "rule `{rule_name}`: boundary_policy.by_axis.{axis} missing required string `kind`"
            ),
        )
    })?;
    if !BOUNDARY_POLICY_KIND_VALUES.contains(&kind_raw) {
        return Err(RuleEngineError::new(
            "E_RULE_PARSE",
            format!(
                "rule `{rule_name}`: boundary_policy.by_axis.{axis}: unknown kind `{kind_raw}` (closed set: {})",
                BOUNDARY_POLICY_KIND_VALUES.join(", ")
            ),
        ));
    }
    let kind = BoundaryPolicyKind::from_str(kind_raw).expect("validated above");
    let mut spec = BoundaryPolicySpec::new(kind);
    if let Some(d) = obj.get("degree") {
        let n = d.as_i64().ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!(
                    "rule `{rule_name}`: boundary_policy.by_axis.{axis}.degree must be an integer"
                ),
            )
        })?;
        if !(0..=3).contains(&n) {
            return Err(RuleEngineError::new(
                "E_RULE_PARSE",
                format!(
                    "rule `{rule_name}`: boundary_policy.by_axis.{axis}.degree must be between 0 and 3, got {n}"
                ),
            ));
        }
        spec.degree = Some(n);
    }
    if let Some(s) = obj.get("description") {
        spec.description = Some(s.as_str().ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!(
                    "rule `{rule_name}`: boundary_policy.by_axis.{axis}.description must be a string"
                ),
            )
        })?.to_string());
    }
    Ok(spec)
}

fn parse_ghost_width(
    name: &str,
    v: Option<&serde_json::Value>,
) -> Result<Option<GhostWidth>, RuleEngineError> {
    let Some(v) = v else {
        return Ok(None);
    };
    if let Some(n) = v.as_i64() {
        if n < 0 {
            return Err(RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{name}`: `ghost_width` must be non-negative, got {n}"),
            ));
        }
        return Ok(Some(GhostWidth::Uniform(n)));
    }
    if let Some(obj) = v.as_object() {
        let by_axis_raw = obj.get("by_axis").ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{name}`: `ghost_width` object must have a `by_axis` field"),
            )
        })?;
        let by_axis_obj = by_axis_raw.as_object().ok_or_else(|| {
            RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{name}`: `ghost_width.by_axis` must be an object"),
            )
        })?;
        let mut out = HashMap::with_capacity(by_axis_obj.len());
        for (axis, w) in by_axis_obj {
            let n = w.as_i64().ok_or_else(|| {
                RuleEngineError::new(
                    "E_RULE_PARSE",
                    format!("rule `{name}`: ghost_width.by_axis.{axis} must be an integer"),
                )
            })?;
            if n < 0 {
                return Err(RuleEngineError::new(
                    "E_RULE_PARSE",
                    format!(
                        "rule `{name}`: ghost_width.by_axis.{axis} must be non-negative, got {n}"
                    ),
                ));
            }
            out.insert(axis.clone(), n);
        }
        return Ok(Some(GhostWidth::PerAxis(out)));
    }
    Err(RuleEngineError::new(
        "E_RULE_PARSE",
        format!(
            "rule `{name}`: `ghost_width` must be a non-negative integer or an object with a `by_axis` field"
        ),
    ))
}

fn parse_bindings(
    name: &str,
    v: Option<&serde_json::Value>,
) -> Result<Option<HashMap<String, RuleBinding>>, RuleEngineError> {
    let Some(v) = v else {
        return Ok(None);
    };
    let obj = v.as_object().ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{name}`: `bindings` must be an object"),
        )
    })?;
    let mut out = HashMap::with_capacity(obj.len());
    for (bname, bval) in obj {
        out.insert(bname.clone(), parse_rule_binding(name, bname, bval)?);
    }
    Ok(Some(out))
}

fn parse_rule_binding(
    rule_name: &str,
    binding_name: &str,
    v: &serde_json::Value,
) -> Result<RuleBinding, RuleEngineError> {
    let obj = v.as_object().ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{rule_name}`: bindings.{binding_name} must be an object"),
        )
    })?;
    let kind_raw = obj.get("kind").and_then(|s| s.as_str()).ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{rule_name}`: bindings.{binding_name} missing required string `kind`"),
        )
    })?;
    let kind = RuleBindingKind::from_str(kind_raw).ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!(
                "rule `{rule_name}`: bindings.{binding_name}: unknown kind `{kind_raw}` \
                 (closed set: static, per_step, per_cell)"
            ),
        )
    })?;
    let default = match obj.get("default") {
        Some(d) => Some(parse_expr(d)?),
        None => None,
    };
    let description = match obj.get("description") {
        Some(serde_json::Value::String(s)) => Some(s.clone()),
        Some(serde_json::Value::Null) | None => None,
        Some(_) => {
            return Err(RuleEngineError::new(
                "E_RULE_PARSE",
                format!("rule `{rule_name}`: bindings.{binding_name}.description must be a string"),
            ));
        }
    };
    Ok(RuleBinding {
        kind,
        default,
        description,
    })
}

/// Discriminate the RFC §5.2.7 `where` forms by JSON shape: array of
/// guards (legacy, selection-time) vs expression-node object (new,
/// per-query-point predicate).
fn parse_where(
    name: &str,
    v: Option<&serde_json::Value>,
) -> Result<(Vec<Guard>, Option<Expr>), RuleEngineError> {
    let Some(v) = v else {
        return Ok((Vec::new(), None));
    };
    if let Some(arr) = v.as_array() {
        let guards = arr.iter().map(parse_guard).collect::<Result<Vec<_>, _>>()?;
        return Ok((guards, None));
    }
    if let Some(obj) = v.as_object() {
        if !obj.contains_key("op") {
            return Err(RuleEngineError::new(
                "E_RULE_PARSE",
                format!(
                    "rule `{name}`: `where` object must be an expression node with an `op` field"
                ),
            ));
        }
        return Ok((Vec::new(), Some(parse_expr(v)?)));
    }
    Err(RuleEngineError::new(
        "E_RULE_PARSE",
        format!("rule `{name}`: `where` must be an array of guards or an expression object"),
    ))
}

/// Discriminate the RFC §5.2.7 `region` forms: a legacy advisory
/// string vs a scope object with a `kind` tag.
fn parse_region(
    name: &str,
    v: Option<&serde_json::Value>,
) -> Result<Option<RuleRegion>, RuleEngineError> {
    let Some(v) = v else {
        return Ok(None);
    };
    if let Some(s) = v.as_str() {
        return Ok(Some(RuleRegion::Tag(s.to_string())));
    }
    let obj = v.as_object().ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!(
                "rule `{name}`: `region` must be a string (legacy) or object (normative scope)"
            ),
        )
    })?;
    let kind = obj.get("kind").and_then(|s| s.as_str()).ok_or_else(|| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{name}`: region object must carry a `kind` field"),
        )
    })?;
    let missing = |field: &str| {
        RuleEngineError::new(
            "E_RULE_PARSE",
            format!("rule `{name}`: region.{kind} requires `{field}`"),
        )
    };
    let str_field = |field: &str| -> Result<String, RuleEngineError> {
        obj.get(field)
            .and_then(|s| s.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| missing(field))
    };
    let int_field = |field: &str| -> Result<i64, RuleEngineError> {
        obj.get(field)
            .and_then(|s| s.as_i64())
            .ok_or_else(|| missing(field))
    };
    match kind {
        "boundary" => Ok(Some(RuleRegion::Boundary {
            side: str_field("side")?,
        })),
        "mask_field" => Ok(Some(RuleRegion::MaskField {
            field: str_field("field")?,
        })),
        "index_range" => Ok(Some(RuleRegion::IndexRange {
            axis: str_field("axis")?,
            lo: int_field("lo")?,
            hi: int_field("hi")?,
        })),
        other => Err(RuleEngineError::new(
            "E_RULE_PARSE",
            format!(
                "rule `{name}`: unknown region.kind `{other}` \
                 (closed set: boundary, mask_field, index_range)"
            ),
        )),
    }
}

fn parse_guard(v: &serde_json::Value) -> Result<Guard, RuleEngineError> {
    let obj = v
        .as_object()
        .ok_or_else(|| RuleEngineError::new("E_RULE_PARSE", "guard must be an object"))?;
    let name = obj
        .get("guard")
        .and_then(|s| s.as_str())
        .ok_or_else(|| RuleEngineError::new("E_RULE_PARSE", "guard object missing `guard` field"))?
        .to_string();
    let mut params = HashMap::new();
    for (k, val) in obj {
        if k == "guard" {
            continue;
        }
        params.insert(k.clone(), val.clone());
    }
    Ok(Guard { name, params })
}

/// Parse a JSON value into an [`Expr`], preserving int-vs-float per RFC §5.4.
pub fn parse_expr(v: &serde_json::Value) -> Result<Expr, RuleEngineError> {
    use serde_json::Value;
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                // `serde_json::Number::as_i64` returns Some only for JSON
                // tokens without `.`, `e`, or `E` — matches RFC §5.4.1
                // integer grammar.
                Ok(Expr::Integer(i))
            } else if let Some(f) = n.as_f64() {
                Ok(Expr::Number(f))
            } else {
                Err(RuleEngineError::new(
                    "E_RULE_PARSE",
                    "number out of i64/f64 range",
                ))
            }
        }
        Value::String(s) => Ok(Expr::Variable(s.clone())),
        Value::Object(obj) => {
            let op = obj
                .get("op")
                .and_then(|x| x.as_str())
                .ok_or_else(|| RuleEngineError::new("E_RULE_PARSE", "operator node missing `op`"))?
                .to_string();
            let empty = Vec::new();
            let args_raw = obj.get("args").and_then(|a| a.as_array()).unwrap_or(&empty);
            let mut args = Vec::with_capacity(args_raw.len());
            for a in args_raw {
                args.push(parse_expr(a)?);
            }
            let wrt = obj
                .get("wrt")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());
            let dim = obj
                .get("dim")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());
            Ok(Expr::Operator(ExpressionNode {
                op,
                args,
                wrt,
                dim,
                ..Default::default()
            }))
        }
        _ => Err(RuleEngineError::new(
            "E_RULE_PARSE",
            format!("cannot parse expression of JSON type {v}"),
        )),
    }
}

// ============================================================================
// Unrewritten PDE op check (§11 Step 7)
// ============================================================================

const PDE_OPS: &[&str] = &["grad", "div", "laplacian", "D", "bc"];

/// Scan `expr` for leftover PDE ops after rewriting. Returns
/// `E_UNREWRITTEN_PDE_OP` if any are found.
pub fn check_unrewritten_pde_ops(expr: &Expr) -> Result<(), RuleEngineError> {
    if let Some(op) = find_pde_op(expr) {
        return Err(RuleEngineError::new(
            "E_UNREWRITTEN_PDE_OP",
            format!(
                "equation still contains PDE op '{op}' after rewrite; \
                 annotate the equation with 'passthrough: true' to opt out"
            ),
        ));
    }
    Ok(())
}

fn find_pde_op(e: &Expr) -> Option<&str> {
    if let Expr::Operator(node) = e {
        for op in PDE_OPS {
            if node.op == *op {
                return Some(op);
            }
        }
        for a in &node.args {
            if let Some(x) = find_pde_op(a) {
                return Some(x);
            }
        }
    }
    None
}

// ============================================================================
// Unit tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canonicalize::canonical_json;

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args,
            ..Default::default()
        })
    }

    fn op_with(name: &str, args: Vec<Expr>, wrt: Option<&str>, dim: Option<&str>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args,
            wrt: wrt.map(|s| s.to_string()),
            dim: dim.map(|s| s.to_string()),
            ..Default::default()
        })
    }

    fn var(s: &str) -> Expr {
        Expr::Variable(s.to_string())
    }

    #[test]
    fn match_and_replace() {
        let rule = Rule::new(
            "add_zero",
            op("+", vec![var("$a"), Expr::Integer(0)]),
            var("$a"),
        );
        let seed = op("+", vec![var("x"), Expr::Integer(0)]);
        let out = rewrite(&seed, &[rule], &RuleContext::default(), 32).unwrap();
        assert_eq!(canonical_json(&out).unwrap(), "\"x\"");
    }

    #[test]
    fn non_linear_match() {
        let rule = Rule::new(
            "self_minus",
            op("-", vec![var("$a"), var("$a")]),
            Expr::Integer(0),
        );
        let yes = op("-", vec![var("x"), var("x")]);
        assert!(match_pattern(&rule.pattern, &yes).is_some());
        let no = op("-", vec![var("x"), var("y")]);
        assert!(match_pattern(&rule.pattern, &no).is_none());
    }

    #[test]
    fn sibling_field_pvar() {
        let pat = op_with("D", vec![var("$u")], Some("$x"), None);
        let repl = op("index", vec![var("$u"), var("$x")]);
        let rule = Rule::new("d_to_index", pat, repl);
        let seed = op_with("D", vec![var("T")], Some("t"), None);
        let out = rewrite(&seed, &[rule], &RuleContext::default(), 32).unwrap();
        assert_eq!(
            canonical_json(&out).unwrap(),
            "{\"args\":[\"T\",\"t\"],\"op\":\"index\"}"
        );
    }

    #[test]
    fn fixed_point_reduce() {
        let rule = Rule::new(
            "add_zero",
            op("+", vec![var("$a"), Expr::Integer(0)]),
            var("$a"),
        );
        let seed = op(
            "+",
            vec![op("+", vec![var("x"), Expr::Integer(0)]), Expr::Integer(0)],
        );
        let out = rewrite(&seed, &[rule], &RuleContext::default(), 32).unwrap();
        assert_eq!(canonical_json(&out).unwrap(), "\"x\"");
    }

    #[test]
    fn not_converged_error() {
        let rule = Rule::new(
            "explode",
            var("$a"),
            op("+", vec![var("$a"), Expr::Integer(0)]),
        );
        let err = rewrite(&var("x"), &[rule], &RuleContext::default(), 3).unwrap_err();
        assert_eq!(err.code(), "E_RULES_NOT_CONVERGED");
    }

    #[test]
    fn top_down_seal() {
        // (x+x)+(x+x) — rule $a+$a -> 2*$a fires once at root, seals,
        // then next pass fires on the remaining (x+x) once.
        let rule = Rule::new(
            "double",
            op("+", vec![var("$a"), var("$a")]),
            op("*", vec![Expr::Integer(2), var("$a")]),
        );
        let inner = op("+", vec![var("x"), var("x")]);
        let seed = op("+", vec![inner.clone(), inner]);
        let out = rewrite(&seed, &[rule], &RuleContext::default(), 32).unwrap();
        let want = op(
            "*",
            vec![Expr::Integer(2), op("*", vec![Expr::Integer(2), var("x")])],
        );
        assert_eq!(
            canonical_json(&out).unwrap(),
            canonical_json(&want).unwrap()
        );
    }

    #[test]
    fn pde_op_unrewritten() {
        let expr = op_with("grad", vec![var("T")], None, Some("x"));
        let err = check_unrewritten_pde_ops(&expr).unwrap_err();
        assert_eq!(err.code(), "E_UNREWRITTEN_PDE_OP");
        let ok = op("index", vec![var("T"), var("x")]);
        assert!(check_unrewritten_pde_ops(&ok).is_ok());
    }

    #[test]
    fn guard_var_has_grid_bind() {
        // Rule: grad($u, dim=$x) -> $u when $u.grid == g1
        let pat = op_with("grad", vec![var("$u")], None, Some("$x"));
        let rule = Rule {
            name: "drop".into(),
            pattern: pat,
            where_: vec![Guard {
                name: "var_has_grid".into(),
                params: {
                    let mut m = HashMap::new();
                    m.insert("pvar".into(), serde_json::json!("$u"));
                    m.insert("grid".into(), serde_json::json!("g1"));
                    m
                },
            }],
            replacement: var("$u"),
            region: None,
            where_expr: None,
            boundary_policy: None,
            ghost_width: None,
            bindings: None,
        };
        let mut ctx = RuleContext::default();
        ctx.variables.insert(
            "T".into(),
            VariableMeta {
                grid: Some("g1".into()),
                ..Default::default()
            },
        );
        let seed = op_with("grad", vec![var("T")], None, Some("x"));
        let out = rewrite(&seed, std::slice::from_ref(&rule), &ctx, 32).unwrap();
        assert_eq!(canonical_json(&out).unwrap(), "\"T\"");
        // Wrong grid: does not fire.
        let mut ctx2 = RuleContext::default();
        ctx2.variables.insert(
            "T".into(),
            VariableMeta {
                grid: Some("g2".into()),
                ..Default::default()
            },
        );
        let out2 = rewrite(&seed, &[rule], &ctx2, 32).unwrap();
        assert!(matches!(out2, Expr::Operator(_)));
    }

    /// Conformance fixture consumer — the Julia and Rust bindings are both
    /// required by RFC §13.1 Step 1 to emit byte-identical canonical output.
    /// This test walks the same manifest the Julia conformance harness uses.
    #[test]
    fn rule_engine_conformance_fixtures() {
        use std::path::PathBuf;
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        let repo_root: PathBuf = PathBuf::from(manifest_dir)
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        let dir = repo_root
            .join("tests")
            .join("conformance")
            .join("discretization")
            .join("infra")
            .join("rule_engine");
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

            let rules = parse_rules(&fixture["rules"]).expect("parse_rules");
            let input = parse_expr(&fixture["input"]).expect("parse_expr");
            let max_passes = fixture
                .get("max_passes")
                .and_then(|v| v.as_u64())
                .map(|n| n as usize)
                .unwrap_or(DEFAULT_MAX_PASSES);
            let ctx = build_test_context(&fixture);

            let expect = &fixture["expect"];
            let kind = expect["kind"].as_str().unwrap();
            match kind {
                "output" => {
                    let out = rewrite(&input, &rules, &ctx, max_passes)
                        .unwrap_or_else(|e| panic!("fixture {id}: {e}"));
                    let got = canonical_json(&out).expect("canonicalize output");
                    let want = expect["canonical_json"].as_str().unwrap();
                    assert_eq!(got, want, "fixture {id}: got {got}, want {want}");
                }
                "error" => {
                    let err = rewrite(&input, &rules, &ctx, max_passes)
                        .expect_err("expected rule-engine error");
                    let want = expect["code"].as_str().unwrap();
                    assert_eq!(err.code(), want, "fixture {id}: code mismatch");
                }
                other => panic!("fixture {id}: unknown expect.kind {other}"),
            }
        }
    }

    fn build_test_context(fixture: &serde_json::Value) -> RuleContext {
        let Some(ctx) = fixture.get("context") else {
            return RuleContext::default();
        };
        let mut out = RuleContext::default();
        if let Some(grids) = ctx.get("grids").and_then(|v| v.as_object()) {
            for (k, v) in grids {
                let mut meta = GridMeta::default();
                if let Some(arr) = v.get("spatial_dims").and_then(|x| x.as_array()) {
                    meta.spatial_dims = arr
                        .iter()
                        .filter_map(|s| s.as_str().map(|x| x.to_string()))
                        .collect();
                }
                if let Some(arr) = v.get("periodic_dims").and_then(|x| x.as_array()) {
                    meta.periodic_dims = arr
                        .iter()
                        .filter_map(|s| s.as_str().map(|x| x.to_string()))
                        .collect();
                }
                if let Some(arr) = v.get("nonuniform_dims").and_then(|x| x.as_array()) {
                    meta.nonuniform_dims = arr
                        .iter()
                        .filter_map(|s| s.as_str().map(|x| x.to_string()))
                        .collect();
                }
                if let Some(bounds) = v.get("dim_bounds").and_then(|x| x.as_object()) {
                    for (dk, dv) in bounds {
                        if let Some(arr) = dv.as_array()
                            && arr.len() == 2
                            && let (Some(lo), Some(hi)) = (arr[0].as_i64(), arr[1].as_i64())
                        {
                            meta.dim_bounds.insert(dk.clone(), [lo, hi]);
                        }
                    }
                }
                if let Some(sizes) = v.get("dim_sizes").and_then(|x| x.as_object()) {
                    for (dk, dv) in sizes {
                        if let Some(n) = dv.as_i64() {
                            meta.dim_sizes.insert(dk.clone(), n);
                        }
                    }
                }
                out.grids.insert(k.clone(), meta);
            }
        }
        if let Some(qp) = ctx.get("query_point").and_then(|v| v.as_object()) {
            for (k, v) in qp {
                if let Some(i) = v.as_i64() {
                    out.query_point.insert(k.clone(), i);
                }
            }
        }
        if let Some(g) = ctx.get("grid_name").and_then(|v| v.as_str()) {
            out.grid_name = Some(g.to_string());
        }
        if let Some(vars) = ctx.get("variables").and_then(|v| v.as_object()) {
            for (k, v) in vars {
                let mut meta = VariableMeta {
                    grid: v
                        .get("grid")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string()),
                    location: v
                        .get("location")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string()),
                    ..Default::default()
                };
                if let Some(arr) = v.get("shape").and_then(|x| x.as_array()) {
                    meta.shape = Some(
                        arr.iter()
                            .filter_map(|s| s.as_str().map(|x| x.to_string()))
                            .collect(),
                    );
                }
                out.variables.insert(k.clone(), meta);
            }
        }
        if let Some(masks) = ctx.get("mask_fields").and_then(|v| v.as_object()) {
            for (k, v) in masks {
                let Some(points) = v.as_array() else { continue };
                let mut parsed = Vec::with_capacity(points.len());
                for entry in points {
                    let Some(obj) = entry.as_object() else {
                        continue;
                    };
                    let mut pt = HashMap::new();
                    for (axis, val) in obj {
                        if let Some(i) = val.as_i64() {
                            pt.insert(axis.clone(), i);
                        }
                    }
                    parsed.push(pt);
                }
                out.mask_fields.insert(k.clone(), parsed);
            }
        }
        out
    }

    #[test]
    fn parse_rules_object_and_array() {
        let obj = serde_json::json!({
            "a": {"pattern": {"op": "+", "args": ["$x", 0]}, "replacement": "$x"}
        });
        let rs = parse_rules(&obj).unwrap();
        assert_eq!(rs.len(), 1);
        assert_eq!(rs[0].name, "a");

        let arr = serde_json::json!([
            {"name": "first",  "pattern": {"op": "*", "args": ["$a", 0]}, "replacement": 0},
            {"name": "second", "pattern": {"op": "+", "args": ["$a", 0]}, "replacement": "$a"}
        ]);
        let rs2 = parse_rules(&arr).unwrap();
        assert_eq!(
            rs2.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
            vec!["first", "second"]
        );
    }

    // RFC §5.2.8 / §7 (esm-bet) — boundary_policy + ghost_width fields.

    fn parse_one(v: serde_json::Value) -> Result<Rule, RuleEngineError> {
        parse_rules(&serde_json::json!([v])).map(|mut rs| rs.remove(0))
    }

    #[test]
    fn boundary_policy_string_form_all_kinds() {
        for kind in [
            "periodic",
            "reflecting",
            "one_sided_extrapolation",
            "prescribed",
            "ghosted",
            "neumann_zero",
            "extrapolate",
        ] {
            let r = parse_one(serde_json::json!({
                "name": "r",
                "pattern": "$a",
                "replacement": "$a",
                "boundary_policy": kind,
            }))
            .unwrap();
            match r.boundary_policy.unwrap() {
                BoundaryPolicy::Uniform(k) => assert_eq!(k.as_str(), kind),
                _ => panic!("expected uniform form"),
            }
        }
    }

    #[test]
    fn boundary_policy_string_form_rejects_unknown() {
        let err = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "boundary_policy": "nope",
        }))
        .unwrap_err();
        assert_eq!(err.code, "E_RULE_PARSE");
    }

    #[test]
    fn boundary_policy_per_axis_one_sided_extrapolation_with_degree() {
        let r = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "boundary_policy": {
                "by_axis": {
                    "x": {"kind": "one_sided_extrapolation", "degree": 2}
                }
            },
        }))
        .unwrap();
        let map = match r.boundary_policy.unwrap() {
            BoundaryPolicy::PerAxis(m) => m,
            _ => panic!("expected per-axis form"),
        };
        assert!(matches!(
            map["x"].kind,
            BoundaryPolicyKind::OneSidedExtrapolation
        ));
        assert_eq!(map["x"].degree, Some(2));
    }

    #[test]
    fn boundary_policy_rejects_out_of_range_degree() {
        let err = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "boundary_policy": {
                "by_axis": {"x": {"kind": "one_sided_extrapolation", "degree": 5}}
            },
        }))
        .unwrap_err();
        assert_eq!(err.code, "E_RULE_PARSE");
    }

    #[test]
    fn ghost_width_scalar_form() {
        let r = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "ghost_width": 3,
        }))
        .unwrap();
        match r.ghost_width.unwrap() {
            GhostWidth::Uniform(n) => assert_eq!(n, 3),
            _ => panic!("expected uniform form"),
        }
    }

    #[test]
    fn ghost_width_per_axis_form() {
        let r = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "ghost_width": {"by_axis": {"xi": 3, "eta": 2}},
        }))
        .unwrap();
        let map = match r.ghost_width.unwrap() {
            GhostWidth::PerAxis(m) => m,
            _ => panic!("expected per-axis form"),
        };
        assert_eq!(map["xi"], 3);
        assert_eq!(map["eta"], 2);
    }

    #[test]
    fn ghost_width_rejects_negative() {
        let err = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "ghost_width": -1,
        }))
        .unwrap_err();
        assert_eq!(err.code, "E_RULE_PARSE");
    }

    #[test]
    fn ghost_width_rejects_string() {
        let err = parse_one(serde_json::json!({
            "name": "r",
            "pattern": "$a",
            "replacement": "$a",
            "ghost_width": "3",
        }))
        .unwrap_err();
        assert_eq!(err.code, "E_RULE_PARSE");
    }
}
