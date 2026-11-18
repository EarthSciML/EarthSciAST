//! The right-hand side a solve integrates, evaluated outside a solve, and the
//! tape it runs: the one door measurement and inspection tooling outside the
//! crate has into a compiled model.
//!
//! The public route to a right-hand side is [`crate::rhs_program`] (API_SPEC
//! §5.8). It runs on the calling thread, in its own layout, on a forcing set
//! it is handed. A few out-of-crate callers need the solve's own evaluation
//! instead: the scaling tier's adapter times the threaded call a solve makes;
//! the forcing and program conformance tests compare the program against the
//! solve's evaluation reading the forcing buffer in place; the
//! closed-template benchmark and `examples/tape_report.rs` print the tape.
//! Hidden from rustdoc and outside the API manifest.

use std::collections::HashMap;
use std::rc::Rc;

use super::tape::TapeBuildReport;
use super::{ArrayCompiled, RhsScratch, RhsStats, RuntimeMode};
use crate::simulate::SimulateError;

/// One compiled model's right-hand side with its scratch and parameter
/// vector, evaluated in the model's own state order
/// ([`ArrayCompiled::state_variable_names`]) as a solve evaluates it.
#[doc(hidden)]
pub struct SolveRhs {
    model: Rc<ArrayCompiled>,
    scratch: RhsScratch,
    params: Vec<f64>,
}

impl std::fmt::Debug for SolveRhs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SolveRhs")
            .field("n_states", &self.model.n_states())
            .field("taped", &self.scratch.has_tape())
            .finish()
    }
}

impl SolveRhs {
    /// `model`'s right-hand side under the compiler it was built for: the
    /// strict tape under `native` and `xla` (the tape the XLA executable is
    /// emitted from), the per-cell oracle under `interpreter`. `params` is
    /// matched as a solve matches parameter keys (esm-spec §6.6.2) over the
    /// declared defaults, leniently: a key that designates no parameter is
    /// ignored. Under a tape compiler a model whose tape declines a rule is
    /// the refusal a solve raises.
    pub fn new(
        model: Rc<ArrayCompiled>,
        params: &HashMap<String, f64>,
    ) -> Result<SolveRhs, SimulateError> {
        let mut scratch = model.new_scratch();
        if model.runtime_mode != RuntimeMode::Interpreter {
            scratch.install_tape(model.strict_tape(&Default::default())?);
        }
        Ok(Self::with_scratch(model, params, scratch))
    }

    /// `model`'s right-hand side through the per-cell oracle, whatever
    /// compiler it was built for: the reference the compilers are checked
    /// against.
    pub fn oracle(model: Rc<ArrayCompiled>, params: &HashMap<String, f64>) -> SolveRhs {
        let scratch = model.new_scratch();
        Self::with_scratch(model, params, scratch)
    }

    /// The per-cell oracle over this handle's model, with its parameter
    /// vector.
    pub fn to_oracle(&self) -> SolveRhs {
        SolveRhs {
            model: Rc::clone(&self.model),
            scratch: self.model.new_scratch(),
            params: self.params.clone(),
        }
    }

    fn with_scratch(
        model: Rc<ArrayCompiled>,
        params: &HashMap<String, f64>,
        scratch: RhsScratch,
    ) -> SolveRhs {
        let params = model.debug_resolve_params(params);
        SolveRhs {
            model,
            scratch,
            params,
        }
    }

    /// The compiled model behind this right-hand side.
    pub fn model(&self) -> &ArrayCompiled {
        &self.model
    }

    /// The model's state slot names, in the order `state` and `dy` use.
    pub fn state_variable_names(&self) -> &[String] {
        self.model.state_variable_names()
    }

    /// The length of the state vector.
    pub fn n_states(&self) -> usize {
        self.model.n_states()
    }

    /// The positional parameter vector the calls use, in
    /// [`ArrayCompiled::parameter_names`] order: what
    /// `crate::xla_runtime::CompiledRhs` takes.
    pub fn params(&self) -> &[f64] {
        &self.params
    }

    /// Replace the parameter vector, resolving `params` as [`Self::new`]
    /// does.
    pub fn set_params(&mut self, params: &HashMap<String, f64>) {
        self.params = self.model.debug_resolve_params(params);
    }

    /// `dy = f(state, t)`, reading the model's forcing buffer
    /// ([`ArrayCompiled::forcing_handle`]) as it stands, under the precision
    /// the model was compiled under. On a tape this is the call a solve
    /// makes, threads included, and a warm call allocates nothing.
    pub fn eval_into(&mut self, state: &[f64], t: f64, dy: &mut [f64]) {
        let _precision = self.model.precision.enter();
        self.model.debug_eval_rhs_into(
            state,
            t,
            &self.params,
            dy,
            &mut self.scratch,
            &mut RhsStats::default(),
        );
    }

    /// [`Self::eval_into`] into a fresh vector.
    pub fn eval(&mut self, state: &[f64], t: f64) -> Vec<f64> {
        let mut dy = vec![0.0; self.n_states()];
        self.eval_into(state, t, &mut dy);
        dy
    }

    /// The report of the model's tape build: instruction counts by section,
    /// storage, fusion, and the rules it declined. Built for any model,
    /// whichever evaluator this handle runs.
    pub fn tape_report(&self) -> TapeBuildReport {
        self.model.debug_build_tape_report()
    }

    /// The model's tape as text: one instruction per line with its section
    /// and the box it defines, then the fused and lane groups. Diagnostics
    /// only; the format is not stable.
    pub fn tape_listing(&self) -> String {
        self.model.debug_tape_listing()
    }

    /// The fused program's per-group shape statistics and the fusion pass's
    /// histograms, as text. Diagnostics only; the format is not stable.
    pub fn fuse_stats(&self) -> String {
        self.model.debug_fuse_stats()
    }
}
