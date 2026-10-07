//! A/B verification of the tape: build the tape for fixture models, run BOTH
//! executors — the slow reference executor ([`super::refexec`], which pins the
//! LOWERING) and the production fast executor ([`super::exec`], Step 3b,
//! reached through a taped scratch + `debug_eval_rhs_into`) — and assert
//! **bitwise** equality of `dy` against `evaluate_rhs_with_scratch`, the full
//! legacy production path (vectorized overlay + runtime CSE), at several
//! random-but-seeded states and times. The fast-executor arm reuses ONE warm
//! scratch across every state/time, so slab recycling, CONST-section
//! retention and the section re-run discipline are all exercised.

use super::super::{ArrayCompiled, DimU, RhsStats};
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
    crate::parse::load_string(&doc.to_string()).expect("fixture document loads")
}

pub(super) fn compile(doc: serde_json::Value) -> ArrayCompiled {
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

/// Build BOTH tapes (fused and unfused), check the expected fallback count,
/// and assert bitwise `dy` equality against the production interpreter over
/// several seeded states and times — for BOTH executors on BOTH programs:
/// the reference executor (fresh run per state) and the Step 3b fast
/// executor (one warm taped scratch per program across all of them). Returns
/// the FUSED program.
pub(super) fn ab_check(
    doc: serde_json::Value,
    expect_fallbacks: usize,
    lo: f64,
    hi: f64,
) -> TapeProgram {
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
    // The fused program as lowered, without the state-layout alignment
    // (`layout`), which `prog` may carry: both storage orders must agree.
    let rm_build = || {
        compiled
            .build_tape_layout(&HashSet::new(), Some(default_cfg()), false)
            .0
    };
    let prog_rm = rm_build();
    assert!(!prog_rm.col_major);
    let mut fast_rm = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_rm.install_tape(
        std::rc::Rc::new(rm_build()),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let mut fast_stats = RhsStats::default();
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, lo, hi);
        for &t in &[0.0, 0.37, 2.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
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
        }
    }
    assert!(
        fast_stats.taped_rules > 0,
        "the fast executor must have run"
    );
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
        "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "expr": {"op": "D", "args": [{"op": "index", "args": [var, "i"]}], "wrt": "t"},
                "ranges": {"i": [1, n]}},
        "rhs": rhs
    })
}

fn agg(n: i64, body: serde_json::Value) -> serde_json::Value {
    json!({"op": "faq", "args": [], "output_idx": ["i"],
           "ranges": {"i": [1, n]}, "expr": body})
}

fn idx(var: &str, e: serde_json::Value) -> serde_json::Value {
    json!({"op": "index", "args": [var, e]})
}

/// Evaluate through the Step 3b FAST executor (warm taped scratch) and assert
/// bitwise `dy` equality against `dy_ref`.
/// A causal self-read of `var` at `pos` that the tape does NOT lower, so the
/// recurrence around it stays a fallback rule: the read sits inside an
/// array-valued part of the cell body (`(j ↦ var[pos])[1]`, a one-element
/// nested `faq`), and the tape's sweep evaluates a self-read one scalar cell
/// at a time. Its value is the plain self-read's, bit for bit.
fn untaped_self_read(var: &str, pos: serde_json::Value) -> serde_json::Value {
    json!({"op": "index", "args": [
        {"op": "faq", "args": [], "output_idx": ["j"], "ranges": {"j": [1, 1]},
         "expr": idx(var, pos)},
        1]})
}

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
        "esm": "1.1.0",
        "metadata": {"name": "tape_stencil"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "v": {"type": "unknown", "shape": ["i"]}
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
    let inner = json!({"op": "faq", "args": [], "output_idx": ["j"],
    "ranges": {"j": [1, n]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["j", 1]})),
        idx("u", json!("j"))
    ]}});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_nested"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
    let inner = json!({"op": "faq", "args": [], "output_idx": ["i"],
    "ranges": {"i": [1, n]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["i", 1]})),
        idx("u", json!("i"))
    ]}});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_nested_shadow"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
        json!({"op": "faq", "args": [], "output_idx": ["i"],
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_nested_makearray_agg"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
    let inner = json!({"op": "faq", "args": [], "output_idx": ["j"],
    "ranges": {"j": [1, n]},
    "expr": {"op": "*", "args": [idx("u", json!("j")), "i"]}});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_nested_capture"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "v": {"type": "unknown", "shape": ["i"]}
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_makearray"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, agg(n, json!({"op": "index", "args": [ma, "i"]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(prog.regions.len(), 3, "three makearray regions lowered");
}

/// Static einsum contraction with the `ifelse(k==0,…)` weight idiom — the
/// per-tuple fold in the per-cell oracle's tuple order (last name fastest).
#[test]
fn ab_contraction_weights() {
    let n = 8;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_einsum"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "faq", "args": [], "output_idx": ["i"],
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_filter"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "faq", "args": [], "output_idx": ["i"],
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_shortcircuit"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_select_nan"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_signed_zero"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_fold_order"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_subblock"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]}
                            ], "wrt": "t"},
                            "ranges": {"i": [1, 7]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_obs"},
        "models": {"M": {
            "variables": {
                "w": {"type": "unknown", "shape": ["i", "j"]},
                "x": {"type": "unknown"},
                "c": {"type": "unknown", "shape": ["j"]},
                "s": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "c", "rhs": {"op": "faq", "args": [], "output_idx": ["j"],
                          "ranges": {"j": [1, nj]},
                          "expr": {"op": "cos", "args": [{"op": "*", "args": [0.3, "j"]}]}}},
                {"lhs": "s", "rhs": {"op": "*", "args": [2.0, "x"]}},
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [{"op": "neg", "args": ["s"]}, "x"]}},
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["w", "i", "j"]}], "wrt": "t"},
                            "ranges": {"i": [1, ni], "j": [1, nj]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
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

/// A model with a construct the tape cannot lower (a recurrence whose
/// self-read sits in an array-valued part of its body) becomes a FALLBACK
/// rule; taped readers of the runtime observed map and dy still match the
/// interpreter bit for bit.
#[test]
fn ab_fallback_rule_interop() {
    let n = 3;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_fallback"},
        "index_sets": {"c": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "psi": {"type": "unknown", "shape": ["c"]},
                "k": {"type": "unknown", "shape": ["c"]},
                "a": {"type": "unknown", "shape": ["c"]}
            },
            "equations": [
                // A recurrence the tape does not lower
                // ([`untaped_self_read`]): a fallback rule in the middle of a
                // taped program.
                {"lhs": "k", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "ifelse", "args": [
                        {"op": "<=", "args": ["i", 1]},
                        1.0,
                        {"op": "*", "args": [
                            untaped_self_read("k", json!({"op": "-", "args": ["i", 1]})), 2.0]}
                    ]}}},
                {"lhs": "a", "rhs": {"op": "+", "args": ["psi", "k"]}},
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
        "the untaped recurrence must produce at least one fallback"
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_scalar"},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown"},
                "y": {"type": "unknown"},
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

