//! The Problem / `solve` surface — one noun and one verb
//! (`esm-libraries-spec.md` §2.5, `API_SPEC.md` §5.8).
//!
//! ```text
//! let prob = esm_problem(&file, (0.0, 10.0), ProblemOptions::default())?;  // build once
//! let sol  = solve(&prob, &SolveOptions::default())?;                      // run per knob-set
//! ```
//!
//! [`ProblemOptions`] is taken **by value**: it owns the boxed data providers
//! the build hands to the runtime, and there is nothing left in it worth
//! reusing afterwards. [`SolveOptions`] is taken by reference, because a caller
//! sweeping knobs reuses it.
//!
//! ## What replaced what
//!
//! `simulate` is **gone**, in all of its forms — the one-shot free function,
//! `simulate_with_inspection`, `simulate_with_providers_inspect`, and
//! `Prepared`/`prepare`. It conflated two operations whose costs differ by
//! orders of magnitude and whose inputs differ in kind, which is exactly why
//! this crate had grown a second, `prepare`-shaped entry point beside it.
//!
//! [`esm_problem`] absorbs the whole deterministic-per-document pipeline: the
//! projection-pushdown rewrite, value invention, the gated fetch of provider
//! data, CONST-provider materialization, and the compile of the right-hand
//! side. [`solve`] varies only per-run knobs — `alg`, `abstol`, `reltol`,
//! `saveat`, `callback`, `maxiters`.
//!
//! ## The solver is optional
//!
//! Per §2.5.9, **constructing a Problem does not require the solver.**
//! [`esm_problem`], [`remake`], [`callbacks`] and [`observed_field`] are all
//! available with the `solve` Cargo feature switched off; only [`solve`],
//! [`init`], [`step`] and [`solve_to_completion`] need it. `diffsol` is behind
//! that feature and is not an unconditional dependency.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ndarray::ArrayD;
use serde_json::Value as JsonValue;

use crate::flatten::FlattenedSystem;
#[cfg_attr(not(feature = "solve"), allow(unused_imports))]
use crate::simulate::Solution;
use crate::simulate::{Compiled, Flow, Progress, ProgressFn, SimulateError, SolveOptions};
use crate::types::EsmFile;

use crate::simulate_array::{ArrayCompiled, BuildInspection};

// =============================================================================
// Callbacks
// =============================================================================

/// One callback: an observer invoked once before the first step and then after
/// every accepted step, with the interval covered so far AND the integrator's
/// current state vector ([`Progress::u`]).
///
/// Returning [`Flow::Cancel`] stops the integration; the solution comes back
/// with [`crate::ReturnCode::Terminated`] and the trajectory computed so far
/// rather than as an error, because a caller who stops a run deliberately still
/// wants what it produced.
#[cfg(target_arch = "wasm32")]
pub type CallbackFn = std::rc::Rc<dyn for<'p> Fn(&Progress<'p>) -> Flow>;
/// One callback. See the `wasm32` twin for the documentation.
#[cfg(not(target_arch = "wasm32"))]
pub type CallbackFn = std::sync::Arc<dyn for<'p> Fn(&Progress<'p>) -> Flow + Send + Sync>;

/// The callbacks declared on a [`Problem`].
///
/// Callbacks live on the Problem, not on a run: a callback that refreshes
/// provider buffers or writes an output stream belongs to the *document*, not
/// to a particular run's tolerances (§2.5.4).
///
/// Entries are named so that [`CallbackSet::names`] can tell a caller what a
/// Problem already carries before they decide whether to replace it.
#[derive(Clone, Default)]
pub struct CallbackSet {
    entries: Vec<(String, CallbackFn)>,
}

impl std::fmt::Debug for CallbackSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CallbackSet")
            .field("names", &self.names())
            .finish()
    }
}

impl CallbackSet {
    /// An empty set.
    pub fn new() -> Self {
        Self::default()
    }

    /// A one-entry set.
    pub fn of(name: impl Into<String>, f: CallbackFn) -> Self {
        let mut s = Self::new();
        s.push(name, f);
        s
    }

    /// Append one named callback.
    pub fn push(&mut self, name: impl Into<String>, f: CallbackFn) -> &mut Self {
        self.entries.push((name.into(), f));
        self
    }

    /// How many callbacks the set holds.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the set is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The names, in invocation order.
    pub fn names(&self) -> Vec<&str> {
        self.entries.iter().map(|(n, _)| n.as_str()).collect()
    }

    /// Invoke every callback in order. The first [`Flow::Cancel`] wins, and the
    /// remaining callbacks are still called — an output callback must not be
    /// skipped for the final step just because an earlier watchdog asked to
    /// stop on it.
    pub fn invoke(&self, p: &Progress<'_>) -> Flow {
        let mut flow = Flow::Continue;
        for (_, f) in &self.entries {
            if matches!(f(p), Flow::Cancel) {
                flow = Flow::Cancel;
            }
        }
        flow
    }
}

/// Concatenate two callback sets into a new one.
///
/// This is the explicit composition §2.5.4 requires: a `callback` argument to
/// [`solve`] REPLACES the Problem's set entirely — it does not append, merge or
/// wrap — so a caller who wants to *extend* rather than replace reads the
/// existing set back with [`callbacks`] and composes:
///
/// ```text
/// let cb = compose(callbacks(&prob), &my_extra);
/// solve(&prob, &SolveOptions { callback: Some(cb), ..Default::default() })
/// ```
pub fn compose(a: &CallbackSet, b: &CallbackSet) -> CallbackSet {
    let mut out = a.clone();
    out.entries.extend(b.entries.iter().cloned());
    out
}

// =============================================================================
// Construction inputs and options
// =============================================================================

