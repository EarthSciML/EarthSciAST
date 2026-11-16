//! What the tape's test modules share: compiling a fixture document, seeded
//! states, bitwise comparison, opcode counts, the document builders of the
//! array-form tests, and the three A/B harnesses that build a fixture's
//! fused and unfused programs and run every executor over them:
//!
//! * [`ab_check`] against the interpreter, on warm scratches, row-major and
//!   split executions included;
//! * [`ab`] / [`compare_tape_at`] against the per-cell oracle, on a fresh
//!   scratch per evaluation, comparing the latched fault too;
//! * [`oracle_ab`] against the per-cell oracle under the document's own
//!   precision environment.

use super::super::{ArrayCompiled, RhsScratch, RhsStats};
use super::ir::*;
use super::refexec::run_reference;
use super::taped;
use crate::simulate_array::take_const_array_oob;
use crate::types::EsmFile;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

pub(super) fn typed(doc: serde_json::Value) -> EsmFile {
    // Through `load`, not `serde_json::from_value`: load activates the AST
    // interner, so structurally identical subtrees share one `Arc` — the
    // property the pointer-keyed value numbering exploits (exactly as the
    // production `load_path_with_options` path does).
    crate::parse::load_string(&doc.to_string()).expect("fixture document loads")
}

pub(super) fn compile(doc: serde_json::Value) -> ArrayCompiled {
    ArrayCompiled::from_file(&typed(doc)).expect("fixture compiles")
}

/// The production superop configuration (env-independent for tests).
pub(super) fn superop_cfg() -> super::fuse::SuperopCfg {
    super::fuse::SuperopCfg { ext_pairs: true }
}

/// Deterministic pseudo-random state in `[lo, hi)` (xorshift-style LCG).
pub(super) fn seeded_state(n: usize, seed: u64, lo: f64, hi: f64) -> Vec<f64> {
    let mut x = seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1);
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let u = (x >> 11) as f64 / (1u64 << 53) as f64;
            lo + u * (hi - lo)
        })
        .collect()
}

/// The counterpart of [`ab_check`] for a document the tape cannot lower:
/// BOTH builds (fused and unfused) must decline and leave no program, and a
/// scratch asked for a tape must be refused, naming the declined rule — never
/// handed back without a tape to run the legacy evaluator. Returns the fused
/// build's decline.
pub(super) fn declined_check(doc: serde_json::Value) -> DeclinedTape {
    let compiled = compile(doc);
    let (fused, report) = compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg()));
    let (unfused, _) = compiled.build_tape_opts(&HashSet::new(), None);
    let Err(declined) = fused else {
        panic!("the fixture must decline a rule:\n{report}");
    };
    assert!(unfused.is_err(), "the unfused build must decline too");
    assert_refused(&compiled, &declined);
    declined
}

/// A scratch asked of a model whose tape declined is refused with
/// `compiler_refused_rule`, naming the first declined rule and its reason.
pub(super) fn assert_refused(compiled: &ArrayCompiled, declined: &DeclinedTape) {
    let (rule, reason) = declined
        .declined_rules()
        .into_iter()
        .next()
        .expect("a declined tape names at least one rule");
    match compiled.debug_new_scratch_taped() {
        Ok(_) => panic!("a declined build must not hand back a scratch"),
        Err(crate::simulate::SimulateError::Compile(
            crate::compile_error::CompileError::CompilerRefusedRule {
                rule: r,
                reason: why,
                ..
            },
        )) => {
            assert_eq!(r, rule);
            assert_eq!(why, reason);
        }
        Err(e) => panic!("expected compiler_refused_rule, got {e:?}"),
    }
}