/// Many scalar boxes of one mechanism (the `scalar_chemistry` shape): the
/// rerolling pass shares each rate across the equations that read it and
/// runs the boxes as the lanes of one lane program, bit-identical to the
/// interpreter. Box `k` reads its own `kb_k` (a parameter input) and the
/// shared `k1`, `t` and literals (scalar operands). The off-grid state `a_1x`
/// sits between two boxes' `a` in the state order, so `a`'s lanes are not
/// evenly spaced and go through a position table; an equation written another
/// way runs in a one-lane block.
#[test]
fn ab_rerolled_scalar_boxes() {
    let boxes = [1, 2, 3, 5, 8, 13, 21];
    let mut vars = serde_json::Map::new();
    let mut eqs: Vec<serde_json::Value> = Vec::new();
    vars.insert("k1".into(), json!({"type": "parameter", "default": 0.7}));
    for b in boxes {
        let (a, c, kb) = (format!("a_{b}"), format!("c_{b}"), format!("kb_{b}"));
        vars.insert(a.clone(), json!({"type": "unknown"}));
        vars.insert(c.clone(), json!({"type": "unknown"}));
        vars.insert(
            kb.clone(),
            json!({"type": "parameter", "default": 0.1 * b as f64}),
        );
        // r = k1 * a * c, read by both equations.
        let r = json!({"op": "*", "args": ["k1", a, c]});
        eqs.push(json!({"lhs": {"op": "D", "args": [a], "wrt": "t"},
            "rhs": {"op": "+", "args": [
                {"op": "-", "args": [r]},
                {"op": "*", "args": [kb, {"op": "exp", "args": [{"op": "-", "args": [c]}]}]},
                {"op": "*", "args": [0.25, "t"]}]}}));
        eqs.push(json!({"lhs": {"op": "D", "args": [c], "wrt": "t"},
            "rhs": {"op": "-", "args": [r, {"op": "max", "args": [c, 0.5]}]}}));
    }
    vars.insert("a_1x".into(), json!({"type": "unknown"}));
    eqs.push(json!({"lhs": {"op": "D", "args": ["a_1x"], "wrt": "t"},
        "rhs": {"op": "*", "args": ["a_1x", "a_1x", "k1"]}}));
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_reroll"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    });
    let prog = ab_check(doc, 0, 0.1, 2.0);
    let lanes: Vec<&LaneSpec> = prog
        .instrs
        .iter()
        .filter_map(|i| match i {
            Instr::Lanes { spec } => Some(&prog.lanes[*spec as usize]),
            _ => None,
        })
        .collect();
    // The boxes' lane program, and one one-lane block holding the rest of
    // the run (`0.25 * t` and the off-grid equation).
    assert_eq!(lanes.len(), 2, "{:?}", prog.instrs);
    let (blocks, multi): (Vec<&LaneSpec>, Vec<&LaneSpec>) =
        lanes.into_iter().partition(|ls| ls.lanes == 1);
    assert_eq!((blocks.len(), multi.len()), (1, 1));
    assert!(blocks[0].inputs.is_empty());
    // It writes the off-grid derivative, and `0.25 * t` back to its slot for
    // the lanes to read.
    let dsts: Vec<bool> = blocks[0]
        .writes
        .iter()
        .map(|w| matches!(w.dst, LaneDst::Dy(_)))
        .collect();
    assert_eq!(dsts, vec![true, false], "{:?}", blocks[0].writes);
    let ls = multi[0];
    assert_eq!(ls.lanes as usize, boxes.len());
    assert_eq!(ls.writes.len(), 2);
    // The rate is computed once per lane: two `*` for r, `-r`, `-c`, `exp`,
    // `* kb`, two `+`, `max`, the final `-`. `0.25 * t` reads no box, so it
    // runs once outside and every lane reads it.
    assert_eq!(ls.micro.len(), 10, "{:?}", ls.micro);
    let kinds: Vec<LaneKind> = ls.inputs.iter().map(|i| i.kind).collect();
    assert_eq!(
        kinds,
        vec![LaneKind::State, LaneKind::State, LaneKind::Param],
        "{:?}",
        ls.inputs
    );
    assert!(
        ls.inputs.iter().any(|i| matches!(i.ix, LaneIx::Table(_))),
        "the off-grid state breaks one input's spacing"
    );
    assert!(
        !prog
            .instrs
            .iter()
            .any(|i| matches!(i, Instr::DyWrite { .. })),
        "every derivative is written by a lane program"
    );
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_coloring"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [
                d_eq("u", n, json!({"op": "faq", "args": [], "output_idx": ["i"],
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
        ins.for_each_def(&prog.tables(), |o| {
            if def[o as usize] == usize::MAX {
                def[o as usize] = i;
            } else {
                last[o as usize] = last[o as usize].max(i);
            }
        });
        ins.for_each_read(&prog.tables(), |s| {
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_vn"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
            .filter(|m| matches!(m, MicroOp::Bin { op, .. } if *op == super::super::BinCode::Sub))
            .count();
    assert_eq!(subs, 1, "repeated subtree must be lowered once");
}

/// The tape build must not perturb the production path: building a tape and
/// then evaluating the RHS gives the same bits as never building one.
#[test]
fn tape_build_is_side_effect_free() {
    let n = 6;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_pure_build"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_export_shape"},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown"},
                "s": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "s", "rhs": {"op": "*", "args": [2.0, "x"]}},
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
/// production `eval_faq` runs for these.
#[test]
fn ab_prefix_scan_observeds() {
    let (ni, nk) = (4, 5);
    let scan_obs = |cmp: &str| {
        json!({"op": "faq", "args": [], "output_idx": ["i", "k"],
            "reduce": "+",
            "ranges": {"i": [1, ni], "k": [1, nk], "m": [1, nk]},
            "filter": {"op": cmp, "args": ["m", "k"]},
            "expr": {"op": "*", "args": [0.3, {"op": "index", "args": ["u", "i", "m"]}]}})
    };
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_scan"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i", "k"]},
                "P": {"type": "unknown", "shape": ["i", "k"]},
                "Q": {"type": "unknown", "shape": ["i", "k"]}
            },
            "equations": [
                {"lhs": "P", "rhs": scan_obs("<=")},
                {"lhs": "Q", "rhs": scan_obs("<")},
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", "i", "k"]}], "wrt": "t"},
                            "ranges": {"i": [1, ni], "k": [1, nk]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
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
    // Each scan is ONE `Scan` over its whole box (an instruction, or a
    // micro-op of the fused group that computes its source), with no
    // per-step writes.
    assert_eq!(
        opcount(&prog, "Scan") + scan_micro_ops(&prog),
        2,
        "one Scan per scan observed"
    );
    assert_eq!(opcount(&prog, "Region"), 0, "no per-step region writes");
}

/// Absorbed scans (`MicroOp::Scan`) over every fused group.
fn scan_micro_ops(prog: &TapeProgram) -> usize {
    prog.fused
        .iter()
        .flat_map(|f| &f.micro)
        .filter(|m| matches!(m, MicroOp::Scan { .. }))
        .count()
}

/// A scan along the last axis joins the fused group that computes its
/// source, and the scan's readers join it too (the identity read of the
/// scanned observed and its export no longer split the group). Rows longer
/// than the executor's chunk, and a box whose chunks start mid-row, exercise
/// the carry from one chunk to the next and the restart at each row.
#[test]
fn ab_scan_absorbed_into_its_group() {
    let (ni, nk) = (3, 1100);
    let scan_obs = |cmp: &str| {
        json!({"op": "faq", "args": [], "output_idx": ["i", "k"],
            "reduce": "+",
            "ranges": {"i": [1, ni], "k": [1, nk], "m": [1, nk]},
            "filter": {"op": cmp, "args": ["m", "k"]},
            "expr": {"op": "*", "args": [
                {"op": "index", "args": ["u", "i", "m"]},
                {"op": "index", "args": ["w", "i", "m"]}]}})
    };
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_scan_fused"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i", "k"]},
                "w": {"type": "unknown", "shape": ["i", "k"]},
                "P": {"type": "unknown", "shape": ["i", "k"]},
                "Q": {"type": "unknown", "shape": ["i", "k"]}
            },
            "equations": [
                {"lhs": "w", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
                    "ranges": {"i": [1, ni], "k": [1, nk]},
                    "expr": {"op": "+", "args": [1.0, {"op": "*", "args": [0.5,
                        {"op": "sin", "args": [{"op": "*", "args": ["i", "k"]}]}]}]}}},
                {"lhs": "P", "rhs": scan_obs("<=")},
                {"lhs": "Q", "rhs": scan_obs("<")},
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", "i", "k"]}], "wrt": "t"},
                            "ranges": {"i": [1, ni], "k": [1, nk]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
                            "ranges": {"i": [1, ni], "k": [1, nk]},
                            "expr": {"op": "+", "args": [
                                {"op": "*", "args": [-0.001,
                                    {"op": "index", "args": ["P", "i", "k"]}]},
                                {"op": "*", "args": [0.002,
                                    {"op": "index", "args": ["Q", "i", "k"]}]}
                            ]}}
                }
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(opcount(&prog, "Scan"), 0, "both scans are absorbed");
    assert_eq!(scan_micro_ops(&prog), 2);
    let cont = prog.section_range(Cadence::Continuous);
    let fused_cont = prog.instrs[cont]
        .iter()
        .filter(|i| matches!(i, Instr::Fused { .. }))
        .count();
    assert_eq!(fused_cont, 1, "the scans and their reader run as one group");
}

/// A ghost Laplacian along the innermost axis of a 3-D box whose rows are
/// too short to fold as shifted reads: the gathers are read through their
/// plans one chunk at a time inside the consumer's group (chunks start and
/// end mid-row), together with a wrap along the outer axis.
#[test]
fn ab_chunk_gathers_on_short_rows() {
    let (ni, nj, nk) = (8i64, 4i64, 40i64);
    let ix3 = |i: serde_json::Value, k: serde_json::Value| json!({"op": "index", "args": ["u", i, "j", k]});
    let lap = json!({"op": "+", "args": [
        ix3(json!("i"), json!({"op": "-", "args": ["k", 1]})),
        {"op": "*", "args": [-2.0, ix3(json!("i"), json!("k"))]},
        ix3(json!("i"), json!({"op": "+", "args": ["k", 1]})),
        {"op": "*", "args": [0.5, ix3(wrap(json!({"op": "+", "args": ["i", 1]}), 1, ni), json!("k"))]}
    ]});
    let ranges = json!({"i": [1, ni], "j": [1, nj], "k": [1, nk]});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_chunk_gather"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i", "j", "k"]}},
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "k"],
                        "expr": {"op": "D", "args": [
                            {"op": "index", "args": ["u", "i", "j", "k"]}], "wrt": "t"},
                        "ranges": ranges},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "k"],
                        "ranges": ranges, "expr": {"op": "*", "args": [0.25, lap]}}
            }]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert!(
        prog.fused
            .iter()
            .flat_map(|f| &f.inputs)
            .any(|i| i.gather.is_some()),
        "the innermost-axis shifts are read through their plans"
    );
    assert_eq!(opcount(&prog, "Gather"), 0, "no gather is materialized");
}

/// The unstructured-mesh gather `sum_k kappa * (u[nbr[i, k]] - u[i])` over a
/// constant neighbour table, with more cells than one executor chunk: the
/// folded gather reads positions resolved when the CONST section runs, and
/// the reduction over the four neighbour positions walks its accumulator
/// chunk by chunk.
#[test]
fn ab_index_gather_reduction_interleaved() {
    let n = 1500usize;
    let nbr: Vec<Vec<f64>> = (0..n)
        .map(|i| {
            (0..4)
                .map(|k| ((i * 7 + k * 389 + 1) % n + 1) as f64)
                .collect()
        })
        .collect();
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_mesh_gather"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["cells"]},
                "nbr": {"type": "unknown", "shape": ["cells", "nb"]},
                "kappa": {"type": "parameter", "default": 0.1}
            },
            "equations": [
                {"lhs": "nbr", "rhs": {"op": "const", "args": [], "value": nbr}},
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                            "ranges": {"i": [1, n]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "ranges": {"i": [1, n], "k": [1, 4]},
                            "expr": {"op": "*", "args": ["kappa", {"op": "-", "args": [
                                {"op": "index", "args": ["u",
                                    {"op": "index", "args": ["nbr", "i", "k"]}]},
                                {"op": "index", "args": ["u", "i"]}]}]}}
                }
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert!(
        prog.fused
            .iter()
            .any(|f| f.interleave.is_some() && f.inputs.iter().any(|i| i.index.is_some())),
        "the neighbour reduction runs interleaved over its folded gather"
    );
}

/// A declared observed whose whole body is a `makearray` (the boundary-
/// dispatch stencil shape every discretization template expands to), plus a
/// wholesale ELEMENTWISE observed combining a state array with a taped
/// observed array.
#[test]
fn ab_wholesale_makearray_and_elementwise_observeds() {
    let n = 8;
    let interior = json!({"op": "faq", "args": [], "output_idx": ["i"],
    "ranges": {"i": [2, n - 1]},
    "expr": {"op": "-", "args": [
        idx("u", json!({"op": "+", "args": ["i", 1]})),
        idx("u", json!({"op": "-", "args": ["i", 1]}))
    ]}});
    let top = json!({"op": "faq", "args": [], "output_idx": ["i"],
        "ranges": {"i": [n, n]},
        "expr": {"op": "*", "args": [2.0, idx("u", json!("i"))]}});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_wholesale"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "g": {"type": "unknown", "shape": ["i"]},
                "q": {"type": "unknown", "shape": ["i"]},
                "h": {"type": "unknown", "shape": ["i"]}
            },
            "equations": [
                {"lhs": "g", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                          "ranges": {"i": [1, n]},
                          "expr": {"op": "sin", "args": [{"op": "*", "args": [0.5, "i"]}]}}},
                {"lhs": "q", "rhs": {"op": "makearray", "args": [],
                          "regions": [[[2, n - 1]], [[1, 1]], [[n, n]]],
                          "values": [interior, 1.5, top]}},
                {"lhs": "h", "rhs": {"op": "+", "args": [
                          {"op": "*", "args": [2.0, "u"]}, "g", "q"]}},
                d_eq("u", n, agg(n, json!({"op": "neg", "args": [
                    {"op": "index", "args": ["h", "i"]}]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    // `g` is state-free — its instructions must land in the CONST section.
    assert!(prog.n_const > 0);
}

/// A FALLBACK observed `m` whose wholesale body is an `ifelse` over an ARRAY
/// test with scalar branches. `eval_ifelse` broadcasts to the test's box, so
/// the shape recorded for `m` must be that box. A scalar claim compiles `m`'s
/// readers against a scalar: `s` below as a scalar kernel (which then panics on
/// the scalar read of the published array), or the literal `index(m, 2)` as
/// the scalar-base NaN. The parameter index is what keeps `m` off the tape
/// (`wholesale: non-literal index argument`).
fn fallback_ifelse_array_condition_doc(reader: serde_json::Value) -> serde_json::Value {
    let n = 3;
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_fallback_ifelse"},
        "index_sets": {"c": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "psi": {"type": "unknown", "shape": ["c"]},
                "m": {"type": "unknown", "shape": ["c"]},
                "s": {"type": "unknown"},
                "a": {"type": "unknown", "shape": ["c"]},
                "p": {"type": "parameter", "default": 2.0}
            },
            "equations": [
                {"lhs": "m", "rhs": {"op": "ifelse", "args": [
                    {"op": ">", "args": ["psi", {"op": "index", "args": ["psi", "p"]}]},
                    1.0,
                    0.0
                ]}},
                {"lhs": "s", "rhs": reader},
                {"lhs": "a", "rhs": {"op": "+", "args": ["psi", "s"]}},
                {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                 "rhs": {"op": "-", "args": ["a"]}}
            ]
        }}
    })
}

