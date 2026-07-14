//! Unit parsing and dimensional analysis.
//!
//! This module implements a hand-rolled dimensional algebra for ESM
//! expressions. Two layers are exposed:
//!
//! 1. [`parse_unit`] parses a unit string (e.g. `"kg*m/s^2"`, `"J/(mol*K)"`)
//!    into a [`Unit`] carrying a `HashMap<Dimension, i32>` and a scale
//!    factor. Used for variable/parameter unit metadata.
//!
//! 2. [`Unit::propagate`] walks an [`Expr`] AST and returns the resulting
//!    [`Unit`] for the whole expression. This is the expression-level
//!    dimensional propagation that lets a caller verify, for example, that
//!    `D(h)/dt` has the same dimensions as a `v` of units `m/s`.
//!
//! The propagation rules match the Python implementation
//! (`earthsci_ast/units.py::_get_expression_dimension`) and the Julia
//! implementation (`EarthSciAST.jl/src/units.jl::
//! get_expression_dimensions`).

use crate::types::{Equation, Expr, ExpressionNode};
use std::collections::HashMap;
use thiserror::Error;

/// Represents a physical unit with dimensions
#[derive(Debug, Clone, PartialEq)]
pub struct Unit {
    /// Base dimensions with their powers
    dimensions: HashMap<Dimension, i32>,
    /// Scale factor for unit conversions
    scale: f64,
}

/// Base physical dimensions
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Dimension {
    Mass,        // M
    Length,      // L
    Time,        // T
    Current,     // I (electric current)
    Temperature, // Θ (thermodynamic temperature)
    Amount,      // N (amount of substance)
    Luminosity,  // J (luminous intensity)
}

/// Error types for unit operations
#[derive(Debug, Clone, PartialEq, Error)]
pub enum UnitError {
    #[error("Parse error: {0}")]
    ParseError(String),
    #[error("Dimension mismatch: {0}")]
    DimensionMismatch(String),
    #[error("Unknown unit: {0}")]
    UnknownUnit(String),
}

/// Severity of a dimensional finding — the cross-binding policy that decides
/// whether a finding blocks validation.
///
/// The split is drawn at *provability*, and it is decided AT THE POINT the
/// finding is raised (mirroring the TypeScript reference, whose `UnitWarning`
/// carries the same classification):
///
/// * [`UnitSeverity::Error`] — a PROVABLE dimensional inconsistency: every
///   operand's dimension was determined, and they are incompatible. That is a
///   defect in the FILE, so it is promoted by `structural.rs` to a
///   `unit_inconsistency` structural error and makes `is_valid` false. The
///   shared corpus requires this: `tests/invalid/expected_errors.json` pins the
///   `units_*.esm` fixtures as `is_valid: false` with a structural error, so a
///   binding that keeps them as warnings ACCEPTS files the corpus pins invalid.
///
/// * [`UnitSeverity::Analysis`] — the checker could not DETERMINE a dimension
///   (unknown variable, unparseable unit string, symbolic/non-literal exponent,
///   an operator with no dimensional rule). This reports what the checker could
///   not conclude, NOT a defect in the file, so it stays a non-blocking warning
///   and the affected subexpression propagates as [`Dim::Unknown`].
///
/// An unknown *variable* stays `Analysis` here only because it is already a
/// hard `undefined_variable` structural error — the file is still rejected; we
/// just do not double-report it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnitSeverity {
    /// Provable dimensional inconsistency — blocks validation.
    Error,
    /// Undeterminable dimension — non-blocking warning.
    Analysis,
}

/// A single dimensional finding produced while propagating an expression.
#[derive(Debug, Clone, PartialEq)]
pub struct UnitFinding {
    /// Whether this finding blocks validation. See [`UnitSeverity`].
    pub severity: UnitSeverity,
    /// Human-readable description of the finding.
    pub message: String,
}

impl UnitFinding {
    fn error(message: impl Into<String>) -> Self {
        UnitFinding {
            severity: UnitSeverity::Error,
            message: message.into(),
        }
    }

    fn analysis(message: impl Into<String>) -> Self {
        UnitFinding {
            severity: UnitSeverity::Analysis,
            message: message.into(),
        }
    }

    /// True when this finding is a provable inconsistency.
    pub fn is_error(&self) -> bool {
        self.severity == UnitSeverity::Error
    }
}

/// The dimension of a subexpression: either determined, or not.
///
/// `Unknown` is what makes multi-finding collection sound. Propagation NEVER
/// aborts an expression at the first finding — it records the finding, yields
/// `Unknown` for that subtree, and keeps walking its siblings. An
/// undeterminable operand therefore cannot SUPPRESS a provable mismatch
/// elsewhere in the same expression (the old `Result`-based propagation bailed
/// at the first `Err`, so a single unknown variable hid every real error after
/// it), and it equally cannot MANUFACTURE one: `Unknown` compares against
/// nothing, so no finding is raised for it.
#[derive(Debug, Clone, PartialEq)]
enum Dim {
    /// Dimension determined.
    Known(Unit),
    /// Dimension could not be determined; an `Analysis` finding was recorded.
    Unknown,
}

impl Dim {
    fn known(&self) -> Option<&Unit> {
        match self {
            Dim::Known(u) => Some(u),
            Dim::Unknown => None,
        }
    }
}

impl Unit {
    /// Create a dimensionless unit
    pub fn dimensionless() -> Self {
        Unit {
            dimensions: HashMap::new(),
            scale: 1.0,
        }
    }

    /// Create a unit with a single dimension
    pub fn base(dimension: Dimension, power: i32, scale: f64) -> Self {
        let mut dimensions = HashMap::new();
        if power != 0 {
            dimensions.insert(dimension, power);
        }
        Unit { dimensions, scale }
    }

    /// Check if two units have compatible dimensions
    pub fn is_compatible(&self, other: &Unit) -> bool {
        self.dimensions == other.dimensions
    }

    /// Check if this unit is dimensionless
    pub fn is_dimensionless(&self) -> bool {
        self.dimensions.is_empty()
    }

    /// Multiply two units
    pub fn multiply(&self, other: &Unit) -> Unit {
        let mut dimensions = self.dimensions.clone();

        for (dim, power) in &other.dimensions {
            let entry = dimensions.entry(dim.clone()).or_insert(0);
            *entry += power;
            if *entry == 0 {
                dimensions.remove(dim);
            }
        }

        Unit {
            dimensions,
            scale: self.scale * other.scale,
        }
    }

    /// Divide two units
    pub fn divide(&self, other: &Unit) -> Unit {
        let mut dimensions = self.dimensions.clone();

        for (dim, power) in &other.dimensions {
            let entry = dimensions.entry(dim.clone()).or_insert(0);
            *entry -= power;
            if *entry == 0 {
                dimensions.remove(dim);
            }
        }

        Unit {
            dimensions,
            scale: self.scale / other.scale,
        }
    }

    /// Raise unit to a power
    pub fn power(&self, exponent: i32) -> Unit {
        let dimensions = self
            .dimensions
            .iter()
            .map(|(dim, power)| (dim.clone(), power * exponent))
            .filter(|(_, power)| *power != 0)
            .collect();

        Unit {
            dimensions,
            scale: self.scale.powi(exponent),
        }
    }

    /// Propagate units through an expression AST.
    ///
    /// Given a variable→unit environment, returns the [`Unit`] of the whole
    /// expression by recursively walking its AST. Returns a
    /// [`UnitError::DimensionMismatch`] when the expression is dimensionally
    /// inconsistent (e.g. adding `m` to `s`, using a non-dimensionless
    /// exponent, or passing a dimensional argument to `exp`/`log`/`sin`).
    ///
    /// The `t` identifier is treated as the implicit time variable with units
    /// of seconds if not otherwise present in `env`.
    ///
    /// This is the single-outcome (`Result`) view, kept for callers that only
    /// need "does this expression have a unit". Validation uses
    /// [`check_expression_dimensions`], which reports EVERY finding rather than
    /// only the first.
    ///
    /// # Arguments
    ///
    /// * `expr` - Expression to analyse.
    /// * `env`  - Map from variable name to its [`Unit`].
    pub fn propagate(expr: &Expr, env: &HashMap<String, Unit>) -> Result<Unit, UnitError> {
        Self::propagate_with_coords(expr, env, None)
    }

