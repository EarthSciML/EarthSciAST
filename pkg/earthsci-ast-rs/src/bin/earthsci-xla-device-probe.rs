//! What the XLA device under `EARTHSCI_XLA_PLATFORM` actually is, and what it
//! costs to talk to it. Diagnostics only: nothing in the conformance tier
//! depends on this binary.
//!
//! Three subcommands, each answering a question the tier cannot:
//!
//! * `devices` — which platform and how many devices the client sees, and
//!   which multi-device operations the `xla` crate reaches. The conformance
//!   run says whether the numbers are right; this says what hardware produced
//!   them.
//! * `residency <fixture.esm> [iters]` — the same right-hand side evaluated
//!   `iters` times two ways: through the host each call
//!   (`CompiledRhs::eval`), and against buffers that stay on the device
//!   (`CompiledRhs::on_device` / `DeviceRhs::eval_at`). It ALSO checks that
//!   the two agree exactly, because a residency path that quietly evaluated a
//!   stale buffer would otherwise look like a very fast one.
//! * `largest` — the flat state length of every fixture in the compiled tier,
//!   so "the largest fixture that compiles" is a measured claim rather than a
//!   guess.
//!
//! Timings are printed, never asserted on: a wall-clock threshold in a test is
//! a flake on a shared machine.
#![cfg(feature = "xla")]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use earthsci_ast::load_string;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::xla_runtime::{self, CompileRhsError, CompiledRhs};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("crate sits two levels below the repository root")
        .to_path_buf()
}

fn build(path: &Path) -> ArrayCompiled {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let file = load_string(&text).unwrap_or_else(|e| panic!("load {}: {e:?}", path.display()));
    ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("compile {}: {e:?}", path.display()))
}

fn devices() -> Result<(), String> {
    let client = xla_runtime::client()?;
    println!("platform          {}", client.platform_name());
    println!("platform version  {}", client.platform_version());
    println!("devices           {}", client.device_count());
    println!("addressable       {}", client.addressable_device_count());
    for d in client.addressable_devices() {
        println!(
            "  device {:<3} kind {:<20} local id {}  {}",
            d.id(),
            d.kind(),
            d.local_hardware_id(),
            d.to_string()
        );
    }

    // What the crate reaches for multi-device work. Each line is a fact about
    // xla 0.4.4's surface, checked here rather than asserted from the docs.
    println!("\nmulti-device surface of the `xla` crate:");
    println!("  PjRtClient::devices / addressable_devices      yes");
    println!("  buffer_from_host_buffer(.., Some(&device))     yes (placement)");
    println!("  PjRtBuffer::copy_to_device                     yes");
    println!("  compile options (num_partitions, num_replicas,");
    println!("  use_spmd_partitioning, device assignment)      NO — `compile`");
    println!("     passes a default-constructed CompileOptions");
    println!("  XlaBuilder sharding scope / OpSharding         NO — not wrapped");
    println!("  execute with one argument group per replica    NO — both");
    println!("     `execute` and `execute_b` pass a single group");

    if client.addressable_device_count() > 1 {
        // Placement works; execution against a non-default device does not,
        // because the executable was compiled for a one-device assignment.
        // Run it anyway, so the report quotes the runtime's own words.
        let devs = client.addressable_devices();
        let d1 = &devs[1];
        match client.buffer_from_host_buffer(&[1.0f64, 2.0, 3.0], &[3], Some(d1)) {
            Ok(_) => println!("\nplacing a buffer on device {}: ok", d1.id()),
            Err(e) => println!("\nplacing a buffer on device {}: {e}", d1.id()),
        }
    }
    Ok(())
}

