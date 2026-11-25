//! Range-restricted right-hand sides (API_SPEC §5.8) beyond the conformance
//! manifest: the compiler gate, `Send + Sync`, a steady call that allocates
//! nothing, and a tile whose cost does not grow with the domain.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use earthsci_ast::{
    AxisCut, Compiler, Decomposition, LaneKind, LaneProgram, ProblemOptions, RhsError, RhsProgram,
    RhsSelection, SimulateError, TermOrigin, TileBox, TileProgram, esm_problem, rhs_program,
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
        "esm": "2.0.0",
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
    let fs = prog.default_forcing();
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
        "esm": "2.0.0",
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
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let mut du = vec![f64::NAN; prog.layout().u_len];
    let mut ws = prog.new_workspace();
    prog.eval_into(u, aux, &p, 0.0, &fs, &mut du, &mut ws)
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
fn select_builds_an_unshaped_mixed_ifelse_at_its_whole_system_shape() {
    // esm-spec §4.3.4: `X = ifelse(w > 1, 0.0, F * 2)` is built at `F`'s
    // shape, which the inference decides from `w` being an unshaped ODE state.
    // Selecting only `B`'s terms keeps `A.w` (the cone reads it) but drops
    // `D(w)`, so the cut system alone cannot decide `w`'s rank: the selection
    // must be built at the shapes the whole system was.
    let n = 3;
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "review", "authors": ["test"]},
        "index_sets": {"cell": {"kind": "interval", "size": n}},
        "models": {
            "A": {
                "variables": {"w": {"type": "unknown", "units": "1", "default": 0.0}},
                "equations": [{"lhs": d_of(json!("w")), "rhs": 1.0}]
            },
            "B": {
                "variables": {
                    "F": {"type": "parameter", "units": "1", "shape": ["cell"],
                          "default": [1.0, 2.0, 3.0]},
                    "X": {"type": "unknown", "units": "1"},
                    "acc": {"type": "unknown", "units": "1", "shape": ["cell"], "default": 0.0}
                },
                "equations": [
                    {"lhs": "X", "rhs": {"op": "ifelse", "args": [
                        {"op": ">", "args": ["A.w", 1.0]}, 0.0,
                        {"op": "*", "args": ["F", 2.0]}]}},
                    faq_eq(d_of(ix("acc", vec![json!("i")])), ix("X", vec![json!("i")]),
                           json!({"i": {"from": "cell"}}), &["i"])
                ]
            }
        }
    });
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let prog = program(&doc, compiler);
        let op = prog
            .select(&RhsSelection {
                writes: Some(vec!["B.acc".to_string()]),
                terms: Some(vec![TermOrigin::Component {
                    component: "B".to_string(),
                }]),
            })
            .unwrap_or_else(|e| panic!("{compiler:?}: the selection builds: {e}"));
        let cut = op.flattened();
        let has_d_w = cut.equations.iter().any(|eq| {
            let lhs = serde_json::to_string(&eq.lhs).unwrap();
            lhs.contains("\"D\"") && lhs.contains("\"A.w\"")
        });
        assert!(
            cut.state_variables.contains_key("A.w") && !has_d_w,
            "{compiler:?}: `A.w` is kept as a read-only state with no `D` equation"
        );
        let layout = op.layout();
        assert_eq!(layout.u_len, n as usize, "{compiler:?}: `u` is `acc`");
        assert_eq!(layout.aux_len, 1, "{compiler:?}: `aux` is `w`");
        let u = vec![0.0; layout.u_len];
        for (w, want) in [(0.0, [2.0, 4.0, 6.0]), (2.0, [0.0, 0.0, 0.0])] {
            let got = whole_du(&op, &u, &[w]);
            assert_eq!(got, want, "{compiler:?}: du(acc) at w = {w}");
        }
    }
}

