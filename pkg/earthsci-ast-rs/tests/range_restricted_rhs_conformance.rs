//! The `range_restricted_rhs` conformance suite (CONFORMANCE_SPEC §5.50,
//! `tests/conformance/range_restricted_rhs/README.md`): every case of the
//! manifest, under `Compiler::Native`, each checked bitwise against the same
//! selected program evaluated over the whole domain.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::BTreeSet;
use std::path::PathBuf;

use earthsci_ast::{
    AxisCut, Compiler, Decomposition, LaneKind, ProblemOptions, RhsProgram, RhsSelection,
    SimulateError, TermOrigin, TileBlock, TileBox, TileLayout, esm_problem, rhs_program,
};
use serde_json::Value;

fn suite_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("RANGE_RESTRICTED_RHS_DIR") {
        return PathBuf::from(dir);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/range_restricted_rhs")
}

fn manifest() -> Value {
    let path = suite_dir().join("manifest.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).expect("manifest parses")
}

/// The manifest's state generator: `0.5 + h(v, k)`.
fn state_value(var: &str, k: u32) -> f64 {
    let mut f: u32 = 0x811c_9dc5;
    for b in var.as_bytes() {
        f ^= u32::from(*b);
        f = f.wrapping_mul(0x0100_0193);
    }
    let mut x = f.wrapping_add(0x9e37_79b1u32.wrapping_mul(k));
    x ^= x >> 16;
    x = x.wrapping_mul(0x85eb_ca6b);
    x ^= x >> 13;
    x = x.wrapping_mul(0xc2b2_ae35);
    x ^= x >> 16;
    0.5 + f64::from(x) / 4_294_967_296.0
}

/// The global `(u, aux)` of `prog` in its whole-domain layout.
fn global_state(prog: &RhsProgram) -> (Vec<f64>, Vec<f64>) {
    let lay = prog.layout();
    let fill = |blocks: &[TileBlock], n: usize| {
        let mut x = vec![0.0; n];
        for v in blocks {
            for k in 0..v.len() {
                x[v.base + k] = state_value(&v.name, k as u32 + 1);
            }
        }
        x
    };
    (fill(&lay.u, lay.u_len), fill(&lay.aux, lay.aux_len))
}

fn selection(c: &Value) -> RhsSelection {
    let sel = &c["selection"];
    let writes = match &sel["writes"] {
        Value::Array(a) => Some(a.iter().map(|x| x.as_str().unwrap().to_string()).collect()),
        _ => None,
    };
    let terms = match &sel["terms"] {
        Value::Array(a) => Some(
            a.iter()
                .map(|x| serde_json::from_value::<TermOrigin>(x.clone()).unwrap())
                .collect(),
        ),
        _ => None,
    };
    RhsSelection { writes, terms }
}

fn decomposition(c: &Value) -> Decomposition {
    let d = &c["decomposition"];
    Decomposition {
        axes: d["axes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| AxisCut {
                index_set: a["index_set"].as_str().unwrap().to_string(),
                period: a["period"].as_i64(),
            })
            .collect(),
        faces: d["faces"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                (
                    f[0].as_str().unwrap().to_string(),
                    f[1].as_str().unwrap().to_string(),
                )
            })
            .collect(),
    }
}

fn tile_box(t: &Value) -> TileBox {
    let ranges = |b: &Value| {
        b.as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v[0].as_i64().unwrap()..=v[1].as_i64().unwrap()))
            .collect()
    };
    TileBox {
        owned: ranges(&t["owned"]),
        storage: ranges(&t["storage"]),
    }
}

fn program(c: &Value) -> Result<RhsProgram, SimulateError> {
    let path = suite_dir().join(c["document"].as_str().unwrap());
    let mut opts = ProblemOptions {
        compiler: Some(Compiler::Native),
        ..Default::default()
    };
    if let Some(m) = c["metaparameters"].as_object() {
        for (k, v) in m {
            opts.metaparameters.insert(k.clone(), v.as_i64().unwrap());
        }
    }
    let prob = esm_problem(path.as_path(), (0.0, 1.0), opts)?;
    let prog = rhs_program(&prob)?;
    prog.select(&selection(c))
}

/// The whole-domain reference `G` of `op` at the generated state.
fn reference(op: &RhsProgram) -> Vec<f64> {
    let (u, aux) = global_state(op);
    let p = op.parameter_vector(&Default::default()).expect("defaults");
    let fs = op.default_forcing();
    let mut du = vec![f64::NAN; op.layout().u_len];
    let mut ws = op.new_workspace();
    op.eval_into(&u, &aux, &p, 0.0, &fs, &mut du, &mut ws)
        .expect("whole-domain evaluation");
    du
}

