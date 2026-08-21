//! Bit-exact solution dumper (perf verification harness).
//!
//! Loads an `.esm`, integrates it exactly the way `simpleclimate.esm`'s
//! `run-model-rs` does, and writes every solution number as its raw IEEE-754
//! bit pattern — states AND the appended scalar observed trajectories — so two
//! builds can be compared for bit identity with `cmp`/`sha256sum`.
//!
//! Usage:
//!   cargo run --release --no-default-features --example dump_solution -- \
//!       --model PATH [--nx N] [--ny N] [--nz N] [--days D] [--samples N] \
//!       [--solver erk|bdf|sdirk] --out FILE

use std::collections::{BTreeMap, HashMap};
use std::io::Write as _;

use earthsci_ast::{SimulateOptions, SolverChoice, load_path_with_options, simulate};

fn main() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut model = String::new();
    let mut out = String::from("dump.bits");
    let mut days = 0.25f64;
    let mut samples = 11usize;
    let mut solver = SolverChoice::Erk;
    let mut mp: BTreeMap<String, i64> = BTreeMap::new();
    let mut i = 0;
    while i < argv.len() {
        let v = || -> Result<String, String> {
            argv.get(i + 1)
                .cloned()
                .ok_or(format!("{} needs a value", argv[i]))
        };
        match argv[i].as_str() {
            "--model" => model = v()?,
            "--out" => out = v()?,
            "--days" => days = v()?.parse().map_err(|e| format!("--days: {e}"))?,
            "--samples" => samples = v()?.parse().map_err(|e| format!("--samples: {e}"))?,
            "--nx" | "--ny" | "--nz" => {
                let k = argv[i][2..].to_uppercase();
                mp.insert(k, v()?.parse().map_err(|e| format!("{}: {e}", argv[i]))?);
            }
            "--solver" => {
                solver = match v()?.as_str() {
                    "erk" => SolverChoice::Erk,
                    "bdf" => SolverChoice::Bdf,
                    "sdirk" => SolverChoice::Sdirk,
                    s => return Err(format!("unknown solver '{s}'")),
                }
            }
            a => return Err(format!("unrecognized argument: {a}")),
        }
        i += 2;
    }
    if model.is_empty() {
        return Err("--model is required".into());
    }

    let file = load_path_with_options(std::path::Path::new(&model), &mp)
        .map_err(|e| format!("load: {e:?}"))?;
    let tspan = (0.0, days * 86400.0);
    let opts = SimulateOptions {
        solver,
        abstol: 1e-8,
        reltol: 1e-6,
        max_steps: 10_000_000,
        output_times: Some(
            (0..samples.max(2))
                .map(|s| tspan.1 * s as f64 / (samples.max(2) - 1) as f64)
                .collect(),
        ),
        progress: None,
    };
    let t_start = std::time::Instant::now();
    let sol = simulate(&file, tspan, &HashMap::new(), &HashMap::new(), &opts)
        .map_err(|e| format!("simulate: {e:?}"))?;
    eprintln!(
        "[dump] solve {:.2} s, {} rows, {} times, {} rhs calls",
        t_start.elapsed().as_secs_f64(),
        sol.state_variable_names.len(),
        sol.time.len(),
        sol.metadata.n_rhs_calls
    );
    // Rows beyond the flat state vector are the appended scalar observeds.
    let n_obs_rows = sol
        .state_variable_names
        .iter()
        .filter(|n| !n.contains('['))
        .count();
    eprintln!("[dump] {n_obs_rows} rows have no subscript (scalar observeds + scalar states)");

    let f = std::fs::File::create(&out).map_err(|e| format!("{out}: {e}"))?;
    let mut w = std::io::BufWriter::new(f);
    writeln!(
        w,
        "# rows={} times={}",
        sol.state_variable_names.len(),
        sol.time.len()
    )
    .map_err(|e| e.to_string())?;
    for (i, t) in sol.time.iter().enumerate() {
        writeln!(w, "t {i} {:016x}", t.to_bits()).map_err(|e| e.to_string())?;
    }
    for (r, name) in sol.state_variable_names.iter().enumerate() {
        write!(w, "{name}").map_err(|e| e.to_string())?;
        for x in &sol.state[r] {
            write!(w, " {:016x}", x.to_bits()).map_err(|e| e.to_string())?;
        }
        writeln!(w).map_err(|e| e.to_string())?;
    }
    w.flush().map_err(|e| e.to_string())?;
    eprintln!("[dump] wrote {out}");
    Ok(())
}
