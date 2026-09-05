//! The EsmProblem / `solve` surface — one noun and one verb
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
//! Per §2.5.9, **constructing a EsmProblem does not require the solver.**
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
use crate::precision::{self, Precision};
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

/// The callbacks declared on a [`EsmProblem`].
///
/// Callbacks live on the EsmProblem, not on a run: a callback that refreshes
/// provider buffers or writes an output stream belongs to the *document*, not
/// to a particular run's tolerances (§2.5.4).
///
/// Entries are named so that [`CallbackSet::names`] can tell a caller what a
/// EsmProblem already carries before they decide whether to replace it.
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
/// [`solve`] REPLACES the EsmProblem's set entirely — it does not append, merge or
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
    /// evaluation — still gets a EsmProblem, whose build-time products
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
    /// Callbacks declared on the EsmProblem (§2.5.4).
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
    /// and reads it back off the EsmProblem, instead of carrying a
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
// The EsmProblem
// =============================================================================

/// The compiled right-hand side a [`EsmProblem`] integrates, if any.
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
pub struct EsmProblem {
    /// The (possibly rewritten) raw document.
    pub(crate) doc: Rc<JsonValue>,
    /// The name of the model this EsmProblem was built from, when one was
    /// selected.
    pub(crate) model_name: Option<String>,
    /// The working precision the document declared (`domain.element_type`,
    /// esm-spec §11.3), captured at construction. Every run entry re-arms it
    /// (`precision::enter`) so a problem carries its own precision rather than
    /// depending on what the calling thread last evaluated.
    pub(crate) precision: precision::Env,
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
    /// Callbacks declared on the EsmProblem (§2.5.4).
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

impl std::fmt::Debug for EsmProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EsmProblem")
            .field("model_name", &self.model_name)
            .field("tspan", &self.tspan)
            .field("p", &self.p.len())
            .field("u0", &self.u0.len())
            .field("backend", &self.backend_kind())
            .field("callbacks", &self.callbacks.names())
            .finish()
    }
}

impl EsmProblem {
    /// The integration interval.
    pub fn tspan(&self) -> (f64, f64) {
        self.tspan
    }

    /// The parameter bindings this EsmProblem carries.
    pub fn p(&self) -> &HashMap<String, f64> {
        &self.p
    }

    /// The initial-state bindings this EsmProblem carries.
    pub fn u0(&self) -> &HashMap<String, f64> {
        &self.u0
    }

    /// The model this EsmProblem was built from, when one was selected.
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

    /// The working precision this problem evaluates in — `domain.element_type`
    /// (esm-spec §11.3), [`Precision::Float64`] unless the document said
    /// `"Float32"`.
    pub fn precision(&self) -> Precision {
        self.precision.document
    }

    /// Whether this EsmProblem has a right-hand side to integrate.
    pub fn is_dynamic(&self) -> bool {
        !matches!(&*self.backend, Backend::Static(_))
    }

    /// The state-variable names of the compiled right-hand side, in the
    /// flattened state-vector order. Empty for a static EsmProblem.
    pub fn state_variable_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Scalar(c) => c.state_variable_names().to_vec(),
            Backend::Array(c) => c.state_variable_names().to_vec(),
            Backend::Static(_) => Vec::new(),
        }
    }

    /// The parameter names of the compiled right-hand side. Empty for a static
    /// EsmProblem.
    pub fn parameter_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Scalar(c) => c.parameter_names().to_vec(),
            Backend::Array(c) => c.parameter_names().to_vec(),
            Backend::Static(_) => Vec::new(),
        }
    }

    /// The value-invention members this EsmProblem's build materialized.
    pub fn members(&self) -> &HashMap<String, Vec<i64>> {
        &self.build.members
    }

    /// The derived index-set extents this EsmProblem's build materialized.
    pub fn extents(&self) -> &HashMap<String, i64> {
        &self.build.extents
    }

    /// Provider keys that were deferred and fetched pre-sliced.
    pub fn gated_provider_keys(&self) -> &[String] {
        &self.build.gated_provider_keys
    }

    /// Take the build-observability record this EsmProblem collected.
    ///
    /// Only populated when [`ProblemOptions::inspect`] was set. This is the
    /// construction-time seam that replaced threading a `&mut BuildInspection`
    /// through the run.
    pub fn take_inspection(&self) -> BuildInspection {
        std::mem::take(&mut self.inspection.borrow_mut())
    }

    /// Re-arm the build-observability record to the state CONSTRUCTION leaves
    /// it in (empty).
    ///
    /// [`esm_problem`] initialises `inspection` empty and only [`solve`] fills
    /// it — and only on the array backend, which OVERWRITES rather than merges;
    /// [`Self::take_inspection`] DRAINS it. So a caller that solves one problem
    /// more than once (the inline-test runner, which memoises the build across
    /// consecutive tests that share it) must re-arm between solves, or the
    /// second read would see what the first left behind instead of what a
    /// rebuild would have produced. Idempotent, and a no-op on a problem that
    /// has never been read.
    pub(crate) fn reset_inspection(&self) {
        *self.inspection.borrow_mut() = BuildInspection::default();
    }

    /// Every build-time field this EsmProblem's construction materialized, keyed
    /// by observed name.
    pub fn observed_fields(&self) -> &HashMap<String, ArrayD<f64>> {
        &self.build.fields
    }

    /// The names of the OBSERVED VARIABLES [`observed_trajectory`] can report a
    /// trajectory for.
    ///
    /// Disjoint from [`Self::observed_field_names`] and answering a different
    /// question: those are constants the BUILD materialized, these vary along a
    /// solution. Empty on the array and static backends, which have no scalar
    /// observed graph to walk.
    pub fn observed_variable_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Scalar(c) => c.observed_variable_names().to_vec(),
            Backend::Array(_) | Backend::Static(_) => Vec::new(),
        }
    }

    /// The names of every build-time field [`observed_field`] can return,
    /// component-qualified — the spelling that resolves whatever the problem's
    /// component count, and the one to report to an author whose bare name was
    /// refused.
    pub fn observed_field_names(&self) -> Vec<String> {
        let model = self.model_name.as_deref().unwrap_or("");
        let mut names: Vec<String> = self
            .build
            .fields
            .keys()
            .chain(self.inspection.borrow().setup_arrays.keys())
            .map(|k| qualify(model, k))
            .collect();
        names.sort();
        names.dedup();
        names
    }
}