/// The period of an axis on `set` under `dec` (a face set takes its cell
/// set's period).
fn period_of(dec: &Decomposition, set: &str) -> Option<i64> {
    let cell = dec
        .faces
        .iter()
        .find(|(f, _)| f == set)
        .map(|(_, c)| c.as_str())
        .unwrap_or(set);
    dec.axes
        .iter()
        .find(|a| a.index_set == cell)
        .and_then(|a| a.period)
}

/// The global multi-index of each element of `storage` (column-major), or
/// `None` for a dead cell: per the README, an in-domain cell is itself, a cell
/// outside `1..N` on a periodic axis is its wrapped index, any other is dead.
fn storage_cells(
    storage: &[(i64, i64)],
    global: &[(i64, i64)],
    periods: &[Option<i64>],
) -> Vec<Option<Vec<i64>>> {
    let n: usize = storage
        .iter()
        .map(|(lo, hi)| (hi - lo + 1) as usize)
        .product();
    let mut out = Vec::with_capacity(n.max(1));
    if storage.is_empty() {
        out.push(Some(Vec::new()));
        return out;
    }
    for k in 0..n {
        let mut rem = k;
        let mut g = Vec::with_capacity(storage.len());
        let mut dead = false;
        for d in 0..storage.len() {
            let ext = (storage[d].1 - storage[d].0 + 1) as usize;
            let x = storage[d].0 + (rem % ext) as i64;
            rem /= ext;
            let (lo, hi) = global[d];
            if x >= lo && x <= hi {
                g.push(x);
            } else if let Some(p) = periods[d] {
                g.push((x - 1).rem_euclid(p) + 1);
            } else {
                dead = true;
                g.push(x);
            }
        }
        out.push((!dead).then_some(g));
    }
    out
}

fn slot_of(lay: &TileLayout, name: &str, g: &[i64]) -> usize {
    lay.block(name).unwrap().slot(g).unwrap()
}

/// Fill a tile's `(u_S, aux_S)` from the global state.
fn fill_tile(
    tile: &TileLayout,
    whole: &TileLayout,
    dec: &Decomposition,
    gu: &[f64],
    gaux: &[f64],
) -> (Vec<f64>, Vec<f64>) {
    let fill = |blocks: &[TileBlock], n: usize| {
        let mut x = vec![f64::NAN; n];
        for v in blocks {
            let (w, src) = match whole.u.iter().find(|b| b.name == v.name) {
                Some(w) => (w, gu),
                None => (whole.aux.iter().find(|b| b.name == v.name).unwrap(), gaux),
            };
            let periods: Vec<Option<i64>> = (0..v.storage.len())
                .map(|d| v.sets.get(d).and_then(|s| period_of(dec, s)))
                .collect();
            for (k, g) in storage_cells(&v.storage, &w.storage, &periods)
                .into_iter()
                .enumerate()
            {
                if let Some(g) = g {
                    x[v.base + k] = src[w.slot(&g).unwrap()];
                }
            }
        }
        x
    };
    (fill(&tile.u, tile.u_len), fill(&tile.aux, tile.aux_len))
}

/// Every owned cell (global multi-index) of each `u` variable of a tile.
fn owned_cells(tile: &TileLayout) -> Vec<(String, Vec<i64>)> {
    let mut out = Vec::new();
    for v in &tile.u {
        let n: usize = v
            .owned
            .iter()
            .map(|(lo, hi)| (hi - lo + 1) as usize)
            .product();
        for k in 0..n.max(1) {
            let mut rem = k;
            let g: Vec<i64> = v
                .owned
                .iter()
                .map(|&(lo, hi)| {
                    let ext = (hi - lo + 1) as usize;
                    let x = lo + (rem % ext) as i64;
                    rem /= ext;
                    x
                })
                .collect();
            out.push((v.name.clone(), g));
        }
    }
    out
}

fn halo_rows(v: &Value) -> BTreeSet<(String, String, i64, i64)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["variable"].as_str().unwrap().to_string(),
                r["index_set"].as_str().unwrap().to_string(),
                r["lo"].as_i64().unwrap(),
                r["hi"].as_i64().unwrap(),
            )
        })
        .collect()
}

