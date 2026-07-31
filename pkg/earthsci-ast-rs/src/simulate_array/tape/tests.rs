//! A/B verification of the tape: build the tape for fixture models, run BOTH
//! executors — the slow reference executor ([`super::refexec`], which pins the
//! LOWERING) and the production fast executor ([`super::exec`], Step 3b,
//! reached through a taped scratch + `debug_eval_rhs_into`) — and assert
//! **bitwise** equality of `dy` against `evaluate_rhs_with_scratch`, the full
//! legacy production path (vectorized overlay + runtime CSE), at several
//! random-but-seeded states and times. The fast-executor arm reuses ONE warm
//! scratch across every state/time, so slab recycling, CONST-section
//! retention and the section re-run discipline are all exercised.

use super::super::{ArrayCompiled, RhsStats};
use super::ir::*;
use super::refexec::{RefVal, run_reference};
use crate::types::EsmFile;
use serde_json::json;
use std::collections::{HashMap, HashSet};

fn typed(doc: serde_json::Value) -> EsmFile {
    // Through `load`, not `serde_json::from_value`: load activates the AST
    // interner, so structurally identical subtrees share one `Arc` — the
    // property the pointer-keyed value numbering exploits (exactly as the
    // production `load_path_with_options` path does).
    crate::parse::load(&doc.to_string()).expect("fixture document loads")
}

fn compile(doc: serde_json::Value) -> ArrayCompiled {
    ArrayCompiled::from_file(&typed(doc)).expect("fixture compiles")
}

/// The production superop configuration (env-independent for tests).
fn default_cfg() -> super::fuse::SuperopCfg {
    super::fuse::SuperopCfg {
        bin3: false,
        ext_pairs: true,
    }
}

/// Every superop enabled (the Bin3 A/B arm).
fn all_superops_cfg() -> super::fuse::SuperopCfg {
    super::fuse::SuperopCfg {
        bin3: true,
        ext_pairs: true,
    }
}

/// Deterministic pseudo-random state in `[lo, hi)` (xorshift-style LCG).
fn seeded_state(n: usize, seed: u64, lo: f64, hi: f64) -> Vec<f64> {
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

/// Build BOTH tapes (fused and unfused), check the expected fallback count,
/// and assert bitwise `dy` equality against the production interpreter over
/// several seeded states and times — for BOTH executors on BOTH programs:
/// the reference executor (fresh run per state) and the Step 3b fast
/// executor (one warm taped scratch per program across all of them). Returns
/// the FUSED program.
fn ab_check(doc: serde_json::Value, expect_fallbacks: usize, lo: f64, hi: f64) -> TapeProgram {
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), Some(default_cfg()));
    let (prog_uf, report_uf) = compiled.build_tape_opts(&HashSet::new(), None);
    for rep in [&report, &report_uf] {
        assert_eq!(
            rep.fallbacks.len(),
            expect_fallbacks,
            "unexpected fallback set: {:?}",
            rep.fallbacks
        );
    }
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
    let mut fast_scratch = compiled.debug_new_scratch_taped();
    assert!(fast_scratch.has_tape(), "fixture scratch must carry a tape");
    // A second warm fast scratch carrying the UNFUSED program.
    let mut fast_uf = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_uf.install_tape(
        std::rc::Rc::new(prog_uf),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let prog_uf = {
        // Rebuild for the reference arm (the scratch consumed the first).
        compiled.build_tape_opts(&HashSet::new(), None).0
    };
    let mut fast_stats = RhsStats::default();
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, lo, hi);
        for &t in &[0.0, 0.37, 2.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            for (label, p) in [("fused", &prog), ("unfused", &prog_uf)] {
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
            for (label, scratch) in [("fused", &mut fast_scratch), ("unfused", &mut fast_uf)] {
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
        }
    }
    assert!(fast_stats.taped_rules > 0, "the fast executor must have run");
    prog
}

/// The periodic-wrap index idiom the lat-lon discretization emits:
/// `ifelse(inner < lo, inner + P, ifelse(inner > hi, inner - P, inner))`.
fn wrap(inner: serde_json::Value, lo: i64, hi: i64) -> serde_json::Value {
    let p = hi - lo + 1;
    json!({"op": "ifelse", "args": [
        {"op": "<", "args": [inner, lo]},
        {"op": "+", "args": [inner, p]},
        {"op": "ifelse", "args": [
            {"op": ">", "args": [inner, hi]},
            {"op": "-", "args": [inner, p]},
            inner
        ]}
    ]})
}

/// `D(u[i]) = rhs` over `i ∈ [1, n]` (the standard method-of-lines equation).
fn d_eq(var: &str, n: i64, rhs: serde_json::Value) -> serde_json::Value {
    json!({
        "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                "expr": {"op": "D", "args": [{"op": "index", "args": [var, "i"]}], "wrt": "t"},
                "ranges": {"i": [1, n]}},
        "rhs": rhs
    })
}

fn agg(n: i64, body: serde_json::Value) -> serde_json::Value {
    json!({"op": "aggregate", "args": [], "output_idx": ["i"],
           "ranges": {"i": [1, n]}, "expr": body})
}

fn idx(var: &str, e: serde_json::Value) -> serde_json::Value {
    json!({"op": "index", "args": [var, e]})
}

/// Evaluate through the Step 3b FAST executor (warm taped scratch) and assert
/// bitwise `dy` equality against `dy_ref`.
fn assert_fast_matches(
    compiled: &ArrayCompiled,
    scratch: &mut super::super::RhsScratch,
    param_vec: &[f64],
    state: &[f64],
    t: f64,
    dy_ref: &[f64],
    label: &str,
) {
    let mut dy = vec![0.0f64; dy_ref.len()];
    let mut stats = RhsStats::default();
    compiled.debug_eval_rhs_into(state, t, param_vec, &mut dy, scratch, &mut stats);
    for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{label}: dy[{k}] diverged: FAST exec {a:?} ({:016x}) vs interpreter {b:?} ({:016x})",
            a.to_bits(),
            b.to_bits()
        );
    }
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

/// Multi-rule PDE: a periodic (wrap) Laplacian on `u` and a clamped-ghost
/// Laplacian on `v` — the wraps + ghost-0 gathers of a real stencil.
#[test]
fn ab_multi_rule_stencil_wrap_and_ghost() {
    let n = 8;
    let lap_wrap = json!({"op": "+", "args": [
        idx("u", wrap(json!({"op": "-", "args": ["i", 1]}), 1, n)),
        {"op": "*", "args": [-2.0, idx("u", json!("i"))]},
        idx("u", wrap(json!({"op": "+", "args": ["i", 1]}), 1, n))
    ]});
    let lap_ghost = json!({"op": "+", "args": [
        idx("v", json!({"op": "-", "args": ["i", 1]})),
        {"op": "*", "args": [-2.0, idx("v", json!("i"))]},
        idx("v", json!({"op": "+", "args": ["i", 1]}))
    ]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_stencil"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "v": {"type": "state", "shape": ["i"]}
            },
            "equations": [
                d_eq("u", n, agg(n, lap_wrap)),
                d_eq("v", n, agg(n, lap_ghost))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -3.0, 3.0);
    // The wrap must have become a Gather with a two-segment (rolled) axis.
    assert!(
        prog.plans
            .iter()
            .any(|p| p.segs.iter().any(|s| s.len() == 2)),
        "expected a rolled (two-segment) gather axis for the periodic wrap"
    );
}

/// Nested aggregate materialized once and indexed (`D(u[i]) = index(agg, i)`).
#[test]
fn ab_nested_aggregate() {
    let n = 8;
    let inner = json!({"op": "aggregate", "args": [], "output_idx": ["j"],
    "ranges": {"j": [1, n]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["j", 1]})),
        idx("u", json!("j"))
    ]}});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_nested"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [inner, "i"]})))
            ]
        }}
    });
    ab_check(doc, 0, -2.0, 2.0);
}

