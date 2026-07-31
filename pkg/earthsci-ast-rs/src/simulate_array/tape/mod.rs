//! Tape compilation and execution.
//!
//! Compiles a model's observed + RHS rule set into a flat instruction program
//! ([`TapeProgram`]) with build-time value numbering (subsuming the runtime
//! CSE overlay for taped rules), cadence-sectioned instruction streams
//! (CONST / SEGMENT / CONTINUOUS), liveness-based slab coloring, `dy` scatter
//! descriptors and observed exports (Step 3a), and executes it as the
//! DEFAULT production RHS hot path through the fast slab executor in
//! [`exec`] (Step 3b): `simulate` builds the program once per solve and each
//! segment's RHS scratch runs it; `ESS_TAPE_DISABLE=1` reverts wholesale to
//! the legacy interpreter, and `ESS_TAPE_CHECK=N` dual-runs and bit-compares
//! the first N calls. The `debug_eval_rhs*` oracles, the samples pass and
//! the FD Jacobian closure stay on the legacy interpreter path.

mod exec;
mod fuse;
mod ir;
mod lower;
#[cfg(test)]
mod refexec;
#[cfg(test)]
mod tests;

pub(in crate::simulate_array) use exec::{TapeCtx, run_tape_call};
pub(crate) use exec::tape_disabled;
pub(crate) use fuse::fuse_disabled;
pub(crate) use ir::*;
use lower::build_tape_program;

use super::ArrayCompiled;
use std::collections::HashSet;
use std::fmt;

/// Human-readable summary of one tape build. Public so external diagnostics
/// (the `tape_report` example) can print it; the program itself stays
/// crate-internal.
#[derive(Debug, Clone, Default)]
pub struct TapeBuildReport {
    /// Total rules considered (observed + RHS).
    pub n_rules: usize,
    /// Rules fully lowered onto the tape.
    pub n_taped: usize,
    /// `(rule name, deepest bail reason)` for every fallback rule.
    pub fallbacks: Vec<(String, String)>,
    pub n_instr_const: usize,
    pub n_instr_segment: usize,
    pub n_instr_continuous: usize,
    /// Instruction counts per opcode, whole program, descending.
    pub opcode_counts: Vec<(String, usize)>,
    pub n_slots: usize,
    pub n_storages: usize,
    pub n_gather_plans: usize,
    pub n_exports: usize,
    pub n_dy_writes: usize,
    /// Total slab size in bytes (all storages, `f64`).
    pub slab_bytes: usize,
    /// Dedicated (cross-section-live) CONST storage bytes.
    pub slab_bytes_const: usize,
    /// Dedicated SEGMENT storage bytes.
    pub slab_bytes_segment: usize,
    /// Recycled (within-section) storage bytes.
    pub slab_bytes_recycled: usize,
    /// Build-time value-numbering hits served from the scope-local memo.
    pub vn_scope_hits: usize,
    /// Hits served from the cross-rule (box-pure) hoist map.
    pub vn_hoist_hits: usize,
    /// Step 4: kernel-fusion diagnostics (all-zero when fusion is disabled).
    pub fuse: FuseStats,
}

