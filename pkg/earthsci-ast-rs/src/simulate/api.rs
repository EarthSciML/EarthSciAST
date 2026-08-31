use super::*;

// ============================================================================
// Public API surface (per gt-5ws design)
// ============================================================================

/// Why a solve stopped — the SciML `ReturnCode` vocabulary
/// (`esm-libraries-spec.md` §2.5.3).
///
/// This REPLACES reading [`SolutionMetadata`]'s step and evaluation counters as
/// a proxy for whether a run finished. The counters remain, as informative
/// statistics; the answer to "did it reach `tspan.1`" is this enum and nothing
/// else, and a caller never has to parse an error message to get it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReturnCode {
    /// The integration reached the end of `tspan`.
    Success,
    /// The integrator hit the configured [`SolveOptions::maxiters`] cap first.
    /// The trajectory returned is everything computed up to that point.
    MaxIters,
    /// The state left the finite range (a NaN or an infinity appeared), so the
    /// remaining trajectory would be meaningless.
    Unstable,
    /// A callback or the progress observer asked the integrator to stop
    /// ([`Flow::Cancel`]). Nothing went wrong: it is the caller's own decision.
    Terminated,
    /// The solver itself reported an error — a step failure, a build failure, a
    /// nonlinear-solve failure.
    Failure,
}

impl ReturnCode {
    /// Whether this is [`ReturnCode::Success`] — the one code that means the
    /// integration covered the whole of `tspan`.
    pub fn is_success(self) -> bool {
        matches!(self, ReturnCode::Success)
    }

    /// The canonical SciML spelling, for display and for JSON hosts.
    pub fn name(self) -> &'static str {
        match self {
            ReturnCode::Success => "Success",
            ReturnCode::MaxIters => "MaxIters",
            ReturnCode::Unstable => "Unstable",
            ReturnCode::Terminated => "Terminated",
            ReturnCode::Failure => "Failure",
        }
    }
}

impl std::fmt::Display for ReturnCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// The canonical default relative tolerance.
///
/// All three simulation-capable bindings defaulted differently — Rust `1e-6`,
/// Python scipy's `1e-3`, Julia `1e-4` — so the same document solved with
/// default options did not produce comparable trajectories. The ruling is to
/// adopt **Julia's** pair, which is what this is; Rust's own default was two
/// orders TIGHTER, so aligning loosens it.
///
/// These are the defaults for a *production* run, not for a conformance
/// assertion. A test that pins a trajectory to a numerical threshold should
/// pass an explicit `reltol`/`abstol` rather than lean on these — that is what
/// the knobs are for, and it is what the in-tree fixtures do.
pub const DEFAULT_RELTOL: f64 = 1e-4;

/// The canonical default absolute tolerance — Julia's. Rust's was `1e-8`.
/// See [`DEFAULT_RELTOL`].
pub const DEFAULT_ABSTOL: f64 = 1e-6;

/// Which solver family to use inside diffsol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alg {
    /// Backward Differentiation Formulas — implicit, default for stiff ODEs.
    Bdf,
    /// Singly Diagonally Implicit Runge-Kutta (TR-BDF2 tableau) — implicit,
    /// alternative stiff solver.
    Sdirk,
    /// Explicit Runge-Kutta (Tsitouras 5(4)) — non-stiff.
    Erk,
}

/// The raw trajectory the solver loop hands back: sample times, one state row
/// per time, and why it stopped.
#[cfg(feature = "solve")]
pub(crate) type RawTrajectory = (Vec<f64>, Vec<Vec<f64>>, ReturnCode);

/// The raw trajectory `integrate` hands back: [`RawTrajectory`] plus the
/// solver's step/eval counters.
#[cfg(feature = "solve")]
pub(super) type IntegrateResult =
    Result<(Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode), SimulateError>;

impl Alg {
    /// Parse the host-facing solver name, case-insensitively.
    ///
    /// Every host that lets a caller pick a solver receives it as a string —
    /// from a JSON options object in the browser, from an HTTP request body on
    /// a server — so the name→variant mapping belongs next to the enum rather
    /// than being re-derived per target. A host that spells it differently, or
    /// forgets to apply it at all, silently runs a DIFFERENT solver than the
    /// one its caller asked for and was quoted for.
    pub fn from_name(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "bdf" => Some(Self::Bdf),
            "sdirk" => Some(Self::Sdirk),
            "erk" => Some(Self::Erk),
            _ => None,
        }
    }

    /// The canonical lowercase name — the inverse of [`Self::from_name`].
    pub fn name(self) -> &'static str {
        match self {
            Self::Bdf => "bdf",
            Self::Sdirk => "sdirk",
            Self::Erk => "erk",
        }
    }
}