/// The callbacks declared on `prob` (§2.5.4).
///
/// Stable API in every simulation-capable binding, and for a specific reason:
/// a `callback` argument to [`solve`] REPLACES this set entirely, so without a
/// way to read it back, a EsmProblem-level callback would be impossible to extend.
/// See [`compose`].
pub fn callbacks(prob: &EsmProblem) -> &CallbackSet {
    &prob.callbacks
}

/// `key` qualified by the component path `model`, idempotently.
///
/// The two field maps an [`EsmProblem`] carries are keyed differently. The
/// build pipeline keys a field by the SELECTED MODEL's own variable name
/// (`E_PM25`, or `North.u` for a mounted subsystem), because it evaluates one
/// model's observed graph rather than the flattened document's; the state-free
/// static evaluation keys it by the FLATTENED name (`ISRM.E_PM25`), because
/// that is what `Compiled` produces. Qualifying the first spelling and leaving
/// the second alone puts both into the one namespace Julia and Python key
/// their build-time fields by, so `observed_field` answers the same spellings
/// in all three bindings.
fn qualify(model: &str, key: &str) -> String {
    let already = key == model
        || key
            .strip_prefix(model)
            .is_some_and(|rest| rest.starts_with('.'));
    if model.is_empty() || already {
        key.to_string()
    } else {
        format!("{model}.{key}")
    }
}

/// The component that owns a qualified name — everything before the final
/// segment, or `""` when the name is unqualified.
fn component_of(qualified: &str) -> &str {
    qualified.rsplit_once('.').map_or("", |(head, _)| head)
}

/// The distinct components owning `prob`'s build-time fields (API_SPEC §5.8).
///
/// A bare name is only resolvable when this holds exactly one: with two
/// mounted components a bare `u` designates `North.u` and `South.u` equally,
/// and answering with either is worse than refusing.
fn field_components(prob: &EsmProblem) -> std::collections::BTreeSet<String> {
    let model = prob.model_name.as_deref().unwrap_or("");
    let mut out = std::collections::BTreeSet::new();
    for k in prob.build.fields.keys() {
        out.insert(component_of(&qualify(model, k)).to_string());
    }
    for k in prob.inspection.borrow().setup_arrays.keys() {
        out.insert(component_of(&qualify(model, k)).to_string());
    }
    out
}

/// Outcome of applying §5.8's precedence to one namespace of stored keys.
enum NameResolution {
    /// The stored key `name` designates.
    Key(String),
    /// `name` is a bare name whose tail matches these keys (sorted), but the
    /// gate refused to bind one: a multi-component problem, or a second tail
    /// match within ONE component — where two keys cannot share a tail, so a
    /// second match means the component set was miscounted; refuse rather
    /// than pick.
    Ambiguous(Vec<String>),
    /// No rule matched.
    Miss,
}

/// The §5.8 name-resolution rule, shared by [`observed_field`] and the
/// observed-trajectory resolver, in precedence order:
///
/// 1. **Exact hit** — `name` is a stored key.
/// 2. **Component-qualified hit** — `name` is a stored key's [`qualify`]d
///    spelling (`ISRM.E_PM25` for the pipeline's `E_PM25`). Done as a strip
///    rather than a scan: `name` is the qualified spelling of key `k` exactly
///    when it is `model` + `.` + `k`. With an empty `model` the inner strip
///    fails and this is a no-op.
/// 3. **Bare name** — `name` carries no `.` and the problem has exactly ONE
///    component; it then resolves to the unique key with that tail.
///
/// A bare name whose tail matches but which rule 3's gate refuses comes back
/// as [`NameResolution::Ambiguous`] carrying every candidate, so a caller can
/// put the remedy in its diagnostic — the author has to qualify the name, and
/// cannot know which spellings exist without being told.
fn resolve_observed_key<'a>(
    keys: impl Iterator<Item = &'a String> + Clone,
    model: &str,
    single_component: bool,
    name: &str,
) -> NameResolution {
    if keys.clone().any(|k| k == name) {
        return NameResolution::Key(name.to_string()); // rule 1
    }
    if let Some(rest) = name.strip_prefix(model).and_then(|r| r.strip_prefix('.'))
        && keys.clone().any(|k| k == rest)
    {
        return NameResolution::Key(rest.to_string()); // rule 2
    }
    if name.contains('.') {
        return NameResolution::Miss; // rule 3 is for bare names only
    }
    let mut matches: Vec<&String> = keys
        .filter(|k| k.rsplit('.').next() == Some(name))
        .collect();
    matches.sort();
    if single_component && matches.len() == 1 {
        return NameResolution::Key(matches[0].clone());
    }
    if matches.is_empty() {
        NameResolution::Miss
    } else {
        NameResolution::Ambiguous(matches.into_iter().cloned().collect())
    }
}

