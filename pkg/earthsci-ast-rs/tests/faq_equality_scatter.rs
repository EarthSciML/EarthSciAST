//! A `faq` whose filter pins an output index by equality (`j == e`, `e`
//! reading no output index) is evaluated by `native` in one pass over the
//! contracted box, each admitted term scattered into cell `e`
//! (esm-spec §4.3.1, EarthSciAST#613). The interpreter keeps the naive
//! output × contracted walk and is the oracle: every case here compares the
//! two right-hand sides bit for bit, on data whose sum changes with the order
//! of its terms (`[1e16, 1, -1e16, 1]`) or that holds a NaN.
//!
//! The last test builds the transposed band at N = 10^6, whose dense
//! output × contracted box (10^12 terms) the dense lowering refuses: it
//! builds and runs only through the scatter.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::HashMap;

use earthsci_ast::{Compiler, ProblemOptions, RhsProgram, esm_problem, rhs_program};
use serde_json::{Value, json};

struct Counting;

thread_local! {
    static ALLOCS: Cell<usize> = const { Cell::new(0) };
}

fn allocs() -> usize {
    ALLOCS.with(Cell::get)
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let _ = ALLOCS.try_with(|c| c.set(c.get() + 1));
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        let _ = ALLOCS.try_with(|c| c.set(c.get() + 1));
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

fn ix(v: &str, subs: Vec<Value>) -> Value {
    let mut a = vec![json!(v)];
    a.extend(subs);
    op("index", a)
}

/// `faq` with `output_idx`, `ranges` (name -> [lo, hi]), `reduce`, `filter`.
fn faq(
    out: &[&str],
    ranges: &[(&str, i64, i64)],
    reduce: &str,
    filter: Value,
    expr: Value,
) -> Value {
    let mut r = serde_json::Map::new();
    for (n, lo, hi) in ranges {
        r.insert((*n).to_string(), json!([lo, hi]));
    }
    let mut f = json!({"op": "faq", "args": [], "output_idx": out, "ranges": r,
        "reduce": reduce, "expr": expr});
    if !filter.is_null() {
        f["filter"] = filter;
    }
    f
}

/// A model with a 1-D state `u` on `x` (size `n`) and, when `m > 0`, a 2-D
/// state `w` on `x2 × x2` (size `m`), whose equations are `eqs`.
fn doc(n: i64, m: i64, eqs: Vec<Value>, extra_vars: Value) -> Value {
    let mut vars = json!({
        "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}
    });
    if m > 0 {
        vars["w"] = json!({"type": "unknown", "units": "1", "shape": ["x2", "x2"], "default": 1.0});
    }
    if let Value::Object(o) = extra_vars {
        for (k, v) in o {
            vars[k] = v;
        }
    }
    let mut sets = json!({"x": {"kind": "interval", "size": n}});
    if m > 0 {
        sets["x2"] = json!({"kind": "interval", "size": m});
    }
    json!({
        "esm": "1.3.0",
        "metadata": {"name": "faq_equality_scatter", "authors": ["test"]},
        "index_sets": sets,
        "models": {"M": {"variables": vars, "equations": eqs}}
    })
}

/// `D(u[j]) = rhs` over `j ∈ [1, n]`.
fn du(n: i64, rhs: Value) -> Value {
    json!({
        "lhs": faq(&["j"], &[("j", 1, n)], "+", Value::Null,
            json!({"op": "D", "args": [ix("u", vec![json!("j")])], "wrt": "t"})),
        "rhs": rhs
    })
}

/// `D(w[a, b]) = rhs` over `a, b ∈ [1, m]`.
fn dw(m: i64, rhs: Value) -> Value {
    json!({
        "lhs": faq(&["a", "b"], &[("a", 1, m), ("b", 1, m)], "+", Value::Null,
            json!({"op": "D", "args": [ix("w", vec![json!("a"), json!("b")])], "wrt": "t"})),
        "rhs": rhs
    })
}

fn program(d: &Value, compiler: Compiler) -> RhsProgram {
    let prob = esm_problem(
        d,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{compiler} must build: {e}"));
    if compiler == Compiler::Native {
        for r in prob.compiler_report().rules() {
            assert_eq!(r.tier, "taped", "{}", r.rule);
        }
    }
    rhs_program(&prob).expect("program")
}

fn eval(prog: &RhsProgram, u: &[f64]) -> Vec<f64> {
    let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
    let fs = prog.default_forcing();
    let mut ws = prog.new_workspace();
    let mut out = vec![f64::NAN; prog.n_states()];
    prog.eval_into(u, &[], &p, 0.0, &fs, &mut out, &mut ws)
        .expect("eval");
    out
}

/// The state `u` (then `w`, row-major) filled from `pattern`, repeating.
fn state(prog: &RhsProgram, pattern: &[f64]) -> Vec<f64> {
    (0..prog.n_states())
        .map(|k| pattern[k % pattern.len()])
        .collect()
}

const CANCEL: [f64; 4] = [1e16, 1.0, -1e16, 1.0];
const WITH_NAN: [f64; 5] = [3.0, f64::NAN, -2.0, 7.0, 0.5];

/// Native and interpreter agree bit for bit on `d` at every state pattern.
fn agree(name: &str, d: &Value) -> Vec<f64> {
    let native = program(d, Compiler::Native);
    let interp = program(d, Compiler::Interpreter);
    let mut first = Vec::new();
    for pattern in [&CANCEL[..], &WITH_NAN[..], &[0.5, -0.0, 2.0][..]] {
        let u = state(&native, pattern);
        let a = eval(&native, &u);
        let b = eval(&interp, &u);
        assert_eq!(a.len(), b.len());
        for (k, (x, y)) in a.iter().zip(&b).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "[{name}] cell {k}: native {x:e} vs interpreter {y:e} (pattern {pattern:?})"
            );
        }
        if first.is_empty() {
            first = a;
        }
    }
    first
}

