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

/// A dimension exponent.
///
/// Exponents are RATIONAL, not integer: `1/s^0.5` — the intensity of an SDE
/// noise term — is a legitimate unit that appears in the shared corpus
/// (`tests/fixtures/sde/*.esm`), and `sqrt` halves whatever it is given. An
/// integer exponent could represent neither, so `sqrt(m^3)` used to be reported
/// as "not representable" and `s^0.5` failed to parse outright — which, now that
/// a dimensional mismatch is a HARD ERROR, would falsely reject legitimate
/// files.
///
/// Always stored in lowest terms with a positive denominator, so `PartialEq`
/// is exact dimensional equality (½ and 2/4 compare equal) and `HashMap` lookups
/// are sound.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rational {
    num: i32,
    den: i32,
}

impl Rational {
    /// A whole number exponent.
    #[must_use]
    pub fn int(n: i32) -> Self {
        Rational { num: n, den: 1 }
    }

    /// `num/den`, reduced. A zero denominator is treated as `0/1`.
    #[must_use]
    pub fn new(num: i32, den: i32) -> Self {
        if den == 0 {
            return Rational { num: 0, den: 1 };
        }
        let sign = if den < 0 { -1 } else { 1 };
        let (num, den) = (num * sign, den * sign);
        let g = gcd(num.abs(), den);
        if g == 0 {
            return Rational { num: 0, den: 1 };
        }
        Rational {
            num: num / g,
            den: den / g,
        }
    }

    /// Convert a decimal literal (`0.5`, `-1.5`, `2`) to an exact rational.
    ///
    /// Goes through the DECIMAL representation rather than the binary float, so
    /// `0.5` is exactly ½ and `0.1` is exactly 1/10 — a continued-fraction
    /// expansion of the `f64` would introduce a spurious huge denominator.
    /// Returns `None` for a non-finite value or one needing more precision than
    /// an `i32` numerator can hold.
    #[must_use]
    pub fn from_f64(x: f64) -> Option<Self> {
        if !x.is_finite() {
            return None;
        }
        if x.fract() == 0.0 && x.abs() < i32::MAX as f64 {
            return Some(Rational::int(x as i32));
        }
        // Up to 6 decimal places is far more than any real unit exponent needs.
        for places in 1..=6u32 {
            let den = 10i32.checked_pow(places)?;
            let scaled = x * f64::from(den);
            if scaled.fract().abs() < 1e-9 && scaled.abs() < i32::MAX as f64 {
                return Some(Rational::new(scaled.round() as i32, den));
            }
        }
        None
    }

    fn add(self, other: Self) -> Self {
        Rational::new(
            self.num * other.den + other.num * self.den,
            self.den * other.den,
        )
    }

    fn sub(self, other: Self) -> Self {
        Rational::new(
            self.num * other.den - other.num * self.den,
            self.den * other.den,
        )
    }

    fn mul(self, other: Self) -> Self {
        Rational::new(self.num * other.num, self.den * other.den)
    }

    fn is_zero(self) -> bool {
        self.num == 0
    }

    /// As an `f64`, for scaling a unit's magnitude by this exponent.
    fn as_f64(self) -> f64 {
        f64::from(self.num) / f64::from(self.den)
    }
}

impl std::fmt::Display for Rational {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.den == 1 {
            write!(f, "{}", self.num)
        } else {
            write!(f, "{}/{}", self.num, self.den)
        }
    }
}

fn gcd(a: i32, b: i32) -> i32 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// Represents a physical unit with dimensions
#[derive(Debug, Clone, PartialEq)]
pub struct Unit {
    /// Base dimensions with their (rational) powers
    dimensions: HashMap<Dimension, Rational>,
    /// Scale factor for unit conversions
    scale: f64,
}