/// The build-time field named `name`, from `prob`'s construction.
///
/// Resolution is the cross-binding rule of API_SPEC §5.8
/// ([`resolve_observed_key`]), in precedence order:
///
/// 1. **Exact hit** — `name` is a stored key.
/// 2. **Component-qualified hit** — `name` is a stored key's [`qualify`]d
///    spelling (`ISRM.E_PM25` for the pipeline's `E_PM25`).
/// 3. **Bare name** — `name` carries no `.`, and the problem has exactly ONE
///    component; it then resolves to the unique field with that tail.
///
/// A bare name against a MULTI-component problem is refused rather than bound
/// to an arbitrary candidate. Reads the build pipeline's fields, the state-free
/// static evaluation's fields, and — when [`ProblemOptions::inspect`] was set —
/// the array runtime's materialized setup arrays. One arity, `(prob, name)`,
/// in every binding.
pub fn observed_field(prob: &EsmProblem, name: &str) -> Result<ArrayD<f64>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let model = prob.model_name.as_deref().unwrap_or("");
    let components = field_components(prob);
    let single = components.len() == 1;

    if let NameResolution::Key(k) =
        resolve_observed_key(prob.build.fields.keys(), model, single, name)
    {
        return Ok(prob.build.fields[&k].clone());
    }
    let inspection = prob.inspection.borrow();
    if let NameResolution::Key(k) =
        resolve_observed_key(inspection.setup_arrays.keys(), model, single, name)
    {
        return Ok(inspection.setup_arrays[&k].clone());
    }
    // A bare name that WOULD have resolved but for the component gate gets the
    // remedy in the diagnostic: the author has to qualify it, and cannot know
    // which spellings exist without being told. (`Ambiguous` under a SINGLE
    // component — the miscounted-set refusal — keeps the generic error below,
    // as it always has.)
    if !single
        && let NameResolution::Ambiguous(matches) = resolve_observed_key(
            prob.build
                .fields
                .keys()
                .chain(inspection.setup_arrays.keys()),
            model,
            single,
            name,
        )
    {
        let mut cands: Vec<String> = matches.iter().map(|k| qualify(model, k)).collect();
        cands.sort();
        cands.dedup();
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_field: '{name}' is a bare name and this EsmProblem has {} \
                     components ({}); qualify it as one of: {}",
                components.len(),
                components
                    .iter()
                    .filter(|c| !c.is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
                cands.join(", ")
            )),
        ));
    }
    Err(SimulateError::Compile(
        crate::compile_error::CompileError::build_err(format!(
            "observed_field: '{name}' is not a build-time-evaluable observed of this EsmProblem"
        )),
    ))
}

/// The trajectory of the observed variable `name` over `sol`'s output grid.
///
/// The solution-aware half of [`observed_field`], and the answer to a question
/// neither argument can answer alone. An observed is a pure function of
/// `(state, params, t)`: `prob` holds the function — the topo-sorted observed
/// graph and the parameter bindings — and `sol` holds the arguments. That is
/// why this takes both, and why [`observed_field`] can only ever report fields
/// the BUILD materialized. A [`Solution`] carries state rows only, so an
/// observed of a model that does integrate has no other way out.
///
/// Named `observed_trajectory` rather than being a second arity of
/// `observed_field` because the return RANK differs: a field is the shape the
/// document declares, a trajectory is that shape with a time axis added. Two
/// ranks under one name is a contract a caller cannot read off the call. (A
/// binding that can overload — Julia, Python — may still spell it as an extra
/// arity of `observed_field`; API_SPEC §5.8 records the transliteration.)
///
/// Name resolution is §5.8's rule, the same one [`observed_field`] applies:
/// exact hit, then the component-qualified spelling, then a bare name only when
/// the problem has exactly one component.
///
/// Scalar backend only. A document on the array/spatial runtime materializes
/// its observeds per cell inside that runtime rather than through this graph,
/// and reporting a scalar trajectory for one would be a wrong answer rather
/// than a missing one; a static one has no trajectory at all and wants
/// [`observed_field`].
#[cfg(feature = "solve")]
pub fn observed_trajectory(
    prob: &EsmProblem,
    sol: &Solution,
    name: &str,
) -> Result<Vec<f64>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let one = [name.to_string()];
    // The bulk form omits what it cannot resolve; the singular one must not,
    // so an empty result becomes the diagnostic the resolver would have given.
    match observed_trajectories(prob, sol, &one)?.pop() {
        Some((_, values)) => Ok(values),
        None => {
            let compiled = match &*prob.backend {
                Backend::Scalar(c) => c,
                _ => unreachable!("the bulk form already refused a non-scalar backend"),
            };
            let declared = compiled.observed_variable_names();
            let model = prob.model_name.as_deref().unwrap_or("");
            Err(
                resolve_observed_name(declared, model, components_of(declared, model) == 1, name)
                    .expect_err("resolution failed, or the bulk form would have answered"),
            )
        }
    }
}

