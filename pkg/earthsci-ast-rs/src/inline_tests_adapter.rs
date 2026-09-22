//! Core of the Rust adapter for the INLINE-TEST conformance tiers
//! (`CONFORMANCE_SPEC.md` §5.45, and each tier's own `README.md`).
//!
//! A tier of this family has fixtures that are DOCUMENTS carrying their own
//! esm-spec §6.6 `tests` blocks. Every binding runs the same documents through
//! its OWN §6.6 runner under a NAMED compiler and reports, per assertion,
//! whether its §6.6.3 predicate passed and what the ACTUAL reduction value was.
//! The runner gates both: `passed` against the document's authored
//! expectation, `actual` against the committed Julia-`interpreter` golden.
//!
//! `--compiler` is passed straight to [`crate::inline_tests::InlineTestOptions`]
//! and never interpreted here — an adapter that chose a build itself would be
//! reimplementing the thing under test.
//!
//! The three per-fixture outcomes, and the distinction that is load-bearing:
//!
//!   * **refused** — this compiler cannot evaluate this document. Two shapes
//!     reach it: a refusal thrown out of the build, and a run in which EVERY
//!     assertion failed carrying ONE coded diagnostic. An operator with no
//!     evaluation rule declines at EVALUATION rather than at build, and
//!     reporting that as "every number is wrong" would file a refusal in the
//!     same bucket as a numeric defect, which is the one conflation §5.45.3
//!     forbids.
//!   * **unavailable** — the whole output, when this build has no such
//!     compiler at all. A fact about the BINDING, never about a document.
//!   * **error** — anything else. It says nothing about what a compiler can
//!     run, so a fixture's `required` map does not excuse it.
//!
//! The logic lives in the library rather than in `src/bin/` so that a test can
//! drive exactly the path the binary runs — the same split
//! [`crate::compiler_agreement_adapter`] uses.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::inline_tests::{InlineTestOptions, run_inline_tests_with_options};
use crate::problem::Compiler;
use crate::simulate::{Alg, SolveOptions};
use crate::types::EsmFile;

/// The coded diagnostics a refusal can carry. A message naming one of these is
/// this binding declining to evaluate the document, which the tier records as a
/// NAMED EXCLUSION under the fixture's ledger — never as a wrong answer, and
/// never as a silent skip. Anything else is an ordinary assertion failure.
const REFUSAL_CODES: [&str; 5] = [
    "compiler_refused_rule",
    "compiler_unavailable",
    "unevaluable_operator",
    "unlowered_operator",
    "unsupported_construct",
];

/// The adapter's parsed command line.
pub struct Args {
    /// Path to the tier manifest.
    pub manifest: PathBuf,
    /// Path the report is written to.
    pub output: PathBuf,
    /// The compiler every fixture is built with. REQUIRED: one adapter binary
    /// serves every compiler this binding offers, and a default would make the
    /// report's `compiler` field a guess.
    pub compiler: Compiler,
}

/// Parse `--manifest <m> --output <o> --compiler <c>`, rejecting anything else.
///
/// A value outside API_SPEC §5.8's closed vocabulary is `compiler_unknown` and
/// fails the invocation: it is a typo, not a missing runtime.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    let mut manifest: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut compiler: Option<Compiler> = None;
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--manifest" => manifest = it.next().map(PathBuf::from),
            "--output" => output = it.next().map(PathBuf::from),
            "--compiler" => {
                let v = it.next().ok_or("--compiler needs a value")?;
                compiler = Some(Compiler::parse_named(&v)?);
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    match (manifest, output, compiler) {
        (Some(manifest), Some(output), Some(compiler)) => Ok(Args {
            manifest,
            output,
            compiler,
        }),
        _ => Err("--manifest, --output and --compiler are required".to_string()),
    }
}

/// What a manifest run produced: the report payload to write, plus the ids of
/// the fixtures that answered with an `error`. A non-zero exit WITH a parsable
/// report is legal, and is how a run that broke on one fixture still hands the
/// runner the rest.
pub struct Report {
    /// The document written to `--output`.
    pub payload: Value,
    /// Ids of fixtures whose entry is an `error`.
    pub failed: Vec<String>,
}