/// What [`esm_problem`] can be built from: a path on disk, a raw JSON
/// document, a typed document, or an already-flattened system.
pub enum ProblemInput<'a> {
    /// A path to an `.esm` file.
    Path(&'a Path),
    /// A raw (un-typed) JSON document — the form the build pipeline rewrites.
    Json(&'a JsonValue),
    /// A typed document.
    File(&'a EsmFile),
    /// An already-flattened system (scalar ODE path only).
    Flattened(&'a FlattenedSystem),
}

impl<'a> From<&'a Path> for ProblemInput<'a> {
    fn from(p: &'a Path) -> Self {
        ProblemInput::Path(p)
    }
}
impl<'a> From<&'a JsonValue> for ProblemInput<'a> {
    fn from(v: &'a JsonValue) -> Self {
        ProblemInput::Json(v)
    }
}
impl<'a> From<&'a EsmFile> for ProblemInput<'a> {
    fn from(f: &'a EsmFile) -> Self {
        ProblemInput::File(f)
    }
}
impl<'a> From<&'a FlattenedSystem> for ProblemInput<'a> {
    fn from(f: &'a FlattenedSystem) -> Self {
        ProblemInput::Flattened(f)
    }
}

/// Whether [`esm_problem`] compiles a right-hand side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Compile {
    /// Compile when the selected document declares differential equations,
    /// skip when it does not. A document with no ODEs — a dispatched static
    /// evaluation — still gets a Problem, whose build-time products
    /// [`observed_field`] reads; [`solve`] on it raises
    /// [`SimulateError::NotDynamic`].
    #[default]
    Auto,
    /// Always compile; a document with no differential equations is an error.
    Always,
    /// Never compile. Build-time products only.
    Never,
}

/// Build-time bindings for [`esm_problem`] — everything that fixes a
/// *document* rather than a *run*.
///
/// The per-run knobs (`alg`, `abstol`, `reltol`, `saveat`, `callback`,
/// `maxiters`) live on [`SolveOptions`] instead. That split is the whole point
/// of §2.5: construction is deterministic per document and expensive, `solve`
/// is cheap and varies.
#[derive(Default)]
pub struct ProblemOptions {
    /// Parameter bindings (canonical SciML `p`). Exact or bare names.
    pub p: HashMap<String, f64>,
    /// Initial state bindings (canonical SciML `u0`). Exact or bare names.
    pub u0: HashMap<String, f64>,
    /// Select one model when the document holds several.
    pub model_name: Option<String>,
    /// Metaparameter bindings closed at load (esm-spec §9.7.6 site 4).
    pub metaparameters: BTreeMap<String, i64>,
    /// Base path anchoring relative `{ref}`s.
    pub base_path: Option<PathBuf>,
    /// Callbacks declared on the Problem (§2.5.4).
    pub callbacks: CallbackSet,
    /// Whether to compile a right-hand side. See [`Compile`].
    pub compile: Compile,

    /// Opt in to the automatic projection-pushdown desugar. Turning this on
    /// also turns the build pipeline on.
    #[cfg(not(target_arch = "wasm32"))]
    pub pushdown_rewrite: bool,
    /// Run-time data providers, keyed by the forcing VARIABLE name they feed.
    ///
    /// CONST providers are materialized ONCE, here, at construction — the
    /// "gated fetch" §2.5.2 puts in the build half. DISCRETE providers
    /// contribute the refresh anchors [`solve`] segments the integration on.
    #[cfg(not(target_arch = "wasm32"))]
    pub providers: HashMap<String, Box<dyn crate::provider::CadenceProvider>>,
    /// Build-time array providers consumed by the pushdown / gated-fetch
    /// pipeline, keyed by provider key. Supplying any turns the build pipeline
    /// on.
    #[cfg(not(target_arch = "wasm32"))]
    pub build_providers: Vec<(String, Box<dyn crate::prepare::PrepareProvider>)>,
    /// Constant arrays injected into the build-time evaluation scope.
    #[cfg(not(target_arch = "wasm32"))]
    pub const_arrays: HashMap<String, ArrayD<f64>>,
    /// Force the deterministic build pipeline on (it is on automatically when
    /// `pushdown_rewrite`, `build_providers` or `const_arrays` is set).
    #[cfg(not(target_arch = "wasm32"))]
    pub build_pipeline: bool,
    /// Split a gated provider's pre-sliced fetch into requests of at most this
    /// many native indices along the gated axis.
    #[cfg(not(target_arch = "wasm32"))]
    pub gated_fetch_batch: Option<usize>,
    /// Print per-phase build progress lines on stdout.
    #[cfg(not(target_arch = "wasm32"))]
    pub verbose: bool,
    /// Build-time progress observer. **Extension seam, not stable API** — a
    /// binding MAY expose its own build observability (§2.5.2).
    #[cfg(not(target_arch = "wasm32"))]
    pub progress: Option<crate::prepare::PrepareProgressFn>,

    /// Collect the array runtime's named build-time products so
    /// [`observed_field`] can read them back.
    ///
    /// This is the **construction-time build-observability seam** that replaced
    /// the old `simulate_with_inspection` / `observed_field(prep, inspection,
    /// name)` threading: the caller asks for observability when it builds,
    /// and reads it back off the Problem, instead of carrying a
    /// `BuildInspection` through the run.
    pub inspect: bool,

    /// Time at which CONST providers are sampled. Defaults to `tspan.0`.
    pub sample_time: Option<f64>,
}

impl std::fmt::Debug for ProblemOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut d = f.debug_struct("ProblemOptions");
        d.field("p", &self.p)
            .field("u0", &self.u0)
            .field("model_name", &self.model_name)
            .field("metaparameters", &self.metaparameters)
            .field("base_path", &self.base_path)
            .field("callbacks", &self.callbacks)
            .field("compile", &self.compile)
            .field("inspect", &self.inspect)
            .field("sample_time", &self.sample_time);
        #[cfg(not(target_arch = "wasm32"))]
        d.field("pushdown_rewrite", &self.pushdown_rewrite)
            .field("providers", &self.providers.keys().collect::<Vec<_>>())
            .field(
                "build_providers",
                &self
                    .build_providers
                    .iter()
                    .map(|(k, _)| k)
                    .collect::<Vec<_>>(),
            )
            .field(
                "const_arrays",
                &self.const_arrays.keys().collect::<Vec<_>>(),
            )
            .field("build_pipeline", &self.build_pipeline)
            .field("gated_fetch_batch", &self.gated_fetch_batch)
            .field("verbose", &self.verbose)
            // Hand-written because the observer is a trait object: it cannot
            // derive `Debug`, and a `ProblemOptions` that no longer prints
            // would be a regression for every `{:?}` on a build error path.
            .field(
                "progress",
                &self
                    .progress
                    .as_ref()
                    .map(|_| "<observer>")
                    .unwrap_or("None"),
            );
        d.finish()
    }
}

