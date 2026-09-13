//! PJRT runtime for the compiled right-hand side (feature `xla`).
//!
//! [`crate::simulate_array::tape::xla_emit`] turns a model's tape into an
//! `rhs(u, p, t) -> du` XLA computation; this module compiles that computation
//! for a device and runs it.
//!
//! ```no_run
//! # use earthsci_ast::simulate_array::ArrayCompiled;
//! # fn demo(model: &ArrayCompiled) -> Result<(), Box<dyn std::error::Error>> {
//! # let state: Vec<f64> = Vec::new();
//! # let params: Vec<f64> = Vec::new();
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
//! `EARTHSCI_XLA_GPU_PREALLOCATE=1` tune it).
//!
//! The GPU path needs TWO things beyond the CPU one, and they fail in
//! different places:
//!
//! * a CUDA `xla_extension` build (`scripts/fetch-xla-extension.sh --variant
//!   cuda12`). With the CPU build, `EARTHSCI_XLA_PLATFORM=gpu` reaches
//!   [`client`] and fails there, with the message this module composes;
//! * the CUDA shared libraries the CUDA build HARD-LINKS -- cuDNN, NCCL,
//!   nvshmem, cuBLAS, cuFFT, cuSPARSE, nvJitLink, the CUDA runtime and NVRTC.
//!   Those are `DT_NEEDED` entries, so a missing one is a *dynamic loader*
//!   failure before `main` runs: no Rust code here ever sees it, and the
//!   symptom is `error while loading shared libraries: libcudnn.so.9`.
//!   `scripts/setup-xla-gpu-libs.sh` builds a directory that satisfies all of
//!   them and prints the `LD_LIBRARY_PATH` and `XLA_FLAGS` lines to export.
//!
//! ## Host round trip against device residency
//!
//! [`CompiledRhs::eval`] is the simple form: host state in, host derivative
//! out, one transfer each way per call. [`DeviceRhs`] is the form for a caller
//! that steps in time -- state and parameters are uploaded once and stay in
//! device memory, each evaluation consumes those device buffers and leaves its
//! result in device memory, and the host sees numbers only when it asks
//! ([`DeviceRhs::du_to_host`]). [`DeviceRhs::euler_step`] closes the loop
//! without a transfer at all: it feeds the resident derivative back into the
//! resident state through a second tiny compiled program.

//! ## Multi-device, and why there is none
//!
//! Sharding a model's state across several devices is not reachable through
//! `xla` 0.4.4. The gap is in the crate's C++ shim (`xla_rs/xla_rs.cc`), not
//! in XLA, and it is three specific omissions:
//!
//! 1. **Compile options.** `status compile(...)` writes `CompileOptions
//!    options;` and passes it straight to `CompileAndLoad`, so every
//!    executable gets `num_replicas = 1`, `num_partitions = 1`,
//!    `use_spmd_partitioning = false`, and the default device assignment. A
//!    variant taking those four would need
//!    `options.executable_build_options.set_num_replicas`,
//!    `.set_num_partitions`, `.set_use_spmd_partitioning`, and
//!    `.set_device_assignment(client->GetDefaultDeviceAssignment(r, p))` —
//!    plus `.set_device_ordinal(k)` for the simpler "one single-device
//!    executable per device" shape.
//! 2. **Execution with one argument group per replica.** `execute` and
//!    `execute_b` both call `exe->Execute({input_buffer_ptrs}, options)`. The
//!    braces are the problem: that is ONE group. A replicated or partitioned
//!    executable takes `std::vector<std::vector<PjRtBuffer*>>`, one inner
//!    vector per replica. The output-unpacking code beneath already walks the
//!    replica-major nesting, so only the input side and one more C signature
//!    change. `ExecuteSharded(args, device, options)` would cover the
//!    per-device dispatch shape.
//! 3. **Sharding annotations.** `xla::XlaBuilder::SetSharding(const
//!    OpSharding&)` / `ClearSharding()` are not wrapped, and neither is
//!    `OpSharding` itself. Emitting a tiled sharding needs a constructor for
//!    the proto (`type = OTHER`, `tile_assignment_dimensions`,
//!    `tile_assignment_devices`) and a builder-scoped setter, so the emitter
//!    can annotate the state parameter and let SPMD partitioning do the rest.
//!
//! That is on the order of two hundred lines of C++ in the shim plus about a
//! hundred of Rust binding, in a third-party crate — a fork or an upstream
//! patch, not a local change. Until it exists, work that is genuinely
//! independent (separate models, separate probe sets) can be spread over
//! devices with one PROCESS per device and `CUDA_VISIBLE_DEVICES`; work that
//! needs one state split across devices cannot be expressed at all.
//!
use std::sync::OnceLock;

