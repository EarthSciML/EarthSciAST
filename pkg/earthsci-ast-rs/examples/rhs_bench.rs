//! Ad-hoc per-RHS microbenchmark: legacy scratch vs taped scratch.
//! Usage: rhs_bench <model.esm> [KEY=VALUE ...]

use std::collections::{BTreeMap, HashMap};

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or("usage: rhs_bench <model.esm>")?;
    let mut mp: BTreeMap<String, i64> = BTreeMap::new();
    for kv in args {
        let (k, v) = kv.split_once('=').ok_or("KEY=VALUE")?;
        mp.insert(k.to_string(), v.parse().map_err(|e| format!("{e}"))?);
    }
    let file = earthsci_ast::load_path_with_options(std::path::Path::new(&path), &mp)
        .map_err(|e| format!("load: {e:?}"))?;
    let compiled = earthsci_ast::compile_array(file).map_err(|e| format!("compile: {e:?}"))?;
    let n = compiled.state_variable_names().len();
    let params = compiled.debug_resolve_params(&HashMap::new());
    // A plausible positive state.
    let state: Vec<f64> = (0..n).map(|k| 1.0 + 0.1 * ((k as f64) * 0.37).sin()).collect();
    let mut dy = vec![0.0f64; n];

    let only = std::env::var("BENCH_ONLY").unwrap_or_default();
    for (label, taped) in [("legacy", false), ("taped", true)] {
        if !only.is_empty() && only != label {
            continue;
        }
        let mut scratch = if taped {
            compiled.debug_new_scratch_taped()
        } else {
            compiled.debug_new_scratch()
        };
        let mut stats = earthsci_ast::simulate_array::RhsStats::default();
        // Warmup.
        for _ in 0..3 {
            compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
        }
        let iters: usize = std::env::var("BENCH_ITERS").ok().and_then(|v| v.parse().ok()).unwrap_or(30);
        let t0 = std::time::Instant::now();
        for _ in 0..iters {
            compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
        }
        let dt = t0.elapsed().as_secs_f64();
        eprintln!(
            "[bench] {label}: {:.3} ms/RHS  (taped_rules={} fallback={} vec={} scalar={})",
            dt / iters as f64 * 1e3,
            stats.taped_rules,
            stats.fallback_rules,
            stats.vectorized_rules,
            stats.scalar_rules
        );
    }
    Ok(())
}