/// [`observed_trajectory`] for several names, in ONE pass over the output grid.
///
/// The graph is walked once per output time however many names are asked for,
/// so a caller wanting five observeds should ask once rather than five times.
///
/// **Tolerant where the singular form is strict**, and returns `(name, values)`
/// pairs so a caller can tell which is which. A name that is not an observed
/// variable — most often a STATE, which the caller already has in `sol` — is
/// omitted rather than failing the whole call. That is what a host asking "give
/// me whichever of these are observed" needs: a test harness reading a model's
/// authored assertions knows the variable names but not which kind each is, and
/// one state in the list must not cost it the other four answers.
///
/// The returned names are the spellings that were ASKED FOR, not the resolved
/// ones, so a caller can key its own lookup by them.
#[cfg(feature = "solve")]
pub fn observed_trajectories(
    prob: &EsmProblem,
    sol: &Solution,
    names: &[String],
) -> Result<Vec<(String, Vec<f64>)>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let compiled = match &*prob.backend {
        Backend::Scalar(c) => c,
        Backend::Array(_) => {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::build_err(
                    "observed_trajectory: this EsmProblem is on the array runtime,                               which materializes observeds per cell rather than through the                               scalar graph",
                ),
            ));
        }
        Backend::Static(reason) => {
            return Err(SimulateError::NotDynamic {
                details: format!(
                    "{reason}; a static document's results are read with observed_field"
                ),
            });
        }
    };

    let declared = compiled.observed_variable_names();
    let model = prob.model_name.as_deref().unwrap_or("");
    let single = components_of(declared, model) == 1;

    let (asked, resolved): (Vec<String>, Vec<String>) = names
        .iter()
        .filter_map(|name| {
            resolve_observed_name(declared, model, single, name)
                .ok()
                .map(|r| (name.clone(), r))
        })
        .unzip();

    let rows = compiled.observed_trajectories(&resolved, &sol.time, &sol.state, &prob.p)?;
    Ok(asked.into_iter().zip(rows).collect())
}

/// §5.8's precedence ([`resolve_observed_key`]), against a flat list of
/// declared observed names.
#[cfg(feature = "solve")]
fn resolve_observed_name(
    declared: &[String],
    model: &str,
    single_component: bool,
    name: &str,
) -> Result<String, SimulateError> {
    match resolve_observed_key(declared.iter(), model, single_component, name) {
        NameResolution::Key(k) => Ok(k),
        // A bare name that WOULD have resolved but for the component count gets
        // the remedy in the diagnostic — the author cannot qualify it without
        // being told which spellings exist.
        NameResolution::Ambiguous(matches) => Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_trajectory: '{name}' is a bare name and this EsmProblem has {}                          components; qualify it as one of: {}",
                components_of(declared, model),
                matches
                    .iter()
                    .map(|k| qualify(model, k))
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        )),
        NameResolution::Miss => Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "observed_trajectory: '{name}' is not an observed variable of this EsmProblem"
            )),
        )),
    }
}

#[cfg(feature = "solve")]
fn components_of(declared: &[String], model: &str) -> usize {
    declared
        .iter()
        .map(|k| component_of(&qualify(model, k)).to_string())
        .collect::<std::collections::BTreeSet<_>>()
        .len()
}

// =============================================================================
// remake
// =============================================================================

/// The substitutions [`remake`] applies. Every field is optional; an omitted
/// field is inherited unchanged.
#[derive(Debug, Clone, Default)]
pub struct Remake {
    /// Replacement parameter bindings, merged over the EsmProblem's.
    pub p: HashMap<String, f64>,
    /// Replacement initial-state bindings, merged over the EsmProblem's.
    pub u0: HashMap<String, f64>,
    /// A different integration interval.
    pub tspan: Option<(f64, f64)>,
    /// Replacement callbacks. `None` inherits the EsmProblem's set.
    pub callbacks: Option<CallbackSet>,
}

