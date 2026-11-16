use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use std::collections::HashMap;
use std::hint::black_box;

// ---------------------------------------------------------------------------
// Interpolation bracket (issue #588): one right-hand side, three spellings.
// ---------------------------------------------------------------------------

/// One `native` right-hand side of a `bench/interp_bracket` document, ready to
/// call: the compiled model, its scratch, parameters and a state.
struct BracketRhs {
    prob: earthsci_ast::EsmProblem,
    scratch: earthsci_ast::simulate_array::RhsScratch,
    params: Vec<f64>,
    state: Vec<f64>,
}

impl BracketRhs {
    /// Build `bench/interp_bracket/<doc>` under `native`, with the counted
    /// bracket recognised or not ([`earthsci_ast::simulate_array::tape::CompilerRewrites`]).
    fn new(doc: &str, count_rewrite: bool) -> BracketRhs {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bench/interp_bracket")
            .join(doc);
        let mut rewrites = earthsci_ast::simulate_array::tape::CompilerRewrites::default();
        rewrites.count_fold = count_rewrite;
        let prob = earthsci_ast::esm_problem(
            path.as_path(),
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                compiler: Some(earthsci_ast::Compiler::Native),
                rewrites,
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{doc}: {e}"));
        let compiled = prob.debug_array_compiled().expect("a right-hand side");
        let scratch = compiled.debug_new_scratch_taped().expect("taped");
        let params = compiled.debug_resolve_params(prob.p());
        let state = bracket_state(compiled.state_variable_names());
        BracketRhs {
            prob,
            scratch,
            params,
            state,
        }
    }

    fn call(&mut self, dy: &mut [f64]) {
        let compiled = self.prob.debug_array_compiled().expect("a right-hand side");
        compiled.debug_eval_rhs_into(
            &self.state,
            BRACKET_T,
            &self.params,
            dy,
            &mut self.scratch,
            &mut earthsci_ast::simulate_array::RhsStats::default(),
        );
    }
}

/// The time every bracket call is made at: the forcing moves some queries
/// past each end of the axis.
const BRACKET_T: f64 = 1.3;

/// `(variable, 1-based level)` of a state slot name `u[3]`.
fn bracket_slot(name: &str) -> (String, usize) {
    let (var, rest) = name.split_once('[').expect("an array state");
    (
        var.to_string(),
        rest.trim_end_matches(']').parse().expect("a level"),
    )
}

/// A state with every level different: `u = 10 + l/7`, `v = 2 - l/50`,
/// `th = 290 + l/3`.
fn bracket_state(names: &[String]) -> Vec<f64> {
    names
        .iter()
        .map(|n| {
            let (var, l) = bracket_slot(n);
            let l = l as f64;
            match var.as_str() {
                "u" => 10.0 + l / 7.0,
                "v" => 2.0 - l / 50.0,
                _ => 290.0 + l / 3.0,
            }
        })
        .collect()
}

/// The hand-written right-hand side: the formulas of
/// `bench/interp_bracket/generate.py` evaluated once into tables at setup (the
/// axis is a run-time array: nothing here assumes it is sorted until it has
/// checked), then per call one bracket per level found by bisection and three
/// pinned blends. Writes `dy` in the compiled model's state order.
struct HandBracket {
    z: Vec<f64>,
    tables: [Vec<f64>; 3],
    zq: Vec<f64>,
    /// Per state slot: (table, level - 1).
    slots: Vec<(usize, usize)>,
    sorted: bool,
}

impl HandBracket {
    fn new(n: usize, names: &[String], dz0: f64) -> HandBracket {
        let k = |k: usize| k as f64;
        let z: Vec<f64> = (1..=n)
            .map(|i| (k(i) - 1.0) * (dz0 + (k(i) - 1.0)))
            .collect();
        let u = (1..=n)
            .map(|i| (10.0 + 0.5 * k(i)) - 0.002 * (k(i) * k(i)))
            .collect();
        let v = (1..=n).map(|i| 2.0 - 0.05 * k(i)).collect();
        let th = z.iter().map(|&zk| 290.0 + 0.004 * zk).collect();
        let zq = (1..=n)
            .map(|l| {
                let s = k(l) - 0.6;
                s * (100.0 + s)
            })
            .collect();
        let slots = names
            .iter()
            .map(|nm| {
                let (var, l) = bracket_slot(nm);
                let t = match var.as_str() {
                    "u" => 0,
                    "v" => 1,
                    _ => 2,
                };
                (t, l - 1)
            })
            .collect();
        let sorted = z.windows(2).all(|w| w[0] <= w[1]);
        HandBracket {
            z,
            tables: [u, v, th],
            zq,
            slots,
            sorted,
        }
    }

