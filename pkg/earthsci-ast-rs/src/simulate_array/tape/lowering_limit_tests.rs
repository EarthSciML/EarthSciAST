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
use super::taped;
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
/// oracle's `dy` bit for bit. Returns the fused program and the unfused one's
/// length.
fn oracle_ab(doc: Value) -> (TapeProgram, usize) {
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
    let (prog, report) = taped(compiled.build_tape_opts(&HashSet::new(), Some(cfg)));
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
    (prog, unfused_len)
}

/// [`oracle_ab`] at two grid sizes, requiring the same lowered program length
/// (the unfused one: fusion's grouping may differ with the box size).
fn flat_in_n(make: impl Fn(i64) -> Value, small: i64, large: i64) -> TapeProgram {
    let (_, a) = oracle_ab(make(small));
    let (b, b_len) = oracle_ab(make(large));
    assert_eq!(
        a, b_len,
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

/// A scalar `bool_and_or` reduction runs on the tape (CONFORMANCE_SPEC
/// §5.6.1): one fold with `BinCode::Or` from `0.0`, over one contracted index
/// and over two under a filter, bit for bit with the oracle and flat in N. An
/// array-valued one is rejected at build, under every compiler.
#[test]
fn scalar_boolean_reductions_lower_and_array_valued_ones_are_rejected() {
    let make = |n: i64| {
        doc(
            "boolean_reduction",
            json!({
                "u": {"type": "unknown", "shape": ["x"], "default": 1.0},
                "any_hot": {"type": "unknown"},
                "spread": {"type": "unknown"}
            }),
            vec![
                json!({"lhs": "any_hot", "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"k": [1, n]}, "semiring": "bool_and_or",
                    "expr": op(">", vec![ix("u", vec![json!("k")]), json!(1.2)])}}),
                json!({"lhs": "spread", "rhs": {"op": "faq", "args": [], "output_idx": [],
                    "ranges": {"k": [1, n], "m": [1, n]}, "semiring": "bool_and_or",
                    "filter": op("!=", vec![json!("k"), json!("m")]),
                    "expr": op(">", vec![op("-", vec![ix("u", vec![json!("k")]),
                        ix("u", vec![json!("m")])]), json!(0.5)])}}),
                d_eq(
                    "u",
                    &["i"],
                    json!({"i": [1, n]}),
                    op(
                        "*",
                        vec![
                            op("+", vec![json!(-0.1), json!("any_hot"), json!("spread")]),
                            ix("u", vec![json!("i")]),
                        ],
                    ),
                ),
            ],
            None,
        )
    };
    flat_in_n(make, 4, 40);

    let array_valued = doc(
        "array_boolean_reduction",
        json!({"v": {"type": "unknown", "shape": ["x"], "default": 1.0}}),
        vec![json!({
            "lhs": faq(&["i"], json!({"i": [1, 4]}),
                json!({"op": "D", "wrt": "t", "args": [ix("v", vec![json!("i")])]})),
            "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "ranges": {"i": [1, 4], "k": [1, 4]}, "semiring": "bool_and_or",
                "expr": op(">", vec![ix("v", vec![json!("k")]), ix("v", vec![json!("i")])])}
        })],
        None,
    );
    let file = crate::parse::load_string(&array_valued.to_string()).expect("loads");
    let err = ArrayCompiled::from_file(&file)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    assert!(
        err.contains("bool_and_or") && err.contains("§5.6.1"),
        "an array-valued bool_and_or reduction is rejected at build, naming the spec: {err}"
    );
}