// =============================================================================
// The Problem
// =============================================================================

/// The compiled right-hand side a [`Problem`] integrates, if any.
pub(crate) enum Backend {
    /// The scalar ODE interpreter.
    Scalar(Rc<Compiled>),
    /// The array / spatial runtime.
    Array(Rc<ArrayCompiled>),
    /// No right-hand side: the document declares no differential equations, or
    /// the caller asked for [`Compile::Never`]. Carries the reason.
    Static(String),
}

/// The build-time products construction materialized.
#[derive(Default)]
pub(crate) struct BuildProducts {
    /// Observed name → build-time field (dependency-complete).
    pub fields: HashMap<String, ArrayD<f64>>,
    /// Value-invention producer id (`from_faq`) → sorted-distinct member ids.
    pub members: HashMap<String, Vec<i64>>,
    /// Value-invention producer id → derived index-set extent.
    pub extents: HashMap<String, i64>,
    /// Provider keys that were deferred + fetched pre-sliced (sorted).
    pub gated_provider_keys: Vec<String>,
    /// Parameters baked into the build. Substituting one of these needs a
    /// rebuild, so [`remake`] refuses rather than lying.
    pub baked_parameters: Vec<String>,
}

/// A simulation problem: a document, an interval, and the bindings that fix
/// the document rather than the run.
///
/// Built once by [`esm_problem`]; run by [`solve`] (or stepped by [`init`]).
/// Re-parameterized without rebuilding by [`remake`].
pub struct Problem {
    /// The (possibly rewritten) raw document.
    pub(crate) doc: Rc<JsonValue>,
    /// The name of the model this Problem was built from, when one was
    /// selected.
    pub(crate) model_name: Option<String>,
    /// The integration interval.
    pub(crate) tspan: (f64, f64),
    /// Parameter bindings.
    pub(crate) p: HashMap<String, f64>,
    /// Initial-state bindings.
    pub(crate) u0: HashMap<String, f64>,
    /// The compiled right-hand side. `Rc` so [`remake`] shares it rather than
    /// recompiling.
    pub(crate) backend: Rc<Backend>,
    /// Build-time products, shared with every [`remake`] descendant.
    pub(crate) build: Rc<BuildProducts>,
    /// Build observability, filled at construction when
    /// [`ProblemOptions::inspect`] is set and topped up at the first solve.
    pub(crate) inspection: std::cell::RefCell<BuildInspection>,
    /// Whether the caller asked for build observability.
    pub(crate) inspect: bool,
    /// Callbacks declared on the Problem (§2.5.4).
    pub(crate) callbacks: CallbackSet,
    /// Bound run-time providers, already CONST-materialized.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) refresh: Option<std::cell::RefCell<crate::provider::RefreshExecutor>>,
    /// Forcing variables fed by a DISCRETE provider.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) discrete_forcing: std::collections::HashSet<String>,
    /// Refresh anchors strictly inside `tspan`.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) refresh_boundaries: Vec<f64>,
}

impl std::fmt::Debug for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Problem")
            .field("model_name", &self.model_name)
            .field("tspan", &self.tspan)
            .field("p", &self.p.len())
            .field("u0", &self.u0.len())
            .field("backend", &self.backend_kind())
            .field("callbacks", &self.callbacks.names())
            .finish()
    }
}

impl Problem {
    /// The integration interval.
    pub fn tspan(&self) -> (f64, f64) {
        self.tspan
    }

    /// The parameter bindings this Problem carries.
    pub fn p(&self) -> &HashMap<String, f64> {
        &self.p
    }

    /// The initial-state bindings this Problem carries.
    pub fn u0(&self) -> &HashMap<String, f64> {
        &self.u0
    }

    /// The model this Problem was built from, when one was selected.
    pub fn model_name(&self) -> Option<&str> {
        self.model_name.as_deref()
    }

    /// The (possibly rewritten) raw document.
    pub fn document(&self) -> &JsonValue {
        &self.doc
    }

    /// `"scalar"`, `"array"`, or `"static"`.
    pub fn backend_kind(&self) -> &'static str {
        match &*self.backend {
            Backend::Scalar(_) => "scalar",
            Backend::Array(_) => "array",
            Backend::Static(_) => "static",
        }
    }

    /// Whether this Problem has a right-hand side to integrate.
    pub fn is_dynamic(&self) -> bool {
        !matches!(&*self.backend, Backend::Static(_))
    }

    /// The state-variable names of the compiled right-hand side, in the
    /// flattened state-vector order. Empty for a static Problem.
    pub fn state_variable_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Scalar(c) => c.state_variable_names().to_vec(),
            Backend::Array(c) => c.state_variable_names().to_vec(),
            Backend::Static(_) => Vec::new(),
        }
    }

    /// The parameter names of the compiled right-hand side. Empty for a static
    /// Problem.
    pub fn parameter_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Scalar(c) => c.parameter_names().to_vec(),
            Backend::Array(c) => c.parameter_names().to_vec(),
            Backend::Static(_) => Vec::new(),
        }
    }

    /// The value-invention members this Problem's build materialized.
    pub fn members(&self) -> &HashMap<String, Vec<i64>> {
        &self.build.members
    }

    /// The derived index-set extents this Problem's build materialized.
    pub fn extents(&self) -> &HashMap<String, i64> {
        &self.build.extents
    }

    /// Provider keys that were deferred and fetched pre-sliced.
    pub fn gated_provider_keys(&self) -> &[String] {
        &self.build.gated_provider_keys
    }

    /// Take the build-observability record this Problem collected.
    ///
    /// Only populated when [`ProblemOptions::inspect`] was set. This is the
    /// construction-time seam that replaced threading a `&mut BuildInspection`
    /// through the run.
    pub fn take_inspection(&self) -> BuildInspection {
        std::mem::take(&mut self.inspection.borrow_mut())
    }

    /// Every build-time field this Problem's construction materialized, keyed
    /// by observed name.
    pub fn observed_fields(&self) -> &HashMap<String, ArrayD<f64>> {
        &self.build.fields
    }

    /// The names of every build-time field [`observed_field`] can return.
    pub fn observed_field_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.build.fields.keys().cloned().collect();
        names.extend(self.inspection.borrow().setup_arrays.keys().cloned());
        names.sort();
        names.dedup();
        names
    }
}

