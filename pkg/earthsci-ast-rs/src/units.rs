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
        match expr {
            Expr::Number(_) | Expr::Integer(_) => Ok(Unit::dimensionless()),
            Expr::Variable(name) => {
                if let Some(unit) = env.get(name) {
                    Ok(unit.clone())
                } else if name == "t" {
                    // Implicit time variable.
                    Ok(Unit::base(Dimension::Time, 1, 1.0))
                } else {
                    Err(UnitError::UnknownUnit(format!("Variable: {name}")))
                }
            }
            Expr::Operator(op) => propagate_operator(op, env, coords),
        }
    }
}

/// Dispatch one operator node to its family's propagation helper. Kept as a
/// thin match so each family's dimensional rules live in one named function;
/// the rules mirror the Python (`units.py::_get_expression_dimension`) and
/// Julia (`units.jl::get_expression_dimensions`) implementations.
fn propagate_operator(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    match op.op.as_str() {
        "+" | "-" => propagate_additive(op, env, coords),
        "*" | "/" => propagate_multiplicative(op, env, coords),
        "^" | "power" | "pow" => propagate_power(op, env, coords),
        "D" | "ic" => propagate_calculus(op, env, coords),
        "grad" | "div" | "laplacian" => propagate_spatial(op, env, coords),
        "exp" | "log" | "log10" | "ln" | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh" => {
            propagate_transcendental(op, env, coords)
        }
        "sqrt" => propagate_sqrt(op, env, coords),
        // abs/sign/floor/ceil preserve dimensions; `Pre` is an initial-value
        // marker — same dimensions as its argument.
        "abs" | "floor" | "ceil" | "round" | "sign" | "Pre" => {
            propagate_dimension_preserving(op, env, coords)
        }
        "min" | "max" => propagate_min_max(op, env, coords),
        "atan2" => propagate_atan2(op, env, coords),
        "ifelse" => propagate_ifelse(op, env, coords),
        ">" | "<" | ">=" | "<=" | "==" | "!=" => propagate_comparison(op, env, coords),
        "and" | "or" | "not" => Ok(Unit::dimensionless()),
        // Array operators: propagate the element dimension. Shape and
        // indexing are orthogonal to dimension (see gt-t5c / gt-vt3 — shapes
        // are a separate concern from unit checking).
        "aggregate" | "makearray" | "index" | "reshape" | "transpose" | "concat" | "broadcast" => {
            propagate_array(op, env, coords)
        }
        // Unknown operator — fail loudly rather than silently returning
        // dimensionless, which used to mask propagation gaps.
        other => Err(UnitError::ParseError(format!(
            "Unknown operator '{other}' in dimensional propagation"
        ))),
    }
}

/// `+` / `-`: every operand must share dimensions; the result carries them.
/// A unary minus propagates its single argument unchanged.
fn propagate_additive(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.is_empty() {
        return Ok(Unit::dimensionless());
    }
    // Unary minus: propagate the single argument.
    if op.op == "-" && op.args.len() == 1 {
        return Unit::propagate_with_coords(&op.args[0], env, coords);
    }
    let first = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    for arg in op.args.iter().skip(1) {
        let other = Unit::propagate_with_coords(arg, env, coords)?;
        if !first.is_compatible(&other) {
            return Err(UnitError::DimensionMismatch(format!(
                "Incompatible dimensions in '{}' operation",
                op.op
            )));
        }
    }
    Ok(first)
}

/// `*` / `/`: dimensions multiply / divide, no compatibility requirement.
fn propagate_multiplicative(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    match op.op.as_str() {
        "*" => {
            let mut result = Unit::dimensionless();
            for arg in &op.args {
                let u = Unit::propagate_with_coords(arg, env, coords)?;
                result = result.multiply(&u);
            }
            Ok(result)
        }
        _ => {
            if op.args.len() != 2 {
                return Err(UnitError::ParseError(
                    "Division requires exactly 2 arguments".to_string(),
                ));
            }
            let num = Unit::propagate_with_coords(&op.args[0], env, coords)?;
            let den = Unit::propagate_with_coords(&op.args[1], env, coords)?;
            Ok(num.divide(&den))
        }
    }
}

