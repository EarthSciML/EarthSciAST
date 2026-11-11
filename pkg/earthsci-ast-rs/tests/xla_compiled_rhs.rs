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
/// As of the `Instr::ConstArray` / `Instr::Reduce` tape growth this is EVERY
/// fixture in the tier. The four that used to refuse — `elementwise_gather`,
/// `explicit_gather`, `pde_inline_observed_rank2`,
/// `pde_inline_observed_param_rank2` — did so because their `const` data was
/// array-valued, which the lowering bailed on wholesale; the emitter needed no
/// change beyond an arm for the new instruction.
const EXPECTED_LOWERED: &[&str] = &[
    "elementwise_gather",
    "explicit_gather",
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
    "pde_inline_observed_rank2",
    "pde_inline_observed_param_rank2",
    "pde_inline_observed_state_dependent",
    "mount_rename_atm_column",
    "mount_rename_soil_column",
    "units_registry_grammar",
    // Added by the fixture the tier gained after this list was written; the Rust
    // lowering and the fixture landed on separate branches, so nothing had ever
    // run one against the other until the two were merged.
    "datetime_log10",
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
    let text = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()));
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
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let file = load_string(&text).unwrap_or_else(|e| panic!("load {}: {e:?}", path.display()));
    ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("compile {}: {e:?}", path.display()))
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
    Ok {
        worst: f64,
        probes: usize,
    },
    Refused {
        rule: String,
        reason: String,
    },
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
/// mixed run and never a silent pass.
///
/// The fixture is a CAUSAL SELF-REFERENCE whose self-read sits inside an
/// array-valued part of its cell body (a nested `faq` over `j`): the tape
/// lowers a recurrence as a sweep that evaluates each self-read one scalar
/// cell at a time, so this rule stays a `Fallback`. (A plain recurrence is on
/// the tape now, and is refused for a different reason — see
/// [`a_recurrence_sweep_is_refused_by_name`].)
#[test]
fn a_fallback_rule_is_refused_by_name() {
    if !runtime_available() {
        return;
    }
    let text = r#"{
        "esm": "2.0.0",
        "metadata": {"name": "XlaFallback"},
        "index_sets": {"steps": {"kind": "interval", "size": 4}},
        "models": {"R": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "default": 1.0},
                "s": {"type": "unknown", "units": "1", "shape": ["steps"]}
            },
            "equations": [
                {"lhs": "s", "rhs": {
                    "op": "faq", "args": [], "output_idx": ["k"],
                    "ranges": {"k": {"from": "steps"}},
                    "expr": {"op": "ifelse", "args": [
                        {"op": "<=", "args": ["k", 1]},
                        1.0,
                        {"op": "index", "args": [
                            {"op": "faq", "args": [], "output_idx": ["j"],
                             "ranges": {"j": [1, 2]},
                             "expr": {"op": "*", "args": [
                                 {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]},
                                 "j"]}},
                            2]}
                    ]}}},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "*", "args": [-0.01, "u", {"op": "index", "args": ["s", 4]}]}}
            ]
        }}
    }"#;
    let file = load_string(text).expect("fixture loads");
    let compiled = ArrayCompiled::from_file(&file).expect("fixture compiles");
    match CompiledRhs::compile(&compiled) {
        Ok(_) => panic!(
            "the fixture now lowers completely. If the tape really did learn a \
             self-read inside an array-valued part of a recurrence body, move this to \
             another fallback-carrying fixture; if it did not, the emitter is silently \
             dropping a Fallback instruction."
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

/// A recurrence is on the tape as an ordered `Sweep`, which this emitter does
/// not lower (it has no per-cell loop and no channel for the self-read's
/// fail-closed fault): a refusal naming the rule and the construct, never a
/// number (CONFORMANCE_SPEC §5.19.3b).
#[test]
fn a_recurrence_sweep_is_refused_by_name() {
    if !runtime_available() {
        return;
    }
    let path = repo_root().join("tests/fixtures/recurrence/01_recurrence_doubling.esm");
    let compiled = build(&path);
    match CompiledRhs::compile(&compiled) {
        Ok(_) => panic!(
            "{} lowered to XLA: the sweep must be refused",
            path.display()
        ),
        Err(CompileRhsError::Refused(e)) => {
            assert!(!e.rule.is_empty(), "refusal names no rule");
            assert!(e.reason.contains("recurrence"), "{}", e.reason);
        }
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    }
}

/// `true` when this process asked for a GPU client. The client is a
/// process-wide singleton keyed off `EARTHSCI_XLA_PLATFORM`, so the whole test
/// binary runs on one platform; a GPU run is `EARTHSCI_XLA_PLATFORM=gpu cargo
/// test`, not a per-test choice.
fn gpu_requested() -> bool {
    matches!(
        std::env::var("EARTHSCI_XLA_PLATFORM").as_deref(),
        Ok("gpu") | Ok("cuda")
    )
}

/// The tier on the GPU: the same fixtures, the same tolerance classes, the
/// same expected lowering set.
///
/// Two things this asserts that the CPU arm cannot:
///
/// 1. that the client really is a GPU one. `PjRtClient::gpu` failing would
///    reach [`CompileRhsError::Runtime`], but a build that silently fell back
///    to CPU would pass every numeric assertion in this file while proving
///    nothing about a device. The platform name is checked first, before any
///    fixture runs.
/// 2. that the DEVICE-RESIDENT path agrees with the host round trip *exactly*.
///    Not within a tolerance: the two run the identical executable on the
///    identical inputs, so the only way they differ is if one of them is
///    reading a buffer it should not — a stale output, an argument on the
///    wrong device. A tolerance here would hide precisely the bug the path can
///    have.
///
/// Skips loudly when `EARTHSCI_XLA_PLATFORM` is not `gpu`: on a machine with
/// no device this must be a message, not a failure, and not a silent pass.
#[test]
fn compiled_rhs_on_the_gpu() {
    if !runtime_available() {
        return;
    }
    if !gpu_requested() {
        eprintln!(
            "SKIP: EARTHSCI_XLA_PLATFORM is not set to gpu, so this arm has no device \
             to run on. A GPU run needs the CUDA extension \
             (scripts/fetch-xla-extension.sh --variant cuda12), the CUDA libraries it \
             hard-links (scripts/setup-xla-gpu-libs.sh), and \
             EARTHSCI_XLA_PLATFORM=gpu."
        );
        return;
    }

    let platform = earthsci_ast::xla_runtime::client()
        .unwrap_or_else(|e| panic!("GPU client: {e}"))
        .platform_name();
    assert!(
        platform.to_ascii_lowercase().contains("cuda")
            || platform.to_ascii_lowercase().contains("gpu"),
        "EARTHSCI_XLA_PLATFORM=gpu was asked for but the client reports platform \
         {platform:?}; this run would have proved nothing about a device"
    );
    eprintln!("GPU client platform: {platform}");

    let m = manifest();
    let mut lowered: HashSet<String> = HashSet::new();
    for fx in m["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().expect("id").to_string();
        match run_fixture(fx) {
            Outcome::Ok { worst, probes } => {
                eprintln!("{id:38} ok   {probes} probes, worst {worst:.3e} of tolerance");
                lowered.insert(id);
            }
            Outcome::Refused { rule, reason } => {
                assert!(!rule.is_empty(), "{id}: refusal with no rule named");
                eprintln!("{id:38} refused (rule {rule}): {reason}");
            }
        }
    }
    let expected: HashSet<String> = EXPECTED_LOWERED.iter().map(|s| s.to_string()).collect();
    let missing: Vec<&String> = expected.difference(&lowered).collect();
    assert!(
        missing.is_empty(),
        "these fixtures lower on the CPU but not on the GPU: {missing:?} — the \
         emitter is platform-independent, so a difference here is a backend gap, \
         not a model one"
    );
    let extra: Vec<&String> = lowered.difference(&expected).collect();
    assert!(
        extra.is_empty(),
        "fixtures lowered on the GPU that the CPU list does not have: {extra:?}"
    );
}

/// The device-resident evaluator against the host round trip, on whatever
/// platform this binary is running.
///
/// Runs on CPU too, deliberately: residency is a transfer question, not a GPU
/// question, and the aliasing mistakes it can make (reusing a stale output,
/// forgetting to re-upload) are visible on either backend. The GPU is where it
/// PAYS, not where it is correct or not.
#[test]
fn the_device_resident_path_agrees_with_the_host_round_trip() {
    if !runtime_available() {
        return;
    }
    let m = manifest();
    let mut checked = 0usize;
    for fx in m["fixtures"].as_array().expect("fixtures") {
        let rel = fx["path"].as_str().expect("fixture.path");
        let path = repo_root().join("tests").join(rel);
        let compiled = build(&path);
        let program = match CompiledRhs::compile(&compiled) {
            Ok(p) => p,
            Err(CompileRhsError::Refused(_)) => continue,
            Err(CompileRhsError::Runtime(msg)) => panic!("{rel}: xla runtime: {msg}"),
        };
        let params: HashMap<String, f64> = HashMap::new();
        let pv = compiled.debug_resolve_params(&params);
        let names: Vec<String> = compiled.state_variable_names().to_vec();

        for probe in fx["rhs_probes"].as_array().expect("rhs_probes") {
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
                        .expect("probe state")
                })
                .collect();
            let host = program.eval(&u, &pv, t).expect("host round trip");
            let mut dev = program.on_device(&u, &pv).expect("upload");
            dev.eval_at(t).expect("resident eval");
            let resident = dev.du_to_host().expect("copy back");
            assert_eq!(
                host, resident,
                "{rel}: the device-resident path and the host round trip ran the same \
                 executable on the same inputs and disagreed; one of them is not \
                 evaluating what it claims"
            );

            // A second evaluation must not return the first one's buffer: set
            // a different state and require the answer to move (or to be
            // legitimately identical because the right-hand side is constant,
            // which the interpreter settles).
            let mut shifted = u.clone();
            for v in shifted.iter_mut() {
                *v += 0.5;
            }
            dev.set_state(&shifted).expect("re-upload");
            dev.eval_at(t).expect("resident eval 2");
            let after = dev.du_to_host().expect("copy back 2");
            let expected_after = program.eval(&shifted, &pv, t).expect("host round trip 2");
            assert_eq!(
                after, expected_after,
                "{rel}: after set_state the resident path did not re-evaluate — a \
                 stale output buffer would look exactly like this"
            );
            checked += 1;
        }
    }
    assert!(checked > 0, "no fixture exercised the device-resident path");
    eprintln!("device-resident path matched the host round trip on {checked} probe states");
}

