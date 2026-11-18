//! Shared plumbing for the conformance adapter binaries
//! (`earthsci-*-adapter-rust` under `src/bin/`).
//!
//! Two layers:
//!
//! * the `--manifest <m.json> --output <r.json>` argument protocol and the
//!   report writer, which every manifest-driven adapter uses;
//! * the per-fixture harness ([`Tier`], [`run_manifest`], [`adapter_main`]) for
//!   the tiers whose report is `{"binding": "rust", …, "fixtures": {<id>: …}}`
//!   with one answer per fixture. A tier supplies only its per-fixture
//!   function; reading the manifest, resolving fixture paths, recording a
//!   failed fixture as its own `error` entry, the whole-output `unavailable`
//!   form, the report and the exit code are decided here, once.
//!
//! The conventions this pins for every adapter: unknown arguments are
//! rejected; messages are prefixed with the binary's name; the output
//! directory is created on demand; a report ends with a trailing newline; the
//! report is written before the process fails, so the runner still reads the
//! fixtures that did answer; and a run in which any fixture errored exits
//! non-zero.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde_json::{Map, Value, json};

use crate::problem::Compiler;
use crate::simulate::Alg;
use crate::types::EsmFile;

/// The parsed `--manifest` / `--output` pair, plus the one tier-specific flag
/// a tier may take (`config`).
pub struct Args<C> {
    /// Path to the tier's manifest JSON.
    pub manifest: PathBuf,
    /// Path the adapter writes its report to.
    pub output: PathBuf,
    /// What the tier made of its own flag (`--engine`, `--compiler`).
    pub config: C,
}

/// The arguments of an adapter that takes no flag of its own.
pub type AdapterArgs = Args<()>;

/// Parse `--manifest <path> --output <path>`, plus `flag <value>` when the
/// tier names one, rejecting anything else. Both paths are required.
/// `configure` turns the flag's value (`None` when it was not given) into the
/// tier's configuration; a tier whose flag is required refuses `None` there.
pub fn parse_args<C, I: IntoIterator<Item = String>>(
    args: I,
    flag: Option<&str>,
    configure: impl FnOnce(Option<&str>) -> Result<C, String>,
) -> Result<Args<C>, String> {
    let mut manifest: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut value: Option<String> = None;
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--manifest" => manifest = it.next().map(PathBuf::from),
            "--output" => output = it.next().map(PathBuf::from),
            a if Some(a) == flag => {
                value = Some(it.next().ok_or_else(|| format!("{a} needs a value"))?);
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    let (Some(manifest), Some(output)) = (manifest, output) else {
        return Err("--manifest and --output are required".to_string());
    };
    Ok(Args {
        manifest,
        output,
        config: configure(value.as_deref())?,
    })
}

/// Parse `--manifest <path> --output <path>` from `std::env::args`, rejecting
/// anything else. Both flags are required.
pub fn parse_manifest_output_args() -> Result<AdapterArgs, String> {
    parse_args(std::env::args().skip(1), None, |_| Ok(()))
}

/// The value of a REQUIRED `--compiler` flag. One adapter binary serves every
/// compiler its binding offers, and a default would make the report's
/// `compiler` field a guess. A value outside API_SPEC §5.8's closed
/// vocabulary is `compiler_unknown` and fails the invocation: it is a typo,
/// not a missing runtime, and the two must not read alike
/// ([`Compiler::parse_named`]).
pub fn required_compiler(value: Option<&str>) -> Result<Compiler, String> {
    Compiler::parse_named(value.ok_or("--manifest, --output and --compiler are required")?)
}

/// Write an adapter report as pretty-printed JSON with a trailing newline,
/// creating the output's parent directory if needed.
pub fn write_report(
    output_path: &Path,
    report: &serde_json::Value,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = output_path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        output_path,
        format!("{}\n", serde_json::to_string_pretty(report)?),
    )?;
    Ok(())
}