/// `^` / `power` / `pow`: the exponent must be dimensionless; a dimensional
/// base additionally requires a literal integer exponent (only integer powers
/// of dimensions are representable).
fn propagate_power(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 2 {
        return Err(UnitError::ParseError(
            "Power operator requires exactly 2 arguments".to_string(),
        ));
    }
    let base_unit = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    let exp_unit = Unit::propagate_with_coords(&op.args[1], env, coords)?;
    if !exp_unit.is_dimensionless() {
        return Err(UnitError::DimensionMismatch(format!(
            "Exponent in '{}' must be dimensionless",
            op.op
        )));
    }
    // Only integer exponents carry dimensions meaningfully.
    if base_unit.is_dimensionless() {
        return Ok(Unit::dimensionless());
    }
    // A literal exponent may arrive as EITHER `Expr::Number` (JSON `2.0`) or
    // `Expr::Integer` (JSON `2`). Matching only `Number` meant that `L^2` — the
    // natural spelling, and the one every author writes — fell through to the
    // "non-literal exponent" error below, so `area = L^2` raised a spurious
    // dimension mismatch. Worse, because `structural.rs` abandons an equation's
    // whole dimension check at the first error, that spurious finding
    // SUPPRESSED any real mismatch elsewhere in the same equation. The only
    // test covering this path used `Expr::Number(3.0)` and so never saw it.
    let literal_exp = match &op.args[1] {
        Expr::Integer(i) => Some(*i as f64),
        Expr::Number(n) => Some(*n),
        _ => None,
    };
    if let Some(n) = literal_exp {
        if n.fract() == 0.0 {
            return Ok(base_unit.power(n as i32));
        }
        return Err(UnitError::DimensionMismatch(format!(
            "Non-integer exponent {n} applied to dimensional quantity"
        )));
    }
    // Non-literal exponent with a dimensional base is ambiguous.
    Err(UnitError::DimensionMismatch(
        "Cannot apply non-literal exponent to a dimensional quantity".to_string(),
    ))
}

/// Calculus-family operators: the time/coordinate derivative `D` divides its
/// argument's dimensions by the `wrt` variable's, and the initial-condition
/// marker `ic` (v0.8.0) is dimension-preserving — the initial value of a field
/// carries the same units as the field itself.
fn propagate_calculus(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    match op.op.as_str() {
        "D" => {
            if op.args.len() != 1 {
                return Err(UnitError::ParseError(
                    "Derivative 'D' requires exactly 1 argument".to_string(),
                ));
            }
            let arg_unit = Unit::propagate_with_coords(&op.args[0], env, coords)?;
            let wrt = op.wrt.as_deref().unwrap_or("t");
            let wrt_unit = env
                .get(wrt)
                .cloned()
                .or_else(|| {
                    if wrt == "t" {
                        Some(Unit::base(Dimension::Time, 1, 1.0))
                    } else {
                        None
                    }
                })
                .ok_or_else(|| {
                    UnitError::UnknownUnit(format!("Derivative wrt unknown variable: {wrt}"))
                })?;
            Ok(arg_unit.divide(&wrt_unit))
        }
        _ => {
            // "ic": propagate the unit of the single argument unchanged.
            if op.args.len() != 1 {
                return Err(UnitError::ParseError(
                    "Initial condition 'ic' requires exactly 1 argument".to_string(),
                ));
            }
            Unit::propagate_with_coords(&op.args[0], env, coords)
        }
    }
}

/// Spatial operators `grad` / `div` / `laplacian`: divide the argument's
/// dimensions by the coordinate unit raised to the operator's order (1 for
/// first derivatives, 2 for the laplacian), via [`coord_denominator`].
fn propagate_spatial(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.is_empty() {
        return Err(UnitError::ParseError(format!(
            "'{}' requires at least one argument",
            op.op
        )));
    }
    let arg_unit = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    let power = if op.op == "laplacian" { 2 } else { 1 };
    let denom = coord_denominator(op, coords, power);
    Ok(arg_unit.divide(&denom))
}

