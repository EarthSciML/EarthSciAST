//! The compiled (XLA) right-hand side against the interpreter, over the
//! `compiled_rhs` conformance tier's own fixtures and probes.
//!
//! This is the in-crate half of the phase-2 gate. The cross-language half is
//! `scripts/run-compiled-rhs-conformance.py --engine compiled`, which compares
//! the same numbers against the Julia-interpreter golden; here the reference
//! is THIS crate's interpreter (`ArrayCompiled::debug_eval_rhs`), so a
//! divergence localizes to the emitter rather than to the two bindings'
//! evaluators.
//!
//! Three things are asserted, and the third is the one that keeps the file
//! honest:
//!
//! 1. every fixture the emitter lowers agrees with the interpreter inside its
//!    manifest tolerance class, at every manifest probe;
//! 2. every fixture it refuses names a rule and a reason — a refusal with an
//!    empty rule would reach the tier's report as an unattributable exclusion;
//! 3. the SET of lowered fixtures is exactly the list below. Coverage that
//!    silently shrinks is the failure mode a pass/refuse-agnostic test cannot
//!    see: without this, an emitter that refused everything would be green.
//!
//! The whole file is behind the `xla` feature and additionally skips (loudly,
//! not silently) when `XLA_EXTENSION_DIR` is unset.
#![cfg(feature = "xla")]

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use earthsci_ast::load_string;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::xla_runtime::{CompileRhsError, CompiledRhs};
use serde_json::Value;

/// Fixture ids the emitter is expected to lower completely. Anything else in
/// the manifest must refuse, by name — see assertion 3 in the module docs.
///
/// The four the manifest carries and this list does not —
/// `elementwise_gather`, `explicit_gather`, `pde_inline_observed_rank2`,
/// `pde_inline_observed_param_rank2` — all refuse for the SAME reason, and it
/// is a gap in the TAPE, not in this emitter: their `const` data is
/// array-valued, which the lowering bails on wholesale, so the rule reaches
/// the emitter as a `Fallback`. They move into this list when the tape grows
/// an array-constant instruction, with no change here beyond the move.
const EXPECTED_LOWERED: &[&str] = &[
    "diffusion_1d_dirichlet_n4",
    "diffusion_1d_neumann_n4",
    "diffusion_1d_zero_gradient_n4",
    "diffusion_1d_robin_n4",
    "diffusion_1d_periodic_n4",
    "diffusion_1d_periodic_n8",
    "diffusion_2d_dirichlet_n3",
    "advection_1d_periodic_n4",
    "events_cross_system_meteorology",
    "expr_graphs_variable_deps",
    "pde_inline_observed_indexed_lhs",
    "pde_inline_observed_state_dependent",
    "mount_rename_atm_column",
    "mount_rename_soil_column",
    "units_registry_grammar",
];

fn repo_root() -> PathBuf {
    // <repo>/pkg/earthsci-ast-rs
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("crate sits two levels below the repository root")
        .to_path_buf()
}

fn manifest() -> Value {
    let p = repo_root().join("tests/conformance/compiled_rhs/manifest.json");
    let text = std::fs::read_to_string(&p)
        .unwrap_or_else(|e| panic!("read {}: {e}", p.display()));
    serde_json::from_str(&text).expect("manifest parses")
}

/// `true` when the XLA runtime is configured on this machine. The extension is
/// a separately-fetched 144 MB release; a developer without it must get a
/// message, not a failure and not a silent pass.
fn runtime_available() -> bool {
    if std::env::var_os("XLA_EXTENSION_DIR").is_none() {
        eprintln!(
            "SKIP: XLA_EXTENSION_DIR is unset, so there is no XLA runtime to test \
             against. Fetch one with scripts/fetch-xla-extension.sh and re-run with \
             --features xla."
        );
        return false;
    }
    true
}

fn build(path: &Path) -> ArrayCompiled {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let file = load_string(&text).unwrap_or_else(|e| panic!("load {}: {e:?}", path.display()));
    ArrayCompiled::from_file(&file)
        .unwrap_or_else(|e| panic!("compile {}: {e:?}", path.display()))
}

/// `|got - want| <= atol + rtol * |want|` with the manifest's classes. The
/// `reduction` class's `atol` is SCALED by the probe's largest magnitude, so
/// an exact zero beside a large entry is not given an impossible bound (the
/// tier README's reading 7).
fn within(class: &str, got: f64, want: f64, scale: f64) -> bool {
    let (rtol, atol) = match class {
        "algebraic" => (1e-13, 1e-300),
        "transcendental" => (1e-12, 1e-300),
        "reduction" => (1e-11, 1e-14 * scale),
        "float32" => (1e-5, 1e-30),
        other => panic!("unknown tolerance class {other:?}"),
    };
    if got == want {
        return true;
    }
    (got - want).abs() <= atol + rtol * want.abs()
}

/// What one fixture did.
enum Outcome {
    /// Lowered; carries the worst `|got - want| / tolerance` ratio seen.
    Ok { worst: f64, probes: usize },
    Refused { rule: String, reason: String },
}