fn eq(a: Value, b: Value) -> Value {
    op("==", vec![a, b])
}

fn plus(a: Value, b: Value) -> Value {
    op("+", vec![a, b])
}

fn and(args: Vec<Value>) -> Value {
    op("and", args)
}

#[test]
fn transposed_band_sum_matches_the_interpreter() {
    // out[j] = Σ_{i : i + 1 = j} u[i] (i/2 + 1), and the mirrored spelling.
    for filt in [
        eq(plus(json!("i"), json!(1)), json!("j")),
        eq(json!("j"), plus(json!("i"), json!(1))),
    ] {
        let rhs = faq(
            &["j"],
            &[("j", 1, 9), ("i", 1, 8)],
            "+",
            filt,
            op(
                "*",
                vec![
                    ix("u", vec![json!("i")]),
                    plus(op("*", vec![json!("i"), json!(0.5)]), json!(1)),
                ],
            ),
        );
        let v = agree("band", &doc(9, 0, vec![du(9, rhs)], Value::Null));
        // Cell 1 receives no term: the additive identity, +0.0.
        assert_eq!(v[0].to_bits(), 0.0f64.to_bits());
    }
}

#[test]
fn cancelling_terms_fold_in_the_interpreters_order() {
    // Every term lands in cell 1, from a 2-D contracted box: the order
    // between `i` and `k` decides the sum (k fastest: 1, i fastest: 2).
    let body = ix(
        "u",
        vec![op(
            "-",
            vec![
                plus(op("*", vec![json!(2), json!("i")]), json!("k")),
                json!(2),
            ],
        )],
    );
    for reduce in ["+", "max", "min", "*"] {
        let rhs = faq(
            &["j"],
            &[("j", 1, 4), ("i", 1, 2), ("k", 1, 2)],
            reduce,
            eq(json!("j"), json!(1)),
            body.clone(),
        );
        let v = agree(reduce, &doc(4, 0, vec![du(4, rhs)], Value::Null));
        if reduce == "+" {
            assert_eq!(v[0], 1.0, "the k-fastest fold of [1e16, 1, -1e16, 1]");
        }
    }
    // Each cell its own run: cell i folds u[2i - 1], u[2i].
    let rhs = faq(
        &["j"],
        &[("j", 1, 4), ("i", 1, 2), ("k", 1, 2)],
        "+",
        eq(json!("j"), json!("i")),
        body,
    );
    agree("per-cell runs", &doc(4, 0, vec![du(4, rhs)], Value::Null));
}

