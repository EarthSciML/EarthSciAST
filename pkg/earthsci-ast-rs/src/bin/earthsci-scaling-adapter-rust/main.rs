//! Rust adapter for the scaling conformance tier (tests/conformance/scaling/).
//!
//! ```text
//! earthsci-scaling-adapter-rust --index <index.json> --output <results.json>
//!     [--threads T] [--family F ...] [--max-n N] [--timeout-s S] [--max-rss-gb G]
//!     [--oracle-max-states M]
//! ```
//!
//! Reads the generator's `index.json`, measures every listed document under
//! `compiler = native`, and writes the tier's result format (README.md). Each
//! document runs in its own child process (this binary with `--one`), so a
//! timeout, a panic or an out-of-memory kill is recorded as that document's
//! `"error"` and the run carries on; a refusal is recorded as `"refused"` with
//! the compiler's reason text. The parent kills a child whose resident memory
//! passes `--max-rss-gb` (default 12, the same on every machine, so whether a
//! document fits does not depend on the machine), so a document too big is
//! recorded before the machine runs out.
//! After a child that timed out or was killed, the family's larger sizes are
//! recorded as not attempted.
//!
//! Per document the child: builds a warm-up problem (one-time process costs),
//! times `esm_problem` on the document, reads the tape length off the compiled
//! model, evaluates the right-hand side once (first call) and then repeatedly
//! (steady), counts the bytes a steady call allocates through the counting
//! global allocator below, times the family's hand-written loop on the same
//! state and compares its `dy` with native's, and, up to a size cap, compares
//! native's `dy` with the interpreter's.
//!
//! `--threads T` sets the hand loop's thread count. Native Rust does not
//! thread its right-hand side, so a threaded run records native's serial time
//! against the threaded reference.

mod hand_loops;
#[rustfmt::skip]
mod pollu_box;

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{CompileError, Compiler, ProblemOptions, Rhs, SimulateError, esm_problem};
use hand_loops::HandLoop;
use serde_json::{Map, Value, json};

// ---------------------------------------------------------------------------
// Counting allocator
// ---------------------------------------------------------------------------

/// Counts the bytes requested (allocations and reallocations) while
/// `MEASURING` is set. Frees are not counted: the question is whether a
/// steady call asks for memory.
struct CountingAlloc;