fn run_fixture(fx: &Value) -> Outcome {
    let rel = fx["path"].as_str().expect("fixture.path");
    let class = fx["tolerance_class"].as_str().expect("tolerance_class");
    let path = repo_root().join("tests").join(rel);
    let compiled = build(&path);
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => {
            return Outcome::Refused {
                rule: e.rule,
                reason: e.reason,
            };
        }
        Err(CompileRhsError::Runtime(m)) => panic!("{rel}: xla runtime: {m}"),
    };
    let names: Vec<String> = compiled.state_variable_names().to_vec();
    let params: HashMap<String, f64> = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);

    let mut worst = 0.0f64;
    let mut probes = 0usize;
    for probe in fx["rhs_probes"].as_array().expect("rhs_probes") {
        let pid = probe["id"].as_str().unwrap_or("?");
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let state_obj = probe["state"].as_object().expect("probe.state");
        let u: Vec<f64> = names
            .iter()
            .map(|n| {
                let bare = n.split_once('.').map(|x| x.1).unwrap_or(n);
                state_obj
                    .get(n)
                    .or_else(|| state_obj.get(bare))
                    .and_then(Value::as_f64)
                    .unwrap_or_else(|| panic!("{rel} probe {pid}: no state for {bare}"))
            })
            .collect();
        let (want, _) = compiled.debug_eval_rhs(&u, t, &params, false);
        let got = program.eval(&u, &param_vec, t).expect("compiled eval");
        assert_eq!(got.len(), want.len(), "{rel} probe {pid}: length");
        let scale = want.iter().fold(0.0f64, |m, v| m.max(v.abs()));
        for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
            assert!(
                within(class, *g, *w, scale),
                "{rel} probe {pid} element {} ({}): compiled {g:e} vs interpreter {w:e} \
                 (class {class})",
                i,
                names[i]
            );
            let denom = match class {
                "reduction" => 1e-14 * scale + 1e-11 * w.abs(),
                "transcendental" => 1e-12 * w.abs(),
                _ => 1e-13 * w.abs(),
            };
            if denom > 0.0 {
                worst = worst.max((g - w).abs() / denom);
            }
        }
        probes += 1;
    }
    Outcome::Ok { worst, probes }
}

#[test]
fn compiled_rhs_matches_the_interpreter_over_the_tier() {
    if !runtime_available() {
        return;
    }
    let m = manifest();
    let mut lowered: HashSet<String> = HashSet::new();
    let mut refused: Vec<(String, String, String)> = Vec::new();
    for fx in m["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().expect("id").to_string();
        match run_fixture(fx) {
            Outcome::Ok { worst, probes } => {
                eprintln!("{id:38} ok   {probes} probes, worst {worst:.3e} of tolerance");
                lowered.insert(id);
            }
            Outcome::Refused { rule, reason } => {
                assert!(!rule.is_empty(), "{id}: refusal with no rule named");
                assert!(!reason.is_empty(), "{id}: refusal with no reason");
                eprintln!("{id:38} refused (rule {rule}): {reason}");
                refused.push((id, rule, reason));
            }
        }
    }
    let expected: HashSet<String> = EXPECTED_LOWERED.iter().map(|s| s.to_string()).collect();
    let missing: Vec<&String> = expected.difference(&lowered).collect();
    let extra: Vec<&String> = lowered.difference(&expected).collect();
    assert!(
        missing.is_empty(),
        "fixtures that used to lower now refuse: {missing:?} (refusals were {refused:?})"
    );
    assert!(
        extra.is_empty(),
        "fixtures now lower that EXPECTED_LOWERED does not list: {extra:?} — coverage \
         grew; add them to the list (and to `compiled_required` in the manifest, which \
         the tier coordinator owns)"
    );
}

/// A model with a `Fallback` rule is a HARD refusal naming the rule, never a
/// mixed run and never a silent pass. `elementwise_gather` is the tier's
/// standing example: its `faq` prefix sum is not on the tape today.
#[test]
fn a_fallback_rule_is_refused_by_name() {
    if !runtime_available() {
        return;
    }
    let path = repo_root()
        .join("tests/conformance/elementwise_observed_gather/fixtures/elementwise_gather.esm");
    let compiled = build(&path);
    match CompiledRhs::compile(&compiled) {
        Ok(_) => panic!(
            "elementwise_gather now lowers completely. That is good news, not a bug: \
             move it into EXPECTED_LOWERED above and give this test another \
             fallback-carrying fixture."
        ),
        Err(CompileRhsError::Refused(e)) => {
            assert!(!e.rule.is_empty(), "refusal names no rule");
            assert!(
                e.reason.contains("not on the tape") || e.reason.contains("no lowering"),
                "refusal reason does not say what could not be lowered: {}",
                e.reason
            );
            eprintln!("refused rule {}: {}", e.rule, e.reason);
        }
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    }
}