#[test]
fn max_with_a_nan_in_the_window() {
    for reduce in ["max", "min"] {
        let rhs = faq(
            &["j"],
            &[("j", 1, 5), ("i", 1, 5), ("k", 1, 5)],
            reduce,
            eq(json!("j"), json!("i")),
            ix("u", vec![json!("k")]),
        );
        agree(reduce, &doc(5, 0, vec![du(5, rhs)], Value::Null));
    }
}

#[test]
fn two_dimensional_output_both_pinned_and_one_free() {
    let m = 3;
    // Both pinned: w'[a, b] = Σ_{i, k : a = i, b = 4 - k} u[i + k] w[k, i].
    let both = faq(
        &["a", "b"],
        &[("a", 1, m), ("b", 1, m), ("i", 1, m), ("k", 1, m)],
        "+",
        and(vec![
            eq(json!("a"), json!("i")),
            eq(json!("b"), op("-", vec![json!(4), json!("k")])),
        ]),
        op(
            "*",
            vec![
                ix("u", vec![plus(json!("i"), json!("k"))]),
                ix("w", vec![json!("k"), json!("i")]),
            ],
        ),
    );
    agree(
        "2-D both pinned",
        &doc(8, m, vec![dw(m, both)], Value::Null),
    );
    // `a` free: w'[a, b] = Σ_{i : b = i + 1} w[a, i] u[a + i].
    let free = faq(
        &["a", "b"],
        &[("a", 1, m), ("b", 1, m), ("i", 1, m)],
        "+",
        eq(json!("b"), plus(json!("i"), json!(1))),
        op(
            "*",
            vec![
                ix("w", vec![json!("a"), json!("i")]),
                ix("u", vec![plus(json!("a"), json!("i"))]),
            ],
        ),
    );
    agree("2-D one free", &doc(8, m, vec![dw(m, free)], Value::Null));
}

#[test]
fn out_of_range_and_non_integer_pins_are_skipped() {
    for e in [
        op("/", vec![json!("i"), json!(2)]),
        plus(json!("i"), json!(3)),
        op("-", vec![json!("i"), json!(4)]),
    ] {
        let rhs = faq(
            &["j"],
            &[("j", 1, 8), ("i", 1, 8)],
            "+",
            eq(json!("j"), e),
            ix("u", vec![json!("i")]),
        );
        agree("out of range", &doc(8, 0, vec![du(8, rhs)], Value::Null));
    }
}

#[test]
fn equality_with_a_comparison_folds_ascending() {
    // j == i and k <= j: not a scan; each cell folds u[1..=j] ascending.
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 8), ("k", 1, 8)],
        "+",
        and(vec![
            eq(json!("j"), json!("i")),
            op("<=", vec![json!("k"), json!("j")]),
        ]),
        ix("u", vec![json!("k")]),
    );
    agree("== and <=", &doc(8, 0, vec![du(8, rhs)], Value::Null));
    // The comparison against the contracted index only, the other way round.
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 8), ("k", 1, 8)],
        "+",
        and(vec![
            op(">=", vec![json!("k"), json!("i")]),
            eq(json!("i"), json!("j")),
        ]),
        ix("u", vec![json!("k")]),
    );
    agree(">= and ==", &doc(8, 0, vec![du(8, rhs)], Value::Null));
}

#[test]
fn an_index_pinned_twice_tests_the_second_conjunct() {
    let rhs = faq(
        &["j"],
        &[("j", 1, 6), ("i", 1, 6), ("k", 1, 6)],
        "+",
        and(vec![
            eq(json!("j"), json!("i")),
            eq(json!("j"), op("-", vec![json!(7), json!("k")])),
        ]),
        op(
            "*",
            vec![ix("u", vec![json!("k")]), ix("u", vec![json!("i")])],
        ),
    );
    agree("pinned twice", &doc(6, 0, vec![du(6, rhs)], Value::Null));
}

