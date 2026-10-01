//! `native` against `interpreter` on the corpus documents whose right-hand
//! side reads the forcing buffer: data-fed and handler-fed parameters, bound
//! through `ProblemOptions::providers` and read by the tape as forcing loads.
//!
//! Each document is built under both compilers with the same scripted
//! providers and solved over the same output grid; the trajectories must be
//! identical bit for bit, and under `native` every rule must be on the tape.
//! A DISCRETE provider (one with refresh times) segments the solve, so the
//! refresh path is exercised too.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_ast::{Compiler, ProblemOptions, SolveOptions, esm_problem, solve};
use ndarray::{ArrayD, IxDyn};
use std::collections::HashMap;
use std::path::Path;

mod common;

/// A provider feeding one variable a deterministic field: once, for a CONST
/// provider (no anchors), or at each anchor, for a DISCRETE one.
struct Scripted {
    key: String,
    shape: Vec<usize>,
    anchors: Vec<f64>,
    base: f64,
}

impl Scripted {
    fn field(&self, t: f64) -> HashMap<String, NativeField> {
        let n: usize = self.shape.iter().product();
        let values: Vec<f64> = (0..n.max(1))
            .map(|i| self.base * (1.0 + 0.25 * i as f64) * (1.0 + t))
            .collect();
        let values = if self.shape.is_empty() {
            values[..1].to_vec()
        } else {
            values[..n].to_vec()
        };
        let array = ArrayD::from_shape_vec(IxDyn(&self.shape), values).expect("scripted field");
        HashMap::from([(self.key.clone(), NativeField::new(array))])
    }
}

impl CadenceProvider for Scripted {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        Ok(self.field(0.0))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(self.anchors.contains(&t).then(|| self.field(t)))
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.anchors.clone()
    }
}

/// `(key, shape, anchors, base)` per forcing the document reads.
type Feed<'a> = (&'a str, &'a [usize], &'a [f64], f64);

