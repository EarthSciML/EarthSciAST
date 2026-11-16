//! The analyses of a finished program that its executor needs, computed
//! once per program ([`TapeProgram::prepared`]) rather than once per
//! execution context.
//!
//! Each depends on the program alone: the folded form of every lane program
//! with its strip registers allocated (`lane_fold`), the segmented-reduction
//! chains that split in one dispatch (`chains`), where the derivative goes
//! (`dy`), and which gathers and assemblies cover their whole box. Every
//! context that runs the program (one per RHS scratch, range tile or lane
//! workspace) reads the same value. Nothing here touches the slab: the
//! executor's unsafe code consumes these as plain data.

#[cfg(not(target_arch = "wasm32"))]
pub(super) mod chains;
pub(super) mod dy;
pub(super) mod lane_fold;

use super::ir::*;
use super::layout::rm_strides;
use smallvec::SmallVec;

pub(in crate::simulate_array::tape) use dy::UNSTORED;

/// A program's executor-side analyses (see the module docs).
pub(in crate::simulate_array::tape) struct Prepared {
    /// Per slot, its offset into the slab in the program's own layout
    /// (`usize::MAX` for a slot no storage holds, which no reachable
    /// instruction references).
    pub(in crate::simulate_array::tape) slot_off: Vec<usize>,
    /// Per lane program, its folded form (`None` for a one-lane block or a
    /// program too large to decode).
    pub(in crate::simulate_array::tape) lane_codes: Vec<Option<lane_fold::LaneCode>>,
    /// The continuous section's segmented reductions that split together
    /// with the work around them, in program order.
    #[cfg(not(target_arch = "wasm32"))]
    pub(in crate::simulate_array::tape) seg_chains: Vec<chains::SegChain>,
    /// Where the derivative goes.
    pub(in crate::simulate_array::tape) dy: dy::DyPlacement,
    /// Per gather plan: `true` when its per-axis segments tile the whole
    /// output box, so the ghost zero-fill can be skipped (every element is
    /// overwritten by a segment copy).
    pub(in crate::simulate_array::tape) plan_full: Vec<bool>,
    /// Per `makearray` assembly: `true` when its regions cover the whole
    /// output box of every `Assemble` that uses it, so its zero fill can be
    /// skipped (every element is overwritten by a part).
    pub(in crate::simulate_array::tape) asm_covered: Vec<bool>,
    /// Per fused group, [`node_elems`] of its schedule: what lets a worker
    /// step straight to the start of its share of the group.
    pub(in crate::simulate_array::tape) node_elems: Vec<Vec<usize>>,
}

impl Prepared {
    pub(super) fn of(prog: &TapeProgram) -> Self {
        let slot_off: Vec<usize> = prog
            .tables
            .slots
            .iter()
            .map(|s| {
                if s.storage == u32::MAX {
                    usize::MAX
                } else {
                    prog.slab.storages[s.storage as usize].offset
                }
            })
            .collect();
        let guarded = prog.guarded_positions();
        let lane_codes = prog
            .lanes
            .iter()
            .map(|ls| {
                (ls.lanes > 1 || !ls.inputs.is_empty())
                    .then(|| lane_fold::decode(ls))
                    .flatten()
            })
            .collect();
        Prepared {
            #[cfg(not(target_arch = "wasm32"))]
            seg_chains: chains::seg_chains(prog, &slot_off, &guarded),
            dy: dy::DyPlacement::of(prog, &guarded),
            plan_full: plans_full(prog),
            asm_covered: assemblies_covered(prog),
            node_elems: prog
                .fused
                .iter()
                .map(|f| node_elems(&f.schedule.nodes))
                .collect(),
            lane_codes,
            slot_off,
        }
    }
}

/// Per gather plan of `prog`, whether its per-axis segments tile the whole
/// output box.
fn plans_full(prog: &TapeProgram) -> Vec<bool> {
    prog.tables
        .plans
        .iter()
        .map(|plan| {
            plan.shape.iter().enumerate().all(|(d, &extent)| {
                let mut segs: Vec<(usize, usize)> =
                    plan.segs[d].iter().map(|&(o, l, _)| (o, l)).collect();
                segs.sort_unstable();
                let mut next = 0usize;
                for (o, l) in segs {
                    if o != next {
                        return false;
                    }
                    next = o + l;
                }
                next == extent
            })
        })
        .collect()
}

/// Per assembly of `prog`, whether its regions cover every element of the box
/// it assembles (for every `Assemble` that uses it).
fn assemblies_covered(prog: &TapeProgram) -> Vec<bool> {
    let mut covered = vec![true; prog.tables.assemblies.len()];
    for ins in &prog.instrs {
        let Instr::Assemble { table, out } = ins else {
            continue;
        };
        let shape = &prog.tables.slots[*out as usize].shape;
        let rm = rm_strides(shape);
        let mut hit = vec![false; shape.iter().product::<usize>().max(1)];
        for (_, region) in &prog.tables.assemblies[*table as usize].parts {
            let spec = &prog.tables.regions[*region as usize];
            let n: usize = spec.shape.iter().product();
            let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0, spec.shape.len());
            for _ in 0..n {
                let flat: i64 = (0..idx.len())
                    .map(|d| rm[d] * (spec.dest_lo[d] + idx[d]) as i64)
                    .sum();
                hit[flat as usize] = true;
                for d in (0..idx.len()).rev() {
                    idx[d] += 1;
                    if idx[d] < spec.shape[d] {
                        break;
                    }
                    idx[d] = 0;
                }
            }
        }
        covered[*table as usize] &= hit.iter().all(|&h| h);
    }
    covered
}

/// The elements one execution of each schedule node covers: a run's length,
/// or ONE repetition of a `Repeat`'s body (its whole span is that times its
/// count). Pre-order, like the nodes.
pub(in crate::simulate_array::tape) fn node_elems(nodes: &[RunNode]) -> Vec<usize> {
    fn span(nodes: &[RunNode], out: &mut [usize], i: usize) -> (usize, usize) {
        match &nodes[i] {
            RunNode::Run(r) => {
                out[i] = r.len as usize;
                (out[i], i + 1)
            }
            RunNode::Repeat { count, body, .. } => {
                let end = i + 1 + *body as usize;
                let (mut rep, mut j) = (0usize, i + 1);
                while j < end {
                    let (t, next) = span(nodes, out, j);
                    rep += t;
                    j = next;
                }
                out[i] = rep;
                (rep * *count as usize, end)
            }
        }
    }
    let mut out = vec![0usize; nodes.len()];
    let mut j = 0usize;
    while j < nodes.len() {
        j = span(nodes, &mut out, j).1;
    }
    out
}
