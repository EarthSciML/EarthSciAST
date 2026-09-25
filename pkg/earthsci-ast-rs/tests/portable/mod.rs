//! Native-against-interpreter checks that need no filesystem, shared by the
//! wasm suite (`tests/wasm_suite.rs`, run under Node on wasm32) and its host
//! mirror (`tests/portable_native_interpreter.rs`).
//!
//! Every document is embedded with `include_str!`. Each check builds the same
//! document under `compiler = native` and `compiler = interpreter` IN THE SAME
//! PROCESS and requires the two to agree bit for bit: bit-identity is a
//! per-target rule (a platform's math library rounds transcendentals its own
//! way, so results on wasm and on the host are compared to their own
//! interpreter, never to each other).
//!
//! Two sets of documents:
//! - the scaling tier's committed small fixtures
//!   (`tests/conformance/scaling/fixtures/`): the right-hand side at one
//!   state, and a refusal only where the tier's Rust ledger expects one;
//! - the documents of the inline-test tiers that need no filesystem
//!   (`broadcast_alignment`, `scalar_operator_semantics`, every
//!   `pde_inline_*`): the build-time fields and the whole trajectory at the
//!   times the document's own tests assert at, with default parameters and
//!   initial conditions. The assertions themselves are the native-only
//!   inline-test runner's business (its module is not compiled for wasm32),
//!   and `mounted_component_tests` is left out because a mount is a file
//!   reference.

#![allow(dead_code)]

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{
    Alg, CompileError, Compiler, ProblemOptions, Rhs, SimulateError, SolveOptions, esm_problem,
    solve,
};
use serde_json::Value;

/// The scaling tier's manifest, for its Rust ledger.
pub const SCALING_MANIFEST: &str =
    include_str!("../../../../tests/conformance/scaling/manifest.json");

macro_rules! scaling_fixture {
    ($fam:literal, $n:literal) => {
        (
            $fam,
            $n,
            include_str!(concat!(
                "../../../../tests/conformance/scaling/fixtures/",
                $fam,
                "/",
                $fam,
                "_N",
                $n,
                ".esm"
            )),
        )
    };
}

/// `(family, nominal N, document)` for every committed scaling fixture.
pub const SCALING_FIXTURES: &[(&str, u64, &str)] = &[
    scaling_fixture!("stencil_1d", 100),
    scaling_fixture!("stencil_1d", 1000),
    scaling_fixture!("stencil_2d", 100),
    scaling_fixture!("stencil_2d", 1000),
    scaling_fixture!("stencil_3d", 100),
    scaling_fixture!("stencil_3d", 1000),
    scaling_fixture!("stencil_4d", 100),
    scaling_fixture!("stencil_4d", 1000),
    scaling_fixture!("transport_3d", 100),
    scaling_fixture!("transport_3d", 1000),
    scaling_fixture!("chemistry_grid", 100),
    scaling_fixture!("chemistry_grid", 1000),
    scaling_fixture!("prefix_scan", 100),
    scaling_fixture!("prefix_scan", 1000),
    scaling_fixture!("source_receptor", 100),
    scaling_fixture!("source_receptor", 1000),
    scaling_fixture!("regrid", 100),
    scaling_fixture!("regrid", 1000),
    scaling_fixture!("unstructured_gather", 100),
    scaling_fixture!("unstructured_gather", 1000),
    scaling_fixture!("scalar_chemistry", 100),
    scaling_fixture!("scalar_chemistry", 1000),
];

macro_rules! tier_doc {
    ($tier:literal, $id:literal, $path:literal, $model:literal) => {
        (
            concat!($tier, "/", $id),
            $model,
            include_str!(concat!("../../../../tests/", $path)),
        )
    };
}

