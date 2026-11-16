//! Core of the Rust adapter for the `compiled_rhs` conformance tier
//! (`tests/conformance/compiled_rhs/README.md`).
//!
//! The tier asks each binding to evaluate the right-hand side `f(u, p, t)` at a
//! set of literal probe states and report the numbers; agreement is checked
//! numerically by the runner, never by inspecting emitted programs.
//!
//! The logic lives in the LIBRARY rather than in `src/bin/` so that the
//! integration test (`tests/compiled_rhs_adapter.rs`) can drive exactly the
//! code path the binary runs, without spawning a process. The binary
//! `earthsci-compiled-rhs-adapter-rust` is
//! [`crate::adapter_support::adapter_main`] over this tier.
//!
//! Engines:
//!   * `interpreter` — [`ArrayCompiled::debug_eval_rhs`] on the vectorized
//!     evaluator, the same no-scalarization kernel the simulator uses. This is
//!     the engine that runs today.
//!   * `compiled` — the XlaBuilder emitter over the tape
//!     (`simulate_array::tape::xla_emit`) run through PJRT
//!     (`xla_runtime`). Behind the non-default `xla` feature: a
//!     binary built without it answers `--engine compiled` with the
//!     contract's whole-output `unavailable` form, and so does one built with
//!     it on a machine where the PJRT client will not start. A model the
//!     emitter cannot lower completely becomes that fixture's `refused`
//!     entry, carrying the rule and the reason — never a fallback to the
//!     interpreter, never a silent skip.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::{Map, Value, json};

pub use crate::adapter_support::Report;
use crate::adapter_support::{self, Answer, Manifest, Tier, bare, number};
use crate::load_string;
use crate::simulate_array::ArrayCompiled;

/// The reason string the `compiled` engine reports when this binary was built
/// WITHOUT the `xla` feature.
///
/// The feature is off by default (it links a separately-fetched 144 MB
/// `xla_extension` release), so this is the answer an ordinary
/// `cargo build --features conformance-adapters` gives, and it has to say how
/// to get the other one.
pub const COMPILED_UNAVAILABLE_REASON: &str = concat!(
    "built without the `xla` feature: rebuild with ",
    "--features conformance-adapters,xla and XLA_EXTENSION_DIR pointing at an ",
    "unpacked xla_extension release (scripts/fetch-xla-extension.sh)"
);

/// Which right-hand-side engine the adapter was asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    /// The vectorized interpreter (`ArrayCompiled::debug_eval_rhs`).
    Interpreter,
    /// The compiled backend: the XLA emitter over the tape, feature `xla`.
    Compiled,
}

impl Engine {
    /// The wire spelling written into the report's `engine` field.
    pub fn as_str(self) -> &'static str {
        match self {
            Engine::Interpreter => "interpreter",
            Engine::Compiled => "compiled",
        }
    }

    /// The engine `--engine` names; `interpreter` when the flag is omitted.
    pub fn configure(value: Option<&str>) -> Result<Self, String> {
        match value {
            None | Some("interpreter") => Ok(Engine::Interpreter),
            Some("compiled") => Ok(Engine::Compiled),
            Some(other) => Err(format!(
                "unknown --engine {other:?} (want interpreter|compiled)"
            )),
        }
    }
}

/// The adapter's parsed command line: `--manifest <m> --output <o>
/// [--engine interpreter|compiled]`.
pub type Args = adapter_support::Args<Engine>;

/// Parse the adapter contract's argument list, rejecting anything else.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    adapter_support::parse_args(args, Some("--engine"), Engine::configure)
}

/// Canonicalize the manifest's `parameters` override keys onto the compiled
/// model's own parameter names.
///
/// `ArrayCompiled::debug_eval_rhs` matches override keys EXACTLY against
/// `parameter_names()` and silently ignores the rest, so an override the
/// evaluator does not recognize would otherwise pass as a fixture evaluated
/// with default parameters. Accept the bare name and the `<Model>.`-qualified
/// spelling, and make anything else a hard error for that fixture.
fn canonical_parameters(
    compiled: &ArrayCompiled,
    model: &str,
    parameters: &Map<String, Value>,
) -> Result<HashMap<String, f64>, String> {
    let known: Vec<&str> = compiled
        .parameter_names()
        .iter()
        .map(String::as_str)
        .collect();
    let mut out = HashMap::new();
    for (key, value) in parameters {
        let v = value
            .as_f64()
            .ok_or_else(|| format!("parameter override {key:?} is not a number"))?;
        let stripped = key.strip_prefix(&format!("{model}.")).unwrap_or(key);
        let resolved = if known.contains(&key.as_str()) {
            key.as_str()
        } else if known.contains(&stripped) {
            stripped
        } else {
            return Err(format!(
                "parameter override {key:?} does not name a parameter of model {model:?} \
                 (known: {})",
                known.join(", ")
            ));
        };
        out.insert(resolved.to_string(), v);
    }
    Ok(out)
}

/// Look up a probe state value by the evaluator's own slot name, falling back
/// to the bare name. Probe states in the manifest are keyed by bare element
/// names; the evaluator's slot names may carry a namespace.
fn state_vec(names: &[String], state: &Map<String, Value>) -> Result<Vec<f64>, String> {
    names
        .iter()
        .map(|n| {
            state
                .get(n)
                .or_else(|| state.get(bare(n)))
                .and_then(Value::as_f64)
                .ok_or_else(|| format!("probe state is missing element {:?}", bare(n)))
        })
        .collect()
}