/// The same nested aggregate, but the inner `output_idx` REBINDS the enclosing
/// symbol — `i` inside `i` rather than `j` inside `i`. That is the shape a
/// discretization template plants whenever a `D(·)` is written inline in an
/// equation body instead of being named as its own observed (issue #98): both
/// aggregates are keyed on the grid's index names, so they collide.
///
/// The collision is a SHADOW, not a dependence — inside the inner body `i` is
/// the inner aggregate's own index — so the hoist is sound and this must tape
/// exactly like the `j` spelling above. Before the admission test learned about
/// shadowing, this single rename was the difference between a 4-instruction
/// tape and one `Instr::Fallback`.
#[test]
fn ab_nested_aggregate_shadowing_enclosing_index() {
    let n = 8;
    let inner = json!({"op": "aggregate", "args": [], "output_idx": ["i"],
    "ranges": {"i": [1, n]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["i", 1]})),
        idx("u", json!("i"))
    ]}});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_nested_shadow"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [inner, "i"]})))
            ]
        }}
    });
    ab_check(doc, 0, -2.0, 2.0);
}

/// The real `central_D_lon_*` shape: a `makearray` of boundary regions whose
/// region VALUES are aggregates keyed on the same symbol as the enclosing
/// output box. `lower_makearray` hands every region box the enclosing symbols
/// (`bx.syms`), so each region value re-collides with `i` one level further
/// down than [`ab_nested_aggregate_shadowing_enclosing_index`] — the form an
/// expression template produces after `substitute` inlines it at a call site
/// and the operator is lowered on the next fixpoint pass.
#[test]
fn ab_nested_aggregate_makearray_of_shadowed_aggregates() {
    let n = 8;
    let region_agg = |lo: i64, hi: i64, body: serde_json::Value| {
        json!({"op": "aggregate", "args": [], "output_idx": ["i"],
               "ranges": {"i": [lo, hi]}, "expr": body})
    };
    let interior = region_agg(
        2,
        n - 1,
        json!({"op": "/", "args": [
            {"op": "-", "args": [
                idx("u", json!({"op": "+", "args": ["i", 1]})),
                idx("u", json!({"op": "-", "args": ["i", 1]}))
            ]},
            2.0
        ]}),
    );
    let left = region_agg(
        1,
        1,
        json!({"op": "-", "args": [idx("u", json!(2)), idx("u", json!(1))]}),
    );
    let right = region_agg(
        n,
        n,
        json!({"op": "-", "args": [idx("u", json!(n)), idx("u", json!(n - 1))]}),
    );
    let ma = json!({"op": "makearray", "args": [],
        "regions": [[[2, n - 1]], [[1, 1]], [[n, n]]],
        "values": [interior, left, right]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_nested_makearray_agg"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [ma, "i"]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(prog.regions.len(), 3, "three makearray regions lowered");
}

/// The soundness boundary of the shadow analysis: an enclosing symbol the
/// nested aggregate does NOT rebind is a genuine dependence and must keep
/// bailing. Here the inner aggregate is keyed on `j` and its body multiplies by
/// the enclosing `i`, so the oracle's value differs for every enclosing cell
/// and hoisting it out of the loop would be wrong.
///
/// Widening this by accident would not merely be slow — it would be silently
/// WRONG: the hoisted box drops the enclosing symbols, so `i` would fall
/// through the resolver ladder onto a same-named state/observed/parameter.
///
/// The model carries a second, fully taped rule so both executor arms run.
#[test]
fn ab_nested_aggregate_capturing_enclosing_index_still_falls_back() {
    let n = 6;
    let inner = json!({"op": "aggregate", "args": [], "output_idx": ["j"],
    "ranges": {"j": [1, n]},
    "expr": {"op": "*", "args": [idx("u", json!("j")), "i"]}});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_nested_capture"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "v": {"type": "state", "shape": ["i"]}
            },
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [inner, "i"]}))),
                d_eq("v", n, agg(n, json!({"op": "*", "args": [-0.5, idx("v", json!("i"))]})))
            ]
        }}
    });
    let (_prog, report) = compile(doc.clone()).build_tape(&HashSet::new());
    let (name, reason) = report
        .fallbacks
        .first()
        .expect("the captured enclosing index must produce a fallback");
    assert!(
        reason.contains("enclosing bound index"),
        "fallback on `{name}` must name the captured index, got: {reason}"
    );
    ab_check(doc, 1, -2.0, 2.0);
}

/// Makearray with three regions (Dirichlet rows + interior stencil), the
/// interior repeating a subexpression (exercises scope-local value numbering
/// inside a region scope).
#[test]
fn ab_makearray_regions() {
    let n = 8;
    let d = json!({"op": "-", "args": [idx("u", json!("i")),
                                       idx("u", json!({"op": "-", "args": ["i", 1]}))]});
    let interior = json!({"op": "+", "args": [
        {"op": "*", "args": [d, d]},
        {"op": "*", "args": ["i", d]}
    ]});
    let ma = json!({"op": "makearray", "args": [],
        "regions": [[[2, n - 1]], [[1, 1]], [[n, n]]],
        "values": [interior, 0.5, {"op": "*", "args": [2.0, idx("u", json!("i"))]}]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_makearray"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [ma, "i"]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(prog.regions.len(), 3, "three makearray regions lowered");
}

/// Static einsum contraction with the `ifelse(k==0,…)` weight idiom — the
/// per-tuple fold in `eval_vec_contracted`'s ascending mixed-radix order.
#[test]
fn ab_contraction_weights() {
    let n = 8;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_einsum"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "aggregate", "args": [], "output_idx": ["i"],
                    "reduce": "+",
                    "ranges": {"i": [1, n], "k": [-1, 1]},
                    "expr": {"op": "*", "args": [
                        25,
                        {"op": "ifelse", "args": [{"op": "==", "args": ["k", 0]}, -2, 1]},
                        idx("u", json!({"op": "+", "args": ["i", "k"]}))
                    ]}}))
            ]
        }}
    });
    ab_check(doc, 0, -2.0, 2.0);
}

/// A contraction gated by a §5.3 filter on an output symbol (`j <= i`), which
/// vectorizes as a per-tuple Ramp/compare/Select mask.
#[test]
fn ab_contraction_with_filter_mask() {
    let n = 6;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_filter"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "aggregate", "args": [], "output_idx": ["i"],
                    "reduce": "+",
                    "ranges": {"i": [1, n], "j": [1, n]},
                    "filter": {"op": "<=", "args": ["j", {"op": "*", "args": [1, "i"]}]},
                    "expr": idx("u", json!("j"))}))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    let has_select = prog
        .instrs
        .iter()
        .any(|i| matches!(i, Instr::Select { .. }))
        || prog
            .fused
            .iter()
            .any(|fs| fs.micro.iter().any(|m| matches!(m, MicroOp::Select { .. })));
    assert!(
        has_select,
        "the filter mask must lower to Select instructions (plain or fused)"
    );
}

