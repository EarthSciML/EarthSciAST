//! Closed-AST phase-4 benchmarks, Rust tape side.
//!
//! Times the documents `bench/closed_templates/generate_p4.py` writes (and the
//! phase-3 `nearest_*` pair) under `Compiler::Native`: one right-hand-side
//! call of each spelling, its build, and, where the workload has one, a
//! hand-written loop and an external library computing the same derivative
//! from the document's sidecar data. Every spelling's derivative is checked
//! against the closed form's bits (or, for the geometry leaf and the external
//! libraries, by its largest difference), and the template's against the
//! per-cell oracle's.
//!
//! ```text
//! RUSTFLAGS="-C llvm-args=-align-loops=64" cargo run --release -- <family> [DIR] [filter]
//! ```
//!
//! Families: `search`, `linear`, `bilinear`, `calendar`, `overlap`, `nearest`,
//! `fastjx`, `size`, `all`. DIR defaults to `bench/closed_templates/p4`
//! (`nearest` reads `bench/closed_templates`). Environment: `ORACLE=0` skips
//! the per-cell oracle check, `SAMPLE_MS` (default 30) sets the length of one
//! timing sample, `BUILDS` (default 3) the builds per document.

use std::collections::HashMap;
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::time::Instant;

use earthsci_ast::simulate_array::{RhsScratch, RhsStats};
use earthsci_ast::simulate_array::tape::CompilerRewrites;
use earthsci_ast::{Compiler, EsmProblem, ProblemOptions, Rhs};
use serde_json::Value;

const T_BASE: f64 = 1.3;

fn env_num(k: &str, d: f64) -> f64 {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
}

/// One `native` right-hand side, ready to call.
struct Model {
    prob: EsmProblem,
    scratch: RhsScratch,
    params: Vec<f64>,
    state: Vec<f64>,
    names: Vec<String>,
    build_s: f64,
}

impl Model {
    fn build(path: &Path, count_fold: bool, oracle: bool) -> Model {
        let t0 = Instant::now();
        let mut rewrites = CompilerRewrites::default();
        rewrites.count_fold = count_fold;
        let prob = earthsci_ast::esm_problem(
            path,
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(Compiler::Native),
                rewrites,
                rhs: Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let c = prob.debug_array_compiled().expect("a right-hand side");
        let scratch = if oracle {
            c.debug_new_scratch()
        } else {
            c.debug_new_scratch_taped()
                .unwrap_or_else(|e| panic!("{}: not taped: {e}", path.display()))
        };
        let params = c.debug_resolve_params(prob.p());
        let names = c.state_variable_names().to_vec();
        let state = names
            .iter()
            .map(|n| prob.u0().get(n).copied().unwrap_or(0.0))
            .collect();
        let build_s = t0.elapsed().as_secs_f64();
        Model {
            prob,
            scratch,
            params,
            state,
            names,
            build_s,
        }
    }

    fn call(&mut self, t: f64, dy: &mut [f64]) {
        let c = self.prob.debug_array_compiled().expect("a right-hand side");
        c.debug_eval_rhs_into(
            &self.state,
            t,
            &self.params,
            dy,
            &mut self.scratch,
            &mut RhsStats::default(),
        );
    }

    fn dy(&mut self, t: f64) -> Vec<f64> {
        let mut dy = vec![0.0; self.state.len()];
        self.call(t, &mut dy);
        dy
    }
}

/// The median over `SAMPLE_MS`-long samples of the time per call of `f`, in ns.
/// `f(k)` is the k-th call; callers move `t` with it.
fn time_ns(mut f: impl FnMut(u64)) -> f64 {
    let sample = env_num("SAMPLE_MS", 30.0) / 1.0e3;
    let mut k = 0u64;
    // Calibrate: calls per sample.
    let t0 = Instant::now();
    let mut n = 0u64;
    while t0.elapsed().as_secs_f64() < sample.min(0.01) || n < 3 {
        f(k);
        k += 1;
        n += 1;
    }
    let per = t0.elapsed().as_secs_f64() / n as f64;
    let iters = ((sample / per) as u64).max(1);
    let mut ts: Vec<f64> = (0..11)
        .map(|_| {
            let t = Instant::now();
            for _ in 0..iters {
                f(k);
                k += 1;
            }
            t.elapsed().as_secs_f64() / iters as f64 * 1.0e9
        })
        .collect();
    ts.sort_by(f64::total_cmp);
    ts[ts.len() / 2]
}

fn t_of(k: u64) -> f64 {
    T_BASE + 1.0e-3 * (k % 1000) as f64
}

fn time_model(m: &mut Model) -> f64 {
    let mut dy = vec![0.0; m.state.len()];
    time_ns(|k| {
        m.call(t_of(k), &mut dy);
        black_box(&dy);
    })
}

fn bits_eq(a: &[f64], b: &[f64]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b)
            .all(|(x, y)| x.to_bits() == y.to_bits() || (x.is_nan() && y.is_nan()))
}

