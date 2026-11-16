//! Ad-hoc per-RHS microbenchmark: the `interpreter` (per-cell oracle) program
//! against the `native` (taped) one, each through the public program
//! ([`earthsci_ast::rhs_program`]), which evaluates on the calling thread.
//! Usage: rhs_bench <model.esm> [KEY=VALUE ...]

use std::collections::BTreeMap;

use earthsci_ast::{Compiler, ProblemOptions, Rhs, esm_problem, rhs_program};

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or("usage: rhs_bench <model.esm>")?;
    let mut mp: BTreeMap<String, i64> = BTreeMap::new();
    for kv in args {
        let (k, v) = kv.split_once('=').ok_or("KEY=VALUE")?;
        mp.insert(k.to_string(), v.parse().map_err(|e| format!("{e}"))?);
    }

    let only = std::env::var("BENCH_ONLY").unwrap_or_default();
    for (label, compiler) in [
        ("oracle", Compiler::Interpreter),
        ("taped", Compiler::Native),
    ] {
        if !only.is_empty() && only != label {
            continue;
        }
        let prob = esm_problem(
            std::path::Path::new(&path),
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(compiler),
                rhs: Rhs::Always,
                metaparameters: mp.clone(),
                ..Default::default()
            },
        )
        .map_err(|e| format!("build: {e}"))?;
        let prog = rhs_program(&prob).map_err(|e| format!("rhs_program: {e}"))?;
        let n = prog.n_states();
        // A plausible positive state.
        let state: Vec<f64> = (0..n)
            .map(|k| 1.0 + 0.1 * ((k as f64) * 0.37).sin())
            .collect();
        let (_, aux) = prog.default_state();
        let params: Vec<f64> = prog
            .parameters()
            .iter()
            .map(|s| s.default.unwrap_or(0.0))
            .collect();
        let forcing = prog.default_forcing();
        let mut ws = prog.new_workspace();
        let mut dy = vec![0.0f64; n];
        let mut call = |dy: &mut [f64]| {
            prog.eval_into(&state, &aux, &params, 0.0, &forcing, dy, &mut ws)
                .map_err(|e| format!("eval_into: {e}"))
        };
        // Warmup.
        for _ in 0..3 {
            call(&mut dy)?;
        }
        let iters: usize = std::env::var("BENCH_ITERS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(30);
        let t0 = std::time::Instant::now();
        for _ in 0..iters {
            call(&mut dy)?;
        }
        let dt = t0.elapsed().as_secs_f64();
        let report = prob.compiler_report();
        eprintln!(
            "[bench] {label}: {:.3} ms/RHS  (taped={} oracle={})",
            dt / iters as f64 * 1e3,
            report.n_taped(),
            report.n_oracle()
        );
    }
    Ok(())
}
