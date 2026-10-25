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
    let p = prog.default_parameters();
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = tile.new_workspace();
    for _ in 0..3 {
        tile.eval_into(&u, &aux, &p, 0.0, &mut du, &mut ws)
            .expect("eval");
    }
    let before = allocs();
    for _ in 0..10 {
        tile.eval_into(&u, &aux, &p, 0.0, &mut du, &mut ws)
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

// ---------------------------------------------------------------------------
// Review regressions (#540).

fn ix(v: &str, subs: Vec<serde_json::Value>) -> serde_json::Value {
    let mut args = vec![json!(v)];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

fn faq_eq(
    lhs: serde_json::Value,
    rhs: serde_json::Value,
    ranges: serde_json::Value,
    idx: &[&str],
) -> serde_json::Value {
    json!({
        "lhs": {"op": "faq", "args": [], "output_idx": idx, "ranges": ranges.clone(), "expr": lhs},
        "rhs": {"op": "faq", "args": [], "output_idx": idx, "ranges": ranges, "expr": rhs}
    })
}

fn d_of(e: serde_json::Value) -> serde_json::Value {
    json!({"op": "D", "args": [e], "wrt": "t"})
}

fn model(
    index_sets: serde_json::Value,
    variables: serde_json::Value,
    equations: serde_json::Value,
) -> serde_json::Value {
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "review", "authors": ["test"]},
        "index_sets": index_sets,
        "models": {"M": {"variables": variables, "equations": equations}}
    })
}

/// A state vector of distinct, irregular values.
fn varied(n: usize) -> Vec<f64> {
    (0..n)
        .map(|k| 0.5 + ((k * 7919) % 101) as f64 / 37.0)
        .collect()
}

fn whole_du(prog: &RhsProgram, u: &[f64], aux: &[f64]) -> Vec<f64> {
    let p = prog.default_parameters();
    let mut du = vec![f64::NAN; prog.layout().u_len];
    let mut ws = prog.new_workspace();
    prog.eval_into(u, aux, &p, 0.0, &mut du, &mut ws)
        .expect("whole-domain eval");
    du
}

#[test]
fn select_follows_every_region_of_a_split_observed() {
    // `F[1] ~ G` and `F[2:4] ~ u[i]`: the cone must follow both definitions
    // of `F`, so `G` (read only through the first) stays in the program.
    let n = 4;
    let doc = model(
        json!({"x": {"kind": "interval", "size": n}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "F": {"type": "unknown", "units": "1", "shape": ["x"]},
            "G": {"type": "unknown", "units": "1"}
        }),
        json!([
            {"lhs": "G", "rhs": {"op": "*", "args": [3.0, ix("u", vec![json!(2)])]}},
            faq_eq(ix("F", vec![json!("i")]), json!("G"), json!({"i": [1, 1]}), &["i"]),
            faq_eq(ix("F", vec![json!("i")]), ix("u", vec![json!("i")]), json!({"i": [2, n]}), &["i"]),
            faq_eq(d_of(ix("u", vec![json!("i")])), ix("F", vec![json!("i")]), json!({"i": {"from": "x"}}), &["i"])
        ]),
    );
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prog = program(&doc, compiler);
        let op = prog
            .select(&RhsSelection::default())
            .expect("the selection keeps both definitions of `F`");
        assert!(
            op.flattened().observed_variables.contains_key("M.G"),
            "`G` is read through `F[1]`"
        );
        let u = varied(op.layout().u_len);
        let aux = vec![0.0; op.layout().aux_len];
        let got = whole_du(&op, &u, &aux);
        let want = whole_du(&prog, &u, &aux);
        assert_eq!(
            got.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
            want.iter().map(|x| x.to_bits()).collect::<Vec<_>>()
        );
        assert_eq!(got[0], 3.0 * u[1]);
    }
}

#[test]
fn a_workspace_follows_its_program_when_the_program_moves() {
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prog = program(&stencil(8), compiler);
        let mut ws = prog.new_workspace();
        // Move the program to the heap: its address changes, its identity
        // does not.
        let moved = Box::new(prog);
        let u = varied(moved.layout().u_len);
        let p = moved.default_parameters();
        let mut du = vec![0.0; u.len()];
        moved
            .eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
            .expect("the workspace still belongs to the moved program");
        // A workspace of another program is still refused.
        let other = program(&stencil(8), compiler);
        let mut foreign = other.new_workspace();
        assert!(
            moved
                .eval_into(&u, &[], &p, 0.0, &mut du, &mut foreign)
                .is_err()
        );
    }
}