/// Transcendental and trigonometric functions: argument must be
/// dimensionless, result is dimensionless.
fn propagate_transcendental(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 1 {
        return Err(UnitError::ParseError(format!(
            "'{}' requires exactly 1 argument",
            op.op
        )));
    }
    let arg = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    if !arg.is_dimensionless() {
        return Err(UnitError::DimensionMismatch(format!(
            "Argument to '{}' must be dimensionless",
            op.op
        )));
    }
    Ok(Unit::dimensionless())
}

/// Square root: halve dimension powers when all even, else error.
fn propagate_sqrt(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 1 {
        return Err(UnitError::ParseError(
            "'sqrt' requires exactly 1 argument".to_string(),
        ));
    }
    let arg = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    if arg.is_dimensionless() {
        return Ok(Unit::dimensionless());
    }
    let mut dims = HashMap::new();
    for (d, p) in &arg.dimensions {
        if p % 2 != 0 {
            return Err(UnitError::DimensionMismatch(
                "sqrt of a quantity with odd-power dimensions is not representable".to_string(),
            ));
        }
        dims.insert(d.clone(), p / 2);
    }
    Ok(Unit {
        dimensions: dims,
        scale: arg.scale.sqrt(),
    })
}

/// Single-argument dimension-preserving operators (`abs` / `floor` / `ceil` /
/// `round` / `sign`, and the initial-value marker `Pre`): the result carries
/// the argument's dimensions unchanged.
fn propagate_dimension_preserving(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 1 {
        return Err(UnitError::ParseError(format!(
            "'{}' requires exactly 1 argument",
            op.op
        )));
    }
    Unit::propagate_with_coords(&op.args[0], env, coords)
}

/// `min` / `max` require matching dimensions across every operand; the result
/// carries them.
fn propagate_min_max(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.is_empty() {
        return Ok(Unit::dimensionless());
    }
    let first = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    for arg in op.args.iter().skip(1) {
        let other = Unit::propagate_with_coords(arg, env, coords)?;
        if !first.is_compatible(&other) {
            return Err(UnitError::DimensionMismatch(format!(
                "Incompatible dimensions in '{}'",
                op.op
            )));
        }
    }
    Ok(first)
}

/// `atan2`: both arguments must share dimensions (their ratio is the angle);
/// the result is dimensionless.
fn propagate_atan2(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 2 {
        return Err(UnitError::ParseError(
            "'atan2' requires exactly 2 arguments".to_string(),
        ));
    }
    let a = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    let b = Unit::propagate_with_coords(&op.args[1], env, coords)?;
    if !a.is_compatible(&b) {
        return Err(UnitError::DimensionMismatch(
            "atan2 arguments must share dimensions (ratio is the angle)".to_string(),
        ));
    }
    Ok(Unit::dimensionless())
}

/// `ifelse`: the two branches must share dimensions; the result carries them.
fn propagate_ifelse(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 3 {
        return Err(UnitError::ParseError(
            "'ifelse' requires exactly 3 arguments".to_string(),
        ));
    }
    // Condition (arg 0) need not be dimensionless — comparison ops
    // already produce a dimensionless Boolean, and we don't want to
    // reject bare scalars used as truthiness flags. Branches must
    // match.
    let t_unit = Unit::propagate_with_coords(&op.args[1], env, coords)?;
    let f_unit = Unit::propagate_with_coords(&op.args[2], env, coords)?;
    if !t_unit.is_compatible(&f_unit) {
        return Err(UnitError::DimensionMismatch(
            "'ifelse' branches must share dimensions".to_string(),
        ));
    }
    Ok(t_unit)
}

/// Comparison operators return a dimensionless flag, but their operands must
/// share dimensions (logical `and`/`or`/`not` are handled directly in the
/// dispatcher — always dimensionless).
fn propagate_comparison(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    if op.args.len() != 2 {
        return Err(UnitError::ParseError(format!(
            "'{}' requires exactly 2 arguments",
            op.op
        )));
    }
    let a = Unit::propagate_with_coords(&op.args[0], env, coords)?;
    let b = Unit::propagate_with_coords(&op.args[1], env, coords)?;
    if !a.is_compatible(&b) {
        return Err(UnitError::DimensionMismatch(format!(
            "Comparison '{}' requires matching dimensions",
            op.op
        )));
    }
    Ok(Unit::dimensionless())
}