/// The callbacks declared on `prob` (§2.5.4).
///
/// Stable API in every simulation-capable binding, and for a specific reason:
/// a `callback` argument to [`solve`] REPLACES this set entirely, so without a
/// way to read it back, a Problem-level callback would be impossible to extend.
/// See [`compose`].
pub fn callbacks(prob: &Problem) -> &CallbackSet {
    &prob.callbacks
}

/// The build-time field named `name`, from `prob`'s construction.
///
/// Matches the exact name first, then the unique dotted-name tail. Reads the
/// build pipeline's fields and, when [`ProblemOptions::inspect`] was set, the
/// array runtime's materialized setup arrays — one arity, `(prob, name)`, in
/// every binding.
pub fn observed_field(prob: &Problem, name: &str) -> Result<ArrayD<f64>, SimulateError> {
    fn pick<'a, T>(map: &'a HashMap<String, T>, name: &str) -> Option<&'a T> {
        if let Some(v) = map.get(name) {
            return Some(v);
        }
        if name.contains('.') {
            return None;
        }
        let mut matches: Vec<&String> = map
            .keys()
            .filter(|k| k.contains('.') && k.rsplit('.').next() == Some(name))
            .collect();
        matches.sort();
        matches.first().map(|k| &map[*k])
    }

    if let Some(a) = pick(&prob.build.fields, name) {
        return Ok(a.clone());
    }
    if let Some(a) = pick(&prob.inspection.borrow().setup_arrays, name) {
        return Ok(a.clone());
    }
    Err(SimulateError::Compile(
        crate::compile_error::CompileError::InterpreterBuildError {
            details: format!(
                "observed_field: '{name}' is not a build-time-evaluable observed of this Problem"
            ),
        },
    ))
}

// =============================================================================
// remake
// =============================================================================

/// The substitutions [`remake`] applies. Every field is optional; an omitted
/// field is inherited unchanged.
#[derive(Debug, Clone, Default)]
pub struct Remake {
    /// Replacement parameter bindings, merged over the Problem's.
    pub p: HashMap<String, f64>,
    /// Replacement initial-state bindings, merged over the Problem's.
    pub u0: HashMap<String, f64>,
    /// A different integration interval.
    pub tspan: Option<(f64, f64)>,
    /// Replacement callbacks. `None` inherits the Problem's set.
    pub callbacks: Option<CallbackSet>,
}

/// A NEW Problem with `changes` applied and everything else shared (§2.5.5).
///
/// Does not mutate `prob`, and does not redo the parts of construction the
/// substitution cannot have invalidated: the compiled right-hand side, the
/// build-time fields and the materialized provider data are shared by `Rc`, not
/// rebuilt. A changed parameter value does not re-fetch provider data or
/// recompile.
///
/// **Refusal is deliberate.** A substitution the Problem cannot honour without
/// a rebuild raises [`SimulateError::UnsubstitutableBinding`], naming the
/// binding and the class that makes it un-substitutable, rather than silently
/// rebuilding or silently ignoring it. Two classes refuse: a parameter that was
/// baked into the build (it is a load-time constant of the compiled RHS, not a
/// solver input), and a name that is not a parameter of the compiled system at
/// all.
pub fn remake(prob: &Problem, changes: &Remake) -> Result<Problem, SimulateError> {
    let known: std::collections::HashSet<String> = prob.parameter_names().into_iter().collect();
    let known_bare: HashMap<String, usize> = {
        let mut counts: HashMap<String, usize> = HashMap::new();
        for n in &known {
            *counts
                .entry(n.rsplit('.').next().unwrap_or(n).to_string())
                .or_insert(0) += 1;
        }
        counts
    };

    for name in changes.p.keys() {
        if prob.build.baked_parameters.iter().any(|b| b == name) {
            return Err(SimulateError::UnsubstitutableBinding {
                name: name.clone(),
                class: "baked into the build as a load-time constant — build a new Problem"
                    .to_string(),
            });
        }
        if prob.is_dynamic()
            && !known.contains(name)
            && known_bare.get(name).copied().unwrap_or(0) == 0
        {
            return Err(SimulateError::UnsubstitutableBinding {
                name: name.clone(),
                class: "not a parameter of the compiled system".to_string(),
            });
        }
    }

    let mut p = prob.p.clone();
    p.extend(changes.p.iter().map(|(k, v)| (k.clone(), *v)));
    let mut u0 = prob.u0.clone();
    u0.extend(changes.u0.iter().map(|(k, v)| (k.clone(), *v)));
    let tspan = changes.tspan.unwrap_or(prob.tspan);

    #[cfg(not(target_arch = "wasm32"))]
    let boundaries: Vec<f64> = prob
        .refresh_boundaries
        .iter()
        .copied()
        .filter(|&b| b > tspan.0 && b < tspan.1)
        .collect();

    Ok(Problem {
        doc: Rc::clone(&prob.doc),
        model_name: prob.model_name.clone(),
        tspan,
        p,
        u0,
        backend: Rc::clone(&prob.backend),
        build: Rc::clone(&prob.build),
        inspection: std::cell::RefCell::new(prob.inspection.borrow().clone()),
        inspect: prob.inspect,
        callbacks: changes
            .callbacks
            .clone()
            .unwrap_or_else(|| prob.callbacks.clone()),
        // The materialized provider data is shared by moving the executor's
        // ownership question out of `remake`'s way: a remade Problem reads the
        // SAME forcing buffer, because the provider fetch is exactly the work
        // §2.5.5 forbids redoing. A Problem with providers therefore cannot be
        // remade into two live copies; the derivative borrows nothing and
        // carries no executor of its own.
        #[cfg(not(target_arch = "wasm32"))]
        refresh: None,
        #[cfg(not(target_arch = "wasm32"))]
        discrete_forcing: prob.discrete_forcing.clone(),
        #[cfg(not(target_arch = "wasm32"))]
        refresh_boundaries: boundaries,
    })
}