#[test]
fn padding_lanes_ignore_the_tail_of_cells() {
    // `D(u[i]) = -c[i]·u[i]`: a lane gathers `c` at its own cell, so a
    // padding lane that took its index from the garbage tail of `cells`
    // would gather far outside `c`.
    let n = 6;
    let doc = model(
        json!({"x": {"kind": "interval", "size": n}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "c": {"type": "parameter", "units": "1", "shape": ["x"],
                  "default": [0.5, 1.5, 2.5, 3.5, 4.5, 5.5]}
        }),
        json!([faq_eq(
            d_of(ix("u", vec![json!("i")])),
            json!({"op": "*", "args": [-1.0, ix("c", vec![json!("i")]), ix("u", vec![json!("i")])]}),
            json!({"i": {"from": "x"}}),
            &["i"]
        )]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            4,
        )
        .expect("lanes");
    let gu = varied(n as usize);
    let want = whole_du(&prog, &gu, &[]);
    let p = prog.default_parameters();
    // Two lanes asked for; the tail of `cells` is garbage.
    let cells: Vec<i32> = vec![5, 2, 1_000_000, -7];
    let lay = lanes.layout().clone();
    let mut u = vec![0.0; lay.u_len];
    u[0] = gu[4];
    u[1] = gu[1];
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = lanes.new_workspace();
    lanes
        .eval_into(&u, &[], &p, 0.0, &cells, 2, &mut du, &mut ws)
        .expect("the padding lanes read in-range cells");
    assert_eq!(du[0].to_bits(), want[4].to_bits());
    assert_eq!(du[1].to_bits(), want[1].to_bits());
    let mut inputs = lanes.lane_inputs();
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.0, &cells, 2)
        .expect("the padding lanes gather in-range cells");
    // With no lane asked for, the whole of `cells` is padding.
    lanes
        .eval_into(&u, &[], &p, 0.0, &cells, 0, &mut du, &mut ws)
        .expect("n = 0");
}

/// `D(u[i, j]) = u[i, perm[j]] + u[i-1, j]` on an 8 × 3 grid: a computed
/// subscript along `y`, an affine one along `x`.
fn permuted_columns() -> serde_json::Value {
    model(
        json!({"x": {"kind": "interval", "size": 8}, "y": {"kind": "interval", "size": 3}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 1.0},
            "perm": {"type": "parameter", "units": "1", "shape": ["y"], "default": [3.0, 1.0, 2.0]}
        }),
        json!([faq_eq(
            d_of(ix("u", vec![json!("i"), json!("j")])),
            json!({"op": "+", "args": [
                ix("u", vec![json!("i"), ix("perm", vec![json!("j")])]),
                ix("u", vec![json!({"op": "-", "args": ["i", 1]}), json!("j")])
            ]}),
            json!({"i": {"from": "x"}, "j": {"from": "y"}}),
            &["i", "j"]
        )]),
    )
}

#[test]
fn a_computed_subscript_along_an_uncut_axis_tiles() {
    let prog = program(&permuted_columns(), Compiler::Native);
    let gu = varied(prog.layout().u_len);
    let want = whole_du(&prog, &gu, &[]);
    let whole = prog.layout().clone();
    for (owned, storage) in [((1, 3), (0, 3)), ((4, 8), (3, 8))] {
        let tile = prog
            .tile(&dec(), &tile_box(owned, storage))
            .expect("`y` is not cut, so its computed subscript reads the whole axis");
        let lay = tile.layout().clone();
        let b = &lay.u[0];
        let mut u = vec![0.0; lay.u_len];
        for i in storage.0..=storage.1 {
            for j in 1..=3 {
                if let (Some(s), Some(g)) = (b.slot(&[i, j]), whole.u[0].slot(&[i, j])) {
                    u[s] = gu[g];
                }
            }
        }
        let p = prog.default_parameters();
        let mut du = vec![f64::NAN; lay.u_len];
        let mut ws = tile.new_workspace();
        tile.eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
            .expect("eval");
        for i in owned.0..=owned.1 {
            for j in 1..=3 {
                let (s, g) = (b.slot(&[i, j]).unwrap(), whole.u[0].slot(&[i, j]).unwrap());
                assert_eq!(du[s].to_bits(), want[g].to_bits(), "u[{i}, {j}]");
            }
        }
    }
    // Along the cut axis a computed subscript is still global.
    let cut_y = Decomposition {
        axes: vec![AxisCut {
            index_set: "y".to_string(),
            period: None,
        }],
        faces: Vec::new(),
    };
    let bx = TileBox {
        owned: vec![("y".to_string(), 1..=2)],
        storage: vec![("y".to_string(), 1..=3)],
    };
    match prog.tile(&cut_y, &bx) {
        Err(SimulateError::RangeRestriction { code, .. }) => {
            assert_eq!(code, "range_global_locality")
        }
        other => panic!("expected range_global_locality, got {other:?}"),
    }
}