/// esm-spec §4.3.4 in a tile: `X = ifelse(lev < 2, F / D, 0.0)` with
/// `F: [x]` and `D` a gather from a `const` table is built at the whole `x`
/// shape, so a tile of `D(u[i]) = X[i] + u[i]` reads the same cells as the
/// whole program on both arms, the array arm first and second. (An observed
/// that is a whole-array expression of a STATE is not tiled at all.)
#[test]
fn a_tile_builds_an_unshaped_mixed_ifelse_at_the_whole_shape() {
    let n = 8;
    let table = json!({"op": "const", "args": [], "value": [31.0, 28.0, 31.0]});
    let f: Vec<f64> = (1..=n).map(|k| 28.0 * k as f64).collect();
    let ud = json!({"op": "/", "args": ["F", "D"]});
    let bodies = [
        json!({"op": "ifelse", "args": [{"op": "<", "args": ["lev", 2.0]}, ud.clone(), 0.0]}),
        json!({"op": "ifelse", "args": [{"op": ">=", "args": ["lev", 2.0]}, 0.0, ud]}),
    ];
    for body in bodies {
        for lev in [1.0, 3.0] {
            let doc = model(
                json!({"x": {"kind": "interval", "size": n}}),
                json!({
                    "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                    "lev": {"type": "parameter", "units": "1", "default": lev},
                    "F": {"type": "parameter", "units": "1", "shape": ["x"], "default": f.clone()},
                    "D": {"type": "unknown", "units": "1"},
                    "X": {"type": "unknown", "units": "1"}
                }),
                json!([
                    {"lhs": "D", "rhs": ix_expr(table.clone(), json!(2))},
                    {"lhs": "X", "rhs": body.clone()},
                    faq_eq(d_of(ix("u", vec![json!("i")])),
                        json!({"op": "+", "args": [ix("X", vec![json!("i")]), ix("u", vec![json!("i")])]}),
                        json!({"i": {"from": "x"}}), &["i"])
                ]),
            );
            let prog = program(&doc, Compiler::Native);
            let gu = varied(prog.layout().u_len);
            let want = whole_du(&prog, &gu, &[]);
            let whole = prog.layout().clone();
            for (lo, hi) in [(1, 2), (3, 5), (6, 8)] {
                let tile = prog
                    .tile(&dec(), &tile_box((lo, hi), (lo, hi)))
                    .unwrap_or_else(|e| panic!("lev = {lev}: tile ({lo}, {hi}): {e}"));
                let lay = tile.layout().clone();
                let (b, g) = (&lay.u[0], &whole.u[0]);
                let mut u = vec![0.0; lay.u_len];
                for i in lo..=hi {
                    u[b.slot(&[i]).unwrap()] = gu[g.slot(&[i]).unwrap()];
                }
                let p = prog
                    .parameter_vector(&Default::default())
                    .expect("defaults");
                let fs = prog.default_forcing();
                let mut du = vec![f64::NAN; lay.u_len];
                let mut ws = tile.new_workspace();
                tile.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
                    .expect("eval");
                for i in lo..=hi {
                    let (s, w) = (b.slot(&[i]).unwrap(), g.slot(&[i]).unwrap());
                    assert_eq!(du[s].to_bits(), want[w].to_bits(), "lev = {lev}: u[{i}]");
                }
            }
            for (k, w) in want.iter().enumerate() {
                let x = if lev < 2.0 { (k + 1) as f64 } else { 0.0 };
                assert_eq!(*w, x + gu[k], "lev = {lev}: whole du[{k}]");
            }
        }
    }
}

fn ix_expr(base: serde_json::Value, sub: serde_json::Value) -> serde_json::Value {
    json!({"op": "index", "args": [base, sub]})
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
        let p = moved
            .parameter_vector(&Default::default())
            .expect("defaults");
        let fs = moved.default_forcing();
        let mut du = vec![0.0; u.len()];
        moved
            .eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
            .expect("the workspace still belongs to the moved program");
        // A workspace of another program is still refused.
        let other = program(&stencil(8), compiler);
        let mut foreign = other.new_workspace();
        assert!(
            moved
                .eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut foreign)
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
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    // Two lanes asked for; the tail of `cells` is garbage.
    let cells: Vec<i32> = vec![5, 2, 1_000_000, -7];
    let lay = lanes.layout().clone();
    let mut u = vec![0.0; lay.u_len];
    u[0] = gu[4];
    u[1] = gu[1];
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = lanes.new_workspace();
    lanes
        .eval_into(&u, &[], &p, 0.0, &fs, &cells, 2, &mut du, &mut ws)
        .expect("the padding lanes read in-range cells");
    assert_eq!(du[0].to_bits(), want[4].to_bits());
    assert_eq!(du[1].to_bits(), want[1].to_bits());
    let mut inputs = lanes.lane_inputs();
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.0, &fs, &cells, 2)
        .expect("the padding lanes gather in-range cells");
    // With no lane asked for, the whole of `cells` is padding.
    lanes
        .eval_into(&u, &[], &p, 0.0, &fs, &cells, 0, &mut du, &mut ws)
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
        let p = prog
            .parameter_vector(&Default::default())
            .expect("defaults");
        let fs = prog.default_forcing();
        let mut du = vec![f64::NAN; lay.u_len];
        let mut ws = tile.new_workspace();
        tile.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
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
            let p = prog
                .parameter_vector(&Default::default())
                .expect("defaults");
            let fs = prog.default_forcing();
            let mut du = vec![f64::NAN; lay.u_len];
            let mut ws = tile.new_workspace();
            tile.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
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
            tile.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
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
struct Feed;