/// `(tier/fixture id, model, document)` for the inline-test tiers' documents.
pub const INLINE_TIER_DOCS: &[(&str, &str, &str)] = &[
    tier_doc!(
        "broadcast_alignment",
        "bare_rank_lift",
        "valid/array_broadcast/bare_rank_lift.esm",
        "bare_rank_lift"
    ),
    tier_doc!(
        "broadcast_alignment",
        "bare_mixed_rank_product",
        "valid/array_broadcast/bare_mixed_rank_product.esm",
        "bare_mixed_rank_product"
    ),
    tier_doc!(
        "broadcast_alignment",
        "bare_axis_permuted_operand",
        "valid/array_broadcast/bare_axis_permuted_operand.esm",
        "bare_axis_permuted_operand"
    ),
    tier_doc!(
        "broadcast_alignment",
        "broadcast_node_mixed_rank",
        "valid/array_broadcast/broadcast_node_mixed_rank.esm",
        "broadcast_node_mixed_rank"
    ),
    tier_doc!(
        "broadcast_alignment",
        "anonymous_shape_positional",
        "conformance/broadcast_alignment/fixtures/anonymous_shape_positional.esm",
        "anonymous_shape_positional"
    ),
    tier_doc!(
        "broadcast_alignment",
        "unary_broadcast_fn",
        "conformance/broadcast_alignment/fixtures/unary_broadcast_fn.esm",
        "unary_broadcast_fn"
    ),
    tier_doc!(
        "broadcast_alignment",
        "observed_expression_aligned",
        "conformance/broadcast_alignment/fixtures/observed_expression_aligned.esm",
        "observed_expression_aligned"
    ),
    tier_doc!(
        "scalar_operator_semantics",
        "scalar_operator_semantics",
        "conformance/scalar_operator_semantics/fixtures/scalar_operator_semantics.esm",
        "Ops"
    ),
    tier_doc!(
        "scalar_operator_semantics",
        "boolean_literal_false",
        "conformance/scalar_operator_semantics/fixtures/boolean_literal_false.esm",
        "FalseOp"
    ),
    tier_doc!(
        "scalar_operator_semantics",
        "pow_alias",
        "conformance/scalar_operator_semantics/fixtures/pow_alias.esm",
        "PowAlias"
    ),
    tier_doc!(
        "scalar_operator_semantics",
        "boolean_literal_true",
        "conformance/scalar_operator_semantics/fixtures/boolean_literal_true.esm",
        "TrueOp"
    ),
    tier_doc!(
        "pde_inline_array_overrides",
        "column_array_overrides",
        "conformance/pde_inline_array_overrides/fixtures/column_array_overrides.esm",
        "Column"
    ),
    tier_doc!(
        "pde_inline_array_overrides",
        "slab_array_overrides_rank2",
        "conformance/pde_inline_array_overrides/fixtures/slab_array_overrides_rank2.esm",
        "Slab"
    ),
    tier_doc!(
        "pde_inline_dead_observed",
        "dead_observed",
        "conformance/pde_inline_dead_observed/fixtures/dead_observed.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_ic_param_override",
        "ic_param_override",
        "conformance/pde_inline_ic_param_override/fixtures/ic_param_override.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_ic_param_override",
        "ic_param_override_rank3",
        "conformance/pde_inline_ic_param_override/fixtures/ic_param_override_rank3.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_ic_param_override",
        "ic_param_default_rank3",
        "conformance/pde_inline_ic_param_override/fixtures/ic_param_default_rank3.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_observed_indexed_lhs",
        "observed_indexed_lhs",
        "conformance/pde_inline_observed_indexed_lhs/fixtures/observed_indexed_lhs.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_observed_indexed_lhs",
        "observed_bare_index_lhs",
        "conformance/pde_inline_observed_indexed_lhs/fixtures/observed_bare_index_lhs.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_observed_param_rank2",
        "observed_param_rank2",
        "conformance/pde_inline_observed_param_rank2/fixtures/observed_param_rank2.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_observed_rank2",
        "observed_rank2",
        "conformance/pde_inline_observed_rank2/fixtures/observed_rank2.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_observed_state_dependent",
        "observed_state_dependent",
        "conformance/pde_inline_observed_state_dependent/fixtures/observed_state_dependent.esm",
        "M"
    ),
    tier_doc!(
        "pde_inline_reference_dimension_names",
        "reference_dimension_names",
        "conformance/pde_inline_reference_dimension_names/fixtures/reference_dimension_names.esm",
        "M"
    ),
];

