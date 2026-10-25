//! The inputs and errors of a program evaluation (API_SPEC §5.8): forcing
//! sets, the parameter and state layouts, and [`RhsError`].

use super::RhsProgram;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Why a program evaluation (`eval_into`) failed.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum RhsError {
    /// A fail-closed evaluation fault (CONFORMANCE_SPEC §5.5.5, §5.23): `code`
    /// is its `E_TREEWALK_*` code. `du` is unspecified.
    Fault { code: &'static str, message: String },
    /// An argument does not fit the program: a buffer of the wrong length, or
    /// a workspace or forcing set made for another program.
    Shape {
        what: &'static str,
        expected: usize,
        got: usize,
    },
}

impl std::fmt::Display for RhsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RhsError::Fault { code, message } => write!(f, "{code}: {message}"),
            RhsError::Shape {
                what,
                expected,
                got,
            } => write!(
                f,
                "`{what}` does not fit the program: expected {expected}, got {got}"
            ),
        }
    }
}

impl std::error::Error for RhsError {}

/// The fail-closed codes a fault message may lead with.
const FAULT_CODES: [&str; 9] = [
    "E_TREEWALK_CONSTARRAY_OOB",
    "E_TREEWALK_GEOMETRY_CLIP",
    "E_TREEWALK_INDEX_ON_SCALAR",
    "E_TREEWALK_MISSING_DATA",
    "E_TREEWALK_MISSING_INITIAL_VALUE",
    "E_TREEWALK_RECUR_UNAVAILABLE",
    "E_TREEWALK_UNBOUND_NAME",
    "E_TREEWALK_UNDECLARED_INDEX_SET",
    "E_TREEWALK_UNRESOLVED_ORDER",
];

/// The fault a latched message reports, coded by the code it leads with.
pub(super) fn fault(message: String) -> RhsError {
    let code = FAULT_CODES
        .iter()
        .copied()
        .find(|c| {
            message
                .strip_prefix(c)
                .is_some_and(|rest| rest.starts_with(':'))
        })
        .unwrap_or("rhs_fault");
    RhsError::Fault { code, message }
}

pub(super) fn shape(what: &'static str, expected: usize, got: usize) -> RhsError {
    RhsError::Shape {
        what,
        expected,
        got,
    }
}

/// One positional parameter of a program: `p[k]` is [`RhsProgram::parameters`]`[k]`.
#[derive(Debug, Clone, PartialEq)]
pub struct ParamSlot {
    /// The flattened (dot-namespaced) name.
    pub name: String,
    /// The declared default, if any.
    pub default: Option<f64>,
}

/// One state variable's block of `u` (API_SPEC §5.8): `shape` column-major
/// from `flat_offset`, first index fastest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateBlock {
    pub name: String,
    pub flat_offset: usize,
    pub shape: Vec<usize>,
}

/// What a forcing slot carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotKind {
    /// A parameter refreshed from outside the model (a data source or a
    /// registered handler).
    Forcing,
    /// A shaped parameter the Problem was asked to leave as a run-time input
    /// (`ProblemOptions::runtime_array_parameters`).
    ArrayParameter,
}

/// One buffer of a [`ForcingSet`]: the variable it serves, its shape, and its
/// kind. The buffer holds `shape`'s element count (one for a 0-d slot),
/// column-major, first index fastest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForcingSlot {
    pub name: String,
    pub shape: Vec<usize>,
    pub kind: SlotKind,
}

impl ForcingSlot {
    /// The buffer length the slot takes.
    pub fn len(&self) -> usize {
        self.shape.iter().product::<usize>()
    }

    /// Whether the slot's buffer holds no element (a box with an empty axis).
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Process-wide epoch source: no two sets ever share an epoch, so a
/// workspace that primed its SEGMENT section on one set cannot mistake
/// another set for it.
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);

fn next_epoch() -> u64 {
    NEXT_EPOCH.fetch_add(1, Ordering::Relaxed)
}

/// The forcing a program evaluation reads (API_SPEC §5.8): one immutable
/// buffer per [`RhsProgram::forcing_slots`] entry, stamped with a
/// process-unique epoch. Refresh is a swap: [`Self::replace`] makes a new set
/// (a new epoch) sharing every other buffer, and a call on the new set
/// re-runs what reads forcing. Cheap to clone; `Send + Sync`.
#[derive(Debug, Clone)]
pub struct ForcingSet {
    epoch: u64,
    slots: Arc<[ForcingSlot]>,
    bufs: Arc<[Arc<[f64]>]>,
}

impl ForcingSet {
    /// A set for `prog`'s slots: `bufs[k]` is slot `k`'s buffer.
    pub fn new(prog: &RhsProgram, bufs: Vec<Arc<[f64]>>) -> Result<ForcingSet, RhsError> {
        ForcingSet::for_slots(prog.slots_arc(), bufs)
    }

    /// A set over `slots`, its buffers checked against them.
    pub(super) fn for_slots(
        slots: Arc<[ForcingSlot]>,
        bufs: Vec<Arc<[f64]>>,
    ) -> Result<ForcingSet, RhsError> {
        if bufs.len() != slots.len() {
            return Err(shape("forcing", slots.len(), bufs.len()));
        }
        for (slot, buf) in slots.iter().zip(&bufs) {
            check_len(slot, buf)?;
        }
        Ok(ForcingSet {
            epoch: next_epoch(),
            slots,
            bufs: bufs.into(),
        })
    }

    /// A new set, with a new epoch, sharing every buffer but `slot`'s.
    pub fn replace(&self, slot: usize, buf: Arc<[f64]>) -> Result<ForcingSet, RhsError> {
        let Some(s) = self.slots.get(slot) else {
            return Err(shape("forcing", self.slots.len(), slot));
        };
        check_len(s, &buf)?;
        let mut bufs: Vec<Arc<[f64]>> = self.bufs.to_vec();
        bufs[slot] = buf;
        Ok(ForcingSet {
            epoch: next_epoch(),
            slots: Arc::clone(&self.slots),
            bufs: bufs.into(),
        })
    }

    /// The set's epoch, unique in the process.
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// The slots the buffers fill, in order.
    pub fn slots(&self) -> &[ForcingSlot] {
        &self.slots
    }

    /// Slot `k`'s buffer.
    pub fn buffer(&self, k: usize) -> &[f64] {
        &self.bufs[k]
    }

    pub(super) fn slots_arc(&self) -> Arc<[ForcingSlot]> {
        Arc::clone(&self.slots)
    }

    pub(super) fn bufs(&self) -> &[Arc<[f64]>] {
        &self.bufs
    }

    /// Whether this set was made for `slots` (the same list, or an equal one).
    pub(super) fn fits(&self, slots: &Arc<[ForcingSlot]>) -> bool {
        Arc::ptr_eq(&self.slots, slots) || *self.slots == **slots
    }
}

fn check_len(slot: &ForcingSlot, buf: &[f64]) -> Result<(), RhsError> {
    if buf.len() != slot.len() {
        return Err(shape("forcing", slot.len(), buf.len()));
    }
    Ok(())
}