fn max_diff(a: &[f64], b: &[f64]) -> f64 {
    a.iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs())
        .fold(0.0, f64::max)
}

/// The template's derivative at a few times against the per-cell oracle's.
fn oracle_check(path: &Path, m: &mut Model) -> &'static str {
    if std::env::var("ORACLE").is_ok_and(|v| v == "0") {
        return "skipped";
    }
    let mut o = Model::build(path, true, true);
    let ok = [0.0, 0.7, T_BASE, 1800.0]
        .iter()
        .all(|&t| bits_eq(&m.dy(t), &o.dy(t)));
    if ok { "bit-identical" } else { "DIFFERS" }
}

/// Build `path` `BUILDS` times; the median build and the last model.
fn build_median(path: &Path, count_fold: bool) -> Model {
    let n = env_num("BUILDS", 3.0) as usize;
    let mut times = Vec::new();
    let mut last = None;
    for _ in 0..n.max(1) {
        let m = Model::build(path, count_fold, false);
        times.push(m.build_s);
        last = Some(m);
    }
    times.sort_by(f64::total_cmp);
    let mut m = last.unwrap();
    m.build_s = times[times.len() / 2];
    m
}

fn load_json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display())))
        .unwrap()
}

fn f64s(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("an array")
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

/// `(variable, 1-based index)` of a state slot name `u[3]`.
fn slot(name: &str) -> (String, usize) {
    let (var, rest) = name.split_once('[').expect("an array state");
    (var.to_string(), rest.trim_end_matches(']').parse().unwrap())
}

fn slots(names: &[String]) -> Vec<usize> {
    names.iter().map(|n| slot(n).1 - 1).collect()
}

fn sizes(dir: &Path, prefix: &str) -> Vec<String> {
    let mut v: Vec<(u64, String)> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter_map(|n| {
            let size = n.strip_prefix(prefix)?.strip_suffix(".esm")?.to_string();
            let key = size
                .split(|c: char| !c.is_ascii_digit())
                .find(|s| !s.is_empty())?
                .parse()
                .ok()?;
            Some((key, size))
        })
        .collect();
    v.sort();
    v.dedup();
    v.into_iter().map(|x| x.1).collect()
}

fn header(cols: &[&str]) {
    println!("{}", cols.join("\t"));
}

// ---------------------------------------------------------------------------
// searchsorted
// ---------------------------------------------------------------------------

fn search(dir: &Path) {
    println!("# searchsorted: ns per right-hand-side call ({} queries); per query = /512", 512);
    header(&[
        "K", "fn", "tpl_binary", "tpl_linear(shuffled)", "tpl_fold(count off)", "hand_linear",
        "hand_binary", "partition_point", "tpl/fn", "tpl_lin/tpl_bin", "bits", "oracle",
    ]);
    for size in sizes(dir, "search_fn_") {
        let p = |sp: &str| dir.join(format!("search_{sp}_{size}.esm"));
        let data = load_json(&dir.join(format!("search_{size}.data.json")));
        let (axis, c) = (f64s(&data["axis"]), f64s(&data["c"]));
        let mut f = Model::build(&p("fn"), true, false);
        let mut tb = Model::build(&p("tpl"), true, false);
        let mut tl = Model::build(&p("lin"), true, false);
        let mut tf = Model::build(&p("tpl"), false, false);
        let reference = f.dy(T_BASE);
        let idx = slots(&f.names);
        let u = f.state.clone();
        let hand = |t: f64, dy: &mut [f64], how: u8| {
            for (s, &q) in idx.iter().enumerate() {
                let x = (c[q] + u[s]) + 0.001 * t;
                let below = match how {
                    0 => axis.iter().filter(|&&a| !(a >= x)).count(),
                    1 => {
                        let (mut lo, mut hi) = (0usize, axis.len());
                        while lo < hi {
                            let mid = lo + (hi - lo) / 2;
                            if !(axis[mid] >= x) {
                                lo = mid + 1;
                            } else {
                                hi = mid;
                            }
                        }
                        lo
                    }
                    _ => axis.partition_point(|&a| a < x),
                };
                dy[s] = (1 + below) as f64 - u[s];
            }
        };
        let mut ok = bits_eq(&tb.dy(T_BASE), &reference)
            && bits_eq(&tl.dy(T_BASE), &reference)
            && bits_eq(&tf.dy(T_BASE), &reference);
        let mut dy = vec![0.0; reference.len()];
        for how in 0..3 {
            hand(T_BASE, &mut dy, how);
            ok &= bits_eq(&dy, &reference);
        }
        let oracle = oracle_check(&p("lin"), &mut tl);
        let (a, b, cc, d) = (
            time_model(&mut f),
            time_model(&mut tb),
            time_model(&mut tl),
            time_model(&mut tf),
        );
        let mut h = [0.0; 3];
        for (how, slot) in h.iter_mut().enumerate() {
            *slot = time_ns(|k| {
                hand(t_of(k), &mut dy, how as u8);
                black_box(&dy);
            });
        }
        println!(
            "{size}\t{a:.0}\t{b:.0}\t{cc:.0}\t{d:.0}\t{:.0}\t{:.0}\t{:.0}\t{:.2}\t{:.2}\t{ok}\t{oracle}",
            h[0],
            h[1],
            h[2],
            b / a,
            cc / b
        );
    }
}

// ---------------------------------------------------------------------------
// linear / bilinear
// ---------------------------------------------------------------------------

fn lerp_cell(axis: &[f64], x: f64) -> (usize, f64) {
    let n = axis.len();
    let below = axis.iter().filter(|&&a| a <= x).count();
    let i = below.clamp(1, n - 1) - 1;
    (i, (x - axis[i]) / (axis[i + 1] - axis[i]))
}

fn hand_linear(table: &[f64], axis: &[f64], x: f64) -> f64 {
    let n = axis.len();
    if x <= axis[0] {
        table[0]
    } else if x >= axis[n - 1] {
        table[n - 1]
    } else {
        let (i, w) = lerp_cell(axis, x);
        table[i] + w * (table[i + 1] - table[i])
    }
}

fn clamp_to(axis: &[f64], x: f64) -> f64 {
    if x <= axis[0] {
        axis[0]
    } else if x >= axis[axis.len() - 1] {
        axis[axis.len() - 1]
    } else {
        x
    }
}

fn hand_bilinear(t: &[Vec<f64>], ax: &[f64], ay: &[f64], x: f64, y: f64) -> f64 {
    let (xc, yc) = (clamp_to(ax, x), clamp_to(ay, y));
    let (i, wx) = lerp_cell(ax, xc);
    let (j, wy) = lerp_cell(ay, yc);
    let r0 = t[i][j] + wx * (t[i + 1][j] - t[i][j]);
    let r1 = t[i][j + 1] + wx * (t[i + 1][j + 1] - t[i][j + 1]);
    r0 + wy * (r1 - r0)
}

fn interp(dir: &Path, family: &str) {
    println!("# {family}: ns per right-hand-side call (512 queries)");
    header(&["K", "fn", "tpl", "hand", "tpl/fn", "bits(tpl,hand vs fn)", "oracle"]);
    for size in sizes(dir, &format!("{family}_fn_")) {
        let p = |sp: &str| dir.join(format!("{family}_{sp}_{size}.esm"));
        let data = load_json(&dir.join(format!("{family}_{size}.data.json")));
        let mut f = Model::build(&p("fn"), true, false);
        let mut tp = Model::build(&p("tpl"), true, false);
        let reference = f.dy(T_BASE);
        let idx = slots(&f.names);
        let u = f.state.clone();
        let c = f64s(&data["c"]);
        let hand: Box<dyn Fn(f64, &mut [f64])> = if family == "linear" {
            let (axis, table) = (f64s(&data["axis"]), f64s(&data["table"]));
            Box::new(move |t, dy| {
                for (s, &q) in idx.iter().enumerate() {
                    let x = (c[q] + u[s]) + 0.001 * t;
                    dy[s] = hand_linear(&table, &axis, x) - u[s];
                }
            })
        } else {
            let (ax, ay, d) = (f64s(&data["axis_x"]), f64s(&data["axis_y"]), f64s(&data["d"]));
            let table: Vec<Vec<f64>> = data["table"].as_array().unwrap().iter().map(f64s).collect();
            Box::new(move |t, dy| {
                for (s, &q) in idx.iter().enumerate() {
                    let x = (c[q] + u[s]) + 0.001 * t;
                    let y = (d[q] + u[s]) + 0.001 * t;
                    dy[s] = hand_bilinear(&table, &ax, &ay, x, y) - u[s];
                }
            })
        };
        let mut dy = vec![0.0; reference.len()];
        hand(T_BASE, &mut dy);
        let ok = bits_eq(&tp.dy(T_BASE), &reference) && bits_eq(&dy, &reference);
        let oracle = oracle_check(&p("tpl"), &mut tp);
        let (a, b) = (time_model(&mut f), time_model(&mut tp));
        let h = time_ns(|k| {
            hand(t_of(k), &mut dy);
            black_box(&dy);
        });
        println!("{size}\t{a:.0}\t{b:.0}\t{h:.0}\t{:.2}\t{ok}\t{oracle}", b / a);
    }
}

// ---------------------------------------------------------------------------
// calendar
// ---------------------------------------------------------------------------

/// The nine §9.2 fields of `t`, summed in generate_p4.py's order, by Hinnant's
/// civil_from_days in integer arithmetic.
fn hand_calendar(t: f64) -> f64 {
    let ft = t.floor();
    let secs = ft as i64;
    let d = secs.div_euclid(86400);
    let s = secs.rem_euclid(86400);
    let z = d + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + 400 * era + i64::from(month <= 2);
    let leap = i64::from(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    let day_of_year = if doy >= 306 { doy - 305 } else { doy + 60 + leap };
    let jd = (d as f64 + 2440588.0) + (((s as f64) - 43200.0) + (t - ft)) / 86400.0;
    (year as f64)
        + month as f64
        + day as f64
        + (s / 3600) as f64
        + ((s / 60) % 60) as f64
        + (s % 60) as f64
        + day_of_year as f64
        + jd
        + leap as f64
}

fn chrono_calendar(t: f64) -> f64 {
    use chrono::{Datelike, Timelike};
    let ft = t.floor();
    let dt = chrono::DateTime::from_timestamp(ft as i64, ((t - ft) * 1.0e9) as u32).expect("in range");
    let d = (dt.num_days_from_ce() - 719163) as f64;
    let s = dt.num_seconds_from_midnight() as f64;
    let jd = (d + 2440588.0) + ((s - 43200.0) + (t - ft)) / 86400.0;
    let leap = chrono::NaiveDate::from_ymd_opt(dt.year(), 1, 1)
        .unwrap()
        .leap_year();
    (dt.year() as f64)
        + dt.month() as f64
        + dt.day() as f64
        + dt.hour() as f64
        + dt.minute() as f64
        + dt.second() as f64
        + dt.ordinal() as f64
        + jd
        + f64::from(u8::from(leap))
}

fn calendar(dir: &Path) {
    println!("# calendar: ns per right-hand-side call (nine fields per timestamp)");
    header(&["H", "fn", "tpl", "hand", "chrono", "tpl/fn", "bits(tpl,hand,chrono vs fn)", "oracle"]);
    for size in sizes(dir, "calendar_fn_") {
        let p = |sp: &str| dir.join(format!("calendar_{sp}_{size}.esm"));
        let data = load_json(&dir.join(format!("calendar_{size}.data.json")));
        let t0 = data["T0"].as_f64().unwrap();
        let mut f = Model::build(&p("fn"), true, false);
        let mut tp = Model::build(&p("tpl"), true, false);
        let reference = f.dy(T_BASE);
        let idx = slots(&f.names);
        let u = f.state.clone();
        let run = |t: f64, dy: &mut [f64], g: fn(f64) -> f64| {
            for (s, &h) in idx.iter().enumerate() {
                let tq = (t0 + 3600.0 * h as f64) + (t + u[s]);
                dy[s] = g(tq) - u[s];
            }
        };
        let mut dy = vec![0.0; reference.len()];
        let mut ok = vec![bits_eq(&tp.dy(T_BASE), &reference)];
        for g in [hand_calendar as fn(f64) -> f64, chrono_calendar] {
            run(T_BASE, &mut dy, g);
            ok.push(bits_eq(&dy, &reference));
        }
        let oracle = oracle_check(&p("tpl"), &mut tp);
        let (a, b) = (time_model(&mut f), time_model(&mut tp));
        let mut hs = [0.0; 2];
        for (i, g) in [hand_calendar as fn(f64) -> f64, chrono_calendar].into_iter().enumerate() {
            hs[i] = time_ns(|k| {
                run(t_of(k), &mut dy, g);
                black_box(&dy);
            });
        }
        println!(
            "{size}\t{a:.0}\t{b:.0}\t{:.0}\t{:.0}\t{:.2}\t{ok:?}\t{oracle}",
            hs[0],
            hs[1],
            b / a
        );
    }
}

// ---------------------------------------------------------------------------
// overlap areas
// ---------------------------------------------------------------------------

fn s2_poly(ring: &[(f64, f64)]) -> s2rst::s2::Polygon {
    use s2rst::s2::{LatLng, Loop, Polygon};
    let pts = ring
        .iter()
        .map(|&(lon, lat)| LatLng::from_degrees(lat, lon).to_point())
        .collect();
    let mut l = Loop::new(pts);
    l.normalize();
    Polygon::from_loops(vec![l])
}

fn rings(v: &Value) -> Vec<Vec<(f64, f64)>> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|r| {
            r.as_array()
                .unwrap()
                .iter()
                .map(|p| (p[0].as_f64().unwrap(), p[1].as_f64().unwrap()))
                .collect()
        })
        .collect()
}