static BYTES: AtomicU64 = AtomicU64::new(0);
static MEASURING: AtomicBool = AtomicBool::new(false);

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if MEASURING.load(Ordering::Relaxed) {
            BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if MEASURING.load(Ordering::Relaxed) {
            BYTES.fetch_add(new_size as u64, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------

const MIN_CALLS: usize = 5;
const MAX_CALLS: usize = 1000;
const MIN_TOTAL_S: f64 = 0.25;
const ALLOC_CALLS: u64 = 4;

/// Median wall seconds of `f`, over at least `MIN_CALLS` calls and at least
/// `MIN_TOTAL_S` seconds of calls, at most `MAX_CALLS`.
fn median_time(mut f: impl FnMut()) -> f64 {
    let mut samples = Vec::with_capacity(64);
    let start = Instant::now();
    while samples.len() < MAX_CALLS
        && (samples.len() < MIN_CALLS || start.elapsed().as_secs_f64() < MIN_TOTAL_S)
    {
        let t = Instant::now();
        f();
        samples.push(t.elapsed().as_secs_f64());
    }
    samples.sort_by(|a, b| a.total_cmp(b));
    samples[samples.len() / 2]
}

// ---------------------------------------------------------------------------
// The measured state (README "The measured state")
// ---------------------------------------------------------------------------

fn synthetic(k: usize, default: f64) -> f64 {
    let k = k as f64;
    default * (1.0 + 0.1 * (0.37 * k).sin()) + 0.01 * (1.0 + (0.53 * k).sin())
}

/// A canonical state variable: its name in the document, its extents in
/// declaration order (row-major, last fastest), and its declared default.
struct CanonVar {
    name: String,
    extents: Vec<usize>,
    default: f64,
}

/// The first model of the document: its variables and the model itself.
fn first_model(doc: &Value) -> Result<(&Map<String, Value>, &Value), String> {
    let models = doc["models"].as_object().ok_or("no models")?;
    let (_, m) = models.iter().next().ok_or("no model")?;
    Ok((m["variables"].as_object().ok_or("no variables")?, m))
}

/// The canonical order of `family`'s states, read off the document.
fn canonical_vars(family: &str, doc: &Value) -> Result<Vec<CanonVar>, String> {
    let extent = |set: &str| -> Result<usize, String> {
        doc["index_sets"][set]["size"]
            .as_u64()
            .map(|v| v as usize)
            .ok_or_else(|| format!("index set {set:?} has no size"))
    };
    if family == "chemistry_grid" {
        let species = doc["reaction_systems"]["Pollu"]["species"]
            .as_object()
            .ok_or("no Pollu species")?;
        if !species.keys().eq(pollu_box::SPECIES.iter()) {
            return Err("the document's species order is not the hand loop's".into());
        }
        let ext = vec![extent("lon")?, extent("lat")?];
        return Ok(species
            .iter()
            .map(|(k, v)| CanonVar {
                name: k.clone(),
                extents: ext.clone(),
                default: v["default"].as_f64().unwrap_or(0.0),
            })
            .collect());
    }
    let (vars, _) = first_model(doc)?;
    let var = |name: &str| -> Result<CanonVar, String> {
        let v = vars
            .get(name)
            .ok_or_else(|| format!("no variable {name:?}"))?;
        let extents = match v["shape"].as_array() {
            Some(s) => s
                .iter()
                .map(|a| extent(a.as_str().unwrap_or("")))
                .collect::<Result<_, _>>()?,
            None => Vec::new(),
        };
        Ok(CanonVar {
            name: name.to_string(),
            extents,
            default: v["default"].as_f64().unwrap_or(0.0),
        })
    };
    let names: Vec<&str> = match family {
        "stencil_1d"
        | "stencil_2d"
        | "stencil_3d"
        | "stencil_4d"
        | "prefix_scan"
        | "unstructured_gather" => vec!["u"],
        "transport_3d" => vec!["q"],
        "source_receptor" => vec!["c", "e"],
        "regrid" => vec!["F_src", "F_tgt"],
        // Box-major, species in declaration order: the document's own order.
        "scalar_chemistry" => vars
            .iter()
            .filter(|(_, v)| v["type"] == "unknown")
            .map(|(k, _)| k.as_str())
            .collect(),
        other => return Err(format!("unknown family {other:?}")),
    };
    names.into_iter().map(var).collect()
}

/// `Pollu.NO2[3,4]` / `u[1,2]` / `NO2_17` → (bare variable, 1-based indices).
fn parse_state_name(name: &str) -> (String, Vec<usize>) {
    let (base, idx) = match name.split_once('[') {
        Some((b, rest)) => (
            b,
            rest.trim_end_matches(']')
                .split(',')
                .filter_map(|s| s.trim().parse().ok())
                .collect(),
        ),
        None => (name, Vec::new()),
    };
    let bare = base.rsplit_once('.').map_or(base, |(_, b)| b);
    (bare.to_string(), idx)
}

/// For each native state position its canonical index, and the canonical
/// state vector.
fn layout(names: &[String], vars: &[CanonVar]) -> Result<(Vec<usize>, Vec<f64>), String> {
    let mut offset = HashMap::new();
    let mut total = 0usize;
    let mut canon_state = Vec::new();
    for v in vars {
        let len: usize = v.extents.iter().product();
        offset.insert(v.name.as_str(), (total, v));
        for k in 0..len {
            canon_state.push(synthetic(total + k, v.default));
        }
        total += len;
    }
    if total != names.len() {
        return Err(format!(
            "the canonical order has {total} states, the compiled model {}",
            names.len()
        ));
    }
    let mut perm = Vec::with_capacity(names.len());
    let mut seen = vec![false; total];
    for n in names {
        let (bare, idx) = parse_state_name(n);
        let (off, v) = offset
            .get(bare.as_str())
            .ok_or_else(|| format!("state {n:?} is not in the canonical order"))?;
        if idx.len() != v.extents.len() {
            return Err(format!("state {n:?}: rank differs from {:?}", v.extents));
        }
        let mut flat = 0usize;
        for (i, e) in idx.iter().zip(&v.extents) {
            if *i == 0 || i > e {
                return Err(format!("state {n:?}: index outside {:?}", v.extents));
            }
            flat = flat * e + (i - 1);
        }
        let k = off + flat;
        if std::mem::replace(&mut seen[k], true) {
            return Err(format!("state {n:?} maps onto a canonical index twice"));
        }
        perm.push(k);
    }
    Ok((perm, canon_state))
}

// ---------------------------------------------------------------------------
// Hand loops from the document
// ---------------------------------------------------------------------------

fn param_default(doc: &Value, name: &str) -> Result<f64, String> {
    let (vars, _) = first_model(doc)?;
    vars.get(name)
        .and_then(|v| v["default"].as_f64())
        .ok_or_else(|| format!("no default for parameter {name:?}"))
}

fn build_hand_loop(family: &str, doc: &Value, shape: &Value) -> Result<HandLoop, String> {
    let shape_of = |k: &str| -> Result<usize, String> {
        shape[k]
            .as_u64()
            .map(|v| v as usize)
            .ok_or_else(|| format!("the index entry has no shape.{k}"))
    };
    let set_size = |set: &str| doc["index_sets"][set]["size"].as_u64().unwrap_or(0) as usize;
    Ok(match family {
        "stencil_1d" | "stencil_2d" | "stencil_3d" | "stencil_4d" => HandLoop::Stencil {
            rank: family[8..9].parse().expect("stencil_<rank>d"),
            side: shape_of("side")?,
            kappa: param_default(doc, "kappa")?,
        },
        "transport_3d" => HandLoop::Transport {
            side: shape_of("side")?,
        },
        "chemistry_grid" => {
            let adv = &doc["models"]["Advection"]["variables"];
            HandLoop::ChemistryGrid {
                nlon: shape_of("nlon")?,
                nlat: shape_of("nlat")?,
                u_wind: adv["u_wind"]["default"].as_f64().ok_or("no u_wind")?,
                dx: adv["dx"]["default"].as_f64().ok_or("no dx")?,
            }
        }
        // The document's own formulas for its non-uniform arrays (generate.py),
        // at the 1-based indices it evaluates them at.
        "prefix_scan" => HandLoop::PrefixScan {
            dz: (1..=set_size("x"))
                .map(|i| 100.0 * (1.0 + 0.5 * (i as f64).sin()))
                .collect(),
        },
        "source_receptor" => {
            let n = set_size("rcv");
            let mut k = Vec::with_capacity(n * n);
            // Source-major, the layout the hand loop streams.
            for j in 1..=n {
                for i in 1..=n {
                    k.push(0.001 * (1.0 + (i as f64 * j as f64).sin()));
                }
            }
            HandLoop::SourceReceptor {
                n,
                k,
                kd: param_default(doc, "kd")?,
            }
        }
        "regrid" => HandLoop::Regrid {
            kd: param_default(doc, "kd")?,
            weights: regrid_weights(doc)?,
        },
        "unstructured_gather" => {
            let (_, model) = first_model(doc)?;
            let table = model["equations"]
                .as_array()
                .and_then(|eqs| eqs.iter().find(|e| e["lhs"] == "nbr"))
                .and_then(|e| e["rhs"]["value"].as_array())
                .ok_or("no nbr table")?;
            let mut nbr = Vec::with_capacity(table.len());
            for row in table {
                let r: Vec<usize> = row
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|v| v.as_u64())
                    .map(|v| v as usize - 1)
                    .collect();
                nbr.push(<[usize; 4]>::try_from(r).map_err(|_| "an nbr row is not 4 long")?);
            }
            HandLoop::Unstructured {
                kappa: param_default(doc, "kappa")?,
                nbr,
            }
        }
        "scalar_chemistry" => HandLoop::ScalarChemistry {
            boxes: shape_of("boxes")?,
        },
        other => return Err(format!("no hand loop for family {other:?}")),
    })
}

/// The regrid's weights from its strip geometry. Every polygon is an axis-
/// aligned rectangle of unit height, so an overlap area is the overlap of the
/// lon intervals; pairs are the document's broad-phase candidates (the same
/// `floor(lon_min / dx)` bin, `dx = 2`) whose area exceeds `atol`. `A_j` sums
/// a target's areas in source order and each weight is `A_ij / A_j`, the
/// document's own normalisation.
fn regrid_weights(doc: &Value) -> Result<Vec<Vec<(usize, f64)>>, String> {
    let (_, model) = first_model(doc)?;
    let eqs = model["equations"].as_array().ok_or("no equations")?;
    let lon_ranges = |var: &str| -> Result<Vec<(f64, f64)>, String> {
        let polys = eqs
            .iter()
            .find(|e| e["lhs"] == var)
            .and_then(|e| e["rhs"]["value"].as_array())
            .ok_or_else(|| format!("no {var}"))?;
        Ok(polys
            .iter()
            .map(|p| {
                let lons: Vec<f64> = p
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|v| v[0].as_f64())
                    .collect();
                let lo = lons.iter().copied().fold(f64::INFINITY, f64::min);
                let hi = lons.iter().copied().fold(f64::NEG_INFINITY, f64::max);
                (lo, hi)
            })
            .collect())
    };
    let src = lon_ranges("src_poly")?;
    let tgt = lon_ranges("tgt_poly")?;
    let atol = param_default(doc, "atol")?;
    let dx = param_default(doc, "dx")?;
    let bin = |x: f64| (x / dx).floor();
    Ok(tgt
        .iter()
        .map(|&(tl, th)| {
            let areas: Vec<(usize, f64)> = src
                .iter()
                .enumerate()
                .filter(|(_, (sl, _))| bin(*sl) == bin(tl))
                .map(|(i, &(sl, sh))| (i, (sh.min(th) - sl.max(tl)).max(0.0)))
                .filter(|&(_, a)| a > atol)
                .collect();
            let aj = areas.iter().fold(0.0, |acc, &(_, a)| acc + a);
            areas.into_iter().map(|(i, a)| (i, a / aj)).collect()
        })
        .collect())
}

// ---------------------------------------------------------------------------
// One document (child process)
// ---------------------------------------------------------------------------

struct One {
    doc: PathBuf,
    entry: Value,
    threads: usize,
    oracle_max_states: usize,
}

fn options(compiler: Compiler) -> ProblemOptions {
    ProblemOptions {
        compiler: Some(compiler),
        rhs: Rhs::Always,
        ..Default::default()
    }
}

/// A trivial build, so the measured one does not pay the process's one-time
/// costs (schema compilation, lazily built tables).
fn warm_up() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "warm_up", "authors": ["scaling tier"]},
        "models": {"M": {
            "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0},
                          "k": {"type": "parameter", "units": "1", "default": -1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "*", "args": ["k", "x"]}}]}}
    });
    let _ = esm_problem(&doc, (0.0, 1.0), options(Compiler::Native));
}