use xla::{ArrayElement, Literal, PjRtBuffer, PjRtClient, PjRtLoadedExecutable, XlaBuilder};

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
                PjRtClient::gpu(frac, prealloc)
                    .map_err(|e| format!("PjRtClient::gpu failed ({e}).\n{}", gpu_setup_hint()))
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

/// What to tell somebody whose GPU client would not start.
///
/// The two failures look the same from here and have different fixes, so the
/// message says which one this machine looks like it has. The CUDA build ships
/// CUDA headers the CPU build does not, so the presence of
/// `include/_virtual_includes/cuda_headers` under `XLA_EXTENSION_DIR`
/// distinguishes them. That is a heuristic on a build-time variable -- the
/// library itself is found at run time through the rpath `build.rs` baked, so
/// `XLA_EXTENSION_DIR` may be unset or may have moved on since the build --
/// which is why it only chooses the *wording*, never whether to report.
fn gpu_setup_hint() -> String {
    let mut out = String::new();
    match std::env::var_os("XLA_EXTENSION_DIR") {
        Some(dir) => {
            let dir = std::path::PathBuf::from(dir);
            let cuda_build = dir.join("include/_virtual_includes/cuda_headers").is_dir();
            if cuda_build {
                out.push_str(&format!(
                    "The extension at {} is a CUDA build, so this is most likely no \
                     visible device: check that the job asked for one (nvidia-smi, \
                     CUDA_VISIBLE_DEVICES).\n",
                    dir.display()
                ));
            } else {
                out.push_str(&format!(
                    "The extension at {} looks like the CPU build (it has no CUDA \
                     headers), which has no GPU backend compiled in. Fetch the CUDA \
                     one and rebuild against it:\n  \
                     scripts/fetch-xla-extension.sh --variant cuda12 --dest <dir outside the repo>\n  \
                     export XLA_EXTENSION_DIR=<that dir>/xla_extension-<version>-cuda12/xla_extension\n  \
                     cargo build --features xla ...      # the rpath is baked at build time\n",
                    dir.display()
                ));
            }
        }
        None => out.push_str(
            "XLA_EXTENSION_DIR is unset here, so this process is running against \
             whatever extension was baked into its rpath at build time; if that was \
             the CPU build there is no GPU backend to start.\n",
        ),
    }
    out.push_str(
        "The CUDA extension also HARD-LINKS cuDNN, NCCL, nvshmem, cuBLAS, cuFFT, \
         cuSPARSE, nvJitLink, the CUDA runtime and NVRTC, and needs ptxas through \
         XLA_FLAGS=--xla_gpu_cuda_data_dir=... Build that environment with\n  \
         scripts/setup-xla-gpu-libs.sh --prefix <dir outside the repo>\n\
         and export the lines it prints. (A library missing outright does not reach \
         this message at all: it is a dynamic-loader failure before main, reading \
         \"error while loading shared libraries\".)",
    );
    out
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
        let pv = self.check_and_pad(state, params)?;
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

impl CompiledRhs {
    /// Run the compiled program against three buffers the CALLER placed, and
    /// copy the result back.
    ///
    /// A diagnostic seam, not a hot path: [`DeviceRhs`] is the supported way
    /// to keep state resident. This exists so a probe can ask what happens
    /// when the arguments live on a device the executable was not compiled
    /// for — the question multi-device support turns on, and one whose answer
    /// is a runtime error message rather than a documented rule.
    pub fn execute_on_buffers(
        &self,
        u: &PjRtBuffer,
        p: &PjRtBuffer,
        t: &PjRtBuffer,
    ) -> Result<Vec<f64>, CompileRhsError> {
        let out = self
            .exe
            .execute_b(&[u, p, t])
            .map_err(|e| CompileRhsError::Runtime(format!("execute failed: {e}")))?;
        let buf = take_single_output(out, "rhs")?;
        let mut host = vec![0.0f64; self.n_states];
        buf.copy_raw_to_host_sync(&mut host, 0)
            .map_err(|e| CompileRhsError::Runtime(format!("copy back failed: {e}")))?;
        Ok(host)
    }
}

/// A right-hand side whose state and parameters LIVE ON THE DEVICE between
/// calls.
///
/// [`CompiledRhs::eval`] is a pure function of host data: it uploads `u` and
/// `p`, runs, and downloads `du`. That is the right shape for the conformance
/// tier, which evaluates a handful of unrelated probe states. It is the wrong
/// shape for a solver, which evaluates a state it just produced: there the two
/// transfers per call move the same numbers off the device and straight back
/// on, and on a GPU that round trip can cost more than the arithmetic.
///
/// `DeviceRhs` splits the transfer from the evaluation. `u` and `p` are
/// uploaded once, [`eval_at`](Self::eval_at) runs on the buffers already
/// there and leaves its result in device memory, and the host gets numbers
/// only when it asks for them with [`du_to_host`](Self::du_to_host).
/// [`euler_step`](Self::euler_step) closes the loop entirely on the device by
/// feeding the resident derivative back into the resident state.
///
/// `t` is re-uploaded every call. It is one scalar; keeping it resident would
/// save eight bytes and cost an extra compiled program to increment it.
///
/// The borrow is deliberate: the executable is the expensive object and there
/// must be exactly one of it per model, so a `DeviceRhs` is a *view* on a
/// [`CompiledRhs`] the caller keeps.
pub struct DeviceRhs<'a> {
    rhs: &'a CompiledRhs,
    u: PjRtBuffer,
    p: PjRtBuffer,
    /// Result of the most recent [`eval_at`](Self::eval_at), still on the
    /// device. `None` before the first evaluation.
    du: Option<PjRtBuffer>,
    /// `u <- u + dt * du`, compiled on first use. Most callers never step.
    stepper: Option<PjRtLoadedExecutable>,
}