/// The on-device time loop: `u <- u + dt * f(u, p, t)` with nothing crossing
/// to the host between steps, against the same recurrence done through the
/// host.
///
/// The comparison is a TOLERANCE one, unlike the two above, and for a reason
/// worth stating: the device loop keeps `u` in device memory across steps
/// while the host loop rounds it into a `Vec<f64>` and back. Both are f64 and
/// both do the same arithmetic, so they should agree to the last bit — but the
/// device update is a separate compiled program, and XLA is free to fuse and
/// reassociate it. A step count this small keeps any such difference far
/// inside the algebraic class.
#[test]
fn the_on_device_euler_loop_tracks_the_host_loop() {
    if !runtime_available() {
        return;
    }
    let path =
        repo_root().join("tests/conformance/pde_simulation/fixtures/diffusion_1d_periodic_n8.esm");
    let compiled = build(&path);
    let program = CompiledRhs::compile(&compiled).expect("diffusion_1d_periodic_n8 lowers");
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    let n = program.n_states();
    let u0: Vec<f64> = (0..n).map(|i| 1.0 + 0.25 * i as f64).collect();
    let dt = 1e-6;
    let steps = 20;

    let mut host = u0.clone();
    for k in 0..steps {
        let du = program.eval(&host, &pv, dt * k as f64).expect("host rhs");
        for (h, d) in host.iter_mut().zip(du.iter()) {
            *h += dt * d;
        }
    }

    let mut dev = program.on_device(&u0, &pv).expect("upload");
    for k in 0..steps {
        dev.euler_step(dt * k as f64, dt).expect("device step");
    }
    let device = dev.state_to_host().expect("copy back");

    assert_eq!(device.len(), host.len());
    let scale = host.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    for (i, (d, h)) in device.iter().zip(host.iter()).enumerate() {
        assert!(
            within("algebraic", *d, *h, scale),
            "slot {i}: on-device loop {d:e} vs host loop {h:e} after {steps} steps"
        );
    }
    eprintln!("on-device euler loop tracked the host loop over {steps} steps on {n} slots");
}