/// Max `|a - b|`, counting bit-identical pairs (including matching NaNs) as
/// zero and any other NaN as NaN.
fn max_abs_diff(a: &[f64], b: &[f64]) -> f64 {
    let mut m = 0.0f64;
    for (x, y) in a.iter().zip(b) {
        if x.to_bits() == y.to_bits() {
            continue;
        }
        let d = (x - y).abs();
        if d.is_nan() {
            return f64::NAN;
        }
        m = m.max(d);
    }
    m
}

const FIELDS: [&str; 13] = [
    "reason",
    "build_s",
    "code_size",
    "first_call_s",
    "steady_rhs_s",
    "allocs_per_call",
    "hand_loop_s",
    "hand_loop_max_abs_diff",
    "dy_max_abs",
    "interpreter_max_abs_diff",
    "hand_loop_threads",
    "code_size_detail",
    "peak_rss_bytes",
];

/// A record with every field present and `null`.
fn blank(entry: &Value, status: &str) -> Map<String, Value> {
    let mut r = Map::new();
    for k in ["family", "n", "n_cells", "n_states"] {
        r.insert(k.into(), entry[k].clone());
    }
    r.insert("status".into(), json!(status));
    for k in FIELDS {
        r.insert(k.into(), Value::Null);
    }
    r.insert("code_size_unit".into(), json!("tape_instructions"));
    r
}

