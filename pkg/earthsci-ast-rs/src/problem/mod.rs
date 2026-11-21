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

use crate::classification::DeclaredRank;
use crate::flatten::FlattenedSystem;
use crate::precision::{self, Precision};
#[cfg_attr(not(feature = "solve"), allow(unused_imports))]
use crate::simulate::Solution;
use crate::simulate::{Flow, Progress, ProgressFn, SimulateError, SolveOptions};
use crate::types::EsmFile;
use crate::types::HasSubsystems;

use crate::simulate_array::{ArrayCompiled, BuildInspection};

mod observed;
mod remake;
mod report;
mod solve;
mod supplied;

pub use observed::*;
pub use remake::*;
use report::*;
pub use solve::*;
#[cfg(not(target_arch = "wasm32"))]
pub(crate) use supplied::provider_key_error;
use supplied::*;

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
pub enum Rhs {
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

/// The pattern rewrites the tape compilers (`native`, `xla`) apply to the
/// expanded expression tree: each recognises one small algebraic shape and
/// lowers it to a faster instruction with the same bits as the lowering it
/// replaces. Every rewrite is on by default. Turning one off changes the
/// program a compiler builds, never what it computes: it is the seam an A/B
/// check or benchmark of the rewrite uses.
#[doc(hidden)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub struct CompilerRewrites {
    /// The counted bracket (issue #588): a rank-0 `faq` summing
    /// `ifelse(axis[k] REL x, 1, 0)` over one contracted index, `REL` one of
    /// `<= < >= >`, lowered to one count of the axis window instead of the
    /// fold.
    pub count_fold: bool,
}

impl CompilerRewrites {
    /// Every rewrite on: the default.
    pub const ALL: CompilerRewrites = CompilerRewrites { count_fold: true };
}

impl Default for CompilerRewrites {
    fn default() -> Self {
        CompilerRewrites::ALL
    }
}

/// Which strategy builds a Problem's right-hand side (API_SPEC §5.8,
/// esm-libraries-spec §2.5.10).
///
/// The vocabulary is CLOSED and the same in every binding. A value this
/// binding does not provide is REFUSED — never answered by quietly selecting
/// another one, because the point of naming a compiler is that the caller
/// knows which one ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Compiler {
    /// The universally fast option with no heavy external dependency, and the
    /// default for that reason: the array runtime's TAPE, for every document
    /// whatever its shape — never a routing decision taken on document
    /// content.
    ///
    /// **Strict.** A rule the tape cannot lower is a construction error naming
    /// the rule and the deepest decline reason
    /// ([`crate::compile_error::CompileError::CompilerRefusedRule`]), not a
    /// quiet demotion to the per-cell oracle.
    ///
    /// It covers the whole evaluable core. The only documents it may refuse
    /// are those carrying a construct outside its scope, each refused by name:
    /// events, implicit equations and SDE noise (`unsupported_construct`) and
    /// a spatial operator with no discretization rule (`unlowered_operator`,
    /// refused under every compiler). Every compiler-driven conformance tier
    /// requires `native` for every fixture, so any other refusal is a defect
    /// in this crate.
    #[default]
    Native,
    /// The reference, and only the reference: the array runtime with the tape
    /// off, so every rule is evaluated by the
    /// per-cell oracle. Complete over the evaluable core, and carrying no
    /// performance promise of any kind. A caller selects it to CHECK another
    /// compiler, not to run a model.
    Interpreter,
    /// StableHLO through XLA: the specialty compiler that needs a heavy
    /// external dependency to exist at all.
    ///
    /// The tape is lowered to an `rhs(u, p, t) -> du` XLA computation
    /// (`crate::simulate_array::tape::xla_emit`) and run through PJRT
    /// (`crate::xla_runtime`), so the Problem's right-hand side — and the
    /// finite-difference Jacobian an implicit solve differences out of it —
    /// ARE the compiled executable. The passes that are not the right-hand
    /// side (the build-time materialization of constants and static
    /// observeds, the per-segment seed, the inspection snapshot, and the
    /// observeds reported at output times) are served from the SAME tape the
    /// emitter was built from, because the emitted program's only output is
    /// `du`. That is one evaluator, not two.
    ///
    /// **Strict twice over, and never a fallback.** A rule the tape cannot
    /// lower and an instruction the emitter cannot lower are both
    /// [`crate::compile_error::CompileError::CompilerRefusedRule`] at
    /// construction, naming the rule and the reason; neither demotes to the
    /// tape interpreter or to the per-cell oracle.
    ///
    /// It needs the `xla` Cargo feature AND a usable XLA runtime in this
    /// process (an unpacked `xla_extension` release — see
    /// `scripts/fetch-xla-extension.sh`). Without either, `esm_problem`
    /// answers [`crate::SimulateError::CompilerUnavailable`], never a quiet
    /// substitution.
    Xla,
    /// A ModelingToolkit system. Julia only; refused here with
    /// `compiler_unavailable`.
    Mtk,
    /// A lambdified SymPy scalar right-hand side. Python only; refused here
    /// with `compiler_unavailable`.
    Sympy,
}

impl Compiler {
    /// The closed vocabulary's spelling of this value — the one a diagnostic,
    /// a CLI argument and a conformance manifest all use.
    pub fn as_str(self) -> &'static str {
        match self {
            Compiler::Native => "native",
            Compiler::Interpreter => "interpreter",
            Compiler::Xla => "xla",
            Compiler::Mtk => "mtk",
            Compiler::Sympy => "sympy",
        }
    }

    /// Parse a vocabulary member. `None` for anything outside it — the caller
    /// raises `compiler_unknown`, which is a different failure from
    /// `compiler_unavailable`.
    pub fn parse(name: &str) -> Option<Compiler> {
        match name {
            "native" => Some(Compiler::Native),
            "interpreter" => Some(Compiler::Interpreter),
            "xla" => Some(Compiler::Xla),
            "mtk" => Some(Compiler::Mtk),
            "sympy" => Some(Compiler::Sympy),
            _ => None,
        }
    }

    /// [`Self::parse`] with the `compiler_unknown` diagnostic (esm-spec
    /// §9.6.6) already written, for the entry points that take the compiler as
    /// TEXT — the CLI flag, the wasm handle, a conformance adapter.
    ///
    /// One wording and one place the closed vocabulary is listed: a value
    /// outside it is a different failure from one inside it this binding
    /// cannot provide, and a caller who conflates them cannot tell a typo from
    /// a missing runtime.
    pub fn parse_named(name: &str) -> Result<Compiler, String> {
        Compiler::parse(name).ok_or_else(|| {
            format!(
                "{}: '{name}' is not a compiler. The vocabulary is closed: {}",
                crate::diagnostic::codes::COMPILER_UNKNOWN,
                Compiler::vocabulary()
                    .iter()
                    .map(|c| c.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })
    }

    /// Whether this compiler is STRICT: a rule it cannot express is a
    /// construction error naming the rule, never a quiet demotion to a slower
    /// evaluator (API_SPEC §5.8, "The default is `native`, and it is strict").
    ///
    /// Both of the values this binding implements over the tape are strict —
    /// `native`, which is the tape, and `xla`, which is the emitter over it —
    /// and they are strict for the same reason: a compiler either runs the
    /// whole document or names what it refused. `interpreter` is not strict
    /// because it declines nothing it can evaluate; it IS the fallback the
    /// other two refuse to take.
    pub fn is_strict(self) -> bool {
        matches!(self, Compiler::Native | Compiler::Xla)
    }

    /// Every member, in the order API_SPEC §5.8 tabulates them.
    pub fn vocabulary() -> &'static [Compiler] {
        &[
            Compiler::Native,
            Compiler::Interpreter,
            Compiler::Xla,
            Compiler::Mtk,
            Compiler::Sympy,
        ]
    }
}

