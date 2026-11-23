//! The scalar arithmetic of the array evaluators: one `#[inline(always)]`
//! function per operator, generic over the element width.
//!
//! Every kernel table and every monomorphized fast path — the per-cell
//! oracle's `apply_binary` / `apply_unary`, the shared function-pointer tables
//! in binary64 and binary32, and the tape executors' inlined element loops —
//! calls these, so an operator's arithmetic is written once. Values travel in
//! `f64` carriers; a binary32 kernel narrows its operands, calls the `f32`
//! instance and widens the result, which is exact. Comparisons narrow too:
//! the carriers of two values that round to the same `f32` must compare
//! equal. The `f32` elementary functions are the `f32` libm entry points
//! (`expf`, `logf`, …), not the binary64 function rounded afterwards.

use num_traits::Float;

/// An element type the kernels run at: `f64` or `f32`.
pub(crate) trait Elem: Float {
    /// The 1 / 0 encoding of a boolean.
    fn flag(b: bool) -> Self;
    /// This type's value of an `f64` carrier (exact for a carrier of a value
    /// of this type).
    fn narrow(x: f64) -> Self;
    /// The `f64` carrier of a value (exact).
    fn widen(self) -> f64;
}

impl Elem for f64 {
    #[inline(always)]
    fn flag(b: bool) -> f64 {
        b as i32 as f64
    }
    #[inline(always)]
    fn narrow(x: f64) -> f64 {
        x
    }
    #[inline(always)]
    fn widen(self) -> f64 {
        self
    }
}

impl Elem for f32 {
    #[inline(always)]
    fn flag(b: bool) -> f32 {
        b as i32 as f32
    }
    #[inline(always)]
    fn narrow(x: f64) -> f32 {
        x as f32
    }
    #[inline(always)]
    fn widen(self) -> f64 {
        self as f64
    }
}

/// [`Elem::narrow`] as a function, for the kernel macros.
#[inline(always)]
pub(crate) fn n<F: Elem>(x: f64) -> F {
    F::narrow(x)
}

/// [`Elem::widen`] as a function, for the kernel macros.
#[inline(always)]
pub(crate) fn w<F: Elem>(x: F) -> f64 {
    x.widen()
}

#[inline(always)]
pub(crate) fn add<F: Elem>(x: F, y: F) -> F {
    x + y
}
#[inline(always)]
pub(crate) fn sub<F: Elem>(x: F, y: F) -> F {
    x - y
}
#[inline(always)]
pub(crate) fn mul<F: Elem>(x: F, y: F) -> F {
    x * y
}
#[inline(always)]
pub(crate) fn div<F: Elem>(x: F, y: F) -> F {
    x / y
}
#[inline(always)]
pub(crate) fn pow<F: Elem>(x: F, y: F) -> F {
    x.powf(y)
}
#[inline(always)]
pub(crate) fn atan2<F: Elem>(x: F, y: F) -> F {
    x.atan2(y)
}
/// `min` with NaN propagation (a NaN operand gives NaN).
#[inline(always)]
pub(crate) fn min<F: Elem>(x: F, y: F) -> F {
    if x.is_nan() || y.is_nan() {
        F::nan()
    } else {
        x.min(y)
    }
}
/// `max` with NaN propagation (a NaN operand gives NaN).
#[inline(always)]
pub(crate) fn max<F: Elem>(x: F, y: F) -> F {
    if x.is_nan() || y.is_nan() {
        F::nan()
    } else {
        x.max(y)
    }
}
/// Exact equality with the native relop, so `inf == inf`.
#[inline(always)]
pub(crate) fn eq<F: Elem>(x: F, y: F) -> F {
    F::flag(x == y)
}
#[inline(always)]
pub(crate) fn ne<F: Elem>(x: F, y: F) -> F {
    F::flag(x != y)
}
#[inline(always)]
pub(crate) fn lt<F: Elem>(x: F, y: F) -> F {
    F::flag(x < y)
}
#[inline(always)]
pub(crate) fn le<F: Elem>(x: F, y: F) -> F {
    F::flag(x <= y)
}
#[inline(always)]
pub(crate) fn gt<F: Elem>(x: F, y: F) -> F {
    F::flag(x > y)
}
#[inline(always)]
pub(crate) fn ge<F: Elem>(x: F, y: F) -> F {
    F::flag(x >= y)
}
/// Nonzero is true; the result is a strict 1 / 0 flag.
#[inline(always)]
pub(crate) fn and<F: Elem>(x: F, y: F) -> F {
    F::flag(x != F::zero() && y != F::zero())
}
#[inline(always)]
pub(crate) fn or<F: Elem>(x: F, y: F) -> F {
    F::flag(x != F::zero() || y != F::zero())
}