/// The loop-owning tape instructions — a prefix scan (`Instr::Scan`), a
/// `makearray` assembled in one instruction (`Instr::Assemble`) and a
/// contraction folded by one `Instr::Reduce` over its promoted box — lower
/// through the emitter and agree with the interpreter within the `reduction`
/// tolerance class (XLA does not pin a fold's association).
#[test]
fn scans_assemblies_and_promoted_contractions_lower() {
    if !runtime_available() {
        return;
    }
    let n = 9;
    let u_j = r#"{"op": "index", "args": ["u", "j"]}"#;
    let u_i = r#"{"op": "index", "args": ["u", "i"]}"#;
    let doc = format!(
        r#"{{
  "esm": "2.0.0",
  "metadata": {{"name": "XlaLoopProbe"}},
  "index_sets": {{"x": {{"kind": "interval", "size": {n}}}}},
  "models": {{"M": {{
    "variables": {{
      "u": {{"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}},
      "b": {{"type": "unknown", "units": "1", "shape": ["x"]}},
      "c": {{"type": "unknown", "units": "1", "shape": ["x"]}}
    }},
    "equations": [
      {{"lhs": "b", "rhs": {{"op": "faq", "args": [], "output_idx": ["i"],
          "ranges": {{"i": {{"from": "x"}}, "j": {{"from": "x"}}}},
          "filter": {{"op": "<", "args": ["j", "i"]}},
          "expr": {{"op": "*", "args": [{u_j}, 0.5]}}}}}},
      {{"lhs": "c", "rhs": {{"op": "faq", "args": [], "output_idx": ["i"],
          "ranges": {{"i": {{"from": "x"}}, "j": {{"from": "x"}}}},
          "expr": {{"op": "*", "args": [{u_j}, {{"op": "cos", "args": [{{"op": "*", "args": ["i", "j"]}}]}}]}}}}}},
      {{"lhs": {{"op": "faq", "args": [], "output_idx": ["i"],
               "expr": {{"op": "D", "args": [{u_i}], "wrt": "t"}},
               "ranges": {{"i": {{"from": "x"}}}}}},
       "rhs": {{"op": "faq", "args": [], "output_idx": ["i"], "ranges": {{"i": {{"from": "x"}}}},
          "expr": {{"op": "+", "args": [
            {{"op": "index", "args": ["b", "i"]}},
            {{"op": "index", "args": ["c", "i"]}},
            {{"op": "index", "args": [{{"op": "makearray", "args": [],
                "regions": [[[1, {n}]], [[1, 1]], [[{n}, {n}]]],
                "values": [{u_i}, -1.0, {{"op": "*", "args": [2.0, {u_i}]}}]}}, "i"]}}
          ]}}}}}}
    ]
  }}}}
}}"#
    );
    let file = load_string(&doc).expect("the probe document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("it compiles");
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => {
            panic!("the emitter refused rule {}: {}", e.rule, e.reason)
        }
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    };
    // The three rules lowered to the loop-owning instructions this test is
    // about, one each, and not to the per-step or unrolled forms: without
    // this the agreement below would hold just as well over those.
    for op in ["Scan", "Assemble", "Reduce"] {
        assert_eq!(
            program.opcode_count(op),
            1,
            "the lowered tape carries {} `{op}` instructions, expected one",
            program.opcode_count(op)
        );
    }
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    let m = compiled.state_variable_names().len();
    for seed in 0..4 {
        let u: Vec<f64> = (0..m)
            .map(|k| ((k * 7 + seed * 3) % 11) as f64 * 0.37 - 1.5)
            .collect();
        let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, true);
        let got = program.eval(&u, &pv, 0.0).expect("compiled eval");
        let scale = want.iter().fold(0.0f64, |a, v| a.max(v.abs()));
        for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
            assert!(
                within("reduction", *g, *w, scale),
                "seed {seed} tendency {i}: compiled {g:e} vs interpreter {w:e}"
            );
        }
    }
}