#[test]
fn run_time_conjuncts_and_run_time_pins() {
    // A remaining conjunct that reads the state: a run-time mask.
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 7)],
        "+",
        and(vec![
            eq(json!("j"), plus(json!("i"), json!(1))),
            op(">", vec![ix("u", vec![json!("i")]), json!(0)]),
        ]),
        ix("u", vec![json!("i")]),
    );
    agree(
        "run-time conjunct",
        &doc(8, 0, vec![du(8, rhs)], Value::Null),
    );
    // A pin that reads the state: no build-time map; the dense lowering.
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 8)],
        "+",
        eq(json!("j"), ix("u", vec![json!("i")])),
        ix("u", vec![json!("i")]),
    );
    let d = doc(8, 0, vec![du(8, rhs)], Value::Null);
    let native = program(&d, Compiler::Native);
    let interp = program(&d, Compiler::Interpreter);
    for pattern in [&[3.0, 1.0, 2.5, 8.0, -1.0, 2.0][..], &CANCEL[..]] {
        let u = state(&native, pattern);
        let (a, b) = (eval(&native, &u), eval(&interp, &u));
        for (x, y) in a.iter().zip(&b) {
            assert_eq!(x.to_bits(), y.to_bits(), "run-time pin");
        }
    }
}

#[test]
fn a_pin_through_a_build_time_gather_and_a_parameter() {
    // j == perm[i] + off: a const gather and a parameter.
    let perm: Vec<i64> = vec![3, 1, 4, 1, 5, 9, 2, 6];
    let extra = json!({
        "perm": {"type": "unknown", "units": "1", "shape": ["x"]},
        "off": {"type": "parameter", "units": "1", "default": -1.0}
    });
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 8)],
        "+",
        eq(json!("j"), plus(ix("perm", vec![json!("i")]), json!(0))),
        ix("u", vec![json!("i")]),
    );
    let eqs = vec![
        json!({"lhs": "perm", "rhs": {"op": "const", "args": [], "value": perm}}),
        du(8, rhs),
    ];
    agree("const gather pin", &doc(8, 0, eqs.clone(), extra.clone()));
    // A tunable parameter is a run-time value: the dense lowering, same bits.
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 8)],
        "+",
        eq(json!("j"), plus(json!("i"), json!("off"))),
        ix("u", vec![json!("i")]),
    );
    let eqs = vec![
        json!({"lhs": "perm", "rhs": {"op": "const", "args": [], "value": perm}}),
        du(8, rhs),
    ];
    agree("parameter pin", &doc(8, 0, eqs, extra));
}

/// The band-transpose shape: three faqs summed in one right-hand side, as
/// an expression of whole-array terms and as a `makearray` region.
fn band_transpose(n: i64) -> Value {
    let i = || json!("i");
    let term = |coef: Value, filt: Value| {
        faq(
            &["j"],
            &[("j", 1, n), ("i", 1, n)],
            "+",
            filt,
            op("*", vec![coef, ix("u", vec![i()])]),
        )
    };
    let a = op("+", vec![json!(1.0), op("*", vec![json!(0.001), i()])]);
    let b = op("-", vec![json!(2.0), op("/", vec![i(), json!(n)])]);
    let c = op(
        "+",
        vec![
            json!(0.5),
            op("*", vec![json!(1e-6), op("*", vec![i(), i()])]),
        ],
    );
    let sum = op(
        "+",
        vec![
            term(a, eq(plus(i(), json!(1)), json!("j"))),
            term(b, eq(op("-", vec![i(), json!(1)]), json!("j"))),
            term(c, eq(i(), json!("j"))),
        ],
    );
    doc(
        n,
        0,
        vec![json!({"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": op("-", vec![sum])})],
        Value::Null,
    )
}

#[test]
fn several_scatters_in_one_expression_and_a_makearray_region() {
    agree("band_transpose", &band_transpose(50));
    let n = 12;
    let region = faq(
        &["j"],
        &[("j", 1, n), ("i", 1, n)],
        "+",
        eq(plus(json!("i"), json!(1)), json!("j")),
        ix("u", vec![json!("i")]),
    );
    let rhs = json!({"op": "makearray", "args": [], "regions": [[[1, n]], [[1, n]]],
        "values": [0, region]});
    let d = doc(
        n,
        0,
        vec![json!({"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": rhs})],
        Value::Null,
    );
    agree("makearray region", &d);
}