    /// Like [`Unit::propagate`] but additionally consults a map of spatial
    /// coordinate name → declared [`Unit`] when resolving `grad`/`div`/
    /// `laplacian` operators' denominator. When `coords` is `None` or does not
    /// contain the node's `dim`, falls back to the legacy metre denominator.
    pub fn propagate_with_coords(
        expr: &Expr,
        env: &HashMap<String, Unit>,
        coords: Option<&HashMap<String, Unit>>,
    ) -> Result<Unit, UnitError> {
        let mut findings = Vec::new();
        let dim = propagate_dim(expr, env, coords, &mut findings);
        // A provable inconsistency outranks an undeterminable dimension.
        if let Some(err) = findings.iter().find(|f| f.is_error()) {
            return Err(UnitError::DimensionMismatch(err.message.clone()));
        }
        match dim {
            Dim::Known(unit) => Ok(unit),
            Dim::Unknown => Err(UnitError::UnknownUnit(
                findings
                    .first()
                    .map(|f| f.message.clone())
                    .unwrap_or_else(|| "undetermined dimension".to_string()),
            )),
        }
    }
}

/// Propagate the dimension of `expr`, recording every finding in `findings`.
///
/// Never aborts: an undeterminable subtree yields [`Dim::Unknown`] and the walk
/// continues, so all provable mismatches in the expression are reported.
fn propagate_dim(
    expr: &Expr,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    match expr {
        // A BARE NUMERIC LITERAL has an INDETERMINATE dimension, not a
        // dimensionless one: nothing in the AST says whether `273.15` is a pure
        // number or a temperature offset, or whether `6.022e23` is Avogadro's
        // constant. Calling it dimensionless manufactured a mismatch on every
        // line of the valid corpus that uses an implicit-unit constant
        // (`T - 273.15`, `1 - phi`).
        //
        // This matters BECAUSE these findings are now hard errors: a checker
        // that fails the build must not fabricate a dimension it cannot know.
        // It costs nothing on the pinned invalid corpus — every fixture there
        // states its inconsistency between DECLARED quantities (`length + mass`,
        // `ln(mass)`, `m^kg`), never via a literal. Literals still behave
        // correctly wherever their meaning IS determined: additively they are
        // neutral and adopt their sibling's dimension, an all-literal expression
        // is dimensionless, and an exponent is read BY VALUE.
        Expr::Number(_) | Expr::Integer(_) => Dim::Unknown,
        Expr::Variable(name) => {
            if let Some(unit) = env.get(name) {
                Dim::Known(unit.clone())
            } else if name == "t" {
                // Implicit time variable.
                Dim::Known(Unit::base(Dimension::Time, 1, 1.0))
            } else {
                // Dimension unknown — but NOT reported here, because the reason
                // is always already reported at the variable itself, and this
                // path fires once per REFERENCE:
                //   * genuinely undeclared  ⇒ hard `undefined_variable` error;
                //   * unparseable unit      ⇒ `build_unit_env` warns once;
                //   * no `units` field      ⇒ a legitimate choice, not a defect.
                // Re-reporting per reference would only duplicate those.
                Dim::Unknown
            }
        }
        Expr::Operator(op) => propagate_operator_dim(op, env, coords, findings),
    }
}

/// Propagate every argument, returning their dimensions positionally.
fn propagate_args(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Vec<Dim> {
    op.args
        .iter()
        .map(|a| propagate_dim(a, env, coords, findings))
        .collect()
}

/// Require exactly `n` arguments. Arity is enforced by the operator registry
/// and the schema; here a wrong arity simply means we cannot analyse the node,
/// so it is an `Analysis` finding rather than a dimensional defect.
fn require_arity(op: &ExpressionNode, n: usize, findings: &mut Vec<UnitFinding>) -> bool {
    if op.args.len() == n {
        return true;
    }
    findings.push(UnitFinding::analysis(format!(
        "'{}' expects {} argument(s) but has {}; not dimension-checked",
        op.op,
        n,
        op.args.len()
    )));
    false
}

/// Dispatch one operator node to its family's propagation helper. Kept as a
/// thin match so each family's dimensional rules live in one named function;
/// the rules mirror the Python (`units.py::_get_expression_dimension`) and
/// Julia (`units.jl::get_expression_dimensions`) implementations.
fn propagate_operator_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    match op.op.as_str() {
        "+" | "-" => propagate_additive_dim(op, env, coords, findings),
        "*" | "/" => propagate_multiplicative_dim(op, env, coords, findings),
        "^" | "power" | "pow" => propagate_power_dim(op, env, coords, findings),
        "D" | "ic" => propagate_calculus_dim(op, env, coords, findings),
        "grad" | "div" | "laplacian" => propagate_spatial_dim(op, env, coords, findings),
        "exp" | "log" | "log10" | "ln" | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh" => {
            propagate_transcendental_dim(op, env, coords, findings)
        }
        "sqrt" => propagate_sqrt_dim(op, env, coords, findings),
        // abs/sign/floor/ceil preserve dimensions; `Pre` is an initial-value
        // marker — same dimensions as its argument.
        "abs" | "floor" | "ceil" | "round" | "sign" | "Pre" => {
            if !require_arity(op, 1, findings) {
                return Dim::Unknown;
            }
            propagate_dim(&op.args[0], env, coords, findings)
        }
        "min" | "max" => propagate_matching_dim(op, env, coords, findings),
        "atan2" => {
            if !require_arity(op, 2, findings) {
                return Dim::Unknown;
            }
            // Both arguments must share dimensions (their ratio is the angle);
            // the result is dimensionless.
            propagate_matching_dim(op, env, coords, findings);
            Dim::Known(Unit::dimensionless())
        }
        "ifelse" => propagate_ifelse_dim(op, env, coords, findings),
        ">" | "<" | ">=" | "<=" | "==" | "!=" => {
            if !require_arity(op, 2, findings) {
                return Dim::Known(Unit::dimensionless());
            }
            // Operands must be comparable; the flag itself is dimensionless.
            propagate_matching_dim(op, env, coords, findings);
            Dim::Known(Unit::dimensionless())
        }
        "and" | "or" | "not" => Dim::Known(Unit::dimensionless()),
        // Array operators: propagate the element dimension. Shape and
        // indexing are orthogonal to dimension (see gt-t5c / gt-vt3 — shapes
        // are a separate concern from unit checking).
        "aggregate" | "makearray" | "index" | "reshape" | "transpose" | "concat" | "broadcast" => {
            propagate_array_dim(op, env, coords, findings)
        }
        // No dimensional rule for this operator. We cannot conclude anything
        // about the file, so this is an `Analysis` finding and the node's
        // dimension is unknown — NOT a silent `dimensionless`, which would
        // manufacture false mismatches in the enclosing expression.
        other => {
            findings.push(UnitFinding::analysis(format!(
                "Operator '{other}' has no dimensional rule; its dimension is unknown"
            )));
            Dim::Unknown
        }
    }
}

/// True for a bare numeric literal, which is dimensionally NEUTRAL in an
/// additive position rather than dimensionless. See [`propagate_dim`].
fn is_literal(expr: &Expr) -> bool {
    matches!(expr, Expr::Number(_) | Expr::Integer(_))
}

/// Report a provable mismatch among the operands that DID resolve, and return
/// the shared dimension. Used by `+`/`-`, `min`/`max`, comparisons and `atan2`.
///
/// Two operands are only ever compared when BOTH dimensions were determined —
/// an undeterminable operand is skipped, never assumed dimensionless, so it can
/// neither hide nor manufacture a mismatch.
///
/// Bare numeric literals are skipped entirely: they adopt the dimension of what
/// they are combined with (`T - 273.15` is a temperature). If EVERY operand is
/// a literal (`1 + 2`, unary `-1`), the result is dimensionless.
fn propagate_matching_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    let mut first: Option<Unit> = None;
    let mut saw_non_literal = false;
    for arg in &op.args {
        if is_literal(arg) {
            continue;
        }
        saw_non_literal = true;
        let dim = propagate_dim(arg, env, coords, findings);
        let Some(unit) = dim.known() else {
            continue;
        };
        match &first {
            None => first = Some(unit.clone()),
            Some(f) if !f.is_compatible(unit) => {
                findings.push(UnitFinding::error(format!(
                    "Incompatible dimensions in '{}': {} vs {}",
                    op.op,
                    describe(f),
                    describe(unit)
                )));
            }
            _ => {}
        }
    }
    if !saw_non_literal {
        return Dim::Known(Unit::dimensionless());
    }
    match first {
        Some(unit) => Dim::Known(unit),
        None => Dim::Unknown,
    }
}

/// `+` / `-`: every operand must share dimensions; the result carries them.
/// A unary minus propagates its single argument unchanged.
fn propagate_additive_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if op.args.is_empty() {
        return Dim::Known(Unit::dimensionless());
    }
    // Unary minus: propagate the single argument.
    if op.op == "-" && op.args.len() == 1 {
        return propagate_dim(&op.args[0], env, coords, findings);
    }
    propagate_matching_dim(op, env, coords, findings)
}