fn expect_global(r: Result<earthsci_ast::HaloReport, SimulateError>, what: &str) {
    match r {
        Err(SimulateError::RangeRestriction { code, message }) => {
            assert_eq!(code, "range_global_locality", "{what}: {message}")
        }
        other => panic!("{what}: expected range_global_locality, got {other:?}"),
    }
}

#[test]
fn halo_counts_scans_and_wholesale_observeds() {
    let n = 8;
    let x = json!({"x": {"kind": "interval", "size": n}});
    let u_decl = json!({"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0});
    // A recurrence along the cut axis: S[i] = S[i-1] + u[i].
    let scan = model(
        x.clone(),
        json!({"u": u_decl, "S": {"type": "unknown", "units": "1", "shape": ["x"]}}),
        json!([
            {"lhs": "S", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "ranges": {"i": {"from": "x"}},
                "expr": {"op": "ifelse", "args": [
                    {"op": "<=", "args": ["i", 1]},
                    ix("u", vec![json!("i")]),
                    {"op": "+", "args": [
                        ix("S", vec![json!({"op": "-", "args": ["i", 1]})]),
                        ix("u", vec![json!("i")])
                    ]}
                ]}}},
            faq_eq(d_of(ix("u", vec![json!("i")])), ix("S", vec![json!("i")]), json!({"i": {"from": "x"}}), &["i"])
        ]),
    );
    expect_global(program(&scan, Compiler::Native).halo(&dec()), "recurrence");
    // A prefix sum written as a filtered reduction, computed wholesale.
    let prefix = model(
        x.clone(),
        json!({"u": u_decl, "B": {"type": "unknown", "units": "1", "shape": ["x"]}}),
        json!([
            {"lhs": "B", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "ranges": {"i": {"from": "x"}, "j": {"from": "x"}}, "reduce": "+",
                "filter": {"op": "<=", "args": ["j", "i"]},
                "expr": ix("u", vec![json!("j")])}},
            faq_eq(d_of(ix("u", vec![json!("i")])), ix("B", vec![json!("i")]), json!({"i": {"from": "x"}}), &["i"])
        ]),
    );
    expect_global(
        program(&prefix, Compiler::Native).halo(&dec()),
        "wholesale prefix sum",
    );
    // A wholesale scalar observed of one fixed cell.
    let fixed = model(
        x,
        json!({"u": u_decl, "W": {"type": "unknown", "units": "1"}}),
        json!([
            {"lhs": "W", "rhs": {"op": "*", "args": [2.0, ix("u", vec![json!(1)])]}},
            faq_eq(d_of(ix("u", vec![json!("i")])), json!({"op": "-", "args": ["W", ix("u", vec![json!("i")])]}),
                json!({"i": {"from": "x"}}), &["i"])
        ]),
    );
    expect_global(
        program(&fixed, Compiler::Native).halo(&dec()),
        "fixed-cell wholesale observed",
    );
}

#[test]
fn halo_counts_a_recurrence_along_an_uncut_axis() {
    // S[i, k] = S[i, k-1] + u[i+1, k], a column scan along the uncut `z`:
    // u is reached one cell above along the cut `x`.
    let doc = model(
        json!({"x": {"kind": "interval", "size": 8}, "z": {"kind": "interval", "size": 3}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x", "z"], "default": 1.0},
            "S": {"type": "unknown", "units": "1", "shape": ["x", "z"]}
        }),
        json!([
            {"lhs": "S", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "k"],
                "ranges": {"i": {"from": "x"}, "k": {"from": "z"}},
                "expr": {"op": "ifelse", "args": [
                    {"op": "<=", "args": ["k", 1]},
                    ix("u", vec![json!({"op": "+", "args": ["i", 1]}), json!("k")]),
                    {"op": "+", "args": [
                        ix("S", vec![json!("i"), json!({"op": "-", "args": ["k", 1]})]),
                        ix("u", vec![json!({"op": "+", "args": ["i", 1]}), json!("k")])
                    ]}
                ]}}},
            faq_eq(d_of(ix("u", vec![json!("i"), json!("k")])), ix("S", vec![json!("i"), json!("k")]),
                json!({"i": {"from": "x"}, "k": {"from": "z"}}), &["i", "k"])
        ]),
    );
    let halo = program(&doc, Compiler::Native)
        .halo(&dec())
        .expect("a scan along an uncut axis has a bounded reach");
    assert_eq!(halo.get("M.u", "x"), Some((0, 1)));
}