/// A prefix-scan document over `n` cells: one inclusive and one exclusive
/// running sum and one reverse (suffix) sum, all read by the state's tendency.
fn scan_doc(n: usize) -> String {
    let u_j = r#"{"op": "index", "args": ["u", "j"]}"#;
    format!(
        r#"{{
  "esm": "2.0.0",
  "metadata": {{"name": "XlaScanProbe"}},
  "index_sets": {{"x": {{"kind": "interval", "size": {n}}}}},
  "models": {{"M": {{
    "variables": {{
      "u": {{"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}},
      "incl": {{"type": "unknown", "units": "1", "shape": ["x"]}},
      "excl": {{"type": "unknown", "units": "1", "shape": ["x"]}},
      "suff": {{"type": "unknown", "units": "1", "shape": ["x"]}}
    }},
    "equations": [
      {{"lhs": "incl", "rhs": {{"op": "faq", "args": [], "output_idx": ["i"],
          "ranges": {{"i": {{"from": "x"}}, "j": {{"from": "x"}}}},
          "filter": {{"op": "<=", "args": ["j", "i"]}},
          "expr": {{"op": "*", "args": [{u_j}, 0.1]}}}}}},
      {{"lhs": "excl", "rhs": {{"op": "faq", "args": [], "output_idx": ["i"],
          "ranges": {{"i": {{"from": "x"}}, "j": {{"from": "x"}}}},
          "filter": {{"op": "<", "args": ["j", "i"]}},
          "expr": {{"op": "*", "args": [{u_j}, 0.3]}}}}}},
      {{"lhs": "suff", "rhs": {{"op": "faq", "args": [], "output_idx": ["i"],
          "ranges": {{"i": {{"from": "x"}}, "j": {{"from": "x"}}}},
          "filter": {{"op": ">=", "args": ["j", "i"]}},
          "expr": {{"op": "*", "args": [{u_j}, 0.7]}}}}}},
      {{"lhs": {{"op": "faq", "args": [], "output_idx": ["i"],
               "expr": {{"op": "D", "args": [{{"op": "index", "args": ["u", "i"]}}], "wrt": "t"}},
               "ranges": {{"i": {{"from": "x"}}}}}},
       "rhs": {{"op": "faq", "args": [], "output_idx": ["i"], "ranges": {{"i": {{"from": "x"}}}},
          "expr": {{"op": "+", "args": [
            {{"op": "-", "args": [
              {{"op": "index", "args": ["incl", "i"]}},
              {{"op": "index", "args": ["excl", "i"]}}]}},
            {{"op": "index", "args": ["suff", "i"]}}]}}}}}}
    ]
  }}}}
}}"#
    )
}