/// `*` / `/`: dimensions multiply / divide, no compatibility requirement.
fn propagate_multiplicative_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    let dims = propagate_args(op, env, coords, findings);
    if op.op == "*" {
        let mut result = Unit::dimensionless();
        for d in &dims {
            match d.known() {
                Some(u) => result = result.multiply(u),
                None => return Dim::Unknown,
            }
        }
        return Dim::Known(result);
    }
    if !require_arity(op, 2, findings) {
        return Dim::Unknown;
    }
    match (dims[0].known(), dims[1].known()) {
        (Some(num), Some(den)) => Dim::Known(num.divide(den)),
        _ => Dim::Unknown,
    }
}

/// `^` / `power` / `pow`: the exponent must be dimensionless; a dimensional
/// base additionally requires a literal integer exponent (only integer powers
/// of dimensions are representable).
fn propagate_power_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 2, findings) {
        return Dim::Unknown;
    }
    let base = propagate_dim(&op.args[0], env, coords, findings);
    let exp = propagate_dim(&op.args[1], env, coords, findings);

    // A dimensional exponent is provably wrong regardless of the base.
    if let Some(e) = exp.known()
        && !e.is_dimensionless()
    {
        findings.push(UnitFinding::error(format!(
            "Exponent in '{}' must be dimensionless, got {}",
            op.op,
            describe(e)
        )));
        return Dim::Unknown;
    }

    let Some(base_unit) = base.known() else {
        return Dim::Unknown;
    };
    // A dimensionless base stays dimensionless under any exponent, so a
    // non-literal exponent is only a problem for a DIMENSIONAL base.
    if base_unit.is_dimensionless() {
        return Dim::Known(Unit::dimensionless());
    }

    // The exponent is read BY VALUE, not by dimension — a literal's dimension is
    // indeterminate, but its VALUE is exactly what a power needs. It may arrive
    // as EITHER `Expr::Number` (JSON `2.0`) or `Expr::Integer` (JSON `2`).
    let literal_exp = match &op.args[1] {
        Expr::Integer(i) => Some(*i as f64),
        Expr::Number(n) => Some(*n),
        _ => None,
    };
    match literal_exp {
        Some(n) if n.fract() == 0.0 => Dim::Known(base_unit.power(n as i32)),
        // A fractional power of a dimensional quantity (`m^0.5`) is real, but
        // our integer-power `Unit` cannot represent it — a limitation of the
        // checker, not a defect in the file.
        Some(n) => {
            findings.push(UnitFinding::analysis(format!(
                "Non-integer exponent {n} on a dimensional quantity is not representable; \
                 its dimension is unknown"
            )));
            Dim::Unknown
        }
        // Symbolic exponent (`x^n` for a parameter `n`): the resulting
        // dimension depends on a value we do not have. Undeterminable, NOT a
        // mismatch.
        None => {
            findings.push(UnitFinding::analysis(format!(
                "Exponent of '{}' is not a literal, so the dimension of a dimensional \
                 base is unknown",
                op.op
            )));
            Dim::Unknown
        }
    }
}

/// Calculus-family operators: the time/coordinate derivative `D` divides its
/// argument's dimensions by the `wrt` variable's, and the initial-condition
/// marker `ic` (v0.8.0) is dimension-preserving — the initial value of a field
/// carries the same units as the field itself.
fn propagate_calculus_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 1, findings) {
        return Dim::Unknown;
    }
    let arg = propagate_dim(&op.args[0], env, coords, findings);
    if op.op == "ic" {
        return arg;
    }
    let wrt = op.wrt.as_deref().unwrap_or("t");
    // The independent variable's unit is only known if it was DECLARED. We do
    // not assume an undeclared `t` means seconds: that would give `D(x)/dt` a
    // dimension of `[x]/second`, and every dimensionless toy model
    // (`D(x)/dt = -x`, the idiom used across the shared corpus) would then look
    // like a mismatch of `time^-1` against `dimensionless`. An undeclared
    // independent variable leaves the derivative INDETERMINATE here; the
    // equation-level time-ratio rule in `check_equation_dimensions` still
    // catches derivative equations that no time unit could reconcile.
    let (Some(arg_unit), Some(wrt_unit)) = (arg.known(), env.get(wrt)) else {
        return Dim::Unknown;
    };
    Dim::Known(arg_unit.divide(wrt_unit))
}

/// True when `expr` is `D(x)` taken with respect to an UNDECLARED independent
/// variable, which makes its dimension indeterminate. Mirrors the TypeScript
/// reference (`units.ts::derivativeOfUndeclaredTime`).
fn derivative_of_undeclared_time<'a>(
    expr: &'a Expr,
    env: &HashMap<String, Unit>,
) -> Option<&'a Expr> {
    let Expr::Operator(op) = expr else {
        return None;
    };
    if op.op != "D" || op.args.len() != 1 {
        return None;
    }
    let wrt = op.wrt.as_deref().unwrap_or("t");
    (!env.contains_key(wrt)).then(|| &op.args[0])
}

/// The weaker-but-still-provable rule for `d(state)/dt = rhs` when the time
/// unit is unknown: whatever time unit `t` carries, it can only ever contribute
/// powers of TIME to the ratio. So if `dims(state) / dims(rhs)` contains any
/// NON-time dimension, no choice of time unit could reconcile the two sides and
/// the equation is provably inconsistent. A ratio that is a pure power of time
/// (including time^0) is accepted. Mirrors `units.ts::derivativeTimeMismatch`.
fn derivative_time_mismatch(state: &Unit, rhs: &Unit) -> Option<String> {
    let ratio = state.divide(rhs);
    let unreconcilable = ratio
        .dimensions
        .iter()
        .any(|(d, p)| *d != Dimension::Time && *p != 0);
    unreconcilable.then(|| {
        format!(
            "No time unit can reconcile d({})/dt with {} (their ratio {} is not a power of time)",
            describe(state),
            describe(rhs),
            describe(&ratio)
        )
    })
}

/// Spatial operators `grad` / `div` / `laplacian`: divide the argument's
/// dimensions by the coordinate unit raised to the operator's order (1 for
/// first derivatives, 2 for the laplacian), via [`coord_denominator`].
fn propagate_spatial_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if op.args.is_empty() {
        findings.push(UnitFinding::analysis(format!(
            "'{}' requires at least one argument; not dimension-checked",
            op.op
        )));
        return Dim::Unknown;
    }
    let arg = propagate_dim(&op.args[0], env, coords, findings);
    let Some(arg_unit) = arg.known() else {
        return Dim::Unknown;
    };
    let power = if op.op == "laplacian" { 2 } else { 1 };
    Dim::Known(arg_unit.divide(&coord_denominator(op, coords, power)))
}

/// Transcendental and trigonometric functions: argument must be
/// dimensionless, result is dimensionless.
fn propagate_transcendental_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 1, findings) {
        // The result is dimensionless whatever the argument turns out to be.
        return Dim::Known(Unit::dimensionless());
    }
    let arg = propagate_dim(&op.args[0], env, coords, findings);
    if let Some(u) = arg.known()
        && !u.is_dimensionless()
    {
        findings.push(UnitFinding::error(format!(
            "Argument to '{}' must be dimensionless, got {}",
            op.op,
            describe(u)
        )));
    }
    // Dimensionless by definition, even when the argument was undeterminable.
    Dim::Known(Unit::dimensionless())
}

/// Square root: halve dimension powers when all even.
fn propagate_sqrt_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 1, findings) {
        return Dim::Unknown;
    }
    let arg = propagate_dim(&op.args[0], env, coords, findings);
    let Some(unit) = arg.known() else {
        return Dim::Unknown;
    };
    if unit.is_dimensionless() {
        return Dim::Known(Unit::dimensionless());
    }
    let mut dims = HashMap::new();
    for (d, p) in &unit.dimensions {
        if p % 2 != 0 {
            // sqrt(m^3) is meaningful (m^1.5); our integer-power `Unit` just
            // cannot represent it. A checker limitation, not a file defect.
            findings.push(UnitFinding::analysis(format!(
                "sqrt of {} has half-integer dimensions, which are not representable; \
                 its dimension is unknown",
                describe(unit)
            )));
            return Dim::Unknown;
        }
        dims.insert(d.clone(), p / 2);
    }
    Dim::Known(Unit {
        dimensions: dims,
        scale: unit.scale.sqrt(),
    })
}

/// `ifelse`: the two branches must share dimensions; the result carries them.
fn propagate_ifelse_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 3, findings) {
        return Dim::Unknown;
    }
    // The condition (arg 0) need not be dimensionless — comparison ops already
    // produce a dimensionless Boolean, and we don't want to reject bare scalars
    // used as truthiness flags. It is still walked so findings inside it (e.g.
    // a mismatched comparison) are reported.
    propagate_dim(&op.args[0], env, coords, findings);
    let t = propagate_dim(&op.args[1], env, coords, findings);
    let f = propagate_dim(&op.args[2], env, coords, findings);
    match (t.known(), f.known()) {
        (Some(a), Some(b)) if !a.is_compatible(b) => {
            findings.push(UnitFinding::error(format!(
                "'ifelse' branches must share dimensions: {} vs {}",
                describe(a),
                describe(b)
            )));
            Dim::Unknown
        }
        (Some(a), Some(_)) => Dim::Known(a.clone()),
        _ => Dim::Unknown,
    }
}

