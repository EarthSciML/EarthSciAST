//! Forcing reads on the tape (`Instr::LoadForcing`): a parameter refreshed
//! from outside the model is loaded from the forcing buffer once per section
//! run, in the CONST section, or in the SEGMENT section when a provider
//! refreshes it between segments, and every reader takes the slot.
//!
//! Each program here is checked bit for bit against the per-cell oracle and
//! the whole-array overlay, through the fast executor (fused and unfused) and
//! the reference executor.

use super::super::{ArrayCompiled, RhsScratch, RhsStats};
use super::ir::*;
use super::refexec::run_reference;
use ndarray::{ArrayD, IxDyn};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// `M` over `cells` (size `n`): state `c`, the data-fed forcings `bc` (shaped)
/// and `k` (0-d), the observed `g = 2*bc + k`, and
/// `D(c[i]) = g[i]*ifelse(t > 1, k, -k) - r*c[i] + bc[i-1]`, whose shifted
/// read of `bc` falls on the ghost at `i = 1`.
fn forced_doc(n: i64) -> serde_json::Value {
    let fed = |var: &str| json!({"kind": "data", "source": "met", "from": {"file_variable": var}});
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "Forced"},
        "index_sets": {"cells": {"kind": "interval", "size": n}},
        "data_sources": {"met": {"kind": "grid", "source": {"url_template": "file:///met.nc"}}},
        "models": {"M": {
            "variables": {
                "c": {"type": "unknown", "units": "1", "shape": ["cells"], "default": 0.5},
                "bc": {"type": "parameter", "units": "1", "shape": ["cells"], "update": fed("bc")},
                "k": {"type": "parameter", "units": "1", "shape": [], "update": fed("k")},
                "g": {"type": "unknown", "units": "1", "shape": ["cells"]},
                "r": {"type": "parameter", "units": "1", "default": 0.3}
            },
            "equations": [
                {"lhs": "g", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "+", "args": [
                        {"op": "*", "args": [2.0, {"op": "index", "args": ["bc", "i"]}]},
                        "k"]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"},
                    "ranges": {"i": [1, n]}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "+", "args": [
                        {"op": "-", "args": [
                            {"op": "*", "args": [
                                {"op": "index", "args": ["g", "i"]},
                                {"op": "ifelse", "args": [
                                    {"op": ">", "args": ["t", 1.0]},
                                    "k",
                                    {"op": "-", "args": ["k"]}]}]},
                            {"op": "*", "args": ["r", {"op": "index", "args": ["c", "i"]}]}]},
                        {"op": "index", "args": ["bc", {"op": "-", "args": ["i", 1]}]}]}}}
            ]
        }}
    })
}

fn compile(n: i64) -> ArrayCompiled {
    let file = crate::parse::load_string(&forced_doc(n).to_string()).expect("fixture loads");
    ArrayCompiled::from_file(&file).expect("fixture compiles")
}

fn bc_values(n: usize, scale: f64) -> ArrayD<f64> {
    ArrayD::from_shape_vec(
        IxDyn(&[n]),
        (0..n).map(|i| scale * (0.1 + i as f64 * 0.37)).collect(),
    )
    .expect("1-D")
}

fn feed(compiled: &ArrayCompiled, n: usize, scale: f64, k: f64) {
    let buf = compiled.forcing_buffer();
    let mut buf = buf.borrow_mut();
    buf.insert("bc".into(), bc_values(n, scale));
    buf.insert("k".into(), ArrayD::from_elem(IxDyn(&[]), k));
}

fn opcount(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

fn state_of(n: usize, seed: u64) -> Vec<f64> {
    (0..n)
        .map(|i| 0.25 + ((i as u64 * 7 + seed * 13) % 11) as f64 * 0.19)
        .collect()
}

fn assert_bits(got: &[f64], want: &[f64], label: &str) {
    assert_eq!(got.len(), want.len(), "{label}: length");
    for (k, (a, b)) in got.iter().zip(want).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{label}: dy[{k}] {a:?} vs interpreter {b:?}"
        );
    }
}

fn taped_scratch(compiled: &ArrayCompiled, prog: TapeProgram) -> RhsScratch {
    let mut s = compiled.debug_new_scratch();
    s.install_tape(Rc::new(prog), compiled.shared_observed_rules());
    s
}

fn fast(
    compiled: &ArrayCompiled,
    scratch: &mut RhsScratch,
    state: &[f64],
    t: f64,
    param_vec: &[f64],
) -> Vec<f64> {
    let mut dy = vec![0.0; state.len()];
    compiled.debug_eval_rhs_into(
        state,
        t,
        param_vec,
        &mut dy,
        scratch,
        &mut RhsStats::default(),
    );
    dy
}