/// Scalar-`ifelse` short circuit: the untaken branch (whose evaluation would
/// produce `inf` from a division by zero) must NEVER execute — its slots stay
/// undefined in the reference run.
#[test]
fn ab_scalar_ifelse_short_circuit_traps_untaken_branch() {
    let n = 6;
    // cond `p > 1000` is false for the default p = 2, so the TRUE branch
    // (the trapping division u[i]/(p-p) → ±inf) must never run.
    let trap = json!({"op": "/", "args": [
        idx("u", json!("i")),
        {"op": "-", "args": ["p", "p"]}
    ]});
    let safe = json!({"op": "*", "args": [3.0, idx("u", json!("i"))]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_shortcircuit"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "p": {"type": "parameter", "default": 2.0}
            },
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "ifelse", "args": [
                    {"op": ">", "args": ["p", 1000.0]}, trap, safe]})))
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    // Locate the JmpIfZero and collect the slots its TRUE region defines.
    let (jmp_at, n_true, n_false) = prog
        .instrs
        .iter()
        .enumerate()
        .find_map(|(i, ins)| match ins {
            Instr::JmpIfZero {
                n_true, n_false, ..
            } => Some((i, *n_true as usize, *n_false as usize)),
            _ => None,
        })
        .expect("a JmpIfZero was emitted");
    // Slots defined ONLY in the true region (the phi slot is defined by the
    // trailing Copy of BOTH branches and is legitimately written).
    let false_defs: Vec<SlotId> = prog.instrs[jmp_at + 1 + n_true..jmp_at + 1 + n_true + n_false]
        .iter()
        .filter_map(|i| i.out())
        .collect();
    let true_slots: Vec<SlotId> = prog.instrs[jmp_at + 1..jmp_at + 1 + n_true]
        .iter()
        .filter_map(|i| i.out())
        .filter(|s| !false_defs.contains(s))
        .collect();
    assert!(
        !true_slots.is_empty(),
        "the trapping branch has instructions"
    );

    let nstates = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = seeded_state(nstates, 7, 0.5, 2.0);
    let (dy_ref, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
    let mut dy = vec![0.0f64; nstates];
    let run = run_reference(&prog, &compiled, &state, &param_vec, 0.0, &mut dy);
    for (a, b) in dy.iter().zip(dy_ref.iter()) {
        assert_eq!(a.to_bits(), b.to_bits());
        assert!(a.is_finite(), "no inf/NaN may leak from the untaken branch");
    }
    for s in true_slots {
        assert!(
            run.slots[s as usize].is_none(),
            "slot {s} of the untaken branch was executed"
        );
    }
    // FAST executor: same short-circuit, same bits, no inf/NaN leakage.
    let mut fast = compiled.debug_new_scratch_taped();
    assert_fast_matches(
        &compiled,
        &mut fast,
        &param_vec,
        &state,
        0.0,
        &dy_ref,
        "short-circuit",
    );
}

/// Array-condition `ifelse` (Select): a NaN in the UNCHOSEN branch (sqrt of a
/// negative) must not contaminate the selected result.
#[test]
fn ab_select_nan_semantics() {
    let n = 8;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_select_nan"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "ifelse", "args": [
                    {"op": ">=", "args": [idx("u", json!("i")), 0.0]},
                    {"op": "sqrt", "args": [idx("u", json!("i"))]},
                    0.25]})))
            ]
        }}
    });
    // The seeded range straddles zero, so both branches are live per cell and
    // the sqrt branch holds NaN at every negative cell.
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    let nstates = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast = compiled.debug_new_scratch_taped();
    for seed in 0..4u64 {
        let state = seeded_state(nstates, seed, -2.0, 2.0);
        assert!(state.iter().any(|&x| x < 0.0), "fixture needs negatives");
        let (dy_ref, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        let mut dy = vec![0.0f64; nstates];
        run_reference(&prog, &compiled, &state, &param_vec, 0.0, &mut dy);
        for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
            assert_eq!(a.to_bits(), b.to_bits(), "dy[{k}]");
            assert!(!a.is_nan(), "NaN leaked through the select at cell {k}");
        }
        assert_fast_matches(
            &compiled,
            &mut fast,
            &param_vec,
            &state,
            0.0,
            &dy_ref,
            "select-nan",
        );
    }
}

/// Signed-zero distinctness: literal `-0.0` and `neg(0.0)` must survive
/// constant folding with their sign (bitwise oracle comparison catches a
/// `-0.0` → `0.0` slip).
#[test]
fn ab_signed_zero() {
    let n = 4;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_signed_zero"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "+", "args": [
                    {"op": "*", "args": [-0.0, idx("u", json!("i"))]},
                    {"op": "neg", "args": [0.0]}
                ]})))
            ]
        }}
    });
    // Positive states: -0.0 * u = -0.0; sum with neg(0.0) = -0.0 exactly.
    let prog = ab_check(doc, 0, 0.5, 2.0);
    let _ = prog;
}

/// N-ary left-fold order: `0.1 + 0.2 + 0.3 + u[i]` re-associated differs in
/// the last bit, so bitwise equality against the oracle pins the fold order.
/// A `min` chain is included for the kernel-order-sensitive family.
#[test]
fn ab_nary_fold_order() {
    let n = 6;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_fold_order"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "+", "args": [
                    0.1, 0.2, 0.3,
                    idx("u", json!("i")),
                    {"op": "min", "args": [
                        idx("u", json!("i")),
                        {"op": "*", "args": [0.1, idx("u", json!("i"))]},
                        0.7
                    ]}
                ]})))
            ]
        }}
    });
    ab_check(doc, 0, -2.0, 2.0);
}

/// Sub-block dy scatter: `D(u[i+1]) = u[i]` writes a shifted sub-block of the
/// variable's flat dy block (`subblock_dest` with shift 1).
#[test]
fn ab_subblock_dy_scatter() {
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_subblock"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                {
                    "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]}
                            ], "wrt": "t"},
                            "ranges": {"i": [1, 7]}},
                    "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                            "ranges": {"i": [1, 7]},
                            "expr": idx("u", json!("i"))}
                },
                // The shifted LHS covers u[2..8]; u[1] needs its own
                // (indexed-scalar) defining equation.
                {"lhs": {"op": "D", "args": [{"op": "index", "args": ["u", 1]}], "wrt": "t"},
                 "rhs": {"op": "*", "args": [0.5, {"op": "index", "args": ["u", 1]}]}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert!(
        prog.dy_writes
            .iter()
            .any(|w| w.dest_lo.iter().any(|&d| d > 0)),
        "expected a shifted sub-block dy write"
    );
}

