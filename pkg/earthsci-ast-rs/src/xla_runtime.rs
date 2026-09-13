//! PJRT runtime for the compiled right-hand side (feature `xla`).
//!
//! [`crate::simulate_array::tape::xla_emit`] turns a model's tape into an
//! `rhs(u, p, t) -> du` XLA computation; this module compiles that computation
//! for a device and runs it.
//!
//! ```no_run
//! # use earthsci_ast::simulate_array::ArrayCompiled;
//! # fn demo(model: &ArrayCompiled) -> Result<(), Box<dyn std::error::Error>> {
//! let rhs = earthsci_ast::xla_runtime::CompiledRhs::compile(model)?;  // once per model
//! let du = rhs.eval(&state, &params, 0.0)?;                           // per probe / step
//! # Ok(()) }
//! ```
//!
//! ## What is cached and why
//!
//! * **The client** is a process-wide singleton ([`client`]). Creating a PJRT
//!   client spins up the device runtime and its thread pools; one per model
//!   would be both slow and wasteful, and `PjRtClient` is `Clone` over an
//!   `Arc` precisely so it can be shared.
//! * **The executable** is cached by holding it: a [`CompiledRhs`] IS the
//!   per-model cache. XLA compilation is the expensive step (seconds for a
//!   large stencil program, against microseconds per execution), so a caller
//!   that evaluates many states — the conformance adapter over a fixture's
//!   probes, a solver over its steps — must build one [`CompiledRhs`] and keep
//!   it. Nothing here re-compiles per call.
//!
//! ## Device selection
//!
//! CPU by default. `EARTHSCI_XLA_PLATFORM=gpu` asks for a GPU client instead
//! (`EARTHSCI_XLA_GPU_MEMORY_FRACTION`, default 0.75, and
//! `EARTHSCI_XLA_GPU_PREALLOCATE=1` tune it). The GPU path is **untested**:
//! it needs a CUDA `xla_extension` build and a device, neither of which the
//! development machine has. It is wired up rather than left out so that
//! trying it is a matter of one environment variable and one extension
//! download, and so that its failure is a clear `unavailable` reason.

use std::sync::OnceLock;

use xla::{Literal, PjRtClient, PjRtLoadedExecutable};

use crate::simulate_array::ArrayCompiled;
use crate::simulate_array::tape::xla_emit::{self, EmittedRhs, XlaEmitError};

/// Why a model has no compiled right-hand side.
///
/// The two arms are the tier's two different outcomes and must not be
/// collapsed: a [`Self::Refused`] says THIS MODEL cannot be lowered (the
/// binding is fine, the fixture is excluded by name), a [`Self::Runtime`] says
/// the XLA runtime is not usable at all on this machine (the whole engine is
/// unavailable and no fixture says anything about coverage).
#[derive(Debug)]
pub enum CompileRhsError {
    /// The emitter cannot lower this model. Carries the rule and the reason.
    Refused(XlaEmitError),
    /// The XLA runtime is missing, unloadable, or failed on us.
    Runtime(String),
}

impl std::fmt::Display for CompileRhsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CompileRhsError::Refused(e) => write!(f, "refused: {e}"),
            CompileRhsError::Runtime(m) => write!(f, "xla runtime: {m}"),
        }
    }
}

impl std::error::Error for CompileRhsError {}

impl From<XlaEmitError> for CompileRhsError {
    fn from(e: XlaEmitError) -> Self {
        CompileRhsError::Refused(e)
    }
}

/// The process-wide PJRT client, created on first use.
///
/// A failure is cached too: if the extension will not load once it will not
/// load the second time either, and retrying per fixture would turn one clear
/// message into nineteen.
pub fn client() -> Result<&'static PjRtClient, String> {
    static CLIENT: OnceLock<Result<PjRtClient, String>> = OnceLock::new();
    CLIENT
        .get_or_init(|| match std::env::var("EARTHSCI_XLA_PLATFORM").as_deref() {
            Ok("gpu") | Ok("cuda") => {
                let frac = std::env::var("EARTHSCI_XLA_GPU_MEMORY_FRACTION")
                    .ok()
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or(0.75);
                let prealloc = std::env::var("EARTHSCI_XLA_GPU_PREALLOCATE")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false);
                PjRtClient::gpu(frac, prealloc).map_err(|e| {
                    format!(
                        "PjRtClient::gpu failed ({e}); a GPU client needs a CUDA \
                         xla_extension build and a visible device"
                    )
                })
            }
            Ok(other) => Err(format!(
                "EARTHSCI_XLA_PLATFORM={other:?} is not a platform this build knows \
                 (want cpu|gpu)"
            )),
            Err(_) => PjRtClient::cpu().map_err(|e| format!("PjRtClient::cpu failed: {e}")),
        })
        .as_ref()
        .map_err(|e| e.clone())
}

