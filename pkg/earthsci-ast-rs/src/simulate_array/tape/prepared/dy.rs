//! Where a call's derivative goes: which `dy` positions every call writes
//! (the rest are zeroed), which fused outputs are stored straight into `dy`,
//! and which are not stored at all.

use super::super::ir::*;
use super::super::layout::{dy_strides, rm_strides};
use smallvec::SmallVec;

/// A [`DyPlacement::home`] entry: the fused output is not stored at all.
pub(in crate::simulate_array::tape) const UNSTORED: usize = usize::MAX - 1;

/// The program's `dy` facts (see the module docs), for any `dy` of at least
/// [`DyPlacement::min_len`] elements.
pub(in crate::simulate_array::tape) struct DyPlacement {
    /// The `[start, end)` ranges below `written_end` that no `DyWrite` is
    /// certain to write.
    gaps: Vec<(usize, usize)>,
    /// One past the last position some `DyWrite` is certain to write.
    written_end: usize,
    /// The shortest `dy` a call may pass: one past the last position a
    /// certain write or a homed fused output writes.
    pub(in crate::simulate_array::tape) min_len: usize,
    /// Per slot: the `dy` offset a fused group writes it to directly instead
    /// of the slab, or `usize::MAX` (see [`dy_homes`]).
    pub(in crate::simulate_array::tape) home: Vec<usize>,
    /// `home` for a call that publishes no observeds: a fused output that
    /// only the output-only tail reads is [`UNSTORED`] (see [`quiet_homes`]).
    pub(in crate::simulate_array::tape) home_quiet: Vec<usize>,
}

impl DyPlacement {
    pub(super) fn of(prog: &TapeProgram, guarded: &[bool]) -> Self {
        let written = certain_writes(prog, guarded);
        let mut gaps = Vec::new();
        let mut k = 0;
        while k < written.len() {
            if written[k] {
                k += 1;
                continue;
            }
            let start = k;
            while k < written.len() && !written[k] {
                k += 1;
            }
            gaps.push((start, k));
        }
        let (home, home_end) = dy_homes(prog, guarded);
        let home_quiet = quiet_homes(prog, &home);
        DyPlacement {
            gaps,
            written_end: written.len(),
            min_len: written.len().max(home_end),
            home,
            home_quiet,
        }
    }

    /// The `[start, end)` ranges of a `dy` of `n` (at least
    /// [`DyPlacement::min_len`]) elements that no `DyWrite` is certain to
    /// write on every call, which each call zeroes.
    pub(in crate::simulate_array::tape) fn zero_ranges(
        &self,
        n: usize,
    ) -> impl Iterator<Item = (usize, usize)> + '_ {
        debug_assert!(n >= self.min_len);
        let tail = (n > self.written_end).then_some((self.written_end, n));
        self.gaps.iter().copied().chain(tail)
    }
}

/// Mark `p` in `written`, growing it as needed.
fn mark(written: &mut Vec<bool>, p: usize) {
    if p >= written.len() {
        written.resize(p + 1, false);
    }
    written[p] = true;
}

/// Per `dy` position up to the last one marked, whether a `DyWrite` of
/// `prog` is certain to write it on every call: one in the CONTINUOUS
/// section's leading [`TapeProgram::n_rhs`] instructions (the output-only
/// tail after them is skipped while exports are off) outside any conditional
/// region (`guarded`: a `JmpIfZero` branch or a sweep body may not run).
fn certain_writes(prog: &TapeProgram, guarded: &[bool]) -> Vec<bool> {
    let cont = prog.section_range(Cadence::Continuous);
    let every_call = cont.start..cont.end.min(cont.start + prog.n_rhs as usize);
    let mut written = Vec::new();
    for pc in every_call {
        if guarded[pc] {
            continue;
        }
        let write = match &prog.instrs[pc] {
            Instr::DyWrite { write } => write,
            // A lane program writes each of its lanes' positions.
            Instr::Lanes { spec } => {
                let ls = &prog.lanes[*spec as usize];
                for w in &ls.writes {
                    if let LaneDst::Dy(pos) = &w.dst {
                        for l in 0..ls.lanes as usize {
                            mark(&mut written, pos.at(l) as usize);
                        }
                    }
                }
                continue;
            }
            _ => continue,
        };
        let w = &prog.tables.dy_writes[*write as usize];
        if let Some(pos) = &w.scatter {
            for &p in pos {
                mark(&mut written, p);
            }
        } else if let Some(flat) = w.scalar_flat {
            mark(&mut written, flat);
        } else {
            let sv = &prog.state_vars[w.var as usize];
            let shape = &prog.tables.slots[w.slot as usize].shape;
            let st = dy_strides(prog, &sv.shape);
            let total: usize = shape.iter().product();
            let nd = shape.len();
            let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0, nd);
            for _ in 0..total {
                let mut off = sv.flat_offset;
                for d in 0..nd {
                    off += (w.dest_lo[d] + idx[d]) * st[d] as usize;
                }
                mark(&mut written, off);
                let mut d = nd;
                while d > 0 {
                    d -= 1;
                    idx[d] += 1;
                    if idx[d] < shape[d] {
                        break;
                    }
                    idx[d] = 0;
                }
            }
        }
    }
    written
}