impl std::fmt::Display for Compiler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Where ONE rule of a Problem landed, and at what cadence (API_SPEC §5.8,
/// "Every Problem reports what ran").
#[derive(Clone, Debug)]
pub struct CompilerRuleReport {
    /// The rule — an equation or an observed — component-qualified, the same
    /// spelling [`observed_field`] resolves and a refusal names.
    pub rule: String,
    /// `"observed"` or `"state derivative"` for a rule of the compiled model.
    /// The evaluations construction performs OUTSIDE that rule set are
    /// reported too, under their own kinds: `"build-time observed"` and
    /// `"value invention"` (the build pipeline), and `"initial condition"` and
    /// `"initial-condition scope"` (a field `ic` and the state-free observeds
    /// it reads).
    pub kind: &'static str,
    /// The cadence tier the rule runs at: `"const"` (once per solve, at
    /// setup), `"discrete"` (once per refresh segment) or `"continuous"`
    /// (every right-hand-side call). The tier is the cost story: a decline at
    /// `const` costs once, the same decline at `continuous` costs per step.
    pub cadence: &'static str,
    /// Where the rule landed: `"taped"`, `"xla"` (lowered from the tape into
    /// the compiled XLA program, under [`Compiler::Xla`]), `"fallback"` (the
    /// per-cell oracle beneath the tape, reachable only outside a strict
    /// compiler), or `"oracle"` (every rule under [`Compiler::Interpreter`],
    /// by design). An evaluation outside the compiled rule set is
    /// `"vectorized"` when the reference evaluator evaluated it over whole
    /// arrays with no cell walked, `"taped"` when a standalone tape did
    /// (what a strict compiler does with one the reference evaluator would
    /// walk per cell), and `"oracle"` under the interpreter. A
    /// `"value invention"` row is `"relational"`: the producer's member set,
    /// computed once at setup by the relational engine from build-time factors
    /// (CONFORMANCE_SPEC §5.7.6 keeps that engine off the hot path), under
    /// every compiler alike. It is neither the oracle nor a fallback, so a
    /// build that succeeds under a strict compiler still has
    /// [`CompilerReport::n_oracle`] `== 0`.
    pub tier: &'static str,
    /// For a `"fallback"`, the DEEPEST decline reason reached while trying to
    /// lower the rule; for an `"oracle"` evaluation outside the compiled rule
    /// set, why it was walked per cell. `None` otherwise.
    pub reason: Option<String>,
}

/// What built a Problem's right-hand side, per rule (API_SPEC §5.8).
///
/// The names and their meanings are stable surface; the record's exact shape
/// is per-binding and is deliberately not pinned across the five.
///
/// **Fusion is reported per PROGRAM, not per rule.** The tape's Step-4 fusion
/// pass merges instructions across rule boundaries and the fused program keeps
/// no rule attribution, so a `tier` of `"taped"` covers both a rule that runs
/// as discrete instructions and one absorbed into a fused group;
/// [`Self::fused_groups`] and [`Self::fused_instructions`] report the fusion
/// at the level the tape actually tracks it.
#[derive(Clone, Debug)]
pub struct CompilerReport {
    compiler: Compiler,
    rules: Vec<CompilerRuleReport>,
    fused_groups: usize,
    fused_instructions: usize,
}

impl CompilerReport {
    /// The report of a Problem with no right-hand side: no rules, because no
    /// compiler was asked to build anything.
    fn empty(compiler: Compiler) -> CompilerReport {
        CompilerReport {
            compiler,
            rules: Vec::new(),
            fused_groups: 0,
            fused_instructions: 0,
        }
    }

    /// The compiler that built the Problem.
    pub fn compiler(&self) -> Compiler {
        self.compiler
    }

    /// Every rule, in program order: the evaluations construction performs
    /// outside the compiled model (the build pipeline's, then a state-free
    /// document's observeds, then the field initial conditions), then the
    /// compiled model's observed rules in dependency order, then its state
    /// derivatives. A state-free document's observeds are here too: it has no
    /// right-hand side, but its observed graph is still evaluated by the
    /// compiler the Problem names.
    pub fn rules(&self) -> &[CompilerRuleReport] {
        &self.rules
    }

    /// How many rules landed on the tape.
    pub fn n_taped(&self) -> usize {
        self.rules.iter().filter(|r| r.tier == "taped").count()
    }

    /// How many rules were lowered out of the tape into the compiled XLA
    /// program. Non-zero only under [`Compiler::Xla`], where it is every rule
    /// — the build refuses the document otherwise.
    pub fn n_xla(&self) -> usize {
        self.rules.iter().filter(|r| r.tier == "xla").count()
    }

    /// How many rules landed on the per-cell oracle — as a fallback beneath
    /// the tape, or, under [`Compiler::Interpreter`], by design.
    ///
    /// Counts the two oracle tiers by NAME rather than everything that is not
    /// `"taped"`: an `"xla"` rule is compiled, and counting it here would
    /// report the fastest tier in the crate as the slowest.
    pub fn n_oracle(&self) -> usize {
        self.rules
            .iter()
            .filter(|r| matches!(r.tier, "oracle" | "fallback"))
            .count()
    }

    /// How many evaluations outside the compiled rule set the reference
    /// evaluator served over whole arrays, walking no cell (tier
    /// `"vectorized"`).
    pub fn n_vectorized(&self) -> usize {
        self.rules.iter().filter(|r| r.tier == "vectorized").count()
    }

    /// Fused instruction groups in the compiled program. `0` under
    /// [`Compiler::Interpreter`], which compiles no program.
    pub fn fused_groups(&self) -> usize {
        self.fused_groups
    }

    /// Instructions absorbed into those groups.
    pub fn fused_instructions(&self) -> usize {
        self.fused_instructions
    }
}

impl std::fmt::Display for CompilerReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "compiler {}: {} rules, {} taped, {} on the per-cell oracle",
            self.compiler,
            self.rules.len(),
            self.n_taped(),
            self.n_oracle()
        )?;
        if self.n_xla() > 0 {
            write!(f, ", {} lowered into the XLA program", self.n_xla())?;
        }
        if self.n_vectorized() > 0 {
            write!(f, ", {} evaluated over whole arrays", self.n_vectorized())?;
        }
        let n_relational = self.rules.iter().filter(|r| r.tier == "relational").count();
        if n_relational > 0 {
            write!(f, ", {n_relational} by the relational engine at setup")?;
        }
        if self.fused_groups > 0 {
            write!(
                f,
                "; {} fused groups absorbing {} instructions",
                self.fused_groups, self.fused_instructions
            )?;
        }
        Ok(())
    }
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
    /// Select one model when the document holds several. `None` builds the
    /// whole document: one model as itself, several as one dot-namespaced
    /// (`Model.var`) system, on the build pipeline as on the compile path.
    pub model_name: Option<String>,
    /// Metaparameter bindings closed at load (esm-spec §9.7.6 site 4).
    pub metaparameters: BTreeMap<String, i64>,
    /// Base path anchoring relative `{ref}`s.
    pub base_path: Option<PathBuf>,
    /// Callbacks declared on the EsmProblem (§2.5.4).
    pub callbacks: CallbackSet,
    /// Whether to compile a right-hand side. See [`Rhs`].
    pub rhs: Rhs,
    /// WHICH strategy builds the right-hand side (§2.5.10). `None` is
    /// [`Compiler::Native`], and `native` is STRICT: a rule it cannot express
    /// is a construction error, not a quiet demotion.
    ///
    /// `Option` rather than a bare `Compiler` so that "the caller said
    /// nothing" and "the caller asked for native" stay distinguishable in a
    /// `ProblemOptions` a test prints; they build identically.
    pub compiler: Option<Compiler>,
    /// The pattern rewrites the tape compilers apply (every one on by
    /// default); ignored by [`Compiler::Interpreter`], which builds no tape.
    /// An A/B seam for checking and timing a rewrite, outside the API
    /// manifest.
    #[doc(hidden)]
    pub rewrites: CompilerRewrites,

    /// Opt in to the automatic projection-pushdown desugar. Turning this on
    /// also turns the build pipeline on.
    #[cfg(not(target_arch = "wasm32"))]
    pub pushdown_rewrite: bool,
    /// Data providers, keyed by the parameter each feeds
    /// ([`crate::provider::DataProvider`]). A key spells the parameter as a
    /// `p` key may (esm-spec §6.6.2): its full
    /// name (`Fed.s`), its bare name (`s`) or a partial qualification. An
    /// exact key wins over the others for the same parameter, whose providers
    /// are not read; two non-exact keys for one parameter, an ambiguous key,
    /// and a provider beside a [`Self::const_arrays`] entry for the same
    /// parameter are refused. A key that designates no parameter, names a
    /// state or observed variable, or is read by a `variable_map` coupling is
    /// used as given.
    ///
    /// When the build pipeline is asked for ([`Self::build_pipeline`] or
    /// [`Self::pushdown_rewrite`]), it consumes every CONST provider (one with
    /// no refresh times): its key is then
    /// `"<ModelPath>.<param>"`, a gate defers its fetch past value invention,
    /// and its extent may close a metaparameter. Otherwise CONST providers
    /// are materialized ONCE, here, at construction — the "gated fetch"
    /// §2.5.2 puts in the build half. DISCRETE providers are
    /// sampled once at construction too, after every construction check, at
    /// [`Self::sample_time`] (the record in effect there, see
    /// [`crate::provider::RefreshExecutor::sample_at`]), so the Problem's
    /// forcing, and the default forcing set of [`crate::rhs_program`], hold
    /// their data before any solve. A parameter whose provider delivers
    /// nothing there holds its declared default until the provider first
    /// delivers. Their refresh times inside `tspan` are the boundaries
    /// [`solve`] segments the integration on: a solve samples them at its own
    /// start and refreshes them at each boundary, with or without `saveat`.
    #[cfg(not(target_arch = "wasm32"))]
    pub providers: HashMap<String, Box<dyn crate::provider::DataProvider>>,
    /// Constant arrays injected into the build-time evaluation scope.
    #[cfg(not(target_arch = "wasm32"))]
    pub const_arrays: HashMap<String, ArrayD<f64>>,
    /// Run the deterministic build pipeline (it is on automatically when
    /// `pushdown_rewrite` or `const_arrays` is set). Set, or with
    /// `pushdown_rewrite`, it consumes the CONST [`Self::providers`].
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

    /// The DATA-FED parameters (esm-spec §5.4 `update: {kind: "data"}`) whose
    /// ingested values [`observed_field`] must be able to read back, spelled
    /// as `observed_field` would be called (exact, component-qualified, or
    /// bare). Empty by default.
    ///
    /// The build pipeline's ingested tables can be hundreds of MB, so the
    /// Problem keeps only what something reads: a column the right-hand side
    /// reads is MOVED into the forcing buffer, a column named here is kept
    /// (and cloned only when the right-hand side reads it too), and every
    /// other ingested column is dropped at construction. A bare name keeps
    /// every column with that tail; `observed_field` still resolves it under
    /// API_SPEC §5.8's rules.
    pub retain_data_fields: Vec<String>,

    /// Evaluate only what these observeds need. `None` (the default)
    /// evaluates every build-time observed.
    ///
    /// When `Some`, and the build pipeline runs over a model with nothing to
    /// integrate, its observed-graph pass evaluates only the DEPENDENCY CONE
    /// of the named observeds: each one, and transitively every observed its
    /// definition names. Names are spelled as [`observed_field`] would be
    /// called (exact, component-qualified, or bare; a bare name seeds every
    /// observed it is the tail of). Every field in the cone is bit-identical
    /// to the unpruned build's, and [`observed_field`] answers for nothing
    /// outside it.
    ///
    /// Without the build pipeline, the state-free evaluation of a document
    /// with nothing to integrate is narrowed the same way: its flattened
    /// system is compiled with only the cone's observed equations, after the
    /// whole document has passed the build's gates.
    ///
    /// What sizes the build is NOT pruned: the build-time coordinates value
    /// invention seeds from, value invention itself (every derived index set
    /// and its extent), member-factor feedback, data ingestion and the gated
    /// fetch all run as they do without this option, and an observed an index
    /// set names (a ragged set's `offsets`, say) is always in the cone, as is,
    /// on the state-free evaluation, one an event or a field initial condition
    /// names. Nor is anything pruned in a model with state: its build-time
    /// fields feed a right-hand side.
    ///
    /// A strict compiler ([`Compiler::Native`]) refuses only a rule in the
    /// cone: a document it refuses whole can build with a request that leaves
    /// the refused rule out. The free-name gate (a name declared nowhere)
    /// still sees every equation, on both routes, and so does the state-free
    /// evaluation's unlowered-operator gate.
    ///
    /// `esm simulate --observed` sets this, so a relational document's run
    /// costs what the requested columns cost rather than what the document
    /// costs.
    pub observed_cone: Option<Vec<String>>,

    /// Time at which providers are sampled at construction: a DISCRETE
    /// provider gives its record in effect there (a CONST one is
    /// time-invariant). Defaults to `tspan.0`. It moves only the construction
    /// sample: a solve still starts from the record in effect at `tspan.0`
    /// and refreshes at every refresh time inside `tspan`.
    pub sample_time: Option<f64>,

    /// Leave every shaped parameter that has a value and is not fed from
    /// outside the model (no `update`) as a run-time input of
    /// [`crate::rhs_program`]: an [`crate::SlotKind::ArrayParameter`] forcing
    /// slot, seeded with that value, instead of build-time data (API_SPEC
    /// §5.8). The value is the document's (inline array data, or one scalar
    /// broadcast over its grid) or the caller's [`Self::const_arrays`] entry,
    /// which takes precedence. The Problem itself
    /// reads it from its forcing buffer, where construction serves that
    /// value, so `solve` integrates the same numbers either way. Off by
    /// default.
    pub runtime_array_parameters: bool,

    /// The construct classes construction removes and hands back instead of
    /// refusing (API_SPEC §5.8, "Strip and expose"). Empty, the default,
    /// changes nothing. A Problem anything was removed from is refused by
    /// [`solve`] and [`init`]; read what was removed with [`stripped`] and
    /// compile what the caller needs with [`crate::compile_kernels`].
    /// `native` and `interpreter` only.
    pub strip: crate::strip::StripSet,
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
            .field("rhs", &self.rhs)
            .field("compiler", &self.compiler)
            .field("rewrites", &self.rewrites)
            .field("inspect", &self.inspect)
            .field("retain_data_fields", &self.retain_data_fields)
            .field("observed_cone", &self.observed_cone)
            .field("sample_time", &self.sample_time)
            .field("runtime_array_parameters", &self.runtime_array_parameters)
            .field("strip", &self.strip);
        #[cfg(not(target_arch = "wasm32"))]
        d.field("pushdown_rewrite", &self.pushdown_rewrite)
            .field("providers", &self.providers.keys().collect::<Vec<_>>())
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
    /// The array / spatial runtime — the tape under `native` / `xla`, its
    /// per-cell oracle under `interpreter` (API_SPEC §5.8), for every document.
    Array(Rc<ArrayCompiled>),
    /// No right-hand side: the document declares no differential equations, or
    /// the caller asked for [`Rhs::Never`]. Carries the reason.
    Static(String),
}

