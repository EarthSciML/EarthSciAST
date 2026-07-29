//! A/B verification of the tape LOWERING: build the tape for fixture models,
//! run the reference executor ([`super::refexec`]), and assert **bitwise**
//! equality of `dy` against `evaluate_rhs_with_scratch` — the full production
//! path (vectorized overlay + runtime CSE), reached through
//! `ArrayCompiled::debug_eval_rhs(force_scalar = false)` — at several
//! random-but-seeded states and times.

use super::super::ArrayCompiled;
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

/// Build the tape, check the expected fallback count, and assert bitwise `dy`
/// equality (tape reference executor vs the production interpreter) over
/// several seeded states and times.
fn ab_check(doc: serde_json::Value, expect_fallbacks: usize, lo: f64, hi: f64) -> TapeProgram {
    let compiled = compile(doc);
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert_eq!(
        report.fallbacks.len(),
        expect_fallbacks,
        "unexpected fallback set: {:?}",
        report.fallbacks
    );
    let n = compiled.state_variable_names().len();
    let params = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, lo, hi);
        for &t in &[0.0, 0.37, 2.5] {
            let (dy_ref, _) = compiled.debug_eval_rhs(&state, t, &params, false);
            let mut dy = vec![0.0f64; n];
            run_reference(&prog, &compiled, &state, &param_vec, t, &mut dy);
            for (k, (a, b)) in dy.iter().zip(dy_ref.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "seed {seed} t {t}: dy[{k}] diverged: tape {a:?} ({:016x}) vs \
                     interpreter {b:?} ({:016x})",
                    a.to_bits(),
                    b.to_bits()
                );
            }
        }
    }
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
    assert!(
        prog.instrs
            .iter()
            .any(|i| matches!(i, Instr::Select { .. })),
        "the filter mask must lower to Select instructions"
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
        }
    }
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
    let (prog, report) = compiled.build_tape(&HashSet::new());
    assert!(report.fallbacks.is_empty());

    // def / last-use per slot (linear order, re-defs count as uses).
    let mut def = vec![usize::MAX; prog.slots.len()];
    let mut last = vec![0usize; prog.slots.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        if let Some(o) = ins.out() {
            if def[o as usize] == usize::MAX {
                def[o as usize] = i;
            } else {
                last[o as usize] = last[o as usize].max(i);
            }
        }
        ins.for_each_read(&prog.dy_writes, |s| {
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
    // Bin(Sub) instructions — 1 for d (shared), not 2.
    let subs = prog
        .instrs
        .iter()
        .filter(|i| matches!(i, Instr::Bin { op, .. } if *op == super::super::BinCode::Sub))
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
        }
    }
}
