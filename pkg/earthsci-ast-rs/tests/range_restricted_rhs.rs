//! Range-restricted right-hand sides (API_SPEC §5.8) beyond the conformance
//! manifest: the compiler gate, `Send + Sync`, a steady call that allocates
//! nothing, and a tile whose cost does not grow with the domain.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use earthsci_ast::{
    AxisCut, Compiler, Decomposition, LaneKind, LaneProgram, ProblemOptions, RhsProgram,
    RhsSelection, SimulateError, TileBox, TileProgram, esm_problem, rhs_program,
};
use serde_json::json;

struct Counting;

thread_local! {
    /// Allocations made by this thread (tests run on several threads).
    static ALLOCS: Cell<usize> = const { Cell::new(0) };
}

fn count() {
    let _ = ALLOCS.try_with(|c| c.set(c.get() + 1));
}

fn allocs() -> usize {
    ALLOCS.with(Cell::get)
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        count();
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        count();
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// A 1-D three-point stencil on `n` cells with a one-sided last cell.
fn stencil(n: i64) -> serde_json::Value {
    let idx = |e: serde_json::Value| json!({"op": "index", "args": ["u", e]});
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "stencil", "authors": ["test"]},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"S": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "kappa": {"type": "parameter", "units": "1", "default": 0.5}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "D", "args": [idx(json!("i"))], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "*", "args": ["kappa", {"op": "index", "args": [
                            {"op": "makearray", "args": [], "regions": [[[1, n]], [[n, n]]], "values": [
                                {"op": "+", "args": [idx(json!({"op": "-", "args": ["i", 1]})),
                                    {"op": "*", "args": [-2, idx(json!("i"))]},
                                    idx(json!({"op": "+", "args": ["i", 1]}))]},
                                {"op": "-", "args": [idx(json!({"op": "-", "args": ["i", 1]})), idx(json!("i"))]}
                            ]}, "i"]}]}}
            }]
        }}
    })
}

fn program(doc: &serde_json::Value, compiler: Compiler) -> RhsProgram {
    let prob = esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        },
    )
    .expect("builds");
    rhs_program(&prob).expect("program")
}

fn dec() -> Decomposition {
    Decomposition {
        axes: vec![AxisCut {
            index_set: "x".to_string(),
            period: None,
        }],
        faces: Vec::new(),
    }
}

fn tile_box(owned: (i64, i64), storage: (i64, i64)) -> TileBox {
    TileBox {
        owned: vec![("x".to_string(), owned.0..=owned.1)],
        storage: vec![("x".to_string(), storage.0..=storage.1)],
    }
}

fn unavailable<T: std::fmt::Debug>(r: Result<T, SimulateError>, call: &str) {
    match r {
        Err(SimulateError::CompilerUnavailable { details, .. }) => {
            assert!(details.contains(call), "{details}")
        }
        other => panic!("{call}: expected compiler_unavailable, got {other:?}"),
    }
}

#[test]
fn restrictions_need_the_native_compiler() {
    let prog = program(&stencil(8), Compiler::Interpreter);
    let op = prog
        .select(&RhsSelection::default())
        .expect("select works on any program");
    unavailable(op.halo(&dec()), "halo");
    unavailable(op.tile(&dec(), &tile_box((1, 4), (0, 5))), "tile");
    unavailable(
        op.lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            4,
        ),
        "lanes",
    );
}

#[test]
fn tile_and_lane_programs_are_send_and_sync() {
    fn check<T: Send + Sync>() {}
    check::<TileProgram>();
    check::<LaneProgram>();
}

#[test]
fn a_steady_tile_call_allocates_nothing() {
    let prog = program(&stencil(64), Compiler::Native);
    let tile = prog
        .tile(&dec(), &tile_box((17, 32), (16, 33)))
        .expect("tile");
    let lay = tile.layout();
    let u = vec![1.25; lay.u_len];
    let aux = vec![0.0; lay.aux_len];
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing().expect("forcing");
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = tile.new_workspace();
    for _ in 0..3 {
        tile.eval_into(&u, &aux, &p, 0.0, &fs, &mut du, &mut ws)
            .expect("eval");
    }
    let before = allocs();
    for _ in 0..10 {
        tile.eval_into(&u, &aux, &p, 0.0, &fs, &mut du, &mut ws)
            .expect("eval");
    }
    assert_eq!(allocs() - before, 0, "a warm tile call allocated");
}

#[test]
fn a_tile_reads_only_its_storage_box() {
    // The same 16-cell owned box with a one-cell halo, in a domain of 64 and
    // one of 4096 cells: the tile's buffers, and so its call, are the
    // storage box's size whatever the domain.
    for n in [64, 4096] {
        let prog = program(&stencil(n), Compiler::Native);
        let tile = prog
            .tile(&dec(), &tile_box((17, 32), (16, 33)))
            .expect("tile");
        assert_eq!(tile.layout().u_len, 18);
        assert_eq!(tile.layout().u[0].owned, vec![(17, 32)]);
    }
}

#[test]
fn a_short_storage_box_is_refused_by_name() {
    let prog = program(&stencil(16), Compiler::Native);
    let err = prog
        .tile(&dec(), &tile_box((5, 8), (5, 9)))
        .expect_err("one cell short");
    match err {
        SimulateError::RangeRestriction { code, message } => {
            assert_eq!(code, "range_halo_insufficient");
            assert!(
                message.contains("S.u") && message.contains('x'),
                "{message}"
            );
        }
        other => panic!("{other:?}"),
    }
}