/// How far along an in-flight integration is, handed to
/// [`SolveOptions::progress`] once per accepted step.
///
/// `t` advances non-uniformly: an adaptive solver crawls through a stiff
/// startup and then takes large steps, so [`Progress::fraction`] is *not*
/// linear in wall clock. A host driving a progress bar from it should expect
/// the early part of a stiff run to look stalled, and is usually better off
/// showing `step` alongside the bar so a slow start still reads as alive.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Progress<'a> {
    /// Start of the integration interval.
    pub t0: f64,
    /// Independent-variable value the integrator has reached.
    pub t: f64,
    /// End of the integration interval.
    pub t_end: f64,
    /// Accepted steps taken so far (`0` for the pre-loop report at `t0`).
    pub step: usize,
    /// The configured [`SolveOptions::maxiters`] cap, for context.
    pub maxiters: usize,
    /// The integrator's state vector at `t`, in
    /// [`Compiled::state_variable_names`] order.
    ///
    /// This is what makes a [`crate::problem::CallbackSet`] entry able to do
    /// the job `esm-libraries-spec.md` §2.5.4 describes — write an output
    /// stream, checkpoint, watch for a threshold — rather than only draw a
    /// progress bar.
    pub u: &'a [f64],
}

impl Progress<'_> {
    /// Fraction of the integration interval covered, clamped to `[0, 1]`.
    ///
    /// Returns `0.0` for a degenerate (zero-length) interval rather than a NaN,
    /// so a host can divide by it or feed it to a bar without a guard.
    pub fn fraction(&self) -> f64 {
        let span = self.t_end - self.t0;
        if !span.is_finite() || span <= 0.0 {
            return 0.0;
        }
        ((self.t - self.t0) / span).clamp(0.0, 1.0)
    }
}

/// What a [`SolveOptions::progress`] observer wants the integrator to do
/// next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    /// Keep integrating.
    Continue,
    /// Stop now; [`run_solver`] unwinds with [`SimulateError::Cancelled`].
    Cancel,
}

/// A progress observer. See [`SolveOptions::progress`].
///
/// The `Send + Sync` bound is dropped on `wasm32`, where the natural observer
/// wraps a `js_sys::Function` (neither `Send` nor `Sync`, and harmlessly so on
/// a single-threaded target). Keeping the bound on native means adding this
/// field does not cost native callers `SolveOptions: Send + Sync`.
#[cfg(target_arch = "wasm32")]
pub type ProgressFn = std::sync::Arc<dyn for<'p> Fn(&Progress<'p>) -> Flow>;
/// A progress observer. See [`SolveOptions::progress`].
#[cfg(not(target_arch = "wasm32"))]
pub type ProgressFn = std::sync::Arc<dyn for<'p> Fn(&Progress<'p>) -> Flow + Send + Sync>;