fn failed(mut r: Map<String, Value>, msg: String) -> Map<String, Value> {
    r.insert("status".into(), json!("error"));
    r.insert("reason".into(), json!(msg));
    r
}

fn measure_one(one: &One) -> Map<String, Value> {
    let entry = &one.entry;
    let mut r = blank(entry, "ok");
    let family = entry["family"].as_str().unwrap_or("").to_string();

    warm_up();
    let t = Instant::now();
    let built = esm_problem(one.doc.as_path(), (0.0, 1.0), options(Compiler::Native));
    let build_s = t.elapsed().as_secs_f64();
    let prob = match built {
        Ok(p) => p,
        Err(err) => {
            let refused = matches!(
                err,
                SimulateError::Compile(CompileError::CompilerRefusedRule { .. })
            );
            r.insert(
                "status".into(),
                json!(if refused { "refused" } else { "error" }),
            );
            r.insert("reason".into(), json!(err.to_string()));
            if refused {
                check_hand_loop_against_interpreter(one, &family, &mut r);
            }
            return r;
        }
    };
    r.insert("build_s".into(), json!(build_s));
    let Some(compiled) = prob.debug_array_compiled() else {
        return failed(r, "the problem has no right-hand side (static)".into());
    };

    // Code size: the tape the solve builds, over all three cadence sections.
    let tape = compiled.debug_build_tape_report();
    r.insert(
        "code_size".into(),
        json!(tape.n_instr_const + tape.n_instr_segment + tape.n_instr_continuous),
    );
    r.insert(
        "code_size_detail".into(),
        json!({"const": tape.n_instr_const, "segment": tape.n_instr_segment,
               "continuous": tape.n_instr_continuous, "slots": tape.n_slots,
               "gather_plans": tape.n_gather_plans, "fallback_rules": tape.fallbacks.len()}),
    );

    let doc: Value = match std::fs::read_to_string(&one.doc)
        .map_err(|e| e.to_string())
        .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
    {
        Ok(d) => d,
        Err(msg) => return failed(r, format!("rereading the document: {msg}")),
    };
    let names = compiled.state_variable_names().to_vec();
    let (perm, canon_state) = match canonical_vars(&family, &doc).and_then(|v| layout(&names, &v)) {
        Ok(x) => x,
        Err(msg) => return failed(r, format!("mapping the state layout: {msg}")),
    };
    let n = names.len();
    r.insert("n_states".into(), json!(n));
    let state: Vec<f64> = perm.iter().map(|&k| canon_state[k]).collect();
    let params = compiled.debug_resolve_params(prob.p());
    let mut dy = vec![0.0f64; n];
    let mut stats = RhsStats::default();

    let mut scratch = compiled.debug_new_scratch_taped();
    let t = Instant::now();
    compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    r.insert("first_call_s".into(), json!(t.elapsed().as_secs_f64()));
    if stats.fallback_rules > 0 {
        return failed(
            r,
            format!("{} rule(s) left the tape at run time", stats.fallback_rules),
        );
    }
    let native_dy = dy.clone();
    r.insert(
        "dy_max_abs".into(),
        json!(native_dy.iter().fold(0.0f64, |m, v| m.max(v.abs()))),
    );
    let steady = median_time(|| {
        compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats)
    });
    r.insert("steady_rhs_s".into(), json!(steady));
    BYTES.store(0, Ordering::SeqCst);
    MEASURING.store(true, Ordering::SeqCst);
    for _ in 0..ALLOC_CALLS {
        compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    }
    MEASURING.store(false, Ordering::SeqCst);
    r.insert(
        "allocs_per_call".into(),
        json!(BYTES.load(Ordering::SeqCst) / ALLOC_CALLS),
    );
    if max_abs_diff(&dy, &native_dy) != 0.0 {
        return failed(
            r,
            "native's dy changed between calls at the same point".into(),
        );
    }
    drop(scratch);

    // The hand loop, on the canonical order.
    match build_hand_loop(&family, &doc, &entry["shape"]) {
        Ok(hl) => {
            let pool = (one.threads > 1).then(|| {
                rayon::ThreadPoolBuilder::new()
                    .num_threads(one.threads)
                    .build()
                    .expect("a rayon pool")
            });
            let mut hdy = vec![0.0f64; n];
            hl.run(&canon_state, &mut hdy, pool.as_ref());
            let mut native_canon = vec![0.0f64; n];
            for (p, &k) in perm.iter().enumerate() {
                native_canon[k] = native_dy[p];
            }
            r.insert(
                "hand_loop_max_abs_diff".into(),
                json!(max_abs_diff(&hdy, &native_canon)),
            );
            let hand = median_time(|| hl.run(&canon_state, &mut hdy, pool.as_ref()));
            r.insert("hand_loop_s".into(), json!(hand));
            r.insert(
                "hand_loop_threads".into(),
                json!(hl.threads_used(one.threads)),
            );
            r.insert("hand_loop_checked_against".into(), json!("native"));
        }
        Err(msg) => {
            r.insert("hand_loop_error".into(), json!(msg));
        }
    }

    // The interpreter at the same point, where it is affordable.
    if n <= one.oracle_max_states {
        match esm_problem(
            one.doc.as_path(),
            (0.0, 1.0),
            options(Compiler::Interpreter),
        ) {
            Ok(ip) => match ip.debug_array_compiled() {
                Some(ic) if ic.state_variable_names() == names.as_slice() => {
                    let (idy, _) = ic.debug_eval_rhs(&state, 0.0, ip.p(), true);
                    r.insert(
                        "interpreter_max_abs_diff".into(),
                        json!(max_abs_diff(&idy, &native_dy)),
                    );
                }
                _ => {
                    r.insert(
                        "interpreter_error".into(),
                        json!("the interpreter's state order differs from native's"),
                    );
                }
            },
            Err(err) => {
                r.insert("interpreter_error".into(), json!(err.to_string()));
            }
        }
    }
    r
}