impl fmt::Display for TapeBuildReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "tape build report")?;
        writeln!(
            f,
            "  rules: {} taped / {} fallback (of {})",
            self.n_taped,
            self.fallbacks.len(),
            self.n_rules
        )?;
        for (name, reason) in &self.fallbacks {
            writeln!(f, "    fallback {name}: {reason}")?;
        }
        writeln!(
            f,
            "  instructions: {} CONST + {} SEGMENT + {} CONTINUOUS = {}",
            self.n_instr_const,
            self.n_instr_segment,
            self.n_instr_continuous,
            self.n_instr_const + self.n_instr_segment + self.n_instr_continuous
        )?;
        write!(f, "  opcodes:")?;
        for (op, n) in &self.opcode_counts {
            write!(f, " {op}={n}")?;
        }
        writeln!(f)?;
        writeln!(
            f,
            "  slots: {} ({} storages, {} gather plans, {} dy writes, {} exports)",
            self.n_slots, self.n_storages, self.n_gather_plans, self.n_dy_writes, self.n_exports
        )?;
        writeln!(
            f,
            "  slab: {:.2} MiB total ({:.2} MiB CONST + {:.2} MiB SEGMENT dedicated, {:.2} MiB recycled)",
            self.slab_bytes as f64 / (1024.0 * 1024.0),
            self.slab_bytes_const as f64 / (1024.0 * 1024.0),
            self.slab_bytes_segment as f64 / (1024.0 * 1024.0),
            self.slab_bytes_recycled as f64 / (1024.0 * 1024.0),
        )?;
        writeln!(
            f,
            "  value numbering: {} scope hits, {} hoist hits",
            self.vn_scope_hits, self.vn_hoist_hits
        )?;
        if self.fuse.n_groups > 0 {
            writeln!(
                f,
                "  fusion: {} -> {} instructions; {} groups absorbing {} \
                 ({} gathers folded, {} kept); group sizes [2-3]={} [4-7]={} \
                 [8-15]={} [16-31]={} [32-63]={} [64+]={}",
                self.fuse.instrs_before,
                self.fuse.instrs_after,
                self.fuse.n_groups,
                self.fuse.n_member_instrs,
                self.fuse.n_gathers_folded,
                self.fuse.n_gathers_kept,
                self.fuse.group_size_hist[0],
                self.fuse.group_size_hist[1],
                self.fuse.group_size_hist[2],
                self.fuse.group_size_hist[3],
                self.fuse.group_size_hist[4],
                self.fuse.group_size_hist[5],
            )?;
        }
        Ok(())
    }
}

/// Assemble the report from a finished program.
pub(crate) fn make_report(prog: &TapeProgram, vn_hits: (usize, usize)) -> TapeBuildReport {
    let mut opcode_counts: std::collections::HashMap<&'static str, usize> =
        std::collections::HashMap::new();
    for i in &prog.instrs {
        *opcode_counts.entry(i.opcode()).or_insert(0) += 1;
    }
    let mut opcode_counts: Vec<(String, usize)> = opcode_counts
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    opcode_counts.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let fallbacks: Vec<(String, String)> = prog
        .rules
        .iter()
        .filter_map(|r| match &r.status {
            RuleStatus::Fallback(reason) => Some((r.name.clone(), reason.clone())),
            RuleStatus::Taped => None,
        })
        .collect();
    let n_cont = prog.instrs.len() - (prog.n_const + prog.n_segment) as usize;
    TapeBuildReport {
        n_rules: prog.rules.len(),
        n_taped: prog.rules.len() - fallbacks.len(),
        fallbacks,
        n_instr_const: prog.n_const as usize,
        n_instr_segment: prog.n_segment as usize,
        n_instr_continuous: n_cont,
        opcode_counts,
        n_slots: prog.slots.len(),
        n_storages: prog.slab.storages.len(),
        n_gather_plans: prog.plans.len(),
        n_exports: prog.exports.len(),
        n_dy_writes: prog.dy_writes.len(),
        slab_bytes: prog.slab.total_elems * 8,
        slab_bytes_const: prog.slab.const_elems * 8,
        slab_bytes_segment: prog.slab.segment_elems * 8,
        slab_bytes_recycled: prog.slab.recycled_elems * 8,
        vn_scope_hits: vn_hits.0,
        vn_hoist_hits: vn_hits.1,
        fuse: prog.fuse_stats.clone(),
    }
}