/// The build-time products construction materialized.
#[derive(Default)]
pub(crate) struct BuildProducts {
    /// Observed name → build-time field (dependency-complete).
    pub fields: HashMap<String, ArrayD<f64>>,
    /// Data-fed parameter name → the values the build pipeline's provider
    /// supplied (`crate::prepare::PreparedBuild::data_fields`), for the
    /// parameters [`ProblemOptions::retain_data_fields`] names only. Kept apart
    /// from `fields` so the default `esm simulate` output (every observed) is
    /// unchanged, while [`observed_field`] and the inline-test runner can
    /// still answer for one by name.
    pub data_fields: HashMap<String, ArrayD<f64>>,
    /// The ingested data-fed parameters construction did NOT keep (sorted), so
    /// [`observed_field`] can say how to ask for one rather than call it
    /// unknown.
    pub dropped_data_fields: Vec<String>,
    /// Value-invention producer id (`from_faq`) → sorted-distinct member ids.
    pub members: HashMap<String, Vec<i64>>,
    /// Value-invention producer id → derived index-set extent.
    pub extents: HashMap<String, i64>,
    /// Provider keys that were deferred + fetched pre-sliced (sorted).
    pub gated_provider_keys: Vec<String>,
    /// Parameters baked into the build. Substituting one of these needs a
    /// rebuild, so [`remake`] refuses rather than lying.
    pub baked_parameters: Vec<String>,
    /// The baked parameters a join reads — through an `on` key column or an
    /// `overlap` envelope factor ([`bind_join_key_params`]) — so [`remake`]'s
    /// refusal can name that cause. A grid spacing that both builds the cell
    /// rings and enters a flux is the case a caller will not guess.
    pub join_baked_parameters: std::collections::HashSet<String>,
    /// Why a state-free document's observed graph could not be evaluated at
    /// construction — a fail-closed evaluation fault such as
    /// `E_TREEWALK_CONSTARRAY_OOB` — so [`observed_field`] can name the cause
    /// instead of only the name it cannot answer.
    pub static_eval_error: Option<String>,
    /// The build pipeline's built variables,
    /// read by [`EsmProblem::built_variables`] when there is no compiled model
    /// to answer instead. Empty when the pipeline did not run.
    pub built_variables: crate::simulate_array::BuiltVariables,
    /// The names (keyed like `fields`) whose value the build pipeline took
    /// from a TIME-VARYING provider's record in effect at the construction
    /// sample, in a document with nothing to integrate: each data-fed
    /// parameter such a provider fed and every observed reading one. Their
    /// build-time values are the answer at that time only.
    pub time_pinned: std::collections::HashSet<String>,
}

/// The raw document a Problem carries. A document read from a file and built
/// without rewriting keeps the file's text and parses it on the first
/// [`EsmProblem::document`] call, so the build hands its one parsed copy to
/// the loader instead of cloning it.
pub(crate) struct RawDocument {
    text: Option<String>,
    value: std::cell::OnceCell<JsonValue>,
}

impl RawDocument {
    fn parsed(value: JsonValue) -> Self {
        RawDocument {
            text: None,
            value: std::cell::OnceCell::from(value),
        }
    }

    fn from_text(text: String) -> Self {
        RawDocument {
            text: Some(text),
            value: std::cell::OnceCell::new(),
        }
    }

    fn get(&self) -> &JsonValue {
        self.value.get_or_init(|| {
            // The text parsed once already, when the Problem was built.
            self.text
                .as_deref()
                .and_then(|t| serde_json::from_str(t).ok())
                .unwrap_or(JsonValue::Null)
        })
    }
}

/// A simulation problem: a document, an interval, and the bindings that fix
/// the document rather than the run.
///
/// Built once by [`esm_problem`]; run by [`solve`] (or stepped by [`init`]).
/// Re-parameterized without rebuilding by [`remake`].
pub struct EsmProblem {
    /// The (possibly rewritten) raw document.
    pub(crate) doc: Rc<RawDocument>,
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
    /// The compiler that built this Problem's right-hand side (§2.5.10).
    pub(crate) compiler: Compiler,
    /// Where every rule landed, computed at CONSTRUCTION — which is also where
    /// a strict `native` refuses, so the record and the refusal are read off
    /// the same tape build.
    pub(crate) compiler_report: CompilerReport,
    /// Callbacks declared on the EsmProblem (§2.5.4).
    pub(crate) callbacks: CallbackSet,
    /// The document's §2.2 `solver` block, captured at construction.
    ///
    /// Its OWN field rather than a read-back out of `doc`, because `doc` is
    /// `JsonValue::Null` whenever the problem was built from a typed
    /// [`EsmFile`] and the build pipeline was not requested — which made the
    /// §2.2.2 chain dead on exactly the paths a library caller uses. `None` when
    /// the document declares no block, or when the problem was built from a bare
    /// [`FlattenedSystem`], which carries no document at all.
    pub(crate) solver: Option<crate::types::Solver>,
    /// Bound run-time providers, already CONST-materialized.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) refresh: Option<SharedRefresh>,
    /// Forcing variables fed by a DISCRETE provider.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) discrete_forcing: std::collections::HashSet<String>,
    /// Refresh anchors strictly inside `tspan`.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) refresh_boundaries: Vec<f64>,
    /// The key the caller passed each run-time provider under, keyed by the
    /// forcing name it feeds, so an error names the provider as the caller
    /// did whenever it fails.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) provider_keys: HashMap<String, String>,
    /// The typed input the right-hand side was compiled from, kept so
    /// [`crate::range_rhs::rhs_program`] can flatten it once and select terms
    /// by provenance (API_SPEC §5.8). `None` for a problem with no array
    /// backend.
    pub(crate) program_source: Option<Rc<ProgramSource>>,
    /// [`ProblemOptions::runtime_array_parameters`], for `rhs_program`.
    pub(crate) runtime_array_parameters: bool,
    /// What [`ProblemOptions::strip`] removed (empty when nothing was).
    pub(crate) stripped: Rc<crate::strip::StrippedConstructs>,
    /// The stripped document the Problem was built from, for
    /// [`crate::compile_kernels`] (`None` when `strip` was empty).
    pub(crate) strip_source: Option<Rc<EsmFile>>,
}

/// What [`EsmProblem::program_source`] holds: the prepared typed document, or
/// the caller's flattened system.
pub(crate) enum ProgramSource {
    File(Box<EsmFile>),
    Flattened(Box<FlattenedSystem>),
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
    /// The document's §2.2 `solver` block, or `None` when it declares none.
    ///
    /// The middle level of the esm-spec §2.2.2 tolerance chain, captured at
    /// construction so it holds however the problem was built.
    pub fn solver(&self) -> Option<&crate::types::Solver> {
        self.solver.as_ref()
    }

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
        self.doc.get()
    }

    /// The compiler that built this Problem's right-hand side (API_SPEC §5.8).
    ///
    /// The vocabulary value the build ACTUALLY used — which, because a refused
    /// compiler is never answered by substituting another, is always the one
    /// the caller asked for.
    pub fn compiler(&self) -> Compiler {
        self.compiler
    }

    /// Where every rule of this Problem landed (API_SPEC §5.8).
    ///
    /// Informative even under a strict [`Compiler::Native`], where every rule
    /// is taped by construction: the interesting question there is the cadence
    /// tier each rule runs at, which is what makes a cost readable.
    pub fn compiler_report(&self) -> &CompilerReport {
        &self.compiler_report
    }

    /// `"array"` or `"static"`.
    ///
    /// Kept for compatibility beside [`Self::compiler`], which is the stable
    /// answer to "what built this". Under both `native` and `interpreter` a
    /// dynamic Problem is `"array"`, so this does not distinguish the two;
    /// `compiler()` does.
    pub fn backend_kind(&self) -> &'static str {
        match &*self.backend {
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

    /// The right-hand side a solve of this Problem integrates, with the
    /// Problem's parameters ([`Self::p`]) over the declared defaults, and the
    /// tape behind it ([`crate::simulate_array::SolveRhs`]): for measurement
    /// and inspection tooling outside the crate, which the public program
    /// ([`crate::rhs_program`]) does not serve. A static Problem has no
    /// right-hand side; a tape that declines a rule is a solve's refusal.
    #[doc(hidden)]
    pub fn debug_solve_rhs(&self) -> Result<crate::simulate_array::SolveRhs, SimulateError> {
        match &*self.backend {
            Backend::Array(c) => crate::simulate_array::SolveRhs::new(Rc::clone(c), &self.p),
            Backend::Static(_) => Err(SimulateError::Compile(
                crate::compile_error::CompileError::build_err(
                    "this Problem is static: it has no right-hand side".to_string(),
                ),
            )),
        }
    }

    /// The compiled array model behind this Problem's right-hand side, or
    /// `None` for a static Problem.
    #[cfg(test)]
    pub(crate) fn debug_array_compiled(&self) -> Option<Rc<ArrayCompiled>> {
        match &*self.backend {
            Backend::Array(c) => Some(Rc::clone(c)),
            Backend::Static(_) => None,
        }
    }

    /// Whether this EsmProblem has a right-hand side to integrate.
    pub fn is_dynamic(&self) -> bool {
        !matches!(&*self.backend, Backend::Static(_))
    }

    /// Whether `strip` removed anything from this Problem (API_SPEC §5.8):
    /// [`solve`] and [`init`] refuse it when it did.
    pub fn is_stripped(&self) -> bool {
        !self.stripped.is_empty()
    }

    /// The state-variable names of the compiled right-hand side, in the
    /// flattened state-vector order. Empty for a static EsmProblem.
    pub fn state_variable_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Array(c) => c.qualified_state_names().to_vec(),
            Backend::Static(_) => Vec::new(),
        }
    }

    /// The parameter names of the compiled right-hand side. Empty for a static
    /// EsmProblem.
    pub fn parameter_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Array(c) => c.qualified_parameter_names().to_vec(),
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

    /// What this Problem's build knows of its variables by name
    /// ([`crate::simulate_array::BuiltVariables`]): the compiled model's, else,
    /// for a Problem with no compiled model, the build pipeline's. Keyed by the
    /// name the build gives a variable — model-local for a single-model build,
    /// `Model.var` for a whole-document one.
    #[cfg(feature = "solve")]
    pub(crate) fn built_variables(&self) -> &crate::simulate_array::BuiltVariables {
        match &*self.backend {
            Backend::Array(c) => c.built_variables(),
            Backend::Static(_) => &self.build.built_variables,
        }
    }

    /// The observeds a solve of this Problem materializes ONCE at setup, and
    /// so records in [`BuildInspection::setup_arrays`] when inspecting, keyed
    /// like [`Self::built_variables`]. `None` for a Problem with no compiled
    /// model, which never solves.
    #[cfg(feature = "solve")]
    pub(crate) fn static_observeds(&self) -> Option<std::collections::HashSet<String>> {
        let Backend::Array(c) = &*self.backend else {
            return None;
        };
        #[cfg(not(target_arch = "wasm32"))]
        let discrete = &self.discrete_forcing;
        #[cfg(target_arch = "wasm32")]
        let discrete = &std::collections::HashSet::new();
        Some(
            c.observed_dependencies(discrete)
                .at_most(crate::cadence::Cadence::Const),
        )
    }

    /// Every build-time field this EsmProblem's construction materialized, keyed
    /// by observed name.
    pub fn observed_fields(&self) -> &HashMap<String, ArrayD<f64>> {
        &self.build.fields
    }

    /// The values the build pipeline ingested for each DATA-FED parameter
    /// (esm-spec §5.4 `update: {kind: "data"}`), keyed like
    /// [`Self::observed_fields`]: those [`ProblemOptions::retain_data_fields`]
    /// named. Empty when no provider fed the build or none was named.
    pub(crate) fn data_fields(&self) -> &HashMap<String, ArrayD<f64>> {
        &self.build.data_fields
    }

    /// [`BuildProducts::time_pinned`]: the build-time values that hold only
    /// at the construction sample, because a time-varying provider decided
    /// them there.
    pub(crate) fn time_pinned(&self) -> &std::collections::HashSet<String> {
        &self.build.time_pinned
    }

    /// The names of the OBSERVED VARIABLES [`observed_trajectory`] can report a
    /// trajectory for.
    ///
    /// Disjoint from [`Self::observed_field_names`] and answering a different
    /// question: those are constants the BUILD materialized, these vary along a
    /// solution. Empty on the static backend, which has no run to vary along.
    pub fn observed_variable_names(&self) -> Vec<String> {
        match &*self.backend {
            Backend::Array(c) => c.observed_rule_names().collect(),
            Backend::Static(_) => Vec::new(),
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

/// What [`ProblemOptions::strip`] removed from `prob`, flattened and
/// namespaced (API_SPEC §5.8, "The stripped object"). Empty when nothing was.
pub fn stripped(prob: &EsmProblem) -> &crate::strip::StrippedConstructs {
    &prob.stripped
}

/// `stripped_problem_not_solvable` when `strip` removed anything from `prob`.
#[cfg_attr(not(feature = "solve"), allow(dead_code))]
fn refuse_stripped(prob: &EsmProblem, call: &str) -> Result<(), SimulateError> {
    if prob.is_stripped() {
        return Err(crate::strip::strip_error(
            crate::diagnostic::codes::STRIPPED_PROBLEM_NOT_SOLVABLE,
            format!(
                "`{call}` cannot run a Problem `strip` removed constructs from ({}): running it \
                 without them would report a number the document does not describe. Evaluate \
                 its right-hand side and the removed constructs with `compile_kernels`",
                prob.stripped.removed_classes().join(", ")
            ),
        ));
    }
    Ok(())
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
    mut opts: ProblemOptions,
) -> Result<EsmProblem, SimulateError> {
    let input = input.into();
    let set = std::mem::take(&mut opts.strip);
    if set.is_empty() {
        return build_problem(input, tspan, opts, set);
    }
    strip_and_build(input, tspan, opts, set)
}

/// [`esm_problem`] with `strip` non-empty (API_SPEC §5.8): load the document,
/// remove `set`'s constructs, build what remains, and keep what was removed.
fn strip_and_build(
    input: ProblemInput<'_>,
    tspan: (f64, f64),
    mut opts: ProblemOptions,
    set: crate::strip::StripSet,
) -> Result<EsmProblem, SimulateError> {
    let compiler = opts.compiler.unwrap_or_default();
    if !matches!(compiler, Compiler::Native | Compiler::Interpreter) {
        return Err(SimulateError::CompilerUnavailable {
            compiler: compiler.as_str(),
            details: "`strip` serves the `native` and `interpreter` compilers (API_SPEC §5.8, \
                      \"Strip and expose\")"
                .to_string(),
        });
    }
    let load = |raw: &JsonValue, base: Option<PathBuf>, opts: &ProblemOptions| {
        crate::parse::load_document_with_options(
            raw,
            &crate::parse::LoadOptions {
                base_path: base,
                metaparameters: opts.metaparameters.clone(),
            },
        )
        .map_err(|e| {
            SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                "loading the document: {e}"
            )))
        })
    };
    let file = match input {
        ProblemInput::Path(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "reading {}: {e}",
                    path.display()
                )))
            })?;
            // esm-spec §1.2.1: the extension picks the format.
            let raw: JsonValue = crate::ref_reader::decode_document(&text, path).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "parsing {}: {e}",
                    path.display()
                )))
            })?;
            if opts.base_path.is_none() {
                opts.base_path = Some(match path.parent() {
                    Some(dir) if !dir.as_os_str().is_empty() => dir.to_path_buf(),
                    _ => PathBuf::from("."),
                });
            }
            load(&raw, opts.base_path.clone(), &opts)?
        }
        ProblemInput::Json(raw) => load(raw, opts.base_path.clone(), &opts)?,
        ProblemInput::File(f) => f.clone(),
        ProblemInput::Flattened(_) => {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::build_err(
                    "`strip` needs a document; a flattened system has none to strip",
                ),
            ));
        }
    };
    let stripped = crate::strip::strip_file(&file, set)?;
    // The loader closed the metaparameters already.
    opts.metaparameters.clear();
    let p = opts.p.clone();
    let mut prob = build_problem(ProblemInput::File(&stripped.file), tspan, opts, set)?;
    let mut constructs = stripped.constructs;
    if !constructs.z_layout.is_empty() {
        let flat = crate::flatten::flatten(&stripped.file)
            .map_err(|e| SimulateError::Compile(e.into()))?;
        let mut params: HashMap<String, f64> = flat
            .parameters
            .iter()
            .filter_map(|(k, v)| match &v.default {
                Some(crate::types::InlineValue::Scalar(x)) => Some((k.clone(), *x)),
                _ => None,
            })
            .collect();
        for (k, v) in &p {
            if params.contains_key(k) {
                params.insert(k.clone(), *v);
            }
        }
        params.insert("t".to_string(), tspan.0);
        constructs.z0 = crate::strip::z_starting_values(&flat, &constructs.z_layout, &params);
    }
    prob.stripped = Rc::new(constructs);
    prob.strip_source = Some(Rc::new(stripped.file));
    Ok(prob)
}

