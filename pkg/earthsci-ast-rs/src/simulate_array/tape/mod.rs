//! Tape compilation and execution.
//!
//! Compiles a model's observed + RHS rule set into a flat instruction program
//! ([`TapeProgram`]) with build-time value numbering (subsuming the runtime
//! CSE overlay for taped rules), cadence-sectioned instruction streams
//! (CONST / SEGMENT / CONTINUOUS), liveness-based slab coloring, `dy` scatter
//! descriptors and observed exports (Step 3a), and executes it as the
//! DEFAULT production RHS hot path through the fast slab executor in
//! [`exec`] (Step 3b): a model builds the program once, keeps it
//! ([`TapeCache`]), and each segment's RHS scratch runs it. Which evaluator runs is the caller's
//! choice of compiler (API_SPEC §5.8) and nothing else: `native` is this
//! tape, `interpreter` is the per-cell oracle. Under `native` the tape also
//! serves the finite-difference Jacobian closure and the observed passes
//! (the build-time materialization of static observeds, the per-segment seed
//! and the observeds reported at output times; see `tape_serves_passes`).
//! `debug_eval_rhs` is the oracle and never runs the tape.
//!
//! ## Instruction set
//!
//! [`ir`] defines it and fixes each instruction's element semantics; the
//! short version is that everything is straight-line and shape-static.
//! Elementwise work is [`Instr::Bin`] / [`Instr::Un`] / [`Instr::Neg`] /
//! [`Instr::Select`] (and, after the Step 4 fusion pass, [`Instr::Fused`]);
//! data movement is [`Instr::Gather`] / [`Instr::LoadElem`] /
//! [`Instr::Copy`] / [`Instr::Region`] / [`Instr::Fill`] / [`Instr::Ramp`];
//! control flow is the one structured [`Instr::JmpIfZero`]; and the
//! boundaries with the rest of the runtime are [`Instr::Export`],
//! [`Instr::DyWrite`] and [`Instr::Fallback`].
//!
//! Two instructions carry data or a fold rather than a per-element map, and
//! both exist so a whole downstream cone of rules stops falling back:
//!
//! * [`Instr::ConstArray`] materializes an inline array literal into a
//!   CONST-section slot — one instruction and one store per solve, whatever
//!   the literal's size, with the payload on
//!   [`TapeProgram::const_data`]. Without it an array-valued `const` had no
//!   representation at all (`Operand::Lit` is one `f64`; `Fill` broadcasts
//!   one scalar), so every reader of such a constant bailed.
//! * [`Instr::Reduce`] folds a source box over a set of axes with a binary
//!   kernel, visiting the source in ROW-MAJOR order — which is the per-cell
//!   oracle's contraction odometer, so a rank-0 `faq` (every index
//!   contracted, scalar result) folds the same terms in the same
//!   association the interpreter would. It is the one construct the tape
//!   lowers that the whole-array overlay declines outright.
//!
//! A third piece of the same work is not an instruction: the lowering
//! records every observed's statically inferable box, including the ones
//! produced by rules that FELL BACK, so an `Operand::Obs` read of a
//! per-cell-produced observed still carries a box and its readers stay on
//! the tape (`TapeBuilder::wholesale_shape`).
//!
//! ## Closed functions
//!
//! A fourth piece is likewise not an instruction. The esm-spec §9.2
//! `datetime.*` family — `year`, `month`, `day`, `hour`, `minute`, `second`,
//! `day_of_year`, `julian_day`, `is_leap_year` — is expanded at LOWERING time
//! into the arithmetic above (one floored divmod by 86400, then floors,
//! remainders, comparisons and selects on integer-valued `f64`s), so all
//! three executors gained it at once and none of them can drift from
//! another. The `interp.*` entries of the same registry are not lowered: they
//! read a table, and a rule that calls one becomes a fallback naming the
//! function.

mod exec;
mod fuse;
mod ir;
mod lower;
#[cfg(test)]
mod refexec;
#[cfg(test)]
mod tests;
// Phase 2: the XLA emitter over this IR (feature `xla`, OFF by default). Last
// in the list because it is the only optional one.
#[cfg(feature = "xla")]
pub mod xla_emit;

