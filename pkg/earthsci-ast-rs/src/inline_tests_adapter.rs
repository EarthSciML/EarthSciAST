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

use std::io::{self, BufRead, Write};
use std::path::Path;

use serde::Deserialize;
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

#[derive(Deserialize)]
struct ProbeRequest {
    document: Value,
    requests: Vec<ProbeAssertion>,
}

#[derive(Deserialize)]
struct ProbeAssertion {
    test_id: String,
    assertion_idx: usize,
}

fn probe_values(line: &[u8]) -> Result<Vec<String>, String> {
    let request: ProbeRequest =
        serde_json::from_slice(line).map_err(|error| format!("invalid request: {error}"))?;
    let file = crate::load_document(&request.document).map_err(|e| format!("load: {e:?}"))?;
    let options = InlineTestOptions {
        model_name: Some("Probe".to_owned()),
        compiler: Some(Compiler::Native),
        ..Default::default()
    };
    let results = run_inline_tests_with_options(&file, &options);
    request
        .requests
        .iter()
        .map(|assertion| {
            let result = results
                .iter()
                .find(|r| {
                    r.test_id == assertion.test_id && r.assertion_idx == assertion.assertion_idx
                })
                .ok_or_else(|| {
                    format!(
                        "missing Probe assertion {:?} at index {}",
                        assertion.test_id, assertion.assertion_idx
                    )
                })?;
            // The expected value in a generated probe is a placeholder.
            result
                .actual
                .map(|value| value.to_bits().to_string())
                .ok_or_else(|| result.message.clone())
        })
        .collect()
}

/// Run a stream of generated scalar probes through the inline-test runner.
/// A response contains raw binary64 bits in request order or the error for
/// that input line. Flush each response so a caller can submit one case at a
/// time while keeping the same interpreter process.
pub fn run_jsonl(input: impl BufRead, mut output: impl Write) -> io::Result<()> {
    for line in input.split(b'\n') {
        let response = match probe_values(&line?) {
            Ok(values) => json!({ "values": values }),
            Err(error) => json!({ "error": error }),
        };
        serde_json::to_writer(&mut output, &response)?;
        writeln!(output)?;
        output.flush()?;
    }
    Ok(())
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

    fn scalar_request(parameter: &str, value: f64, probes: &[(&str, Value)]) -> Value {
        let mut variables = serde_json::Map::new();
        variables.insert(
            parameter.to_owned(),
            json!({ "type": "parameter", "units": "1", "description": parameter, "default": value }),
        );
        let mut equations = Vec::new();
        let mut assertions = Vec::new();
        for (name, expr) in probes {
            variables.insert(
                (*name).to_owned(),
                json!({ "type": "unknown", "units": "1", "description": name }),
            );
            equations.push(json!({ "lhs": name, "rhs": expr }));
            assertions.push(json!({ "variable": name, "time": 0, "expected": 0 }));
        }
        let requests: Vec<_> = (1..=probes.len())
            .map(|idx| json!({ "test_id": "probe", "assertion_idx": idx }))
            .collect();
        json!({
            "document": {
                "esm": "2.4.0",
                "metadata": { "name": "ScalarProbe", "description": "JSONL adapter probe" },
                "models": {
                    "Probe": {
                        "variables": variables,
                        "equations": equations,
                        "tests": [{
                            "id": "probe",
                            "time_span": { "start": 0, "end": 1 },
                            "assertions": assertions
                        }]
                    }
                }
            },
            "requests": requests
        })
    }

    fn jsonl_responses(input: &str) -> Vec<Value> {
        let mut output = Vec::new();
        run_jsonl(input.as_bytes(), &mut output).expect("adapter streams responses");
        std::str::from_utf8(&output)
            .expect("UTF-8")
            .lines()
            .map(|line| serde_json::from_str(line).expect("one JSON response per line"))
            .collect()
    }

    #[test]
    fn jsonl_keeps_request_order_and_continues_after_bad_input() {
        let mut request = scalar_request(
            "x",
            1.5,
            &[
                ("positive", json!("x")),
                ("negative", json!({ "op": "-", "args": ["x"] })),
            ],
        );
        request["requests"].as_array_mut().unwrap().reverse();
        let missing_assertion = json!({
            "document": request["document"],
            "requests": [{ "test_id": "probe", "assertion_idx": 3 }]
        });
        let input = format!("{{bad JSON}}\n{missing_assertion}\n{request}\n");
        let responses = jsonl_responses(&input);
        assert_eq!(responses.len(), 3);
        assert!(
            responses[0]["error"]
                .as_str()
                .unwrap()
                .contains("invalid request")
        );
        assert!(
            responses[1]["error"]
                .as_str()
                .unwrap()
                .contains("missing Probe assertion")
        );
        assert_eq!(
            responses[2]["values"],
            json!([
                (-1.5f64).to_bits().to_string(),
                1.5f64.to_bits().to_string()
            ])
        );
    }

    #[test]
    fn jsonl_extrema_preserve_signed_zero_and_propagate_nan() {
        let zero = json!("z");
        let neg_zero = json!({ "op": "-", "args": ["z"] });
        let nan = json!({ "op": "/", "args": ["z", "z"] });
        let mut probes = Vec::new();
        for (op, names) in [
            (
                "min",
                [
                    "min_forward",
                    "min_reverse",
                    "min_nan_left",
                    "min_nan_right",
                ],
            ),
            (
                "max",
                [
                    "max_forward",
                    "max_reverse",
                    "max_nan_left",
                    "max_nan_right",
                ],
            ),
        ] {
            for (name, args) in names.into_iter().zip([
                [&zero, &neg_zero],
                [&neg_zero, &zero],
                [&nan, &zero],
                [&zero, &nan],
            ]) {
                probes.push((name, json!({ "op": op, "args": args })));
            }
        }
        let mut request = scalar_request("z", 0.0, &probes);
        for width in ["Float64", "Float32"] {
            request["document"]["domain"] = json!({ "element_type": width });
            let responses = jsonl_responses(&format!("{request}\n"));
            assert_eq!(responses.len(), 1);
            let actual: Vec<u64> = responses[0]["values"]
                .as_array()
                .unwrap_or_else(|| panic!("{width} response: {}", responses[0]))
                .iter()
                .map(|value| value.as_str().unwrap().parse().unwrap())
                .collect();
            assert_eq!(actual.len(), 8);
            assert_eq!(actual[..2], [(-0.0f64).to_bits(); 2], "{width} min");
            assert_eq!(actual[4..6], [0.0f64.to_bits(); 2], "{width} max");
            assert!(
                [2, 3, 6, 7]
                    .iter()
                    .all(|&i| f64::from_bits(actual[i]).is_nan()),
                "{width} NaN results: {actual:?}"
            );
        }
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
