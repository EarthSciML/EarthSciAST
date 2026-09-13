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
//! `earthsci-compiled-rhs-adapter-rust` is a thin `main` over [`parse_args`]
//! and [`run_manifest`].
//!
//! Engines:
//!   * `interpreter` — [`ArrayCompiled::debug_eval_rhs`] on the vectorized
//!     evaluator, the same no-scalarization kernel the simulator uses. This is
//!     the engine that runs today.
//!   * `compiled` — the XlaBuilder emitter over the tape, which lands in phase
//!     2. Until then the whole output is the contract's `unavailable` form.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::load_string;
use crate::simulate_array::ArrayCompiled;

/// The reason string the `compiled` engine reports until phase 2 lands.
pub const COMPILED_UNAVAILABLE_REASON: &str =
    "Rust compiled engine (XlaBuilder emitter over the tape) lands in phase 2";

/// Which right-hand-side engine the adapter was asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    /// The vectorized interpreter (`ArrayCompiled::debug_eval_rhs`).
    Interpreter,
    /// The compiled backend; unavailable in phase 1.
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

    fn parse(s: &str) -> Result<Self, String> {
        match s {
            "interpreter" => Ok(Engine::Interpreter),
            "compiled" => Ok(Engine::Compiled),
            other => Err(format!(
                "unknown --engine {other:?} (want interpreter|compiled)"
            )),
        }
    }
}

/// The adapter's parsed command line: `--manifest <m> --output <o>
/// [--engine interpreter|compiled]`.
pub struct Args {
    /// Path to the tier manifest.
    pub manifest: PathBuf,
    /// Path the report is written to.
    pub output: PathBuf,
    /// Requested engine; `interpreter` when `--engine` is omitted.
    pub engine: Engine,
}

/// Parse the adapter contract's argument list, rejecting anything else.
///
/// Separate from [`crate::adapter_support::parse_manifest_output_args`]
/// because this tier adds `--engine`; the other adapters take no such flag and
/// must keep rejecting it.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    let mut manifest: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut engine = Engine::Interpreter;
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--manifest" => manifest = it.next().map(PathBuf::from),
            "--output" => output = it.next().map(PathBuf::from),
            "--engine" => {
                let v = it.next().ok_or("--engine needs a value")?;
                engine = Engine::parse(&v)?;
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    match (manifest, output) {
        (Some(manifest), Some(output)) => Ok(Args {
            manifest,
            output,
            engine,
        }),
        _ => Err("--manifest and --output are required".to_string()),
    }
}

/// What a manifest run produced: the report payload to write, plus the ids of
/// any fixtures that could not be evaluated.
///
/// The two are separate because they go to different places. `payload` is the
/// adapter's JSON output and carries each failure as that fixture's `error`
/// entry, so the runner can name it. `failed` is what decides the process exit
/// code: a run in which no fixture produced numbers must not exit 0, or a
/// broken adapter reads as a clean pass upstream.
pub struct Report {
    /// The `{"binding": …, "engine": …, …}` document to write to `--output`.
    pub payload: Value,
    /// Ids of fixtures whose entry is an `error` rather than an `rhs` map.
    pub failed: Vec<String>,
}

/// Strip a leading `Model.` namespace so element names match across bindings.
/// The same spelling the PDE-simulation adapter emits: bare column-major
/// element names (`u[1]`, `u[i,j]`, scalar `s`).
fn bare(name: &str) -> &str {
    name.split_once('.').map(|x| x.1).unwrap_or(name)
}