/// Array operators: propagate the element dimension. Shape and indexing are
/// orthogonal to dimension (see gt-t5c / gt-vt3 — shapes are a separate
/// concern from unit checking). `aggregate` is the unified Functional
/// Aggregate Query op (RFC §5.6).
fn propagate_array(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    coords: Option<&HashMap<String, Unit>>,
) -> Result<Unit, UnitError> {
    match op.op.as_str() {
        "aggregate" => {
            // The body is the scalar expression evaluated for each tuple of
            // loop-index values; its dimension is the array's element
            // dimension.
            if let Some(body) = &op.expr {
                return Unit::propagate_with_coords(body, env, coords);
            }
            // Fallback: infer from the first positional arg.
            if let Some(first) = op.args.first() {
                return Unit::propagate_with_coords(first, env, coords);
            }
            Ok(Unit::dimensionless())
        }
        "makearray" => {
            // Element dimension is determined by any per-region `values`
            // entry. All regions must share dimensions.
            if let Some(values) = &op.values
                && let Some(first) = values.first()
            {
                let first_dim = Unit::propagate_with_coords(first, env, coords)?;
                for v in values.iter().skip(1) {
                    let v_dim = Unit::propagate_with_coords(v, env, coords)?;
                    if !first_dim.is_compatible(&v_dim) {
                        return Err(UnitError::DimensionMismatch(
                            "'makearray' regions must share dimensions".to_string(),
                        ));
                    }
                }
                return Ok(first_dim);
            }
            Ok(Unit::dimensionless())
        }
        "broadcast" => {
            // Elementwise map over arrays with `fn` naming the scalar
            // operator. Construct a synthetic scalar node and recurse so we
            // reuse the same dimensional rules.
            let fn_name = op
                .broadcast_fn
                .as_deref()
                .ok_or_else(|| UnitError::ParseError("'broadcast' requires 'fn'".to_string()))?;
            let synthetic = ExpressionNode {
                op: fn_name.to_string(),
                args: op.args.clone(),
                ..ExpressionNode::default()
            };
            propagate_operator(&synthetic, env, coords)
        }
        // "index" | "reshape" | "transpose" | "concat"
        _ => {
            // Shape-only reorderings: element dimension is inherited from
            // the first positional arg (the source array).
            if let Some(first) = op.args.first() {
                return Unit::propagate_with_coords(first, env, coords);
            }
            Ok(Unit::dimensionless())
        }
    }
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
/// Variables without declared units are treated as dimensionless. A variable
/// whose declared unit string is *unparseable* is OMITTED from the returned
/// environment — its dimension is left UNKNOWN, so [`Unit::propagate`] yields
/// [`UnitError::UnknownUnit`] for any equation referencing it and that equation
/// is skipped for dimensional checking (surfaced by the caller as a
/// non-blocking warning). It is deliberately NOT coerced to dimensionless:
/// doing so would both hide genuine [`UnitError::DimensionMismatch`] errors
/// (when the variable is used consistently) and manufacture false ones (when
/// the real unit was, e.g., `m`). This mirrors the Julia (`@warn`) reference
/// behavior and esm-libraries-spec §3.3.3/§3.4. The returned warnings must not
/// affect validity — callers report them as non-blocking warnings only.
pub fn build_unit_env(
    variables: &HashMap<String, crate::ModelVariable>,
) -> (HashMap<String, Unit>, Vec<String>) {
    let mut env = HashMap::new();
    let mut warnings = Vec::new();
    for (name, var) in variables {
        match &var.units {
            Some(s) => match parse_unit(s) {
                Ok(unit) => {
                    env.insert(name.clone(), unit);
                }
                Err(_) => {
                    // Unparseable unit: omit the variable so its dimension is
                    // unknown (rather than silently coerced to dimensionless)
                    // and surface a warning.
                    warnings.push(format!(
                        "Variable \"{name}\" has an unparseable unit \"{s}\"; \
                         treating its dimension as unknown (equations \
                         referencing it are skipped for dimensional checking)"
                    ));
                }
            },
            None => {
                env.insert(name.clone(), Unit::dimensionless());
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
    let lhs = Unit::propagate_with_coords(&eq.lhs, env, coords)?;
    let rhs = Unit::propagate_with_coords(&eq.rhs, env, coords)?;
    if lhs.is_compatible(&rhs) {
        Ok(())
    } else {
        Err(UnitError::DimensionMismatch(format!(
            "Equation LHS dimensions {:?} do not match RHS dimensions {:?}",
            lhs.dimensions, rhs.dimensions
        )))
    }
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

    // Division: split on top-level '/', left-associative.
    if let Some(idx) = find_top_level(s, '/') {
        let (left, right) = (&s[..idx], &s[idx + 1..]);
        let num = parse_unit(left)?;
        let den = parse_unit(right)?;
        return Ok(num.divide(&den));
    }

    // Multiplication: split on top-level '*', left-associative.
    if let Some(idx) = find_top_level(s, '*') {
        let (left, right) = (&s[..idx], &s[idx + 1..]);
        let l = parse_unit(left)?;
        let r = parse_unit(right)?;
        return Ok(l.multiply(&r));
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

/// Find the *last* occurrence of `needle` at depth 0 (outside any
/// parenthesised group), or `None` if there is none.
///
/// `parse_unit` splits at this index and recurses on the *left* substring, so
/// returning the last top-level occurrence makes the operator left-associative:
/// `a/b/c` splits as `(a/b) / c` and `a*b*c` as `(a*b) * c`. This gives the
/// conventional reading of `W/m^2/K` as `W/(m^2*K)` and matches the
/// left-associative division of the sibling parsers (Python/pint, TypeScript's
/// numerator-then-denominators split, and Julia's Unitful `uparse`).
fn find_top_level(s: &str, needle: char) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut depth = 0i32;
    let mut last = None;
    for (i, &b) in bytes.iter().enumerate() {
        match b as char {
            '(' => depth += 1,
            ')' => depth -= 1,
            c if c == needle && depth == 0 => last = Some(i),
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
    fn test_find_top_level_splits_at_last_occurrence() {
        // `a/b/c` splits at the *last* top-level '/' so parse_unit recurses on
        // the left `a/b`, yielding left-associative `(a/b)/c`.
        assert_eq!(find_top_level("a/b/c", '/'), Some(3));
        assert_eq!(find_top_level("a*b*c", '*'), Some(3));
        // Separators inside parentheses are hidden from the top-level scan.
        assert_eq!(find_top_level("a/(b/c)", '/'), Some(1));
        assert_eq!(find_top_level("kg", '/'), None);
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
    fn propagate_number_is_dimensionless() {
        let env = HashMap::new();
        let u = Unit::propagate(&Expr::Number(2.5), &env).unwrap();
        assert!(u.is_dimensionless());
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
        let env = env_of(&[("h", "m"), ("v", "m/s")]);
        let dh = op_with_wrt("D", vec![Expr::Variable("h".into())], "t");
        let dh_dim = Unit::propagate(&dh, &env).unwrap();
        let v_dim = Unit::propagate(&Expr::Variable("v".into()), &env).unwrap();
        assert!(dh_dim.is_compatible(&v_dim));
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
        // arrayop { expr: x * 2 } with x having units m/s -> result m/s.
        let env = env_of(&[("x", "m/s")]);
        let body = op("*", vec![Expr::Variable("x".into()), Expr::Number(2.0)]);
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
    fn propagate_unknown_operator_errors() {
        let env = HashMap::new();
        let e = op("zorp", vec![Expr::Number(1.0)]);
        let err = Unit::propagate(&e, &env).unwrap_err();
        assert!(matches!(err, UnitError::ParseError(_)));
    }

    #[test]
    fn validate_equation_dimensions_passes() {
        let env = env_of(&[("h", "m"), ("v", "m/s")]);
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("v".into()),
        };
        validate_equation_dimensions(&eq, &env).unwrap();
    }

    #[test]
    fn validate_equation_dimensions_detects_mismatch() {
        let env = env_of(&[("h", "m"), ("v", "m/s")]);
        // Wrong: D(h)/dt = h is dimensionally inconsistent.
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("h".into()),
        };
        assert!(validate_equation_dimensions(&eq, &env).is_err());
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
        assert!(!env.contains_key("x"), "unparseable unit must not be in env");
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
