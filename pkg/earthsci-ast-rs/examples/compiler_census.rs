//! Phase-0 compiler census: for each document, what the DEFAULT routing picks
//! and what the array runtime's tape would do with it if it were forced.
//!
//! The "native" compiler under consideration is the array runtime's tape for
//! EVERY document — including the 0-D scalar ones the default router sends to
//! `Backend::Scalar` — refusing any document that leaves a rule on the
//! per-cell fallback path. This example measures the distance between that
//! rule and today's code, one document at a time:
//!
//!   (a) `esm_problem` with default options, recording `backend_kind()`;
//!   (b) the array runtime FORCED — `ArrayCompiled` built the way
//!       `simulate::driver::build_array_compiled` builds it, whether or not
//!       `is_array_file` would have routed here — plus
//!       `debug_build_tape_report()`: rules taped, rules on the fallback path,
//!       and each fallback's deepest bail reason.
//!
//! Each fallback also carries the CADENCE TIER of its rule, because the tape
//! report cannot say WHEN the per-cell path runs: a CONST-tier observed is
//! evaluated once at setup, an RHS rule on every call. See `forced_array`.
//!
//! One JSON object per document on stdout (JSON Lines); progress and panics on
//! stderr. Nothing here affects evaluation: both halves build and discard.
//!
//! Usage:
//!     cargo run --example compiler_census -- <doc.esm> [more.esm …]
//!     cargo run --example compiler_census -- --paths-from <list.txt>
//!
//! A document that panics is reported with its message rather than taking the
//! process down; a document that hangs or is killed emits no line at all, and
//! the driver that invoked this example is what notices the missing one. (No
//! document in either corpus did either, as of 2026-09-21.)

use earthsci_ast::EsmFile;
use earthsci_ast::simulate_array::{ArrayCompiled, file_has_array_ops, file_has_spatial_model};
use earthsci_ast::{Compile, ProblemOptions, esm_problem, flatten, load_path_with_options};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The leading identifier of a `Debug` rendering — `UnsupportedConstruct` out
/// of `UnsupportedConstruct { construct: …`. Used as the error's variant name
/// so the census can histogram build failures without matching every arm of
/// two error enums by hand.
fn variant_of<E: std::fmt::Debug>(e: &E) -> String {
    let s = format!("{e:?}");
    let head: String = s
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if head.is_empty() {
        s.chars().take(40).collect()
    } else {
        head
    }
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

/// Run `f`, converting a panic into `Err(message)`. The panic hook is
/// installed once by `main` and stashes the message here.
fn guarded<T>(sink: &Arc<Mutex<Option<String>>>, f: impl FnOnce() -> T) -> Result<T, String> {
    sink.lock().expect("panic sink").take();
    match std::panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => Ok(v),
        Err(_) => Err(sink
            .lock()
            .expect("panic sink")
            .take()
            .unwrap_or_else(|| "panic (no message)".to_string())),
    }
}