/// Base physical dimensions — the eight canonical axes shared across the
/// bindings (`m kg s mol K A cd rad`).
///
/// `Angle` is a full axis rather than a synonym for dimensionless, matching the
/// Go reference. The trigonometric functions therefore accept an angle OR a
/// dimensionless argument (see `propagate_transcendental_dim`); `exp`/`log` still
/// demand strict dimensionlessness.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Dimension {
    Mass,        // M   — kg
    Length,      // L   — m
    Time,        // T   — s
    Current,     // I   — A  (electric current)
    Temperature, // Θ   — K  (thermodynamic temperature)
    Amount,      // N   — mol (amount of substance)
    Luminosity,  // J   — cd (luminous intensity)
    Angle,       // rad (plane angle)
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
///   wrong arity, a broadcast missing its `fn`). This reports what the checker
///   could not conclude, NOT a defect in the file, so it stays a non-blocking
///   warning and the affected subexpression propagates as [`Dim::Unknown`].
///
/// An operator with NO dimensional rule (a rewrite-target sugar op such as
/// `grad`/`div`/`laplacian`, or any unregistered user op) is the one
/// undeterminable case that emits NO finding at all: per esm-spec §4.8.4 the
/// checker reports UNKNOWN and skips silently, matching the other four bindings
/// (Julia/TS/Python/Go). See [`propagate_operator_dim`].
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
    /// Dimension could not be determined. Most undeterminable causes record an
    /// `Analysis` finding; an op with no dimensional rule records none (it is
    /// reported as unknown and skipped, per esm-spec §4.8.4).
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
    /// The multiplicative factor taking this unit to its SI base (`atm` → 101325).
    ///
    /// NOTE: the representation is purely multiplicative — there is no affine
    /// OFFSET — so `degC` and `K` are indistinguishable here. A check that must
    /// separate them (the `default_units` identity check) cannot do so by
    /// dimension and scale alone.
    pub fn scale(&self) -> f64 {
        self.scale
    }

    /// Whether two units measure the same physical quantity, ignoring scale
    /// (`atm` and `Pa` are the same dimension at different scales).
    pub fn same_dimensions(&self, other: &Unit) -> bool {
        self.dimensions == other.dimensions
    }

    /// Create a dimensionless unit
    pub fn dimensionless() -> Self {
        Unit {
            dimensions: HashMap::new(),
            scale: 1.0,
        }
    }

    /// Create a unit with a single dimension raised to an integer power.
    pub fn base(dimension: Dimension, power: i32, scale: f64) -> Self {
        Unit::base_rational(dimension, Rational::int(power), scale)
    }

    /// Create a unit with a single dimension raised to a RATIONAL power (e.g.
    /// `s^-1/2`, the dimension of an SDE noise intensity).
    pub fn base_rational(dimension: Dimension, power: Rational, scale: f64) -> Self {
        let mut dimensions = HashMap::new();
        if !power.is_zero() {
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

    /// True when this unit is dimensionless OR a pure plane angle.
    ///
    /// `rad` is a full dimension axis here (matching the Go reference), but a
    /// trigonometric function legitimately takes an ANGLE — `sin(theta)` with
    /// `theta` in radians must not be reported as a dimensional error.
    pub fn is_dimensionless_or_angle(&self) -> bool {
        self.dimensions
            .keys()
            .all(|d| matches!(d, Dimension::Angle))
    }

    /// Multiply two units
    pub fn multiply(&self, other: &Unit) -> Unit {
        self.combine(other, Rational::add, self.scale * other.scale)
    }

    /// Divide two units
    pub fn divide(&self, other: &Unit) -> Unit {
        self.combine(other, Rational::sub, self.scale / other.scale)
    }

    /// Merge `other`'s exponents into a copy of `self`'s with `op`, dropping any
    /// axis whose exponent cancels to zero.
    fn combine(&self, other: &Unit, op: fn(Rational, Rational) -> Rational, scale: f64) -> Unit {
        let mut dimensions = self.dimensions.clone();
        for (dim, power) in &other.dimensions {
            let entry = dimensions.entry(dim.clone()).or_insert(Rational::int(0));
            *entry = op(*entry, *power);
            if entry.is_zero() {
                dimensions.remove(dim);
            }
        }
        Unit { dimensions, scale }
    }

    /// Raise unit to an integer power.
    pub fn power(&self, exponent: i32) -> Unit {
        self.power_rational(Rational::int(exponent))
    }

    /// Raise unit to a RATIONAL power. `sqrt` is `power_rational(1/2)`, and a
    /// literal `^0.5` in an expression lands here too.
    pub fn power_rational(&self, exponent: Rational) -> Unit {
        let dimensions = self
            .dimensions
            .iter()
            .map(|(dim, power)| (dim.clone(), power.mul(exponent)))
            .filter(|(_, power)| !power.is_zero())
            .collect();

        Unit {
            dimensions,
            scale: self.scale.powf(exponent.as_f64()),
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
        let mut findings = Vec::new();
        let dim = propagate_dim(expr, env, &mut findings);
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
        Expr::Operator(op) => propagate_operator_dim(op, env, findings),
    }
}

/// Propagate every argument, returning their dimensions positionally.
fn propagate_args(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    findings: &mut Vec<UnitFinding>,
) -> Vec<Dim> {
    op.args
        .iter()
        .map(|a| propagate_dim(a, env, findings))
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    match op.op.as_str() {
        "+" | "-" => propagate_additive_dim(op, env, findings),
        "*" | "/" => propagate_multiplicative_dim(op, env, findings),
        "^" | "power" | "pow" => propagate_power_dim(op, env, findings),
        "D" | "ic" => propagate_calculus_dim(op, env, findings),
        "exp" | "log" | "log10" | "ln" | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh" => {
            propagate_transcendental_dim(op, env, findings)
        }
        "sqrt" => propagate_sqrt_dim(op, env, findings),
        // abs/sign/floor/ceil preserve dimensions; `Pre` is an initial-value
        // marker — same dimensions as its argument.
        "abs" | "floor" | "ceil" | "round" | "sign" | "Pre" => {
            if !require_arity(op, 1, findings) {
                return Dim::Unknown;
            }
            propagate_dim(&op.args[0], env, findings)
        }
        "min" | "max" => propagate_matching_dim(op, env, findings),
        "atan2" => {
            if !require_arity(op, 2, findings) {
                return Dim::Unknown;
            }
            // Both arguments must share dimensions (their RATIO is what is fed
            // to the arctangent). The result is an ANGLE — `atan2(y, x)` is the
            // canonical spelling of a bearing.
            propagate_matching_dim(op, env, findings);
            Dim::Known(radian())
        }
        "ifelse" => propagate_ifelse_dim(op, env, findings),
        ">" | "<" | ">=" | "<=" | "==" | "!=" => {
            if !require_arity(op, 2, findings) {
                return Dim::Known(Unit::dimensionless());
            }
            // Operands must be comparable; the flag itself is dimensionless.
            propagate_matching_dim(op, env, findings);
            Dim::Known(Unit::dimensionless())
        }
        "and" | "or" | "not" => Dim::Known(Unit::dimensionless()),
        // Array operators: propagate the element dimension. Shape and
        // indexing are orthogonal to dimension (see gt-t5c / gt-vt3 — shapes
        // are a separate concern from unit checking).
        "aggregate" | "makearray" | "index" | "reshape" | "transpose" | "concat" | "broadcast" => {
            propagate_array_dim(op, env, findings)
        }
        // No dimensional rule for this operator — an unregistered user op, or a
        // rewrite-target sugar op (`grad`/`div`/`laplacian`/`fn`/`table_lookup`/
        // `godunov_hamiltonian`/…) whose dimension is UNDETERMINABLE until a
        // discretization rule lowers it (esm-spec §4.8.4). The checker reports
        // UNKNOWN and SKIPS: it emits NO finding, matching the other four
        // bindings (Julia/TS/Python/Go), which return an unknown dimension and
        // let their callers skip the check. The node's dimension is `Unknown` —
        // NOT a silent `dimensionless`, which would manufacture false mismatches
        // in the enclosing expression. `findings` is left untouched so nothing
        // is singled out; `_` treats `grad` exactly like any other no-rule op.
        _ => Dim::Unknown,
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    let mut first: Option<Unit> = None;
    let mut saw_non_literal = false;
    for arg in &op.args {
        if is_literal(arg) {
            continue;
        }
        saw_non_literal = true;
        let dim = propagate_dim(arg, env, findings);
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if op.args.is_empty() {
        return Dim::Known(Unit::dimensionless());
    }
    // Unary minus: propagate the single argument.
    if op.op == "-" && op.args.len() == 1 {
        return propagate_dim(&op.args[0], env, findings);
    }
    propagate_matching_dim(op, env, findings)
}

/// `*` / `/`: dimensions multiply / divide, no compatibility requirement.
fn propagate_multiplicative_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    let dims = propagate_args(op, env, findings);
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 2, findings) {
        return Dim::Unknown;
    }
    let base = propagate_dim(&op.args[0], env, findings);
    let exp = propagate_dim(&op.args[1], env, findings);

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
        Expr::Integer(i) => Some(f64::from(*i as i32)),
        Expr::Number(n) => Some(*n),
        _ => None,
    };
    match literal_exp {
        // Exponents are RATIONAL, so a fractional power of a dimensional
        // quantity (`x^0.5`) is representable and propagates exactly.
        Some(n) => match Rational::from_f64(n) {
            Some(r) => Dim::Known(base_unit.power_rational(r)),
            None => {
                findings.push(UnitFinding::analysis(format!(
                    "Exponent {n} is not a representable rational, so the dimension of a \
                     dimensional base is unknown"
                )));
                Dim::Unknown
            }
        },
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 1, findings) {
        return Dim::Unknown;
    }
    let arg = propagate_dim(&op.args[0], env, findings);
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
        .any(|(d, p)| *d != Dimension::Time && !p.is_zero());
    unreconcilable.then(|| {
        format!(
            "No time unit can reconcile d({})/dt with {} (their ratio {} is not a power of time)",
            describe(state),
            describe(rhs),
            describe(&ratio)
        )
    })
}