#[test]
fn a_million_cell_transpose_builds_and_runs_in_one_pass() {
    let n = 1_000_000;
    let d = band_transpose(n);
    let t0 = std::time::Instant::now();
    let native = program(&d, Compiler::Native);
    let build = t0.elapsed();
    let u: Vec<f64> = (0..n).map(|k| 1.0 + (k % 7) as f64).collect();
    let mut ws = native.new_workspace();
    let p = native.parameter_vector(&HashMap::new()).expect("defaults");
    let fs = native.default_forcing();
    let mut out = vec![0.0; n as usize];
    native
        .eval_into(&u, &[], &p, 0.0, &fs, &mut out, &mut ws)
        .expect("eval");
    let before = allocs();
    let t1 = std::time::Instant::now();
    for _ in 0..5 {
        native
            .eval_into(&u, &[], &p, 0.0, &fs, &mut out, &mut ws)
            .expect("eval");
    }
    let call = t1.elapsed() / 5;
    assert_eq!(allocs() - before, 0, "a warm call allocated");
    eprintln!("N = {n}: build {build:?}, call {call:?}");
    // A hand loop, folded in the same order (ascending i into each cell).
    let nf = n as f64;
    let mut want = vec![0.0f64; n as usize];
    for (k, w) in want.iter_mut().enumerate() {
        let j = k as i64 + 1;
        let mut acc = 0.0f64;
        if j >= 2 {
            let i = (j - 1) as f64;
            acc += (1.0 + 0.001 * i) * u[(j - 2) as usize];
        }
        let mut b = 0.0f64;
        if j < n {
            let i = (j + 1) as f64;
            b += (2.0 - i / nf) * u[j as usize];
        }
        let jf = j as f64;
        let c = 0.0 + (0.5 + 1e-6 * (jf * jf)) * u[k];
        *w = -((acc + b) + c);
    }
    for (k, (x, y)) in out.iter().zip(&want).enumerate() {
        assert_eq!(
            x.to_bits(),
            y.to_bits(),
            "cell {k}: native {x:e} vs hand loop {y:e}"
        );
    }
}

#[test]
fn a_million_cell_non_shift_scatter_builds_through_the_tuple_list() {
    // out[j] = Σ_{i : j = i / 2} u[i] (i/2 is an integer at even i only):
    // not a unit shift, so the build-time scatter map, at a size whose dense
    // box the dense lowering refuses.
    let n: i64 = 1_000_000;
    let rhs = faq(
        &["j"],
        &[("j", 1, n), ("i", 1, n)],
        "+",
        eq(json!("j"), op("/", vec![json!("i"), json!(2)])),
        ix("u", vec![json!("i")]),
    );
    let d = doc(n, 0, vec![du(n, rhs)], Value::Null);
    let native = program(&d, Compiler::Native);
    let u: Vec<f64> = (0..n).map(|k| CANCEL[k as usize % 4]).collect();
    let mut ws = native.new_workspace();
    let p = native.parameter_vector(&HashMap::new()).expect("defaults");
    let fs = native.default_forcing();
    let mut out = vec![0.0; n as usize];
    native
        .eval_into(&u, &[], &p, 0.0, &fs, &mut out, &mut ws)
        .expect("eval");
    let before = allocs();
    native
        .eval_into(&u, &[], &p, 0.0, &fs, &mut out, &mut ws)
        .expect("eval");
    assert_eq!(allocs() - before, 0, "a warm call allocated");
    for (k, x) in out.iter().enumerate() {
        let j = k + 1;
        let want = if 2 * j <= n as usize {
            0.0 + u[2 * j - 1]
        } else {
            0.0
        };
        assert_eq!(x.to_bits(), want.to_bits(), "cell {j}");
    }
}