fn code_of(e: &SimulateError) -> String {
    match e {
        SimulateError::RangeRestriction { code, .. } => code.to_string(),
        SimulateError::CompilerUnavailable { .. } => "compiler_unavailable".to_string(),
        other => {
            let s = other.to_string();
            if s.contains("compiler_refused_rule") || s.contains("CompilerRefusedRule") {
                "compiler_refused_rule".to_string()
            } else {
                s
            }
        }
    }
}

fn check_error(e: &SimulateError, expect: &Value) -> Result<(), String> {
    let code = expect["code"].as_str().unwrap();
    let got = code_of(e);
    let msg = e.to_string();
    if got != code && !msg.contains(code) {
        return Err(format!("expected {code}, got {got}: {msg}"));
    }
    for key in ["variable", "index_set"] {
        if let Some(name) = expect[key].as_str()
            && !msg.contains(name)
        {
            return Err(format!(
                "the {code} message does not name {key} `{name}`: {msg}"
            ));
        }
    }
    Ok(())
}

fn tile_partition(c: &Value) -> Result<(), String> {
    let op = program(c).map_err(|e| format!("build: {e}"))?;
    let dec = decomposition(c);
    let halo = op.halo(&dec).map_err(|e| format!("halo: {e}"))?;
    let got: BTreeSet<_> = halo
        .reach
        .iter()
        .map(|((v, s), &(lo, hi))| (v.clone(), s.clone(), lo, hi))
        .collect();
    let want = halo_rows(&c["halo"]);
    if got != want {
        return Err(format!("halo: got {got:?}, want {want:?}"));
    }
    let g = reference(&op);
    let (gu, gaux) = global_state(&op);
    let p = op.parameter_vector(&Default::default()).expect("defaults");
    let fs = op.default_forcing();
    let whole = op.layout().clone();
    for tiling in c["tilings"].as_array().unwrap() {
        let tid = tiling["id"].as_str().unwrap();
        let shared = tiling["shared_storage"].as_bool().unwrap_or(false);
        let mut written = vec![0u32; whole.u_len];
        let mut shared_du: Option<Vec<f64>> = None;
        let mut shared_cells: Vec<(String, Vec<i64>)> = Vec::new();
        let mut shared_layout: Option<TileLayout> = None;
        for t in tiling["tiles"].as_array().unwrap() {
            let tile = op
                .tile(&dec, &tile_box(t))
                .map_err(|e| format!("{tid}: tile {t}: {e}"))?;
            let lay = tile.layout().clone();
            let (u, aux) = fill_tile(&lay, &whole, &dec, &gu, &gaux);
            let (u0, aux0) = (u.clone(), aux.clone());
            let mut du = match shared_du.take() {
                Some(d) if shared => d,
                _ => vec![f64::NAN; lay.u_len],
            };
            let mut ws = tile.new_workspace();
            tile.eval_into(&u, &aux, &p, 0.0, &fs, &mut du, &mut ws)
                .map_err(|e| format!("{tid}: eval {t}: {e}"))?;
            if u.iter().zip(&u0).any(|(a, b)| a.to_bits() != b.to_bits())
                || aux
                    .iter()
                    .zip(&aux0)
                    .any(|(a, b)| a.to_bits() != b.to_bits())
            {
                return Err(format!("{tid}: the call changed its inputs"));
            }
            let cells = owned_cells(&lay);
            for (name, gi) in &cells {
                let ts = slot_of(&lay, name, gi);
                let gs = slot_of(&whole, name, gi);
                if du[ts].to_bits() != g[gs].to_bits() {
                    return Err(format!(
                        "{tid}: tile {t}: {name}{gi:?} = {} but the whole domain gives {}",
                        du[ts], g[gs]
                    ));
                }
                written[gs] += 1;
            }
            if shared {
                shared_cells.extend(cells);
                shared_layout = Some(lay);
                shared_du = Some(du);
            } else {
                let owned: std::collections::HashSet<usize> =
                    cells.iter().map(|(n, gi)| slot_of(&lay, n, gi)).collect();
                for (k, x) in du.iter().enumerate() {
                    if !owned.contains(&k) && !x.is_nan() {
                        return Err(format!(
                            "{tid}: tile {t} wrote du[{k}] = {x} outside its owned rows"
                        ));
                    }
                }
            }
        }
        if let (Some(du), Some(lay)) = (shared_du, shared_layout) {
            let owned: std::collections::HashSet<usize> = shared_cells
                .iter()
                .map(|(n, gi)| slot_of(&lay, n, gi))
                .collect();
            for (k, x) in du.iter().enumerate() {
                if !owned.contains(&k) && !x.is_nan() {
                    return Err(format!(
                        "{tid}: the shared du_S has du[{k}] = {x} outside every owned row"
                    ));
                }
            }
        }
        if let Some(k) = written.iter().position(|&n| n != 1) {
            return Err(format!(
                "{tid}: element {k} of G was written {} times",
                written[k]
            ));
        }
    }
    Ok(())
}