/// Transcendental and trigonometric functions: argument must be dimensionless,
/// result is dimensionless.
///
/// `sqrt` is NOT in this family — it halves its argument's dimensions (see
/// [`propagate_sqrt_dim`]).
///
/// The TRIGONOMETRIC members additionally accept a plane ANGLE: `rad` is a real
/// dimension axis here, so `sin(theta)` with `theta` in radians is correct, not
/// an error. `exp`/`log`/`log10`/`ln` still demand strict dimensionlessness.
fn propagate_transcendental_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    // `rad` is a real axis here, so the circular functions are NOT symmetric —
    // and getting this wrong is silently destructive in both directions:
    //
    // * FORWARD circular (`sin`/`cos`/`tan`) map an ANGLE to a ratio: they
    //   accept an angle OR a dimensionless argument, and return DIMENSIONLESS.
    //   (`sin(kg)` is still an error.)
    // * INVERSE circular (`asin`/`acos`/`atan`) map a ratio to an ANGLE: they
    //   require a DIMENSIONLESS argument and RETURN AN ANGLE. Asserting a
    //   dimensionless result while `rad` is an axis makes every
    //   `zenith: "rad"` computed by `acos(...)` a guaranteed false mismatch.
    // * The HYPERBOLIC family takes and returns pure numbers — a hyperbolic
    //   "angle" is an area, not a plane angle, so `rad` is not involved.
    // * `exp`/`log` demand strict dimensionlessness: their Taylor series adds
    //   powers of the argument.
    let is_inverse_circular = matches!(op.op.as_str(), "asin" | "acos" | "atan");
    let result = if is_inverse_circular {
        radian()
    } else {
        Unit::dimensionless()
    };

    if !require_arity(op, 1, findings) {
        // The result is fixed by the operator whatever the argument turns out
        // to be.
        return Dim::Known(result);
    }

    // Only the forward circular functions accept an angle.
    let angle_ok = matches!(op.op.as_str(), "sin" | "cos" | "tan");

    let arg = propagate_dim(&op.args[0], env, findings);
    if let Some(u) = arg.known() {
        let acceptable = if angle_ok {
            u.is_dimensionless_or_angle()
        } else {
            u.is_dimensionless()
        };
        if !acceptable {
            findings.push(UnitFinding::error(format!(
                "Argument to '{}' must be dimensionless{}, got {}",
                op.op,
                if angle_ok { " (or an angle)" } else { "" },
                describe(u)
            )));
        }
    }
    Dim::Known(result)
}

/// The radian — the unit of the `Angle` axis, returned by the inverse circular
/// functions.
fn radian() -> Unit {
    Unit::base(Dimension::Angle, 1, 1.0)
}

/// Square root HALVES its argument's dimensions — it is not a transcendental
/// function and does NOT require a dimensionless argument. Because exponents are
/// rational, `sqrt(m^3)` is exactly `m^3/2` rather than "not representable".
fn propagate_sqrt_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 1, findings) {
        return Dim::Unknown;
    }
    let arg = propagate_dim(&op.args[0], env, findings);
    match arg.known() {
        Some(unit) => Dim::Known(unit.power_rational(Rational::new(1, 2))),
        None => Dim::Unknown,
    }
}