impl CompiledRhs {
    /// Upload `state` and `params` and return a device-resident evaluator.
    ///
    /// See [`DeviceRhs`] for when this is worth it over [`Self::eval`].
    pub fn on_device<'a>(
        &'a self,
        state: &[f64],
        params: &[f64],
    ) -> Result<DeviceRhs<'a>, CompileRhsError> {
        let pv = self.check_and_pad(state, params)?;
        let client = client().map_err(CompileRhsError::Runtime)?;
        let u = client
            .buffer_from_host_buffer(state, &[self.n_states], None)
            .map_err(|e| CompileRhsError::Runtime(format!("upload of u failed: {e}")))?;
        let p = client
            .buffer_from_host_buffer(&pv, &[self.params_len], None)
            .map_err(|e| CompileRhsError::Runtime(format!("upload of p failed: {e}")))?;
        Ok(DeviceRhs { rhs: self, u, p, du: None, stepper: None })
    }

    /// Shared argument checking: the length rules are the same whether the
    /// arguments arrive as literals or as device buffers, and a second copy of
    /// them would be a second place to get them wrong.
    fn check_and_pad(&self, state: &[f64], params: &[f64]) -> Result<Vec<f64>, CompileRhsError> {
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
        Ok(pv)
    }
}

impl DeviceRhs<'_> {
    /// Flat state length, which is also the length of the derivative.
    pub fn n_states(&self) -> usize {
        self.rhs.n_states
    }

    /// Replace the resident state from the host. This IS a transfer; a caller
    /// in a time loop uses [`euler_step`](Self::euler_step) instead.
    pub fn set_state(&mut self, state: &[f64]) -> Result<(), CompileRhsError> {
        if state.len() != self.rhs.n_states {
            return Err(CompileRhsError::Runtime(format!(
                "state has {} elements, the compiled program takes {}",
                state.len(),
                self.rhs.n_states
            )));
        }
        let client = client().map_err(CompileRhsError::Runtime)?;
        self.u = client
            .buffer_from_host_buffer(state, &[self.rhs.n_states], None)
            .map_err(|e| CompileRhsError::Runtime(format!("upload of u failed: {e}")))?;
        Ok(())
    }

    /// Evaluate at `t` against the resident state and parameters. Nothing
    /// crosses to the host: the derivative stays in device memory, replacing
    /// whatever the previous call left there.
    pub fn eval_at(&mut self, t: f64) -> Result<(), CompileRhsError> {
        let client = client().map_err(CompileRhsError::Runtime)?;
        // `t` is a scalar; a fresh 8-byte upload per call is cheaper than the
        // machinery to keep and advance it on the device.
        let tb = client
            .buffer_from_host_buffer(&[t], &[], None)
            .map_err(|e| CompileRhsError::Runtime(format!("upload of t failed: {e}")))?;
        let out = self
            .rhs
            .exe
            .execute_b(&[&self.u, &self.p, &tb])
            .map_err(|e| CompileRhsError::Runtime(format!("execute failed: {e}")))?;
        self.du = Some(take_single_output(out, "rhs")?);
        Ok(())
    }

    /// The resident derivative, for a caller that wants to hand it to another
    /// device computation rather than read it.
    pub fn du_device(&self) -> Option<&PjRtBuffer> {
        self.du.as_ref()
    }

    /// Copy the resident derivative to the host. THIS is the transfer that
    /// [`eval_at`](Self::eval_at) avoids; call it when you actually want the
    /// numbers, not once per step.
    pub fn du_to_host(&self) -> Result<Vec<f64>, CompileRhsError> {
        let du = self.du.as_ref().ok_or_else(|| {
            CompileRhsError::Runtime("no derivative on the device yet; call eval_at first".into())
        })?;
        let mut host = vec![0.0f64; self.rhs.n_states];
        du.copy_raw_to_host_sync(&mut host, 0)
            .map_err(|e| CompileRhsError::Runtime(format!("copy back failed: {e}")))?;
        Ok(host)
    }

    /// Copy the resident state to the host, for a caller that stepped on the
    /// device and now wants to see where it got to.
    pub fn state_to_host(&self) -> Result<Vec<f64>, CompileRhsError> {
        let mut host = vec![0.0f64; self.rhs.n_states];
        self.u
            .copy_raw_to_host_sync(&mut host, 0)
            .map_err(|e| CompileRhsError::Runtime(format!("copy back failed: {e}")))?;
        Ok(host)
    }

    /// `u <- u + dt * f(u, p, t)`, entirely on the device.
    ///
    /// This exists to make the residency USABLE, not because explicit Euler is
    /// a good integrator: without it the only way to get the derivative back
    /// into the state is through the host, and then keeping the output buffer
    /// resident buys nothing. A real solver would fuse its whole stage into
    /// the emitted program; this is the smallest thing that demonstrates a
    /// closed loop with no transfer in it.
    pub fn euler_step(&mut self, t: f64, dt: f64) -> Result<(), CompileRhsError> {
        self.eval_at(t)?;
        let client = client().map_err(CompileRhsError::Runtime)?;
        if self.stepper.is_none() {
            self.stepper = Some(compile_axpy(self.rhs.n_states)?);
        }
        let dtb = client
            .buffer_from_host_buffer(&[dt], &[], None)
            .map_err(|e| CompileRhsError::Runtime(format!("upload of dt failed: {e}")))?;
        let du = self
            .du
            .as_ref()
            .expect("eval_at just set the derivative");
        let out = self
            .stepper
            .as_ref()
            .expect("just compiled")
            .execute_b(&[&self.u, du, &dtb])
            .map_err(|e| CompileRhsError::Runtime(format!("step execute failed: {e}")))?;
        self.u = take_single_output(out, "step")?;
        Ok(())
    }
}

