//! Working precision of the evaluator — `domain.element_type` (esm-spec §11.3).
//!
//! # What `element_type: "Float32"` means
//!
//! It means the evaluator computes in **binary32, rounding once per
//! operation** — not "store f32, compute f64". The distinction is not
//! cosmetic: it decides answers. `100 * ((100 - 73.5) / 100) / (100 - 73.5)`
//! is exactly `1.0` in binary64 and `0.99999994` in binary32, and downstream
//! a comparison against such a residual decides which rows a relational model
//! emits at all. A field stored as f32 but multiplied in f64 reproduces
//! neither.
//!
//! # Representation
//!
//! Values keep their `f64` carrier (`Value::Scalar(f64)`, `ArrayD<f64>`); what
//! changes is the arithmetic. Every operation in [`Precision::Float32`] mode
//! converts its operands to `f32`, applies the `f32` operation, and widens the
//! `f32` result back — so every live value is exactly representable in
//! binary32 and every rounding step is the binary32 one. Widening f32→f64 is
//! exact, so the carrier is invisible; this is genuine binary32 arithmetic, not
//! f64 arithmetic with a cast at the end.
//!
//! Two ingress rules keep that invariant total:
//!
//! * **Literals and bindings round on entry** (numbers in the AST, parameter
//!   values, state/observed/forcing reads, `t`), so a value that reaches an
//!   output without passing through any operator is still binary32.
//! * **Loop index bindings do NOT round.** They are integers, exact in `f64`,
//!   and are consumed as array subscripts. Index *arithmetic* (`i + 1`) still
//!   goes through the f32 kernels and so is exact only while every index stays
//!   below `2^24`; [`check_index_set_extent`] rejects a Float32 document whose
//!   declared index sets exceed that rather than let a subscript silently
//!   round.
//!
//! # Where the mode lives
//!
//! A thread-local, set by an RAII [`PrecisionGuard`] at each entry point that
//! has a document (and re-armed from the compiled artifact at each run entry,
//! so a compiled model carries its own precision). The kernels read it where
//! they resolve an operator, which is once per AST node on the vectorized and
//! taped paths and once per cell on the oracle — the same place the operator
//! name is already being matched.
//!
//! [`Precision::Float64`] is the default and takes the identical code path it
//! took before this module existed: `active()` returns `Float64`, every
//! `is_f32()` branch is not taken, and the f64 kernel tables are the same
//! tables. Float64 results are bit-unchanged by construction, not by testing.

use std::cell::Cell;

use crate::compile_error::CompileError;
use crate::types::Expr;

/// The evaluator's working floating-point precision.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub enum Precision {
    /// IEEE binary64 — the default, and the precision every document that does
    /// not say otherwise evaluates in.
    #[default]
    Float64,
    /// IEEE binary32, rounded per operation.
    Float32,
}

impl Precision {
    /// Parse a `domain.element_type` string.
    ///
    /// `None` (the field absent) is [`Precision::Float64`], the schema default.
    ///
    /// # Errors
    ///
    /// [`CompileError::UnsupportedElementType`] for any other spelling. The
    /// schema `enum` already restricts the field to the two names, but a
    /// document reaching the evaluator has not necessarily been schema-checked,
    /// and quietly treating an unknown element type as f64 is the exact silent
    /// fallback this module exists to remove.
    pub fn from_element_type(s: Option<&str>) -> Result<Self, CompileError> {
        match s {
            None | Some("Float64") => Ok(Precision::Float64),
            Some("Float32") => Ok(Precision::Float32),
            Some(other) => Err(CompileError::UnsupportedElementType {
                element_type: other.to_string(),
            }),
        }
    }

    /// Is this the binary32 mode?
    #[inline(always)]
    #[must_use]
    pub fn is_f32(self) -> bool {
        matches!(self, Precision::Float32)
    }

    /// Round a value to this precision. Identity in [`Precision::Float64`].
    #[inline(always)]
    #[must_use]
    pub fn round(self, v: f64) -> f64 {
        match self {
            Precision::Float64 => v,
            Precision::Float32 => v as f32 as f64,
        }
    }

    /// The `domain.element_type` spelling.
    #[must_use]
    pub fn element_type(self) -> &'static str {
        match self {
            Precision::Float64 => "Float64",
            Precision::Float32 => "Float32",
        }
    }
}

thread_local! {
    /// The precision the current thread evaluates in. Written only through
    /// [`PrecisionGuard`], which restores the previous value on drop, so a
    /// nested build/solve cannot leak a mode to its caller.
    static ACTIVE: Cell<Precision> = const { Cell::new(Precision::Float64) };
}

/// The precision the current thread is evaluating in.
#[inline(always)]
#[must_use]
pub fn active() -> Precision {
    ACTIVE.with(Cell::get)
}

/// Shorthand for `active().is_f32()`.
#[inline(always)]
#[must_use]
pub fn is_f32() -> bool {
    active().is_f32()
}

/// Round `v` to the active precision (identity under Float64).
#[inline(always)]
#[must_use]
pub fn round(v: f64) -> f64 {
    active().round(v)
}

/// Restores the enclosing [`Precision`] when dropped.
#[must_use = "the precision is restored as soon as the guard is dropped"]
pub struct PrecisionGuard {
    prev: Precision,
}

impl Drop for PrecisionGuard {
    fn drop(&mut self) {
        ACTIVE.with(|c| c.set(self.prev));
    }
}

/// Evaluate in `p` until the returned guard is dropped.
pub fn enter(p: Precision) -> PrecisionGuard {
    let prev = ACTIVE.with(|c| c.replace(p));
    PrecisionGuard { prev }
}

/// Largest integer every binary32 value below it represents exactly.
///
/// Index arithmetic shares the value kernels (there is no integer type in the
/// expression language), so a subscript above this would round.
pub const F32_EXACT_INT_LIMIT: i64 = 1 << 24;