/// `Instr::Scan` lowers to one `while` loop, so the emitted program does not
/// grow with the scanned length — and because the loop folds plane after
/// plane in the sweep's order (descending for the suffix sum), each running
/// sum is the interpreter's own association, bit for bit.
#[test]
fn scan_lowering_is_flat_in_the_scanned_length() {
    if !runtime_available() {
        return;
    }
    use earthsci_ast::simulate_array::tape::xla_emit::emit_rhs;
    let hlo_len = |n: usize| {
        let file = load_string(&scan_doc(n)).expect("the probe document loads");
        let compiled = ArrayCompiled::from_file(&file).expect("it compiles");
        let emitted = emit_rhs(&compiled).expect("the emitter lowers the scans");
        emitted.hlo_text().expect("HLO text").len()
    };
    let (small, large) = (hlo_len(8), hlo_len(512));
    // The lengths differ only in the digits of the extents and loop bounds.
    assert!(
        large.abs_diff(small) < 256,
        "the emitted program grew with the scan: {small} bytes at n = 8, {large} at n = 512"
    );

    let n = 300;
    let file = load_string(&scan_doc(n)).expect("the probe document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("it compiles");
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => {
            panic!("the emitter refused rule {}: {}", e.rule, e.reason)
        }
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    };
    assert_eq!(program.opcode_count("Scan"), 3);
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    let m = compiled.state_variable_names().len();
    let u: Vec<f64> = (0..m)
        .map(|k| ((k * 37) % 101) as f64 * 0.013 - 0.61)
        .collect();
    let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, true);
    let got = program.eval(&u, &pv, 0.0).expect("compiled eval");
    for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
        assert_eq!(
            g.to_bits(),
            w.to_bits(),
            "tendency {i}: compiled {g:e} vs interpreter {w:e}"
        );
    }
}