/// The determinism conformance adapter's body (`earthsci-determinism-adapter-rust`).
#[cfg(not(target_arch = "wasm32"))]
pub use crate::determinism_adapter::run as run_determinism_adapter;

// === The per-fixture harness ================================================

/// A tier's manifest, read once, with the directory its fixture paths are
/// resolved against.
pub struct Manifest {
    /// The parsed manifest.
    pub doc: Value,
    /// The manifest's own directory, absolute.
    pub dir: PathBuf,
}

impl Manifest {
    /// Read and parse the manifest at `path`.
    pub fn read(path: &Path) -> Result<Manifest, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("failed to read manifest {}: {e}", path.display()))?;
        let doc: Value =
            serde_json::from_str(&text).map_err(|e| format!("failed to parse manifest: {e}"))?;
        // Absolutize BEFORE taking the parent: `resolve_fixture_path` finds the
        // repository's `tests/` by walking ancestors, and a relative
        // `--manifest` (exactly what a runner invoking `cargo run` from the
        // crate directory passes) has no ancestors above its own first segment.
        let abs = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
        let dir = abs.parent().unwrap_or(Path::new(".")).to_path_buf();
        Ok(Manifest { doc, dir })
    }

    /// The file a fixture entry's `path` names ([`resolve_fixture_path`]).
    pub fn fixture_path(&self, fx: &Value) -> Result<PathBuf, String> {
        let rel = fx["path"].as_str().ok_or("fixture.path missing")?;
        resolve_fixture_path(&self.dir, rel)
    }

    /// The manifest's integrator settings for this binding
    /// (`integrators.rust`), `Null` when it declares none.
    pub fn integrator(&self) -> &Value {
        &self.doc["integrators"]["rust"]
    }
}