/// [`esm_problem`] without `strip`. `taken` is the set the caller stripped
/// with, for the coupling-level event gate.
fn build_problem(
    input: ProblemInput<'_>,
    tspan: (f64, f64),
    opts: ProblemOptions,
    taken: crate::strip::StripSet,
) -> Result<EsmProblem, SimulateError> {
    #[allow(unused_mut)]
    let mut opts = opts;

    // ---- (1) Resolve the input to a raw document and/or a typed one. -------
    let mut owned_json: Option<JsonValue> = None;
    let mut owned_file: Option<EsmFile> = None;
    let mut flat_only: Option<&FlattenedSystem> = None;
    // `owned_json` is exactly what the parser made of the file's text, so it
    // nests within the parser's recursion limit (see stage (3)).
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut json_from_text = false;

    // The file's text, while `owned_json` is still exactly its parse.
    let mut source_text: Option<String> = None;
    match input {
        ProblemInput::Path(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "reading {}: {e}",
                    path.display()
                )))
            })?;
            // esm-spec §1.2.1: the extension picks the format.
            let raw: JsonValue = crate::ref_reader::decode_document(&text, path).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                    "parsing {}: {e}",
                    path.display()
                )))
            })?;
            owned_json = Some(raw);
            // Only JSON text is the document's text; a Markdown or Typst
            // source document is kept as its parse.
            source_text = crate::ref_reader::source_format(path)
                .is_none()
                .then_some(text);
            json_from_text = true;
            // A relative `{ref}` or template import resolves against the
            // referencing file's directory (esm-spec §4.7), not the process's
            // working directory; a caller's explicit `base_path` still wins.
            if opts.base_path.is_none() {
                opts.base_path = Some(match path.parent() {
                    Some(dir) if !dir.as_os_str().is_empty() => dir.to_path_buf(),
                    _ => PathBuf::from("."),
                });
            }
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
        opts.model_name.as_deref(),
    )?;
    let _precision_guard = precision::enter_env(prec, std::sync::Arc::new(var_precisions));

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
        // `const_arrays` is a host-side build-pipeline input and does not
        // exist on wasm32, where `ProblemOptions` carries no build half.
        #[cfg(not(target_arch = "wasm32"))]
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
    // The build pipeline's flattened system, while the typed document the
    // compile path would flatten is still exactly the one it was flattened
    // from (`PreparedBuild::flattened`): every stage below that changes that
    // document drops it.
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut pipeline_flat: Option<FlattenedSystem> = None;
    let compiler = opts.compiler.unwrap_or_default();
    // A compiler this build or process cannot provide is refused before
    // anything is evaluated for it: that failure says nothing about the
    // document, so no document-level refusal may pre-empt it.
    if let Some(details) = unavailable_reason(compiler) {
        return Err(SimulateError::CompilerUnavailable {
            compiler: compiler.as_str(),
            details,
        });
    }
    // What construction evaluates OUTSIDE the compiled model's rule set — the
    // build pipeline, a state-free document's observed graph — reported ahead
    // of that rule set (API_SPEC §5.8, "Every Problem reports what ran").
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut route_rows: Vec<CompilerRuleReport> = Vec::new();
    // Whether the build pipeline evaluated `observed_cone`'s cone: its fields
    // are then the answer even when the cone held no observed.
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut pipeline_evaluated_cone = false;
    // Whether the build pipeline ran value invention over the system the
    // compile builds, so the compile takes `build.members` and
    // `build.extents` rather than running it again.
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut pipeline_invented = false;

    // What the caller supplied for the document's shaped parameters, captured
    // before the build pipeline consumes `const_arrays` and the providers it consumes:
    // the compiled model binds the arrays too (stage 3d), and the missing-data
    // gate asks which names any channel serves.
    let supplied = SuppliedData::capture(&mut opts, owned_json.as_ref(), owned_file.as_ref());

    // A TYPED document is a legitimate input to the build pipeline, and it used
    // to be the one input shape that silently was not: the pipeline reads raw
    // JSON, so `ProblemInput::File` skipped it entirely — `providers`,
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
        // The JSON form does not carry where the document was loaded from,
        // and the re-parse would resolve its relative `coupling_import` refs
        // against the working directory instead (esm-spec §10.10 -> §4.7: they
        // resolve against the importing document). Keep that anchor.
        if opts.base_path.is_none() {
            opts.base_path = file.coupling_import_base.as_ref().map(PathBuf::from);
        }
        owned_file = None;
    }

    // The build pipeline's ingested data-fed columns, and the keys of those
    // `retain_data_fields` asks to keep; settled into `build` once the
    // right-hand side has taken what it reads (step 5).
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut ingested: HashMap<String, ArrayD<f64>> = HashMap::new();
    #[cfg_attr(target_arch = "wasm32", allow(unused_mut))]
    let mut retained_data_keys: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    #[cfg(not(target_arch = "wasm32"))]
    if let Some(raw) = owned_json.as_mut().filter(|_| wants_build_pipeline(&opts)) {
        refuse_pipeline_provider_const_overlap(raw, &opts, &supplied.const_keys)?;
        {
            // The pipeline's observeds are evaluated where the static route
            // evaluates them: at the construction sample.
            let sample_time = opts.sample_time.unwrap_or(tspan.0);
            let prepared = crate::prepare::run_build_pipeline(raw, sample_time, &mut opts)?;
            // The pipeline evaluates the observed graph through the reference
            // evaluator whatever the compiler, and under a strict one it
            // stopped at the first observed it had to walk per cell.
            if let Some(r) = &prepared.refused {
                // The walk stopped at its first cell (`CellWalks`).
                let reason = match &r.route {
                    crate::prepare::Route::PerCell(why) => {
                        format!("{why}; {}", crate::simulate_array::ONE_CELL_NOTE)
                    }
                    _ => String::new(),
                };
                return Err(SimulateError::Compile(
                    crate::compile_error::CompileError::CompilerRefusedRule {
                        compiler: compiler.as_str(),
                        kind: r.kind,
                        rule: qualify(prepared.model_name.as_deref().unwrap_or(""), &r.name),
                        tier: "const",
                        reason,
                    },
                ));
            }
            route_rows.extend(prepared.rules.iter().map(|r| {
                use crate::simulate_array::BuildRoute;
                let rule = qualify(prepared.model_name.as_deref().unwrap_or(""), &r.name);
                let route = match &r.route {
                    crate::prepare::Route::Relational => {
                        return CompilerRuleReport {
                            rule,
                            kind: r.kind,
                            cadence: "const",
                            tier: "relational",
                            reason: None,
                        };
                    }
                    crate::prepare::Route::Whole => BuildRoute::Whole,
                    crate::prepare::Route::Tape => BuildRoute::Tape,
                    crate::prepare::Route::PerCell(_) => BuildRoute::PerCell,
                };
                build_time_row(compiler, rule, r.kind, route)
            }));
            // The pipeline loaded the document it prepared, closed over its
            // metaparameters: that typed form is the one compiled below, and
            // the raw form is kept for `EsmProblem::document`.
            *raw = prepared.doc;
            // The pipeline's flattened system is the compile's, so its value
            // invention is too.
            pipeline_invented = prepared.flattened.is_some();
            owned_file = Some(prepared.file);
            json_from_text = false;
            source_text = None;
            // The whole-document build (several models, none selected) keeps
            // `None`: its names are qualified already, as on the compile path.
            model_name = prepared.model_name;
            pipeline_flat = prepared.flattened;
            build = prepared.products;
            pipeline_evaluated_cone = prepared.observed_cone_applied;
            retained_data_keys = retained_data_keys_of(
                prepared.data_fields.keys(),
                model_name.as_deref().unwrap_or(""),
                &opts.retain_data_fields,
            );
            ingested = prepared.data_fields;
            build.baked_parameters = opts.p.keys().cloned().collect();
            build.baked_parameters.sort();
        }
    }

    // ---- (3) Typed parse. -------------------------------------------------
    // The document's own solver block, read here when the raw document is
    // handed to the loader below rather than kept.
    let mut doc_solver_of_text: Option<Option<crate::Solver>> = None;
    if owned_file.is_none() && owned_json.is_some() {
        {
            // The prepared document goes to the loader as the value it already
            // is. Writing it out and parsing the text back gives the same
            // document -- this crate parses with `float_roundtrip`, so every
            // number reads back as the value written -- except that the parser
            // refuses nesting past its recursion limit, so only a document
            // nested that deep still takes the round trip, to get the same
            // refusal. A document parsed from a file's text is within that
            // limit already. The loader-API metaparameters close the authored
            // document (esm-spec §9.7.6 site 4).
            let load_opts = crate::parse::LoadOptions {
                base_path: opts.base_path.clone(),
                metaparameters: opts.metaparameters.clone(),
            };
            let loaded = if json_from_text && source_text.is_some() {
                // The Problem keeps the file's text, so the loader may consume
                // the parse rather than a copy of it.
                let raw = owned_json.take().expect("checked above");
                doc_solver_of_text = Some(document_solver(&raw));
                crate::parse::load_document_owned(raw, &load_opts)
            } else if let Some(raw) = owned_json.as_ref()
                && (json_from_text || nesting_within(raw, NESTING_WITHOUT_ROUND_TRIP))
            {
                crate::parse::load_document_with_options(raw, &load_opts)
            } else {
                let raw = owned_json.as_ref().expect("checked above");
                let text = serde_json::to_string(raw).map_err(|e| {
                    SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
                        "re-serializing the prepared document: {e}"
                    )))
                })?;
                crate::parse::load_string_with_options(&text, &load_opts)
            };
            // A document failing to load — a schema violation, an unresolved
            // import, a removed op, a version the library does not read — is
            // fatal under every `Rhs` mode: esm-libraries-spec §2.1a says a
            // library MUST NOT silently accept an invalid file, and a Problem
            // built from one would answer for a document that does not load.
            match loaded {
                Ok(f) => owned_file = Some(f),
                Err(e) => {
                    let details = format!("loading the document: {e}");
                    return Err(SimulateError::Compile(match e.code() {
                        Some(code) => {
                            crate::compile_error::CompileError::coded_build_err(code, details)
                        }
                        None => crate::compile_error::CompileError::build_err(details),
                    }));
                }
            }
        }
    }

    // A coupling-level event is lowered by no compiler: refuse it unless the
    // caller stripped its class (esm-spec §9.6.6 `unsupported_construct`).
    if let Some(f) = owned_file.as_ref() {
        crate::strip::refuse_coupling_events(f, taken)?;
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
        pipeline_flat = None;
    }

    // ---- (3d) Caller arrays for shaped parameters. ------------------------
    // CONFORMANCE_SPEC §5.32.5: a caller's `const_arrays` entry that gives a
    // shaped parameter its value is the same binding as an inline-array
    // override, so it lands where that override does — on the parameter's
    // `default`, which the array compile lowers. The build pipeline above only
    // evaluates the observed graph; without this the compiled right-hand side
    // never saw the array and ran on the declared default instead.
    #[cfg(not(target_arch = "wasm32"))]
    if let Some(f) = owned_file.as_mut()
        && supplied.bind_arrays(f, &opts.p, model_name.as_deref())
    {
        pipeline_flat = None;
    }
    // A `p` entry may land on a declaration below (a value-invention or join
    // key parameter's `default`, a data-fed parameter's dropped `update`).
    if !opts.p.is_empty() {
        pipeline_flat = None;
    }
    // A scalar parameter value invention reads (a key's bin width) is
    // build-time data: the invented set's size depends on it, so the caller's
    // `p` entry lands on its `default`, which the compile's value invention
    // reads, and the parameter is baked into the build.
    if let Some(f) = owned_file.as_mut() {
        for name in bind_value_invention_params(f, &opts.p) {
            if !build.baked_parameters.contains(&name) {
                build.baked_parameters.push(name);
            }
        }
        // A scalar parameter a join key column or an overlap envelope factor
        // reads decides the join's match set or the gate's candidate pairs,
        // which the build constructs once (CONFORMANCE_SPEC §5.5.6, §5.5.8):
        // it is baked the same way, under every compiler.
        for name in bind_join_key_params(f, &opts.p) {
            if !build.baked_parameters.contains(&name) {
                build.baked_parameters.push(name.clone());
            }
            build.join_baked_parameters.insert(name);
        }
        build.baked_parameters.sort();
    }

    // ---- (3d) A `p` pin BINDS a data-fed parameter (esm-spec §9.6.6). -----
    // The caller passed a value for a parameter the document says is read from
    // a file, so for THIS build it is not read from a file — that is the
    // documented escape hatch for running a data-fed document offline, and for
    // its own inline tests (`Test.parameter_overrides`, esm-spec §6.6, is this
    // argument by another name). Stripping the `update` here, before the
    // backend is built, is what makes the pin REACH the right-hand side: a
    // parameter that still carries a `data` update is routed to the external
    // forcing channel, where a `p` binding never lands and which the tape
    // cannot lower at all, so the pin used to change nothing and `native`
    // refused the document anyway.
    #[cfg(not(target_arch = "wasm32"))]
    if !opts.p.is_empty()
        && let Some(file) = owned_file.as_mut()
    {
        crate::data_fed::pin_data_fed_parameters(file, opts.p.keys());
    }

    // ---- (4) Compile the right-hand side. ---------------------------------
    let invented = pipeline_invented.then_some(crate::simulate_array::InventedSets {
        extents: &build.extents,
        members: &build.members,
    });
    let backend = compile_backend(
        owned_file.as_ref(),
        flat_only,
        pipeline_flat.as_ref(),
        invented,
        model_name.as_deref(),
        opts.rhs,
        compiler,
        opts.rewrites,
        opts.runtime_array_parameters,
    )?;

    // ---- (4a) The missing-data gate (esm-spec §10.10). ---------------------
    // A shaped parameter with neither a default nor a supplied value is a
    // construction error, raised here naming the parameter rather than as an
    // unbound read at the first evaluation. An array model is checked on its
    // compiled tables (after step 5 has bound the providers); a static one on
    // its flattened parameters, before its observed graph is evaluated.
    if let Backend::Static(_) = &backend
        && let Some(f) = owned_file.as_ref()
    {
        supplied.refuse_missing_static(
            f,
            pipeline_flat.as_ref(),
            &opts.p,
            model_name.as_deref(),
        )?;
    }

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
    // pushdown path keeps its own (model-local) keys untouched — or evaluated
    // the cone of `observed_cone`, which leaves no fields when the request
    // names only a data-fed parameter.
    //
    // Evaluated by the compiler the Problem names, and gated by it: the tape
    // under `native` / `xla`, the per-cell oracle under `interpreter`.
    if build.fields.is_empty()
        && !pipeline_evaluated_cone
        && let Backend::Static(_) = &backend
    {
        let t0 = opts.sample_time.unwrap_or(tspan.0);
        let (fields, rows, eval_error) = static_observed_fields(
            owned_file.as_ref(),
            flat_only.or(pipeline_flat.as_ref()),
            &opts.p,
            t0,
            model_name.as_deref(),
            compiler,
            opts.rewrites,
            opts.observed_cone.as_deref(),
        )?;
        build.fields = fields;
        build.static_eval_error = eval_error;
        route_rows.extend(rows);
    }

    // ---- (5) Bind and CONST-materialize the run-time providers. -----------
    #[cfg(not(target_arch = "wasm32"))]
    let (refresh, discrete_forcing, refresh_boundaries, provider_keys) = bind_providers(
        &backend,
        &mut opts,
        tspan,
        &supplied.const_keys,
        &coupling_reads(owned_file.as_ref()),
    )?;
    #[cfg(target_arch = "wasm32")]
    let provider_keys: HashMap<String, String> = HashMap::new();
    // Every ingested column construction does not keep for read-back —
    // including the ones the right-hand side is about to take — so
    // `observed_field` can name the option that would have kept it.
    build.dropped_data_fields = ingested
        .keys()
        .filter(|k| !retained_data_keys.contains(*k))
        .cloned()
        .collect();
    build.dropped_data_fields.sort();
    if let Backend::Array(c) = &backend {
        supplied.refuse_missing_array(
            c,
            owned_file.as_ref(),
            &opts.p,
            &provider_keys,
            &mut ingested,
            &retained_data_keys,
        )?;
    }
    // Keep only the ingested columns a caller asked to read back; the rest
    // (those the right-hand side took were moved, not copied) are dropped.
    ingested.retain(|k, _| retained_data_keys.contains(k));
    build.data_fields = ingested;

    // ---- (5c) Refuse a data-fed parameter nothing bound (§9.6.6). ---------
    // After the providers are bound and BEFORE the compiler's gate below builds
    // the tape, so the refusal is the same under `native` and `interpreter`:
    // this asks whether the DOCUMENT's inputs are bound, not what a compiler
    // can lower. Without it `native` reported the same document as
    // `compiler_refused_rule` ("wholesale: unresolved symbol"), naming the
    // tape's limits in place of the defect, while `interpreter` built and then
    // failed inside the run with an uncoded treewalk fault.
    #[cfg(not(target_arch = "wasm32"))]
    if let Backend::Array(compiled) = &backend {
        crate::data_fed::refuse_unbound(
            compiled,
            &opts.const_arrays,
            &discrete_forcing,
            opts.p.keys(),
        )?;
    }

    // esm-spec §2.2: the document's own solver hints. Read from whichever
    // carrier survived to here — the raw JSON when there is one, else the typed
    // file — so the §2.2.2 chain holds however the problem was built.
    let doc_solver = match (doc_solver_of_text, owned_json.as_ref(), owned_file.as_ref()) {
        (Some(solver), _, _) => solver,
        (None, Some(raw), _) => document_solver(raw),
        (None, None, Some(file)) => crate::solver::normalize_empty(file.solver.clone()),
        (None, None, None) => None,
    };

    // ---- (5b) The compiler's own gate, and its report. --------------------
    // §2.5.10 puts the refusal at CONSTRUCTION, and puts every evaluation the
    // compiler performs for the Problem under it — not the right-hand side
    // alone. Both need the tape, so the tape is built HERE rather than inside
    // `solve`, and with the DISCRETE forcing set step (5) just resolved, which
    // is what decides a rule's cadence tier.
    let mut compiler_report = build_compiler_report(
        &backend,
        model_name.as_deref(),
        compiler,
        #[cfg(not(target_arch = "wasm32"))]
        &discrete_forcing,
        #[cfg(target_arch = "wasm32")]
        &std::collections::HashSet::new(),
        &opts.p,
        tspan.0,
    )?;
    compiler_report.rules.splice(0..0, route_rows);

    // ---- (5b') Every state slot has a starting value (esm-spec §11.4). ------
    // After (5b), which resolved the field `ic`s this reads.
    #[cfg(feature = "solve")]
    if let Backend::Array(c) = &backend {
        refuse_missing_initial_values(c, &opts.u0).map_err(|e| c.show_error(e))?;
    }

    // ---- (5c) `xla`: emit and compile, here, once. ------------------------
    // AFTER the gate above, so a rule that never reached the tape is refused
    // by name with its cadence tier and component, rather than by the
    // emitter's own unqualified refusal of the declined tape. At construction rather than at the first
    // step, because §2.5.10 puts the refusal at construction and because XLA
    // compilation is the expensive step: a Problem pays it once, and every
    // segment and every Jacobian call reuses the one executable.
    install_xla_program(&backend, model_name.as_deref(), compiler)?;

    // ---- (5d) Sample the DISCRETE providers, after every gate above. ------
    #[cfg(not(target_arch = "wasm32"))]
    if let (Backend::Array(compiled), Some(exec)) = (&backend, &refresh) {
        sample_discrete_providers(
            compiled,
            exec,
            &discrete_forcing,
            opts.sample_time.unwrap_or(tspan.0),
            &provider_keys,
        )?;
    }

    let program_source = match (&backend, owned_file, flat_only) {
        (Backend::Array(_), Some(file), _) => Some(Rc::new(ProgramSource::File(Box::new(file)))),
        (Backend::Array(_), None, Some(flat)) => {
            Some(Rc::new(ProgramSource::Flattened(Box::new(flat.clone()))))
        }
        _ => None,
    };
    let prob = EsmProblem {
        doc: Rc::new(match (owned_json, source_text) {
            (None, Some(text)) => RawDocument::from_text(text),
            (raw, _) => RawDocument::parsed(raw.unwrap_or(JsonValue::Null)),
        }),
        solver: doc_solver,
        model_name,
        precision: precision::Env::capture(),
        tspan,
        p: std::mem::take(&mut opts.p),
        u0: std::mem::take(&mut opts.u0),
        backend: Rc::new(backend),
        build: Rc::new(build),
        inspection: std::cell::RefCell::new(BuildInspection::default()),
        inspect: opts.inspect,
        compiler,
        compiler_report,
        callbacks: std::mem::take(&mut opts.callbacks),
        #[cfg(not(target_arch = "wasm32"))]
        refresh,
        #[cfg(not(target_arch = "wasm32"))]
        discrete_forcing,
        #[cfg(not(target_arch = "wasm32"))]
        refresh_boundaries,
        #[cfg(not(target_arch = "wasm32"))]
        provider_keys,
        program_source,
        runtime_array_parameters: opts.runtime_array_parameters,
        stripped: Rc::default(),
        strip_source: None,
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
    selected: Option<&str>,
) -> Result<precision::VarPrecisions, SimulateError> {
    if let Some(models) = raw
        .and_then(|v| v.get("models"))
        .and_then(JsonValue::as_object)
    {
        let decls: Vec<precision::ModelDeclarations<'_>> = models
            .iter()
            .map(|(mname, model)| precision::ModelDeclarations {
                model: mname,
                variables: model
                    .get("variables")
                    .and_then(JsonValue::as_object)
                    .map(|vars| {
                        vars.iter()
                            .map(|(v, d)| {
                                (
                                    v.as_str(),
                                    d.get("element_type").and_then(JsonValue::as_str),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                subsystem_variables: precision::subsystem_declarations(model.get("subsystems")),
            })
            .collect();
        return precision::VarPrecisions::from_declarations(&decls, document, selected)
            .map_err(SimulateError::Compile);
    }
    if let Some(models) = file.and_then(|f| f.models.as_ref()) {
        let decls = crate::precision_infer::model_declarations(models);
        return precision::VarPrecisions::from_declarations(&decls, document, selected)
            .map_err(SimulateError::Compile);
    }
    // A flattened system carries namespaced names and no per-variable element
    // types of its own; nothing to collect. `document` stays the answer for
    // every name.
    let _ = (flat, document);
    Ok(precision::VarPrecisions::default())
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
    // evaluator, and `Rhs::Always` giving it a non-static backend does not
    // make it dynamic.
    let integrates = match &*prob.backend {
        Backend::Static(_) => false,
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

/// Arrays and objects nested this deep or less parse from text well inside
/// `serde_json`'s recursion limit (128).
const NESTING_WITHOUT_ROUND_TRIP: usize = 64;

/// Whether no array or object in `v` sits more than `limit` containers deep
/// (the root container is depth 1).
fn nesting_within(v: &JsonValue, limit: usize) -> bool {
    match v {
        JsonValue::Array(items) => limit > 0 && items.iter().all(|x| nesting_within(x, limit - 1)),
        JsonValue::Object(map) => limit > 0 && map.values().all(|x| nesting_within(x, limit - 1)),
        _ => true,
    }
}

/// Whether the build pipeline consumes the CONST providers: when the caller
/// asked for it, not when `const_arrays` alone turned it on.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn pipeline_takes_providers(opts: &ProblemOptions) -> bool {
    opts.build_pipeline || opts.pushdown_rewrite
}

#[cfg(not(target_arch = "wasm32"))]
fn wants_build_pipeline(opts: &ProblemOptions) -> bool {
    opts.build_pipeline || opts.pushdown_rewrite || !opts.const_arrays.is_empty()
}

/// The compiled model of a problem with **nothing to integrate** whose
/// observeds are a scalar function of the parameters and `t` alone — the
/// graph [`evaluate_static_observeds_over`] evaluates.
///
/// `esm simulate` evaluates such a document ONCE, at `tspan.0`, because a
/// single evaluation is all that command promises. The §6.6 inline-test runner
/// cannot stop there: esm-spec §6.6.3 defines an assertion's `time` as
/// "Simulation time at which to evaluate the assertion", and a document with
/// no differential equations is still a FUNCTION OF `t` — a solar-geometry
/// component's declination, hour angle and zenith cosine are exactly that. So
/// the runner evaluates this once per asserted time (issue #406).
///
/// `None` when there is something to integrate — the trajectory, not this, is
/// the answer — and `None` for a SHAPED state-free document (an array,
/// tensor or geometry observed, [`ArrayCompiled::observeds_are_scalar`]), which
/// is answered from the fields its BUILD materialized instead: see the
/// `has_nothing_to_integrate` arm of the inline-test runner, which is why that
/// runner asks the build pipeline for them. `None` again when a DISCRETE
/// provider feeds the document, whose forcing moves with `t` only through the
/// segmented refresh a solve drives.
#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub(crate) fn static_observed_graph(prob: &EsmProblem) -> Option<Rc<ArrayCompiled>> {
    if !prob.discrete_forcing.is_empty() {
        return None;
    }
    match &*prob.backend {
        Backend::Array(c)
            if !c.has_differential_equations()
                && c.state_variable_names().is_empty()
                && c.observeds_are_scalar() =>
        {
            Some(Rc::clone(c))
        }
        _ => None,
    }
}

/// Every 0-D observed of [`static_observed_graph`]'s result at each of
/// `times`, against the problem's resolved parameters — `(name, values)` in
/// the document's own observed order, one value per time, named as a
/// [`solve`] of the same problem names its rows.
///
/// Evaluated by the array runtime on the compiler the problem was built with,
/// so under `native` the values come off the tape and under `interpreter` off
/// the per-cell oracle, exactly as a solve's reported observeds would.
#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub(crate) fn evaluate_static_observeds_over(
    prob: &EsmProblem,
    graph: &ArrayCompiled,
    times: &[f64],
) -> Result<Vec<(String, Vec<f64>)>, SimulateError> {
    let _precision_guard = prob.precision.enter();
    graph.evaluate_stateless_observeds(&prob.p, times)
}

/// Every observed field of a problem with **nothing to integrate** whose
/// compiled model is state-free, evaluated at `tspan.0` on the compiler the
/// problem was built with — `(name, field)` in dependency order, named as the
/// model's rules are.
///
/// The inline-test runner's answer for a SHAPED state-free document, which
/// [`static_observed_graph`] does not serve: the same array runtime the
/// problem already built, so under `native` the fields come off the tape
/// rather than from a second, pipeline build through the reference evaluator.
/// `None` when there is state or something to integrate, when a DISCRETE
/// provider feeds the document (its forcing moves only through a solve's
/// refresh), or when the evaluation fails or produces nothing.
#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub(crate) fn stateless_fields(prob: &EsmProblem) -> Option<Vec<(String, ArrayD<f64>)>> {
    if !prob.discrete_forcing.is_empty() {
        return None;
    }
    let Backend::Array(c) = &*prob.backend else {
        return None;
    };
    if c.has_differential_equations() || !c.state_variable_names().is_empty() {
        return None;
    }
    let _precision_guard = prob.precision.enter();
    c.evaluate_stateless_fields(&prob.p, prob.tspan.0)
        .ok()
        .filter(|f| !f.is_empty())
}

/// Whether this problem has **nothing to integrate**: no backend at all, or a
/// backend that declares no differential equation (esm-spec §6.3.1 derives
/// `system_kind: "nonlinear"` for such a document).
///
/// This is the derivation `Rhs::Auto` consults to pick [`Backend::Static`],
/// asked of a problem the inline-test runner deliberately built with
/// `Rhs::Always` — which still compiles, and therefore still refuses, a
/// construct no evaluator supports, but which also hands a right-hand side over
/// an empty state vector to the solver. The runner asks this BEFORE solving, so
/// a document with nothing to integrate is answered from what was evaluated or
/// built rather than reported as a nonlinear-solver failure (issue #406).
///
/// [`static_observed_graph`] serves the scalar-observed documents; this
/// predicate is what lets the runner tell "nothing to integrate, and no scalar
/// graph to evaluate here" (a shaped document) apart from "something to
/// integrate".
#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub(crate) fn has_nothing_to_integrate(prob: &EsmProblem) -> bool {
    match &*prob.backend {
        Backend::Static(_) => true,
        Backend::Array(c) => !c.has_differential_equations(),
    }
}

/// Evaluate a state-free system's observed graph at `t0`, on the compiler the
/// Problem names, and report every rule it evaluated.
///
/// The build-time half of [`observed_field`] for a document with no
/// differential equations: one stateless evaluation of the array runtime
/// ([`ArrayCompiled::evaluate_stateless_observeds`]) — no solver, no build
/// pipeline, and no dependence on how the caller spelled its input.
///
/// Keys are FLATTENED names (`Sites.North.u`), matching Julia's
/// `BuildInspection.observed_exprs` and Python's `static_observed_values`.
///
/// **The rank comes from the DECLARATION**, through the same
/// [`crate::classification::DeclaredRank`] the build pipeline uses (API_SPEC
/// `observed_trajectories`: "A field is the shape the document declares").
/// This path and the pipeline serve the SAME documents — this one runs exactly
/// when the pipeline produced no fields — so deciding the rank differently
/// here would give one document two spellings, `Rel.total` or `Rel.total[1]`,
/// picked by a backend choice the author cannot see.
///
/// **Under the compiler's refusal.** esm-libraries-spec §2.5.10 puts "the
/// materialization of constants and static observeds at construction" under
/// the refusal, and this IS that materialization for a document with nothing
/// to integrate: it has no right-hand side, but its observed graph is its
/// whole answer and something evaluates it. So the runtime is built in the
/// named compiler's mode and the SAME per-rule gate a dynamic document meets
/// ([`build_compiler_report`]) runs over it: under `native` / `xla` every rule
/// must lower to the tape, which then evaluates them, and a rule that does not
/// is a `compiler_refused_rule` naming it; under `interpreter` every rule is
/// the per-cell oracle's. `xla` emits no program here — there is no
/// right-hand side to emit — so its rules are reported as `"taped"`, which is
/// what evaluates them.
///
/// **Every observed, scalar or shaped.** A shaped state-free document — a
/// relational row set, a grid-geometry table — is evaluated here as a scalar
/// one is: its observeds are rules of the same array runtime, so the compiler
/// that answers a scalar observed answers a shaped one, rather than leaving it
/// to the build pipeline's reference evaluator. A 0-D or one-cell observed takes its rank from the declaration; a
/// shaped one is the field the runtime materialized, reported only when the
/// document declares it an observed (a shaped parameter the runtime lowered to
/// a `const` rule is not one).
///
/// **Tolerant of what no compiler can build.** A system the runtime cannot
/// build or evaluate — a `v1`-unsupported feature, a parameter with no default
/// — yields NO fields rather than failing the build, under every compiler
/// alike. Construction was not asked to compile a right-hand side
/// (`Rhs::Auto` chose `Backend::Static`), so a failure to evaluate must surface
/// as `observed_field` reporting the name it cannot answer, not as a document
/// that will not build. Python makes the same call for the same reason
/// (`problem.py`, the scalar no-state branch). Only the compiler's own refusal is
/// raised: that one says the document evaluates under `interpreter` and not
/// under the compiler the caller named. An EVALUATION failure of a runtime
/// that did build (a fail-closed fault) comes back as the third element, for
/// [`observed_field`] to report.
#[allow(clippy::type_complexity, clippy::too_many_arguments)]
fn static_observed_fields(
    file: Option<&EsmFile>,
    flat_only: Option<&FlattenedSystem>,
    p: &HashMap<String, f64>,
    t0: f64,
    model_name: Option<&str>,
    compiler: Compiler,
    rewrites: CompilerRewrites,
    cone: Option<&[String]>,
) -> Result<
    (
        HashMap<String, ArrayD<f64>>,
        Vec<CompilerRuleReport>,
        Option<String>,
    ),
    SimulateError,
> {
    let nothing = || Ok((HashMap::new(), Vec::new(), None));
    let owned_flat;
    let flat = match (flat_only, file) {
        (Some(f), _) => f,
        // A document that does not flatten — an unresolved coupling endpoint,
        // a coupling-import error — is a build failure, raised as one
        // (esm-libraries-spec §2.5.2) rather than answered with no fields.
        (None, Some(file)) => {
            owned_flat = crate::flatten::flatten(file).map_err(|e| {
                SimulateError::Compile(crate::compile_error::CompileError::Flatten(e))
            })?;
            &owned_flat
        }
        (None, None) => return nothing(),
    };
    crate::compile_error::refuse_reserved_lifting(flat).map_err(SimulateError::Compile)?;
    // The evaluable-core gate runs first (esm-spec §9.6.3 constraint 6): it
    // walks every equation, so an unknown no equation defines — which makes
    // the system not state-free below — does not let a rewrite-target operator
    // through unreported.
    if let Some(op) = crate::flatten::first_unlowered_operator(flat) {
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::UnloweredOperatorError { op },
        ));
    }
    // A system WITH state is not state-free evaluable: an observed may read
    // state, and there is none to read. Reachable when `model_name` selects an
    // ODE-free model out of a document that has ODEs elsewhere, since
    // `flatten` is document-wide.
    // An unknown defined by an element-wise equation (`index(a, i) = …`) is
    // listed as an observed as well as a state; only a state no equation
    // defines has anything to integrate.
    if flat
        .state_variables
        .keys()
        .any(|k| !flat.observed_variables.contains_key(k))
    {
        return nothing();
    }
    // An ill-formed document is not a compiler's to refuse: a name declared
    // nowhere fails the same free-variable gate the array build and the build
    // pipeline run (CONFORMANCE_SPEC §5.23), and is raised as that build
    // failure rather than surfacing as a strict compiler "declining" a rule no
    // compiler could evaluate — or as a Problem with no fields at all.
    #[cfg(not(target_arch = "wasm32"))]
    if let Some(file) = file
        && crate::simulate::whole_document_is_one_model(file)
        && let Some((_, model)) = file.models.as_ref().and_then(|m| m.iter().next())
    {
        let index_sets: HashMap<String, crate::types::IndexSet> = file
            .index_sets
            .clone()
            .unwrap_or_default()
            .into_iter()
            .collect();
        crate::simulate_array::check_free_variables(model, &index_sets, &[])
            .map_err(SimulateError::Compile)?;
    }
    // `ProblemOptions::observed_cone`: compile and evaluate only what the
    // requested fields read. The gates above see the whole document, so a
    // document they refuse is refused with or without a request. Everything
    // below sees only the cone: the compile, and a strict compiler's refusal
    // of a rule it cannot lower, which therefore does not fire for a rule
    // outside the cone.
    let pruned;
    let flat = match cone {
        Some(requested) => {
            let mut f = flat.clone();
            crate::observed_cone::prune_flattened(&mut f, requested);
            pruned = f;
            &pruned
        }
        None => flat,
    };
    // The same gates the array route runs — the evaluable-core operator gate
    // (esm-spec §9.6.3 constraint 6), events, operator arity — fire here too:
    // a state-free document is evaluated, so it is built.
    let mut compiled = ArrayCompiled::from_flattened_with(flat, false, compiler)
        .map_err(SimulateError::Compile)?;
    compiled.rewrites = rewrites;
    let compiled = Rc::new(compiled);
    let report = rule_report(
        &compiled,
        model_name,
        compiler,
        &std::collections::HashSet::new(),
        false,
    )?;
    let values = match compiled.evaluate_stateless_fields(p, t0) {
        Ok(values) => values,
        // A value that is only not yet available (a parameter with no
        // default, a field a provider fills later) leaves the Problem with no
        // fields rather than refusing it.
        Err(e) => return Ok((HashMap::new(), report.rules, Some(e.to_string()))),
    };
    let fields = values
        .into_iter()
        .filter_map(|(name, arr)| {
            let declared = flat.observed_variables.get(&name);
            if arr.len() == 1 {
                // A variable `flatten` left unshaped that the build gave an
                // array shape (esm-spec §4.3.4) is not 0-D.
                let built = compiled.built_variables().shapes.built_axes(&name);
                let shape = DeclaredRank::of_built(declared, built).scalar_shape();
                let v = arr.iter().copied().next().expect("one element");
                let arr = ArrayD::from_shape_vec(ndarray::IxDyn(shape), vec![v])
                    .expect("`scalar_shape` is `[]` or `[1]`, and both hold exactly one element");
                return Some((name, arr));
            }
            declared.map(|_| (name, arr))
        })
        .collect();
    Ok((fields, report.rules, None))
}