impl ArrayCompiled {
    /// Build the tape program for this model. Called once per solve by
    /// `simulate_core` (Step 3b) and by the diagnostic entry points below.
    pub(crate) fn build_tape(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> (TapeProgram, TapeBuildReport) {
        self.build_tape_opts(discrete_forcing, !fuse_disabled())
    }

    /// [`Self::build_tape`] with the Step 4 fusion pass explicitly on/off
    /// (the env-independent entry the fused-vs-unfused A/B tests drive).
    pub(crate) fn build_tape_opts(
        &self,
        discrete_forcing: &HashSet<String>,
        fuse: bool,
    ) -> (TapeProgram, TapeBuildReport) {
        let const_names = self.classify_static_observeds(discrete_forcing);
        let seg_names = self.classify_segment_invariant_observeds(discrete_forcing, true);
        let (prog, vn_hits) = build_tape_program(
            &self.rhs_rules,
            &self.observed_rules,
            &self.var_shapes,
            &self.param_names,
            &const_names,
            &seg_names,
            fuse,
        );
        let report = make_report(&prog, vn_hits);
        (prog, report)
    }

    /// Build the tape and return the diagnostic report (see
    /// [`TapeBuildReport`]). Evaluation is unchanged: this is a build-and-
    /// discard entry for inspection tooling (`examples/tape_report.rs`).
    pub fn debug_build_tape_report(&self) -> TapeBuildReport {
        self.build_tape(&HashSet::new()).1
    }

    /// Step 4 diagnostic: dump per-group shape statistics of the fused
    /// program to stderr (`examples/fuse_stats.rs`).
    pub fn debug_dump_fuse_stats(&self) {
        let (prog, report) = self.build_tape(&HashSet::new());
        eprintln!("{report}");
        let mut by_regs: Vec<&FusedSpec> = prog.fused.iter().collect();
        by_regs.sort_by_key(|f| std::cmp::Reverse(f.n_regs));
        let max_regs = by_regs.first().map(|f| f.n_regs).unwrap_or(0);
        let tot_runs: usize = prog.fused.iter().map(|f| f.runs.len()).sum();
        let tot_micro: usize = prog.fused.iter().map(|f| f.micro.len()).sum();
        let tot_inputs: usize = prog.fused.iter().map(|f| f.inputs.len()).sum();
        let tot_outputs: usize = prog.fused.iter().map(|f| f.outputs.len()).sum();
        let tot_elem_ops: usize = prog
            .fused
            .iter()
            .map(|f| f.micro.len() * f.n_elems())
            .sum();
        let tot_out_elems: usize = prog
            .fused
            .iter()
            .map(|f| f.outputs.len() * f.n_elems())
            .sum();
        eprintln!(
            "element-ops per call: {} micro x elems | output elems stored {}",
            tot_elem_ops, tot_out_elems
        );
        eprintln!(
            "fused groups: {} | micro ops {} | inputs {} | outputs {} | runs {} | max n_regs {}",
            prog.fused.len(),
            tot_micro,
            tot_inputs,
            tot_outputs,
            tot_runs,
            max_regs
        );
        eprintln!("micro-op histogram (element-weighted, post-superop):");
        for (k, n) in prog.fuse_stats.micro_hist.iter().take(24) {
            eprintln!("  {n:>10}  {k}");
        }
        eprintln!("single-use adjacency (element-weighted, pre-superop):");
        for (k, n) in prog.fuse_stats.adj_hist.iter().take(24) {
            eprintln!("  {n:>10}  {k}");
        }
        eprintln!("arith chain lengths (element-weighted, pre-superop):");
        for (len, n) in prog.fuse_stats.chain_hist.iter() {
            eprintln!("  {n:>10}  len={len}");
        }
        for f in by_regs.iter().take(12) {
            eprintln!(
                "  group: shape={:?} micro={} regs={} inputs={} (shifted {}) scalars={} \
                 outputs={} runs={} folded_gathers={}",
                &f.shape[..],
                f.micro.len(),
                f.n_regs,
                f.inputs.len(),
                f.inputs.iter().filter(|i| i.shifted_ix.is_some()).count(),
                f.scalars.len(),
                f.outputs.len(),
                f.runs.len(),
                f.n_folded_gathers
            );
        }
    }
}