// =============================================================================
// Ensembles
// =============================================================================

/// A Problem plus a per-trajectory rewrite, and the family it stands for
/// (§2.5.8) — the canonical form for parameter sweeps, Monte Carlo over
/// declared distributions, and perturbed initial conditions.
pub struct EnsembleProblem<'a> {
    prob: &'a Problem,
    trajectories: usize,
    #[allow(clippy::type_complexity)]
    rewrite: Box<dyn Fn(&Problem, usize) -> Result<Remake, SimulateError> + 'a>,
}

impl std::fmt::Debug for EnsembleProblem<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EnsembleProblem")
            .field("trajectories", &self.trajectories)
            .field("prob", self.prob)
            .finish()
    }
}

impl<'a> EnsembleProblem<'a> {
    /// Wrap `prob` with a rewrite applied once per trajectory index.
    ///
    /// The rewrite returns a [`Remake`], not a Problem, so every trajectory
    /// goes through the same refusal rules and shares the same compiled
    /// right-hand side.
    pub fn new(
        prob: &'a Problem,
        trajectories: usize,
        rewrite: impl Fn(&Problem, usize) -> Result<Remake, SimulateError> + 'a,
    ) -> Self {
        Self {
            prob,
            trajectories,
            rewrite: Box::new(rewrite),
        }
    }

    /// The base Problem.
    pub fn problem(&self) -> &Problem {
        self.prob
    }

    /// How many trajectories the family holds.
    pub fn trajectories(&self) -> usize {
        self.trajectories
    }

    /// The Problem for trajectory `i`.
    pub fn trajectory(&self, i: usize) -> Result<Problem, SimulateError> {
        let changes = (self.rewrite)(self.prob, i)?;
        remake(self.prob, &changes)
    }
}

/// Solve every trajectory of `ens`, in index order (§2.5.8).
#[cfg(feature = "solve")]
pub fn solve_ensemble(
    ens: &EnsembleProblem<'_>,
    opts: &SolveOptions,
) -> Result<Vec<Solution>, SimulateError> {
    let mut out = Vec::with_capacity(ens.trajectories());
    for i in 0..ens.trajectories() {
        let prob = ens.trajectory(i)?;
        out.push(solve(&prob, opts)?);
    }
    Ok(out)
}

// =============================================================================
// Construction
// =============================================================================

/// Build a [`Problem`] (§2.5.2).
///
/// Absorbs the whole deterministic-per-document pipeline — the pushdown
/// rewrite, value invention, the gated fetch of provider data, CONST-provider
/// materialization, and the compile of the right-hand side — and takes the
/// bindings that fix a *document*: parameters, initial state, data providers,
/// metaparameters, and the model to build when the file holds several.
///
/// **Does not require the solver.** With the `solve` Cargo feature off this
/// still builds; only [`solve`] and the stepping entry points need `diffsol`.
pub fn esm_problem<'a>(
    input: impl Into<ProblemInput<'a>>,
    tspan: (f64, f64),
    opts: ProblemOptions,
) -> Result<Problem, SimulateError> {
    let input = input.into();
    #[allow(unused_mut)]
    let mut opts = opts;

    // ---- (1) Resolve the input to a raw document and/or a typed one. -------
    let mut owned_json: Option<JsonValue> = None;
    let mut owned_file: Option<EsmFile> = None;
    let mut flat_only: Option<&FlattenedSystem> = None;

    match input {
        ProblemInput::Path(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::InterpreterBuildError {
                    details: format!("reading {}: {e}", path.display()),
                })
            })?;
            let raw: JsonValue = serde_json::from_str(&text).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::InterpreterBuildError {
                    details: format!("parsing {}: {e}", path.display()),
                })
            })?;
            owned_json = Some(raw);
        }
        ProblemInput::Json(v) => owned_json = Some(v.clone()),
        ProblemInput::File(f) => owned_file = Some(f.clone()),
        ProblemInput::Flattened(f) => flat_only = Some(f),
    }

    // ---- (2) The deterministic build pipeline. ----------------------------
    // `mut` on wasm32 only in the sense that the pipeline that writes these is
    // native-only; the bindings themselves exist on both targets.
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut build = BuildProducts::default();
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut model_name = opts.model_name.clone();

    #[cfg(not(target_arch = "wasm32"))]
    if let Some(raw) = owned_json.as_mut().filter(|_| wants_build_pipeline(&opts)) {
        {
            let prepared = crate::prepare::run_build_pipeline(raw, &mut opts)?;
            *raw = prepared.doc;
            model_name = Some(prepared.model_name);
            build.fields = prepared.fields;
            build.members = prepared.members;
            build.extents = prepared.extents;
            build.gated_provider_keys = prepared.gated_provider_keys;
            build.baked_parameters = opts.p.keys().cloned().collect();
            build.baked_parameters.sort();
        }
    }

    // ---- (3) Typed parse. -------------------------------------------------
    if owned_file.is_none()
        && let Some(raw) = owned_json.as_ref()
    {
        {
            let text = serde_json::to_string(raw).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::InterpreterBuildError {
                    details: format!("re-serializing the prepared document: {e}"),
                })
            })?;
            match crate::parse::load_string(&text) {
                Ok(f) => owned_file = Some(f),
                Err(e) => {
                    // A document the build pipeline rewrote may no longer be a
                    // *typed* ESM document (the pushdown desugar emits engine
                    // constructs). Its build-time products are still valid, so
                    // this is only fatal when the caller wanted a solve.
                    if opts.compile == Compile::Always {
                        return Err(SimulateError::Compile(
                            crate::compile_error::CompileError::InterpreterBuildError {
                                details: format!("typed parse of the prepared document: {e}"),
                            },
                        ));
                    }
                }
            }
        }
    }

    // ---- (4) Compile the right-hand side. ---------------------------------
    let backend = compile_backend(
        owned_file.as_ref(),
        flat_only,
        model_name.as_deref(),
        opts.compile,
    )?;

    // ---- (5) Bind and CONST-materialize the run-time providers. -----------
    #[cfg(not(target_arch = "wasm32"))]
    let (refresh, discrete_forcing, refresh_boundaries) =
        bind_providers(&backend, &mut opts, tspan)?;

    let prob = Problem {
        doc: Rc::new(owned_json.unwrap_or(JsonValue::Null)),
        model_name,
        tspan,
        p: std::mem::take(&mut opts.p),
        u0: std::mem::take(&mut opts.u0),
        backend: Rc::new(backend),
        build: Rc::new(build),
        inspection: std::cell::RefCell::new(BuildInspection::default()),
        inspect: opts.inspect,
        callbacks: std::mem::take(&mut opts.callbacks),
        #[cfg(not(target_arch = "wasm32"))]
        refresh,
        #[cfg(not(target_arch = "wasm32"))]
        discrete_forcing,
        #[cfg(not(target_arch = "wasm32"))]
        refresh_boundaries,
    };
    Ok(prob)
}