#[test]
fn forcing_reads_tape_bit_identically_through_every_executor() {
    let n = 7usize;
    let compiled = compile(n as i64);
    feed(&compiled, n, 1.0, 0.7);
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let (prog, report) =
        compiled.build_tape_opts(&HashSet::new(), Some(super::fuse::SuperopCfg::from_env()));
    assert!(report.fallbacks.is_empty(), "{report}");
    // One load per forcing, however many rules read it: the ifelse branch
    // reuses the load the observed made.
    assert_eq!(opcount(&prog, "LoadForcing"), 2, "{report}");
    let (prog_uf, _) = compiled.build_tape_opts(&HashSet::new(), None);
    let cfg = Some(super::fuse::SuperopCfg::from_env());
    let mut fused = taped_scratch(&compiled, compiled.build_tape_opts(&HashSet::new(), cfg).0);
    let mut unfused = taped_scratch(&compiled, compiled.build_tape_opts(&HashSet::new(), None).0);
    for seed in 0..3u64 {
        let state = state_of(n, seed);
        for &t in &[0.0, 0.5, 2.0] {
            let (oracle, _) = compiled.debug_eval_rhs(&state, t, &params, true);
            let (overlay, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            assert_bits(&overlay, &oracle, "overlay");
            for (label, p) in [("fused", &prog), ("unfused", &prog_uf)] {
                let mut dy = vec![0.0; n];
                run_reference(p, &compiled, &state, &param_vec, t, &mut dy);
                assert_bits(&dy, &oracle, &format!("reference executor, {label}"));
            }
            assert_bits(
                &fast(&compiled, &mut fused, &state, t, &param_vec),
                &oracle,
                "fast executor, fused",
            );
            assert_bits(
                &fast(&compiled, &mut unfused, &state, t, &param_vec),
                &oracle,
                "fast executor, unfused",
            );
        }
    }
    assert!(crate::simulate_array::take_const_array_oob().is_none());
}

#[test]
fn a_forcing_load_runs_in_the_section_its_cadence_allows() {
    let n = 5usize;
    let compiled = compile(n as i64);
    let sections = |discrete: &HashSet<String>| -> Vec<(String, Cadence)> {
        let (prog, _) = compiled.build_tape_opts(discrete, None);
        prog.instrs
            .iter()
            .enumerate()
            .filter_map(|(pc, i)| match i {
                Instr::LoadForcing { forcing, .. } => Some((
                    prog.forcings[*forcing as usize].name.clone(),
                    prog.section_of(pc),
                )),
                _ => None,
            })
            .collect()
    };
    let mut none = sections(&HashSet::new());
    none.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        none,
        [
            ("bc".to_string(), Cadence::Const),
            ("k".to_string(), Cadence::Const)
        ]
    );
    let discrete: HashSet<String> = ["bc".to_string()].into();
    let mut some = sections(&discrete);
    some.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        some,
        [
            ("bc".to_string(), Cadence::Segment),
            ("k".to_string(), Cadence::Const)
        ]
    );
}

#[test]
fn the_forcing_program_does_not_grow_with_the_grid() {
    let shape = |n: i64| {
        let compiled = compile(n);
        let (prog, report) = compiled.build_tape_opts(&HashSet::new(), None);
        assert!(report.fallbacks.is_empty(), "{report}");
        (prog.instrs.len(), report.opcode_counts)
    };
    assert_eq!(shape(6), shape(600));
}

#[test]
fn a_missing_forcing_entry_faults_as_the_interpreter_does() {
    let n = 4usize;
    let compiled = compile(n as i64);
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = state_of(n, 1);
    crate::simulate_array::take_const_array_oob();
    compiled.debug_eval_rhs(&state, 0.0, &params, true);
    let want = crate::simulate_array::take_const_array_oob().expect("the oracle faults");
    assert!(want.starts_with("E_TREEWALK_UNBOUND_NAME: '"), "{want}");
    let mut scratch = taped_scratch(&compiled, compiled.build_tape_opts(&HashSet::new(), None).0);
    let dy = fast(&compiled, &mut scratch, &state, 0.0, &param_vec);
    let got = crate::simulate_array::take_const_array_oob().expect("the tape faults");
    assert_eq!(got, want);
    assert!(
        dy.iter().any(|v| v.is_nan()),
        "a missing forcing is never a number"
    );
}

#[test]
fn a_forcing_entry_of_another_shape_faults() {
    let n = 4usize;
    let compiled = compile(n as i64);
    feed(&compiled, n, 1.0, 0.7);
    let param_vec = compiled.debug_resolve_params(&HashMap::new());
    let prog = Rc::new(compiled.build_tape_opts(&HashSet::new(), None).0);
    let scratch_for = |prog: &Rc<TapeProgram>| {
        let mut s = compiled.debug_new_scratch();
        s.install_tape(Rc::clone(prog), compiled.shared_observed_rules());
        s
    };
    crate::simulate_array::take_const_array_oob();
    fast(
        &compiled,
        &mut scratch_for(&prog),
        &state_of(n, 0),
        0.0,
        &param_vec,
    );
    assert!(crate::simulate_array::take_const_array_oob().is_none());
    // The buffer changes shape under a program built against the old one.
    compiled
        .forcing_buffer()
        .borrow_mut()
        .insert("bc".into(), bc_values(n + 1, 1.0));
    let dy = fast(
        &compiled,
        &mut scratch_for(&prog),
        &state_of(n, 0),
        0.0,
        &param_vec,
    );
    let msg = crate::simulate_array::take_const_array_oob().expect("the mismatch faults");
    assert!(
        msg.contains("'bc' with shape [5]") && msg.contains("reads it as [4]"),
        "{msg}"
    );
    assert!(dy.iter().any(|v| v.is_nan()));
}