/// A compiled, ready-to-run right-hand side for one model.
pub struct CompiledRhs {
    exe: PjRtLoadedExecutable,
    n_states: usize,
    params_len: usize,
    n_instrs: usize,
    platform: String,
}

impl CompiledRhs {
    /// Emit and compile `model`'s right-hand side. Do this ONCE per model.
    pub fn compile(model: &ArrayCompiled) -> Result<Self, CompileRhsError> {
        let emitted = xla_emit::emit_rhs(model)?;
        Self::from_emitted(emitted)
    }

    /// Compile an already-emitted computation (the seam a test uses when it
    /// wants the HLO as well as the numbers).
    pub fn from_emitted(emitted: EmittedRhs) -> Result<Self, CompileRhsError> {
        let client = client().map_err(CompileRhsError::Runtime)?;
        let exe = client
            .compile(emitted.computation())
            .map_err(|e| CompileRhsError::Runtime(format!("XLA compilation failed: {e}")))?;
        Ok(CompiledRhs {
            exe,
            n_states: emitted.n_states(),
            params_len: emitted.params_len(),
            n_instrs: emitted.n_instrs(),
            platform: client.platform_name(),
        })
    }

    /// Flat state length, which is also the length of the result.
    pub fn n_states(&self) -> usize {
        self.n_states
    }
    /// Declared length of the positional parameter vector.
    pub fn params_len(&self) -> usize {
        self.params_len
    }
    /// Tape instructions lowered (diagnostics only).
    pub fn n_instrs(&self) -> usize {
        self.n_instrs
    }
    /// PJRT platform name (`"cpu"`, `"cuda"`, …).
    pub fn platform(&self) -> &str {
        &self.platform
    }

    /// Evaluate `f(state, params, t)`.
    ///
    /// `params` is the POSITIONAL parameter vector, i.e. what
    /// `ArrayCompiled::debug_resolve_params` returns — not a name map. A
    /// shorter slice is zero-extended and a longer one is an error, because
    /// silently ignoring a trailing parameter would evaluate a different
    /// model than the caller asked for.
    pub fn eval(&self, state: &[f64], params: &[f64], t: f64) -> Result<Vec<f64>, CompileRhsError> {
        if state.len() != self.n_states {
            return Err(CompileRhsError::Runtime(format!(
                "state has {} elements, the compiled program takes {}",
                state.len(),
                self.n_states
            )));
        }
        if params.len() > self.params_len {
            return Err(CompileRhsError::Runtime(format!(
                "parameter vector has {} elements, the compiled program takes {}",
                params.len(),
                self.params_len
            )));
        }
        let mut pv = vec![0.0f64; self.params_len];
        pv[..params.len()].copy_from_slice(params);
        let args = [Literal::vec1(state), Literal::vec1(&pv), Literal::scalar(t)];
        let out = self
            .exe
            .execute::<Literal>(&args)
            .map_err(|e| CompileRhsError::Runtime(format!("execute failed: {e}")))?;
        let buf = out
            .first()
            .and_then(|replica| replica.first())
            .ok_or_else(|| CompileRhsError::Runtime("execute returned no buffer".into()))?;
        let du = buf
            .to_literal_sync()
            .and_then(|l| l.to_vec::<f64>())
            .map_err(|e| CompileRhsError::Runtime(format!("copy back failed: {e}")))?;
        if du.len() != self.n_states {
            return Err(CompileRhsError::Runtime(format!(
                "compiled program returned {} elements, expected {}",
                du.len(),
                self.n_states
            )));
        }
        Ok(du)
    }
}