#[inline(always)]
pub(crate) fn exp<F: Elem>(x: F) -> F {
    x.exp()
}
/// The natural logarithm (`log` in the format).
#[inline(always)]
pub(crate) fn ln<F: Elem>(x: F) -> F {
    x.ln()
}
#[inline(always)]
pub(crate) fn log10<F: Elem>(x: F) -> F {
    x.log10()
}
#[inline(always)]
pub(crate) fn sqrt<F: Elem>(x: F) -> F {
    x.sqrt()
}
#[inline(always)]
pub(crate) fn abs<F: Elem>(x: F) -> F {
    x.abs()
}
/// -1, 0 or +1; `+0.0` for a zero of either sign and for NaN.
#[inline(always)]
pub(crate) fn sign<F: Elem>(x: F) -> F {
    if x > F::zero() {
        F::one()
    } else if x < F::zero() {
        -F::one()
    } else {
        F::zero()
    }
}
#[inline(always)]
pub(crate) fn floor<F: Elem>(x: F) -> F {
    x.floor()
}
#[inline(always)]
pub(crate) fn ceil<F: Elem>(x: F) -> F {
    x.ceil()
}
#[inline(always)]
pub(crate) fn sin<F: Elem>(x: F) -> F {
    x.sin()
}
#[inline(always)]
pub(crate) fn cos<F: Elem>(x: F) -> F {
    x.cos()
}
#[inline(always)]
pub(crate) fn tan<F: Elem>(x: F) -> F {
    x.tan()
}
#[inline(always)]
pub(crate) fn asin<F: Elem>(x: F) -> F {
    x.asin()
}
#[inline(always)]
pub(crate) fn acos<F: Elem>(x: F) -> F {
    x.acos()
}
#[inline(always)]
pub(crate) fn atan<F: Elem>(x: F) -> F {
    x.atan()
}
#[inline(always)]
pub(crate) fn sinh<F: Elem>(x: F) -> F {
    x.sinh()
}
#[inline(always)]
pub(crate) fn cosh<F: Elem>(x: F) -> F {
    x.cosh()
}
#[inline(always)]
pub(crate) fn tanh<F: Elem>(x: F) -> F {
    x.tanh()
}
#[inline(always)]
pub(crate) fn asinh<F: Elem>(x: F) -> F {
    x.asinh()
}
#[inline(always)]
pub(crate) fn acosh<F: Elem>(x: F) -> F {
    x.acosh()
}
#[inline(always)]
pub(crate) fn atanh<F: Elem>(x: F) -> F {
    x.atanh()
}
/// Logical negation: 1 for a zero operand, else 0.
#[inline(always)]
pub(crate) fn not<F: Elem>(x: F) -> F {
    F::flag(x == F::zero())
}