/// A ragged range whose parent is contracted: `pm[j] = Σ_{r, k ∈ row r :
/// j = floor((mem[r, k] - 1) / 3) + 1} W[mem] s[mem]` over `m` members in
/// rows of length 3, 1, 4, 2, …, the members a scrambled numbering. Returns
/// the document, the members row by row, and `W`.
fn ragged_parent_doc(m: usize) -> (Value, Vec<Vec<usize>>, Vec<f64>) {
    let lens = [3usize, 1, 4, 2];
    let mut rows: Vec<Vec<usize>> = Vec::new();
    let mut t = 0usize;
    while t < m {
        let len = lens[rows.len() % 4].min(m - t);
        rows.push((t..t + len).map(|x| (x * 7919) % m + 1).collect());
        t += len;
    }
    let max_len = 4;
    let row_len: Vec<usize> = rows.iter().map(Vec::len).collect();
    let row_mem: Vec<Vec<usize>> = rows
        .iter()
        .map(|r| {
            (0..max_len)
                .map(|k| r.get(k).copied().unwrap_or(0))
                .collect()
        })
        .collect();
    let w: Vec<f64> = (0..m)
        .map(|x| [1e16, 1.0, -1e16, 3.0, 0.5][x % 5] * (1.0 + (x % 7) as f64))
        .collect();
    let n_out = m.div_ceil(3);
    let mem = || ix("rowMem", vec![json!("r"), json!("k")]);
    let e = plus(
        op(
            "floor",
            vec![op("/", vec![op("-", vec![mem(), json!(1)]), json!(3)])],
        ),
        json!(1),
    );
    let rhs = json!({"op": "faq", "args": [], "output_idx": ["j"], "reduce": "+",
        "ranges": {"j": {"from": "nout"}, "r": {"from": "rows"},
                   "k": {"from": "row_members", "of": ["r"]}},
        "filter": eq(json!("j"), e),
        "expr": op("*", vec![ix("W", vec![mem()]), ix("s", vec![mem()])])});
    let d = json!({
        "esm": "1.3.0",
        "metadata": {"name": "ragged_parent_scatter", "authors": ["test"]},
        "index_sets": {
            "ns": {"kind": "interval", "size": m},
            "nout": {"kind": "interval", "size": n_out},
            "rows": {"kind": "interval", "size": rows.len()},
            "maxLen": {"kind": "interval", "size": max_len},
            "row_members": {"kind": "ragged", "of": ["rows"], "offsets": "rowLen",
                            "values": "rowMem"}
        },
        "models": {"M": {
            "variables": {
                "s": {"type": "unknown", "units": "1", "shape": ["ns"], "default": 1.0},
                "pm": {"type": "unknown", "units": "1", "shape": ["nout"], "default": 0.0},
                "rowLen": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "rowMem": {"type": "unknown", "units": "1", "shape": ["rows", "maxLen"]},
                "W": {"type": "unknown", "units": "1", "shape": ["ns"]}
            },
            "equations": [
                {"lhs": faq(&["q"], &[("q", 1, m as i64)], "+", Value::Null,
                    json!({"op": "D", "args": [ix("s", vec![json!("q")])], "wrt": "t"})),
                 "rhs": faq(&["q"], &[("q", 1, m as i64)], "+", Value::Null, json!(0.0))},
                {"lhs": "rowLen", "rhs": {"op": "const", "args": [], "value": row_len}},
                {"lhs": "rowMem", "rhs": {"op": "const", "args": [], "value": row_mem}},
                {"lhs": "W", "rhs": {"op": "const", "args": [], "value": w}},
                {"lhs": faq(&["j"], &[("j", 1, n_out as i64)], "+", Value::Null,
                    json!({"op": "D", "args": [ix("pm", vec![json!("j")])], "wrt": "t"})),
                 "rhs": rhs}
            ]
        }}
    });
    (d, rows, w)
}