/// `index` over a `transpose`, a `reshape` or a `broadcast` with a loop symbol
/// as a subscript (esm-spec §4.3.4, §4.3.5): the base is lowered whole, as the
/// oracle's gather evaluates it, then read at the subscripts.
#[test]
fn shape_op_bases_under_loop_symbol_subscripts() {
    let make = |n: i64| {
        let zero = |v: &str, out: &[&str], r: Value| d_eq(v, out, r, json!(0.0));
        doc(
            "shape_op_bases",
            json!({
                "u": {"type": "unknown", "shape": ["x", "y"], "default": 1.0},
                "a": {"type": "unknown", "shape": ["y"], "default": 2.0},
                "b": {"type": "unknown", "shape": ["x"], "default": 3.0},
                "v": {"type": "unknown", "shape": ["y"], "default": 0.0},
                "w": {"type": "unknown", "shape": ["y"], "default": 0.0},
                "z": {"type": "unknown", "shape": ["y"], "default": 0.0}
            }),
            vec![
                zero("u", &["i", "j"], json!({"i": [1, 2], "j": [1, n]})),
                zero("a", &["i"], json!({"i": [1, n]})),
                zero("b", &["i"], json!({"i": [1, 2]})),
                d_eq(
                    "v",
                    &["i"],
                    json!({"i": [1, n]}),
                    json!({"op": "index", "args": [op("transpose", vec![json!("u")]), "i", 2]}),
                ),
                d_eq(
                    "w",
                    &["j"],
                    json!({"j": [1, n]}),
                    json!({"op": "index", "args": [
                        {"op": "reshape", "args": ["a"], "shape": [1, n]}, 1, "j"]}),
                ),
                d_eq(
                    "z",
                    &["i"],
                    json!({"i": [1, n]}),
                    json!({"op": "index", "args": [
                        {"op": "broadcast", "fn": "+", "args": ["a",
                            {"op": "reshape", "args": ["b"], "shape": [1, 2]}]}, "i", 2]}),
                ),
            ],
            None,
        )
    };
    flat_in_n(make, 3, 40);
}

// ---------------------------------------------------------------------------
// The counted bracket (issue #588): a rank-0 indicator sum lowered to one
// `Instr::Count`, bit-identical to the fold it replaces.
// ---------------------------------------------------------------------------

/// `ifelse(cmp, 1, 0)`.
fn indicator(cmp: Value) -> Value {
    op("ifelse", vec![cmp, json!(1), json!(0)])
}

/// A column of `n` levels: `c[l]` is the rank-0 `faq` `body(l)` over
/// `k in [1, n]`, and the state `u` relaxes toward it. The axes a body may
/// read: `zc` (a const observed, increasing), `zp` (increasing, built from a
/// parameter, so unknown at build), `w` (a state, in no order), each over
/// `k`; `u[l]` is the query.
fn count_doc(n: i64, body: Value) -> Value {
    let zc: Vec<f64> = (0..n).map(|k| 3.0 * k as f64 / (n - 1) as f64).collect();
    doc(
        "counted_bracket",
        json!({
            "u": {"type": "unknown", "shape": ["lev"], "default": 1.0},
            "w": {"type": "unknown", "shape": ["lev"], "default": 0.5},
            "dz": {"type": "parameter", "default": 3.0 / (n - 1) as f64},
            "zc": {"type": "unknown", "shape": ["lev"]},
            "zp": {"type": "unknown", "shape": ["lev"]},
            "c": {"type": "unknown", "shape": ["lev"]}
        }),
        vec![
            json!({"lhs": "zc", "rhs": {"op": "const", "args": [], "value": zc}}),
            json!({"lhs": "zp", "rhs": faq(&["k"], json!({"k": [1, n]}),
                op("*", vec![json!("dz"), op("-", vec![json!("k"), json!(1)])]))}),
            json!({"lhs": "c", "rhs": faq(&["l"], json!({"l": [1, n]}), json!({
                "op": "faq", "args": [], "output_idx": [], "ranges": {"k": [1, n]},
                "expr": body
            }))}),
            d_eq(
                "u",
                &["l"],
                json!({"l": [1, n]}),
                op(
                    "+",
                    vec![
                        op("*", vec![json!(-0.1), ix("u", vec![json!("l")])]),
                        op("*", vec![json!(0.01), ix("c", vec![json!("l")])]),
                    ],
                ),
            ),
            d_eq(
                "w",
                &["l"],
                json!({"l": [1, n]}),
                op("*", vec![json!(-0.05), ix("w", vec![json!("l")])]),
            ),
        ],
        None,
    )
}

fn axis_at(axis: &str) -> Value {
    ix(axis, vec![json!("k")])
}

fn query() -> Value {
    ix("u", vec![json!("l")])
}

/// The `Instr::Count`s of `prog`, as `(rel, sorted)`.
fn counts(prog: &TapeProgram) -> Vec<(CountRel, bool)> {
    prog.instrs
        .iter()
        .filter_map(|i| match i {
            Instr::Count { rel, sorted, .. } => Some((*rel, *sorted)),
            _ => None,
        })
        .collect()
}