fn check_fallback_ifelse_array_condition(reader: serde_json::Value) {
    let doc = fallback_ifelse_array_condition_doc(reader);
    let (_prog, report) = compile(doc.clone()).build_tape(&HashSet::new());
    assert!(
        report
            .fallbacks
            .iter()
            .any(|(name, reason)| name == "m" && reason.contains("non-literal index")),
        "`m` must be the fallback rule this test is about: {:?}",
        report.fallbacks
    );
    ab_check(doc, 1, -1.0, 1.0);
}

#[test]
fn ab_fallback_ifelse_array_condition_elementwise_reader() {
    check_fallback_ifelse_array_condition(json!({"op": "*", "args": ["m", 2.0]}));
}

#[test]
fn ab_fallback_ifelse_array_condition_indexed_reader() {
    check_fallback_ifelse_array_condition(json!({"op": "index", "args": ["m", 2]}));
}

/// End-to-end A/B against a real model file (opt-in): set `TAPE_AB_MODEL` to
/// an .esm path (e.g. simpleclimate.esm) and optionally `TAPE_AB_MP` to
/// `NX=12,NY=7,NZ=7`. Builds the tape, obtains the model's own u0 through a
/// zero-length solve, and asserts bitwise dy equality at u0 and at perturbed
/// states — the `native` tape against the `interpreter` per-cell oracle, the
/// same comparison `CONFORMANCE_SPEC.md` §5.44 runs over the corpus.
///
/// The two variables name an INPUT DOCUMENT and its metaparameters, not an
/// evaluation strategy, so they are not switches `esm-libraries-spec.md`
/// §2.5.10 retires: a model too large to commit is the one thing a fixture
/// cannot be.
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
    let seed_sol = crate::problem::esm_problem(
        &file,
        (0.0, 1.0),
        crate::problem::ProblemOptions {
            p: HashMap::new().clone(),
            u0: HashMap::new().clone(),
            rhs: crate::problem::Rhs::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| {
        crate::problem::solve(
            &prob,
            &crate::simulate::SolveOptions {
                alg: crate::simulate::Alg::Erk,
                abstol: Some(1e-8),
                reltol: Some(1e-6),
                saveat: Some(vec![0.0]),
                ..Default::default()
            },
        )
    })
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
/// a periodic WRAP (two-segment roll), a Dirichlet GHOST-edge shift
/// (uncovered edge rows read `+0.0`), and a LINEAR level-slice read
/// (constant element stride from a deeper box). The wrap and the ghost shift
/// run along both axes: on a box this small only a shift along the axis
/// stored leading folds, which is `i` as lowered and `j` in a column-major
/// program (`layout`). The A/B
/// harness proves byte equality of the fused program (shifted reads) against
/// the unfused program (materialized gathers) and the legacy interpreter.
#[test]
fn ab_shifted_read_folding_wrap_ghost_linear() {
    let (ni, nj) = (8, 6);
    let idx2 = |var: &str, i: serde_json::Value, j: serde_json::Value| json!({"op": "index", "args": [var, i, j]});
    // Wrap Laplacian along i on u[i,j]; ghost Laplacian along i on v[i,j];
    // plus a level-slice coupling w[i,3] broadcast down the j axis via a
    // 1-D observed.
    let lap_wrap = json!({"op": "+", "args": [
        idx2("u", wrap(json!({"op": "-", "args": ["i", 1]}), 1, ni), json!("j")),
        {"op": "*", "args": [-2.0, idx2("u", json!("i"), json!("j"))]},
        idx2("u", wrap(json!({"op": "+", "args": ["i", 1]}), 1, ni), json!("j")),
        idx2("u", json!("i"), wrap(json!({"op": "-", "args": ["j", 1]}), 1, nj)),
        idx2("u", json!("i"), wrap(json!({"op": "+", "args": ["j", 1]}), 1, nj))
    ]});
    let lap_ghost = json!({"op": "+", "args": [
        idx2("v", json!({"op": "-", "args": ["i", 1]}), json!("j")),
        {"op": "*", "args": [-2.0, idx2("v", json!("i"), json!("j"))]},
        idx2("v", json!({"op": "+", "args": ["i", 1]}), json!("j")),
        idx2("v", json!("i"), json!({"op": "-", "args": ["j", 1]})),
        idx2("v", json!("i"), json!({"op": "+", "args": ["j", 1]}))
    ]});
    let d2 = |var: &str, rhs: serde_json::Value| {
        json!({
            "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                    "expr": {"op": "D", "args": [
                        {"op": "index", "args": [var, "i", "j"]}], "wrt": "t"},
                    "ranges": {"i": [1, ni], "j": [1, nj]}},
            "rhs": rhs
        })
    };
    let agg2 = |body: serde_json::Value| {
        json!({"op": "faq", "args": [], "output_idx": ["i", "j"],
               "ranges": {"i": [1, ni], "j": [1, nj]}, "expr": body})
    };
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_fold"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i", "j"]},
                "v": {"type": "unknown", "shape": ["i", "j"]},
                "w": {"type": "unknown", "shape": ["i", "j"]},
                // s[i] = 0.5 * w[i, 3] and r[j] = 0.5 * w[2, j]: linear slice
                // reads, one of them strided in either storage order.
                "s": {"type": "unknown", "shape": ["i"]},
                "r": {"type": "unknown", "shape": ["j"]}
            },
            "equations": [
                {"lhs": "s", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                          "ranges": {"i": [1, ni]},
                          "expr": {"op": "*", "args": [0.5,
                              {"op": "index", "args": ["w", "i", 3]}]}}},
                {"lhs": "r", "rhs": {"op": "faq", "args": [], "output_idx": ["j"],
                          "ranges": {"j": [1, nj]},
                          "expr": {"op": "*", "args": [0.5,
                              {"op": "index", "args": ["w", 2, "j"]}]}}},
                d2("u", agg2(json!({"op": "*", "args": [0.25, lap_wrap]}))),
                d2("v", agg2(json!({"op": "*", "args": [0.25, lap_ghost]}))),
                d2("w", agg2(json!({"op": "*", "args": [
                    {"op": "+", "args": [
                        {"op": "index", "args": ["s", "i"]},
                        {"op": "index", "args": ["r", "j"]}]},
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
    let any_multi_run = prog.fused.iter().any(|f| f.schedule.n_runs > 1);
    let any_ghost = prog
        .fused
        .iter()
        .flat_map(|f| f.schedule.expanded())
        .any(|r| r.in_off.contains(&GHOST_OFF));
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
/// An observed no derivative reads sits after the part of the section a
/// right-hand-side call runs; a call that publishes runs it too and gets
/// its value, and the derivatives are bit-identical either way.
#[test]
fn output_only_observeds_leave_the_rhs() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_output_only"},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown"},
                "s": {"type": "unknown"},
                "o": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "o", "rhs": {"op": "*", "args": [{"op": "sin", "args": ["x"]}, 3.0]}},
                {"lhs": "s", "rhs": {"op": "*", "args": [2.0, "x"]}},
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "neg", "args": ["s"]}}
            ]
        }}
    });
    ab_check(doc.clone(), 0, -1.0, 1.0);
    let compiled = compile(doc);
    let (prog, _) = compiled.build_tape(&HashSet::new());
    let cont = prog.section_range(Cadence::Continuous).len() as u32;
    assert!(
        prog.n_rhs < cont,
        "o's instructions leave the call: {:?}",
        prog.instrs
    );
    let exported = prog.exports.iter().any(|(n, _)| n == "o");
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = vec![1.5f64];
    let run_call = |ctx: &mut super::exec::TapeCtx, dy: &mut [f64]| {
        let mut stats = RhsStats::default();
        let call = super::super::RhsCall {
            rhs_rules: &compiled.rhs_rules,
            observed_rules: &compiled.observed_rules,
            var_shapes: &compiled.var_shapes,
            param_names: &compiled.param_names,
            state: &state,
            params: &param_vec,
            forcing: &compiled.forcing,
            t: 0.0,
            declared: &compiled.declared_names,
        };
        super::exec::run_tape_call(
            ctx,
            &call,
            &super::super::ArrMap::default(),
            &compiled.const_scope,
            &super::super::ConstLitMemo::default(),
            dy,
            &mut stats,
        );
    };
    let mut ctx = super::exec::TapeCtx::new(
        std::rc::Rc::new(prog),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let mut dy = vec![0.0f64; 1];
    run_call(&mut ctx, &mut dy);
    assert_eq!(dy[0].to_bits(), (-3.0f64).to_bits());
    ctx.set_exports_active(true);
    let mut dy2 = vec![0.0f64; 1];
    run_call(&mut ctx, &mut dy2);
    assert_eq!(dy2[0].to_bits(), dy[0].to_bits());
    if exported {
        let o = ctx.exec.obs.get("o").expect("o published");
        assert_eq!(
            o[ndarray::IxDyn(&[])].to_bits(),
            (1.5f64.sin() * 3.0).to_bits()
        );
    }
}

