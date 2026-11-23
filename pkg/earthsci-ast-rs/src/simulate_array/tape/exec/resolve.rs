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

pub(super) use super::super::layout::{cm_strides, rm_strides};

/// One call's slab: its base pointer and length, with the slot layout that
/// addresses it.
///
/// Built once per call (or per plan phase) from the executor's slab, it is
/// the only way the executors reach slab memory: a slot's address comes from
/// [`Slab::slot`], a decoded offset's from [`Slab::at`], and a debug build
/// checks each against the slab's length. Hot kernels take a raw pointer
/// from the handle once per operand and index from it.
///
/// Copies of the handle share the slab; the executors' own discipline (one
/// thread per instruction outside a split, disjoint windows inside one, the
/// call plan's phases) is what keeps their accesses apart.
#[derive(Clone, Copy)]
pub(super) struct Slab<'a> {
    ptr: *mut f64,
    len: usize,
    slot_off: &'a [usize],
    /// The handle stands for the exclusive borrow of the slab it was made
    /// from.
    _slab: std::marker::PhantomData<&'a mut [f64]>,
}

impl<'a> Slab<'a> {
    /// The handle over `slab`, laid out by `slot_off`, for a program whose
    /// slots `slots` describes. Every slot a storage holds must lie in
    /// `slab`; a debug build checks it here.
    pub(super) fn new(slab: &'a mut [f64], slot_off: &'a [usize], slots: &[SlotDesc]) -> Self {
        debug_assert!(
            slot_off
                .iter()
                .zip(slots)
                .all(|(&o, d)| o == usize::MAX || o + d.elems().max(1) <= slab.len()),
            "a slot lies outside the slab"
        );
        Slab {
            ptr: slab.as_mut_ptr(),
            len: slab.len(),
            slot_off,
            _slab: std::marker::PhantomData,
        }
    }

    /// Where slot `s` starts.
    #[inline(always)]
    pub(super) fn slot(&self, s: SlotId) -> *mut f64 {
        let off = self.slot_off[s as usize];
        debug_assert!(off < self.len, "slot {s} is not in the slab");
        self.ptr.wrapping_add(off)
    }

    /// Slot `s`'s offset in the slab, for a decoded form that keeps it.
    #[inline(always)]
    pub(super) fn off(&self, s: SlotId) -> usize {
        self.slot_off[s as usize]
    }

    /// Where slab offset `off` (one a decoded form holds) is.
    #[inline(always)]
    pub(super) fn at(&self, off: usize) -> *mut f64 {
        debug_assert!(off < self.len, "offset {off} is not in the slab");
        self.ptr.wrapping_add(off)
    }

    /// Slot `s`'s first element.
    ///
    /// # Safety
    /// No other thread may be writing it.
    #[inline(always)]
    pub(super) unsafe fn read(&self, s: SlotId) -> f64 {
        // SAFETY: `new` checked the slot lies in the slab; the caller rules
        // out a concurrent write.
        unsafe { *self.slot(s) }
    }

    /// Store `v` as slot `s`'s first element.
    ///
    /// # Safety
    /// No other thread may be reading or writing it.
    #[inline(always)]
    pub(super) unsafe fn write(&self, s: SlotId, v: f64) {
        // SAFETY: as for `read`.
        unsafe { *self.slot(s) = v }
    }

    /// Slot `s`'s first `n` elements.
    ///
    /// # Safety
    /// They lie in the slot, and no other thread may be writing them while
    /// the slice lives.
    #[inline(always)]
    pub(super) unsafe fn slot_slice(&self, s: SlotId, n: usize) -> &'a [f64] {
        let p = self.slot(s);
        debug_assert!(self.slot_off[s as usize] + n <= self.len);
        // SAFETY: the caller's contract.
        unsafe { std::slice::from_raw_parts(p, n) }
    }
}

/// Where state variable `ix`'s block starts in the layout the program reads
/// it in: the row-major mirror for a mirrored variable, else the caller's
/// state in place (a column-major program's reversed box, or a variable whose
/// two layouts are the same walk). Either way it is row-major over the
/// program's `state_vars[ix].shape`.
pub(super) fn state_ptr(env: &Env, ix: u32) -> *const f64 {
    // A function's state variable is the running call's array argument,
    // already the caller's row-major view.
    if env.prog.is_function {
        return env.arrays[ix as usize];
    }
    let sv = &env.prog.state_vars[ix as usize];
    let v = if env.mirror[ix as usize] {
        env.state_rm
    } else {
        env.state
    };
    debug_assert!(sv.flat_offset <= v.len(), "state block outside the state");
    v.as_ptr().wrapping_add(sv.flat_offset)
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
pub(super) fn resolve_scalar(op: &Operand, env: &Env, slab: Slab) -> f64 {
    match op {
        Operand::Lit(v) => *v,
        Operand::Param(p) => env.params[*p as usize],
        Operand::Time => env.t,
        Operand::Slot(s) => {
            debug_assert!(
                env.prog.tables.slots[*s as usize].scalar,
                "scalar read of array slot"
            );
            // SAFETY: an instruction's operand is not written while it runs.
            unsafe { slab.read(*s) }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            debug_assert!(sv.shape.is_empty(), "scalar read of array state");
            env.state[sv.flat_offset]
        }
    }
}

/// Resolve an operand against a consumer box `shape` (the out slot's shape).
pub(super) fn resolve_rv(op: &Operand, shape: &[usize], env: &Env, slab: Slab) -> Rv {
    match op {
        Operand::Lit(v) => Rv::S(*v),
        Operand::Param(p) => Rv::S(env.params[*p as usize]),
        Operand::Time => Rv::S(env.t),
        Operand::Slot(s) => {
            let desc = &env.prog.tables.slots[*s as usize];
            if desc.scalar {
                // SAFETY: an instruction's operand is not written while it
                // runs.
                Rv::S(unsafe { slab.read(*s) })
            } else {
                debug_assert_eq!(&desc.shape[..], shape, "slot box mismatch");
                Rv::V {
                    ptr: slab.slot(*s),
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

/// A gather/load source's base pointer and its own shape, without the
/// stride vector [`resolve_src`] builds: what a scalar read needs.
#[inline]
pub(super) fn src_base<'a>(src: &SrcRef, env: &'a Env, slab: Slab) -> (*const f64, &'a [usize]) {
    match src {
        SrcRef::Slot(s) => (
            slab.slot(*s) as *const f64,
            &env.prog.tables.slots[*s as usize].shape[..],
        ),
        SrcRef::State(ix) => (
            state_ptr(env, *ix),
            &env.prog.state_vars[*ix as usize].shape[..],
        ),
    }
}

/// Resolve a gather/load-elem source to its own full view.
pub(super) fn resolve_src(src: &SrcRef, env: &Env, slab: Slab) -> SrcView {
    match src {
        SrcRef::Slot(s) => {
            let desc = &env.prog.tables.slots[*s as usize];
            SrcView {
                ptr: slab.slot(*s),
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