/// Build BOTH tapes (fused and unfused), each of which must lower every rule,
/// and assert bitwise `dy` equality against the production interpreter over
/// several seeded states and times — for BOTH executors on BOTH programs:
/// the reference executor (fresh run per state) and the Step 3b fast
/// executor (one warm taped scratch per program across all of them). Returns
/// the FUSED program.
pub(super) fn ab_check(doc: serde_json::Value, lo: f64, hi: f64) -> TapeProgram {
    let compiled = compile(doc);
    let (prog, _) = taped(compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg())));
    let (prog_uf, _) = taped(compiled.build_tape_opts(&HashSet::new(), None));
    assert!(
        prog_uf.fused.is_empty() && prog_uf.fuse_stats.n_groups == 0,
        "the unfused build must not fuse"
    );
    assert!(
        prog.instrs.len() <= prog_uf.instrs.len(),
        "fusion must not grow the program"
    );
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast_scratch = compiled
        .debug_new_scratch_taped()
        .expect("the tape lowers every rule");
    assert!(fast_scratch.has_tape(), "fixture scratch must carry a tape");
    // A second warm fast scratch carrying the UNFUSED program.
    let mut fast_uf = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_uf.install_tape(std::sync::Arc::new(prog_uf));
    let prog_uf = {
        // Rebuild for the reference arm (the scratch consumed the first).
        taped(compiled.build_tape_opts(&HashSet::new(), None)).0
    };
    // The fused program as lowered, without the state-layout alignment
    // (`layout`), which `prog` may carry: both storage orders must agree.
    let rm_build =
        || taped(compiled.build_tape_layout(&HashSet::new(), Some(superop_cfg()), false)).0;
    let prog_rm = rm_build();
    assert!(!prog_rm.col_major);
    let mut fast_rm = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_rm.install_tape(std::sync::Arc::new(rm_build()));
    let mut fast_stats = RhsStats::default();
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, lo, hi);
        for &t in &[0.0, 0.37, 2.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params);
            for (label, p) in [
                ("fused", &prog),
                ("unfused", &prog_uf),
                ("row-major fused", &prog_rm),
            ] {
                let mut dy = vec![0.0f64; n];
                run_reference(p, &compiled, &state, &param_vec, t, &mut dy);
                for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                    assert_eq!(
                        a.to_bits(),
                        b.to_bits(),
                        "seed {seed} t {t}: dy[{k}] diverged: {label} tape-ref {a:?} \
                         ({:016x}) vs interpreter {b:?} ({:016x})",
                        a.to_bits(),
                        b.to_bits()
                    );
                }
            }
            for (label, scratch) in [
                ("fused", &mut fast_scratch),
                ("unfused", &mut fast_uf),
                ("row-major fused", &mut fast_rm),
            ] {
                let mut dy_fast = vec![0.0f64; n];
                compiled.debug_eval_rhs_into(
                    &state,
                    t,
                    &param_vec,
                    &mut dy_fast,
                    scratch,
                    &mut fast_stats,
                );
                for (k, (a, b)) in dy_fast.iter().zip(dy_ref.iter()).enumerate() {
                    assert_eq!(
                        a.to_bits(),
                        b.to_bits(),
                        "seed {seed} t {t}: dy[{k}] diverged: {label} FAST exec {a:?} \
                         ({:016x}) vs interpreter {b:?} ({:016x})",
                        a.to_bits(),
                        b.to_bits()
                    );
                }
            }
            // Every instruction split three wide, whatever its size, is the
            // serial executor bit for bit.
            #[cfg(not(target_arch = "wasm32"))]
            for (label, scratch) in [
                ("fused split", &mut fast_scratch),
                ("row-major fused split", &mut fast_rm),
            ] {
                let mut dy_split = vec![0.0f64; n];
                super::exec::force_split(Some(3));
                compiled.debug_eval_rhs_into(
                    &state,
                    t,
                    &param_vec,
                    &mut dy_split,
                    scratch,
                    &mut fast_stats,
                );
                super::exec::force_split(None);
                for (k, (a, b)) in dy_split.iter().zip(dy_ref.iter()).enumerate() {
                    assert_eq!(
                        a.to_bits(),
                        b.to_bits(),
                        "seed {seed} t {t}: dy[{k}] diverged: {label} exec {a:?} vs \
                         interpreter {b:?}"
                    );
                }
            }
        }
    }
    assert!(
        fast_stats.taped_rules > 0,
        "the fast executor must have run"
    );
    prog
}