fn tile_one(c: &Value, expect_ok: bool) -> Result<(), String> {
    let op = program(c).map_err(|e| format!("build: {e}"))?;
    let dec = decomposition(c);
    let res = op.tile(&dec, &tile_box(&c["tile"]));
    match (res, expect_ok) {
        (Ok(tile), true) => {
            let g = reference(&op);
            let (gu, gaux) = global_state(&op);
            let whole = op.layout().clone();
            let lay = tile.layout().clone();
            let (u, aux) = fill_tile(&lay, &whole, &dec, &gu, &gaux);
            let mut du = vec![f64::NAN; lay.u_len];
            let mut ws = tile.new_workspace();
            let p = op.parameter_vector(&Default::default()).expect("defaults");
            let fs = op.default_forcing();
            tile.eval_into(&u, &aux, &p, 0.0, &fs, &mut du, &mut ws)
                .map_err(|e| format!("eval: {e}"))?;
            for (name, gi) in owned_cells(&lay) {
                let (ts, gs) = (slot_of(&lay, &name, &gi), slot_of(&whole, &name, &gi));
                if du[ts].to_bits() != g[gs].to_bits() {
                    return Err(format!("{name}{gi:?} = {} but G = {}", du[ts], g[gs]));
                }
            }
            Ok(())
        }
        (Err(e), true) => Err(format!("tile: {e}")),
        (Ok(_), false) => Err("tile succeeded; an error was expected".to_string()),
        (Err(e), false) => check_error(&e, &c["expect_error"]),
    }
}

fn halo_case(c: &Value, expect_ok: bool) -> Result<(), String> {
    let op = program(c).map_err(|e| format!("build: {e}"))?;
    match (op.halo(&decomposition(c)), expect_ok) {
        (Ok(h), true) => {
            let got: BTreeSet<_> = h
                .reach
                .iter()
                .map(|((v, s), &(lo, hi))| (v.clone(), s.clone(), lo, hi))
                .collect();
            let want = halo_rows(&c["halo"]);
            if got == want {
                Ok(())
            } else {
                Err(format!("halo: got {got:?}, want {want:?}"))
            }
        }
        (Err(e), true) => Err(format!("halo: {e}")),
        (Ok(h), false) => Err(format!("halo succeeded ({h:?}); an error was expected")),
        (Err(e), false) => check_error(&e, &c["expect_error"]),
    }
}

fn names(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect()
}

fn selection_sum(c: &Value) -> Result<(), String> {
    let mut whole_case = c.clone();
    whole_case["selection"] = serde_json::json!({"writes": "all", "terms": "all"});
    let full = program(&whole_case).map_err(|e| format!("build: {e}"))?;
    let f = reference(&full);
    let flay = full.layout().clone();
    let mut sum = vec![0.0f64; f.len()];
    let mut abs = vec![0.0f64; f.len()];
    for opv in c["operators"].as_array().unwrap() {
        let mut oc = c.clone();
        oc["selection"] = serde_json::json!({"writes": opv["writes"], "terms": opv["terms"]});
        let op = program(&oc).map_err(|e| format!("select {}: {e}", opv["name"]))?;
        if op.aux() != names(&opv["aux"]).as_slice() {
            return Err(format!(
                "{}: aux {:?}, want {}",
                opv["name"],
                op.aux(),
                opv["aux"]
            ));
        }
        let gk = reference(&op);
        for v in &op.layout().u {
            let fv = flay.block(&v.name).unwrap();
            for k in 0..v.len() {
                sum[fv.base + k] += gk[v.base + k];
                abs[fv.base + k] += gk[v.base + k].abs();
            }
        }
    }
    let rel = c["tolerance"]["rel"].as_f64().unwrap();
    for k in 0..f.len() {
        if (sum[k] - f[k]).abs() > rel * abs[k] {
            return Err(format!(
                "element {k}: sum of operators {} vs F {}",
                sum[k], f[k]
            ));
        }
    }
    Ok(())
}