/// Where native refuses a document, check the family's hand loop against the
/// interpreter instead, so the reference is already known good when native
/// learns the construct. Only up to the interpreter's size cap.
fn check_hand_loop_against_interpreter(one: &One, family: &str, r: &mut Map<String, Value>) {
    let n_states = one.entry["n_states"].as_u64().unwrap_or(u64::MAX) as usize;
    if n_states > one.oracle_max_states {
        return;
    }
    let outcome = (|| -> Result<f64, String> {
        let ip = esm_problem(
            one.doc.as_path(),
            (0.0, 1.0),
            options(Compiler::Interpreter),
        )
        .map_err(|e| format!("the interpreter: {e}"))?;
        let ic = ip
            .debug_array_compiled()
            .ok_or("the interpreter built no right-hand side")?;
        let text = std::fs::read_to_string(&one.doc).map_err(|e| e.to_string())?;
        let doc: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let names = ic.state_variable_names().to_vec();
        let (perm, canon_state) = layout(&names, &canonical_vars(family, &doc)?)?;
        let state: Vec<f64> = perm.iter().map(|&k| canon_state[k]).collect();
        let (idy, _) = ic.debug_eval_rhs(&state, 0.0, ip.p(), true);
        let mut interp_canon = vec![0.0f64; idy.len()];
        for (p, &k) in perm.iter().enumerate() {
            interp_canon[k] = idy[p];
        }
        let hl = build_hand_loop(family, &doc, &one.entry["shape"])?;
        let mut hdy = vec![0.0f64; idy.len()];
        hl.run(&canon_state, &mut hdy, None);
        r.insert(
            "dy_max_abs".into(),
            json!(idy.iter().fold(0.0f64, |m, v| m.max(v.abs()))),
        );
        Ok(max_abs_diff(&hdy, &interp_canon))
    })();
    match outcome {
        Ok(d) => {
            r.insert("hand_loop_max_abs_diff".into(), json!(d));
            r.insert("hand_loop_checked_against".into(), json!("interpreter"));
        }
        Err(msg) => {
            r.insert("hand_loop_error".into(), json!(msg));
        }
    }
}