/// Unwrap PJRT's replica-major, then output-major result nesting down to the
/// one buffer these single-output, single-replica programs produce.
fn take_single_output(
    mut out: Vec<Vec<PjRtBuffer>>,
    what: &str,
) -> Result<PjRtBuffer, CompileRhsError> {
    if out.len() != 1 {
        return Err(CompileRhsError::Runtime(format!(
            "{what}: execute returned {} replicas, expected 1",
            out.len()
        )));
    }
    let mut replica = out.remove(0);
    if replica.len() != 1 {
        return Err(CompileRhsError::Runtime(format!(
            "{what}: execute returned {} output buffers, expected 1",
            replica.len()
        )));
    }
    Ok(replica.remove(0))
}

/// Compile `(u, du, dt) -> u + dt * du` for a flat state of `n` elements.
fn compile_axpy(n: usize) -> Result<PjRtLoadedExecutable, CompileRhsError> {
    let b = XlaBuilder::new("euler_step");
    let build = || -> Result<xla::XlaComputation, xla::Error> {
        let u = b.parameter(0, f64::TY, &[n as i64], "u")?;
        let du = b.parameter(1, f64::TY, &[n as i64], "du")?;
        let dt = b.parameter(2, f64::TY, &[], "dt")?;
        let scaled = dt.broadcast(&[n as i64])?.mul_(&du)?;
        b.build(&u.add_(&scaled)?)
    };
    let comp = build()
        .map_err(|e| CompileRhsError::Runtime(format!("building the step program failed: {e}")))?;
    client()
        .map_err(CompileRhsError::Runtime)?
        .compile(&comp)
        .map_err(|e| CompileRhsError::Runtime(format!("compiling the step program failed: {e}")))
}