#[test]
fn export_demotion_skips_unread_publishes() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_export_demote"},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown"},
                "s": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "s", "rhs": {"op": "*", "args": [2.0, "x"]}},
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
        let call = super::super::RhsCall {
            rhs_rules: &compiled.rhs_rules,
            observed_rules: &compiled.observed_rules,
            var_shapes: &compiled.var_shapes,
            param_names: &compiled.param_names,
            state: &state,
            params: &param_vec,
            forcing: &compiled.forcing,
            t: 0.0,
            declared: &compiled.declared_names,
        };
        super::exec::run_tape_call(
            ctx,
            &call,
            &super::super::ArrMap::default(),
            &compiled.const_scope,
            &super::super::ConstLitMemo::default(),
            dy,
            &mut stats,
        );
    };

    // Demoted (production default for a no-fallback model): the export is
    // never published into the observed map.
    let mut ctx = super::exec::TapeCtx::new(
        std::rc::Rc::new(prog),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let mut dy = vec![0.0f64; 1];
    run_call(&mut ctx, &mut dy);
    assert_eq!(dy[0].to_bits(), (-3.0f64).to_bits());
    assert!(
        !ctx.exec.obs.contains_key("s"),
        "demoted export must not publish"
    );

    // Re-enabled (fallbacks present, or an explicit request): the same call
    // publishes the computed value, and dy is unchanged.
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

/// The fail-closed layer behind the export-ordering gate (CONFORMANCE_SPEC
/// §5.23.1(2), §5.19.4). `compute_exports` places a taped observed's `Export`
/// before the `Fallback` that reads it; this test builds the program a route
/// that missed that gate would produce — the `Export` moved to just after its
/// reader — and requires the read to FAULT naming the observed rather than
/// resolve to a number: not a ghost `0.0` on the first call, and not the
/// previous call's published value on a later one. Both executors must reach
/// the same verdict (§5.23.1(3)).
#[test]
fn unpublished_export_read_by_a_fallback_fails_closed() {
    let n = 3;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_unpublished_export"},
        "index_sets": {"c": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "psi": {"type": "unknown", "shape": ["c"]},
                "s": {"type": "unknown", "shape": ["c"]},
                "k": {"type": "unknown", "shape": ["c"]}
            },
            "equations": [
                // Taped, and exported because the fallback below reads it.
                {"lhs": "s", "rhs": {"op": "+", "args": [1.0, "psi"]}},
                // A recurrence the tape does not lower
                // ([`untaped_self_read`]), so a Fallback.
                {"lhs": "k", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "ifelse", "args": [
                        {"op": "<=", "args": ["i", 1]},
                        idx("s", json!("i")),
                        {"op": "+", "args": [
                            idx("s", json!("i")),
                            {"op": "*", "args": [
                                0.5,
                                untaped_self_read("k", json!({"op": "-", "args": ["i", 1]}))]}
                        ]}
                    ]}}},
                {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
                 "rhs": {"op": "neg", "args": ["k"]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let nstates = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = seeded_state(nstates, 7, -1.0, 1.0);

    // Positions of the `Export` publishing `s` and of the `Fallback` reading it.
    let locate = |prog: &TapeProgram| {
        let e = prog
            .exports
            .iter()
            .position(|(n, _)| n == "s")
            .expect("fixture must export `s`") as u32;
        let export_pc = prog
            .instrs
            .iter()
            .position(|i| matches!(i, Instr::Export { export, .. } if *export == e))
            .expect("an Export for `s`");
        let fallback_pc = prog
            .instrs
            .iter()
            .position(|i| matches!(i, Instr::Fallback { .. }))
            .expect("the recurrence is a Fallback");
        (export_pc, fallback_pc)
    };
    let fast_call = |prog: TapeProgram, dy: &mut [f64], calls: usize| -> Vec<Option<String>> {
        let mut ctx = super::exec::TapeCtx::new(
            std::rc::Rc::new(prog),
            std::rc::Rc::new(compiled.observed_rules.clone()),
        );
        (0..calls)
            .map(|_| {
                let _ = super::super::take_const_array_oob();
                let mut stats = RhsStats::default();
                let call = super::super::RhsCall {
                    rhs_rules: &compiled.rhs_rules,
                    observed_rules: &compiled.observed_rules,
                    var_shapes: &compiled.var_shapes,
                    param_names: &compiled.param_names,
                    state: &state,
                    params: &param_vec,
                    forcing: &compiled.forcing,
                    t: 0.0,
                    declared: &compiled.declared_names,
                };
                dy.fill(0.0);
                super::exec::run_tape_call(
                    &mut ctx,
                    &call,
                    &super::super::ArrMap::default(),
                    &compiled.const_scope,
                    &super::super::ConstLitMemo::default(),
                    dy,
                    &mut stats,
                );
                super::super::take_const_array_oob()
            })
            .collect()
    };

    // Control: the gate's ordering runs clean on both executors, and they agree.
    let (good, report) = compiled.build_tape(&HashSet::new());
    assert_eq!(report.fallbacks.len(), 1, "{:?}", report.fallbacks);
    let (export_pc, fallback_pc) = locate(&good);
    assert!(
        export_pc < fallback_pc,
        "the gate publishes `s` before its reader"
    );
    let cont = good.section_range(Cadence::Continuous);
    assert!(cont.contains(&export_pc) && cont.contains(&fallback_pc));
    assert!(
        good.instrs[export_pc..fallback_pc]
            .iter()
            .all(|i| !matches!(i, Instr::JmpIfZero { .. })),
        "moving the Export must not cross a branch region"
    );
    let _ = super::super::take_const_array_oob();
    let mut dy_ref = vec![0.0f64; nstates];
    run_reference(&good, &compiled, &state, &param_vec, 0.0, &mut dy_ref);
    assert_eq!(super::super::take_const_array_oob(), None);
    let mut dy_fast = vec![0.0f64; nstates];
    for fault in fast_call(good, &mut dy_fast, 2) {
        assert_eq!(fault, None);
    }
    for (k, (a, b)) in dy_fast.iter().zip(dy_ref.iter()).enumerate() {
        assert_eq!(a.to_bits(), b.to_bits(), "dy[{k}]: {a:?} vs {b:?}");
    }

    // The route that missed the gate: `Export` moved to just after its reader.
    let (mut bad, _) = compiled.build_tape(&HashSet::new());
    let instr = bad.instrs.remove(export_pc);
    let prov = bad.provenance.remove(export_pc);
    bad.instrs.insert(fallback_pc, instr);
    bad.provenance.insert(fallback_pc, prov);
    let (moved_export, moved_fallback) = locate(&bad);
    assert!(moved_fallback < moved_export);

    let names_s = |fault: &Option<String>| {
        fault
            .as_deref()
            .is_some_and(|m| m.contains("E_TREEWALK_UNRESOLVED_ORDER") && m.contains("'s'"))
    };
    let _ = super::super::take_const_array_oob();
    let mut dy = vec![0.0f64; nstates];
    run_reference(&bad, &compiled, &state, &param_vec, 0.0, &mut dy);
    let ref_fault = super::super::take_const_array_oob();
    assert!(names_s(&ref_fault), "reference executor: {ref_fault:?}");
    // Two calls on one warm executor: the first read would meet the zero
    // prealloc, the second the value the first call published.
    for (call, fault) in fast_call(bad, &mut dy, 2).iter().enumerate() {
        assert!(names_s(fault), "fast executor call {call}: {fault:?}");
    }
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
        "esm": "1.1.0",
        "metadata": {"name": "tape_superops"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "v": {"type": "unknown", "shape": ["i"]}
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

    // The Bin3 arm (`all_superops_cfg`, the `ESS_TAPE_BIN3=1` threshold): the
    // three-op chain must merge, splat registers must be provisioned, and
    // BOTH executors must stay bitwise equal to the production interpreter.
    let compiled = compile(doc);
    let (prog3, _) = compiled.build_tape_opts(&HashSet::new(), Some(all_superops_cfg()));
    assert!(
        has_bin3(&prog3),
        "expected a Bin3 superop with bin3 enabled"
    );
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
        std::rc::Rc::new(
            compiled
                .build_tape_opts(&HashSet::new(), Some(all_superops_cfg()))
                .0,
        ),
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
        "esm": "1.1.0",
        "metadata": {"name": name},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "s": {"type": "unknown", "shape": ["i"]}
            },
            "equations": [
                {"lhs": "s",
                 "rhs": agg(n, json!({"op": "*", "args": [0.5, idx("u", json!("i"))]}))},
                d_eq("u", n, agg(n, rhs))
            ]
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

// ---------------------------------------------------------------------------
// Phase 2 tape growth: `Instr::ConstArray`, `Instr::Reduce`, and the observed
// shapes that let a reader of a per-cell-produced observed stay on the tape.
// ---------------------------------------------------------------------------

/// How many instructions of a given opcode the program carries.
fn opcount(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

/// Every fold of the program, as `(source box, folded leading axes, output
/// slot)`: an `Instr::Reduce`, or one a fused group absorbed (which folds its
/// box's leading axes down to `n_inner` elements).
fn reductions(prog: &TapeProgram) -> Vec<(DimU, usize, SlotId)> {
    let mut out = Vec::new();
    for i in &prog.instrs {
        match i {
            Instr::Reduce {
                axes,
                src_shape,
                out: o,
                ..
            } => {
                assert!(
                    axes.iter().enumerate().all(|(k, &a)| a as usize == k),
                    "the tape folds leading axes"
                );
                out.push((src_shape.clone(), axes.len(), *o));
            }
            Instr::Fused { spec } => {
                let fs = &prog.fused[*spec as usize];
                if let Some(r) = &fs.reduce {
                    let mut inner = 1usize;
                    let mut kept = 0usize;
                    while inner < r.n_inner {
                        kept += 1;
                        inner *= fs.shape[fs.shape.len() - kept];
                    }
                    assert_eq!(inner, r.n_inner, "n_inner is a trailing sub-box");
                    out.push((fs.shape.clone(), fs.shape.len() - kept, r.out));
                }
            }
            _ => {}
        }
    }
    out
}

/// An array-valued `const` observed, consumed elementwise and through a
/// gather. Before `Instr::ConstArray` the `const` rule bailed and took every
/// reader with it.
#[test]
fn ab_const_array_observed() {
    let n = 4;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_const_array"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "zc": {"type": "unknown", "shape": ["i"]},
                "f": {"type": "unknown", "shape": ["i"]}
            },
            "equations": [
                {"lhs": "zc", "rhs": {"op": "const", "args": [],
                                      "value": [0.25, -1.5, 2.0, 3.75]}},
                {"lhs": "f", "rhs": {"op": "+", "args": [
                    1, {"op": "cos", "args": [{"op": "*", "args": [3.5, "zc"]}]}]}},
                d_eq("u", n, agg(n, json!({"op": "*", "args": [
                    idx("f", json!("i")),
                    idx("zc", wrap(json!({"op": "+", "args": ["i", 1]}), 1, n))
                ]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(
        opcount(&prog, "ConstArray"),
        1,
        "the literal is stored once"
    );
    assert_eq!(prog.const_data.len(), 1);
    assert_eq!(&prog.const_data[0].shape[..], &[4]);
    assert_eq!(&prog.const_data[0].values, &[0.25, -1.5, 2.0, 3.75]);
    // CONST cadence: the literal is stored once per solve, not per RHS call.
    let store = prog
        .instrs
        .iter()
        .position(|i| matches!(i, Instr::ConstArray { .. }))
        .expect("ConstArray emitted");
    assert_eq!(prog.section_of(store), Cadence::Const);
}

/// Rank-0 `faq`s — every index contracted, scalar result — one per reduction
/// kernel, each folded by `Instr::Reduce`. `sum` over a sign-mixed state is
/// the order-sensitive case: a different association would move bits.
#[test]
fn ab_rank0_scalar_reductions() {
    let n = 5;
    let red = |kind: &str| {
        json!({"op": "faq", "args": [], "output_idx": [], "reduce": kind,
               "ranges": {"j": [1, n]},
               "expr": {"op": "*", "args": [idx("u", json!("j")), 1.5]}})
    };
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_rank0_reduce"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "s": {"type": "unknown", "default": 0.0},
                "tot": {"type": "unknown"},
                "prod": {"type": "unknown"},
                "hi": {"type": "unknown"},
                "lo": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "tot", "rhs": red("+")},
                {"lhs": "prod", "rhs": red("*")},
                {"lhs": "hi", "rhs": red("max")},
                {"lhs": "lo", "rhs": red("min")},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                 "rhs": {"op": "+", "args": ["tot", "prod", "hi", "lo"]}},
                d_eq("u", n, agg(n, json!({"op": "*", "args": ["tot", idx("u", json!("i"))]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    let folds = reductions(&prog);
    assert_eq!(folds.len(), 4, "one fold per reduction rule");
    for (src_shape, n_axes, out) in folds {
        assert_eq!(n_axes, 1, "the single contracted axis");
        assert_eq!(&src_shape[..], &[n as usize]);
        assert!(prog.slots[out as usize].scalar, "rank-0 output");
    }
}

/// A two-axis rank-0 reduction: the fold order is LEXICOGRAPHIC over the
/// contracted names (last fastest), which is `CartesianTuples`' odometer. A
/// body that is not associativity-neutral (mixed magnitudes) would move bits
/// under any other order, so the bitwise A/B is the assertion.
#[test]
fn ab_rank0_reduction_two_contracted_axes() {
    let n = 4;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_rank0_reduce_2d"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "s": {"type": "unknown", "default": 0.0},
                "tot": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "tot", "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"j": [1, n], "k": [1, n]},
                    "expr": {"op": "*", "args": [
                        {"op": "^", "args": [10.0, "k"]},
                        idx("u", json!("j"))]}}},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "tot"},
                d_eq("u", n, agg(n, json!({"op": "*", "args": ["tot", idx("u", json!("i"))]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -3.0, 3.0);
    let folds = reductions(&prog);
    let (src_shape, n_axes, _) = folds.first().expect("a fold emitted");
    assert_eq!(*n_axes, 2);
    assert_eq!(&src_shape[..], &[n as usize, n as usize]);
}

/// A filtered rank-0 reduction tapes: the excluded tuples are SKIPPED (their
/// term replaced by a value the fold leaves unchanged), so the fold visits
/// the oracle's terms in the oracle's order.
#[test]
fn ab_rank0_reduction_with_a_filter() {
    let n = 4;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_rank0_filter"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "s": {"type": "unknown", "default": 0.0},
                "tot": {"type": "unknown"}
            },
            "equations": [
                {"lhs": "tot", "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"j": [1, n]},
                    "filter": {"op": "<=", "args": ["j", 2]},
                    "expr": idx("u", json!("j"))}},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "tot"},
                d_eq("u", n, agg(n, idx("u", json!("i"))))
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(reductions(&prog).len(), 1, "one fold");
}

/// The shape cascade: an observed produced by a rule the tape REFUSES (a
/// recurrence it does not lower, [`untaped_self_read`]) is still read on the
/// tape by later rules, because its published box is inferable. Before, every
/// reader bailed too.
#[test]
fn ab_reader_of_a_fallback_producer_stays_taped() {
    let n = 6;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_fallback_producer_shape"},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["i"]},
                "r": {"type": "unknown", "shape": ["i"]},
                "g": {"type": "unknown", "shape": ["i"]}
            },
            "equations": [
                // A causal self-reference: `r[i]` reads `r[i-1]`, through a
                // part of the body the tape's sweep does not lower.
                {"lhs": "r", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    // The base case is an `ifelse` guard INSIDE the body: a
                    // self-read of an unpublished cell is a fault, never a
                    // zero (CONFORMANCE_SPEC §5.19.4).
                    "expr": {"op": "ifelse", "args": [
                        {"op": "<=", "args": ["i", 1]},
                        idx("u", json!("i")),
                        {"op": "+", "args": [
                            idx("u", json!("i")),
                            {"op": "*", "args": [
                                0.5,
                                untaped_self_read("r", json!({"op": "-", "args": ["i", 1]}))]}
                        ]}
                    ]}}},
                // …read elementwise, and through a shifted gather.
                {"lhs": "g", "rhs": {"op": "*", "args": [2.0, "r"]}},
                d_eq("u", n, agg(n, json!({"op": "-", "args": [
                    idx("g", json!("i")),
                    idx("r", wrap(json!({"op": "+", "args": ["i", 1]}), 1, n))
                ]})))
            ]
        }}
    });
    // Exactly one fallback: the recurrence itself.
    let prog = ab_check(doc, 1, -2.0, 2.0);
    let fb: Vec<&str> = prog
        .rules
        .iter()
        .filter(|r| matches!(r.status, RuleStatus::Fallback(_)))
        .map(|r| r.name.as_str())
        .collect();
    assert_eq!(fb, vec!["r"]);
    // The readers resolve `r` through the runtime observed map at its
    // inferred box.
    assert!(prog.obs_reads.iter().any(|n| n == "r"));
}

/// The phase-2 spike fixture end to end: all three gaps at once (an
/// array-valued `const`, a reader of it, a prefix-scan aggregate and a rank-0
/// reduction), loaded from the corpus rather than restated here.
#[test]
fn ab_elementwise_observed_gather_fixture() {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(
        "../../tests/conformance/elementwise_observed_gather/fixtures/elementwise_gather.esm",
    );
    let file = crate::parse::load_path(&path).expect("corpus fixture loads");
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    for (label, fuse) in [("fused", Some(default_cfg())), ("unfused", None)] {
        let (prog, report) = compiled.build_tape_opts(&HashSet::new(), fuse);
        assert!(
            report.fallbacks.is_empty(),
            "{label}: {:?}",
            report.fallbacks
        );
        // Four observeds, `D(s)`, and `D(u)` as ONE rule over its four cells.
        assert_eq!(report.n_taped, 6, "{label}: all six rules");
        assert_eq!(opcount(&prog, "ConstArray"), 1, "{label}");
        assert_eq!(opcount(&prog, "Reduce"), 1, "{label}");

        let n = compiled.state_variable_names().len();
        let params = HashMap::new();
        let param_vec = compiled.debug_resolve_params(&params);
        for seed in 0..3u64 {
            let state = seeded_state(n, seed, -2.0, 2.0);
            for &t in &[0.0, 1.0] {
                let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
                let mut dy = vec![0.0f64; n];
                run_reference(&prog, &compiled, &state, &param_vec, t, &mut dy);
                for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                    assert_eq!(
                        a.to_bits(),
                        b.to_bits(),
                        "{label} seed {seed} t {t}: dy[{k}] {a:?} vs {b:?}"
                    );
                }
            }
        }
    }
    // …and through the production fast executor on a warm scratch.
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut fast = compiled.debug_new_scratch_taped();
    for seed in 0..3u64 {
        let state = seeded_state(n, seed, -2.0, 2.0);
        for &t in &[0.0, 1.0] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            assert_fast_matches(
                &compiled,
                &mut fast,
                &param_vec,
                &state,
                t,
                &dy_ref,
                "elementwise_gather fixture",
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Closed functions: the esm-spec §9.2 `datetime.*` family.
// ---------------------------------------------------------------------------

/// The probe times the datetime tests sweep: the epoch, both sides of a day
/// boundary, a fractional second on each side of the epoch, a leap day, the
/// last second of a leap day, two year boundaries, a leap century (2000), two
/// non-leap centuries (1900 backwards, 2100 forwards) and a deeply negative
/// time (0001-01-01, several eras before the epoch), and four 400-year era
/// boundaries, where a reciprocal-rewritten divide floors the era one short.
const DATETIME_TIMES: &[f64] = &[
    0.0,
    -1.0,
    -0.5,
    86_399.999,
    86_400.0,
    946_684_800.0,     // 2000-01-01T00:00:00Z
    951_782_400.0,     // 2000-02-29T00:00:00Z (leap day)
    951_868_799.0,     // 2000-02-29T23:59:59Z
    1_709_164_800.0,   // 2024-02-29T00:00:00Z
    1_735_689_599.0,   // 2024-12-31T23:59:59Z
    1_735_689_600.0,   // 2025-01-01T00:00:00Z
    -2_208_988_800.0,  // 1900-01-01T00:00:00Z (non-leap century)
    -2_203_891_201.0,  // 1900-02-28T23:59:59Z
    4_102_444_800.0,   // 2100-01-01T00:00:00Z (non-leap century)
    -62_135_596_800.0, // 0001-01-01T00:00:00Z
    1_500_000_000.25,
    -1_500_000_000.25,
    // The start of a 400-year Gregorian era (March 1 of 0400, 0800, 1600 —
    // `z = day + 719468` an exact multiple of 146097). `fl(1/146097)` is below
    // the true reciprocal, so a backend that answers `z / 146097` with
    // `z * fl(1/146097)` floors the era one short and the whole date moves by
    // a day; these three are the multiples at which that product actually
    // rounds low.
    -49_539_254_400.0, // 0400-03-01T00:00:00Z (era boundary)
    -36_916_473_600.0, // 0800-03-01T00:00:00Z (era boundary)
    -11_670_912_000.0, // 1600-03-01T00:00:00Z (era boundary)
    951_868_800.0,     // 2000-03-01T00:00:00Z (era boundary, product exact)
];

/// The nine calendar entries of the closed-function registry, in the order the
/// fixture below declares its tendencies.
const DATETIME_NAMES: &[&str] = &[
    "datetime.year",
    "datetime.month",
    "datetime.day",
    "datetime.hour",
    "datetime.minute",
    "datetime.second",
    "datetime.day_of_year",
    "datetime.julian_day",
    "datetime.is_leap_year",
];

/// One 0-d tendency per `datetime.*` entry, all reading the solver time, plus
/// one ARRAY tendency that multiplies a calendar field into a coordinate ramp
/// (so the scalar result is exercised as a broadcast operand of an array box,
/// not only as a 0-d rule).
fn datetime_doc() -> serde_json::Value {
    let n = 3i64;
    let mut vars = serde_json::Map::new();
    let mut eqs: Vec<serde_json::Value> = Vec::new();
    for (k, name) in DATETIME_NAMES.iter().enumerate() {
        let var = format!("f{k}");
        vars.insert(var.clone(), json!({"type": "unknown"}));
        eqs.push(json!({
            "lhs": {"op": "D", "args": [var], "wrt": "t"},
            "rhs": {"op": "fn", "name": name, "args": ["t"]}
        }));
    }
    vars.insert("u".to_string(), json!({"type": "unknown", "shape": ["i"]}));
    eqs.push(d_eq(
        "u",
        n,
        agg(
            n,
            json!({"op": "*", "args": [
                "i",
                {"op": "fn", "name": "datetime.hour", "args": ["t"]}
            ]}),
        ),
    ));
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_datetime"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    })
}

/// Build the tape for `doc`, assert nothing fell back, and assert BITWISE
/// equality of `dy` against the production interpreter — whose `fn` arm is the
/// per-cell closed-function registry, i.e. the reference the lowering has to
/// reproduce — at every probe time, on the reference executor (fused and
/// unfused programs) and on the Step 3b fast executor.
fn datetime_ab_check(doc: serde_json::Value, times: &[f64]) {
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), Some(default_cfg()));
    assert!(
        report.fallbacks.is_empty(),
        "the datetime family must lower with no fallback, else the tape path is \
         untested: {:?}",
        report.fallbacks
    );
    let (prog_uf, _) = compiled.build_tape_opts(&HashSet::new(), None);
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut scratch = compiled.debug_new_scratch_taped();
    let state = vec![0.0f64; n];
    for &t in times {
        let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
        for (label, p) in [("fused", &prog), ("unfused", &prog_uf)] {
            let mut dy = vec![0.0f64; n];
            run_reference(p, &compiled, &state, &param_vec, t, &mut dy);
            assert_bits_eq(&dy, &dy_ref, &format!("t={t} tape-ref {label}"));
        }
        assert_fast_matches(
            &compiled,
            &mut scratch,
            &param_vec,
            &state,
            t,
            &dy_ref,
            &format!("t={t} fast"),
        );
    }
}

/// Every `datetime.*` entry, taped, bit-identical to the closed-function
/// registry the per-cell oracle calls — including the integer fields, which
/// the spec pins to zero ulp drift, and `julian_day`, which the lowering
/// happens to reproduce exactly (its single divide is IEEE-754 pinned) rather
/// than merely inside the spec's 1 ulp.
#[test]
fn ab_datetime_family() {
    datetime_ab_check(datetime_doc(), DATETIME_TIMES);
}

/// The oracle's `eval_fn` answers a NaN argument with the calendar fields of
/// the epoch, because its float-to-integer casts saturate, and with NaN for
/// `julian_day`, whose fractional term keeps the NaN. The tape has to do the
/// same, or a NaN state during a rejected solver step would be the one input
/// on which the two paths disagree.
#[test]
fn ab_datetime_nan_argument() {
    // `x / x` with x = 0 is the NaN the per-cell registry sees.
    let nan = json!({"op": "/", "args": ["x", "x"]});
    let mut vars = serde_json::Map::new();
    vars.insert("x".to_string(), json!({"type": "unknown"}));
    let mut eqs = vec![json!({"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0.0})];
    for (k, name) in DATETIME_NAMES.iter().enumerate() {
        let var = format!("f{k}");
        vars.insert(var.clone(), json!({"type": "unknown"}));
        eqs.push(json!({
            "lhs": {"op": "D", "args": [var], "wrt": "t"},
            "rhs": {"op": "fn", "name": name, "args": [nan]}
        }));
    }
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_datetime_nan"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    });
    datetime_ab_check(doc, &[0.0, 1.0]);
}

/// A `datetime.*` call on a compile-time-known time folds all the way to one
/// literal: the whole decomposition is constant, so the tape must not carry a
/// single instruction for it.
#[test]
fn datetime_on_a_literal_time_folds_at_build_time() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_datetime_const"},
        "models": {"M": {
            "variables": {"x": {"type": "unknown"}},
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "fn", "name": "datetime.year", "args": [946684800.0]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    for op in ["Bin", "Un", "Select"] {
        assert_eq!(
            opcount(&prog, op),
            0,
            "a constant `datetime.year` left a `{op}` instruction behind:\n{report}"
        );
    }
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut dy = vec![0.0f64; 1];
    run_reference(&prog, &compiled, &[0.0], &param_vec, 0.0, &mut dy);
    assert_eq!(dy[0], 2000.0, "datetime.year(946684800) is 2000");
}

/// The `interp.*` entries lower to ONE `Instr::Interp` each, whatever the
/// table's size — the instruction carries an index into `interp_tables`, not
/// the table — and the per-element answer is the registry's own.
///
/// This test used to assert the opposite (a named fallback), which is what the
/// tape did before the family was lowered. The shape of the assertion is kept:
/// what is checked is the INSTRUCTION, not just the absence of a fallback,
/// because a family lowered into a select chain per knot would also report no
/// fallback while putting a table's worth of instructions on the tape.
#[test]
fn interp_closed_functions_lower_to_one_instruction() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_interp"},
        "models": {"M": {
            "variables": {"x": {"type": "unknown"}},
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                 "rhs": {"op": "fn", "name": "interp.searchsorted", "args": [
                     "t", {"op": "const", "args": [], "value": [0.0, 1.0, 2.0]}]}}
            ]
        }}
    });
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    assert_eq!(opcount(&prog, "Interp"), 1, "{report}");
    // The table is on the PROGRAM, and the `const` literal that carried it
    // into the call is not materialized at all: nothing reads it any more.
    assert_eq!(prog.interp_tables.len(), 1);
    assert_eq!(opcount(&prog, "ConstArray"), 0, "{report}");

    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let mut dy = vec![0.0f64; 1];
    // `t = 1.5` sits between `xs[2]` and `xs[3]`, so the first entry >= t is
    // the third, 1-based.
    run_reference(&prog, &compiled, &[0.0], &param_vec, 1.5, &mut dy);
    assert_eq!(dy[0], 3.0);
    // Past the end: N + 1, one past the last index.
    run_reference(&prog, &compiled, &[0.0], &param_vec, 9.0, &mut dy);
    assert_eq!(dy[0], 4.0);
}

// ---------------------------------------------------------------------------
// Index widths (#474).
// ---------------------------------------------------------------------------

/// More entries than a 16-bit index can name. Each fixture below puts
/// something past this bound, so a program-table index narrowed to 16 bits,
/// or a fused group allowed to outgrow its 16-bit local indices, reads
/// another entry's value and the bitwise comparison fails.
const PAST_U16: usize = 70_000;

/// `PAST_U16` scalar state variables, each with its own equation (a scalar
/// diffusion chain, so every derivative reads its neighbours), and as many
/// parameters, of which the equations near both ends of the chain read ones
/// past the 16-bit bound. State, parameter and `dy` indices all exceed
/// 65,535.
#[test]
fn ab_state_and_parameter_indices_past_u16() {
    let n = PAST_U16;
    let mut vars = serde_json::Map::new();
    for k in 1..=n {
        vars.insert(format!("u{k}"), json!({"type": "unknown", "default": 1.0}));
        vars.insert(
            format!("c{k}"),
            json!({"type": "parameter", "default": 1.0 + k as f64 * 1e-3}),
        );
    }
    let coeff = |k: usize| {
        if k <= 3 || k > n - 3 {
            json!(format!("c{}", n + 1 - k))
        } else {
            json!(0.1)
        }
    };
    let eqs: Vec<serde_json::Value> = (1..=n)
        .map(|k| {
            let mut nb = Vec::new();
            if k > 1 {
                nb.push(json!(format!("u{}", k - 1)));
            }
            if k < n {
                nb.push(json!(format!("u{}", k + 1)));
            }
            let sum = if nb.len() == 1 {
                nb.pop().unwrap()
            } else {
                json!({"op": "+", "args": nb})
            };
            json!({
                "lhs": {"op": "D", "args": [format!("u{k}")], "wrt": "t"},
                "rhs": {"op": "*", "args": [coeff(k), {"op": "-", "args": [
                    sum, {"op": "*", "args": [2, format!("u{k}")]}]}]}
            })
        })
        .collect();
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_wide_state_indices"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    });
    let prog = ab_check(doc, 0, -1.0, 1.0);
    assert_eq!(prog.state_vars.len(), n);
}

/// More micro-ops and distinct scalar operands on one box than a fused
/// group's 16-bit local indices can name: `D(u[i]) = Σ_j j·u[i]` over
/// `PAST_U16` terms. The fusion pass has to split the box into several
/// groups, each within [`GroupIx`], and the split program must still match
/// the interpreter bit for bit.
#[test]
fn ab_fused_box_past_u16_splits_into_groups() {
    let n = 8;
    let terms: Vec<serde_json::Value> = (1..=PAST_U16)
        .map(|j| json!({"op": "*", "args": [j as f64 * 0.5, idx("u", json!("i"))]}))
        .collect();
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_wide_fused_box"},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "shape": ["i"]}},
            "equations": [d_eq("u", n, agg(n, json!({"op": "+", "args": terms})))]
        }}
    });
    let prog = ab_check(doc, 0, -1.0, 1.0);
    assert!(
        prog.fused.len() > 1,
        "the box must be split across groups, got {}",
        prog.fused.len()
    );
    let scalars: usize = prog.fused.iter().map(|f| f.scalars.len()).sum();
    assert!(
        scalars > GroupIx::MAX as usize,
        "the fixture must put more scalar operands on the box than one group can index ({scalars})"
    );
    for f in &prog.fused {
        let regs = f.n_regs as usize + f.n_load_regs as usize + f.n_splat_regs as usize;
        assert!(
            f.micro.len() < GroupIx::MAX as usize
                && f.scalars.len() < GroupIx::MAX as usize
                && regs < GroupIx::MAX as usize,
            "a group outgrew its local indices"
        );
    }
}