fn selection_case(c: &Value, expect_ok: bool) -> Result<(), String> {
    match (program(c), expect_ok) {
        (Ok(op), true) => {
            if op.aux() != names(&c["aux"]).as_slice() {
                return Err(format!("aux {:?}, want {}", op.aux(), c["aux"]));
            }
            let g = reference(&op);
            for name in names(&c["zero_rows"]) {
                let v = op
                    .layout()
                    .block(&name)
                    .ok_or(format!("{name} is not written"))?;
                if g[v.base..v.base + v.len()].iter().any(|&x| x != 0.0) {
                    return Err(format!("{name} is not zero"));
                }
            }
            Ok(())
        }
        (Err(e), true) => Err(format!("select: {e}")),
        (Ok(_), false) => Err("select succeeded; an error was expected".to_string()),
        (Err(e), false) => check_error(&e, &c["expect_error"]),
    }
}

fn lane_kind(c: &Value) -> LaneKind {
    let sets = names(&c["lane_sets"]);
    match c["lane_kind"].as_str().unwrap() {
        "cells" => LaneKind::Cells { sets },
        _ => LaneKind::Columns { sets },
    }
}

/// The global multi-index of element `k` (column-major over the block's
/// non-lane sets) of `name` in a lane at `cell`.
fn lane_global(
    whole: &TileLayout,
    name: &str,
    lane_sets: &[String],
    cell: &[i64],
    k: usize,
) -> Vec<i64> {
    let w = whole.block(name).unwrap();
    let mut rem = k;
    let mut g = Vec::with_capacity(w.storage.len());
    for (d, &(lo, hi)) in w.storage.iter().enumerate() {
        let set = w.sets.get(d).map(String::as_str).unwrap_or("");
        if let Some(pos) = lane_sets.iter().position(|s| s == set) {
            g.push(cell[pos]);
        } else {
            let ext = (hi - lo + 1) as usize;
            g.push(lo + (rem % ext) as i64);
            rem /= ext;
        }
    }
    g
}