fn solve_under(
    path: &Path,
    compiler: Compiler,
    feeds: &[Feed<'_>],
    u0: &HashMap<String, f64>,
    tspan: (f64, f64),
    saveat: &[f64],
) -> earthsci_ast::Solution {
    let providers: HashMap<String, Box<dyn CadenceProvider>> = feeds
        .iter()
        .map(|&(key, shape, anchors, base)| {
            (
                key.to_string(),
                Box::new(Scripted {
                    key: key.to_string(),
                    shape: shape.to_vec(),
                    anchors: anchors.to_vec(),
                    base,
                }) as Box<dyn CadenceProvider>,
            )
        })
        .collect();
    let prob = esm_problem(
        path,
        tspan,
        ProblemOptions {
            compiler: Some(compiler),
            providers,
            u0: u0.clone(),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{} [{compiler}]: {e}", path.display()));
    if compiler == Compiler::Native {
        let report = prob.compiler_report();
        assert_eq!(
            report.n_oracle(),
            0,
            "{}: every rule is taped under native: {:?}",
            path.display(),
            report.rules()
        );
        assert!(report.n_taped() > 0, "{}", path.display());
    }
    solve(
        &prob,
        &SolveOptions {
            saveat: Some(saveat.to_vec()),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{} [{compiler}] solve: {e}", path.display()))
}

fn agree(rel: &str, feeds: &[Feed<'_>], u0: &[(&str, f64)], tspan: (f64, f64), saveat: &[f64]) {
    let path = common::repo_fixture(rel);
    let u0: HashMap<String, f64> = u0.iter().map(|&(k, v)| (k.to_string(), v)).collect();
    let want = solve_under(&path, Compiler::Interpreter, feeds, &u0, tspan, saveat);
    let got = solve_under(&path, Compiler::Native, feeds, &u0, tspan, saveat);
    assert_eq!(got.state_variable_names, want.state_variable_names, "{rel}");
    assert_eq!(got.time, want.time, "{rel}");
    for (name, (g, w)) in got
        .state_variable_names
        .iter()
        .zip(got.state.iter().zip(&want.state))
    {
        for (k, (a, b)) in g.iter().zip(w).enumerate() {
            assert_eq!(
                a.to_bits(),
                b.to_bits(),
                "{rel}: {name} at t = {}: native {a:e} vs interpreter {b:e}",
                got.time[k]
            );
        }
    }
    assert!(
        earthsci_ast::simulate_array::take_const_array_oob().is_none(),
        "{rel}: no fault"
    );
}

fn cells(var: &str, n: usize, v: f64) -> Vec<(String, f64)> {
    (1..=n)
        .map(|i| (format!("{var}[{i}]"), v * i as f64))
        .collect()
}

fn u0_of(v: &[(String, f64)]) -> Vec<(&str, f64)> {
    v.iter().map(|(k, x)| (k.as_str(), *x)).collect()
}

#[test]
fn a_const_loader_field_agrees() {
    let c = cells("c", 4, 0.1);
    agree(
        "valid/cadence/loader_const_seed.esm",
        &[("bc", &[4], &[], 0.8)],
        &u0_of(&c),
        (0.0, 2.0),
        &[0.5, 1.0, 2.0],
    );
}

#[test]
fn a_temporal_loader_field_refreshes_and_agrees() {
    let c = cells("c", 4, 0.1);
    agree(
        "valid/cadence/loader_temporal_seed.esm",
        &[("bc", &[4], &[0.0, 0.5, 1.5], 0.8)],
        &u0_of(&c),
        (0.0, 2.0),
        &[0.25, 0.5, 1.0, 1.5, 2.0],
    );
}

#[test]
fn a_scalar_loader_field_in_a_subsystem_document_agrees() {
    agree(
        "conformance/subsystem_loader/fixtures/subsystem_loader_ode.esm",
        &[("k", &[], &[], 0.4), ("wind", &[3], &[], 1.5)],
        &[],
        (0.0, 1.0),
        &[0.5, 1.0],
    );
}

#[test]
fn a_handler_fed_scalar_read_by_an_observed_agrees() {
    let u = cells("u", 4, 0.3);
    agree(
        "valid/cadence/observed_leaf_seeds.esm",
        &[("Kdiff", &[], &[0.0, 0.5], 0.9)],
        &u0_of(&u),
        (0.0, 1.0),
        &[0.25, 0.5, 1.0],
    );
}

#[test]
fn photolysis_rates_from_a_loader_agree() {
    agree(
        "valid/reaction_system_only.esm",
        &[
            ("PureChemistry.jO3", &[], &[], 1e-5),
            ("PureChemistry.jNO2", &[], &[], 5e-3),
            ("PureChemistry.jNO3", &[], &[], 2e-3),
            ("PureChemistry.jH2O2", &[], &[], 1e-6),
        ],
        &[],
        (0.0, 10.0),
        &[5.0, 10.0],
    );
}

/// The forcing shapes here name index sets the document never declares, so
/// the build sizes each read from how the equations index it; the DISCRETE
/// field is not in the buffer until the solve's first refresh.
#[test]
fn forcings_sized_from_their_uses_agree() {
    agree(
        "conformance/refresh/fixtures/coupled_refresh_regrid.esm",
        &[
            ("F_src", &[6], &[0.0, 1.0, 2.0], 0.6),
            ("scale_src", &[6], &[], 1.3),
        ],
        &[],
        (0.0, 3.0),
        &[0.5, 1.0, 1.5, 2.0, 3.0],
    );
    agree(
        "conformance/discrete_materialize/fixtures/discrete_materialize_contraction.esm",
        &[("src", &[2], &[0.0, 1.0, 2.0], 0.7)],
        &[],
        (0.0, 3.0),
        &[1.0, 2.0, 3.0],
    );
}