/// Reject an index-set extent a Float32 subscript could not address exactly.
///
/// # Errors
///
/// [`CompileError::Float32Unsupported`] naming the index set.
pub fn check_index_set_extent(name: &str, size: i64) -> Result<(), CompileError> {
    if size > F32_EXACT_INT_LIMIT {
        return Err(CompileError::Float32Unsupported {
            construct: format!("index set `{name}` of size {size}"),
            reason: format!(
                "index expressions share the value kernels, so a subscript above \
                 2^24 ({F32_EXACT_INT_LIMIT}) would round under \
                 `domain.element_type: \"Float32\"`"
            ),
        });
    }
    Ok(())
}

/// Operators whose numeric work happens **outside** the shared scalar kernel
/// layer, in hand-written binary64 code, and which therefore cannot honour a
/// Float32 declaration.
///
/// Returning the reason (rather than a bare bool) keeps the diagnostic
/// specific: a Float32 document that uses one of these gets an error naming the
/// construct, never a subexpression that quietly evaluated in binary64.
#[must_use]
pub fn f32_unsupported_reason(op: &str, fn_name: Option<&str>) -> Option<(String, String)> {
    let geometry = |op: &str| {
        (
            format!("operator `{op}`"),
            "polygon clipping and area are computed by the binary64 geometry \
             kernels (`crate::geometry`), which have no binary32 form"
                .to_string(),
        )
    };
    match op {
        "intersect_polygon" | "polygon_intersection_area" => Some(geometry(op)),
        "fn" => match fn_name {
            // Interpolation walks a binary64 table and blends in binary64.
            Some(n @ ("interp.linear" | "interp.bilinear")) => Some((
                format!("closed function `{n}`"),
                "table interpolation is evaluated by the binary64 closed-function \
                 registry, which has no binary32 form"
                    .to_string(),
            )),
            // A Julian day is ~2.46e6 with a fractional part; binary32 cannot
            // hold it to better than ~0.25 s, so returning one under Float32
            // would be a silent precision cliff rather than a rounding.
            Some(n @ "datetime.julian_day") => Some((
                format!("closed function `{n}`"),
                "a Julian day number exceeds binary32's exact-integer range, so \
                 its fractional part would be destroyed by the declared precision"
                    .to_string(),
            )),
            // The remaining closed functions (`datetime.year`,
            // `datetime.day_of_year`, `datetime.is_leap_year`,
            // `interp.searchsorted`) return small exact integers, which binary32
            // represents exactly.
            _ => None,
        },
        _ => None,
    }
}

/// Reject every construct in `expr` that cannot be evaluated in binary32.
///
/// A no-op unless the active precision is [`Precision::Float32`]; call it from
/// the compile paths alongside the other operator gates.
///
/// # Errors
///
/// [`CompileError::Float32Unsupported`] naming the first offending construct.
pub fn check_f32_supported(expr: &Expr) -> Result<(), CompileError> {
    if !is_f32() {
        return Ok(());
    }
    check_f32_supported_tree(expr)
}

fn check_f32_supported_tree(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    let fn_name = node.name.as_deref();
    if let Some((construct, reason)) = f32_unsupported_reason(&node.op, fn_name) {
        return Err(CompileError::Float32Unsupported { construct, reason });
    }
    let mut first_err: Option<CompileError> = None;
    node.for_each_child(&mut |child| {
        if first_err.is_none()
            && let Err(e) = check_f32_supported_tree(child)
        {
            first_err = Some(e);
        }
    });
    match first_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_float64_and_round_is_identity() {
        assert_eq!(active(), Precision::Float64);
        // A value with no binary32 representation survives untouched.
        let v = 0.1_f64;
        assert_eq!(round(v).to_bits(), v.to_bits());
    }

    #[test]
    fn guard_sets_and_restores() {
        assert!(!is_f32());
        {
            let _g = enter(Precision::Float32);
            assert!(is_f32());
            assert_eq!(round(0.1_f64), 0.1_f32 as f64);
            {
                let _inner = enter(Precision::Float64);
                assert!(!is_f32());
            }
            assert!(is_f32(), "the inner guard restores Float32, not the default");
        }
        assert!(!is_f32());
    }

    #[test]
    fn element_type_parsing() {
        assert_eq!(
            Precision::from_element_type(None).unwrap(),
            Precision::Float64
        );
        assert_eq!(
            Precision::from_element_type(Some("Float64")).unwrap(),
            Precision::Float64
        );
        assert_eq!(
            Precision::from_element_type(Some("Float32")).unwrap(),
            Precision::Float32
        );
        // Not a silent fallback to f64.
        assert!(Precision::from_element_type(Some("Float16")).is_err());
        assert!(Precision::from_element_type(Some("float32")).is_err());
    }

    #[test]
    fn f32_unsupported_set() {
        assert!(f32_unsupported_reason("intersect_polygon", None).is_some());
        assert!(f32_unsupported_reason("polygon_intersection_area", None).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.linear")).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.bilinear")).is_some());
        assert!(f32_unsupported_reason("fn", Some("datetime.julian_day")).is_some());
        assert!(f32_unsupported_reason("fn", Some("interp.searchsorted")).is_none());
        assert!(f32_unsupported_reason("fn", Some("datetime.year")).is_none());
        assert!(f32_unsupported_reason("+", None).is_none());
    }

    #[test]
    fn index_set_extent_gate() {
        assert!(check_index_set_extent("rows", F32_EXACT_INT_LIMIT).is_ok());
        let err = check_index_set_extent("rows", F32_EXACT_INT_LIMIT + 1).unwrap_err();
        assert!(format!("{err}").contains("rows"), "{err}");
    }
}
