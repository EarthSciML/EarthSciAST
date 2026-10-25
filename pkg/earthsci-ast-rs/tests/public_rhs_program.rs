//! The public right-hand side (API_SPEC §5.8, CONFORMANCE_SPEC §5.51): a
//! program built once, shared across threads, evaluated with one workspace
//! per thread, reading its forcing from an epoch-stamped forcing set.
//!
//! * the static thread-safety contract;
//! * equivalence with the `debug_eval_rhs_into` seam on a taped scratch (and,
//!   under `interpreter`, with the per-cell oracle);
//! * 16 threads x 1000 calls at seeded random inputs, bitwise equal to the
//!   serial results;
//! * history independence, the stale-forcing negative control, fault
//!   isolation across threads, and zero allocation on a warm call;
//! * the parameter vector, the state layout and the array-parameter opt-in.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::HashMap;
use std::sync::Arc;

use earthsci_ast::{
    AxisCut, Compiler, Decomposition, ForcingSet, LaneProgram, ProblemOptions, RhsError,
    RhsProgram, RhsSelection, RhsWorkspace, SlotKind, TileBox, TileProgram, esm_problem,
    rhs_program,
};
use serde_json::json;

struct Counting;

thread_local! {
    /// Allocations made by this thread (tests run on several threads).
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

// ---------------------------------------------------------------------------
// The static contract (RFC test 1).
// ---------------------------------------------------------------------------

const _: () = {
    const fn shared<T: Send + Sync + Clone>() {}
    const fn sendable<T: Send>() {}
    shared::<RhsProgram>();
    shared::<TileProgram>();
    shared::<LaneProgram>();
    shared::<ForcingSet>();
    sendable::<RhsWorkspace>();
    sendable::<earthsci_ast::LaneInputs>();
};

/// Resolves only when `T` is not `Sync`: with a `Sync` `T` both impls apply
/// and the call below is ambiguous.
trait AmbiguousIfSync<A> {
    fn check() {}
}
impl<T: ?Sized> AmbiguousIfSync<()> for T {}
impl<T: ?Sized + Sync> AmbiguousIfSync<u8> for T {}
const _: fn() = || <RhsWorkspace as AmbiguousIfSync<_>>::check();

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

fn idx1(v: &str, e: serde_json::Value) -> serde_json::Value {
    json!({"op": "index", "args": [v, e]})
}

/// A 1-D stencil on `n` cells forced by a field `F[x]` and a scalar `s`, both
/// refreshed from outside the model (with defaults until data arrives).
fn forced_1d(n: i64) -> serde_json::Value {
    let i = || json!("i");
    let im1 = json!({"op": "-", "args": ["i", 1]});
    let ip1 = json!({"op": "+", "args": ["i", 1]});
    let refresh =
        json!({"kind": "schedule", "interval": 60.0, "handler": {"handler_id": "reload"}});
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "forced_1d", "authors": ["test"]},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "kappa": {"type": "parameter", "units": "1", "default": 0.5},
                "decay": {"type": "parameter", "units": "1", "default": 0.1},
                "F": {"type": "parameter", "units": "1", "shape": ["x"], "default": 0.25,
                      "update": refresh},
                "s": {"type": "parameter", "units": "1", "shape": [], "default": 2.0,
                      "update": refresh}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "D", "args": [idx1("u", i())], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "+", "args": [
                            {"op": "*", "args": ["kappa", {"op": "+", "args": [
                                idx1("u", im1), {"op": "*", "args": [-2, idx1("u", i())]}, idx1("u", ip1)]}]},
                            {"op": "*", "args": ["s", idx1("F", i())]},
                            {"op": "*", "args": [-1, "decay", idx1("u", i())]}
                        ]}}
            }]
        }}
    })
}