/// Per slot, the `dy` offset a fused group writes it to directly, or
/// `usize::MAX` for the slab, and one past the last position so written: a
/// fused output whose only reader is one whole-box `DyWrite` onto a
/// CONTIGUOUS run of `dy`, both in the CONTINUOUS section and outside any
/// conditional region. The group then stores the derivative where the
/// `DyWrite` would have copied it (the same values, one pass fewer), and that
/// `DyWrite` does nothing.
fn dy_homes(prog: &TapeProgram, guarded: &[bool]) -> (Vec<usize>, usize) {
    let mut home = vec![usize::MAX; prog.tables.slots.len()];
    let mut end = 0usize;
    let tables = prog.slot_tables();
    let mut readers = vec![0u32; prog.tables.slots.len()];
    let mut defs = vec![0u32; prog.tables.slots.len()];
    let mut def_pc = vec![usize::MAX; prog.tables.slots.len()];
    for (pc, i) in prog.instrs.iter().enumerate() {
        i.for_each_read(&tables, |s| readers[s as usize] += 1);
        i.for_each_def(&tables, |s| {
            defs[s as usize] += 1;
            def_pc[s as usize] = pc;
        });
    }
    let cont = prog.section_range(Cadence::Continuous);
    for pc in cont.clone() {
        let Instr::DyWrite { write } = &prog.instrs[pc] else {
            continue;
        };
        let w = &prog.tables.dy_writes[*write as usize];
        let s = w.slot as usize;
        if guarded[pc] || w.scatter.is_some() || w.scalar_flat.is_some() {
            continue;
        }
        if readers[s] != 1 || defs[s] != 1 || !cont.contains(&def_pc[s]) || guarded[def_pc[s]] {
            continue;
        }
        let Instr::Fused { spec } = &prog.instrs[def_pc[s]] else {
            continue;
        };
        let fs = &prog.fused[*spec as usize];
        // A stored output over the group's box, or an absorbed reduction's
        // accumulator (folded in place, so straight into `dy`).
        let desc = &prog.tables.slots[s];
        let fits = match &fs.reduce {
            Some(r) if r.out as usize == s => desc.elems() == r.n_inner,
            _ => fs.outputs.iter().any(|&(_, o)| o as usize == s) && desc.shape[..] == fs.shape[..],
        };
        if desc.scalar || !fits {
            continue;
        }
        let sv = &prog.state_vars[w.var as usize];
        let st = dy_strides(prog, &sv.shape);
        let rm = rm_strides(&desc.shape);
        let contiguous = (0..desc.shape.len()).all(|d| desc.shape[d] <= 1 || st[d] == rm[d]);
        let mut off = sv.flat_offset;
        for d in 0..desc.shape.len() {
            off += w.dest_lo[d] * st[d] as usize;
        }
        if contiguous {
            home[s] = off;
            end = end.max(off + desc.elems());
        }
    }
    (home, end)
}

/// `home` with [`UNSTORED`] for every output of a CONTINUOUS fused group
/// whose readers all sit in the section's output-only tail (past
/// [`TapeProgram::n_rhs`]), which a call that publishes no observeds does
/// not run: the group still computes the value (a later micro-op may need
/// it) but writes it nowhere.
fn quiet_homes(prog: &TapeProgram, home: &[usize]) -> Vec<usize> {
    let mut quiet = home.to_vec();
    let rhs_end = (prog.n_const + prog.n_segment + prog.n_rhs) as usize;
    let cont = prog.section_range(Cadence::Continuous);
    let tables = prog.slot_tables();
    // Per slot: whether any instruction a quiet call runs reads it.
    let mut read_early = vec![false; prog.tables.slots.len()];
    for i in prog.instrs.iter().take(rhs_end) {
        i.for_each_read(&tables, |s| read_early[s as usize] = true);
    }
    for pc in cont.start..rhs_end.min(cont.end) {
        let Instr::Fused { spec } = &prog.instrs[pc] else {
            continue;
        };
        for &(_, slot) in &prog.fused[*spec as usize].outputs {
            let s = slot as usize;
            if !read_early[s] && home[s] == usize::MAX {
                quiet[s] = UNSTORED;
            }
        }
    }
    quiet
}