// ---------------------------------------------------------------------------
// Forcing reads (`Instr::LoadForcing`)
// ---------------------------------------------------------------------------

/// `D(c[i]) = g[i]*k - r*c[i] + bc[i-1]` with `g = 2*bc + k`, where `bc`
/// (shaped) and `k` (0-d) are data-fed parameters the forcing buffer serves.
fn forced_doc(n: i64) -> String {
    let fed = |var: &str| serde_json::json!({"kind": "data", "source": "met", "from": {"file_variable": var}});
    serde_json::json!({
        "esm": "2.0.0",
        "metadata": {"name": "Forced"},
        "index_sets": {"cells": {"kind": "interval", "size": n}},
        "data_sources": {"met": {"kind": "grid", "source": {"url_template": "file:///met.nc"}}},
        "models": {"M": {
            "variables": {
                "c": {"type": "unknown", "units": "1", "shape": ["cells"], "default": 0.5},
                "bc": {"type": "parameter", "units": "1", "shape": ["cells"], "update": fed("bc")},
                "k": {"type": "parameter", "units": "1", "shape": [], "update": fed("k")},
                "g": {"type": "unknown", "units": "1", "shape": ["cells"]},
                "r": {"type": "parameter", "units": "1", "default": 0.3}
            },
            "equations": [
                {"lhs": "g", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "+", "args": [
                        {"op": "*", "args": [2.0, {"op": "index", "args": ["bc", "i"]}]},
                        "k"]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"},
                    "ranges": {"i": [1, n]}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                    "ranges": {"i": [1, n]},
                    "expr": {"op": "+", "args": [
                        {"op": "-", "args": [
                            {"op": "*", "args": [{"op": "index", "args": ["g", "i"]}, "k"]},
                            {"op": "*", "args": ["r", {"op": "index", "args": ["c", "i"]}]}]},
                        {"op": "index", "args": ["bc", {"op": "-", "args": ["i", 1]}]}]}}}
            ]
        }}
    })
    .to_string()
}

fn feed_forced(compiled: &ArrayCompiled, n: usize, scale: f64, k: f64) {
    let buf = compiled.forcing_handle();
    let mut buf = buf.borrow_mut();
    buf.insert(
        "bc".into(),
        ndarray::ArrayD::from_shape_vec(
            ndarray::IxDyn(&[n]),
            (0..n).map(|i| scale * (0.1 + i as f64 * 0.37)).collect(),
        )
        .expect("1-D"),
    );
    buf.insert(
        "k".into(),
        ndarray::ArrayD::from_elem(ndarray::IxDyn(&[]), k),
    );
}