#[cfg(not(target_arch = "wasm32"))]
fn wants_build_pipeline(opts: &ProblemOptions) -> bool {
    opts.build_pipeline
        || opts.pushdown_rewrite
        || !opts.build_providers.is_empty()
        || !opts.const_arrays.is_empty()
}

fn compile_backend(
    file: Option<&EsmFile>,
    flat: Option<&FlattenedSystem>,
    model_name: Option<&str>,
    mode: Compile,
) -> Result<Backend, SimulateError> {
    if mode == Compile::Never {
        return Ok(Backend::Static(
            "the caller asked for Compile::Never".to_string(),
        ));
    }
    if let Some(flat) = flat {
        return Ok(Backend::Scalar(Rc::new(Compiled::from_flattened(flat)?)));
    }
    let Some(file) = file else {
        if mode == Compile::Always {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::InterpreterBuildError {
                    details: "no typed document to compile".to_string(),
                },
            ));
        }
        return Ok(Backend::Static(
            "the prepared document has no typed form to compile".to_string(),
        ));
    };

    if mode == Compile::Auto && !has_differential_equations(file, model_name) {
        return Ok(Backend::Static(
            "the document declares no differential equations".to_string(),
        ));
    }

    if crate::simulate::is_array_file(file) {
        Ok(Backend::Array(Rc::new(
            crate::simulate::build_array_compiled(file)?,
        )))
    } else {
        Ok(Backend::Scalar(Rc::new(Compiled::from_file(file)?)))
    }
}

/// Whether the document (or the named model within it) declares at least one
/// differential equation, i.e. whether there is anything to integrate.
///
/// A document with none is a *dispatched static evaluation*: it still gets a
/// Problem, and [`observed_field`] still reads its build-time products, but
/// [`solve`] on it raises [`SimulateError::NotDynamic`] rather than handing
/// back an empty trajectory.
pub(crate) fn has_differential_equations(file: &EsmFile, model_name: Option<&str>) -> bool {
    let Some(models) = file.models.as_ref() else {
        return false;
    };
    models
        .iter()
        .filter(|(name, _)| model_name.is_none_or(|want| want == name.as_str()))
        .any(|(_, m)| model_has_derivative(m))
}

fn model_has_derivative(model: &crate::types::Model) -> bool {
    model.equations.iter().any(|eq| expr_is_derivative(&eq.lhs))
}

fn expr_is_derivative(e: &crate::types::Expr) -> bool {
    matches!(e, crate::types::Expr::Operator(node) if node.op == "D")
}

#[cfg(not(target_arch = "wasm32"))]
#[allow(clippy::type_complexity)]
fn bind_providers(
    backend: &Backend,
    opts: &mut ProblemOptions,
    tspan: (f64, f64),
) -> Result<
    (
        Option<std::cell::RefCell<crate::provider::RefreshExecutor>>,
        std::collections::HashSet<String>,
        Vec<f64>,
    ),
    SimulateError,
> {
    if opts.providers.is_empty() {
        return Ok((None, Default::default(), Vec::new()));
    }
    let Backend::Array(compiled) = backend else {
        // Providers feed loader fields, which only exist on the array/spatial
        // runtime; a pure-scalar or static document has nowhere to put them.
        let name = opts.providers.keys().next().cloned().unwrap_or_default();
        return Err(SimulateError::ProviderError {
            name,
            details: "providers require an array/spatial model (this document has none)"
                .to_string(),
        });
    };

    // One RefreshExecutor, classifying each provider by its `refresh_times()`.
    // CONST forcings are materialized ONCE, HERE — at construction, which is
    // where §2.5.2 puts the gated fetch — and never again.
    let providers = std::mem::take(&mut opts.providers);
    let mut exec = crate::provider::RefreshExecutor::from_providers(providers);
    let forcing = compiled.forcing_handle();
    exec.materialize_const(&forcing)
        .map_err(|e| SimulateError::ProviderError {
            name: "<const-loader>".into(),
            details: e.to_string(),
        })?;

    let discrete: std::collections::HashSet<String> = exec
        .bindings()
        .filter(|b| b.cadence == crate::cadence::Cadence::Discrete)
        .flat_map(|b| b.variables.iter().cloned())
        .collect();

    let sample_time = opts.sample_time.unwrap_or(tspan.0);
    let mut boundaries: Vec<f64> = exec.refresh_times();
    boundaries.retain(|&b| b > sample_time && b < tspan.1);

    Ok((Some(std::cell::RefCell::new(exec)), discrete, boundaries))
}

