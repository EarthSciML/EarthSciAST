//! The tape lowering limits closed in the universal-native plan's phase 4,
//! each pinned the same three ways: the rule is taped (no fallback), every
//! executor over both programs (fused and unfused) agrees with the PER-CELL
//! oracle bit for bit at several states and times, and the program is the
//! same length at two grid sizes, so nothing is interpreted per cell and the
//! build does not unroll with N. The documents mirror the probe fixtures in
//! `tests/fixtures/native_probes/`, parameterized by the grid size.

use super::super::{ArrayCompiled, RhsStats};
use super::ir::*;
use super::refexec::run_reference;
use super::tests::seeded_state;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

fn ix(v: &str, subs: Vec<Value>) -> Value {
    let mut args = vec![json!(v)];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

fn faq(out: &[&str], ranges: Value, expr: Value) -> Value {
    json!({"op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr})
}

/// `D(var[out…]) = rhs` over `ranges`.
fn d_eq(var: &str, out: &[&str], ranges: Value, rhs: Value) -> Value {
    let subs = out.iter().map(|s| json!(s)).collect();
    json!({
        "lhs": faq(out, ranges.clone(),
                   json!({"op": "D", "args": [ix(var, subs)], "wrt": "t"})),
        "rhs": faq(out, ranges, rhs)
    })
}

/// `ifelse(inner < lo, inner + P, ifelse(inner > hi, inner - P, inner))`.
fn wrap(inner: Value, lo: i64, hi: i64) -> Value {
    let p = hi - lo + 1;
    op(
        "ifelse",
        vec![
            op("<", vec![inner.clone(), json!(lo)]),
            op("+", vec![inner.clone(), json!(p)]),
            op(
                "ifelse",
                vec![
                    op(">", vec![inner.clone(), json!(hi)]),
                    op("-", vec![inner.clone(), json!(p)]),
                    inner,
                ],
            ),
        ],
    )
}

fn doc(name: &str, variables: Value, equations: Vec<Value>, domain: Option<Value>) -> Value {
    let mut d = json!({
        "esm": "1.1.0",
        "metadata": {"name": name},
        "models": {"M": {"variables": variables, "equations": equations}}
    });
    if let Some(dom) = domain {
        d["domain"] = dom;
    }
    d
}

/// Build `doc` under its own precision environment, require that the tape
/// lowers every rule, and require that the reference executor and the fast
/// executor, over the fused and the unfused program, write the per-cell
/// oracle's `dy` bit for bit. Returns the fused program.
fn oracle_ab(doc: Value) -> TapeProgram {
    let file = crate::parse::load_string(&doc.to_string()).expect("fixture document loads");
    let env = crate::precision_infer::env_of_file(&file).expect("precision environment");
    let file = crate::precision_infer::annotated(&file)
        .expect("precision inference")
        .unwrap_or(file);
    let _env = env.enter();
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    let cfg = super::fuse::SuperopCfg {
        bin3: false,
        ext_pairs: true,
    };
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), Some(cfg));
    let (prog_uf, report_uf) = compiled.build_tape_opts(&HashSet::new(), None);
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
    let mut fast = compiled.debug_new_scratch_taped();
    let mut fast_uf = super::super::RhsScratch::new(&compiled.var_shapes);
    fast_uf.install_tape(
        std::rc::Rc::new(compiled.build_tape_opts(&HashSet::new(), None).0),
        std::rc::Rc::new(compiled.observed_rules.clone()),
    );
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    for seed in 0..4u64 {
        let state = seeded_state(n, seed, 0.25, 2.5);
        for &t in &[0.0, 0.37, 2.5] {
            let (oracle, _) = compiled.debug_eval_rhs(&state, t, &params, true);
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
    prog
}

/// [`oracle_ab`] at two grid sizes, requiring the same program length.
fn flat_in_n(make: impl Fn(i64) -> Value, small: i64, large: i64) -> TapeProgram {
    let a = oracle_ab(make(small));
    let b = oracle_ab(make(large));
    assert_eq!(
        a.instrs.len(),
        b.instrs.len(),
        "the program must not grow with the grid ({small} vs {large} cells)"
    );
    b
}

fn count(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

/// More than four contracted indices: five at once, over a rank-1 output (the
/// promoted box is rank 6) and in a rank-0 observed.
#[test]
fn five_contracted_indices() {
    let make = |n: i64| {
        let r5 = json!({"a": [1, 2], "b": [1, 2], "c": [1, 2], "d": [1, 2], "e": [1, 2]});
        let mut r_out = r5.clone();
        r_out["i"] = json!([1, n]);
        let w5 = ix("w", ["a", "b", "c", "d", "e"].map(|s| json!(s)).to_vec());
        let weights = op(
            "+",
            vec![
                json!("a"),
                op("*", vec![json!(2), json!("b")]),
                op("*", vec![json!(3), json!("c")]),
                op("*", vec![json!(5), json!("d")]),
                op("*", vec![json!(7), json!("e")]),
            ],
        );
        doc(
            "five_contracted",
            json!({
                "u": {"type": "unknown", "shape": ["i"], "default": 1.0},
                "w": {"type": "unknown", "shape": ["a", "b", "c", "d", "e"], "default": 0.5},
                "z": {"type": "unknown", "default": 0.0},
                "s": {"type": "unknown"}
            }),
            vec![
                d_eq(
                    "w",
                    &["a", "b", "c", "d", "e"],
                    r5.clone(),
                    op("*", vec![json!(-0.05), w5.clone()]),
                ),
                d_eq(
                    "u",
                    &["i"],
                    r_out,
                    op(
                        "*",
                        vec![
                            json!(0.01),
                            op(
                                "+",
                                vec![
                                    op("*", vec![ix("u", vec![json!("i")]), w5.clone()]),
                                    weights,
                                ],
                            ),
                        ],
                    ),
                ),
                json!({"lhs": "s", "rhs": faq(&[], r5,
                    op("*", vec![w5, op("+", vec![json!("a"), json!("e")])]))}),
                json!({"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": "s"}),
            ],
            None,
        )
    };
    let prog = flat_in_n(make, 3, 40);
    // Fusion absorbs a reduction into the group that computes its terms.
    let folds = count(&prog, "Reduce") + prog.fused.iter().filter(|f| f.reduce.is_some()).count();
    assert!(
        folds >= 2,
        "both contractions fold on the tape, none unrolled"
    );
}

/// A periodic wrap over boxes that are not one full period of their source:
/// an interior-only update, a window shorter than its source, a source
/// shorter than its window (reads falling off it, including one folded once
/// and still outside), and a const table read through a partial wrap.
#[test]
fn periodic_wraps_that_are_not_a_full_roll() {
    let make = |n: i64| {
        let i = || json!("i");
        let plus = |k: i64| op("+", vec![json!("i"), json!(k)]);
        let table: Vec<f64> = (0..n).map(|k| 0.25 * k as f64 - 1.5).collect();
        doc(
            "partial_wrap",
            json!({
                "u": {"type": "unknown", "shape": ["x"], "default": 1.0},
                "v": {"type": "unknown", "shape": ["y"], "default": 2.0},
                "r": {"type": "unknown", "shape": ["z"], "default": 0.75},
                "c": {"type": "unknown", "shape": ["x"]}
            }),
            vec![
                json!({"lhs": "c", "rhs": {"op": "const", "args": [], "value": table}}),
                d_eq(
                    "u",
                    &["i"],
                    json!({"i": [2, n - 1]}),
                    op(
                        "+",
                        vec![
                            ix("u", vec![wrap(plus(-1), 1, n)]),
                            ix("u", vec![wrap(plus(1), 1, n)]),
                            op("*", vec![json!(-2), ix("u", vec![i()])]),
                            op("*", vec![json!(0.01), ix("c", vec![wrap(plus(2), 1, n)])]),
                        ],
                    ),
                ),
                d_eq(
                    "u",
                    &["i"],
                    json!({"i": [1, 1]}),
                    op("*", vec![json!(-0.2), ix("u", vec![i()])]),
                ),
                d_eq(
                    "u",
                    &["i"],
                    json!({"i": [n, n]}),
                    op("*", vec![json!(-0.3), ix("u", vec![i()])]),
                ),
                d_eq(
                    "v",
                    &["i"],
                    json!({"i": [1, n + 2]}),
                    op("*", vec![json!(-0.1), ix("v", vec![wrap(plus(2), 1, n)])]),
                ),
                d_eq(
                    "r",
                    &["i"],
                    json!({"i": [1, n - 2]}),
                    op(
                        "+",
                        vec![
                            op("*", vec![json!(-0.2), ix("r", vec![wrap(plus(1), 1, n)])]),
                            op(
                                "*",
                                vec![json!(0.1), ix("r", vec![wrap(plus(2 * n + 1), 1, n)])],
                            ),
                        ],
                    ),
                ),
            ],
            None,
        )
    };
    flat_in_n(make, 6, 40);
}

/// Derivative left-hand sides that are not a constant shift of the output
/// indices: a reversal and a transpose.
#[test]
fn derivative_lhs_that_is_not_a_constant_shift() {
    let make = |n: i64| {
        doc(
            "permuted_lhs",
            json!({
                "u": {"type": "unknown", "shape": ["x"], "default": 1.0},
                "m": {"type": "unknown", "shape": ["y", "x"], "default": 0.25}
            }),
            vec![
                json!({
                    "lhs": faq(&["i"], json!({"i": [1, n]}), json!({"op": "D", "wrt": "t",
                        "args": [ix("u", vec![op("-", vec![json!(n + 1), json!("i")])])]})),
                    "rhs": faq(&["i"], json!({"i": [1, n]}), op("+", vec![
                        op("*", vec![json!(-0.1), ix("u", vec![json!("i")])]),
                        op("*", vec![json!(0.01), json!("i")])]))
                }),
                json!({
                    "lhs": faq(&["i", "j"], json!({"i": [1, n], "j": [1, 2]}),
                        json!({"op": "D", "wrt": "t", "args": [ix("m", vec![json!("j"), json!("i")])]})),
                    "rhs": faq(&["i", "j"], json!({"i": [1, n], "j": [1, 2]}), op("-", vec![
                        op("*", vec![json!(0.1), json!("i")]),
                        op("*", vec![json!(0.2), ix("m", vec![json!("j"), json!("i")])])]))
                }),
            ],
            None,
        )
    };
    let prog = flat_in_n(make, 6, 40);
    assert_eq!(
        prog.dy_writes
            .iter()
            .filter(|w| w.scatter.is_some())
            .count(),
        2,
        "both rules write through a position table"
    );
}

/// An array observed defined per cell over ranges that start past 1: the
/// interpreter materializes it over `[1, hi]` with zeros below the range.
#[test]
fn array_observed_over_a_range_that_starts_past_one() {
    let make = |n: i64| {
        doc(
            "offset_observed",
            json!({
                "u": {"type": "unknown", "shape": ["x"], "default": 1.0},
                "g": {"type": "unknown", "shape": ["x"]}
            }),
            vec![
                json!({
                    "lhs": faq(&["i"], json!({"i": [3, n]}), ix("g", vec![json!("i")])),
                    "rhs": faq(&["i"], json!({"i": [3, n]}), op("*", vec![
                        op("+", vec![json!(1), json!("i")]), ix("u", vec![json!("i")])]))
                }),
                d_eq(
                    "u",
                    &["i"],
                    json!({"i": [1, n]}),
                    op(
                        "-",
                        vec![
                            op("*", vec![json!(0.01), ix("g", vec![json!("i")])]),
                            op("*", vec![json!(0.1), ix("u", vec![json!("i")])]),
                        ],
                    ),
                ),
            ],
            None,
        )
    };
    flat_in_n(make, 6, 40);
}

/// `datetime.*` where the kernels are binary32 — a Float32 document, and a
/// Float32 variable in a Float64 one — is one registry call per element
/// ([`Instr::Calendar`]); a Float64 document keeps the arithmetic expansion.
#[test]
fn datetime_at_single_precision() {
    const FNS: [&str; 8] = [
        "datetime.year",
        "datetime.month",
        "datetime.day",
        "datetime.hour",
        "datetime.minute",
        "datetime.second",
        "datetime.day_of_year",
        "datetime.is_leap_year",
    ];
    // `per_variable`: Float32 variables in a Float64 document; otherwise a
    // Float32 (or, with `f32 = false`, Float64) document.
    let make = |n: i64, f32: bool, per_variable: bool| {
        let mut vars = json!({
            "epoch": {"type": "parameter", "default": 946684800.0},
            "step": {"type": "parameter", "default": 8406720.0},
            "u": {"type": "unknown", "shape": ["x"], "default": 0.5}
        });
        let r = || json!({"i": [1, n]});
        let mut eqs = Vec::new();
        let mut total = Vec::new();
        for (k, f) in FNS.iter().enumerate() {
            let c = format!("c{k}");
            vars[&c] = json!({"type": "unknown", "shape": ["x"]});
            let inst = op(
                "+",
                vec![
                    json!("epoch"),
                    op("*", vec![json!("step"), json!("i")]),
                    op("*", vec![json!(3671.0), json!("i")]),
                    op("*", vec![json!(86400.0), json!("t")]),
                ],
            );
            eqs.push(json!({
                "lhs": faq(&["i"], r(), ix(&c, vec![json!("i")])),
                "rhs": faq(&["i"], r(), json!({"op": "fn", "name": f, "args": [inst]}))
            }));
            total.push(ix(&c, vec![json!("i")]));
        }
        // A scalar call on the solver time as well.
        vars["h"] = json!({"type": "unknown"});
        eqs.push(
            json!({"lhs": "h", "rhs": {"op": "fn", "name": "datetime.hour",
            "args": [op("+", vec![json!("epoch"), op("*", vec![json!(3600.0), json!("t")])])]}}),
        );
        total.push(json!("h"));
        eqs.push(d_eq(
            "u",
            &["i"],
            r(),
            op(
                "-",
                vec![
                    op("*", vec![json!(1e-4), op("+", total)]),
                    op("*", vec![json!(0.1), ix("u", vec![json!("i")])]),
                ],
            ),
        ));
        if per_variable {
            for (_, v) in vars.as_object_mut().expect("variables").iter_mut() {
                v["element_type"] = json!("Float32");
            }
        }
        let domain = (f32 && !per_variable).then(|| json!({"element_type": "Float32"}));
        doc("datetime_precision", vars, eqs, domain)
    };
    let f32_doc = flat_in_n(|n| make(n, true, false), 4, 40);
    assert_eq!(count(&f32_doc, "Calendar"), FNS.len() + 1);
    let per_var = flat_in_n(|n| make(n, true, true), 4, 40);
    assert_eq!(count(&per_var, "Calendar"), FNS.len() + 1);
    let f64_doc = flat_in_n(|n| make(n, false, false), 4, 40);
    assert_eq!(
        count(&f64_doc, "Calendar"),
        0,
        "Float64 keeps the expansion"
    );
}

/// A `bool_and_or` reduction stays refused, by name: CONFORMANCE_SPEC §5.6.1
/// has the numeric evaluators reject the array-valued ones, and does not say
/// whether they run a scalar one.
#[test]
fn boolean_reductions_are_refused_by_name() {
    let d = doc(
        "boolean_reduction",
        json!({
            "u": {"type": "unknown", "shape": ["x"], "default": 1.0},
            "v": {"type": "unknown", "shape": ["x"], "default": 1.0},
            "any_hot": {"type": "unknown"}
        }),
        vec![
            json!({"lhs": "any_hot", "rhs": {"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": [1, 4]}, "semiring": "bool_and_or",
                "expr": op(">", vec![ix("u", vec![json!("k")]), json!(1.2)])}}),
            d_eq(
                "u",
                &["i"],
                json!({"i": [1, 4]}),
                op("*", vec![json!(-0.1), json!("any_hot")]),
            ),
            json!({
                "lhs": faq(&["i"], json!({"i": [1, 4]}),
                    json!({"op": "D", "wrt": "t", "args": [ix("v", vec![json!("i")])]})),
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, 4], "k": [1, 4]}, "semiring": "bool_and_or",
                    "expr": op(">", vec![ix("v", vec![json!("k")]), ix("v", vec![json!("i")])])}
            }),
        ],
        None,
    );
    let file = crate::parse::load_string(&d.to_string()).expect("loads");
    let compiled = ArrayCompiled::from_file(&file).expect("compiles");
    let (_, report) = compiled.build_tape(&HashSet::new());
    for (rule, kind) in [("any_hot", "scalar"), ("D(v)", "array-valued")] {
        assert!(
            report.fallbacks.iter().any(|(name, why)| name == rule
                && why.contains(kind)
                && why.contains("bool_and_or")
                && why.contains("§5.6.1")),
            "{rule} must be refused naming the construct and the spec: {:?}",
            report.fallbacks
        );
    }
}