    fn call(&self, state: &[f64], t: f64, dy: &mut [f64]) {
        let n = self.z.len();
        let shift = 150.0 * (0.3 * t).sin();
        for (p, &(tab, l)) in self.slots.iter().enumerate() {
            let x = self.zq[l] + shift;
            let z = &self.z;
            let table = &self.tables[tab];
            let below = if self.sorted {
                z.partition_point(|&a| a <= x)
            } else {
                z.iter().filter(|&&a| a <= x).count()
            };
            let i = below.clamp(1, n - 1) - 1;
            let look = if x <= z[0] {
                table[0]
            } else if x >= z[n - 1] {
                table[n - 1]
            } else {
                let w = (x - z[i]) / (z[i + 1] - z[i]);
                table[i] + w * (table[i + 1] - table[i])
            };
            dy[p] = 0.5 * (look - state[p]);
        }
    }
}

fn benchmark_interp_bracket(c: &mut Criterion) {
    let mut group = c.benchmark_group("interp_bracket");
    for n in [59usize, 200] {
        let docs = [
            (
                "compose_const_fused",
                format!("interp_bracket_const_compose_N{n}.esm"),
                true,
            ),
            (
                "compose_const_unfused",
                format!("interp_bracket_const_compose_N{n}.esm"),
                false,
            ),
            (
                "compose_runtime_fused",
                format!("interp_bracket_runtime_compose_N{n}.esm"),
                true,
            ),
            (
                "compose_runtime_unfused",
                format!("interp_bracket_runtime_compose_N{n}.esm"),
                false,
            ),
        ];
        // Every spelling, and the hand loop, writes the same bits.
        let mut reference: Option<Vec<u64>> = None;
        let mut built = Vec::new();
        for (label, doc, fused) in docs {
            let mut rhs = BracketRhs::new(&doc, fused);
            let mut dy = vec![0.0; rhs.state.len()];
            rhs.call(&mut dy);
            let bits: Vec<u64> = dy.iter().map(|x| x.to_bits()).collect();
            match &reference {
                None => reference = Some(bits),
                Some(r) => assert_eq!(
                    r, &bits,
                    "N={n} {label}: not the first spelling's derivative"
                ),
            }
            built.push((label, rhs));
        }
        let names = built[0]
            .1
            .prob
            .debug_array_compiled()
            .expect("a right-hand side")
            .state_variable_names()
            .to_vec();
        let hand = HandBracket::new(n, &names, 100.0);
        let state = built[0].1.state.clone();
        let mut dy = vec![0.0; state.len()];
        hand.call(&state, BRACKET_T, &mut dy);
        let bits: Vec<u64> = dy.iter().map(|x| x.to_bits()).collect();
        assert_eq!(reference.as_ref(), Some(&bits), "N={n}: the hand loop");

        for (label, rhs) in built.iter_mut() {
            let mut dy = vec![0.0; rhs.state.len()];
            group.bench_function(BenchmarkId::new(*label, n), |b| {
                b.iter(|| {
                    rhs.call(&mut dy);
                    black_box(&dy);
                })
            });
        }
        group.bench_function(BenchmarkId::new("hand_search", n), |b| {
            b.iter(|| {
                hand.call(black_box(&state), BRACKET_T, &mut dy);
                black_box(&dy);
            })
        });
    }
    group.finish();
}

// ---------------------------------------------------------------------------
// Standard-library templates against the closed forms they replace
// (bench/closed_templates/generate.py: calendar, geometry, relational).
// ---------------------------------------------------------------------------

/// One right-hand side of a `bench/closed_templates/generate.py` document under `native`
/// (or the per-cell oracle), with what it cost to get there.
struct TemplateRhs {
    prob: earthsci_ast::EsmProblem,
    /// The taped scratch, or `None` for the per-cell oracle.
    scratch: Option<earthsci_ast::simulate_array::RhsScratch>,
    params: Vec<f64>,
    state: Vec<f64>,
    /// Problem construction plus tape installation, and the first call.
    build_s: f64,
    first_call_s: f64,
}

/// The time the steady calls are made at.
const TEMPLATE_T: f64 = 1.3;

impl TemplateRhs {
    fn new(path: &std::path::Path, oracle: bool) -> TemplateRhs {
        let t0 = std::time::Instant::now();
        let prob = earthsci_ast::esm_problem(
            path,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                compiler: Some(earthsci_ast::Compiler::Native),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let compiled = prob.debug_array_compiled().expect("a right-hand side");
        let scratch = (!oracle).then(|| compiled.debug_new_scratch_taped().expect("taped"));
        let params = compiled.debug_resolve_params(prob.p());
        // A state that differs from cell to cell, the same per name in every
        // spelling, so a regrid's derivative depends on every weight.
        let names = compiled.state_variable_names();
        let mut sorted: Vec<&String> = names.iter().collect();
        sorted.sort();
        let rank: HashMap<&String, usize> = sorted
            .iter()
            .enumerate()
            .map(|(r, n)| (*n, r + 1))
            .collect();
        let state: Vec<f64> = names
            .iter()
            .map(|n| prob.u0().get(n).copied().unwrap_or(0.0) + rank[n] as f64 / 64.0)
            .collect();
        let build_s = t0.elapsed().as_secs_f64();
        let mut rhs = TemplateRhs {
            prob,
            scratch,
            params,
            state,
            build_s,
            first_call_s: 0.0,
        };
        let mut dy = vec![0.0; rhs.state.len()];
        let t1 = std::time::Instant::now();
        rhs.call(0.0, &mut dy);
        rhs.first_call_s = t1.elapsed().as_secs_f64();
        rhs
    }

    fn call(&mut self, t: f64, dy: &mut [f64]) {
        let compiled = self.prob.debug_array_compiled().expect("a right-hand side");
        match &mut self.scratch {
            Some(scratch) => compiled.debug_eval_rhs_into(
                &self.state,
                t,
                &self.params,
                dy,
                scratch,
                &mut earthsci_ast::simulate_array::RhsStats::default(),
            ),
            None => dy.copy_from_slice(&compiled.debug_eval_rhs(&self.state, t, self.prob.p()).0),
        }
    }

    /// `dy` at a few times, as bits.
    fn bits(&mut self) -> Vec<u64> {
        let mut dy = vec![0.0; self.state.len()];
        let mut out = Vec::new();
        for t in [0.0, 0.7, 3.1, 1800.0] {
            self.call(t, &mut dy);
            out.extend(dy.iter().map(|x| x.to_bits()));
        }
        out
    }
}

/// Each template document of `CLOSED_TEMPLATES_DIR` (`*_tpl_*`).
/// `CLOSED_TEMPLATES_FILTER` keeps the names containing it. The documents are
/// not committed: with `CLOSED_TEMPLATES_DIR` unset,
/// `bench/closed_templates/generate.py` writes its default set into
/// `closed_templates` under the temporary directory first.
fn closed_template_documents() -> Vec<std::path::PathBuf> {
    let dir = std::env::var("CLOSED_TEMPLATES_DIR").map_or_else(
        |_| {
            let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../bench/closed_templates/generate.py");
            let dir = std::env::temp_dir().join("closed_templates");
            let status = std::process::Command::new("python3")
                .arg(&script)
                .arg("--out")
                .arg(&dir)
                .status();
            assert!(
                status.is_ok_and(|s| s.success()),
                "python3 {} --out {} failed",
                script.display(),
                dir.display()
            );
            dir
        },
        std::path::PathBuf::from,
    );
    let filter = std::env::var("CLOSED_TEMPLATES_FILTER").unwrap_or_default();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
        .into_iter()
        .filter(|n| n.ends_with(".esm") && n.contains("_tpl_") && n.contains(&filter))
        .map(|n| dir.join(n))
        .collect()
}

fn benchmark_closed_templates(c: &mut Criterion) {
    let mut group = c.benchmark_group("closed_templates");
    group.sample_size(20);
    let nan_eq = |a: &[u64], b: &[u64]| {
        a.len() == b.len()
            && a.iter().zip(b).all(|(x, y)| {
                x == y || (f64::from_bits(*x).is_nan() && f64::from_bits(*y).is_nan())
            })
    };
    for tpl_path in closed_template_documents() {
        let stem = tpl_path
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .replace("_tpl", "");
        let mut tpl = TemplateRhs::new(&tpl_path, false);
        let tb = tpl.bits();
        // The per-cell oracle is slow on the large workloads:
        // `CLOSED_TEMPLATES_ORACLE=0` skips it.
        if std::env::var("CLOSED_TEMPLATES_ORACLE").map_or(true, |v| v != "0") {
            let mut oracle = TemplateRhs::new(&tpl_path, true);
            assert!(
                nan_eq(&tb, &oracle.bits()),
                "{stem}: the template's native derivative is not the oracle's"
            );
        }
        eprintln!(
            "{stem}: states {}  build {:.4}s  first call {:.6}s",
            tpl.state.len(),
            tpl.build_s,
            tpl.first_call_s
        );
        let mut dy = vec![0.0; tpl.state.len()];
        let mut k = 0u64;
        group.bench_function(BenchmarkId::new("tpl", &stem), |b| {
            b.iter(|| {
                k += 1;
                tpl.call(TEMPLATE_T + 1.0e-3 * (k % 1000) as f64, &mut dy);
                black_box(&dy);
            })
        });
    }
    group.finish();
}

// ---------------------------------------------------------------------------
// Templates applied elementwise over array arguments (esm-spec §9.6.11,
// bench/template_array_args): the template form the build lifts per cell, and
// the per-cell `faq` written by hand.
// ---------------------------------------------------------------------------

/// Each `*_tpl_*` document of `TEMPLATE_ARRAY_ARGS_DIR` with its `*_faq_*`
/// spelling. `TEMPLATE_ARRAY_ARGS_FILTER` keeps the names containing
/// it. The documents are not committed: with `TEMPLATE_ARRAY_ARGS_DIR` unset,
/// `bench/template_array_args/generate.py` writes its default set into
/// `template_array_args` under the temporary directory first.
fn template_array_args_pairs() -> Vec<(String, [std::path::PathBuf; 2])> {
    let dir = std::env::var("TEMPLATE_ARRAY_ARGS_DIR").map_or_else(
        |_| {
            let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../bench/template_array_args/generate.py");
            let dir = std::env::temp_dir().join("template_array_args");
            let status = std::process::Command::new("python3")
                .arg(&script)
                .arg("--out")
                .arg(&dir)
                .status();
            assert!(
                status.is_ok_and(|s| s.success()),
                "python3 {} --out {} failed",
                script.display(),
                dir.display()
            );
            dir
        },
        std::path::PathBuf::from,
    );
    let filter = std::env::var("TEMPLATE_ARRAY_ARGS_FILTER").unwrap_or_default();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    let mut out = Vec::new();
    for name in names {
        if !(name.ends_with(".esm") && name.contains("_tpl_") && name.contains(&filter)) {
            continue;
        }
        let faq = dir.join(name.replacen("_tpl_", "_faq_", 1));
        if faq.exists() {
            let stem = name.trim_end_matches(".esm").replacen("_tpl", "", 1);
            out.push((stem, [dir.join(&name), faq]));
        }
    }
    out
}

fn benchmark_template_array_args(c: &mut Criterion) {
    let mut group = c.benchmark_group("template_array_args");
    group.sample_size(20);
    for (stem, paths) in template_array_args_pairs() {
        let mut rhs: Vec<TemplateRhs> = paths.iter().map(|p| TemplateRhs::new(p, false)).collect();
        let bits: Vec<Vec<u64>> = rhs.iter_mut().map(|r| r.bits()).collect();
        // The lift is the hand-written per-cell faq: the same bits, always.
        assert_eq!(
            bits[0], bits[1],
            "{stem}: the lifted template is not the per-cell faq"
        );
        eprintln!(
            "{stem}: states {}  build tpl {:.4}s faq {:.4}s  first call tpl {:.6}s faq {:.6}s",
            rhs[0].state.len(),
            rhs[0].build_s,
            rhs[1].build_s,
            rhs[0].first_call_s,
            rhs[1].first_call_s,
        );
        for (label, r) in ["tpl", "faq"].into_iter().zip(rhs.iter_mut()) {
            let mut dy = vec![0.0; r.state.len()];
            let mut k = 0u64;
            group.bench_function(BenchmarkId::new(label, &stem), |b| {
                b.iter(|| {
                    k += 1;
                    r.call(TEMPLATE_T + 1.0e-3 * (k % 1000) as f64, &mut dy);
                    black_box(&dy);
                })
            });
        }
    }
    group.finish();
}

criterion_group!(
    benches,
    benchmark_interp_bracket,
    benchmark_closed_templates,
    benchmark_template_array_args,
);
criterion_main!(benches);