/// Per-run knobs for [`crate::problem::solve`] / [`Compiled::solve`].
///
/// Every field carries the canonical SciML spelling (`API_SPEC.md` §4):
/// `alg`, `abstol`, `reltol`, `saveat`, `maxiters`.
#[derive(Clone)]
pub struct SolveOptions {
    /// Which solver algorithm to use. Defaults to [`Alg::Bdf`].
    ///
    /// Named `alg` — not `solver` — because `API_SPEC.md` §4 makes the SciML
    /// spelling canonical in every binding.
    pub alg: Alg,
    /// Absolute tolerance. Defaults to [`DEFAULT_ABSTOL`] (`1e-6`).
    pub abstol: f64,
    /// Relative tolerance. Defaults to [`DEFAULT_RELTOL`] (`1e-4`).
    pub reltol: f64,
    /// Maximum number of integrator steps before bailing out. Defaults to `10_000`.
    pub maxiters: usize,
    /// If `Some`, the solution is sampled (via dense output / interpolation)
    /// at exactly these times. If `None`, the natural step times are
    /// returned.
    pub saveat: Option<Vec<f64>>,
    /// Callbacks for THIS run.
    ///
    /// **`Some(set)` REPLACES the EsmProblem's callback set entirely** — it does
    /// not append, merge or wrap (`esm-libraries-spec.md` §2.5.4). `None`
    /// inherits the EsmProblem's set. To extend rather than replace, read the set
    /// back with [`crate::problem::callbacks`] and
    /// [`crate::problem::compose`] explicitly.
    pub callback: Option<crate::problem::CallbackSet>,
    /// If `Some`, called once before the first step and then after every
    /// accepted step, with the interval covered so far. Returning
    /// [`Flow::Cancel`] stops the integration with
    /// [`SimulateError::Cancelled`].
    ///
    /// **Called on every step, deliberately unthrottled.** The integrator has
    /// no portable clock to throttle against — `std::time::Instant::now()`
    /// panics on `wasm32-unknown-unknown`, and taking one unconditionally is
    /// what broke every array/PDE run in the browser until `bc52c5fa` — so the
    /// rate limiting belongs to the host, which has a working clock. Keep the
    /// observer cheap: a fast run can accept thousands of steps in well under a
    /// second.
    pub progress: Option<ProgressFn>,
    /// Observed fields to expose as extra rows of the returned [`Solution`],
    /// alongside the state (streaming-output-sinks RFC decision 8: output is
    /// the state PLUS a caller-named subset of observeds, never every observed
    /// by default).
    ///
    /// Empty by default, so a run that does not ask pays nothing and returns
    /// exactly what it returns today. A named field is appended in the same
    /// flat cell-key spelling the state uses — a scalar as `name`, an
    /// array-shaped one as one row per cell, `name[i,j,…]`, 1-based and
    /// column-major — which is precisely the `slot_names` shape
    /// [`crate::derive_output_plan`] inverts back into dimension-labeled,
    /// CF-coordinated output arrays.
    ///
    /// Names may be bare or `Model.`-qualified. A name that is not an observed
    /// of this document is ignored here and diagnosed downstream by
    /// [`crate::OutputError::UnknownObserved`], which names it.
    ///
    /// Honoured by both runners: the scalar runner walks its observed graph
    /// over the output grid, the array runner materializes the requested
    /// array-valued observeds it otherwise skips.
    pub output_observed: Vec<String>,
}

// Hand-written because `ProgressFn` is a trait object: it cannot derive Debug,
// and a `SolveOptions` that no longer prints would be a regression for every
// existing `{:?}` on a solver error path.
impl std::fmt::Debug for SolveOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SolveOptions")
            .field("alg", &self.alg)
            .field("abstol", &self.abstol)
            .field("reltol", &self.reltol)
            .field("maxiters", &self.maxiters)
            .field("saveat", &self.saveat)
            .field("callback", &self.callback)
            .field(
                "progress",
                &self
                    .progress
                    .as_ref()
                    .map(|_| "<observer>")
                    .unwrap_or("None"),
            )
            .field("output_observed", &self.output_observed)
            .finish()
    }
}

impl Default for SolveOptions {
    fn default() -> Self {
        Self {
            alg: Alg::Bdf,
            abstol: DEFAULT_ABSTOL,
            reltol: DEFAULT_RELTOL,
            maxiters: 10_000,
            saveat: None,
            callback: None,
            progress: None,
            output_observed: Vec::new(),
        }
    }
}

impl SolveOptions {
    /// Request `n` evenly spaced output samples across `[t0, t_end]`.
    ///
    /// Hosts almost always express "how much output do I want" as a count, not
    /// as a time grid, so the grid construction lives here — an off-by-one in
    /// the spacing is easy to write and impossible to notice in a plot.
    /// `n` is clamped to at least 2, since a span needs both ends.
    pub fn sample_evenly(&mut self, t0: f64, t_end: f64, n: usize) {
        let n = n.max(2);
        let span = t_end - t0;
        self.saveat = Some(
            (0..n)
                .map(|i| t0 + span * (i as f64) / ((n - 1) as f64))
                .collect(),
        );
    }
}

/// A simulation result.
///
/// `state[i][k]` is the value of state variable `state_variable_names[i]` at
/// time `time[k]`.
#[derive(Debug, Clone)]
pub struct Solution {
    /// Output time grid.
    pub time: Vec<f64>,
    /// State trajectories, indexed `[variable_index][time_index]`.
    pub state: Vec<Vec<f64>>,
    /// Names of the state variables, parallel to the rows of `state`.
    pub state_variable_names: Vec<String>,
    /// Why the integration stopped (`esm-libraries-spec.md` §2.5.3).
    ///
    /// [`ReturnCode::Success`] means the run reached `tspan.1`. Anything else
    /// means it stopped early and the trajectory ends where it stopped — the
    /// counters in [`Solution::metadata`] are statistics, not the answer to
    /// that question.
    pub retcode: ReturnCode,
    /// Solver provenance and step counts.
    pub metadata: SolutionMetadata,
}