/// A shaped parameter's inline array default reaches the tape as the numbers
/// it was declared with — one `ConstArray` whose payload is the row-major
/// data — and the taped right-hand side agrees bit for bit with the
/// interpreter, which reads the same default back from the `const` literal.
#[test]
fn a_shaped_parameter_default_is_taped_from_its_data() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "shaped_param_data", "authors": ["tape tests"]},
        "index_sets": {"x": {"kind": "interval", "size": 3}, "y": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "default": 1.0, "shape": ["x", "y"]},
                "w": {"type": "parameter", "units": "1", "shape": ["x", "y"],
                      "default": [[0.5, -1.25], [2.0, 3.5], [-0.75, 1e-3]]}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                        "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i", "j"]}], "wrt": "t"},
                        "ranges": {"i": [1, 3], "j": [1, 2]}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                        "ranges": {"i": [1, 3], "j": [1, 2]},
                        "expr": {"op": "*", "args": [
                            {"op": "index", "args": ["w", "i", "j"]},
                            {"op": "index", "args": ["u", "i", "j"]}]}}
            }]
        }}
    });
    let prog = ab_check(doc.clone(), 0, -2.0, 2.0);
    let payloads: Vec<&ConstArrayData> = prog.const_data.iter().collect();
    // A column-major program stores the box axis-reversed (`layout`).
    let (shape, values): ([usize; 2], [f64; 6]) = if prog.col_major {
        ([2, 3], [0.5, 2.0, -0.75, -1.25, 3.5, 1e-3])
    } else {
        ([3, 2], [0.5, -1.25, 2.0, 3.5, -0.75, 1e-3])
    };
    assert!(
        payloads
            .iter()
            .any(|d| d.shape[..] == shape && d.values == values),
        "the default's row-major data is a ConstArray payload: {payloads:?}"
    );
    // And against the per-cell oracle, not only the overlay.
    let compiled = compile(doc);
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let state = seeded_state(n, 7, -2.0, 2.0);
    let (dy_oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);
    let mut scratch = compiled.debug_new_scratch_taped();
    let mut dy = vec![0.0f64; n];
    compiled.debug_eval_rhs_into(
        &state,
        0.0,
        &param_vec,
        &mut dy,
        &mut scratch,
        &mut RhsStats::default(),
    );
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    assert_eq!(bits(&dy), bits(&dy_oracle));
}