fn overlap(dir: &Path) {
    println!("# overlap: build (setup) seconds, median of BUILDS; per-call ns; areas = the derivative");
    header(&[
        "manifold", "N", "pairs", "leaf_build_s", "tpl_build_s", "tpl/leaf build", "leaf_call_ns",
        "tpl_call_ns", "s2rst_per_pair_ns", "max|tpl-leaf|", "max|s2rst-leaf|", "max|s2rst-tpl|", "oracle",
    ]);
    for size in sizes(dir, "overlap_planar_leaf_") {
        let data = load_json(&dir.join(format!("overlap_{size}.data.json")));
        let (ra, rb) = (rings(&data["ring_a"]), rings(&data["ring_b"]));
        for mf in ["planar", "spherical"] {
            let p = |sp: &str| dir.join(format!("overlap_{mf}_{sp}_{size}.esm"));
            let mut leaf = build_median(&p("leaf"), true);
            let mut tp = build_median(&p("tpl"), true);
            let idx = slots(&leaf.names);
            let (al, at) = (leaf.dy(T_BASE), tp.dy(T_BASE));
            let oracle = if ra.len() <= 2000 {
                oracle_check(&p("tpl"), &mut tp)
            } else {
                "skipped"
            };
            let (cl, ct) = (time_model(&mut leaf), time_model(&mut tp));
            let (ext, d_ext_leaf, d_ext_tpl) = if mf == "spherical" {
                let areas: Vec<f64> = idx
                    .iter()
                    .map(|&q| {
                        let (mut a, mut b) = (s2_poly(&ra[q]), s2_poly(&rb[q]));
                        let c = s2rst::s2::Polygon::intersection(&mut a, &mut b);
                        if c.is_empty_polygon() { 0.0 } else { c.area() }
                    })
                    .collect();
                let mut k = 0usize;
                let per = time_ns(|_| {
                    let q = k % ra.len();
                    k += 1;
                    let (mut a, mut b) = (s2_poly(&ra[q]), s2_poly(&rb[q]));
                    let c = s2rst::s2::Polygon::intersection(&mut a, &mut b);
                    black_box(if c.is_empty_polygon() { 0.0 } else { c.area() });
                });
                (
                    format!("{per:.0}"),
                    format!("{:.3e}", max_diff(&areas, &al)),
                    format!("{:.3e}", max_diff(&areas, &at)),
                )
            } else {
                ("-".into(), "-".into(), "-".into())
            };
            println!(
                "{mf}\t{size}\t{}\t{:.4}\t{:.4}\t{:.2}\t{cl:.0}\t{ct:.0}\t{ext}\t{:.3e}\t{d_ext_leaf}\t{d_ext_tpl}\t{oracle}",
                ra.len(),
                leaf.build_s,
                tp.build_s,
                tp.build_s / leaf.build_s,
                max_diff(&al, &at)
            );
        }
    }
}