/// Observed chain: a taped array observed feeding the RHS rule, a scalar
/// observed (exported for the samples cone), and a 2-D broadcast gather of a
/// 1-D observed along the second axis.
#[test]
fn ab_observed_chain_and_broadcast() {
    let ni = 5;
    let nj = 4;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_obs"},
        "models": {"M": {
            "variables": {
                "w": {"type": "state", "shape": ["i", "j"]},
                "x": {"type": "state"},
                "c": {"type": "observed", "shape": ["j"],
                      "expression": {"op": "aggregate", "args": [], "output_idx": ["j"],
                          "ranges": {"j": [1, nj]},
                          "expr": {"op": "cos", "args": [{"op": "*", "args": [0.3, "j"]}]}}},
                "s": {"type": "observed",
                      "expression": {"op": "*", "args": [2.0, "x"]}}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [{"op": "neg", "args": ["s"]}, "x"]}},
                {
                    "lhs": {"op": "aggregate", "args": [], "output_idx": ["i", "j"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["w", "i", "j"]}], "wrt": "t"},
                            "ranges": {"i": [1, ni], "j": [1, nj]}},
                    "rhs": {"op": "aggregate", "args": [], "output_idx": ["i", "j"],
                            "ranges": {"i": [1, ni], "j": [1, nj]},
                            "expr": {"op": "*", "args": [
                                {"op": "index", "args": ["c", "j"]},
                                {"op": "index", "args": ["w", "i", "j"]}
                            ]}}
                }
            ]
        }}
    });
    let prog = ab_check(doc, 0, 0.2, 2.0);
    // `c` is CONST-tier (state-free, t-free): its instructions live in the
    // CONST section; the gather of `c` along j broadcasts over i.
    assert!(
        prog.n_const > 0,
        "const-tier observed lowered to CONST section"
    );
    assert!(
        prog.plans.iter().any(|p| p.mapped.iter().any(|m| !m)),
        "expected a broadcast axis in the c[j] gather over the [i,j] box"
    );
    // `s` reads state, so it is CONTINUOUS; it is 0-d ⇒ in the samples cone ⇒
    // exported (along with its dependency cone).
    assert!(
        prog.exports.iter().any(|(n, _)| n == "s"),
        "scalar observed `s` must be exported for the samples pass: {:?}",
        prog.exports
    );
}

/// A model with a construct the overlay cannot vectorize (an array-valued
/// `const` observed) becomes a FALLBACK rule; taped readers of the runtime
/// observed map and dy still match the interpreter bit for bit.
#[test]
fn ab_fallback_rule_interop() {
    let n = 3;
    let doc = json!({
        "esm": "0.8.0",
        "metadata": {"name": "tape_fallback"},
        "index_sets": {"c": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "psi": {"type": "state", "shape": ["c"]},
                "k": {"type": "observed", "shape": ["c"],
                      "expression": {"op": "const", "value": [1.0, 2.0, 3.0], "args": []}},
                "a": {"type": "observed", "shape": ["c"],
                      "expression": {"op": "+", "args": ["psi", "k"]}}
            },
            "equations": [
                {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                 "rhs": {"op": "-", "args": ["a"]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(
        !report.fallbacks.is_empty(),
        "the array-valued const must produce at least one fallback"
    );
    let nstates = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast = compiled.debug_new_scratch_taped();
    let mut fast_stats = RhsStats::default();
    for seed in 0..3u64 {
        let state = seeded_state(nstates, seed, -1.0, 1.0);
        for &t in &[0.0, 1.3] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            let mut dy = vec![0.0f64; nstates];
            run_reference(&prog, &compiled, &state, &param_vec, t, &mut dy);
            for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "seed {seed} t {t} dy[{k}]: {a:?} vs {b:?}"
                );
            }
            let mut dy_fast = vec![0.0f64; nstates];
            compiled.debug_eval_rhs_into(
                &state,
                t,
                &param_vec,
                &mut dy_fast,
                &mut fast,
                &mut fast_stats,
            );
            for (k, (a, b)) in dy_fast.iter().zip(dy_ref.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "seed {seed} t {t} dy[{k}] (FAST): {a:?} vs {b:?}"
                );
            }
        }
    }
    assert!(
        fast_stats.fallback_rules > 0,
        "the fast executor must have exercised the fallback arm"
    );
}

/// Scalar RHS rules (0-d states) through the scalar-`eval` mirror, including a
/// runtime scalar `ifelse` over `t`.
#[test]
fn ab_scalar_rules() {
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_scalar"},
        "models": {"M": {
            "variables": {
                "x": {"type": "state"},
                "y": {"type": "state"},
                "r": {"type": "parameter", "default": 0.5}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [{"op": "-", "args": ["r"]}, "x"]}},
                {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                 "rhs": {"op": "ifelse", "args": [
                     {"op": "<", "args": ["t", 1.0]},
                     {"op": "+", "args": ["x", "y", 0.1]},
                     {"op": "sin", "args": ["y"]}]}}
            ]
        }}
    });
    ab_check(doc, 0, -1.5, 1.5);
}

// ---------------------------------------------------------------------------
// Structural invariants.
// ---------------------------------------------------------------------------

/// Slab coloring invariants: dedicated storages are never shared; recycled
/// storages are only shared by slots with disjoint (or def-touching,
/// alias-safe) live intervals; every colored slot has storage.
#[test]
fn coloring_invariants() {
    let n = 8;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_coloring"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "aggregate", "args": [], "output_idx": ["i"],
                    "reduce": "+",
                    "ranges": {"i": [1, n], "k": [-1, 1]},
                    "expr": {"op": "*", "args": [
                        {"op": "ifelse", "args": [{"op": "==", "args": ["k", 0]}, -2, 1]},
                        {"op": "sin", "args": [idx("u", json!({"op": "+", "args": ["i", "k"]}))]}
                    ]}}))
            ]
        }}
    });
    let compiled = compile(doc);
    // The unfused program: this test pins the (shared) slab-coloring logic,
    // and needs enough surviving intermediates to actually recycle (the fused
    // program of this small fixture collapses to a couple of groups).
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), None);
    assert!(report.fallbacks.is_empty());

    // def / last-use per slot (linear order, re-defs count as uses).
    let mut def = vec![usize::MAX; prog.slots.len()];
    let mut last = vec![0usize; prog.slots.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        ins.for_each_def(&prog.fused, |o| {
            if def[o as usize] == usize::MAX {
                def[o as usize] = i;
            } else {
                last[o as usize] = last[o as usize].max(i);
            }
        });
        ins.for_each_read(&prog.dy_writes, &prog.fused, |s| {
            last[s as usize] = last[s as usize].max(i);
        });
    }
    // Group slots by storage.
    let mut by_storage: HashMap<u32, Vec<usize>> = HashMap::new();
    for (s, d) in prog.slots.iter().enumerate() {
        if def[s] != usize::MAX {
            assert_ne!(d.storage, u32::MAX, "defined slot {s} must be colored");
            by_storage.entry(d.storage).or_default().push(s);
        }
    }
    let mut recycled_any = false;
    for (st, slots) in by_storage {
        let sd = &prog.slab.storages[st as usize];
        if sd.dedicated {
            assert_eq!(slots.len(), 1, "dedicated storage {st} shared");
            continue;
        }
        if slots.len() > 1 {
            recycled_any = true;
        }
        // Pairwise: live intervals may only touch where one dies at the
        // other's def (alias-safe reuse).
        for (ai, &a) in slots.iter().enumerate() {
            for &b in &slots[ai + 1..] {
                let (a0, a1) = (def[a], last[a].max(def[a]));
                let (b0, b1) = (def[b], last[b].max(def[b]));
                let overlap = a0.max(b0) < a1.min(b1);
                assert!(
                    !overlap,
                    "storage {st}: slots {a} [{a0},{a1}] and {b} [{b0},{b1}] overlap"
                );
            }
        }
    }
    assert!(recycled_any, "the coloring must actually recycle something");
    // Slab totals agree with the storage list.
    let sum: usize = prog.slab.storages.iter().map(|s| s.elems).sum();
    assert_eq!(sum, prog.slab.total_elems);
}