impl Solution {
    /// The trajectory of the variable named `name` — the documented way to read
    /// a solution (`esm-libraries-spec.md` §2.5.7).
    ///
    /// Matches the exact (flattened, qualified) name first, then falls back to
    /// the UNIQUE dotted-name tail, so a caller may write `"x"` for `"M.x"`
    /// while an ambiguous bare name still returns `None` rather than an
    /// arbitrary one of the candidates. Position-indexed access through
    /// [`Solution::state`] remains available, but the flattened state ordering
    /// is an implementation detail that coupling can change.
    pub fn get(&self, name: &str) -> Option<&[f64]> {
        if let Some(i) = self.state_variable_names.iter().position(|n| n == name) {
            return Some(&self.state[i]);
        }
        if name.contains('.') {
            return None;
        }
        let mut hit = None;
        for (i, n) in self.state_variable_names.iter().enumerate() {
            if n.rsplit('.').next() == Some(name) && n.contains('.') {
                if hit.is_some() {
                    return None; // ambiguous bare name
                }
                hit = Some(i);
            }
        }
        hit.map(|i| self.state[i].as_slice())
    }

    /// [`Solution::get`], as a `Result` naming the variable that was not found.
    pub fn variable(&self, name: &str) -> Result<&[f64], SimulateError> {
        self.get(name)
            .ok_or_else(|| SimulateError::InvalidParameter {
                name: name.to_string(),
            })
    }

    /// The value of variable `name` at output index `k`.
    pub fn at(&self, name: &str, k: usize) -> Option<f64> {
        self.get(name).and_then(|row| row.get(k).copied())
    }

    /// The final value of variable `name`.
    pub fn final_value(&self, name: &str) -> Option<f64> {
        self.get(name).and_then(|row| row.last().copied())
    }

    /// Every variable name carried by this solution.
    pub fn variable_names(&self) -> &[String] {
        &self.state_variable_names
    }
}

impl std::ops::Index<&str> for Solution {
    type Output = [f64];

    /// `sol["M.x"]` — name-indexed access, panicking on an unknown or
    /// ambiguous name. Use [`Solution::get`] when absence is expected.
    fn index(&self, name: &str) -> &[f64] {
        self.get(name).unwrap_or_else(|| {
            panic!(
                "no state variable '{name}' in this solution; have {:?}",
                self.state_variable_names
            )
        })
    }
}

/// Provenance metadata for a [`Solution`].
#[derive(Debug, Clone, Default)]
pub struct SolutionMetadata {
    /// Solver algorithm name (e.g. `"Bdf"`, `"Sdirk"`, `"Erk"`).
    pub alg: String,
    /// Number of RHS function evaluations performed (best-effort, may be
    /// zero in v1 if diffsol does not expose it).
    pub n_rhs_calls: usize,
    /// Number of Jacobian evaluations performed (best-effort).
    pub n_jacobian_calls: usize,
    /// Number of accepted integrator steps (best-effort).
    pub n_accepted_steps: usize,
    /// Number of rejected integrator steps (best-effort).
    pub n_rejected_steps: usize,
    /// `(rule name, reason)` for every rule the array driver could NOT compile
    /// onto the vectorized tape and therefore evaluated with the per-cell
    /// oracle — one full re-walk of the rule body per grid cell per RHS call.
    ///
    /// A non-empty list is a performance diagnosis, not an error: the answer is
    /// bit-identical either way, but the cost of a fallback rule grows with the
    /// cell count while a taped rule's does not, so a single fallback in a
    /// tendency equation can be the difference between a second and an hour.
    /// See `esm-spec.md` §9.6.10 for the authoring patterns that keep rules
    /// vectorizable.
    ///
    /// Always empty for the scalar interpreter path (which has no tape) and
    /// when the tape is switched off with `ESS_TAPE_DISABLE` / `ESS_VEC_DISABLE`
    /// — an empty list means "nothing to report", not "the tape covered
    /// everything".
    pub tape_fallbacks: Vec<(String, String)>,
}
