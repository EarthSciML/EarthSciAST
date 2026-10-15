//! Operand resolution: turning an `Operand` / `SrcRef` into the scalar,
//! consumer-aligned strided view, or full source view a kernel consumes.
//!
//! Split from the kernels because this is where the two address spaces —
//! slab slots and the flat state vector — are unified; past this boundary the loops see only `(pointer, shape,
//! strides)` and never consult the program again.

use super::*;

// ---------------------------------------------------------------------------
// Operand resolution.
// ---------------------------------------------------------------------------

/// Row-major strides (elements) of `shape` — the slab slot layout.
pub(super) fn rm_strides(shape: &[usize]) -> DimI {
    let n = shape.len();
    let mut st = DimI::from_elem(0, n);
    let mut acc = 1i64;
    for d in (0..n).rev() {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

/// Column-major strides (elements) of `shape` — the flat state-vector layout
/// of each variable block.
pub(super) fn cm_strides(shape: &[usize]) -> DimI {
    let n = shape.len();
    let mut st = DimI::from_elem(0, n);
    let mut acc = 1i64;
    for d in 0..n {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

/// Where state variable `ix`'s block starts in the layout the program reads
/// it in: the row-major mirror for a mirrored variable, else the caller's
/// state in place (a column-major program's reversed box, or a variable whose
/// two layouts are the same walk). Either way it is row-major over the
/// program's `state_vars[ix].shape`.
pub(super) fn state_ptr(env: &Env, ix: u32) -> *const f64 {
    let sv = &env.prog.state_vars[ix as usize];
    if env.mirror[ix as usize] {
        unsafe { env.state_rm.as_ptr().add(sv.flat_offset) }
    } else {
        unsafe { env.state.as_ptr().add(sv.flat_offset) }
    }
}

/// A resolved operand for the elementwise kernels: a scalar value, or an
/// array view whose strides are aligned to the CONSUMER's logical shape.
pub(super) enum Rv {
    S(f64),
    V { ptr: *const f64, strides: DimI },
}

/// A resolved gather/load source: pointer + its OWN shape and strides.
pub(super) struct SrcView {
    pub(super) ptr: *const f64,
    pub(super) shape: DimU,
    pub(super) strides: DimI,
}

/// Resolve an operand to a scalar. Panics on an array operand — the lowering
/// only feeds scalars where a scalar is consumed.
pub(super) fn resolve_scalar(
    op: &Operand,
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
) -> f64 {
    match op {
        Operand::Lit(v) => *v,
        Operand::Param(p) => env.params[*p as usize],
        Operand::Time => env.t,
        Operand::Slot(s) => {
            debug_assert!(
                env.prog.slots[*s as usize].scalar,
                "scalar read of array slot"
            );
            unsafe { *slab_ptr.add(slot_off[*s as usize]) }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            debug_assert!(sv.shape.is_empty(), "scalar read of array state");
            env.state[sv.flat_offset]
        }
    }
}

/// Resolve an operand against a consumer box `shape` (the out slot's shape).
pub(super) fn resolve_rv(
    op: &Operand,
    shape: &[usize],
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
) -> Rv {
    match op {
        Operand::Lit(v) => Rv::S(*v),
        Operand::Param(p) => Rv::S(env.params[*p as usize]),
        Operand::Time => Rv::S(env.t),
        Operand::Slot(s) => {
            let desc = &env.prog.slots[*s as usize];
            let off = slot_off[*s as usize];
            if desc.scalar {
                Rv::S(unsafe { *slab_ptr.add(off) })
            } else {
                debug_assert_eq!(&desc.shape[..], shape, "slot box mismatch");
                Rv::V {
                    ptr: unsafe { slab_ptr.add(off) },
                    strides: rm_strides(shape),
                }
            }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            if sv.shape.is_empty() {
                Rv::S(env.state[sv.flat_offset])
            } else {
                debug_assert_eq!(&sv.shape[..], shape, "state box mismatch");
                Rv::V {
                    ptr: state_ptr(env, *ix),
                    strides: rm_strides(&sv.shape),
                }
            }
        }
    }
}

/// Resolve a gather/load-elem source to its own full view.
pub(super) fn resolve_src(
    src: &SrcRef,
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
) -> SrcView {
    match src {
        SrcRef::Slot(s) => {
            let desc = &env.prog.slots[*s as usize];
            SrcView {
                ptr: unsafe { slab_ptr.add(slot_off[*s as usize]) },
                shape: desc.shape.clone(),
                strides: rm_strides(&desc.shape),
            }
        }
        SrcRef::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            SrcView {
                ptr: state_ptr(env, *ix),
                shape: sv.shape.clone(),
                strides: rm_strides(&sv.shape),
            }
        }
    }
}