fn options(compiler: Compiler, model: Option<&str>) -> ProblemOptions {
    ProblemOptions {
        compiler: Some(compiler),
        rhs: Rhs::Always,
        model_name: model.map(str::to_string),
        ..Default::default()
    }
}

fn is_refusal(err: &SimulateError) -> bool {
    matches!(
        err,
        SimulateError::Compile(CompileError::CompilerRefusedRule { .. })
    )
}

/// The first position where two vectors differ in their bits, if any.
fn first_bit_difference(a: &[f64], b: &[f64]) -> Option<(usize, f64, f64)> {
    if a.len() != b.len() {
        return Some((a.len().min(b.len()), f64::NAN, f64::NAN));
    }
    a.iter()
        .zip(b)
        .position(|(x, y)| x.to_bits() != y.to_bits())
        .map(|i| (i, a[i], b[i]))
}

/// Whether the scaling tier's Rust ledger expects native to refuse
/// (`family`, `n`): a `builds` entry for the family with no `n` or this `n`.
pub fn ledger_expects_refusal(family: &str, n: u64) -> bool {
    let manifest: Value = serde_json::from_str(SCALING_MANIFEST).expect("the manifest parses");
    manifest["ledger"]["rust"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|e| {
            e["gate"] == "builds"
                && e["family"] == family
                && e.get("compiler").is_none_or(|c| c == "native")
                && e.get("n")
                    .is_none_or(|v| v.is_null() || v.as_u64() == Some(n))
        })
}

/// Native and the interpreter give the same right-hand side, bit for bit, on
/// one scaling fixture; or native refuses it and the ledger says it does.
pub fn check_scaling_fixture(family: &str, n: u64, text: &str) {
    let doc: Value = serde_json::from_str(text).expect("the fixture parses");
    let interp = esm_problem(&doc, (0.0, 1.0), options(Compiler::Interpreter, None))
        .unwrap_or_else(|e| panic!("{family} N={n}: the interpreter does not build it: {e}"));
    let expected_refusal = ledger_expects_refusal(family, n);
    let native = match esm_problem(&doc, (0.0, 1.0), options(Compiler::Native, None)) {
        Ok(p) => p,
        Err(e) if is_refusal(&e) => {
            assert!(
                expected_refusal,
                "{family} N={n}: native refuses a document the Rust ledger does not list: {e}"
            );
            return;
        }
        Err(e) => panic!("{family} N={n}: native fails to build: {e}"),
    };
    assert!(
        !expected_refusal,
        "{family} N={n}: native builds it now; remove its `builds` entry from the Rust ledger"
    );
    let nc = native
        .debug_array_compiled()
        .expect("native has a right-hand side");
    let ic = interp
        .debug_array_compiled()
        .expect("the interpreter has a right-hand side");
    assert_eq!(
        nc.state_variable_names(),
        ic.state_variable_names(),
        "{family} N={n}: state order"
    );
    let state: Vec<f64> = (0..nc.state_variable_names().len())
        .map(|p| 1.0 + 0.1 * (0.37 * p as f64).sin())
        .collect();
    let params = nc.debug_resolve_params(native.p());
    let mut dy = vec![0.0f64; state.len()];
    let mut scratch = nc.debug_new_scratch_taped();
    let mut stats = RhsStats::default();
    nc.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    assert_eq!(
        stats.fallback_rules, 0,
        "{family} N={n}: a rule left the tape"
    );
    let (idy, _) = ic.debug_eval_rhs(&state, 0.0, interp.p(), true);
    if let Some((i, a, b)) = first_bit_difference(&dy, &idy) {
        panic!(
            "{family} N={n}: native dy differs from the interpreter's at {} ({a} vs {b})",
            nc.state_variable_names()[i]
        );
    }
}