/// `a` and `b` equal bit for bit, element by element.
pub(super) fn assert_bits_eq(a: &[f64], b: &[f64], what: &str) {
    assert_eq!(a.len(), b.len(), "{what}: length");
    for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
        assert_eq!(
            x.to_bits(),
            y.to_bits(),
            "{what}: dy[{k}] diverged: {x:?} ({:016x}) vs {y:?} ({:016x})",
            x.to_bits(),
            y.to_bits()
        );
    }
}

/// A fresh scratch carrying `prog`.
pub(super) fn scratch_with(compiled: &ArrayCompiled, prog: TapeProgram) -> RhsScratch {
    let mut s = RhsScratch::new(&compiled.var_shapes);
    s.set_const_arrays(std::sync::Arc::clone(&compiled.const_scope));
    s.install_tape(std::sync::Arc::new(prog));
    s
}

/// Build the fused and unfused tapes — neither may carry a fallback — and
/// compare `dy` and the latched fault against the oracle at
/// several states, times and parameter maps. The fast executor is compared
/// on a FRESH scratch per evaluation: a CONST-section fault latches when the
/// section primes, which a warm scratch has already done. Returns the fused
/// program.
pub(super) fn ab(compiled: &ArrayCompiled, param_maps: &[HashMap<String, f64>]) -> TapeProgram {
    let (prog, report) = taped(compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg())));
    assert!(
        report.fallbacks.is_empty(),
        "fallbacks: {:?}",
        report.fallbacks
    );
    let n = compiled.state_variable_names().len();
    for params in param_maps {
        for seed in 0..3u64 {
            let state = seeded_state(n, seed, -2.0, 2.0);
            for &t in &[0.0, 0.7] {
                compare_tape_at(compiled, params, &state, t);
            }
        }
    }
    prog
}

/// Compare the fused and unfused tapes, in both executors, against the
/// oracle at one state, time and parameter map: `dy` bit for bit and the
/// latched fault.
pub(super) fn compare_tape_at(
    compiled: &ArrayCompiled,
    params: &HashMap<String, f64>,
    state: &[f64],
    t: f64,
) {
    let n = state.len();
    let pv = compiled.debug_resolve_params(params);
    take_const_array_oob();
    let (dy_oracle, _) = compiled.debug_eval_rhs(state, t, params);
    let f_oracle = take_const_array_oob();
    for fused in [true, false] {
        let label = if fused { "fused" } else { "unfused" };
        let p = taped(compiled.build_tape_opts(&HashSet::new(), fused.then(superop_cfg))).0;
        let mut dy = vec![0.0f64; n];
        run_reference(&p, compiled, state, &pv, t, &mut dy);
        let f_ref = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} reference executor"));
        assert_eq!(f_ref, f_oracle, "{label} reference executor fault");
        let mut scratch = scratch_with(compiled, p);
        let mut dy = vec![0.0f64; n];
        compiled.debug_eval_rhs_into(
            state,
            t,
            &pv,
            &mut dy,
            &mut scratch,
            &mut RhsStats::default(),
        );
        let f_fast = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} fast executor"));
        assert_eq!(f_fast, f_oracle, "{label} fast executor fault");
    }
}

/// The tape's refusals when it refuses any rule; otherwise [`compare_tape_at`] at
/// each of `states` under each parameter map, and no refusals.
pub(super) fn agrees_or_refuses(
    compiled: &ArrayCompiled,
    param_maps: &[HashMap<String, f64>],
    states: &[Vec<f64>],
) -> Vec<(String, String)> {
    let (_, report) = compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg()));
    if !report.fallbacks.is_empty() {
        return report.fallbacks;
    }
    for params in param_maps {
        for state in states {
            compare_tape_at(compiled, params, state, 0.0);
        }
    }
    Vec::new()
}

pub(super) fn no_params() -> Vec<HashMap<String, f64>> {
    vec![HashMap::new()]
}

/// How many instructions of a given opcode the program carries.
pub(super) fn opcount(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

/// `D(u[i]) = rhs` over `i ∈ [1, n]`.
pub(super) fn d_eq(var: &str, n: i64, rhs: serde_json::Value) -> serde_json::Value {
    json!({
        "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "expr": {"op": "D", "args": [{"op": "index", "args": [var, "i"]}], "wrt": "t"},
                "ranges": {"i": [1, n]}},
        "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, n]}, "expr": rhs}
    })
}