/// Resolve a manifest `fixtures[].path` to a file on disk.
///
/// Tiers spell fixture paths either relative to the manifest's own directory
/// (a document the tier authored) or relative to the repository's `tests/`
/// directory (a document another tier already owns). Both are accepted:
/// candidates are tried in a fixed order and the first that exists wins, so the
/// same adapter drives a shipped manifest and a crate-local test manifest that
/// sits elsewhere.
///
/// `manifest_dir` MUST be absolute ([`Manifest::read`] makes it so). The
/// ancestor walk below is what finds the repository's `tests/`, and a relative
/// directory runs out of ancestors long before reaching it.
pub fn resolve_fixture_path(manifest_dir: &Path, rel: &str) -> Result<PathBuf, String> {
    let mut tried: Vec<PathBuf> = Vec::new();
    // 1. Relative to the manifest itself.
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

/// What one fixture answered.
pub enum Answer {
    /// The fixture's entry in the report.
    Entry(Value),
    /// This configuration cannot run here at all. A fact about the binding and
    /// this build, not about the document, so it replaces the WHOLE output
    /// with `{"status": "unavailable", "reason": …}` and ends the run:
    /// reporting it per fixture would make a missing runtime look like a
    /// coverage gap.
    Unavailable(String),
}

/// One conformance tier: its configuration, and how it answers one fixture.
pub trait Tier {
    /// The report field naming the configuration the run used, as
    /// `(key, value)` (`("compiler", "native")`), or `None` when the tier's
    /// report carries none.
    fn header(&self) -> Option<(&'static str, &'static str)>;

    /// Why this configuration cannot run here at all, decided before any
    /// fixture is loaded; `None` when it can.
    fn unavailable(&self) -> Option<String> {
        None
    }

    /// Answer one fixture. An `Err` is that fixture's `error` entry, and fails
    /// the run's exit code.
    fn run_fixture(&self, fx: &Value, manifest: &Manifest) -> Result<Answer, String>;

    /// The entry an error is reported as instead of `error`, when the error is
    /// not a failure of this fixture (a coded refusal, for a tier that reads
    /// one out of the message). `None`, the default, keeps it an `error`.
    fn excuse(&self, _error: &str) -> Option<Value> {
        None
    }
}

/// What a manifest run produced: the report payload to write, plus the ids of
/// the fixtures that answered with an `error`.
///
/// The two are separate because they go to different places: `payload` is the
/// adapter's JSON output and carries each failure as that fixture's `error`
/// entry, so the runner can name it; `failed` decides the process exit code. A
/// non-zero exit WITH a parsable report is legal and is how a run that broke on
/// one fixture still hands the runner the rest.
pub struct Report {
    /// The `{"binding": "rust", …}` document written to `--output`.
    pub payload: Value,
    /// Ids of fixtures whose entry is an `error`.
    pub failed: Vec<String>,
}

/// The longest error text a fixture's `error` entry carries; the whole message
/// still goes to stderr.
const ERROR_ENTRY_CHARS: usize = 800;

/// `s` cut to at most `n` characters.
pub fn truncate(s: &str, n: usize) -> String {
    let end = s.char_indices().nth(n).map(|(i, _)| i).unwrap_or(s.len());
    s[..end].to_string()
}

fn report_header<T: Tier>(tier: &T) -> Map<String, Value> {
    let mut head = Map::new();
    head.insert("binding".to_string(), json!("rust"));
    if let Some((key, value)) = tier.header() {
        head.insert(key.to_string(), json!(value));
    }
    head
}

/// Run a whole manifest through `tier` and build the report.
///
/// Every fixture is attempted; one that fails becomes its own `error` entry
/// and the run continues, so a single broken fixture cannot hide the rest.
/// [`Answer::Unavailable`], from [`Tier::unavailable`] or from any fixture,
/// replaces the whole payload. Unknown manifest fields are ignored.
pub fn run_manifest<T: Tier>(tier: &T, manifest_path: &Path) -> Result<Report, String> {
    let unavailable = |reason: String| {
        let mut payload = report_header(tier);
        payload.insert("status".to_string(), json!("unavailable"));
        payload.insert("reason".to_string(), json!(reason));
        Report {
            payload: Value::Object(payload),
            failed: Vec::new(),
        }
    };
    if let Some(reason) = tier.unavailable() {
        return Ok(unavailable(reason));
    }
    let manifest = Manifest::read(manifest_path)?;
    let empty: Vec<Value> = Vec::new();
    let mut fixtures = Map::new();
    let mut failed = Vec::new();
    for fx in manifest.doc["fixtures"].as_array().unwrap_or(&empty) {
        let id = fx["id"].as_str().unwrap_or("<unknown>").to_string();
        let entry = match tier.run_fixture(fx, &manifest) {
            Ok(Answer::Entry(v)) => v,
            Ok(Answer::Unavailable(reason)) => return Ok(unavailable(reason)),
            Err(e) => match tier.excuse(&e) {
                Some(v) => v,
                None => {
                    eprintln!("fixture {id}: {e}");
                    failed.push(id.clone());
                    json!({ "error": truncate(&e, ERROR_ENTRY_CHARS) })
                }
            },
        };
        fixtures.insert(id, entry);
    }
    let mut payload = report_header(tier);
    payload.insert("fixtures".to_string(), Value::Object(fixtures));
    Ok(Report {
        payload: Value::Object(payload),
        failed,
    })
}

/// The whole `main` of a per-fixture adapter binary: parse the command line
/// (`flag` is the tier's own flag, handed to `configure`), run the manifest,
/// write the report, and exit non-zero when anything failed. `name` prefixes
/// every message.
pub fn adapter_main<T: Tier>(
    name: &str,
    flag: Option<&str>,
    configure: impl FnOnce(Option<&str>) -> Result<T, String>,
) -> ExitCode {
    let args = match parse_args(std::env::args().skip(1), flag, configure) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{name}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let report = match run_manifest(&args.config, &args.manifest) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{name}: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(e) = write_report(&args.output, &report.payload) {
        eprintln!("{name}: failed to write output: {e}");
        return ExitCode::FAILURE;
    }
    if !report.failed.is_empty() {
        eprintln!(
            "{name}: {} fixture(s) errored: {}",
            report.failed.len(),
            report.failed.join(", ")
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

// === Shared spellings =======================================================

/// Strip a leading `Model.` namespace: the tiers' keys are bare column-major
/// element names (`u[1]`, `u[i,j]`, scalar `s`), the same in every binding.
pub fn bare(name: &str) -> &str {
    name.split_once('.').map(|x| x.1).unwrap_or(name)
}

/// One reported value as JSON. `json!(f64)` writes NaN and ±inf as `null`,
/// which the runners cannot turn back into a number, so a non-finite value
/// goes out as the string Python's `float()` parses (`"NaN"`, `"Infinity"`,
/// `"-Infinity"`), and a regression that produces one fails its own element's
/// comparison by name instead of arriving as a silent NaN or aborting the run.
pub fn number(v: f64) -> Value {
    if v.is_finite() {
        json!(v)
    } else if v.is_nan() {
        json!("NaN")
    } else if v > 0.0 {
        json!("Infinity")
    } else {
        json!("-Infinity")
    }
}

/// A save-time key, the adapter's own float repr. The runners canonicalize
/// both sides and match by numeric value, so only the round trip matters.
pub fn time_key(t: f64) -> String {
    format!("{t}")
}

/// Index of the solution sample closest to `t` (`total_cmp`, so a NaN sample
/// cannot panic the comparison). `saveat` pins the grid; this matches
/// defensively.
pub fn nearest_index(times: &[f64], t: f64) -> Option<usize> {
    (0..times.len()).min_by(|&a, &b| (times[a] - t).abs().total_cmp(&(times[b] - t).abs()))
}

/// The algorithm a trajectory tier integrates a document with.
///
/// esm-spec §2.2's `solver` block is the document's declaration about ITSELF,
/// and `stiffness: "high"` selects the stiff family, the rule the reference
/// adapter applies too. Everything else takes the explicit Runge-Kutta arm
/// rather than this binding's stiff default: the tiers compare trajectories
/// numerically against a reference produced by the Tsitouras 5(4) tableau
/// this arm implements, and two different integrators at the same tolerance
/// disagree by more than a fixture's band for reasons that have nothing to do
/// with what the tier tests. The tolerances are the manifest's.
pub fn solver_alg(file: &EsmFile) -> Alg {
    match file.solver.as_ref().and_then(|s| s.stiffness.as_deref()) {
        Some("high") => Alg::Bdf,
        _ => Alg::Erk,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn parse_args_rejects_a_flag_the_tier_does_not_take() {
        let none = |_: Option<&str>| Ok(());
        assert!(parse_args(argv("--manifest m --output o"), None, none).is_ok());
        assert!(parse_args(argv("--manifest m --output o --compiler x"), None, none).is_err());
        assert!(parse_args(argv("--manifest m"), None, none).is_err());
        let a = parse_args(
            argv("--manifest m --output o --compiler x"),
            Some("--compiler"),
            |v| Ok(v.map(str::to_string)),
        )
        .expect("parses");
        assert_eq!(a.config.as_deref(), Some("x"));
        let needs_value = parse_args(
            argv("--manifest m --output o --compiler"),
            Some("--compiler"),
            none,
        );
        assert!(needs_value.is_err());
    }

    #[test]
    fn non_finite_numbers_are_strings() {
        assert_eq!(number(1.5), json!(1.5));
        assert_eq!(number(f64::NAN), json!("NaN"));
        assert_eq!(number(f64::INFINITY), json!("Infinity"));
        assert_eq!(number(f64::NEG_INFINITY), json!("-Infinity"));
    }
}