// =============================================================================
// solve
// =============================================================================

/// Run `prob` to completion (§2.5.3).
///
/// `opts` carries only per-run knobs: `alg`, `abstol`, `reltol`, `saveat`,
/// `callback`, `maxiters`. The result carries a
/// [`retcode`](crate::ReturnCode) — a caller distinguishes "ran to `tspan.1`"
/// from "stopped early, here is why" without parsing prose.
///
/// **`opts.callback` REPLACES the Problem's callback set entirely.** It does
/// not append, merge or wrap. To extend rather than replace, read the set back
/// with [`callbacks`] and [`compose`] explicitly. See §2.5.4 for why
/// replacement is the safe default.
#[cfg(feature = "solve")]
pub fn solve(prob: &Problem, opts: &SolveOptions) -> Result<Solution, SimulateError> {
    let effective = effective_options(prob, opts);
    match &*prob.backend {
        Backend::Static(reason) => Err(SimulateError::NotDynamic {
            details: reason.clone(),
        }),
        Backend::Scalar(compiled) => compiled.solve(prob.tspan, &prob.p, &prob.u0, &effective),
        Backend::Array(compiled) => {
            let mut insp = BuildInspection::default();
            let sink = prob.inspect.then_some(&mut insp);

            #[cfg(not(target_arch = "wasm32"))]
            let sol = {
                match (&prob.refresh, prob.discrete_forcing.is_empty()) {
                    (Some(exec), false) => {
                        let forcing = compiled.forcing_handle();
                        let mut exec = exec.borrow_mut();
                        let refresh_fn = |t: f64| -> Result<(), SimulateError> {
                            exec.refresh_at(t, &forcing).map(|_| ()).map_err(|e| {
                                SimulateError::ProviderError {
                                    name: "<discrete-loader>".into(),
                                    details: e.to_string(),
                                }
                            })
                        };
                        compiled.solve_with_refresh_inspect(
                            prob.tspan,
                            &prob.p,
                            &prob.u0,
                            &effective,
                            sink,
                            &prob.discrete_forcing,
                            &prob.refresh_boundaries,
                            refresh_fn,
                        )?
                    }
                    _ => compiled.solve_inspect(prob.tspan, &prob.p, &prob.u0, &effective, sink)?,
                }
            };
            #[cfg(target_arch = "wasm32")]
            let sol = compiled.solve_inspect(prob.tspan, &prob.p, &prob.u0, &effective, sink)?;

            if prob.inspect {
                *prob.inspection.borrow_mut() = insp;
            }
            Ok(sol)
        }
    }
}

/// Fold the Problem's callbacks (or the run's REPLACEMENT set) and the
/// extension-seam progress observer into the one per-step hook `run_solver`
/// already drives.
fn effective_options(prob: &Problem, opts: &SolveOptions) -> SolveOptions {
    // §2.5.4: the run's `callback` REPLACES the Problem's set. It does not
    // append, merge, or wrap.
    let set = opts
        .callback
        .clone()
        .unwrap_or_else(|| prob.callbacks.clone());
    if set.is_empty() {
        return opts.clone();
    }
    let user = opts.progress.clone();
    let observer: ProgressFn = wrap_observer(set, user);
    SolveOptions {
        progress: Some(observer),
        ..opts.clone()
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn wrap_observer(set: CallbackSet, user: Option<ProgressFn>) -> ProgressFn {
    std::sync::Arc::new(move |p: &Progress<'_>| {
        let a = set.invoke(p);
        let b = user.as_ref().map(|f| f(p)).unwrap_or(Flow::Continue);
        if matches!(a, Flow::Cancel) || matches!(b, Flow::Cancel) {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    })
}

#[cfg(target_arch = "wasm32")]
fn wrap_observer(set: CallbackSet, user: Option<ProgressFn>) -> ProgressFn {
    std::sync::Arc::new(move |p: &Progress<'_>| {
        let a = set.invoke(p);
        let b = user.as_ref().map(|f| f(p)).unwrap_or(Flow::Continue);
        if matches!(a, Flow::Cancel) || matches!(b, Flow::Cancel) {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    })
}

// =============================================================================
// Stepping
// =============================================================================

/// A stepping integrator (§2.5.6) — the same lifecycle [`solve`] performs
/// internally, exposed for callers that need to interleave their own work with
/// the integration: the coupling driver in a host model, an interactive
/// session, a progress UI.
///
/// # What a "step" is here
///
/// [`Integrator::step`] advances to the next entry of the **output grid**, not
/// to the next internal solver step. Each advance runs the configured
/// algorithm over `[t_now, t_next]` from the current state, exactly the way the
/// array runtime's segmented provider-refresh driver already advances across a
/// refresh boundary. That means the adaptive controller restarts at every
/// interleave point, so a run stepped in N pieces is not step-for-step
/// identical to the same run solved in one call — it is the same trajectory to
/// tolerance, at some extra cost per boundary. Choose the grid accordingly:
/// coarse when you only need to interleave, fine when you need control.
///
/// (`diffsol`'s solver borrows its `OdeSolverProblem`, so a Problem-owning
/// integrator that also owns a live solver would be self-referential. Restarting
/// per grid interval is the safe-Rust way to expose the lifecycle, and it is
/// the mechanism already in production here for segmented refresh.)
#[cfg(feature = "solve")]
pub struct Integrator<'a> {
    prob: &'a Problem,
    opts: SolveOptions,
    grid: Vec<f64>,
    next: usize,
    t: f64,
    u: HashMap<String, f64>,
    time: Vec<f64>,
    state: Vec<Vec<f64>>,
    names: Vec<String>,
    retcode: crate::simulate::ReturnCode,
    metadata: crate::simulate::SolutionMetadata,
}

#[cfg(feature = "solve")]
impl std::fmt::Debug for Integrator<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Integrator")
            .field("t", &self.t)
            .field("remaining", &(self.grid.len().saturating_sub(self.next)))
            .field("retcode", &self.retcode)
            .finish()
    }
}