/// Every comparison, with the axis on either side, over a literal axis
/// (bisected without a check), a parameter-built one (checked once per call,
/// then bisected) and a state in no order (counted entry by entry): one
/// `Instr::Count` each, no reduction, and the oracle's bits.
#[test]
fn counted_bracket_every_relation_and_axis() {
    let spellings: [(&str, bool, CountRel); 6] = [
        ("<=", true, CountRel::Le),
        ("<", true, CountRel::Lt),
        (">=", true, CountRel::Ge),
        (">", true, CountRel::Gt),
        // The query on the left: the mirrored relation.
        (">=", false, CountRel::Le),
        ("<", false, CountRel::Gt),
    ];
    for axis in ["zc", "zp", "w"] {
        for (cmp, axis_left, rel) in spellings {
            let make = |n: i64| {
                let args = if axis_left {
                    vec![axis_at(axis), query()]
                } else {
                    vec![query(), axis_at(axis)]
                };
                count_doc(n, indicator(op(cmp, args)))
            };
            let prog = flat_in_n(make, 5, 37);
            assert_eq!(
                counts(&prog),
                vec![(rel, axis == "zc")],
                "{axis} {cmp} (axis left: {axis_left})"
            );
            assert_eq!(count(&prog, "Reduce"), 0, "{axis} {cmp}: no fold is left");
        }
    }
}

/// A query that is NaN at every cell satisfies no comparison: the count is 0,
/// as every term of the fold is.
#[test]
fn counted_bracket_nan_query() {
    let nan = op(
        "/",
        vec![
            op("-", vec![query(), query()]),
            op("-", vec![query(), query()]),
        ],
    );
    for axis in ["zc", "w"] {
        for cmp in ["<=", ">"] {
            let prog = oracle_ab(count_doc(
                9,
                indicator(op(cmp, vec![axis_at(axis), nan.clone()])),
            ))
            .0;
            assert_eq!(counts(&prog).len(), 1, "{axis} {cmp}");
        }
    }
}

/// The standalone rank-0 form: a scalar query, a scalar count.
#[test]
fn counted_bracket_standalone_scalar() {
    let make = |n: i64| {
        let zc: Vec<f64> = (0..n).map(|k| 3.0 * k as f64 / (n - 1) as f64).collect();
        doc(
            "counted_scalar",
            json!({
                "s": {"type": "unknown", "default": 1.0},
                "zc": {"type": "unknown", "shape": ["lev"]},
                "c": {"type": "unknown"}
            }),
            vec![
                json!({"lhs": "zc", "rhs": {"op": "const", "args": [], "value": zc}}),
                json!({"lhs": "c", "rhs": {
                    "op": "faq", "args": [], "output_idx": [], "ranges": {"k": [1, n]},
                    "expr": indicator(op("<=", vec![axis_at("zc"), json!("s")]))
                }}),
                json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                       "rhs": op("+", vec![op("*", vec![json!(-0.1), json!("s")]),
                                           op("*", vec![json!(0.01), json!("c")])])}),
            ],
            None,
        )
    };
    let prog = flat_in_n(make, 5, 37);
    assert_eq!(counts(&prog), vec![(CountRel::Le, true)]);
}

/// Shapes next to the bracket that are not a count, or not one this
/// recognition can prove: each keeps the general lowering (no
/// `Instr::Count`) and the oracle's bits.
#[test]
fn counted_bracket_near_misses_decline() {
    let cmp = |o: &str| op(o, vec![axis_at("zc"), query()]);
    let ite = |c: Value, a: Value, b: Value| op("ifelse", vec![c, a, b]);
    let n = 9i64;
    let plain = |body: Value| count_doc(n, body);
    let with = |body: Value, key: &str, v: Value| {
        let mut d = count_doc(n, body);
        d["models"]["M"]["equations"][2]["rhs"]["expr"][key] = v;
        d
    };
    let cases: Vec<(&str, Value)> = vec![
        // The complement: under a NaN query not the count of the mirrored
        // relation, and not a count of anything this instruction states.
        ("complement", plain(ite(cmp("<="), json!(0), json!(1)))),
        ("weight 2", plain(ite(cmp("<="), json!(2), json!(0)))),
        ("equality", plain(indicator(cmp("==")))),
        (
            "query reads k",
            plain(indicator(op(
                "<=",
                vec![axis_at("zc"), op("+", vec![query(), json!("k")])],
            ))),
        ),
        (
            "shifted axis read",
            plain(indicator(op(
                "<=",
                vec![ix("zc", vec![op("-", vec![json!("k"), json!(0)])]), query()],
            ))),
        ),
        (
            "product of indicators",
            plain(op(
                "*",
                vec![
                    indicator(cmp("<=")),
                    indicator(op(">=", vec![axis_at("zp"), query()])),
                ],
            )),
        ),
        (
            "filtered",
            with(
                indicator(cmp("<=")),
                "filter",
                op(">", vec![json!("k"), json!(1)]),
            ),
        ),
        (
            "max reduction",
            with(indicator(cmp("<=")), "reduce", json!("max")),
        ),
        (
            "axis past its extent",
            with(
                indicator(op("<=", vec![axis_at("w"), query()])),
                "ranges",
                json!({"k": [1, n + 2]}),
            ),
        ),
    ];
    for (label, d) in cases {
        let prog = oracle_ab(d).0;
        assert!(
            counts(&prog).is_empty(),
            "{label}: must keep the general lowering"
        );
    }
    // Two contracted indices.
    let mut d = count_doc(n, indicator(cmp("<=")));
    d["models"]["M"]["equations"][2]["rhs"]["expr"]["ranges"] = json!({"k": [1, n], "m": [1, 2]});
    let prog = oracle_ab(d).0;
    assert!(counts(&prog).is_empty(), "two contracted indices");
}