/// A NEW EsmProblem with `changes` applied and everything else shared (§2.5.5).
///
/// Does not mutate `prob`, and does not redo the parts of construction the
/// substitution cannot have invalidated: the compiled right-hand side, the
/// build-time fields and the materialized provider data are shared by `Rc`, not
/// rebuilt. A changed parameter value does not re-fetch provider data or
/// recompile.
///
/// **Refusal is deliberate.** A substitution the EsmProblem cannot honour without
/// a rebuild raises [`SimulateError::UnsubstitutableBinding`], naming the
/// binding and the class that makes it un-substitutable, rather than silently
/// rebuilding or silently ignoring it. Two classes refuse: a parameter that was
/// baked into the build (it is a load-time constant of the compiled RHS, not a
/// solver input), and a name that is not a parameter of the compiled system at
/// all.
pub fn remake(prob: &EsmProblem, changes: &Remake) -> Result<EsmProblem, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
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
                class: "baked into the build as a load-time constant — build a new EsmProblem"
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

    Ok(EsmProblem {
        doc: Rc::clone(&prob.doc),
        model_name: prob.model_name.clone(),
        precision: prob.precision.clone(),
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
        // ownership question out of `remake`'s way: a remade EsmProblem reads the
        // SAME forcing buffer, because the provider fetch is exactly the work
        // §2.5.5 forbids redoing. A EsmProblem with providers therefore cannot be
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

/// A EsmProblem plus a per-trajectory rewrite, and the family it stands for
/// (§2.5.8) — the canonical form for parameter sweeps, Monte Carlo over
/// declared distributions, and perturbed initial conditions.
pub struct EnsembleProblem<'a> {
    prob: &'a EsmProblem,
    trajectories: usize,
    #[allow(clippy::type_complexity)]
    rewrite: Box<dyn Fn(&EsmProblem, usize) -> Result<Remake, SimulateError> + 'a>,
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
    /// The rewrite returns a [`Remake`], not a EsmProblem, so every trajectory
    /// goes through the same refusal rules and shares the same compiled
    /// right-hand side.
    pub fn new(
        prob: &'a EsmProblem,
        trajectories: usize,
        rewrite: impl Fn(&EsmProblem, usize) -> Result<Remake, SimulateError> + 'a,
    ) -> Self {
        Self {
            prob,
            trajectories,
            rewrite: Box::new(rewrite),
        }
    }

    /// The base EsmProblem.
    pub fn problem(&self) -> &EsmProblem {
        self.prob
    }

    /// How many trajectories the family holds.
    pub fn trajectories(&self) -> usize {
        self.trajectories
    }

    /// The EsmProblem for trajectory `i`.
    pub fn trajectory(&self, i: usize) -> Result<EsmProblem, SimulateError> {
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

/// Build a [`EsmProblem`] (§2.5.2).
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
) -> Result<EsmProblem, SimulateError> {
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
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "reading {}: {e}",
                    path.display()
                )))
            })?;
            let raw: JsonValue = serde_json::from_str(&text).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "parsing {}: {e}",
                    path.display()
                )))
            })?;
            owned_json = Some(raw);
        }
        ProblemInput::Json(v) => owned_json = Some(v.clone()),
        ProblemInput::File(f) => owned_file = Some(f.clone()),
        ProblemInput::Flattened(f) => flat_only = Some(f),
    }

    // ---- (1b) The working precision, and the guard that arms it. ----------
    // `domain.element_type` (esm-spec §11.3). This has to be read from the RAW
    // input and armed BEFORE the build pipeline, not after the typed parse:
    // value invention, the pushdown rewrite and the build-time field
    // materialization all evaluate expressions, and a constant folded in
    // binary64 at build time would disagree with the same subexpression
    // evaluated in binary32 at run time.
    let prec = element_type_of(owned_json.as_ref(), owned_file.as_ref(), flat_only)?;
    // Per-variable overrides (`ModelVariable.element_type`, esm-spec §11.3.1)
    // are read from the same raw input and armed alongside the document's
    // precision, because the ingress sites below — and the provider fetches in
    // `prepare` — fill NAMED variables and must round each to ITS declared
    // precision, not to the document's. Empty for every document that declares
    // none, which is the inert path.
    let var_precisions = variable_element_types_of(
        owned_json.as_ref(),
        owned_file.as_ref(),
        flat_only,
        prec,
    )?;
    let _precision_guard = precision::enter_env(prec, std::rc::Rc::new(var_precisions));

    // Host-supplied numbers are the one class of value the evaluator does not
    // itself produce, so they are rounded ONCE here rather than on each of the
    // O(N) reads of them. Everything computed downstream is binary32 already,
    // every operation having rounded. Each is rounded to the precision of the
    // variable it binds: an override that spared a key column on the provider
    // path but not on the host-supplied one would be no exemption at all.
    if prec.is_f32() || precision::has_variable_overrides() {
        for (k, v) in opts.p.iter_mut() {
            *v = precision::of_variable(k).round(*v);
        }
        for (k, v) in opts.u0.iter_mut() {
            *v = precision::of_variable(k).round(*v);
        }
        for (k, a) in opts.const_arrays.iter_mut() {
            let kp = precision::of_variable(k);
            if kp.is_f32() {
                a.mapv_inplace(|x| kp.round(x));
            }
        }
    }

    // ---- (1c) Static precision inference, on the TYPED document. ---------
    // Propagate every `ModelVariable.element_type` over the equations and mark
    // the precision boundaries (esm-spec §11.3.1, `crate::precision_infer`).
    //
    // It runs on the TYPED form and BEFORE the build pipeline, which is the
    // only point that satisfies both constraints. Typed, because that is what
    // has `expression_templates` expanded and `$ref` imports resolved, so no
    // template body escapes the pass. Before the pipeline, because the pipeline
    // MATERIALIZES a relational document's whole observed graph — for a
    // state-free document that is the entire evaluation — and a marker
    // inserted after it would arrive too late to decide anything.
    //
    // Skipped entirely, not merely a no-op walk, for a document that declares
    // no per-variable element type.
    let mut inferred = false;
    if precision::has_variable_overrides()
        && let Some(f) = owned_file.as_mut()
        && let Some(models) = f.models.as_mut()
    {
        crate::precision_infer::annotate_models(models, prec).map_err(SimulateError::Compile)?;
        inferred = true;
    }

    // ---- (2) The deterministic build pipeline. ----------------------------
    // `mut` on wasm32 only in the sense that the pipeline that writes these is
    // native-only; the bindings themselves exist on both targets.
    let mut build = BuildProducts::default();
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut model_name = opts.model_name.clone();

    // A TYPED document is a legitimate input to the build pipeline, and it used
    // to be the one input shape that silently was not: the pipeline reads raw
    // JSON, so `ProblemInput::File` skipped it entirely — `build_providers`,
    // `const_arrays` and `pushdown_rewrite` were accepted and then DROPPED,
    // with no error, and the caller got a document evaluated against every
    // data-fed parameter's `default`. Re-serializing here routes it through the
    // same path `Json` takes; the typed form is dropped so step (3) re-parses
    // the PREPARED document rather than the authored one, exactly as the JSON
    // input does.
    //
    // `ProblemInput::Flattened` still cannot: a flattened system has no
    // document to rewrite. It is reachable only from inside this crate.
    #[cfg(not(target_arch = "wasm32"))]
    if owned_json.is_none()
        && let Some(file) = owned_file.as_ref().filter(|_| wants_build_pipeline(&opts))
    {
        owned_json = Some(serde_json::to_value(file).map_err(|e| {
            SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                "re-serializing the typed document for the build pipeline: {e}"
            )))
        })?);
        owned_file = None;
    }

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
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "re-serializing the prepared document: {e}"
                )))
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
                            crate::compile_error::CompileError::build_err(format!(
                                "typed parse of the prepared document: {e}"
                            )),
                        ));
                    }
                }
            }
        }
    }

    // ---- (3b) Static precision inference, for a RAW-JSON input. -----------
    // Stage (1c) already ran when the caller handed in a typed document. A raw
    // JSON input has no typed form until stage (3) — this is its first chance,
    // and the pass has to happen before stage (4) lowers the equations.
    if !inferred
        && precision::has_variable_overrides()
        && let Some(f) = owned_file.as_mut()
        && let Some(models) = f.models.as_mut()
    {
        crate::precision_infer::annotate_models(models, prec).map_err(SimulateError::Compile)?;
    }

    // ---- (4) Compile the right-hand side. ---------------------------------
    let backend = compile_backend(
        owned_file.as_ref(),
        flat_only,
        model_name.as_deref(),
        opts.compile,
    )?;

    // ---- (4b) State-free static evaluation. -------------------------------
    // A document that declares no differential equations has nothing to
    // integrate — `solve` refuses it with `NotDynamic` — but its whole content
    // is its observed graph, which is exactly what `observed_field` reads. This
    // evaluates that graph so the read works with NO options set, which is what
    // a stable-API function has to do (API_SPEC §5.8): before this, reaching a
    // state-free document's own results through the Rust binding meant knowing
    // to pass `build_pipeline: true` AND to hand in raw JSON rather than a
    // typed document, neither of which the surface contract mentions.
    //
    // Skipped when the build pipeline already produced fields, so the ISRM /
    // pushdown path keeps its own (model-local) keys untouched.
    if build.fields.is_empty()
        && let Backend::Static(_) = &backend
    {
        let t0 = opts.sample_time.unwrap_or(tspan.0);
        build.fields = static_observed_fields(owned_file.as_ref(), flat_only, &opts.p, t0);
    }

    // ---- (5) Bind and CONST-materialize the run-time providers. -----------
    #[cfg(not(target_arch = "wasm32"))]
    let (refresh, discrete_forcing, refresh_boundaries) =
        bind_providers(&backend, &mut opts, tspan)?;

    let prob = EsmProblem {
        doc: Rc::new(owned_json.unwrap_or(JsonValue::Null)),
        model_name,
        precision: precision::Env::capture(),
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

/// Read `domain.element_type` off whichever form of the input the caller gave
/// (esm-spec §11.3).
///
/// The raw-JSON branch reads the field textually because it runs *before* the
/// typed parse — the build pipeline needs the precision armed already.
///
/// # Errors
///
/// [`SimulateError::Compile`] wrapping
/// [`crate::compile_error::CompileError::UnsupportedElementType`] for a
/// spelling that is neither `"Float64"` nor `"Float32"`. An unrecognised
/// element type is not silently binary64.
fn element_type_of(
    raw: Option<&JsonValue>,
    file: Option<&EsmFile>,
    flat: Option<&FlattenedSystem>,
) -> Result<Precision, SimulateError> {
    let named = raw
        .and_then(|v| v.get("domain"))
        .and_then(|d| d.get("element_type"))
        .and_then(JsonValue::as_str)
        .map(str::to_string)
        .or_else(|| {
            file.and_then(|f| f.domain.as_ref())
                .and_then(|d| d.element_type.clone())
        })
        .or_else(|| {
            flat.and_then(|f| f.domain.as_ref())
                .and_then(|d| d.element_type.clone())
        });
    Precision::from_element_type(named.as_deref()).map_err(SimulateError::Compile)
}

/// Collect every `ModelVariable.element_type` the document declares
/// (esm-spec §11.3.1), keyed by both the bare and the `Model.name` spelling.
///
/// Read off whichever form of the input the caller gave, and — like
/// [`element_type_of`] — off the RAW JSON textually where there is one,
/// because it has to be armed before the build pipeline runs.
///
/// Returns an EMPTY table for the overwhelmingly common document that declares
/// none, which is what keeps the whole per-variable path inert.
///
/// # Errors
///
/// [`SimulateError::Compile`] wrapping
/// [`crate::compile_error::CompileError::UnsupportedElementType`] for a
/// spelling that is neither `"Float64"` nor `"Float32"`.
fn variable_element_types_of(
    raw: Option<&JsonValue>,
    file: Option<&EsmFile>,
    flat: Option<&FlattenedSystem>,
    document: Precision,
) -> Result<precision::VarPrecisions, SimulateError> {
    let mut out = precision::VarPrecisions::default();
    let mut record = |model: Option<&str>, name: &str, spelling: Option<&str>| {
        match Precision::from_element_type(spelling) {
            Ok(p) => {
                out.insert(model, name, p);
                Ok(())
            }
            Err(e) => Err(SimulateError::Compile(e)),
        }
    };
    if let Some(models) = raw.and_then(|v| v.get("models")).and_then(JsonValue::as_object) {
        for (mname, model) in models {
            let Some(vars) = model.get("variables").and_then(JsonValue::as_object) else {
                continue;
            };
            for (vname, var) in vars {
                let Some(et) = var.get("element_type").and_then(JsonValue::as_str) else {
                    continue;
                };
                record(Some(mname), vname, Some(et))?;
            }
        }
        return Ok(out);
    }
    if let Some(models) = file.and_then(|f| f.models.as_ref()) {
        for (mname, model) in models {
            for (vname, var) in &model.variables {
                let Some(et) = var.element_type.as_deref() else {
                    continue;
                };
                record(Some(mname), vname, Some(et))?;
            }
        }
        return Ok(out);
    }
    // A flattened system carries namespaced names and no per-variable element
    // types of its own; nothing to collect. `document` stays the answer for
    // every name.
    let _ = (flat, document);
    Ok(out)
}

/// Reject integrating a Float32 document.
///
/// The ODE/DAE solver (diffsol) is instantiated over `f64` — its step-size
/// control, error norms and Newton iteration are binary64 and have no binary32
/// form here. Integrating a Float32 document would therefore produce an answer
/// whose right-hand side was binary32 and whose time-stepping was binary64,
/// with nothing in the result to say so. Per esm-spec §11.3 that is an error
/// naming the construct, not a partial honouring of the declaration.
///
/// Algebraic, observed and relational evaluation — everything `observed_field`
/// and the inline `tests` blocks read — is unaffected and runs in binary32.
fn reject_f32_integration(prob: &EsmProblem) -> Result<(), SimulateError> {
    // Only a system that actually INTEGRATES is affected. A model whose every
    // equation is algebraic — the relational / lookup-table shape this mode
    // exists for — is evaluated entirely by the (binary32) expression
    // evaluator, and `Compile::Always` giving it a non-static backend does not
    // make it dynamic.
    let integrates = match &*prob.backend {
        Backend::Static(_) => false,
        Backend::Scalar(c) => c.has_differential_equations(),
        Backend::Array(c) => c.has_differential_equations(),
    };
    if prob.precision.is_f32() && integrates {
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::Float32Unsupported {
                construct: "time integration of a dynamic model".to_string(),
                reason: "the ODE/DAE solver is instantiated over binary64 (step-size control,                          error norms and the Newton solve), so the trajectory would be                          binary64 even though the right-hand side is binary32"
                    .to_string(),
            },
        ));
    }
    Ok(())
}

