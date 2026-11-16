//! The strip kernels of folded lane programs (see
//! [`prepared::lane_fold`](super::super::prepared::lane_fold), which decodes
//! the folds once per program): each fold's terms and destination resolved
//! against one call's bases, and one strip of a fold computed in CPU
//! registers.

pub(super) use crate::simulate_array::tape::prepared::lane_fold::{
    B_DY, B_PARAM, B_REG, B_SPLAT, B_STATE, LOp, LaneCode, N_BASES, OTHER, SOp, SSTRIDE, STRIP,
    TPtr,
};

/// A fold term resolved for one call's strip loop: at strip offset `off`
/// its lanes start at `p + (off & adv)`, each with its bits XORed with
/// `neg` ([`SIGN`] or 0).
#[derive(Clone, Copy, Debug)]
pub(super) struct RTerm {
    pub p: *const f64,
    pub adv: usize,
    pub neg: u64,
}

impl RTerm {
    /// `t` against one call's bases.
    #[inline(always)]
    pub(super) fn of(t: &TPtr, bases: &[*mut f64; N_BASES]) -> Self {
        RTerm {
            p: bases[t.base].wrapping_add(t.off),
            adv: t.adv,
            neg: t.neg,
        }
    }
}

/// [`ROp::code`] of a micro-op that is not a fold.
pub(super) const R_OTHER: u8 = 128;

/// One operation of the strip loop resolved for one call: its value goes
/// to `dst + (off & adv)` at strip offset `off`. A fold's `code` is its
/// [`FoldOp`] times 32, plus 16 when its first term is a scalar, plus its
/// shape ([`shape`]), so one dispatch picks the kernel; its `n` terms are
/// at `t`. For [`R_OTHER`], `n` is the
/// micro-op's index in `LaneCode::ops`.
#[derive(Clone, Copy, Debug)]
pub(super) struct ROp {
    pub code: u8,
    pub n: u32,
    pub t: *const RTerm,
    pub dst: *mut f64,
    pub adv: usize,
}

/// A fold's kernel shape: for up to four terms, its term count and which of
/// its terms after the first are negated (`1 + s`, `3 + s`, `7 + s` for two,
/// three and four terms, bit `j - 1` of `s` set when term `j` is); 15 for
/// five or more.
fn shape(t: &[RTerm]) -> u8 {
    if t.len() > 4 {
        return 15;
    }
    let s = t
        .iter()
        .skip(1)
        .enumerate()
        .fold(0u8, |s, (j, tj)| s | (u8::from(tj.neg != 0) << j));
    match t.len() {
        1 => 0,
        2 => 1 + s,
        3 => 3 + s,
        4 => 7 + s,
        _ => 15,
    }
}

impl ROp {
    /// `o` against one call's bases, its terms within `terms` (`tptr`
    /// resolved against the same bases, and not moved while this is in use).
    #[inline(always)]
    pub(super) fn of(
        o: &SOp,
        k: usize,
        terms: &[RTerm],
        tptr: &[TPtr],
        bases: &[*mut f64; N_BASES],
    ) -> Self {
        let dst = bases[o.base].wrapping_add(o.off);
        if o.kind == OTHER {
            return ROp {
                code: R_OTHER,
                n: k as u32,
                t: std::ptr::null(),
                dst,
                adv: o.dadv,
            };
        }
        let t = &terms[o.t as usize..][..o.n as usize];
        ROp {
            code: o.kind * 32 + 16 * u8::from(tptr[o.t as usize].base == B_SPLAT) + shape(t),
            n: o.n,
            t: t.as_ptr(),
            dst,
            adv: o.dadv,
        }
    }

    /// Where its strip at offset `off` is stored.
    #[inline(always)]
    pub(super) fn at(&self, off: usize) -> *mut f64 {
        self.dst.wrapping_add(off & self.adv)
    }
}

// A fold's accumulator, `acc`, lives in CPU registers across its terms,
// each read exactly once, in order. A negated term toggles its sign bit
// with its own mask, which the compiler cannot see is the sign bit: it
// must not rewrite `acc + (-t)` as `acc - t`, which differs for a NaN `t`.

/// `acc` from the first term, its mask applied. A scalar's strip holds one
/// value, so `SCAL` reads just that one (a rate constant leads most folds,
/// and its whole strip need not stay in cache).
#[inline(always)]
unsafe fn first<const SCAL: bool>(t: &RTerm, off: usize) -> [f64; STRIP] {
    if SCAL {
        // SAFETY: a scalar's strip is its splat, which lies in its buffer.
        return [f64::from_bits(unsafe { *t.p }.to_bits() ^ t.neg); STRIP];
    }
    let mut acc = [0.0f64; STRIP];
    // SAFETY (every term read here and in `apply`): the caller checked that
    // each term's strip lies in its vector (see `Strips::ends`).
    let p = t.p.wrapping_add(off & t.adv);
    for (k, a) in acc.iter_mut().enumerate() {
        *a = f64::from_bits(unsafe { *p.add(k) }.to_bits() ^ t.neg);
    }
    acc
}