#[allow(clippy::too_many_arguments)]
fn compile_backend(
    file: Option<&EsmFile>,
    flat: Option<&FlattenedSystem>,
    file_flattened: Option<&FlattenedSystem>,
    invented: Option<crate::simulate_array::InventedSets<'_>>,
    model_name: Option<&str>,
    mode: Rhs,
    compiler: Compiler,
    rewrites: CompilerRewrites,
    runtime_array_parameters: bool,
) -> Result<Backend, SimulateError> {
    if let Some(details) = unavailable_reason(compiler) {
        return Err(SimulateError::CompilerUnavailable {
            compiler: compiler.as_str(),
            details,
        });
    }
    // An equation that defines a parameter (esm-spec §6.3.1) is refused under
    // every compiler and every `Rhs` mode: the build used to drop it, answering
    // with the parameter's default.
    refuse_parameter_definitions(file, flat)?;
    if mode == Rhs::Never {
        return Ok(Backend::Static(
            "the caller asked for Rhs::Never".to_string(),
        ));
    }
    if let Some(flat) = flat {
        // Same rule the typed-document branch applies below, on the input that
        // states it most directly: a flattened system with no state variables
        // has nothing to integrate, so `solve` reports `NotDynamic` rather than
        // failing inside the solver, and `observed_field` sees the static
        // fields.
        if mode == Rhs::Auto && flat.state_variables.is_empty() {
            return Ok(Backend::Static(
                "the flattened system declares no state variables".to_string(),
            ));
        }
        let mut compiled = crate::simulate_array::ArrayCompiled::from_flattened_with(
            flat,
            runtime_array_parameters,
            compiler,
        )?;
        compiled.rewrites = rewrites;
        return Ok(Backend::Array(Rc::new(compiled)));
    }
    let Some(file) = file else {
        if mode == Rhs::Always {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::build_err("no typed document to compile"),
            ));
        }
        return Ok(Backend::Static(
            "the prepared document has no typed form to compile".to_string(),
        ));
    };

    // A document with no component at all — a template or coupling library, a
    // `data_sources` registry — has nothing to build. Julia's and Python's
    // `flatten` refuse it the same way, rather than hand back an empty Problem.
    let n_components = file.models.as_ref().map_or(0, |m| m.len())
        + file.reaction_systems.as_ref().map_or(0, |r| r.len());
    if n_components == 0 {
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "nothing to flatten: '{}' declares no `models` and no `reaction_systems`. A \
                 file carrying only `expression_templates` is a template LIBRARY (esm-spec \
                 §9.7); import it from a document that declares components rather than \
                 building it directly",
                file.metadata.name.as_deref().unwrap_or("")
            )),
        ));
    }

    refuse_structurally_unreachable(file)?;
    refuse_unregistered_callback_reads(file)?;
    refuse_reference_integrity_errors(file)?;

    if mode == Rhs::Auto && !has_differential_equations(file, model_name) {
        // Nothing to integrate is not nothing to run: an event, an implicit
        // equation or a noise term still changes what the document means, and
        // the static evaluation below honours none of them. The array route
        // refuses each by name, and so does this one.
        refuse_static_unsupported_construct(file, model_name)?;
        return Ok(Backend::Static(
            "the document declares no differential equations".to_string(),
        ));
    }

    // §2.5.10: "A binding MUST NOT switch strategy inside `native` on document
    // content: a scalar document and a gridded one are built by the same
    // machinery, so that what ran is a property of the name and not of the
    // input." So every document, scalar or gridded, builds the array runtime.
    let mut compiled = crate::simulate::build_array_compiled(
        file,
        file_flattened,
        invented,
        runtime_array_parameters,
        compiler,
    )?;
    compiled.rewrites = rewrites;
    Ok(Backend::Array(Rc::new(compiled)))
}