/// A forcing read lowers to a slice of the program's fourth parameter, which
/// the runtime packs from the model's live buffer on every call: the numbers
/// agree with the interpreter (to the FMA contraction XLA may make of
/// `g*k - r*c`), a refreshed buffer is read on the next call, and a missing
/// entry fails with the interpreter's own fault.
#[test]
fn forcing_reads_lower_and_follow_the_buffer() {
    if !runtime_available() {
        return;
    }
    let n = 6usize;
    let file = load_string(&forced_doc(n as i64)).expect("loads");
    let compiled = ArrayCompiled::from_file(&file).expect("compiles");
    feed_forced(&compiled, n, 1.0, 0.7);
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => panic!("refused rule {}: {}", e.rule, e.reason),
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    };
    let params: HashMap<String, f64> = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let u: Vec<f64> = (0..n).map(|i| 0.2 + i as f64 * 0.11).collect();
    let close = |got: &[f64], want: &[f64], label: &str| {
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            assert!(
                (g - w).abs() <= 4e-16 * w.abs().max(1.0),
                "{label}: du[{i}] compiled {g:e} vs interpreter {w:e}"
            );
        }
    };
    for scale in [1.0, 3.0] {
        feed_forced(&compiled, n, scale, 0.7);
        let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, false);
        let got = program.eval(&u, &param_vec, 0.0).expect("compiled eval");
        close(&got, &want, &format!("scale {scale}"));
        let mut dev = program.on_device(&u, &param_vec).expect("upload");
        dev.eval_at(0.0).expect("device eval");
        close(
            &dev.du_to_host().expect("download"),
            &want,
            "device-resident",
        );
    }

    compiled.forcing_handle().borrow_mut().remove("bc");
    earthsci_ast::simulate_array::take_const_array_oob();
    compiled.debug_eval_rhs(&u, 0.0, &params, true);
    let want = earthsci_ast::simulate_array::take_const_array_oob().expect("the oracle faults");
    let got = program.eval(&u, &param_vec, 0.0).expect("compiled eval");
    let fault = earthsci_ast::simulate_array::take_const_array_oob().expect("the program faults");
    assert_eq!(fault, want);
    assert!(got.iter().any(|v| v.is_nan()));
}

/// The array forms phase 3 put on the tape — a column-major `reshape` (an
/// `Instr::Reshape` between two reversal gathers), `transpose`, `concat`, the
/// positional broadcast of anonymous operands, a makearray whose face regions
/// hold lower-rank values, an empty region, a filtered rank-0 reduction and a
/// shaped `ifelse` with a scalar arm — lower through the emitter and agree
/// with the interpreter. Each document's tape is checked to carry the
/// instruction it is here for, so the test notices if the form stopped being
/// taped.
#[test]
fn phase3_array_forms_lower() {
    if !runtime_available() {
        return;
    }
    let cases: &[(&str, &str, &str)] = &[
        (
            "tests/fixtures/faq/11_reshape_roundtrip.esm",
            "Reshape",
            "algebraic",
        ),
        // A gather may be folded into a fused group, so these two name none.
        ("tests/fixtures/faq/12_transpose_2d.esm", "", "algebraic"),
        (
            "tests/fixtures/faq/13_concat_1d.esm",
            "Assemble",
            "algebraic",
        ),
        (
            "tests/fixtures/faq/14_broadcast_elementwise.esm",
            "Reshape",
            "algebraic",
        ),
        ("tests/bench/transport_3axis_7cubed.esm", "", "algebraic"),
        (
            "tests/valid/makearray_empty_region_min_extent.esm",
            "Assemble",
            "algebraic",
        ),
        (
            "tests/conformance/shaped_observed_scalar_broadcast/fixtures/scalar_rhs_broadcast.esm",
            "JmpIfZero",
            "algebraic",
        ),
    ];
    let params: HashMap<String, f64> = HashMap::new();
    for (rel, opcode, class) in cases {
        let path = repo_root().join(rel);
        let compiled = build(&path);
        let listing = compiled.debug_tape_listing();
        assert!(
            opcode.is_empty() || listing.contains(&format!(" {opcode} {{")),
            "{rel}: the tape carries no {opcode}:\n{listing}"
        );
        let program = match CompiledRhs::compile(&compiled) {
            Ok(p) => p,
            Err(CompileRhsError::Refused(e)) => {
                panic!("{rel}: the emitter refused rule {}: {}", e.rule, e.reason)
            }
            Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
        };
        let pv = compiled.debug_resolve_params(&params);
        let m = compiled.state_variable_names().len();
        for seed in 0..3 {
            let u: Vec<f64> = (0..m)
                .map(|k| ((k * 7 + seed * 3) % 11) as f64 * 0.37 - 1.5)
                .collect();
            let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, true);
            let got = program.eval(&u, &pv, 0.0).expect("compiled eval");
            let scale = want.iter().fold(0.0f64, |a, v| a.max(v.abs()));
            for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
                assert!(
                    within(class, *g, *w, scale),
                    "{rel} seed {seed} tendency {i}: compiled {g:e} vs interpreter {w:e}"
                );
            }
        }
    }
}