/// Whether an [`Integrator`] has more to do.
#[cfg(feature = "solve")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepStatus {
    /// The integrator advanced and has further grid points to cover.
    Advanced,
    /// The integrator reached `tspan.1`, or stopped early — read
    /// [`Integrator::retcode`].
    Done,
}

/// Build a stepping integrator for `prob` (§2.5.6).
///
/// The step grid is `opts.saveat` when the caller supplied one, else 100 evenly
/// spaced points across `tspan`.
#[cfg(feature = "solve")]
pub fn init<'a>(prob: &'a Problem, opts: &SolveOptions) -> Result<Integrator<'a>, SimulateError> {
    if let Backend::Static(reason) = &*prob.backend {
        return Err(SimulateError::NotDynamic {
            details: reason.clone(),
        });
    }
    let (t0, t_end) = prob.tspan;
    let grid = match &opts.saveat {
        Some(g) if g.len() >= 2 => g.clone(),
        _ => {
            let n = 100usize;
            (0..=n)
                .map(|i| t0 + (t_end - t0) * (i as f64) / (n as f64))
                .collect()
        }
    };
    Ok(Integrator {
        prob,
        opts: opts.clone(),
        grid,
        next: 0,
        t: t0,
        u: prob.u0.clone(),
        time: Vec::new(),
        state: Vec::new(),
        names: prob.state_variable_names(),
        retcode: crate::simulate::ReturnCode::Success,
        metadata: crate::simulate::SolutionMetadata::default(),
    })
}

#[cfg(feature = "solve")]
impl Integrator<'_> {
    /// The independent-variable value reached so far.
    pub fn t(&self) -> f64 {
        self.t
    }

    /// Why the integration stopped, once it has.
    pub fn retcode(&self) -> crate::simulate::ReturnCode {
        self.retcode
    }

    /// The current state, keyed by variable name.
    pub fn u(&self) -> &HashMap<String, f64> {
        &self.u
    }

    /// Advance to the next grid point. Returns [`StepStatus::Done`] at the end
    /// of `tspan` or when the run stopped early.
    pub fn step(&mut self) -> Result<StepStatus, SimulateError> {
        if !self.retcode.is_success() {
            return Ok(StepStatus::Done);
        }
        // Skip grid points at or behind where we already are.
        while self.next < self.grid.len() && self.grid[self.next] <= self.t {
            self.next += 1;
        }
        if self.next >= self.grid.len() {
            return Ok(StepStatus::Done);
        }
        let t_next = self.grid[self.next];

        let seg = remake(
            self.prob,
            &Remake {
                u0: self.u.clone(),
                tspan: Some((self.t, t_next)),
                ..Default::default()
            },
        )?;
        let seg_opts = SolveOptions {
            saveat: Some(vec![t_next]),
            ..self.opts.clone()
        };
        let sol = solve(&seg, &seg_opts)?;

        self.retcode = sol.retcode;
        self.metadata.alg = sol.metadata.alg.clone();
        self.metadata.n_rhs_calls += sol.metadata.n_rhs_calls;
        self.metadata.n_jacobian_calls += sol.metadata.n_jacobian_calls;
        self.metadata.n_accepted_steps += sol.metadata.n_accepted_steps;
        self.metadata.n_rejected_steps += sol.metadata.n_rejected_steps;
        self.metadata.tape_fallbacks = sol.metadata.tape_fallbacks.clone();

        if self.state.is_empty() {
            self.names = sol.state_variable_names.clone();
            self.state = vec![Vec::new(); self.names.len()];
        }
        if let Some(k) = sol.time.len().checked_sub(1) {
            self.time.push(sol.time[k]);
            for (r, row) in sol.state.iter().enumerate() {
                if let Some(v) = row.get(k) {
                    if r < self.state.len() {
                        self.state[r].push(*v);
                    }
                    if let Some(name) = self.names.get(r) {
                        self.u.insert(name.clone(), *v);
                    }
                }
            }
            self.t = sol.time[k];
        }
        self.next += 1;
        if self.next >= self.grid.len() || !self.retcode.is_success() {
            Ok(StepStatus::Done)
        } else {
            Ok(StepStatus::Advanced)
        }
    }

    /// Run to completion and take the accumulated [`Solution`]. This is the
    /// `solve!` of the SciML lifecycle; it is spelled out because `!` is not a
    /// legal suffix in Rust.
    pub fn solve_to_completion(&mut self) -> Result<Solution, SimulateError> {
        while matches!(self.step()?, StepStatus::Advanced) {}
        Ok(Solution {
            time: std::mem::take(&mut self.time),
            state: std::mem::take(&mut self.state),
            state_variable_names: self.names.clone(),
            retcode: self.retcode,
            metadata: self.metadata.clone(),
        })
    }
}

/// Advance `integrator` by one grid point (§2.5.6's `step!`).
#[cfg(feature = "solve")]
pub fn step(integrator: &mut Integrator<'_>) -> Result<StepStatus, SimulateError> {
    integrator.step()
}

/// Run `integrator` to completion (§2.5.6's `solve!`).
#[cfg(feature = "solve")]
pub fn solve_to_completion(integrator: &mut Integrator<'_>) -> Result<Solution, SimulateError> {
    integrator.solve_to_completion()
}