/// Refuse an equation whose left-hand side names a parameter
/// (`equation_defines_parameter`, esm-spec §6.3.1), in the typed document or,
/// for a flattened input, in the flattened equations. `validate` reports the
/// same finding; Julia and Python refuse it at their front doors too.
fn refuse_parameter_definitions(
    file: Option<&EsmFile>,
    flat: Option<&FlattenedSystem>,
) -> Result<(), SimulateError> {
    let refuse = |path: &str, message: &str| {
        SimulateError::Compile(crate::compile_error::CompileError::coded_build_err(
            crate::diagnostic::codes::EQUATION_DEFINES_PARAMETER,
            format!(
                "[{}] {path}: {message} (esm-spec §6.3.1)",
                crate::diagnostic::codes::EQUATION_DEFINES_PARAMETER
            ),
        ))
    };
    if let Some(file) = file
        && let Some(e) = crate::structural::parameter_definition_errors(file).first()
    {
        return Err(refuse(&e.path, &e.message));
    }
    if let Some(flat) = flat {
        for (k, eq) in flat.equations.iter().enumerate() {
            let mut lhs = &eq.lhs;
            let name = loop {
                match lhs {
                    crate::types::Expr::Variable(v) => break Some(v.as_str()),
                    crate::types::Expr::Operator(n) if n.op == "faq" => match n.expr.as_deref() {
                        Some(x) => lhs = x,
                        None => break None,
                    },
                    crate::types::Expr::Operator(n)
                        if n.op == "index"
                            || (n.op == "D" && matches!(n.wrt.as_deref(), None | Some("t"))) =>
                    {
                        match n.args.first() {
                            Some(x) => lhs = x,
                            None => break None,
                        }
                    }
                    _ => break None,
                }
            };
            if let Some(name) = name
                && flat.parameters.contains_key(name)
            {
                return Err(refuse(
                    &format!("/equations/{k}/lhs"),
                    &format!(
                        "Equation {k} defines '{name}', which is a parameter; an equation \
                         defines unknowns only"
                    ),
                ));
            }
        }
    }
    Ok(())
}