/// Why the `compiled` engine cannot run here at all, or `None` when it can.
///
/// Two different causes, one answer: the binary was built without the `xla`
/// feature, or it has the feature but the PJRT client will not start (no
/// usable `xla_extension`, no device for the requested platform). Both are the
/// contract's whole-output `unavailable`, because neither says anything about
/// what the emitter can or cannot lower.
#[cfg(feature = "xla")]
fn compiled_unavailable_reason() -> Option<String> {
    crate::xla_runtime::client()
        .err()
        .map(|e| format!("XLA runtime is not usable on this machine: {e}"))
}

#[cfg(not(feature = "xla"))]
fn compiled_unavailable_reason() -> Option<String> {
    Some(COMPILED_UNAVAILABLE_REASON.to_string())
}

/// Evaluate one fixture's probes with the compiled engine.
///
/// Returns the fixture entry: an `rhs` map, or the contract's `refused` entry
/// when the emitter will not lower the model. An `Err` here is the contract's
/// `error` (the load or the build threw), which `compiled_required` does not
/// excuse.
#[cfg(feature = "xla")]
fn eval_compiled(
    compiled: &ArrayCompiled,
    fx: &Value,
    names: &[String],
    params: &HashMap<String, f64>,
) -> Result<Value, String> {
    use crate::xla_runtime::{CompileRhsError, CompiledRhs};

    // ONE compile per fixture, reused across every probe — see the
    // `xla_runtime` module docs on what is cached.
    let program = match CompiledRhs::compile(compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => {
            return Ok(json!({
                "status": "refused",
                "rule": e.rule,
                "reason": e.reason,
            }));
        }
        Err(CompileRhsError::Runtime(m)) => return Err(format!("xla: {m}")),
    };
    let param_vec = compiled.debug_resolve_params(params);
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(names, state_obj).map_err(|e| format!("probe {pid}: {e}"))?;
        let du = program
            .eval(&sv, &param_vec, t)
            .map_err(|e| format!("probe {pid}: {e}"))?;
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(du[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }
    Ok(json!({ "rhs": Value::Object(rhs) }))
}

#[cfg(not(feature = "xla"))]
fn eval_compiled(
    _compiled: &ArrayCompiled,
    _fx: &Value,
    _names: &[String],
    _params: &HashMap<String, f64>,
) -> Result<Value, String> {
    // Unreachable: `run_manifest` answers `unavailable` for the whole output
    // before any fixture is loaded when the feature is off.
    Err(COMPILED_UNAVAILABLE_REASON.to_string())
}

/// Evaluate one fixture's probes with the requested engine.
fn run_fixture(fx: &Value, manifest: &Manifest, engine: Engine) -> Result<Value, String> {
    let path = manifest.fixture_path(fx)?;
    let json_str = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let file = load_string(&json_str).map_err(|e| format!("load: {e:?}"))?;

    // `ArrayCompiled::from_file` drives the single model in the document; the
    // manifest's `model` field must name it, or the numbers would silently be
    // some other model's.
    if let Some(models) = &file.models
        && let Some(want) = fx["model"].as_str()
        && !models.contains_key(want)
    {
        return Err(format!(
            "manifest model {want:?} is not in {}; document declares {}",
            path.display(),
            models.keys().cloned().collect::<Vec<_>>().join(", ")
        ));
    }
    let compiled = ArrayCompiled::from_file(&file).map_err(|e| format!("compile: {e:?}"))?;

    let params = match fx.get("parameters").and_then(Value::as_object) {
        Some(p) if !p.is_empty() => {
            canonical_parameters(&compiled, fx["model"].as_str().unwrap_or_default(), p)?
        }
        _ => HashMap::new(),
    };

    let names: Vec<String> = compiled.state_variable_names().to_vec();
    if engine == Engine::Compiled {
        return eval_compiled(&compiled, fx, &names, &params);
    }
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(&names, state_obj).map_err(|e| format!("probe {pid}: {e}"))?;
        let (dy, _stats) = compiled.debug_eval_rhs(&sv, t, &params, false);
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(dy[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }
    Ok(json!({ "rhs": Value::Object(rhs) }))
}

impl Tier for Engine {
    fn header(&self) -> Option<(&'static str, &'static str)> {
        Some(("engine", self.as_str()))
    }

    /// For `Engine::Compiled`, the whole output is the contract's
    /// `unavailable` form when the engine cannot run here at all (no `xla`
    /// feature, or no usable PJRT client): no fixture is loaded and nothing is
    /// evaluated.
    fn unavailable(&self) -> Option<String> {
        match self {
            Engine::Compiled => compiled_unavailable_reason(),
            Engine::Interpreter => None,
        }
    }

    fn run_fixture(&self, fx: &Value, manifest: &Manifest) -> Result<Answer, String> {
        run_fixture(fx, manifest, *self).map(Answer::Entry)
    }
}

/// Run a whole manifest under `engine` and build the report
/// ([`adapter_support::run_manifest`]). Nothing may be a silent skip: a
/// fixture that fails is its own `error` entry and is named in
/// [`Report::failed`], which the binary turns into a non-zero exit.
pub fn run_manifest(manifest_path: &Path, engine: Engine) -> Result<Report, String> {
    adapter_support::run_manifest(&engine, manifest_path)
}