/// (b): build `ArrayCompiled` the way `build_array_compiled` does, then the
/// tape report. Records into `out`.
fn forced_array(file: &EsmFile, out: &mut Map<String, Value>) {
    // `build_array_compiled`'s own preamble: arm the document's precision
    // environment, and work from an annotated copy when (and only when) a
    // variable declares its own `element_type` (esm-spec §11.3.1).
    let env = match earthsci_ast::precision_infer::env_of_file(file) {
        Ok(e) => e,
        Err(e) => {
            out.insert("forced_ok".into(), json!(false));
            out.insert("forced_err_variant".into(), json!(variant_of(&e)));
            out.insert("forced_err".into(), json!(e.to_string()));
            return;
        }
    };
    let _guard = env.enter();
    // `tape_disabled()` short-circuits to true for a document with per-variable
    // element types, whatever the tape managed to lower — so record it.
    out.insert(
        "tape_disabled".into(),
        json!(earthsci_ast::precision::has_variable_overrides()),
    );
    let annotated = match earthsci_ast::precision_infer::annotated(file) {
        Ok(a) => a,
        Err(e) => {
            out.insert("forced_ok".into(), json!(false));
            out.insert("forced_err_variant".into(), json!(variant_of(&e)));
            out.insert("forced_err".into(), json!(e.to_string()));
            return;
        }
    };
    let file = annotated.as_ref().unwrap_or(file);

    // `ArrayCompiled::from_file` takes exactly one raw `Model`, so anything
    // else is flattened into one dot-namespaced system first. That is what
    // `build_array_compiled` does for a COUPLED document; here it also covers
    // the zero-model case — a document whose whole content is a
    // `reaction_systems` block, which has no models at all until flattening
    // lowers its reactions to `D(species, t) = …`. Production never reaches
    // the array runtime with such a document (`is_array_file` is false, so it
    // routes to `Backend::Scalar`), but the census must, because `native` is
    // the tape for EVERY document. The route taken is recorded.
    //
    // (`build_array_compiled` also calls the crate-private
    // `refuse_coupled_subsystem_event` gate here; it is a refusal, not a
    // lowering step, and is not reachable from outside the crate.)
    let n_models = file.models.as_ref().map_or(0, |m| m.len());
    let t = Instant::now();
    out.insert(
        "forced_route".into(),
        json!(if n_models == 1 {
            "from_file"
        } else {
            "flattened"
        }),
    );
    let compiled = if n_models == 1 {
        ArrayCompiled::from_file(file).map_err(|e| (variant_of(&e), e.to_string()))
    } else {
        match flatten(file) {
            Ok(flat) => {
                ArrayCompiled::from_flattened(&flat).map_err(|e| (variant_of(&e), e.to_string()))
            }
            Err(e) => Err((variant_of(&e), e.to_string())),
        }
    };
    out.insert("compile_ms".into(), json!(ms(t)));
    let compiled = match compiled {
        Ok(c) => c,
        Err((v, msg)) => {
            out.insert("forced_ok".into(), json!(false));
            out.insert("forced_err_variant".into(), json!(v));
            out.insert("forced_err".into(), json!(msg));
            return;
        }
    };
    out.insert("forced_ok".into(), json!(true));
    out.insert(
        "has_diff_eqs".into(),
        json!(compiled.has_differential_equations()),
    );
    out.insert(
        "n_state".into(),
        json!(compiled.state_variable_names().len()),
    );

    // The observed cadence partition, so each fallback rule can be attributed
    // to WHEN it is evaluated. This is the build-time-versus-RHS-path split,
    // and the tape report alone cannot make it: `Instr::Fallback` says a rule
    // is on the per-cell path, not how often that path runs.
    //
    // A CONST-tier observed is worse than the report suggests. `solve` calls
    // `hoist_static_observeds` (`simulate_array/driver.rs:518` → `:697`)
    // BEFORE `build_solve_tape` (`:530`), and that hoist evaluates the static
    // rules through `materialize_observeds_into` — the whole-array overlay
    // with the per-cell oracle beneath it — with no tape involved at all. So
    // every CONST rule is evaluated off the tape once per solve, whether or
    // not the tape lowered it.
    let (const_names, discrete_names, continuous_names) = compiled.debug_cadence_partition(&[]);
    out.insert("n_obs_const".into(), json!(const_names.len()));
    out.insert("n_obs_discrete".into(), json!(discrete_names.len()));
    out.insert("n_obs_continuous".into(), json!(continuous_names.len()));
    let tier_of = |name: &str| -> &'static str {
        // The tape names an RHS rule `D(var)` / `D(slot N)`; anything else is
        // an observed rule, named by its variable.
        if name.starts_with("D(") {
            "rhs"
        } else if const_names.iter().any(|n| n == name) {
            "const"
        } else if discrete_names.iter().any(|n| n == name) {
            "discrete"
        } else if continuous_names.iter().any(|n| n == name) {
            "continuous"
        } else {
            "unclassified"
        }
    };

    let t = Instant::now();
    let report = compiled.debug_build_tape_report();
    out.insert("tape_ms".into(), json!(ms(t)));
    out.insert("n_rules".into(), json!(report.n_rules));
    out.insert("n_taped".into(), json!(report.n_taped));
    out.insert("n_fallback".into(), json!(report.fallbacks.len()));
    out.insert(
        "n_instr".into(),
        json!(report.n_instr_const + report.n_instr_segment + report.n_instr_continuous),
    );
    out.insert("slab_bytes".into(), json!(report.slab_bytes));
    out.insert(
        "fallbacks".into(),
        Value::Array(
            report
                .fallbacks
                .iter()
                .map(
                    |(rule, reason)| json!({"rule": rule, "reason": reason, "tier": tier_of(rule)}),
                )
                .collect(),
        ),
    );
}