/// The A/B documents (`bench/interp_bracket`): the composition is taped with
/// one count per level box, agrees with the oracle bit for bit, and gives
/// exactly the `interp.linear` spelling's derivative.
#[test]
fn counted_bracket_benchmark_documents() {
    let read = |name: &str| -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bench/interp_bracket")
            .join(name);
        serde_json::from_str(&std::fs::read_to_string(&path).expect("benchmark document"))
            .expect("benchmark document parses")
    };
    let const_compose = read("interp_bracket_const_compose_N59.esm");
    let runtime = read("interp_bracket_runtime_compose_N59.esm");
    let fn_doc = read("interp_bracket_const_fn_N59.esm");
    let (prog, _) = oracle_ab(const_compose.clone());
    assert_eq!(counts(&prog), vec![(CountRel::Le, true)]);
    assert_eq!(
        faulting_gathers(&prog),
        0,
        "a clamped bracket's table reads cannot fault"
    );
    let (prog, _) = oracle_ab(runtime.clone());
    assert_eq!(counts(&prog), vec![(CountRel::Le, false)]);
    // The three spellings integrate the same ODE: the same derivative, bit for bit.
    let dy = |d: &Value| {
        let file = crate::parse::load_string(&d.to_string()).expect("loads");
        let compiled = ArrayCompiled::from_file(&file).expect("compiles");
        let n = compiled.state_variable_names().len();
        let state = seeded_state(n, 7, 0.25, 2.5);
        let params = HashMap::new();
        let mut scratch = compiled.debug_new_scratch_taped().expect("taped");
        let p = compiled.debug_resolve_params(&params);
        let mut out = vec![0.0; n];
        compiled.debug_eval_rhs_into(
            &state,
            1.3,
            &p,
            &mut out,
            &mut scratch,
            &mut RhsStats::default(),
        );
        (
            compiled.state_variable_names().to_vec(),
            out.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        )
    };
    let a = dy(&fn_doc);
    assert_eq!(a, dy(&const_compose), "interp.linear vs the composition");
    assert_eq!(a, dy(&runtime), "interp.linear vs the run-time composition");
}

/// The count itself, against the plain fold of the indicator, on windows
/// with signed zeros, infinities, NaNs and ties, sorted and not.
#[test]
fn count_rel_is_the_indicator_fold() {
    let pool = [
        f64::NEG_INFINITY,
        -2.5,
        -0.0,
        0.0,
        1.0,
        1.0,
        3.5,
        f64::INFINITY,
        f64::NAN,
    ];
    let queries = [
        f64::NEG_INFINITY,
        -3.0,
        -0.0,
        0.0,
        0.5,
        1.0,
        3.5,
        9.0,
        f64::INFINITY,
        f64::NAN,
    ];
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    for trial in 0..4000 {
        let len = (next() % 9) as usize;
        let mut w: Vec<f64> = (0..len)
            .map(|_| pool[(next() % pool.len() as u64) as usize])
            .collect();
        if trial % 2 == 0 {
            w.retain(|v| !v.is_nan());
            w.sort_by(|a, b| a.partial_cmp(b).unwrap());
        }
        let sorted = non_decreasing(w.len(), |j| w[j]);
        for rel in [CountRel::Le, CountRel::Lt, CountRel::Ge, CountRel::Gt] {
            for &x in &queries {
                let fold = w.iter().fold(0.0f64, |acc, &a| {
                    acc + if rel.holds(a, x) { 1.0 } else { 0.0 }
                });
                let got = count_rel(rel, w.len(), |j| w[j], sorted, x);
                assert_eq!(
                    got.to_bits(),
                    fold.to_bits(),
                    "{rel:?} {x} on {w:?} (sorted {sorted})"
                );
            }
        }
    }
}

