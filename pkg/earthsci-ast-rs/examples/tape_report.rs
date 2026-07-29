//! Build the tape program for a model file and print the build report
//! (Step 3a diagnostics — nothing here affects evaluation).
//!
//! Usage:
//!     cargo run --release --example tape_report -- <model.esm> [KEY=VALUE …]
//!
//! Trailing `KEY=VALUE` pairs are integer metaparameters (e.g. `NX=12 NY=7`);
//! with none, the file's own defaults apply (the production grid).

use earthsci_ast::load_path_with_options;
use earthsci_ast::simulate_array::ArrayCompiled;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path: PathBuf = args
        .next()
        .ok_or("usage: tape_report <model.esm> [KEY=VALUE …]")?
        .into();
    let mut mp: BTreeMap<String, i64> = BTreeMap::new();
    for kv in args {
        let (k, v) = kv
            .split_once('=')
            .ok_or_else(|| format!("bad metaparameter `{kv}` (expected KEY=VALUE)"))?;
        mp.insert(
            k.to_string(),
            v.parse().map_err(|e| format!("bad value in `{kv}`: {e}"))?,
        );
    }

    let t0 = Instant::now();
    let file = load_path_with_options(&path, &mp).map_err(|e| format!("load: {e:?}"))?;
    eprintln!(
        "[info] loaded and lowered in {:.2} s",
        t0.elapsed().as_secs_f64()
    );

    let t1 = Instant::now();
    let compiled = ArrayCompiled::from_file(&file).map_err(|e| format!("compile: {e:?}"))?;
    eprintln!(
        "[info] ArrayCompiled::from_file in {:.2} s ({} state slots)",
        t1.elapsed().as_secs_f64(),
        compiled.state_variable_names().len()
    );

    let t2 = Instant::now();
    let report = compiled.debug_build_tape_report();
    let dt = t2.elapsed().as_secs_f64();
    println!("{report}");
    println!("tape build time: {dt:.3} s");
    Ok(())
}