fn census_one(path: &Path, sink: &Arc<Mutex<Option<String>>>) -> Value {
    let mut out = Map::new();
    out.insert("path".into(), json!(path.display().to_string()));

    // (a) default routing, from the public one-shot entry, exactly as a caller
    // would get it. `tspan` is irrelevant to construction; `Compile::Auto` is
    // the default and is what decides `Backend::Static`.
    let t = Instant::now();
    let default = guarded(sink, || {
        esm_problem(
            path,
            (0.0, 1.0),
            ProblemOptions {
                compile: Compile::Auto,
                ..Default::default()
            },
        )
        .map(|p| p.backend_kind().to_string())
        .map_err(|e| (variant_of(&e), e.to_string()))
    });
    out.insert("default_ms".into(), json!(ms(t)));
    match default {
        Ok(Ok(kind)) => {
            out.insert("default_backend".into(), json!(kind));
        }
        Ok(Err((variant, msg))) => {
            out.insert("default_err_variant".into(), json!(variant));
            out.insert("default_err".into(), json!(msg));
        }
        Err(p) => {
            out.insert("default_err_variant".into(), json!("PANIC"));
            out.insert("default_err".into(), json!(p));
        }
    }

    // (b) the array runtime forced. Load once more here because `esm_problem`
    // consumed its own parse; the load itself is part of what a compiler
    // front end pays, so it is timed separately.
    let t = Instant::now();
    let loaded = guarded(sink, || {
        load_path_with_options(path, &BTreeMap::new()).map_err(|e| (variant_of(&e), e.to_string()))
    });
    out.insert("load_ms".into(), json!(ms(t)));
    let file = match loaded {
        Ok(Ok(f)) => f,
        Ok(Err((variant, msg))) => {
            out.insert("load_err_variant".into(), json!(variant));
            out.insert("load_err".into(), json!(msg));
            out.insert("forced_ok".into(), json!(false));
            return Value::Object(out);
        }
        Err(p) => {
            out.insert("load_err_variant".into(), json!("PANIC"));
            out.insert("load_err".into(), json!(p));
            out.insert("forced_ok".into(), json!(false));
            return Value::Object(out);
        }
    };
    out.insert(
        "n_models".into(),
        json!(file.models.as_ref().map_or(0, |m| m.len())),
    );
    // `is_array_file` (the crate-private router predicate) spelled out from its
    // two public halves — this is the bit that decides Array vs Scalar once a
    // document has differential equations.
    out.insert(
        "is_array_file".into(),
        json!(file_has_array_ops(&file) || file_has_spatial_model(&file)),
    );

    match guarded(sink, || {
        let mut sub = Map::new();
        forced_array(&file, &mut sub);
        sub
    }) {
        Ok(sub) => out.extend(sub),
        Err(p) => {
            out.insert("forced_ok".into(), json!(false));
            out.insert("forced_err_variant".into(), json!("PANIC"));
            out.insert("forced_err".into(), json!(p));
        }
    }
    Value::Object(out)
}

fn main() -> Result<(), String> {
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--paths-from" {
            let list = args.next().ok_or("--paths-from needs a file")?;
            let text = std::fs::read_to_string(&list).map_err(|e| format!("{list}: {e}"))?;
            paths.extend(
                text.lines()
                    .filter(|l| !l.trim().is_empty())
                    .map(PathBuf::from),
            );
        } else {
            paths.push(PathBuf::from(a));
        }
    }
    if paths.is_empty() {
        return Err("usage: compiler_census <doc.esm …> | --paths-from <list.txt>".into());
    }

    let sink: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    {
        let sink = Arc::clone(&sink);
        std::panic::set_hook(Box::new(move |info| {
            *sink.lock().expect("panic sink") = Some(format!("{info}"));
        }));
    }

    for path in &paths {
        let line = census_one(path, &sink);
        println!("{line}");
        use std::io::Write;
        let _ = std::io::stdout().flush();
    }
    Ok(())
}