/// Array operators: propagate the element dimension. Shape and indexing are
/// orthogonal to dimension (see gt-t5c / gt-vt3 — shapes are a separate
/// concern from unit checking). `aggregate` is the unified Functional
/// Aggregate Query op (RFC §5.6).
fn propagate_array_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    match op.op.as_str() {
        "aggregate" => {
            // The body is the scalar expression evaluated for each tuple of
            // loop-index values; its dimension is the array's element
            // dimension.
            if let Some(body) = &op.expr {
                return propagate_dim(body, env, coords, findings);
            }
            // Fallback: infer from the first positional arg.
            match op.args.first() {
                Some(first) => propagate_dim(first, env, coords, findings),
                None => Dim::Known(Unit::dimensionless()),
            }
        }
        "makearray" => {
            // Element dimension is determined by any per-region `values`
            // entry. All regions must share dimensions.
            let Some(values) = &op.values else {
                return Dim::Known(Unit::dimensionless());
            };
            let dims: Vec<Dim> = values
                .iter()
                .map(|v| propagate_dim(v, env, coords, findings))
                .collect();
            let mut resolved = dims.iter().filter_map(Dim::known);
            let Some(first) = resolved.next().cloned() else {
                return if values.is_empty() {
                    Dim::Known(Unit::dimensionless())
                } else {
                    Dim::Unknown
                };
            };
            let mut mismatched = false;
            for other in resolved {
                if !first.is_compatible(other) {
                    mismatched = true;
                    findings.push(UnitFinding::error(format!(
                        "'makearray' regions must share dimensions: {} vs {}",
                        describe(&first),
                        describe(other)
                    )));
                }
            }
            if mismatched || dims.iter().any(|d| d.known().is_none()) {
                return Dim::Unknown;
            }
            Dim::Known(first)
        }
        "broadcast" => {
            // Elementwise map over arrays with `fn` naming the scalar
            // operator. Construct a synthetic scalar node and recurse so we
            // reuse the same dimensional rules.
            let Some(fn_name) = op.broadcast_fn.as_deref() else {
                findings.push(UnitFinding::analysis(
                    "'broadcast' is missing its 'fn'; its dimension is unknown".to_string(),
                ));
                return Dim::Unknown;
            };
            let synthetic = ExpressionNode {
                op: fn_name.to_string(),
                args: op.args.clone(),
                ..ExpressionNode::default()
            };
            propagate_operator_dim(&synthetic, env, coords, findings)
        }
        // "index" | "reshape" | "transpose" | "concat"
        _ => {
            // Shape-only reorderings: element dimension is inherited from
            // the first positional arg (the source array).
            match op.args.first() {
                Some(first) => propagate_dim(first, env, coords, findings),
                None => Dim::Known(Unit::dimensionless()),
            }
        }
    }
}

/// Render a unit's dimensions for a diagnostic message.
fn describe(unit: &Unit) -> String {
    if unit.is_dimensionless() {
        return "dimensionless".to_string();
    }
    let mut parts: Vec<String> = unit
        .dimensions
        .iter()
        .map(|(d, p)| {
            let name = match d {
                Dimension::Mass => "mass",
                Dimension::Length => "length",
                Dimension::Time => "time",
                Dimension::Current => "current",
                Dimension::Temperature => "temperature",
                Dimension::Amount => "amount",
                Dimension::Luminosity => "luminosity",
            };
            if *p == 1 {
                name.to_string()
            } else {
                format!("{name}^{p}")
            }
        })
        .collect();
    parts.sort();
    parts.join("*")
}

/// Resolve the denominator unit for a `grad`/`div`/`laplacian` node raised
/// to `power`. Looks up `op.dim` in the supplied coordinate map; falls back
/// to `Length^power` (the legacy metre denominator) when the coordinate map
/// is absent, the dim is unspecified, or the dim is not present in the map.
/// A coordinate entry that is dimensionless (declared without units) also
/// falls back to metres; here we only care about propagation.
fn coord_denominator(
    op: &ExpressionNode,
    coords: Option<&HashMap<String, Unit>>,
    power: i32,
) -> Unit {
    let fallback = Unit::base(Dimension::Length, power, 1.0);
    let Some(coords) = coords else {
        return fallback;
    };
    let Some(dim) = op.dim.as_deref() else {
        return fallback;
    };
    let Some(coord) = coords.get(dim) else {
        return fallback;
    };
    if coord.is_dimensionless() {
        return fallback;
    }
    coord.power(power)
}

/// Build a `HashMap<String, Unit>` environment from model variable metadata,
/// together with a list of warnings for any variables whose declared unit
/// string could not be parsed.
///
/// A variable is entered into the environment ONLY when its dimension is
/// actually known. Both an *unparseable* unit string and a *missing* one leave
/// the variable OUT of the map, so [`propagate_dim`] yields [`Dim::Unknown`] for
/// it and every expression containing it is skipped for dimensional checking.
///
/// Neither case is coerced to dimensionless. Doing so would both HIDE genuine
/// mismatches (when the variable is used consistently) and MANUFACTURE false
/// ones (when the real unit was, e.g., `m`) — and since a provable mismatch is
/// now a hard validation error, a fabricated dimension would fail the build on
/// a legitimate file. A model that declares no units at all (a common idiom in
/// the shared corpus) is therefore simply not dimension-checked, rather than
/// being treated as an all-dimensionless model in which `D(u)/dt = A*sin(w*t)`
/// looks inconsistent.
///
/// Only the unparseable case warns: a missing `units` field is a legitimate
/// choice, whereas a unit string we cannot read is worth surfacing. The
/// returned warnings must not affect validity — callers report them as
/// non-blocking warnings only.
pub fn build_unit_env(
    variables: &HashMap<String, crate::ModelVariable>,
) -> (HashMap<String, Unit>, Vec<String>) {
    let mut env = HashMap::new();
    let mut warnings = Vec::new();
    for (name, var) in variables {
        let Some(declared) = &var.units else {
            // No declared units — dimension unknown, not dimensionless.
            continue;
        };
        match parse_unit(declared) {
            Ok(unit) => {
                env.insert(name.clone(), unit);
            }
            Err(_) => {
                warnings.push(format!(
                    "Variable \"{name}\" has an unparseable unit \"{declared}\"; \
                     treating its dimension as unknown (expressions \
                     referencing it are skipped for dimensional checking)"
                ));
            }
        }
    }
    (env, warnings)
}

/// Validate that an equation's LHS and RHS have matching dimensions.
///
/// Returns `Ok(())` when both sides propagate to dimensionally-equal units,
/// and a [`UnitError`] with a descriptive message otherwise. Propagation
/// errors from either side are surfaced verbatim.
///
/// This is the single-outcome view. Validation uses
/// [`check_equation_dimensions`], which reports EVERY finding and separates
/// provable mismatches from undeterminable dimensions.
pub fn validate_equation_dimensions(
    eq: &Equation,
    env: &HashMap<String, Unit>,
) -> Result<(), UnitError> {
    validate_equation_dimensions_with_coords(eq, env, None)
}

