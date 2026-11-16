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

use std::path::Path;

use serde_json::{Value, json};

pub use crate::adapter_support::Report;
use crate::adapter_support::{
    self, Answer, Manifest, Tier, required_compiler, solver_alg, truncate,
};
use crate::inline_tests::{InlineTestOptions, run_inline_tests_with_options};
use crate::problem::Compiler;
use crate::simulate::SolveOptions;

/// The coded diagnostics a refusal can carry. A message naming one of these is
/// this binding declining to evaluate the document, which the tier gates as a
/// REFUSAL — a named exclusion only where the fixture's ledger admits it, never
/// a wrong answer and never a silent skip. Anything else is an ordinary
/// assertion failure.
const REFUSAL_CODES: [&str; 5] = [
    "compiler_refused_rule",
    "compiler_unavailable",
    "unevaluable_operator",
    "unlowered_operator",
    "unsupported_construct",
];

/// The adapter's parsed command line: `--manifest <m> --output <o>
/// --compiler <c>`.
pub type Args = adapter_support::Args<Compiler>;

/// Parse `--manifest <m> --output <o> --compiler <c>`, rejecting anything else
/// ([`required_compiler`]).
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    adapter_support::parse_args(args, Some("--compiler"), required_compiler)
}

/// This tier under one compiler.
pub struct InlineTests(pub Compiler);

/// The tier the binary's `--compiler` names ([`required_compiler`]).
pub fn configure(value: Option<&str>) -> Result<InlineTests, String> {
    required_compiler(value).map(InlineTests)
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
    let start = message.find("E_TREEWALK_")?;
    let end = message[start..]
        .find(|c: char| !(c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'))
        .map(|i| start + i)
        .unwrap_or(message.len());
    Some(message[start..end].to_string())
}

fn run_fixture(fx: &Value, manifest: &Manifest, compiler: Compiler) -> Result<Answer, String> {
    let path = manifest.fixture_path(fx)?;
    // Loaded from its path, so its relative refs (subsystems,
    // `expression_template_imports`) resolve against its own directory.
    let file = crate::load_path(&path).map_err(|e| format!("load: {e:?}"))?;
    let model = fx["model"].as_str().ok_or("fixture.model missing")?;

    let integ = manifest.integrator();
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
    let results = run_inline_tests_with_options(&file, &opts);
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

impl Tier for InlineTests {
    fn header(&self) -> Option<(&'static str, &'static str)> {
        Some(("compiler", self.0.as_str()))
    }

    fn run_fixture(&self, fx: &Value, manifest: &Manifest) -> Result<Answer, String> {
        run_fixture(fx, manifest, self.0)
    }

    /// An error naming a coded diagnostic is this compiler declining the
    /// document (a build-time refusal), reported as `refused`, not `error`.
    fn excuse(&self, error: &str) -> Option<Value> {
        refusal_code(error).map(
            |code| json!({ "status": "refused", "code": code, "reason": truncate(error, 400) }),
        )
    }
}

/// Run a whole manifest under one compiler and build the report
/// ([`adapter_support::run_manifest`]): a fixture that throws is its own
/// `error` entry unless it names a refusal code, and a `compiler_unavailable`
/// replaces the whole payload.
pub fn run_manifest(manifest_path: &Path, compiler: Compiler) -> Result<Report, String> {
    adapter_support::run_manifest(&InlineTests(compiler), manifest_path)
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
        assert_eq!(a.config, Compiler::Interpreter);
    }
}