/// Resolve a manifest `fixtures[].path` to a file on disk.
///
/// The contract spells the path relative to the repository's `tests/`
/// directory, while the sibling PDE tier spells its own fixture paths relative
/// to the manifest's directory. Both are accepted: candidates are tried in a
/// fixed order and the first that exists wins, so the same adapter drives the
/// shipped manifest and a crate-local test manifest that sits elsewhere.
///
/// `manifest_dir` MUST be absolute — [`run_manifest`] absolutizes it first.
/// The ancestor walk below is what finds the repository's `tests/`, and a
/// relative directory runs out of ancestors long before reaching it, which
/// turns every fixture into a not-found error.
pub fn resolve_fixture_path(manifest_dir: &Path, rel: &str) -> Result<PathBuf, String> {
    let mut tried: Vec<PathBuf> = Vec::new();
    // 1. Relative to the manifest itself (the PDE tier's spelling).
    tried.push(manifest_dir.join(rel));
    // 2/3. Relative to a `tests/` directory at or above the manifest, innermost
    //      first. This resolves `conformance/<tier>/fixtures/x.esm` against the
    //      repository's own `tests/` however deep the manifest is nested.
    for ancestor in manifest_dir.ancestors() {
        if ancestor.file_name().map(|n| n == "tests").unwrap_or(false) {
            tried.push(ancestor.join(rel));
        }
        tried.push(ancestor.join("tests").join(rel));
    }
    tried.iter().find(|p| p.is_file()).cloned().ok_or_else(|| {
        format!(
            "fixture path {rel:?} not found; tried {}",
            tried
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        )
    })
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

/// Evaluate one fixture's probes with the interpreter engine.
fn run_fixture(fx: &Value, manifest_dir: &Path) -> Result<Value, String> {
    let rel = fx["path"].as_str().ok_or("fixture.path missing")?;
    let path = resolve_fixture_path(manifest_dir, rel)?;
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
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(&names, state_obj).map_err(|e| format!("probe {pid}: {e}"))?;
        let (dy, _stats) = compiled.debug_eval_rhs(&sv, t, &params, false);
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(dy[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }
    Ok(json!({ "rhs": Value::Object(rhs) }))
}

/// Run a whole manifest and build the report payload.
///
/// For `Engine::Compiled` this is the contract's whole-output `unavailable`
/// form — no fixture is loaded and nothing is evaluated. For
/// `Engine::Interpreter` every fixture is evaluated; a fixture that fails is
/// reported as `{"error": "<text>"}` in its own entry and the run continues,
/// so one bad fixture cannot hide the rest. The caller learns that a failure
/// happened from [`Report::failed`], which the binary turns into a non-zero
/// exit: the tier's ruling is that nothing may be a silent skip, and a run
/// where every fixture errored must not look like a clean run.
///
/// Unknown manifest fields are ignored throughout.
pub fn run_manifest(manifest_path: &Path, engine: Engine) -> Result<Report, String> {
    if engine == Engine::Compiled {
        return Ok(Report {
            payload: json!({
                "binding": "rust",
                "engine": engine.as_str(),
                "status": "unavailable",
                "reason": COMPILED_UNAVAILABLE_REASON,
            }),
            failed: Vec::new(),
        });
    }
    let text = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest {}: {e}", manifest_path.display()))?;
    let manifest: Value =
        serde_json::from_str(&text).map_err(|e| format!("failed to parse manifest: {e}"))?;
    // Absolutize BEFORE taking the parent: `resolve_fixture_path` finds the
    // repository's `tests/` by walking ancestors, and a relative `--manifest`
    // (exactly what a runner invoking `cargo run` from the crate directory
    // passes) has no ancestors above its own first segment.
    let abs = std::path::absolute(manifest_path).unwrap_or_else(|_| manifest_path.to_path_buf());
    let manifest_dir = abs.parent().unwrap_or(Path::new(".")).to_path_buf();

    let empty: Vec<Value> = Vec::new();
    let mut fixtures = Map::new();
    let mut failed = Vec::new();
    for fx in manifest["fixtures"].as_array().unwrap_or(&empty) {
        let id = fx["id"].as_str().unwrap_or("<unknown>").to_string();
        let entry = match run_fixture(fx, &manifest_dir) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("fixture {id}: {e}");
                failed.push(id.clone());
                json!({ "error": e })
            }
        };
        fixtures.insert(id, entry);
    }
    Ok(Report {
        payload: json!({
            "binding": "rust",
            "engine": engine.as_str(),
            "fixtures": Value::Object(fixtures),
        }),
        failed,
    })
}