/// Like [`validate_equation_dimensions`] but additionally consults a spatial
/// coordinate units map when propagating `grad`/`div`/`laplacian` operators,
/// rather than assuming a hardcoded metre denominator.
pub fn validate_equation_dimensions_with_coords(
    eq: &Equation,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<(), UnitError> {
    if let Some(err) = check_equation_dimensions(eq, env, coords)
        .iter()
        .find(|f| f.is_error())
    {
        return Err(UnitError::DimensionMismatch(err.message.clone()));
    }
    // Single-outcome contract: distinguish "checked, consistent" (`Ok`) from
    // "could not be checked" (`UnknownUnit`) — an equation with an indeterminate
    // side was SKIPPED, and reporting `Ok` would claim we verified it.
    let mut sink = Vec::new();
    let lhs = propagate_dim(&eq.lhs, env, coords, &mut sink);
    let rhs = propagate_dim(&eq.rhs, env, coords, &mut sink);
    if lhs.known().is_none() || rhs.known().is_none() {
        return Err(UnitError::UnknownUnit(
            "equation has an indeterminate side; skipped for dimensional checking".to_string(),
        ));
    }
    Ok(())
}

/// Dimension-check an equation, returning EVERY finding.
///
/// Both sides are always walked — a finding on the LHS never short-circuits the
/// RHS — so one undeterminable subexpression cannot hide a provable mismatch
/// elsewhere in the same equation. The LHS/RHS comparison itself is only made
/// when BOTH sides resolved: comparing against an unknown dimension could only
/// ever produce a false mismatch.
pub fn check_equation_dimensions(
    eq: &Equation,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Vec<UnitFinding> {
    let mut findings = Vec::new();
    let lhs = propagate_dim(&eq.lhs, env, coords, &mut findings);
    let rhs = propagate_dim(&eq.rhs, env, coords, &mut findings);

    // `D(x)/dt` with an undeclared `t` is indeterminate, so the plain LHS-vs-RHS
    // comparison below cannot see it. Apply the weaker time-ratio rule instead.
    if let Some(state) = derivative_of_undeclared_time(&eq.lhs, env) {
        let state_dim = propagate_dim(state, env, coords, &mut Vec::new());
        if let (Some(s), Some(r)) = (state_dim.known(), rhs.known())
            && let Some(message) = derivative_time_mismatch(s, r)
        {
            findings.push(UnitFinding::error(message));
        }
        return findings;
    }

    if let (Some(l), Some(r)) = (lhs.known(), rhs.known())
        && !l.is_compatible(r)
    {
        findings.push(UnitFinding::error(format!(
            "Left-hand side has units of {} but right-hand side has units of {}",
            describe(l),
            describe(r)
        )));
    }
    findings
}

/// Dimension-check a standalone expression (an observed variable's defining
/// expression), returning EVERY finding.
///
/// When `declared` is `Some`, the expression's dimension is additionally
/// compared against the variable's declared units — the observed-variable
/// analogue of the equation LHS/RHS check.
pub fn check_expression_dimensions(
    expr: &Expr,
    declared: Option<&Unit>,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Vec<UnitFinding> {
    let mut findings = Vec::new();
    let actual = propagate_dim(expr, env, coords, &mut findings);

    // If the expression is ALREADY internally inconsistent, its overall
    // dimension is whatever the first resolved operand happened to be — so
    // comparing it against the declaration would report the SAME defect a
    // second time at the same path. Report the internal mismatch only.
    if findings.iter().any(UnitFinding::is_error) {
        return findings;
    }

    if let (Some(declared), Some(actual)) = (declared, actual.known())
        && !declared.is_compatible(actual)
    {
        findings.push(UnitFinding::error(format!(
            "Declared units of {} do not match the expression's units of {}",
            describe(declared),
            describe(actual)
        )));
    }
    findings
}

/// Parse a unit string into a Unit struct
///
/// Supports common scientific unit notations:
/// - base units (`"m"`, `"s"`, `"kg"`, `"mol"`, `"K"`, `"Pa"`, …)
/// - products (`"kg*m"`, `"N*m"`)
/// - quotients (`"m/s"`, `"mol/L"`)
/// - parenthesised groups (`"J/(mol*K)"`)
/// - integer powers (`"m^2"`, `"s^-1"`)
/// - dimensionless (`""`, `"1"`, `"dimensionless"`)
pub fn parse_unit(unit_str: &str) -> Result<Unit, UnitError> {
    let s = unit_str.trim();
    if s.is_empty() || s == "1" || s == "dimensionless" {
        return Ok(Unit::dimensionless());
    }

    // Strip a single layer of surrounding parentheses when they balance.
    if s.starts_with('(') && s.ends_with(')') && parens_balance(&s[1..s.len() - 1]) {
        return parse_unit(&s[1..s.len() - 1]);
    }

    let base_units = get_base_units();
    if let Some(unit) = base_units.get(s) {
        return Ok(unit.clone());
    }

    // Product / quotient. `*` and `/` share one precedence level and bind
    // LEFT-associatively, so we split at the LAST top-level operator and
    // recurse on the left. Splitting on `/` as a separate, looser level (as
    // this parser used to) pulls every `*` factor appearing after the last `/`
    // into the DENOMINATOR: `J/mol*K` parsed as `J/(mol*K)`, silently negating
    // K's exponent, and `kg/m^3*s` came out as `kg/(m^3*s)`. Equal-precedence
    // left association is the reading of the Go reference parser
    // (`unit := term (('*'|'/') term)*`) and of pint/Unitful.
    if let Some((idx, sym)) = find_last_top_level_operator(s) {
        let (left, right) = (&s[..idx], &s[idx + 1..]);
        if left.trim().is_empty() || right.trim().is_empty() {
            return Err(UnitError::ParseError(format!(
                "Dangling '{sym}' in unit \"{unit_str}\""
            )));
        }
        let l = parse_unit(left)?;
        let r = parse_unit(right)?;
        return Ok(match sym {
            '/' => l.divide(&r),
            _ => l.multiply(&r),
        });
    }

    // Power: right-most '^'.
    if let Some(idx) = s.rfind('^') {
        let (base_s, pow_s) = (&s[..idx], &s[idx + 1..]);
        let base_unit = parse_unit(base_s)?;
        let power: i32 = pow_s
            .trim()
            .parse()
            .map_err(|_| UnitError::ParseError(format!("Invalid power: {pow_s}")))?;
        return Ok(base_unit.power(power));
    }

    Err(UnitError::UnknownUnit(unit_str.to_string()))
}

/// Find the *last* top-level (outside any parenthesised group) `*` or `/`,
/// returning its byte index and which operator it is.
///
/// `parse_unit` splits here and recurses on the *left* substring, which makes
/// the two operators share a precedence level and associate left-to-right:
/// `a/b/c` is `(a/b)/c`, `a*b/c` is `(a*b)/c`, and `a/b*c` is `(a/b)*c`. This
/// gives the conventional reading of `W/m^2/K` as `W/(m^2*K)` while keeping
/// `J/mol*K` as `(J/mol)*K`, and matches the sibling parsers (Go's recursive
/// descent, Python/pint, Julia's Unitful `uparse`).
fn find_last_top_level_operator(s: &str) -> Option<(usize, char)> {
    let mut depth = 0i32;
    let mut last = None;
    for (i, c) in s.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            '*' | '/' if depth == 0 => last = Some((i, c)),
            _ => {}
        }
    }
    last
}

fn parens_balance(s: &str) -> bool {
    let mut depth = 0i32;
    for c in s.chars() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

/// Get commonly used base units
/// The cached base-unit registry. `parse_unit` recurses (parentheses, `/`,
/// `*` splits) and runs inside per-equation validation loops, so rebuilding
/// the ~50-entry map on every call was pure waste; the table is immutable
/// and deterministic, so one process-wide build is safe.
fn get_base_units() -> &'static HashMap<String, Unit> {
    static BASE_UNITS: std::sync::LazyLock<HashMap<String, Unit>> =
        std::sync::LazyLock::new(build_base_units);
    &BASE_UNITS
}

fn build_base_units() -> HashMap<String, Unit> {
    let mut units = HashMap::new();

    // Length units
    units.insert("m".to_string(), Unit::base(Dimension::Length, 1, 1.0));
    units.insert("cm".to_string(), Unit::base(Dimension::Length, 1, 0.01));
    units.insert("km".to_string(), Unit::base(Dimension::Length, 1, 1000.0));
    units.insert("mm".to_string(), Unit::base(Dimension::Length, 1, 0.001));

    // Time units
    units.insert("s".to_string(), Unit::base(Dimension::Time, 1, 1.0));
    units.insert("min".to_string(), Unit::base(Dimension::Time, 1, 60.0));
    units.insert("h".to_string(), Unit::base(Dimension::Time, 1, 3600.0));
    units.insert("hr".to_string(), Unit::base(Dimension::Time, 1, 3600.0));
    units.insert("day".to_string(), Unit::base(Dimension::Time, 1, 86400.0));

    // Mass units
    units.insert("kg".to_string(), Unit::base(Dimension::Mass, 1, 1.0));
    units.insert("g".to_string(), Unit::base(Dimension::Mass, 1, 0.001));

    // Amount units
    units.insert("mol".to_string(), Unit::base(Dimension::Amount, 1, 1.0));

    // Temperature units
    units.insert("K".to_string(), Unit::base(Dimension::Temperature, 1, 1.0));

    // Current / luminous intensity
    units.insert("A".to_string(), Unit::base(Dimension::Current, 1, 1.0));
    units.insert("cd".to_string(), Unit::base(Dimension::Luminosity, 1, 1.0));

    // Volume (L = dm³ = 10⁻³ m³)
    units.insert("L".to_string(), Unit::base(Dimension::Length, 3, 0.001));

    // Derived units
    // Velocity: m/s
    units.insert(
        "m/s".to_string(),
        Unit::base(Dimension::Length, 1, 1.0).divide(&Unit::base(Dimension::Time, 1, 1.0)),
    );

    // Concentration: mol/L (mol/m^3)
    let liter = Unit::base(Dimension::Length, 3, 0.001);
    units.insert(
        "mol/L".to_string(),
        Unit::base(Dimension::Amount, 1, 1.0).divide(&liter),
    );
    units.insert(
        "M".to_string(),
        Unit::base(Dimension::Amount, 1, 1.0).divide(&liter),
    );

    // Force: kg*m/s^2 (Newton)
    let newton = Unit::base(Dimension::Mass, 1, 1.0)
        .multiply(&Unit::base(Dimension::Length, 1, 1.0))
        .divide(&Unit::base(Dimension::Time, 2, 1.0));
    units.insert("N".to_string(), newton.clone());

    // Pressure: kg/(m*s^2) (Pascal)
    let pascal = Unit::base(Dimension::Mass, 1, 1.0)
        .divide(&Unit::base(Dimension::Length, 1, 1.0))
        .divide(&Unit::base(Dimension::Time, 2, 1.0));
    units.insert("Pa".to_string(), pascal);

    // Energy: kg*m^2/s^2 (Joule)
    let joule = Unit::base(Dimension::Mass, 1, 1.0)
        .multiply(&Unit::base(Dimension::Length, 2, 1.0))
        .divide(&Unit::base(Dimension::Time, 2, 1.0));
    units.insert("J".to_string(), joule.clone());
    let mut kj = joule.clone();
    kj.scale *= 1000.0;
    units.insert("kJ".to_string(), kj);
    let mut cal = joule.clone();
    cal.scale *= 4.184;
    units.insert("cal".to_string(), cal);
    let mut kcal = joule.clone();
    kcal.scale *= 4184.0;
    units.insert("kcal".to_string(), kcal);

    // Power: kg*m^2/s^3 (Watt)
    units.insert(
        "W".to_string(),
        Unit::base(Dimension::Mass, 1, 1.0)
            .multiply(&Unit::base(Dimension::Length, 2, 1.0))
            .divide(&Unit::base(Dimension::Time, 3, 1.0)),
    );

    // ESM-specific units standard (docs/units-standard.md).
    // Mole-fraction family: dimensionless with scale factors.
    // ppmv/ppbv/pptv are volume-mixing-ratio aliases of ppm/ppb/ppt under
    // the ideal-gas approximation — identical dimension and scale.
    let dimensionless_scaled = |scale: f64| Unit {
        dimensions: HashMap::new(),
        scale,
    };
    units.insert("ppm".to_string(), dimensionless_scaled(1e-6));
    units.insert("ppmv".to_string(), dimensionless_scaled(1e-6));
    units.insert("ppb".to_string(), dimensionless_scaled(1e-9));
    units.insert("ppbv".to_string(), dimensionless_scaled(1e-9));
    units.insert("ppt".to_string(), dimensionless_scaled(1e-12));
    units.insert("pptv".to_string(), dimensionless_scaled(1e-12));
    // `molec` is a dimensionless count atom — composites like `molec/cm^3`
    // fall out of the compound-unit parser as `[length]^-3`.
    units.insert("molec".to_string(), Unit::dimensionless());
    // Dobson unit: areal number density of ozone molecules.
    // Since `molec` is dimensionless, Dobson resolves to `[length]^-2` with
    // scale 2.6867e20 molec/m^2.
    units.insert(
        "Dobson".to_string(),
        Unit::base(Dimension::Length, -2, 2.6867e20),
    );
    units.insert(
        "DU".to_string(),
        Unit::base(Dimension::Length, -2, 2.6867e20),
    );

    units
}

/// Check dimensional consistency of an equation
///
/// # Arguments
///
/// * `lhs_unit` - Units of the left-hand side
/// * `rhs_unit` - Units of the right-hand side
///
/// # Returns
///
/// * `Result<(), UnitError>` - Ok if consistent, error otherwise
pub fn check_dimensional_consistency(lhs_unit: &Unit, rhs_unit: &Unit) -> Result<(), UnitError> {
    if lhs_unit.is_compatible(rhs_unit) {
        Ok(())
    } else {
        Err(UnitError::DimensionMismatch(
            "Left and right sides have incompatible dimensions".to_string(),
        ))
    }
}

/// Convert between compatible units
///
/// # Arguments
///
/// * `value` - Value to convert
/// * `from_unit` - Source unit
/// * `to_unit` - Target unit
///
/// # Returns
///
/// * `Result<f64, UnitError>` - Converted value or error
pub fn convert_units(value: f64, from_unit: &Unit, to_unit: &Unit) -> Result<f64, UnitError> {
    if !from_unit.is_compatible(to_unit) {
        return Err(UnitError::DimensionMismatch(
            "Units have incompatible dimensions".to_string(),
        ));
    }

    Ok(value * from_unit.scale / to_unit.scale)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ExpressionNode;

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args,
            ..ExpressionNode::default()
        })
    }

    fn op_with_wrt(name: &str, args: Vec<Expr>, wrt: &str) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args,
            wrt: Some(wrt.to_string()),
            ..ExpressionNode::default()
        })
    }

    fn env_of(pairs: &[(&str, &str)]) -> HashMap<String, Unit> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), parse_unit(v).unwrap()))
            .collect()
    }

    #[test]
    fn test_parse_dimensionless() {
        assert!(parse_unit("").unwrap().is_dimensionless());
        assert!(parse_unit("1").unwrap().is_dimensionless());
        assert!(parse_unit("dimensionless").unwrap().is_dimensionless());
    }

    #[test]
    fn test_parse_base_units() {
        assert_eq!(
            parse_unit("m").unwrap().dimensions.get(&Dimension::Length),
            Some(&1)
        );
        assert_eq!(
            parse_unit("s").unwrap().dimensions.get(&Dimension::Time),
            Some(&1)
        );
        assert_eq!(
            parse_unit("kg").unwrap().dimensions.get(&Dimension::Mass),
            Some(&1)
        );
    }

    #[test]
    fn test_parse_compound_units() {
        let u = parse_unit("m/s").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-1));

        let u = parse_unit("mol/L").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Amount), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&-3));
    }

    #[test]
    fn test_parse_parenthesised_units() {
        // J/(mol*K) == kg*m^2/(s^2*mol*K)
        let u = parse_unit("J/(mol*K)").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&2));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-2));
        assert_eq!(u.dimensions.get(&Dimension::Amount), Some(&-1));
        assert_eq!(u.dimensions.get(&Dimension::Temperature), Some(&-1));
    }

    #[test]
    fn test_parse_pascal_and_kg_per_m3() {
        let pa = parse_unit("Pa").unwrap();
        assert_eq!(pa.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(pa.dimensions.get(&Dimension::Length), Some(&-1));
        assert_eq!(pa.dimensions.get(&Dimension::Time), Some(&-2));

        let rho = parse_unit("kg/m^3").unwrap();
        assert_eq!(rho.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(rho.dimensions.get(&Dimension::Length), Some(&-3));
    }

    #[test]
    fn test_parse_negative_power() {
        let inv_s = parse_unit("s^-1").unwrap();
        assert_eq!(inv_s.dimensions.get(&Dimension::Time), Some(&-1));
    }

    #[test]
    fn test_division_is_left_associative() {
        // `W/m^2/K` must parse as `(W/m^2)/K = W/(m^2*K)`, not the
        // right-associative `W/(m^2/K) = W*K/m^2`. W = kg*m^2/s^3, so the
        // correct result is kg*s^-3*K^-1: Temperature power -1 (a +1 would
        // betray the old right-associative bug).
        let u = parse_unit("W/m^2/K").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-3));
        assert_eq!(u.dimensions.get(&Dimension::Temperature), Some(&-1));
        // Length cancels: m^2 (from W) divided by m^2 leaves power 0 (absent).
        assert_eq!(u.dimensions.get(&Dimension::Length), None);
    }

    #[test]
    fn test_find_last_top_level_operator() {
        // `a/b/c` splits at the *last* top-level operator so parse_unit recurses
        // on the left `a/b`, yielding left-associative `(a/b)/c`.
        assert_eq!(find_last_top_level_operator("a/b/c"), Some((3, '/')));
        assert_eq!(find_last_top_level_operator("a*b*c"), Some((3, '*')));
        // `*` and `/` share one precedence level, so the LAST of either wins:
        // `a/b*c` is `(a/b)*c`, not `a/(b*c)`.
        assert_eq!(find_last_top_level_operator("a/b*c"), Some((3, '*')));
        // Separators inside parentheses are hidden from the top-level scan.
        assert_eq!(find_last_top_level_operator("a/(b/c)"), Some((1, '/')));
        assert_eq!(find_last_top_level_operator("kg"), None);
    }

    /// `*` and `/` are the SAME precedence level and associate left-to-right.
    /// Splitting `/` first (looser) pulled every factor after the last `/` into
    /// the denominator, so `J/mol*K` parsed as `J/(mol*K)` — silently negating
    /// K's exponent.
    #[test]
    fn test_mixed_product_quotient_is_left_associative() {
        let u = parse_unit("J/mol*K").unwrap();
        // (J/mol)*K ⇒ temperature appears with power +1, not -1.
        assert_eq!(u.dimensions.get(&Dimension::Temperature), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Amount), Some(&-1));

        let u = parse_unit("kg/m^3*s").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&-3));

        // Repeated division stays left-associative: m/s/s == m/s^2.
        let u = parse_unit("m/s/s").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-2));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));

        // Parenthesised denominators are unaffected.
        let u = parse_unit("J/(mol*K)").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Temperature), Some(&-1));
        assert_eq!(u.dimensions.get(&Dimension::Amount), Some(&-1));
    }

    /// A dangling operator is malformed, not silently dimensionless. `"m/"` used
    /// to parse as metres and `"/s"` as s^-1.
    #[test]
    fn test_dangling_operator_is_rejected() {
        assert!(matches!(parse_unit("m/"), Err(UnitError::ParseError(_))));
        assert!(matches!(parse_unit("/s"), Err(UnitError::ParseError(_))));
        assert!(matches!(parse_unit("kg*"), Err(UnitError::ParseError(_))));
    }

    #[test]
    fn test_parse_mixed_product_quotient() {
        // Mixed `kg*m/s^2` is the Newton: mass^1 length^1 time^-2.
        let u = parse_unit("kg*m/s^2").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-2));
    }

    #[test]
    fn test_unit_compatibility() {
        let m = parse_unit("m").unwrap();
        let cm = parse_unit("cm").unwrap();
        let s = parse_unit("s").unwrap();
        assert!(m.is_compatible(&cm));
        assert!(!m.is_compatible(&s));
    }

    #[test]
    fn test_unit_arithmetic() {
        let m = parse_unit("m").unwrap();
        let s = parse_unit("s").unwrap();
        let v = m.divide(&s);
        assert_eq!(v.dimensions.get(&Dimension::Length), Some(&1));
        assert_eq!(v.dimensions.get(&Dimension::Time), Some(&-1));
        assert_eq!(m.power(2).dimensions.get(&Dimension::Length), Some(&2));
    }

    #[test]
    fn test_dimensional_consistency() {
        let m = parse_unit("m").unwrap();
        let cm = parse_unit("cm").unwrap();
        let s = parse_unit("s").unwrap();
        assert!(check_dimensional_consistency(&m, &cm).is_ok());
        assert!(check_dimensional_consistency(&m, &s).is_err());
    }

    #[test]
    fn test_unit_conversion() {
        let m = parse_unit("m").unwrap();
        let cm = parse_unit("cm").unwrap();
        assert!((convert_units(1.0, &m, &cm).unwrap() - 100.0).abs() < 1e-10);
        assert!((convert_units(100.0, &cm, &m).unwrap() - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_unknown_unit() {
        let result = parse_unit("unknown_unit");
        assert!(matches!(result, Err(UnitError::UnknownUnit(_))));
    }

    // ---- propagate ---------------------------------------------------

    #[test]
    fn propagate_literal_is_indeterminate() {
        // A bare numeric literal carries NO knowable dimension: `273.15` may be
        // a pure number or a temperature offset. It is therefore indeterminate,
        // not dimensionless — a checker whose findings are hard errors must not
        // fabricate a dimension it cannot know.
        let env = HashMap::new();
        assert!(matches!(
            Unit::propagate(&Expr::Number(2.5), &env),
            Err(UnitError::UnknownUnit(_))
        ));

        // Additively, though, a literal is NEUTRAL: it adopts its sibling's
        // dimension, so `T - 273.15` is a temperature and raises no finding.
        let env = env_of(&[("T", "K")]);
        let expr = op("-", vec![Expr::Variable("T".into()), Expr::Number(273.15)]);
        let u = Unit::propagate(&expr, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Temperature), Some(&1));
        assert!(check_expression_dimensions(&expr, None, &env, None).is_empty());

        // And an all-literal expression is dimensionless.
        let expr = op("+", vec![Expr::Number(1.0), Expr::Number(2.0)]);
        assert!(
            Unit::propagate(&expr, &HashMap::new())
                .unwrap()
                .is_dimensionless()
        );
    }

    /// An exponent is read BY VALUE, so `L^2` still yields an area even though
    /// the literal `2` has no dimension of its own.
    #[test]
    fn propagate_literal_exponent_is_read_by_value() {
        let env = env_of(&[("L", "m")]);
        let expr = op("^", vec![Expr::Variable("L".into()), Expr::Integer(2)]);
        let u = Unit::propagate(&expr, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&2));
    }

    #[test]
    fn propagate_variable_lookup() {
        let env = env_of(&[("v", "m/s")]);
        let u = Unit::propagate(&Expr::Variable("v".into()), &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-1));
    }

    #[test]
    fn propagate_time_variable_default() {
        let env = HashMap::new();
        let u = Unit::propagate(&Expr::Variable("t".into()), &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&1));
    }

    #[test]
    fn propagate_unknown_variable_errors() {
        let env = HashMap::new();
        let err = Unit::propagate(&Expr::Variable("nope".into()), &env).unwrap_err();
        assert!(matches!(err, UnitError::UnknownUnit(_)));
    }

    #[test]
    fn propagate_addition_matches() {
        let env = env_of(&[("h1", "m"), ("h2", "cm")]);
        let e = op(
            "+",
            vec![Expr::Variable("h1".into()), Expr::Variable("h2".into())],
        );
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
    }

    #[test]
    fn propagate_addition_mismatch_errors() {
        let env = env_of(&[("h", "m"), ("t", "s")]);
        let e = op(
            "+",
            vec![Expr::Variable("h".into()), Expr::Variable("t".into())],
        );
        let err = Unit::propagate(&e, &env).unwrap_err();
        assert!(matches!(err, UnitError::DimensionMismatch(_)));
    }

    #[test]
    fn propagate_multiplication_combines_dims() {
        let env = env_of(&[("rho", "kg/m^3"), ("v", "m/s")]);
        let e = op(
            "*",
            vec![Expr::Variable("rho".into()), Expr::Variable("v".into())],
        );
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&-2));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-1));
    }

    #[test]
    fn propagate_division_subtracts_dims() {
        let env = env_of(&[("m1", "kg"), ("V", "m^3")]);
        let e = op(
            "/",
            vec![Expr::Variable("m1".into()), Expr::Variable("V".into())],
        );
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&-3));
    }

    #[test]
    fn propagate_power_integer() {
        let env = env_of(&[("s", "m")]);
        let e = op("^", vec![Expr::Variable("s".into()), Expr::Number(3.0)]);
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&3));
    }

    #[test]
    fn propagate_power_rejects_dimensional_exponent() {
        // h ^ t is invalid: exponent must be dimensionless.
        let env = env_of(&[("h", "m"), ("t", "s")]);
        let e = op(
            "^",
            vec![Expr::Variable("h".into()), Expr::Variable("t".into())],
        );
        let err = Unit::propagate(&e, &env).unwrap_err();
        assert!(matches!(err, UnitError::DimensionMismatch(_)));
    }

    #[test]
    fn propagate_derivative_divides_by_wrt() {
        // Canonical bead example: D(h)/dt should have dimensions of v (m/s).
        // `t` must be DECLARED for the derivative to be determinate — an
        // undeclared independent variable leaves it unknown (see
        // `derivative_of_undeclared_time`).
        let env = env_of(&[("h", "m"), ("v", "m/s"), ("t", "s")]);
        let dh = op_with_wrt("D", vec![Expr::Variable("h".into())], "t");
        let dh_dim = Unit::propagate(&dh, &env).unwrap();
        let v_dim = Unit::propagate(&Expr::Variable("v".into()), &env).unwrap();
        assert!(dh_dim.is_compatible(&v_dim));
    }

    /// With an UNDECLARED `t` the derivative's dimension is unknown, so no time
    /// unit is assumed and the plain LHS/RHS comparison is skipped.
    #[test]
    fn propagate_derivative_of_undeclared_time_is_unknown() {
        let env = env_of(&[("h", "m")]);
        let dh = op_with_wrt("D", vec![Expr::Variable("h".into())], "t");
        assert!(matches!(
            Unit::propagate(&dh, &env),
            Err(UnitError::UnknownUnit(_))
        ));
    }

    #[test]
    fn propagate_exp_requires_dimensionless_arg() {
        let env = env_of(&[("h", "m")]);
        let e = op("exp", vec![Expr::Variable("h".into())]);
        let err = Unit::propagate(&e, &env).unwrap_err();
        assert!(matches!(err, UnitError::DimensionMismatch(_)));
    }

    #[test]
    fn propagate_sqrt_halves_even_powers() {
        let env = env_of(&[("a", "m^2")]);
        let e = op("sqrt", vec![Expr::Variable("a".into())]);
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
    }

    #[test]
    fn propagate_ifelse_branches_must_match() {
        let env = env_of(&[("h", "m"), ("x", "s")]);
        let e = op(
            "ifelse",
            vec![
                Expr::Number(1.0),
                Expr::Variable("h".into()),
                Expr::Variable("x".into()),
            ],
        );
        assert!(matches!(
            Unit::propagate(&e, &env).unwrap_err(),
            UnitError::DimensionMismatch(_)
        ));
    }

    #[test]
    fn propagate_comparison_requires_matching_dims() {
        let env = env_of(&[("h", "m"), ("x", "s")]);
        let e = op(
            ">",
            vec![Expr::Variable("h".into()), Expr::Variable("x".into())],
        );
        assert!(matches!(
            Unit::propagate(&e, &env).unwrap_err(),
            UnitError::DimensionMismatch(_)
        ));
    }

    #[test]
    fn propagate_grad_and_laplacian() {
        let env = env_of(&[("c", "mol/m^3")]);
        let g = op("grad", vec![Expr::Variable("c".into())]);
        let gu = Unit::propagate(&g, &env).unwrap();
        assert_eq!(gu.dimensions.get(&Dimension::Amount), Some(&1));
        assert_eq!(gu.dimensions.get(&Dimension::Length), Some(&-4));

        let l = op("laplacian", vec![Expr::Variable("c".into())]);
        let lu = Unit::propagate(&l, &env).unwrap();
        assert_eq!(lu.dimensions.get(&Dimension::Length), Some(&-5));
    }

    #[test]
    fn propagate_arrayop_body() {
        // aggregate { expr: x * scale } with x in m/s and a dimensionless
        // `scale` -> result m/s. (A bare numeric literal would leave the product
        // INDETERMINATE — see `propagate_literal_is_indeterminate` — so the
        // element dimension is exercised with a declared factor.)
        let env = env_of(&[("x", "m/s"), ("scale", "1")]);
        let body = op(
            "*",
            vec![Expr::Variable("x".into()), Expr::Variable("scale".into())],
        );
        let node = Expr::Operator(ExpressionNode {
            op: "aggregate".to_string(),
            args: vec![],
            expr: Some(Box::new(body)),
            ..ExpressionNode::default()
        });
        let u = Unit::propagate(&node, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&-1));
    }

    #[test]
    fn propagate_index_inherits_from_source() {
        let env = env_of(&[("arr", "kg")]);
        let node = op(
            "index",
            vec![Expr::Variable("arr".into()), Expr::Number(0.0)],
        );
        let u = Unit::propagate(&node, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&1));
    }

    #[test]
    fn propagate_broadcast_dispatches_to_fn() {
        // broadcast(fn='+', a, b) with matching dims works.
        let env = env_of(&[("a", "m"), ("b", "m")]);
        let node = Expr::Operator(ExpressionNode {
            op: "broadcast".to_string(),
            broadcast_fn: Some("+".to_string()),
            args: vec![Expr::Variable("a".into()), Expr::Variable("b".into())],
            ..ExpressionNode::default()
        });
        let u = Unit::propagate(&node, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Length), Some(&1));
    }

    #[test]
    fn propagate_unknown_operator_is_analysis_not_error() {
        // An operator with no dimensional rule means the CHECKER cannot
        // conclude anything — it is not a defect in the file. So it yields an
        // `Analysis` finding (non-blocking) and an unknown dimension, never a
        // promotable `Error` and never a silent `dimensionless`.
        let env = HashMap::new();
        let e = op("zorp", vec![Expr::Number(1.0)]);
        let findings = check_expression_dimensions(&e, None, &env, None);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].severity, UnitSeverity::Analysis);
        assert!(!findings[0].is_error());
        assert!(matches!(
            Unit::propagate(&e, &env),
            Err(UnitError::UnknownUnit(_))
        ));
    }

    /// An undeterminable operand must not SUPPRESS a provable mismatch
    /// elsewhere in the same expression: propagation records the finding and
    /// keeps walking instead of bailing at the first one.
    #[test]
    fn analysis_finding_does_not_hide_a_real_mismatch() {
        let env = env_of(&[("len", "m"), ("mass", "kg")]);
        // (zorp(1) + len) + mass — the unknown op is undeterminable, but the
        // `len` vs `mass` mismatch after it is still proven.
        let expr = op(
            "+",
            vec![
                op("zorp", vec![Expr::Number(1.0)]),
                Expr::Variable("len".into()),
                Expr::Variable("mass".into()),
            ],
        );
        let findings = check_expression_dimensions(&expr, None, &env, None);
        assert!(
            findings
                .iter()
                .any(|f| f.severity == UnitSeverity::Analysis),
            "expected the unknown operator to be reported: {findings:?}"
        );
        assert!(
            findings.iter().any(UnitFinding::is_error),
            "the m-vs-kg mismatch must still be proven: {findings:?}"
        );
    }

    #[test]
    fn validate_equation_dimensions_passes() {
        // `t` is declared, so D(h)/dt is determinate (m/s) and matches v.
        let env = env_of(&[("h", "m"), ("v", "m/s"), ("t", "s")]);
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("v".into()),
        };
        validate_equation_dimensions(&eq, &env).unwrap();
    }

    #[test]
    fn validate_equation_dimensions_detects_mismatch() {
        // With `t` DECLARED the derivative is determinate, so the plain
        // LHS-vs-RHS comparison proves the mismatch: D(h)/dt is m/s, h is m.
        let env = env_of(&[("h", "m"), ("v", "m/s"), ("t", "s")]);
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("h".into()),
        };
        assert!(validate_equation_dimensions(&eq, &env).is_err());

        // The consistent equation is accepted.
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("v".into()),
        };
        assert!(validate_equation_dimensions(&eq, &env).is_ok());
    }

    /// With an UNDECLARED `t`, the weaker time-ratio rule still proves a
    /// derivative equation that NO time unit could reconcile — while accepting
    /// one that some time unit could.
    #[test]
    fn derivative_time_ratio_rule() {
        let env = env_of(&[("h", "m"), ("v", "m/s"), ("mass", "kg")]);

        // d(m)/dt = kg: ratio m/kg is not a power of time ⇒ provable mismatch.
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("mass".into()),
        };
        let findings = check_equation_dimensions(&eq, &env, None);
        assert!(findings.iter().any(UnitFinding::is_error), "{findings:?}");

        // d(m)/dt = m/s: ratio is exactly `s` ⇒ reconcilable, no finding.
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("v".into()),
        };
        assert!(
            !check_equation_dimensions(&eq, &env, None)
                .iter()
                .any(UnitFinding::is_error)
        );

        // The dimensionless toy idiom `D(x)/dt = -x` (ratio time^0) is accepted:
        // it is the idiom used across the shared valid corpus.
        let env = env_of(&[("x", "dimensionless")]);
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("x".into())], "t"),
            rhs: op("-", vec![Expr::Variable("x".into())]),
        };
        assert!(
            !check_equation_dimensions(&eq, &env, None)
                .iter()
                .any(UnitFinding::is_error)
        );
    }

    /// Build a bare state [`crate::ModelVariable`] carrying only a declared
    /// unit string (all other metadata omitted).
    fn state_var_with_units(units: Option<&str>) -> crate::ModelVariable {
        crate::ModelVariable {
            var_type: crate::VariableType::State,
            units: units.map(str::to_string),
            default: None,
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        }
    }

    #[test]
    fn build_unit_env_unparseable_unit_is_unknown_not_dimensionless() {
        let mut variables = HashMap::new();
        // `x` has an unparseable unit; `y` has a real unit of metres.
        variables.insert("x".to_string(), state_var_with_units(Some("not_a_unit")));
        variables.insert("y".to_string(), state_var_with_units(Some("m")));

        let (env, warnings) = build_unit_env(&variables);

        // The unparseable variable is OMITTED (unknown), NOT coerced to a
        // dimensionless unit; the parseable one is present.
        assert!(
            !env.contains_key("x"),
            "unparseable unit must not be in env"
        );
        assert!(env.contains_key("y"));

        // A warning is surfaced for the unparseable unit (behavior, not text).
        assert!(
            warnings.iter().any(|w| w.contains("x")),
            "expected a warning mentioning the offending variable, got {warnings:?}"
        );

        // An equation `y = x` referencing the unknown-unit variable propagates
        // to UnknownUnit — a non-blocking, skip-for-dim-checking outcome — NOT
        // a false DimensionMismatch (which a dimensionless coercion of `x`
        // against `y`'s metres would have produced).
        let eq = Equation {
            lhs: Expr::Variable("y".into()),
            rhs: Expr::Variable("x".into()),
        };
        let result = validate_equation_dimensions(&eq, &env);
        assert!(
            matches!(result, Err(UnitError::UnknownUnit(_))),
            "expected UnknownUnit (skipped), not a false mismatch, got {result:?}"
        );
    }
}