#[test]
fn the_forcing_epoch_reruns_the_segment_section_only() {
    let n = 6usize;
    let compiled = compile(n as i64);
    feed(&compiled, n, 1.0, 0.7);
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let discrete: HashSet<String> = ["bc".to_string()].into();
    let (prog, report) =
        compiled.build_tape_opts(&discrete, Some(super::fuse::SuperopCfg::from_env()));
    assert!(report.fallbacks.is_empty(), "{report}");
    let mut scratch = taped_scratch(&compiled, prog);
    let state = state_of(n, 2);
    let t = 2.0;
    let first = fast(&compiled, &mut scratch, &state, t, &param_vec);
    assert_bits(
        &first,
        &compiled.debug_eval_rhs(&state, t, &params, true).0,
        "primed",
    );

    // A refresh of the DISCRETE forcing: served stale until the epoch moves,
    // and after it exactly as the interpreter reads the refreshed buffer.
    feed(&compiled, n, 3.0, 0.7);
    assert_bits(
        &fast(&compiled, &mut scratch, &state, t, &param_vec),
        &first,
        "before the epoch moves",
    );
    scratch.bump_forcing_epoch();
    let refreshed = fast(&compiled, &mut scratch, &state, t, &param_vec);
    assert_bits(
        &refreshed,
        &compiled.debug_eval_rhs(&state, t, &params, true).0,
        "after the epoch moves",
    );
    assert_ne!(refreshed, first, "the refresh is load-bearing");

    // `k` is not DISCRETE, so its load is CONST and the forcing epoch does
    // not re-run it: nothing refreshes a CONST forcing inside a solve.
    feed(&compiled, n, 3.0, -1.5);
    scratch.bump_forcing_epoch();
    assert_bits(
        &fast(&compiled, &mut scratch, &state, t, &param_vec),
        &refreshed,
        "a CONST forcing is loaded once per scratch",
    );
}

/// A segmented solve that refreshes `bc` at each boundary, under `mode`, with
/// the forcing buffer primed at `t0` as the provider executor primes it.
#[cfg(all(feature = "solve", not(target_arch = "wasm32")))]
fn segmented_solve(
    mode: super::super::RuntimeMode,
    boundaries: &[f64],
) -> (crate::simulate::Solution, (u64, u64)) {
    let n = 5usize;
    let mut compiled = compile(n as i64);
    compiled.runtime_mode = mode;
    let buf = compiled.forcing_buffer();
    let discrete: HashSet<String> = ["bc".to_string()].into();
    let opts = crate::simulate::SolveOptions {
        saveat: Some(vec![0.5, 1.0, 1.5, 2.0, 2.5, 3.0]),
        ..Default::default()
    };
    let before = super::section_primes();
    let sol = compiled
        .solve_with_refresh_inspect(
            (0.0, 3.0),
            &HashMap::new(),
            &HashMap::new(),
            &opts,
            None,
            &discrete,
            boundaries,
            |t| {
                let mut b = buf.borrow_mut();
                b.insert("bc".into(), bc_values(n, 1.0 + t));
                b.insert("k".into(), ArrayD::from_elem(IxDyn(&[]), 0.7));
                Ok(())
            },
        )
        .expect("segmented solve");
    let after = super::section_primes();
    (sol, (after.0 - before.0, after.1 - before.1))
}

/// Under `native` the solve keeps one tape scratch across its segments and
/// re-runs only the SEGMENT section after each refresh, and the trajectory is
/// the interpreter's, bit for bit.
#[cfg(all(feature = "solve", not(target_arch = "wasm32")))]
#[test]
fn a_segmented_native_solve_refreshes_through_the_forcing_epoch() {
    use super::super::RuntimeMode;
    let (want, _) = segmented_solve(RuntimeMode::Interpreter, &[1.0, 2.0]);
    let (got, (full, seg)) = segmented_solve(RuntimeMode::Native, &[1.0, 2.0]);
    assert_eq!(got.time, want.time);
    for (row, (g, w)) in got.state.iter().zip(&want.state).enumerate() {
        assert_bits(g, w, &format!("state row {row}"));
    }
    // Every segment after the first re-runs SEGMENT without CONST, and the
    // number of full primes does not grow with the number of segments.
    assert!(seg >= 2, "SEGMENT-only reruns: {seg}");
    let (_, (full_one, seg_one)) = segmented_solve(RuntimeMode::Native, &[1.5]);
    assert_eq!(full, full_one, "full primes per solve");
    assert!(seg_one >= 1 && seg_one < seg, "{seg_one} vs {seg}");
}