// ---------------------------------------------------------------------------
// Phase 3: `Instr::PolyArea` (with its planar broad phase), the build-time
// `intersect_polygon` ring, and `Instr::IndexGather`.
// ---------------------------------------------------------------------------

/// A square ring `[x0, x0 + w] × [y0, y0 + h]`, counter-clockwise.
fn quad(x0: f64, y0: f64, w: f64, h: f64) -> serde_json::Value {
    json!([[x0, y0], [x0 + w, y0], [x0 + w, y0 + h], [x0, y0 + h]])
}

/// A regrid-shaped document: `A[i, j] = polygon_intersection_area(src[i],
/// tgt[j])` over `src × tgt`, and `D(F[j]) = Σ_i A[i, j] · G[i] - F[j]`, so
/// every element of `A` reaches `dy`.
fn regrid_doc(
    manifold: &str,
    src: Vec<serde_json::Value>,
    tgt: Vec<serde_json::Value>,
) -> serde_json::Value {
    let (ns, nt) = (src.len() as i64, tgt.len() as i64);
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_poly_area"},
        "index_sets": {
            "s": {"kind": "interval", "size": ns},
            "t": {"kind": "interval", "size": nt},
            "v": {"kind": "interval", "size": 4},
            "c": {"kind": "interval", "size": 2}
        },
        "models": {"M": {
            "variables": {
                "src": {"type": "unknown", "shape": ["s", "v", "c"]},
                "tgt": {"type": "unknown", "shape": ["t", "v", "c"]},
                "A": {"type": "unknown", "shape": ["s", "t"]},
                "G": {"type": "unknown", "shape": ["s"]},
                "F": {"type": "unknown", "shape": ["t"]}
            },
            "equations": [
                {"lhs": "src", "rhs": {"op": "const", "args": [], "value": src}},
                {"lhs": "tgt", "rhs": {"op": "const", "args": [], "value": tgt}},
                {"lhs": "A", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                    "ranges": {"i": {"from": "s"}, "j": {"from": "t"}},
                    "expr": {"op": "polygon_intersection_area", "manifold": manifold,
                             "args": [idx("src", json!("i")), idx("tgt", json!("j"))]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "expr": {"op": "D", "args": [idx("G", json!("i"))], "wrt": "t"},
                         "ranges": {"i": {"from": "s"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "s"}},
                         "expr": {"op": "-", "args": [idx("G", json!("i"))]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["j"],
                         "expr": {"op": "D", "args": [idx("F", json!("j"))], "wrt": "t"},
                         "ranges": {"j": {"from": "t"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["j"],
                         "ranges": {"i": {"from": "s"}, "j": {"from": "t"}},
                         "expr": {"op": "-", "args": [
                             {"op": "*", "args": [
                                 {"op": "index", "args": ["A", "i", "j"]},
                                 idx("G", json!("i"))]},
                             {"op": "/", "args": [idx("F", json!("j")), ns]}]}}}
            ]
        }}
    })
}

/// The one `PolyArea` of a program and its spec.
fn only_poly_area(prog: &TapeProgram) -> &GeomSpec {
    assert_eq!(opcount(prog, "PolyArea"), 1, "one geometry instruction");
    assert_eq!(prog.geoms.len(), 1);
    let at = prog
        .instrs
        .iter()
        .position(|i| matches!(i, Instr::PolyArea { .. }))
        .expect("PolyArea emitted");
    assert_eq!(
        prog.section_of(at),
        Cadence::Const,
        "clipped once per solve"
    );
    &prog.geoms[0]
}

/// The planar broad phase against the dense definition: the fast executor
/// clips only the candidate pairs, the reference executor clips every pair,
/// and both must reproduce the interpreter's `dy` bit for bit. The rings
/// cover what the candidate enumeration has to get right: a strip layout
/// with a single diagonal band of overlaps, an edge-touching pair (a
/// candidate whose clip is a zero-area sliver), a corner-touching pair, a
/// target overlapping nothing, a padded ring, a clockwise ring, and a ring
/// with a NaN vertex (a box the R*-tree is never shown).
#[test]
fn ab_poly_area_planar_broad_phase() {
    let mut src: Vec<serde_json::Value> = (0..6).map(|k| quad(k as f64, 0.0, 1.0, 1.0)).collect();
    // Padded: the last vertex repeated in place of the fourth.
    src.push(json!([[6.0, 0.0], [7.0, 0.0], [7.0, 1.0], [7.0, 1.0]]));
    // Clockwise.
    src.push(json!([[8.0, 0.0], [8.0, 1.0], [9.0, 1.0], [9.0, 0.0]]));
    // A NaN coordinate: the ring's box is not finite.
    src.push(json!([[10.0, 0.0], [11.0, 0.0], [null, 1.0], [10.0, 1.0]]));
    let mut tgt: Vec<serde_json::Value> = (0..6)
        .map(|k| quad(k as f64 + 0.5, 0.25, 1.0, 1.0))
        .collect();
    tgt.push(quad(3.0, 1.0, 1.0, 1.0)); // shares an edge with src[3]
    tgt.push(quad(7.0, 1.0, 1.0, 1.0)); // shares a corner with src[6]
    tgt.push(quad(40.0, 40.0, 1.0, 1.0)); // overlaps nothing
    let prog = ab_check(regrid_doc("planar", src, tgt), 0, 0.5, 2.0);
    let spec = only_poly_area(&prog);
    assert_eq!(
        spec.pairs,
        Some((0, 1)),
        "the pair axes drive the broad phase"
    );
}

/// A null (NaN) literal is not what a document carries; keep the broad-phase
/// test's NaN ring honest by checking the same pairs without it too.
#[test]
fn ab_poly_area_planar_regular_grids() {
    let src: Vec<serde_json::Value> = (0..5)
        .flat_map(|i| (0..4).map(move |j| quad(i as f64, j as f64, 1.0, 1.0)))
        .collect();
    let tgt: Vec<serde_json::Value> = (0..3)
        .flat_map(|i| (0..3).map(move |j| quad(1.7 * i as f64 - 0.3, 1.3 * j as f64, 1.7, 1.3)))
        .collect();
    let prog = ab_check(regrid_doc("planar", src, tgt), 0, 0.5, 2.0);
    assert!(only_poly_area(&prog).pairs.is_some());
}

/// A spherical clip has no broad phase: every pair is clipped, densely, by
/// the same S2 kernel the interpreter calls.
#[test]
fn ab_poly_area_spherical_dense() {
    let src: Vec<serde_json::Value> = (0..3)
        .map(|k| quad(10.0 * k as f64, 0.0, 10.0, 10.0))
        .collect();
    let tgt: Vec<serde_json::Value> = (0..2)
        .map(|k| quad(10.0 * k as f64 + 5.0, 5.0, 10.0, 10.0))
        .collect();
    let prog = ab_check(regrid_doc("spherical", src, tgt), 0, 0.5, 2.0);
    assert_eq!(only_poly_area(&prog).pairs, None);
}

/// The wholesale form — `polygon_intersection_area` of two whole `[V, 2]`
/// arrays — is one scalar area; a ring drawn by a literal subscript is the
/// same instruction with a fixed selector, and a same-axis pair (`poly[c]`
/// against itself) is the dense per-element form.
#[test]
fn ab_poly_area_wholesale_and_same_axis() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_poly_area_scalar"},
        "index_sets": {"c": {"kind": "interval", "size": 3},
                       "v": {"kind": "interval", "size": 4},
                       "x": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "variables": {
                "a": {"type": "unknown", "shape": ["v", "x"]},
                "b": {"type": "unknown", "shape": ["v", "x"]},
                "poly": {"type": "unknown", "shape": ["c", "v", "x"]},
                "whole": {"type": "unknown"},
                "picked": {"type": "unknown"},
                "self_area": {"type": "unknown", "shape": ["c"]},
                "y": {"type": "unknown", "default": 1.0},
                "u": {"type": "unknown", "shape": ["c"]}
            },
            "equations": [
                {"lhs": "a", "rhs": {"op": "const", "args": [], "value": quad(0.0, 0.0, 2.0, 2.0)}},
                {"lhs": "b", "rhs": {"op": "const", "args": [], "value": quad(1.0, 1.0, 2.0, 2.0)}},
                {"lhs": "poly", "rhs": {"op": "const", "args": [], "value": [
                    quad(0.0, 0.0, 1.0, 1.0), quad(0.0, 0.0, 2.0, 3.0), quad(5.0, 5.0, 0.5, 0.25)]}},
                {"lhs": "whole", "rhs": {"op": "polygon_intersection_area", "manifold": "planar",
                                         "args": ["a", "b"]}},
                {"lhs": "picked", "rhs": {"op": "polygon_intersection_area", "manifold": "planar",
                                          "args": [{"op": "index", "args": ["poly", 2]}, "b"]}},
                {"lhs": "self_area", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": {"from": "c"}},
                    "expr": {"op": "polygon_intersection_area", "manifold": "planar",
                             "args": [idx("poly", json!("i")), idx("poly", json!("i"))]}}},
                {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [-1.0, "whole", "picked", "y"]}},
                d_eq("u", 3, agg(3, json!({"op": "*", "args": [
                    idx("self_area", json!("i")), idx("u", json!("i"))]})))
            ]
        }}
    });
    let prog = ab_check(doc, 0, 0.5, 2.0);
    assert_eq!(opcount(&prog, "PolyArea"), 3);
    assert!(prog.geoms.iter().all(|g| g.pairs.is_none()));
}