/// The repository `tests/` directory, found by walking UP from the manifest.
fn tests_root(manifest_path: &Path) -> PathBuf {
    let abs = std::path::absolute(manifest_path).unwrap_or_else(|_| manifest_path.to_path_buf());
    let mut cur = abs.as_path();
    while let Some(parent) = cur.parent() {
        if parent.file_name().is_some_and(|n| n == "tests") {
            return parent.to_path_buf();
        }
        cur = parent;
    }
    abs.parent().unwrap_or(Path::new(".")).to_path_buf()
}

/// Resolve a fixture's `.esm`: against the manifest's own directory first (a
/// document the tier authored), then against `tests/` (a document another tier
/// already owns). The two-step rule every binding's adapter applies, so a tier
/// is free to reference rather than copy.
fn fixture_path(manifest_dir: &Path, tests: &Path, rel: &str) -> PathBuf {
    let local = manifest_dir.join(rel);
    if local.is_file() {
        return local;
    }
    tests.join(rel)
}

/// The coded diagnostic a message names, or `None`. Matched against the closed
/// list plus the `E_TREEWALK_*` family, so an ordinary numeric failure — whose
/// message names no code — can never be mistaken for a refusal.
fn refusal_code(message: &str) -> Option<String> {
    for code in REFUSAL_CODES {
        if message.contains(code) {
            return Some(code.to_string());
        }
    }
    let bytes = message.as_bytes();
    let needle = b"E_TREEWALK_";
    let start = bytes
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|i| i)?;
    let end = message[start..]
        .find(|c: char| !(c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'))
        .map(|i| start + i)
        .unwrap_or(message.len());
    Some(message[start..end].to_string())
}

/// The algorithm this fixture integrates with. esm-spec §2.2's `solver` block
/// is the document's declaration about ITSELF, and `stiffness: "high"` selects
/// the stiff family; everything else takes the explicit Runge-Kutta arm rather
/// than this binding's stiff default, so two bindings integrate the same
/// document with the same family. The TOLERANCES are the manifest's.
fn solver_alg(file: &EsmFile) -> Alg {
    match file.solver.as_ref().and_then(|s| s.stiffness.as_deref()) {
        Some("high") => Alg::Bdf,
        _ => Alg::Erk,
    }
}

/// What one fixture answered: an entry for the report, or the whole-output
/// `unavailable` this compiler forces.
enum Answer {
    Entry(Value),
    Unavailable(String),
}

fn truncate(s: &str, n: usize) -> String {
    let end = s.char_indices().nth(n).map(|(i, _)| i).unwrap_or(s.len());
    s[..end].to_string()
}

fn run_fixture(
    fx: &Value,
    manifest: &Value,
    manifest_dir: &Path,
    tests: &Path,
    compiler: Compiler,
) -> Result<Answer, String> {
    let rel = fx["path"].as_str().ok_or("fixture.path missing")?;
    let path = fixture_path(manifest_dir, tests, rel);
    let text = fs::read_to_string(&path)
        .map_err(|e| format!("fixture document not found at {}: {e}", path.display()))?;
    let file = crate::load_string(&text).map_err(|e| format!("load: {e:?}"))?;
    let model = fx["model"].as_str().ok_or("fixture.model missing")?;

    let integ = &manifest["integrators"]["rust"];
    let opts = InlineTestOptions {
        model_name: Some(model.to_string()),
        solve: SolveOptions {
            alg: solver_alg(&file),
            reltol: integ["reltol"].as_f64(),
            abstol: integ["abstol"].as_f64(),
            maxiters: Some(1_000_000),
            ..Default::default()
        },
        base_dir: path.parent().map(Path::to_path_buf),
        compiler: Some(compiler),
        ..Default::default()
    };
    let results = run_inline_tests_with_options(&file, &opts, None);
    if results.is_empty() {
        return Err(format!(
            "the document declares no inline assertions for model {model:?}"
        ));
    }

    // A run in which EVERY assertion failed carrying ONE coded diagnostic is
    // this compiler declining the document, not this compiler getting every
    // number wrong.
    let codes: Vec<Option<String>> = results
        .iter()
        .filter(|r| !r.passed)
        .map(|r| refusal_code(&r.message))
        .collect();
    if codes.len() == results.len()
        && !codes.is_empty()
        && codes.iter().all(Option::is_some)
        && codes.windows(2).all(|w| w[0] == w[1])
    {
        let code = codes[0].clone().unwrap_or_default();
        let reason = truncate(&results[0].message, 400);
        if code == "compiler_unavailable" {
            return Ok(Answer::Unavailable(reason));
        }
        return Ok(Answer::Entry(json!({
            "status": "refused",
            "code": code,
            "reason": reason,
        })));
    }

    let entries: Vec<Value> = results
        .iter()
        .map(|r| {
            json!({
                "test_id": r.test_id,
                "assertion_idx": r.assertion_idx,
                "variable": r.variable,
                "passed": r.passed,
                "actual": r.actual,
                "message": r.message,
            })
        })
        .collect();
    Ok(Answer::Entry(json!({ "assertions": entries })))
}

/// Run a whole manifest under one compiler and build the report payload.
///
/// Every fixture is attempted; one that throws becomes its own `error` entry
/// and the run continues, so a single broken fixture cannot hide the rest. A
/// `compiler_unavailable` ends the run and replaces the whole payload:
/// availability is a property of the binding, and reporting it per fixture
/// would make a missing runtime look like a coverage gap.
pub fn run_manifest(manifest_path: &Path, compiler: Compiler) -> Result<Report, String> {
    let text = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest {}: {e}", manifest_path.display()))?;
    let manifest: Value =
        serde_json::from_str(&text).map_err(|e| format!("failed to parse manifest: {e}"))?;
    let abs = std::path::absolute(manifest_path).unwrap_or_else(|_| manifest_path.to_path_buf());
    let manifest_dir = abs.parent().unwrap_or(Path::new(".")).to_path_buf();
    let tests = tests_root(manifest_path);

    let empty: Vec<Value> = Vec::new();
    let mut fixtures = Map::new();
    let mut failed = Vec::new();
    for fx in manifest["fixtures"].as_array().unwrap_or(&empty) {
        let id = fx["id"].as_str().unwrap_or("<unknown>").to_string();
        let entry = match run_fixture(fx, &manifest, &manifest_dir, &tests, compiler) {
            Ok(Answer::Entry(v)) => v,
            Ok(Answer::Unavailable(reason)) => {
                return Ok(Report {
                    payload: json!({
                        "binding": "rust",
                        "compiler": compiler.as_str(),
                        "status": "unavailable",
                        "reason": reason,
                    }),
                    failed: Vec::new(),
                });
            }
            Err(e) => {
                if let Some(code) = refusal_code(&e) {
                    json!({ "status": "refused", "code": code, "reason": truncate(&e, 400) })
                } else {
                    eprintln!("fixture {id}: {e}");
                    failed.push(id.clone());
                    json!({ "error": truncate(&e, 800) })
                }
            }
        };
        fixtures.insert(id, entry);
    }
    Ok(Report {
        payload: json!({
            "binding": "rust",
            "compiler": compiler.as_str(),
            "fixtures": Value::Object(fixtures),
        }),
        failed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusal_code_names_only_coded_diagnostics() {
        // An ordinary numeric failure names no code and must NEVER be read as
        // a refusal: doing so would turn a wrong answer into a green named
        // exclusion, which is the one way this tier could go quietly blind.
        assert_eq!(refusal_code("expected 1.0, got 2.0 (rel 1.0)"), None);
        assert_eq!(
            refusal_code("simulation failed: unevaluable_operator: operator 'false'"),
            Some("unevaluable_operator".to_string())
        );
        assert_eq!(
            refusal_code("build: E_TREEWALK_CONSTARRAY_OOB at cell 5"),
            Some("E_TREEWALK_CONSTARRAY_OOB".to_string())
        );
    }

    #[test]
    fn parse_args_requires_all_three() {
        assert!(parse_args(["--manifest".into(), "m.json".into()]).is_err());
        let a = parse_args([
            "--manifest".to_string(),
            "m.json".to_string(),
            "--output".to_string(),
            "o.json".to_string(),
            "--compiler".to_string(),
            "interpreter".to_string(),
        ])
        .expect("parses");
        assert_eq!(a.compiler, Compiler::Interpreter);
    }
}