/// A periodic 1-D flux form on `n` cells: `F = 2u` (cell by cell) and
/// `du[i] = F[i-1] - F[i]`, with `F[i-1]` at cell 1 spelled `wrapped` ways:
/// an explicit `F[n]` boundary region, or the periodic-wrap subscript idiom.
fn periodic_flux(n: i64, idiom: bool) -> serde_json::Value {
    let f = |e: serde_json::Value| ix("F", vec![e]);
    let im1 = json!({"op": "-", "args": ["i", 1]});
    let rhs = if idiom {
        let wrapped = json!({"op": "ifelse", "args": [
            {"op": "<", "args": [im1.clone(), 1]},
            {"op": "+", "args": [im1.clone(), n]},
            {"op": "ifelse", "args": [
                {"op": ">", "args": [im1.clone(), n]},
                {"op": "-", "args": [im1.clone(), n]},
                im1.clone()
            ]}
        ]});
        json!({"op": "-", "args": [f(wrapped), f(json!("i"))]})
    } else {
        json!({"op": "index", "args": [
            {"op": "makearray", "args": [], "regions": [[[1, 1]], [[2, n]]], "values": [
                {"op": "-", "args": [f(json!(n)), f(json!("i"))]},
                {"op": "-", "args": [f(im1), f(json!("i"))]}
            ]}, "i"]})
    };
    model(
        json!({"x": {"kind": "interval", "size": n}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "F": {"type": "unknown", "units": "1", "shape": ["x"]}
        }),
        json!([
            faq_eq(
                ix("F", vec![json!("i")]),
                json!({"op": "*", "args": [2.0, ix("u", vec![json!("i")])]}),
                json!({"i": {"from": "x"}}),
                &["i"]
            ),
            faq_eq(
                d_of(ix("u", vec![json!("i")])),
                rhs,
                json!({"i": {"from": "x"}}),
                &["i"]
            )
        ]),
    )
}

#[test]
fn an_observed_read_across_a_periodic_seam_is_computed_over_its_need() {
    for idiom in [false, true] {
        for n in [64i64, 4096] {
            let prog = program(&periodic_flux(n, idiom), Compiler::Native);
            let pdec = Decomposition {
                axes: vec![AxisCut {
                    index_set: "x".to_string(),
                    period: Some(n),
                }],
                faces: Vec::new(),
            };
            let gu = varied(n as usize);
            let want = whole_du(&prog, &gu, &[]);
            // Cells 1..4, with cell n held below the seam at storage cell 0:
            // `F` is needed at n and 1..4 only, so `u` is needed nowhere else.
            let tile = prog
                .tile(&pdec, &tile_box((1, 4), (0, 4)))
                .unwrap_or_else(|e| panic!("n = {n}, idiom = {idiom}: {e}"));
            let lay = tile.layout().clone();
            assert_eq!(lay.u_len, 5);
            let b = &lay.u[0];
            let mut u = vec![0.0; lay.u_len];
            for g in 0..=4i64 {
                let src = if g < 1 { g + n } else { g };
                u[b.slot(&[g]).unwrap()] = gu[(src - 1) as usize];
            }
            let p = prog.default_parameters();
            let mut du = vec![f64::NAN; lay.u_len];
            let mut ws = tile.new_workspace();
            tile.eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
                .expect("eval");
            for g in 1..=4i64 {
                assert_eq!(
                    du[b.slot(&[g]).unwrap()].to_bits(),
                    want[(g - 1) as usize].to_bits(),
                    "n = {n}, idiom = {idiom}, cell {g}"
                );
            }
            // And a tile at the top of the domain, holding cell 1 above the
            // seam (the flux form reads only below, so this is the plain
            // interior case at the other edge).
            let tile = prog
                .tile(&pdec, &tile_box((n - 3, n), (n - 4, n)))
                .expect("top tile");
            let lay = tile.layout().clone();
            let b = &lay.u[0];
            let mut u = vec![0.0; lay.u_len];
            for g in n - 4..=n {
                u[b.slot(&[g]).unwrap()] = gu[(g - 1) as usize];
            }
            let mut du = vec![f64::NAN; lay.u_len];
            let mut ws = tile.new_workspace();
            tile.eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
                .expect("eval");
            for g in n - 3..=n {
                assert_eq!(
                    du[b.slot(&[g]).unwrap()].to_bits(),
                    want[(g - 1) as usize].to_bits()
                );
            }
        }
    }
}