// ---------------------------------------------------------------------------
// nearest generator (phase-3 documents)
// ---------------------------------------------------------------------------

fn const_eq(doc: &Value, var: &str) -> Vec<f64> {
    let eqs = doc["models"].as_object().unwrap().values().next().unwrap()["equations"]
        .as_array()
        .unwrap();
    let e = eqs.iter().find(|e| e["lhs"] == var).expect(var);
    f64s(&e["rhs"]["value"])
}

fn nearest(dir: &Path) {
    println!("# nearest-generator argmin: ns per right-hand-side call");
    header(&["size", "op", "tpl", "hand", "tpl/op", "bits(tpl,hand vs op)", "oracle"]);
    for size in sizes(dir, "nearest_op_") {
        let p = |sp: &str| dir.join(format!("nearest_{sp}_{size}.esm"));
        let doc = load_json(&p("op"));
        let (px, py, gx, gy) = (
            const_eq(&doc, "px"),
            const_eq(&doc, "py"),
            const_eq(&doc, "gx"),
            const_eq(&doc, "gy"),
        );
        let mut o = Model::build(&p("op"), true, false);
        let mut tp = Model::build(&p("tpl"), true, false);
        let reference = o.dy(T_BASE);
        let idx = slots(&o.names);
        let w = o.state.clone();
        let hand = |dy: &mut [f64]| {
            for (s, &i) in idx.iter().enumerate() {
                let dist = |k: usize| {
                    let dx = px[i] - gx[k];
                    let dyy = py[i] - gy[k];
                    dx * dx + dyy * dyy
                };
                let (mut best, mut bd) = (0usize, dist(0));
                for k in 1..gx.len() {
                    let d = dist(k);
                    if d < bd {
                        best = k;
                        bd = d;
                    }
                }
                dy[s] = gx[best] - w[s];
            }
        };
        let mut dy = vec![0.0; reference.len()];
        hand(&mut dy);
        let ok = bits_eq(&tp.dy(T_BASE), &reference) && bits_eq(&dy, &reference);
        let oracle = oracle_check(&p("tpl"), &mut tp);
        let (a, b) = (time_model(&mut o), time_model(&mut tp));
        let h = time_ns(|_| {
            hand(&mut dy);
            black_box(&dy);
        });
        println!("{size}\t{a:.0}\t{b:.0}\t{h:.0}\t{:.2}\t{ok}\t{oracle}", b / a);
    }
}