/// A 2-D field `u[x, y]` forced by `G[x, y]`, with a shift along `x`.
fn forced_2d(nx: i64, ny: i64) -> serde_json::Value {
    let ix = |v: &str, a: serde_json::Value, b: serde_json::Value| json!({"op": "index", "args": [v, a, b]});
    let refresh =
        json!({"kind": "schedule", "interval": 60.0, "handler": {"handler_id": "reload"}});
    let ranges = json!({"i": {"from": "x"}, "j": {"from": "y"}});
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "forced_2d", "authors": ["test"]},
        "index_sets": {"x": {"kind": "interval", "size": nx}, "y": {"kind": "interval", "size": ny}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 1.0},
                "k": {"type": "parameter", "units": "1", "default": 0.3},
                "G": {"type": "parameter", "units": "1", "shape": ["x", "y"], "default": 1.5,
                      "update": refresh}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"], "ranges": ranges,
                        "expr": {"op": "D", "args": [ix("u", json!("i"), json!("j"))], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"], "ranges": ranges,
                        "expr": {"op": "+", "args": [
                            ix("G", json!("i"), json!("j")),
                            {"op": "*", "args": [-1, "k", ix("u", json!("i"), json!("j"))]},
                            ix("u", json!({"op": "-", "args": ["i", 1]}), json!("j"))
                        ]}}
            }]
        }}
    })
}

/// `D(u[i]) = w[i] * u[i] + index(w, k)`: a shaped parameter with a default
/// (array data), and a gather of it at a parameter-chosen index, which is a
/// fail-closed fault when `k` is outside `1..n`.
fn weighted(n: i64) -> serde_json::Value {
    let w: Vec<f64> = (1..=n).map(|i| 0.5 + 0.125 * i as f64).collect();
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "weighted", "authors": ["test"]},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "w": {"type": "parameter", "units": "1", "shape": ["x"], "default": w},
                "k": {"type": "parameter", "units": "1", "default": 1.0}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "D", "args": [idx1("u", json!("i"))], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "+", "args": [
                            {"op": "*", "args": [idx1("w", json!("i")), idx1("u", json!("i"))]},
                            idx1("w", json!("k"))
                        ]}}
            }]
        }}
    })
}

fn problem(doc: &serde_json::Value, compiler: Compiler, runtime: bool) -> earthsci_ast::EsmProblem {
    esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            runtime_array_parameters: runtime,
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("builds: {e}"))
}

fn program(doc: &serde_json::Value, compiler: Compiler) -> RhsProgram {
    rhs_program(&problem(doc, compiler, false)).expect("program")
}