impl earthsci_ast::provider::DataProvider for Feed {
    fn sample(&mut self) -> Result<ndarray::ArrayD<f64>, earthsci_ast::provider::ProviderError> {
        Ok(
            ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[4]), vec![0.25, 1.5, 2.75, 4.0])
                .expect("field"),
        )
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
        Box<dyn earthsci_ast::provider::DataProvider>,
    > = (1..=k)
        .map(|f| {
            (
                format!("f{f}"),
                Box::new(Feed) as Box<dyn earthsci_ast::provider::DataProvider>,
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
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let mut du = vec![f64::NAN; u.len()];
    let mut ws = prog.new_workspace();
    for _ in 0..3 {
        prog.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
            .expect("eval");
    }
    assert_eq!(
        du.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        want.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        "the interpreter reads the same forcing as the tape"
    );
    let before = allocs();
    prog.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
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

mod precision_source {
    use earthsci_ast::{
        Compiler, EsmProblem, PrecisionSource, ProblemOptions, RhsOptions, RhsProgram, esm_problem,
        load_string, precision::Precision, rhs_program, rhs_program_with_options,
    };
    use serde_json::{Value, json};

    fn witness() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/conformance/precision_source/rounding.esm"
        ))
        .unwrap()
    }

    fn problem(doc: &Value, compiler: Compiler) -> EsmProblem {
        let typed = load_string(&doc.to_string()).unwrap();
        esm_problem(
            &typed,
            (0., 1.),
            ProblemOptions {
                compiler: Some(compiler),
                ..Default::default()
            },
        )
        .unwrap()
    }

    fn narrow(doc: &Value, compiler: Compiler) -> Result<RhsProgram, earthsci_ast::SimulateError> {
        let typed = load_string(&doc.to_string()).unwrap();
        rhs_program_with_options(
            &typed,
            (0., 1.),
            ProblemOptions {
                compiler: Some(compiler),
                ..Default::default()
            },
            RhsOptions {
                unspecified_evaluation: Precision::Float32,
            },
        )
    }

    fn rhs(prog: &RhsProgram) -> Vec<f64> {
        let (u, aux) = prog.default_state();
        let p = prog
            .parameters()
            .iter()
            .map(|p| p.default.unwrap())
            .collect::<Vec<_>>();
        let mut out = vec![0.0; u.len()];
        prog.eval_into(
            &u,
            &aux,
            &p,
            0.,
            &prog.default_forcing(),
            &mut out,
            &mut prog.new_workspace(),
        )
        .unwrap();
        out
    }

    #[test]
    fn choice_uses_per_operation_rounding_only_on_external_rhs() {
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            let prob = problem(&witness(), compiler);
            let standard = rhs_program(&prob).unwrap();
            assert_eq!(
                standard.precision_sources(),
                &[PrecisionSource::Unspecified; 2]
            );
            assert_eq!(standard.state_precisions(), &[Precision::Float64; 2]);
            assert_eq!(rhs(&standard), [1.0; 2]);

            let chosen = narrow(&witness(), compiler).unwrap();
            assert_eq!(
                chosen.precision_sources(),
                &[PrecisionSource::Unspecified; 2]
            );
            assert_eq!(chosen.state_precisions(), &[Precision::Float32; 2]);
            let expected = f32::from_bits(1.0_f32.to_bits() - 1);
            assert_eq!(rhs(&chosen), [f64::from(expected); 2]);
            let p = chosen
                .parameters()
                .iter()
                .map(|p| p.default.unwrap())
                .collect::<Vec<_>>();
            let mut out = [0.0_f32; 2];
            chosen
                .eval_into::<f32>(
                    &[0.0; 2],
                    &[],
                    &p,
                    0.,
                    &chosen.default_forcing(),
                    &mut out,
                    &mut chosen.new_workspace(),
                )
                .unwrap();
            assert_eq!(out, [expected; 2]);
            assert_eq!(rhs(&rhs_program(&prob).unwrap()), [1.0; 2]);
        }
    }

    #[test]
    fn a_declared_root_and_a_legacy_omission_are_both_binding() {
        let mut doc = witness();
        doc["esm"] = json!("2.3.0");
        let prob = problem(&doc, Compiler::Interpreter);
        assert_eq!(
            rhs_program(&prob).unwrap().precision_sources(),
            &[PrecisionSource::Declared(Precision::Float64); 2]
        );
        assert_eq!(
            narrow(&doc, Compiler::Interpreter).unwrap_err().code(),
            Some("precision_choice_conflict")
        );

        doc["esm"] = json!("2.4.0");
        doc["domain"] = json!({"element_type": "Float64"});
        assert_eq!(
            narrow(&doc, Compiler::Interpreter).unwrap_err().code(),
            Some("precision_choice_conflict")
        );

        doc.as_object_mut().unwrap().remove("domain");
        doc["models"]["M"]["variables"]["a"]["element_type"] = json!("Float64");
        doc["models"]["M"]["variables"]["x"]["element_type"] = json!("Float64");
        let err = narrow(&doc, Compiler::Interpreter).unwrap_err();
        assert_eq!(err.code(), Some("precision_choice_conflict"));
        assert!(err.to_string().contains("M.x"), "{err}");
    }

    #[test]
    fn a_mixed_working_expression_names_the_conflicting_variables() {
        let mut doc = witness();
        doc["models"]["M"]["variables"]["a"]["element_type"] = json!("Float64");
        let err = narrow(&doc, Compiler::Interpreter).unwrap_err();
        assert_eq!(err.code(), Some("precision_choice_conflict"));
        for name in ["a", "x", "unspecified_evaluation", "Float64"] {
            assert!(err.to_string().contains(name), "{err}");
        }
    }

    #[test]
    fn chosen_precision_can_agree_with_a_declared_operand() {
        let mut doc = witness();
        doc["models"]["M"]["variables"]["a"]["element_type"] = json!("Float32");
        let typed = load_string(&doc.to_string()).unwrap();
        assert_eq!(
            esm_problem(&typed, (0., 1.), Default::default())
                .unwrap_err()
                .code(),
            Some("mixed_element_type"),
        );
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            let chosen = narrow(&doc, compiler).unwrap();
            assert_eq!(rhs(&chosen), [0.9999999403953552; 2]);
        }
    }

    #[test]
    fn an_unspecified_join_key_is_refused_before_compilation() {
        let mut doc = witness();
        doc["models"]["M"]["equations"][0]["rhs"]["join"] = json!([{"on": [["a", "a"]]}]);
        let err = narrow(&doc, Compiler::Native).unwrap_err();
        assert_eq!(err.code(), Some("key_precision_unspecified"));
        assert!(err.to_string().contains("join.on"), "{err}");
    }

    #[test]
    fn a_declared_key_comparison_stays_exact_in_a_binary32_group() {
        let mut doc = witness();
        doc["models"]["M"]["variables"]["a"]["default"] = json!(2260007005.0);
        doc["models"]["M"]["variables"]["b"] = json!({
            "type": "parameter", "default": 2260007015.0, "units": "1"
        });
        doc["models"]["M"]["equations"][0]["rhs"]["expr"] = json!({
            "op": "ifelse",
            "args": [{"op": "==", "args": ["a", "b"]}, 1.0, 0.0],
        });
        let typed = load_string(&doc.to_string()).unwrap();
        let result = earthsci_ast::validate(&typed);
        assert!(
            result
                .warnings
                .iter()
                .any(|w| w.code == "key_precision_unspecified")
        );
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            assert_eq!(
                narrow(&doc, compiler).unwrap_err().code(),
                Some("key_precision_unspecified")
            );
        }
        for key in ["a", "b"] {
            doc["models"]["M"]["variables"][key]["element_type"] = json!("Float64");
        }
        for compiler in [Compiler::Interpreter, Compiler::Native] {
            assert_eq!(rhs(&narrow(&doc, compiler).unwrap()), [0.; 2]);
        }
    }
}