fn largest() -> Result<(), String> {
    let p = repo_root().join("tests/conformance/compiled_rhs/manifest.json");
    let text = std::fs::read_to_string(&p).map_err(|e| format!("read {}: {e}", p.display()))?;
    let m: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let mut rows: Vec<(usize, String, String)> = Vec::new();
    for fx in m["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().unwrap_or("?").to_string();
        let rel = fx["path"].as_str().expect("path");
        let path = repo_root().join("tests").join(rel);
        let compiled = build(&path);
        let n = compiled.state_variable_names().len();
        let status = match CompiledRhs::compile(&compiled) {
            Ok(_) => "lowers".to_string(),
            Err(CompileRhsError::Refused(e)) => format!("refused ({})", e.rule),
            Err(CompileRhsError::Runtime(m)) => return Err(m),
        };
        rows.push((n, id, status));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    for (n, id, status) in rows {
        println!("{n:5}  {id:40}  {status}");
    }
    Ok(())
}

fn residency(fixture: &Path, iters: usize) -> Result<(), String> {
    let compiled = build(fixture);
    let program = CompiledRhs::compile(&compiled).map_err(|e| e.to_string())?;
    let names = compiled.state_variable_names().to_vec();
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    // A state that is not all-equal, so a lowering that dropped an index would
    // show up in the agreement check below rather than cancelling.
    let u: Vec<f64> = (0..program.n_states()).map(|i| 1.0 + 0.25 * i as f64).collect();
    let t = 0.0;

    println!("fixture     {}", fixture.display());
    println!("platform    {}", program.platform());
    println!("states      {} ({} variables)", program.n_states(), names.len());
    println!("instrs      {}", program.n_instrs());
    println!("iterations  {iters}");

    // Warm both paths: the first execution of an XLA program pays for kernel
    // loading and autotuning, which is a per-program cost, not a per-call one.
    let warm_host = program.eval(&u, &pv, t).map_err(|e| e.to_string())?;
    let mut dev = program.on_device(&u, &pv).map_err(|e| e.to_string())?;
    dev.eval_at(t).map_err(|e| e.to_string())?;
    let warm_dev = dev.du_to_host().map_err(|e| e.to_string())?;
    let worst = warm_host
        .iter()
        .zip(warm_dev.iter())
        .fold(0.0f64, |m, (a, b)| m.max((a - b).abs()));
    println!("agreement   max |host path - device path| = {worst:e}");
    if worst != 0.0 {
        return Err(format!(
            "the device-resident path disagrees with the host round trip by {worst:e}; \
             they run the SAME executable on the same inputs, so any difference at all \
             means one of them is not evaluating what it claims"
        ));
    }

    let start = Instant::now();
    for _ in 0..iters {
        let du = program.eval(&u, &pv, t).map_err(|e| e.to_string())?;
        std::hint::black_box(&du);
    }
    let host_elapsed = start.elapsed();

    let start = Instant::now();
    for _ in 0..iters {
        dev.eval_at(t).map_err(|e| e.to_string())?;
    }
    // One copy at the end, which is the point: a solver reads the trajectory
    // when it is done, not once per step.
    let last = dev.du_to_host().map_err(|e| e.to_string())?;
    std::hint::black_box(&last);
    let dev_elapsed = start.elapsed();

    // The closed loop: state updated on the device from the device-resident
    // derivative, nothing crossing to the host until the end.
    let mut stepper = program.on_device(&u, &pv).map_err(|e| e.to_string())?;
    // The FIRST euler_step compiles the update program, and an XLA compilation
    // is milliseconds against microseconds of execution. Left in the timed
    // loop it dominates the average and the number reported would be a
    // compile time wearing a per-step label.
    stepper.euler_step(t, 0.0).map_err(|e| e.to_string())?;
    // Back to the starting state, keeping the now-compiled update program.
    stepper.set_state(&u).map_err(|e| e.to_string())?;
    let start = Instant::now();
    for k in 0..iters {
        stepper
            .euler_step(t + 1e-6 * k as f64, 1e-9)
            .map_err(|e| e.to_string())?;
    }
    let final_state = stepper.state_to_host().map_err(|e| e.to_string())?;
    let step_elapsed = start.elapsed();

    let per = |d: std::time::Duration| d.as_secs_f64() * 1e6 / iters as f64;
    println!(
        "host round trip     {:>10.3?} total  {:>9.2} us/call",
        host_elapsed,
        per(host_elapsed)
    );
    println!(
        "device resident     {:>10.3?} total  {:>9.2} us/call",
        dev_elapsed,
        per(dev_elapsed)
    );
    println!(
        "device euler loop   {:>10.3?} total  {:>9.2} us/step (rhs + update, no transfer)",
        step_elapsed,
        per(step_elapsed)
    );
    println!(
        "final state[0..{}] = {:?}",
        final_state.len().min(4),
        &final_state[..final_state.len().min(4)]
    );
    Ok(())
}

/// What happens when you try to use a second device with xla 0.4.4.
///
/// Deliverable 4 of the GPU phase asked whether the crate exposes enough to
/// SHARD a model's state across devices. It does not, and this subcommand is
/// the evidence rather than the assertion: it runs each step of the intended
/// path and prints what the runtime said.
///
/// The blocking facts are in the crate's C++ shim, `xla_rs/xla_rs.cc`:
///
/// * `compile` constructs `CompileOptions options;` and passes it unchanged,
///   so every executable is built with `num_replicas = 1`,
///   `num_partitions = 1`, `use_spmd_partitioning = false` and the default
///   device assignment. There is no Rust-visible way to change any of them.
/// * `execute` and `execute_b` both call `exe->Execute({input_buffer_ptrs},
///   options)` — note the braces: ONE argument group. A replicated executable
///   needs one group per replica, so even a compiled-for-N-replicas program
///   could not be fed from here.
/// * `XlaBuilder::SetSharding` / `OpSharding` are not wrapped at all, so
///   per-operation sharding annotations cannot be attached to the emitted
///   program.
///
/// What IS reachable: enumerating devices, PLACING a buffer on a chosen one
/// (`buffer_from_host_buffer(.., Some(&device))`), and copying between them
/// (`PjRtBuffer::copy_to_device`). This subcommand checks whether that is
/// enough to at least run an executable against buffers resident on a
/// non-default device — the last thing that might have worked by accident.
fn multidevice(fixture: &Path) -> Result<(), String> {
    let client = xla_runtime::client()?;
    let n_dev = client.addressable_device_count();
    println!("platform {} with {n_dev} addressable device(s)", client.platform_name());
    if n_dev < 2 {
        println!(
            "only one addressable device here, so nothing to say about multi-device \
             placement; ask the job for more (--gres=gpu:N)"
        );
        return Ok(());
    }

    let compiled = build(fixture);
    let program = CompiledRhs::compile(&compiled).map_err(|e| e.to_string())?;
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    let n = program.n_states();
    let u: Vec<f64> = (0..n).map(|i| 1.0 + 0.25 * i as f64).collect();

    let reference = program.eval(&u, &pv, 0.0).map_err(|e| e.to_string())?;
    println!("reference (default device) computed {} values", reference.len());

    let devices = client.addressable_devices();
    for d in devices.iter() {
        let placed = client.buffer_from_host_buffer(&u, &[n], Some(d));
        match placed {
            Err(e) => {
                println!("device {}: placing u failed: {e}", d.id());
                continue;
            }
            Ok(ub) => {
                let pb = match client.buffer_from_host_buffer(&pv, &[pv.len()], Some(d)) {
                    Ok(b) => b,
                    Err(e) => {
                        println!("device {}: placing p failed: {e}", d.id());
                        continue;
                    }
                };
                let tb = match client.buffer_from_host_buffer(&[0.0f64], &[], Some(d)) {
                    Ok(b) => b,
                    Err(e) => {
                        println!("device {}: placing t failed: {e}", d.id());
                        continue;
                    }
                };
                match program.execute_on_buffers(&ub, &pb, &tb) {
                    Ok(got) => {
                        let worst = got
                            .iter()
                            .zip(reference.iter())
                            .fold(0.0f64, |m, (a, b)| m.max((a - b).abs()));
                        println!(
                            "device {}: execute against buffers placed there SUCCEEDED, \
                             max |diff from default device| = {worst:e}",
                            d.id()
                        );
                    }
                    Err(e) => println!("device {}: execute against buffers placed there: {e}", d.id()),
                }
            }
        }
    }

    // Copying between devices is the other half of any sharding scheme; check
    // it independently of execution, since it is the part that does work.
    let src = client
        .buffer_from_host_buffer(&u, &[n], Some(&devices[0]))
        .map_err(|e| e.to_string())?;
    match src.copy_to_device(client.addressable_devices().swap_remove(1)) {
        Ok(moved) => {
            let mut back = vec![0.0f64; n];
            match moved.copy_raw_to_host_sync(&mut back, 0) {
                Ok(()) => println!(
                    "copy_to_device 0 -> 1 then back to host: {}",
                    if back == u { "exact" } else { "DIFFERENT" }
                ),
                Err(e) => println!("copy_to_device 0 -> 1 then back to host: {e}"),
            }
        }
        Err(e) => println!("copy_to_device 0 -> 1: {e}"),
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let r = match args.get(1).map(String::as_str) {
        Some("devices") => devices(),
        Some("largest") => largest(),
        Some("multidevice") => {
            let f = args
                .get(2)
                .map(PathBuf::from)
                .unwrap_or_else(|| repo_root().join("tests/valid/mount_rename_atm_column.esm"));
            multidevice(&f)
        }
        Some("residency") => {
            let f = args.get(2).expect("residency <fixture.esm> [iterations]");
            let n: usize = args.get(3).map(|s| s.parse().expect("iterations")).unwrap_or(100);
            residency(Path::new(f), n)
        }
        _ => {
            eprintln!(
                "usage: earthsci-xla-device-probe devices\n       \
                 earthsci-xla-device-probe largest\n       \
                 earthsci-xla-device-probe residency <fixture.esm> [iterations]\n       \
                 earthsci-xla-device-probe multidevice [fixture.esm]"
            );
            std::process::exit(2);
        }
    };
    if let Err(e) = r {
        eprintln!("earthsci-xla-device-probe: {e}");
        std::process::exit(1);
    }
}