/// Const-array gathers that can fault, and conditional fault scans.
fn faulting_gathers(prog: &TapeProgram) -> usize {
    prog.instrs
        .iter()
        .filter(|i| {
            matches!(
                i,
                Instr::DataGather { faults: true, .. } | Instr::FaultScan { .. }
            )
        })
        .count()
}

/// A const-array read at a count clamped into the array's extent cannot
/// fault, so it compiles without the fault machinery; at the bare count
/// (which can be 0) it keeps it. Both agree with the oracle bit for bit.
#[test]
fn const_gather_at_a_clamped_count() {
    let n = 9i64;
    let count = || {
        json!({"op": "faq", "args": [], "output_idx": [], "ranges": {"k": [1, n]},
               "expr": indicator(op("<=", vec![axis_at("zc"), query()]))})
    };
    let read = |sub: Value| {
        let mut d = count_doc(n, indicator(op("<=", vec![axis_at("zc"), query()])));
        d["models"]["M"]["equations"][2]["rhs"]["expr"] = ix("zc", vec![sub]);
        d
    };
    let clamped = op(
        "min",
        vec![op("max", vec![count(), json!(1)]), json!(n - 1)],
    );
    let prog = oracle_ab(read(clamped.clone())).0;
    assert_eq!(faulting_gathers(&prog), 0, "zc[clamp(count)]");
    let prog = oracle_ab(read(op("+", vec![clamped, json!(1)]))).0;
    assert_eq!(faulting_gathers(&prog), 0, "zc[clamp(count) + 1]");
    let prog = oracle_ab(read(count())).0;
    assert!(faulting_gathers(&prog) > 0, "zc[count] can read zc[0]");
}

/// A count window the axis does not hold at run time (a program whose
/// window outgrew its axis) is refused in every build profile, not read past
/// the axis's end.
#[test]
fn count_window_outside_its_axis_is_refused() {
    let d = count_doc(9, indicator(op("<=", vec![axis_at("w"), query()])));
    let file = crate::parse::load_string(&d.to_string()).expect("fixture document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    let (mut prog, _) = taped(compiled.build_tape_opts(&HashSet::new(), None));
    let mut widened = 0;
    for ins in &mut prog.instrs {
        if let Instr::Count { n, .. } = ins {
            *n += 1;
            widened += 1;
        }
    }
    assert_eq!(widened, 1);
    let n = compiled.state_variable_names().len();
    let param_vec = compiled.debug_resolve_params(&HashMap::new());
    let mut scratch = super::super::RhsScratch::new(&compiled.var_shapes);
    scratch.install_tape(std::sync::Arc::new(prog));
    let state = seeded_state(n, 1, 0.25, 2.5);
    let run = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut dy = vec![0.0f64; n];
        compiled.debug_eval_rhs_into(
            &state,
            0.0,
            &param_vec,
            &mut dy,
            &mut scratch,
            &mut RhsStats::default(),
        );
    }));
    let err = run.expect_err("an out-of-axis window must be refused");
    let msg = err
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| err.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default();
    assert!(msg.contains("does not hold the window"), "{msg}");
}

/// The count rewrite is a build option of the model, part of the tape
/// cache's key: switching it off on the same model builds (and serves) the
/// general fold, and switching it back serves the counted program again.
#[test]
fn count_rewrite_is_a_build_option() {
    let d = count_doc(9, indicator(op("<=", vec![axis_at("zc"), query()])));
    let file = crate::parse::load_string(&d.to_string()).expect("fixture document loads");
    let mut compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    let tape = |c: &ArrayCompiled| c.tape(&HashSet::new()).0.expect("taped");
    let on = tape(&compiled);
    assert_eq!(counts(&on).len(), 1);
    compiled.rewrites.count_fold = false;
    let off = tape(&compiled);
    assert!(counts(&off).is_empty(), "the general fold");
    assert!(count(&off, "Reduce") > 0);
    compiled.rewrites.count_fold = true;
    assert!(
        std::sync::Arc::ptr_eq(&on, &tape(&compiled)),
        "served from the cache"
    );
}