/// A whole-array right-hand side `D(u) = faq{output_idx [i, j], …}` (the
/// form EarthSciIntegrator's derived documents write, lowered to
/// `index(faq{…}, loops…)`) builds a lane program, and every lane equals the
/// whole-domain program bit for bit: a body read at the lane's cell, a
/// coordinate, the time, and a `faq` that also contracts over `k`.
#[test]
fn whole_array_faq_right_hand_sides_build_lanes() {
    let (nx, ny) = (3, 4);
    let whole = |expr: serde_json::Value, ranges: serde_json::Value| json!({"op": "faq", "args": [], "output_idx": ["i", "j"], "ranges": ranges, "expr": expr});
    let xy = json!({"i": {"from": "x"}, "j": {"from": "y"}});
    let xyk = json!({"i": {"from": "x"}, "j": {"from": "y"}, "k": {"from": "z"}});
    let doc = model(
        json!({"x": {"kind": "interval", "size": nx},
               "y": {"kind": "interval", "size": ny},
               "z": {"kind": "interval", "size": 2}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 1.0},
            "v": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 2.0},
            "c": {"type": "parameter", "units": "1", "shape": ["x"], "default": [0.5, 1.5, 2.5]},
            "w": {"type": "parameter", "units": "1", "shape": ["z"], "default": [0.25, 0.75]}
        }),
        json!([
            {"lhs": d_of(json!("u")),
             "rhs": whole(json!({"op": "-", "args": [
                 {"op": "*", "args": [ix("c", vec![json!("i")]), ix("u", vec![json!("i"), json!("j")]), "t"]},
                 {"op": "*", "args": ["j", ix("v", vec![json!("i"), json!("j")])]}]}), xy)},
            {"lhs": d_of(json!("v")),
             "rhs": whole(json!({"op": "*", "args": [ix("w", vec![json!("k")]), ix("u", vec![json!("i"), json!("j")])]}), xyk)}
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string(), "y".to_string()],
            },
            4,
        )
        .expect("a whole-array faq right-hand side builds lanes");
    let n = (nx * ny) as usize;
    let gu = varied(2 * n);
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let t = 0.75;
    let mut want = vec![f64::NAN; prog.layout().u_len];
    let mut ws = prog.new_workspace();
    prog.eval_into(&gu, &[], &p, t, &fs, &mut want, &mut ws)
        .expect("whole-domain eval");
    let lay = lanes.layout().clone();
    let off = |name: &str| lay.block(name).expect("a lane block").offset;
    let (ou, ov) = (off("M.u"), off("M.v"));
    let mut lws = lanes.new_workspace();
    // Cells in batches of up to 4, the last one short (padded).
    let cells: Vec<usize> = (0..n).collect();
    for batch in cells.chunks(4) {
        let mut u = vec![0.0; lay.u_len];
        let mut cs = Vec::new();
        for (l, &c) in batch.iter().enumerate() {
            u[ou * 4 + l] = gu[c];
            u[ov * 4 + l] = gu[n + c];
            cs.push((c % nx as usize) as i32 + 1);
            cs.push((c / nx as usize) as i32 + 1);
        }
        let mut du = vec![f64::NAN; lay.u_len];
        lanes
            .eval_into(&u, &[], &p, t, &fs, &cs, batch.len(), &mut du, &mut lws)
            .expect("lane eval");
        for (l, &c) in batch.iter().enumerate() {
            assert_eq!(du[ou * 4 + l].to_bits(), want[c].to_bits(), "u at cell {c}");
            assert_eq!(
                du[ov * 4 + l].to_bits(),
                want[n + c].to_bits(),
                "v at cell {c}"
            );
        }
    }
}