// ---------------------------------------------------------------------------
// FastJX over a grid
// ---------------------------------------------------------------------------

fn fastjx(dir: &Path) {
    println!("# fastjx: real FastJX cross-section tables over a grid; ns per right-hand-side call");
    header(&["cells", "lookups/cell", "fn", "tpl", "tpl/fn", "fn_build_s", "tpl_build_s", "bits", "oracle"]);
    for size in sizes(dir, "fastjx_fn_") {
        let p = |sp: &str| dir.join(format!("fastjx_{sp}_{size}.esm"));
        let data = load_json(&dir.join(format!("fastjx_{size}.data.json")));
        let mut f = build_median(&p("fn"), true);
        let mut tp = build_median(&p("tpl"), true);
        let ok = bits_eq(&tp.dy(T_BASE), &f.dy(T_BASE));
        let oracle = oracle_check(&p("tpl"), &mut tp);
        let (a, b) = (time_model(&mut f), time_model(&mut tp));
        println!(
            "{size}\t{}\t{a:.0}\t{b:.0}\t{:.2}\t{:.4}\t{:.4}\t{ok}\t{oracle}",
            data["lookups"],
            b / a,
            f.build_s,
            tp.build_s
        );
    }
}

// ---------------------------------------------------------------------------
// build time against expression size
// ---------------------------------------------------------------------------