// ---------------------------------------------------------------------------
// The run (parent process)
// ---------------------------------------------------------------------------

struct Run {
    index: PathBuf,
    output: PathBuf,
    threads: usize,
    families: Vec<String>,
    max_n: Option<u64>,
    timeout: Duration,
    max_rss_bytes: u64,
    oracle_max_states: usize,
}

const RESULT_TAG: &str = "SCALING_RESULT ";

fn error_record(entry: &Value, reason: String) -> Value {
    Value::Object(failed(blank(entry, "error"), reason))
}

/// A `kB` field of `/proc/<pid>/status` (`VmRSS`, `VmHWM`) in bytes, on Linux.
fn proc_status_bytes(pid: &str, field: &str) -> Option<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let line = s.lines().find(|l| l.starts_with(field))?;
    let kb: u64 = line[field.len()..]
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()?;
    Some(kb * 1024)
}

fn gb(bytes: u64) -> String {
    format!("{:.1}", bytes as f64 / (1u64 << 30) as f64)
}

/// The default `--max-rss-gb`, 12 GB: a hosted runner's 16 GB less room for
/// the runner itself.
const DEFAULT_MAX_RSS: u64 = 12 << 30;

fn run_child(run: &Run, doc: &Path, entry: &Value) -> Value {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => return error_record(entry, format!("cannot find this executable: {e}")),
    };
    let spawned = Command::new(exe)
        .arg("--one")
        .arg(doc)
        .arg("--entry")
        .arg(entry.to_string())
        .arg("--threads")
        .arg(run.threads.to_string())
        .arg("--oracle-max-states")
        .arg(run.oracle_max_states.to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => return error_record(entry, format!("cannot start the child process: {e}")),
    };
    let mut stdout = child.stdout.take().expect("stdout is piped");
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let start = Instant::now();
    let pid = child.id().to_string();
    let mut peak = 0u64;
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Ok(st),
            Ok(None) => {
                let rss = proc_status_bytes(&pid, "VmRSS:").unwrap_or(0);
                peak = peak.max(rss);
                let killed = if rss > run.max_rss_bytes {
                    Some(format!(
                        "out of memory: the process measuring this document reached {} GB \
                         resident after {} s, over this run's --max-rss-gb of {} GB",
                        gb(rss),
                        start.elapsed().as_secs(),
                        gb(run.max_rss_bytes)
                    ))
                } else if start.elapsed() > run.timeout {
                    Some(format!(
                        "timeout: no result within {} s",
                        run.timeout.as_secs()
                    ))
                } else {
                    None
                };
                if let Some(msg) = killed {
                    let _ = child.kill();
                    let _ = child.wait();
                    break Err(msg);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => return error_record(entry, format!("waiting on the child process: {e}")),
        }
    };
    let out = reader.join().unwrap_or_default();
    let with_peak = |mut v: Value| {
        v["peak_rss_bytes"] = json!(peak);
        v
    };
    let status = match status {
        Ok(st) => st,
        Err(msg) => return with_peak(error_record(entry, msg)),
    };
    if let Some(v) = out
        .lines()
        .rev()
        .find_map(|l| l.strip_prefix(RESULT_TAG))
        .and_then(|l| serde_json::from_str::<Value>(l).ok())
    {
        return v;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            return with_peak(error_record(
                entry,
                format!(
                    "the child process was killed by signal {sig} (9 is usually out of memory)"
                ),
            ));
        }
    }
    with_peak(error_record(
        entry,
        format!("the child process exited with {status} and no result"),
    ))
}

