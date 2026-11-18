//! A Problem's right-hand side evaluated through the public program
//! ([`rhs_program`], API_SPEC §5.8), read and written in the Problem's own
//! state order ([`EsmProblem::state_variable_names`]).
//!
//! The program lays its state out by variable in flat-layout order; the
//! Problem's state vector may order the variables differently. Each variable
//! is one column-major block in both, so the two are mapped block by block.
//!
//! Needs no filesystem, so it lives with the portable checks (which the wasm
//! suite also compiles); the integration suite reaches it as `common::rhs`.
#![allow(dead_code)]

use std::collections::HashMap;

use earthsci_ast::{EsmProblem, ForcingSet, RhsProgram, RhsWorkspace, rhs_program};

/// The variable part of a slot name: `M.u` of `M.u[2,3]`.
fn variable_of(slot: &str) -> &str {
    slot.split_once('[').map_or(slot, |(v, _)| v)
}

/// A slot name without its namespace: `u[2,3]` of `M.u[2,3]`, `g` of `M.g`.
/// For a single-model Problem, the spelling its compiled model's own slot
/// names use.
pub fn bare_slot(slot: &str) -> &str {
    let var = variable_of(slot);
    match var.rfind('.') {
        Some(k) => &slot[k + 1..],
        None => slot,
    }
}

/// Whether `a` and `b` name the same variable, one possibly carrying a
/// namespace prefix the other lacks.
fn same_variable(a: &str, b: &str) -> bool {
    a == b || a.ends_with(&format!(".{b}")) || b.ends_with(&format!(".{a}"))
}

/// A Problem's right-hand side through its public program, under the compiler
/// the Problem was built with.
pub struct ProblemRhs {
    prog: RhsProgram,
    ws: RhsWorkspace,
    p: Vec<f64>,
    forcing: ForcingSet,
    aux: Vec<f64>,
    /// Per variable: `(offset in the Problem's state, offset in the program's
    /// state, length)`.
    blocks: Vec<(usize, usize, usize)>,
    n: usize,
    u: Vec<f64>,
    du: Vec<f64>,
}

impl ProblemRhs {
    /// The program of `prob`, with the parameters `prob` was built with
    /// ([`EsmProblem::p`]) over the declared defaults, and its forcing.
    pub fn new(prob: &EsmProblem) -> ProblemRhs {
        Self::with_params(prob, prob.p())
    }

    /// [`Self::new`] with `params` in place of [`EsmProblem::p`]. A parameter
    /// neither `params` nor a default gives a value reads `0.0`.
    pub fn with_params(prob: &EsmProblem, params: &HashMap<String, f64>) -> ProblemRhs {
        let prog = rhs_program(prob).unwrap_or_else(|e| panic!("rhs_program: {e}"));
        let names = prob.state_variable_names();
        let mut blocks = Vec::new();
        for b in prog.state_layout() {
            let len = b.shape.iter().product::<usize>().max(1);
            let at = names
                .iter()
                .position(|n| variable_of(n) == b.name)
                .or_else(|| {
                    names
                        .iter()
                        .position(|n| same_variable(variable_of(n), &b.name))
                })
                .unwrap_or_else(|| panic!("the Problem has no state for `{}`", b.name));
            blocks.push((at, b.flat_offset, len));
        }
        assert_eq!(
            prog.n_states(),
            names.len(),
            "the program and the Problem hold different state counts"
        );
        let ws = prog.new_workspace();
        let forcing = prog.default_forcing();
        let aux = prog.default_state().1;
        let n = names.len();
        let mut rhs = ProblemRhs {
            p: Vec::new(),
            prog,
            ws,
            forcing,
            aux,
            blocks,
            n,
            u: vec![0.0; n],
            du: vec![0.0; n],
        };
        rhs.set_params(params);
        rhs
    }

    /// Replace the parameter vector: `params` over the declared defaults
    /// (matched by flattened or bare name), `0.0` where neither gives one.
    pub fn set_params(&mut self, params: &HashMap<String, f64>) {
        self.p = self
            .prog
            .parameters()
            .iter()
            .map(|slot| {
                params
                    .get(&slot.name)
                    .or_else(|| {
                        params
                            .iter()
                            .find(|(k, _)| same_variable(&slot.name, k))
                            .map(|(_, v)| v)
                    })
                    .copied()
                    .or(slot.default)
                    .unwrap_or(0.0)
            })
            .collect();
    }

    /// The program behind this right-hand side.
    pub fn program(&self) -> &RhsProgram {
        &self.prog
    }

    /// The parameter vector the calls use.
    pub fn params(&self) -> &[f64] {
        &self.p
    }

    /// The length of the state vector.
    pub fn n_states(&self) -> usize {
        self.n
    }

    /// `dy = f(state, t)` with `state` and `dy` in the Problem's state order.
    pub fn eval_into(&mut self, state: &[f64], t: f64, dy: &mut [f64]) {
        assert_eq!(state.len(), self.n, "state length");
        assert_eq!(dy.len(), self.n, "dy length");
        for &(at, off, len) in &self.blocks {
            self.u[off..off + len].copy_from_slice(&state[at..at + len]);
        }
        self.prog
            .eval_into(
                &self.u,
                &self.aux,
                &self.p,
                t,
                &self.forcing,
                &mut self.du,
                &mut self.ws,
            )
            .unwrap_or_else(|e| panic!("eval_into: {e}"));
        for &(at, off, len) in &self.blocks {
            dy[at..at + len].copy_from_slice(&self.du[off..off + len]);
        }
    }

    /// [`Self::eval_into`] into a fresh vector.
    pub fn eval(&mut self, state: &[f64], t: f64) -> Vec<f64> {
        let mut dy = vec![0.0; self.n];
        self.eval_into(state, t, &mut dy);
        dy
    }
}