pub(crate) use exec::tape_disabled;
pub(in crate::simulate_array) use exec::{TapeCtx, run_tape_call};
pub(crate) use ir::*;
use lower::build_tape_program;

use super::{AlgebraicRule, ArrayCompiled};
use std::cell::RefCell;
use std::collections::HashSet;
use std::fmt;
use std::rc::Rc;

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
                 ({} gathers folded, {} kept, {} reductions folded); group sizes \
                 [2-3]={} [4-7]={} [8-15]={} [16-31]={} [32-63]={} [64+]={}",
                self.fuse.instrs_before,
                self.fuse.instrs_after,
                self.fuse.n_groups,
                self.fuse.n_member_instrs,
                self.fuse.n_gathers_folded,
                self.fuse.n_gathers_kept,
                self.fuse.n_reduces_folded,
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

/// Where ONE rule of a model landed, for `compiler_report` (API_SPEC §5.8).
///
/// Deliberately plain data rather than a borrow of the program: the record
/// lives on the Problem, apart from the program the model keeps.
#[derive(Clone, Debug)]
pub(crate) struct TapeRuleRecord {
    /// The rule's variable name, as the compiled model spells it (the caller
    /// qualifies it with the component).
    pub name: String,
    /// `"observed"` or `"state derivative"`.
    pub kind: &'static str,
    /// The cadence tier the rule runs at: `"const"` (once per solve, at
    /// setup), `"segment"` (once per forcing-refresh segment) or
    /// `"continuous"` (every right-hand-side call).
    pub cadence: &'static str,
    /// `None` when the rule lowered onto the tape; otherwise the DEEPEST
    /// decline reason reached while trying.
    pub fallback_reason: Option<String>,
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

/// A tape program this model built, with its report, kept so that every pass
/// that runs the tape — the construction-time gate, a state-free evaluation,
/// each solve, the diagnostic seams — runs the one program instead of
/// building its own.
///
/// What a build reads, and so what invalidates a kept program:
///
/// * the compiled model itself — its rules, state layout, parameter NAMES and
///   const-array registry. These are fixed when the model is constructed and
///   nothing mutates them through `&self`; a changed document is a new model,
///   with an empty cache.
/// * the DISCRETE-forcing set, which decides each observed's cadence tier;
/// * the precision in force (`crate::precision::active`), which rounds every
///   literal the build folds;
/// * whether the tape serves the observed passes (the runtime mode), which
///   decides what it exports.
///
/// The last three are the key an entry is looked up by. Parameter VALUES and
/// the forcing buffer's contents are not inputs: the program reads parameters
/// on every call, and it cannot read the forcing buffer at all. So a new
/// parameter vector, or new forcing data, needs no rebuild — the CONST and
/// SEGMENT sections the program primes from them are per-scratch state, re-run
/// when the parameter vector changes.
pub(crate) struct TapeCache {
    entries: RefCell<Vec<CachedTape>>,
}

struct CachedTape {
    discrete_forcing: Vec<String>,
    precision: crate::precision::Precision,
    serves_passes: bool,
    prog: Rc<TapeProgram>,
    report: Rc<TapeBuildReport>,
}

impl TapeCache {
    pub(crate) fn new() -> Self {
        TapeCache {
            entries: RefCell::new(Vec::new()),
        }
    }
}

impl ArrayCompiled {
    /// The production tape for `discrete_forcing`, built on first use and then
    /// served from [`TapeCache`]: see there for what a kept program depends on.
    pub(crate) fn tape(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> (Rc<TapeProgram>, Rc<TapeBuildReport>) {
        let mut forcing: Vec<String> = discrete_forcing.iter().cloned().collect();
        forcing.sort();
        let precision = crate::precision::active();
        let serves_passes = self.tape_serves_passes();
        if let Some(e) = self.tape_cache.entries.borrow().iter().find(|e| {
            e.discrete_forcing == forcing
                && e.precision == precision
                && e.serves_passes == serves_passes
        }) {
            return (Rc::clone(&e.prog), Rc::clone(&e.report));
        }
        let (prog, report) = self.build_tape(discrete_forcing);
        let (prog, report) = (Rc::new(prog), Rc::new(report));
        self.tape_cache.entries.borrow_mut().push(CachedTape {
            discrete_forcing: forcing,
            precision,
            serves_passes,
            prog: Rc::clone(&prog),
            report: Rc::clone(&report),
        });
        (prog, report)
    }

    /// The observed rules a taped scratch carries beside its program, shared
    /// rather than copied per install.
    pub(super) fn shared_observed_rules(&self) -> Rc<Vec<AlgebraicRule>> {
        Rc::clone(
            self.shared_observed
                .get_or_init(|| Rc::new(self.observed_rules.clone())),
        )
    }

    /// Build the tape program for this model, uncached. Production passes go
    /// through [`Self::tape`]; this is the build itself, for the tests that
    /// take a program apart.
    pub(crate) fn build_tape(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> (TapeProgram, TapeBuildReport) {
        self.build_tape_opts(discrete_forcing, Some(fuse::SuperopCfg::from_env()))
    }

    /// [`Self::build_tape`] with the Step 4 fusion pass explicitly on/off
    /// (the entry the fused-vs-unfused A/B tests drive).
    pub(crate) fn build_tape_opts(
        &self,
        discrete_forcing: &HashSet<String>,
        fuse: Option<fuse::SuperopCfg>,
    ) -> (TapeProgram, TapeBuildReport) {
        let const_names = self.classify_static_observeds(discrete_forcing);
        let seg_names = self.classify_segment_invariant_observeds(discrete_forcing, true);
        let (prog, vn_hits) = build_tape_program(self, &const_names, &seg_names, fuse);
        let report = make_report(&prog, vn_hits);
        (prog, report)
    }

    /// Build the tape and return the diagnostic report (see
    /// [`TapeBuildReport`]). Evaluation is unchanged: this is a build-and-
    /// discard entry for inspection tooling (`examples/tape_report.rs`).
    pub fn debug_build_tape_report(&self) -> TapeBuildReport {
        (*self.tape(&HashSet::new()).1).clone()
    }

    /// Where every rule of this model LANDS, in program order — the per-rule
    /// half of `compiler_report` (API_SPEC §5.8).
    ///
    /// [`TapeBuildReport::fallbacks`] answers only "which rules did not lower",
    /// which is the wrong half for a caller asking what a compiler did: a
    /// document with no fallbacks reports an empty list and says nothing about
    /// the rules that DID lower, nor at which cadence they run. This walks the
    /// program's whole rule table instead, so a taped rule is named too.
    ///
    /// Read off the same kept program the solve runs ([`Self::tape`]).
    pub(crate) fn tape_rule_records(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> (Vec<TapeRuleRecord>, TapeBuildReport) {
        let (prog, report) = self.tape(discrete_forcing);
        let report = (*report).clone();
        let records = prog
            .rules
            .iter()
            .map(|r| TapeRuleRecord {
                name: r.name.clone(),
                kind: match r.kind {
                    RuleKind::Observed(_) => "observed",
                    RuleKind::Rhs(_) => "state derivative",
                },
                cadence: match r.cadence {
                    Cadence::Const => "const",
                    Cadence::Segment => "segment",
                    Cadence::Continuous => "continuous",
                },
                fallback_reason: match &r.status {
                    RuleStatus::Taped => None,
                    RuleStatus::Fallback(reason) => Some(reason.clone()),
                },
            })
            .collect();
        (records, report)
    }

    /// Step 4 diagnostic: dump per-group shape statistics of the fused
    /// program to stderr (`examples/fuse_stats.rs`).
    pub fn debug_dump_fuse_stats(&self) {
        let (prog, report) = self.tape(&HashSet::new());
        eprintln!("{report}");
        let mut by_regs: Vec<&FusedSpec> = prog.fused.iter().collect();
        by_regs.sort_by_key(|f| std::cmp::Reverse(f.n_regs));
        let max_regs = by_regs.first().map(|f| f.n_regs).unwrap_or(0);
        let tot_runs: usize = prog.fused.iter().map(|f| f.runs.len()).sum();
        let tot_micro: usize = prog.fused.iter().map(|f| f.micro.len()).sum();
        let tot_inputs: usize = prog.fused.iter().map(|f| f.inputs.len()).sum();
        let tot_outputs: usize = prog.fused.iter().map(|f| f.outputs.len()).sum();
        let tot_elem_ops: usize = prog.fused.iter().map(|f| f.micro.len() * f.n_elems()).sum();
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
