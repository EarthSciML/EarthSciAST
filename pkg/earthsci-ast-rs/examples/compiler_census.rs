//! Compiler census: build every document under `Compiler::Native` and under
//! `Compiler::Interpreter`, through the public `esm_problem` entry, and record
//! what each one answered.
//!
//! The numbers below are what a caller gets, not what a reconstruction of the
//! build path predicts.
//!
//! Per document:
//!
//!   * **native** — `esm_problem(…, compiler: Some(Native))`. Either a Problem,
//!     whose `compiler_report()` says where every rule landed and at which
//!     cadence, or a refusal (`compiler_refused_rule`, with the rule and the
//!     deepest decline reason) or an ordinary build error.
//!   * **interpreter** — the same document under the reference compiler, which
//!     refuses nothing it can evaluate, so a document that builds under one and
//!     not the other separates "the tape cannot lower this" from "nothing can".
//!
//! One JSON object per document on stdout (JSON Lines); progress and panics on
//! stderr. Nothing here evaluates a trajectory: both halves build and discard.
//!
//! Usage:
//!     cargo run --example compiler_census -- <doc.esm> [more.esm …]
//!     cargo run --example compiler_census -- --paths-from <list.txt>
//!
//! A document that panics is reported with its message rather than taking the
//! process down; a document that hangs or is killed emits no line at all, and
//! the driver that invoked this example is what notices the missing one.

use earthsci_ast::{
    CompileError, Compiler, EsmProblem, ProblemOptions, Rhs, SimulateError, esm_problem,
};
use serde_json::{Map, Value, json};
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

/// `Rhs::Auto` unless `--rhs always` was passed.
///
/// `Auto` is the default and is what decides `Backend::Static`: a document
/// with no differential equations has no right-hand side, so no compiler is
/// chosen for it and it can refuse nothing. `--rhs always` is for the
/// pre-discretization fixtures whose `D` operators only become an integrable
/// system once a harness has applied their discretization: under `Auto` they
/// are static and the census learns nothing about them.
fn rhs_mode() -> Rhs {
    static MODE: std::sync::OnceLock<Rhs> = std::sync::OnceLock::new();
    *MODE.get_or_init(|| {
        if std::env::args().any(|a| a == "--rhs-always") {
            Rhs::Always
        } else {
            Rhs::Auto
        }
    })
}

fn build(path: &Path, compiler: Compiler) -> Result<EsmProblem, SimulateError> {
    esm_problem(
        path,
        (0.0, 1.0),
        ProblemOptions {
            rhs: rhs_mode(),
            compiler: Some(compiler),
            ..Default::default()
        },
    )
}

/// Record one compiler's answer for one document under the key prefix `tag`.
fn record(out: &mut Map<String, Value>, tag: &str, path: &Path, compiler: Compiler) {
    let t = Instant::now();
    let built = build(path, compiler);
    out.insert(format!("{tag}_ms"), json!(ms(t)));
    match built {
        Ok(prob) => {
            let report = prob.compiler_report();
            out.insert(format!("{tag}_ok"), json!(true));
            out.insert(format!("{tag}_backend"), json!(prob.backend_kind()));
            out.insert(format!("{tag}_n_rules"), json!(report.rules().len()));
            out.insert(format!("{tag}_n_taped"), json!(report.n_taped()));
            out.insert(format!("{tag}_n_oracle"), json!(report.n_oracle()));
            let mut by_tier: Map<String, Value> = Map::new();
            for r in report.rules() {
                let n = by_tier.get(r.cadence).and_then(Value::as_u64).unwrap_or(0);
                by_tier.insert(r.cadence.to_string(), json!(n + 1));
            }
            out.insert(format!("{tag}_cadence"), Value::Object(by_tier));
        }
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule {
            kind,
            rule,
            tier,
            reason,
            ..
        })) => {
            out.insert(format!("{tag}_ok"), json!(false));
            out.insert(format!("{tag}_err_variant"), json!("CompilerRefusedRule"));
            out.insert(format!("{tag}_refused_kind"), json!(kind));
            out.insert(format!("{tag}_refused_rule"), json!(rule));
            out.insert(format!("{tag}_refused_tier"), json!(tier));
            out.insert(format!("{tag}_refused_reason"), json!(reason));
        }
        Err(e) => {
            out.insert(format!("{tag}_ok"), json!(false));
            out.insert(format!("{tag}_err_variant"), json!(variant_of(&e)));
            out.insert(format!("{tag}_err"), json!(e.to_string()));
        }
    }
}

fn census_one(path: &Path, sink: &Arc<Mutex<Option<String>>>) -> Value {
    let mut out = Map::new();
    out.insert("path".into(), json!(path.display().to_string()));
    for (tag, compiler) in [
        ("native", Compiler::Native),
        ("interpreter", Compiler::Interpreter),
    ] {
        match guarded(sink, || {
            let mut sub = Map::new();
            record(&mut sub, tag, path, compiler);
            sub
        }) {
            Ok(sub) => out.extend(sub),
            Err(p) => {
                out.insert(format!("{tag}_ok"), json!(false));
                out.insert(format!("{tag}_err_variant"), json!("PANIC"));
                out.insert(format!("{tag}_err"), json!(p));
            }
        }
    }
    Value::Object(out)
}

fn main() -> Result<(), String> {
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--rhs-always" {
            continue;
        }
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