pub(super) fn idx(base: serde_json::Value, subs: &[serde_json::Value]) -> serde_json::Value {
    let mut args = vec![base];
    args.extend(subs.iter().cloned());
    json!({"op": "index", "args": args})
}

pub(super) fn plus(a: serde_json::Value, b: serde_json::Value) -> serde_json::Value {
    json!({"op": "+", "args": [a, b]})
}

pub(super) fn lit(v: &[f64]) -> serde_json::Value {
    json!({"op": "const", "args": [], "value": v})
}

pub(super) fn doc(vars: serde_json::Value, eqs: Vec<serde_json::Value>) -> serde_json::Value {
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "tape_array_forms"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    })
}

/// Build `doc` under its own precision environment, require that the tape
/// lowers every rule, and require that the reference executor and the fast
/// executor, over the fused and the unfused program, write the per-cell
/// oracle's `dy` bit for bit. Returns the fused program and the unfused one's
/// length.
pub(super) fn oracle_ab(doc: Value) -> (TapeProgram, usize) {
    let file = crate::parse::load_string(&doc.to_string()).expect("fixture document loads");
    let env = crate::precision_infer::env_of_file(&file).expect("precision environment");
    let file = crate::precision_infer::annotated(&file)
        .expect("precision inference")
        .unwrap_or(file);
    let _env = env.enter();
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    let (prog, report) = taped(compiled.build_tape_opts(&HashSet::new(), Some(superop_cfg())));
    let (prog_uf, report_uf) = taped(compiled.build_tape_opts(&HashSet::new(), None));
    let unfused_len = prog_uf.instrs.len();
    for rep in [&report, &report_uf] {
        assert!(
            rep.fallbacks.is_empty(),
            "the tape must lower every rule: {:?}",
            rep.fallbacks
        );
    }
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast = compiled
        .debug_new_scratch_taped()
        .expect("the tape lowers every rule");
    let mut fast_uf = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_uf.install_tape(std::sync::Arc::new(
        taped(compiled.build_tape_opts(&HashSet::new(), None)).0,
    ));
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, 0.25, 2.5);
        for &t in &[0.0, 0.37, 2.5] {
            let (oracle, _) = compiled.debug_eval_rhs(&state, t, &params);
            for (label, p) in [("fused", &prog), ("unfused", &prog_uf)] {
                let mut dy = vec![0.0f64; n];
                run_reference(p, &compiled, &state, &param_vec, t, &mut dy);
                assert_eq!(
                    bits(&dy),
                    bits(&oracle),
                    "seed {seed} t {t}: {label} reference executor"
                );
            }
            for (label, scratch) in [("fused", &mut fast), ("unfused", &mut fast_uf)] {
                let mut dy = vec![0.0f64; n];
                compiled.debug_eval_rhs_into(
                    &state,
                    t,
                    &param_vec,
                    &mut dy,
                    scratch,
                    &mut RhsStats::default(),
                );
                assert_eq!(
                    bits(&dy),
                    bits(&oracle),
                    "seed {seed} t {t}: {label} fast executor"
                );
            }
        }
    }
    (prog, unfused_len)
}

/// [`oracle_ab`] at two grid sizes, requiring the same lowered program length
/// (the unfused one: fusion's grouping may differ with the box size).
pub(super) fn flat_in_n(make: impl Fn(i64) -> Value, small: i64, large: i64) -> TapeProgram {
    let (_, a) = oracle_ab(make(small));
    let (b, b_len) = oracle_ab(make(large));
    assert_eq!(
        a, b_len,
        "the program must not grow with the grid ({small} vs {large} cells)"
    );
    b
}

/// The `Instr::Count`s of `prog`, as `(rel, sorted)`.
pub(super) fn counts(prog: &TapeProgram) -> Vec<(CountRel, bool)> {
    prog.instrs
        .iter()
        .filter_map(|i| match i {
            Instr::Count { rel, sorted, .. } => Some((*rel, *sorted)),
            _ => None,
        })
        .collect()
}