#[test]
fn a_ragged_range_under_a_contracted_parent_scatters_in_one_pass() {
    // Bits against the interpreter at a size it walks quickly.
    let (d, _, _) = ragged_parent_doc(60);
    agree("ragged contracted parent", &d);

    // Build time grows linearly: a per-cell walk of the whole nest would
    // grow tenfold per cell count, a hundredfold per tenfold in size.
    let mut builds = Vec::new();
    for m in [100_000usize, 1_000_000] {
        let (d, rows, w) = ragged_parent_doc(m);
        let t0 = std::time::Instant::now();
        let native = program(&d, Compiler::Native);
        builds.push(t0.elapsed().as_secs_f64());
        let n = native.n_states();
        let u = vec![1.0; n];
        let out = eval(&native, &u);
        // The interpreter's order: rows ascending, each row's members
        // ascending; each cell folds its terms from +0.0.
        let n_out = m.div_ceil(3);
        let mut want = vec![0.0f64; n_out];
        for row in &rows {
            for &mem in row {
                let j = (mem - 1) / 3;
                want[j] += w[mem - 1] * 1.0;
            }
        }
        let pm = native
            .state_layout()
            .iter()
            .find(|b| b.name == "pm" || b.name.ends_with(".pm"))
            .expect("pm block")
            .flat_offset;
        let got = &out[pm..pm + n_out];
        for (j, (x, y)) in got.iter().zip(&want).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "m = {m}, cell {j}: {x:e} vs {y:e}"
            );
        }
    }
    eprintln!("ragged contracted parent builds: {builds:?}");
    assert!(
        builds[1] < 30.0 * builds[0],
        "build grew superlinearly: {builds:?}"
    );
}

#[test]
fn a_float32_document_pins_and_filters_at_binary32() {
    // Under `element_type: "Float32"` every literal is rounded on entry and
    // every operation, `==` included, is binary32: the map from points to
    // cells must be the interpreter's binary32 one.
    let n = 40;
    let cases = [
        // i·0.1·10 is an integer at different `i` in binary32 and binary64.
        eq(
            json!("j"),
            op("*", vec![op("*", vec![json!("i"), json!(0.1)]), json!(10)]),
        ),
        // A bare literal that is 2 only once rounded to binary32.
        eq(json!("j"), json!(2.00000001)),
        // The same through a negation, and through a build-time comparison.
        eq(json!("j"), op("-", vec![json!(-3.00000001)])),
        and(vec![
            eq(json!("j"), json!("i")),
            op("<=", vec![json!("i"), json!(3.00000001)]),
        ]),
        and(vec![
            eq(json!("j"), json!("i")),
            op("==", vec![json!("i"), json!(5.0000001)]),
        ]),
    ];
    for filt in cases {
        let rhs = faq(
            &["j"],
            &[("j", 1, n), ("i", 1, n)],
            "+",
            filt.clone(),
            ix("u", vec![json!("i")]),
        );
        let mut d = doc(n, 0, vec![du(n, rhs)], Value::Null);
        d["domain"] = json!({"element_type": "Float32"});
        agree(&format!("Float32 {filt}"), &d);
    }
}

#[test]
fn nested_ands_flatten_left_to_right() {
    // and(and(j == i + 1, u[i] > 0), k < 3): the pin sits inside an inner
    // `and`; a run-time conjunct beside it and a build-time one outside.
    let filt = and(vec![
        and(vec![
            eq(json!("j"), plus(json!("i"), json!(1))),
            op(">", vec![ix("u", vec![json!("i")]), json!(0)]),
        ]),
        op("<", vec![json!("k"), json!(3)]),
    ]);
    let rhs = faq(
        &["j"],
        &[("j", 1, 8), ("i", 1, 7), ("k", 1, 4)],
        "+",
        filt,
        op(
            "*",
            vec![ix("u", vec![json!("i")]), ix("u", vec![json!("k")])],
        ),
    );
    agree("nested and", &doc(8, 0, vec![du(8, rhs)], Value::Null));
    // A second pin of `j` in a later, nested conjunct is an ordinary filter.
    let filt = and(vec![
        eq(json!("j"), json!("i")),
        and(vec![
            eq(json!("j"), op("-", vec![json!(7), json!("k")])),
            op(">=", vec![json!("k"), json!(2)]),
        ]),
    ]);
    let rhs = faq(
        &["j"],
        &[("j", 1, 6), ("i", 1, 6), ("k", 1, 6)],
        "+",
        filt,
        op(
            "*",
            vec![ix("u", vec![json!("k")]), ix("u", vec![json!("i")])],
        ),
    );
    agree(
        "nested second pin",
        &doc(6, 0, vec![du(6, rhs)], Value::Null),
    );
}