/// A record the child did not write (timed out, killed, died): the family's
/// larger sizes would end the same way.
fn child_ended(r: &Value) -> bool {
    r["status"] == "error"
        && r["build_s"].is_null()
        && r["reason"].as_str().is_some_and(|s| {
            [
                "timeout",
                "out of memory",
                "the child process",
                "cannot start",
            ]
            .iter()
            .any(|p| s.starts_with(p))
        })
}

/// The commit measured: `SCALING_COMMIT` when the caller built this binary
/// from a commit it recorded (the Slurm driver does, since the checkout may
/// move on while a queued job waits), else the working tree's `HEAD`.
fn git_commit() -> Value {
    if let Ok(c) = std::env::var("SCALING_COMMIT")
        && !c.trim().is_empty()
    {
        return json!(c.trim());
    }
    Command::new("git")
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| json!(String::from_utf8_lossy(&o.stdout).trim().to_string()))
        .unwrap_or(Value::Null)
}

fn hostname() -> Value {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| json!(s.trim()))
        .or_else(|| std::env::var("HOSTNAME").ok().map(|s| json!(s)))
        .unwrap_or(Value::Null)
}

fn write_output(run: &Run, header: &Map<String, Value>, results: &[Value]) -> Result<(), String> {
    let mut payload = header.clone();
    payload.insert("results".into(), json!(results));
    let text = serde_json::to_string_pretty(&Value::Object(payload)).map_err(|e| e.to_string())?;
    std::fs::write(&run.output, text + "\n").map_err(|e| format!("{:?}: {e}", run.output))
}