/// `intersect_polygon` of two literal rings is evaluated at build: the closed
/// ring is a literal, and the derived range over it (`from_faq` naming the
/// clip's `id`) has the ring's distinct-vertex count, as the interpreter's
/// ring registry says.
#[test]
fn ab_intersect_polygon_build_time_ring() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_intersect_polygon"},
        "index_sets": {
            "sv": {"kind": "interval", "size": 4},
            "tv": {"kind": "interval", "size": 4},
            "coord": {"kind": "interval", "size": 2},
            "clip_ring": {"kind": "derived", "from_faq": "ov"}
        },
        "models": {"M": {
            "variables": {
                "src": {"type": "unknown", "shape": ["sv", "coord"]},
                "tgt": {"type": "unknown", "shape": ["tv", "coord"]},
                "clip": {"type": "unknown", "shape": ["clip_ring", "coord"]},
                "area": {"type": "unknown"},
                "y": {"type": "unknown", "default": 1.0}
            },
            "equations": [
                {"lhs": "src", "rhs": {"op": "const", "args": [], "value": quad(0.0, 0.0, 2.0, 2.0)}},
                {"lhs": "tgt", "rhs": {"op": "const", "args": [],
                    "value": [[1.0, 1.0], [3.0, 1.5], [2.5, 3.0], [0.5, 2.5]]}},
                {"lhs": "clip", "rhs": {"op": "intersect_polygon", "id": "ov", "manifold": "planar",
                                        "args": ["src", "tgt"]}},
                {"lhs": "area", "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"k": {"from": "clip_ring"}},
                    "expr": {"op": "*", "args": [0.5, {"op": "-", "args": [
                        {"op": "*", "args": [
                            {"op": "index", "args": ["clip", "k", 1]},
                            {"op": "index", "args": ["clip", {"op": "+", "args": ["k", 1]}, 2]}]},
                        {"op": "*", "args": [
                            {"op": "index", "args": ["clip", {"op": "+", "args": ["k", 1]}, 1]},
                            {"op": "index", "args": ["clip", "k", 2]}]}]}]}}},
                {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [-1.0, "area", "y"]}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, 0.5, 2.0);
    assert_eq!(opcount(&prog, "PolyArea"), 0);
    assert!(
        prog.const_data
            .iter()
            .any(|d| d.shape[1] == 2 && d.shape[0] >= 4),
        "the closed ring is a literal"
    );
}