#[test]
fn a_free_index_read_by_a_conjunct_or_a_ragged_bound() {
    let m = 4;
    // `a` free, read by a build-time conjunct and by a run-time one: the
    // points are placed once and each free cell re-tests those conjuncts.
    for extra in [
        op("<=", vec![json!("i"), json!("a")]),
        op("!=", vec![json!("a"), json!(2)]),
        op(">", vec![ix("w", vec![json!("a"), json!("i")]), json!(0)]),
    ] {
        let rhs = faq(
            &["a", "b"],
            &[("a", 1, m), ("b", 1, m), ("i", 1, m), ("k", 1, 2)],
            "+",
            and(vec![
                eq(json!("b"), plus(json!("i"), json!(1))),
                extra.clone(),
            ]),
            op(
                "*",
                vec![
                    ix("w", vec![json!("a"), json!("i")]),
                    ix("u", vec![plus(json!("k"), json!("i"))]),
                ],
            ),
        );
        agree(
            &format!("free conjunct {extra}"),
            &doc(8, m, vec![dw(m, rhs)], Value::Null),
        );
    }

    // A ragged range under the free output index `a`: each free cell walks
    // its own row. pm[a, b] = Σ_{k ∈ row a : b = k} s[mem[a, k]] (k + 1/2).
    let rows: Vec<Vec<usize>> = vec![vec![2, 1, 2], vec![3], vec![1, 3, 3, 2], vec![]];
    let max_len = 4;
    let row_len: Vec<usize> = rows.iter().map(Vec::len).collect();
    let row_mem: Vec<Vec<usize>> = rows
        .iter()
        .map(|r| {
            (0..max_len)
                .map(|k| r.get(k).copied().unwrap_or(1))
                .collect()
        })
        .collect();
    let mem = || ix("rowMem", vec![json!("a"), json!("k")]);
    let rhs = json!({"op": "faq", "args": [], "output_idx": ["a", "b"], "reduce": "+",
        "ranges": {"a": {"from": "rows"}, "b": {"from": "cols"},
                   "k": {"from": "row_members", "of": ["a"]}},
        "filter": eq(json!("b"), json!("k")),
        "expr": op("*", vec![ix("s", vec![mem()]), plus(json!("k"), json!(0.5))])});
    let d = json!({
        "esm": "1.3.0",
        "metadata": {"name": "ragged_free_scatter", "authors": ["test"]},
        "index_sets": {
            "rows": {"kind": "interval", "size": rows.len()},
            "cols": {"kind": "interval", "size": 3},
            "maxLen": {"kind": "interval", "size": max_len},
            "row_members": {"kind": "ragged", "of": ["rows"], "offsets": "rowLen",
                            "values": "rowMem"}
        },
        "models": {"M": {
            "variables": {
                "s": {"type": "unknown", "units": "1", "shape": ["cols"], "default": 1.0},
                "pm": {"type": "unknown", "units": "1", "shape": ["rows", "cols"], "default": 0.0},
                "rowLen": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "rowMem": {"type": "unknown", "units": "1", "shape": ["rows", "maxLen"]}
            },
            "equations": [
                {"lhs": faq(&["q"], &[("q", 1, 3)], "+", Value::Null,
                    json!({"op": "D", "args": [ix("s", vec![json!("q")])], "wrt": "t"})),
                 "rhs": faq(&["q"], &[("q", 1, 3)], "+", Value::Null, json!(0.0))},
                {"lhs": "rowLen", "rhs": {"op": "const", "args": [], "value": row_len}},
                {"lhs": "rowMem", "rhs": {"op": "const", "args": [], "value": row_mem}},
                {"lhs": faq(&["a", "b"], &[("a", 1, rows.len() as i64), ("b", 1, 3)], "+",
                    Value::Null,
                    json!({"op": "D", "args": [ix("pm", vec![json!("a"), json!("b")])],
                           "wrt": "t"})),
                 "rhs": rhs}
            ]
        }}
    });
    agree("ragged under a free index", &d);
}
