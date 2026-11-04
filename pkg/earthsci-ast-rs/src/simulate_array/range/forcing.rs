//! The inputs and errors of a program evaluation (API_SPEC §5.8): forcing
//! sets, the parameter and state layouts, and [`RhsError`].

use super::RhsProgram;
use crate::provider::{NativeField, ProviderError, single_provider_field};
use ndarray::ArrayD;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Why a program evaluation (`eval_into`) failed.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum RhsError {
    /// A fail-closed evaluation fault (CONFORMANCE_SPEC §5.5.5, §5.23): `code`
    /// is its `E_TREEWALK_*` code. `du` is unspecified.
    Fault { code: &'static str, message: String },
    /// A buffer of the wrong length: `what` names the argument, `expected`
    /// and `got` are lengths (or, for a forcing set's buffer list, slot
    /// counts).
    Shape {
        what: &'static str,
        expected: usize,
        got: usize,
    },
    /// A workspace or lane inputs passed to a program other than the one that
    /// made them (`what` names which). A program `select`ed, tiled or laned
    /// from another is a different program; a clone is the same one.
    ForeignProgram { what: &'static str },
    /// A forcing set built for other forcing slots than the program's;
    /// `detail` says where the two slot lists first differ.
    ForcingSignature { detail: String },
    /// A forcing-slot index past the end of a set of `slots` slots.
    SlotIndex { slot: usize, slots: usize },
    /// Lane inputs that hold no successful gather: never gathered, or the
    /// last gather failed.
    NotGathered,
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
                "`{what}` does not fit the program: expected length {expected}, got {got}"
            ),
            RhsError::ForeignProgram { what } => write!(
                f,
                "`{what}` was made by another program; it serves only the program that made it \
                 and that program's clones"
            ),
            RhsError::ForcingSignature { detail } => write!(
                f,
                "the forcing set was built for other forcing slots than the program's: {detail}"
            ),
            RhsError::SlotIndex { slot, slots } => write!(
                f,
                "forcing slot {slot} is out of range: the set has {slots} slot(s), indexed from 0"
            ),
            RhsError::NotGathered => write!(
                f,
                "the lane inputs hold no successful gather; call `gather_lane_inputs` first"
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
            return Err(RhsError::SlotIndex {
                slot,
                slots: self.slots.len(),
            });
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

    /// Why this set does not fit `slots`: the first slot the two lists
    /// disagree on, or their lengths.
    pub(super) fn mismatch(&self, slots: &[ForcingSlot]) -> RhsError {
        let show = |s: &ForcingSlot| format!("`{}` {:?} ({:?})", s.name, s.shape, s.kind);
        let detail = match self.slots.iter().zip(slots).position(|(a, b)| a != b) {
            Some(k) => format!(
                "slot {k} is {} in the set, {} in the program",
                show(&self.slots[k]),
                show(&slots[k])
            ),
            None => format!(
                "the set has {} slot(s), the program {}",
                self.slots.len(),
                slots.len()
            ),
        };
        RhsError::ForcingSignature { detail }
    }
}

/// The buffer of `slot` built from one provider sample: the check and the
/// conversion [`crate::esm_problem`] applies to a sample from a provider in
/// `ProblemOptions::providers`, so a runtime that builds its own
/// [`ForcingSet`]s from provider samples gets, bit for bit, the buffer
/// [`RhsProgram::default_forcing`] holds for the same sample (API_SPEC §5.8,
/// "Forcing sets").
///
/// `sample` is what a [`crate::provider::CadenceProvider`] returned
/// (`materialize()` for a const provider, `refresh(t)` for a discrete one). It
/// must hold exactly one field, whatever that field is called: a provider in
/// `ProblemOptions::providers` feeds the one parameter its key names, so the
/// field's own name is not read. This differs from the Julia binding, whose
/// provider samples are keyed by parameter name, because each binding's
/// provider contract differs. The field's array dimensions, in the order the
/// provider delivered them (a source's file order, the record dimension first
/// when two records are delivered), must be `slot.shape`, axis by axis; a 0-d
/// slot takes an array of exactly one element. `esm_problem` refuses a sample
/// whose field does not have the parameter's declared shape, at `materialize()`
/// and at every `refresh(t)`, so the two accept the same samples. The buffer
/// is the array's values column-major over those dimensions (first index
/// fastest), the order a forcing set reads a slot's buffer in.
///
/// A declared `unit_conversion` (esm-spec §8.5) is NOT applied here: a
/// provider from `esio_provider::providers_from_document` (feature `esio`) applies
/// it when it delivers the sample, so the sample is already in the
/// parameter's declared units, and applying it again would apply it twice.
///
/// A provider passed to `esm_problem` in `ProblemOptions::build_providers` is
/// consumed by the build instead, which also checks the declared shape but
/// rounds the sample to the document's working precision (`domain.element_type`)
/// for a Float32 document; this function does not round.
///
/// # Errors
///
/// A sample that does not hold exactly one field, or whose field's array does
/// not have the slot's shape.
pub fn forcing_from_sample(
    sample: &HashMap<String, NativeField>,
    slot: &ForcingSlot,
) -> Result<Arc<[f64]>, ProviderError> {
    let field = single_provider_field(&slot.name, sample, Some(&slot.shape))?;
    Ok(column_major(&field.array))
}

/// A row-major array's elements in column-major order (first index fastest):
/// a slot's buffer from the Problem's forcing array, for
/// [`RhsProgram::default_forcing`] and [`forcing_from_sample`] alike.
pub(super) fn column_major(a: &ArrayD<f64>) -> Arc<[f64]> {
    a.view().reversed_axes().iter().copied().collect()
}

fn check_len(slot: &ForcingSlot, buf: &[f64]) -> Result<(), RhsError> {
    if buf.len() != slot.len() {
        return Err(shape("forcing", slot.len(), buf.len()));
    }
    Ok(())
}