/// Value numbering must collapse a subtree repeated within one scope to ONE
/// instruction sequence, and must NOT collapse across contraction tuples
/// (each tuple is a fresh scope with different bound `k`).
#[test]
fn value_numbering_scope_behaviour() {
    let n = 6;
    // d(u) repeated twice in one map body: lowered once.
    let d = json!({"op": "-", "args": [idx("u", json!("i")),
                                       idx("u", json!({"op": "-", "args": ["i", 1]}))]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_vn"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "*", "args": [d, d]})))
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty());
    assert!(
        report.vn_scope_hits + report.vn_hoist_hits >= 1,
        "the repeated subtree must hit the value numbering"
    );
    // Exactly one subtraction of the two gathers (plus none duplicated): count
    // Bin(Sub) instructions (plain or fused) — 1 for d (shared), not 2.
    let subs = prog
        .instrs
        .iter()
        .filter(|i| matches!(i, Instr::Bin { op, .. } if *op == super::super::BinCode::Sub))
        .count()
        + prog
            .fused
            .iter()
            .flat_map(|fs| fs.micro.iter())
            .filter(
                |m| matches!(m, MicroOp::Bin { op, .. } if *op == super::super::BinCode::Sub),
            )
            .count();
    assert_eq!(subs, 1, "repeated subtree must be lowered once");
}

/// The tape build must not perturb the production path: building a tape and
/// then evaluating the RHS gives the same bits as never building one.
#[test]
fn tape_build_is_side_effect_free() {
    let n = 6;
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_pure_build"},
        "models": {"M": {
            "variables": {"u": {"type": "state", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "*", "args": [2.0, idx("u", json!("i"))]})))
            ]
        }}
    });
    let compiled = compile(doc);
    let state = seeded_state(n as usize, 3, -1.0, 1.0);
    let (before, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let _ = compiled.build_tape(&HashSet::new());
    let (after, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    for (a, b) in before.iter().zip(after.iter()) {
        assert_eq!(a.to_bits(), b.to_bits());
    }
}

/// Sanity: the reference executor materializes exports as arrays the
/// interpreter would produce (0-d for scalars).
#[test]
fn exports_materialize_as_observed_arrays() {
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_export_shape"},
        "models": {"M": {
            "variables": {
                "x": {"type": "state"},
                "s": {"type": "observed", "expression": {"op": "*", "args": [2.0, "x"]}}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "neg", "args": ["s"]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = vec![1.5];
    let mut dy = vec![0.0f64];
    let run = run_reference(&prog, &compiled, &state, &param_vec, 0.0, &mut dy);
    assert_eq!(dy[0].to_bits(), (-3.0f64).to_bits());
    let s = run.obs.get("s").expect("s exported");
    assert_eq!(s.ndim(), 0);
    assert_eq!(s[ndarray::IxDyn(&[])].to_bits(), 3.0f64.to_bits());
    // The slot value backing the export is the scalar 3.0.
    let (_, slot) = prog.exports.iter().find(|(n, _)| n == "s").expect("export");
    match &run.slots[*slot as usize] {
        Some(RefVal::Scalar(v)) => assert_eq!(v.to_bits(), 3.0f64.to_bits()),
        other => panic!("unexpected export slot value {other:?}"),
    }
}

/// Forward prefix scans (inclusive `<=` and exclusive `<`), compiled as the
/// whole-plane running fold — bit-identical to the per-cell sweep the
/// production `eval_arrayop` runs for these.
#[test]
fn ab_prefix_scan_observeds() {
    let (ni, nk) = (4, 5);
    let scan_obs = |cmp: &str| {
        json!({"op": "aggregate", "args": [], "output_idx": ["i", "k"],
            "reduce": "+",
            "ranges": {"i": [1, ni], "k": [1, nk], "m": [1, nk]},
            "filter": {"op": cmp, "args": ["m", "k"]},
            "expr": {"op": "*", "args": [0.3, {"op": "index", "args": ["u", "i", "m"]}]}})
    };
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_scan"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i", "k"]},
                "P": {"type": "observed", "shape": ["i", "k"],
                      "expression": scan_obs("<=")},
                "Q": {"type": "observed", "shape": ["i", "k"],
                      "expression": scan_obs("<")}
            },
            "equations": [
                {
                    "lhs": {"op": "aggregate", "args": [], "output_idx": ["i", "k"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", "i", "k"]}], "wrt": "t"},
                            "ranges": {"i": [1, ni], "k": [1, nk]}},
                    "rhs": {"op": "aggregate", "args": [], "output_idx": ["i", "k"],
                            "ranges": {"i": [1, ni], "k": [1, nk]},
                            "expr": {"op": "+", "args": [
                                {"op": "*", "args": [-0.1,
                                    {"op": "index", "args": ["P", "i", "k"]}]},
                                {"op": "*", "args": [0.05,
                                    {"op": "index", "args": ["Q", "i", "k"]}]}
                            ]}}
                }
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    // The scan lowers to per-step Region writes along the scanned axis.
    assert!(
        prog.instrs
            .iter()
            .filter(|i| matches!(i, Instr::Region { .. }))
            .count()
            >= 2 * nk as usize,
        "expected one Region write per scan step"
    );
}

/// A declared observed whose whole body is a `makearray` (the boundary-
/// dispatch stencil shape every discretization template expands to), plus a
/// wholesale ELEMENTWISE observed combining a state array with a taped
/// observed array.
#[test]
fn ab_wholesale_makearray_and_elementwise_observeds() {
    let n = 8;
    let interior = json!({"op": "aggregate", "args": [], "output_idx": ["i"],
    "ranges": {"i": [2, n - 1]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["i", 1]})),
        idx("u", json!({"op": "-", "args": ["i", 1]}))
    ]}});
    let top = json!({"op": "aggregate", "args": [], "output_idx": ["i"],
        "ranges": {"i": [n, n]},
        "expr": {"op": "*", "args": [2.0, idx("u", json!("i"))]}});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_wholesale"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "g": {"type": "observed", "shape": ["i"],
                      "expression": {"op": "aggregate", "args": [], "output_idx": ["i"],
                          "ranges": {"i": [1, n]},
                          "expr": {"op": "sin", "args": [{"op": "*", "args": [0.5, "i"]}]}}},
                "q": {"type": "observed", "shape": ["i"],
                      "expression": {"op": "makearray", "args": [],
                          "regions": [[[2, n - 1]], [[1, 1]], [[n, n]]],
                          "values": [interior, 1.5, top]}},
                "h": {"type": "observed", "shape": ["i"],
                      "expression": {"op": "+", "args": [
                          {"op": "*", "args": [2.0, "u"]}, "g", "q"]}}
            },
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "neg", "args": [
                    {"op": "index", "args": ["h", "i"]}]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    // `g` is state-free — its instructions must land in the CONST section.
    assert!(prog.n_const > 0);
}