/// `ifelse`: the two branches must share dimensions; the result carries them.
fn propagate_ifelse_dim(
    op: &ExpressionNode,
    env: &HashMap<String, Unit>,
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    if !require_arity(op, 3, findings) {
        return Dim::Unknown;
    }
    // The condition (arg 0) need not be dimensionless — comparison ops already
    // produce a dimensionless Boolean, and we don't want to reject bare scalars
    // used as truthiness flags. It is still walked so findings inside it (e.g.
    // a mismatched comparison) are reported.
    propagate_dim(&op.args[0], env, findings);
    let t = propagate_dim(&op.args[1], env, findings);
    let f = propagate_dim(&op.args[2], env, findings);
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
    findings: &mut Vec<UnitFinding>,
) -> Dim {
    match op.op.as_str() {
        "aggregate" => {
            // The body is the scalar expression evaluated for each tuple of
            // loop-index values; its dimension is the array's element
            // dimension.
            if let Some(body) = &op.expr {
                return propagate_dim(body, env, findings);
            }
            // Fallback: infer from the first positional arg.
            match op.args.first() {
                Some(first) => propagate_dim(first, env, findings),
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
                .map(|v| propagate_dim(v, env, findings))
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
            propagate_operator_dim(&synthetic, env, findings)
        }
        // "index" | "reshape" | "transpose" | "concat"
        _ => {
            // Shape-only reorderings: element dimension is inherited from
            // the first positional arg (the source array).
            match op.args.first() {
                Some(first) => propagate_dim(first, env, findings),
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
                Dimension::Angle => "angle",
            };
            if *p == Rational::int(1) {
                name.to_string()
            } else {
                format!("{name}^{p}")
            }
        })
        .collect();
    parts.sort();
    parts.join("*")
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
/// The two cases are NOT alike, and only one of them is a defect:
///
/// * A MISSING `units` field is a legitimate choice — the variable is simply
///   not dimension-checked.
/// * An UNPARSEABLE `units` field is a HARD ERROR (`unit_parse_error`,
///   esm-spec §4.8.4). A unit string either resolves against the shared
///   registry or it is a defect in the file: silently treating a typo
///   (`1/time`, `m/s2`) as "dimension unknown" disables every dimensional check
///   downstream, which is precisely the class of bug the checker exists to
///   catch. The failures are returned to the caller, which reports each one at
///   the JSON-Pointer of the offending DECLARATION.
///
/// Note this is a *different* case from a genuinely UNDETERMINABLE dimension (a
/// symbolic exponent), which stays a non-blocking warning: there the checker
/// cannot conclude, whereas here the author wrote something that is not a unit.
pub fn build_unit_env(
    variables: &HashMap<String, crate::ModelVariable>,
) -> (HashMap<String, Unit>, Vec<UnitParseFailure>) {
    let mut env = HashMap::new();
    let mut failures = Vec::new();
    for (name, var) in variables {
        let Some(declared) = &var.units else {
            // No declared units — dimension unknown, not dimensionless.
            continue;
        };
        match parse_unit(declared) {
            Ok(unit) => {
                env.insert(name.clone(), unit);
            }
            Err(_) => failures.push(UnitParseFailure {
                name: name.clone(),
                units: declared.clone(),
            }),
        }
    }
    // `variables` is a HashMap, so iteration order is nondeterministic; sort so
    // a multi-failure file reports its errors in a stable order.
    failures.sort_by(|a, b| a.name.cmp(&b.name));
    (env, failures)
}

/// A declared unit string that denotes no real unit.
///
/// Carries the NAME of the declaration alongside the offending string so the
/// caller can report `unit_parse_error` at the declaration's JSON-Pointer
/// rather than at the model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitParseFailure {
    /// The declaration's name (variable, species, or parameter).
    pub name: String,
    /// The unit string exactly as the author wrote it.
    pub units: String,
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
    if let Some(err) = check_equation_dimensions(eq, env)
        .iter()
        .find(|f| f.is_error())
    {
        return Err(UnitError::DimensionMismatch(err.message.clone()));
    }
    // Single-outcome contract: distinguish "checked, consistent" (`Ok`) from
    // "could not be checked" (`UnknownUnit`) — an equation with an indeterminate
    // side was SKIPPED, and reporting `Ok` would claim we verified it.
    let mut sink = Vec::new();
    let lhs = propagate_dim(&eq.lhs, env, &mut sink);
    let rhs = propagate_dim(&eq.rhs, env, &mut sink);
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
pub fn check_equation_dimensions(eq: &Equation, env: &HashMap<String, Unit>) -> Vec<UnitFinding> {
    let mut findings = Vec::new();
    let lhs = propagate_dim(&eq.lhs, env, &mut findings);
    let rhs = propagate_dim(&eq.rhs, env, &mut findings);

    // `D(x)/dt` with an undeclared `t` is indeterminate, so the plain LHS-vs-RHS
    // comparison below cannot see it. Apply the weaker time-ratio rule instead.
    if let Some(state) = derivative_of_undeclared_time(&eq.lhs, env) {
        let state_dim = propagate_dim(state, env, &mut Vec::new());
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
) -> Vec<UnitFinding> {
    let mut findings = Vec::new();
    let actual = propagate_dim(expr, env, &mut findings);

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
    parse_normalized(&normalize_unit_str(unit_str), unit_str)
}

/// Rewrite the ordinary earth-science spellings of a unit into the ASCII
/// grammar, BEFORE parsing.
///
/// These are not exotic: `W/m²`, `cm³`, `J/(kg·K)`, `kg⋅m/s`, `μg/m^3`, `°C` and
/// `Pa*m**3` all appear in the shared corpus and all failed to parse, leaving
/// their variables dimensionless-unknown and silently unchecked.
///
/// * superscript digits `⁰¹²³⁴⁵⁶⁷⁸⁹` and superscript minus `⁻` → `^n`
/// * middot `·` (U+00B7) and dot-operator `⋅` (U+22C5) → `*`
/// * `µ` (U+00B5) / `μ` (U+03BC) → `u`  (so `μg` is the `u` + `g` prefix form)
/// * `°C` → `degC`, `Ω` → `Ohm`
/// * `**` → `^`  (the Python spelling of a power)
fn normalize_unit_str(s: &str) -> String {
    // `°C` and `**` are two-character sequences, so handle them first.
    let s = s.replace("°C", "degC").replace("**", "^");

    let mut out = String::with_capacity(s.len());
    let mut in_superscript = false;
    for c in s.chars() {
        let sup = match c {
            '⁰' => Some('0'),
            '¹' => Some('1'),
            '²' => Some('2'),
            '³' => Some('3'),
            '⁴' => Some('4'),
            '⁵' => Some('5'),
            '⁶' => Some('6'),
            '⁷' => Some('7'),
            '⁸' => Some('8'),
            '⁹' => Some('9'),
            '⁻' => Some('-'),
            _ => None,
        };
        match sup {
            // A run of superscripts is one exponent: emit a single `^` before it.
            Some(ascii) => {
                if !in_superscript {
                    out.push('^');
                    in_superscript = true;
                }
                out.push(ascii);
            }
            None => {
                in_superscript = false;
                match c {
                    '·' | '⋅' | '×' => out.push('*'),
                    'µ' | 'μ' => out.push('u'),
                    'Ω' => out.push_str("Ohm"),
                    _ => out.push(c),
                }
            }
        }
    }
    out
}

/// Parse an already-normalized unit string. `original` is carried only for
/// error messages, so a diagnostic quotes what the author actually wrote.
fn parse_normalized(s: &str, original: &str) -> Result<Unit, UnitError> {
    let s = s.trim();
    if s.is_empty() || s == "1" || s == "dimensionless" {
        return Ok(Unit::dimensionless());
    }

    // Strip a single layer of surrounding parentheses when they balance.
    if s.starts_with('(') && s.ends_with(')') && parens_balance(&s[1..s.len() - 1]) {
        return parse_normalized(&s[1..s.len() - 1], original);
    }

    let base_units = get_base_units();
    if let Some(unit) = base_units.get(s) {
        return Ok(unit.clone());
    }
    // An SI-PREFIXED symbol (`mg`, `um`, `nm`, `mL`, `umol`, `dm`). Tried only
    // after the exact table, so a name that merely LOOKS prefixed (`min`, `mol`,
    // `cd`, `day`) keeps its own meaning. This is what makes the `µ`/`μ` → `u`
    // normalization above mean anything: `μg/m^3` reaches here as `ug/m^3`.
    if let Some(unit) = parse_si_prefixed(s, base_units) {
        return Ok(unit);
    }

    // Product / quotient. `*` and `/` share one precedence level and bind
    // LEFT-associatively, so we split at the LAST top-level operator and
    // recurse on the left. Splitting on `/` as a separate, looser level (as
    // this parser used to) pulls every `*` factor appearing after the last `/`
    // into the DENOMINATOR: `J/mol*K` parsed as `J/(mol*K)`, silently negating
    // K's exponent, and `kg/m^3*s` came out as `kg/(m^3*s)`. Equal-precedence
    // left association is the reading of the Go reference parser and of
    // pint/Unitful.
    //
    // WHITESPACE between two terms is an implicit multiplication (`ppb^-1 s^-1`),
    // so it is a top-level operator too.
    if let Some((idx, len, sym)) = find_last_top_level_operator(s) {
        let (left, right) = (&s[..idx], &s[idx + len..]);
        if left.trim().is_empty() || right.trim().is_empty() {
            return Err(UnitError::ParseError(format!(
                "Dangling '{sym}' in unit \"{original}\""
            )));
        }
        let l = parse_normalized(left, original)?;
        let r = parse_normalized(right, original)?;
        return Ok(match sym {
            '/' => l.divide(&r),
            _ => l.multiply(&r),
        });
    }

    // Power: right-most '^'. The exponent is RATIONAL — `s^0.5` and `m^(1/2)`
    // are legitimate (an SDE noise intensity carries `1/s^0.5`).
    if let Some(idx) = s.rfind('^') {
        let (base_s, pow_s) = (&s[..idx], &s[idx + 1..]);
        let base_unit = parse_normalized(base_s, original)?;
        let power = parse_exponent(pow_s).ok_or_else(|| {
            UnitError::ParseError(format!(
                "Invalid exponent \"{pow_s}\" in unit \"{original}\""
            ))
        })?;
        return Ok(base_unit.power_rational(power));
    }

    // A bare numeric atom is a dimensionless scale factor (`1000`, `0.5`).
    if let Ok(v) = s.parse::<f64>() {
        return Ok(Unit {
            dimensions: HashMap::new(),
            scale: v,
        });
    }

    Err(UnitError::UnknownUnit(original.to_string()))
}

/// Decompose an SI-prefixed symbol into prefix × base (`mg` → milli × gram).
///
/// Only the symbols in [`PREFIXABLE`] take a prefix, which keeps the
/// decomposition from inventing units out of arbitrary identifiers — `not_a_unit`
/// must still fail to parse, and a count like `units` must not be read as
/// micro-something. Prefixes are tried LONGEST-first so `da` (deca) is not
/// mistaken for `d` (deci).
fn parse_si_prefixed(s: &str, base_units: &HashMap<String, Unit>) -> Option<Unit> {
    /// (symbol, factor), longest symbol first.
    const PREFIXES: [(&str, f64); 20] = [
        ("da", 1e1),
        ("Y", 1e24),
        ("Z", 1e21),
        ("E", 1e18),
        ("P", 1e15),
        ("T", 1e12),
        ("G", 1e9),
        ("M", 1e6),
        ("k", 1e3),
        ("h", 1e2),
        ("d", 1e-1),
        ("c", 1e-2),
        ("m", 1e-3),
        ("u", 1e-6),
        ("n", 1e-9),
        ("p", 1e-12),
        ("f", 1e-15),
        ("a", 1e-18),
        ("z", 1e-21),
        ("y", 1e-24),
    ];
    /// Symbols that admit an SI prefix.
    const PREFIXABLE: [&str; 13] = [
        "m", "g", "s", "mol", "K", "A", "cd", "L", "N", "Pa", "J", "W", "rad",
    ];

    for (prefix, factor) in PREFIXES {
        let Some(base) = s.strip_prefix(prefix) else {
            continue;
        };
        if !PREFIXABLE.contains(&base) {
            continue;
        }
        let mut unit = base_units.get(base)?.clone();
        unit.scale *= factor;
        return Some(unit);
    }
    None
}

/// Parse a unit exponent: an integer (`2`, `-1`), a decimal (`0.5`, `-1.5`), or
/// a parenthesised fraction (`(1/2)`).
fn parse_exponent(s: &str) -> Option<Rational> {
    let s = s.trim();
    let inner = s
        .strip_prefix('(')
        .and_then(|rest| rest.strip_suffix(')'))
        .unwrap_or(s)
        .trim();
    if let Some((num, den)) = inner.split_once('/') {
        return Some(Rational::new(
            num.trim().parse().ok()?,
            den.trim().parse().ok()?,
        ));
    }
    if let Ok(n) = inner.parse::<i32>() {
        return Some(Rational::int(n));
    }
    Rational::from_f64(inner.parse::<f64>().ok()?)
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
/// Returns `(byte index, byte length, operator)`. The length matters because an
/// implicit multiplication is a RUN of whitespace, which the caller must skip
/// whole.
fn find_last_top_level_operator(s: &str) -> Option<(usize, usize, char)> {
    let bytes = s.as_bytes();
    let mut depth = 0i32;
    let mut last = None;
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            '*' | '/' if depth == 0 => last = Some((i, 1, c)),
            ' ' | '\t' if depth == 0 => {
                // A run of whitespace BETWEEN two terms is an implicit `*`.
                // Whitespace merely padding an explicit operator (`m / s`) is
                // not: the operator arm above already claimed that position, and
                // a run adjacent to one must not be treated as a second operator.
                let start = i;
                while i < bytes.len() && matches!(bytes[i] as char, ' ' | '\t') {
                    i += 1;
                }
                let before = s[..start].trim_end().chars().last();
                let after = s[i..].chars().next();
                let padding = matches!(before, Some('*' | '/' | '^') | None)
                    || matches!(after, Some('*' | '/' | '^') | None);
                if !padding {
                    last = Some((start, i - start, '*'));
                }
                continue;
            }
            _ => {}
        }
        i += 1;
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
    units.insert("meter".to_string(), Unit::base(Dimension::Length, 1, 1.0));
    units.insert("meters".to_string(), Unit::base(Dimension::Length, 1, 1.0));

    // Time units
    units.insert("s".to_string(), Unit::base(Dimension::Time, 1, 1.0));
    units.insert("min".to_string(), Unit::base(Dimension::Time, 1, 60.0));
    units.insert("h".to_string(), Unit::base(Dimension::Time, 1, 3600.0));
    units.insert("hr".to_string(), Unit::base(Dimension::Time, 1, 3600.0));
    units.insert("hour".to_string(), Unit::base(Dimension::Time, 1, 3600.0));
    // The canonical spelling of the day is `day`. A bare `d` is deliberately NOT
    // a unit (esm-spec §4.8.1): a one-letter symbol reads as the deci- prefix or
    // as a differential, so admitting it would make `d` ambiguous at every site.
    units.insert("day".to_string(), Unit::base(Dimension::Time, 1, 86400.0));

    // Mass units
    units.insert("kg".to_string(), Unit::base(Dimension::Mass, 1, 1.0));
    units.insert("g".to_string(), Unit::base(Dimension::Mass, 1, 0.001));

    // Amount units
    units.insert("mol".to_string(), Unit::base(Dimension::Amount, 1, 1.0));

    // Temperature units. `degC` (and its `°C` spelling, normalized to `degC`
    // before parsing) shares the TEMPERATURE dimension with kelvin: the two
    // differ by an affine OFFSET, which a multiplicative dimension algebra
    // cannot express, and dimensional analysis only cares about the axis.
    units.insert("K".to_string(), Unit::base(Dimension::Temperature, 1, 1.0));
    units.insert(
        "degC".to_string(),
        Unit::base(Dimension::Temperature, 1, 1.0),
    );
    units.insert(
        "Celsius".to_string(),
        Unit::base(Dimension::Temperature, 1, 1.0),
    );

    // Current / luminous intensity
    units.insert("A".to_string(), Unit::base(Dimension::Current, 1, 1.0));
    units.insert("cd".to_string(), Unit::base(Dimension::Luminosity, 1, 1.0));

    // Plane angle — a real axis (the eighth), not a synonym for dimensionless.
    // The trig functions accept it; see `propagate_transcendental_dim`.
    units.insert("rad".to_string(), Unit::base(Dimension::Angle, 1, 1.0));
    // Degrees of arc — the same axis, scaled. (`deg` is the short spelling; the
    // TEMPERATURE `degC`/`degF` are separate entries and are matched first, so
    // there is no collision.)
    let degree = Unit::base(Dimension::Angle, 1, std::f64::consts::PI / 180.0);
    units.insert("degrees".to_string(), degree.clone());
    units.insert("degree".to_string(), degree.clone());
    units.insert("deg".to_string(), degree);

    // Volume (L = dm³ = 10⁻³ m³)
    units.insert("L".to_string(), Unit::base(Dimension::Length, 3, 0.001));

    // Frequency: Hz = s⁻¹.
    units.insert("Hz".to_string(), Unit::base(Dimension::Time, -1, 1.0));

    // Fahrenheit shares the TEMPERATURE axis with kelvin, like `degC`: the
    // three differ by affine offset/scale, which a multiplicative dimension
    // algebra cannot express and dimensional analysis does not need.
    units.insert(
        "degF".to_string(),
        Unit::base(Dimension::Temperature, 1, 1.0),
    );

    // Year — the Julian-ish 365-day year used by the corpus's ecological
    // fixtures (`km^2/year`, `1/year`).
    units.insert(
        "year".to_string(),
        Unit::base(Dimension::Time, 1, 3.153_6e7),
    );
    units.insert("yr".to_string(), Unit::base(Dimension::Time, 1, 3.153_6e7));

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
    let watt = Unit::base(Dimension::Mass, 1, 1.0)
        .multiply(&Unit::base(Dimension::Length, 2, 1.0))
        .divide(&Unit::base(Dimension::Time, 3, 1.0));
    units.insert("W".to_string(), watt.clone());

    // Electromagnetic family, all derived from the ampere.
    //
    // `C` is the COULOMB (A·s), NOT Celsius — degrees Celsius is spelled
    // `degC`, and the `°C` form normalizes to it before parsing. A unit string
    // carries DIMENSIONS ONLY, so a bare `C` can never mean a chemical species
    // tag either.
    let ampere = Unit::base(Dimension::Current, 1, 1.0);
    let coulomb = ampere.multiply(&Unit::base(Dimension::Time, 1, 1.0));
    units.insert("C".to_string(), coulomb.clone());

    // Volt = W/A = kg*m^2/(s^3*A)
    let volt = watt.divide(&ampere);
    units.insert("V".to_string(), volt.clone());

    // Ohm = V/A. Reached from the `Ω` spelling too, which normalizes to `Ohm`.
    units.insert("Ohm".to_string(), volt.divide(&ampere));

    // Farad = C/V (so `F/m`, the permittivity of the corpus, is F ÷ metre).
    units.insert("F".to_string(), coulomb.divide(&volt));

    // Tesla = kg/(s^2*A). The weber appears in the corpus as the composite
    // `V*s`, which the parser builds from `V` and `s`, so it needs no entry.
    units.insert(
        "T".to_string(),
        Unit::base(Dimension::Mass, 1, 1.0)
            .divide(&Unit::base(Dimension::Time, 2, 1.0))
            .divide(&ampere),
    );

    // Non-SI energies, as multiples of the joule.
    let joule_scaled = |scale: f64| {
        let mut u = joule.clone();
        u.scale *= scale;
        u
    };
    units.insert("erg".to_string(), joule_scaled(1e-7));
    units.insert("BTU".to_string(), joule_scaled(1_055.055_852_62));
    units.insert("kWh".to_string(), joule_scaled(3.6e6));

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
    // Percent — dimensionless with a scale, like the mole-fraction family.
    units.insert("%".to_string(), dimensionless_scaled(0.01));
    units.insert("percent".to_string(), dimensionless_scaled(0.01));

    // COUNTS carry no dimension axis: they count entities, they do not measure
    // one. Composites therefore fall out of the parser with the right dimension
    // on their own — `molec/cm^3` is `[length]^-3`, `individuals/km^2` is
    // `[length]^-2`.
    for count in [
        "molec",
        "molecule",
        "count",
        "individuals",
        "vehicles",
        "units",
    ] {
        units.insert(count.to_string(), Unit::dimensionless());
    }

    // Practical salinity — dimensionless by definition (PSS-78).
    units.insert("psu".to_string(), Unit::dimensionless());

    // Pressure: atmosphere, and the micro-atmosphere used for seawater pCO2.
    units.insert("atm".to_string(), pascal_scaled(&units, 101_325.0));
    units.insert("uatm".to_string(), pascal_scaled(&units, 0.101_325));
    // Non-SI pressures, as multiples of the pascal.
    units.insert("bar".to_string(), pascal_scaled(&units, 1e5));
    units.insert("Torr".to_string(), pascal_scaled(&units, 133.322_368_421));
    units.insert("mmHg".to_string(), pascal_scaled(&units, 133.322_387_415));
    units.insert("psi".to_string(), pascal_scaled(&units, 6_894.757_293_168));

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

/// A pressure unit expressed as a multiple of the pascal already in `units`.
fn pascal_scaled(units: &HashMap<String, Unit>, scale: f64) -> Unit {
    let mut u = units["Pa"].clone();
    u.scale *= scale;
    u
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

    /// Exponents are RATIONAL. `1/s^0.5` is the intensity of an SDE noise term
    /// and appears in the shared corpus (`tests/fixtures/sde/*.esm`); an
    /// integer-only grammar could not parse it at all.
    #[test]
    fn test_rational_exponents() {
        let half = Rational::new(-1, 2);
        assert_eq!(
            parse_unit("1/s^0.5")
                .unwrap()
                .dimensions
                .get(&Dimension::Time),
            Some(&half)
        );
        // The fraction and decimal spellings agree.
        assert_eq!(
            parse_unit("s^(-1/2)")
                .unwrap()
                .dimensions
                .get(&Dimension::Time),
            Some(&half)
        );
        // `**` is the Python spelling of a power.
        assert_eq!(
            parse_unit("m**3")
                .unwrap()
                .dimensions
                .get(&Dimension::Length),
            Some(&Rational::int(3))
        );
        // Reduced to lowest terms, so 2/4 IS 1/2.
        assert_eq!(Rational::new(2, 4), Rational::new(1, 2));
        assert_eq!(Rational::from_f64(0.5), Some(Rational::new(1, 2)));
    }

    /// Ordinary earth-science spellings must parse: superscripts, the middot and
    /// dot-operator, micro, degree-Celsius and ohm.
    #[test]
    fn test_unicode_normalization() {
        // W/m² — superscript exponent.
        let u = parse_unit("W/m²").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-3)));
        // Length cancels: W carries m^2, divided by m^2.
        assert_eq!(u.dimensions.get(&Dimension::Length), None);

        assert_eq!(
            parse_unit("cm³")
                .unwrap()
                .dimensions
                .get(&Dimension::Length),
            Some(&Rational::int(3))
        );
        // Superscript minus.
        assert_eq!(
            parse_unit("m⁻³")
                .unwrap()
                .dimensions
                .get(&Dimension::Length),
            Some(&Rational::int(-3))
        );
        // Middot (U+00B7) and dot-operator (U+22C5) are multiplication.
        assert_eq!(
            parse_unit("J/(kg·K)").unwrap(),
            parse_unit("J/(kg*K)").unwrap()
        );
        assert_eq!(parse_unit("kg⋅m/s").unwrap(), parse_unit("kg*m/s").unwrap());
        // Micro, in both its spellings.
        assert_eq!(parse_unit("μg/m^3").unwrap(), parse_unit("ug/m^3").unwrap());
        assert_eq!(parse_unit("µg").unwrap(), parse_unit("ug").unwrap());
        // °C shares the temperature axis with K (they differ by an affine
        // offset, which dimensional analysis does not model).
        assert!(
            parse_unit("°C")
                .unwrap()
                .is_compatible(&parse_unit("K").unwrap())
        );
    }

    /// Whitespace between two terms is an implicit multiplication.
    #[test]
    fn test_implicit_multiplication() {
        assert_eq!(
            parse_unit("ppb^-1 s^-1").unwrap(),
            parse_unit("ppb^-1*s^-1").unwrap()
        );
        // But whitespace merely PADDING an explicit operator is not a second
        // operator.
        assert_eq!(parse_unit("m / s").unwrap(), parse_unit("m/s").unwrap());
        assert_eq!(parse_unit("kg * m").unwrap(), parse_unit("kg*m").unwrap());
    }

    /// SI prefixes resolve against the prefixable symbols — which is what makes
    /// the `µ` → `u` normalization useful — but must not invent units out of
    /// arbitrary identifiers, nor shadow a name that merely looks prefixed.
    #[test]
    fn test_si_prefixes() {
        assert_eq!(
            parse_unit("mg").unwrap().dimensions.get(&Dimension::Mass),
            Some(&Rational::int(1))
        );
        assert!((parse_unit("mg").unwrap().scale - 1e-6).abs() < 1e-18);
        assert!((parse_unit("um").unwrap().scale - 1e-6).abs() < 1e-18);
        assert!((parse_unit("nm").unwrap().scale - 1e-9).abs() < 1e-21);
        assert_eq!(parse_unit("mL").unwrap(), {
            let mut l = parse_unit("L").unwrap();
            l.scale *= 1e-3;
            l
        });
        assert_eq!(
            parse_unit("umol")
                .unwrap()
                .dimensions
                .get(&Dimension::Amount),
            Some(&Rational::int(1))
        );
        // Exact names win over a prefix reading: `min` is minutes, not milli-in.
        assert!((parse_unit("min").unwrap().scale - 60.0).abs() < 1e-9);
        assert_eq!(
            parse_unit("mol")
                .unwrap()
                .dimensions
                .get(&Dimension::Amount),
            Some(&Rational::int(1))
        );
        // A prefix on a non-prefixable identifier is NOT a unit.
        assert!(parse_unit("not_a_unit").is_err());
    }

    /// Counts carry no dimension axis, so composites come out with the right
    /// dimension on their own.
    #[test]
    fn test_counts_are_dimensionless() {
        for c in [
            "molec",
            "molecule",
            "count",
            "individuals",
            "vehicles",
            "units",
        ] {
            assert!(
                parse_unit(c).unwrap().is_dimensionless(),
                "{c} must be dimensionless"
            );
        }
        // individuals/km^2 is an inverse area.
        assert_eq!(
            parse_unit("individuals/km^2")
                .unwrap()
                .dimensions
                .get(&Dimension::Length),
            Some(&Rational::int(-2))
        );
        assert!(parse_unit("psu").unwrap().is_dimensionless());
        assert!(parse_unit("%").unwrap().is_dimensionless());
        assert!((parse_unit("%").unwrap().scale - 0.01).abs() < 1e-12);
        // uatm is a pressure.
        assert!(
            parse_unit("uatm")
                .unwrap()
                .is_compatible(&parse_unit("Pa").unwrap())
        );
    }

    /// `sqrt` HALVES a dimension — it is not a transcendental and does not
    /// require a dimensionless argument. With rational exponents `sqrt(m^3)` is
    /// exactly `m^3/2` rather than "not representable".
    #[test]
    fn test_sqrt_halves_dimensions() {
        let env = env_of(&[("area", "m^2"), ("vol", "m^3")]);

        let e = op("sqrt", vec![Expr::Variable("area".into())]);
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert!(check_expression_dimensions(&e, None, &env).is_empty());

        let e = op("sqrt", vec![Expr::Variable("vol".into())]);
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::new(3, 2))
        );
        assert!(
            !check_expression_dimensions(&e, None, &env)
                .iter()
                .any(UnitFinding::is_error),
            "sqrt of an odd power is representable, not an error"
        );
    }

    /// `rad` is a real axis, so a trig function accepts an ANGLE — but `exp` and
    /// `log` still demand strict dimensionlessness.
    #[test]
    fn test_trig_accepts_angle_but_exp_does_not() {
        let env = env_of(&[("theta", "rad"), ("m", "m")]);

        let e = op("sin", vec![Expr::Variable("theta".into())]);
        assert!(
            !check_expression_dimensions(&e, None, &env)
                .iter()
                .any(UnitFinding::is_error),
            "sin(theta) with theta in radians is correct"
        );

        // A LENGTH is still wrong for sin.
        let e = op("sin", vec![Expr::Variable("m".into())]);
        assert!(
            check_expression_dimensions(&e, None, &env)
                .iter()
                .any(UnitFinding::is_error)
        );

        // exp of an angle is a dimensional argument.
        let e = op("exp", vec![Expr::Variable("theta".into())]);
        assert!(
            check_expression_dimensions(&e, None, &env)
                .iter()
                .any(UnitFinding::is_error),
            "exp requires strict dimensionlessness"
        );
    }

    /// The derivative rule leaves the TIME exponent free and requires only that
    /// the non-time dimensions reconcile — so `x` in metres with an RHS in
    /// `m/s^2` is accepted (some time unit reconciles it), while `m` against
    /// `kg` never can be.
    #[test]
    fn test_derivative_time_exponent_is_free() {
        let env = env_of(&[("x", "m"), ("accel", "m/s^2"), ("mass", "kg")]);

        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("x".into())], "t"),
            rhs: Expr::Variable("accel".into()),
        };
        assert!(
            !check_equation_dimensions(&eq, &env)
                .iter()
                .any(UnitFinding::is_error),
            "ratio m/(m/s^2) = s^2 is a power of time ⇒ reconcilable"
        );

        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("x".into())], "t"),
            rhs: Expr::Variable("mass".into()),
        };
        assert!(
            check_equation_dimensions(&eq, &env)
                .iter()
                .any(UnitFinding::is_error),
            "ratio m/kg is not a power of time ⇒ provable mismatch"
        );
    }

    #[test]
    fn test_parse_base_units() {
        assert_eq!(
            parse_unit("m").unwrap().dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(
            parse_unit("s").unwrap().dimensions.get(&Dimension::Time),
            Some(&Rational::int(1))
        );
        assert_eq!(
            parse_unit("kg").unwrap().dimensions.get(&Dimension::Mass),
            Some(&Rational::int(1))
        );
    }

    #[test]
    fn test_parse_compound_units() {
        let u = parse_unit("m/s").unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-1)));

        let u = parse_unit("mol/L").unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Amount),
            Some(&Rational::int(1))
        );
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-3))
        );
    }

    #[test]
    fn test_parse_parenthesised_units() {
        // J/(mol*K) == kg*m^2/(s^2*mol*K)
        let u = parse_unit("J/(mol*K)").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(2))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-2)));
        assert_eq!(
            u.dimensions.get(&Dimension::Amount),
            Some(&Rational::int(-1))
        );
        assert_eq!(
            u.dimensions.get(&Dimension::Temperature),
            Some(&Rational::int(-1))
        );
    }

    #[test]
    fn test_parse_pascal_and_kg_per_m3() {
        let pa = parse_unit("Pa").unwrap();
        assert_eq!(pa.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(
            pa.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-1))
        );
        assert_eq!(
            pa.dimensions.get(&Dimension::Time),
            Some(&Rational::int(-2))
        );

        let rho = parse_unit("kg/m^3").unwrap();
        assert_eq!(
            rho.dimensions.get(&Dimension::Mass),
            Some(&Rational::int(1))
        );
        assert_eq!(
            rho.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-3))
        );
    }

    #[test]
    fn test_parse_negative_power() {
        let inv_s = parse_unit("s^-1").unwrap();
        assert_eq!(
            inv_s.dimensions.get(&Dimension::Time),
            Some(&Rational::int(-1))
        );
    }

    #[test]
    fn test_division_is_left_associative() {
        // `W/m^2/K` must parse as `(W/m^2)/K = W/(m^2*K)`, not the
        // right-associative `W/(m^2/K) = W*K/m^2`. W = kg*m^2/s^3, so the
        // correct result is kg*s^-3*K^-1: Temperature power -1 (a +1 would
        // betray the old right-associative bug).
        let u = parse_unit("W/m^2/K").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-3)));
        assert_eq!(
            u.dimensions.get(&Dimension::Temperature),
            Some(&Rational::int(-1))
        );
        // Length cancels: m^2 (from W) divided by m^2 leaves power 0 (absent).
        assert_eq!(u.dimensions.get(&Dimension::Length), None);
    }

    #[test]
    fn test_find_last_top_level_operator() {
        // `a/b/c` splits at the *last* top-level operator so parse_unit recurses
        // on the left `a/b`, yielding left-associative `(a/b)/c`.
        assert_eq!(find_last_top_level_operator("a/b/c"), Some((3, 1, '/')));
        assert_eq!(find_last_top_level_operator("a*b*c"), Some((3, 1, '*')));
        // `*` and `/` share one precedence level, so the LAST of either wins:
        // `a/b*c` is `(a/b)*c`, not `a/(b*c)`.
        assert_eq!(find_last_top_level_operator("a/b*c"), Some((3, 1, '*')));
        // Separators inside parentheses are hidden from the top-level scan.
        assert_eq!(find_last_top_level_operator("a/(b/c)"), Some((1, 1, '/')));
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
        assert_eq!(
            u.dimensions.get(&Dimension::Temperature),
            Some(&Rational::int(1))
        );
        assert_eq!(
            u.dimensions.get(&Dimension::Amount),
            Some(&Rational::int(-1))
        );

        let u = parse_unit("kg/m^3*s").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(1)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-3))
        );

        // Repeated division stays left-associative: m/s/s == m/s^2.
        let u = parse_unit("m/s/s").unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-2)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );

        // Parenthesised denominators are unaffected.
        let u = parse_unit("J/(mol*K)").unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Temperature),
            Some(&Rational::int(-1))
        );
        assert_eq!(
            u.dimensions.get(&Dimension::Amount),
            Some(&Rational::int(-1))
        );
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
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-2)));
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
        assert_eq!(
            v.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(v.dimensions.get(&Dimension::Time), Some(&Rational::int(-1)));
        assert_eq!(
            m.power(2).dimensions.get(&Dimension::Length),
            Some(&Rational::int(2))
        );
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
        assert_eq!(
            u.dimensions.get(&Dimension::Temperature),
            Some(&Rational::int(1))
        );
        assert!(check_expression_dimensions(&expr, None, &env).is_empty());

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
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(2))
        );
    }

    #[test]
    fn propagate_variable_lookup() {
        let env = env_of(&[("v", "m/s")]);
        let u = Unit::propagate(&Expr::Variable("v".into()), &env).unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-1)));
    }

    #[test]
    fn propagate_time_variable_default() {
        let env = HashMap::new();
        let u = Unit::propagate(&Expr::Variable("t".into()), &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(1)));
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
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
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
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-2))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-1)));
    }

    #[test]
    fn propagate_division_subtracts_dims() {
        let env = env_of(&[("m1", "kg"), ("V", "m^3")]);
        let e = op(
            "/",
            vec![Expr::Variable("m1".into()), Expr::Variable("V".into())],
        );
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(-3))
        );
    }

    #[test]
    fn propagate_power_integer() {
        let env = env_of(&[("s", "m")]);
        let e = op("^", vec![Expr::Variable("s".into()), Expr::Number(3.0)]);
        let u = Unit::propagate(&e, &env).unwrap();
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(3))
        );
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
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
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

    /// The spatial-calculus sugar ops (`grad` / `div` / `laplacian` / `curl` /
    /// `∇` / `integral`) are ORDINARY open-tier rewrite targets with NO
    /// privileged dimensional rule (esm-spec §4.2 / §4.8.3). Their dimension is
    /// UNDETERMINABLE until a discretization rule lowers them, so propagation
    /// yields an unknown dimension via the same no-rule path as any unregistered
    /// user op — never the old bespoke "divide by a metre denominator"
    /// behaviour. Per esm-spec §4.8.4 an unlowered op is reported as UNKNOWN and
    /// SKIPPED: it emits NO finding at all, matching the other four bindings
    /// (Julia/TS/Python/Go). `grad` is not singled out.
    #[test]
    fn propagate_spatial_sugar_ops_are_undeterminable() {
        let env = env_of(&[("c", "mol/m^3")]);
        for op_name in ["grad", "div", "laplacian", "curl", "∇", "integral"] {
            let e = op(op_name, vec![Expr::Variable("c".into())]);
            // No dimensional rule ⇒ undeterminable, so `propagate` cannot
            // conclude a unit.
            assert!(
                matches!(Unit::propagate(&e, &env), Err(UnitError::UnknownUnit(_))),
                "{op_name} must have an undeterminable dimension"
            );
            // Report-unknown-and-skip: NO finding at all — not a promotable
            // `Error`, and not even a non-blocking `Analysis`. The checker just
            // declines to fabricate a dimension it cannot know.
            let findings = check_expression_dimensions(&e, None, &env);
            assert!(
                findings.is_empty(),
                "{op_name} must emit no finding (report unknown + skip): {findings:?}"
            );
        }
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
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
        assert_eq!(u.dimensions.get(&Dimension::Time), Some(&Rational::int(-1)));
    }

    #[test]
    fn propagate_index_inherits_from_source() {
        let env = env_of(&[("arr", "kg")]);
        let node = op(
            "index",
            vec![Expr::Variable("arr".into()), Expr::Number(0.0)],
        );
        let u = Unit::propagate(&node, &env).unwrap();
        assert_eq!(u.dimensions.get(&Dimension::Mass), Some(&Rational::int(1)));
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
        assert_eq!(
            u.dimensions.get(&Dimension::Length),
            Some(&Rational::int(1))
        );
    }

    #[test]
    fn propagate_unknown_operator_reports_unknown_and_skips() {
        // An operator with no dimensional rule means the CHECKER cannot
        // conclude anything — it is not a defect in the file. Per esm-spec
        // §4.8.4 it reports UNKNOWN and SKIPS: an unknown dimension and NO
        // finding at all (matching Julia/TS/Python/Go), never a promotable
        // `Error` and never a silent `dimensionless`.
        let env = HashMap::new();
        let e = op("zorp", vec![Expr::Number(1.0)]);
        let findings = check_expression_dimensions(&e, None, &env);
        assert!(findings.is_empty(), "expected no finding, got {findings:?}");
        assert!(matches!(
            Unit::propagate(&e, &env),
            Err(UnitError::UnknownUnit(_))
        ));
    }

    /// An undeterminable operand must not SUPPRESS a provable mismatch
    /// elsewhere in the same expression: propagation yields `Unknown` for it and
    /// keeps walking instead of bailing at the first one.
    #[test]
    fn undeterminable_operand_does_not_hide_a_real_mismatch() {
        let env = env_of(&[("len", "m"), ("mass", "kg")]);
        // (zorp(1) + len) + mass — the unknown op is undeterminable (reported as
        // unknown and skipped, so it emits NO finding of its own), but the `len`
        // vs `mass` mismatch after it is still proven.
        let expr = op(
            "+",
            vec![
                op("zorp", vec![Expr::Number(1.0)]),
                Expr::Variable("len".into()),
                Expr::Variable("mass".into()),
            ],
        );
        let findings = check_expression_dimensions(&expr, None, &env);
        assert!(
            findings.iter().any(UnitFinding::is_error),
            "the m-vs-kg mismatch must still be proven: {findings:?}"
        );
        // The no-rule op adds nothing: the only finding is the real mismatch.
        assert!(
            findings.iter().all(UnitFinding::is_error),
            "the undeterminable op must not add a finding of its own: {findings:?}"
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
        let findings = check_equation_dimensions(&eq, &env);
        assert!(findings.iter().any(UnitFinding::is_error), "{findings:?}");

        // d(m)/dt = m/s: ratio is exactly `s` ⇒ reconcilable, no finding.
        let eq = Equation {
            lhs: op_with_wrt("D", vec![Expr::Variable("h".into())], "t"),
            rhs: Expr::Variable("v".into()),
        };
        assert!(
            !check_equation_dimensions(&eq, &env)
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
            !check_equation_dimensions(&eq, &env)
                .iter()
                .any(UnitFinding::is_error)
        );
    }

    /// Build a bare state [`crate::ModelVariable`] carrying only a declared
    /// unit string (all other metadata omitted).
    fn state_var_with_units(units: Option<&str>) -> crate::ModelVariable {
        crate::ModelVariable {
            default_units: None,
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

        let (env, failures) = build_unit_env(&variables);

        // The unparseable variable is OMITTED (unknown), NOT coerced to a
        // dimensionless unit; the parseable one is present.
        assert!(
            !env.contains_key("x"),
            "unparseable unit must not be in env"
        );
        assert!(env.contains_key("y"));

        // The failure is REPORTED, naming the offending variable and the string
        // the author actually wrote, so the caller can raise a hard
        // `unit_parse_error` at `/models/<M>/variables/x` (esm-spec §4.8.4).
        assert_eq!(
            failures,
            vec![UnitParseFailure {
                name: "x".to_string(),
                units: "not_a_unit".to_string(),
            }]
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