#[cfg(not(target_arch = "wasm32"))]
fn wants_build_pipeline(opts: &ProblemOptions) -> bool {
    opts.build_pipeline
        || opts.pushdown_rewrite
        || !opts.build_providers.is_empty()
        || !opts.const_arrays.is_empty()
}

/// Evaluate a state-free system's observed graph at `t0`.
///
/// The build-time half of [`observed_field`] for a document with no
/// differential equations. `Compiled` has already topologically ordered and
/// index-resolved the flattened observeds, so this is one interpreter pass
/// over them against an EMPTY state vector — no solver, no build pipeline, and
/// no dependence on how the caller spelled its input.
///
/// Keys are FLATTENED names (`Sites.North.u`), matching Julia's
/// `BuildInspection.observed_exprs` and Python's `static_observed_values`.
///
/// **Tolerant by construction.** A system the scalar interpreter cannot lower
/// — an array op, a `v1`-unsupported feature, a parameter with no default —
/// yields NO fields rather than failing the build. Construction was not asked
/// to compile anything here (`Compile::Auto` chose `Backend::Static`), so a
/// failure to evaluate must surface as `observed_field` reporting the name it
/// cannot answer, not as a document that will not build. Python makes the same
/// call for the same reason (`problem.py`, the scalar no-state branch).
fn static_observed_fields(
    file: Option<&EsmFile>,
    flat_only: Option<&FlattenedSystem>,
    p: &HashMap<String, f64>,
    t0: f64,
) -> HashMap<String, ArrayD<f64>> {
    let owned_flat;
    let flat = match (flat_only, file) {
        (Some(f), _) => f,
        (None, Some(file)) => match crate::flatten::flatten(file) {
            Ok(f) => {
                owned_flat = f;
                &owned_flat
            }
            Err(_) => return HashMap::new(),
        },
        (None, None) => return HashMap::new(),
    };
    // A system WITH state is not state-free evaluable: an observed may read
    // state, and there is none to read. Reachable when `model_name` selects an
    // ODE-free model out of a document that has ODEs elsewhere, since
    // `flatten` is document-wide.
    if !flat.state_variables.is_empty() {
        return HashMap::new();
    }
    let Ok(compiled) = Compiled::from_flattened(flat) else {
        return HashMap::new();
    };
    let Ok(values) = compiled.evaluate_static_observeds(p, t0) else {
        return HashMap::new();
    };
    values
        .into_iter()
        .map(|(name, v)| {
            (
                name,
                ArrayD::from_shape_vec(ndarray::IxDyn(&[1]), vec![v]).unwrap(),
            )
        })
        .collect()
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
        // Same rule the typed-document branch applies below, on the input that
        // states it most directly: a flattened system with no state variables
        // has nothing to integrate. Without this, `ProblemInput::Flattened`
        // was the one input shape that got a "dynamic" scalar backend for a
        // state-free system — `solve` then failed inside the solver instead of
        // reporting `NotDynamic`, and `observed_field` saw no static fields.
        if mode == Compile::Auto && flat.state_variables.is_empty() {
            return Ok(Backend::Static(
                "the flattened system declares no state variables".to_string(),
            ));
        }
        return Ok(Backend::Scalar(Rc::new(Compiled::from_flattened(flat)?)));
    }
    let Some(file) = file else {
        if mode == Compile::Always {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::build_err("no typed document to compile"),
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
/// EsmProblem, and [`observed_field`] still reads its build-time products, but
/// [`solve`] on it raises [`SimulateError::NotDynamic`] rather than handing
/// back an empty trajectory.
pub(crate) fn has_differential_equations(file: &EsmFile, model_name: Option<&str>) -> bool {
    // A REACTION SYSTEM is differential, and reading only `models` said it was
    // not. Reactions lower to `D(species, t) = …` during flattening, so a
    // document whose whole content is a `reaction_systems` block has no models
    // AT ALL until that happens — and this function runs before it. Every pure
    // chemistry document in the wild is that shape (`pollu`, `superfast`,
    // `geoschem_fullchem`), and `Compile::Auto` was calling each of them static
    // and then refusing to solve twenty-five differential equations with
    // `NotDynamic { "the document declares no differential equations" }`.
    //
    // A system with no reactions is genuinely not differential — it lowers to
    // nothing — so the check is for reactions rather than for the block.
    if let Some(systems) = file.reaction_systems.as_ref()
        && systems
            .iter()
            .filter(|(name, _)| model_name.is_none_or(|want| want == name.as_str()))
            .any(|(_, rs)| !rs.reactions.is_empty())
    {
        return true;
    }
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
/// **`opts.callback` REPLACES the EsmProblem's callback set entirely.** It does
/// not append, merge or wrap. To extend rather than replace, read the set back
/// with [`callbacks`] and [`compose`] explicitly. See §2.5.4 for why
/// replacement is the safe default.
///
/// **`opts.output_observed` adds rows.** A [`Solution`] carries state rows by
/// default; a name listed there is appended as extra rows in the flat cell-key
/// spelling the state uses, which is what [`crate::derive_output_plan`] needs
/// to write that field alongside the state (RFC decision 8).
#[cfg(feature = "solve")]
pub fn solve(prob: &EsmProblem, opts: &SolveOptions) -> Result<Solution, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    reject_f32_integration(prob)?;
    let effective = effective_options(prob, opts);
    match &*prob.backend {
        Backend::Static(reason) => Err(SimulateError::NotDynamic {
            details: reason.clone(),
        }),
        Backend::Scalar(compiled) => {
            let mut sol = compiled.solve(prob.tspan, &prob.p, &prob.u0, &effective)?;
            append_requested_observeds(prob, &mut sol, &effective.output_observed);
            Ok(sol)
        }
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

/// Append [`SolveOptions::output_observed`] to a SCALAR-backend solution as
/// extra rows (the array runner does its own, per cell, inside the driver).
///
/// Every scalar-graph observed is 0-D, so each contributes exactly one
/// bracket-free row — the cell-key spelling of a scalar, which
/// [`crate::derive_output_gridding`] reads back as a `shape == []` variable.
///
/// Silent about a name it cannot resolve, and about one already carried as a
/// state row: [`crate::derive_output_plan`] is the layer that can see both the
/// state slots and the request list, so it owns the diagnostic
/// ([`crate::OutputError::UnknownObserved`]).
#[cfg(feature = "solve")]
fn append_requested_observeds(prob: &EsmProblem, sol: &mut Solution, requested: &[String]) {
    if requested.is_empty() {
        return;
    }
    // Tolerant by contract: a request naming a STATE (which the caller already
    // has) is omitted from the result rather than failing the whole call.
    let Ok(rows) = observed_trajectories(prob, sol, requested) else {
        return;
    };
    for (asked, values) in rows {
        // The returned key is the spelling that was ASKED FOR; it is the row
        // name because it is also what the caller will name in the output
        // request, and the plan's both-ways match binds the two either way.
        if sol.state_variable_names.contains(&asked) {
            continue;
        }
        sol.state_variable_names.push(asked);
        sol.state.push(values);
    }
}

/// Fold the EsmProblem's callbacks (or the run's REPLACEMENT set) and the
/// extension-seam progress observer into the one per-step hook `run_solver`
/// already drives.
fn effective_options(prob: &EsmProblem, opts: &SolveOptions) -> SolveOptions {
    // §2.5.4: the run's `callback` REPLACES the EsmProblem's set. It does not
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
/// (`diffsol`'s solver borrows its `OdeSolverProblem`, so a EsmProblem-owning
/// integrator that also owns a live solver would be self-referential. Restarting
/// per grid interval is the safe-Rust way to expose the lifecycle, and it is
/// the mechanism already in production here for segmented refresh.)
#[cfg(feature = "solve")]
pub struct Integrator<'a> {
    prob: &'a EsmProblem,
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
pub fn init<'a>(
    prob: &'a EsmProblem,
    opts: &SolveOptions,
) -> Result<Integrator<'a>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    reject_f32_integration(prob)?;
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
        // Re-arm the document's working precision (esm-spec §11.3); a stepping
        // caller reaches the RHS without passing back through `solve`.
        let _precision_guard = self.prob.precision.enter();
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