/// Expand `$apply!(kernel)` with the kernel of the [`BinCode`] `$op` at
/// element type `$ty`, as an `f64`-carrier closure. The one list of binary
/// kernels: the function-pointer tables and the tape executors' inlined
/// loops all expand it.
///
/// [`BinCode`]: super::eval::BinCode
macro_rules! with_bin_kernel {
    ($ty:ty, $op:expr, $apply:ident) => {{
        use $crate::simulate_array::scalar_ops as k;
        match $op {
            BinCode::Add => $apply!(|x: f64, y: f64| k::w(k::add::<$ty>(k::n(x), k::n(y)))),
            BinCode::Sub => $apply!(|x: f64, y: f64| k::w(k::sub::<$ty>(k::n(x), k::n(y)))),
            BinCode::Mul => $apply!(|x: f64, y: f64| k::w(k::mul::<$ty>(k::n(x), k::n(y)))),
            BinCode::Div => $apply!(|x: f64, y: f64| k::w(k::div::<$ty>(k::n(x), k::n(y)))),
            BinCode::Pow => $apply!(|x: f64, y: f64| k::w(k::pow::<$ty>(k::n(x), k::n(y)))),
            BinCode::Atan2 => $apply!(|x: f64, y: f64| k::w(k::atan2::<$ty>(k::n(x), k::n(y)))),
            BinCode::Min => $apply!(|x: f64, y: f64| k::w(k::min::<$ty>(k::n(x), k::n(y)))),
            BinCode::Max => $apply!(|x: f64, y: f64| k::w(k::max::<$ty>(k::n(x), k::n(y)))),
            BinCode::Eq => $apply!(|x: f64, y: f64| k::w(k::eq::<$ty>(k::n(x), k::n(y)))),
            BinCode::Ne => $apply!(|x: f64, y: f64| k::w(k::ne::<$ty>(k::n(x), k::n(y)))),
            BinCode::Lt => $apply!(|x: f64, y: f64| k::w(k::lt::<$ty>(k::n(x), k::n(y)))),
            BinCode::Le => $apply!(|x: f64, y: f64| k::w(k::le::<$ty>(k::n(x), k::n(y)))),
            BinCode::Gt => $apply!(|x: f64, y: f64| k::w(k::gt::<$ty>(k::n(x), k::n(y)))),
            BinCode::Ge => $apply!(|x: f64, y: f64| k::w(k::ge::<$ty>(k::n(x), k::n(y)))),
            BinCode::And => $apply!(|x: f64, y: f64| k::w(k::and::<$ty>(k::n(x), k::n(y)))),
            BinCode::Or => $apply!(|x: f64, y: f64| k::w(k::or::<$ty>(k::n(x), k::n(y)))),
            BinCode::Unknown => $apply!(|_: f64, _: f64| f64::NAN),
        }
    }};
}
pub(crate) use with_bin_kernel;

/// The unary counterpart of [`with_bin_kernel`], over [`UnCode`].
///
/// [`UnCode`]: super::eval::UnCode
macro_rules! with_un_kernel {
    ($ty:ty, $op:expr, $apply:ident) => {{
        use $crate::simulate_array::scalar_ops as k;
        match $op {
            UnCode::Exp => $apply!(|x: f64| k::w(k::exp::<$ty>(k::n(x)))),
            UnCode::Ln => $apply!(|x: f64| k::w(k::ln::<$ty>(k::n(x)))),
            UnCode::Log10 => $apply!(|x: f64| k::w(k::log10::<$ty>(k::n(x)))),
            UnCode::Sqrt => $apply!(|x: f64| k::w(k::sqrt::<$ty>(k::n(x)))),
            UnCode::Abs => $apply!(|x: f64| k::w(k::abs::<$ty>(k::n(x)))),
            UnCode::Sign => $apply!(|x: f64| k::w(k::sign::<$ty>(k::n(x)))),
            UnCode::Floor => $apply!(|x: f64| k::w(k::floor::<$ty>(k::n(x)))),
            UnCode::Ceil => $apply!(|x: f64| k::w(k::ceil::<$ty>(k::n(x)))),
            UnCode::Sin => $apply!(|x: f64| k::w(k::sin::<$ty>(k::n(x)))),
            UnCode::Cos => $apply!(|x: f64| k::w(k::cos::<$ty>(k::n(x)))),
            UnCode::Tan => $apply!(|x: f64| k::w(k::tan::<$ty>(k::n(x)))),
            UnCode::Asin => $apply!(|x: f64| k::w(k::asin::<$ty>(k::n(x)))),
            UnCode::Acos => $apply!(|x: f64| k::w(k::acos::<$ty>(k::n(x)))),
            UnCode::Atan => $apply!(|x: f64| k::w(k::atan::<$ty>(k::n(x)))),
            UnCode::Sinh => $apply!(|x: f64| k::w(k::sinh::<$ty>(k::n(x)))),
            UnCode::Cosh => $apply!(|x: f64| k::w(k::cosh::<$ty>(k::n(x)))),
            UnCode::Tanh => $apply!(|x: f64| k::w(k::tanh::<$ty>(k::n(x)))),
            UnCode::Asinh => $apply!(|x: f64| k::w(k::asinh::<$ty>(k::n(x)))),
            UnCode::Acosh => $apply!(|x: f64| k::w(k::acosh::<$ty>(k::n(x)))),
            UnCode::Atanh => $apply!(|x: f64| k::w(k::atanh::<$ty>(k::n(x)))),
            UnCode::Not => $apply!(|x: f64| k::w(k::not::<$ty>(k::n(x)))),
            UnCode::RoundF32 => $apply!(|x: f64| f64::from(x as f32)),
            UnCode::Unknown => $apply!(|_: f64| f64::NAN),
        }
    }};
}
pub(crate) use with_un_kernel;