/// Refuse two declarations the document can hold but no build may run, each a
/// structural error `validate` also reports, which built anyway would be
/// finite, plausible and wrong:
///
/// * a declaration spelled with the independent variable or `_var`
///   (`reserved_variable_name`, esm-spec §4.9.1.1): every reader of the name
///   gets the implicit symbol, never the declared quantity;
/// * an `ic` equation among a reaction system's `constraint_equations`
///   (`ic_in_reaction_system`, esm-spec §11.4.1), which no evaluator applies.
///
/// Julia and Python refuse both at their front doors too. A shaped variable
/// read by bare name in a `faq` (`faq_bare_array_operand`) is refused later,
/// on the model the build compiles
/// ([`crate::simulate_array::refuse_faq_bare_array_operands`]).
fn refuse_structurally_unreachable(file: &EsmFile) -> Result<(), SimulateError> {
    let refuse = |code: &str, path: &str, message: &str, section: &str| {
        SimulateError::Compile(crate::compile_error::CompileError::build_err(format!(
            "[{code}] {path}: {message} (esm-spec {section})"
        )))
    };
    if let Some(e) = crate::structural::reserved_declaration_errors(file).first() {
        return Err(refuse(&e.code.to_string(), &e.path, &e.message, "§4.9.1.1"));
    }
    if let Some(systems) = &file.reaction_systems {
        for (rs_name, rs) in systems {
            for (i, eq) in rs.constraint_equations.iter().flatten().enumerate() {
                if matches!(&eq.lhs, crate::types::Expr::Operator(n) if n.op == "ic") {
                    return Err(refuse(
                        crate::diagnostic::codes::IC_IN_REACTION_SYSTEM,
                        &format!("/reaction_systems/{rs_name}/constraint_equations/{i}"),
                        "ic equation not allowed in a reaction system; a reaction system \
                         hosts no ic equations (a species' initial value is its \
                         `species.default`, or a scoped-reference ic equation in a model)",
                        "§11.4.1",
                    ));
                }
            }
        }
    }
    Ok(())
}