/// `D(u[i]) = Σ_k κ (u[nbr[i, k]] - u[i])` on an unstructured neighbour
/// table: one `IndexGather` over the promoted `(k, i)` box, with subscripts
/// that exercise the interpreter's rounding (`2.5` rounds away from zero,
/// `2.49` down) and its zero ghost (0, n + 1, a negative subscript).
#[test]
fn ab_index_gather_unstructured() {
    let n = 6;
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_index_gather"},
        "index_sets": {"cells": {"kind": "interval", "size": n},
                       "nb": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["cells"], "default": 1.0},
                "nbr": {"type": "unknown", "shape": ["cells", "nb"]},
                "kappa": {"type": "parameter", "default": 0.3}
            },
            "equations": [
                {"lhs": "nbr", "rhs": {"op": "const", "args": [], "value": [
                    [2, 6, 3], [1, 3, 0], [2.5, 4, 7], [3, 5, -1], [2.49, 6, 1], [5, 1, 4]]}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "expr": {"op": "D", "args": [idx("u", json!("i"))], "wrt": "t"},
                         "ranges": {"i": {"from": "cells"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "cells"}, "k": {"from": "nb"}},
                         "expr": {"op": "*", "args": ["kappa", {"op": "-", "args": [
                             {"op": "index", "args": ["u",
                                 {"op": "index", "args": ["nbr", "i", "k"]}]},
                             idx("u", json!("i"))]}]}}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -1.0, 2.0);
    // Fusion folds the gather into the group that consumes it: a pre-loaded
    // input rather than a materialized [k, i] box.
    assert_eq!(prog.index_gathers.len(), 1);
    assert_eq!(opcount(&prog, "IndexGather"), 0, "folded away");
    assert!(
        prog.fused.iter().any(|f| f
            .inputs
            .iter()
            .any(|i| i.index.is_some_and(|(_, m)| m == n as usize))),
        "a fused group reads the source through the subscript"
    );
    let spec = &prog.index_gathers[0];
    assert_eq!(spec.axes[..], [GatherAxis::Data]);
    assert_eq!(&spec.shape[..], &[3, n as usize], "the promoted (k, i) box");
}

/// A two-axis source with one data subscript and one affine axis
/// (`w[nbr[i], j]`), and a data subscript that is a scalar. Neither is the
/// rank-1 form fusion folds, so both stay instructions.
#[test]
fn ab_index_gather_mixed_axes() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_index_gather_mixed"},
        "index_sets": {"cells": {"kind": "interval", "size": 4},
                       "lev": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "w": {"type": "unknown", "shape": ["cells", "lev"], "default": 1.0},
                "nbr": {"type": "unknown", "shape": ["cells"]},
                "pick": {"type": "parameter", "default": 3.0}
            },
            "equations": [
                {"lhs": "nbr", "rhs": {"op": "const", "args": [], "value": [4, 1, 0, 2]}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["w", "i", "j"]}],
                                  "wrt": "t"},
                         "ranges": {"i": {"from": "cells"}, "j": {"from": "lev"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                         "ranges": {"i": {"from": "cells"}, "j": {"from": "lev"}},
                         "expr": {"op": "+", "args": [
                             {"op": "index", "args": ["w",
                                 {"op": "index", "args": ["nbr", "i"]}, "j"]},
                             {"op": "index", "args": ["w", "pick", "j"]}]}}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -1.0, 2.0);
    assert_eq!(opcount(&prog, "IndexGather"), 2);
}

/// Per-variable element types (esm-spec §11.3.1) on the tape: a binary32
/// observed beside a binary64 one, each with a predicate at the other
/// precision inside it. Every instruction carries the precision it was
/// lowered at, fusion keeps the two apart, and both executors agree with the
/// interpreter bit for bit, fused and unfused.
#[test]
fn ab_float32_variables_beside_float64_neighbours() {
    use crate::precision::Precision;
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/element_type/float32_state_float64_neighbour.esm");
    let text = std::fs::read_to_string(&path).expect("fixture reads");
    let doc: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");
    let file = typed(doc);
    let env = crate::precision_infer::env_of_file(&file).expect("precision environment");
    let annotated = crate::precision_infer::annotated(&file)
        .expect("precision inference")
        .expect("the fixture declares element types");
    let _env = env.enter();
    let compiled = ArrayCompiled::from_file(&annotated).expect("fixture compiles");
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), Some(default_cfg()));
    assert!(report.fallbacks.is_empty(), "{:?}", report.fallbacks);
    assert_eq!(prog.precision.len(), prog.instrs.len());
    assert!(prog.precision.contains(&Precision::Float32));
    assert!(prog.precision.contains(&Precision::Float64));

    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let prog_uf = compiled.build_tape_opts(&HashSet::new(), None).0;
    let mut fast = compiled.debug_new_scratch_taped();
    assert!(fast.has_tape());
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, -1.0, 1.0);
        let (want, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        let (oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);
        let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
        assert_eq!(bits(&want), bits(&oracle), "seed {seed}: overlay vs oracle");
        for (label, p) in [("fused", &prog), ("unfused", &prog_uf)] {
            let mut dy = vec![0.0f64; n];
            run_reference(p, &compiled, &state, &param_vec, 0.0, &mut dy);
            assert_eq!(
                bits(&dy),
                bits(&want),
                "seed {seed}: {label} reference executor"
            );
        }
        let mut dy = vec![0.0f64; n];
        compiled.debug_eval_rhs_into(
            &state,
            0.0,
            &param_vec,
            &mut dy,
            &mut fast,
            &mut RhsStats::default(),
        );
        assert_eq!(bits(&dy), bits(&want), "seed {seed}: fast executor");
    }
}

/// A state-driven causal self-reference (esm-spec §4.3.1.1) over a 2-D frame
/// whose recurrence axis is the SECOND one (so the sweep's outer loop is not
/// the row-major one), with a banded lag window under a `filter`, an `ifelse`
/// on the contracted symbol, a const-array read by a frame symbol, a state read
/// and a parameter-valued lag — read back by the derivative, so every executor
/// runs the sweep on every call. `n` is the recurrence axis's extent.
fn recurrence_doc(n: i64) -> serde_json::Value {
    let w = json!({"op": "const", "args": [], "value": [0.0, 0.5, -0.25, 0.125]});
    let body = json!({"op": "ifelse", "args": [
        {"op": "==", "args": ["a", 0]},
        {"op": "+", "args": [
            {"op": "index", "args": ["u", "i"]},
            {"op": "*", "args": [0.1, "j"]}
        ]},
        {"op": "*", "args": [
            {"op": "max", "args": [
                {"op": "index", "args": ["r", "i", {"op": "-", "args": ["j", "a"]}]}, -1.0]},
            {"op": "index", "args": [w, {"op": "+", "args": ["a", 1]}]}
        ]}
    ]});
    let lagged = json!({"op": "ifelse", "args": [
        {"op": "<=", "args": ["j", "L"]},
        0.0,
        {"op": "index", "args": ["r", "i", {"op": "-", "args": ["j", "L"]}]}
    ]});
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_recurrence"},
        "models": {"M": {
            "variables": {
                "L": {"type": "parameter", "default": 2},
                "u": {"type": "unknown", "shape": ["i"]},
                "r": {"type": "unknown", "shape": ["i", "j"]},
                "q": {"type": "unknown", "shape": ["i", "j"]}
            },
            "equations": [
                {"lhs": "r", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                    "reduce": "+",
                    "ranges": {"i": [1, 3], "j": [1, n], "a": [0, 3]},
                    "filter": {"op": "<=", "args": ["a", {"op": "-", "args": ["j", 1]}]},
                    "expr": body}},
                {"lhs": "q", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                    "ranges": {"i": [1, 3], "j": [1, n]},
                    "expr": {"op": "+", "args": [
                        {"op": "index", "args": ["r", "i", "j"]}, lagged]}}},
                {
                    "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "expr": {"op": "D", "args": [
                                {"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                            "ranges": {"i": [1, 3]}},
                    "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "ranges": {"i": [1, 3]},
                            "expr": {"op": "*", "args": [-0.01,
                                {"op": "index", "args": ["q", "i", n]}]}}
                }
            ]
        }}
    })
}

#[test]
fn ab_recurrence_sweep() {
    let prog = ab_check(recurrence_doc(6), 0, -2.0, 2.0);
    // One sweep, and nothing in its body fused.
    assert_eq!(opcount(&prog, "Sweep"), 1);
    assert!(opcount(&prog, "ScalarRead") > 0);
    // The body is lowered once: the program and the sweep's body do not grow
    // with the frame.
    let body_len = |p: &TapeProgram| p.sweeps[0].body_len;
    let small = compile(recurrence_doc(6))
        .build_tape_opts(&HashSet::new(), None)
        .0;
    let large = compile(recurrence_doc(600))
        .build_tape_opts(&HashSet::new(), None)
        .0;
    assert_eq!(body_len(&small), body_len(&large));
    assert_eq!(small.instrs.len(), large.instrs.len());
}