fn lanes_case(c: &Value) -> Result<(), String> {
    let op = program(c).map_err(|e| format!("build: {e}"))?;
    let cap = c["capacity"].as_u64().unwrap() as usize;
    let lane_sets = names(&c["lane_sets"]);
    let lanes = op
        .lanes(lane_kind(c), cap)
        .map_err(|e| format!("lanes: {e}"))?;
    let g = reference(&op);
    let (gu, gaux) = global_state(&op);
    let p = op.parameter_vector(&Default::default()).expect("defaults");
    let fs = op.default_forcing();
    let whole = op.layout().clone();
    let d = lane_sets.len();
    let lay = lanes.layout().clone();
    if lay.sets != lane_sets || lay.capacity != cap {
        return Err(format!(
            "lane layout sets {:?} / capacity {}",
            lay.sets, lay.capacity
        ));
    }
    let cell_of = |cells: &[i32], l: usize| -> Vec<i64> {
        (0..d).map(|a| i64::from(cells[l * d + a])).collect()
    };
    let n_elems = |b: &earthsci_ast::LaneBlock| b.extents.iter().product::<usize>();
    let gather = |cells: &[i32], n: usize| {
        let mut u = vec![f64::NAN; lay.u_len];
        let mut aux = vec![f64::NAN; lay.aux_len];
        for (blocks, dst) in [(&lay.u, &mut u), (&lay.aux, &mut aux)] {
            for b in blocks {
                let w = whole.block(&b.name).unwrap();
                let src: &[f64] = if whole.u.iter().any(|x| x.name == b.name) {
                    &gu
                } else {
                    &gaux
                };
                for l in 0..n {
                    let cell = cell_of(cells, l);
                    for e in 0..n_elems(b) {
                        let gi = lane_global(&whole, &b.name, &lane_sets, &cell, e);
                        dst[(b.offset + e) * cap + l] = src[w.slot(&gi).unwrap()];
                    }
                }
            }
        }
        (u, aux)
    };
    let matches = |cells: &[i32], n: usize, du: &[f64]| -> Result<(), String> {
        for b in &lay.u {
            let w = whole.block(&b.name).unwrap();
            for l in 0..n {
                let cell = cell_of(cells, l);
                for e in 0..n_elems(b) {
                    let gi = lane_global(&whole, &b.name, &lane_sets, &cell, e);
                    let (got, want) = (du[(b.offset + e) * cap + l], g[w.slot(&gi).unwrap()]);
                    if got.to_bits() != want.to_bits() {
                        return Err(format!(
                            "lane {} {}{gi:?}: {got} vs G {want}",
                            l + 1,
                            b.name
                        ));
                    }
                }
            }
        }
        Ok(())
    };
    for bt in c["batches"].as_array().unwrap() {
        let bid = bt["id"].as_str().unwrap();
        let n = bt["n"].as_u64().unwrap() as usize;
        let cells: Vec<i32> = bt["cells"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|t| {
                t.as_array()
                    .unwrap()
                    .iter()
                    .map(|x| x.as_i64().unwrap() as i32)
                    .collect::<Vec<_>>()
            })
            .collect();
        let (u, aux) = gather(&cells, n);
        let mut du = vec![f64::NAN; lay.u_len];
        let mut ws = lanes.new_workspace();
        lanes
            .eval_into(&u, &aux, &p, 0.0, &fs, &cells, n, &mut du, &mut ws)
            .map_err(|e| format!("{bid}: eval: {e}"))?;
        matches(&cells, n, &du).map_err(|e| format!("{bid}: {e}"))?;
        let mut inputs = lanes.lane_inputs();
        lanes
            .gather_lane_inputs(&mut inputs, &p, 0.0, &fs, &cells, n)
            .map_err(|e| format!("{bid}: gather_lane_inputs: {e}"))?;
        let mut du2 = vec![f64::NAN; lay.u_len];
        lanes
            .eval_gathered_into(&u, &aux, &inputs, &p, 0.0, &cells, n, &mut du2, &mut ws)
            .map_err(|e| format!("{bid}: pre-gathered eval: {e}"))?;
        matches(&cells, n, &du2).map_err(|e| format!("{bid} (pre-gathered): {e}"))?;
        if c["negative_control"]["batch"].as_str() == Some(bid) {
            let sw = c["negative_control"]["swap_lanes"].as_array().unwrap();
            let (a, b2) = (
                sw[0].as_u64().unwrap() as usize - 1,
                sw[1].as_u64().unwrap() as usize - 1,
            );
            let (mut su, mut saux) = (u.clone(), aux.clone());
            for (blocks, dst) in [(&lay.u, &mut su), (&lay.aux, &mut saux)] {
                for b in blocks {
                    for e in 0..n_elems(b) {
                        dst.swap((b.offset + e) * cap + a, (b.offset + e) * cap + b2);
                    }
                }
            }
            let mut du3 = vec![f64::NAN; lay.u_len];
            lanes
                .eval_into(&su, &saux, &p, 0.0, &fs, &cells, n, &mut du3, &mut ws)
                .map_err(|e| format!("{bid}: swapped eval: {e}"))?;
            if matches(&cells, n, &du3).is_ok() {
                return Err(format!(
                    "{bid}: swapping lanes {} and {} did not change the result",
                    a + 1,
                    b2 + 1
                ));
            }
        }
    }
    Ok(())
}

fn lanes_error(c: &Value) -> Result<(), String> {
    let op = program(c).map_err(|e| format!("build: {e}"))?;
    match op.lanes(lane_kind(c), c["capacity"].as_u64().unwrap() as usize) {
        Ok(_) => Err("lanes succeeded; an error was expected".to_string()),
        Err(e) => check_error(&e, &c["expect_error"]),
    }
}

#[test]
fn range_restricted_rhs_manifest() {
    let m = manifest();
    assert_eq!(m["compiler"], "native");
    let only = std::env::var("RANGE_RHS_CASE").ok();
    let mut failures = Vec::new();
    for c in m["cases"].as_array().unwrap() {
        let id = c["id"].as_str().unwrap();
        if only.as_deref().is_some_and(|o| o != id) {
            continue;
        }
        let res = match c["kind"].as_str().unwrap() {
            "tile_partition" => tile_partition(c),
            "tile_ok" => tile_one(c, true),
            "tile_error" => tile_one(c, false),
            "halo_ok" => halo_case(c, true),
            "halo_error" => halo_case(c, false),
            "selection_sum" => selection_sum(c),
            "selection_ok" => selection_case(c, true),
            "selection_error" => selection_case(c, false),
            "lanes" => lanes_case(c),
            "lanes_error" => lanes_error(c),
            other => Err(format!("unknown case kind `{other}`")),
        };
        match res {
            Ok(()) => eprintln!("ok    {id}"),
            Err(e) => {
                eprintln!("FAIL  {id}: {e}");
                failures.push(format!("{id}: {e}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} case(s) failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