/// End-to-end A/B against a real model file (opt-in): set `TAPE_AB_MODEL` to
/// an .esm path (e.g. simpleclimate.esm) and optionally `TAPE_AB_MP` to
/// `NX=12,NY=7,NZ=7`. Builds the tape, obtains the model's own u0 through a
/// zero-length solve, and asserts bitwise dy equality at u0 and at perturbed
/// states.
#[test]
fn ab_model_file_if_available() {
    let Ok(path) = std::env::var("TAPE_AB_MODEL") else {
        return;
    };
    let mut mp: std::collections::BTreeMap<String, i64> = Default::default();
    if let Ok(spec) = std::env::var("TAPE_AB_MP") {
        for kv in spec.split(',') {
            let (k, v) = kv.split_once('=').expect("KEY=VALUE");
            mp.insert(k.to_string(), v.parse().expect("integer"));
        }
    }
    let file =
        crate::load_path_with_options(std::path::Path::new(&path), &mp).expect("model loads");
    let seed_sol = crate::simulate::simulate(
        &file,
        (0.0, 1.0),
        &HashMap::new(),
        &HashMap::new(),
        &crate::simulate::SimulateOptions {
            solver: crate::simulate::SolverChoice::Erk,
            abstol: 1e-8,
            reltol: 1e-6,
            output_times: Some(vec![0.0]),
            ..Default::default()
        },
    )
    .expect("u0 seed solve");
    let compiled = ArrayCompiled::from_file(&file).expect("model compiles");
    let n = compiled.state_variable_names().len();
    let u0: Vec<f64> = seed_sol.state.iter().take(n).map(|row| row[0]).collect();

    let (prog, report) = compiled.build_tape(&HashSet::new());
    eprintln!("{report}");
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);

    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast = compiled.debug_new_scratch_taped();
    let mut fast_stats = RhsStats::default();
    for seed in 0..3u64 {
        // Multiplicative perturbation keeps positive fields positive.
        let noise = seeded_state(n, seed, -0.01, 0.01);
        let state: Vec<f64> = u0.iter().zip(&noise).map(|(u, e)| u * (1.0 + e)).collect();
        for &t in &[0.0, 1234.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            let mut dy = vec![0.0f64; n];
            run_reference(&prog, &compiled, &state, &param_vec, t, &mut dy);
            let mut diverged = 0usize;
            for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                if a.to_bits() != b.to_bits() {
                    if diverged < 8 {
                        eprintln!("dy[{k}]: tape {a:e} vs interpreter {b:e}");
                    }
                    diverged += 1;
                }
            }
            assert_eq!(diverged, 0, "seed {seed} t {t}: {diverged} slots diverged");
            let mut dy_fast = vec![0.0f64; n];
            compiled.debug_eval_rhs_into(
                &state,
                t,
                &param_vec,
                &mut dy_fast,
                &mut fast,
                &mut fast_stats,
            );
            let mut diverged = 0usize;
            for (k, (a, b)) in dy_fast.iter().zip(dy_ref.iter()).enumerate() {
                if a.to_bits() != b.to_bits() {
                    if diverged < 8 {
                        eprintln!("dy[{k}] (FAST): tape {a:e} vs interpreter {b:e}");
                    }
                    diverged += 1;
                }
            }
            assert_eq!(
                diverged, 0,
                "seed {seed} t {t}: {diverged} slots diverged (FAST exec)"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Step 4: kernel fusion.
// ---------------------------------------------------------------------------

/// Shifted-read gather folding, all three fold shapes at once on a 2-D box:
/// a periodic WRAP along the leading axis (two-segment roll), a Dirichlet
/// GHOST-edge shift (uncovered edge rows read `+0.0`), and a LINEAR
/// level-slice read (constant element stride from a deeper box). The A/B
/// harness proves byte equality of the fused program (shifted reads) against
/// the unfused program (materialized gathers) and the legacy interpreter.
#[test]
fn ab_shifted_read_folding_wrap_ghost_linear() {
    let (ni, nj) = (8, 6);
    let idx2 = |var: &str, i: serde_json::Value, j: serde_json::Value| {
        json!({"op": "index", "args": [var, i, j]})
    };
    // Wrap Laplacian along i on u[i,j]; ghost Laplacian along i on v[i,j];
    // plus a level-slice coupling w[i,3] broadcast down the j axis via a
    // 1-D observed.
    let lap_wrap = json!({"op": "+", "args": [
        idx2("u", wrap(json!({"op": "-", "args": ["i", 1]}), 1, ni), json!("j")),
        {"op": "*", "args": [-2.0, idx2("u", json!("i"), json!("j"))]},
        idx2("u", wrap(json!({"op": "+", "args": ["i", 1]}), 1, ni), json!("j"))
    ]});
    let lap_ghost = json!({"op": "+", "args": [
        idx2("v", json!({"op": "-", "args": ["i", 1]}), json!("j")),
        {"op": "*", "args": [-2.0, idx2("v", json!("i"), json!("j"))]},
        idx2("v", json!({"op": "+", "args": ["i", 1]}), json!("j"))
    ]});
    let d2 = |var: &str, rhs: serde_json::Value| {
        json!({
            "lhs": {"op": "aggregate", "args": [], "output_idx": ["i", "j"],
                    "expr": {"op": "D", "args": [
                        {"op": "index", "args": [var, "i", "j"]}], "wrt": "t"},
                    "ranges": {"i": [1, ni], "j": [1, nj]}},
            "rhs": rhs
        })
    };
    let agg2 = |body: serde_json::Value| {
        json!({"op": "aggregate", "args": [], "output_idx": ["i", "j"],
               "ranges": {"i": [1, ni], "j": [1, nj]}, "expr": body})
    };
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_fold"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i", "j"]},
                "v": {"type": "state", "shape": ["i", "j"]},
                "w": {"type": "state", "shape": ["i", "j"]},
                // s[i] = 0.5 * w[i, 3]: a linear (strided) slice read.
                "s": {"type": "observed", "shape": ["i"],
                      "expression": {"op": "aggregate", "args": [], "output_idx": ["i"],
                          "ranges": {"i": [1, ni]},
                          "expr": {"op": "*", "args": [0.5,
                              {"op": "index", "args": ["w", "i", 3]}]}}}
            },
            "equations": [
                d2("u", agg2(json!({"op": "*", "args": [0.25, lap_wrap]}))),
                d2("v", agg2(json!({"op": "*", "args": [0.25, lap_ghost]}))),
                d2("w", agg2(json!({"op": "*", "args": [
                    {"op": "index", "args": ["s", "i"]},
                    {"op": "index", "args": ["w", "i", "j"]}
                ]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    // Folding happened: fewer materialized gathers than plans, and at least
    // one group carries a wrap (multi-run), a ghost run, and a strided
    // (linear) input.
    assert!(
        prog.fuse_stats.n_gathers_folded >= 4,
        "expected the stencil gathers to fold: {:?}",
        prog.fuse_stats
    );
    let any_multi_run = prog.fused.iter().any(|f| f.runs.len() > 1);
    let any_ghost = prog
        .fused
        .iter()
        .flat_map(|f| f.runs.iter())
        .any(|r| r.in_off.iter().any(|&o| o == GHOST_OFF));
    let any_strided = prog
        .fused
        .iter()
        .flat_map(|f| f.inputs.iter())
        .any(|i| i.shifted_ix.is_some() && i.elem_stride > 1);
    assert!(any_multi_run, "wrap fold must produce a multi-run schedule");
    assert!(any_ghost, "ghost-edge fold must produce a ghost run");
    assert!(any_strided, "level-slice fold must produce a strided input");
}

/// Step 4 export demotion: with no fallback rules and no check mode, the
/// `Export` publish memcpys are skipped (nothing can read them); forcing
/// them back on (the check-mode/diagnostic path) publishes the same values —
/// and `dy` is bit-identical either way.
#[test]
fn export_demotion_skips_unread_publishes() {
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_export_demote"},
        "models": {"M": {
            "variables": {
                "x": {"type": "state"},
                "s": {"type": "observed", "expression": {"op": "*", "args": [2.0, "x"]}}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "neg", "args": ["s"]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    assert!(
        prog.exports.iter().any(|(n, _)| n == "s"),
        "fixture must export `s`"
    );
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = vec![1.5f64];

    let run_call = |ctx: &mut super::exec::TapeCtx, dy: &mut [f64]| {
        let mut stats = RhsStats::default();
        super::exec::run_tape_call(
            ctx,
            &compiled.rhs_rules,
            &compiled.var_shapes,
            &compiled.param_names,
            &super::super::ArrMap::default(),
            &compiled.forcing,
            &state,
            &param_vec,
            0.0,
            dy,
            &mut stats,
        );
    };

    // Demoted (production default for a no-fallback model outside check
    // mode): the export target array stays at its zero prealloc.
    let mut ctx = super::exec::TapeCtx::new(
        std::rc::Rc::new(prog),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    if std::env::var("ESS_TAPE_CHECK").is_ok() {
        return; // check mode legitimately keeps exports on
    }
    let mut dy = vec![0.0f64; 1];
    run_call(&mut ctx, &mut dy);
    assert_eq!(dy[0].to_bits(), (-3.0f64).to_bits());
    let s = ctx.exec.obs.get("s").expect("export array preallocated");
    assert_eq!(
        s[ndarray::IxDyn(&[])].to_bits(),
        0.0f64.to_bits(),
        "demoted export must not publish"
    );

    // Re-enabled (fallbacks present / ESS_TAPE_CHECK / explicit request):
    // the same call publishes the computed value, and dy is unchanged.
    ctx.set_exports_active(true);
    let mut dy2 = vec![0.0f64; 1];
    run_call(&mut ctx, &mut dy2);
    assert_eq!(dy2[0].to_bits(), dy[0].to_bits());
    let s = ctx.exec.obs.get("s").expect("export array");
    assert_eq!(
        s[ndarray::IxDyn(&[])].to_bits(),
        3.0f64.to_bits(),
        "active export must publish the slot value"
    );
}

/// Step 4b superop composition: arith three-op chains must merge into `Bin3`
/// and the extended (mask / clamp) pairs into `Bin2`, with bitwise `dy`
/// equality across fused/unfused programs on BOTH executors (the fixture
/// A/B) — the superops apply the identical scalar kernels in the identical
/// order, so no bit may move.
#[test]
fn ab_superop_bin3_and_extended_pairs() {
    let n = 9;
    let u = idx("u", json!("i"));
    let v = idx("v", json!("i"));
    // ((u * 2.5 + v) * u - 1.5) / (v + 3.0): a four-op arith chain plus a
    // divisor — long enough that a Bin3 must form.
    let chain = json!({"op": "/", "args": [
        {"op": "-", "args": [
            {"op": "*", "args": [
                {"op": "+", "args": [{"op": "*", "args": [u.clone(), 2.5]}, v.clone()]},
                u.clone()
            ]},
            1.5
        ]},
        {"op": "+", "args": [v.clone(), 3.0]}
    ]});
    // ifelse(u*v > 1, max(min(u, v), 0.1), u): the multiply-into-mask
    // (Mul,Gt) and clamp (Min,Max) extended pairs feeding a Select.
    let limiter = json!({"op": "ifelse", "args": [
        {"op": ">", "args": [{"op": "*", "args": [u.clone(), v.clone()]}, 1.0]},
        {"op": "max", "args": [{"op": "min", "args": [u.clone(), v.clone()]}, 0.1]},
        u.clone()
    ]});
    let doc = json!({
        "esm": "0.1.0",
        "metadata": {"name": "tape_superops"},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "v": {"type": "state", "shape": ["i"]}
            },
            "equations": [
                d_eq("u", n, agg(n, chain)),
                d_eq("v", n, agg(n, limiter))
            ]
        }}
    });
    // Default configuration (ext pairs on, Bin3 off) through the standard
    // fixture A/B: fused + unfused × reference + fast executors.
    let prog = ab_check(doc.clone(), 0, -3.0, 3.0);
    let has_bin3 = |p: &TapeProgram| {
        p.fused
            .iter()
            .any(|f| f.micro.iter().any(|m| matches!(m, MicroOp::Bin3 { .. })))
    };
    let has_ext_bin2 = prog.fused.iter().any(|f| {
        f.micro.iter().any(|m| {
            matches!(m, MicroOp::Bin2 { op1, op2, .. }
                if matches!((op1, op2),
                    (crate::simulate_array::BinCode::Mul, crate::simulate_array::BinCode::Gt)
                    | (crate::simulate_array::BinCode::Min, crate::simulate_array::BinCode::Max)))
        })
    });
    assert!(
        has_ext_bin2,
        "expected an extended-pair Bin2 ((Mul,Gt) or (Min,Max)) in the fused program"
    );
    assert!(
        !has_bin3(&prog),
        "Bin3 must stay off in the default configuration"
    );

    // The Bin3 arm (`all_superops_cfg`, the `ESS_TAPE_BIN3=1` build): the
    // three-op chain must merge, splat registers must be provisioned, and
    // BOTH executors must stay bitwise equal to the production interpreter.
    let compiled = compile(doc);
    let (prog3, _) = compiled.build_tape_opts(&HashSet::new(), Some(all_superops_cfg()));
    assert!(has_bin3(&prog3), "expected a Bin3 superop with bin3 enabled");
    for f in &prog3.fused {
        let has3 = f.micro.iter().any(|m| matches!(m, MicroOp::Bin3 { .. }));
        if has3 {
            assert_eq!(f.n_splat_regs as usize, f.scalars.len() + 1);
        } else {
            assert_eq!(f.n_splat_regs, 0);
        }
    }
    let n_state = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast3 = super::super::RhsScratch::new(&compiled.var_shapes);
    fast3.install_tape(
        std::rc::Rc::new(compiled.build_tape_opts(&HashSet::new(), Some(all_superops_cfg())).0),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let mut stats = RhsStats::default();
    for seed in 0..4u64 {
        let state = seeded_state(n_state, seed, -3.0, 3.0);
        for &t in &[0.0, 0.37, 2.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            let mut dy = vec![0.0f64; n_state];
            run_reference(&prog3, &compiled, &state, &param_vec, t, &mut dy);
            for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "seed {seed} t {t}: dy[{k}] diverged: bin3 tape-ref vs interpreter"
                );
            }
            let mut dy_fast = vec![0.0f64; n_state];
            compiled.debug_eval_rhs_into(
                &state,
                t,
                &param_vec,
                &mut dy_fast,
                &mut fast3,
                &mut stats,
            );
            for (k, (a, b)) in dy_fast.iter().zip(dy_ref.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "seed {seed} t {t}: dy[{k}] diverged: bin3 FAST exec vs interpreter"
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Issue #101 — a ONE-operand `broadcast` must apply its `fn`.
// ---------------------------------------------------------------------------

/// A method-of-lines model whose tendency is `rhs`, over an `[i]`-shaped state
/// and an `[i]`-shaped observed `s = 0.5 * u` for `rhs` to consume. Array-shaped
/// on purpose: a scalar model never engages the whole-array overlay, and the
/// whole point of #101 is that the three evaluators disagreed.
fn bcast_doc(name: &str, n: i64, rhs: serde_json::Value) -> serde_json::Value {
    json!({
        "esm": "0.1.0",
        "metadata": {"name": name},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "shape": ["i"]},
                "s": {"type": "observed", "shape": ["i"],
                      "expression": agg(n, json!({"op": "*", "args": [0.5, idx("u", json!("i"))]}))}
            },
            "equations": [d_eq("u", n, agg(n, rhs))]
        }}
    })
}

/// `dy` from all three evaluation paths: the per-cell oracle (`force_scalar`),
/// the whole-array vectorized overlay, and the tape (reference executor over
/// the FUSED program). Returns them in that order.
fn dy_three_ways(doc: serde_json::Value, state: &[f64]) -> [Vec<f64>; 3] {
    let compiled = compile(doc);
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let (dy_oracle, _) = compiled.debug_eval_rhs(state, 0.0, &params, true);
    let (dy_vec, _) = compiled.debug_eval_rhs(state, 0.0, &params, false);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(
        report.fallbacks.is_empty(),
        "the tape must lower this model with no fallback, else the tape path is untested: {:?}",
        report.fallbacks
    );
    let mut dy_tape = vec![0.0f64; state.len()];
    run_reference(&prog, &compiled, state, &param_vec, 0.0, &mut dy_tape);
    [dy_oracle, dy_vec, dy_tape]
}

fn assert_bits_eq(a: &[f64], b: &[f64], what: &str) {
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

/// The regression itself. For each unary scalar operator `F`, the tendency
/// `broadcast(fn = F, [s])` must be BIT-IDENTICAL to the bare `F(s)` — on the
/// per-cell oracle, on the vectorized overlay, and on the tape.
///
/// Before the fix all three folded `args` through the BINARY kernel table, so a
/// single-element fold degenerated to the identity and every one of these
/// returned `s` unchanged (issue #101).
#[test]
fn unary_broadcast_matches_the_bare_node_on_all_three_paths() {
    let n = 6i64;
    // `s = 0.5 * u` and `u ∈ [0.25, 3)`, so every operand is inside the domain
    // of `log`/`sqrt` and no NaN can mask a divergence.
    let state = seeded_state(n as usize, 11, 0.25, 3.0);
    // `abs` is deliberately absent: the operands below are all positive, so
    // `abs` would be the identity on them and the vacuity guard would fire.
    for f in [
        "-", "neg", "log", "exp", "sqrt", "sin", "cos", "tanh", "floor", "not",
    ] {
        let operand = idx("s", json!("i"));
        let bare = json!({"op": f, "args": [operand]});
        let bcast = json!({"op": "broadcast", "fn": f, "args": [operand]});

        let [o_bare, v_bare, t_bare] = dy_three_ways(bcast_doc("bare", n, bare), &state);
        let [o_bc, v_bc, t_bc] = dy_three_ways(bcast_doc("bcast", n, bcast), &state);

        // Each path agrees with itself across the two spellings …
        assert_bits_eq(&o_bc, &o_bare, &format!("fn `{f}`: oracle"));
        assert_bits_eq(&v_bc, &v_bare, &format!("fn `{f}`: vectorized overlay"));
        assert_bits_eq(&t_bc, &t_bare, &format!("fn `{f}`: tape"));
        // … and the three paths agree with each other.
        assert_bits_eq(&v_bc, &o_bc, &format!("fn `{f}`: overlay vs oracle"));
        assert_bits_eq(&t_bc, &o_bc, &format!("fn `{f}`: tape vs oracle"));

        // Guard against a vacuous pass: `F` must actually CHANGE the operand,
        // otherwise "broadcast == bare" would hold even with the bug present.
        let [o_id, _, _] = dy_three_ways(bcast_doc("id", n, idx("s", json!("i"))), &state);
        assert!(
            o_bare
                .iter()
                .zip(o_id.iter())
                .any(|(a, b)| a.to_bits() != b.to_bits()),
            "fn `{f}` is the identity on this state — the test would pass vacuously"
        );
    }
}

/// The n-ary and binary spellings keep folding exactly as before: a 1-operand
/// `broadcast(fn = "+")` is the identity because `+(x)` IS `x`, and 2- and
/// 3-operand folds are unchanged. This is the arity rule stated in
/// `op_registry::check_broadcast_fn` — legal iff the bare node is legal.
#[test]
fn n_ary_broadcast_folds_are_unchanged() {
    let n = 6i64;
    let state = seeded_state(n as usize, 7, 0.25, 3.0);
    let s = || idx("s", json!("i"));
    let cases: Vec<(&str, serde_json::Value, serde_json::Value)> = vec![
        // (label, broadcast spelling, equivalent bare spelling)
        (
            "unary +",
            json!({"op": "broadcast", "fn": "+", "args": [s()]}),
            json!({"op": "+", "args": [s()]}),
        ),
        (
            "binary -",
            json!({"op": "broadcast", "fn": "-", "args": [s(), 0.25]}),
            json!({"op": "-", "args": [s(), 0.25]}),
        ),
        (
            "ternary *",
            json!({"op": "broadcast", "fn": "*", "args": [s(), 2.0, s()]}),
            json!({"op": "*", "args": [s(), 2.0, s()]}),
        ),
        (
            "binary min",
            json!({"op": "broadcast", "fn": "min", "args": [s(), 1.0]}),
            json!({"op": "min", "args": [s(), 1.0]}),
        ),
        (
            "binary atan2",
            json!({"op": "broadcast", "fn": "atan2", "args": [s(), 2.0]}),
            json!({"op": "atan2", "args": [s(), 2.0]}),
        ),
        (
            "ternary ifelse",
            json!({"op": "broadcast", "fn": "ifelse",
                   "args": [{"op": ">", "args": [s(), 0.5]}, s(), 0.125]}),
            json!({"op": "ifelse",
                   "args": [{"op": ">", "args": [s(), 0.5]}, s(), 0.125]}),
        ),
    ];
    for (label, bcast, bare) in cases {
        let [o_bare, v_bare, t_bare] = dy_three_ways(bcast_doc("bare", n, bare), &state);
        let [o_bc, v_bc, t_bc] = dy_three_ways(bcast_doc("bcast", n, bcast), &state);
        assert_bits_eq(&o_bc, &o_bare, &format!("{label}: oracle"));
        assert_bits_eq(&v_bc, &v_bare, &format!("{label}: vectorized overlay"));
        assert_bits_eq(&t_bc, &t_bare, &format!("{label}: tape"));
    }
}

/// The numbers from the issue report, as a closed-form check rather than a
/// cross-spelling one: `s = 0.5 * u`, so `D(u) = broadcast(fn="-", [s])` is
/// `-0.5 * u` — and NOT `+0.5 * u`, which is what the fold-degeneracy produced.
#[test]
fn unary_broadcast_minus_negates() {
    let n = 3i64;
    let state = vec![1.0, 2.0, 4.0];
    let rhs = json!({"op": "broadcast", "fn": "-", "args": [idx("s", json!("i"))]});
    for dy in dy_three_ways(bcast_doc("neg_check", n, rhs), &state) {
        assert_bits_eq(&dy, &[-0.5, -1.0, -2.0], "broadcast(fn=\"-\") must negate");
    }
}
