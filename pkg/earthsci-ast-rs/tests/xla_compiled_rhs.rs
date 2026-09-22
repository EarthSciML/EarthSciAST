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
/// The fixture is a CAUSAL SELF-REFERENCE (`k[i]` reads `k[i-1]`), which
/// CONFORMANCE_SPEC §5.19.2 forbids the tape from ever lowering — its cells
/// are not independent and the tape's scheduler reorders and batches. That is
/// what makes it durable here: unlike the array-valued `const` this test used
/// to lean on, it cannot quietly become tapeable and turn the assertion into a
/// tautology.
#[test]
fn a_fallback_rule_is_refused_by_name() {
    if !runtime_available() {
        return;
    }
    let path = repo_root().join("tests/fixtures/recurrence/01_recurrence_doubling.esm");
    let compiled = build(&path);
    match CompiledRhs::compile(&compiled) {
        Ok(_) => panic!(
            "{} now lowers completely. If the tape really did learn causal \
             self-reference, move this to another fallback-carrying fixture; if it \
             did not, the emitter is silently dropping a Fallback instruction.",
            path.display()
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

// ---------------------------------------------------------------------------
// Closed functions: the esm-spec §9.2 `datetime.*` family.
//
// This stands on its own rather than leaning on a tier fixture: the family is
// lowered by the TAPE (into floors, remainders, comparisons and selects), so
// the emitter needed no new arm, and a test that only ran the manifest would
// not notice if it had.
// ---------------------------------------------------------------------------

/// The nine calendar entries, in the order the fixture declares `f0..f8`.
const DATETIME_NAMES: &[&str] = &[
    "datetime.year",
    "datetime.month",
    "datetime.day",
    "datetime.hour",
    "datetime.minute",
    "datetime.second",
    "datetime.day_of_year",
    "datetime.julian_day",
    "datetime.is_leap_year",
];

/// `f7` is `datetime.julian_day` — the one entry the spec allows to drift.
const JULIAN_DAY_VAR: &str = "f7";

/// Probe times: the epoch, both sides of a day boundary, a fractional second
/// each side of the epoch, two leap days, the last second of a leap day, two
/// year boundaries, a leap century (2000), two non-leap centuries (1900
/// backwards and 2100 forwards), a deeply negative time (0001-01-01) and four
/// 400-year era boundaries, where a reciprocal-rewritten divide floors the era
/// one short.
const DATETIME_TIMES: &[f64] = &[
    0.0,
    -1.0,
    -0.5,
    86_399.999,
    86_400.0,
    946_684_800.0,     // 2000-01-01T00:00:00Z
    951_782_400.0,     // 2000-02-29T00:00:00Z (leap day)
    951_868_799.0,     // 2000-02-29T23:59:59Z
    1_709_164_800.0,   // 2024-02-29T00:00:00Z
    1_735_689_599.0,   // 2024-12-31T23:59:59Z
    1_735_689_600.0,   // 2025-01-01T00:00:00Z
    -2_208_988_800.0,  // 1900-01-01T00:00:00Z (non-leap century)
    -2_203_891_201.0,  // 1900-02-28T23:59:59Z
    4_102_444_800.0,   // 2100-01-01T00:00:00Z (non-leap century)
    -62_135_596_800.0, // 0001-01-01T00:00:00Z
    1_500_000_000.25,
    -1_500_000_000.25,
    // The start of a 400-year Gregorian era (March 1 of 0400, 0800, 1600 —
    // `z = day + 719468` an exact multiple of 146097). `fl(1/146097)` is below
    // the true reciprocal, so a backend that answers `z / 146097` with
    // `z * fl(1/146097)` floors the era one short and the whole date moves by
    // a day; these three are the multiples at which that product actually
    // rounds low.
    -49_539_254_400.0, // 0400-03-01T00:00:00Z (era boundary)
    -36_916_473_600.0, // 0800-03-01T00:00:00Z (era boundary)
    -11_670_912_000.0, // 1600-03-01T00:00:00Z (era boundary)
    951_868_800.0,     // 2000-03-01T00:00:00Z (era boundary, product exact)
];

/// One 0-d tendency per calendar entry, each reading the solver time.
fn datetime_doc() -> String {
    let vars: Vec<String> = (0..DATETIME_NAMES.len())
        .map(|k| format!(r#""f{k}": {{"type": "unknown", "default": 0.0}}"#))
        .collect();
    let eqs: Vec<String> = DATETIME_NAMES
        .iter()
        .enumerate()
        .map(|(k, name)| {
            format!(
                r#"{{"lhs": {{"op": "D", "args": ["f{k}"], "wrt": "t"}},
                     "rhs": {{"op": "fn", "name": "{name}", "args": ["t"]}}}}"#
            )
        })
        .collect();
    format!(
        r#"{{"esm": "1.1.0",
             "metadata": {{"name": "CompiledDatetime"}},
             "models": {{"M": {{"variables": {{{}}}, "equations": [{}]}}}}}}"#,
        vars.join(","),
        eqs.join(",")
    )
}

/// The compiled lane's `datetime.*` against the interpreter's closed-function
/// registry.
///
/// The eight integer-valued entries are asserted BIT-identical, not within a
/// tolerance: the whole lowering is `+ - * /`, `floor`, `ceil`, comparisons and
/// selects on integer-valued `f64`s, all of which IEEE-754 pins identically in
/// the interpreter's kernels and in XLA. A tolerance here would hide exactly
/// the kind of off-by-one-day error the lowering can have. `julian_day` gets
/// the spec's 1 ulp, because it ends in a genuine floating-point divide.
#[test]
fn compiled_datetime_family_matches_the_interpreter() {
    if !runtime_available() {
        return;
    }
    let file = load_string(&datetime_doc()).expect("datetime document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("datetime document compiles");
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => panic!(
            "the datetime family must lower completely; refused rule {}: {}",
            e.rule, e.reason
        ),
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    };
    let names: Vec<String> = compiled.state_variable_names().to_vec();
    assert_eq!(names.len(), DATETIME_NAMES.len(), "one tendency per entry");
    let params: HashMap<String, f64> = HashMap::new();
    let param_vec = compiled.debug_resolve_params(&params);
    let u = vec![0.0f64; names.len()];
    for &t in DATETIME_TIMES {
        let (want, _) = compiled.debug_eval_rhs(&u, t, &params, false);
        let got = program.eval(&u, &param_vec, t).expect("compiled eval");
        assert_eq!(got.len(), want.len(), "t={t}: length");
        for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
            if names[i].ends_with(JULIAN_DAY_VAR) {
                // 1 ulp of `w` in the worst binade.
                let ulp = w.abs() * f64::EPSILON;
                assert!(
                    (g - w).abs() <= ulp,
                    "t={t}: datetime.julian_day compiled {g:.17e} vs interpreter \
                     {w:.17e} (more than 1 ulp)"
                );
            } else {
                assert_eq!(
                    g.to_bits(),
                    w.to_bits(),
                    "t={t}: tendency {} compiled {g} vs interpreter {w}",
                    names[i]
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// esm-spec §9.2 `interp.*`
// ---------------------------------------------------------------------------

/// The `interp.*` family through the emitter, against this crate's
/// interpreter.
///
/// Built from an inline document rather than added to the tier manifest: the
/// manifest is the cross-language tier's, owned by its coordinator, and this
/// gate is about the RUST emitter's new arm. The three entries are exercised
/// in one document so a single probe sweep covers all of them.
///
/// The tolerance is §9.2's OWN mixed-FMA bound, `{abs: 0, rel: 4e-16}` (~2 ulp
/// at unit magnitude), and the reason it is not bitwise is worth stating: the
/// cell search, the clamps and the corner reads are exact integer and
/// selection work, and the blend is the three IEEE-754 operations §9.2 pins,
/// in that order — so the ONLY thing that can move a bit here is XLA
/// contracting `a + w * (b - a)` into an FMA, which it does. §9.2 anticipates
/// exactly that ("bindings that use FMA selectively MUST ensure their results
/// still match the non-FMA reference within the per-fixture tolerance") and
/// prices it at this bound.
///
/// So the test also COUNTS the probes that are not bit-identical and asserts
/// that count stays small. A tolerance alone would pass just as happily if
/// every probe drifted; the count is what would catch a lowering that started
/// blending in a different order rather than merely fusing a multiply.
#[test]
fn interp_lowers_and_matches_the_interpreter() {
    if !runtime_available() {
        return;
    }
    // A non-uniform axis (so a wrong cell cannot hide behind even spacing), a
    // 3x4 bilinear grid, and a searchsorted table with a duplicate run.
    let doc = r#"{
  "esm": "1.0.0",
  "metadata": { "name": "XlaInterpProbe", "description": "One state per §9.2 interp entry, each reading query states, so a probe places every query independently." },
  "models": { "M": { "variables": {
      "qa": { "type": "unknown", "units": "1", "default": 0.0 },
      "qb": { "type": "unknown", "units": "1", "default": 0.0 },
      "lin": { "type": "unknown", "units": "1", "default": 0.0 },
      "bil": { "type": "unknown", "units": "1", "default": 0.0 },
      "ss":  { "type": "unknown", "units": "1", "default": 0.0 }
    },
    "equations": [
      { "lhs": { "op": "D", "args": ["qa"], "wrt": "t" }, "rhs": 0.0 },
      { "lhs": { "op": "D", "args": ["qb"], "wrt": "t" }, "rhs": 0.0 },
      { "lhs": { "op": "D", "args": ["lin"], "wrt": "t" },
        "rhs": { "op": "fn", "name": "interp.linear", "args": [
          { "op": "const", "args": [], "value": [10.0, 20.0, 40.0, 80.0, 160.0] },
          { "op": "const", "args": [], "value": [0.0, 1.0, 2.5, 3.0, 7.0] },
          "qa" ]} },
      { "lhs": { "op": "D", "args": ["bil"], "wrt": "t" },
        "rhs": { "op": "fn", "name": "interp.bilinear", "args": [
          { "op": "const", "args": [], "value": [[0.0, 1.0, 2.0, 3.0], [10.0, 11.5, 12.0, 13.0], [20.0, 21.0, 22.5, 23.0]] },
          { "op": "const", "args": [], "value": [0.0, 1.0, 2.0] },
          { "op": "const", "args": [], "value": [0.0, 10.0, 25.0, 30.0] },
          "qa", "qb" ]} },
      { "lhs": { "op": "D", "args": ["ss"], "wrt": "t" },
        "rhs": { "op": "fn", "name": "interp.searchsorted", "args": [
          "qa", { "op": "const", "args": [], "value": [1.0, 2.0, 2.0, 2.0, 4.0, 5.0] } ]} }
    ] } }
}"#;
    let file = load_string(doc).expect("the probe document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("it compiles");
    let program = match CompiledRhs::compile(&compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => {
            panic!("the emitter refused rule {}: {}", e.rule, e.reason)
        }
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    };
    let names: Vec<String> = compiled.state_variable_names().to_vec();
    let bare = |n: &str| {
        names
            .iter()
            .position(|s| s == n || s.split_once('.').map(|x| x.1) == Some(n))
            .unwrap_or_else(|| panic!("no state {n:?} in {names:?}"))
    };
    let (ia, ib) = (bare("qa"), bare("qb"));
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);

    // Below range, on the first knot, mid-cell, on each interior knot, on the
    // last knot, above range — in both axes, and on the duplicate run of the
    // searchsorted table. NaN is left out: the tier compares `f64` bits, and a
    // NaN payload is not a lowering property (the interpreter's comes out of
    // Rust's arithmetic, the compiled one out of XLA's).
    let qas = [-2.0, 0.0, 0.5, 1.0, 2.0, 2.5, 2.75, 3.0, 5.0, 7.0, 9.0];
    let qbs = [-5.0, 0.0, 4.0, 10.0, 18.0, 25.0, 27.5, 30.0, 51.0];
    let mut probes = 0usize;
    let mut inexact = 0usize;
    let mut worst = 0.0f64;
    for a in qas {
        for b in qbs {
            let mut u = vec![0.0f64; names.len()];
            u[ia] = a;
            u[ib] = b;
            let (want, _) = compiled.debug_eval_rhs(&u, 0.0, &params, false);
            let got = program.eval(&u, &pv, 0.0).expect("compiled eval");
            assert_eq!(got.len(), want.len());
            for (i, (g, w)) in got.iter().zip(want.iter()).enumerate() {
                if g.to_bits() == w.to_bits() {
                    continue;
                }
                inexact += 1;
                // §9.2's mixed-FMA / non-FMA bound.
                assert!(
                    (g - w).abs() <= 4e-16 * w.abs(),
                    "interp probe (qa={a}, qb={b}) tendency {}: compiled {g:.17e} vs \
                     interpreter {w:.17e} — beyond §9.2's mixed-FMA tolerance, so this \
                     is a lowering difference and not a contracted multiply",
                    names[i]
                );
                worst = worst.max((g - w).abs() / (4e-16 * w.abs()));
            }
            probes += 1;
        }
    }
    // Every tendency of every probe; only the `interp.linear` /
    // `interp.bilinear` blends can be inexact at all, and only where the
    // weight is not 0 or 1.
    let checked = probes * names.len();
    assert!(
        inexact * 4 <= checked,
        "{inexact} of {checked} compiled values differ from the interpreter; the blend \
         is supposed to be the same three operations, with only a contracted multiply \
         between them"
    );
    eprintln!(
        "interp: {probes} probes, {} of {checked} values bit-identical, worst \
         {worst:.3e} of §9.2's mixed-FMA tolerance",
        checked - inexact
    );
}