/// `acc = f(acc, t)` over a strip, `t` read through its mask when `NEG`.
///
/// `NEG` is fixed per kernel rather than tested per term: with a branch per
/// term the compiler sinks both paths' operation below the load, so a plain
/// term no longer loads into its operation and the loaded strip needs
/// registers of its own, which spills the accumulator.
#[inline(always)]
unsafe fn apply<const NEG: bool>(
    acc: &mut [f64; STRIP],
    t: &RTerm,
    off: usize,
    f: impl Fn(f64, f64) -> f64 + Copy,
) {
    let p = t.p.wrapping_add(off & t.adv);
    if NEG {
        for (k, a) in acc.iter_mut().enumerate() {
            *a = f(*a, f64::from_bits(unsafe { *p.add(k) }.to_bits() ^ t.neg));
        }
    } else {
        for (k, a) in acc.iter_mut().enumerate() {
            *a = f(*a, unsafe { *p.add(k) });
        }
    }
}

/// A fold of any number of terms, every one read through its mask.
#[inline(always)]
unsafe fn strip_any(t: &[RTerm], off: usize, dst: *mut f64, f: impl Fn(f64, f64) -> f64 + Copy) {
    let mut acc = unsafe { first::<false>(&t[0], off) };
    for tj in &t[1..] {
        unsafe { apply::<true>(&mut acc, tj, off, f) };
    }
    // SAFETY: `dst` is a strip register or the fold's own `dy` run, disjoint
    // from every term.
    unsafe { std::ptr::copy_nonoverlapping(acc.as_ptr(), dst, STRIP) };
}

/// A fold of a fixed shape: term `j` read through its mask when `neg`.
macro_rules! fixed {
    ($t:expr, $off:expr, $dst:expr, $f:expr, $s:literal; $($j:literal $neg:literal),*) => {{
        let t: *const RTerm = $t;
        // SAFETY: the shape says the fold has this many terms.
        #[allow(unused_mut)]
        let mut acc = unsafe { first::<$s>(&*t, $off) };
        $( unsafe { apply::<$neg>(&mut acc, &*t.add($j), $off, $f) }; )*
        // SAFETY: as in `strip_any`.
        unsafe { std::ptr::copy_nonoverlapping(acc.as_ptr(), $dst, STRIP) };
    }};
}

/// One strip (lanes `off .. off + STRIP` of the call) of the fold `o`.
///
/// # Safety
/// `o` was resolved by [`ROp::of`] against this call's bases, and the
/// terms it points to are still in place.
#[inline(always)]
pub(super) unsafe fn strip_fold(o: &ROp, off: usize) {
    let dst = o.at(off);
    let t = o.t;
    macro_rules! by_shape {
        ($f:expr, $s:literal) => {
            match o.code % 16 {
                0 => fixed!(t, off, dst, $f, $s;),
                1 => fixed!(t, off, dst, $f, $s; 1 false),
                2 => fixed!(t, off, dst, $f, $s; 1 true),
                3 => fixed!(t, off, dst, $f, $s; 1 false, 2 false),
                4 => fixed!(t, off, dst, $f, $s; 1 true, 2 false),
                5 => fixed!(t, off, dst, $f, $s; 1 false, 2 true),
                6 => fixed!(t, off, dst, $f, $s; 1 true, 2 true),
                7 => fixed!(t, off, dst, $f, $s; 1 false, 2 false, 3 false),
                8 => fixed!(t, off, dst, $f, $s; 1 true, 2 false, 3 false),
                9 => fixed!(t, off, dst, $f, $s; 1 false, 2 true, 3 false),
                10 => fixed!(t, off, dst, $f, $s; 1 true, 2 true, 3 false),
                11 => fixed!(t, off, dst, $f, $s; 1 false, 2 false, 3 true),
                12 => fixed!(t, off, dst, $f, $s; 1 true, 2 false, 3 true),
                13 => fixed!(t, off, dst, $f, $s; 1 false, 2 true, 3 true),
                14 => fixed!(t, off, dst, $f, $s; 1 true, 2 true, 3 true),
                // SAFETY: `ROp::of` took `t` and `n` from one in-bounds slice.
                _ => unsafe {
                    strip_any(std::slice::from_raw_parts(t, o.n as usize), off, dst, $f)
                },
            }
        };
    }
    macro_rules! by_lead {
        ($f:expr) => {
            if o.code & 16 != 0 {
                by_shape!($f, true)
            } else {
                by_shape!($f, false)
            }
        };
    }
    match o.code / 32 {
        0 => by_lead!(|x: f64, y: f64| x + y),
        1 => by_lead!(|x: f64, y: f64| x - y),
        2 => by_lead!(|x: f64, y: f64| x * y),
        _ => by_lead!(|x: f64, y: f64| x / y),
    }
}