/// Feeds one 4-cell field once.
struct Feed(String);

type Fields = std::collections::HashMap<String, earthsci_ast::provider::NativeField>;

impl earthsci_ast::provider::CadenceProvider for Feed {
    fn materialize(&mut self) -> Result<Fields, earthsci_ast::provider::ProviderError> {
        let a = ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[4]), vec![0.25, 1.5, 2.75, 4.0])
            .expect("field");
        Ok(Fields::from([(
            self.0.clone(),
            earthsci_ast::provider::NativeField::new(a),
        )]))
    }
    fn refresh(
        &mut self,
        _t: f64,
    ) -> Result<Option<Fields>, earthsci_ast::provider::ProviderError> {
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        Vec::new()
    }
}

/// `D(c[i]) = f1[i] - c[i]` with `k` data-fed fields `f1..fk` in the forcing
/// buffer.
fn forced_program(compiler: Compiler, k: usize) -> RhsProgram {
    let mut vars = serde_json::Map::new();
    vars.insert(
        "c".to_string(),
        json!({"type": "unknown", "units": "1", "shape": ["cells"], "default": 1.0}),
    );
    for f in 1..=k {
        vars.insert(
            format!("f{f}"),
            json!({"type": "parameter", "units": "1", "shape": ["cells"],
                   "update": {"kind": "data", "source": "src", "from": {"file_variable": format!("f{f}")}}}),
        );
    }
    let mut doc = model(
        json!({"cells": {"kind": "interval", "size": 4}}),
        serde_json::Value::Object(vars),
        json!([faq_eq(
            d_of(ix("c", vec![json!("i")])),
            json!({"op": "-", "args": [ix("f1", vec![json!("i")]), ix("c", vec![json!("i")])]}),
            json!({"i": {"from": "cells"}}),
            &["i"]
        )]),
    );
    doc["data_sources"] =
        json!({"src": {"kind": "grid", "source": {"url_template": "file:///data/f.nc"}}});
    let providers: std::collections::HashMap<
        String,
        Box<dyn earthsci_ast::provider::CadenceProvider>,
    > = (1..=k)
        .map(|f| {
            (
                format!("f{f}"),
                Box::new(Feed(format!("f{f}"))) as Box<dyn earthsci_ast::provider::CadenceProvider>,
            )
        })
        .collect();
    let prob = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            providers,
            ..Default::default()
        },
    )
    .expect("builds");
    rhs_program(&prob).expect("program")
}

/// Allocations of one warm interpreter call of `prog`, after checking it
/// against the native program `native`.
fn warm_call_allocs(prog: &RhsProgram, native: &RhsProgram) -> usize {
    let u = varied(prog.layout().u_len);
    let want = whole_du(native, &u, &[]);
    let p = prog.default_parameters();
    let mut du = vec![f64::NAN; u.len()];
    let mut ws = prog.new_workspace();
    for _ in 0..3 {
        prog.eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
            .expect("eval");
    }
    assert_eq!(
        du.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        want.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        "the interpreter reads the same forcing as the tape"
    );
    let before = allocs();
    prog.eval_into(&u, &[], &p, 0.0, &mut du, &mut ws)
        .expect("eval");
    allocs() - before
}

#[test]
fn an_interpreter_call_reads_the_forcing_without_copying_it() {
    // The same right-hand side with one field in the forcing buffer and with
    // twenty: a call that copied the buffer would allocate per entry.
    let one = warm_call_allocs(
        &forced_program(Compiler::Interpreter, 1),
        &forced_program(Compiler::Native, 1),
    );
    let twenty = warm_call_allocs(
        &forced_program(Compiler::Interpreter, 20),
        &forced_program(Compiler::Native, 20),
    );
    assert_eq!(
        one, twenty,
        "a warm interpreter call copied the forcing buffer"
    );
}