/// The structural-validation codes a build refuses on (esm-libraries-spec
/// §2.5.2). They are the reference-integrity findings: a name, reference or data
/// source the document uses and does not declare. A build that went ahead would
/// read a value the document does not describe. Equation-count and unit findings
/// are not here: they stay `validate`'s to report.
const BUILD_REFUSED_VALIDATION_CODES: &[&str] = &[
    "undefined_variable",
    "undefined_parameter",
    "undefined_species",
    "undefined_system",
    "undefined_index_set",
    "unresolved_scoped_ref",
    "event_var_undeclared",
    "data_source_undefined",
    "missing_required_field",
];

/// Refuse the first [`BUILD_REFUSED_VALIDATION_CODES`] finding `validate`
/// reports for `file`, with the validator's code, pointer and message.
fn refuse_reference_integrity_errors(file: &EsmFile) -> Result<(), SimulateError> {
    let result =
        crate::validate::validate_scoped(file, crate::validate::ValidationScope::References);
    if let Some(e) = result.structural_errors.iter().find(|e| {
        // An inline test's references are the test runner's to report
        // (esm-spec §6.6); the build does not evaluate them.
        BUILD_REFUSED_VALIDATION_CODES.contains(&e.code.to_string().as_str())
            && !e.path.contains("/tests/")
    }) {
        let named = declared_name_at(&e.path)
            .map(|n| format!(" (variable '{n}')"))
            .unwrap_or_default();
        return Err(SimulateError::Compile(
            crate::compile_error::CompileError::build_err(format!(
                "[{}] {}: {}{named} (esm-libraries-spec §2.5.2)",
                e.code, e.path, e.message
            )),
        ));
    }
    Ok(())
}

/// The full name of the variable a validator pointer sits under —
/// `/models/A/subsystems/B/variables/v/…` is `A.B.v` — so a refusal names the
/// variable the way a caller addresses it (esm-spec §6.6.2).
fn declared_name_at(pointer: &str) -> Option<String> {
    let segs: Vec<&str> = pointer.trim_start_matches('/').split('/').collect();
    let mut parts = Vec::new();
    let mut i = 0;
    while i + 1 < segs.len() {
        match segs[i] {
            "models" | "reaction_systems" | "subsystems" => parts.push(segs[i + 1]),
            "variables" | "species" | "parameters" => {
                parts.push(segs[i + 1]);
                return Some(parts.join("."));
            }
            _ => return None,
        }
        i += 2;
    }
    None
}

/// Refuse, with `callback_unregistered` (esm-spec §9.6.6), an equation that
/// reads a variable a `callback` coupling injects
/// (`config.callback_variables[].name`). Only a registered callback supplies
/// that value, and nothing registers one at construction, so a build would read
/// a placeholder the document does not describe. The interpreter would read
/// an unset forcing slot at its first call instead.
fn refuse_unregistered_callback_reads(file: &EsmFile) -> Result<(), SimulateError> {
    let mut injected: BTreeMap<String, String> = BTreeMap::new();
    for entry in file.coupling.iter().flatten() {
        let crate::CouplingEntry::Callback {
            callback_id,
            config,
            ..
        } = entry
        else {
            continue;
        };
        let names = config
            .as_ref()
            .and_then(|c| c.get("callback_variables"))
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|cv| cv.get("name").and_then(|n| n.as_str()));
        for name in names {
            injected.insert(name.to_string(), callback_id.clone());
        }
    }
    if injected.is_empty() {
        return Ok(());
    }
    let Some(models) = file.models.as_ref() else {
        return Ok(());
    };
    let mut names: Vec<&String> = models.keys().collect();
    names.sort();
    for name in names {
        callback_reads_in(&models[name], name, &injected)?;
    }
    Ok(())
}

/// [`refuse_unregistered_callback_reads`] over one model and its inline
/// subsystems. A name the model declares itself is not the injected one.
fn callback_reads_in(
    model: &crate::types::Model,
    path: &str,
    injected: &BTreeMap<String, String>,
) -> Result<(), SimulateError> {
    for eq in &model.equations {
        for side in [&eq.lhs, &eq.rhs] {
            let mut vars: Vec<String> = crate::free_variables(side).into_iter().collect();
            vars.sort();
            for v in vars {
                if model.variables.contains_key(&v) {
                    continue;
                }
                if let Some(id) = injected.get(&v) {
                    return Err(SimulateError::Compile(
                        crate::compile_error::CompileError::build_err(format!(
                            "[{}] '{path}' reads '{v}', which the `callback` coupling '{id}' \
                             supplies, but no callback is registered to supply it at \
                             construction; refusing the build rather than reading a value \
                             the document does not give (esm-spec §9.6.6)",
                            crate::diagnostic::codes::CALLBACK_UNREGISTERED
                        )),
                    ));
                }
            }
        }
    }
    let mut subs: Vec<(&String, &crate::types::Model)> = model.inline_subsystems().collect();
    subs.sort_by(|a, b| a.0.cmp(b.0));
    for (name, sub) in subs {
        callback_reads_in(sub, &format!("{path}.{name}"), injected)?;
    }
    Ok(())
}

/// Refuse, with `unsupported_construct` (esm-spec §9.6.6), a document with
/// nothing to integrate that still carries an event, an implicit equation or a
/// Wiener-noise parameter — in the named model, or in any model when none is
/// named, subsystems included. The array route refuses the same three while
/// compiling; a state-free document never reaches it.
fn refuse_static_unsupported_construct(
    file: &EsmFile,
    model_name: Option<&str>,
) -> Result<(), SimulateError> {
    if model_name.is_none()
        && let Some((construct, event)) = crate::compile_error::first_event_in_file(file)
    {
        return Err(crate::compile_error::event_refusal(
            construct,
            crate::compile_error::ARRAY_EVALUATOR,
            event.as_deref(),
        )
        .into());
    }
    let Some(models) = file.models.as_ref() else {
        return Ok(());
    };
    for (_, model) in models
        .iter()
        .filter(|(name, _)| model_name.is_none_or(|want| want == name.as_str()))
    {
        if let Some(refusal) = static_unsupported_construct(model) {
            return Err(refusal.into());
        }
    }
    Ok(())
}

/// The first construct of `model` or its inline subsystems that
/// [`refuse_static_unsupported_construct`] refuses, as its refusal.
fn static_unsupported_construct(
    model: &crate::types::Model,
) -> Option<crate::compile_error::CompileError> {
    use crate::compile_error::ARRAY_EVALUATOR;
    if let Some((construct, event)) = crate::compile_error::first_event(model) {
        return Some(crate::compile_error::event_refusal(
            construct,
            ARRAY_EVALUATOR,
            event.as_deref(),
        ));
    }
    if let Some(eq) = crate::compile_error::first_implicit_equation(&model.equations) {
        return Some(crate::compile_error::implicit_equation_refusal(
            ARRAY_EVALUATOR,
            eq,
        ));
    }
    let class = crate::classification::Classification::of(model);
    if let Some(name) = class.brownian_parameters.first() {
        return Some(crate::compile_error::CompileError::UnsupportedConstruct {
            construct: crate::compile_error::WIENER_NOISE,
            evaluator: ARRAY_EVALUATOR,
            detail: format!("parameter '{name}'"),
        });
    }
    let mut subs: Vec<(&String, &crate::types::Model)> = model.inline_subsystems().collect();
    subs.sort_by(|a, b| a.0.cmp(b.0));
    subs.into_iter()
        .find_map(|(_, sub)| static_unsupported_construct(sub))
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
    // `geoschem_fullchem`), and `Rhs::Auto` was calling each of them static
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
        .any(|(_, m)| crate::simulate_array::model_tree_any(m, &model_has_derivative))
}

/// Whether any equation of `model` has a TIME derivative in its LHS — the
/// esm-spec §6.3.1 derivation of `system_kind`, which is what "declares no
/// differential equations" means (API_SPEC §5.8).
///
/// A bare top-level `D` is not the only spelling. The arrayed form
/// `faq{expr: D(index(u, i))}` is how every array-op PDE is written and what
/// the pointwise lift produces, and `index(D(u), i)` also names a derivative.
/// Each of them makes the document dynamic (issue #476): the array runtime
/// then either compiles the equation or refuses it by name, where
/// [`Backend::Static`] would have `solve` answer `NotDynamic` for a document
/// that plainly integrates.
fn model_has_derivative(model: &crate::types::Model) -> bool {
    model
        .equations
        .iter()
        .any(|eq| crate::classification::has_time_derivative(&eq.lhs))
}