/// SplitMix64: a fixed-seed stream with no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `[lo, hi)`.
    fn f(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// The index of the slot named `name` (or ending `.name`).
fn slot(prog: &RhsProgram, name: &str) -> usize {
    prog.forcing_slots()
        .iter()
        .position(|s| s.name == name || s.name.ends_with(&format!(".{name}")))
        .unwrap_or_else(|| panic!("no forcing slot {name}: {:?}", prog.forcing_slots()))
}

fn eval(prog: &RhsProgram, u: &[f64], p: &[f64], t: f64, fs: &ForcingSet) -> Vec<f64> {
    let mut ws = prog.new_workspace();
    let mut du = vec![f64::NAN; prog.n_states()];
    prog.eval_into(u, &[], p, t, fs, &mut du, &mut ws)
        .expect("eval");
    du
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

// ---------------------------------------------------------------------------
// Equivalence (RFC test 2).
// ---------------------------------------------------------------------------

/// `eval_into` on the Problem's own forcing equals `debug_eval_rhs_into` on a
/// taped scratch of the Problem's compiled model, bit for bit; under
/// `interpreter` it equals the per-cell oracle.
#[test]
fn eval_into_equals_the_debug_seam() {
    for doc in [forced_1d(24), forced_2d(6, 5), weighted(9)] {
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let prob = problem(&doc, compiler, false);
            let prog = rhs_program(&prob).expect("program");
            let c = prob.debug_array_compiled().expect("array backend");
            assert_eq!(prog.n_states(), c.n_states());
            let mut rng = Rng(7);
            let fs = prog.default_forcing();
            for _ in 0..5 {
                let u: Vec<f64> = (0..prog.n_states()).map(|_| rng.f(-1.0, 2.0)).collect();
                let t = rng.f(0.0, 10.0);
                let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
                let got = eval(&prog, &u, &p, t, &fs);
                let named: HashMap<String, f64> = prog
                    .parameters()
                    .iter()
                    .zip(&p)
                    .map(|(s, v)| (s.name.rsplit('.').next().unwrap().to_string(), *v))
                    .collect();
                let want = {
                    let _env = c.debug_precision_env().enter();
                    match compiler {
                        Compiler::Native => {
                            let pv = c.debug_resolve_params(&named);
                            let mut scratch = c.debug_new_scratch_taped().expect("taped");
                            let mut dy = vec![f64::NAN; c.n_states()];
                            c.debug_eval_rhs_into(
                                &u,
                                t,
                                &pv,
                                &mut dy,
                                &mut scratch,
                                &mut Default::default(),
                            );
                            dy
                        }
                        _ => c.debug_eval_rhs(&u, t, &named, true).0,
                    }
                };
                assert_eq!(bits(&got), bits(&want), "{compiler}: {doc}");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Concurrency (RFC test 3).
// ---------------------------------------------------------------------------

struct Call {
    u: Vec<f64>,
    p: Vec<f64>,
    t: f64,
    set: usize,
}

fn draws(prog: &RhsProgram, n: usize, seed: u64) -> Vec<Call> {
    let mut rng = Rng(seed);
    let base = prog.parameter_vector(&HashMap::new()).expect("defaults");
    (0..n)
        .map(|_| Call {
            u: (0..prog.n_states()).map(|_| rng.f(-1.0, 2.0)).collect(),
            p: base.iter().map(|&d| d * rng.f(0.5, 1.5)).collect(),
            t: rng.f(0.0, 100.0),
            set: (rng.next() % 3) as usize,
        })
        .collect()
}

/// Three forcing sets: the Problem's, and two that differ in one buffer.
fn three_sets(prog: &RhsProgram, name: &str) -> Vec<ForcingSet> {
    let fs = prog.default_forcing();
    let k = slot(prog, name);
    let n = prog.forcing_slots()[k].len();
    let a: Arc<[f64]> = (0..n).map(|i| 0.1 * i as f64 - 0.4).collect();
    let b: Arc<[f64]> = (0..n).map(|i| 1.0 / (1.0 + i as f64)).collect();
    vec![
        fs.clone(),
        fs.replace(k, a).expect("replace"),
        fs.replace(k, b).expect("replace"),
    ]
}

/// `threads` threads evaluate a shuffled deal of `calls`, each with its own
/// workspace, and every result equals the serial one bit for bit.
fn concurrent_matches_serial(
    prog: &RhsProgram,
    sets: &[ForcingSet],
    calls: &[Call],
    threads: usize,
) {
    let mut ws = prog.new_workspace();
    let serial: Vec<Vec<f64>> = calls
        .iter()
        .map(|c| {
            let mut du = vec![f64::NAN; prog.n_states()];
            prog.eval_into(&c.u, &[], &c.p, c.t, &sets[c.set], &mut du, &mut ws)
                .expect("serial eval");
            du
        })
        .collect();
    let mut order: Vec<usize> = (0..calls.len()).collect();
    let mut rng = Rng(0xC0FFEE);
    for i in (1..order.len()).rev() {
        order.swap(i, (rng.next() % (i as u64 + 1)) as usize);
    }
    let deal: Vec<Vec<usize>> = (0..threads)
        .map(|w| order.iter().skip(w).step_by(threads).copied().collect())
        .collect();
    let results: Vec<Vec<(usize, Vec<f64>)>> = std::thread::scope(|s| {
        let handles: Vec<_> = deal
            .iter()
            .map(|mine| {
                let prog = prog.clone();
                s.spawn(move || {
                    let mut ws = prog.new_workspace();
                    mine.iter()
                        .map(|&k| {
                            let c = &calls[k];
                            let mut du = vec![f64::NAN; prog.n_states()];
                            prog.eval_into(&c.u, &[], &c.p, c.t, &sets[c.set], &mut du, &mut ws)
                                .expect("threaded eval");
                            (k, du)
                        })
                        .collect()
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("thread"))
            .collect()
    });
    let mut seen = 0;
    for (k, du) in results.into_iter().flatten() {
        assert_eq!(bits(&du), bits(&serial[k]), "call {k}");
        seen += 1;
    }
    assert_eq!(seen, calls.len());
}

#[test]
fn sixteen_threads_by_a_thousand_calls_equal_the_serial_results() {
    let prog = program(&forced_1d(48), Compiler::Native);
    let sets = three_sets(&prog, "F");
    let calls = draws(&prog, 16 * 1000, 11);
    concurrent_matches_serial(&prog, &sets, &calls, 16);
}

#[test]
fn threaded_two_d_and_interpreter_programs_equal_the_serial_results() {
    let prog = program(&forced_2d(8, 6), Compiler::Native);
    let sets = three_sets(&prog, "G");
    concurrent_matches_serial(&prog, &sets, &draws(&prog, 8 * 200, 12), 8);
    let prog = program(&forced_1d(12), Compiler::Interpreter);
    let sets = three_sets(&prog, "F");
    concurrent_matches_serial(&prog, &sets, &draws(&prog, 4 * 50, 13), 4);
}

/// A tile and a selected program share the whole program's forcing sets
/// and are as thread-safe.
#[test]
fn threaded_tiles_equal_the_serial_results() {
    let prog = program(&forced_1d(32), Compiler::Native);
    let sets = three_sets(&prog, "F");
    let op = prog.select(&RhsSelection::default()).expect("select");
    assert_eq!(op.forcing_slots(), prog.forcing_slots());
    let dec = Decomposition {
        axes: vec![AxisCut {
            index_set: "x".to_string(),
            period: None,
        }],
        faces: Vec::new(),
    };
    let tile = op
        .tile(
            &dec,
            &TileBox {
                owned: vec![("x".to_string(), 9..=16)],
                storage: vec![("x".to_string(), 8..=17)],
            },
        )
        .expect("tile");
    let calls = draws(&prog, 400, 21);
    let lay = tile.layout().clone();
    let run = |ws: &mut RhsWorkspace, c: &Call| {
        let mut du = vec![f64::NAN; lay.u_len];
        tile.eval_into(&c.u[7..17], &[], &c.p, c.t, &sets[c.set], &mut du, ws)
            .expect("tile eval");
        du
    };
    let mut ws = tile.new_workspace();
    let serial: Vec<Vec<f64>> = calls.iter().map(|c| run(&mut ws, c)).collect();
    // The tile's owned rows equal the whole program's.
    for (c, du) in calls.iter().zip(&serial) {
        let g = eval(&op, &c.u, &c.p, c.t, &sets[c.set]);
        assert_eq!(bits(&du[1..9]), bits(&g[8..16]));
    }
    std::thread::scope(|s| {
        for w in 0..4 {
            let (calls, serial, run, tile) = (&calls, &serial, &run, &tile);
            s.spawn(move || {
                let mut ws = tile.new_workspace();
                for (k, c) in calls.iter().enumerate().skip(w).step_by(4) {
                    assert_eq!(bits(&run(&mut ws, c)[1..9]), bits(&serial[k][1..9]));
                }
            });
        }
    });
}

// ---------------------------------------------------------------------------
// History independence (RFC test 4) and the stale-forcing control (test 5).
// ---------------------------------------------------------------------------

#[test]
fn a_used_workspace_gives_the_bits_of_a_fresh_one() {
    let prog = program(&forced_1d(20), Compiler::Native);
    let sets = three_sets(&prog, "F");
    let calls = draws(&prog, 60, 31);
    let mut ws = prog.new_workspace();
    for c in &calls {
        let mut du = vec![f64::NAN; prog.n_states()];
        prog.eval_into(&c.u, &[], &c.p, c.t, &sets[c.set], &mut du, &mut ws)
            .expect("eval");
        let fresh = eval(&prog, &c.u, &c.p, c.t, &sets[c.set]);
        assert_eq!(bits(&du), bits(&fresh));
    }
}

/// Change one forcing buffer and keep `p`: the result changes. The same
/// change through today's taped debug scratch (forcing loads in the CONST
/// section, re-run only on a new `p`) reproduces the stale result, which is
/// what shows the check can fail.
#[test]
fn a_new_forcing_set_is_never_served_stale() {
    let doc = forced_1d(16);
    let prob = problem(&doc, Compiler::Native, false);
    let prog = rhs_program(&prob).expect("program");
    let u: Vec<f64> = (0..16).map(|i| 1.0 + 0.1 * f64::from(i)).collect();
    let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
    let k = slot(&prog, "F");
    let fs = prog.default_forcing();
    let fresh: Arc<[f64]> = (0..16).map(|i| 3.0 + f64::from(i)).collect();
    let fs2 = fs.replace(k, Arc::clone(&fresh)).expect("replace");
    assert_ne!(fs.epoch(), fs2.epoch());

    let mut ws = prog.new_workspace();
    let mut before = vec![0.0; 16];
    let mut after = vec![0.0; 16];
    prog.eval_into(&u, &[], &p, 0.0, &fs, &mut before, &mut ws)
        .expect("eval");
    prog.eval_into(&u, &[], &p, 0.0, &fs2, &mut after, &mut ws)
        .expect("eval");
    assert_ne!(bits(&before), bits(&after), "the new buffer was not read");
    assert_eq!(bits(&after), bits(&eval(&prog, &u, &p, 0.0, &fs2)));

    // The control: refresh the debug seam's forcing buffer in place.
    let c = prob.debug_array_compiled().expect("array backend");
    let pv = c.debug_resolve_params(&HashMap::new());
    let mut scratch = c.debug_new_scratch_taped().expect("taped");
    let mut d1 = vec![0.0; 16];
    let mut d2 = vec![0.0; 16];
    c.debug_eval_rhs_into(&u, 0.0, &pv, &mut d1, &mut scratch, &mut Default::default());
    assert_eq!(bits(&d1), bits(&before));
    let handle = c.forcing_handle();
    let key = handle
        .borrow()
        .keys()
        .find(|n| *n == "F" || n.ends_with(".F"))
        .cloned()
        .expect("F in the forcing buffer");
    handle.borrow_mut().insert(
        key,
        ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[16]), fresh.to_vec()).unwrap(),
    );
    c.debug_eval_rhs_into(&u, 0.0, &pv, &mut d2, &mut scratch, &mut Default::default());
    assert_eq!(
        bits(&d2),
        bits(&d1),
        "the taped debug scratch served the stale forcing"
    );
}

// ---------------------------------------------------------------------------
// Faults (RFC test 6).
// ---------------------------------------------------------------------------

/// `k` outside `1..n` gathers `w` out of range: every such call returns the
/// fault (the same `p` again included), on its own thread, while a call on
/// another thread at an in-range `k` is unaffected.
#[test]
fn a_fault_is_returned_on_its_own_thread_only() {
    let prog = program(&weighted(6), Compiler::Native);
    let fs = prog.default_forcing();
    let k_at = prog
        .parameters()
        .iter()
        .position(|s| s.name.ends_with('k'))
        .expect("k");
    let mut good = prog.parameter_vector(&HashMap::new()).expect("defaults");
    good[k_at] = 3.0;
    let mut bad = good.clone();
    bad[k_at] = 9.0;
    let u = vec![1.5; 6];
    let want = eval(&prog, &u, &good, 0.0, &fs);
    std::thread::scope(|s| {
        s.spawn(|| {
            let mut ws = prog.new_workspace();
            let mut du = vec![0.0; 6];
            for _ in 0..200 {
                match prog.eval_into(&u, &[], &bad, 0.0, &fs, &mut du, &mut ws) {
                    Err(RhsError::Fault { code, .. }) => {
                        assert_eq!(code, "E_TREEWALK_CONSTARRAY_OOB")
                    }
                    other => panic!("expected the fault, got {other:?}"),
                }
            }
        });
        s.spawn(|| {
            let mut ws = prog.new_workspace();
            let mut du = vec![0.0; 6];
            for _ in 0..200 {
                prog.eval_into(&u, &[], &good, 0.0, &fs, &mut du, &mut ws)
                    .expect("an in-range call does not fault");
                assert_eq!(bits(&du), bits(&want));
            }
        });
    });
    // The faulted workspace recovers on an in-range call.
    let mut ws = prog.new_workspace();
    let mut du = vec![0.0; 6];
    assert!(
        prog.eval_into(&u, &[], &bad, 0.0, &fs, &mut du, &mut ws)
            .is_err()
    );
    prog.eval_into(&u, &[], &good, 0.0, &fs, &mut du, &mut ws)
        .expect("recovers");
    assert_eq!(bits(&du), bits(&want));
}

// ---------------------------------------------------------------------------
// Allocation (RFC test 7).
// ---------------------------------------------------------------------------

#[test]
fn a_warm_call_allocates_nothing() {
    for doc in [forced_1d(64), forced_2d(8, 8)] {
        let prog = program(&doc, Compiler::Native);
        let sets = three_sets(
            &prog,
            if doc["metadata"]["name"] == "forced_1d" {
                "F"
            } else {
                "G"
            },
        );
        let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
        let u = vec![1.25; prog.n_states()];
        let mut du = vec![0.0; prog.n_states()];
        let mut ws = prog.new_workspace();
        for fs in &sets {
            prog.eval_into(&u, &[], &p, 0.0, fs, &mut du, &mut ws)
                .expect("eval");
        }
        let before = allocs();
        for k in 0..30 {
            // Switching sets re-runs the SEGMENT section, still allocation-free.
            prog.eval_into(
                &u,
                &[],
                &p,
                f64::from(k),
                &sets[k as usize % 3],
                &mut du,
                &mut ws,
            )
            .expect("eval");
        }
        assert_eq!(allocs() - before, 0, "a warm call allocated");
    }
}

// ---------------------------------------------------------------------------
// The surface: parameters, layout, workspace and forcing-set checks.
// ---------------------------------------------------------------------------

#[test]
fn the_parameter_vector_is_strict_and_positional() {
    let prog = program(&forced_1d(8), Compiler::Native);
    let names: Vec<&str> = prog.parameters().iter().map(|s| s.name.as_str()).collect();
    let mut sorted = names.clone();
    sorted.sort();
    assert_eq!(names, sorted, "sorted flattened names");
    let p = prog
        .parameter_vector(&HashMap::from([("kappa".to_string(), 4.0)]))
        .expect("an override by bare name");
    let at = names.iter().position(|n| n.ends_with("kappa")).unwrap();
    assert_eq!(p[at], 4.0);
    assert!(
        prog.parameter_vector(&HashMap::from([("nope".to_string(), 1.0)]))
            .is_err(),
        "an unknown key is refused"
    );
    assert_eq!(prog.state_layout().len(), 1);
    assert_eq!(prog.state_layout()[0].shape, vec![8]);
    assert_eq!(prog.state_layout()[0].flat_offset, 0);
    assert_eq!(prog.n_states(), prog.layout().u_len);
}

#[test]
fn foreign_workspaces_and_sets_are_refused() {
    let a = program(&forced_1d(8), Compiler::Native);
    let b = program(&forced_2d(4, 2), Compiler::Native);
    let fa = a.default_forcing();
    let fb = b.default_forcing();
    let p = a.parameter_vector(&HashMap::new()).expect("defaults");
    let u = vec![1.0; 8];
    let mut du = vec![0.0; 8];
    let mut wb = b.new_workspace();
    assert!(matches!(
        a.eval_into(&u, &[], &p, 0.0, &fa, &mut du, &mut wb),
        Err(RhsError::ForeignProgram { what: "workspace" })
    ));
    let mut wa = a.new_workspace();
    assert!(matches!(
        a.eval_into(&u, &[], &p, 0.0, &fb, &mut du, &mut wa),
        Err(RhsError::ForcingSignature { .. })
    ));
    assert!(matches!(
        a.eval_into(&u[..7], &[], &p, 0.0, &fa, &mut du, &mut wa),
        Err(RhsError::Shape {
            what: "u",
            expected: 8,
            got: 7
        })
    ));
    assert!(matches!(
        ForcingSet::new(&a, vec![]),
        Err(RhsError::Shape { .. })
    ));
    // A program moved, or cloned, after its workspace was made still owns it.
    let moved = Box::new(a);
    moved
        .eval_into(&u, &[], &p, 0.0, &fa, &mut du, &mut wa)
        .expect("moved program");
    let clone = (*moved).clone();
    clone
        .eval_into(&u, &[], &p, 0.0, &fa, &mut du, &mut wa)
        .expect("cloned program");
}

/// The result does not depend on the calling thread's ambient precision.
#[test]
fn the_program_arms_its_own_precision() {
    let prog = program(&forced_1d(8), Compiler::Native);
    let fs = prog.default_forcing();
    let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
    let u: Vec<f64> = (0..8).map(|i| 1.0 / (3.0 + f64::from(i))).collect();
    let want = eval(&prog, &u, &p, 0.0, &fs);
    let got = {
        let _f32 = earthsci_ast::precision::enter(earthsci_ast::precision::Precision::Float32);
        eval(&prog, &u, &p, 0.0, &fs)
    };
    assert_eq!(bits(&got), bits(&want));
}

/// `runtime_array_parameters`: the shaped parameter `w` is an
/// `ArrayParameter` slot seeded with its default, the program gives the
/// baked program's bits on it, and a new buffer is read.
#[test]
fn array_parameters_are_run_time_slots_on_request() {
    let doc = weighted(5);
    let baked = rhs_program(&problem(&doc, Compiler::Native, false)).expect("baked");
    assert!(baked.forcing_slots().is_empty());
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prog = rhs_program(&problem(&doc, compiler, true)).expect("runtime");
        let k = slot(&prog, "w");
        assert_eq!(prog.forcing_slots()[k].kind, SlotKind::ArrayParameter);
        assert_eq!(prog.forcing_slots()[k].shape, vec![5]);
        let fs = prog.default_forcing();
        let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
        assert_eq!(p.len(), baked.parameters().len());
        let u: Vec<f64> = (0..5).map(|i| 1.0 + f64::from(i)).collect();
        let pb = baked.parameter_vector(&HashMap::new()).expect("defaults");
        let fb = baked.default_forcing();
        assert_eq!(
            bits(&eval(&prog, &u, &p, 0.0, &fs)),
            bits(&eval(&baked, &u, &pb, 0.0, &fb)),
            "{compiler}"
        );
        let w: Arc<[f64]> = vec![2.0, 3.0, 5.0, 7.0, 11.0].into();
        let fs2 = fs.replace(k, Arc::clone(&w)).expect("replace");
        let du = eval(&prog, &u, &p, 0.0, &fs2);
        // k = 1: du[i] = w[i] u[i] + w[1].
        for i in 0..5 {
            assert_eq!(du[i], w[i] * u[i] + w[0], "{compiler} cell {i}");
        }
    }
}

/// `weighted(n)` with `w` given no value by the document.
fn weighted_without_w(n: i64) -> serde_json::Value {
    let mut doc = weighted(n);
    doc["models"]["M"]["variables"]["w"]
        .as_object_mut()
        .unwrap()
        .remove("default");
    doc
}

/// A shaped parameter whose array the caller supplies (`const_arrays`) is,
/// under `runtime_array_parameters`, an `ArrayParameter` slot whose default
/// buffer is the caller's array, and swapping it changes the result with no
/// rebuild. Off, the caller's array is baked in as before.
#[test]
fn caller_arrays_are_run_time_slots_on_request() {
    let caller = [1.5, 2.5, 4.0, 0.25, 3.0];
    let make = |doc: &serde_json::Value, compiler: Compiler, runtime: bool| {
        let arr = ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[5]), caller.to_vec()).unwrap();
        esm_problem(
            doc,
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(compiler),
                runtime_array_parameters: runtime,
                const_arrays: HashMap::from([("M.w".to_string(), arr)]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("builds: {e}"))
    };
    let u: Vec<f64> = (0..5).map(|i| 1.0 + f64::from(i)).collect();
    // k = 1: du[i] = w[i] u[i] + w[1].
    let expect = |w: &[f64]| -> Vec<f64> { (0..5).map(|i| w[i] * u[i] + w[0]).collect() };
    for doc in [weighted(5), weighted_without_w(5)] {
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let baked = rhs_program(&make(&doc, compiler, false)).expect("baked");
            assert!(baked.forcing_slots().is_empty(), "{compiler}");
            let pb = baked.parameter_vector(&HashMap::new()).expect("defaults");
            let off = eval(&baked, &u, &pb, 0.0, &baked.default_forcing());
            assert_eq!(bits(&off), bits(&expect(&caller)), "{compiler} off");

            let prog = rhs_program(&make(&doc, compiler, true)).expect("runtime");
            let k = slot(&prog, "w");
            assert_eq!(prog.forcing_slots()[k].kind, SlotKind::ArrayParameter);
            let fs = prog.default_forcing();
            assert_eq!(
                fs.buffer(k),
                &caller[..],
                "{compiler}: seeded by the caller"
            );
            let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
            let mut ws = prog.new_workspace();
            let mut du = vec![f64::NAN; 5];
            prog.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
                .expect("eval");
            assert_eq!(bits(&du), bits(&off), "{compiler}: on equals off");
            let w: Arc<[f64]> = vec![2.0, 3.0, 5.0, 7.0, 11.0].into();
            let fs2 = fs.replace(k, Arc::clone(&w)).expect("replace");
            prog.eval_into(&u, &[], &p, 0.0, &fs2, &mut du, &mut ws)
                .expect("eval");
            assert_eq!(bits(&du), bits(&expect(&w)), "{compiler}: swapped");
        }
    }
}

/// Each argument that does not belong to the program says what is wrong.
#[test]
fn mismatches_name_what_is_wrong() {
    let a = program(&forced_1d(8), Compiler::Native);
    let b = program(&forced_2d(4, 2), Compiler::Native);
    let fa = a.default_forcing();
    let n = fa.slots().len();
    let buf: Arc<[f64]> = vec![0.0; 1].into();
    assert_eq!(
        fa.replace(n, buf).unwrap_err(),
        RhsError::SlotIndex { slot: n, slots: n }
    );
    let p = a.parameter_vector(&HashMap::new()).expect("defaults");
    let u = vec![1.0; 8];
    let mut du = vec![0.0; 8];
    let mut wa = a.new_workspace();
    match a.eval_into(&u, &[], &p, 0.0, &b.default_forcing(), &mut du, &mut wa) {
        Err(e @ RhsError::ForcingSignature { .. }) => {
            let msg = e.to_string();
            assert!(
                msg.contains("slot 0 is `M.G`") && msg.contains("`M.F`"),
                "{msg}"
            )
        }
        other => panic!("expected a forcing-signature error, got {other:?}"),
    }
    let mut wb = b.new_workspace();
    assert_eq!(
        a.eval_into(&u, &[], &p, 0.0, &fa, &mut du, &mut wb)
            .unwrap_err(),
        RhsError::ForeignProgram { what: "workspace" }
    );
}

/// A gather that fails leaves the inputs ungathered: evaluating them is an
/// error, not a result built from the half-written buffers and the previous
/// gather's forcing.
#[test]
fn a_failed_gather_cannot_be_evaluated() {
    // `D(u[i]) = w[i + k] u[i]`: each lane gathers `w` at its cell shifted
    // by `k`, a fault when the shift leaves `1..n`.
    let mut doc = weighted(6);
    doc["models"]["M"]["variables"]["k"]["default"] = json!(0.0);
    doc["models"]["M"]["equations"][0]["rhs"]["expr"] = json!({"op": "*", "args": [
        idx1("w", json!({"op": "+", "args": ["i", "k"]})), idx1("u", json!("i"))]});
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(
            earthsci_ast::LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            4,
        )
        .expect("lanes");
    let names: Vec<&str> = prog.parameters().iter().map(|s| s.name.as_str()).collect();
    let at_k = names.iter().position(|n| n.ends_with(".k")).unwrap();
    let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
    let fs = prog.default_forcing();
    let cells: Vec<i32> = vec![2, 5, 1, 1];
    let lay = lanes.layout().clone();
    let u = vec![1.0; lay.u_len];
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = lanes.new_workspace();
    let mut inputs = lanes.lane_inputs();
    assert_eq!(
        lanes
            .eval_gathered_into(&u, &[], &inputs, &p, 0.0, &cells, 2, &mut du, &mut ws)
            .unwrap_err(),
        RhsError::NotGathered
    );
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.0, &fs, &cells, 2)
        .expect("gather");
    lanes
        .eval_gathered_into(&u, &[], &inputs, &p, 0.0, &cells, 2, &mut du, &mut ws)
        .expect("eval");
    // A cell outside its index set fails the gather after the buffers began
    // to fill.
    let bad: Vec<i32> = vec![2, 99, 1, 1];
    assert!(
        lanes
            .gather_lane_inputs(&mut inputs, &p, 0.0, &fs, &bad, 2)
            .is_err()
    );
    assert_eq!(
        lanes
            .eval_gathered_into(&u, &[], &inputs, &p, 0.0, &cells, 2, &mut du, &mut ws)
            .unwrap_err(),
        RhsError::NotGathered
    );
    // So does a fault inside the gather (`w[i + k]` out of range).
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.0, &fs, &cells, 2)
        .expect("gather");
    let mut q = p.clone();
    q[at_k] = 40.0;
    match lanes.gather_lane_inputs(&mut inputs, &q, 0.0, &fs, &cells, 2) {
        Err(RhsError::Fault { .. }) => {}
        other => panic!("expected a fault, got {other:?}"),
    }
    assert_eq!(
        lanes
            .eval_gathered_into(&u, &[], &inputs, &q, 0.0, &cells, 2, &mut du, &mut ws)
            .unwrap_err(),
        RhsError::NotGathered
    );
    // A wrong-length `p` is refused before the gather starts.
    assert!(matches!(
        lanes.gather_lane_inputs(&mut inputs, &p[1..], 0.0, &fs, &cells, 2),
        Err(RhsError::Shape { what: "p", .. })
    ));
}