fn run_all(run: &Run) -> Result<(), String> {
    let text = std::fs::read_to_string(&run.index).map_err(|e| format!("{:?}: {e}", run.index))?;
    let index: Value = serde_json::from_str(&text).map_err(|e| format!("{:?}: {e}", run.index))?;
    let base = run.index.parent().unwrap_or(Path::new("."));
    let mut header = Map::new();
    header.insert("binding".into(), json!("rust"));
    header.insert("compiler".into(), json!("native"));
    header.insert("threads".into(), json!(run.threads));
    header.insert("commit".into(), git_commit());
    header.insert("host".into(), hostname());
    // Timings want a machine nothing else shares: record how busy this one
    // was when the run started (the 1-, 5- and 15-minute load averages).
    header.insert(
        "load_average".into(),
        std::fs::read_to_string("/proc/loadavg")
            .ok()
            .map(|s| json!(s.split_whitespace().take(3).collect::<Vec<_>>().join(" ")))
            .unwrap_or(Value::Null),
    );
    header.insert(
        "cpus".into(),
        std::thread::available_parallelism()
            .map(|n| json!(n.get()))
            .unwrap_or(Value::Null),
    );
    header.insert(
        "target".into(),
        json!(format!(
            "{}-{}",
            std::env::consts::ARCH,
            std::env::consts::OS
        )),
    );
    header.insert(
        "max_rss_gb".into(),
        json!((run.max_rss_bytes as f64 / (1u64 << 30) as f64 * 10.0).round() / 10.0),
    );
    header.insert("timeout_s".into(), json!(run.timeout.as_secs()));
    let mut results = Vec::new();
    let mut stopped: HashMap<String, String> = HashMap::new();
    let docs = index["documents"]
        .as_array()
        .ok_or("index.json has no documents")?;
    for entry in docs {
        let family = entry["family"].as_str().unwrap_or("");
        if !run.families.is_empty() && !run.families.iter().any(|f| f == family) {
            continue;
        }
        if run
            .max_n
            .is_some_and(|max| entry["n"].as_u64().unwrap_or(0) > max)
        {
            continue;
        }
        let doc = base.join(entry["path"].as_str().unwrap_or(""));
        let t = Instant::now();
        let r = match stopped.get(family) {
            Some(why) => error_record(entry, why.clone()),
            None => run_child(run, &doc, entry),
        };
        if child_ended(&r) {
            stopped.insert(
                family.to_string(),
                format!(
                    "not attempted: the document at n = {} did not finish ({})",
                    entry["n"],
                    r["reason"].as_str().unwrap_or("")
                ),
            );
        }
        let reason = r["reason"]
            .as_str()
            .map(|s| format!(": {}", s.chars().take(160).collect::<String>()))
            .unwrap_or_default();
        eprintln!(
            "scaling-adapter-rust: {family} N={} {} ({:.1} s){reason}",
            entry["n"],
            r["status"].as_str().unwrap_or("?"),
            t.elapsed().as_secs_f64(),
        );
        results.push(r);
        // After every document, so a run that is itself killed keeps what it
        // finished.
        write_output(run, &header, &results)?;
    }
    write_output(run, &header, &results)
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

enum Mode {
    Run(Run),
    One(One),
}

fn parse_args(args: Vec<String>) -> Result<Mode, String> {
    let mut it = args.into_iter();
    let mut index = None;
    let mut output = None;
    let mut threads = 1usize;
    let mut families = Vec::new();
    let mut max_n = None;
    let mut timeout_s = 1800u64;
    let mut max_rss_bytes = DEFAULT_MAX_RSS;
    let mut oracle_max_states = 20_000usize;
    let mut one = None;
    let mut entry = None;
    let num = |v: Option<String>, what: &str| -> Result<u64, String> {
        v.ok_or(format!("{what} needs a value"))?
            .parse()
            .map_err(|e| format!("{what}: {e}"))
    };
    while let Some(a) = it.next() {
        match a.as_str() {
            "--index" => index = it.next().map(PathBuf::from),
            "--output" => output = it.next().map(PathBuf::from),
            "--threads" => threads = num(it.next(), "--threads")? as usize,
            "--family" => families.push(it.next().ok_or("--family needs a value")?),
            "--max-n" => max_n = Some(num(it.next(), "--max-n")?),
            "--timeout-s" => timeout_s = num(it.next(), "--timeout-s")?,
            "--max-rss-gb" => {
                let g: f64 = it
                    .next()
                    .ok_or("--max-rss-gb needs a value")?
                    .parse()
                    .map_err(|e| format!("--max-rss-gb: {e}"))?;
                max_rss_bytes = (g * (1u64 << 30) as f64) as u64;
            }
            "--oracle-max-states" => {
                oracle_max_states = num(it.next(), "--oracle-max-states")? as usize
            }
            "--one" => one = it.next().map(PathBuf::from),
            "--entry" => {
                let s = it.next().ok_or("--entry needs a value")?;
                entry = Some(serde_json::from_str(&s).map_err(|e| format!("--entry: {e}"))?);
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    if let Some(doc) = one {
        return Ok(Mode::One(One {
            doc,
            entry: entry.ok_or("--one needs --entry")?,
            threads: threads.max(1),
            oracle_max_states,
        }));
    }
    match (index, output) {
        (Some(index), Some(output)) => Ok(Mode::Run(Run {
            index,
            output,
            threads: threads.max(1),
            families,
            max_n,
            timeout: Duration::from_secs(timeout_s),
            max_rss_bytes,
            oracle_max_states,
        })),
        _ => Err("--index and --output are required".into()),
    }
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1).collect()) {
        Ok(Mode::One(one)) => {
            let mut r = measure_one(&one);
            let peak = proc_status_bytes("self", "VmHWM:");
            r.insert("peak_rss_bytes".into(), json!(peak));
            println!("{RESULT_TAG}{}", Value::Object(r));
            ExitCode::SUCCESS
        }
        Ok(Mode::Run(run)) => match run_all(&run) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("scaling-adapter-rust: {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("scaling-adapter-rust: {e}");
            ExitCode::FAILURE
        }
    }
}