/// A program that raises a fail-closed fault — here the const-array gather
/// past the end, which the interpreter reports as `E_TREEWALK_CONSTARRAY_OOB`
/// on evaluation — is refused by the emitter with that fault, not compiled
/// into one that returns the `NaN` without the error.
#[test]
fn a_program_that_faults_is_refused_with_the_fault() {
    if !runtime_available() {
        return;
    }
    let path = repo_root()
        .join("tests/conformance/const_array_gather_bounds/fixtures/named_1d_past_end.esm");
    let compiled = build(&path);
    assert!(compiled.debug_tape_listing().contains(" Fault {"));
    match CompiledRhs::compile(&compiled) {
        Ok(_) => panic!("a faulting program compiled"),
        Err(CompileRhsError::Refused(e)) => assert!(
            e.reason.contains("E_TREEWALK_CONSTARRAY_OOB"),
            "the refusal does not carry the fault: {}",
            e.reason
        ),
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    }
}

/// The scaling tier's regrid (the `overlap_area_planar` template over literal
/// rings) and unstructured-gather (a data subscript, lowered to one `take`)
/// fixtures compile and agree with the interpreter. The opcode count pins that
/// the gather reaches the emitter through the instruction it is meant to
/// exercise.
#[test]
fn geometry_and_data_subscript_gathers_lower() {
    if !runtime_available() {
        return;
    }
    let root = repo_root().join("tests/conformance/scaling/fixtures");
    for (path, opcode) in [
        ("regrid/regrid_N100.esm", None),
        (
            "unstructured_gather/unstructured_gather_N100.esm",
            Some("IndexGather"),
        ),
    ] {
        let compiled = build(&root.join(path));
        let report = compiled.debug_build_tape_report();
        let has = |op: &str| report.opcode_counts.iter().any(|(o, n)| o == op && *n > 0);
        // The fused program folds a rank-1 IndexGather into its consumer; the
        // emitter runs the unfused one, where the instruction stands alone.
        if let Some(opcode) = opcode {
            assert!(
                has(opcode) || (opcode == "IndexGather" && report.fuse.n_gathers_folded > 0),
                "{path}: no {opcode} in the tape ({:?})",
                report.opcode_counts
            );
        }
        let program = match CompiledRhs::compile(&compiled) {
            Ok(p) => p,
            Err(CompileRhsError::Refused(e)) => {
                panic!("{path}: the emitter refused rule {}: {}", e.rule, e.reason)
            }
            Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
        };
        let params: HashMap<String, f64> = HashMap::new();
        let pv = compiled.debug_resolve_params(&params);
        let m = compiled.state_variable_names().len();
        for seed in 0..3 {
            let u: Vec<f64> = (0..m)
                .map(|k| 1.0 + 0.1 * ((k * 7 + seed * 3) as f64 * 0.37).sin())
                .collect();
            let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, true);
            let got = program.eval(&u, &pv, 0.0).expect("compiled eval");
            let scale = want.iter().fold(0.0f64, |a, v| a.max(v.abs()));
            for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
                assert!(
                    within("reduction", *g, *w, scale),
                    "{path} seed {seed} tendency {i}: compiled {g:e} vs interpreter {w:e}"
                );
            }
        }
    }
}