fn size(dir: &Path) {
    println!("# build time (esm_problem + tape) against site count; median of BUILDS");
    header(&["family", "sites", "closed_build_s", "tpl_build_s", "tpl/closed", "closed_call_ns", "tpl_call_ns", "bits"]);
    for (fam, closed) in [
        ("searchsorted", "fn"),
        ("linear", "fn"),
        ("bilinear", "fn"),
        ("calendar", "fn"),
        ("argmin", "op"),
        ("overlap_planar", "leaf"),
    ] {
        for s in sizes(dir, &format!("size_{fam}_{closed}_")) {
            let p = |sp: &str| dir.join(format!("size_{fam}_{sp}_{s}.esm"));
            let mut c = build_median(&p(closed), true);
            let mut tp = build_median(&p("tpl"), true);
            let ok = bits_eq(&tp.dy(T_BASE), &c.dy(T_BASE));
            let (a, b) = (time_model(&mut c), time_model(&mut tp));
            println!(
                "{fam}\t{s}\t{:.4}\t{:.4}\t{:.2}\t{a:.0}\t{b:.0}\t{ok}",
                c.build_s,
                tp.build_s,
                tp.build_s / c.build_s
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let family = args.get(1).map(String::as_str).unwrap_or("all");
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let dir = args
        .get(2)
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("closed_templates/p4"));
    let mut done: HashMap<&str, bool> = HashMap::new();
    let all = family == "all";
    let mut run = |name: &'static str, f: &dyn Fn()| {
        if all || family == name {
            f();
            done.insert(name, true);
        }
    };
    run("search", &|| search(&dir));
    run("linear", &|| interp(&dir, "linear"));
    run("bilinear", &|| interp(&dir, "bilinear"));
    run("calendar", &|| calendar(&dir));
    run("overlap", &|| overlap(&dir));
    run("nearest", &|| {
        let d = args.get(2).map(PathBuf::from).unwrap_or_else(|| root.join("closed_templates"));
        nearest(&d)
    });
    run("fastjx", &|| fastjx(&dir));
    run("size", &|| size(&dir));
    if done.is_empty() {
        eprintln!("unknown family {family}");
        std::process::exit(2);
    }
}