/// The span and save times the document's own tests use for `model`.
fn test_times(doc: &Value, model: &str) -> (f64, f64, Vec<f64>) {
    let tests = doc["models"][model]["tests"]
        .as_array()
        .or_else(|| doc["reaction_systems"][model]["tests"].as_array());
    let (mut t0, mut t1) = (f64::INFINITY, f64::NEG_INFINITY);
    let mut times = Vec::new();
    for t in tests.into_iter().flatten() {
        if let (Some(a), Some(b)) = (
            t["time_span"]["start"].as_f64(),
            t["time_span"]["end"].as_f64(),
        ) {
            t0 = t0.min(a);
            t1 = t1.max(b);
        }
        for a in t["assertions"].as_array().into_iter().flatten() {
            if let Some(x) = a["time"].as_f64() {
                times.push(x);
            }
        }
    }
    if !t0.is_finite() || !t1.is_finite() {
        (t0, t1) = (0.0, 1.0);
    }
    times.push(t1);
    times.retain(|x| *x >= t0 && *x <= t1);
    times.sort_by(|a, b| a.total_cmp(b));
    times.dedup_by(|a, b| a.to_bits() == b.to_bits());
    (t0, t1, times)
}

/// Native and the interpreter agree bit for bit on one inline-test tier
/// document: its build-time fields, and, when it has a right-hand side, the
/// whole saved trajectory (states and the observeds saved beside them).
pub fn check_inline_tier_doc(id: &str, model: &str, text: &str) {
    let doc: Value = serde_json::from_str(text).expect("the document parses");
    let (t0, t1, saveat) = test_times(&doc, model);
    let mut probs = Vec::new();
    for c in [Compiler::Interpreter, Compiler::Native] {
        let rhs = Rhs::Auto;
        let opts = ProblemOptions {
            rhs,
            ..options(c, Some(model))
        };
        let p = esm_problem(&doc, (t0, t1), opts)
            .unwrap_or_else(|e| panic!("{id}: {} does not build it: {e}", c.as_str()));
        probs.push(p);
    }
    let (ip, np) = (&probs[0], &probs[1]);
    let mut names: Vec<&String> = ip.observed_fields().keys().collect();
    names.sort();
    let mut native_names: Vec<&String> = np.observed_fields().keys().collect();
    native_names.sort();
    assert_eq!(names, native_names, "{id}: build-time field names");
    for name in names {
        let a = ip.observed_fields()[name]
            .as_slice_memory_order()
            .map(<[f64]>::to_vec);
        let b = np.observed_fields()[name]
            .as_slice_memory_order()
            .map(<[f64]>::to_vec);
        let (a, b) = (
            a.unwrap_or_else(|| ip.observed_fields()[name].iter().copied().collect()),
            b.unwrap_or_else(|| np.observed_fields()[name].iter().copied().collect()),
        );
        if let Some((i, x, y)) = first_bit_difference(&a, &b) {
            panic!("{id}: build-time field {name}[{i}]: interpreter {x}, native {y}");
        }
    }
    assert_eq!(
        ip.is_dynamic(),
        np.is_dynamic(),
        "{id}: dynamic under one compiler only"
    );
    if !ip.is_dynamic() {
        return;
    }
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-10),
        abstol: Some(1e-12),
        saveat: Some(saveat),
        ..Default::default()
    };
    let is = solve(ip, &opts).unwrap_or_else(|e| panic!("{id}: interpreter solve: {e}"));
    let ns = solve(np, &opts).unwrap_or_else(|e| panic!("{id}: native solve: {e}"));
    assert_eq!(
        is.state_variable_names, ns.state_variable_names,
        "{id}: saved rows"
    );
    assert_eq!(is.time, ns.time, "{id}: save times");
    for (row, name) in is.state_variable_names.iter().enumerate() {
        if let Some((i, x, y)) = first_bit_difference(&is.state[row], &ns.state[row]) {
            panic!(
                "{id}: {name} at t = {}: interpreter {x}, native {y}",
                is.time[i]
            );
        }
    }
}