/// U19: each lane at its own time. `D(u[i]) = -k·u[i] + g[i]·s` with `k`
/// a scalar observed of `t`, `s` one of `k` and `t`, and an array observed
/// `g[i] = c[i]·t`: every lane equals the
/// whole-domain program at its own cell and its own time, bit for bit,
/// whatever the other lanes' times; and `eval_into` with one time agrees
/// with `eval_times_into` at that time in every lane.
#[test]
fn each_lane_evaluates_at_its_own_time() {
    let n = 5;
    let doc = model(
        json!({"x": {"kind": "interval", "size": n}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "c": {"type": "parameter", "units": "1", "shape": ["x"],
                  "default": [0.5, 1.5, 2.5, 3.5, 4.5]},
            "k": {"type": "unknown", "units": "1"},
            "s": {"type": "unknown", "units": "1"},
            "g": {"type": "unknown", "units": "1", "shape": ["x"]}
        }),
        json!([
            {"lhs": "k", "rhs": {"op": "+", "args": [1.0, {"op": "sin", "args": ["t"]}]}},
            {"lhs": "s", "rhs": {"op": "*", "args": [3.0, "k", {"op": "cos", "args": ["t"]}]}},
            faq_eq(ix("g", vec![json!("i")]),
                   json!({"op": "*", "args": [ix("c", vec![json!("i")]), "t"]}),
                   json!({"i": {"from": "x"}}), &["i"]),
            faq_eq(
                d_of(ix("u", vec![json!("i")])),
                json!({"op": "+", "args": [
                    {"op": "*", "args": [-1.0, "k", ix("u", vec![json!("i")])]},
                    {"op": "*", "args": [ix("g", vec![json!("i")]), "s"]}]}),
                json!({"i": {"from": "x"}}),
                &["i"]
            )
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let cap = 4;
    let lanes = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            cap,
        )
        .expect("lanes over a time-dependent program");
    let gu = varied(n as usize);
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let whole_at = |t: f64| {
        let mut du = vec![f64::NAN; prog.layout().u_len];
        let mut ws = prog.new_workspace();
        prog.eval_into(&gu, &[], &p, t, &fs, &mut du, &mut ws)
            .expect("whole-domain eval");
        du
    };
    let lay = lanes.layout().clone();
    let mut ws = lanes.new_workspace();
    // Lanes hold cells 4, 1, 3 (and one padding lane), each at its own time.
    let cells: Vec<i32> = vec![4, 1, 3, 2];
    let ts = [0.3, 2.0, 7.25];
    let mut u = vec![0.0; lay.u_len];
    for (l, &c) in cells.iter().take(3).enumerate() {
        u[l] = gu[(c - 1) as usize];
    }
    let mut du = vec![f64::NAN; lay.u_len];
    let r = lanes.eval_times_into(&u, &[], &p, &ts, &fs, &cells, 3, &mut du, &mut ws);
    match r {
        Ok(()) => {
            for (l, &c) in cells.iter().take(3).enumerate() {
                let want = whole_at(ts[l]);
                assert_eq!(
                    du[l].to_bits(),
                    want[(c - 1) as usize].to_bits(),
                    "lane {l} at t = {}",
                    ts[l]
                );
            }
        }
        Err(e) => panic!("{e}"),
    }
    // One time for every lane: eval_into and eval_times_into agree.
    let mut d1 = vec![f64::NAN; lay.u_len];
    let mut d2 = vec![f64::NAN; lay.u_len];
    lanes
        .eval_into(&u, &[], &p, 2.0, &fs, &cells, 3, &mut d1, &mut ws)
        .expect("one time");
    lanes
        .eval_times_into(
            &u,
            &[],
            &p,
            &[2.0, 2.0, 2.0],
            &fs,
            &cells,
            3,
            &mut d2,
            &mut ws,
        )
        .expect("per-lane times");
    for l in 0..3 {
        assert_eq!(d1[l].to_bits(), d2[l].to_bits(), "lane {l}");
    }
    // Too few times is refused.
    assert!(
        lanes
            .eval_times_into(&u, &[], &p, &[1.0], &fs, &cells, 3, &mut d2, &mut ws)
            .is_err()
    );
}

/// Every lane of `lanes` equals the whole-domain program at its cell (or
/// column) bit for bit, at time `t`, over every cell of the lane sets
/// (extents `ext`, first set fastest) in batches of the capacity with the
/// last one padded, on both the plain and the pre-gathered path.
fn assert_lanes_match(prog: &RhsProgram, lanes: &LaneProgram, ext: &[i64], t: f64) {
    assert_lanes_match_at(prog, lanes, ext, &|_| t, false);
}

/// [`assert_lanes_match`] with the cell numbered `c` (in the order the
/// cells are visited) at time `time_of(c)`. With `per_lane_times`, the calls
/// are `eval_times_into` and `eval_gathered_times_into`, and every padding
/// lane, given lane 0's state, equals lane 0 (it takes `ts[0]` and lane 0's
/// cell); otherwise `eval_into` and `eval_gathered_into` at `time_of(0)`.
fn assert_lanes_match_at(
    prog: &RhsProgram,
    lanes: &LaneProgram,
    ext: &[i64],
    time_of: &dyn Fn(usize) -> f64,
    per_lane_times: bool,
) {
    let whole = prog.layout().clone();
    let lay = lanes.layout().clone();
    let cap = lay.capacity;
    let d = lay.sets.len();
    let gu = varied(whole.u_len);
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let mut wants: Vec<(f64, Vec<f64>)> = Vec::new();
    let mut want_at = |t: f64| -> Vec<f64> {
        if let Some((_, w)) = wants.iter().find(|(x, _)| x.to_bits() == t.to_bits()) {
            return w.clone();
        }
        let mut want = vec![f64::NAN; whole.u_len];
        let mut ws = prog.new_workspace();
        prog.eval_into(&gu, &[], &p, t, &fs, &mut want, &mut ws)
            .expect("whole-domain eval");
        wants.push((t, want.clone()));
        want
    };
    // The global multi-index of element `e` of `name` in the lane at `cell`.
    let global = |name: &str, cell: &[i64], e: usize| -> Vec<i64> {
        let w = whole.block(name).expect("a whole block");
        let mut rem = e;
        let mut g = Vec::new();
        for (a, &(lo, hi)) in w.storage.iter().enumerate() {
            match lay.sets.iter().position(|s| *s == w.sets[a]) {
                Some(pos) => g.push(cell[pos]),
                None => {
                    let n = (hi - lo + 1) as usize;
                    g.push(lo + (rem % n) as i64);
                    rem /= n;
                }
            }
        }
        g
    };
    let n_cells: i64 = ext.iter().product();
    let cells: Vec<Vec<i64>> = (0..n_cells)
        .map(|mut c| {
            ext.iter()
                .map(|&n| {
                    let x = c % n + 1;
                    c /= n;
                    x
                })
                .collect()
        })
        .collect();
    let mut lws = lanes.new_workspace();
    let mut inputs = lanes.lane_inputs();
    for (k, batch) in cells.chunks(cap).enumerate() {
        let ts: Vec<f64> = (0..batch.len()).map(|l| time_of(k * cap + l)).collect();
        let wanted: Vec<Vec<f64>> = ts.iter().map(|&t| want_at(t)).collect();
        let mut u = vec![0.0; lay.u_len];
        let mut cs = vec![1i32; cap * d];
        for (l, cell) in batch.iter().enumerate() {
            for (a, &x) in cell.iter().enumerate() {
                cs[l * d + a] = x as i32;
            }
            for b in &lay.u {
                let w = whole.block(&b.name).expect("a whole block");
                for e in 0..b.extents.iter().product::<usize>() {
                    u[(b.offset + e) * cap + l] = gu[w.slot(&global(&b.name, cell, e)).unwrap()];
                }
            }
        }
        // The padding lanes hold lane 0's state.
        for b in &lay.u {
            for e in 0..b.extents.iter().product::<usize>() {
                for l in batch.len()..cap {
                    u[(b.offset + e) * cap + l] = u[(b.offset + e) * cap];
                }
            }
        }
        let check = |du: &[f64], path: &str| {
            for (l, cell) in batch.iter().enumerate() {
                for b in &lay.u {
                    let w = whole.block(&b.name).expect("a whole block");
                    for e in 0..b.extents.iter().product::<usize>() {
                        let g = global(&b.name, cell, e);
                        assert_eq!(
                            du[(b.offset + e) * cap + l].to_bits(),
                            wanted[l][w.slot(&g).unwrap()].to_bits(),
                            "{path}: {} at {g:?}, t = {}",
                            b.name,
                            ts[l]
                        );
                    }
                }
            }
            if per_lane_times {
                for b in &lay.u {
                    for e in 0..b.extents.iter().product::<usize>() {
                        for l in batch.len()..cap {
                            assert_eq!(
                                du[(b.offset + e) * cap + l].to_bits(),
                                du[(b.offset + e) * cap].to_bits(),
                                "{path}: padding lane {l} of {}",
                                b.name
                            );
                        }
                    }
                }
            }
        };
        let t = ts[0];
        let mut du = vec![f64::NAN; lay.u_len];
        if per_lane_times {
            lanes
                .eval_times_into(&u, &[], &p, &ts, &fs, &cs, batch.len(), &mut du, &mut lws)
                .expect("lane eval at per-lane times");
            check(&du, "eval_times_into");
        } else {
            lanes
                .eval_into(&u, &[], &p, t, &fs, &cs, batch.len(), &mut du, &mut lws)
                .expect("lane eval");
            check(&du, "eval_into");
        }
        lanes
            .gather_lane_inputs(&mut inputs, &p, t, &fs, &cs, batch.len())
            .expect("gather");
        let mut du = vec![f64::NAN; lay.u_len];
        if per_lane_times {
            lanes
                .eval_gathered_times_into(
                    &u,
                    &[],
                    &inputs,
                    &p,
                    &ts,
                    &cs,
                    batch.len(),
                    &mut du,
                    &mut lws,
                )
                .expect("gathered lane eval at per-lane times");
            check(&du, "eval_gathered_times_into");
        } else {
            lanes
                .eval_gathered_into(&u, &[], &inputs, &p, t, &cs, batch.len(), &mut du, &mut lws)
                .expect("gathered lane eval");
            check(&du, "eval_gathered_into");
        }
    }
}

fn columns(sets: &[&str]) -> LaneKind {
    LaneKind::Columns {
        sets: sets.iter().map(|s| s.to_string()).collect(),
    }
}

fn faq_node(out: &[&str], ranges: serde_json::Value, expr: serde_json::Value) -> serde_json::Value {
    json!({"op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr})
}

/// Column lanes read a whole-array `faq` at a vertical (non-lane)
/// subscript: the `faq`'s output index along `z` is bound to the column's
/// own vertical loop symbol. The body also holds nested `faq`s that rebind
/// output-index names (`k`, and the lane index `i`), which shadow them
/// there; and a filtered `faq` with no contraction.
#[test]
fn column_lanes_read_a_whole_array_faq_at_a_vertical_subscript() {
    let (nx, ny, nz) = (3, 2, 4);
    let xyz = json!({"i": {"from": "x"}, "j": {"from": "y"}, "k": {"from": "z"}});
    let u3 = |k: &str| ix("u", vec![json!("i"), json!("j"), json!(k)]);
    let doc = model(
        json!({"x": {"kind": "interval", "size": nx},
               "y": {"kind": "interval", "size": ny},
               "z": {"kind": "interval", "size": nz}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x", "y", "z"], "default": 1.0},
            "v": {"type": "unknown", "units": "1", "shape": ["x", "y", "z"], "default": 1.0},
            "c": {"type": "parameter", "units": "1", "shape": ["z"], "default": [0.5, 1.5, 2.5, 3.5]},
            "w": {"type": "parameter", "units": "1", "shape": ["y"], "default": [0.25, 0.75]}
        }),
        json!([
            {"lhs": d_of(json!("u")),
             "rhs": faq_node(&["i", "j", "k"], xyz.clone(), json!({"op": "+", "args": [
                 {"op": "*", "args": [ix("c", vec![json!("k")]), u3("k"), "t"]},
                 // A column sum: the nested `k` shadows the output `k`.
                 faq_node(&[], json!({"k": {"from": "z"}}), u3("k")),
                 // The nested `i` shadows the lane index `i`.
                 faq_node(&[], json!({"i": [1, 2]}), ix("w", vec![json!("i")]))]}))},
            {"lhs": d_of(json!("v")),
             "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "k"], "ranges": xyz,
                     "filter": {"op": "!=", "args": ["k", "i"]},
                     "expr": {"op": "*", "args": ["k", u3("k")]}}}
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(columns(&["x", "y"]), 4)
        .expect("a whole-array faq read at a vertical subscript builds column lanes");
    assert_lanes_match(&prog, &lanes, &[nx, ny], 0.75);
}

/// A `makearray` whose region values are array `faq`s that are filtered or
/// contract, on a band of the vertical (non-lane) axis that starts above 1
/// and on a single level whose value's range starts elsewhere: each value
/// is read at the region's element, as the whole-domain program places it.
#[test]
fn makearray_faq_region_values_build_lanes() {
    let (nx, ny, nz) = (3, 2, 4);
    let u3 = |k: serde_json::Value| ix("u", vec![json!("i"), json!("j"), k]);
    let all = |n: i64| json!([1, n]);
    let doc = model(
        json!({"x": {"kind": "interval", "size": nx},
               "y": {"kind": "interval", "size": ny},
               "z": {"kind": "interval", "size": nz}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x", "y", "z"], "default": 1.0},
            "v": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 1.0},
            "c": {"type": "parameter", "units": "1", "shape": ["z"], "default": [0.5, 1.5, 2.5, 3.5]}
        }),
        json!([
            {"lhs": d_of(json!("u")),
             "rhs": {"op": "makearray", "args": [],
                     "regions": [
                         [all(nx), all(ny), all(nz)],
                         [all(nx), all(ny), [2, 3]],
                         [all(nx), all(ny), [4, 4]]],
                     "values": [
                         -1.0,
                         // A filtered band on levels 2..3.
                         {"op": "faq", "args": [], "output_idx": ["i", "j", "k"],
                          "ranges": {"i": {"from": "x"}, "j": {"from": "y"}, "k": [2, 3]},
                          "filter": {"op": "!=", "args": ["i", "k"]},
                          "expr": {"op": "*", "args": [ix("c", vec![json!("k")]), u3(json!("k"))]}},
                         // Level 4 holds a column sum over `m`, its own range
                         // `k` running 1..1.
                         {"op": "faq", "args": [], "output_idx": ["i", "j", "k"],
                          "ranges": {"i": {"from": "x"}, "j": {"from": "y"}, "k": [1, 1], "m": {"from": "z"}},
                          "expr": {"op": "*", "args": ["k", ix("c", vec![json!("m")]), u3(json!("m"))]}}
                     ]}},
            {"lhs": d_of(json!("v")),
             "rhs": {"op": "makearray", "args": [],
                     "regions": [[all(nx), all(ny)]],
                     "values": [
                         {"op": "faq", "args": [], "output_idx": ["i", "j"],
                          "ranges": {"i": {"from": "x"}, "j": {"from": "y"}, "m": {"from": "z"}},
                          "filter": {"op": "!=", "args": ["m", "i"]},
                          "expr": {"op": "*", "args": ["j", u3(json!("m"))]}}
                     ]}}
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(columns(&["x", "y"]), 4)
        .expect("a makearray of filtered and contracted faq values builds column lanes");
    assert_lanes_match(&prog, &lanes, &[nx, ny], 0.5);
}

/// An array `faq` carrying `args` (or a `key`) names its output indices
/// outside the body, where a lane does not rewrite them: a structured lane
/// refusal, not a wrong value or a panic.
#[test]
fn an_array_faq_carrying_args_is_refused_by_lanes() {
    let doc = model(
        json!({"x": {"kind": "interval", "size": 3}}),
        json!({"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}}),
        json!([{"lhs": d_of(json!("u")),
                "rhs": {"op": "faq", "args": ["u"], "output_idx": ["i"],
                        "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "*", "args": [-1.0, ix("u", vec![json!("i")])]}}}]),
    );
    let prog = program(&doc, Compiler::Native);
    let err = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            4,
        )
        .expect_err("an array faq with args has no lane form");
    assert!(err.to_string().contains("lane:"), "{err}");
    assert!(err.to_string().contains("`args`"), "{err}");
}

/// U19 at mixed times, on the plain and the pre-gathered path, with the
/// padding lanes checked: a 0-d observed of `t`, an array observed of `t`
/// over the lane set, a parameter read the pre-gather hoists, and one whose
/// subscript is an array observed of `t` (`c[i, q[i]]`), which the
/// pre-gather must not hoist, since its program does not compute `q`.
#[test]
fn lanes_at_mixed_times_match_the_whole_domain_program() {
    let n = 7;
    let doc = model(
        json!({"x": {"kind": "interval", "size": n}, "y": {"kind": "interval", "size": 2}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "c": {"type": "parameter", "units": "1", "shape": ["x", "y"],
                  "default": [[0.5, 5.0], [1.5, 6.0], [2.5, 7.0], [3.5, 8.0],
                              [4.5, 9.0], [5.5, 10.0], [6.5, 11.0]]},
            "k": {"type": "unknown", "units": "1"},
            "g": {"type": "unknown", "units": "1", "shape": ["x"]},
            "q": {"type": "unknown", "units": "1", "shape": ["x"]}
        }),
        json!([
            {"lhs": "k", "rhs": {"op": "+", "args": [1.0, {"op": "sin", "args": ["t"]}]}},
            faq_eq(ix("g", vec![json!("i")]),
                   json!({"op": "*", "args": [ix("c", vec![json!("i"), json!(1)]), "t"]}),
                   json!({"i": {"from": "x"}}), &["i"]),
            faq_eq(ix("q", vec![json!("i")]),
                   json!({"op": "ifelse", "args": [{"op": ">", "args": ["t", 1.0]}, 2, 1]}),
                   json!({"i": {"from": "x"}}), &["i"]),
            faq_eq(
                d_of(ix("u", vec![json!("i")])),
                json!({"op": "+", "args": [
                    {"op": "*", "args": [-1.0, "k", ix("u", vec![json!("i")])]},
                    ix("g", vec![json!("i")]),
                    ix("c", vec![json!("i"), json!(2)]),
                    ix("c", vec![json!("i"), ix("q", vec![json!("i")])])]}),
                json!({"i": {"from": "x"}}),
                &["i"]
            )
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            3,
        )
        .expect("lanes over a time-dependent program");
    assert_eq!(lanes.n_lane_inputs(), 2, "c[i, 1] and c[i, 2] are hoisted");
    let times = [0.25, 3.0, 0.75, 1.5, 0.25, 2.0, 0.5];
    assert_lanes_match_at(&prog, &lanes, &[n], &|c| times[c], true);
    // Equal times: the one-time program.
    assert_lanes_match_at(&prog, &lanes, &[n], &|_| 1.25, true);
    assert_lanes_match(&prog, &lanes, &[n], 1.25);
}

/// An observed of `t` with no lane form (`f[w] = w·t` along a set that is
/// not a lane set, read in `D(u[i]) = Σ_w f[w]·u[i]`) still builds lanes:
/// it stays one whole-domain value per call. The one-time call equals the
/// whole-domain program; a batch at equal times equals the one-time call;
/// a batch at mixed times is an error naming the observed.
#[test]
fn an_observed_of_t_with_no_lane_form_builds_one_time_lanes() {
    let n = 5;
    let doc = model(
        json!({"x": {"kind": "interval", "size": n}, "w": {"kind": "interval", "size": 3}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "f": {"type": "unknown", "units": "1", "shape": ["w"]}
        }),
        json!([
            faq_eq(ix("f", vec![json!("m")]),
                   json!({"op": "*", "args": ["m", "t"]}),
                   json!({"m": {"from": "w"}}), &["m"]),
            {"lhs": d_of(json!("u")),
             "rhs": faq_node(&["i"], json!({"i": {"from": "x"}, "m": {"from": "w"}}),
                 json!({"op": "*", "args": [ix("f", vec![json!("m")]), ix("u", vec![json!("i")])]}))}
        ]),
    );
    let prog = program(&doc, Compiler::Native);
    let lanes = prog
        .lanes(
            LaneKind::Cells {
                sets: vec!["x".to_string()],
            },
            2,
        )
        .expect("an observed of t with no lane form still builds lanes");
    assert_lanes_match(&prog, &lanes, &[n], 0.75);
    assert_lanes_match_at(&prog, &lanes, &[n], &|_| 0.75, true);
    let p = prog
        .parameter_vector(&Default::default())
        .expect("defaults");
    let fs = prog.default_forcing();
    let lay = lanes.layout().clone();
    let u = vec![1.0; lay.u_len];
    let mut du = vec![f64::NAN; lay.u_len];
    let mut ws = lanes.new_workspace();
    let cells = [1, 2];
    let mixed = |r: Result<(), RhsError>| match r {
        Err(e @ RhsError::MixedTimes { .. }) => {
            assert!(e.to_string().contains("M.f"), "{e}")
        }
        other => panic!("expected a mixed-times error, got {other:?}"),
    };
    mixed(lanes.eval_times_into(&u, &[], &p, &[0.5, 1.0], &fs, &cells, 2, &mut du, &mut ws));
    let mut inputs = lanes.lane_inputs();
    lanes
        .gather_lane_inputs(&mut inputs, &p, 0.5, &fs, &cells, 2)
        .expect("gather");
    mixed(lanes.eval_gathered_times_into(
        &u,
        &[],
        &inputs,
        &p,
        &[0.5, 1.0],
        &cells,
        2,
        &mut du,
        &mut ws,
    ));
    // One lane asked for: the padding lane's time is not compared.
    lanes
        .eval_times_into(&u, &[], &p, &[0.5, 1.0], &fs, &cells, 1, &mut du, &mut ws)
        .expect("one lane is never at mixed times");
}
